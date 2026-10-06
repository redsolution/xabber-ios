import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

/// N05 exercises the normal manager boundary with an already prepared account:
/// reconnecting or invoking storage.prepare manually is not part of each action.
final class OMEMO2NormativeKeyMaintenanceTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ interval: TimeInterval) { date.addTimeInterval(interval) }
    }
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failSaves = false
        var writes = 0
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failSaves { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
            writes += 1
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private final class Stream: XMPPStream {
        var elements: [DDXMLElement] = []
        var authenticated = true
        override var isAuthenticated: Bool { authenticated }
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }
    private final class Scheduler {
        var entries: [(Date, DispatchWorkItem)] = []
        func runDue(at date: Date) {
            let due = entries.filter { $0.0 <= date }
            entries.removeAll { $0.0 <= date }
            due.forEach { if !$0.1.isCancelled { $0.1.perform() } }
        }
    }
    private struct Fixture {
        let manager: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let clock: Clock
        let stream: Stream
        let scheduler: Scheduler
    }
    private var originalRealm: Realm.Configuration!
    private var realmKeeper: Realm?
    private var owners: [String] = []

    override func setUp() {
        super.setUp()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "N05-\(UUID())")
        realmKeeper = try? WRealm.safe()
    }
    override func tearDown() {
        for owner in owners { CredentialsManager.shared.removeDeviceId(for: owner) }
        owners.removeAll()
        realmKeeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testContinuousConnectionPreparationRotatesOverdueSPKAndUpdatesPublicProjection() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        _ = try f.manager.ensureOMEMO2Prepared()

        let after = try f.storage.localBundle()
        XCTAssertEqual(after.signedPreKeyID, before.signedPreKeyID + 1)
        XCTAssertNotEqual(after.signedPreKey, before.signedPreKey)
        XCTAssertEqual(after.identityKey, before.identityKey)
        XCTAssertEqual(after.deviceID, before.deviceID)
        let identity = try ownIdentity(f)
        XCTAssertEqual(identity.signedPreKeyId, Int(after.signedPreKeyID))
        XCTAssertEqual(identity.signedPreKey, after.signedPreKey.base64EncodedString())
        XCTAssertFalse(identity.isPublicated)
        XCTAssertTrue(f.manager.shouldPublicate)
    }

    func testRepeatedActivityAtTheSameDueTimeRotatesOnlyOnceWithoutAdditionalSecretWrites() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        _ = try f.manager.ensureOMEMO2Prepared()
        let writesAfterFirst = f.memory.writes
        let committed = f.memory.records[f.manager.owner]
        for _ in 0..<8 { _ = try f.manager.ensureOMEMO2Prepared() }

        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, before.signedPreKeyID + 1)
        XCTAssertEqual(f.memory.writes, writesAfterFirst)
        XCTAssertEqual(f.memory.records[f.manager.owner], committed)
    }

    func testActivityBeforeWeeklyBoundaryPreservesSPKAndSecretState() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        let committed = f.memory.records[f.manager.owner]
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval - 1)

        _ = try f.manager.ensureOMEMO2Prepared()

        XCTAssertEqual(try f.storage.localBundle().signedPreKey, before.signedPreKey)
        XCTAssertEqual(f.memory.records[f.manager.owner], committed)
        XCTAssertFalse(f.manager.shouldPublicate)
    }

    func testOutgoingControlUsesTheNormalDueMaintenanceBoundaryWithoutResettingSession() throws {
        let f = try fixture()
        let peer = try sender(clock: f.clock)
        let remote = try peer.localBundle()
        try f.storage.initiateSession(jid: peer.owner, deviceID: remote.deviceID, bundle: selected(remote))
        let beforeBundle = try f.storage.localBundle()
        let beforeSession = try XCTUnwrap(f.storage.sessionMetadata(jid: peer.owner, deviceID: remote.deviceID))
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        let control = try f.manager.makeOMEMO2Control(jid: peer.owner, deviceID: remote.deviceID)

        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, beforeBundle.signedPreKeyID + 1)
        let afterSession = try XCTUnwrap(f.storage.sessionMetadata(jid: peer.owner, deviceID: remote.deviceID))
        XCTAssertEqual(afterSession.ephemeralKey, beforeSession.ephemeralKey)
        XCTAssertEqual(afterSession.sendCounter, beforeSession.sendCounter + 1)
        let encrypted = try XCTUnwrap(control.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        XCTAssertNil(encrypted.element(forName: "payload", xmlns: OmemoManager.xmlns))
        XCTAssertTrue(f.manager.shouldPublicate)
    }

    func testIncomingDelayedOldSPKKeyExchangeRotatesAndRemainsDecryptableDuringGrace() throws {
        let f = try fixture()
        let peer = try sender(clock: f.clock)
        let old = try f.storage.localBundle()
        try peer.initiateSession(jid: f.manager.owner, deviceID: old.deviceID, bundle: selected(old))
        let plaintext = Data(repeating: 0x51, count: 48)
        let delayed = try peer.encrypt(plaintext, jid: f.manager.owner, deviceID: old.deviceID)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        let opened = try f.manager.doubleUnratched(delayed.data.base64EncodedString(), jid: peer.owner, deviceId: 77, keyExchange: true)

        XCTAssertEqual(opened, plaintext)
        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, old.signedPreKeyID + 1)
        XCTAssertTrue(try f.storage.sessionExists(jid: peer.owner, deviceID: 77))
    }

    func testVerifiedIncomingContentRunsDueMaintenanceBeforeUsingTheDelayedSPK() throws {
        let f = try fixture()
        let peer = try sender(clock: f.clock)
        let old = try f.storage.localBundle()
        try peer.initiateSession(jid: f.manager.owner, deviceID: old.deviceID, bundle: selected(old))
        let peerManager = OmemoManager(withOwner: peer.owner)
        let content = try XCTUnwrap(peerManager.prepareStanzaContent(message: "delayed weekly secret", date: Date(), jid: f.manager.owner, additionalContent: [], ignoreTimeSignature: true))
        let sealed = try Omemo2PayloadCodec.seal(content)
        let key = try peer.encrypt(sealed.keyAndMAC, jid: f.manager.owner, deviceID: old.deviceID)
        let wire = try DDXMLElement(xmlString: """
        <message xmlns='jabber:client' from='\(peer.owner)' to='\(f.manager.owner)' type='chat'>
          <encrypted xmlns='urn:xmpp:omemo:2'>
            <header sid='77'><keys jid='\(f.manager.owner)'><key rid='42' kex='true'>\(key.data.base64EncodedString())</key></keys></header>
            <payload>\(sealed.ciphertext.base64EncodedString())</payload>
          </encrypted>
        </message>
        """)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        let result = f.manager.prepareIncoming(XMPPMessage(from: wire))

        guard case .verified(let message, _) = result else { return XCTFail("Expected authenticated delayed content") }
        XCTAssertEqual(message.element(forName: "body", xmlns: "jabber:client")?.stringValue, "delayed weekly secret")
        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, old.signedPreKeyID + 1)
        XCTAssertTrue(try f.storage.sessionExists(jid: peer.owner, deviceID: 77))
    }

    func testUserContentSendRotatesOverdueSPKAndKeepsTheExistingRatchetDecryptable() throws {
        let f = try fixture()
        let peer = try sender(clock: f.clock)
        let remote = try peer.localBundle()
        try f.storage.initiateSession(jid: peer.owner, deviceID: remote.deviceID, bundle: selected(remote))
        let device = SignalDeviceStorageItem()
        device.primary = SignalDeviceStorageItem.genPrimary(owner: f.manager.owner, jid: peer.owner, deviceId: remote.deviceID)
        device.owner = f.manager.owner; device.jid = peer.owner; device.deviceId = remote.deviceID
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: remote.identityKey)
        device.state = .trusted; device.isInDeviceList = true
        let snapshot = OMEMO2DeviceListStorageItem()
        snapshot.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: f.manager.owner, jid: peer.owner)
        snapshot.owner = f.manager.owner; snapshot.jid = peer.owner; snapshot.isKnown = true
        snapshot.deviceIDs.append(remote.deviceID)
        snapshot.devicesXML = "<devices xmlns='urn:xmpp:omemo:2'><device id='\(remote.deviceID)'/></devices>"
        let realm = try WRealm.safe()
        try realm.write { realm.add(device); realm.add(snapshot) }
        let before = try f.storage.localBundle()
        let initialEK = try XCTUnwrap(f.storage.sessionMetadata(jid: peer.owner, deviceID: remote.deviceID)?.ephemeralKey)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        let content = try XCTUnwrap(f.manager.prepareStanzaContent(message: "weekly secret", date: Date(), jid: peer.owner, additionalContent: [], ignoreTimeSignature: true))

        let encrypted = try XCTUnwrap(f.manager.encryptMessage(message: content, to: peer.owner))

        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, before.signedPreKeyID + 1)
        XCTAssertEqual(try f.storage.sessionMetadata(jid: peer.owner, deviceID: remote.deviceID)?.ephemeralKey, initialEK)
        let key = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns)?.element(forName: "keys", xmlns: OmemoManager.xmlns)?.element(forName: "key", xmlns: OmemoManager.xmlns))
        let payload = try XCTUnwrap(encrypted.element(forName: "payload", xmlns: OmemoManager.xmlns)?.stringValue)
        let ciphertext = try OMEMO2Ciphertext(data: Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue)), keyExchange: key.attributeStringValue(forName: "kex") == "true")
        let keyAndMAC = try peer.decrypt(ciphertext, jid: f.manager.owner, deviceID: before.deviceID)
        let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(Omemo2PayloadCodec.decodeBase64(payload), keyAndMAC: keyAndMAC, expectedFrom: f.manager.owner, expectedTo: peer.owner))
        XCTAssertEqual(opened.content.element(forName: "body", xmlns: "jabber:client")?.stringValue, "weekly secret")
    }

    func testUnknownKeyExchangeUsingRetiredSPKIsRejectedAfterAnotherRotationPeriod() throws {
        let f = try fixture()
        let peer = try sender(clock: f.clock)
        let old = try f.storage.localBundle()
        try peer.initiateSession(jid: f.manager.owner, deviceID: old.deviceID, bundle: selected(old))
        let delayed = try peer.encrypt(Data(repeating: 0x61, count: 48), jid: f.manager.owner, deviceID: old.deviceID)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        _ = try f.manager.ensureOMEMO2Prepared()
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        _ = try f.manager.ensureOMEMO2Prepared()
        let committed = f.memory.records[f.manager.owner]

        XCTAssertThrowsError(try f.manager.doubleUnratched(delayed.data.base64EncodedString(), jid: peer.owner, deviceId: 77, keyExchange: true))

        XCTAssertEqual(f.memory.records[f.manager.owner], committed)
        XCTAssertFalse(try f.storage.sessionExists(jid: peer.owner, deviceID: 77))
    }

    func testKnownKeyExchangeSessionStillDecryptsAfterTheRetiredSPKGraceExpires() throws {
        let f = try fixture()
        let peer = try sender(clock: f.clock)
        let old = try f.storage.localBundle()
        try peer.initiateSession(jid: f.manager.owner, deviceID: old.deviceID, bundle: selected(old))
        let first = try peer.encrypt(Data(repeating: 0x71, count: 48), jid: f.manager.owner, deviceID: old.deviceID)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        _ = try f.manager.doubleUnratched(first.data.base64EncodedString(), jid: peer.owner, deviceId: 77, keyExchange: true)
        let knownEK = try XCTUnwrap(f.storage.sessionMetadata(jid: peer.owner, deviceID: 77)?.ephemeralKey)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        _ = try f.manager.ensureOMEMO2Prepared()
        let plaintext = Data(repeating: 0x72, count: 48)
        let later = try peer.encrypt(plaintext, jid: f.manager.owner, deviceID: old.deviceID)

        let opened = try f.manager.doubleUnratched(later.data.base64EncodedString(), jid: peer.owner, deviceId: 77, keyExchange: true)

        XCTAssertEqual(opened, plaintext)
        XCTAssertEqual(try f.storage.sessionMetadata(jid: peer.owner, deviceID: 77)?.ephemeralKey, knownEK)
        XCTAssertEqual(try f.storage.localBundle().identityKey, old.identityKey)
    }

    func testFailedRotationSaveKeepsIdentitySPKAndProjectionThenRetriesTheSameBoundary() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        let committed = f.memory.records[f.manager.owner]
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        f.memory.failSaves = true

        XCTAssertThrowsError(try f.manager.ensureOMEMO2Prepared())

        XCTAssertEqual(f.memory.records[f.manager.owner], committed)
        XCTAssertEqual(try f.storage.localBundle().signedPreKey, before.signedPreKey)
        XCTAssertEqual(try ownIdentity(f).signedPreKeyId, Int(before.signedPreKeyID))
        f.memory.failSaves = false
        _ = try f.manager.ensureOMEMO2Prepared()
        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, before.signedPreKeyID + 1)
        XCTAssertEqual(try f.storage.localBundle().identityKey, before.identityKey)
    }

    func testStalePublicationACKAfterRotationCannotMarkTheNewSPKAsPublished() throws {
        let f = try fixture()
        // Keep the older IQ within its transport timeout while crossing the
        // independently measured weekly SPK boundary.
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval - 1)
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let oldRequest = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        f.clock.advance(1)
        _ = try f.manager.ensureOMEMO2Prepared()

        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: oldRequest)))

        XCTAssertFalse(try ownIdentity(f).isPublicated)
        XCTAssertTrue(f.manager.shouldPublicate)
    }

    func testRotatedBundlePublicationMaintainsMinimumOPKsAndMatchingACKProvesCurrentSPK() throws {
        let f = try fixture(preKeyCount: 3)
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)
        _ = try f.manager.ensureOMEMO2Prepared()

        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)

        let request = try XCTUnwrap(publications(f.stream).last)
        let item = try XCTUnwrap(request.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.element(forName: "publish")?.element(forName: "item"))
        let value = try OMEMO2BundleCodec.decode(item: item)
        XCTAssertGreaterThanOrEqual(value.preKeys.count, 25)
        XCTAssertEqual(value.preKeys.count, 100)
        XCTAssertEqual(value.signedPreKeyID, try f.storage.localBundle().signedPreKeyID)
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: request.attributeStringValue(forName: "id"))))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
        XCTAssertFalse(f.manager.shouldPublicate)
    }

    func testForegroundMaintenancePublishesTheRotatedBundleOnceWhileItsIQIsPending() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        f.manager.performOMEMO2KeyMaintenance(f.stream, force: true)
        let writes = f.memory.writes
        for _ in 0..<5 { f.manager.performOMEMO2KeyMaintenance(f.stream, force: true) }

        XCTAssertEqual(try f.storage.localBundle().signedPreKeyID, before.signedPreKeyID + 1)
        XCTAssertEqual(publications(f.stream).count, 1)
        XCTAssertEqual(f.memory.writes, writes)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
    }

    func testPublicationErrorRetriesOnActivityAfterTheRetryInterval() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let first = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: first)))

        f.manager.performOMEMO2KeyMaintenance(f.stream)
        XCTAssertEqual(publications(f.stream).count, 1)
        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval - 1)
        f.manager.performOMEMO2KeyMaintenance(f.stream)
        XCTAssertEqual(publications(f.stream).count, 1)
        f.clock.advance(1)
        f.manager.performOMEMO2KeyMaintenance(f.stream)

        XCTAssertEqual(publications(f.stream).count, 2)
        let retry = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertNotEqual(retry, first)
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: retry)))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
        XCTAssertFalse(f.manager.shouldPublicate)
    }

    func testPublicationTimeoutReleasesPendingRequestAndLateACKCannotProveCurrentPublication() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let expired = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        f.clock.advance(OmemoManager.omemo2PublicationIQTimeout - 1)
        f.manager.performOMEMO2KeyMaintenance(f.stream)
        XCTAssertEqual(publications(f.stream).count, 1)

        f.clock.advance(1)
        f.manager.performOMEMO2KeyMaintenance(f.stream)

        XCTAssertEqual(publications(f.stream).count, 2)
        XCTAssertFalse(f.manager.queryIds.contains(expired))
        XCTAssertFalse(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: expired)))
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        let current = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: current)))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
    }

    func testIdleAuthenticatedConnectionRetriesPublicationErrorWithoutNewMessageActivity() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let first = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: first)))

        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.scheduler.runDue(at: f.clock.date)

        XCTAssertEqual(publications(f.stream).count, 2)
        XCTAssertTrue(f.scheduler.entries.filter { !$0.1.isCancelled }.count <= 1)
    }

    func testIdleAuthenticatedConnectionRecoversMissingPublicationACKAtTheTimeout() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let old = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))

        f.clock.advance(OmemoManager.omemo2PublicationIQTimeout)
        f.scheduler.runDue(at: f.clock.date)

        XCTAssertEqual(publications(f.stream).count, 2)
        XCTAssertFalse(f.manager.omemo2BundlePublications.keys.contains(old))
        XCTAssertTrue(f.scheduler.entries.filter { !$0.1.isCancelled }.count <= 1)
    }

    func testScheduledRetryStopsAfterDisableInsteadOfReannouncingTheRetainedBundle() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let first = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: first)))
        let realm = try WRealm.safe()
        try realm.write { realm.object(ofType: AccountStorageItem.self, forPrimaryKey: f.manager.owner)?.isEncryptionEnabled = false }

        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.scheduler.runDue(at: f.clock.date)

        XCTAssertEqual(publications(f.stream).count, 1)
        XCTAssertTrue(f.scheduler.entries.filter { !$0.1.isCancelled }.isEmpty)
    }

    func testScheduledRetryStopsWhileDisconnectedAndTheNextAuthenticatedActivityResumesIt() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let first = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: first)))
        f.stream.authenticated = false

        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.scheduler.runDue(at: f.clock.date)
        XCTAssertEqual(publications(f.stream).count, 1)
        XCTAssertTrue(f.scheduler.entries.filter { !$0.1.isCancelled }.isEmpty)
        f.stream.authenticated = true
        f.manager.performOMEMO2KeyMaintenance(f.stream)

        XCTAssertEqual(publications(f.stream).count, 2)
    }

    func testConfigurationErrorAllowsAnotherConfigurationAttemptAfterBackoff() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let first = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(preconditionError(first)))
        let configuration = try XCTUnwrap(configurations(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: configuration)))
        XCTAssertEqual(publications(f.stream).count, 1)

        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.scheduler.runDue(at: f.clock.date)
        let retry = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(preconditionError(retry)))

        XCTAssertEqual(publications(f.stream).count, 2)
        XCTAssertEqual(configurations(f.stream).count, 2)
        XCTAssertNotEqual(configurations(f.stream).last?.attributeStringValue(forName: "id"), configuration)
    }

    func testConfigurationTimeoutReleasesOwnershipAndAllowsAnotherConfigurationAttempt() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let first = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(preconditionError(first)))
        let configuration = try XCTUnwrap(configurations(f.stream).last?.attributeStringValue(forName: "id"))

        f.clock.advance(OmemoManager.omemo2PublicationIQTimeout)
        f.scheduler.runDue(at: f.clock.date)
        XCTAssertFalse(f.manager.queryIds.contains(configuration))
        XCTAssertFalse(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: configuration)))
        let retry = try XCTUnwrap(publications(f.stream).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(preconditionError(retry)))

        XCTAssertEqual(publications(f.stream).count, 2)
        XCTAssertEqual(configurations(f.stream).count, 2)
    }

    func testClosedSecondaryStreamDoesNotPreventAnIdleRetryOnTheAuthenticatedPrimaryStream() throws {
        let f = try fixture()
        let secondary = Stream()
        f.manager.omemo2RegistrationStream = f.stream
        try f.manager.sendOwnDeviceBundle(secondary, createNode: false)
        let first = try XCTUnwrap(publications(secondary).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: first)))
        secondary.authenticated = false

        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.scheduler.runDue(at: f.clock.date)

        XCTAssertEqual(publications(secondary).count, 1)
        XCTAssertEqual(publications(f.stream).count, 1)
    }

    func testPublicationSaveFailureLeavesNoPendingIQAndRetriesOnLaterActivity() throws {
        let f = try fixture(preKeyCount: 3)
        f.manager.shouldPublicate = true
        f.memory.failSaves = true

        f.manager.performOMEMO2KeyMaintenance(f.stream)

        XCTAssertTrue(publications(f.stream).isEmpty)
        XCTAssertTrue(f.manager.omemo2BundlePublications.isEmpty)
        XCTAssertTrue(f.manager.shouldPublicate)
        f.memory.failSaves = false
        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.manager.performOMEMO2KeyMaintenance(f.stream)
        XCTAssertEqual(publications(f.stream).count, 1)
        XCTAssertEqual(try f.storage.localBundle().preKeys.count, 100)
    }

    func testDirectRegistrationPublicationFailureRetriesWithoutWaitingForAnotherActivity() throws {
        let f = try fixture(preKeyCount: 3)
        f.memory.failSaves = true

        XCTAssertThrowsError(try f.manager.sendOwnDeviceBundle(f.stream, createNode: false))
        XCTAssertTrue(publications(f.stream).isEmpty)
        f.memory.failSaves = false
        f.clock.advance(OmemoManager.omemo2PublicationRetryInterval)
        f.scheduler.runDue(at: f.clock.date)

        XCTAssertEqual(publications(f.stream).count, 1)
        XCTAssertEqual(try f.storage.localBundle().preKeys.count, 100)
    }

    func testDisabledAccountForegroundDoesNotRotateOrPublishItsRetainedKeys() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        let realm = try WRealm.safe()
        try realm.write { realm.object(ofType: AccountStorageItem.self, forPrimaryKey: f.manager.owner)?.isEncryptionEnabled = false }
        f.clock.advance(XabberOMEMO2Storage.signedPreKeyRotationInterval)

        f.manager.performOMEMO2KeyMaintenance(f.stream, force: true)

        XCTAssertEqual(try f.storage.localBundle().signedPreKey, before.signedPreKey)
        XCTAssertTrue(publications(f.stream).isEmpty)
    }

    private func fixture(preKeyCount: Int = 3) throws -> Fixture {
        let owner = "maintenance-\(UUID().uuidString.lowercased())@example.test"
        owners.append(owner)
        let memory = Memory()
        let clock = Clock()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory, now: { clock.date })
        _ = try storage.prepare(deviceID: 42, preKeyCount: preKeyCount)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage
        manager.omemo2MaintenanceNow = { clock.date }
        let scheduler = Scheduler()
        manager.omemo2MaintenanceScheduler = { delay, work in
            scheduler.entries.append((clock.date.addingTimeInterval(delay), work))
        }
        _ = try manager.ensureOMEMO2Prepared()
        manager.isOmemoPrepared = true
        manager.shouldPublicate = false
        let account = AccountStorageItem()
        account.jid = owner; account.isEncryptionEnabled = true
        let snapshot = OMEMO2DeviceListStorageItem()
        snapshot.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: owner)
        snapshot.owner = owner; snapshot.jid = owner; snapshot.isKnown = true
        snapshot.deviceIDs.append(42)
        snapshot.devicesXML = "<devices xmlns='urn:xmpp:omemo:2'><device id='42'/></devices>"
        let realm = try WRealm.safe()
        try realm.write { realm.add(account); realm.add(snapshot) }
        return Fixture(manager: manager, storage: storage, memory: memory, clock: clock, stream: Stream(), scheduler: scheduler)
    }
    private func sender(clock: Clock) throws -> XabberOMEMO2Storage {
        let owner = "maintenance-peer-\(UUID().uuidString.lowercased())@example.test"
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: Memory(), now: { clock.date })
        _ = try storage.prepare(deviceID: 77, preKeyCount: 3)
        return storage
    }
    private func selected(_ bundle: OMEMO2LocalBundle) throws -> OMEMO2Bundle {
        let key = try XCTUnwrap(bundle.preKeys.first)
        return try OMEMO2PublishedBundle(bundle).selectedBundle(preKeyID: key.id)
    }
    private func ownIdentity(_ f: Fixture) throws -> SignalIdentityStorageItem {
        let realm = try WRealm.safe()
        return try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: f.manager.owner, jid: f.manager.owner, deviceId: 42)))
    }
    private func publications(_ stream: Stream) -> [DDXMLElement] {
        stream.elements.filter {
            $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.element(forName: "publish")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue
        }
    }
    private func configurations(_ stream: Stream) -> [DDXMLElement] {
        stream.elements.filter {
            $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")?.element(forName: "configure")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue
        }
    }
    private func preconditionError(_ requestID: String) -> XMPPIQ {
        let result = XMPPIQ(iqType: .error, to: nil, elementID: requestID)
        let error = DDXMLElement(name: "error")
        error.addChild(DDXMLElement(name: "precondition-not-met", xmlns: "http://jabber.org/protocol/pubsub#errors"))
        result.addChild(error)
        return result
    }
}
