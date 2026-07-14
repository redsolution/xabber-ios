import XCTest
import RealmSwift
@testable import xabber

final class ChatHistoryRealmMigrationTests: XCTestCase {
    private var realmURL: URL!

    override func setUp() {
        super.setUp()
        realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryRealmMigrationTests-\(UUID().uuidString).realm")
    }

    override func tearDown() {
        if let realmURL {
            var configuration = Realm.Configuration(fileURL: realmURL)
            configuration.schemaVersion = XabberRealmSchema.current
            try? Realm.deleteFiles(for: configuration)
        }
        realmURL = nil
        super.tearDown()
    }

    func testCurrentSchemaIsNonDestructiveAndIndexesActualHistoryPredicates() {
        XCTAssertEqual(XabberRealmSchema.current, 12)
        let configuration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current
        )

        XCTAssertFalse(configuration.deleteRealmIfMigrationNeeded)
        XCTAssertTrue(Set(MessageStorageItem.indexedProperties()).isSuperset(of: [
            "owner",
            "opponent",
            "conversationType_",
            "isDeleted",
            "date",
            "archivedId",
            "messageId",
            "historyPositionOrdinal",
            "historyPositionKind",
            "historyPositionHigh",
            "historyPositionLow",
            "historyPositionDiscriminator"
        ]))
    }

    func testSchema11HistoryMigratesAndReopensWithoutLosingIdentityOrderOrDeleteState() throws {
        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 11)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            try! realm.write {
                realm.add(self.message(
                    primary: "visible-a",
                    archivedId: "archive-a",
                    messageId: "message-a",
                    timestamp: 100,
                    isDeleted: false,
                    deleteState: .visible
                ))
                realm.add(self.message(
                    primary: "visible-b",
                    archivedId: "archive-b",
                    messageId: "message-b",
                    timestamp: 200,
                    isDeleted: false,
                    deleteState: .visible
                ))
                realm.add(self.message(
                    primary: "deleted-c",
                    archivedId: "archive-c",
                    messageId: "message-c",
                    timestamp: 300,
                    isDeleted: true,
                    deleteState: .autoDeleted
                ))
            }
        }

        var upgradedConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current
        )
        upgradedConfiguration.fileURL = realmURL
        upgradedConfiguration.deleteRealmIfMigrationNeeded = false
        try assertMigratedContents(configuration: upgradedConfiguration)
        try assertMigratedContents(configuration: upgradedConfiguration)
    }

    private func assertMigratedContents(configuration: Realm.Configuration) throws {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let all = realm.objects(MessageStorageItem.self)
                .sorted(byKeyPath: "date", ascending: true)
            XCTAssertEqual(Array(all.map(\.primary)), ["visible-a", "visible-b", "deleted-c"])
            XCTAssertEqual(Array(all.map(\.archivedId)), ["archive-a", "archive-b", "archive-c"])
            XCTAssertEqual(Array(all.map(\.messageId)), ["message-a", "message-b", "message-c"])
            let deleted = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "deleted-c"))
            XCTAssertTrue(deleted.isDeleted)
            XCTAssertEqual(deleted.deleteState, .autoDeleted)
            for message in all {
                let expected = MessageHistoryPositionComponents.make(
                    primary: message.primary,
                    archivedId: message.archivedId,
                    messageId: message.messageId,
                    date: message.date
                )
                XCTAssertEqual(message.historyPositionOrdinal, expected.ordinal)
                XCTAssertEqual(message.historyPositionKind, expected.kind)
                XCTAssertEqual(message.historyPositionHigh, expected.high)
                XCTAssertEqual(message.historyPositionLow, expected.low)
                XCTAssertEqual(message.historyPositionDiscriminator, expected.discriminator)
            }

            let provider = ChatLocalHistoryPageProvider(
                realm: realm,
                owner: "migration-owner",
                jid: "migration-peer",
                conversationType: .regular
            )
            XCTAssertEqual(provider.latest(limit: 10).map(\.primary), ["visible-a", "visible-b"])
            let indexState = try XCTUnwrap(ChatLocalHistoryLinkedIndex.state(
                owner: "migration-owner",
                jid: "migration-peer",
                conversationType: .regular,
                in: realm
            ))
            XCTAssertEqual(indexState.oldestMessagePrimary, "visible-a")
            XCTAssertEqual(indexState.newestMessagePrimary, "visible-b")
            XCTAssertEqual(indexState.indexedVisibleCount, 2)
            XCTAssertEqual(realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "visible-a"
            )?.historyNextMessagePrimary, "visible-b")
            XCTAssertEqual(realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "visible-b"
            )?.historyPreviousMessagePrimary, "visible-a")
        }
    }

    private func message(
        primary: String,
        archivedId: String,
        messageId: String,
        timestamp: TimeInterval,
        isDeleted: Bool,
        deleteState: MessageStorageItem.DeleteState
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = "migration-owner"
        message.opponent = "migration-peer"
        message.conversationType = .regular
        message.archivedId = archivedId
        message.messageId = messageId
        message.date = Date(timeIntervalSince1970: timestamp)
        message.sentDate = message.date
        message.body = primary
        message.isDeleted = isDeleted
        message.deleteState = deleteState
        return message
    }
}
