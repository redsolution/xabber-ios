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
        _ = primaryBootstrapGateActive
        return hasPrimaryAccount && primaryStreamReady
            ? .primaryAccount
            : .uiAction
    }
}

enum ChatInitialBootstrapPresentationWatchdogPolicy {
    static func timeout(
        hasCommittedPage: Bool,
        remainingTransportTimeout: TimeInterval,
        presentationTimeout: TimeInterval = ChatInteractiveRemoteArchiveTimeoutPolicy.timeout
    ) -> TimeInterval {
        hasCommittedPage
            ? max(0, presentationTimeout)
            : max(0, remainingTransportTimeout)
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
}

enum ConversationArchiveLoadPurpose: String, Equatable {
    case interactiveBootstrap
    case snapshotRepair
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
    }

    struct CommittedPage: Equatable {
        let event: MessageArchiveEndPageEvent
        let completion: ChatRemoteHistoryCompletionResult
        let boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint?

        init(
            event: MessageArchiveEndPageEvent,
            completion: ChatRemoteHistoryCompletionResult,
            boundaryFingerprint: MessageArchiveManager.ConversationArchiveBoundaryFingerprint? = nil
        ) {
            self.event = event
            self.completion = completion
            self.boundaryFingerprint = boundaryFingerprint
        }
    }

    enum Acquisition {
        case start(Lease)
        case joined(Lease)
        case terminal(MessageArchiveRequestFailureEvent)
    }

    typealias StartObserver = (
        String,
        MessageArchiveManager.SyncChatStartResult,
        MessageManager?
    ) -> Void
    typealias ReadinessObserver = (ConversationArchiveReadiness?) -> Void

    static let shared = ChatInitialBootstrapRequestCoordinator()

    private struct Attempt {
        let lease: Lease
        let enqueuedAt: Date
        let persistenceTimeout: TimeInterval
        var phase: ConversationArchiveLoadPhase
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
        var hasDurableCoverage: Bool
        var confirmsEmptyConversation: Bool
        var schedulerCompletion: (() -> Void)?
        var hasWireTerminal: Bool
        var didRegisterPersistenceSource: Bool
        var isPersistenceCommitClaimed: Bool
    }

    private struct Cleanup {
        let owner: String
        let queryId: String
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

    private let lock = NSLock()
    private let now: () -> Date
    private let automaticallySchedulesTimeouts: Bool
    private var attemptsByKey: [ChatInitialBootstrapRequestKey: Attempt] = [:]
    private var terminalFailuresByKey: [ChatInitialBootstrapRequestKey: MessageArchiveRequestFailureEvent] = [:]
    private var terminalFailureOrder: [ChatInitialBootstrapRequestKey] = []
    private var finalReceivedOrder: [ChatInitialBootstrapRequestKey] = []
    private var cancelledTransportIdentities: Set<AttemptIdentity> = []
    private var cancelledTransportIdentityOrder: [AttemptIdentity] = []
    private var readinessObserversByKey: [
        ChatInitialBootstrapRequestKey: [UUID: ReadinessObserver]
    ] = [:]

    /// Test seam for the timeout-vs-commit handoff. It runs only after the
    /// coordinator atomically owns the persistence terminal.
    var persistenceCommitClaimObserver: ((String) -> Void)?

    init(
        now: @escaping () -> Date = Date.init,
        automaticallySchedulesTimeouts: Bool = true
    ) {
        self.now = now
        self.automaticallySchedulesTimeouts = automaticallySchedulesTimeouts
    }

    func acquire(
        key: ChatInitialBootstrapRequestKey,
        proposedQueryId: String,
        timeout: TimeInterval,
        purpose: ConversationArchiveLoadPurpose = .interactiveBootstrap,
        persistenceTimeout: TimeInterval? = nil,
        observer: @escaping StartObserver
    ) -> Acquisition {
        expireAttemptIfDue(key: key)

        var immediateStart: (
            MessageArchiveManager.SyncChatStartResult,
            MessageManager?
        )?
        lock.lock()
        if let terminalFailure = terminalFailuresByKey[key] {
            lock.unlock()
            return .terminal(terminalFailure)
        }
        if var attempt = attemptsByKey[key] {
            if let startResult = attempt.startResult {
                immediateStart = (startResult, attempt.messages)
            } else {
                attempt.observers.append(observer)
                attemptsByKey[key] = attempt
            }
            let lease = attempt.lease
            lock.unlock()
            if let immediateStart {
                observer(lease.queryId, immediateStart.0, immediateStart.1)
            }
            return .joined(lease)
        }

        let lease = Lease(
            queryId: proposedQueryId,
            deadline: now().addingTimeInterval(max(0, timeout)),
            purpose: purpose
        )
        attemptsByKey[key] = Attempt(
            lease: lease,
            enqueuedAt: now(),
            persistenceTimeout: max(0, persistenceTimeout ?? timeout),
            phase: .queued,
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
            hasDurableCoverage: false,
            confirmsEmptyConversation: false,
            schedulerCompletion: nil,
            hasWireTerminal: false,
            didRegisterPersistenceSource: false,
            isPersistenceCommitClaimed: false
        )
        lock.unlock()

        installLifetimeHandlers(key: key, lease: lease)
        notifyReadinessObservers(key: key)
        ChatArchiveDebugTrace.log("archiveLoadEnqueue", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.queued.rawValue),
            ("waitMs", 0),
            ("hasPredecessor", false)
        ])
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
        observer: @escaping StartObserver
    ) -> Acquisition {
        acquire(
            key: key,
            proposedQueryId: proposedQueryId,
            timeout: timeout,
            purpose: purpose,
            persistenceTimeout: persistenceTimeout,
            observer: observer
        )
    }

    func readiness(for key: ChatInitialBootstrapRequestKey) -> ConversationArchiveReadiness? {
        lock.lock()
        let value = readinessLocked(for: key)
        lock.unlock()
        return value
    }

    @discardableResult
    func observe(
        key: ChatInitialBootstrapRequestKey,
        observer: @escaping ReadinessObserver
    ) -> ObservationToken {
        let token = ObservationToken()
        lock.lock()
        readinessObserversByKey[key, default: [:]][token.id] = observer
        let value = readinessLocked(for: key)
        lock.unlock()
        observer(value)
        return token
    }

    /// Joining an existing interactive request is itself the promotion: the
    /// account scheduler upgrades a queued task with the same deduplication
    /// key. This method provides the explicit lease API used by callers that
    /// already hold the transaction key.
    @discardableResult
    func promote(key: ChatInitialBootstrapRequestKey) -> Bool {
        lock.lock()
        let queryId = attemptsByKey[key]?.lease.queryId
        lock.unlock()
        if let queryId {
            AccountManager.shared.find(for: key.owner)?.xmppTaskScheduler.promotePendingTask(
                deduplicationKey: key.schedulerDeduplicationKey(queryId: queryId),
                to: .interactive
            )
        }
        return queryId != nil
    }

    /// Controller teardown detaches presentation only. The account-scoped
    /// transport/persistence transaction intentionally remains alive.
    func detach(
        key: ChatInitialBootstrapRequestKey,
        observation token: ObservationToken
    ) {
        lock.lock()
        readinessObserversByKey[key]?[token.id] = nil
        if readinessObserversByKey[key]?.isEmpty == true {
            readinessObserversByKey[key] = nil
        }
        lock.unlock()
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
        var purpose = ConversationArchiveLoadPurpose.interactiveBootstrap
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId {
            purpose = attempt.lease.purpose
            // A very fast raw terminal may be delivered synchronously while
            // the request-start call is still unwinding. Never regress that
            // persistence lease back to transport.
            let acceptsStartResources = attempt.phase == .queued || attempt.phase == .transport
            if acceptsStartResources {
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
        } else {
            let identity = AttemptIdentity(key: key, queryId: queryId)
            if !cancelledTransportIdentities.contains(identity) {
                recordCancelledTransportIdentityLocked(identity)
                shouldCancelLateTransport = true
            }
        }
        lock.unlock()

        notifyReadinessObservers(key: key)

        ChatArchiveDebugTrace.log("archiveLoadStart", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.transport.rawValue),
            ("waitMs", Int(max(0, now().timeIntervalSince(
                attemptsEnqueuedAt(key: key, queryId: queryId) ?? now()
            )) * 1000)),
            ("started", true)
        ])

        if shouldCancelLateTransport {
            cancelTransport()
            return
        }
        if shouldRegisterPersistenceSource,
           let messages {
            ChatRemoteHistoryCompletionCoordinator.registerPersistenceSource(
                messages,
                owner: key.owner,
                queryId: queryId
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
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId {
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
            queryId: queryId
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
        let cleanup: Cleanup?
        lock.lock()
        if let attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId {
            attemptsByKey.removeValue(forKey: key)
            finalReceivedOrder.removeAll { $0 == key }
            recordCancelledTransportIdentityLocked(
                AttemptIdentity(key: key, queryId: queryId)
            )
            cleanup = makeCleanup(key: key, attempt: attempt, includesTransportCancellation: false)
        } else {
            cleanup = nil
        }
        lock.unlock()
        notifyReadinessObservers(key: key)
        performCleanup(
            cleanup,
            unregisterPersistenceSource: unregisterPersistenceSource
        )
        return cleanup != nil
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
                // not a reusable receipt. Removing it lets the single
                // interactive follow-up acquire a fresh query immediately.
                attemptsByKey.removeValue(forKey: key)
                finalReceivedOrder.removeAll { $0 == key }
                didRemoveNonDurableReceipt = true
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
        let cleanup: Cleanup?
        lock.lock()
        if let attempt = attemptsByKey[key],
           attempt.phase == .committed,
           attempt.committedPage != nil,
           queryId == nil || attempt.lease.queryId == queryId {
            attemptsByKey.removeValue(forKey: key)
            finalReceivedOrder.removeAll { $0 == key }
            cleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
        } else {
            cleanup = nil
        }
        lock.unlock()

        guard let cleanup else {
            return false
        }
        notifyReadinessObservers(key: key)
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
        var purpose = ConversationArchiveLoadPurpose.interactiveBootstrap
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
            purpose = attempt.lease.purpose
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
        ChatArchiveDebugTrace.log("archiveLoadFail", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.failed.rawValue),
            ("pendingQueryCount", event.pendingQueryCount),
            ("hadWireTerminal", cleanup.endDispatcherToken == nil)
        ])
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
        resultCount: Int = 0
    ) {
        let normalizedResultCount = max(0, resultCount)
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
                    flushedMessageCount: 0,
                    persistenceSummary: MessageManager.ArchivePersistenceSummary()
                ),
                boundaryFingerprint: boundaryFingerprint
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
        persistenceCommitClaimObserver = nil
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
        var purpose = ConversationArchiveLoadPurpose.interactiveBootstrap
        var didRecord = false
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == event.queryId,
           attempt.endPageEvent == nil {
            purpose = attempt.lease.purpose
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
        ChatArchiveDebugTrace.log("archiveLoadWireFin", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.persistence.rawValue),
            ("resultCount", event.count),
            ("hasPersistenceSource", messages != nil)
        ])
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
            let commitResult = archiveManager?.commitAfterPersistence(
                queryId: event.queryId,
                persistenceSummary: completion.persistenceSummary
            ) ?? .missingDescriptor
            let boundaryFingerprint = archiveManager?.consumeCommittedArchiveBoundaryFingerprint(
                queryId: event.queryId
            )
            switch commitResult {
            case .committed:
                let hasDurableCoverage = hasPersistenceConfirmedReadiness(for: key)
                recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint: boundaryFingerprint
                    ),
                    hasDurableCoverage: hasDurableCoverage
                )
            case .committedNeedsFollowUpRepair:
                recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint: boundaryFingerprint
                    ),
                    hasDurableCoverage: false
                )
            case .missingDescriptor where archiveManager == nil:
                recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(event: event, completion: completion)
                )
            case .missingDescriptor:
                recordPersistenceFailure(
                    key: key,
                    queryId: event.queryId,
                    description: "Deferred archive commit descriptor is unavailable"
                )
            case .rejected(let rejection):
                recordPersistenceFailure(
                    key: key,
                    queryId: event.queryId,
                    description: "Deferred archive commit rejected: \(rejection)"
                )
            }
            return
        }

        ChatArchiveDebugTrace.log("archiveLoadPersistenceStart", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.persistence.rawValue),
            ("resultCount", event.count)
        ])

        ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync(
            owner: key.owner,
            queryId: event.queryId,
            state: event.state,
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
            let boundaryFingerprint = archiveManager?.consumeCommittedArchiveBoundaryFingerprint(
                queryId: event.queryId
            )
            switch commitResult {
            case .committed:
                let hasDurableCoverage = self.hasPersistenceConfirmedReadiness(for: key)
                self.recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint: boundaryFingerprint
                    ),
                    hasDurableCoverage: hasDurableCoverage
                )
            case .committedNeedsFollowUpRepair:
                self.recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(
                        event: event,
                        completion: completion,
                        boundaryFingerprint: boundaryFingerprint
                    ),
                    hasDurableCoverage: false
                )
            case .missingDescriptor where archiveManager == nil:
                // Unit/legacy sources that never opted into deferred MAM
                // coverage still use the coordinator's persistence barrier.
                self.recordCommittedPage(
                    key: key,
                    queryId: event.queryId,
                    page: CommittedPage(event: event, completion: completion)
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
        var purpose = ConversationArchiveLoadPurpose.interactiveBootstrap
        lock.lock()
        if let attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.committedPage == nil,
           !(reason == .timeout && attempt.isPersistenceCommitClaimed) {
            purpose = attempt.lease.purpose
            archiveManager = attempt.archiveManager
            attemptsByKey.removeValue(forKey: key)
            finalReceivedOrder.removeAll { $0 == key }
            terminalFailuresByKey[key] = event
            recordTerminalKeyLocked(key)
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
        ChatArchiveDebugTrace.log("archiveLoadFail", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.failed.rawValue),
            ("pendingQueryCount", 0),
            ("persistenceFailure", true)
        ])
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
        var purpose = ConversationArchiveLoadPurpose.interactiveBootstrap
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == event.queryId,
           attempt.phase != .committed,
           attempt.phase != .failed {
            purpose = attempt.lease.purpose
            attempt.phase = .persistence
            schedulerCompletion = attempt.schedulerCompletion
            transportTimeout = attempt.timeoutWorkItem
            attempt.schedulerCompletion = nil
            attempt.hasWireTerminal = true
            attempt.timeoutWorkItem = nil
            attempt.failurePreparationToken = nil
            attemptsByKey[key] = attempt
            didTransition = true
        }
        lock.unlock()

        guard didTransition else { return }
        transportTimeout?.cancel()
        schedulerCompletion?()
        notifyReadinessObservers(key: key)
        installPersistenceTimeout(key: key, queryId: event.queryId)
        ChatArchiveDebugTrace.log("archiveLoadWireFail", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.persistence.rawValue),
            ("pendingQueryCount", event.pendingQueryCount)
        ])
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
        var purpose = ConversationArchiveLoadPurpose.interactiveBootstrap
        lock.lock()
        if var attempt = attemptsByKey[key],
           attempt.lease.queryId == queryId,
           attempt.committedPage == nil {
            purpose = attempt.lease.purpose
            committedCleanup = makeCleanup(
                key: key,
                attempt: attempt,
                includesTransportCancellation: false
            )
            attempt.committedPage = page
            attempt.phase = .committed
            attempt.hasDurableCoverage = hasDurableCoverage
            attempt.confirmsEmptyConversation = hasDurableCoverage && page.event.count == 0
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
        ChatArchiveDebugTrace.log("archiveLoadCommit", [
            ("purpose", purpose.rawValue),
            ("phase", ConversationArchiveLoadPhase.committed.rawValue),
            ("persistedRows", page.completion.persistenceSummary.persistedRows),
            ("processedRows", page.completion.persistenceSummary.processedRows),
            ("resultCount", page.event.count),
            ("failedRows", page.completion.persistenceSummary.failed)
        ])
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

    private func attemptsEnqueuedAt(
        key: ChatInitialBootstrapRequestKey,
        queryId: String
    ) -> Date? {
        lock.lock()
        let date = attemptsByKey[key]?.lease.queryId == queryId
            ? attemptsByKey[key]?.enqueuedAt
            : nil
        lock.unlock()
        return date
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

    private func hasPersistenceConfirmedReadiness(
        for key: ChatInitialBootstrapRequestKey
    ) -> Bool {
        guard let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: key.conversationTypeRawValue
        ) else {
            return false
        }
        do {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: key.jid,
                    owner: key.owner,
                    conversationType: conversationType
                )
            )
            return chat?.isInitialArchiveLoaded == true && chat?.isSynced == true
        } catch {
            DDLogDebug("ChatInitialBootstrapRequestCoordinator: \(#function). \(error.localizedDescription)")
            return false
        }
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
        ChatInitialBootstrapRequestKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
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
    
    internal func subscribe() throws {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        self.bag = DisposeBag()
        let realm = try WRealm.safe()
        self.configureDataset()
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
        let initialBootstrapViewState = self.bootstrapViewState(chatInstance: initialChatInstance)
        self.applyBootstrapViewState(
            initialBootstrapViewState,
            forceRender: self.datasource.isEmpty || !self.isShowingBootstrapPlaceholder
        )
        if initialBootstrapViewState == .skeleton {
            self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
        }
        self.requestInitialBootstrapArchive()
        
        if self.conversationType == .group {
            do {
                let realm = try WRealm.safe()
                let myGroupUser = realm.objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
                Observable
                    .collection(from: myGroupUser, synchronousStart: true)
                    .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
                    .observe(on: MainScheduler.asyncInstance)
                    .subscribe(onNext: { _ in
                        _ = self.timelineSession?.refreshUnreadMetadata()
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
        
        self.shouldShowInitialMessage
            .asObservable()
            .observe(on: MainScheduler.asyncInstance)
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
        }.disposed(by: bag)

        
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
    
    internal func requestInitialBootstrapArchive(showFailureIfUnavailable: Bool = false) {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = self.initialBootstrapRequestKey
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
        guard requiresArchiveConfirmationNow || hasUncommittedLease else {
            // Never discard an account-scoped lease here: one may have been
            // installed after the readiness read, and active work always wins
            // over legacy Realm flags. A later readiness/Realm notification
            // will join it or request the newly required boundary.
            coordinator.clearTerminal(key: key)
            self.performOnMain {
                self.hasAttemptedInitialBootstrapBoundaryFollowUp = false
                self.resetInitialBootstrapTracking()
                _ = self.revealStaleLocalHistoryIfNeeded()
                self.applyBootstrapLoadingState(
                    self.currentBootstrapLoadingState(),
                    forceRender: true
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
            timeout: ChatInteractiveRemoteArchiveTimeoutPolicy.timeout
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

        self.registerRemoteHistoryEndPageDispatcher(queryId: lease.queryId)
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

        let cancelTransport = {
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

        let account = AccountManager.shared.find(for: owner)
        let transport = ChatInitialBootstrapTransportPolicy.resolve(
            hasPrimaryAccount: account != nil,
            primaryStreamReady: account?.sendReadiness.snapshot.canFlushApplicationStanzas == true,
            primaryBootstrapGateActive: account?.syncManager.isBootstrapCriticalSyncInProgress() == true
        )
        if transport == .primaryAccount,
           let account {
            account.xmppTaskScheduler.enqueueAccountTask(
                priority: .interactive,
                resource: .mamArchive,
                deduplicationKey: key.schedulerDeduplicationKey(queryId: lease.queryId),
                requiresAuthenticatedStream: true
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
            account.action { user, stream in
                startRequest(stream, user.mam, user.messages)
            }
        }
    }

    internal func retryInitialBootstrapAfterFailure() {
        guard !self.isInitialBootstrapInFlight else { return }
        ChatInitialBootstrapRequestCoordinator.shared.clearTerminal(
            key: self.initialBootstrapRequestKey
        )
        self.hasAttemptedInitialBootstrapBoundaryFollowUp = false
        self.allowsBootstrapFailureFallback = false
        self.setBootstrapFailureVisible(false)
        self.applyBootstrapLoadingState(self.currentBootstrapLoadingState())
        self.requestInitialBootstrapArchive(showFailureIfUnavailable: true)
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
            self.applyBootstrapViewState(state)
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
