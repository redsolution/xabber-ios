import Foundation
import UIKit

enum ChatArchiveWindowPresentationPolicy {
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
              expectedPrimaryIDs.isNotEmpty,
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
                oldestArchiveId: oldest?.archivedId,
                newestArchiveId: newest?.archivedId
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
        archiveEnginePresentationActive = true
        archiveWindowCommittedCoverageGeneration = nil
        archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)

        guard let account = AccountManager.shared.find(for: owner) else {
            archiveWindowState = .skeleton(reason: .offline, target: .latest)
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

        let intent = makeInitialArchiveWindowIntent()
        if archiveWindowIntent?.semanticDescriptor != intent.semanticDescriptor {
            archiveWindowIntent = intent
            archiveWindowState = .skeleton(reason: .opening, target: intent.locator)
        } else if archiveWindowIntent == nil {
            archiveWindowIntent = intent
        }
        Task { await account.archiveEngine.submit(intent) }
    }

    internal func stopArchiveEnginePresentationSubscription() {
        archiveWindowStateTask?.cancel()
        archiveWindowStateTask = nil
        archiveEnginePresentationActive = false
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
        archiveWindowCommittedCoverageGeneration = nil
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
        if priority >= .target {
            archiveWindowCommittedCoverageGeneration = nil
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
        }
        Task { await account.archiveEngine.submit(intent) }
    }

    internal func prefetchArchiveEngineWindowIfNeeded(indexPaths: [IndexPath]) {
        guard archiveEnginePresentationActive,
              case .verified(let snapshot) = archiveWindowState,
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
            archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
            cancelDatasetMappingJobs()
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
        case .verified(let snapshot):
            if !preservesCommittedContent {
                archiveWindowCommittedCoverageGeneration = nil
                setSkeletonVisible(true)
                setDatasourceLoadingEnabled(false)
            }
            applyArchiveEngineVerifiedSnapshot(
                snapshot,
                applyGeneration: applyGeneration
            )
        case .authoritativeEmpty:
            archiveWindowCommittedCoverageGeneration = nil
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            applyArchiveEngineAuthoritativeEmpty(applyGeneration: applyGeneration)
        }
    }

    private func applyArchiveEngineVerifiedSnapshot(
        _ snapshot: ArchiveWindowSnapshot,
        applyGeneration: UInt64
    ) {
        guard let session = timelineSession else { return }
        let mappingJob = beginDatasetMappingJob()
        let mappingContext = captureDatasourceMappingContext()
        let restoreDirection: ChatHistoryPageDirection = {
            if case .newer = snapshot.target { return .newer }
            return .older
        }()
        let restoreAnchor = capturePagingAnchorIfNeeded(direction: restoreDirection)

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
                let forceBottom: ChatBottomAlignmentTarget? = {
                    if case .latest = snapshot.target { return .newestRealMessage }
                    return nil
                }()
                self.applyChatDatasource(
                    mappingResult.datasource,
                    mode: .fullReload(keepOffset: restoreAnchor != nil),
                    animated: false,
                    invalidateLayout: false,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: forceBottom == nil,
                    forceBottomAlignmentTarget: forceBottom,
                    anchorRestorePhase: restoreAnchor == nil ? .none : .applyTransaction,
                    anchorPrimary: restoreAnchor?.primary,
                    restoreAnchor: restoreAnchor,
                    presentationCommitMode: .atomicInitialFrame,
                    completion: { [weak self] in
                        guard let self,
                              self.archiveWindowApplyGeneration == applyGeneration,
                              case .verified(let current) = self.archiveWindowState,
                              current == snapshot else {
                            return
                        }
                        self.archiveWindowCommittedCoverageGeneration =
                            snapshot.coverageGeneration
                        self.recordArchiveSkeletonTerminalIfNeeded()
                        ArchiveEngineObservability.event(
                            .uikitApply,
                            value: snapshot.messagePrimaryIDs.count
                        )
                        self.setSkeletonVisible(false)
                        self.setDatasourceLoadingEnabled(true)
                        if self.pendingOpenMessageRequest != nil {
                            self.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
                        }
                    }
                )
            }
        }
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
                    presentationCommitMode: .atomicInitialFrame,
                    completion: { [weak self] in
                        guard let self,
                              self.archiveWindowApplyGeneration == applyGeneration,
                              case .authoritativeEmpty = self.archiveWindowState else {
                            return
                        }
                        self.archiveWindowCommittedCoverageGeneration = 0
                        self.recordArchiveSkeletonTerminalIfNeeded()
                        ArchiveEngineObservability.event(.uikitApply)
                        self.setSkeletonVisible(false)
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
