import Foundation
import UIKit

struct ChatArchiveBoundaryPresentationAnchor {
    let locator: ArchiveWindowLocator
    let direction: ChatHistoryPageDirection
    let anchor: ChatHistoryPageAnchor
}

enum ChatArchiveWindowPresentationPolicy {
    static func shouldAdmitDatasourceApply(
        isArchiveEnginePresentationActive: Bool,
        owner: ChatDatasourcePresentationOwner
    ) -> Bool {
        !isArchiveEnginePresentationActive || owner == .archiveEngine
    }

    static func latestTargetIntent(
        conversation: ArchiveConversationKey
    ) -> ArchiveWindowIntent {
        ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .target
        )
    }

    static func shouldShowBoundaryLoadingIndicator(
        activity: ArchiveWindowActivity,
        pendingPresentationTarget: ArchiveWindowLocator? = nil,
        isShowingFullSkeleton: Bool
    ) -> Bool {
        guard !isShowingFullSkeleton else { return false }
        return activity.isLoadingBoundary ||
            pendingPresentationTarget.map(isBoundaryExpansion) == true
    }

    static func shouldReplaceCommittedContentWithSkeleton(
        for locator: ArchiveWindowLocator
    ) -> Bool {
        switch locator {
        case .older, .newer, .gap:
            return false
        case .latest, .firstUnread, .archiveID, .timestamp:
            return true
        }
    }

    private static func isBoundaryExpansion(_ locator: ArchiveWindowLocator) -> Bool {
        switch locator {
        case .older, .newer, .gap:
            return true
        case .latest, .firstUnread, .archiveID, .timestamp:
            return false
        }
    }

    static func shouldRunLegacyBootstrapRematerialization(
        isArchiveEnginePresentationActive: Bool
    ) -> Bool {
        !isArchiveEnginePresentationActive
    }

    static func shouldResetForStart(
        isPresentationActive: Bool,
        currentIntent: ArchiveWindowIntent?,
        incomingIntent: ArchiveWindowIntent
    ) -> Bool {
        _ = currentIntent
        _ = incomingIntent
        return !isPresentationActive
    }

    static func shouldCoalesceVerifiedState(
        currentState: ArchiveWindowState?,
        committedCoverageGeneration: UInt64?,
        pendingSnapshot: ArchiveWindowSnapshot?,
        incoming: ArchiveWindowSnapshot
    ) -> Bool {
        if pendingSnapshot == incoming {
            return true
        }
        guard committedCoverageGeneration == incoming.coverageGeneration,
              case .verified(let current) = currentState else {
            return false
        }
        return current == incoming
    }

    static func canPrefetch(
        snapshot: ArchiveWindowSnapshot,
        committedCoverageGeneration: UInt64?,
        isShowingSkeleton: Bool
    ) -> Bool {
        !isShowingSkeleton &&
            committedCoverageGeneration == snapshot.coverageGeneration
    }

    static func shouldDeferOpenMessageRequest(
        isPresentationActive: Bool,
        state: ArchiveWindowState?,
        committedCoverageGeneration: UInt64?,
        pendingSnapshot: ArchiveWindowSnapshot?,
        isShowingSkeleton: Bool
    ) -> Bool {
        guard isPresentationActive else { return false }
        guard case .verified(let snapshot) = state,
              committedCoverageGeneration == snapshot.coverageGeneration,
              pendingSnapshot == nil,
              !isShowingSkeleton else {
            return true
        }
        return false
    }

    static func shouldCapturePagingAnchor(
        for locator: ArchiveWindowLocator
    ) -> Bool {
        switch locator {
        case .older, .newer, .gap:
            return true
        case .latest, .firstUnread, .archiveID, .timestamp:
            return false
        }
    }

    static func boundaryDirection(
        for locator: ArchiveWindowLocator
    ) -> ChatHistoryPageDirection? {
        switch locator {
        case .older, .gap:
            return .older
        case .newer:
            return .newer
        case .latest, .firstUnread, .archiveID, .timestamp:
            return nil
        }
    }

    static func resolveBoundaryAnchor(
        for locator: ArchiveWindowLocator,
        live: ChatHistoryPageAnchor?,
        retained: ChatHistoryPageAnchor?
    ) -> ChatHistoryPageAnchor? {
        guard boundaryDirection(for: locator) != nil else { return nil }
        return live ?? retained
    }

    static func boundaryApplyPlan(
        for locator: ArchiveWindowLocator,
        hasCapturedAnchor: Bool
    ) -> ChatHistoryPageApplyPlan {
        guard let direction = boundaryDirection(for: locator) else {
            return ChatHistoryPageApplyPlan(
                keepOffset: false,
                restorePhase: .none,
                applyCategory: .default
            )
        }
        return ChatHistoryPageApplyPolicy.plan(
            direction: direction,
            hasCapturedAnchor: hasCapturedAnchor
        )
    }

    static func shouldShowBoundaryRecoverySkeleton(
        for locator: ArchiveWindowLocator,
        hasUsableAnchor: Bool,
        hasCommittedContent: Bool
    ) -> Bool {
        boundaryDirection(for: locator) != nil &&
            hasCommittedContent &&
            !hasUsableAnchor
    }

    static func forceBottomAlignmentTarget(
        for locator: ArchiveWindowLocator,
        itemCount: Int
    ) -> ChatBottomAlignmentTarget? {
        guard itemCount > 0,
              case .latest = locator else {
            return nil
        }
        return .newestRealMessage
    }

    static func shouldRetryAtomicApply(
        failure: ChatViewportTransactionFailure,
        completedRetryCount: Int
    ) -> Bool {
        guard completedRetryCount < 2 else { return false }
        switch failure {
        case .targetMissing, .alignmentUnresolved:
            return true
        case .superseded:
            return false
        }
    }

    static func shouldShowFullSkeleton(
        for state: ArchiveWindowState,
        committedCoverageGeneration: UInt64?
    ) -> Bool {
        switch state {
        case .skeleton, .retryableFailure:
            return true
        case .verified(let snapshot):
            return committedCoverageGeneration != snapshot.coverageGeneration
        case .authoritativeEmpty:
            return committedCoverageGeneration != 0
        }
    }

    static func shouldPreserveCommittedContent(
        currentState: ArchiveWindowState?,
        committedCoverageGeneration: UInt64?,
        incoming: ArchiveWindowSnapshot
    ) -> Bool {
        guard case .verified(let current) = currentState,
              committedCoverageGeneration == current.coverageGeneration else {
            return false
        }
        switch incoming.target {
        case .older, .newer, .gap:
            return current.freshnessToken.fingerprint == incoming.freshnessToken.fingerprint
        case .latest:
            return current.target == incoming.target &&
                current.freshnessToken.fingerprint == incoming.freshnessToken.fingerprint &&
                incoming.verifiedSegment.oldest <= current.verifiedSegment.oldest &&
                incoming.verifiedSegment.newest >= current.verifiedSegment.newest
        case .firstUnread, .archiveID, .timestamp:
            return false
        }
    }
}

enum ChatArchiveVerifiedTimelineStateFactory {
    static func make(
        items: [MessageStorageItem],
        expectedPrimaryIDs: [String],
        segment: ArchiveCoverageSegment,
        conversationKey: ChatTimelineConversationKey
    ) -> ChatTimelineSnapshot? {
        guard segment.isVerified,
              Set(items.map(\.primary)) == Set(expectedPrimaryIDs),
              items.count == Set(expectedPrimaryIDs).count else {
            return nil
        }
        let ordered: [MessageStorageItem] = items.compactMap { item in
            guard item.owner == conversationKey.owner,
                  item.opponent == conversationKey.jid,
                  item.conversationType == conversationKey.conversationType,
                  let cursor = ArchiveCursor(rawValue: item.archivedId),
                  cursor >= segment.oldest,
                  cursor <= segment.newest else {
                return nil
            }
            return item
        }.sorted {
            guard let lhs = ArchiveCursor(rawValue: $0.archivedId),
                  let rhs = ArchiveCursor(rawValue: $1.archivedId) else {
                return $0.date < $1.date
            }
            return lhs < rhs
        }
        guard ordered.count == items.count else { return nil }

        let oldest = ordered.first.map(ChatTimelineBoundary.init(message:))
        let newest = ordered.last.map(ChatTimelineBoundary.init(message:))
        var segments: [ChatVirtualSegment] = []
        if !segment.reachesArchiveStart {
            segments.append(.unknownOlder)
        }
        segments.append(
            .loadedRange(
                oldestArchiveId: oldest?.archivedId ?? segment.oldest.rawValue,
                newestArchiveId: newest?.archivedId ?? segment.newest.rawValue
            )
        )
        if segment.reachesLiveEdge {
            segments.append(.liveTail)
        } else {
            segments.append(.unknownNewer)
        }
        let state = ChatVirtualTimelineState(
            conversationKey: conversationKey,
            segments: segments,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: ordered.map(\.primary),
            residentArchivedIds: ordered.compactMap {
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0.archivedId)
            },
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: segment.reachesLiveEdge
        )
        return ChatTimelineSnapshot(
            items: ordered,
            state: state,
            loadingState: .none,
            loadDecision: nil,
            anchorRestore: nil,
            pageSize: ordered.count
        )
    }
}

extension ChatViewController {
    var archiveEngineConversationKey: ArchiveConversationKey {
        ArchiveConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
    }

    internal func startArchiveEnginePresentationIfNeeded() {
        assert(Thread.isMainThread)
        let intent = makeInitialArchiveWindowIntent()
        let shouldResetPresentation =
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: archiveEnginePresentationActive,
                currentIntent: archiveWindowIntent,
                incomingIntent: intent
            )
        guard shouldResetPresentation else { return }
        cancelDatasetMappingJobs()
        cancelBootstrapSkeletonMappingJobs()
        scrollWorkScheduler.cancel()
        archiveEnginePresentationActive = true
        archiveWindowIntent = intent
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
        archiveWindowState = .skeleton(reason: .opening, target: intent.locator)
        archiveWindowActivity = .idle
        setArchiveLoading(false)
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)

        guard let account = AccountManager.shared.find(for: owner) else {
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowState = .skeleton(reason: .offline, target: .latest)
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            return
        }
        if archiveWindowStateTask == nil {
            let conversation = archiveEngineConversationKey
            archiveWindowStateTask = Task { @MainActor [weak self, weak account] in
                guard let self, let account else { return }
                let states = await account.archiveEngine.states(for: conversation)
                for await state in states {
                    guard !Task.isCancelled else { return }
                    self.receiveArchiveWindowState(state)
                }
            }
        }
        if archiveWindowActivityTask == nil {
            let conversation = archiveEngineConversationKey
            archiveWindowActivityTask = Task { @MainActor [weak self, weak account] in
                guard let self, let account else { return }
                let activities = await account.archiveEngine.activities(for: conversation)
                for await activity in activities {
                    guard !Task.isCancelled else { return }
                    self.receiveArchiveWindowActivity(activity)
                }
            }
        }

        Task { await account.archiveEngine.submit(intent) }
    }

    internal func stopArchiveEnginePresentationSubscription() {
        archiveWindowStateTask?.cancel()
        archiveWindowStateTask = nil
        archiveWindowActivityTask?.cancel()
        archiveWindowActivityTask = nil
        archiveWindowActivity = .idle
        setArchiveLoading(false)
        archiveEnginePresentationActive = false
        archiveWindowPendingSnapshot = nil
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        archiveWindowApplyGeneration &+= 1
        cancelDatasetMappingJobs()
    }

    internal func retryArchiveEngineWindow() {
        guard let account = AccountManager.shared.find(for: owner) else { return }
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        Task { await account.archiveEngine.retry(conversation: archiveEngineConversationKey) }
    }

    @discardableResult
    internal func submitArchiveEngineLatestTarget() -> Bool {
        guard archiveEnginePresentationActive else { return false }
        let intent = ChatArchiveWindowPresentationPolicy.latestTargetIntent(
            conversation: archiveEngineConversationKey
        )
        archiveWindowIntent = intent
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveWindowState = .skeleton(reason: .loadingTarget, target: .latest)
        archiveWindowActivity = .idle
        setArchiveLoading(false)
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        if let account = AccountManager.shared.find(for: owner) {
            Task { await account.archiveEngine.submit(intent) }
        }
        return true
    }

    @discardableResult
    internal func submitArchiveEngineTarget(_ request: ChatOpenMessageRequest) -> Bool {
        guard archiveEnginePresentationActive,
              request.owner == owner,
              request.chatJid == jid,
              request.conversationType == conversationType,
              let account = AccountManager.shared.find(for: owner) else {
            return false
        }
        let locator: ArchiveWindowLocator
        if let rawArchiveID = request.anchor.archivedId,
           let cursor = ArchiveCursor(rawValue: rawArchiveID) {
            locator = .archiveID(cursor)
        } else if let date = request.anchor.sourceDate {
            locator = .timestamp(date)
        } else {
            return false
        }
        let intent = ArchiveWindowIntent(
            conversation: archiveEngineConversationKey,
            locator: locator,
            contextBefore: ArchivePageSizing.anchorBefore,
            contextAfter: ArchivePageSizing.anchorAfter,
            priority: .target
        )
        archiveWindowIntent = intent
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveWindowState = .skeleton(reason: .loadingTarget, target: locator)
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        Task { await account.archiveEngine.submit(intent) }
        return true
    }

    internal func submitArchiveEnginePage(
        direction: ChatHistoryPageDirection,
        priority: ArchiveIntentPriority = .visibleIntegrity
    ) {
        guard let account = AccountManager.shared.find(for: owner),
              case .verified(let snapshot) = archiveWindowState else {
            return
        }
        let locator: ArchiveWindowLocator
        let contextBefore: Int
        let contextAfter: Int
        switch direction {
        case .older:
            locator = .older(before: snapshot.verifiedSegment.oldest)
            contextBefore = ArchivePageSizing.history
            contextAfter = min(snapshot.messagePrimaryIDs.count, ArchivePageSizing.initial)
        case .newer:
            locator = .newer(after: snapshot.verifiedSegment.newest)
            contextBefore = min(snapshot.messagePrimaryIDs.count, ArchivePageSizing.initial)
            contextAfter = ArchivePageSizing.history
        }
        let intent = ArchiveWindowIntent(
            conversation: archiveEngineConversationKey,
            locator: locator,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            priority: priority
        )
        archiveWindowIntent = intent
        if let anchor = captureArchiveEngineBoundaryAnchor(direction: direction) {
            archiveWindowBoundaryPresentationAnchor = ChatArchiveBoundaryPresentationAnchor(
                locator: locator,
                direction: direction,
                anchor: anchor
            )
        }
        if priority >= .target,
           ChatArchiveWindowPresentationPolicy.shouldReplaceCommittedContentWithSkeleton(
                for: locator
           ) {
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowPendingSnapshot = nil
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
        }
        Task { await account.archiveEngine.submit(intent) }
    }

    internal func prefetchArchiveEngineWindowIfNeeded(indexPaths: [IndexPath]) {
        guard archiveEnginePresentationActive,
              case .verified(let snapshot) = archiveWindowState,
              ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: archiveWindowCommittedCoverageGeneration,
                isShowingSkeleton: showSkeletonObserver.value
              ),
              indexPaths.isNotEmpty,
              datasource.isNotEmpty else {
            return
        }
        let visibleCount = max(1, messagesCollectionView.indexPathsForVisibleItems.count)
        let threshold = max(8, visibleCount * 2)
        let sections = indexPaths.map(\.section)
        if !snapshot.verifiedSegment.reachesArchiveStart,
           let minimum = sections.min(),
           minimum < threshold {
            submitArchiveEnginePage(direction: .older, priority: .nearEdgePrefetch)
            return
        }
        if !snapshot.verifiedSegment.reachesLiveEdge,
           let maximum = sections.max(),
           maximum >= max(0, datasource.count - threshold) {
            submitArchiveEnginePage(direction: .newer, priority: .nearEdgePrefetch)
        }
    }

    private func makeInitialArchiveWindowIntent() -> ArchiveWindowIntent {
        let conversation = archiveEngineConversationKey
        if let request = pendingOpenMessageRequest,
           request.owner == owner,
           request.chatJid == jid,
           request.conversationType == conversationType {
            if let rawArchiveID = request.anchor.archivedId,
               let cursor = ArchiveCursor(rawValue: rawArchiveID) {
                return ArchiveWindowIntent(
                    conversation: conversation,
                    locator: .archiveID(cursor),
                    contextBefore: ArchivePageSizing.anchorBefore,
                    contextAfter: ArchivePageSizing.anchorAfter,
                    priority: .target
                )
            }
            if let date = request.anchor.sourceDate {
                return ArchiveWindowIntent(
                    conversation: conversation,
                    locator: .timestamp(date),
                    contextBefore: ArchivePageSizing.anchorBefore,
                    contextAfter: ArchivePageSizing.anchorAfter,
                    priority: .target
                )
            }
        }

        if let realm = try? WRealm.safe(),
           let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
           ),
           chat.syncUnreadCount > 0,
           let rawUnreadBoundary = chat.syncUnreadAfterId,
           let boundary = ArchiveCursor(rawValue: rawUnreadBoundary) {
            return ArchiveWindowIntent(
                conversation: conversation,
                locator: .firstUnread(after: boundary),
                contextBefore: ArchivePageSizing.anchorBefore,
                contextAfter: ArchivePageSizing.initial,
                priority: .visibleIntegrity
            )
        }
        return ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
    }

    private func receiveArchiveWindowState(_ state: ArchiveWindowState) {
        assert(Thread.isMainThread)
        guard archiveEnginePresentationActive else { return }
        if case .verified(let incoming) = state,
           ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: archiveWindowState,
                committedCoverageGeneration: archiveWindowCommittedCoverageGeneration,
                pendingSnapshot: archiveWindowPendingSnapshot,
                incoming: incoming
           ) {
            return
        }
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        let preservesCommittedContent: Bool
        if case .verified(let incoming) = state {
            preservesCommittedContent =
                ChatArchiveWindowPresentationPolicy.shouldPreserveCommittedContent(
                    currentState: archiveWindowState,
                    committedCoverageGeneration: archiveWindowCommittedCoverageGeneration,
                    incoming: incoming
                )
        } else {
            preservesCommittedContent = false
        }
        archiveWindowState = state
        archiveWindowApplyGeneration &+= 1
        let applyGeneration = archiveWindowApplyGeneration
        switch state {
        case .skeleton, .retryableFailure:
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowPendingSnapshot = nil
            archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
            cancelDatasetMappingJobs()
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            refreshArchiveBoundaryLoadingIndicator()
        case .verified(let snapshot):
            archiveWindowPendingSnapshot = snapshot
            if !preservesCommittedContent {
                archiveWindowCommittedCoverageGeneration = nil
                setSkeletonVisible(true)
                setDatasourceLoadingEnabled(false)
            }
            refreshArchiveBoundaryLoadingIndicator()
            applyArchiveEngineVerifiedSnapshot(
                snapshot,
                applyGeneration: applyGeneration
            )
        case .authoritativeEmpty:
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowPendingSnapshot = nil
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            refreshArchiveBoundaryLoadingIndicator()
            applyArchiveEngineAuthoritativeEmpty(applyGeneration: applyGeneration)
        }
    }

    private func receiveArchiveWindowActivity(_ activity: ArchiveWindowActivity) {
        assert(Thread.isMainThread)
        guard archiveEnginePresentationActive else { return }
        archiveWindowActivity = activity
        refreshArchiveBoundaryLoadingIndicator()
    }

    private func refreshArchiveBoundaryLoadingIndicator() {
        setArchiveLoading(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: archiveWindowActivity,
                pendingPresentationTarget: archiveWindowPendingSnapshot?.target,
                isShowingFullSkeleton: showSkeletonObserver.value
            )
        )
    }

    private func applyArchiveEngineVerifiedSnapshot(
        _ snapshot: ArchiveWindowSnapshot,
        applyGeneration: UInt64
    ) {
        guard let session = timelineSession else { return }
        let mappingJob = beginDatasetMappingJob()
        let mappingContext = captureDatasourceMappingContext()

        datasetMappingQueue.async { [weak self, weak session] in
            guard let self, let session,
                  !mappingJob.token.isCancelled,
                  let committed = session.installArchiveEngineVerifiedWindow(
                    primaryIDs: snapshot.messagePrimaryIDs,
                    segment: snapshot.verifiedSegment
                  ) else {
                return
            }
            let mappingResult = self.mapDataset(
                dataset: committed.items,
                context: mappingContext,
                cancellationToken: mappingJob.token
            )
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session,
                      self.timelineSession === session,
                      self.archiveEnginePresentationActive,
                      self.archiveWindowApplyGeneration == applyGeneration,
                      self.datasetMappingGeneration == mappingJob.generation,
                      !mappingJob.token.isCancelled,
                      !mappingResult.wasCancelled,
                      case .verified(let current) = self.archiveWindowState,
                      current == snapshot else {
                    return
                }
                self.activeHistoryBoundaryPlaceholder = nil
                self.syncCurrentPage(
                    with: ChatDatasetWindow(
                        minIndex: 0,
                        maxIndex: committed.items.count
                    )
                )
                let forceBottom =
                    ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                        for: snapshot.target,
                        itemCount: committed.items.count
                    )
                let boundaryDirection =
                    ChatArchiveWindowPresentationPolicy.boundaryDirection(
                        for: snapshot.target
                    )
                let mappedPrimaryIDs = Set(mappingResult.datasource.map(\.primary))
                let liveAnchorCandidate = boundaryDirection.flatMap {
                    self.captureArchiveEngineBoundaryAnchor(direction: $0)
                }
                let liveAnchor = liveAnchorCandidate.flatMap {
                    mappedPrimaryIDs.contains($0.primary) ? $0 : nil
                }
                let retainedAnchorCandidate = self.archiveWindowBoundaryPresentationAnchor
                    .flatMap { retained in
                        retained.locator == snapshot.target &&
                            retained.direction == boundaryDirection
                            ? retained.anchor
                            : nil
                    }
                let retainedAnchor = retainedAnchorCandidate.flatMap {
                    mappedPrimaryIDs.contains($0.primary) ? $0 : nil
                }
                let restoreAnchor =
                    ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                        for: snapshot.target,
                        live: liveAnchor,
                        retained: retainedAnchor
                    )
                let applyPlan =
                    ChatArchiveWindowPresentationPolicy.boundaryApplyPlan(
                        for: snapshot.target,
                        hasCapturedAnchor: restoreAnchor != nil
                    )
                let usesBoundaryRecoverySkeleton =
                    ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                        for: snapshot.target,
                        hasUsableAnchor: restoreAnchor != nil,
                        hasCommittedContent: self.datasource.contains { !$0.isFakeMessage }
                    )
                let effectiveForceBottom = forceBottom ?? (
                    usesBoundaryRecoverySkeleton ? .newestRealMessage : nil
                )
                if usesBoundaryRecoverySkeleton {
                    self.setArchiveLoading(false)
                    self.setSkeletonVisible(true)
                    self.setDatasourceLoadingEnabled(false)
                }
                if boundaryDirection != nil {
                    ChatArchiveDebugTrace.log("archiveEngineBoundaryApplyPlan", [
                        ("hasLiveAnchorCandidate", liveAnchorCandidate != nil),
                        ("hasRetainedAnchorCandidate", retainedAnchorCandidate != nil),
                        ("hasLiveAnchor", liveAnchor != nil),
                        ("hasRetainedAnchor", retainedAnchor != nil),
                        ("hasResolvedAnchor", restoreAnchor != nil),
                        ("keepOffset", applyPlan.keepOffset),
                        ("recoverySkeleton", usesBoundaryRecoverySkeleton),
                        ("itemCount", mappingResult.datasource.count)
                    ])
                }
                self.applyChatDatasource(
                    mappingResult.datasource,
                    mode: .fullReload(keepOffset: applyPlan.keepOffset),
                    animated: false,
                    invalidateLayout: false,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: effectiveForceBottom == nil,
                    forceBottomAlignmentTarget: effectiveForceBottom,
                    applyCategory: applyPlan.applyCategory,
                    anchorRestorePhase: applyPlan.restorePhase,
                    anchorPrimary: restoreAnchor?.primary,
                    restoreAnchor: restoreAnchor,
                    presentationOwner: .archiveEngine,
                    presentationCommitMode: .atomicInitialFrame,
                    transactionCompletion: { [weak self] result in
                        self?.handleArchiveEngineAtomicApplyResult(
                            result,
                            snapshot: snapshot,
                            applyGeneration: applyGeneration
                        )
                    },
                    completion: { [weak self] in
                        guard let self,
                              self.archiveWindowApplyGeneration == applyGeneration,
                              case .verified(let current) = self.archiveWindowState,
                              current == snapshot else {
                            return
                        }
                        self.archiveWindowCommittedCoverageGeneration =
                            snapshot.coverageGeneration
                        self.archiveWindowPendingSnapshot = nil
                        if self.archiveWindowBoundaryPresentationAnchor?.locator == snapshot.target {
                            self.archiveWindowBoundaryPresentationAnchor = nil
                        }
                        self.archiveWindowAtomicApplyRetryWorkItem?.cancel()
                        self.archiveWindowAtomicApplyRetryWorkItem = nil
                        self.archiveWindowAtomicApplyRetryCount = 0
                        self.recordArchiveSkeletonTerminalIfNeeded()
                        ArchiveEngineObservability.event(
                            .uikitApply,
                            value: snapshot.messagePrimaryIDs.count
                        )
                        self.setSkeletonVisible(false)
                        self.refreshArchiveBoundaryLoadingIndicator()
                        self.setDatasourceLoadingEnabled(true)
                        if self.pendingOpenMessageRequest != nil {
                            self.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
                        }
                    }
                )
            }
        }
    }

    private func captureArchiveEngineBoundaryAnchor(
        direction: ChatHistoryPageDirection
    ) -> ChatHistoryPageAnchor? {
        if let visibleAnchor = capturePagingAnchorIfNeeded(direction: direction) {
            return visibleAnchor
        }

        let realSections = datasource.indices.filter { !datasource[$0].isFakeMessage }
        let boundarySection: Int?
        switch direction {
        case .older:
            boundarySection = realSections.first
        case .newer:
            boundarySection = realSections.last
        }
        guard let boundarySection else { return nil }

        messagesCollectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: 0, section: boundarySection)
        let attributes = messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? messagesCollectionView.cellForItem(at: indexPath)?.frame
        guard let frame else { return nil }

        return ChatHistoryPageAnchor(
            primary: datasource[boundarySection].primary,
            viewportRelativeMinY: frame.minY - messagesCollectionView.contentOffset.y
        )
    }

    private func handleArchiveEngineAtomicApplyResult(
        _ result: ChatViewportTransactionResult,
        snapshot: ArchiveWindowSnapshot,
        applyGeneration: UInt64
    ) {
        guard case .failed(let failure, _) = result,
              archiveEnginePresentationActive,
              archiveWindowApplyGeneration == applyGeneration,
              archiveWindowPendingSnapshot == snapshot,
              case .verified(let current) = archiveWindowState,
              current == snapshot,
              ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: failure,
                completedRetryCount: archiveWindowAtomicApplyRetryCount
              ) else {
            return
        }
        archiveWindowAtomicApplyRetryCount += 1
        scheduleArchiveEngineAtomicApplyRetry(
            snapshot: snapshot,
            applyGeneration: applyGeneration,
            remainingMotionChecks: 20
        )
    }

    private func scheduleArchiveEngineAtomicApplyRetry(
        snapshot: ArchiveWindowSnapshot,
        applyGeneration: UInt64,
        remainingMotionChecks: Int
    ) {
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.archiveEnginePresentationActive,
                  self.archiveWindowApplyGeneration == applyGeneration,
                  self.archiveWindowPendingSnapshot == snapshot,
                  case .verified(let current) = self.archiveWindowState,
                  current == snapshot else {
                return
            }
            if self.currentScrollMotionState() != .resting,
               remainingMotionChecks > 0 {
                self.scheduleArchiveEngineAtomicApplyRetry(
                    snapshot: snapshot,
                    applyGeneration: applyGeneration,
                    remainingMotionChecks: remainingMotionChecks - 1
                )
                return
            }
            self.archiveWindowAtomicApplyRetryWorkItem = nil
            self.applyArchiveEngineVerifiedSnapshot(
                snapshot,
                applyGeneration: applyGeneration
            )
        }
        archiveWindowAtomicApplyRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.15,
            execute: workItem
        )
    }

    private func applyArchiveEngineAuthoritativeEmpty(applyGeneration: UInt64) {
        guard let session = timelineSession else { return }
        let mappingJob = beginDatasetMappingJob()
        let mappingContext = captureDatasourceMappingContext()
        datasetMappingQueue.async { [weak self, weak session] in
            guard let self, let session, !mappingJob.token.isCancelled else { return }
            _ = session.installArchiveEngineAuthoritativeEmpty()
            let mappingResult = self.mapDataset(
                dataset: [],
                context: mappingContext,
                cancellationToken: mappingJob.token
            )
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session,
                      self.timelineSession === session,
                      self.archiveEnginePresentationActive,
                      self.archiveWindowApplyGeneration == applyGeneration,
                      self.datasetMappingGeneration == mappingJob.generation,
                      !mappingJob.token.isCancelled,
                      !mappingResult.wasCancelled,
                      case .authoritativeEmpty = self.archiveWindowState else {
                    return
                }
                self.syncCurrentPage(with: .empty)
                self.applyChatDatasource(
                    [],
                    mode: .fullReload(keepOffset: false),
                    animated: false,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: true,
                    presentationOwner: .archiveEngine,
                    presentationCommitMode: .atomicInitialFrame,
                    completion: { [weak self] in
                        guard let self,
                              self.archiveWindowApplyGeneration == applyGeneration,
                              case .authoritativeEmpty = self.archiveWindowState else {
                            return
                        }
                        self.archiveWindowCommittedCoverageGeneration = 0
                        self.archiveWindowPendingSnapshot = nil
                        self.recordArchiveSkeletonTerminalIfNeeded()
                        ArchiveEngineObservability.event(.uikitApply)
                        self.setSkeletonVisible(false)
                        self.refreshArchiveBoundaryLoadingIndicator()
                        self.setDatasourceLoadingEnabled(true)
                    }
                )
            }
        }
    }

    private func recordArchiveSkeletonTerminalIfNeeded() {
        guard let beganAt = archiveSkeletonBeganAt else { return }
        archiveSkeletonBeganAt = nil
        ArchiveEngineObservability.event(
            .skeletonDuration,
            value: max(0, Int(Date().timeIntervalSince(beganAt) * 1_000))
        )
    }
}
