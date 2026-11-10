import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class ArchiveWirePreparationLatencyTests: XCTestCase {
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ArchiveWirePreparation-\(UUID().uuidString)")
        realm = try WRealm.safe()
        resetDispatchers()
    }

    override func tearDown() {
        resetDispatchers()
        realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        previousConfiguration = nil
        super.tearDown()
    }

    func testVisibleHistorySendsWhilePriorPersistenceIsHeldButReceiptStillAwaitsItsBarrier() throws {
        try assertWirePreparationDoesNotWaitForPriorPersistence(isSearch: false)
    }

    func testVisibleSearchSendsWhilePriorPersistenceIsHeldButReceiptStillAwaitsItsBarrier() throws {
        try assertWirePreparationDoesNotWaitForPriorPersistence(isSearch: true)
    }

    func testHistoryRawFinalKeepsOldGenerationReceiptThroughResetUntilPersistenceCompletes() throws {
        try assertPostFinalResetPreservesPersistence(isSearch: false, resetBeforeScheduledCompletion: false)
    }

    func testSearchRawFinalKeepsOldGenerationReceiptThroughResetUntilPersistenceCompletes() throws {
        try assertPostFinalResetPreservesPersistence(isSearch: true, resetBeforeScheduledCompletion: false)
    }

    func testHistoryRawFinalWinsResetQueuedBeforeSchedulerCompletionAndCleansItsProof() throws {
        try assertPostFinalResetPreservesPersistence(isSearch: false, resetBeforeScheduledCompletion: true)
    }

    func testSearchRawFinalWinsResetQueuedBeforeSchedulerCompletionAndCleansItsProof() throws {
        try assertPostFinalResetPreservesPersistence(isSearch: true, resetBeforeScheduledCompletion: true)
    }

    func testHistoryResetBeforeFinalFailsOnceAfterPersistenceCleanup() throws {
        try assertPostFinalResetPreservesPersistence(isSearch: false,
            resetBeforeScheduledCompletion: false, receivesFinal: false)
    }

    func testSearchResetBeforeFinalFailsOnceAfterPersistenceCleanup() throws {
        try assertPostFinalResetPreservesPersistence(isSearch: true,
            resetBeforeScheduledCompletion: false, receivesFinal: false)
    }

    func testQueuedPreparationCannotReopenABatchAfterReceiverLifecycleFlush() throws {
        let queryID = "retired-preparation-\(UUID().uuidString)"
        let messages = MessageManager(withOwner: "retired-batch@example.test", activeStream: false)
        let queueEntered = expectation(description: "message queue owns a lifecycle flush before queued metadata")
        let flushed = expectation(description: "receiver lifecycle flush completed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        messages.queue.async {
            queueEntered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            messages.unsubscribeReceiver()
            flushed.fulfill()
        }
        wait(for: [queueEntered], timeout: 1)

        messages.prepareArchiveTransportQueryBatch(queryId: queryID, priority: .interactive)
        release.signal()
        wait(for: [flushed], timeout: 1)

        let state = messages.performMessageQueueSync {
            (messages.archiveQueryBatchIds.contains(queryID),
             messages.archivePersistencePriorityByQueryId[queryID],
             messages.postPersistenceEffectsHeldForTransportQueryIds.contains(queryID))
        }
        XCTAssertFalse(state.0)
        XCTAssertNil(state.1)
        XCTAssertFalse(state.2, "Queued preparation must not revive a retired transport effects hold")
    }

    #if DEBUG
    func testResetBeforeAccountStartCannotSendOrRegisterALateNativeQuery() throws {
        let queryID = "cancelled-before-start-\(UUID().uuidString)"
        let owner = "cancelled-before-start@example.test"
        let account = Account(jid: owner, queue: DispatchQueue(label: queryID))
        let stream = ArchiveWirePreparationStream {}
        stream.myJID = XMPPJID(string: owner, resource: "archive-cancel-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let messages = account.messages
        let mam = account.mam
        let scheduler = account.xmppTaskScheduler
        let adapter = MessageArchiveTransportAdapter(account: account,
            materializationResolver: ArchiveWirePreparationResolver(),
            requestTerminalTimeout: 3, persistenceTerminalTimeout: 3)
        let accountHeld = expectation(description: "account queue held before adapter start")
        let releaseAccount = DispatchSemaphore(value: 0)
        defer {
            releaseAccount.signal()
            messages.updateSendingMessagesTimer?.invalidate()
            messages.updateSendingMessagesTimer = nil
        }
        account.queue.async {
            accountHeld.fulfill()
            _ = releaseAccount.wait(timeout: .now() + 4)
        }
        wait(for: [accountHeld], timeout: 1)
        let terminal = expectation(description: "queued adapter request is cancelled before start")
        let results = ArchiveWirePreparationResults()
        Task {
            do {
                _ = try await adapter.request(.init(queryID: queryID,
                    conversation: .init(owner: owner, jid: "peer@example.test", conversationType: .regular),
                    locator: .latest, connectionGeneration: 39, pageSize: 80,
                    contextBefore: 80, contextAfter: 0, proofFingerprint: "session:39",
                    isUnfiltered: true, producesContinuousCoverage: true), priority: .visibleIntegrity)
                results.append(.success(true))
            } catch { results.append(.failure(error)) }
            terminal.fulfill()
        }
        pumpRunLoop(until: { !account.isActionQueueQuiescentForTests }, timeout: 1)
        XCTAssertFalse(account.isActionQueueQuiescentForTests,
            "The real scheduler must have enqueued the blocked account action before reset")
        scheduler.reset()
        waitForSchedulerTurn(scheduler, queryID: queryID + "-reset")
        wait(for: [terminal], timeout: 1)
        releaseAccount.signal()
        let accountDrained = expectation(description: "late account start closure has returned")
        account.action { _, _ in accountDrained.fulfill() }
        wait(for: [accountDrained], timeout: 1)

        XCTAssertEqual(results.values.count, 1)
        XCTAssertThrowsError(try XCTUnwrap(results.values.first).get()) {
            XCTAssertEqual($0 as? ArchiveTransportError, .disconnected)
        }
        XCTAssertTrue(stream.queries.isEmpty)
        XCTAssertFalse(mam.callbackQueueContains { $0.elementId == queryID })
        XCTAssertNil(mam.archiveTransportAccountingSnapshot(queryId: queryID))
        XCTAssertFalse(messages.isArchiveQueryBatchActive(queryId: queryID))
    }
    #endif

    private func assertPostFinalResetPreservesPersistence(
        isSearch: Bool, resetBeforeScheduledCompletion: Bool, receivesFinal: Bool = true
    ) throws {
        let queryID = "post-final-reset-\(UUID().uuidString)"
        let conversation = ArchiveConversationKey(owner: "post-final-owner@example.test",
            jid: "post-final-peer@example.test", conversationType: .regular)
        let account = Account(jid: conversation.owner,
            queue: DispatchQueue(label: "ArchiveWirePreparation-reset-account-\(queryID)"))
        let sent = expectation(description: "query is actually on the wire before reset")
        sent.assertForOverFulfill = false
        let stream = ArchiveWirePreparationStream { sent.fulfill() }
        stream.myJID = XMPPJID(string: conversation.owner, resource: "archive-reset-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let messages = account.messages
        let mam = account.mam
        mam.isExtendedArchiveAvailable = true
        let scheduler = account.xmppTaskScheduler
        defer {
            messages.updateSendingMessagesTimer?.invalidate()
            messages.updateSendingMessagesTimer = nil
        }
        let adapter = MessageArchiveTransportAdapter(account: account,
            materializationResolver: ArchiveWirePreparationResolver(),
            requestTerminalTimeout: 5, persistenceTerminalTimeout: 5)
        let terminal = expectation(description: "post-final old generation receipt completes exactly once")
        let results = ArchiveWirePreparationResults()
        Task {
            do {
                if isSearch {
                    let receipt = try await adapter.searchPage(.init(queryID: queryID,
                        conversation: conversation, query: "reset fixture", connectionGeneration: 29,
                        pageCursor: nil, pageSize: ArchivePageSizing.search), priority: .searchCurrentPage)
                    results.append(.success(receipt.queryID == queryID &&
                        receipt.connectionGeneration == 29 && receipt.finalReceived))
                } else {
                    let request = ArchiveTransportRequest(queryID: queryID, conversation: conversation,
                        locator: .latest, connectionGeneration: 29, pageSize: ArchivePageSizing.initial,
                        contextBefore: ArchivePageSizing.initial, contextAfter: 0,
                        proofFingerprint: "session:29", isUnfiltered: true,
                        producesContinuousCoverage: true)
                    let receipt = try await adapter.request(request, priority: .visibleIntegrity)
                    _ = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
                    results.append(.success(receipt.queryID == queryID &&
                        receipt.connectionGeneration == 29 && receipt.finalReceived))
                }
            } catch { results.append(.failure(error)) }
            terminal.fulfill()
        }
        wait(for: [sent], timeout: 2)
        XCTAssertTrue(mam.callbackQueueContains { $0.elementId == queryID })
        let persistenceHeld = expectation(description: "persistence remains held through raw fin and reset")
        let releasePersistence = DispatchSemaphore(value: 0)
        defer { releasePersistence.signal() }
        messages.queue.async {
            persistenceHeld.fulfill()
            _ = releasePersistence.wait(timeout: .now() + 5)
        }
        wait(for: [persistenceHeld], timeout: 1)

        let releaseScheduler = DispatchSemaphore(value: 0)
        defer { releaseScheduler.signal() }
        if resetBeforeScheduledCompletion {
            let schedulerHeld = expectation(description: "scheduler queue held before reset and completion")
            scheduler.enqueue(priority: .interactive, resource: .other(queryID), deduplicationKey: nil) { finish in
                schedulerHeld.fulfill()
                _ = releaseScheduler.wait(timeout: .now() + 5)
                finish()
            }
            wait(for: [schedulerHeld], timeout: 1)
            // This reset is queued first, but cannot execute yet. The raw fin
            // below synchronously transfers ownership to persistence before
            // scheduler.reset gets its turn and invokes unavailable callbacks.
            scheduler.reset()
        }
        if receivesFinal {
            let final = try XMPPIQ(from: XCTUnwrap(DDXMLDocument(xmlString: """
            <iq type='result' id='\(queryID)'>
              <fin xmlns='urn:xmpp:mam:2' queryid='\(queryID)' complete='true'>
                <set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set>
              </fin>
            </iq>
            """, options: 0).rootElement()))
            XCTAssertTrue(mam.read(stream, withIQ: final))
            XCTAssertNotNil(mam.archiveTransportAccountingSnapshot(queryId: queryID))
        }
        if resetBeforeScheduledCompletion {
            releaseScheduler.signal()
        } else {
            waitForSchedulerTurn(scheduler, queryID: queryID + "-after-final")
            scheduler.reset()
        }
        waitForSchedulerTurn(scheduler, queryID: queryID + "-after-reset")
        // A stream/module reset preserves proof already sealed by the old fin;
        // it must neither discard the barrier nor relabel this as generation30.
        mam.didResetState()
        pumpRunLoop(until: { !results.values.isEmpty }, timeout: 0.1)
        XCTAssertTrue(results.values.isEmpty,
            "A post-fin scheduler unavailable callback cannot bypass the persistence owner")
        if receivesFinal { XCTAssertNotNil(mam.archiveTransportAccountingSnapshot(queryId: queryID)) }
        releasePersistence.signal()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(results.values.count, 1)
        let outcome = try XCTUnwrap(results.values.first)
        if receivesFinal {
            do {
                XCTAssertTrue(try outcome.get(),
                    "The completed receipt retains its original connection generation")
            } catch {
                XCTFail("Post-final \(isSearch ? "search" : "history") receipt failed after reset: \(error)")
            }
        } else {
            XCTAssertThrowsError(try outcome.get()) {
                XCTAssertEqual($0 as? ArchiveTransportError, .disconnected)
            }
        }
        XCTAssertNil(mam.archiveTransportAccountingSnapshot(queryId: queryID),
            "The transaction terminal retires its sealed proof after reset")
        XCTAssertFalse(messages.isArchiveQueryBatchActive(queryId: queryID))
        XCTAssertFalse(mam.callbackQueueContains { $0.elementId == queryID })
        XCTAssertEqual(stream.queries.count, 1)
    }

    private func waitForSchedulerTurn(_ scheduler: AccountXMPPTaskScheduler, queryID: String) {
        let reached = expectation(description: "scheduler reaches ordered barrier \(queryID)")
        scheduler.enqueue(priority: .interactive, resource: .other(queryID), deduplicationKey: nil) { finish in
            finish()
            reached.fulfill()
        }
        wait(for: [reached], timeout: 1)
    }

    private func assertWirePreparationDoesNotWaitForPriorPersistence(isSearch: Bool) throws {
        let queryID = "wire-preparation-\(UUID().uuidString)"
        let conversation = ArchiveConversationKey(owner: "wire-preparation-owner@example.test",
            jid: "wire-preparation-peer@example.test", conversationType: .regular)
        let account = Account(jid: conversation.owner,
            queue: DispatchQueue(label: "ArchiveWirePreparation-account-\(queryID)"))
        let sent = expectation(description: "real MAM query sent to authenticated fake stream")
        sent.assertForOverFulfill = false
        let stream = ArchiveWirePreparationStream { sent.fulfill() }
        stream.myJID = XMPPJID(string: conversation.owner, resource: "archive-wire-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        // Initialize all account-owned dependencies before the held background
        // operation. The hold represents an earlier Realm persistence chunk.
        let messages = account.messages
        let mam = account.mam
        mam.isExtendedArchiveAvailable = true
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }
        let adapter = MessageArchiveTransportAdapter(account: account,
            materializationResolver: ArchiveWirePreparationResolver(),
            requestTerminalTimeout: 5, persistenceTerminalTimeout: 5)
        let backgroundEntered = expectation(description: "prior background persistence owns the queue")
        let releaseBackground = DispatchSemaphore(value: 0)
        defer { releaseBackground.signal() }
        messages.queue.async {
            backgroundEntered.fulfill()
            _ = releaseBackground.wait(timeout: .now() + 5)
        }
        wait(for: [backgroundEntered], timeout: 1)

        let terminal = expectation(description: "owned receipt finishes after persistence terminal")
        let results = ArchiveWirePreparationResults()
        Task {
            do {
                if isSearch {
                    let receipt = try await adapter.searchPage(.init(queryID: queryID,
                        conversation: conversation, query: "fixture query", connectionGeneration: 19,
                        pageCursor: nil, pageSize: ArchivePageSizing.search), priority: .searchCurrentPage)
                    results.append(.success(receipt.queryID == queryID &&
                        receipt.deliveredResultCount == 0 && receipt.persistedResultCount == 0))
                } else {
                    let request = ArchiveTransportRequest(queryID: queryID, conversation: conversation,
                        locator: .latest, connectionGeneration: 19, pageSize: ArchivePageSizing.initial,
                        contextBefore: ArchivePageSizing.initial, contextAfter: 0,
                        proofFingerprint: "session:19", isUnfiltered: true,
                        producesContinuousCoverage: true)
                    let receipt = try await adapter.request(request, priority: .visibleIntegrity)
                    _ = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
                    results.append(.success(receipt.queryID == queryID && receipt.finalReceived &&
                        receipt.deliveredResultCount == 0 && receipt.persistedResultCount == 0))
                }
            } catch {
                results.append(.failure(error))
            }
            terminal.fulfill()
        }

        // A bounded held resource, rather than a device wall-clock threshold,
        // establishes whether wire preparation has a persistence dependency.
        pumpRunLoop(until: { !stream.queries.isEmpty }, timeout: 0.3)
        let sentBeforePriorPersistenceCompleted = !stream.queries.isEmpty
        releaseBackground.signal()
        wait(for: [sent], timeout: 2)
        XCTAssertTrue(sentBeforePriorPersistenceCompleted,
            "A visible MAM send must not synchronously queue behind an unrelated persistence chunk")
        XCTAssertEqual(stream.queries.count, 1)
        XCTAssertTrue(mam.callbackQueueContains { $0.elementId == queryID })

        // Queue-local bookkeeping is allowed to remain serialized. A matched
        // raw final must still wait for that bookkeeping/persistence barrier.
        let ownPersistenceEntered = expectation(description: "persistence barrier is held after wire send")
        let releaseOwnPersistence = DispatchSemaphore(value: 0)
        defer { releaseOwnPersistence.signal() }
        messages.queue.async {
            ownPersistenceEntered.fulfill()
            _ = releaseOwnPersistence.wait(timeout: .now() + 5)
        }
        wait(for: [ownPersistenceEntered], timeout: 1)
        let final = try XMPPIQ(from: XCTUnwrap(DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryID)'>
          <fin xmlns='urn:xmpp:mam:2' queryid='\(queryID)' complete='true'>
            <set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set>
          </fin>
        </iq>
        """, options: 0).rootElement()))
        XCTAssertTrue(mam.read(stream, withIQ: final))
        pumpRunLoop(until: { !results.values.isEmpty }, timeout: 0.1)
        XCTAssertTrue(results.values.isEmpty,
            "A raw final releases wire capacity without authorizing an unpersisted receipt")
        releaseOwnPersistence.signal()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(results.values.count, 1)
        XCTAssertTrue(try XCTUnwrap(results.values.first).get())
        XCTAssertEqual(stream.queries.count, 1, "Preparing batch metadata must not cause another MAM query")
        XCTAssertFalse(messages.isArchiveQueryBatchActive(queryId: queryID))
        XCTAssertFalse(mam.callbackQueueContains { $0.elementId == queryID })
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 0)
    }

    private func pumpRunLoop(until predicate: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func resetDispatchers() {
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
    }
}

private final class ArchiveWirePreparationStream: XMPPStream {
    private let lock = NSLock()
    private let onQuery: () -> Void
    private var storage: [DDXMLElement] = []

    init(onQuery: @escaping () -> Void) {
        self.onQuery = onQuery
        super.init()
    }

    override var isAuthenticated: Bool { true }

    override func send(_ element: DDXMLElement) {
        guard element.element(forName: "query", xmlns: "urn:xmpp:mam:2") != nil,
              let copy = element.copy() as? DDXMLElement else { return }
        lock.lock()
        storage.append(copy)
        lock.unlock()
        onQuery()
    }

    var queries: [DDXMLElement] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private struct ArchiveWirePreparationResolver: ArchiveMessageMaterializationResolving {
    func materializedMessages(conversation: ArchiveConversationKey,
        archiveIDs: [String]) async throws -> [ArchiveMaterializedMessageIdentity] { [] }
}

private final class ArchiveWirePreparationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<Bool, Error>] = []

    func append(_ value: Result<Bool, Error>) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var values: [Result<Bool, Error>] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
