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
import RxSwift
import RxCocoa

class MessageManager: AbstractXMPPManager {
    
    internal struct ScheduledMessage: Hashable {
        let body: String
        let to: String
    }
    
    var queue: DispatchQueue
    
//    var previousId: String = ""
    
    internal var receiverSubscribtion: Disposable? = nil
    internal var receiverBag: DisposeBag = DisposeBag()
    internal var messagesQueue: BehaviorRelay<Set<MessageQueueItem>> = BehaviorRelay(value: Set<MessageQueueItem>())
    
    internal var senderBag: DisposeBag = DisposeBag()
    
//    internal var scheduledMessages: Set<ScheduledMessage> = Set<ScheduledMessage>()
    internal var stanzaQueue: BehaviorRelay<Array<XMPPMessage>> = BehaviorRelay<Array<XMPPMessage>>(value: Array<XMPPMessage>())
    
//    internal var sendingMessages: Results<MessageStorageItem>? = nil
    internal var updateSendingMessagesTimer: Timer? = nil
    
    
    init(withOwner owner: String, activeStream: Bool) {
        self.queue = DispatchQueue(
            label: "com.xabber.messages.transmitter.\(owner).\(UUID().uuidString)",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .never,
            target: nil
        )
//        self.queue = DispatchQueue.global(qos: .background)
        
        super.init(withOwner: owner)
        subscribe(activeStream)
        if activeStream {
//            self.queue.async {
                do {
                    let realm = try  WRealm.safe()
                    let states = [
                        MessageStorageItem.MessageSendingState.sending.rawValue,
                        MessageStorageItem.MessageSendingState.uploading.rawValue,
                    ]
                    let collection = realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND state_ IN %@", self.owner, states)
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            collection.forEach {
                                $0.state = .error
                                $0.messageError = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                                $0.references.forEach({
                                    $0.hasError = true
                                })
                            }
                        }
                    }
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
//            }
        }
    }
    
    deinit {
        
    }
    
    internal func subscribe(_ activeStream: Bool) {
//        if activeStream {
//            checkTemporaryMessages()
//        }
        subscribeReceiver()
        subscribeSender()
        if self.updateSendingMessagesTimer != nil {
            self.updateSendingMessagesTimer?.fire()
            self.updateSendingMessagesTimer?.invalidate()
            self.updateSendingMessagesTimer = nil
        }
        self.updateSendingMessagesTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { (_) in
            do {
                let realm = try  WRealm.safe()
                
                let sendingMessages = realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND state_ IN %@", self.owner, [MessageStorageItem.MessageSendingState.sending.rawValue, MessageStorageItem.MessageSendingState.uploading.rawValue])
                var toEdit: Set<String> = Set<String>()
                sendingMessages.forEach {
                    message in
                    if [.quote, .text].contains(message.displayAs) {
                        if Date().timeIntervalSince(message.date) > 60 {
                            let primary = message.primary
                            toEdit.insert(primary)
                        }
                    } else {
                        var totalAttachesSize: Int = 0
                        totalAttachesSize = message.references.toArray().compactMap ({ return $0.sizeInBytesRaw }).reduce(0, +)
                        let totalSeconds = 60 + (totalAttachesSize / 1024 / 32)
                        if Date().timeIntervalSince(message.date) > TimeInterval(totalSeconds) {
                            let primary = message.primary
                            toEdit.insert(primary)
                        }
                    }
                }
                if toEdit.isEmpty { return }
                let collection = realm
                    .objects(MessageStorageItem.self)
                    .filter("primary IN %@", Array(toEdit))
                try realm.write {
                    collection.forEach {
                        $0.state = .error
                        $0.messageError = "Stream was disconnected".localizeString(id: "stream_was_disconnected_error", arguments: [])
                    }
                }
            } catch {
                DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
            }
        }
        RunLoop.main.add(self.updateSendingMessagesTimer!, forMode: RunLoop.Mode.default)
    }
    
    internal func unsubscribe() {
        
    }
    
    func readAllMessages() {
        do {
            let realm = try WRealm.safe()
            realm
                .objects(LastChatsStorageItem.self)
                .filter("isArchived == false AND owner == %@", self.owner)
                .sorted(byKeyPath: "messageDate", ascending: false)
                .compactMap { return $0.lastMessage?.primary }
                .forEach { self.readMessage($0, last: true) }
        } catch {
            DDLogDebug("MessagesManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func readLastMessage(jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if let primary = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType))?.lastMessage?.primary {
                self.readMessage(primary, last: true)
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func readMessage(_ primary: String, last: Bool) {
        do {
            let realm = try  WRealm.safe()
            if let message = realm.object(ofType: MessageStorageItem.self,
                                           forPrimaryKey: primary) {
                if message.outgoing {
                    return
                }
                let stanzaId = message.archivedId
                NotifyManager.shared.clearNotifications(forMessage: [stanzaId])
                let collection = realm.objects(MessageStorageItem.self).filter("owner == %@ AND opponent == %@ AND conversationType_ == %@ AND date < %@", self.owner, message.opponent, message.conversationType_, message.date)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        if message.isInvalidated { return }
                        message.isRead = true
                        message.state = .read
                        collection.forEach {
                            $0.isRead = true
                            $0.state = .read
                            if $0.readDate < 0 {
                                $0.readDate = Date().timeIntervalSince1970
                            }
                            if $0.afterburnInterval > 0 {
                                if $0.burnDate < 0 {
                                    $0.burnDate = Date().timeIntervalSince1970 + $0.afterburnInterval
                                }
                            }
                        }
                    }
                }
                if let instance = realm.object(ofType: LastChatsStorageItem.self,
                                               forPrimaryKey: LastChatsStorageItem.genPrimary(
                                                jid: message.opponent,
                                                owner: self.owner,
                                                conversationType: message.conversationType)),
                   instance.unread > 0 {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            if instance.isInvalidated { return }
                            if last {
                                instance.unread = 0
                            } else {
                                instance.unread -= 1
                            }
                        }
                    }
                }
            }
            
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.chatMarkers.displayed(stream, message: primary)
        })
    }
    
    internal func getForwardedAuthorNicknameGroupchat(_ references: [DDXMLElement]) -> String? {
        if let user = references.first(where: { ($0.attributeStringValue(forName: "type") ?? "none") == MessageReferenceStorageItem.Kind.groupchat.rawValue && $0.element(forName: "user") != nil })?.element(forName: "user") {
            return user.element(forName: "nickname")?.stringValue
        }
        return nil
    }
    
    internal func getMessageAuthorGroupchat(_ references: [DDXMLElement], jid: String) -> String? {
        guard let groupchatRef = references.first(where: { $0.element(forName: "user",
                                                                      xmlns: "https://xabber.com/protocol/groups") != nil }),
            let user = groupchatRef.element(forName: "user", xmlns: "https://xabber.com/protocol/groups") else {
                return nil
            }
        if let jid = user.element(forName: "jid")?.stringValue {
            return jid
        } else {
            if let id = user.attributeStringValue(forName: "id") {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                                   forPrimaryKey: GroupchatUserStorageItem
                                                    .genPrimary(id: id,
                                                                groupchat: jid,
                                                                owner: owner)) {
                        return instance.jid
                    }
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            }
        }
        return nil
    }
    
    public final func fail(message: XMPPMessage) {
        guard let elementId = message.elementID,
            let opponent = message.to?.bare,
            opponent != self.owner else {
                return
        }
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND messageId == %@", owner, opponent, elementId).first {
               
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.messageError = "Connection error".localizeString(id: "CONNECTION_FAILED", arguments: [])
                    instance.state = .error
                    instance.references.forEach({
                        $0.hasError = true
                    })
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func read(error message: XMPPMessage) -> Bool {
        guard let error = message.element(forName: "error"),
            let errorMessageRaw = error.children?.first?.name,
            let elementId = message.elementID,
            let opponent = message.to?.bare,
            opponent != self.owner else {
                return false
        }
        var errorMessage: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
        switch errorMessageRaw {
        case "gone": errorMessage = "Contact unavailable".localizeString(id: "message_manager_error_contact_unavailable", arguments: [])
        case "forbidden": errorMessage = "Forbidden".localizeString(id: "message_manager_error_forbidden", arguments: [])
        case "feature-not-implemented": errorMessage = "Feature not implemented".localizeString(id: "message_manager_error_not_implemented", arguments: [])
        case "conflict": errorMessage = "Conflict".localizeString(id: "message_manager_error_conflict", arguments: [])
        case "bad-request": errorMessage = "Bad request".localizeString(id: "message_maanger_error_bad_request", arguments: [])
        case "internal-server-error": errorMessage = "Internal server error".localizeString(id: "message_manager_error_internal_server", arguments: [])
        case "item-not-found": errorMessage = "Item not found".localizeString(id: "message_manager_error_no_item", arguments: [])
        case "jid-malformed": errorMessage = "JID mailformed".localizeString(id: "message_manager_error_mailformed_jid", arguments: [])
        case "not-acceptable": errorMessage = "Not acceptable".localizeString(id: "message_manager_error_unacceptable", arguments: [])
        case "not-allowed": errorMessage = "Not allowed".localizeString(id: "message_manager_error_unallowed", arguments: [])
        case "not-authorized": errorMessage = "Not authorized".localizeString(id: "message_manager_error_unauthorized", arguments: [])
        case "policy-violation": errorMessage = "Policy violation".localizeString(id: "message_manager_error_policy", arguments: [])
        case "recipient-unavailable": errorMessage = "Recipient unavailable".localizeString(id: "message_manager_error_recipient", arguments: [])
        case "redirect": errorMessage = "Redirect".localizeString(id: "message_manager_error_redirect", arguments: [])
        case "remote-server-not-found": errorMessage = "Remote server not found".localizeString(id: "message_manager_error_no_remote_server", arguments: [])
        case "remote-server-timeout": errorMessage = "Remote server timeout".localizeString(id: "message_manager_error_server_timeout", arguments: [])
        case "subscription-required": errorMessage = "Subscription required".localizeString(id: "message_manager_error_no_subscription", arguments: [])
        case "undefined-condition": errorMessage = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
        default: break
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND messageId == %@", owner, opponent, elementId).first {
               
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.messageError = errorMessage
                    instance.state = .error
                    instance.references.forEach({
                        $0.hasError = true
                    })
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            let messages = realm.objects(MessageStorageItem.self).filter("owner == %@", owner)
            let stanzas = realm.objects(MessageStanzaStorageItem.self).filter("owner == %@", owner)
            let inlines = realm.objects(MessageForwardsInlineStorageItem.self).filter("owner == %@", owner)
            let refs = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@", owner)
            let calls = realm.objects(CallMetadataStorageItem.self).filter("owner == %@", owner)

            let defaults  = UserDefaults.init(suiteName: PushNotificationsManager.suitName)
            defaults?.removeObject(forKey: "com.xabber.messages.temporary.\(owner)")
            
            if commitTransaction {
                try realm.write {
                    realm.delete(messages)
                    realm.delete(inlines)
                    realm.delete(refs)
                    realm.delete(stanzas)
                    realm.delete(calls)
                }
            } else {
                realm.delete(messages)
                realm.delete(inlines)
                realm.delete(refs)
                realm.delete(stanzas)
                realm.delete(calls)
            }
        } catch {
            DDLogDebug("cant remove messages for account \(owner)")
        }
    }
    
}
