import Foundation
import XCTest
@testable import xabber

/// Transactions use real native sessions. Only protected persistence is faked.
final class OMEMO2StorageBehaviorTests: XCTestCase {
    private enum Failure: Error { case injected }

    private final class Memory: OMEMO2StatePersistence {
        private let lock = NSLock()
        private var records: [String: Data] = [:]
        private var committedWrites = 0
        var failWrites = false
        var failRemoves = false
        var beforeSave: ((String) -> Void)?
        var delayReads = false
        var legacyReads = 0

        func load(owner: String) throws -> Data? {
            let data = value(owner)
            // Widen a genuine read/modify/write race if owner serialization is
            // removed. The fake protects its dictionary, not the transaction.
            if delayReads { Thread.sleep(forTimeInterval: 0.002) }
            return data
        }
        func save(_ data: Data, owner: String) throws {
            beforeSave?(owner)
            lock.lock()
            defer { lock.unlock() }
            if failWrites { throw Failure.injected }
            records[owner] = data
            committedWrites += 1
        }
        func remove(owner: String) throws {
            lock.lock()
            defer { lock.unlock() }
            if failRemoves { throw Failure.injected }
            records.removeValue(forKey: owner)
        }
        func value(_ owner: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return records[owner]
        }
        func put(_ data: Data, owner: String) {
            lock.lock()
            defer { lock.unlock() }
            records[owner] = data
        }
        var writes: Int {
            lock.lock()
            defer { lock.unlock() }
            return committedWrites
        }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? {
            legacyReads += 1
            throw Failure.injected
        }
        func legacyDeviceID(owner: String) -> Int? { legacyReads += 1; return 999 }
    }

    private final class Results<T> {
        private let lock = NSLock()
        private var storage: [T] = []
        func append(_ value: T) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(value)
        }
        var values: [T] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct Fixture {
        let memory: Memory
        let alice: XabberOMEMO2Storage
        let bob: XabberOMEMO2Storage
        let bundle: OMEMO2LocalBundle
    }

    func testConcurrentStoreInstancesCommitEveryOutgoingCounterAndEveryPacketDecrypts() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        let stores = try (0..<16).map { _ in try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory) }
        let packets = Results<OMEMO2Ciphertext>()
        let errors = Results<Error>()
        f.memory.delayReads = true

        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            do { packets.append(try stores[index].encrypt(material(0), jid: f.bob.owner, deviceID: 2)) }
            catch { errors.append(error) }
        }

        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(packets.values.count, stores.count)
        XCTAssertEqual(Set(packets.values.map(\.counter)), Set((0..<stores.count).map(UInt32.init)))
        XCTAssertEqual(Set(packets.values.compactMap(\.ephemeralKey)).count, 1)
        for packet in packets.values.sorted(by: { $0.counter > $1.counter }) {
            XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1), material(0))
        }
        let restarted = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        XCTAssertEqual(try restarted.sessionMetadata(jid: f.bob.owner, deviceID: 2)?.sendCounter, UInt32(stores.count))
    }

    func testConcurrentReceiveInstancesKeepAllCountersAndConsumeOneOPKOnlyOnce() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        let packets = try (0..<16).map { try f.alice.encrypt(material($0), jid: f.bob.owner, deviceID: 2) }
        let stores = try packets.map { _ in try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory) }
        let plaintexts = Results<Data>()
        let errors = Results<Error>()
        let commits = Results<Int>()
        for (index, store) in stores.enumerated() { store.authenticatedReceiveDidCommit = { commits.append(index) } }
        f.memory.delayReads = true

        DispatchQueue.concurrentPerform(iterations: packets.count) { index in
            do {
                plaintexts.append(try stores[index].decrypt(packets[index], jid: f.alice.owner, deviceID: 1,
                    replayFingerprint: Data(repeating: UInt8(index), count: 32)))
            } catch { errors.append(error) }
        }

        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(Set(plaintexts.values), Set((0..<16).map(material)))
        XCTAssertEqual(commits.values.count, packets.count)
        XCTAssertEqual(try f.bob.consumedPreKeyIDs(), [try XCTUnwrap(f.bundle.preKeys.first).id])
        XCTAssertEqual(try f.bob.localBundle().preKeys.count, f.bundle.preKeys.count - 1)
        XCTAssertEqual(try f.bob.sessionMetadata(jid: f.alice.owner, deviceID: 1)?.receiveCounter, UInt32(packets.count))
        let before = f.memory.value(f.bob.owner)
        for (index, packet) in packets.enumerated() {
            XCTAssertThrowsError(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
                replayFingerprint: Data(repeating: UInt8(index), count: 32))) { error in
                guard case OMEMO2StorageError.authenticatedDuplicate = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(f.memory.value(f.bob.owner), before)
    }

    func testConcurrentFirstReceivesForDifferentPeersPreserveBothSessionsOPKsAndReplayReceipts() throws {
        let f = try fixture()
        let charlie = try XabberOMEMO2Storage(owner: "charlie-\(UUID().uuidString)@example.test", persistence: f.memory)
        _ = try charlie.prepare(deviceID: 3, preKeyCount: 1)
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle, index: 0))
        try charlie.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle, index: 1))
        let peers = [(f.alice, 1), (charlie, 3)]
        let packets = try peers.enumerated().map { index, pair in
            try pair.0.encrypt(material(index), jid: f.bob.owner, deviceID: 2)
        }
        let stores = try peers.map { _ in try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory) }
        let errors = Results<Error>()
        let plaintexts = Results<Data>()
        f.memory.delayReads = true

        DispatchQueue.concurrentPerform(iterations: peers.count) { index in
            do {
                plaintexts.append(try stores[index].decrypt(packets[index], jid: peers[index].0.owner,
                    deviceID: peers[index].1, replayFingerprint: Data(repeating: UInt8(index), count: 32)))
            } catch { errors.append(error) }
        }

        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(Set(plaintexts.values), [material(0), material(1)])
        XCTAssertEqual(try f.bob.consumedPreKeyIDs(), Set(f.bundle.preKeys.prefix(2).map(\.id)))
        XCTAssertEqual(Set(try f.bob.pendingControlAddresses()), Set(peers.map { OMEMO2PeerAddress(jid: $0.0.owner, deviceID: $0.1) }))
        for (index, peer) in peers.enumerated() {
            XCTAssertTrue(try f.bob.sessionExists(jid: peer.0.owner, deviceID: peer.1))
            XCTAssertThrowsError(try f.bob.decrypt(packets[index], jid: peer.0.owner, deviceID: peer.1,
                replayFingerprint: Data(repeating: UInt8(index), count: 32)))
        }
    }

    func testBlockedSaveForOneOwnerDoesNotBlockAnotherOwnerTransaction() throws {
        let f = try fixture()
        let saveEntered = expectation(description: "Alice save is blocked")
        let aliceDone = expectation(description: "Alice save completes")
        let bobDone = expectation(description: "Bob completes while Alice save is blocked")
        let release = DispatchSemaphore(value: 0)
        let errors = Results<Error>()
        f.memory.beforeSave = { owner in
            if owner == f.alice.owner {
                saveEntered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        defer { release.signal(); f.memory.beforeSave = nil }
        DispatchQueue.global().async {
            defer { aliceDone.fulfill() }
            do { try f.alice.markControlNeeded(jid: f.bob.owner, deviceID: 2, needed: true) }
            catch { errors.append(error) }
        }
        wait(for: [saveEntered], timeout: 2)
        DispatchQueue.global().async {
            defer { bobDone.fulfill() }
            do { try f.bob.markControlNeeded(jid: f.alice.owner, deviceID: 1, needed: true) }
            catch { errors.append(error) }
        }
        wait(for: [bobDone], timeout: 2)
        release.signal()
        wait(for: [aliceDone], timeout: 2)
        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(try f.alice.pendingControlAddresses(), [OMEMO2PeerAddress(jid: f.bob.owner, deviceID: 2)])
        XCTAssertEqual(try f.bob.pendingControlAddresses(), [OMEMO2PeerAddress(jid: f.alice.owner, deviceID: 1)])
    }

    func testEveryReceiveBranchRollsBackValidationPolicyAndWriteFailuresAndAuthenticRetryCommitsOnce() throws {
        for branch in ["initial KEX", "existing KEX", "regular"] {
            for failure in ["validation", "policy callback", "invalid policy", "write"] {
                try XCTContext.runActivity(named: "\(branch), \(failure)") { _ in
                    let f = try fixture()
                    try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
                    if branch != "initial KEX" {
                        _ = try f.bob.decrypt(f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2), jid: f.alice.owner, deviceID: 1)
                    }
                    if branch == "regular" {
                        _ = try f.alice.decrypt(f.bob.encrypt(Data(repeating: 0, count: 32), jid: f.alice.owner, deviceID: 1), jid: f.bob.owner, deviceID: 2)
                    }
                    let packet = try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2)
                    XCTAssertEqual(packet.isKeyExchange, branch != "regular")
                    let before = f.memory.value(f.bob.owner)
                    let writes = f.memory.writes
                    let consumed = try f.bob.consumedPreKeyIDs()
                    let controls = Set(try f.bob.pendingControlAddresses())
                    var events: [String] = []
                    f.bob.authenticatedReceiveDidCommit = { events.append("commit") }
                    f.memory.failWrites = failure == "write"

                    XCTAssertThrowsError(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
                        replayFingerprint: Data(repeating: 0x73, count: 32),
                        recordingOptOut: {
                            if failure == "policy callback" { throw Failure.injected }
                            if failure == "invalid policy" {
                                return OMEMO2OptOutRequest(jid: f.alice.owner, fingerprint: Data([1]),
                                    protectedDate: nil, reason: nil, historical: false)
                            }
                            return nil
                        }, authenticatedIdentity: { _ in events.append("identity") },
                        validating: { _ in if failure == "validation" { throw Failure.injected } }))

                    XCTAssertEqual(f.memory.value(f.bob.owner), before)
                    XCTAssertEqual(f.memory.writes, writes)
                    XCTAssertEqual(try f.bob.consumedPreKeyIDs(), consumed)
                    XCTAssertEqual(Set(try f.bob.pendingControlAddresses()), controls)
                    XCTAssertTrue(try f.bob.optOutRecords().isEmpty)
                    XCTAssertTrue(events.isEmpty)
                    f.memory.failWrites = false
                    XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
                        replayFingerprint: Data(repeating: 0x73, count: 32),
                        authenticatedIdentity: { _ in events.append("identity") }), material(1))
                    XCTAssertEqual(f.memory.writes, writes + 1)
                    XCTAssertEqual(events, ["identity", "commit"])
                    let after = f.memory.value(f.bob.owner)
                    XCTAssertThrowsError(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
                        replayFingerprint: Data(repeating: 0x73, count: 32)))
                    XCTAssertEqual(f.memory.value(f.bob.owner), after)
                    XCTAssertEqual(events, ["identity", "commit"])
                }
            }
        }
    }

    func testIdentityPolicyFailureForInitialAndExistingKEXLeavesAuthenticRetryEligible() throws {
        for existing in [false, true] {
            let f = try fixture()
            try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
            if existing {
                _ = try f.bob.decrypt(f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2), jid: f.alice.owner, deviceID: 1)
            }
            let packet = try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2)
            let before = f.memory.value(f.bob.owner)
            var observed = 0
            f.bob.authenticatedReceiveDidCommit = { observed += 1 }
            XCTAssertThrowsError(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
                updatingIdentity: { _ in throw Failure.injected }, authenticatedIdentity: { _ in observed += 1 }))
            XCTAssertEqual(f.memory.value(f.bob.owner), before)
            XCTAssertEqual(observed, 0)
            XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1), material(1))
            XCTAssertEqual(observed, 1)
        }
    }

    func testCommitObserverCanUseAnotherInstanceAfterLockReleaseAndCleanupCannotHideAuthenticatedIdentity() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        let packet = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        let sibling = try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory)
        let events = Results<String>()
        let errors = Results<Error>()
        f.bob.authenticatedReceiveDidCommit = {
            events.append("commit")
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    XCTAssertTrue(try sibling.sessionExists(jid: f.alice.owner, deviceID: 1))
                    try sibling.finishCatchUp()
                    events.append("cleanup")
                } catch { errors.append(error) }
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        }

        XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
            authenticatedIdentity: { key in
                XCTAssertEqual(key, try? f.alice.identity().publicKey)
                XCTAssertEqual(try? sibling.consumedPreKeyIDs().count, 1)
                events.append("identity")
            }), material(0))

        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(events.values, ["identity", "commit", "cleanup"])
        XCTAssertTrue(try f.bob.consumedPreKeyIDs().isEmpty)
        XCTAssertTrue(try f.bob.sessionExists(jid: f.alice.owner, deviceID: 1))
    }

    func testReceiveOnlyKnownEKSurvivesConsumedOPKCleanupAndRestartWithoutChangingCurrentIdentityOrControlQueue() throws {
        let f = try fixture()
        let chosen = try selected(f.bundle)
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: chosen)
        let first = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        _ = try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1)
        _ = try f.bob.encrypt(Data(repeating: 0, count: 32), jid: f.alice.owner, deviceID: 1)
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: chosen)
        let reused = try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2)
        let delayed = try f.alice.encrypt(material(2), jid: f.bob.owner, deviceID: 2)
        _ = try f.bob.decrypt(reused, jid: f.alice.owner, deviceID: 1)
        try f.bob.finishCatchUp()
        let restarted = try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory)
        let current = try XCTUnwrap(restarted.sessionMetadata(jid: f.alice.owner, deviceID: 1))
        var identityUpdates = 0

        XCTAssertEqual(try restarted.decrypt(delayed, jid: f.alice.owner, deviceID: 1,
            updatingIdentity: { _ in identityUpdates += 1 }), material(2))

        XCTAssertEqual(identityUpdates, 0)
        XCTAssertEqual(try restarted.sessionMetadata(jid: f.alice.owner, deviceID: 1)?.ephemeralKey, current.ephemeralKey)
        XCTAssertTrue(try XCTUnwrap(restarted.sessionMetadata(jid: f.alice.owner, deviceID: 1, ephemeralKey: reused.ephemeralKey)).receiveOnly)
        XCTAssertTrue(try restarted.pendingControlAddresses().isEmpty)
        XCTAssertTrue(try restarted.consumedPreKeyIDs().isEmpty)
        XCTAssertFalse(try restarted.canRecoverMissingSession(jid: f.alice.owner, deviceID: 1))
    }

    func testSelectiveDeviceDeletionPreservesOtherDeviceSessionControlAndAllKeyMaterial() throws {
        let f = try fixture()
        let other = try XabberOMEMO2Storage(owner: "other-\(UUID().uuidString)@example.test", persistence: f.memory)
        let otherBundle = try other.prepare(deviceID: 3, preKeyCount: 2)
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle), initialControlNeeded: true)
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 3, bundle: selected(otherBundle), initialControlNeeded: true)
        let before = try f.alice.localBundle()
        let otherSession = try f.alice.sessionMetadata(jid: f.bob.owner, deviceID: 3)

        try f.alice.deleteSessions(jid: f.bob.owner, deviceID: 2)

        XCTAssertNil(try f.alice.sessionMetadata(jid: f.bob.owner, deviceID: 2))
        XCTAssertTrue(try f.alice.canRecoverMissingSession(jid: f.bob.owner, deviceID: 2))
        XCTAssertEqual(try f.alice.sessionMetadata(jid: f.bob.owner, deviceID: 3)?.ephemeralKey, otherSession?.ephemeralKey)
        XCTAssertEqual(try f.alice.pendingControlAddresses(), [OMEMO2PeerAddress(jid: f.bob.owner, deviceID: 3)])
        let after = try f.alice.localBundle()
        XCTAssertEqual(after.identityKey, before.identityKey)
        XCTAssertEqual(after.signedPreKey, before.signedPreKey)
        XCTAssertEqual(after.preKeys, before.preKeys)
    }

    func testFailedControlAndSessionDeletionWritesKeepTheirDurableQueueAndSession() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle), initialControlNeeded: true)
        let before = f.memory.value(f.alice.owner)
        f.memory.failWrites = true
        XCTAssertThrowsError(try f.alice.markControlNeeded(jid: f.bob.owner, deviceID: 2, needed: false))
        XCTAssertEqual(f.memory.value(f.alice.owner), before)
        XCTAssertThrowsError(try f.alice.deleteSessions(jid: f.bob.owner, deviceID: 2))
        XCTAssertEqual(f.memory.value(f.alice.owner), before)
        f.memory.failWrites = false
        XCTAssertTrue(try f.alice.sessionExists(jid: f.bob.owner, deviceID: 2))
        XCTAssertEqual(try f.alice.pendingControlAddresses().count, 1)
        try f.alice.markControlNeeded(jid: f.bob.owner, deviceID: 2, needed: false)
        XCTAssertTrue(try f.alice.pendingControlAddresses().isEmpty)
        XCTAssertTrue(try f.alice.sessionExists(jid: f.bob.owner, deviceID: 2))
    }

    func testFailedRemovalIsAtomicAndSuccessfulRemovalIsScopedToOneOwner() throws {
        let f = try fixture()
        let aliceBefore = f.memory.value(f.alice.owner)
        let bobBefore = f.memory.value(f.bob.owner)
        f.memory.failRemoves = true
        XCTAssertThrowsError(try f.alice.removeAllState())
        XCTAssertEqual(f.memory.value(f.alice.owner), aliceBefore)
        XCTAssertEqual(f.memory.value(f.bob.owner), bobBefore)
        f.memory.failRemoves = false

        try f.alice.removeAllState()

        XCTAssertNil(f.memory.value(f.alice.owner))
        XCTAssertEqual(f.memory.value(f.bob.owner), bobBefore)
        XCTAssertThrowsError(try f.alice.identity())
        XCTAssertEqual(try f.bob.localBundle().identityKey, f.bundle.identityKey)
    }

    func testPrepareRejectsDeviceMismatchAndInvalidCountsWithoutMutatingExistingIdentity() throws {
        let f = try fixture()
        let before = f.memory.value(f.alice.owner)
        for deviceID in [0, -1, 2, Int(Int32.max) + 1] {
            XCTAssertThrowsError(try f.alice.prepare(deviceID: deviceID, preKeyCount: 1))
            XCTAssertEqual(f.memory.value(f.alice.owner), before)
        }
        for count in [-1, 0, 1001] {
            XCTAssertThrowsError(try f.alice.prepare(deviceID: 1, preKeyCount: count))
            XCTAssertEqual(f.memory.value(f.alice.owner), before)
        }
        XCTAssertEqual(try f.alice.prepare(deviceID: 1, preKeyCount: 1).preKeys.count, 3,
            "Preparing an existing identity does not replace its OPK inventory")
        XCTAssertEqual(f.memory.value(f.alice.owner), before)
    }

    func testReplenishmentNoOpAndInvalidBoundsPerformNoWriteWhileFailureCanRetryWithoutReusingIDs() throws {
        let f = try fixture()
        let before = f.memory.value(f.bob.owner)
        let writes = f.memory.writes
        for count in [1, 2, 3] { XCTAssertEqual(try f.bob.replenishPreKeys(minimumCount: count).preKeys, f.bundle.preKeys) }
        for count in [-1, 0, 1001] { XCTAssertThrowsError(try f.bob.replenishPreKeys(minimumCount: count)) }
        XCTAssertEqual(f.memory.value(f.bob.owner), before)
        XCTAssertEqual(f.memory.writes, writes)
        f.memory.failWrites = true
        XCTAssertThrowsError(try f.bob.replenishPreKeys(minimumCount: 5))
        XCTAssertEqual(f.memory.value(f.bob.owner), before)
        f.memory.failWrites = false
        let after = try f.bob.replenishPreKeys(minimumCount: 5)
        XCTAssertEqual(after.preKeys.count, 5)
        XCTAssertEqual(Array(after.preKeys.prefix(3)), f.bundle.preKeys)
        XCTAssertEqual(after.preKeys.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(after.identityKey, f.bundle.identityKey)
    }

    func testMaintenanceAndCleanupNoOpsPreserveProtectedBytesAndPerformNoWrite() throws {
        let f = try fixture()
        let before = f.memory.value(f.bob.owner)
        let writes = f.memory.writes
        XCTAssertFalse(try f.bob.maintainKeysIfDue())
        try f.bob.finishCatchUp()
        try f.bob.removeConsumedPreKeys(ids: Set(f.bundle.preKeys.map(\.id)).union([999]))
        try f.bob.replaceOutgoingSessions()
        XCTAssertEqual(f.memory.value(f.bob.owner), before)
        XCTAssertEqual(f.memory.writes, writes)
    }

    func testInvalidReplayFingerprintIsRejectedBeforeAnyCandidateValidationOrCommit() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        let packet = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        let before = f.memory.value(f.bob.owner)
        var callbacks = 0
        f.bob.authenticatedReceiveDidCommit = { callbacks += 1 }
        for size in [0, 1, 31, 33, 64] {
            XCTAssertThrowsError(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
                replayFingerprint: Data(repeating: 0x53, count: size),
                updatingIdentity: { _ in callbacks += 1 }, recordingOptOut: { callbacks += 1; return nil },
                authenticatedIdentity: { _ in callbacks += 1 }, validating: { _ in callbacks += 1 }))
            XCTAssertEqual(f.memory.value(f.bob.owner), before)
        }
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
            replayFingerprint: Data(repeating: 0x53, count: 32)), material(0))
        XCTAssertEqual(callbacks, 1)
    }

    func testMaximumKeyIDsStillDecryptWhilePreKeyAndSignedPreKeyExhaustionCannotWritePartialState() throws {
        let f = try fixture()
        var source = try plist(try XCTUnwrap(f.memory.value(f.bob.owner)))
        var preKeys = try XCTUnwrap(source["preKeys"] as? [[String: Any]])
        preKeys[2]["id"] = UInt32(Int32.max)
        source["preKeys"] = preKeys
        source["nextPreKeyID"] = UInt64(Int32.max) + 1
        source["signedPreKeyID"] = UInt32(Int32.max)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        source["signedPreKeyCreatedAt"] = now
        f.memory.put(try encoded(source), owner: f.bob.owner)
        let bob = try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory,
            now: { now.addingTimeInterval(XabberOMEMO2Storage.signedPreKeyRotationInterval) })
        let bundle = try bob.localBundle()
        try f.alice.initiateSession(jid: bob.owner, deviceID: 2, bundle: selected(bundle, index: 2))
        let packet = try f.alice.encrypt(material(0), jid: bob.owner, deviceID: 2)

        XCTAssertEqual(packet.preKeyID, UInt32(Int32.max))
        XCTAssertEqual(packet.signedPreKeyID, UInt32(Int32.max))
        XCTAssertEqual(try bob.decrypt(packet, jid: f.alice.owner, deviceID: 1), material(0))
        let before = f.memory.value(bob.owner)
        let writes = f.memory.writes
        XCTAssertThrowsError(try bob.replenishPreKeys(minimumCount: 3))
        XCTAssertThrowsError(try bob.maintainKeysIfDue())
        XCTAssertEqual(f.memory.value(bob.owner), before)
        XCTAssertEqual(f.memory.writes, writes)
        XCTAssertEqual(try bob.localBundle().identityKey, f.bundle.identityKey)
        XCTAssertEqual(try bob.consumedPreKeyIDs(), [UInt32(Int32.max)])
    }

    func testReplayReceiptCapacityEvictsOnlyOldestReceiptAndRetainsNewCommittedReplayDenial() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        let packet = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        let capacity = XabberOMEMO2Storage.maximumAuthenticatedReceiveFingerprints
        let fingerprint: (Int) -> Data = { index in
            var value = UInt32(index).bigEndian
            var result = Data(repeating: 0, count: 28)
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
            return result
        }
        var source = try plist(try XCTUnwrap(f.memory.value(f.bob.owner)))
        let prior = (0..<capacity).map(fingerprint)
        source["authenticatedReceiveFingerprints"] = prior
        f.memory.put(try encoded(source), owner: f.bob.owner)
        let newest = fingerprint(capacity)

        XCTAssertEqual(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
            replayFingerprint: newest), material(0))

        let committed = try plist(try XCTUnwrap(f.memory.value(f.bob.owner)))
        let retained = try XCTUnwrap(committed["authenticatedReceiveFingerprints"] as? [Data])
        XCTAssertEqual(retained, Array(prior.dropFirst()) + [newest])
        let before = f.memory.value(f.bob.owner)
        let restarted = try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory)
        XCTAssertThrowsError(try restarted.decrypt(packet, jid: f.alice.owner, deviceID: 1,
            replayFingerprint: newest)) { error in
            guard case OMEMO2StorageError.authenticatedDuplicate = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(f.memory.value(f.bob.owner), before)
    }

    func testMalformedNativeAggregateFieldsFailClosedWithoutWritesOrLegacyReads() throws {
        let f = try fixture()
        let source = try plist(try XCTUnwrap(f.memory.value(f.alice.owner)))
        let writes = f.memory.writes
        let changes: [(String, Any)] = [
            ("backend", "Signal"), ("identityRepresentation", "x25519Scalar"),
            ("deviceID", 0), ("deviceID", Int(Int32.max) + 1),
            ("identityPrivateKey", Data(repeating: 1, count: 31)),
            ("fingerprintPublicKey", Data(repeating: 1, count: 31)),
            ("fingerprintPublicKey", Data(repeating: 1, count: 32)),
            ("signedPreKeyPrivateKey", Data(repeating: 1, count: 31)),
            ("signedPreKeyID", 0), ("signedPreKeyID", UInt64(Int32.max) + 1),
            ("signature", Data(repeating: 1, count: 63)), ("signature", Data(repeating: 1, count: 64)),
            ("nextPreKeyID", 1), ("nextPreKeyID", UInt64(Int32.max) + 2),
            ("authenticatedReceiveFingerprints", [Data(repeating: 1, count: 31)]),
            ("authenticatedReceiveFingerprints", Array(repeating: Data(repeating: 1, count: 32), count: 2)),
            ("authenticatedReceiveFingerprints", Array(repeating: Data(repeating: 1, count: 32), count: XabberOMEMO2Storage.maximumAuthenticatedReceiveFingerprints + 1)),
            ("controlsNeeded", [["jid": "", "deviceID": 1]]),
            ("controlsNeeded", [["jid": f.bob.owner, "deviceID": 0]]),
            ("controlsNeeded", [["jid": f.bob.owner, "deviceID": Int(Int32.max) + 1]])
        ]
        for (index, change) in changes.enumerated() {
            try XCTContext.runActivity(named: "Malformed \(change.0), case \(index)") { _ in
                var changed = source
                changed[change.0] = change.1
                let invalid = try encoded(changed)
                f.memory.put(invalid, owner: f.alice.owner)
                XCTAssertThrowsError(try f.alice.localBundle())
                XCTAssertThrowsError(try f.alice.prepare(deviceID: 1, preKeyCount: 1))
                XCTAssertThrowsError(try f.alice.pendingControlAddresses())
                XCTAssertEqual(f.memory.value(f.alice.owner), invalid)
                XCTAssertEqual(f.memory.writes, writes)
                XCTAssertEqual(f.memory.legacyReads, 0)
            }
        }
    }

    func testMalformedPreKeyRecordsFailClosedAndCannotBeSilentlyReplenished() throws {
        let f = try fixture()
        let source = try plist(try XCTUnwrap(f.memory.value(f.alice.owner)))
        let records = try XCTUnwrap(source["preKeys"] as? [[String: Any]])
        let changes: [(String, Any)] = [("id", 0), ("id", UInt64(Int32.max) + 1),
            ("privateKey", Data(repeating: 1, count: 31)), ("id", records[1]["id"]!)]
        let writes = f.memory.writes
        for (index, change) in changes.enumerated() {
            try XCTContext.runActivity(named: "Malformed OPK \(change.0), case \(index)") { _ in
                var changed = source
                var preKeys = records
                preKeys[0][change.0] = change.1
                changed["preKeys"] = preKeys
                let invalid = try encoded(changed)
                f.memory.put(invalid, owner: f.alice.owner)
                XCTAssertThrowsError(try f.alice.replenishPreKeys(minimumCount: 5))
                XCTAssertThrowsError(try f.alice.consumedPreKeyIDs())
                XCTAssertThrowsError(try f.alice.finishCatchUp())
                XCTAssertEqual(f.memory.value(f.alice.owner), invalid)
                XCTAssertEqual(f.memory.writes, writes)
            }
        }
    }

    func testNonfiniteSignedPreKeyCreationDateFailsClosedInsteadOfPermanentlySuppressingRotation() throws {
        let f = try fixture()
        let source = try plist(try XCTUnwrap(f.memory.value(f.alice.owner)))
        let writes = f.memory.writes
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            var changed = source
            changed["signedPreKeyCreatedAt"] = Date(timeIntervalSince1970: interval)
            let invalid = try encoded(changed)
            let decoded = try plist(invalid)
            XCTAssertFalse(try XCTUnwrap(decoded["signedPreKeyCreatedAt"] as? Date).timeIntervalSince1970.isFinite,
                "Binary plist must retain the nonfinite date for this regression")
            f.memory.put(invalid, owner: f.alice.owner)

            XCTAssertThrowsError(try f.alice.localBundle())
            XCTAssertThrowsError(try f.alice.prepare(deviceID: 1, preKeyCount: 1))
            XCTAssertThrowsError(try f.alice.maintainKeysIfDue())
            XCTAssertEqual(f.memory.value(f.alice.owner), invalid)
            XCTAssertEqual(f.memory.writes, writes)
            XCTAssertEqual(f.memory.legacyReads, 0)
        }
    }

    func testNonfiniteRetiredSignedPreKeyDateFailsClosedInsteadOfRetainingGraceSecretsForever() throws {
        let memory = Memory()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let storage = try XabberOMEMO2Storage(owner: "retired-date-\(UUID().uuidString)@example.test",
            persistence: memory, now: { now })
        _ = try storage.prepare(deviceID: 1, preKeyCount: 1)
        now.addTimeInterval(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        XCTAssertTrue(try storage.maintainKeysIfDue())
        let source = try plist(try XCTUnwrap(memory.value(storage.owner)))
        let retired = try XCTUnwrap(source["retiredSignedPreKeys"] as? [[String: Any]])
        XCTAssertEqual(retired.count, 1)
        let writes = memory.writes
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            var changed = source
            var keys = retired
            keys[0]["retiredAt"] = Date(timeIntervalSince1970: interval)
            changed["retiredSignedPreKeys"] = keys
            let invalid = try encoded(changed)
            let decoded = try plist(invalid)
            let decodedKeys = try XCTUnwrap(decoded["retiredSignedPreKeys"] as? [[String: Any]])
            XCTAssertFalse(try XCTUnwrap(decodedKeys[0]["retiredAt"] as? Date).timeIntervalSince1970.isFinite)
            memory.put(invalid, owner: storage.owner)

            XCTAssertThrowsError(try storage.localBundle())
            XCTAssertThrowsError(try storage.prepare(deviceID: 1, preKeyCount: 1))
            XCTAssertThrowsError(try storage.maintainKeysIfDue())
            XCTAssertEqual(memory.value(storage.owner), invalid)
            XCTAssertEqual(memory.writes, writes)
            XCTAssertEqual(memory.legacyReads, 0)
        }
    }

    func testNonfiniteSessionCreationDateFailsClosedBeforeRestoringOrAdvancingNativeRatchet() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        _ = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        let source = try plist(try XCTUnwrap(f.memory.value(f.alice.owner)))
        let sessions = try XCTUnwrap(source["sessions"] as? [String: [String: Any]])
        let slot = try XCTUnwrap(sessions.keys.first)
        let writes = f.memory.writes
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            var changed = source
            var stored = sessions
            stored[slot]?["createdAt"] = Date(timeIntervalSince1970: interval)
            changed["sessions"] = stored
            let invalid = try encoded(changed)
            let decoded = try plist(invalid)
            let decodedSessions = try XCTUnwrap(decoded["sessions"] as? [String: [String: Any]])
            XCTAssertFalse(try XCTUnwrap(decodedSessions[slot]?["createdAt"] as? Date).timeIntervalSince1970.isFinite)
            f.memory.put(invalid, owner: f.alice.owner)

            XCTAssertThrowsError(try f.alice.localBundle())
            XCTAssertThrowsError(try f.alice.sessionMetadata(jid: f.bob.owner, deviceID: 2))
            XCTAssertThrowsError(try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2))
            XCTAssertEqual(f.memory.value(f.alice.owner), invalid)
            XCTAssertEqual(f.memory.writes, writes)
            XCTAssertEqual(f.memory.legacyReads, 0)
        }
    }

    func testMalformedSessionMetadataAndDanglingCurrentPointerNeverProduceCiphertext() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        _ = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        let source = try plist(try XCTUnwrap(f.memory.value(f.alice.owner)))
        let sessions = try XCTUnwrap(source["sessions"] as? [String: [String: Any]])
        let slot = try XCTUnwrap(sessions.keys.first)
        let changes: [(String, Any)] = [
            ("ephemeralKey", Data(repeating: 1, count: 31)),
            ("ephemeralKey", Data(repeating: 1, count: 32)),
            ("seenIncomingRatchets", [Data(repeating: 1, count: 31)]),
            ("seenIncomingRatchets", Array(repeating: Data(repeating: 1, count: 32), count: OMEMO2Session.maximumReceivedRatchets + 1)),
            ("outgoingPreKey", Data(repeating: 1, count: 31)),
            ("address", ["jid": "", "deviceID": 2]),
            ("address", ["jid": f.bob.owner, "deviceID": 0]),
            ("receiveOnly", true)
        ]
        let writes = f.memory.writes
        for (index, change) in changes.enumerated() {
            try XCTContext.runActivity(named: "Malformed session \(change.0), case \(index)") { _ in
                var changed = source
                var stored = sessions
                stored[slot]?[change.0] = change.1
                changed["sessions"] = stored
                let invalid = try encoded(changed)
                f.memory.put(invalid, owner: f.alice.owner)
                XCTAssertThrowsError(try f.alice.sessionMetadata(jid: f.bob.owner, deviceID: 2))
                XCTAssertThrowsError(try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2))
                XCTAssertEqual(f.memory.value(f.alice.owner), invalid)
                XCTAssertEqual(f.memory.writes, writes)
            }
        }
        var dangling = source
        dangling["sessions"] = [String: Any]()
        let invalid = try encoded(dangling)
        f.memory.put(invalid, owner: f.alice.owner)
        XCTAssertThrowsError(try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2))
        XCTAssertEqual(f.memory.value(f.alice.owner), invalid)
    }

    func testCorruptNativeSnapshotDeniesReceiveSendAndMetadataWithoutFallbackOrMutation() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        _ = try f.bob.decrypt(f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2), jid: f.alice.owner, deviceID: 1)
        let packet = try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2)
        var source = try plist(try XCTUnwrap(f.memory.value(f.bob.owner)))
        var sessions = try XCTUnwrap(source["sessions"] as? [String: [String: Any]])
        let slot = try XCTUnwrap(sessions.keys.first)
        sessions[slot]?["snapshot"] = Data("invalid native snapshot".utf8)
        source["sessions"] = sessions
        let invalid = try encoded(source)
        f.memory.put(invalid, owner: f.bob.owner)
        let writes = f.memory.writes
        var callbacks = 0
        f.bob.authenticatedReceiveDidCommit = { callbacks += 1 }

        XCTAssertThrowsError(try f.bob.decrypt(packet, jid: f.alice.owner, deviceID: 1,
            authenticatedIdentity: { _ in callbacks += 1 }))
        XCTAssertThrowsError(try f.bob.encrypt(material(2), jid: f.alice.owner, deviceID: 1))
        XCTAssertThrowsError(try f.bob.sessionMetadata(jid: f.alice.owner, deviceID: 1))
        XCTAssertFalse(try f.bob.canRecoverMissingSession(jid: f.alice.owner, deviceID: 1))
        XCTAssertEqual(f.memory.value(f.bob.owner), invalid)
        XCTAssertEqual(f.memory.writes, writes)
        XCTAssertEqual(f.memory.legacyReads, 0)
        XCTAssertEqual(callbacks, 0)
    }

    func testSnapshotFromOneOwnerCannotBeReboundByEditingOnlyAggregateOwner() throws {
        let f = try fixture()
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: selected(f.bundle))
        _ = try f.alice.encrypt(material(0), jid: f.bob.owner, deviceID: 2)
        let owner = "transplanted-\(UUID().uuidString)@example.test"
        var source = try plist(try XCTUnwrap(f.memory.value(f.alice.owner)))
        source["owner"] = owner
        let transplanted = try encoded(source)
        f.memory.put(transplanted, owner: owner)
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: f.memory)
        let writes = f.memory.writes

        XCTAssertThrowsError(try storage.sessionMetadata(jid: f.bob.owner, deviceID: 2))
        XCTAssertThrowsError(try storage.encrypt(material(1), jid: f.bob.owner, deviceID: 2))
        XCTAssertEqual(f.memory.value(owner), transplanted)
        XCTAssertEqual(f.memory.writes, writes)
        XCTAssertEqual(f.memory.legacyReads, 0)
        XCTAssertNoThrow(try f.alice.encrypt(material(1), jid: f.bob.owner, deviceID: 2))
    }

    private func fixture() throws -> Fixture {
        let memory = Memory()
        let nonce = UUID().uuidString
        let alice = try XabberOMEMO2Storage(owner: "alice-\(nonce)@example.test", persistence: memory)
        let bob = try XabberOMEMO2Storage(owner: "bob-\(nonce)@example.test", persistence: memory)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 3)
        return Fixture(memory: memory, alice: alice, bob: bob, bundle: try bob.prepare(deviceID: 2, preKeyCount: 3))
    }

    private func selected(_ bundle: OMEMO2LocalBundle, index: Int = 0) throws -> OMEMO2Bundle {
        let key = bundle.preKeys[index]
        return try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
            signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: key.publicKey, preKeyID: key.id)
    }

    private func material(_ value: Int) -> Data { Data(repeating: UInt8(value), count: 48) }

    private func plist(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func encoded(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
