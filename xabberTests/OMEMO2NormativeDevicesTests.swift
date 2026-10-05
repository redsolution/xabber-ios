import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

final class OMEMO2NormativeDevicesTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private final class Stream: XMPPStream {
        var elements: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }
    private struct Fixture {
        let alice: OmemoManager
        let bob: OmemoManager
        let aliceStore: XabberOMEMO2Storage
        let bobStore: XabberOMEMO2Storage
        let bobBundle: OMEMO2LocalBundle
    }
    private var originalRealm: Realm.Configuration!
    override func setUp() {
        super.setUp()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "N01-\(UUID())")
    }
    override func tearDown() { Realm.Configuration.defaultConfiguration = originalRealm; super.tearDown() }

    func testTrustedIdentityOutsideAdvertisedListCannotReceiveContentOrAdvanceSession() throws {
        let f = try fixture()
        try headline(f.alice, jid: f.bob.owner, devices: "")
        try trust(f.alice, jid: f.bob.owner, bundle: f.bobBundle)
        let before = try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: 42)?.sendCounter
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
        XCTAssertEqual(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: 42)?.sendCounter, before)
    }

    func testDirectRatchetAlsoRejectsUnadvertisedTrustedContentRecipient() throws {
        let f = try fixture()
        try headline(f.alice, jid: f.bob.owner, devices: "")
        try trust(f.alice, jid: f.bob.owner, bundle: f.bobBundle)
        XCTAssertThrowsError(try f.alice.doubleRatchet(hmac: Data(repeating: 1, count: 48), jid: f.bob.owner, deviceId: 42))
        XCTAssertEqual(try f.aliceStore.sessionMetadata(jid: f.bob.owner, deviceID: 42)?.sendCounter, 0)
    }

    func testKnownEmptyListRemovesRecipientButPreservesTrustIdentityAndSession() throws {
        let f = try fixture()
        let realm = try WRealm.safe()
        let primary = SignalDeviceStorageItem.genPrimary(owner: f.alice.owner, jid: f.bob.owner, deviceId: 42)
        let identity = SignalIdentityStorageItem()
        identity.primary = primary; identity.owner = f.alice.owner; identity.jid = f.bob.owner; identity.deviceId = 42
        identity.identityKey = f.bobBundle.identityKey.base64EncodedString(); identity.protocolProfile = OmemoManager.xmlns
        try realm.write { realm.add(identity) }
        try headline(f.alice, jid: f.bob.owner, devices: "")
        let retained = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual(retained.state, .trusted)
        XCTAssertEqual(retained.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: f.bobBundle.identityKey))
        XCTAssertNotNil(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
        XCTAssertTrue(try f.aliceStore.sessionExists(jid: f.bob.owner, deviceID: 42))
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testForeignNamespaceDeviceDoesNotBecomeRecipient() throws {
        let f = try fixture()
        try headline(f.alice, jid: f.bob.owner, devices: "<device xmlns='urn:foreign' id='42'/>")
        try trust(f.alice, jid: f.bob.owner, bundle: f.bobBundle)
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testPrefixedDevicesProduceRealDecryptableContent() throws {
        let f = try fixture()
        let message = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><o:devices xmlns:o='urn:xmpp:omemo:2'><o:device id='42'/></o:devices></item></items></event></message>")
        XCTAssertTrue(f.alice.onContactDeviceListReceiveHeadline(message))
        let encrypted = try XCTUnwrap(f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
        XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [42])
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [])
        let incoming = XMPPMessage(type: "chat", to: XMPPJID(string: f.bob.owner))
        incoming.addAttribute(withName: "from", stringValue: f.alice.owner); incoming.addChild(encrypted)
        let opened = try XCTUnwrap(f.bob.decryptMessage(incoming))
        XCTAssertEqual(opened.element(forName: "content")?.element(forName: "body")?.stringValue, "verified N01")
    }

    func testDelayedIQCannotRestoreDeviceRemovedByNewerPEP() throws {
        let f = try fixture(); let stream = Stream()
        f.alice.getContactDevices(stream, jid: f.bob.owner, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        try headline(f.alice, jid: f.bob.owner, devices: "")
        XCTAssertTrue(f.alice.read(withIQ: try reply(id: id, from: f.bob.owner, devices: "<device id='42'/>")))
        try trust(f.alice, jid: f.bob.owner, bundle: f.bobBundle)
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testUnsolicitedOrWrongSenderIQCannotChangeMembership() throws {
        let f = try fixture(); let stream = Stream()
        try headline(f.alice, jid: f.bob.owner, devices: "")
        f.alice.getContactDevices(stream, jid: f.bob.owner, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        _ = f.alice.read(withIQ: try reply(id: "unsolicited", from: f.bob.owner, devices: "<device id='42'/>"))
        _ = f.alice.read(withIQ: try reply(id: id, from: "other@example.test", devices: "<device id='42'/>"))
        try trust(f.alice, jid: f.bob.owner, bundle: f.bobBundle)
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testEmptyIQItemsAreAuthoritativeEmptyRatherThanKeepingOldRecipient() throws {
        let f = try fixture(); let stream = Stream()
        f.alice.getContactDevices(stream, jid: f.bob.owner, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='\(id)' from='\(f.bob.owner)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'/></pubsub></iq>")
        XCTAssertTrue(f.alice.read(withIQ: iq))
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testNodePurgeAndCurrentRetractionRemoveRecipientsWithoutDeletingTrust() throws {
        for removal in ["<purge node='urn:xmpp:omemo:2:devices'/>", "<delete node='urn:xmpp:omemo:2:devices'/>", "<items node='urn:xmpp:omemo:2:devices'><retract id='current'/></items>"] {
            let f = try fixture()
            let m = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'>\(removal)</event></message>")
            XCTAssertTrue(f.alice.onContactDeviceListReceiveHeadline(m))
            let realm = try WRealm.safe()
            XCTAssertEqual(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: f.alice.owner, jid: f.bob.owner, deviceId: 42))?.state, .trusted)
            XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
        }
    }

    func testOwnSnapshotIsRequiredEvenWhenPeerSnapshotIsKnown() throws {
        let alice = OmemoManager(withOwner: "a-\(UUID().uuidString.lowercased())@example.test")
        let bob = OmemoManager(withOwner: "b-\(UUID().uuidString.lowercased())@example.test")
        let memory = Memory(); let a = try XabberOMEMO2Storage(owner: alice.owner, persistence: memory)
        let b = try XabberOMEMO2Storage(owner: bob.owner, persistence: memory)
        _ = try a.prepare(deviceID: 41, preKeyCount: 3); let bundle = try b.prepare(deviceID: 42, preKeyCount: 3)
        alice.omemo2Storage = a; bob.omemo2Storage = b
        _ = try alice.ensureOMEMO2Prepared(); _ = try bob.ensureOMEMO2Prepared()
        try initiate(a, jid: bob.owner, bundle: bundle); try trust(alice, jid: bob.owner, bundle: bundle)
        try headline(alice, jid: bob.owner, devices: "<device id='42'/>")
        var discovered: [String] = []
        alice.omemo2DeviceListRequester = { discovered.append($0) }
        XCTAssertThrowsError(try alice.encryptMessage(message: "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>no own list</body></content><rpad>pad</rpad></envelope>", to: bob.owner))
        XCTAssertEqual(discovered, [alice.owner])
    }

    func testOnlyKnownSnapshotSuppressesFetchNotLegacyReceivedBoolean() throws {
        let owner = "a-\(UUID().uuidString.lowercased())@example.test"; let manager = OmemoManager(withOwner: owner); let stream = Stream()
        let account = AccountStorageItem(); account.jid = owner; account.isOmemoDevicesListReceived = true
        let realm = try WRealm.safe(); try realm.write { realm.add(account) }
        manager.getContactDevices(stream, jid: owner)
        XCTAssertEqual(stream.elements.count, 1)
    }

    func testEmptyProtocolControlStillTargetsUnadvertisedSenderWithoutUserContent() throws {
        let f = try fixture()
        try headline(f.alice, jid: f.bob.owner, devices: "")
        let control = try f.alice.makeOMEMO2Control(jid: f.bob.owner, deviceID: 42)
        let encrypted = try XCTUnwrap(control.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [42])
        XCTAssertNil(encrypted.element(forName: "payload"))
        XCTAssertNil(control.body)
    }

    func testMalformedPublicationPreservesKnownMembershipAndTrust() throws {
        let f = try fixture()
        try headline(f.alice, jid: f.bob.owner, devices: "<device id='42'/><device id='42'/>")
        let realm = try WRealm.safe()
        let list = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: realm, owner: f.alice.owner, jid: f.bob.owner))
        XCTAssertEqual(Array(list.deviceIDs), [42])
        XCTAssertNotNil(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testLatestRequestedIQWinsAndOwnResultMayOmitFrom() throws {
        let f = try fixture(); let stream = Stream()
        f.alice.getContactDevices(stream, jid: f.bob.owner, force: true)
        let old = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        f.alice.getContactDevices(stream, jid: f.bob.owner, force: true)
        let latest = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.alice.read(withIQ: try reply(id: latest, from: f.bob.owner, devices: "")))
        XCTAssertTrue(f.alice.read(withIQ: try reply(id: old, from: f.bob.owner, devices: "<device id='42'/>")))
        XCTAssertThrowsError(try f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
        f.alice.getContactDevices(stream, jid: f.alice.owner, force: true)
        let ownID = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        let own = try reply(id: ownID, from: f.alice.owner, devices: "<device id='41'/>"); own.removeAttribute(forName: "from")
        XCTAssertTrue(f.alice.read(withIQ: own))
        XCTAssertEqual(Array(try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: WRealm.safe(), owner: f.alice.owner, jid: f.alice.owner)).deviceIDs), [41])
    }

    func testSnapshotSurvivesManagerReloadAndHistoricalTrustCannotGrantMembership() throws {
        let f = try fixture()
        try headline(f.alice, jid: f.bob.owner, devices: "")
        let reloaded = OmemoManager(withOwner: f.alice.owner); reloaded.omemo2Storage = f.aliceStore
        let stream = Stream(); reloaded.getContactDevices(stream, jid: f.bob.owner)
        XCTAssertTrue(stream.elements.isEmpty, "Known empty is durable")
        XCTAssertThrowsError(try reloaded.encryptMessage(message: envelope(f), to: f.bob.owner))
    }

    func testUnknownValidSenderRefreshesDevicesWithoutGrantingMembership() throws {
        let f = try fixture(); let stream = Stream()
        try headline(f.bob, jid: f.alice.owner, devices: "")
        let encrypted = try XCTUnwrap(f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: f.bob.owner))
        message.addAttribute(withName: "from", stringValue: f.alice.owner); message.addChild(encrypted)
        var refreshes = 0
        f.bob.omemo2DeviceListRequester = { jid in refreshes += 1; f.bob.getContactDevices(stream, jid: jid, force: true) }
        guard case .verified = f.bob.prepareIncoming(message) else { return XCTFail("Real ciphertext must decrypt") }
        XCTAssertEqual(refreshes, 1)
        guard case .consumed(.duplicate) = f.bob.prepareIncoming(message) else { return XCTFail("Expected duplicate") }
        XCTAssertEqual(refreshes, 1)
        let realm = try WRealm.safe()
        XCTAssertFalse(OMEMO2DeviceListStorageItem.contains(in: realm, owner: f.bob.owner, jid: f.alice.owner, deviceID: 41))
        let primary = SignalDeviceStorageItem.genPrimary(owner: f.bob.owner, jid: f.alice.owner, deviceId: 41)
        XCTAssertFalse(try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary)).isInDeviceList)
    }

    func testNonCurrentPublishedItemIsAcceptedAndOnlyItsRetractionClearsMembership() throws {
        let f = try fixture()
        let update = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='server-generated'><devices xmlns='urn:xmpp:omemo:2'><device id='43'/></devices></item></items></event></message>")
        XCTAssertTrue(f.alice.onContactDeviceListReceiveHeadline(update))
        let realm = try WRealm.safe()
        let list = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: realm, owner: f.alice.owner, jid: f.bob.owner))
        XCTAssertEqual(Array(list.deviceIDs), [43])
        for id in ["current", "server-generated"] {
            let retract = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><retract id='\(id)'/></items></event></message>")
            XCTAssertTrue(f.alice.onContactDeviceListReceiveHeadline(retract))
            XCTAssertEqual(Array(list.deviceIDs), id == "current" ? [43] : [])
        }
    }

    func testSchema22MigrationRetainsTrustAndRequiresNewMembershipProof() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.realm")
        let primary = SignalDeviceStorageItem.genPrimary(owner: "a@example.test", jid: "b@example.test", deviceId: 42)
        try autoreleasepool {
            let old = try Realm(configuration: .init(fileURL: url, schemaVersion: 22, objectTypes: [SignalDeviceStorageItem.self]))
            let d = SignalDeviceStorageItem(); d.primary = primary; d.owner = "a@example.test"; d.jid = "b@example.test"; d.deviceId = 42
            d.state = .trusted; d.fingerprint = "retained"; d.isInDeviceList = true
            try old.write { old.add(d) }
        }
        var config = makeRealmMigrationConfiguration(scheme: XabberRealmSchema.current)
        config.fileURL = url; config.objectTypes = [SignalDeviceStorageItem.self, OMEMO2DeviceListStorageItem.self]
        let migrated = try Realm(configuration: config)
        let d = try XCTUnwrap(migrated.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual(d.state, .trusted); XCTAssertEqual(d.fingerprint, "retained")
        XCTAssertFalse(d.isInDeviceList)
        XCTAssertNil(OMEMO2DeviceListStorageItem.get(in: migrated, owner: d.owner, jid: d.jid))
    }

    func testRemovedOtherOwnDeviceIsExcludedAndItsRetainedSessionDoesNotAdvance() throws {
        let f = try fixture()
        let ownPeer = try XabberOMEMO2Storage(owner: "other-own@example.test", persistence: Memory())
        let bundle = try ownPeer.prepare(deviceID: 43, preKeyCount: 3)
        try initiate(f.aliceStore, jid: f.alice.owner, bundle: bundle)
        try trust(f.alice, jid: f.alice.owner, bundle: bundle)
        try headline(f.alice, jid: f.alice.owner, devices: "<device id='41'/><device id='43'/>")
        try headline(f.alice, jid: f.alice.owner, devices: "<device id='41'/>")
        let encrypted = try XCTUnwrap(f.alice.encryptMessage(message: envelope(f), to: f.bob.owner))
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [])
        XCTAssertEqual(try f.aliceStore.sessionMetadata(jid: f.alice.owner, deviceID: 43)?.sendCounter, 0)
    }

    private func fixture() throws -> Fixture {
        let alice = OmemoManager(withOwner: "a-\(UUID().uuidString.lowercased())@example.test"), bob = OmemoManager(withOwner: "b-\(UUID().uuidString.lowercased())@example.test")
        let memory = Memory(); let a = try XabberOMEMO2Storage(owner: alice.owner, persistence: memory)
        let b = try XabberOMEMO2Storage(owner: bob.owner, persistence: memory)
        _ = try a.prepare(deviceID: 41, preKeyCount: 3); let bundle = try b.prepare(deviceID: 42, preKeyCount: 3)
        alice.omemo2Storage = a; bob.omemo2Storage = b
        _ = try alice.ensureOMEMO2Prepared(); _ = try bob.ensureOMEMO2Prepared()
        try initiate(a, jid: bob.owner, bundle: bundle)
        try trust(alice, jid: bob.owner, bundle: bundle)
        try headline(alice, jid: alice.owner, devices: "<device id='41'/>")
        try headline(alice, jid: bob.owner, devices: "<device id='42'/>")
        return Fixture(alice: alice, bob: bob, aliceStore: a, bobStore: b, bobBundle: bundle)
    }
    private func initiate(_ store: XabberOMEMO2Storage, jid: String, bundle: OMEMO2LocalBundle) throws {
        let pk = try XCTUnwrap(bundle.preKeys.first)
        try store.initiateSession(jid: jid, deviceID: bundle.deviceID, bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey, signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: pk.publicKey, preKeyID: pk.id))
    }
    private func trust(_ manager: OmemoManager, jid: String, bundle: OMEMO2LocalBundle) throws {
        let realm = try WRealm.safe(); let primary = SignalDeviceStorageItem.genPrimary(owner: manager.owner, jid: jid, deviceId: bundle.deviceID)
        let d = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) ?? SignalDeviceStorageItem()
        try realm.write {
            if d.realm == nil { d.primary = primary; d.owner = manager.owner; d.jid = jid; d.deviceId = bundle.deviceID }
            d.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey); d.state = .trusted
            realm.add(d, update: .modified)
        }
    }
    private func headline(_ manager: OmemoManager, jid: String, devices: String) throws {
        let m = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(jid)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></event></message>")
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(m))
    }
    private func reply(id: String, from: String, devices: String) throws -> XMPPIQ {
        try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='\(id)' from='\(from)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></pubsub></iq>")
    }
    private func envelope(_ f: Fixture) -> String { "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>verified N01</body></content><rpad>pad</rpad><from jid='\(f.alice.owner)'/><to jid='\(f.bob.owner)'/></envelope>" }
    private func recipientIDs(_ e: DDXMLElement, jid: String) -> [Int] { e.element(forName: "header")?.elements(forName: "keys").first(where: { $0.attributeStringValue(forName: "jid") == jid })?.elements(forName: "key").map { $0.attributeIntegerValue(forName: "rid") } ?? [] }
}
