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
    
    public final func configure(for jid: String) {
        self.node = jid
        
        do {
            try createXMPPFavoritesManagerStorageItem()
            try createRosterStorageItem()
            try createLastChatsStorageItem()
            
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
        var message = XMPPMessage(from: messageContainer)
        var date: Date? = nil
        var isForwarded: Bool = false
        
        var from: String? = nil
        
        if let reference = messageContainer.element(forName: "reference"),
           let forwarded = reference.element(forName: "forwarded"),
           let rawMessage = forwarded.element(forName: "message"),
           let dateForward = messageContainer.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate {
            message = XMPPMessage(from: rawMessage)
            date = dateForward
            
            if let x = message.element(forName: "x"),
               x.xmlns == AccountManager.shared.find(for: self.owner)?.groupchats.getPrimaryNamespace() {
                from = x.element(forName: "reference")?.element(forName: "user")?.element(forName: "jid")?.stringValue
            }
            
            isForwarded = true
        }
        
        if from == nil {
            from = message.from?.bare
        }
        
        guard let from = from,
              let to = message.to?.bare,
              let sentDate = message.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate else {
            return
        }
        
        let isOutgoing = from == self.owner
        let messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        
        do {
            let realm = try WRealm.safe()
            
            var isExist = false
            if let existedInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: messageId, owner: self.owner)) {
                if existedInstance.inlineForwards.isEmpty {
                    return
                }
                
                isExist = true
            }
            
            let instance = MessageStorageItem()
            instance.opponent = isOutgoing ? to : from
            instance.owner = self.owner
            instance.primary = MessageStorageItem.genPrimary(messageId: messageId, owner: self.owner)
            instance.outgoing = true
            instance.date = date ?? sentDate
            instance.body = message.body ?? ""
            instance.conversationType = .saved
            instance.messageId = messageId
            instance.legacyBody = message.body ?? ""
            instance.sentDate = sentDate
            
            instance.references.append(objectsIn: parseReferences(message, primary: instance.primary, jid: instance.opponent, owner: self.owner))
            instance.updateDisplayMode()
            instance.references.forEach { $0.messageId = instance.primary }
            
            if isForwarded {
                if let groupChatCard = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [GroupChatStorageItem.genPrimary(jid: from, owner: self.owner), "saved-forwarded"].prp()) {
                    instance.groupchatCard = groupChatCard
                } else {
                    let groupChatCard = GroupchatUserStorageItem()
                    groupChatCard.owner = self.owner
                    groupChatCard.nickname = from
                    groupChatCard.primary = [GroupChatStorageItem.genPrimary(jid: from, owner: self.owner), "saved-forwarded"].prp()
                    instance.groupchatCard = groupChatCard
                }
            }
            
            try realm.write {
                if isExist {
                    realm.add(instance, update: .all)
                } else {
                    realm.add(instance)
                }
            }
            
            if let chatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: AccountManager.shared.find(for: self.owner)?.favorites.node ?? "", owner: self.owner, conversationType: .saved)) {
                if chatInstance.lastMessage == nil {
                    try realm.write {
                        chatInstance.lastMessage = instance
                        chatInstance.messageDate = instance.date
                    }
                    
                } else if let lastMessage = chatInstance.lastMessage,
                   lastMessage.date < instance.date {
                    try realm.write {
                        chatInstance.lastMessage = instance
                        chatInstance.messageDate = instance.date
                    }
                    
                }
            }
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
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
