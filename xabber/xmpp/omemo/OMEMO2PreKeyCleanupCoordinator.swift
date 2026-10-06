import Foundation

/// Ephemeral owner-local receive ownership. The protected storage remains the
/// source of consumed IDs; no catch-up proof or key material is journalled here.
final class OMEMO2PreKeyCleanupCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let consumedIDs: () throws -> Set<UInt32>
    private let removeConsumed: (Set<UInt32>) throws -> Void
    private var chains: Set<UUID> = []
    private var queries: [UUID: String] = [:]
    private var ingress: Set<UUID> = []
    private var eligible: Set<UInt32> = []

    init(consumedIDs: @escaping () throws -> Set<UInt32>,
         removeConsumed: @escaping (Set<UInt32>) throws -> Void) {
        self.consumedIDs = consumedIDs
        self.removeConsumed = removeConsumed
    }

    func beginCatchUp(id: UUID) {
        synchronized {
            chains.insert(id)
            adoptConsumed()
        }
    }

    func finishCatchUp(id: UUID) {
        synchronized {
            guard chains.remove(id) != nil else { return }
            cleanIfIdle()
        }
    }

    @discardableResult
    func beginQuery(id: String) -> UUID {
        synchronized {
            let token = UUID()
            queries[token] = id
            adoptConsumed()
            return token
        }
    }

    func finishQuery(id: String, token: UUID) {
        synchronized {
            guard queries[token] == id else { return }
            queries.removeValue(forKey: token)
            cleanIfIdle()
        }
    }

    func beginIngress() -> UUID {
        synchronized {
            let token = UUID()
            ingress.insert(token)
            return token
        }
    }

    func finishIngress(id: UUID) {
        synchronized {
            guard ingress.remove(id) != nil else { return }
            cleanIfIdle()
        }
    }

    /// Called only after the authenticated decrypt transaction has committed
    /// and released the storage owner lock.
    func authenticatedReceiveDidCommit() {
        synchronized { adoptConsumed(); cleanIfIdle() }
    }

    func retryEligibleCleanup() {
        synchronized { adoptConsumed(); cleanIfIdle() }
    }

    private func adoptConsumed() {
        if let consumed = try? consumedIDs() { eligible.formUnion(consumed) }
    }

    private func cleanIfIdle() {
        guard chains.isEmpty, queries.isEmpty, ingress.isEmpty, !eligible.isEmpty else { return }
        do {
            // Registration uses the same coordinator lock as this recheck and
            // selective protected write. Storage never calls back while locked.
            let consumed = try consumedIDs()
            eligible.formIntersection(consumed)
            guard !eligible.isEmpty else { return }
            try removeConsumed(eligible)
            eligible.removeAll()
        } catch {
            // A maintenance or the next receive terminal retries eligibility;
            // a successful decrypt remains successful if cleanup save fails.
        }
    }

    private func synchronized<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}

struct OMEMO2CleanupTimeoutPolicy {
    var request: TimeInterval
    var persistence: TimeInterval
    static let production = OMEMO2CleanupTimeoutPolicy(request: 30, persistence: 30)
}

/// A legacy/standalone query has the same finite request + persistence
/// terminals as the modern archive adapter. Retained adapter queries use its
/// existing watchdogs and explicitly call finish() at the adapter terminal.
final class OMEMO2CleanupQueryLease {
    let id: String
    let token: UUID
    let chainID: UUID?
    private let cleanup: OMEMO2PreKeyCleanupCoordinator
    private weak var messages: MessageManager?
    private let requestGate: ArchivePersistenceTerminalGate
    private let persistenceGate: ArchivePersistenceTerminalGate
    private let lock = NSLock()
    private var didBeginPersistence = false
    private var didFinish = false
    private var closesChain = false
    private let onTerminal: (UUID, Bool, Bool) -> Void

    init(id: String, chainID: UUID?, cleanup: OMEMO2PreKeyCleanupCoordinator,
         messages: MessageManager?, policy: OMEMO2CleanupTimeoutPolicy,
         onTerminal: @escaping (UUID, Bool, Bool) -> Void) {
        self.id = id
        self.chainID = chainID
        self.cleanup = cleanup
        self.messages = messages
        self.token = cleanup.beginQuery(id: id)
        self.requestGate = ArchivePersistenceTerminalGate(timeout: policy.request)
        self.persistenceGate = ArchivePersistenceTerminalGate(timeout: policy.persistence)
        self.onTerminal = onTerminal
    }

    func armRequestTimeout(_ handler: @escaping (@escaping () -> Void) -> Void) {
        requestGate.arm { [self] in
            handler { [self] in
                // First retire the request on its stream-owner queue, then
                // allow the bounded partial persistence flush to release it.
                beginPersistence(expected: nil, closesChain: true, abandoning: true)
            }
        }
    }

    func beginPersistence(expected: Int?, closesChain: Bool, abandoning: Bool = false) {
        lock.lock()
        self.closesChain = self.closesChain || closesChain
        guard !didBeginPersistence, !didFinish else { lock.unlock(); return }
        didBeginPersistence = true
        lock.unlock()
        _ = requestGate.claimPersistenceTerminal()
        guard let messages else { finish(successfulPersistence: false); return }
        guard persistenceGate.arm(onTimeout: { [self] in
            messages.releaseArchiveQueryBatchIngressExpectation(queryId: id)
            finish(successfulPersistence: false)
        }) else { return }
        if abandoning { messages.releaseArchiveQueryBatchIngressExpectation(queryId: id) }
        messages.finishArchiveQueryBatchAsync(queryId: id, expectedReceivedCount: expected) { [self] _ in
            guard persistenceGate.claimPersistenceTerminal() else { return }
            finish()
        }
    }

    func finish(successfulPersistence: Bool = true) {
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        didFinish = true
        let closesChain = self.closesChain || !successfulPersistence
        lock.unlock()
        _ = requestGate.claimPersistenceTerminal()
        _ = persistenceGate.claimPersistenceTerminal()
        cleanup.finishQuery(id: id, token: token)
        if closesChain, let chainID { cleanup.finishCatchUp(id: chainID) }
        // Persistence completions run on MessageManager's queue. Retirement
        // must never wait there for MAM's lifecycle lock, because registration
        // may hold that lock while synchronizing the next archive batch.
        DispatchQueue.global(qos: .utility).async { [onTerminal, token] in
            onTerminal(token, closesChain, successfulPersistence)
        }
    }
}
