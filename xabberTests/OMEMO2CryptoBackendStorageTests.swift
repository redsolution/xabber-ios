import CryptoKit
import Foundation
import Security
import XabberCryptoSwift
import XCTest
@testable import xabber

final class OMEMO2CryptoBackendStorageTests: XCTestCase {
    private final class Persistence: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var retiredData: Data?
        var retiredReads = 0
        var failRetiredReads = false
        var nativeMarked = false
        var legacyReads = 0
        var failWrites = false
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func nativePreparationExists(owner: String) throws -> Bool { nativeMarked }
        func retiredOptOutRecords(owner: String) throws -> [String: OMEMO2OptOutRecord]? {
            retiredReads += 1
            if failRetiredReads { throw OMEMO2StorageError.persistenceFailed }
            guard let retiredData else { return nil }
            return try XabberOMEMO2Storage.decodeRetiredOptOutRecords(retiredData, owner: owner)
        }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? {
            legacyReads += 1
            throw OMEMO2StorageError.identityMismatch
        }
        func legacyDeviceID(owner: String) -> Int? { legacyReads += 1; return 999 }
    }

    func testFreshSeedPreparationNeverReadsOldBackendMaterialAndRestartsWithoutRotation() throws {
        let persistence = Persistence()
        let owner = "fresh-seed@example.test"
        let first = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let bundle = try first.prepare(deviceID: 42, preKeyCount: 2)
        let saved = persistence.records[owner]
        let seed = try first.identity().privateKey
        let independent = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

        XCTAssertEqual(independent.publicKey.rawRepresentation, bundle.identityKey)
        XCTAssertTrue(independent.publicKey.isValidSignature(bundle.signature, for: bundle.signedPreKey))
        XCTAssertEqual(persistence.legacyReads, 0)
        let restarted = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        XCTAssertEqual(try restarted.prepare(deviceID: 42, preKeyCount: 2).identityKey, bundle.identityKey)
        XCTAssertEqual(persistence.records[owner], saved)
        XCTAssertEqual(try restarted.identity().privateKey, seed)
    }

    func testFailedFreshIdentityWriteDoesNotExposePreparedState() throws {
        let persistence = Persistence()
        persistence.failWrites = true
        let storage = try XabberOMEMO2Storage(owner: "failed-write@example.test", persistence: persistence)

        XCTAssertThrowsError(try storage.prepare(deviceID: 42, preKeyCount: 1))
        XCTAssertThrowsError(try storage.identity())
        XCTAssertTrue(persistence.records.isEmpty)
        XCTAssertEqual(persistence.legacyReads, 0)
    }

    func testMissingOrCorruptNewStateNeverSelectsLegacyIdentity() throws {
        let persistence = Persistence()
        let owner = "invalid-state@example.test"
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        var fallbackReads = 0
        let fallback: () -> Data? = { fallbackReads += 1; return Data(repeating: 1, count: 32) }

        XCTAssertThrowsError(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: owner, storage: storage,
                                                                                   legacyPrivateKey: fallback))
        persistence.records[owner] = Data("invalid native aggregate".utf8)
        XCTAssertThrowsError(try storage.prepare(deviceID: 42, preKeyCount: 1))
        XCTAssertThrowsError(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: owner, storage: storage,
                                                                                   legacyPrivateKey: fallback))
        XCTAssertEqual(fallbackReads, 0)
        XCTAssertEqual(persistence.legacyReads, 0)
    }

    func testNativeStateRejectsAnOldBackendVersionWithoutReplacingIt() throws {
        let persistence = Persistence()
        let owner = "old-version@example.test"
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        _ = try storage.prepare(deviceID: 42, preKeyCount: 1)
        var state = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(persistence.records[owner]),
                                                                        format: nil) as? [String: Any])
        state["version"] = 1
        let old = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        persistence.records[owner] = old

        XCTAssertThrowsError(try storage.prepare(deviceID: 42, preKeyCount: 1))
        XCTAssertEqual(persistence.records[owner], old)
        XCTAssertEqual(persistence.legacyReads, 0)
    }

    func testFirstNativePacketAtomicallyBindsThePreparedSlotAndSurvivesRestart() throws {
        let persistence = Persistence()
        let alice = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        let bob = try XabberOMEMO2Storage(owner: "bob@example.test", persistence: persistence)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 2)
        let bobBundle = try bob.prepare(deviceID: 2, preKeyCount: 2)
        try alice.initiateSession(jid: bob.owner, deviceID: 2, bundle: selectedBundle(bobBundle))
        let material = Data(repeating: 0x41, count: 48)

        let first = try alice.encrypt(material, jid: bob.owner, deviceID: 2)
        XCTAssertEqual(first.counter, 0)
        let aliceRestart = try XabberOMEMO2Storage(owner: alice.owner, persistence: persistence)
        XCTAssertEqual(try aliceRestart.sessionMetadata(jid: bob.owner, deviceID: 2)?.ephemeralKey, first.ephemeralKey)
        XCTAssertEqual(try bob.decrypt(first, jid: alice.owner, deviceID: 1), material)
        let second = try aliceRestart.encrypt(material, jid: bob.owner, deviceID: 2)
        XCTAssertEqual(second.ephemeralKey, first.ephemeralKey)
        XCTAssertEqual(second.counter, 1)
        let bobRestart = try XabberOMEMO2Storage(owner: bob.owner, persistence: persistence)
        XCTAssertEqual(try bobRestart.decrypt(second, jid: alice.owner, deviceID: 1), material)
        XCTAssertEqual(try bobRestart.localBundle().preKeys.count, 1)
    }

    func testLegalLongOwnerAndPeerJIDsEncryptDecryptAndRestoreWithBoundNativeScope() throws {
        let owner = String(repeating: "a", count: 560) + "@example.test"
        let peer = String(repeating: "b", count: 560) + "@example.test"
        XCTAssertEqual(try OMEMO2OptOutPolicy.bareJID(owner), owner)
        XCTAssertEqual(try OMEMO2OptOutPolicy.bareJID(peer), peer)
        let persistence = Persistence()
        let alice = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let bob = try XabberOMEMO2Storage(owner: peer, persistence: persistence)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 1)
        let bobBundle = try bob.prepare(deviceID: 2, preKeyCount: 1)
        try alice.initiateSession(jid: peer, deviceID: 2, bundle: selectedBundle(bobBundle))
        let material = Data(repeating: 0x41, count: 48)

        let first = try alice.encrypt(material, jid: peer, deviceID: 2)
        XCTAssertEqual(try bob.decrypt(first, jid: owner, deviceID: 1), material)
        let aliceRestart = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        XCTAssertEqual(try aliceRestart.sessionMetadata(jid: peer, deviceID: 2)?.remoteIdentityKey, bobBundle.identityKey)
        let second = try aliceRestart.encrypt(material, jid: peer, deviceID: 2)
        let bobRestart = try XabberOMEMO2Storage(owner: peer, persistence: persistence)
        XCTAssertEqual(try bobRestart.decrypt(second, jid: owner, deviceID: 1), material)
    }

    func testStoredSnapshotCannotBeReassignedToAnotherPeerSlot() throws {
        let persistence = Persistence()
        let alice = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        let bob = try XabberOMEMO2Storage(owner: "bob@example.test", persistence: persistence)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 1)
        let bobBundle = try bob.prepare(deviceID: 2, preKeyCount: 1)
        try alice.initiateSession(jid: bob.owner, deviceID: 2, bundle: selectedBundle(bobBundle))
        let first = try alice.encrypt(Data(repeating: 0x41, count: 48), jid: bob.owner, deviceID: 2)
        var state = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(persistence.records[alice.owner]),
                                                                        format: nil) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: [String: Any]])
        var session = try XCTUnwrap(sessions.values.first)
        let peer = "charlie@example.test"
        let addressKey = "\(peer.utf8.count):\(peer):2"
        let sessionKey = addressKey + ":" + (try XCTUnwrap(first.ephemeralKey)).base64EncodedString()
        session["address"] = ["jid": peer, "deviceID": 2]
        state["sessions"] = [sessionKey: session]
        state["currentSessions"] = [addressKey: sessionKey]
        let reassigned = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        persistence.records[alice.owner] = reassigned

        XCTAssertThrowsError(try alice.sessionMetadata(jid: peer, deviceID: 2))
        XCTAssertThrowsError(try alice.encrypt(Data(repeating: 0x41, count: 48), jid: peer, deviceID: 2))
        XCTAssertEqual(persistence.records[alice.owner], reassigned)
    }

    func testRepeatedKeyExchangeWithAnEquivalentEphemeralEncodingCannotReplayOrConsumeAnotherPreKey() throws {
        let persistence = Persistence()
        let alice = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        let bob = try XabberOMEMO2Storage(owner: "bob@example.test", persistence: persistence)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 2)
        let bobBundle = try bob.prepare(deviceID: 2, preKeyCount: 2)
        try alice.initiateSession(jid: bob.owner, deviceID: 2, bundle: selectedBundle(bobBundle))
        let plaintext = Data(repeating: 0x41, count: 48)
        let first = try alice.encrypt(plaintext, jid: bob.owner, deviceID: 2)
        XCTAssertEqual(try bob.decrypt(first, jid: alice.owner, deviceID: 1), plaintext)
        let before = persistence.records[bob.owner]
        guard case .keyExchange(let exchange) = try OMEMOEnvelope(data: first.data, keyExchange: true) else {
            return XCTFail("First packet must carry a key exchange")
        }
        var aliasedEphemeral = exchange.ephemeralKey
        aliasedEphemeral[31] ^= 0x80
        // Outer EK bytes are not independently MAC-bound. Preserve the exact
        // authenticated inner packet while changing only its RFC7748 alias.
        let alias = try OMEMOKeyExchange(preKeyID: exchange.preKeyID, signedPreKeyID: exchange.signedPreKeyID,
                                         identityKey: exchange.identityKey, ephemeralKey: aliasedEphemeral,
                                         message: exchange.message)
        let ciphertext = try OMEMO2Ciphertext(data: alias.serializedData(), keyExchange: true)

        XCTAssertThrowsError(try bob.decrypt(ciphertext, jid: alice.owner, deviceID: 1))
        XCTAssertEqual(persistence.records[bob.owner], before)
        XCTAssertEqual(try bob.localBundle().preKeys.count, 1)
        XCTAssertEqual(try bob.sessionMetadata(jid: alice.owner, deviceID: 1, ephemeralKey: aliasedEphemeral)?.ephemeralKey,
                       first.ephemeralKey)
    }

    func testEphemeralSlotCanonicalizationAppliesRFC7748HighBitMaskAndPrimeReduction() {
        let zero = Data(repeating: 0, count: 32)
        var highBitZero = zero
        highBitZero[31] = 0x80
        XCTAssertEqual(XabberOMEMO2Storage.canonicalEphemeralKey(highBitZero), zero)
        for offset in 0...18 {
            var encoded = Data([UInt8(0xED + offset)]) + Data(repeating: 0xFF, count: 30) + Data([0x7F])
            let reduced = Data([UInt8(offset)]) + Data(repeating: 0, count: 31)
            XCTAssertEqual(XabberOMEMO2Storage.canonicalEphemeralKey(encoded), reduced)
            encoded[31] |= 0x80
            XCTAssertEqual(XabberOMEMO2Storage.canonicalEphemeralKey(encoded), reduced)
        }
        let belowPrime = Data([0xEC]) + Data(repeating: 0xFF, count: 30) + Data([0x7F])
        XCTAssertEqual(XabberOMEMO2Storage.canonicalEphemeralKey(belowPrime), belowPrime)
        XCTAssertEqual(XabberOMEMO2Storage.canonicalEphemeralKey(Data([1])), Data([1]))
    }

    func testNativeCredentialNamespaceDoesNotLoadOrOverwriteOldAggregate() throws {
        let isolated = HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment)
        XCTAssertTrue(isolated)
        guard isolated else { return }
        let owner = "backend-namespace-\(UUID().uuidString)@example.test"
        let credentials = CredentialsManager.shared
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialsManager.uniqueServiceName(),
            kSecAttrAccount as String: [owner, XabberOMEMO2Storage.profile, "state-v1"].prp()
        ]
        let legacy = try retiredPolicy(owner: owner, records: policyRecords())
        var oldItem = query
        oldItem[kSecValueData as String] = legacy
        oldItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(oldItem as CFDictionary, nil), errSecSuccess)
        defer {
            SecItemDelete(query as CFDictionary)
            try? credentials.removeOMEMO2State(for: owner)
        }

        XCTAssertNil(try credentials.getOMEMO2State(for: owner))
        let storage = try XabberOMEMO2Storage(owner: owner)
        _ = try storage.prepare(deviceID: 42, preKeyCount: 1)
        XCTAssertNotEqual(try credentials.getOMEMO2State(for: owner), legacy)
        XCTAssertEqual(try storage.optOutDecision(jid: "pending@example.test"), .pending)
        XCTAssertEqual(try storage.optOutDecision(jid: "plaintext@example.test"), .plaintext)
        XCTAssertEqual(try storage.optOutDecision(jid: "omemo@example.test"), .omemo)
        var oldRead = query
        oldRead[kSecReturnData as String] = true
        var value: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(oldRead as CFDictionary, &value), errSecSuccess)
        XCTAssertEqual(value as? Data, legacy)
        try credentials.removeOMEMO2State(for: owner)
        XCTAssertNil(try credentials.getOMEMO2State(for: owner))
        XCTAssertEqual(SecItemCopyMatching(oldRead as CFDictionary, &value), errSecItemNotFound)
    }

    func testFreshNativeCutoverPreservesAllProtectedOptOutDecisionsWithoutDecodingOldCryptoFields() throws {
        let owner = "policy-owner@example.test"
        let persistence = Persistence()
        let decisions = policyRecords()
        persistence.retiredData = try retiredPolicy(owner: owner, records: decisions)
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)

        _ = try storage.prepare(deviceID: 42, preKeyCount: 1)
        for record in decisions.values {
            XCTAssertEqual(try storage.optOutDecision(jid: record.jid), record.decision)
            let imported = try XCTUnwrap(try storage.optOutRecords().first { $0.jid == record.jid })
            XCTAssertEqual(imported.requestFingerprint, record.requestFingerprint)
            XCTAssertEqual(imported.protectedRequestDate, record.protectedRequestDate)
            XCTAssertEqual(imported.resolvedWatermark, record.resolvedWatermark)
            XCTAssertEqual(imported.updatedAt, record.updatedAt)
            XCTAssertEqual(imported.reason, record.reason)
        }
        XCTAssertThrowsError(try storage.encrypt(Data(repeating: 1, count: 48), jid: "pending@example.test", deviceID: 2)) {
            guard case OMEMO2StorageError.pendingOptOut = $0 else { return XCTFail("Pending policy must still block sends") }
        }
        XCTAssertEqual(persistence.legacyReads, 0)
        XCTAssertEqual(persistence.retiredReads, 1)
        try storage.resolveOptOut(jid: "pending@example.test", decision: .omemo, at: Date(timeIntervalSince1970: 100))
        persistence.retiredData = Data("retired item no longer available".utf8)
        let restarted = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        _ = try restarted.prepare(deviceID: 42, preKeyCount: 1)
        XCTAssertEqual(try restarted.optOutDecision(jid: "pending@example.test"), .omemo)
        XCTAssertEqual(persistence.retiredReads, 1, "Native decisions remain authoritative after the one-time cutover")
    }

    func testRetiredPendingDecisionRemainsAuthoritativeBeforeNativePreparation() throws {
        let owner = "policy-startup@example.test"
        let persistence = Persistence()
        persistence.retiredData = try retiredPolicy(owner: owner, records: policyRecords())
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)

        XCTAssertEqual(try storage.optOutDecision(jid: "pending@example.test"), .pending)
        XCTAssertFalse(OMEMO2OptOutPolicy.allowsMessage(owner: owner, jid: "pending@example.test", storage: storage))
        XCTAssertEqual(try storage.optOutRecords().count, 3)
        XCTAssertTrue(persistence.records.isEmpty)
        _ = try storage.prepare(deviceID: 42, preKeyCount: 1)
        XCTAssertEqual(try storage.optOutDecision(jid: "pending@example.test"), .pending)
        persistence.retiredData = Data("old item becomes corrupt after cutover".utf8)
        XCTAssertEqual(try storage.optOutDecision(jid: "pending@example.test"), .pending)
    }

    func testFailedNativeSaveLeavesRetiredPolicyUntouchedAndRetriesTheWholeCutover() throws {
        let owner = "policy-rollback@example.test"
        let persistence = Persistence()
        let retired = try retiredPolicy(owner: owner, records: policyRecords())
        persistence.retiredData = retired
        persistence.failWrites = true
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)

        XCTAssertThrowsError(try storage.prepare(deviceID: 42, preKeyCount: 1))
        XCTAssertTrue(persistence.records.isEmpty)
        XCTAssertEqual(persistence.retiredData, retired)
        XCTAssertThrowsError(try storage.identity())
        persistence.failWrites = false
        _ = try storage.prepare(deviceID: 42, preKeyCount: 1)
        XCTAssertEqual(try storage.optOutDecision(jid: "pending@example.test"), .pending)
        XCTAssertEqual(persistence.retiredData, retired)
        XCTAssertEqual(persistence.legacyReads, 0)
    }

    func testWrongOwnerOrMalformedRetiredPolicyFailsClosedWithoutNativeIdentityCreation() throws {
        let owner = "policy-invalid@example.test"
        var invalidDecision = policyRecords()
        invalidDecision["plaintext@example.test"]?.resolvedWatermark = nil
        let values = [
            Data("malformed retired aggregate".utf8),
            try retiredPolicy(owner: "another-owner@example.test", records: policyRecords()),
            try retiredPolicy(owner: owner, records: invalidDecision),
            try retiredPolicy(owner: owner, records: policyRecords(), version: 2),
            try retiredPolicy(owner: owner, records: policyRecords(), profile: "wrong-profile")
        ]
        for retired in values {
            let persistence = Persistence()
            persistence.retiredData = retired
            let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)

            XCTAssertThrowsError(try storage.optOutDecision(jid: "pending@example.test"))
            XCTAssertThrowsError(try storage.optOutRecords())
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsMessage(owner: owner, jid: "pending@example.test", storage: storage))
            XCTAssertThrowsError(try storage.prepare(deviceID: 42, preKeyCount: 1))
            XCTAssertTrue(persistence.records.isEmpty)
            XCTAssertEqual(persistence.retiredData, retired)
            XCTAssertEqual(persistence.legacyReads, 0)
        }
    }

    func testUnavailableRetiredPolicyCannotBecomePermissiveNativeState() throws {
        let persistence = Persistence()
        persistence.failRetiredReads = true
        let storage = try XabberOMEMO2Storage(owner: "policy-unavailable@example.test", persistence: persistence)

        XCTAssertThrowsError(try storage.optOutDecision(jid: "pending@example.test"))
        XCTAssertThrowsError(try storage.prepare(deviceID: 42, preKeyCount: 1))
        XCTAssertTrue(persistence.records.isEmpty)
        XCTAssertEqual(persistence.legacyReads, 0)
    }

    func testMissingMarkedNativeStateCannotReplaceANewPendingDecisionWithRetiredResolvedOrAbsentPolicy() throws {
        let owner = "marked-native@example.test"
        let peer = "pending@example.test"
        for retiredResolved in [false, true] {
            let persistence = Persistence()
            let date = Date(timeIntervalSince1970: 50)
            let oldRecord = OMEMO2OptOutRecord(jid: peer, decision: .plaintext,
                requestFingerprint: Data(repeating: 9, count: 32), protectedRequestDate: date,
                reason: "old resolved policy", resolvedWatermark: date, updatedAt: date)
            let retired = try retiredPolicy(owner: owner, records: retiredResolved ? [peer: oldRecord] : nil)
            persistence.retiredData = retired
            let alice = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
            let aliceBundle = try alice.prepare(deviceID: 1, preKeyCount: 1)
            persistence.nativeMarked = true
            let bob = try XabberOMEMO2Storage(owner: peer, persistence: Persistence())
            _ = try bob.prepare(deviceID: 2, preKeyCount: 1)
            try bob.initiateSession(jid: owner, deviceID: 1, bundle: selectedBundle(aliceBundle))
            let incoming = try bob.encrypt(Data(repeating: 0x41, count: 48), jid: owner, deviceID: 1)
            _ = try alice.decrypt(incoming, jid: peer, deviceID: 2, recordingOptOut: {
                OMEMO2OptOutRequest(jid: peer, fingerprint: Data(repeating: 0xAB, count: 32),
                    protectedDate: Date(timeIntervalSince1970: 100), reason: "new pending decision", historical: false)
            })
            XCTAssertEqual(try alice.optOutDecision(jid: peer), .pending)
            let retiredReads = persistence.retiredReads
            persistence.records.removeValue(forKey: owner)

            XCTAssertThrowsError(try alice.optOutDecision(jid: peer))
            XCTAssertThrowsError(try alice.optOutRecords())
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsMessage(owner: owner, jid: peer, storage: alice))
            XCTAssertThrowsError(try alice.prepare(deviceID: 1, preKeyCount: 1))
            XCTAssertTrue(persistence.records.isEmpty)
            XCTAssertEqual(persistence.retiredReads, retiredReads)
            XCTAssertEqual(persistence.retiredData, retired)
        }
    }

    func testOlderProtectedAggregateWithoutOptOutRecordsStillAllowsFreshNativeCutover() throws {
        let owner = "policy-absent@example.test"
        let persistence = Persistence()
        persistence.retiredData = try retiredPolicy(owner: owner, records: nil)
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)

        _ = try storage.prepare(deviceID: 42, preKeyCount: 1)
        XCTAssertTrue(try storage.optOutRecords().isEmpty)
        XCTAssertEqual(persistence.legacyReads, 0)
    }

    private func policyRecords() -> [String: OMEMO2OptOutRecord] {
        let date = Date(timeIntervalSince1970: 50)
        return Dictionary(uniqueKeysWithValues: [OMEMO2OptOutPolicy.Decision.pending, .plaintext, .omemo].enumerated().map { index, decision in
            let jid = "\(decision.rawValue)@example.test"
            return (jid, OMEMO2OptOutRecord(jid: jid, decision: decision,
                requestFingerprint: Data(repeating: UInt8(index + 1), count: 32), protectedRequestDate: date,
                reason: "preserved decision", resolvedWatermark: decision == .pending ? nil : date, updatedAt: date))
        })
    }

    private func retiredPolicy(owner: String, records: [String: OMEMO2OptOutRecord]?, version: Int = 1,
                               profile: String = XabberOMEMO2Storage.profile) throws -> Data {
        struct Fixture: Encodable {
            let version: Int
            let profile: String
            let owner: String
            let optOutDecisions: [String: OMEMO2OptOutRecord]?
            // Wrong crypto field types deliberately prove only the domain DTO
            // is decoded. These cannot be parsed as old/new crypto key state.
            let identityPrivateKey = "not a private key"
            let fingerprintPublicKey = "not a public key"
            let signedPreKeyPrivateKey = "not a prekey"
            let sessions = ["invalid-crypto-snapshot": "not a session"]
        }
        return try PropertyListEncoder().encode(Fixture(version: version, profile: profile, owner: owner,
                                                       optOutDecisions: records))
    }

    private func selectedBundle(_ bundle: OMEMO2LocalBundle) throws -> OMEMO2Bundle {
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        return try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                                signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                                preKey: preKey.publicKey, preKeyID: preKey.id)
    }
}
