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

class RosterManager: AbstractXMPPManager {
    
    class QueueItem: Hashable {
        static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        enum Action {
            case add
            case delete
        }
        
        var action: Action
        var elementId: String
        var value: String
        var callback: ((String?, String?, Bool) -> Void)?
        
        init(_ action: Action, elementId: String, value: String, callback: ((String?, String?,  Bool) -> Void)? = nil) {
            self.action = action
            self.elementId = elementId
            self.callback = callback
            self.value = value
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    internal var version: String? = nil
    
    internal var queueItems: SynchronizedArray<QueueItem> = SynchronizedArray<QueueItem>()
    internal var isInitialRosterReceived: Bool = false
    
    override func namespaces() -> [String] {
        return ["jabber:iq:roster", ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        version = SettingManager.shared.getKey(for: owner, scope: .roster, key: "version")
    }
    
    open func request(_ xmppStream: XMPPStream) {
        isInitialRosterReceived = false
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        query.addAttribute(withName: "ver", stringValue: version ?? " ")
//        isInitialRosterReceived = true
        AccountManager.shared.find(for: owner)?.didReceiveRoster()
        xmppStream.send(XMPPIQ(iqType: .get, elementID: elementId, child: query))
        queryIds.insert(elementId)
    }
    
    open func setContact(_ xmppStream: XMPPStream, jid: String, getNickFromVCard: Bool = false, nickname preferredNickname: String? = nil, groups: [String] = [], shouldAddSystemMessage: Bool = false, callback: ((String?, String?, Bool) -> Void)? = nil) {
        do {
            let realm = try  WRealm.safe()
            let elementId = xmppStream.generateUUID
            let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "jid", stringValue: jid)
            var nickname = preferredNickname
            if getNickFromVCard {
                if let vcard = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                    nickname = vcard.unsafeGeneratedNickname
                }
            }
            if let nickname = nickname {
                item.addAttribute(withName: "name", stringValue: nickname)
            }
            groups
                .filter{ $0.isNotEmpty }
                .compactMap { return DDXMLElement(name: "group", stringValue: $0) }
                .forEach { item.addChild($0) }
            query.addChild(item)
            xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
            queryIds.insert(elementId)
            queueItems.insert(QueueItem(.add, elementId: elementId, value: jid, callback: callback))
        
            
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                try realm.write {
                    instance.subscribtion = .none
                }
            } else {
                let instance = RosterStorageItem()
                instance.jid = jid
                instance.owner = owner
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .none
                instance.associatedLastChat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular))
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func removeContact(_ xmppStream: XMPPStream, jid: String, callback: ((String?, String?, Bool) -> Void)? = nil ) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        item.addAttribute(withName: "subscription", stringValue: "remove")
        query.addChild(item)
        xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.delete, elementId: elementId, value: jid, callback: callback))
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                try realm.write {
                    instance.subscribtion = .undefined
                    instance.ask = .none
                }
            }
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readError(iq): return true
        case readSuccess(iq): return true
        case readResponse(iq): return true
        default: return false
        }
    }
    
    internal func readSuccess(_ iq: XMPPIQ) -> Bool {
        guard let query = iq.element(forName: "query", xmlns: getPrimaryNamespace()),
            let elementId = iq.elementID else {
            return false
        }
        
        if queryIds.contains(elementId) {
            queryIds.remove(elementId)
        }
        
        if iq.iqType == .set {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.presence()
            })
        }
        do {
            let realm = try  WRealm.safe()
            
            func updateGroups(_ instance: RosterStorageItem, groups: [String]) {
                if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.notInRosterGroupName, owner].prp()) {
                    if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                        item.contacts.remove(at: index)
                    }
                }
                if groups.isEmpty {
                    realm.objects(RosterGroupStorageItem.self)
                        .filter("owner == %@", owner)
                        .forEach { item in
                            if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                item.contacts.remove(at: index)
                            }
                        }
                    if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                        if !group.contacts.contains(instance) {
                            group.contacts.append(instance)
                        }
                    } else {
                        let group = RosterGroupStorageItem()
                        group.isSystemGroup = true
                        group.name = RosterGroupStorageItem.systemGroupName
                        group.owner = owner
                        group.primary = RosterGroupStorageItem.genPrimary(name: RosterGroupStorageItem.systemGroupName, owner: owner)
                        group.contacts.append(instance)
                        realm.add(group, update: .modified)
                    }
                } else {
                    if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                        if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                            item.contacts.remove(at: index)
                        }
                    }
                    groups.forEach {
                        groupName in
                        realm.objects(RosterGroupStorageItem.self)
                            .filter("owner == %@", owner)
                            .forEach { item in
                                if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }),
                                   item.groupName != groupName {
                                    item.contacts.remove(at: index)
                                }
                            }
                        if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [groupName, owner].prp()) {
                            if !group.contacts.contains(instance) {
                                group.contacts.append(instance)
                            }
                        } else {
                            let group = RosterGroupStorageItem()
                            group.name = groupName
                            group.owner = owner
                            group.primary = RosterGroupStorageItem.genPrimary(name: groupName, owner: owner)
                            group.contacts.append(instance)
                            realm.add(group, update: .modified)
                        }
                    }
                }
            }
            
            try realm.write {
                query.elements(forName: "item").forEach { item in
                    guard let jid = item.attributeStringValue(forName: "jid") else { return }
                    let subscribtion = item.attributeStringValue(forName: "subscription", withDefaultValue: "none")
                    if subscribtion == "remove" {
                        if let instance = realm.object(ofType: RosterStorageItem.self,
                                                       forPrimaryKey: [jid, owner].prp()) {
                            realm
                                .objects(RosterGroupStorageItem.self)
                                .filter("owner == %@ AND name IN %@", owner, instance.groups.toArray())
                                .forEach { item in
                                    if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                        item.contacts.remove(at: index)
                                    }
                                }
                            if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                                if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                    item.contacts.remove(at: index)
                                }
                            }
                            instance.associatedLastChat?.rosterItem = nil
                            
                            realm.delete(instance)
                            
                            if let preaprovedSubscribtionInstance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self,
                                                                                 forPrimaryKey: PreaprovedSubscribtionStorageItem.genPrimary(jid: jid, owner: owner)) {
                                realm.delete(preaprovedSubscribtionInstance)
                            }
                            if let groupchatInstance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, self.owner].prp()) {
                                groupchatInstance.isDeleted = true
                            } else {
                                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.75) {
                                    do {
                                        let realm = try  WRealm.safe()
                                        
                                        if let authMessage = realm.object(
                                            ofType: MessageStorageItem.self,
                                            forPrimaryKey: MessageStorageItem.genPrimary(
                                                messageId: MessageStorageItem.messageIdForAuthRequest(jid: jid),
                                                owner: self.owner
                                            )
                                        ) {
                                            let lastMessageForChat = realm
                                                .objects(MessageStorageItem.self)
                                                .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, jid, ClientSynchronizationManager.ConversationType.omemo.rawValue)
                                                .sorted(byKeyPath: "date", ascending: true).last
                                            try realm.write {
                                                realm.delete(authMessage)
                                                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo))?.lastMessage = lastMessageForChat
                                            }
                                        }
                                    } catch {
                                        DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                    } else if let instance = realm.object(ofType: RosterStorageItem.self,
                                                          forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                        instance.owner = owner
                        instance.customUsername = item.attributeStringValue(forName: "name", withDefaultValue: "")
                        instance.subscription_ = subscribtion
//                        instance.ask_ = item.attributeStringValue(forName: "ask", withDefaultValue: "none")
                        if let ask = item.attributeStringValue(forName: "ask") {
                            if ask == "subscribe" {
                                instance.ask = .out
                            }
                        } else {
                            instance.ask = .none
                            if let notifyInstance = realm.object(ofType: UINotificationStorageItem.self, forPrimaryKey: UINotificationStorageItem.genPrimary(owner: jid, jid: owner)) {
                                realm.delete(notifyInstance)
                            }
                        }
                        if let approved = item.attributeStringValue(forName: "approved"),
                           approved == "true" {
                            instance.approved = true
                        } else {
                            instance.approved = false
                        }
                        instance.groups.removeAll()
                        let groups = item.elements(forName: "group").compactMap{ return $0.stringValue }
                        instance.groups.removeAll()
                        instance.groups.append(objectsIn: groups)
                        updateGroups(instance, groups: groups)
                        let isGroupchat = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, self.owner].prp()) != nil
                        if isGroupchat {
                            realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, self.owner].prp())?.isDeleted = false
                        }                        
                        realm
                            .objects(LastChatsStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, jid)
                            .forEach {
                            $0.rosterItem = instance
                        }
                        let username = instance.displayName
                        let avatarUrl = instance.avatarUrl
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl)
                    } else {
//                        DefaultAvatarManager.shared.updateAvatarIfNeeded(for: jid, owner: owner)
                        let instance = RosterStorageItem()
                        instance.owner = owner
                        instance.jid = jid
                        instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                        instance.customUsername = item.attributeStringValue(forName: "name", withDefaultValue: "")
                        instance.subscription_ = subscribtion
                        if let ask = item.attributeStringValue(forName: "ask") {
                            if ask == "subscribe" {
                                instance.ask = .out
                            }
                        } else {
                            instance.ask = .none
                        }
                        if let approved = item.attributeStringValue(forName: "approved"),
                           approved == "true" {
                            instance.approved = true
                        } else {
                            instance.approved = false
                        }
//                        instance.ask_ = item.attributeStringValue(forName: "ask", withDefaultValue: "none")
                        instance.groups.removeAll()
                        let groups = item.elements(forName: "group").compactMap{ return $0.stringValue }
                        instance.groups.append(objectsIn: groups)
//                        instance.associatedLastChat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(
//                            jid: ,
//                            owner: ,
//                            conversationType:
//                        ))
                        realm.add(instance, update: .modified)
                        
                        updateGroups(instance, groups: groups)
                        let isGroupchat = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, self.owner].prp()) != nil
                        if isGroupchat {
                            realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, self.owner].prp())?.isDeleted = false
                        }
                        if jid == XMPPJID(string: owner)?.domain {
                            let resourceInstance = ResourceStorageItem()
                            resourceInstance.jid = jid
                            resourceInstance.owner = owner
                            resourceInstance.resource = "server"
                            resourceInstance.status = .online
                            resourceInstance.statusMessage = ""
                            resourceInstance.priority = -5
                            resourceInstance.entity = .server
                            resourceInstance.client = ""
                            resourceInstance.isTemporary = false
                            resourceInstance.timestamp = Date()
                            resourceInstance.primary = ResourceStorageItem.genPrimary(jid: jid, owner: owner, resource: "server")
                            realm.add(resourceInstance, update: .modified)
                        }
                        RosterDisplayNameStorageItem.createOrUpdate(
                            jid: jid,
                            owner: self.owner,
                            displayName: item.attributeStringValue(forName: "name", withDefaultValue: ""),
                            commitTransaction: false
                        )
                        realm
                            .objects(LastChatsStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, jid)
                            .forEach {
                            $0.rosterItem = instance
                        }
                        let username = instance.displayName
                        let avatarUrl = instance.avatarUrl
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl)
                    }
                }
            }
            
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
        }
        
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(item.value, nil, true)
            queueItems.remove(item)
        }
        if iq.iqType == .set { return true }
        if let newVersion = query.attributeStringValue(forName: "ver") {
            version = newVersion
            SettingManager.shared.saveItem(for: owner, scope: .roster, key: "version", value: newVersion)
        }

        return true
    }
    
    internal func readError(_ iq: XMPPIQ) -> Bool {
        guard let errorElement = iq.element(forName: "error"),
            let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        
        let error = errorElement.name
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(item.value, error,false)
            queueItems.remove(item)
        }
        return true
    }
    
    internal func readResponse(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
//        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(item.value, nil, true)
            queueItems.remove(item)
        }
        return true
    }
    
    
    static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager.shared.removeItem(for: owner, scope: .roster, key: "version")
        do {
            let realm = try  WRealm.safe()
            let items = realm.objects(RosterStorageItem.self).filter("owner == %@", owner)
            let groups = realm.objects(RosterGroupStorageItem.self).filter("owner == %@", owner)
            let displayNames = realm.objects(RosterDisplayNameStorageItem.self).filter("owner == %@", owner)
            if commitTransaction {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(items)
                        realm.delete(groups)
                        realm.delete(displayNames)
                    }
                }
            } else {
                realm.delete(items)
            }
        } catch {
            DDLogDebug("cant delete roster for \(owner)")
        }
    }
}
