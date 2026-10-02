import CryptoKit
import Curve25519Kit
import Foundation
import RealmSwift
import SignalProtocolObjC
import XCTest
@testable import xabber

final class OMEMO2IdentityBindingTests: XCTestCase {
    private final class MemoryPersistence: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failReads = false
        func load(owner: String) throws -> Data? {
            if failReads { throw OMEMO2StorageError.persistenceFailed }
            return records[owner]
        }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private let aliceScalar = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    private let bobScalar = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"

    func testWireIdentityMapsToRFC7748CurvePublicKey() throws {
        let wireIdentity = try data(hex: "8120f299c37ae1ca64a179f638a6c6fafde968f1c33705e28c413c7579d9884f")
        let expectedCurveKey = try data(hex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")

        let actual = try Omemo2IdentityRepresentation.curvePublicKey(from: wireIdentity)

        XCTAssertEqual(actual, expectedCurveKey)
    }

    func testEdwardsSignBitDoesNotChangeCurveFingerprint() throws {
        var wireIdentity = try data(hex: "8120f299c37ae1ca64a179f638a6c6fafde968f1c33705e28c413c7579d9884f")
        let first = try Omemo2IdentityRepresentation.curvePublicKey(from: wireIdentity)
        wireIdentity[31] ^= 0x80

        let oppositeSign = try Omemo2IdentityRepresentation.curvePublicKey(from: wireIdentity)

        XCTAssertEqual(first, oppositeSign)
    }

    func testLegacyAndOMEMO2RepresentationsHaveOneCanonicalFingerprint() throws {
        let wireIdentity = try data(hex: "8120f299c37ae1ca64a179f638a6c6fafde968f1c33705e28c413c7579d9884f")
        let rawCurve = try data(hex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let legacy = Data([5]) + rawCurve
        let expectedFingerprint = "8520f009 8930a754 748b7ddc b43ef75a 0dbf3a0d 26381af4 eba4a98e aa9b4e6a"

        XCTAssertEqual(try Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: legacy), rawCurve)
        XCTAssertEqual(try Omemo2IdentityRepresentation.fingerprint(for: legacy), expectedFingerprint)
        XCTAssertEqual(try Omemo2IdentityRepresentation.fingerprint(for: wireIdentity), expectedFingerprint)
        XCTAssertNotEqual(try Omemo2IdentityRepresentation.fingerprint(for: wireIdentity), wireIdentity.formattedFingerprint())
    }

    func testMalformedIdentityEncodingsFailClosed() throws {
        let invalidIdentities = [
            Data(), Data(repeating: 1, count: 31), Data(repeating: 1, count: 34),
            Data([4]) + Data(repeating: 1, count: 32),
            Data(repeating: 0, count: 32),
            Data([1]) + Data(repeating: 0, count: 31),
            Data(repeating: 0xFF, count: 32)
        ]

        for identity in invalidIdentities {
            XCTAssertThrowsError(try Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: identity))
        }
    }

    func testAKEAgreementWithWireIdentityMatchesRFC7748() throws {
        let context = try OMEMO2Context(error: ())
        let bob = try context.identity(withPrivateKey: data(hex: bobScalar))
        let expected = try data(hex: "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

        let shared = try Omemo2IdentityRepresentation.sharedSecret(privateKey: data(hex: aliceScalar), peerIdentity: bob.publicKey)

        XCTAssertEqual(shared, expected)
    }

    func testAKEAgreementRejectsLowOrderLegacyPeer() throws {
        let legacyZero = Data([5]) + Data(repeating: 0, count: 32)

        XCTAssertThrowsError(try Omemo2IdentityRepresentation.sharedSecret(privateKey: data(hex: aliceScalar), peerIdentity: legacyZero))
    }

    func testAKEReadsWireIdentityButExposesCurveKeyForECDH() throws {
        let context = try OMEMO2Context(error: ())
        let identity = try context.identity(withPrivateKey: data(hex: aliceScalar))
        try withStoredIdentity(identity.publicKey) { manager, jid, deviceID in
            XCTAssertEqual(manager.getUsersIdentityKey(jid: jid, deviceId: deviceID), identity.publicKey)
            XCTAssertEqual(manager.getUsersPublicKey(jid: jid, deviceId: deviceID), Array(identity.fingerprintPublicKey))
        }
    }

    func testAKERejectsMalformedStoredWireIdentity() throws {
        try withStoredIdentity(Data(repeating: 0, count: 32)) { manager, jid, deviceID in
            XCTAssertNil(manager.getUsersIdentityKey(jid: jid, deviceId: deviceID))
            XCTAssertTrue(manager.getUsersPublicKey(jid: jid, deviceId: deviceID).isEmpty)
        }
    }

    func testTrustSignatureUsesEd25519ForOMEMO2Identity() throws {
        let context = try OMEMO2Context(error: ())
        let identity = try context.identity(withPrivateKey: data(hex: aliceScalar))
        let canonicalHash = Data(SHA256.hash(data: Data("trusted-items canonical string".utf8)))

        let signature = try Omemo2IdentityRepresentation.sign(canonicalHash, privateKey: identity.privateKey)

        let independent = try CryptoKit.Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKey)
        XCTAssertTrue(independent.isValidSignature(signature, for: canonicalHash))
        XCTAssertTrue(Omemo2IdentityRepresentation.verify(signature, data: canonicalHash, storedIdentity: identity.publicKey))
        XCTAssertFalse(Omemo2IdentityRepresentation.verify(signature, data: canonicalHash + Data([1]), storedIdentity: identity.publicKey))
    }

    func testLegacyTrustSignatureIsNeverAcceptedForOMEMO2WireIdentity() throws {
        let context = try OMEMO2Context(error: ())
        let identity = try context.identity(withPrivateKey: data(hex: aliceScalar))
        let hash = Data(SHA256.hash(data: Data("legacy signed trust".utf8)))
        let legacyIdentity = Data([5]) + identity.fingerprintPublicKey
        let signature = try legacySignature(data: hash, publicKey: legacyIdentity, privateKey: identity.privateKey)

        XCTAssertTrue(Omemo2IdentityRepresentation.verify(signature, data: hash, storedIdentity: legacyIdentity))
        // Legacy signatures with Edwards x sign one must not select a fallback
        // merely because standard Ed25519 verification failed.
        var oppositeWireSign = identity.publicKey
        oppositeWireSign[31] = (oppositeWireSign[31] & 0x7F) | ((signature[63] & 0x80) ^ 0x80)
        XCTAssertFalse(Omemo2IdentityRepresentation.verify(signature, data: hash, storedIdentity: oppositeWireSign))
    }

    func testRemoteEd25519IdentityWithSignBitOneVerifiesWithoutCurveSignature() throws {
        let independentIdentity = try CryptoKit.Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map(UInt8.init)))
        let message = Data("remote Ed25519 trust proof".utf8)
        let signature = try independentIdentity.signature(for: message)

        XCTAssertEqual(try XCTUnwrap(independentIdentity.publicKey.rawRepresentation.last) & 0x80, 0x80)
        XCTAssertTrue(Omemo2IdentityRepresentation.verify(signature, data: message, storedIdentity: independentIdentity.publicKey.rawRepresentation))
    }

    func testPreparedOMEMO2IdentityIsAuthoritativeWhenLegacyPrivateKeyIsAbsent() throws {
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        _ = try store.prepare(deviceID: 42, preKeyCount: 1)
        let expected = try store.identity().privateKey

        let actual = try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: store.owner, storage: store, legacyPrivateKey: { nil })

        XCTAssertEqual(actual, expected)
    }

    func testPreparedOMEMO2IdentityIgnoresAMismatchedLegacyPrivateKey() throws {
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        _ = try store.prepare(deviceID: 42, preKeyCount: 1)
        let expected = try store.identity().privateKey
        let mismatchedLegacy = Data(repeating: 0xAF, count: 32)

        let actual = try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: store.owner, storage: store, legacyPrivateKey: { mismatchedLegacy })

        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, mismatchedLegacy)
    }

    func testCorruptOMEMO2StateDoesNotFallBackToALegacyPrivateKey() throws {
        let persistence = MemoryPersistence()
        persistence.records["alice@example.test"] = Data("invalid new profile state".utf8)
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)

        XCTAssertThrowsError(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: store.owner, storage: store,
                             legacyPrivateKey: { Data(repeating: 1, count: 32) }))
    }

    func testMissingOMEMO2StateWithAnExistingProfileMarkerDoesNotUseTheLegacyPrivateKey() throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2IdentityBindingTests-marker-\(UUID().uuidString)")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let owner = "migrated-alice@example.test"
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let realm = try WRealm.safe()
        let marker = SignalIdentityStorageItem()
        marker.owner = owner
        marker.jid = owner
        marker.deviceId = 42
        marker.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: owner, deviceId: 42)
        marker.protocolProfile = XabberOMEMO2Storage.profile
        try realm.write { realm.add(marker, update: .modified) }

        XCTAssertThrowsError(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: owner, storage: store,
                             legacyPrivateKey: { Data(repeating: 1, count: 32) }))
        XCTAssertTrue(persistence.records.isEmpty)
    }

    func testAnAbsentOMEMO2ProfileCanUseTheExistingLegacyPrivateKey() throws {
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        let legacy = try data(hex: aliceScalar)

        XCTAssertEqual(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: store.owner, storage: store,
                       legacyPrivateKey: { legacy }), legacy)
    }

    func testLocalIdentityCannotBeReadFromAnotherAccountOrAnInvalidLegacyScalar() throws {
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: "alice@example.test", persistence: persistence)
        _ = try store.prepare(deviceID: 42, preKeyCount: 1)
        XCTAssertThrowsError(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: "bob@example.test", storage: store,
                             legacyPrivateKey: { Data(repeating: 1, count: 32) }))
        let absent = try XabberOMEMO2Storage(owner: "absent@example.test", persistence: persistence)
        XCTAssertThrowsError(try Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: absent.owner, storage: absent,
                             legacyPrivateKey: { Data(repeating: 1, count: 31) }))
    }

    func testPreparationReusesTheAuthoritativeDeviceIDWhenTheLegacyCredentialIsMissingOrDifferent() throws {
        let persistence = MemoryPersistence()
        let owner = "prepared-\(UUID().uuidString)@example.test"
        let store = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        _ = try store.prepare(deviceID: 42, preKeyCount: 1)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = store

        for legacyID in [nil, 999] as [Int?] {
            XCTAssertEqual(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { legacyID }, freshDeviceID: {
                XCTFail("A prepared aggregate must not request a replacement device ID")
                return 123
            }), 42)
        }
    }

    func testPreparationDoesNotReplaceCorruptOrInaccessibleStateWithLegacyOrFreshIDs() throws {
        let persistence = MemoryPersistence()
        let owner = "broken-\(UUID().uuidString)@example.test"
        persistence.records[owner] = Data("corrupt new profile".utf8)
        let store = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = store

        XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { 123 }, freshDeviceID: { 456 }))
        persistence.failReads = true
        XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { 123 }, freshDeviceID: { 456 }))
    }

    func testPreparationCanUseLegacyOrFreshIDsOnlyBeforeAMigrationExists() throws {
        let persistence = MemoryPersistence()
        let owner = "fresh-\(UUID().uuidString)@example.test"
        let store = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = store

        XCTAssertEqual(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { 123 }, freshDeviceID: { 456 }), 123)
        XCTAssertEqual(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { nil }, freshDeviceID: { 456 }), 456)
        XCTAssertTrue(persistence.records.isEmpty)
    }

    func testPreparationDoesNotGenerateAnIDWhenAMigratedProfileHasLostItsAggregate() throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2IdentityBindingTests-device-marker-\(UUID().uuidString)")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let owner = "missing-\(UUID().uuidString)@example.test"
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = store
        let realm = try WRealm.safe()
        let marker = SignalIdentityStorageItem()
        marker.owner = owner
        marker.jid = owner
        marker.deviceId = 42
        marker.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: owner, deviceId: 42)
        marker.protocolProfile = XabberOMEMO2Storage.profile
        try realm.write { realm.add(marker, update: .modified) }

        XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { nil }, freshDeviceID: { 456 }))
        XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { 42 }, freshDeviceID: { 456 }))
        XCTAssertTrue(persistence.records.isEmpty)
    }

    func testPreparationRejectsInvalidLegacyOrGeneratedDeviceIDs() throws {
        let persistence = MemoryPersistence()
        let owner = "invalid-id-\(UUID().uuidString)@example.test"
        let store = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = store
        for invalid in [-1, 0, Int(Int32.max) + 1] {
            XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { invalid }, freshDeviceID: { 123 }))
            XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { nil }, freshDeviceID: { invalid }))
        }
    }

    func testPreparationRejectsAnAggregateBelongingToAnotherAccount() throws {
        let persistence = MemoryPersistence()
        let store = try XabberOMEMO2Storage(owner: "another-device@example.test", persistence: persistence)
        _ = try store.prepare(deviceID: 42, preKeyCount: 1)
        let manager = OmemoManager(withOwner: "owner-\(UUID().uuidString)@example.test")
        manager.omemo2Storage = store

        XCTAssertThrowsError(try manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { 123 }, freshDeviceID: { 456 }))
    }

    private func withStoredIdentity(_ identity: Data, assertions: (AuthenticatedKeyExchangeManager, String, Int) throws -> Void) throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2IdentityBindingTests-\(UUID().uuidString)")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let owner = "alice@example.test"
        let jid = "bob@example.test"
        let deviceID = 42
        let realm = try WRealm.safe()
        let stored = SignalIdentityStorageItem()
        stored.owner = owner
        stored.jid = jid
        stored.deviceId = deviceID
        stored.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: deviceID)
        stored.identityKey = identity.base64EncodedString()
        try realm.write { realm.add(stored, update: .modified) }

        try assertions(AuthenticatedKeyExchangeManager(withOwner: owner), jid, deviceID)
    }

    private func legacySignature(data: Data, publicKey: Data, privateKey: Data) throws -> Data {
        let pair = Curve25519Kit.Curve25519.load(fromPublicKey: Data(publicKey.dropFirst()), andPrivateKey: privateKey)
        return try XCTUnwrap(Ed25519.sign(data, with: pair))
    }

    private func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw NSError(domain: "OMEMO2IdentityBindingTests.hex", code: 1) }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { throw NSError(domain: "OMEMO2IdentityBindingTests.hex", code: 2) }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }
}
