import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Local session metadata is a projection of committed protected identity;
/// the server device-list snapshot remains the membership authority.
final class OMEMO2OwnDeviceBindingTests: XCTestCase {
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
        let current: DeviceStorageItem
        let remote: DeviceStorageItem
    }

    private var previousRealm: Realm.Configuration!
    private var owners: [String] = []

    override func setUp() {
        super.setUp()
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2OwnDeviceBinding-\(UUID())")
    }

    override func tearDown() {
        for owner in owners { CredentialsManager.shared.removeDeviceId(for: owner) }
        owners.removeAll()
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testFreshProtectedRegistrationBindsCurrentSessionWithoutChangingRemoteMembership() throws {
        let f = try fixture()
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)
        XCTAssertEqual(f.current.omemoDeviceId, -1)
        XCTAssertTrue(f.memory.records.isEmpty)

        XCTAssertTrue(f.manager.read(withIQ: try ownNodeReply(f, devices: "<device id='99'/>")))

        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertEqual(f.current.omemoDeviceId, 42)
        XCTAssertEqual(f.remote.omemoDeviceId, 99)
        let realm = try WRealm.safe()
        XCTAssertEqual(Array(try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: realm, owner: f.manager.owner, jid: f.manager.owner)).deviceIDs), [99])
        let local = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: f.manager.owner, jid: f.manager.owner, deviceId: 42)))
        XCTAssertFalse(local.isInDeviceList)
        XCTAssertEqual(local.state, .trusted)
    }

    func testFreshBackendRegistrationRepairsLegacyDeviceCredentialMirror() throws {
        let f = try fixture()
        CredentialsManager.shared.setDeviceId(123, for: f.manager.owner)
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)

        XCTAssertTrue(f.manager.read(withIQ: try ownNodeReply(f, devices: "<device id='123'/><device id='99'/>")))

        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertEqual(CredentialsManager.shared.getDeviceId(for: f.manager.owner), 42)
        XCTAssertEqual(f.current.omemoDeviceId, 42)
        XCTAssertEqual(f.remote.omemoDeviceId, 99)
    }

    func testFailedFreshBackendRegistrationPreservesLegacyDeviceCredentialMirror() throws {
        let f = try fixture()
        CredentialsManager.shared.setDeviceId(123, for: f.manager.owner)
        f.memory.failSaves = true
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)

        XCTAssertTrue(f.manager.read(withIQ: try ownNodeReply(f, devices: "<device id='123'/>")))

        XCTAssertEqual(CredentialsManager.shared.getDeviceId(for: f.manager.owner), 123)
        XCTAssertEqual(f.current.omemoDeviceId, -1)
        XCTAssertTrue(f.memory.records.isEmpty)
    }

    func testUnchangedCommittedBundleRepairsCurrentSessionBinding() throws {
        let f = try fixture(preparedID: 42)
        _ = try f.manager.ensureOMEMO2Prepared(attemptPublication: false)
        let previousIdentity = try f.storage.localBundle().identityKey
        let realm = try WRealm.safe()
        try realm.write { f.current.omemoDeviceId = 123 }

        _ = try f.manager.ensureOMEMO2Prepared(attemptPublication: false)

        XCTAssertEqual(f.current.omemoDeviceId, 42)
        XCTAssertEqual(f.remote.omemoDeviceId, 99)
        XCTAssertEqual(try f.storage.localBundle().identityKey, previousIdentity)
    }

    func testDeviceListRefreshWithoutOwnOmemoIDReconcilesFromCommittedProfile() throws {
        let f = try fixture(preparedID: 42)
        _ = try f.manager.ensureOMEMO2Prepared(attemptPublication: false)
        let devices = XMPPDeviceManager(withOwner: f.manager.owner)
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='devices'><query xmlns='https://xabber.com/protocol/devices#items'><device id='current-session'><client>Xabber</client><expire>2000000000</expire><ip>127.0.0.1</ip><last-auth>1</last-auth></device><device id='remote-session'><client>Other</client><expire>2000000000</expire><ip>127.0.0.2</ip><last-auth>1</last-auth><omemo-id>99</omemo-id></device></query></iq>")

        XCTAssertTrue(devices.read(withIQ: iq))
        f.manager.checkInfo()

        XCTAssertEqual(f.current.omemoDeviceId, 42)
        XCTAssertEqual(f.remote.omemoDeviceId, 99)
    }

    func testBindingOnlyRepairPreservesPublicationProofAndDoesNotRepublish() throws {
        let f = try fixture(preparedID: 42)
        _ = try f.manager.ensureOMEMO2Prepared(attemptPublication: false)
        let realm = try WRealm.safe()
        let primary = SignalDeviceStorageItem.genPrimary(owner: f.manager.owner, jid: f.manager.owner, deviceId: 42)
        let identity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
        let device = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
        try realm.write {
            f.current.omemoDeviceId = -1
            identity.isPublicated = true
            device.isPublicated = true
        }
        f.manager.shouldPublicate = false

        _ = try f.manager.ensureOMEMO2Prepared(attemptPublication: false)

        XCTAssertEqual(f.current.omemoDeviceId, 42)
        XCTAssertTrue(identity.isPublicated)
        XCTAssertTrue(device.isPublicated)
        XCTAssertFalse(f.manager.shouldPublicate)
    }

    func testFailedProtectedRegistrationCannotBindCurrentSession() throws {
        let f = try fixture()
        f.memory.failSaves = true
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)

        XCTAssertTrue(f.manager.read(withIQ: try ownNodeReply(f, devices: "")))
        f.manager.checkInfo()

        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertEqual(f.current.omemoDeviceId, -1)
        XCTAssertEqual(f.remote.omemoDeviceId, 99)
        XCTAssertFalse(f.manager.isOmemoPrepared)
    }

    private func fixture(preparedID: Int? = nil) throws -> Fixture {
        let owner = "own-device-binding-\(UUID().uuidString.lowercased())@example.test"
        owners.append(owner)
        let account = AccountStorageItem()
        account.jid = owner
        account.deviceUuid = "current-session"
        account.isEncryptionEnabled = true
        let current = DeviceStorageItem()
        current.owner = owner; current.uid = "current-session"
        current.primary = DeviceStorageItem.genPrimary(uid: current.uid, owner: owner)
        let remote = DeviceStorageItem()
        remote.owner = owner; remote.uid = "remote-session"
        remote.primary = DeviceStorageItem.genPrimary(uid: remote.uid, owner: owner)
        remote.omemoDeviceId = 99
        let realm = try WRealm.safe()
        try realm.write { realm.add(account); realm.add(current); realm.add(remote) }
        let manager = OmemoManager(withOwner: owner)
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        manager.omemo2Storage = storage
        if let preparedID { _ = try storage.prepare(deviceID: preparedID, preKeyCount: 3) }
        return Fixture(manager: manager, storage: storage, memory: memory, stream: Stream(), current: current, remote: remote)
    }

    private func ownNodeReply(_ f: Fixture, devices: String) throws -> XMPPIQ {
        let request = try XCTUnwrap(f.stream.elements.last { $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.device.rawValue })
        let id = try XCTUnwrap(request.attributeStringValue(forName: "id"))
        return try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='\(id)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></pubsub></iq>")
    }
}
