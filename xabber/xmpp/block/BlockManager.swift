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

class BlockManager: AbstractXMPPManager {
    
    class QueueItem: Hashable {
        static func == (lhs: BlockManager.QueueItem, rhs: BlockManager.QueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        var elementId: String
        var callback: (() -> Void)?
        
        init(_ elementId: String, callback: @escaping (() -> Void)) {
            self.elementId = elementId
            self.callback = callback
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    internal var queueItems: SynchronizedArray<QueueItem> = SynchronizedArray<QueueItem>()
    
    open var lastUpdate: Date? = nil
    private var isBlockListRequested: Bool = false
    
    override func namespaces() -> [String] {
        return ["urn:xmpp:blocking"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    func blockContact(_ xmppStream: XMPPStream, jid: String) {
        let elementId = xmppStream.generateUUID
        let block = DDXMLElement(name: "block", xmlns: getPrimaryNamespace())
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        block.addChild(item)
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: block))
        self.queryIds.insert(elementId)
        do {
            let realm = try  WRealm.safe()
            let item = BlockStorageItem()
            item.set(jid: jid, owner: owner)
            try realm.write {
                realm.add(item, update: .modified)
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func unblockContact(_ xmppStream: XMPPStream, jid: String) {
        let elementId = xmppStream.generateUUID
        let block = DDXMLElement(name: "unblock", xmlns: getPrimaryNamespace())
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        block.addChild(item)
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: block))
        self.queryIds.insert(elementId)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: BlockStorageItem.self,
                                           forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    if instance.isInvalidated { return }
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func requestBlockListAck(_ xmppStream: XMPPStream, callback: @escaping (() -> Void)) {
        if isBlockListRequested {
            lastUpdate = Date()
            callback()
            return
        }
        isBlockListRequested = true
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: nil,
                               elementID: elementId,
                               child: DDXMLElement(name: "blocklist",
                                                   xmlns: getPrimaryNamespace())))
        self.queryIds.insert(elementId)
        self.queueItems.insert(QueueItem(elementId, callback: callback))
    }
    
    func requestBlocklist(_ xmppStream: XMPPStream) {
        if isBlockListRequested {
            return
        }
        isBlockListRequested = true
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: nil,
                               elementID: elementId,
                               child: DDXMLElement(name: "blocklist",
                                                   xmlns: getPrimaryNamespace())))
        self.queryIds.insert(elementId)
    }
    
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID else { return false }
        var result: Bool = false
        if didReceiveBlocklist(with: iq) {
            result = true
        } else if didReceiveBlockPush(with: iq) {
            result = true
        } else if didReceiveUblockPush(with: iq) {
            result = true
        }
        if result { syncRosterItems() }
        if self.queryIds.contains(elementId) {
            self.queryIds.remove(elementId)
            result = true
        }
        return result
    }
    
    private func didReceiveBlocklist(with iq: XMPPIQ) -> Bool {
        guard let blocklist = iq.element(forName: "blocklist"),
            let elementId = iq.elementID else {
                return false
        }
        
        let items = blocklist.elements(forName: "item")
        if items.isEmpty {
            clearBlockList()
        } else {
            var result: [BlockStorageItem] = []
            items.forEach { element in
                if let jid = element.attributeStringValue(forName: "jid") {
                    let item = getOrCreate(for: jid)
                    if item.jid.isEmpty {
                        item.set(jid: jid, owner: self.owner)
                        result.append(item)
                    }
                }
            }
            saveItems(result)
        }
//        return false
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?()
            queueItems.remove(item)
        }
        lastUpdate = Date()
        return true
    }
    
    private func didReceiveBlockPush(with iq: XMPPIQ) -> Bool {
        guard let block = iq.element(forName: "block") else { return false }
        let items = block.elements(forName: "item")
        var result: [BlockStorageItem] = []
        items.forEach { element in
            if let jid = element.attributeStringValue(forName: "jid") {
                let item = getOrCreate(for: jid)
                if item.jid.isEmpty {
                    item.set(jid: jid, owner: self.owner)
                    result.append(item)
                }
            }
        }
        saveItems(result)
        lastUpdate = Date()
        AccountManager.shared.find(for: owner)?.groupchats.updateInvitesState()
        return true
    }
    
    private func didReceiveUblockPush(with iq: XMPPIQ) -> Bool {
        guard let unblock = iq.element(forName: "unblock") else { return false }
        let items = unblock.elements(forName: "item")
        if items.isEmpty {
            clearBlockList()
        }
        items.forEach { element in
            if let jid = element.attributeStringValue(forName: "jid") {
                clearBlockList(for: jid)
            }
        }
        lastUpdate = Date()
        return true
    }
    
    private func clearBlockList(for jid: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: BlockStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(instance)
                    }
                }
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func clearBlockList() {
        do {
            let realm = try  WRealm.safe()
            let collection = realm.objects(BlockStorageItem.self).filter("owner == %@", self.owner)
            if !realm.isInWriteTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func getOrCreate(for jid: String) -> BlockStorageItem {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: BlockStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                return instance
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
        return BlockStorageItem()
    }
    
    private func saveItems(_ collection: [BlockStorageItem]) {
        do {
            let realm = try  WRealm.safe()
            if collection.isNotEmpty {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(collection, update: .all)
                    }
                }
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func syncRosterItems() {
        do {
            let realm = try  WRealm.safe()
            let blocklist = realm.objects(BlockStorageItem.self).filter("owner == %@", self.owner)
            let lastChats = realm.objects(LastChatsStorageItem.self).filter("owner == %@", self.owner)
            if !realm.isInWriteTransaction {
                try realm.write {
                    lastChats.forEach { item in
                        item.isBlocked = blocklist.contains(where: {$0.jid == item.jid})
                    }
                }
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func clearSession() {
        super.clearSession()
        lastUpdate = nil
        self.isBlockListRequested = false
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            if commitTransaction {
                try realm.write {
                    realm.delete(realm.objects(BlockStorageItem.self).filter("owner == %@", owner))
                }
            } else {
                realm.delete(realm.objects(BlockStorageItem.self).filter("owner == %@", owner))
            }
        } catch {
            DDLogDebug("BlockManager: \(#function). \(error.localizedDescription)")
        }
    }
}
