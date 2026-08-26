import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

private final class MalformedFinalAuthenticatedXMPPStream: XMPPStream {
    override var isAuthenticated: Bool { true }

    override func send(_ element: DDXMLElement) {}
}

private struct EmptyArchiveMaterializationResolver:
    ArchiveMessageMaterializationResolving,
    Sendable
{
    func materializedMessages(
        conversation: ArchiveConversationKey,
        archiveIDs: [String]
    ) async throws -> [ArchiveMaterializedMessageIdentity] {
        []
    }
}

private final class LockedArchiveTransportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResults: [Result<ArchiveTransportReceipt, Error>] = []

    func append(_ result: Result<ArchiveTransportReceipt, Error>) {
        lock.lock()
        storedResults.append(result)
        lock.unlock()
    }

    var results: [Result<ArchiveTransportReceipt, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storedResults
    }
}

private final class LockedArchiveSearchTransportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResults: [Result<ArchiveSearchTransportReceipt, Error>] = []

    func append(_ result: Result<ArchiveSearchTransportReceipt, Error>) {
        lock.lock()
        storedResults.append(result)
        lock.unlock()
    }

    var results: [Result<ArchiveSearchTransportReceipt, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storedResults
    }
}

final class ArchiveTransportReceiptTests: XCTestCase {
    func testServerErrorTransportFailureRemainsAutomaticallyRetryable() {
        XCTAssertTrue(ArchiveTransportError.serverError.isRetryable)
        XCTAssertFalse(ArchiveTransportError.protocolViolation.isRetryable)
    }

    func testUnownedIQErrorIsNotClaimedOrClassifiedAsMAM() {
        let owner = "unowned-iq-error-owner@example.org"
        let elementID = "unowned-vcard-error"
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        var traceLines: [String] = []
        ChatArchiveDebugTrace.configureForTesting(
            enabled: true,
            sampleEvery: 1,
            sink: { traceLines.append($0) }
        )
        defer {
            ChatArchiveDebugTrace.resetTestingConfiguration()
        }

        XCTAssertFalse(manager.callbackQueueContains { $0.elementId == elementID })
        XCTAssertFalse(manager.queryIds.contains(elementID))
        XCTAssertFalse(
            MessageArchiveEndPageDispatcher.hasHandler(
                owner: owner,
                queryId: elementID
            )
        )

        let unrelatedError = XMPPIQ(
            iqType: .error,
            elementID: elementID
        )

        XCTAssertFalse(manager.read(stream, withIQ: unrelatedError))
        XCTAssertFalse(
            traceLines.contains { $0.contains("event=mamErrorReceived") },
            "An IQ error without archive ownership must remain available to its actual stanza manager"
        )
    }

    func testCrossManagerArchiveErrorPublishesServerFailureInsteadOfSuccessfulEndPage() {
        let owner = "cross-manager-error-owner@example.org"
        let queryID = "cross-manager-archive-error"
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        var endPageEvents: [MessageArchiveEndPageEvent] = []
        var failureEvents: [MessageArchiveRequestFailureEvent] = []
        _ = MessageArchiveEndPageDispatcher.register(
            owner: owner,
            queryId: queryID,
            delivery: .synchronous,
            handler: { endPageEvents.append($0) }
        )
        _ = MessageArchiveRequestFailureDispatcher.register(
            owner: owner,
            queryId: queryID,
            delivery: .synchronous,
            handler: { failureEvents.append($0) }
        )
        let receivingManager = MessageArchiveManager(withOwner: owner)
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(
            string: owner,
            resource: "archive-test_ui_upgrade_task"
        )

        XCTAssertTrue(
            receivingManager.read(
                stream,
                withIQ: XMPPIQ(iqType: .error, elementID: queryID)
            )
        )
        XCTAssertTrue(endPageEvents.isEmpty)
        XCTAssertEqual(failureEvents.count, 1)
        XCTAssertEqual(failureEvents.first?.queryId, queryID)
        XCTAssertEqual(failureEvents.first?.reason, .serverError)
        XCTAssertEqual(failureEvents.first?.streamKind, .uiAction)
    }

    func testFallbackOwnedArchiveErrorInvokesFailureCallbackAndNeverEndPageCallback() {
        let owner = "fallback-owned-error-owner@example.org"
        let queryID = "fallback-owned-archive-error"
        let requestManager = MessageArchiveManager(withOwner: owner)
        let receivingManager = MessageArchiveManager(withOwner: owner)
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "ui-action-test")
        let failure = expectation(description: "fallback request reports failure")
        let endPage = expectation(description: "error never reports an end page")
        endPage.isInverted = true
        var receivedFailure: MessageArchiveRequestFailureEvent?
        defer {
            _ = requestManager.cancelPendingArchiveRequest(queryId: queryID)
        }

        requestManager.requestArchive(
            stream,
            jid: "juliet@example.org",
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryID,
            requestCallbacks: .init(
                onEndPage: { _, _, _, _, _ in endPage.fulfill() },
                onFailure: { event in
                    receivedFailure = event
                    failure.fulfill()
                }
            )
        )

        XCTAssertTrue(
            receivingManager.read(
                stream,
                withIQ: XMPPIQ(iqType: .error, elementID: queryID)
            )
        )
        wait(for: [failure, endPage], timeout: 0.25)
        XCTAssertEqual(receivedFailure?.queryId, queryID)
        XCTAssertEqual(receivedFailure?.reason, .serverError)
    }

    func testLocalQueryOwnedErrorPublishesFailureAndClearsQueryWithoutSyntheticEndPage() {
        let owner = "local-query-error-owner@example.org"
        let queryID = "local-query-owned-error"
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        manager.queryIds.insert(queryID)
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        var failureEvents: [MessageArchiveRequestFailureEvent] = []
        _ = MessageArchiveRequestFailureDispatcher.register(
            owner: owner,
            queryId: queryID,
            delivery: .synchronous,
            handler: { failureEvents.append($0) }
        )

        XCTAssertTrue(
            manager.read(
                stream,
                withIQ: XMPPIQ(iqType: .error, elementID: queryID)
            )
        )
        XCTAssertEqual(failureEvents.map(\.reason), [.serverError])
        XCTAssertFalse(manager.queryIds.contains(queryID))
    }

    func testLocalArchiveCallbackErrorNeverBecomesSuccessfulEndPage() {
        let owner = "local-callback-error-owner@example.org"
        let queryID = "local-callback-archive-error"
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        var endPageEvents: [MessageArchiveEndPageEvent] = []
        var failureEvents: [MessageArchiveRequestFailureEvent] = []
        _ = MessageArchiveEndPageDispatcher.register(
            owner: owner,
            queryId: queryID,
            delivery: .synchronous,
            handler: { endPageEvents.append($0) }
        )
        _ = MessageArchiveRequestFailureDispatcher.register(
            owner: owner,
            queryId: queryID,
            delivery: .synchronous,
            handler: { failureEvents.append($0) }
        )
        manager.requestArchive(
            stream,
            jid: "juliet@example.org",
            isContinues: false,
            conversationType: .regular,
            purpose: .jump,
            queryId: queryID
        )

        XCTAssertTrue(
            manager.read(
                stream,
                withIQ: XMPPIQ(iqType: .error, elementID: queryID)
            )
        )
        XCTAssertTrue(endPageEvents.isEmpty)
        XCTAssertEqual(failureEvents.map(\.reason), [.serverError])
        XCTAssertFalse(manager.callbackQueueContains { $0.elementId == queryID })
        XCTAssertFalse(manager.queryIds.contains(queryID))
    }

    func testUnroutedErrorCannotBecomeEndPageAndMapsToServerFailure() throws {
        let owner = "unrouted-error-owner@example.org"
        let queryID = "unrouted-archive-error"
        let iq = XMPPIQ(iqType: .error, elementID: queryID)

        XCTAssertNil(
            MessageArchiveManager.unroutedEndPageEvent(
                owner: owner,
                iq: iq,
                streamKind: .uiAction
            )
        )
        let failure = try XCTUnwrap(
            MessageArchiveManager.unroutedRequestFailureEvent(
                owner: owner,
                iq: iq,
                streamKind: .uiAction
            )
        )
        XCTAssertEqual(failure.queryId, queryID)
        XCTAssertEqual(failure.reason, .serverError)
        XCTAssertEqual(failure.streamKind, .uiAction)
    }

    func testUIActionPreRoutedErrorIsConsumedOnceAfterFailureHandlerRetires() {
        let owner = "ui-action-race-owner@example.org"
        let queryID = "ui-action-race-error"
        let manager = XMPPUIActionManager()
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(
            string: owner,
            resource: "archive-test_ui_upgrade_task"
        )
        manager.stream = stream
        manager.currentJid = owner
        manager.mam = nil
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        var failureEvents: [MessageArchiveRequestFailureEvent] = []
        _ = MessageArchiveRequestFailureDispatcher.register(
            owner: owner,
            queryId: queryID,
            delivery: .synchronous,
            handler: { failureEvents.append($0) }
        )
        let iq = XMPPIQ(iqType: .error, elementID: queryID)

        XCTAssertNotNil(manager.xmppStream(stream, willReceive: iq))
        XCTAssertTrue(manager.xmppStream(stream, didReceive: iq))
        XCTAssertEqual(failureEvents.count, 1)
        XCTAssertEqual(failureEvents.first?.reason, .serverError)
    }

    func testAccountWideSearchAcceptsActualRowConversationIdentity() {
        let scope = ArchiveSearchScope.account(
            owner: "romeo@example.org",
            conversationType: .regular
        )

        XCTAssertTrue(
            ArchiveSearchTransportRowPolicy.accepts(
                owner: "romeo@example.org",
                conversationJID: "favorites.example.org",
                conversationTypeRaw:
                    ClientSynchronizationManager.ConversationType.saved.rawValue,
                for: scope
            )
        )
        XCTAssertFalse(
            ArchiveSearchTransportRowPolicy.accepts(
                owner: "other@example.org",
                conversationJID: "favorites.example.org",
                conversationTypeRaw:
                    ClientSynchronizationManager.ConversationType.saved.rawValue,
                for: scope
            )
        )
    }

    func testConversationSearchRequiresExactJIDAndConversationType() {
        let conversation = ArchiveConversationKey(
            owner: "romeo@example.org",
            jid: "juliet@example.org",
            conversationType: .regular
        )
        let scope = ArchiveSearchScope.conversation(conversation)

        XCTAssertTrue(
            ArchiveSearchTransportRowPolicy.accepts(
                owner: conversation.owner,
                conversationJID: conversation.jid,
                conversationTypeRaw: conversation.conversationTypeRaw,
                for: scope
            )
        )
        XCTAssertFalse(
            ArchiveSearchTransportRowPolicy.accepts(
                owner: conversation.owner,
                conversationJID: conversation.jid,
                conversationTypeRaw:
                    ClientSynchronizationManager.ConversationType.group.rawValue,
                for: scope
            )
        )
    }

    func testAccountWideSearchDedupeIdentityIncludesConversation() throws {
        let first = makeSearchMessage(
            archiveID: "42",
            conversationJID: "juliet@example.org"
        )
        let second = makeSearchMessage(
            archiveID: "42",
            conversationJID: "mercutio@example.org"
        )

        XCTAssertNotEqual(
            try XCTUnwrap(
                ArchiveSearchTransportRowPolicy.identityKey(for: first)
            ),
            try XCTUnwrap(
                ArchiveSearchTransportRowPolicy.identityKey(for: second)
            )
        )
    }

    func testDuplicateSearchFinalDeliveryWaitsForPersistenceAndCompletesExactlyOnce() throws {
        let owner = "duplicate-search-final-owner@example.org"
        let queryID = "duplicate-search-final-page"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-duplicate-search-final"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ArchiveTransportReceiptTests.duplicate-search-final-account"
            )
        )
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver(),
            requestTerminalTimeout: 2,
            persistenceTerminalTimeout: 2
        )
        let request = ArchiveSearchTransportRequest(
            queryID: queryID,
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: "juliet@example.org",
                conversationType: .regular
            ),
            query: "needle",
            connectionGeneration: 1,
            pageCursor: nil,
            pageSize: ArchivePageSizing.search
        )
        let terminal = expectation(
            description: "search adapter reaches one terminal receipt"
        )
        let resultBox = LockedArchiveSearchTransportResult()

        Task {
            let result: Result<ArchiveSearchTransportReceipt, Error>
            do {
                result = .success(
                    try await adapter.searchPage(
                        request,
                        priority: .searchCurrentPage
                    )
                )
            } catch {
                result = .failure(error)
            }
            resultBox.append(result)
            terminal.fulfill()
        }

        let requestDeadline = Date().addingTimeInterval(2)
        while Date() < requestDeadline,
              !account.mam.callbackQueueContains(where: {
                  $0.elementId == queryID
              }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            account.mam.callbackQueueContains {
                $0.elementId == queryID && $0.task.purpose == .engineSearchPage
            }
        )

        let persistenceQueueBlocked = expectation(
            description: "search persistence queue is held behind the final"
        )
        let releasePersistenceQueue = DispatchSemaphore(value: 0)
        defer { releasePersistenceQueue.signal() }
        account.messages.queue.async {
            persistenceQueueBlocked.fulfill()
            releasePersistenceQueue.wait()
        }
        wait(for: [persistenceQueueBlocked], timeout: 1)

        let iq = try XMPPIQ(
            from: XCTUnwrap(
                DDXMLDocument(
                    xmlString: """
                    <iq type='result' id='\(queryID)'>
                      <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'>
                        <set xmlns='http://jabber.org/protocol/rsm'>
                          <count>0</count>
                        </set>
                      </fin>
                    </iq>
                    """,
                    options: 0
                ).rootElement()
            )
        )

        // A final routed first through another stream manager consumes the
        // process-wide fallback callback. The primary manager still owns its
        // local callback and subsequently delivers the same final again.
        let fallbackManager = MessageArchiveManager(withOwner: owner)
        XCTAssertTrue(fallbackManager.read(stream, withIQ: iq))
        XCTAssertTrue(account.mam.read(stream, withIQ: iq))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(
            resultBox.results.isEmpty,
            "A duplicate search final must not fail the transaction while the first delivery waits for persistence"
        )

        releasePersistenceQueue.signal()
        wait(for: [terminal], timeout: 3)

        let results = resultBox.results
        XCTAssertEqual(results.count, 1)
        let receipt = try XCTUnwrap(results.first).get()
        XCTAssertEqual(receipt.queryID, queryID)
        XCTAssertTrue(receipt.finalReceived)
        XCTAssertEqual(receipt.deliveredResultCount, 0)
        XCTAssertEqual(receipt.persistedResultCount, 0)
    }

    private func makeSearchMessage(
        archiveID: String,
        conversationJID: String
    ) -> ArchiveSearchMessage {
        ArchiveSearchMessage(
            primaryID: "\(conversationJID)-\(archiveID)",
            archiveID: archiveID,
            messageID: "message-\(archiveID)",
            owner: "romeo@example.org",
            conversationJID: conversationJID,
            conversationTypeRaw:
                ClientSynchronizationManager.ConversationType.regular.rawValue,
            body: "needle",
            date: Date(timeIntervalSince1970: 1),
            outgoing: false,
            deliveryStateRaw: 0,
            groupAuthorID: nil,
            groupAuthorNickname: nil,
            groupAuthorAvatarURL: nil
        )
    }

    func testDuplicateFinalDeliveryWaitsForPersistenceAndCompletesExactlyOnce() throws {
        let owner = "duplicate-final-owner@example.org"
        let queryID = "duplicate-final-latest-history"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-duplicate-final"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ArchiveTransportReceiptTests.duplicate-final-account"
            )
        )
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver(),
            requestTerminalTimeout: 2,
            persistenceTerminalTimeout: 2
        )
        let request = ArchiveTransportRequest(
            queryID: queryID,
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: "juliet@example.org",
                conversationType: .regular
            ),
            locator: .latest,
            connectionGeneration: 1,
            pageSize: ArchivePageSizing.initial,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "session-proof",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let terminal = expectation(description: "adapter reaches one terminal receipt")
        let resultBox = LockedArchiveTransportResult()

        Task {
            let result: Result<ArchiveTransportReceipt, Error>
            do {
                result = .success(
                    try await adapter.request(request, priority: .visibleIntegrity)
                )
            } catch {
                result = .failure(error)
            }
            resultBox.append(result)
            terminal.fulfill()
        }

        let requestDeadline = Date().addingTimeInterval(2)
        while Date() < requestDeadline,
              !account.mam.callbackQueueContains(where: {
                  $0.elementId == queryID
              }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(account.mam.callbackQueueContains { $0.elementId == queryID })

        let persistenceQueueBlocked = expectation(
            description: "persistence queue is held behind the final"
        )
        let releasePersistenceQueue = DispatchSemaphore(value: 0)
        defer { releasePersistenceQueue.signal() }
        account.messages.queue.async {
            persistenceQueueBlocked.fulfill()
            releasePersistenceQueue.wait()
        }
        wait(for: [persistenceQueueBlocked], timeout: 1)

        let iq = try XMPPIQ(
            from: XCTUnwrap(
                DDXMLDocument(
                    xmlString: """
                    <iq type='result' id='\(queryID)'>
                      <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'>
                        <set xmlns='http://jabber.org/protocol/rsm'>
                          <count>0</count>
                        </set>
                      </fin>
                    </iq>
                    """,
                    options: 0
                ).rootElement()
            )
        )

        XCTAssertTrue(account.mam.read(stream, withIQ: iq))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(
            resultBox.results.isEmpty,
            "The duplicate local final callback must not fail the transaction while the first final waits for persistence"
        )

        releasePersistenceQueue.signal()
        wait(for: [terminal], timeout: 3)

        let results = resultBox.results
        XCTAssertEqual(results.count, 1)
        let receipt = try XCTUnwrap(results.first).get()
        XCTAssertEqual(receipt.queryID, queryID)
        XCTAssertTrue(receipt.finalReceived)
        XCTAssertEqual(receipt.deliveredResultCount, 0)
        XCTAssertEqual(receipt.persistedResultCount, 0)
    }

    func testMissingFinalTimesOutAndReleasesMamSchedulerSlot() {
        let owner = "missing-final-owner@example.org"
        let queryID = "missing-final-latest-history"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-missing-final"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ArchiveTransportReceiptTests.missing-final-account"
            )
        )
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver(),
            requestTerminalTimeout: 0.05,
            persistenceTerminalTimeout: 0.5
        )
        let request = ArchiveTransportRequest(
            queryID: queryID,
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: "juliet@example.org",
                conversationType: .regular
            ),
            locator: .latest,
            connectionGeneration: 1,
            pageSize: ArchivePageSizing.initial,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "session-proof",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let adapterFailed = expectation(
            description: "missing final terminates the adapter continuation"
        )
        let nextMamTaskRan = expectation(
            description: "missing final releases the MAM scheduler slot"
        )
        var receivedError: ArchiveTransportError?

        Task {
            do {
                _ = try await adapter.request(request, priority: .visibleIntegrity)
                XCTFail("A request without final must time out")
            } catch {
                receivedError = error as? ArchiveTransportError
            }
            adapterFailed.fulfill()
        }

        let requestDeadline = Date().addingTimeInterval(2)
        while Date() < requestDeadline,
              !account.mam.callbackQueueContains(where: {
                  $0.elementId == queryID
              }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            account.mam.callbackQueueContains(where: {
                $0.elementId == queryID && $0.task.purpose == .bootstrap
            })
        )

        account.xmppTaskScheduler.enqueue(
            priority: .foreground,
            resource: .mamArchive,
            deduplicationKey: "missing-final-follow-up"
        ) { finish in
            nextMamTaskRan.fulfill()
            finish()
        }

        wait(for: [adapterFailed, nextMamTaskRan], timeout: 2)
        XCTAssertEqual(receivedError, .timeout)
        XCTAssertFalse(account.mam.queryIds.contains(queryID))
        XCTAssertFalse(account.mam.callbackQueueContains { $0.elementId == queryID })
    }

    func testMalformedLatestHistoryFinalFailsAdapterAndReleasesMamSchedulerSlot() throws {
        let owner = "malformed-final-owner@example.org"
        let queryID = "malformed-final-latest-history"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-malformed-final"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ArchiveTransportReceiptTests.malformed-final-account"
            )
        )
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver()
        )
        let request = ArchiveTransportRequest(
            queryID: queryID,
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: "juliet@example.org",
                conversationType: .regular
            ),
            locator: .latest,
            connectionGeneration: 1,
            pageSize: ArchivePageSizing.initial,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "session-proof",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let adapterFailed = expectation(
            description: "malformed final terminates the adapter continuation"
        )
        let nextMamTaskRan = expectation(
            description: "malformed final releases the MAM scheduler slot"
        )
        var receivedError: ArchiveTransportError?

        Task {
            do {
                _ = try await adapter.request(request, priority: .visibleIntegrity)
                XCTFail("A history final without RSM must not create a receipt")
            } catch {
                receivedError = error as? ArchiveTransportError
            }
            adapterFailed.fulfill()
        }

        let requestDeadline = Date().addingTimeInterval(2)
        while Date() < requestDeadline,
              !account.mam.callbackQueueContains(where: {
                  $0.elementId == queryID
              }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            account.mam.callbackQueueContains(where: {
                $0.elementId == queryID && $0.task.purpose == .bootstrap
            }),
            "The latest window must be on the wire as a bootstrap history request"
        )

        account.xmppTaskScheduler.enqueue(
            priority: .foreground,
            resource: .mamArchive,
            deduplicationKey: "malformed-final-follow-up"
        ) { finish in
            nextMamTaskRan.fulfill()
            finish()
        }

        let iq = try XMPPIQ(
            from: XCTUnwrap(
                DDXMLDocument(
                    xmlString: """
                    <iq type='result' id='\(queryID)'>
                      <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'/>
                    </iq>
                    """,
                    options: 0
                ).rootElement()
            )
        )

        XCTAssertTrue(account.mam.read(stream, withIQ: iq))
        wait(for: [adapterFailed, nextMamTaskRan], timeout: 3)
        XCTAssertEqual(receivedError, .protocolViolation)
        XCTAssertFalse(account.mam.queryIds.contains(queryID))
        XCTAssertFalse(account.mam.callbackQueueContains { $0.elementId == queryID })
    }

    func testReconnectGenerationQueuesSameWindowBehindRunningMAMAndCompletesBothContinuations() throws {
        let owner = "reconnect-generation-owner@example.org"
        let oldQueryID = "reconnect-generation-old"
        let newQueryID = "reconnect-generation-new"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-reconnect-generation"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }

        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ArchiveTransportReceiptTests.reconnect-generation-account"
            )
        )
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver()
        )
        let conversation = ArchiveConversationKey(
            owner: owner,
            jid: "juliet@example.org",
            conversationType: .regular
        )
        func request(queryID: String, generation: UInt64) -> ArchiveTransportRequest {
            ArchiveTransportRequest(
                queryID: queryID,
                conversation: conversation,
                locator: .latest,
                connectionGeneration: generation,
                pageSize: ArchivePageSizing.initial,
                contextBefore: 0,
                contextAfter: 0,
                proofFingerprint: "session:\(generation)",
                isUnfiltered: true,
                producesContinuousCoverage: true
            )
        }
        func malformedFinal(queryID: String) throws -> XMPPIQ {
            try XMPPIQ(
                from: XCTUnwrap(
                    DDXMLDocument(
                        xmlString: """
                        <iq type='result' id='\(queryID)'>
                          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'/>
                        </iq>
                        """,
                        options: 0
                    ).rootElement()
                )
            )
        }

        let oldTerminal = expectation(description: "old generation terminal")
        let newTerminal = expectation(description: "new generation terminal")
        var oldError: ArchiveTransportError?
        var newError: ArchiveTransportError?
        Task {
            do {
                _ = try await adapter.request(
                    request(queryID: oldQueryID, generation: 1),
                    priority: .visibleIntegrity
                )
            } catch {
                oldError = error as? ArchiveTransportError
            }
            oldTerminal.fulfill()
        }

        let oldRequestDeadline = Date().addingTimeInterval(2)
        while Date() < oldRequestDeadline,
              !account.mam.callbackQueueContains(where: {
                  $0.elementId == oldQueryID
              }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(account.mam.callbackQueueContains { $0.elementId == oldQueryID })

        Task {
            do {
                _ = try await adapter.request(
                    request(queryID: newQueryID, generation: 2),
                    priority: .visibleIntegrity
                )
            } catch {
                newError = error as? ArchiveTransportError
            }
            newTerminal.fulfill()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(
            account.mam.callbackQueueContains { $0.elementId == newQueryID },
            "The reconnect request must wait behind the old MAM transaction"
        )

        XCTAssertTrue(account.mam.read(stream, withIQ: try malformedFinal(queryID: oldQueryID)))
        let newRequestDeadline = Date().addingTimeInterval(2)
        while Date() < newRequestDeadline,
              !account.mam.callbackQueueContains(where: {
                  $0.elementId == newQueryID
              }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            account.mam.callbackQueueContains { $0.elementId == newQueryID },
            "A new connection generation must not be silently deduplicated"
        )

        XCTAssertTrue(account.mam.read(stream, withIQ: try malformedFinal(queryID: newQueryID)))
        wait(for: [oldTerminal, newTerminal], timeout: 3)
        XCTAssertEqual(oldError, .protocolViolation)
        XCTAssertEqual(newError, .protocolViolation)
    }

    func testTransportRegistersSynchronousRawFinalRouteBeforeMAMSendAndCleansItUp() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/engine/MessageArchiveTransportAdapter.swift"
            ),
            encoding: .utf8
        )
        let transactionStart = try XCTUnwrap(
            source.range(of: "func start(on stream: XMPPStream)")
        )
        let finalHandler = try XCTUnwrap(
            source.range(
                of: "private func handleFinal(",
                range: transactionStart.upperBound..<source.endIndex
            )
        )
        let startBody = String(
            source[transactionStart.lowerBound..<finalHandler.lowerBound]
        )

        let registration = try XCTUnwrap(
            startBody.range(
                of: "MessageArchiveEndPageDispatcher.register("
            )
        )
        let send = try XCTUnwrap(
            startBody.range(of: "account.mam.requestArchive(")
        )
        XCTAssertLessThan(registration.lowerBound, send.lowerBound)
        XCTAssertTrue(startBody.contains("delivery: .synchronous"))
        XCTAssertTrue(source.contains("MessageArchiveEndPageDispatcher.unregister(token)"))
    }

    func testTransportReleasesOptionalEffectsOnlyAfterReceiptContinuation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/engine/MessageArchiveTransportAdapter.swift"
            ),
            encoding: .utf8
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "holdPostPersistenceEffectsUntilArchiveTransportTerminal("
            ).count - 1,
            2,
            "Timeline and engine-search transactions must both own the effects barrier"
        )

        let timelineFinish = try XCTUnwrap(
            source.range(
                of: "private func finish(_ result: Result<ArchiveTransportReceipt, Error>)"
            )
        )
        let timelineTail = source[timelineFinish.lowerBound...]
        let timelineEnd = timelineTail.range(of: "private var purpose:")?.lowerBound
            ?? timelineTail.endIndex
        let timelineMethod = String(timelineTail[..<timelineEnd])
        XCTAssertLessThan(
            try XCTUnwrap(timelineMethod.range(of: "continuationBox.resume")).lowerBound,
            try XCTUnwrap(
                timelineMethod.range(
                    of: "releasePostPersistenceEffectsAfterArchiveTransportTerminal("
                )
            ).lowerBound
        )

        let searchFinish = try XCTUnwrap(
            source.range(
                of: "private func finish(\n        _ result: Result<ArchiveSearchTransportReceipt, Error>"
            )
        )
        let searchMethod = String(source[searchFinish.lowerBound...])
        XCTAssertLessThan(
            try XCTUnwrap(searchMethod.range(of: "continuationBox.resume")).lowerBound,
            try XCTUnwrap(
                searchMethod.range(
                    of: "releasePostPersistenceEffectsAfterArchiveTransportTerminal("
                )
            ).lowerBound
        )
    }

    func testContinuationBoxRetainsTransactionUntilTerminalResume() {
        final class LifetimeProbe {}

        let continuationBox = ArchiveTransportContinuationBox()
        var probe: LifetimeProbe? = LifetimeProbe()
        weak var weakProbe = probe

        continuationBox.retainUntilTerminal(probe!)
        probe = nil

        XCTAssertNotNil(weakProbe)

        continuationBox.resume(throwing: ArchiveTransportError.timeout)

        XCTAssertNil(weakProbe)
    }

    func testPersistenceAccountingAcceptsAlreadyMaterializedDuplicateRows() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3
        summary.skipped = 3

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
                ArchiveMaterializedMessageIdentity(archiveID: "20", primaryID: "p20"),
                ArchiveMaterializedMessageIdentity(archiveID: "30", primaryID: "p30"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 3)
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingStillReportsActualStorageFailure() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3
        summary.savedNew = 2
        summary.failed = 1

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
                ArchiveMaterializedMessageIdentity(archiveID: "20", primaryID: "p20"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 2)
        XCTAssertEqual(accounting.failedPersistenceCount, 1)
    }

    func testPersistenceAccountingAcceptsDurableIdentityAfterCurrentSaveFailure() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 1
        summary.failed = 1

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 1)
        XCTAssertEqual(accounting.messagePrimaryIDs, ["p10"])
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingCountsOnlyConsumedResultsWithoutDurableRows() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: ["10", "20"],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
                ArchiveMaterializedMessageIdentity(archiveID: "30", primaryID: "p30"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 2)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(accounting.messagePrimaryIDs, ["p10", "p30"])
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingTreatsQueryScopedSkippedArchiveIDsAsConsumed() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 2
        summary.skipped = 2
        summary.recordSkippedArchiveId("10")
        summary.recordSkippedArchiveId("20")

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: summary.skippedArchiveIds,
            materializedMessages: []
        )

        XCTAssertEqual(accounting.persistedResultCount, 0)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(accounting.messagePrimaryIDs, [])
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testCanonicalGroupRegularShadowRowsAreConsumedWithoutEnteringGroupTimeline() {
        let group = ArchiveConversationKey(
            owner: "romeo@example.org",
            jid: "stage@example.org",
            conversationType: .group
        )
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 2
        summary.updatedExisting = 2
        summary.recordPersistedArchiveId(
            "10",
            owner: group.owner,
            jid: group.jid,
            conversationType: .regular
        )
        summary.recordPersistedArchiveId(
            "20",
            owner: group.owner,
            jid: group.jid,
            conversationType: .regular
        )

        let consumed = ArchiveTransportShadowConsumptionPolicy.archiveIDs(
            summary: summary,
            conversation: group
        )
        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: consumed,
            materializedMessages: []
        )

        XCTAssertEqual(consumed, ["10", "20"])
        XCTAssertEqual(accounting.persistedResultCount, 0)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingRejectsMissingUnconsumedResult() {
        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: MessageManager.ArchivePersistenceSummary(),
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: ["10"],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 1)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(accounting.failedPersistenceCount, 1)
    }

    func testPersistenceRoutingOverridesConsumptionAcrossDelegates() {
        var consumedFirst = MessageArchiveManager.DeferredArchiveTransportProof()
        consumedFirst.record(resultId: "10")
        consumedFirst.recordIntentionalConsumption(resultId: "10")
        consumedFirst.recordPersistenceRouting(resultId: "10")

        XCTAssertEqual(consumedFirst.intentionallyConsumedResultCount, 0)

        var persistedFirst = MessageArchiveManager.DeferredArchiveTransportProof()
        persistedFirst.record(resultId: "10")
        persistedFirst.recordPersistenceRouting(resultId: "10")
        persistedFirst.recordIntentionalConsumption(resultId: "10")

        XCTAssertEqual(persistedFirst.intentionallyConsumedResultCount, 0)
    }

    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testFlipPageReceiptNormalizesToChronologicalCoverage() throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "300"))
        let request = ArchiveTransportRequest(
            queryID: "q1",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 4,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-1",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: "q1",
            connectionGeneration: 4,
            resultArchiveIDs: ["299", "250", "200"],
            messagePrimaryIDs: ["p299", "p250", "p200"],
            first: "299",
            last: "200",
            complete: false,
            cheapPageCount: 3,
            deliveredResultCount: 3,
            persistedResultCount: 3,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(
            receipt,
            for: request
        )

        XCTAssertEqual(validated.segment?.oldest.rawValue, "200")
        XCTAssertEqual(validated.segment?.newest.rawValue, "299")
        XCTAssertEqual(validated.adjacency, .older(before: boundary))
        XCTAssertEqual(validated.chronologicalArchiveIDs, ["200", "250", "299"])
    }

    func testNewestUnfilteredZeroPageIsAuthoritativeWithoutCounter() throws {
        let request = ArchiveTransportRequest(
            queryID: "q-empty",
            conversation: conversation,
            locator: .latest,
            connectionGeneration: 9,
            pageSize: 80,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-2",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: "q-empty",
            connectionGeneration: 9,
            resultArchiveIDs: [],
            messagePrimaryIDs: [],
            first: "",
            last: "",
            complete: true,
            cheapPageCount: 0,
            deliveredResultCount: 0,
            persistedResultCount: 0,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(
            receipt,
            for: request
        )

        XCTAssertTrue(validated.isAuthoritativeEmpty)
        XCTAssertNil(validated.segment)
    }

    func testCursorOrFilteredZeroPageIsNeverAuthoritativeEmpty() throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let request = ArchiveTransportRequest(
            queryID: "q-cursor-empty",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 2,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-3",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: [],
            messagePrimaryIDs: [],
            first: "",
            last: "",
            complete: true,
            cheapPageCount: 0,
            deliveredResultCount: 0,
            persistedResultCount: 0,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(
            receipt,
            for: request
        )
        XCTAssertFalse(validated.isAuthoritativeEmpty)
    }

    func testRejectsResultBeforeFinalPartialPersistenceAndStaleIdentity() throws {
        let request = ArchiveTransportRequest(
            queryID: "expected",
            conversation: conversation,
            locator: .latest,
            connectionGeneration: 7,
            pageSize: 80,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-4",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )

        var receipt = ArchiveTransportReceipt(
            queryID: "expected",
            connectionGeneration: 7,
            resultArchiveIDs: ["10"],
            messagePrimaryIDs: ["p10"],
            first: "10",
            last: "10",
            complete: true,
            cheapPageCount: 1,
            deliveredResultCount: 1,
            persistedResultCount: 1,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: false
        )
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .missingFinal)
        }

        receipt.finalReceived = true
        receipt.persistedResultCount = 0
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            guard case let .incompletePersistenceAccounting(
                delivered,
                persisted,
                consumed,
                resultArchiveIDs,
                messagePrimaryIDs
            ) = $0 as? ArchiveTransportValidationError else {
                return XCTFail("Expected accounting diagnostics, got \($0)")
            }
            XCTAssertEqual(delivered, 1)
            XCTAssertEqual(persisted, 0)
            XCTAssertEqual(consumed, 0)
            XCTAssertEqual(resultArchiveIDs, 1)
            XCTAssertEqual(messagePrimaryIDs, 1)
        }

        receipt.persistedResultCount = 1
        receipt.queryID = "stale"
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .staleQuery)
        }
    }

    func testRejectsRepeatedOrWrongDirectionCursorAndMalformedIDs() throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
        let request = ArchiveTransportRequest(
            queryID: "q-direction",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 1,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-5",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        var receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ["200"],
            messagePrimaryIDs: ["p200"],
            first: "200",
            last: "200",
            complete: false,
            cheapPageCount: 1,
            deliveredResultCount: 1,
            persistedResultCount: 1,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .nonAdvancingCursor)
        }

        receipt.resultArchiveIDs = ["not-numeric"]
        receipt.first = "not-numeric"
        receipt.last = "not-numeric"
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .malformedArchiveID)
        }
    }

    func testSearchAndExactAnchorRowsNeverProduceTimelineCoverage() throws {
        let anchor = try XCTUnwrap(ArchiveCursor(rawValue: "42"))
        let request = ArchiveTransportRequest(
            queryID: "q-search",
            conversation: conversation,
            locator: .archiveID(anchor),
            connectionGeneration: 1,
            pageSize: 50,
            contextBefore: 30,
            contextAfter: 30,
            proofFingerprint: "sync-6",
            isUnfiltered: false,
            producesContinuousCoverage: false
        )
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ["42"],
            messagePrimaryIDs: ["p42"],
            first: "42",
            last: "42",
            complete: true,
            cheapPageCount: 1,
            deliveredResultCount: 1,
            persistedResultCount: 1,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        XCTAssertNil(validated.segment)
        XCTAssertFalse(validated.isAuthoritativeEmpty)
    }

    func testIncompleteGapPageJoinsTheKnownNewerSegmentForNextCursorAdvance() throws {
        let older = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let newer = try XCTUnwrap(ArchiveCursor(rawValue: "300"))
        let request = ArchiveTransportRequest(
            queryID: "q-gap-page",
            conversation: conversation,
            locator: .gap(olderBoundary: older, newerBoundary: newer),
            connectionGeneration: 11,
            pageSize: ArchivePageSizing.history,
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.history,
            proofFingerprint: "sync-gap",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ["299", "250", "201"],
            messagePrimaryIDs: ["p299", "p250", "p201"],
            first: "299",
            last: "201",
            complete: false,
            cheapPageCount: 3,
            deliveredResultCount: 3,
            persistedResultCount: 3,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let page = try ArchiveTransportReceiptValidator.validate(receipt, for: request)

        XCTAssertEqual(page.segment?.oldest, ArchiveCursor(rawValue: "201"))
        XCTAssertEqual(page.adjacency, .older(before: newer))
        XCTAssertFalse(page.requestComplete)
    }
}
