import XCTest
import RealmSwift
@testable import xabber

final class ChatTimelineCursorTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"
    private let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatTimelineCursorTests-\(name)-\(UUID().uuidString)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testSameDateArchivedIdsOrderDeterministically() throws {
        try insertMessages([
            spec("p300", archivedId: "300", date: sharedDate),
            spec("p100", archivedId: "100", date: sharedDate),
            spec("p200", archivedId: "200", date: sharedDate)
        ])

        XCTAssertEqual(try provider().latest(limit: 10).map(\.primary), ["p100", "p200", "p300"])
    }

    func testOlderBoundaryIncludesEqualDateItemsBeforeArchivedId() throws {
        try insertMessages([
            spec("older", archivedId: "050", date: sharedDate.addingTimeInterval(-60)),
            spec("p100", archivedId: "100", date: sharedDate),
            spec("p200", archivedId: "200", date: sharedDate),
            spec("p300", archivedId: "300", date: sharedDate),
            spec("p400", archivedId: "400", date: sharedDate)
        ])

        let items = try provider().older(before: boundary(primary: "p300", archivedId: "300"), limit: 2)

        XCTAssertEqual(items.map(\.primary), ["p100", "p200"])
    }

    func testNewerBoundaryIncludesEqualDateItemsAfterArchivedId() throws {
        try insertMessages([
            spec("p100", archivedId: "100", date: sharedDate),
            spec("p200", archivedId: "200", date: sharedDate),
            spec("p300", archivedId: "300", date: sharedDate),
            spec("p400", archivedId: "400", date: sharedDate),
            spec("newer", archivedId: "500", date: sharedDate.addingTimeInterval(60))
        ])

        let items = try provider().newer(after: boundary(primary: "p200", archivedId: "200"), limit: 2)

        XCTAssertEqual(items.map(\.primary), ["p300", "p400"])
    }

    func testAroundAnchorUsesCompoundBoundaryInsteadOfWholeDateBucket() throws {
        try insertMessages([
            spec("p100", archivedId: "100", date: sharedDate),
            spec("p200", archivedId: "200", date: sharedDate),
            spec("p300", archivedId: "300", date: sharedDate),
            spec("p400", archivedId: "400", date: sharedDate),
            spec("p500", archivedId: "500", date: sharedDate)
        ])
        let anchor = try XCTUnwrap(message(primary: "p300"))

        let items = try provider().around(anchor: anchor, before: 1, after: 1)

        XCTAssertEqual(items.map(\.primary), ["p200", "p300", "p400"])
    }

    func testMissingArchivedIdFallsBackToMessageIdAndPrimary() throws {
        try insertMessages([
            spec("fallback-c", archivedId: "", messageId: "message-c", date: sharedDate),
            spec("fallback-a", archivedId: "", messageId: "message-a", date: sharedDate),
            spec("fallback-b", archivedId: "", messageId: "message-b", date: sharedDate)
        ])

        let provider = try provider()
        let older = provider.older(
            before: ChatTimelineBoundary(
                primary: "fallback-c",
                archivedId: nil,
                messageId: "message-c",
                date: sharedDate
            ),
            limit: 2
        )
        let newer = provider.newer(
            after: ChatTimelineBoundary(
                primary: "fallback-a",
                archivedId: nil,
                messageId: "message-a",
                date: sharedDate
            ),
            limit: 2
        )

        XCTAssertEqual(provider.latest(limit: 10).map(\.primary), ["fallback-a", "fallback-b", "fallback-c"])
        XCTAssertEqual(older.map(\.primary), ["fallback-a", "fallback-b"])
        XCTAssertEqual(newer.map(\.primary), ["fallback-b", "fallback-c"])
    }

    func testCanonicalIdentityDedupeRemovesMamLiveDuplicateRows() throws {
        try insertMessages([
            spec("live-primary", archivedId: "900", messageId: "origin-1", date: sharedDate),
            spec("mam-primary", archivedId: "900", messageId: "origin-1", date: sharedDate),
            spec("unique-primary", archivedId: "901", messageId: "origin-2", date: sharedDate.addingTimeInterval(1))
        ])

        let items = try provider().latest(limit: 10)

        XCTAssertEqual(items.map(\.archivedId), ["900", "901"])
        XCTAssertEqual(Set(items.map(\.primary)).count, 2)
    }

    func testGapRepairRequiresProviderVisibleRowsBeforeAdvance() {
        XCTAssertFalse(ChatRemoteHistoryApplyProofPolicy.didAdvance(
            direction: .older,
            visibleRows: 0,
            resultCount: 10,
            queryExhausted: false,
            previousOldestArchivedId: "300",
            previousNewestArchivedId: "500",
            newOldestArchivedId: "100",
            newNewestArchivedId: "500"
        ))
    }

    private func provider() throws -> ChatLocalHistoryPageProvider {
        ChatLocalHistoryPageProvider(
            realm: try WRealm.safe(),
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
    }

    private func message(primary: String) throws -> MessageStorageItem? {
        try WRealm.safe().object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
    }

    private func boundary(primary: String, archivedId: String) -> ChatTimelineBoundary {
        ChatTimelineBoundary(
            primary: primary,
            archivedId: archivedId,
            messageId: "message-\(primary)",
            date: sharedDate
        )
    }

    private func spec(
        _ primary: String,
        archivedId: String,
        messageId: String? = nil,
        date: Date
    ) -> (primary: String, archivedId: String, messageId: String, date: Date) {
        (primary, archivedId, messageId ?? "message-\(primary)", date)
    }

    private func insertMessages(
        _ specs: [(primary: String, archivedId: String, messageId: String, date: Date)]
    ) throws {
        let realm = try WRealm.safe()
        try realm.write {
            specs.forEach { spec in
                let message = MessageStorageItem()
                message.primary = spec.primary
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.archivedId = spec.archivedId
                message.messageId = spec.messageId
                message.date = spec.date
                message.sentDate = spec.date
                message.body = spec.primary
                realm.add(message, update: .modified)
            }
        }
    }
}
