import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Executes the public account/OMEMO lifecycle with isolated storage and a
/// stream whose send method only captures XML. No socket can be opened here.
final class OMEMO2ManagerLifecycleBehaviorTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }

    private final class CapturingStream: XMPPStream {
        private let lock = NSLock()
        private var captured: [DDXMLElement] = []
        var authenticated = false
        var disconnected = false
        override var isAuthenticated: Bool { authenticated }
        override var isDisconnected: Bool { disconnected }
        override func send(_ element: DDXMLElement) {
            lock.lock()
            captured.append(element.copy() as! DDXMLElement)
            lock.unlock()
        }
        var elements: [DDXMLElement] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
        func clear() {
            lock.lock()
            captured.removeAll()
            lock.unlock()
        }
    }

    private struct Fixture {
        let account: Account
        let manager: OmemoManager
        let memory: Memory
        let storage: XabberOMEMO2Storage
        let stream: CapturingStream
        let peer: String
    }

    private var originalRealm: Realm.Configuration!
    private var realmKeeper: Realm?
    private var originalUsers: [Account] = []
    private var accounts: [Account] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: environment),
            "This suite requires isolated storage and disabled account autoconnect")
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "OMEMO-manager-lifecycle-\(UUID())")
        realmKeeper = try WRealm.safe()
        originalUsers = AccountManager.shared.users
    }

    override func tearDownWithError() throws {
        guard originalRealm != nil else {
            try super.tearDownWithError()
            return
        }
        XMPPUIActionManager.shared.resetPendingAuthenticationForTests()
        for account in accounts {
            account.queue.sync {}
            account.omemo.omemo2MaintenanceWorkItem?.cancel()
            account.omemo.omemo2MaintenanceWorkItem = nil
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            account.xmppTaskScheduler.reset()
            CredentialsManager.shared.removeDeviceId(for: account.jid)
            try? CredentialsManager.shared.removeOMEMO2State(for: account.jid)
        }
        AccountManager.shared.users = originalUsers
        accounts.removeAll()
        realmKeeper = nil
        if let originalRealm { Realm.Configuration.defaultConfiguration = originalRealm }
        try super.tearDownWithError()
    }

    func testDisconnectedPreparedStreamCannotResetRequestsOrStartRegistration() throws {
        let f = try fixture(prepared: false)
        f.manager.getContactBundle(f.stream, jid: f.peer, deviceId: 77, force: true)
        let request = try XCTUnwrap(f.stream.elements.first?.attributeStringValue(forName: "id"))
        f.stream.clear()
        f.stream.disconnected = true

        f.manager.onStreamPrepared(f.stream)

        XCTAssertTrue(f.stream.elements.isEmpty)
        XCTAssertNotNil(f.manager.omemo2BundleRequests[request])
        XCTAssertTrue(f.manager.queryIds.contains(request))
        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertNil(f.manager.omemo2RegistrationStream)
    }

    func testEnabledUnpreparedStreamResetsOldRequestsAndFetchesCurrentOwnMembershipBeforeKeys() throws {
        let f = try fixture(prepared: false)
        f.manager.getContactBundle(f.stream, jid: f.peer, deviceId: 77, force: true)
        let oldID = try XCTUnwrap(f.stream.elements.first?.attributeStringValue(forName: "id"))
        f.stream.clear()
        f.manager.omemo2FreshDeviceIDGenerator = { XCTFail("Stream preparation must await own membership"); return 42 }

        f.manager.onStreamPrepared(f.stream)

        XCTAssertFalse(f.manager.queryIds.contains(oldID))
        XCTAssertNil(f.manager.omemo2BundleRequests[oldID])
        XCTAssertTrue(f.manager.omemo2FreshRegistrationPending)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertTrue(f.memory.records.isEmpty)
        let requests = requests(f.stream, node: .device)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.attributeStringValue(forName: "to"))
        XCTAssertTrue(publications(f.stream, node: .bundle).isEmpty)
    }

    func testDisabledUnpreparedStreamCannotCreateKeysOrPublishRegistration() throws {
        let f = try fixture(enabled: false, prepared: false)

        f.manager.onStreamPrepared(f.stream)

        XCTAssertTrue(f.stream.elements.isEmpty)
        XCTAssertTrue(f.memory.records.isEmpty)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertFalse(f.manager.omemo2FreshRegistrationPending)
        XCTAssertNil(CredentialsManager.shared.getDeviceId(for: f.manager.owner))
    }

    func testEnabledPreparedStreamReusesNativeIdentityAndPublishesOnlyTheCurrentOwnRegistration() throws {
        let f = try fixture()
        try ownSnapshot(f, ids: [42, 99])
        let identity = try f.storage.identity().publicKey
        let contact = try addDevice(owner: f.manager.owner, jid: f.peer, id: 77)
        try WRealm.safe().write { contact.freshlyUpdated = true }

        f.manager.onStreamPrepared(f.stream)
        drainAccount(f)

        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertFalse(f.manager.omemo2FreshRegistrationPending)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertEqual(f.manager.localStore.localDeviceId(), 42)
        XCTAssertEqual(CredentialsManager.shared.getDeviceId(for: f.manager.owner), 42)
        XCTAssertFalse(contact.freshlyUpdated)
        XCTAssertEqual(publications(f.stream, node: .bundle).map { $0.attributeIntegerValue(forName: "id") }, [42])
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 99])
    }

    func testDisabledPreparedStreamPreservesKeysWhileWithdrawingItsOwnAdvertisement() throws {
        let f = try fixture(enabled: false)
        try ownSnapshot(f, ids: [42, 99])
        let identity = try f.storage.identity().publicKey

        f.manager.onStreamPrepared(f.stream)
        drainAccount(f)

        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [99])
        XCTAssertTrue(publications(f.stream, node: .bundle).isEmpty)
        XCTAssertEqual(retractions(f.stream, node: .bundle).map { $0.attributeIntegerValue(forName: "id") }, [42])
    }

    func testPrepareSecretChatForcesARealDeviceFetchWithoutCreatingOrChangingHistory() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        let regular = try addChat(owner: f.manager.owner, jid: f.peer, type: .regular)
        try WRealm.safe().write { regular.lastMessageId = "regular-message" }
        withUIAction(f) { ui in
            f.manager.prepareSecretChat(wit: f.peer, success: nil, fail: nil)
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 1)
            XCTAssertTrue(f.stream.elements.isEmpty)
            resumeUIAction(ui, fixture: f)
        }

        XCTAssertEqual(requests(f.stream, node: .device).map { $0.attributeStringValue(forName: "to") }, [f.peer])
        XCTAssertEqual(regular.lastMessageId, "regular-message")
        XCTAssertNil(try chat(owner: f.manager.owner, jid: f.peer, type: .omemo))
        let snapshot = try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: WRealm.safe(), owner: f.manager.owner, jid: f.peer))
        let requestID = try XCTUnwrap(requests(f.stream, node: .device).only?.attributeStringValue(forName: "id"))
        XCTAssertEqual(snapshot.pendingRequestID, requestID)
        XCTAssertEqual(Array(snapshot.deviceIDs), [77])
    }

    func testPrepareSecretChatFallsBackToTheActualAccountQueueWhenUIRequestFails() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        withUIAction(f) { ui in
            f.manager.prepareSecretChat(wit: f.peer, success: nil, fail: nil)
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 1)
            failUIAction(ui, fixture: f)
        }

        XCTAssertEqual(requests(f.stream, node: .device).map { $0.attributeStringValue(forName: "to") }, [f.peer])
        XCTAssertNil(try chat(owner: f.manager.owner, jid: f.peer, type: .omemo))
    }

    func testInitChatCreatesExactlyOneOwnedOMEMORowWithRosterAndPreservesRegularHistory() throws {
        let f = try fixture()
        let roster = try addRoster(owner: f.manager.owner, jid: f.peer)
        let regular = try addChat(owner: f.manager.owner, jid: f.peer, type: .regular)
        let history = MessageStorageItem()
        history.owner = f.manager.owner
        history.opponent = f.peer
        history.messageId = "regular-history"
        history.primary = "regular-history-\(UUID())"
        history.body = "already decrypted history"
        let date = Date(timeIntervalSince1970: 123)
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(history)
            regular.lastMessage = history
            regular.lastMessageId = history.messageId
            regular.messageDate = date
        }
        withUIAction(f) { ui in
            f.manager.initChat(jid: f.peer)
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 1)
            resumeUIAction(ui, fixture: f)
        }

        let encrypted = try XCTUnwrap(chat(owner: f.manager.owner, jid: f.peer, type: .omemo))
        XCTAssertEqual(encrypted.owner, f.manager.owner)
        XCTAssertEqual(encrypted.jid, f.peer)
        XCTAssertEqual(encrypted.conversationType, .omemo)
        XCTAssertTrue(encrypted.isFreshNotEmptyEncryptedChat)
        XCTAssertEqual(encrypted.rosterItem?.primary, roster.primary)
        XCTAssertEqual(regular.lastMessage?.body, "already decrypted history")
        XCTAssertEqual(regular.lastMessageId, "regular-history")
        XCTAssertEqual(regular.messageDate, date)
        XCTAssertEqual(try WRealm.safe().objects(MessageStorageItem.self).count, 1)
        XCTAssertEqual(requests(f.stream, node: .device).count, 1)
    }

    func testInitChatReusesTheExactOMEMORowAndKnownDeviceListWithoutResettingState() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        let encrypted = try addChat(owner: f.manager.owner, jid: f.peer, type: .omemo)
        let date = Date(timeIntervalSince1970: 345)
        try WRealm.safe().write {
            encrypted.messageDate = date
            encrypted.lastMessageId = "encrypted-history"
            encrypted.draftMessage = "unsent draft"
            encrypted.isFreshNotEmptyEncryptedChat = false
        }
        let foreign = try addChat(owner: "other-owner@example.test", jid: f.peer, type: .omemo)
        withUIAction(f) { ui in
            f.manager.initChat(jid: f.peer)
            f.manager.initChat(jid: f.peer)
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 2)
            resumeUIAction(ui, fixture: f)
        }

        XCTAssertEqual(try WRealm.safe().objects(LastChatsStorageItem.self).filter("owner == %@ AND jid == %@", f.manager.owner, f.peer).count, 1)
        XCTAssertEqual(encrypted.messageDate, date)
        XCTAssertEqual(encrypted.lastMessageId, "encrypted-history")
        XCTAssertEqual(encrypted.draftMessage, "unsent draft")
        XCTAssertFalse(encrypted.isFreshNotEmptyEncryptedChat)
        XCTAssertFalse(foreign.isInvalidated)
        XCTAssertTrue(requests(f.stream, node: .device).isEmpty)
    }

    func testInitChatRetainsTheCreatedRowWhenDeviceFetchUsesAccountFallback() throws {
        let f = try fixture()
        try withUIAction(f) { ui in
            f.manager.initChat(jid: f.peer)
            XCTAssertNotNil(try chat(owner: f.manager.owner, jid: f.peer, type: .omemo))
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 1)
            failUIAction(ui, fixture: f)
        }

        XCTAssertNotNil(try chat(owner: f.manager.owner, jid: f.peer, type: .omemo))
        XCTAssertEqual(requests(f.stream, node: .device).map { $0.attributeStringValue(forName: "to") }, [f.peer])
    }

    func testSubscribeAndUnsubscribeCarryUniqueIQIDsExactNodesAndOwnerSubscriber() throws {
        let f = try fixture()
        for node in [OmemoManager.NodeType.device, .bundle, .update, .trustList] {
            f.manager.subscribeNode(f.stream, jid: f.peer, node: node)
            f.manager.unsubscribeNode(f.stream, jid: f.peer, node: node)
        }

        let packets = f.stream.elements
        XCTAssertEqual(packets.count, 8)
        let ids = try packets.map { try XCTUnwrap($0.attributeStringValue(forName: "id")) }
        XCTAssertEqual(Set(ids).count, ids.count)
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(packet.attributeStringValue(forName: "type"), "set")
            XCTAssertEqual(packet.attributeStringValue(forName: "to"), f.peer)
            let pubsub = try XCTUnwrap(packet.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"))
            let operation = try XCTUnwrap(pubsub.element(forName: index.isMultiple(of: 2) ? "subscribe" : "unsubscribe"))
            XCTAssertEqual(operation.attributeStringValue(forName: "jid"), f.manager.owner)
            XCTAssertEqual(operation.attributeStringValue(forName: "node"), [OmemoManager.NodeType.device, .bundle, .update, .trustList][index / 2].rawValue)
            if index.isMultiple(of: 2) { XCTAssertTrue(f.manager.queryIds.contains(ids[index])) }
        }
    }

    func testBulkBundleRefreshForcesEveryCachedDeviceOfTheExactOwnerAndPeer() throws {
        let f = try fixture()
        try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        try addIdentity(owner: f.manager.owner, jid: f.peer, id: 88)
        try addIdentity(owner: f.manager.owner, jid: "unrelated@example.test", id: 66)
        try addIdentity(owner: "other-owner@example.test", jid: f.peer, id: 55)

        f.manager.getAllContactsBundle(f.stream, jid: f.peer)

        let requested = requests(f.stream, node: .bundle)
        XCTAssertEqual(try Set(requested.map(requestDeviceID)), [77, 88])
        XCTAssertTrue(requested.allSatisfy { $0.attributeStringValue(forName: "to") == f.peer })
        XCTAssertEqual(Set(f.manager.omemo2BundleRequests.values.map { $0.jid }), [f.peer])
        XCTAssertEqual(Set(f.manager.omemo2BundleRequests.values.map { $0.deviceID }), [77, 88])
        for packet in requested {
            XCTAssertTrue(f.manager.queryIds.contains(try XCTUnwrap(packet.attributeStringValue(forName: "id"))))
        }
    }

    func testOwnBulkBundleRefreshUsesSenderlessOwnPEPAndExcludesPeerAndForeignOwnerCaches() throws {
        let f = try fixture()
        try addIdentity(owner: f.manager.owner, jid: f.manager.owner, id: 99)
        try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        try addIdentity(owner: "other-owner@example.test", jid: f.manager.owner, id: 55)

        f.manager.getAllContactsBundle(f.stream, jid: f.manager.owner)

        let requested = requests(f.stream, node: .bundle)
        XCTAssertEqual(try Set(requested.map(requestDeviceID)), [42, 99])
        XCTAssertTrue(requested.allSatisfy { $0.attributeStringValue(forName: "to") == nil })
        let local = try XCTUnwrap(f.manager.omemo2BundleRequests.values.first { $0.deviceID == 42 })
        XCTAssertTrue(local.isOwnLocalDevice)
        XCTAssertFalse(try XCTUnwrap(f.manager.omemo2BundleRequests.values.first { $0.deviceID == 99 }).isOwnLocalDevice)
    }

    func testDeleteDeviceRemovesOnlyTheChosenOwnProjectionAndPublishesItsRemovalAndBundleRetraction() throws {
        let f = try fixture()
        try ownSnapshot(f, ids: [42, 99, 100])
        let own = try addDevice(owner: f.manager.owner, jid: f.manager.owner, id: 99)
        let identity = try addIdentity(owner: f.manager.owner, jid: f.manager.owner, id: 99)
        let contact = try addDevice(owner: f.manager.owner, jid: f.peer, id: 99)
        let foreign = try addDevice(owner: "other-owner@example.test", jid: f.manager.owner, id: 99)
        let history = try addChat(owner: f.manager.owner, jid: f.peer, type: .omemo)

        f.manager.deleteDevice(deviceId: 99)
        drainAccount(f)

        XCTAssertTrue(own.isInvalidated)
        XCTAssertTrue(identity.isInvalidated)
        XCTAssertFalse(contact.isInvalidated)
        XCTAssertFalse(foreign.isInvalidated)
        XCTAssertFalse(history.isInvalidated)
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 100])
        XCTAssertEqual(retractions(f.stream, node: .bundle).map { $0.attributeIntegerValue(forName: "id") }, [99])
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
    }

    func testDeleteBundleUsesExactBareDestinationNodeItemAndCorrelatedIQWithoutRemovingOtherCaches() throws {
        let f = try fixture()
        let identity = try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        let device = try addDevice(owner: f.manager.owner, jid: f.peer, id: 77)

        f.manager.deleteDeviceOrBundle(f.stream, jid: XMPPJID(string: f.peer + "/resource"), itemId: 77, node: .bundle)

        let packet = try XCTUnwrap(f.stream.elements.first)
        XCTAssertEqual(packet.attributeStringValue(forName: "to"), f.peer)
        XCTAssertEqual(packet.attributeStringValue(forName: "type"), "set")
        XCTAssertEqual(retractions(f.stream, node: .bundle).map { $0.attributeIntegerValue(forName: "id") }, [77])
        XCTAssertTrue(f.manager.queryIds.contains(try XCTUnwrap(packet.attributeStringValue(forName: "id"))))
        XCTAssertFalse(identity.isInvalidated)
        XCTAssertFalse(device.isInvalidated)
    }

    func testDeleteOwnDeviceNodeCannotEraseContactDevicesWithTheSameNumericID() throws {
        let f = try fixture()
        try ownSnapshot(f, ids: [42, 99])
        let own = try addDevice(owner: f.manager.owner, jid: f.manager.owner, id: 99)
        let contact = try addDevice(owner: f.manager.owner, jid: f.peer, id: 99)
        let foreign = try addDevice(owner: "other-owner@example.test", jid: f.manager.owner, id: 99)

        f.manager.deleteDeviceOrBundle(f.stream, jid: nil, itemId: 99, node: .device)

        XCTAssertTrue(own.isInvalidated)
        XCTAssertFalse(contact.isInvalidated, "A device ID is scoped by owner and peer JID")
        XCTAssertFalse(foreign.isInvalidated)
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42])
        XCTAssertTrue(retractions(f.stream, node: .bundle).isEmpty)
    }

    func testBundleHeadlineRejectsMissingSenderWrongNamespaceWrongNodeAndMissingItem() throws {
        let f = try fixture()
        for xml in [
            "<message type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:bundles'><item id='77'/></items></event></message>",
            "<message from='\(f.peer)' type='headline'><event xmlns='urn:foreign'><items node='urn:xmpp:omemo:2:bundles'><item id='77'/></items></event></message>",
            "<message from='\(f.peer)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='77'/></items></event></message>",
            "<message from='\(f.peer)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:bundles'/></event></message>"
        ] {
            XCTAssertFalse(f.manager.onContactDeviceReceiveHeadline(try XMPPMessage(xmlString: xml)))
        }
        drainMainRunLoop()

        XCTAssertNil(try WRealm.safe().object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: f.manager.owner, jid: f.peer, deviceId: 77)))
    }

    func testBundleHeadlineProjectsValidatedNativePublicKeysIntoOnlyTheSenderDeviceSlot() throws {
        let f = try fixture()
        let bundle = try peerBundle(owner: f.peer, id: 77)
        let message = try bundleHeadline(from: f.peer + "/pep", bundle: bundle)
        let foreign = try addIdentity(owner: "other-owner@example.test", jid: f.peer, id: 77)

        XCTAssertTrue(f.manager.onContactDeviceReceiveHeadline(message))
        drainMainRunLoop()

        let cached = try XCTUnwrap(WRealm.safe().object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: f.manager.owner, jid: f.peer, deviceId: 77)))
        XCTAssertEqual(cached.identityKey, bundle.identityKey.base64EncodedString())
        XCTAssertEqual(cached.protocolProfile, OmemoManager.xmlns)
        XCTAssertEqual(cached.signedPreKeyId, Int(bundle.signedPreKeyID))
        XCTAssertEqual(try WRealm.safe().objects(SignalPreKeysStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND deviceId == %@", f.manager.owner, f.peer, 77).count, bundle.preKeys.count)
        let device = try XCTUnwrap(WRealm.safe().object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: f.manager.owner, jid: f.peer, deviceId: 77)))
        XCTAssertEqual(device.state, .unknown)
        XCTAssertEqual(device.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey))
        XCTAssertFalse(foreign.isInvalidated)
        XCTAssertNotEqual(foreign.identityKey, cached.identityKey)
    }

    func testMalformedBundleHeadlineCannotReplaceCachedNativeIdentityOrDeviceTrust() throws {
        let f = try fixture()
        let cached = try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        let original = cached.identityKey
        let device = try addDevice(owner: f.manager.owner, jid: f.peer, id: 77)
        try WRealm.safe().write { device.state = .trusted }
        let message = try bundleHeadline(from: f.peer, bundle: peerBundle(owner: f.peer, id: 77))
        let signature = try XCTUnwrap(message.element(forName: "event")?.element(forName: "items")?
            .element(forName: "item")?.element(forName: "bundle")?.element(forName: "spks"))
        signature.stringValue = Data(repeating: 0, count: 64).base64EncodedString()

        XCTAssertTrue(f.manager.onContactDeviceReceiveHeadline(message))
        drainMainRunLoop()

        XCTAssertEqual(cached.identityKey, original)
        XCTAssertEqual(device.state, .trusted)
        XCTAssertEqual(try WRealm.safe().objects(SignalPreKeysStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND deviceId == %@", f.manager.owner, f.peer, 77).count, 0)
    }

    func testEncryptionUpdateHeadlineRefreshesOnlyTheNewerKnownPeerTimestamp() throws {
        let f = try fixture()
        let roster = try addRoster(owner: f.manager.owner, jid: f.peer)
        try WRealm.safe().write { roster.encryptionUpdatedTS = 10 }
        try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        try withUIAction(f) { ui in
            for stamp in ["10", "9", "0", "invalid"] {
                XCTAssertTrue(f.manager.onEncryptionUpdateReceiveHeadline(try updateHeadline(from: f.peer, stamp: stamp)))
            }
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 0)
            XCTAssertTrue(f.manager.onEncryptionUpdateReceiveHeadline(try updateHeadline(from: f.peer, stamp: "11")))
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 1)
            resumeUIAction(ui, fixture: f)
        }

        XCTAssertEqual(try requests(f.stream, node: .bundle).map(requestDeviceID), [77])
        XCTAssertEqual(roster.encryptionUpdatedTS, 10, "Only successful public-key projection can refresh cache state")
    }

    func testEncryptionUpdateHeadlineIgnoresUnknownPeerAndMalformedEnvelopeWithoutRequests() throws {
        let f = try fixture()
        try withUIAction(f) { ui in
            XCTAssertTrue(f.manager.onEncryptionUpdateReceiveHeadline(try updateHeadline(from: f.peer, stamp: "100")))
            XCTAssertTrue(f.manager.onEncryptionUpdateReceiveHeadline(try updateHeadline(from: f.peer, stamp: nil)))
            let missingSender = try updateHeadline(from: nil, stamp: "100")
            XCTAssertFalse(f.manager.onEncryptionUpdateReceiveHeadline(missingSender))
            let wrongNode = try updateHeadline(from: f.peer, stamp: "100", node: OmemoManager.NodeType.device.rawValue)
            XCTAssertFalse(f.manager.onEncryptionUpdateReceiveHeadline(wrongNode))
            let wrongNamespace = try updateHeadline(from: f.peer, stamp: "100", namespace: "urn:foreign")
            XCTAssertFalse(f.manager.onEncryptionUpdateReceiveHeadline(wrongNamespace))
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 0)
        }
        XCTAssertTrue(f.stream.elements.isEmpty)
    }

    func testOwnEncryptionUpdateUsesTheCurrentOwnCacheAndFallsBackWithoutRefreshingPeerDevices() throws {
        let f = try fixture()
        let accountRow = try XCTUnwrap(WRealm.safe().object(ofType: AccountStorageItem.self, forPrimaryKey: f.manager.owner))
        try WRealm.safe().write { accountRow.encryptionUpdatedTS = 10 }
        try addIdentity(owner: f.manager.owner, jid: f.manager.owner, id: 99)
        try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        try withUIAction(f) { ui in
            XCTAssertTrue(f.manager.onEncryptionUpdateReceiveHeadline(try updateHeadline(from: f.manager.owner, stamp: "11")))
            XCTAssertEqual(ui.pendingPerformRequestCountForTests(owner: f.manager.owner), 1)
            failUIAction(ui, fixture: f)
        }

        let requested = requests(f.stream, node: .bundle)
        XCTAssertEqual(try Set(requested.map(requestDeviceID)), [42, 99])
        XCTAssertTrue(requested.allSatisfy { $0.attributeStringValue(forName: "to") == nil })
    }

    func testPublicationPreconditionFailureConfiguresThroughTheAuthenticatedAccountAndPublishesOnlyAfterItsACK() throws {
        let f = try fixture()
        try ownSnapshot(f, ids: [42])
        let identity = try f.storage.identity().publicKey
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let firstID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        f.manager.omemo2MaintenancePublicationStream = nil
        f.manager.omemo2RegistrationStream = nil
        f.stream.authenticated = true

        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(try preconditionError(id: firstID)))
        drainAccount(f)

        let configuration = try XCTUnwrap(configurations(f.stream).only)
        let configurationID = try XCTUnwrap(configuration.attributeStringValue(forName: "id"))
        XCTAssertNil(configuration.attributeStringValue(forName: "to"))
        XCTAssertEqual(f.manager.omemo2BundleConfigurationRequestID, configurationID)
        XCTAssertTrue(f.manager.queryIds.contains(configurationID))
        XCTAssertEqual(publications(f.stream, node: .bundle).count, 1)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: configurationID)))
        XCTAssertEqual(publications(f.stream, node: .bundle).count, 2)
        XCTAssertNil(f.manager.omemo2BundleConfigurationRequestID)
        let retryID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        XCTAssertNotEqual(firstID, retryID)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: retryID)))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
    }

    func testQueuedPublicationConfigurationCannotRunAfterAuthenticationLossOrEncryptionDisable() throws {
        for losesAuthentication in [true, false] {
            let f = try fixture()
            try ownSnapshot(f, ids: [42])
            try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
            let firstID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
            f.manager.omemo2MaintenancePublicationStream = nil
            f.manager.omemo2RegistrationStream = nil
            f.stream.authenticated = true
            try holdAccountQueue(f) {
                XCTAssertTrue(f.manager.onOMEMO2PublicationResult(try preconditionError(id: firstID)))
                if losesAuthentication { f.stream.authenticated = false }
                else {
                    let row = try XCTUnwrap(WRealm.safe().object(ofType: AccountStorageItem.self, forPrimaryKey: f.manager.owner))
                    try WRealm.safe().write { row.isEncryptionEnabled = false }
                }
            }
            drainAccount(f)

            XCTAssertTrue(configurations(f.stream).isEmpty)
            XCTAssertNil(f.manager.omemo2BundleConfigurationRequestID)
            XCTAssertFalse(try ownIdentity(f).isPublicated)
            XCTAssertEqual(publications(f.stream, node: .bundle).count, 1)
        }
    }

    func testConcurrentPublicationRetryActivitiesUseTheRealAccountQueueAndSendOneCurrentBundle() throws {
        let f = try fixture()
        try ownSnapshot(f, ids: [42])
        let identity = try f.storage.identity().publicKey
        f.stream.authenticated = true
        f.manager.shouldPublicate = true
        f.manager.omemo2MaintenancePublicationStream = nil
        f.manager.omemo2RegistrationStream = nil
        holdAccountQueue(f) {
            f.manager.retryOMEMO2BundlePublication()
            f.manager.retryOMEMO2BundlePublication()
        }
        drainAccount(f)

        let publication = try XCTUnwrap(publications(f.stream, node: .bundle).only)
        XCTAssertEqual(try OMEMO2BundleCodec.decode(item: publication).identityKey, identity)
        XCTAssertEqual(f.manager.omemo2BundlePublications.count, 1)
        XCTAssertFalse(f.manager.shouldPublicate)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        let id = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: id)))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
    }

    func testAccountPublicationFallbackCannotSendWhileUnauthenticatedAndResumesOnAuthenticatedActivity() throws {
        let f = try fixture()
        try ownSnapshot(f, ids: [42])
        let identity = try f.storage.identity().publicKey
        f.manager.shouldPublicate = true
        f.manager.omemo2MaintenancePublicationStream = nil
        f.manager.omemo2RegistrationStream = nil

        f.manager.retryOMEMO2BundlePublication()
        drainAccount(f)

        XCTAssertTrue(f.stream.elements.isEmpty)
        XCTAssertTrue(f.manager.shouldPublicate)
        XCTAssertTrue(f.manager.omemo2BundlePublications.isEmpty)
        f.stream.authenticated = true
        f.manager.retryOMEMO2BundlePublication()
        drainAccount(f)
        XCTAssertEqual(publications(f.stream, node: .bundle).count, 1)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
    }

    func testDefaultFreshBundleRequesterDispatchesOneCorrelatedForcedFetchThroughTheAccount() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        try addIdentity(owner: f.manager.owner, jid: f.peer, id: 77)
        f.stream.authenticated = true
        XCTAssertNil(f.manager.omemo2FreshBundleRequester)
        holdAccountQueue(f) {
            f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
            f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
        }
        drainAccount(f)

        let request = try XCTUnwrap(f.manager.omemo2FreshBundleRequests.values.only)
        let packet = try XCTUnwrap(requests(f.stream, node: .bundle).only)
        XCTAssertEqual(packet.attributeStringValue(forName: "id"), request.id)
        XCTAssertEqual(packet.attributeStringValue(forName: "to"), f.peer)
        XCTAssertEqual(try requestDeviceID(packet), 77)
        XCTAssertTrue(request.isRecovery)
        XCTAssertNil(request.replacementGeneration)
        XCTAssertTrue(f.manager.queryIds.contains(request.id))
        XCTAssertNil(f.manager.omemo2BundleRequests[request.id], "Fresh recovery owns its request separately from cached-bundle fetches")
        XCTAssertFalse(try f.storage.sessionExists(jid: f.peer, deviceID: 77))
    }

    func testUnauthenticatedDefaultFreshFetchProducesNoWireAndTimeoutReplacesItsRequestOnAuthentication() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        f.manager.omemo2MaintenanceNow = { now }

        f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
        drainAccount(f)

        let oldID = try XCTUnwrap(f.manager.omemo2FreshBundleRequests.values.only?.id)
        XCTAssertTrue(f.stream.elements.isEmpty)
        XCTAssertFalse(try f.storage.sessionExists(jid: f.peer, deviceID: 77))
        now = now.addingTimeInterval(OmemoManager.omemo2PublicationIQTimeout)
        f.stream.authenticated = true
        f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
        drainAccount(f)
        let currentID = try XCTUnwrap(f.manager.omemo2FreshBundleRequests.values.only?.id)
        XCTAssertNotEqual(oldID, currentID)
        XCTAssertFalse(f.manager.queryIds.contains(oldID))
        XCTAssertEqual(requests(f.stream, node: .bundle).map { $0.attributeStringValue(forName: "id") }, [currentID])
    }

    func testExpiredQueuedDefaultFetchCannotSendAfterANewerRequestTakesOwnership() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        f.manager.omemo2MaintenanceNow = { now }
        f.stream.authenticated = true
        var oldID: String?
        var currentID: String?
        holdAccountQueue(f) {
            f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
            oldID = f.manager.omemo2FreshBundleRequests.values.only?.id
            now = now.addingTimeInterval(OmemoManager.omemo2PublicationIQTimeout)
            f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
            currentID = f.manager.omemo2FreshBundleRequests.values.only?.id
        }
        drainAccount(f)

        XCTAssertNotEqual(try XCTUnwrap(oldID), try XCTUnwrap(currentID))
        XCTAssertFalse(f.manager.queryIds.contains(try XCTUnwrap(oldID)))
        XCTAssertEqual(requests(f.stream, node: .bundle).map { $0.attributeStringValue(forName: "id") }, [try XCTUnwrap(currentID)])
        XCTAssertFalse(try f.storage.sessionExists(jid: f.peer, deviceID: 77))
    }

    func testManualReplacementCancellationPreventsAnAlreadyQueuedDefaultFreshRequestFromSending() throws {
        let f = try fixture()
        try knownPeerSnapshot(f, ids: [77])
        f.stream.authenticated = true
        var canceledID: String?
        try holdAccountQueue(f) {
            f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
            canceledID = f.manager.omemo2FreshBundleRequests.values.only?.id
            try f.manager.replaceOMEMO2Sessions()
        }
        drainAccount(f)

        XCTAssertNotNil(canceledID)
        XCTAssertFalse(f.manager.queryIds.contains(try XCTUnwrap(canceledID)))
        XCTAssertTrue(f.manager.omemo2FreshBundleRequests.isEmpty)
        XCTAssertTrue(requests(f.stream, node: .bundle).isEmpty)
        XCTAssertFalse(try f.storage.sessionExists(jid: f.peer, deviceID: 77))
        f.manager.recoverMissingOMEMO2Session(jid: f.peer, deviceID: 77)
        drainAccount(f)
        XCTAssertEqual(requests(f.stream, node: .bundle).count, 1)
        XCTAssertNotEqual(requests(f.stream, node: .bundle).first?.attributeStringValue(forName: "id"), canceledID)
    }

    func testXabberRegistrationPublishesOnlyBundleAndWaitsForServerMembership() throws {
        let f = try fixture()
        advertiseXabberDevices(f)
        try ownSnapshot(f, ids: [99])
        let originalID = try f.storage.localBundle().deviceID
        let originalIdentity = try f.storage.identity().publicKey

        try f.manager.publicateOwnDevice(f.stream, createNode: true)

        try assertXabberBundlePackets(f, count: 1)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        let requestID = try XCTUnwrap(Array(f.manager.omemo2BundlePublications.keys).only)
        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: requestID)))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
        let realm = try WRealm.safe()
        XCTAssertEqual(Array(try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: realm, owner: f.manager.owner, jid: f.manager.owner)).deviceIDs), [99])
        XCTAssertFalse(OMEMO2DeviceListStorageItem.contains(in: realm, owner: f.manager.owner, jid: f.manager.owner, deviceID: originalID),
            "A bundle ACK cannot fabricate server-owned device membership")
        let local = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: f.manager.owner, jid: f.manager.owner, deviceId: originalID)))
        XCTAssertEqual(local.state, .trusted)
        XCTAssertFalse(local.isInDeviceList)
        XCTAssertEqual(try f.storage.localBundle().deviceID, originalID)
        XCTAssertEqual(try f.storage.identity().publicKey, originalIdentity)
    }

    func testXabberDirectBundlePublicationOmitsPublishOptions() throws {
        let f = try fixture()
        advertiseXabberDevices(f)
        try ownSnapshot(f, ids: [42, 99])

        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)

        try assertXabberBundlePackets(f, count: 1)
        XCTAssertEqual(f.manager.omemo2BundlePublications.count, 1)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
    }

    func testXabberPublicationErrorsRetrySameBundleWithoutNodeConfiguration() throws {
        for condition in ["precondition-not-met", "resource-constraint", "item-not-found"] {
            let f = try fixture()
            advertiseXabberDevices(f)
            try ownSnapshot(f, ids: [99])
            f.stream.authenticated = true
            let originalID = try f.storage.localBundle().deviceID
            let originalIdentity = try f.storage.identity().publicKey
            var now = Date(timeIntervalSince1970: 1_900_000_000)
            f.manager.omemo2MaintenanceNow = { now }
            try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
            let requestID = try XCTUnwrap(Array(f.manager.omemo2BundlePublications.keys).only)
            let errorXML = condition == "precondition-not-met"
                ? "<precondition-not-met xmlns='http://jabber.org/protocol/pubsub#errors'/>"
                : "<\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
            let error = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='error' id='\(requestID)'><error type='wait'>\(errorXML)</error></iq>")

            XCTAssertTrue(f.manager.onOMEMO2PublicationResult(error))
            XCTAssertNil(f.manager.omemo2BundleConfigurationRequestID)
            XCTAssertTrue(configurations(f.stream).isEmpty)
            XCTAssertFalse(try ownIdentity(f).isPublicated)
            now = now.addingTimeInterval(OmemoManager.omemo2PublicationRetryInterval + 1)
            f.manager.retryOMEMO2BundlePublication(on: f.stream)

            try assertXabberBundlePackets(f, count: 2)
            let retryID = try XCTUnwrap(Array(f.manager.omemo2BundlePublications.keys).only)
            XCTAssertNotEqual(requestID, retryID)
            XCTAssertTrue(f.manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: retryID)))
            XCTAssertTrue(try ownIdentity(f).isPublicated)
            XCTAssertEqual(try f.storage.localBundle().deviceID, originalID)
            XCTAssertEqual(try f.storage.identity().publicKey, originalIdentity)
        }
    }

    func testXabberPreconditionFailureCannotQueueConfigurationThroughAccountFallback() throws {
        let f = try fixture()
        advertiseXabberDevices(f)
        try ownSnapshot(f, ids: [42])
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let requestID = try XCTUnwrap(Array(f.manager.omemo2BundlePublications.keys).only)
        f.manager.omemo2MaintenancePublicationStream = nil
        f.manager.omemo2RegistrationStream = nil
        f.stream.authenticated = true

        XCTAssertTrue(f.manager.onOMEMO2PublicationResult(try preconditionError(id: requestID)))
        drainAccount(f)

        XCTAssertTrue(configurations(f.stream).isEmpty)
        XCTAssertNil(f.manager.omemo2BundleConfigurationRequestID)
        try assertXabberBundlePackets(f, count: 1)
        XCTAssertTrue(f.manager.shouldPublicate)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
    }

    func testXabberDirectMembershipPublicationCannotReplaceOrExcludeServerDevices() throws {
        let f = try fixture()
        advertiseXabberDevices(f)
        try ownSnapshot(f, ids: [42, 99])

        try f.manager.sendOwnDevice(f.stream, createNode: true, excludingIDs: [99])

        XCTAssertTrue(f.stream.elements.isEmpty)
        XCTAssertEqual(Array(try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: WRealm.safe(), owner: f.manager.owner, jid: f.manager.owner)).deviceIDs), [42, 99])
    }

    func testXabberOwnListMissingLocalSIDDoesNotPublishClientMembership() throws {
        let f = try fixture()
        advertiseXabberDevices(f)
        try ownSnapshot(f, ids: [99])
        f.manager.shouldPublicate = false

        f.manager.onOwnDeviceListUpdated(f.stream)

        XCTAssertTrue(f.stream.elements.isEmpty)
        XCTAssertFalse(OMEMO2DeviceListStorageItem.contains(in: try WRealm.safe(), owner: f.manager.owner, jid: f.manager.owner, deviceID: 42))
    }

    func testXabberDisableRetractsOnlyOwnBundleWithoutWritingDeviceMembership() throws {
        let f = try fixture(enabled: false)
        advertiseXabberDevices(f)
        try ownSnapshot(f, ids: [42, 99])

        try f.manager.publicateOwnDevice(f.stream, createNode: true)

        let packet = try XCTUnwrap(f.stream.elements.only)
        let wire = try DDXMLElement(xmlString: packet.xmlString)
        let pubsub = try XCTUnwrap(wire.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"))
        XCTAssertEqual((pubsub.children ?? []).compactMap { ($0 as? DDXMLElement)?.localName }, ["retract"])
        let retract = try XCTUnwrap(pubsub.element(forName: "retract"))
        XCTAssertEqual(retract.attributeStringValue(forName: "node"), OmemoManager.NodeType.bundle.rawValue)
        XCTAssertEqual(retract.element(forName: "item")?.attributeStringValue(forName: "id"), "42")
        XCTAssertFalse(f.manager.shouldPublicate)
        XCTAssertEqual(Array(try XCTUnwrap(OMEMO2DeviceListStorageItem.get(in: WRealm.safe(), owner: f.manager.owner, jid: f.manager.owner)).deviceIDs), [42, 99])
    }

    func testStandardPEPRegistrationRetainsNodeSetupAndNormativePublicationOptions() throws {
        let f = try fixture()
        XCTAssertFalse(f.account.devices.isAvailable)
        try ownSnapshot(f, ids: [99])

        try f.manager.publicateOwnDevice(f.stream, createNode: true)

        let packets = try f.stream.elements.map { try DDXMLElement(xmlString: $0.xmlString) }
        XCTAssertEqual(packets.filter { $0.element(forName: "pubsub")?.element(forName: "create") != nil }.count, 2)
        XCTAssertEqual(packets.filter { $0.element(forName: "pubsub")?.element(forName: "configure") != nil }.count, 2)
        XCTAssertEqual(try publishedDeviceIDs(f.stream), [42, 99])
        for (node, maxItems) in [(OmemoManager.NodeType.bundle, "max"), (.device, "1")] {
            let packet = try XCTUnwrap(packets.first {
                $0.element(forName: "pubsub")?.element(forName: "publish")?.attributeStringValue(forName: "node") == node.rawValue
            })
            let form = try XCTUnwrap(packet.element(forName: "pubsub")?.element(forName: "publish-options")?.element(forName: "x", xmlns: "jabber:x:data"))
            let fields = Dictionary(uniqueKeysWithValues: form.elements(forName: "field").map {
                ($0.attributeStringValue(forName: "var") ?? "", $0.element(forName: "value")?.stringValue ?? "")
            })
            XCTAssertEqual(fields["FORM_TYPE"], "http://jabber.org/protocol/pubsub#publish-options")
            XCTAssertEqual(fields["pubsub#access_model"], "open")
            XCTAssertEqual(fields["pubsub#max_items"], maxItems)
        }
    }

    private func advertiseXabberDevices(_ f: Fixture) {
        let features = DDXMLElement(name: "features")
        features.addChild(DDXMLElement(name: "devices", xmlns: "https://xabber.com/protocol/devices"))
        f.account.devices.setAvailable(features)
        XCTAssertTrue(f.account.devices.isAvailable)
    }

    private func assertXabberBundlePackets(_ f: Fixture, count: Int,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(f.stream.elements.count, count, file: file, line: line)
        for packet in f.stream.elements {
            let wire = try DDXMLElement(xmlString: packet.xmlString)
            XCTAssertEqual(wire.attributeStringValue(forName: "type"), "set", file: file, line: line)
            let pubsub = try XCTUnwrap(wire.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"), file: file, line: line)
            XCTAssertEqual((pubsub.children ?? []).compactMap { ($0 as? DDXMLElement)?.localName }, ["publish"], file: file, line: line)
            let publish = try XCTUnwrap(pubsub.element(forName: "publish"), file: file, line: line)
            XCTAssertEqual(publish.attributeStringValue(forName: "node"), OmemoManager.NodeType.bundle.rawValue, file: file, line: line)
            XCTAssertEqual(publish.elements(forName: "item").count, 1, file: file, line: line)
            let item = try XCTUnwrap(publish.element(forName: "item"), file: file, line: line)
            XCTAssertEqual(item.attributeStringValue(forName: "id"), "42", file: file, line: line)
            XCTAssertEqual(try OMEMO2BundleCodec.decode(item: item).identityKey, try f.storage.localBundle().identityKey, file: file, line: line)
        }
    }

    private func fixture(enabled: Bool = true, prepared: Bool = true) throws -> Fixture {
        let owner = "omemo-lifecycle-\(UUID().uuidString.lowercased())@example.test"
        let peer = "peer-\(UUID().uuidString.lowercased())@example.test"
        let realm = try WRealm.safe()
        let row = AccountStorageItem()
        row.jid = owner
        row.isEncryptionEnabled = enabled
        try realm.write { realm.add(row) }
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        if prepared { _ = try storage.prepare(deviceID: 42, preKeyCount: 2) }
        let account = Account(jid: owner, queue: DispatchQueue(label: "OMEMO-manager-lifecycle-\(UUID())"))
        let manager = account.omemo
        manager.omemo2Storage = storage
        manager.omemo2MaintenanceScheduler = { _, _ in }
        if prepared { _ = try manager.ensureOMEMO2Prepared(attemptPublication: false) }
        let stream = CapturingStream()
        stream.myJID = XMPPJID(string: owner + "/ios-test")
        account.xmppStream = stream
        accounts.append(account)
        AccountManager.shared.users = originalUsers + accounts
        return Fixture(account: account, manager: manager, memory: memory, storage: storage, stream: stream, peer: peer)
    }

    private func withUIAction(_ f: Fixture, _ body: (XMPPUIActionManager) throws -> Void) rethrows {
        let ui = XMPPUIActionManager.shared
        let previousOwner = ui.currentJid
        let previousStream = ui.stream
        let previousMessages = ui.messages
        let previousMAM = ui.mam
        ui.preparePendingAuthenticationForTests(owner: f.manager.owner, stream: f.stream,
            archiveManager: f.account.mam, messageManager: f.account.messages)
        defer {
            ui.resetPendingAuthenticationForTests()
            ui.queue.sync {
                ui.currentJid = previousOwner
                ui.stream = previousStream
                ui.messages = previousMessages
                ui.mam = previousMAM
            }
        }
        try body(ui)
    }

    private func resumeUIAction(_ ui: XMPPUIActionManager, fixture f: Fixture) {
        f.stream.authenticated = true
        _ = ui.dispatchAuthenticatedReconnectForTests(owner: f.manager.owner)
        let finished = expectation(description: "real UI action queue completed")
        ui.queue.async { finished.fulfill() }
        wait(for: [finished], timeout: 3)
        drainAccount(f)
    }

    private func failUIAction(_ ui: XMPPUIActionManager, fixture f: Fixture) {
        let failed = expectation(description: "real pending UI request failure dispatched")
        ui.queue.async {
            ui.failPendingPerformRequests(owner: f.manager.owner, reason: "synthetic lifecycle failure")
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        drainAccount(f)
    }

    private func drainAccount(_ f: Fixture) {
        let finished = expectation(description: "account action queue completed")
        f.account.queue.async { finished.fulfill() }
        wait(for: [finished], timeout: 3)
        // Queue completion proves the writer committed. Refresh the test's
        // thread-bound Realm explicitly before observing that newer version;
        // XCTest's run-loop waits do not guarantee automatic Realm refresh.
        _ = realmKeeper?.refresh()
    }

    private func drainMainRunLoop() {
        let finished = expectation(description: "main run-loop projection completed")
        RunLoop.main.perform { finished.fulfill() }
        wait(for: [finished], timeout: 3)
        _ = realmKeeper?.refresh()
    }

    private func holdAccountQueue(_ f: Fixture, _ body: () throws -> Void) rethrows {
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "account queue held before lifecycle callback")
        f.account.queue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        wait(for: [entered], timeout: 3)
        defer { release.signal() }
        try body()
    }

    private func configurations(_ stream: CapturingStream) -> [DDXMLElement] {
        stream.elements.filter {
            $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")?
                .element(forName: "configure")?.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue
        }
    }

    private func ownIdentity(_ f: Fixture) throws -> SignalIdentityStorageItem {
        try XCTUnwrap(WRealm.safe().object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: f.manager.owner, jid: f.manager.owner, deviceId: 42)))
    }

    private func preconditionError(id: String) throws -> XMPPIQ {
        try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='error' id='\(id)'><error type='cancel'><precondition-not-met xmlns='http://jabber.org/protocol/pubsub#errors'/></error></iq>")
    }

    private func requests(_ stream: CapturingStream, node: OmemoManager.NodeType) -> [DDXMLElement] {
        stream.elements.filter {
            $0.attributeStringValue(forName: "type") == "get"
                && $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                    .element(forName: "items")?.attributeStringValue(forName: "node") == node.rawValue
        }
    }

    private func publications(_ stream: CapturingStream, node: OmemoManager.NodeType) -> [DDXMLElement] {
        stream.elements.compactMap {
            guard let publish = $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .element(forName: "publish"), publish.attributeStringValue(forName: "node") == node.rawValue else { return nil }
            return publish.element(forName: "item")
        }
    }

    private func retractions(_ stream: CapturingStream, node: OmemoManager.NodeType) -> [DDXMLElement] {
        stream.elements.compactMap {
            guard let retract = $0.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
                .element(forName: "retract"), retract.attributeStringValue(forName: "node") == node.rawValue else { return nil }
            return retract.element(forName: "item")
        }
    }

    private func requestDeviceID(_ packet: DDXMLElement) throws -> Int {
        try XCTUnwrap(packet.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
            .element(forName: "items")?.element(forName: "item")).attributeIntegerValue(forName: "id")
    }

    private func publishedDeviceIDs(_ stream: CapturingStream) throws -> [Int] {
        let item = try XCTUnwrap(publications(stream, node: .device).last)
        return try XCTUnwrap(item.element(forName: "devices", xmlns: OmemoManager.xmlns))
            .elements(forName: "device").map { $0.attributeIntegerValue(forName: "id") }.sorted()
    }

    private func ownSnapshot(_ f: Fixture, ids: [Int]) throws {
        try snapshot(owner: f.manager.owner, jid: f.manager.owner, ids: ids)
    }

    private func knownPeerSnapshot(_ f: Fixture, ids: [Int]) throws {
        try snapshot(owner: f.manager.owner, jid: f.peer, ids: ids)
    }

    private func snapshot(owner: String, jid: String, ids: [Int]) throws {
        let row = OMEMO2DeviceListStorageItem()
        row.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: jid)
        row.owner = owner
        row.jid = jid
        row.isKnown = true
        row.itemID = "current"
        row.deviceIDs.append(objectsIn: ids)
        row.devicesXML = "<devices xmlns='urn:xmpp:omemo:2'>\(ids.map { "<device id='\($0)'/>" }.joined())</devices>"
        let realm = try WRealm.safe()
        try realm.write { realm.add(row, update: .modified) }
    }

    @discardableResult
    private func addIdentity(owner: String, jid: String, id: Int) throws -> SignalIdentityStorageItem {
        let row = SignalIdentityStorageItem()
        row.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: id)
        row.owner = owner
        row.jid = jid
        row.deviceId = id
        row.protocolProfile = OmemoManager.xmlns
        row.identityKey = Data(repeating: 0xAA, count: 32).base64EncodedString()
        let realm = try WRealm.safe()
        try realm.write { realm.add(row, update: .modified) }
        return row
    }

    @discardableResult
    private func addDevice(owner: String, jid: String, id: Int) throws -> SignalDeviceStorageItem {
        let row = SignalDeviceStorageItem()
        row.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: id)
        row.owner = owner
        row.jid = jid
        row.deviceId = id
        let realm = try WRealm.safe()
        try realm.write { realm.add(row, update: .modified) }
        return row
    }

    @discardableResult
    private func addRoster(owner: String, jid: String) throws -> RosterStorageItem {
        let row = RosterStorageItem()
        row.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        row.owner = owner
        row.jid = jid
        let realm = try WRealm.safe()
        try realm.write { realm.add(row, update: .modified) }
        return row
    }

    private func addChat(owner: String, jid: String, type: ClientSynchronizationManager.ConversationType) throws -> LastChatsStorageItem {
        let row = LastChatsStorageItem()
        row.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: type)
        row.owner = owner
        row.jid = jid
        row.conversationType = type
        let realm = try WRealm.safe()
        try realm.write { realm.add(row) }
        return row
    }

    private func chat(owner: String, jid: String, type: ClientSynchronizationManager.ConversationType) throws -> LastChatsStorageItem? {
        try WRealm.safe().object(ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: type))
    }

    private func peerBundle(owner: String, id: Int) throws -> OMEMO2PublishedBundle {
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: Memory())
        return OMEMO2PublishedBundle(try storage.prepare(deviceID: id, preKeyCount: 2))
    }

    private func bundleHeadline(from: String, bundle: OMEMO2PublishedBundle) throws -> XMPPMessage {
        let item = try OMEMO2BundleCodec.encode(bundle)
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(from)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:bundles'>\(item.xmlString)</items></event></message>")
    }

    private func updateHeadline(from: String?, stamp: String?, node: String = OmemoManager.NodeType.update.rawValue,
                                namespace: String = "http://jabber.org/protocol/pubsub#event") throws -> XMPPMessage {
        let sender = from.map { " from='\($0)'" } ?? ""
        let item = stamp.map { "<item id='\($0)'/>" } ?? ""
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' type='headline'\(sender)><event xmlns='\(namespace)'><items node='\(node)'>\(item)</items></event></message>")
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
