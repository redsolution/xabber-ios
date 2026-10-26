import Foundation
import XMPPFramework
import os.signpost

/// Counts only: distinguishes an ingress/outcome gap from a saved identity
/// that can no longer be materialized, without exposing any archive identity.
struct ArchiveTransportAccountingDiagnostic: Equatable, Sendable {
    let deliveredIDCount: Int
    let uniqueDeliveredIDCount: Int
    let materializedRowCount: Int
    let uniqueMaterializedPrimaryCount: Int
    let matchedMaterializedIDCount: Int
    let explicitConsumedIDCount: Int
    let consumedWithoutRowCount: Int
    let missingUnaccountedIDCount: Int
    let duplicateMaterializedIDCount: Int
    let summaryReceived: Int
    let summaryQueued: Int
    let summarySavedNew: Int
    let summaryUpdatedExisting: Int
    let summarySkipped: Int
    let summaryFailed: Int
    let summaryProcessed: Int
    let summaryQueuedWithoutOutcome: Int
    let scopedPersistedIDCount: Int
    let scopedVisibleRowCount: Int
    let visibleScopeCount: Int
    let unaccountedWithScopedPersistedIDCount: Int
    let recognizedSamePeerOMEMOIDCount: Int
    let recognizedSamePeerLegacyEncryptedIDCount: Int
    let recognizedSamePeerGroupIDCount: Int
    let recognizedSamePeerSavedIDCount: Int
}

typealias ArchiveTransportAccountingDiagnosticSink =
    @Sendable (ArchiveTransportAccountingDiagnostic) -> Void

private enum ArchiveTransportAccountingObservability {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "org.xabber", category: "ArchiveEngine")

    static func event(_ value: ArchiveTransportAccountingDiagnostic) {
        let transaction = ArchiveEngineDiagnosticExecutionCodes.take()
        os_signpost(.event, log: log, name: "archive.accounting_identity",
            "transaction=%{public}llu delivered=%{public}lld uniqueDelivered=%{public}lld rows=%{public}lld uniquePrimaries=%{public}lld matched=%{public}lld explicitConsumed=%{public}lld consumedWithoutRow=%{public}lld missing=%{public}lld duplicates=%{public}lld",
            transaction, Int64(clamping: value.deliveredIDCount), Int64(clamping: value.uniqueDeliveredIDCount),
            Int64(clamping: value.materializedRowCount), Int64(clamping: value.uniqueMaterializedPrimaryCount),
            Int64(clamping: value.matchedMaterializedIDCount), Int64(clamping: value.explicitConsumedIDCount),
            Int64(clamping: value.consumedWithoutRowCount), Int64(clamping: value.missingUnaccountedIDCount),
            Int64(clamping: value.duplicateMaterializedIDCount))
        os_signpost(.event, log: log, name: "archive.accounting_summary",
            "transaction=%{public}llu received=%{public}lld queued=%{public}lld saved=%{public}lld updated=%{public}lld skipped=%{public}lld failed=%{public}lld processed=%{public}lld",
            transaction, Int64(clamping: value.summaryReceived), Int64(clamping: value.summaryQueued),
            Int64(clamping: value.summarySavedNew), Int64(clamping: value.summaryUpdatedExisting),
            Int64(clamping: value.summarySkipped), Int64(clamping: value.summaryFailed),
            Int64(clamping: value.summaryProcessed))
        os_signpost(.event, log: log, name: "archive.accounting_scope",
            "transaction=%{public}llu queuedWithoutOutcome=%{public}lld persisted=%{public}lld visible=%{public}lld visibleScopes=%{public}lld unaccountedSaved=%{public}lld otherOMEMO=%{public}lld otherLegacyEncrypted=%{public}lld otherGroup=%{public}lld otherSaved=%{public}lld",
            transaction, Int64(clamping: value.summaryQueuedWithoutOutcome), Int64(clamping: value.scopedPersistedIDCount),
            Int64(clamping: value.scopedVisibleRowCount), Int64(clamping: value.visibleScopeCount),
            Int64(clamping: value.unaccountedWithScopedPersistedIDCount),
            Int64(clamping: value.recognizedSamePeerOMEMOIDCount),
            Int64(clamping: value.recognizedSamePeerLegacyEncryptedIDCount),
            Int64(clamping: value.recognizedSamePeerGroupIDCount),
            Int64(clamping: value.recognizedSamePeerSavedIDCount))
    }
}

struct ArchiveTransportPersistenceAccounting: Equatable, Sendable {
    let messagePrimaryIDs: [String]
    let persistedResultCount: Int
    let intentionallyConsumedResultCount: Int
    let failedPersistenceCount: Int
    let diagnostic: ArchiveTransportAccountingDiagnostic

    static func make(
        summary: MessageManager.ArchivePersistenceSummary,
        deliveredArchiveIDs: [String],
        explicitlyConsumedArchiveIDs: Set<ArchiveCursor>,
        materializedMessages: [ArchiveMaterializedMessageIdentity],
        conversation: ArchiveConversationKey? = nil
    ) -> ArchiveTransportPersistenceAccounting {
        let deliveredIDs = Set(deliveredArchiveIDs.compactMap(ArchiveCursor.init(rawValue:)))
        let materializedByArchiveID = Dictionary(
            grouping: materializedMessages.compactMap { identity in
                ArchiveCursor(rawValue: identity.archiveID).map { ($0, identity.primaryID) }
            },
            by: { $0.0 }
        )
        let duplicateMaterializedIDs = Set(
            materializedByArchiveID.compactMap { archiveID, identities in
                Set(identities.map { Data($0.1.utf8) }).count > 1 ? archiveID : nil
            }
        ).intersection(deliveredIDs)
        let uniquePrimaryByArchiveID = materializedByArchiveID.reduce(
            into: [ArchiveCursor: String]()
        ) { result, entry in
            guard Set(entry.value.map { Data($0.1.utf8) }).count == 1,
                  let primaryID = entry.value.first?.1 else {
                return
            }
            result[entry.key] = primaryID
        }
        let materializedIDs = Set(uniquePrimaryByArchiveID.keys)
            .intersection(deliveredIDs)
        let unresolvedIDs = deliveredIDs.subtracting(materializedIDs)
        let consumedWithoutRows = unresolvedIDs.intersection(
            explicitlyConsumedArchiveIDs
        )
        let unaccountedIDs = unresolvedIDs
            .subtracting(explicitlyConsumedArchiveIDs)
            .union(duplicateMaterializedIDs)
        let orderedPrimaryIDs = deliveredArchiveIDs.compactMap(ArchiveCursor.init(rawValue:)).compactMap {
            uniquePrimaryByArchiveID[$0]
        }
        let scopedPersistedIDs = conversation.map {
            summary.persistedArchiveIds(owner: $0.owner, jid: $0.jid,
                conversationType: $0.conversationType)
        } ?? []
        func samePeerPersistedIDs(
            _ type: ClientSynchronizationManager.ConversationType
        ) -> Set<ArchiveCursor> {
            guard let conversation else { return [] }
            return summary.persistedArchiveIds(owner: conversation.owner,
                jid: conversation.jid, conversationType: type)
        }
        let diagnostic = ArchiveTransportAccountingDiagnostic(
            deliveredIDCount: deliveredArchiveIDs.count, uniqueDeliveredIDCount: deliveredIDs.count,
            materializedRowCount: materializedMessages.count,
            uniqueMaterializedPrimaryCount: Set(materializedMessages.map { Data($0.primaryID.utf8) }).count,
            matchedMaterializedIDCount: materializedIDs.count,
            explicitConsumedIDCount: explicitlyConsumedArchiveIDs.intersection(deliveredIDs).count,
            consumedWithoutRowCount: consumedWithoutRows.count,
            missingUnaccountedIDCount: unresolvedIDs.subtracting(explicitlyConsumedArchiveIDs)
                .subtracting(duplicateMaterializedIDs).count,
            duplicateMaterializedIDCount: duplicateMaterializedIDs.count,
            summaryReceived: summary.received, summaryQueued: summary.queued,
            summarySavedNew: summary.savedNew, summaryUpdatedExisting: summary.updatedExisting,
            summarySkipped: summary.skipped, summaryFailed: summary.failed,
            summaryProcessed: summary.processedRows,
            summaryQueuedWithoutOutcome: max(0, summary.queued - summary.processedRows),
            scopedPersistedIDCount: scopedPersistedIDs.count,
            scopedVisibleRowCount: conversation.map {
                summary.visibleRows(owner: $0.owner, jid: $0.jid, conversationType: $0.conversationType)
            } ?? 0,
            visibleScopeCount: summary.visibleConversationCount,
            unaccountedWithScopedPersistedIDCount: unaccountedIDs.intersection(scopedPersistedIDs).count,
            recognizedSamePeerOMEMOIDCount: deliveredIDs.intersection(samePeerPersistedIDs(.omemo)).count,
            recognizedSamePeerLegacyEncryptedIDCount: deliveredIDs.intersection(
                samePeerPersistedIDs(.omemo1).union(samePeerPersistedIDs(.axolotl))).count,
            recognizedSamePeerGroupIDCount: deliveredIDs.intersection(samePeerPersistedIDs(.group)).count,
            recognizedSamePeerSavedIDCount: deliveredIDs.intersection(samePeerPersistedIDs(.saved)).count)
        return ArchiveTransportPersistenceAccounting(
            messagePrimaryIDs: orderedPrimaryIDs,
            persistedResultCount: materializedIDs.count,
            intentionallyConsumedResultCount: consumedWithoutRows.count,
            // The query-scoped barrier has completed before this resolver runs.
            // A save attempt may report failure for a row that is already
            // durable (notably repeated group/system archive rows). Coverage
            // admission depends on durable identity accounting, not on whether
            // this particular write call inserted or updated the row.
            failedPersistenceCount: unaccountedIDs.count,
            diagnostic: diagnostic
        )
    }
}

enum ArchiveTransportShadowConsumptionPolicy {
    static func archiveIDs(
        summary: MessageManager.ArchivePersistenceSummary,
        conversation: ArchiveConversationKey
    ) -> Set<ArchiveCursor> {
        guard conversation.conversationType == .group else {
            return []
        }
        // A canonical Xabber Group owns this owner/JID namespace. Older group
        // archives can contain the account-side regular-chat shadow of the
        // same events. Those rows may already exist durably as `.regular`, but
        // must never enter the canonical `.group` timeline.
        return summary.persistedArchiveIds(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: .regular
        )
    }
}

enum ArchiveSearchTransportRowPolicy {
    static func strictMAMArchiveID(for item: MessageStorageItem) -> String? {
        let archiveID = item.mamArchiveId
        guard archiveID.isNotEmpty else {
            return nil
        }
        return archiveID
    }

    static func accepts(
        owner: String,
        conversationJID: String,
        conversationTypeRaw: String,
        for scope: ArchiveSearchScope
    ) -> Bool {
        guard owner == scope.owner else { return false }
        guard let conversation = scope.conversation else {
            // Account-wide search preserves the server row's actual
            // conversation identity. Its request conversation type selects
            // the MAM route; it is not a post-persistence result filter.
            return true
        }
        return conversationJID == conversation.jid &&
            conversationTypeRaw == conversation.conversationTypeRaw
    }

    static func identityKey(for message: ArchiveSearchMessage) -> String? {
        let rowIdentity: String
        if message.archiveID.isNotEmpty {
            rowIdentity = "archive:\(message.archiveID)"
        } else if message.primaryID.isNotEmpty {
            rowIdentity = "primary:\(message.primaryID)"
        } else {
            return nil
        }
        return [
            message.owner,
            message.conversationJID,
            message.conversationTypeRaw,
            rowIdentity,
        ].joined(separator: "\u{1F}")
    }
}

enum ArchiveSearchTransportRowInsertResult: Equatable {
    case inserted
    case duplicate
    case conflictingPrimary
}

/// Collects callback-delivered search rows while preserving the one-to-one
/// relationship between an outer MAM result id and its local message primary.
/// The transaction owns synchronization; this value intentionally has no lock.
struct ArchiveSearchTransportRowAccumulator {
    private(set) var messages: [ArchiveSearchMessage] = []
    private var primaryIDByIdentityKey: [Data: String] = [:]
    private(set) var hasConflictingArchiveIdentity = false

    mutating func insert(
        _ message: ArchiveSearchMessage
    ) -> ArchiveSearchTransportRowInsertResult {
        guard let identityKey = ArchiveSearchTransportRowPolicy.identityKey(
            for: message
        ) else {
            return .duplicate
        }
        let exactIdentityKey = Data(identityKey.utf8)
        if let existingPrimaryID = primaryIDByIdentityKey[exactIdentityKey] {
            guard existingPrimaryID.utf8.elementsEqual(message.primaryID.utf8) else {
                hasConflictingArchiveIdentity = true
                return .conflictingPrimary
            }
            return .duplicate
        }
        primaryIDByIdentityKey[exactIdentityKey] = message.primaryID
        messages.append(message)
        return .inserted
    }
}

/// Bridges the callback-based MAM implementation to the archive engine's
/// immutable async receipt. The scheduler slot remains owned until both raw
/// `<fin/>` and query-scoped Realm persistence have reached a terminal.
final class MessageArchiveTransportAdapter: ArchiveTransport, @unchecked Sendable {
    private weak var account: Account?
    private let materializationResolver: ArchiveMessageMaterializationResolving
    private let requestTerminalTimeout: TimeInterval
    private let persistenceTerminalTimeout: TimeInterval
    private let accountingDiagnosticSink: ArchiveTransportAccountingDiagnosticSink

    init(
        account: Account,
        materializationResolver: ArchiveMessageMaterializationResolving,
        requestTerminalTimeout: TimeInterval = 30,
        persistenceTerminalTimeout: TimeInterval = 30,
        accountingDiagnosticSink: @escaping ArchiveTransportAccountingDiagnosticSink = ArchiveTransportAccountingObservability.event
    ) {
        self.account = account
        self.materializationResolver = materializationResolver
        self.requestTerminalTimeout = max(0, requestTerminalTimeout)
        self.persistenceTerminalTimeout = max(0, persistenceTerminalTimeout)
        self.accountingDiagnosticSink = accountingDiagnosticSink
    }

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        let receipt = try await requestPage(
            request,
            priority: priority,
            timestampDirection: .atOrAfter
        )
        guard case .timestamp = request.locator,
              receipt.deliveredResultCount == 0 else {
            return receipt
        }
        // A timestamp after the newest message still needs a nearby anchor.
        // Validate the empty forward page before trying the last bounded page
        // at/before the date. A new query identity rejects late forward replies.
        _ = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        let fallback = ArchiveTransportRequest(
            queryID: "\(request.queryID).before.\(UUID().uuidString)",
            conversation: request.conversation,
            locator: request.locator,
            connectionGeneration: request.connectionGeneration,
            pageSize: request.pageSize,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            proofFingerprint: request.proofFingerprint,
            isUnfiltered: request.isUnfiltered,
            producesContinuousCoverage: request.producesContinuousCoverage
        )
        var fallbackReceipt = try await requestPage(
            fallback,
            priority: priority,
            timestampDirection: .atOrBefore
        )
        _ = try ArchiveTransportReceiptValidator.validate(fallbackReceipt, for: fallback)
        fallbackReceipt.queryID = request.queryID
        return fallbackReceipt
    }

    func resolveStanzaReference(
        _ request: ArchiveStanzaReferenceResolutionRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveCursor? {
        guard let account else { throw ArchiveTransportError.disconnected }
        guard request.conversation.owner == account.jid else {
            throw ArchiveTransportError.authentication
        }
        let lookup = ArchiveTransportRequest(
            queryID: request.queryID,
            conversation: request.conversation,
            locator: .latest,
            connectionGeneration: request.connectionGeneration,
            pageSize: 1,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "reference-resolution",
            isUnfiltered: false,
            producesContinuousCoverage: false
        )
        let receipt = try await requestPage(
            lookup,
            priority: priority,
            timestampDirection: .atOrAfter,
            referenceResolution: request
        )
        _ = try ArchiveTransportReceiptValidator.validate(receipt, for: lookup)
        return receipt.resolvedStanzaReference
    }

    private func requestPage(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority,
        timestampDirection: ArchiveTimestampLookupDirection,
        referenceResolution: ArchiveStanzaReferenceResolutionRequest? = nil
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
                deduplicationKey: referenceResolution.map { "archive-reference.\($0.queryID)" }
                    ?? Self.deduplicationKey(for: request),
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
                    timestampDirection: timestampDirection,
                    referenceResolution: referenceResolution,
                    account: user,
                    materializationResolver: self.materializationResolver,
                    continuationBox: continuationBox,
                    requestTerminalTimeout: self.requestTerminalTimeout,
                    persistenceTerminalTimeout: self.persistenceTerminalTimeout,
                    accountingDiagnosticSink: self.accountingDiagnosticSink,
                    finishSchedulerSlot: finishSchedulerSlot
                )
                // Every transport callback intentionally captures the transaction
                // weakly to avoid a request/dispatcher retain cycle. Keep one
                // explicit owner until the async continuation reaches exactly one
                // terminal; otherwise the local transaction is released as soon
                // as this scheduler closure returns and `<fin/>` becomes a no-op.
                continuationBox.retainUntilTerminal(transaction)
                transaction.start(on: stream)
            }
        }
    }

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        guard let account else {
            throw ArchiveTransportError.disconnected
        }
        let continuationBox = ArchiveSearchTransportContinuationBox()
        return try await withCheckedThrowingContinuation { continuation in
            continuationBox.install(continuation)
            account.xmppTaskScheduler.enqueueAccountTask(
                priority: Self.schedulerPriority(priority),
                resource: .mamArchive,
                deduplicationKey: Self.searchDeduplicationKey(for: request),
                unavailable: {
                    continuationBox.resume(
                        throwing: ArchiveTransportError.disconnected
                    )
                }
            ) { user, stream, finishSchedulerSlot in
                let transaction = ArchiveSearchTransportTransaction(
                    request: request,
                    account: user,
                    continuationBox: continuationBox,
                    requestTerminalTimeout: self.requestTerminalTimeout,
                    persistenceTerminalTimeout: self.persistenceTerminalTimeout,
                    finishSchedulerSlot: finishSchedulerSlot
                )
                continuationBox.retainUntilTerminal(transaction)
                transaction.start(on: stream)
            }
        }
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {
        account?.xmppTaskScheduler.promotePendingTask(
            deduplicationKey: Self.deduplicationKey(
                for: descriptor,
                connectionGeneration: connectionGeneration
            ),
            to: Self.schedulerPriority(priority)
        )
    }

    static func schedulerPriority(
        _ priority: ArchiveIntentPriority
    ) -> AccountXMPPTaskScheduler.Priority {
        switch priority {
        case .visibleIntegrity, .target, .searchCurrentPage:
            return .interactive
        case .nearEdgePrefetch:
            return .foreground
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
            ),
            connectionGeneration: request.connectionGeneration
        )
    }

    private static func deduplicationKey(
        for descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64
    ) -> String {
        let key = descriptor.conversation
        return [
            "archive-engine",
            key.owner,
            key.jid,
            key.conversationTypeRaw,
            String(connectionGeneration),
            String(describing: descriptor.locator),
            String(descriptor.contextBefore),
            String(descriptor.contextAfter),
        ].joined(separator: "\u{1F}")
    }

    private static func searchDeduplicationKey(
        for request: ArchiveSearchTransportRequest
    ) -> String {
        [
            "archive-engine-search",
            request.scope.owner,
            request.jid ?? "all-conversations",
            request.conversationType.rawValue,
            String(request.connectionGeneration),
            request.queryID,
            request.query,
            request.pageCursor ?? "latest",
        ].joined(separator: "\u{1F}")
    }
}

final class ArchiveSearchTransportContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<ArchiveSearchTransportReceipt, Error>?
    private var pendingResult: Result<ArchiveSearchTransportReceipt, Error>?
    private var terminalRetention: AnyObject?

    func retainUntilTerminal(_ object: AnyObject) {
        lock.lock()
        terminalRetention = object
        lock.unlock()
    }

    func install(
        _ continuation: CheckedContinuation<ArchiveSearchTransportReceipt, Error>
    ) {
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

    func resume(returning receipt: ArchiveSearchTransportReceipt) {
        resume(with: .success(receipt))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(
        with result: Result<ArchiveSearchTransportReceipt, Error>
    ) {
        lock.lock()
        terminalRetention = nil
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

final class ArchiveTransportContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ArchiveTransportReceipt, Error>?
    private var pendingResult: Result<ArchiveTransportReceipt, Error>?
    private var terminalRetention: AnyObject?

    func retainUntilTerminal(_ object: AnyObject) {
        lock.lock()
        terminalRetention = object
        lock.unlock()
    }

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
        terminalRetention = nil
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

private enum ArchiveTimestampLookupDirection: Equatable, Sendable {
    case atOrAfter
    case atOrBefore
}

private final class ArchiveTransportTransaction: @unchecked Sendable {
    private let request: ArchiveTransportRequest
    private let timestampDirection: ArchiveTimestampLookupDirection
    private let referenceResolution: ArchiveStanzaReferenceResolutionRequest?
    private let account: Account
    private let materializationResolver: ArchiveMessageMaterializationResolving
    private let continuationBox: ArchiveTransportContinuationBox
    private let finishSchedulerSlot: () -> Void
    private let lock = NSLock()
    private let requestTerminalGate: ArchivePersistenceTerminalGate
    private let persistenceGate: ArchivePersistenceTerminalGate
    private let accountingDiagnosticSink: ArchiveTransportAccountingDiagnosticSink
    private var didStartTerminal = false
    private var didFinish = false
    private var failureToken: MessageArchiveRequestFailureDispatcher.Token?
    private var preparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token?
    private var endPageToken: MessageArchiveEndPageDispatcher.Token?

    init(
        request: ArchiveTransportRequest,
        timestampDirection: ArchiveTimestampLookupDirection,
        referenceResolution: ArchiveStanzaReferenceResolutionRequest?,
        account: Account,
        materializationResolver: ArchiveMessageMaterializationResolving,
        continuationBox: ArchiveTransportContinuationBox,
        requestTerminalTimeout: TimeInterval,
        persistenceTerminalTimeout: TimeInterval,
        accountingDiagnosticSink: @escaping ArchiveTransportAccountingDiagnosticSink,
        finishSchedulerSlot: @escaping () -> Void
    ) {
        self.request = request
        self.timestampDirection = timestampDirection
        self.referenceResolution = referenceResolution
        self.account = account
        self.materializationResolver = materializationResolver
        self.continuationBox = continuationBox
        self.requestTerminalGate = ArchivePersistenceTerminalGate(
            timeout: requestTerminalTimeout
        )
        self.persistenceGate = ArchivePersistenceTerminalGate(
            timeout: persistenceTerminalTimeout
        )
        self.finishSchedulerSlot = finishSchedulerSlot
        self.accountingDiagnosticSink = accountingDiagnosticSink
    }

    func start(on stream: XMPPStream) {
        guard stream.isAuthenticated,
              account.sendReadiness.snapshot.canFlushApplicationStanzas else {
            finish(.failure(ArchiveTransportError.disconnected))
            return
        }
        if let referenceResolution,
           !account.mam.registerStanzaReferenceResolution(referenceResolution) {
            finish(.failure(ArchiveTransportError.protocolViolation))
            return
        }

        account.messages.beginArchiveQueryBatch(
            queryId: request.queryID,
            priority: Self.persistencePriority(request)
        )
        account.messages.holdPostPersistenceEffectsUntilArchiveTransportTerminal(
            queryId: request.queryID
        )
        ArchiveEngineObservability.event(
            .transport,
            value: request.pageSize
        )
        endPageToken = MessageArchiveEndPageDispatcher.register(
            owner: request.conversation.owner,
            queryId: request.queryID,
            delivery: .synchronous
        ) { [weak self] event in
            self?.handleFinal(
                queryID: event.queryId,
                state: event.state,
                first: event.first,
                last: event.last
            )
        }
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

        guard requestTerminalGate.arm(onTimeout: { [weak self] in
            self?.handleRequestTerminalTimeout()
        }) else {
            finish(.failure(ArchiveTransportError.protocolViolation))
            return
        }

        account.mam.requestArchive(
            stream,
            jid: request.conversation.jid,
            isContinues: false,
            conversationType: request.conversation.conversationType,
            purpose: purpose,
            queryId: request.queryID,
            ids: ids,
            flipPage: request.usesFlippedPage,
            beforeId: beforeID,
            afterId: afterID,
            start: startDate,
            end: endDate,
            nextPage: nextPage,
            prevPage: previousPage,
            max: request.pageSize,
            withCounter: false,
            retainSealedTransportProofUntilBarrier: true,
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
        guard queryID == request.queryID else { return }
        guard requestTerminalGate.claimPersistenceTerminal() else {
            // MessageArchiveManager publishes the raw final synchronously and
            // then delivers its request-local callback on the main queue. Both
            // routes describe the same terminal, so the route that loses
            // ownership must not fail or release the request while the winner
            // is still waiting for persistence.
            ChatArchiveDebugTrace.log(
                "archiveTransportDuplicateFinalIgnored",
                [("persistenceTerminalAlreadyClaimed", true)]
            )
            return
        }
        guard beginTerminal() else {
            ChatArchiveDebugTrace.log(
                "archiveTransportDuplicateFinalIgnored",
                [("transactionTerminalAlreadyStarted", true)]
            )
            return
        }
        guard let accounting = account.mam.archiveTransportAccountingSnapshot(
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
                    let materializedMessages = try await self.materializationResolver
                        .materializedMessages(
                            conversation: self.request.conversation,
                            archiveIDs: accounting.resultArchiveIDs
                        )
                    let persistenceAccounting =
                        ArchiveTransportPersistenceAccounting.make(
                            summary: summary,
                            deliveredArchiveIDs: accounting.resultArchiveIDs,
                            explicitlyConsumedArchiveIDs:
                                accounting.intentionallyConsumedArchiveIDs.union(
                                    summary.skippedArchiveIds
                                ).union(
                                    ArchiveTransportShadowConsumptionPolicy.archiveIDs(
                                        summary: summary,
                                        conversation: self.request.conversation
                                    )
                            ),
                            materializedMessages: materializedMessages,
                            conversation: self.request.conversation
                        )
                    self.accountingDiagnosticSink(persistenceAccounting.diagnostic)
                    ChatArchiveDebugTrace.logDiagnostic(
                        "archiveTransportPersistenceAccounting",
                        context: ChatArchiveDebugTrace.DiagnosticContext(
                            owner: self.request.conversation.owner,
                            jid: self.request.conversation.jid,
                            conversationType:
                                self.request.conversation.conversationType.rawValue,
                            queryID: self.request.queryID
                        ),
                        [
                            ("summaryReceived", summary.received),
                            ("summaryQueued", summary.queued),
                            ("summarySavedNew", summary.savedNew),
                            ("summaryUpdatedExisting", summary.updatedExisting),
                            ("summarySkipped", summary.skipped),
                            ("summaryFailed", summary.failed),
                            ("deliveredResultCount", accounting.deliveredResultCount),
                            ("deliveredArchiveIDCount", accounting.resultArchiveIDs.count),
                            ("wireConsumedResultCount", accounting.intentionallyConsumedResultCount),
                            ("materializedMessageCount", materializedMessages.count),
                            ("uniqueMaterializedPrimaryCount", Set(
                                materializedMessages.map(\.primaryID)
                            ).count),
                            ("requestVisibleRowCount", summary.visibleRows(
                                owner: self.request.conversation.owner,
                                jid: self.request.conversation.jid,
                                conversationType:
                                    self.request.conversation.conversationType
                            )),
                            ("requestPersistedArchiveIDCount", summary.persistedArchiveIdCount(
                                owner: self.request.conversation.owner,
                                jid: self.request.conversation.jid,
                                conversationType:
                                    self.request.conversation.conversationType
                            )),
                            ("accountedPersistedResultCount", persistenceAccounting.persistedResultCount),
                            ("accountedConsumedResultCount", persistenceAccounting.intentionallyConsumedResultCount),
                            ("accountedFailedResultCount", persistenceAccounting.failedPersistenceCount)
                        ]
                    )
                    let resolvedReference: ArchiveCursor?
                    if self.referenceResolution != nil {
                        resolvedReference = try self.account.mam.resolvedStanzaReferenceCursor(
                            queryID: self.request.queryID,
                            deliveredArchiveIDs: accounting.resultArchiveIDs
                        )
                    } else {
                        resolvedReference = nil
                    }
                    let receipt = ArchiveTransportReceipt(
                        queryID: queryID,
                        connectionGeneration: self.request.connectionGeneration,
                        resultArchiveIDs: accounting.resultArchiveIDs,
                        messagePrimaryIDs:
                            persistenceAccounting.messagePrimaryIDs,
                        first: first,
                        last: last,
                        complete: state.rawComplete,
                        cheapPageCount: state.serverResultCount ?? accounting.deliveredResultCount,
                        deliveredResultCount: accounting.deliveredResultCount,
                        persistedResultCount:
                            persistenceAccounting.persistedResultCount,
                        intentionallyConsumedResultCount:
                            persistenceAccounting
                                .intentionallyConsumedResultCount,
                        failedPersistenceCount:
                            persistenceAccounting.failedPersistenceCount,
                        finalReceived: true,
                        resolvedStanzaReference: resolvedReference
                    )
                    self.finish(.success(receipt))
                } catch let error as ArchiveTransportError {
                    self.finish(.failure(error))
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
        guard requestTerminalGate.claimPersistenceTerminal(),
              beginTerminal() else {
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

    private func handleRequestTerminalTimeout() {
        guard beginTerminal() else { return }
        // The adapter owns the overall terminal watchdog. When it wins there
        // will be no server final to make MessageArchiveManager retire its
        // query-scoped callback and identity, so fail closed before releasing
        // the scheduler lease.
        _ = account.mam.cancelPendingArchiveRequest(
            queryId: request.queryID
        )
        guard persistenceGate.arm(onTimeout: { [weak self] in
            self?.finish(.failure(ArchiveTransportError.timeout))
        }) else {
            finish(.failure(ArchiveTransportError.timeout))
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
            self.finish(.failure(ArchiveTransportError.timeout))
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
            MessageArchiveEndPageDispatcher.Token?,
            MessageArchiveRequestFailureDispatcher.Token?,
            MessageArchiveRequestFailurePreparationDispatcher.Token?
        )
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        tokens = (endPageToken, failureToken, preparationToken)
        endPageToken = nil
        failureToken = nil
        preparationToken = nil
        lock.unlock()

        if case .failure = result {
            _ = account.mam.cancelPendingArchiveRequest(
                queryId: request.queryID
            )
        }

        if let token = tokens.0 {
            MessageArchiveEndPageDispatcher.unregister(token)
        }
        if let token = tokens.1 {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
        if let token = tokens.2 {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(token)
        }
        account.mam.finishOMEMO2CleanupQuery(queryId: request.queryID)
        account.mam.abortDeferredCommit(queryId: request.queryID)
        finishSchedulerSlot()
        switch result {
        case .success(let receipt):
            continuationBox.resume(returning: receipt)
        case .failure(let error):
            continuationBox.resume(throwing: error)
        }
        account.messages.releasePostPersistenceEffectsAfterArchiveTransportTerminal(
            queryId: request.queryID
        )
    }

    private var purpose: MessageArchiveManager.RequestPurpose {
        if referenceResolution != nil { return .jump }
        switch request.locator {
        case .latest, .firstUnread(.none): return .bootstrap
        case .firstUnread(.some), .newer: return .pageNewer
        case .older: return .pageOlder
        case .gap: return .gapRepair
        case .archiveID: return .jump
        case .timestamp: return .timestampLookup
        }
    }

    private var ids: [String]? {
        if let referenceResolution { return [referenceResolution.reference] }
        guard case .archiveID(let cursor) = request.locator else { return nil }
        return [cursor.rawValue]
    }

    private var nextPage: String? {
        if referenceResolution != nil { return nil }
        switch request.locator {
        case .latest, .firstUnread(.none), .gap:
            return ""
        case .older(let cursor):
            return cursor.rawValue
        case .timestamp where timestampDirection == .atOrBefore:
            return ""
        default:
            return nil
        }
    }

    private var previousPage: String? {
        if referenceResolution != nil { return nil }
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
        guard case .timestamp(let date) = request.locator,
              timestampDirection == .atOrAfter else { return nil }
        // Default RSM paging starts at the earliest matching result. A broad
        // date window would select its oldest page instead of a nearby anchor.
        return date
    }

    private var endDate: Date? {
        guard case .timestamp(let date) = request.locator,
              timestampDirection == .atOrBefore else { return nil }
        return date
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
            return .serverError
        case .malformedResponse:
            return .protocolViolation
        }
    }
}

private final class ArchiveSearchTransportTransaction: @unchecked Sendable {
    private let request: ArchiveSearchTransportRequest
    private let account: Account
    private let continuationBox: ArchiveSearchTransportContinuationBox
    private let finishSchedulerSlot: () -> Void
    private let lock = NSLock()
    private let requestTerminalGate: ArchivePersistenceTerminalGate
    private let persistenceGate: ArchivePersistenceTerminalGate
    private var searchRows = ArchiveSearchTransportRowAccumulator()
    private var didStartTerminal = false
    private var didFinish = false
    private var failureToken: MessageArchiveRequestFailureDispatcher.Token?
    private var preparationToken:
        MessageArchiveRequestFailurePreparationDispatcher.Token?

    init(
        request: ArchiveSearchTransportRequest,
        account: Account,
        continuationBox: ArchiveSearchTransportContinuationBox,
        requestTerminalTimeout: TimeInterval,
        persistenceTerminalTimeout: TimeInterval,
        finishSchedulerSlot: @escaping () -> Void
    ) {
        self.request = request
        self.account = account
        self.continuationBox = continuationBox
        self.requestTerminalGate = ArchivePersistenceTerminalGate(
            timeout: requestTerminalTimeout
        )
        self.persistenceGate = ArchivePersistenceTerminalGate(
            timeout: persistenceTerminalTimeout
        )
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
            priority: .interactive
        )
        account.messages.holdPostPersistenceEffectsUntilArchiveTransportTerminal(
            queryId: request.queryID
        )
        ArchiveEngineObservability.event(
            .transport,
            value: request.pageSize
        )
        preparationToken = MessageArchiveRequestFailurePreparationDispatcher.register(
            owner: request.scope.owner,
            queryId: request.queryID
        ) { [weak self] event, acknowledgement in
            self?.handleFailure(event, acknowledgement: acknowledgement)
        }
        failureToken = MessageArchiveRequestFailureDispatcher.register(
            owner: request.scope.owner,
            queryId: request.queryID,
            delivery: .synchronous
        ) { [weak self] event in
            self?.handleFailure(event, acknowledgement: nil)
        }

        guard requestTerminalGate.arm(onTimeout: { [weak self] in
            self?.handleRequestTerminalTimeout()
        }) else {
            finish(.failure(ArchiveTransportError.protocolViolation))
            return
        }

        account.mam.requestArchive(
            stream,
            jid: request.jid,
            isContinues: false,
            conversationType: request.conversationType,
            purpose: .engineSearchPage,
            queryId: request.queryID,
            searchText: request.query,
            flipPage: false,
            nextPage: request.pageCursor ?? "",
            max: min(max(1, request.pageSize), ArchivePageSizing.search),
            withCounter: false,
            retainSealedTransportProofUntilBarrier: true,
            requestCallbacks: MessageArchiveManager.RequestCallbacks(
                onMessage: { [weak self] item, queryID in
                    self?.record(item, queryID: queryID)
                },
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

    private func record(_ item: MessageStorageItem, queryID: String) {
        guard queryID == request.queryID,
              ArchiveSearchTransportRowPolicy.accepts(
                  owner: item.owner,
                  conversationJID: item.opponent,
                  conversationTypeRaw: item.conversationType.rawValue,
                  for: request.scope
              ) else {
            return
        }
        guard let archiveID = ArchiveSearchTransportRowPolicy.strictMAMArchiveID(
            for: item
        ) else {
            ChatArchiveDebugTrace.log("archiveSearchRowRejected", [
                ("owner", item.owner),
                ("queryId", queryID),
                ("reason", "missingVerifiedMAMResultID")
            ])
            return
        }
        let message = ArchiveSearchMessage(
            primaryID: item.primary,
            archiveID: archiveID,
            messageID: item.messageId,
            owner: item.owner,
            conversationJID: item.opponent,
            conversationTypeRaw: item.conversationType.rawValue,
            body: item.body,
            date: item.date,
            outgoing: item.outgoing,
            deliveryStateRaw: item.state.rawValue,
            groupAuthorID: item.groupchatAuthorId,
            groupAuthorNickname: item.groupchatAuthorNickname,
            groupAuthorAvatarURL: item.groupchatAuthorAvatarURL
        )
        lock.lock()
        guard !didStartTerminal else {
            lock.unlock()
            return
        }
        let insertResult = searchRows.insert(message)
        lock.unlock()
        if insertResult == .conflictingPrimary {
            ChatArchiveDebugTrace.log("archiveSearchRowRejected", [
                ("owner", item.owner),
                ("queryId", queryID),
                ("reason", "conflictingMAMResultPrimary")
            ])
        }
    }

    private func handleFinal(
        queryID: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String
    ) {
        guard queryID == request.queryID else { return }
        guard requestTerminalGate.claimPersistenceTerminal() else {
            ChatArchiveDebugTrace.log(
                "archiveSearchTransportDuplicateFinalIgnored",
                [("persistenceTerminalAlreadyClaimed", true)]
            )
            return
        }
        guard beginTerminal() else {
            ChatArchiveDebugTrace.log(
                "archiveSearchTransportDuplicateFinalIgnored",
                [("transactionTerminalAlreadyStarted", true)]
            )
            return
        }
        guard let accounting = account.mam.archiveTransportAccountingSnapshot(
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
        }) else {
            return
        }
        let expected = account.mam.expectedPersistenceResultCount(
            queryId: request.queryID
        )
        account.messages.finishArchiveQueryBatchAsync(
            queryId: request.queryID,
            priority: .interactive,
            expectedReceivedCount: expected
        ) { [weak self] summary in
            guard let self,
                  self.persistenceGate.claimPersistenceTerminal() else {
                return
            }
            self.lock.lock()
            let messages = self.searchRows.messages
            let hasConflictingArchiveIdentity =
                self.searchRows.hasConflictingArchiveIdentity
            self.lock.unlock()
            ArchiveEngineObservability.event(
                .persistence,
                value: summary.persistedRows,
                auxiliary: summary.failed + summary.skipped
            )
            guard !hasConflictingArchiveIdentity else {
                ChatArchiveDebugTrace.log("archiveSearchTransactionRejected", [
                    ("owner", self.request.scope.owner),
                    ("queryId", queryID),
                    ("reason", "conflictingMAMResultPrimary")
                ])
                self.finish(.failure(ArchiveTransportError.protocolViolation))
                return
            }
            self.finish(
                .success(
                    ArchiveSearchTransportReceipt(
                        queryID: queryID,
                        connectionGeneration: self.request.connectionGeneration,
                        messages: messages,
                        first: first,
                        last: last,
                        complete: state.rawComplete,
                        deliveredResultCount: accounting.deliveredResultCount,
                        persistedResultCount: min(
                            accounting.deliveredResultCount,
                            max(0, summary.processedRows - summary.failed)
                        ),
                        failedPersistenceCount: summary.failed,
                        finalReceived: true
                    )
                )
            )
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
        guard requestTerminalGate.claimPersistenceTerminal(),
              beginTerminal() else {
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
            priority: .interactive,
            expectedReceivedCount: nil
        ) { [weak self] _ in
            guard let self,
                  self.persistenceGate.claimPersistenceTerminal() else {
                return
            }
            acknowledgement?()
            self.finish(.failure(Self.transportError(for: event)))
        }
    }

    private func handleRequestTerminalTimeout() {
        guard beginTerminal() else { return }
        // Search pages use the same MAM callback registry and must not leave a
        // stale query occupying manager state after the adapter watchdog wins.
        _ = account.mam.cancelPendingArchiveRequest(
            queryId: request.queryID
        )
        guard persistenceGate.arm(onTimeout: { [weak self] in
            self?.finish(.failure(ArchiveTransportError.timeout))
        }) else {
            finish(.failure(ArchiveTransportError.timeout))
            return
        }
        account.messages.releaseArchiveQueryBatchIngressExpectation(
            queryId: request.queryID
        )
        account.messages.finishArchiveQueryBatchAsync(
            queryId: request.queryID,
            priority: .interactive,
            expectedReceivedCount: nil
        ) { [weak self] _ in
            guard let self,
                  self.persistenceGate.claimPersistenceTerminal() else {
                return
            }
            self.finish(.failure(ArchiveTransportError.timeout))
        }
    }

    private func beginTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didStartTerminal else { return false }
        didStartTerminal = true
        return true
    }

    private func finish(
        _ result: Result<ArchiveSearchTransportReceipt, Error>
    ) {
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
        if case .failure = result {
            _ = account.mam.cancelPendingArchiveRequest(
                queryId: request.queryID
            )
        }
        if let token = tokens.0 {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
        if let token = tokens.1 {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(token)
        }
        account.mam.finishOMEMO2CleanupQuery(queryId: request.queryID)
        account.mam.abortDeferredCommit(queryId: request.queryID)
        account.mam.finishEngineSearchPage(queryId: request.queryID)
        finishSchedulerSlot()
        switch result {
        case .success(let receipt):
            continuationBox.resume(returning: receipt)
        case .failure(let error):
            continuationBox.resume(throwing: error)
        }
        account.messages.releasePostPersistenceEffectsAfterArchiveTransportTerminal(
            queryId: request.queryID
        )
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
            return .serverError
        case .malformedResponse:
            return .protocolViolation
        }
    }
}
