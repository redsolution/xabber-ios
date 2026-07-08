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

    private enum ArchivePersistenceOutcome: Equatable {
        case savedNew
        case updatedExisting
        case skipped
        case failed
    }

    private struct ArchivePersistenceOutcomeItem {
        let queryIds: [String]
        let owner: String
        let opponent: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let isDeleted: Bool
        let outcome: ArchivePersistenceOutcome
    }

    private func updateArchivePersistenceSummary(
        for queryId: String?,
        _ update: (inout ArchivePersistenceSummary) -> Void
    ) {
        guard let queryId,
              queryId.isNotEmpty else {
            return
        }

        var summary = self.archivePersistenceSummariesByQueryId[queryId] ?? ArchivePersistenceSummary()
        update(&summary)
        self.archivePersistenceSummariesByQueryId[queryId] = summary
    }

    private func queryIds(from message: MessageStorageItem) -> [String] {
        message.queryIds?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isNotEmpty } ?? []
    }

    private func recordArchivePersistenceOutcomes(_ outcomes: [ArchivePersistenceOutcomeItem]) {
        self.performMessageQueueSync {
            outcomes.forEach { item in
                item.queryIds.forEach { queryId in
                    self.updateArchivePersistenceSummary(for: queryId) { summary in
                        switch item.outcome {
                        case .savedNew:
                            summary.savedNew += 1
                        case .updatedExisting:
                            summary.updatedExisting += 1
                        case .skipped:
                            summary.skipped += 1
                        case .failed:
                            summary.failed += 1
                        }

                        if item.outcome != .skipped,
                           item.outcome != .failed,
                           !item.isDeleted {
                            summary.recordVisibleRow(
                                owner: item.owner,
                                jid: item.opponent,
                                conversationType: item.conversationType
                            )
                        }
                    }
                }
            }
        }
    }

    private func archivePersistenceSummarySnapshot(forQueryId queryId: String) -> ArchivePersistenceSummary {
        self.archivePersistenceSummariesByQueryId[queryId] ?? ArchivePersistenceSummary()
    }

    internal func hasPendingMessages(forQueryId queryId: String) -> Bool {
        self.performMessageQueueSync {
            (self.queuedMessageCountsByQueryId[queryId] ?? 0) > 0 ||
            (self.inFlightMessageCountsByQueryId[queryId] ?? 0) > 0
        }
    }

    internal func shouldPersistArchiveQueryId(_ queryId: String?) -> Bool {
        if let archiveQueryIdPersistenceResolver {
            return archiveQueryIdPersistenceResolver(queryId)
        }

        return AccountManager.shared
            .find(for: owner)?
            .mam
            .shouldPersistArchiveQueryId(queryId) ?? false
    }

    internal func clearArchivePersistenceSummary(forQueryId queryId: String) {
        self.performMessageQueueSync {
            self.archivePersistenceSummariesByQueryId.removeValue(forKey: queryId)
        }
    }

    internal func scheduleQueuedMessagesDrainIfNeeded() {
        self.performMessageQueueSync {
            self.scheduleQueuedMessagesDrainOnQueue()
        }
    }

    internal func scheduleQueuedMessagesDrainWithoutWaiting() {
        self.queue.async { [weak self] in
            self?.scheduleQueuedMessagesDrainOnQueue()
        }
    }

    private func scheduleQueuedMessagesDrainOnQueue() {
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
                    _ = self.save(batch)
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
        var shouldPersistArchiveQueryId: Bool = false
        var countsAsRuntimeUnread: Bool = false
        
        init(_ message: XMPPMessage, messageId: String?, archivedFrom: String?, isRead: Bool, date: Date, state: MessageStorageItem.MessageSendingState, forceUnreadState: Bool? = nil, clientSyncMessage: Bool = false, queryId: String?, shouldPersistArchiveQueryId: Bool = false, countsAsRuntimeUnread: Bool = false, groupchatUserCard: DDXMLElement? = nil, readDate: Date? = nil) {
            self.message = message
            self.archivedFrom = archivedFrom
            self.isRead = isRead
            self.date = date
            self.state = state
            self.forceUnreadState = forceUnreadState
            self.clientSyncMessage = clientSyncMessage
            self.groupchatUserCard = groupchatUserCard
            self.queryId = queryId
            self.shouldPersistArchiveQueryId = shouldPersistArchiveQueryId
            self.countsAsRuntimeUnread = countsAsRuntimeUnread
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
        let archiveQueryIdsByPrimary: [String: [String]]

        init(
            messages: [MessageStorageItem],
            readStateRequests: [ReadStateReconciliationRequest],
            archiveQueryIdsByPrimary: [String: [String]] = [:]
        ) {
            self.messages = messages
            self.readStateRequests = readStateRequests
            self.archiveQueryIdsByPrimary = archiveQueryIdsByPrimary
        }

        func chunks(maxSize: Int) -> [ProcessedQueueBatch] {
            let chunkSize = max(1, maxSize)
            guard messages.count > chunkSize else {
                return [self]
            }

            return stride(from: 0, to: messages.count, by: chunkSize).map { startIndex in
                let endIndex = min(startIndex + chunkSize, messages.count)
                let messageChunk = Array(messages[startIndex..<endIndex])
                let chunkPrimaries = Set(messageChunk.map(\.primary))
                let chunkArchiveQueryIds = archiveQueryIdsByPrimary.filter { primary, _ in
                    chunkPrimaries.contains(primary)
                }
                let readStateChunk: [ReadStateReconciliationRequest]
                if readStateRequests.count == messages.count {
                    readStateChunk = Array(readStateRequests[startIndex..<endIndex])
                } else {
                    readStateChunk = startIndex == 0 ? readStateRequests : []
                }
                return ProcessedQueueBatch(
                    messages: messageChunk,
                    readStateRequests: readStateChunk,
                    archiveQueryIdsByPrimary: chunkArchiveQueryIds
                )
            }
        }
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
        let queryId = getMAMQueryId(message)
        ChatArchiveDebugTrace.log("mamResultMessageReceived", [
            ("owner", self.owner),
            ("queryId", queryId ?? "-"),
            ("wrapperId", message.element(forName: "result")?.attributeStringValue(forName: "id") ?? "-"),
            ("from", message.from?.bare ?? "-"),
            ("hasArchivedContainer", getArchivedMessageContainer(message) != nil)
        ])
        self.performMessageQueueSync {
            self.updateArchivePersistenceSummary(for: queryId) { summary in
                summary.received += 1
            }
        }
        if let date = getDelayedDate(message),
            let messageBare = getArchivedMessageContainer(message) {
            if AccountManager.shared.find(for: owner)?.groupchats.readInvite(in: messageBare, date: getDeliveryTime(messageBare, owner: owner) ?? date, isRead: nil) ?? GroupchatInviteV3Parser.isInvite(messageBare) {
                self.performMessageQueueSync {
                    self.updateArchivePersistenceSummary(for: queryId) { summary in
                        summary.skipped += 1
                    }
                }
                return
            }
            let shouldPersistArchiveQueryId = self.shouldPersistArchiveQueryId(queryId)
            let didQueue = enqueue(MessageQueueItem(messageBare,
                                                    messageId: getOriginId(messageBare),
                                                    archivedFrom: message.from?.bare,
                                                    isRead: true,
                                                    date: getDeliveryTime(messageBare, owner: owner) ?? date,
                                                    state: .deliver,
                                                    queryId: queryId,
                                                    shouldPersistArchiveQueryId: shouldPersistArchiveQueryId))
            if didQueue {
                self.performMessageQueueSync {
                    self.updateArchivePersistenceSummary(for: queryId) { summary in
                        summary.queued += 1
                    }
                }
            }
        } else {
            self.performMessageQueueSync {
                self.updateArchivePersistenceSummary(for: queryId) { summary in
                    summary.skipped += 1
                }
            }
        }
    }
    
    public func receiveCarbon(_ message: XMPPMessage) {
        if let messageBare = getCarbonCopyMessageContainer(message) {
            if AccountManager.shared.find(for: owner)?.groupchats.readInvite(in: messageBare, date: getDeliveryTime(messageBare, owner: owner) ?? Date(), isRead: nil) ?? GroupchatInviteV3Parser.isInvite(messageBare) {
                return
            }
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
            if AccountManager.shared.find(for: owner)?.groupchats.readInvite(in: messageBare, date: getDeliveryTime(messageBare, owner: owner) ?? Date(), isRead: nil) ?? GroupchatInviteV3Parser.isInvite(messageBare) {
                return
            }
            enqueue(MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: message.from?.bare,
                                     isRead: false,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message),
                                     countsAsRuntimeUnread: true))
        }
    }
    
    public func receiveRuntime(_ message: XMPPMessage) {
        if AccountManager.shared.find(for: owner)?.groupchats.readInvite(in: message, date: getDeliveryTime(message, owner: owner) ?? Date(), isRead: false) ?? GroupchatInviteV3Parser.isInvite(message) {
            return
        }
        enqueue(MessageQueueItem(message,
                                 messageId: getOriginId(message),
                                 archivedFrom: message.from?.bare,
                                 isRead: false,
                                 date: getDeliveryTime(message, owner: owner) ?? Date(),
                                 state: .sended,
                                 queryId: getMAMQueryId(message),
                                 countsAsRuntimeUnread: true))
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
        let startedAt = Date()
        let queryIds = Set(items.compactMap { $0.queryId?.isNotEmpty == true ? $0.queryId : nil })
            .sorted()
            .joined(separator: ",")
        ChatArchiveDebugTrace.log("messageProcessQueueStart", [
            ("owner", self.owner),
            ("queryId", queryIds),
            ("count", items.count)
        ])
        var messageQueryIds: Set<String> = Set<String>()
        var out: Set<MessageStorageItem> = Set<MessageStorageItem>()
        var readStateRequests: [ReadStateReconciliationRequest] = []
        var archiveQueryIdsByPrimary: [String: [String]] = [:]
        let sortedItems = Array(items).sorted(by: {
            $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970
        })
        
        sortedItems.forEach { (item) in
            if isVoIPMessage(item.message) {
                return
            }
            if AccountManager.shared.find(for: owner)?.groupchats.readInvite(in: item.message, date: item.date, isRead: item.forceUnreadState ?? item.isRead) ?? GroupchatInviteV3Parser.isInvite(item.message) {
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
            
            instance.queryIds = item.shouldPersistArchiveQueryId ? item.queryId : nil
            instance.shouldPersistArchiveQueryId = item.shouldPersistArchiveQueryId
            if let queryId = item.queryId,
               queryId.isNotEmpty {
                archiveQueryIdsByPrimary[instance.primary, default: []].append(queryId)
            }
            instance.countsAsRuntimeUnread = item.countsAsRuntimeUnread &&
                !item.originalOutgoing &&
                !instance.isRead &&
                item.forceUnreadState == nil &&
                !item.clientSyncMessage
            
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
            XMPPMessageScheduleManager.applyDeferredMetadata(to: instance, source: item.message)
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
        let batch = ProcessedQueueBatch(
            messages: Array(out).sorted(by: { $0.date < $1.date}),
            readStateRequests: readStateRequests,
            archiveQueryIdsByPrimary: archiveQueryIdsByPrimary
        )
        ChatArchiveDebugTrace.log("messageProcessQueueFinish", [
            ("owner", self.owner),
            ("queryId", queryIds),
            ("inputCount", items.count),
            ("outputCount", batch.messages.count),
            ("readStateRequests", batch.readStateRequests.count),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
        ])
        callback(batch)
    }
    
    @discardableResult
    internal func enqueue(_ item: MessageQueueItem) -> Bool {
        self.performMessageQueueSync {
            let inserted = self.queuedMessages.update(with: item) == nil
            if inserted {
                self.adjustQueuedMessageCounts(for: [item], delta: 1)
            }
            self.publishQueuedMessagesSnapshot()
            self.scheduleQueuedMessagesDrainIfNeeded()
            return inserted
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
    
    @discardableResult
    func storeMessagesNow(forQueryId queryId: String? = nil) -> Int {
        storeMessagesNowSummary(forQueryId: queryId).persistedRows
    }

    @discardableResult
    func storeMessagesNowSummary(forQueryId queryId: String? = nil) -> ArchivePersistenceSummary {
        let requestedAt = Date()
        ChatArchiveDebugTrace.log("messageStoreNowRequest", [
            ("owner", self.owner),
            ("queryId", queryId ?? "-")
        ])
        return self.performMessageQueueSync {
            let startedAt = Date()
            let waitMs = ChatArchiveDebugTrace.milliseconds(since: requestedAt)
            let results: Set<MessageQueueItem>
            if let queryId, queryId.isNotEmpty {
                results = Set(self.queuedMessages.filter { $0.queryId == queryId })
            } else {
                results = self.queuedMessages
            }
            let queuedBefore = self.queuedMessages.count
            let queryQueuedBefore = queryId.flatMap { self.queuedMessageCountsByQueryId[$0] } ?? 0
            let queryInFlightBefore = queryId.flatMap { self.inFlightMessageCountsByQueryId[$0] } ?? 0
            ChatArchiveDebugTrace.log("messageStoreNowStart", [
                ("owner", self.owner),
                ("queryId", queryId ?? "-"),
                ("waitMs", waitMs),
                ("queuedBefore", queuedBefore),
                ("queryQueuedBefore", queryQueuedBefore),
                ("queryInFlightBefore", queryInFlightBefore),
                ("drainCount", results.count)
            ])

            guard results.isNotEmpty else {
                if self.queuedMessages.isEmpty {
                    self.isQueuedMessagesDrainScheduled = false
                }
                if let queryId, queryId.isNotEmpty {
                    let summary = self.archivePersistenceSummarySnapshot(forQueryId: queryId)
                    ChatArchiveDebugTrace.log("messageStoreNowEmpty", [
                        ("owner", self.owner),
                        ("queryId", queryId),
                        ("waitMs", waitMs),
                        ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                        ("received", summary.received),
                        ("queued", summary.queued),
                        ("savedNew", summary.savedNew),
                        ("updatedExisting", summary.updatedExisting),
                        ("skipped", summary.skipped),
                        ("failed", summary.failed)
                    ])
                    return summary
                }
                ChatArchiveDebugTrace.log("messageStoreNowEmpty", [
                    ("owner", self.owner),
                    ("queryId", queryId ?? "-"),
                    ("waitMs", waitMs),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
                ])
                return ArchivePersistenceSummary()
            }

            self.adjustQueuedMessageCounts(for: results, delta: -1)
            self.queuedMessages.subtract(results)
            self.publishQueuedMessagesSnapshot()
            self.adjustInFlightMessageCounts(for: results, delta: 1)

            self.processQueue(results, callback: { values in
                if let batch = values {
                    _ = self.save(batch)
                }
            })

            self.adjustInFlightMessageCounts(for: results, delta: -1)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()

            if self.queuedMessages.isEmpty {
                self.isQueuedMessagesDrainScheduled = false
            } else if self.isReceiverActive, !self.isQueuedMessagesDrainScheduled {
                self.scheduleQueuedMessagesDrainOnQueue()
            }

            let summary: ArchivePersistenceSummary
            if let queryId, queryId.isNotEmpty {
                summary = self.archivePersistenceSummarySnapshot(forQueryId: queryId)
            } else {
                summary = ArchivePersistenceSummary()
            }
            ChatArchiveDebugTrace.log("messageStoreNowFinish", [
                ("owner", self.owner),
                ("queryId", queryId ?? "-"),
                ("waitMs", waitMs),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                ("queuedAfter", self.queuedMessages.count),
                ("queryQueuedAfter", queryId.flatMap { self.queuedMessageCountsByQueryId[$0] } ?? 0),
                ("queryInFlightAfter", queryId.flatMap { self.inFlightMessageCountsByQueryId[$0] } ?? 0),
                ("received", summary.received),
                ("queued", summary.queued),
                ("savedNew", summary.savedNew),
                ("updatedExisting", summary.updatedExisting),
                ("skipped", summary.skipped),
                ("failed", summary.failed)
            ])
            return summary
        }
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

    private func archiveSummary(from outcomes: [ArchivePersistenceOutcomeItem]) -> ArchivePersistenceSummary {
        var summary = ArchivePersistenceSummary()
        outcomes.forEach { item in
            switch item.outcome {
            case .savedNew:
                summary.savedNew += 1
            case .updatedExisting:
                summary.updatedExisting += 1
            case .skipped:
                summary.skipped += 1
            case .failed:
                summary.failed += 1
            }

            if item.outcome != .skipped,
               item.outcome != .failed,
               !item.isDeleted {
                summary.recordVisibleRow(
                    owner: item.owner,
                    jid: item.opponent,
                    conversationType: item.conversationType
                )
            }
        }
        return summary
    }

    private func archiveQueryIds(for message: MessageStorageItem, runtimeQueryIds: [String]?) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        (runtimeQueryIds ?? []).forEach {
            let queryId = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard queryId.isNotEmpty,
                  !seen.contains(queryId) else {
                return
            }
            seen.insert(queryId)
            ids.append(queryId)
        }
        self.queryIds(from: message).forEach {
            guard !seen.contains($0) else {
                return
            }
            seen.insert($0)
            ids.append($0)
        }
        return ids
    }

    private func persistMessage(
        _ message: MessageStorageItem,
        in realm: Realm,
        silentNotifications: Bool,
        runtimeQueryIds: [String]?
    ) -> (ArchivePersistenceOutcomeItem, MessageStorageItem.SaveSideEffects?) {
        message.updatePrimary()
        let existedBefore = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: message.primary) != nil
        let queryIds = self.archiveQueryIds(for: message, runtimeQueryIds: runtimeQueryIds)
        let sideEffects = message.applyMessagePersistence(in: realm, silentNotifications: silentNotifications)

        if sideEffects?.shouldStoreStanza == true {
            message.storeStanza(in: realm)
        }

        let outcome: ArchivePersistenceOutcome
        if sideEffects?.shouldStoreStanza == true {
            outcome = existedBefore ? .updatedExisting : .savedNew
        } else {
            outcome = existedBefore ? .updatedExisting : .skipped
        }

        return (
            ArchivePersistenceOutcomeItem(
                queryIds: queryIds,
                owner: message.owner,
                opponent: message.opponent,
                conversationType: message.conversationType,
                isDeleted: message.isDeleted,
                outcome: outcome
            ),
            sideEffects
        )
    }

    private func failedOutcome(for message: MessageStorageItem, runtimeQueryIds: [String]?) -> ArchivePersistenceOutcomeItem {
        ArchivePersistenceOutcomeItem(
            queryIds: self.archiveQueryIds(for: message, runtimeQueryIds: runtimeQueryIds),
            owner: message.owner,
            opponent: message.opponent,
            conversationType: message.conversationType,
            isDeleted: message.isDeleted,
            outcome: .failed
        )
    }

    private func saveIndividuallyAfterBatchFailure(
        _ batch: ProcessedQueueBatch,
        silentNotifications: Bool
    ) -> ArchivePersistenceSummary {
        let startedAt = Date()
        let batchQueryIds = Set(batch.archiveQueryIdsByPrimary.values.flatMap { $0 })
            .sorted()
            .joined(separator: ",")
        ChatArchiveDebugTrace.log("messageSaveFallbackStart", [
            ("owner", self.owner),
            ("queryId", batchQueryIds),
            ("count", batch.messages.count)
        ])
        var outcomes: [ArchivePersistenceOutcomeItem] = []
        var persistedMessages: [MessageStorageItem] = []
        var referencePrepareMs = 0
        var referenceCount = 0

        batch.messages.forEach { message in
            do {
                let messageStartedAt = Date()
                let realm = try WRealm.safe()
                var sideEffects: MessageStorageItem.SaveSideEffects?
                var outcome: ArchivePersistenceOutcomeItem?
                try realm.write {
                    let result = self.persistMessage(
                        message,
                        in: realm,
                        silentNotifications: silentNotifications,
                        runtimeQueryIds: batch.archiveQueryIdsByPrimary[message.primary]
                    )
                    outcome = result.0
                    sideEffects = result.1
                }
                if let outcome {
                    outcomes.append(outcome)
                    if outcome.outcome != .failed {
                        persistedMessages.append(message)
                    }
                }
                if let notification = sideEffects?.notification {
                    NotifyManager.shared.update(
                        withMessage: notification.message,
                        messageId: notification.messageId,
                        username: notification.username,
                        opponent: notification.opponent,
                        owner: notification.owner,
                        date: notification.date,
                        displayName: notification.displayName,
                        imageUrl: notification.imageUrl,
                        conversationType: notification.conversationType
                    )
                }
                message.references.forEach { reference in
                    let referenceStartedAt = Date()
                    ChatPerformanceSignposts.measure(.referencePrepare) {
                        reference.prepare()
                    }
                    let durationMs = ChatArchiveDebugTrace.milliseconds(since: referenceStartedAt)
                    referencePrepareMs += durationMs
                    referenceCount += 1
                    if durationMs > 100 {
                        ChatArchiveDebugTrace.log("messageReferencePrepareSlow", [
                            ("owner", self.owner),
                            ("queryId", batch.archiveQueryIdsByPrimary[message.primary]?.joined(separator: ",") ?? message.queryIds ?? "-"),
                            ("referencePrimary", reference.primary),
                            ("kind", reference.kind.rawValue),
                            ("mimeType", reference.mimeType),
                            ("isDownloaded", reference.isDownloaded),
                            ("hasPreview", reference.videoPreviewKey != nil),
                            ("durationMs", durationMs)
                        ])
                    }
                }
                ChatArchiveDebugTrace.log("messageSaveFallbackItem", [
                    ("owner", self.owner),
                    ("queryId", batch.archiveQueryIdsByPrimary[message.primary]?.joined(separator: ",") ?? message.queryIds ?? "-"),
                    ("archivedId", message.archivedId),
                    ("opponent", message.opponent),
                    ("conversationType", message.conversationType.rawValue),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: messageStartedAt))
                ])
            } catch {
                let queryIds = batch.archiveQueryIdsByPrimary[message.primary]
                outcomes.append(self.failedOutcome(for: message, runtimeQueryIds: queryIds))
                DDLogDebug(
                    "MessageManager.save fallback failed queryIds=\(queryIds?.joined(separator: ",") ?? message.queryIds ?? "-") archivedId=\(message.archivedId) messageId=\(message.messageId) opponent=\(message.opponent) conversationType=\(message.conversationType.rawValue) error=\(error.localizedDescription)"
                )
            }
        }

        AccountManager.shared.find(for: self.owner)?.messageSchedule.reconcileDeliveredScheduleMarkers(from: persistedMessages)
        self.recordArchivePersistenceOutcomes(outcomes)
        let summary = self.archiveSummary(from: outcomes)
        ChatArchiveDebugTrace.log("messageSaveFallbackFinish", [
            ("owner", self.owner),
            ("queryId", batchQueryIds),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
            ("referencePrepareMs", referencePrepareMs),
            ("referenceCount", referenceCount),
            ("savedNew", summary.savedNew),
            ("updatedExisting", summary.updatedExisting),
            ("skipped", summary.skipped),
            ("failed", summary.failed)
        ])
        return summary
    }

    @discardableResult
    func save(_ batch: ProcessedQueueBatch, silentNotifications: Bool = false) -> ArchivePersistenceSummary {
        self.messagePersistenceChunkSizes.removeAll(keepingCapacity: true)
        guard !batch.messages.isEmpty else {
            return ArchivePersistenceSummary()
        }

        let chunks = batch.chunks(maxSize: self.messagePersistenceChunkSize)
        var summary = ArchivePersistenceSummary()
        chunks.enumerated().forEach { index, chunk in
            self.messagePersistenceChunkSizes.append(chunk.messages.count)
            self.messagePersistenceChunkObserver?(chunk.messages.count, index)
            summary.merge(self.saveSingleBatch(chunk, silentNotifications: silentNotifications))
        }
        return summary
    }

    private func saveSingleBatch(
        _ batch: ProcessedQueueBatch,
        silentNotifications: Bool
    ) -> ArchivePersistenceSummary {
        return ChatPerformanceSignposts.measure(.messagePersistence) {
        let startedAt = Date()
        let batchQueryIds = Set(batch.archiveQueryIdsByPrimary.values.flatMap { $0 })
            .sorted()
            .joined(separator: ",")
        ChatArchiveDebugTrace.log("messageSaveStart", [
            ("owner", self.owner),
            ("queryId", batchQueryIds),
            ("count", batch.messages.count),
            ("readStateRequests", batch.readStateRequests.count)
        ])
        do {
            let realm = try  WRealm.safe()
            var clearedStanzaIDs: Set<String> = []
            var notificationPayloads: [MessageStorageItem.SaveNotificationPayload] = []
            var messagePrimariesToMarkRead: Set<String> = []
            var outcomes: [ArchivePersistenceOutcomeItem] = []
            let affectedChats = Set(batch.messages.compactMap { message -> String? in
                guard message.conversationType == .group else {
                    return nil
                }
                return message.opponent
            })

            try self.archiveBatchSaveFailureInjector?()
            let realmWriteStartedAt = Date()
            try realm.write {
                clearedStanzaIDs = self.reconcileReadStates(batch.readStateRequests, in: realm)
                batch.messages.forEach {
                    let result = self.persistMessage(
                        $0,
                        in: realm,
                        silentNotifications: silentNotifications,
                        runtimeQueryIds: batch.archiveQueryIdsByPrimary[$0.primary]
                    )
                    outcomes.append(result.0)
                    if let notification = result.1?.notification {
                        notificationPayloads.append(notification)
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
            let realmWriteMs = ChatArchiveDebugTrace.milliseconds(since: realmWriteStartedAt)

            let sideEffectsStartedAt = Date()
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
            let sideEffectsMs = ChatArchiveDebugTrace.milliseconds(since: sideEffectsStartedAt)

            let referencePrepareStartedAt = Date()
            var referenceCount = 0
            batch.messages.forEach {
                message in
                message.references.forEach {
                    reference in
                    let referenceStartedAt = Date()
                    ChatPerformanceSignposts.measure(.referencePrepare) {
                        reference.prepare()
                    }
                    let durationMs = ChatArchiveDebugTrace.milliseconds(since: referenceStartedAt)
                    referenceCount += 1
                    if durationMs > 100 {
                        ChatArchiveDebugTrace.log("messageReferencePrepareSlow", [
                            ("owner", self.owner),
                            ("queryId", batch.archiveQueryIdsByPrimary[message.primary]?.joined(separator: ",") ?? message.queryIds ?? "-"),
                            ("referencePrimary", reference.primary),
                            ("kind", reference.kind.rawValue),
                            ("mimeType", reference.mimeType),
                            ("isDownloaded", reference.isDownloaded),
                            ("hasPreview", reference.videoPreviewKey != nil),
                            ("durationMs", durationMs)
                        ])
                    }
                }
            }
            let referencePrepareMs = ChatArchiveDebugTrace.milliseconds(since: referencePrepareStartedAt)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()
            AccountManager.shared.find(for: self.owner)?.messageSchedule.reconcileDeliveredScheduleMarkers(from: batch.messages)
            self.recordArchivePersistenceOutcomes(outcomes)
            let summary = self.archiveSummary(from: outcomes)
            ChatArchiveDebugTrace.log("messageSaveFinish", [
                ("owner", self.owner),
                ("queryId", batchQueryIds),
                ("count", batch.messages.count),
                ("realmWriteMs", realmWriteMs),
                ("sideEffectsMs", sideEffectsMs),
                ("referencePrepareMs", referencePrepareMs),
                ("referenceCount", referenceCount),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                ("savedNew", summary.savedNew),
                ("updatedExisting", summary.updatedExisting),
                ("skipped", summary.skipped),
                ("failed", summary.failed)
            ])
            return summary
        } catch {
            DDLogDebug("MessageManager.save batch failed count=\(batch.messages.count) error=\(error.localizedDescription)")
            return self.saveIndividuallyAfterBatchFailure(batch, silentNotifications: silentNotifications)
        }
        }
    }

    func save(_ messages: [MessageStorageItem], silentNotifications: Bool = false) {
        save(ProcessedQueueBatch(messages: messages, readStateRequests: []), silentNotifications: silentNotifications)
    }
}
