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

enum XabberAxolotlStorageError: LocalizedError {
    case localIdentityKeyPairUnavailable
    case localKeyMaterialUnavailable
    case activeOMEMO2Profile
    
    var errorDescription: String? {
        switch self {
        case .localIdentityKeyPairUnavailable:
            return L10n.text("xabber_axolotl_storage__localized_error_description__local_omemo_identity_key_pair_is_unavailable", fallback: "Local OMEMO identity key pair is unavailable")
        case .localKeyMaterialUnavailable:
            return L10n.text("xabber_axolotl_storage__localized_error_description__local_omemo_key_material_is_unavailable", fallback: "Local OMEMO key material is unavailable")
        case .activeOMEMO2Profile:
            return L10n.text("xabber_axolotl_storage__localized_error_description__omemo2_state_requires_profile_storage", fallback: "Existing OMEMO2 state must be prepared without replacing legacy key material")
        }
    }
}

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
    
    public func create(for deviceId: Int, context: SignalContext) throws {
        guard deviceId > 0, deviceId <= Int(Int32.max) else {
            throw XabberAxolotlStorageError.localKeyMaterialUnavailable
        }
        // A missing Realm device row must not cause identity replacement when
        // an independent OMEMO2 state exists. Read errors also abort before any
        // legacy credential mutation; profile decoding belongs to its store.
        guard try CredentialsManager.shared.getOMEMO2State(for: owner) == nil else {
            throw XabberAxolotlStorageError.activeOMEMO2Profile
        }
        let realm = try WRealm.safe()
        if realm.objects(SignalIdentityStorageItem.self).filter("owner == %@ AND jid == %@ AND protocolProfile == %@", owner, owner, XabberOMEMO2Storage.profile).first != nil {
            throw XabberAxolotlStorageError.activeOMEMO2Profile
        }
        if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId)) {
            guard hasLocalIdentityKeyPair(), getLocalRegistrationId() != 0 else {
                throw XabberAxolotlStorageError.localIdentityKeyPairUnavailable
            }
            try validateExistingIdentity()
            try bindExistingDevice(deviceID: instance.deviceId)
            return
        }
        let existingPublic = CredentialsManager.shared.getIdentityKeyPublicKey(for: owner)
        let existingPrivate = CredentialsManager.shared.getIdentityKeyPrivateKey(for: owner)
        if existingPublic != nil || existingPrivate != nil {
            try validateExistingIdentity()
            if let existingDeviceID = CredentialsManager.shared.getDeviceId(for: owner), existingDeviceID != deviceId {
                throw XabberAxolotlStorageError.localKeyMaterialUnavailable
            }
            // Existing credential pairs and their old SPK/OPKs remain the
            // authority for legacy archives. Public profile metadata is rebuilt
            // by OMEMO2 preparation, not by regenerating keys with old IDs.
            try bindExistingDevice(deviceID: deviceId)
            return
        }
        guard CredentialsManager.shared.getDeviceId(for: owner) == nil,
              realm.objects(SignalIdentityStorageItem.self).filter("owner == %@ AND jid == %@", owner, owner).isEmpty,
              realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", owner, owner).isEmpty else {
            throw XabberAxolotlStorageError.localIdentityKeyPairUnavailable
        }
        self.deviceId = deviceId
        CredentialsManager.shared.setRegistrationId(Int(arc4random_uniform(XabberAxolotlStorage.deviceIdLimit - 1) + 1), for: self.owner)
        CredentialsManager.shared.setDeviceId(self.deviceId, for: owner)
        let keyHelper = SignalKeyHelper(context: context)!
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
        instance.signedPreKeyId = Int(signedPreKey.preKeyId)
        
        try realm.write {
            realm.add(instance)
        }
        try preKeys.forEach {
            preKey in
            if let data = preKey.serializedData() {
                guard self.storePreKey(data, preKeyId: preKey.preKeyId) else {
                    throw XabberAxolotlStorageError.localKeyMaterialUnavailable
                }
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
        guard hasLocalIdentityKeyPair(), getLocalRegistrationId() != 0 else {
            throw XabberAxolotlStorageError.localIdentityKeyPairUnavailable
        }
        
        guard let signedPreKeyData = signedPreKey.serializedData(),
              self.storeSignedPreKey(signedPreKeyData, signedPreKeyId: signedPreKey.preKeyId) else {
            throw XabberAxolotlStorageError.localKeyMaterialUnavailable
        }
        let deviceInstance: SignalDeviceStorageItem = SignalDeviceStorageItem()
        deviceInstance.name = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        deviceInstance.owner = self.owner
        deviceInstance.jid = self.owner
        deviceInstance.deviceId = deviceId
        deviceInstance.state = .trusted
        deviceInstance.freshlyUpdated = true
        deviceInstance.fingerprint = identityKey.publicKey.formattedFingerprint()
        deviceInstance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId)
        try realm.write {
            realm.add(deviceInstance)
        }
        
        realm.refresh()
    }
    
    func localDeviceId() -> Int {
        return self.deviceId
    }

    /// Bind the existing profile device without creating or rewriting keys.
    func bindExistingDevice(deviceID: Int) throws {
        guard deviceID > 0, deviceID <= Int(Int32.max) else {
            throw XabberAxolotlStorageError.localKeyMaterialUnavailable
        }
        self.deviceId = deviceID
    }

    private func validateExistingIdentity() throws {
        guard let publicKey = CredentialsManager.shared.getIdentityKeyPublicKey(for: owner),
              let privateKey = CredentialsManager.shared.getIdentityKeyPrivateKey(for: owner),
              publicKey.count == 33, publicKey.first == 5, privateKey.count == 32,
              let context = try? OMEMO2Context(error: ()),
              let identity = try? context.identity(withPrivateKey: privateKey),
              identity.fingerprintPublicKey == Data(publicKey.dropFirst()) else {
            throw XabberAxolotlStorageError.localIdentityKeyPairUnavailable
        }
    }
    
    func hasLocalIdentityKeyPair() -> Bool {
        return localIdentityKeyPair() != nil
    }
    
    private func localIdentityKeyPair() -> SignalIdentityKeyPair? {
        guard let publicKey = CredentialsManager.shared.getIdentityKeyPublicKey(for: self.owner),
              let privateKey = CredentialsManager.shared.getIdentityKeyPrivateKey(for: self.owner) else {
            return nil
        }
        return try? SignalIdentityKeyPair(publicKey: publicKey, privateKey: privateKey)
    }
}
extension XabberAxolotlStorage: SignalSessionStore {
    
    func sessionRecord(for address: SignalAddress) -> Data? {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: SessionRecordStorageItem.self,
                forPrimaryKey: SessionRecordStorageItem.genPrimary(self.owner, for: address)) {
                guard instance.profile_ == SessionRecordStorageItem.legacyProfile else { return nil }
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
                guard storedInstnace.profile_ == SessionRecordStorageItem.legacyProfile else { return false }
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
            return realm.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: SessionRecordStorageItem.genPrimary(self.owner, for: address))?.profile_ == SessionRecordStorageItem.legacyProfile
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
                .filter("owner == %@ AND jid == %@ AND profile_ == %@", self.owner, addressName, SessionRecordStorageItem.legacyProfile)
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
    static let legacyProfile = "legacy-signal"
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var record: Data? = nil
    @objc dynamic var profile_: String = SessionRecordStorageItem.legacyProfile
    
    static func genPrimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
    
    static func genPrimary(_ owner: String, for address: SignalAddress) -> String {
        return [owner, address.name, "\(address.deviceId)"].prp()
    }
}


extension XabberAxolotlStorage: SignalPreKeyStore {
    
    func loadPreKey(withId preKeyId: UInt32) -> Data? {
        guard let preKey = CredentialsManager.shared.getPreKey(for: self.owner, id: Int(preKeyId)) else {
//            print(preKeyId)
            return nil
            
        }
        return preKey
    }
    
    func storePreKey(_ preKey: Data, preKeyId: UInt32) -> Bool {
        CredentialsManager.shared.setPreKey(for: self.owner, id: Int(preKeyId), key: preKey)
        return containsPreKey(withId: preKeyId)
    }
    
    func containsPreKey(withId preKeyId: UInt32) -> Bool {
        return CredentialsManager.shared.getPreKey(for: self.owner, id: Int(preKeyId)) != nil
    }
    
    func deletePreKey(withId preKeyId: UInt32) -> Bool {
//        CredentialsManager.shared.removePreKey(for: self.owner, id: Int(preKeyId))
        return true
    }
    
}

extension XabberAxolotlStorage: SignalSignedPreKeyStore {
    
    func loadSignedPreKey(withId signedPreKeyId: UInt32) -> Data? {
        return CredentialsManager.shared.getSignedPreKey(for: self.owner, id: Int(signedPreKeyId))
    }
    
    func storeSignedPreKey(_ signedPreKey: Data, signedPreKeyId: UInt32) -> Bool {
        CredentialsManager.shared.setSignedPreKey(for: self.owner, id: Int(signedPreKeyId), key: signedPreKey)
        return containsSignedPreKey(withId: signedPreKeyId)
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
        guard let keyPair = localIdentityKeyPair() else {
            DDLogError("XabberAxolotlStorage: local OMEMO identity key pair is unavailable")
            preconditionFailure("Local OMEMO identity key pair is unavailable")
        }
        return keyPair
    }
    
    func getLocalRegistrationId() -> UInt32 {
        guard let value = CredentialsManager.shared.getRegistrationId(for: self.owner),
              value > 0, value <= Int(UInt32.max) else { return 0 }
        return UInt32(value)
    }
    
    func saveIdentity(_ address: SignalAddress, identityKey: Data?) -> Bool {
        do {
            let realm = try WRealm.safe()
            var identityToStore = identityKey
            if let identityKey = identityKey,
               let storedIdentity = storedIdentity(for: address, in: realm) {
                guard identitiesEquivalent(storedIdentity, identityKey) else {
                    markIdentityChanged(address: address, newIdentityKey: identityKey, in: realm)
                    return false
                }
                // Archive Signal callbacks use 33-byte X keys. Preserve an
                // already migrated Ed key instead of downgrading its encoding.
                identityToStore = storedIdentity
            }
            let instance = SignalTrustedIdentityStoreageItem()
            instance.owner = self.owner
            instance.jid = address.name
            instance.deviceId = Int(address.deviceId)
            instance.identity = identityToStore
            instance.primary = SignalTrustedIdentityStoreageItem.genPrimary(self.owner, for: address)
            if let storedInstance = realm.object(ofType: SignalTrustedIdentityStoreageItem.self, forPrimaryKey: instance.primary) {
                try realm.write {
                    storedInstance.identity = identityToStore
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
        do {
            let realm = try WRealm.safe()
            guard let storedIdentity = storedIdentity(for: address, in: realm) else {
                return true
            }
            if identitiesEquivalent(storedIdentity, identityKey) {
                return true
            }
            markIdentityChanged(address: address, newIdentityKey: identityKey, in: realm)
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
        return false
    }

    private func identitiesEquivalent(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let left = try? Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: lhs),
              let right = try? Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: rhs) else {
            return false
        }
        return left == right
    }
    
    private func storedIdentity(for address: SignalAddress, in realm: Realm) -> Data? {
        if let trustedIdentity = realm.object(
            ofType: SignalTrustedIdentityStoreageItem.self,
            forPrimaryKey: SignalTrustedIdentityStoreageItem.genPrimary(self.owner, for: address)
        )?.identity {
            return trustedIdentity
        }
        
        guard let storedBundle = realm.object(
            ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: address.name,
                deviceId: Int(address.deviceId)
            )
        )?.identityKey else {
            return nil
        }
        
        return Data(base64Encoded: storedBundle, options: .ignoreUnknownCharacters)
    }
    
    private func markIdentityChanged(address: SignalAddress, newIdentityKey: Data, in realm: Realm) {
        do {
            let devicePrimary = SignalDeviceStorageItem.genPrimary(
                owner: self.owner,
                jid: address.name,
                deviceId: Int(address.deviceId)
            )
            let sessionPrimary = SessionRecordStorageItem.genPrimary(self.owner, for: address)
            let trustedPrimary = SignalTrustedIdentityStoreageItem.genPrimary(self.owner, for: address)
            
            try realm.write {
                if let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: devicePrimary),
                   !device.isInvalidated {
                    device.state = .fingerprintChanged
                    device.fingerprint = (try? Omemo2IdentityRepresentation.fingerprint(for: newIdentityKey))
                        ?? newIdentityKey.formattedFingerprint()
                    device.trustDate = Date(timeIntervalSince1970: -1)
                    device.trustedByDeviceId = nil
                    device.isTrustedByCertificate = false
                    device.signedAt = -1
                    device.signedBy = nil
                }
                
                if let session = realm.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: sessionPrimary),
                   !session.isInvalidated {
                    realm.delete(session)
                }
                
                if let trusted = realm.object(ofType: SignalTrustedIdentityStoreageItem.self, forPrimaryKey: trustedPrimary),
                   !trusted.isInvalidated {
                    realm.delete(trusted)
                }
            }
        } catch {
            DDLogDebug("XabberAxolotlStorage: \(#function). \(error.localizedDescription)")
        }
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
