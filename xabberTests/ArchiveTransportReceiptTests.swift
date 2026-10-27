import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class ArchiveRegularWireProjectionTests: XCTestCase {
    private final class NumericTraceRecorder {
        private let lock = NSLock()
        private var storage: [String] = []
        func record(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    private let conversation = ArchiveConversationKey(owner: "owner@example.com",
        jid: "peer@example.com", conversationType: .regular)
    private var previous: Realm.Configuration!
    private var anchor: Realm!

    override func setUp() {
        super.setUp()
        previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "RegularWireProjection-\(name)")
        anchor = try! Realm()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
    }

    override func tearDown() {
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        anchor = nil
        Realm.Configuration.defaultConfiguration = previous
        super.tearDown()
    }

    private func account(_ query: String) -> (Account, TimestampLookupAuthenticatedXMPPStream) {
        let account = Account(jid: conversation.owner, queue: DispatchQueue(label: query))
        let stream = TimestampLookupAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: conversation.owner, resource: "wire-test")
        account.xmppStream = stream
        account.mam.isExtendedArchiveAvailable = true
        account.sendReadiness.markStreamManagementEnabled()
        return (account, stream)
    }

    private func request(_ query: String, locator: ArchiveWindowLocator = .latest,
        pageSize: Int = 100) -> ArchiveTransportRequest {
        ArchiveTransportRequest(queryID: query, conversation: conversation, locator: locator,
            connectionGeneration: 7, pageSize: pageSize, contextBefore: 0, contextAfter: 0,
            proofFingerprint: "projection-test", isUnfiltered: true,
            producesContinuousCoverage: true, usesFlippedPage: false)
    }

    private func envelope(_ query: String, uid: String, payload: String,
        messageID: String? = nil, from: String? = nil, to: String? = nil,
        outerFrom: String? = nil) throws -> XMPPMessage {
        let xml = """
        <message xmlns='jabber:client' from='\(outerFrom ?? conversation.owner)' to='\(conversation.owner)/wire-test'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(query)' id='\(uid)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(from ?? conversation.jid)' to='\(to ?? conversation.owner)' type='chat' id='\(messageID ?? uid)'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(conversation.owner)' id='\(uid)'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(conversation.owner)' id='\(uid)'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(conversation.owner)' stamp='2026-01-01T00:00:00Z'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='\(messageID ?? uid)'/>
                \(payload)
              </message>
              <delay xmlns='urn:xmpp:delay' stamp='2026-01-01T00:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """
        return XMPPMessage(from: try XCTUnwrap(DDXMLDocument(xmlString: xml, options: 0).rootElement()))
    }

    private func legacy(_ namespace: String = "urn:xmpp:omemo:1") -> String {
        "<encrypted xmlns='\(namespace)'><header sid='1'/><payload>AA==</payload></encrypted><body>legacy fallback</body>"
    }

    private func submit(_ account: Account, _ stream: XMPPStream, query: String,
        binding: MessageArchiveManager.RegularProjectionRequestBinding?, jid: String? = "peer@example.com",
        type: ClientSynchronizationManager.ConversationType = .regular,
        purpose: MessageArchiveManager.RequestPurpose = .bootstrap, ids: [String]? = nil,
        max: Int = 100) {
        account.mam.requestArchive(stream, jid: jid, isContinues: false, conversationType: type,
            purpose: purpose, queryId: query, ids: ids, max: max,
            retainSealedTransportProofUntilBarrier: true, regularProjectionBinding: binding)
    }

    private func assertSubmittedFilter(_ stream: TimestampLookupAuthenticatedXMPPStream,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let query = try XCTUnwrap(stream.queries.last?.element(forName: "query", xmlns: "urn:xmpp:mam:2"),
            file: file, line: line)
        let form = try XCTUnwrap(query.element(forName: "x", xmlns: "jabber:x:data"), file: file, line: line)
        let fields = form.elements(forName: "field")
        XCTAssertEqual(fields.first { $0.attributeStringValue(forName: "var") == "with" }?
            .element(forName: "value")?.stringValue, conversation.jid, file: file, line: line)
        XCTAssertEqual(fields.first { $0.attributeStringValue(forName: "var") == "conversation-type" }?
            .element(forName: "value")?.stringValue, conversation.conversationTypeRaw, file: file, line: line)
    }

    private func start(_ account: Account, stream: TimestampLookupAuthenticatedXMPPStream,
        request: ArchiveTransportRequest) throws -> (XCTestExpectation, LockedArchiveTransportResult) {
        let configuration = Realm.Configuration.defaultConfiguration
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: configuration) }
        let adapter = MessageArchiveTransportAdapter(account: account, materializationResolver: repository,
            requestTerminalTimeout: 15, persistenceTerminalTimeout: 10)
        let terminal = expectation(description: "projection terminal \(request.queryID)")
        let result = LockedArchiveTransportResult()
        Task {
            do { result.append(.success(try await adapter.request(request, priority: .visibleIntegrity))) }
            catch { result.append(.failure(error)) }
            terminal.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !account.mam.callbackQueueContains(where: { $0.elementId == request.queryID }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(account.mam.callbackQueueContains { $0.elementId == request.queryID })
        try assertSubmittedFilter(stream)
        return (terminal, result)
    }

    private func finish(_ account: Account, stream: XMPPStream, query: String,
        ids: [String], complete: Bool) throws {
        let xml = """
        <iq type='result' id='\(query)'><fin xmlns='urn:xmpp:mam:2' queryid='\(query)' complete='\(complete)'>
          <set xmlns='http://jabber.org/protocol/rsm'><first>\(ids.first ?? "")</first><last>\(ids.last ?? "")</last><count>\(ids.count)</count></set>
        </fin></iq>
        """
        let fin = XMPPIQ(from: try XCTUnwrap(DDXMLDocument(xmlString: xml, options: 0).rootElement()))
        XCTAssertTrue(account.mam.read(stream, withIQ: fin))
    }

    private func accounting(_ account: Account, query: String,
        binding: MessageArchiveManager.RegularProjectionRequestBinding,
        generation: UInt64 = 7, qid: String? = nil, scope: ArchiveConversationKey? = nil,
        controls: Set<ArchiveCursor> = []) throws -> ArchiveTransportPersistenceAccounting {
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        return ArchiveTransportPersistenceAccounting.make(summary: .init(),
            deliveredArchiveIDs: snapshot.resultArchiveIDs, explicitlyConsumedArchiveIDs: controls,
            materializedMessages: [], conversation: scope ?? conversation, queryID: qid ?? query,
            connectionGeneration: generation, regularProjectionBinding: binding,
            regularProjectionExclusions: snapshot.regularProjectionExclusions,
            regularProjectionConflicts: snapshot.regularProjectionConflicts)
    }

    private func assertStrictFailure(_ result: ArchiveTransportPersistenceAccounting,
        account: Account, query: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query), file: file, line: line)
        let receipt = ArchiveTransportReceipt(queryID: query, connectionGeneration: 7,
            resultArchiveIDs: snapshot.resultArchiveIDs, messagePrimaryIDs: result.messagePrimaryIDs,
            first: snapshot.resultArchiveIDs.first ?? "", last: snapshot.resultArchiveIDs.last ?? "",
            complete: false, cheapPageCount: snapshot.deliveredResultCount,
            deliveredResultCount: snapshot.deliveredResultCount, persistedResultCount: result.persistedResultCount,
            intentionallyConsumedResultCount: result.intentionallyConsumedResultCount,
            failedPersistenceCount: result.failedPersistenceCount, finalReceived: true)
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request(query)), file: file, line: line) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .persistenceFailure, file: file, line: line)
        }
    }

    func testActualSubmittedRegularWireMixedPageExcludesOnlyOriginalLegacyWithoutMutatingCachedRow() throws {
        let query = "actual-regular-projection"
        let (account, stream) = account(query)
        let cached = MessageStorageItem()
        cached.owner = conversation.owner; cached.opponent = conversation.jid
        cached.messageId = "legacy-cached-origin"; cached.body = "cached legacy body"
        cached.conversationType = .omemo1; cached.mamArchiveId = "old-cached-legacy-uid"
        cached.updatePrimary()
        try anchor.write { anchor.add(cached) }
        let req = request(query)
        let (terminal, result) = try start(account, stream: stream, request: req)
        let first = try envelope(query, uid: "foreign-one", payload: legacy(), messageID: cached.messageId)
        let second = try envelope(query, uid: "foreign-two", payload: legacy("eu.siacs.conversations.axolotl"),
            from: conversation.owner, to: conversation.jid)
        let plain = try envelope(query, uid: "ordinary-one", payload: "<body>ordinary visible</body>")
        for wire in [first, first, second, plain] { account.xmppStream(stream, didReceive: wire) }
        try finish(account, stream: stream, query: query,
            ids: ["foreign-one", "foreign-two", "ordinary-one"], complete: false)
        wait(for: [terminal], timeout: 4)
        let receipt = try XCTUnwrap(result.results.first).get()
        XCTAssertEqual(receipt.deliveredResultCount, 3)
        XCTAssertEqual(receipt.persistedResultCount, 1)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(receipt.failedPersistenceCount, 0)
        XCTAssertNoThrow(try ArchiveTransportReceiptValidator.validate(receipt, for: req))
        anchor.refresh()
        XCTAssertEqual(anchor.objects(MessageStorageItem.self).count, 2)
        XCTAssertEqual(cached.mamArchiveId, "old-cached-legacy-uid")
        XCTAssertEqual(cached.body, "cached legacy body")
        XCTAssertEqual(cached.conversationType, .omemo1)
        XCTAssertTrue(cached.references.isEmpty)
        let summary = account.messages.finishArchiveQueryBatchSummary(queryId: query)
        XCTAssertEqual(summary.received, 1)
        XCTAssertEqual(summary.queued, 1)
        XCTAssertTrue(summary.skippedArchiveIds.isEmpty)
        XCTAssertEqual(anchor.objects(MessageMediaAttachmentStorageItem.self).count, 0)
    }

    func testOriginalForeignWireDoesNotBorrowAnOldRegularRowWithTheSameArchiveUID() throws {
        let query = "projection-cached-regular-overlap"
        let uid = "foreign-cached-uid"
        let (account, stream) = account(query)
        let cached = MessageStorageItem()
        cached.owner = conversation.owner; cached.opponent = conversation.jid
        cached.messageId = "old-ordinary-origin"; cached.body = "old ordinary body"
        cached.conversationType = .regular; cached.mamArchiveId = uid
        cached.updatePrimary()
        try anchor.write { anchor.add(cached) }
        let primary = cached.primary
        let req = request(query)
        let (terminal, result) = try start(account, stream: stream, request: req)

        account.xmppStream(stream, didReceive: try envelope(query, uid: uid, payload: legacy()))
        try finish(account, stream: stream, query: query, ids: [uid], complete: false)
        wait(for: [terminal], timeout: 4)

        let receipt = try XCTUnwrap(result.results.first).get()
        XCTAssertEqual(receipt.persistedResultCount, 0,
            "An old regular row is not evidence for the current foreign original wire")
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(receipt.failedPersistenceCount, 1,
            "Conflicting cached ordinary data needs authoritative repair, not ephemeral exclusion")
        XCTAssertTrue(receipt.messagePrimaryIDs.isEmpty,
            "A foreign wire exclusion must never publish an ordinary row or visible anchor")
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: req)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .persistenceFailure)
        }
        anchor.refresh()
        XCTAssertEqual(anchor.objects(MessageStorageItem.self).count, 1)
        XCTAssertEqual(cached.primary, primary)
        XCTAssertEqual(cached.mamArchiveId, uid)
        XCTAssertEqual(cached.body, "old ordinary body")
        XCTAssertEqual(cached.conversationType, .regular)
        XCTAssertTrue(cached.references.isEmpty)
    }

    func testConflictingOriginalWireCannotBorrowAnExistingMaterializedRegularRow() throws {
        let query = "projection-conflicting-cached-regular"
        let uid = "conflicting-cached-uid"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query,
            conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding)
        for payload in [legacy(), "<body>ordinary conflicting source</body>"] {
            _ = account.mam.observeOriginalArchiveResult(try envelope(query, uid: uid, payload: payload), from: stream)
        }
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        let result = ArchiveTransportPersistenceAccounting.make(summary: .init(),
            deliveredArchiveIDs: snapshot.resultArchiveIDs, explicitlyConsumedArchiveIDs: [],
            materializedMessages: [ArchiveMaterializedMessageIdentity(archiveID: uid, primaryID: "old-ordinary-primary")],
            conversation: conversation, queryID: query, connectionGeneration: 7,
            regularProjectionBinding: binding,
            regularProjectionExclusions: snapshot.regularProjectionExclusions,
            regularProjectionConflicts: snapshot.regularProjectionConflicts)
        XCTAssertEqual(result.failedPersistenceCount, 1)
        XCTAssertEqual(result.persistedResultCount, 0)
        XCTAssertTrue(result.messagePrimaryIDs.isEmpty)
        try assertStrictFailure(result, account: account, query: query)
    }

    func testActualSubmittedRegularOMEMO2WireIsExcludedBeforeCryptoAndPersistenceIngress() throws {
        let query = "actual-regular-omemo2-projection"
        let (account, stream) = account(query)
        let req = request(query)
        let (terminal, result) = try start(account, stream: stream, request: req)
        let plain = try envelope(query, uid: "ordinary-visible", payload: "<body>ordinary visible</body>")
        let omemo2 = try envelope(query, uid: "foreign-omemo2", payload: legacy("urn:xmpp:omemo:2"))
        let eme = try envelope(query, uid: "foreign-omemo2-eme", payload: legacy("urn:xmpp:omemo:2") +
            "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:2'/>")

        for wire in [omemo2, eme, plain] { account.xmppStream(stream, didReceive: wire) }
        try finish(account, stream: stream, query: query,
            ids: ["foreign-omemo2", "foreign-omemo2-eme", "ordinary-visible"], complete: false)
        wait(for: [terminal], timeout: 4)

        let receipt = try XCTUnwrap(result.results.first).get()
        XCTAssertEqual(receipt.deliveredResultCount, 3)
        XCTAssertEqual(receipt.persistedResultCount, 1)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(receipt.failedPersistenceCount, 0)
        XCTAssertNoThrow(try ArchiveTransportReceiptValidator.validate(receipt, for: req))
        anchor.refresh()
        XCTAssertEqual(anchor.objects(MessageStorageItem.self).count, 1)
        XCTAssertEqual(anchor.objects(MessageStorageItem.self).first?.mamArchiveId, "ordinary-visible")
        let summary = account.messages.finishArchiveQueryBatchSummary(queryId: query)
        XCTAssertEqual(summary.received, 1, "OMEMO2 must stop before crypto/persistence ingress in this ordinary projection")
        XCTAssertEqual(summary.queued, 1)
        XCTAssertTrue(summary.skippedArchiveIds.isEmpty)
        XCTAssertEqual(anchor.objects(MessageMediaAttachmentStorageItem.self).count, 0)
    }

    func testActualTimestampLookupProjectsKnownForeignWireWithoutClaimingContinuousCoverage() throws {
        let query = "actual-timestamp-regular-projection"
        let (account, stream) = account(query)
        let req = ArchiveTransportRequest(queryID: query, conversation: conversation,
            locator: .timestamp(Date(timeIntervalSince1970: 1767225600)), connectionGeneration: 7,
            pageSize: 60, contextBefore: 30, contextAfter: 30,
            proofFingerprint: "timestamp-projection", isUnfiltered: false,
            producesContinuousCoverage: false)
        let (terminal, result) = try start(account, stream: stream, request: req)
        let foreign = ["urn:xmpp:omemo:2", "urn:xmpp:omemo:1", "eu.siacs.conversations.axolotl"]
        for (index, namespace) in foreign.enumerated() {
            account.xmppStream(stream, didReceive: try envelope(query,
                uid: "timestamp-foreign-\(index)", payload: legacy(namespace)))
        }
        account.xmppStream(stream, didReceive: try envelope(query,
            uid: "timestamp-ordinary", payload: "<body>ordinary timestamp anchor</body>"))
        try finish(account, stream: stream, query: query,
            ids: ["timestamp-foreign-0", "timestamp-foreign-1", "timestamp-foreign-2", "timestamp-ordinary"],
            complete: false)
        wait(for: [terminal], timeout: 4)

        let receipt = try XCTUnwrap(result.results.first).get()
        XCTAssertEqual(receipt.persistedResultCount, 1)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 3)
        XCTAssertEqual(receipt.failedPersistenceCount, 0)
        let page = try ArchiveTransportReceiptValidator.validate(receipt, for: req)
        XCTAssertNil(page.segment, "Typed timestamp projection does not prove continuous coverage")
        XCTAssertFalse(page.isAuthoritativeEmpty)
        XCTAssertEqual(page.messagePrimaryIDs.count, 1)
        anchor.refresh()
        XCTAssertEqual(anchor.objects(MessageStorageItem.self).count, 1)
        XCTAssertEqual(anchor.objects(MessageStorageItem.self).first?.mamArchiveId, "timestamp-ordinary")
        let summary = account.messages.finishArchiveQueryBatchSummary(queryId: query)
        XCTAssertEqual(summary.received, 1)
        XCTAssertEqual(summary.queued, 1)
    }

    func testOtherNonCoverageRequestCannotAcquireTimestampProjectionEligibility() throws {
        let query = "noncoverage-latest-not-timestamp"
        let (account, stream) = account(query)
        let req = ArchiveTransportRequest(queryID: query, conversation: conversation,
            locator: .latest, connectionGeneration: 7, pageSize: 1, contextBefore: 0, contextAfter: 0,
            proofFingerprint: "noncoverage-utility", isUnfiltered: false,
            producesContinuousCoverage: false)
        let (terminal, result) = try start(account, stream: stream, request: req)
        account.xmppStream(stream, didReceive: try envelope(query, uid: "foreign-unleased", payload: legacy()))
        try finish(account, stream: stream, query: query, ids: ["foreign-unleased"], complete: true)
        wait(for: [terminal], timeout: 4)

        let receipt = try XCTUnwrap(result.results.first).get()
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(receipt.failedPersistenceCount, 1)
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: req)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .persistenceFailure)
        }
    }

    func testAllForeignIncompletePageThenOneOlderOrdinaryPageAdvancesOnlyObservedCursor() throws {
        let (account, stream) = account("all-foreign-projection")
        let firstRequest = request("all-foreign-first")
        let (firstTerminal, firstResult) = try start(account, stream: stream, request: firstRequest)
        for uid in ["foreign-A", "foreign-B"] {
            account.xmppStream(stream, didReceive: try envelope(firstRequest.queryID, uid: uid, payload: legacy()))
        }
        try finish(account, stream: stream, query: firstRequest.queryID, ids: ["foreign-A", "foreign-B"], complete: false)
        wait(for: [firstTerminal], timeout: 4)
        let first = try XCTUnwrap(firstResult.results.first).get()
        XCTAssertEqual(first.deliveredResultCount, 2)
        XCTAssertEqual(first.persistedResultCount, 0)
        XCTAssertEqual(first.intentionallyConsumedResultCount, 2)
        XCTAssertFalse(first.complete)
        XCTAssertNoThrow(try ArchiveTransportReceiptValidator.validate(first, for: firstRequest))
        let secondRequest = request("all-foreign-next", locator: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: first.first))))
        let (secondTerminal, secondResult) = try start(account, stream: stream, request: secondRequest)
        account.xmppStream(stream, didReceive: try envelope(secondRequest.queryID, uid: "older-ordinary", payload: "<body>older visible</body>"))
        try finish(account, stream: stream, query: secondRequest.queryID, ids: ["older-ordinary"], complete: true)
        wait(for: [secondTerminal], timeout: 4)
        let second = try XCTUnwrap(secondResult.results.first).get()
        XCTAssertEqual(second.persistedResultCount, 1)
        XCTAssertEqual(second.intentionallyConsumedResultCount, 0)
        XCTAssertNoThrow(try ArchiveTransportReceiptValidator.validate(second, for: secondRequest))
        XCTAssertEqual(stream.queries.count, 2, "No hidden request loop")
        XCTAssertEqual(stream.queries.last?.element(forName: "query", xmlns: "urn:xmpp:mam:2")?
            .element(forName: "set", xmlns: "http://jabber.org/protocol/rsm")?
            .element(forName: "before")?.stringValue, first.first)
    }

    func testOriginalWireWitnessRequiresSubmittedRegularFilterAndMatchingLease() throws {
        for variant in 0..<9 {
            let query = "lease-negative-\(variant)"
            let (account, stream) = account(query)
            let normal = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query,
                conversation: conversation, connectionGeneration: 7)
            var binding: MessageArchiveManager.RegularProjectionRequestBinding? = normal
            if variant == 0 { account.mam.isExtendedArchiveAvailable = false }
            if variant == 1 { binding = nil }
            if variant == 2 { binding = .init(queryID: "wrong-query", conversation: conversation, connectionGeneration: 7) }
            if variant == 3 { binding = .init(queryID: query, conversation: .init(owner: "other@example.com", jid: conversation.jid, conversationType: .regular), connectionGeneration: 7) }
            if variant == 4 { binding = .init(queryID: query, conversation: .init(owner: conversation.owner, jid: "other@example.com", conversationType: .regular), connectionGeneration: 7) }
            submit(account, stream, query: query, binding: binding, jid: variant == 5 ? nil : conversation.jid,
                type: variant == 6 ? .omemo1 : .regular, purpose: variant == 7 ? .engineSearchPage : .bootstrap,
                ids: variant == 8 ? ["filtered-target"] : nil)
            let wire = try envelope(query, uid: "foreign", payload: legacy())
            XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(wire, from: stream), .excludedRegularProjection)
            XCTAssertTrue(try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query)).regularProjectionExclusions.isEmpty)
            account.mam.abortDeferredCommit(queryId: query)
        }
    }

    func testUnknownNestedEMEAndConflictingScopeCannotMintOriginalWireWitness() throws {
        let previousType = CommonConfigManager.shared.config.locked_conversation_type
        CommonConfigManager.shared.config.locked_conversation_type = ClientSynchronizationManager.ConversationType.omemo1.rawValue
        defer { CommonConfigManager.shared.config.locked_conversation_type = previousType }
        let payloads = [
            "<body>ordinary missing</body>",
            legacy("urn:xabber:test:unknown"),
            "<opaque xmlns='urn:xabber:test:wrapper'>\(legacy("urn:xmpp:omemo:2"))</opaque>",
            "<opaque xmlns='urn:xabber:test:wrapper'>\(legacy())</opaque>",
            "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:1'/>",
            legacy() + "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:2'/>",
            legacy() + legacy("eu.siacs.conversations.axolotl"),
            legacy("urn:xmpp:omemo:2") + "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:1'/>",
            legacy("urn:xmpp:omemo:2") + "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:2'/><encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:2'/>",
            legacy("urn:xmpp:omemo:2") + legacy()
        ]
        for (index, payload) in payloads.enumerated() {
            let query = "wire-negative-\(index)"
            let (account, stream) = account(query)
            let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query,
                conversation: conversation, connectionGeneration: 7)
            submit(account, stream, query: query, binding: binding)
            XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: "missing", payload: payload), from: stream), .excludedRegularProjection)
            let result = try accounting(account, query: query, binding: binding)
            XCTAssertEqual(result.intentionallyConsumedResultCount, 0)
            XCTAssertEqual(result.failedPersistenceCount, 1)
            try assertStrictFailure(result, account: account, query: query)
        }
        for variant in 0..<4 {
            let query = "wire-scope-negative-\(variant)"
            let (account, stream) = account(query)
            let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
            submit(account, stream, query: query, binding: binding)
            let wire = try envelope(query, uid: "missing", payload: legacy(),
                from: variant == 0 ? "other@example.com" : nil,
                to: variant == 1 ? "other@example.com" : nil,
                outerFrom: variant == 2 ? "other@example.com" : nil)
            let sender: XMPPStream = variant == 3 ? TimestampLookupAuthenticatedXMPPStream() : stream
            XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(wire, from: sender), .excludedRegularProjection)
            XCTAssertTrue(try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query)).regularProjectionExclusions.isEmpty)
        }
    }

    func testScopedOriginalWitnessCannotCrossGenerationQueryPeerOrRequestToken() throws {
        let query = "scope-accounting-witness"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding)
        XCTAssertEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: "foreign", payload: legacy()), from: stream), .excludedRegularProjection)
        XCTAssertEqual(try accounting(account, query: query, binding: binding).intentionallyConsumedResultCount, 1)
        let wrongToken = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
        for result in [try accounting(account, query: query, binding: binding, generation: 8),
            try accounting(account, query: query, binding: binding, qid: "wrong-query"),
            try accounting(account, query: query, binding: binding, scope: .init(owner: conversation.owner, jid: "other@example.com", conversationType: .regular)),
            try accounting(account, query: query, binding: wrongToken),
            try accounting(account, query: query, binding: binding, scope: .init(owner: conversation.owner, jid: conversation.jid, conversationType: .omemo1))] {
            XCTAssertEqual(result.intentionallyConsumedResultCount, 0)
            XCTAssertEqual(result.failedPersistenceCount, 1)
            try assertStrictFailure(result, account: account, query: query)
        }
        account.mam.abortDeferredCommit(queryId: query)
        XCTAssertNil(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        account.mam.didResetState()
        XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: "foreign", payload: legacy()), from: stream), .excludedRegularProjection)
    }

    func testConflictingDuplicateUIDRevokesForeignWitnessInEitherOriginalWireOrder() throws {
        for foreignFirst in [false, true] {
            let query = "conflicting-wire-uid-\(foreignFirst)"
            let (account, stream) = account(query)
            let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
            submit(account, stream, query: query, binding: binding)
            let foreign = try envelope(query, uid: "same-wire-uid", payload: legacy())
            let missingOrdinary = try envelope(query, uid: "same-wire-uid", payload: "<body>ordinary failed persistence</body>")
            for wire in foreignFirst ? [foreign, missingOrdinary] : [missingOrdinary, foreign] {
                _ = account.mam.observeOriginalArchiveResult(wire, from: stream)
            }
            let result = try accounting(account, query: query, binding: binding,
                controls: [try XCTUnwrap(ArchiveCursor(rawValue: "same-wire-uid"))])
            XCTAssertEqual(result.intentionallyConsumedResultCount, 0)
            XCTAssertEqual(result.failedPersistenceCount, 1)
            let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
            XCTAssertEqual(snapshot.regularProjectionConflicts.count, 1)
            try assertStrictFailure(result, account: account, query: query)
        }
    }

    func testIdenticalForeignUIDCountsOnceAndUnknownMissingUIDStillFails() throws {
        let query = "wire-duplicate-and-missing"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding)
        let foreign = try envelope(query, uid: "foreign-once", payload: legacy())
        for _ in 0..<2 { XCTAssertEqual(account.mam.observeOriginalArchiveResult(foreign, from: stream), .excludedRegularProjection) }
        _ = account.mam.observeOriginalArchiveResult(try envelope(query, uid: "ordinary-missing", payload: "<body>not persisted</body>"), from: stream)
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        XCTAssertEqual(snapshot.deliveredResultCount, 2)
        let result = try accounting(account, query: query, binding: binding)
        XCTAssertEqual(result.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(result.failedPersistenceCount, 1)
        try assertStrictFailure(result, account: account, query: query)
    }

    func testProjectionSourceAndRecordBudgetsFailClosedWithoutRetainingUnboundedWitnesses() throws {
        let query = "projection-record-budget"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding, max: 2)
        for uid in ["first", "second"] {
            XCTAssertEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: uid, payload: legacy()), from: stream), .excludedRegularProjection)
        }
        XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: "overflow", payload: legacy()), from: stream), .excludedRegularProjection)
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        XCTAssertTrue(snapshot.regularProjectionExclusions.isEmpty)
        XCTAssertEqual(snapshot.regularProjectionConflicts.count, 2)
        try assertStrictFailure(accounting(account, query: query, binding: binding), account: account, query: query)

        let largeQuery = "projection-source-budget"
        let (largeAccount, largeStream) = self.account(largeQuery)
        let largeBinding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: largeQuery, conversation: conversation, connectionGeneration: 7)
        submit(largeAccount, largeStream, query: largeQuery, binding: largeBinding)
        let payload = legacy() + "<opaque xmlns='urn:xabber:test:budget'>" + String(repeating: "x", count: 1_048_576) + "</opaque>"
        XCTAssertNotEqual(largeAccount.mam.observeOriginalArchiveResult(try envelope(largeQuery, uid: "large", payload: payload), from: largeStream), .excludedRegularProjection)
        XCTAssertTrue(try XCTUnwrap(largeAccount.mam.archiveTransportAccountingSnapshot(queryId: largeQuery)).regularProjectionExclusions.isEmpty)
    }

    func testSealedOriginalWireConflictRevokesExclusionBeforeAccounting() throws {
        let query = "sealed-projection-conflict"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query, conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding)
        XCTAssertEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: "same", payload: legacy()), from: stream), .excludedRegularProjection)
        try finish(account, stream: stream, query: query, ids: ["same"], complete: false)
        XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(try envelope(query, uid: "same", payload: "<body>ordinary missing after seal</body>"), from: stream), .excludedRegularProjection)
        let result = try accounting(account, query: query, binding: binding,
            controls: [try XCTUnwrap(ArchiveCursor(rawValue: "same"))])
        XCTAssertEqual(result.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(result.failedPersistenceCount, 1)
        try assertStrictFailure(result, account: account, query: query)
    }

    func testActualSubmitted101OrdinaryRecordsKeepTheirValidReceiptAndNoProjectionConflicts() throws {
        let query = "ordinary-page-over-100"
        let (account, stream) = account(query)
        let req = request(query, pageSize: 101)
        let (terminal, results) = try start(account, stream: stream, request: req)
        let ids = (0..<101).map { "ordinary-\($0)" }
        for uid in ids {
            account.xmppStream(stream, didReceive: try envelope(query, uid: uid, payload: "<body>ordinary visible</body>"))
        }
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        XCTAssertTrue(snapshot.regularProjectionConflicts.isEmpty,
            "The lease must cover the actual submitted page size")
        XCTAssertTrue(snapshot.regularProjectionExclusions.isEmpty)
        XCTAssertEqual(stream.queries.last?.element(forName: "query", xmlns: "urn:xmpp:mam:2")?
            .element(forName: "set", xmlns: "http://jabber.org/protocol/rsm")?
            .element(forName: "max")?.stringValue, "101")
        try finish(account, stream: stream, query: query, ids: ids, complete: false)
        wait(for: [terminal], timeout: 5)
        let receipt = try XCTUnwrap(results.results.first).get()
        XCTAssertEqual(receipt.persistedResultCount, 101)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(receipt.failedPersistenceCount, 0)
        XCTAssertNoThrow(try ArchiveTransportReceiptValidator.validate(receipt, for: req))
    }

    func test101OrdinaryControlsNeverAcquireProjectionConflicts() throws {
        let query = "ordinary-controls-over-100"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query,
            conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding, max: 101)
        let ids = (0..<101).map { "ordinary-control-\($0)" }
        for uid in ids {
            let wire = try envelope(query, uid: uid, payload: "<body>ordinary service control</body>")
            XCTAssertNotEqual(account.mam.observeOriginalArchiveResult(wire, from: stream), .excludedRegularProjection)
            XCTAssertTrue(account.mam.recordDeferredArchiveControlConsumption(wire))
        }
        let snapshot = try XCTUnwrap(account.mam.archiveTransportAccountingSnapshot(queryId: query))
        XCTAssertTrue(snapshot.regularProjectionConflicts.isEmpty)
        let result = try accounting(account, query: query, binding: binding,
            controls: snapshot.intentionallyConsumedArchiveIDs)
        XCTAssertEqual(result.intentionallyConsumedResultCount, 101)
        XCTAssertEqual(result.failedPersistenceCount, 0)
    }

    func testFinalProjectionAdmissionDiagnosticContainsOnlyValidatedNumericCounts() throws {
        let query = "projection-numeric-private-query"
        let (account, stream) = account(query)
        let binding = MessageArchiveManager.RegularProjectionRequestBinding(queryID: query,
            conversation: conversation, connectionGeneration: 7)
        submit(account, stream, query: query, binding: binding)
        XCTAssertEqual(account.mam.observeOriginalArchiveResult(try envelope(query,
            uid: "numeric-private-uid", payload: legacy()), from: stream), .excludedRegularProjection)
        let recorder = NumericTraceRecorder()
        ChatArchiveDebugTrace.configureForTesting(enabled: true, sampleEvery: 1, sink: recorder.record)
        defer { ChatArchiveDebugTrace.resetTestingConfiguration() }

        let result = try accounting(account, query: query, binding: binding)

        XCTAssertEqual(result.intentionallyConsumedResultCount, 1)
        let lines = recorder.lines.filter { $0.contains("event=archiveRegularProjectionAccounting") }
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("excluded=1"))
        XCTAssertTrue(line.contains("conflicts=0"))
        for privateValue in [query, conversation.owner, conversation.jid, "numeric-private-uid",
            "urn:xmpp:omemo:1", "legacy fallback"] {
            XCTAssertFalse(line.contains(privateValue))
        }
    }
}

final class ArchiveLogicalDuplicateAccountingTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "owner@example.com", jid: "peer@example.com", conversationType: .regular)

    private func proof(query: String = "owned-query", scope: ArchiveConversationKey? = nil,
        canonical: String = "A", duplicate: String = "B", primary: String = "pA"
    ) -> MessageManager.ArchiveLogicalDuplicateProof {
        MessageManager.ArchiveLogicalDuplicateProof(queryID: query, conversation: scope ?? conversation,
            canonicalCursor: ArchiveCursor(rawValue: canonical)!,
            duplicateCursor: ArchiveCursor(rawValue: duplicate)!, canonicalPrimaryID: primary)
    }

    private func accounting(_ proofs: [MessageManager.ArchiveLogicalDuplicateProof],
        delivered: [String] = ["A", "B"],
        rows: [ArchiveMaterializedMessageIdentity] = [.init(archiveID: "A", primaryID: "pA")],
        query: String? = "owned-query", hasScope: Bool = true
    ) -> ArchiveTransportPersistenceAccounting {
        var summary = MessageManager.ArchivePersistenceSummary()
        proofs.forEach { summary.recordProvenLogicalDuplicate($0) }
        return ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: delivered, explicitlyConsumedArchiveIDs: [],
            materializedMessages: rows, conversation: hasScope ? conversation : nil, queryID: query)
    }

    private func validate(_ accounting: ArchiveTransportPersistenceAccounting,
        delivered: [String] = ["A", "B"]
    ) throws -> ValidatedArchiveTransportPage {
        let request = ArchiveTransportRequest(queryID: "owned-query", conversation: conversation,
            locator: .latest, connectionGeneration: 1, pageSize: 100, contextBefore: 0,
            contextAfter: 0, proofFingerprint: "test", isUnfiltered: true, producesContinuousCoverage: true)
        return try ArchiveTransportReceiptValidator.validate(ArchiveTransportReceipt(
            queryID: request.queryID, connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: delivered, messagePrimaryIDs: accounting.messagePrimaryIDs,
            first: delivered.first ?? "", last: delivered.last ?? "", complete: true,
            cheapPageCount: delivered.count, deliveredResultCount: delivered.count,
            persistedResultCount: accounting.persistedResultCount,
            intentionallyConsumedResultCount: accounting.intentionallyConsumedResultCount,
            failedPersistenceCount: accounting.failedPersistenceCount, finalReceived: true), for: request)
    }

    private func assertRejected(_ result: ArchiveTransportPersistenceAccounting,
        delivered: [String] = ["A", "B"], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.intentionallyConsumedResultCount, 0, file: file, line: line)
        XCTAssertGreaterThan(result.failedPersistenceCount, 0, file: file, line: line)
        XCTAssertThrowsError(try validate(result, delivered: delivered), file: file, line: line) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .persistenceFailure, file: file, line: line)
        }
    }

    func testProofRegistryMergesWithoutGenericConsumptionOrOutcomeCounters() {
        let witness = proof()
        var first = MessageManager.ArchivePersistenceSummary()
        XCTAssertTrue(first.isEmpty)
        first.recordProvenLogicalDuplicate(witness)
        first.recordProvenLogicalDuplicate(witness)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.provenLogicalDuplicates, [witness])
        XCTAssertTrue(first.skippedArchiveIds.isEmpty)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.processedRows, 0)
        var merged = MessageManager.ArchivePersistenceSummary()
        merged.merge(first)
        merged.merge(first)
        XCTAssertEqual(merged.provenLogicalDuplicates, [witness])
        XCTAssertTrue(merged.skippedArchiveIds.isEmpty)
        XCTAssertEqual(merged.skipped, 0)
    }

    func testCurrentQueryProofWithUniqueMaterializedCanonicalAdmitsTwoWireResults() throws {
        let result = accounting([proof()])
        XCTAssertEqual(result.messagePrimaryIDs, ["pA"])
        XCTAssertEqual(result.persistedResultCount, 1)
        XCTAssertEqual(result.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(result.failedPersistenceCount, 0)
        let page = try validate(result)
        XCTAssertEqual(page.chronologicalArchiveIDs, ["A", "B"])
        XCTAssertEqual(page.messagePrimaryIDs, ["pA"])
        XCTAssertEqual(page.intentionallyConsumedResultCount, 1)
    }

    func testProofCannotCrossQueryOwnerPeerOrConversationType() {
        let invalid = [
            proof(query: "foreign-query"),
            proof(scope: ArchiveConversationKey(owner: "foreign@example.com", jid: conversation.jid, conversationType: .regular)),
            proof(scope: ArchiveConversationKey(owner: conversation.owner, jid: "foreign@example.com", conversationType: .regular)),
            proof(scope: ArchiveConversationKey(owner: conversation.owner, jid: conversation.jid, conversationType: .omemo))
        ]
        invalid.forEach { assertRejected(accounting([$0])) }
        assertRejected(accounting([proof()], query: nil))
        assertRejected(accounting([proof()], hasScope: false))
    }

    func testProofRequiresBothDistinctCursorsInTheCurrentDeliveredPage() {
        assertRejected(accounting([proof()], delivered: ["B"], rows: [.init(archiveID: "A", primaryID: "pA")]), delivered: ["B"])
        assertRejected(accounting([proof()], delivered: ["A", "C"]), delivered: ["A", "C"])
        assertRejected(accounting([proof(canonical: "A", duplicate: "A")]))
    }

    func testProofRequiresCanonicalRowAndExactUnambiguousPrimary() {
        assertRejected(accounting([proof()], rows: []))
        assertRejected(accounting([proof()], rows: [.init(archiveID: "A", primaryID: "wrong-primary")]))
        assertRejected(accounting([proof()], rows: [
            .init(archiveID: "A", primaryID: "pA"), .init(archiveID: "A", primaryID: "conflicting-primary")]))
        assertRejected(accounting([proof(primary: "")], rows: [.init(archiveID: "A", primaryID: "")]))
        let ambiguousDuplicate = accounting([proof()], rows: [
            .init(archiveID: "A", primaryID: "pA"), .init(archiveID: "B", primaryID: "pB"),
            .init(archiveID: "B", primaryID: "conflicting-B")])
        XCTAssertGreaterThan(ambiguousDuplicate.failedPersistenceCount, 0)
        XCTAssertThrowsError(try validate(ambiguousDuplicate))
    }

    func testMaterializedDuplicateIsNeverCountedAsAnAdditionalConsumedResult() throws {
        let result = accounting([proof()], rows: [
            .init(archiveID: "A", primaryID: "pA"), .init(archiveID: "B", primaryID: "pB")])
        XCTAssertEqual(result.persistedResultCount, 2)
        XCTAssertEqual(result.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(result.failedPersistenceCount, 0)
        _ = try validate(result)
    }

    func testProofIdentityAndAccountingKeepExactUTF8TokensDistinct() {
        let composed = "caf\u{00E9}", decomposed = "cafe\u{0301}"
        let tokens = [
            proof(query: composed), proof(query: decomposed),
            proof(primary: composed), proof(primary: decomposed),
            proof(scope: ArchiveConversationKey(owner: composed, jid: conversation.jid, conversationType: .regular)),
            proof(scope: ArchiveConversationKey(owner: decomposed, jid: conversation.jid, conversationType: .regular)),
            proof(scope: ArchiveConversationKey(owner: conversation.owner, jid: composed, conversationType: .regular)),
            proof(scope: ArchiveConversationKey(owner: conversation.owner, jid: decomposed, conversationType: .regular))
        ]
        XCTAssertEqual(Set(tokens).count, tokens.count)
        assertRejected(accounting([proof(query: composed)], query: decomposed))
        assertRejected(accounting([proof(primary: composed)], rows: [.init(archiveID: "A", primaryID: decomposed)]))
        let unicodeCursor = proof(canonical: composed, duplicate: decomposed)
        let cursorResult = accounting([unicodeCursor], delivered: [composed, decomposed],
            rows: [.init(archiveID: composed, primaryID: "pA")])
        XCTAssertEqual(cursorResult.persistedResultCount, 1)
        XCTAssertEqual(cursorResult.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(cursorResult.failedPersistenceCount, 0)
    }
}

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

private final class LockedArchiveAccountingDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ArchiveTransportAccountingDiagnostic] = []

    @Sendable func append(_ value: ArchiveTransportAccountingDiagnostic) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [ArchiveTransportAccountingDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return stored
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
        let accountingDiagnostics = LockedArchiveAccountingDiagnostics()
        let adapter = MessageArchiveTransportAdapter(
            account: account,
            materializationResolver: EmptyArchiveMaterializationResolver(),
            requestTerminalTimeout: 2,
            persistenceTerminalTimeout: 2,
            accountingDiagnosticSink: accountingDiagnostics.append
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
        XCTAssertEqual(accountingDiagnostics.values.count, 1,
            "The actual adapter terminal emits accounting once despite duplicate final delivery")
        let diagnostic = try XCTUnwrap(accountingDiagnostics.values.first)
        XCTAssertEqual(diagnostic.deliveredIDCount, 0)
        XCTAssertEqual(diagnostic.summaryQueued, 0)
        XCTAssertEqual(diagnostic.missingUnaccountedIDCount, 0)
    }

    func testActualRegularAdapterRejectsUnexpectedEncryptedResultsInOrdinaryReply() throws {
        let previous = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(inMemoryIdentifier: "mixed-typed-archive-adapter")
        Realm.Configuration.defaultConfiguration = configuration
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            Realm.Configuration.defaultConfiguration = previous
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }
        let realm = try Realm(configuration: configuration)
        let queryID = "mixed-typed-archive-query"
        let account = Account(jid: conversation.owner, queue: DispatchQueue(label: queryID))
        let stream = MalformedFinalAuthenticatedXMPPStream()
        stream.myJID = XMPPJID(string: conversation.owner, resource: "archive-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: configuration) }
        let diagnostics = LockedArchiveAccountingDiagnostics()
        let adapter = MessageArchiveTransportAdapter(account: account, materializationResolver: repository,
            requestTerminalTimeout: 3, persistenceTerminalTimeout: 3,
            accountingDiagnosticSink: diagnostics.append)
        let request = ArchiveTransportRequest(queryID: queryID, conversation: conversation,
            locator: .latest, connectionGeneration: 1, pageSize: 80, contextBefore: 80,
            contextAfter: 0, proofFingerprint: "session:1", isUnfiltered: true,
            producesContinuousCoverage: true, usesFlippedPage: true)
        let terminal = expectation(description: "mixed typed archive reaches its persistence terminal")
        let results = LockedArchiveTransportResult()
        Task {
            do { results.append(.success(try await adapter.request(request, priority: .visibleIntegrity))) }
            catch { results.append(.failure(error)) }
            terminal.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !account.mam.callbackQueueContains(where: { $0.elementId == queryID }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(account.mam.callbackQueueContains { $0.elementId == queryID })
        let payloads = [
            ("encrypted-id", "encrypted-message", "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/></encrypted>"),
            ("regular-id", "regular-message", "<body>fixture ordinary message</body>")
        ]
        for (archiveID, messageID, payload) in payloads {
            let message = try XMPPMessage(from: XCTUnwrap(DDXMLDocument(xmlString: """
            <message from='\(conversation.owner)' to='\(conversation.owner)/archive-test'>
              <result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(archiveID)'>
                <forwarded xmlns='urn:xmpp:forward:0'>
                  <message xmlns='jabber:client' from='\(conversation.jid)' to='\(conversation.owner)' type='chat' id='\(messageID)'>\(payload)</message>
                  <delay xmlns='urn:xmpp:delay' stamp='2026-10-19T10:32:48.614Z'/>
                </forwarded>
              </result>
            </message>
            """, options: 0).rootElement()))
            XCTAssertTrue(account.mam.recordDeferredArchiveResultDelivery(message))
            account.messages.receiveArchived(message)
        }
        let final = try XMPPIQ(from: XCTUnwrap(DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryID)'><fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'>
          <set xmlns='http://jabber.org/protocol/rsm'><first>encrypted-id</first><last>regular-id</last><count>2</count></set>
        </fin></iq>
        """, options: 0).rootElement()))
        XCTAssertTrue(account.mam.read(stream, withIQ: final))
        wait(for: [terminal], timeout: 4)

        let receipt = try XCTUnwrap(results.results.first).get()
        XCTAssertEqual(receipt.deliveredResultCount, 2)
        XCTAssertEqual(receipt.persistedResultCount, 1)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(receipt.failedPersistenceCount, 1)
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .persistenceFailure)
        }
        let visible = realm.objects(MessageStorageItem.self).filter("conversationType_ == %@", conversation.conversationTypeRaw)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(receipt.messagePrimaryIDs, visible.map(\.primary))
        XCTAssertEqual(realm.objects(MessageStorageItem.self).filter("conversationType_ == %@", ClientSynchronizationManager.ConversationType.omemo.rawValue).count, 1)
        XCTAssertEqual(diagnostics.values.count, 1)
        XCTAssertEqual(diagnostics.values.first?.summaryQueuedWithoutOutcome, 0)
        XCTAssertEqual(diagnostics.values.first?.recognizedSamePeerOMEMOIDCount, 1)
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

    func testPersistenceAccountingDiagnosticsSeparateQueueDropsFromSavedIdentityLoss() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3
        summary.queued = 3
        summary.savedNew = 2
        for archiveID in ["10", "20"] {
            summary.recordPersistedArchiveId(archiveID, owner: conversation.owner,
                jid: conversation.jid, conversationType: conversation.conversationType)
        }

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary, deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10")],
            conversation: conversation)

        let diagnostic = accounting.diagnostic
        XCTAssertEqual(diagnostic.deliveredIDCount, 3)
        XCTAssertEqual(diagnostic.uniqueDeliveredIDCount, 3)
        XCTAssertEqual(diagnostic.matchedMaterializedIDCount, 1)
        XCTAssertEqual(diagnostic.missingUnaccountedIDCount, 2)
        XCTAssertEqual(diagnostic.duplicateMaterializedIDCount, 0)
        XCTAssertEqual(diagnostic.summaryQueuedWithoutOutcome, 1)
        XCTAssertEqual(diagnostic.scopedPersistedIDCount, 2)
        XCTAssertEqual(diagnostic.unaccountedWithScopedPersistedIDCount, 1)
        XCTAssertEqual(accounting.failedPersistenceCount, 2,
            "Diagnostics cannot weaken the strict accounting result")
    }

    func testAccountingDiagnosticsIdentifyOtherTypesOnlyForTheSameOwnerAndPeer() {
        let owner = conversation.owner
        let peer = conversation.jid
        let rows: [(String, String, String, ClientSynchronizationManager.ConversationType)] = [
            ("regular-id", owner, peer, .regular),
            ("omemo-id", owner, peer, .omemo),
            ("omemo1-id", owner, peer, .omemo1),
            ("axolotl-id", owner, peer, .axolotl),
            ("group-id", owner, peer, .group),
            ("saved-id", owner, peer, .saved),
            ("foreign-owner-id", "another-owner@example.org", peer, .omemo),
            ("foreign-peer-id", owner, "another-peer@example.org", .omemo),
        ]
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = rows.count
        summary.queued = rows.count
        summary.updatedExisting = rows.count
        for (archiveID, rowOwner, rowPeer, type) in rows {
            summary.recordPersistedArchiveId(archiveID, owner: rowOwner,
                jid: rowPeer, conversationType: type)
        }

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary, deliveredArchiveIDs: rows.map { $0.0 },
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [ArchiveMaterializedMessageIdentity(
                archiveID: "regular-id", primaryID: "regular-primary")],
            conversation: conversation)

        let diagnostic = accounting.diagnostic
        XCTAssertEqual(diagnostic.recognizedSamePeerOMEMOIDCount, 1)
        XCTAssertEqual(diagnostic.recognizedSamePeerLegacyEncryptedIDCount, 2)
        XCTAssertEqual(diagnostic.recognizedSamePeerGroupIDCount, 1)
        XCTAssertEqual(diagnostic.recognizedSamePeerSavedIDCount, 1)
        XCTAssertEqual(accounting.persistedResultCount, 1)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(accounting.failedPersistenceCount, 7,
            "Other-scope persistence remains diagnostic evidence, never automatic consumption")
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
        XCTAssertEqual(accounting.diagnostic.duplicateMaterializedIDCount, 1)
        XCTAssertEqual(accounting.diagnostic.missingUnaccountedIDCount, 0)
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

    func testRegularArchiveDoesNotRetireForeignOrUnpersistedOrUnrelatedTypedResults() {
        var summary = MessageManager.ArchivePersistenceSummary()
        let excluded: [(String, String, String, ClientSynchronizationManager.ConversationType)] = [
            ("foreign-owner", "foreign@example.org", conversation.jid, .omemo),
            ("foreign-peer", conversation.owner, "foreign@example.org", .omemo),
            ("group", conversation.owner, conversation.jid, .group),
            ("saved", conversation.owner, conversation.jid, .saved),
            ("notification", conversation.owner, conversation.jid, .notifications)
        ]
        for (id, owner, peer, type) in excluded {
            summary.recordPersistedArchiveId(id, owner: owner, jid: peer, conversationType: type)
        }
        let consumed = ArchiveTransportShadowConsumptionPolicy.archiveIDs(
            summary: summary, conversation: conversation)
        let accounting = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: excluded.map { $0.0 } + ["unpersisted-encrypted"],
            explicitlyConsumedArchiveIDs: consumed, materializedMessages: [], conversation: conversation)

        XCTAssertTrue(consumed.isEmpty)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(accounting.failedPersistenceCount, excluded.count + 1)
    }

    func testEncryptedArchiveCannotRetirePlaintextResults() {
        let encrypted = ArchiveConversationKey(owner: conversation.owner,
            jid: conversation.jid, conversationType: .omemo)
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.recordPersistedArchiveId("plain-id", owner: conversation.owner,
            jid: conversation.jid, conversationType: .regular)
        let consumed = ArchiveTransportShadowConsumptionPolicy.archiveIDs(
            summary: summary, conversation: encrypted)
        let accounting = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: ["plain-id"], explicitlyConsumedArchiveIDs: consumed,
            materializedMessages: [], conversation: encrypted)

        XCTAssertTrue(consumed.isEmpty)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(accounting.failedPersistenceCount, 1)
    }

    func testScopeDiagnosticsKeepRecognizedIDsAfterExplicitConsumption() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.recordPersistedArchiveId("encrypted-id", owner: conversation.owner,
            jid: conversation.jid, conversationType: .omemo)
        let accounting = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: ["encrypted-id"],
            explicitlyConsumedArchiveIDs: [ArchiveCursor(rawValue: "encrypted-id")!],
            materializedMessages: [], conversation: conversation)

        XCTAssertEqual(accounting.diagnostic.recognizedSamePeerOMEMOIDCount, 1,
            "The numeric scope classifier must remain visible after explicit domain consumption")
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

final class ArchivePlaintextMAMSourceTests: XCTestCase {
    private let owner = "owner@example.com"
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        id: String = "first-MAM", stamp: String? = nil, body: String = "original source",
        suffix: String = "", metadata: String? = nil, reordered: Bool = false
    ) throws -> XMPPMessage {
        let stamp = stamp ?? date.XMPPFormattedDate
        let triple = metadata ?? """
        <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='\(id)'/>
        <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(id)'/>
        <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(stamp)'/>
        """
        let attributes = reordered
            ? "id='logical-ID' type='chat' to='\(owner)' from='peer@example.com'"
            : "from='peer@example.com' to='\(owner)' type='chat' id='logical-ID'"
        return XMPPMessage(from: try DDXMLElement(xmlString: """
        <message xmlns='jabber:client' \(attributes)>
        \(triple)
        <origin-id xmlns='urn:xmpp:sid:0' id='logical-ID'/><body>\(body)</body>\(suffix)
        </message>
        """))
    }

    private func source(_ message: XMPPMessage, id: String? = "first-MAM", date: Date? = nil) -> ArchivePlaintextMAMSource? {
        ArchivePlaintextMAMSource.make(message: message, archiveOwner: owner,
            expectedArchiveID: id, expectedDate: date ?? self.date)
    }

    func testOriginalSourceIgnoresOnlyCoherentServerDecorationAcrossDifferentArchiveCopies() throws {
        let first = try XCTUnwrap(source(message()))
        let laterDate = date.addingTimeInterval(60)
        let second = try XCTUnwrap(source(message(id: "second-MAM", stamp: laterDate.XMPPFormattedDate),
            id: "second-MAM", date: laterDate))
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 32, "Prepared batch proofs must have a fixed-size memory bound")
        XCTAssertEqual(first.archiveID, ArchiveCursor(rawValue: "first-MAM"))
        XCTAssertEqual(second.archiveID, ArchiveCursor(rawValue: "second-MAM"))
        XCTAssertEqual(first.date, date)
        XCTAssertEqual(second.date, laterDate)
    }

    func testDifferentOriginalBodyAndExtensionPayloadRemainDifferent() throws {
        let first = try XCTUnwrap(source(message()))
        let changedBody = try XCTUnwrap(source(message(body: "another source")))
        let extensionPayload = try XCTUnwrap(source(message(suffix: "<payload xmlns='urn:example:opaque' value='one'/>")))
        let changedExtension = try XCTUnwrap(source(message(suffix: "<payload xmlns='urn:example:opaque' value='two'/>")))
        XCTAssertNotEqual(first.fingerprint, changedBody.fingerprint)
        XCTAssertNotEqual(extensionPayload.fingerprint, changedExtension.fingerprint)
    }

    func testSourceDoesNotDependOnMutableCanonicalArchiveIDOfCachedRow() throws {
        let raw = try message(id: "original-raw-MAM")
        XCTAssertNotNil(source(raw, id: nil))
        XCTAssertNil(source(raw, id: "later-canonical-MAM"))
    }

    func testMalformedForeignOrIncompleteGeneratedMetadataCannotAuthorizeSourceComparison() throws {
        let stamp = date.XMPPFormattedDate
        let archived = "<archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='first-MAM'/>"
        let stanza = "<stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='first-MAM'/>"
        let time = "<time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(stamp)'/>"
        let invalid: [String] = [
            "", archived + stanza,
            archived.replacingOccurrences(of: owner, with: "foreign@example.com") + stanza + time,
            archived + stanza.replacingOccurrences(of: "first-MAM", with: "different-MAM") + time,
            archived + stanza + time.replacingOccurrences(of: owner, with: "foreign@example.com"),
            archived + stanza + time.replacingOccurrences(of: stamp, with: "invalid"),
            archived + stanza + time.replacingOccurrences(of: stamp, with: date.addingTimeInterval(1).XMPPFormattedDate),
            archived.replacingOccurrences(of: "/>", with: " extra='must-preserve'/>") + stanza + time,
            archived + stanza + "<origin-id xmlns='urn:xmpp:sid:0' id='logical-ID'/>" + time,
            archived.replacingOccurrences(of: "/>", with: "><payload/></archived>") + stanza + time
        ]
        for metadata in invalid {
            XCTAssertNil(source(try message(metadata: metadata)), "Unproven metadata must fail closed")
        }
    }

    func testAttributeOrderingAndNamespacePrefixSpellingDoNotInventDifferentSource() throws {
        let original = try XCTUnwrap(source(message()))
        let reordered = try XCTUnwrap(source(message(reordered: true)))
        let prefixXML = """
        <c:message xmlns:c='jabber:client' id='logical-ID' type='chat' from='peer@example.com' to='\(owner)'>
        <m:archived xmlns:m='urn:xmpp:mam:tmp' id='first-MAM' by='\(owner)'/>
        <s:stanza-id xmlns:s='urn:xmpp:sid:0' id='first-MAM' by='\(owner)'/>
        <d:time xmlns:d='https://xabber.com/protocol/delivery' stamp='\(date.XMPPFormattedDate)' by='\(owner)'/>
        <s:origin-id xmlns:s='urn:xmpp:sid:0' id='logical-ID'/><c:body>original source</c:body>
        </c:message>
        """
        let prefixed = try XCTUnwrap(source(XMPPMessage(from: try DDXMLElement(xmlString: prefixXML))))
        XCTAssertEqual(original.fingerprint, reordered.fingerprint)
        XCTAssertEqual(original.fingerprint, prefixed.fingerprint)
    }

    func testForeignAndAdditionalArchiveMetadataRemainPartOfOriginalPayload() throws {
        let first = try XCTUnwrap(source(message(suffix: "<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='foreign-one'/><time xmlns='urn:example:time'>one</time>")))
        let changed = try XCTUnwrap(source(message(suffix: "<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='foreign-two'/><time xmlns='urn:example:time'>one</time>")))
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
    }

    func testBodyWhitespaceAndInlineForwardPayloadArePreservedExactly() throws {
        let body = try XCTUnwrap(source(message(body: "source ")))
        let trimmed = try XCTUnwrap(source(message(body: "source")))
        let forward = try XCTUnwrap(source(message(suffix: "<forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' id='inner'><body>one</body></message></forwarded>")))
        let changedForward = try XCTUnwrap(source(message(suffix: "<forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' id='inner'><body>two</body></message></forwarded>")))
        XCTAssertNotEqual(body.fingerprint, trimmed.fingerprint)
        XCTAssertNotEqual(forward.fingerprint, changedForward.fingerprint)
    }

    func testArchiveUIDBytesRemainOpaqueWhileSourceFingerprintExcludesOwnedUID() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let first = try XCTUnwrap(source(message(id: composed), id: composed))
        let second = try XCTUnwrap(source(message(id: decomposed), id: decomposed))
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(Data(first.archiveID.rawValue.utf8), Data(second.archiveID.rawValue.utf8))
        XCTAssertNil(source(try message(id: composed), id: decomposed))
    }

    func testUnsupportedNodesAndBoundedPayloadCannotProducePartialProof() throws {
        XCTAssertNil(source(try message(suffix: "<!--cannot-silently-ignore-->")))
        XCTAssertNil(source(try message(body: String(repeating: "x", count: 1_048_576))))
        XCTAssertNil(source(try message(suffix: String(repeating: "<nested>", count: 33)
            + "payload" + String(repeating: "</nested>", count: 33))))
    }

    func testPositiveAuthoredContentProofIgnoresWeakTransportIDsResourcesAndUnknownRootMetadata() throws {
        let original = try XCTUnwrap(source(message()))
        let copy = try message(suffix: "<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='foreign-copy'/><opaque xmlns='urn:example:opaque'>metadata</opaque>")
        copy.addAttribute(withName: "id", stringValue: "fresh-transmission-ID")
        copy.addAttribute(withName: "from", stringValue: "peer@example.com/new-resource")
        let changedMetadata = try XCTUnwrap(source(copy))
        XCTAssertNotEqual(original.fingerprint, changedMetadata.fingerprint)
        XCTAssertEqual(original.authoredPayloadFingerprint, changedMetadata.authoredPayloadFingerprint)
        XCTAssertEqual(original.authoredPayloadFingerprint.count, 32)
        XCTAssertFalse(original.hasDistinctAuthoredContent(from: changedMetadata))
    }

    func testPositiveAuthoredContentProofRequiresDifferentKnownPayloadOrDifferentKnownBareAuthor() throws {
        let original = try XCTUnwrap(source(message()))
        let changedBody = try XCTUnwrap(source(message(body: "different authored body")))
        let oppositeDirection = try message()
        oppositeDirection.addAttribute(withName: "from", stringValue: owner)
        oppositeDirection.addAttribute(withName: "to", stringValue: "peer@example.com")
        let differentAuthor = try XCTUnwrap(source(oppositeDirection))
        XCTAssertTrue(original.hasDistinctAuthoredContent(from: changedBody))
        XCTAssertEqual(original.authoredPayloadFingerprint, differentAuthor.authoredPayloadFingerprint)
        XCTAssertTrue(original.hasDistinctAuthoredContent(from: differentAuthor))
        let missingAuthor = try message()
        missingAuthor.removeAttribute(forName: "from")
        let unknownAuthor = try XCTUnwrap(source(missingAuthor))
        XCTAssertNil(unknownAuthor.bareAuthor)
        XCTAssertFalse(original.hasDistinctAuthoredContent(from: unknownAuthor))
    }

    func testRecognizedMediaAndInlineForwardPayloadChangesProducePositiveAuthoredProof() throws {
        func media(_ name: String) -> String {
            "<reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'><file-sharing xmlns='https://xabber.com/protocol/files'><file><name>\(name).mov</name><media-type>video/quicktime</media-type><size>42</size></file><sources><uri>https://files.example.com/\(name).mov</uri></sources></file-sharing></reference>"
        }
        func forward(_ body: String) -> String {
            "<reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-06-04T10:00:00Z'/><message xmlns='jabber:client' from='author@example.com' to='peer@example.com' type='chat' id='inner'><body>\(body)</body></message></forwarded></reference>"
        }
        for payloads in [(media("first"), media("second")), (forward("first"), forward("second"))] {
            let lhsMessage = try message(body: "", suffix: payloads.0)
            let rhsMessage = try message(body: "", suffix: payloads.1)
            for item in [lhsMessage, rhsMessage] {
                XCTAssertNotNil(getReferenceType(try XCTUnwrap(SCEReceivePolicy.children(of: item,
                    named: "reference", xmlns: "https://xabber.com/protocol/references").first)))
            }
            let lhs = try XCTUnwrap(source(lhsMessage)), rhs = try XCTUnwrap(source(rhsMessage))
            XCTAssertTrue(lhs.hasDistinctAuthoredContent(from: rhs))
        }
    }

    func testUnrecognizedReferenceMetadataDoesNotCreatePositiveAuthoredProof() throws {
        for type in ["opaque", "decoration"] {
            let original = try XCTUnwrap(source(message(suffix: "<reference xmlns='https://xabber.com/protocol/references' type='\(type)'><unknown xmlns='urn:example:opaque'>one</unknown></reference>")))
            let changed = try XCTUnwrap(source(message(suffix: "<reference xmlns='https://xabber.com/protocol/references' type='\(type)'><unknown xmlns='urn:example:opaque'>two</unknown></reference>")))
            XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
            XCTAssertFalse(original.hasDistinctAuthoredContent(from: changed))
        }
        let invalidMention = try XCTUnwrap(source(message(suffix: "<reference xmlns='https://xabber.com/protocol/references' type='decoration'><mention xmlns='https://xabber.com/protocol/markup'>invalid-one</mention></reference>")))
        let changedInvalidMention = try XCTUnwrap(source(message(suffix: "<reference xmlns='https://xabber.com/protocol/references' type='decoration'><mention xmlns='https://xabber.com/protocol/markup'>invalid-two</mention></reference>")))
        XCTAssertNotEqual(invalidMention.fingerprint, changedInvalidMention.fingerprint)
        XCTAssertFalse(invalidMention.hasDistinctAuthoredContent(from: changedInvalidMention))
        func invalidMedia(_ name: String) -> String {
            "<reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='900' end='901'><file-sharing xmlns='https://xabber.com/protocol/files'><file><name>\(name).mov</name><media-type>video/quicktime</media-type><size>42</size></file><sources><uri>https://files.example.com/\(name).mov</uri></sources></file-sharing></reference>"
        }
        let invalidRangeMessage = try message(suffix: invalidMedia("one"))
        XCTAssertTrue(admittedMessageContentReferenceIndices(in: invalidRangeMessage).isEmpty)
        let invalidRange = try XCTUnwrap(source(invalidRangeMessage))
        let changedInvalidRange = try XCTUnwrap(source(message(suffix: invalidMedia("two"))))
        XCTAssertNotEqual(invalidRange.fingerprint, changedInvalidRange.fingerprint)
        XCTAssertFalse(invalidRange.hasDistinctAuthoredContent(from: changedInvalidRange))
    }

    func testTransportTransparentProofAllowsOnlyRootIDAndAddressResources() throws {
        let first = try XCTUnwrap(source(message()))
        let copy = try message(id: "copy-MAM", stamp: date.addingTimeInterval(60).XMPPFormattedDate)
        copy.addAttribute(withName: "id", stringValue: "new-transmission-ID")
        copy.addAttribute(withName: "from", stringValue: "peer@example.com/other-device")
        copy.addAttribute(withName: "to", stringValue: owner + "/phone")
        let second = try XCTUnwrap(source(copy, id: "copy-MAM", date: date.addingTimeInterval(60)))
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(try XCTUnwrap(first.transportTransparentFingerprint).count, 32)
        XCTAssertEqual(first.transportTransparentFingerprint, second.transportTransparentFingerprint)
        XCTAssertEqual(first.duplicateProbe(comparedTo: second, sameQuery: true, canonicalFork: false), 1 | 2 | 4 | 8 | 16)
        XCTAssertEqual(first.duplicateProbe(comparedTo: second, sameQuery: false, canonicalFork: true), 1 | 4 | 8 | 16 | 256)
    }

    func testTransportTransparentProofRetainsUnknownRootAttributesAndQualifiedID() throws {
        let first = try XCTUnwrap(source(message()))
        for attribute in ["extra='opaque'", "xmlns:t='urn:example:transport' t:id='qualified-ID'"] {
            let xml = try message().xmlString.replacingOccurrences(of: "<message ", with: "<message \(attribute) ")
            let second = try XCTUnwrap(source(XMPPMessage(from: try DDXMLElement(xmlString: xml))))
            XCTAssertNotEqual(first.transportTransparentFingerprint, second.transportTransparentFingerprint)
            XCTAssertEqual(first.duplicateProbe(comparedTo: second, sameQuery: true, canonicalFork: false), 2)
        }
    }

    func testTransportTransparentProofRetainsEveryUnknownForeignIdentityAndRewriteChild() throws {
        let cases: [(String, String, Int)] = [
            ("<opaque xmlns='urn:example:opaque'>one</opaque>", "<opaque xmlns='urn:example:opaque'>two</opaque>", 32),
            ("<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='one'/>", "<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='two'/>", 64),
            ("<time xmlns='https://xabber.com/protocol/delivery' by='foreign@example.com' stamp='one'/>", "<time xmlns='https://xabber.com/protocol/delivery' by='foreign@example.com' stamp='two'/>", 64),
            ("<reference xmlns='https://xabber.com/protocol/references' type='opaque'>one</reference>", "<reference xmlns='https://xabber.com/protocol/references' type='opaque'>two</reference>", 32),
            ("<replaced xmlns='https://xabber.com/protocol/rewrite' stamp='one'/>", "<replaced xmlns='https://xabber.com/protocol/rewrite' stamp='two'/>", 32 | 128)
        ]
        for (left, right, flags) in cases {
            let first = try XCTUnwrap(source(message(suffix: left)))
            let second = try XCTUnwrap(source(message(suffix: right)))
            XCTAssertNotEqual(first.transportTransparentFingerprint, second.transportTransparentFingerprint)
            XCTAssertEqual(first.duplicateProbe(comparedTo: second, sameQuery: false, canonicalFork: false), flags)
        }
    }

    func testTransportTransparentProofRequiresBothValidBareAddressesAndPreservesTheirDirection() throws {
        let first = try XCTUnwrap(source(message()))
        for name in ["from", "to"] {
            let absent = try message()
            absent.removeAttribute(forName: name)
            XCTAssertNil(try XCTUnwrap(source(absent)).transportTransparentFingerprint)
            let empty = try message()
            empty.addAttribute(withName: name, stringValue: "")
            XCTAssertNil(try XCTUnwrap(source(empty)).transportTransparentFingerprint)
            let different = try message()
            different.addAttribute(withName: name, stringValue: "other@example.com/device")
            let changed = try XCTUnwrap(source(different))
            XCTAssertNotEqual(first.transportTransparentFingerprint, changed.transportTransparentFingerprint)
            XCTAssertEqual(first.duplicateProbe(comparedTo: changed, sameQuery: false, canonicalFork: false), 0)
        }
        let swapped = try message()
        swapped.addAttribute(withName: "from", stringValue: owner)
        swapped.addAttribute(withName: "to", stringValue: "peer@example.com")
        XCTAssertNotEqual(first.transportTransparentFingerprint, try XCTUnwrap(source(swapped)).transportTransparentFingerprint)
    }

    func testTransportTransparentProofKeepsExactUTF8PayloadTokensAndBodyWhitespace() throws {
        let first = try XCTUnwrap(source(message(body: "\u{00E9}")))
        let second = try XCTUnwrap(source(message(body: "e\u{0301}")))
        XCTAssertNotEqual(first.transportTransparentFingerprint, second.transportTransparentFingerprint)
        XCTAssertEqual(first.duplicateProbe(comparedTo: second, sameQuery: true, canonicalFork: false), 2 | 32)
        let trailingSpace = try XCTUnwrap(source(message(body: "\u{00E9} ")))
        XCTAssertNotEqual(first.transportTransparentFingerprint, trailingSpace.transportTransparentFingerprint)
        let leftSID = try XCTUnwrap(source(message(suffix: "<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='\u{00E9}'/>")))
        let rightSID = try XCTUnwrap(source(message(suffix: "<stanza-id xmlns='urn:xmpp:sid:0' by='foreign@example.com' id='e\u{0301}'/>")))
        XCTAssertNotEqual(leftSID.transportTransparentFingerprint, rightSID.transportTransparentFingerprint)
        XCTAssertEqual(leftSID.duplicateProbe(comparedTo: rightSID, sameQuery: false, canonicalFork: false), 64)
    }
}
