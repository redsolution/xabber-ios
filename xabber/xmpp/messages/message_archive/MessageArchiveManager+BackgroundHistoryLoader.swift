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
import XMPPFramework
import RealmSwift

extension MessageArchiveManager {
//    public final func loadFullChatHistory(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, nextPage: String? = nil) -> String? {
//        do {
//            let realm = try WRealm.safe()
//            
////            if !(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: MessageStorageItem.messageIdForInitial(jid: jid, conversationType: conversationType), owner: self.owner))?.isDeleted ?? true) {
////                self.backgroundTaskDelegate?.backgroundTaskDidEnd(shouldContinue: false)
////                return nil
////            }
//            let isGroupchat = realm
//                .object(ofType: GroupChatStorageItem.self,
//                        forPrimaryKey: GroupChatStorageItem.genPrimary(jid: jid, owner: owner)) != nil
//            
//            let chat = realm
//                .object(
//                    ofType: LastChatsStorageItem.self,
//                    forPrimaryKey: LastChatsStorageItem.genPrimary(
//                        jid: jid,
//                        owner: self.owner,
//                        conversationType: conversationType
//                    )
//                )
//            
//            var queryId: String? = nil
//            if let task = self.fullChatLoadingTask {
//                queryId = startLoadingMessage(
//                    stream,
//                    from: task.messageId,
//                    jid: jid,
//                    count: nil,
//                    isGroupchat: task.isGroupchat,
//                    conversationType: task.conversationType
//                )
//            } else {
//                let messages = realm
//                    .objects(MessageStorageItem.self)
//                    .filter("owner == %@ AND opponent == %@ AND messageType != %@", owner, jid,  MessageStorageItem.MessageDisplayType.initial.rawValue)
//                    .sorted(byKeyPath: "date", ascending: false)
//    //            print(messages)
//                let messagesCount = messages.count
//                let lastMessageId = messages.suffix(3).first?.archivedId
//    //            print("messagesCount", messagesCount)
//                if let count = chat?.messagesCount {
//    //                print("count", count)
//                    if count > messagesCount || count <= 2 {
//                        queryId = startLoadingMessage(
//                            stream,
//                            from: lastMessageId,
//                            jid: jid,
//                            count: nil,
//                            isGroupchat: isGroupchat,
//                            conversationType: conversationType,
//                            nextPage: nextPage,
//                            ui: true
//                        )
//                    } else {
//                        queryId = startLoadingMessage(
//                            stream,
//                            from: "",
//                            jid: jid,
//                            count: nil,
//                            isGroupchat: isGroupchat,
//                            conversationType: conversationType,
//                            nextPage: nextPage,
//                            ui: true
//                        )
//                    }
//                } else {
//                    queryId = startLoadingMessage(
//                        stream,
//                        from: lastMessageId,
//                        jid: jid,
//                        count: nil,
//                        isGroupchat: isGroupchat,
//                        conversationType: conversationType,
//                        nextPage: nextPage,
//                        ui: true
//                    )
//                }
//            }
//            
//            
//            return queryId
//        } catch {
//            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//            return nil
//        }
//    }
//    
//    private final func startLoadingMessage(_ stream: XMPPStream, from messageId: String?, jid: String, count: Int?, isGroupchat: Bool, conversationType: ClientSynchronizationManager.ConversationType, nextPage: String? = nil, ui: Bool = false) -> String? {
//        let maxPageSize = 200
//        let resultCount: Int
//        if let count = count {
//            resultCount = maxPageSize < count ? maxPageSize : count
//        } else {
//            resultCount = maxPageSize
//        }
//        var elementId: String? = nil
//        if conversationType == .omemo {
//            elementId = requestHistory(
//                stream,
//                to: isGroupchat ? jid : nil,
//                jid: isGroupchat ? nil : jid,
//                count: resultCount,
//                beforeId: nil,//messageId ?? "",
//                filter: .encrypted,
//                before: messageId ?? nextPage
//            )
//        } else {
//            elementId = requestHistory(
//                stream,
//                to: isGroupchat ? jid : nil,
//                jid: isGroupchat ? nil : jid,
//                count: resultCount,
//                beforeId: nil, //messageId ?? "",
//                before: messageId ?? nextPage
//            )
//        }
//        
//        if let elementId = elementId {
//            if ui {
//                self.fullChatLoadingTask = MAMRequestItem(
//                    jid: jid,
//                    messageId: messageId,
//                    elementId: elementId,
//                    conversationType: conversationType,
//                    isGroupchat: isGroupchat
//                )
//            } else {
//                self.backgroundMAMRequest = MAMRequestItem(
//                    jid: jid,
//                    messageId: messageId,
//                    elementId: elementId,
//                    conversationType: conversationType,
//                    isGroupchat: isGroupchat
//                )
//            }
//        }
//        return elementId
//    }
//    
//    internal final func readBackgroundLoaderResponse(_ iq: XMPPIQ) -> Bool {
//        guard let requestMetadata = self.backgroundMAMRequest,
//              let elementId = iq.elementID,
//              requestMetadata.elementId == elementId,
//              let finElement = iq.element(forName: "fin") else {
//            return false
//        }
//        AccountManager.shared.addUpdatedChat(jid: requestMetadata.jid, owner: self.owner, conversationType: requestMetadata.conversationType)
//        if let set = finElement.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") {
//            if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
////                print("elementsCount", count)
//                do {
//                    let realm = try WRealm.safe()
//                    try realm.write {
//                        realm
//                            .object(
//                                ofType: LastChatsStorageItem.self,
//                                forPrimaryKey: LastChatsStorageItem
//                                    .genPrimary(
//                                        jid: requestMetadata.jid,
//                                        owner: self.owner,
//                                        conversationType: .omemo
//                                    )
//                            )?.messagesCount = count
//                    }
//                } catch {
//                    DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//                }
//            }
//            if finElement.attributeBoolValue(forName: "complete") {
//                do {
//                    let realm = try WRealm.safe()
//                    let initialMessage = MessageStorageItem()
//                    initialMessage.configureInitialMessage(
//                        self.owner,
//                        opponent: requestMetadata.jid,
//                        conversationType: .omemo,
//                        text: "",
//                        date: Date(),
//                        isRead: true
//                    )
//                    if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessage.primary) == nil {
//                        initialMessage.isDeleted = false
//                        if !realm.isInWriteTransaction {
//                            try realm.write {
//                                realm.add(initialMessage)
//                            }
//                        }
//                    } else {
//                        if !realm.isInWriteTransaction {
//                            try realm.write {
//                                realm.object(
//                                    ofType: MessageStorageItem.self,
//                                    forPrimaryKey: MessageStorageItem.genPrimary(
//                                        messageId: MessageStorageItem.messageIdForInitial(
//                                            jid: requestMetadata.jid,
//                                            conversationType: .omemo
//                                        ),
//                                        owner: self.owner
//                                    )
//                                )?.isDeleted = false
//                            }
//                        }
//                    }
//                } catch {
//                    DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//                }
//            } else {
//                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
//                    self.backgroundTaskDelegate?.backgroundTaskDidEnd(shouldContinue: false) // todo load from last loaded message
//                }
//            }
//        }
//        
//        return true
//    }
}
