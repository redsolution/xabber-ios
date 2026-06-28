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
import RxRealm
import RxSwift


extension MessageManager {
    
    struct ForwardedMessageItem {
        let referenceElement: DDXMLElement
        let body: String
        let count: Int
        let date: Date
    }

    private struct ForwardingSourceMessage {
        let message: XMPPMessage
        let timestamp: Date
    }

    internal static func outboundDestinationJID(
        for opponent: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        resource: String?
    ) -> XMPPJID? {
        XMPPJID(
            string: opponent,
            resource: conversationType == .group ? nil : resource
        )
    }
    
    internal func subscribeSender() {
        senderBag = DisposeBag()
        stanzaQueue
            .asObservable()
            .window(timeSpan: .milliseconds(50),
                    count: 50,
                    scheduler: SerialDispatchQueueScheduler(queue: self.queue,
                                                              internalSerialQueueName: "messageSendingQueue"))
            .subscribe(onNext: { (collection) in
                if self.stanzaQueue.value.isEmpty { return }
//                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                    if stream.isAuthenticated {
//                        let value = self.stanzaQueue.value
//                        value.forEach {
//                            stream.send($0)
//                        }
//                        self.stanzaQueue.accept(Array<XMPPMessage>())
//                    }
//                } fail: {
//                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
//                        if stream.isAuthenticated {
//                            let value = self.stanzaQueue.value
//                            value.forEach {
//                                stream.send($0)
//                            }
//                            self.stanzaQueue.accept(Array<XMPPMessage>())
//                        }
//                    })
//                }
                
            }, onError: { (_) in
                
            }, onCompleted: {
                
            }) {
                
            }
            .disposed(by: senderBag)
    }
    
    internal func unsubscribeSender() {
        senderBag = DisposeBag()
    }
    
    internal func retrySending(item primary: String) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                if instance.displayAs == .text {
                    self.processSender(item: primary, retry: true)
                } else {
                    self.uploadMedia(for: primary, retry: true)
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func processSender(item primary: String, retry: Bool = false, childs: [DDXMLElement] = []) {
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) else {
                return
            }
            let conversationType = item.conversationType
            let resource = realm
                .object(ofType: RosterStorageItem.self,
                        forPrimaryKey: RosterStorageItem
                            .genPrimary(jid: item.opponent,
                                        owner: item.owner))?
                .getPrimaryResource()?
                .resource
            let destinationJID = MessageManager.outboundDestinationJID(
                for: item.opponent,
                conversationType: conversationType,
                resource: resource
            )
            let stanza = XMPPMessage(messageType: .chat,
                                     to: destinationJID,
                                     elementID: item.messageId,
                                     child: nil)
            
            let stanzaToSave = XMPPMessage(messageType: .chat,
                                           to: destinationJID,
                                           elementID: item.messageId,
                                           child: nil)
            
            childs.forEach {
                stanza.addChild($0.copy() as! DDXMLElement)
                stanzaToSave.addChild($0.copy() as! DDXMLElement)
            }
            
            func failEncryptedSend(_ error: Error? = nil) {
                try? realm.write {
                    item.state = .error
                    item.messageError = "Can`t find any OMEMO device".localizeString(id: "message_manager_error_no_omemo", arguments: [])
                    item.messageErrorCode = "omemo"
                }
                if let error = error {
                    DDLogDebug("MessageManager; \(#function). OMEMO encryption failed: \(error.localizedDescription)")
                } else {
                    DDLogDebug("MessageManager; \(#function). OMEMO encryption failed")
                }
                LastChats.updateErrorState(for: item.opponent, owner: self.owner, conversationType: item.conversationType)
            }

            let encryptedSendAvailability = OmemoSendAvailabilityPolicy.evaluate(
                owner: item.owner,
                jid: item.opponent,
                conversationType: conversationType,
                realm: realm
            )
            if conversationType.isEncrypted && !encryptedSendAvailability.canSend {
                failEncryptedSend(OmemoManagerError.noTrustedRecipientDevices)
                return
            }
            
            switch conversationType {
                case .omemo, .omemo1, .axolotl:
                    
                    formForwardedMessages(item
                        .inlineForwards
                        .sorted(byKeyPath: "originalDate", ascending: true)
                        .toArray()
                        .compactMap { return $0.messageId })
                        .forEach { stanzaToSave.addChild($0.referenceElement) }
                    
                    if let mentions = item.createMentionsElement() {
                        stanzaToSave.addChild(mentions)
                    }

                    let references = item.createReferences()
                    references.forEach {
                        stanzaToSave.addChild($0)
                    }
                    
                    let forwardedMessages = formForwardedMessages(item
                        .inlineForwards
                        .sorted(byKeyPath: "originalDate", ascending: true)
                        .toArray()
                        .compactMap { return $0.messageId })
                        .compactMap { $0.referenceElement }
                    let mentions = item.createMentionsElement().map { [$0] } ?? []
                    
                    guard let payload = AccountManager.shared.find(for: self.owner)?.omemo.prepareStanzaContent(
                        message: item.legacyBody,
                        date: item.sentDate,
                        jid: item.opponent,
                        additionalContent: [forwardedMessages, mentions, references].flatMap({ $0 }),
                        ignoreTimeSignature: item.displayAs == .system
                    ) else {
                        failEncryptedSend()
                        return
                    }
                    do {
                        let encrypted = try AccountManager.shared.find(for: self.owner)?.omemo.encryptMessage(message: payload, to: item.opponent)
                        guard let encrypted = encrypted else {
                            throw OmemoManagerError.encryptionFailed
                        }
                        stanza.addChild(encrypted)
                    } catch {
                        failEncryptedSend(error)
                        return
                    }
                    let encryptionElement = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
                    encryptionElement.addAttribute(withName: "namespace", stringValue: conversationType.rawValue)
                    stanza.addChild(encryptionElement)
                    stanza.addBody("Message was encrypted by OMEMO".localizeString(id: "message_omemo_encryption", arguments: []))
                    stanzaToSave.addBody(item.legacyBody)
                default:
                    formForwardedMessages(item
                        .inlineForwards
                        .sorted(byKeyPath: "originalDate", ascending: true)
                        .toArray()
                        .compactMap { return $0.messageId })
                        .forEach {
                            stanza.addChild($0.referenceElement.copy() as! DDXMLElement)
                            stanzaToSave.addChild($0.referenceElement.copy() as! DDXMLElement)
                        }
                    
                    stanza.addBody(item.legacyBody)
                    stanzaToSave.addBody(item.legacyBody)
                    if let mentions = item.createMentionsElement() {
                        stanza.addChild(mentions.copy() as! DDXMLElement)
                        stanzaToSave.addChild(mentions.copy() as! DDXMLElement)
                    }
                    item.createReferences().forEach {
                        stanza.addChild($0.copy() as! DDXMLElement)
                        stanzaToSave.addChild($0.copy() as! DDXMLElement)
                    }
            }
            
            stanza.addOriginId(item.messageId)
            stanzaToSave.addOriginId(item.messageId)
            
            stanza.addAttribute(withName: "from", stringValue: owner)
            stanzaToSave.addAttribute(withName: "from", stringValue: owner)
            let missRetryElementOnResend = item.messageErrorCode == "405"
            let isDeliveryReceiptTimeoutRetry = retry && item.messageErrorCode == AccountSendCoordinator.deliveryReceiptTimeoutErrorCode
            let shouldUseDurableRegularQueue = item.conversationType == .regular && item.displayAs == .text
            let durableQueueRequest = AccountQueuedMessageSendRequest(
                owner: item.owner,
                conversationJid: item.opponent,
                conversationType: item.conversationType,
                messagePrimary: item.primary,
                originId: item.messageId,
                stanzaXML: stanzaToSave.xmlString,
                createdAt: item.date,
                replayRequired: retry
            )
            try realm.write {
                if item.displayAs != .system {
                    if item.conversationType.isEncrypted {
                        if let conversation = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.opponent, owner: item.owner, conversationType: item.conversationType)) {
                            if conversation.isAfterburnEnabled {
                                let ephemeralElement = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
                                ephemeralElement.addAttribute(withName: "timer", doubleValue: conversation.afterburnInterval)
                                stanza.addChild(ephemeralElement)
                                item.applyAutoDeleteTTL(
                                    conversation.afterburnInterval,
                                    startsAt: item.sentDate,
                                    policyVersion: conversation.autoDeletePolicyVersion
                                )
                            }
                        }
                    }
                }
                
                if encryptedSendAvailability.requiresUntrustedContactDeviceWarning {
                    item.markOmemoUntrustedContactDevicesWarning()
                } else {
                    item.clearOmemoUntrustedContactDevicesWarning()
                }

                item.state = .sending
                if isDeliveryReceiptTimeoutRetry {
                    item.messageError = nil
                    item.messageErrorCode = nil
                    item.references.forEach {
                        $0.hasError = false
                    }
                }
                
                item.trustedSource = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: item.opponent,
                        owner: item.owner,
                        conversationType: item.conversationType
                    )
                )?.isSynced ?? false
                
                if item.conversationType.isEncrypted && item.displayAs != .system {
                    if SignatureManager.shared.isSignatureSetted {
                        item.errorMetadata = (try? SignatureManager.shared.checkSignature(
                            owner: self.owner,
                            for: self.owner,
                            signature: SignatureManager.shared.signatureElement,
                            messageDate: item.sentDate
                        ).errorMetadata) ?? SignatureManager.MessageError().errorMetadata
                        item.messageError = "cert_error"
                    }
                }
                
                if retry {
                    realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: item.primary)?
                        .stanza = stanzaToSave.compactXMLString()
                    if let instance = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: item.opponent,
                            owner: item.owner,
                            conversationType: item.conversationType
                        )
                    ) {
                        instance.lastMessage = item
                        instance.messageDate = Date()
                    }
                } else {
                    item.originalStanza = stanzaToSave
                    item.storeStanza()
                }
            }
            if shouldUseDurableRegularQueue {
                if let sendCoordinator = AccountManager.shared.find(for: owner)?.sendCoordinator {
                    try sendCoordinator.enqueueRegularMessage(durableQueueRequest)
                } else {
                    try AccountSendCoordinator.persistRegularMessage(durableQueueRequest)
                    ConnectionDiagnosticsLogger.log(
                        event: "application_message_durable_queue_no_account",
                        stream: .primary,
                        jid: owner,
                        details: [
                            "messageId": item.messageId,
                            "conversationType": item.conversationType.rawValue
                        ]
                    )
                }
                LastChats.updateErrorState(for: item.opponent, owner: self.owner, conversationType: item.conversationType)
                return
            }
            let deferredMessageId = item.messageId
            let deferredConversationType = item.conversationType.rawValue
            AccountManager.shared.find(for: owner)?.unsafeAction({ (user, stream) in
                stanza.addChild(user.chatMarkers.child)
                let stanzaToSend = user.deliveryManager.apply(to: stanza, retry: retry, missRetryElement: missRetryElementOnResend)
                guard user.sendReadiness.snapshot.canFlushApplicationStanzas else {
                    user.logConnectionDiagnostics(
                        event: "application_message_send_deferred_no_replay_policy",
                        details: [
                            "messageId": deferredMessageId,
                            "conversationType": deferredConversationType
                        ]
                    )
                    return
                }
                user.action { _, stream in
                    if stream === user.xmppStream {
                        user.sendPrimaryStanza(stanzaToSend, replayPolicy: .notReplayable)
                    } else {
                        stream.send(stanzaToSend)
                    }
                }
            })
            LastChats.updateErrorState(for: item.opponent, owner: self.owner, conversationType: item.conversationType)
        } catch {
            DDLogDebug("cant send message \(primary)")
        }
    }
    
    struct ForwardedMessagePrimaryWithNotmalMessage {
        let primary: String
        let stanzaPrimary: String
    }
    
    internal func formForwardedMessages(_ forwarded: [String]) -> [ForwardedMessageItem] {
        var out: [ForwardedMessageItem] = []
        var legacyBody: String = ""
        do {
            let realm = try WRealm.safe()
            
            let dateFormatter: DateFormatter = DateFormatter()
            let timeFormatter: DateFormatter = DateFormatter()
            
            dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
            timeFormatter.dateFormat = "[HH:mm:ss]"
            
            let preparedForwardedMessages = forwarded.compactMap {
                return ForwardedMessagePrimaryWithNotmalMessage(
                    primary: $0,
                    stanzaPrimary: [$0, "stanza"].prp()
                )
            }
            
            try preparedForwardedMessages.forEach {
                item in
                var body: String? = nil
                var stanza: DDXMLElement? = nil
                var date: Date? = nil
                if let instance = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: item.stanzaPrimary) {
                    let storageItem = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary)
                    let stanzaRaw = instance.stanza
                    let document = try DDXMLDocument(xmlString: "\(stanzaRaw)", options: 0)
                    guard let root = document.rootElement()?.copy() as? DDXMLElement else { fatalError() }
                    
                    let storedMessage = XMPPMessage(from: root)
                    let forwardingSource = forwardingSourceMessage(
                        from: storedMessage,
                        storedTimestamp: instance.timestamp,
                        storageItem: storageItem
                    )
                    let message = forwardingSource.message
                    
                    
                    body = ">\(dateFormatter.string(from: forwardingSource.timestamp))\n\(timeFormatter.string(from: forwardingSource.timestamp)) \(message.from?.bare ?? "")\n\(message.body ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)//.xmlEscaping(reverse: false)
                    body = body!.replacingOccurrences(
                        of: "\n",
                        with: "\n>",//.xmlEscaping(reverse: false),
                        options: [],
                        range: Range<String.Index>(NSRange(location: 0,
                                                           length: body!.count),
                                                   in: body!)
                    )
                    date = forwardingSource.timestamp
                    let refElement = DDXMLElement.element(withName: "reference") as! DDXMLElement
                    refElement.setXmlns("https://xabber.com/protocol/references")
                    refElement.addAttribute(withName: "type", stringValue: "mutable")
                    refElement.addAttribute(withName: "begin", integerValue: legacyBody.count)
                    legacyBody += "\(body?.xmlEscaping(reverse: false) ?? "")"
                    legacyBody += "\n"
                    refElement.addAttribute(withName: "end", integerValue: legacyBody.count)// - 1)
                    let forwardedElement = DDXMLElement.element(withName: "forwarded", uri: "urn:xmpp:forward:0") as! DDXMLElement
                    let delayElement = DDXMLElement.element(withName: "delay", uri: "urn:xmpp:delay") as! DDXMLElement
                    delayElement.addAttribute(withName: "stamp", stringValue: (date ?? Date()).XMPPFormattedDate)
                    forwardedElement.addChild(delayElement)
                    forwardedElement.addChild(message)
                    refElement.addChild(forwardedElement)
                    stanza = refElement
                }
                if let body = body,
                    let stanza = stanza,
                    let date = date {
                    out.append(ForwardedMessageItem(referenceElement: stanza,
                                                    body: body,//.xmlEscaping(reverse: true),
                                                    count: body.count,
                                                    date: date))
                }
            }
        } catch {
            DDLogDebug("cant form body for forwarded messages")
        }
        return out.sorted(by: { $0.date.compare($1.date) == .orderedDescending })
    }

    private func forwardingSourceMessage(
        from storedMessage: XMPPMessage,
        storedTimestamp: Date,
        storageItem: MessageStorageItem?
    ) -> ForwardingSourceMessage {
        guard storageItem?.conversationType == .saved else {
            return ForwardingSourceMessage(message: storedMessage, timestamp: storedTimestamp)
        }

        if let savedServiceJid = storageItem?.opponent,
           savedServiceJid.isNotEmpty,
           [storedMessage.from?.bare, storedMessage.to?.bare].contains(savedServiceJid),
           let payload = savedForwardedPayload(from: storedMessage) {
            return ForwardingSourceMessage(
                message: payload,
                timestamp: getDeliveryDate(payload) ?? storageItem?.sentDate ?? storedTimestamp
            )
        }

        return ForwardingSourceMessage(
            message: storedMessage,
            timestamp: getDeliveryDate(storedMessage) ?? storageItem?.sentDate ?? storedTimestamp
        )
    }

    private func savedForwardedPayload(from message: XMPPMessage) -> XMPPMessage? {
        for reference in message.elements(forName: "reference") where reference.xmlns() == "https://xabber.com/protocol/references" {
            guard let forwarded = reference.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"),
                  let payload = forwarded.element(forName: "message") else {
                continue
            }
            let payloadCopy = payload.copy() as? DDXMLElement ?? payload
            return XMPPMessage(from: payloadCopy)
        }
        return nil
    }
    
    internal func prepareForwards(_ forwardedIds: [String], primary: String, isReport: Bool, owner: String, jid: String) -> [MessageForwardsInlineStorageItem] {
        var out: [MessageForwardsInlineStorageItem] = []
        
        do {
            let realm = try  WRealm.safe()
            forwardedIds.forEach { primary in
                if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                    let item = MessageForwardsInlineStorageItem()
                    
                    
                    item.owner = owner
                    item.jid = jid
                    item.forwardJid = instance.outgoing ? instance.owner : instance.opponent
                    if !instance.outgoing {
                        let rosterPrimary = RosterStorageItem.genPrimary(jid: instance.opponent, owner: instance.owner)
                        let nickname = realm.object(ofType: RosterStorageItem.self,
                                                    forPrimaryKey: rosterPrimary)?
                            .displayName
                        
                        item.forwardNickname = nickname ?? ""
                    } else {
                        item.forwardNickname = ""
                    }

                    item.rosterItem = realm
                        .object(ofType: RosterStorageItem.self,
                                forPrimaryKey: [instance.opponent, owner].prp())
                    item.body = instance.body
                    item.references.append(objectsIn: instance.references.toArray())
                    item.subforwards.append(objectsIn: instance.inlineForwards.toArray())
                    item.messageId = instance.primary
                    item.parentId = primary
                    item.originalDate = instance.date
                    item.isOutgoing = instance.outgoing
//                    item.updateDisplayMode()
                    out.append(item)
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
        return out.sorted(by: { ($0.originalDate?.timeIntervalSince1970 ?? 0.0) < ($1.originalDate?.timeIntervalSince1970 ?? 0.0) })
    }
    
    public func editSimpleMessage(_ body: String, primary: String, references: [MessageReferenceStorageItem] = []) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let stanzaId = instance.archivedId
                let conversationType = instance.conversationType
                references.forEach {
                    $0.owner = self.owner
                    $0.jid = instance.opponent
                    $0.messageId = primary
                    $0.conversationType = conversationType
                    $0.sentDate = Date()
                }
                try realm.write {
                    instance.legacyBody = body
                    instance.body = body
                    instance.references
                        .filter { [.markup, .mention, .quote].contains($0.kind) }
                        .compactMap { instance.references.index(of: $0) }
                        .sorted(by: >)
                        .forEach { instance.references.remove(at: $0) }
                    instance.references.append(objectsIn: references)
                    instance.messageError = "Editing".localizeString(id: "editing", arguments: [])
                    instance.editDate = Date()
                }
                let message = XMPPMessage()
                message.addBody(body)
                if let mentions = instance.createMentionsElement() {
                    message.addChild(mentions)
                }
                instance.createReferences().forEach {
                    message.addChild($0)
                }
                let stanzaIdElement = DDXMLElement(name: "stanza-id", xmlns: "urn:xmpp:sid:0")
                stanzaIdElement.addAttribute(withName: "by",
                                             stringValue: instance.groupchatMetadata != nil ? instance.opponent : self.owner)
                stanzaIdElement.addAttribute(withName: "id",
                                             stringValue: stanzaId)
                message.addChild(stanzaIdElement)
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.retract?.editMessage(stream, primary: primary, editedMessage: message, conversationType: conversationType)
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.msgDeleteManager.editMessage(stream, primary: primary, editedMessage: message, conversationType: conversationType)
                    })
                })
            }
        } catch {
            
        }
    }
        
    public func sendSimpleMessage(_ body: String, to jid: String, childs: [DDXMLElement] = [],  forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType, references: [MessageReferenceStorageItem] = [], isReport: Bool = false) -> String {
        let originalId = NanoID.new(8)
        do {
            let realm = try  WRealm.safe()
            let instance = MessageStorageItem()
            var legacyBody: String = ""
            let toForward: [ForwardedMessageItem] =   formForwardedMessages(forwarded)
            if isReport == false {
                toForward.forEach {
                    legacyBody += "\($0.body)\n"
                }
            }
            legacyBody += body
            references.forEach {
                $0.owner = owner
                $0.jid = jid
                $0.conversationType = conversationType
                $0.sentDate = Date()
            }
            instance.conversationType = conversationType
            instance.configureOutgoingMessage(body,
                                              legacy: legacyBody,
                                              messageId: originalId,
                                              owner: owner,
                                              opponent: jid,
                                              references: references,
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              isReport: isReport,
                                                                              owner: owner,
                                                                              jid: jid))
            if instance.conversationType == .regular && instance.displayAs == .text {
                instance.state = .sending
            }
            if realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@", owner, instance.messageId).count > 0 {
                instance.messageId = UUID().uuidString
            }
            instance.updatePrimary()
            let prevMessageInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))?.lastMessage
            let prevMessageId = prevMessageInstance?.messageId
            if let prevMessageId = prevMessageId, isReport == false {
                if !(prevMessageInstance?.outgoing ?? true) {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                        user.chatMarkers.displayed(stream, message: prevMessageId)
                    })
                }
            }
            
            try realm.write {
                _ = instance.save(commitTransaction: false)
                if isReport {
                    instance.isDeleted = true
                }
                let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))
                chat?.draftMessage = nil
            }
            
            self.processSender(item: instance.primary, childs: childs)
        } catch {
            DDLogDebug("cant store new message item")
        }
        return originalId
    }
    
    public func sendSystemMessage(_ body: String, attachments: [MessageReferenceStorageItem], to jid: String, childs: [DDXMLElement] = [], conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try  WRealm.safe()
            let instance = MessageStorageItem()
            instance.conversationType = conversationType
            instance.configureOutgoingMessage(body,
                                              legacy: body,
                                              messageId: UUID().uuidString,
                                              owner: owner,
                                              opponent: jid,
                                              references: attachments,
                                              inlineForwards: [])

            instance.updatePrimary()
            instance.displayAs = .system
            try realm.write {
                _ = instance.save(commitTransaction: false)
            }
            
            self.processSender(item: instance.primary, childs: childs)
        } catch {
            DDLogDebug("cant store new message item")
        }
    }
    
    public func willSendMediaMessage(_ attachments: [MessageReferenceStorageItem], to jid: String, forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType) -> String? {
        willSendMediaMessage(
            attachments,
            to: jid,
            forwarded: forwarded,
            conversationType: conversationType,
            body: "",
            legacyBody: ""
        )
    }

    public func willSendMediaMessage(
        _ attachments: [MessageReferenceStorageItem],
        to jid: String,
        forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        body: String,
        legacyBody captionLegacyBody: String
    ) -> String? {
        if attachments.isEmpty { return nil }
        do {
            let realm = try  WRealm.safe()
            let instance = MessageStorageItem()
            var legacyBody: String = ""
            let toForward = formForwardedMessages(forwarded)
            toForward.forEach {
                legacyBody += "\($0.body)\n"
            }
            legacyBody += captionLegacyBody
            
            instance.configureOutgoingMessage(body,
                                              legacy: legacyBody,
                                              messageId: UUID().uuidString,
                                              owner: owner,
                                              opponent: jid,
                                              references: attachments,
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              isReport: false,
                                                                              owner: owner,
                                                                              jid: jid))
            instance.conversationType = conversationType
            instance.state = .uploading
            instance.updatePrimary()
            instance.references.forEach {
                $0.owner = owner
                $0.jid = jid
                $0.messageId = instance.primary
                $0.conversationType = conversationType
            }
           
            try realm.write {
                _ = instance.save(commitTransaction: false)
            }
            let primary = instance.primary
            return primary
        } catch {
            DDLogDebug("cant store new message item")
        }
        return nil
    }
    
    public final func continueSendMediaMessage(_ primary: String?) {
        guard let primary = primary else { return }
        uploadMedia(for: primary)
    }
    
    public func sendMediaMessage(_ attachments: [MessageReferenceStorageItem], to jid: String, forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType) {
        sendMediaMessage(
            attachments,
            to: jid,
            forwarded: forwarded,
            conversationType: conversationType,
            body: "",
            legacyBody: ""
        )
    }

    public func sendMediaMessage(
        _ attachments: [MessageReferenceStorageItem],
        to jid: String,
        forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        body: String,
        legacyBody captionLegacyBody: String
    ) {
        let primary = willSendMediaMessage(
            attachments,
            to: jid,
            forwarded: forwarded,
            conversationType: conversationType,
            body: body,
            legacyBody: captionLegacyBody
        )
        continueSendMediaMessage(primary)
    }

    internal func uploadMedia(for primary: String, retry: Bool = false) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let opponent = instance.opponent
                let conversationType = instance.conversationType
                try realm.write {
                    instance.state = .uploading
                    instance.messageError = nil
                    instance.messageErrorCode = nil
                    instance.references.forEach {
                        $0.hasError = false
                    }
                }
                LastChats.updateErrorState(for: opponent, owner: self.owner, conversationType: conversationType)
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }

        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            user.cloudStorage.getFileData(message: primary, successCallback: {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                        try realm.write {
                            instance.createLegacyBody()
                            instance.state = .sending
                            instance.messageError = nil
                            instance.messageErrorCode = nil
                            instance.references.forEach {
                                $0.hasError = false
                            }
                        }
                        LastChats.updateErrorState(for: instance.opponent, owner: instance.owner, conversationType: instance.conversationType)
                    }
                    self.processSender(item: primary, retry: retry)
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            }, failCallback: {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                        try realm.write {
                            instance.state = .error
                            realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: instance.opponent, owner: instance.owner, conversationType: instance.conversationType))?.hasErrorInChat = true
                        }
                    }
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            })
        })
    }
}
