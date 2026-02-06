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
            let resource = realm
                .object(ofType: RosterStorageItem.self,
                        forPrimaryKey: RosterStorageItem
                            .genPrimary(jid: item.opponent,
                                        owner: item.owner))?
                .getPrimaryResource()?
                .resource
            let stanza = XMPPMessage(messageType: .chat,
                                     to: XMPPJID(string: item.opponent, resource: resource),
                                     elementID: item.messageId,
                                     child: nil)
            
            let stanzaToSave = XMPPMessage(messageType: .chat,
                                           to: XMPPJID(string: item.opponent, resource: resource),
                                           elementID: item.messageId,
                                           child: nil)
            
            let conversationType = item.conversationType
            
            childs.forEach {
                stanza.addChild($0.copy() as! DDXMLElement)
                stanzaToSave.addChild($0.copy() as! DDXMLElement)
            }
            
            switch conversationType {
                case .omemo, .omemo1, .axolotl:
                    
                    formForwardedMessages(item
                        .inlineForwards
                        .sorted(byKeyPath: "originalDate", ascending: true)
                        .toArray()
                        .compactMap { return $0.messageId })
                        .forEach { stanzaToSave.addChild($0.referenceElement) }
                    
                    item.createReferences().forEach {
                        stanzaToSave.addChild($0)
                    }
                    
                    let forwardedMessages = formForwardedMessages(item
                        .inlineForwards
                        .sorted(byKeyPath: "originalDate", ascending: true)
                        .toArray()
                        .compactMap { return $0.messageId })
                        .compactMap { $0.referenceElement }
                    let references = item.createReferences()
                    
                    guard let payload = AccountManager.shared.find(for: self.owner)?.omemo.prepareStanzaContent(
                        message: item.legacyBody,
                        date: item.sentDate,
                        jid: item.opponent,
                        additionalContent: [forwardedMessages, references].flatMap({ $0 }),
                        ignoreTimeSignature: item.displayAs == .system
                    ) else {
                        return
                    }
                    do {
                        let encrypted = try AccountManager.shared.find(for: self.owner)?.omemo.encryptMessage(message: payload, to: item.opponent)
                        if let encrypted = encrypted {
                            stanza.addChild(encrypted)
                        }
                    } catch {
                        DDLogDebug("MessageManager; \(#function). \(error.localizedDescription)")
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
            try realm.write {
                if item.displayAs != .system {
                    if item.conversationType.isEncrypted {
                        if let conversation = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.opponent, owner: item.owner, conversationType: item.conversationType)) {
                            if conversation.isAfterburnEnabled {
                                let ephemeralElement = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
                                ephemeralElement.addAttribute(withName: "timer", doubleValue: conversation.afterburnInterval)
                                stanza.addChild(ephemeralElement)
                                item.afterburnInterval = conversation.afterburnInterval
                            }
                        }
                    }
                }
                
                item.state = .sending
                
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
            AccountManager.shared.find(for: owner)?.unsafeAction({ (user, stream) in
                stanza.addChild(user.chatMarkers.child)
                let stanzaToSend = user.deliveryManager.apply(to: stanza, retry: retry, missRetryElement: missRetryElementOnResend)
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                    stream.send(stanzaToSend)
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        stream.send(stanzaToSend)
                    })
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
                    let stanzaRaw = instance.stanza
                    let document = try DDXMLDocument(xmlString: "\(stanzaRaw)", options: 0)
                    guard let root = document.rootElement()?.copy() as? DDXMLElement else { fatalError() }
                    
                    let message = XMPPMessage(from: root)
                    
                    
                    body = ">\(dateFormatter.string(from: instance.timestamp))\n\(timeFormatter.string(from: instance.timestamp)) \(message.from?.bare ?? "")\n\(message.body ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)//.xmlEscaping(reverse: false)
                    body = body!.replacingOccurrences(
                        of: "\n",
                        with: "\n>",//.xmlEscaping(reverse: false),
                        options: [],
                        range: Range<String.Index>(NSRange(location: 0,
                                                           length: body!.count),
                                                   in: body!)
                    )
                    date = instance.timestamp
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
    
    internal func prepareForwards(_ forwardedIds: [String], primary: String, owner: String, jid: String) -> [MessageForwardsInlineStorageItem] {
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
    
    public func editSimpleMessage(_ body: String, primary: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                
                let stanzaId = instance.archivedId
                let message = XMPPMessage()
                message.addBody(body)
                let stanzaIdElement = DDXMLElement(name: "stanza-id", xmlns: "urn:xmpp:sid:0")
                stanzaIdElement.addAttribute(withName: "by",
                                             stringValue: instance.groupchatMetadata != nil ? instance.opponent : self.owner)
                stanzaIdElement.addAttribute(withName: "id",
                                             stringValue: stanzaId)
                message.addChild(stanzaIdElement)
                let conversationType = instance.conversationType
                try realm.write {
                    instance.legacyBody = body
                    instance.body = body
                    instance.references
                        .filter { [.markup, .mention, .quote].contains($0.kind) }
                        .compactMap{ return instance.references.index(of: $0) }
                        .forEach { instance.references.remove(at: $0) }
                    instance.messageError = "Editing".localizeString(id: "editing", arguments: [])
                    instance.editDate = Date()
                    
                }
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
        
    public func sendSimpleMessage(_ body: String, to jid: String, childs: [DDXMLElement] = [],  forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType) -> String {
        let originalId = NanoID.new(8)
        do {
            let realm = try  WRealm.safe()
            let instance = MessageStorageItem()
            var legacyBody: String = ""
            let toForward: [ForwardedMessageItem] =   formForwardedMessages(forwarded)
            toForward.forEach {
                legacyBody += "\($0.body)\n"
            }
            legacyBody += body
            instance.conversationType = conversationType
            instance.configureOutgoingMessage(body,
                                              legacy: legacyBody,
                                              messageId: originalId,
                                              owner: owner,
                                              opponent: jid,
                                              references: [],
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              owner: owner,
                                                                              jid: jid))
            if realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@", owner, instance.messageId).count > 0 {
                instance.messageId = UUID().uuidString
            }
            instance.updatePrimary()
            let prevMessageInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))?.lastMessage
            let prevMessageId = prevMessageInstance?.messageId
            if let prevMessageId = prevMessageId {
                if !(prevMessageInstance?.outgoing ?? true) {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                        user.chatMarkers.displayed(stream, message: prevMessageId)
                    })
                }
            }
            try realm.write {
                _ = instance.save(commitTransaction: false)
                let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))
                chat?.lastReadId = nil
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
                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))?.lastReadId = nil
            }
            
            self.processSender(item: instance.primary, childs: childs)
        } catch {
            DDLogDebug("cant store new message item")
        }
    }
    
    public func willSendMediaMessage(_ attachments: [MessageReferenceStorageItem], to jid: String, forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType) -> String? {
        if attachments.isEmpty { return nil }
        do {
            let realm = try  WRealm.safe()
            let instance = MessageStorageItem()
            var legacyBody: String = ""
            let toForward = formForwardedMessages(forwarded)
            toForward.forEach {
                legacyBody += "\($0.body)\n"
            }
            
            instance.configureOutgoingMessage("",
                                              legacy: legacyBody,
                                              messageId: UUID().uuidString,
                                              owner: owner,
                                              opponent: jid,
                                              references: attachments,
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              owner: owner,
                                                                              jid: jid))
            instance.conversationType = conversationType
            instance.state = .uploading
            instance.updatePrimary()
           
            try realm.write {
                _ = instance.save(commitTransaction: false)
                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))?.lastReadId = nil
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
        if attachments.isEmpty { return }
        do {
            let realm = try  WRealm.safe()
            let instance = MessageStorageItem()
            var legacyBody: String = ""
            let toForward = formForwardedMessages(forwarded)
            toForward.forEach {
                legacyBody += "\($0.body)\n"
            }
            
            instance.configureOutgoingMessage("",
                                              legacy: legacyBody,
                                              messageId: UUID().uuidString,
                                              owner: owner,
                                              opponent: jid,
                                              references: attachments,
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              owner: owner,
                                                                              jid: jid))
            instance.conversationType = conversationType
            instance.state = .uploading
           
            try realm.write {
                _ = instance.save(commitTransaction: false)
            }
            let primary = instance.primary
            uploadMedia(for: primary)
            
        } catch {
            DDLogDebug("cant store new message item")
        }
    }
    
    internal func uploadMedia(for primary: String, retry: Bool = false) {
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            user.cloudStorage.getFileData(message: primary, successCallback: {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                        try realm.write {
                            instance.createLegacyBody()
                            instance.state = .sending
                        }
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
