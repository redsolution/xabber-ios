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
    
}
