import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Received chronology and media dates must have actual qualified time/delay tags.
final class ReceivedMessageDateAdmissionTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }
    private let owner = "date-owner@example.test"
    private let peer = "date-peer@example.test"
    private let stamp = "2026-10-20T08:00:01.234Z"
    private var previousRealm: Realm.Configuration!
    private var receiver: MessageManager!
    private var expectedDate: Date { Date(timeIntervalSince1970: 1_792_483_201.234) }

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ReceivedTagDates-\(UUID())")
        receiver = MessageManager(withOwner: owner, activeStream: false)
        receiver.unsubscribeReceiver()
    }

    override func tearDown() {
        receiver.unsubscribeReceiver()
        receiver = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testDelayOnlyLiveMessageUsesTheDelayTagDate() throws {
        receiver.receiveRuntime(try message(extra: delay()))
        XCTAssertEqual(try queued().date, expectedDate)
    }

    func testRuntimeWithoutQualifiedTagDoesNotAdmitWallClockDatedUserRow() throws {
        receiver.receiveRuntime(try message(extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='9999999999999999'/>"))
        XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
    }

    func testWrongOwnerTimeWithoutDelayCannotBecomeLocalMessageClock() throws {
        receiver.receiveRuntime(try message(extra: time(by: peer)))
        XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
    }

    func testForeignNamespaceTimeDoesNotAdmitWallClockDatedUserRow() throws {
        receiver.receiveRuntime(try message(extra: "<time xmlns='urn:foreign' stamp='\(stamp)'/>"))
        XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
    }

    func testFederatedTimeSelectsTheCurrentOwnerDate() throws {
        receiver.receiveRuntime(try message(extra: time(by: peer, stamp: "2026-10-20T07:59:59Z") + time(by: owner)))
        XCTAssertEqual(try queued().date, expectedDate)
    }

    func testOwnerTimeWinsOverLaterOfflineQueueDelay() throws {
        receiver.receiveRuntime(try message(extra: time(by: owner) + delay("2026-10-20T08:01:00Z")))
        XCTAssertEqual(try queued().date, expectedDate)
    }

    func testCarbonForwardedDelayCanDateTheOriginalMessage() throws {
        receiver.receiveCarbonForwarded(try carbon(sent: false, inner: message(), forwarded: delay()))
        XCTAssertEqual(try queued().date, expectedDate)
    }

    func testSentCarbonDelayCanDateTheOriginalMessage() throws {
        receiver.receiveCarbon(try carbon(sent: true, inner: message(from: owner, to: peer), forwarded: delay()))
        XCTAssertEqual(try queued().date, expectedDate)
    }

    func testMissingCarbonDateCannotBorrowNestedQuoteDate() throws {
        let quote = "<reference xmlns='https://xabber.com/protocol/references'><forwarded xmlns='urn:xmpp:forward:0'>\(delay())<message xmlns='jabber:client'><body>old quote</body></message></forwarded></reference>"
        receiver.receiveCarbonForwarded(try carbon(sent: false, inner: message(extra: quote)))
        XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
    }

    func testReferencesAndGalleryUseTheSameOwnerTimeAsTheirParent() throws {
        let node = try mediaMessage(extra: time(by: peer, stamp: "2026-10-20T07:59:59Z") + time(by: owner))
        let reference = try XCTUnwrap(parseReferences(node, primary: "media", jid: peer, owner: owner).first)
        XCTAssertEqual(reference.sentDate, expectedDate)
        XCTAssertEqual(reference.pendingMediaAttachment?.date, expectedDate)
    }

    func testAcceptedArchiveParentDateReachesMediaWhenTheLeafHasNoClock() throws {
        let row = MessageStorageItem()
        row.configureIncomingMessage(try mediaMessage(), owner: owner, opponent: peer,
            outgoing: false, isRead: true, date: expectedDate)
        let reference = try XCTUnwrap(row.references.first)
        XCTAssertEqual(reference.sentDate, expectedDate)
        XCTAssertEqual(reference.pendingMediaAttachment?.date, expectedDate)
    }

    func testUndatedMediaCannotInventAGalleryDate() throws {
        let reference = try XCTUnwrap(parseReferences(try mediaMessage(), primary: "media", jid: peer, owner: owner).first)
        XCTAssertNil(reference.pendingMediaAttachment)
    }

    func testUndatedEncryptedContentDoesNotCommitAndTheSameDatedCiphertextRemainsEligible() throws {
        let f = try encryptedFixture(content: true)
        let before = f.memory.records[owner]

        let result = f.manager.prepareIncoming(f.message)

        XCTAssertEqual(f.memory.records[owner], before, "Missing message clocks must not consume ratchet/prekey state")
        guard case .consumed(.invalidTransport) = result else {
            return XCTFail("Undated user content must be held before native decryption")
        }
        f.message.addChild(try DDXMLElement(xmlString: time(by: owner)))
        guard case let .verified(clean, _, _) = f.manager.prepareIncoming(f.message) else {
            return XCTFail("The same ciphertext with its actual delivery tag must remain eligible")
        }
        XCTAssertEqual(clean.body, "private dated content")
        XCTAssertNotEqual(f.memory.records[owner], before)
        guard case .consumed(.duplicate) = f.manager.prepareIncoming(f.message) else {
            return XCTFail("Only the admitted dated packet may consume its replay identity")
        }
    }

    func testPayloadlessSessionControlCanStillAdvanceWithoutAUserMessageDate() throws {
        let f = try encryptedFixture(content: false)
        guard case .consumed(.control) = f.manager.prepareIncoming(f.message) else {
            return XCTFail("Protocol key controls contain no dated user content")
        }
    }

    func testForeignSingletonTimeCannotOverrideAValidDelayBeforeDecryption() throws {
        let f = try encryptedFixture(content: true)
        f.message.addChild(try DDXMLElement(xmlString: time(by: peer, stamp: "2030-01-01T00:00:00Z")))
        f.message.addChild(try DDXMLElement(xmlString: delay()))
        XCTAssertEqual(getReceivedMessageDate(f.message, owner: owner), expectedDate)
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: f.message, owner: owner)?.date, expectedDate)
        guard case let .verified(clean, _, _) = f.manager.prepareIncoming(f.message) else {
            return XCTFail("A foreign account's timestamp must not replace the valid owned delay or reject valid ciphertext")
        }
        XCTAssertEqual(clean.body, "private dated content")
    }

    func testForeignSingletonWithoutDelayIsNotAnOriginalSendingClock() throws {
        let node = try message(extra: time(by: peer, stamp: "2030-01-01T00:00:00Z"))
        XCTAssertNil(try OmemoManager.originalSendingTime(for: node, owner: owner))
        XCTAssertNil(getReceivedMessageDate(node, owner: owner))
    }

    func testDatelessAuthenticatedTrustSharingPayloadRemainsAvailableToItsControlConsumer() throws {
        for optionalBody in ["", "<body xmlns='jabber:client'/>"] {
            let share = "<share xmlns='urn:xmpp:trustsharing:0' protocol='urn:xmpp:omemo:2'/>\(optionalBody)"
            let f = try encryptedFixture(content: true, semanticXML: share)
            let before = f.memory.records[owner]
            guard case let .verified(clean, proof, sender) = f.manager.prepareIncoming(f.message) else {
                return XCTFail("Authenticated TrustSharing payload is a control, with no user message clock requirement")
            }
            XCTAssertEqual(SCEReceivePolicy.children(of: clean, named: "share", xmlns: "urn:xmpp:trustsharing:0").count, 1)
            XCTAssertTrue((clean.body ?? "").isEmpty)
            XCTAssertTrue(proof.isAuthenticated)
            XCTAssertEqual(sender?.deviceID, 41)
            XCTAssertNotEqual(f.memory.records[owner], before)
            receiver.receiveRuntime(clean, encryption: proof, authenticatedSender: sender)
            XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })

            let raw = try encryptedFixture(content: true, semanticXML: share)
            let envelope = try XCTUnwrap(raw.manager.decryptMessage(raw.message))
            let content = try XCTUnwrap(SCEReceivePolicy.children(of: envelope, named: "content", xmlns: "urn:xmpp:sce:1").first)
            XCTAssertEqual(SCEReceivePolicy.children(of: content, named: "share", xmlns: "urn:xmpp:trustsharing:0").count, 1)
        }
    }

    func testDatelessEncryptedOptOutPayloadRemainsAControl() throws {
        for optionalBody in ["", "<body xmlns='jabber:client'/>"] {
            let f = try encryptedFixture(content: true, semanticXML: "<opt-out xmlns='urn:xmpp:omemo:2'/><origin-id xmlns='urn:xmpp:sid:0' id='control-id'/>\(optionalBody)")
            let before = f.memory.records[owner]
            guard case .consumed(.control) = f.manager.prepareIncoming(f.message) else {
                return XCTFail("Authenticated opt-out-only payload contains no dated user content")
            }
            XCTAssertNotEqual(f.memory.records[owner], before)
            XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
        }
    }

    func testUndatedUserContentMixedWithTrustSharingDoesNotCommit() throws {
        for body in ["private dated content", " "] {
            let f = try encryptedFixture(content: true, semanticXML: "<body xmlns='jabber:client'>\(body)</body><share xmlns='urn:xmpp:trustsharing:0'/>")
            let before = f.memory.records[owner]
            let held = f.manager.prepareIncoming(f.message)
            XCTAssertEqual(f.memory.records[owner], before)
            guard case .consumed(.invalidTransport) = held else {
                return XCTFail("A control sibling cannot exempt real user content from source date admission")
            }
            f.message.addChild(try DDXMLElement(xmlString: time(by: owner)))
            guard case let .verified(clean, _, _) = f.manager.prepareIncoming(f.message) else {
                return XCTFail("The same mixed ciphertext must remain eligible after its time tag arrives")
            }
            XCTAssertEqual(clean.body, body)
        }
    }

    private func queued() throws -> MessageManager.MessageQueueItem {
        try XCTUnwrap(receiver.performMessageQueueSync { receiver.queuedMessages.first })
    }

    private func encryptedFixture(content: Bool, semanticXML: String? = nil) throws -> (message: XMPPMessage, manager: OmemoManager, memory: Memory) {
        let memory = Memory()
        let sender = try XabberOMEMO2Storage(owner: peer, persistence: memory)
        let destination = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        _ = try sender.prepare(deviceID: 41, preKeyCount: 3)
        let bundle = try destination.prepare(deviceID: 42, preKeyCount: 3)
        let prekey = try XCTUnwrap(bundle.preKeys.first)
        try sender.initiateSession(jid: owner, deviceID: 42,
            bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                preKey: prekey.publicKey, preKeyID: prekey.id))
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = destination
        _ = try manager.ensureOMEMO2Prepared(attemptPublication: false)
        let semantics = semanticXML ?? "<body xmlns='jabber:client'>private dated content</body>"
        let sealed = try content ? Omemo2PayloadCodec.seal("<envelope xmlns='urn:xmpp:sce:1'><content>\(semantics)</content><rpad/><from jid='\(peer)'/><to jid='\(owner)'/><time stamp='\(stamp)'/></envelope>") : nil
        let wrapped = try sender.encrypt(sealed?.keyAndMAC ?? Data(repeating: 0, count: 32), jid: owner, deviceID: 42)
        let payload = sealed.map { "<payload>\($0.ciphertext.base64EncodedString())</payload>" } ?? ""
        let message = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(peer)' to='\(owner)' id='encrypted-date'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='41'><keys jid='\(owner)'><key rid='42' kex='\(wrapped.isKeyExchange ? "true" : "false")'>\(wrapped.data.base64EncodedString())</key></keys></header>\(payload)</encrypted></message>")
        return (message, manager, memory)
    }

    private func time(by: String, stamp: String? = nil) -> String {
        "<time xmlns='https://xabber.com/protocol/delivery' by='\(by)' stamp='\(stamp ?? self.stamp)'/>"
    }

    private func delay(_ value: String? = nil) -> String {
        "<delay xmlns='urn:xmpp:delay' stamp='\(value ?? stamp)'/>"
    }

    private func message(extra: String = "", from: String? = nil, to: String? = nil) throws -> XMPPMessage {
        try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(from ?? peer)/ios' to='\(to ?? owner)' id='date-message' type='chat'><body>dated content</body>\(extra)</message>")
    }

    private func mediaMessage(extra: String = "") throws -> XMPPMessage {
        let uri = "https://files.example.test/photo.jpg"
        return try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(peer)' to='\(owner)' id='media-message'>
          <body>\(uri)</body>\(extra)
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(uri.count)'>
            <file-sharing xmlns='https://xabber.com/protocol/files'><sources><uri>\(uri)</uri></sources><file><media-type>image/jpeg</media-type></file></file-sharing>
          </reference>
        </message>
        """)
    }

    private func carbon(sent: Bool, inner: XMPPMessage, forwarded: String = "") throws -> XMPPMessage {
        let kind = sent ? "sent" : "received"
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(owner)' to='\(owner)/ios'><\(kind) xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\(forwarded)\(inner.xmlString)</forwarded></\(kind)></message>")
    }
}
