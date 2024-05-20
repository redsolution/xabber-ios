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
import SignalProtocolObjC
import RxSwift
import CryptoSwift
import CryptoKit
import SwiftKeychainWrapper

open class OmemoManager: AbstractXMPPManager {
    override func namespaces() -> [String] {
        return [
            OmemoManager.xmlns,
            [NodeType.device.rawValue, "notify"].joined(separator: "+"),
            [NodeType.bundle.rawValue, "notify"].joined(separator: "+"),
//            [NodeType.update.rawValue, "notify"].joined(separator: "+")
        ]
    }

    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    static let xmlns: String = "urn:xmpp:omemo:2"
    static let signalPreKeysMaxVal: UInt32 = 16777215
    static let signedPreKeyRotationPeriod: TimeInterval = 604800
    
//    public var deviceId: UInt32!
    
    internal var shouldPublicate: Bool = false
    
    internal var deviceName: String = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
    
    internal var isOmemoPrepared: Bool
    
    internal var localStore: XabberAxolotlStorage
    internal var signalStorage: SignalStorage
    internal var signalContext: SignalContext
    
    internal var myDeviceRequestElementId: String? = nil
    var isRefreshRequest: Bool = false
    
//    internal var preKeys: [PreKeyStoreItem] = []
    
    static func generatePreKeys() throws -> [SignalPreKey] {
        return (0...100).compactMap {
            _ -> SignalPreKey in
            return SignalPreKey()
        }
    }
    
    override init(withOwner owner: String) {
        guard CredentialsManager.shared.getDeviceId(for: owner) != nil else {
            self.isOmemoPrepared = false
            self.localStore = XabberAxolotlStorage(withOwner: owner)
            self.signalStorage = SignalStorage(signalStore: self.localStore)
            self.signalContext = SignalContext(storage: self.signalStorage)!
            
            super.init(withOwner: owner)
            return
        }
        
        self.localStore = XabberAxolotlStorage(withOwner: owner)
        self.signalStorage = SignalStorage(signalStore: self.localStore)
        self.signalContext = SignalContext(storage: self.signalStorage)!
        self.isOmemoPrepared = true
        super.init(withOwner: owner)
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        if stream.isDisconnected {
            return
        }
        let deviceId = CredentialsManager.shared.getDeviceId(for: self.owner) ?? Int(arc4random() % 16380)
        self.configureLocal(stream, for: deviceId)
    }
    
    public final func configureLocal(_ stream: XMPPStream, for deviceId: Int) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(SignalDeviceStorageItem.self)
            try realm.write {
                collection.forEach {
                    $0.freshlyUpdated = false
                }
            }
            try self.localStore.create(for: deviceId, context: self.signalContext)
            
            if (realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId))?.isPublicated ?? false) {
                return
            }
            self.updateMyDevice(stream)
            AccountManager.shared.find(for: self.owner)?.trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(deviceId))
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func checkInfo() {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactBundle(stream, jid: self.owner, deviceId: self.localStore.localDeviceId())
        })
    }
 
    public final func prepareSecretChat(wit jid: String, success: (() -> Void)?, fail: (() -> Void)?) {
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
            self.getContactDevices(stream, jid: jid, force: true)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.omemo.getContactDevices(stream, jid: jid, force: true)
            })
        }
    }
    
    public final func initChat(jid: String) {
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo)) == nil {
                let initialMessageInstance = MessageStorageItem()

                initialMessageInstance.configureInitialMessage(
                    owner,
                    opponent: jid,
                    conversationType: .omemo,
                    text: "Encrypted chat created".localizeString(id: "encrypted_chat_created", arguments: []),
                    date: Date(),
                    isRead: true
                )

                initialMessageInstance.isDeleted = false
                let instance = LastChatsStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.conversationType = .omemo
                instance.messageDate = Date()
                instance.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo)
                instance.isFreshNotEmptyEncryptedChat = true
                instance.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner))
                
                try realm.write {
                    realm.add(instance, update: .modified)
                    if let messageInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessageInstance.primary) {
                        instance.lastMessage = messageInstance
                    } else {
                        instance.lastMessage = initialMessageInstance
                    }
                }
            }
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
                AccountManager.shared.find(for: self.owner)?.omemo.getContactDevices(stream, jid: jid)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.omemo.getContactDevices(stream, jid: jid)
                })
            }

        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case onContactDeviceListErrorReceive(iq): return true
        case onContactDeviceListReceive(iq): return true
        case onContactBundleErrorReceive(iq): return true
        case onContactBundleReceive(iq): return true
        default: return false
        }
    }
    
    public final func prepareStanzaContent(message: String, date: Date, jid: String, additionalContent: [DDXMLElement], ignoreTimeSignature: Bool) -> String? {
        
        let envelope = DDXMLElement(name: "envelope", xmlns: "urn:xmpp:sce:1")
        let content = DDXMLElement(name: "content")
        let body = DDXMLElement(name: "body", xmlns: "jabber:client")
        body.stringValue = message
        envelope.addChild(content)
        additionalContent.forEach { content.addChild($0) }
        if !ignoreTimeSignature {
            if let signature = SignatureManager.shared.signatureElement {
                content.addChild(signature)
            }
        }
        content.addChild(body)
        let from = DDXMLElement(name: "from")
        from.addAttribute(withName: "jid", stringValue: self.owner)
        let to = DDXMLElement(name: "to")
        to.addAttribute(withName: "jid", stringValue: jid)
        let time = DDXMLElement(name: "time")
        time.addAttribute(withName: "stamp", stringValue: date.XMPPFormattedDate)
        envelope.addChild(from)
        envelope.addChild(to)
        envelope.addChild(time)
        let randomString = String.randomLenString(max: 200, includeNumber: true)
        let rpad = DDXMLElement(name: "rpad", stringValue: randomString)
        envelope.addChild(rpad)
        
        return envelope.compactXMLString
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let identitys = realm.objects(SignalIdentityStorageItem.self).filter("owner == %@", owner)
            let devices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@", owner)
            let preKeys = realm.objects(SignalPreKeysStorageItem.self).filter("owner == %@", owner)
            let sessions = realm.objects(SessionRecordStorageItem.self).filter("owner == %@", owner)
            let trustedIdentity = realm.objects(SignalTrustedIdentityStoreageItem.self).filter("owner == %@", owner)
            let senderKeys = realm.objects(SignalSenderKeyStoreageItem.self).filter("owner == %@", owner)
            CredentialsManager.shared.removeIdentityKey(for: owner)
            CredentialsManager.shared.removeDeviceId(for: owner)
            preKeys.forEach {
                CredentialsManager.shared.removePreKey(for: owner, id: $0.pkId)
            }
            CredentialsManager.shared.removeSignedPreKey(for: owner, id: 1)
            if commitTransaction {
                try realm.write {
                    identitys.forEach { realm.delete($0) }
                    devices.forEach { realm.delete($0) }
                    preKeys.forEach { realm.delete($0) }
                    sessions.forEach { realm.delete($0) }
                    trustedIdentity.forEach { realm.delete($0) }
                    senderKeys.forEach { realm.delete($0) }
                }
            } else {
                identitys.forEach { realm.delete($0) }
                devices.forEach { realm.delete($0) }
                preKeys.forEach { realm.delete($0) }
                sessions.forEach { realm.delete($0) }
                trustedIdentity.forEach { realm.delete($0) }
                senderKeys.forEach { realm.delete($0) }
            }
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
}

extension OmemoManager {
    
    public enum NodeType: String {
        case device = "urn:xmpp:omemo:2:devices"
        case bundle = "urn:xmpp:omemo:2:bundles"
        case update = "urn:xmpp:omemo:2:bundles:update"
        case trustList = "urn:xmpp:trustsharing:0:items"
    }
    
    public final func subscribeNode(_ xmppStream: XMPPStream, jid: String, node: NodeType) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let subscribe = DDXMLElement(name: "subscribe", xmlns: "http://jabber.org/protocol/pubsub")
        subscribe.addAttribute(withName: "node", stringValue: node.rawValue)
        subscribe.addAttribute(withName: "jid", stringValue: self.owner)
        pubsub.addChild(subscribe)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        self.queryIds.append(elementId)
    }
    
    public final func unsubscribeNode(_ xmppStream: XMPPStream, jid: String, node: NodeType) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let subscribe = DDXMLElement(name: "unsubscribe", xmlns: "http://jabber.org/protocol/pubsub")
        subscribe.addAttribute(withName: "node", stringValue: node.rawValue)
        subscribe.addAttribute(withName: "jid", stringValue: self.owner)
        pubsub.addChild(subscribe)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
    }
     
    public final func getAllContactsBundle(_ xmppStream: XMPPStream, jid: String) {
        do {
            let realm = try WRealm.safe()
            realm
                .objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@", self.owner, jid)
                .compactMap { return $0.deviceId }
                .forEach { self.getContactBundle(xmppStream, jid: jid, deviceId: $0, force: true) }
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func getContactDevices(_ xmppStream: XMPPStream, jid: String, force: Bool = false) {
        if !force {
            do {
                let realm = try WRealm.safe()
                if jid == owner {
                    if (realm.object(ofType: AccountStorageItem.self,
                                     forPrimaryKey: jid)?
                        .isOmemoDevicesListReceived ?? false) {
                        return
                    }
                } else {
                    if (realm.object(ofType: RosterStorageItem.self,
                                     forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?
                        .isOmemoDevicesListReceived ?? false) {
                        return
                    }
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: NodeType.device.rawValue)
        pubsub.addChild(items)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .get, to: jid == owner ? nil : XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        self.queryIds.append(elementId)
    }
    
    public func getContactBundle(_ xmppStream: XMPPStream, jid: String, deviceId: Int, force: Bool = false) {
        let elementId = xmppStream.generateUUID
        if self.localStore.localDeviceId() == deviceId {
            self.myDeviceRequestElementId = elementId
        }
        if !force {
            do {
                let realm = try WRealm.safe()
                if realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: Int(deviceId) )) != nil{
                    return
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: NodeType.bundle.rawValue)
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", integerValue: deviceId)
        items.addChild(item)
        pubsub.addChild(items)
        let iq = XMPPIQ(iqType: .get, to: jid == owner ? nil : XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        print(iq.prettyXMLString!)
        self.queryIds.append(elementId)
    }
    
    private func onContactDeviceListErrorReceive(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error,
              let jid = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == NodeType.device.rawValue,
              let error = iq.element(forName: "error") else {
                  return false
              }
        if error.attributeStringValue(forName: "code") == "404" {
            do {
                let realm = try WRealm.safe()
                print("devices omemom 2", realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", owner, owner).toArray())
                if jid == owner {
                    XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
    //                    self.configureNode(stream, node: .device)
    //                    self.configureNode(stream, node: .bundle)
                        try? self.publicateOwnDevice(stream, createNode: true)
                    } fail: {
                        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
    //                        user.omemo.configureNode(stream, node: .device)
    //                        user.omemo.configureNode(stream, node: .bundle)
                            try? user.omemo.publicateOwnDevice(stream, createNode: true)
                        })
                    }
                    if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                        try realm.write {
                            instance.isOmemoDevicesListReceived = true
                        }
                    }
                } else {
                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                        try realm.write {
                            instance.isSupportOmemo = false
                            instance.isOmemoDevicesListReceived = true
                        }
                    }
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        
        
        return true
    }
    
    private final func onContactDeviceListReceive(_ iq: XMPPIQ) -> Bool {
        guard let jid = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == NodeType.device.rawValue else {
                  return false
              }
        guard let item = items.element(forName: "item") else {
            if jid == self.owner && self.shouldPublicate {
                
                do {
                    let realm = try WRealm.safe()
                    try realm.write {
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?
                            .isOmemoDevicesListReceived = true
                    }
                } catch {
                    DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                }
            }
            return true
        }
        return onContactDeviceListReceiveItem(item, jid: jid)
    }
    
    /*<message xmlns="jabber:client" to="andrew@clandestino.chat/clandestino-ios-3F02F22F" from="andrew@clandestino.chat" type="headline">
     <event xmlns="http://jabber.org/protocol/pubsub#event">
       <items node="urn:xmpp:omemo:2:devices">*/
    public final func onContactDeviceListReceiveHeadline(_ message: XMPPMessage) -> Bool {
        guard let jid = message.from?.bare,
              let event = message.element(forName: "event", xmlns: "http://jabber.org/protocol/pubsub#event"),
              let items = event.element(forName: "items"),
              items.attributeStringValue(forName: "node") == NodeType.device.rawValue else {
            return false
        }
        
        guard let item = items.element(forName: "item") else {
            if jid == self.owner && self.shouldPublicate {
//                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
//                    self.configureNode(stream, node: .device)
//                    self.configureNode(stream, node: .bundle)
//                    try? self.publicateOwnDevice(stream, createNode: false)
//                } fail: {
//                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
//                        user.omemo.configureNode(stream, node: .device)
//                        user.omemo.configureNode(stream, node: .bundle)
//                        try? user.omemo.publicateOwnDevice(stream, createNode: false)
//                    })
//                }
                
                do {
                    let realm = try WRealm.safe()
                    try realm.write {
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?
                            .isOmemoDevicesListReceived = true
                    }
                } catch {
                    DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                }
            }
            return true
        }
        return onContactDeviceListReceiveItem(item, jid: jid, fromMessage: true)
    }
    
    public final func onEncryptionUpdateReceiveHeadline(_ message: XMPPMessage) -> Bool {
        guard let jid = message.from?.bare,
              let event = message.element(forName: "event", xmlns: "http://jabber.org/protocol/pubsub#event"),
              let items = event.element(forName: "items"),
              items.attributeStringValue(forName: "node") == NodeType.update.rawValue else {
            return false
        }
        
        guard let item = items.element(forName: "item") else {
            return true
        }
        
        let itemId = item.attributeDoubleValue(forName: "id")
        if itemId > 0 {
            do {
                let realm = try WRealm.safe()
                
                if jid == self.owner {
                    let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)
                    if (instance?.encryptionUpdatedTS ?? 0) <= 1 { return true }
                    if (instance?.encryptionUpdatedTS ?? 0) < itemId {
                        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
                            self.getAllContactsBundle(stream, jid: jid)
                        } fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                                user.omemo.getAllContactsBundle(stream, jid: jid)
                            })
                        }
                    }
                } else {
                    let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner))
                    if (instance?.encryptionUpdatedTS ?? 0) <= 1 { return true }
                    if (instance?.encryptionUpdatedTS ?? 0) < itemId {
                        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
                            self.getAllContactsBundle(stream, jid: jid)
                        } fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                                user.omemo.getAllContactsBundle(stream, jid: jid)
                            })
                        }
                    }
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
            
        }
        
        return true
    }
    
    private func onContactDeviceListReceiveItem(_ item: DDXMLElement, jid: String, fromMessage: Bool = false) -> Bool {
        guard let devices = item.element(forName: "devices", xmlns: getPrimaryNamespace())?.elements(forName: "device") else {
                  return false
              }
        
        do {
            let realm = try WRealm.safe()
            let devicesList = devices.compactMap { return  $0.attributeIntegerValue(forName: "id") }
            
            let deviceCollection = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid).toArray()
            let toDeleteItems: [String] = deviceCollection.compactMap {
                device in
                if device.deviceId == self.localStore.localDeviceId() { return nil }
                if !devicesList.contains(device.deviceId) {
                    return device.primary
                }
                return nil
            }
            let xabberDeviceCollection = realm.objects(DeviceStorageItem.self).filter("owner == %@", self.owner)
            try realm.write {
                toDeleteItems.forEach {
                    if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: $0) {
                        if let deviceInstance = xabberDeviceCollection.first(where: { $0.uid.contains("\(instance.deviceId)") }) {
                            deviceInstance.isEncryptionEnabled = false
                        }
                        realm.delete(instance)
                    }
                    if let instance = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: $0) {
                        realm.delete(instance)
                    }
                }
                devices.forEach {
                    device in
                    let id = device.attributeIntegerValue(forName: "id")
                    if id == self.localStore.localDeviceId() { return }
                    let label = device.attributeStringValue(forName: "label")
                    let primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: id)
                    if let instance = xabberDeviceCollection.first(where: { $0.uid.contains("\(id)") }) {
                        instance.isEncryptionEnabled = true
                    }
                    if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) {
                        if instance.isInvalidated { return }
                        instance.name = label
                        instance.freshlyUpdated = true
                    } else {
                        let instance = SignalDeviceStorageItem()
                        instance.owner = self.owner
                        instance.jid = jid
                        instance.primary = primary
                        instance.deviceId = Int(id)
                        instance.name = label
                        instance.state = .unknown
                        instance.freshlyUpdated = true
                         
                        realm.add(instance, update: .error)
                    }
                }
            }
            
            devices.forEach {
                device in
                let id = device.attributeIntegerValue(forName: "id")
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.omemo.getContactBundle(stream, jid: jid, deviceId: id, force: self.isRefreshRequest)
                })
            }
            
            self.isRefreshRequest = false
            
            if jid == self.owner {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.devices.requestList(stream)
                })
            }
            
            if jid == self.owner && self.shouldPublicate && !fromMessage {
//                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, _ in
//                    try? self.publicateOwnDevice(stream, createNode: false)
//                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        try? user.omemo.publicateOwnDevice(stream, createNode: false)
                    })
//                }
                let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)
                try realm.write {
                    account?.isOmemoDevicesListReceived = true
                    account?.encryptionUpdatedTS = Date().timeIntervalSince1970
                }
            } else {
                let contact = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner))
                try realm.write {
                    contact?.isOmemoDevicesListReceived = true
                    contact?.encryptionUpdatedTS = Date().timeIntervalSince1970
                }
            }
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private final func onContactBundleErrorReceive(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error,
              let from = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == NodeType.bundle.rawValue,
              let error = iq.element(forName: "error"),
              error.attributeStringValue(forName: "code") == "404" else {
                  return false
              }

        return true
    }
    
    public final func deleteDevice(deviceId: Int) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
            
            if let instance = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.owner, deviceId: deviceId)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                try? user.omemo.sendOwnDevice(stream, createNode: false)
                user.omemo.deleteDeviceOrBundle(stream, jid: nil, itemId: deviceId, node: .bundle)
            })
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func deleteDeviceOrBundle(_ xmppStream: XMPPStream, jid: XMPPJID?, itemId: Int, node: NodeType) {
        if node == .device {
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    realm.delete(
                        realm
                            .objects(SignalDeviceStorageItem.self)
                            .filter("owner == %@ AND deviceId == %@", self.owner, itemId)
                    )
                }
                try self.sendOwnDevice(xmppStream, createNode: false)
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
            return
        } else {
            let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
            let retract = DDXMLElement(name: "retract")
            retract.addAttribute(withName: "node", stringValue: node.rawValue)
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "id", integerValue: itemId)
            retract.addChild(item)
            pubsub.addChild(retract)
            let elementId = xmppStream.generateUUID
            xmppStream.send(XMPPIQ(iqType: .set, to: jid?.bareJID, elementID: elementId, child: pubsub))
            self.queryIds.insert(elementId)
        }
    }
    
    public final func onContactBundleReceive(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              let from = iq.from?.bare,
              iq.from?.user != nil,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):bundles" else {
                  return false
              }
        
        guard let item = items.element(forName: "item") else {
            if elementId == myDeviceRequestElementId {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.omemo.updateMyDevice(stream)
                })
            }
            return true
        }

        RunLoop.main.perform {
            let itemId = item.attributeIntegerValue(forName: "id")
            do {
                try _ = self.onContactBundleReceive(items: items, jid: from)
            } catch {
                if from == self.owner {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                        user.omemo.deleteDeviceOrBundle(stream, jid: iq.from, itemId: itemId, node: .bundle)
                    })
                }
            }
        }
        
        return true
    }
    
    public final func onContactDeviceReceiveHeadline(_ message: XMPPMessage) -> Bool {
        guard let from = message.from?.bare,
              let event = message.element(forName: "event", xmlns: "http://jabber.org/protocol/pubsub#event"),
              let items = event.element(forName: "items"),
              items.attributeStringValue(forName: "node") == NodeType.bundle.rawValue else {
                  return false
              }
        guard let item  = items.element(forName: "item") else {
            return false
        }
        RunLoop.main.perform {
            let itemId = item.attributeIntegerValue(forName: "id")
            do {
                try _ = self.onContactBundleReceive(items: items, jid: from)
            } catch {
                if from != self.owner { return }
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                    user.omemo.deleteDeviceOrBundle(stream, jid: message.from, itemId: itemId, node: .bundle)
                })
            }
        }
        
        return true
    }
    
    private final func onContactBundleReceive(items: DDXMLElement, jid: String) throws -> Bool {
        func clearDevice(deviceId: Int) {
            do {
                let realm = try Realm()
                if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: deviceId)) {
                    realm.writeAsync {
                        realm.delete(instance)
                    }
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        guard items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):bundles",
              let item = items.element(forName: "item"),
              let bundle = item.element(forName: "bundle", xmlns: getPrimaryNamespace()) else {
                throw OmemoManagerError.bundleNotFound
              }
        let cDeviceId = item.attributeIntegerValue(forName: "id")
        guard let spkId = bundle.element(forName: "spk")?.attributeIntValue(forName: "id"),
              let spk_b64 = bundle.element(forName: "spk")?.stringValue,
              spk_b64.isNotEmpty,
              let spks_b64 = bundle.element(forName: "spks")?.stringValue,
              spks_b64.isNotEmpty,
              let ik_b64 = bundle.element(forName: "ik")?.stringValue,
              ik_b64.isNotEmpty,
              let preKeys = bundle.element(forName: "prekeys")?.elements(forName: "pk") else {
            clearDevice(deviceId: cDeviceId)
            throw OmemoManagerError.bundleNotFound
          }
                
//        let signed: Bool = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns) != nil
        var signedInfo: SignatureManager.BundleSignedInfo? = nil
        if let signature = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns) {
            signedInfo = try SignatureManager.shared.checkBundleSignature(
                owner: self.owner,
                for: jid,
                signature: signature
            )
        }
        
        let realm = try WRealm.safe()
        
        let pkcollection = preKeys.compactMap {
            (pkElement) -> SignalPreKeysStorageItem? in
            
            let pk_id = pkElement.attributeIntegerValue(forName: "id")
            
            guard let pk = pkElement.stringValue,
                  pk.isNotEmpty else {
                return nil
            }
            
            let instance = SignalPreKeysStorageItem()
            instance.owner = self.owner
            instance.jid = jid
            instance.pkId = pk_id
            instance.preKey = pk
            instance.deviceId = cDeviceId
            instance.primary = SignalPreKeysStorageItem.genPrimary(keyUUID: UUID().uuidString)
            
            return instance
        }
        
        if realm.object(
            ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: jid,
                deviceId: cDeviceId
            )) != nil {
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self,
                                           forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)) {
                let ik_data = Data(base64Encoded: ik_b64, options: .ignoreUnknownCharacters)
                realm.writeAsync {
                    if instance.isInvalidated { return }
                    instance.fingerprint = ik_data?.formattedFingerprint() ?? ""
                    instance.signature = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns)?.xmlString
                    if let signedInfo = signedInfo,
                       signedInfo.signedBy == jid {
                        instance.state = .trusted
                        instance.isTrustedByCertificate = true
                        instance.signedAt = signedInfo.signedAt
                        instance.signedBy = signedInfo.signedBy
                    } else {
                        instance.isTrustedByCertificate = false
                        instance.signedAt = -1
                        instance.signedBy = nil
                    }
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo))?.updateTS = Date().timeIntervalSince1970
                }
            } else {
                let ik_data = Data(base64Encoded: ik_b64, options: .ignoreUnknownCharacters)
                let instance = SignalDeviceStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
                instance.deviceId = Int(cDeviceId)
                instance.state = .unknown
                instance.freshlyUpdated = true
                instance.fingerprint = ik_data?.formattedFingerprint() ?? ""
                instance.signature = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns)?.xmlString
                if let signedInfo = signedInfo,
                   signedInfo.signedBy == jid {
                    instance.state = .trusted
                    instance.isTrustedByCertificate = true
                    instance.signedAt = signedInfo.signedAt
                    instance.signedBy = signedInfo.signedBy
                } else {
                    instance.isTrustedByCertificate = false
                    instance.signedAt = -1
                    instance.signedBy = nil
                }
                try realm.write {
                    realm.add(instance)
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo))?.updateTS = Date().timeIntervalSince1970
                }
            }
        } else {
            let instance = SignalIdentityStorageItem()
            instance.primary = SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
            instance.signedPreKey = spk_b64
            instance.signedPreKeySignature = spks_b64
            instance.identityKey = ik_b64
            instance.signedPreKeyId = Int(spkId)
            instance.owner = self.owner
            instance.jid = jid
            instance.deviceId = cDeviceId
            
            realm.writeAsync {
                realm.add(instance, update: .modified)
                realm.add(pkcollection)
                if let instance = realm.object(ofType: SignalDeviceStorageItem.self,
                                               forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)) {
                    let ik_data = Data(base64Encoded: ik_b64, options: .ignoreUnknownCharacters)
                    instance.fingerprint = ik_data?.formattedFingerprint() ?? ""
                    instance.signature = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns)?.xmlString
                    if let signedInfo = signedInfo,
                       signedInfo.signedBy == jid {
                        instance.state = .trusted
                        instance.isTrustedByCertificate = true
                        instance.signedAt = signedInfo.signedAt
                        instance.signedBy = signedInfo.signedBy
                    } else {
                        instance.isTrustedByCertificate = false
                        instance.signedAt = -1
                        instance.signedBy = nil
                    }
                } else {
                    let ik_data = Data(base64Encoded: ik_b64, options: .ignoreUnknownCharacters)
                    let instance = SignalDeviceStorageItem()
                    instance.owner = self.owner
                    instance.jid = jid
                    instance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
                    instance.deviceId = Int(cDeviceId)
                    instance.state = .unknown
                    instance.freshlyUpdated = true
                    instance.fingerprint = ik_data?.formattedFingerprint() ?? ""
                    instance.signature = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns)?.xmlString
                    if let signedInfo = signedInfo,
                       signedInfo.signedBy == jid {
                        instance.state = .trusted
                        instance.isTrustedByCertificate = true
                        instance.signedAt = signedInfo.signedAt
                        instance.signedBy = signedInfo.signedBy
                    } else {
                        instance.isTrustedByCertificate = false
                        instance.signedAt = -1
                        instance.signedBy = nil
                    }
                    realm.add(instance)
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo))?.updateTS = Date().timeIntervalSince1970
                }
            }
        }
        if jid == self.owner {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.devices.requestList(stream)
            })
        }
        return true
    }
    
    func modifySyncQuery(_ query: DDXMLElement) -> DDXMLElement {
        query.elements(forName: "conversation").forEach {
            item in
            guard (ClientSynchronizationManager.ConversationType(rawValue: item.attributeStringValue(forName: "type") ?? "none") ?? .regular) == .omemo else {
                return
            }
            guard let messageElement = item
                .elements(forName: "metadata")
                .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?
                .element(forName: "last-message")?.element(forName: "message") else {
                return
            }
            
            do {
                let content = try self.decryptMessage(XMPPMessage(from: messageElement))
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
                item
                    .elements(forName: "metadata")
                    .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?
                    .element(forName: "last-message")?
                    .element(forName: "message")?
                    .remove(forName: "body")
                item
                    .elements(forName: "metadata")
                    .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?
                    .element(forName: "last-message")?
                    .element(forName: "message")?
                    .addChild(DDXMLElement(name: "body", stringValue: body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")"))
                
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            item
                                .elements(forName: "metadata")
                                .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?
                                .element(forName: "last-message")?
                                .element(forName: "message")?
                                .addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    item
                        .elements(forName: "metadata")
                        .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?
                        .element(forName: "last-message")?
                        .element(forName: "message")?
                        .addChild(resultElement)
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                return
            }
            
        }
        
        
        return query
    }
    
    func modifyOmemoStanza(message: XMPPMessage) -> XMPPMessage {
        guard message.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
            return message
        }
        do {
            let content = try self.decryptMessage(message)
            let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
            message.remove(forName: "body")
            message.addBody(body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")")
            if let content = content?.element(forName: "content") {
                content.children?.forEach {
                    if $0.name != "body" {
                        message.addChild($0.copy() as! DDXMLNode)
                    }
                }
                let resultElement = DDXMLElement(name: "omemo-result__system")
                resultElement.addAttribute(withName: "result", boolValue: true)
                message.addChild(resultElement)
            }
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
        return message
    }
    
    func didReceiveOmemoMessageFromPush(_ message: XMPPMessage) -> XMPPMessage? {
        if isArchivedMessage(message) {
            do {
                guard let bareMessage = getArchivedMessageContainer(message),
                      bareMessage.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                          return nil
                      }
                let content = try self.decryptMessage(bareMessage)
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
                
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")"))
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.addChild(resultElement)
                }
                return message
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        } else {
            guard message.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                return nil
            }
            do {
                let content = try self.decryptMessage(message)
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
                message.remove(forName: "body")
                message.addBody(body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")")
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.addChild(resultElement)
                }
                return message
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        return nil
    }
    
    func didReceiveOmemoMessage(_ message: XMPPMessage, fromCCC: Bool = false) -> Bool {
        if isArchivedMessage(message) {
            do {
                guard let bareMessage = getArchivedMessageContainer(message),
                      bareMessage.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                          return false
                      }
                let content = try self.decryptMessage(bareMessage)
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue

                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")"))
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(resultElement)
                }
                AccountManager.shared.find(for: self.owner)?.messages.receiveArchived(message)
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                return false
            }
        } else if isCarbonCopy(message) {
            do {
                guard let bareMessage = getCarbonCopyMessageContainer(message),
                      bareMessage.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                          return false
                      }
                let content = try self.decryptMessage(bareMessage)
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
                if body == nil { return true }
                message.element(forName: "sent")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "sent")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")"))
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.element(forName: "sent")?.element(forName: "forwarded")?.element(forName: "message")?.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.element(forName: "sent")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(resultElement)
                }
                AccountManager.shared.find(for: self.owner)?.messages.receiveCarbon(message)
            } catch {
//                fatalError(error.localizedDescription)
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                return false
            }
        } else if isCarbonForwarded(message) {
            do {
                guard let bareMessage = getCarbonForwardedMessageContainer(message),
                      bareMessage.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                          return false
                      }
                let content = try self.decryptMessage(bareMessage)
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
                
                
                message.element(forName: "received")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "received")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")"))
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.element(forName: "received")?.element(forName: "forwarded")?.element(forName: "message")?.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.element(forName: "received")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(resultElement)
                }
                AccountManager.shared.find(for: self.owner)?.messages.receiveCarbonForwarded(message)
            } catch {
//                fatalError(error.localizedDescription)
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                return false
            }
        } else {
            guard message.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                return false
            }
            do {
                let content = try self.decryptMessage(message)
                let body = content?.element(forName: "content")?.element(forName: "body")?.stringValue
                message.remove(forName: "body")
                message.addBody(body ?? "Failed to decrypt \(content?.prettyXMLString ?? "no content")")
//                if let content = content {
//                    message.addChild(content)
//                }
                if let content = content?.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.addChild(resultElement)
                }
                AccountManager.shared.find(for: self.owner)?.messages.receiveRuntime(message)
            } catch {
//                fatalError(error.localizedDescription)
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
                return false
            }
        }
        
        
        return true
    }
    
    func decryptMessage(_ message: XMPPMessage) throws -> DDXMLElement? {
        guard let from = message.from?.bare,
              let encryptedElement = message.element(forName: "encrypted", xmlns: getPrimaryNamespace()),
              let headerElement = encryptedElement.element(forName: "header") else {
                  return nil
              }
        
        guard let payload = encryptedElement.element(forName: "payload")?.stringValue,
              let payloadData = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            return nil
        }
        
        let senderDeviceId = headerElement.attributeIntegerValue(forName: "sid")
        
        let keyElement = headerElement
            .elements(forName: "keys")
            .first(where: { $0.attributeStringValue(forName: "jid") == self.owner })?
            .elements(forName: "key")
            .first(where: { $0.attributeIntegerValue(forName: "rid") == self.localStore.localDeviceId() })
        
        
        let keyExchange = keyElement?.attributeBoolValue(forName: "kex") ?? false
        guard let ratchetInfo = keyElement?.stringValue else {
            return nil
        }
        
        let unratchedData = try self.doubleUnratched(ratchetInfo, jid: from, deviceId: senderDeviceId, keyExchange: keyExchange)
        
        let key = Data(unratchedData!.prefix(32))
        let hmac = Data(unratchedData!.suffix(16))
        
        let salt = Array<UInt8>(repeating: 0, count: 32)
        
        let hkdf = try HKDF(
            password: key.bytes,
            salt: salt,
            info: Array("OMEMO Payload".data(using: .utf8)!),
            keyLength: 80,
            variant: .sha2(.sha256)
        ).calculate()
        
        
        let encryptionKey: Array<UInt8> = Array(hkdf.prefix(32))
        let authKey: Array<UInt8> = Array(hkdf.suffix(from: 32).prefix(32))
        let iv: Array<UInt8> = Array(hkdf.suffix(16))
        
        let symKey = SymmetricKey(data: Data(authKey))
        let hmacCalculated = CryptoKit.HMAC<SHA256>.authenticationCode(for: Data(payloadData), using: symKey)
        guard Array<UInt8>(hmac) == Array<UInt8>(hmacCalculated.prefix(16)) else {
            return nil
        }
        
        let gcm = CBC(iv: iv)
        let aes = try AES(key: encryptionKey, blockMode: gcm, padding: .pkcs7)
        let decrypted = try aes.decrypt(payloadData.bytes)

        let doceument = try DDXMLDocument(xmlString: String(data: Data(decrypted), encoding: .utf8)!, options: 0)
        let element = doceument.rootElement()
        element?.detach()
        
        return element
    }
    
         
}
