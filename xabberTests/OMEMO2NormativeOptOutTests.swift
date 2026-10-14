import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Prepared first for N08. Policy API can be renamed before app registration.
final class OMEMO2NormativeOptOutTests: XCTestCase {
    private var previousRealm: Realm.Configuration!
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false
        var failReads = false
        func load(owner: String) throws -> Data? {
            if failReads { throw OMEMO2StorageError.persistenceFailed }
            return records[owner]
        }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private struct Fixture {
        let sender: OmemoManager
        let receiver: OmemoManager
        let senderMemory: Memory
        let receiverMemory: Memory
        let senderID = 41
        let receiverID = 42
    }
    override func setUp() {
        super.setUp()
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N08-\(UUID())")
    }
    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testOnlyVerifiedSCEPeerOptOutCreatesPersistentPendingDecision() throws {
        let f = try fixture()
        let wire = try message(f, content: "<body xmlns='jabber:client'>Authenticated text</body><opt-out xmlns='urn:xmpp:omemo:2'><reason>Plain text preferred</reason></opt-out>")
        guard case .verified = f.receiver.prepareIncoming(wire) else { return XCTFail("Genuine authenticated opt-out must decrypt") }
        XCTAssertEqual(try decision(f), .pending)
        XCTAssertTrue(try XCTUnwrap(f.receiver.omemo2Storage).sessionExists(jid: f.sender.owner, deviceID: f.senderID))
        let restarted = OmemoManager(withOwner: f.receiver.owner)
        restarted.omemo2Storage = try XabberOMEMO2Storage(owner: restarted.owner, persistence: f.receiverMemory)
        XCTAssertEqual(try OMEMO2OptOutPolicy.decision(owner: restarted.owner, jid: f.sender.owner, realm: WRealm.safe(), storage: restarted.omemo2Storage), .pending)
    }

    func testOuterOptOutCannotRequestPlaintext() throws {
        let f = try fixture()
        let wire = try message(f, content: "<body xmlns='jabber:client'>Authenticated body</body>")
        wire.addChild(try DDXMLElement(xmlString: "<opt-out xmlns='urn:xmpp:omemo:2'><reason>Outer injection</reason></opt-out>"))
        guard case .verified = f.receiver.prepareIncoming(wire) else { return XCTFail("Expected valid content") }
        XCTAssertEqual(try decision(f), .none)
    }

    func testForeignOptOutNameInsideVerifiedSCEIsSemanticallyInactive() throws {
        let f = try fixture()
        let wire = try message(f, content: "<opt-out xmlns='urn:foreign'><reason>Wrong namespace</reason></opt-out>")
        guard case .verified = f.receiver.prepareIncoming(wire) else { return XCTFail("Foreign extension can remain inert content") }
        XCTAssertEqual(try decision(f), .none)
    }

    func testPrefixedExpandedQNameActivatesPendingDecision() throws {
        let f = try fixture()
        let wire = try message(f, content: "<body xmlns='jabber:client'>Authenticated text</body><om:opt-out xmlns:om='urn:xmpp:omemo:2'><om:reason>Prefixed</om:reason></om:opt-out>")
        guard case .verified = f.receiver.prepareIncoming(wire) else { return XCTFail("Expected real prefixed decrypt") }
        XCTAssertEqual(try decision(f), .pending)
    }

    func testPayloadAuthenticationFailureNeverActivatesOptOut() throws {
        let f = try fixture()
        let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>")
        let payload = try XCTUnwrap(wire.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload", xmlns: OmemoManager.xmlns))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue))
        bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()
        guard case .failed = f.receiver.prepareIncoming(wire) else { return XCTFail("Modified MAC must fail") }
        XCTAssertEqual(try decision(f), .none)
    }

    func testPlaintextOptOutAndForgedXMLSuccessMarkerDoNotActivate() throws {
        let f = try fixture()
        let wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.sender.owner)' to='\(f.receiver.owner)'><opt-out xmlns='urn:xmpp:omemo:2'/><omemo-result__system result='true'/></message>")
        guard case .notEncrypted = f.receiver.prepareIncoming(wire) else { return XCTFail("XML is not an internal grant") }
        XCTAssertEqual(try decision(f), .none)
    }

    func testReceivedCarbonCreatesPeerRequest() throws {
        let f = try fixture()
        let wire = try message(f, content: "<body xmlns='jabber:client'>Authenticated text</body><opt-out xmlns='urn:xmpp:omemo:2'/>")
        guard case .verified = f.receiver.prepareIncoming(try forwarded(wire, receiver: f.receiver.owner, route: "received"), context: .carbon) else { return XCTFail("Expected received carbon decrypt") }
        XCTAssertEqual(try decision(f), .pending)
    }

    func testOwnSentCarbonIsNotMistakenForPeerRequest() throws {
        let f = try fixture(sameOwner: true)
        let otherPeer = "other-peer@example.test"
        let wire = try message(f, content: "<body xmlns='jabber:client'>Authenticated text</body><opt-out xmlns='urn:xmpp:omemo:2'/>", to: otherPeer)
        guard case .verified = f.receiver.prepareIncoming(try forwarded(wire, receiver: f.receiver.owner, route: "sent"), context: .carbon) else { return XCTFail("Expected own-device sync decrypt") }
        let realm = try WRealm.safe()
        XCTAssertEqual(try OMEMO2OptOutPolicy.decision(owner: f.receiver.owner, jid: otherPeer, realm: realm, storage: f.receiver.omemo2Storage), .none)
        XCTAssertEqual(try OMEMO2OptOutPolicy.decision(owner: f.receiver.owner, jid: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage), .none)
    }

    func testArchivedAndSyncPreviewPeerRequestsUseTheSameVerifiedGate() throws {
        for route in ["archive", "sync"] {
            let f = try fixture()
            let wire = try message(f, content: "<body xmlns='jabber:client'>Authenticated text</body><opt-out xmlns='urn:xmpp:omemo:2'/>")
            let packet = route == "archive" ? try forwarded(wire, receiver: f.receiver.owner, route: "archive") : wire
            guard case .verified = f.receiver.prepareIncoming(packet, context: route == "archive" ? .archive : .syncPreview) else { return XCTFail("Expected authenticated \(route)") }
            XCTAssertEqual(try decision(f), .pending)
        }
    }

    func testOptOutActivatesBeforeAutomaticEmptyAcknowledgementIsPrepared() throws {
        let f = try fixture()
        var controls: [XMPPMessage] = []
        f.receiver.omemo2ControlSender = { controls.append($0) }
        let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>")
        guard case .consumed(.control) = f.receiver.prepareIncoming(wire) else { return XCTFail("Pure opt-out is a consumed protocol control") }
        XCTAssertTrue(controls.isEmpty, "No exempt system/control message while decision is pending")
        XCTAssertEqual(try XCTUnwrap(f.receiver.omemo2Storage).sessionMetadata(jid: f.sender.owner, deviceID: f.senderID)?.sendCounter, 0, "The pending gate runs before control ratchet mutation")
    }

    func testPendingBlocksBothRegularAndEncryptedSendAvailability() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let realm = try WRealm.safe()
        for type in [ClientSynchronizationManager.ConversationType.regular, .omemo, .omemo1, .axolotl] {
            XCTAssertFalse(OmemoSendAvailabilityPolicy.evaluate(owner: f.receiver.owner, jid: f.sender.owner, conversationType: type, realm: realm).canSend, type.rawValue)
        }
    }

    func testPendingBlocksAllPeerMessagesIncludingPlaintextExtensionsAndEncryptedControls() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let extensions = [
            "<body>Text</body>",
            "<reference xmlns='https://xabber.com/protocol/references' type='mutable'><media-sharing xmlns='urn:xmpp:sim:0'/></reference>",
            "<displayed xmlns='urn:xmpp:chat-markers:0' id='seen'/>",
            "<received xmlns='urn:xmpp:chat-markers:0' id='delivered'/>",
            "<received xmlns='urn:xmpp:receipts' id='receipt'/>",
            "<composing xmlns='http://jabber.org/protocol/chatstates'/>",
            "<attention xmlns='urn:xmpp:attention:0'/>",
            "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='42'/></encrypted>",
            "<trust xmlns='urn:xmpp:trust:0'/>"
        ]
        let realm = try WRealm.safe()
        for content in extensions {
            let message = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.sender.owner)/phone'>\(content)</message>")
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(message, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage), content)
        }
        let unaffected = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='another@example.test'><body>Allowed</body></message>")
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(unaffected, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(unaffected, owner: "other-account@example.test", realm: realm))
    }

    func testOwnerDirectedRewriteAndScheduleAndXENCannotBypassPeerGate() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let peer = f.sender.owner
        let wrappers = [
            "<replace xmlns='https://xabber.com/protocol/rewrite' id='old' type='urn:xmpp:omemo:2'><message to='\(peer)' from='\(f.receiver.owner)'><body>Edited</body></message></replace>",
            "<schedule xmlns='https://xabber.com/protocol/schedule' conversation='\(peer)' type='urn:xabber:chat' deliver-at='2030-01-01T00:00:00Z'><message xmlns='jabber:client' to='\(peer)'><body>Scheduled</body></message></schedule>",
            "<notify xmlns='urn:xabber:xen:0'><notification><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' to='\(peer)'><trust xmlns='urn:xmpp:trust:0'/></message></forwarded></notification><addresses xmlns='http://jabber.org/protocol/address'><address type='to' jid='\(peer)'/></addresses></notify>"
        ]
        let realm = try WRealm.safe()
        for wrapper in wrappers {
            let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='set' to='\(f.receiver.owner)'>\(wrapper)</iq>")
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(iq, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage), wrapper)
        }
        let query = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='get' to='\(peer)'><pubsub xmlns='http://jabber.org/protocol/pubsub'/></iq>")
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(query, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage), "Normal IQ state/capability queries are not messages")
    }

    func testExplicitPlaintextConfirmationPreservesRatchetsAndAllowsRegularRoute() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let before = try cryptographicState(f)
        let realm = try WRealm.safe()
        try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .plaintext, at: Date(), realm: realm, storage: f.receiver.omemo2Storage)
        XCTAssertEqual(try decision(f), .plaintext)
        XCTAssertEqual(try cryptographicState(f), before)
        XCTAssertTrue(OmemoSendAvailabilityPolicy.evaluate(owner: f.receiver.owner, jid: f.sender.owner, conversationType: .regular, realm: realm).canSend)
        let plain = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.sender.owner)'><body>Explicitly allowed plaintext</body></message>")
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(plain, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
    }

    func testActualXENAndScheduleBuildersAndTheirWireRoundTripsCannotBypassPendingGate() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let peer = try XCTUnwrap(XMPPJID(string: f.sender.owner))
        let payload = XMPPMessage(messageType: .chat, to: peer, elementID: "builder",
                                  child: DDXMLElement(name: "trust", xmlns: "urn:xmpp:trust:0"))
        payload.addBody("Text from real builder")
        let xen = XMPPNotificationsManager(withOwner: f.receiver.owner).formIQ(to: peer, child: payload)
        let scheduled = XMPPMessageScheduleManager(withOwner: f.receiver.owner).makeScheduleIQ(
            elementId: "scheduled-builder", conversation: f.sender.owner, conversationType: .regular,
            deliverAt: Date().addingTimeInterval(3600), payload: payload)
        let realm = try WRealm.safe()
        for packet in [xen, scheduled] {
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(packet, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
            let parsed = try DDXMLElement(xmlString: packet.xmlString)
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(parsed, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
        }
    }

    func testGeneratedRewriteAndGenericOneShotMessageCannotBypassPendingGate() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let inner = DDXMLElement(name: "message", xmlns: "https://xabber.com/protocol/rewrite")
        inner.addAttribute(withName: "to", stringValue: f.sender.owner)
        let body = DDXMLElement(name: "body", xmlns: "https://xabber.com/protocol/rewrite")
        body.stringValue = "Edited"
        inner.addChild(body)
        let replace = DDXMLElement(name: "replace", xmlns: "https://xabber.com/protocol/rewrite")
        replace.addAttribute(withName: "id", stringValue: "archived")
        replace.addChild(inner)
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: f.receiver.owner), elementID: "rewrite-builder", child: replace)
        let generic = DDXMLElement(name: "message")
        generic.addAttribute(withName: "to", stringValue: f.sender.owner)
        let realm = try WRealm.safe()
        for packet in [iq as DDXMLElement, try DDXMLElement(xmlString: iq.xmlString), generic] {
            XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(packet, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
        }
    }

    func testDeclineAndReturnToOMEMOPreserveExistingRatchets() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let before = try cryptographicState(f)
        let realm = try WRealm.safe()
        try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .omemo, at: Date(), realm: realm, storage: f.receiver.omemo2Storage)
        XCTAssertEqual(try decision(f), .omemo)
        XCTAssertEqual(try cryptographicState(f), before)
        let encrypted = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.sender.owner)'><encrypted xmlns='urn:xmpp:omemo:2'/></message>")
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(encrypted, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
    }

    func testExactArchiveAndCarbonReplayCannotOverturnLaterDecision() throws {
        let f = try fixture()
        let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>")
        _ = f.receiver.prepareIncoming(wire)
        let realm = try WRealm.safe()
        try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .plaintext, at: Date().addingTimeInterval(60), realm: realm, storage: f.receiver.omemo2Storage)
        for route in ["archive", "received"] {
            guard case .consumed(.duplicate) = f.receiver.prepareIncoming(try forwarded(wire, receiver: f.receiver.owner, route: route), context: route == "archive" ? .archive : .carbon) else { return XCTFail("Exact authenticated replay should consume") }
            XCTAssertEqual(try decision(f), .plaintext)
        }
    }

    func testPreviouslyUnseenOlderArchivedOptOutCannotOverturnLaterDecision() throws {
        let f = try fixture()
        let start = Date()
        let old = try message(f, content: "<body xmlns='jabber:client'>Historical content</body><opt-out xmlns='urn:xmpp:omemo:2'/>", at: start.addingTimeInterval(-60))
        let current = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>", at: start)
        _ = f.receiver.prepareIncoming(current)
        try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .omemo, at: start.addingTimeInterval(30), realm: WRealm.safe(), storage: f.receiver.omemo2Storage)
        guard case .verified = f.receiver.prepareIncoming(try forwarded(old, receiver: f.receiver.owner, route: "archive"), context: .archive) else { return XCTFail("Out-of-order authentic ciphertext still decrypts") }
        XCTAssertEqual(try decision(f), .omemo)
    }

    func testPreviouslyUnseenTimestampLessArchiveDoesNotReopenResolvedDecision() throws {
        let f = try fixture()
        let old = try message(f, content: "<body xmlns='jabber:client'>Historical content</body><opt-out xmlns='urn:xmpp:omemo:2'/>", includeTime: false)
        let current = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>")
        _ = f.receiver.prepareIncoming(current)
        try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .plaintext, at: Date().addingTimeInterval(30), realm: WRealm.safe(), storage: f.receiver.omemo2Storage)
        guard case .verified = f.receiver.prepareIncoming(try forwarded(old, receiver: f.receiver.owner, route: "archive"), context: .archive) else { return XCTFail("Legacy omitted SCE time does not prevent authenticated history decrypt") }
        XCTAssertEqual(try decision(f), .plaintext, "Conservative client replay policy for unavailable ordering")
    }

    func testNewerAuthenticatedRequestCanCreateANewDecisionAfterExplicitResolution() throws {
        let f = try fixture()
        let start = Date()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>", at: start))
        try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .omemo, at: start.addingTimeInterval(30), realm: WRealm.safe(), storage: f.receiver.omemo2Storage)
        let fresh = try message(f, content: "<body xmlns='jabber:client'>New content</body><opt-out xmlns='urn:xmpp:omemo:2'><reason>New request</reason></opt-out>", at: start.addingTimeInterval(60))
        guard case .verified = f.receiver.prepareIncoming(fresh) else { return XCTFail("Expected later authenticated request") }
        XCTAssertEqual(try decision(f), .pending)
    }

    func testFailedProtectedWriteRollsBackBothRatchetAndOptOutAndRetryRemainsEligible() throws {
        let f = try fixture()
        let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>")
        let before = f.receiverMemory.records[f.receiver.owner]
        f.receiverMemory.failWrites = true
        guard case .failed = f.receiver.prepareIncoming(wire) else { return XCTFail("Failed aggregate write must not grant receive success") }
        XCTAssertEqual(f.receiverMemory.records[f.receiver.owner], before)
        XCTAssertEqual(try decision(f), .none)
        f.receiverMemory.failWrites = false
        guard case .consumed(.control) = f.receiver.prepareIncoming(wire) else { return XCTFail("Neither N04 receipt nor ratchet committed; authentic retry remains eligible") }
        XCTAssertEqual(try decision(f), .pending)
    }

    func testFailedExplicitDecisionWriteLeavesPendingGateIntact() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let before = f.receiverMemory.records[f.receiver.owner]
        f.receiverMemory.failWrites = true
        XCTAssertThrowsError(try OMEMO2OptOutPolicy.resolve(owner: f.receiver.owner, jid: f.sender.owner, decision: .plaintext, at: Date(), realm: WRealm.safe(), storage: f.receiver.omemo2Storage))
        XCTAssertEqual(f.receiverMemory.records[f.receiver.owner], before)
        XCTAssertEqual(try decision(f), .pending)
    }

    func testStaleOrMissingRealmProjectionCannotBypassProtectedPendingGate() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let staleUIRealm = try Realm(configuration: .init(inMemoryIdentifier: "N08-stale-projection-\(UUID())"))
        let plain = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.sender.owner)'><body>Must remain blocked</body></message>")
        XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(plain, owner: f.receiver.owner, realm: staleUIRealm, storage: f.receiver.omemo2Storage))
    }

    func testUnavailableProtectedStateFailsClosedButTrulyAbsentStateAllowsOrdinaryMessages() throws {
        let f = try fixture()
        let plain = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.sender.owner)'><body>Plaintext</body></message>")
        let realm = try WRealm.safe()
        f.receiverMemory.failReads = true
        XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(plain, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage))
        let freshOwner = "no-omemo-\(UUID().uuidString.lowercased())@example.test"
        let fresh = try XabberOMEMO2Storage(owner: freshOwner, persistence: Memory())
        XCTAssertEqual(try OMEMO2OptOutPolicy.decision(owner: freshOwner, jid: f.sender.owner, realm: realm, storage: fresh), .none)
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(plain, owner: freshOwner, realm: realm, storage: fresh))
    }

    func testExplicitProtectedSourceCannotBeReusedForAnotherOwnerEvenOnOwnDeviceRoute() throws {
        let f = try fixture()
        let own = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.receiver.owner)'><trust xmlns='urn:xmpp:trust:0'/></message>")
        let realm = try WRealm.safe()
        XCTAssertFalse(OMEMO2OptOutPolicy.allowsOutgoing(own, owner: f.receiver.owner, realm: realm, storage: f.sender.omemo2Storage))
        XCTAssertThrowsError(try OMEMO2OptOutPolicy.requireAllowedMessage(owner: f.receiver.owner, jid: f.receiver.owner, storage: f.sender.omemo2Storage))
        f.receiverMemory.failReads = true
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(own, owner: f.receiver.owner, realm: realm, storage: f.receiver.omemo2Storage), "Correctly owner-bound own-device trust traffic is not a peer opt-out route")
    }

    func testPureOptOutHasNoDisplayableContentAcrossLiveArchiveAndReceivedCarbon() throws {
        for route in ["live", "archive", "received"] {
            let f = try fixture()
            let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'><reason>Please confirm</reason></opt-out>")
            let packet = route == "live" ? wire : try forwarded(wire, receiver: f.receiver.owner, route: route)
            let context: OMEMOReceiveContext = route == "archive" ? .archive : (route == "received" ? .carbon : .live)
            let result = f.receiver.prepareIncoming(packet, context: context)
            guard case .consumed(.control) = result else { return XCTFail("Pure opt-out must be intentionally consumed for \(route)") }
            XCTAssertNil(result.message, "No bubble, notification or archive preview")
            XCTAssertEqual(try decision(f), .pending)
            guard case .consumed(.duplicate) = f.receiver.prepareIncoming(packet, context: context) else {
                return XCTFail("Consumed opt-out retains authenticated replay accounting")
            }
        }
    }

    func testPureOptOutSyncLastMessageIsConsumedWithoutCreatingPreview() throws {
        let f = try fixture()
        let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>")
        let conversation = try DDXMLElement(xmlString: "<conversation xmlns='https://xabber.com/protocol/synchronization' jid='\(f.sender.owner)' type='urn:xmpp:omemo:2'><metadata node='https://xabber.com/protocol/synchronization'><last-message>\(wire.xmlString)</last-message></metadata></conversation>")
        let prepared = f.receiver.prepareSyncConversation(conversation)
        XCTAssertTrue(prepared.lastMessageWasConsumed)
        let xml = try XCTUnwrap(prepared.materializedElement())
        XCTAssertNil(xml.element(forName: "metadata")?.element(forName: "last-message"))
        XCTAssertEqual(try decision(f), .pending)
    }

    func testPureOwnSentOptOutCarbonIsConsumedWithoutCreatingPeerRequest() throws {
        let f = try fixture(sameOwner: true)
        let otherPeer = "other-peer@example.test"
        let wire = try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>", to: otherPeer)
        guard case .consumed(.control) = f.receiver.prepareIncoming(try forwarded(wire, receiver: f.receiver.owner, route: "sent"), context: .carbon) else {
            return XCTFail("Own pure opt-out control does not create a sent bubble")
        }
        XCTAssertEqual(try OMEMO2OptOutPolicy.decision(owner: f.receiver.owner, jid: otherPeer, realm: WRealm.safe(), storage: f.receiver.omemo2Storage), .none)
    }

    func testPendingStopsTextSystemAndMediaAdmissionBeforeCreatingBubbles() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let sender = MessageManager(withOwner: f.receiver.owner, activeStream: false)
        sender.omemo2OptOutStorage = f.receiver.omemo2Storage
        let media = MessageReferenceStorageItem()
        media.kind = .media; media.url = "/tmp/n08-local-image.jpg"

        let textID = sender.sendSimpleMessage("Blocked text", to: f.sender.owner, forwarded: [], conversationType: .regular)
        sender.sendSystemMessage("Blocked system content", attachments: [], to: f.sender.owner, conversationType: .regular)
        let mediaID = sender.willSendMediaMessage([media], to: f.sender.owner, forwarded: [], conversationType: .regular)

        XCTAssertTrue(textID.isEmpty)
        XCTAssertNil(mediaID)
        XCTAssertTrue(try WRealm.safe().objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).isEmpty)
        XCTAssertThrowsError(try f.receiver.encryptMessage(message: "<envelope xmlns='urn:xmpp:sce:1'><content/><rpad/></envelope>", to: f.sender.owner)) { error in
            guard case OMEMO2StorageError.pendingOptOut = error else { return XCTFail("Must gate before recipient fetch/encryption") }
        }
    }

    func testPendingStopsRetryAndUploadBeforeChangingStateOrReferences() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let sender = MessageManager(withOwner: f.receiver.owner, activeStream: false)
        sender.omemo2OptOutStorage = f.receiver.omemo2Storage
        let item = try storedOutgoing(f)
        let reference = MessageReferenceStorageItem()
        reference.primary = "reference-\(UUID())"; reference.kind = .media
        reference.url = "/tmp/n08-upload-retry.jpg"; reference.isUploaded = true; reference.hasError = true
        let realm = try WRealm.safe()
        try realm.write { item.references.append(reference) }

        sender.retrySending(item: item.primary)
        sender.uploadMedia(for: item.primary)

        XCTAssertEqual(item.state, .error)
        XCTAssertEqual(item.messageError, "Original error")
        XCTAssertTrue(reference.isUploaded)
        XCTAssertTrue(reference.hasError)
    }

    func testPendingStopsLocalAndWireEditsBeforeChangingBodyOrRegisteringIQ() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let item = try storedOutgoing(f)
        let sender = MessageManager(withOwner: f.receiver.owner, activeStream: false)
        sender.omemo2OptOutStorage = f.receiver.omemo2Storage
        let manager = MessageDeleteManager(withOwner: f.receiver.owner)
        manager.omemo2OptOutStorage = f.receiver.omemo2Storage
        let stream = CapturingStream()
        let edit = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.receiver.owner)' to='\(f.sender.owner)'><body>Changed draft</body></message>")

        sender.editSimpleMessage("Changed local body", primary: item.primary)
        manager.editMessage(stream, primary: item.primary, editedMessage: edit, conversationType: .regular)

        XCTAssertEqual(item.body, "Original body")
        XCTAssertNil(item.editDate)
        XCTAssertTrue(stream.elements.isEmpty)
        XCTAssertTrue(manager.queryIds.isEmpty)
    }

    func testPendingStopsScheduledCreationBeforeRequestRegistrationAndCallsRejection() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let manager = XMPPMessageScheduleManager(withOwner: f.receiver.owner)
        manager.omemo2OptOutStorage = f.receiver.omemo2Storage
        manager.isAvailable = true
        let stream = CapturingStream()
        let payload = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.sender.owner)'><body>Scheduled</body></message>")
        var rejection: XMPPMessageScheduleManager.ScheduleError?

        let id = manager.scheduleMessage(stream, conversation: f.sender.owner, conversationType: .regular,
            deliverAt: Date().addingTimeInterval(3600), payload: payload) { result in
                if case .failure(let error) = result { rejection = error }
            }

        XCTAssertNil(id)
        XCTAssertEqual(rejection, .sendRejected)
        XCTAssertTrue(stream.elements.isEmpty)
        XCTAssertTrue(manager.queryIds.isEmpty)
    }

    func testDeferredUploadBlockedAfterAdmissionBecomesRetryableAndKeepsUploadedReferences() throws {
        let f = try fixture()
        _ = f.receiver.prepareIncoming(try message(f, content: "<opt-out xmlns='urn:xmpp:omemo:2'/>"))
        let sender = MessageManager(withOwner: f.receiver.owner, activeStream: false)
        sender.omemo2OptOutStorage = f.receiver.omemo2Storage
        let item = try storedOutgoing(f)
        let reference = MessageReferenceStorageItem()
        reference.kind = .media; reference.url = "https://files.example.test/already-uploaded"
        reference.isUploaded = true; reference.hasError = false
        let realm = try WRealm.safe()
        try realm.write {
            item.state = .uploading; item.archivedId = ""; item.outgoing = true
            item.messageError = nil; item.references.append(reference)
        }

        sender.suspendDeferredUploadForOptOut(primary: item.primary)

        XCTAssertEqual(item.state, .error, "Already admitted upload must not retain a permanent spinner when no upload starts")
        XCTAssertEqual(item.messageErrorCode, "omemo-opt-out-pending")
        XCTAssertEqual(item.body, "Original body")
        XCTAssertTrue(reference.isUploaded)
        XCTAssertFalse(reference.hasError)
    }

    private func storedOutgoing(_ f: Fixture) throws -> MessageStorageItem {
        let item = MessageStorageItem()
        item.owner = f.receiver.owner; item.opponent = f.sender.owner
        item.messageId = "original-\(UUID())"
        item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: item.owner)
        item.archivedId = "archive-original"; item.conversationType = .regular
        item.body = "Original body"; item.legacyBody = "Original body"
        item.state = .error; item.messageError = "Original error"
        let realm = try WRealm.safe()
        try realm.write { realm.add(item) }
        return item
    }

    private final class CapturingStream: XMPPStream {
        var elements: [DDXMLElement] = []
        override var isAuthenticated: Bool { true }
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }

    private func cryptographicState(_ f: Fixture) throws -> NSDictionary {
        let data = try XCTUnwrap(f.receiverMemory.records[f.receiver.owner])
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        object.removeValue(forKey: "optOutDecisions")
        return object as NSDictionary
    }
    private func decision(_ f: Fixture) throws -> OMEMO2OptOutPolicy.Decision {
        try OMEMO2OptOutPolicy.decision(owner: f.receiver.owner, jid: f.sender.owner, realm: try WRealm.safe(), storage: f.receiver.omemo2Storage)
    }
    private func fixture(sameOwner: Bool = false) throws -> Fixture {
        let receiverOwner = "n08-receiver-\(UUID().uuidString.lowercased())@example.test"
        let senderOwner = sameOwner ? receiverOwner : "n08-sender-\(UUID().uuidString.lowercased())@example.test"
        let senderMemory = Memory(), receiverMemory = Memory()
        let sender = OmemoManager(withOwner: senderOwner), receiver = OmemoManager(withOwner: receiverOwner)
        let a = try XabberOMEMO2Storage(owner: senderOwner, persistence: senderMemory)
        let b = try XabberOMEMO2Storage(owner: receiverOwner, persistence: receiverMemory)
        _ = try a.prepare(deviceID: 41, preKeyCount: 8)
        let bundle = try b.prepare(deviceID: 42, preKeyCount: 8)
        sender.omemo2Storage = a; receiver.omemo2Storage = b
        _ = try sender.ensureOMEMO2Prepared(); _ = try receiver.ensureOMEMO2Prepared()
        let pk = try XCTUnwrap(bundle.preKeys.first)
        try a.initiateSession(jid: receiverOwner, deviceID: 42, bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey, signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: pk.publicKey, preKeyID: pk.id))
        return Fixture(sender: sender, receiver: receiver, senderMemory: senderMemory, receiverMemory: receiverMemory)
    }
    private func message(_ f: Fixture, content: String, to: String? = nil, at: Date = Date(), includeTime: Bool = true) throws -> XMPPMessage {
        let recipient = to ?? f.receiver.owner
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content>\(content)</content><rpad/><from jid='\(f.sender.owner)'/><to jid='\(recipient)'/></envelope>"
        let prepared = includeTime ? try Omemo2PayloadCodec.prepareOutgoingXML(xml, encryptionTime: at) : xml
        let sealed = try Omemo2PayloadCodec.seal(prepared)
        let cipher = try XCTUnwrap(f.sender.omemo2Storage).encrypt(sealed.keyAndMAC, jid: f.receiver.owner, deviceID: f.receiverID)
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.sender.owner)' to='\(recipient)' id='\(UUID())'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='\(f.senderID)'><keys jid='\(f.receiver.owner)'><key rid='\(f.receiverID)'\(cipher.isKeyExchange ? " kex='true'" : "")>\(cipher.data.base64EncodedString())</key></keys></header><payload>\(sealed.ciphertext.base64EncodedString())</payload></encrypted></message>")
    }
    private func forwarded(_ wire: XMPPMessage, receiver: String, route: String) throws -> XMPPMessage {
        let opening = route == "archive" ? "<result xmlns='urn:xmpp:mam:2' id='archived' queryid='n08'>" : "<\(route) xmlns='urn:xmpp:carbons:2'>"
        let closing = route == "archive" ? "</result>" : "</\(route)>"
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(receiver)' to='\(receiver)'>\(opening)<forwarded xmlns='urn:xmpp:forward:0'>\(wire.xmlString)</forwarded>\(closing)</message>")
    }
}
