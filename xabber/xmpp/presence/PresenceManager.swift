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
import RealmSwift
import RxSwift
import RxCocoa
import XMPPFramework
import Network

class PresenceManager: AbstractXMPPManager {
    
    enum PresenceDirection {
        case incoming
        case outgoing
    }
    
    internal var bag: DisposeBag = DisposeBag()
    internal var enqueuedItems: BehaviorRelay<[XMPPPresence]> = BehaviorRelay<[XMPPPresence]>(value: [])

    init(withOwner owner: String, withoutSubscribtion: Bool) {
        super.init(withOwner: owner)
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        subscribe()
    }
    
    override func namespaces() -> [String] {
        return [
            "http://jabber.org/protocol/caps",
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    fileprivate final func subscribe() {
        bag = DisposeBag()
        
        checkTemporarySubscribtions()
        RunLoop.main.perform {
            self.resetResources(commitTransaction: true)
        }
        
        enqueuedItems
            .asObservable()
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                RunLoop.main.perform {
                do {
                    let realm = try  WRealm.safe()
                        let presences = results.compactMap({ return $0 })
                    
                        realm.writeAsync {
                            presences.forEach { self.parse(contact: $0) }
                        }
                        AccountManager
                            .shared
                            .find(for: self.owner)?
                            .devices
                            .readBatch(presences, commitTransaction: true)
                    
                    } catch {
                        DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
                    }
                }
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func processQueue() {
        
    }
    
    open func unsubscribed(_ xmppStream: XMPPStream, jid: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    realm.delete(instance)
                }
            }
            xmppStream.send(XMPPPresence(type: .unsubscribed, to: XMPPJID(string: jid)))
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    open func unsubscribe(_ xmppStream: XMPPStream, jid: String) {
        xmppStream.send(XMPPPresence(type: .unsubscribe, to: XMPPJID(string: jid)))
    }
    
    
    open func subscribed(_ xmppStream: XMPPStream, jid: String, storePreaproved: Bool = true) {
        do {
            let realm = try  WRealm.safe()
            if storePreaproved {
                let instance = PreaprovedSubscribtionStorageItem()
                instance.owner = owner
                instance.jid = jid
                instance.primary = PreaprovedSubscribtionStorageItem.genPrimary(jid: jid, owner: owner)
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            xmppStream.send(XMPPPresence(type: .subscribed, to: XMPPJID(string: jid)))
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        do {
            let realm = try WRealm.safe()
            if let instance =  realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                try realm.write {
                    instance.ask = .none
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }

    }
    
    
    open func subscribe(_ xmppStream: XMPPStream, jid: String) {
        xmppStream.send(XMPPPresence(type: .subscribe, to: XMPPJID(string: jid)))
    }
    
    open func sendSubscribtionRequest(_ xmppStream: XMPPStream, jid: String) {
        do {
            let realm = try  WRealm.safe()
            let instance = PreaprovedSubscribtionStorageItem()
            instance.owner = owner
            instance.jid = jid
            instance.primary = PreaprovedSubscribtionStorageItem.genPrimary(jid: jid, owner: owner)
            try realm.write {
                realm.add(instance, update: .modified)
            }
            xmppStream.send(XMPPPresence(type: .subscribe, to: XMPPJID(string: jid)))
            xmppStream.send(XMPPPresence(type: .subscribed, to: XMPPJID(string: jid)))

        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: jid)
        })
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    instance.ask = .out
                }
            } else {
                let instance = RosterStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .undefined
                instance.ask = .out
                try realm.write {
                    if realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil { return }
                    realm.add(instance)
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func receiveError(_ presence: XMPPPresence) -> Bool {
//        guard presence.presenceType == .error,
//            let jid = presence.from?.bare else {
//                return false
//        }
//        do {
//            let realm = try  WRealm.safe()
//            if let instance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self,
//                                           forPrimaryKey: [jid, owner].prp()) {
//                try realm.write {
//                    realm.delete(instance)
//                }
//            }
//        } catch {
//            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
//        }
//
//        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
//            user.presences.unsubscribe(stream, jid: jid)
//            user.presences.unsubscribed(stream, jid: jid)
//        })
        return false
    }
    
    public final func clearAuthMessage(for jid: String) {
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
                    .sorted(byKeyPath: "date", ascending: false).last
                try realm.write {
                    realm.delete(authMessage)
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .omemo))?.lastMessage = lastMessageForChat
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func receivePreapruvedSubscribeRequest(_ presence: XMPPPresence) -> Bool {
        guard let jid = presence.from?.bare,
            presence.presenceType == .subscribe else {
                return false
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self,
                                           forPrimaryKey: [jid, owner].prp()) {
                AccountManager
                    .shared
                    .find(for: owner)?
                    .unsafeAction({ (user, stream) in
                        stream.send(XMPPPresence(
                                        type: .subscribed,
                                        to: XMPPJID(string: jid)))
                    })
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    open func updateMyself(_ xmppStream: XMPPStream, with status: ResourceStorageItem, ver: String, to jid: XMPPJID?) {
        var show: XMPPPresence.ShowType? = nil
        switch status.status {
        case .offline, .online:
            break
        case .xa:
            show = XMPPPresence.ShowType.xa
        case .away:
            show = XMPPPresence.ShowType.away
        case .dnd:
            show = XMPPPresence.ShowType.dnd
        case .chat:
            show = XMPPPresence.ShowType.chat
        }
        let presence = XMPPPresence(type: nil,
                                    show: show,
                                    status: status.statusMessage,
                                    to: jid)
        if let deviceElement = AccountManager.shared.find(for: self.owner)?.devices.deviceElement  {
            presence.addChild(deviceElement)
        }
        presence.addChild(DDXMLElement(name: "priority", stringValue: "67"))
        let caps = DDXMLElement.element(withName: "c") as! DDXMLElement
        caps.setXmlns("http://jabber.org/protocol/caps")
        caps.addAttribute(withName: "hash", stringValue: "sha-1")
        caps.addAttribute(withName: "node", stringValue: "https://www.xabber.com")
        caps.addAttribute(withName: "ver", stringValue: ver)
        presence.addChild(caps)
//        xmppStream.send(DDXMLElement(name: "inactive", xmlns: "urn:xmpp:csi:0"))
        if status.status != .offline {
            xmppStream.send(presence)
        }
    }
    
    final func probe(_ xmppStream: XMPPStream, jid: String) {
        let presence = XMPPPresence(type: .probe, to: XMPPJID(string: jid))
        xmppStream.send(presence)
    }
    
    public static func parseStatusValue(from presence: XMPPPresence) -> ResourceStatus {
        if presence.type == "unavailable" {
            return .offline
        }
        if let show = presence.element(forName: "show") {
            return RosterUtils.shared.convertShowStatus(show.stringValue ?? "unavailable")
        }
        return .online
    }
    
    public static func parseStatusMessage(from presence: XMPPPresence) -> String {
        return presence.element(forName: "status")?.stringValue ?? ""
    }
    
    open func read(withPresence presence: XMPPPresence) -> Bool {
        switch true {
        case receiveError(presence): return true
        case receivePreapruvedSubscribeRequest(presence): return true
        case didReceiveSubscribeRequest(presence): return true
        case didReceiveUnsubscribedRequest(presence): return true
        case didReceiveMyPresence(presence): return true
        case didReceiveContactPresence(presence): return true
        default: return false
        }
    }
    
    internal func parse(contact presence: XMPPPresence) {
        do {
            guard let fromJid = presence.from,
                fromJid.bare != owner,
                let resource = fromJid.resource else {
                    return
            }
            
            let realm = try  WRealm.safe()
            if PresenceManager.parseStatusValue(from: presence) == .offline && presence.element(forName: "x", xmlns: GroupchatManager.staticGetNamespace()) == nil {
                if let instance = realm.object(ofType: ResourceStorageItem.self,
                                               forPrimaryKey: [fromJid.bare,
                                                               resource,
                                                               owner].prp()) {
                    instance.status = .offline
                    realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [fromJid.bare, owner].prp())?.notes = " "
                }
            } else {
                realm.autorefresh = true
                if let instance = realm.object(ofType: ResourceStorageItem.self,
                                forPrimaryKey: [fromJid.bare,
                                                fromJid.resource ?? "",
                                                owner].prp()) {
                    
                    if instance.isInvalidated { return }
                    
                    instance.status = PresenceManager.parseStatusValue(from: presence)
                    instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                    instance.priority = presence.priority
                    instance.timestamp = presence.delayedDeliveryDate ?? Date()
                } else {
                    let instance = ResourceStorageItem()
                    instance.jid = fromJid.bare
                    instance.owner = owner
                    instance.resource = fromJid.resource ?? ""
                    instance.status = PresenceManager.parseStatusValue(from: presence)
                    instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                    instance.priority = presence.priority
                    instance.client = ""
                    instance.isTemporary = false
                    instance.timestamp = presence.delayedDeliveryDate ?? Date()
                    instance.primary = ResourceStorageItem.genPrimary(jid: fromJid.bare, owner: owner, resource: fromJid.resource ?? "")
                    realm.add(instance, update: .modified)
                }
                realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [fromJid.bare, owner].prp())?.notes = " "
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func didReceiveMyPresence(_ presence: XMPPPresence) -> Bool {
        guard let from = presence.from,
            let to = presence.to,
            from.full != to.full,
            from.bare == owner else { return false }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                                           forPrimaryKey: [from.bare,
                                                           from.resource ?? "",
                                                           owner].prp()) {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.status = PresenceManager.parseStatusValue(from: presence)
                        instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                        instance.priority = presence.priority
                        instance.timestamp = presence.delayedDeliveryDate ?? Date()
                    }
                }
            } else {
                let instance = ResourceStorageItem()
                instance.jid = from.bare
                instance.owner = owner
                instance.resource = from.resource ?? ""
                instance.status = PresenceManager.parseStatusValue(from: presence)
                instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                instance.priority = presence.priority
                instance.client = ""
                instance.isTemporary = false
                instance.timestamp = presence.delayedDeliveryDate ?? Date()
                instance.primary = ResourceStorageItem.genPrimary(jid: from.bare, owner: owner, resource: from.resource ?? "")
                
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(instance, update: .modified)
                    }
                }
            }
        } catch {
            DDLogDebug("cant update presence info for account \(owner)")
        }
        return true
    }
    
    internal func didReceiveContactPresence(_ presence: XMPPPresence) -> Bool {
        guard let fromJid = presence.from,
            fromJid.bare != owner,
            fromJid.resource != nil else {
                return false
        }
        var value = enqueuedItems.value
        value.append(presence)
        enqueuedItems.accept(value)
        
        return true
    }
    
    internal func didReceiveUnsubscribedRequest(_ presence: XMPPPresence) -> Bool {
            guard let jid = presence.from?.bare,
                jid != owner,
                presence.presenceType == .unsubscribed else {
                    return false
            }
            do {
                let realm = try WRealm.safe()
                if let instance =  realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                    try realm.write {
                        instance.subscribtion = .none
                        instance.ask = .none
                    }
                }
            } catch {
                DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
            }
            return true
        }
    
    internal func didReceiveSubscribeRequest(_ presence: XMPPPresence) -> Bool {
        guard let jid = presence.from?.bare,
            jid != owner,
            presence.presenceType == .subscribe else {
                return false
        }
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: jid)
        })
        
        do {
            let realm = try  WRealm.safe()
            let notificationId = ["subscribtion_request", jid, owner].prp()
            if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: notificationId)) {
                try realm.write {
                    instance.date = Date()
                    instance.associatedJid = jid
                    instance.displayedNick = presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue
                }
            } else {
                let instance = NotificationStorageItem()
                instance.owner = owner
                instance.jid = jid
                instance.uniqueId = notificationId
                instance.primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: notificationId)
                instance.associatedJid = jid
                instance.displayedNick = presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue
                instance.date = Date()
                instance.isRead = true
                instance.shouldShow = true
                instance.category = .contact
                instance.metadata = [
                    "message": presence.status ?? "",
                    "username": presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue ?? jid
                ]
                try realm.write {
                    realm.add(instance)
                }
            }
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    instance.ask = .in
                    if instance.username.isEmpty {
                        instance.username = presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue ?? ""
                    }
                }
            } else {
                let instance = RosterStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.username = presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue ?? ""
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .undefined
                instance.ask = .in
                try realm.write {
                    if realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil { return }
                    realm.add(instance)
                }
            }
            
            if realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil {
                return true
            }
            
            AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                user.avatarManager.requestPubSubItem(stream, node: .metadata, jid: jid, by: "")
            })
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    
    open func didResetState() {
//        self.unsubscribe()
//        self.subscribe()
//        RunLoop.main.perform {
//            self.resetResources(commitTransaction: true)
//        }
    }
    
    func resetResources(for jid: String? = nil,commitTransaction: Bool) {
        let resource = AccountManager.shared.find(for: owner)?.resource ?? ""
        do {
            let realm = try WRealm.safe()
            var collection = realm.objects(ResourceStorageItem.self).filter("owner == %@ AND resource != %@ AND statusExt == %@", owner, resource, RosterItemEntity.contact.rawValue)
            if let jid = jid {
                collection = collection.filter("jid == %@", jid)
            }
            if commitTransaction {
                realm.writeAsync {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
            
        } catch {
            DDLogDebug("cant reset resources for \((jid == nil) ? "all contacts" : jid!) of \(self.owner)")
        }
    }
    
    override func clearSession() {
//        unsubscribe()
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            let collection = realm.objects(ResourceStorageItem.self)
                .filter("owner == %@", owner)
            let preaproved = realm.objects(PreaprovedSubscribtionStorageItem.self).filter("owner == %@", owner)
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                    realm.delete(preaproved)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    deinit {
        unsubscribe()
    }
    
}
