import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Authentication is a real lifecycle boundary even if no archive query or
/// crypto activity follows a successful bundle publication after restart.
final class OMEMO2NormativeCleanupRestartTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var onRemoval: (() -> Void)?
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            let old = records[owner].flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let next = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let consumed = Set((old?["preKeys"] as? [[String: Any]] ?? [])
                .filter { $0["consumed"] as? Bool == true }
                .compactMap { ($0["id"] as? NSNumber)?.uint32Value })
            let retained = Set((next?["preKeys"] as? [[String: Any]] ?? [])
                .compactMap { ($0["id"] as? NSNumber)?.uint32Value })
            records[owner] = data
            if !consumed.subtracting(retained).isEmpty { onRemoval?() }
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
    private struct Fixture {
        let manager: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let stream: Stream
        let sender: XabberOMEMO2Storage
        let preKeyID: UInt32
    }
    private var originalRealm: Realm.Configuration!
    private var keeper: Realm?
    private var owners: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N06-restart-\(UUID())")
        keeper = try WRealm.safe()
    }
    override func tearDown() {
        owners.forEach { CredentialsManager.shared.removeDeviceId(for: $0) }
        owners.removeAll()
        keeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testAuthenticatedRestartDeletesUnclaimedConsumedOPKWithoutLaterCryptoOrMaintenance() throws {
        let f = try fixture()
        let identity = try f.storage.localBundle().identityKey
        let session = try XCTUnwrap(f.storage.sessionMetadata(jid: f.sender.owner, deviceID: 77))

        f.manager.configureLocal(f.stream, for: 42)
        try acknowledgeCurrentBundle(f)

        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertTrue(try f.storage.consumedPreKeyIDs().isEmpty, "Successful authentication must not depend on another receive or a publication watchdog to erase old consumed OPKs")
        XCTAssertFalse(f.manager.shouldPublicate)
        XCTAssertNil(f.manager.omemo2MaintenanceWorkItem)
        XCTAssertEqual(try f.storage.localBundle().identityKey, identity)
        let retained = try XCTUnwrap(f.storage.sessionMetadata(jid: f.sender.owner, deviceID: 77))
        XCTAssertEqual(retained.ephemeralKey, session.ephemeralKey)
        XCTAssertEqual(retained.receiveCounter, session.receiveCounter)
    }

    func testAuthenticatedRestartKeepsConsumedOPKWhileActualCatchUpQueryIsRegistered() async throws {
        let f = try fixture()
        let mam = MessageArchiveManager(withOwner: f.manager.owner)
        let messages = MessageManager(withOwner: f.manager.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = f.manager.omemo2PreKeyCleanup
        mam.omemo2CleanupMessages = messages
        let queryID = "restart-catch-up-\(UUID())"
        mam.requestArchive(f.stream, jid: f.sender.owner, isContinues: true,
            conversationType: .regular, purpose: .latest, queryId: queryID)

        f.manager.configureLocal(f.stream, for: 42)
        try acknowledgeCurrentBundle(f)

        XCTAssertEqual(try f.storage.consumedPreKeyIDs(), [f.preKeyID], "A real registered catch-up must adopt the persisted consumed key")
        XCTAssertNil(f.manager.omemo2MaintenanceWorkItem)
        let removed = expectation(description: "actual catch-up persistence terminal deletes OPK")
        f.memory.onRemoval = { removed.fulfill() }
        let final = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' from='\(f.manager.owner)' type='result' id='\(queryID)'><fin xmlns='urn:xmpp:mam:2' queryid='\(queryID)' complete='true'><set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin></iq>")
        XCTAssertTrue(mam.read(f.stream, withIQ: final))
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertTrue(try f.storage.consumedPreKeyIDs().isEmpty)
        XCTAssertTrue(try f.storage.sessionExists(jid: f.sender.owner, deviceID: 77))
    }

    func testUnauthenticatedPreparationDoesNotAdoptPersistedConsumedKeys() throws {
        let f = try fixture()
        f.stream.authenticated = false

        f.manager.configureLocal(f.stream, for: 42)

        XCTAssertEqual(try f.storage.consumedPreKeyIDs(), [f.preKeyID])
        XCTAssertTrue(try f.storage.sessionExists(jid: f.sender.owner, deviceID: 77))
    }

    private func fixture() throws -> Fixture {
        let owner = "restart-recipient-\(UUID().uuidString.lowercased())@example.test"
        owners.append(owner)
        let senderOwner = "restart-sender-\(UUID().uuidString.lowercased())@example.test"
        let memory = Memory()
        let original = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try original.prepare(deviceID: 42, preKeyCount: 3)
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        let sender = try XabberOMEMO2Storage(owner: senderOwner, persistence: memory)
        _ = try sender.prepare(deviceID: 77, preKeyCount: 3)
        try sender.initiateSession(jid: owner, deviceID: 42,
            bundle: OMEMO2PublishedBundle(bundle).selectedBundle(preKeyID: preKey.id))
        let envelope = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>before restart</body></content><rpad/><from jid='\(senderOwner)'/><to jid='\(owner)'/></envelope>"
        let payload = try Omemo2PayloadCodec.seal(Omemo2PayloadCodec.prepareOutgoingXML(envelope))
        let ciphertext = try sender.encrypt(payload.keyAndMAC, jid: owner, deviceID: 42)
        _ = try original.decrypt(ciphertext, jid: senderOwner, deviceID: 77, validating: { key in
            XCTAssertNotNil(try Omemo2PayloadCodec.openVerified(payload.ciphertext, keyAndMAC: key,
                expectedFrom: senderOwner, expectedTo: owner))
        })
        XCTAssertEqual(try original.consumedPreKeyIDs(), [preKey.id])
        let restored = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = restored
        manager.omemo2MaintenanceScheduler = { _, _ in }
        let account = AccountStorageItem()
        account.jid = owner
        account.isEncryptionEnabled = true
        let devices = OMEMO2DeviceListStorageItem()
        devices.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: owner)
        devices.owner = owner
        devices.jid = owner
        devices.isKnown = true
        devices.deviceIDs.append(42)
        devices.devicesXML = "<devices xmlns='urn:xmpp:omemo:2'><device id='42'/></devices>"
        let realm = try WRealm.safe()
        try realm.write { realm.add(account); realm.add(devices) }
        return Fixture(manager: manager, storage: restored, memory: memory,
            stream: Stream(), sender: sender, preKeyID: preKey.id)
    }

    private func acknowledgeCurrentBundle(_ f: Fixture) throws {
        let publication = try XCTUnwrap(f.stream.elements.last(where: {
            $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .element(forName: "publish")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue
        }))
        let id = try XCTUnwrap(publication.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: id)))
    }
}
