//
//  CredentialsManager.swift
//  xabber
//
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
import SwiftKeychainWrapper
import Curve25519Kit
//import Realm

class CredentialsManager: NSObject {
    open class var shared: CredentialsManager {
        struct CredentialsManagerManagerSingleton {
            static let instance = CredentialsManager()
        }
        return CredentialsManagerManagerSingleton.instance
    }
    
    enum StoredKeyType: String {
        case signedPreKey = "signedPreKeySerializedData"
        case identityKeyPublicKey = "identityKeyPublicKey"
        case identityKeyPrivateKey = "identityKeyPrivateKey"
        case preKey = "preKeySerializedData"
    }
    
    enum CredentialsError: Error {
        case itemNotFound
    }
    
    public struct CredentialsStore: Codable {
        var uniqueServiceName: String
        var uniqueAccessGroup: String
    }
    
    
    static func  uniqueServiceName() -> String {
        guard let path = Bundle.main.path(forResource: "credential_store", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let value = try? PropertyListDecoder().decode(CredentialsStore.self, from: xml) else {
              return ""
        }
        return value.uniqueServiceName
    }// = "clandestino.keychain"
    
    static func uniqueAccessGroup() -> String {
        guard let path = Bundle.main.path(forResource: "credential_store", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let value = try? PropertyListDecoder().decode(CredentialsStore.self, from: xml) else {
              return ""
        }
        return value.uniqueAccessGroup
    }
    
//    var uniqueAccessGroup: String = "group.clandestino.shared.data"
    
    class Storage: Hashable, Equatable {
        static func == (lhs: CredentialsManager.Storage, rhs: CredentialsManager.Storage) -> Bool {
            return rhs.jid == lhs.jid
        }
        
        enum Kind: String {
            case password = "password"
            case token = "token"
            case secret = "secret"
        }
        
        var jid: String
        var counter: UInt64 = 0
//        {
//            get {
//                if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
//                   let counter = UInt64(counterRaw) {
//                    return counter
//                }
//                return 1
//            } set {
//                self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newValue)")
//            }
//        }
        
        var kind: Kind = .password
        
        var isBlocked: Bool = false
        
        var isInvalidate: Bool = false
        
        var creditionalString: String? {
            get {
                print("\(self.kind.rawValue):", self.retrieveCreditionals(for: [jid, kind.rawValue].prp()))
                return self.retrieveCreditionals(for: [jid, kind.rawValue].prp())
            }
            set {
                if let value = newValue {
                    self.storeCreditionals(for: [jid, kind.rawValue].prp(), value: value)
                }
            }
        }
        var validationKey: String? {
            get {
                return self.retrieveCreditionals(for: [jid, "validation_key"].prp())
            } set {
                if let value = newValue {
                    self.storeCreditionals(for: [jid, "validation_key"].prp(), value: value)
                }
            }
        }
        
//        var callbacks: SynchronizedArray<SynchronizedArrayCallbackItem> = SynchronizedArray()
        var callbacks: Array<SynchronizedArrayCallbackItem> = Array()
        var isFirstTokenIssued: Bool = false {
            didSet {
                print("Token fpr \(jid) firstIssued: \(isFirstTokenIssued)")
            }
        }
        
        init(jid: String) {
            self.jid = jid
//            do {
//                let realm = try WRealm.safe()
//                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
//                    self.counter = UInt64(instance.counter)!
//                    self.isFirstTokenIssued = false
//                }
//            } catch {
//                
//            }
            if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
               let counter = UInt64(counterRaw) {
                self.isFirstTokenIssued = false
//                self.counter = counter
            }
            if self.retrieveCreditionals(for: [jid, Kind.token.rawValue].prp()) != nil {
                self.kind = .token
            }
            if self.retrieveCreditionals(for: [jid, Kind.secret.rawValue].prp()) != nil {
                self.kind = .secret
            }
        }
        
        public final func updateKind(to predefinedKind: Kind? = nil) {
            print(#function)
            if let kind = predefinedKind {
                self.kind = kind
                return
            }
            self.kind = .password
            if self.retrieveCreditionals(for: [jid, Kind.token.rawValue].prp()) != nil {
                self.kind = .token
            }
            if self.retrieveCreditionals(for: [jid, Kind.secret.rawValue].prp()) != nil {
                self.kind = .secret
            }
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
        
        public final func use(_ callback: @escaping ((Bool, Storage) -> Void)) {
            print("USE SECRET")
            if isBlocked {
                callbacks.append(SynchronizedArrayCallbackItem({
                    [unowned self] in
                    self.isBlocked = true
                    do {
                        callback(isInvalidate, self)
                    }
                }))
            } else {
                if [.token, .secret].contains(self.kind) {
                    isBlocked = true
                }
                do {
                    callback(isInvalidate, self)
                }
            }
        }
        
        public final func release(error: Bool) {
            print("RELEASE SECRET FOR \(self.jid)")
//            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self.isInvalidate = error
                do {
                    if error {
                        self.isBlocked = false
                        self.callbacks = Array()
                    } else {
                        self.isBlocked = false
                        if self.callbacks.isNotEmpty {
                            self.callbacks.removeFirst().callback?()
                        }
                    }
                }
//            }
        }
        
        public func incrementCounter() {
            print(#function)

            if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
               let counter = UInt64(counterRaw) {
                let newCounter = counter + 1
                self.counter = newCounter
                self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newCounter)")
//                self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newCounter)")
            } else {
                print("FATAL ERROR", #function, self.retrieveCreditionals(for: [jid, "counter"].prp()))
            }
        }
        
        public func decrementCounter() {
            print(#function)
            if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
               let counter = UInt64(counterRaw) {
                if counter > 1 {
                    let newCounter = counter - 1
                    self.counter = newCounter
                    self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newCounter)")
                    self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newCounter)")
                }
            } else {
                print("FATAL ERROR", #function)
            }
            
        }
        
        public final func getSecret() -> String? {
            print(#function)
            return self.retrieveCreditionals(for: [jid, Kind.secret.rawValue].prp())
        }
        
//        func storeCounterToRealm(_ value: UInt64) {
//            do {
//                let realm = try WRealm.safe()
//                try realm.write {
//                    realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.counter = "\(value)"
//                }
//            } catch {
//                
//            }
//        }
        
        public func storeSecret(_ value: String, validationKey: String) {
            self.isFirstTokenIssued = true
            self.counter = 1
            self.kind = .secret
            self.storeCreditionals(for: [jid, "validation_key"].prp(), value: validationKey)
            self.storeCreditionals(for: [jid, Kind.secret.rawValue].prp(), value: value)
            self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(self.counter)")
//            self.storeCounterToRealm(self.counter)
            self.removeCreditionals(for: [jid, Kind.password.rawValue].prp())
            self.removeCreditionals(for: [jid, Kind.token.rawValue].prp())
        }
        
        public func storeToken(_ value: String) {
            print(#function)
            self.isFirstTokenIssued = true
            self.counter = 1
            self.kind = .token
            self.storeCreditionals(for: [jid, Kind.token.rawValue].prp(), value: value)
            self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(self.counter)")
//            self.storeCounterToRealm(self.counter)
            self.removeCreditionals(for: [jid, Kind.password.rawValue].prp())
            self.removeCreditionals(for: [jid, Kind.secret.rawValue].prp())
        }
        
        public func storePassword(_ value: String, keepSecret: Bool = false) {
            print(#function)
            self.kind = .password
            self.storeCreditionals(for: [jid, Kind.password.rawValue].prp(), value: value)
            self.removeCreditionals(for: [jid, Kind.token.rawValue].prp())
            if !keepSecret {
                self.removeCreditionals(for: [jid, Kind.secret.rawValue].prp())
            }
//            self.removeCreditionals(for: [jid, "counter"].prp())
        }
        
        private func storeCreditionals(for key: String, value: String) {
            print(#function)
            let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                           accessGroup: CredentialsManager.uniqueAccessGroup())
            let result = keychain.set(value, forKey: key, withAccessibility: .alwaysThisDeviceOnly)
            print(result)
        }
        
        private func retrieveCreditionals(for key: String) -> String? {
            print(#function)
            let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                           accessGroup: CredentialsManager.uniqueAccessGroup())
            return keychain.string(forKey: key)
        }
        
        private func removeCreditionals(for key: String) {
            print(#function)
            let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                           accessGroup: CredentialsManager.uniqueAccessGroup())

            _ = keychain.removeObject(forKey: key)
        }
        
    }
    
    var storage: Set<Storage> = Set<Storage>()
    
    override init() {
        super.init()
    }
    
    public final func clearKeychain() {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeAllKeys()
    }
    
    public final func getItem(for jid: String) -> Storage {
        if let item = storage.first(where: { $0.jid == jid }) {
            return item
        } else {
            let item = Storage(jid: jid)
            storage.insert(item)
            return item
        }
    }
    
    public func setXabberAccountToken(for jid: String, token: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.set(token, forKey: [jid, "xabberAccountToken"].prp(), withAccessibility: .always)
    }
    
    public static func getXabberAccountToken(for jid: String) -> String? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.string(forKey: [jid, "xabberAccountToken"].prp())
    }
    
    public func removeXabberAccountToken(for jid: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeObject(forKey: [jid, "xabberAccountToken"].prp())
    }
    
    public func setXabberAccountTokenExpire(for jid: String, expire: Double) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.set(expire, forKey: [jid, "xabberAccountTokenExpire"].prp(), withAccessibility: .always)
    }
    
    public static func getXabberAccountTokenExpire(for jid: String) -> Double? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.double(forKey: [jid, "xabberAccountTokenExpire"].prp())
    }
    
    public func removeXabberAccountTokenExpire(for jid: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeObject(forKey: [jid, "xabberAccountTokenExpire"].prp())
    }
    
    public func setXabberDeviceId(for jid: String, deviceId: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.set(deviceId, forKey: [jid, "xabberDeviceId"].prp(), withAccessibility: .always)
    }
    
    public static func getXabberDeviceId(for jid: String) -> String? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.string(forKey: [jid, "xabberDeviceId"].prp())
    }
    
    public func removeXabberDeviceId(for jid: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeObject(forKey: [jid, "xabberDeviceId"].prp())
    }
    
    public func setItem(for jid: String, validationKey: String? = nil, secret: String? = nil, token: String? = nil, password: String? = nil, keepSecret: Bool = false) {
        if let item = storage.first(where: { $0.jid == jid }) {
            if let secret = secret {
                item.storeSecret(secret, validationKey: validationKey ?? "")
            } else if let token = token {
                item.storeToken(token)
            } else if let password = password {
                item.storePassword(password, keepSecret: keepSecret)
            }
        } else {
            let item = Storage(jid: jid)
            if let secret = secret {
                item.storeSecret(secret, validationKey: validationKey ?? "")
            } else if let token = token {
                item.storeToken(token)
            } else if let password = password {
                item.storePassword(password, keepSecret: keepSecret)
            }
            storage.insert(item)
        }
    }
       
    private final func storeData(value: Data, for key: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        
        _ = keychain.set(
            value,
            forKey: key,
            withAccessibility: .always,
            isSynchronizable: false
        )
    }
    
    private final func loadData(for key: String) -> Data? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        
        return keychain.data(forKey: key)
    }
    
    private final func removeData(for key: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        
        keychain.removeObject(forKey: key)
    }
    
//    public final func setKey(for jid: String, type keyType: StoredKeyType, value: Data) {
//        self.storeData(value: value, for: [jid, keyType.rawValue].prp())
//    }
//
//    public final func getKey(for jid: String, type keyType: StoredKeyType) throws -> Data {
//        guard let value = loadData(for: [jid, keyType.rawValue].prp()) else {
//            throw CredentialsError.itemNotFound
//        }
//        return value
//    }
    //OMEMO
    public final func setPreKey(for jid: String, id preKeyId: Int, key: Data) {
        self.storeData(value: key, for: [jid, "\(preKeyId)", StoredKeyType.preKey.rawValue].prp())
    }
    
    public final func getPreKey(for jid: String, id preKeyId: Int) -> Data? {
        return loadData(for: [jid, "\(preKeyId)", StoredKeyType.preKey.rawValue].prp())
    }
    
    public final func removePreKey(for jid: String, id preKeyId: Int) {
        self.removeData(for:  [jid, "\(preKeyId)", StoredKeyType.preKey.rawValue].prp())
    }
    
    public final func setSignedPreKey(for jid: String, id spkId: Int, key: Data) {
        self.storeData(value: key, for: [jid, "\(spkId)", StoredKeyType.signedPreKey.rawValue].prp())
    }
    
    public final func getSignedPreKey(for jid: String, id spkId: Int) -> Data? {
        return loadData(for: [jid, "\(spkId)", StoredKeyType.signedPreKey.rawValue].prp())
    }
    
    public final func removeSignedPreKey(for jid: String, id spkId: Int) {
        self.removeData(for:  [jid, "\(spkId)", StoredKeyType.signedPreKey.rawValue].prp())
    }
    
    public final func setIdentityKey(for jid: String, publicKey: Data, privateKey: Data) {
        self.storeData(value: publicKey, for: [jid, StoredKeyType.identityKeyPublicKey.rawValue].prp())
        self.storeData(value: privateKey, for: [jid, StoredKeyType.identityKeyPrivateKey.rawValue].prp())
    }
    
    public final func getIdentityKeyPublicKey(for jid: String)  -> Data? {
        return loadData(for: [jid, StoredKeyType.identityKeyPublicKey.rawValue].prp())
    }
    
    public final func getIdentityKeyPrivateKey(for jid: String)  -> Data? {
        return loadData(for: [jid, StoredKeyType.identityKeyPrivateKey.rawValue].prp())
    }
    
    public final func removeIdentityKey(for jid: String) {
        self.removeData(for:  [jid, StoredKeyType.identityKeyPublicKey.rawValue].prp())
        self.removeData(for:  [jid, StoredKeyType.identityKeyPrivateKey.rawValue].prp())
    }
    
    public final func getRegistrationId(for jid: String) -> Int? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.integer(forKey: [jid, "registrationId"].prp())
    }
    
    public final func getDeviceId(for jid: String) -> Int? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.integer(forKey: [jid, "deviceId"].prp())
    }
    
    public final func setDeviceId(_ deviceId: Int, for jid: String) {
        
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        _ = keychain.set(deviceId, forKey: [jid, "deviceId"].prp(), withAccessibility: .always)
    }
    
    public final func setRegistrationId(_ registrationId: Int, for jid: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.set(registrationId, forKey: [jid, "registrationId"].prp(), withAccessibility: .always)
    }
    
    public final func removeDeviceId(for jid: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeObject(forKey: [jid, "deviceId"].prp())
        keychain.removeObject(forKey: [jid, "registrationId"].prp())
    }
    
    //END OMEMO
    
    public final func storeCertificate(_ data: CFData) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.set(data as Data, forKey: "yubiko_certificate", withAccessibility: .always)
    }
    
    public final func loadCertificate() -> CFData? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.data(forKey: "yubiko_certificate") as CFData?
    }
    
    public final func getSignature() -> String? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.string(forKey: "time_signature")
    }
    
    public final func getSignatureTimestamp() -> Double? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.double(forKey: "time_signature_timestamp")
    }
    
//    public final func setSignature(_ signature: String, for timestamp: TimeInterval, deviceType: YUDeviceType) {
//        
//        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
//                                       accessGroup: CredentialsManager.uniqueAccessGroup())
//        _ = keychain.set(signature, forKey: "time_signature", withAccessibility: .always)
//        _ = keychain.set(timestamp, forKey: "time_signature_timestamp", withAccessibility: .always)
//        _ = keychain.set(deviceType.rawValue, forKey: "time_signature_device_type", withAccessibility: .always)
//    }
    
    
    
//    public final func getSignatureDeviceType() -> YUDeviceType? {
//        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
//                                       accessGroup: CredentialsManager.uniqueAccessGroup())
//        guard let raw = keychain.string(forKey: "time_signature_device_type"),
//              let out = YUDeviceType(rawValue: raw) else {
//                  return nil
//              }
//        return out
//        return nil
//    }
    
    public final func clearSignature()  {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.remove(forKey: "time_signature")
        keychain.remove(forKey: "time_signature_timestamp")
        keychain.remove(forKey: "time_signature_device_type")
        keychain.remove(forKey: "yubiko_certificate")
    }
    
    public final func clearPincodes() {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.remove(forKey: "pincode")
        keychain.remove(forKey: "pincode_timestamp")
    }
    
    public final func isPincodeSetted() -> Bool {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        guard let pincode = keychain.string(forKey: "pincode")  else {
                  return false
              }
        return true
    }
    
    public final func setPincode(_ value: String) {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        _ = keychain.set(value, forKey: "pincode", withAccessibility: .always)
        _ = keychain.set(Date().timeIntervalSince1970, forKey: "pincode_timestamp", withAccessibility: .always)
    }
    
    public final func setPasscodeAttemptsLeft(_ value: Int) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        _ = keychain.set(value, forKey: "passcode_attempts_left", withAccessibility: .always)
    }
    
    public final func getPasscodeAttemptsLeft() -> Int {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        return keychain.integer(forKey: "passcode_attempts_left") ?? 0
    }
    
    public final func getPincodeTimestamp() -> TimeInterval {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        
        return keychain.double(forKey: "pincode_timestamp") ?? 0.0
    }
    
    public final func validatePincode(_ value: String) -> Bool {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        
        guard let pincode = keychain.string(forKey: "pincode"),
              value == pincode else {
                  return false
              }
        return true
    }
    
    public final func updatePincode(_ value: String) -> Bool {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        
        guard let pincode = keychain.string(forKey: "pincode"),
              value == pincode else {
                  return false
              }
        
        keychain.set(Date().timeIntervalSince1970, forKey: "pincode_timestamp", withAccessibility: .always)
        
        return true
    }
    
    public final func updateOnlyPincodeTimestamp() {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        
        keychain.set(Date().timeIntervalSince1970, forKey: "pincode_timestamp", withAccessibility: .always)
    }
    
    struct PushSecretData {
        let host: String
        let secret: String
        let jid: String
        let service: String
        let jwt: String
    }
    
    public final func storePushCredentials(node: String, jid: String, host: String, secret: String, service: String, jwt: String) throws {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        let dict: NSDictionary = [
            "jid": jid,
            "host": host,
            "secret": secret,
            "service": service,
            "jwt": jwt
        ]

        let data = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)

        let json = String(data: data, encoding: .utf8)
        if let json = json {
            print(json)
            keychain.set(json, forKey: node, withAccessibility: .always)
        }
    }
    
    public final func getPushCredentials(for node: String) throws -> PushSecretData {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        guard let jsonString = keychain.string(forKey: node),
              let data = jsonString.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary,
              let jid = dict["jid"] as? String,
              let service = dict["service"] as? String,
              let host = dict["host"] as? String,
              let secret = dict["secret"] as? String,
              let jwt = dict["jwt"] as? String else {
            throw CredentialsError.itemNotFound
        }
        return PushSecretData(host: host, secret: secret, jid: jid, service: service, jwt: jwt)
    }
    
    public final func removePushCredentials(for node: String) {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        keychain.removeObject(forKey: node)
    }
    
    public static func staticGetPushCredentials(for node: String) throws -> PushSecretData {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        guard let jsonString = keychain.string(forKey: node),
              let data = jsonString.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary,
              let jid = dict["jid"] as? String,
              let service = dict["service"] as? String,
              let host = dict["host"] as? String,
              let secret = dict["secret"] as? String,
              let jwt = dict["jwt"] as? String  else {
            throw CredentialsError.itemNotFound
        }
        return PushSecretData(host: host, secret: secret, jid: jid, service: service, jwt: jwt)
    }
    
    private final func clearKeychainFull() {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
        keychain.removeAllKeys()
    }
    
    public final func clearKeyachain() {
        clearPincodes()
        clearSignature()
        if !CommonConfigManager.shared.config.supports_multiaccounts {
            clearKeychainFull()
        }
    }
    
}

