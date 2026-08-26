//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import RealmSwift

enum XabberRealmSchema {
    /// Schema 19 introduces proof-bearing conversation archive coverage.
    /// Schema 18 ranges are imported as permanently provisional compatibility
    /// data. Only current-session MAM persistence proof can authorize UI.
    static let current: UInt64 = 19
}


func makeRealmMigrationConfiguration(
    scheme: UInt64,
    inMemoryIdentifier: String? = nil
) -> Realm.Configuration {
    Realm.Configuration(
//        fileURL: FileManager
//            .default
//            .containerURL(forSecurityApplicationGroupIdentifier: "group.clandestino.shared")?
//            .appendingPathComponent("clandestino.realm"),
//        encryptionKey: Data("absdasdfadsfasdfsadfadsfsadfadsfasddfasdfasdfdfghjfgjfghjfghjgfhjfgjfgjfgjfghjfghhjfgjhfghjadsf".bytes.prefix(64)),
        inMemoryIdentifier: inMemoryIdentifier,
        schemaVersion: scheme,
        
        
        migrationBlock: {
            migration, oldSchemaVersion in
            if oldSchemaVersion < 4 {
                migration.enumerateObjects(ofType: MessageStorageItem.className()) { _, newObject in
                    newObject?["isLocallyHiddenByReport"] = false
                    newObject?["localReportState"] = nil
                    newObject?["lastReportedAt"] = nil
                    newObject?["lastReportReason"] = nil
                    newObject?["reportCount"] = 0
                }
                migration.enumerateObjects(ofType: MessageReferenceStorageItem.className()) { _, newObject in
                    newObject?["isLocallyHiddenByReport"] = false
                    newObject?["localReportState"] = nil
                    newObject?["lastReportedAt"] = nil
                    newObject?["lastReportReason"] = nil
                    newObject?["reportCount"] = 0
                }
                migration.enumerateObjects(ofType: MessageMediaAttachmentStorageItem.className()) { _, newObject in
                    newObject?["isLocallyHiddenByReport"] = false
                    newObject?["localReportState"] = nil
                    newObject?["lastReportedAt"] = nil
                    newObject?["lastReportReason"] = nil
                    newObject?["reportCount"] = 0
                }
                migration.enumerateObjects(ofType: XMPPAbuseReportStorageItem.className()) { _, newObject in
                    newObject?["reportId"] = ""
                    newObject?["createdAt"] = nil
                    newObject?["targetType"] = ""
                    newObject?["reason"] = ""
                    newObject?["comment"] = nil
                    newObject?["state"] = nil
                    newObject?["includeMessageExcerpt"] = false
                    newObject?["messageExcerpt"] = nil
                    newObject?["payload"] = nil
                }
            }
            if oldSchemaVersion < 5 {
                migration.enumerateObjects(ofType: MessageReferenceStorageItem.className()) { _, newObject in
                    newObject?["sensitivityCheckedAt"] = nil
                    newObject?["sensitivityAnalysisFailedAt"] = nil
                    newObject?["sensitivityAnalysisError"] = nil
                    newObject?["sensitivitySource"] = nil
                }
                migration.enumerateObjects(ofType: MessageMediaAttachmentStorageItem.className()) { _, newObject in
                    newObject?["isSensitive"] = false
                    newObject?["isSensitiveChecked"] = false
                    newObject?["sensitivityCheckedAt"] = nil
                    newObject?["sensitivityAnalysisFailedAt"] = nil
                    newObject?["sensitivityAnalysisError"] = nil
                    newObject?["sensitivitySource"] = nil
                }
            }
            if oldSchemaVersion < 6 {
                // RegularChatArchiveSyncStateStorageItem is a new table with default values.
                // Existing LastChatsStorageItem rows remain authoritative until a regular MAM page
                // establishes durable archive bounds for that dialog.
            }
            if oldSchemaVersion < 7 {
                migration.enumerateObjects(ofType: LastChatsStorageItem.className()) { oldObject, newObject in
                    let legacyUnread = max((oldObject?["unread"] as? Int) ?? 0, 0)
                    newObject?["syncUnreadCount"] = legacyUnread
                    newObject?["syncUnreadAfterId"] = oldObject?["lastReadId"] as? String
                    newObject?["syncSnapshotLastArchiveId"] = nil
                    newObject?["runtimeUnreadCount"] = 0
                    newObject?["unread"] = legacyUnread
                }
                migration.enumerateObjects(ofType: MessageStorageItem.className()) { _, newObject in
                    newObject?["unreadCounterBucket_"] = MessageStorageItem.UnreadCounterBucket.none.rawValue
                }
            }
            if oldSchemaVersion < 8 {
                migration.enumerateObjects(ofType: LastChatsStorageItem.className()) { _, newObject in
                    newObject?["lastVisibleMessagePrimary"] = nil
                    newObject?["lastVisibleMessageArchivedId"] = nil
                    newObject?["lastVisibleMessageId"] = nil
                    newObject?["lastVisibleMessageDate"] = nil
                    newObject?["lastVisiblePositionSavedAtLastMessageId"] = nil
                    newObject?["lastVisiblePositionSavedAtSnapshotLastArchiveId"] = nil
                    newObject?["lastVisiblePositionUpdatedAt"] = nil
                }
            }
            if oldSchemaVersion < 9 {
                // OutgoingMessageQueueItem is a new table for durable regular-message replay.
                // Existing recoverable sending messages are reconstructed by MessageManager startup.
            }
            if oldSchemaVersion < 10 {
                // Canonical group storage is intentionally fresh-only. Legacy
                // group invite rows are not converted by the hard-cut contract.
            }
            if oldSchemaVersion < 11 {
                // XMPPMessageScheduleStorageItem is a new table for pending/failed scheduled messages.
                // Existing accounts have no local schedule rows to backfill.
            }
            if oldSchemaVersion < 12 {
                // Realm creates indexes from indexedProperties. The position
                // components are derived only from stable message identity and
                // can be rebuilt safely without changing row identity or order.
                var rowsByConversation: [String: [(
                    object: MigrationObject,
                    primary: String,
                    orderKey: MessageHistoryOrderKey,
                    owner: String,
                    jid: String,
                    conversationType: ClientSynchronizationManager.ConversationType
                )]] = [:]
                migration.enumerateObjects(ofType: MessageStorageItem.className()) { oldObject, newObject in
                    guard let newObject else { return }
                    let primary = oldObject?["primary"] as? String ?? ""
                    let owner = oldObject?["owner"] as? String ?? ""
                    let jid = oldObject?["opponent"] as? String ?? ""
                    let conversationType = ClientSynchronizationManager.ConversationType(
                        rawValue: oldObject?["conversationType_"] as? String
                            ?? ClientSynchronizationManager.ConversationType.regular.rawValue
                    ) ?? .regular
                    let components = MessageHistoryPositionComponents.make(
                        primary: primary,
                        archivedId: oldObject?["archivedId"] as? String,
                        messageId: oldObject?["messageId"] as? String,
                        date: oldObject?["date"] as? Date ?? Date(timeIntervalSince1970: 0)
                    )
                    newObject["historyPositionOrdinal"] = components.ordinal
                    newObject["historyPositionKind"] = components.kind
                    newObject["historyPositionHigh"] = components.high
                    newObject["historyPositionLow"] = components.low
                    newObject["historyPositionDiscriminator"] = components.discriminator
                    newObject["historyPreviousMessagePrimary"] = nil
                    newObject["historyNextMessagePrimary"] = nil
                    newObject["historyLinkedIndexVersion"] = 0

                    let isDeleted = oldObject?["isDeleted"] as? Bool ?? false
                    guard !isDeleted, primary.isNotEmpty, owner.isNotEmpty, jid.isNotEmpty else { return }
                    let conversationPrimary = ChatLocalHistoryIndexStorageItem.genPrimary(
                        owner: owner,
                        jid: jid,
                        conversationType: conversationType
                    )
                    rowsByConversation[conversationPrimary, default: []].append((
                        object: newObject,
                        primary: primary,
                        orderKey: MessageHistoryOrderKey(
                            primary: primary,
                            archivedId: oldObject?["archivedId"] as? String,
                            messageId: oldObject?["messageId"] as? String,
                            date: oldObject?["date"] as? Date ?? Date(timeIntervalSince1970: 0)
                        ),
                        owner: owner,
                        jid: jid,
                        conversationType: conversationType
                    ))
                }

                for (conversationPrimary, unsortedRows) in rowsByConversation {
                    let rows = unsortedRows.sorted { $0.orderKey < $1.orderKey }
                    for (index, row) in rows.enumerated() {
                        row.object["historyPreviousMessagePrimary"] = index > 0 ? rows[index - 1].primary : nil
                        row.object["historyNextMessagePrimary"] = index + 1 < rows.count ? rows[index + 1].primary : nil
                        row.object["historyLinkedIndexVersion"] = ChatLocalHistoryIndexStorageItem.currentVersion
                    }
                    guard let first = rows.first, let last = rows.last else { continue }
                    migration.create(
                        ChatLocalHistoryIndexStorageItem.className(),
                        value: [
                            "primary": conversationPrimary,
                            "owner": first.owner,
                            "jid": first.jid,
                            "conversationType_": first.conversationType.rawValue,
                            "oldestMessagePrimary": first.primary,
                            "newestMessagePrimary": last.primary,
                            "indexedVisibleCount": rows.count,
                            "version": ChatLocalHistoryIndexStorageItem.currentVersion
                        ]
                    )
                }
            }
            if oldSchemaVersion < 13 {
                migration.enumerateObjects(ofType: NotificationStorageItem.className()) { oldObject, newObject in
                    guard let newObject else { return }
                    let existingAssociatedJid = oldObject?["associatedJid"] as? String
                    guard existingAssociatedJid?.isNotEmpty != true else { return }

                    var sourceChatJid: String?
                    if let metadata = oldObject?["metadata_"] as? String,
                       let data = metadata.data(using: .utf8),
                       let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        sourceChatJid = dictionary["sourceChatJid"] as? String
                    }
                    let originalSenderJid = oldObject?["originalSenderJid"] as? String
                    let conversationJid = sourceChatJid?.isNotEmpty == true
                        ? sourceChatJid
                        : (originalSenderJid?.isNotEmpty == true ? originalSenderJid : nil)
                    newObject["associatedJid"] = conversationJid
                }
            }
            if oldSchemaVersion < 14 {
                // The canonical group tables are intentionally created empty.
                // There is no conversion from the legacy group schema.
            }
            if oldSchemaVersion < 18 {
                // Existing messages have no durable @all send intent. The new
                // fields keep their nil/false defaults; only newly composed
                // messages can be retried with an empty canonical <mentions/>.
            }
            if oldSchemaVersion < 19 {
                struct LegacyChatBoundary {
                    let snapshotArchiveID: String?
                    let lastMessageID: String?
                    let unreadAfterID: String?
                    let unreadCount: Int
                }

                var chatBoundaries: [String: LegacyChatBoundary] = [:]
                migration.enumerateObjects(ofType: LastChatsStorageItem.className()) { oldObject, _ in
                    guard let primary = oldObject?["primary"] as? String,
                          primary.isNotEmpty else {
                        return
                    }
                    chatBoundaries[primary] = LegacyChatBoundary(
                        snapshotArchiveID: oldObject?["syncSnapshotLastArchiveId"] as? String,
                        lastMessageID: oldObject?["lastMessageId"] as? String,
                        unreadAfterID: oldObject?["syncUnreadAfterId"] as? String,
                        unreadCount: oldObject?["syncUnreadCount"] as? Int ?? 0
                    )
                }

                migration.enumerateObjects(
                    ofType: RegularChatArchiveSyncStateStorageItem.className()
                ) { oldObject, _ in
                    guard let primary = oldObject?["primary"] as? String,
                          let owner = oldObject?["owner"] as? String,
                          let jid = oldObject?["jid"] as? String,
                          primary.isNotEmpty,
                          owner.isNotEmpty,
                          jid.isNotEmpty else {
                        return
                    }
                    let conversationTypeRaw = oldObject?["conversationType_"] as? String
                        ?? ClientSynchronizationManager.ConversationType.regular.rawValue
                    let chatBoundary = chatBoundaries[primary]
                    let fingerprint = ArchiveSyncFingerprint(
                        completedSnapshotStamp: ClientSynchronizationManager.completedSnapshotStamp(
                            for: owner
                        ),
                        lastArchiveID: oldObject?["lastSnapshotArchiveId"] as? String
                            ?? chatBoundary?.snapshotArchiveID,
                        lastMessageID: oldObject?["lastSnapshotMessageId"] as? String
                            ?? chatBoundary?.lastMessageID,
                        unreadAfterID: chatBoundary?.unreadAfterID,
                        unreadCount: chatBoundary?.unreadCount ?? 0
                    ).stableValue
                    let segmentsJSON = ConversationArchiveCoverageStorageItem.provisionalSegmentsJSON(
                        legacyRangesJSON: oldObject?["loadedRangesJSON"] as? String ?? "[]",
                        reachesArchiveStart: oldObject?["olderArchiveEndReached"] as? Bool ?? false,
                        reachesLiveEdge: oldObject?["newerLiveEdgeReached"] as? Bool ?? false,
                        fingerprint: fingerprint
                    )
                    let now = Date()
                    migration.create(
                        ConversationArchiveCoverageStorageItem.className(),
                        value: [
                            "primary": primary,
                            "owner": owner,
                            "jid": jid,
                            "conversationType_": conversationTypeRaw,
                            "segmentsJSON": segmentsJSON,
                            "coverageGeneration": Int64(0),
                            "lastObservedXEPSYNCFingerprint": fingerprint,
                            "createdAt": now,
                            "updatedAt": now,
                        ]
                    )
                }
            }
        },
        deleteRealmIfMigrationNeeded: false) { total, used in
            let limit = 100 * 1024 * 1024
            return total > limit && Double(used) / Double(total) < 0/5
        }
}

func realmMigrations(
    scheme: UInt64,
    inMemoryIdentifier: String? = nil
) {
    let config = makeRealmMigrationConfiguration(
        scheme: scheme,
        inMemoryIdentifier: inMemoryIdentifier
    )

//    if _DEBUG {
//        print(config.fileURL)
//    }
    Realm.Configuration.defaultConfiguration = config
}
