import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Actual locally encrypted packets cross Account's final admission and stream
/// delegate. Only the network sink and protected persistence are isolated.
@MainActor
final class OMEMO2FinalRecipientTransportTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }

    private final class Stream: XMPPStream {
        weak var account: Account?
        var sent: [DDXMLElement] = []
        var deferred = false
        var pending: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) {
            if deferred { pending.append(element); return }
            deliver(element)
        }
        func deliverNext() {
            guard !pending.isEmpty else { return }
            deliver(pending.removeFirst())
        }
        private func deliver(_ element: DDXMLElement) {
            if let message = element as? XMPPMessage,
               account?.xmppStream(self, willSend: message) == nil { return }
            if let iq = element as? XMPPIQ,
               account?.xmppStream(self, willSend: iq) == nil { return }
            sent.append(element.copy() as! DDXMLElement)
            if let message = element as? XMPPMessage { account?.xmppStream(self, didSend: message) }
            else if let iq = element as? XMPPIQ { account?.xmppStream(self, didSend: iq) }
        }
    }

    private final class ResumableSM: XMPPStreamManagement {
        override func canResumeStream() -> Bool { true }
    }

    private struct Device {
        let manager: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let bundle: OMEMO2LocalBundle
        var owner: String { manager.owner }
    }

    private struct Fixture {
        let sender: Device
        let recipient: Device
        let account: Account
        let stream: Stream
    }

    private var oldRealm: Realm.Configuration!
    private var realm: Realm!
    private var oldUsers: [Account] = []
    private var accounts: [Account] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        oldRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "FinalRecipient-\(UUID())")
        realm = try WRealm.safe()
        oldUsers = AccountManager.shared.users
    }

    override func tearDown() {
        for account in accounts {
            account.queue.sync {}
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }
        AccountManager.shared.users = oldUsers
        accounts.removeAll()
        realm = nil
        if let oldRealm { Realm.Configuration.defaultConfiguration = oldRealm }
        super.tearDown()
    }

    func testQueuedProductionContentCannotReachSocketAfterExactRecipientIsRevoked() throws {
        let f = try fixture()
        let row = MessageStorageItem()
        row.owner = f.sender.owner; row.opponent = f.recipient.owner
        row.messageId = UUID().uuidString
        row.primary = MessageStorageItem.genPrimary(messageId: row.messageId, owner: row.owner)
        row.conversationType = .omemo; row.outgoing = true
        row.body = "prepared before exact recipient revoke"; row.legacyBody = row.body
        row.date = Date(); row.sentDate = row.date
        try realm.write { realm.add(row) }
        f.account.queue.suspend()
        let admitted = f.account.messages.processSender(item: row.primary)
        let preparedState = f.sender.memory.records[f.sender.owner]
        try setTrust(f, .revoked)
        f.account.queue.resume()
        f.account.queue.sync {}
        realm.refresh()

        XCTAssertTrue(admitted, "Content must really be prepared before the queued transport seam")
        XCTAssertNotNil(preparedState)
        XCTAssertTrue(f.stream.sent.isEmpty, "Revoked prepared recipient must never reach the socket")
        XCTAssertEqual(f.sender.memory.records[f.sender.owner], preparedState, "Final denial does not reset/re-encrypt a committed ratchet")
        XCTAssertEqual(row.body, "prepared before exact recipient revoke")
        XCTAssertEqual(row.state, .error, "The retained bubble must be retryable rather than stuck sending")
        XCTAssertEqual(row.messageErrorCode, "omemo-recipient-changed", "A recipient revoke is not an opt-out decision")
        if let leaked = f.stream.sent.first as? XMPPMessage {
            XCTAssertEqual(try authenticatedBody(leaked, at: f.recipient), row.body,
                "The regression packet is genuine decryptable content, not a malformed mock")
        }
    }

    func testFinalPreparationRejectsRemovedRecipientWithoutMutatingCommittedSecrets() throws {
        let f = try fixture(); let packet = try packet(f)
        try advertise(f.sender.manager, jid: f.recipient.owner, ids: [])
        let before = f.sender.memory.records[f.sender.owner]
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(packet))
        XCTAssertEqual(f.sender.memory.records[f.sender.owner], before)
        XCTAssertTrue(f.stream.sent.isEmpty)
    }

    func testFinalWillSendRejectsPreparedOldIdentityEvenWhenReplacementUnderSameSIDIsTrusted() throws {
        let f = try fixture(); let packet = try packet(f)
        let replacement = try device(owner: f.recipient.owner, id: f.recipient.bundle.deviceID)
        try cache(replacement, observer: f.sender)
        let before = f.sender.memory.records[f.sender.owner]
        XCTAssertNil(f.account.xmppStream(f.stream, willSend: packet))
        XCTAssertEqual(f.sender.memory.records[f.sender.owner], before)
    }

    func testExplicitSessionReplacementInvalidatesPreparedContentWithoutFreshEncryption() throws {
        let f = try fixture(); let packet = try packet(f)
        try f.sender.storage.replaceOutgoingSessions()
        let before = f.sender.memory.records[f.sender.owner]
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(packet))
        XCTAssertEqual(f.sender.memory.records[f.sender.owner], before)
    }

    func testCurrentRealCiphertextSurvivesOrdinaryCopyAndDecryptsAtItsRecipient() throws {
        let f = try fixture(); let packet = try packet(f)
        let copied = try XMPPMessage(xmlString: packet.xmlString)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(copied))
        _ = f.account.sendPrimaryStanza(copied)
        XCTAssertEqual(f.stream.sent.count, 1)
        XCTAssertEqual(try authenticatedBody(try XCTUnwrap(f.stream.sent.first as? XMPPMessage), at: f.recipient), "bounded final recipient content")
    }

    func testPayloadlessACKCanConfirmAnUntrustedIdentity() throws {
        let f = try fixture(); _ = try packet(f)
        try setTrust(f, .unknown)
        let control = try f.sender.manager.makeOMEMO2Control(jid: f.recipient.owner, deviceID: f.recipient.bundle.deviceID)
        XCTAssertTrue(SCEReceivePolicy.children(of: try XCTUnwrap(control.element(forName: "encrypted", xmlns: OmemoManager.xmlns)), named: "payload", xmlns: OmemoManager.xmlns).isEmpty)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(control))
        XCTAssertNotNil(f.account.xmppStream(f.stream, willSend: control))
    }

    func testPreparedCipherCannotBeSentThroughAnotherAccount() throws {
        let f = try fixture(); let packet = try packet(f)
        let other = try device(owner: "other-\(UUID())@example.test", id: 73)
        let account = makeAccount(other)
        XCTAssertFalse(account.preparePrimaryStreamStanzaForSend(packet))
    }

    func testMalformedRecipientAndChangedCiphertextCannotRetainPreparationAuthority() throws {
        for change in ["recipient", "SID", "payload"] {
            let f = try fixture(); let packet = try packet(f)
            let encrypted = try XCTUnwrap(packet.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
            let header = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns))
            if change == "recipient" { packet.removeAttribute(forName: "to"); packet.addAttribute(withName: "to", stringValue: "elsewhere@example.test") }
            else if change == "SID" { header.removeAttribute(forName: "sid"); header.addAttribute(withName: "sid", integerValue: 99) }
            else { encrypted.element(forName: "payload", xmlns: OmemoManager.xmlns)?.stringValue = Data(repeating: 7, count: 32).base64EncodedString() }
            XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(packet), change)
        }
    }

    func testOrdinaryMessagePresenceAndIQRemainUnaffectedByOMEMORecipientTrust() throws {
        let f = try fixture(); try setTrust(f, .revoked)
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: f.recipient.owner), elementID: "ordinary")
        message.addBody("explicit ordinary content")
        for stanza in [message as XMPPElement, XMPPPresence(), XMPPIQ(type: "get", elementID: "ordinary-iq")] {
            XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(stanza))
        }
    }

    func testPreparedContentSurvivesNormalOutgoingAndIncomingRatchetProgress() throws {
        let f = try fixture()
        _ = try authenticatedBody(try packet(f), at: f.recipient)
        let prepared = try packet(f)
        let before = f.sender.memory.records[f.sender.owner]
        let reply = try packet(sender: f.recipient, recipient: f.sender)
        XCTAssertEqual(try authenticatedBody(reply, at: f.sender), "bounded final recipient content")
        _ = try packet(f)
        XCTAssertNotEqual(f.sender.memory.records[f.sender.owner], before)
        let copied = try XMPPMessage(xmlString: prepared.xmlString)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(copied))
        XCTAssertNotNil(f.account.xmppStream(f.stream, willSend: copied))
        XCTAssertEqual(try authenticatedBody(copied, at: f.recipient), "bounded final recipient content")
    }

    func testSemanticNamespacePrefixCopyRetainsAuthorityButUnsupportedCarriersDoNot() throws {
        let f = try fixture(); let original = try packet(f)
        let encrypted = try XCTUnwrap(original.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        let prefixedXML = encrypted.xmlString.replacingOccurrences(of: "<encrypted", with: "<o:encrypted")
            .replacingOccurrences(of: "</encrypted>", with: "</o:encrypted>")
            .replacingOccurrences(of: "xmlns=", with: "xmlns:o=")
        // Prefix the entire OMEMO vocabulary, preserving expanded QNames.
        var qualified = prefixedXML
        for name in ["header", "keys", "key", "payload"] {
            qualified = qualified.replacingOccurrences(of: "<\(name)", with: "<o:\(name)")
                .replacingOccurrences(of: "</\(name)>", with: "</o:\(name)>")
        }
        let prefixed = try XMPPMessage(xmlString: "<message xmlns='jabber:client' to='\(f.recipient.owner)' from='\(f.sender.owner)' id='prefixed'>\(qualified)</message>")
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(prefixed))
        XCTAssertNotNil(f.account.xmppStream(f.stream, willSend: prefixed))
        let foreign = try XMPPMessage(xmlString: "<message xmlns='urn:foreign' to='\(f.recipient.owner)'>\(encrypted.xmlString)</message>")
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(foreign))
        let unsupported = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='set' id='bad-carrier'><extension xmlns='urn:foreign'>\(original.xmlString)</extension></iq>")
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(unsupported))
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(original), "Malformed aliases cannot erase the real prepared candidate")
    }

    func testNestedKeyOrPayloadTextCannotBorrowOriginalCipherAuthority() throws {
        for name in ["key", "payload"] {
            let f = try fixture(); let original = try packet(f)
            let malformed = original.copy() as! XMPPMessage
            let encrypted = try XCTUnwrap(malformed.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
            let leaf: DDXMLElement
            if name == "key" {
                let header = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns))
                leaf = try XCTUnwrap(header.element(forName: "keys", xmlns: OmemoManager.xmlns)?.element(forName: "key", xmlns: OmemoManager.xmlns))
            } else { leaf = try XCTUnwrap(encrypted.element(forName: name, xmlns: OmemoManager.xmlns)) }
            let text = leaf.stringValue; leaf.stringValue = nil
            let wrapper = DDXMLElement(name: "wrapped", xmlns: "urn:foreign"); wrapper.stringValue = text
            leaf.addChild(wrapper)
            XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(malformed), name)
            XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(original))
        }
    }

    func testFullFanoutMustStillMatchCurrentTrustedContactAndOwnDevices() throws {
        for ownDevice in [false, true] {
            let f = try fixture(); let prepared = try packet(f)
            let added = try device(owner: ownDevice ? f.sender.owner : f.recipient.owner, id: 83)
            try cache(added, observer: f.sender)
            try advertise(f.sender.manager, jid: added.owner, ids: ownDevice ? [41, 83] : [42, 83])
            XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(prepared), "A newly eligible device needs a rebuilt fanout")
        }
    }

    func testPendingOwnDeviceAndOptOutStillBlockPreviouslyPreparedContentAndControl() throws {
        let f = try fixture(); let prepared = try packet(f)
        let control = try f.sender.manager.makeOMEMO2Control(jid: f.recipient.owner, deviceID: 42)
        let added = try device(owner: f.sender.owner, id: 83); try cache(added, observer: f.sender)
        let projection = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: f.sender.owner, jid: f.sender.owner, deviceId: 83)))
        try realm.write { projection.state = .unknown }
        try advertise(f.sender.manager, jid: f.sender.owner, ids: [41, 83])
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(prepared))
        XCTAssertNotNil(f.account.xmppStream(f.stream, willSend: control), "Content-free control remains permitted for trust establishment")
        _ = try authenticatedBody(prepared, at: f.recipient)
        let optOut = try DDXMLElement(xmlString: "<opt-out xmlns='urn:xmpp:omemo:2'><reason>Authenticated opt-out</reason></opt-out>")
        let request = try packet(sender: f.recipient, recipient: f.sender, additionalContent: [optOut])
        _ = try authenticatedBody(request, at: f.sender)
        XCTAssertEqual(try f.sender.storage.optOutDecision(jid: f.recipient.owner), .pending)
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(control), "Opt-out remains the first transport gate for ACKs too")
    }

    func testPreparedCapacityDenialDoesNotAdvanceCryptoOrEvictQueuedCandidates() throws {
        let f = try fixture()
        var queued: [XMPPMessage] = []
        for _ in 0..<256 { queued.append(try packet(f)) }
        let before = f.sender.memory.records[f.sender.owner]
        XCTAssertThrowsError(try packet(f))
        XCTAssertEqual(f.sender.memory.records[f.sender.owner], before, "Capacity is reserved before outgoing ratchet mutation")
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(try XCTUnwrap(queued.first)))
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(try XCTUnwrap(queued.last)))
        f.account.notePrimaryStreamStanzaDidFailToSend(queued[64])
        let replacement = try packet(f)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(replacement))
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(queued[0]))
        XCTAssertThrowsError(try packet(f), "Known-unsent cleanup frees exactly one candidate")
    }

    func testNonSMActualDidSendAllowsMoreThanCapacitySuccessfulMessages() throws {
        let f = try fixture()
        for _ in 0..<260 {
            let prepared = try packet(f)
            _ = f.account.sendPrimaryStanza(prepared)
        }
        XCTAssertEqual(f.stream.sent.count, 260)
        XCTAssertEqual(try authenticatedBody(try XCTUnwrap(f.stream.sent.first as? XMPPMessage), at: f.recipient), "bounded final recipient content")
        XCTAssertEqual(try authenticatedBody(try XCTUnwrap(f.stream.sent.last as? XMPPMessage), at: f.recipient), "bounded final recipient content")
    }

    func testSMActualAckRetiresOnlyTransmittedFrameAndKeepsPendingSameIDCandidate() throws {
        let f = try fixture(); useResumableSM(f)
        let ordinary = XMPPMessage(type: "chat", to: XMPPJID(string: f.recipient.owner), elementID: "same-ID")
        ordinary.addBody("ordinary first frame")
        _ = f.account.sendPrimaryStanza(ordinary)
        let sent = try packet(f); sent.removeAttribute(forName: "id"); sent.addAttribute(withName: "id", stringValue: "same-ID")
        _ = f.account.sendPrimaryStanza(sent)
        let pending = try packet(f); pending.removeAttribute(forName: "id"); pending.addAttribute(withName: "id", stringValue: "same-ID")
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(pending))
        f.account.xmppStreamManagement(f.account.sm, didReceiveAckForStanzaIds: ["same-ID"])
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(sent), "ACK of the earlier ordinary frame cannot retire encrypted inflight content")
        f.account.xmppStreamManagement(f.account.sm, didReceiveAckForStanzaIds: ["same-ID"])
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(sent), "Only actual SM ACK retires the matching transmitted frame")
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(pending), "A same-ID preflight is not an actual didSend witness")
        f.account.xmppStreamManagement(f.account.sm, didReceiveAckForStanzaIds: ["same-ID"])
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(pending), "Unknown ACK must not consume a queued candidate")
    }

    func testSMInflightCopySurvivesUnsentFailureAndRepeatedFinalGates() throws {
        let f = try fixture(); useResumableSM(f)
        let sent = try packet(f)
        _ = f.account.sendPrimaryStanza(sent)
        let copied = try XMPPMessage(xmlString: sent.xmlString)
        f.account.notePrimaryStreamStanzaDidFailToSend(copied)
        for _ in 0..<3 {
            XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(copied))
            XCTAssertNotNil(f.account.xmppStream(f.stream, willSend: copied))
            f.account.notePrimaryStreamStanzaDidFailToSend(copied)
        }
        XCTAssertEqual(f.stream.sent.count, 1, "Final validation/failed copies do not manufacture actual didSend frames")
        f.account.xmppStreamManagement(f.account.sm, didReceiveAckForStanzaIds: [try XCTUnwrap(sent.elementID)])
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(copied))
    }

    func testResumableDisconnectKeepsInflightAndPendingButFailedResumeRetiresOnlyInflight() throws {
        let f = try fixture(); useResumableSM(f)
        let sent = try packet(f); _ = f.account.sendPrimaryStanza(sent)
        let pending = try packet(f)
        f.sender.manager.preparedOMEMO2TransportDidDisconnect(canResume: true)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(try XMPPMessage(xmlString: sent.xmlString)))
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(pending))
        f.sender.manager.preparedOMEMO2TransportDidDisconnect(canResume: false)
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(sent))
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(pending), "Confirmed full reconnect must not evict never-transmitted candidates")
        _ = try packet(f)
    }

    func testOneSMFrameContainingTwoProtectedMessagesRetiresTogetherAfterActualAck() throws {
        let f = try fixture(); useResumableSM(f)
        let first = try packet(f); let second = try packet(f)
        let notify = DDXMLElement(name: "notify", xmlns: "urn:xabber:xen:0")
        for packet in [first, second] {
            let notification = DDXMLElement(name: "notification", xmlns: "urn:xabber:xen:0")
            let forward = DDXMLElement(name: "forwarded", xmlns: "urn:xmpp:forward:0")
            forward.addChild(packet.copy() as! XMPPMessage); notification.addChild(forward); notify.addChild(notification)
        }
        let iq = XMPPIQ(type: "set", elementID: "one-frame-two-messages"); iq.addChild(notify)
        _ = f.account.sendPrimaryStanza(iq)
        XCTAssertEqual(f.stream.sent.count, 1)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(first))
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(second))
        f.account.xmppStreamManagement(f.account.sm, didReceiveAckForStanzaIds: ["one-frame-two-messages"])
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(first))
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(second))
    }

    func testKnownUnsentAliasFailureCannotRevokeAlreadyQueuedOriginal() throws {
        let f = try fixture(); f.stream.deferred = true
        let queued = try packet(f)
        _ = f.account.sendPrimaryStanza(queued)
        let neverSubmitted = try XMPPMessage(xmlString: queued.xmlString)
        f.account.notePrimaryStreamStanzaDidFailToSend(neverSubmitted)
        XCTAssertTrue(f.stream.sent.isEmpty)
        f.stream.deliverNext()
        XCTAssertEqual(f.stream.sent.count, 1, "A failed unsent alias cannot erase a live queued submission")
        XCTAssertEqual(try authenticatedBody(try XCTUnwrap(f.stream.sent.first as? XMPPMessage), at: f.recipient), "bounded final recipient content")
    }

    func testTwoQueuedCopiesSurviveFirstNonSMTransmissionUntilEachTerminalResult() throws {
        let f = try fixture(); f.stream.deferred = true
        let first = try packet(f); let second = try XMPPMessage(xmlString: first.xmlString)
        _ = f.account.sendPrimaryStanza(first); _ = f.account.sendPrimaryStanza(second)
        f.stream.deliverNext()
        XCTAssertEqual(f.stream.sent.count, 1)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(second))
        f.stream.deliverNext()
        XCTAssertEqual(f.stream.sent.count, 2, "First non-SM didSend cannot retire the second queued copy")
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(first), "All actual non-SM attempts are now finished")
    }

    func testTwoActualSubmissionsOfSameObjectHaveIndependentQueuedLifetimes() throws {
        let f = try fixture(); f.stream.deferred = true
        let message = try packet(f)
        _ = f.account.sendPrimaryStanza(message); _ = f.account.sendPrimaryStanza(message)
        f.stream.deliverNext()
        XCTAssertEqual(f.stream.sent.count, 1)
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(message))
        f.stream.deliverNext()
        XCTAssertEqual(f.stream.sent.count, 2)
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(message))
    }

    func testNestedCanonicalEncryptedHeaderExtensionCannotBorrowTransportAuthority() throws {
        let f = try fixture(); let original = try packet(f)
        let malformed = try XMPPMessage(xmlString: original.xmlString)
        let encrypted = try XCTUnwrap(malformed.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        let header = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns))
        let extensionNode = DDXMLElement(name: "extension", xmlns: "urn:foreign")
        extensionNode.addChild(try XCTUnwrap(original.element(forName: "encrypted", xmlns: OmemoManager.xmlns)).copy() as! DDXMLElement)
        header.addChild(extensionNode)
        XCTAssertFalse(f.account.preparePrimaryStreamStanzaForSend(malformed), "Every canonical encrypted descendant needs its own supported carrier, including nested headers")
        XCTAssertTrue(f.account.preparePrimaryStreamStanzaForSend(original))
        for duplicateNamespace in ["urn:foreign", OmemoManager.xmlns] {
            let pair = try fixture(); let valid = try packet(pair)
            let alias = try XMPPMessage(xmlString: valid.xmlString)
            let duplicate = duplicateNamespace == OmemoManager.xmlns
                ? try XCTUnwrap(valid.element(forName: "encrypted", xmlns: OmemoManager.xmlns)).copy() as! DDXMLElement
                : DDXMLElement(name: "encrypted", xmlns: duplicateNamespace)
            alias.addChild(duplicate)
            XCTAssertFalse(pair.account.preparePrimaryStreamStanzaForSend(alias), duplicateNamespace)
            XCTAssertTrue(pair.account.preparePrimaryStreamStanzaForSend(valid), "Rejected duplicate alias must retain the original candidate: \(duplicateNamespace)")
        }
    }

    private func useResumableSM(_ f: Fixture) {
        f.account.sm = ResumableSM(storage: f.account.smStorage, dispatchQueue: f.account.queue)
    }

    private func fixture() throws -> Fixture {
        let suffix = UUID().uuidString.lowercased()
        let sender = try device(owner: "final-sender-\(suffix)@example.test", id: 41)
        let recipient = try device(owner: "final-recipient-\(suffix)@example.test", id: 42)
        try cache(recipient, observer: sender); try cache(sender, observer: recipient)
        for observer in [sender, recipient] {
            try advertise(observer.manager, jid: sender.owner, ids: [41])
            try advertise(observer.manager, jid: recipient.owner, ids: [42])
        }
        let account = makeAccount(sender)
        let stream = Stream(); stream.account = account; account.xmppStream = stream
        return Fixture(sender: sender, recipient: recipient, account: account, stream: stream)
    }

    private func makeAccount(_ device: Device) -> Account {
        let account = Account(jid: device.owner, queue: DispatchQueue(label: "FinalTransport-\(UUID())"))
        account.omemo = device.manager
        account.chatMarkers = ChatMarkersManager(withOwner: device.owner, withoutAfterburnTimer: true)
        account.sendReadiness.onReadinessChanged = nil
        account.sendReadiness.markStreamManagementEnabled()
        AccountManager.shared.users.append(account); accounts.append(account)
        return account
    }

    private func device(owner: String, id: Int) throws -> Device {
        let memory = Memory(); let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try storage.prepare(deviceID: id, preKeyCount: 3)
        let manager = OmemoManager(withOwner: owner); manager.omemo2Storage = storage
        _ = try manager.ensureOMEMO2Prepared(attemptPublication: false)
        return Device(manager: manager, storage: storage, memory: memory, bundle: bundle)
    }

    private func cache(_ device: Device, observer: Device) throws {
        let bundle = device.bundle
        let primary = SignalIdentityStorageItem.genRpimary(owner: observer.owner, jid: device.owner, deviceId: bundle.deviceID)
        let identity = SignalIdentityStorageItem(); identity.primary = primary
        identity.owner = observer.owner; identity.jid = device.owner; identity.deviceId = bundle.deviceID
        identity.protocolProfile = OmemoManager.xmlns; identity.cryptoBackend = XabberOMEMO2Storage.backend
        identity.identityKey = bundle.identityKey.base64EncodedString(); identity.signedPreKey = bundle.signedPreKey.base64EncodedString()
        identity.signedPreKeyId = Int(bundle.signedPreKeyID); identity.signedPreKeySignature = bundle.signature.base64EncodedString()
        let projection = SignalDeviceStorageItem(); projection.owner = observer.owner; projection.jid = device.owner
        projection.deviceId = bundle.deviceID; projection.primary = SignalDeviceStorageItem.genPrimary(owner: observer.owner, jid: device.owner, deviceId: bundle.deviceID)
        projection.state = .trusted; projection.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        let prekeys = bundle.preKeys.map { key -> SignalPreKeysStorageItem in
            let row = SignalPreKeysStorageItem(); row.owner = observer.owner; row.jid = device.owner; row.deviceId = bundle.deviceID
            row.pkId = Int(key.id); row.preKey = key.publicKey.base64EncodedString(); row.keyUUID = UUID().uuidString; row.primary = row.keyUUID
            return row
        }
        try realm.write { realm.add(identity, update: .modified); realm.add(projection, update: .modified); realm.add(prekeys) }
    }

    private func advertise(_ manager: OmemoManager, jid: String, ids: [Int]) throws {
        let items = ids.map { "<device id='\($0)'/>" }.joined()
        let wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(jid)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(items)</devices></item></items></event></message>")
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(wire))
    }

    private func setTrust(_ f: Fixture, _ state: SignalDeviceStorageItem.TrustState) throws {
        let row = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: f.sender.owner, jid: f.recipient.owner, deviceId: f.recipient.bundle.deviceID)))
        try realm.write { row.state = state }
    }

    private func packet(_ f: Fixture) throws -> XMPPMessage {
        try packet(sender: f.sender, recipient: f.recipient)
    }

    private func packet(sender: Device, recipient: Device, additionalContent: [DDXMLElement] = []) throws -> XMPPMessage {
        let content = try XCTUnwrap(sender.manager.prepareStanzaContent(message: "bounded final recipient content", date: Date(), jid: recipient.owner, additionalContent: additionalContent, ignoreTimeSignature: true))
        let result = try sender.manager.encryptMessage(message: content, to: recipient.owner)
        let encrypted = try XCTUnwrap(result)
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: recipient.owner), elementID: UUID().uuidString)
        message.addNamespace(DDXMLNode.namespace(withName: "", stringValue: "jabber:client") as! DDXMLNode)
        message.addAttribute(withName: "from", stringValue: sender.owner)
        message.addChild(encrypted); return message
    }

    private func authenticatedBody(_ source: XMPPMessage, at recipient: Device) throws -> String? {
        let message = source.copy() as! XMPPMessage
        let time = DDXMLElement(name: "time", xmlns: "https://xabber.com/protocol/delivery")
        time.addAttribute(withName: "by", stringValue: recipient.owner); time.addAttribute(withName: "stamp", stringValue: Date().XMPPFormattedDate)
        message.addChild(time); recipient.manager.omemo2ControlSender = { _ in }
        guard case let .verified(clean, _, _) = recipient.manager.prepareIncoming(message) else {
            XCTFail("Expected genuine authenticated prepared packet"); return nil
        }
        return clean.body
    }
}
