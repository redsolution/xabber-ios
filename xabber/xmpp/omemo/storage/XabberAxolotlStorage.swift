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
import SignalProtocolObjC
import RealmSwift
import CocoaLumberjack


//SignalSessionStore,
//SignalPreKeyStore,
//SignalSignedPreKeyStore,
//SignalIdentityKeyStore,
//SignalSenderKeyStore>


class XabberAxolotlStorage: NSObject, SignalStore {
    public static let deviceIdLimit: UInt32 = 16380
    
    private var deviceId: Int
    
    public var sessionRecord: NSMutableDictionary = NSMutableDictionary()
    
    public var owner: String
    
    init(withOwner owner: String) {
        self.owner = owner
        if let deviceId = CredentialsManager.shared.getDeviceId(for: owner) {
            self.deviceId = deviceId
            super.init()
        } else {
            self.deviceId = -1
//            CredentialsManager.shared.setDeviceId(self.deviceId, for: owner)
            super.init()
        }
    }
    
    public func create(for deviceId: Int, context: SignalContext) {
        if CredentialsManager.shared.getDeviceId(for: owner) != nil {
            return
        }
        self.deviceId = deviceId
        CredentialsManager.shared.setRegistrationId(Int(arc4random() % 16380), for: self.owner)
        CredentialsManager.shared.setDeviceId(self.deviceId, for: owner)
        let keyHelper = SignalKeyHelper(context: context)!
        do {
            let realm = try WRealm.safe()
            let instance = SignalIdentityStorageItem()
            instance.owner = self.owner
            instance.jid = self.owner
            instance.deviceId = self.deviceId
            instance.primary = SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: self.owner,
                deviceId: self.deviceId
            )
            instance.name = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
            
//            let sliced_skp = Data(Array<UInt8>(storedSignedPreKey).suffix(32))
            
            
            let preKeys = keyHelper.generatePreKeys(withStartingPreKeyId: 1, count: 100)
                        
            let identityKey = keyHelper.generateIdentityKeyPair()!
            let signedPreKey = keyHelper.generateSignedPreKey(withIdentity: identityKey, signedPreKeyId: 1)!
            let signature = signedPreKey.signature
//            let signature = Ed25519.sign((signedPreKey.publicKey(), with: identityKey)
            
            instance.identityKey = identityKey.publicKey.base64EncodedString()
            instance.signedPreKey = signedPreKey.keyPair!.publicKey.base64EncodedString()
            instance.signedPreKeySignature = signature.base64EncodedString()
            instance.signedPreKeyId = Int(preKeys.first?.preKeyId ?? arc4random() % 16380)
            
            try realm.write {
                realm.add(instance)
            }
            try preKeys.forEach {
                preKey in
                if let data = preKey.serializedData() {
                    _ = self.storePreKey(data, preKeyId: preKey.preKeyId)
                }
                let instance = SignalPreKeysStorageItem()
                instance.owner = self.owner
                instance.jid = self.owner
                instance.deviceId = Int(localDeviceId())
                instance.pkId = Int(preKey.preKeyId)
                instance.keyUUID = UUID().uuidString
                instance.primary = SignalPreKeysStorageItem.genPrimary(keyUUID: instance.keyUUID)
                instance.preKey = preKey.keyPair!.publicKey.base64EncodedString()
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            
            
            
            CredentialsManager.shared.setIdentityKey(
                for: self.owner,
                publicKey: identityKey.publicKey,
                privateKey: identityKey.privateKey
            )
            
            if let data = signedPreKey.serializedData() {
                _ = self.storeSignedPreKey(data, signedPreKeyId: signedPreKey.preKeyId)
            }
            let deviceInstance: SignalDeviceStorageItem = SignalDeviceStorageItem()
            deviceInstance.name = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
            deviceInstance.owner = self.owner
            deviceInstance.jid = self.owner
            deviceInstance.deviceId = deviceId
            deviceInstance.state = .trusted
            deviceInstance.freshlyUpdated = true
            deviceInstance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId)
            try realm.write {
                realm.add(deviceInstance)
            }
            
            realm.refresh()
            
    //        deviceInstance.fingerprint = Data(identityKey.publicKey.serialize()).formattedFingerprint()
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
    }
    
    func localDeviceId() -> Int {
        return self.deviceId
    }
}
extension XabberAxolotlStorage: SignalSessionStore {
    
    func sessionRecord(for address: SignalAddress) -> Data? {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: SessionRecordStorageItem.self,
                forPrimaryKey: SessionRecordStorageItem.genPrimary(self.owner, for: address)) {
                return instance.record
            }
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
    func storeSessionRecord(_ recordData: Data, for address: SignalAddress) -> Bool {
        do {
            let realm = try WRealm.safe()
            let instance = SessionRecordStorageItem()
            instance.owner = self.owner
            instance.jid = address.name
            instance.deviceId = Int(address.deviceId)
            instance.record = recordData
            instance.primary = SessionRecordStorageItem.genPrimary(self.owner, for: address)
            if let storedInstnace = realm.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: instance.primary)  {
                try realm.write {
                    storedInstnace.record = recordData
                }
            } else {
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            return true
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func sessionRecordExists(for address: SignalAddress) -> Bool {
        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: SessionRecordStorageItem.genPrimary(self.owner, for: address)) != nil
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func deleteSessionRecord(for address: SignalAddress) -> Bool {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: SessionRecordStorageItem.genPrimary(self.owner, for: address)) {
                try realm.write {
                    if instance.isInvalidated { return }
                    realm.delete(instance)
                }
                return true
            }
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func allDeviceIds(forAddressName addressName: String) -> [NSNumber] {
        do {
            let realm = try WRealm.safe()
            return realm
                .objects(SessionRecordStorageItem.self)
                .filter("owner == %@ AND jid == %@", self.owner, addressName)
                .toArray()
                .compactMap { return NSNumber(value: $0.deviceId) }
            
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return []
    }
    
    func deleteAllSessions(forAddressName addressName: String) -> Int32 {
        do {
            let realm = try WRealm.safe()
            let collection = realm
                .objects(SessionRecordStorageItem.self)
                .filter("owner == %@ AND jid == %@", self.owner, addressName)
            let count = collection.count
            try realm.write {
                collection.forEach { realm.delete($0) }
            }
            return Int32(count)
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return -1
    }
    
}


class SessionRecordStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var record: Data? = nil
    
    static func genPrimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
    
    static func genPrimary(_ owner: String, for address: SignalAddress) -> String {
        return [owner, address.name, "\(address.deviceId)"].prp()
    }
}


extension XabberAxolotlStorage: SignalPreKeyStore {
    
    func loadPreKey(withId preKeyId: UInt32) -> Data? {
        return CredentialsManager.shared.getPreKey(for: self.owner, id: Int(preKeyId))
    }
    
    func storePreKey(_ preKey: Data, preKeyId: UInt32) -> Bool {
        CredentialsManager.shared.setPreKey(for: self.owner, id: Int(preKeyId), key: preKey)
        return true
    }
    
    func containsPreKey(withId preKeyId: UInt32) -> Bool {
        return CredentialsManager.shared.getPreKey(for: self.owner, id: Int(preKeyId)) != nil
    }
    
    func deletePreKey(withId preKeyId: UInt32) -> Bool {
        CredentialsManager.shared.removePreKey(for: self.owner, id: Int(preKeyId))
        return true
    }
    
}

extension XabberAxolotlStorage: SignalSignedPreKeyStore {
    
    func loadSignedPreKey(withId signedPreKeyId: UInt32) -> Data? {
        return CredentialsManager.shared.getSignedPreKey(for: self.owner, id: Int(signedPreKeyId))
    }
    
    func storeSignedPreKey(_ signedPreKey: Data, signedPreKeyId: UInt32) -> Bool {
        CredentialsManager.shared.setSignedPreKey(for: self.owner, id: Int(signedPreKeyId), key: signedPreKey)
        return true
    }
    
    func containsSignedPreKey(withId signedPreKeyId: UInt32) -> Bool {
        return CredentialsManager.shared.getSignedPreKey(for: self.owner, id: Int(signedPreKeyId)) != nil
    }
    
    func removeSignedPreKey(withId signedPreKeyId: UInt32) -> Bool {
        CredentialsManager.shared.removeSignedPreKey(for: self.owner, id: Int(signedPreKeyId))
        return true
    }
    
}

extension XabberAxolotlStorage: SignalIdentityKeyStore {
    
    func getIdentityKeyPair() -> SignalIdentityKeyPair {
        guard let publicKey = CredentialsManager.shared.getIdentityKeyPublicKey(for: self.owner),
              let privateKey = CredentialsManager.shared.getIdentityKeyPrivateKey(for: self.owner),
              let keyPair = try? SignalIdentityKeyPair(publicKey: publicKey, privateKey: privateKey) else {
            fatalError()
        }
        return keyPair
    }
    
    func getLocalRegistrationId() -> UInt32 {
        return UInt32(CredentialsManager.shared.getRegistrationId(for: self.owner) ?? 0)
    }
    
    func saveIdentity(_ address: SignalAddress, identityKey: Data?) -> Bool {
        do {
            let realm = try WRealm.safe()
            let instance = SignalTrustedIdentityStoreageItem()
            instance.owner = self.owner
            instance.jid = address.name
            instance.deviceId = Int(address.deviceId)
            instance.identity = identityKey
            instance.primary = SignalTrustedIdentityStoreageItem.genPrimary(self.owner, for: address)
            if let storedInstance = realm.object(ofType: SignalTrustedIdentityStoreageItem.self, forPrimaryKey: instance.primary) {
                try realm.write {
                    storedInstance.identity = identityKey
                }
            } else {
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            return true
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func isTrustedIdentity(_ address: SignalAddress, identityKey: Data) -> Bool {
        return true
//        do {
//            let realm = try WRealm.safe()
//            return realm.object(ofType: SignalTrustedIdentityStoreageItem.self, forPrimaryKey: SignalTrustedIdentityStoreageItem.genPrimary(self.owner, for: address)) != nil
//        } catch {
//            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
//        }
    }
    
}


class SignalTrustedIdentityStoreageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var identity: Data? = nil
    
    static func genPrimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
    
    static func genPrimary(_ owner: String, for address: SignalAddress) -> String {
        return [owner, address.name, "\(address.deviceId)"].prp()
    }
}

extension XabberAxolotlStorage: SignalSenderKeyStore {
    
    func storeSenderKey(_ senderKey: Data, address: SignalAddress, groupId: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            let instance = SignalSenderKeyStoreageItem()
            instance.owner = self.owner
            instance.jid = address.name
            instance.deviceId = Int(address.deviceId)
            instance.groupId = groupId
            instance.senderKey = senderKey
            instance.primary = SignalSenderKeyStoreageItem.genPrimary(self.owner, for: address, groupId: groupId)
            if let storedInstance = realm.object(ofType: SignalSenderKeyStoreageItem.self, forPrimaryKey: instance.primary) {
                try realm.write {
                    storedInstance.senderKey = senderKey
                }
            } else {
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            return true
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func loadSenderKey(for address: SignalAddress, groupId: String) -> Data? {
        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: SignalSenderKeyStoreageItem.self, forPrimaryKey: SignalSenderKeyStoreageItem.genPrimary(self.owner, for: address, groupId: groupId))?.senderKey
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
}

class SignalSenderKeyStoreageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    @objc dynamic var groupId: String = ""
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var senderKey: Data? = nil
    
    static func genPrimary(owner: String, jid: String, deviceId: Int, groupId: String) -> String {
        return [owner, jid, "\(deviceId)", groupId].prp()
    }
    
    static func genPrimary(_ owner: String, for address: SignalAddress, groupId: String) -> String {
        return [owner, address.name, "\(address.deviceId)", groupId].prp()
    }
}
