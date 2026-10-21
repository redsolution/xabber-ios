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
import CocoaLumberjack

private enum MessageMediaUploadTrace {
    static func log(_ event: String, details: [(String, Any?)] = []) {
        let renderedDetails = details.compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(key)=\(format(value))"
        }.joined(separator: " ")
        let suffix = renderedDetails.isEmpty ? "" : " \(renderedDetails)"
        DDLogDebug("MEDIA_UPLOAD_TRACE event=\(event)\(suffix)")
    }

    private static func format(_ value: Any) -> String {
        let string = String(describing: value)
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard !string.isEmpty,
              string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return "\"\(string)\""
        }
        return string
    }
}

extension MessageManager {
    
    struct ForwardedMessageItem {
        let referenceElement: DDXMLElement
        let body: String
        let count: Int
        let date: Date
    }

    internal static func outboundDestinationJID(
        for opponent: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        resource: String?
    ) -> XMPPJID? {
        guard let baseJID = XMPPJID(string: opponent) else {
            return nil
        }

        // Device fanout belongs inside the OMEMO header. A roster resource must
        // never pin a conversation message to one connection or expired device.
        return XMPPJID(string: baseJID.bare)
    }

    internal static func canonicalOutgoingConversationJID(
        for jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> String {
        guard conversationType == .regular,
              let bareJID = XMPPJID(string: jid)?.bare,
              bareJID.isNotEmpty else {
            return jid
        }
        return bareJID
    }

    internal static func retryRequiresMediaUpload(_ instance: MessageStorageItem) -> Bool {
        instance.references.contains { retryReferenceRequiresMediaUpload($0) }
    }

    private static func retryReferenceRequiresMediaUpload(_ reference: MessageReferenceStorageItem) -> Bool {
        guard [MessageReferenceStorageItem.Kind.media, .voice].contains(reference.kind) else {
            return false
        }
        if !reference.isUploaded {
            return true
        }
        return isLocalOnlyFileSharingURI(reference.fileSharingURI)
    }

    private static func isLocalOnlyFileSharingURI(_ uri: String?) -> Bool {
        guard let uri = uri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uri.isEmpty else {
            return false
        }
        if uri.hasPrefix("/") {
            return true
        }
        guard let scheme = URL(string: uri)?.scheme?.lowercased() else {
            return false
        }
        return ["asset", "assets-library", "file", "ph", "photos", "data"].contains(scheme)
    }

    private static func retryMediaUploadRouteDetails(for instance: MessageStorageItem) -> [(String, Any?)] {
        let mediaReferences = instance.references.filter {
            [MessageReferenceStorageItem.Kind.media, .voice].contains($0.kind)
        }
        let pendingMediaReferences = mediaReferences.filter { retryReferenceRequiresMediaUpload($0) }
        return [
            ("displayAs", instance.displayAs.rawValue),
            ("state", instance.state.rawValue),
            ("referenceCount", instance.references.count),
            ("mediaReferenceCount", mediaReferences.count),
            ("pendingMediaReferenceCount", pendingMediaReferences.count),
            ("uploadedMediaReferenceCount", mediaReferences.filter(\.isUploaded).count),
            ("failedMediaReferenceCount", mediaReferences.filter(\.hasError).count)
        ]
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
                guard optOutAllowsOutgoing(to: instance.opponent) else { return }
                guard preparedBatchPredecessorsAllowed(for: instance, in: realm) else { return }
                let requiresMediaUpload = Self.retryRequiresMediaUpload(instance)
                if requiresMediaUpload {
                    let localOnlyUploadedReferences = instance.references.filter {
                        [MessageReferenceStorageItem.Kind.media, .voice].contains($0.kind)
                            && $0.isUploaded
                            && Self.isLocalOnlyFileSharingURI($0.fileSharingURI)
                    }
                    if !localOnlyUploadedReferences.isEmpty {
                        try realm.write {
                            localOnlyUploadedReferences.forEach {
                                $0.isUploaded = false
                            }
                        }
                    }
                }
                let route = requiresMediaUpload ? "uploadMedia" : "processSender"
                MessageMediaUploadTrace.log("message_retry_route", details: [
                    ("owner", self.owner),
                    ("messagePrimary", primary),
                    ("route", route)
                ] + Self.retryMediaUploadRouteDetails(for: instance))
                if requiresMediaUpload {
                    self.uploadMedia(for: primary, retry: true)
                } else {
                    if instance.systemMetadata?["forwardUploadPending"] as? Bool == true {
                        try realm.write { try Self.finalizePreparedForwardUpload(instance, in: realm) }
                    }
                    self.processSender(
                        item: primary,
                        retry: true,
                        groupMentionIntent: instance.groupMentionIntent,
                        groupMentionSenderRole: instance.groupMentionSenderRole,
                        groupMentionAllCapabilityGranted: instance.groupMentionAllCapabilityGranted
                    )
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    internal func processSender(
        item primary: String,
        retry: Bool = false,
        childs: [DDXMLElement] = [],
        groupMentionIntent: GroupMessageMentionIntent? = nil,
        groupMentionSenderRole: GroupMemberRole? = nil,
        groupMentionAllCapabilityGranted: Bool = false
    ) -> Bool {
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) else {
                return false
            }
            guard optOutAllowsOutgoing(to: item.opponent) else { return false }
            guard preparedBatchPredecessorsAllowed(for: item, in: realm) else { return false }
            guard item.systemMetadata?["forwardUploadPending"] as? Bool != true else { return false }
            if let groupMentionIntent {
                let persistMentionAuthorization = {
                    item.groupMentionIntent = groupMentionIntent
                    item.groupMentionSenderRole = groupMentionSenderRole
                    item.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
                }
                if realm.isInWriteTransaction {
                    persistMentionAuthorization()
                } else {
                    try realm.write {
                        persistMentionAuthorization()
                    }
                }
            }
            let conversationType = item.conversationType
            let conversationJID = Self.canonicalOutgoingConversationJID(
                for: item.opponent,
                conversationType: conversationType
            )
            let resource = realm
                .object(ofType: RosterStorageItem.self,
                        forPrimaryKey: RosterStorageItem
                            .genPrimary(jid: conversationJID,
                                        owner: item.owner))?
                .getPrimaryResource()?
                .resource
            let destinationJID = MessageManager.outboundDestinationJID(
                for: conversationJID,
                conversationType: conversationType,
                resource: resource
            )
            let stanza = XMPPMessage(messageType: .chat,
                                     to: destinationJID,
                                     elementID: item.messageId,
                                     child: nil)
            
            stanza.setXmlns("jabber:client")
            let stanzaToSave = XMPPMessage(messageType: .chat,
                                           to: destinationJID,
                                           elementID: item.messageId,
                                           child: nil)
            stanzaToSave.setXmlns("jabber:client")
            
            let preparedContent = try Self.preparedForwardingContent(for: item, in: realm)
            (preparedContent == nil ? childs : []).forEach {
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
                AccountManager.shared.find(for: item.owner)?.omemo.requestMissingDeviceLists(jid: item.opponent)
                failEncryptedSend(OmemoManagerError.noTrustedRecipientDevices)
                return false
            }
            
            let contentBody: String
            let contentElements: [DDXMLElement]
            if let preparedContent {
                contentBody = preparedContent.body ?? ""
                contentElements = (preparedContent.children ?? []).compactMap { $0 as? DDXMLElement }.filter {
                    !SCEReceivePolicy.matches($0, name: "body", namespace: "jabber:client") &&
                    !SCEReceivePolicy.matches($0, name: "origin-id", namespace: "urn:xmpp:sid:0")
                }
            } else {
                let forwardedIDs = item.inlineForwards.sorted(byKeyPath: "originalDate", ascending: true)
                    .toArray().compactMap { $0.messageId }
                let forwardedItems = formForwardedMessages(forwardedIDs)
                if !forwardedIDs.isEmpty && forwardedItems.isEmpty {
                    throw ForwardOutgoingAdmissionError.missingPreparedContent
                }
                let forwardedFallbackBody = forwardedItems.map { "\($0.body)\n" }.joined()
                let offset = forwardedFallbackBody.isNotEmpty && item.legacyBody.hasPrefix(forwardedFallbackBody)
                    ? forwardedItems.last?.referenceElement.attributeIntegerValue(forName: "end") ?? 0 : 0
                let mentions = item.createMentionsElement().map { [$0] } ?? []
                contentBody = item.legacyBody
                contentElements = forwardedItems.map(\.referenceElement) + mentions + shiftReferenceRanges(item.createReferences(), by: offset)
            }
            for element in contentElements { stanzaToSave.addChild(element.copy() as! DDXMLElement) }
            let savedBody = DDXMLElement(name: "body", xmlns: "jabber:client")
            savedBody.stringValue = contentBody
            stanzaToSave.addChild(savedBody)

            var encryptedAuthoredTime: Omemo2PayloadCodec.AuthoredTime?
            switch conversationType {
            case .omemo, .omemo1, .axolotl:
                guard let payload = AccountManager.shared.find(for: self.owner)?.omemo.prepareStanzaContent(
                    message: contentBody, date: item.sentDate, jid: item.opponent,
                    additionalContent: contentElements.map { $0.copy() as! DDXMLElement },
                    ignoreTimeSignature: item.displayAs == .system) else {
                    failEncryptedSend()
                    return false
                }
                do {
                    guard let prepared = try AccountManager.shared.find(for: self.owner)?.omemo.encryptPreparedMessage(message: payload, to: item.opponent) else {
                        throw OmemoManagerError.encryptionFailed
                    }
                    stanza.addChild(prepared.element)
                    if conversationType == .omemo { encryptedAuthoredTime = prepared.time }
                } catch {
                    failEncryptedSend(error)
                    return false
                }
                stanza.addBody("Message was encrypted by OMEMO".localizeString(id: "message_omemo_encryption", arguments: []))
            default:
                for element in contentElements { stanza.addChild(element.copy() as! DDXMLElement) }
                let bodyElement = DDXMLElement(name: "body", xmlns: "jabber:client")
                bodyElement.stringValue = contentBody
                stanza.addChild(bodyElement)
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
                conversationJid: conversationJID,
                conversationType: item.conversationType,
                messagePrimary: item.primary,
                originId: item.messageId,
                stanzaXML: stanzaToSave.xmlString,
                createdAt: item.conversationType == .omemo ? item.outgoingOperationalDate : item.date,
                replayRequired: retry
            )
            try realm.write {
                if let encryptedAuthoredTime {
                    item.applyOutgoingAuthoredTime(encryptedAuthoredTime)
                    if let chat = realm.object(ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversationJID, owner: item.owner, conversationType: item.conversationType)),
                       chat.lastMessage?.primary == item.primary || chat.lastMessageId == item.messageId {
                        chat.messageDate = encryptedAuthoredTime.date
                    }
                }
                if item.displayAs != .system {
                    if item.conversationType.isEncrypted {
                        if let conversation = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversationJID, owner: item.owner, conversationType: item.conversationType)) {
                            if conversation.isAfterburnEnabled {
                                let ephemeralElement = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
                                ephemeralElement.addAttribute(withName: "timer", doubleValue: conversation.afterburnInterval)
                                stanza.addChild(ephemeralElement)
                                item.applyAutoDeleteTTL(
                                    conversation.afterburnInterval,
                                    startsAt: item.outgoingOperationalDate,
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
                        jid: conversationJID,
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
                    if preparedContent == nil {
                        realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: "\(item.primary)_stanza")?
                            .stanza = stanzaToSave.compactXMLString()
                    }
                    if let instance = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: conversationJID,
                            owner: item.owner,
                            conversationType: item.conversationType
                        )
                    ) {
                        instance.lastMessage = item
                        instance.messageDate = Date()
                    }
                } else if preparedContent == nil {
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
                LastChats.updateErrorState(for: conversationJID, owner: self.owner, conversationType: item.conversationType)
                try recordPreparedSubmissionAcceptance(item, state: "queued", in: realm)
                return true
            }
            guard let sendingAccount = AccountManager.shared.find(for: owner) else { return false }
            let deferredMessageId = item.messageId
            let deferredConversationType = item.conversationType.rawValue
            sendingAccount.unsafeAction({ (user, stream) in
                guard self.optOutAllowsOutgoing(to: conversationJID) else {
                    user.outgoingStanzaWasBlocked(stanza)
                    return
                }
                stanza.addChild(user.chatMarkers.child)
                let stanzaToSend = user.deliveryManager.apply(to: stanza, retry: retry, missRetryElement: missRetryElementOnResend)
                if conversationType.isEncrypted {
                    OmemoManager.synchronizeOutgoingEncryptionMetadata(stanzaToSend)
                }
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
                    guard self.optOutAllowsOutgoing(to: conversationJID) else {
                        user.outgoingStanzaWasBlocked(stanzaToSend)
                        return
                    }
                    if stream === user.xmppStream {
                        user.sendPrimaryStanza(stanzaToSend, replayPolicy: .notReplayable)
                    } else {
                        stream.send(stanzaToSend)
                    }
                }
            })
            LastChats.updateErrorState(for: conversationJID, owner: self.owner, conversationType: item.conversationType)
            try recordPreparedSubmissionAcceptance(item, state: "awaitingTransport", in: realm)
        } catch {
            DDLogDebug("cant send message \(primary)")
            if let realm = try? WRealm.safe(),
               let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
               item.systemMetadata?["forwardPreparedVersion"] as? Int == 1 {
                try? realm.write {
                    item.state = .error
                    item.messageErrorCode = "forward-preparation"
                }
            }
            return false
        }
        return true
    }

    private func recordPreparedSubmissionAcceptance(_ row: MessageStorageItem, state: String, in realm: Realm) throws {
        guard row.systemMetadata?["forwardPreparedVersion"] as? Int == 1 else { return }
        try realm.write {
            var metadata = row.systemMetadata ?? [:]
            metadata["forwardSubmissionState"] = state
            row.systemMetadata = metadata
        }
    }

    /// Resuming any retained tail first hands off the untouched predecessors.
    /// An already queued or scheduled predecessor keeps its existing ID and is
    /// not admitted or scheduled a second time by that tail's retry.
    private func preparedBatchPredecessorsAllowed(for row: MessageStorageItem, in realm: Realm) -> Bool {
        guard let batch = row.systemMetadata?["forwardBatchPrimaryIDs"] as? [String] else { return true }
        guard let index = batch.firstIndex(of: row.primary), Set(batch).count == batch.count else { return false }
        for primary in batch.prefix(index) {
            guard let predecessor = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
                  predecessor.owner == owner, predecessor.outgoing,
                  predecessor.systemMetadata?["forwardPreparedVersion"] as? Int == 1 else { return false }
            let state = predecessor.systemMetadata?["forwardSubmissionState"] as? String
            if state == "queued" || state == "awaitingTransport" { continue }
            if !realm.objects(OutgoingMessageQueueItem.self)
                .filter("owner == %@ AND messagePrimary == %@", owner, primary).isEmpty { continue }
            guard processSender(item: primary) else { return false }
        }
        return true
    }
    
    struct ForwardedMessagePrimaryWithNotmalMessage {
        let primary: String
        let stanzaPrimary: String
    }
    
    internal func formForwardedMessages(_ forwarded: [String]) -> [ForwardedMessageItem] {
        do {
            let realm = try WRealm.safe()
            let sources = try ForwardSourceLoader.load(ids: forwarded, owner: owner, realm: realm)
            let units = try ForwardSendPlanner.plan(sources: sources, comment: "")
            var result: [ForwardedMessageItem] = []
            var offset = 0
            for unit in units {
                for reference in unit.refs {
                    guard let payload = inlineForwardPayloadMessage(from: reference),
                          let begin = Int(reference.attributeStringValue(forName: "begin") ?? ""),
                          let end = Int(reference.attributeStringValue(forName: "end") ?? ""),
                          var fallback = Self.forwardWireSubstring(unit.body, begin: begin, end: end) else { continue }
                    if fallback.hasSuffix("\n") { fallback.removeLast() }
                    reference.removeAttribute(forName: "begin")
                    reference.removeAttribute(forName: "end")
                    reference.addAttribute(withName: "begin", integerValue: offset)
                    offset += fallback.xmlEscaping(reverse: false).unicodeScalars.count + 1
                    reference.addAttribute(withName: "end", integerValue: offset)
                    result.append(ForwardedMessageItem(referenceElement: reference, body: fallback,
                        count: fallback.count, date: payload.date ?? sources.first?.date ?? .distantPast))
                }
            }
            return result
        } catch {
            // The compatibility API must never turn a failed selection into a
            // successful partial forward. Public admission uses the throwing API.
            DDLogDebug("MessageManager: forwarding preparation rejected")
            return []
        }
    }

    private static func forwardWireSubstring(_ body: String, begin: Int, end: Int) -> String? {
        let scalars = Array(body.xmlEscaping(reverse: false).unicodeScalars)
        guard begin >= 0, end >= begin, end <= scalars.count else { return nil }
        return String(String.UnicodeScalarView(scalars[begin..<end])).xmlEscaping(reverse: true)
    }

    private func shiftReferenceRanges(
        _ references: [DDXMLElement],
        by offset: Int
    ) -> [DDXMLElement] {
        guard offset > 0 else { return references }
        return references.compactMap { reference in
            guard let copy = reference.copy() as? DDXMLElement else { return nil }
            ["begin", "end"].forEach { attributeName in
                guard let rawValue = copy.attributeStringValue(forName: attributeName),
                      let value = Int(rawValue) else {
                    return
                }
                copy.removeAttribute(forName: attributeName)
                copy.addAttribute(withName: attributeName, integerValue: value + offset)
            }
            return copy
        }
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
    
    /// Edits current-level text without reconstructing any forwarded original.
    internal static func messageByEditingForwardComment(
        _ original: XMPPMessage, body: String, references: [DDXMLElement], mentions: DDXMLElement? = nil
    ) throws -> XMPPMessage {
        guard SCEReceivePolicy.matches(original, name: "message", namespace: "jabber:client"),
              SCEReceivePolicy.children(of: original, named: "body", xmlns: "jabber:client").count == 1 else {
            throw ForwardOutgoingAdmissionError.mismatchedPreparedContent
        }
        let message = XMPPMessage(from: original.copy() as! DDXMLElement)
        let originalBody = message.body ?? ""
        let allReferences = SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references")
        let forwardMarkers = allReferences.filter { reference in
            (reference.children ?? []).compactMap { $0 as? DDXMLElement }.contains { $0.localName == "forwarded" }
        }
        guard forwardMarkers.count == admittedInlineForwardReferences(in: message).count else {
            throw ForwardOutgoingAdmissionError.mismatchedPreparedContent
        }
        var protected: [(reference: DDXMLElement, begin: Int, end: Int)] = []
        for reference in allReferences {
            if reference.attributeStringValue(forName: "type") == "decoration" {
                reference.detach()
                continue
            }
            guard reference.attributeStringValue(forName: "type") == "mutable" else { continue }
            guard let begin = Int(reference.attributeStringValue(forName: "begin") ?? ""),
                  let end = Int(reference.attributeStringValue(forName: "end") ?? ""),
                  forwardWireSubstring(originalBody, begin: begin, end: end) != nil else {
                throw ForwardOutgoingAdmissionError.mismatchedPreparedContent
            }
            protected.append((reference, begin, end))
        }
        protected.sort { $0.begin < $1.begin }
        var previousEnd = 0
        var prefix = ""
        for item in protected {
            guard item.begin >= previousEnd,
                  let fallback = forwardWireSubstring(originalBody, begin: item.begin, end: item.end) else {
                throw ForwardOutgoingAdmissionError.mismatchedPreparedContent
            }
            previousEnd = item.end
            if !prefix.isEmpty && !prefix.hasSuffix("\n") { prefix += "\n" }
            item.reference.removeAttribute(forName: "begin")
            item.reference.removeAttribute(forName: "end")
            item.reference.addAttribute(withName: "begin", integerValue: prefix.xmlEscaping(reverse: false).unicodeScalars.count)
            prefix += fallback
            item.reference.addAttribute(withName: "end", integerValue: prefix.xmlEscaping(reverse: false).unicodeScalars.count)
        }
        if !prefix.isEmpty && !prefix.hasSuffix("\n") && !body.isEmpty { prefix += "\n" }
        for element in SCEReceivePolicy.children(of: message, named: "body", xmlns: "jabber:client") { element.detach() }
        for element in SCEReceivePolicy.children(of: message, named: "stanza-id", xmlns: "urn:xmpp:sid:0") { element.detach() }
        for element in SCEReceivePolicy.children(of: message, named: "time", xmlns: "https://xabber.com/protocol/delivery") { element.detach() }
        for element in SCEReceivePolicy.children(of: message, named: "mentions", xmlns: "https://xabber.com/protocol/groups") { element.detach() }
        let bodyElement = DDXMLElement(name: "body", xmlns: "jabber:client")
        bodyElement.stringValue = prefix + body
        message.addChild(bodyElement)
        let offset = prefix.xmlEscaping(reverse: false).unicodeScalars.count
        for reference in references {
            let copy = reference.copy() as! DDXMLElement
            if copy.attributeStringValue(forName: "type") != "data" {
                for attribute in ["begin", "end"] {
                    guard let value = Int(copy.attributeStringValue(forName: attribute) ?? "") else { continue }
                    copy.removeAttribute(forName: attribute)
                    copy.addAttribute(withName: attribute, integerValue: value + offset)
                }
            }
            message.addChild(copy)
        }
        if let mentions { message.addChild(mentions.copy() as! DDXMLElement) }
        return message
    }

    @discardableResult
    public func editSimpleMessage(
        _ body: String,
        primary: String,
        references: [MessageReferenceStorageItem] = [],
        groupMentionIntent: GroupMessageMentionIntent? = nil,
        groupMentionSenderRole: GroupMemberRole? = nil,
        groupMentionAllCapabilityGranted: Bool = false
    ) -> Bool {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                guard instance.owner == self.owner, instance.outgoing,
                      optOutAllowsOutgoing(to: instance.opponent) else { return false }
                let stanzaId = instance.archivedId
                let conversationType = instance.conversationType
                if let raw = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: primary + "_stanza"),
                   raw.owner != self.owner { return false }
                let original = try Self.originalMessageForEdit(instance, in: realm)
                let hasStoredForwards = !instance.inlineForwards.isEmpty || instance.references.contains { $0.kind == .forward }
                let isPreparedUnit = instance.systemMetadata?["forwardPreparedVersion"] as? Int == 1
                let directForwardMarkers = original.map { message in
                    SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references").filter {
                        ($0.children ?? []).compactMap { $0 as? DDXMLElement }.contains { $0.localName == "forwarded" }
                    }
                } ?? []
                let preservesPreparedContent = isPreparedUnit || hasStoredForwards || !directForwardMarkers.isEmpty
                if preservesPreparedContent {
                    guard realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: primary + "_stanza") != nil,
                          let original, original.from?.bare == self.owner, original.to?.bare == instance.opponent else { return false }
                    if hasStoredForwards && directForwardMarkers.isEmpty { return false }
                }
                let editedReferences = references.map { reference -> MessageReferenceStorageItem in
                    let detached = MessageReferenceStorageItem(value: reference)
                    if reference.realm != nil { detached.primary = UUID().uuidString }
                    detached.temporaryData = reference.temporaryData
                    detached.pendingMediaAttachment = reference.pendingMediaAttachment
                    return detached
                }
                editedReferences.forEach {
                    $0.owner = self.owner
                    $0.jid = instance.opponent
                    $0.messageId = primary
                    $0.conversationType = conversationType
                    $0.sentDate = Date()
                }
                let preservedForwardEdit: XMPPMessage?
                if preservesPreparedContent, let original {
                    let projection = MessageStorageItem()
                    projection.references.append(objectsIn: editedReferences)
                    projection.groupMentionIntent = groupMentionIntent
                    projection.groupMentionSenderRole = groupMentionSenderRole
                    projection.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
                    preservedForwardEdit = try Self.messageByEditingForwardComment(original, body: body,
                        references: projection.createReferences(), mentions: projection.createMentionsElement())
                } else {
                    preservedForwardEdit = nil
                }
                try realm.write {
                    instance.groupMentionIntent = groupMentionIntent
                    instance.groupMentionSenderRole = groupMentionSenderRole
                    instance.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
                    if let preservedForwardEdit {
                        let pending = instance.editMessage(preservedForwardEdit, editDate: Date())
                        MessageStorageItem.persistPendingMediaAttachments(pending, forMessagePrimary: instance.primary, in: realm)
                        instance.storeStanza(in: realm)
                    } else {
                    instance.legacyBody = body
                    instance.body = body
                    instance.references
                        .filter { [.markup, .mention, .quote].contains($0.kind) }
                        .compactMap { instance.references.index(of: $0) }
                        .sorted(by: >)
                        .forEach { instance.references.remove(at: $0) }
                    instance.references.append(objectsIn: editedReferences)
                    }
                    instance.messageError = "Editing".localizeString(id: "editing", arguments: [])
                    instance.editDate = Date()
                }
                let message = preservedForwardEdit ?? XMPPMessage(from: DDXMLElement(name: "message", xmlns: "jabber:client"))
                if preservedForwardEdit == nil {
                if let original {
                    for name in ["type", "id", "from", "to"] {
                        if let value = original.attributeStringValue(forName: name) {
                            message.addAttribute(withName: name, stringValue: value)
                        }
                    }
                    if let origin = SCEReceivePolicy.children(of: original, named: "origin-id", xmlns: "urn:xmpp:sid:0").first {
                        message.addChild(origin.copy() as! DDXMLElement)
                    }
                } else if !conversationType.isEncrypted {
                    // Preserve the existing ordinary-message fallback.
                    message.addAttribute(withName: "type", stringValue: conversationType == .group ? "groupchat" : "chat")
                    message.addAttribute(withName: "id", stringValue: instance.messageId)
                    message.addAttribute(withName: "from", stringValue: self.owner)
                    message.addAttribute(withName: "to", stringValue: instance.opponent)
                    message.addOriginId(instance.messageId)
                }
                if conversationType.isEncrypted {
                    // The server targets the archived stanza by replace.id and
                    // retains its routing identifiers. Recover known bare
                    // bindings when original XML is unavailable or incomplete;
                    // do not synthesize an old XML id, resource or thread.
                    if message.attributeStringValue(forName: "from") == nil {
                        message.addAttribute(withName: "from", stringValue: self.owner)
                    }
                    if message.attributeStringValue(forName: "to") == nil {
                        message.addAttribute(withName: "to", stringValue: instance.opponent)
                    }
                }
                if let thread = original.flatMap({ SCEReceivePolicy.children(of: $0, named: "thread", xmlns: "jabber:client").first }) {
                    message.addChild(thread.copy() as! DDXMLElement)
                }
                // KissXML's addBody creates a namespace-less DOM node even
                // under a jabber:client message. Bind the QName explicitly for
                // the common SCE sender's validation before serialization.
                let editedBody = DDXMLElement(name: "body", xmlns: "jabber:client")
                editedBody.stringValue = body
                message.addChild(editedBody)
                if let mentions = instance.createMentionsElement() {
                    message.addChild(mentions)
                }
                instance.createReferences().forEach {
                    message.addChild($0)
                }
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
                return true
            }
        } catch {
            DDLogDebug("MessageManager: edit admission rejected: \(error.localizedDescription)")
        }
        return false
    }

    private static func originalMessageForEdit(_ instance: MessageStorageItem, in realm: Realm) throws -> XMPPMessage? {
        let original: DDXMLElement
        let stored = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: instance.primary + "_stanza")
        if let stored {
            guard stored.owner == instance.owner,
                  let parsed = try? DDXMLElement(xmlString: stored.stanza) else { return nil }
            original = parsed
        } else if let current = instance.originalStanza {
            original = current.copy() as! DDXMLElement
        } else {
            return nil
        }
        guard original.localName == "message",
              (original.uri ?? "").isEmpty || original.uri == "jabber:client" else { return nil }
        if (original.uri ?? "").isEmpty {
            // Older app-private outgoing stanzas were stored without the
            // enclosing stream's default namespace. Restore that context only
            // for this local format; foreign namespaces are rejected above.
            original.addNamespace(DDXMLNode.namespace(withName: "", stringValue: "jabber:client") as! DDXMLNode)
        }
        guard let parsed = try? DDXMLElement(xmlString: original.xmlString) else { return nil }
        let message = XMPPMessage(from: parsed)
        if SCEReceivePolicy.hasOMEMO2(message) {
            guard let stored,
                  instance.canForwardAuthenticatedPlaintext(stanzaXML: stored.stanza, owner: instance.owner),
                  SCEReceivePolicy.children(of: message, named: "encrypted", xmlns: SCEReceivePolicy.omemo).count == 1 else {
                throw ForwardPreparationError.unavailablePlaintext(instance.primary)
            }
            // Verified receive evidence covers this exact reconstructed outer
            // content. A replacement gets fresh transport encryption; nested
            // originals remain opaque and are never stripped here.
            SCEReceivePolicy.children(of: message, named: "encrypted", xmlns: SCEReceivePolicy.omemo).first?.detach()
            SCEReceivePolicy.children(of: message, named: "encryption", xmlns: "urn:xmpp:eme:0")
                .filter { $0.attributeStringValue(forName: "namespace") == SCEReceivePolicy.omemo }
                .forEach { $0.detach() }
        }
        return message
    }
        
    private func publishLocalOutgoingAdmission(
        primaryID: String,
        conversationJID: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) {
        localOutgoingAdmissionPublisher(
            ChatTimelineLocalOutgoingAdmission(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: conversationJID,
                    conversationType: conversationType
                ),
                primaryID: primaryID
            )
        )
    }

    enum ForwardOutgoingAdmissionError: Error {
        case gateClosed
        case emptyPlan
        case missingPreparedContent
        case mismatchedPreparedContent
        case persistenceFailed
    }

    struct ForwardOutgoingAdmission {
        let primaryIDs: [String]
        let messageIDs: [String]
        let uploadPrimary: String?
    }

    enum ForwardUnitSubmissionState: Equatable {
        case queued
        case awaitingTransport
        case blocked
        case failed
        case unsubmitted
    }

    struct ForwardUnitSubmission {
        let primaryID: String
        let state: ForwardUnitSubmissionState
    }

    struct ForwardOutgoingSubmission {
        let admittedPrimaryIDs: [String]
        let units: [ForwardUnitSubmission]
        var handedOffPrimaryIDs: [String] { units.filter { [.queued, .awaitingTransport].contains($0.state) }.map(\.primaryID) }
        var failedPrimaryIDs: [String] { units.filter { $0.state == .failed }.map(\.primaryID) }
        var blockedPrimaryIDs: [String] { units.filter { $0.state == .blocked }.map(\.primaryID) }
        var unsubmittedPrimaryIDs: [String] { units.filter { $0.state == .unsubmitted }.map(\.primaryID) }
    }

    enum ForwardBatchSendResult {
        case rejected(Error)
        case admitted(admission: ForwardOutgoingAdmission, submission: ForwardOutgoingSubmission)
    }

    /// Prepared content is persisted before any publication or network action.
    /// A retry reads this snapshot rather than the currently selected messages.
    internal static func preparedForwardingContent(
        for item: MessageStorageItem, in realm: Realm
    ) throws -> XMPPMessage? {
        guard item.systemMetadata?["forwardPreparedVersion"] as? Int == 1 else { return nil }
        guard let raw = realm.object(ofType: MessageStanzaStorageItem.self,
                                     forPrimaryKey: "\(item.primary)_stanza"),
              raw.owner == item.owner,
              let document = try? DDXMLDocument(xmlString: raw.stanza, options: 0),
              let root = document.rootElement(),
              SCEReceivePolicy.matches(root, name: "message", namespace: "jabber:client") else {
            throw ForwardOutgoingAdmissionError.missingPreparedContent
        }
        let message = XMPPMessage(from: root)
        guard item.outgoing, message.elementID == item.messageId,
              message.from?.bare == item.owner,
              message.to?.bare == XMPPJID(string: item.opponent)?.bare,
              SCEReceivePolicy.children(of: message, named: "body", xmlns: "jabber:client").count == 1 else {
            throw ForwardOutgoingAdmissionError.mismatchedPreparedContent
        }
        return message
    }

    /// Local ranges are derived from the final wire body after removing its
    /// fallback spans. Upload state belongs only to the caller's own files.
    private static func preparedForwardProjection(
        _ message: XMPPMessage, primary: String, jid: String, owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        ownReferences: [MessageReferenceStorageItem]
    ) -> [MessageReferenceStorageItem] {
        var projection = parseReferences(message, primary: primary, jid: jid, owner: owner).filter { $0.kind != .forward }
        var available = Set(projection.indices)
        for own in ownReferences.reversed() {
            let match = projection.indices.reversed().first { index in
                guard available.contains(index), projection[index].kind == own.kind else { return false }
                if [.media, .voice].contains(own.kind) {
                    return projection[index].fileSharingURI == own.fileSharingURI
                }
                return true
            }
            if let match {
                available.remove(match)
                let parsed = projection[match]
                parsed.primary = own.primary
                var metadata = own.metadata ?? [:]
                (parsed.metadata ?? [:]).forEach { metadata[$0.key] = $0.value }
                parsed.metadata = metadata
                parsed.temporaryData = own.temporaryData
                if parsed.pendingMediaAttachment == nil { parsed.pendingMediaAttachment = own.pendingMediaAttachment }
                parsed.isUploaded = own.isUploaded
                parsed.isDownloaded = own.isDownloaded
                parsed.hasError = own.hasError
            } else if [.media, .voice].contains(own.kind) {
                // A local upload may not yet have a wire source URI. Keep its
                // pending data until upload finalization produces that source.
                let pending = MessageReferenceStorageItem(value: own)
                pending.temporaryData = own.temporaryData
                pending.pendingMediaAttachment = own.pendingMediaAttachment
                pending.begin = 0
                pending.end = 0
                projection.append(pending)
            }
        }
        let ownIDs = Set(ownReferences.map(\.primary))
        for reference in projection where !ownIDs.contains(reference.primary) && [.media, .voice].contains(reference.kind) {
            if let uri = reference.fileSharingURI, URL(string: uri)?.scheme != nil, !isLocalOnlyFileSharingURI(uri) {
                reference.isUploaded = true
            }
        }
        for reference in projection {
            reference.conversationType = conversationType
            reference.pendingMediaAttachment?.conversationType = conversationType
        }
        return projection
    }

    private static func validatePreparedContentSize(_ message: XMPPMessage) throws {
        let bytes = (message.children ?? []).compactMap { $0 as? DDXMLElement }.filter {
            !SCEReceivePolicy.matches($0, name: "origin-id", namespace: "urn:xmpp:sid:0")
        }.reduce(0) { $0 + $1.xmlString.utf8.count }
        guard bytes <= 32_768 else { throw ForwardPreparationError.oversizedContent }
    }

    private func admitForwarding(
        body: String, legacyBody: String, to jid: String, forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        references: [MessageReferenceStorageItem], childs: [DDXMLElement] = [],
        intent: ForwardSendIntent, options: ForwardSendOptions,
        requiresUpload: Bool,
        groupMentionIntent: GroupMessageMentionIntent? = nil,
        groupMentionSenderRole: GroupMemberRole? = nil,
        groupMentionAllCapabilityGranted: Bool = false
    ) throws -> ForwardOutgoingAdmission {
        let realm = try WRealm.safe()
        let sources = try ForwardSourceLoader.load(ids: forwarded, owner: owner, realm: realm)
        var units = try ForwardSendPlanner.plan(sources: sources, comment: legacyBody, intent: intent, options: options)
        // New local attachments need a final authored carrier even when there is
        // no typed comment or selected current-level content left.
        let selectionHasOwnContent = sources.contains { source in
            let message = source.message
            let carried = admittedInlineForwardReferences(in: message)
            return !((message.body ?? "").xmlEscaping(reverse: false).excludeFromBody(carried, groupchat: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references")
                    .contains { ["media", "voice", "geoloc", "contact"].contains(getReferenceType($0) ?? "") }
        }
        if !references.isEmpty, units.last?.kind != .plain, legacyBody.isEmpty, !selectionHasOwnContent {
            units.append(ForwardPreparedUnit(body: "", refs: [], kind: .plain))
        }
        if units.isEmpty && !references.isEmpty { units.append(ForwardPreparedUnit(body: legacyBody, refs: [], kind: .plain)) }
        guard !units.isEmpty else { throw ForwardOutgoingAdmissionError.emptyPlan }
        let conversationJID = Self.canonicalOutgoingConversationJID(for: jid, conversationType: conversationType)
        guard let destination = Self.outboundDestinationJID(for: conversationJID,
                conversationType: conversationType, resource: nil) else {
            throw ForwardOutgoingAdmissionError.mismatchedPreparedContent
        }
        let batchDate = Date()
        var rows: [MessageStorageItem] = []
        for (index, unit) in units.enumerated() {
            let last = index == units.count - 1
            let messageID = UUID().uuidString
            let row = MessageStorageItem()
            row.conversationType = conversationType
            let raw = XMPPMessage(messageType: .chat, to: destination, elementID: messageID, child: nil)
            raw.setXmlns("jabber:client")
            raw.addAttribute(withName: "from", stringValue: owner)
            raw.addOriginId(messageID)
            unit.appendContent(to: raw)
            if last { childs.forEach { raw.addChild($0.copy() as! DDXMLElement) } }
            let ownReferences: [MessageReferenceStorageItem] = last ? references.map { reference in
                let copy = MessageReferenceStorageItem(value: reference)
                // Managed inputs must not be overwritten by a new message.
                if reference.realm != nil { copy.primary = UUID().uuidString }
                copy.temporaryData = reference.temporaryData
                copy.pendingMediaAttachment = reference.pendingMediaAttachment
                copy.owner = owner
                copy.jid = conversationJID
                copy.conversationType = conversationType
                let prefix = unit.body.xmlEscaping(reverse: false).unicodeScalars.count - legacyBody.xmlEscaping(reverse: false).unicodeScalars.count
                if copy.kind != .forwardContactData {
                    copy.begin += max(prefix, 0)
                    copy.end += max(prefix, 0)
                }
                return copy
            } : []
            let ownProjection = MessageStorageItem()
            ownProjection.owner = owner
            ownProjection.opponent = conversationJID
            ownProjection.primary = MessageStorageItem.genPrimary(messageId: messageID, owner: owner)
            ownProjection.body = body
            ownProjection.legacyBody = unit.body
            ownProjection.systemMetadata = ["forwardPreparedVersion": 1]
            ownProjection.references.append(objectsIn: ownReferences)
            if ownReferences.contains(where: { [.media, .voice].contains($0.kind) && (!requiresUpload || $0.isUploaded) }) {
                ownProjection.createLegacyBody()
            }
            let ownWireReferences = ownProjection.createReferences()
            ownWireReferences.forEach { raw.addChild($0) }
            SCEReceivePolicy.children(of: raw, named: "body", xmlns: "jabber:client").first?.stringValue = ownProjection.legacyBody
            if last {
                ownProjection.groupMentionIntent = groupMentionIntent
                ownProjection.groupMentionSenderRole = groupMentionSenderRole
                ownProjection.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
                if let mentions = ownProjection.createMentionsElement() { raw.addChild(mentions) }
            }
            try Self.validatePreparedContentSize(raw)
            // The wire serializer supplies inherited QNames for file/source
            // descendants. Parse that exact serialized content before deriving
            // local ranges so display and receiver admission see the same XML.
            let finalRaw = try XMPPMessage(xmlString: raw.xmlString)
            let primary = MessageStorageItem.genPrimary(messageId: messageID, owner: owner)
            let projection = Self.preparedForwardProjection(finalRaw, primary: primary, jid: conversationJID, owner: owner,
                                                            conversationType: conversationType, ownReferences: ownReferences)
            ownProjection.references.removeAll()
            ownProjection.references.append(objectsIn: projection)
            let visibleBody = ownProjection.normalizedIncomingTextBody(from: finalRaw)
            row.configureOutgoingMessage(visibleBody, legacy: ownProjection.legacyBody, messageId: messageID,
                owner: owner, opponent: conversationJID, references: projection,
                inlineForwards: parseInlineMessages(finalRaw, parentId: primary, jid: conversationJID, owner: owner))
            let authoredDate = batchDate.addingTimeInterval(Double(index) * 0.000_001)
            row.date = authoredDate
            row.sentDate = row.date
            if conversationType == .omemo {
                row.applyOutgoingAuthoredTime(try Omemo2PayloadCodec.authoredTime(at: authoredDate))
            }
            if last {
                row.groupMentionIntent = groupMentionIntent
                row.groupMentionSenderRole = groupMentionSenderRole
                row.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
            }
            var preparedMetadata = row.systemMetadata ?? [:]
            preparedMetadata["forwardPreparedVersion"] = 1
            row.systemMetadata = preparedMetadata
            row.state = requiresUpload && last ? .uploading : (conversationType == .regular ? .sending : .notSended)
            if requiresUpload && last {
                var metadata = row.systemMetadata ?? [:]
                metadata["forwardOwnReferencePrimaryIDs"] = ownReferences.map(\.primary)
                metadata["forwardOwnReferenceCount"] = ownWireReferences.count
                metadata["forwardPreparedBaseBody"] = unit.body
                row.systemMetadata = metadata
            }
            row.originalStanza = finalRaw
            rows.append(row)
        }
        for row in rows {
            var metadata = row.systemMetadata ?? [:]
            metadata["forwardBatchPrimaryIDs"] = rows.map(\.primary)
            if requiresUpload && row.primary == rows.last?.primary { metadata["forwardUploadPending"] = true }
            row.systemMetadata = metadata
        }
        try realm.write {
            for row in rows {
                guard row.save(commitTransaction: false) else { throw ForwardOutgoingAdmissionError.persistenceFailed }
            }
            realm.object(ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversationJID, owner: owner, conversationType: conversationType))?.draftMessage = nil
        }
        for row in rows {
            publishLocalOutgoingAdmission(primaryID: row.primary, conversationJID: conversationJID, conversationType: conversationType)
        }
        return ForwardOutgoingAdmission(primaryIDs: rows.map(\.primary), messageIDs: rows.map(\.messageId),
                                         uploadPrimary: requiresUpload ? rows.last?.primary : nil)
    }

    @discardableResult
    internal func submitForwarding(_ admission: ForwardOutgoingAdmission) -> ForwardOutgoingSubmission {
        var units: [ForwardUnitSubmission] = []
        var stopped = false
        for primary in admission.primaryIDs {
            guard !stopped else {
                units.append(ForwardUnitSubmission(primaryID: primary, state: .unsubmitted))
                continue
            }
            let accepted = processSender(item: primary)
            let realm = try? WRealm.safe()
            let row = realm?.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
            let state: ForwardUnitSubmissionState
            if accepted {
                let queued = realm?.objects(OutgoingMessageQueueItem.self)
                    .filter("owner == %@ AND messagePrimary == %@", owner, primary).isEmpty == false
                state = queued ? .queued : .awaitingTransport
            } else {
                state = row?.state == .error ? .failed : .blocked
                stopped = true
            }
            units.append(ForwardUnitSubmission(primaryID: primary, state: state))
        }
        return ForwardOutgoingSubmission(admittedPrimaryIDs: admission.primaryIDs, units: units)
    }

    /// Callers needing batch progress should use this result rather than treating
    /// a legacy String admission token as proof that every carrier was sent.
    @discardableResult
    public func sendForwardingMessage(
        _ body: String, to jid: String, forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        references: [MessageReferenceStorageItem] = [], childs: [DDXMLElement] = [],
        intent: ForwardSendIntent = .forward, options: ForwardSendOptions = .init(),
        groupMentionIntent: GroupMessageMentionIntent? = nil,
        groupMentionSenderRole: GroupMemberRole? = nil,
        groupMentionAllCapabilityGranted: Bool = false
    ) -> ForwardBatchSendResult {
        guard optOutAllowsOutgoing(to: jid) else {
            return .rejected(ForwardOutgoingAdmissionError.gateClosed)
        }
        do {
            let admission = try admitForwarding(body: body, legacyBody: body, to: jid, forwarded: forwarded,
                conversationType: conversationType, references: references, childs: childs,
                intent: intent, options: options, requiresUpload: false,
                groupMentionIntent: groupMentionIntent, groupMentionSenderRole: groupMentionSenderRole,
                groupMentionAllCapabilityGranted: groupMentionAllCapabilityGranted)
            return .admitted(admission: admission, submission: submitForwarding(admission))
        } catch {
            return .rejected(error)
        }
    }

    public func sendSimpleMessage(
        _ body: String,
        to jid: String,
        childs: [DDXMLElement] = [],
        forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        references: [MessageReferenceStorageItem] = [],
        isReport: Bool = false,
        forwardIntent: ForwardSendIntent = .forward,
        forwardOptions: ForwardSendOptions = .init(),
        groupMentionIntent: GroupMessageMentionIntent? = nil,
        groupMentionSenderRole: GroupMemberRole? = nil,
        groupMentionAllCapabilityGranted: Bool = false
    ) -> String {
        guard optOutAllowsOutgoing(to: jid) else { return "" }
        if !forwarded.isEmpty && !isReport {
            switch sendForwardingMessage(body, to: jid, forwarded: forwarded, conversationType: conversationType,
                    references: references, childs: childs, intent: forwardIntent, options: forwardOptions,
                    groupMentionIntent: groupMentionIntent, groupMentionSenderRole: groupMentionSenderRole,
                    groupMentionAllCapabilityGranted: groupMentionAllCapabilityGranted) {
            case .rejected:
                return ""
            case .admitted(let admission, _):
                return admission.messageIDs.last ?? ""
            }
        }
        let originalId = NanoID.new(8)
        do {
            let realm = try  WRealm.safe()
            let conversationJID = Self.canonicalOutgoingConversationJID(for: jid, conversationType: conversationType)
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
                $0.jid = conversationJID
                $0.conversationType = conversationType
                $0.sentDate = Date()
            }
            instance.conversationType = conversationType
            instance.configureOutgoingMessage(body,
                                              legacy: legacyBody,
                                              messageId: originalId,
                                              owner: owner,
                                              opponent: conversationJID,
                                              references: references,
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              isReport: isReport,
                                                                              owner: owner,
                                                                              jid: conversationJID))
            if conversationType == .omemo {
                instance.applyOutgoingAuthoredTime(try Omemo2PayloadCodec.authoredTime())
            }
            instance.groupMentionIntent = groupMentionIntent
            instance.groupMentionSenderRole = groupMentionSenderRole
            instance.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
            if references.contains(where: { [.media, .voice].contains($0.kind) }) {
                instance.createLegacyBody()
            }
            if instance.conversationType == .regular && instance.displayAs == .text {
                instance.state = .sending
            }
            if realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@", owner, instance.messageId).count > 0 {
                instance.messageId = UUID().uuidString
            }
            instance.updatePrimary()
            let prevMessageInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversationJID, owner: self.owner, conversationType: conversationType))?.lastMessage
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
                    instance.markDeleted()
                }
                let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversationJID, owner: self.owner, conversationType: conversationType))
                chat?.draftMessage = nil
            }
            if !isReport {
                publishLocalOutgoingAdmission(
                    primaryID: instance.primary,
                    conversationJID: conversationJID,
                    conversationType: conversationType
                )
            }
            self.processSender(
                item: instance.primary,
                childs: childs,
                groupMentionIntent: groupMentionIntent,
                groupMentionSenderRole: groupMentionSenderRole,
                groupMentionAllCapabilityGranted: groupMentionAllCapabilityGranted
            )
        } catch {
            DDLogDebug("cant store new message item")
            return ""
        }
        return originalId
    }
    
    public func sendSystemMessage(_ body: String, attachments: [MessageReferenceStorageItem], to jid: String, childs: [DDXMLElement] = [], conversationType: ClientSynchronizationManager.ConversationType) {
        guard optOutAllowsOutgoing(to: jid) else { return }
        do {
            let realm = try  WRealm.safe()
            let conversationJID = Self.canonicalOutgoingConversationJID(for: jid, conversationType: conversationType)
            let instance = MessageStorageItem()
            instance.conversationType = conversationType
            instance.configureOutgoingMessage(body,
                                              legacy: body,
                                              messageId: UUID().uuidString,
                                              owner: owner,
                                              opponent: conversationJID,
                                              references: attachments,
                                              inlineForwards: [])

            instance.updatePrimary()
            instance.displayAs = .system
            try realm.write {
                _ = instance.save(commitTransaction: false)
            }
            publishLocalOutgoingAdmission(
                primaryID: instance.primary,
                conversationJID: conversationJID,
                conversationType: conversationType
            )
            self.processSender(item: instance.primary, childs: childs)
        } catch {
            DDLogDebug("cant store new message item")
        }
    }
    
    public func willSendMediaMessage(_ attachments: [MessageReferenceStorageItem], to jid: String, forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType, forwardIntent: ForwardSendIntent = .forward, forwardOptions: ForwardSendOptions = .init()) -> String? {
        willSendMediaMessage(
            attachments,
            to: jid,
            forwarded: forwarded,
            conversationType: conversationType,
            body: "",
            legacyBody: "",
            forwardIntent: forwardIntent,
            forwardOptions: forwardOptions
        )
    }

    public func willSendMediaMessage(
        _ attachments: [MessageReferenceStorageItem],
        to jid: String,
        forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        body: String,
        legacyBody captionLegacyBody: String,
        forwardIntent: ForwardSendIntent = .forward,
        forwardOptions: ForwardSendOptions = .init()
    ) -> String? {
        guard optOutAllowsOutgoing(to: jid) else { return nil }
        if attachments.isEmpty { return nil }
        if !forwarded.isEmpty {
            do {
                return try admitForwarding(body: body, legacyBody: captionLegacyBody, to: jid, forwarded: forwarded,
                    conversationType: conversationType, references: attachments,
                    intent: forwardIntent, options: forwardOptions, requiresUpload: true).uploadPrimary
            } catch {
                DDLogDebug("MessageManager: media forwarding admission rejected")
                return nil
            }
        }
        do {
            let realm = try  WRealm.safe()
            let conversationJID = Self.canonicalOutgoingConversationJID(for: jid, conversationType: conversationType)
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
                                              opponent: conversationJID,
                                              references: attachments,
                                              inlineForwards: prepareForwards(forwarded,
                                                                              primary: instance.primary,
                                                                              isReport: false,
                                                                              owner: owner,
                                                                              jid: conversationJID))
            instance.conversationType = conversationType
            if conversationType == .omemo {
                instance.applyOutgoingAuthoredTime(try Omemo2PayloadCodec.authoredTime())
            }
            instance.state = .uploading
            instance.updatePrimary()
            instance.references.forEach {
                $0.owner = owner
                $0.jid = conversationJID
                $0.messageId = instance.primary
                $0.conversationType = conversationType
            }
           
            try realm.write {
                _ = instance.save(commitTransaction: false)
            }
            let primary = instance.primary
            publishLocalOutgoingAdmission(
                primaryID: primary,
                conversationJID: conversationJID,
                conversationType: conversationType
            )
            return primary
        } catch {
            DDLogDebug("cant store new message item")
        }
        return nil
    }
    
    public final func continueSendMediaMessage(_ primary: String?) {
        guard let primary else { return }
        if let realm = try? WRealm.safe(),
           let row = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
            guard preparedBatchPredecessorsAllowed(for: row, in: realm) else { return }
        }
        uploadMedia(for: primary)
    }

    /// Replaces only the current user's upload projection. Forwarded originals,
    /// cards and existing files stay in the admitted snapshot unchanged.
    private static func finalizePreparedForwardUpload(_ row: MessageStorageItem, in realm: Realm) throws {
        guard row.systemMetadata?["forwardUploadPending"] as? Bool == true,
              let original = try preparedForwardingContent(for: row, in: realm) else { return }
        let ids = row.systemMetadata?["forwardOwnReferencePrimaryIDs"] as? [String] ?? []
        let own = ids.compactMap { id in row.references.first { $0.primary == id } }.map { reference -> MessageReferenceStorageItem in
            let copy = MessageReferenceStorageItem(value: reference)
            copy.temporaryData = reference.temporaryData
            copy.pendingMediaAttachment = reference.pendingMediaAttachment
            return copy
        }
        let previousCount = row.systemMetadata?["forwardOwnReferenceCount"] as? Int ?? 0
        let oldReferences = SCEReceivePolicy.children(of: original, named: "reference", xmlns: "https://xabber.com/protocol/references")
        guard previousCount <= oldReferences.count else { throw ForwardOutgoingAdmissionError.mismatchedPreparedContent }
        var oldOwn = Array(oldReferences.suffix(previousCount))
        for reference in own.reversed() {
            let decoration = [.markup, .mention, .quote].contains(reference.kind)
            guard let index = oldOwn.indices.reversed().first(where: {
                getReferenceType(oldOwn[$0]) == reference.kind.rawValue ||
                    (decoration && oldOwn[$0].attributeStringValue(forName: "type") == "decoration")
            }) else { continue }
            let wire = oldOwn.remove(at: index)
            reference.begin = Int(wire.attributeStringValue(forName: "begin") ?? "") ?? 0
            reference.end = Int(wire.attributeStringValue(forName: "end") ?? "") ?? 0
        }
        oldReferences.suffix(previousCount).forEach { $0.detach() }
        let projection = MessageStorageItem()
        projection.primary = row.primary
        projection.owner = row.owner
        projection.opponent = row.opponent
        projection.legacyBody = row.systemMetadata?["forwardPreparedBaseBody"] as? String ?? row.legacyBody
        projection.systemMetadata = ["forwardPreparedVersion": 1]
        projection.references.append(objectsIn: own)
        projection.createLegacyBody()
        projection.createReferences().forEach { original.addChild($0) }
        SCEReceivePolicy.children(of: original, named: "body", xmlns: "jabber:client").first?.stringValue = projection.legacyBody
        try validatePreparedContentSize(original)
        let finalized = try XMPPMessage(xmlString: original.xmlString)
        let projectedReferences = preparedForwardProjection(finalized, primary: row.primary, jid: row.opponent,
                                                            owner: row.owner, conversationType: row.conversationType,
                                                            ownReferences: own)
        let projectedForwards = parseInlineMessages(finalized, parentId: row.primary, jid: row.opponent, owner: row.owner)
        realm.add(projectedReferences, update: .modified)
        row.legacyBody = projection.legacyBody
        row.references.removeAll()
        row.references.append(objectsIn: projectedReferences)
        row.body = row.normalizedIncomingTextBody(from: finalized)
        row.inlineForwards.removeAll()
        row.inlineForwards.append(objectsIn: projectedForwards)
        row.updateDisplayMode()
        MessageStorageItem.persistPendingMediaAttachments(row.pendingMediaAttachmentsIncludingInlineForwards(),
                                                           forMessagePrimary: row.primary, in: realm)
        row.originalStanza = finalized
        var metadata = row.systemMetadata ?? [:]
        metadata["forwardUploadPending"] = false
        metadata.removeValue(forKey: "forwardPreparedBaseBody")
        row.systemMetadata = metadata
        row.storeStanza(in: realm)
    }

    public func sendMediaMessage(_ attachments: [MessageReferenceStorageItem], to jid: String, forwarded: [String], conversationType: ClientSynchronizationManager.ConversationType, forwardIntent: ForwardSendIntent = .forward, forwardOptions: ForwardSendOptions = .init()) {
        sendMediaMessage(
            attachments,
            to: jid,
            forwarded: forwarded,
            conversationType: conversationType,
            body: "",
            legacyBody: "",
            forwardIntent: forwardIntent,
            forwardOptions: forwardOptions
        )
    }

    public func sendMediaMessage(
        _ attachments: [MessageReferenceStorageItem],
        to jid: String,
        forwarded: [String],
        conversationType: ClientSynchronizationManager.ConversationType,
        body: String,
        legacyBody captionLegacyBody: String,
        forwardIntent: ForwardSendIntent = .forward,
        forwardOptions: ForwardSendOptions = .init()
    ) {
        let primary = willSendMediaMessage(
            attachments,
            to: jid,
            forwarded: forwarded,
            conversationType: conversationType,
            body: body,
            legacyBody: captionLegacyBody,
            forwardIntent: forwardIntent,
            forwardOptions: forwardOptions
        )
        continueSendMediaMessage(primary)
    }

    internal func uploadMedia(for primary: String, retry: Bool = false) {
        MessageMediaUploadTrace.log("message_upload_requested", details: [
            ("owner", self.owner),
            ("messagePrimary", primary),
            ("retry", retry)
        ])
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                guard optOutAllowsOutgoing(to: instance.opponent) else { return }
                guard preparedBatchPredecessorsAllowed(for: instance, in: realm) else { return }
                let opponent = instance.opponent
                let conversationType = instance.conversationType
                let referenceCount = instance.references.count
                try realm.write {
                    instance.state = .uploading
                    instance.messageError = nil
                    instance.messageErrorCode = nil
                    instance.references.forEach {
                        $0.hasError = false
                    }
                }
                LastChats.updateErrorState(for: opponent, owner: self.owner, conversationType: conversationType)
                MessageMediaUploadTrace.log("message_upload_state_set", details: [
                    ("owner", self.owner),
                    ("messagePrimary", primary),
                    ("conversationType", conversationType.rawValue),
                    ("referenceCount", referenceCount),
                    ("state", "uploading")
                ])
            } else {
                MessageMediaUploadTrace.log("message_upload_missing_message", details: [
                    ("owner", self.owner),
                    ("messagePrimary", primary)
                ])
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }

        guard let account = AccountManager.shared.find(for: self.owner) else {
            MessageMediaUploadTrace.log("message_upload_account_missing", details: [
                ("owner", self.owner),
                ("messagePrimary", primary)
            ])
            return
        }

        account.unsafeAction({ user, stream in
            guard let realm = try? WRealm.safe(),
                  let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) else { return }
            guard self.optOutAllowsOutgoing(to: instance.opponent) else {
                self.suspendDeferredUploadForOptOut(primary: primary)
                return
            }
            user.cloudStorage.getFileData(message: primary, successCallback: {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                        guard self.optOutAllowsOutgoing(to: instance.opponent) else {
                            self.suspendDeferredUploadForOptOut(primary: primary)
                            return
                        }
                        let conversationType = instance.conversationType
                        let uploadedReferenceCount = instance.references.filter("isUploaded == true").count
                        let referenceCount = instance.references.count
                        try realm.write {
                            if instance.systemMetadata?["forwardUploadPending"] as? Bool == true {
                                try Self.finalizePreparedForwardUpload(instance, in: realm)
                            } else {
                                instance.createLegacyBody()
                            }
                            instance.state = .sending
                            instance.messageError = nil
                            instance.messageErrorCode = nil
                            instance.references.forEach {
                                $0.hasError = false
                            }
                        }
                        LastChats.updateErrorState(for: instance.opponent, owner: instance.owner, conversationType: instance.conversationType)
                        MessageMediaUploadTrace.log("message_upload_completed", details: [
                            ("owner", instance.owner),
                            ("messagePrimary", primary),
                            ("conversationType", conversationType.rawValue),
                            ("referenceCount", referenceCount),
                            ("uploadedReferenceCount", uploadedReferenceCount),
                            ("nextState", "sending")
                        ])
                    }
                    self.processSender(item: primary, retry: retry)
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            }, failCallback: {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                        let conversationType = instance.conversationType
                        let referenceCount = instance.references.count
                        let failedReferenceCount = instance.references.filter("hasError == true").count
                        let errorCode = instance.messageErrorCode
                        try realm.write {
                            instance.state = .error
                            realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: instance.opponent, owner: instance.owner, conversationType: instance.conversationType))?.hasErrorInChat = true
                        }
                        MessageMediaUploadTrace.log("message_upload_failed", details: [
                            ("owner", instance.owner),
                            ("messagePrimary", primary),
                            ("conversationType", conversationType.rawValue),
                            ("referenceCount", referenceCount),
                            ("failedReferenceCount", failedReferenceCount),
                            ("messageErrorCode", errorCode),
                            ("state", "error")
                        ])
                    }
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            })
        })
    }

    private func optOutAllowsOutgoing(to jid: String) -> Bool {
        OMEMO2OptOutPolicy.allowsMessage(owner: owner, jid: jid, storage: omemo2OptOutStorage)
    }

    internal func suspendDeferredUploadForOptOut(primary: String) {
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
                  item.owner == owner, item.outgoing, item.state == .uploading else { return }
            try realm.write {
                item.state = .error
                item.messageErrorCode = "omemo-opt-out-pending"
                item.messageError = L10n.text("omemo_opt_out_review", fallback: "Review encryption request")
            }
            // Already uploaded references remain usable by an explicit retry.
            LastChats.updateErrorState(for: item.opponent, owner: owner, conversationType: item.conversationType)
        } catch { DDLogDebug("Deferred OMEMO2 upload could not be suspended locally") }
    }
}
