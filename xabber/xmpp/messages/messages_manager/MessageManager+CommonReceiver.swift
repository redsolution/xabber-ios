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
import RxRealm


extension MessageManager {
    
    class MessageQueueItem: Hashable {
        
        static func == (lhs: MessageQueueItem, rhs: MessageQueueItem) -> Bool {
            return lhs.message.xmlString == rhs.message.xmlString &&
                lhs.date == rhs.date
        }
        
        var isRead: Bool = true
        var date: Date = Date()
        var message: XMPPMessage
        var state: MessageStorageItem.MessageSendingState = MessageStorageItem.MessageSendingState.none
        var originalFrom: String = ""
        var archivedFrom: String? = nil
        var originalOutgoing: Bool = false
        var forceUnreadState: Bool? = nil
        var clientSyncMessage: Bool = false
        var queryId: String? = nil
        var groupchatUserCard: DDXMLElement? = nil
        var readDate: Date? = nil
        
        init(_ message: XMPPMessage, archivedFrom: String?, isRead: Bool, date: Date, state: MessageStorageItem.MessageSendingState, forceUnreadState: Bool? = nil, clientSyncMessage: Bool = false, queryId: String?, groupchatUserCard: DDXMLElement? = nil, readDate: Date? = nil) {
            self.message = message
            self.archivedFrom = archivedFrom
            self.isRead = isRead
            self.date = date
            self.state = state
            self.forceUnreadState = forceUnreadState
            self.clientSyncMessage = clientSyncMessage
            self.groupchatUserCard = groupchatUserCard
            self.queryId = queryId
            self.readDate = readDate
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(message.xmlString)
            hasher.combine(date)
        }
    }
    
    public func resetQueue() {
        clearQueue()
        subscribe(true)
    }
    
    public func receiveClientSyncRaw(_ message: XMPPMessage, groupchatUserCard: DDXMLElement?, isRead: Bool, state: MessageStorageItem.MessageSendingState, date: Date, readDate: Date? = nil) -> MessageQueueItem? {
        return MessageQueueItem(
            message,
            archivedFrom: message.from?.bare,
            isRead: isRead,
            date: date,
            state: state,
            forceUnreadState: isRead,
            clientSyncMessage: true,
            queryId: getMAMQueryId(message),
            groupchatUserCard: groupchatUserCard,
            readDate: readDate
        )
    }
    
    public func receiveClientSync(_ message: XMPPMessage, isRead: Bool, state: MessageStorageItem.MessageSendingState, date: Date) {
        enqueue(MessageQueueItem(message,
                                 archivedFrom: message.from?.bare,
                                 isRead: isRead,
                                 date: date,
                                 state: state,
                                 forceUnreadState: isRead,
                                 clientSyncMessage: true,
                                 queryId: getMAMQueryId(message)))
        
    }
    
    public func receiveTemporary(_ message: XMPPMessage) -> MessageQueueItem? {
        if let date = getDelayedDate(message),
            let messageBare = getArchivedMessageContainer(message) {
             return MessageQueueItem(messageBare,
                                     archivedFrom: message.from?.bare,
                                     isRead: message.from?.bare == owner ? true : false,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? date,
                                     state: .deliver,
                                     clientSyncMessage: true,
                                     queryId: getMAMQueryId(message))
        }
        return nil
    }
    
    public func receiveArchived(_ message: XMPPMessage) {
        if let date = getDelayedDate(message),
            let messageBare = getArchivedMessageContainer(message) {
            enqueue(MessageQueueItem(messageBare,
                                     archivedFrom: message.from?.bare,
                                     isRead: true,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? date,
                                     state: .deliver,
                                     queryId: getMAMQueryId(message)))
        }
    }
    
    public func receiveCarbon(_ message: XMPPMessage) {
        if let messageBare = getCarbonCopyMessageContainer(message) {
            enqueue(MessageQueueItem(messageBare,
                                     archivedFrom: message.from?.bare,
                                     isRead: true,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message)))
        }
    }
    
    public func receiveCarbonForwarded(_ message: XMPPMessage) {
        if let messageBare = getCarbonForwardedMessageContainer(message) {
            enqueue(MessageQueueItem(messageBare,
                                     archivedFrom: message.from?.bare,
                                     isRead: false,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message)))
        }
    }
    
    public func receiveRuntime(_ message: XMPPMessage) {
        enqueue(MessageQueueItem(message,
                                 archivedFrom: message.from?.bare,
                                 isRead: false,
                                 date: getDeliveryTime(message, owner: owner) ?? Date(),
                                 state: .sended,
                                 queryId: getMAMQueryId(message)))
        if let from = message.from?.bare,
            from != owner {
            CommonChatStatesManager.shared.update(jid: from, owner: owner, state: .none)
            do {
                let conversationType = conversationTypeByMessage(message)
                let realm = try WRealm.safe()
                try realm.write {
                    realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND outgoing == true AND state_ == %@ AND date <= %@ AND conversationType_ == %@",
                                owner,
                                from,
                                MessageStorageItem.MessageSendingState.deliver.rawValue,
                                getDeliveryTime(message, owner: owner) ?? Date(),
                                conversationType.rawValue)
                        .forEach { $0.state = .read}
                }
            } catch {
                DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        
        
        
        
    }
    
    internal func clearQueue(_ item: MessageQueueItem) {
        var value = self.messagesQueue.value
        value.remove(item)
        self.messagesQueue.accept(value)
    }
    
    internal func clearQueue() {
        self.messagesQueue.accept(Set())
    }
    
    internal func subscribeReceiver() {
        receiverBag = DisposeBag()
//        self.receiverSubscribtion = nil
//        self.receiverSubscribtion =
        self.messagesQueue
            .asObservable()
            .debounce(.milliseconds(500),
                      scheduler: SerialDispatchQueueScheduler(
                        queue: self.queue,
                        internalSerialQueueName: "com.xabber.msgQueue"))
            .subscribe(onNext: { (results) in
                self.processQueue(results, callback: { (values) in
                    if let messages = values {
                        self.save(messages)
                    }
                })
                }, onError: { (error) in
                    DDLogDebug(error.localizedDescription)
                }, onCompleted: {
                    DDLogDebug("message queue complited")
                }) {
                    DDLogDebug("message queue disposed")
            }
        .disposed(by: receiverBag)
    }
    
    internal func unsubscribeReceiver() {
        receiverBag = DisposeBag()
        clearQueue()
    }
    
    func processQueue(_ items: Set<MessageQueueItem>, callback: (([MessageStorageItem]?) -> Void)) {
        if items.isEmpty {
            return callback(nil)
        }
        var messageQueryIds: Set<String> = Set<String>()
        var out: Set<MessageStorageItem> = Set<MessageStorageItem>()
        let sortedItems = Array(items).sorted(by: {
            $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970
        })
        sortedItems.forEach { (item) in
            if isVoIPMessage(item.message) {
                return
            }
            let instance: MessageStorageItem = MessageStorageItem()
            let from = item.message.from?.bare ?? item.archivedFrom ?? item.originalFrom
            guard let to = item.message.to?.bare else {
                    return
            }
            if let formElement = item.message.element(forName: "x", xmlns: "jabber:x:data"),
                formElement.attributeStringValue(forName: "type") == "submit" {
                return
            }
            let opponent = to != owner ? to : from
            
            var omemoError: Bool = !(item.message.element(forName: "omemo-result__system")?.attributeBoolValue(forName: "result") ?? false)
            var errorMetadata: [String: Any] = [:]
            var isEncryptedMessage: Bool = false
            if item.message.element(forName: "encrypted") != nil {
                isEncryptedMessage = true
                errorMetadata = SignatureManager.MessageError().errorMetadata
            }
            
            let afterburnInterval = item.message.element(forName: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeDoubleValue(forName: "timer") ?? -1
            
            var hasSignElement: Bool = false
            var envelopeContainer: String? = nil
            print("RECEIVER", #function, item.message.prettyXMLString!)
            if let sign = item.message.element(forName: "time-signature", xmlns: SignatureManager.xmlns){
                omemoError = false
                hasSignElement = true
                envelopeContainer = sign.xmlString
                do {
                    errorMetadata = try SignatureManager.shared.checkSignature(
                        owner: self.owner,
                        for: from,
                        signature: sign,
                        messageDate: item.date
                    ).errorMetadata
                } catch {
                    errorMetadata = SignatureManager.MessageError().errorMetadata
                }
            }
            
            if let userId = item
                .message
                .element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
                .element(forName: "reference")?
                .element(forName: "user", xmlns: "https://xabber.com/protocol/groups")?
                .attributeStringValue(forName: "id") {
                if let userCard = item.groupchatUserCard,
                    let myId = userCard.attributeStringValue(forName: "id") {
                    item.originalOutgoing = userId == myId
                } else {
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [userId, opponent, owner].prp()) {
                            item.originalOutgoing = instance.isMe
                        }
                    } catch {
                        DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                    }
                }
            } else if let groupchatRef = item.message
                    .element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
                    .elements(forName: "reference"),
                    let groupchatAuthor = getMessageAuthorGroupchat(groupchatRef, jid: opponent) {
                    item.originalOutgoing = groupchatAuthor == owner
            } else {
                item.originalOutgoing = from == owner
            }
            
            if item.originalOutgoing || item.state == .read {
                item.isRead = true
                RunLoop.main.perform {
                    do {
                        let realm = try  WRealm.safe()
                        if let chat = realm.object(
                            ofType: LastChatsStorageItem.self,
                            forPrimaryKey: LastChatsStorageItem.genPrimary(
                                jid: item.originalFrom,
                                owner: self.owner,
                                conversationType: conversationTypeByMessage(item.message)
                            )
                        ) {
                            if chat.lastMessage != nil {
                                var stanzaIDs: Set<String> = Set<String>()
                                if item.date.timeIntervalSinceReferenceDate > chat.messageDate.timeIntervalSinceReferenceDate {
                                    realm.writeAsync {
                                        realm
                                            .objects(MessageStorageItem.self)
                                            .filter("owner == %@ AND opponent == %@ AND isRead == %@", self.owner, item.originalFrom, false)
                                            .forEach {
                                                stanzaIDs.insert($0.archivedId)
                                                $0.isRead = true
                                                if $0.afterburnInterval > 0 && $0.burnDate < 0 {
                                                    
                                                    if let readDate = item.readDate {
                                                        $0.readDate = readDate.timeIntervalSince1970
                                                        $0.burnDate = readDate.timeIntervalSince1970 + afterburnInterval
                                                        if (readDate.timeIntervalSince1970 + afterburnInterval) < Date().timeIntervalSince1970 {
                                                            $0.isDeleted = true
                                                        }
                                                    }
                                                }
                                            }
                                    }
                                }
                                NotifyManager.shared.clearNotifications(forMessage: Array(stanzaIDs))
                            }
                        }
                    } catch {
                        DDLogDebug("cant read unreaded messages")
                    }
                }
                
            } else {
                item.state = .none
                do {
                    let realm = try WRealm.safe()
                    if let chat = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: item.originalFrom,
                            owner: self.owner,
                            conversationType: conversationTypeByMessage(item.message)
                        )
                    ) {
                        if chat.lastMessage == nil {
                            item.isRead = false
                        } else {
                            if item.date.timeIntervalSinceReferenceDate < chat.messageDate.timeIntervalSinceReferenceDate {
                                item.isRead = true
                            } else {
                                item.isRead = false
                            }
                        }
                    }
                } catch {
                    DDLogDebug("cant update unread state for message \(item.message.elementID ?? "")")
                }
            }
            
            if parseSystemMessageMetadata(item.message) != nil {
                instance.configureSystemMessage(item.message,
                                                owner: owner,
                                                opponent: opponent,
                                                date: item.date)
                instance.state = .none
                instance.isRead = item.forceUnreadState ?? item.isRead
            } else {
                instance.configureIncomingMessage(item.message,
                                          owner: owner,
                                          opponent: opponent,
                                          outgoing: item.originalOutgoing,
                                          isRead: item.forceUnreadState ?? item.isRead,
                                          date: item.date, isEncrypted: isEncryptedMessage)
                instance.forceUnreadState = item.forceUnreadState
                print(instance)
                instance.state = item.state
                
            }
            instance.envelopeContainer = envelopeContainer
            instance.updatePrimary()
            instance.afterburnInterval = afterburnInterval
            if let readDate = item.readDate,
               afterburnInterval > 0 {
                instance.isRead = true
                instance.readDate = readDate.timeIntervalSince1970
                instance.burnDate = readDate.timeIntervalSince1970 + afterburnInterval
                if instance.burnDate < Date().timeIntervalSince1970 {
                    instance.isDeleted = true
                }
            }
            if hasSignElement {
                instance.errorMetadata = errorMetadata
            }
            
            if item.clientSyncMessage {
                instance.trustedSource = false
            } else {
                if let queryId = item.queryId {
                    if messageQueryIds.contains(queryId) {
                        instance.trustedSource = true
                    } else {
                        messageQueryIds.insert(queryId)
                        instance.trustedSource = false
                    }
                } else {
                    instance.trustedSource = false
                }
            }
            
            instance.previousId = getPreviousId(item.message)
            print("PIPELINED", item.message)
            
            if !errorMetadata.isEmpty {
                if omemoError {
                    instance.messageError = "omemo"
//                    instance.state = .error
                } else {
                    if hasSignElement {
                        instance.messageError = "cert_error"
//                        instance.state = .error
                    }
                }
            }
            out.insert(instance)
        }
        callback(Array(out).sorted(by: { $0.date < $1.date}))
        items.forEach { clearQueue($0) }
    }
    
    internal func enqueue(_ item: MessageQueueItem) {
//        self.queue.sync {
            var value = self.messagesQueue.value
            value.update(with: item)
            messagesQueue.accept(value)
//        }
    }
    
    internal func enqueue(collection: [MessageQueueItem]) {
        collection.forEach { enqueue($0)}
    }
    
    func unsafeSave(_ messages: [MessageStorageItem]) {
        autoreleasepool {
            messages.forEach {
                if $0.save(commitTransaction: false) {
                    $0.storeStanza()
                }
            }
        }
    }
    
    func storeMessagesNow() {
        var results = self.messagesQueue.value
        self.messagesQueue.accept(Set())
        self.processQueue(results, callback: { (values) in
            if let messages = values {
                self.save(messages)
            }
        })
    }
    
    func save(_ messages: [MessageStorageItem], silentNotifications: Bool = false) {
//        RunLoop.main.perform {
            do {
                let realm = try  WRealm.safe()
    //            try autoreleasepool {
                try realm.write {
                        messages.forEach {
                            if $0.save(commitTransaction: false, silentNotifications: silentNotifications) {
                                $0.storeStanza()
                            }
                        }
                    }
    //            }
            } catch {
                DDLogDebug("cant save messages colelction")
            }
//        }
    }
}
