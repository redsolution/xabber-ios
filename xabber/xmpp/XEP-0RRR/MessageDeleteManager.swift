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
import CryptoSwift

class MessageDeleteManager: AbstractXMPPManager {
    
    internal class Item: Hashable {
        
        static func == (lhs: Item, rhs: Item) -> Bool {
            return lhs.messageId == rhs.messageId && lhs.iqId == rhs.iqId
        }
        
        enum Kind {
            case retract
            case rewrite
        }
        
        var messagePrimary: String
        var kind: Kind
        var messageId: String
        var iqId: String
        let callback: ((String?, Bool) -> Void)?
        
        init(_ messagePrimary: String, kind: Kind, messageId: String, iqId: String, callback: ((String?, Bool) -> Void)?) {
            self.messagePrimary = messagePrimary
            self.kind = kind
            self.messageId = messageId
            self.iqId = iqId
            self.callback = callback
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(messageId)
            hasher.combine(iqId)
        }
    }
    
    open var isAvailable: Bool = false
    open var version: String = ""
    
    internal var isEnabled: Bool = false
    internal var itemsQuery: SynchronizedArray<Item> = SynchronizedArray<Item>()
    
    override func namespaces() -> [String] {
        return [getPrimaryNamespace()]
    }
    
    static public let namespace = "https://xabber.com/protocol/rewrite"
    
    override func getPrimaryNamespace() -> String {
        return MessageDeleteManager.namespace
    }
    
    static public func availability(_ owner: String) -> Bool {
        guard let node = SettingManager
            .shared
            .getKey(for: owner, scope: SettingManager.KeyScope.messageDeleteRewrite, key: "node"),
            node == MessageDeleteManager.namespace else {
                return false
        }
        return true
    }
    
    open func checkAvailability() {
        isAvailable = MessageDeleteManager.availability(owner)
    }
    
    internal func updateVersion(_ version: String) {
        self.version = version
        SettingManager.shared.saveItem(for: owner, scope: .messageDeleteRewrite, key: "version", value: version)
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        checkAvailability()
        version = SettingManager.shared.getKey(for: owner, scope: .messageDeleteRewrite, key: "version") ?? ""
        if version.isEmpty {
            SettingManager.shared.saveItem(for: owner, scope: .messageDeleteRewrite, key: "version", value: "")
        }
    }
    
    func read(headline message: XMPPMessage) -> Bool {
        switch true {
        case readRetractAllNotify(message): return true
        case readRetractUserNotify(message): return true
        case readRetractMessageNotify(message): return true
        case readRewriteNotify(message): return true
        default: return false
        }
    }
    
    internal func readRetractAllNotify(_ message: XMPPMessage) -> Bool {
        guard let retract = message.element(forName: "retract-all", xmlns: [getPrimaryNamespace(), "notify"].joined(separator: "#")),
              let jid = retract.attributeStringValue(forName: "conversation"),
              let conversationTypeRaw = retract.attributeStringValue(forName: "type"),
              let conversationType = ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type),
              let version = retract.attributeStringValue(forName: "version") else {
                return false
        }
        updateVersion(version)
        do {
            let realm = try  WRealm.safe()
            let messages = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND messageType != %@ AND conversationType_ == %@", owner, jid, MessageStorageItem.MessageDisplayType.initial.rawValue, conversationTypeRaw)
            let instance = realm
                .object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: self.owner,
                        conversationType: conversationType
                    )
                )
            let references = realm.objects(MessageReferenceStorageItem.self).filter("jid == %@ AND conversationType_ == %@", jid, conversationTypeRaw)
            if messages.isEmpty { return false }
            try realm.write {
                if !(instance?.isInvalidated ?? true) {
                    instance?.lastMessage = nil
                    instance?.retractVersion = version
//                    instance?.isSynced = false
                }
                realm.delete(messages)
                realm.delete(references)
            }
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    internal func readRetractUserNotify(_ message: XMPPMessage) -> Bool {
        guard let retract = message.element(forName: "retract-user"),
            retract.xmlns() == [getPrimaryNamespace(), "notify"].joined(separator: "#"),
            retract.attributeStringValue(forName: "conversation") != nil,
            let version = retract.attributeStringValue(forName: "version") else {
                return false
        }
        
        updateVersion(version)
        return true
    }
    
    internal func readRetractMessageNotify(_ message: XMPPMessage) -> Bool {
        guard let retract = message.element(forName: "retract-message"),
              let conversation = retract.attributeStringValue(forName: "conversation"),
              let conversationTypeRaw = retract.attributeStringValue(forName: "type"),
              let conversationType = ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type),
              let stanzaId = retract.attributeStringValue(forName: "id"),
              let version = retract.attributeStringValue(forName: "version") else {
                return false
        }
        updateVersion(version)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND archivedId == %@ AND conversationType_ == %@", owner, conversation, stanzaId, conversationTypeRaw)
                .first {
                try realm.write {
                    realm.delete(instance)
                    if let lastChat = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: conversation,
                            owner: self.owner,
                            conversationType: conversationType
                        )
                    ) {
                        let lastMessage = realm
                            .objects(MessageStorageItem.self)
                            .filter(
                                "owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@",
                                self.owner,
                                conversation,
                                conversationTypeRaw
                            )
                            .sorted(byKeyPath: "date", ascending: false)
                            .first
                        lastChat.lastMessage = lastMessage
                        if let date = lastMessage?.date {
                            lastChat.messageDate = date
                        }
//                        lastChat.isSynced = false
                        lastChat.retractVersion = version
                    }
                }
                LastChats.updateErrorState(for: conversation, owner: self.owner, conversationType: conversationType)
            } else {
                if (AccountManager.shared.find(for: self.owner)?.messages.messagesQueue.value.contains(where: {
                    return getStanzaId($0.message, owner: self.owner) == stanzaId
                }) ?? false) {
                    AccountManager.shared.find(for: self.owner)?.messages.storeMessagesNow()
                    return readRetractMessageNotify(message)
                }
            }
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    internal func readRewriteNotify(_ message: XMPPMessage) -> Bool {
        guard let replace = message.element(forName: "replace"),
              let version = replace.attributeStringValue(forName: "version"),
              let conversation = replace.attributeStringValue(forName: "conversation"),
              let conversationTypeRaw = replace.attributeStringValue(forName: "type"),
              let conversationType = ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type),
              let messageContainer = replace.element(forName: "message"),
              let stanzaId = replace.attributeStringValue(forName: "id"),
              let editDate = messageContainer.element(forName: "replaced")?.attributeStringValue(forName: "stamp")?.xmppDate else {
                return false
        }
        updateVersion(version)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND archivedId == %@", owner, conversation, stanzaId).first {
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.editMessage(XMPPMessage(from: messageContainer), editDate: editDate)
                    realm
                        .object(ofType: LastChatsStorageItem.self,
                                forPrimaryKey: LastChatsStorageItem.genPrimary(
                                    jid: conversation,
                                    owner: self.owner,
                                    conversationType: conversationType
                                )
                        )?
                        .retractVersion = version
                }
            } else {
                if (AccountManager.shared.find(for: self.owner)?.messages.messagesQueue.value.contains(where: {
                    return getStanzaId($0.message, owner: self.owner) == stanzaId
                }) ?? false) {
                    AccountManager.shared.find(for: self.owner)?.messages.storeMessagesNow()
                    return readRewriteNotify(message)
                }
            }
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readEnabled(iq): return true
        case readError(iq): return true
        case readSuccess(iq): return true
        default: return false
        }
    }
    
    internal func readError(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let error = iq.element(forName: "error") else {
                return false
        }
        var deleteAnyway: Bool = false
        var errorMessage: String? = nil
        if error.element(forName: "not-allowed") != nil {
            errorMessage = "not allowed".localizeString(id: "not_allowed_error", arguments: [])
        }
        else if error.element(forName: "not-acceptable") != nil {
            errorMessage = "not acceptable".localizeString(id: "not_acceptable_error", arguments: [])
        }
        else if error.element(forName: "item-not-found") != nil {
            errorMessage = "message not found".localizeString(id: "message_not_found_error", arguments: [])
            deleteAnyway = true
        }
        if let errorText = error.element(forName: "text")?.stringValue {
            errorMessage = errorText
        }
        queryIds.remove(elementId)
        if let item = itemsQuery.first(where: { $0.iqId == elementId }) {
            if deleteAnyway {
                item.callback?(nil, true)
            } else {
                item.callback?(["Can`t delete message:".localizeString(id: "cant_delete_message_first_part", arguments: []), errorMessage ?? "unexpected error".localizeString(id: "unexpected_error", arguments: [])].joined(separator: " "), false)
            }
            if item.messagePrimary.isNotEmpty {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.messagePrimary) {
                        let jid = instance.opponent
                        let conversationType = instance.conversationType
                        try realm.write {
                            if deleteAnyway {
                                realm.delete(instance)
                            } else {
                                instance.messageError = errorMessage
                                instance.isDeleted = false
                            }
                        }
                        LastChats.updateErrorState(for: jid, owner: self.owner, conversationType: conversationType)
                    }
                    
                } catch {
                    DDLogDebug("MessageDeleteManager: \(#function). \(error.localizedDescription)")
                }
            }
            itemsQuery.remove(item)
        }
        return true
    }
    
    private final func readEnabled(_ iq: XMPPIQ) -> Bool {
        guard let query = iq.element(forName: "query", xmlns: getPrimaryNamespace()),
              let version = query.attributeStringValue(forName: "version") else {
            return false
        }
        updateVersion(version)
        return true
    }
    
    internal func readSuccess(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            iq.elements(forName: "error").isEmpty else {
                return false
        }
//        queryIds.remove(elementId)
        if let item = itemsQuery.first(where: { $0.iqId == elementId }) {
            item.callback?(nil, true)
            itemsQuery.remove(item)
        }
        return true
    }
    
    open func deleteMessage(_ xmppStream: XMPPStream, primary: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, symmetric: Bool, callback: ((String?, Bool) -> Void)?) {
        func send(_ messageId: String, elementId: String, to archiveJid: XMPPJID?) {
            let retract = DDXMLElement(name: "retract-message", xmlns: getPrimaryNamespace())
            retract.addAttribute(withName: "symmetric", stringValue: symmetric ? "true" : "false" )
            retract.addAttribute(withName: "id", stringValue: messageId)
            retract.addAttribute(withName: "type", stringValue: conversationType.rawValue)
            xmppStream.send(XMPPIQ(iqType: .set, to: archiveJid, elementID: elementId, child: retract))
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let elementId = "RRR: \(NanoID.new(8))"
                send(instance.archivedId, elementId: elementId, to: jid.isEmpty ? nil : XMPPJID(string: jid))
                queryIds.insert(elementId)
                guard instance.archivedId.isNotEmpty else {
                    callback?("Can`t delete message: unexpected error".localizeString(id: "cant_delete_message_error", arguments: []), false)
                    return
                }
                itemsQuery.insert(Item(primary, kind: .retract, messageId: instance.archivedId, iqId: elementId, callback: callback))
            }
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). Cant get message for key \(primary). \(error.localizedDescription)")
        }
        
    }
    
    open func deleteAllMessages(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, callback: ((String?, Bool) -> Void)?) {
        let retract = DDXMLElement(name: "retract-all", xmlns: getPrimaryNamespace())
        retract.addAttribute(withName: "conversation", stringValue: jid)
        retract.addAttribute(withName: "symmetric", boolValue: false)
        retract.addAttribute(withName: "type", stringValue: conversationType.rawValue)
        let elementId = "RRR: \(NanoID.new(8))"
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: retract))
        queryIds.insert(elementId)
        itemsQuery.insert(Item("", kind: .retract, messageId: "", iqId: elementId, callback: callback))
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND conversationType_ == %@ AND messageType != %@", owner, jid, conversationType.rawValue, MessageStorageItem.MessageDisplayType.initial.rawValue)
                    .forEach { $0.isDeleted = true }
            }
            LastChats.updateErrorState(for: jid, owner: self.owner, conversationType: conversationType)
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). \(error.localizedDescription)")
        }
    }
    
//    <iq type='set' to='test-group-ios-07102021-02@xmppdev01.xabber.com/Group' xmlns='jabber:client' id='d8c63ca7-9707-49a1-b04c-9b4519b96f62:sendIQ'><retract-user id='qzsgkk4vchfeloei' xmlns='https://xabber.com/protocol/rewrite' symmetric='true'/></iq>
    
    open func deleteMessageGroupchat(_ xmppStream: XMPPStream, chat: String, userId: String, callback: ((String?, Bool) -> Void)?) {
        let retract = DDXMLElement(name: "retract-user", xmlns: getPrimaryNamespace())
        retract.addAttribute(withName: "symmetric", stringValue: "true")
        retract.addAttribute(withName: "id", stringValue: userId)
        let elementId = "RRR: \(NanoID.new(8))"
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: chat), elementID: elementId, child: retract))
        queryIds.insert(elementId)
        itemsQuery.insert(Item("", kind: .retract, messageId: "", iqId: elementId, callback: callback))
    }
    
    open func deleteMessageGroupchat(_ xmppStream: XMPPStream, chat: String, callback: ((String?, Bool) -> Void)?) {
        let retract = DDXMLElement(name: "retract-all", xmlns: getPrimaryNamespace())
        retract.addAttribute(withName: "symmetric", stringValue: "true")
        retract.addAttribute(withName: "conversation", stringValue: chat)
        let elementId = "RRR: \(NanoID.new(8))"
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: chat), elementID: elementId, child: retract))
        queryIds.insert(elementId)
        itemsQuery.insert(Item("", kind: .retract, messageId: "", iqId: elementId, callback: callback))
    }
    
    open func editMessage(_ xmppStream: XMPPStream, primary: String, editedMessage: XMPPMessage, conversationType: ClientSynchronizationManager.ConversationType) {
        func send(_ messageId: String, elementId: String, to archiveJid: String) {
            let replace = DDXMLElement(name: "replace", xmlns: getPrimaryNamespace())
            replace.addAttribute(withName: "id", stringValue: messageId)
            replace.addAttribute(withName: "type", stringValue: conversationType.rawValue)
            replace.addChild(editedMessage)
            
            let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: replace)
            iq.addAttribute(withName: "to", stringValue: archiveJid)
            iq.addAttribute(withName: "from", stringValue: self.owner)
            
            xmppStream.send(iq)
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let elementId = "RRR: \(NanoID.new(8))"
                send(instance.archivedId, elementId: elementId, to: instance.groupchatMetadata != nil ? instance.opponent : self.owner)
                queryIds.insert(elementId)
            }
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). Cant get message for key \(primary). \(error.localizedDescription)")
        }
    }
    
    open func enable(_ xmppStream: XMPPStream, maxItems: Int? = nil) {
        if isEnabled { return }
        isEnabled = true
        let activate = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        if version.isNotEmpty {
            activate.addAttribute(withName: "version", stringValue: version)
        }
        if let maxItems = maxItems {
            activate.addAttribute(withName: "less-than", integerValue: maxItems)
        }
        let elementId = "RRR: \(NanoID.new(8))"
        xmppStream.send(XMPPIQ(iqType: .get, to: nil, elementID: elementId, child: activate))
        queryIds.insert(elementId)
    }
    
    open func enableForGroupchat(_ xmppStream: XMPPStream, jid: String, maxItems: Int? = nil, currentVersion: String? = nil) {
        var version: String? = nil
        do {
            let realm = try  WRealm.safe()
            if let retractVersion = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: .group
                )
            )?.retractVersion {
                version = retractVersion
            }
        } catch {
            DDLogDebug("MessageDeleteManager: \(#function). \(error.localizedDescription)")
        }
        if currentVersion == version { return }
        let activate = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        if let version = version {
            activate.addAttribute(withName: "version", stringValue: version)
        }
        if let maxItems = maxItems {
            activate.addAttribute(withName: "less-than", integerValue: maxItems)
        }
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get, to: XMPPJID(string: jid), elementID: elementId, child: activate))
        queryIds.insert(elementId)
    }
    
    override func clearSession() {
        isEnabled = false
        queryIds.removeAll()
        itemsQuery.removeAll()
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager.shared.saveItem(for: owner, scope: .messageDeleteRewrite, key: "node", value: "")
    }
}
