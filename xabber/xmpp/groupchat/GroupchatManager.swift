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
import Kingfisher

class GroupchatManager: AbstractXMPPManager {
    
    static let requestTimeoutSeconds: TimeInterval = 15.0
    
    enum FormType {
        case settings
        case defaultRights
        case userRights
        case status
    }
    
    class QueueItem: Hashable {
        static func == (lhs: GroupchatManager.QueueItem, rhs: GroupchatManager.QueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        enum Action {
            case create
            case delete
            case join
            case block
            case unblock
            case cancelJoin
            case leave
            case requestForm
            case updateForm
            case invite
            case revokeInvite
            case publishAvatar
            case publishAvatarMeta
            case resetAvatar
            case changeData
            case kick
            case pin
            case userCard
        }
        
        var action: Action
        var elementId: String
        var value: String = ""
        var values: [String] = []
        var payload: [[String: String]]
        var callback: ((String?) -> Void)?
        var formCallback: (([[String: Any]]?, [[String: Any]]?, [[String: Any]]?, String?) -> Void)?
        var settingsCallback: (([[String: Any]]?, String?) -> Void)?
        var invitesCallback: ((String, String?) -> Void)?
        
        init(_ action: Action, elementId: String, callback: ((String?) -> Void)? = nil, formCallback: (([[String: Any]]?, [[String: Any]]?, [[String: Any]]?, String?) -> Void)? = nil, settingsCallback: (([[String: Any]]?, String?) -> Void)? = nil, inviteCallback: ((String, String?) -> Void)? = nil, payload: [[String: String]] = [], value: String = "", values: [String] = []) {
            self.action = action
            self.elementId = elementId
            self.callback = callback
            self.settingsCallback = settingsCallback
            self.formCallback = formCallback
            self.invitesCallback = inviteCallback
            self.payload = payload
            self.value = value
            self.values = values
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    public var currentChat: String? = nil
    
    private final var queueItems: SynchronizedArray<QueueItem> = SynchronizedArray<QueueItem>()
    
    override func namespaces() -> [String] {
        return ["https://xabber.com/protocol/groups", ]
    }
    
    public static func staticGetNamespace() -> String {
        return "https://xabber.com/protocol/groups"
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first ?? ""
    }
    
    public final func xmlns(_ action: String) -> String {
        return [getPrimaryNamespace(), action].joined(separator: "#")
    }
    
    public final func invalidateCallback(_ elementId: String) {
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            queueItems.remove(item)
        }
    }
    
    public final func fullJid(_ bareJid: String) -> XMPPJID? {
        do {
            let realm = try  WRealm.safe()
            let resource = realm
                .objects(ResourceStorageItem.self)
                .filter("owner == %@ AND jid == %@", self.owner, bareJid)
                .sorted(by: [
                    SortDescriptor(keyPath: "timestamp", ascending: false),
                    SortDescriptor(keyPath: "priority", ascending: false)
                ])
                .first?
            .resource ?? "Group"
            return XMPPJID(string: bareJid, resource: resource)
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
//    public final func open(_ xmppStream: XMPPStream, groupchat: String) {
//        currentChat = groupchat
//        let presence = xmppStream.myPresence?.copy() as? DDXMLElement ?? XMPPPresence(type: .none, show: .none, status: nil, to: XMPPJID(string: groupchat))
//        presence.removeAttribute(forName: "to")
//        presence.addAttribute(withName: "to", stringValue: groupchat)
//        presence.addChild(DDXMLElement(name: "x", xmlns: xmlns("present")))
//        xmppStream.send(presence)
//    }
//    
//    public final func close(_ xmppStream: XMPPStream) {
//        if let groupchat = currentChat {
//            currentChat = nil
//            let presence = xmppStream.myPresence?.copy() as? DDXMLElement ?? XMPPPresence(type: .none, show: .none, status: nil, to: XMPPJID(string: groupchat))
//            presence.removeAttribute(forName: "to")
//            presence.addAttribute(withName: "to", stringValue: groupchat)
//            presence.addChild(DDXMLElement(name: "x", xmlns: xmlns("not-present")))
//            xmppStream.send(presence)
//        }
//    }
    
    public final func createPeerToPeer(_ xmppStream: XMPPStream, groupchat: String, user userId: String, callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: xmlns("create"))
        let peerToPeer = DDXMLElement(name: "peer-to-peer")
        peerToPeer.addAttribute(withName: "jid", stringValue: groupchat)
        peerToPeer.addAttribute(withName: "id", stringValue: userId)
        query.addChild(peerToPeer)
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat)?.domainJID, elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.create, elementId: elementId, callback: callback, value: "peer-to-peer"))
        let item = QueueItem(.join, elementId: [groupchat, "join"].prp(), callback: nil)
        queueItems.insert(item)
        AccountManager.shared.find(for: owner)?.groupchats.queueItems.insert(item)
    }
    
    public final func create(_ xmppStream: XMPPStream, server: String, name: String, localPart: String?, privacy: GroupChatStorageItem.Privacy?, membership: GroupChatStorageItem.Membership?,  index: GroupChatStorageItem.Index?, description: String?, callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: xmlns("create"))
        query.addChild(DDXMLElement(name: "name", stringValue: name))
        if let localPart = localPart {
            query.addChild(DDXMLElement(name: "localpart", stringValue: localPart))
        }
        if let privacy = privacy {
            query.addChild(DDXMLElement(name: "privacy", stringValue: privacy.rawValue))
        }
        if let membership = membership {
            query.addChild(DDXMLElement(name: "membership", stringValue: membership.rawValue))
        }
        if let index = index {
            query.addChild(DDXMLElement(name: "index", stringValue: index.rawValue))
        }
        if let descr = description {
            query.addChild(DDXMLElement(name: "description", stringValue: descr))
        }
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: server), elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.create, elementId: elementId, callback: callback))
        if let localPart = localPart {
            let item = QueueItem(.join, elementId: [[localPart, server].joined(separator: "@"), "join"].prp(), callback: nil)
            queueItems.insert(item)
            AccountManager.shared.find(for: owner)?.groupchats.queueItems.insert(item)
        }
    }
    
    public final func delete(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: xmlns("delete"))
        query.addChild(DDXMLElement(name: "localpart", stringValue: XMPPJID(string: groupchat)?.user ?? "\(groupchat.split(separator: "@").first ?? "")"))
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat)?.domainJID, elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.delete, elementId: elementId, callback: callback))
    }
    
    private final func addRequestTimeoutHandler(for elementId: String) {
        
        let timer = Timer.scheduledTimer(withTimeInterval: GroupchatManager.requestTimeoutSeconds, repeats: false) { (timer) in
            if let item = self.queueItems.first(where: { $0.elementId ==  elementId }) {
                item.formCallback?(nil, nil, nil, "timeout")
                item.settingsCallback?(nil, "timeout")
                item.callback?("timeout")
                item.invitesCallback?(item.value, "timeout")
                self.queueItems.remove(item)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }
    
    public final func join(_ xmppStream: XMPPStream, uiConnection: Bool, groupchat: String, callback: @escaping ((String?) -> Void)) {
        xmppStream.send(XMPPPresence(type: .subscribe, to: XMPPJID(string: groupchat)))
        let elementId = [groupchat, "join"].prp()
        queueItems.insert(QueueItem(.join, elementId: elementId, callback: callback))
        if uiConnection {
            AccountManager.shared.find(for: self.owner)?.groupchats.queueItems.insert(QueueItem(.join, elementId: elementId, callback: callback))
        }
        addRequestTimeoutHandler(for: elementId)
    }
    
    public final func cancelJoin(_ xmppStream: XMPPStream, uiConnection: Bool, groupchat: String, callback: @escaping ((String?) -> Void)) {
        xmppStream.send(XMPPPresence(type: .unsubscribe, to: XMPPJID(string: groupchat)))
        xmppStream.send(XMPPPresence(type: .unsubscribed, to: XMPPJID(string: groupchat)))
        let elementId = [groupchat, "cancel_join"].prp()
        queueItems.insert(QueueItem(.cancelJoin, elementId: elementId, callback: callback))
        if uiConnection {
            AccountManager.shared.find(for: self.owner)?.groupchats.queueItems.insert(QueueItem(.cancelJoin, elementId: elementId, callback: callback))
        }
        addRequestTimeoutHandler(for: elementId)
    }
    
    public final func decline(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "decline",
                                                   xmlns: xmlns("invite"))))
        queueItems.insert(QueueItem(.cancelJoin, elementId: elementId, callback: callback))
        addRequestTimeoutHandler(for: elementId )
    }
    
    public final func leave(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ((String?) -> Void)) {
        xmppStream.send(XMPPPresence(type: .unsubscribe, to: fullJid(groupchat)))
        queueItems.insert(QueueItem(.leave, elementId: [groupchat, "leave"].prp(), callback: callback))
    }
    
    public final func afterLeave(groupchat: String) {
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: groupchat,
                        owner: self.owner,
                        conversationType: .group
                    )
                ) {
                    realm.delete(instance)
                }
                realm.delete(realm.objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@", owner, groupchat))
                realm.delete(realm.objects(MessageReferenceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, groupchat))
                realm.delete(realm.objects(CallMetadataStorageItem.self)
                    .filter("owner == %@ AND opponent == %@", owner, groupchat))
                realm.delete(realm.objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@", [groupchat, owner].prp()))
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }

    public final func changeUserData(_ xmppStream: XMPPStream, groupchat: String, userId: String, nickname: String? = nil, badge: String? = nil, callback: ((String?) -> Void)?) {
        let elementId = xmppStream.generateUUID
        let user = DDXMLElement(name: "user", xmlns: getPrimaryNamespace())
        user.addAttribute(withName: "id", stringValue: userId)
        if let nickname = nickname {
            user.addChild(DDXMLElement(name: "nickname", stringValue: nickname))
        }
        if let badge = badge {
            user.addChild(DDXMLElement(name: "badge", stringValue: badge))
        }
        let query = DDXMLElement(name: "query", xmlns: xmlns("members"))
        query.addChild(user)
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.changeData, elementId: elementId, callback: callback))
    }
    
    public final func willInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String, callback: @escaping ((String, String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let invite = DDXMLElement(name: "invite", xmlns: xmlns("invite"))
        invite.addChild(DDXMLElement(name: "jid", stringValue: jid))
        invite.addChild(DDXMLElement(name: "send", stringValue: "false"))
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: invite))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.invite, elementId: elementId, inviteCallback: callback, value: jid))
    }
    
    public final func didInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String, reason: String? = nil) {
        let elementId = xmppStream.generateUUID
        let invite = DDXMLElement(name: "invite", xmlns: xmlns("invite"))
        invite.addAttribute(withName: "jid", stringValue: groupchat)
        if let reason = reason {
            invite.addChild(DDXMLElement(name: "reason", stringValue: reason))
        }
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: elementId, child: invite)
        message.addOriginId(elementId)
        message.addChild(DDXMLElement(name: "no-copy", xmlns: "urn:xmpp:hints"))
        message.addChild(DDXMLElement(name: "private", xmlns: "urn:xmpp:carbons:2"))
        message.addBody("Для вступления в групповой чат добавьте \(groupchat) в свой список контактов.")
        xmppStream.send(message)
        do {
            let realm = try  WRealm.safe()
            let instance = GroupchatInvitesStorageItem()
            instance.owner = owner
            instance.jid = jid
            instance.primary = [elementId, owner].prp()
            instance.inviteId = elementId
            instance.date = Date()
            instance.groupchat = groupchat
            instance.sender = owner
            instance.outgoing = true
            instance.isRead = true
            instance.isProcessed = true
            try realm.write {
                realm.add(instance, update: .all)
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func revokeInvites(_ xmppStream: XMPPStream, groupchat: String, jids: [String], callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let revoke = DDXMLElement(name: "revoke", xmlns: xmlns("invite"))
        jids.forEach { revoke.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: revoke))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.revokeInvite, elementId: elementId, callback: callback, values: jids))
    }
    
    public final func revokeInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String, callback: @escaping ((String, String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let revoke = DDXMLElement(name: "revoke", xmlns: xmlns("invite"))
        revoke.addChild(DDXMLElement(name: "jid", stringValue: jid))
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: revoke))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.revokeInvite, elementId: elementId, inviteCallback: callback, value: jid))
    }
    
    public final func requestInvitedUsers(_ xmppStream: XMPPStream, groupchat: String) {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "query",
                                                   xmlns: xmlns("invite"))))
        queryIds.insert(elementId)
    }
    
    //<iq from='igor.boldin@redsolution.com' to='xabber@xmppdev01.xabber.com' type='get' xmlns='jabber:client' id='d15f14fa-cc9d-4368-a075-2b691642b219:sendIQ'><query xmlns='https://xabber.com/protocol/groups#members' version='0'/></iq>
    public final func requestUsers(_ xmppStream: XMPPStream, groupchat: String, userId: String? = nil) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: xmlns("members"))
        if let userId = userId {
            if userId == "" {
                self.queueItems.insert(QueueItem(.userCard, elementId: elementId, value: "my-card"))
            }
            query.addAttribute(withName: "id", stringValue: userId)
        } else {
            do {
                let realm = try  WRealm.safe()
                if let version = realm
                    .object(ofType: GroupChatStorageItem.self,
                            forPrimaryKey: [groupchat, owner].prp())?
                    .usersListVersion {
                    query.addAttribute(withName: "version", stringValue: version)
                } else {
                    query.addAttribute(withName: "version", stringValue: "0")
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: query))
        self.queryIds.insert(elementId)
    }
    
    public final func requestDefaltRightsForm(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ([[String: Any]]?, String?) -> Void) -> String {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "query",
                                                   xmlns: xmlns("default-rights"))))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.requestForm, elementId: elementId, settingsCallback: callback))
        return elementId
    }
    
    public final func requestChatSettingsForm(_ xmppStream: XMPPStream, groupchat: String, callback: (([[String: Any]]?, String?) -> Void)?) -> String {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "query",
                                                   xmlns: getPrimaryNamespace())))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.requestForm, elementId: elementId, settingsCallback: callback))
        return elementId
    }
    
    public final func requestChatStatusForm(_ xmppStream: XMPPStream, groupchat: String, callback: (([[String: Any]]?, String?) -> Void)?) -> String {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "query",
                                                   xmlns: xmlns("status"))))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.requestForm, elementId: elementId, settingsCallback: callback))
        return elementId
    }
    
    public final func requestMyRights(_ xmppStream: XMPPStream, groupchat: String, callback: (([[String: Any]]?, [[String: Any]]?, [[String: Any]]?, String?) -> Void)? = nil) -> String {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: xmlns("rights"))
        let user = DDXMLElement(name: "user", xmlns: getPrimaryNamespace())
        user.addAttribute(withName: "id", stringValue: "")
        query.addChild(user)
        xmppStream.send(XMPPIQ(iqType: .get, to: fullJid(groupchat), elementID: elementId, child: query))
        self.queryIds.insert(elementId)
        queueItems.insert(QueueItem(.requestForm, elementId: elementId, formCallback: callback))
        return elementId
    }
    
    public final func requestEditUserForm(_ xmppStream: XMPPStream, groupchat: String, userId: String, callback: @escaping ([[String: Any]]?, [[String: Any]]?, [[String: Any]]?, String?) -> Void) -> String {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: xmlns("rights"))
        let user = DDXMLElement(name: "user", xmlns: getPrimaryNamespace())
        user.addAttribute(withName: "id", stringValue: userId)
        query.addChild(user)
        xmppStream.send(XMPPIQ(iqType: .get, to: fullJid(groupchat), elementID: elementId, child: query))
        self.queryIds.insert(elementId)
        queueItems.insert(QueueItem(.requestForm, elementId: elementId, formCallback: callback))
        return elementId
    }
    
    public final func updateForm(_ xmppStream: XMPPStream, formType: FormType, groupchat: String, userData: [[String: Any]], callback: @escaping ((String?) -> Void)) -> String {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query")
        switch formType {
        case .settings:
            query.setXmlns(getPrimaryNamespace())
        case .defaultRights:
            query.setXmlns(xmlns("default-rights"))
        case .userRights:
            query.setXmlns(xmlns("rights"))
        case .status:
            query.setXmlns(xmlns("status"))
        }
        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        x.addAttribute(withName: "type", stringValue: "submit")
        for item in userData {
            let field = DDXMLElement(name: "field")
            if let type = item["type"] as? String {
                field.addAttribute(withName: "type", stringValue: type)
            }
            if let varName = item["var"] as? String {
                field.addAttribute(withName: "var", stringValue: varName)
            }
            if let label = item["label"] as? String {
                field.addAttribute(withName: "label", stringValue: label)
            }
            if let values = item["values"] as? [String] {
                values.forEach { field.addChild(DDXMLElement(name: "value", stringValue: $0)) }
            }
            if let value = item["value"] as? String {
                if value.isNotEmpty {
                    field.addChild(DDXMLElement(name: "value", stringValue: value))
                }
            }
            x.addChild(field)
        }
        query.addChild(x)
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.updateForm, elementId: elementId, callback: callback, value: "save"))
        return elementId
    }
    
    public final func blockList(_ xmppStream: XMPPStream, groupchat: String) {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "query",
                                                   xmlns: xmlns("block"))))
        queryIds.insert(elementId)
    }
    
    public final func kickUser(_ xmppStream: XMPPStream, groupchat: String, userId: String, callback: ((String?) -> Void)?) {
        let elementId = xmppStream.generateUUID
        let kick = DDXMLElement(name: "kick", xmlns: getPrimaryNamespace())
        kick.addChild(DDXMLElement(name: "id", stringValue: userId))
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: kick))
        queueItems.insert(QueueItem(.kick, elementId: elementId, callback: callback))
        queryIds.insert(elementId)
    }
    
    public final func blockUser(_ xmppStream: XMPPStream, groupchat: String, ids: [String] = [], jids: [String] = [], domains: [String] = [], callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let block = DDXMLElement(name: "block", xmlns: xmlns("block"))
        ids.forEach { block.addChild(DDXMLElement(name: "id", stringValue: $0)) }
        jids.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        domains.forEach { block.addChild(DDXMLElement(name: "domain", stringValue: $0)) }
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: block))
        queryIds.insert(elementId)
        var toBlock: [[String: String]] = []
        toBlock.append(contentsOf: ids.compactMap { return ["type": "id", "value": $0] })
        toBlock.append(contentsOf: jids.compactMap { return ["type": "jid", "value": $0] })
        toBlock.append(contentsOf: domains.compactMap { return ["type": "domain", "value": $0] })
        queueItems.insert(QueueItem(.block, elementId: elementId, callback: callback, payload: toBlock))
    }
    
    public final func unblockUser(_ xmppStream: XMPPStream, groupchat: String, ids: [String] = [], jids: [String] = [], domains: [String] = [], callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let block = DDXMLElement(name: "unblock", xmlns: xmlns("block"))
        ids.forEach { block.addChild(DDXMLElement(name: "id", stringValue: $0)) }
        jids.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        domains.forEach { block.addChild(DDXMLElement(name: "domain", stringValue: $0)) }
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: block))
        queryIds.insert(elementId)
        var toUnblock: [[String: String]] = []
        toUnblock.append(contentsOf: ids.compactMap { return ["type": "id", "value": $0] })
        toUnblock.append(contentsOf: jids.compactMap { return ["type": "jid", "value": $0] })
        toUnblock.append(contentsOf: domains.compactMap { return ["type": "domain", "value": $0] })
        queueItems.insert(QueueItem(.unblock, elementId: elementId, callback: callback, payload: toUnblock))
    }
    
    public final func unpinMessage(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ((String?) -> Void)) {
        pinMessage(xmppStream, groupchat: groupchat, message: "0", callback: callback)
    }
    
    public final func pinMessage(_ xmppStream: XMPPStream, groupchat: String, message stanzaId: String, callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        let update = DDXMLElement(name: "update", xmlns: getPrimaryNamespace())
        update.addChild(DDXMLElement(name: "pinned-message", stringValue: stanzaId))
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: update))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.pin, elementId: elementId, callback: callback))
    }
    
    public final func requestPinnedMessage(_ xmppStream: XMPPStream, groupchat: String, message stanzaId: String) {
        do {
            let realm = try  WRealm.safe()
            if realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND archivedId == %@",
                        owner,
                        groupchat,
                        stanzaId)
                .first != nil {
                return
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
//        TODO
//        AccountManager
//            .shared
//            .find(for: owner)?
//            .mam
//            .requestMessageByStanzaId(xmppStream,
//                                      groupchat: groupchat,
//                                      stanzaId: stanzaId)
    }
    
    public final func publishAvatar(_ xmppStream: XMPPStream, groupchat: String, groupAvatar: Bool, userId: String = "", image: UIImage?, callback: @escaping ((String?) -> Void)) {
        let elementId = xmppStream.generateUUID
        if let image = image {
            let jpegData = image.jpegData(compressionQuality: 0.7)
            let hash = jpegData?.sha1().toHexString() ?? ""
            
            if groupAvatar {
//                DefaultAvatarManager.shared.storeAvatar(jid: groupchat, owner: owner, hash: hash, images: [DefaultAvatarManager.SizedImage(image: image, size: .original)], kind: .xabber)
            } else {
                do {
                    let realm = try  WRealm.safe()
                    var effectiveUserID = userId
                    if userId.isEmpty {
                        effectiveUserID = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isMe == true", [groupchat, owner].prp()).first?.userId ?? ""
                    }
//                    DefaultAvatarManager.shared.storeGroupAvatar(user: effectiveUserID, jid: groupchat, owner: owner, hash: hash, images: [DefaultAvatarManager.SizedImage(image: image, size: .original)], kind: .xabber)
                } catch {
                    DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
                }
            }
            
            let binval = image.toBase64(.jpeg(0.7))
            let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
            let publish = DDXMLElement(name: "publish")
            if groupAvatar {
                publish.addAttribute(withName: "node", stringValue: "urn:xmpp:avatar:data")
            } else {
                publish.addAttribute(withName: "node", stringValue: ["urn:xmpp:avatar:data", userId].joined(separator: "#"))
            }
            
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "id", stringValue: hash)
            let data = DDXMLElement(name: "data", xmlns: "urn:xmpp:avatar:data")
            data.stringValue = binval
            item.addChild(data)
            publish.addChild(item)
            pubsub.addChild(publish)
            xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat)?.bareJID, elementID: elementId, child: pubsub))
            queryIds.insert(elementId)
            queueItems.insert(QueueItem(.publishAvatar,
                                        elementId: elementId,
                                        callback: callback,
                                        payload: [["bytes": "\(jpegData?.count ?? 0)",
                                                   "id": hash,
                                                   "type": "image/jpeg",
                                                   "userId": userId]],
                                        value: groupAvatar ? "groupchat" : "member"))
        } else {
            let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
            let publish = DDXMLElement(name: "publish")
            publish.addAttribute(withName: "node", stringValue: ["urn:xmpp:avatar:metadata", userId].joined(separator: "#"))
            let item = DDXMLElement(name: "item")
            item.addChild(DDXMLElement(name: "metadata", xmlns: "urn:xmpp:avatar:metadata"))
            publish.addChild(item)
            pubsub.addChild(publish)
            xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat)?.bareJID, elementID: elementId, child: pubsub))
            queryIds.insert(elementId)
            queueItems.insert(QueueItem(.resetAvatar, elementId: elementId, callback: callback))
            if groupAvatar {
//                DefaultAvatarManager.shared.deleteAvatar(jid: groupchat, owner: owner)
            } else {
                do {
                    let realm = try  WRealm.safe()
                    if userId.isNotEmpty {
//                        DefaultAvatarManager.shared.deleteGroupAvatar(user: userId, jid: groupchat, owner: owner)
                    } else if let userId = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isMe == true", [groupchat, owner].prp()).first?.userId {
//                        DefaultAvatarManager.shared.deleteGroupAvatar(user: userId, jid: groupchat, owner: owner)
                    }
                } catch {
                    DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
                }
            }
        }
    }
    
    private final func publishAvatarMetadata(_ xmppStream: XMPPStream, elementId: String, groupchat: String) {
        if let item = queueItems.first(where: { $0.elementId == elementId }),
            let bytes = item.payload.first?["bytes"],
            let imageId = item.payload.first?["id"],
            let mimeType = item.payload.first?["type"],
            let userId = item.payload.first?["userId"] {
            let elementId = xmppStream.generateUUID
            let info = DDXMLElement(name: "info")
            info.addAttribute(withName: "bytes", stringValue: bytes)
            info.addAttribute(withName: "id", stringValue: imageId)
            info.addAttribute(withName: "type", stringValue: mimeType)
            let metadata = DDXMLElement(name: "metadata", xmlns: "urn:xmpp:avatar:metadata")
            let itemXml = DDXMLElement(name: "item")
            itemXml.addAttribute(withName: "id", stringValue: imageId)
            let publish = DDXMLElement(name: "publish")
            if item.value == "groupchat" {
                publish.addAttribute(withName: "node", stringValue: "urn:xmpp:avatar:metadata")
            } else {
                publish.addAttribute(withName: "node", stringValue: ["urn:xmpp:avatar:metadata", userId].joined(separator: "#"))
            }
            let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
            metadata.addChild(info)
            itemXml.addChild(metadata)
            publish.addChild(itemXml)
            pubsub.addChild(publish)
            xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat)?.bareJID, elementID: elementId, child: pubsub))
            item.elementId = elementId
            item.action = .publishAvatarMeta
            queryIds.insert(elementId)
        }
    }
    
    private final func onEditDefaultRightsForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query", xmlns: xmlns("default-rights")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "form" else {
            return false
        }
        queryIds.remove(elementId)
        var out: [[String: Any]] = []
        x.elements(forName: "field").forEach {
            field in
            var item: [String: Any] = [:]
            if let varName = field.attributeStringValue(forName: "var") {
                item["var"] = varName
            }
            if let type = field.attributeStringValue(forName: "type") {
                item["type"] = type
            }
            if let label = field.attributeStringValue(forName: "label") {
                item["label"] = label
            }
            if let value = field.element(forName: "value")?.stringValue {
                item["value"] = value
            }
            item["values"] = field.elements(forName: "option").compactMap {
                return ["label": $0.attributeStringValue(forName: "label"), "value": $0.stringValue]
            }
            out.append(item)
        }
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.settingsCallback?(out, nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onEditChatSettingsForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let from = iq.from?.bare,
            let query = iq.element(forName: "query", xmlns: getPrimaryNamespace()),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "form" else {
            return false
        }
        updateStatusStateFromForm(iq)
        queryIds.remove(elementId)
        var out: [[String: Any]] = []
        x.elements(forName: "field").forEach {
            field in
            var item: [String: Any] = [:]
            if let varName = field.attributeStringValue(forName: "var") {
                item["var"] = varName
            }
            if let type = field.attributeStringValue(forName: "type") {
                item["type"] = type
            }
            if let label = field.attributeStringValue(forName: "label") {
                item["label"] = label
            }
            if field.elements(forName: "value").count > 1 {
                item["values"] = field.elements(forName: "value").compactMap { return $0.stringValue }
            } else {
                if let value = field.element(forName: "value")?.stringValue {
                    item["value"] = value
                }
            }
            if field.elements(forName: "option").isNotEmpty {
                item["options"] = field.elements(forName: "option").compactMap { return ["label": $0.attributeStringValue(forName: "label"), "value": $0.element(forName: "value")?.stringValue ?? ""] }
            }
            out.append(item)
        }
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.settingsCallback?(out, nil)
            queueItems.remove(item)
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [self.owner, from].prp()) {
                try realm.write {
                    instance.defaultRestrictions.removeAll()
                    instance.defaultRestrictions.append(objectsIn: out.compactMap { return $0["label"] as? String })
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private final func onEditStatusForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query", xmlns: xmlns("status")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "form",
            let item = queueItems.first(where: { $0.elementId == elementId }),
            item.value != "save" else {
            return false
        }
        updateStatusStateFromForm(iq)
        queryIds.remove(elementId)
        var out: [[String: Any]] = []
        x.elements(forName: "field").forEach {
            field in
            var item: [String: Any] = [:]
            if let varName = field.attributeStringValue(forName: "var"),
                varName == "status" {
                item["var"] = varName
                if let value = field.element(forName: "value")?.stringValue {
                    item["value"] = value
                }
                item["type"] = "list-single"
                if let label = field.attributeStringValue(forName: "label") {
                    item["label"] = label
                }
                if field.elements(forName: "option").isNotEmpty {
                    let options: [[String: String]] = field
                        .elements(forName: "option")
                        .compactMap { item in
                            guard let label = item.attributeStringValue(forName: "label"),
                                let value = item.element(forName: "value")?.stringValue,
                                let description = x
                                    .elements(forName: "field")
                                    .first(where: { $0.attributeStringValue(forName: "var") == value })?
                                    .element(forName: "desc")?
                                    .stringValue,
                                let show_status = x
                                    .elements(forName: "field")
                                    .first(where: { $0.attributeStringValue(forName: "var") == value })?
                                    .element(forName: "value")?
                                    .stringValue else {
                                return nil
                            }
                            return [
                                "label": label,
                                "value": value,
                                "description": description,
                                "show_status": show_status
                            ]
                    }
                    item["options"] = options
                }
            }
            out.append(item)
        }
        item.settingsCallback?(out, nil)
        queueItems.remove(item)
        return true
    }
    
    private final func onUpdateOwnRights(_ iq: XMPPIQ) -> Bool {
        guard let from = iq.from?.bare,
            let query = iq.element(forName: "query", xmlns: xmlns("rights")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "form" else {
            return false
        }
        if let userId = x.elements(forName: "field").first(where: { $0.attributeStringValue(forName: "var") == "user-id" })?.element(forName: "value"),
            userId.stringValue == "" {
            do {
                let realm = try  WRealm.safe()
                if let instance = realm.object(ofType: GroupChatStorageItem.self,
                                               forPrimaryKey: [from, owner].prp()) {
                    try realm.write {
                        instance.canInvite = true
                        instance.canChangeSettings = false
                        instance.canChangeUsersSettings = false
                        instance.canChangeNicknames = false
                        instance.canChangeBadge = false
                        instance.canBlockUsers = false
                        instance.canChangeAvatars = false
                        instance.canDeleteMessages = false
                        
                        x.elements(forName: "field").forEach {
                            element in
                            let fieldName = element.attributeStringValue(forName: "var", withDefaultValue: "none")
                            guard let value = element.element(forName: "value")?.stringValue,
                                value.isNotEmpty else { return }
                            switch fieldName {
                                case "owner":
                                    instance.canInvite = true
                                    instance.canChangeSettings = true
                                    instance.canChangeUsersSettings = true
                                    instance.canChangeNicknames = true
                                    instance.canChangeBadge = true
                                    instance.canBlockUsers = true
                                    instance.canChangeAvatars = true
                                    instance.canDeleteMessages = true
                                case "restrict-participants":
                                    instance.canChangeNicknames = true
                                    instance.canChangeBadge = true
                                    instance.canChangeUsersSettings = true
                                    instance.canBlockUsers = true
                                case "block-participants":
                                    instance.canBlockUsers = true
                                case "administrator":
                                    instance.canChangeSettings = true
                                    instance.canChangeUsersSettings = true
                                    instance.canChangeNicknames = true
                                    instance.canChangeBadge = true
                                    instance.canBlockUsers = true
                                    instance.canChangeAvatars = true
                                case "change-badges":
                                    instance.canChangeBadge = true
                                case "change-nicknames":
                                    instance.canChangeNicknames = true
                                case "delete-messages":
                                    instance.canDeleteMessages = true
                                case "send-invitations":
                                    instance.canInvite = false
                                    break
                            default: break
                            }
                        }
                    }
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
            return true
        }
        return false
    }
    
    private final func onEditUserForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query", xmlns: xmlns("rights")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "form" else {
            return false
        }
        
        _ = onUpdateOwnRights(iq)
        var isPermission: Bool = true
        var out: [[String: Any]] = []
        var permissions: [[String: Any]] = []
        var restrictions: [[String: Any]] = []
        x.elements(forName: "field").forEach {
            field in
            if  isPermission
                && field.attributeStringValue(forName: "type") == "fixed"
                && field.attributeStringValue(forName: "var") == "restriction" {
                isPermission = false
            }
            var item: [String: Any] = [:]
            if let varName = field.attributeStringValue(forName: "var") {
                item["var"] = varName
            }
            if let type = field.attributeStringValue(forName: "type") {
                item["type"] = type
            }
            if let label = field.attributeStringValue(forName: "label") {
                item["label"] = label
            }
            if let value = field.element(forName: "value")?.stringValue {
                item["value"] = value
            }
            item["values"] = field.elements(forName: "option").compactMap {
                return ["label": $0.attributeStringValue(forName: "label"), "value": $0.stringValue]}
            if isPermission {
                permissions.append(item)
            } else {
                restrictions.append(item)
            }
            out.append(item)
        }
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.formCallback?(out, permissions, restrictions, nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onSuccessDefaultRightsUpdatedForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query",
                                   xmlns: xmlns("default-rights")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "result" else {
            return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onSuccessSettingsUpdatedForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query",
                                   xmlns: getPrimaryNamespace()),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "result" else {
            return false
        }
        queryIds.remove(elementId)
        
        updateStatusStateFromForm(iq)
        
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onSuccessStatusUpdatedForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query",
                                   xmlns: xmlns("status")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "form",
            let item = queueItems.first(where: { $0.elementId == elementId }),
            item.value == "save" else {
            return false
        }
        queryIds.remove(elementId)
        
        updateStatusStateFromForm(iq)
        
        item.callback?(nil)
        queueItems.remove(item)
        
        return true
    }
    
    private final func updateStatusStateFromForm(_ iq: XMPPIQ) {
        guard let from = iq.from?.bare else { return }
        
        if let statusField = iq.element(forName: "query", xmlns: getPrimaryNamespace())?
            .element(forName: "x", xmlns: "jabber:x:data")?
            .elements(forName: "field")
            .first(where: { $0.attributeStringValue(forName: "var") == "status" }) {
            
            guard let statusValue = statusField.element(forName: "value")?.stringValue,
                  let statusMessageValue = statusField
                    .elements(forName: "option")
                    .first(where: { $0.element(forName: "value")?.stringValue == statusValue })?
                    .attributeStringValue(forName: "label") else {
                return
            }
            
            do {
                let realm = try  WRealm.safe()
                let collection = realm
                    .objects(ResourceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, from)
                try realm.write {
                    collection.forEach {
                        $0.isTemporary = false
                        $0.status_ = statusValue
                        $0.statusMessage = statusMessageValue
                    }
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    private final func onSuccessUserUpdatedForm(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let query = iq.element(forName: "query",
                                   xmlns: xmlns("rights")),
            let x = query.element(forName: "x", xmlns: "jabber:x:data"),
            x.attributeStringValue(forName: "type", withDefaultValue: "none") == "result" else {
            return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onInfo(_ presence: XMPPPresence) -> Bool {
        guard let from = presence.from?.bare,
            let x = presence.element(forName: "x", xmlns: getPrimaryNamespace()) else {
            return false
        }
        let resource: String = presence.from?.resource ?? "groupchat"
        
        func update(_ instance: GroupChatStorageItem) {
            if instance.isInvalidated { return }
            instance.name = x.element(forName: "name")?.stringValue ?? instance.name
            instance.privacy_ = x.element(forName: "privacy")?.stringValue ?? instance.privacy_
            instance.index_ = x.element(forName: "index")?.stringValue ?? instance.index_
            instance.membership_ = x.element(forName: "membership")?.stringValue ?? instance.membership_
            instance.descr = x.element(forName: "description")?.stringValue ?? instance.descr
            instance.members = x.attributeIntegerValue(forName: "members", withDefaultValue: instance.members)
            instance.status = x.element(forName: "status")?.stringValue ?? ""
            if let pinnedMessage = x.element(forName: "pinned-message")?.stringValue {
                if pinnedMessage != "0" {
                    if instance.pinnedMessage != pinnedMessage {
                        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                            user.groupchats.requestPinnedMessage(stream, groupchat: from, message: pinnedMessage)
                        })
                        instance.pinnedMessage = pinnedMessage
                    }
                } else {
                    instance.pinnedMessage = ""
                }
            }
            if let members = x.element(forName: "members") {
                instance.members = members.stringValueAsNSInteger()
            }
            if let present = x.element(forName: "present") {
                instance.present = present.stringValueAsNSInteger()
            }
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self,
                                           forPrimaryKey: [from, owner].prp()) {
                try realm.write {
                    if instance.isInvalidated { return }
                    update(instance)
                }
            } else {
                let instance = GroupChatStorageItem()
                instance.jid = from
                instance.owner = owner
                instance.primary = GroupChatStorageItem.genPrimary(jid: from, owner: owner)
                update(instance)
                try realm.write {
                    if instance.isInvalidated { return }
                    realm.add(instance, update: .modified)
                }
            }
            if let name = x.element(forName: "name")?.stringValue,
                let instance = realm.object(ofType: RosterStorageItem.self,
                                            forPrimaryKey: [from, owner].prp()) {
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.username = name
                }
            }
            
            
            if let instnace = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: from,
                    owner: owner,
                    conversationType: .group
                )
            ) {
                if instnace.conversationType != .group {
                    try realm.write {
                        instnace.conversationType = .group
                    }
                }
            }
            
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                                           forPrimaryKey: [from, resource, owner].prp())  {
                try realm.write {
                    if instance.isInvalidated { return }
                    
                    if presence.attributeStringValue(forName: "type") == "unavailable" {
                        if presence.presenceType == .subscribe {
                            instance.status = .online
                        } else {
                            instance.status = .offline
                        }
                    } else if let statusValue = presence.element(forName: "show")?.stringValue {
                        instance.status = RosterUtils.shared.convertShowStatus(statusValue)
                    } else {
                        instance.status = .online
                    }
                    
                    instance.timestamp = Date()
                    
                    instance.statusMessage = presence.element(forName: "status")?.stringValue ?? ""
                    
                    if x.element(forName: "parent-chat") != nil {
                        instance.entity = .privateChat
                    } else if x.element(forName: "privacy")?.stringValue == "incognito" {
                        instance.entity = .incognitoChat
                    } else if x.element(forName: "privacy")?.stringValue == "public" {
                        instance.entity = .groupchat
                    } else {
                        instance.entity = .groupchat
                    }
                    
                    instance.type = .groupchat
                }
                
            } else {
                let instance = ResourceStorageItem()
                instance.owner = owner
                instance.jid = from
                instance.resource = resource
                if let statusValue = x.element(forName: "show")?.stringValue {
                    instance.status = RosterUtils.shared.convertShowStatus(statusValue)
                } else {
                    instance.status = .online
                }
                if x.element(forName: "parent-chat") != nil {
                    instance.entity = .privateChat
                } else if x.element(forName: "privacy")?.stringValue == "incognito" {
                    instance.entity = .incognitoChat
                } else if x.element(forName: "privacy")?.stringValue == "public" {
                    instance.entity = .groupchat
                }
                instance.type = .groupchat
                instance.isTemporary = false
                instance.primary = ResourceStorageItem.genPrimary(jid: from, owner: owner, resource: resource)
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            if let authMessage = realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: MessageStorageItem.genPrimary(
                    messageId: MessageStorageItem.messageIdForAuthRequest(jid: from),
                    owner: self.owner
                )
            ) {
                try realm.write {
                    realm.delete(authMessage)
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private final func onSubscribe(_ xmppStream: XMPPStream, presence: XMPPPresence) -> Bool {
        guard let jid = presence.from?.bare,
            jid.isNotEmpty,
            let item = queueItems.first(where: { [[jid, "create"].prp(),
                                                  [jid, "join"].prp(),
                                    [jid, "cancel_join"].prp()]
            .contains($0.elementId) }),
            let presenceType = presence.presenceType else {
                return false
        }
        switch presenceType {
        case .subscribe:
            item.callback?(nil)
            if item.elementId != [jid, "create"].prp() {
                queueItems.remove(item)
                xmppStream.send(XMPPPresence(to: XMPPJID(string: jid)))
            }
            _ = self.onInfo(presence)
        case .subscribed:
            xmppStream.send(XMPPPresence(type: .subscribed, to: XMPPJID(string: jid)))
            do {
                let realm = try  WRealm.safe()
                if realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: .group
                    )
                ) == nil,
                    let rosterItem = realm.object(ofType: RosterStorageItem.self,
                                                  forPrimaryKey: [jid, owner].prp()),
                    let groupchatItem = realm.object(ofType: GroupChatStorageItem.self,
                                                     forPrimaryKey: [jid, owner].prp()) {
                    print("OOOOO2", #function, jid, "group")
                    let instance = LastChatsStorageItem()
                    instance.jid = jid
                    instance.setPrimary(withOwner: owner)
                    instance.rosterItem = rosterItem
                    instance.isSynced = true
                    instance.chatState = .none
                    instance.conversationType = .group
                    instance.messageDate = Date()
                    try realm.write {
                        if rosterItem.isInvalidated { return }
                        rosterItem.customUsername = groupchatItem.name
                        realm.add(instance, update: .modified)
                    }
//                    AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//                        user.groupchats.requestUsers(stream, groupchat: jid)
//                        _ = user.mam.requestHistory(
//                            stream,
//                            to: jid,
//                            jid: nil,
//                            count: 10,
//                            start: nil,
//                            end: nil,
//                            after: nil,
//                            before: ""
//                        )
//                    })
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        case .unsubscribe:
            xmppStream.send(XMPPPresence(type: .unsubscribed, to: XMPPJID(string: jid)))
            item.callback?("error")
            queueItems.remove(item)
        default: return false
        }
        return true
    }
    
    private final func onCreate(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            let query = iq.element(forName: "query", xmlns: xmlns("create")),
            queryIds.contains(elementId),
            let from = iq.from?.domain,
            iq.element(forName: "error") == nil else {
            return false
        }
        
        var unwrappedJid: String? = query.element(forName: "jid")?.stringValue
        if unwrappedJid == nil {
            if let localPart = query.element(forName: "localpart")?.stringValue {
                unwrappedJid = XMPPJID(string: [localPart, from].joined(separator: "@"))?.bare
            }
        }
        
        guard let jid = unwrappedJid else { return false }
        
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            if item.value == "peer-to-peer" {
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                    user.groupchats.join(stream, uiConnection: false, groupchat: jid) { (nil) in
                        
                    }
                })
            }
            item.callback?("success")
            queueItems.remove(item)
        }
        
        queueItems.insert(QueueItem(.join, elementId: [jid, "create"].prp(), callback: nil))
        AccountManager.shared.find(for: owner)?.unsafeAction({ (user, stream) in
            user.roster.setContact(stream, jid: jid, nickname: query.element(forName: "name")?.stringValue)
            stream.send(XMPPPresence(type: .subscribe, to: XMPPJID(string: jid)))
            stream.send(XMPPPresence(type: .subscribed, to: XMPPJID(string: jid)))
        })
        do {
            let realm = try  WRealm.safe()
            if realm.object(ofType: GroupChatStorageItem.self,
                            forPrimaryKey: [jid, owner].prp()) == nil {
                let instance = GroupChatStorageItem()
                instance.primary = GroupChatStorageItem.genPrimary(jid: jid, owner: owner)
                instance.jid = jid
                instance.owner = owner
                if let name = query.element(forName: "name")?.stringValue {
                    instance.name = name
                }
                if let privacy = query.element(forName: "privacy")?.stringValue {
                    instance.privacy_ = privacy
                }
                if let index = query.element(forName: "index")?.stringValue {
                    instance.index_ = index
                }
                if let membership = query.element(forName: "membership")?.stringValue {
                    instance.membership_ = membership
                }
                if let descr = query.element(forName: "description")?.stringValue {
                    instance.descr = descr
                }
                
                let initialMessageInstance = MessageStorageItem()
                initialMessageInstance.configureInitialMessage(
                    owner,
                    opponent: jid,
                    conversationType: .group,
                    text: "",
                    date: Date(),
                    isRead: true
                )
                switch instance.privacy {
                case .publicChat:
                    initialMessageInstance.legacyBody = "Group \(instance.name) created".localizeString(id: "chat_group_created", arguments: ["\(instance.name)"])
                case .incognito:
                    initialMessageInstance.legacyBody = "Incognito group \(instance.name) created".localizeString(id: "chat_incognito_group_created", arguments: ["\(instance.name)"])
                default: break
                }
                initialMessageInstance.isDeleted = false
                if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessageInstance.primary) != nil {
                    try realm.write {
                        realm.add(instance, update: .modified)
                    }
                } else {
                    try realm.write {
                        realm.add(instance, update: .modified)
                        _ = initialMessageInstance.save(commitTransaction: false)
                    }
                }
                
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            return false
        }
        return true
    }
    
    private final func onSuccess(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onError(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            iq.iqType == .error,
            let error = iq.element(forName: "error") else {
                return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            if item.value == "peer-to-peer" {
                if let jid = iq.element(forName: "x", xmlns: getPrimaryNamespace())?.element(forName: "jid")?.stringValue {
                    DispatchQueue.main.async {
                        getAppTabBar()?.displayChat(
                            owner: self.owner,
                            jid: jid,
                            entity: .privateChat,
                            conversationType: .group
                        )
                    }
                }
            }
            switch item.action {
            case .requestForm:
                item.formCallback?(nil, nil, nil, "error")
                item.settingsCallback?(nil, "error")
            default:
                if error.element(forName: "conflict") != nil {
                    item.callback?("conflict")
                    item.invitesCallback?(item.value, "conflict")
                } else if error.element(forName: "not-allowed") != nil {
                    item.callback?("not-allowed")
                    item.invitesCallback?(item.value, "not-allowed")
                } else {
                    item.callback?("error")
                    item.invitesCallback?(item.value, "error")
                }
            }
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onUser(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let from = iq.from?.bare,
            let query = iq.element(forName: "query", xmlns: xmlns("members")) else {
                return false
        }
        queryIds.remove(elementId)
        let isMyCard = queueItems.first(where: { $0.elementId == elementId })?.value == "my-card"
        let version: String? = query.attributeStringValue(forName: "version")
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                query
                    .elements(forName: "user")
                    .forEach({
                        _ = updateUserCard($0,
                                           myCard: isMyCard ? true : nil,
                                           groupchat: from,
                                           trustedSource: true,
                                           messageAction: nil,
                                           commitTransaction: false)
                        
                    })
                if let version = version {
                    realm
                        .object(ofType: GroupChatStorageItem.self,
                                forPrimaryKey: [from, owner].prp())?
                        .usersListVersion = version
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    public final func updateUserCard(_ card: DDXMLElement, myCard: Bool? = nil, groupchat: String, trustedSource: Bool, messageAction: String?, commitTransaction: Bool, cardDate: Date = Date()) -> GroupchatUserStorageItem? {
        guard let id = card.attributeStringValue(forName: "id") else { return  nil }
        func transaction(_ commit: Bool, transaction: (() -> Void)) {
            do {
                let realm = try  WRealm.safe()
                if commit {
                    try realm.write {
                        transaction()
                    }
                } else {
                    transaction()
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        func update(_ instance: GroupchatUserStorageItem) {
            
            instance.jid = card.element(forName: "jid")?.stringValue ?? instance.jid
            if let myCard = myCard {
                instance.isMe = myCard
            } else {
                instance.isMe = instance.jid == owner
            }
            
            instance.nickname = card.element(forName: "nickname")?.stringValue ?? instance.nickname
            instance.role_ = card.element(forName: "role")?.stringValue ?? instance.role_
            instance.subscribtion_ = card.element(forName: "subscription")?.stringValue ?? instance.subscribtion_
            instance.permissions = card.elements(forName: "permission").compactMap { return $0.attributesAsDictionary()}
            instance.restrictions = card.elements(forName: "restriction").compactMap { return $0.attributesAsDictionary()}
            
            instance.isTemporary = !trustedSource
            
            if let subscribtion = card.element(forName: "subscription")?.stringValue {
                switch subscribtion {
                case "none": instance.isKicked = true
                case "both": instance.isKicked = false
                default: instance.isKicked = false
                }
            } else {
                instance.isKicked = false
            }
            
            if messageAction == "block" {
                instance.isBlocked = true
                if AccountManager.shared.find(for: owner)?.syncManager.isSynced() ?? true {
                    AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                        user.groupchats.blockList(stream, groupchat: groupchat)
                    })
                }
            }
            
            switch instance.role {
            case .owner: instance.sortedRole = GroupchatUserStorageItem.IntegerRole.owner.rawValue
            case .admin: instance.sortedRole = GroupchatUserStorageItem.IntegerRole.admin.rawValue
            case .member: instance.sortedRole = GroupchatUserStorageItem.IntegerRole.member.rawValue
            }
            instance.badge = card.element(forName: "badge")?.stringValue ?? instance.badge
            if let present = card.element(forName: "present") {
                if let timestamp = present.stringValue {
                    instance.lastSeen = timestamp.xmppDate
                    instance.isOnline = timestamp == "now" ? true : false
                } else {
                    instance.isOnline = false
                }
            } else {
                instance.isOnline = true
            }
            if AccountManager.shared.find(for: owner)?.syncManager.isSynced() ?? true {
                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                    _ = user.avatarManager.readFromUserCard(groupchat: groupchat, user: card)
                })
            }
            instance.updateTimestamp = cardDate
        }
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                           forPrimaryKey: [id, groupchat, owner].prp()) {
                if instance.updateTimestamp < cardDate {
                    transaction(commitTransaction) {
                        update(instance)
                    }
                }
                return instance
            } else {
                let instance = GroupchatUserStorageItem()
                instance.userId = id
                instance.owner = owner
                instance.groupchatId = [groupchat, owner].prp()
                instance.primary = GroupchatUserStorageItem.genPrimary(id: id, groupchat: groupchat, owner: owner)
                update(instance)
                transaction(commitTransaction) {
                    realm.add(instance, update: .modified)
                }
                return instance
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
    private final func onPublishData(_ stream: XMPPStream, iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            queueItems.contains(where: { $0.elementId == elementId && $0.action == .publishAvatar }),
            let from = iq.from?.bare else {
                return false
        }
        queryIds.remove(elementId)
        self.publishAvatarMetadata(stream, elementId: elementId, groupchat: from)
        
        return true
    }
    
    private final func onPublishMetadata(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            queueItems.contains(where: { $0.elementId == elementId && $0.action == .publishAvatarMeta }) else {
                return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onResetAvatar(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            queueItems.contains(where: { $0.elementId == elementId && $0.action == .resetAvatar }) else {
                return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onRevoke(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            let from = iq.from?.bare,
            queryIds.contains(elementId),
            queueItems.contains(where: { $0.action == .revokeInvite && $0.elementId == elementId }) else {
                return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            do {
                let realm = try  WRealm.safe()
                if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [from, owner].prp()) {
                    if let index = instance.invited.index(of: item.value) {
                        try realm.write {
                            if instance.invited.count > index {
                                instance.invited.remove(at: index)
                            }
                        }
                    }
                }
                
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
            item.invitesCallback?(item.value, nil)
        }
        return true
    }
    
    private final func onSuccesInvite(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let queueItem = queueItems.first(where: { $0.elementId == elementId }),
            queueItem.action == .invite else {
                return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            let jid = item.value
            item.invitesCallback?(jid, nil)
            queueItems.remove(item)
        }
        
        return true
    }
    
    private final func onDelete(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            iq.elements(forName: "error").isEmpty,
            let from = iq.from?.bare,
            let item = queueItems.first(where: { $0.elementId == elementId }),
            item.action == .delete else {
                return false
        }
        queryIds.remove(elementId)
        item.callback?(nil)
        queueItems.remove(item)
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: from,
                        owner: owner,
                        conversationType: .group
                    )
                ) {
                    realm.delete(instance)
                }
                realm.delete(realm.objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@", owner, from))
                realm.delete(realm.objects(MessageReferenceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, from))
                realm.delete(realm.objects(CallMetadataStorageItem.self)
                    .filter("owner == %@ AND opponent == %@", owner, from))
                realm.delete(realm.objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@", [from, owner].prp()))
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private final func onBlockList(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            let from = iq.from?.bare,
            let query = iq.element(forName: "query", xmlns: xmlns("block")),
            queryIds.contains(elementId) else {
                return false
        }
        
        do {
            let realm = try  WRealm.safe()
            
            try realm.write {
                query.elements(forName: "user").forEach {
                    user in
                    guard let userId = user.stringValue else { return }
                    let jid = user.attributeStringValue(forName: "jid") ?? ""
                    if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                                   forPrimaryKey: [userId, from, owner].prp()) {
                        instance.isBlocked = true
                    } else {
                        let instance = GroupchatUserStorageItem()
                        instance.userId = userId
                        instance.groupchatId = [from, owner].prp()
                        instance.primary = GroupchatUserStorageItem.genPrimary(id: userId, groupchat: from, owner: owner)
                        instance.isBlocked = true
                        instance.nickname = jid
                        realm.add(instance)
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    private final func onBlock(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            iq.elements(forName: "error").isEmpty,
            let from = iq.from?.bare,
            let item = queueItems.first(where: { $0.elementId == elementId }),
            item.action == .block else {
                return false
        }
        queryIds.remove(elementId)
        
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@", [from, owner].prp())
                    .forEach { user in
                    item.payload.forEach {
                        if let value = $0["value"] {
                            if $0["type"] == "id" {
                                if user.userId == value {
                                    user.isBlocked = true
                                }
                            } else if $0["type"] == "jid" {
                                if user.jid == value {
                                    user.isBlocked = true
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        item.callback?(nil)
        queueItems.remove(item)
        return true
    }
    
    private final func onUnblock(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            iq.elements(forName: "error").isEmpty,
            let from = iq.from?.bare,
            let item = queueItems.first(where: { $0.elementId == elementId }),
            item.action == .unblock else {
                return false
        }
        
        queryIds.remove(elementId)

        do {
            let realm = try  WRealm.safe()
            try realm.write {
                realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@", [from, owner].prp())
                    .forEach { user in
                    item.payload.forEach {
                        if let value = $0["value"] {
                            if $0["type"] == "id" {
                                if user.userId == value {
                                    user.isBlocked = false
                                }
                            } else if $0["type"] == "jid" {
                                if user.jid == value {
                                    user.isBlocked = false
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        
        item.callback?(nil)
        
        return true
    }
    
    private final func onInviteList(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let from = iq.from?.bare,
            let query = iq.element(forName: "query", xmlns: xmlns("invite")) else {
                return false
        }
        queryIds.remove(elementId)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .object(ofType: GroupChatStorageItem.self,
                        forPrimaryKey: [from, owner].prp()) {
                try realm.write {
                    instance.invited.removeAll()
                    instance
                        .invited
                        .append(objectsIn: query
                                            .elements(forName: "user")
                                            .compactMap { return $0.attributeStringValue(forName: "jid")})
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    public final func isInvite(_ message: XMPPMessage) -> Bool {
        return message.element(forName: "invite", xmlns: xmlns("invite")) != nil
    }
    
    public final func readInvite(in message: XMPPMessage, date: Date, isRead: Bool?, commit: Bool = true) -> Bool {
        guard let invite = message.element(forName: "invite", xmlns: xmlns("invite")),
            let groupchat = invite.attributeStringValue(forName: "jid"),
            let elementId = getUniqueMessageId(message, owner: self.owner).isEmpty ? nil : getUniqueMessageId(message, owner: self.owner) else {
            return false
        }
        guard let from = message.from?.bare,
            from != owner,
            let to = message.to?.bare else {
            return true
        }
        do {
            let realm = try  WRealm.safe()
            
            var lastInviteDate: Date = Date(timeIntervalSince1970: 1)
            
            if let instance = realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner == %@ AND groupchat == %@", owner, groupchat)
                .sorted(byKeyPath: "date", ascending: false)
                .first {
                lastInviteDate = instance.date
                if instance.date < date {
                    if commit {
                        try realm.write {
                            instance.isRead = true
                        }
                    } else {
                        instance.isRead = true
                    }
                }
            }
            let instance = GroupchatInvitesStorageItem()
            instance.inviteId = elementId
            instance.owner = owner
            instance.primary = [elementId, owner].prp()
            instance.groupchat = groupchat
            instance.outgoing = from == owner
            instance.isRead = lastInviteDate < date ? isRead ?? (from == owner) : true
            instance.isProcessed = lastInviteDate <= date ? false : true// false
            instance.date = date
            instance.jid = from == owner ? to : from
            instance.temporary = true
            instance.isAnonymous = message
                .element(forName: "x", xmlns: getPrimaryNamespace())?
                .element(forName: "privacy")?
                .stringValue == "incognito"
            
            if let x = message.element(forName: "x", xmlns: getPrimaryNamespace()) {
                var entity: RosterItemEntity = .groupchat
                
                if x.element(forName: "parent-chat") != nil {
                    entity = .privateChat
                } else if x.element(forName: "privacy")?.stringValue == "incognito" {
                    entity = .incognitoChat
                }
                
                instance.entity = entity
                
                let resource = ResourceStorageItem()
                resource.owner = owner
                resource.jid = groupchat
                resource.resource = owner
                resource.status = .offline
                resource.entity = entity
                resource.type = .groupchat
                resource.priority = -5
                resource.isTemporary = true
                resource.primary = ResourceStorageItem.genPrimary(jid: groupchat, owner: owner, resource: owner)
                if commit {
                    try realm.write {
                        realm.add(resource, update: .all)
                    }
                } else {
                    realm.add(resource, update: .all)
                }
            }
            
            if commit {
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            } else {
                realm.add(instance, update: .modified)
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        if isRead != nil {
            self.onNewInvites(commitTransaction: commit)
        }
        return true
    }
    
    public final func getInvitesFallback() {
        if AccountManager.shared.find(for: owner)?.blocked.lastUpdate == nil {
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.blocked.requestBlockListAck(stream, callback: self.onInviteUpdate)
            })
        } else {
            self.onInviteUpdate()
        }
    }
    
    private final func onInviteUpdate() {
        do {
            let realm = try  WRealm.safe()
            let invites = realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner == %@ AND temporary == %@ AND outgoing == %@ AND isProcessed == %@", owner, true, false, false)
            let blocked = realm
                .objects(BlockStorageItem.self)
                .filter("owner == %@", owner)
                .compactMap { return XMPPJID(string: $0.jid) }
            try realm.write {
                invites.forEach {
                    item in
                    if let blockedItem = blocked.first(where: { $0.bare == item.groupchat }) {
                        if let resource = blockedItem.resource,
                            let timeInterval = TimeInterval(resource) {
                            item.isRead = timeInterval < item.date.timeIntervalSince1970
                            item.temporary = false
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func onNewInvites(commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            let unprocessedInvites = realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner == %@ AND isRead == %@ AND isProcessed == %@", owner, false, false)
            var query: [MessageStorageItem] = []
            for item in unprocessedInvites {
                let jid = item.groupchat
                let primary = item.primary
                
                if realm
                    .object(ofType: RosterStorageItem.self,
                            forPrimaryKey: [jid, owner].prp())?
                    .subscribtion == .both {
                    if commitTransaction {
                        try realm.write {
                            realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary)?.isProcessed = true
                        }
                    } else {
                        realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary)?.isProcessed = true
                    }
                    continue
                }
                if AccountManager.shared.find(for: owner)?.syncManager.isSynced() ?? true {
                    AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                        user.vcards.requestItem(stream, jid: jid)
                    })
                }
                
                let groupchatInstance = GroupChatStorageItem()
                groupchatInstance.owner = self.owner
                groupchatInstance.jid = jid
                groupchatInstance.privacy = item.isAnonymous ? .incognito : .publicChat
                groupchatInstance.primary = GroupChatStorageItem.genPrimary(jid: jid, owner: self.owner)
                
                if commitTransaction {
                    try realm.write {
                        realm.add(groupchatInstance, update: .modified)
                        if !item.isRead {
                            realm.delete(realm
                                .objects(MessageStorageItem.self)
                                .filter("owner == %@ AND opponent == %@", self.owner, jid))
                        }
                    }
                } else {
                    realm.add(groupchatInstance, update: .modified)
                    if !item.isRead {
                        realm.delete(realm
                            .objects(MessageStorageItem.self)
                            .filter("owner == %@ AND opponent == %@", self.owner, jid))
                    }
                }
                
                let entity: RosterItemEntity = item.entity
                let instance = MessageStorageItem()
                instance.configureInitialMessage(
                    item.owner,
                    opponent: item.groupchat,
                    conversationType: .group,
                    text: item.reason,
                    date: item.date,
                    isRead: item.isRead
                )
                
                if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: instance.primary) != nil {
                    continue
                }
                
                query.append(instance)
                
                if item.isRead { continue }
                
                let groupchatJid = item.groupchat
                let userJid = item.jid
                if AccountManager.shared.find(for: self.owner)?.syncManager.isSynced() ?? true {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.vcards.requestItem(stream, jid: groupchatJid)
                    })
                }
                
                let resource = ResourceStorageItem()
                resource.owner = owner
                resource.jid = jid
                resource.resource = owner
                resource.status = .online
                resource.entity = entity
                resource.type = .groupchat
                resource.priority = -5
                resource.isTemporary = true
                resource.primary = ResourceStorageItem.genPrimary(jid: jid, owner: owner, resource: owner)
                let resourcePrimary = resource.primary
                if realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: resourcePrimary) == nil {
                    if commitTransaction {
                        try realm.write {
                            realm.add(resource, update: .modified)
                        }
                    } else {
                        realm.add(resource, update: .modified)
                    }
                }
                
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) {
                    var displayedName: String = groupchatJid
                    var userName: String = userJid
                    do {
                        let realm = try  WRealm.safe()
                        if let name = realm.object(ofType: vCardStorageItem.self,
                                                   forPrimaryKey: groupchatJid)?.generatedNickname {
                            displayedName = name
                        }
                        if let name = realm.object(ofType: RosterStorageItem.self,
                                                   forPrimaryKey: [userJid, self.owner].prp())?.displayName {
                            userName = name
                        }
                    } catch {
                        DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
                    }
                    
                    var message = ""
                    
                    switch entity {
                    case .groupchat:
                        message = "\(userName) invited you to join this group".localizeString(id: "chat_group_invitation", arguments: ["\(userName)"])
                    case .incognitoChat:
                        message = "\(userName) invited you to join this incognito group".localizeString(id: "chat_incognito_chat_invitation", arguments: ["\(userName)"])
                    case .privateChat:
                        message = "\(userName) invited you to join private chat".localizeString(id: "chat_private_chat_invitation", arguments: ["\(userName)"])
                    default: break
                    }
                    
                    do {
                        let realm = try  WRealm.safe()
                        let notifyId = [jid, self.owner, NotifyManager.notificationInviteCategory].prp()
                        if realm.object(ofType: ShowedNotificationRequests.self, forPrimaryKey: notifyId) != nil {
                            return
                        }
                        
                        let instance = ShowedNotificationRequests()
                        instance.primary = notifyId
                        instance.jid = jid
                        instance.owner = self.owner
                        
                        try realm.write {
                            realm.add(instance, update: .modified)
                        }
                    } catch {
                        DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
                    }
                    
                    
                    DispatchQueue.main.async {
                        NotifyManager.shared.showInviteNotification(
                            title: displayedName,
                            subtitle: "",
                            text: message,
                            jid: groupchatJid,
                            owner: self.owner
                        )
                    }
                    
                }
                
            }
            
            var jids: [String] = []
            
            if commitTransaction {
                try realm.write {
                    query.forEach {
                        if $0.save(commitTransaction: false) {
                            jids.append($0.opponent)
                        }
                    }
                }
                try realm.write {
                    jids.forEach {
                        if let instance = realm.object(
                            ofType: LastChatsStorageItem.self,
                            forPrimaryKey: LastChatsStorageItem.genPrimary(
                                jid: $0,
                                owner: self.owner,
                                conversationType: .group
                            )
                        ) {
                            instance.unread = 1
                            if instance.lastMessage == nil && instance.lastMessageId.isNotEmpty {
                                instance.lastMessage = realm.objects(MessageStorageItem.self).filter("owner == %@ AND messageId == %@", self.owner, instance.lastMessageId).first
                            }
                        }
                    }
                }
            } else {
                query.forEach {
                    if $0.save(commitTransaction: false) {
                        jids.append($0.opponent)
                    }
                }
                jids.forEach {
                    if let instance = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: $0,
                            owner: self.owner,
                            conversationType: .group
                        )
                    ) {
                        instance.unread = 1
                        if instance.lastMessage == nil && instance.lastMessageId.isNotEmpty {
                            instance.lastMessage = realm.objects(MessageStorageItem.self).filter("owner == %@ AND messageId == %@", self.owner, instance.lastMessageId).first
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private final func onDecline(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result,
              let elementId = iq.elementID,
              self.queryIds.contains(elementId) else {
            return false
        }
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(nil)
            queueItems.remove(item)
            return true
        }
        return false
    }
    
    public final func updateInvitesState() {
        if AccountManager.shared.find(for: owner)?.syncManager.isAvailable ?? false { return }
        do {
            let realm = try  WRealm.safe()
            let blocked = realm
                .objects(BlockStorageItem.self)
                .filter("owner == %@", owner)
                .compactMap { return XMPPJID(string: $0.jid) }
            
            try blocked.forEach {
                item in
                let jid = item.bare
                if let timestamp = item.resource,
                    let blockedDate = TimeInterval(timestamp) {
                    let collection = realm
                        .objects(GroupchatInvitesStorageItem.self)
                        .filter("owner == %@ AND groupchat == %@ AND temporary == %@ AND isRead == %@ AND date <= %@",
                                owner,
                                jid,
                                false,
                                false,
                                Date(timeIntervalSince1970: blockedDate))
                    if !collection.isEmpty {
                        try realm.write {
                            if let instance = realm
                                .object(
                                    ofType: LastChatsStorageItem.self,
                                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                                        jid: jid,
                                        owner: owner,
                                        conversationType: .group
                                    )
                                ) {
                                if let message = instance.lastMessage {
                                    realm.delete(message)
                                }
                                realm.delete(instance)
                            }
                            if let instance = realm
                                .object(ofType: RosterStorageItem.self,
                                        forPrimaryKey: [jid, owner].prp()) {
                                realm.delete(instance)
                            }
                            collection.forEach { $0.isRead = true }
                        }
//                        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                            _ = session.sync?.update(stream, jid: jid, conversationType: .group, status: .deleted)
//                        } fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                _ = user.syncManager.update(stream, jid: jid, conversationType: .group, status: .deleted)
                            })
//                        }

                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func blockInvite(groupchat: String, withContact: Bool = false) {
        do {
            let realm = try  WRealm.safe()
            let toUnblock = realm
                .objects(BlockStorageItem.self)
                .filter("owner == %@", owner)
                .compactMap { return XMPPJID(string: $0.jid ) }
                .filter { $0.bare == groupchat && $0.resource != nil }
                .compactMap {  return $0.full }
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.blocked.blockContact(stream,
                                          jid: [groupchat,
                                                Int(Date().timeIntervalSince1970).description].joined(separator: "/"))
                if withContact {
                    user.blocked.blockContact(stream, jid: groupchat)
                }
                toUnblock.forEach {
                    item in
                    user.blocked.unblockContact(stream, jid: item)
                }
            })
            
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func readMessage(withMessage message: XMPPMessage, commitTransaction: Bool = true) -> Bool {
        func transaction(_ commit: Bool, transaction: (() -> Void)) {
            do {
                let realm = try  WRealm.safe()
                if commit {
                    try realm.write {
                        transaction()
                    }
                } else {
                    transaction()
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        var bareMessage: XMPPMessage = message
        
        var isTrustedSource: Bool = true
        if let archived = getArchivedMessageContainer(message) {
            bareMessage = archived
            isTrustedSource = false
        } else if let carbonsCopy = getCarbonCopyMessageContainer(message) {
            bareMessage = carbonsCopy
        } else if let carbonsForward = getCarbonForwardedMessageContainer(message) {
            bareMessage = carbonsForward
        }
        
        guard let groupchat = bareMessage.from?.bare else { return false }
        
        if let info = bareMessage.element(forName: "x", xmlns: getPrimaryNamespace()),
           let pinnedMessage = info.element(forName: "pinned-message")?.stringValue {
            if isTrustedSource {
                do {
                    let realm = try  WRealm.safe()
                    transaction(commitTransaction) {
                        realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [groupchat, owner].prp())?.pinnedMessage = pinnedMessage
                    }
                } catch {
                    DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
                }
            }
        }
        
        let actionType = bareMessage
            .element(forName: "x", xmlns: xmlns("system-message"))?
            .attributeStringValue(forName: "type")
        
        if actionType == "block" { return true }
        
        if actionType == "update" {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.vcards.requestItem(stream, jid: groupchat)
            })
        }
        
        if actionType == "create", let query = bareMessage
            .element(forName: "x", xmlns: xmlns("system-message")) {
            do {
                let realm = try  WRealm.safe()
                if let name = query.element(forName: "name")?.stringValue {
                    AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                        user.roster.setContact(stream, jid: groupchat, nickname: name, groups: [])
                    })
                }
                if realm.object(ofType: GroupChatStorageItem.self,
                                forPrimaryKey: [groupchat, owner].prp()) == nil {
                    let instance = GroupChatStorageItem()
                    instance.primary = GroupChatStorageItem.genPrimary(jid: groupchat, owner: owner)
                    instance.jid = groupchat
                    instance.owner = owner
                    if let name = query.element(forName: "name")?.stringValue {
                        instance.name = name
                    }
                    var isIncognito: Bool = false
                    if let privacy = query.element(forName: "privacy")?.stringValue {
                        instance.privacy_ = privacy
                        isIncognito = privacy == "incognito"
                    }
                    if let index = query.element(forName: "index")?.stringValue {
                        instance.index_ = index
                    }
                    if let membership = query.element(forName: "membership")?.stringValue {
                        instance.membership_ = membership
                    }
                    if let descr = query.element(forName: "description")?.stringValue {
                        instance.descr = descr
                    }
                    
                    let initialMessageInstance = MessageStorageItem()

                    initialMessageInstance.configureInitialMessage(
                        owner,
                        opponent: groupchat,
                        conversationType: .group,
                        text: "",
                        date: Date(),
                        isRead: true
                    )
                    switch instance.privacy {
                    case .publicChat:
                        initialMessageInstance.legacyBody = "Group \(instance.name) created".localizeString(id: "chat_group_created", arguments: ["\(instance.name)"])
                    case .incognito:
                        initialMessageInstance.legacyBody = "Incognito group \(instance.name) created".localizeString(id: "chat_incognito_group_created", arguments: ["\(instance.name)"])
                    default: break
                    }
                    initialMessageInstance.isDeleted = false
                    let resource = ResourceStorageItem()
                    resource.owner = owner
                    resource.jid = groupchat
                    resource.resource = owner
                    resource.status = .offline
                    resource.entity = isIncognito ? .incognitoChat : .groupchat
                    resource.priority = -5
                    resource.isTemporary = true
                    resource.primary = ResourceStorageItem.genPrimary(jid: groupchat, owner: owner, resource: owner)
                    if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessageInstance.primary) != nil {
                        transaction(commitTransaction) {
                            realm.add(resource, update: .modified)
                            realm.add(instance, update: .modified)
                        }
                    } else {
                        transaction(commitTransaction) {
                            realm.add(resource, update: .modified)
                            realm.add(instance, update: .modified)
                            _ = initialMessageInstance.save(commitTransaction: false)
                        }
                    }
                    
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        if let userCard = bareMessage
            .elements(forName: "reference")
            .filter({ return $0.attributeStringValue(forName: "type") == "mutable" })
            .first(where: { $0.element(forName: "user") != nil })?
            .element(forName: "user"){
            let card = updateUserCard(userCard,
                                      groupchat: groupchat,
                                      trustedSource: isTrustedSource,
                                      messageAction: nil,
                                      commitTransaction: commitTransaction,
                                      cardDate: getDelayedDate(message) ?? Date())
            if card?.isMe ?? false {
                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                    _ = user.groupchats.requestMyRights(stream, groupchat: groupchat)
                })
            }
        }
        if let userCard = bareMessage
            .element(forName: "x", xmlns: xmlns("system-message"))?
            .element(forName: "user"),
            let groupchat = bareMessage.from?.bare {
            
            let card = updateUserCard(userCard,
                                      groupchat: groupchat,
                                      trustedSource: isTrustedSource,
                                      messageAction: actionType,
                                      commitTransaction: commitTransaction,
                                      cardDate: getDelayedDate(message) ?? Date())
            if card?.isMe ?? false {
                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                    _ = user.groupchats.requestMyRights(stream, groupchat: groupchat)
                })
            }
        }
        return false
    }
    
    public final func fail(iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            switch item.action {
            case .requestForm:
                item.formCallback?(nil, nil, nil, "fail")
                item.settingsCallback?(nil, "fail")
            default:
                item.callback?("fail")
                item.invitesCallback?(item.value, "fail")
            }
            queueItems.remove(item)
        }
        return true
    }
        
    public final func fail(presence: XMPPPresence) -> Bool {
        guard let to = presence.to?.bare,
            let item = queueItems.first(where: { [[to, "join"].prp(),
                                        [to, "cancel_join"].prp(),
                                        [to, "leave"].prp()]
                .contains($0.elementId) }) else {
            return false
        }
        item.callback?("fail")
        queueItems.remove(item)
        return true
    }
    
    public final func success(presence: XMPPPresence) -> Bool {
        guard let to = presence.to?.bare,
            let item = queueItems
                .first(where: { [[to, "leave"].prp()].contains($0.elementId) }) else {
            return false
        }
        item.callback?(nil)
        queueItems.remove(item)
        return true
    }
    
    func read(_ stream: XMPPStream, withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case onCreate(iq): return true
        case onError(iq): return true
        case onUser(iq): return true
        case onEditChatSettingsForm(iq): return true
        case onEditStatusForm(iq): return true
        case onEditDefaultRightsForm(iq): return true
        case onSuccessUserUpdatedForm(iq): return true
        case onEditUserForm(iq): return true
        case onSuccessSettingsUpdatedForm(iq): return true
        case onSuccessStatusUpdatedForm(iq): return true
        case onSuccesInvite(iq): return true
        case onInviteList(iq): return true
        case onRevoke(iq): return true
        case onBlockList(iq): return true
        case onBlock(iq): return true
        case onUnblock(iq): return true
        case onPublishData(stream, iq: iq): return true
        case onPublishMetadata(iq): return true
        case onResetAvatar(iq): return true
        case onSuccess(iq): return true
        case onDecline(iq): return true
        default: return false
        }
    }
    
    func read(_ xmppStream: XMPPStream, withPresence presence: XMPPPresence) -> Bool {
        switch true {
        case onSubscribe(xmppStream, presence: presence): return true
        case onInfo(presence): return true
        default: return false
        }
    }
    
    public func reset() {
//        RunLoop.main.perform {
//            do {
//                self.queueItems.forEach {
//                    item in
//                    let value = item.value
//                    switch item.action {
//                    case .requestForm:
//                        item.formCallback?(nil, nil, nil, "fail")
//                        item.settingsCallback?(nil, "fail")
//                    default:
//                        item.callback?("fail")
//                        item.invitesCallback?(value, "fail")
//                    }
//                }
//                let realm = try  WRealm.safe()
//                realm.writeAsync {
//                    realm.objects(GroupChatStorageItem.self).filter("owner == %@", self.owner).forEach {
//                        $0.present = 0
//                    }
//                }
//            } catch {
//                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
//            }
//        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        
        func transaction(_ commit: Bool, transaction: (() -> Void)) {
            do {
                let realm = try  WRealm.safe()
                if commit {
                    try realm.write {
                        transaction()
                    }
                } else {
                    transaction()
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        do {
            let realm = try  WRealm.safe()
            transaction(commitTransaction) {
                realm.delete(realm
                    .objects(GroupChatStorageItem.self)
                    .filter("owner == %@", owner))
                realm.delete(realm
                    .objects(GroupchatInvitesStorageItem.self)
                    .filter("owner == %@", owner))
                realm.delete(realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("owner == %@", owner))
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
}
