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
import CocoaLumberjack

struct XabberDeliveryReceipt: Equatable {
    let originId: String
    let stanzaId: String
    let stamp: Date?
}

enum ReliableMessageDeliveryReceiptProcessor {
    @discardableResult
    static func apply(
        owner: String,
        receipt: XabberDeliveryReceipt,
        onLiveMessagePersisted: ((ArchiveConversationKey, String) -> Void)? = nil,
        onApplied: (String, String) -> Void
    ) -> Bool {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let messages = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@", owner, receipt.originId)
            guard !messages.isEmpty else {
                return false
            }
            let messageSnapshot = Array(messages)
            let liveAdmissionRows: [(ArchiveConversationKey, String)]
            if let receiptCursor = ArchiveCursor(rawValue: receipt.stanzaId) {
                liveAdmissionRows = messageSnapshot.compactMap { message in
                    guard !message.isDeleted,
                          !message.isLocallyHiddenByReport,
                          ArchiveCursor(rawValue: message.archivedId)?
                            .numericValue != receiptCursor.numericValue else {
                        return nil
                    }
                    return (
                        ArchiveConversationKey(
                            owner: message.owner,
                            jid: message.opponent,
                            conversationType: message.conversationType
                        ),
                        message.primary
                    )
                }
            } else {
                liveAdmissionRows = []
            }
            let timeoutErrorChatKeys = messageSnapshot
                .filter { $0.messageErrorCode == AccountSendCoordinator.deliveryReceiptTimeoutErrorCode }
                .map { message in
                    (
                        jid: message.opponent,
                        owner: message.owner,
                        conversationType: message.conversationType
                    )
                }
            try realm.write {
                messageSnapshot.forEach { instance in
                    let isTimeoutError = instance.messageErrorCode == AccountSendCoordinator.deliveryReceiptTimeoutErrorCode
                    if instance.state == .sending || isTimeoutError {
                        instance.state = .sended
                    }
                    if isTimeoutError {
                        instance.messageError = nil
                        instance.messageErrorCode = nil
                        instance.references.forEach {
                            $0.hasError = false
                        }
                    }
                    if let stamp = receipt.stamp {
                        instance.date = stamp
                        instance.sentDate = stamp
                    }
                    instance.archivedId = receipt.stanzaId
                }
            }
            timeoutErrorChatKeys.forEach { chatKey in
                LastChats.updateErrorState(
                    for: chatKey.jid,
                    owner: chatKey.owner,
                    conversationType: chatKey.conversationType
                )
            }
            liveAdmissionRows.forEach { conversation, primaryID in
                onLiveMessagePersisted?(conversation, primaryID)
            }
            onApplied(receipt.originId, receipt.stanzaId)
            return true
        } catch {
            DDLogDebug("ReliableMessageDeliveryReceiptProcessor: apply failed: \(error.localizedDescription)")
            return false
        }
    }
}

class ReliableMessageDeliveryManager: AbstractXMPPManager {
    private static let receiptRetryQueue = DispatchQueue(label: "com.xabber.reliable-delivery.receipt-retry", qos: .utility)
    
    open var isAvailable: Bool = false
    
    internal var bag: DisposeBag = DisposeBag()
    internal var echoQueue: BehaviorRelay<Set<XMPPMessage>> = BehaviorRelay(value: Set<XMPPMessage>())
    
    open func checkAvailability() {
        guard let node = SettingManager
            .shared
            .getKey(for: owner, scope: .reliableMessageDelivery, key: "node"),
            node == getPrimaryNamespace() else {
            isAvailable = false
            return
        }
        isAvailable = true
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        checkAvailability()
        subscribe()
    }
    
    override func namespaces() -> [String] {
        return ["https://xabber.com/protocol/delivery"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    public func xmlns(_ category: String?) -> String {
        guard let category = category,
              category.isNotEmpty else {
            return getPrimaryNamespace()
        }
        return [getPrimaryNamespace(), "#", category].joined()
    }
    
    open func apply(to message: XMPPMessage, retry: Bool = false, missRetryElement: Bool = false) -> XMPPMessage {
        if retry && !missRetryElement {
            message.addChild(DDXMLElement(name: "retry", xmlns: getPrimaryNamespace()))
        }
        return message
    }
    
    
    open func read(headline message: XMPPMessage) -> Bool {
        switch true {
        case readNotification(message): return true
        case readEcho(message): return true
        case readRealtimeNotification(message): return true
        default: return false
        }
    }
    
    open func read(error message: XMPPMessage) -> Bool {
        return readNotificationError(message)
    }
    
    internal func getErrorDescription(_ error: DDXMLElement) -> String? {
        if error.element(forName: "remote-server-not-found") != nil { return "Remote server not found".localizeString(id: "error_server_not_found", arguments: []) }
        if error.element(forName: "policy-violation") != nil { return "Internal server error".localizeString(id: "error_internal_server", arguments: []) }
        if error.element(forName: "not-allowed") != nil { return "You are not allowed to send messages to this chat".localizeString(id: "error_not_allowed", arguments: []) }
        return nil
    }
    
    internal func getErrorCode(_ error: DDXMLElement) -> String? {
        if error.element(forName: "remote-server-not-found") != nil { return "404" }
        if error.element(forName: "policy-violation") != nil { return "403" }
        if error.element(forName: "not-allowed") != nil { return "405" }
        return nil
    }
    
    internal func readNotificationError(_ message: XMPPMessage) -> Bool {
        guard let elementId = message.elementID,
            let error = message.element(forName: "error"),
            let errorMessage = getErrorDescription(error) else { return false }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@ AND outgoing == %@", owner, elementId, true)
                .first {
                try realm.write {
                    instance.state = .error
                    instance.messageError = errorMessage
                    instance.messageErrorCode = getErrorCode(error)
                    instance.references.forEach({
                        $0.hasError = true
                    })
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: instance.opponent, owner: instance.owner, conversationType: instance.conversationType))?.hasErrorInChat = true
                }
                AccountManager.shared.find(for: self.owner)?.sendCoordinator.terminalFailure(
                    originId: elementId,
                    error: errorMessage
                )
                return true
            }
        } catch {
            DDLogDebug("\(#function). Cant load message for messageId: \(elementId). \(error.localizedDescription)")
        }
        return false
    }
    
    //TODO bring to rrr
    internal func readRealtimeNotification(_ message: XMPPMessage) -> Bool {
        guard let retractElement = message.element(forName: "retract-message",
                                                   xmlns: xmlns("notify")),
              let conversation = retractElement.attributeStringValue(forName: "conversation"),
              let id = retractElement.attributeStringValue(forName: "id") else {
            return false
        }
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                realm.delete(
                    realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND archivedId == %@",
                                self.owner,
                                conversation,
                                id)
                )
            }
        } catch {
            DDLogDebug("ReliableMessageDeliveryManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    internal func readNotification(_ message: XMPPMessage) -> Bool {
        guard let received = message.element(forName: "received", xmlns: getPrimaryNamespace()),
            let elementId = received.element(forName: "origin-id")?.attributeStringValue(forName: "id"),
            let stanzaId = received.element(forName: "stanza-id")?.attributeStringValue(forName: "id") else {
                return false
        }
        let receipt = XabberDeliveryReceipt(
            originId: elementId,
            stanzaId: stanzaId,
            stamp: received.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate
        )
        if !applyDeliveryReceipt(receipt) {
            scheduleDeliveryReceiptRetry(receipt, attemptsRemaining: 2)
        }
        return true
    }

    @discardableResult
    internal func applyDeliveryReceipt(_ receipt: XabberDeliveryReceipt) -> Bool {
        ReliableMessageDeliveryReceiptProcessor.apply(
            owner: self.owner,
            receipt: receipt,
            onLiveMessagePersisted: { [weak self] conversation, primaryID in
                guard let self,
                      let account = AccountManager.shared.find(for: self.owner)
                else {
                    return
                }
                Task { [archiveEngine = account.archiveEngine] in
                    await archiveEngine.liveMessageDidPersist(
                        conversation: conversation,
                        primaryID: primaryID
                    )
                }
            },
            onApplied: { [weak self] originId, stanzaId in
                guard let self else { return }
                if let account = AccountManager.shared.find(for: self.owner) {
                    account.connectionResilience.noteDeliveryReceipt(originId: originId, stanzaId: stanzaId)
                    account.sendCoordinator.deliveryReceiptReceived(originId: originId, stanzaId: stanzaId)
                    account.logConnectionDiagnostics(
                        event: "delivery_receipt_applied",
                        details: ["originId": originId, "stanzaId": stanzaId]
                    )
                }
            }
        )
    }

    private func scheduleDeliveryReceiptRetry(_ receipt: XabberDeliveryReceipt, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else { return }
        Self.receiptRetryQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if !self.applyDeliveryReceipt(receipt) {
                self.scheduleDeliveryReceiptRetry(receipt, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }
    
    internal func readEcho(_ message: XMPPMessage) -> Bool {
        guard let messageElement = echoMessageContainer(from: message),
              messageElement.element(forName: "x", xmlns: "https://xabber.com/protocol/groups") != nil else {
            return false
        }
        var value = echoQueue.value
        value.insert(message)
        echoQueue.accept(value)
        return true
    }
    
    internal func parseEcho(_ message: XMPPMessage) {
        guard let from = message.from?.bare,
              let echoedMessage = echoMessageContainer(from: message),
              let elementId = echoedMessage.element(forName: "origin-id")?.attributeStringValue(forName: "id"),
              let stamp = echoedMessage
                .element(forName: "time", xmlns: "https://xabber.com/protocol/delivery")?
                .attributeStringValue(forName: "stamp")?.xmppDate
                    ?? echoedMessage.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate else {
            return
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@ AND outgoing == %@", owner, elementId, true)
                .first {
                    try realm.write {
                        instance.state = .deliver
                        instance.date = stamp
                        instance.sentDate = stamp
                        let parsedReferences = parseReferences(
                            echoedMessage,
                            primary: instance.primary,
                            jid: from,
                            owner: owner,
                            echo: true
                        )
                        let pendingMediaAttachments = parsedReferences.compactMap {
                            $0.pendingMediaAttachment
                        }
                        reconcileEchoReferences(
                            instance: instance,
                            parsedReferences: parsedReferences,
                            echoedBody: echoedMessage.body ?? ""
                        )
                        MessageStorageItem.persistPendingMediaAttachments(
                            pendingMediaAttachments,
                            forMessagePrimary: instance.primary,
                            in: realm
                        )
                        if let stanzaId = echoStanzaId(for: echoedMessage, conversationJid: from),
                           stanzaId.isNotEmpty {
                            instance.archivedId = stanzaId
                        }
                        realm
                            .object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: instance.primary)?
                            .stanza = echoedMessage.compactXMLString()
                    }
                }
        } catch {
            DDLogDebug("\(#function). Cant load message for messageId: \(elementId). \(error.localizedDescription)")
        }
        return
    }

    private func reconcileEchoReferences(
        instance: MessageStorageItem,
        parsedReferences: [MessageReferenceStorageItem],
        echoedBody: String
    ) {
        let existingReferences = Array(instance.references)
        let shouldPreserveLocalTextReferences =
            echoedBody != instance.body &&
            existingReferences.contains(where: {
                [.mention, .quote, .markup].contains($0.kind)
            })

        instance.references.removeAll()

        guard shouldPreserveLocalTextReferences else {
            instance.references.append(objectsIn: parsedReferences)
            return
        }

        instance.references.append(objectsIn: existingReferences)

        let hasExistingGroupchatRef = existingReferences.contains(where: { $0.kind == .groupchat })
        let supplementalReferences = parsedReferences.filter { reference in
            switch reference.kind {
            case .mention, .quote, .markup:
                return false
            case .groupchat:
                return !hasExistingGroupchatRef
            default:
                return true
            }
        }

        instance.references.append(objectsIn: supplementalReferences)
    }

    private func echoMessageContainer(from message: XMPPMessage) -> XMPPMessage? {
        if let container = message
            .element(forName: "x", xmlns: getPrimaryNamespace())?
            .element(forName: "message") {
            return XMPPMessage(from: container)
        }
        return getGroupchatHeadlineForwardedMessageContainer(message)
    }

    private func echoStanzaId(for echoedMessage: XMPPMessage, conversationJid: String) -> String? {
        let ids = echoedMessage.elements(forName: "stanza-id") + echoedMessage.elements(forName: "archived")
        if let matchingId = ids.first(where: {
            $0.attributeStringValue(forName: "by", withDefaultValue: "") == conversationJid
        })?.attributeStringValue(forName: "id"), matchingId.isNotEmpty {
            return matchingId
        }

        let fallback = getStanzaId(echoedMessage, owner: conversationJid)
        return fallback.isNotEmpty ? fallback : nil
    }
    
    
    internal func subscribe() {
        bag = DisposeBag()
        
        echoQueue
            .asObservable()
            .debounce(.seconds(1), scheduler: SerialDispatchQueueScheduler(qos: .default))
            .subscribe(onNext: { (results) in
                results.forEach {
                    self.parseEcho($0)
                }
                self.echoQueue.accept(Set<XMPPMessage>())
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
   static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager
            .shared
            .saveItem(for: owner,
                      scope: .reliableMessageDelivery,
                      key: "node",
                      value: "")
    }
    
    deinit {
        unsubscribe()
    }
}
