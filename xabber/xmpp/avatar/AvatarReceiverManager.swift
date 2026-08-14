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
import RxSwift
import RxCocoa
import RealmSwift
import CocoaLumberjack

class XmppAvatarManager: AbstractXMPPManager {
    
    struct PubSubItemRequestMetadata: Hashable, Equatable {
        
        let jid: String
        let itemId: String
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
            hasher.combine(itemId)
        }
    }
    
    override func namespaces() -> [String] {
        return [
            "urn:xmpp:avatar:metadata+notify",
        ]
    }
    
    private var pubsubItemsIds: BehaviorRelay<Set<PubSubItemRequestMetadata>> = BehaviorRelay(value: Set<PubSubItemRequestMetadata>())
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
    }
    
    public final func readFromVcard(_ iq: XMPPIQ) -> Bool {
        guard let base64 = iq
                .element(forName: "vCard", xmlns: "vcard-temp")?
                .element(forName: "PHOTO")?
                .element(forName: "BINVAL")?
                .stringValue,
              iq.iqType == .result,
              let jid = iq.from?.bare else {
            return false
        }
//        guard let image = base64ToImage(base64) else {
//            return false
//        }
        
//        self.storeBase64(jid: jid, avatar: base64, imageHash: base64.sha1(), source: .vcard)
        return true
    }
    
    public final func readFromPubSubData(_ iq: XMPPIQ) -> Bool {
        guard let item = iq
                .element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .elements(forName: "items")
                .first(where: { $0.attributeStringValue(forName: "node") == "urn:xmpp:avatar:data" })?
                .element(forName: "item"),
              let itemId = item.attributeStringValue(forName: "id"),
              let base64 = item
                .element(forName: "data", xmlns: "urn:xmpp:avatar:data")?
                .stringValue,
              let jid = iq.from?.bare else {
            return false
        }
        guard let image = base64ToImage(base64) else {
            return false
        }
        let avatarKey = [itemId, owner].prp()
        DefaultAvatarManager.shared.storeImage(for: avatarKey, image: image)
        do {
            let realm = try WRealm.safe()
            var hasManagedRecord = false
            if jid == owner {
                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                    hasManagedRecord = true
                    if instance.avatarMaxUrl?.isEmpty == false
                        || instance.avatarMinUrl?.isEmpty == false {
                        return true
                    }
                    try realm.write {
                        instance.oldschoolAvatarKey = avatarKey
                        instance.avatarUpdatedTS = Date().timeIntervalSince1970
                        instance.updatedTS = Date().timeIntervalSince1970
                    }
                }
            } else {
                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                    hasManagedRecord = true
                    if instance.avatarMaxUrl?.isEmpty == false
                        || instance.avatarMinUrl?.isEmpty == false {
                        return true
                    }
                    try realm.write {
                        instance.oldschoolAvatarKey = avatarKey
                        instance.avatarUpdatedTS = Date().timeIntervalSince1970
                        instance.updatedTS = Date().timeIntervalSince1970
                        realm.objects(NotificationStorageItem.self).filter("owner == %@ AND jid == %@", owner, jid).forEach {
                            $0.metadata_ = $0.metadata_
                        }
                    }
                }
            }
            if hasManagedRecord {
                DefaultAvatarManager.shared.publishPushAvatarSnapshot(
                    image,
                    sourceKey: avatarKey,
                    metadataRevision: avatarKey,
                    owner: owner,
                    jid: jid
                )
            } else if jid != owner {
                DefaultAvatarManager.shared.publishTransientPushAvatarSnapshot(
                    image,
                    sourceKey: avatarKey,
                    metadataRevision: avatarKey,
                    owner: owner,
                    jid: jid
                )
            }
        } catch {
            DDLogDebug("XMPPAvatarManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }

    public final func readFromPubSubMetadata(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result,
              let jid = iq.from?.bare,
              let item = iq
                .element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .elements(forName: "items")
                .first(where: { $0.attributeStringValue(forName: "node") == AvatarNode.metadata.rawValue })?
                .element(forName: "item") else {
            return false
        }
        return readFromPubSubMetadata(jid: jid, pubsub: item)
    }
    
    public final func readFromPubSubMetadata(jid: String, pubsub item: DDXMLElement) -> Bool {
        guard let id = item.attributeStringValue(forName: "id") else {
            return false
        }
        guard let metadata = item.element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata"),
              let info = metadata.element(forName: "info") else {
            return false
        }
        if let url = info.attributeStringValue(forName: "url") {
            do {
                let realm = try WRealm.safe()
                var maxUrl: String = url
                var minUrl: String? = nil
                info.elements(forName: "thumbnail").forEach {
                    thumb in
                    if let thumbUrl = thumb.attributeStringValue(forName: "uri") {
                        let width = thumb.attributeIntegerValue(forName: "witdth")
                        if width >= 512 {
                            maxUrl = thumbUrl
                            return
                        } else if width >= 256 {
                            maxUrl = thumbUrl
                            return
                        }
                    }
                }
                
                info.elements(forName: "thumbnail").forEach {
                    thumb in
                    if let thumbUrl = thumb.attributeStringValue(forName: "uri") {
                        let width = thumb.attributeIntegerValue(forName: "witdth")
                        if width < 256 && width >= 128 {
                            minUrl = thumbUrl
                            return
                        } else if width < 128 {
                            minUrl = thumbUrl
                            return
                        }
                    }
                }
                if jid == self.owner {
                    if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                        if instance.oldschoolAvatarKey == id,
                           instance.avatarMaxUrl == maxUrl,
                           instance.avatarMinUrl == minUrl {
                            return true
                        }
                        if instance.oldschoolAvatarKey != id
                            || instance.avatarMaxUrl != maxUrl
                            || instance.avatarMinUrl != minUrl {
                            DefaultAvatarManager.shared.invalidatePushAvatarSnapshot(
                                owner: self.owner,
                                jid: jid
                            )
                        }
                        try realm.write {
                            instance.avatarMaxUrl = maxUrl
                            instance.avatarMinUrl = minUrl
                            instance.oldschoolAvatarKey = id
                            instance.avatarUpdatedTS = Date().timeIntervalSince1970
                            instance.updatedTS = Date().timeIntervalSince1970
                        }
                    }
                } else {
                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        if instance.oldschoolAvatarKey == id,
                           instance.avatarMaxUrl == maxUrl,
                           instance.avatarMinUrl == minUrl {
                            return true
                        }
                        if instance.oldschoolAvatarKey != id {
                            DefaultAvatarManager.shared.invalidatePushAvatarSnapshot(
                                owner: self.owner,
                                jid: jid
                            )
                        }
                        try realm.write {
                            instance.avatarMaxUrl = maxUrl
                            instance.avatarMinUrl = minUrl
                            instance.oldschoolAvatarKey = id
                            instance.avatarUpdatedTS = Date().timeIntervalSince1970
                            instance.updatedTS = Date().timeIntervalSince1970
                            realm.objects(NotificationStorageItem.self).filter("owner == %@ AND jid == %@", owner, jid).forEach {
                                $0.metadata_ = $0.metadata_
                            }
                        }
                        let username = instance.displayName
                        let avatarUrl = instance.avatarUrl
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl)
                    }
                }
                
            } catch {
                DDLogDebug("XMPPAvatarManager: \(#function). \(error.localizedDescription)")
            }
        } else {
            do {
                let avatarKey = [id, owner].prp()
                let realm = try WRealm.safe()
                if jid == self.owner {
                    if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                        if instance.oldschoolAvatarKey == avatarKey {
                            return true
                        }
                    }
                } else {
                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        if instance.oldschoolAvatarKey == avatarKey {
                            return true
                        }
                    }
                }
            } catch {
                DDLogDebug("XmppAvatarManager: \(#function). \(error.localizedDescription)")
            }
            self.enqueuePubSubItemRequest(node: .data, jid: jid, by: id)
        }
        return true
    }
    
    public final func readMessage(_ message: XMPPMessage) -> Bool {
        guard message.messageType == .headline,
              let event = message.element(forName: "event", xmlns: "http://jabber.org/protocol/pubsub#event"),
              let items = event.element(forName: "items"),
              let node = items.attributeStringValue(forName: "node"),
              node == AvatarNode.metadata.rawValue,
              let item = items.element(forName: "item"),
              let jid = message.from?.bare else {
            return false
        }
        return readFromPubSubMetadata(jid: jid, pubsub: item)
    }
    
    enum AvatarNode: String {
        case metadata = "urn:xmpp:avatar:metadata"
        case data = "urn:xmpp:avatar:data"
    }

    public final func enqueuePubSubItemRequest(node: AvatarNode, jid: String, by itemId: String) {
        guard let account = AccountManager.shared.find(for: self.owner) else {
            return
        }
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .background,
            resource: .avatar,
            deduplicationKey: "avatar.\(self.owner).\(node.rawValue).\(jid).\(itemId)",
            requiresAuthenticatedStream: false
        ) { [weak self] _, stream, finish in
            guard let self else {
                finish()
                return
            }
            guard stream.isAuthenticated else {
                finish()
                return
            }
            self.requestPubSubItem(stream, node: node, jid: jid, by: itemId)
            finish()
        }
    }
        
    public final func requestPubSubItem(_ xmppStream: XMPPStream, node: AvatarNode, jid: String, by itemId: String) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: node.rawValue)
        if itemId.isNotEmpty {
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "id", stringValue: itemId)
            items.addChild(item)
        } else {
            items.addAttribute(withName: "max_items", integerValue: 1)
        }
        pubsub.addChild(items)
        let elementId = [UUID().uuidString, ":IQ:avatar:pubsub"].joined()
        let iq = XMPPIQ(iqType: .get, to: XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        self.queryIds.insert(elementId)
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub") != nil,
              self.queryIds.contains(elementId) else {
            return false
        }
        defer {
            self.queryIds.remove(elementId)
        }
        if iq.iqType == .error {
            return true
        }
        switch true {
        case self.readFromPubSubData(iq): return true
        case self.readFromPubSubMetadata(iq): return true
        default:
            DDLogDebug("XmppAvatarManager: unhandled known PubSub avatar IQ id=\(elementId)")
            return true
        }
    }
}
