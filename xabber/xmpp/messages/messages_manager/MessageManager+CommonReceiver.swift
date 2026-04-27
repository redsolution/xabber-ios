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

    @discardableResult
    internal func performMessageQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: self.queueSpecificKey) == self.queueSpecificValue {
            return block()
        }
        return self.queue.sync(execute: block)
    }

    internal func publishQueuedMessagesSnapshot() {
        self.messagesQueue.accept(self.queuedMessages)
    }

    private func adjustPendingMessageCount(
        _ storage: inout [String: Int],
        for queryId: String?,
        delta: Int
    ) {
        guard let queryId, queryId.isNotEmpty else {
            return
        }

        let nextValue = (storage[queryId] ?? 0) + delta
        if nextValue > 0 {
            storage[queryId] = nextValue
        } else {
            storage.removeValue(forKey: queryId)
        }
    }

    private func adjustQueuedMessageCounts(for items: some Sequence<MessageQueueItem>, delta: Int) {
        items.forEach { item in
            self.adjustPendingMessageCount(&self.queuedMessageCountsByQueryId, for: item.queryId, delta: delta)
        }
    }

    private func adjustInFlightMessageCounts(for items: some Sequence<MessageQueueItem>, delta: Int) {
        items.forEach { item in
            self.adjustPendingMessageCount(&self.inFlightMessageCountsByQueryId, for: item.queryId, delta: delta)
        }
    }

    internal func hasPendingMessages(forQueryId queryId: String) -> Bool {
        self.performMessageQueueSync {
            (self.queuedMessageCountsByQueryId[queryId] ?? 0) > 0 ||
            (self.inFlightMessageCountsByQueryId[queryId] ?? 0) > 0
        }
    }

    internal func scheduleQueuedMessagesDrainIfNeeded() {
        self.performMessageQueueSync {
            guard self.isReceiverActive,
                  !self.isQueuedMessagesDrainScheduled,
                  !self.queuedMessages.isEmpty else {
                return
            }
            self.isQueuedMessagesDrainScheduled = true
            self.queue.async { [weak self] in
                self?.drainQueuedMessagesAndPersist()
            }
        }
    }

    internal func drainQueuedMessagesAndPersist() {
        self.performMessageQueueSync {
            guard self.isReceiverActive else {
                self.isQueuedMessagesDrainScheduled = false
                return
            }

            let results = self.drainQueuedMessages()
            self.adjustInFlightMessageCounts(for: results, delta: 1)
            self.isQueuedMessagesDrainScheduled = false
            self.processQueue(results, callback: { values in
                if let batch = values {
                    self.save(batch)
                }
            })
            self.adjustInFlightMessageCounts(for: results, delta: -1)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()

            if self.isReceiverActive, !self.queuedMessages.isEmpty {
                self.scheduleQueuedMessagesDrainIfNeeded()
            }
        }
    }

    internal func drainQueuedMessages() -> Set<MessageQueueItem> {
        self.performMessageQueueSync {
            let snapshot = self.queuedMessages
            self.adjustQueuedMessageCounts(for: snapshot, delta: -1)
            self.queuedMessages.removeAll()
            self.publishQueuedMessagesSnapshot()
            return snapshot
        }
    }
    
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
        var messageId: String? = nil
        
        init(_ message: XMPPMessage, messageId: String?, archivedFrom: String?, isRead: Bool, date: Date, state: MessageStorageItem.MessageSendingState, forceUnreadState: Bool? = nil, clientSyncMessage: Bool = false, queryId: String?, groupchatUserCard: DDXMLElement? = nil, readDate: Date? = nil) {
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
            self.messageId = messageId
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(message.xmlString)
            hasher.combine(date)
        }
    }

    struct ReadStateReconciliationRequest: Hashable {
        let owner: String
        let opponent: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let itemDate: Date
        let readDate: Date?
        let afterburnInterval: Double
    }

    struct ProcessedQueueBatch {
        let messages: [MessageStorageItem]
        let readStateRequests: [ReadStateReconciliationRequest]
    }
    
//    public func resetQueue() {
//        clearQueue()
//        subscribe(true)
//    }
    
    public func receiveClientSyncRaw(_ message: XMPPMessage, groupchatUserCard: DDXMLElement?, isRead: Bool, state: MessageStorageItem.MessageSendingState, date: Date, readDate: Date? = nil) -> MessageQueueItem? {
        return MessageQueueItem(
            message,
            messageId: getOriginId(message),
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
                                 messageId: getOriginId(message),
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
                                     messageId: getOriginId(messageBare),
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
                                     messageId: getOriginId(messageBare),
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
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: messageBare.from?.bare,
                                     isRead: true,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message)))
            guard let from = messageBare.from?.bare else { return }
//            do {
//                let conversationType = conversationTypeByMessage(message)
//                let realm = try WRealm.safe()
//                try realm.write {
//                    realm
//                        .objects(MessageStorageItem.self)
//                        .filter("owner == %@ AND opponent == %@ AND state_ < %@ AND date <= %@ AND conversationType_ == %@",
//                                owner,
//                                from,
//                                MessageStorageItem.MessageSendingState.read.rawValue,
//                                getDeliveryTime(message, owner: owner) ?? Date(),
//                                conversationType.rawValue)
//                        .forEach {
//                            $0.state = .read
//                            $0.isRead = true
//                            if $0.burnDate <= 1 {
//                                if $0.afterburnInterval > 0 {
//                                    $0.readDate = Date().timeIntervalSince1970
//                                    $0.burnDate = Date().timeIntervalSince1970 + $0.afterburnInterval
//                                }
//                            }
//                        }
//                }
//            } catch {
//                DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
//            }
        }
    }
    
    public func receiveCarbonForwarded(_ message: XMPPMessage) {
        if let messageBare = getCarbonForwardedMessageContainer(message) {
            enqueue(MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: message.from?.bare,
                                     isRead: false,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message)))
        }
    }
    
    public func receiveRuntime(_ message: XMPPMessage) {
        enqueue(MessageQueueItem(message,
                                 messageId: getOriginId(message),
                                 archivedFrom: message.from?.bare,
                                 isRead: false,
                                 date: getDeliveryTime(message, owner: owner) ?? Date(),
                                 state: .sended,
                                 queryId: getMAMQueryId(message)))
    }
    
    
    
    public func updateReadDate(for messageId: String, stanzaId: String, jid: String, date: Date) {
//        RunLoop.current.perform {
        self.prereadedMessages.append(PrereadedMessagesItem(messageId: messageId, stanzaId: stanzaId, date: date, jid: jid))
//        }
        
    }
    
    internal func clearQueue(_ item: MessageQueueItem) {
        self.performMessageQueueSync {
            if self.queuedMessages.remove(item) != nil {
                self.adjustQueuedMessageCounts(for: [item], delta: -1)
            }
            self.publishQueuedMessagesSnapshot()
        }
    }
    
    internal func clearQueue() {
        self.performMessageQueueSync {
            self.adjustQueuedMessageCounts(for: self.queuedMessages, delta: -1)
            self.queuedMessages.removeAll()
            self.publishQueuedMessagesSnapshot()
        }
    }
    
    internal func subscribeReceiver() {
        receiverBag = DisposeBag()
        self.performMessageQueueSync {
            self.isReceiverActive = true
        }
        self.scheduleQueuedMessagesDrainIfNeeded()
    }
    
    internal func unsubscribeReceiver() {
        receiverBag = DisposeBag()
        self.performMessageQueueSync {
            self.isReceiverActive = false
            self.isQueuedMessagesDrainScheduled = false
        }
        clearQueue()
    }
    
    func processQueue(_ items: Set<MessageQueueItem>, callback: ((ProcessedQueueBatch?) -> Void)) {
        if items.isEmpty {
            return callback(nil)
        }
        var messageQueryIds: Set<String> = Set<String>()
        var out: Set<MessageStorageItem> = Set<MessageStorageItem>()
        var readStateRequests: [ReadStateReconciliationRequest] = []
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
            
            let afterburnInterval = item.message.element(forName: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeDoubleValue(forName: "timer") ?? 0
            
            var hasSignElement: Bool = false
            var envelopeContainer: String? = nil
//            print("RECEIVER", #function, item.message.prettyXMLString!)
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
            
            if let userId = groupchatUserElement(from: item.message)?
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
            
//            if item.originalOutgoing || item.state == .read {
//                item.isRead = true
            let conversationType = conversationTypeByMessage(item.message)
            let readDate = item.isRead ? (item.readDate ?? prereadedMessages.first(where: { item.messageId == $0.messageId })?.date) : nil// ?? prereadedConversation.first(where: { $0.jid == opponent && $0.conversationType == conversationType })?.date) : nil
            if let readDate = readDate,
               item.date < readDate {
                item.isRead = true
            } else {
                item.isRead = item.state == .read
            }
            readStateRequests.append(
                ReadStateReconciliationRequest(
                    owner: self.owner,
                    opponent: opponent,
                    conversationType: conversationType,
                    itemDate: item.date,
                    readDate: readDate,
                    afterburnInterval: afterburnInterval
                )
            )
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
//                print(instance)
                instance.state = item.state
                
            }
            instance.envelopeContainer = envelopeContainer
            instance.updatePrimary()
            if afterburnInterval > 0 {
                instance.applyAutoDeleteTTL(afterburnInterval, startsAt: item.date)
            } else {
                instance.afterburnInterval = afterburnInterval
            }
            
            instance.queryIds = item.queryId
            
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
//            print("PIPELINED", item.message)
            
            
            if isEncryptedMessage {
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
            }
            
//            let conversationType = instance.conversationType
            
//            let readDate = item.isRead ? item.readDate ?? prereadedMessages.first(where: { item.messageId == $0.messageId })?.date ?? prereadedConversation.first(where: { $0.jid == opponent && $0.conversationType == conversationType })?.date : nil
            
            if afterburnInterval > 0 {
                if isEncryptedMessage {
                    if !errorMetadata.isEmpty {
                        if omemoError {
                            instance.isDeleted = true
                        }
                    }
                }
            }
            if let readDate = readDate,
               afterburnInterval > 0 {
                instance.isRead = true
                if !item.originalOutgoing {
                    instance.state = .read
                }
                instance.readDate = readDate.timeIntervalSince1970
                if instance.autoDeleteExpiresAt <= 0 {
                    instance.burnDate = readDate.timeIntervalSince1970 + afterburnInterval
                }
                
                if let index = self.prereadedConversation.firstIndex(where: {$0.jid == opponent && $0.conversationType == conversationType}) {
                    if self.prereadedConversation[index].date < readDate {
                        self.prereadedConversation[index].date = readDate
                    }
                } else {
                    self.prereadedConversation.append(PrereadedConversationItem(conversationType: conversationType, date: readDate, jid: opponent))
                }
                
                if instance.effectiveAutoDeleteExpiresAt > 0,
                   instance.effectiveAutoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                    instance.markAutoDeleted()
//                    instance.errorMetadata_ = ""
//                    instance.messageError = nil
                }
            }
            if instance.autoDeleteExpiresAt > 0,
               instance.autoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                instance.markAutoDeleted()
            }
            
            out.insert(instance)
        }
        callback(
            ProcessedQueueBatch(
                messages: Array(out).sorted(by: { $0.date < $1.date}),
                readStateRequests: readStateRequests
            )
        )
    }
    
    internal func enqueue(_ item: MessageQueueItem) {
        self.performMessageQueueSync {
            if self.queuedMessages.update(with: item) == nil {
                self.adjustQueuedMessageCounts(for: [item], delta: 1)
            }
            self.publishQueuedMessagesSnapshot()
            self.scheduleQueuedMessagesDrainIfNeeded()
        }
    }
    
    internal func enqueue(collection: [MessageQueueItem]) {
        self.performMessageQueueSync {
            collection.forEach {
                if self.queuedMessages.update(with: $0) == nil {
                    self.adjustQueuedMessageCounts(for: [$0], delta: 1)
                }
            }
            self.publishQueuedMessagesSnapshot()
            self.scheduleQueuedMessagesDrainIfNeeded()
        }
    }
    
    func unsafeSave(_ messages: [MessageStorageItem]) {
        autoreleasepool {
            messages.forEach {
                _ = $0.save(commitTransaction: false)
            }
        }
    }
    
    func storeMessagesNow() {
        let results = self.drainQueuedMessages()
        self.processQueue(results, callback: { (values) in
            if let batch = values {
                self.save(batch)
            }
        })
        AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()
    }
    
    private func reconcileReadStates(_ requests: [ReadStateReconciliationRequest], in realm: Realm) -> Set<String> {
        var clearedNotifications: Set<String> = []
        var affectedChats: Set<String> = []

        requests.forEach { request in
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: request.opponent,
                    owner: request.owner,
                    conversationType: request.conversationType
                )
            ), chat.lastMessage != nil else {
                return
            }

            guard request.itemDate.timeIntervalSinceReferenceDate > chat.messageDate.timeIntervalSinceReferenceDate else {
                return
            }

            affectedChats.insert(request.opponent)

            realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND isRead == %@ AND conversationType_ == %@",
                    request.owner,
                    request.opponent,
                    false,
                    request.conversationType.rawValue
                )
                .forEach {
                    clearedNotifications.insert($0.archivedId)
                    $0.isRead = true
                    if $0.afterburnInterval > 0 && $0.burnDate <= 1 && $0.autoDeleteExpiresAt <= 0,
                       let readDate = request.readDate {
                        $0.readDate = readDate.timeIntervalSince1970
                        $0.burnDate = readDate.timeIntervalSince1970 + request.afterburnInterval
                        if (readDate.timeIntervalSince1970 + request.afterburnInterval) < Date().timeIntervalSince1970 {
                            $0.markAutoDeleted()
                        }
                    }
                }
        }

        if affectedChats.isNotEmpty {
            _ = MentionNotificationSync.reconcileMentionNotifications(
                for: self.owner,
                chats: affectedChats,
                in: realm
            )
        }

        return clearedNotifications
    }

    func save(_ batch: ProcessedQueueBatch, silentNotifications: Bool = false) {
        do {
            let realm = try  WRealm.safe()
            var clearedStanzaIDs: Set<String> = []
            var notificationPayloads: [MessageStorageItem.SaveNotificationPayload] = []
            var messagePrimariesToMarkRead: Set<String> = []
            let affectedChats = Set(batch.messages.compactMap { message -> String? in
                guard message.conversationType == .group else {
                    return nil
                }
                return message.opponent
            })

            try realm.write {
                clearedStanzaIDs = self.reconcileReadStates(batch.readStateRequests, in: realm)
                batch.messages.forEach {
                    if let sideEffects = $0.applyMessagePersistence(in: realm, silentNotifications: silentNotifications) {
                        if sideEffects.shouldStoreStanza {
                            $0.storeStanza(in: realm)
                        }
                        if let notification = sideEffects.notification {
                            notificationPayloads.append(notification)
                        }
                    }
                }
                if affectedChats.isNotEmpty {
                    messagePrimariesToMarkRead = MentionNotificationSync.reconcileMentionNotifications(
                        for: self.owner,
                        chats: affectedChats,
                        in: realm
                    )
                }
            }

            if clearedStanzaIDs.isNotEmpty {
                NotifyManager.shared.clearNotifications(forMessage: Array(clearedStanzaIDs))
            }

            notificationPayloads.forEach {
                NotifyManager.shared.update(
                    withMessage: $0.message,
                    messageId: $0.messageId,
                    username: $0.username,
                    opponent: $0.opponent,
                    owner: $0.owner,
                    date: $0.date,
                    displayName: $0.displayName,
                    imageUrl: $0.imageUrl,
                    conversationType: $0.conversationType
                )
            }

            messagePrimariesToMarkRead.forEach { primary in
                self.readMessage(primary, last: false)
            }

            batch.messages.forEach {
                message in
                message.references.forEach {
                    reference in
                    reference.prepare()
                }
            }
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()
        } catch {
            DDLogDebug("cant save messages colelction")
        }
    }

    func save(_ messages: [MessageStorageItem], silentNotifications: Bool = false) {
        save(ProcessedQueueBatch(messages: messages, readStateRequests: []), silentNotifications: silentNotifications)
    }
}
