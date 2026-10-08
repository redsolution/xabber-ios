//
//  XMPPFavoritesManager.swift
//  xabber
//
//  Created by Admin on 14.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import RealmSwift
import CocoaLumberjack

enum XMPPServiceJidsSupport {
    static func ignoredServiceJids(in realm: Realm, accountJids: [String], serviceNodes: [String]? = nil) -> [String] {
        var ignoredJids: [String] = serviceNodes ?? {
            var nodes: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
            nodes.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
            return nodes
        }()
        ignoredJids.append(contentsOf: accountJids)

        var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap(\.abuseAddress))
        ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
        ignoredJids.append(contentsOf: Array(ignoredAbuse))

        if CommonConfigManager.shared.config.support_jid.isNotEmpty {
            ignoredJids.append(CommonConfigManager.shared.config.support_jid)
        }

        return Array(Set(ignoredJids))
    }
}

struct SavedMessageEnvelope {
    let outerMessage: XMPPMessage
    let innerMessage: XMPPMessage?
    let storageMessage: XMPPMessage
    let isForwardedSaved: Bool
    let serviceJid: String
    let displayAuthorJid: String
    let originalFromJid: String
    let originalToJid: String
    let outerArchiveId: String?
    let mamArchiveId: String?
    let originId: String?
    let innerOriginId: String?
    let innerStanzaIds: [String]
    let messageId: String
    let date: Date
    let sentDate: Date
    let originalDate: Date?
}

enum SavedMessagePersistencePolicy {
    static func serviceJid(
        configuredFavoritesJid: String?,
        wrapperMessage: XMPPMessage,
        outerMessage: XMPPMessage,
        originalFromJid: String,
        originalToJid: String,
        owner: String
    ) -> String {
        let fallback = originalFromJid == owner ? originalToJid : originalFromJid
        let candidates = [
            configuredFavoritesJid,
            outerMessage.to?.bare,
            outerMessage.from?.bare,
            wrapperMessage.to?.bare,
            wrapperMessage.from?.bare,
            fallback
        ]

        return candidates
            .compactMap { $0 }
            .first { $0.isNotEmpty && $0 != owner } ?? fallback
    }
}

enum SavedMessageParser {
    private struct NormalizedInput {
        let message: XMPPMessage
        let wrapperArchiveId: String?
    }

    static func parse(messageContainer: XMPPMessage, owner: String, favoritesNode: String?) -> SavedMessageEnvelope? {
        let normalizedInput = normalizedSavedMessage(from: messageContainer)
        let outerMessage = normalizedInput.message
        var storageMessage = outerMessage
        var innerMessage: XMPPMessage? = nil
        var isForwardedSaved = false
        var date = deliveryDate(from: outerMessage)
        var originalForwardedDate: Date? = nil

        let forwardReferences = admittedInlineForwardReferences(in: outerMessage)
        // Rejected overlaps or mixed payloads still belong to the carrier and
        // must not disappear when stripping a presentation-only service wrapper.
        let canonicalForwardReferenceCount = SCEReceivePolicy.children(
            of: outerMessage, named: "reference", xmlns: "https://xabber.com/protocol/references"
        ).filter {
            !SCEReceivePolicy.children(of: $0, named: "forwarded", xmlns: "urn:xmpp:forward:0").isEmpty
        }.count
        let currentText = (outerMessage.body ?? "").xmlEscaping(reverse: false)
            .excludeFromBody(forwardReferences, groupchat: nil)
        // Only the service's single, pure save wrapper is presentation-only.
        // A content carrier with multiple roots or a comment stays intact.
        let configuredService = favoritesNode.flatMap { XMPPJID(string: $0)?.bare }
        let addressedToService = configuredService == nil ||
            [outerMessage.from?.bare, outerMessage.to?.bare].contains(configuredService)
        if addressedToService, canonicalForwardReferenceCount == 1, forwardReferences.count == 1,
           currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let forwardedDate = deliveryDate(from: outerMessage),
           let payload = inlineForwardPayloadMessage(from: forwardReferences[0]) {
            storageMessage = XMPPMessage(from: payload.message.copy() as! DDXMLElement)
            innerMessage = storageMessage
            isForwardedSaved = true
            date = forwardedDate
            originalForwardedDate = payload.date
        }

        guard let originalFromJid = storageMessage.from?.bare,
              let originalToJid = storageMessage.to?.bare,
              let messageDate = date else {
            return nil
        }
        let originalDate = originalForwardedDate ?? deliveryDate(from: storageMessage)
        let sentDate = originalDate ?? messageDate

        let displayAuthorJid = groupDisplayAuthorJid(from: storageMessage) ?? originalFromJid
        let serviceJid = SavedMessagePersistencePolicy.serviceJid(
            configuredFavoritesJid: favoritesNode,
            wrapperMessage: messageContainer,
            outerMessage: outerMessage,
            originalFromJid: originalFromJid,
            originalToJid: originalToJid,
            owner: owner
        )

        return SavedMessageEnvelope(
            outerMessage: outerMessage,
            innerMessage: innerMessage,
            storageMessage: storageMessage,
            isForwardedSaved: isForwardedSaved,
            serviceJid: serviceJid,
            displayAuthorJid: displayAuthorJid,
            originalFromJid: originalFromJid,
            originalToJid: originalToJid,
            outerArchiveId: archiveId(
                wrapperMessage: messageContainer,
                outerMessage: outerMessage,
                owner: owner
            ),
            mamArchiveId: normalizedInput.wrapperArchiveId,
            originId: getOriginId(outerMessage),
            innerOriginId: innerMessage.flatMap { getOriginId($0) },
            innerStanzaIds: innerMessage.map(stanzaIds(from:)) ?? [],
            messageId: getUniqueMessageId(outerMessage, owner: owner),
            date: messageDate,
            sentDate: sentDate,
            originalDate: originalDate
        )
    }

    private static func normalizedSavedMessage(from message: XMPPMessage) -> NormalizedInput {
        if let archivedMessage = getArchivedMessageContainer(message) {
            return NormalizedInput(
                message: archivedMessage,
                wrapperArchiveId: getMAMResultID(message)
            )
        }

        if let carbonMessage = getCarbonCopyMessageContainer(message) {
            return NormalizedInput(message: carbonMessage, wrapperArchiveId: nil)
        }

        if let carbonForwardedMessage = getCarbonForwardedMessageContainer(message) {
            return NormalizedInput(message: carbonForwardedMessage, wrapperArchiveId: nil)
        }

        return NormalizedInput(message: message, wrapperArchiveId: nil)
    }

    private static func archiveId(
        wrapperMessage: XMPPMessage,
        outerMessage: XMPPMessage,
        owner: String
    ) -> String? {
        let outerStanzaId = getStanzaId(outerMessage, owner: owner)
        if outerStanzaId.isNotEmpty {
            return outerStanzaId
        }

        let wrapperStanzaId = getStanzaId(wrapperMessage, owner: owner)
        return wrapperStanzaId.isNotEmpty ? wrapperStanzaId : nil
    }

    private static func deliveryDate(from message: XMPPMessage) -> Date? {
        getDeliveryDate(message)
    }

    private static func deliveryDate(fromForwarded forwarded: DDXMLElement) -> Date? {
        if let dateString = forwarded.element(forName: "time")?.attributeStringValue(forName: "stamp"),
           let date = dateString.xmppDate {
            return date
        }
        if let dateString = forwarded.element(forName: "delay", xmlns: "urn:xmpp:delay")?.attributeStringValue(forName: "stamp"),
           let date = dateString.xmppDate {
            return date
        }
        if let dateString = forwarded.element(forName: "delay")?.attributeStringValue(forName: "stamp"),
           let date = dateString.xmppDate {
            return date
        }
        return nil
    }

    private static func groupDisplayAuthorJid(from message: XMPPMessage) -> String? {
        groupchatUserElement(from: message)?
            .element(forName: "jid")?
            .stringValue
    }

    private static func stanzaIds(from message: XMPPMessage) -> [String] {
        (message.elements(forName: "stanza-id") + message.elements(forName: "archived"))
            .compactMap { $0.attributeStringValue(forName: "id") }
            .filter(\.isNotEmpty)
    }
}

class XMPPFavoritesManager: AbstractXMPPManager {
    enum ManagerErrorType: Error {
        case notAvailable
    }
    
    static let xmlns: String = "urn:xabber:favorites:0"
    
    open var node: String? = nil
    
    override func namespaces() -> [String] {
        return [
            XMPPFavoritesManager.xmlns
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return XMPPFavoritesManager.xmlns
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        loadLocal()
    }
    
    private func loadLocal() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: XMPPFavoritesManagerStorageItem.self, forPrimaryKey: XMPPFavoritesManagerStorageItem.genPrimary(owner: self.owner)) {
                self.node = instance.node
            }
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func resolvedSavedServiceJid(from messageContainer: XMPPMessage, fallback: String) -> String {
        let candidates = [
            self.node,
            AccountManager.shared.find(for: self.owner)?.favorites.node,
            messageContainer.to?.bare,
            messageContainer.from?.bare,
            fallback
        ]

        return candidates
            .compactMap { $0 }
            .first { $0.isNotEmpty && $0 != self.owner } ?? fallback
    }
    
    public final func configure(for jid: String) {
        self.node = jid
        
        do {
            try createXMPPFavoritesManagerStorageItem()
            try createRosterStorageItem()
            try createLastChatsStorageItem()
            try repairSavedMessagesStorageIdentity(favoritesNode: jid)
            
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.favorites.update(stream)
        })
    }

    static func supportsService(_ query: DDXMLElement) -> Bool {
        guard let identity = query.element(forName: "identity"),
              identity.attributeStringValue(forName: "type") == "archive",
              identity.attributeStringValue(forName: "category") == "component" else {
            return false
        }

        return query
            .elements(forName: "feature")
            .contains(where: { $0.attributeStringValue(forName: "var") == XMPPFavoritesManager.xmlns })
    }
    
    func createXMPPFavoritesManagerStorageItem() throws {
        guard let node = self.node else { throw ManagerErrorType.notAvailable }
        
        let realm = try WRealm.safe()
        
        let instance = XMPPFavoritesManagerStorageItem()
        instance.owner = self.owner
        instance.primary = XMPPFavoritesManagerStorageItem.genPrimary(owner: self.owner)
        instance.node = node
        
        try realm.write {
            realm.add(instance, update: .modified)
        }
    }
    
    func createRosterStorageItem() throws {
        guard let node = self.node else { throw ManagerErrorType.notAvailable }
        
        let realm = try WRealm.safe()
        
        let rosterItem = RosterStorageItem()
        rosterItem.owner = owner
        rosterItem.jid = node
        rosterItem.primary = RosterStorageItem.genPrimary(jid: node, owner: owner)
        rosterItem.username = "Saved messages"
        
//        try realm.write {
//            realm.add(rosterItem)
//        }
    }
    
    func createLastChatsStorageItem(commitTransaction: Bool = true) throws {
        guard let node = self.node else { throw ManagerErrorType.notAvailable }
        
        let realm = try WRealm.safe()
        
        if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: node, owner: self.owner, conversationType: .saved)) != nil {
            return
        }
        
        let instance = LastChatsStorageItem()
        instance.owner = self.owner
        instance.jid = node
        instance.isSynced = false
        instance.conversationType = .saved
        instance.primary = LastChatsStorageItem.genPrimary(jid: node, owner: self.owner, conversationType: .saved)
        
        let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: node, owner: self.owner))
        
        instance.rosterItem = rosterItem
        
        if commitTransaction {
            try realm.write {
                realm.add(instance)
            }
        } else {
            realm.add(instance)
        }
    }

    func repairSavedMessagesStorageIdentity(favoritesNode: String) throws {
        guard favoritesNode.isNotEmpty else { return }

        let realm = try WRealm.safe()
        let savedType = ClientSynchronizationManager.ConversationType.saved.rawValue
        let messagesToRepair = Array(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@ AND conversationType_ == %@ AND opponent != %@", self.owner, savedType, favoritesNode)
        )

        try realm.write {
            messagesToRepair.forEach { message in
                message.opponent = favoritesNode
                message.references.forEach { repairSavedReference($0, favoritesNode: favoritesNode) }
                message.inlineForwards.forEach { repairSavedInlineForward($0, favoritesNode: favoritesNode) }
            }

            let chat = savedLastChat(in: realm, favoritesNode: favoritesNode)
            let latestMessage = realm.objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND conversationType_ == %@ AND isDeleted == false", self.owner, favoritesNode, savedType)
                .sorted(byKeyPath: "date", ascending: false)
                .first

            chat.lastMessage = latestMessage
            chat.messageDate = latestMessage?.date ?? Date(timeIntervalSince1970: 0)
        }
    }

    private func savedLastChat(in realm: Realm, favoritesNode: String) -> LastChatsStorageItem {
        let primary = LastChatsStorageItem.genPrimary(jid: favoritesNode, owner: self.owner, conversationType: .saved)
        if let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) {
            return chat
        }

        let chat = LastChatsStorageItem()
        chat.owner = self.owner
        chat.jid = favoritesNode
        chat.isSynced = false
        chat.conversationType = .saved
        chat.primary = primary
        chat.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: favoritesNode, owner: self.owner))
        realm.add(chat)
        return chat
    }

    private func repairSavedReference(_ reference: MessageReferenceStorageItem, favoritesNode: String) {
        reference.jid = favoritesNode
        reference.conversationType = .saved
    }

    private func repairSavedInlineForward(_ inlineForward: MessageForwardsInlineStorageItem, favoritesNode: String) {
        inlineForward.jid = favoritesNode
        inlineForward.references.forEach { repairSavedReference($0, favoritesNode: favoritesNode) }
        inlineForward.subforwards.forEach { repairSavedInlineForward($0, favoritesNode: favoritesNode) }
    }
    
    public final func isAvailable() -> Bool {
        guard self.node != nil else {
            return false
        }
        
        return true
    }

    internal func buildForwardMessages(for forwardedIds: [String]) throws -> [XMPPMessage] {
        guard let node, let destination = XMPPJID(string: node), destination.resource == nil else {
            throw ForwardPreparationError.missingSource("saved-service")
        }
        let realm = try WRealm.safe()
        let sources = try ForwardSourceLoader.load(ids: forwardedIds, owner: owner, realm: realm)
        let units = try ForwardSendPlanner.plan(sources: sources, comment: "")
        guard !units.isEmpty else { throw ForwardPreparationError.missingSource("saved-selection") }
        return units.map { unit in
            let id = UUID().uuidString
            let stanza = XMPPMessage(messageType: .chat, to: destination, elementID: id, child: nil)
            stanza.setXmlns("jabber:client")
            stanza.addAttribute(withName: "from", stringValue: owner)
            stanza.addOriginId(id)
            unit.appendContent(to: stanza)
            return stanza
        }
    }

    internal func buildForwardMessage(for forwardedIds: [String]) -> XMPPMessage? {
        guard let messages = try? buildForwardMessages(for: forwardedIds), messages.count == 1 else { return nil }
        return messages[0]
    }

    @discardableResult
    public func forwardMessages(_ forwardedIds: [String], stream: XMPPStream) -> Bool {
        guard isAvailable(), let stanzas = try? buildForwardMessages(for: forwardedIds) else { return false }
        // Prepare every carrier before the first transport handoff.
        stanzas.forEach(stream.send)
        return true
    }

    public func receiveSaved(message messageContainer: XMPPMessage, encryption: MessageEncryptionProvenance = .plaintext,
                             authenticatedSender: OMEMOAuthenticatedSender? = nil) {
        do {
            let realm = try WRealm.safe()
            try receiveSaved(message: messageContainer, realm: realm, commitTransaction: true,
                encryption: encryption, authenticatedSender: authenticatedSender)
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
    }

    @discardableResult
    func receiveSaved(
        message messageContainer: XMPPMessage,
        realm: Realm,
        commitTransaction: Bool,
        favoritesNodeOverride: String? = nil,
        encryption: MessageEncryptionProvenance = .plaintext,
        authenticatedSender: OMEMOAuthenticatedSender? = nil
    ) throws -> MessageStorageItem? {
        let prepared: OMEMOReceiveResult = encryption.isAuthenticated
            ? .verified(XMPPMessage(from: SCEReceivePolicy.droppingUnprotectedSCE(messageContainer)), encryption, sender: authenticatedSender)
            : OmemoManager.prepareUnverifiedIncoming(messageContainer)
        guard let messageContainer = prepared.message else { return nil }
        var incomingEncryption = encryption.isEncrypted ? encryption : prepared.provenance
        guard let envelope = SavedMessageParser.parse(
            messageContainer: messageContainer,
            owner: self.owner,
            favoritesNode: favoritesNodeOverride ?? self.node
        ) else {
            return nil
        }
        
        let message = envelope.storageMessage
        if SCEReceivePolicy.hasOMEMO2(message), !incomingEncryption.isAuthenticated {
            // A plaintext saved-forward can contain an encrypted inner stanza.
            // Its outer reference is not evidence that the inner was decrypted.
            let sanitized = SCEReceivePolicy.sanitized(message)
            for child in message.children ?? [] { child.detach() }
            for child in sanitized.children ?? [] { message.addChild(child.copy() as! DDXMLNode) }
            if !incomingEncryption.isEncrypted { incomingEncryption = .unverifiedOMEMO }
        }
        let savedServiceJid = envelope.serviceJid
        let messageId = envelope.messageId

        var isExist = false
        if let existedInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: messageId, owner: self.owner)) {
            if existedInstance.inlineForwards.isEmpty {
                let persistedStanza = realm.object(ofType: MessageStanzaStorageItem.self,
                    forPrimaryKey: "\(existedInstance.primary)_stanza")
                let storedXML = existedInstance.originalStanza?.xmlString ??
                    (persistedStanza?.owner == self.owner ? persistedStanza?.stanza : nil)
                let content = MessageStorageItem()
                content.legacyBody = message.body ?? ""
                content.body = content.legacyBody.xmlEscaping(reverse: false).excludeFromBody(
                    SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references"), groupchat: nil)
                content.references.append(objectsIn: parseReferences(message,
                    primary: existedInstance.primary, jid: savedServiceJid, owner: self.owner))
                appendSavedContactData(envelope, to: content.references, primary: existedInstance.primary)
                let isExactStoredStanza = existedInstance.owner == self.owner &&
                    existedInstance.opponent == savedServiceJid && existedInstance.conversationType == .saved &&
                    existedInstance.hasSameIncomingContent(as: content) && storedXML == message.xmlString
                try performSavedWrite(in: realm, commitTransaction: commitTransaction) {
                    existedInstance.isSavedForward = envelope.isForwardedSaved
                    existedInstance.savedForwardAuthorJid = envelope.isForwardedSaved
                        ? envelope.displayAuthorJid
                        : ""
                    if envelope.isForwardedSaved && envelope.originalDate == nil {
                        var metadata = existedInstance.systemMetadata ?? [:]
                        metadata["forwardOriginalDateUnknown"] = true
                        existedInstance.systemMetadata = metadata
                    }
                    if !existedInstance.references.contains(where: { $0.kind == .forwardContactData }) {
                        appendSavedContactData(envelope, to: existedInstance.references, primary: existedInstance.primary)
                    }
                    if let archivedId = envelope.outerArchiveId, archivedId.isNotEmpty, existedInstance.archivedId != archivedId {
                        existedInstance.archivedId = archivedId
                        updateSavedLastChatPreviewIfNeeded(
                            realm: realm,
                            savedServiceJid: savedServiceJid,
                            instance: existedInstance
                        )
                    }
                    if let mamArchiveId = envelope.mamArchiveId,
                       mamArchiveId.isNotEmpty,
                       existedInstance.mamArchiveId != mamArchiveId {
                        existedInstance.mamArchiveId = mamArchiveId
                    }
                    storeSavedForwardingStanza(for: existedInstance, envelope: envelope,
                        encryption: isExactStoredStanza ? incomingEncryption : .plaintext, in: realm)
                    // A proof for a saved outer stanza does not authenticate a
                    // nested saved-forward's sender or unrelated cached body.
                    if isExactStoredStanza {
                        existedInstance.incomingEncryption = incomingEncryption
                        if !envelope.isForwardedSaved, prepared.authenticatedSender != nil {
                            existedInstance.originalStanza = message
                        }
                        existedInstance.applyIncomingSenderTrust(
                            envelope.isForwardedSaved ? nil : prepared.authenticatedSender,
                            encryption: incomingEncryption)
                    }
                }
                return existedInstance
            }

            isExist = true
        }

        let instance = MessageStorageItem()
        instance.opponent = savedServiceJid
        instance.owner = self.owner
        instance.primary = MessageStorageItem.genPrimary(messageId: messageId, owner: self.owner)
        instance.outgoing = true
        instance.date = envelope.date
        instance.body = (message.body ?? "").xmlEscaping(reverse: false).excludeFromBody(
            SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references"), groupchat: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        instance.conversationType = .saved
        instance.incomingEncryption = incomingEncryption
        if incomingEncryption.isEncrypted && !incomingEncryption.isAuthenticated {
            instance.messageError = "omemo"
        }
        instance.messageId = messageId
        instance.legacyBody = message.body ?? ""
        instance.sentDate = envelope.sentDate
        if envelope.isForwardedSaved && envelope.originalDate == nil {
            instance.systemMetadata = ["forwardOriginalDateUnknown": true]
        }
        instance.archivedId = envelope.outerArchiveId ?? ""
        instance.mamArchiveId = envelope.mamArchiveId ?? ""
        instance.previousId = getPreviousId(envelope.outerMessage)
        instance.originalStanza = envelope.isForwardedSaved ? envelope.storageMessage : envelope.outerMessage
        instance.isSavedForward = envelope.isForwardedSaved
        instance.savedForwardAuthorJid = envelope.isForwardedSaved
            ? envelope.displayAuthorJid
            : ""
        instance.applyIncomingSenderTrust(envelope.isForwardedSaved ? nil : prepared.authenticatedSender,
            encryption: incomingEncryption)

        instance.references.append(objectsIn: parseReferences(message, primary: instance.primary, jid: savedServiceJid, owner: self.owner))
        appendSavedContactData(envelope, to: instance.references, primary: instance.primary)
        instance.inlineForwards.append(objectsIn: parseInlineMessages(message, parentId: instance.primary, jid: savedServiceJid, owner: self.owner))
        instance.updateDisplayMode()
        instance.references.forEach { $0.messageId = instance.primary }
        let pendingMediaAttachments = instance
            .pendingMediaAttachmentsIncludingInlineForwards()

        try performSavedWrite(in: realm, commitTransaction: commitTransaction) {
            realm.add(instance, update: isExist ? .all : .modified)
            MessageStorageItem.persistPendingMediaAttachments(
                pendingMediaAttachments,
                forMessagePrimary: instance.primary,
                in: realm
            )
            storeSavedForwardingStanza(for: instance, envelope: envelope, encryption: incomingEncryption, in: realm)
            updateSavedLastChatPreviewIfNeeded(
                realm: realm,
                savedServiceJid: savedServiceJid,
                instance: instance
            )
        }
        return instance
    }

    private func appendSavedContactData(
        _ envelope: SavedMessageEnvelope,
        to references: List<MessageReferenceStorageItem>, primary: String
    ) {
        guard envelope.isForwardedSaved,
              let from = envelope.storageMessage.from?.bare,
              let card = ForwardContactDataCodec.matchingCard(for: from, cards: ForwardContactDataCodec.cards(in: envelope.outerMessage)) else { return }
        let reference = MessageReferenceStorageItem()
        reference.kind = .forwardContactData
        reference.owner = owner
        reference.jid = envelope.serviceJid
        reference.messageId = primary
        reference.conversationType = .saved
        reference.metadata = ForwardContactDataCodec.metadata(for: card)
        references.append(reference)
    }

    private func storeSavedForwardingStanza(
        for instance: MessageStorageItem,
        envelope: SavedMessageEnvelope,
        encryption: MessageEncryptionProvenance,
        in realm: Realm
    ) {
        guard instance.owner == owner else { return }
        let stanza = envelope.isForwardedSaved ? envelope.storageMessage : envelope.outerMessage
        let timestamp = envelope.isForwardedSaved ? envelope.sentDate : envelope.date
        // The managed cache may retain transient provenance from an earlier
        // arrival. Bind this store only to the actual incoming direct stanza;
        // an unwrapped saved forward never inherits its outer's authority.
        let source = MessageStorageItem()
        source.primary = instance.primary
        source.owner = instance.owner
        source.messageId = instance.messageId
        source.date = timestamp
        source.originalStanza = stanza
        source.isSavedForward = envelope.isForwardedSaved
        source.incomingEncryption = envelope.isForwardedSaved ? .plaintext : encryption
        source.storeStanza(in: realm)
    }

    private func performSavedWrite(in realm: Realm, commitTransaction: Bool, _ block: () -> Void) throws {
        if commitTransaction && !realm.isInWriteTransaction {
            try realm.write {
                block()
            }
        } else {
            block()
        }
    }

    private func updateSavedLastChatPreviewIfNeeded(
        realm: Realm,
        savedServiceJid: String,
        instance: MessageStorageItem
    ) {
        if let chatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: savedServiceJid, owner: self.owner, conversationType: .saved)) {
            if chatInstance.lastMessage == nil {
                updateSavedLastChatPreview(chatInstance, instance: instance)
            } else if let lastMessage = chatInstance.lastMessage,
                      lastMessage.date < instance.date {
                updateSavedLastChatPreview(chatInstance, instance: instance)
            }
        }
    }

    private func updateSavedLastChatPreview(_ chatInstance: LastChatsStorageItem, instance: MessageStorageItem) {
        chatInstance.lastMessage = instance
        chatInstance.lastMessageId = instance.messageId
        chatInstance.messageDate = instance.date
    }
    
    public func update(_ stream: XMPPStream) {
        guard isAvailable() else {
            return
        }
        
        updateArchive(stream)
    }
    
    func updateArchive(_ stream: XMPPStream) {
        guard let node = self.node,
              let account = AccountManager.shared.find(for: self.owner) else {
            return
        }
        
        var lastArchivedMessageDate: Date? = nil
        do {
            let realm = try WRealm.safe()
            lastArchivedMessageDate = realm
                .objects(MessageStorageItem.self)
                .filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", node, self.owner, ClientSynchronizationManager.ConversationType.saved.rawValue)
                .sorted(byKeyPath: "date", ascending: false)
                .first?
                .date
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
        
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .background,
            resource: .mamArchive,
            deduplicationKey: "archive.saved-refresh.\(self.owner).\(node)",
            requiresAuthenticatedStream: true
        ) { user, scheduledStream, finish in
            user.mam.requestArchive(
                scheduledStream,
                jid: node,
                isContinues: true,
                conversationType: .saved,
                purpose: .jump,
                start: lastArchivedMessageDate,
                callback: finish,
                requestCallbacks: .init(onFailure: { _ in finish() })
            )
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let managerStorageItem = realm.objects(XMPPFavoritesManagerStorageItem.self).filter("owner == %@", owner)
            
            if commitTransaction {
                try realm.write {
                    realm.delete(managerStorageItem)
                }
            } else {
                realm.delete(managerStorageItem)
            }
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
    }
    
}
