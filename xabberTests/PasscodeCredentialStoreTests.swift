import XCTest
import Security
@testable import xabber

final class PasscodeCredentialStoreTests: XCTestCase {
    private final class MemorySecrets: PasscodeSecretStorage {
        var values: [String: Data] = [:]
        var failReads = false
        var failWrites = false
        var failRemovals = false
        var failWriteOnceForKey: String?

        func read(_ key: String) throws -> Data? {
            if failReads { throw PasscodeCredentialStore.Error.storageUnavailable }
            return values[key]
        }

        func write(_ data: Data, for key: String) throws {
            if failWrites { throw PasscodeCredentialStore.Error.storageUnavailable }
            if failWriteOnceForKey == key {
                failWriteOnceForKey = nil
                throw PasscodeCredentialStore.Error.storageUnavailable
            }
            values[key] = data
        }

        func remove(_ key: String) throws {
            if failRemovals { throw PasscodeCredentialStore.Error.storageUnavailable }
            values.removeValue(forKey: key)
        }
    }

    private final class MemoryMarker: PasscodeEnrollmentMarker {
        var enrolled = false
        var failWrites = false
        func read() throws -> Bool { enrolled }
        func write(_ enrolled: Bool) throws {
            if failWrites { throw PasscodeCredentialStore.Error.storageUnavailable }
            self.enrolled = enrolled
        }
    }

    private func makeStore(
        secrets: MemorySecrets = MemorySecrets(),
        marker: MemoryMarker = MemoryMarker(),
        legacyLimit: Int? = 5
    ) -> PasscodeCredentialStore {
        PasscodeCredentialStore(secrets: secrets, marker: marker, legacyAttemptLimit: { legacyLimit })
    }

    func testEnrollmentStoresVerifierWithoutPlaintextAndVerifiesPIN() throws {
        let secrets = MemorySecrets()
        let marker = MemoryMarker()
        let store = makeStore(secrets: secrets, marker: marker)

        try store.enroll("012345", attempts: 5)

        XCTAssertEqual(try store.enrollmentState(), .enrolled)
        XCTAssertTrue(marker.enrolled)
        XCTAssertNil(secrets.values["pincode"])
        let verifier = try XCTUnwrap(secrets.values["passcode_verifier_v2"])
        XCTAssertNil(verifier.range(of: Data("012345".utf8)))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: verifier) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 2)
        XCTAssertEqual(payload["algorithm"] as? String, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(payload["iterations"] as? Int, 600_000)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(payload["salt"] as? String))?.count, 16)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(payload["digest"] as? String))?.count, 32)
        XCTAssertEqual(try store.verify("012345"), .matched)
    }

    func testSharedBudgetExhaustsOnFinalWrongPINAndNeverResetsAtZero() throws {
        let store = makeStore()
        try store.enroll("012345", attempts: 2)

        XCTAssertEqual(try store.verify("000000"), .incorrect(remaining: 1))
        XCTAssertEqual(try store.verify("000000"), .exhausted)
        XCTAssertEqual(try store.remainingAttempts(), 0)
        XCTAssertEqual(try store.verify("012345"), .exhausted)
        XCTAssertThrowsError(try store.resetRemainingAttemptsAfterSuccessfulAuthentication())
    }

    func testSuccessfulVerificationRestoresConfiguredBudget() throws {
        let store = makeStore()
        try store.enroll("012345", attempts: 3)

        XCTAssertEqual(try store.verify("111111"), .incorrect(remaining: 2))
        XCTAssertEqual(try store.verify("012345"), .matched)
        XCTAssertEqual(try store.remainingAttempts(), 3)
    }

    func testUnlimitedBudgetRemainsUnlimited() throws {
        let store = makeStore()
        try store.enroll("012345", attempts: nil)
        for _ in 0..<8 {
            XCTAssertEqual(try store.verify("111111"), .incorrect(remaining: nil))
        }
        XCTAssertNil(try store.remainingAttempts())
    }

    func testLegacyPINRequiresReenrollmentAndIsRemovedAfterNewVerifier() throws {
        let secrets = MemorySecrets()
        secrets.values["pincode"] = Data("123456".utf8)
        secrets.values["passcode_attempts_left"] = Data("2".utf8)
        let store = makeStore(secrets: secrets)

        XCTAssertEqual(try store.enrollmentState(), .legacyNeedsReenrollment)
        XCTAssertEqual(try store.verify("123456"), .matched)
        XCTAssertEqual(try store.enrollmentState(), .legacyNeedsReenrollment)
        XCTAssertNotNil(secrets.values["pincode"])

        try store.enroll("654321", attempts: 5)

        XCTAssertNil(secrets.values["pincode"])
        XCTAssertEqual(try store.enrollmentState(), .enrolled)
        XCTAssertEqual(try store.verify("654321"), .matched)
    }

    func testInterruptedLegacyReenrollmentUsesOldPINUntilMarkerCommits() throws {
        let secrets = MemorySecrets()
        let marker = MemoryMarker()
        secrets.values["pincode"] = Data("123456".utf8)
        secrets.values["passcode_verifier_v2"] = Data("incomplete-v2".utf8)
        let store = makeStore(secrets: secrets, marker: marker)

        XCTAssertEqual(try store.enrollmentState(), .legacyNeedsReenrollment)
        XCTAssertEqual(try store.verify("123456"), .matched)
        try store.enroll("654321", attempts: 5)
        XCTAssertEqual(try store.enrollmentState(), .enrolled)
    }

    func testInterruptedFirstEnrollmentRequiresNewPINBeforeMarkerCommits() throws {
        let secrets = MemorySecrets()
        let marker = MemoryMarker()
        let store = makeStore(secrets: secrets, marker: marker)
        marker.failWrites = true

        XCTAssertThrowsError(try store.enroll("123456", attempts: 3))
        XCTAssertEqual(try store.enrollmentState(), .pendingFirstEnrollment)
        XCTAssertThrowsError(try store.enroll("999999", attempts: 3))
        XCTAssertEqual(try store.verify("000000"), .incorrect(remaining: 2))
        XCTAssertThrowsError(try store.verify("123456"))
        XCTAssertEqual(try store.enrollmentState(), .pendingFirstEnrollment)

        marker.failWrites = false
        XCTAssertEqual(try store.verify("123456"), .matched)
        XCTAssertEqual(try store.enrollmentState(), .enrolled)
        XCTAssertEqual(try store.remainingAttempts(), 3)
    }

    func testMalformedStagedFirstEnrollmentRemainsLocked() throws {
        let secrets = MemorySecrets()
        secrets.values["passcode_verifier_v2"] = Data("bad".utf8)
        let store = makeStore(secrets: secrets)

        XCTAssertThrowsError(try store.enrollmentState())
        XCTAssertThrowsError(try store.verify("123456"))
    }

    func testCommittedVerifierDoesNotAuthorizeWhileLegacyPlaintextCleanupFails() throws {
        let secrets = MemorySecrets()
        let store = makeStore(secrets: secrets)
        try store.enroll("123456", attempts: 5)
        secrets.values["pincode"] = Data("old-pin".utf8)
        secrets.failRemovals = true

        XCTAssertThrowsError(try store.enrollmentState())
        XCTAssertThrowsError(try store.verify("123456"))
    }

    func testAttemptBudgetPersistsAcrossStoreInstances() throws {
        let secrets = MemorySecrets()
        let marker = MemoryMarker()
        try makeStore(secrets: secrets, marker: marker).enroll("123456", attempts: 3)
        XCTAssertEqual(try makeStore(secrets: secrets, marker: marker).verify("000000"),
                       .incorrect(remaining: 2))
        XCTAssertEqual(try makeStore(secrets: secrets, marker: marker).remainingAttempts(), 2)
    }

    func testFailedSecondWriteWhileLoweringLimitCannotIncreaseEffectiveBudget() throws {
        let secrets = MemorySecrets()
        let store = makeStore(secrets: secrets)
        try store.enroll("123456", attempts: 5)
        secrets.failWriteOnceForKey = "passcode_attempts_remaining_v2"

        XCTAssertThrowsError(try store.setAttemptLimit(2))
        XCTAssertEqual(try store.attemptLimit(), 2)
        XCTAssertEqual(try store.remainingAttempts(), 2)
        XCTAssertEqual(try store.verify("000000"), .incorrect(remaining: 1))
    }

    func testFailedSecondWriteTowardUnlimitedKeepsFiniteBudgetAfterAuthentication() throws {
        let secrets = MemorySecrets()
        let store = makeStore(secrets: secrets)
        try store.enroll("123456", attempts: 5)
        XCTAssertEqual(try store.verify("000000"), .incorrect(remaining: 4))
        secrets.failWriteOnceForKey = "passcode_attempts_remaining_v2"

        XCTAssertThrowsError(try store.setAttemptLimit(nil))
        XCTAssertNil(try store.attemptLimit())
        XCTAssertEqual(try store.remainingAttempts(), 4)
        XCTAssertEqual(try store.verify("123456"), .matched)
        try store.resetRemainingAttemptsAfterSuccessfulAuthentication()
        XCTAssertEqual(try store.remainingAttempts(), 4)

        try store.setAttemptLimit(nil)
        XCTAssertNil(try store.remainingAttempts())
    }

    func testLegacyArchivedAttemptCounterIsReadWithoutReset() throws {
        let secrets = MemorySecrets()
        secrets.values["pincode"] = Data("123456".utf8)
        secrets.values["passcode_attempts_left"] = try NSKeyedArchiver.archivedData(
            withRootObject: NSNumber(value: 2), requiringSecureCoding: false
        )
        let store = makeStore(secrets: secrets, legacyLimit: 5)

        XCTAssertEqual(try store.remainingAttempts(), 2)
        XCTAssertEqual(try store.verify("000000"), .incorrect(remaining: 1))
    }

    func testMissingLegacyLimitSettingDefaultsToFiniteBudget() throws {
        let suite = "xabber.passcode.legacy-limit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(try PasscodeCredentialStore.configuredLegacyAttemptLimit(defaults: defaults), 5)
        defaults.set(0, forKey: "security_passcode_attempts_")
        XCTAssertNil(try PasscodeCredentialStore.configuredLegacyAttemptLimit(defaults: defaults))
        defaults.set(3, forKey: "security_passcode_attempts_")
        XCTAssertEqual(try PasscodeCredentialStore.configuredLegacyAttemptLimit(defaults: defaults), 3)
        defaults.set(false, forKey: "security_passcode_attempts_")
        XCTAssertThrowsError(try PasscodeCredentialStore.configuredLegacyAttemptLimit(defaults: defaults))
        XCTAssertThrowsError(try PasscodeCredentialStore.configuredLegacyAttemptLimit(defaults: nil))
    }

    func testLegacyFiniteCounterSurvivesExplicitUnlimitedSetting() throws {
        let secrets = MemorySecrets()
        secrets.values["pincode"] = Data("123456".utf8)
        secrets.values["passcode_attempts_left"] = Data("2".utf8)
        let store = makeStore(secrets: secrets, legacyLimit: nil)

        XCTAssertEqual(try store.remainingAttempts(), 2)
        XCTAssertEqual(try store.verify("000000"), .incorrect(remaining: 1))
    }

    func testFreshReinstallClearsOrphanedVerifierOnlyAfterEmptyAccountCheck() throws {
        let secrets = MemorySecrets()
        secrets.values["passcode_verifier_v2"] = Data("orphan".utf8)
        let store = makeStore(secrets: secrets)

        XCTAssertTrue(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { false }, isWipePending: { false }
        ))
        XCTAssertNil(secrets.values["passcode_verifier_v2"])
        XCTAssertEqual(try store.enrollmentState(), .notEnrolled)
    }

    func testOrphanRecoveryKeepsCredentialWhenAccountsOrWipeRemain() throws {
        let secrets = MemorySecrets()
        secrets.values["pincode"] = Data("123456".utf8)
        let store = makeStore(secrets: secrets)

        XCTAssertFalse(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { true }, isWipePending: { false }
        ))
        XCTAssertFalse(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { false }, isWipePending: { true }
        ))
        XCTAssertNotNil(secrets.values["pincode"])

        XCTAssertTrue(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { false }, isWipePending: { false }
        ))
        XCTAssertNil(secrets.values["pincode"])
    }

    func testOrphanRecoveryFailsClosedOnRealmReadErrorOrEnrollmentMarker() throws {
        let secrets = MemorySecrets()
        secrets.values["passcode_verifier_v2"] = Data("verifier".utf8)
        let marker = MemoryMarker()
        let store = makeStore(secrets: secrets, marker: marker)

        XCTAssertThrowsError(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { throw PasscodeCredentialStore.Error.storageUnavailable },
            isWipePending: { false }
        ))
        XCTAssertNotNil(secrets.values["passcode_verifier_v2"])

        marker.enrolled = true
        XCTAssertFalse(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { false }, isWipePending: { false }
        ))
        XCTAssertNotNil(secrets.values["passcode_verifier_v2"])
    }

    func testTerminalBudgetBlocksOrphanRecoveryUntilWipeCompletes() throws {
        let secrets = MemorySecrets()
        let marker = MemoryMarker()
        let store = makeStore(secrets: secrets, marker: marker)
        try store.enroll("123456", attempts: 1)
        XCTAssertEqual(try store.verify("000000"), .exhausted)
        marker.enrolled = false

        XCTAssertFalse(try store.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: { false }, isWipePending: { false }
        ))
        XCTAssertNotNil(secrets.values["passcode_verifier_v2"])
        XCTAssertEqual(try store.remainingAttempts(), 0)
    }

    func testMissingDeviceOnlyVerifierWithEnrollmentMarkerFailsClosed() throws {
        let secrets = MemorySecrets()
        let marker = MemoryMarker()
        let store = makeStore(secrets: secrets, marker: marker)
        try store.enroll("012345", attempts: 5)
        secrets.values.removeValue(forKey: "passcode_verifier_v2")

        XCTAssertThrowsError(try store.enrollmentState())
        XCTAssertThrowsError(try store.verify("012345"))
    }

    func testStorageReadAndWriteErrorsNeverAuthorizeUnlock() throws {
        let secrets = MemorySecrets()
        let store = makeStore(secrets: secrets)
        secrets.failWrites = true
        XCTAssertThrowsError(try store.enroll("012345", attempts: 5))
        secrets.failWrites = false
        try store.enroll("012345", attempts: 5)
        secrets.failReads = true
        XCTAssertThrowsError(try store.verify("012345"))
    }

    func testOnlySixASCIIDigitsCanBeEnrolled() throws {
        let store = makeStore()
        for pin in ["12345", "1234567", "１２３４５６", "１２3456", "12345a"] {
            XCTAssertThrowsError(try store.enroll(pin, attempts: 5))
        }
    }

    func testDeviceOnlyAccessibilityInIsolatedHostedKeychain() throws {
        guard HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment) else {
            throw XCTSkip("Hosted Keychain isolation is required")
        }
        let service = "xabber.passcode.test.\(UUID().uuidString)"
        let key = "verifier"
        let accessGroup = CredentialsManager.uniqueKeychainAccessGroup()
        XCTAssertFalse(accessGroup.isEmpty)
        let storage = PasscodeKeychainStorage(service: service, accessGroup: accessGroup)
        defer { try? storage.remove(key) }
        let addition = storage.attributesForAddition(Data([1, 2, 3]), for: key)
        XCTAssertEqual(addition[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        if addStatus != errSecSuccess {
            // The required accessibility assertion above still runs in unsigned
            // hosted tests. A signed runner is needed for the Security round trip.
            throw XCTSkip("Hosted simulator Keychain is unavailable (status \(addStatus))")
        }
        try storage.write(Data([4, 5, 6]), for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Data(key.utf8),
            kSecAttrGeneric as String: Data(key.utf8),
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
