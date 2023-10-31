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
    
//    private final func storeBase64(jid: String, avatar: String, imageHash: String, source: AvatarStorageItem.Kind, userId: String? = nil) {
//        guard let image = base64ToImage(avatar) else {
//            return
//        }
//        let images = [
//            DefaultAvatarManager.SizedImage(image: image, url: nil, size: .original)
//        ]
//        if let userId = userId {
//            DefaultAvatarManager
//                .shared
//                .storeGroupAvatar(user: userId, jid: jid, owner: self.owner, hash: imageHash, images: images, kind: source)
//        } else {
//            DefaultAvatarManager
//                .shared
//                .storeAvatar(jid: jid, owner: self.owner, hash: imageHash, images: images, kind: source)
//        }
//    }
//        
//    private final func storeHttp(jid: String, imageHash: String, userId: String? = nil, images: [DefaultAvatarManager.SizedImage]) {
//        
//        if let userId = userId {
//            DefaultAvatarManager
//                .shared
//                .storeGroupAvatar(user: userId, jid: jid, owner: owner, hash: imageHash, images: images, kind: .xabber)
//        } else {
//            DefaultAvatarManager
//                .shared
//                .storeAvatar(jid: jid, owner: owner, hash: imageHash, images: images, kind: .xabber)
//        }
//    }
    
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
            if jid == owner {
                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                    if instance.avatarMaxUrl != nil {
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
                    if instance.avatarMaxUrl != nil {
                        return true
                    }
                    try realm.write {
                        instance.oldschoolAvatarKey = avatarKey
                        instance.avatarUpdatedTS = Date().timeIntervalSince1970
                        instance.updatedTS = Date().timeIntervalSince1970
                    }
                }
            }
            
        } catch {
            DDLogDebug("XMPPAvatarManager: \(#function). \(error.localizedDescription)")
        }
        return true
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
                        try realm.write {
                            instance.avatarMaxUrl = maxUrl
                            instance.avatarMinUrl = minUrl
                            instance.oldschoolAvatarKey = nil
                            instance.avatarUpdatedTS = Date().timeIntervalSince1970
                            instance.updatedTS = Date().timeIntervalSince1970
                        }
                    }
                } else {
                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        try realm.write {
                            instance.avatarMaxUrl = maxUrl
                            instance.avatarMinUrl = minUrl
                            instance.oldschoolAvatarKey = nil
                            instance.avatarUpdatedTS = Date().timeIntervalSince1970
                            instance.updatedTS = Date().timeIntervalSince1970
                        }
                    }
                }
                
            } catch {
                DDLogDebug("XMPPAvatarManager: \(#function). \(error.localizedDescription)")
            }
        } else {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.avatarManager.self.requestPubSubItem(stream, node: .data, jid: jid, by: id)
            })
        }
        return true
    }
    
    public final func readFromUserCard(groupchat: String, user card: DDXMLElement) -> Bool {
        guard let userId = card.attributeStringValue(forName: "id"),
              let info = card
                .element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")?
                .element(forName: "info"),
              let imageHash = info.attributeStringValue(forName: "id"),
              let urlRaw = info.attributeStringValue(forName: "url") else {
            return false
        }
//        DefaultAvatarManager.shared.storeGroupAvatar(
//            user: userId,
//            jid: groupchat,
//            owner: owner,
//            hash: imageHash,
//            images: [DefaultAvatarManager.SizedImage(url: urlRaw, size: .original)],
//            kind: .xabber
//        )
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
        switch true {
        case self.readFromPubSubData(iq): return true
        default: return false
        }
    }
}
