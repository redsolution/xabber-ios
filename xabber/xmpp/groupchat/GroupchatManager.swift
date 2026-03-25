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

final class GroupchatRequestScheduler {
    private let queue = DispatchQueue(label: "com.xabber.groupchat.request-scheduler")
    private var workItems: [String: DispatchWorkItem] = [:]

    func schedule(elementId: String, timeout: TimeInterval, callback: @escaping () -> Void) {
        queue.async {
            self.workItems[elementId]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.queue.async {
                    self?.workItems.removeValue(forKey: elementId)
                }
                callback()
            }
            self.workItems[elementId] = item
            self.queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    func cancel(elementId: String) {
        queue.async {
            self.workItems[elementId]?.cancel()
            self.workItems.removeValue(forKey: elementId)
        }
    }
}

class GroupchatManager: AbstractXMPPManager {
    
    static let requestTimeoutSeconds: TimeInterval = 15.0
    
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
            case invite
            case revokeInvite
            case changeData
            case kick
            case pin
            case userCard
            case updateSettings
            case updateInfo
        }

        var action: Action
        var elementId: String
        var value: String = ""
        var values: [String] = []
        var payload: [[String: String]]
        var callback: ((String?) -> Void)?
        var invitesCallback: ((String, String?) -> Void)?

        init(_ action: Action, elementId: String, callback: ((String?) -> Void)? = nil, inviteCallback: ((String, String?) -> Void)? = nil, payload: [[String: String]] = [], value: String = "", values: [String] = []) {
            self.action = action
            self.elementId = elementId
            self.callback = callback
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
    private let requestScheduler = GroupchatRequestScheduler()
    
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
        requestScheduler.cancel(elementId: elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            queueItems.remove(item)
        }
    }
    
    public final func fullJid(_ bareJid: String) -> XMPPJID? {
        return XMPPJID(string: bareJid, resource: nil)
//        do {
//            let realm = try  WRealm.safe()
//            let resource = realm
//                .objects(ResourceStorageItem.self)
//                .filter("owner == %@ AND jid == %@", self.owner, bareJid)
//                .sorted(by: [
//                    SortDescriptor(keyPath: "timestamp", ascending: false),
//                    SortDescriptor(keyPath: "priority", ascending: false)
//                ])
//                .first?
//            .resource ?? "Group"
//            return XMPPJID(string: bareJid, resource: "Group")
//        } catch {
//            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
//        }
//        return nil
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
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <create xmlns='...'><peer-to-peer parent='...' with='...'/></create>
        let create = DDXMLElement(name: "create", xmlns: getPrimaryNamespace())
        let peerToPeer = DDXMLElement(name: "peer-to-peer")
        peerToPeer.addAttribute(withName: "parent", stringValue: groupchat)
        peerToPeer.addAttribute(withName: "with", stringValue: userId)
        create.addChild(peerToPeer)
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat)?.domainJID, elementID: elementId, child: create))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.create, elementId: elementId, callback: callback, value: "peer-to-peer"))
        let item = QueueItem(.join, elementId: [groupchat, "join"].prp(), callback: nil)
        queueItems.insert(item)
        AccountManager.shared.find(for: owner)?.groupchats.queueItems.insert(item)
    }
    
    public final func create(_ xmppStream: XMPPStream, server: String, name: String, localPart: String?, privacy: GroupChatStorageItem.Privacy?, membership: GroupChatStorageItem.Membership?,  index: GroupChatStorageItem.Index?, description: String?, callback: @escaping ((String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <create xmlns='...'><group privacy='...'><localpart>...<info><name>...</info><settings>...</settings></group></create>
        let create = DDXMLElement(name: "create", xmlns: getPrimaryNamespace())
        let group = DDXMLElement(name: "group")
        if let privacy = privacy {
            group.addAttribute(withName: "privacy", stringValue: privacy.rawValue)
        }
        if let localPart = localPart {
            group.addChild(DDXMLElement(name: "localpart", stringValue: localPart))
        }
        let info = DDXMLElement(name: "info")
        info.addChild(DDXMLElement(name: "name", stringValue: name))
        if let descr = description {
            info.addChild(DDXMLElement(name: "description", stringValue: descr))
        }
        group.addChild(info)
        let settings = DDXMLElement(name: "settings")
        if let membership = membership {
            settings.addChild(DDXMLElement(name: "membership", stringValue: membership.rawValue))
        }
        if let index = index {
            settings.addChild(DDXMLElement(name: "index", stringValue: index.rawValue))
        }
        group.addChild(settings)
        create.addChild(group)
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: server), elementID: elementId, child: create))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.create, elementId: elementId, callback: callback))
        if let localPart = localPart {
            let item = QueueItem(.join, elementId: [[localPart, server].joined(separator: "@"), "join"].prp(), callback: nil)
            queueItems.insert(item)
            AccountManager.shared.find(for: owner)?.groupchats.queueItems.insert(item)
        }
    }
    
    public final func delete(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ((String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <delete xmlns='...'>jid</delete>
        let delete = DDXMLElement(name: "delete", xmlns: getPrimaryNamespace())
        delete.stringValue = groupchat
        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat)?.domainJID, elementID: elementId, child: delete))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.delete, elementId: elementId, callback: callback))
    }
    
    private final func addRequestTimeoutHandler(for elementId: String) {
        requestScheduler.schedule(elementId: elementId, timeout: GroupchatManager.requestTimeoutSeconds) {
            if let item = self.queueItems.first(where: { $0.elementId ==  elementId }) {
                item.callback?("timeout")
                item.invitesCallback?(item.value, "timeout")
                self.queueItems.remove(item)
            }
        }
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
        let elementId = "GC: \(NanoID.new(6))"
        // V3: uses primary namespace
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "decline",
                                                   xmlns: getPrimaryNamespace())))
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
        let elementId = "GC: \(NanoID.new(6))"
        let user = DDXMLElement(name: "user", xmlns: getPrimaryNamespace())
        user.addAttribute(withName: "id", stringValue: userId)
        if let nickname = nickname {
            user.addChild(DDXMLElement(name: "nickname", stringValue: nickname))
        }
        if let badge = badge {
            user.addChild(DDXMLElement(name: "badge", stringValue: badge))
        }
        // V3: <members xmlns='...'>, Old: <query xmlns='...#members'>
        let query = DDXMLElement(name: "members", xmlns: getPrimaryNamespace())
        query.addChild(user)
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: query))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.changeData, elementId: elementId, callback: callback))
    }
    
    public final func willInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String, callback: @escaping ((String, String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: uses primary namespace
        let invite = DDXMLElement(name: "invite", xmlns: getPrimaryNamespace())
        invite.addChild(DDXMLElement(name: "jid", stringValue: jid))
        invite.addChild(DDXMLElement(name: "send", stringValue: "false"))
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: invite))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.invite, elementId: elementId, inviteCallback: callback, value: jid))
    }

    public final func didInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String, reason: String? = nil) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: uses primary namespace
        let invite = DDXMLElement(name: "invite", xmlns: getPrimaryNamespace())
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
//            instance.inviteId = elementId
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
        let elementId = "GC: \(NanoID.new(6))"
        // V3: uses primary namespace
        let revoke = DDXMLElement(name: "revoke", xmlns: getPrimaryNamespace())
        jids.forEach { revoke.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: revoke))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.revokeInvite, elementId: elementId, callback: callback, values: jids))
    }

    public final func revokeInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String, callback: @escaping ((String, String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: uses primary namespace
        let revoke = DDXMLElement(name: "revoke", xmlns: getPrimaryNamespace())
        revoke.addChild(DDXMLElement(name: "jid", stringValue: jid))
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: revoke))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.revokeInvite, elementId: elementId, inviteCallback: callback, value: jid))
    }

    public final func cancelInvite(_ xmppStream: XMPPStream, groupchat: String, jid: String) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: uses primary namespace
        let revoke = DDXMLElement(name: "revoke", xmlns: getPrimaryNamespace())
        revoke.addChild(DDXMLElement(name: "jid", stringValue: jid))
        xmppStream.send(XMPPIQ(iqType: .set,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: revoke))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: GroupchatInvitedUsersStorageItem.self,
                forPrimaryKey: GroupchatInvitedUsersStorageItem.genPrimary(jid: jid, groupchat: groupchat, owner: self.owner)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
            if let instance = realm.object(
                ofType: GroupchatInvitesStorageItem.self,
                forPrimaryKey: GroupchatInvitesStorageItem.genPrimary(jid: jid, groupchat: groupchat, owner: self.owner)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func requestInvitedUsers(_ xmppStream: XMPPStream, groupchat: String) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <invites xmlns='...'/>, Old: <query xmlns='...#invite'>
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "invites",
                                                   xmlns: getPrimaryNamespace())))
        queryIds.insert(elementId)
    }
    
    //<iq from='igor.boldin@redsolution.com' to='xabber@xmppdev01.xabber.com' type='get' xmlns='jabber:client' id='d15f14fa-cc9d-4368-a075-2b691642b219:sendIQ'><query xmlns='https://xabber.com/protocol/groups#members' version='0'/></iq>
    public final func requestUsers(_ xmppStream: XMPPStream, groupchat: String, userId: String? = nil) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <members xmlns='...'/>, Old: <query xmlns='...#members'/>
        let query = DDXMLElement(name: "members", xmlns: getPrimaryNamespace())
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
        do {
            let realm = try WRealm.safe()
            if let instance = realm.objects(GroupchatInvitesStorageItem.self).filter("owner == %@ AND groupchat == %@", self.owner, groupchat).first {
//                if instance.isGroupInfoLoaded == false {
//                    try realm.write {
//                        instance.isGroupInfoLoaded = true
//                    }
//                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        self.queryIds.insert(elementId)
    }
    
    
    
    
    public final func updateUserPermissions(_ xmppStream: XMPPStream, groupchat: String, user userId: String, changes: [GroupchatPermission]) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        
        let permissions = DDXMLElement(name: "permissions", xmlns: "https://xabber.com/protocol/permissions")
        permissions.addAttribute(withName: "target", stringValue: userId)
        changes.forEach {
            item in
            let permission = DDXMLElement(name: "permission")
            permission.addAttribute(withName: "name", stringValue: item.name)
            if item.status {
                permission.addAttribute(withName: "status", stringValue: "true")
            } else {
                permission.addAttribute(withName: "status", stringValue: "false")
            }
            
            if let seconds = item.expires {
                permission.addAttribute(withName: "seconds", doubleValue: seconds)
            }
            permissions.addChild(permission)
        }
        let iq = XMPPIQ(iqType: .set, to: to, elementID: elementId, child: permissions)
        xmppStream.send(iq)
        self.requestUserPermissions(xmppStream, groupchat: groupchat, user: userId)
    }
    
    public final func updateDefaultPermissions(_ xmppStream: XMPPStream, groupchat: String, changes: [GroupchatPermission]) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        let query = XMPPElement(name: "defaults", xmlns: "https://xabber.com/protocol/permissions")
        let permissions = DDXMLElement(name: "permissions", xmlns: "https://xabber.com/protocol/permissions")
        query.addChild(permissions)
        changes.forEach {
            item in
            let permission = DDXMLElement(name: "permission")
            permission.addAttribute(withName: "name", stringValue: item.name)
            if item.status {
                permission.addAttribute(withName: "status", stringValue: "true")
            } else {
                permission.addAttribute(withName: "status", stringValue: "false")
            }
            if let seconds = item.expires {
                permission.addAttribute(withName: "seconds", doubleValue: seconds)
            }
            permissions.addChild(permission)
        }
        let iq = XMPPIQ(iqType: .set, to: to, elementID: elementId, child: query)
        xmppStream.send(iq)
        self.getDefaultPermissions(xmppStream, groupchat: groupchat)
    }
    
    public final func getDefaultPermissions(_ xmppStream: XMPPStream, groupchat: String) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        let query = XMPPElement(name: "defaults", xmlns: "https://xabber.com/protocol/permissions")
        let iq = XMPPIQ(iqType: .get, to: to, elementID: elementId, child: query)
        xmppStream.send(iq)
    }
    
    private func onReceiveDefaultPermissionsList(_ iq: XMPPIQ) -> Bool {
        guard let groupchat = iq.from?.bare,
              let query = iq.element(forName: "defaults", xmlns: "https://xabber.com/protocol/permissions"),
              let permissionsRaw = query.element(forName: "permissions")?
            .elements(forName: "permission") else {
            return false
        }
        let permissions: [GroupchatPermission] = permissionsRaw.compactMap {
            return GroupchatPermission(
                role: $0.attributeStringValue(forName: "level", withDefaultValue: "member"),
                name: $0.attributeStringValue(forName: "name", withDefaultValue: ""),
                status: $0.attributeBoolValue(forName: "status", withDefaultValue: false),
                displayName: $0.attributeStringValue(forName: "display", withDefaultValue: ""),
                expires: $0.attributeDoubleValue(forName: "expires"),
                seconds: $0.attributeDoubleValue(forName: "seconds"),
                fixed: $0.attributeBoolValue(forName: "fixed", withDefaultValue: false)
            )
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: GroupChatStorageItem.self,
                forPrimaryKey: GroupChatStorageItem.genPrimary(jid: groupchat, owner: self.owner)
            ) {
                try realm.write {
                    instance.defaultPermissions = permissions
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    public final func updateNewbiesPermissions(_ xmppStream: XMPPStream, groupchat: String, changes: [GroupchatPermission]) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        let query = XMPPElement(name: "newbies", xmlns: "https://xabber.com/protocol/permissions")
        let permissions = DDXMLElement(name: "permissions")
        query.addChild(permissions)
        changes.forEach {
            item in
            let permission = DDXMLElement(name: "permission")
            permission.addAttribute(withName: "name", stringValue: item.name)
            if item.status {
                permission.addAttribute(withName: "status", stringValue: "true")
            } else {
                permission.addAttribute(withName: "status", stringValue: "false")
            }
            if let seconds = item.expires {
                permission.addAttribute(withName: "seconds", doubleValue: seconds)
            }
            permissions.addChild(permission)
        }
        let iq = XMPPIQ(iqType: .set, to: to, elementID: elementId, child: query)
        xmppStream.send(iq)
        self.getNewbiesPermissions(xmppStream, groupchat: groupchat)
    }
    
    public final func getNewbiesPermissions(_ xmppStream: XMPPStream, groupchat: String) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        let query = XMPPElement(name: "newbies", xmlns: "https://xabber.com/protocol/permissions")
        let iq = XMPPIQ(iqType: .get, to: to, elementID: elementId, child: query)
        xmppStream.send(iq)
    }
    
    private func onReceiveNewbiesPermissionsList(_ iq: XMPPIQ) -> Bool {
        guard let groupchat = iq.from?.bare,
              let query = iq.element(forName: "newbies", xmlns: "https://xabber.com/protocol/permissions"),
              let permissionsRaw = query.element(forName: "permissions")?
            .elements(forName: "permission") else {
            return false
        }
        let permissions: [GroupchatPermission] = permissionsRaw.compactMap {
            return GroupchatPermission(
                role: $0.attributeStringValue(forName: "level", withDefaultValue: "member"),
                name: $0.attributeStringValue(forName: "name", withDefaultValue: ""),
                status: $0.attributeBoolValue(forName: "status", withDefaultValue: false),
                displayName: $0.attributeStringValue(forName: "display", withDefaultValue: ""),
                expires: $0.attributeDoubleValue(forName: "expires"),
                seconds: $0.attributeDoubleValue(forName: "seconds"),
                fixed: $0.attributeBoolValue(forName: "fixed", withDefaultValue: false)
            )
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: GroupChatStorageItem.self,
                forPrimaryKey: GroupChatStorageItem.genPrimary(jid: groupchat, owner: self.owner)
            ) {
                try realm.write {
                    instance.newbiesPermissions = permissions
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private func onReceiveUserPermissionssList(_ iq: XMPPIQ) -> Bool {
//        guard let permissions = iq.elemen
        /*
         RECV: <iq xmlns="jabber:client" lang="ru" to="igor.boldin@redsolution.com/xabber-ios-0413280E_ui_upgrade_task" from="test-group-igor-20250903@xmppdev01.xabber.com" type="result" id="GC Rights: JEtuLm">
         <query xmlns="https://xabber.com/protocol/groups/permissions" id="jlol81xet5s29hn4">
           <permissions role="owner">
             <permission fixed="true" status="true" role="member" name="send-messages">Send messages</permission>
             <permission fixed="true" status="true" role="member" name="send-media">Send media</permission>
             <permission fixed="true" status="true" role="member" name="add-members">Add members</permission>
             <permission fixed="true" status="true" role="member" name="pin-messages">Pin messages</permission>
             <permission fixed="true" status="true" role="member" name="change-group-info">Change group info</permission>
             <permission fixed="true" status="true" role="owner" name="owner">Owner</permission>
             <permission fixed="true" status="true" role="admin" name="change-group-settings">Edit group settings</permission>
             <permission fixed="true" status="true" role="admin" name="change-user-info">Edit users' info</permission>
             <permission fixed="true" status="true" role="admin" name="delete-messages">Delete messages</permission>
             <permission fixed="true" status="true" role="admin" name="change-permissions">Change users' permissions</permission>
             <permission fixed="true" status="true" role="admin" name="change-default-permissions">Change default permissions</permission>
             <permission fixed="true" status="true" role="admin" name="block-users">Kick and block users</permission>
             <permission fixed="true" status="true" role="admin" name="create-admins">Create admins</permission>
           </permissions>
         </query>
       </iq>
         */
        
        guard let groupchat = iq.from?.bare,
              let permissionsContainer = iq.element(forName: "permissions", xmlns: "https://xabber.com/protocol/permissions") else {
            return false
        }
        do {
            let containers = iq.elements(forName: "permissions")
            let realm = try WRealm.safe()
            try containers.forEach {
                container in
                guard container.xmlns == "https://xabber.com/protocol/permissions" else {
                    return
                }
                guard let userId = container.attributeStringValue(forName: "target") else {
                    return
                }
                let permissionsRaw = container.elements(forName: "permission")
                let permissions: [GroupchatPermission] = permissionsRaw.compactMap {
                    return GroupchatPermission(
                        role: $0.attributeStringValue(forName: "level", withDefaultValue: "member"),
                        name: $0.attributeStringValue(forName: "name", withDefaultValue: ""),
                        status: $0.attributeBoolValue(forName: "status", withDefaultValue: false),
                        displayName: $0.attributeStringValue(forName: "display", withDefaultValue: ""),
                        expires: $0.attributeDoubleValue(forName: "expires"),
                        seconds: $0.attributeDoubleValue(forName: "seconds"),
                        fixed: $0.attributeBoolValue(forName: "fixed", withDefaultValue: false)
                    )
                }
                if let instance = realm.object(
                    ofType: GroupchatUserStorageItem.self,
                    forPrimaryKey: GroupchatUserStorageItem.genPrimary(id: userId, groupchat: groupchat, owner: owner)
                ) {
                    try realm.write {
                        instance.userPermissions = permissions
                        instance.sendMessage = permissions.findByPermissionName("send-messages")?.status ?? false
                        instance.sendMedia = permissions.findByPermissionName("send-media")?.status ?? false
                        instance.addMembers = permissions.findByPermissionName("add-members")?.status ?? false
                        instance.pinMessages = permissions.findByPermissionName("pin-messages")?.status ?? false
                        instance.changeGroupInfo = permissions.findByPermissionName("change-group-info")?.status ?? false
                        instance.changeGroupSettings = permissions.findByPermissionName("change-group-settings")?.status ?? false
                        instance.changeUserInfo = permissions.findByPermissionName("change-user-info")?.status ?? false
                        instance.changePermissions = permissions.findByPermissionName("change-permissions")?.status ?? false
                        instance.changeDefaultPermissions = permissions.findByPermissionName("change-default-permissions")?.status ?? false
                        instance.blockUsers = permissions.findByPermissionName("block-users")?.status ?? false
                        instance.createAdmins = permissions.findByPermissionName("create-admins")?.status ?? false
                    }
                }
            }
            
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
//    private final func onReceiveUserPermissions()
    
    public final func requestUserPermissions(_ xmppStream: XMPPStream, groupchat: String, user userId: String) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        let permissions = XMPPElement(name: "permissions", xmlns: "https://xabber.com/protocol/permissions")
        permissions.addAttribute(withName: "target", stringValue: userId)
        let iq = XMPPIQ(iqType: .get, to: to, elementID: elementId, child: permissions)
        xmppStream.send(iq)
        queryIds.append(elementId)
    }
    
    public final func requestPermissionsEachUser(_ xmppStream: XMPPStream, groupchat: String) {
        guard let to = XMPPJID(string: groupchat) else { return }
        let elementId = "GC Permissions: \(NanoID.new(6))"
        let permissions = XMPPElement(name: "permissions", xmlns: "https://xabber.com/protocol/permissions")
        let iq = XMPPIQ(iqType: .get, to: to, elementID: elementId, child: permissions)
        xmppStream.send(iq)
        queryIds.append(elementId)
    }
    
    public final func requestMyPermissions(_ xmppStream: XMPPStream, groupchat: String) {
        guard let to = XMPPJID(string: groupchat) else { return }
        do {
            let realm = try WRealm.safe()
            if let instance = realm
                .objects(GroupchatUserStorageItem.self)
                .filter("groupchatId == %@ AND isMe == true",
                        GroupChatStorageItem.genPrimary(jid: groupchat, owner: self.owner)).first {
                self.requestUserPermissions(xmppStream, groupchat: groupchat, user: instance.userId)
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    
    public final func getGroupInfo(_ xmppStream: XMPPStream, groupchat: String) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <query xmlns='...'>, get general group info
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        xmppStream.send(XMPPIQ(iqType: .get, to: fullJid(groupchat), elementID: elementId, child: query))
        self.queryIds.insert(elementId)
    }

    // MARK: - V3 Update Settings
    // V3: <settings xmlns='https://xabber.com/protocol/groups'><membership>open</membership>...</settings>

    public final func updateSettings(_ xmppStream: XMPPStream, groupchat: String, settings: [String: Any], callback: ((String?) -> Void)?) {
        let elementId = "GC: \(NanoID.new(6))"
        let settingsElement = DDXMLElement(name: "settings", xmlns: getPrimaryNamespace())

        if let membership = settings["membership"] as? String {
            settingsElement.addChild(DDXMLElement(name: "membership", stringValue: membership))
        }
        if let index = settings["index"] as? String {
            settingsElement.addChild(DDXMLElement(name: "index", stringValue: index))
        }
        if let contacts = settings["contacts"] as? [String] {
            let contactsElement = DDXMLElement(name: "contacts")
            for contact in contacts {
                contactsElement.addChild(DDXMLElement(name: "contact", stringValue: contact))
            }
            settingsElement.addChild(contactsElement)
        }
        if let domains = settings["domains"] as? [String] {
            let domainsElement = DDXMLElement(name: "domains")
            for domain in domains {
                domainsElement.addChild(DDXMLElement(name: "domain", stringValue: domain))
            }
            settingsElement.addChild(domainsElement)
        }

        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: settingsElement))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.updateSettings, elementId: elementId, callback: callback))
    }

    // MARK: - V3 Update Info
    // V3: <info xmlns='https://xabber.com/protocol/groups'><name>New name</name>...</info>

    public final func updateInfo(_ xmppStream: XMPPStream, groupchat: String, info: [String: Any], callback: ((String?) -> Void)?) {
        let elementId = "GC: \(NanoID.new(6))"
        let infoElement = DDXMLElement(name: "info", xmlns: getPrimaryNamespace())

        if let name = info["name"] as? String {
            infoElement.addChild(DDXMLElement(name: "name", stringValue: name))
        }
        if let description = info["description"] as? String {
            infoElement.addChild(DDXMLElement(name: "description", stringValue: description))
        }
        if let statusString = info["status"] as? String {
            let status = DDXMLElement(name: "status", xmlns: "jabber:client")
            status.stringValue = statusString
            infoElement.addChild(status)
        }

        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: infoElement))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.updateInfo, elementId: elementId, callback: callback))
    }

    // MARK: - V3 Update Group Avatar
    // V3: <info xmlns='https://xabber.com/protocol/groups'><avatar><info xmlns='urn:xmpp:avatar:metadata' .../></avatar></info>

    public final func updateGroupAvatar(_ xmppStream: XMPPStream, groupchat: String, image: UIImage?, callback: ((String?) -> Void)?) {
        let elementId = "GC: \(NanoID.new(6))"
        let infoElement = DDXMLElement(name: "info", xmlns: getPrimaryNamespace())
        let avatarElement = DDXMLElement(name: "avatar")

//        if let image = image,
//           let imageData = image.pngData() {
//            let base64String = imageData.base64EncodedString()
//            let hash = imageData.sha1().toHexString()
//            let dataElement = DDXMLElement(name: "data", xmlns: "urn:xmpp:avatar:data", stringValue: base64String)
////            dataElement,
//            avatarElement.addChild(dataElement)
//            let metaInfo = DDXMLElement(name: "info", xmlns: "urn:xmpp:avatar:metadata")
//            metaInfo.addAttribute(withName: "bytes", stringValue: "\(imageData.count)")
//            metaInfo.addAttribute(withName: "id", stringValue: hash)
//            metaInfo.addAttribute(withName: "type", stringValue: "image/png")
//            metaInfo.addAttribute(withName: "height", stringValue: "\(Int(image.size.height))")
//            metaInfo.addAttribute(withName: "width", stringValue: "\(Int(image.size.width))")
//            avatarElement.addChild(metaInfo)
//        }

        infoElement.addChild(avatarElement)
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: infoElement))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.updateInfo, elementId: elementId, callback: callback))
    }

    // MARK: - V3 Update Member Avatar
    // V3: <members xmlns='...'><user id='...'><avatar><info xmlns='urn:xmpp:avatar:metadata' .../></avatar></user></members>

    public final func updateMemberAvatar(_ xmppStream: XMPPStream, groupchat: String, userId: String, image: UIImage?, callback: ((String?) -> Void)?) {
        let elementId = "GC: \(NanoID.new(6))"
        let membersElement = DDXMLElement(name: "members", xmlns: getPrimaryNamespace())
        let userElement = DDXMLElement(name: "user", xmlns: getPrimaryNamespace())
        userElement.addAttribute(withName: "id", stringValue: userId)
        let avatarElement = DDXMLElement(name: "avatar", xmlns: getPrimaryNamespace())

        if let image = image,
           let imageData = image.pngData() {
            let hash = imageData.sha1().toHexString()
            let metaInfo = DDXMLElement(name: "info", xmlns: "urn:xmpp:avatar:metadata")
            metaInfo.addAttribute(withName: "bytes", stringValue: "\(imageData.count)")
            metaInfo.addAttribute(withName: "id", stringValue: hash)
            metaInfo.addAttribute(withName: "type", stringValue: "image/png")
            metaInfo.addAttribute(withName: "height", stringValue: "\(Int(image.size.height))")
            metaInfo.addAttribute(withName: "width", stringValue: "\(Int(image.size.width))")
            avatarElement.addChild(metaInfo)
        }

        userElement.addChild(avatarElement)
        membersElement.addChild(userElement)
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: membersElement))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.changeData, elementId: elementId, callback: callback))
    }


    public final func blockList(_ xmppStream: XMPPStream, groupchat: String) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <block xmlns='...'>, Old: <query xmlns='...#block'>
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: fullJid(groupchat),
                               elementID: elementId,
                               child: DDXMLElement(name: "block",
                                                   xmlns: getPrimaryNamespace())))
        queryIds.insert(elementId)
    }

    public final func kickUser(_ xmppStream: XMPPStream, groupchat: String, userId: String, callback: ((String?) -> Void)?) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <kick xmlns='...'><jid>user@domain</jid></kick>
        let kick = DDXMLElement(name: "kick", xmlns: getPrimaryNamespace())
        kick.addChild(DDXMLElement(name: "jid", stringValue: userId))
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: kick))
        queueItems.insert(QueueItem(.kick, elementId: elementId, callback: callback))
        queryIds.insert(elementId)
    }

    public final func blockUser(_ xmppStream: XMPPStream, groupchat: String, ids: [String] = [], jids: [String] = [], domains: [String] = [], callback: @escaping ((String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <block xmlns='...'> with <jid> children only
        let block = DDXMLElement(name: "block", xmlns: getPrimaryNamespace())
        // V3 uses <jid> for all block types
        jids.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        // ids and domains mapped to jid elements for V3 compatibility
        ids.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        domains.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: block))
        queryIds.insert(elementId)
        var toBlock: [[String: String]] = []
        toBlock.append(contentsOf: ids.compactMap { return ["type": "id", "value": $0] })
        toBlock.append(contentsOf: jids.compactMap { return ["type": "jid", "value": $0] })
        toBlock.append(contentsOf: domains.compactMap { return ["type": "domain", "value": $0] })
        queueItems.insert(QueueItem(.block, elementId: elementId, callback: callback, payload: toBlock))
    }

    public final func unblockUser(_ xmppStream: XMPPStream, groupchat: String, ids: [String] = [], jids: [String] = [], domains: [String] = [], callback: @escaping ((String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <unblock xmlns='...'> with <jid> children only
        let block = DDXMLElement(name: "unblock", xmlns: getPrimaryNamespace())
        jids.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        ids.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        domains.forEach { block.addChild(DDXMLElement(name: "jid", stringValue: $0)) }
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: block))
        queryIds.insert(elementId)
        var toUnblock: [[String: String]] = []
        toUnblock.append(contentsOf: ids.compactMap { return ["type": "id", "value": $0] })
        toUnblock.append(contentsOf: jids.compactMap { return ["type": "jid", "value": $0] })
        toUnblock.append(contentsOf: domains.compactMap { return ["type": "domain", "value": $0] })
        queueItems.insert(QueueItem(.unblock, elementId: elementId, callback: callback, payload: toUnblock))
    }
    
    public final func unpinMessage(_ xmppStream: XMPPStream, groupchat: String, callback: @escaping ((String?) -> Void)) {
        // V3: <pinned-message id='...' status='remove'/>
        let elementId = "GC: \(NanoID.new(6))"
        let pinnedMessage = DDXMLElement(name: "pinned-message", xmlns: getPrimaryNamespace())
        pinnedMessage.addAttribute(withName: "id", stringValue: "0")
        pinnedMessage.addAttribute(withName: "status", stringValue: "remove")
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: pinnedMessage))
        queryIds.insert(elementId)
        queueItems.insert(QueueItem(.pin, elementId: elementId, callback: callback))
    }

    public final func pinMessage(_ xmppStream: XMPPStream, groupchat: String, message stanzaId: String, callback: @escaping ((String?) -> Void)) {
        let elementId = "GC: \(NanoID.new(6))"
        // V3: <pinned-message id='stanzaId' status='pinned'/>
        let pinnedMessage = DDXMLElement(name: "pinned-message", xmlns: getPrimaryNamespace())
        pinnedMessage.addAttribute(withName: "id", stringValue: stanzaId)
        pinnedMessage.addAttribute(withName: "status", stringValue: "pinned")
        xmppStream.send(XMPPIQ(iqType: .set, to: fullJid(groupchat), elementID: elementId, child: pinnedMessage))
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
    
    
    
    
    private final func onInfo(_ presence: XMPPPresence) -> Bool {
        guard let from = presence.from?.bare else { return false }
        // V3: <group xmlns='...' privacy='...' members='N'>
        //   <info><name/><description/><status/></info>
        //   <settings><index/><membership/></settings>
        //   <pinned><pinned-message id='...'/></pinned>
        //   <present>N</present>
        // Old: <x xmlns='...'> with flat children
        let v3Group = presence.element(forName: "group", xmlns: getPrimaryNamespace())
        let x = v3Group ?? presence.element(forName: "x", xmlns: getPrimaryNamespace())
        guard let x = x else { return false }
        let isV3 = v3Group != nil
        let resource: String = presence.from?.resource ?? "groupchat"

        func update(_ instance: GroupChatStorageItem) {
            if instance.isInvalidated { return }
            if isV3 {
                let info = x.element(forName: "info")
                let settings = x.element(forName: "settings")
                instance.name = info?.element(forName: "name")?.stringValue ?? instance.name
                instance.privacy_ = x.attributeStringValue(forName: "privacy") ?? instance.privacy_
                instance.index_ = settings?.element(forName: "index")?.stringValue ?? instance.index_
                instance.membership_ = settings?.element(forName: "membership")?.stringValue ?? instance.membership_
                instance.descr = info?.element(forName: "description")?.stringValue ?? instance.descr
                instance.members = x.attributeIntegerValue(forName: "members", withDefaultValue: instance.members)
                instance.status = info?.element(forName: "status")?.stringValue ?? ""
            } else {
                instance.name = x.element(forName: "name")?.stringValue ?? instance.name
                instance.privacy_ = x.element(forName: "privacy")?.stringValue ?? instance.privacy_
                instance.index_ = x.element(forName: "index")?.stringValue ?? instance.index_
                instance.membership_ = x.element(forName: "membership")?.stringValue ?? instance.membership_
                instance.descr = x.element(forName: "description")?.stringValue ?? instance.descr
                instance.members = x.attributeIntegerValue(forName: "members", withDefaultValue: instance.members)
                instance.status = x.element(forName: "status")?.stringValue ?? ""
            }
            // V3 pinned: <pinned><pinned-message id='...'/>
            // Old pinned: <pinned-message>stanzaId</pinned-message>
            let pinnedMessageId: String? = isV3
                ? x.element(forName: "pinned")?.element(forName: "pinned-message")?.attributeStringValue(forName: "id")
                : x.element(forName: "pinned-message")?.stringValue
            if let pinnedMessage = pinnedMessageId {
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
            if !isV3, let members = x.element(forName: "members") {
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
            // V3: name in <info><name>, Old: name in <x><name>
            let groupName: String? = isV3
                ? x.element(forName: "info")?.element(forName: "name")?.stringValue
                : x.element(forName: "name")?.stringValue
            let instance = realm.object(ofType: RosterStorageItem.self,
                                            forPrimaryKey: [from, owner].prp())
            try realm.write {
                instance?.username = groupName ?? ""
                instance?.isContact = false
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

            // V3: privacy is attribute on <group>, Old: <privacy> element in <x>
            let privacyValue: String? = isV3
                ? x.attributeStringValue(forName: "privacy")
                : x.element(forName: "privacy")?.stringValue

            func resolveEntity() -> RosterItemEntity {
                if x.element(forName: "parent-chat") != nil {
                    return .privateChat
                } else if privacyValue == "incognito" {
                    return .incognitoChat
                } else if privacyValue == "public" {
                    return .groupchat
                }
                return .groupchat
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

                    instance.entity = resolveEntity()
                    instance.type = .groupchat
                }

            } else {
                let instance = ResourceStorageItem()
                instance.owner = owner
                instance.jid = from
                instance.resource = resource
                if let statusValue = presence.element(forName: "show")?.stringValue {
                    instance.status = RosterUtils.shared.convertShowStatus(statusValue)
                } else {
                    instance.status = .online
                }
                instance.entity = resolveEntity()
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
            queryIds.contains(elementId),
            let from = iq.from?.domain,
            iq.element(forName: "error") == nil else {
            return false
        }

        // V3: <group xmlns='...' privacy='...' jid='...'><info><name>...</info><settings>...</settings></group>
        // Old: <query xmlns='...#create'><jid>...<name>...<privacy>...</query>
        let v3Group = iq.element(forName: "group", xmlns: getPrimaryNamespace())
        let oldQuery = iq.element(forName: "query", xmlns: xmlns("create"))
        guard v3Group != nil || oldQuery != nil else { return false }
        let isV3 = v3Group != nil
        let query = v3Group ?? oldQuery!

        var unwrappedJid: String?
        if isV3 {
            unwrappedJid = query.attributeStringValue(forName: "jid")
        } else {
            unwrappedJid = query.element(forName: "jid")?.stringValue
            if unwrappedJid == nil {
                if let localPart = query.element(forName: "localpart")?.stringValue {
                    unwrappedJid = XMPPJID(string: [localPart, from].joined(separator: "@"))?.bare
                }
            }
        }

        guard let jid = unwrappedJid else { return false }

        queryIds.remove(elementId)
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            if item.value == "peer-to-peer" {
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                    user.groupchats.join(stream, uiConnection: false, groupchat: jid) { (_) in

                    }
                })
            }
            item.callback?("success")
            queueItems.remove(item)
        }

        // Extract name for roster
        let groupName: String? = isV3
            ? query.element(forName: "info")?.element(forName: "name")?.stringValue
            : query.element(forName: "name")?.stringValue

        queueItems.insert(QueueItem(.join, elementId: [jid, "create"].prp(), callback: nil))
        AccountManager.shared.find(for: owner)?.unsafeAction({ (user, stream) in
            user.roster.setContact(stream, jid: jid, nickname: groupName)
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
                if isV3 {
                    let info = query.element(forName: "info")
                    let settings = query.element(forName: "settings")
                    if let name = info?.element(forName: "name")?.stringValue {
                        instance.name = name
                    }
                    instance.privacy_ = query.attributeStringValue(forName: "privacy") ?? instance.privacy_
                    if let index = settings?.element(forName: "index")?.stringValue {
                        instance.index_ = index
                    }
                    if let membership = settings?.element(forName: "membership")?.stringValue {
                        instance.membership_ = membership
                    }
                    if let descr = info?.element(forName: "description")?.stringValue {
                        instance.descr = descr
                    }
                } else {
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
                }
                try realm.write {
                    realm.add(instance, update: .modified)
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

                }
            }
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
            queueItems.remove(item)
        }
        return true
    }
    
    private final func onUser(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId),
            let from = iq.from?.bare else {
                return false
        }
        // V3: <members xmlns='...'>, Old: <query xmlns='...#members'>
        guard let query = iq.element(forName: "members", xmlns: getPrimaryNamespace())
                ?? iq.element(forName: "query", xmlns: xmlns("members")) else {
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
            // V3: <avatar><info xmlns='urn:xmpp:avatar:metadata' url='...'/>
            // Old: <metadata xmlns='urn:xmpp:avatar:metadata'><info url='...'/>
            if let avatarUrl = card.element(forName: "avatar")?.element(forName: "info")?.attributeStringValue(forName: "url")
                ?? card.element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")?.element(forName: "info")?.attributeStringValue(forName: "url") {
                instance.avatarURI = avatarUrl
            }
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
                case .member, .custom: instance.sortedRole = GroupchatUserStorageItem.IntegerRole.member.rawValue
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
            queryIds.contains(elementId) else {
                return false
        }
        // V3: <block xmlns='...'>, Old: <query xmlns='...#block'>
        guard let query = iq.element(forName: "block", xmlns: getPrimaryNamespace())
                ?? iq.element(forName: "query", xmlns: xmlns("block")) else {
            return false
        }

        do {
            let realm = try  WRealm.safe()

            try realm.write {
                // V3: <jid> children, Old: <user> children
                let blockedItems = query.elements(forName: "jid") + query.elements(forName: "user")
                blockedItems.forEach {
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
    
    private func onGroupInfo(_ iq: XMPPIQ) -> Bool {
        guard let fromRaw = iq.from,
              let from = iq.from?.bare else {
            return false
        }
        // V3: <group xmlns='...' privacy='...'> with <info>/<settings>/<pinned>
        // Old: <x xmlns='...'> with flat children
        let v3Group = iq.element(forName: "group", xmlns: getPrimaryNamespace())
        let x = v3Group ?? iq.element(forName: "x", xmlns: getPrimaryNamespace())
        guard let x = x else { return false }
        let isV3 = v3Group != nil
        let resource: String = fromRaw.resource ?? "groupchat"

        func update(_ instance: GroupChatStorageItem) {
            if instance.isInvalidated { return }
            if isV3 {
                let info = x.element(forName: "info")
                let settings = x.element(forName: "settings")
                instance.name = info?.element(forName: "name")?.stringValue ?? instance.name
                instance.privacy_ = x.attributeStringValue(forName: "privacy") ?? instance.privacy_
                instance.index_ = settings?.element(forName: "index")?.stringValue ?? instance.index_
                instance.membership_ = settings?.element(forName: "membership")?.stringValue ?? instance.membership_
                instance.descr = info?.element(forName: "description")?.stringValue ?? instance.descr
                instance.members = x.attributeIntegerValue(forName: "members", withDefaultValue: instance.members)
                instance.status = info?.element(forName: "status")?.stringValue ?? ""
            } else {
                instance.name = x.element(forName: "name")?.stringValue ?? instance.name
                instance.privacy_ = x.element(forName: "privacy")?.stringValue ?? instance.privacy_
                instance.index_ = x.element(forName: "index")?.stringValue ?? instance.index_
                instance.membership_ = x.element(forName: "membership")?.stringValue ?? instance.membership_
                instance.descr = x.element(forName: "description")?.stringValue ?? instance.descr
                instance.members = x.attributeIntegerValue(forName: "members", withDefaultValue: instance.members)
                instance.status = x.element(forName: "status")?.stringValue ?? ""
            }
            // V3 pinned: <pinned><pinned-message id='...'/>
            // Old pinned: <pinned-message>stanzaId</pinned-message>
            let pinnedMessageId: String? = isV3
                ? x.element(forName: "pinned")?.element(forName: "pinned-message")?.attributeStringValue(forName: "id")
                : x.element(forName: "pinned-message")?.stringValue
            if let pinnedMessage = pinnedMessageId {
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
            if !isV3, let members = x.element(forName: "members") {
                instance.members = members.stringValueAsNSInteger()
            }
            if let present = x.element(forName: "present") {
                instance.present = present.stringValueAsNSInteger()
            }
        }
        do {
            let realm = try WRealm.safe()
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
            // V3: name in <info><name>, Old: name in <x><name>
            let groupName: String? = isV3
                ? x.element(forName: "info")?.element(forName: "name")?.stringValue
                : x.element(forName: "name")?.stringValue
            let instance = realm.object(ofType: RosterStorageItem.self,
                                        forPrimaryKey: [from, owner].prp())
            try realm.write {
                instance?.username = groupName ?? ""
                instance?.isContact = false
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
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
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
            let from = iq.from?.bare else {
                return false
        }
        // V3: <invites xmlns='...'>, Old: <query xmlns='...#invite'>
        guard let query = iq.element(forName: "invites", xmlns: getPrimaryNamespace())
                ?? iq.element(forName: "query", xmlns: xmlns("invite")) else {
            return false
        }
//        queryIds.remove(elementId)
//        do {
//            let realm = try  WRealm.safe()
//            if let instance = realm
//                .object(ofType: GroupChatStorageItem.self,
//                        forPrimaryKey: [from, owner].prp()) {
//                try realm.write {
//                    instance.invited.removeAll()
//                    instance
//                        .invited
//                        .append(objectsIn: query
//                                            .elements(forName: "user")
//                                            .compactMap { return $0.attributeStringValue(forName: "jid")})
//                }
//            }
//        } catch {
//            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
//        }
        let groupchatId = GroupChatStorageItem.genPrimary(jid: from, owner: self.owner)
        do {
            let realm = try WRealm.safe()
            // V3: <jid> children with text content, Old: <user jid='...'> children
            let oldJids = query.elements(forName: "user").compactMap { $0.attributeStringValue(forName: "jid") }
            let v3Jids = query.elements(forName: "jid").compactMap { $0.stringValue }
            let jids = Set(oldJids + v3Jids)
            
            try jids.forEach {
                jid in
                let primary = GroupchatInvitedUsersStorageItem.genPrimary(jid: jid, groupchat: from, owner: self.owner)
                if let instance = realm.object(ofType: GroupchatInvitedUsersStorageItem.self, forPrimaryKey: primary) {
                    if let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        try realm.write {
                            instance.nickname = rosterItem.displayName
                            instance.avatarMaxUrl = rosterItem.avatarMaxUrl
                            instance.avatarMinUrl = rosterItem.avatarMinUrl
                            instance.oldschoolAvatarKey = rosterItem.oldschoolAvatarKey
                            instance.avatarUpdatedTS = rosterItem.avatarUpdatedTS
                        }
                    } else if let vcardItem = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                        try realm.write {
                            instance.nickname = vcardItem.nickname
                        }
                    }
                } else {
                    let instance = GroupchatInvitedUsersStorageItem()
                    instance.primary = primary
                    instance.owner = self.owner
                    instance.jid = jid
                    instance.groupchatId = groupchatId
                    if let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        instance.nickname = rosterItem.displayName
                        instance.avatarMaxUrl = rosterItem.avatarMaxUrl
                        instance.avatarMinUrl = rosterItem.avatarMinUrl
                        instance.oldschoolAvatarKey = rosterItem.oldschoolAvatarKey
                        instance.avatarUpdatedTS = rosterItem.avatarUpdatedTS
                    } else if let vcardItem = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                        instance.nickname = vcardItem.nickname
                    }
                    try realm.write {
                        realm.add(instance, update: .modified)
                    }
                }
            }
            let invited = Set(realm.objects(GroupchatInvitedUsersStorageItem.self).filter("groupchatId == %@", groupchatId).toArray().compactMap { $0.jid })
            try invited.subtracting(jids).forEach {
                jid in
                let primary = GroupchatInvitedUsersStorageItem.genPrimary(jid: jid, groupchat: from, owner: self.owner)
                if let instance = realm.object(ofType: GroupchatInvitedUsersStorageItem.self, forPrimaryKey: primary) {
                    try realm.write {
                        realm.delete(instance)
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    public final func isInvite(_ message: XMPPMessage) -> Bool {
        // V3: <invite xmlns='...'>, Old: <invite xmlns='...#invite'>
        return message.element(forName: "invite", xmlns: getPrimaryNamespace()) != nil
            || message.element(forName: "invite", xmlns: xmlns("invite")) != nil
    }

    public final func readInvite(in message: XMPPMessage, date: Date, isRead: Bool?, commit: Bool = true) -> Bool {
        // V3: <invite xmlns='...'>, Old: <invite xmlns='...#invite'>
        guard let invite = message.element(forName: "invite", xmlns: getPrimaryNamespace())
                ?? message.element(forName: "invite", xmlns: xmlns("invite")),
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
            let primary = [elementId, owner].prp()
            if realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary) != nil {
                return false
            }
            
            var lastInviteDate: Date = Date(timeIntervalSince1970: 1)
            
            let reason = invite.element(forName: "reason")?.stringValue
            
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
            
            let isReadInvite = lastInviteDate < date ? isRead ?? (from == owner) : true
            let instance = GroupchatInvitesStorageItem()
//            instance.inviteId = elementId
            instance.owner = owner
            instance.primary = primary
            instance.groupchat = groupchat
            instance.outgoing = from == owner
            instance.reason = reason
            instance.isRead = isReadInvite
            instance.isProcessed = lastInviteDate <= date ? false : true// false
            instance.date = date
            instance.jid = from == owner ? to : from
//            instance.temporary = true
            // V3: <group xmlns='...' privacy='incognito'>, Old: <x xmlns='...'><privacy>incognito</privacy>
            let v3Group = message.element(forName: "group", xmlns: getPrimaryNamespace())
            let oldX = message.element(forName: "x", xmlns: getPrimaryNamespace())
            let invitePrivacy: String? = v3Group?.attributeStringValue(forName: "privacy")
                ?? oldX?.element(forName: "privacy")?.stringValue
            instance.isAnonymous = invitePrivacy == "incognito"

            let rosterItem = RosterStorageItem()
            rosterItem.jid = groupchat
            rosterItem.owner = self.owner
            rosterItem.primary = RosterStorageItem.genPrimary(jid: groupchat, owner: self.owner)
            rosterItem.isContact = false
            rosterItem.subscribtion = .none
            rosterItem.ask = .none

            let groupInfoElement = v3Group ?? oldX
            if let x = groupInfoElement {
                var entity: RosterItemEntity = .groupchat

                if x.element(forName: "parent-chat") != nil {
                    entity = .privateChat
                } else if (v3Group?.attributeStringValue(forName: "privacy") ?? x.element(forName: "privacy")?.stringValue) == "incognito" {
                    entity = .incognitoChat
                }
                
//                instance.entity = .groupchat
                
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
                    realm.add(rosterItem, update: .modified)
                    let primary = UINotificationStorageItem.genPrimary(owner: owner, jid: groupchat)
                    if !isReadInvite {
                        let uiNotifyObject = UINotificationStorageItem()
                        uiNotifyObject.primary = primary
                        uiNotifyObject.owner = owner
                        uiNotifyObject.jid = groupchat
                        uiNotifyObject.kind = .invite
                        uiNotifyObject.date = Date()
                        uiNotifyObject.readAt = nil
                        realm.add(uiNotifyObject, update: .modified)
                    }
                    
                }
            } else {
                realm.add(instance, update: .modified)
                realm.add(rosterItem, update: .modified)
                let primary = UINotificationStorageItem.genPrimary(owner: owner, jid: groupchat)
                if !isReadInvite {
                    let uiNotifyObject = UINotificationStorageItem()
                    uiNotifyObject.primary = primary
                    uiNotifyObject.owner = owner
                    uiNotifyObject.jid = groupchat
                    uiNotifyObject.kind = .invite
                    uiNotifyObject.date = Date()
                    uiNotifyObject.readAt = nil
                    realm.add(uiNotifyObject, update: .modified)
                }
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
                .filter("owner == %@ AND outgoing == %@ AND isProcessed == %@", owner, false, false)
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
//                            item.temporary = false
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
                        _ = user.vcards.requestItem(stream, jid: jid)
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
                
                let entity: RosterItemEntity = .groupchat//item.entity
                
                
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
    
    /// V3: Handle headline messages containing group info updates
    /// Format: <message type='headline'><group privacy='...' members='N'>
    ///           <info><name/><description/></info>
    ///           <settings>...</settings>
    ///           <pinned><pinned-message id='...'/></pinned>
    ///           <present>N</present>
    ///         </group></message>
    public final func readHeadlineMessage(_ message: XMPPMessage) -> Bool {
        guard message.attributeStringValue(forName: "type") == "headline",
              let from = message.from?.bare,
              let group = message.element(forName: "group", xmlns: getPrimaryNamespace()) else {
            return false
        }

        let info = group.element(forName: "info")
        let settings = group.element(forName: "settings")

        do {
            let realm = try WRealm.safe()
            let primary = GroupChatStorageItem.genPrimary(jid: from, owner: owner)
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: primary) {
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.name = info?.element(forName: "name")?.stringValue ?? instance.name
                    instance.privacy_ = group.attributeStringValue(forName: "privacy") ?? instance.privacy_
                    instance.index_ = settings?.element(forName: "index")?.stringValue ?? instance.index_
                    instance.membership_ = settings?.element(forName: "membership")?.stringValue ?? instance.membership_
                    instance.descr = info?.element(forName: "description")?.stringValue ?? instance.descr
                    instance.members = group.attributeIntegerValue(forName: "members", withDefaultValue: instance.members)
                    instance.status = info?.element(forName: "status")?.stringValue ?? instance.status

                    // Pinned message
                    if let pinnedMessage = group.element(forName: "pinned")?.element(forName: "pinned-message")?.attributeStringValue(forName: "id") {
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

                    if let present = group.element(forName: "present") {
                        instance.present = present.stringValueAsNSInteger()
                    }
                }
            }
            // Update roster display name
            if let name = info?.element(forName: "name")?.stringValue {
                let rosterInstance = realm.object(ofType: RosterStorageItem.self,
                                                 forPrimaryKey: [from, owner].prp())
                try realm.write {
                    rosterInstance?.username = name
                }
            }
        } catch {
            DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
        }

        return true
    }

    public final func readMessage(withMessage message: XMPPMessage, commitTransaction: Bool = true) -> Bool {
        // V3: headline messages carry group info updates, not chat messages
        if readHeadlineMessage(message) {
            return true
        }

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
        
        // V3: <x><pinned><pinned-message id='...'/></pinned></x>
        // Old: <x><pinned-message>stanzaId</pinned-message></x>
        if let info = bareMessage.element(forName: "x", xmlns: getPrimaryNamespace()) {
            let pinnedMessage: String? = info.element(forName: "pinned")?.element(forName: "pinned-message")?.attributeStringValue(forName: "id")
                ?? info.element(forName: "pinned-message")?.stringValue
            if let pinnedMessage = pinnedMessage, isTrustedSource {
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
        
        // V3: <x xmlns='https://xabber.com/protocol/groups'><system-message type='...'/>
        // Old: <x xmlns='https://xabber.com/protocol/groups#system-message' type='...'/>
        let actionType: String? = bareMessage
            .element(forName: "x", xmlns: getPrimaryNamespace())?
            .element(forName: "system-message")?
            .attributeStringValue(forName: "type")
            ?? bareMessage
            .element(forName: "x", xmlns: xmlns("system-message"))?
            .attributeStringValue(forName: "type")

        // V3 or old: the element containing system message metadata (name, privacy, etc.)
        let systemMessageContainer: DDXMLElement? = bareMessage
            .element(forName: "x", xmlns: getPrimaryNamespace())
            ?? bareMessage
            .element(forName: "x", xmlns: xmlns("system-message"))

        if actionType == "block" { return true }

        if actionType == "update" {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.vcards.requestItem(stream, jid: groupchat)
            })
        }

        if actionType == "create", let query = systemMessageContainer {
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
                    
                    let resource = ResourceStorageItem()
                    resource.owner = owner
                    resource.jid = groupchat
                    resource.resource = owner
                    resource.status = .offline
                    resource.entity = isIncognito ? .incognitoChat : .groupchat
                    resource.priority = -5
                    resource.isTemporary = true
                    resource.primary = ResourceStorageItem.genPrimary(jid: groupchat, owner: owner, resource: owner)
                    transaction(commitTransaction) {
                        realm.add(resource, update: .modified)
                        realm.add(instance, update: .modified)
                    }
                    
                }
            } catch {
                DDLogDebug("GroupchatManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        // Old format: <reference type='mutable'><user>...</user></reference>
        // V3 format: <x xmlns='https://xabber.com/protocol/groups'><user>...</user></x>
        var messageUserCard: DDXMLElement? = bareMessage
            .elements(forName: "reference")
            .filter({ return $0.attributeStringValue(forName: "type") == "mutable" })
            .first(where: { $0.element(forName: "user") != nil })?
            .element(forName: "user")
        var isV3UserCard = false
        if messageUserCard == nil {
            messageUserCard = bareMessage
                .element(forName: "x", xmlns: getPrimaryNamespace())?
                .element(forName: "user")
            if messageUserCard != nil { isV3UserCard = true }
        }
        if let userCard = messageUserCard {
            // V3: if <system-message> is present alongside <user>, pass actionType
            // Old format reference: always pass nil (sender identity only)
            let cardAction: String? = isV3UserCard ? actionType : nil
            let card = updateUserCard(userCard,
                                      groupchat: groupchat,
                                      trustedSource: isTrustedSource,
                                      messageAction: cardAction,
                                      commitTransaction: commitTransaction,
                                      cardDate: getDelayedDate(message) ?? Date())
            if card?.isMe ?? false {
//                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//                    user.groupchats.requestUserPermissions(stream, groupchat: groupchat, user: card?.userId ?? "0")
//                })
            }
        }
        // Old format system message user card: <x xmlns='...#system-message'><user>
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
//                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//                    user.groupchats.requestUserPermissions(stream, groupchat: groupchat, user: card?.userId ?? "0")
//                })
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
            item.callback?("fail")
            item.invitesCallback?(item.value, "fail")
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
            case onGroupInfo(iq): return true
            case onReceiveUserPermissionssList(iq): return true
            case onReceiveDefaultPermissionsList(iq): return true
            case onReceiveNewbiesPermissionsList(iq): return true
            case onSuccesInvite(iq): return true
            case onInviteList(iq): return true
            case onRevoke(iq): return true
            case onBlockList(iq): return true
            case onBlock(iq): return true
            case onUnblock(iq): return true
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
