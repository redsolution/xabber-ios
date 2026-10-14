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
        XCTAssertEqual(XabberRealmSchema.current, 26)
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
            "rawProtocolStanzaIDNumericValue",
            "mamArchiveId",
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

    func testSchema25KeepsDecryptedHistoryAndDoesNotPromoteRetiredIdentityToNativeAuthority() throws {
        let identityPrimary = SignalIdentityStorageItem.genRpimary(owner: "migration-owner",
            jid: "migration-owner", deviceId: 42)
        let retiredPublic = (Data([5]) + Data(repeating: 0x17, count: 32)).base64EncodedString()
        var legacy = makeRealmMigrationConfiguration(scheme: 25)
        legacy.fileURL = realmURL
        try autoreleasepool {
            let realm = try Realm(configuration: legacy)
            let identity = SignalIdentityStorageItem()
            identity.primary = identityPrimary
            identity.owner = "migration-owner"
            identity.jid = "migration-owner"
            identity.deviceId = 42
            identity.identityKey = retiredPublic
            identity.protocolProfile = XabberOMEMO2Storage.profile
            let history = message(primary: "decrypted-crypto-history", archivedId: "100", messageId: "history-100",
                timestamp: 100, isDeleted: false, deleteState: .visible)
            history.body = "already decrypted history"
            try realm.write { realm.add(identity); realm.add(history) }
        }
        var upgraded = makeRealmMigrationConfiguration(scheme: XabberRealmSchema.current)
        upgraded.fileURL = realmURL

        try autoreleasepool {
            let realm = try Realm(configuration: upgraded)
            let identity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: identityPrimary))
            let history = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "decrypted-crypto-history"))
            XCTAssertEqual(identity.identityKey, retiredPublic)
            XCTAssertEqual(identity.protocolProfile, XabberOMEMO2Storage.profile)
            XCTAssertEqual(identity.cryptoBackend, "")
            XCTAssertEqual(history.body, "already decrypted history")
            XCTAssertEqual(history.archivedId, "100")
            XCTAssertEqual(history.messageId, "history-100")
        }
    }

    func testSchema20RebuildsRawProtocolStanzaNumericValueWithoutChangingMAMIdentity() throws {
        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 20)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            let message = self.message(
                primary: "schema-20-raw-protocol-id",
                archivedId: "1700000000000151",
                messageId: "schema-20-message",
                timestamp: 1_700_000_000,
                isDeleted: false,
                deleteState: .visible
            )
            message.mamArchiveId = "1700000000000300"
            message.rawProtocolStanzaIDNumericValue = 1
            try! realm.write {
                realm.add(message)
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
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: "schema-20-raw-protocol-id"
                )
            )
            XCTAssertEqual(
                migrated.rawProtocolStanzaIDNumericValue,
                1_700_000_000_000_151
            )
            XCTAssertEqual(migrated.archivedId, "1700000000000151")
            XCTAssertEqual(migrated.mamArchiveId, "1700000000000300")
        }
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

    func testSchema19LeavesMAMArchiveIDEmptyForSafeReplayReconciliation() throws {
        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 19)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            let message = self.message(
                primary: "legacy-mam-identity",
                archivedId: "100",
                messageId: "legacy-message",
                timestamp: 100,
                isDeleted: false,
                deleteState: .visible
            )
            message.mamArchiveId = "must-not-survive-schema-20-migration"
            try! realm.write {
                realm.add(message)
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
                realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "legacy-mam-identity")
            )
            XCTAssertEqual(migrated.archivedId, "100")
            XCTAssertEqual(migrated.mamArchiveId, "")
            XCTAssertEqual(migrated.mamArchiveCursorID, "100")
        }
    }

    func testSchema19VerifiedCoverageAndLegacyProjectionInvalidateWhenMAMIDsAreUnavailable() throws {
        let owner = "coverage-migration-owner"
        let jid = "coverage-migration-peer"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let primary = ConversationArchiveCoverageStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let verifiedSegment = try XCTUnwrap(
            ArchiveCoverageSegment(
                oldest: try XCTUnwrap(ArchiveCursor(rawValue: "100")),
                newest: try XCTUnwrap(ArchiveCursor(rawValue: "200")),
                reachesArchiveStart: true,
                reachesLiveEdge: true,
                fingerprint: "session:19",
                isVerified: true
            )
        )

        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 19)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            try! realm.write {
                let message = MessageStorageItem()
                message.primary = "legacy-covered-message"
                message.owner = owner
                message.opponent = jid
                message.conversationType = conversationType
                message.archivedId = "100"
                message.mamArchiveId = "old-result-id"
                message.messageId = "legacy-message"
                message.date = Date(timeIntervalSince1970: 100)
                realm.add(message)

                let coverage = ConversationArchiveCoverageStorageItem()
                coverage.primary = primary
                coverage.owner = owner
                coverage.jid = jid
                coverage.conversationType = conversationType
                coverage.segments = [verifiedSegment]
                coverage.coverageGeneration = 7
                coverage.archiveFreshnessFingerprint = "session:19"
                realm.add(coverage)

                let legacy = RegularChatArchiveSyncStateStorageItem()
                legacy.primary = primary
                legacy.owner = owner
                legacy.jid = jid
                legacy.conversationType = conversationType
                legacy.loadedRanges = [
                    RegularChatArchiveIDRange(
                        oldestArchiveId: "100",
                        newestArchiveId: "200"
                    )
                ]
                legacy.olderArchiveEndReached = true
                legacy.newerLiveEdgeReached = true
                legacy.recomputeBoundsAndGaps()
                realm.add(legacy)

                let chat = LastChatsStorageItem()
                chat.primary = primary
                chat.owner = owner
                chat.jid = jid
                chat.conversationType = conversationType
                chat.isSynced = true
                chat.isInitialArchiveLoaded = true
                chat.fullArchiveLoaded = true
                chat.lastLoadedMessageHistoryId = "100"
                realm.add(chat)
            }
        }

        var upgradedConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current
        )
        upgradedConfiguration.fileURL = realmURL
        upgradedConfiguration.deleteRealmIfMigrationNeeded = false
        try autoreleasepool {
            let realm = try Realm(configuration: upgradedConfiguration)

            let message = try XCTUnwrap(
                realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "legacy-covered-message")
            )
            XCTAssertEqual(message.archivedId, "100")
            XCTAssertEqual(message.mamArchiveId, "")

            let coverage = try XCTUnwrap(
                realm.object(ofType: ConversationArchiveCoverageStorageItem.self, forPrimaryKey: primary)
            )
            XCTAssertEqual(coverage.segments, [])
            XCTAssertEqual(coverage.coverageGeneration, 0)
            XCTAssertNil(coverage.archiveFreshnessFingerprint)

            let legacy = try XCTUnwrap(
                realm.object(ofType: RegularChatArchiveSyncStateStorageItem.self, forPrimaryKey: primary)
            )
            XCTAssertEqual(legacy.loadedRanges, [])
            XCTAssertEqual(legacy.knownGaps, [])
            XCTAssertNil(legacy.oldestLoadedArchiveId)
            XCTAssertNil(legacy.newestLoadedArchiveId)
            XCTAssertFalse(legacy.olderArchiveEndReached)
            XCTAssertFalse(legacy.newerLiveEdgeReached)

            let chat = try XCTUnwrap(
                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary)
            )
            XCTAssertFalse(chat.isSynced)
            XCTAssertFalse(chat.isInitialArchiveLoaded)
            XCTAssertFalse(chat.fullArchiveLoaded)
            XCTAssertNil(chat.lastLoadedMessageHistoryId)
        }
    }

    func testSchema19AuthoritativeEmptyCoverageInvalidatesItsLegacyProjection() throws {
        let owner = "empty-coverage-migration-owner"
        let jid = "empty-coverage-migration-peer"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let primary = ConversationArchiveCoverageStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )

        var legacyConfiguration = makeRealmMigrationConfiguration(scheme: 19)
        legacyConfiguration.fileURL = realmURL
        legacyConfiguration.deleteRealmIfMigrationNeeded = false
        autoreleasepool {
            let realm = try! Realm(configuration: legacyConfiguration)
            try! realm.write {
                let coverage = ConversationArchiveCoverageStorageItem()
                coverage.primary = primary
                coverage.owner = owner
                coverage.jid = jid
                coverage.conversationType = conversationType
                coverage.segments = []
                coverage.coverageGeneration = 5
                coverage.archiveFreshnessFingerprint = "session:19"
                realm.add(coverage)

                let legacy = RegularChatArchiveSyncStateStorageItem()
                legacy.primary = primary
                legacy.owner = owner
                legacy.jid = jid
                legacy.conversationType = conversationType
                legacy.olderArchiveEndReached = true
                legacy.newerLiveEdgeReached = true
                realm.add(legacy)

                let chat = LastChatsStorageItem()
                chat.primary = primary
                chat.owner = owner
                chat.jid = jid
                chat.conversationType = conversationType
                chat.isSynced = true
                chat.isInitialArchiveLoaded = true
                chat.fullArchiveLoaded = true
                realm.add(chat)
            }
        }

        var upgradedConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current
        )
        upgradedConfiguration.fileURL = realmURL
        upgradedConfiguration.deleteRealmIfMigrationNeeded = false
        try autoreleasepool {
            let realm = try Realm(configuration: upgradedConfiguration)
            let coverage = try XCTUnwrap(
                realm.object(ofType: ConversationArchiveCoverageStorageItem.self, forPrimaryKey: primary)
            )
            XCTAssertEqual(coverage.segments, [])
            XCTAssertEqual(coverage.coverageGeneration, 0)
            XCTAssertNil(coverage.archiveFreshnessFingerprint)

            let legacy = try XCTUnwrap(
                realm.object(ofType: RegularChatArchiveSyncStateStorageItem.self, forPrimaryKey: primary)
            )
            XCTAssertEqual(legacy.loadedRanges, [])
            XCTAssertEqual(legacy.knownGaps, [])
            XCTAssertNil(legacy.oldestLoadedArchiveId)
            XCTAssertNil(legacy.newestLoadedArchiveId)
            XCTAssertFalse(legacy.olderArchiveEndReached)
            XCTAssertFalse(legacy.newerLiveEdgeReached)

            let chat = try XCTUnwrap(
                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary)
            )
            XCTAssertFalse(chat.isSynced)
            XCTAssertFalse(chat.isInitialArchiveLoaded)
            XCTAssertFalse(chat.fullArchiveLoaded)
            XCTAssertNil(chat.lastLoadedMessageHistoryId)
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
