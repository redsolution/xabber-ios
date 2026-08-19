import Foundation
import XMPPFramework

/// Bridges the callback-based MAM implementation to the archive engine's
/// immutable async receipt. The scheduler slot remains owned until both raw
/// `<fin/>` and query-scoped Realm persistence have reached a terminal.
final class MessageArchiveTransportAdapter: ArchiveTransport, @unchecked Sendable {
    private weak var account: Account?
    private let materializationResolver: ArchiveMessageMaterializationResolving

    init(
        account: Account,
        materializationResolver: ArchiveMessageMaterializationResolving
    ) {
        self.account = account
        self.materializationResolver = materializationResolver
    }

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        guard let account else {
            throw ArchiveTransportError.disconnected
        }
        let continuationBox = ArchiveTransportContinuationBox()
        return try await withCheckedThrowingContinuation { continuation in
            continuationBox.install(continuation)
            account.xmppTaskScheduler.enqueueAccountTask(
                priority: Self.schedulerPriority(priority),
                resource: .mamArchive,
                deduplicationKey: Self.deduplicationKey(for: request),
                unavailable: {
                    continuationBox.resume(throwing: ArchiveTransportError.disconnected)
                }
            ) { [weak self] user, stream, finishSchedulerSlot in
                guard let self else {
                    finishSchedulerSlot()
                    continuationBox.resume(throwing: ArchiveTransportError.disconnected)
                    return
                }
                let transaction = ArchiveTransportTransaction(
                    request: request,
                    account: user,
                    materializationResolver: self.materializationResolver,
                    continuationBox: continuationBox,
                    finishSchedulerSlot: finishSchedulerSlot
                )
                transaction.start(on: stream)
            }
        }
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        to priority: ArchiveIntentPriority
    ) async {
        account?.xmppTaskScheduler.promotePendingTask(
            deduplicationKey: Self.deduplicationKey(for: descriptor),
            to: Self.schedulerPriority(priority)
        )
    }

    private static func schedulerPriority(
        _ priority: ArchiveIntentPriority
    ) -> AccountXMPPTaskScheduler.Priority {
        switch priority {
        case .visibleIntegrity, .target:
            return .interactive
        case .searchCurrentPage, .nearEdgePrefetch:
            return .foreground
        case .snapshotRepair:
            return .background
        case .idleBackfill:
            return .idle
        }
    }

    private static func deduplicationKey(
        for request: ArchiveTransportRequest
    ) -> String {
        deduplicationKey(
            for: ArchiveIntentDescriptor(
                conversation: request.conversation,
                locator: request.locator,
                contextBefore: request.contextBefore,
                contextAfter: request.contextAfter
            )
        )
    }

    private static func deduplicationKey(
        for descriptor: ArchiveIntentDescriptor
    ) -> String {
        let key = descriptor.conversation
        return [
            "archive-engine",
            key.owner,
            key.jid,
            key.conversationTypeRaw,
            String(describing: descriptor.locator),
            String(descriptor.contextBefore),
            String(descriptor.contextAfter),
        ].joined(separator: "\u{1F}")
    }
}

private final class ArchiveTransportContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ArchiveTransportReceipt, Error>?
    private var pendingResult: Result<ArchiveTransportReceipt, Error>?

    func install(_ continuation: CheckedContinuation<ArchiveTransportReceipt, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning receipt: ArchiveTransportReceipt) {
        resume(with: .success(receipt))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<ArchiveTransportReceipt, Error>) {
        lock.lock()
        guard let continuation else {
            guard pendingResult == nil else {
                lock.unlock()
                return
            }
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class ArchiveTransportTransaction: @unchecked Sendable {
    private let request: ArchiveTransportRequest
    private let account: Account
    private let materializationResolver: ArchiveMessageMaterializationResolving
    private let continuationBox: ArchiveTransportContinuationBox
    private let finishSchedulerSlot: () -> Void
    private let lock = NSLock()
    private let persistenceGate = ArchivePersistenceTerminalGate(timeout: 30)
    private var didStartTerminal = false
    private var didFinish = false
    private var failureToken: MessageArchiveRequestFailureDispatcher.Token?
    private var preparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token?

    init(
        request: ArchiveTransportRequest,
        account: Account,
        materializationResolver: ArchiveMessageMaterializationResolving,
        continuationBox: ArchiveTransportContinuationBox,
        finishSchedulerSlot: @escaping () -> Void
    ) {
        self.request = request
        self.account = account
        self.materializationResolver = materializationResolver
        self.continuationBox = continuationBox
        self.finishSchedulerSlot = finishSchedulerSlot
    }

    func start(on stream: XMPPStream) {
        guard stream.isAuthenticated,
              account.sendReadiness.snapshot.canFlushApplicationStanzas else {
            finish(.failure(ArchiveTransportError.disconnected))
            return
        }

        account.messages.beginArchiveQueryBatch(
            queryId: request.queryID,
            priority: Self.persistencePriority(request)
        )
        ArchiveEngineObservability.event(
            .transport,
            value: request.pageSize
        )
        preparationToken = MessageArchiveRequestFailurePreparationDispatcher.register(
            owner: request.conversation.owner,
            queryId: request.queryID
        ) { [weak self] event, acknowledgement in
            self?.handleFailure(event, acknowledgement: acknowledgement)
        }
        failureToken = MessageArchiveRequestFailureDispatcher.register(
            owner: request.conversation.owner,
            queryId: request.queryID,
            delivery: .synchronous
        ) { [weak self] event in
            self?.handleFailure(event, acknowledgement: nil)
        }

        account.mam.requestArchive(
            stream,
            jid: request.conversation.jid,
            isContinues: false,
            conversationType: request.conversation.conversationType,
            purpose: purpose,
            queryId: request.queryID,
            ids: ids,
            flipPage: true,
            beforeId: beforeID,
            afterId: afterID,
            start: startDate,
            end: endDate,
            nextPage: nextPage,
            prevPage: previousPage,
            max: request.pageSize,
            withCounter: false,
            coverageUpdateKind: coverageUpdateKind,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            deferCoverageCommitUntilConsumerProof: true,
            requestCallbacks: MessageArchiveManager.RequestCallbacks(
                onEndPage: { [weak self] queryID, state, first, last, _ in
                    self?.handleFinal(
                        queryID: queryID,
                        state: state,
                        first: first,
                        last: last
                    )
                },
                onFailure: { [weak self] event in
                    self?.handleFailure(event, acknowledgement: nil)
                }
            )
        )
    }

    private func handleFinal(
        queryID: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String
    ) {
        guard beginTerminal() else { return }
        guard queryID == request.queryID,
              let accounting = account.mam.archiveTransportAccountingSnapshot(
                queryId: request.queryID
              ) else {
            finish(.failure(ArchiveTransportError.protocolViolation))
            return
        }
        ArchiveEngineObservability.event(
            .final,
            value: accounting.deliveredResultCount,
            auxiliary: state.rawComplete ? 1 : 0
        )

        guard persistenceGate.arm(onTimeout: { [weak self] in
            guard let self else { return }
            self.account.messages.releaseArchiveQueryBatchIngressExpectation(
                queryId: self.request.queryID
            )
            self.finish(.failure(ArchiveTransportError.timeout))
        }) else { return }

        let expected = account.mam.expectedPersistenceResultCount(
            queryId: request.queryID
        )
        account.messages.finishArchiveQueryBatchAsync(
            queryId: request.queryID,
            priority: Self.persistencePriority(request),
            expectedReceivedCount: expected
        ) { [weak self] summary in
            guard let self,
                  self.persistenceGate.claimPersistenceTerminal() else {
                return
            }
            Task {
                do {
                    ArchiveEngineObservability.event(
                        .persistence,
                        value: summary.persistedRows,
                        auxiliary: summary.failed + summary.skipped
                    )
                    let primaryIDs = try await self.materializationResolver
                        .materializedMessagePrimaryIDs(
                            conversation: self.request.conversation,
                            archiveIDs: accounting.resultArchiveIDs
                        )
                    let receipt = ArchiveTransportReceipt(
                        queryID: queryID,
                        connectionGeneration: self.request.connectionGeneration,
                        resultArchiveIDs: accounting.resultArchiveIDs,
                        messagePrimaryIDs: primaryIDs,
                        first: first,
                        last: last,
                        complete: state.rawComplete,
                        cheapPageCount: state.serverResultCount ?? accounting.deliveredResultCount,
                        deliveredResultCount: accounting.deliveredResultCount,
                        persistedResultCount: summary.persistedRows,
                        intentionallyConsumedResultCount: accounting.intentionallyConsumedResultCount,
                        failedPersistenceCount: summary.failed + summary.skipped,
                        finalReceived: true
                    )
                    self.finish(.success(receipt))
                } catch {
                    self.finish(.failure(ArchiveTransportError.storage))
                }
            }
        }
    }

    private func handleFailure(
        _ event: MessageArchiveRequestFailureEvent,
        acknowledgement: (() -> Void)?
    ) {
        guard event.queryId == request.queryID else {
            acknowledgement?()
            return
        }
        guard beginTerminal() else {
            acknowledgement?()
            return
        }
        guard persistenceGate.arm(onTimeout: { [weak self] in
            acknowledgement?()
            self?.finish(.failure(Self.transportError(for: event)))
        }) else {
            acknowledgement?()
            return
        }
        account.messages.releaseArchiveQueryBatchIngressExpectation(
            queryId: request.queryID
        )
        account.messages.finishArchiveQueryBatchAsync(
            queryId: request.queryID,
            priority: Self.persistencePriority(request),
            expectedReceivedCount: nil
        ) { [weak self] _ in
            guard let self,
                  self.persistenceGate.claimPersistenceTerminal() else {
                return
            }
            acknowledgement?()
            ArchiveEngineObservability.event(
                .persistence,
                value: 0,
                auxiliary: 1
            )
            self.finish(.failure(Self.transportError(for: event)))
        }
    }

    private func beginTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didStartTerminal else { return false }
        didStartTerminal = true
        return true
    }

    private func finish(_ result: Result<ArchiveTransportReceipt, Error>) {
        let tokens: (
            MessageArchiveRequestFailureDispatcher.Token?,
            MessageArchiveRequestFailurePreparationDispatcher.Token?
        )
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        tokens = (failureToken, preparationToken)
        failureToken = nil
        preparationToken = nil
        lock.unlock()

        if let token = tokens.0 {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
        if let token = tokens.1 {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(token)
        }
        account.mam.abortDeferredCommit(queryId: request.queryID)
        finishSchedulerSlot()
        switch result {
        case .success(let receipt):
            continuationBox.resume(returning: receipt)
        case .failure(let error):
            continuationBox.resume(throwing: error)
        }
    }

    private var purpose: MessageArchiveManager.RequestPurpose {
        switch request.locator {
        case .latest, .firstUnread(.none): return .bootstrap
        case .firstUnread(.some), .newer: return .pageNewer
        case .older: return .pageOlder
        case .gap: return .gapRepair
        case .archiveID: return .jump
        case .timestamp: return .timestampLookup
        }
    }

    private var coverageUpdateKind: RegularArchiveCoverageUpdateKind {
        switch request.locator {
        case .latest, .firstUnread(.none):
            return .bootstrapNewest
        case .older(let cursor):
            return .pageOlder(cursorArchiveId: cursor.rawValue)
        case .newer(let cursor), .firstUnread(.some(let cursor)):
            return .pageNewer(cursorArchiveId: cursor.rawValue)
        case .gap(_, let newer):
            return .gapRepairOlder(cursorArchiveId: newer.rawValue)
        case .archiveID, .timestamp:
            return .disjointWindow
        }
    }

    private var ids: [String]? {
        guard case .archiveID(let cursor) = request.locator else { return nil }
        return [cursor.rawValue]
    }

    private var nextPage: String? {
        switch request.locator {
        case .latest, .firstUnread(.none), .gap:
            return ""
        case .older(let cursor):
            return cursor.rawValue
        default:
            return nil
        }
    }

    private var previousPage: String? {
        switch request.locator {
        case .newer(let cursor), .firstUnread(.some(let cursor)):
            return cursor.rawValue
        default:
            return nil
        }
    }

    private var afterID: String? {
        guard case .gap(let older, _) = request.locator else { return nil }
        return older.rawValue
    }

    private var beforeID: String? {
        guard case .gap(_, let newer) = request.locator else { return nil }
        return newer.rawValue
    }

    private var startDate: Date? {
        guard case .timestamp(let date) = request.locator else { return nil }
        return date.addingTimeInterval(-43_200)
    }

    private var endDate: Date? {
        guard case .timestamp(let date) = request.locator else { return nil }
        return date.addingTimeInterval(43_200)
    }

    private static func persistencePriority(
        _ request: ArchiveTransportRequest
    ) -> ArchivePersistencePriority {
        switch request.locator {
        case .latest, .firstUnread, .archiveID, .timestamp, .gap:
            return .interactive
        case .older, .newer:
            return .background
        }
    }

    private static func transportError(
        for event: MessageArchiveRequestFailureEvent
    ) -> ArchiveTransportError {
        switch event.reason {
        case .timeout:
            return .timeout
        case .uiActionDisconnect, .requestStartFailed:
            return .disconnected
        case .serverError:
            return .protocolViolation
        case .malformedResponse:
            return .protocolViolation
        }
    }
}
