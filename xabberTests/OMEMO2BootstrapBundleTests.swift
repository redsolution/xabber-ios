import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

@MainActor
final class OMEMO2BootstrapBundleTests: XCTestCase {
    private final class Stream: XMPPStream {
        var elements: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }

    private var previousRealm: Realm.Configuration!
    private var realm: Realm!
    private let owner = "bootstrap-bundle-owner@example.test"
    private let peer = "bootstrap-bundle-peer@example.test"

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2BootstrapBundle-" + UUID().uuidString)
        realm = try WRealm.safe()
    }

    override func tearDownWithError() throws {
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
    }

    func testOwnBundleResponseWithoutFromLoadsOnlyTheRequestedDevice() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: owner, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        XCTAssertTrue(manager.read(withIQ: try reply(id: id, from: nil, bundle: bundle(deviceID: 7))))
        drainMainRunLoop()

        let identity = try XCTUnwrap(identity(jid: owner, deviceID: 7))
        XCTAssertEqual(identity.protocolProfile, OmemoManager.xmlns)
        XCTAssertFalse(manager.queryIds.contains(id))
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.state, .unknown)
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.isInDeviceList, false)
    }

    func testSenderlessPeerBundleCannotBeAttributedToOwner() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        XCTAssertFalse(manager.read(withIQ: try reply(id: id, from: nil, bundle: bundle(deviceID: 7))))
        drainMainRunLoop()

        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
        XCTAssertTrue(manager.queryIds.contains(id))
    }

    func testMalformedFromCannotImpersonateSenderlessOwnBundleResult() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: owner, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        let iq = try reply(id: id, from: "invalid@@example.test", bundle: bundle(deviceID: 7))
        XCTAssertNil(iq.from)

        XCTAssertFalse(manager.read(withIQ: iq))
        drainMainRunLoop()

        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
        XCTAssertNotNil(manager.omemo2BundleRequests[id])
    }

    func testMalformedFromCannotConsumeSenderlessOwnBundleError() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: owner, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='error' id='\(id)' from='invalid@@example.test'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        XCTAssertNil(iq.from)

        XCTAssertFalse(manager.read(withIQ: iq))

        XCTAssertNotNil(manager.omemo2BundleRequests[id])
        XCTAssertTrue(manager.queryIds.contains(id))
    }

    func testMatchingPeerBundleLoadsAndConsumesItsRequest() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        XCTAssertTrue(manager.read(withIQ: try reply(id: id, from: peer, bundle: bundle(deviceID: 7))))
        drainMainRunLoop()

        XCTAssertNotNil(identity(jid: peer, deviceID: 7))
        XCTAssertFalse(manager.queryIds.contains(id))
    }

    func testCorrelatedOwnBundleErrorWithoutEchoedPayloadConsumesItsRequest() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: owner, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='error' id='\(id)'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")

        XCTAssertTrue(manager.read(withIQ: iq))

        XCTAssertFalse(manager.queryIds.contains(id))
        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
    }

    func testSessionResetRejectsThePreviousConnectionBundleResponse() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        manager.clearSession()

        XCTAssertFalse(manager.read(withIQ: try reply(id: id, from: peer, bundle: bundle(deviceID: 7))))
        drainMainRunLoop()
        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
        XCTAssertFalse(manager.queryIds.contains(id))
    }

    func testAccountModuleResetClearsPendingBundleOwnershipAndRejectsLateReply() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "OMEMO2BootstrapBundleTests.account-reset"))
        defer {
            account.xmppTaskScheduler.reset()
            account.queue.sync {}
        }
        let stream = Stream()
        account.omemo.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        XCTAssertNotNil(account.omemo.omemo2BundleRequests[id])

        account.resetModules()

        XCTAssertNil(account.omemo.omemo2BundleRequests[id])
        XCTAssertFalse(account.omemo.queryIds.contains(id))
        XCTAssertFalse(account.omemo.read(withIQ: try reply(id: id, from: peer, bundle: bundle(deviceID: 7))))
        drainMainRunLoop()
        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
    }

    func testSessionResetPreventsQueuedBundleProjectionFromOldConnection() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(manager.read(withIQ: try reply(id: id, from: peer, bundle: bundle(deviceID: 7))))

        manager.clearSession()
        drainMainRunLoop()

        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
    }

    func testConcurrentBundleSubmissionSnapshotsAndResetLeaveNoOldRequestOwnership() {
        let manager = OmemoManager(withOwner: owner)
        let peerJID = peer
        let recordedIDs = LockedRequestIDs()
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            let stream = Stream()
            manager.getContactBundle(stream, jid: peerJID, deviceId: index + 1, force: true)
            if let id = stream.elements.last?.attributeStringValue(forName: "id") { recordedIDs.append(id) }
            _ = manager.omemo2BundleRequests.count
            if index.isMultiple(of: 3) { manager.clearSession() }
        }

        manager.clearSession()

        // Reset may cancel a request before it reaches the stream.
        XCTAssertFalse(recordedIDs.values.isEmpty)
        XCTAssertTrue(manager.omemo2BundleRequests.isEmpty)
        for id in recordedIDs.values { XCTAssertFalse(manager.queryIds.contains(id)) }
    }

    func testResourceQualifiedBundleTargetUsesItsBareIdentity() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer + "/desktop", deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        XCTAssertTrue(manager.read(withIQ: try reply(id: id, from: peer + "/phone", bundle: bundle(deviceID: 7))))
        drainMainRunLoop()

        XCTAssertEqual(stream.elements.last?.attributeStringValue(forName: "to"), peer)
        XCTAssertNotNil(identity(jid: peer, deviceID: 7))
        XCTAssertNil(identity(jid: peer + "/desktop", deviceID: 7))
    }

    func testBundleRejectionDiagnosticsDescribeLegacyShapeWithoutKeyOrXMLContents() throws {
        let published = try bundle(deviceID: 7)
        let item = try OMEMO2BundleCodec.encode(published)
        let identityElement = try XCTUnwrap(item.element(forName: "bundle")?.element(forName: "ik"))
        let legacyIdentity = Data([5]) + published.identityKey
        identityElement.stringValue = legacyIdentity.base64EncodedString()

        let diagnostic = OMEMO2BundleCodec.rejectionDiagnostics(item: item, error: OMEMO2BundleCodec.Error.invalidBase64)

        XCTAssertEqual(diagnostic, "reason=invalidBase64OrKeyLength ikBytes=33 spkBytes=32 signatureBytes=64 preKeys=1")
        for bytes in [legacyIdentity, published.signedPreKey, published.signature, published.preKeys[0].publicKey] {
            XCTAssertFalse(diagnostic.contains(bytes.base64EncodedString()))
        }
        XCTAssertFalse(diagnostic.contains("<"))
        XCTAssertFalse(diagnostic.contains(owner))
    }

    func testWrongSenderCannotPopulateCacheForCorrelatedBundleRequest() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        XCTAssertFalse(manager.read(withIQ: try reply(id: id, from: "other@example.test", bundle: bundle(deviceID: 7))))
        drainMainRunLoop()

        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
        XCTAssertTrue(manager.queryIds.contains(id))
    }

    func testMismatchedDeviceCannotPopulateCacheForCorrelatedBundleRequest() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactBundle(stream, jid: peer, deviceId: 7, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))

        XCTAssertFalse(manager.read(withIQ: try reply(id: id, from: peer, bundle: bundle(deviceID: 8))))
        drainMainRunLoop()

        XCTAssertTrue(realm.objects(SignalIdentityStorageItem.self).isEmpty)
        XCTAssertTrue(manager.queryIds.contains(id))
    }

    func testOwnDeviceListLoadsEvenWhenItsBundleIsIncompatibleWithOMEMO2() throws {
        let manager = OmemoManager(withOwner: owner)
        let stream = Stream()
        manager.getContactDevices(stream, jid: owner, force: true)
        let id = try XCTUnwrap(stream.elements.last?.attributeStringValue(forName: "id"))
        let list = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='\(id)' from='\(owner)'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='7'/></devices></item></items></pubsub></iq>")
        XCTAssertTrue(manager.read(withIQ: list))
        let incompatible = try OMEMO2BundleCodec.encode(bundle(deviceID: 7))
        let key = try XCTUnwrap(incompatible.element(forName: "bundle")?.element(forName: "ik"))
        let legacyKey = Data([5]) + (try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(key.stringValue))))
        key.stringValue = legacyKey.base64EncodedString()
        let items = DDXMLElement(name: "items", xmlns: OMEMO2DeviceListCodec.pubsub)
        items.addAttribute(withName: "node", stringValue: OmemoManager.NodeType.bundle.rawValue)
        items.addChild(incompatible)

        XCTAssertThrowsError(try manager.onContactBundleReceive(items: items, jid: owner))

        let device = try XCTUnwrap(realm.objects(SignalDeviceStorageItem.self).first)
        XCTAssertEqual(device.deviceId, 7)
        XCTAssertTrue(device.isInDeviceList)
        XCTAssertEqual(device.state, .unknown)
        XCTAssertNil(identity(jid: owner, deviceID: 7))
        let controller = DevicesListViewController()
        controller.owner = owner; controller.jid = owner
        controller.load()
        XCTAssertEqual(controller.omemoDevices.map(\.deviceId), [7])
    }

    private func identity(jid: String, deviceID: Int) -> SignalIdentityStorageItem? {
        realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: deviceID))
    }

    private func reply(id: String, from: String?, bundle: OMEMO2PublishedBundle) throws -> XMPPIQ {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let items = DDXMLElement(name: "items", xmlns: OMEMO2DeviceListCodec.pubsub)
        items.addAttribute(withName: "node", stringValue: OmemoManager.NodeType.bundle.rawValue)
        items.addChild(try OMEMO2BundleCodec.encode(bundle)); pubsub.addChild(items)
        let iq = XMPPIQ(iqType: .result, elementID: id, child: pubsub)
        if let from { iq.addAttribute(withName: "from", stringValue: from) }
        return iq
    }

    private func bundle(deviceID: Int) throws -> OMEMO2PublishedBundle {
        let context = try OMEMO2Context(error: ())
        let identity = try context.generateIdentity()
        let spk = try context.generateKeyPair()
        return OMEMO2PublishedBundle(deviceID: deviceID, identityKey: identity.publicKey,
                                    fingerprintPublicKey: identity.fingerprintPublicKey,
                                    signedPreKey: spk.publicKey, signedPreKeyID: 3,
                                    signature: try context.sign(spk.publicKey, identity: identity),
                                    preKeys: [OMEMO2PublicPreKey(id: 9, publicKey: try context.generateKeyPair().publicKey)])
    }

    private func drainMainRunLoop() {
        let drained = expectation(description: "Bundle cache projection completed")
        RunLoop.main.perform { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        realm.refresh()
    }

    private final class LockedRequestIDs {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ id: String) { lock.lock(); storage.append(id); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
