import XCTest
import Foundation
import RealmSwift
import XMPPFramework
@testable import xabber

/// Runs the real Account authentication/resumption callback and native OMEMO
/// preparation. The SM response and network I/O are supplied by fakes.
final class DevicesSessionResumePublicationTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var data: Data?
        func load(owner: String) throws -> Data? { data }
        func save(_ data: Data, owner: String) throws { self.data = data }
        func remove(owner: String) throws { data = nil }
    }
    private final class Stream: XMPPStream {
        private let packetLock = NSLock()
        private var sentPackets: [DDXMLElement] = []
        var packets: [DDXMLElement] {
            packetLock.lock()
            defer { packetLock.unlock() }
            return sentPackets
        }
        override var isAuthenticated: Bool { true }
        override var isConnected: Bool { true }
        override var isDisconnected: Bool { false }
        override func send(_ element: DDXMLElement) {
            let packet = element.copy() as! DDXMLElement
            packetLock.lock()
            sentPackets.append(packet)
            packetLock.unlock()
        }
    }
    private final class AuthenticationSM: XMPPStreamManagement {
        var resumeAccepted = true
        var usedCheckpoint = false
        override var didResume: Bool { resumeAccepted }
        override var didResumeFromCheckpoint: Bool { usedCheckpoint }
        override func didResume(withAckedStanzaIds stanzaIdsPtr: AutoreleasingUnsafeMutablePointer<NSArray?>?,
            serverResponse responsePtr: AutoreleasingUnsafeMutablePointer<DDXMLElement?>?) -> Bool {
            stanzaIdsPtr?.pointee = []
            responsePtr?.pointee = DDXMLElement(name: resumeAccepted ? "resumed" : "failed", xmlns: "urn:xmpp:sm:3")
            return resumeAccepted
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
            waitForAccountQueue(f.account)
            f.account.cancelStartupTrafficOrdering(); f.account.cancelDelayedConnectTimer()
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
    private func fixture(withReadinessCallbacks: Bool = false) throws -> Fixture {
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
        if !withReadinessCallbacks { account.sendReadiness.onReadinessChanged = nil }
        CredentialsManager.shared.getItem(for: owner).storePassword("fixture-password")
        let f = Fixture(account: account, wire: wire, storage: storage, memory: memory)
        fixtures.append(f); AccountManager.shared.users = previousUsers + fixtures.map(\.account)
        return f
    }
    private func response(_ f: Fixture, id: String, payload: String = "", condition: String? = nil) throws -> XMPPIQ {
        let body = condition.map { "<error type='cancel'><\($0) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>" } ?? payload
        return try XMPPIQ(xmlString: "<iq type='\(condition == nil ? "result" : "error")' id='\(id)' from='\(f.owner)' to='\(f.wire.myJID!.full)'>\(body)</iq>")
    }
    private func emptySyncPage(_ f: Fixture, id: String) throws -> XMPPIQ {
        try response(f, id: id, payload: """
        <query xmlns='https://xabber.com/protocol/synchronization' stamp='1793185595284531'>
          <set xmlns='http://jabber.org/protocol/rsm'><first index='0'>empty</first><last>empty</last><count>0</count></set>
        </query>
        """)
    }
    private func metadataCount(_ f: Fixture) -> Int {
        f.wire.packets.filter { $0.element(forName: "query", xmlns: devicesNS) != nil }.count
    }
    private func publicationCount(_ f: Fixture) -> Int {
        f.wire.packets.filter { $0.element(forName: "pubsub")?.element(forName: "publish")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue }.count
    }
    private func syncQueries(_ f: Fixture) -> [DDXMLElement] {
        f.wire.packets.filter {
            $0.element(forName: "query", xmlns: "https://xabber.com/protocol/synchronization") != nil
        }
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
        f.account.sm = AuthenticationSM(storage: f.account.smStorage, dispatchQueue: f.account.queue)
        f.account.xmppStreamDidAuthenticate(f.wire)
    }
    private func waitForAccountQueue(_ account: Account) {
        let drained = expectation(description: "account queue fence")
        account.queue.async { drained.fulfill() }
        // A queued Realm write may wait for a writer on the main run loop.
        wait(for: [drained], timeout: 5)
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
        let syncID = try XCTUnwrap(syncQueries(f).last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.syncManager.read(withIQ: try emptySyncPage(f, id: syncID)))
        f.account.syncManager.waitForPendingSnapshotApplies()
        waitForAccountQueue(f.account)
        f.account.sendStartupPresenceIfReady()
        waitForAccountQueue(f.account)
        let presence = try XCTUnwrap(f.wire.packets.compactMap { $0 as? XMPPPresence }.last {
            $0.to == nil && [nil, "", "available"].contains($0.type)
        })
        f.account.xmppStream(f.wire, didSend: presence)
        waitForAccountQueue(f.account)
        XCTAssertFalse(f.account.isStartupBackgroundTrafficBlocked,
            "Complete the real sync/presence release before testing a resumed completed startup")
        try driveToReady(f, handled: &handled)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        let generation = try XCTUnwrap(f.account.devices.authenticatedSessionGeneration(on: f.wire))
        let before = publicationCount(f)
        let syncCount = syncQueries(f).count
        f.account.resetModules(preservingDeviceBindingForResume: true)

        resume(f)
        waitForAccountQueue(f.account)

        XCTAssertFalse(f.account.isStartupBackgroundTrafficBlocked)
        XCTAssertEqual(syncQueries(f).count, syncCount, "Warm SM resume must not start another chat-list sync")
        XCTAssertFalse(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
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
    func testActualSMResumeRestartsAnInterruptedInitialSynchronization() throws {
        let f = try fixture()
        f.account.syncManager.isAvailable = true
        f.account.syncManager.prepareForAuthenticatedStream(didResume: false)
        XCTAssertTrue(f.account.syncManager.sync(f.wire))
        let interruptedID = try XCTUnwrap(syncQueries(f).first?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
        f.account.resetModules(preservingDeviceBindingForResume: true)
        XCTAssertFalse(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())

        resume(f)
        waitForAccountQueue(f.account)

        XCTAssertTrue(f.account.isStartupBackgroundTrafficBlocked)
        XCTAssertTrue(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
        XCTAssertFalse(f.account.syncManager.isStartupRecentsReady(),
                       "Resuming an interrupted fallback sync still requires its first page")
        let syncs = syncQueries(f)
        XCTAssertEqual(syncs.count, 2)
        XCTAssertNotEqual(syncs.last?.attributeStringValue(forName: "id"), interruptedID)
        XCTAssertEqual(metadataCount(f), 0)
        XCTAssertEqual(publicationCount(f), 0)
    }

    func testColdSMResumeSkipsChatListSyncAndKeepsServerPresence() throws {
        let f = try fixture(withReadinessCallbacks: true)
        f.account.devices.clearSession()
        f.account.syncManager.isAvailable = true
        let sm = AuthenticationSM(storage: f.account.smStorage, dispatchQueue: f.account.queue)
        sm.usedCheckpoint = true
        f.account.sm = sm
        XCTAssertFalse(f.account.syncManager.isStartupRecentsReady())

        f.account.xmppStreamDidAuthenticate(f.wire)
        XCTAssertTrue(f.account.syncManager.isStartupRecentsReady(),
                      "The accepted resume releases Recents without a sync response")
        waitForAccountQueue(f.account)

        XCTAssertFalse(f.account.isStartupBackgroundTrafficBlocked)
        XCTAssertFalse(f.account.syncManager.isStartupSynchronizationPending())
        XCTAssertFalse(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
        XCTAssertTrue(syncQueries(f).isEmpty)
        XCTAssertGreaterThan(metadataCount(f), 0, "Devices should be prepared when the checkpoint restores presence")
        XCTAssertNil(f.account.devices.authenticatedSessionGeneration(on: f.wire),
                     "A cached device ID is not a live Devices authentication proof")
        XCTAssertFalse(f.wire.packets.contains { $0.name == "presence" && $0.attributeStringValue(forName: "to") == nil })
    }

    func testRejectedSMResumeStillStartsChatListSyncAfterBindingAndSMEnable() throws {
        let f = try fixture(withReadinessCallbacks: true)
        f.account.syncManager.isAvailable = true
        let sm = AuthenticationSM(storage: f.account.smStorage, dispatchQueue: f.account.queue)
        sm.resumeAccepted = false
        f.account.sm = sm

        f.account.xmppStreamDidAuthenticate(f.wire)

        XCTAssertTrue(f.account.syncManager.isStartupSynchronizationPending())
        XCTAssertFalse(f.account.syncManager.isStartupRecentsReady())
        XCTAssertFalse(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
        XCTAssertTrue(syncQueries(f).isEmpty)

        f.account.xmppStreamManagement(sm, wasEnabled: DDXMLElement(name: "enabled", xmlns: "urn:xmpp:sm:3"))
        waitForAccountQueue(f.account)

        XCTAssertEqual(syncQueries(f).count, 1)
        XCTAssertTrue(f.account.isStartupBackgroundTrafficBlocked)
        XCTAssertTrue(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
        XCTAssertFalse(f.account.syncManager.isStartupRecentsReady())

        let syncID = try XCTUnwrap(syncQueries(f).first?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.syncManager.read(withIQ: try emptySyncPage(f, id: syncID)))
        f.account.syncManager.waitForPendingSnapshotApplies()

        XCTAssertFalse(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
        XCTAssertTrue(f.account.syncManager.isStartupRecentsReady())
    }

    func testLegacyRosterRequestDoesNotMarkRecentsAsWaitingForSync() throws {
        let f = try fixture()
        let sm = AuthenticationSM(storage: f.account.smStorage, dispatchQueue: f.account.queue)
        sm.resumeAccepted = false
        f.account.sm = sm

        f.account.xmppStreamDidAuthenticate(f.wire)

        XCTAssertTrue(f.wire.packets.contains { $0.element(forName: "query", xmlns: "jabber:iq:roster") != nil })
        XCTAssertFalse(f.account.syncManager.isAwaitingStartupRecentsSyncResponse())
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
