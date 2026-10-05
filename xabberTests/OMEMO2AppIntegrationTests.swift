import CryptoKit
import CryptoSwift
import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

final class OMEMO2AppIntegrationTests: XCTestCase {
    private final class MemoryPersistence: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false
        func load(owner: String) throws -> Data? { records[owner] }
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
        let aliceStore: XabberOMEMO2Storage
        let bobStore: XabberOMEMO2Storage
        let persistence: MemoryPersistence
        let aliceBundle: OMEMO2LocalBundle
        let bobBundle: OMEMO2LocalBundle
    }

    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2AppIntegrationTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        super.tearDown()
    }

    func testOutgoingRepeatedKEXMovesTheCounterAndKeepsOneEKAfterCachedBundleWasDeleted() throws {
        let fixture = try fixture()
        let first = try outgoing(envelope("one", fixture: fixture), fixture: fixture)
        let firstCipher = try ciphertext(first, recipient: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID)
        try deleteCachedBundle(owner: fixture.alice.owner, jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID)

        let second = try outgoing(envelope("two", fixture: fixture), fixture: fixture)
        let secondCipher = try ciphertext(second, recipient: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID)

        XCTAssertTrue(firstCipher.isKeyExchange)
        XCTAssertTrue(secondCipher.isKeyExchange)
        XCTAssertEqual(firstCipher.counter, 0)
        XCTAssertEqual(secondCipher.counter, 1)
        XCTAssertEqual(firstCipher.ephemeralKey, secondCipher.ephemeralKey)
        XCTAssertEqual(try fixture.aliceStore.sessionMetadata(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID)?.sendCounter, 2)
    }

    func testRecipientWithTheSameNumericIDAsTheLocalDeviceStillReceivesAKey() throws {
        let fixture = try fixture(aliceDeviceID: 42, bobDeviceID: 42)

        let encrypted = try outgoing(envelope("same ID", fixture: fixture), fixture: fixture)

        XCTAssertNoThrow(try ciphertext(encrypted, recipient: fixture.bob.owner, deviceID: 42))
        XCTAssertEqual(encrypted.element(forName: "header")?.attributeIntegerValue(forName: "sid"), 42)
    }

    func testIncomingValidSCEAuthenticatesAndCommitsTheSessionBeforeReturningPlaintext() throws {
        let fixture = try fixture()
        let encrypted = try outgoing(envelope("authenticated", fixture: fixture), fixture: fixture)
        let incoming = message(encrypted, fixture: fixture)
        let usedPreKey = try ciphertext(encrypted, recipient: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID).preKeyID

        let decrypted = try XCTUnwrap(fixture.bob.decryptMessage(incoming))

        XCTAssertEqual(decrypted.xmlns(), "urn:xmpp:sce:1")
        XCTAssertEqual(decrypted.element(forName: "content")?.element(forName: "body")?.stringValue, "authenticated")
        XCTAssertTrue(try fixture.bobStore.sessionExists(jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
        XCTAssertFalse(try fixture.bobStore.localBundle().preKeys.contains { $0.id == usedPreKey })
        let reloaded = try XabberOMEMO2Storage(owner: fixture.bob.owner, persistence: fixture.persistence)
        XCTAssertTrue(try reloaded.sessionExists(jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
    }

    func testPayloadMACFailureDoesNotConsumeOPKAndTheUnmodifiedRetrySucceeds() throws {
        let fixture = try fixture()
        let encrypted = try outgoing(envelope("retry", fixture: fixture), fixture: fixture)
        let originalState = fixture.persistence.records[fixture.bob.owner]
        let originalPreKeys = try fixture.bobStore.localBundle().preKeys
        let damaged = try XCTUnwrap(encrypted.copy() as? DDXMLElement)
        let payload = try XCTUnwrap(damaged.element(forName: "payload"))
        var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(payload.stringValue)))
        bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()

        XCTAssertThrowsError(try fixture.bob.decryptMessage(message(damaged, fixture: fixture)))

        XCTAssertEqual(fixture.persistence.records[fixture.bob.owner], originalState)
        XCTAssertEqual(try fixture.bobStore.localBundle().preKeys, originalPreKeys)
        XCTAssertFalse(try fixture.bobStore.sessionExists(jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
        XCTAssertEqual(try fixture.bob.decryptMessage(message(encrypted, fixture: fixture))?
            .element(forName: "content")?.element(forName: "body")?.stringValue, "retry")
    }

    func testAuthenticatedSCEWithTheWrongSenderDoesNotCommitAndALaterValidKEXSucceeds() throws {
        let fixture = try fixture()
        try fixture.aliceStore.initiateSession(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID,
                                               bundle: selectedBundle(fixture.bobBundle))
        let invalid = try envelope("spoofed", fixture: fixture, protectedFrom: "mallory@example.test")
        let encrypted = try syntheticEncryptedPayload(invalid, fixture: fixture)
        let originalState = fixture.persistence.records[fixture.bob.owner]
        let originalPreKeys = try fixture.bobStore.localBundle().preKeys

        XCTAssertThrowsError(try fixture.bob.decryptMessage(message(encrypted, fixture: fixture)))

        XCTAssertEqual(fixture.persistence.records[fixture.bob.owner], originalState)
        XCTAssertEqual(try fixture.bobStore.localBundle().preKeys, originalPreKeys)
        XCTAssertFalse(try fixture.bobStore.sessionExists(jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
        let valid = try syntheticEncryptedPayload(envelope("valid", fixture: fixture), fixture: fixture)
        XCTAssertEqual(try fixture.bob.decryptMessage(message(valid, fixture: fixture))?
            .element(forName: "content")?.element(forName: "body")?.stringValue, "valid")
    }

    func testAuthenticatedSCEWithTheWrongRecipientDoesNotCommit() throws {
        let fixture = try fixture()
        try fixture.aliceStore.initiateSession(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID,
                                               bundle: selectedBundle(fixture.bobBundle))
        let invalid = try envelope("wrong recipient", fixture: fixture, protectedTo: "mallory@example.test")
        let encrypted = try syntheticEncryptedPayload(invalid, fixture: fixture)
        let originalState = fixture.persistence.records[fixture.bob.owner]

        XCTAssertThrowsError(try fixture.bob.decryptMessage(message(encrypted, fixture: fixture)))

        XCTAssertEqual(fixture.persistence.records[fixture.bob.owner], originalState)
        XCTAssertFalse(try fixture.bobStore.sessionExists(jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
    }

    func testExact32ZeroControlHasNoPayloadAndReturnsNoApplicationContent() throws {
        let fixture = try fixture()
        try fixture.aliceStore.initiateSession(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID,
                                               bundle: selectedBundle(fixture.bobBundle))
        let control = try fixture.aliceStore.encrypt(Data(repeating: 0, count: 32), jid: fixture.bob.owner,
                                                    deviceID: fixture.bobBundle.deviceID)
        let encrypted = encryptedElement(ciphertext: control, payload: nil, fixture: fixture)

        let result = try fixture.bob.decryptMessage(message(encrypted, fixture: fixture))

        XCTAssertNil(result)
        XCTAssertNil(encrypted.element(forName: "payload"))
        XCTAssertTrue(try fixture.bobStore.sessionExists(jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
    }

    func testAlreadyAcceptedCiphertextIsConsumedAsReplayWithoutAnotherCommit() throws {
        let fixture = try fixture()
        let encrypted = try outgoing(envelope("one delivery", fixture: fixture), fixture: fixture)
        XCTAssertNotNil(try fixture.bob.decryptMessage(message(encrypted, fixture: fixture)))
        let acceptedState = fixture.persistence.records[fixture.bob.owner]

        let replay = try fixture.bob.decryptMessage(message(encrypted, fixture: fixture))

        XCTAssertNil(replay)
        XCTAssertEqual(fixture.persistence.records[fixture.bob.owner], acceptedState)
    }

    func testLegacy33ByteBundleCannotCreateAnOutgoingOMEMO2Session() throws {
        let fixture = try fixture()
        let realm = try WRealm.safe()
        let primary = SignalIdentityStorageItem.genRpimary(owner: fixture.alice.owner, jid: fixture.bob.owner,
                                                           deviceId: fixture.bobBundle.deviceID)
        let identity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
        try realm.write {
            identity.identityKey = (Data([5]) + fixture.bobBundle.fingerprintPublicKey).base64EncodedString()
            identity.protocolProfile = SessionRecordStorageItem.legacyProfile
        }

        XCTAssertThrowsError(try fixture.alice.encryptMessage(message: envelope("blocked", fixture: fixture), to: fixture.bob.owner))
        XCTAssertFalse(try fixture.aliceStore.sessionExists(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID))
    }

    func testAutomaticACKTargetsOnlyTheSenderAndConfirmsKEXWithoutAResponseLoop() throws {
        let fixture = try fixture()
        let otherDevice = try XabberOMEMO2Storage(owner: "other-device-\(UUID().uuidString)@example.test", persistence: fixture.persistence)
        let otherBundle = try otherDevice.prepare(deviceID: 43, preKeyCount: 3)
        try cacheBundle(otherBundle, owner: fixture.bob.owner, jid: fixture.alice.owner)
        try advertiseDevices(to: fixture.bob, jid: fixture.alice.owner, ids: [fixture.aliceBundle.deviceID, 43])
        var bobControls = [XMPPMessage]()
        var aliceControls = [XMPPMessage]()
        fixture.bob.omemo2ControlSender = { bobControls.append($0) }
        fixture.alice.omemo2ControlSender = { aliceControls.append($0) }
        let encrypted = try outgoing(envelope("initiate", fixture: fixture), fixture: fixture)

        XCTAssertNotNil(try fixture.bob.decryptMessage(message(encrypted, fixture: fixture)))

        XCTAssertEqual(bobControls.count, 1)
        let ack = try XCTUnwrap(bobControls.first)
        XCTAssertEqual(ack.to?.bare, fixture.alice.owner)
        XCTAssertNil(ack.element(forName: "body"))
        let ackEncrypted = try XCTUnwrap(ack.element(forName: "encrypted", xmlns: OMEMO2BundleCodec.namespace))
        XCTAssertNil(ackEncrypted.element(forName: "payload"))
        let header = try XCTUnwrap(ackEncrypted.element(forName: "header"))
        XCTAssertEqual(header.attributeIntegerValue(forName: "sid"), fixture.bobBundle.deviceID)
        let groups = header.elements(forName: "keys")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.attributeStringValue(forName: "jid"), fixture.alice.owner)
        XCTAssertEqual(groups.first?.elements(forName: "key").count, 1)
        XCTAssertFalse(try fixture.bobStore.sessionExists(jid: fixture.alice.owner, deviceID: 43))
        let ackCiphertext = try ciphertext(ackEncrypted, recipient: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID)
        XCTAssertFalse(ackCiphertext.isKeyExchange)
        ack.addAttribute(withName: "from", stringValue: fixture.bob.owner + "/ios")

        XCTAssertNil(try fixture.alice.decryptMessage(ack))
        XCTAssertTrue(aliceControls.isEmpty)
        XCTAssertFalse(try XCTUnwrap(fixture.aliceStore.sessionMetadata(jid: fixture.bob.owner,
                                                    deviceID: fixture.bobBundle.deviceID)).keyExchangePending)
        let regular = try outgoing(envelope("confirmed", fixture: fixture), fixture: fixture)
        XCTAssertFalse(try ciphertext(regular, recipient: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID).isKeyExchange)
    }

    func testControlAndReplayAreConsumedByLivePushAndStanzaRoutesWithoutAFailureBubble() throws {
        let fixture = try fixture()
        try fixture.aliceStore.initiateSession(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID,
                                               bundle: selectedBundle(fixture.bobBundle))
        let live = try controlMessage(fixture: fixture)
        XCTAssertTrue(fixture.bob.didReceiveOmemoMessage(live))
        XCTAssertTrue(fixture.bob.didReceiveOmemoMessage(live))
        XCTAssertNil(live.element(forName: "body"))
        XCTAssertFalse(try XCTUnwrap(live.compactXMLString).contains("Failed to decrypt"))

        let push = try controlMessage(fixture: fixture)
        XCTAssertNil(fixture.bob.didReceiveOmemoMessageFromPush(push).message)
        XCTAssertNil(fixture.bob.didReceiveOmemoMessageFromPush(push).message)
        XCTAssertNil(push.element(forName: "body"))

        let stanza = try controlMessage(fixture: fixture)
        XCTAssertNil(fixture.bob.modifyOmemoStanza(message: stanza).message)
        XCTAssertNil(fixture.bob.modifyOmemoStanza(message: stanza).message)
        XCTAssertNil(stanza.element(forName: "body"))
    }

    func testOutgoingPersistenceFailureReleasesNoCiphertextAndDoesNotAdvanceTheCounter() throws {
        let fixture = try fixture()
        try fixture.aliceStore.initiateSession(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID,
                                               bundle: selectedBundle(fixture.bobBundle))
        let before = fixture.persistence.records[fixture.alice.owner]
        fixture.persistence.failWrites = true

        XCTAssertThrowsError(try fixture.alice.encryptMessage(message: envelope("must persist", fixture: fixture), to: fixture.bob.owner))

        XCTAssertEqual(fixture.persistence.records[fixture.alice.owner], before)
        fixture.persistence.failWrites = false
        let retried = try outgoing(envelope("retry", fixture: fixture), fixture: fixture)
        XCTAssertEqual(try ciphertext(retried, recipient: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID).counter, 0)
    }

    func testAuthenticatedReplacementIdentityCannotInheritTrustAfterItsCachedBundleWasRemoved() throws {
        let fixture = try fixture()
        try deleteCachedBundle(owner: fixture.bob.owner, jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID)
        let replacedFixture = try replacingAliceIdentity(fixture: fixture)
        let encrypted = try syntheticEncryptedPayload(envelope("replacement identity", fixture: replacedFixture), fixture: replacedFixture)

        _ = try fixture.bob.decryptMessage(message(encrypted, fixture: replacedFixture))

        let realm = try WRealm.safe()
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: fixture.bob.owner, jid: fixture.alice.owner,
                                                               deviceId: fixture.aliceBundle.deviceID)))
        XCTAssertEqual(device.state, .fingerprintChanged)
        XCTAssertThrowsError(try fixture.bob.encryptMessage(message: try envelope("secret", fixture: fixture), to: fixture.alice.owner))
    }

    func testExistingAuthenticatedSessionPreservesTrustWhenTheCachedBundleIsMissing() throws {
        let fixture = try fixture()
        let first = try outgoing(envelope("first", fixture: fixture), fixture: fixture)
        _ = try fixture.bob.decryptMessage(message(first, fixture: fixture))
        try deleteCachedBundle(owner: fixture.bob.owner, jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID)
        let second = try outgoing(envelope("same identity", fixture: fixture), fixture: fixture)

        _ = try fixture.bob.decryptMessage(message(second, fixture: fixture))

        let realm = try WRealm.safe()
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: fixture.bob.owner, jid: fixture.alice.owner,
                                                               deviceId: fixture.aliceBundle.deviceID)))
        XCTAssertEqual(device.state, .trusted)
        XCTAssertEqual(device.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: fixture.aliceBundle.identityKey))
    }

    func testReplacementIdentityRevokesTrustHeldByThePreviousSession() throws {
        let fixture = try fixture()
        let first = try outgoing(envelope("first", fixture: fixture), fixture: fixture)
        _ = try fixture.bob.decryptMessage(message(first, fixture: fixture))
        try deleteCachedBundle(owner: fixture.bob.owner, jid: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID)
        let replacedFixture = try replacingAliceIdentity(fixture: fixture)
        let encrypted = try syntheticEncryptedPayload(envelope("new identity", fixture: replacedFixture), fixture: replacedFixture)

        _ = try fixture.bob.decryptMessage(message(encrypted, fixture: replacedFixture))

        let realm = try WRealm.safe()
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: fixture.bob.owner, jid: fixture.alice.owner,
                                                               deviceId: fixture.aliceBundle.deviceID)))
        XCTAssertEqual(device.state, .fingerprintChanged)
        XCTAssertFalse(device.isTrustedByCertificate)
        XCTAssertThrowsError(try fixture.bob.encryptMessage(message: try envelope("secret", fixture: fixture), to: fixture.alice.owner))
    }

    func testTrustedFingerprintMismatchWithCachedBundleCannotCreateAnOutgoingSession() throws {
        let fixture = try fixture()
        let replacement = try OMEMO2Context(error: ()).generateIdentity()
        let replacementFingerprint = try Omemo2IdentityRepresentation.fingerprint(for: replacement.publicKey)
        let realm = try WRealm.safe()
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: fixture.alice.owner, jid: fixture.bob.owner,
                                                               deviceId: fixture.bobBundle.deviceID)))
        try realm.write { device.fingerprint = replacementFingerprint }
        let originalState = fixture.persistence.records[fixture.alice.owner]

        XCTAssertThrowsError(try fixture.alice.encryptMessage(message: envelope("must not reach stale identity", fixture: fixture),
                                                             to: fixture.bob.owner))

        XCTAssertEqual(fixture.persistence.records[fixture.alice.owner], originalState)
        XCTAssertFalse(try fixture.aliceStore.sessionExists(jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID))
        XCTAssertEqual(device.state, .trusted)
        XCTAssertEqual(device.fingerprint, replacementFingerprint)
    }

    func testCurrentTrustedSessionCanSendWhileCachedBundleStillHasThePreviousIdentity() throws {
        let fixture = try fixture()
        let replacement = try replacingAliceIdentity(fixture: fixture)
        let incoming = try syntheticEncryptedPayload(envelope("new identity", fixture: replacement), fixture: replacement)
        XCTAssertNotNil(try fixture.bob.decryptMessage(message(incoming, fixture: replacement)))
        let realm = try WRealm.safe()
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: fixture.bob.owner, jid: fixture.alice.owner,
                                                               deviceId: fixture.aliceBundle.deviceID)))
        try realm.write { device.state = .trusted }
        let before = try XCTUnwrap(fixture.bobStore.sessionMetadata(jid: fixture.alice.owner,
                                                                   deviceID: fixture.aliceBundle.deviceID))
        let cachedIdentity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: fixture.bob.owner, jid: fixture.alice.owner,
                                                                deviceId: fixture.aliceBundle.deviceID)))
        XCTAssertEqual(cachedIdentity.identityKey, fixture.aliceBundle.identityKey.base64EncodedString())
        XCTAssertNotEqual(cachedIdentity.identityKey, replacement.aliceBundle.identityKey.base64EncodedString())

        let encrypted = try XCTUnwrap(fixture.bob.encryptMessage(message: envelope("trusted reply", fixture: fixture,
                                                    protectedFrom: fixture.bob.owner, protectedTo: fixture.alice.owner),
                                                                  to: fixture.alice.owner))

        XCTAssertNoThrow(try ciphertext(encrypted, recipient: fixture.alice.owner, deviceID: fixture.aliceBundle.deviceID))
        let after = try XCTUnwrap(fixture.bobStore.sessionMetadata(jid: fixture.alice.owner,
                                                                  deviceID: fixture.aliceBundle.deviceID))
        XCTAssertEqual(after.remoteIdentityKey, replacement.aliceBundle.identityKey)
        XCTAssertEqual(after.ephemeralKey, before.ephemeralKey)
        XCTAssertEqual(after.sendCounter, before.sendCounter + 1)
    }

    func testDelayedArchivedKEXCannotOverwriteTheTrustedReplacementIdentity() throws {
        let fixture = try fixture()
        let first = try outgoing(envelope("old first", fixture: fixture), fixture: fixture)
        let delayed = try outgoing(envelope("old delayed", fixture: fixture), fixture: fixture)
        XCTAssertNotNil(try fixture.bob.decryptMessage(message(first, fixture: fixture)))
        let replacement = try replacingAliceIdentity(fixture: fixture)
        let newer = try syntheticEncryptedPayload(envelope("replacement", fixture: replacement), fixture: replacement)
        XCTAssertNotNil(try fixture.bob.decryptMessage(message(newer, fixture: replacement)))
        let realm = try WRealm.safe()
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: fixture.bob.owner, jid: fixture.alice.owner,
                                                               deviceId: fixture.aliceBundle.deviceID)))
        try realm.write { device.state = .trusted }
        let trustedFingerprint = try Omemo2IdentityRepresentation.fingerprint(for: replacement.aliceBundle.identityKey)
        XCTAssertEqual(device.fingerprint, trustedFingerprint)
        let currentEK = try XCTUnwrap(fixture.bobStore.sessionMetadata(jid: fixture.alice.owner,
                                                                      deviceID: fixture.aliceBundle.deviceID)).ephemeralKey

        let archived = try XCTUnwrap(fixture.bob.decryptMessage(message(delayed, fixture: fixture)))

        XCTAssertEqual(archived.element(forName: "content")?.element(forName: "body")?.stringValue, "old delayed")
        XCTAssertEqual(device.state, .trusted)
        XCTAssertEqual(device.fingerprint, trustedFingerprint)
        let current = try XCTUnwrap(fixture.bobStore.sessionMetadata(jid: fixture.alice.owner,
                                                                    deviceID: fixture.aliceBundle.deviceID))
        XCTAssertEqual(current.ephemeralKey, currentEK)
        XCTAssertEqual(current.remoteIdentityKey, replacement.aliceBundle.identityKey)
    }

    private func replacingAliceIdentity(fixture: Fixture) throws -> Fixture {
        let replacement = try XabberOMEMO2Storage(owner: "replacement-\(UUID().uuidString)@example.test", persistence: fixture.persistence)
        let replacementBundle = try replacement.prepare(deviceID: fixture.aliceBundle.deviceID, preKeyCount: 3)
        let currentBobBundle = try fixture.bobStore.localBundle()
        try replacement.initiateSession(jid: fixture.bob.owner, deviceID: currentBobBundle.deviceID,
                                        bundle: selectedBundle(currentBobBundle))
        return Fixture(alice: fixture.alice, bob: fixture.bob, aliceStore: replacement,
                       bobStore: fixture.bobStore, persistence: fixture.persistence,
                       aliceBundle: replacementBundle, bobBundle: currentBobBundle)
    }

    private func controlMessage(fixture: Fixture) throws -> XMPPMessage {
        let ciphertext = try fixture.aliceStore.encrypt(Data(repeating: 0, count: 32), jid: fixture.bob.owner,
                                                        deviceID: fixture.bobBundle.deviceID)
        return message(encryptedElement(ciphertext: ciphertext, payload: nil, fixture: fixture), fixture: fixture)
    }

    private func fixture(aliceDeviceID: Int = 41, bobDeviceID: Int = 42) throws -> Fixture {
        let suffix = UUID().uuidString.lowercased()
        let aliceJID = "alice-\(suffix)@example.test"
        let bobJID = "bob-\(suffix)@example.test"
        let persistence = MemoryPersistence()
        let aliceStore = try XabberOMEMO2Storage(owner: aliceJID, persistence: persistence)
        let bobStore = try XabberOMEMO2Storage(owner: bobJID, persistence: persistence)
        let aliceBundle = try aliceStore.prepare(deviceID: aliceDeviceID, preKeyCount: 3)
        let bobBundle = try bobStore.prepare(deviceID: bobDeviceID, preKeyCount: 3)
        let alice = OmemoManager(withOwner: aliceJID)
        let bob = OmemoManager(withOwner: bobJID)
        alice.omemo2Storage = aliceStore
        bob.omemo2Storage = bobStore
        try alice.ensureOMEMO2Prepared()
        try bob.ensureOMEMO2Prepared()
        try cacheBundle(aliceBundle, owner: bobJID, jid: aliceJID)
        try cacheBundle(bobBundle, owner: aliceJID, jid: bobJID)
        try advertiseDevices(to: alice, jid: aliceJID, ids: [aliceDeviceID])
        try advertiseDevices(to: alice, jid: bobJID, ids: [bobDeviceID])
        try advertiseDevices(to: bob, jid: bobJID, ids: [bobDeviceID])
        try advertiseDevices(to: bob, jid: aliceJID, ids: [aliceDeviceID])
        return Fixture(alice: alice, bob: bob, aliceStore: aliceStore, bobStore: bobStore,
                       persistence: persistence, aliceBundle: aliceBundle, bobBundle: bobBundle)
    }

    private func advertiseDevices(to manager: OmemoManager, jid: String, ids: [Int]) throws {
        let devices = ids.map { "<device id='\($0)'/>" }.joined()
        let headline = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(jid)' type='headline'>
          <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='urn:xmpp:omemo:2:devices'><item id='current'>
              <devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices>
            </item></items>
          </event>
        </message>
        """)
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(headline))
    }

    private func cacheBundle(_ bundle: OMEMO2LocalBundle, owner: String, jid: String) throws {
        let realm = try WRealm.safe()
        let identity = SignalIdentityStorageItem()
        identity.owner = owner
        identity.jid = jid
        identity.deviceId = bundle.deviceID
        identity.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: bundle.deviceID)
        identity.identityKey = bundle.identityKey.base64EncodedString()
        identity.signedPreKey = bundle.signedPreKey.base64EncodedString()
        identity.signedPreKeyId = Int(bundle.signedPreKeyID)
        identity.signedPreKeySignature = bundle.signature.base64EncodedString()
        identity.protocolProfile = OMEMO2BundleCodec.namespace
        let device = SignalDeviceStorageItem()
        device.owner = owner
        device.jid = jid
        device.deviceId = bundle.deviceID
        device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: bundle.deviceID)
        device.state = .trusted
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        let preKeys = bundle.preKeys.map { key -> SignalPreKeysStorageItem in
            let result = SignalPreKeysStorageItem()
            result.owner = owner
            result.jid = jid
            result.deviceId = bundle.deviceID
            result.pkId = Int(key.id)
            result.keyUUID = UUID().uuidString
            result.primary = result.keyUUID
            result.preKey = key.publicKey.base64EncodedString()
            return result
        }
        try realm.write {
            realm.add(identity, update: .modified)
            realm.add(device, update: .modified)
            realm.add(preKeys, update: .modified)
        }
    }

    private func deleteCachedBundle(owner: String, jid: String, deviceID: Int) throws {
        let realm = try WRealm.safe()
        let primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: deviceID)
        let keys = realm.objects(SignalPreKeysStorageItem.self).filter("owner == %@ AND jid == %@ AND deviceId == %@", owner, jid, deviceID)
        try realm.write {
            if let identity = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary) { realm.delete(identity) }
            realm.delete(keys)
        }
    }

    private func selectedBundle(_ bundle: OMEMO2LocalBundle) throws -> OMEMO2Bundle {
        let key = try XCTUnwrap(bundle.preKeys.first)
        return try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                               signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                               preKey: key.publicKey, preKeyID: key.id)
    }

    private func envelope(_ body: String, fixture: Fixture, protectedFrom: String? = nil, protectedTo: String? = nil) throws -> String {
        let envelope = DDXMLElement(name: "envelope", xmlns: "urn:xmpp:sce:1")
        let content = DDXMLElement(name: "content")
        let bodyElement = DDXMLElement(name: "body", xmlns: "jabber:client")
        bodyElement.stringValue = body
        content.addChild(bodyElement)
        envelope.addChild(content)
        envelope.addChild(DDXMLElement(name: "rpad", stringValue: "fixture padding"))
        let from = DDXMLElement(name: "from")
        from.addAttribute(withName: "jid", stringValue: protectedFrom ?? fixture.alice.owner)
        envelope.addChild(from)
        let to = DDXMLElement(name: "to")
        to.addAttribute(withName: "jid", stringValue: protectedTo ?? fixture.bob.owner)
        envelope.addChild(to)
        return try XCTUnwrap(envelope.compactXMLString)
    }

    private func outgoing(_ envelope: String, fixture: Fixture) throws -> DDXMLElement {
        try XCTUnwrap(fixture.alice.encryptMessage(message: envelope, to: fixture.bob.owner))
    }

    private func ciphertext(_ encrypted: DDXMLElement, recipient: String, deviceID: Int) throws -> OMEMO2Ciphertext {
        let key = try XCTUnwrap(encrypted.element(forName: "header")?.elements(forName: "keys")
            .first { $0.attributeStringValue(forName: "jid") == recipient }?
            .elements(forName: "key").first { $0.attributeIntegerValue(forName: "rid") == deviceID })
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(key.stringValue)))
        return try OMEMO2Ciphertext(data: bytes, keyExchange: key.attributeBoolValue(forName: "kex"))
    }

    private func message(_ encrypted: DDXMLElement, fixture: Fixture) -> XMPPMessage {
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: fixture.bob.owner))
        message.addAttribute(withName: "from", stringValue: fixture.alice.owner + "/ios")
        message.addAttribute(withName: "id", stringValue: UUID().uuidString)
        message.addChild(encrypted.copy() as! DDXMLElement)
        return message
    }

    /// Independently constructs the outer payload so invalid authenticated SCE
    /// can exercise the receive boundary even if outgoing validation rejects it.
    private func syntheticEncryptedPayload(_ plaintext: String, fixture: Fixture) throws -> DDXMLElement {
        let contentKey = Data(repeating: 0x31, count: 32)
        let material = try HKDF(password: contentKey.bytes, salt: [UInt8](repeating: 0, count: 32),
                                info: Array("OMEMO Payload".utf8), keyLength: 80, variant: .sha2(.sha256)).calculate()
        let cipher = try AES(key: Array(material.prefix(32)), blockMode: CBC(iv: Array(material.suffix(16))), padding: .pkcs7)
        let payload = Data(try cipher.encrypt(Array(plaintext.utf8)))
        let mac = Data(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: payload,
                           using: SymmetricKey(data: Data(material[32..<64]))).prefix(16))
        let wrapped = try fixture.aliceStore.encrypt(contentKey + mac, jid: fixture.bob.owner, deviceID: fixture.bobBundle.deviceID)
        return encryptedElement(ciphertext: wrapped, payload: payload, fixture: fixture)
    }

    private func encryptedElement(ciphertext: OMEMO2Ciphertext, payload: Data?, fixture: Fixture) -> DDXMLElement {
        let encrypted = DDXMLElement(name: "encrypted", xmlns: OMEMO2BundleCodec.namespace)
        let header = DDXMLElement(name: "header", xmlns: OMEMO2BundleCodec.namespace)
        header.addAttribute(withName: "sid", integerValue: fixture.aliceBundle.deviceID)
        let keys = DDXMLElement(name: "keys", xmlns: OMEMO2BundleCodec.namespace)
        keys.addAttribute(withName: "jid", stringValue: fixture.bob.owner)
        let key = DDXMLElement(name: "key", xmlns: OMEMO2BundleCodec.namespace)
        key.stringValue = ciphertext.data.base64EncodedString()
        key.addAttribute(withName: "rid", integerValue: fixture.bobBundle.deviceID)
        key.addAttribute(withName: "kex", stringValue: ciphertext.isKeyExchange ? "true" : "false")
        keys.addChild(key)
        header.addChild(keys)
        encrypted.addChild(header)
        if let payload {
            let payloadElement = DDXMLElement(name: "payload", xmlns: OMEMO2BundleCodec.namespace)
            payloadElement.stringValue = payload.base64EncodedString()
            encrypted.addChild(payloadElement)
        }
        return encrypted
    }
}
