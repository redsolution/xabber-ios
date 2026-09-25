import Foundation
import CommonCrypto
import Security

protocol PasscodeSecretStorage {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

protocol PasscodeEnrollmentMarker {
    func read() throws -> Bool
    func write(_ enrolled: Bool) throws
}

/// This marker participates in backups while the Keychain verifier is bound to this device.
/// A restored installation must therefore stay locked if its verifier is unavailable.
final class FilePasscodeEnrollmentMarker: PasscodeEnrollmentMarker {
    private let url: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let suffix = HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment)
            ? ".hosted-xctest" : ""
        url = support.appendingPathComponent("PasscodeSecurity", isDirectory: true)
            .appendingPathComponent("enrolled-v2\(suffix)")
    }

    func read() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard try Data(contentsOf: url) == Data("enrolled-v2".utf8) else {
            throw PasscodeCredentialStore.Error.corruptStorage
        }
        return true
    }

    func write(_ enrolled: Bool) throws {
        if enrolled {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("enrolled-v2".utf8).write(to: url, options: .atomic)
            guard try read() else { throw PasscodeCredentialStore.Error.storageUnavailable }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Unlike SwiftKeychainWrapper, this adapter reports Keychain errors separately from a missing
/// item and sets protection when updating an existing item.
final class PasscodeKeychainStorage: PasscodeSecretStorage {
    private let service: String
    private let accessGroup: String?

    init(service: String = CredentialsManager.uniqueServiceName(),
         accessGroup: String? = CredentialsManager.uniqueKeychainAccessGroup()) {
        self.service = service
        self.accessGroup = accessGroup?.isEmpty == false ? accessGroup : nil
    }

    private func query(_ key: String) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // SwiftKeychainWrapper stores both account and generic as UTF-8
            // Data. Matching that representation is required for legacy PINs.
            kSecAttrAccount as String: Data(key.utf8),
            kSecAttrGeneric as String: Data(key.utf8),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let accessGroup { attributes[kSecAttrAccessGroup as String] = accessGroup }
        return attributes
    }

    func read(_ key: String) throws -> Data? {
        var attributes = query(key)
        attributes[kSecReturnData as String] = kCFBooleanTrue
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PasscodeCredentialStore.Error.storageUnavailable
        }
        return data
    }

    func attributesForAddition(_ data: Data, for key: String) -> [String: Any] {
        var attributes = query(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return attributes
    }

    func write(_ data: Data, for key: String) throws {
        let itemQuery = query(key)
        let attributes = attributesForAddition(data, for: key)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            guard SecItemUpdate(itemQuery as CFDictionary, updates as CFDictionary) == errSecSuccess else {
                throw PasscodeCredentialStore.Error.storageUnavailable
            }
            return
        }
        throw PasscodeCredentialStore.Error.storageUnavailable
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasscodeCredentialStore.Error.storageUnavailable
        }
    }
}

final class PasscodeCredentialStore {
    static let shared = PasscodeCredentialStore(
        secrets: PasscodeKeychainStorage(),
        marker: FilePasscodeEnrollmentMarker(),
        legacyAttemptLimit: {
            // This file is shared with the push extension, where SettingManager
            // and the settings UI are unavailable.
            let suiteName = CredentialsManager.uniqueAccessGroup()
            guard !suiteName.isEmpty else { throw PasscodeCredentialStore.Error.storageUnavailable }
            return try PasscodeCredentialStore.configuredLegacyAttemptLimit(
                defaults: UserDefaults(suiteName: suiteName)
            )
        }
    )

    static func configuredLegacyAttemptLimit(defaults: UserDefaults?) throws -> Int? {
        guard let defaults else { throw Error.storageUnavailable }
        guard let stored = defaults.object(forKey: "security_passcode_attempts_") else {
            // UserDefaults.integer(forKey:) conflates a missing setting with an
            // explicit zero (Unlimited). Missing data must retain a finite cap.
            return 5
        }
        guard let number = stored as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let limit = Int(number.stringValue), limit >= 0 else {
            throw Error.corruptStorage
        }
        return limit == 0 ? nil : limit
    }

    enum Error: Swift.Error, Equatable {
        case invalidPIN
        case invalidAttemptLimit
        case storageUnavailable
        case corruptStorage
        case notEnrolled
    }

    enum EnrollmentState: Equatable {
        case notEnrolled
        case legacyNeedsReenrollment
        case pendingFirstEnrollment
        case enrolled
    }

    enum VerificationResult: Equatable {
        case matched
        case incorrect(remaining: Int?)
        case exhausted
    }

    private enum Key {
        static let verifier = "passcode_verifier_v2"
        static let limit = "passcode_attempt_limit_v2"
        static let remaining = "passcode_attempts_remaining_v2"
        static let legacyPIN = "pincode"
        static let legacyTimestamp = "pincode_timestamp"
        static let legacyRemaining = "passcode_attempts_left"
    }

    private struct Verifier: Codable {
        let version: Int
        let algorithm: String
        let iterations: Int
        let salt: Data
        let digest: Data
    }

    private let secrets: PasscodeSecretStorage
    private let marker: PasscodeEnrollmentMarker
    private let legacyAttemptLimit: () throws -> Int?
    private let lock = NSRecursiveLock()

    init(secrets: PasscodeSecretStorage,
         marker: PasscodeEnrollmentMarker,
         legacyAttemptLimit: @escaping () throws -> Int?) {
        self.secrets = secrets
        self.marker = marker
        self.legacyAttemptLimit = legacyAttemptLimit
    }

    func enrollmentState() throws -> EnrollmentState {
        lock.lock()
        defer { lock.unlock() }
        let wasEnrolled = try marker.read()
        let v2 = try secrets.read(Key.verifier)
        let legacy = try secrets.read(Key.legacyPIN)
        if v2 != nil {
            if !wasEnrolled {
                // An interrupted re-enrollment may have written part of v2, but the
                // old PIN is still authoritative until the enrollment marker commits.
                if legacy != nil { return .legacyNeedsReenrollment }
                // Fresh enrollment commits the verifier before its file marker.
                // Requiring this new PIN recovers a crash or marker write failure.
                _ = try loadVerifier()
                _ = try readBudget(Key.limit)
                _ = try readBudget(Key.remaining)
                return .pendingFirstEnrollment
            }
            _ = try loadVerifier()
            _ = try readBudget(Key.limit)
            _ = try readBudget(Key.remaining)
            // If termination interrupted legacy cleanup after v2 committed, remove
            // the old plaintext before treating the new credential as usable.
            if legacy != nil { try secrets.remove(Key.legacyPIN) }
            try secrets.remove(Key.legacyTimestamp)
            try secrets.remove(Key.legacyRemaining)
            return .enrolled
        }
        if wasEnrolled { throw Error.corruptStorage }
        return legacy == nil ? .notEnrolled : .legacyNeedsReenrollment
    }

    func enroll(_ pin: String, attempts: Int? = 5) throws {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isValidPIN(pin) else { throw Error.invalidPIN }
        guard attempts == nil || attempts! > 0 else { throw Error.invalidAttemptLimit }
        let state = try enrollmentState()
        if state == .pendingFirstEnrollment { throw Error.corruptStorage }
        if state != .notEnrolled {
            if try remainingAttempts() == 0 { throw Error.corruptStorage }
        }

        let salt = try Self.randomSalt()
        let digest = try Self.derive(pin: pin, salt: salt, iterations: 600_000)
        let verifier = Verifier(version: 2, algorithm: "PBKDF2-HMAC-SHA256",
                                iterations: 600_000, salt: salt, digest: digest)
        try writeBudget(attempts, key: Key.limit)
        try writeBudget(attempts, key: Key.remaining)
        // The verifier is the commit point when replacing an existing v2 PIN.
        // A budget write failure leaves the previous verifier usable.
        try secrets.write(JSONEncoder().encode(verifier), for: Key.verifier)
        try marker.write(true)
        // A crash or write failure before this point leaves the old PIN available for
        // explicit re-enrollment. The v2 verifier takes precedence after completion.
        try secrets.remove(Key.legacyPIN)
        try secrets.remove(Key.legacyTimestamp)
        try secrets.remove(Key.legacyRemaining)
    }

    func verify(_ pin: String) throws -> VerificationResult {
        lock.lock()
        defer { lock.unlock() }
        let state = try enrollmentState()
        guard state != .notEnrolled else { throw Error.notEnrolled }
        let remaining = try remainingAttempts()
        if remaining == 0 { return .exhausted }

        let matches: Bool
        switch state {
        case .enrolled, .pendingFirstEnrollment:
            let verifier = try loadVerifier()
            if Self.isValidPIN(pin) {
                let derived = try Self.derive(pin: pin, salt: verifier.salt,
                                              iterations: verifier.iterations)
                matches = Self.constantTimeEqual(derived, verifier.digest)
            } else {
                matches = false
            }
        case .legacyNeedsReenrollment:
            guard let legacy = try secrets.read(Key.legacyPIN),
                  let oldPIN = String(data: legacy, encoding: .utf8) else {
                throw Error.corruptStorage
            }
            matches = Self.constantTimeEqual(Data(pin.utf8), Data(oldPIN.utf8))
        case .notEnrolled:
            throw Error.notEnrolled
        }

        if matches {
            if state == .pendingFirstEnrollment {
                try marker.write(true)
            }
            try resetRemainingAttemptsAfterSuccessfulAuthentication()
            return .matched
        }
        if let remaining {
            let next = remaining - 1
            try writeBudget(next, key: Key.remaining)
            return next == 0 ? .exhausted : .incorrect(remaining: next)
        }
        return .incorrect(remaining: nil)
    }

    func remainingAttempts() throws -> Int? {
        lock.lock()
        defer { lock.unlock() }
        switch try enrollmentState() {
        case .notEnrolled:
            throw Error.notEnrolled
        case .enrolled, .pendingFirstEnrollment:
            return Self.cappedRemaining(try readBudget(Key.remaining),
                                        limit: try readBudget(Key.limit))
        case .legacyNeedsReenrollment:
            let limit = try attemptLimit()
            if let persisted = try secrets.read(Key.remaining) {
                return Self.cappedRemaining(try decodeBudget(persisted), limit: limit)
            }
            if let old = try secrets.read(Key.legacyRemaining) {
                let value = try Self.decodeLegacyInt(old)
                guard value >= 0 else { throw Error.corruptStorage }
                // Older versions stored zero for an explicitly Unlimited
                // setting. A positive old counter is still a finite security
                // budget, even if the setting now says Unlimited.
                let capped = limit == nil && value == 0
                    ? nil : Self.cappedRemaining(value, limit: limit)
                try writeBudget(capped, key: Key.remaining)
                return capped
            }
            try writeBudget(limit, key: Key.remaining)
            return limit
        }
    }

    func attemptLimit() throws -> Int? {
        lock.lock()
        defer { lock.unlock() }
        switch try enrollmentState() {
        case .notEnrolled:
            throw Error.notEnrolled
        case .enrolled, .pendingFirstEnrollment:
            return try readBudget(Key.limit)
        case .legacyNeedsReenrollment:
            let limit = try legacyAttemptLimit()
            guard limit == nil || limit! > 0 else { throw Error.corruptStorage }
            return limit
        }
    }

    func setAttemptLimit(_ limit: Int?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard limit == nil || limit! > 0 else { throw Error.invalidAttemptLimit }
        let state = try enrollmentState()
        guard state != .notEnrolled else { throw Error.notEnrolled }
        guard state != .pendingFirstEnrollment else { throw Error.corruptStorage }
        // Keep a terminal budget terminal: settings cannot revive a wiped PIN.
        if try remainingAttempts() == 0 { throw Error.corruptStorage }
        try writeBudget(limit, key: Key.limit)
        try writeBudget(limit, key: Key.remaining)
    }

    func resetRemainingAttemptsAfterSuccessfulAuthentication() throws {
        lock.lock()
        defer { lock.unlock() }
        let state = try enrollmentState()
        guard state != .notEnrolled else { throw Error.notEnrolled }
        guard state != .pendingFirstEnrollment else { throw Error.corruptStorage }
        // Biometric success cannot revive a terminal budget or change the
        // configured limit based on a possibly stale settings cache.
        guard try remainingAttempts() != 0 else { throw Error.corruptStorage }
        let limit = try attemptLimit()
        let rawRemaining = try readBudget(Key.remaining)
        if limit == nil, rawRemaining != nil {
            // A failed second write while switching to Unlimited leaves the old
            // finite counter in place. Authentication must not activate Unlimited.
            return
        }
        try writeBudget(limit, key: Key.remaining)
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try secrets.remove(Key.verifier)
        try secrets.remove(Key.limit)
        try secrets.remove(Key.remaining)
        try secrets.remove(Key.legacyPIN)
        try secrets.remove(Key.legacyTimestamp)
        try secrets.remove(Key.legacyRemaining)
        try marker.write(false)
    }

    /// Keychain items can survive an uninstall while the app container and its
    /// enrollment marker do not. The caller must inspect the configured local
    /// Realm before account loading; any read error keeps the credential locked.
    @discardableResult
    func clearOrphanedCredentialsIfSafe(
        hasLocalAccounts: () throws -> Bool,
        isWipePending: () -> Bool
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let enrolled = try marker.read()
        guard !enrolled else { return false }
        guard !isWipePending() else { return false }
        let hasAccounts = try hasLocalAccounts()
        guard !hasAccounts else { return false }
        if let persisted = try secrets.read(Key.remaining) {
            let remaining = try decodeBudget(persisted)
            if remaining == 0 {
                // A terminal attempt must resume the wipe, including when the
                // enrollment file is absent and Realm no longer has accounts.
                return false
            }
        }
        let hasVerifier = try secrets.read(Key.verifier) != nil
        let hasLegacy = try secrets.read(Key.legacyPIN) != nil
        let hasOrphan = hasVerifier || hasLegacy
        guard hasOrphan else { return false }
        try clear()
        return true
    }

    private func loadVerifier() throws -> Verifier {
        guard let data = try secrets.read(Key.verifier),
              let verifier = try? JSONDecoder().decode(Verifier.self, from: data),
              verifier.version == 2,
              verifier.algorithm == "PBKDF2-HMAC-SHA256",
              verifier.iterations == 600_000,
              verifier.salt.count == 16,
              verifier.digest.count == 32 else {
            throw Error.corruptStorage
        }
        return verifier
    }

    private func readBudget(_ key: String) throws -> Int? {
        guard let data = try secrets.read(key) else { throw Error.corruptStorage }
        return try decodeBudget(data)
    }

    private func decodeBudget(_ data: Data) throws -> Int? {
        guard let string = String(data: data, encoding: .utf8),
              let value = Int(string), value >= -1 else { throw Error.corruptStorage }
        return value == -1 ? nil : value
    }

    private func writeBudget(_ count: Int?, key: String) throws {
        try secrets.write(Data(String(count ?? -1).utf8), for: key)
    }

    private static func cappedRemaining(_ remaining: Int?, limit: Int?) -> Int? {
        switch (remaining, limit) {
        case (nil, nil): return nil
        case (nil, let limit?): return limit
        case (let remaining?, nil): return remaining
        case (let remaining?, let limit?): return min(remaining, limit)
        }
    }

    private static func decodeLegacyInt(_ data: Data) throws -> Int {
        if let string = String(data: data, encoding: .utf8), let value = Int(string) {
            return value
        }
        if let number = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSNumber.self, from: data) {
            return number.intValue
        }
        throw Error.corruptStorage
    }

    private static func isValidPIN(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == 6 && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Error.storageUnavailable
        }
        return Data(bytes)
    }

    private static func derive(pin: String, salt: Data, iterations: Int) throws -> Data {
        var output = [UInt8](repeating: 0, count: 32)
        let outputCount = output.count
        let status = pin.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password,
                                        pin.utf8.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                                        salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                        UInt32(iterations),
                                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                                        outputCount)
                }
            }
        }
        guard status == kCCSuccess else { throw Error.storageUnavailable }
        return Data(output)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}
