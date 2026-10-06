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
    static let omemo2MaintenanceCheckInterval: TimeInterval = 60
    static let omemo2PublicationRetryInterval: TimeInterval = 60
    static let omemo2PublicationIQTimeout: TimeInterval = 120
    
//    public var deviceId: UInt32!
    
    internal var shouldPublicate: Bool = false
    
    internal var deviceName: String = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
    
    internal var isOmemoPrepared: Bool
    
    internal var omemo2Storage: XabberOMEMO2Storage?
    private let omemo2CleanupInitializationLock = NSLock()
    private var omemo2CleanupCoordinator: OMEMO2PreKeyCleanupCoordinator?
    internal var omemo2PreKeyCleanup: OMEMO2PreKeyCleanupCoordinator {
        omemo2CleanupInitializationLock.lock()
        defer { omemo2CleanupInitializationLock.unlock() }
        if let omemo2CleanupCoordinator { return omemo2CleanupCoordinator }
        let coordinator = OMEMO2PreKeyCleanupCoordinator(
            consumedIDs: { [weak self] in
                guard let storage = self?.omemo2Storage else { return [] }
                return try storage.consumedPreKeyIDs()
            }, removeConsumed: { [weak self] ids in
                guard let storage = self?.omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
                try storage.removeConsumedPreKeys(ids: ids)
            })
        omemo2CleanupCoordinator = coordinator
        return coordinator
    }
    internal var omemo2ControlSender: ((XMPPMessage) -> Void)?
    internal var omemo2FreshBundleRequester: ((String, Int, String) -> Void)?
    internal var omemo2FreshBundleRequests: [OMEMO2PeerAddress: OMEMO2FreshBundleRequest] = [:]
    internal var omemo2MissingSessionCandidates: [OMEMO2PeerAddress: Date] = [:]
    internal var omemo2DeviceListRequests: [String: OMEMO2DeviceListRequest] = [:]
    internal var omemo2DeviceListRequester: ((String) -> Void)?
    internal var omemo2FreshDeviceIDGenerator: (() -> Int)?
    internal weak var omemo2RegistrationStream: XMPPStream?
    internal var omemo2FreshRegistrationPending = false
    internal var omemo2BundlePublications: [String: Data] = [:]
    internal var omemo2BundlePublicationStartedAt: [String: Date] = [:]
    internal var omemo2PublicationReconfigured = false
    internal var omemo2BundleConfigurationRequestID: String?
    internal var omemo2BundleConfigurationStartedAt: Date?
    internal var omemo2PublicationRetryAt: Date?
    internal var omemo2MaintenanceNow: () -> Date = Date.init
    internal var omemo2LastMaintenanceAt: Date?
    internal let omemo2MaintenanceLock = NSRecursiveLock()
    internal weak var omemo2MaintenancePublicationStream: XMPPStream?
    internal var omemo2MaintenanceScheduler: ((TimeInterval, DispatchWorkItem) -> Void)?
    internal var omemo2MaintenanceWorkItem: DispatchWorkItem?
    internal var omemo2MaintenanceWorkDeadline: Date?
    internal var omemo2MaintenanceWorkID: UUID?

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
        beginOMEMO2Registration(stream)
    }

    internal func beginOMEMO2Registration(_ stream: XMPPStream) {
        omemo2RegistrationStream = stream
        do {
            if let existingID = try existingOMEMO2DeviceID() {
                omemo2FreshRegistrationPending = false
                configureLocal(stream, for: existingID)
            } else {
                isOmemoPrepared = false
                guard isOwnOMEMOEnabled else { return }
                // Even a known persisted snapshot can predate a fresh installation.
                // No SID, identity or prekey is committed before this current fetch.
                omemo2FreshRegistrationPending = true
                getContactDevices(stream, jid: owner, force: true)
            }
        } catch {
            self.isOmemoPrepared = false
            DDLogDebug("OMEMO2 state could not be prepared")
        }
    }
    
    public final func configureLocal(_ stream: XMPPStream, for deviceId: Int) {
        omemo2MaintenanceLock.lock()
        var maintenanceLocked = true
        defer { if maintenanceLocked { omemo2MaintenanceLock.unlock() } }
        do {
            guard try existingOMEMO2DeviceID() != nil else {
                beginOMEMO2Registration(stream)
                return
            }
            omemo2RegistrationStream = stream
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
            _ = try self.ensureOMEMO2Prepared(attemptPublication: false)
            // Rebuild a missing shared SID mirror from the committed profile,
            // including restart after fresh preparation. Existing values remain.
            if CredentialsManager.shared.getDeviceId(for: owner) == nil {
                CredentialsManager.shared.setDeviceId(deviceId, for: owner)
            }
            self.isOmemoPrepared = true
            self.omemo2PublicationReconfigured = false
            for requestID in self.omemo2BundlePublications.keys { self.queryIds.remove(requestID) }
            self.omemo2BundlePublications.removeAll()
            self.omemo2BundlePublicationStartedAt.removeAll()
            if let requestID = self.omemo2BundleConfigurationRequestID { self.queryIds.remove(requestID) }
            self.omemo2BundleConfigurationRequestID = nil
            self.omemo2BundleConfigurationStartedAt = nil
            self.omemo2PublicationRetryAt = nil
            self.omemo2MaintenanceWorkItem?.cancel()
            self.omemo2MaintenanceWorkItem = nil
            self.omemo2MaintenanceWorkDeadline = nil
            self.omemo2MaintenanceWorkID = nil
            self.shouldPublicate = true
            self.updateMyDevice(stream)
            // Control preparation enters sessionQueue before acquiring this
            // lock. Preserve that order when registration finishes.
            omemo2MaintenanceLock.unlock()
            maintenanceLocked = false
            if isOwnOMEMOEnabled, stream.isAuthenticated {
                omemo2PreKeyCleanup.retryEligibleCleanup()
            }
            self.flushOMEMO2Controls()
            AccountManager.shared.find(for: self.owner)?.trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(deviceId))
        } catch {
            self.isOmemoPrepared = false
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }

    /// A stored protected SID or an existing migration credential is never
    /// regenerated as part of registration or a PEP collision check.
    private func existingOMEMO2DeviceID() throws -> Int? {
        guard let storage = omemo2Storage, storage.owner == owner else { throw OMEMO2StorageError.stateUnavailable }
        do { return try storage.localBundle().deviceID }
        catch OMEMO2StorageError.stateUnavailable {
            let realm = try WRealm.safe()
            guard realm.objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND protocolProfile == %@", owner, owner, Self.xmlns).isEmpty else {
                throw OMEMO2StorageError.stateUnavailable
            }
        }
        guard let id = CredentialsManager.shared.getDeviceId(for: owner) else { return nil }
        guard id > 0, id <= Int(Int32.max) else { throw OMEMO2StorageError.invalidDeviceID }
        return id
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
        case handleOMEMO2FreshBundleResponse(iq): return true
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
        let content = DDXMLElement(name: "content", xmlns: "urn:xmpp:sce:1")
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
        let from = DDXMLElement(name: "from", xmlns: "urn:xmpp:sce:1")
        from.addAttribute(withName: "jid", stringValue: self.owner)
        let to = DDXMLElement(name: "to", xmlns: "urn:xmpp:sce:1")
        to.addAttribute(withName: "jid", stringValue: jid)
        let time = DDXMLElement(name: "time", xmlns: "urn:xmpp:sce:1")
        // Queue creation time is not encryption time. The final writer refreshes
        // this again immediately before producing new ciphertext.
        time.addAttribute(withName: "stamp", stringValue: Date().XMPPFormattedDate)
        envelope.addChild(from)
        envelope.addChild(to)
        envelope.addChild(time)
        let rpad = DDXMLElement(name: "rpad", xmlns: "urn:xmpp:sce:1")
        envelope.addChild(rpad)
        do {
            try Omemo2PayloadCodec.applyPadding(to: envelope)
        } catch {
            return nil
        }
        return envelope.compactXMLString
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let identitys = realm.objects(SignalIdentityStorageItem.self).filter("owner == %@", owner)
            let devices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@", owner)
            let preKeys = realm.objects(SignalPreKeysStorageItem.self).filter("owner == %@", owner)
            let sessions = realm.objects(SessionRecordStorageItem.self).filter("owner == %@", owner)
            let deviceLists = realm.objects(OMEMO2DeviceListStorageItem.self).filter("owner == %@", owner)
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
                    deviceLists.forEach { realm.delete($0) }
                    devices.forEach { realm.delete($0) }
                    preKeys.forEach { realm.delete($0) }
                    sessions.forEach { realm.delete($0) }
                    trustedIdentity.forEach { realm.delete($0) }
                    senderKeys.forEach { realm.delete($0) }
                }
            } else {
                identitys.forEach { realm.delete($0) }
                deviceLists.forEach { realm.delete($0) }
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
    
    public func getContactBundle(_ xmppStream: XMPPStream, jid: String, deviceId: Int, force: Bool = false, requestID: String? = nil) {
        let elementId = requestID ?? xmppStream.generateUUID
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
        if requestID == nil { self.queryIds.append(elementId) }
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
                try? user.omemo.sendOwnDevice(stream, createNode: false, excludingIDs: [deviceId])
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
                try self.sendOwnDevice(xmppStream, createNode: false, excludingIDs: [itemId])
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
        if handleOMEMO2FreshBundleResponse(iq) { return true }
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

    func prepareSyncConversations(_ query: DDXMLElement, serverContext: OMEMOReceiveServerContext = .unverified) -> [ClientSyncConversationValue] {
        let cleanup = omemo2PreKeyCleanup
        let ingress = cleanup.beginIngress()
        defer { cleanup.finishIngress(id: ingress) }
        return query.elements(forName: "conversation").map { prepareSyncConversation($0, serverContext: serverContext) }
    }

    func prepareSyncConversation(
        _ conversation: DDXMLElement,
        prepareMessage: ((XMPPMessage) -> OMEMOReceiveResult)? = nil,
        serverContext: OMEMOReceiveServerContext = .unverified
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
        let result = (prepareMessage ?? { self.prepareIncoming($0, context: .syncPreview, serverContext: serverContext) })(XMPPMessage(from: message))
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

    func prepareIncoming(
        _ message: XMPPMessage,
        context: OMEMOReceiveContext = .live,
        originalSendingTime suppliedTime: OMEMOOriginalSendingTime? = nil,
        serverContext: OMEMOReceiveServerContext = .unverified
    ) -> OMEMOReceiveResult {
        let timestampAuthority: OMEMOReceiveServerContext
        if case .syncPreview = context { timestampAuthority = serverContext }
        else { timestampAuthority = .unverified }
        do {
            let copy = XMPPMessage(from: SCEReceivePolicy.droppingUnprotectedSCE(message))
            let path = try Self.incomingPath(copy, owner: owner)
            guard let bare = path.last, SCEReceivePolicy.hasOMEMO2(bare) else { return .notEncrypted(copy) }
            do {
                let originalSendingTime = try Self.originalSendingTime(in: path, supplied: suppliedTime, owner: owner, serverContext: timestampAuthority)
                switch try decryptIncoming(XMPPMessage(from: bare), originalSendingTime: originalSendingTime, optOutContext: context) {
                case .content(let opened, let profile):
                    let contentElements = opened.content.children?.compactMap { $0 as? DDXMLElement } ?? []
                    let hasOptOut = contentElements.contains { SCEReceivePolicy.matches($0, name: "opt-out", namespace: Self.xmlns) }
                    let onlyOptOut = contentElements.allSatisfy {
                        SCEReceivePolicy.matches($0, name: "opt-out", namespace: Self.xmlns) ||
                        SCEReceivePolicy.matches($0, name: "origin-id", namespace: "urn:xmpp:sid:0")
                    }
                    if profile == .omemo2, hasOptOut, onlyOptOut { return .consumed(.control) }
                    Self.reconstruct(path, content: opened.content, owner: owner, serverContext: timestampAuthority)
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
    internal static func incomingPath(_ root: DDXMLElement, owner: String?) throws -> [DDXMLElement] {
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
                let messages = SCEReceivePolicy.rewriteMessages(in: wrapper)
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

    /// Only metadata attached to the validated original stanza can bind SCE
    /// time. A wrapper's receipt time or conversation/query stamp is unrelated.
    internal static func originalSendingTime(
        for message: XMPPMessage,
        owner: String? = nil,
        supplied: OMEMOOriginalSendingTime? = nil
    ) throws -> OMEMOOriginalSendingTime? {
        try originalSendingTime(in: incomingPath(message, owner: owner), supplied: supplied, owner: owner)
    }

    private static func originalSendingTime(
        in path: [DDXMLElement],
        supplied: OMEMOOriginalSendingTime?,
        owner: String? = nil,
        serverContext: OMEMOReceiveServerContext = .unverified
    ) throws -> OMEMOOriginalSendingTime? {
        guard let original = path.last else { throw OmemoManagerError.invalidEncryptedPayload }
        var times: [OMEMOOriginalSendingTime] = []
        func appendTime(
            from element: DDXMLElement,
            name: String,
            namespace: String,
            source: OMEMOOriginalSendingTime.Source
        ) throws {
            let elements = SCEReceivePolicy.children(of: element, named: name, xmlns: namespace)
            guard elements.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
            guard let metadata = elements.first else { return }
            let stamps = metadata.attributes?.filter {
                $0.name == "stamp" && ($0.uri ?? "").isEmpty
            } ?? []
            guard stamps.count == 1, let stamp = stamps[0].stringValue,
                  !(metadata.children ?? []).contains(where: { $0 is DDXMLElement }) else {
                throw OmemoManagerError.invalidDecryptedPayload
            }
            times.append(OMEMOOriginalSendingTime(date: try Omemo2PayloadCodec.timestamp(stamp), source: source))
        }

        try appendTime(from: original, name: "time", namespace: "https://xabber.com/protocol/delivery", source: .xabberDelivery)
        if let forwarded = path.dropLast().last(where: {
            SCEReceivePolicy.matches($0, name: "forwarded", namespace: "urn:xmpp:forward:0")
        }) {
            try appendTime(from: forwarded, name: "delay", namespace: "urn:xmpp:delay", source: .forwardedDelay)
        }
        try appendTime(from: original, name: "delay", namespace: "urn:xmpp:delay", source: .stanzaDelay)
        if let supplied {
            guard supplied.date.timeIntervalSince1970.isFinite else { throw OmemoManagerError.invalidDecryptedPayload }
            times.append(supplied)
        }
        let replacement = try serverReplacement(in: path, owner: owner, serverContext: serverContext)
        guard let selected = times.first else { return replacement?.time }
        // Xabber Delivery requires its timestamp to equal the archive delay.
        // The SCE clock margin is checked separately against this one value.
        guard times.allSatisfy({ $0.date == selected.date }) else { throw OmemoManagerError.invalidDecryptedPayload }
        // Rewriting retains creation/archive dates, but the new ciphertext
        // belongs to the server-confirmed replacement version's timestamp.
        return replacement?.time ?? selected
    }

    private static func serverReplacement(
        in path: [DDXMLElement], owner: String?, serverContext: OMEMOReceiveServerContext = .unverified
    ) throws -> (element: DDXMLElement, time: OMEMOOriginalSendingTime)? {
        guard let root = path.first, let leaf = path.last else { return nil }
        if path.count == 1 && serverContext == .accountServer {
            return try replacementMetadata(in: leaf)
        }
        guard path.count > 1 else { return nil }
        let isRewrite = path.contains { SCEReceivePolicy.matches($0, name: "replace", namespace: "https://xabber.com/protocol/rewrite#notify") }
        let isArchive = path.contains { $0.localName == "result" && SCEReceivePolicy.mamNamespaces.contains($0.uri ?? "") }
        guard isRewrite || isArchive,
              let to = root.attributeStringValue(forName: "to").flatMap({ XMPPJID(string: $0)?.bare }),
              owner == nil || to == owner else { return nil }
        let from = root.attributeStringValue(forName: "from").flatMap { XMPPJID(string: $0)?.bare }
        // Server archives may omit from; a peer-addressed wrapper cannot grant
        // authority to an external replacement marker.
        guard from == to || (isArchive && from == nil && owner == to) else { return nil }
        return try replacementMetadata(in: leaf)
    }

    private static func replacementMetadata(in leaf: DDXMLElement) throws -> (element: DDXMLElement, time: OMEMOOriginalSendingTime)? {
        let markers = SCEReceivePolicy.children(of: leaf, named: "replaced", xmlns: "https://xabber.com/protocol/rewrite")
        guard markers.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
        guard let marker = markers.first else { return nil }
        let attributes = marker.attributes ?? []
        guard attributes.count == 1, attributes[0].localName == "stamp", (attributes[0].uri ?? "").isEmpty,
              let stamp = attributes[0].stringValue,
              !(marker.children ?? []).contains(where: { $0 is DDXMLElement }),
              (marker.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        return (marker, OMEMOOriginalSendingTime(date: try Omemo2PayloadCodec.timestamp(stamp), source: .rewriteReplacement))
    }

    private static func reconstruct(_ path: [DDXMLElement], content: DDXMLElement?, owner: String? = nil, serverContext: OMEMOReceiveServerContext = .unverified) {
        guard let target = path.last else { return }
        let reconstructed = SCEReceivePolicy.sanitized(target, content: content)
        if let content,
           SCEReceivePolicy.children(of: content, named: "replaced", xmlns: "https://xabber.com/protocol/rewrite").isEmpty,
           let replacement = try? serverReplacement(in: path, owner: owner, serverContext: serverContext) {
            // Only a successful decrypt can materialize the server edit marker.
            // Protected markers in legacy history remain authoritative.
            reconstructed.addChild(SCEReceivePolicy.canonicalElementCopy(replacement.element))
        }
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
    func decryptMessage(
        _ message: XMPPMessage,
        originalSendingTime suppliedTime: OMEMOOriginalSendingTime? = nil
    ) throws -> DDXMLElement? {
        let path = try Self.incomingPath(message, owner: owner)
        guard let original = path.last else { throw OmemoManagerError.invalidEncryptedPayload }
        let originalSendingTime = try Self.originalSendingTime(in: path, supplied: suppliedTime, owner: owner)
        switch try decryptIncoming(XMPPMessage(from: original), originalSendingTime: originalSendingTime) {
        case .content(let opened, _): return opened.envelope
        case .control, .duplicate: return nil
        }
    }

    private func decryptIncoming(
        _ message: XMPPMessage,
        originalSendingTime: OMEMOOriginalSendingTime?,
        optOutContext: OMEMOReceiveContext? = nil
    ) throws -> DecryptedIncoming {
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
        if let payload, payload.isEmpty || !payload.count.isMultiple(of: 16) {
            throw OmemoManagerError.invalidEncryptedPayload
        }
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
            if let opened = try Omemo2PayloadCodec.openVerified(payload, keyAndMAC: plaintext, expectedFrom: from, expectedTo: message.to?.bare ?? owner, requireTo: message.type == "groupchat", originalSendingTime: originalSendingTime) {
                return .content(opened, .legacySignal)
            }
            return .control
        }
        let ciphertext = try OMEMO2Ciphertext(data: data, keyExchange: keyExchange)
        guard let replayFingerprint = OMEMO2ReplayProtection.fingerprint(for: message, owner: owner, localDeviceID: localID) else {
            throw OmemoManagerError.invalidEncryptedPayload
        }
        refreshDevicesForUnknownSender(jid: from, deviceID: sid)
        let previousSessionIdentity = try storage.sessionMetadata(jid: from, deviceID: sid)?.remoteIdentityKey
        var opened: Omemo2PayloadCodec.OpenedPayload?
        do {
            _ = try storage.decrypt(ciphertext, jid: from, deviceID: sid, replayFingerprint: replayFingerprint, previouslyAuthenticated: {
                OMEMO2ReplayProtection.hasVerifiedHistory(fingerprint: replayFingerprint, owner: self.owner)
            }, updatingIdentity: { identity in
                try self.updateAuthenticatedOMEMO2Identity(identity, jid: from, deviceID: sid, previousSessionIdentity: previousSessionIdentity)
            }, recordingOptOut: {
                guard let opened, let context = optOutContext, from != self.owner, message.type != "groupchat",
                      let request = SCEReceivePolicy.children(of: opened.content, named: "opt-out", xmlns: Self.xmlns).first else { return nil }
                let protectedDate = try SCEReceivePolicy.children(of: opened.envelope, named: "time", xmlns: "urn:xmpp:sce:1")
                    .first?.attributeStringValue(forName: "stamp").map { try Omemo2PayloadCodec.timestamp($0) }
                let reason = SCEReceivePolicy.children(of: request, named: "reason", xmlns: Self.xmlns)
                    .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let historical: Bool
                switch context {
                case .archive, .carbon, .syncPreview: historical = true
                case .live, .push, .modify: historical = false
                }
                return OMEMO2OptOutRequest(jid: from, fingerprint: replayFingerprint, protectedDate: protectedDate,
                                          reason: reason, historical: historical)
            }) { plaintext in
                opened = try Omemo2PayloadCodec.openVerified(payload, keyAndMAC: plaintext, expectedFrom: from, expectedTo: message.to?.bare ?? owner, requireTo: message.type == "groupchat", originalSendingTime: originalSendingTime)
            }
        } catch OMEMO2StorageError.authenticatedDuplicate {
            return .duplicate
        } catch OMEMO2StorageError.missingSession {
            if !keyExchange { recoverMissingOMEMO2Session(jid: from, deviceID: sid) }
            throw OMEMO2StorageError.missingSession
        }
        // Public identity projection has also succeeded before committing the
        // secret state. Receiving an identity never grants device trust.
        do { try OMEMO2OptOutPolicy.mirror(storage, in: WRealm.safe()) }
        catch { DDLogDebug("OMEMO2 opt-out projection will be retried") }
        if keyExchange {
            omemo2MaintenanceLock.lock()
            _ = try? storage.replenishPreKeys()
            shouldPublicate = true
            omemo2MaintenanceLock.unlock()
            AccountManager.shared.find(for: owner)?.action { _, stream in
                self.retryOMEMO2BundlePublication(on: stream)
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
