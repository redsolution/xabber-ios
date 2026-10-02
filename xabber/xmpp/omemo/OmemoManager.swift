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
    
    internal var omemo2Storage: XabberOMEMO2Storage?
    internal var omemo2ControlSender: ((XMPPMessage) -> Void)?
    internal var omemo2BundlePublications: [String: Data] = [:]
    internal var omemo2PublicationReconfigured = false
    internal var omemo2BundleConfigurationRequestID: String?

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
        self.omemo2Storage = try? XabberOMEMO2Storage(owner: owner)
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
        do {
            self.configureLocal(stream, for: try self.deviceIDForOMEMO2Preparation())
        } catch {
            self.isOmemoPrepared = false
            DDLogDebug("OMEMO2 state could not be prepared")
        }
    }
    
    public final func configureLocal(_ stream: XMPPStream, for deviceId: Int) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@", self.owner)
            try realm.write {
                collection.forEach {
                    $0.freshlyUpdated = false
                }
            }
            guard let storage = self.omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
            do {
                let bundle = try storage.localBundle()
                guard bundle.deviceID == deviceId else { throw OMEMO2StorageError.invalidDeviceID }
                // Existing aggregate is authoritative even if its Realm public
                // projection has been removed. Do not regenerate legacy keys.
                try self.localStore.bindExistingDevice(deviceID: bundle.deviceID)
                _ = try storage.prepare(deviceID: bundle.deviceID)
            } catch OMEMO2StorageError.stateUnavailable {
                guard realm.objects(SignalIdentityStorageItem.self)
                    .filter("owner == %@ AND jid == %@ AND protocolProfile == %@", self.owner, self.owner, Self.xmlns).isEmpty else {
                    throw OMEMO2StorageError.stateUnavailable
                }
                try self.localStore.create(for: deviceId, context: self.signalContext)
            }
            _ = try self.ensureOMEMO2Prepared()
            self.isOmemoPrepared = true
            self.omemo2PublicationReconfigured = false
            self.omemo2BundlePublications.removeAll()
            self.shouldPublicate = true
            self.updateMyDevice(stream)
            self.flushOMEMO2Controls()
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
        case onOMEMO2PublicationResult(iq): return true
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
            try CredentialsManager.shared.removeOMEMO2State(for: owner)
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
                if let cached = realm.object(ofType: SignalIdentityStorageItem.self,
                                             forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: deviceId)),
                   cached.protocolProfile == OMEMO2BundleCodec.namespace,
                   cached.identityKey.flatMap({ Data(base64Encoded: $0) })?.count == 32 {
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
//        print(iq.prettyXMLString!)
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
//                print("devices omemom 2", realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", owner, owner).toArray())
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
            let devicesList = try devices.map { try OMEMO2BundleCodec.keyID($0.attributeStringValue(forName: "id")) }.map(Int.init)
            guard Set(devicesList).count == devicesList.count else { return true }
            
            let deviceCollection = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid).toArray()
            let toDeleteItems: [String] = deviceCollection.compactMap {
                device in
                if jid == self.owner && device.deviceId == self.localStore.localDeviceId() { return nil }
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
                    if jid == self.owner && id == self.localStore.localDeviceId() { return }
                    // Unsigned peer labels are not authenticated identity metadata.
                    var label: String?
                    if let value = device.attributeStringValue(forName: "label"),
                       let encoded = device.attributeStringValue(forName: "labelsig"),
                       let signature = try? Omemo2PayloadCodec.decodeBase64(encoded),
                       let identity = realm.object(ofType: SignalIdentityStorageItem.self,
                            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: id)),
                       identity.protocolProfile == Self.xmlns,
                       let encodedIdentity = identity.identityKey,
                       let key = try? Omemo2PayloadCodec.decodeBase64(encodedIdentity),
                       Omemo2IdentityRepresentation.verify(signature, data: Data(value.utf8), storedIdentity: key) {
                        label = value
                    }
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
            do {
                try _ = self.onContactBundleReceive(items: items, jid: from)
            } catch {
                DDLogDebug("OmemoManager: rejected OMEMO2 bundle publication")
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
        guard let item = items.element(forName: "item") else {
            return false
        }
        RunLoop.main.perform {
            do {
                try _ = self.onContactBundleReceive(items: items, jid: from)
            } catch {
                DDLogDebug("OmemoManager: rejected OMEMO2 bundle publication")
            }
        }
        
        return true
    }
    
    internal final func onContactBundleReceive(items: DDXMLElement, jid: String) throws -> Bool {
        guard items.attributeStringValue(forName: "node") == OMEMO2BundleCodec.namespace + ":bundles",
              let item = items.element(forName: "item") else { throw OmemoManagerError.bundleNotFound }
        // The codec authenticates the SPK and validates all public fields before
        // a malformed PEP publication is allowed to affect cached keys or trust.
        let published = try OMEMO2BundleCodec.decode(item: item)
        guard let bundle = item.element(forName: "bundle", xmlns: getPrimaryNamespace()) else {
            throw OmemoManagerError.bundleNotFound
        }
        let cDeviceId = published.deviceID
        var signedInfo: SignatureManager.BundleSignedInfo?
        if let signature = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns) {
            signedInfo = try SignatureManager.shared.checkBundleSignature(owner: self.owner, for: jid, signature: signature)
        }
        let realm = try WRealm.safe()
        let identityPrimary = SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
        let devicePrimary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
        let sessionPrimary = SessionRecordStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
        let trustedIdentityPrimary = SignalTrustedIdentityStoreageItem.genPrimary(owner: self.owner, jid: jid, deviceId: cDeviceId)
        let previousIdentity = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: identityPrimary)
        let oldIdentityData = previousIdentity?.identityKey.flatMap { Data(base64Encoded: $0) }
        let oldCurveKey = oldIdentityData.flatMap { try? OMEMO2BundleCodec.fingerprintPublicKey(storedIdentityKey: $0) }
        let trustedIdentity = realm.object(ofType: SignalTrustedIdentityStoreageItem.self, forPrimaryKey: trustedIdentityPrimary)
        let trustedCurveKey = trustedIdentity?.identity.flatMap { try? OMEMO2BundleCodec.fingerprintPublicKey(storedIdentityKey: $0) }
        let identityChanged = (oldIdentityData != nil && oldCurveKey != published.fingerprintPublicKey)
            || (trustedIdentity?.identity != nil && trustedCurveKey != published.fingerprintPublicKey)
        if identityChanged, let storage = self.omemo2Storage {
            do {
                _ = try storage.localBundle()
                // Invalidate the affected OMEMO2 peer before changing the
                // public identity/trust cache. Storage failures cannot leave a
                // trusted replacement pointing at an old outgoing session.
                try storage.deleteSessions(jid: jid, deviceID: cDeviceId)
            } catch OMEMO2StorageError.stateUnavailable {
                // An account whose OMEMO2 migration has not prepared local
                // state has no new-profile session to invalidate.
            }
        }
        let signatureXML = bundle.element(forName: "time-signature", xmlns: SignatureManager.xmlns)?.xmlString
        let pkcollection = published.preKeys.map { preKey -> SignalPreKeysStorageItem in
            let instance = SignalPreKeysStorageItem()
            instance.owner = self.owner
            instance.jid = jid
            instance.pkId = Int(preKey.id)
            instance.preKey = preKey.publicKey.base64EncodedString()
            instance.deviceId = cDeviceId
            instance.keyUUID = UUID().uuidString
            instance.primary = SignalPreKeysStorageItem.genPrimary(keyUUID: instance.keyUUID)
            return instance
        }
        try realm.write {
            let identity = previousIdentity ?? SignalIdentityStorageItem()
            if identity.primary.isEmpty {
                identity.primary = identityPrimary
                identity.owner = self.owner
                identity.jid = jid
                identity.deviceId = cDeviceId
            }
            identity.protocolProfile = OMEMO2BundleCodec.namespace
            identity.signedPreKey = published.signedPreKey.base64EncodedString()
            identity.signedPreKeySignature = published.signature.base64EncodedString()
            identity.identityKey = published.identityKey.base64EncodedString()
            identity.signedPreKeyId = Int(published.signedPreKeyID)
            identity.signedPreKeyTimestamp = Date().timeIntervalSince1970
            realm.add(identity, update: .modified)
            realm.delete(realm.objects(SignalPreKeysStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, jid, cDeviceId))
            realm.add(pkcollection, update: .modified)
            let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: devicePrimary) ?? SignalDeviceStorageItem()
            if device.primary.isEmpty {
                device.owner = self.owner
                device.jid = jid
                device.primary = devicePrimary
                device.deviceId = cDeviceId
                device.state = .unknown
            }
            device.freshlyUpdated = true
            device.updateDate = Date()
            device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: published.identityKey)
            device.signature = signatureXML
            if identityChanged {
                device.state = .fingerprintChanged
                device.isTrustedByCertificate = false
                device.signedAt = -1
                device.signedBy = nil
                device.trustedByDeviceId = nil
                device.trustDate = Date(timeIntervalSince1970: -1)
                if let trustedIdentity = trustedIdentity, !trustedIdentity.isInvalidated { realm.delete(trustedIdentity) }
            } else {
                // Equivalent Curve25519 identity keeps the user's trust while
                // moving from a prefixed legacy key to raw Ed25519 wire data.
                if device.state == .trusted, device.isTrustedByCertificate,
                   device.trustedByDeviceId == nil {
                    // Cached timestamp-only certificate trust is not a manual
                    // identity decision and cannot survive the profile change.
                    device.state = .unknown
                    device.trustDate = Date(timeIntervalSince1970: -1)
                }
                if let trustedIdentity = trustedIdentity { trustedIdentity.identity = published.identityKey }
                if let signedInfo = signedInfo, signedInfo.signedBy == jid {
                    // The legacy certificate signature authenticates a timestamp,
                    // not this identity key. It is metadata, never a trust proof.
                    device.isTrustedByCertificate = false
                    device.signedAt = signedInfo.signedAt
                    device.signedBy = signedInfo.signedBy
                } else {
                    device.isTrustedByCertificate = false
                    device.signedAt = -1
                    device.signedBy = nil
                }
            }
            if identityChanged,
               let legacySession = realm.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: sessionPrimary),
               !legacySession.isInvalidated { realm.delete(legacySession) }
            realm.add(device, update: .modified)
            realm.object(ofType: LastChatsStorageItem.self,
                         forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo))?.updateTS = Date().timeIntervalSince1970
        }
        if jid == self.owner {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in user.devices.requestList(stream) }
        }
        return true
    }

    func modifySyncQuery(_ query: DDXMLElement) -> DDXMLElement {
        modifySyncQuery(query, decryptMessage: self.decryptMessage(_:))
    }

    internal func modifySyncQuery(
        _ query: DDXMLElement,
        decryptMessage: (XMPPMessage) throws -> DDXMLElement?
    ) -> DDXMLElement {
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
            // XEP-SYNC may already contain a safe plaintext list preview for
            // an OMEMO conversation. Only run the decrypt/replace path when
            // the embedded message actually carries an OMEMO payload;
            // otherwise a valid preview was being overwritten with
            // "Failed to decrypt".
            guard messageElement.element(
                forName: "encrypted",
                xmlns: getPrimaryNamespace()
            ) != nil else {
                return
            }
            
            do {
                guard let decryptedEnvelope = try decryptMessage(
                    XMPPMessage(from: messageElement)
                ),
                let decryptedContent = decryptedEnvelope.element(
                    forName: "content"
                ) else {
                    return
                }
                // A successfully decrypted attachment-only envelope has no
                // body. Keep any safe server preview in that case; without
                // one, the copied reference lets the list parser choose its
                // neutral attachment fallback.
                if let decryptedBody = decryptedContent
                    .element(forName: "body")?
                    .stringValue,
                   decryptedBody.isNotEmpty {
                    messageElement.remove(forName: "body")
                    messageElement.addChild(
                        DDXMLElement(
                            name: "body",
                            stringValue: decryptedBody
                        )
                    )
                }

                decryptedContent.children?.forEach {
                    if $0.name != "body" {
                        messageElement.addChild($0.copy() as! DDXMLNode)
                    }
                }
                let resultElement = DDXMLElement(
                    name: "omemo-result__system"
                )
                resultElement.addAttribute(
                    withName: "result",
                    boolValue: true
                )
                messageElement.addChild(resultElement)
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
            guard let content = try self.decryptMessage(message) else { return message }
            let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
            message.remove(forName: "body")
            message.addBody(body ?? "")
            if let content = content.element(forName: "content") {
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
                guard let content = try self.decryptMessage(bareMessage) else { return nil }
                let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
                
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? ""))
                if let content = content.element(forName: "content") {
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
                guard let content = try self.decryptMessage(message) else { return nil }
                let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
                message.remove(forName: "body")
                message.addBody(body ?? "")
                if let content = content.element(forName: "content") {
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
    
    internal static func persistDecryptedArchivedMessage(
        _ message: XMPPMessage,
        preferredReceiver: MessageManager?,
        fallbackReceiver: MessageManager?
    ) {
        (preferredReceiver ?? fallbackReceiver)?.receiveArchived(message)
    }

    func didReceiveOmemoMessage(
        _ message: XMPPMessage,
        fromCCC: Bool = false,
        archivedMessageReceiver: MessageManager? = nil
    ) -> Bool {
        if isArchivedMessage(message) {
            do {
                guard let bareMessage = getArchivedMessageContainer(message),
                      bareMessage.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                          return false
                      }
                guard let content = try self.decryptMessage(bareMessage) else { return true }
                let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue

                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? ""))
                if let content = content.element(forName: "content") {
                    content.children?.forEach {
                        if $0.name != "body" {
                            message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild($0.copy() as! DDXMLNode)
                        }
                    }
                    let resultElement = DDXMLElement(name: "omemo-result__system")
                    resultElement.addAttribute(withName: "result", boolValue: true)
                    message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(resultElement)
                }
                Self.persistDecryptedArchivedMessage(
                    message,
                    preferredReceiver: archivedMessageReceiver,
                    fallbackReceiver: AccountManager.shared.find(for: self.owner)?.messages
                )
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
                guard let content = try self.decryptMessage(bareMessage) else { return true }
                let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
                message.element(forName: "sent")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "sent")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? ""))
                if let content = content.element(forName: "content") {
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
                guard let content = try self.decryptMessage(bareMessage) else { return true }
                let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
                
                
                message.element(forName: "received")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "received")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? ""))
                if let content = content.element(forName: "content") {
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
                guard let content = try self.decryptMessage(message) else { return true }
                let body = content.element(forName: "content")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
                message.remove(forName: "body")
                message.addBody(body ?? "")
//                if let content = content {
//                    message.addChild(content)
//                }
                if let content = content.element(forName: "content") {
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
        guard let from = message.from?.bare else { throw OmemoManagerError.invalidEncryptedPayload }
        let encryptedElements = message.children?.compactMap { $0 as? DDXMLElement }.filter { $0.localName == "encrypted" && $0.uri == Self.xmlns } ?? []
        guard encryptedElements.count == 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        let encrypted = encryptedElements[0]
        func children(_ parent: DDXMLElement, _ name: String) -> [DDXMLElement] {
            parent.children?.compactMap { $0 as? DDXMLElement }.filter { $0.localName == name && $0.uri == Self.xmlns } ?? []
        }
        let headers = children(encrypted, "header")
        guard headers.count == 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        let header = headers[0]
        let sid = Int(try OMEMO2BundleCodec.keyID(header.attributeStringValue(forName: "sid")))
        let storage = try ensureOMEMO2Prepared()
        let localID = try storage.localBundle().deviceID
        let keyGroups = children(header, "keys").filter { $0.attributeStringValue(forName: "jid") == owner }
        guard keyGroups.count <= 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        let matches = keyGroups.first.map { children($0, "key").filter { $0.attributeStringValue(forName: "rid") == String(localID) } } ?? []
        guard !matches.isEmpty else { throw OmemoManagerError.missingRecipientKey }
        guard matches.count == 1, let encoded = matches[0].stringValue else { throw OmemoManagerError.invalidEncryptedPayload }
        let kex = matches[0].attributeStringValue(forName: "kex")
        guard kex == nil || ["true", "false", "1", "0"].contains(kex!) else { throw OmemoManagerError.invalidEncryptedPayload }
        let keyExchange = kex == "true" || kex == "1"
        let data = try Omemo2PayloadCodec.decodeBase64(encoded)
        let payloads = children(encrypted, "payload")
        guard payloads.count <= 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        let payload = try payloads.first.map { try Omemo2PayloadCodec.decodeBase64($0.stringValue ?? "") }
        if data.first == 0x33 {
            // The old Signal v3 frame is unambiguous. Never try this path after
            // an OMEMO2 authentication error, or create an outgoing legacy session.
            let address = SignalAddress(name: from, deviceId: Int32(sid))
            guard localStore.sessionRecordExists(for: address) else { throw OmemoManagerError.sessionCreationFailed }
            let cipher = SignalSessionCipher(address: address, context: signalContext)
            let plaintext = try cipher.decryptCiphertext(SignalCiphertext(data: data, type: keyExchange ? .preKeyMessage : .message))
            return try Omemo2PayloadCodec.open(payload, keyAndMAC: plaintext, expectedFrom: from, expectedTo: message.to?.bare ?? owner, requireTo: message.type == "groupchat")
        }
        let ciphertext = try OMEMO2Ciphertext(data: data, keyExchange: keyExchange)
        let previousSessionIdentity = try storage.sessionMetadata(jid: from, deviceID: sid)?.remoteIdentityKey
        var envelope: DDXMLElement?
        do {
            _ = try storage.decrypt(ciphertext, jid: from, deviceID: sid, updatingIdentity: { identity in
                try self.updateAuthenticatedOMEMO2Identity(identity, jid: from, deviceID: sid, previousSessionIdentity: previousSessionIdentity)
            }) { plaintext in
                envelope = try Omemo2PayloadCodec.open(payload, keyAndMAC: plaintext, expectedFrom: from, expectedTo: message.to?.bare ?? owner, requireTo: message.type == "groupchat")
            }
        } catch let error as NSError where error.domain == SignalErrorDomain && error.code == SignalError.duplicateMessage.rawValue {
            return nil
        }
        // Public identity projection has also succeeded before committing the
        // secret state. Receiving an identity never grants device trust.
        if keyExchange {
            _ = try? storage.replenishPreKeys()
            shouldPublicate = true
            AccountManager.shared.find(for: owner)?.action { _, stream in
                do { try self.sendOwnDeviceBundle(stream, createNode: false) }
                catch { self.shouldPublicate = true }
            }
        }
        flushOMEMO2Controls()
        return envelope
    }

    private func updateAuthenticatedOMEMO2Identity(_ identity: Data, jid: String, deviceID: Int, previousSessionIdentity: Data?) throws {
        let realm = try WRealm.safe()
        let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceID)
        let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) ?? SignalDeviceStorageItem()
        let trustedPrimary = SignalTrustedIdentityStoreageItem.genPrimary(owner, for: SignalAddress(name: jid, deviceId: Int32(deviceID)))
        let trusted = realm.object(ofType: SignalTrustedIdentityStoreageItem.self, forPrimaryKey: trustedPrimary)
        let old = trusted?.identity ?? realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary)?.identityKey.flatMap { Data(base64Encoded: $0) } ?? previousSessionIdentity
        let same = old.flatMap { try? Omemo2IdentityRepresentation.canonicalRawX25519(storedIdentityKey: $0) } == (try Omemo2IdentityRepresentation.rawX25519(identityKey: identity))
        try realm.write {
            if device.realm == nil { device.owner = owner; device.jid = jid; device.deviceId = deviceID; device.primary = primary }
            if !same && (old != nil || device.state == .trusted) {
                device.state = .fingerprintChanged; device.trustedByDeviceId = nil; device.isTrustedByCertificate = false
                if let trusted { realm.delete(trusted) }
            }
            device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: identity)
            realm.add(device, update: .modified)
            if same, let trusted { trusted.identity = identity }
        }
    }
}
