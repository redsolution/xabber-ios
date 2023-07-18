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
    private var bag: DisposeBag = DisposeBag()
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        self.subscribe()
    }
    
    private final func subscribe() {
        bag = DisposeBag()
//        pubsubItemsIds
//            .asObservable()
//            .debounce(.seconds(2), scheduler: MainScheduler.asyncInstance)
//            .subscribe { value in
//                if value.isEmpty {
//                    return
//                }
//                AccountManager
//                    .shared
//                    .newBackgroundTask(
//                        for: self.owner,
//                        task: .pubsubAvatarsRequests(value)
//                    )
//                self.pubsubItemsIds.accept(Set())
//            } onError: { error in
//
//            } onCompleted: {
//
//            } onDisposed: {
//
//            }
//            .disposed(by: bag)
    }
    
    private final func unsubscribe() {
        bag = DisposeBag()
    }
    
    private final func storeBase64(jid: String, avatar: String, imageHash: String, source: AvatarStorageItem.Kind, userId: String? = nil) {
        guard let image = base64ToImage(avatar) else {
            return
        }
        let images = [
            DefaultAvatarManager.SizedImage(image: image, url: nil, size: .original)
        ]
        if let userId = userId {
            DefaultAvatarManager
                .shared
                .storeGroupAvatar(user: userId, jid: jid, owner: self.owner, hash: imageHash, images: images, kind: source)
        } else {
            DefaultAvatarManager
                .shared
                .storeAvatar(jid: jid, owner: self.owner, hash: imageHash, images: images, kind: source)
        }
    }
        
    private final func storeHttp(jid: String, imageHash: String, userId: String? = nil, images: [DefaultAvatarManager.SizedImage]) {
        
        if let userId = userId {
            DefaultAvatarManager
                .shared
                .storeGroupAvatar(user: userId, jid: jid, owner: owner, hash: imageHash, images: images, kind: .xabber)
        } else {
            DefaultAvatarManager
                .shared
                .storeAvatar(jid: jid, owner: owner, hash: imageHash, images: images, kind: .xabber)
        }
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
        self.storeBase64(jid: jid, avatar: base64, imageHash: base64.sha1(), source: .vcard)
        return true
    }
    
    public final func readFromPubSubData(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              let item = iq
                .element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .elements(forName: "items")
                .first(where: { $0.attributeStringValue(forName: "node") == "urn:xmpp:avatar:data" })?
                .element(forName: "item"),
              let itemId = item.attributeStringValue(forName: "id"),
              let base64 = item
                .element(forName: "data", xmlns: "urn:xmpp:avatar:data")?
                .stringValue,
              iq.iqType == .result,
              let jid = iq.from?.bare else {
            return false
        }
        self.storeBase64(jid: jid, avatar: base64, imageHash: itemId, source: .pep)
        self.queryIds.remove(elementId)
        return true
    }
    
    public final func readFromPubSubMetadata(jid: String, pubsub item: DDXMLElement) -> Bool {
        guard let id = item.attributeStringValue(forName: "id") else {
            return false
        }
        if !DefaultAvatarManager.shared.isImageCached(jid: jid, owner: owner, imageHash: id) {
            if let info = item.element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")?
                .element(forName: "info"),
               let url = info.attributeStringValue(forName: "url") {
                let originalImage = DefaultAvatarManager.SizedImage(url: url, size: .original)
                var images = info.elements(forName: "thumbnail").compactMap {
                    let width = CGFloat($0.attributeFloatValue(forName: "width"))
                    if let uri = $0.attributeStringValue(forName: "uri"),
                       let size = DefaultAvatarManager.ImageSize(rawValue: width) {
                        return DefaultAvatarManager.SizedImage(url: uri, size: size)
                    }
                    return nil
                }
                images.append(originalImage)
                DefaultAvatarManager.shared.storeAvatar(jid: jid, owner: owner, hash: id, images: images, kind: images.count > 1 ? .xabber : .pep)
            } else {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.avatarManager.self.requestPubSubItem(stream, node: .data, jid: jid, by: id)
                })
            }
            return true
        }
        return false
    }
    
    public final func readFromUserCard(groupchat: String, user card: DDXMLElement) -> Bool {
        guard let userId = card.attributeStringValue(forName: "id"),
              let info = card
                .element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")?
                .element(forName: "info"),
              let imageHash = info.attributeStringValue(forName: "id"),
              !DefaultAvatarManager.shared.isImageCachedGroup(user: userId, jid: groupchat, owner: owner, imageHash: imageHash),
              let urlRaw = info.attributeStringValue(forName: "url") else {
            return false
        }
        DefaultAvatarManager.shared.storeGroupAvatar(
            user: userId,
            jid: groupchat,
            owner: owner,
            hash: imageHash,
            images: [DefaultAvatarManager.SizedImage(url: urlRaw, size: .original)],
            kind: .xabber
        )
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
