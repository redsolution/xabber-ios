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

private func credentialsDebugLog(_ message: String) {
    #if DEBUG
    NSLog("%@", message)
    #endif
}

private func credentialsDiagnosticHash(_ value: String) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return String(format: "%016llx", hash)
}

enum HostedXCTestIsolationPolicy {
    static let hostedXCTestEnvironmentKey = "XCTestConfigurationFilePath"
    static let disableAccountAutoconnectEnvironmentKey = "XABBER_DISABLE_ACCOUNT_AUTOCONNECT"
    static let isolatedStorageEnvironmentKey = "XABBER_ISOLATED_STORAGE"

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[hostedXCTestEnvironmentKey] != nil
            && environment[disableAccountAutoconnectEnvironmentKey] == "1"
            && environment[isolatedStorageEnvironmentKey] == "1"
    }
}

class CredentialsManager: NSObject {
    private static var testDataStore: [String: Data] = [:]
    private static var testIntStore: [String: Int] = [:]
    private static let testStoreLock = NSLock()
    
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

    static let hostedXCTestServiceSuffix = ".hosted-xctest"

    static func resolvedCredentialsStore(
        base: CredentialsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> CredentialsStore {
        // The test-only service must be stable between hosted test processes so
        // their cleanup can reach prior test data without ever reaching the app service.
        _ = processIdentifier
        guard HostedXCTestIsolationPolicy.isEnabled(environment: environment) else {
            return base
        }

        return CredentialsStore(
            uniqueServiceName: base.uniqueServiceName + hostedXCTestServiceSuffix,
            uniqueAccessGroup: base.uniqueAccessGroup
        )
    }

    private static func bundledCredentialsStore() -> CredentialsStore? {
        guard let path = Bundle.main.path(forResource: "credential_store", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let value = try? PropertyListDecoder().decode(CredentialsStore.self, from: xml) else {
            return nil
        }
        return value
    }

    static func uniqueServiceName() -> String {
        guard let base = bundledCredentialsStore() else { return "" }
        return resolvedCredentialsStore(base: base).uniqueServiceName
    }// = "clandestino.keychain"

    static func uniqueAccessGroup() -> String {
        guard let base = bundledCredentialsStore() else { return "" }
        return resolvedCredentialsStore(base: base).uniqueAccessGroup
    }
    
//    var uniqueAccessGroup: String = "group.clandestino.shared.data"
    
    class Storage: Hashable, Equatable {
        static func == (lhs: CredentialsManager.Storage, rhs: CredentialsManager.Storage) -> Bool {
            return rhs.jid == lhs.jid
        }
        
        enum Kind: String, Equatable {
            case password = "password"
            case token = "token"
            case secret = "secret"
        }

        enum ReleaseOutcome {
            case authSucceeded
            case authFailedRecoverable
            case credentialRevoked
        }

        struct AuthenticationCounterReservation: Equatable {
            let jid: String
            let attemptID: String
            let counter: UInt64
            let nextCounter: UInt64
            let credentialGeneration: UInt64
        }

        enum CounterReservationError: Error, Equatable {
            case counterOverflow
            case persistenceFailed
        }

        static var counterPersistenceOverride: ((String, UInt64) -> Bool)?
        
        var jid: String
        var counter: UInt64 = 0
        private var credentialGeneration: UInt64 = 0
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
                let credential = self.retrieveCreditionals(for: [jid, kind.rawValue].prp())
                credentialsDebugLog("CredentialsManager: credential lookup jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) present=\(credential != nil)")
                return credential
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
        private let lock = NSRecursiveLock()
        var isFirstTokenIssued: Bool = false {
            didSet {
                credentialsDebugLog("CredentialsManager: credential first token state jidHash=\(credentialsDiagnosticHash(jid)) firstIssued=\(isFirstTokenIssued)")
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
                self.counter = counter
            }
            if self.retrieveCreditionals(for: [jid, Kind.token.rawValue].prp()) != nil {
                self.kind = .token
            }
            if self.retrieveCreditionals(for: [jid, Kind.secret.rawValue].prp()) != nil {
                self.kind = .secret
            }
        }
        
        public final func updateKind(to predefinedKind: Kind? = nil) {
            withLock {
                if let kind = predefinedKind {
                    self.kind = kind
                    credentialsDebugLog("CredentialsManager: credential kind updated jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) predefined=true")
                    return
                }
                self.kind = .password
                if self.retrieveCreditionals(for: [jid, Kind.token.rawValue].prp()) != nil {
                    self.kind = .token
                }
                if self.retrieveCreditionals(for: [jid, Kind.secret.rawValue].prp()) != nil {
                    self.kind = .secret
                }
                credentialsDebugLog("CredentialsManager: credential kind updated jidHash=\(credentialsDiagnosticHash(jid)) kind=\(self.kind.rawValue) predefined=false")
            }
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
        
        public final func use(_ callback: @escaping ((Bool, Storage) -> Void)) {
            credentialsDebugLog("CredentialsManager: credential use requested jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) blocked=\(isBlocked)")
            let callbackToRun: (() -> Void)? = withLock {
                if isBlocked {
                    callbacks.append(SynchronizedArrayCallbackItem({
                        [weak self] in
                        guard let self = self else { return }
                        let invalidated = self.withLock { () -> Bool in
                            if [.token, .secret].contains(self.kind) {
                                self.isBlocked = true
                            }
                            return self.isInvalidate
                        }
                        callback(invalidated, self)
                    }))
                    return nil
                }
                if [.token, .secret].contains(self.kind) {
                    isBlocked = true
                }
                let invalidated = isInvalidate
                return {
                    callback(invalidated, self)
                }
            }
            callbackToRun?()
        }
        
        public final func release(_ outcome: ReleaseOutcome) {
            credentialsDebugLog("CredentialsManager: credential release jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) outcome=\(outcome)")
            let callbackToRun: (() -> Void)? = withLock {
                switch outcome {
                case .authSucceeded:
                    self.isInvalidate = false
                    self.isBlocked = false
                    return self.callbacks.isNotEmpty ? self.callbacks.removeFirst().callback : nil

                case .authFailedRecoverable:
                    self.isBlocked = false
                    self.callbacks = Array()
                    return nil

                case .credentialRevoked:
                    self.isInvalidate = true
                    self.isBlocked = false
                    self.callbacks = Array()
                    return nil
                }
            }
            callbackToRun?()
        }
        
        public func incrementCounter() {
            withLock {
                let newCounter = self.currentCounter() + 1
                self.counter = newCounter
                self.storeCounter(newCounter)
            }
//            self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newCounter)")
        }
        
        public func decrementCounter() {
            withLock {
                if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
                   let counter = UInt64(counterRaw) {
                    if counter > 1 {
                        let newCounter = counter - 1
                        self.counter = newCounter
                        self.storeCounter(newCounter)
                    }
                } else {
                    credentialsDebugLog("CredentialsManager: credential counter missing on decrement jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue)")
                }
            }
            
        }
        
        public final func getSecret() -> String? {
            let secret = self.retrieveCreditionals(for: [jid, Kind.secret.rawValue].prp())
            credentialsDebugLog("CredentialsManager: credential secret lookup jidHash=\(credentialsDiagnosticHash(jid)) present=\(secret != nil)")
            return secret
        }

        public final func currentCounter() -> UInt64 {
            withLock {
                if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
                   let counter = UInt64(counterRaw),
                   counter > 0 {
                    self.counter = counter
                    return counter
                }
                return max(self.counter, 1)
            }
        }

        public final func reserveCounterForAuthentication() throws -> AuthenticationCounterReservation {
            try withLock {
                let counter = self.currentCounter()
                guard counter < UInt64.max else {
                    credentialsDebugLog("CredentialsManager: counter reservation overflow jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue)")
                    throw CounterReservationError.counterOverflow
                }

                let nextCounter = counter + 1
                let previousCounter = self.counter
                self.counter = nextCounter

                guard self.storeCounter(nextCounter, allowTestOverride: true),
                      let persistedRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
                      UInt64(persistedRaw) == nextCounter else {
                    self.counter = previousCounter
                    credentialsDebugLog("CredentialsManager: counter reservation persistence failed jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) counter=\(counter) nextCounter=\(nextCounter)")
                    throw CounterReservationError.persistenceFailed
                }

                let reservation = AuthenticationCounterReservation(
                    jid: jid,
                    attemptID: UUID().uuidString,
                    counter: counter,
                    nextCounter: nextCounter,
                    credentialGeneration: credentialGeneration
                )
                credentialsDebugLog("CredentialsManager: counter reserved jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) attemptID=\(reservation.attemptID) counter=\(counter) nextCounter=\(nextCounter) generation=\(credentialGeneration)")
                return reservation
            }
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
            withLock {
                self.credentialGeneration += 1
                self.isInvalidate = false
                self.isBlocked = false
                self.callbacks.removeAll()
                self.isFirstTokenIssued = true
                self.counter = 1
                self.kind = .secret
                self.storeCreditionals(for: [jid, "validation_key"].prp(), value: validationKey)
                self.storeCreditionals(for: [jid, Kind.secret.rawValue].prp(), value: value)
                self.storeCounter(self.counter)
//            self.storeCounterToRealm(self.counter)
                self.removeCreditionals(for: [jid, Kind.password.rawValue].prp())
                self.removeCreditionals(for: [jid, Kind.token.rawValue].prp())
            }
        }
        
        public func storeToken(_ value: String) {
            withLock {
                self.credentialGeneration += 1
                self.isInvalidate = false
                self.isBlocked = false
                self.callbacks.removeAll()
                self.isFirstTokenIssued = true
                self.counter = 1
                self.kind = .token
                self.storeCreditionals(for: [jid, Kind.token.rawValue].prp(), value: value)
                self.storeCounter(self.counter)
//            self.storeCounterToRealm(self.counter)
                self.removeCreditionals(for: [jid, Kind.password.rawValue].prp())
                self.removeCreditionals(for: [jid, Kind.secret.rawValue].prp())
            }
        }
        
        public func storePassword(_ value: String, keepSecret: Bool = false) {
            withLock {
                self.credentialGeneration += 1
                self.isInvalidate = false
                self.isBlocked = false
                self.callbacks.removeAll()
                self.kind = .password
                self.storeCreditionals(for: [jid, Kind.password.rawValue].prp(), value: value)
                self.removeCreditionals(for: [jid, Kind.token.rawValue].prp())
                if !keepSecret {
                    self.removeCreditionals(for: [jid, Kind.secret.rawValue].prp())
                }
            }
//            self.removeCreditionals(for: [jid, "counter"].prp())
        }

        private func withLock<T>(_ block: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try block()
        }
        
        @discardableResult
        private func storeCounter(_ value: UInt64, allowTestOverride: Bool = false) -> Bool {
            if allowTestOverride,
               let counterPersistenceOverride = Self.counterPersistenceOverride,
               !counterPersistenceOverride(jid, value) {
                return false
            }
            return self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(value)")
        }

        @discardableResult
        private func storeCreditionals(for key: String, value: String) -> Bool {
            let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                           accessGroup: CredentialsManager.uniqueAccessGroup())
            let result = keychain.set(value, forKey: key, withAccessibility: .alwaysThisDeviceOnly)
            credentialsDebugLog("CredentialsManager: credential store jidHash=\(credentialsDiagnosticHash(jid)) kind=\(kind.rawValue) success=\(result)")
            return result
        }
        
        private func retrieveCreditionals(for key: String) -> String? {
            let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                           accessGroup: CredentialsManager.uniqueAccessGroup())
            return keychain.string(forKey: key)
        }
        
        private func removeCreditionals(for key: String) {
            let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                           accessGroup: CredentialsManager.uniqueAccessGroup())

            _ = keychain.removeObject(forKey: key)
        }
        
    }
    
    var storage: Set<Storage> = Set<Storage>()
    private let storageLock = NSRecursiveLock()
    
    override init() {
        super.init()
    }
    
    public final func clearKeychain() {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeAllKeys()
    }
    
    public final func getItem(for jid: String) -> Storage {
        storageLock.lock()
        defer { storageLock.unlock() }

        if let item = storage.first(where: { $0.jid == jid }) {
            return item
        }

        let item = Storage(jid: jid)
        storage.insert(item)
        return item
    }
    
    public func setXabberAccountUUID(for jid: String, uuid uuidString: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.set(uuidString, forKey: [jid, "xabberAccountUUID"].prp(), withAccessibility: .always)
    }
    
    public static func getXabberAccountUUID(for jid: String) -> String? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.string(forKey: [jid, "xabberAccountUUID"].prp())
    }
    
    public func removeXabberAccountUUID(for jid: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        keychain.removeObject(forKey: [jid, "xabberAccountUUID"].prp())
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
        let item = getItem(for: jid)
        if let secret = secret {
            item.storeSecret(secret, validationKey: validationKey ?? "")
        } else if let token = token {
            item.storeToken(token)
        } else if let password = password {
            item.storePassword(password, keepSecret: keepSecret)
        }
    }
       
    private final func primaryKeychain() -> KeychainWrapper {
        return KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueAccessGroup()
        )
    }
    
    private final func fallbackKeychain() -> KeychainWrapper {
        return KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName())
    }
    
    private final var isRunningTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    
    private final func storeTestData(_ value: Data, for key: String) {
        guard isRunningTests else { return }
        CredentialsManager.testStoreLock.lock()
        CredentialsManager.testDataStore[key] = value
        CredentialsManager.testStoreLock.unlock()
    }
    
    private final func loadTestData(for key: String) -> Data? {
        guard isRunningTests else { return nil }
        CredentialsManager.testStoreLock.lock()
        defer { CredentialsManager.testStoreLock.unlock() }
        return CredentialsManager.testDataStore[key]
    }
    
    private final func removeTestData(for key: String) {
        guard isRunningTests else { return }
        CredentialsManager.testStoreLock.lock()
        CredentialsManager.testDataStore.removeValue(forKey: key)
        CredentialsManager.testStoreLock.unlock()
    }
    
    private final func storeTestInt(_ value: Int, for key: String) {
        guard isRunningTests else { return }
        CredentialsManager.testStoreLock.lock()
        CredentialsManager.testIntStore[key] = value
        CredentialsManager.testStoreLock.unlock()
    }
    
    private final func loadTestInt(for key: String) -> Int? {
        guard isRunningTests else { return nil }
        CredentialsManager.testStoreLock.lock()
        defer { CredentialsManager.testStoreLock.unlock() }
        return CredentialsManager.testIntStore[key]
    }
    
    private final func removeTestInt(for key: String) {
        guard isRunningTests else { return }
        CredentialsManager.testStoreLock.lock()
        CredentialsManager.testIntStore.removeValue(forKey: key)
        CredentialsManager.testStoreLock.unlock()
    }
    
    private final func storeData(value: Data, for key: String) {
        storeTestData(value, for: key)
        let keychain = primaryKeychain()
        let didStore = keychain.set(
            value,
            forKey: key,
            withAccessibility: .always,
            isSynchronizable: false
        )
        
        guard !didStore else { return }
        
        let didStoreFallback = fallbackKeychain().set(
            value,
            forKey: key,
            withAccessibility: .always,
            isSynchronizable: false
        )
        if didStoreFallback {
            credentialsDebugLog("CredentialsManager: stored secure data with fallback keychain service")
        } else {
            credentialsDebugLog("CredentialsManager: failed to store secure data")
        }
    }
    
    private final func loadData(for key: String) -> Data? {
        if let data = primaryKeychain().data(forKey: key) {
            return data
        }
        return fallbackKeychain().data(forKey: key) ?? loadTestData(for: key)
    }
    
    private final func removeData(for key: String) {
        primaryKeychain().removeObject(forKey: key)
        fallbackKeychain().removeObject(forKey: key)
        removeTestData(for: key)
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
        let key = [jid, "registrationId"].prp()
        return primaryKeychain().integer(forKey: key) ?? fallbackKeychain().integer(forKey: key) ?? loadTestInt(for: key)
    }
    
    public final func getDeviceId(for jid: String) -> Int? {
        let key = [jid, "deviceId"].prp()
        return primaryKeychain().integer(forKey: key) ?? fallbackKeychain().integer(forKey: key) ?? loadTestInt(for: key)
    }
    
    public final func setDeviceId(_ deviceId: Int, for jid: String) {
        let key = [jid, "deviceId"].prp()
        storeTestInt(deviceId, for: key)
        if !primaryKeychain().set(deviceId, forKey: key, withAccessibility: .always) {
            let didStoreFallback = fallbackKeychain().set(deviceId, forKey: key, withAccessibility: .always)
            if didStoreFallback {
                credentialsDebugLog("CredentialsManager: stored device id with fallback keychain service")
            } else {
                credentialsDebugLog("CredentialsManager: failed to store device id")
            }
        }
    }
    
    public final func setRegistrationId(_ registrationId: Int, for jid: String) {
        let key = [jid, "registrationId"].prp()
        storeTestInt(registrationId, for: key)
        if !primaryKeychain().set(registrationId, forKey: key, withAccessibility: .always) {
            let didStoreFallback = fallbackKeychain().set(registrationId, forKey: key, withAccessibility: .always)
            if didStoreFallback {
                credentialsDebugLog("CredentialsManager: stored registration id with fallback keychain service")
            } else {
                credentialsDebugLog("CredentialsManager: failed to store registration id")
            }
        }
    }
    
    public final func removeDeviceId(for jid: String) {
        let deviceIdKey = [jid, "deviceId"].prp()
        let registrationIdKey = [jid, "registrationId"].prp()
        primaryKeychain().removeObject(forKey: deviceIdKey)
        primaryKeychain().removeObject(forKey: registrationIdKey)
        fallbackKeychain().removeObject(forKey: deviceIdKey)
        fallbackKeychain().removeObject(forKey: registrationIdKey)
        removeTestInt(for: deviceIdKey)
        removeTestInt(for: registrationIdKey)
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
            credentialsDebugLog("CredentialsManager: push credential stored hostPresent=\(host.isEmpty == false) servicePresent=\(service.isEmpty == false)")
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
