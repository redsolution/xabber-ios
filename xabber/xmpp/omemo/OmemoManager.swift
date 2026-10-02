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

    func prepareSyncConversations(_ query: DDXMLElement) -> [ClientSyncConversationValue] {
        query.elements(forName: "conversation").map { prepareSyncConversation($0) }
    }

    func prepareSyncConversation(
        _ conversation: DDXMLElement,
        prepareMessage: ((XMPPMessage) -> OMEMOReceiveResult)? = nil
    ) -> ClientSyncConversationValue {
        let copy = conversation.copy() as! DDXMLElement
        guard let metadata = copy.elements(forName: "metadata").first(where: {
            $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization"
        }), let last = metadata.element(forName: "last-message") else {
            return ClientSyncConversationValue(copy)
        }
        let messages = SCEReceivePolicy.children(of: last, named: "message", xmlns: "jabber:client")
        guard messages.count == 1 else {
            last.detach()
            return ClientSyncConversationValue(copy, consumed: true)
        }
        let message = messages[0]
        let result = (prepareMessage ?? { self.prepareIncoming($0, context: .syncPreview) })(XMPPMessage(from: message))
        if let reconstructed = result.message {
            message.detach()
            last.addChild(reconstructed.copy() as! DDXMLElement)
        } else {
            // Controls/replays cannot replace a previously visible last message.
            last.detach()
        }
        return ClientSyncConversationValue(copy, encryption: result.provenance, consumed: result.message == nil)
    }

    /// Compatibility XML adapter. Authentication is intentionally not serialized.
    func modifySyncQuery(_ query: DDXMLElement) -> DDXMLElement {
        let copy = query.copy() as! DDXMLElement
        let conversations = prepareSyncConversations(query)
        copy.elements(forName: "conversation").forEach { $0.detach() }
        conversations.compactMap { $0.materializedElement() }.forEach { copy.addChild($0.copy() as! DDXMLElement) }
        return copy
    }

    internal func modifySyncQuery(
        _ query: DDXMLElement,
        decryptMessage: @escaping (XMPPMessage) throws -> DDXMLElement?
    ) -> DDXMLElement {
        let copy = query.copy() as! DDXMLElement
        let conversations = query.elements(forName: "conversation").map { conversation in
            prepareSyncConversation(conversation, prepareMessage: { message in
                guard SCEReceivePolicy.hasOMEMO2(message) else {
                    return .notEncrypted(XMPPMessage(from: SCEReceivePolicy.droppingUnprotectedSCE(message)))
                }
                do {
                    guard let envelope = try decryptMessage(message) else { return .consumed(.control) }
                    guard let content = SCEReceivePolicy.children(of: envelope, named: "content", xmlns: SCEReceivePolicy.sce).first else {
                        throw OmemoManagerError.invalidDecryptedPayload
                    }
                    return .verified(XMPPMessage(from: SCEReceivePolicy.sanitized(message, content: content)), .authenticatedSCE(profile: .omemo2))
                } catch { return .failed(XMPPMessage(from: SCEReceivePolicy.sanitized(message)), error) }
            })
        }
        copy.elements(forName: "conversation").forEach { $0.detach() }
        conversations.compactMap { $0.materializedElement() }.forEach { copy.addChild($0.copy() as! DDXMLElement) }
        return copy
    }

    func modifyOmemoStanza(message: XMPPMessage) -> OMEMOReceiveResult {
        prepareIncoming(message, context: .modify)
    }

    func didReceiveOmemoMessageFromPush(_ message: XMPPMessage) -> OMEMOReceiveResult {
        prepareIncoming(message, context: .push)
    }

    internal static func persistDecryptedArchivedMessage(
        _ message: XMPPMessage,
        preferredReceiver: MessageManager?,
        fallbackReceiver: MessageManager?,
        encryption: MessageEncryptionProvenance = .plaintext
    ) {
        (preferredReceiver ?? fallbackReceiver)?.receiveArchived(message, encryption: encryption)
    }

    /// Compatibility receiver; stream delegates use preparation before dispatch.
    func didReceiveOmemoMessage(
        _ message: XMPPMessage,
        fromCCC: Bool = false,
        archivedMessageReceiver: MessageManager? = nil
    ) -> Bool {
        let result = prepareIncoming(message)
        if case .notEncrypted = result { return false }
        guard let message = result.message else { return true }
        let receiver = archivedMessageReceiver ?? AccountManager.shared.find(for: owner)?.messages
        if isArchivedMessage(message) {
            receiver?.receiveArchived(message, encryption: result.provenance)
        } else if isCarbonCopy(message) {
            receiver?.receiveCarbon(message, encryption: result.provenance)
        } else if isCarbonForwarded(message) {
            receiver?.receiveCarbonForwarded(message, encryption: result.provenance)
        } else {
            receiver?.receiveRuntime(message, encryption: result.provenance)
        }
        return true
    }

    private enum DecryptedIncoming {
        case content(Omemo2PayloadCodec.OpenedPayload, OMEMOReceiveProfile)
        case control
        case duplicate
    }

    func prepareIncoming(_ message: XMPPMessage, context: OMEMOReceiveContext = .live) -> OMEMOReceiveResult {
        do {
            let copy = XMPPMessage(from: SCEReceivePolicy.droppingUnprotectedSCE(message))
            let path = try Self.incomingPath(copy, owner: owner)
            guard let bare = path.last, SCEReceivePolicy.hasOMEMO2(bare) else { return .notEncrypted(copy) }
            do {
                switch try decryptIncoming(XMPPMessage(from: bare)) {
                case .content(let opened, let profile):
                    Self.reconstruct(path, content: opened.content)
                    return .verified(XMPPMessage(from: SCEReceivePolicy.canonicalElementCopy(copy)), .authenticatedSCE(profile: profile))
                case .control: return .consumed(.control)
                case .duplicate: return .consumed(.duplicate)
                }
            } catch {
                Self.reconstruct(path, content: nil)
                return .failed(XMPPMessage(from: SCEReceivePolicy.canonicalElementCopy(copy)), error)
            }
        } catch {
            return SCEReceivePolicy.containsOMEMO2(message) ? .consumed(.invalidTransport) : .notEncrypted(XMPPMessage(from: SCEReceivePolicy.droppingUnprotectedSCE(message)))
        }
    }

    /// Auxiliary ingress can fail closed without creating/loading secret state.
    static func prepareUnverifiedIncoming(_ message: XMPPMessage, owner: String? = nil) -> OMEMOReceiveResult {
        let copy = XMPPMessage(from: SCEReceivePolicy.droppingUnprotectedSCE(message))
        do {
            let path = try incomingPath(copy, owner: owner)
            guard let bare = path.last, SCEReceivePolicy.hasOMEMO2(bare) else { return .notEncrypted(copy) }
            reconstruct(path, content: nil)
        } catch {
            return SCEReceivePolicy.containsOMEMO2(message) ? .consumed(.invalidTransport) : .notEncrypted(copy)
        }
        return .failed(XMPPMessage(from: SCEReceivePolicy.canonicalElementCopy(copy)), OmemoManagerError.invalidEncryptedPayload)
    }

    /// Only recognized transport wrappers may supply an inner encrypted stanza.
    private static func incomingPath(_ root: DDXMLElement, owner: String?) throws -> [DDXMLElement] {
        var path = [root]
        var current = root
        for _ in 0..<3 {
            let children = current.children?.compactMap { $0 as? DDXMLElement } ?? []
            let wrappers = children.filter {
                ($0.localName == "result" && SCEReceivePolicy.mamNamespaces.contains($0.uri ?? "")) ||
                (["sent", "received"].contains($0.localName ?? "") && SCEReceivePolicy.carbonNamespaces.contains($0.uri ?? "")) ||
                SCEReceivePolicy.matches($0, name: "forwarded", namespace: "urn:xmpp:forward:0") ||
                SCEReceivePolicy.matches($0, name: "priority-message", namespace: "https://xabber.com/protocol/priority") ||
                SCEReceivePolicy.matches($0, name: "replace", namespace: "https://xabber.com/protocol/rewrite#notify")
            }
            guard wrappers.count <= 1 else { throw OmemoManagerError.invalidEncryptedPayload }
            guard let wrapper = wrappers.first else { return path }
            // Ciphertext may only occur at the leaf, and receivers unwrap a
            // single transport layer. Reject ambiguity before ratchet commit.
            guard path.count == 1, !SCEReceivePolicy.hasOMEMO2(current) else {
                throw OmemoManagerError.invalidEncryptedPayload
            }
            if SCEReceivePolicy.carbonNamespaces.contains(wrapper.uri ?? "") {
                let from = current.attributeStringValue(forName: "from").flatMap { XMPPJID(string: $0)?.bare }
                let to = current.attributeStringValue(forName: "to").flatMap { XMPPJID(string: $0)?.bare }
                guard let from, let to, from == to, owner == nil || from == owner else {
                    throw OmemoManagerError.invalidEncryptedPayload
                }
            }
            if SCEReceivePolicy.matches(wrapper, name: "replace", namespace: "https://xabber.com/protocol/rewrite#notify") {
                let messages = SCEReceivePolicy.children(of: wrapper, named: "message", xmlns: "jabber:client")
                guard messages.count == 1, !SCEReceivePolicy.hasOMEMO2(wrapper) else { throw OmemoManagerError.invalidEncryptedPayload }
                path += [wrapper, messages[0]]
                current = messages[0]
                continue
            }
            let isDirectForward = SCEReceivePolicy.matches(wrapper, name: "forwarded", namespace: "urn:xmpp:forward:0")
            let forwarded = isDirectForward ? [wrapper] : SCEReceivePolicy.children(of: wrapper, named: "forwarded", xmlns: "urn:xmpp:forward:0")
            guard forwarded.count == 1, !SCEReceivePolicy.hasOMEMO2(wrapper), !SCEReceivePolicy.hasOMEMO2(forwarded[0]) else { throw OmemoManagerError.invalidEncryptedPayload }
            let messages = SCEReceivePolicy.children(of: forwarded[0], named: "message", xmlns: "jabber:client")
            guard messages.count == 1 else { throw OmemoManagerError.invalidEncryptedPayload }
            path += isDirectForward ? [wrapper, messages[0]] : [wrapper, forwarded[0], messages[0]]
            current = messages[0]
        }
        throw OmemoManagerError.invalidEncryptedPayload
    }

    private static func reconstruct(_ path: [DDXMLElement], content: DDXMLElement?) {
        guard let target = path.last else { return }
        let reconstructed = SCEReceivePolicy.sanitized(target, content: content)
        for child in target.children ?? [] { child.detach() }
        for child in reconstructed.children ?? [] { target.addChild(child.copy() as! DDXMLNode) }
        for index in 0..<(path.count - 1) {
            let parent = path[index]
            let retained = path[index + 1]
            for child in parent.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
                // KissXML can expose different wrappers for the same XML node.
                // incomingPath already checked uniqueness of this expanded QName.
                let isRetained = child.localName == retained.localName && child.uri == retained.uri
                if !isRetained && !SCEReceivePolicy.isServerProcessed(child) { child.detach() }
            }
        }
    }

    /// Existing TrustSharing/history callers retain the validated envelope API.
    func decryptMessage(_ message: XMPPMessage) throws -> DDXMLElement? {
        switch try decryptIncoming(message) {
        case .content(let opened, _): return opened.envelope
        case .control, .duplicate: return nil
        }
    }

    private func decryptIncoming(_ message: XMPPMessage) throws -> DecryptedIncoming {
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
            let plaintext: Data
            do {
                plaintext = try cipher.decryptCiphertext(SignalCiphertext(data: data, type: keyExchange ? .preKeyMessage : .message))
            } catch let error as NSError where error.domain == SignalErrorDomain && error.code == SignalError.duplicateMessage.rawValue {
                return .duplicate
            }
            if let opened = try Omemo2PayloadCodec.openVerified(payload, keyAndMAC: plaintext, expectedFrom: from, expectedTo: message.to?.bare ?? owner, requireTo: message.type == "groupchat") {
                return .content(opened, .legacySignal)
            }
            return .control
        }
        let ciphertext = try OMEMO2Ciphertext(data: data, keyExchange: keyExchange)
        let previousSessionIdentity = try storage.sessionMetadata(jid: from, deviceID: sid)?.remoteIdentityKey
        var opened: Omemo2PayloadCodec.OpenedPayload?
        do {
            _ = try storage.decrypt(ciphertext, jid: from, deviceID: sid, updatingIdentity: { identity in
                try self.updateAuthenticatedOMEMO2Identity(identity, jid: from, deviceID: sid, previousSessionIdentity: previousSessionIdentity)
            }) { plaintext in
                opened = try Omemo2PayloadCodec.openVerified(payload, keyAndMAC: plaintext, expectedFrom: from, expectedTo: message.to?.bare ?? owner, requireTo: message.type == "groupchat")
            }
        } catch let error as NSError where error.domain == SignalErrorDomain && error.code == SignalError.duplicateMessage.rawValue {
            return .duplicate
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
        return opened.map { .content($0, .omemo2) } ?? .control
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
