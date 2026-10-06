import Foundation
import RealmSwift
import SignalProtocolObjC
import XCTest
import XMPPFramework
@testable import xabber

final class OMEMO2NormativeSessionRecoveryTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false
        var failLoads = false
        func load(owner: String) throws -> Data? {
            if failLoads { throw OMEMO2StorageError.stateUnavailable }
            return records[owner]
        }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private struct Fixture {
        let alice: OmemoManager
        let bob: OmemoManager
        let memory: Memory
        let aliceBundle: OMEMO2LocalBundle
        let bobBundle: OMEMO2LocalBundle
        var aliceStore: XabberOMEMO2Storage { alice.omemo2Storage! }
        var bobStore: XabberOMEMO2Storage { bob.omemo2Storage! }
    }
    private var originalRealm: Realm.Configuration!
    private var keeper: Realm!
    override func setUpWithError() throws {
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N07-\(UUID())")
        keeper = try WRealm.safe()
    }
    override func tearDown() {
        keeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testManualReplacementPreservesIdentityDevicePreKeysTrustAndHistory() throws {
        let f = try fixture()
        _ = try content(f)
        let before = try f.aliceStore.localBundle()
        let trust = try device(owner: f.alice.owner, jid: f.bob.owner, id: f.bobBundle.deviceID)
        let trusted = SignalTrustedIdentityStoreageItem()
        trusted.owner = f.alice.owner; trusted.jid = f.bob.owner; trusted.deviceId = f.bobBundle.deviceID
        trusted.primary = SignalTrustedIdentityStoreageItem.genPrimary(owner: f.alice.owner, jid: f.bob.owner, deviceId: f.bobBundle.deviceID)
        trusted.identity = f.bobBundle.identityKey
        let history = MessageStanzaStorageItem()
        history.owner = f.alice.owner; history.primary = "n07-history"; history.stanza = "encrypted-history"
        try keeper.write { keeper.add(trusted); keeper.add(history) }
        let current = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))

        try f.alice.replaceOMEMO2Sessions()

        let after = try f.aliceStore.localBundle()
        XCTAssertEqual(after.identityKey, before.identityKey)
        XCTAssertEqual(after.deviceID, before.deviceID)
        XCTAssertEqual(after.signedPreKey, before.signedPreKey)
        XCTAssertEqual(after.preKeys, before.preKeys)
        XCTAssertEqual(trust.state, .trusted)
        XCTAssertEqual(trusted.identity, f.bobBundle.identityKey)
        XCTAssertEqual(history.stanza, "encrypted-history")
        XCTAssertNil(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        let archived = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID, ephemeralKey: current.ephemeralKey))
        XCTAssertTrue(archived.receiveOnly)
        XCTAssertEqual(archived.sendCounter, current.sendCounter)
    }

    func testManualReplacementIsOneAtomicWriteAndSaveFailureKeepsOutgoingSession() throws {
        let f = try fixture(); _ = try content(f)
        let before = f.memory.records[f.alice.owner]
        let metadata = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        f.memory.failWrites = true
        XCTAssertThrowsError(try f.alice.replaceOMEMO2Sessions())
        XCTAssertEqual(f.memory.records[f.alice.owner], before)
        f.memory.failWrites = false
        let wire = try content(f)
        XCTAssertEqual(try cipher(wire, to: f.bob.owner, id: f.bobBundle.deviceID).ephemeralKey, metadata.ephemeralKey)
        XCTAssertEqual(try cipher(wire, to: f.bob.owner, id: f.bobBundle.deviceID).counter, metadata.sendCounter)
    }

    func testManualReplacementRetainsOldSnapshotForDelayedAuthenticatedRegularCiphertext() throws {
        let f = try fixture(); try established(f)
        let delayed = try f.bob.makeOMEMO2Control(jid: f.alice.owner, deviceID: f.aliceBundle.deviceID)
        delayed.addAttribute(withName: "from", stringValue: f.bob.owner)
        let old = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        try f.alice.replaceOMEMO2Sessions()

        guard case .consumed(.control) = f.alice.prepareIncoming(delayed) else { return XCTFail("delayed old control remains decryptable") }

        XCTAssertNil(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        XCTAssertTrue(try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID, ephemeralKey: old.ephemeralKey)).receiveOnly)
    }

    func testNextSendAfterReplacementBlocksCachedBundleAndRequestsFreshBundleOnce() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var requests: [(String, Int, String)] = []
        f.alice.omemo2FreshBundleRequester = { requests.append(($0, $1, $2)) }
        for _ in 0..<3 { XCTAssertThrowsError(try content(f)) }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, f.bob.owner)
        XCTAssertEqual(requests.first?.1, f.bobBundle.deviceID)
        XCTAssertNil(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
    }

    func testCurrentFreshBundleResponseProducesNewEKAndNoPreviouslySelectedOPK() throws {
        let f = try fixture(); let initial = try content(f)
        let old = try cipher(initial, to: f.bob.owner, id: f.bobBundle.deviceID)
        try f.alice.replaceOMEMO2Sessions()
        var request = ""
        f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(f.bobBundle, from: f.bob.owner, id: request)))

        let next = try cipher(content(f), to: f.bob.owner, id: f.bobBundle.deviceID)

        XCTAssertTrue(next.isKeyExchange)
        XCTAssertEqual(next.counter, 0)
        XCTAssertNotEqual(next.ephemeralKey, old.ephemeralKey)
        XCTAssertNotEqual(next.preKeyID, old.preKeyID)
        XCTAssertEqual(try device(owner: f.alice.owner, jid: f.bob.owner, id: f.bobBundle.deviceID).state, .trusted)
    }

    func testUncorrelatedBundleHeadlineCannotAuthorizeManualReplacement() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        f.alice.omemo2FreshBundleRequester = { _, _, _ in }
        let items = try bundleItems(f.bobBundle)
        XCTAssertTrue(try f.alice.onContactBundleReceive(items: items, jid: f.bob.owner))
        XCTAssertThrowsError(try content(f))
    }

    func testWrongSenderAndDeviceCannotAuthorizeFreshBundle() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var id = ""; f.alice.omemo2FreshBundleRequester = { _, _, value in id = value }
        XCTAssertThrowsError(try content(f))
        XCTAssertFalse(f.alice.handleOMEMO2FreshBundleResponse(try response(f.bobBundle, from: "mallory@example.test", id: id)))
        XCTAssertThrowsError(try content(f))
        let other = try XabberOMEMO2Storage(owner: "other-\(UUID())@example.test", persistence: f.memory).prepare(deviceID: 99, preKeyCount: 3)
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(other, from: f.bob.owner, id: id)))
        XCTAssertThrowsError(try content(f))
    }

    func testStaleFreshBundleResponseCannotUnlockANewerManualResetGeneration() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var ids: [String] = []; f.alice.omemo2FreshBundleRequester = { _, _, id in ids.append(id) }
        XCTAssertThrowsError(try content(f))
        let stale = try response(f.bobBundle, from: f.bob.owner, id: try XCTUnwrap(ids.first))
        try f.alice.replaceOMEMO2Sessions()
        XCTAssertFalse(f.alice.handleOMEMO2FreshBundleResponse(stale))
        XCTAssertThrowsError(try content(f))
        XCTAssertEqual(ids.count, 2)
    }

    func testRestartRetainsFreshBundleGateAndArchivedSnapshot() throws {
        let f = try fixture(); _ = try content(f)
        let old = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        try f.alice.replaceOMEMO2Sessions()
        let restored = OmemoManager(withOwner: f.alice.owner)
        restored.omemo2Storage = try XabberOMEMO2Storage(owner: f.alice.owner, persistence: f.memory)
        var requests = 0; restored.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        XCTAssertThrowsError(try restored.encryptMessage(message: envelope(f), to: f.bob.owner))
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(try XCTUnwrap(restored.omemo2Storage?.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID, ephemeralKey: old.ephemeralKey)).receiveOnly)
    }

    func testFreshBundleAuthorizationSaveFailureKeepsManualGateAndReleasesNoCiphertext() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var ids: [String] = []; f.alice.omemo2FreshBundleRequester = { _, _, id in ids.append(id) }
        XCTAssertThrowsError(try content(f))
        let before = f.memory.records[f.alice.owner]
        f.memory.failWrites = true
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(f.bobBundle, from: f.bob.owner, id: try XCTUnwrap(ids.first))))
        XCTAssertEqual(f.memory.records[f.alice.owner], before)
        f.memory.failWrites = false
        XCTAssertThrowsError(try content(f))
    }

    func testFreshReplacementBundleWithOnlyPreviouslyUsedOPKIsBlocked() throws {
        let f = try fixture(); let used = try cipher(content(f), to: f.bob.owner, id: f.bobBundle.deviceID).preKeyID
        try f.alice.replaceOMEMO2Sessions()
        var id = ""; f.alice.omemo2FreshBundleRequester = { _, _, value in id = value }
        XCTAssertThrowsError(try content(f))
        let b = f.bobBundle
        let repeated = OMEMO2LocalBundle(deviceID: b.deviceID, identityKey: b.identityKey, fingerprintPublicKey: b.fingerprintPublicKey,
                                        signedPreKey: b.signedPreKey, signedPreKeyID: b.signedPreKeyID, signature: b.signature,
                                        preKeys: b.preKeys.filter { $0.id == used })
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(repeated, from: f.bob.owner, id: id)))
        XCTAssertThrowsError(try content(f))
    }

    func testValidRegularWithoutAnySessionRequestsFreshRecoveryAndSendsOnlyEmptyKEX() throws {
        let f = try fixture(); try established(f)
        let regular = try content(f)
        XCTAssertFalse(try cipher(regular, to: f.bob.owner, id: f.bobBundle.deviceID).isKeyExchange)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        var requests: [String] = []; var controls: [XMPPMessage] = []
        f.bob.omemo2FreshBundleRequester = { _, _, id in requests.append(id) }
        f.bob.omemo2ControlSender = { controls.append($0) }
        assertFailed(f.bob.prepareIncoming(regular))
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(controls.isEmpty)
        XCTAssertTrue(f.bob.handleOMEMO2FreshBundleResponse(try response(f.aliceBundle, from: f.alice.owner, id: try XCTUnwrap(requests.first))))
        XCTAssertEqual(controls.count, 1)
        let recovery = try XCTUnwrap(controls.first)
        XCTAssertNil(recovery.element(forName: "body"))
        let encrypted = try XCTUnwrap(recovery.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        XCTAssertNil(encrypted.element(forName: "payload", xmlns: OmemoManager.xmlns))
        XCTAssertTrue(try cipher(recovery, to: f.alice.owner, id: f.aliceBundle.deviceID).isKeyExchange)
    }

    func testMissingSessionRecoveryDoesNotGrantTrustOrAllowUserContent() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let d = try device(owner: f.bob.owner, jid: f.alice.owner, id: f.aliceBundle.deviceID)
        try keeper.write { d.state = .unknown }
        var request = ""; var controls = 0
        f.bob.omemo2FreshBundleRequester = { _, _, id in request = id }; f.bob.omemo2ControlSender = { _ in controls += 1 }
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertTrue(f.bob.handleOMEMO2FreshBundleResponse(try response(f.aliceBundle, from: f.alice.owner, id: request)))
        XCTAssertEqual(controls, 1)
        XCTAssertEqual(d.state, .unknown)
        XCTAssertThrowsError(try f.bob.encryptMessage(message: envelope(f, reverse: true), to: f.alice.owner))
    }

    func testExistingSessionMACFailureDoesNotFetchReplaceOrEmitControl() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        let key = try XCTUnwrap(regular.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "header")?.element(forName: "keys")?.element(forName: "key"))
        var data = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue)); data[2] ^= 1; key.stringValue = data.base64EncodedString()
        let before = f.memory.records[f.bob.owner]
        var requests = 0; var controls = 0
        f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }; f.bob.omemo2ControlSender = { _ in controls += 1 }
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertEqual(requests, 0); XCTAssertEqual(controls, 0); XCTAssertEqual(f.memory.records[f.bob.owner], before)
    }

    func testArchivedOnlySessionAuthenticationFailureDoesNotStartMissingSessionRecovery() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bob.replaceOMEMO2Sessions()
        let key = try XCTUnwrap(regular.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "header")?.element(forName: "keys")?.element(forName: "key"))
        var data = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue)); data[2] ^= 1; key.stringValue = data.base64EncodedString()
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(regular)); XCTAssertEqual(requests, 0)
    }

    func testMalformedRegularWithoutSessionDoesNotRequestRecovery() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let key = try XCTUnwrap(regular.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "header")?.element(forName: "keys")?.element(forName: "key"))
        key.stringValue = Data([1, 2, 3]).base64EncodedString()
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(regular)); XCTAssertEqual(requests, 0)
    }

    func testMissingSessionStorageFailureDoesNotRequestRecoveryOrGenerateIdentity() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let before = f.memory.records
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        f.memory.failLoads = true
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertEqual(requests, 0); XCTAssertEqual(f.memory.records, before)
    }

    func testIncomingKEXFailureDoesNotUseMissingSessionRecovery() throws {
        let f = try fixture(); let kex = try content(f)
        let payload = try XCTUnwrap(kex.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload"))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue)); bytes[0] ^= 1; payload.stringValue = bytes.base64EncodedString()
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(kex)); XCTAssertEqual(requests, 0)
    }

    func testAuthenticatedSCEFailureDoesNotResetExistingRegularSession() throws {
        let f = try fixture(); try established(f)
        let sealed = try Omemo2PayloadCodec.seal(envelope(f, protectedFrom: "mallory@example.test"))
        let key = try f.alice.doubleRatchet(hmac: sealed.keyAndMAC, jid: f.bob.owner, deviceId: f.bobBundle.deviceID)
        let message = try wire(f, key: key, payload: sealed.ciphertext)
        let before = f.memory.records[f.bob.owner]
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(message))
        XCTAssertEqual(requests, 0); XCTAssertEqual(f.memory.records[f.bob.owner], before)
    }

    func testFreshAuthorizationDoesNotPermitLaterUncorrelatedCacheOverwrite() throws {
        let f = try fixture(); let used = try cipher(content(f), to: f.bob.owner, id: f.bobBundle.deviceID).preKeyID
        try f.alice.replaceOMEMO2Sessions()
        var id = ""; f.alice.omemo2FreshBundleRequester = { _, _, value in id = value }
        XCTAssertThrowsError(try content(f))
        let current = f.bobBundle
        let unused = current.preKeys.filter { $0.id != used }
        let fetched = OMEMO2LocalBundle(deviceID: current.deviceID, identityKey: current.identityKey, fingerprintPublicKey: current.fingerprintPublicKey,
                                       signedPreKey: current.signedPreKey, signedPreKeyID: current.signedPreKeyID, signature: current.signature,
                                       preKeys: [unused[0]])
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(fetched, from: f.bob.owner, id: id)))
        let unrelated = OMEMO2LocalBundle(deviceID: current.deviceID, identityKey: current.identityKey, fingerprintPublicKey: current.fingerprintPublicKey,
                                         signedPreKey: current.signedPreKey, signedPreKeyID: current.signedPreKeyID, signature: current.signature,
                                         preKeys: [unused[1]])
        XCTAssertTrue(try f.alice.onContactBundleReceive(items: bundleItems(unrelated), jid: f.bob.owner))
        XCTAssertThrowsError(try content(f))
        XCTAssertNil(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: current.deviceID))
    }

    func testFreshBundleRequestTimeoutAllowsNewAttemptAndOldReplyCannotAuthorize() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        f.alice.omemo2MaintenanceNow = { time }
        var ids: [String] = []; f.alice.omemo2FreshBundleRequester = { _, _, id in ids.append(id) }
        XCTAssertThrowsError(try content(f))
        time.addTimeInterval(OmemoManager.omemo2PublicationIQTimeout)
        XCTAssertThrowsError(try content(f))
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(f.alice.handleOMEMO2FreshBundleResponse(try response(f.bobBundle, from: f.bob.owner, id: try XCTUnwrap(ids.first))))
        XCTAssertThrowsError(try content(f))
    }

    func testMalformedFreshBundleAndIQErrorLeaveResetGateClosed() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var ids: [String] = []; f.alice.omemo2FreshBundleRequester = { _, _, id in ids.append(id) }
        XCTAssertThrowsError(try content(f))
        let bad = try response(f.bobBundle, from: f.bob.owner, id: try XCTUnwrap(ids.first))
        bad.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item")?.element(forName: "bundle")?.element(forName: "spks")?.stringValue = Data(repeating: 0, count: 64).base64EncodedString()
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(bad))
        XCTAssertThrowsError(try content(f))
        let error = XMPPIQ(iqType: .error, elementID: try XCTUnwrap(ids.last))
        error.addAttribute(withName: "from", stringValue: f.bob.owner)
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(error))
        XCTAssertThrowsError(try content(f))
    }

    func testRecoveryResponseAfterSessionWasAcceptedDoesNotReplaceIt() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        var request = ""; f.bob.omemo2FreshBundleRequester = { _, _, id in request = id }
        assertFailed(f.bob.prepareIncoming(regular))
        let current = try f.bobStore.localBundle()
        try f.aliceStore.initiateSession(jid: f.bob.owner, deviceID: current.deviceID, bundle: OMEMO2PublishedBundle(current).selectedBundle(preKeyID: try XCTUnwrap(current.preKeys.first).id))
        guard case .verified = f.bob.prepareIncoming(try content(f)) else { return XCTFail("new incoming KEX") }
        let accepted = try XCTUnwrap(f.bobStore.sessionMetadata(jid: f.alice.owner, deviceID: f.aliceBundle.deviceID))
        let before = f.memory.records[f.bob.owner]
        XCTAssertTrue(f.bob.handleOMEMO2FreshBundleResponse(try response(f.aliceBundle, from: f.alice.owner, id: request)))
        XCTAssertEqual(f.memory.records[f.bob.owner], before)
        XCTAssertEqual(try f.bobStore.sessionMetadata(jid: f.alice.owner, deviceID: f.aliceBundle.deviceID)?.ephemeralKey, accepted.ephemeralKey)
    }

    func testActualBundleIQRouteCompletesFreshResetAuthorization() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var request = ""; f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        XCTAssertTrue(f.alice.read(withIQ: try response(f.bobBundle, from: f.bob.owner, id: request)))
        XCTAssertNoThrow(try content(f))
    }

    func testGlobalReplacementInvalidatesEveryPeerAndClearsPendingControls() throws {
        let f = try fixture(); _ = try content(f)
        let peer = try XabberOMEMO2Storage(owner: "second-\(UUID())@example.test", persistence: f.memory)
        let b = try peer.prepare(deviceID: 77, preKeyCount: 3)
        try f.aliceStore.initiateSession(jid: peer.owner, deviceID: b.deviceID, bundle: OMEMO2PublishedBundle(b).selectedBundle(preKeyID: try XCTUnwrap(b.preKeys.first).id))
        let second = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: peer.owner, deviceID: b.deviceID))
        try f.aliceStore.markControlNeeded(jid: peer.owner, deviceID: b.deviceID, needed: true)
        try f.alice.replaceOMEMO2Sessions()
        XCTAssertNil(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        XCTAssertNil(try f.aliceStore.sessionMetadata(jid: peer.owner, deviceID: b.deviceID))
        XCTAssertTrue(try XCTUnwrap(f.aliceStore.sessionMetadata(jid: peer.owner, deviceID: b.deviceID, ephemeralKey: second.ephemeralKey)).receiveOnly)
        XCTAssertTrue(try f.aliceStore.pendingControlAddresses().isEmpty)
    }

    func testDisabledAccountDoesNotStartAutomaticMissingSessionRecovery() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let account = try XCTUnwrap(keeper.object(ofType: AccountStorageItem.self, forPrimaryKey: f.bob.owner))
        try keeper.write { account.isEncryptionEnabled = false }
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(regular)); XCTAssertEqual(requests, 0)
    }

    func testUnknownDeviceListRefreshResumesMissingSessionRecoveryWithoutAnotherMessage() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let snapshot = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: keeper, owner: f.bob.owner, jid: f.alice.owner))
        try keeper.write { snapshot.isKnown = false }
        var refreshes: [String] = []; var requests: [String] = []; var controls: [XMPPMessage] = []
        f.bob.omemo2DeviceListRequester = { refreshes.append($0) }
        f.bob.omemo2FreshBundleRequester = { _, _, id in requests.append(id) }
        f.bob.omemo2ControlSender = { controls.append($0) }
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertEqual(refreshes, [f.alice.owner]); XCTAssertTrue(requests.isEmpty)
        try publishDevices(to: f.bob, jid: f.alice.owner, ids: [f.aliceBundle.deviceID])
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(f.bob.handleOMEMO2FreshBundleResponse(try response(f.aliceBundle, from: f.alice.owner, id: try XCTUnwrap(requests.first))))
        XCTAssertEqual(controls.count, 1)
        XCTAssertNil(controls.first?.element(forName: "body"))
        XCTAssertTrue(try cipher(try XCTUnwrap(controls.first), to: f.alice.owner, id: f.aliceBundle.deviceID).isKeyExchange)
    }

    func testRefreshedRemovedSenderDoesNotInitiateARecoverySession() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let snapshot = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: keeper, owner: f.bob.owner, jid: f.alice.owner))
        try keeper.write { snapshot.isKnown = false }
        f.bob.omemo2DeviceListRequester = { _ in }
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(regular))
        try publishDevices(to: f.bob, jid: f.alice.owner, ids: [])
        try publishDevices(to: f.bob, jid: f.alice.owner, ids: [f.aliceBundle.deviceID])
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(try f.bobStore.sessionExists(jid: f.alice.owner, deviceID: f.aliceBundle.deviceID))
    }

    func testExpiredMissingSessionCandidateCannotResumeFromALateList() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let snapshot = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: keeper, owner: f.bob.owner, jid: f.alice.owner))
        try keeper.write { snapshot.isKnown = false }
        var now = Date(timeIntervalSince1970: 1_700_000_000); f.bob.omemo2MaintenanceNow = { now }
        f.bob.omemo2DeviceListRequester = { _ in }
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(regular))
        now.addTimeInterval(OmemoManager.omemo2PublicationIQTimeout)
        try publishDevices(to: f.bob, jid: f.alice.owner, ids: [f.aliceBundle.deviceID])
        XCTAssertEqual(requests, 0)
    }

    func testExpiredFreshBundleResponseCannotAuthorizeWithoutAnotherSend() throws {
        let f = try fixture(); _ = try content(f); try f.alice.replaceOMEMO2Sessions()
        var now = Date(timeIntervalSince1970: 1_700_000_000); f.alice.omemo2MaintenanceNow = { now }
        var request = ""; f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        now.addTimeInterval(OmemoManager.omemo2PublicationIQTimeout)
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(f.bobBundle, from: f.bob.owner, id: request)))
        XCTAssertThrowsError(try content(f))
    }

    func testKnownCachedListWithoutSIDRefreshResumesRecoveryFromItsNewActiveMembership() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let snapshot = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: keeper, owner: f.bob.owner, jid: f.alice.owner))
        try keeper.write { snapshot.deviceIDs.removeAll() }
        var refreshes = 0; var requests = 0
        f.bob.omemo2DeviceListRequester = { _ in refreshes += 1 }
        f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertEqual(refreshes, 1); XCTAssertEqual(requests, 0)
        try publishDevices(to: f.bob, jid: f.alice.owner, ids: [f.aliceBundle.deviceID])
        XCTAssertEqual(requests, 1)
    }

    func testFreshChangedPeerIdentityPreservesManualReceiveOnlySnapshotsAndRevokesTrust() throws {
        let f = try fixture(); try established(f)
        let delayed = try f.bob.makeOMEMO2Control(jid: f.alice.owner, deviceID: f.aliceBundle.deviceID)
        delayed.addAttribute(withName: "from", stringValue: f.bob.owner)
        let old = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID))
        try f.alice.replaceOMEMO2Sessions()
        var request = ""; f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        let replacement = try XabberOMEMO2Storage(owner: "replacement-\(UUID().uuidString.lowercased())@example.test", persistence: f.memory)
        let bundle = try replacement.prepare(deviceID: f.bobBundle.deviceID, preKeyCount: 3)
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(bundle, from: f.bob.owner, id: request)))
        let d = try device(owner: f.alice.owner, jid: f.bob.owner, id: f.bobBundle.deviceID)
        XCTAssertEqual(d.state, .fingerprintChanged)
        XCTAssertEqual(d.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey))
        XCTAssertThrowsError(try content(f))
        guard case .consumed(.control) = f.alice.prepareIncoming(delayed) else { return XCTFail("old delayed ciphertext must survive manual replacement") }
        let archived = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID, ephemeralKey: old.ephemeralKey))
        XCTAssertTrue(archived.receiveOnly)
        XCTAssertEqual(archived.remoteIdentityKey, f.bobBundle.identityKey)
        XCTAssertEqual(d.state, .fingerprintChanged)
        XCTAssertEqual(d.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey))
    }

    func testMalformedOuterAESPayloadWithoutSessionCannotRequestRecovery() throws {
        let f = try fixture(); try established(f); let regular = try content(f)
        try f.bobStore.deleteSessions(jid: f.alice.owner)
        let payload = try XCTUnwrap(regular.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload", xmlns: OmemoManager.xmlns))
        payload.stringValue = Data([1]).base64EncodedString()
        var requests = 0; f.bob.omemo2FreshBundleRequester = { _, _, _ in requests += 1 }
        let before = f.memory.records[f.bob.owner]
        assertFailed(f.bob.prepareIncoming(regular))
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(f.memory.records[f.bob.owner], before)
    }

    func testMigratedPendingSessionWithoutOPKMetadataCannotReuseItsConsumedCandidateID() throws {
        let f = try fixture(); let first = try cipher(content(f), to: f.bob.owner, id: f.bobBundle.deviceID)
        XCTAssertTrue(first.isKeyExchange)
        try removeOutgoingOPKMetadata(from: f.alice.owner, memory: f.memory)
        try f.alice.replaceOMEMO2Sessions()
        var request = ""; f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        let b = f.bobBundle
        let repeated = OMEMO2LocalBundle(deviceID: b.deviceID, identityKey: b.identityKey, fingerprintPublicKey: b.fingerprintPublicKey,
                                        signedPreKey: b.signedPreKey, signedPreKeyID: b.signedPreKeyID, signature: b.signature,
                                        preKeys: b.preKeys.filter { $0.id == first.preKeyID })
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(repeated, from: f.bob.owner, id: request)))
        XCTAssertThrowsError(try content(f))
        XCTAssertEqual(try f.aliceStore.localBundle().identityKey, f.aliceBundle.identityKey)
        XCTAssertTrue(try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: b.deviceID, ephemeralKey: try XCTUnwrap(first.ephemeralKey))).receiveOnly)
    }

    func testMigratedAcknowledgedSessionWithoutOPKMetadataCannotReuseItsCandidateID() throws {
        let f = try fixture(); let wire = try content(f); let first = try cipher(wire, to: f.bob.owner, id: f.bobBundle.deviceID)
        var controls: [XMPPMessage] = []; f.bob.omemo2ControlSender = { controls.append($0) }
        guard case .verified = f.bob.prepareIncoming(wire) else { return XCTFail("valid fixture KEX") }
        let ack = try XCTUnwrap(controls.first); ack.addAttribute(withName: "from", stringValue: f.bob.owner)
        guard case .consumed(.control) = f.alice.prepareIncoming(ack) else { return XCTFail("valid fixture ACK") }
        XCTAssertFalse(try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID)).keyExchangePending)
        let oldCounter = try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: f.bobBundle.deviceID)?.sendCounter
        try removeOutgoingOPKMetadata(from: f.alice.owner, memory: f.memory)
        try f.alice.replaceOMEMO2Sessions()
        var request = ""; f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        let b = f.bobBundle
        let repeated = OMEMO2LocalBundle(deviceID: b.deviceID, identityKey: b.identityKey, fingerprintPublicKey: b.fingerprintPublicKey,
                                        signedPreKey: b.signedPreKey, signedPreKeyID: b.signedPreKeyID, signature: b.signature,
                                        preKeys: b.preKeys.filter { $0.id == first.preKeyID })
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(repeated, from: f.bob.owner, id: request)))
        XCTAssertThrowsError(try content(f))
        let archived = try XCTUnwrap(f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: b.deviceID, ephemeralKey: try XCTUnwrap(first.ephemeralKey)))
        XCTAssertTrue(archived.receiveOnly); XCTAssertEqual(archived.sendCounter, oldCounter)
        XCTAssertEqual(try f.aliceStore.localBundle().deviceID, f.aliceBundle.deviceID)
    }

    func testExplicitManualReplacementCanReplaceAnUnrestorableOldSnapshotWithoutDeletingIt() throws {
        let f = try fixture(); let first = try cipher(content(f), to: f.bob.owner, id: f.bobBundle.deviceID)
        try removeOutgoingOPKMetadata(from: f.alice.owner, memory: f.memory)
        let broken = Data([0xff, 0x01])
        try corruptSnapshots(owner: f.alice.owner, memory: f.memory, snapshot: broken)
        try f.alice.replaceOMEMO2Sessions()
        var request = ""; f.alice.omemo2FreshBundleRequester = { _, _, id in request = id }
        XCTAssertThrowsError(try content(f))
        let b = f.bobBundle
        let fresh = OMEMO2LocalBundle(deviceID: b.deviceID, identityKey: b.identityKey, fingerprintPublicKey: b.fingerprintPublicKey,
                                     signedPreKey: b.signedPreKey, signedPreKeyID: b.signedPreKeyID, signature: b.signature,
                                     preKeys: b.preKeys.filter { $0.id != first.preKeyID })
        XCTAssertTrue(f.alice.handleOMEMO2FreshBundleResponse(try response(fresh, from: f.bob.owner, id: request)))
        let next = try cipher(content(f), to: f.bob.owner, id: b.deviceID)
        XCTAssertTrue(next.isKeyExchange); XCTAssertNotEqual(next.ephemeralKey, first.ephemeralKey)
        XCTAssertEqual(try f.aliceStore.localBundle().identityKey, f.aliceBundle.identityKey)
        XCTAssertEqual(try f.aliceStore.localBundle().deviceID, f.aliceBundle.deviceID)
        let data = try XCTUnwrap(f.memory.records[f.alice.owner])
        let state = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let archived = try XCTUnwrap(state["sessions"] as? [String: [String: Any]]).values.filter { ($0["snapshot"] as? Data) == broken }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?["receiveOnly"] as? Bool, true)
        XCTAssertEqual(try device(owner: f.alice.owner, jid: f.bob.owner, id: b.deviceID).state, .trusted)
    }

    func testNonmanualCorruptArchivedInspectionDoesNotPermitANewOutgoingSession() throws {
        let f = try fixture(); _ = try content(f)
        try removeOutgoingOPKMetadata(from: f.alice.owner, memory: f.memory)
        try corruptSnapshots(owner: f.alice.owner, memory: f.memory, snapshot: Data([0xff, 0x01]), archiveOnly: true)
        let before = f.memory.records[f.alice.owner]
        XCTAssertThrowsError(try content(f))
        XCTAssertEqual(f.memory.records[f.alice.owner], before)
    }

    private func corruptSnapshots(owner: String, memory: Memory, snapshot: Data, archiveOnly: Bool = false) throws {
        let data = try XCTUnwrap(memory.records[owner])
        var state = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var sessions = try XCTUnwrap(state["sessions"] as? [String: [String: Any]])
        for key in Array(sessions.keys) {
            sessions[key]?["snapshot"] = snapshot
            if archiveOnly { sessions[key]?["receiveOnly"] = true }
        }
        state["sessions"] = sessions
        if archiveOnly { state["currentSessions"] = [String: String]() }
        memory.records[owner] = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private func removeOutgoingOPKMetadata(from owner: String, memory: Memory) throws {
        let data = try XCTUnwrap(memory.records[owner])
        var state = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var sessions = try XCTUnwrap(state["sessions"] as? [String: [String: Any]])
        for key in Array(sessions.keys) { sessions[key]?.removeValue(forKey: "outgoingPreKey") }
        state["sessions"] = sessions
        memory.records[owner] = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private func publishDevices(to manager: OmemoManager, jid: String, ids: [Int]) throws {
        let devices = ids.map { "<device id='\($0)'/>" }.joined()
        let message = try XMPPMessage(xmlString: "<message xmlns='jabber:client' type='headline' from='\(jid)'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></event></message>")
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(message))
    }

    private func fixture() throws -> Fixture {
        let memory = Memory(); let suffix = UUID().uuidString.lowercased()
        let alice = OmemoManager(withOwner: "alice-\(suffix)@example.test")
        let bob = OmemoManager(withOwner: "bob-\(suffix)@example.test")
        alice.omemo2Storage = try XabberOMEMO2Storage(owner: alice.owner, persistence: memory)
        bob.omemo2Storage = try XabberOMEMO2Storage(owner: bob.owner, persistence: memory)
        let a = try alice.omemo2Storage!.prepare(deviceID: 41, preKeyCount: 5)
        let b = try bob.omemo2Storage!.prepare(deviceID: 42, preKeyCount: 5)
        try alice.ensureOMEMO2Prepared(); try bob.ensureOMEMO2Prepared()
        alice.omemo2ControlSender = { _ in }; bob.omemo2ControlSender = { _ in }
        for (m, bundle, jid) in [(alice, b, bob.owner), (bob, a, alice.owner)] {
            let account = AccountStorageItem()
            account.jid = m.owner; account.isEncryptionEnabled = true
            try keeper.write { keeper.add(account, update: .modified) }
            XCTAssertTrue(try m.onContactBundleReceive(items: bundleItems(bundle), jid: jid))
            let d = try device(owner: m.owner, jid: jid, id: bundle.deviceID)
            try keeper.write { d.state = .trusted }
            for (listedJID, ids) in [(m.owner, [m === alice ? a.deviceID : b.deviceID]), (jid, [bundle.deviceID])] {
                let xml = try XMPPMessage(xmlString: "<message xmlns='jabber:client' type='headline' from='\(listedJID)'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(ids.map { "<device id='\($0)'/>" }.joined())</devices></item></items></event></message>")
                XCTAssertTrue(m.onContactDeviceListReceiveHeadline(xml))
            }
        }
        return Fixture(alice: alice, bob: bob, memory: memory, aliceBundle: a, bobBundle: b)
    }
    private func content(_ f: Fixture) throws -> XMPPMessage {
        let encryptedValue = try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner)
        let encrypted = try XCTUnwrap(encryptedValue)
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: f.bob.owner))
        message.addAttribute(withName: "from", stringValue: f.alice.owner)
        message.addChild(encrypted); return message
    }
    private func established(_ f: Fixture) throws {
        let first = try content(f)
        var replies: [XMPPMessage] = []
        f.bob.omemo2ControlSender = { replies.append($0) }
        guard case .verified = f.bob.prepareIncoming(first) else { return XCTFail("valid initial KEX") }
        XCTAssertEqual(replies.count, 1)
        let reply = try XCTUnwrap(replies.first); reply.addAttribute(withName: "from", stringValue: f.bob.owner)
        guard case .consumed(.control) = f.alice.prepareIncoming(reply) else { return XCTFail("valid KEX ACK") }
        f.bob.omemo2ControlSender = { _ in }
    }
    private func envelope(_ f: Fixture, reverse: Bool = false, protectedFrom: String? = nil) -> String {
        let from = protectedFrom ?? (reverse ? f.bob.owner : f.alice.owner)
        let to = reverse ? f.alice.owner : f.bob.owner
        return "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>N07 secret</body></content><rpad>fixture padding</rpad><from jid='\(from)'/><to jid='\(to)'/></envelope>"
    }
    private func cipher(_ message: XMPPMessage, to jid: String, id: Int) throws -> OMEMO2Ciphertext {
        let encrypted = try XCTUnwrap(message.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        let header = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns))
        let keys = try XCTUnwrap(header.elements(forName: "keys").first { $0.attributeStringValue(forName: "jid") == jid })
        let key = try XCTUnwrap(keys.elements(forName: "key").first { $0.attributeStringValue(forName: "rid") == String(id) })
        return try OMEMO2Ciphertext(data: Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue)), keyExchange: key.attributeStringValue(forName: "kex") == "true")
    }
    private func wire(_ f: Fixture, key: DDXMLElement, payload: Data) throws -> XMPPMessage {
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: f.bob.owner))
        message.addAttribute(withName: "from", stringValue: f.alice.owner)
        let encrypted = DDXMLElement(name: "encrypted", xmlns: OmemoManager.xmlns)
        let header = DDXMLElement(name: "header", xmlns: OmemoManager.xmlns)
        header.addAttribute(withName: "sid", integerValue: f.aliceBundle.deviceID)
        let keys = DDXMLElement(name: "keys", xmlns: OmemoManager.xmlns)
        keys.addAttribute(withName: "jid", stringValue: f.bob.owner); keys.addChild(key); header.addChild(keys); encrypted.addChild(header)
        let p = DDXMLElement(name: "payload", xmlns: OmemoManager.xmlns); p.stringValue = payload.base64EncodedString(); encrypted.addChild(p)
        message.addChild(encrypted); return message
    }
    private func bundleItems(_ bundle: OMEMO2LocalBundle) throws -> DDXMLElement {
        let items = DDXMLElement(name: "items", xmlns: "http://jabber.org/protocol/pubsub")
        items.addAttribute(withName: "node", stringValue: OmemoManager.xmlns + ":bundles")
        items.addChild(try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(bundle))); return items
    }
    private func response(_ bundle: OMEMO2LocalBundle, from jid: String, id: String) throws -> XMPPIQ {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(try bundleItems(bundle))
        let iq = XMPPIQ(iqType: .result, elementID: id, child: pubsub)
        iq.addAttribute(withName: "from", stringValue: jid)
        return try XMPPIQ(xmlString: XCTUnwrap(iq.compactXMLString))
    }
    private func device(owner: String, jid: String, id: Int) throws -> SignalDeviceStorageItem {
        try XCTUnwrap(keeper.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: id)))
    }
    private func assertFailed(_ result: OMEMOReceiveResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed = result else { return XCTFail("failure must remain locally visible", file: file, line: line) }
    }
}
