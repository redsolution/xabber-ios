import Foundation
import RealmSwift
import Security
import XCTest
@testable import xabber

final class OMEMO2StateStorageTests: XCTestCase {
    func testExplicitKeychainGroupIsOmittedOnlyForFullyIsolatedHostedTests() {
        let environment = ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
                           "XABBER_DISABLE_ACCOUNT_AUTOCONNECT": "1", "XABBER_ISOLATED_STORAGE": "1"]
        XCTAssertFalse(CredentialsManager.omemo2KeychainUsesAccessGroup(environment: environment))
        for key in environment.keys {
            var partial = environment
            partial.removeValue(forKey: key)
            XCTAssertTrue(CredentialsManager.omemo2KeychainUsesAccessGroup(environment: partial))
        }
        XCTAssertTrue(CredentialsManager.omemo2KeychainUsesAccessGroup(environment: [:]))
    }

    func testRealKeychainRoundTripIsDeviceOnlyAndPreservesLegacyCredentials() throws {
        let isolated = HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment)
        XCTAssertTrue(isolated, "Run hosted tests with both TEST_RUNNER_XABBER isolation flags")
        guard isolated else { return }
        let owner = "omemo2-state-test-\(UUID().uuidString)@example.test"
        let credentials = CredentialsManager.shared
        let legacyPublic = Data(repeating: 0x15, count: 33)
        let legacyPrivate = Data(repeating: 0x27, count: 32)
        credentials.setIdentityKey(for: owner, publicKey: legacyPublic, privateKey: legacyPrivate)
        defer {
            try? credentials.removeOMEMO2State(for: owner)
            credentials.removeIdentityKey(for: owner)
        }
        XCTAssertNil(try credentials.getOMEMO2State(for: owner))
        try credentials.setOMEMO2State(Data([1, 2, 3]), for: owner)
        XCTAssertEqual(try credentials.getOMEMO2State(for: owner), Data([1, 2, 3]))
        try credentials.setOMEMO2State(Data([4, 5]), for: owner)
        XCTAssertEqual(try credentials.getOMEMO2State(for: owner), Data([4, 5]))
        XCTAssertEqual(credentials.getIdentityKeyPublicKey(for: owner), legacyPublic)
        XCTAssertEqual(credentials.getIdentityKeyPrivateKey(for: owner), legacyPrivate)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: CredentialsManager.uniqueServiceName(),
                                    kSecAttrAccount as String: [owner, XabberOMEMO2Storage.profile, CredentialsManager.omemo2StateNamespace].prp(),
                                    kSecReturnAttributes as String: true]
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributes), errSecSuccess)
        XCTAssertEqual((attributes as? [String: Any])?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try credentials.removeOMEMO2State(for: owner)
        XCTAssertNil(try credentials.getOMEMO2State(for: owner))
        XCTAssertEqual(credentials.getIdentityKeyPrivateKey(for: owner), legacyPrivate)
    }

    private final class MemoryPersistence: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var legacy: (publicKey: Data, privateKey: Data)?
        var legacyDevice: Int?
        var failWrites = false
        var writes = 0
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
            writes += 1
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) -> (publicKey: Data, privateKey: Data)? { legacy }
        func legacyDeviceID(owner: String) -> Int? { legacyDevice }
    }

    func testBackendCutoverCreatesFreshIdentityAndIsIdempotent() throws {
        let context = try OMEMO2Context(error: ())
        let legacyIdentity = try context.generateIdentity()
        let persistence = MemoryPersistence()
        persistence.legacy = (Data([5]) + legacyIdentity.fingerprintPublicKey, legacyIdentity.privateKey)
        persistence.legacyDevice = 42
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)

        let first = try store.prepare(deviceID: 42, preKeyCount: 3)
        let persisted = persistence.records
        let second = try store.prepare(deviceID: 42, preKeyCount: 3)

        XCTAssertNotEqual(first.identityKey, legacyIdentity.publicKey)
        XCTAssertNotEqual(first.fingerprintPublicKey, legacyIdentity.fingerprintPublicKey)
        XCTAssertEqual(first.deviceID, 42)
        XCTAssertEqual(first.preKeys.count, 3)
        XCTAssertEqual(second.signedPreKey, first.signedPreKey)
        XCTAssertEqual(persistence.records, persisted)
        XCTAssertEqual(persistence.writes, 1)
        XCTAssertEqual(persistence.legacy?.publicKey, Data([5]) + legacyIdentity.fingerprintPublicKey)
    }

    func testMismatchedLegacyIdentityCannotBeImportedIntoNativeState() throws {
        let context = try OMEMO2Context(error: ())
        let identity = try context.generateIdentity()
        let differentIdentity = try context.generateIdentity()
        let persistence = MemoryPersistence()
        persistence.legacy = (Data([5]) + differentIdentity.fingerprintPublicKey, identity.privateKey)
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)

        let bundle = try store.prepare(deviceID: 42, preKeyCount: 2)
        XCTAssertNotEqual(bundle.identityKey, identity.publicKey)
        XCTAssertNotEqual(bundle.identityKey, differentIdentity.publicKey)
        XCTAssertEqual(persistence.writes, 1)
    }

    func testLegacyDeviceWithoutPrivateIdentityDoesNotPreventFreshNativeState() throws {
        let persistence = MemoryPersistence()
        persistence.legacyDevice = 42
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)

        let bundle = try store.prepare(deviceID: 43, preKeyCount: 2)
        XCTAssertEqual(bundle.deviceID, 43)
        XCTAssertEqual(bundle.identityKey.count, 32)
        XCTAssertEqual(persistence.writes, 1)
    }

    func testRepeatedKEXContinuesOneSessionAndConsumesTheOPKOnce() throws {
        let (alice, bob, persistence, bundle) = try fixture()
        let plaintext = Data(repeating: 0x42, count: 48)
        try alice.initiateSession(jid: "bob@example.test", deviceID: bundle.deviceID, bundle: selectedBundle(bundle))
        let first = try alice.encrypt(plaintext, jid: "bob@example.test", deviceID: bundle.deviceID)
        let second = try alice.encrypt(plaintext, jid: "bob@example.test", deviceID: bundle.deviceID)
        XCTAssertEqual(first.counter, 0)
        XCTAssertEqual(second.counter, 1)
        XCTAssertEqual(first.ephemeralKey, second.ephemeralKey)

        XCTAssertEqual(try bob.decrypt(first, jid: "alice@example.test", deviceID: 1), plaintext)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 2)
        let freshBob = try XabberOMEMO2Storage(owner: "bob@example.test", persistence: persistence)
        XCTAssertEqual(try freshBob.decrypt(second, jid: "alice@example.test", deviceID: 1), plaintext)
        XCTAssertEqual(try freshBob.localBundle().preKeys.count, 2)
        XCTAssertThrowsError(try freshBob.decrypt(first, jid: "alice@example.test", deviceID: 1))
    }

    func testFailedPersistenceDoesNotConsumeOPKOrAcceptTheMessage() throws {
        let (alice, bob, persistence, bundle) = try fixture()
        let plaintext = Data(repeating: 0x35, count: 48)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(bundle))
        let ciphertext = try alice.encrypt(plaintext, jid: "bob@example.test", deviceID: 2)
        let before = persistence.records["bob@example.test"]
        persistence.failWrites = true

        XCTAssertThrowsError(try bob.decrypt(ciphertext, jid: "alice@example.test", deviceID: 1))
        XCTAssertEqual(persistence.records["bob@example.test"], before)
        persistence.failWrites = false
        XCTAssertEqual(try bob.localBundle().preKeys.count, 3)
        XCTAssertFalse(try bob.sessionExists(jid: "alice@example.test", deviceID: 1))
        XCTAssertEqual(try bob.decrypt(ciphertext, jid: "alice@example.test", deviceID: 1), plaintext)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 2)
    }

    func testFailedOutgoingPersistenceDoesNotAdvanceTheCounter() throws {
        let (alice, _, persistence, bundle) = try fixture()
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(bundle))
        persistence.failWrites = true
        XCTAssertThrowsError(try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2))
        persistence.failWrites = false
        XCTAssertEqual(try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2).counter, 0)
    }

    func testAuthenticationFailureLeavesSessionAndPreKeysUnchanged() throws {
        let (alice, bob, persistence, bundle) = try fixture()
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(bundle))
        let ciphertext = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        var damaged = ciphertext.data
        damaged[damaged.count - 1] ^= 1
        let parsed = try OMEMO2Ciphertext(data: damaged, keyExchange: true)
        let before = persistence.records["bob@example.test"]

        XCTAssertThrowsError(try bob.decrypt(parsed, jid: "alice@example.test", deviceID: 1))
        XCTAssertEqual(persistence.records["bob@example.test"], before)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 3)
    }

    func testOuterPayloadValidationFailureRollsBackRatchetAndOPKConsumption() throws {
        let (alice, bob, persistence, bundle) = try fixture()
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(bundle))
        let ciphertext = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        let before = persistence.records["bob@example.test"]

        XCTAssertThrowsError(try bob.decrypt(ciphertext, jid: "alice@example.test", deviceID: 1, validating: { _ in
            throw OMEMO2StorageError.invalidState
        }))
        XCTAssertEqual(persistence.records["bob@example.test"], before)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 3)
        XCTAssertEqual(try bob.decrypt(ciphertext, jid: "alice@example.test", deviceID: 1), Data(repeating: 1, count: 48))
    }

    func testNewEKWithConsumedOPKIsReceiveOnlyAndKeepsTheOutboundSession() throws {
        let (alice, bob, _, bundle) = try fixture()
        let peerBundle = try selectedBundle(bundle)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: peerBundle)
        let first = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(first, jid: "alice@example.test", deviceID: 1)
        _ = try bob.encrypt(Data(repeating: 0, count: 32), jid: "alice@example.test", deviceID: 1)
        XCTAssertTrue(try bob.pendingControlAddresses().isEmpty)

        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: peerBundle)
        let second = try alice.encrypt(Data(repeating: 2, count: 48), jid: "bob@example.test", deviceID: 2)
        let repeated = try alice.encrypt(Data(repeating: 3, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(second, jid: "alice@example.test", deviceID: 1)
        _ = try bob.decrypt(repeated, jid: "alice@example.test", deviceID: 1)

        XCTAssertNotEqual(first.ephemeralKey, second.ephemeralKey)
        let current = try XCTUnwrap(bob.sessionMetadata(jid: "alice@example.test", deviceID: 1))
        let duplicate = try XCTUnwrap(bob.sessionMetadata(jid: "alice@example.test", deviceID: 1,
                                                        ephemeralKey: second.ephemeralKey))
        XCTAssertEqual(current.ephemeralKey, first.ephemeralKey)
        XCTAssertFalse(current.receiveOnly)
        XCTAssertTrue(duplicate.receiveOnly)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 2)
        XCTAssertTrue(try bob.pendingControlAddresses().isEmpty)
    }

    func testDelayedKEXUsesItsArchivedEKAfterANewerSessionWasAccepted() throws {
        let (alice, bob, _, bundle) = try fixture()
        let firstPeerBundle = try selectedBundle(bundle)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: firstPeerBundle)
        let first = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        let delayed = try alice.encrypt(Data(repeating: 2, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(first, jid: "alice@example.test", deviceID: 1)
        let anotherPreKey = try XCTUnwrap(bundle.preKeys.last)
        let secondPeerBundle = try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                                                signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                                                preKey: anotherPreKey.publicKey, preKeyID: anotherPreKey.id)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: secondPeerBundle)
        let newer = try alice.encrypt(Data(repeating: 3, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(newer, jid: "alice@example.test", deviceID: 1)
        _ = try bob.encrypt(Data(repeating: 0, count: 32), jid: "alice@example.test", deviceID: 1)

        XCTAssertEqual(try bob.decrypt(delayed, jid: "alice@example.test", deviceID: 1), Data(repeating: 2, count: 48))
        XCTAssertEqual(try bob.sessionMetadata(jid: "alice@example.test", deviceID: 1)?.ephemeralKey, newer.ephemeralKey)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 1)
        XCTAssertTrue(try bob.pendingControlAddresses().isEmpty)
    }

    func testControlRetryMarkerIsDurableAndClearedOnlyAfterSuccessfulSendCommit() throws {
        let (alice, bob, persistence, bundle) = try fixture()
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(bundle))
        let ciphertext = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(ciphertext, jid: "alice@example.test", deviceID: 1)
        XCTAssertEqual(try bob.pendingControlAddresses(), [OMEMO2PeerAddress(jid: "alice@example.test", deviceID: 1)])
        persistence.failWrites = true
        XCTAssertThrowsError(try bob.encrypt(Data(repeating: 0, count: 32), jid: "alice@example.test", deviceID: 1))
        persistence.failWrites = false
        XCTAssertEqual(try bob.pendingControlAddresses().count, 1)
        _ = try bob.encrypt(Data(repeating: 0, count: 32), jid: "alice@example.test", deviceID: 1)
        XCTAssertTrue(try bob.pendingControlAddresses().isEmpty)
    }

    func testSignedPreKeyRotatesWeeklyAndThePreviousKeyAcceptsDelayedKEX() throws {
        let persistence = MemoryPersistence()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let alice = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        let bob = try XabberOMEMO2Storage(owner: "bob@example.test", persistence: persistence, now: { now })
        _ = try alice.prepare(deviceID: 1, preKeyCount: 3)
        let before = try bob.prepare(deviceID: 2, preKeyCount: 3)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(before))
        let delayed = try alice.encrypt(Data(repeating: 7, count: 48), jid: "bob@example.test", deviceID: 2)

        now.addTimeInterval(7 * 24 * 60 * 60)
        let after = try bob.prepare(deviceID: 2, preKeyCount: 3)
        XCTAssertEqual(after.signedPreKeyID, before.signedPreKeyID + 1)
        XCTAssertNotEqual(after.signedPreKey, before.signedPreKey)
        XCTAssertEqual(after.identityKey, before.identityKey)
        XCTAssertEqual(try bob.decrypt(delayed, jid: "alice@example.test", deviceID: 1), Data(repeating: 7, count: 48))
    }

    func testFinishCatchUpDeletesConsumedPrivatePreKeysAndKeepsSessions() throws {
        let (alice, bob, _, bundle) = try fixture()
        let chosen = try selectedBundle(bundle)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: chosen)
        let first = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        let repeated = try alice.encrypt(Data(repeating: 2, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(first, jid: "alice@example.test", deviceID: 1)
        try bob.finishCatchUp()

        XCTAssertEqual(try bob.decrypt(repeated, jid: "alice@example.test", deviceID: 1), Data(repeating: 2, count: 48))
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: chosen)
        let duplicate = try alice.encrypt(Data(repeating: 3, count: 48), jid: "bob@example.test", deviceID: 2)
        XCTAssertThrowsError(try bob.decrypt(duplicate, jid: "alice@example.test", deviceID: 1))
        XCTAssertEqual(try bob.localBundle().preKeys.count, 2)
    }

    func testFirstMessageAtCounter53ForANewRatchetSchedulesOneHeartbeat() throws {
        let (alice, bob, _, bundle) = try fixture()
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: selectedBundle(bundle))
        let first = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(first, jid: "alice@example.test", deviceID: 1)
        let ack = try bob.encrypt(Data(repeating: 0, count: 32), jid: "alice@example.test", deviceID: 1)
        _ = try alice.decrypt(ack, jid: "bob@example.test", deviceID: 2)
        var advanced: OMEMO2Ciphertext?
        for _ in 0..<54 { advanced = try alice.encrypt(Data(repeating: 2, count: 48), jid: "bob@example.test", deviceID: 2) }
        let counter53 = try XCTUnwrap(advanced)
        XCTAssertEqual(counter53.counter, 53)
        XCTAssertFalse(counter53.isKeyExchange)

        _ = try bob.decrypt(counter53, jid: "alice@example.test", deviceID: 1)
        XCTAssertEqual(try bob.pendingControlAddresses().count, 1)
        _ = try bob.encrypt(Data(repeating: 0, count: 32), jid: "alice@example.test", deviceID: 1)
        XCTAssertTrue(try bob.pendingControlAddresses().isEmpty)
        let later = try alice.encrypt(Data(repeating: 3, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(later, jid: "alice@example.test", deviceID: 1)
        XCTAssertTrue(try bob.pendingControlAddresses().isEmpty)
    }

    func testUnknownProfileOrMalformedStateFailsClosed() throws {
        let persistence = MemoryPersistence()
        persistence.records["alice@example.test"] = Data("legacy Signal protobuf".utf8)
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        XCTAssertThrowsError(try store.prepare(deviceID: 1, preKeyCount: 3))
        XCTAssertEqual(persistence.writes, 0)
    }

    func testStateProfileVersionAndOwnerAreNeverGuessedOrConverted() throws {
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        _ = try store.prepare(deviceID: 1, preKeyCount: 3)
        let original = try XCTUnwrap(persistence.records["alice@example.test"])
        let source = try XCTUnwrap(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        let writes = persistence.writes
        for (field, value) in [("profile", "legacy-signal" as Any), ("version", 99 as Any), ("owner", "another@example.test" as Any)] {
            var invalid = source
            invalid[field] = value
            persistence.records["alice@example.test"] = try PropertyListSerialization.data(fromPropertyList: invalid, format: .binary, options: 0)
            XCTAssertThrowsError(try store.prepare(deviceID: 1, preKeyCount: 3))
            XCTAssertEqual(persistence.writes, writes)
        }
    }

    func testOldSessionRetentionIsBoundedAndPreservesTheCurrentSession() throws {
        let (alice, _, _, bundle) = try fixture()
        let peerBundle = try selectedBundle(bundle)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: peerBundle)
        let oldest = try XCTUnwrap(alice.sessionMetadata(jid: "bob@example.test", deviceID: 2)).ephemeralKey
        for _ in 0..<XabberOMEMO2Storage.maximumSessionsPerPeer {
            try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: peerBundle)
        }

        XCTAssertNil(try alice.sessionMetadata(jid: "bob@example.test", deviceID: 2, ephemeralKey: oldest))
        XCTAssertNotNil(try alice.sessionMetadata(jid: "bob@example.test", deviceID: 2))
        XCTAssertNoThrow(try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2))
    }

    func testReplenishmentNeverReusesAConsumedIDAndKeepsTheIdentity() throws {
        let (alice, bob, _, bundle) = try fixture()
        let chosen = try selectedBundle(bundle)
        try alice.initiateSession(jid: "bob@example.test", deviceID: 2, bundle: chosen)
        let ciphertext = try alice.encrypt(Data(repeating: 1, count: 48), jid: "bob@example.test", deviceID: 2)
        _ = try bob.decrypt(ciphertext, jid: "alice@example.test", deviceID: 1)

        let replenished = try bob.replenishPreKeys(minimumCount: 3)
        XCTAssertEqual(replenished.preKeys.count, 3)
        XCTAssertFalse(replenished.preKeys.contains { $0.id == chosen.preKeyID })
        XCTAssertEqual(replenished.identityKey, bundle.identityKey)
        XCTAssertEqual(replenished.signedPreKey, bundle.signedPreKey)
    }

    func testRealmMigrationMarksLegacyRecordsAndPreservesTheirBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.realm")
        let record = Data([0x08, 0x03, 0x12, 0x20])
        let primary = SessionRecordStorageItem.genPrimary(owner: "alice@example.test", jid: "bob@example.test", deviceId: 2)
        try autoreleasepool {
            let old = try Realm(configuration: Realm.Configuration(fileURL: url, schemaVersion: 21, objectTypes: [SessionRecordStorageItem.self]))
            let row = SessionRecordStorageItem()
            row.primary = primary
            row.record = record
            row.profile_ = ""
            try old.write { old.add(row) }
        }
        var configuration = makeRealmMigrationConfiguration(scheme: XabberRealmSchema.current)
        configuration.fileURL = url
        configuration.objectTypes = [SessionRecordStorageItem.self]
        let migrated = try Realm(configuration: configuration)
        let row = try XCTUnwrap(migrated.object(ofType: SessionRecordStorageItem.self, forPrimaryKey: primary))

        XCTAssertEqual(row.record, record)
        XCTAssertEqual(row.profile_, SessionRecordStorageItem.legacyProfile)
    }

    func testBindingExistingDeviceWritesNoCredentialsAndRejectsInvalidIDs() throws {
        try withLegacyFixture { owner, _ in
            let store = XabberAxolotlStorage(withOwner: owner)
            try store.bindExistingDevice(deviceID: 42)
            XCTAssertEqual(store.localDeviceId(), 42)
            XCTAssertNil(CredentialsManager.shared.getDeviceId(for: owner))
            XCTAssertNil(CredentialsManager.shared.getIdentityKeyPrivateKey(for: owner))
            for id in [0, -1, Int(Int32.max) + 1] {
                XCTAssertThrowsError(try store.bindExistingDevice(deviceID: id))
                XCTAssertEqual(store.localDeviceId(), 42)
            }
        }
    }

    private func withLegacyFixture<T>(_ operation: (String, Realm) throws -> T) throws -> T {
        let owner = "legacy-state-test-\(UUID().uuidString)@example.test"
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString,
                                                                         objectTypes: [SignalDeviceStorageItem.self, SignalIdentityStorageItem.self,
                                                                                       SignalPreKeysStorageItem.self, SessionRecordStorageItem.self,
                                                                                       SignalTrustedIdentityStoreageItem.self])
        defer {
            Realm.Configuration.defaultConfiguration = previous
            try? CredentialsManager.shared.removeOMEMO2State(for: owner)
            CredentialsManager.shared.removeIdentityKey(for: owner)
            CredentialsManager.shared.removeDeviceId(for: owner)
            CredentialsManager.shared.removePreKey(for: owner, id: 1)
            CredentialsManager.shared.removeSignedPreKey(for: owner, id: 1)
        }
        return try operation(owner, WRealm.safe())
    }

    private func fixture() throws -> (XabberOMEMO2Storage, XabberOMEMO2Storage, MemoryPersistence, OMEMO2LocalBundle) {
        let persistence = MemoryPersistence()
        let alice = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        let bob = try XabberOMEMO2Storage(owner: "bob@example.test", persistence: persistence)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 3)
        let bundle = try bob.prepare(deviceID: 2, preKeyCount: 3)
        return (alice, bob, persistence, bundle)
    }

    private func selectedBundle(_ bundle: OMEMO2LocalBundle) throws -> OMEMO2Bundle {
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        return try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                                signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                                preKey: preKey.publicKey, preKeyID: preKey.id)
    }
}
