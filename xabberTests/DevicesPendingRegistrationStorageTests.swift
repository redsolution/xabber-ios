import Foundation
import XCTest
@testable import xabber

/// Uses the real native crypto backend. Only protected persistence is in memory.
final class DevicesPendingRegistrationStorageTests: XCTestCase {
    private enum Failure: Error { case injected }
    private final class Memory: OMEMO2StatePersistence {
        var values: [String: Data] = [:]
        var failWrites = false
        var unavailable = false
        var preparedMarker = false
        var writes = 0
        func load(owner: String) throws -> Data? {
            if unavailable { throw Failure.injected }
            return values[owner]
        }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw Failure.injected }
            values[owner] = data; writes += 1
        }
        func remove(owner: String) throws { values.removeValue(forKey: owner) }
        func nativePreparationExists(owner: String) throws -> Bool { preparedMarker }
    }
    private struct Fixture {
        let memory: Memory
        let alice: XabberOMEMO2Storage
        let bob: XabberOMEMO2Storage
        let aliceBundle: OMEMO2LocalBundle
        let bobBundle: OMEMO2LocalBundle
    }

    func testAbsentSnapshotDoesNotAllocateIdentityOrWrite() throws {
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: "empty-\(UUID())@example.test", persistence: memory)
        XCTAssertNil(try storage.registrationSnapshot())
        XCTAssertEqual(memory.writes, 0)
    }

    func testUnavailableSnapshotCannotBeTreatedAsAbsent() throws {
        let f = try fixture(); let before = bytes(f)
        f.memory.unavailable = true
        XCTAssertThrowsError(try f.alice.registrationSnapshot())
        XCTAssertTrue(bytes(f) == before)
    }

    func testMissingPreparedSecretsRequireRecoveryInsteadOfFreshIdentity() throws {
        let memory = Memory(); memory.preparedMarker = true
        let storage = try XabberOMEMO2Storage(owner: "prepared-\(UUID())@example.test", persistence: memory)
        XCTAssertThrowsError(try storage.registrationSnapshot())
        XCTAssertEqual(memory.writes, 0)
    }

    func testFreshPreparationRequiresCurrentAuthenticationAtCommit() throws {
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: "new-\(UUID())@example.test", persistence: memory)
        var checks = 0
        XCTAssertThrowsError(try storage.prepare(deviceID: 101, preKeyCount: 3,
            isCurrent: { checks += 1; return checks == 1 }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertNil(try storage.registrationSnapshot())
        XCTAssertEqual(memory.writes, 0)
    }

    func testFreshPreparationCannotOverwriteConcurrentInitialState() throws {
        let memory = Memory(); let owner = "new-\(UUID())@example.test"
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let other = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        var checks = 0; var concurrent: Data?
        XCTAssertThrowsError(try storage.prepare(deviceID: 101, preKeyCount: 3, isCurrent: {
            checks += 1
            if checks == 2 {
                do { _ = try other.prepare(deviceID: 303, preKeyCount: 3); concurrent = memory.values[owner] }
                catch { XCTFail("Concurrent initial registration failed") }
            }
            return true
        }))
        XCTAssertNotNil(concurrent)
        XCTAssertTrue(memory.values[owner] == concurrent)
        XCTAssertEqual(try storage.localBundle().deviceID, 303)
    }

    func testFreshSnapshotIsPendingAndReadOnly() throws {
        let f = try fixture(); let before = bytes(f); let writes = f.memory.writes
        let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        XCTAssertEqual(snapshot.deviceID, 101)
        XCTAssertEqual(snapshot.identityKey, f.aliceBundle.identityKey)
        XCTAssertTrue(snapshot.registrationPending)
        XCTAssertTrue(snapshot.isUnusedPending)
        XCTAssertTrue(snapshot.publicationNeeded)
        XCTAssertTrue(bytes(f) == before)
        XCTAssertEqual(f.memory.writes, writes)
    }

    func testRegistrationIdentityWitnessSurvivesNormalPreKeyAndSessionUpdates() throws {
        let f = try fixture(); let original = try XCTUnwrap(f.alice.registrationSnapshot())
        _ = try f.alice.replenishPreKeys(minimumCount: 5)
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 202, bundle: selected(f.bobBundle))
        let updated = try XCTUnwrap(f.alice.registrationSnapshot())
        XCTAssertTrue(original.hasSameIdentity(as: updated))
        XCTAssertTrue(updated.hasSameIdentity(as: original))
        let restarted = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        XCTAssertTrue(try original.hasSameIdentity(as: XCTUnwrap(restarted.registrationSnapshot())))
    }

    func testRegistrationIdentityWitnessRejectsSameSIDNewProtectedIncarnation() throws {
        let f = try fixture(); let original = try XCTUnwrap(f.alice.registrationSnapshot())
        try f.alice.removeAllState()
        _ = try f.alice.prepare(deviceID: 101, preKeyCount: 3)
        let replaced = try XCTUnwrap(f.alice.registrationSnapshot())
        XCTAssertFalse(original.hasSameIdentity(as: replaced))
        XCTAssertFalse(try original.hasSameIdentity(as: XCTUnwrap(f.bob.registrationSnapshot())))
    }

    func testRegistrationIdentityWitnessRetainsIncarnationAcrossAllowedSIDAdoption() throws {
        let f = try fixture(); let original = try XCTUnwrap(f.alice.registrationSnapshot())
        _ = try adopt(f, expected: original)
        let adopted = try XCTUnwrap(f.alice.registrationSnapshot())
        XCTAssertTrue(original.hasSameIdentity(as: adopted))
        XCTAssertNotEqual(original.deviceID, adopted.deviceID)
    }

    func testGuardedReplenishmentRejectsExpiredPublicationAuthorityWithoutWriting() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try f.alice.replenishPreKeys(minimumCount: 5, isCurrent: { false }))
        XCTAssertTrue(bytes(f) == before)
        XCTAssertEqual(try f.alice.localBundle().preKeys.count, 3)
    }

    func testGuardedReplenishmentRechecksPublicationAuthorityAtCommit() throws {
        let f = try fixture(); let before = bytes(f); var checks = 0
        XCTAssertThrowsError(try f.alice.replenishPreKeys(minimumCount: 5,
            isCurrent: { checks += 1; return checks == 1 }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertTrue(bytes(f) == before)
    }

    func testGuardedReplenishmentCannotOverwriteReentrantConcurrentKeyUpdate() throws {
        let f = try fixture(); let other = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        var checks = 0; var concurrent: Data?
        XCTAssertThrowsError(try f.alice.replenishPreKeys(minimumCount: 5, isCurrent: {
            checks += 1
            if checks == 2 {
                do { _ = try other.replenishPreKeys(minimumCount: 6); concurrent = self.bytes(f) }
                catch { XCTFail("Concurrent native key replenishment failed") }
            }
            return true
        }))
        XCTAssertNotNil(concurrent)
        XCTAssertTrue(bytes(f) == concurrent)
        XCTAssertEqual(try f.alice.localBundle().preKeys.count, 6)
    }

    func testUnusedPendingAdoptsServerIDChangingOnlyIDAndPublicationFlag() throws {
        let f = try fixture(); let before = try plist(bytes(f))
        let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        let adopted = try adopt(f, expected: snapshot)
        XCTAssertEqual(adopted.deviceID, 303)
        XCTAssertEqual(adopted.identityKey, f.aliceBundle.identityKey)
        XCTAssertEqual(adopted.fingerprintPublicKey, f.aliceBundle.fingerprintPublicKey)
        XCTAssertEqual(adopted.signedPreKey, f.aliceBundle.signedPreKey)
        XCTAssertEqual(adopted.signature, f.aliceBundle.signature)
        XCTAssertEqual(adopted.preKeys, f.aliceBundle.preKeys)
        var after = try plist(bytes(f)); after["deviceID"] = before["deviceID"]
        after["bundlePublicationNeeded"] = before["bundlePublicationNeeded"]
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: after), "Only public ID and publication-dirty metadata may change")
    }

    func testAdoptedPendingIdentityPerformsRealKeyExchangeUnderServerID() throws {
        let f = try fixture()
        let adopted = try adopt(f)
        try f.bob.initiateSession(jid: f.alice.owner, deviceID: 303, bundle: selected(adopted))
        let packet = try f.bob.encrypt(material(8), jid: f.alice.owner, deviceID: 303)
        XCTAssertEqual(try f.alice.decrypt(packet, jid: f.bob.owner, deviceID: 202), material(8))
        let reply = try f.alice.encrypt(material(9), jid: f.bob.owner, deviceID: 202)
        XCTAssertEqual(try f.bob.decrypt(reply, jid: f.alice.owner, deviceID: 303), material(9))
        XCTAssertEqual(try f.alice.localBundle().identityKey, f.aliceBundle.identityKey)
        XCTAssertEqual(try f.alice.localBundle().deviceID, 303)
    }

    func testPendingAdoptionAcceptsSamePublishedTargetIdentity() throws {
        let f = try fixture()
        let adopted = try adopt(f, targetIdentity: f.aliceBundle.identityKey)
        XCTAssertEqual(adopted.deviceID, 303)
        XCTAssertEqual(adopted.identityKey, f.aliceBundle.identityKey)
    }

    func testPendingAdoptionRejectsDifferentPublishedTargetIdentity() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try adopt(f, targetIdentity: f.bobBundle.identityKey))
        XCTAssertTrue(bytes(f) == before)
    }

    func testPendingAdoptionRejectsExistingOldPublishedIdentity() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try adopt(f, oldIdentity: f.aliceBundle.identityKey))
        XCTAssertTrue(bytes(f) == before)
    }

    func testPendingAdoptionRejectsOldIDInAuthoritativeMembership() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try adopt(f, oldIDAbsent: { false }))
        XCTAssertTrue(bytes(f) == before)
    }

    func testPendingAdoptionRejectsExternalReplayOrAdmittedIdentity() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try adopt(f, externalStateUnused: { false }))
        XCTAssertTrue(bytes(f) == before)
    }

    func testPendingAdoptionRejectsExpiredAuthenticationWithoutWriting() throws {
        let f = try fixture(); let before = bytes(f); let writes = f.memory.writes
        XCTAssertThrowsError(try adopt(f, isCurrent: { false }))
        XCTAssertTrue(bytes(f) == before)
        XCTAssertEqual(f.memory.writes, writes)
    }

    func testPendingAdoptionRechecksAuthenticationAtCommitBoundary() throws {
        let f = try fixture(); let before = bytes(f); var checks = 0
        XCTAssertThrowsError(try adopt(f, isCurrent: { checks += 1; return checks == 1 }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertTrue(bytes(f) == before)
    }

    func testPendingAdoptionRechecksMembershipAtCommitBoundary() throws {
        let f = try fixture(); let before = bytes(f); var checks = 0
        XCTAssertThrowsError(try adopt(f, oldIDAbsent: { checks += 1; return checks == 1 }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertTrue(bytes(f) == before)
    }

    func testFinalExternalAdmissionCannotRevokeAuthenticationThenCommit() throws {
        let f = try fixture(); let before = bytes(f)
        var liveAuthentication = true; var checks = 0
        XCTAssertThrowsError(try adopt(f, externalStateUnused: {
            checks += 1
            if checks == 2 { liveAuthentication = false }
            return true
        }, isCurrent: { liveAuthentication }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertTrue(bytes(f) == before)
        XCTAssertEqual(try f.alice.localBundle().deviceID, 101)
    }

    func testConcurrentKeyMaintenanceInvalidatesPendingSnapshot() throws {
        let f = try fixture(); let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        let other = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        _ = try other.replenishPreKeys(minimumCount: 5)
        let concurrent = bytes(f)
        XCTAssertThrowsError(try adopt(f, expected: snapshot))
        XCTAssertTrue(bytes(f) == concurrent)
        XCTAssertEqual(try f.alice.localBundle().preKeys.count, 5)
    }

    func testReentrantConcurrentWriteDuringFinalAdmissionCannotBeOverwritten() throws {
        let f = try fixture(); let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        let other = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        var checks = 0; var concurrent: Data?
        XCTAssertThrowsError(try adopt(f, expected: snapshot, externalStateUnused: {
            checks += 1
            if checks == 2 {
                do { _ = try other.replenishPreKeys(minimumCount: 5); concurrent = self.bytes(f) }
                catch { XCTFail("Concurrent native state update failed") }
            }
            return true
        }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertNotNil(concurrent)
        XCTAssertTrue(bytes(f) == concurrent)
        XCTAssertEqual(try f.alice.localBundle().deviceID, 101)
        XCTAssertEqual(try f.alice.localBundle().preKeys.count, 5)
    }

    func testConcurrentStateReplacementInvalidatesPendingIncarnation() throws {
        let f = try fixture(); let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        try f.alice.removeAllState()
        let replacement = try f.alice.prepare(deviceID: 101, preKeyCount: 3)
        let concurrent = bytes(f)
        XCTAssertThrowsError(try adopt(f, expected: snapshot))
        XCTAssertTrue(bytes(f) == concurrent)
        XCTAssertEqual(try f.alice.localBundle().identityKey, replacement.identityKey)
        XCTAssertNotEqual(replacement.identityKey, f.aliceBundle.identityKey)
    }

    func testFailedAtomicSavePreservesIdentityAndAllowsSamePendingRetry() throws {
        let f = try fixture(); let before = bytes(f)
        let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        f.memory.failWrites = true
        XCTAssertThrowsError(try adopt(f, expected: snapshot))
        XCTAssertTrue(bytes(f) == before)
        f.memory.failWrites = false
        XCTAssertEqual(try adopt(f, expected: snapshot).deviceID, 303)
        XCTAssertEqual(try f.alice.localBundle().identityKey, f.aliceBundle.identityKey)
    }

    func testOldAggregateWithoutPendingEvidenceCannotAdoptEvenWhenEmpty() throws {
        let f = try fixture(); var state = try plist(bytes(f))
        for key in ["registrationPending", "bundlePublicationNeeded", "registrationIncarnation", "registrationKeyMaterialUsed"] {
            state.removeValue(forKey: key)
        }
        f.memory.values[f.alice.owner] = try encoded(state)
        let before = bytes(f)
        let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        XCTAssertFalse(snapshot.isUnusedPending)
        XCTAssertThrowsError(try adopt(f, expected: snapshot))
        XCTAssertTrue(bytes(f) == before)
    }

    func testLiveSessionMismatchLeavesNativeRatchetUsableAndUnchanged() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 202, bundle: selected(f.bobBundle))
        let first = try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 202)
        XCTAssertEqual(try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 101), material(1))
        let before = bytes(f)
        XCTAssertThrowsError(try adopt(f))
        XCTAssertTrue(bytes(f) == before)
        let second = try f.alice.encrypt(material(2), jid: f.bob.owner, deviceID: 202)
        XCTAssertEqual(try f.bob.decrypt(second, jid: f.alice.owner, deviceID: 101), material(2))
        XCTAssertEqual(try f.alice.localBundle().deviceID, 101)
        XCTAssertEqual(try f.alice.localBundle().identityKey, f.aliceBundle.identityKey)
    }

    func testDeletedSessionStillLeavesDurableKeyUseEvidence() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 202, bundle: selected(f.bobBundle))
        _ = try f.alice.encrypt(material(3), jid: f.bob.owner, deviceID: 202)
        try f.alice.deleteSessions(jid: f.bob.owner)
        XCTAssertFalse(try f.alice.sessionExists(jid: f.bob.owner, deviceID: 202))
        let before = bytes(f)
        XCTAssertFalse(try XCTUnwrap(f.alice.registrationSnapshot()).isUnusedPending)
        XCTAssertThrowsError(try adopt(f))
        XCTAssertTrue(bytes(f) == before)
    }

    func testAuthenticatedReplayAndConsumedPreKeysRejectIDAdoption() throws {
        let f = try fixture()
        try f.bob.initiateSession(jid: f.alice.owner, deviceID: 101, bundle: selected(f.aliceBundle))
        let packet = try f.bob.encrypt(material(4), jid: f.alice.owner, deviceID: 101)
        XCTAssertEqual(try f.alice.decrypt(packet, jid: f.bob.owner, deviceID: 202,
            replayFingerprint: Data(repeating: 0x54, count: 32)), material(4))
        let before = bytes(f)
        XCTAssertFalse(try f.alice.consumedPreKeyIDs().isEmpty)
        XCTAssertThrowsError(try adopt(f))
        XCTAssertTrue(bytes(f) == before)
    }

    func testControlHistoryPreventsAdoptionAfterControlCleared() throws {
        let f = try fixture()
        try f.alice.markControlNeeded(jid: f.bob.owner, deviceID: 202, needed: true)
        try f.alice.markControlNeeded(jid: f.bob.owner, deviceID: 202, needed: false)
        let before = bytes(f)
        XCTAssertThrowsError(try adopt(f))
        XCTAssertTrue(bytes(f) == before)
    }

    func testConfirmedRegistrationCannotAdoptAndRetainsNativeSession() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 202, bundle: selected(f.bobBundle))
        let before = try plist(bytes(f))
        try f.alice.markRegistrationConfirmed(deviceID: 101, identityKey: f.aliceBundle.identityKey, isCurrent: { true })
        let snapshot = try XCTUnwrap(f.alice.registrationSnapshot())
        XCTAssertFalse(snapshot.registrationPending)
        XCTAssertFalse(snapshot.publicationNeeded)
        XCTAssertFalse(snapshot.isUnusedPending)
        var after = try plist(bytes(f))
        for key in ["registrationPending", "bundlePublicationNeeded"] { after[key] = before[key] }
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: after), "Confirmation preserves all private material and sessions")
        XCTAssertThrowsError(try adopt(f, expected: snapshot))
        let packet = try f.alice.encrypt(material(5), jid: f.bob.owner, deviceID: 202)
        XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 101), material(5))
    }

    func testPublicKeyMaintenanceMarksPublicationDirtyWithoutReplacingIdentity() throws {
        let f = try fixture()
        try f.alice.markRegistrationConfirmed(deviceID: 101, identityKey: f.aliceBundle.identityKey, isCurrent: { true })
        XCTAssertFalse(try XCTUnwrap(f.alice.registrationSnapshot()).publicationNeeded)
        let before = bytes(f)
        XCTAssertFalse(try f.alice.maintainKeysIfDue())
        XCTAssertTrue(bytes(f) == before)
        let replenished = try f.alice.replenishPreKeys(minimumCount: 5)
        XCTAssertTrue(try XCTUnwrap(f.alice.registrationSnapshot()).publicationNeeded)
        XCTAssertEqual(replenished.identityKey, f.aliceBundle.identityKey)
        XCTAssertEqual(Array(replenished.preKeys.prefix(3)), f.aliceBundle.preKeys)
    }

    func testConsumedPublishedOPKMarksBundleDirtyWithoutLosingSession() throws {
        let f = try fixture()
        try f.alice.markRegistrationConfirmed(deviceID: 101, identityKey: f.aliceBundle.identityKey, isCurrent: { true })
        try f.bob.initiateSession(jid: f.alice.owner, deviceID: 101, bundle: selected(f.aliceBundle))
        let first = try f.bob.encrypt(material(6), jid: f.alice.owner, deviceID: 101)
        XCTAssertEqual(try f.alice.decrypt(first, jid: f.bob.owner, deviceID: 202), material(6))
        XCTAssertTrue(try XCTUnwrap(f.alice.registrationSnapshot()).publicationNeeded)
        let second = try f.bob.encrypt(material(7), jid: f.alice.owner, deviceID: 101)
        XCTAssertEqual(try f.alice.decrypt(second, jid: f.bob.owner, deviceID: 202), material(7))
        XCTAssertEqual(try f.alice.localBundle().identityKey, f.aliceBundle.identityKey)
    }

    func testStaleConfirmationAndWrongIdentityDoNotClearPendingState() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try f.alice.markRegistrationConfirmed(deviceID: 303, identityKey: f.aliceBundle.identityKey, isCurrent: { true }))
        XCTAssertThrowsError(try f.alice.markRegistrationConfirmed(deviceID: 101, identityKey: f.bobBundle.identityKey, isCurrent: { true }))
        XCTAssertThrowsError(try f.alice.markRegistrationConfirmed(deviceID: 101, identityKey: f.aliceBundle.identityKey, isCurrent: { false }))
        XCTAssertTrue(bytes(f) == before)
    }

    func testConfirmationCannotOverwriteConcurrentPublicKeyUpdateAtCommit() throws {
        let f = try fixture(); let other = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        var checks = 0; var concurrent: Data?
        XCTAssertThrowsError(try f.alice.markRegistrationConfirmed(deviceID: 101,
            identityKey: f.aliceBundle.identityKey, isCurrent: {
                checks += 1
                if checks == 2 {
                    do { _ = try other.replenishPreKeys(minimumCount: 5); concurrent = self.bytes(f) }
                    catch { XCTFail("Concurrent native key update failed") }
                }
                return true
            }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertNotNil(concurrent)
        XCTAssertTrue(bytes(f) == concurrent)
        XCTAssertTrue(try XCTUnwrap(f.alice.registrationSnapshot()).publicationNeeded)
        XCTAssertTrue(try XCTUnwrap(f.alice.registrationSnapshot()).registrationPending)
    }

    func testInvalidOrForeignPendingSnapshotCannotMutateTargetState() throws {
        let f = try fixture(); let before = bytes(f)
        for id in [0, -1, Int(Int32.max) + 1] { XCTAssertThrowsError(try adopt(f, to: id)) }
        let foreign = try XCTUnwrap(f.bob.registrationSnapshot())
        XCTAssertThrowsError(try adopt(f, expected: foreign))
        XCTAssertTrue(bytes(f) == before)
    }

    private func fixture() throws -> Fixture {
        let memory = Memory(); let nonce = UUID().uuidString
        let alice = try XabberOMEMO2Storage(owner: "alice-\(nonce)@example.test", persistence: memory)
        let bob = try XabberOMEMO2Storage(owner: "bob-\(nonce)@example.test", persistence: memory)
        return Fixture(memory: memory, alice: alice, bob: bob,
            aliceBundle: try alice.prepare(deviceID: 101, preKeyCount: 3),
            bobBundle: try bob.prepare(deviceID: 202, preKeyCount: 3))
    }
    private func adopt(_ f: Fixture, to id: Int = 303, expected: OMEMO2RegistrationSnapshot? = nil,
                       oldIdentity: Data? = nil, targetIdentity: Data? = nil,
                       oldIDAbsent: () -> Bool = { true }, externalStateUnused: () -> Bool = { true },
                       isCurrent: () -> Bool = { true }) throws -> OMEMO2LocalBundle {
        try f.alice.adoptPendingDeviceID(id, expected: expected ?? XCTUnwrap(f.alice.registrationSnapshot()),
            oldIDAbsent: oldIDAbsent, publishedOldIdentity: oldIdentity, publishedTargetIdentity: targetIdentity,
            externalStateUnused: externalStateUnused, isCurrent: isCurrent)
    }
    private func bytes(_ f: Fixture) -> Data { f.memory.values[f.alice.owner] ?? Data() }
    private func plist(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
    private func encoded(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private func selected(_ bundle: OMEMO2LocalBundle) throws -> OMEMO2Bundle {
        let key = try XCTUnwrap(bundle.preKeys.first)
        return try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
            signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: key.publicKey, preKeyID: key.id)
    }
    private func material(_ byte: UInt8) -> Data { Data(repeating: byte, count: 48) }
}
