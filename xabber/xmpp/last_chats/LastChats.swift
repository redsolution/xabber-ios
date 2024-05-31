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
//import XMPPFramework
import RealmSwift
import CocoaLumberjack

class LastChats: AbstractXMPPManager {
    
    public static func updateLastMessage(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
            ) {
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.lastMessage = realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND isDeleted == false", owner, jid)
                        .sorted(byKeyPath: "date", ascending: false)
                        .first
                }
            }
            
        } catch {
            DDLogDebug("LastChats: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func initChat(jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)) == nil {
                let initialMessageInstance = MessageStorageItem()

                initialMessageInstance.configureInitialMessage(
                    owner,
                    opponent: jid,
                    conversationType: conversationType,
                    text: conversationType == .omemo ? "Encrypted chat created".localizeString(id: "encrypted_chat_created", arguments: []) : "New chat created",
                    date: Date(),
                    isRead: true
                )

                initialMessageInstance.isDeleted = false
                let instance = LastChatsStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.conversationType = conversationType
                instance.messageDate = Date()
                instance.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)
                instance.isFreshNotEmptyEncryptedChat = conversationType == .omemo
                instance.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner))
                
                try realm.write {
                    realm.add(instance, update: .modified)
                    if let messageInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessageInstance.primary) {
                        instance.lastMessage = messageInstance
                    } else {
                        instance.lastMessage = initialMessageInstance
                    }
                }
            }
            if conversationType == .omemo {
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
                    AccountManager.shared.find(for: self.owner)?.omemo.getContactDevices(stream, jid: jid)
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.omemo.getContactDevices(stream, jid: jid)
                    })
                }
            }
        } catch {
            DDLogDebug("LastChats: \(#function). \(error.localizedDescription)")
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let chats = realm.objects(LastChatsStorageItem.self).filter("owner == %@", owner)
            
            if commitTransaction {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(chats)
                    }
                }
            } else {
                realm.delete(chats)
            }
        } catch {
            DDLogDebug("cant remove last chats for \(owner)")
        }
    }
    
    func resetSyncedStatus(hard: Bool = false) {
        RunLoop.main.perform {
            do {
                let realm = try WRealm.safe()
                realm.writeAsync {
                    realm.objects(LastChatsStorageItem.self).filter("owner == %@", self.owner).forEach {
                        chat in
//                        chat.isSynced = false
                        if hard {
                            chat.isPrereaded = false
                        }
                        chat.isHistoryGapFixedForSession = false
                        chat.chatState = .none
                    }
                }
            } catch {
                DDLogDebug("cant reset synced chat state for \(self.owner)")
            }
        }
    }
    
    
    static func updateErrorState(for jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            let collection = realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND state_ == %@ AND messageType != %@",
                    owner,
                    jid,
                    conversationType.rawValue,
                    MessageStorageItem.MessageSendingState.error.rawValue,
                    MessageStorageItem.MessageDisplayType.system.rawValue
                )
            let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType))
            try realm.write {
                instance?.hasErrorInChat = !collection.isEmpty
            }
        } catch {
            DDLogDebug("LastChats: \(#function). \(error.localizedDescription)")
        }
    }
}
