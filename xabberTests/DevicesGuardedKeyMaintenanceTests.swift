import Foundation
import XCTest
@testable import xabber

/// The native SPK rotation runs against real protected key material. The clock
/// and atomic persistence are controlled to expose authority/commit races.
final class DevicesGuardedKeyMaintenanceTests: XCTestCase {
    private enum Failure: Error { case injected }
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    private final class Memory: OMEMO2StatePersistence {
        var values: [String: Data] = [:]
        var failWrites = false
        func load(owner: String) throws -> Data? { values[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw Failure.injected }
            values[owner] = data
        }
        func remove(owner: String) throws { values.removeValue(forKey: owner) }
    }
    private struct Fixture {
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let clock: Clock
        let bundle: OMEMO2LocalBundle
    }

    func testCurrentMaintenanceRotatesSPKAndRetainsIdentityAndPreKeys() throws {
        let f = try fixture()
        XCTAssertTrue(try f.storage.maintainKeysIfDue(isCurrent: { true }))
        let after = try f.storage.localBundle()
        XCTAssertEqual(after.deviceID, f.bundle.deviceID)
        XCTAssertEqual(after.identityKey, f.bundle.identityKey)
        XCTAssertEqual(after.fingerprintPublicKey, f.bundle.fingerprintPublicKey)
        XCTAssertEqual(after.preKeys, f.bundle.preKeys)
        XCTAssertEqual(after.signedPreKeyID, f.bundle.signedPreKeyID + 1)
        XCTAssertNotEqual(after.signedPreKey, f.bundle.signedPreKey)
        XCTAssertTrue(try XCTUnwrap(f.storage.registrationSnapshot()).publicationNeeded)
    }

    func testExpiredMaintenanceAuthorityLeavesPrivateStateUnchanged() throws {
        let f = try fixture(); let before = bytes(f)
        XCTAssertThrowsError(try f.storage.maintainKeysIfDue(isCurrent: { false }))
        XCTAssertTrue(bytes(f) == before)
        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, f.bundle.signedPreKeyID)
    }

    func testMaintenanceRechecksAuthenticationAfterGeneratingRotationCandidate() throws {
        let f = try fixture(); let before = bytes(f); var checks = 0
        XCTAssertThrowsError(try f.storage.maintainKeysIfDue(isCurrent: {
            checks += 1; return checks == 1
        }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertTrue(bytes(f) == before)
        XCTAssertEqual(try f.storage.localBundle().identityKey, f.bundle.identityKey)
    }

    func testMaintenanceCannotOverwriteSameSIDReplacementAtCommit() throws {
        let f = try fixture()
        let other = try XabberOMEMO2Storage(owner: f.storage.owner, persistence: f.memory, now: { f.clock.now })
        var checks = 0; var replacement: Data?; var replacementIdentity: Data?
        XCTAssertThrowsError(try f.storage.maintainKeysIfDue(isCurrent: {
            checks += 1
            if checks == 2 {
                do {
                    try other.removeAllState()
                    let bundle = try other.prepare(deviceID: f.bundle.deviceID, preKeyCount: 3)
                    replacementIdentity = bundle.identityKey; replacement = self.bytes(f)
                } catch { XCTFail("Concurrent replacement could not be prepared") }
            }
            return true
        }))
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertNotNil(replacement)
        XCTAssertTrue(bytes(f) == replacement)
        XCTAssertEqual(try f.storage.localBundle().identityKey, replacementIdentity)
        XCTAssertNotEqual(replacementIdentity, f.bundle.identityKey)
    }

    func testFailedMaintenanceCommitPreservesStateAndRetriesSameIdentity() throws {
        let f = try fixture(); let before = bytes(f)
        f.memory.failWrites = true
        XCTAssertThrowsError(try f.storage.maintainKeysIfDue(isCurrent: { true }))
        XCTAssertTrue(bytes(f) == before)
        f.memory.failWrites = false
        XCTAssertTrue(try f.storage.maintainKeysIfDue(isCurrent: { true }))
        let after = try f.storage.localBundle()
        XCTAssertEqual(after.identityKey, f.bundle.identityKey)
        XCTAssertEqual(after.signedPreKeyID, f.bundle.signedPreKeyID + 1)
    }

    private func fixture() throws -> Fixture {
        let memory = Memory(); let clock = Clock()
        let storage = try XabberOMEMO2Storage(owner: "maintenance-\(UUID())@example.test", persistence: memory,
            now: { clock.now })
        let bundle = try storage.prepare(deviceID: 101, preKeyCount: 3)
        clock.now = clock.now.addingTimeInterval(XabberOMEMO2Storage.signedPreKeyRotationInterval + 1)
        return Fixture(storage: storage, memory: memory, clock: clock, bundle: bundle)
    }
    private func bytes(_ f: Fixture) -> Data { f.memory.values[f.storage.owner] ?? Data() }
}
