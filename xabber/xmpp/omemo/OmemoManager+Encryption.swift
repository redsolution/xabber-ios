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
//import SignalClient
import SignalProtocolObjC
import RealmSwift
import CryptoSwift
import XMPPFramework
import CryptoKit

enum OmemoManagerError: Error {
    case bundleNotFound
    case preKeyNotFound
}

extension OmemoManager {
    
    func testRatchet() {
        
    }
    
    func doubleUnratched(_ encrypted: String, jid: String, deviceId: Int, keyExchange: Bool) throws -> Data? {
        let realm = try WRealm.safe()
        
        guard let encryptedData = Data(base64Encoded: encrypted, options: .ignoreUnknownCharacters) else {
            return nil
        }
        
        let address = SignalAddress(name: jid, deviceId: Int32(deviceId))
        let cipher = SignalSessionCipher(address: address, context: self.signalContext)
        
        let cipherText = SignalCiphertext(data: encryptedData, type: keyExchange ? .preKeyMessage : .message)
                
        let unratched = try cipher.decryptCiphertext(cipherText)
        
        return unratched
    }
    
    func doubleRatchet( hmac: Data, jid: String, deviceId: Int) throws -> DDXMLElement? {
        
        let realm = try WRealm.safe()
        
        guard let storedBundle = realm.object(
            ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: jid,
                deviceId: deviceId
            )
        ) else {
            return nil
        }
                
        guard let preKey = realm.objects(SignalPreKeysStorageItem.self).filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, jid, deviceId).toArray().randomElement() else {
            return nil
        }
        
        guard let storedPreKey64 = preKey.preKey,
              let storedIdentityKey64 = storedBundle.identityKey,
              let storedSignedPreKey64 = storedBundle.signedPreKey,
              let storedSignature64 = storedBundle.signedPreKeySignature,
              let storedPreKey = Data(base64Encoded: storedPreKey64, options: .ignoreUnknownCharacters),
              let storedIdentityKey = Data(base64Encoded: storedIdentityKey64, options: .ignoreUnknownCharacters),
              let storedSignedPreKey = Data(base64Encoded: storedSignedPreKey64, options: .ignoreUnknownCharacters),
              let storedSignature = Data(base64Encoded: storedSignature64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        
        
        let bundle = try! SignalPreKeyBundle(
            registrationId: UInt32(deviceId),
            deviceId: UInt32(deviceId),
            preKeyId: UInt32(preKey.pkId),
            preKeyPublic: storedPreKey,
            signedPreKeyId: UInt32(storedBundle.signedPreKeyId),
            signedPreKeyPublic: storedSignedPreKey,
            signature: storedSignature,
            identityKey: storedIdentityKey
        )
        
        let address = SignalAddress(name: jid, deviceId: Int32(deviceId))
        
        let sessionBuilder = SignalSessionBuilder(address: address, context: self.signalContext)
        
        try! sessionBuilder.processPreKeyBundle(bundle)
        
        
        
        let cipher = SignalSessionCipher(address: address, context: self.signalContext)
        
        
        
        let cipherText = try! cipher.encryptData(hmac)
        
        
        let needKex: Bool = cipherText.type == .preKeyMessage
        
        let message: Data = cipherText.data
        
        let keyElement = DDXMLElement(name: "key")
        
        keyElement.addAttribute(withName: "rid", integerValue: deviceId)
        keyElement.addAttribute(withName: "kex", stringValue: needKex ? "true" : "false")
        keyElement.stringValue = message.base64EncodedString()
        
        print(keyElement)
        
        return keyElement
    }
    
    func encryptMessage(message: String, to jid: String) throws -> DDXMLElement? {
        
        var key = Data(count: 32) // masterKey omemo.js:1780
 
        key.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        
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
        
        let gcm = CBC(iv: iv)
        let aes = try! AES(key: encryptionKey, blockMode: gcm, padding: .pkcs7)
        let encrypted = try! aes.encrypt(Array(message.data(using: .utf8)!))
            
        let symKey = SymmetricKey(data: Data(authKey))
        let hmac = CryptoKit.HMAC<SHA256>.authenticationCode(for: Data(encrypted), using: symKey)
        
        let hmacSliced = Array<UInt8>(hmac.prefix(hmac.byteCount - 16))

        var keyData = Array<UInt8>(key)
        keyData.append(contentsOf: hmacSliced)
        

        let encryptedElement = DDXMLElement(name: "encrypted", xmlns: getPrimaryNamespace())
        let payload = DDXMLElement(name: "payload", stringValue: Data(encrypted).base64EncodedString())
        encryptedElement.addChild(payload)

        let header = DDXMLElement(name: "header")
        header.addAttribute(withName: "sid", integerValue: Int(self.localStore.localDeviceId()))
        let remoteKeysElement = DDXMLElement(name: "keys")
        remoteKeysElement.addAttribute(withName: "jid", stringValue: jid)
        let localKeysElement = DDXMLElement(name: "keys")
        localKeysElement.addAttribute(withName: "jid", stringValue: self.owner)

        let realm = try WRealm.safe()
        
        try realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND state_ == %@",
                    self.owner,
                    jid,
                    SignalDeviceStorageItem.TrustState.trusted.rawValue)
            .toArray()
            .compactMap { return try doubleRatchet(hmac: Data(keyData), jid: jid, deviceId: $0.deviceId) }
            .forEach { remoteKeysElement.addChild($0) }
        
        header.addChild(remoteKeysElement)
        
        try realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND state_ == %@ AND deviceId != %@",
                    self.owner,
                    self.owner,
                    SignalDeviceStorageItem.TrustState.trusted.rawValue,
                    self.localStore.localDeviceId())
            .toArray()
            .compactMap { return try doubleRatchet(hmac: Data(keyData), jid: self.owner,  deviceId: $0.deviceId) }
            .forEach { localKeysElement.addChild($0) }
        
        header.addChild(localKeysElement)

        encryptedElement.addChild(header)

        return encryptedElement
    }
}
