import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

/// N02 tests observe the real own-node IQs and the protected identity boundary.
/// Device-list membership is supplied by N01; trust and existing identity stay intact.
final class OMEMO2NormativeRegistrationTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failSaves = false
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failSaves { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private final class Stream: XMPPStream {
        var elements: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }
    private struct Fixture {
        let manager: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let stream: Stream
    }
    private var originalRealm: Realm.Configuration!
    private var fixtureOwners: [String] = []
    override func setUp() {
        super.setUp()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "N02-\(UUID())")
    }
    override func tearDown() {
        for owner in fixtureOwners {
            CredentialsManager.shared.removeIdentityKey(for: owner)
            CredentialsManager.shared.removeDeviceId(for: owner)
            CredentialsManager.shared.removeSignedPreKey(for: owner, id: 1)
            for id in 1...100 { CredentialsManager.shared.removePreKey(for: owner, id: id) }
        }
        fixtureOwners.removeAll()
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testFreshStartupFetchesOwnNodeBeforeChoosingIDOrCreatingAnySecret() throws {
        let f = try fixture()
        var generated = 0
        f.manager.omemo2FreshDeviceIDGenerator = { generated += 1; return 42 }

        f.manager.beginOMEMO2Registration(f.stream)

        XCTAssertEqual(generated, 0)
        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertNil(CredentialsManager.shared.getDeviceId(for: f.manager.owner))
        XCTAssertNil(CredentialsManager.shared.getIdentityKeyPrivateKey(for: f.manager.owner))
        XCTAssertEqual(ownNodeRequests(f.stream).count, 1)
        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
        XCTAssertTrue(devicePublications(f.stream).isEmpty)
    }

    func testRestartWhileOwnNodeIsUnknownStillFetchesAndDoesNotCommitFreshID() throws {
        let f = try fixture()
        f.manager.beginOMEMO2Registration(f.stream)
        let restarted = OmemoManager(withOwner: f.manager.owner)
        restarted.omemo2Storage = f.storage
        restarted.omemo2FreshDeviceIDGenerator = { XCTFail("Unknown own node must defer ID generation"); return 42 }
        let restartedStream = Stream()

        restarted.beginOMEMO2Registration(restartedStream)

        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertNil(CredentialsManager.shared.getDeviceId(for: f.manager.owner))
        XCTAssertEqual(ownNodeRequests(restartedStream).count, 1)
        XCTAssertTrue(bundlePublications(restartedStream).isEmpty)
    }

    func testFreshStartupDoesNotUseAStoredKnownSnapshotInsteadOfCurrentFetch() throws {
        let f = try fixture()
        try snapshot(f.manager, ids: [42])
        f.manager.omemo2FreshDeviceIDGenerator = { XCTFail("A cached node is not a fresh collision check"); return 42 }

        f.manager.beginOMEMO2Registration(f.stream)

        XCTAssertEqual(ownNodeRequests(f.stream).count, 1)
        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
    }

    func testFreshCollisionIsResolvedBeforeBundleAndDevicePublication() throws {
        let f = try fixture()
        var candidates = [41, 42]
        f.manager.omemo2FreshDeviceIDGenerator = {
            guard !candidates.isEmpty else { XCTFail("Collision retry unexpectedly exhausted candidates"); return 42 }
            return candidates.removeFirst()
        }
        f.manager.beginOMEMO2Registration(f.stream)
        let requestID = try XCTUnwrap(ownNodeRequests(f.stream).last?.attributeStringValue(forName: "id"))

        XCTAssertTrue(f.manager.read(withIQ: try reply(id: requestID, owner: f.manager.owner, devices: "<device id='41'/><device id='99'/>")))

        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertEqual(f.manager.localStore.localDeviceId(), 42)
        XCTAssertEqual(CredentialsManager.shared.getDeviceId(for: f.manager.owner), 42)
        XCTAssertNil(CredentialsManager.shared.getIdentityKeyPrivateKey(for: f.manager.owner))
        XCTAssertEqual(bundlePublications(f.stream).map { $0.attributeIntegerValue(forName: "id") }, [42])
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [41, 42, 99])
    }

    func testEmptyAcceptedOwnNodeAllowsFreshRegistration() throws {
        let f = try fixture()
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)
        let requestID = try XCTUnwrap(ownNodeRequests(f.stream).last?.attributeStringValue(forName: "id"))
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='\(requestID)' from='\(f.manager.owner)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'/></pubsub></iq>")

        XCTAssertTrue(f.manager.read(withIQ: iq))

        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42])
    }

    func testOwnNodeFailureCannotGenerateOrPublishFreshIdentity() throws {
        let f = try fixture()
        f.manager.omemo2FreshDeviceIDGenerator = { XCTFail("Failed fetch must not choose an ID"); return 42 }
        f.manager.beginOMEMO2Registration(f.stream)
        let requestID = try XCTUnwrap(ownNodeRequests(f.stream).last?.attributeStringValue(forName: "id"))
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='error' id='\(requestID)' from='\(f.manager.owner)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'/></pubsub><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")

        _ = f.manager.read(withIQ: iq)

        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
        XCTAssertTrue(devicePublications(f.stream).isEmpty)
    }

    func testFailedProtectedSaveAfterCollisionCheckDoesNotCommitOrPublishFreshID() throws {
        let f = try fixture()
        f.memory.failSaves = true
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)
        let requestID = try XCTUnwrap(ownNodeRequests(f.stream).last?.attributeStringValue(forName: "id"))

        XCTAssertTrue(f.manager.read(withIQ: try reply(id: requestID, owner: f.manager.owner, devices: "")))

        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertNil(CredentialsManager.shared.getDeviceId(for: f.manager.owner))
        XCTAssertNil(CredentialsManager.shared.getIdentityKeyPrivateKey(for: f.manager.owner))
        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
        XCTAssertTrue(devicePublications(f.stream).isEmpty)
        XCTAssertFalse(f.manager.isOmemoPrepared)
    }

    func testPreparedIDAndIdentityArePreservedWhenOwnNodeContainsThatID() throws {
        let f = try fixture(preparedID: 42)
        let previousIdentity = try f.storage.localBundle().identityKey
        f.manager.omemo2FreshDeviceIDGenerator = { XCTFail("Existing protected ID is not a fresh collision"); return 43 }
        try snapshot(f.manager, ids: [42, 99])
        for legacyID in [nil, 999] as [Int?] {
            if let legacyID { CredentialsManager.shared.setDeviceId(legacyID, for: f.manager.owner) }
            else { CredentialsManager.shared.removeDeviceId(for: f.manager.owner) }
            f.stream.elements.removeAll()

            f.manager.beginOMEMO2Registration(f.stream)

            XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
            XCTAssertEqual(try f.storage.localBundle().identityKey, previousIdentity)
            XCTAssertEqual(CredentialsManager.shared.getDeviceId(for: f.manager.owner), legacyID ?? 42)
            XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 99])
        }
    }

    func testLegacyDeviceIDIsNotChangedByTheFreshIDGenerator() throws {
        let f = try fixture()

        let id = try f.manager.deviceIDForOMEMO2Preparation(legacyDeviceID: { 42 }, freshDeviceID: {
            XCTFail("Migration must preserve its existing device ID")
            return 43
        })

        XCTAssertEqual(id, 42)
        XCTAssertTrue(f.memory.records.isEmpty)
    }

    func testEnabledMissingOwnIDReannouncesOnlyReceivedMembersPlusLocalID() throws {
        let f = try fixture(preparedID: 42)
        try addUnadvertisedOwnDevice(f.manager, id: 77)
        try snapshot(f.manager, ids: [99])
        f.manager.shouldPublicate = false

        f.manager.onOwnDeviceListUpdated(f.stream, createNode: false)

        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 99])
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertNil(try publishedDevices(f.stream).element(forName: "device", xmlns: "urn:foreign"))
    }

    func testDevicePublicationPreservesOtherDevicesSignedLabelFromServerSnapshot() throws {
        let f = try fixture(preparedID: 42)
        // A neighbour's label is forwarded as received; local trust is not its source.
        let devices = "<devices xmlns='urn:xmpp:omemo:2'><device id='99' label='Tablet' labelsig='AA=='/></devices>"
        try snapshot(f.manager, ids: [99], xml: devices)

        f.manager.onOwnDeviceListUpdated(f.stream, createNode: false)

        let device = try XCTUnwrap(try publishedDevices(f.stream).elements(forName: "device").first { $0.attributeIntegerValue(forName: "id") == 99 })
        XCTAssertEqual(device.attributeStringValue(forName: "label"), "Tablet")
        XCTAssertEqual(device.attributeStringValue(forName: "labelsig"), "AA==")
    }

    func testPrefixedReceivedMembersKeepQNameAndExcludeForeignNamesWhenReannouncing() throws {
        let f = try fixture(preparedID: 42)
        try snapshot(f.manager, ids: [99], xml: "<o:devices xmlns:o='urn:xmpp:omemo:2'><o:device id='99'/><device xmlns='urn:foreign' id='77'/></o:devices>")
        f.manager.shouldPublicate = false

        f.manager.onOwnDeviceListUpdated(f.stream, createNode: false)

        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 99])
        let devices = try publishedDevices(f.stream)
        XCTAssertTrue(SCEReceivePolicy.children(of: devices, named: "device", xmlns: OmemoManager.xmlns).allSatisfy { $0.uri == OmemoManager.xmlns })
        XCTAssertTrue(SCEReceivePolicy.children(of: devices, named: "device", xmlns: "urn:foreign").isEmpty)
    }

    func testExplicitOtherDeviceDeletionMergesItsRemovalIntoTheServerSnapshot() throws {
        let f = try fixture(preparedID: 42)
        try snapshot(f.manager, ids: [42, 99, 100])

        try f.manager.sendOwnDevice(f.stream, createNode: false, excludingIDs: [99])

        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 100])
    }

    func testDisableRemovesOwnIDAndRetractsBundleWithoutRepublishingIt() throws {
        let f = try fixture(preparedID: 42)
        try addUnadvertisedOwnDevice(f.manager, id: 77)
        try snapshot(f.manager, ids: [42, 99])
        try setEnabled(f.manager, false)

        try f.manager.publicateOwnDevice(f.stream, createNode: false)

        XCTAssertEqual(try publishedDeviceIDs(f.stream), [99])
        XCTAssertEqual(bundleRetractions(f.stream).map { $0.attributeIntegerValue(forName: "id") }, [42])
        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
    }

    func testDisabledOwnListOmissionCannotReannounceOrPublishBundle() throws {
        let f = try fixture(preparedID: 42)
        try snapshot(f.manager, ids: [99])
        try setEnabled(f.manager, false)
        f.manager.shouldPublicate = false

        f.manager.onOwnDeviceListUpdated(f.stream, createNode: false)
        try? f.manager.sendOwnDeviceBundle(f.stream, createNode: false)

        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
        XCTAssertTrue(devicePublications(f.stream).isEmpty)
    }

    func testDisabledClientDoesNotRetryBundleAfterLateConfigurationSuccess() throws {
        let f = try fixture(preparedID: 42)
        try snapshot(f.manager, ids: [99])
        try setEnabled(f.manager, false)
        f.manager.omemo2BundleConfigurationRequestID = "configuration-pending"

        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: "configuration-pending")))
        try? f.manager.sendOwnDeviceBundle(f.stream, createNode: false)

        XCTAssertTrue(bundlePublications(f.stream).isEmpty)
        XCTAssertNil(f.manager.omemo2BundleConfigurationRequestID)
    }

    private func fixture(preparedID: Int? = nil) throws -> Fixture {
        let owner = "registration-\(UUID().uuidString.lowercased())@example.test"
        fixtureOwners.append(owner)
        let manager = OmemoManager(withOwner: owner)
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        manager.omemo2Storage = storage
        if let preparedID {
            _ = try storage.prepare(deviceID: preparedID, preKeyCount: 3)
            _ = try manager.ensureOMEMO2Prepared()
        }
        let account = AccountStorageItem(); account.jid = owner; account.isEncryptionEnabled = true
        let realm = try WRealm.safe(); try realm.write { realm.add(account) }
        return Fixture(manager: manager, storage: storage, memory: memory, stream: Stream())
    }
    private func setEnabled(_ manager: OmemoManager, _ enabled: Bool) throws {
        let realm = try WRealm.safe()
        try realm.write { realm.object(ofType: AccountStorageItem.self, forPrimaryKey: manager.owner)?.isEncryptionEnabled = enabled }
    }
    private func snapshot(_ manager: OmemoManager, ids: [Int], xml: String? = nil) throws {
        let value = OMEMO2DeviceListStorageItem()
        value.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: manager.owner, jid: manager.owner)
        value.owner = manager.owner; value.jid = manager.owner; value.isKnown = true
        value.deviceIDs.append(objectsIn: ids)
        value.devicesXML = xml ?? "<devices xmlns='urn:xmpp:omemo:2'>\(ids.map { "<device id='\($0)'/>" }.joined())</devices>"
        let realm = try WRealm.safe(); try realm.write { realm.add(value, update: .modified) }
    }
    private func addUnadvertisedOwnDevice(_ manager: OmemoManager, id: Int) throws {
        let device = SignalDeviceStorageItem()
        device.owner = manager.owner; device.jid = manager.owner; device.deviceId = id
        device.primary = SignalDeviceStorageItem.genPrimary(owner: manager.owner, jid: manager.owner, deviceId: id)
        device.state = .trusted
        let realm = try WRealm.safe(); try realm.write { realm.add(device) }
    }
    private func reply(id: String, owner: String, devices: String) throws -> XMPPIQ {
        try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='\(id)' from='\(owner)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></pubsub></iq>")
    }
    private func ownNodeRequests(_ stream: Stream) -> [DDXMLElement] {
        stream.elements.filter { $0.attributeStringValue(forName: "type") == "get" && $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.device.rawValue }
    }
    private func publishedItems(_ stream: Stream, node: String, operation: String) -> [DDXMLElement] {
        stream.elements.compactMap { element in
            guard let container = element.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.element(forName: operation), container.attributeStringValue(forName: "node") == node else { return nil }
            return container.element(forName: "item")
        }
    }
    private func bundlePublications(_ stream: Stream) -> [DDXMLElement] { publishedItems(stream, node: OmemoManager.NodeType.bundle.rawValue, operation: "publish") }
    private func bundleRetractions(_ stream: Stream) -> [DDXMLElement] { publishedItems(stream, node: OmemoManager.NodeType.bundle.rawValue, operation: "retract") }
    private func devicePublications(_ stream: Stream) -> [DDXMLElement] { publishedItems(stream, node: OmemoManager.NodeType.device.rawValue, operation: "publish") }
    private func publishedDevices(_ stream: Stream) throws -> DDXMLElement {
        try XCTUnwrap(devicePublications(stream).last?.element(forName: "devices", xmlns: OmemoManager.xmlns))
    }
    private func publishedDeviceIDs(_ stream: Stream) throws -> [Int] {
        try publishedDevices(stream).elements(forName: "device").map { $0.attributeIntegerValue(forName: "id") }.sorted()
    }
}
