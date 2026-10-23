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

    func testSameDateLocalPrimariesOrderIndependentlyOfArchiveIDs() throws {
        try insertMessages([
            spec("p300", archivedId: "0001", mamArchiveId: "a-first", date: sharedDate),
            spec("p100", archivedId: "z-last", mamArchiveId: "9", date: sharedDate),
            spec("p200", archivedId: "9", mamArchiveId: "0001", date: sharedDate)
        ])

        XCTAssertEqual(try provider().latest(limit: 10).map(\.primary), ["p100", "p200", "p300"])
    }

    func testOlderBoundaryIncludesEqualDateItemsBeforeLocalPrimary() throws {
        try insertMessages([
            spec("older", archivedId: "050", date: sharedDate.addingTimeInterval(-60)),
            spec("p100", archivedId: "z-last", date: sharedDate),
            spec("p200", archivedId: "9", date: sharedDate),
            spec("p300", archivedId: "0001", date: sharedDate),
            spec("p400", archivedId: "a-first", date: sharedDate)
        ])

        let items = try provider().older(before: boundary(primary: "p300", archivedId: "0001"), limit: 2)

        XCTAssertEqual(items.map(\.primary), ["p100", "p200"])
    }

    func testNewerBoundaryIncludesEqualDateItemsAfterLocalPrimary() throws {
        try insertMessages([
            spec("p100", archivedId: "z-last", date: sharedDate),
            spec("p200", archivedId: "9", date: sharedDate),
            spec("p300", archivedId: "0001", date: sharedDate),
            spec("p400", archivedId: "a-first", date: sharedDate),
            spec("newer", archivedId: "500", date: sharedDate.addingTimeInterval(60))
        ])

        let items = try provider().newer(after: boundary(primary: "p200", archivedId: "9"), limit: 2)

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

    func testMissingArchivedIdUsesLocalPrimaryIndependentOfMessageID() throws {
        try insertMessages([
            spec("fallback-c", archivedId: "", messageId: "message-a", date: sharedDate),
            spec("fallback-a", archivedId: "", messageId: "message-z", date: sharedDate),
            spec("fallback-b", archivedId: "", messageId: "message-m", date: sharedDate)
        ])

        let provider = try provider()
        let older = provider.older(
            before: ChatTimelineBoundary(
                primary: "fallback-c",
                archivedId: nil,
                messageId: "message-a",
                date: sharedDate
            ),
            limit: 2
        )
        let newer = provider.newer(
            after: ChatTimelineBoundary(
                primary: "fallback-a",
                archivedId: nil,
                messageId: "message-z",
                date: sharedDate
            ),
            limit: 2
        )

        XCTAssertEqual(provider.latest(limit: 10).map(\.primary), ["fallback-a", "fallback-b", "fallback-c"])
        XCTAssertEqual(older.map(\.primary), ["fallback-a", "fallback-b"])
        XCTAssertEqual(newer.map(\.primary), ["fallback-b", "fallback-c"])
    }

    func testEqualDateQueriesMatchLocalOrderWhenOnlyFinalIdentityComponentDiffers() throws {
        // Both local-primary chunks are identical. Only the stable local
        // discriminator can distinguish these rows, never their archive UIDs.
        let prefix = String(repeating: "p", count: 14)
        let primaries = (1...20).map { prefix + "-\($0)" }
        try insertMessages(primaries.enumerated().map { index, primary in
            spec(primary, archivedId: "raw/\(100 - index)",
                 mamArchiveId: "mam/\(index)", date: sharedDate)
        })
        let expected = primaries.sorted {
            MessageHistoryPositionComponents.make(primary: $0, archivedId: nil,
                messageId: nil, date: sharedDate) <
                MessageHistoryPositionComponents.make(primary: $1, archivedId: nil,
                    messageId: nil, date: sharedDate)
        }
        let provider = try provider()
        let anchor = try XCTUnwrap(message(primary: expected[10]))

        XCTAssertEqual(provider.latest(limit: 2).map(\.primary), Array(expected.suffix(2)))
        XCTAssertEqual(provider.older(before: ChatTimelineBoundary(message: anchor), limit: 2).map(\.primary),
                       Array(expected[8...9]))
        XCTAssertEqual(provider.newer(after: ChatTimelineBoundary(message: anchor), limit: 2).map(\.primary),
                       Array(expected[11...12]))
        XCTAssertEqual(provider.around(anchor: anchor, before: 1, after: 1).map(\.primary),
                       Array(expected[9...11]))
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

    func testFirstIncomingUnreadResolvesOpaqueBoundaryThenUsesLocalPosition() throws {
        let boundary = "raw-boundary-z"
        try insertMessages([
            spec("boundary", archivedId: boundary, mamArchiveId: "mam-z", date: sharedDate),
            spec("outgoing", archivedId: "raw-a", mamArchiveId: "mam-0", outgoing: true,
                 date: sharedDate.addingTimeInterval(1)),
            spec("incoming", archivedId: "raw-before-lexically", mamArchiveId: "001",
                 date: sharedDate.addingTimeInterval(2)),
            spec("later", archivedId: "0", mamArchiveId: "0", date: sharedDate.addingTimeInterval(3))
        ])
        XCTAssertEqual(try provider().firstIncoming(afterArchiveBoundaryId: boundary)?.primary, "incoming")
        XCTAssertNil(try provider().firstIncoming(afterArchiveBoundaryId: "not-locally-resolved"))
    }

    func testExactArchiveBatchPreservesRequestedServerOrderAndScope() throws {
        try insertMessages([
            spec("first", archivedId: "raw-1", mamArchiveId: "z-first", date: sharedDate.addingTimeInterval(5)),
            spec("second", archivedId: "raw-2", mamArchiveId: "001", date: sharedDate),
            spec("third", archivedId: "raw-3", mamArchiveId: "a-last", date: sharedDate.addingTimeInterval(-5))
        ])
        XCTAssertEqual(try provider().items(archiveCursorIDs: ["z-first", "001", "a-last"]).map(\.primary),
                       ["first", "second", "third"])
        XCTAssertTrue(try provider().items(archiveCursorIDs: ["raw-1"]).isEmpty)
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
        mamArchiveId: String? = nil,
        messageId: String? = nil,
        outgoing: Bool = false,
        date: Date
    ) -> (
        primary: String,
        archivedId: String,
        mamArchiveId: String?,
        messageId: String,
        outgoing: Bool,
        date: Date
    ) {
        (
            primary,
            archivedId,
            mamArchiveId,
            messageId ?? "message-\(primary)",
            outgoing,
            date
        )
    }

    private func insertMessages(
        _ specs: [
            (
                primary: String,
                archivedId: String,
                mamArchiveId: String?,
                messageId: String,
                outgoing: Bool,
                date: Date
            )
        ]
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
                message.mamArchiveId = spec.mamArchiveId ?? ""
                message.messageId = spec.messageId
                message.outgoing = spec.outgoing
                message.date = spec.date
                message.sentDate = spec.date
                message.body = spec.primary
                realm.add(message, update: .modified)
            }
        }
    }
}
