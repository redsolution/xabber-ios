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

class ClientSynchronizationManager: AbstractXMPPManager {
    
    public let pageSize: Int = 60
    
    open var isAvailable: Bool = false
    open var version: String = ""
    private var temporaryVer: String? = nil
    
    internal var isPresenceSended: Bool = false
    
    internal var acountSynced: Bool = false
    private var ignorePush: Bool = false
    
    internal var firstSync: Bool = true
    
    enum ConversationStatus: String {
        case archived = "archived"
        case active = "active"
        case deleted = "deleted"
    }
    
    enum ConversationType: String {
        case regular = "urn:xabber:chat"
        case group = "https://xabber.com/protocol/groups"
        case channel = "https://xabber.com/protocol/channels"
        case omemo = "urn:xmpp:omemo:2"
        case omemo1 = "urn:xmpp:omemo:1"
        case axolotl = "eu.siacs.conversations.axolotl"
        case notifications = "urn:xabber:notify:0"
    }
    
    static public let primaryNamespace = "https://xabber.com/protocol/synchronization"
    
    init(withOwner owner: String, ignorePush: Bool = false) {
        super.init(withOwner: owner)
        self.ignorePush = ignorePush
    }
    
    override func getPrimaryNamespace() -> String {
        return ClientSynchronizationManager.primaryNamespace
    }
    
    open func checkAvailability(_ features: DDXMLElement) {
        if features.element(forName: "starttls") != nil { return }
        guard let synchronization = features.element(forName: "synchronization"),
            synchronization.xmlns() == ClientSynchronizationManager.primaryNamespace else {
                isAvailable = false
                return
        }
        isAvailable = true
        updateStateForAccount()
        version = SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: "version") ?? ""
        if version.isEmpty {
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "0")
        }
    }
    
    internal func updateStateForAccount() {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                if instance.clientSyncSupport != isAvailable && !realm.isInWriteTransaction {
                    try realm.write {
                        instance.clientSyncSupport = isAvailable
                    }
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func sync(_ xmppStream: XMPPStream, customVer: String? = nil, after: String? = nil) -> Bool {
        if !isAvailable { return false }
        acountSynced = false
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: ClientSynchronizationManager.primaryNamespace)
        if let customVer = customVer,
           customVer.isNotEmpty {
            query.addAttribute(withName: "stamp", stringValue: customVer)
        } else if version.isNotEmpty {
            query.addAttribute(withName: "stamp", stringValue: version)
        }
        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        set.addChild(DDXMLElement(name: "max", stringValue: "\(pageSize)"))
        if let after = after {
            set.addChild(DDXMLElement(name: "after", stringValue: after))
        }
        query.addChild(set)
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: nil,
                               elementID: elementId,
                               child: query))
        queryIds.insert(elementId)
        return isAvailable
    }
    
    public final func muteChat(_ xmppStream: XMPPStream, jid: String, conversatuinType: ClientSynchronizationManager.ConversationType) -> Bool {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let conversation = DDXMLElement(name: "conversation")
        conversation.addAttribute(withName: "jid", stringValue: jid)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversatuinType
                )) {
                conversation.addAttribute(withName: "type", stringValue: instance.conversationType.rawValue)
                if instance.isPinned {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = 0
                        instance.isPinned = false
                    }
                    conversation.addAttribute(withName: "mute", stringValue: "0")
                } else {
                    let position = Date().timeIntervalSince1970.rounded()*1000
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = position
                        instance.isPinned = true
                    }
                    conversation.addAttribute(withName: "pinned", doubleValue: position)
                }
                query.addChild(conversation)
                if self.isAvailable {
                    xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
                    self.queryIds.insert(elementId)
                    return true
                } else {
                    return false
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    public final func pinChat(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let conversation = DDXMLElement(name: "conversation")
        conversation.addAttribute(withName: "jid", stringValue: jid)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )) {
                conversation.addAttribute(withName: "type", stringValue: instance.conversationType.rawValue)
                if instance.isPinned {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = 0
                        instance.isPinned = false
                    }
                    conversation.addAttribute(withName: "pinned", stringValue: "0")
                } else {
                    let position = Date().timeIntervalSince1970.rounded()*1000
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = position
                        instance.isPinned = true
                    }
                    conversation.addAttribute(withName: "pinned", doubleValue: position)
                }
                query.addChild(conversation)
                if self.isAvailable {
                    xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
                    self.queryIds.insert(elementId)
                    return true
                } else {
                    return false
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    public final func update(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, status: ConversationStatus? = nil, pinned: Double? = nil, mute: Double? = nil) -> String? {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let conversation = DDXMLElement(name: "conversation")
        conversation.addAttribute(withName: "jid", stringValue: jid)
        do {
            let realm = try  WRealm.safe()
            
                conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
                if let status = status {
                    conversation.addAttribute(withName: "status", stringValue: status.rawValue)
                } else {
                    if let instance = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: jid,
                            owner: self.owner,
                            conversationType: conversationType
                        )) {
                        if let pinned = pinned {
                            conversation.addAttribute(withName: "pinned", doubleValue: pinned)
                        } else if instance.isPinned && mute == nil {
                            conversation.addAttribute(withName: "pinned", stringValue: "")
                        } else {
                            if let mute = mute {
                                conversation.addAttribute(withName: "mute", doubleValue: mute)
                            } else if instance.isMuted && pinned == nil {
                                conversation.addAttribute(withName: "mute", stringValue: "")
                            }
                        }
                    }
                }
            query.addChild(conversation)
            xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
            self.queryIds.insert(elementId)
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        
        return nil
    }
 
    open func checkNextPage(_ xmppStream: XMPPStream, in iq: XMPPIQ) -> Bool {
        guard let last = iq
                        .element(forName: "query")?
                        .element(forName: "set")?
                        .element(forName: "last")?
                        .stringValue,
              let count = iq
                        .element(forName: "query")?
                        .element(forName: "set")?
                        .element(forName: "count")?
                        .stringValueAsNSInteger(),
                  count > pageSize//,
//            iq
//                .element(forName: "synchronization")?
//                .element(forName: "fin") == nil
        else {
                return false
        }
        let result = sync(xmppStream, after: last)
        return result
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readPush(iq): return true
        case readSnapshot(iq): return true
        case readResult(iq): return true
        default: return false
        }
    }
    
    internal func readPush(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .set,
              let query = iq.element(forName: "synchronization") ?? iq.element(forName: "query"),
              query.xmlns() == ClientSynchronizationManager.primaryNamespace,
              let stamp = query.attributeStringValue(forName: "stamp") else {
                return false
        }
        version = stamp
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: version)
        
        do {
            let realm = try WRealm.safe()
            try realm.write {
                query.elements(forName: "conversation").forEach {
                    _ = readConversationMetadata($0)
                    readPresence($0)
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: owner)?.groupchats.getInvitesFallback()
        return true
    }
    
    private final func readConversationMetadata(_ conversation: DDXMLElement, commitTransaction: Bool = false) -> Bool {
        func transaction(_ block: (() -> Void)) throws {
            let realm = try WRealm.safe()
            if commitTransaction {
                try realm.write(block)
            } else {
                block()
            }
        }
        guard let jid = conversation.attributeStringValue(forName: "jid")
               else {
            return false
        }
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)) {
                if let statusRaw = conversation.attributeStringValue(forName: "status"),
                   let status = ConversationStatus(rawValue: statusRaw) {
                    let pinned = conversation.attributeDoubleValue(forName: "pinned", withDefaultValue: 0)
                    if instance.pinnedPosition != pinned {
                        try transaction {
                            instance.pinnedPosition = pinned
                            instance.isPinned = pinned != 0
                        }
                    }
                    let muteExpired = conversation.attributeDoubleValue(forName: "mute", withDefaultValue: 0)
                    if instance.muteExpired != muteExpired {
                        try transaction {
                            instance.muteExpired = muteExpired
                        }
                    }
                    switch status {
                    case .archived:
                        try transaction {
                            instance.isArchived = true
                        }
                    case .active:
                        try transaction {
                            instance.isArchived = false
                        }
                    case .deleted:
                        let messages = realm
                            .objects(MessageStorageItem.self)
                            .filter("opponent == %@ AND owner == %@", jid, owner)

                        let messagesReference = realm
                            .objects(MessageReferenceStorageItem.self)
                            .filter("jid == %@ AND owner == %@", jid, owner)
                        let messagesInlines = realm
                            .objects(MessageForwardsInlineStorageItem.self)
                            .filter("jid == %@ AND owner == %@", jid, owner)
                        try transaction {
                            instance.rosterItem?.associatedLastChat = nil
                            realm.delete(instance)
                            realm.delete(messages)
                            realm.delete(messagesReference)
                            realm.delete(messagesInlines)
                        }
                    }
                }
                
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
//    <iq xmlns="jabber:client" lang="ru" to="igor.boldin@redsolution.com/xabber-ios-3F02F22F" from="igor.boldin@redsolution.com" type="result" id="EF06FF8B-BC20-4215-A7C5-CC9675DC5366">
//      <synchronization xmlns="https://xabber.com/protocol/synchronization" stamp="1594109688793236">
//        <set xmlns="http://jabber.org/protocol/rsm">
//          <count>82</count>
//        </set>
//      </synchronization>
//    </iq>
    
    internal func readSnapshot(_ iq: XMPPIQ) -> Bool {
        guard let query = iq.element(forName: "query", xmlns: ClientSynchronizationManager.primaryNamespace),
              let stamp = query.attributeStringValue(forName: "stamp") else {
                return false
        }
        if temporaryVer == nil {
            temporaryVer = stamp
        }
        
        AccountManager.shared.changeNewUserState(for: self.owner, to: .dataLoaded)
        let afterElement = query.element(forName: "set")?.element(forName: "last")
        if !isPresenceSended {
            isPresenceSended = true
            AccountManager
                .shared
                .find(for: owner)?
                .unsafeAction { (user, stream) in
                    user.msgDeleteManager.enable(stream)
                    if !user.sm.didResume {
                        user.presence()
                    }
                    _ = user.syncManager.sync(stream, customVer: self.temporaryVer)
                }
        }
        if afterElement == nil {
            self.version = stamp
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: version)
            
            self.firstSync = false
            acountSynced = true
            self.temporaryVer = nil
            
            AccountManager.shared.find(for: owner)?.unsafeAction({ (user, stream) in
                user.csi.active(stream, by: .synchronization)
            })
        }
        let conversationsItems = updateOmemoMessages(query).elements(forName: "conversation")

        RunLoop.main.perform {
            do {
                let realm = try WRealm.safe()
                
                var accountCreateDate: Date? = nil
                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                    accountCreateDate = instance.createdAt
                }
                
                realm.writeAsync {
                    
                    conversationsItems.forEach { self.readInvites($0) }
                    
                    AccountManager
                        .shared
                        .find(for: self.owner)?
                        .messages
                        .processQueue(Set(conversationsItems.compactMap { self.readConversation($0, accountCreateDate: accountCreateDate) })) {
                        if let results = $0 {
                            AccountManager.shared.find(for: self.owner)?.messages.unsafeSave(results)
                        }
                    }
                }
                realm.writeAsync {
                    conversationsItems.forEach {
                        self.readMessageMarkers($0)
                        self.readPresence($0)
                    }
                }
                AccountManager.shared.find(for: self.owner)?.groupchats.getInvitesFallback()
            } catch {
                DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
            }
        }
        return true
    }
    
    internal func updateOmemoMessages(_ query: DDXMLElement) -> DDXMLElement {
        
        if let modifiedQuery = AccountManager.shared.find(for: self.owner)?.omemo.modifySyncQuery(query) {
            return modifiedQuery
        }
        return query
        
    }
    
    internal func readPresence(_ conversation: DDXMLElement, commitTransaction: Bool = false) {
        
        func transaction(_ block: (() -> Void)) throws {
            let realm = try WRealm.safe()
            if commitTransaction {
                try realm.write(block)
            } else {
                block()
            }
        }
        
        func checkPresenceSubscribe(_ conversation: DDXMLElement) -> Bool {
            if let presenceRaw = conversation.element(forName: "presence"),
               let presence = try? XMPPPresence(xmlString: presenceRaw.xmlString),
               presence.presenceType == .subscribe {
                return true
            } else {
                return false
            }
        }
        
        guard let jid = conversation.attributeStringValue(forName: "jid") else { return }

        do {
            let realm = try  WRealm.safe()
            
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                if checkPresenceSubscribe(conversation) {
                    try transaction {
                        instance.ask = .in
                    }
                } else {
                    try transaction {
                        instance.ask = .none
                    }
                }
            } else {
                let instance = RosterStorageItem()
                instance.owner = owner
                instance.jid = jid
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .undefined
                instance.ask = checkPresenceSubscribe(conversation) ? .in : .none
                try transaction {
                    realm.add(instance)
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func readMessageMarkers(_ conversation: DDXMLElement) {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              let metadata = conversation
                            .elements(forName: "metadata")
                            .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" }),
              let displayed = metadata.element(forName: "displayed")?.attributeStringValue(forName: "id"),
              let delivered = metadata.element(forName: "delivered")?.attributeStringValue(forName: "id") else { return }
        
        let stamp = conversation.attributeDoubleValue(forName: "stamp")
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? .regular
        do {
            let realm = try  WRealm.safe()
            if let deliveredMessageTimeInterval = TimeInterval(delivered) {
                let deliveredMessageDate = Date(timeIntervalSince1970: deliveredMessageTimeInterval / 1000000)
                realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND outgoing == true AND state_ == %@ AND date <= %@ AND conversationType_ == %@",
                            owner,
                            jid,
                            MessageStorageItem.MessageSendingState.sended.rawValue,
                            deliveredMessageDate,
                            conversationType.rawValue)
                    .forEach { $0.state = .deliver}
            }
            
            if let displayedMessageTimeInterval = TimeInterval(displayed) {
                let displayedMessageDate = Date(timeIntervalSince1970: displayedMessageTimeInterval / 1000000)
                var state: MessageStorageItem.MessageSendingState = .sended
                let readDate = Date(timeIntervalSince1970: stamp / 1000000)
                realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND state_ == %@ AND date <= %@ AND conversationType_ == %@",
                            owner,
                            jid,
                            MessageStorageItem.MessageSendingState.deliver.rawValue,
                            displayedMessageDate,
                            conversationType.rawValue)
                    .forEach {
                        $0.state = .read
                        $0.isRead = true
                        if $0.afterburnInterval > 0 && $0.burnDate <= 1 {
                            $0.readDate = readDate.timeIntervalSince1970
                            $0.burnDate = readDate.timeIntervalSince1970 + $0.afterburnInterval
                            if (readDate.timeIntervalSince1970 + $0.afterburnInterval) < Date().timeIntervalSince1970 {
                                $0.isDeleted = true
                            }
                        }
                    }
            }
            
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func readInvites(_ conversation: DDXMLElement) {
        
        let timestamp = conversation.attributeDoubleValue(forName: "stamp")
        if let messageElement = conversation.elements(forName: "metadata").first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?.element(forName: "last-message")?.element(forName: "message"),
            (AccountManager.shared.find(for: owner)?.groupchats.isInvite(XMPPMessage(from: messageElement.copy() as! DDXMLElement)) ?? false) {
            if AccountManager
                .shared
                .find(for: owner)?
                .groupchats
                .readInvite(in: XMPPMessage(from: messageElement.copy() as! DDXMLElement),
                            date: Date(timeIntervalSince1970: timestamp / 1000000), isRead: false, commit: false) ?? false {
                conversation.removeAttribute(forName: "jid")
            }
        }
        
    }
    
    internal func readConversation(_ conversation: DDXMLElement, accountCreateDate: Date? = nil) -> MessageManager.MessageQueueItem? {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              jid.isNotEmpty else {
            return nil
        }
        
        let conversationStatus = conversation.attributeStringValue(forName: "status") ?? "active"
        
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? .regular
        
        if conversationType == .notifications {
            return nil
        }
        
        if jid == AccountManager.shared.find(for: self.owner)?.notifications.node {
            return nil
        }

        let stamp = conversation.attributeDoubleValue(forName: "stamp")
        do {
            let realm = try WRealm.safe()
            if conversation.element(forName: "deleted") != nil || conversationStatus == "deleted" {
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: self.owner,
                        conversationType: conversationType)) {
                    realm.delete(instance)
                }
                return nil
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager; \(#function). \(error.localizedDescription)")
        }
        
        guard let metadata = conversation
            .elements(forName: "metadata")
            .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" }) else {
            return nil
        }
        func getChat(_ realm: Realm, jid: String, conversationType: ConversationType) throws -> LastChatsStorageItem {
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )
            ) {
                return instance
            }
            let instance = LastChatsStorageItem()
            instance.owner = owner
            instance.jid = jid
            instance.conversationType = conversationType
//            var needGenAvatar: Bool = false
            if let rosterItem = realm
                .object(ofType: RosterStorageItem.self,
                        forPrimaryKey: [jid, owner].prp()) {
                instance.rosterItem = rosterItem
                rosterItem.associatedLastChat = instance
            } else {
                let rosterItem = RosterStorageItem()
                rosterItem.owner = owner
                rosterItem.jid = jid
                rosterItem.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                rosterItem.groups.append(RosterUtils.ungroupped)
                rosterItem.associatedLastChat = instance
                realm.add(rosterItem)
                instance.rosterItem = rosterItem
            }
            instance.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())
            instance.setPrimary(withOwner: owner)
            realm.add(instance, update: .modified)
            
            return instance
        }
        do {
            let realm = try  WRealm.safe()
            
            
            if metadata.element(forName: "last-message")?.element(forName: "message") == nil {
                if conversation.element(forName: "presence")?.attributeStringValue(forName: "type") == "subscribe" {
                    if conversationType != ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                        return nil
                    }
                }
//                if let instance = realm.object(
//                    ofType: LastChatsStorageItem.self,
//                    forPrimaryKey: LastChatsStorageItem.genPrimary(
//                        jid: jid,
//                        owner: self.owner,
//                        conversationType: conversationType)) {
//                    realm.delete(instance)
//                }
//                return nil
            }

            
            
            
            
            if let messageElement = metadata.element(forName: "last-message")?.element(forName: "message") {
                if (AccountManager.shared.find(for: owner)?.groupchats.isInvite(XMPPMessage(from: messageElement)) ?? false) {
                    return nil
                }
            }
            
            let isNewChatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType)
            ) == nil
            
            let instance = try getChat(realm, jid: jid, conversationType: conversationType)
            instance.conversationType_ = conversationType.rawValue
            let mute = conversation.attributeDoubleValue(forName: "mute", withDefaultValue: -1)
            instance.muteExpired = mute
            
            let pinnedPosition = conversation.attributeDoubleValue(forName: "pinned", withDefaultValue: 0)
            instance.pinnedPosition = pinnedPosition
            instance.isPinned = pinnedPosition != 0
            
            if let retractVersion = conversation
                .elements(forName: "metadata")
                .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/rewrite" })?
                .element(forName: "retract")?
                .attributeStringValue(forName: "version"),
                retractVersion != "0" {
                if conversationType == .group && !isNewChatInstance {
                    if AccountManager.shared.activeUsers.value.count == 1 {
                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                            session.retract?.enableForGroupchat(stream, jid: jid, maxItems: 50, currentVersion: retractVersion)
                        }, fail: {
                            AccountManager.shared.find(for: self.owner)?.delayedAction(delay: 0.5, toExecute: { (user, stream) in
                                user.msgDeleteManager.enableForGroupchat(stream, jid: jid, maxItems: 50, currentVersion: retractVersion)
                            })
                        })
                    } else {
                        AccountManager.shared.find(for: owner)?.delayedAction(delay: 0.5, toExecute: { (user, stream) in
                            user.msgDeleteManager.enableForGroupchat(stream, jid: jid, maxItems: 50, currentVersion: retractVersion)
                        })
                    }
                }
            }
            instance.mentionId = metadata.element(forName: "unread-mention")?.attributeStringValue(forName: "id")
            instance.displayedId = metadata.element(forName: "displayed")?.attributeStringValue(forName: "id")
            instance.deliveredId = metadata.element(forName: "delivered")?.attributeStringValue(forName: "id")
            instance.lastReadId = metadata.element(forName: "unread")?.attributeStringValue(forName: "after")
            instance.unread = metadata.element(forName: "unread")?.attributeIntegerValue(forName: "count") ?? 0
            instance.isPrereaded = false

            if conversationStatus == "archived" {
                instance.isArchived = true
            } else if conversationStatus == "active" {
                instance.isArchived = false
            }
            
            var timestamp = stamp
            var conversationDate = Date(timeIntervalSince1970: timestamp / 1000000)
            if let messageElement = metadata.element(forName: "last-message")?.element(forName: "message") {
                if let date = messageElement.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate {
                    conversationDate = date
                    timestamp = date.timeIntervalSince1970
                }
            }
            instance.messageDate = conversationDate
            let unreadAfterTS = metadata.element(forName: "unread")?.attributeDoubleValue(forName: "after")

            if let interval = unreadAfterTS {
                NotifyManager.shared.clearNotifications(for: interval as TimeInterval,
                                                        owner: owner,
                                                        jid: jid)
            }

            if isNewChatInstance {
                let initialMessage = MessageStorageItem()
                initialMessage.configureInitialMessage(
                    self.owner,
                    opponent: jid,
                    conversationType: conversationType,
                    text: "",
                    date: conversationDate,
                    isRead: instance.displayedId == "0"
                )
                if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessage.primary) == nil {
                    initialMessage.isDeleted = true
                    _ = initialMessage.save(commitTransaction: false)
                }
                if conversationType == .group {
                    let resource = ResourceStorageItem()
                    resource.owner = owner
                    resource.jid = jid
                    resource.resource = owner
                    resource.status = .offline
                    resource.entity = .groupchat
                    resource.type = .groupchat
                    resource.priority = -5
                    resource.isTemporary = true
                    resource.primary = ResourceStorageItem.genPrimary(jid: jid, owner: owner, resource: owner)
                    realm.add(resource, update: .modified)

                    if realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: jid, owner: owner)) == nil {
                        let groupchatStorageItem = GroupChatStorageItem()
                        groupchatStorageItem.jid = jid
                        groupchatStorageItem.owner = owner
                        groupchatStorageItem.primary = GroupChatStorageItem.genPrimary(jid: jid, owner: owner)
                        groupchatStorageItem.members = 1
                        realm.add(groupchatStorageItem, update: .modified)
                    }
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
            }
            let userCard = conversation
                .elements(forName: "metadata")
                .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/groups" })?
                .element(forName: "user", xmlns: "https://xabber.com/protocol/groups")
            if let card = userCard {
                _ = AccountManager
                    .shared
                    .find(for: owner)?
                    .groupchats
                    .updateUserCard(card,
                                    myCard: true,
                                    groupchat: jid,
                                    trustedSource: true,
                                    messageAction: nil,
                                    commitTransaction: false)
            }
            
            if [.omemo, .axolotl, .omemo1].contains(conversationType),
               metadata.element(forName: "last-message")?.element(forName: "message") == nil {
                instance.isFreshNotEmptyEncryptedChat = true
                instance.isSynced = false//!firstSync
            }
            if let messageElement = metadata.element(forName: "last-message")?.element(forName: "message") {
                if let date = getDeliveryDate(XMPPMessage(from: messageElement)) {
                    if [.omemo, .axolotl, .omemo1].contains(conversationType), let accountCreateDate = accountCreateDate {
                        if date.timeIntervalSince1970 < accountCreateDate.timeIntervalSince1970 {
                            instance.isFreshNotEmptyEncryptedChat = true
                            instance.isSynced = false//!firstSync
                            instance.lastMessageId = getOriginId(XMPPMessage(from: messageElement)) ?? XMPPMessage(from: messageElement).elementID ?? getStanzaId(XMPPMessage(from: messageElement), owner: self.owner)
                            return nil
                        }
                    }
//                    if !self.firstSync {
//                        return nil
//                    }
                }
                
                if VoIPManager.shared.onReceiveMessage(messageElement, owner: self.owner, archivedDate: Date(timeIntervalSince1970: timestamp / 1000000), commitTransaction: false) {
                    return nil
                }
                if ((AccountManager.shared.find(for: self.owner)?.groupchats.readMessage(withMessage: messageElement as! XMPPMessage, commitTransaction: false)) ?? false) {
                    return nil
                }
                let stanzaId = getStanzaId(XMPPMessage(from: messageElement), owner: self.owner)
                var state: MessageStorageItem.MessageSendingState = .sended
                if unreadAfterTS == timestamp {
                    state = .read
                } else if instance.deliveredId == stanzaId {
                    state = .deliver
                }
                let readDate = state != .read ? nil : Date(timeIntervalSince1970: stamp / 1000000)
                
                if !(AccountManager
                        .shared
                        .find(for: owner)?
                        .groupchats
                        .isInvite(XMPPMessage(from: messageElement)) ?? false) {
                    let messageStanza = XMPPMessage(from: messageElement)
                    guard let from = messageStanza.from?.bare,
                          let to = messageStanza.to?.bare,
                          [self.owner, jid].contains(from),
                          [self.owner, jid].contains(to) else {
                        return nil
                    }
                    if instance.lastMessageId != getUniqueMessageId(messageStanza, owner: self.owner) {
                        instance.isSynced = false//!firstSync
                    }
                    return AccountManager
                        .shared
                        .find(for: owner)?
                        .messages
                        .receiveClientSyncRaw(messageStanza,
                                              groupchatUserCard: userCard,
                                              isRead: state == .read,
                                              state: state,
                                              date: Date(timeIntervalSince1970: timestamp),
                                              readDate: readDate)
                }
            } else {
                if let retractVersion = conversation
                    .elements(forName: "metadata")
                    .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/rewrite" })?
                    .element(forName: "retract")?
                    .attributeStringValue(forName: "version"),
                    retractVersion != "0" {
//                    if instance.retractVersion != retractVersion {
//                        instance.lastMessage = nil
//                    }
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
    internal func readResult(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              iq.iqType == .result,
              queryIds.contains(elementId) else { // BAD ACCESS
                return false
        }
        queryIds.remove(elementId)
        return true
    }
    
    public final func isSynced() -> Bool {
        if isAvailable {
            return acountSynced
        }
        return true
    }
    
    public final func reset() {
        self.queryIds.removeAll()
        self.isPresenceSended = false
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "")
    }
}
