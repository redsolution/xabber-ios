////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import SignalProtocolObjC
//import RealmSwift
//
//extension OmemoManager {
////    internal final func loadKeys(for deviceId: Int) throws {
//////        localStore = InMemorySignalProtocolStore()        §§§§
////        let signedPreKeyBytes = try CredentialsManager.shared.getKey(for: self.owner, type: .signedPreKey)
////        let signedPreKeySignatureBytes = try CredentialsManager.shared.getKey(for: self.owner, type: .signedPreKeySignature)
////        let identityKeyBytes = try CredentialsManager.shared.getKey(for: self.owner, type: .identityKey)
////
////        self.deviceId = UInt32(deviceId)
////        let realm = try WRealm.safe()
////        guard let preKeyPublicRecord = realm
////            .objects(SignalPreKeysStorageItem.self)
////            .filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, self.owner, deviceId)
////            .toArray()
////            .randomElement() else {
////                throw OmemoManagerError.preKeyNotFound
////            }
////
////        guard let bundleRecord = realm.object(
////            ofType: SignalIdentityStorageItem.self,
////            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
////                owner: self.owner,
////                jid: self.owner,
////                deviceId: deviceId
////            )
////        ) else {
////            throw OmemoManagerError.bundleNotFound
////        }
////
////        let preKeyPrivateBytes = try CredentialsManager.shared.getPreKey(for: self.owner, id: preKeyPublicRecord.pkId)
//////        let pkKeyPair: [ECKeyPair] = try realm
//////            .objects(SignalPreKeysStorageItem.self)
//////            .filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, self.owner, self.localStore.localDeviceId())
//////            .compactMap { return $0.pkId }
//////            .compactMap { return try CredentialsManager.shared.getPreKey(for: self.owner, id: $0) }
//////            .compactMap { return  }
////
//////        self.preKey
//////        self.preKey = try PreKeyRecord(
//////            id: UInt32(preKeyPublicRecord.pkId),
//////            publicKey: try PublicKey(preKeyPublicRecord.preKey),
//////            privateKey: try PrivateKey(preKeyPrivateBytes))
//////
//////        let signedPreKey = try SignedPreKeyRecord(
//////            id: UInt32(bundleRecord.signedPreKeyId),
//////            timestamp: UInt64(bundleRecord.signedPreKeyTimestamp),
//////            privateKey: try PrivateKey(signedPreKeyBytes),
//////            signature: signedPreKeySignatureBytes
//////        )
//////        let identityKey = try IdentityKey(bytes: identityKeyBytes)
//////        try localStore.storePreKey(self.preKey, id: self.preKey.id, context: NullContext())
//////        try localStore.storeSignedPreKey(signedPreKey, id: signedPreKey.id, context: NullContext())
//////
//////        let bundle = try PreKeyBundle(
//////            registrationId: UInt32(bundleRecord.registrationId),
//////            deviceId: UInt32(deviceId),
//////            prekeyId: preKey.id,
//////            prekey: preKey.publicKey,
//////            signedPrekeyId: signedPreKey.id,
//////            signedPrekey: signedPreKey.publicKey,
//////            signedPrekeySignature: signedPreKey.signature,
//////            identity: identityKey
//////        )
//////        try processPreKeyBundle(
//////            bundle,
//////            for: try ProtocolAddress(name: bundleRecord.name, deviceId: UInt32(deviceId)),
//////            sessionStore: localStore,
//////            identityStore: localStore,
//////            context: NullContext()
//////        )
////        self.deviceId = UInt32(deviceId)
////        self.isOmemoPrepared = true
////    }
////
////    internal final func initKeys(for deviceId: Int) throws {
////
////        self.preKeys = try OmemoManager.generatePreKeys()
//////        localStore = InMemorySignalProtocolStore()
//////
//////        self.deviceId = UInt32(deviceId)
//////        let preKeys = try initPreKeys(for: deviceId)
//////        guard let preKey = preKeys.randomElement() else {
//////            throw OmemoManagerError.preKeyNotFound
//////        }
//////        self.preKeys = preKeys
//////        let identityKey = try localStore.identityKeyPair(context: NullContext()).identityKey
//////        let signedPreKey = PrivateKey.generate()
//////        let signedPreKeySignature = try localStore.identityKeyPair(context: NullContext()).privateKey.generateSignature(message: signedPreKey.publicKey.serialize())
//////        let signedPreKeyRecord = try SignedPreKeyRecord(id: UInt32.random(in: 0..<OmemoManager.signalPreKeysMaxVal - 1), timestamp: UInt64(Date().timeIntervalSince1970), privateKey: signedPreKey, signature: signedPreKeySignature)
//////        try localStore.storePreKey(preKey, id: preKey.id, context: NullContext())
//////        try localStore.storeSignedPreKey(signedPreKeyRecord, id: signedPreKeyRecord.id, context: NullContext())
//////        let bundle = try PreKeyBundle(
//////            registrationId: try localStore.localRegistrationId(context: NullContext()),
//////            deviceId: UInt32(deviceId),
//////            prekeyId: preKey.id,
//////            prekey: preKey.publicKey,
//////            signedPrekeyId: signedPreKeyRecord.id,
//////            signedPrekey: signedPreKeyRecord.publicKey,
//////            signedPrekeySignature: signedPreKeySignature,
//////            identity: identityKey
//////        )
//////
//////        let localAddr = try ProtocolAddress(name: self.owner, deviceId: UInt32(deviceId))
//////
//////        try processPreKeyBundle(
//////            bundle,
//////            for: localAddr,
//////            sessionStore: localStore,
//////            identityStore: localStore,
//////            context: NullContext()
//////        )
////
////        let realm = try WRealm.safe()
////
////        let identityInstance = SignalIdentityStorageItem()
////        identityInstance.owner = self.owner
////        identityInstance.jid = self.owner
////        identityInstance.deviceId = deviceId
////        identityInstance.primary = SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.owner, deviceId: deviceId)
//////        identityInstance.name = localAddr.name
//////        identityInstance.registrationId = Int(bundle.registrationId)
//////        identityInstance.signedPreKeyId = Int(signedPreKeyRecord.id)
//////        identityInstance.signedPreKeyTimestamp = Double(signedPreKeyRecord.timestamp)
//////
//////        identityInstance.signedPreKeySignature = Data(signedPreKeySignature)
//////        identityInstance.signedPreKey = Data(signedPreKey.publicKey.serialize())
//////        identityInstance.signedPreKeyPrivate = Data(signedPreKey.serialize())
//////        identityInstance.identityKey = Data(identityKey.serialize())
////
////        let preKeysCollection = preKeys.compactMap {
////            privateKey -> SignalPreKeysStorageItem in
////            let uuid = UUID().uuidString
////            let instance = SignalPreKeysStorageItem()
////            instance.deviceId = deviceId
////            instance.owner = self.owner
////            instance.jid = self.owner
////            instance.pkId = Int(privateKey.id)
//////            instance.preKey = Data(privateKey.publicKey.serialize())
////            instance.keyUUID = uuid
////            instance.primary = SignalPreKeysStorageItem.genPrimary(keyUUID: uuid)
////
//////            CredentialsManager.shared.setPreKey(for: self.owner, id: Int(privateKey.id), value: Data(privateKey.privateKey.serialize()))
////            return instance
////        }
////
////        let deviceInstance = SignalDeviceStorageItem()
////        deviceInstance.name = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
////        deviceInstance.owner = self.owner
////        deviceInstance.jid = self.owner
////        deviceInstance.deviceId = deviceId
////        deviceInstance.state = .trusted
////        deviceInstance.freshlyUpdated = true
////        deviceInstance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId)
//////        deviceInstance.fingerprint = Data(identityKey.publicKey.serialize()).formattedFingerprint()
////
////        try realm.write {
////            realm.add(preKeysCollection)
////            realm.add(identityInstance)
////            realm.add(deviceInstance)
////        }
////
//////        CredentialsManager.shared.setKey(for: self.owner, type: .identityKey, value: Data(identityKey.serialize()))
//////        CredentialsManager.shared.setKey(for: self.owner, type: .signedPreKey, value: Data(signedPreKey.serialize()))
//////        CredentialsManager.shared.setKey(for: self.owner, type: .signedPreKeySignature, value: Data(signedPreKeySignature))
//////        XMPPUIActionManager.shared.open(owner: self.owner)
////        self.shouldPublicate = true
////        self.isOmemoPrepared = true
////        self.deviceId = UInt32(deviceId)
////    }
//}
