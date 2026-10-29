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
import CryptoSwift

class XmppAvatarManager: AbstractXMPPManager {

    private struct PubSubRequest {
        let jid: String
        let node: AvatarNode
        let itemId: String
        let metadataRevision: UInt64
        let generation: UInt64
        let deadline: TimeInterval
    }

    private struct MetadataState {
        let itemId: String
        let hasURL: Bool
        let revision: UInt64
    }

    private let requestLock = NSLock()
    private var requestsByID: [String: PubSubRequest] = [:]
    private var metadataByJID: [String: MetadataState] = [:]
    private var sessionGeneration: UInt64 = 0

    // Session reset/disconnect owns invalidation. Preparing extensions can run
    // after initial PEP notifications, so it must not discard their queued data.
    internal var pubSubRequestNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private static let pubSubRequestTimeout: TimeInterval = 30

    /// Lost responses release their reservation on the next request/response.
    /// No automatic retry is scheduled: only a new explicit demand sends again.
    private func expirePubSubRequestsLocked(now: TimeInterval) -> [String] {
        let expired = requestsByID.compactMap { $0.value.deadline <= now ? $0.key : nil }
        for id in expired { requestsByID.removeValue(forKey: id) }
        return expired
    }

    override func clearSession() {
        requestLock.lock()
        sessionGeneration &+= 1
        let cancelledIDs = Array(requestsByID.keys)
        requestsByID.removeAll()
        metadataByJID.removeAll()
        requestLock.unlock()
        cancelledIDs.forEach { queryIds.remove($0) }
        super.clearSession()
    }
    
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
              let image = base64ToImage(base64) else {
            return false
        }
        // The account delegate invokes this only after VCardManager claims
        // its correlated result; own vCards may omit `from`.
        let jid = iq.from?.bare ?? owner
        let avatarKey = ["vcard:\(base64.sha1())", owner].prp()
        do {
            let realm = try WRealm.safe()
            let instance: Object?
            let existingKey: String?
            let existingURL: String?
            if jid == owner {
                let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)
                instance = account
                existingKey = account?.oldschoolAvatarKey
                existingURL = account?.avatarMaxUrl ?? account?.avatarMinUrl
            } else {
                let roster = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))
                instance = roster
                existingKey = roster?.oldschoolAvatarKey
                existingURL = roster?.avatarMaxUrl ?? roster?.avatarMinUrl
            }
            // PEP is authoritative, including data avatars without a URL.
            guard existingURL?.isEmpty != false,
                  existingKey == nil || existingKey?.isEmpty == true || existingKey?.hasPrefix("vcard:") == true else { return true }
            DefaultAvatarManager.shared.storeImage(for: avatarKey, image: image)
            if let instance {
                let update = {
                    if let account = instance as? AccountStorageItem {
                        account.oldschoolAvatarKey = avatarKey
                        account.avatarUpdatedTS = Date().timeIntervalSince1970
                        account.updatedTS = Date().timeIntervalSince1970
                    } else if let roster = instance as? RosterStorageItem {
                        roster.oldschoolAvatarKey = avatarKey
                        roster.avatarUpdatedTS = Date().timeIntervalSince1970
                        roster.updatedTS = Date().timeIntervalSince1970
                    }
                }
                if realm.isInWriteTransaction { update() } else { try realm.write(update) }
                DefaultAvatarManager.shared.publishPushAvatarSnapshot(
                    image, sourceKey: avatarKey, metadataRevision: avatarKey, owner: owner, jid: jid
                )
            }
        } catch {
            DDLogDebug("XmppAvatarManager: \(#function). \(error.localizedDescription)")
            return false
        }
        return true
    }
    
    public final func readFromPubSubData(_ iq: XMPPIQ, publisherJID: String? = nil) -> Bool {
        guard iq.iqType == .result,
              let item = iq
                .element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .elements(forName: "items")
                .first(where: { $0.attributeStringValue(forName: "node") == "urn:xmpp:avatar:data" })?
                .element(forName: "item"),
              let itemId = item.attributeStringValue(forName: "id"),
              let base64 = item
                .element(forName: "data", xmlns: "urn:xmpp:avatar:data")?
                .stringValue,
              let jid = publisherJID ?? iq.from?.bare else {
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
                    try realm.write {
                        instance.avatarMaxUrl = nil
                        instance.avatarMinUrl = nil
                        instance.oldschoolAvatarKey = avatarKey
                        instance.avatarUpdatedTS = Date().timeIntervalSince1970
                        instance.updatedTS = Date().timeIntervalSince1970
                    }
                }
            } else {
                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                    hasManagedRecord = true
                    try realm.write {
                        instance.avatarMaxUrl = nil
                        instance.avatarMinUrl = nil
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

    public final func readFromPubSubMetadata(_ iq: XMPPIQ, publisherJID: String? = nil) -> Bool {
        guard iq.iqType == .result,
              let jid = publisherJID ?? iq.from?.bare,
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
        requestLock.lock()
        metadataByJID[jid] = MetadataState(
            itemId: id,
            hasURL: info.attributeStringValue(forName: "url")?.isEmpty == false,
            revision: (metadataByJID[jid]?.revision ?? 0) &+ 1
        )
        requestLock.unlock()
        if let url = info.attributeStringValue(forName: "url") {
            do {
                let realm = try WRealm.safe()
                var maxUrl: String = url
                var minUrl: String? = nil
                info.elements(forName: "thumbnail").forEach {
                    thumb in
                    if let thumbUrl = thumb.attributeStringValue(forName: "uri") {
                        let width = thumb.attributeIntegerValue(forName: "width")
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
                        let width = thumb.attributeIntegerValue(forName: "width")
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
                            CommonContactsMetadataManager.shared.update(
                                owner: self.owner,
                                jid: jid,
                                username: instance.displayName,
                                avatarUrl: instance.avatarUrl,
                                avatarOriginalUrl: url
                            )
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
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl, avatarOriginalUrl: url)
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
                        if instance.oldschoolAvatarKey == avatarKey,
                           DefaultAvatarManager.shared.cachedAvatarImage(url: avatarKey) != nil {
                            return true
                        }
                    }
                } else {
                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        if instance.oldschoolAvatarKey == avatarKey,
                           DefaultAvatarManager.shared.cachedAvatarImage(url: avatarKey) != nil {
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
        guard let publisherJID = XMPPJID(string: jid)?.bare,
              let account = AccountManager.shared.find(for: self.owner) else {
            return
        }
        requestLock.lock()
        let expectedGeneration = sessionGeneration
        let expectedMetadataRevision = metadataByJID[publisherJID]?.revision ?? 0
        requestLock.unlock()
        let metadataRevisionKey = node == .metadata ? expectedMetadataRevision : 0
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: publisherJID == owner && node == .data ? .foreground : .background,
            resource: .avatar,
            deduplicationKey: "avatar.\(self.owner).\(expectedGeneration).\(node.rawValue).\(publisherJID).\(itemId).\(metadataRevisionKey)",
            requiresAuthenticatedStream: true
        ) { [weak self] _, stream, finish in
            guard let self else {
                finish()
                return
            }
            guard stream.isAuthenticated else {
                finish()
                return
            }
            self.requestLock.lock()
            let isCurrentGeneration = self.sessionGeneration == expectedGeneration
            let metadata = self.metadataByJID[publisherJID]
            let isCurrentMetadata: Bool
            switch node {
            case .metadata:
                isCurrentMetadata = (metadata?.revision ?? 0) == expectedMetadataRevision
            case .data:
                isCurrentMetadata = metadata.map { !$0.hasURL && $0.itemId == itemId } ?? true
            }
            self.requestLock.unlock()
            guard isCurrentGeneration && isCurrentMetadata else {
                finish()
                return
            }
            self.requestPubSubItem(stream, node: node, jid: publisherJID, by: itemId)
            finish()
        }
    }
        
    public final func requestPubSubItem(_ xmppStream: XMPPStream, node: AvatarNode, jid: String, by itemId: String) {
        guard let publisherJID = XMPPJID(string: jid)?.bare else { return }
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
        let iq = XMPPIQ(iqType: .get, to: XMPPJID(string: publisherJID), elementID: elementId, child: pubsub)
        let now = pubSubRequestNow()
        requestLock.lock()
        let expiredIDs = expirePubSubRequestsLocked(now: now)
        guard !requestsByID.values.contains(where: {
            $0.jid == publisherJID && $0.node == node && $0.itemId == itemId
        }) else {
            requestLock.unlock()
            expiredIDs.forEach { queryIds.remove($0) }
            return
        }
        let requestGeneration = sessionGeneration
        requestsByID[elementId] = PubSubRequest(
            jid: publisherJID,
            node: node,
            itemId: itemId,
            metadataRevision: metadataByJID[publisherJID]?.revision ?? 0,
            generation: requestGeneration,
            deadline: now + Self.pubSubRequestTimeout
        )
        requestLock.unlock()
        expiredIDs.forEach { queryIds.remove($0) }
        self.queryIds.insert(elementId)
        // Reset can race correlation registration. Only the same recorded
        // generation may proceed; never hold requestLock across transport.
        requestLock.lock()
        let isCurrentRequest = requestsByID[elementId]?.generation == requestGeneration
            && sessionGeneration == requestGeneration
        requestLock.unlock()
        guard isCurrentRequest else {
            self.queryIds.remove(elementId)
            return
        }
        xmppStream.send(iq)
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        let now = pubSubRequestNow()
        requestLock.lock()
        let expiredIDs = expirePubSubRequestsLocked(now: now)
        requestLock.unlock()
        expiredIDs.forEach { queryIds.remove($0) }
        guard let elementId = iq.elementID,
              self.queryIds.contains(elementId) else {
            return false
        }
        requestLock.lock()
        let request = requestsByID[elementId]
        let metadata = request.flatMap { metadataByJID[$0.jid] }
        requestLock.unlock()
        guard let request,
              iq.from?.bare == request.jid || (iq.attributeStringValue(forName: "from") == nil && request.jid == owner),
              iq.iqType == .result || iq.iqType == .error else { return false }
        if iq.iqType == .result {
            guard let items = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .elements(forName: "items").first(where: { $0.attributeStringValue(forName: "node") == request.node.rawValue }),
                  request.itemId.isEmpty || items.element(forName: "item")?.attributeStringValue(forName: "id") == request.itemId else { return false }
        }
        defer {
            self.queryIds.remove(elementId)
            requestLock.lock()
            requestsByID.removeValue(forKey: elementId)
            requestLock.unlock()
        }
        if iq.iqType == .error {
            return true
        }
        // An event arriving while the IQ is in flight is newer authority.
        // Consume the owned terminal without replacing that newer avatar.
        if request.node == .metadata,
           request.metadataRevision != (metadata?.revision ?? 0) {
            return true
        }
        if request.node == .data, let metadata,
           metadata.hasURL || metadata.itemId != request.itemId {
            return true
        }
        let didReadRequestedNode: Bool
        switch request.node {
        case .data:
            didReadRequestedNode = readFromPubSubData(iq, publisherJID: request.jid)
        case .metadata:
            didReadRequestedNode = readFromPubSubMetadata(iq, publisherJID: request.jid)
        }
        if !didReadRequestedNode {
            DDLogDebug("XmppAvatarManager: unhandled known PubSub avatar IQ id=\(elementId)")
        }
        return true
    }
}
