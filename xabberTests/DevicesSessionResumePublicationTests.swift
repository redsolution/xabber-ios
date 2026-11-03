import XCTest
import Foundation
import RealmSwift
import XMPPFramework
@testable import xabber

/// Runs the real Account authentication/resumption callback and native OMEMO
/// preparation. Only accepted SM response and network I/O are supplied by fakes.
final class DevicesSessionResumePublicationTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var data: Data?
        func load(owner: String) throws -> Data? { data }
        func save(_ data: Data, owner: String) throws { self.data = data }
        func remove(owner: String) throws { data = nil }
    }
    private final class Stream: XMPPStream {
        var packets: [DDXMLElement] = []
        override var isAuthenticated: Bool { true }
        override var isConnected: Bool { true }
        override var isDisconnected: Bool { false }
        override func send(_ element: DDXMLElement) { packets.append(element.copy() as! DDXMLElement) }
    }
    private final class ResumedSM: XMPPStreamManagement {
        override var didResume: Bool { true }
        override func didResume(withAckedStanzaIds stanzaIdsPtr: AutoreleasingUnsafeMutablePointer<NSArray?>?,
            serverResponse responsePtr: AutoreleasingUnsafeMutablePointer<DDXMLElement?>?) -> Bool {
            stanzaIdsPtr?.pointee = []
            responsePtr?.pointee = DDXMLElement(name: "resumed", xmlns: "urn:xmpp:sm:3")
            return true
        }
    }
    private struct Fixture {
        let account: Account
        let wire: Stream
        let storage: XabberOMEMO2Storage
        let memory: Memory
        var manager: OmemoManager { account.omemo }
        var owner: String { account.jid }
    }
    private var previousRealm: Realm.Configuration!
    private var keeper: Realm!
    private var previousUsers: [Account] = []
    private var previousActiveUsers: Set<String> = []
    private var previousAuthenticatedUsers: Set<String> = []
    private var previousConnectingUsers: Set<String> = []
    private var fixtures: [Fixture] = []
    private let devicesNS = "https://xabber.com/protocol/devices#items"
    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: UUID().uuidString)
        keeper = try WRealm.safe(); previousUsers = AccountManager.shared.users
        previousActiveUsers = AccountManager.shared.activeUsers.value
        previousAuthenticatedUsers = AccountManager.shared.authenticatedUsers.value
        previousConnectingUsers = AccountManager.shared.connectingUsers.value
    }
    override func tearDownWithError() throws {
        guard previousRealm != nil else { return }
        for f in fixtures {
            f.account.syncManager.waitForPendingSnapshotApplies()
            f.account.queue.sync {}; f.account.cancelStartupTrafficOrdering(); f.account.cancelDelayedConnectTimer()
            f.manager.omemo2MaintenanceWorkItem?.cancel(); f.manager.clearSession()
            f.account.xmppTaskScheduler.reset(); f.account.messages.updateSendingMessagesTimer?.invalidate()
            CredentialsManager.shared.getItem(for: f.owner).release(.authFailedRecoverable)
            CredentialsManager.shared.removeDeviceId(for: f.owner)
            ClientSynchronizationManager.remove(for: f.owner, commitTransaction: false)
        }
        AccountManager.shared.users = previousUsers
        AccountManager.shared.activeUsers.accept(previousActiveUsers)
        AccountManager.shared.authenticatedUsers.accept(previousAuthenticatedUsers)
        AccountManager.shared.connectingUsers.accept(previousConnectingUsers)
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        try super.tearDownWithError()
    }
    private func fixture() throws -> Fixture {
        let owner = "devices-resume-\(UUID().uuidString.lowercased())@example.test"
        let row = AccountStorageItem(); row.jid = owner; row.isEncryptionEnabled = true
        row.deviceUuid = "current-device"
        try keeper.write { keeper.add(row) }
        let memory = Memory(), storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        _ = try storage.prepare(deviceID: 42, preKeyCount: 2)
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        account.omemo.omemo2Storage = storage; account.omemo.omemo2MaintenanceScheduler = { _, _ in }
        let wire = Stream(); wire.myJID = XMPPJID(string: owner + "/current"); account.xmppStream = wire
        let features = DDXMLElement(name: "features")
        features.addChild(DDXMLElement(name: "devices", xmlns: "https://xabber.com/protocol/devices"))
        account.devices.setAvailable(features)
        account.devices.recordAuthenticatedSession(on: wire, deviceID: "current-device", didResume: false)
        account.syncManager.isAvailable = false
        account.isRegularPushRequestSended = true; account.isVoIPPushRequestSended = true
        account.sendReadiness.onReadinessChanged = nil
        CredentialsManager.shared.getItem(for: owner).storePassword("fixture-password")
        let f = Fixture(account: account, wire: wire, storage: storage, memory: memory)
        fixtures.append(f); AccountManager.shared.users = previousUsers + fixtures.map(\.account)
        return f
    }
    private func response(_ f: Fixture, id: String, payload: String = "", condition: String? = nil) throws -> XMPPIQ {
        let body = condition.map { "<error type='cancel'><\($0) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>" } ?? payload
        return try XMPPIQ(xmlString: "<iq type='\(condition == nil ? "result" : "error")' id='\(id)' from='\(f.owner)' to='\(f.wire.myJID!.full)'>\(body)</iq>")
    }
    private func metadataCount(_ f: Fixture) -> Int {
        f.wire.packets.filter { $0.element(forName: "query", xmlns: devicesNS) != nil }.count
    }
    private func publicationCount(_ f: Fixture) -> Int {
        f.wire.packets.filter { $0.element(forName: "pubsub")?.element(forName: "publish")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue }.count
    }
    private func driveToReady(_ f: Fixture, handled: inout Set<String>) throws {
        for _ in 0..<40 {
            if f.manager.isOmemoPrepared { return }
            guard let packet = f.wire.packets.first(where: { p in
                guard let id = p.attributeStringValue(forName: "id"), !handled.contains(id) else { return false }
                return p.element(forName: "query", xmlns: devicesNS) != nil || p.element(forName: "pubsub") != nil
            }), let id = packet.attributeStringValue(forName: "id") else { return }
            handled.insert(id)
            let reply: XMPPIQ
            if packet.element(forName: "query", xmlns: devicesNS) != nil {
                reply = try response(f, id: id, payload: "<query xmlns='\(devicesNS)'><device xmlns='https://xabber.com/protocol/devices' id='current-device'><omemo-id>42</omemo-id></device></query>")
            } else if let items = packet.element(forName: "pubsub")?.element(forName: "items") {
                let node = items.attributeStringValue(forName: "node") ?? ""
                let child: String
                if node == OmemoManager.NodeType.device.rawValue {
                    child = "<item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='42'/></devices></item>"
                } else {
                    child = try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(f.storage.localBundle())).xmlString
                }
                reply = try response(f, id: id, payload: "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(node)'>\(child)</items></pubsub>")
            } else { reply = try response(f, id: id) }
            _ = f.account.xmppStream(f.wire, didReceive: reply)
        }
    }
    private func resume(_ f: Fixture) {
        f.account.sm = ResumedSM(storage: f.account.smStorage, dispatchQueue: f.account.queue)
        f.account.xmppStreamDidAuthenticate(f.wire)
    }
    func testActualSMResumeRepreparesManagedOMEMOAfterAccidentalReset() throws {
        let f = try fixture(); var handled = Set<String>()
        f.manager.beginOMEMO2Registration(f.wire)
        try driveToReady(f, handled: &handled)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        let identity = try f.storage.identity().publicKey
        let generation = try XCTUnwrap(f.account.devices.authenticatedSessionGeneration(on: f.wire))
        let before = publicationCount(f)
        f.account.resetModules(preservingDeviceBindingForResume: true)
        XCTAssertFalse(f.manager.isOmemoPrepared)

        resume(f)

        XCTAssertEqual(f.account.devices.authenticatedSessionGeneration(on: f.wire), generation)
        XCTAssertNotNil(f.manager.omemo2ManagedDevicesPublication.pending)
        try driveToReady(f, handled: &handled)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertEqual(publicationCount(f), before + 1)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
    }
    func testActualSMResumeRepreparesAfterCompletedSyncAndPresenceRelease() throws {
        let f = try fixture(); var handled = Set<String>()
        f.account.syncManager.isAvailable = true
        f.account.syncManager.prepareForAuthenticatedStream(didResume: false)
        f.account.sendReadiness.markStreamManagementResumeSucceeded()
        f.account.roster.isInitialRosterReceived = true
        XCTAssertTrue(f.account.syncManager.sync(f.wire))
        let syncRequest = try XCTUnwrap(f.wire.packets.last {
            $0.element(forName: "query", xmlns: "https://xabber.com/protocol/synchronization") != nil
        })
        let syncID = try XCTUnwrap(syncRequest.attributeStringValue(forName: "id"))
        let emptyPage = try response(f, id: syncID, payload: "<query xmlns='https://xabber.com/protocol/synchronization' stamp='1793185595284531'><set xmlns='http://jabber.org/protocol/rsm'><first index='0'>empty</first><last>empty</last><count>0</count></set></query>")
        XCTAssertTrue(f.account.syncManager.read(withIQ: emptyPage))
        f.account.syncManager.waitForPendingSnapshotApplies()
        f.account.queue.sync {}
        f.account.sendStartupPresenceIfReady()
        f.account.queue.sync {}
        let presence = try XCTUnwrap(f.wire.packets.compactMap { $0 as? XMPPPresence }.last {
            $0.to == nil && [nil, "", "available"].contains($0.type)
        })
        f.account.xmppStream(f.wire, didSend: presence)
        f.account.queue.sync {}
        XCTAssertFalse(f.account.isStartupBackgroundTrafficBlocked,
            "Complete the real sync/presence release before testing a resumed completed startup")
        try driveToReady(f, handled: &handled)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        let generation = try XCTUnwrap(f.account.devices.authenticatedSessionGeneration(on: f.wire))
        let before = publicationCount(f)
        f.account.resetModules(preservingDeviceBindingForResume: true)

        resume(f)

        XCTAssertFalse(f.account.isStartupBackgroundTrafficBlocked)
        XCTAssertEqual(f.account.devices.authenticatedSessionGeneration(on: f.wire), generation)
        XCTAssertNotNil(f.manager.omemo2ManagedDevicesPublication.pending)
        try driveToReady(f, handled: &handled)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertEqual(publicationCount(f), before + 1)
    }
    func testActualSMResumeDoesNotLiftSameAuthenticationPolicyBlock() throws {
        let f = try fixture(); var handled = Set<String>()
        f.manager.beginOMEMO2Registration(f.wire)
        // Stop immediately before supplying the real publication result.
        try driveUntilPublication(f, handled: &handled)
        let id = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        _ = f.manager.read(withIQ: try response(f, id: id, condition: "policy-violation"), on: f.wire)
        let generation = try XCTUnwrap(f.account.devices.authenticatedSessionGeneration(on: f.wire))
        f.account.resetModules(preservingDeviceBindingForResume: true)
        let before = metadataCount(f), publications = publicationCount(f)

        resume(f)

        XCTAssertEqual(f.account.devices.authenticatedSessionGeneration(on: f.wire), generation)
        XCTAssertEqual(metadataCount(f), before)
        XCTAssertEqual(publicationCount(f), publications)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertNotNil(f.manager.omemo2ManagedDevicesPublication.blocked)
    }
    func testActualSMResumeDoesNotBypassPendingInitialSynchronization() throws {
        let f = try fixture()
        f.account.syncManager.isAvailable = true
        f.account.prepareStartupTrafficOrdering(didResume: false)
        f.account.resetModules(preservingDeviceBindingForResume: true)

        resume(f)

        XCTAssertTrue(f.account.isStartupBackgroundTrafficBlocked)
        XCTAssertEqual(metadataCount(f), 0)
        XCTAssertEqual(publicationCount(f), 0)
    }
    private func driveUntilPublication(_ f: Fixture, handled: inout Set<String>) throws {
        for _ in 0..<30 {
            if !f.manager.omemo2BundlePublications.isEmpty { return }
            guard let packet = f.wire.packets.first(where: { p in
                guard let id = p.attributeStringValue(forName: "id") else { return false }; return !handled.contains(id)
            }), let id = packet.attributeStringValue(forName: "id") else { return }
            handled.insert(id)
            let payload: String
            if packet.element(forName: "query", xmlns: devicesNS) != nil {
                payload = "<query xmlns='\(devicesNS)'><device xmlns='https://xabber.com/protocol/devices' id='current-device'><omemo-id>42</omemo-id></device></query>"
            } else if let items = packet.element(forName: "pubsub")?.element(forName: "items") {
                let node = items.attributeStringValue(forName: "node") ?? ""
                let child = node == OmemoManager.NodeType.device.rawValue
                    ? "<item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='42'/></devices></item>"
                    : try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(f.storage.localBundle())).xmlString
                payload = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(node)'>\(child)</items></pubsub>"
            } else { continue }
            _ = f.manager.read(withIQ: try response(f, id: id, payload: payload), on: f.wire)
        }
    }
}
