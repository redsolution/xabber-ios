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


func realmMigrations(scheme: UInt64) {
    let config = Realm.Configuration(
//        fileURL: FileManager
//            .default
//            .containerURL(forSecurityApplicationGroupIdentifier: "group.clandestino.shared")?
//            .appendingPathComponent("clandestino.realm"),
//        encryptionKey: Data("absdasdfadsfasdfsadfadsfsadfadsfasddfasdfasdfdfghjfgjfghjfghjgfhjfgjfgjfgjfghjfghhjfgjhfghjadsf".bytes.prefix(64)),
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
        },
        deleteRealmIfMigrationNeeded: true) { total, used in
            let limit = 100 * 1024 * 1024
            return total > limit && Double(used) / Double(total) < 0/5
        }

//    if _DEBUG {
//        print(config.fileURL)
//    }
    Realm.Configuration.defaultConfiguration = config
}
