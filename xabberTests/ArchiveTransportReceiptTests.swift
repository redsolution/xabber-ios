import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

private final class MalformedFinalAuthenticatedXMPPStream: XMPPStream {
    override var isAuthenticated: Bool { true }

    override func send(_ element: DDXMLElement) {}
}

private final class TimestampLookupAuthenticatedXMPPStream: XMPPStream {
    private let sentLock = NSLock()
    private var capturedQueries: [DDXMLElement] = []

    override var isAuthenticated: Bool { true }

    override func send(_ element: DDXMLElement) {
        guard element.element(forName: "query", xmlns: "urn:xmpp:mam:2") != nil,
              let copy = element.copy() as? DDXMLElement else { return }
        sentLock.lock()
        capturedQueries.append(copy)
        sentLock.unlock()
    }

    var queries: [DDXMLElement] {
        sentLock.lock()
        defer { sentLock.unlock() }
        return capturedQueries
    }
}

private struct TimestampLookupFixtureRow {
    let archiveID: String
    let date: Date
}

private final class LockedArchiveReferenceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<ArchiveCursor?, Error>] = []

    func append(_ result: Result<ArchiveCursor?, Error>) {
        lock.lock()
        stored.append(result)
        lock.unlock()
    }

    var results: [Result<ArchiveCursor?, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
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
    func testStanzaReferenceResolutionWaitsForFinAndUsesBoundOuterMAMCursorWithoutLocalRows() throws {
        let result = try stanzaReferenceResolutionFixture()

        XCTAssertEqual(try result.get()?.rawValue, "2002")
    }

    func testStanzaReferenceResolutionRejectsAnUnrelatedReferenceDespiteOwnedQuery() throws {
        let result = try stanzaReferenceResolutionFixture(innerReference: "7003")

        XCTAssertThrowsError(try result.get()) {
            XCTAssertEqual($0 as? ArchiveTransportError, .protocolViolation)
        }
    }

    func testStanzaReferenceResolutionRejectsForeignPeerAndForeignQualifiedIdentity() throws {
        for (peer, by) in [
            ("foreign-peer@example.org", "reference-owner@example.org"),
            ("reference-peer@example.org", "foreign-owner@example.org")
        ] {
            let result = try stanzaReferenceResolutionFixture(innerPeer: peer, qualifiedBy: by)
            XCTAssertThrowsError(try result.get()) {
                XCTAssertEqual($0 as? ArchiveTransportError, .protocolViolation)
            }
        }
    }

    func testStanzaReferenceResolutionRejectsForeignArchiveEnvelope() throws {
        let result = try stanzaReferenceResolutionFixture(archiveOwner: "foreign-owner@example.org")

        XCTAssertThrowsError(try result.get()) {
            XCTAssertEqual($0 as? ArchiveTransportError, .protocolViolation)
        }
    }

    func testStanzaReferenceResolutionDoesNotInventCursorForEmptyOwnedFinal() throws {
        let result = try stanzaReferenceResolutionFixture(hasResult: false)

        XCTAssertNil(try result.get())
    }

    private func stanzaReferenceResolutionFixture(
        innerReference: String = "7002",
        innerPeer: String = "reference-peer@example.org",
        qualifiedBy: String = "reference-owner@example.org",
        archiveOwner: String = "reference-owner@example.org",
        hasResult: Bool = true
    ) throws -> Result<ArchiveCursor?, Error> {
        let owner = "reference-owner@example.org"
        let queryID = "reference-fixture-\(UUID().uuidString)"
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current, inMemoryIdentifier: queryID
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }
        let realm = try Realm()
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 0)
        let account = Account(jid: owner, queue: DispatchQueue(label: queryID))
        let stream = TimestampLookupAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver(),
            requestTerminalTimeout: 2,
            persistenceTerminalTimeout: 2
        )
        let request = ArchiveStanzaReferenceResolutionRequest(
            queryID: queryID,
            conversation: ArchiveConversationKey(
                owner: owner, jid: "reference-peer@example.org", conversationType: .regular
            ),
            reference: "7002",
            connectionGeneration: 1
        )
        let terminal = expectation(description: "reference resolution finishes after its owned final")
        let resultBox = LockedArchiveReferenceResult()
        Task {
            do {
                resultBox.append(.success(try await adapter.resolveStanzaReference(request, priority: .target)))
            } catch {
                resultBox.append(.failure(error))
            }
            terminal.fulfill()
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, stream.queries.isEmpty, resultBox.results.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let iq = stream.queries.first else {
            wait(for: [terminal], timeout: 3)
            XCTFail("A raw stanza reference must issue an owned MAM lookup")
            return try XCTUnwrap(resultBox.results.first)
        }
        XCTAssertTrue(account.mam.callbackQueueContains { $0.elementId == queryID })
        let query = try XCTUnwrap(iq.element(forName: "query", xmlns: "urn:xmpp:mam:2"))
        let form = try XCTUnwrap(query.element(forName: "x", xmlns: "jabber:x:data"))
        let ids = form.elements(forName: "field").first { $0.attributeStringValue(forName: "var") == "ids" }
        XCTAssertEqual(ids?.elements(forName: "value").compactMap(\.stringValue), ["7002"])
        XCTAssertFalse(form.elements(forName: "field").contains {
            ["start", "end"].contains($0.attributeStringValue(forName: "var") ?? "")
        }, "Raw identity resolution must not invent a timestamp")
        let rsm = try XCTUnwrap(query.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm"))
        XCTAssertEqual(rsm.element(forName: "max")?.stringValue, "1")
        if hasResult {
            let message = try XMPPMessage(from: XCTUnwrap(DDXMLDocument(xmlString: """
            <message from='\(archiveOwner)' to='\(owner)/archive-test'>
              <result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='2002'>
                <forwarded xmlns='urn:xmpp:forward:0'>
                  <message xmlns='jabber:client' from='\(innerPeer)' to='\(owner)' type='chat'>
                    <stanza-id xmlns='urn:xmpp:sid:0' by='\(qualifiedBy)' id='\(innerReference)'/>
                  </message>
                  <delay xmlns='urn:xmpp:delay' stamp='2026-10-19T10:32:48.614Z'/>
                </forwarded>
              </result>
            </message>
            """, options: 0).rootElement()))
            XCTAssertTrue(account.mam.recordDeferredArchiveResultDelivery(message))
            // Transport identity may be resolved even when a domain consumer
            // has intentionally consumed the envelope. It grants no coverage.
            XCTAssertTrue(account.mam.recordDeferredArchiveControlConsumption(message))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertTrue(resultBox.results.isEmpty, "A result binding alone cannot bypass matching fin/accounting")
        let boundaries = hasResult ? "<first>2002</first><last>2002</last>" : ""
        let final = try XMPPIQ(from: XCTUnwrap(DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryID)'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'>
            <set xmlns='http://jabber.org/protocol/rsm'>\(boundaries)<count>\(hasResult ? 1 : 0)</count></set>
          </fin>
        </iq>
        """, options: 0).rootElement()))
        XCTAssertTrue(account.mam.read(stream, withIQ: final))
        wait(for: [terminal], timeout: 3)
        XCTAssertEqual(resultBox.results.count, 1)
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 0,
                       "Reference resolution cannot manufacture a materialized message or coverage")
        return try XCTUnwrap(resultBox.results.first)
    }

    func testTimestampLookupFindsIncomingAfterUnreadBoundaryBeyondFullEarlierPages() throws {
        let target = Date(timeIntervalSince1970: 1_792_405_968)
        let earlier = (0..<80).map { index in
            TimestampLookupFixtureRow(
                archiveID: String(1_000 + index),
                date: target.addingTimeInterval(Double(index - 100))
            )
        }
        // The source timestamp has whole-second precision. The known unread
        // boundary and first incoming row are distinct archive identities;
        // neither identity is interpreted as a timestamp.
        let boundary = TimestampLookupFixtureRow(
            archiveID: "2002", date: target.addingTimeInterval(0.614)
        )
        let firstIncoming = TimestampLookupFixtureRow(
            archiveID: "2003", date: target.addingTimeInterval(0.8)
        )
        let nearTarget = [
            TimestampLookupFixtureRow(archiveID: "2000", date: target.addingTimeInterval(0.05)),
            TimestampLookupFixtureRow(archiveID: "2001", date: target.addingTimeInterval(0.4)),
            boundary,
            firstIncoming,
            TimestampLookupFixtureRow(archiveID: "2004", date: target.addingTimeInterval(1))
        ]

        let receipt = try timestampLookupReceipt(
            target: target,
            rows: earlier + nearTarget,
            pageSize: 4
        )

        XCTAssertTrue(receipt.resultArchiveIDs.contains(firstIncoming.archiveID),
                      "A full earlier page must not hide the first incoming row after the unread boundary")
        XCTAssertEqual(receipt.resultArchiveIDs.sorted(), ["2000", "2001", boundary.archiveID, firstIncoming.archiveID])
        XCTAssertEqual(receipt.deliveredResultCount, 4)
        XCTAssertEqual(receipt.persistedResultCount, 4)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0,
                       "Previously decrypted rows still materialize authenticated replay results")
        XCTAssertEqual(receipt.messagePrimaryIDs.count, 4)
        XCTAssertEqual(receipt.failedPersistenceCount, 0)
        XCTAssertTrue(receipt.finalReceived)
    }

    func testTimestampLookupBeyondNewestFallsBackToBoundedNewestEarlierPage() throws {
        let target = Date(timeIntervalSince1970: 1_792_405_968)
        let rows = (0..<80).map { index in
            TimestampLookupFixtureRow(
                archiveID: String(1_000 + index),
                date: target.addingTimeInterval(Double(index - 100))
            )
        }

        let receipt = try timestampLookupReceipt(
            target: target, rows: rows, pageSize: 4, expectedQueryCount: 2
        )

        XCTAssertEqual(receipt.resultArchiveIDs.sorted(), ["1076", "1077", "1078", "1079"],
                       "A timestamp after the archive must choose its nearest earlier rows")
        XCTAssertEqual(receipt.deliveredResultCount, 4)
        XCTAssertEqual(receipt.persistedResultCount, 4)
        XCTAssertTrue(receipt.finalReceived)
    }

    /// Runs the real adapter, registered MAM result accounting, durable replay
    /// materialization, and final barrier. The fixture server selects its page
    /// from the actual transmitted XData/RSM rather than the requested locator.
    private func timestampLookupReceipt(
        target: Date,
        rows: [TimestampLookupFixtureRow],
        pageSize: Int,
        expectedQueryCount: Int = 1
    ) throws -> ArchiveTransportReceipt {
        let queryID = "timestamp-fixture-\(UUID().uuidString)"
        let owner = "timestamp-owner@example.org"
        let peer = "timestamp-peer@example.org"
        let configuration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: queryID
        )
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = configuration
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }
        let retainedRealm = try Realm(configuration: configuration)
        try retainedRealm.write {
            for row in rows {
                let message = MessageStorageItem()
                message.primary = "timestamp-primary-\(row.archiveID)"
                message.owner = owner
                message.opponent = peer
                message.conversationType = .regular
                message.archivedId = row.archiveID
                message.mamArchiveId = row.archiveID
                message.messageId = "timestamp-message-\(row.archiveID)"
                message.date = row.date
                retainedRealm.add(message)
            }
        }
        let account = Account(jid: owner, queue: DispatchQueue(label: queryID))
        let stream = TimestampLookupAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let repository = RealmArchiveCoverageRepository {
            try Realm(configuration: configuration)
        }
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: repository,
            requestTerminalTimeout: 3,
            persistenceTerminalTimeout: 3
        )
        let request = ArchiveTransportRequest(
            queryID: queryID,
            conversation: ArchiveConversationKey(owner: owner, jid: peer, conversationType: .regular),
            locator: .timestamp(target),
            connectionGeneration: 1,
            pageSize: pageSize,
            contextBefore: pageSize / 2,
            contextAfter: pageSize / 2,
            proofFingerprint: "timestamp-proof",
            isUnfiltered: true,
            producesContinuousCoverage: false,
            usesFlippedPage: true
        )
        let terminal = expectation(description: "timestamp lookup reaches its final barrier")
        let resultBox = LockedArchiveTransportResult()
        Task {
            do {
                resultBox.append(.success(try await adapter.request(request, priority: .target)))
            } catch {
                resultBox.append(.failure(error))
            }
            terminal.fulfill()
        }
        var answered = 0
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, resultBox.results.isEmpty {
            let queries = stream.queries
            guard answered < queries.count else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                continue
            }
            let iq = queries[answered]
            answered += 1
            let sentQueryID = try XCTUnwrap(iq.attributeStringValue(forName: "id"))
            let query = try XCTUnwrap(iq.element(forName: "query", xmlns: "urn:xmpp:mam:2"))
            let form = try XCTUnwrap(query.element(forName: "x", xmlns: "jabber:x:data"))
            let fields = Dictionary(uniqueKeysWithValues: form.elements(forName: "field").compactMap { field -> (String, String)? in
                guard let name = field.attributeStringValue(forName: "var"),
                      let value = field.element(forName: "value")?.stringValue else { return nil }
                return (name, value)
            })
            let rsm = try XCTUnwrap(query.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm"))
            let limit = try XCTUnwrap(Int(try XCTUnwrap(rsm.element(forName: "max")?.stringValue)))
            XCTAssertEqual(limit, pageSize, "Both lookup directions must remain bounded")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func dateField(_ name: String) throws -> Date? {
                guard let value = fields[name] else { return nil }
                return try XCTUnwrap(formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value))
            }
            let start = try dateField("start")
            let end = try dateField("end")
            let matching = rows.filter { row in
                (start == nil || row.date >= start!) && (end == nil || row.date <= end!)
            }.sorted { $0.date < $1.date }
            let selected = rsm.element(forName: "before") != nil
                ? Array(matching.suffix(limit)) : Array(matching.prefix(limit))
            for row in selected {
                let message = try XMPPMessage(from: XCTUnwrap(DDXMLDocument(xmlString: """
                <message from='\(owner)' to='\(owner)/archive-test'>
                  <result xmlns='urn:xmpp:mam:2' queryid='\(sentQueryID)' id='\(row.archiveID)'>
                    <forwarded xmlns='urn:xmpp:forward:0'>
                      <message xmlns='jabber:client' from='\(peer)' to='\(owner)' type='chat' id='timestamp-message-\(row.archiveID)'/>
                      <delay xmlns='urn:xmpp:delay' stamp='\(row.date.XMPPFormattedDate)'/>
                    </forwarded>
                  </result>
                </message>
                """, options: 0).rootElement()))
                XCTAssertTrue(account.mam.recordDeferredArchiveResultDelivery(message))
                XCTAssertTrue(account.mam.recordDeferredArchiveControlConsumption(message))
            }
            XCTAssertTrue(resultBox.results.isEmpty,
                          "Even existing authenticated replay rows cannot finish without matching fin")
            let boundaries = selected.isEmpty ? "" : "<first>\(selected.first!.archiveID)</first><last>\(selected.last!.archiveID)</last>"
            let final = try XMPPIQ(from: XCTUnwrap(DDXMLDocument(xmlString: """
            <iq type='result' id='\(sentQueryID)'>
              <fin xmlns='urn:xmpp:mam:2' complete='\(matching.count <= limit)' queryid='\(sentQueryID)'>
                <set xmlns='http://jabber.org/protocol/rsm'>\(boundaries)<count>\(matching.count)</count></set>
              </fin>
            </iq>
            """, options: 0).rootElement()))
            XCTAssertTrue(account.mam.read(stream, withIQ: final))
        }
        wait(for: [terminal], timeout: 1)
        XCTAssertLessThanOrEqual(answered, 2, "A near-time lookup needs at most two bounded queries")
        XCTAssertEqual(answered, expectedQueryCount)
        let queryIDs = stream.queries.compactMap { $0.attributeStringValue(forName: "id") }
        XCTAssertEqual(Set(queryIDs).count, queryIDs.count,
                       "The fallback must not reuse a sealed query identity")
        let receipt = try XCTUnwrap(resultBox.results.first).get()
        XCTAssertEqual(receipt.queryID, request.queryID)
        _ = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        return receipt
    }

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

    func testSearchTransportUsesOnlyVerifiedOuterMAMResultID() {
        let item = MessageStorageItem()
        item.archivedId = "100"

        XCTAssertNil(ArchiveSearchTransportRowPolicy.strictMAMArchiveID(for: item))

        item.mamArchiveId = "200"

        XCTAssertEqual(
            ArchiveSearchTransportRowPolicy.strictMAMArchiveID(for: item),
            "200"
        )

        item.mamArchiveId = "  300  "

        XCTAssertEqual(
            ArchiveSearchTransportRowPolicy.strictMAMArchiveID(for: item),
            "  300  "
        )

        item.mamArchiveId = " \n "

        XCTAssertEqual(ArchiveSearchTransportRowPolicy.strictMAMArchiveID(for: item), " \n ")
    }

    func testMAMReplayDoesNotTreatLegacyRawIDAsOuterResultCollision() throws {
        let owner = "mam-replay-owner@example.org"
        let jid = "juliet@example.org"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-legacy-raw-replay"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }

        let legacy = MessageStorageItem()
        legacy.primary = "legacy-primary"
        legacy.owner = owner
        legacy.opponent = jid
        legacy.conversationType = .regular
        legacy.archivedId = "200"
        legacy.mamArchiveId = ""
        legacy.messageId = "legacy-message"
        legacy.body = "legacy"
        legacy.date = Date(timeIntervalSince1970: 1)
        legacy.sentDate = legacy.date

        let realm = try WRealm.safe()
        try realm.write {
            realm.add(legacy)
        }

        let replay = MessageStorageItem()
        replay.primary = "replay-primary"
        replay.owner = owner
        replay.opponent = jid
        replay.conversationType = .regular
        replay.archivedId = "100"
        replay.mamArchiveId = "200"
        replay.shouldReconcileMAMArchiveIdentity = true
        replay.messageId = "replay-message"
        replay.body = "replayed"
        replay.date = Date(timeIntervalSince1970: 2)
        replay.sentDate = replay.date

        let summary = MessageManager(withOwner: owner, activeStream: false).save(
            MessageManager.ProcessedQueueBatch(
                messages: [replay],
                readStateRequests: []
            ),
            silentNotifications: true
        )

        XCTAssertEqual(summary.persistedRows, 1)
        realm.refresh()
        XCTAssertEqual(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "legacy-primary"
            )?.mamArchiveId,
            ""
        )
        XCTAssertEqual(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "replay-primary"
            )?.mamArchiveId,
            "200"
        )
    }

    func testSearchRowAccumulatorRejectsConflictingPrimaryForSameMAMResultID() {
        var accumulator = ArchiveSearchTransportRowAccumulator()
        let first = makeSearchMessage(
            archiveID: "42",
            conversationJID: "juliet@example.org",
            primaryID: "first-primary"
        )
        let replay = makeSearchMessage(
            archiveID: "42",
            conversationJID: "juliet@example.org",
            primaryID: "first-primary"
        )
        let conflicting = makeSearchMessage(
            archiveID: "42",
            conversationJID: "juliet@example.org",
            primaryID: "conflicting-primary"
        )

        XCTAssertEqual(accumulator.insert(first), .inserted)
        XCTAssertEqual(accumulator.insert(replay), .duplicate)
        XCTAssertEqual(accumulator.insert(conflicting), .conflictingPrimary)
        XCTAssertTrue(accumulator.hasConflictingArchiveIdentity)
        XCTAssertEqual(accumulator.messages, [first])
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

    func testConflictingSearchMAMResultPrimaryFailsAfterPersistenceBarrier() throws {
        let owner = "conflicting-search-result-owner@example.org"
        let queryID = "conflicting-search-result-page"
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveTransportReceiptTests-conflicting-search-result"
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
                label: "ArchiveTransportReceiptTests.conflicting-search-result-account"
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
            description: "conflicting search result reaches a terminal error"
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

        let first = try makeSearchMAMResult(
            owner: owner,
            queryID: queryID,
            resultID: "200",
            stanzaID: "100",
            messageID: "first-message"
        )
        let conflicting = try makeSearchMAMResult(
            owner: owner,
            queryID: queryID,
            resultID: "200",
            stanzaID: "101",
            messageID: "conflicting-message"
        )
        for message in [first, conflicting] {
            XCTAssertTrue(account.mam.recordDeferredArchiveResultDelivery(message))
            XCTAssertTrue(account.mam.readMessage(message))
            XCTAssertTrue(
                account.mam.recordDeferredArchiveControlConsumption(message)
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let final = try XMPPIQ(
            from: XCTUnwrap(
                DDXMLDocument(
                    xmlString: """
                    <iq type='result' id='\(queryID)'>
                      <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'>
                        <set xmlns='http://jabber.org/protocol/rsm'>
                          <count>1</count>
                          <first>200</first>
                          <last>200</last>
                        </set>
                      </fin>
                    </iq>
                    """,
                    options: 0
                ).rootElement()
            )
        )
        XCTAssertTrue(account.mam.read(stream, withIQ: final))

        wait(for: [terminal], timeout: 3)

        let result = try XCTUnwrap(resultBox.results.first)
        guard case .failure(let error) = result else {
            return XCTFail("A conflicting outer MAM result id must not produce a partial page")
        }
        XCTAssertEqual(error as? ArchiveTransportError, .protocolViolation)
    }

    private func makeSearchMessage(
        archiveID: String,
        conversationJID: String,
        primaryID: String? = nil
    ) -> ArchiveSearchMessage {
        ArchiveSearchMessage(
            primaryID: primaryID ?? "\(conversationJID)-\(archiveID)",
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

    private func makeSearchMAMResult(
        owner: String,
        queryID: String,
        resultID: String,
        stanzaID: String,
        messageID: String
    ) throws -> XMPPMessage {
        try XMPPMessage(
            from: XCTUnwrap(
                DDXMLDocument(
                    xmlString: """
                    <message to='\(owner)' from='\(owner)'>
                      <result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(resultID)'>
                        <forwarded xmlns='urn:xmpp:forward:0'>
                          <message xmlns='jabber:client' to='\(owner)' from='juliet@example.org' type='chat' id='\(messageID)'>
                            <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='\(stanzaID)'/>
                            <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(stanzaID)'/>
                            <origin-id xmlns='urn:xmpp:sid:0' id='\(messageID)'/>
                            <body>needle</body>
                          </message>
                          <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-03-31T10:00:00Z'/>
                        </forwarded>
                      </result>
                    </message>
                    """,
                    options: 0
                ).rootElement()
            )
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
                producesContinuousCoverage: true,
            usesFlippedPage: true
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

    func testPersistenceAccountingRejectsDuplicateMaterializedMAMResultID() {
        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: MessageManager.ArchivePersistenceSummary(),
            deliveredArchiveIDs: ["20"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(
                    archiveID: "20",
                    primaryID: "legacy-p20"
                ),
                ArchiveMaterializedMessageIdentity(
                    archiveID: "20",
                    primaryID: "replayed-p20"
                )
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 0)
        XCTAssertEqual(accounting.messagePrimaryIDs, [])
        XCTAssertEqual(accounting.failedPersistenceCount, 1)
    }

    func testPersistenceAccountingCountsOnlyConsumedResultsWithoutDurableRows() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: [ArchiveCursor(rawValue: "10")!, ArchiveCursor(rawValue: "20")!],
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

        XCTAssertEqual(consumed, [ArchiveCursor(rawValue: "10")!, ArchiveCursor(rawValue: "20")!])
        XCTAssertEqual(accounting.persistedResultCount, 0)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingRejectsMissingUnconsumedResult() {
        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: MessageManager.ArchivePersistenceSummary(),
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: [ArchiveCursor(rawValue: "10")!],
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
        let opaquePage = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        XCTAssertEqual(opaquePage.chronologicalArchiveIDs, ["not-numeric"])
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
            producesContinuousCoverage: false,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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

final class OpaqueArchiveTransportReceiptTests: XCTestCase {
    func testLegacyPageContinuationUsesExactCursorIdentity() {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        XCTAssertTrue(MessageArchiveManager.archivePageFinalDisposition(
            deliveredResultCount: 1, serverResultCount: nil, complete: false,
            requestedPageCursor: composed, responseLastCursor: decomposed).shouldContinue)
        XCTAssertFalse(MessageArchiveManager.archivePageFinalDisposition(
            deliveredResultCount: 1, serverResultCount: nil, complete: false,
            requestedPageCursor: composed, responseLastCursor: composed).shouldContinue)
    }
    private let conversation = ArchiveConversationKey(owner: "owner@example.org", jid: "peer@example.org", conversationType: .regular)

    func testPersistenceSummaryAndAccountingKeepCanonicallyEquivalentUIDsDistinct() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        var summary = MessageManager.ArchivePersistenceSummary()
        var merged = MessageManager.ArchivePersistenceSummary()
        for (id, recordInFirst) in [(composed, true), (decomposed, false)] {
            if recordInFirst {
                summary.recordSkippedArchiveId(id)
                summary.recordPersistedArchiveId(id, owner: conversation.owner,
                    jid: conversation.jid, conversationType: .regular)
            } else {
                merged.recordSkippedArchiveId(id)
                merged.recordPersistedArchiveId(id, owner: conversation.owner,
                    jid: conversation.jid, conversationType: .regular)
            }
        }
        summary.merge(merged)
        XCTAssertEqual(summary.skippedArchiveIds.count, 2)
        XCTAssertEqual(summary.persistedArchiveIdCount(owner: conversation.owner,
            jid: conversation.jid, conversationType: .regular), 2)

        let bothMaterialized = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: [composed, decomposed], explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: composed, primaryID: "p-composed"),
                ArchiveMaterializedMessageIdentity(archiveID: decomposed, primaryID: "p-decomposed"),
            ])
        XCTAssertEqual(bothMaterialized.messagePrimaryIDs, ["p-composed", "p-decomposed"])
        XCTAssertEqual(bothMaterialized.persistedResultCount, 2)
        XCTAssertEqual(bothMaterialized.failedPersistenceCount, 0)

        let oneConsumed = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: [composed, decomposed],
            explicitlyConsumedArchiveIDs: [ArchiveCursor(rawValue: decomposed)!],
            materializedMessages: [ArchiveMaterializedMessageIdentity(archiveID: composed, primaryID: "p-composed")])
        XCTAssertEqual(oneConsumed.messagePrimaryIDs, ["p-composed"])
        XCTAssertEqual(oneConsumed.persistedResultCount, 1)
        XCTAssertEqual(oneConsumed.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(oneConsumed.failedPersistenceCount, 0)
    }

    func testSearchContinuationDistinguishesCanonicalUnicodeEquivalenceFromExactReplay() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let request = ArchiveSearchTransportRequest(queryID: "unicode-search", conversation: conversation,
            query: "needle", connectionGeneration: 7, pageCursor: composed, pageSize: 50)
        func receipt(first: String) -> ArchiveSearchTransportReceipt {
            ArchiveSearchTransportReceipt(queryID: request.queryID, connectionGeneration: 7,
                messages: [], first: first, last: first, complete: false, deliveredResultCount: 1,
                persistedResultCount: 0, failedPersistenceCount: 0, finalReceived: true)
        }
        let page = try ArchiveSearchTransportReceiptValidator.validate(receipt(first: decomposed), for: request)
        XCTAssertEqual(page.continuationCursor.map { Array($0.utf8) }, Array(decomposed.utf8))
        XCTAssertThrowsError(try ArchiveSearchTransportReceiptValidator.validate(receipt(first: composed), for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .nonAdvancingCursor)
        }
    }

    func testSearchAccumulatorKeepsExactUnicodeUIDsSeparateWhileDeduplicatingEach() {
        let ids = ["caf\u{00E9}", "cafe\u{0301}"]
        let messages = ids.enumerated().map { index, id in
            ArchiveSearchMessage(primaryID: "p/\(index)", archiveID: id, messageID: "m/\(index)",
                owner: conversation.owner, conversationJID: conversation.jid,
                conversationTypeRaw: conversation.conversationTypeRaw, body: "needle",
                date: Date(timeIntervalSince1970: 1), outgoing: false, deliveryStateRaw: 0,
                groupAuthorID: nil, groupAuthorNickname: nil, groupAuthorAvatarURL: nil)
        }
        var accumulator = ArchiveSearchTransportRowAccumulator()
        for message in messages { XCTAssertEqual(accumulator.insert(message), .inserted) }
        for message in messages { XCTAssertEqual(accumulator.insert(message), .duplicate) }
        XCTAssertFalse(accumulator.hasConflictingArchiveIdentity)
        XCTAssertEqual(accumulator.messages.map { Array($0.archiveID.utf8) }, ids.map { Array($0.utf8) })
    }

    func testWireProofSeparatesUnicodeUIDsAndTheirConsumptionFromPersistenceRouting() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        var proof = MessageArchiveManager.DeferredArchiveTransportProof()
        for id in [composed, decomposed, composed, decomposed] {
            proof.record(resultId: id)
            proof.recordIntentionalConsumption(resultId: id)
        }
        XCTAssertEqual(proof.deliveredResultCount, 2)
        XCTAssertEqual(proof.deliveredResultIDsInWireOrder.map { Array($0.utf8) },
            [composed, decomposed].map { Array($0.utf8) })
        XCTAssertEqual(proof.intentionallyConsumedResultCount, 2)
        proof.recordPersistenceRouting(resultId: composed)
        proof.recordIntentionalConsumption(resultId: composed)
        XCTAssertEqual(proof.persistenceRoutedResultIds, [ArchiveCursor(rawValue: composed)!])
        XCTAssertEqual(proof.intentionallyConsumedResultIds, [ArchiveCursor(rawValue: decomposed)!])
        XCTAssertEqual(proof.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(proof.deliveredResultCount, 2)
    }

    func testDefaultChronologicalOpaquePageRetainsExactServerOrderAndCompleteness() throws {
        let request = makeRequest(locator: .latest)
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request, ids: ["z", "9", "2", " A "]), for: request)
        XCTAssertEqual(page.chronologicalArchiveIDs, ["z", "9", "2", " A "])
        XCTAssertEqual(page.segment?.orderedArchiveIDs.map(\.rawValue), ["z", "9", "2", " A "])
        XCTAssertTrue(page.segment?.reachesArchiveStart == true)
        XCTAssertTrue(page.segment?.reachesLiveEdge == true)
    }

    func testExplicitFlippedTransmissionUsesRequestOrderRatherThanNumericOrLexicalIDs() throws {
        var request = makeRequest(locator: .older(before: ArchiveCursor(rawValue: "boundary")!))
        request.usesFlippedPage = true
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request, ids: ["a", "2", "9", "z"]), for: request)
        XCTAssertEqual(page.chronologicalArchiveIDs, ["z", "9", "2", "a"])
        XCTAssertEqual(page.segment?.oldest.rawValue, "z")
        XCTAssertEqual(page.segment?.newest.rawValue, "a")
    }

    func testEmptySuccessfulUnknownPageDoesNotInventArchiveEndOrAuthoritativeEmpty() throws {
        let request = makeRequest(locator: .latest)
        var terminal = receipt(request, ids: [])
        terminal.complete = false
        terminal.cheapPageCount = 99
        let page = try ArchiveTransportReceiptValidator.validate(terminal, for: request)
        XCTAssertNil(page.segment)
        XCTAssertFalse(page.isAuthoritativeEmpty)
        XCTAssertFalse(page.requestComplete)
    }

    func testEndpointMismatchAndBoundaryReplayFailWithoutComparingOpaqueIDs() throws {
        let boundary = ArchiveCursor(rawValue: "cursor/z")!
        let request = makeRequest(locator: .older(before: boundary))
        var terminal = receipt(request, ids: ["x", "a"])
        terminal.last = "unrelated"
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(terminal, for: request))
        terminal = receipt(request, ids: ["x", boundary.rawValue])
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(terminal, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .nonAdvancingCursor)
        }
    }

    func testWireIngressProofKeepsFirstDeliveryOrderWhileDeduplicatingRetransmission() {
        var proof = MessageArchiveManager.DeferredArchiveTransportProof()
        for id in ["z", "2", "a", "2", "z"] { proof.record(resultId: id) }
        XCTAssertEqual(proof.deliveredResultCount, 3)
        XCTAssertEqual(proof.deliveredResultIDsInWireOrder, ["z", "2", "a"])
    }

    private func makeRequest(locator: ArchiveWindowLocator) -> ArchiveTransportRequest {
        ArchiveTransportRequest(queryID: "opaque-test", conversation: conversation, locator: locator,
            connectionGeneration: 7, pageSize: 80, contextBefore: 80, contextAfter: 0,
            proofFingerprint: "session:7", isUnfiltered: true, producesContinuousCoverage: true)
    }

    private func receipt(_ request: ArchiveTransportRequest, ids: [String]) -> ArchiveTransportReceipt {
        ArchiveTransportReceipt(queryID: request.queryID, connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ids, messagePrimaryIDs: ids.map { "primary/" + $0 },
            first: ids.first ?? "", last: ids.last ?? "", complete: true, cheapPageCount: ids.count,
            deliveredResultCount: ids.count, persistedResultCount: ids.count, intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0, finalReceived: true)
    }
}
