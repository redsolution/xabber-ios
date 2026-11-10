import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

/// Historical correction records can reuse a logical origin ID. Their edit
/// namespace must not make two positively different MAM records lose a cursor.
final class ArchiveRewriteRecordIdentityTests: XCTestCase {
    private let owner = "owner@example.com"
    private let peer = "peer@example.com"
    private let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var previousConfiguration: Realm.Configuration!
    private var realmAnchor: Realm!

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ArchiveRewriteRecordIdentity-\(name)")
        realmAnchor = try! WRealm.safe()
    }

    override func tearDown() {
        realmAnchor = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    private func wire(query: String, cursor: String, offset: TimeInterval,
        annotation: String = "", peerStanzaID: String = "authored-stanza"
    ) throws -> XMPPMessage {
        let stamp = firstDate.addingTimeInterval(offset).XMPPFormattedDate
        let xml = """
        <message from='\(owner)' to='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(query)' id='\(cursor)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(peer)' to='\(owner)' type='chat' id='shared-origin'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='\(cursor)'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(cursor)'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(stamp)'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='shared-origin'/>
                <body>same authored text</body>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(peer)' id='\(peerStanzaID)'/>
                \(annotation)
              </message>
              <delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>
            </forwarded>
          </result>
        </message>
        """
        return XMPPMessage(from: try XCTUnwrap(DDXMLDocument(xmlString: xml, options: 0).rootElement()))
    }

    private func manager(query: String) -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.unsubscribeReceiver()
        manager.archiveQueryIdPersistenceResolver = { $0 == query }
        manager.beginArchiveQueryBatch(queryId: query, priority: .interactive)
        return manager
    }

    private func resolveAndValidate(summary: MessageManager.ArchivePersistenceSummary,
        query: String, delivered: [String], expectedRows: Int
    ) async throws -> [String: String] {
        let conversation = ArchiveConversationKey(owner: owner, jid: peer, conversationType: .regular)
        let configuration = Realm.Configuration.defaultConfiguration
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: configuration) }
        let rows = try await repository.materializedMessages(conversation: conversation, archiveIDs: delivered)
        let accounting = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: delivered, explicitlyConsumedArchiveIDs: summary.skippedArchiveIds,
            materializedMessages: rows, conversation: conversation, queryID: query)
        XCTAssertEqual(rows.count, expectedRows, "Every distinct verified record retains its exact MAM UID")
        XCTAssertEqual(accounting.persistedResultCount, expectedRows)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0,
            "Edit metadata is not authority to consume an unmaterialized MAM result")
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
        let request = ArchiveTransportRequest(queryID: query, conversation: conversation,
            locator: .older(before: ArchiveCursor(rawValue: "already-loaded-boundary")!),
            connectionGeneration: 1, pageSize: 100, contextBefore: 100, contextAfter: 0,
            proofFingerprint: "session:1", isUnfiltered: true, producesContinuousCoverage: true,
            usesFlippedPage: false)
        let receipt = ArchiveTransportReceipt(queryID: query, connectionGeneration: 1,
            resultArchiveIDs: delivered, messagePrimaryIDs: accounting.messagePrimaryIDs,
            first: delivered.first ?? "", last: delivered.last ?? "", complete: false,
            cheapPageCount: delivered.count, deliveredResultCount: delivered.count,
            persistedResultCount: accounting.persistedResultCount,
            intentionallyConsumedResultCount: accounting.intentionallyConsumedResultCount,
            failedPersistenceCount: accounting.failedPersistenceCount, finalReceived: true)
        XCTAssertNoThrow(try ArchiveTransportReceiptValidator.validate(receipt, for: request))
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.archiveID, $0.primaryID) })
    }

    func testDistinctArchivedCorrectionRecordsPreserveEveryMAMIdentityAndStrictOlderReceipt() async throws {
        let query = "correction-record-current-page"
        let delivered = ["original-record", "edited-record"]
        let manager = manager(query: query)
        let first = try wire(query: query, cursor: delivered[0], offset: 0,
            annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='first-correction-target'/>")
        let second = try wire(query: query, cursor: delivered[1], offset: 60,
            annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='second-correction-target'/>",
            peerStanzaID: "edited-authored-stanza")
        let firstSource = try XCTUnwrap(ArchivePlaintextMAMSource.make(
            message: try XCTUnwrap(getArchivedMessageContainer(first)), archiveOwner: owner,
            expectedArchiveID: delivered[0], expectedDate: firstDate))
        let secondSource = try XCTUnwrap(ArchivePlaintextMAMSource.make(
            message: try XCTUnwrap(getArchivedMessageContainer(second)), archiveOwner: owner,
            expectedArchiveID: delivered[1], expectedDate: firstDate.addingTimeInterval(60)))
        XCTAssertEqual(secondSource.duplicateProbe(comparedTo: firstSource,
            sameQuery: true, canonicalFork: false), 226,
            "Match the physical D10 diagnostic: rewrite plus changed transport/nontransport children")
        manager.receiveArchived(first)
        manager.receiveArchived(second)

        let summary = manager.finishArchiveQueryBatchSummary(queryId: query)

        XCTAssertEqual(summary.savedNew, 2)
        XCTAssertEqual(summary.updatedExisting, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(summary.provenLogicalDuplicates.isEmpty)
        let primaries = try await resolveAndValidate(summary: summary, query: query,
            delivered: delivered, expectedRows: 2)
        XCTAssertEqual(Set(primaries.values).count, 2)
        let realm = try WRealm.safe()
        realm.refresh()
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 2)
        XCTAssertEqual(Set(realm.objects(MessageStorageItem.self).map(\.body)), ["same authored text"])
    }

    func testCorrectionRecordReplayKeepsBothPrimariesAndCurrentQueryAccounting() async throws {
        let delivered = ["replay-original-record", "replay-edited-record"]
        var originalPrimaries: [String: String] = [:]
        for query in ["correction-record-first", "correction-record-replay"] {
            let manager = manager(query: query)
            manager.receiveArchived(try wire(query: query, cursor: delivered[0], offset: 0,
                annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='first-correction-target'/>"))
            manager.receiveArchived(try wire(query: query, cursor: delivered[1], offset: 60,
                annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='second-correction-target'/>",
                peerStanzaID: "edited-authored-stanza"))
            let summary = manager.finishArchiveQueryBatchSummary(queryId: query)
            let primaries = try await resolveAndValidate(summary: summary, query: query,
                delivered: delivered, expectedRows: 2)
            if originalPrimaries.isEmpty { originalPrimaries = primaries }
            else { XCTAssertEqual(primaries, originalPrimaries) }
        }
        let realm = try WRealm.safe()
        realm.refresh()
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 2)
    }

    func testSameMAMCorrectionUIDWithDifferentOriginalSourceFailsClosed() throws {
        let query = "same-correction-UID-conflict"
        let manager = manager(query: query)
        for (index, target) in ["first-correction-target", "conflicting-correction-target"].enumerated() {
            manager.receiveArchived(try wire(query: query, cursor: "same-record", offset: Double(index * 60),
                annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='\(target)'/>"))
        }

        let summary = manager.finishArchiveQueryBatchSummary(queryId: query)

        XCTAssertEqual(summary.savedNew, 1)
        XCTAssertEqual(summary.updatedExisting, 0)
        XCTAssertEqual(summary.failed, 1,
            "Positive source conflict under one MAM UID must not claim a successful update")
        XCTAssertTrue(summary.provenLogicalDuplicates.isEmpty)
        let realm = try! WRealm.safe()
        realm.refresh()
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 1)
        XCTAssertEqual(realm.objects(MessageStorageItem.self).first?.mamArchiveId, "same-record")
    }

    func testAuthoritativeCorrectionPairRepairsLegacyScalarRebindWithoutResettingExistingStorage() async throws {
        let delivered = ["legacy-correction-source-A", "legacy-correction-source-B"]
        let seedQuery = "legacy-correction-seed"
        let seed = manager(query: seedQuery)
        seed.receiveArchived(try wire(query: seedQuery, cursor: delivered[0], offset: 0,
            annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='first-correction-target'/>"))
        XCTAssertEqual(seed.finishArchiveQueryBatchSummary(queryId: seedQuery).savedNew, 1)
        let realm = try WRealm.safe()
        realm.refresh()
        let original = try XCTUnwrap(realm.objects(MessageStorageItem.self).first)
        let originalPrimary = original.primary
        let originalSource = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: originalPrimary + "_stanza")?.stanza)
        // Reproduce the committed physical state: sourceA survived while the
        // later current-query update replaced only its scalar MAM pointer.
        try realm.write { original.mamArchiveId = delivered[1] }

        let query = "legacy-correction-authoritative-recovery"
        let manager = manager(query: query)
        manager.receiveArchived(try wire(query: query, cursor: delivered[0], offset: 0,
            annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='first-correction-target'/>"))
        manager.receiveArchived(try wire(query: query, cursor: delivered[1], offset: 60,
            annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='second-correction-target'/>",
            peerStanzaID: "edited-authored-stanza"))

        let summary = manager.finishArchiveQueryBatchSummary(queryId: query)

        XCTAssertEqual(summary.savedNew, 1)
        XCTAssertEqual(summary.updatedExisting, 1)
        XCTAssertEqual(summary.failed, 0)
        realm.refresh()
        XCTAssertEqual(original.primary, originalPrimary)
        XCTAssertEqual(original.mamArchiveId, delivered[0])
        XCTAssertEqual(realm.object(ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: originalPrimary + "_stanza")?.stanza, originalSource)
        let primaries = try await resolveAndValidate(summary: summary, query: query,
            delivered: delivered, expectedRows: 2)
        XCTAssertEqual(primaries[delivered[0]], originalPrimary)
        XCTAssertNotEqual(primaries[delivered[1]], originalPrimary)
    }

    func testIdenticalCorrectionCopiesRemainExcludedFromLogicalDuplicateConsumption() async throws {
        let query = "identical-correction-copies"
        let delivered = ["correction-copy-A", "correction-copy-B"]
        let manager = manager(query: query)
        for (index, cursor) in delivered.enumerated() {
            manager.receiveArchived(try wire(query: query, cursor: cursor,
                offset: Double(index * 60),
                annotation: "<replace xmlns='urn:xmpp:message-correct:0' id='same-correction-target'/>"))
        }
        let summary = manager.finishArchiveQueryBatchSummary(queryId: query)
        XCTAssertTrue(summary.provenLogicalDuplicates.isEmpty,
            "This fix preserves distinct records; it must not consume active edit controls as transparent copies")
        let configuration = Realm.Configuration.defaultConfiguration
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: configuration) }
        let conversation = ArchiveConversationKey(owner: owner, jid: peer, conversationType: .regular)
        let rows = try await repository.materializedMessages(conversation: conversation, archiveIDs: delivered)
        let accounting = ArchiveTransportPersistenceAccounting.make(summary: summary,
            deliveredArchiveIDs: delivered, explicitlyConsumedArchiveIDs: [],
            materializedMessages: rows, conversation: conversation, queryID: query)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0)
        XCTAssertGreaterThan(accounting.failedPersistenceCount, 0)
    }
}
