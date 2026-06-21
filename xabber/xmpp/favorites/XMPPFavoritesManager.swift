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
    let originId: String?
    let innerOriginId: String?
    let innerStanzaIds: [String]
    let messageId: String
    let date: Date
    let sentDate: Date
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

        if let reference = outerMessage.element(forName: "reference"),
           let forwarded = reference.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"),
           let rawMessage = forwarded.element(forName: "message"),
           let forwardedDate = deliveryDate(from: outerMessage) {
            storageMessage = XMPPMessage(from: rawMessage)
            innerMessage = storageMessage
            isForwardedSaved = true
            date = forwardedDate
        }

        guard let originalFromJid = storageMessage.from?.bare,
              let originalToJid = storageMessage.to?.bare,
              let sentDate = deliveryDate(from: storageMessage),
              let messageDate = date else {
            return nil
        }

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
                normalizedInput: normalizedInput,
                outerMessage: outerMessage,
                owner: owner
            ),
            originId: getOriginId(outerMessage),
            innerOriginId: innerMessage.flatMap { getOriginId($0) },
            innerStanzaIds: innerMessage.map(stanzaIds(from:)) ?? [],
            messageId: getUniqueMessageId(outerMessage, owner: owner),
            date: messageDate,
            sentDate: sentDate
        )
    }

    private static func normalizedSavedMessage(from message: XMPPMessage) -> NormalizedInput {
        if let archivedMessage = getArchivedMessageContainer(message) {
            return NormalizedInput(
                message: archivedMessage,
                wrapperArchiveId: message.element(forName: "result")?.attributeStringValue(forName: "id")
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
        normalizedInput: NormalizedInput,
        outerMessage: XMPPMessage,
        owner: String
    ) -> String? {
        let outerStanzaId = getStanzaId(outerMessage, owner: owner)
        if outerStanzaId.isNotEmpty {
            return outerStanzaId
        }

        if let wrapperArchiveId = normalizedInput.wrapperArchiveId, wrapperArchiveId.isNotEmpty {
            return wrapperArchiveId
        }

        let wrapperStanzaId = getStanzaId(wrapperMessage, owner: owner)
        return wrapperStanzaId.isNotEmpty ? wrapperStanzaId : nil
    }

    private static func deliveryDate(from message: XMPPMessage) -> Date? {
        getDeliveryDate(message)
    }

    private static func groupDisplayAuthorJid(from message: XMPPMessage) -> String? {
        guard let x = message.element(forName: "x", xmlns: "https://xabber.com/protocol/groups") else {
            return nil
        }

        return x
            .element(forName: "reference")?
            .element(forName: "user")?
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

    internal func buildForwardMessage(for forwardedIds: [String]) -> XMPPMessage? {
        guard let node = self.node else {
            return nil
        }

        let originalId = NanoID.new(8)
        let stanza = XMPPMessage(messageType: .chat, to: XMPPJID(string: node), elementID: originalId, child: nil)
        stanza.addAttribute(withName: "from", stringValue: owner)

        let messageManager = AccountManager.shared.find(for: self.owner)?.messages ?? MessageManager(withOwner: self.owner, activeStream: false)
        let forwardedItems = messageManager.formForwardedMessages(forwardedIds)
        let legacyBody = forwardedItems
            .map(\.body)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if legacyBody.isNotEmpty {
            stanza.addBody(legacyBody)
        }

        forwardedItems.forEach {
            stanza.addChild($0.referenceElement.copy() as! DDXMLElement)
        }

        stanza.addOriginId(originalId)
        return stanza
    }

    @discardableResult
    public func forwardMessages(_ forwardedIds: [String], stream: XMPPStream) -> Bool {
        guard isAvailable(),
              let stanza = buildForwardMessage(for: forwardedIds) else {
            return false
        }

        stream.send(stanza)
        return true
    }
    
    public func receiveSaved(message messageContainer: XMPPMessage) {
        do {
            let realm = try WRealm.safe()
            try receiveSaved(message: messageContainer, realm: realm, commitTransaction: true)
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
    }

    func receiveSaved(
        message messageContainer: XMPPMessage,
        realm: Realm,
        commitTransaction: Bool,
        favoritesNodeOverride: String? = nil
    ) throws {
        guard let envelope = SavedMessageParser.parse(
            messageContainer: messageContainer,
            owner: self.owner,
            favoritesNode: favoritesNodeOverride ?? self.node
        ) else {
            return
        }
        
        let message = envelope.storageMessage
        let savedServiceJid = envelope.serviceJid
        let messageId = envelope.messageId

        var isExist = false
        if let existedInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: messageId, owner: self.owner)) {
            if existedInstance.inlineForwards.isEmpty {
                if let archivedId = envelope.outerArchiveId, archivedId.isNotEmpty, existedInstance.archivedId != archivedId {
                    try performSavedWrite(in: realm, commitTransaction: commitTransaction) {
                        existedInstance.archivedId = archivedId
                        updateSavedLastChatPreviewIfNeeded(
                            realm: realm,
                            savedServiceJid: savedServiceJid,
                            instance: existedInstance
                        )
                    }
                }
                return
            }

            isExist = true
        }

        let instance = MessageStorageItem()
        instance.opponent = savedServiceJid
        instance.owner = self.owner
        instance.primary = MessageStorageItem.genPrimary(messageId: messageId, owner: self.owner)
        instance.outgoing = true
        instance.date = envelope.date
        instance.body = message.body ?? ""
        instance.conversationType = .saved
        instance.messageId = messageId
        instance.legacyBody = message.body ?? ""
        instance.sentDate = envelope.sentDate
        instance.archivedId = envelope.outerArchiveId ?? ""
        instance.previousId = getPreviousId(envelope.outerMessage)
        instance.originalStanza = envelope.outerMessage

        instance.references.append(objectsIn: parseReferences(message, primary: instance.primary, jid: savedServiceJid, owner: self.owner))
        instance.updateDisplayMode()
        instance.references.forEach { $0.messageId = instance.primary }

        if envelope.isForwardedSaved {
            if let groupChatCard = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [GroupChatStorageItem.genPrimary(jid: envelope.displayAuthorJid, owner: self.owner), "saved-forwarded"].prp()) {
                instance.groupchatCard = groupChatCard
            } else {
                let groupChatCard = GroupchatUserStorageItem()
                groupChatCard.owner = self.owner
                groupChatCard.nickname = envelope.displayAuthorJid
                groupChatCard.primary = [GroupChatStorageItem.genPrimary(jid: envelope.displayAuthorJid, owner: self.owner), "saved-forwarded"].prp()
                instance.groupchatCard = groupChatCard
            }
        }

        try performSavedWrite(in: realm, commitTransaction: commitTransaction) {
            if isExist {
                realm.add(instance, update: .all)
            } else {
                realm.add(instance)
            }
            updateSavedLastChatPreviewIfNeeded(
                realm: realm,
                savedServiceJid: savedServiceJid,
                instance: instance
            )
        }
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
        guard let node = self.node else {
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
        
        AccountManager.shared.find(for: self.owner)?.mam.requestArchive(
            stream,
            jid: node,
            isContinues: true,
            conversationType: .saved,
            purpose: .jump,
            start: lastArchivedMessageDate
        )
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
