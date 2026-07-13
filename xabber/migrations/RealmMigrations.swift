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
                var newestIncomingInviteByKey: [String: (primary: String, date: Date)] = [:]
                var duplicateIncomingInvitePrimaries = Set<String>()

                migration.enumerateObjects(ofType: GroupchatInvitesStorageItem.className()) { oldObject, _ in
                    let outgoing = (oldObject?["outgoing"] as? Bool) ?? true
                    guard !outgoing,
                          let owner = oldObject?["owner"] as? String,
                          let groupchat = oldObject?["groupchat"] as? String,
                          !owner.isEmpty,
                          !groupchat.isEmpty,
                          let primary = oldObject?["primary"] as? String else {
                        return
                    }
                    let stableKey = [groupchat, owner].prp()
                    let date = (oldObject?["date"] as? Date) ?? Date(timeIntervalSinceReferenceDate: 0)
                    if let existing = newestIncomingInviteByKey[stableKey] {
                        if existing.date >= date {
                            duplicateIncomingInvitePrimaries.insert(primary)
                        } else {
                            duplicateIncomingInvitePrimaries.insert(existing.primary)
                            newestIncomingInviteByKey[stableKey] = (primary, date)
                        }
                    } else {
                        newestIncomingInviteByKey[stableKey] = (primary, date)
                    }
                }

                migration.enumerateObjects(ofType: GroupchatInvitesStorageItem.className()) { oldObject, newObject in
                    guard let newObject else { return }
                    let oldPrimary = (oldObject?["primary"] as? String) ?? ""
                    if duplicateIncomingInvitePrimaries.contains(oldPrimary) {
                        migration.delete(newObject)
                        return
                    }

                    let outgoing = (oldObject?["outgoing"] as? Bool) ?? true
                    let owner = (oldObject?["owner"] as? String) ?? ""
                    let groupchat = (oldObject?["groupchat"] as? String) ?? ""
                    if !outgoing, !owner.isEmpty, !groupchat.isEmpty {
                        newObject["primary"] = [groupchat, owner].prp()
                    }
                    newObject["originId"] = ""
                    newObject["stanzaId"] = oldObject?["messageId"] as? String ?? ""
                    newObject["archiveId"] = oldObject?["messageId"] as? String ?? ""
                }
            }
            if oldSchemaVersion < 11 {
                // XMPPMessageScheduleStorageItem is a new table for pending/failed scheduled messages.
                // Existing accounts have no local schedule rows to backfill.
            }
        },
        deleteRealmIfMigrationNeeded: inMemoryIdentifier == nil) { total, used in
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
