import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

/// Xabber sync returns the current archived XML directly inside last-message.
/// A replacement has a fresh protected time and retains its original Delivery date.
final class OMEMO2NormativeEditedSyncTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private final class Stream: XMPPStream {
        override func send(_ element: DDXMLElement) {}
    }
    private struct Fixture {
        let sender: OmemoManager
        let receiver: OmemoManager
        let memory: Memory
    }
    private let syncNamespace = "https://xabber.com/protocol/synchronization"
    private let deliveryNamespace = "https://xabber.com/protocol/delivery"
    private let replacementDate = Date(timeIntervalSince1970: 1_770_000_000)
    private var originalRealm: Realm.Configuration!
    private var realmKeeper: Realm!
    private var owners: [String] = []
    override func setUp() {
        super.setUp()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "EditedSync-\(UUID())")
        // Keep the in-memory database alive while a snapshot briefly opens it
        // on its apply queue. Otherwise releasing that Realm discards the rows.
        realmKeeper = try! WRealm.safe()
    }
    override func tearDown() {
        for owner in owners { LastChatListSyncPreviewStore.shared.removeAll(for: owner) }
        owners.removeAll()
        realmKeeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testActualOwnedSnapshotAndPushDecryptCurrentVersionWithOldCreationDate() throws {
        for route in ["snapshot", "push"] {
            let f = try fixture()
            let wire = try editedWire(f)
            try withSync(f) { manager in
                try receive(route, manager: manager, fixture: f, wire: wire)

                let projection = try preview(f, id: "edited-id")
                XCTAssertEqual(projection.text, "verified sync edit", route)
                XCTAssertFalse(projection.isAttachment, route)
                let realm = try WRealm.safe()
                let primary = LastChatsStorageItem.genPrimary(jid: f.sender.owner, owner: f.receiver.owner, conversationType: .omemo)
                XCTAssertEqual(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary)?.messageDate, replacementDate.addingTimeInterval(-3600), route)
                XCTAssertTrue(realm.objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).isEmpty, route)
            }
        }
    }

    func testAccountDomainAndOmittedServerSenderKeepEditedSyncWorking() throws {
        for route in ["snapshot", "push"] {
            for from in [nil, "example.test"] as [String?] {
                let f = try fixture()
                let wire = try editedWire(f)
                try withSync(f) { manager in
                    try receive(route, manager: manager, fixture: f, wire: wire, from: from)
                    XCTAssertEqual(try preview(f, id: "edited-id").text, "verified sync edit", "\(route) from=\(from ?? "omitted")")
                }
            }
        }
    }

    func testPeerSenderOrWrongRecipientCannotSupplyServerReplacementAuthority() throws {
        for route in ["snapshot", "push"] {
            for spoof in ["sender", "recipient"] {
                let f = try fixture()
                let wire = try editedWire(f)
                let before = f.memory.records[f.receiver.owner]
                try withSync(f) { manager in
                    let from = spoof == "sender" ? f.sender.owner : f.receiver.owner
                    let to = spoof == "recipient" ? "another@example.test" : f.receiver.owner
                    try receive(route, manager: manager, fixture: f, wire: wire, from: from, to: to)

                    let projection = try preview(f, id: "edited-id")
                    XCTAssertEqual(projection.text, "Failed to decrypt", "\(route) \(spoof)")
                    XCTAssertFalse(projection.isAttachment)
                    XCTAssertEqual(f.memory.records[f.receiver.owner], before)
                }
            }
        }
    }

    func testRawSyncXMLWithoutInternalServerContextCannotOverrideOriginalDate() throws {
        let f = try fixture()
        let query = try DDXMLElement(xmlString: "<query xmlns='\(syncNamespace)' stamp='1770000000000000'>\(try conversation(f, wire: editedWire(f)).xmlString)</query>")
        let before = f.memory.records[f.receiver.owner]

        let value = try XCTUnwrap(f.receiver.prepareSyncConversations(query).first)

        XCTAssertFalse(value.lastMessageEncryption.isAuthenticated)
        XCTAssertEqual(f.memory.records[f.receiver.owner], before)
        let clean = try lastMessage(value)
        XCTAssertNil(clean.body)
        XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "replaced", xmlns: MessageDeleteManager.namespace).isEmpty)
        XCTAssertTrue(SCEReceivePolicy.hasOMEMO2(clean))
    }

    func testVerifiedSyncRestoresReplacementMarkerWithoutChangingCreationMetadata() throws {
        let f = try fixture()
        let value = f.receiver.prepareSyncConversation(try conversation(f, wire: editedWire(f)), serverContext: .accountServer)

        XCTAssertTrue(value.lastMessageEncryption.isAuthenticated)
        let clean = try lastMessage(value)
        XCTAssertEqual(clean.body, "verified sync edit")
        XCTAssertEqual(SCEReceivePolicy.children(of: clean, named: "replaced", xmlns: MessageDeleteManager.namespace).first?.attributeStringValue(forName: "stamp"), replacementDate.XMPPFormattedDate)
        XCTAssertEqual(SCEReceivePolicy.children(of: clean, named: "time", xmlns: deliveryNamespace).first?.attributeStringValue(forName: "stamp"), replacementDate.addingTimeInterval(-3600).XMPPFormattedDate)
        XCTAssertNil(clean.element(forName: "omemo-result__system"))
        XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "reference", xmlns: "https://xabber.com/protocol/references").isEmpty)
    }

    func testBadMACAndMalformedReplacementNeverRestoreMarkerOrRatchetState() throws {
        for invalid in ["mac", "malformed"] {
            let f = try fixture()
            let wire = try editedWire(f)
            if invalid == "mac" {
                let payload = try XCTUnwrap(wire.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload"))
                var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue))
                bytes[0] ^= 1
                payload.stringValue = bytes.base64EncodedString()
            } else {
                let replaced = try XCTUnwrap(SCEReceivePolicy.children(of: wire, named: "replaced", xmlns: MessageDeleteManager.namespace).first)
                replaced.addAttribute(withName: "stamp", stringValue: "not-a-date")
            }
            let before = f.memory.records[f.receiver.owner]

            let value = f.receiver.prepareSyncConversation(try conversation(f, wire: wire), serverContext: .accountServer)

            XCTAssertFalse(value.lastMessageEncryption.isAuthenticated, invalid)
            XCTAssertEqual(f.memory.records[f.receiver.owner], before, invalid)
            let clean = try lastMessage(value)
            XCTAssertNil(clean.body)
            XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "replaced", xmlns: MessageDeleteManager.namespace).isEmpty)
            XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "reference", xmlns: "https://xabber.com/protocol/references").isEmpty)
        }
    }

    func testActualControlSyncPushKeepsPreviousPreviewAndCreatesNoBubble() throws {
        let f = try fixture()
        try withSync(f) { manager in
            let previous = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.sender.owner)' to='\(f.receiver.owner)' id='previous-id'><body>previous preview</body></message>")
            try receive("push", manager: manager, fixture: f, wire: previous)
            let control = try f.sender.makeOMEMO2Control(jid: f.receiver.owner, deviceID: 42)
            control.addNamespace(DDXMLNode.namespace(withName: "", stringValue: "jabber:client") as! DDXMLNode)
            control.addAttribute(withName: "from", stringValue: f.sender.owner)
            control.addAttribute(withName: "id", stringValue: "control-id")
            let forgedBody = DDXMLElement(name: "body", xmlns: "jabber:client")
            forgedBody.stringValue = "forged control preview"
            control.addChild(forgedBody)
            control.addChild(try DDXMLElement(xmlString: "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(replacementDate.XMPPFormattedDate)'/>"))

            try receive("push", manager: manager, fixture: f, wire: control)

            XCTAssertEqual(try preview(f, id: "previous-id").text, "previous preview")
            XCTAssertNil(LastChatListSyncPreviewStore.shared.projection(owner: f.receiver.owner, conversationPrimary: primary(f), expectedLastMessageID: "control-id"))
            XCTAssertTrue(try WRealm.safe().objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).isEmpty)
        }
    }

    func testActualDuplicateEditedPushKeepsVerifiedPreviewWithoutNewBubble() throws {
        let f = try fixture()
        let wire = try editedWire(f)
        try withSync(f) { manager in
            try receive("push", manager: manager, fixture: f, wire: wire)
            let before = try preview(f, id: "edited-id")
            XCTAssertEqual(before.text, "verified sync edit")

            try receive("push", manager: manager, fixture: f, wire: wire)

            XCTAssertEqual(try preview(f, id: "edited-id"), before)
            XCTAssertTrue(try WRealm.safe().objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).isEmpty)
        }
    }

    private func fixture() throws -> Fixture {
        let sender = OmemoManager(withOwner: "sync-sender-\(UUID().uuidString.lowercased())@example.test")
        let receiver = OmemoManager(withOwner: "sync-receiver-\(UUID().uuidString.lowercased())@example.test")
        owners += [sender.owner, receiver.owner]
        let memory = Memory()
        let senderStorage = try XabberOMEMO2Storage(owner: sender.owner, persistence: memory)
        let receiverStorage = try XabberOMEMO2Storage(owner: receiver.owner, persistence: memory)
        _ = try senderStorage.prepare(deviceID: 41, preKeyCount: 3)
        let bundle = try receiverStorage.prepare(deviceID: 42, preKeyCount: 3)
        let prekey = try XCTUnwrap(bundle.preKeys.first)
        try senderStorage.initiateSession(jid: receiver.owner, deviceID: 42, bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey, signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: prekey.publicKey, preKeyID: prekey.id))
        sender.omemo2Storage = senderStorage; receiver.omemo2Storage = receiverStorage
        _ = try sender.ensureOMEMO2Prepared(); _ = try receiver.ensureOMEMO2Prepared()
        let realm = try WRealm.safe()
        let trusted = SignalDeviceStorageItem()
        trusted.primary = SignalDeviceStorageItem.genPrimary(owner: sender.owner, jid: receiver.owner, deviceId: 42)
        trusted.owner = sender.owner; trusted.jid = receiver.owner; trusted.deviceId = 42; trusted.state = .trusted
        trusted.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        try realm.write { realm.add(trusted, update: .modified) }
        for (manager, jid, id) in [(sender, sender.owner, 41), (sender, receiver.owner, 42), (receiver, receiver.owner, 42), (receiver, sender.owner, 41)] {
            let headline = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(jid)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='\(id)'/></devices></item></items></event></message>")
            XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(headline))
        }
        return Fixture(sender: sender, receiver: receiver, memory: memory)
    }

    private func editedWire(_ f: Fixture) throws -> XMPPMessage {
        // A deterministic historical ciphertext fixture bypasses the outgoing
        // writer's wall-clock refresh, but uses the real payload and ratchet crypto.
        let envelope = try DDXMLElement(xmlString: "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>verified sync edit</body></content><from jid='\(f.sender.owner)'/><to jid='\(f.receiver.owner)'/><time stamp='\(replacementDate.XMPPFormattedDate)'/><rpad/></envelope>")
        try Omemo2PayloadCodec.applyPadding(to: envelope)
        let sealed = try Omemo2PayloadCodec.seal(envelope.xmlString)
        let encrypted = DDXMLElement(name: "encrypted", xmlns: OmemoManager.xmlns)
        let header = DDXMLElement(name: "header", xmlns: OmemoManager.xmlns)
        header.addAttribute(withName: "sid", integerValue: 41)
        let keys = DDXMLElement(name: "keys", xmlns: OmemoManager.xmlns)
        keys.addAttribute(withName: "jid", stringValue: f.receiver.owner)
        keys.addChild(try f.sender.doubleRatchet(hmac: sealed.keyAndMAC, jid: f.receiver.owner, deviceId: 42))
        header.addChild(keys); encrypted.addChild(header)
        let payload = DDXMLElement(name: "payload", xmlns: OmemoManager.xmlns)
        payload.stringValue = sealed.ciphertext.base64EncodedString()
        encrypted.addChild(payload)
        let wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.sender.owner)/phone' to='\(f.receiver.owner)/tablet' type='chat' id='edited-id'><body>forged outer preview</body><reference xmlns='https://xabber.com/protocol/references' type='mutable'><file-sharing xmlns='https://xabber.com/protocol/files'/></reference><time xmlns='\(deliveryNamespace)' stamp='\(replacementDate.addingTimeInterval(-3600).XMPPFormattedDate)'/><r:replaced xmlns:r='\(MessageDeleteManager.namespace)' stamp='\(replacementDate.XMPPFormattedDate)'/><stanza-id xmlns='urn:xmpp:sid:0' by='\(f.receiver.owner)' id='archive-original'/><omemo-result__system result='true'/></message>")
        wire.addChild(encrypted)
        return wire
    }
    private func conversation(_ f: Fixture, wire: XMPPMessage) throws -> DDXMLElement {
        try DDXMLElement(xmlString: "<conversation xmlns='\(syncNamespace)' jid='\(f.sender.owner)' type='urn:xmpp:omemo:2' stamp='1770000000000000' status='active'><metadata node='\(syncNamespace)'><unread count='0'/><last-message>\(wire.xmlString)</last-message></metadata></conversation>")
    }
    private func withSync(_ f: Fixture, body: (ClientSynchronizationManager) throws -> Void) throws {
        let account = Account(jid: f.receiver.owner, queue: DispatchQueue(label: "EditedSync-account-\(UUID())"))
        account.omemo = f.receiver
        let previous = AccountManager.shared.users
        AccountManager.shared.users = previous + [account]
        let manager = ClientSynchronizationManager(withOwner: f.receiver.owner)
        manager.isAvailable = true
        defer {
            manager.waitForPendingSnapshotApplies(); manager.reset()
            AccountManager.shared.users = previous
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }
        try body(manager)
    }
    private func receive(_ route: String, manager: ClientSynchronizationManager, fixture f: Fixture, wire: XMPPMessage, from: String? = "owned", to: String? = "owned") throws {
        var id = "push-\(UUID())"
        if route == "snapshot" {
            var request: ClientSynchronizationManager.SyncRequestDiagnostics?
            manager.syncRequestObserver = { request = $0 }
            XCTAssertTrue(manager.sync(Stream()))
            id = try XCTUnwrap(request).id
        }
        let actualFrom = from == "owned" ? f.receiver.owner : from
        let actualTo = to == "owned" ? f.receiver.owner + "/tablet" : to
        let fromXML = actualFrom.map { " from='\($0)'" } ?? ""
        let toXML = actualTo.map { " to='\($0)'" } ?? ""
        let iq = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='\(route == "snapshot" ? "result" : "set")' id='\(id)'\(fromXML)\(toXML)><query xmlns='\(syncNamespace)' stamp='1770000000000000'>\(try conversation(f, wire: wire).xmlString)</query></iq>")
        XCTAssertTrue(manager.read(withIQ: iq))
        if route == "snapshot" {
            manager.waitForPendingSnapshotApplies()
            // Snapshot commits on its apply queue; refresh the observing Realm
            // before asserting the persisted list metadata on the test thread.
            try WRealm.safe().refresh()
        }
    }
    private func primary(_ f: Fixture) -> String {
        LastChatsStorageItem.genPrimary(jid: f.sender.owner, owner: f.receiver.owner, conversationType: .omemo)
    }
    private func preview(_ f: Fixture, id: String) throws -> LastChatListSyncPreviewProjection {
        try XCTUnwrap(LastChatListSyncPreviewStore.shared.projection(owner: f.receiver.owner, conversationPrimary: primary(f), expectedLastMessageID: id))
    }
    private func lastMessage(_ value: ClientSyncConversationValue) throws -> XMPPMessage {
        let conversation = try XCTUnwrap(value.materializedElement())
        let metadata = try XCTUnwrap(conversation.element(forName: "metadata"))
        let last = try XCTUnwrap(metadata.element(forName: "last-message"))
        return XMPPMessage(from: try XCTUnwrap(SCEReceivePolicy.children(of: last, named: "message", xmlns: "jabber:client").first))
    }
}
