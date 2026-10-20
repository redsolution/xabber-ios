import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

final class OMEMO2NormativeRewriteAuthorityTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private struct Fixture {
        let sender: OmemoManager
        let receiver: OmemoManager
    }
    private var previousConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "RewriteAuthority-\(UUID())")
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    func testAuthenticatedPeerWrapperCannotRewriteAnUnrelatedConversation() throws {
        let f = try fixture()
        let item = try storedMessage(owner: f.receiver.owner, jid: "unrelated@example.test")
        let packet = try packet(f, item: item, outerFrom: f.sender.owner, outerTo: f.receiver.owner)

        assertRejectedMutation(packet, fixture: f, item: item)
    }

    func testOwnerWrapperAddressedElsewhereCannotRewriteLocalHistory() throws {
        let f = try fixture()
        let item = try storedMessage(owner: f.receiver.owner, jid: f.sender.owner)
        let packet = try packet(f, item: item, outerFrom: f.receiver.owner, outerTo: "elsewhere@example.test")

        assertRejectedMutation(packet, fixture: f, item: item)
    }

    func testTrustedOwnerWrapperPreservesProtectedLegacyReplacementMarkerPriority() throws {
        let f = try fixture()
        let item = try storedMessage(owner: f.receiver.owner, jid: f.sender.owner)
        let protectedDate = Date().addingTimeInterval(-20)
        let protectedStamp = protectedDate.XMPPFormattedDate
        let packet = try packet(f, item: item, outerFrom: f.receiver.owner, outerTo: f.receiver.owner,
                                protectedStamp: protectedStamp, externalStamp: Date().XMPPFormattedDate)
        guard case let .verified(clean, proof, _) = f.receiver.prepareIncoming(packet) else {
            return XCTFail("Expected an authenticated replacement under the owning server wrapper")
        }
        let rewrite = MessageDeleteManager(withOwner: f.receiver.owner)

        XCTAssertTrue(rewrite.readRewriteNotify(clean, encryption: proof))

        XCTAssertEqual(item.body, "authenticated correction")
        XCTAssertEqual(item.editDate, protectedStamp.xmppDate)
        XCTAssertEqual(rewrite.version, "replacement-version")
    }

    private func assertRejectedMutation(_ packet: XMPPMessage, fixture: Fixture, item: MessageStorageItem,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard case let .verified(clean, proof, _) = fixture.receiver.prepareIncoming(packet) else {
            return XCTFail("The peer ciphertext is authentic; transport authority is a separate check", file: file, line: line)
        }
        let rewrite = MessageDeleteManager(withOwner: fixture.receiver.owner)
        let beforeVersion = rewrite.version

        XCTAssertTrue(rewrite.readRewriteNotify(clean, encryption: proof), file: file, line: line)

        XCTAssertEqual(item.body, "original history", file: file, line: line)
        XCTAssertNil(item.editDate, file: file, line: line)
        XCTAssertEqual(rewrite.version, beforeVersion, file: file, line: line)
    }

    private func storedMessage(owner: String, jid: String) throws -> MessageStorageItem {
        let item = MessageStorageItem()
        item.owner = owner; item.opponent = jid
        item.messageId = "victim-\(UUID())"
        item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: owner)
        item.archivedId = "victim-archive"
        item.conversationType = .omemo
        item.body = "original history"; item.legacyBody = item.body
        let realm = try WRealm.safe()
        try realm.write { realm.add(item) }
        return item
    }

    private func packet(_ f: Fixture, item: MessageStorageItem, outerFrom: String, outerTo: String,
                        protectedStamp: String = Date().XMPPFormattedDate, externalStamp: String? = nil) throws -> XMPPMessage {
        let marker = try DDXMLElement(xmlString: "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(protectedStamp)'/>")
        let payload = try XCTUnwrap(f.sender.prepareStanzaContent(message: "authenticated correction", date: Date(),
            jid: f.receiver.owner, additionalContent: [marker], ignoreTimeSignature: true))
        let encrypted = try XCTUnwrap(f.sender.encryptMessage(message: payload, to: f.receiver.owner))
        let leaf = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.sender.owner)' to='\(f.receiver.owner)' type='chat' id='peer-ciphertext'/>")
        leaf.addChild(encrypted)
        // This generated incoming copy includes the receiving account clock;
        // wrapper authority and protected rewrite markers are asserted separately.
        leaf.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' by='\(f.receiver.owner)' stamp='\(Date().XMPPFormattedDate)'/>"))
        if let externalStamp {
            leaf.addChild(try DDXMLElement(xmlString: "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(externalStamp)'/>"))
        }
        return try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(outerFrom)' to='\(outerTo)' type='headline'>
          <replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(item.opponent)'
                   type='urn:xmpp:omemo:2' id='\(item.archivedId)' version='replacement-version'>
            \(leaf.xmlString)
          </replace>
        </message>
        """)
    }

    private func fixture() throws -> Fixture {
        let memory = Memory()
        let sender = OmemoManager(withOwner: "authority-sender-\(UUID().uuidString.lowercased())@example.test")
        let receiver = OmemoManager(withOwner: "authority-receiver-\(UUID().uuidString.lowercased())@example.test")
        let senderStore = try XabberOMEMO2Storage(owner: sender.owner, persistence: memory)
        let receiverStore = try XabberOMEMO2Storage(owner: receiver.owner, persistence: memory)
        _ = try senderStore.prepare(deviceID: 41, preKeyCount: 3)
        let bundle = try receiverStore.prepare(deviceID: 42, preKeyCount: 3)
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        try senderStore.initiateSession(jid: receiver.owner, deviceID: 42,
            bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                preKey: preKey.publicKey, preKeyID: preKey.id))
        sender.omemo2Storage = senderStore; receiver.omemo2Storage = receiverStore
        _ = try sender.ensureOMEMO2Prepared(); _ = try receiver.ensureOMEMO2Prepared()
        let device = SignalDeviceStorageItem()
        device.primary = SignalDeviceStorageItem.genPrimary(owner: sender.owner, jid: receiver.owner, deviceId: 42)
        device.owner = sender.owner; device.jid = receiver.owner; device.deviceId = 42
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        device.state = .trusted
        let realm = try WRealm.safe()
        try realm.write { realm.add(device, update: .modified) }
        for (manager, jid, id) in [(sender, sender.owner, 41), (sender, receiver.owner, 42),
                                  (receiver, receiver.owner, 42), (receiver, sender.owner, 41)] {
            let headline = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' from='\(jid)' to='\(manager.owner)' type='headline'>
              <event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'>
                <item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='\(id)'/></devices></item>
              </items></event>
            </message>
            """)
            XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(headline))
        }
        return Fixture(sender: sender, receiver: receiver)
    }
}
