import Foundation
import UIKit

struct ChatArchiveBoundaryPresentationAnchor {
    let locator: ArchiveWindowLocator
    let direction: ChatHistoryPageDirection
    let anchor: ChatHistoryPageAnchor
}

enum ChatArchiveVerifiedMaterializationFailurePresentation: Equatable {
    case preserveContent
    case fullSkeleton
}

enum ChatTimelineBoundaryRequestPhase: Equatable {
    case preparingLocal
    case applyingLocal
    case waitingRemote
}

enum ChatTimelineLocalBoundaryFailure: Equatable {
    case sessionGenerationChanged
    case mappingCancelled
    case atomicApplySuperseded
    case transientAtomicApplyFailure
    case invalidProof
    case connectionOrTargetReplaced
}

enum ChatTimelineLocalBoundaryRecoveryDisposition: Equatable {
    case retryLocal
    case dropSilent
    case failClosed
}

enum ChatTimelineLocalBoundaryRecoveryPolicy {
    /// Local Realm/UIKit churn is intentionally bounded. Once this budget is
    /// exhausted, a still-verified timeline remains visible and the boundary
    /// request terminates silently; an invalid proof fails closed separately.
    static let maximumRetryCount = 3

    static func disposition(
        for failure: ChatTimelineLocalBoundaryFailure,
        isVisible: Bool,
        retainsVerifiedProof: Bool,
        completedRetryCount: Int
    ) -> ChatTimelineLocalBoundaryRecoveryDisposition {
        guard retainsVerifiedProof else { return .failClosed }
        switch failure {
        case .invalidProof, .connectionOrTargetReplaced:
            return .failClosed
        case .sessionGenerationChanged,
             .mappingCancelled,
             .atomicApplySuperseded,
             .transientAtomicApplyFailure:
            guard isVisible else { return .dropSilent }
            guard completedRetryCount < maximumRetryCount else {
                return .dropSilent
            }
            return .retryLocal
        }
    }

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        Double(max(1, min(attempt, 10))) * 0.05
    }
}

enum ChatArchiveHistoryAutomaticRetryPolicy {
    static func delay(
        actorFailureCount: Int,
        presentationAttempt: Int
    ) -> TimeInterval {
        let actorBackoff = min(
            5.0,
            Double(max(1, actorFailureCount)) * 0.5
        )
        let exponent = max(0, min(presentationAttempt - 1, 6))
        return min(30.0, actorBackoff * Double(1 << exponent))
    }
}

enum ChatCommittedTimelineLocalPresentationPurpose: Equatable {
    case boundary
    case localTarget
    case sensitiveReveal
}

struct ChatCommittedTimelineLocalPresentationToken: Equatable {
    let id: UUID
    let purpose: ChatCommittedTimelineLocalPresentationPurpose
    let scope: ChatTimelineVerifiedScope
    let sessionGeneration: UInt64
    let applyGeneration: UInt64
}

enum ChatCommittedTimelineSensitiveRevealRetryPolicy {
    static let maximumRetryCount = 1

    static func shouldRetry(
        remainsInCommittedScope: Bool,
        hasNewRevealRequest: Bool,
        didFail: Bool,
        retryCount: Int
    ) -> Bool {
        guard remainsInCommittedScope else { return false }
        if hasNewRevealRequest {
            return true
        }
        return didFail && retryCount < maximumRetryCount
    }
}

enum ChatAuthoritativeEmptyPendingTargetAction: Equatable {
    case submitArchiveTarget
    case failTargetMissing
}

enum ChatAuthoritativeEmptyPendingTargetPolicy {
    static func action(
        emptyTarget: ArchiveWindowLocator,
        requestedTarget: ArchiveWindowLocator?
    ) -> ChatAuthoritativeEmptyPendingTargetAction {
        guard let requestedTarget,
              requestedTarget != emptyTarget else {
            return .failTargetMissing
        }
        return .submitArchiveTarget
    }
}

struct ChatTimelineBoundaryRequestContext {
    let id: UUID
    let direction: ChatHistoryPageDirection
    let scope: ChatTimelineVerifiedScope
    let locator: ArchiveWindowLocator
    var baseGeneration: UInt64
    let applyGeneration: UInt64
    let anchor: ChatHistoryPageAnchor?
    let owningPresentationIntentID: UUID?
    var isVisible: Bool
    var phase: ChatTimelineBoundaryRequestPhase
    var localRecoveryAttempt: Int = 0
    var allowsArchiveExpansion = true
    var remoteIntentID: UUID? = nil
    var remoteTerminal: ArchiveBoundaryTerminalResult? = nil
    var didWinUIKitApply = false
}

private final class ChatTimelineBoundaryCommitReceipt {
    var snapshot: ChatTimelineSessionSnapshot?
    var didCommitInitialTargetFirstFrame = false
    var initialTargetFirstFrameRequest: ChatOpenMessageRequest?
#if DEBUG || CHAT_PERFORMANCE_LAB
    var viewportDiagnostics: ChatViewportTransactionDiagnostics?
#endif
}

private final class ChatTimelineLiveEdgeCommitReceipt {
    var result: ChatTimelineCommittedLiveEdgeAdmission?
    var rollbackSnapshot: ChatTimelineSessionSnapshot?
}

enum ChatArchiveWindowPresentationPolicy {
    static func authorizesCommittedTimelineScope(
        state: ArchiveWindowState?,
        committedCoverageGeneration: UInt64?,
        sessionScope: ChatTimelineVerifiedScope?,
        requiredScope: ChatTimelineVerifiedScope?,
        conversationKey: ChatTimelineConversationKey,
        isShowingSkeleton: Bool,
        hasPendingPresentation: Bool
    ) -> Bool {
        guard !isShowingSkeleton,
              !hasPendingPresentation,
              let state,
              let sessionScope,
              sessionScope.coverageGeneration > 0,
              sessionScope.conversationKey == conversationKey,
              requiredScope.map({ $0 == sessionScope }) ?? true,
              committedCoverageGeneration ==
                sessionScope.coverageGeneration else {
            return false
        }

        switch state {
        case .verified(let snapshot):
            guard case .sessionMAM(let connectionGeneration, _) =
                    snapshot.freshnessToken else {
                return false
            }
            return snapshot.verifiedSegment.isVerified &&
                snapshot.verifiedSegment.fingerprint ==
                    snapshot.freshnessToken.fingerprint &&
                snapshot.coverageGeneration <=
                    sessionScope.coverageGeneration &&
                sessionScope.freshnessFingerprint ==
                    snapshot.freshnessToken.fingerprint &&
                sessionScope.connectionGeneration == connectionGeneration
        case .authoritativeEmpty(_, let freshnessToken):
            guard case .sessionMAM(let connectionGeneration, _) =
                    freshnessToken else {
                return false
            }
            return sessionScope.freshnessFingerprint ==
                    freshnessToken.fingerprint &&
                sessionScope.connectionGeneration == connectionGeneration &&
                sessionScope.reachesArchiveStart &&
                sessionScope.reachesLiveEdge
        case .skeleton, .retryableFailure:
            return false
        }
    }

    static func hasCommittedVerifiedScope(
        snapshot: ArchiveWindowSnapshot,
        committedCoverageGeneration: UInt64?,
        scope: ChatTimelineVerifiedScope
    ) -> Bool {
        authorizesCommittedTimelineScope(
            state: .verified(snapshot),
            committedCoverageGeneration: committedCoverageGeneration,
            sessionScope: scope,
            requiredScope: scope,
            conversationKey: scope.conversationKey,
            isShowingSkeleton: false,
            hasPendingPresentation: false
        )
    }

    static func hasCommittedLiveScope(
        afterAuthoritativeEmpty freshnessToken: ArchiveFreshnessToken,
        committedCoverageGeneration: UInt64?,
        scope: ChatTimelineVerifiedScope?
    ) -> Bool {
        guard let scope else { return false }
        return authorizesCommittedTimelineScope(
            state: .authoritativeEmpty(
                target: .latest,
                freshnessToken: freshnessToken
            ),
            committedCoverageGeneration: committedCoverageGeneration,
            sessionScope: scope,
            requiredScope: scope,
            conversationKey: scope.conversationKey,
            isShowingSkeleton: false,
            hasPendingPresentation: false
        )
    }

    static func shouldAccept(
        state: ArchiveWindowState,
        for intent: ArchiveWindowIntent?
    ) -> Bool {
        guard let intent else { return false }
        let stateTarget: ArchiveWindowLocator
        switch state {
        case .skeleton(_, let target),
             .authoritativeEmpty(let target, _),
             .retryableFailure(_, let target):
            stateTarget = target
        case .verified(let snapshot):
            stateTarget = snapshot.target
        }
        return stateTarget == intent.locator
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
        pendingRequestTarget: ArchiveWindowLocator? = nil,
        pendingPresentationTarget: ArchiveWindowLocator? = nil,
        isShowingFullSkeleton: Bool
    ) -> Bool {
        guard !isShowingFullSkeleton else { return false }
        return activity.isLoadingBoundary ||
            pendingRequestTarget.map(isBoundaryExpansion) == true ||
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
        isShowingSkeleton: Bool,
        verifiedScope: ChatTimelineVerifiedScope? = nil
    ) -> Bool {
        guard !isShowingSkeleton else { return false }
        if let verifiedScope {
            return hasCommittedVerifiedScope(
                snapshot: snapshot,
                committedCoverageGeneration: committedCoverageGeneration,
                scope: verifiedScope
            )
        }
        return committedCoverageGeneration.map {
            $0 >= snapshot.coverageGeneration
        } ?? false
    }

    static func shouldDeferOpenMessageRequest(
        isPresentationActive: Bool,
        state: ArchiveWindowState?,
        committedCoverageGeneration: UInt64?,
        pendingSnapshot: ArchiveWindowSnapshot?,
        isShowingSkeleton: Bool,
        verifiedScope: ChatTimelineVerifiedScope? = nil
    ) -> Bool {
        guard isPresentationActive else { return false }
        guard pendingSnapshot == nil,
              !isShowingSkeleton,
              let state else {
            return true
        }
        switch state {
        case .verified(let snapshot):
            if let verifiedScope {
                return !hasCommittedVerifiedScope(
                    snapshot: snapshot,
                    committedCoverageGeneration:
                        committedCoverageGeneration,
                    scope: verifiedScope
                )
            }
            return !(committedCoverageGeneration.map {
                $0 >= snapshot.coverageGeneration
            } ?? false)
        case .authoritativeEmpty(_, let freshnessToken):
            return !hasCommittedLiveScope(
                afterAuthoritativeEmpty: freshnessToken,
                committedCoverageGeneration:
                    committedCoverageGeneration,
                scope: verifiedScope
            )
        case .skeleton, .retryableFailure:
            return true
        }
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

    static func materializationFailurePresentation(
        for locator: ArchiveWindowLocator,
        hasCommittedContent: Bool
    ) -> ChatArchiveVerifiedMaterializationFailurePresentation {
        guard boundaryDirection(for: locator) != nil,
              hasCommittedContent else {
            return .fullSkeleton
        }
        return .preserveContent
    }

    static func shouldShowFullSkeleton(
        for state: ArchiveWindowState,
        committedCoverageGeneration: UInt64?,
        verifiedScope: ChatTimelineVerifiedScope? = nil
    ) -> Bool {
        switch state {
        case .skeleton, .retryableFailure:
            return true
        case .verified(let snapshot):
            if let verifiedScope {
                return !hasCommittedVerifiedScope(
                    snapshot: snapshot,
                    committedCoverageGeneration:
                        committedCoverageGeneration,
                    scope: verifiedScope
                )
            }
            return !(committedCoverageGeneration.map {
                $0 >= snapshot.coverageGeneration
            } ?? false)
        case .authoritativeEmpty(_, let freshnessToken):
            if committedCoverageGeneration == 0,
               verifiedScope == nil {
                return false
            }
            return !hasCommittedLiveScope(
                afterAuthoritativeEmpty: freshnessToken,
                committedCoverageGeneration:
                    committedCoverageGeneration,
                scope: verifiedScope
            )
        }
    }

    static func shouldPreserveCommittedContent(
        currentState: ArchiveWindowState?,
        committedCoverageGeneration: UInt64?,
        incoming: ArchiveWindowSnapshot,
        currentVerifiedScope: ChatTimelineVerifiedScope? = nil
    ) -> Bool {
        guard case .verified(let current) = currentState else {
            return false
        }
        let hasCommittedContent: Bool
        if let currentVerifiedScope {
            hasCommittedContent = hasCommittedVerifiedScope(
                snapshot: current,
                committedCoverageGeneration: committedCoverageGeneration,
                scope: currentVerifiedScope
            )
        } else {
            hasCommittedContent = committedCoverageGeneration.map {
                $0 >= current.coverageGeneration
            } ?? false
        }
        guard hasCommittedContent else { return false }
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

enum ChatArchiveLiveEdgePresentationPolicy {
    static func shouldAccept(
        _ admission: ArchiveLiveEdgeAdmission,
        currentIntent: ArchiveWindowIntent?,
        currentScope: ChatTimelineVerifiedScope?,
        currentState: ArchiveWindowState?
    ) -> Bool {
        guard let currentIntent else { return false }
        let continuesThroughDirectionalPaging: Bool
        switch currentIntent.locator {
        case .older, .newer, .gap:
            continuesThroughDirectionalPaging =
                admission.presentationIntent.conversation ==
                    currentIntent.conversation
        case .latest, .firstUnread, .archiveID, .timestamp:
            continuesThroughDirectionalPaging = false
        }
        guard (admission.presentationIntent == currentIntent.semanticDescriptor ||
                continuesThroughDirectionalPaging),
              admission.conversation == currentIntent.conversation,
              admission.latestWindow.target == .latest,
              admission.latestWindow.messagePrimaryIDs.contains(
                admission.primaryID
              ) else {
            return false
        }
        guard let currentScope else {
            guard case .authoritativeEmpty(_, let freshnessToken) = currentState
            else {
                return false
            }
            return admission.latestWindow.coverageGeneration > 0 &&
                admission.latestWindow.verifiedSegment.reachesArchiveStart &&
                admission.latestWindow.verifiedSegment.reachesLiveEdge &&
                admission.latestWindow.freshnessToken.fingerprint ==
                    freshnessToken.fingerprint
        }
        guard
              let incomingScope = ChatTimelineVerifiedScope(
                conversationKey: currentScope.conversationKey,
                segment: admission.latestWindow.verifiedSegment,
                coverageGeneration:
                    admission.latestWindow.coverageGeneration,
                freshnessToken: admission.latestWindow.freshnessToken
              ),
              currentScope.reachesLiveEdge,
              incomingScope.reachesLiveEdge,
              incomingScope.connectionGeneration ==
                currentScope.connectionGeneration,
              incomingScope.freshnessFingerprint ==
                currentScope.freshnessFingerprint,
              incomingScope.coverageGeneration >=
                currentScope.coverageGeneration,
              incomingScope.canExtend(currentScope, direction: .newer),
              incomingScope.coverageGeneration >
                currentScope.coverageGeneration || incomingScope == currentScope else {
            return false
        }
        return true
    }
}

enum ChatArchiveLiveEdgeRepreparePolicy {
    static let maximumRetryCount = 1

    static func shouldReprepare(
        remainsCurrent: Bool,
        completedRetryCount: Int
    ) -> Bool {
        remainsCurrent && completedRetryCount < maximumRetryCount
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
            isResidentAtLiveTail: segment.reachesLiveEdge
        )
        return ChatTimelineSnapshot(
            items: ordered,
            state: state,
            anchorRestore: nil
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

    internal func committedTimelineScope(
        matching requiredScope: ChatTimelineVerifiedScope? = nil,
        allowingLocalPresentationID: UUID? = nil,
        allowsPendingLiveEdgeAdmission: Bool = false
    ) -> ChatTimelineVerifiedScope? {
        guard let session = timelineSession,
              let scope = session.verifiedScope else {
            return nil
        }
        if let token = committedTimelineLocalPresentationToken,
           token.id == allowingLocalPresentationID,
           (token.scope != scope ||
                token.applyGeneration != archiveWindowApplyGeneration) {
            return nil
        }
        let hasForeignLocalPresentation =
            committedTimelineLocalPresentationToken.map {
                $0.id != allowingLocalPresentationID
            } ?? false
        let hasPendingPresentation =
            archiveWindowPendingSnapshot != nil ||
            archiveWindowAuthoritativeEmptyApplyGeneration != nil ||
            (!allowsPendingLiveEdgeAdmission &&
                archiveWindowPendingLiveEdgeAdmission != nil) ||
            archiveWindowLiveEdgeApplyGeneration != nil ||
            archiveWindowAtomicApplyRetryWorkItem != nil ||
            hasForeignLocalPresentation
        guard ChatArchiveWindowPresentationPolicy
                .authorizesCommittedTimelineScope(
                    state: archiveWindowState,
                    committedCoverageGeneration:
                        archiveWindowCommittedCoverageGeneration,
                    sessionScope: scope,
                    requiredScope: requiredScope,
                    conversationKey: chatTimelineConversationKey,
                    isShowingSkeleton: showSkeletonObserver.value,
                    hasPendingPresentation: hasPendingPresentation
                ) else {
            return nil
        }
        return scope
    }

    @discardableResult
    internal func beginCommittedTimelineLocalPresentation(
        _ token: ChatCommittedTimelineLocalPresentationToken
    ) -> Bool {
        assert(Thread.isMainThread)
        guard committedTimelineLocalPresentationToken == nil,
              archiveWindowApplyGeneration == token.applyGeneration,
              let session = timelineSession,
              session.snapshot.generation == token.sessionGeneration,
              session.verifiedScope == token.scope else {
            return false
        }
        committedTimelineLocalPresentationToken = token
        return true
    }

    internal func finishCommittedTimelineLocalPresentation(id: UUID) {
        assert(Thread.isMainThread)
        guard committedTimelineLocalPresentationToken?.id == id else {
            return
        }
        committedTimelineLocalPresentationToken = nil
    }

    internal func drainTimelinePresentationLanesAfterAnchorTerminal() {
        assert(Thread.isMainThread)
        guard !anchorTransactionGate.snapshot.positioningStarted else {
            return
        }
        if drainDeferredArchiveEnginePresentationAfterAnchorPositioning() {
            return
        }
        #if DEBUG || CHAT_PERFORMANCE_LAB
        timelinePresentationLaneDrainObserverForTests?(.store)
        #endif
        drainPendingTimelineStoreSnapshot()
        #if DEBUG || CHAT_PERFORMANCE_LAB
        timelinePresentationLaneDrainObserverForTests?(.sensitiveReveal)
        #endif
        drainPendingCommittedTimelineSensitiveRevealRemap()
        #if DEBUG || CHAT_PERFORMANCE_LAB
        timelinePresentationLaneDrainObserverForTests?(.liveEdge)
        #endif
        drainPendingArchiveLiveEdgeAdmission()
    }

    internal func invalidateCommittedTimelineLocalPresentation() {
        assert(Thread.isMainThread)
        committedTimelineLocalPresentationToken = nil
        committedTimelineSensitiveRevealRemapPending = false
        committedTimelineSensitiveRevealRemapRetryCount = 0
    }

    internal func beginArchiveInteractiveCriticalSection() {
        assert(Thread.isMainThread)
        if let gate = archiveInteractiveGate,
           let token = archiveInteractiveGateToken {
            _ = gate.release(token)
        }
        archiveInteractiveGateToken = nil
        guard let account = AccountManager.shared.find(for: owner) else {
            archiveInteractiveGate = nil
            return
        }
        let gate = account.interactiveChatOpenGate
        archiveInteractiveGate = gate
        archiveInteractiveGateToken = gate.acquire()
    }

    internal func endArchiveInteractiveCriticalSection() {
        assert(Thread.isMainThread)
        if let gate = archiveInteractiveGate,
           let token = archiveInteractiveGateToken {
            _ = gate.release(token)
        }
        archiveInteractiveGateToken = nil
        if archiveSearchInteractiveGateToken == nil {
            archiveInteractiveGate = nil
        }
    }

    internal func beginArchiveSearchInteractiveCriticalSection(queryID: String) {
        assert(Thread.isMainThread)
        if let gate = archiveInteractiveGate,
           let token = archiveSearchInteractiveGateToken {
            _ = gate.release(token)
        }
        archiveSearchInteractiveGateToken = nil
        archiveSearchInteractiveGateQueryID = nil
        guard let account = AccountManager.shared.find(for: owner) else {
            if archiveInteractiveGateToken == nil {
                archiveInteractiveGate = nil
            }
            return
        }
        let gate = account.interactiveChatOpenGate
        archiveInteractiveGate = gate
        archiveSearchInteractiveGateToken = gate.acquire()
        archiveSearchInteractiveGateQueryID = queryID
    }

    internal func endArchiveSearchInteractiveCriticalSection(
        queryID: String? = nil
    ) {
        assert(Thread.isMainThread)
        if let queryID,
           archiveSearchInteractiveGateQueryID != queryID {
            return
        }
        if let gate = archiveInteractiveGate,
           let token = archiveSearchInteractiveGateToken {
            _ = gate.release(token)
        }
        archiveSearchInteractiveGateToken = nil
        archiveSearchInteractiveGateQueryID = nil
        if archiveInteractiveGateToken == nil {
            archiveInteractiveGate = nil
        }
    }

    private func invalidateArchiveEngineVerifiedScope() {
        invalidateProofScopedLocalTargetPreparation()
        invalidateCommittedTimelineLocalPresentation()
        timelineSession?.invalidateVerifiedScope()
    }

    internal func invalidateArchiveWindowAuthoritativeEmptyApply() {
        archiveWindowAuthoritativeEmptyApplyGeneration = nil
        archiveWindowAuthoritativeEmptyMappingGeneration = nil
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
    }

    internal func startArchiveEnginePresentationIfNeeded() {
        assert(Thread.isMainThread)
        let intent = makeInitialArchiveWindowIntent()
        let shouldResetPresentation =
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive:
                    archiveWindowStateTask != nil || archiveWindowActivityTask != nil,
                currentIntent: archiveWindowIntent,
                incomingIntent: intent
        )
        guard shouldResetPresentation else { return }
        cancelArchiveHistoryAutomaticRetry()
        invalidateArchiveEngineVerifiedScope()
        invalidateArchiveWindowAuthoritativeEmptyApply()
        cancelDatasetMappingJobs()
        scrollWorkScheduler.cancel()
        timelineBoundaryRequest = nil
        archiveWindowIntent = intent
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveWindowPendingLiveEdgeAdmission = nil
        archiveWindowLiveEdgeApplyGeneration = nil
        archiveWindowLiveEdgeReprepareCount = 0
        archiveWindowBoundaryLoadingTarget = nil
        let account = AccountManager.shared.find(for: owner)
        if account != nil {
            beginArchiveInteractiveCriticalSection()
        } else {
            endArchiveInteractiveCriticalSection()
        }
        archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
        archiveWindowState = .skeleton(reason: .opening, target: intent.locator)
        archiveWindowActivity = .idle
        setArchiveLoading(false)
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        guard commitArchiveEngineOpeningSkeletonSynchronously() else {
            endArchiveInteractiveCriticalSection()
            return
        }

        guard let account else {
            endArchiveInteractiveCriticalSection()
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowState = .skeleton(reason: .offline, target: .latest)
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            return
        }
        if archiveWindowStateTask == nil {
            let conversation = archiveEngineConversationKey
            archiveWindowStateTask = Task { @MainActor [weak self, weak account] in
                guard let account else { return }
                let states = await account.archiveEngine.states(for: conversation)
                for await state in states {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.receiveArchiveWindowState(state)
                }
            }
        }
        if archiveLiveEdgeAdmissionTask == nil {
            let conversation = archiveEngineConversationKey
            archiveLiveEdgeAdmissionTask = Task { @MainActor [weak self, weak account] in
                guard let account else { return }
                let admissions = await account.archiveEngine.liveEdgeAdmissions(
                    for: conversation
                )
                for await admission in admissions {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.receiveArchiveLiveEdgeAdmission(admission)
                }
            }
        }
        if archiveLocalOutgoingAdmissionTask == nil {
            let conversation = archiveEngineConversationKey
            archiveLocalOutgoingAdmissionTask = Task {
                @MainActor [weak self, weak account] in
                guard let account else { return }
                let admissions = await account.archiveEngine
                    .localOutgoingAdmissions(for: conversation)
                for await admission in admissions {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.receiveLocalOutgoingAdmission(admission)
                }
            }
        }
        if archiveWindowActivityTask == nil {
            let conversation = archiveEngineConversationKey
            archiveWindowActivityTask = Task { @MainActor [weak self, weak account] in
                guard let account else { return }
                let activities = await account.archiveEngine.activities(for: conversation)
                for await activity in activities {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.receiveArchiveWindowActivity(activity)
                }
            }
        }
        if archiveBoundaryTerminalTask == nil {
            let conversation = archiveEngineConversationKey
            archiveBoundaryTerminalTask = Task { @MainActor [weak self, weak account] in
                guard let account else { return }
                let terminals = await account.archiveEngine.boundaryTerminals(
                    for: conversation
                )
                for await outcome in terminals {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.receiveArchiveBoundaryTerminal(outcome)
                }
            }
        }
        if archiveSearchStateTask == nil {
            let conversation = archiveEngineConversationKey
            archiveSearchStateTask = Task { @MainActor [weak self, weak account] in
                guard let account else { return }
                let states = await account.archiveEngine.searchStates(
                    for: conversation
                )
                for await state in states {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.receiveArchiveEngineSearchState(state)
                }
            }
        }

        let demandID = UUID()
        let demandConversation = intent.conversation
        let demandEngine = account.archiveEngine
        archiveEnginePresentationDemandID = demandID
        archiveEnginePresentationDemandConversation = demandConversation
        archiveEnginePresentationDemandEngine = demandEngine
        let demandTask = Task {
            await demandEngine.attachPresentationDemand(
                for: demandConversation,
                demandID: demandID
            )
            guard !Task.isCancelled else { return }
            await demandEngine.submit(intent)
        }
        archiveEnginePresentationDemandTask = demandTask
    }

    internal func detachArchiveEnginePresentationDemand() {
        let demandID = archiveEnginePresentationDemandID
        let demandTask = archiveEnginePresentationDemandTask
        let demandConversation = archiveEnginePresentationDemandConversation
        let demandEngine = archiveEnginePresentationDemandEngine
        archiveEnginePresentationDemandID = nil
        archiveEnginePresentationDemandTask = nil
        archiveEnginePresentationDemandConversation = nil
        archiveEnginePresentationDemandEngine = nil
        demandTask?.cancel()
        if let demandID, let demandConversation, let demandEngine {
            Task {
                await demandTask?.value
                await demandEngine.detachPresentationDemand(
                    for: demandConversation,
                    demandID: demandID
                )
            }
        }
    }

    internal func stopArchiveEnginePresentationSubscription() {
        cancelArchiveHistoryAutomaticRetry()
        detachArchiveEnginePresentationDemand()
        invalidateArchiveEngineVerifiedScope()
        invalidateArchiveWindowAuthoritativeEmptyApply()
        archiveWindowStateTask?.cancel()
        archiveWindowStateTask = nil
        archiveLiveEdgeAdmissionTask?.cancel()
        archiveLiveEdgeAdmissionTask = nil
        archiveLocalOutgoingAdmissionTask?.cancel()
        archiveLocalOutgoingAdmissionTask = nil
        archiveLocalOutgoingAdmissionInFlightPrimaryIDs.removeAll()
        archiveWindowActivityTask?.cancel()
        archiveWindowActivityTask = nil
        archiveBoundaryTerminalTask?.cancel()
        archiveBoundaryTerminalTask = nil
        archiveSearchStateTask?.cancel()
        archiveSearchStateTask = nil
        archiveWindowActivity = .idle
        archiveWindowBoundaryLoadingTarget = nil
        timelineBoundaryRequest = nil
        setArchiveLoading(false)
        archiveWindowPendingSnapshot = nil
        archiveWindowPendingLiveEdgeAdmission = nil
        archiveWindowLiveEdgeApplyGeneration = nil
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        archiveWindowApplyGeneration &+= 1
        endArchiveInteractiveCriticalSection()
        endArchiveSearchInteractiveCriticalSection()
        cancelDatasetMappingJobs()
    }

    internal func cancelArchiveHistoryAutomaticRetry(
        resetAttempt: Bool = true
    ) {
        archiveHistoryAutomaticRetryEpoch &+= 1
        archiveHistoryAutomaticRetryWorkItem?.cancel()
        archiveHistoryAutomaticRetryWorkItem = nil
        if resetAttempt {
            archiveHistoryAutomaticRetryAttempt = 0
        }
    }

    /// Retries the actor-owned semantic intent after a short cancellable
    /// backoff. The controller does not rebuild a paging request, choose a
    /// cursor, or replace the current verified/skeleton presentation.
    private func scheduleArchiveHistoryAutomaticRetry(
        failureRetryCount: Int,
        expectedBoundaryRequestID: UUID? = nil
    ) {
        assert(Thread.isMainThread)
        cancelArchiveHistoryAutomaticRetry(resetAttempt: false)
        guard let intent = archiveWindowIntent else { return }

        archiveHistoryAutomaticRetryAttempt += 1
        let presentationAttempt = archiveHistoryAutomaticRetryAttempt

        let expectedIntentID = intent.id
        let expectedDescriptor = intent.semanticDescriptor
        let expectedConversation = intent.conversation
        let expectedApplyGeneration = archiveWindowApplyGeneration
        let retryEpoch = archiveHistoryAutomaticRetryEpoch
        let backoff = ChatArchiveHistoryAutomaticRetryPolicy.delay(
            actorFailureCount: failureRetryCount,
            presentationAttempt: presentationAttempt
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.archiveHistoryAutomaticRetryEpoch == retryEpoch,
                  self.archiveWindowStateTask != nil,
                  self.archiveWindowApplyGeneration == expectedApplyGeneration,
                  self.archiveEngineConversationKey == expectedConversation,
                  self.archiveWindowIntent?.id == expectedIntentID,
                  self.archiveWindowIntent?.semanticDescriptor ==
                    expectedDescriptor else {
                return
            }
            if let expectedBoundaryRequestID {
                guard let request = self.timelineBoundaryRequest,
                      request.id == expectedBoundaryRequestID,
                      request.phase == .waitingRemote,
                      request.remoteIntentID == expectedIntentID else {
                    return
                }
            } else if self.timelineBoundaryRequest != nil {
                return
            }
            guard let account = AccountManager.shared.find(for: self.owner)
            else {
                return
            }
            self.archiveHistoryAutomaticRetryWorkItem = nil
            self.beginArchiveInteractiveCriticalSection()
            Task {
                await account.archiveEngine.retry(conversation: expectedConversation)
            }
        }
        archiveHistoryAutomaticRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + backoff,
            execute: workItem
        )
    }

    @discardableResult
    internal func submitArchiveEngineLatestTarget() -> Bool {
        let intent = ChatArchiveWindowPresentationPolicy.latestTargetIntent(
            conversation: archiveEngineConversationKey
        )
        cancelArchiveHistoryAutomaticRetry()
        invalidateArchiveEngineVerifiedScope()
        invalidateArchiveWindowAuthoritativeEmptyApply()
        timelineBoundaryRequest = nil
        archiveWindowApplyGeneration &+= 1
        cancelDatasetMappingJobs()
        archiveWindowIntent = intent
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveWindowPendingLiveEdgeAdmission = nil
        archiveWindowLiveEdgeApplyGeneration = nil
        archiveWindowBoundaryLoadingTarget = nil
        let account = AccountManager.shared.find(for: owner)
        if account != nil {
            beginArchiveInteractiveCriticalSection()
        } else {
            endArchiveInteractiveCriticalSection()
        }
        archiveWindowState = .skeleton(reason: .loadingTarget, target: .latest)
        archiveWindowActivity = .idle
        setArchiveLoading(false)
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        guard commitArchiveEngineOpeningSkeletonSynchronously() else {
            endArchiveInteractiveCriticalSection()
            return false
        }
        guard let account else {
            archiveWindowState = .skeleton(reason: .offline, target: .latest)
            endArchiveInteractiveCriticalSection()
            return false
        }
        Task { await account.archiveEngine.submit(intent) }
        return true
    }

    @discardableResult
    internal func submitProtectedInitialTargetFirstFrameToArchive(
        _ request: ChatOpenMessageRequest
    ) -> Bool {
        return submitArchiveEngineTarget(request)
    }

    @discardableResult
    internal func submitArchiveEngineTarget(_ request: ChatOpenMessageRequest) -> Bool {
        guard request.owner == owner,
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
        cancelArchiveHistoryAutomaticRetry()
        invalidateArchiveEngineVerifiedScope()
        invalidateArchiveWindowAuthoritativeEmptyApply()
        timelineBoundaryRequest = nil
        archiveWindowApplyGeneration &+= 1
        cancelDatasetMappingJobs()
        archiveWindowIntent = intent
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveWindowPendingLiveEdgeAdmission = nil
        archiveWindowLiveEdgeApplyGeneration = nil
        archiveWindowBoundaryLoadingTarget = nil
        archiveWindowState = .skeleton(reason: .loadingTarget, target: locator)
        beginArchiveInteractiveCriticalSection()
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        guard commitArchiveEngineOpeningSkeletonSynchronously() else {
            endArchiveInteractiveCriticalSection()
            return false
        }
        Task { await account.archiveEngine.submit(intent) }
        return true
    }

    internal func canRequestTimelineBoundary(
        direction: ChatHistoryPageDirection
    ) -> Bool {
        guard !anchorTransactionGate.snapshot.positioningStarted else {
            return false
        }
        let activeRequestID = timelineBoundaryRequest?.id
        guard let session = timelineSession,
              let scope = committedTimelineScope(
                allowingLocalPresentationID: activeRequestID,
                allowsPendingLiveEdgeAdmission: activeRequestID != nil
              ) else {
            return false
        }

        let state = session.snapshot.state
        switch direction {
        case .older:
            guard let rawCursor = state.oldest?.archivedId,
                  let residentCursor = ArchiveCursor(rawValue: rawCursor) else {
                return false
            }
            return residentCursor > scope.oldest || !scope.reachesArchiveStart
        case .newer:
            guard let rawCursor = state.newest?.archivedId,
                  let residentCursor = ArchiveCursor(rawValue: rawCursor) else {
                return false
            }
            return residentCursor < scope.newest || !scope.reachesLiveEdge
        }
    }

    /// The sole controller paging gateway. It always exhausts the immutable
    /// verified Realm scope before it is allowed to hand a boundary request
    /// to the archive actor.
    @discardableResult
    internal func requestTimelineBoundary(
        direction: ChatHistoryPageDirection,
        visible: Bool,
        localRecoveryAttempt: Int = 0
    ) -> Bool {
        assert(Thread.isMainThread)
        guard !anchorTransactionGate.snapshot.positioningStarted else {
            return false
        }
        if var active = timelineBoundaryRequest {
            guard active.direction == direction,
                  committedTimelineScope(
                    matching: active.scope,
                    allowingLocalPresentationID: active.id,
                    allowsPendingLiveEdgeAdmission: true
                  ) == active.scope else {
                return false
            }
            guard visible, !active.isVisible else { return true }
            active.isVisible = true
            timelineBoundaryRequest = active
            beginArchiveBoundaryLoadingIndicator(for: active.locator)
            beginArchiveInteractiveCriticalSection()
            if active.phase == .waitingRemote {
                promoteTimelineBoundaryRemoteRequestIfNeeded(active)
            }
            return true
        }

        guard let session = timelineSession,
              let scope = committedTimelineScope() else {
            return false
        }
        guard canRequestTimelineBoundary(direction: direction) else {
            return false
        }
        let base = session.snapshot
        let locator = timelineBoundaryLocator(direction: direction, scope: scope)
        archiveWindowApplyGeneration &+= 1
        let request = ChatTimelineBoundaryRequestContext(
            id: UUID(),
            direction: direction,
            scope: scope,
            locator: locator,
            baseGeneration: base.generation,
            applyGeneration: archiveWindowApplyGeneration,
            anchor: captureArchiveEngineBoundaryAnchor(direction: direction),
            owningPresentationIntentID: archiveWindowIntent?.id,
            isVisible: visible,
            phase: .preparingLocal,
            localRecoveryAttempt: max(0, localRecoveryAttempt)
        )
        guard beginCommittedTimelineLocalPresentation(
            ChatCommittedTimelineLocalPresentationToken(
                id: request.id,
                purpose: .boundary,
                scope: scope,
                sessionGeneration: base.generation,
                applyGeneration: request.applyGeneration
            )
        ) else {
            return false
        }
        timelineBoundaryRequest = request
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        if visible {
            beginArchiveBoundaryLoadingIndicator(for: locator)
            beginArchiveInteractiveCriticalSection()
        }

        let disposition = session.prepareVerifiedLocalBoundary(
            direction,
            expectedGeneration: base.generation
        ) { [weak self, weak session] result in
            guard let self, let session else { return }
            self.receiveTimelineBoundaryPreparation(
                result,
                requestID: request.id,
                base: base,
                session: session
            )
        }
        if disposition == .rejectedStale {
            handleTimelineBoundaryLocalFailure(
                requestID: request.id,
                session: session,
                failure: .sessionGenerationChanged
            )
        }
        return true
    }

    internal func prefetchTimelineBoundaryIfNeeded(indexPaths: [IndexPath]) {
        guard committedTimelineScope(
                allowingLocalPresentationID: timelineBoundaryRequest?.id,
                allowsPendingLiveEdgeAdmission:
                    timelineBoundaryRequest != nil
              ) != nil,
              indexPaths.isNotEmpty,
              datasource.isNotEmpty else {
            return
        }
        let visibleCount = max(1, messagesCollectionView.indexPathsForVisibleItems.count)
        let threshold = max(8, visibleCount * 2)
        let sections = indexPaths.map(\.section)
        if let minimum = sections.min(),
           canRequestTimelineBoundary(direction: .older),
           minimum < threshold {
            requestTimelineBoundary(direction: .older, visible: false)
            return
        }
        if let maximum = sections.max(),
           canRequestTimelineBoundary(direction: .newer),
           maximum >= max(0, datasource.count - threshold) {
            requestTimelineBoundary(direction: .newer, visible: false)
        }
    }

    private func timelineBoundaryLocator(
        direction: ChatHistoryPageDirection,
        scope: ChatTimelineVerifiedScope
    ) -> ArchiveWindowLocator {
        switch direction {
        case .older:
            return .older(before: scope.oldest)
        case .newer:
            return .newer(after: scope.newest)
        }
    }

    private func receiveTimelineBoundaryPreparation(
        _ result: ChatTimelineVerifiedBoundaryPreparationResult,
        requestID: UUID,
        base: ChatTimelineSessionSnapshot,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard let request = timelineBoundaryRequest,
              request.id == requestID,
              timelineSession === session,
              archiveWindowApplyGeneration == request.applyGeneration else {
            return
        }

        switch result {
        case .stale:
            handleTimelineBoundaryLocalFailure(
                requestID: requestID,
                session: session,
                failure: .sessionGenerationChanged
            )
        case .prepared(let prepared):
            let mappingJob = beginDatasetMappingJob()
            let mappingContext = captureDatasourceMappingContext()
            let originalResidentWindow = residentDatasetWindow
            datasetMappingQueue.async { [weak self, weak session] in
                guard let self, let session else { return }
                guard !mappingJob.token.isCancelled else {
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.handleTimelineBoundaryLocalFailure(
                            requestID: requestID,
                            session: session,
                            failure: .mappingCancelled
                        )
                    }
                    return
                }
                let outcome = session.inspectPreparedVerifiedLocalBoundary(prepared)
                switch outcome {
                case .local(let candidate):
                    let mappingResult = self.mapDataset(
                        dataset: candidate.items,
                        context: mappingContext,
                        cancellationToken: mappingJob.token
                    )
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.applyPreparedTimelineBoundary(
                            candidate,
                            prepared: prepared,
                            mappingResult: mappingResult,
                            mappingJob: mappingJob,
                            requestID: requestID,
                            base: base,
                            originalResidentWindow: originalResidentWindow,
                            session: session
                        )
                    }
                case .needsArchiveExpansion(let direction):
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        guard let current = self.timelineBoundaryRequest,
                              current.id == requestID,
                              current.direction == direction,
                              self.timelineSession === session else {
                            return
                        }
                        guard current.allowsArchiveExpansion else {
                            self.dropSilentTimelineBoundaryRequest(
                                current,
                                session: session
                            )
                            return
                        }
                        self.submitArchiveEngineBoundaryExpansion(
                            direction: direction,
                            scope: current.scope,
                            requestID: requestID
                        )
                    }
                case .endReached:
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session,
                              self.timelineSession === session else {
                            return
                        }
                        self.finishTimelineBoundaryRequest(requestID: requestID)
                    }
                case .invalidProof:
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.handleTimelineBoundaryLocalFailure(
                            requestID: requestID,
                            session: session,
                            failure: self.classifyTimelineBoundaryInvalidProof(
                                requestID: requestID,
                                session: session
                            )
                        )
                    }
                }
            }
        }
    }

    private func applyPreparedTimelineBoundary(
        _ candidate: ChatTimelineSnapshot,
        prepared: ChatTimelinePreparedVerifiedBoundaryPage,
        mappingResult: ChatDatasourceMappingResult,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        requestID: UUID,
        base: ChatTimelineSessionSnapshot,
        originalResidentWindow: ChatDatasetWindow,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard var request = timelineBoundaryRequest,
              request.id == requestID,
              timelineSession === session else {
            return
        }
        let committedScope = committedTimelineScope(
            matching: request.scope,
            allowingLocalPresentationID: request.id,
            allowsPendingLiveEdgeAdmission: true
        )
        let validationFailure: ChatTimelineLocalBoundaryFailure?
        if datasetMappingGeneration != mappingJob.generation ||
            mappingJob.token.isCancelled || mappingResult.wasCancelled {
            validationFailure = .mappingCancelled
        } else if archiveWindowApplyGeneration != request.applyGeneration ||
                    archiveWindowIntent?.id !=
                        request.owningPresentationIntentID {
            validationFailure = .connectionOrTargetReplaced
        } else if session.verifiedScope == request.scope,
                  session.snapshot.generation != base.generation {
            validationFailure = .sessionGenerationChanged
        } else if session.verifiedScope != request.scope ||
                    committedScope != request.scope {
            validationFailure = .invalidProof
        } else {
            validationFailure = nil
        }
        if let validationFailure {
            handleTimelineBoundaryLocalFailure(
                requestID: requestID,
                session: session,
                failure: validationFailure
            )
            return
        }
        request.phase = .applyingLocal
        timelineBoundaryRequest = request
        let mappedPrimaryIDs = Set(mappingResult.datasource.map(\.primary))
        let liveAnchor = captureArchiveEngineBoundaryAnchor(
            direction: request.direction
        ).flatMap {
            mappedPrimaryIDs.contains($0.primary) ? $0 : nil
        }
        let retainedAnchor = request.anchor.flatMap {
            mappedPrimaryIDs.contains($0.primary) ? $0 : nil
        }
        let restoreAnchor = liveAnchor ?? retainedAnchor
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: request.direction,
            hasCapturedAnchor: restoreAnchor != nil
        )
        let usesRecoverySkeleton =
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: request.locator,
                hasUsableAnchor: restoreAnchor != nil,
                hasCommittedContent: datasource.contains { !$0.isFakeMessage }
            )
        if usesRecoverySkeleton {
            setArchiveLoading(false)
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
        }
        syncCurrentPage(with: ChatDatasetWindow(
            minIndex: 0,
            maxIndex: candidate.items.count
        ))

        let commitReceipt = ChatTimelineBoundaryCommitReceipt()

        applyChatDatasource(
            mappingResult.datasource,
            mode: .fullReload(keepOffset: applyPlan.keepOffset),
            animated: false,
            invalidateLayout: false,
            preparedLayouts: mappingResult.layoutSnapshot,
            suppressDefaultBottomScroll: true,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: restoreAnchor?.primary,
            restoreAnchor: restoreAnchor,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { [weak self, weak session] in
                guard let self, let session,
                      let current = self.timelineBoundaryRequest else {
                    return false
                }
                guard current.id == requestID &&
                    current.scope == request.scope &&
                    self.timelineSession === session &&
                    self.archiveWindowApplyGeneration == request.applyGeneration &&
                    self.datasetMappingGeneration == mappingJob.generation &&
                    !mappingJob.token.isCancelled &&
                    session.verifiedScope == request.scope &&
                    self.committedTimelineScope(
                        matching: request.scope,
                        allowingLocalPresentationID: request.id,
                        allowsPendingLiveEdgeAdmission: true
                    ) == request.scope else {
                    return false
                }
                if let committed = commitReceipt.snapshot {
                    return session.snapshot.generation == committed.generation
                }
                guard session.snapshot.generation == base.generation else {
                    return false
                }
                guard case .local(let committed) =
                        session.commitPreparedVerifiedLocalBoundary(prepared),
                      committed.items.map(\.primary) == candidate.items.map(\.primary),
                      committed.state == candidate.state else {
                    return false
                }
                commitReceipt.snapshot = committed
                return true
            },
            transactionCompletion: { [weak self, weak session] result in
                guard let self, let session else { return }
                self.handlePreparedTimelineBoundaryApplyResult(
                    result,
                    candidate: candidate,
                    prepared: prepared,
                    commitReceipt: commitReceipt,
                    mappingResult: mappingResult,
                    mappingJob: mappingJob,
                    requestID: requestID,
                    base: base,
                    originalResidentWindow: originalResidentWindow,
                    session: session
                )
            },
            completion: { [weak self, weak session] in
                guard let self, let session else { return }
                guard let current = self.timelineBoundaryRequest,
                      current.id == requestID,
                      self.timelineSession === session,
                      let committed = commitReceipt.snapshot,
                      session.snapshot.generation == committed.generation,
                      session.verifiedScope == current.scope,
                      self.committedTimelineScope(
                        matching: current.scope,
                        allowingLocalPresentationID: current.id,
                        allowsPendingLiveEdgeAdmission: true
                      ) == current.scope else {
                    if let committed = commitReceipt.snapshot,
                       session.snapshot.generation == committed.generation {
                        _ = session.commitPresentationSnapshot(base)
                        self.syncCurrentPage(with: originalResidentWindow)
                    }
                    let failure: ChatTimelineLocalBoundaryFailure
                    if self.archiveWindowApplyGeneration !=
                        request.applyGeneration ||
                        self.archiveWindowIntent?.id !=
                            request.owningPresentationIntentID {
                        failure = .connectionOrTargetReplaced
                    } else if session.verifiedScope == request.scope {
                        failure = .sessionGenerationChanged
                    } else {
                        failure = .invalidProof
                    }
                    self.handleTimelineBoundaryLocalFailure(
                        requestID: requestID,
                        session: session,
                        failure: failure
                    )
                    return
                }
                self.archiveWindowAtomicApplyRetryWorkItem?.cancel()
                self.archiveWindowAtomicApplyRetryWorkItem = nil
                self.archiveWindowAtomicApplyRetryCount = 0
                self.timelineBoundaryRequest = nil
                self.finishCommittedTimelineLocalPresentation(
                    id: current.id
                )
                ArchiveEngineObservability.event(
                    .uikitApply,
                    value: committed.items.count
                )
                self.setSkeletonVisible(false)
                if current.isVisible {
                    self.completeArchiveBoundaryLoadingIndicator(
                        for: current.locator
                    )
                    self.endArchiveInteractiveCriticalSection()
                }
                self.setDatasourceLoadingEnabled(true)
                if self.pendingOpenMessageRequest != nil {
                    self.performPendingOpenMessageRequestIfNeeded()
                }
                self.drainTimelinePresentationLanesAfterAnchorTerminal()
            }
        )
    }

    private func handlePreparedTimelineBoundaryApplyResult(
        _ result: ChatViewportTransactionResult,
        candidate: ChatTimelineSnapshot,
        prepared: ChatTimelinePreparedVerifiedBoundaryPage,
        commitReceipt: ChatTimelineBoundaryCommitReceipt,
        mappingResult: ChatDatasourceMappingResult,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        requestID: UUID,
        base: ChatTimelineSessionSnapshot,
        originalResidentWindow: ChatDatasetWindow,
        session: ChatTimelineSession
    ) {
        guard case .failed(let failure, _) = result else { return }

        if let committed = commitReceipt.snapshot,
           session.snapshot.generation == committed.generation {
            _ = session.commitPresentationSnapshot(base)
            syncCurrentPage(with: originalResidentWindow)
        }

        guard let request = timelineBoundaryRequest,
              request.id == requestID,
              timelineSession === session else { return }
        if commitReceipt.snapshot == nil,
           ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
            failure: failure,
            completedRetryCount: archiveWindowAtomicApplyRetryCount
        ) {
            archiveWindowAtomicApplyRetryCount += 1
            schedulePreparedTimelineBoundaryApplyRetry(
                candidate: candidate,
                prepared: prepared,
                mappingResult: mappingResult,
                mappingJob: mappingJob,
                requestID: requestID,
                base: base,
                originalResidentWindow: originalResidentWindow,
                session: session,
                remainingMotionChecks: 20
            )
            return
        }
        syncCurrentPage(with: originalResidentWindow)
        let localFailure: ChatTimelineLocalBoundaryFailure
        if datasetMappingGeneration != mappingJob.generation ||
            mappingJob.token.isCancelled || mappingResult.wasCancelled {
            localFailure = .mappingCancelled
        } else if archiveWindowApplyGeneration != request.applyGeneration ||
                    archiveWindowIntent?.id !=
                        request.owningPresentationIntentID {
            localFailure = .connectionOrTargetReplaced
        } else if session.verifiedScope == request.scope,
                  session.snapshot.generation != base.generation {
            localFailure = .sessionGenerationChanged
        } else if session.verifiedScope != request.scope {
            localFailure = .invalidProof
        } else {
            switch failure {
            case .superseded:
                localFailure = .atomicApplySuperseded
            case .targetMissing, .alignmentUnresolved:
                localFailure = .transientAtomicApplyFailure
            }
        }
        handleTimelineBoundaryLocalFailure(
            requestID: requestID,
            session: session,
            failure: localFailure
        )
    }

    private func schedulePreparedTimelineBoundaryApplyRetry(
        candidate: ChatTimelineSnapshot,
        prepared: ChatTimelinePreparedVerifiedBoundaryPage,
        mappingResult: ChatDatasourceMappingResult,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        requestID: UUID,
        base: ChatTimelineSessionSnapshot,
        originalResidentWindow: ChatDatasetWindow,
        session: ChatTimelineSession,
        remainingMotionChecks: Int
    ) {
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session,
                  self.timelineSession === session,
                  self.timelineBoundaryRequest?.id == requestID else {
                return
            }
            if self.currentScrollMotionState() != .resting,
               remainingMotionChecks > 0 {
                self.schedulePreparedTimelineBoundaryApplyRetry(
                    candidate: candidate,
                    prepared: prepared,
                    mappingResult: mappingResult,
                    mappingJob: mappingJob,
                    requestID: requestID,
                    base: base,
                    originalResidentWindow: originalResidentWindow,
                    session: session,
                    remainingMotionChecks: remainingMotionChecks - 1
                )
                return
            }
            self.archiveWindowAtomicApplyRetryWorkItem = nil
            self.applyPreparedTimelineBoundary(
                candidate,
                prepared: prepared,
                mappingResult: mappingResult,
                mappingJob: mappingJob,
                requestID: requestID,
                base: base,
                originalResidentWindow: originalResidentWindow,
                session: session
            )
        }
        archiveWindowAtomicApplyRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func submitArchiveEngineBoundaryExpansion(
        direction: ChatHistoryPageDirection,
        scope: ChatTimelineVerifiedScope,
        requestID: UUID
    ) {
        assert(Thread.isMainThread)
        guard var request = timelineBoundaryRequest,
              request.id == requestID,
              request.direction == direction,
              request.scope == scope,
              let session = timelineSession else {
            return
        }
        guard session.verifiedScope == scope else {
            handleTimelineBoundaryLocalFailure(
                requestID: requestID,
                session: session,
                failure: .invalidProof
            )
            return
        }
        guard let account = AccountManager.shared.find(for: owner) else {
            handleTimelineBoundaryLocalFailure(
                requestID: requestID,
                session: session,
                failure: .connectionOrTargetReplaced
            )
            return
        }

        let locator: ArchiveWindowLocator
        let contextBefore: Int
        let contextAfter: Int
        let residentCount = session.snapshot.items.count
        switch direction {
        case .older:
            locator = .older(before: scope.oldest)
            contextBefore = ArchivePageSizing.history
            contextAfter = min(residentCount, ArchivePageSizing.initial)
        case .newer:
            locator = .newer(after: scope.newest)
            contextBefore = min(residentCount, ArchivePageSizing.initial)
            contextAfter = ArchivePageSizing.history
        }
        guard locator == request.locator else {
            handleTimelineBoundaryLocalFailure(
                requestID: requestID,
                session: session,
                failure: .invalidProof
            )
            return
        }
        cancelArchiveHistoryAutomaticRetry()
        request.phase = .waitingRemote
        timelineBoundaryRequest = request
        if let anchor = request.anchor {
            archiveWindowBoundaryPresentationAnchor = ChatArchiveBoundaryPresentationAnchor(
                locator: locator,
                direction: direction,
                anchor: anchor
            )
        }
        let intent = ArchiveWindowIntent(
            id: request.id,
            conversation: archiveEngineConversationKey,
            locator: locator,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            priority: request.isVisible ? .visibleIntegrity : .nearEdgePrefetch
        )
        request.remoteIntentID = intent.id
        request.remoteTerminal = nil
        request.didWinUIKitApply = false
        timelineBoundaryRequest = request
        archiveWindowIntent = intent
        finishCommittedTimelineLocalPresentation(id: request.id)
        Task { await account.archiveEngine.submit(intent) }
    }

    private func promoteTimelineBoundaryRemoteRequestIfNeeded(
        _ request: ChatTimelineBoundaryRequestContext
    ) {
        guard request.phase == .waitingRemote,
              let account = AccountManager.shared.find(for: owner),
              let currentIntent = archiveWindowIntent,
              currentIntent.locator == request.locator,
              currentIntent.priority < .visibleIntegrity else {
            return
        }
        let promoted = ArchiveWindowIntent(
            id: currentIntent.id,
            conversation: currentIntent.conversation,
            locator: currentIntent.locator,
            contextBefore: currentIntent.contextBefore,
            contextAfter: currentIntent.contextAfter,
            priority: .visibleIntegrity
        )
        archiveWindowIntent = promoted
        Task { await account.archiveEngine.submit(promoted) }
    }

    private func finishTimelineBoundaryRequest(requestID: UUID) {
        guard let request = timelineBoundaryRequest,
              request.id == requestID else {
            return
        }
        timelineBoundaryRequest = nil
        finishCommittedTimelineLocalPresentation(id: request.id)
        if request.isVisible {
            completeArchiveBoundaryLoadingIndicator(for: request.locator)
            endArchiveInteractiveCriticalSection()
        }
        if pendingOpenMessageRequest != nil {
            performPendingOpenMessageRequestIfNeeded()
        }
        drainTimelinePresentationLanesAfterAnchorTerminal()
    }

    private func classifyTimelineBoundaryInvalidProof(
        requestID: UUID,
        session: ChatTimelineSession
    ) -> ChatTimelineLocalBoundaryFailure {
        guard let request = timelineBoundaryRequest,
              request.id == requestID,
              timelineSession === session,
              archiveWindowApplyGeneration == request.applyGeneration,
              archiveWindowIntent?.id == request.owningPresentationIntentID else {
            return .connectionOrTargetReplaced
        }
        // A prepared page is session-generation scoped. Read-boundary and
        // resident observation updates may consume that preparation without
        // revoking the immutable archive proof, so they are locally retryable.
        return session.verifiedScope == request.scope
            ? .sessionGenerationChanged
            : .invalidProof
    }

    private func retainsCurrentTimelineBoundaryProof(
        _ request: ChatTimelineBoundaryRequestContext,
        session: ChatTimelineSession
    ) -> Bool {
        guard timelineSession === session,
              timelineBoundaryRequest?.id == request.id,
              archiveWindowApplyGeneration == request.applyGeneration,
              archiveWindowIntent?.id == request.owningPresentationIntentID,
              session.verifiedScope == request.scope else {
            return false
        }
        // Local recovery must assess the proof, not temporary UIKit overlay
        // state. A recovery skeleton or local-presentation token must not turn
        // an otherwise verified scope into a remote `.latest` reset.
        return ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
            state: archiveWindowState,
            committedCoverageGeneration:
                archiveWindowCommittedCoverageGeneration,
            sessionScope: request.scope,
            requiredScope: request.scope,
            conversationKey: chatTimelineConversationKey,
            isShowingSkeleton: false,
            hasPendingPresentation: false
        )
    }

    private func handleTimelineBoundaryLocalFailure(
        requestID: UUID,
        session: ChatTimelineSession,
        failure: ChatTimelineLocalBoundaryFailure
    ) {
        guard let request = timelineBoundaryRequest,
              request.id == requestID,
              timelineSession === session else {
            return
        }
        let disposition = ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
            for: failure,
            isVisible: request.isVisible,
            retainsVerifiedProof: retainsCurrentTimelineBoundaryProof(
                request,
                session: session
            ),
            completedRetryCount: request.localRecoveryAttempt
        )
        switch disposition {
        case .retryLocal:
            retryTimelineBoundaryLocally(request, session: session)
        case .dropSilent:
            dropSilentTimelineBoundaryRequest(request, session: session)
        case .failClosed:
            failTimelineBoundaryClosed(
                requestID: requestID,
                session: session
            )
        }
    }

    private func clearTimelineBoundaryLocalWork(
        _ request: ChatTimelineBoundaryRequestContext
    ) {
        guard timelineBoundaryRequest?.id == request.id else { return }
        timelineBoundaryRequest = nil
        finishCommittedTimelineLocalPresentation(id: request.id)
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        cancelDatasetMappingJobs()
    }

    private func retryTimelineBoundaryLocally(
        _ request: ChatTimelineBoundaryRequestContext,
        session: ChatTimelineSession
    ) {
        guard timelineSession === session,
              timelineBoundaryRequest?.id == request.id else {
            return
        }
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        cancelDatasetMappingJobs()
        finishCommittedTimelineLocalPresentation(id: request.id)

        let base = session.snapshot
        var restarted = request
        restarted.baseGeneration = base.generation
        restarted.phase = .preparingLocal
        restarted.localRecoveryAttempt = request.localRecoveryAttempt < Int.max
            ? max(0, request.localRecoveryAttempt) + 1
            : Int.max
        restarted.allowsArchiveExpansion = false
        restarted.remoteIntentID = nil
        restarted.remoteTerminal = nil
        restarted.didWinUIKitApply = false
        let retryDelay = ChatTimelineLocalBoundaryRecoveryPolicy.retryDelay(
            forAttempt: restarted.localRecoveryAttempt
        )
        guard beginCommittedTimelineLocalPresentation(
            ChatCommittedTimelineLocalPresentationToken(
                id: restarted.id,
                purpose: .boundary,
                scope: restarted.scope,
                sessionGeneration: base.generation,
                applyGeneration: restarted.applyGeneration
            )
        ) else {
            dropSilentTimelineBoundaryRequest(request, session: session)
            return
        }
        timelineBoundaryRequest = restarted
        setSkeletonVisible(false)
        setDatasourceLoadingEnabled(true)
        let workItem = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session,
                  self.timelineSession === session,
                  let current = self.timelineBoundaryRequest,
                  current.id == restarted.id,
                  current.scope == restarted.scope,
                  current.phase == .preparingLocal,
                  current.baseGeneration == base.generation,
                  current.localRecoveryAttempt ==
                    restarted.localRecoveryAttempt,
                  current.allowsArchiveExpansion == false,
                  self.archiveWindowApplyGeneration ==
                    restarted.applyGeneration else {
                return
            }
            self.archiveWindowAtomicApplyRetryWorkItem = nil
            let disposition = session.prepareVerifiedLocalBoundary(
                restarted.direction,
                expectedGeneration: base.generation
            ) { [weak self, weak session] result in
                guard let self, let session else { return }
                self.receiveTimelineBoundaryPreparation(
                    result,
                    requestID: restarted.id,
                    base: base,
                    session: session
                )
            }
            if disposition == .rejectedStale {
                self.handleTimelineBoundaryLocalFailure(
                    requestID: restarted.id,
                    session: session,
                    failure: .sessionGenerationChanged
                )
            }
        }
        archiveWindowAtomicApplyRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + retryDelay,
            execute: workItem
        )
    }

    private func dropSilentTimelineBoundaryRequest(
        _ request: ChatTimelineBoundaryRequestContext,
        session: ChatTimelineSession
    ) {
        guard timelineSession === session,
              timelineBoundaryRequest?.id == request.id else {
            return
        }
        clearTimelineBoundaryLocalWork(request)
        setArchiveLoading(false)
        setSkeletonVisible(false)
        setDatasourceLoadingEnabled(true)
        if request.isVisible {
            completeArchiveBoundaryLoadingIndicator(for: request.locator)
            endArchiveInteractiveCriticalSection()
        }
        if pendingOpenMessageRequest != nil {
            performPendingOpenMessageRequestIfNeeded()
        }
        drainTimelinePresentationLanesAfterAnchorTerminal()
    }

    private func hasNewerTimelineBoundaryPresentationOwner(
        _ request: ChatTimelineBoundaryRequestContext
    ) -> Bool {
        archiveWindowApplyGeneration != request.applyGeneration ||
            archiveWindowIntent?.id != request.owningPresentationIntentID
    }

    private func failTimelineBoundaryClosed(
        requestID: UUID,
        session: ChatTimelineSession
    ) {
        guard let request = timelineBoundaryRequest,
              request.id == requestID,
              timelineSession === session else {
            return
        }
        // A target or reconnect intent that already advanced the presentation
        // generation owns its skeleton and retry semantics. The stale local
        // boundary must not replace it with an unrelated `.latest` request.
        if hasNewerTimelineBoundaryPresentationOwner(request) {
            timelineBoundaryRequest = nil
            finishCommittedTimelineLocalPresentation(id: request.id)
            return
        }
        clearTimelineBoundaryLocalWork(request)
        if request.isVisible {
            completeArchiveBoundaryLoadingIndicator(for: request.locator)
            endArchiveInteractiveCriticalSection()
        }
        archiveWindowApplyGeneration &+= 1
        invalidateArchiveEngineVerifiedScope()
        archiveWindowCommittedCoverageGeneration = nil
        archiveWindowPendingSnapshot = nil
        archiveWindowPendingLiveEdgeAdmission = nil
        archiveWindowLiveEdgeApplyGeneration = nil
        archiveWindowBoundaryPresentationAnchor = nil
        archiveWindowState = .skeleton(
            reason: .staleFingerprint,
            target: archiveWindowIntent?.locator ?? request.locator
        )
        setArchiveLoading(false)
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        _ = commitArchiveEngineOpeningSkeletonSynchronously()
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

    private func receiveArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission
    ) {
        assert(Thread.isMainThread)
        guard archiveLiveEdgeAdmissionTask != nil,
              ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
                admission,
                currentIntent: archiveWindowIntent,
                currentScope: timelineSession?.verifiedScope,
                currentState: archiveWindowState
              ) else {
            return
        }
        if let pending = archiveWindowPendingLiveEdgeAdmission {
            guard pending.latestWindow.freshnessToken.fingerprint ==
                    admission.latestWindow.freshnessToken.fingerprint,
                  admission.latestWindow.coverageGeneration >
                    pending.latestWindow.coverageGeneration else {
                return
            }
        }
        archiveWindowPendingLiveEdgeAdmission = admission
        archiveWindowLiveEdgeReprepareCount = 0
        drainPendingArchiveLiveEdgeAdmission()
    }

    internal func receiveLocalOutgoingAdmission(
        _ admission: ChatTimelineLocalOutgoingAdmission
    ) {
        assert(Thread.isMainThread)
        guard archiveLocalOutgoingAdmissionTask != nil,
              admission.conversation == archiveEngineConversationKey else {
            return
        }
        archivePendingLocalOutgoingAdmissions[admission.primaryID] = admission
        drainPendingLocalOutgoingAdmissions()
    }

    internal func drainPendingLocalOutgoingAdmissions() {
        assert(Thread.isMainThread)
        guard archiveLocalOutgoingAdmissionTask != nil,
              let session = timelineSession,
              session.verifiedScope?.reachesLiveEdge == true ||
                session.snapshot.authoritativeEmptyLiveTailAuthority != nil else {
            return
        }
        let pending = archivePendingLocalOutgoingAdmissions.values.filter {
            !archiveLocalOutgoingAdmissionInFlightPrimaryIDs.contains(
                $0.primaryID
            )
        }
        for admission in pending {
            archiveLocalOutgoingAdmissionInFlightPrimaryIDs.insert(
                admission.primaryID
            )
            archiveLocalOutgoingAdmissionQueue.async {
                [weak self, weak session] in
                guard let self, let session else { return }
                let admitted = session.admitLocalOutgoing(admission)
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.archiveLocalOutgoingAdmissionInFlightPrimaryIDs.remove(
                        admission.primaryID
                    )
                    guard self.timelineSession === session,
                          self.archiveLocalOutgoingAdmissionTask != nil else {
                        return
                    }
                    if admitted != nil {
                        self.archivePendingLocalOutgoingAdmissions.removeValue(
                            forKey: admission.primaryID
                        )
                    }
                }
            }
        }
    }

    private func drainPendingArchiveLiveEdgeAdmission() {
        assert(Thread.isMainThread)
        guard !anchorTransactionGate.snapshot.positioningStarted,
              archiveWindowLiveEdgeApplyGeneration == nil,
              committedTimelineLocalPresentationToken == nil,
              proofScopedLocalTargetRequest == nil,
              let admission = archiveWindowPendingLiveEdgeAdmission,
              let session = timelineSession else {
            return
        }
        guard ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
            admission,
            currentIntent: archiveWindowIntent,
            currentScope: session.verifiedScope,
            currentState: archiveWindowState
        ) else {
            archiveWindowPendingLiveEdgeAdmission = nil
            return
        }
        guard
              archiveWindowPendingSnapshot == nil,
              archiveWindowAtomicApplyRetryWorkItem == nil,
              timelineBoundaryRequest == nil,
              !showSkeletonObserver.value else {
            return
        }

        let applyGeneration = archiveWindowApplyGeneration
        if deferArchiveEnginePresentationIfTimelineStoreApplyActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.drainPendingArchiveLiveEdgeAdmission()
            }
        ) {
            return
        }
        archiveWindowLiveEdgeApplyGeneration = applyGeneration
        let base = session.snapshot
        let previousScope = session.verifiedScope
        let mappingJob = beginDatasetMappingJob()
        let mappingContext = captureDatasourceMappingContext()

        datasetMappingQueue.async { [weak self, weak session] in
            guard let self, let session,
                  !mappingJob.token.isCancelled,
                  let prepared = session.prepareArchiveLiveEdgeAdmission(
                    admission
                  ),
                  let candidate = session.inspectPreparedArchiveLiveEdgeAdmission(
                    prepared
                  ) else {
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.finishRejectedArchiveLiveEdgeAdmission(
                        admission,
                        applyGeneration: applyGeneration,
                        session: session
                    )
                }
                return
            }

            switch candidate.mode {
            case .proofOnly:
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.commitProofOnlyArchiveLiveEdgeAdmission(
                        admission,
                        prepared: prepared,
                        applyGeneration: applyGeneration,
                        mappingJob: mappingJob,
                        session: session
                    )
                }
            case .residentNewer:
                let mappingResult = self.mapDataset(
                    dataset: candidate.snapshot.items,
                    context: mappingContext,
                    cancellationToken: mappingJob.token
                )
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.applyResidentArchiveLiveEdgeAdmission(
                        admission,
                        candidate: candidate.snapshot,
                        prepared: prepared,
                        mappingResult: mappingResult,
                        mappingJob: mappingJob,
                        applyGeneration: applyGeneration,
                        base: base,
                        previousScope: previousScope,
                        session: session
                    )
                }
            }
        }
    }

    private func isCurrentArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission,
        applyGeneration: UInt64,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        session: ChatTimelineSession
    ) -> Bool {
        timelineSession === session &&
            archiveLiveEdgeAdmissionTask != nil &&
            archiveWindowLiveEdgeApplyGeneration == applyGeneration &&
            archiveWindowPendingLiveEdgeAdmission == admission &&
            archiveWindowApplyGeneration == applyGeneration &&
            archiveWindowPendingSnapshot == nil &&
            timelineBoundaryRequest == nil &&
            datasetMappingGeneration == mappingJob.generation &&
            !mappingJob.token.isCancelled &&
            ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
                admission,
                currentIntent: archiveWindowIntent,
                currentScope: session.verifiedScope,
                currentState: archiveWindowState
            )
    }

    private func commitProofOnlyArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission,
        prepared: ChatTimelinePreparedLiveEdgeAdmission,
        applyGeneration: UInt64,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard isCurrentArchiveLiveEdgeAdmission(
            admission,
            applyGeneration: applyGeneration,
            mappingJob: mappingJob,
            session: session
        ), let committed = session.commitPreparedArchiveLiveEdgeAdmission(
            prepared
        ), committed.mode == .proofOnly else {
            finishRejectedArchiveLiveEdgeAdmission(
                admission,
                applyGeneration: applyGeneration,
                session: session
            )
            return
        }
        finishCommittedArchiveLiveEdgeAdmission(
            admission,
            committed: committed,
            session: session
        )
    }

    private func applyResidentArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission,
        candidate: ChatTimelineSnapshot,
        prepared: ChatTimelinePreparedLiveEdgeAdmission,
        mappingResult: ChatDatasourceMappingResult,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        applyGeneration: UInt64,
        base: ChatTimelineSessionSnapshot,
        previousScope: ChatTimelineVerifiedScope?,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard !mappingResult.wasCancelled,
              isCurrentArchiveLiveEdgeAdmission(
                admission,
                applyGeneration: applyGeneration,
                mappingJob: mappingJob,
                session: session
              ),
              session.inspectPreparedArchiveLiveEdgeAdmission(prepared) != nil,
              session.verifiedScope == previousScope else {
            finishRejectedArchiveLiveEdgeAdmission(
                admission,
                applyGeneration: applyGeneration,
                session: session
            )
            return
        }

        let commitReceipt = ChatTimelineLiveEdgeCommitReceipt()
        applyChatDatasource(
            mappingResult.datasource,
            mode: .targetedDiff,
            animated: false,
            invalidateLayout: false,
            preparedLayouts: mappingResult.layoutSnapshot,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { [weak self, weak session] in
                guard let self, let session,
                      self.isCurrentArchiveLiveEdgeAdmission(
                        admission,
                        applyGeneration: applyGeneration,
                        mappingJob: mappingJob,
                        session: session
                      ) else {
                    return false
                }
                if let committed = commitReceipt.result {
                    return session.snapshot.generation ==
                        committed.snapshot.generation
                }
                guard session.verifiedScope == previousScope else {
                    return false
                }
                let rollbackSnapshot = session.snapshot
                guard let committed =
                    session.commitPreparedArchiveLiveEdgeAdmission(prepared),
                      committed.mode == .residentNewer,
                      committed.snapshot.items.map(\.primary) ==
                        candidate.items.map(\.primary),
                      committed.snapshot.state == candidate.state else {
                    return false
                }
                commitReceipt.rollbackSnapshot = rollbackSnapshot
                commitReceipt.result = committed
                return true
            },
            transactionCompletion: { [weak self, weak session] result in
                guard case .failed = result,
                      let self,
                      let session else {
                    return
                }
                if let committed = commitReceipt.result,
                   session.snapshot.generation == committed.snapshot.generation {
                    _ = session.restorePresentationSnapshot(
                        commitReceipt.rollbackSnapshot ?? base,
                        verifiedScope: previousScope
                    )
                }
                self.finishRejectedArchiveLiveEdgeAdmission(
                    admission,
                    applyGeneration: applyGeneration,
                    session: session
                )
            },
            completion: { [weak self, weak session] in
                guard let self, let session else { return }
                guard let committed = commitReceipt.result,
                      session.snapshot.generation ==
                        committed.snapshot.generation,
                      self.isCurrentArchiveLiveEdgeAdmission(
                        admission,
                        applyGeneration: applyGeneration,
                        mappingJob: mappingJob,
                        session: session
                      ) else {
                    self.finishRejectedArchiveLiveEdgeAdmission(
                        admission,
                        applyGeneration: applyGeneration,
                        session: session
                    )
                    return
                }
                self.finishCommittedArchiveLiveEdgeAdmission(
                    admission,
                    committed: committed,
                    session: session
                )
            }
        )
    }

    private func finishCommittedArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission,
        committed: ChatTimelineCommittedLiveEdgeAdmission,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        let committedSnapshot = committed.snapshot
        guard timelineSession === session,
              session.snapshot.generation == committedSnapshot.generation,
              session.verifiedScope?.coverageGeneration ==
                admission.latestWindow.coverageGeneration,
              archiveWindowPendingLiveEdgeAdmission == admission,
              let intent = archiveWindowIntent,
              ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
                admission,
                currentIntent: intent,
                currentScope: session.verifiedScope,
                currentState: archiveWindowState
              ) else {
            return
        }
        archiveWindowCommittedCoverageGeneration =
            admission.latestWindow.coverageGeneration
        archiveWindowPendingLiveEdgeAdmission = nil
        archiveWindowLiveEdgeApplyGeneration = nil
        archiveWindowLiveEdgeReprepareCount = 0
        if committed.shouldExposeNewMessageBadge,
           !shouldShowScrollDownButton.value {
            shouldShowScrollDownButton.accept(true)
        }
        syncCurrentPage(with: ChatDatasetWindow(
            minIndex: 0,
            maxIndex: committedSnapshot.items.count
        ))
        if let state = archiveWindowState,
           case .authoritativeEmpty = state {
            setSkeletonVisible(false)
        }
        if pendingOpenMessageRequest != nil {
            performPendingOpenMessageRequestIfNeeded()
        }
        drainTimelinePresentationLanesAfterAnchorTerminal()
    }

    private func finishRejectedArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission,
        applyGeneration: UInt64,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard timelineSession === session else { return }
        guard archiveWindowLiveEdgeApplyGeneration == applyGeneration else {
            return
        }
        archiveWindowLiveEdgeApplyGeneration = nil
        let remainsCurrent = archiveWindowApplyGeneration == applyGeneration &&
            archiveWindowPendingLiveEdgeAdmission == admission &&
            archiveLiveEdgeAdmissionTask != nil &&
            ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
                admission,
                currentIntent: archiveWindowIntent,
                currentScope: session.verifiedScope,
                currentState: archiveWindowState
            )
        if ChatArchiveLiveEdgeRepreparePolicy.shouldReprepare(
            remainsCurrent: remainsCurrent,
            completedRetryCount: archiveWindowLiveEdgeReprepareCount
        ) {
            archiveWindowLiveEdgeReprepareCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.drainPendingArchiveLiveEdgeAdmission()
            }
            return
        }
        if archiveWindowApplyGeneration == applyGeneration,
           archiveWindowPendingLiveEdgeAdmission == admission {
            archiveWindowPendingLiveEdgeAdmission = nil
        }
        archiveWindowLiveEdgeReprepareCount = 0
        if pendingOpenMessageRequest != nil {
            performPendingOpenMessageRequestIfNeeded()
        }
        drainTimelinePresentationLanesAfterAnchorTerminal()
    }

    private func receiveArchiveWindowState(_ state: ArchiveWindowState) {
        assert(Thread.isMainThread)
        guard archiveWindowStateTask != nil,
              ChatArchiveWindowPresentationPolicy.shouldAccept(
                state: state,
                for: archiveWindowIntent
              ) else {
            return
        }
        if case .verified(let incoming) = state,
           let scope = timelineSession?.verifiedScope,
           incoming.freshnessToken.fingerprint ==
                scope.freshnessFingerprint,
           incoming.coverageGeneration < scope.coverageGeneration {
            return
        }
        if case .verified(let incoming) = state,
           ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: archiveWindowState,
                committedCoverageGeneration: archiveWindowCommittedCoverageGeneration,
                pendingSnapshot: archiveWindowPendingSnapshot,
                incoming: incoming
        ) {
            return
        }
        let resetsAutomaticRetryAttempt: Bool
        switch state {
        case .retryableFailure, .skeleton(reason: .loadingTarget, target: _):
            resetsAutomaticRetryAttempt = false
        default:
            resetsAutomaticRetryAttempt = true
        }
        cancelArchiveHistoryAutomaticRetry(
            resetAttempt: resetsAutomaticRetryAttempt
        )
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount = 0
        let retainedRemoteBoundaryRequest: ChatTimelineBoundaryRequestContext?
        if case .verified(let snapshot) = state,
           let request = timelineBoundaryRequest,
           request.phase == .waitingRemote,
           request.locator == snapshot.target,
           request.remoteIntentID == archiveWindowIntent?.id {
            retainedRemoteBoundaryRequest = request
        } else {
            retainedRemoteBoundaryRequest = nil
            timelineBoundaryRequest = nil
        }
        let wasVisibleTimelineBoundaryRequest =
            retainedRemoteBoundaryRequest?.isVisible == true
        let preservesCommittedContent: Bool
        if case .verified(let incoming) = state {
            preservesCommittedContent =
                ChatArchiveWindowPresentationPolicy.shouldPreserveCommittedContent(
                    currentState: archiveWindowState,
                    committedCoverageGeneration: archiveWindowCommittedCoverageGeneration,
                    incoming: incoming,
                    currentVerifiedScope: timelineSession?.verifiedScope
                )
        } else {
            preservesCommittedContent = false
        }
        invalidateProofScopedLocalTargetPreparation()
        invalidateCommittedTimelineLocalPresentation()
        archiveWindowAuthoritativeEmptyApplyGeneration = nil
        archiveWindowAuthoritativeEmptyMappingGeneration = nil
        archiveWindowState = state
        archiveWindowApplyGeneration &+= 1
        archiveWindowLiveEdgeApplyGeneration = nil
        let applyGeneration = archiveWindowApplyGeneration
        switch state {
        case .skeleton(let reason, _):
            invalidateArchiveEngineVerifiedScope()
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowPendingSnapshot = nil
            archiveWindowPendingLiveEdgeAdmission = nil
            archiveWindowBoundaryLoadingTarget = nil
            archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
            cancelDatasetMappingJobs()
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            let didCommitSkeleton =
                commitArchiveEngineOpeningSkeletonSynchronously()
            refreshArchiveBoundaryLoadingIndicator()
            if !didCommitSkeleton || reason == .offline {
                endArchiveInteractiveCriticalSection()
            }
        case .retryableFailure(let failure, _):
            invalidateArchiveEngineVerifiedScope()
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowPendingSnapshot = nil
            archiveWindowPendingLiveEdgeAdmission = nil
            archiveWindowBoundaryLoadingTarget = nil
            archiveSkeletonBeganAt = archiveSkeletonBeganAt ?? Date()
            cancelDatasetMappingJobs()
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            let didCommitFailureSkeleton =
                commitArchiveEngineOpeningSkeletonSynchronously()
            refreshArchiveBoundaryLoadingIndicator()
            if !didCommitFailureSkeleton {
                setArchiveLoading(false)
            }
            endArchiveInteractiveCriticalSection()
            switch failure.recoveryAction {
            case .retry:
                scheduleArchiveHistoryAutomaticRetry(
                    failureRetryCount: failure.retryCount
                )
            case .recoverAccount:
                cancelArchiveHistoryAutomaticRetry()
                CredentialsExpiredPresenter(jid: owner).present(animated: true)
            }
        case .verified(let snapshot):
            let isVisibleBoundaryIntent = archiveWindowIntent.map {
                $0.locator == snapshot.target && $0.priority >= .target
            } ?? false
            if (wasVisibleTimelineBoundaryRequest || isVisibleBoundaryIntent),
               ChatArchiveWindowPresentationPolicy.boundaryDirection(
                    for: snapshot.target
               ) != nil {
                archiveWindowBoundaryLoadingTarget = snapshot.target
            }
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
            invalidateArchiveEngineVerifiedScope()
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowPendingSnapshot = nil
            archiveWindowBoundaryLoadingTarget = nil
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
            refreshArchiveBoundaryLoadingIndicator()
            archiveWindowAuthoritativeEmptyApplyGeneration =
                applyGeneration
            archiveWindowAuthoritativeEmptyMappingGeneration = nil
            applyArchiveEngineAuthoritativeEmpty(
                state: state,
                applyGeneration: applyGeneration
            )
        }
    }

    private func receiveArchiveBoundaryTerminal(
        _ outcome: ArchiveBoundaryTerminalOutcome
    ) {
        assert(Thread.isMainThread)
        guard var request = timelineBoundaryRequest,
              request.phase == .waitingRemote,
              request.remoteIntentID == outcome.requestID,
              request.locator == outcome.descriptor.locator,
              archiveEngineConversationKey == outcome.descriptor.conversation else {
            return
        }
        request.remoteTerminal = outcome.result
        timelineBoundaryRequest = request

        switch outcome.result {
        case .succeeded:
            cancelArchiveHistoryAutomaticRetry()
            completeSucceededRemoteTimelineBoundaryIfReady()
        case .failed(let failure):
            switch failure.recoveryAction {
            case .retry:
                endArchiveInteractiveCriticalSection()
                scheduleArchiveHistoryAutomaticRetry(
                    failureRetryCount: failure.retryCount,
                    expectedBoundaryRequestID: request.id
                )
            case .recoverAccount:
                cancelArchiveHistoryAutomaticRetry()
                timelineBoundaryRequest = nil
                archiveWindowBoundaryPresentationAnchor = nil
                if request.isVisible {
                    completeArchiveBoundaryLoadingIndicator(
                        for: request.locator
                    )
                    endArchiveInteractiveCriticalSection()
                }
                CredentialsExpiredPresenter(jid: owner).present(animated: true)
                if pendingOpenMessageRequest != nil {
                    performPendingOpenMessageRequestIfNeeded()
                }
                drainTimelinePresentationLanesAfterAnchorTerminal()
            }
        case .cancelled:
            cancelArchiveHistoryAutomaticRetry()
            timelineBoundaryRequest = nil
            archiveWindowBoundaryPresentationAnchor = nil
            if request.isVisible {
                completeArchiveBoundaryLoadingIndicator(for: request.locator)
                endArchiveInteractiveCriticalSection()
            }
            if pendingOpenMessageRequest != nil {
                performPendingOpenMessageRequestIfNeeded()
            }
            drainTimelinePresentationLanesAfterAnchorTerminal()
        }
    }

    private func completeSucceededRemoteTimelineBoundaryIfReady() {
        assert(Thread.isMainThread)
        guard let request = timelineBoundaryRequest,
              request.phase == .waitingRemote,
              request.didWinUIKitApply,
              case .succeeded = request.remoteTerminal else {
            return
        }
        cancelArchiveHistoryAutomaticRetry()
        timelineBoundaryRequest = nil
        archiveWindowBoundaryPresentationAnchor = nil
        if request.isVisible {
            completeArchiveBoundaryLoadingIndicator(for: request.locator)
            endArchiveInteractiveCriticalSection()
        }
        if pendingOpenMessageRequest != nil {
            performPendingOpenMessageRequestIfNeeded()
        }
        drainTimelinePresentationLanesAfterAnchorTerminal()
    }

    private func receiveArchiveWindowActivity(_ activity: ArchiveWindowActivity) {
        assert(Thread.isMainThread)
        guard archiveWindowActivityTask != nil else { return }
        // Activity is visual telemetry only. In particular, an idle tick (or
        // an unrelated vCard IQ error elsewhere on the stream) cannot become
        // an archive terminal; only the request-keyed terminal stream may do so.
        archiveWindowActivity = activity
        refreshArchiveBoundaryLoadingIndicator()
    }

    internal func beginArchiveBoundaryLoadingIndicator(
        for target: ArchiveWindowLocator
    ) {
        guard ChatArchiveWindowPresentationPolicy.boundaryDirection(for: target) != nil else {
            return
        }
        archiveWindowBoundaryLoadingTarget = target
        refreshArchiveBoundaryLoadingIndicator()
    }

    internal func completeArchiveBoundaryLoadingIndicator(
        for target: ArchiveWindowLocator
    ) {
        if archiveWindowBoundaryLoadingTarget == target {
            archiveWindowBoundaryLoadingTarget = nil
        }
        refreshArchiveBoundaryLoadingIndicator()
    }

    internal func refreshArchiveBoundaryLoadingIndicator() {
        guard archiveWindowBoundaryLoadingTarget != nil else {
            setArchiveLoading(false)
            return
        }
        setArchiveLoading(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: archiveWindowActivity,
                pendingRequestTarget: archiveWindowBoundaryLoadingTarget,
                pendingPresentationTarget: archiveWindowPendingSnapshot?.target,
                isShowingFullSkeleton: showSkeletonObserver.value
            )
        )
    }

    internal func revealSensitiveMediaAndRemapCommittedTimeline(
        referencePrimary: String
    ) {
        assert(Thread.isMainThread)
        guard referencePrimary.isNotEmpty else { return }
        revealedSensitiveMediaPrimaries.insert(referencePrimary)
        committedTimelineSensitiveRevealRemapRetryCount = 0
        committedTimelineSensitiveRevealRemapPending = true
        drainPendingCommittedTimelineSensitiveRevealRemap()
    }

    internal func drainPendingCommittedTimelineSensitiveRevealRemap() {
        assert(Thread.isMainThread)
        guard !anchorTransactionGate.snapshot.positioningStarted,
              committedTimelineSensitiveRevealRemapPending,
              committedTimelineLocalPresentationToken == nil,
              timelineBoundaryRequest == nil,
              proofScopedLocalTargetRequest == nil,
              let session = timelineSession,
              let scope = committedTimelineScope() else {
            return
        }

        archiveWindowApplyGeneration &+= 1
        let applyGeneration = archiveWindowApplyGeneration
        if deferArchiveEnginePresentationIfTimelineStoreApplyActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.drainPendingCommittedTimelineSensitiveRevealRemap()
            }
        ) {
            return
        }

        let base = session.snapshot
        let token = ChatCommittedTimelineLocalPresentationToken(
            id: UUID(),
            purpose: .sensitiveReveal,
            scope: scope,
            sessionGeneration: base.generation,
            applyGeneration: applyGeneration
        )
        guard beginCommittedTimelineLocalPresentation(token) else {
            return
        }
        committedTimelineSensitiveRevealRemapPending = false

        let mappingJob = beginDatasetMappingJob()
        // The reveal set is part of the immutable mapping epoch. Capture it
        // only after the user's reference has been admitted above.
        let mappingContext = captureDatasourceMappingContext()
        let presentationEpoch = committedTimelineSensitiveRevealEpoch(
            mappingContext: mappingContext
        )
        let retainedAnchor = captureCommittedTimelineSensitiveRevealAnchor()

        datasetMappingQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            let mappingResult = self.mapDataset(
                dataset: base.items,
                context: mappingContext,
                cancellationToken: mappingJob.token
            )
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                let remainsCurrent =
                    self.committedTimelineLocalPresentationToken == token &&
                    self.timelineSession === session &&
                    self.archiveWindowApplyGeneration == applyGeneration &&
                    self.datasetMappingGeneration == mappingJob.generation &&
                    !mappingJob.token.isCancelled &&
                    !mappingResult.wasCancelled &&
                    session.snapshot.generation == base.generation &&
                    session.verifiedScope == scope &&
                    self.committedTimelineScope(
                        matching: scope,
                        allowingLocalPresentationID: token.id,
                        allowsPendingLiveEdgeAdmission: true
                    ) == scope &&
                    ChatTimelineStorePresentationEpochPolicy.isCurrent(
                        presentationEpoch,
                        current: self.committedTimelineSensitiveRevealEpoch(
                            mappingContext:
                                self.captureDatasourceMappingContext()
                        )
                    )
                let expectedPrimaryIDs = Set(base.items.map(\.primary))
                let mappedPrimaryIDs = Set(
                    mappingResult.datasource.map(\.primary)
                )
                guard remainsCurrent,
                      expectedPrimaryIDs == mappedPrimaryIDs,
                      base.items.count == mappingResult.datasource.count else {
                    if self.committedTimelineLocalPresentationToken == token {
                        let hasNewRevealRequest =
                            self.timelineSession === session &&
                            mappingContext
                                .revealedSensitiveMediaPrimaries !=
                            self.revealedSensitiveMediaPrimaries
                        let remainsInCommittedScope =
                            self.timelineSession === session &&
                            self.archiveWindowApplyGeneration ==
                                applyGeneration &&
                            session.snapshot.generation == base.generation &&
                            session.verifiedScope == scope &&
                            self.committedTimelineScope(
                                matching: scope,
                                allowingLocalPresentationID: token.id,
                                allowsPendingLiveEdgeAdmission: true
                            ) == scope
                        let shouldRetry =
                            ChatCommittedTimelineSensitiveRevealRetryPolicy
                                .shouldRetry(
                                    remainsInCommittedScope:
                                        remainsInCommittedScope,
                                    hasNewRevealRequest:
                                        hasNewRevealRequest,
                                    didFail: true,
                                    retryCount: self
                                        .committedTimelineSensitiveRevealRemapRetryCount
                                )
                        if shouldRetry {
                            if hasNewRevealRequest {
                                self.committedTimelineSensitiveRevealRemapRetryCount = 0
                            } else {
                                self.committedTimelineSensitiveRevealRemapRetryCount += 1
                            }
                        }
                        self.committedTimelineSensitiveRevealRemapPending =
                            shouldRetry
                        self.finishCommittedTimelineLocalPresentation(
                            id: token.id
                        )
                        if self.pendingOpenMessageRequest != nil {
                            self.performPendingOpenMessageRequestIfNeeded()
                        }
                        self.drainTimelinePresentationLanesAfterAnchorTerminal()
                    }
                    return
                }

                let restoreAnchor = retainedAnchor.flatMap {
                    mappedPrimaryIDs.contains($0.primary) ? $0 : nil
                }
                self.applyChatDatasource(
                    mappingResult.datasource,
                    mode: .targetedDiff,
                    animated: false,
                    invalidateLayout: false,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: true,
                    anchorRestorePhase:
                        restoreAnchor == nil ? .none : .applyTransaction,
                    anchorPrimary: restoreAnchor?.primary,
                    restoreAnchor: restoreAnchor,
                    presentationOwner: .archiveEngine,
                    presentationCommitMode: .atomicInitialFrame,
                    transactionCommitAuthorization: { [weak self, weak session] in
                        guard let self, let session else { return false }
                        return self.committedTimelineLocalPresentationToken == token &&
                            self.timelineSession === session &&
                            self.archiveWindowApplyGeneration == applyGeneration &&
                            self.datasetMappingGeneration == mappingJob.generation &&
                            !mappingJob.token.isCancelled &&
                            session.snapshot.generation == base.generation &&
                            session.verifiedScope == scope &&
                            self.committedTimelineScope(
                                matching: scope,
                                allowingLocalPresentationID: token.id,
                                allowsPendingLiveEdgeAdmission: true
                            ) == scope &&
                            ChatTimelineStorePresentationEpochPolicy.isCurrent(
                                presentationEpoch,
                                current: self
                                    .committedTimelineSensitiveRevealEpoch(
                                        mappingContext: self
                                            .captureDatasourceMappingContext()
                                    )
                            )
                    },
                    transactionCompletion: { [weak self, weak session] result in
                        guard case .failed = result else { return }
                        guard let self else { return }
                        guard self.committedTimelineLocalPresentationToken == token
                        else {
                            return
                        }
                        let hasNewRevealRequest =
                            mappingContext.revealedSensitiveMediaPrimaries !=
                                self.revealedSensitiveMediaPrimaries
                        let remainsInCommittedScope =
                            session.map { currentSession in
                                self.timelineSession === currentSession &&
                                    self.archiveWindowApplyGeneration ==
                                        applyGeneration &&
                                    currentSession.snapshot.generation ==
                                        base.generation &&
                                    currentSession.verifiedScope == scope &&
                                    self.committedTimelineScope(
                                        matching: scope,
                                        allowingLocalPresentationID: token.id,
                                        allowsPendingLiveEdgeAdmission: true
                                    ) == scope
                            } ?? false
                        let shouldRequeue =
                            ChatCommittedTimelineSensitiveRevealRetryPolicy
                                .shouldRetry(
                                    remainsInCommittedScope:
                                        remainsInCommittedScope,
                                    hasNewRevealRequest:
                                        hasNewRevealRequest,
                                    didFail: true,
                                    retryCount: self
                                        .committedTimelineSensitiveRevealRemapRetryCount
                                )
                        if shouldRequeue {
                            if hasNewRevealRequest {
                                self.committedTimelineSensitiveRevealRemapRetryCount = 0
                            } else {
                                self.committedTimelineSensitiveRevealRemapRetryCount += 1
                            }
                        }
                        self.committedTimelineSensitiveRevealRemapPending =
                            shouldRequeue
                        self.finishCommittedTimelineLocalPresentation(
                            id: token.id
                        )
                        if self.pendingOpenMessageRequest != nil {
                            self.performPendingOpenMessageRequestIfNeeded()
                        }
                        self.drainTimelinePresentationLanesAfterAnchorTerminal()
                    },
                    completion: { [weak self, weak session] in
                        guard let self, let session,
                              self.committedTimelineLocalPresentationToken == token,
                              self.timelineSession === session,
                              self.archiveWindowApplyGeneration == applyGeneration,
                              session.snapshot.generation == base.generation,
                              session.verifiedScope == scope,
                              self.committedTimelineScope(
                                matching: scope,
                                allowingLocalPresentationID: token.id,
                                allowsPendingLiveEdgeAdmission: true
                              ) == scope else {
                            return
                        }
                        self.committedTimelineSensitiveRevealRemapPending = false
                        self.committedTimelineSensitiveRevealRemapRetryCount = 0
                        self.finishCommittedTimelineLocalPresentation(
                            id: token.id
                        )
                        if self.pendingOpenMessageRequest != nil {
                            self.performPendingOpenMessageRequestIfNeeded()
                        }
                        self.drainTimelinePresentationLanesAfterAnchorTerminal()
                    }
                )
            }
        }
    }

    private func committedTimelineSensitiveRevealEpoch(
        mappingContext: ChatDatasourceMappingContext
    ) -> ChatTimelineStorePresentationEpoch {
        ChatTimelineStorePresentationEpoch(
            datasourceGeneration: scrollResidentMetadataGeneration,
            layoutGeneration: layoutPreparationGeneration,
            layoutContext: mappingContext.layoutContext,
            displayContext: mappingContext.displayCacheContext,
            inSearchMode: mappingContext.inSearchMode,
            revealedSensitiveMediaPrimaries:
                mappingContext.revealedSensitiveMediaPrimaries,
            canPinMessages: mappingContext.canPinMessages
        )
    }

    private func captureCommittedTimelineSensitiveRevealAnchor()
        -> ChatHistoryPageAnchor? {
        for indexPath in messagesCollectionView.indexPathsForVisibleItems
            .sorted(by: { $0.section < $1.section }) {
            guard datasource.indices.contains(indexPath.section) else {
                continue
            }
            let item = datasource[indexPath.section]
            guard !item.isFakeMessage else { continue }
            let frame = messagesCollectionView.layoutAttributesForItem(
                at: indexPath
            )?.frame ?? messagesCollectionView.cellForItem(
                at: indexPath
            )?.frame
            guard let frame else { continue }
            return ChatHistoryPageAnchor(
                primary: item.primary,
                viewportRelativeMinY:
                    frame.minY - messagesCollectionView.contentOffset.y
            )
        }
        return nil
    }

    private func applyArchiveEngineVerifiedSnapshot(
        _ snapshot: ArchiveWindowSnapshot,
        applyGeneration: UInt64
    ) {
        if deferArchiveEnginePresentationIfAnchorPositioningActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.applyArchiveEngineVerifiedSnapshot(
                    snapshot,
                    applyGeneration: applyGeneration
                )
            }
        ) {
            return
        }
        if deferArchiveEnginePresentationIfTimelineStoreApplyActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.applyArchiveEngineVerifiedSnapshot(
                    snapshot,
                    applyGeneration: applyGeneration
                )
            }
        ) {
            return
        }
        guard let session = timelineSession else {
            finishArchiveEngineVerifiedMaterializationFailure(
                snapshot: snapshot,
                applyGeneration: applyGeneration,
                session: nil
            )
            return
        }
        let mappingJob = beginDatasetMappingJob()
        let mappingContext = captureDatasourceMappingContext()

        datasetMappingQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            let base = session.snapshot
            let previousScope = session.verifiedScope
            guard !mappingJob.token.isCancelled,
                  let prepared = session.prepareArchiveEngineVerifiedWindow(snapshot),
                  let candidate = session.inspectPreparedArchiveEngineVerifiedWindow(
                    prepared
                  ) else {
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.finishArchiveEngineVerifiedMaterializationFailure(
                        snapshot: snapshot,
                        applyGeneration: applyGeneration,
                        session: session
                    )
                }
                return
            }
            let mappingResult = self.mapDataset(
                dataset: candidate.items,
                context: mappingContext,
                cancellationToken: mappingJob.token
            )
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                guard self.timelineSession === session,
                      self.archiveWindowStateTask != nil,
                      self.archiveWindowApplyGeneration == applyGeneration,
                      self.datasetMappingGeneration == mappingJob.generation,
                      !mappingJob.token.isCancelled,
                      !mappingResult.wasCancelled,
                      case .verified(let current) = self.archiveWindowState,
                      current == snapshot else {
                    self.finishArchiveEngineVerifiedMaterializationFailure(
                        snapshot: snapshot,
                        applyGeneration: applyGeneration,
                        session: session
                    )
                    return
                }
                let forceBottom =
                    ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                        for: snapshot.target,
                        itemCount: candidate.items.count
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
                let currentOwnedPendingRequest =
                    self.pendingOpenMessageRequest.flatMap { request in
                        ChatInitialTargetFirstFramePolicy.owns(
                            request: request,
                            owner: self.owner,
                            jid: self.jid,
                            conversationType: self.conversationType
                        ) ? request : nil
                    }
                if let request = currentOwnedPendingRequest {
                    self.initialTargetFirstFrameContext?.retarget(to: request)
                }
                let initialTargetFirstFrameRequest =
                    self.initialTargetFirstFrameContext.flatMap { context in
                        currentOwnedPendingRequest == context.request
                            ? context.request
                            : nil
                    }
                let resolvedInitialTargetIndex =
                    initialTargetFirstFrameRequest.flatMap { request in
                        ChatLoadedMessageNavigationPolicy.index(
                            in: mappingResult.datasource,
                            for: request
                        )
                    }
                let resolvedInitialTargetPrimary =
                    resolvedInitialTargetIndex.flatMap { index in
                        mappingResult.datasource.indices.contains(index)
                            ? mappingResult.datasource[index].primary
                            : nil
                    }
                let resolvedInitialTargetHeight =
                    resolvedInitialTargetPrimary.flatMap { primary in
                        mappingResult.layoutSnapshot
                            .layout(forPrimary: primary)?.cellSize.height
                    }
                let targetFirstFramePlan =
                    ChatInitialTargetFirstFramePolicy.plan(
                        request: initialTargetFirstFrameRequest,
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType,
                        resolvedTargetPrimary: resolvedInitialTargetPrimary,
                        viewportHeight:
                            self.messagesCollectionView.bounds.height,
                        targetHeight: resolvedInitialTargetHeight
                    )
                guard targetFirstFramePlan.canPublishDatasource else {
                    self.setSkeletonVisible(true)
                    self.setDatasourceLoadingEnabled(false)
                    _ = self.commitArchiveEngineOpeningSkeletonSynchronously()
                    self.finishArchiveEngineVerifiedMaterializationFailure(
                        snapshot: snapshot,
                        applyGeneration: applyGeneration,
                        session: session
                    )
                    return
                }
                let effectiveRestoreAnchor =
                    restoreAnchor ?? targetFirstFramePlan.restoreAnchor
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
                let commitReceipt = ChatTimelineBoundaryCommitReceipt()
                if targetFirstFramePlan.canCompletePreparation {
                    commitReceipt.initialTargetFirstFrameRequest =
                        initialTargetFirstFrameRequest
                }
                let presentationReceipt: ChatOpenPerformancePresentationReceipt =
                    candidate.items.isEmpty ? .empty : .content
                self.performArchiveEngineInitialPresentationTransactionIfNeeded(
                    for: snapshot.target,
                    receipt: presentationReceipt,
                    onCommitted: { [weak self] in
                        guard commitReceipt
                                .didCommitInitialTargetFirstFrame,
                              let request = commitReceipt
                                .initialTargetFirstFrameRequest else {
                            return
                        }
                        self?.completeInitialTargetFirstFrameIfNeeded(
                            request: request,
                            applyGeneration: applyGeneration
                        )
                    }
                ) {
                    self.applyChatDatasource(
                        mappingResult.datasource,
                        mode: .fullReload(keepOffset: applyPlan.keepOffset),
                        animated: false,
                        invalidateLayout: false,
                        preparedLayouts: mappingResult.layoutSnapshot,
                        suppressDefaultBottomScroll: effectiveForceBottom == nil,
                        forceBottomAlignmentTarget: effectiveForceBottom,
                        applyCategory: applyPlan.applyCategory,
                        anchorRestorePhase: effectiveRestoreAnchor == nil
                            ? applyPlan.restorePhase
                            : .applyTransaction,
                        anchorPrimary: effectiveRestoreAnchor?.primary,
                        restoreAnchor: effectiveRestoreAnchor,
                        presentationOwner: .archiveEngine,
                        presentationCommitMode: .atomicInitialFrame,
                        transactionCommitAuthorization: { [weak self, weak session] in
                            guard let self, let session,
                                  self.timelineSession === session,
                                  self.archiveWindowStateTask != nil,
                                  self.archiveWindowApplyGeneration == applyGeneration,
                                  self.datasetMappingGeneration == mappingJob.generation,
                                  !mappingJob.token.isCancelled,
                                  self.archiveWindowPendingSnapshot == snapshot,
                                  case .verified(let current) = self.archiveWindowState,
                                  current == snapshot else {
                                return false
                            }
                            if let committed = commitReceipt.snapshot {
                                return session.snapshot.generation == committed.generation
                            }
                            guard session.snapshot.generation == base.generation,
                                  session.verifiedScope == previousScope,
                                  let committed =
                                    session.commitPreparedArchiveEngineVerifiedWindow(
                                        prepared
                                    ),
                                  committed.items.map(\.primary) ==
                                    candidate.items.map(\.primary),
                                  committed.state == candidate.state else {
                                return false
                            }
                            commitReceipt.snapshot = committed
                            return true
                        },
                        transactionCompletion: { [weak self, weak session] result in
                            guard let self, let session else { return }
#if DEBUG || CHAT_PERFORMANCE_LAB
                            if case .committed(let diagnostics) = result {
                                commitReceipt.viewportDiagnostics = diagnostics
                            }
#endif
                            self.handleArchiveEngineAtomicApplyResult(
                                result,
                                snapshot: snapshot,
                                applyGeneration: applyGeneration,
                                base: base,
                                previousScope: previousScope,
                                commitReceipt: commitReceipt,
                                session: session
                            )
                        },
                        completion: { [weak self, weak session] in
                            guard let self, let session else { return }
                            guard self.timelineSession === session,
                                  self.archiveWindowStateTask != nil,
                                  self.archiveWindowApplyGeneration == applyGeneration,
                                  self.archiveWindowPendingSnapshot == snapshot,
                                  let committed = commitReceipt.snapshot,
                                  session.snapshot.generation == committed.generation,
                                  case .verified(let current) = self.archiveWindowState,
                                  current == snapshot else {
                                self.finishArchiveEngineVerifiedMaterializationFailure(
                                    snapshot: snapshot,
                                    applyGeneration: applyGeneration,
                                    session: session
                                )
                                return
                            }
                            self.archiveWindowCommittedCoverageGeneration =
                                snapshot.coverageGeneration
                            self.syncCurrentPage(
                                with: ChatDatasetWindow(
                                    minIndex: 0,
                                    maxIndex: committed.items.count
                                )
                            )
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
                            self.setDatasourceLoadingEnabled(true)
                            if let request = commitReceipt
                                    .initialTargetFirstFrameRequest {
                                self.initialTargetFirstFrameContext?
                                    .markAlignedFrameCommitted(
                                        request: request,
                                        applyGeneration: applyGeneration,
                                        datasourceGeneration:
                                            self.scrollResidentMetadataGeneration
                                    )
                            }
                            commitReceipt.didCommitInitialTargetFirstFrame =
                                targetFirstFramePlan.canCompletePreparation
                            var boundaryCompletionOwnedByTypedTerminal = false
                            if var request = self.timelineBoundaryRequest,
                               request.phase == .waitingRemote,
                               request.locator == snapshot.target,
                               request.remoteIntentID == self.archiveWindowIntent?.id {
                                request.didWinUIKitApply = true
                                self.timelineBoundaryRequest = request
                                boundaryCompletionOwnedByTypedTerminal = true
                                self.completeSucceededRemoteTimelineBoundaryIfReady()
                            }
                            if !boundaryCompletionOwnedByTypedTerminal {
                                self.completeArchiveBoundaryLoadingIndicator(
                                    for: snapshot.target
                                )
                                self.endArchiveInteractiveCriticalSection()
                                if self.pendingOpenMessageRequest != nil {
                                    self.performPendingOpenMessageRequestIfNeeded()
                                }
                            }
#if DEBUG || CHAT_PERFORMANCE_LAB
                            if let viewportDiagnostics =
                                    commitReceipt.viewportDiagnostics {
                                self.performanceFixtureWinningArchiveUIKitApplyHandler?(
                                    ChatPerformanceWinningArchiveUIKitApplyReceipt(
                                        conversationKey:
                                            self.chatTimelineConversationKey,
                                        applyGeneration: applyGeneration,
                                        sessionGeneration: committed.generation,
                                        viewportDiagnostics: viewportDiagnostics
                                    )
                                )
                            }
#endif
                            session.activateStoreObservation()
                            self.drainPendingLocalOutgoingAdmissions()
                            if !boundaryCompletionOwnedByTypedTerminal {
                                self.drainTimelinePresentationLanesAfterAnchorTerminal()
                            }
                        }
                    )
                }
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
        applyGeneration: UInt64,
        base: ChatTimelineSessionSnapshot,
        previousScope: ChatTimelineVerifiedScope?,
        commitReceipt: ChatTimelineBoundaryCommitReceipt,
        session: ChatTimelineSession
    ) {
        guard case .failed(let failure, _) = result else { return }

        let isCurrentPresentation =
            timelineSession === session &&
            archiveWindowStateTask != nil &&
            archiveWindowApplyGeneration == applyGeneration &&
            archiveWindowPendingSnapshot == snapshot &&
            {
                guard case .verified(let current) = archiveWindowState else {
                    return false
                }
                return current == snapshot
            }()

        if let committed = commitReceipt.snapshot,
           session.snapshot.generation == committed.generation {
            _ = session.restorePresentationSnapshot(
                base,
                verifiedScope: previousScope
            )
        }

        guard isCurrentPresentation else { return }
        if commitReceipt.snapshot == nil,
           ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: failure,
                completedRetryCount: archiveWindowAtomicApplyRetryCount
           ) {
            archiveWindowAtomicApplyRetryCount += 1
            scheduleArchiveEngineAtomicApplyRetry(
                snapshot: snapshot,
                applyGeneration: applyGeneration,
                remainingMotionChecks: 20
            )
            return
        }

        finishArchiveEngineVerifiedMaterializationFailure(
            snapshot: snapshot,
            applyGeneration: applyGeneration,
            session: session
        )
    }

    private func finishArchiveEngineVerifiedMaterializationFailure(
        snapshot: ArchiveWindowSnapshot,
        applyGeneration: UInt64,
        session: ChatTimelineSession?
    ) {
        assert(Thread.isMainThread)
        guard archiveWindowStateTask != nil,
              archiveWindowApplyGeneration == applyGeneration,
              archiveWindowPendingSnapshot == snapshot,
              case .verified(let current) = archiveWindowState,
              current == snapshot else {
            return
        }
        if let session {
            guard timelineSession === session else { return }
        } else {
            guard timelineSession == nil else { return }
        }

        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryWorkItem = nil
        archiveWindowAtomicApplyRetryCount =
            min(max(0, archiveWindowAtomicApplyRetryCount), 9) + 1
        archiveWindowPendingSnapshot = nil
        let retryDelay = min(
            2.0,
            Double(archiveWindowAtomicApplyRetryCount) * 0.25
        )

        let expectedSession = session
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.archiveWindowStateTask != nil,
                  self.archiveWindowApplyGeneration == applyGeneration,
                  self.archiveWindowPendingSnapshot == nil,
                  case .verified(let current) = self.archiveWindowState,
                  current == snapshot else {
                return
            }
            if let expectedSession {
                guard self.timelineSession === expectedSession else { return }
            } else {
                guard self.timelineSession == nil else { return }
            }
            self.archiveWindowAtomicApplyRetryWorkItem = nil
            self.retryArchiveEngineVerifiedMaterialization(snapshot)
        }
        archiveWindowAtomicApplyRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + retryDelay,
            execute: workItem
        )

        let presentation =
            ChatArchiveWindowPresentationPolicy.materializationFailurePresentation(
                for: snapshot.target,
                hasCommittedContent: datasource.contains { !$0.isFakeMessage }
            )
        switch presentation {
        case .preserveContent:
            setSkeletonVisible(false)
            setDatasourceLoadingEnabled(true)
            if pendingOpenMessageRequest != nil {
                performPendingOpenMessageRequestIfNeeded()
            }
            drainTimelinePresentationLanesAfterAnchorTerminal()
        case .fullSkeleton:
            archiveWindowCommittedCoverageGeneration = nil
            archiveWindowBoundaryPresentationAnchor = nil
            setSkeletonVisible(true)
            setDatasourceLoadingEnabled(false)
        }
    }

    private func retryArchiveEngineVerifiedMaterialization(
        _ snapshot: ArchiveWindowSnapshot
    ) {
        assert(Thread.isMainThread)
        guard archiveWindowStateTask != nil,
              archiveWindowPendingSnapshot == nil,
              case .verified(let current) = archiveWindowState,
              current == snapshot else {
            return
        }
        archiveWindowApplyGeneration &+= 1
        archiveWindowPendingSnapshot = snapshot
        beginArchiveBoundaryLoadingIndicator(for: snapshot.target)
        beginArchiveInteractiveCriticalSection()
        applyArchiveEngineVerifiedSnapshot(
            snapshot,
            applyGeneration: archiveWindowApplyGeneration
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
                  self.archiveWindowStateTask != nil,
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

    /// A verified authoritative-empty receipt has already completed remotely;
    /// retry only its local Realm/session-to-UIKit materialization. Re-entering
    /// the archive gateway here would duplicate the semantic MAM request.
    private func scheduleArchiveEngineAuthoritativeEmptyMaterializationRetry(
        state: ArchiveWindowState,
        applyGeneration: UInt64
    ) {
        archiveWindowAtomicApplyRetryWorkItem?.cancel()
        archiveWindowAtomicApplyRetryCount =
            min(max(0, archiveWindowAtomicApplyRetryCount), 9) + 1
        let retryDelay = min(
            2.0,
            Double(archiveWindowAtomicApplyRetryCount) * 0.25
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.archiveWindowStateTask != nil,
                  self.archiveWindowApplyGeneration == applyGeneration,
                  self.archiveWindowAuthoritativeEmptyApplyGeneration == nil,
                  self.archiveWindowAuthoritativeEmptyMappingGeneration == nil,
                  self.archiveWindowState == state,
                  self.timelineSession != nil else {
                return
            }
            self.archiveWindowAtomicApplyRetryWorkItem = nil
            self.archiveWindowAuthoritativeEmptyApplyGeneration =
                applyGeneration
            self.applyArchiveEngineAuthoritativeEmpty(
                state: state,
                applyGeneration: applyGeneration
            )
        }
        archiveWindowAtomicApplyRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + retryDelay,
            execute: workItem
        )
    }

    private func applyArchiveEngineAuthoritativeEmpty(
        state: ArchiveWindowState,
        applyGeneration: UInt64
    ) {
        if deferArchiveEnginePresentationIfAnchorPositioningActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.applyArchiveEngineAuthoritativeEmpty(
                    state: state,
                    applyGeneration: applyGeneration
                )
            }
        ) {
            return
        }
        if deferArchiveEnginePresentationIfTimelineStoreApplyActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.applyArchiveEngineAuthoritativeEmpty(
                    state: state,
                    applyGeneration: applyGeneration
                )
            }
        ) {
            return
        }
        guard archiveWindowStateTask != nil,
              archiveWindowApplyGeneration == applyGeneration,
              archiveWindowAuthoritativeEmptyApplyGeneration ==
                applyGeneration,
              archiveWindowState == state,
              let session = timelineSession,
              case .authoritativeEmpty(
                let target,
                let freshnessToken
              ) = state else {
            return
        }
        let base = session.snapshot
        let previousScope = session.verifiedScope
        let mappingJob = beginDatasetMappingJob()
        archiveWindowAuthoritativeEmptyApplyGeneration = applyGeneration
        archiveWindowAuthoritativeEmptyMappingGeneration =
            mappingJob.generation
        let mappingContext = captureDatasourceMappingContext()
        datasetMappingQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            guard !mappingJob.token.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishCancelledArchiveEngineAuthoritativeEmptyApply(
                        applyGeneration: applyGeneration,
                        mappingGeneration: mappingJob.generation
                    )
                }
                return
            }
            let mappingResult = self.mapDataset(
                dataset: [],
                context: mappingContext,
                cancellationToken: mappingJob.token
            )
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session,
                      self.timelineSession === session,
                      self.archiveWindowStateTask != nil,
                      self.archiveWindowApplyGeneration == applyGeneration,
                      self.archiveWindowAuthoritativeEmptyApplyGeneration ==
                        applyGeneration,
                      self.archiveWindowAuthoritativeEmptyMappingGeneration ==
                        mappingJob.generation,
                      self.datasetMappingGeneration == mappingJob.generation,
                      !mappingJob.token.isCancelled,
                      !mappingResult.wasCancelled,
                      self.archiveWindowState == state else {
                    self?.finishCancelledArchiveEngineAuthoritativeEmptyApply(
                        applyGeneration: applyGeneration,
                        mappingGeneration: mappingJob.generation
                    )
                    return
                }
                if self.anchorTransactionGate.snapshot.positioningStarted,
                   self.deferArchiveEnginePresentationIfAnchorPositioningActive(
                        applyGeneration: applyGeneration,
                        work: { [weak self] in
                            self?.applyArchiveEngineAuthoritativeEmpty(
                                state: state,
                                applyGeneration: applyGeneration
                            )
                        }
                   ) {
                    return
                }
                let commitReceipt = ChatTimelineBoundaryCommitReceipt()
                self.performArchiveEngineInitialPresentationTransactionIfNeeded(
                    for: target,
                    receipt: .empty
                ) {
                    self.applyChatDatasource(
                        [],
                        mode: .fullReload(keepOffset: false),
                        animated: false,
                        preparedLayouts: mappingResult.layoutSnapshot,
                        suppressDefaultBottomScroll: true,
                        presentationOwner: .archiveEngine,
                        presentationCommitMode: .atomicInitialFrame,
                        transactionCommitAuthorization: { [weak self, weak session] in
                            guard let self, let session,
                                  self.timelineSession === session,
                                  self.archiveWindowStateTask != nil,
                                  self.archiveWindowApplyGeneration == applyGeneration,
                                  self.archiveWindowAuthoritativeEmptyApplyGeneration ==
                                    applyGeneration,
                                  self.archiveWindowAuthoritativeEmptyMappingGeneration ==
                                    mappingJob.generation,
                                  self.datasetMappingGeneration == mappingJob.generation,
                                  !mappingJob.token.isCancelled,
                                  !self.anchorTransactionGate.snapshot.positioningStarted,
                                  self.archiveWindowState == state else {
                                return false
                            }
                            if let committed = commitReceipt.snapshot {
                                return session.snapshot.generation == committed.generation
                            }
                            guard session.snapshot.generation == base.generation else {
                                return false
                            }
                            let committed = session
                                .installArchiveEngineAuthoritativeEmpty(
                                    freshnessToken: freshnessToken
                                )
                            guard committed.items.isEmpty else { return false }
                            commitReceipt.snapshot = committed
                            return true
                        },
                        transactionCompletion: { [weak self, weak session] result in
#if DEBUG || CHAT_PERFORMANCE_LAB
                            if case .committed(let diagnostics) = result {
                                commitReceipt.viewportDiagnostics = diagnostics
                            }
#endif
                            guard case .failed(let failure, _) = result,
                                  let self,
                                  let session else {
                                return
                            }
                            if let committed = commitReceipt.snapshot,
                               session.snapshot.generation == committed.generation {
                                _ = session.restorePresentationSnapshot(
                                    base,
                                    verifiedScope: previousScope
                                )
                            }
                            guard self.timelineSession === session,
                                  self.archiveWindowApplyGeneration == applyGeneration,
                                  self.archiveWindowAuthoritativeEmptyApplyGeneration ==
                                    applyGeneration,
                                  self.archiveWindowAuthoritativeEmptyMappingGeneration ==
                                    mappingJob.generation,
                                  self.archiveWindowState == state else {
                                return
                            }
                            if failure == .superseded,
                               self.anchorTransactionGate.snapshot.positioningStarted,
                               self.deferArchiveEnginePresentationIfAnchorPositioningActive(
                                    applyGeneration: applyGeneration,
                                    work: { [weak self] in
                                        self?.applyArchiveEngineAuthoritativeEmpty(
                                            state: state,
                                            applyGeneration: applyGeneration
                                        )
                                    }
                               ) {
                                return
                            }
                            self.archiveWindowAuthoritativeEmptyApplyGeneration = nil
                            self.archiveWindowAuthoritativeEmptyMappingGeneration = nil
                            self.setSkeletonVisible(true)
                            self.setDatasourceLoadingEnabled(false)
                            self.scheduleArchiveEngineAuthoritativeEmptyMaterializationRetry(
                                state: state,
                                applyGeneration: applyGeneration
                            )
                        },
                        completion: { [weak self] in
                            guard let self,
                                  self.archiveWindowApplyGeneration == applyGeneration,
                                  self.archiveWindowAuthoritativeEmptyApplyGeneration ==
                                    applyGeneration,
                                  self.archiveWindowAuthoritativeEmptyMappingGeneration ==
                                    mappingJob.generation,
                                  self.archiveWindowState == state,
                                  !self.anchorTransactionGate.snapshot.positioningStarted,
                                  let committed = commitReceipt.snapshot,
                                  session.snapshot.generation == committed.generation else {
                                return
                            }
                            self.archiveWindowAuthoritativeEmptyApplyGeneration = nil
                            self.archiveWindowAuthoritativeEmptyMappingGeneration = nil
                            self.archiveWindowAtomicApplyRetryWorkItem?.cancel()
                            self.archiveWindowAtomicApplyRetryWorkItem = nil
                            self.archiveWindowAtomicApplyRetryCount = 0
                            self.syncCurrentPage(with: .empty)
                            self.archiveWindowCommittedCoverageGeneration = 0
                            self.archiveWindowPendingSnapshot = nil
                            self.recordArchiveSkeletonTerminalIfNeeded()
                            ArchiveEngineObservability.event(.uikitApply)
                            self.setSkeletonVisible(false)
                            self.refreshArchiveBoundaryLoadingIndicator()
                            self.endArchiveInteractiveCriticalSection()
                            self.setDatasourceLoadingEnabled(true)
#if DEBUG || CHAT_PERFORMANCE_LAB
                            if let viewportDiagnostics =
                                    commitReceipt.viewportDiagnostics {
                                self.performanceFixtureWinningArchiveUIKitApplyHandler?(
                                    ChatPerformanceWinningArchiveUIKitApplyReceipt(
                                        conversationKey:
                                            self.chatTimelineConversationKey,
                                        applyGeneration: applyGeneration,
                                        sessionGeneration: committed.generation,
                                        viewportDiagnostics: viewportDiagnostics
                                    )
                                )
                            }
#endif
                            let didSubmitReplacementTarget = self
                                .resolvePendingOpenMessageRequestAfterAuthoritativeEmpty(
                                    target: target
                                )
                            if !didSubmitReplacementTarget {
                                session.activateStoreObservation(
                                    authoritativeEmptyBaseline: true
                                )
                                self.drainPendingLocalOutgoingAdmissions()
                            }
                            self.drainTimelinePresentationLanesAfterAnchorTerminal()
                        }
                    )
                }
            }
        }
    }

    internal func finishCancelledArchiveEngineAuthoritativeEmptyApply(
        applyGeneration: UInt64,
        mappingGeneration: Int
    ) {
        assert(Thread.isMainThread)
        guard archiveWindowStateTask != nil,
              archiveWindowApplyGeneration == applyGeneration,
              archiveWindowAuthoritativeEmptyApplyGeneration ==
                applyGeneration,
              archiveWindowAuthoritativeEmptyMappingGeneration ==
                mappingGeneration,
              let state = archiveWindowState,
              case .authoritativeEmpty = state else {
            return
        }
        archiveWindowAuthoritativeEmptyApplyGeneration = nil
        archiveWindowAuthoritativeEmptyMappingGeneration = nil
        if anchorTransactionGate.snapshot.positioningStarted {
            archiveWindowAuthoritativeEmptyApplyGeneration = applyGeneration
            if deferArchiveEnginePresentationIfAnchorPositioningActive(
                applyGeneration: applyGeneration,
                work: { [weak self] in
                    self?.applyArchiveEngineAuthoritativeEmpty(
                        state: state,
                        applyGeneration: applyGeneration
                    )
                }
            ) {
                return
            }
            archiveWindowAuthoritativeEmptyApplyGeneration = nil
        }
        setSkeletonVisible(true)
        setDatasourceLoadingEnabled(false)
        scheduleArchiveEngineAuthoritativeEmptyMaterializationRetry(
            state: state,
            applyGeneration: applyGeneration
        )
    }

    private func performArchiveEngineInitialPresentationTransactionIfNeeded(
        for target: ArchiveWindowLocator,
        receipt: ChatOpenPerformancePresentationReceipt,
        onCommitted: (() -> Void)? = nil,
        updates: () -> Void
    ) {
        guard ChatArchiveWindowPresentationPolicy.boundaryDirection(
            for: target
        ) == nil else {
            updates()
            return
        }
        let performanceTraceContext = chatOpenPerformanceTraceContext
        if let performanceTraceContext {
            _ = chatOpenPerformanceTraceLifecycle.beginPresenting(
                context: performanceTraceContext
            )
        }
        performChatOpenPerformancePresentationTransaction(
            receipt: receipt,
            context: performanceTraceContext,
            schedulesStableFrame: true,
            completion: onCommitted,
            updates: updates
        )
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
