//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import DeepDiff
import CocoaLumberjack
import XMPPFramework.XMPPJID

enum ChatInitialBootstrapTransport: Equatable {
    case primaryAccount
    case uiAction
}

enum ChatInitialBootstrapTransportPolicy {
    static func resolve(
        hasPrimaryAccount: Bool,
        primaryStreamReady: Bool,
        primaryBootstrapGateActive: Bool
    ) -> ChatInitialBootstrapTransport {
        return hasPrimaryAccount &&
            primaryStreamReady &&
            !primaryBootstrapGateActive
            ? .primaryAccount
            : .uiAction
    }
}

struct ChatGroupMemberUnreadMetadataRefreshGate {
    private let authoritativeMemberId: String?
    private var observedFallbackMemberId: String?

    init(authoritativeMemberId: String?) {
        self.authoritativeMemberId = Self.normalized(authoritativeMemberId)
        self.observedFallbackMemberId = nil
    }

    mutating func shouldRefresh(observedMemberId: String?) -> Bool {
        guard authoritativeMemberId == nil else {
            return false
        }
        let normalizedObservedMemberId = Self.normalized(observedMemberId)
        guard normalizedObservedMemberId != observedFallbackMemberId else {
            return false
        }
        observedFallbackMemberId = normalizedObservedMemberId
        return true
    }

    private static func normalized(_ memberId: String?) -> String? {
        guard let memberId,
              !memberId.isEmpty else {
            return nil
        }
        return memberId
    }
}

enum ChatInitialBootstrapPresentationWatchdogPolicy {
    static let maximumPresentationTimeout: TimeInterval = 5

    static func timeout(
        hasCommittedPage: Bool,
        remainingTransportTimeout: TimeInterval,
        presentationTimeout: TimeInterval = maximumPresentationTimeout
    ) -> TimeInterval {
        let presentationBudget = min(
            max(0, presentationTimeout),
            maximumPresentationTimeout
        )
        guard !hasCommittedPage,
              remainingTransportTimeout > 0 else {
            return presentationBudget
        }
        return min(presentationBudget, remainingTransportTimeout)
    }
}

struct ChatInitialBootstrapRequestKey: Hashable {
    let owner: String
    let jid: String
    let conversationTypeRawValue: String

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationTypeRawValue = conversationType.rawValue
    }

    var schedulerDeduplicationKey: String {
        "conversation.archive.\(owner).\(jid).\(conversationTypeRawValue)"
    }

    /// The conversation key deduplicates observers through the archive lease.
    /// The query suffix keeps a replacement lease from being swallowed by a
    /// stale scheduler closure that belongs to an expired query.
    func schedulerDeduplicationKey(queryId: String) -> String {
        "\(schedulerDeduplicationKey).query.\(queryId)"
    }
}

enum ChatInitialBootstrapFollowUpTargetPolicy {
    static func target(
        coordinatorRequest:
            ChatInitialBootstrapRequestCoordinator.PendingFollowUpTarget?
    ) -> MessageArchiveManager.ChatBootstrapPageTarget {
        coordinatorRequest?.fingerprint.target ?? .latest
    }

    static func consumesSnapshotRepairBudget(
        coordinatorRequest:
            ChatInitialBootstrapRequestCoordinator.PendingFollowUpTarget?
    ) -> Bool {
        coordinatorRequest?.purpose != .interactiveBootstrap
    }

    static func matchesActiveLease(
        coordinatorRequest:
            ChatInitialBootstrapRequestCoordinator.PendingFollowUpTarget?,
        activeTargetFingerprint:
            MessageArchiveManager.ChatBootstrapTargetFingerprint?,
        activePerformanceSemanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint?
    ) -> Bool {
        guard let coordinatorRequest else {
            return true
        }
        guard coordinatorRequest.fingerprint.target ==
                activeTargetFingerprint?.target else {
            return false
        }
        guard let pendingSemanticTargetFingerprint =
                coordinatorRequest.performanceSemanticTargetFingerprint else {
            return true
        }
        return pendingSemanticTargetFingerprint ==
            activePerformanceSemanticTargetFingerprint
    }
}

enum ChatInitialBootstrapRequestAdmissionPolicy {
    static func shouldAcquire(
        requiresArchiveConfirmation: Bool,
        hasUncommittedLease: Bool,
        hasPendingTargetPage: Bool
    ) -> Bool {
        requiresArchiveConfirmation ||
            hasUncommittedLease ||
            hasPendingTargetPage
    }
}

enum ChatInitialBootstrapSatisfiedPresentationPolicy {
    static func loadingState(
        localMessageCount: Int,
        hasPendingInitialAnchorRequest: Bool
    ) -> ChatBootstrapLoadingState {
        if hasPendingInitialAnchorRequest {
            return .blockingTarget
        }
        return localMessageCount > 0 ? .content : .empty
    }
}

/// Persistence-aware lifecycle for one conversation archive transaction.
///
/// The phase is account-scoped through `ChatInitialBootstrapRequestKey`; it is
/// deliberately independent from a particular chat controller lifecycle.
enum ConversationArchiveLoadPhase: String, Equatable {
    case queued
    case transport
    case persistence
    case committed
    case failed

    var traceCode: Int {
        switch self {
        case .queued: return 1
        case .transport: return 2
        case .persistence: return 3
        case .committed: return 4
        case .failed: return 5
        }
    }
}

enum ConversationArchiveLoadPurpose: String, Equatable {
    case interactiveBootstrap
    case snapshotRepair

    var persistencePriority: ArchivePersistencePriority {
        switch self {
        case .interactiveBootstrap:
            return .interactive
        case .snapshotRepair:
            return .background
        }
    }

    var traceCode: Int {
        switch self {
        case .interactiveBootstrap: return 1
        case .snapshotRepair: return 2
        }
    }
}

struct ConversationArchiveReadiness: Equatable {
    let phase: ConversationArchiveLoadPhase
    let hasDurableCoverage: Bool
    let confirmsEmptyConversation: Bool
    let persistedVisibleRowCount: Int
    let boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint?

    init(
        phase: ConversationArchiveLoadPhase,
        hasDurableCoverage: Bool,
        confirmsEmptyConversation: Bool,
        persistedVisibleRowCount: Int,
        boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint? = nil
    ) {
        self.phase = phase
        self.hasDurableCoverage = hasDurableCoverage
        self.confirmsEmptyConversation = confirmsEmptyConversation
        self.persistedVisibleRowCount = persistedVisibleRowCount
        self.boundaryFingerprint = boundaryFingerprint
    }

    var isTerminal: Bool {
        phase == .committed || phase == .failed
    }
}

struct ChatLegacyArchivePresentationProof: Equatable {
    let hasPresentationMaterialization: Bool
    let confirmsEmptyConversation: Bool
}

enum ChatLegacyArchivePresentationProofPolicy {
    static func resolve(
        event: MessageArchiveEndPageEvent,
        persistenceSummary: MessageManager.ArchivePersistenceSummary,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        hasPersistenceSource: Bool
    ) -> ChatLegacyArchivePresentationProof {
        let hasPresentationMaterialization =
            persistenceSummary.visibleRows(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ) > 0
        let confirmsEmptyConversation =
            (hasPersistenceSource || event.source == .localCallback) &&
            event.state.archiveEnded &&
            event.count == 0 &&
            persistenceSummary.isEmpty
        return ChatLegacyArchivePresentationProof(
            hasPresentationMaterialization: hasPresentationMaterialization,
            confirmsEmptyConversation: confirmsEmptyConversation
        )
    }
}

/// Owns the transport lifetime of the initial chat archive request.
///
/// A chat controller may disappear while its MAM request is still active. The
/// coordinator keeps that request alive, lets the next controller join it and
/// applies one absolute deadline to the conversation instead of restarting a
/// controller-scoped timeout on every open.
final class ChatInitialBootstrapRequestCoordinator {
    struct ObservationToken: Hashable {
        fileprivate let id = UUID()
    }

    struct Lease: Equatable {
        let queryId: String
        let deadline: Date
        let purpose: ConversationArchiveLoadPurpose
        let targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint
        let performanceTraceContext: ChatOpenPerformanceTraceContext?
        let performanceSemanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint?
        let performanceSkeletonReceiptWasCommitted: Bool
    }

    struct PerformanceTraceAdoption: Equatable {
        let context: ChatOpenPerformanceTraceContext
        let hasSkeletonReceipt: Bool
    }

    struct PendingFollowUpTarget: Equatable {
        let fingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint
        let purpose: ConversationArchiveLoadPurpose
        let performanceSemanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint?
    }

    struct CommittedPage: Equatable {
        let event: MessageArchiveEndPageEvent
        let completion: ChatRemoteHistoryCompletionResult
        let boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint?
        let confirmsEmptyConversation: Bool
        let hasPresentationMaterialization: Bool
        let recommendedFollowUpTarget:
            MessageArchiveManager.ChatBootstrapPageTarget?

        init(
            event: MessageArchiveEndPageEvent,
            completion: ChatRemoteHistoryCompletionResult,
            boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint? = nil,
            confirmsEmptyConversation: Bool = false,
            hasPresentationMaterialization: Bool = true,
            recommendedFollowUpTarget:
                MessageArchiveManager.ChatBootstrapPageTarget? = nil
        ) {
            self.event = event
            self.completion = completion
            self.boundaryFingerprint = boundaryFingerprint
            self.confirmsEmptyConversation = confirmsEmptyConversation
            self.hasPresentationMaterialization =
                hasPresentationMaterialization
            self.recommendedFollowUpTarget = recommendedFollowUpTarget
        }
    }

    enum Acquisition {
        case start(Lease)
        case joined(Lease)
        case terminal(MessageArchiveRequestFailureEvent)
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    /// Conversation-scoped, privacy-safe production lifecycle counters. The
    /// coordinator deliberately retains terminal counts after the lease is
    /// removed so fast work cannot disappear between fixture samples.
    struct ProductionDiagnosticsSnapshot: Equatable {
        var leaseStartCount: Int
        var leaseJoinCount: Int
        var activeLeaseCount: Int
        var completedLeaseCount: Int
        var failedLeaseCount: Int
        var cancelledLeaseCount: Int
        var transportStartCount: Int

        static let zero = ProductionDiagnosticsSnapshot(
            leaseStartCount: 0,
            leaseJoinCount: 0,
            activeLeaseCount: 0,
            completedLeaseCount: 0,
            failedLeaseCount: 0,
            cancelledLeaseCount: 0,
            transportStartCount: 0
        )

        var leaseEventCount: Int {
            leaseStartCount + leaseJoinCount
        }
    }
#endif

    typealias StartObserver = (
        String,
        MessageArchiveManager.SyncChatStartResult,
        MessageManager?
    ) -> Void
    typealias ReadinessObserver = (ConversationArchiveReadiness?) -> Void

    static let shared = ChatInitialBootstrapRequestCoordinator()

    private struct Attempt {
        var lease: Lease
        let enqueuedAt: Date
        let operationTraceID: UInt64
        let predecessorOperationTraceID: UInt64?
        let persistenceTimeout: TimeInterval
        var phase: ConversationArchiveLoadPhase
        var persistencePriority: ArchivePersistencePriority
        var observers: [StartObserver]
        var startResult: MessageArchiveManager.SyncChatStartResult?
        // Keep the query-scoped persistence pipeline alive even when the
        // controller and its UI-action session disappear before a cached
        // final page is consumed by a reopened chat.
        var messages: MessageManager?
        var archiveManager: MessageArchiveManager?
        var cancelTransport: (() -> Void)?
        var timeoutWorkItem: DispatchWorkItem?
        var endDispatcherToken: MessageArchiveEndPageDispatcher.Token?
        var failureDispatcherToken: MessageArchiveRequestFailureDispatcher.Token?
        var failurePreparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token?
        var endPageEvent: MessageArchiveEndPageEvent?
        var committedPage: CommittedPage?
        var committedPageProvidesDurableCoverage: Bool
        var hasDurableCoverage: Bool
        var confirmsEmptyConversation: Bool
        var schedulerCompletion: (() -> Void)?
        var hasWireTerminal: Bool
        var didRegisterPersistenceSource: Bool
        var isPersistenceCommitClaimed: Bool
        var followUpTargetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint?
        var followUpTargetPurpose: ConversationArchiveLoadPurpose?
        var followUpPerformanceSemanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint?
        // A terminal consumer may finish before another joined consumer's
        // queued presentation callback runs. Keep the lightweight receipt
        // until every observer that joined this lease has detached.
        var isCommittedRemovalDeferredUntilObserversDetach: Bool
        // `acquireOrJoin` and the controller's readiness observation are two
        // consecutive main-owned calls, but snapshot terminal reconciliation
        // may run between them. Reserve only an interactive committed join so
        // that reconciliation cannot remove the receipt in that interval.
        var hasInteractiveCommittedJoinAwaitingObservation: Bool
    }

    private struct Cleanup {
        let owner: String
        let queryId: String
        let performanceTraceContext: ChatOpenPerformanceTraceContext?
        let timeoutWorkItem: DispatchWorkItem?
        let endDispatcherToken: MessageArchiveEndPageDispatcher.Token?
        let failureDispatcherToken: MessageArchiveRequestFailureDispatcher.Token?
        let failurePreparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token?
        let cancelTransport: (() -> Void)?
        let schedulerCompletion: (() -> Void)?
    }

    private struct AttemptIdentity: Hashable {
        let key: ChatInitialBootstrapRequestKey
        let queryId: String
    }

    private static let terminalTombstoneLimit = 64
    private static let finalReceivedAttemptLimit = 64
    private static let cancelledTransportIdentityLimit = 128
    private static let operationTracePredecessorLimit = 128

    private let lock = NSLock()
    private let now: () -> Date
    private let automaticallySchedulesTimeouts: Bool
    private let performanceTraceRegistry: ChatArchivePerformanceTraceRegistry
    private var attemptsByKey: [ChatInitialBootstrapRequestKey: Attempt] = [:]
    private var terminalFailuresByKey: [ChatInitialBootstrapRequestKey: MessageArchiveRequestFailureEvent] = [:]
    private var terminalFailureOrder: [ChatInitialBootstrapRequestKey] = []
    private var finalReceivedOrder: [ChatInitialBootstrapRequestKey] = []
    private var cancelledTransportIdentities: Set<AttemptIdentity> = []
    private var cancelledTransportIdentityOrder: [AttemptIdentity] = []
    private var readinessObserversByKey: [
        ChatInitialBootstrapRequestKey: [UUID: ReadinessObserver]
    ] = [:]
    private var nextOperationTraceID: UInt64 = 0
    private var latestOperationTraceIDByKey: [ChatInitialBootstrapRequestKey: UInt64] = [:]
    private var operationTraceKeyOrder: [ChatInitialBootstrapRequestKey] = []
#if DEBUG || CHAT_PERFORMANCE_LAB
    private var productionDiagnosticsByKey: [
        ChatInitialBootstrapRequestKey: ProductionDiagnosticsSnapshot
    ] = [:]
#endif

    /// Test seam for the timeout-vs-commit handoff. It runs only after the
    /// coordinator atomically owns the persistence terminal.
    var persistenceCommitClaimObserver: ((String) -> Void)?

    init(
        now: @escaping () -> Date = Date.init,
        automaticallySchedulesTimeouts: Bool = true,
        performanceTraceRegistry: ChatArchivePerformanceTraceRegistry = .shared
    ) {
        self.now = now
        self.automaticallySchedulesTimeouts = automaticallySchedulesTimeouts
        self.performanceTraceRegistry = performanceTraceRegistry
    }

    private func reserveOperationTraceLocked(
        for key: ChatInitialBootstrapRequestKey
    ) -> (traceID: UInt64, predecessorTraceID: UInt64?) {
        nextOperationTraceID &+= 1
        if nextOperationTraceID == 0 {
            nextOperationTraceID = 1
        }
        let traceID = nextOperationTraceID
        let predecessorTraceID = latestOperationTraceIDByKey[key]
        latestOperationTraceIDByKey[key] = traceID
        operationTraceKeyOrder.removeAll { $0 == key }
        operationTraceKeyOrder.append(key)
        while operationTraceKeyOrder.count > Self.operationTracePredecessorLimit {
            let expiredKey = operationTraceKeyOrder.removeFirst()
            latestOperationTraceIDByKey.removeValue(forKey: expiredKey)
        }
        return (traceID, predecessorTraceID)
    }

    private func traceArchiveLoad(
        _ event: String,
        attempt: Attempt,
        phase: ConversationArchiveLoadPhase,
        waitMilliseconds: Int,
        additionalFields: [(String, Any?)] = []
    ) {
        ChatArchiveDebugTrace.logOperation(
            event,
            traceID: attempt.operationTraceID,
            [
                ("purposeCode", attempt.lease.purpose.traceCode),
                ("phaseCode", phase.traceCode),
                ("waitMs", max(0, waitMilliseconds)),
                ("hasPredecessor", attempt.predecessorOperationTraceID != nil),
                ("predecessorTraceID", attempt.predecessorOperationTraceID)
            ] + additionalFields
        )
    }

    func acquire(
        key: ChatInitialBootstrapRequestKey,
        proposedQueryId: String,
        timeout: TimeInterval,
        purpose: ConversationArchiveLoadPurpose = .interactiveBootstrap,
        persistenceTimeout: TimeInterval? = nil,
        targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint = .init(
            target: .latest,
            boundary: nil
        ),
        performanceTraceContext: ChatOpenPerformanceTraceContext? = nil,
        performanceSemanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint? = nil,
        performanceSkeletonReceiptWasCommitted: Bool = false,
        observer: @escaping StartObserver
    ) -> Acquisition {
        expireAttemptIfDue(key: key)

        var immediateStart: (
            MessageArchiveManager.SyncChatStartResult,
            MessageManager?
        )?
        var didChangeReadiness = false
        var retiredCommittedCleanup: Cleanup?
        lock.lock()
        if let terminalFailure = terminalFailuresByKey[key] {
            lock.unlock()
            return .terminal(terminalFailure)
        }
        if var attempt = attemptsByKey[key] {
            let shouldRollCommittedFollowUp =
                attempt.phase == .committed &&
                attempt.committedPage != nil &&
                attempt.followUpTargetFingerprint?.target == targetFingerprint.target &&
                (
                    attempt.followUpPerformanceSemanticTargetFingerprint == nil ||
                    attempt.followUpPerformanceSemanticTargetFingerprint ==
                        performanceSemanticTargetFingerprint
                ) &&
                proposedQueryId != attempt.lease.queryId
            if shouldRollCommittedFollowUp {
                // The committed receipt describes the page the UI just
                // consumed. A matching pending target is the next archive
                // generation, not a reason to rejoin and replay that receipt.
                // Readiness observers remain conversation-scoped and will
                // follow the fresh queued lease installed below.
                retiredCommittedCleanup = makeCleanup(
                    key: key,
                    attempt: attempt,
                    includesTransportCancellation: false
                )
                attemptsByKey.removeValue(forKey: key)
                finalReceivedOrder.removeAll { $0 == key }
            } else {
                if attempt.lease.performanceTraceContext == nil,
                   let performanceTraceContext,
                   attempt.phase == .queued,
                   performanceTraceRegistry.register(
                    owner: key.owner,
                    queryID: attempt.lease.queryId,
                    context: performanceTraceContext,
                    operation: .initialOpen
                   ) != .rejected {
                    attempt.lease = Lease(
                        queryId: attempt.lease.queryId,
                        deadline: attempt.lease.deadline,
                        purpose: attempt.lease.purpose,
                        targetFingerprint: attempt.lease.targetFingerprint,
                        performanceTraceContext: performanceTraceContext,
                        performanceSemanticTargetFingerprint:
                            performanceSemanticTargetFingerprint,
                        performanceSkeletonReceiptWasCommitted:
                            performanceSkeletonReceiptWasCommitted
                    )
                } else if performanceTraceContext != nil,
                          attempt.lease.performanceTraceContext ==
                            performanceTraceContext,
                          performanceSkeletonReceiptWasCommitted,
                          !attempt.lease.performanceSkeletonReceiptWasCommitted {
                    attempt.lease = Lease(
                        queryId: attempt.lease.queryId,
                        deadline: attempt.lease.deadline,
                        purpose: attempt.lease.purpose,
                        targetFingerprint: attempt.lease.targetFingerprint,
                        performanceTraceContext:
                            attempt.lease.performanceTraceContext,
                        performanceSemanticTargetFingerprint:
                            attempt.lease.performanceSemanticTargetFingerprint,
                        performanceSkeletonReceiptWasCommitted: true
                    )
                }
                if purpose.persistencePriority > attempt.persistencePriority {
                    attempt.persistencePriority = purpose.persistencePriority
                }
                let previousFollowUpTarget = attempt.followUpTargetFingerprint
                let previousFollowUpPurpose = attempt.followUpTargetPurpose
                let previousFollowUpPerformanceSemanticTargetFingerprint =
                    attempt.followUpPerformanceSemanticTargetFingerprint
                let hasPerformanceSemanticTargetMismatch =
                    attempt.lease.performanceTraceContext != nil &&
                    (
                        performanceSemanticTargetFingerprint.map {
                            attempt.lease.performanceSemanticTargetFingerprint != $0
                        } ?? false
                    )
                if attempt.lease.targetFingerprint.target != targetFingerprint.target ||
                    hasPerformanceSemanticTargetMismatch {
                    if purpose == .interactiveBootstrap ||
                        attempt.followUpTargetPurpose != .interactiveBootstrap {
                        attempt.followUpTargetFingerprint = targetFingerprint
                        attempt.followUpTargetPurpose = purpose
                        attempt.followUpPerformanceSemanticTargetFingerprint =
                            performanceSemanticTargetFingerprint
                    }
                } else if purpose == .interactiveBootstrap {
                    attempt.followUpTargetFingerprint = nil
                    attempt.followUpTargetPurpose = nil
                    attempt.followUpPerformanceSemanticTargetFingerprint = nil
                }
                if purpose == .interactiveBootstrap,
                   attempt.phase == .committed,
                   attempt.committedPage != nil {
                    attempt.hasInteractiveCommittedJoinAwaitingObservation = true
                }
                if attempt.phase == .committed,
                   previousFollowUpTarget != attempt.followUpTargetFingerprint ||
                    previousFollowUpPurpose != attempt.followUpTargetPurpose ||
                    previousFollowUpPerformanceSemanticTargetFingerprint !=
                        attempt.followUpPerformanceSemanticTargetFingerprint {
                    let hasPendingTarget = attempt.followUpTargetFingerprint != nil
                    attempt.hasDurableCoverage =
                        attempt.committedPageProvidesDurableCoverage && !hasPendingTarget
                    attempt.confirmsEmptyConversation =
                        attempt.hasDurableCoverage &&
                        attempt.committedPage?.confirmsEmptyConversation == true
                    didChangeReadiness = true
                }
                if let startResult = attempt.startResult {
                    immediateStart = (startResult, attempt.messages)
                    attemptsByKey[key] = attempt
                } else {
                    attempt.observers.append(observer)
                    attemptsByKey[key] = attempt
                }
                let lease = attempt.lease
#if DEBUG || CHAT_PERFORMANCE_LAB
                var diagnostics = productionDiagnosticsByKey[key] ?? .zero
                diagnostics.leaseJoinCount &+= 1
                productionDiagnosticsByKey[key] = diagnostics
#endif
                lock.unlock()
                if didChangeReadiness {
                    notifyReadinessObservers(key: key)
                }
                if let immediateStart {
                    observer(lease.queryId, immediateStart.0, immediateStart.1)
                }
                return .joined(lease)
            }
        }

        let acceptedPerformanceTraceContext: ChatOpenPerformanceTraceContext?
        if let performanceTraceContext,
           performanceTraceRegistry.register(
            owner: key.owner,
            queryID: proposedQueryId,
            context: performanceTraceContext,
            operation: .initialOpen
           ) != .rejected {
            acceptedPerformanceTraceContext = performanceTraceContext
        } else {
            acceptedPerformanceTraceContext = nil
        }
        let lease = Lease(
            queryId: proposedQueryId,
            deadline: now().addingTimeInterval(max(0, timeout)),
            purpose: purpose,
            targetFingerprint: targetFingerprint,
            performanceTraceContext: acceptedPerformanceTraceContext,
            performanceSemanticTargetFingerprint:
                acceptedPerformanceTraceContext == nil
                    ? nil
                    : performanceSemanticTargetFingerprint,
            performanceSkeletonReceiptWasCommitted:
                acceptedPerformanceTraceContext != nil &&
                performanceSkeletonReceiptWasCommitted
        )
        let operationTrace = reserveOperationTraceLocked(for: key)
        let attempt = Attempt(
            lease: lease,
            enqueuedAt: now(),
            operationTraceID: operationTrace.traceID,
            predecessorOperationTraceID: operationTrace.predecessorTraceID,
            persistenceTimeout: max(0, persistenceTimeout ?? timeout),
            phase: .queued,
            persistencePriority: purpose.persistencePriority,
            observers: [observer],
            startResult: nil,
            messages: nil,
            archiveManager: nil,
            cancelTransport: nil,
            timeoutWorkItem: nil,
            endDispatcherToken: nil,
            failureDispatcherToken: nil,
            failurePreparationToken: nil,
            endPageEvent: nil,
            committedPage: nil,
            committedPageProvidesDurableCoverage: false,
            hasDurableCoverage: false,
            confirmsEmptyConversation: false,
            schedulerCompletion: nil,
            hasWireTerminal: false,
            didRegisterPersistenceSource: false,
            isPersistenceCommitClaimed: false,
            followUpTargetFingerprint: nil,
            followUpTargetPurpose: nil,
            followUpPerformanceSemanticTargetFingerprint: nil,
            isCommittedRemovalDeferredUntilObserversDetach: false,
            hasInteractiveCommittedJoinAwaitingObservation: false
        )
        attemptsByKey[key] = attempt
#if DEBUG || CHAT_PERFORMANCE_LAB
        var diagnostics = productionDiagnosticsByKey[key] ?? .zero
        diagnostics.leaseStartCount &+= 1
        productionDiagnosticsByKey[key] = diagnostics
#endif
        lock.unlock()

        performCleanup(
            retiredCommittedCleanup,
            unregisterPersistenceSource: true
        )
        installLifetimeHandlers(key: key, lease: lease)
        notifyReadinessObservers(key: key)
        traceArchiveLoad(
            "archiveLoadEnqueue",
            attempt: attempt,
            phase: .queued,
            waitMilliseconds: 0,
            additionalFields: [
                ("followUpRollover", retiredCommittedCleanup != nil)
            ]
        )
        return .start(lease)
    }

    /// Account-scoped lease entry point. `acquire` is retained as a source-
    /// compatible spelling for existing callers and tests.
    func acquireOrJoin(
        key: ChatInitialBootstrapRequestKey,
        proposedQueryId: String,
        timeout: TimeInterval,
        purpose: ConversationArchiveLoadPurpose = .interactiveBootstrap,
        persistenceTimeout: TimeInterval? = nil,
        targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint = .init(
            target: .latest,
            boundary: nil
        ),
        performanceTraceContext: ChatOpenPerformanceTraceContext? = nil,
        performanceSemanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint? = nil,
        performanceSkeletonReceiptWasCommitted: Bool = false,
        observer: @escaping StartObserver
    ) -> Acquisition {
        acquire(
            key: key,
            proposedQueryId: proposedQueryId,
            timeout: timeout,
            purpose: purpose,
            persistenceTimeout: persistenceTimeout,
            targetFingerprint: targetFingerprint,
            performanceTraceContext: performanceTraceContext,
            performanceSemanticTargetFingerprint:
                performanceSemanticTargetFingerprint,
            performanceSkeletonReceiptWasCommitted:
                performanceSkeletonReceiptWasCommitted,
            observer: observer
        )
    }

    func pendingFollowUpTarget(
        for key: ChatInitialBootstrapRequestKey
    ) -> MessageArchiveManager.ChatBootstrapTargetFingerprint? {
        lock.lock()
        let target = attemptsByKey[key]?.followUpTargetFingerprint
        lock.unlock()
        return target
    }

    /// Lets a reopened controller adopt the already-emitted opaque trace for
    /// the same conversation and semantic target. Terminal receipts are not
    /// adoptable and a target mismatch must start a fresh UI generation.
    func activePerformanceTraceContext(
        for key: ChatInitialBootstrapRequestKey,
        targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint,
        semanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint
    ) -> ChatOpenPerformanceTraceContext? {
        activePerformanceTraceAdoption(
            for: key,
            targetFingerprint: targetFingerprint,
            semanticTargetFingerprint: semanticTargetFingerprint
        )?.context
    }

    func activePerformanceTraceAdoption(
        for key: ChatInitialBootstrapRequestKey,
        targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint,
        semanticTargetFingerprint:
            ChatOpenPerformanceSemanticTargetFingerprint
    ) -> PerformanceTraceAdoption? {
        lock.lock()
        defer { lock.unlock() }
        guard let attempt = attemptsByKey[key],
              attempt.lease.targetFingerprint.target == targetFingerprint.target,
              attempt.lease.performanceSemanticTargetFingerprint ==
                semanticTargetFingerprint,
              attempt.phase == .queued ||
                attempt.phase == .transport ||
                attempt.phase == .persistence else {
            return nil
        }
        guard let context = attempt.lease.performanceTraceContext else {
            return nil
        }
        return PerformanceTraceAdoption(
            context: context,
            hasSkeletonReceipt:
                attempt.lease.performanceSkeletonReceiptWasCommitted
        )
    }

    func pendingFollowUpRequest(
        for key: ChatInitialBootstrapRequestKey
    ) -> PendingFollowUpTarget? {
        lock.lock()
        let request: PendingFollowUpTarget?
        if let attempt = attemptsByKey[key],
           let fingerprint = attempt.followUpTargetFingerprint,
           let purpose = attempt.followUpTargetPurpose {
            request = PendingFollowUpTarget(
                fingerprint: fingerprint,
                purpose: purpose,
                performanceSemanticTargetFingerprint:
                    attempt.followUpPerformanceSemanticTargetFingerprint
            )
        } else {
            request = nil
        }
        lock.unlock()
        return request
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    func productionDiagnosticsSnapshot(
        for key: ChatInitialBootstrapRequestKey
    ) -> ProductionDiagnosticsSnapshot {
        lock.lock()
        var diagnostics = productionDiagnosticsByKey[key] ?? .zero
        if let attempt = attemptsByKey[key], attempt.phase != .committed {
            diagnostics.activeLeaseCount = 1
        } else {
            diagnostics.activeLeaseCount = 0
        }
        lock.unlock()
        return diagnostics
    }
#endif

    func readiness(for key: ChatInitialBootstrapRequestKey) -> ConversationArchiveReadiness? {
        lock.lock()
        let value = readinessLocked(for: key)
        lock.unlock()
        return value
    }

    @discardableResult
    func observe(
        key: ChatInitialBootstrapRequestKey,
        consumesInteractiveCommittedJoin: Bool = false,
        observer: @escaping ReadinessObserver
    ) -> ObservationToken {
        let token = ObservationToken()
        lock.lock()
        if consumesInteractiveCommittedJoin,
           var attempt = attemptsByKey[key],
           attempt.phase == .committed,
           attempt.committedPage != nil {
            attempt.hasInteractiveCommittedJoinAwaitingObservation = false
            attemptsByKey[key] = attempt
        }
        readinessObserversByKey[key, default: [:]][token.id] = observer
        let value = readinessLocked(for: key)
        lock.unlock()
        observer(value)
        return token
    }

    /// Observation consumes a committed-join reservation under the coordinator
    /// lock. The production controller calls this synchronously from a `defer`
    /// at request-scope exit so every early return also clears an abandoned
    /// reservation. This is lifecycle cleanup, never a readiness or
    /// presentation terminal.
    @discardableResult
    func releaseInteractiveCommittedJoinReservation(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> Bool {
        var cleanup: Cleanup?
        var didRelease = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.phase == .committed,
           attempt.hasInteractiveCommittedJoinAwaitingObservation {
            didRelease = true
            attempt.hasInteractiveCommittedJoinAwaitingObservation = false
            if attempt.isCommittedRemovalDeferredUntilObserversDetach,
               readinessObserversByKey[key]?.isEmpty ?? true {
                attemptsByKey.removeValue(forKey: key)
                finalReceivedOrder.removeAll { $0 == key }
                cleanup = makeCleanup(
                    key: key,
                    attempt: attempt,
                    includesTransportCancellation: false
                )
            } else {
                attemptsByKey[key] = attempt
            }
        }
        lock.unlock()
        performCleanup(cleanup, unregisterPersistenceSource: true)
        return didRelease
    }

    /// Joining an existing interactive request is itself the promotion: the
    /// account scheduler upgrades a queued task with the same deduplication
    /// key. This method provides the explicit lease API used by callers that
    /// already hold the transaction key.
    @discardableResult
    func promote(key: ChatInitialBootstrapRequestKey) -> Bool {
        lock.lock()
        var attempt = attemptsByKey[key]
        if attempt != nil {
            attempt?.persistencePriority = .interactive
            attemptsByKey[key] = attempt
        }
        let queryId = attempt?.lease.queryId
        let messages = attempt?.messages
        lock.unlock()
        if let queryId {
            AccountManager.shared.find(for: key.owner)?.xmppTaskScheduler.promotePendingTask(
                deduplicationKey: key.schedulerDeduplicationKey(queryId: queryId),
                to: .interactive
            )
            let didPromoteRegisteredSource =
                ChatRemoteHistoryCompletionCoordinator.promotePersistenceSource(
                    owner: key.owner,
                    queryId: queryId
                )
            if !didPromoteRegisteredSource {
                messages?.promoteArchiveQueryBatch(queryId: queryId)
            }
        }
        return queryId != nil
    }

    /// Controller teardown detaches presentation only. The account-scoped
    /// transport/persistence transaction intentionally remains alive.
    func detach(
        key: ChatInitialBootstrapRequestKey,
        observation token: ObservationToken
    ) {
        var cleanup: Cleanup?
        var shouldUnregisterPersistenceSource = false
        lock.lock()
        readinessObserversByKey[key]?[token.id] = nil
        if readinessObserversByKey[key]?.isEmpty == true {
            readinessObserversByKey[key] = nil
            if let attempt = attemptsByKey[key],
               attempt.phase == .committed,
               attempt.isCommittedRemovalDeferredUntilObserversDetach,
               !attempt.hasInteractiveCommittedJoinAwaitingObservation {
                attemptsByKey.removeValue(forKey: key)
                finalReceivedOrder.removeAll { $0 == key }
                shouldUnregisterPersistenceSource =
                    attempt.didRegisterPersistenceSource
                cleanup = makeCleanup(
                    key: key,
                    attempt: attempt,
                    includesTransportCancellation: false
                )
            }
        }
        lock.unlock()
        performCleanup(
            cleanup,
            unregisterPersistenceSource: shouldUnregisterPersistenceSource
        )
    }

    func remainingTimeout(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> TimeInterval {
        lock.lock()
        let deadline = attemptsByKey[key]?.lease.queryId == queryId
            ? attemptsByKey[key]?.lease.deadline
            : nil
        lock.unlock()
        return max(0, deadline?.timeIntervalSince(now()) ?? 0)
    }

    func isActive(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> Bool {
        lock.lock()
        let isActive = attemptsByKey[key]?.lease.queryId == queryId
        lock.unlock()
        return isActive
    }

    func cachedEndPageEvent(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> MessageArchiveEndPageEvent? {
        lock.lock()
        let event = attemptsByKey[key]?.lease.queryId == queryId
            ? attemptsByKey[key]?.endPageEvent
            : nil
        lock.unlock()
        return event
    }

    func cachedCommittedPage(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> CommittedPage? {
        lock.lock()
        let page = attemptsByKey[key]?.lease.queryId == queryId
            ? attemptsByKey[key]?.committedPage
            : nil
        lock.unlock()
        return page
    }

    func committedLease(for key: ChatInitialBootstrapRequestKey) -> Lease? {
        lock.lock()
        let lease = attemptsByKey[key]?.phase == .committed
            ? attemptsByKey[key]?.lease
            : nil
        lock.unlock()
        return lease
    }

    func attachSchedulerCompletion(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        completion: @escaping () -> Void
    ) {
        var shouldFinishImmediately = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           !attempt.hasWireTerminal {
            attempt.schedulerCompletion = completion
            attemptsByKey[key] = attempt
        } else {
            shouldFinishImmediately = true
        }
        lock.unlock()
        if shouldFinishImmediately {
            completion()
        }
    }

    func resolveStart(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        result: MessageArchiveManager.SyncChatStartResult,
        messages: MessageManager?,
        archiveManager: MessageArchiveManager? = nil,
        cancelTransport: @escaping () -> Void
    ) {
        var observers: [StartObserver] = []
        var shouldCancelLateTransport = false
        var shouldRegisterPersistenceSource = false
        var shouldCompleteWithoutBootstrapTransport = false
        var persistencePriority = ArchivePersistencePriority.interactive
        var traceAttempt: Attempt?
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId {
            persistencePriority = attempt.persistencePriority
            // A very fast raw terminal may be delivered synchronously while
            // the request-start call is still unwinding. Never regress that
            // persistence lease back to transport.
            let acceptsStartResources = attempt.phase == .queued || attempt.phase == .transport
            if acceptsStartResources {
#if DEBUG || CHAT_PERFORMANCE_LAB
                if attempt.startResult == nil,
                   case .bootstrapStarted = result {
                    var diagnostics = productionDiagnosticsByKey[key] ?? .zero
                    diagnostics.transportStartCount &+= 1
                    productionDiagnosticsByKey[key] = diagnostics
                }
#endif
                attempt.phase = .transport
                attempt.messages = messages
                attempt.archiveManager = archiveManager ?? attempt.archiveManager
                attempt.cancelTransport = cancelTransport
                if case .bootstrapStarted = result,
                   messages != nil,
                   !attempt.didRegisterPersistenceSource {
                    attempt.didRegisterPersistenceSource = true
                    shouldRegisterPersistenceSource = true
                }
                if case .gapRepairOnly = result {
                    shouldCompleteWithoutBootstrapTransport = true
                } else if case .noop = result {
                    shouldCompleteWithoutBootstrapTransport = true
                }
            }
            attempt.startResult = result
            observers = attempt.observers
            attempt.observers.removeAll()
            attemptsByKey[key] = attempt
            traceAttempt = attempt
        } else {
            let identity = AttemptIdentity(key: key, queryId: queryId)
            if !cancelledTransportIdentities.contains(identity) {
                recordCancelledTransportIdentityLocked(identity)
                shouldCancelLateTransport = true
            }
        }
        lock.unlock()

        notifyReadinessObservers(key: key)

        if let traceAttempt {
            if case .bootstrapStarted = result,
               let traceContext = traceAttempt.lease.performanceTraceContext {
                _ = performanceTraceRegistry.transportStarted(
                    owner: key.owner,
                    queryID: queryId,
                    context: traceContext
                )
            }
            traceArchiveLoad(
                "archiveLoadStart",
                attempt: traceAttempt,
                phase: .transport,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [("started", true)]
            )
        }

        if shouldCancelLateTransport {
            cancelTransport()
            return
        }
        if shouldRegisterPersistenceSource,
           let messages {
            ChatRemoteHistoryCompletionCoordinator.registerPersistenceSource(
                messages,
                owner: key.owner,
                queryId: queryId,
                priority: persistencePriority
            )
            if !isActive(key: key, queryId: queryId) {
                ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
                    owner: key.owner,
                    queryId: queryId
                )
            }
        }
        observers.forEach { $0(queryId, result, messages) }
        switch result {
        case .bootstrapStarted:
            break
        case .gapRepairOnly, .noop:
            if shouldCompleteWithoutBootstrapTransport {
                _ = complete(
                    key: key,
                    queryId: queryId,
                    unregisterPersistenceSource: true
                )
            }
        }
    }

    func preparePersistenceSource(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        messages: MessageManager?,
        archiveManager: MessageArchiveManager? = nil
    ) {
        guard messages != nil || archiveManager != nil else {
            return
        }
        var shouldRegister = false
        var persistencePriority = ArchivePersistencePriority.background
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId {
            persistencePriority = attempt.persistencePriority
            attempt.messages = messages ?? attempt.messages
            attempt.archiveManager = archiveManager ?? attempt.archiveManager
            if messages != nil,
               !attempt.didRegisterPersistenceSource {
                attempt.didRegisterPersistenceSource = true
                shouldRegister = true
            }
            attemptsByKey[key] = attempt
        }
        lock.unlock()
        guard shouldRegister,
              let messages else {
            return
        }
        ChatRemoteHistoryCompletionCoordinator.registerPersistenceSource(
            messages,
            owner: key.owner,
            queryId: queryId,
            priority: persistencePriority
        )
        if !isActive(key: key, queryId: queryId) {
            ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
                owner: key.owner,
                queryId: queryId
            )
        }
    }

    @discardableResult
    func complete(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        unregisterPersistenceSource: Bool = false
    ) -> Bool {
        var cleanup: Cleanup?
        var didMatch = false
        var didRemove = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId {
            didMatch = true
            cleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
            let hasJoinedReadinessConsumers =
                readinessObserversByKey[key]?.isEmpty == false ||
                attempt.hasInteractiveCommittedJoinAwaitingObservation
            if attempt.phase == .committed,
               attempt.committedPage != nil,
               hasJoinedReadinessConsumers {
                attempt.isCommittedRemovalDeferredUntilObserversDetach = true
                attemptsByKey[key] = attempt
            } else {
                attemptsByKey.removeValue(forKey: key)
                finalReceivedOrder.removeAll { $0 == key }
#if DEBUG || CHAT_PERFORMANCE_LAB
                if attempt.phase != .committed {
                    var diagnostics = productionDiagnosticsByKey[key] ?? .zero
                    diagnostics.completedLeaseCount &+= 1
                    productionDiagnosticsByKey[key] = diagnostics
                }
#endif
                recordCancelledTransportIdentityLocked(
                    AttemptIdentity(key: key, queryId: queryId)
                )
                didRemove = true
            }
        }
        lock.unlock()
        if didRemove {
            notifyReadinessObservers(key: key)
        }
        performCleanup(
            cleanup,
            unregisterPersistenceSource: unregisterPersistenceSource
        )
        return didMatch
    }

    /// Releases the transport/persistence owners after a durable commit while
    /// retaining a bounded, lightweight receipt for a chat that opens later.
    /// Both the snapshot pump and a consuming controller may acknowledge the
    /// same receipt, so this operation is deliberately idempotent.
    @discardableResult
    func acknowledgeCommittedReceipt(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> Bool {
        var cleanup: Cleanup?
        var shouldUnregisterPersistenceSource = false
        var didMatch = false
        var didRemoveNonDurableReceipt = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.phase == .committed,
           attempt.committedPage != nil {
            didMatch = true
            shouldUnregisterPersistenceSource = attempt.didRegisterPersistenceSource
            cleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
            if attempt.hasDurableCoverage {
                attempt.messages = nil
                attempt.archiveManager = nil
                attempt.cancelTransport = nil
                attempt.timeoutWorkItem = nil
                attempt.endDispatcherToken = nil
                attempt.failureDispatcherToken = nil
                attempt.failurePreparationToken = nil
                attempt.schedulerCompletion = nil
                attempt.didRegisterPersistenceSource = false
                attempt.observers.removeAll(keepingCapacity: false)
                attemptsByKey[key] = attempt
            } else {
                // A terminal page that did not cover the current snapshot is
                // not a reusable receipt. A joined observer must nevertheless
                // consume its page/follow-up proof before the receipt goes
                // away; otherwise a snapshot observer can strand the chat on
                // skeleton between two main-queue hops.
                if readinessObserversByKey[key]?.isEmpty == false ||
                    attempt.hasInteractiveCommittedJoinAwaitingObservation {
                    attempt.isCommittedRemovalDeferredUntilObserversDetach = true
                    attemptsByKey[key] = attempt
                } else {
                    attemptsByKey.removeValue(forKey: key)
                    finalReceivedOrder.removeAll { $0 == key }
                    didRemoveNonDurableReceipt = true
                }
            }
        }
        lock.unlock()

        if didRemoveNonDurableReceipt {
            notifyReadinessObservers(key: key)
        }
        performCleanup(
            cleanup,
            unregisterPersistenceSource: shouldUnregisterPersistenceSource
        )
        return didMatch
    }

    /// A new synchronization boundary may replace only a previously committed
    /// receipt. Active queued/transport/persistence work always keeps ownership.
    @discardableResult
    func invalidateCommittedReceipt(
        key: ChatInitialBootstrapRequestKey,
        queryId: String? = nil
    ) -> Bool {
        var cleanup: Cleanup?
        var didMatch = false
        var didRemove = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.phase == .committed,
           attempt.committedPage != nil,
           queryId == nil || attempt.lease.queryId == queryId {
            didMatch = true
            cleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
            if readinessObserversByKey[key]?.isEmpty == false ||
                attempt.hasInteractiveCommittedJoinAwaitingObservation {
                attempt.isCommittedRemovalDeferredUntilObserversDetach = true
                attemptsByKey[key] = attempt
            } else {
                attemptsByKey.removeValue(forKey: key)
                finalReceivedOrder.removeAll { $0 == key }
                didRemove = true
            }
        }
        lock.unlock()

        guard didMatch else {
            return false
        }
        if didRemove {
            notifyReadinessObservers(key: key)
        }
        performCleanup(cleanup, unregisterPersistenceSource: true)
        return true
    }

    @discardableResult
    func recordFailure(
        key: ChatInitialBootstrapRequestKey,
        event: MessageArchiveRequestFailureEvent,
        publishEvent: Bool
    ) -> Bool {
        let cleanup: Cleanup?
        var traceAttempt: Attempt?
        lock.lock()
        if let activeAttempt = attemptsByKey[key],
           activeAttempt.lease.queryId == event.queryId,
           activeAttempt.endPageEvent != nil,
           activeAttempt.committedPage == nil {
            // A transport timeout/error cannot invalidate a raw final already
            // accepted by the account-scoped persistence transaction.
            cleanup = nil
        } else if let attempt = attemptsByKey[key],
           attempt.lease.queryId == event.queryId,
           attempt.committedPage == nil {
            traceAttempt = attempt
            // The end-page dispatcher claims synchronous delivery under its
            // own lock before invoking us. If timeout races through this
            // interval, the already accepted final page owns the terminal
            // outcome and the timeout must stand down.
            if attempt.endPageEvent == nil,
               MessageArchiveEndPageDispatcher.hasAcceptedSynchronousDelivery(
                owner: event.owner,
                queryId: event.queryId
            ) {
                lock.unlock()
                return false
            }
            attemptsByKey.removeValue(forKey: key)
            finalReceivedOrder.removeAll { $0 == key }
            terminalFailuresByKey[key] = event
            recordTerminalKeyLocked(key)
#if DEBUG || CHAT_PERFORMANCE_LAB
            var diagnostics = productionDiagnosticsByKey[key] ?? .zero
            diagnostics.failedLeaseCount &+= 1
            productionDiagnosticsByKey[key] = diagnostics
#endif
            if attempt.cancelTransport != nil {
                recordCancelledTransportIdentityLocked(
                    AttemptIdentity(key: key, queryId: event.queryId)
                )
            }
            cleanup = makeCleanup(key: key, attempt: attempt, includesTransportCancellation: true)
        } else {
            cleanup = nil
        }
        lock.unlock()
        notifyReadinessObservers(key: key)

        guard let cleanup else {
            return false
        }
        if let traceAttempt {
            if let traceContext = traceAttempt.lease.performanceTraceContext {
                _ = performanceTraceRegistry.terminate(
                    owner: key.owner,
                    queryID: event.queryId,
                    context: traceContext,
                    terminal: .failed
                )
            }
            traceArchiveLoad(
                "archiveLoadFail",
                attempt: traceAttempt,
                phase: .failed,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [
                    ("pendingQueryCount", event.pendingQueryCount),
                    ("hadWireTerminal", cleanup.endDispatcherToken == nil)
                ]
            )
        }
        if publishEvent {
            // Retry presentation is independent from a potentially blocked
            // partial-page cleanup.
            _ = MessageArchiveRequestFailureDispatcher.publish(event)
        }
        performCleanup(cleanup, unregisterPersistenceSource: true)
        return true
    }

    func clearTerminal(key: ChatInitialBootstrapRequestKey) {
        lock.lock()
        terminalFailuresByKey.removeValue(forKey: key)
        terminalFailureOrder.removeAll { $0 == key }
        lock.unlock()
        notifyReadinessObservers(key: key)
    }

    /// Drops a transport lease after Realm has already confirmed that the
    /// initial archive requirement is satisfied. A cached final page is not a
    /// cancellation; a still-running duplicate request is.
    func discardConfirmedAttempt(key: ChatInitialBootstrapRequestKey) {
        let cleanup: Cleanup?
        lock.lock()
        if let currentAttempt = attemptsByKey[key],
           currentAttempt.endPageEvent != nil,
           currentAttempt.committedPage == nil {
            // Realm flags written by older builds are not durable proof while
            // this transaction is between raw <fin> and persistence commit.
            cleanup = nil
        } else if let attempt = attemptsByKey.removeValue(forKey: key) {
            finalReceivedOrder.removeAll { $0 == key }
            let shouldCancelTransport = attempt.endPageEvent == nil
#if DEBUG || CHAT_PERFORMANCE_LAB
            if attempt.phase != .committed {
                var diagnostics = productionDiagnosticsByKey[key] ?? .zero
                diagnostics.cancelledLeaseCount &+= 1
                productionDiagnosticsByKey[key] = diagnostics
            }
#endif
            if shouldCancelTransport,
               attempt.cancelTransport != nil {
                recordCancelledTransportIdentityLocked(
                    AttemptIdentity(key: key, queryId: attempt.lease.queryId)
                )
            }
            cleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: shouldCancelTransport
            )
        } else {
            cleanup = nil
        }
        lock.unlock()
        notifyReadinessObservers(key: key)
        performCleanup(cleanup, unregisterPersistenceSource: true)
    }

    func expireDueAttemptsForTesting() {
        expireDueAttempts()
    }

    func expirePersistenceAttemptForTesting(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) {
        recordPersistenceFailure(
            key: key,
            queryId: queryId,
            description: "Archive persistence timed out",
            reason: .timeout
        )
    }

    func recordCommittedPageForTesting(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        hasDurableCoverage: Bool,
        boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint? = nil,
        resultCount: Int = 0,
        persistedRowsForQuery: Int = 0,
        visibleRowsForConversation: Int = 0,
        confirmsEmptyConversation: Bool? = nil,
        hasPresentationMaterialization: Bool? = nil,
        recommendedFollowUpTarget:
            MessageArchiveManager.ChatBootstrapPageTarget? = nil
    ) {
        let normalizedResultCount = max(0, resultCount)
        let normalizedPersistedRows = max(0, persistedRowsForQuery)
        let normalizedVisibleRows = max(0, visibleRowsForConversation)
        var persistenceSummary = MessageManager.ArchivePersistenceSummary()
        persistenceSummary.received = normalizedResultCount
        persistenceSummary.queued = normalizedPersistedRows
        persistenceSummary.savedNew = normalizedPersistedRows
        let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: key.conversationTypeRawValue
        ) ?? .regular
        for _ in 0..<normalizedVisibleRows {
            persistenceSummary.recordVisibleRow(
                owner: key.owner,
                jid: key.jid,
                conversationType: conversationType
            )
        }
        let state = MessageArchivePageEndState(
            queryExhausted: true,
            archiveEnded: true,
            persistedMessageCount: normalizedResultCount
        )
        let event = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: queryId,
            state: state,
            first: normalizedResultCount > 0 ? "archive-1" : "",
            last: normalizedResultCount > 0 ? "archive-\(normalizedResultCount)" : "",
            count: normalizedResultCount,
            streamKind: .primary,
            source: .localCallback
        )
        recordCommittedPage(
            key: key,
            queryId: queryId,
            page: CommittedPage(
                event: event,
                completion: ChatRemoteHistoryCompletionResult(
                    state: state,
                    flushedMessageCount: normalizedPersistedRows,
                    persistenceSummary: persistenceSummary
                ),
                boundaryFingerprint: boundaryFingerprint,
                confirmsEmptyConversation:
                    confirmsEmptyConversation ??
                    (normalizedResultCount == 0),
                hasPresentationMaterialization:
                    hasPresentationMaterialization ??
                    (normalizedResultCount > 0),
                recommendedFollowUpTarget: recommendedFollowUpTarget
            ),
            hasDurableCoverage: hasDurableCoverage
        )
    }

    func hasRetainedResourcesForTesting(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let attempt = attemptsByKey[key],
              attempt.lease.queryId == queryId else {
            return false
        }
        return attempt.messages != nil ||
            attempt.archiveManager != nil ||
            attempt.cancelTransport != nil ||
            attempt.timeoutWorkItem != nil ||
            attempt.endDispatcherToken != nil ||
            attempt.failureDispatcherToken != nil ||
            attempt.failurePreparationToken != nil ||
            attempt.schedulerCompletion != nil ||
            attempt.didRegisterPersistenceSource
    }

    func resetForTests() {
        let cleanups: [Cleanup]
        lock.lock()
        cleanups = attemptsByKey.map { key, attempt in
            makeCleanup(key: key, attempt: attempt, includesTransportCancellation: true)
        }
        attemptsByKey.removeAll()
        terminalFailuresByKey.removeAll()
        terminalFailureOrder.removeAll()
        finalReceivedOrder.removeAll()
        cancelledTransportIdentities.removeAll()
        cancelledTransportIdentityOrder.removeAll()
        readinessObserversByKey.removeAll()
        latestOperationTraceIDByKey.removeAll()
        operationTraceKeyOrder.removeAll()
        nextOperationTraceID = 0
        persistenceCommitClaimObserver = nil
#if DEBUG || CHAT_PERFORMANCE_LAB
        productionDiagnosticsByKey.removeAll()
#endif
        lock.unlock()
        cleanups.forEach {
            performCleanup($0, unregisterPersistenceSource: true)
        }
    }

    /// Account deletion ends the scope that makes a retained receipt valid.
    /// Purge both lightweight receipts and active work so re-adding the same
    /// JID cannot join archive proof from the previous account session.
    func purge(owner: String) {
        guard owner.isNotEmpty else { return }
        let cleanups: [Cleanup]
        let readinessObservers: [ReadinessObserver]
        lock.lock()
        let attemptKeys = attemptsByKey.keys.filter { $0.owner == owner }
        cleanups = attemptKeys.compactMap { key in
            attemptsByKey.removeValue(forKey: key).map {
                makeCleanup(key: key, attempt: $0, includesTransportCancellation: true)
            }
        }
        let terminalKeys = terminalFailuresByKey.keys.filter { $0.owner == owner }
        terminalKeys.forEach { terminalFailuresByKey.removeValue(forKey: $0) }
        terminalFailureOrder.removeAll { $0.owner == owner }
        finalReceivedOrder.removeAll { $0.owner == owner }
        readinessObservers = readinessObserversByKey
            .filter { $0.key.owner == owner }
            .flatMap { $0.value.values }
        readinessObserversByKey = readinessObserversByKey.filter { $0.key.owner != owner }
        cancelledTransportIdentities = cancelledTransportIdentities.filter {
            $0.key.owner != owner
        }
        cancelledTransportIdentityOrder.removeAll { $0.key.owner == owner }
        let traceKeys = latestOperationTraceIDByKey.keys.filter { $0.owner == owner }
        traceKeys.forEach { latestOperationTraceIDByKey.removeValue(forKey: $0) }
        operationTraceKeyOrder.removeAll { $0.owner == owner }
#if DEBUG || CHAT_PERFORMANCE_LAB
        productionDiagnosticsByKey = productionDiagnosticsByKey.filter {
            $0.key.owner != owner
        }
#endif
        lock.unlock()

        readinessObservers.forEach { $0(nil) }
        cleanups.forEach {
            performCleanup($0, unregisterPersistenceSource: true)
        }
    }

    private func installLifetimeHandlers(
        key: ChatInitialBootstrapRequestKey,
        lease: Lease
    ) {
        let endToken = MessageArchiveEndPageDispatcher.register(
            owner: key.owner,
            queryId: lease.queryId,
            delivery: .synchronous
        ) { [weak self] event in
            self?.recordEndPage(key: key, event: event)
        }
        let failureToken = MessageArchiveRequestFailureDispatcher.register(
            owner: key.owner,
            queryId: lease.queryId,
            delivery: .synchronous
        ) { [weak self] event in
            _ = self?.recordFailure(key: key, event: event, publishEvent: true)
        }
        let failurePreparationToken = MessageArchiveRequestFailurePreparationDispatcher.register(
            owner: key.owner,
            queryId: lease.queryId
        ) { [weak self] event, terminal in
            self?.recordWireFailure(key: key, event: event)
            terminal()
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.expireAttemptIfDue(key: key, expectedQueryId: lease.queryId)
        }

        var didInstall = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease == lease {
            attempt.endDispatcherToken = endToken
            attempt.failureDispatcherToken = failureToken
            attempt.failurePreparationToken = failurePreparationToken
            attempt.timeoutWorkItem = timeoutWorkItem
            attemptsByKey[key] = attempt
            didInstall = true
        }
        lock.unlock()

        guard didInstall else {
            MessageArchiveEndPageDispatcher.unregister(endToken)
            MessageArchiveRequestFailureDispatcher.unregister(failureToken)
            MessageArchiveRequestFailurePreparationDispatcher.unregister(failurePreparationToken)
            timeoutWorkItem.cancel()
            return
        }
        if automaticallySchedulesTimeouts {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, lease.deadline.timeIntervalSince(now())),
                execute: timeoutWorkItem
            )
        }
    }

    private func legacyPresentationProof(
        key: ChatInitialBootstrapRequestKey,
        event: MessageArchiveEndPageEvent,
        completion: ChatRemoteHistoryCompletionResult,
        hasPersistenceSource: Bool
    ) -> ChatLegacyArchivePresentationProof {
        guard let conversationType =
                ClientSynchronizationManager.ConversationType(
                    rawValue: key.conversationTypeRawValue
                ) else {
            return ChatLegacyArchivePresentationProof(
                hasPresentationMaterialization: false,
                confirmsEmptyConversation: false
            )
        }
        return ChatLegacyArchivePresentationProofPolicy.resolve(
            event: event,
            persistenceSummary: completion.persistenceSummary,
            owner: key.owner,
            jid: key.jid,
            conversationType: conversationType,
            hasPersistenceSource: hasPersistenceSource
        )
    }

    private func recordEndPage(
        key: ChatInitialBootstrapRequestKey,
        event: MessageArchiveEndPageEvent
    ) {
        var messages: MessageManager?
        var archiveManager: MessageArchiveManager?
        var timeoutWorkItem: DispatchWorkItem?
        var failureToken: MessageArchiveRequestFailureDispatcher.Token?
        var failurePreparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token?
        var schedulerCompletion: (() -> Void)?
        var didRecord = false
        var traceAttempt: Attempt?
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == event.queryId,
           attempt.endPageEvent == nil {
            attempt.endPageEvent = event
            attempt.phase = .persistence
            messages = attempt.messages
            archiveManager = attempt.archiveManager
            timeoutWorkItem = attempt.timeoutWorkItem
            failureToken = attempt.failureDispatcherToken
            failurePreparationToken = attempt.failurePreparationToken
            schedulerCompletion = attempt.schedulerCompletion
            attempt.timeoutWorkItem = nil
            attempt.failureDispatcherToken = nil
            attempt.failurePreparationToken = nil
            attempt.schedulerCompletion = nil
            attempt.hasWireTerminal = true
            attempt.endDispatcherToken = nil
            attemptsByKey[key] = attempt
            didRecord = true
            traceAttempt = attempt
        }
        lock.unlock()
        // The wire lane must become available before any UI/readiness
        // observer can block or hop to the main queue.
        schedulerCompletion?()
        notifyReadinessObservers(key: key)
        timeoutWorkItem?.cancel()
        if let failureToken {
            MessageArchiveRequestFailureDispatcher.unregister(failureToken)
        }
        if let failurePreparationToken {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(failurePreparationToken)
        }
        // `.mamArchive` represents the wire, not Realm. Let the next
        // interactive transport start while this query-scoped flush persists.
        if let traceAttempt {
            traceArchiveLoad(
                "archiveLoadWireFin",
                attempt: traceAttempt,
                phase: .persistence,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [
                    ("resultCount", event.count),
                    ("hasPersistenceSource", messages != nil)
                ]
            )
        }
        guard didRecord else {
            return
        }
        installPersistenceTimeout(key: key, queryId: event.queryId)

        // `publish` removes the first handler set before dispatching it to
        // main. A controller attached in that interval lives in a new set;
        // replay once so that it cannot miss the raw final page.
        _ = MessageArchiveEndPageDispatcher.publish(event)

        guard messages != nil else {
            guard claimPersistenceCommit(key: key, queryId: event.queryId) else {
                return
            }
            let completion = ChatRemoteHistoryCompletionResult(
                state: event.state,
                flushedMessageCount: 0,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            )
            let performanceTraceContext =
                traceAttempt?.lease.performanceTraceContext
            if let performanceTraceContext {
                // The empty-page path has no MessageManager request to seal.
                // Seal only the already observed real MAM final; the registry
                // rejects synthetic/test completions that never crossed that
                // transport boundary.
                _ = performanceTraceRegistry.sealExpectedIngress(
                    owner: key.owner,
                    queryID: event.queryId,
                    context: performanceTraceContext,
                    expectedCount: event.count
                )
            }
            let completePerformanceTrace: (
                ChatPerformanceIntervalTerminal,
                Int,
                Int
            ) -> Void = { terminal, persistedCount, failedCount in
                guard let performanceTraceContext else {
                    return
                }
                _ = self.performanceTraceRegistry.persistenceTerminal(
                    owner: key.owner,
                    queryID: event.queryId,
                    context: performanceTraceContext,
                    terminal: terminal,
                    persistedCount: persistedCount,
                    failedCount: failedCount
                )
            }
            let completeCommittedPerformanceTrace: () -> Void = {
                guard let performanceTraceContext else {
                    return
                }
                let didCommit = self.performanceTraceRegistry.persistenceTerminal(
                    owner: key.owner,
                    queryID: event.queryId,
                    context: performanceTraceContext,
                    terminal: .committed,
                    persistedCount: completion.persistenceSummary.persistedRows,
                    failedCount: completion.persistenceSummary.failed
                )
                if !didCommit {
                    // A non-empty wire result without a MessageManager ingress
                    // proof must not be reported as a successful persistence
                    // terminal, even if a legacy presentation fallback accepts
                    // the page for UI continuity.
                    completePerformanceTrace(
                        .failed,
                        completion.persistenceSummary.persistedRows,
                        max(1, event.count)
                    )
                }
            }
            let commitResult = archiveManager?.commitAfterPersistence(
                queryId: event.queryId,
                persistenceSummary: completion.persistenceSummary
            ) ?? .missingDescriptor
            let consumerProof = archiveManager?.consumeCommittedArchiveConsumerProof(
                queryId: event.queryId
            )
            switch commitResult {
            case .committed:
                completeCommittedPerformanceTrace()
                recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint:
                            consumerProof?.boundaryFingerprint,
                        confirmsEmptyConversation:
                            consumerProof?.confirmsEmptyConversation ?? false,
                        hasPresentationMaterialization:
                            consumerProof?.hasPresentationMaterialization ?? false,
                        recommendedFollowUpTarget:
                            consumerProof?.recommendedFollowUpTarget
                    ),
                    // `.committed` is produced only after the query-scoped
                    // Realm transaction applies coverage/readiness and stores
                    // its immutable boundary proof. Reading legacy flags again
                    // can race a newer snapshot and must not weaken this receipt.
                    hasDurableCoverage: true
                )
            case .committedNeedsFollowUpRepair:
                completeCommittedPerformanceTrace()
                recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint:
                            consumerProof?.boundaryFingerprint,
                        confirmsEmptyConversation:
                            consumerProof?.confirmsEmptyConversation ?? false,
                        hasPresentationMaterialization:
                            consumerProof?.hasPresentationMaterialization ?? false,
                        recommendedFollowUpTarget:
                            consumerProof?.recommendedFollowUpTarget
                    ),
                    hasDurableCoverage: false
                )
            case .missingDescriptor where archiveManager == nil:
                completeCommittedPerformanceTrace()
                let presentationProof = legacyPresentationProof(
                    key: key,
                    event: event,
                    completion: completion,
                    hasPersistenceSource: false
                )
                recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        confirmsEmptyConversation:
                            presentationProof.confirmsEmptyConversation,
                        hasPresentationMaterialization:
                            presentationProof.hasPresentationMaterialization
                    ),
                    hasDurableCoverage:
                        presentationProof.hasPresentationMaterialization ||
                        presentationProof.confirmsEmptyConversation
                )
            case .missingDescriptor:
                completePerformanceTrace(.failed, 0, max(1, event.count))
                recordPersistenceFailure(
                    key: key,
                    queryId: event.queryId,
                    description: "Deferred archive commit descriptor is unavailable"
                )
            case .rejected(let rejection):
                completePerformanceTrace(.failed, 0, max(1, event.count))
                recordPersistenceFailure(
                    key: key,
                    queryId: event.queryId,
                    description: "Deferred archive commit rejected: \(rejection)"
                )
            }
            return
        }

        if let traceAttempt {
            traceArchiveLoad(
                "archiveLoadPersistenceStart",
                attempt: traceAttempt,
                phase: .persistence,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [("resultCount", event.count)]
            )
        }

        let expectedReceivedCount =
            archiveManager?.expectedPersistenceResultCount(
                queryId: event.queryId
            )
        ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync(
            owner: key.owner,
            queryId: event.queryId,
            state: event.state,
            expectedReceivedCount: expectedReceivedCount,
            conversationJid: key.jid,
            conversationType: ClientSynchronizationManager.ConversationType(
                rawValue: key.conversationTypeRawValue
            )
        ) { [weak self] completion in
            guard let self else { return }
            guard self.claimPersistenceCommit(key: key, queryId: event.queryId) else {
                return
            }
            let commitResult = archiveManager?.commitAfterPersistence(
                queryId: event.queryId,
                persistenceSummary: completion.persistenceSummary
            ) ?? .missingDescriptor
            let consumerProof = archiveManager?.consumeCommittedArchiveConsumerProof(
                queryId: event.queryId
            )
            switch commitResult {
            case .committed:
                self.recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint:
                            consumerProof?.boundaryFingerprint,
                        confirmsEmptyConversation:
                            consumerProof?.confirmsEmptyConversation ?? false,
                        hasPresentationMaterialization:
                            consumerProof?.hasPresentationMaterialization ?? false,
                        recommendedFollowUpTarget:
                            consumerProof?.recommendedFollowUpTarget
                    ),
                    // The deferred commit and consumer proof are one durable
                    // transaction result. Presentation validates the carried
                    // boundary fingerprint instead of polling Realm again.
                    hasDurableCoverage: true
                )
            case .committedNeedsFollowUpRepair:
                self.recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint:
                            consumerProof?.boundaryFingerprint,
                        confirmsEmptyConversation:
                            consumerProof?.confirmsEmptyConversation ?? false,
                        hasPresentationMaterialization:
                            consumerProof?.hasPresentationMaterialization ?? false,
                        recommendedFollowUpTarget:
                            consumerProof?.recommendedFollowUpTarget
                    ),
                    hasDurableCoverage: false
                )
            case .missingDescriptor where archiveManager == nil:
                // Unit/legacy sources that never opted into deferred MAM
                // coverage still use the coordinator's persistence barrier.
                let presentationProof = self.legacyPresentationProof(
                    key: key,
                    event: event,
                    completion: completion,
                    hasPersistenceSource: true
                )
                self.recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        confirmsEmptyConversation:
                            presentationProof.confirmsEmptyConversation,
                        hasPresentationMaterialization:
                            presentationProof.hasPresentationMaterialization
                    ),
                    hasDurableCoverage:
                        presentationProof.hasPresentationMaterialization ||
                        presentationProof.confirmsEmptyConversation
                )
            case .missingDescriptor:
                self.recordPersistenceFailure(
                    key: key,
                    queryId: event.queryId,
                    description: "Deferred archive commit descriptor is unavailable"
                )
            case .rejected(let rejection):
                self.recordPersistenceFailure(
                    key: key,
                    queryId: event.queryId,
                    description: "Deferred archive commit rejected: \(rejection)"
                )
            }
        }
    }

    private func recordPersistenceFailure(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        description: String,
        reason: MessageArchiveRequestFailureReason = .malformedResponse
    ) {
        let event = MessageArchiveRequestFailureEvent(
            owner: key.owner,
            queryId: queryId,
            streamKind: .unknown,
            reason: reason,
            errorDescription: description,
            pendingQueryCount: 0
        )
        let cleanup: Cleanup?
        var archiveManager: MessageArchiveManager?
        var traceAttempt: Attempt?
        lock.lock()
        if let attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.committedPage == nil,
           !(reason == .timeout && attempt.isPersistenceCommitClaimed) {
            traceAttempt = attempt
            archiveManager = attempt.archiveManager
            attemptsByKey.removeValue(forKey: key)
            finalReceivedOrder.removeAll { $0 == key }
            terminalFailuresByKey[key] = event
            recordTerminalKeyLocked(key)
#if DEBUG || CHAT_PERFORMANCE_LAB
            var diagnostics = productionDiagnosticsByKey[key] ?? .zero
            diagnostics.failedLeaseCount &+= 1
            productionDiagnosticsByKey[key] = diagnostics
#endif
            cleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
        } else {
            cleanup = nil
        }
        lock.unlock()
        archiveManager?.abortDeferredCommit(queryId: queryId)
        notifyReadinessObservers(key: key)
        guard let cleanup else { return }
        if let traceAttempt {
            if let traceContext = traceAttempt.lease.performanceTraceContext {
                _ = performanceTraceRegistry.terminate(
                    owner: key.owner,
                    queryID: queryId,
                    context: traceContext,
                    terminal: .failed
                )
            }
            traceArchiveLoad(
                "archiveLoadFail",
                attempt: traceAttempt,
                phase: .failed,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [
                    ("pendingQueryCount", 0),
                    ("persistenceFailure", true)
                ]
            )
        }
        // Presentation must leave skeleton immediately. Cleanup can itself
        // wait for a blocked Realm batch, so it is not the UI terminal.
        _ = MessageArchiveRequestFailureDispatcher.publish(event)
        performCleanup(cleanup, unregisterPersistenceSource: true)
    }

    /// A raw transport failure owns the wire terminal even though partial
    /// results may still be flushing. Release the account scheduler
    /// synchronously from the failure-preparation barrier, then keep the
    /// conversation lease alive until persistence publishes its terminal.
    private func recordWireFailure(
        key: ChatInitialBootstrapRequestKey,
        event: MessageArchiveRequestFailureEvent
    ) {
        var schedulerCompletion: (() -> Void)?
        var transportTimeout: DispatchWorkItem?
        var didTransition = false
        var traceAttempt: Attempt?
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == event.queryId,
           attempt.phase != .committed,
           attempt.phase != .failed {
            attempt.phase = .persistence
            schedulerCompletion = attempt.schedulerCompletion
            transportTimeout = attempt.timeoutWorkItem
            attempt.schedulerCompletion = nil
            attempt.hasWireTerminal = true
            attempt.timeoutWorkItem = nil
            attempt.failurePreparationToken = nil
            attemptsByKey[key] = attempt
            didTransition = true
            traceAttempt = attempt
        }
        lock.unlock()

        guard didTransition else { return }
        transportTimeout?.cancel()
        schedulerCompletion?()
        notifyReadinessObservers(key: key)
        installPersistenceTimeout(key: key, queryId: event.queryId)
        if let traceAttempt {
            traceArchiveLoad(
                "archiveLoadWireFail",
                attempt: traceAttempt,
                phase: .persistence,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [
                    ("pendingQueryCount", event.pendingQueryCount)
                ]
            )
        }
    }

    /// Atomically chooses the persistence terminal before touching MAM
    /// coverage. A timeout that wins first removes the attempt and aborts the
    /// descriptor; a commit that wins first cancels the timeout. Neither side
    /// can subsequently overwrite the other's readiness state.
    private func claimPersistenceCommit(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> Bool {
        var timeoutWorkItem: DispatchWorkItem?
        var didClaim = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.phase == .persistence,
           attempt.committedPage == nil,
           !attempt.isPersistenceCommitClaimed {
            attempt.isPersistenceCommitClaimed = true
            timeoutWorkItem = attempt.timeoutWorkItem
            attempt.timeoutWorkItem = nil
            attemptsByKey[key] = attempt
            didClaim = true
        }
        lock.unlock()

        timeoutWorkItem?.cancel()
        if didClaim {
            persistenceCommitClaimObserver?(queryId)
        }
        return didClaim
    }

    private func installPersistenceTimeout(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) {
        guard automaticallySchedulesTimeouts else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.recordPersistenceFailure(
                key: key,
                queryId: queryId,
                description: "Archive persistence timed out",
                reason: .timeout
            )
        }
        var didInstall = false
        var timeout = ChatInteractiveRemoteArchiveTimeoutPolicy.timeout
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.phase == .persistence,
           attempt.committedPage == nil {
            attempt.timeoutWorkItem?.cancel()
            attempt.timeoutWorkItem = workItem
            attemptsByKey[key] = attempt
            timeout = attempt.persistenceTimeout
            didInstall = true
        }
        lock.unlock()
        guard didInstall else {
            workItem.cancel()
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )
    }

    private func recordCommittedPage(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        page: CommittedPage,
        hasDurableCoverage: Bool = true
    ) {
        var committedCleanup: Cleanup?
        var evictedCleanup: Cleanup?
        var didRecord = false
        var traceAttempt: Attempt?
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.committedPage == nil {
            let recommendedFollowUpTarget:
                MessageArchiveManager.ChatBootstrapPageTarget? =
                page.recommendedFollowUpTarget ??
                (
                    !page.hasPresentationMaterialization &&
                    (
                        !hasDurableCoverage ||
                        !page.confirmsEmptyConversation
                    )
                        ? .latest
                        : nil
                )
            if let recommendedFollowUpTarget {
                let recommendedPurpose: ConversationArchiveLoadPurpose
                if case .older = recommendedFollowUpTarget {
                    recommendedPurpose = .interactiveBootstrap
                } else {
                    recommendedPurpose = .snapshotRepair
                }
                let existingPurpose = attempt.followUpTargetPurpose
                let shouldInstallRecommendation =
                    existingPurpose == nil ||
                    (
                        recommendedPurpose == .interactiveBootstrap &&
                        existingPurpose != .interactiveBootstrap
                    )
                if shouldInstallRecommendation {
                    attempt.followUpTargetFingerprint =
                        MessageArchiveManager.ChatBootstrapTargetFingerprint(
                            target: recommendedFollowUpTarget,
                            boundary: page.boundaryFingerprint
                        )
                    attempt.followUpTargetPurpose = recommendedPurpose
                    attempt.followUpPerformanceSemanticTargetFingerprint =
                        attempt.lease.performanceSemanticTargetFingerprint
                }
            }
            let requiresTargetFollowUp = attempt.followUpTargetFingerprint != nil
            committedCleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
            attempt.committedPage = page
            attempt.phase = .committed
            attempt.committedPageProvidesDurableCoverage = hasDurableCoverage
            attempt.hasDurableCoverage = hasDurableCoverage && !requiresTargetFollowUp
            attempt.confirmsEmptyConversation =
                hasDurableCoverage &&
                !requiresTargetFollowUp &&
                page.confirmsEmptyConversation
            attempt.messages = nil
            attempt.archiveManager = nil
            attempt.cancelTransport = nil
            attempt.timeoutWorkItem = nil
            attempt.endDispatcherToken = nil
            attempt.failureDispatcherToken = nil
            attempt.failurePreparationToken = nil
            attempt.schedulerCompletion = nil
            attempt.didRegisterPersistenceSource = false
            attempt.observers.removeAll(keepingCapacity: false)
            attemptsByKey[key] = attempt
            finalReceivedOrder.removeAll { $0 == key }
            finalReceivedOrder.append(key)
            while finalReceivedOrder.count > Self.finalReceivedAttemptLimit {
                let evictedKey = finalReceivedOrder.removeFirst()
                guard let evictedAttempt = attemptsByKey[evictedKey],
                      evictedAttempt.phase == .committed else {
                    continue
                }
                attemptsByKey.removeValue(forKey: evictedKey)
                evictedCleanup = makeCleanup(
                    key: evictedKey,
                    attempt: evictedAttempt,
                    includesTransportCancellation: false
                )
            }
            didRecord = true
#if DEBUG || CHAT_PERFORMANCE_LAB
            var diagnostics = productionDiagnosticsByKey[key] ?? .zero
            diagnostics.completedLeaseCount &+= 1
            productionDiagnosticsByKey[key] = diagnostics
#endif
            traceAttempt = attempt
        }
        lock.unlock()

        guard didRecord else {
            return
        }
        // A committed receipt is deliberately lightweight and survives its
        // controller. Release query managers/registrations before publishing
        // terminal readiness so teardown cannot strand them until reopen.
        performCleanup(committedCleanup, unregisterPersistenceSource: true)
        performCleanup(evictedCleanup, unregisterPersistenceSource: true)
        notifyReadinessObservers(key: key)
        if let traceAttempt {
            traceArchiveLoad(
                "archiveLoadCommit",
                attempt: traceAttempt,
                phase: .committed,
                waitMilliseconds: Int(
                    max(0, now().timeIntervalSince(traceAttempt.enqueuedAt)) * 1000
                ),
                additionalFields: [
                    ("persistedRows", page.completion.persistenceSummary.persistedRows),
                    ("processedRows", page.completion.persistenceSummary.processedRows),
                    ("resultCount", page.event.count),
                    ("failedRows", page.completion.persistenceSummary.failed)
                ]
            )
        }
    }

    private func expireDueAttempts() {
        lock.lock()
        let due = attemptsByKey.compactMap { key, attempt in
            (attempt.phase == .queued || attempt.phase == .transport) &&
                attempt.endPageEvent == nil &&
                attempt.lease.deadline <= now()
                ? (key, attempt.lease.queryId)
                : nil
        }
        lock.unlock()
        due.forEach { key, queryId in
            expireAttemptIfDue(key: key, expectedQueryId: queryId)
        }
    }

    private func expireAttemptIfDue(
        key: ChatInitialBootstrapRequestKey,
        expectedQueryId: String? = nil
    ) {
        lock.lock()
        let lease = attemptsByKey[key]?.lease
        let endPageEvent = attemptsByKey[key]?.endPageEvent
        let phase = attemptsByKey[key]?.phase
        let isDue = (phase == .queued || phase == .transport) &&
            endPageEvent == nil && (lease.map { candidate in
            (expectedQueryId == nil || candidate.queryId == expectedQueryId) &&
                candidate.deadline <= now()
        } ?? false)
        lock.unlock()
        guard isDue,
              let lease else {
            return
        }
        let event = MessageArchiveRequestFailureEvent(
            owner: key.owner,
            queryId: lease.queryId,
            streamKind: .unknown,
            reason: .timeout,
            errorDescription: nil,
            pendingQueryCount: 1
        )
        _ = recordFailure(key: key, event: event, publishEvent: true)
    }

    private func readinessLocked(
        for key: ChatInitialBootstrapRequestKey
    ) -> ConversationArchiveReadiness? {
        if terminalFailuresByKey[key] != nil {
            return ConversationArchiveReadiness(
                phase: .failed,
                hasDurableCoverage: false,
                confirmsEmptyConversation: false,
                persistedVisibleRowCount: 0
            )
        }
        guard let attempt = attemptsByKey[key] else {
            return nil
        }
        let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: key.conversationTypeRawValue
        )
        let visibleRows = conversationType.flatMap { conversationType in
            attempt.committedPage?.completion.persistenceSummary.visibleRows(
                owner: key.owner,
                jid: key.jid,
                conversationType: conversationType
            )
        } ?? 0
        return ConversationArchiveReadiness(
            phase: attempt.phase,
            hasDurableCoverage: attempt.hasDurableCoverage,
            confirmsEmptyConversation: attempt.confirmsEmptyConversation,
            persistedVisibleRowCount: visibleRows,
            boundaryFingerprint: attempt.committedPage?.boundaryFingerprint
        )
    }

    private func notifyReadinessObservers(key: ChatInitialBootstrapRequestKey) {
        lock.lock()
        let observers = readinessObserversByKey[key].map { Array($0.values) } ?? []
        let value = readinessLocked(for: key)
        lock.unlock()
        observers.forEach { $0(value) }
    }

    private func makeCleanup(
        key: ChatInitialBootstrapRequestKey,
        attempt: Attempt,
        includesTransportCancellation: Bool
    ) -> Cleanup {
        Cleanup(
            owner: key.owner,
            queryId: attempt.lease.queryId,
            performanceTraceContext: attempt.lease.performanceTraceContext,
            timeoutWorkItem: attempt.timeoutWorkItem,
            endDispatcherToken: attempt.endDispatcherToken,
            failureDispatcherToken: attempt.failureDispatcherToken,
            failurePreparationToken: attempt.failurePreparationToken,
            cancelTransport: includesTransportCancellation ? attempt.cancelTransport : nil,
            schedulerCompletion: attempt.schedulerCompletion
        )
    }

    private func performCleanup(
        _ cleanup: Cleanup?,
        unregisterPersistenceSource: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard let cleanup else {
            completion?()
            return
        }
        if let traceContext = cleanup.performanceTraceContext {
            _ = performanceTraceRegistry.terminate(
                owner: cleanup.owner,
                queryID: cleanup.queryId,
                context: traceContext,
                terminal: .cancelled
            )
        }
        cleanup.timeoutWorkItem?.cancel()
        if let token = cleanup.endDispatcherToken {
            MessageArchiveEndPageDispatcher.unregister(token)
        }
        if let token = cleanup.failureDispatcherToken {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
        if let token = cleanup.failurePreparationToken {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(token)
        }
        cleanup.cancelTransport?()
        // The scheduler resource models only the XMPP wire. Realm cleanup is
        // deliberately allowed to continue after the next transport starts.
        cleanup.schedulerCompletion?()
        if unregisterPersistenceSource {
            ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
                owner: cleanup.owner,
                queryId: cleanup.queryId,
                completion: {
                    completion?()
                }
            )
        } else {
            completion?()
        }
    }

    private func recordTerminalKeyLocked(_ key: ChatInitialBootstrapRequestKey) {
        terminalFailureOrder.removeAll { $0 == key }
        terminalFailureOrder.append(key)
        while terminalFailureOrder.count > Self.terminalTombstoneLimit {
            let expiredKey = terminalFailureOrder.removeFirst()
            terminalFailuresByKey.removeValue(forKey: expiredKey)
        }
    }

    private func recordCancelledTransportIdentityLocked(_ identity: AttemptIdentity) {
        cancelledTransportIdentities.insert(identity)
        cancelledTransportIdentityOrder.removeAll { $0 == identity }
        cancelledTransportIdentityOrder.append(identity)
        while cancelledTransportIdentityOrder.count > Self.cancelledTransportIdentityLimit {
            cancelledTransportIdentities.remove(cancelledTransportIdentityOrder.removeFirst())
        }
    }
}

extension ChatViewController {
    internal var initialBootstrapRequestKey: ChatInitialBootstrapRequestKey {
        self.initialBootstrapLeaseKey ?? ChatInitialBootstrapRequestKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
    }

    internal var currentInitialBootstrapTargetFingerprint:
        MessageArchiveManager.ChatBootstrapTargetFingerprint {
        let target: MessageArchiveManager.ChatBootstrapPageTarget
        if self.conversationType == .regular,
           let request = self.pendingOpenMessageRequest,
           request.owner == self.owner,
           request.chatJid == self.jid,
           request.conversationType == self.conversationType {
            switch request.targetResolution {
            case .firstIncomingAfterBoundary(let boundaryArchiveId):
                target = .firstUnread(afterArchiveId: boundaryArchiveId)
            case .anchor where request.source == .savedVisiblePosition:
                target = .savedPosition(
                    messagePrimary: request.anchor.messagePrimary,
                    archivedId: request.anchor.archivedId,
                    messageId: request.anchor.messageId,
                    sourceDate: request.anchor.sourceDate
                )
            case .anchor:
                // Keep the exact semantic target in the account-scoped
                // fingerprint even though generic message opens are executed
                // by the anchor transaction below. Collapsing this to latest
                // allows an unrelated newest-page lease to be adopted.
                target = .savedPosition(
                    messagePrimary: request.anchor.messagePrimary,
                    archivedId: request.anchor.archivedId,
                    messageId: request.anchor.messageId,
                    sourceDate: request.anchor.sourceDate
                )
            }
        } else {
            target = .latest
        }
        return MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: target,
            boundary: self.currentInitialFrameReadinessProof()?
                .archiveBoundaryFingerprint
        )
    }

    internal func initialBootstrapTransportTarget(
        for semanticTarget: MessageArchiveManager.ChatBootstrapPageTarget
    ) -> MessageArchiveManager.ChatBootstrapPageTarget {
        guard case .savedPosition = semanticTarget,
              let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType else {
            return semanticTarget
        }
        let requestTarget = MessageArchiveManager.ChatBootstrapPageTarget.savedPosition(
            messagePrimary: request.anchor.messagePrimary,
            archivedId: request.anchor.archivedId,
            messageId: request.anchor.messageId,
            sourceDate: request.anchor.sourceDate
        )
        guard semanticTarget == requestTarget,
              case .blockingRepair(let repair) = self.savedPositionFirstFrameDecision(
                for: request
              ) else {
            return semanticTarget
        }

        let direction: MessageArchiveManager.RegularArchiveGapRepairDirection
        switch repair.direction {
        case .older:
            direction = .older
        case .newer:
            direction = .newer
        }
        return .savedPositionGapRepair(
            olderRangeNewestArchiveId: repair.gap.olderRangeNewestArchiveId,
            newerRangeOldestArchiveId: repair.gap.newerRangeOldestArchiveId,
            direction: direction
        )
    }

    internal func resumeInitialBootstrapArchiveRequestAfterSavedPositionProbeIfNeeded() {
        guard self.isInitialBootstrapArchiveRequestDeferredForSavedPositionProbe else {
            return
        }
        self.isInitialBootstrapArchiveRequestDeferredForSavedPositionProbe = false
        self.requestInitialBootstrapArchive()
    }

    internal func acquireInteractiveChatOpenGateIfNeeded() {
        if self.initialBootstrapPresentationDeadline == nil {
            self.initialBootstrapPresentationDeadline = Date().addingTimeInterval(
                ChatInitialBootstrapPresentationWatchdogPolicy.maximumPresentationTimeout
            )
        }
        guard self.interactiveChatOpenGateToken == nil,
              let account = AccountManager.shared.find(for: self.owner) else {
            return
        }
        let gate = account.interactiveChatOpenGate
        self.interactiveChatOpenGate = gate
        self.interactiveChatOpenGateToken = gate.acquire()
    }

    internal func releaseInteractiveChatOpenGate() {
        guard let gate = self.interactiveChatOpenGate,
              let token = self.interactiveChatOpenGateToken else {
            self.interactiveChatOpenGate = nil
            self.interactiveChatOpenGateToken = nil
            return
        }
        self.interactiveChatOpenGate = nil
        self.interactiveChatOpenGateToken = nil
        _ = gate.release(token)
    }

    private var chatPresentationRefreshKey: String {
        "chat.presentation.\(owner).\(jid).\(conversationType.rawValue)"
    }

    final func runOrDeferChatPresentationRefresh(
        keySuffix: String,
        work: @escaping () -> Void
    ) {
        ChatUIResponsivenessGate.shared.runOrDefer(
            workKind: .presentationRefresh,
            key: "\(chatPresentationRefreshKey).\(keySuffix)",
            work: work
        )
    }

    public func updateSearchResults(value: String?) {
        acceptSearchSessionQuery(value, flushImmediately: true)
    }

    internal func executeSearchRequest(_ request: ChatSearchSession.Request) {
        guard searchSession.isCurrentRequest(request),
              request.scope.owner == owner,
              request.scope.jid == jid,
              request.scope.conversationTypeRawValue == conversationType.rawValue else {
            return
        }
        let normalizedValue = request.query
        self.reduceSearchPresentationState(
            .debounceElapsed(generation: self.searchPresentationState.generation)
        )
        if request.provider == .localEncrypted {
            guard let context = self.beginInChatSearchQueryIfNeeded(
                text: normalizedValue,
                queryId: "Local search:\(request.generation):\(NanoID.new(8))"
            ) else {
                return
            }
            searchSessionGenerationByQueryId[context.queryId] = request.generation
            searchOlderPageNavigationGate.reset(generation: request.generation)
            self.searchMessagesQueue = []
            self.searchResultPresentations = []
            let localRequest = ChatSearchLocalProvider.Request(
                generation: request.generation,
                queryId: context.queryId,
                query: normalizedValue,
                mappingContext: inChatSearchResultMappingContext
            )
            searchLocalProvider.search(localRequest) { [weak self] event in
                guard let self,
                      event.generation == request.generation,
                      event.queryId == context.queryId,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                switch event.phase {
                case .batch(let results):
                    _ = self.appendDetachedInChatSearchResultsIfCurrent(
                        results,
                        queryId: context.queryId
                    )
                case .completed:
                    _ = self.finishInChatSearchQueryIfCurrent(
                        queryId: context.queryId,
                        emptyList: self.searchResultPresentations.isEmpty
                    )
                case .failed(let failure):
                    DDLogDebug("ChatViewController: local search failed: \(failure)")
                    _ = self.handleInChatSearchQueryFailure(queryId: context.queryId)
                case .cancelled:
                    break
                }
            }
        } else {
            guard let context = self.beginInChatSearchQueryIfNeeded(
                text: normalizedValue,
                queryId: "MAM search:\(request.generation):\(NanoID.new(8))"
            ) else {
                return
            }
            searchSessionGenerationByQueryId[context.queryId] = request.generation
            searchOlderPageNavigationGate.reset(generation: request.generation)
            self.applyLegacySearchPanelStateFromPresentation()
            self.registerRemoteHistoryFailureDispatcher(queryId: context.queryId)
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: { [weak self] item, queryId in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    self?.didReceiveMessage(item, queryId: queryId)
                },
                onEndPage: { [weak self] queryId, state, first, last, count in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                },
                onFailure: { [weak self] event in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    _ = self?.handleInChatSearchQueryFailure(queryId: event.queryId)
                },
                onSearchTerminal: { [weak self] queryId, terminal in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    if case .failed = terminal {
                        _ = self?.handleInChatSearchQueryFailure(queryId: queryId)
                    }
                    self?.markOlderSearchResultsTerminal(generation: request.generation)
                },
                onSearchContinuationAvailable: { [weak self] queryId, cursor in
                    DispatchQueue.main.async {
                        self?.offerOlderSearchResultsCursor(
                            cursor,
                            queryId: queryId,
                            generation: request.generation
                        )
                    }
                }
            )
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { [weak self] stream, session in
                guard let self,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                guard let mam = session.mam else {
                    self.handleInChatSearchQueryFailure(queryId: context.queryId)
                    return
                }
                let queryId = mam.searchText(
                    stream,
                    jid: context.jid,
                    conversationType: context.conversationType,
                    text: context.text,
                    queryId: context.queryId,
                    generation: request.generation,
                    requestCallbacks: requestCallbacks
                )
                self.searchArchiveManagersByQueryId[queryId] = mam
                self.registerRemoteHistoryPersistenceSource(session.messages, queryId: queryId)
            } fail: { [weak self] in
                guard let self,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                guard let account = AccountManager.shared.find(for: self.owner) else {
                    self.handleInChatSearchQueryFailure(queryId: context.queryId)
                    return
                }
                account.action({ [weak self] user, stream in
                    guard let self,
                          self.searchSession.isCurrentRequest(request),
                          self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                        return
                    }
                    let queryId = user.mam.searchText(
                        stream,
                        jid: context.jid,
                        conversationType: context.conversationType,
                        text: context.text,
                        queryId: context.queryId,
                        generation: request.generation,
                        requestCallbacks: requestCallbacks
                    )
                    self.searchArchiveManagersByQueryId[queryId] = user.mam
                    self.registerRemoteHistoryPersistenceSource(user.messages, queryId: queryId)
                })
            }
        }
    }
    
    internal func bindInitialMessageOverlayVisibility() {
        self.shouldShowInitialMessage
            .asObservable()
            .observe(on: MainScheduler.instance)
            .subscribe { value in
                if value {
                    if self.initialMessageOverlayView.superview == nil {
                        self.view.addSubview(self.initialMessageOverlayView)
                    }
                    self.updateInitialMessageOverlayFrame()
                    self.initialMessageOverlayView.isHidden = false
                } else {
                    self.initialMessageOverlayView.isHidden = true
                    self.initialMessageOverlayView.removeFromSuperview()
                }
            }
            .disposed(by: self.bag)
    }

    internal func subscribe() throws {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        self.bag = DisposeBag()
        let realm = try WRealm.safe()
        self.configureDataset()
        self.observeConversationArchiveTerminal()
        let retainedTerminalBootstrapState: ChatBootstrapLoadingState? = {
            guard let state = self.appliedBootstrapLoadingState,
                  !state.showsSkeleton,
                  !state.showsRetry else {
                return nil
            }
            return state
        }()
        if self.hasCommittedRealContentInCurrentLifecycle {
            self.appliedBootstrapLoadingState = .content
        } else if self.hasCommittedBootstrapSkeletonRows {
            let preservedState = self.appliedBootstrapLoadingState
            self.appliedBootstrapLoadingState = preservedState?.showsSkeleton == true
                ? preservedState
                : .blockingArchive
        } else if self.appliedBootstrapLoadingState?.showsRetry != true {
            self.appliedBootstrapLoadingState = nil
        }
        self.lastBootstrapAtomicRevealPlan = nil
        self.cancelInitialBootstrapLocalHistoryFallback()
        let initialChatInstance = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType
            )
        )
        let initialBootstrapLoadingState = retainedTerminalBootstrapState ??
            self.bootstrapLoadingState(chatInstance: initialChatInstance)
        self.applyBootstrapLoadingState(
            initialBootstrapLoadingState,
            forceRender: self.datasource.isEmpty || !self.isShowingBootstrapPlaceholder,
            synchronousSkeletonCommit: initialBootstrapLoadingState.showsSkeleton
        )
        if initialBootstrapLoadingState.showsSkeleton {
            self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
        }
        self.requestInitialBootstrapArchive()
        
        if self.conversationType == .group {
            do {
                let realm = try WRealm.safe()
                var groupMemberUnreadMetadataRefreshGate =
                    ChatGroupMemberUnreadMetadataRefreshGate(
                        authoritativeMemberId: initialChatInstance?.groupchatMyId
                    )
                let myGroupUser = realm.objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
                Observable
                    .collection(from: myGroupUser, synchronousStart: true)
                    .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
                    .observe(on: MainScheduler.asyncInstance)
                    .subscribe(onNext: { results in
                        let observedMemberId = results.first(where: {
                            !$0.isHidden
                        })?.userId
                        if groupMemberUnreadMetadataRefreshGate.shouldRefresh(
                            observedMemberId: observedMemberId
                        ) {
                            _ = self.timelineSession?.refreshUnreadMetadata()
                        }
                        self.rebuildUnreadMentionItems()
                        self.refreshUnreadMentionsNavigatorState(animated: true)
                    })
                    .disposed(by: self.bag)
                Observable
                    .collection(
                        from: realm
                            .objects(GroupChatStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, self.jid),
                        synchronousStart: true
                    )
                    .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
                    .observe(on: MainScheduler.asyncInstance)
                    .subscribe(onNext: { results in
                        guard let groupchat = results.first else {
                            self.updatePinnedMessagePanelState(pinnedMessageId: nil, canUnpin: false)
                            return
                        }
                        self.updatePinnedMessagePanelState(
                            pinnedMessageId: groupchat.pinnedMessage,
                            canUnpin: groupchat.canChangeSettings
                        )
                    })
                    .disposed(by: self.bag)
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
        
        self.showLoadingIndicator
            .asObservable()
            .debounce(.microseconds(100), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
//                DispatchQueue.main.async {
                self.chatViewLoadingOverlay.isHidden = !value
//                }
            }
            .disposed(by: bag)
        
        self.bindInitialMessageOverlayVisibility()

        
        self.inSearchMode
            .asObservable()
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                if self.deferUntilNavigationTransitionCompletesIfNeeded({ [weak self] in
                    self?.inSearchMode.accept(value)
                }) {
                    return
                }
                if value {
                    self.configureSearchModeForCurrentActivation(
                        defaultActivateKeyboard: !self.isNavigationTransitionActive,
                        defaultAnimated: ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                            requestedAnimated: true,
                            isTransitionActive: self.isNavigationTransitionActive,
                            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                        )
                    )
                    self.xabberInputView.changeState(to: .search)
                    self.updateChatInputKeyboardLayoutMode()
                    self.shouldShowScrollDownButton.accept(false)
                    if self.shouldShowUnreadMentionsNavigator.value {
                        self.shouldShowUnreadMentionsNavigator.accept(false)
                    }
                } else {
                    self.searchTextObserver.accept(nil)
                    self.configureNavbar()
                    self.xabberInputView.changeState(to: .normal)
                    self.updateChatInputKeyboardLayoutMode()
                    self.applyChatDatasource(
                        self.datasource,
                        mode: .fullReload(),
                        animated: ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                            requestedAnimated: true,
                            isTransitionActive: self.isNavigationTransitionActive,
                            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                        )
                    )
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                }
            })
            .disposed(by: bag)
        
        self.shouldShowScrollDownButton
            .asObservable()
            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                if value {
                    if self.inSearchMode.value {
                        self.shouldShowScrollDownButton.accept(false)
                    } else {
                        self.updateScrollDownButtonFrame(animated: true)
                        self.updateUnreadMentionsNavigatorFrame(animated: true)
                    }
                } else {
                    self.updateScrollDownButtonFrame(animated: true)
                    self.updateUnreadMentionsNavigatorFrame(animated: true)
                }
            }
            .disposed(by: bag)

        self.shouldShowUnreadMentionsNavigator
            .asObservable()
            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.updateUnreadMentionsNavigatorFrame(animated: true)
                self.updateScrollDownButtonFrame(animated: true)
            }
            .disposed(by: bag)
        
        self.contentOffsetObserver
            .asObservable()
            .debounce(.milliseconds(40), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
//                self.showFloatingDateObserver.accept(false)
                let animated = self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: true)
                let shouldShow = ChatScrollDownButtonVisibilityPolicy.shouldShow(
                    contentOffsetY: value,
                    isNearBottom: self.isNearBottom(),
                    isSearchMode: self.inSearchMode.value
                )
                if shouldShow {
                    if !self.shouldShowScrollDownButton.value {
                        self.shouldShowScrollDownButton.accept(true)
                    }
                } else {
                    if self.shouldShowScrollDownButton.value {
                        self.shouldShowScrollDownButton.accept(false)
                    }
                }
                self.refreshUnreadMentionsNavigatorState(animated: animated)
            }
            .disposed(by: bag)

        self.contentOffsetObserver
            .asObservable()
            .skip(1)
            .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.saveCurrentVisibleMessagePositionIfNeeded()
            }
            .disposed(by: bag)

        self.updateFloatingDateObserverSignal
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.updateFloatingDate()
            }
            .disposed(by: bag)

        
        self.topPanelState
            .asObservable()
            .debounce(.nanoseconds(1), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { state in
                switch state {
                    case .none:
                        self.hideTopPanelBubble(animated: false)
                    case .pinnedMessage:
                        self.applyPinMessagePanel()
                    case .addContact:
                        self.applyAddContactPanel()
                    case .requestSubscribtion:
                        self.applyRequestSubscribtionPanel()
                    case .allowSubscribtion:
                        self.applyAllowSubscribtion()
                    case .requestedVerification:
                        self.applyRequestedVerificationPanel()
                    case .enterCodeVerification:
                        self.applyEnterCodePanel()
                    case .requestingVerification:
                        self.applyRequestingVerificationPanel()
                    case .shouldRequestVerification:
                        self.applyShouldRequestVerificationPanel()
                    case .acceptedVerification:
                        self.applyAcceptedVerification()
                    case .audioPlayer:
                        self.hideTopPanelBubble(animated: false)
                        self.applyAudioPlayerPanel()
                }
            }.disposed(by: bag)

        
//        if !self.groupchat {
        Observable
            .collection(from: realm
                                .objects(ResourceStorageItem.self)
                                .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                                .sorted(by: [SortDescriptor(keyPath: "timestamp", ascending: false),
                                             SortDescriptor(keyPath: "priority", ascending: false)]))
            .observe(on: MainScheduler.asyncInstance)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
//                .skip(1)
            .subscribe(onNext: { (results) in
                let nickname = self.opponentSender.displayName
                let offlineStatus = "last seen recently".localizeString(id: "last_seen_recently", arguments: [])
                let status = (results.first?.statusMessage.isEmpty ?? true) ? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus) : results.first?.statusMessage ?? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
//                    self.contactUsename = nickname
                let statusStr = self.connectionAwareStatusText(fallbackStatus: status)
                self.runOrDeferChatPresentationRefresh(keySuffix: "presence") { [weak self] in
                    guard let self else { return }
                    self.titleLabel.attributedText = self.updateTitle()
                    if self.statusLabel.text == " " && self.conversationType != .saved {
                        self.statusLabel.text = statusStr
                    }
                    if self.shouldShowNormalStatus {
                        self.setStatusText(statusStr)
                        self.contactStatus = status
                        self.statusLabel.layoutIfNeeded()
                    }
                    self.titleLabel.sizeToFit()
                    self.titleLabel.layoutIfNeeded()
                }
                
            })
            .disposed(by: bag)
//        }
        
        let lastChatsObservedCollection = realm
            .objects(LastChatsStorageItem.self)
            .filter("jid == %@ AND owner == %@ AND conversationType_ == %@", self.jid, self.owner, self.conversationType.rawValue)
        if let chat = lastChatsObservedCollection.first {
            self.xabberInputView.setComposerText(chat.draftMessage)
            self.xabberInputView.textViewDidChange(force: true)

            self.updateContentByLastChatInstance(chat)
        } else {
            self.applyBootstrapViewState(self.bootstrapViewState(chatInstance: nil), forceRender: self.datasource.isEmpty)
        }
        Observable
            .collection(from: lastChatsObservedCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                guard let item = results.first else {
                    self.applyBootstrapViewState(self.bootstrapViewState(chatInstance: nil), forceRender: self.datasource.isEmpty)
                    return
                }
                self.updateContentByLastChatInstance(item)
                    
            })
            .disposed(by: bag)

        Observable
            .collection(from: realm
                .objects(RosterStorageItem.self)
                .filter("owner == %@ AND jid == %@", owner, jid))
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                if self.conversationType == .group { return }
                
                if self.conversationType == .saved {
                    let usersCount = AccountManager.shared.users.count
                    
                    if usersCount > 1 {
                        self.contactStatus = self.owner
                        self.updateStatusText()
                    }
                    
                    return
                    
                } else if (XMPPJID(string: self.jid)?.isServer ?? false) {
                    self.contactStatus = "Server"
                    self.updateStatusText()
                    return
                }
                let presentation = self.chatSubscriptionPresentation(
                    rosterItem: results.first,
                    realm: realm
                )
                self.runOrDeferChatPresentationRefresh(keySuffix: "subscription") { [weak self] in
                    guard let self else { return }
                    self.applyChatSubscriptionPresentation(presentation)
                    if presentation.showsNormalPresenceStatus {
                        self.applyNormalPresenceStatus(realm: realm)
                    }
                }
            }).disposed(by: bag)

        Observable
            .collection(from: realm
                .objects(BlockStorageItem.self)
                .filter("owner == %@ AND jid == %@", owner, jid))
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { _ in
                guard self.conversationType != .group,
                      self.conversationType != .saved,
                      !(XMPPJID(string: self.jid)?.isServer ?? false) else {
                    return
                }

                let rosterItem = realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)
                )
                let presentation = self.chatSubscriptionPresentation(
                    rosterItem: rosterItem,
                    realm: realm
                )
                self.runOrDeferChatPresentationRefresh(keySuffix: "block") { [weak self] in
                    guard let self else { return }
                    self.applyChatSubscriptionPresentation(presentation)
                    if presentation.showsNormalPresenceStatus {
                        self.applyNormalPresenceStatus(realm: realm)
                    }
                }
            }).disposed(by: bag)

        
        self.statusLabel.text = self.statusTextObserver.value
        self.statusLabel.layoutIfNeeded()
        self.statusTextObserver
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { (value) in
                self.runOrDeferChatPresentationRefresh(keySuffix: "statusText") { [weak self] in
                    guard let self else { return }
                    self.statusLabel.text = value
                    self.statusLabel.layoutIfNeeded()
                }
            } onError: { (error) in
                DDLogDebug("\(#function). \(error.localizedDescription)")
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: self.bag)

    }
    
    internal func resumeInitialBootstrapArchiveRequestAfterSkeletonReceiptIfNeeded() {
        guard let showFailureIfUnavailable =
                self.pendingInitialBootstrapArchiveRequestAfterSkeletonReceiptShowsFailure else {
            return
        }
        self.pendingInitialBootstrapArchiveRequestAfterSkeletonReceiptShowsFailure = nil
        self.requestInitialBootstrapArchive(
            showFailureIfUnavailable: showFailureIfUnavailable
        )
    }

    internal func requestInitialBootstrapArchive(showFailureIfUnavailable: Bool = false) {
        if let performanceTraceContext = self.chatOpenPerformanceTraceContext,
           self.appliedBootstrapLoadingState?.showsSkeleton == true,
           !self.chatOpenPerformanceTraceLifecycle
            .hasRecordedPresentationReceipt(
                .skeleton,
                context: performanceTraceContext
            ) {
            self.pendingInitialBootstrapArchiveRequestAfterSkeletonReceiptShowsFailure =
                (self.pendingInitialBootstrapArchiveRequestAfterSkeletonReceiptShowsFailure ?? false) ||
                showFailureIfUnavailable
            return
        }
        self.pendingInitialBootstrapArchiveRequestAfterSkeletonReceiptShowsFailure = nil
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = self.initialBootstrapLeaseKey ?? ChatInitialBootstrapRequestKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let currentTargetFingerprint = self.currentInitialBootstrapTargetFingerprint
        let requestedTargetFingerprint =
            MessageArchiveManager.ChatBootstrapTargetFingerprint(
                target: self.initialBootstrapFollowUpTargetOverride ??
                    currentTargetFingerprint.target,
                boundary: currentTargetFingerprint.boundary
            )
        if self.shouldDeferInitialBootstrapArchiveForSavedPositionProbe(
            requestedTargetFingerprint.target
        ) {
            self.isInitialBootstrapArchiveRequestDeferredForSavedPositionProbe = true
            return
        }
        if self.shouldDeferInitialBootstrapArchiveForAnchorTransaction(
            requestedTargetFingerprint.target
        ) {
            self.isInitialBootstrapArchiveRequestDeferredForSavedPositionProbe = false
            self.performOnMain { [weak self] in
                self?.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
            }
            return
        }
        self.isInitialBootstrapArchiveRequestDeferredForSavedPositionProbe = false
        let requestedTransportTarget = self.initialBootstrapTransportTarget(
            for: requestedTargetFingerprint.target
        )
        self.initialBootstrapLeaseKey = key
        let requiresArchiveConfirmation = self.currentBootstrapRequiresArchiveConfirmation()
        if let committedReadiness = coordinator.readiness(for: key),
           self.shouldInvalidateCommittedArchiveReceipt(
               committedReadiness,
               requiresArchiveConfirmation: requiresArchiveConfirmation
           ),
           let committedLease = coordinator.committedLease(for: key),
           let latestReadiness = coordinator.readiness(for: key),
           self.shouldInvalidateCommittedArchiveReceipt(
               latestReadiness,
               requiresArchiveConfirmation: self.currentBootstrapRequiresArchiveConfirmation()
           ) {
            // A retained receipt proves the snapshot it committed. If Realm
            // now requires archive confirmation again, a newer snapshot has
            // invalidated that proof and this open must acquire fresh work.
            _ = coordinator.invalidateCommittedReceipt(
                key: key,
                queryId: committedLease.queryId
            )
        }
        // Realm/snapshot state can change while a retained receipt is being
        // checked. Make the acquire decision from a fresh boundary read.
        let requiresArchiveConfirmationNow = self.currentBootstrapRequiresArchiveConfirmation()
        let activeReadiness = coordinator.readiness(for: key)
        let hasUncommittedLease = activeReadiness.map {
            $0.phase == .queued || $0.phase == .transport || $0.phase == .persistence
        } ?? false
        let hasPendingTargetPage: Bool = {
            guard requestedTargetFingerprint.target != .latest,
                  let request = self.pendingOpenMessageRequest,
                  request.owner == self.owner,
                  request.chatJid == self.jid,
                  request.conversationType == self.conversationType else {
                return false
            }
            return !self.hasLocalAnchorForBootstrap(request)
        }()
        guard ChatInitialBootstrapRequestAdmissionPolicy.shouldAcquire(
            requiresArchiveConfirmation: requiresArchiveConfirmationNow,
            hasUncommittedLease: hasUncommittedLease,
            hasPendingTargetPage: hasPendingTargetPage
        ) else {
            // Never discard an account-scoped lease here: one may have been
            // installed after the readiness read, and active work always wins
            // over legacy Realm flags. A later readiness/Realm notification
            // will join it or request the newly required boundary.
            coordinator.clearTerminal(key: key)
            self.performOnMain {
                self.hasAttemptedInitialBootstrapBoundaryFollowUp = false
                // Retry can race a durable foreground readiness update. When
                // no lease is required anymore, the retained failure overlay
                // has no future archive commit that could replace it.
                self.preservesBootstrapFailureOverlayUntilRetryCommit = false
                self.cancelInitialBootstrapAutomaticRetry(
                    resetFailureCount: true
                )
                self.setBootstrapFailureVisible(false)
                self.resetInitialBootstrapTracking()
                self.releaseInteractiveChatOpenGate()
                _ = self.revealStaleLocalHistoryIfNeeded()
                // The admission decision was made from durable Realm/archive
                // state. `currentBootstrapLoadingState()` intentionally has
                // no synchronous Realm object and can therefore still reduce
                // to blockingArchive during the short cross-thread refresh
                // window after a zero-result commit. Do not turn that stale
                // snapshot into a new loading presentation or another MAM.
                let satisfiedLoadingState =
                    ChatInitialBootstrapSatisfiedPresentationPolicy.loadingState(
                        localMessageCount:
                            self.localHistoryMessageCountForBootstrap(),
                        hasPendingInitialAnchorRequest:
                            self.hasPendingInitialAnchorRequest()
                    )
                self.applyBootstrapLoadingState(
                    satisfiedLoadingState,
                    forceRender: true,
                    hasTrustedPersistedBootstrapPage: true
                )
            }
            return
        }
        let proposedQueryId = "MAM bootstrap history: \(NanoID.new(6))"
        let owner = self.owner
        let jid = self.jid
        let conversationType = self.conversationType
        let pageSize = self.initialBootstrapArchiveRequestPageSize
        let acquisition = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: proposedQueryId,
            timeout: ChatInteractiveRemoteArchiveTimeoutPolicy.timeout,
            targetFingerprint: requestedTargetFingerprint,
            performanceTraceContext: self.chatOpenPerformanceTraceContext,
            performanceSemanticTargetFingerprint:
                self.chatOpenPerformanceSemanticTargetFingerprint(
                    for: self.pendingOpenMessageRequest
                ),
            performanceSkeletonReceiptWasCommitted:
                self.chatOpenPerformanceTraceContext.map {
                    self.chatOpenPerformanceTraceLifecycle
                        .hasRecordedPresentationReceipt(
                            .skeleton,
                            context: $0
                        )
                } ?? false
        ) { [weak self] expectedQueryId, result, _ in
            self?.handleSyncChatStartResult(
                result,
                expectedQueryId: expectedQueryId
            )
        }

        let lease: ChatInitialBootstrapRequestCoordinator.Lease
        switch acquisition {
        case .terminal(let event):
            self.beginInitialBootstrapTracking(queryId: event.queryId, timeout: nil)
            self.handleInitialBootstrapRemoteArchiveFailure(
                queryId: event.queryId,
                reason: event.reason,
                streamKind: event.streamKind,
                errorDescription: event.errorDescription
            )
            return
        case .start(let acquiredLease):
            lease = acquiredLease
        case .joined(let acquiredLease):
            lease = acquiredLease
            _ = coordinator.promote(key: key)
        }
        defer {
            _ = coordinator.releaseInteractiveCommittedJoinReservation(
                key: key,
                queryId: lease.queryId
            )
        }
        let requestedPerformanceSemanticTargetFingerprint =
            self.chatOpenPerformanceSemanticTargetFingerprint(
                for: self.pendingOpenMessageRequest
            )
        if lease.targetFingerprint.target == requestedTargetFingerprint.target,
           lease.performanceSemanticTargetFingerprint ==
            requestedPerformanceSemanticTargetFingerprint,
           let controllerContext = self.chatOpenPerformanceTraceContext {
            assert(
                lease.performanceTraceContext == controllerContext,
                "A same-target bootstrap lease must retain the accepted open context"
            )
        }
        self.initialBootstrapTargetFingerprint = lease.targetFingerprint
        self.initialBootstrapPerformanceSemanticTargetFingerprint =
            lease.performanceSemanticTargetFingerprint
        self.initialBootstrapFollowUpTargetOverride = nil
        self.acquireInteractiveChatOpenGateIfNeeded()

        let cachedEndPage = coordinator.cachedEndPageEvent(
            key: key,
            queryId: lease.queryId
        )
        let cachedCommittedPage = coordinator.cachedCommittedPage(
            key: key,
            queryId: lease.queryId
        )
        self.beginInitialBootstrapTracking(
            queryId: lease.queryId,
            timeout: ChatInitialBootstrapPresentationWatchdogPolicy.timeout(
                // Raw <fin> ends the transport deadline. A reopened
                // controller gets a fresh presentation/persistence watchdog
                // while it joins the same account-scoped lease.
                hasCommittedPage: cachedCommittedPage != nil || cachedEndPage != nil,
                remainingTransportTimeout: coordinator.remainingTimeout(
                    key: key,
                    queryId: lease.queryId
                )
            )
        )
        guard self.isInitialBootstrapInFlight,
              self.initialBootstrapQueryId == lease.queryId else {
            // `beginInitialBootstrapTracking` may synchronously consume a
            // retained committed page. Do not reinstall raw-final dispatch,
            // loading presentation or fallback work after that terminal.
            return
        }
        // Initial ownership is installed before the raw-final dispatcher.
        // A final that arrives in this interval remains durable in the
        // account-scoped coordinator and is replayed by the observer above.
        self.registerRemoteHistoryEndPageDispatcher(queryId: lease.queryId)
        self.applyBootstrapLoadingState(self.currentBootstrapLoadingState(), forceRender: true)
        self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
        if let cachedCommittedPage {
            self.consumeInitialBootstrapCommittedPage(cachedCommittedPage)
        } else {
            self.replayCachedInitialBootstrapEndPageIfNeeded(
                key: key,
                queryId: lease.queryId,
                immediateEvent: cachedEndPage
            )
        }

        guard case .start = acquisition else {
            return
        }

        let cancelTransport = { [weak self] in
#if DEBUG || CHAT_PERFORMANCE_LAB
            self?.performanceFixtureArchiveTransportCancellationHandler?(
                lease.queryId
            )
#endif
            if let account = AccountManager.shared.find(for: owner) {
                account.action { user, _ in
                    _ = user.mam.cancelPendingArchiveRequest(queryId: lease.queryId)
                }
            }
            XMPPUIActionManager.shared.cancelPendingArchiveRequest(
                owner: owner,
                queryId: lease.queryId
            )
        }
        let startRequest: (
            _ stream: XMPPStream,
            _ mam: MessageArchiveManager?,
            _ messages: MessageManager?
        ) -> Void = { stream, mam, messages in
            guard coordinator.isActive(key: key, queryId: lease.queryId) else {
                return
            }
            coordinator.preparePersistenceSource(
                key: key,
                queryId: lease.queryId,
                messages: messages,
                archiveManager: mam
            )
            guard coordinator.isActive(key: key, queryId: lease.queryId) else {
                return
            }
            let result = mam?.syncChat(
                stream,
                jid: jid,
                conversationType: conversationType,
                pageSize: pageSize,
                queryId: lease.queryId,
                // The lease remains keyed by the semantic saved target while
                // transport repairs the concrete gap that makes its first
                // frame unsafe. This preserves single-flight deduplication.
                target: requestedTransportTarget,
                callback: nil,
                requestCallbacks: .none
            ) ?? .noop
            coordinator.resolveStart(
                key: key,
                queryId: lease.queryId,
                result: result,
                messages: messages,
                archiveManager: mam,
                cancelTransport: cancelTransport
            )
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        let performanceRequestDescriptor:
            ChatPerformanceFixtureArchiveRequestDescriptor? = {
                guard conversationType == .regular else { return nil }
                let requestPlan = MessageArchiveManager
                    .regularBootstrapRequestPlan(
                        jid: jid,
                        pageSize: pageSize,
                        target: requestedTransportTarget
                    )
                let requestSource = self.pendingOpenMessageRequest?.source
                let semanticRouteClass:
                    ChatPerformanceFixtureArchiveSemanticRouteClass
                switch requestedTransportTarget {
                case .latest:
                    semanticRouteClass = .latest
                case .firstUnread:
                    semanticRouteClass = .unreadBoundary
                case .savedPosition:
                    semanticRouteClass = .savedPosition
                case .older:
                    semanticRouteClass = .anchorContext
                case .savedPositionGapRepair:
                    semanticRouteClass = .knownGapRepair
                }
                return ChatPerformanceFixtureArchiveRequestDescriptor.make(
                    plan: requestPlan,
                    leasePurpose: .initialBootstrap,
                    requestSource: requestSource,
                    semanticRouteClass: semanticRouteClass
                )
            }()
        let performanceFixtureTransportRequest =
            ChatPerformanceFixtureArchiveTransportRequest(
                kind: .initialBootstrap,
                queryIds: [lease.queryId],
                descriptorsByQueryId: performanceRequestDescriptor.map {
                    [lease.queryId: $0]
                } ?? [:]
            )
        if let performanceFixtureExecutor =
                self.performanceFixtureArchiveTransportExecutor,
           let performanceFixtureTransport =
                self.performanceFixtureArchiveTransportProvider?(
                    performanceFixtureTransportRequest
                ) {
            performanceFixtureExecutor { [weak self] in
                startRequest(
                    performanceFixtureTransport.stream,
                    performanceFixtureTransport.archiveManager,
                    performanceFixtureTransport.messageManager
                )
                DispatchQueue.main.async {
                    self?.performanceFixtureArchiveTransportDidStartHandler?(
                        performanceFixtureTransportRequest
                    )
                }
            }
            return
        }
#endif

        let account = AccountManager.shared.find(for: owner)
        let enqueuePrimaryTransport: (Account) -> Void = { account in
            account.xmppTaskScheduler.enqueueAccountTask(
                priority: .interactive,
                resource: .mamArchive,
                deduplicationKey: key.schedulerDeduplicationKey(queryId: lease.queryId),
                requiresAuthenticatedStream: true,
                unavailable: {
                    guard coordinator.isActive(
                        key: key,
                        queryId: lease.queryId
                    ) else {
                        return
                    }
                    let event = MessageArchiveRequestFailureEvent(
                        owner: owner,
                        queryId: lease.queryId,
                        streamKind: .primary,
                        reason: .requestStartFailed,
                        errorDescription: showFailureIfUnavailable
                            ? "Primary archive transport unavailable during retry"
                            : "Primary archive transport unavailable",
                        pendingQueryCount: 1
                    )
                    _ = coordinator.recordFailure(
                        key: key,
                        event: event,
                        publishEvent: true
                    )
                }
            ) { user, stream, finish in
                guard coordinator.isActive(key: key, queryId: lease.queryId) else {
                    finish()
                    return
                }
                coordinator.attachSchedulerCompletion(
                    key: key,
                    queryId: lease.queryId,
                    completion: finish
                )
                startRequest(stream, user.mam, user.messages)
            }
        }
        let transport = ChatInitialBootstrapTransportPolicy.resolve(
            hasPrimaryAccount: account != nil,
            primaryStreamReady: account?.sendReadiness.snapshot.canFlushApplicationStanzas == true,
            primaryBootstrapGateActive: account?.syncManager.isBootstrapCriticalSyncInProgress() == true
        )
        if transport == .primaryAccount,
           let account {
            enqueuePrimaryTransport(account)
            return
        }

        XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
            startRequest(stream, session.mam, session.messages)
        } fail: {
            guard coordinator.isActive(key: key, queryId: lease.queryId) else {
                return
            }
            guard let account = AccountManager.shared.find(for: owner) else {
                let event = MessageArchiveRequestFailureEvent(
                    owner: owner,
                    queryId: lease.queryId,
                    streamKind: .uiAction,
                    reason: .requestStartFailed,
                    errorDescription: showFailureIfUnavailable
                        ? "Archive transport unavailable during retry"
                        : "Archive transport unavailable",
                    pendingQueryCount: 1
                )
                _ = coordinator.recordFailure(
                    key: key,
                    event: event,
                    publishEvent: true
                )
                return
            }
            // The UI-action stream can fail while the primary account is
            // still authenticating. Rejoin the same scheduler/wire contract;
            // never send MAM directly on an unready primary stream.
            enqueuePrimaryTransport(account)
        }
    }

    internal func retryInitialBootstrapAfterFailure() {
        if self.preservesBootstrapFailureOverlayUntilRetryCommit {
            // A legacy local recovery is already admitted. A repeated signal
            // may promote its existing remote lease, but it must never start
            // a second local mapper or archive transport.
            self.allowsBootstrapFailureFallback = false
            self.allowsStaleLocalHistoryDuringInitialBootstrap = false
            self.acquireInteractiveChatOpenGateIfNeeded()
            if self.isInitialBootstrapInFlight,
               let queryId = self.initialBootstrapQueryId {
                _ = ChatInitialBootstrapRequestCoordinator.shared.promote(
                    key: self.initialBootstrapRequestKey
                )
                self.initialBootstrapPresentationDeadline = nil
                self.scheduleInitialBootstrapTimeout(
                    queryId: queryId,
                    timeout:
                        ChatInitialBootstrapPresentationWatchdogPolicy
                            .maximumPresentationTimeout
                )
            }
            return
        }
        if case .failedPresentation =
                self.initialLocalFirstFramePhase {
            // Keep internal ownership of the admitted local-frame retry even
            // though archive failure UI is permanently detached. A repeated
            // recovery signal must join this work instead of starting MAM.
            self.preservesBootstrapFailureOverlayUntilRetryCommit = true
            self.initialLocalFirstFramePhase = .idle
            self.initialLocalFirstFramePresentationRetryDescriptor = nil
            self.allowsBootstrapFailureFallback = false
            self.allowsStaleLocalHistoryDuringInitialBootstrap = false
            self.applyBootstrapLoadingState(
                .blockingArchive,
                forceRender: true,
                synchronousSkeletonCommit:
                    self.isPreparingStackedNavigationPresentation
            )
            self.acquireInteractiveChatOpenGateIfNeeded()
            self.retryInitialLocalFirstFramePreparation()
            return
        }
        if self.isInitialBootstrapInFlight,
           let queryId = self.initialBootstrapQueryId {
            self.allowsBootstrapFailureFallback = false
            self.allowsStaleLocalHistoryDuringInitialBootstrap = false
            if !self.preservesBootstrapFailureOverlayUntilRetryCommit {
                self.setBootstrapFailureVisible(false)
            }
            self.applyBootstrapLoadingState(.blockingArchive, forceRender: true)
            self.acquireInteractiveChatOpenGateIfNeeded()
            _ = ChatInitialBootstrapRequestCoordinator.shared.promote(
                key: self.initialBootstrapRequestKey
            )
            self.initialBootstrapPresentationDeadline = nil
            self.scheduleInitialBootstrapTimeout(
                queryId: queryId,
                timeout: ChatInitialBootstrapPresentationWatchdogPolicy.maximumPresentationTimeout
            )
            return
        }
        ChatInitialBootstrapRequestCoordinator.shared.clearTerminal(
            key: self.initialBootstrapRequestKey
        )
        self.hasAttemptedInitialBootstrapBoundaryFollowUp = false
        self.preservesBootstrapFailureOverlayUntilRetryCommit =
            self.appliedBootstrapLoadingState?.showsRetry == true &&
            !self.bootstrapFailureView.isHidden
        self.allowsBootstrapFailureFallback = false
        self.applyBootstrapLoadingState(self.currentBootstrapLoadingState())
        self.requestInitialBootstrapArchive(showFailureIfUnavailable: false)
    }

    internal func handleSyncChatStartResult(
        _ result: MessageArchiveManager.SyncChatStartResult,
        expectedQueryId: String
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.initialBootstrapQueryId == expectedQueryId,
                  self.isInitialBootstrapInFlight else {
                return
            }
            switch result {
            case .bootstrapStarted(let queryId):
                guard queryId == expectedQueryId,
                      ChatInitialBootstrapRequestCoordinator.shared.isActive(
                        key: self.initialBootstrapRequestKey,
                        queryId: queryId
                      ) else {
                    return
                }
                self.applyBootstrapLoadingState(self.currentBootstrapLoadingState(), forceRender: true)
                self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
            case .gapRepairOnly, .noop:
                self.cancelInitialBootstrapAutomaticRetry(
                    resetFailureCount: true
                )
                self.resetInitialBootstrapTracking()
                _ = self.revealStaleLocalHistoryIfNeeded()
            }
        }
    }

    private func replayCachedInitialBootstrapEndPageIfNeeded(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        immediateEvent: MessageArchiveEndPageEvent?
    ) {
        if let immediateEvent {
            self.didReceiveEndPage(
                queryId: immediateEvent.queryId,
                state: immediateEvent.state,
                first: immediateEvent.first,
                last: immediateEvent.last,
                count: immediateEvent.count
            )
        }

        // Dispatch once more to close the interval in which the one-shot
        // dispatcher has removed its old handlers but has not yet run the
        // coordinator callback that stores the final page.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.initialBootstrapQueryId == queryId,
                  !self.completedRemoteHistoryEndPageQueryIds.contains(queryId),
                  let event = ChatInitialBootstrapRequestCoordinator.shared.cachedEndPageEvent(
                    key: key,
                    queryId: queryId
                  ) else {
                return
            }
            self.didReceiveEndPage(
                queryId: event.queryId,
                state: event.state,
                first: event.first,
                last: event.last,
                count: event.count
            )
        }
    }

    private final func updateContentByLastChatInstance(_ item: LastChatsStorageItem) {
//        self.lastReadMessageId = item.lastReadId
        let state = self.bootstrapViewState(chatInstance: item)
        let shouldShowSkeleton = state == .skeleton
        if self.showSkeletonObserver.value != shouldShowSkeleton {
            self.applyBootstrapViewState(
                state,
                synchronousSkeletonCommit: shouldShowSkeleton
            )
        } else if !shouldShowSkeleton {
            self.reloadInitialWindowAfterBootstrapIfNeeded()
        }
        if shouldShowSkeleton {
            self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
            if !self.isInitialBootstrapInFlight {
                // The snapshot boundary may have appeared after the initial
                // navigation decision. Re-enter the account single-flight on
                // the next main turn; it will either join or acquire exactly
                // one archive transaction.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isInitialBootstrapInFlight,
                          self.currentBootstrapLoadingState().showsSkeleton else {
                        return
                    }
                    self.requestInitialBootstrapArchive()
                }
            }
        }
        _ = self.completeInitialBootstrapIfNeeded()
        self.rebuildUnreadMentionItems()
        self.refreshUnreadMentionsNavigatorState(
            animated: self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: true)
        )
        let id = self.opponentSender.id
        if !(item.rosterItem?.isInvalidated ?? false) {
            self.opponentSender = Sender(
                id: id,
                displayName: item.rosterItem?.displayName ?? item.jid
            )
        }
//        self.contactUsename = self.opponentSender.displayName
        self.titleLabel.attributedText = self.updateTitle()
        self.setStatusText(self.connectionAwareStatusText(fallbackStatus: self.contactStatus ?? " "))
        
        switch ChatMarkersManager.BurnMessagesTimerValues(rawValue: Int(item.afterburnInterval)) {
            case .off, .none:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "stopwatch"), for: .normal)
            case .s5:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.circle"), for: .normal)
            case .s10:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.circle"), for: .normal)
            case .s15:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.circle"), for: .normal)
            case .s30:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "30.circle"), for: .normal)
            case .m1:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "1.square"), for: .normal)
            case .m5:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.square"), for: .normal)
            case .m10:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.square"), for: .normal)
            case .m15:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.square"), for: .normal)
            
        }
    }
    
    internal final func groupSubscribtions() throws {
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.getDefaultPermissions(stream, groupchat: self.jid)
            session.groupchat?.requestMyPermissions(stream, groupchat: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.getDefaultPermissions(stream, groupchat: self.jid)
                user.groupchats.requestMyPermissions(stream, groupchat: self.jid)
            }
        }

        let realm = try WRealm.safe()
        let mentionUsers = self.mentionUsersResults(in: realm)
        Observable
            .collection(from: mentionUsers)
            .debounce(.milliseconds(20), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { results in
                if !results.isEmpty {
                    self.hasRequestedMentionUsersRefresh = false
                }
                self.xabberInputView.refreshMentionSuggestions()
            })
            .disposed(by: bag)

//        let realm = try WRealm.safe()
//        
//        self.showMyNickname = realm
//            .objects(GroupchatUserStorageItem.self)
//            .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
//            .first?
//            .nickname == AccountManager.shared.find(for: self.owner)?.username
//        Observable
//            .collection(from: realm
//                .objects(GroupchatInvitesStorageItem.self)
//                .filter("owner == %@ AND groupchat == %@ AND isProcessed == false", self.owner, self.jid))
//            .subscribe { (results) in
//                if let item = results.first {
//                    self.didReceiveInvite(item.primary)
//                }
//            } onError: { (error) in
//                DDLogDebug("ChatViewController: \(#function). Invite error \(error.localizedDescription)")
//            } onCompleted: {
//                DDLogDebug("ChatViewController: \(#function). Invite completed")
//            } onDisposed: {
//                DDLogDebug("ChatViewController: \(#function). Invite disposed")
//            }
//            .disposed(by: bag)
//        
//        Observable
//            .collection(from: realm
//                                .objects(GroupChatStorageItem.self)
//                                .filter("jid == %@ AND owner == %@", jid, owner))
//            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
//            .subscribe(onNext: { (results) in
//                
//                let nickname = self.opponentSender.displayName
//                if let item = results.first {
//                    if item.descr != self.groupchatDescr {
//                        self.groupchatDescr = item.descr
//                        do {
//                            let realm = try WRealm.safe()
//                            if let initialMessageInstance = realm.object(
//                                ofType: MessageStorageItem.self,
//                                forPrimaryKey: MessageStorageItem.genPrimary(
//                                    messageId: MessageStorageItem.messageIdForInitial(jid: self.jid, conversationType: self.conversationType),
//                                    owner: self.owner
//                                )
//                            ) {
//                                if initialMessageInstance.isDeleted {
//                                    try realm.write {
//                                        if initialMessageInstance.isInvalidated { return }
//                                        initialMessageInstance.owner = self.owner
//                                    }
//                                }
//                            }
//                        } catch {
//                            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//                        }
//                    }
//                    
//                    if item.isDeleted {
//                        if let value = self.isInitiallyDeletedGroup,
//                            value == false {
//                            self.navigationController?.popToRootViewController(animated: true)
//                        }
//                    } else {
//                        self.titleLabel.text = nickname
//                        let statusStr = self.isInviteViewControllerShowed ? (item.privacy == .incognito ? "Incognito group".localizeString(id: "intro_incognito_group", arguments: []) : "Public group".localizeString(id: "intro_public_group", arguments: [])) : item.statusString
//                        if self.statusLabel.text == " " {
//                            self.statusLabel.text = statusStr
//                        }
//                        
//                        self.statusTextObserver.accept(statusStr)
//                        
//                        self.contactStatus = self.isInviteViewControllerShowed ? (item.privacy == .incognito ?"Incognito group".localizeString(id: "intro_incognito_group", arguments: []) : "Public group".localizeString(id: "intro_public_group", arguments: [])) : item.statusString
//                    }
//                    self.isInitiallyDeletedGroup = item.isDeleted
//                } else {
//                    let status = "Unknown".localizeString(id: "unknown", arguments: [])
////                            if self.entity != .incognitoChat || self.entity != .groupchat {
////                                self.entity = .groupchat
////                            }
//                    if ![.incognitoChat, .groupchat].contains(self.entity) {
//                        self.entity = .groupchat
//                    }
//                    
//                    self.titleLabel.text = nickname
//                    self.statusTextObserver.accept(status)
//                    self.contactStatus = status
//                }
//                self.titleLabel.layoutIfNeeded()
//            })
//            .disposed(by: bag)


//        Observable
//            .collection(from: realm
//                .objects(GroupchatUserStorageItem.self)
//                .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp()))
//            .subscribe(onNext: { (results) in
//                if let item = results.first {
//                    if item.nickname != (AccountManager.shared.find(for: self.owner)?.username ?? "") {
//                        if !self.showMyNickname {
//                            self.showMyNickname = true
//                            UIView.performWithoutAnimation {
//                                self.messagesCollectionView.reloadData()
//                            }
//                        }
//                    } else {
//                        if self.showMyNickname {
//                            self.showMyNickname = false
//                            UIView.performWithoutAnimation {
//                                self.messagesCollectionView.reloadData()
//                            }
//                        }
//                    }
//                }
//            })
//            .disposed(by: bag)
    }
}
