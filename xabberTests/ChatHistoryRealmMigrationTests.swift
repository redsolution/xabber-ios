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
        XCTAssertEqual(XabberRealmSchema.current, 19)
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
        XCTAssertTrue(Set(NotificationStorageItem.indexedProperties()).isSuperset(of: [
            "owner",
            "category_",
            "isRead",
            "associatedJid",
            "date"
        ]))
    }

    func testSchema18CoverageMigratesAsProvisionalAndRejectsMalformedRanges() throws {
        let owner = "archive-migration-owner"
        let jid = "archive-migration-peer"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let primary = RegularChatArchiveSyncStateStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )

        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 18)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            let chat = LastChatsStorageItem()
            chat.primary = primary
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = conversationType
            chat.syncUnreadCount = 3
            chat.syncUnreadAfterId = "150"
            chat.syncSnapshotLastArchiveId = "200"

            let legacy = RegularChatArchiveSyncStateStorageItem()
            legacy.primary = primary
            legacy.owner = owner
            legacy.jid = jid
            legacy.conversationType = conversationType
            legacy.loadedRangesJSON = #"[{"oldestArchiveId":"100","newestArchiveId":"200"},{"oldestArchiveId":"invalid","newestArchiveId":"300"}]"#
            legacy.olderArchiveEndReached = true
            legacy.newerLiveEdgeReached = true
            legacy.lastSnapshotArchiveId = "200"
            legacy.lastSnapshotMessageId = "message-200"

            try! realm.write {
                realm.add(chat)
                realm.add(legacy)
            }
        }

        var upgradedConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current
        )
        upgradedConfiguration.fileURL = realmURL
        upgradedConfiguration.deleteRealmIfMigrationNeeded = false
        try autoreleasepool {
            let realm = try Realm(configuration: upgradedConfiguration)
            let migrated = try XCTUnwrap(
                realm.object(
                    ofType: ConversationArchiveCoverageStorageItem.self,
                    forPrimaryKey: primary
                )
            )
            XCTAssertEqual(migrated.owner, owner)
            XCTAssertEqual(migrated.jid, jid)
            XCTAssertEqual(migrated.conversationType, conversationType)
            XCTAssertEqual(migrated.coverageGeneration, 0)
            XCTAssertNotNil(migrated.lastObservedXEPSYNCFingerprint)
            XCTAssertEqual(migrated.segments.count, 1)
            let segment = try XCTUnwrap(migrated.segments.first)
            XCTAssertEqual(segment.oldest.rawValue, "100")
            XCTAssertEqual(segment.newest.rawValue, "200")
            XCTAssertTrue(segment.reachesArchiveStart)
            XCTAssertTrue(segment.reachesLiveEdge)
            XCTAssertFalse(segment.isVerified)
            XCTAssertEqual(segment.fingerprint, migrated.lastObservedXEPSYNCFingerprint)

            XCTAssertNotNil(realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: primary
            ))
        }
    }

    func testSchema12MentionNotificationBackfillsIndexedConversationIdentity() throws {
        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 12)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            let notification = NotificationStorageItem()
            notification.primary = "legacy-mention"
            notification.owner = "migration-owner"
            notification.category_ = XMPPNotificationsManager.Category.mention.rawValue
            notification.isRead = false
            notification.associatedJid = nil
            notification.date = Date(timeIntervalSince1970: 100)
            notification.metadata_ = #"{"sourceChatJid":"room@example.com","sourceArchivedId":"archive-1"}"#
            try! realm.write {
                realm.add(notification)
            }
        }

        var upgradedConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current
        )
        upgradedConfiguration.fileURL = realmURL
        upgradedConfiguration.deleteRealmIfMigrationNeeded = false
        try autoreleasepool {
            let realm = try Realm(configuration: upgradedConfiguration)
            let migrated = try XCTUnwrap(
                realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: "legacy-mention")
            )
            XCTAssertEqual(migrated.associatedJid, "room@example.com")
            let boundedCandidates = realm.objects(NotificationStorageItem.self)
                .filter(
                    "owner == %@ AND category_ == %@ AND isRead == false AND associatedJid == %@",
                    "migration-owner",
                    XMPPNotificationsManager.Category.mention.rawValue,
                    "room@example.com"
                )
                .sorted(byKeyPath: "date", ascending: true)
            XCTAssertEqual(boundedCandidates.count, 1)
        }
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
