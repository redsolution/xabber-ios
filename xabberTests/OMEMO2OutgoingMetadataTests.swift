import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// OM2-02 is deliberately limited to EME. Fallback bodies and existing hints
/// remain part of the current product contract.
final class OMEMO2OutgoingMetadataTests: XCTestCase {
    private let eme = "urn:xmpp:eme:0"
    private let profiles = ["urn:xmpp:omemo:2", "urn:xmpp:omemo:1", "eu.siacs.conversations.axolotl"]
    private var previousRealm: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "OutgoingMetadata-\(UUID().uuidString)")
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testEMENamespaceComesFromEachActualCipherProfileWithoutDisplayName() throws {
        for profile in profiles {
            let message = try stanza("<encrypted xmlns='\(profile)'><payload>ciphertext</payload></encrypted>")

            OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

            let encryption = try XCTUnwrap(metadata(message).first, profile)
            XCTAssertEqual(metadata(message).count, 1, profile)
            XCTAssertEqual(encryption.attributeStringValue(forName: "namespace"), profile)
            XCTAssertNil(encryption.attribute(forName: "name"), profile)
        }
    }

    func testStaleDuplicateMetadataIsReplacedByOneActualProfileAndIsIdempotent() throws {
        let message = try stanza("""
        <encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:1' name='OMEMO 1'/>
        <m:encryption xmlns:m='urn:xmpp:eme:0' namespace='eu.siacs.conversations.axolotl'/>
        <encrypted xmlns='urn:xmpp:omemo:2'><payload>ciphertext</payload></encrypted>
        """)

        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)
        let once = message.xmlString
        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

        XCTAssertEqual(metadata(message).count, 1)
        XCTAssertEqual(metadata(message).first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
        XCTAssertNil(metadata(message).first?.attribute(forName: "name"))
        XCTAssertEqual(message.xmlString, once)
    }

    func testPrefixedCipherAndMetadataUseExpandedQName() throws {
        let message = try stanza("""
        <e:encrypted xmlns:e='urn:xmpp:omemo:2'><e:payload>prefixed-ciphertext</e:payload></e:encrypted>
        <m:encryption xmlns:m='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:1' name='wrong'/>
        """)
        let before = try XCTUnwrap(SCEReceivePolicy.children(of: message, named: "encrypted", xmlns: "urn:xmpp:omemo:2").first).xmlString

        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

        XCTAssertEqual(metadata(message).count, 1)
        XCTAssertEqual(metadata(message).first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
        XCTAssertEqual(SCEReceivePolicy.children(of: message, named: "encrypted", xmlns: "urn:xmpp:omemo:2").first?.xmlString, before)
    }

    func testForeignNameMetadataAndNestedMetadataArePreserved() throws {
        let message = try stanza("""
        <encrypted xmlns='urn:xmpp:omemo:2'><payload>ciphertext</payload></encrypted>
        <encryption xmlns='urn:foreign' namespace='foreign' name='keep'/>
        <payload xmlns='urn:example:extension'><encryption xmlns='urn:xmpp:eme:0' namespace='nested' name='keep'/></payload>
        """)
        let foreign = try XCTUnwrap(message.element(forName: "encryption", xmlns: "urn:foreign")).xmlString
        let nested = try XCTUnwrap(message.element(forName: "payload", xmlns: "urn:example:extension")).xmlString

        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

        XCTAssertEqual(metadata(message).count, 1)
        XCTAssertEqual(message.element(forName: "encryption", xmlns: "urn:foreign")?.xmlString, foreign)
        XCTAssertEqual(message.element(forName: "payload", xmlns: "urn:example:extension")?.xmlString, nested)
    }

    func testPlaintextMarkerDoesNotAcquireEncryptionMetadata() throws {
        let message = try stanza("""
        <displayed xmlns='urn:xmpp:chat-markers:0' id='read-id'/>
        <conversation xmlns='https://xabber.com/protocol/synchronization' type='urn:xmpp:omemo:2' jid='bob@example.test'/>
        <store xmlns='urn:xmpp:hints'/>
        """)
        let before = message.xmlString

        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

        XCTAssertTrue(metadata(message).isEmpty)
        XCTAssertEqual(message.xmlString, before)
    }

    func testNestedCipherCannotAdvertiseEncryptionOfOuterStanza() throws {
        let message = try stanza("""
        <body>ordinary forwarded message</body>
        <forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client'>
          <encrypted xmlns='urn:xmpp:omemo:2'><payload>inner</payload></encrypted>
        </message></forwarded>
        """)
        let before = message.xmlString

        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

        XCTAssertTrue(metadata(message).isEmpty)
        XCTAssertEqual(message.xmlString, before)
    }

    func testUnknownCipherAndOtherEncryptionSchemesAreUntouched() throws {
        for content in [
            "<encrypted xmlns='urn:foreign'><payload>foreign</payload></encrypted>",
            "<openpgp xmlns='urn:xmpp:openpgp:0'>encrypted</openpgp><encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:openpgp:0'/>"
        ] {
            let message = try stanza(content)
            let before = message.xmlString

            OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

            XCTAssertEqual(message.xmlString, before)
        }
    }

    func testAmbiguousDirectCipherProfilesAreNotGuessed() throws {
        for second in ["urn:xmpp:omemo:2", "urn:xmpp:omemo:1"] {
            let message = try stanza("""
            <encrypted xmlns='urn:xmpp:omemo:2'><payload>first</payload></encrypted>
            <encrypted xmlns='\(second)'><payload>second</payload></encrypted>
            <encryption xmlns='urn:xmpp:eme:0' namespace='existing'/>
            """)
            let before = message.xmlString

            OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

            XCTAssertEqual(message.xmlString, before)
        }
    }

    func testNormalizationPreservesFallbackHintsRoutingAndCiphertextExactly() throws {
        for hint in ["", "<store xmlns='urn:xmpp:hints'/>", "<no-store xmlns='urn:xmpp:hints'/>"] {
            let message = try stanza("""
            <body>Message was encrypted by OMEMO</body>
            \(hint)
            <origin-id xmlns='urn:xmpp:sid:0' id='origin-id'/>
            <conversation xmlns='https://xabber.com/protocol/synchronization' type='eu.siacs.conversations.axolotl' jid='bob@example.test'/>
            <encrypted xmlns='urn:xmpp:omemo:2'><header sid='41'><keys jid='bob@example.test'><key rid='42' kex='true'>QUJDRA==</key></keys></header><payload>AAECAwQ=</payload></encrypted>
            <encryption xmlns='urn:xmpp:eme:0' namespace='eu.siacs.conversations.axolotl' name='old'/>
            """)
            let protectedChildren = childrenExceptEME(message)
            let attributes = message.attributes?.map(\.xmlString)

            OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

            XCTAssertEqual(childrenExceptEME(message), protectedChildren)
            XCTAssertEqual(message.attributes?.map(\.xmlString), attributes)
            XCTAssertEqual(message.body, "Message was encrypted by OMEMO")
            XCTAssertEqual(SCEReceivePolicy.children(of: message, named: "store", xmlns: "urn:xmpp:hints").count, hint.contains("<store") ? 1 : 0)
        }
    }

    func testRealProviderCiphertextRemainsDecryptableAndNormalizationDoesNotAdvanceRatchet() throws {
        let f = try fixture()
        let message = try stanza("<body>Message was encrypted by OMEMO</body>")
        message.addAttribute(withName: "from", stringValue: f.alice.owner)
        message.addAttribute(withName: "to", stringValue: f.bob.owner)
        message.addChild(try XCTUnwrap(f.alice.encryptMessage(message: envelope(f, body: "secret"), to: f.bob.owner)))
        let cipher = try XCTUnwrap(message.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2")).xmlString
        let before = f.memory.records[f.alice.owner]

        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)

        XCTAssertEqual(f.memory.records[f.alice.owner], before)
        XCTAssertEqual(message.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2")?.xmlString, cipher)
        XCTAssertEqual(metadata(message).first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
        XCTAssertNil(metadata(message).first?.attribute(forName: "name"))
        XCTAssertNil(message.element(forName: "store", xmlns: "urn:xmpp:hints"))
        guard case let .verified(clean, _, _) = f.bob.prepareIncoming(message) else { return XCTFail("Expected authentic provider payload") }
        XCTAssertEqual(clean.body, "secret")
    }

    func testActualControlCarriesCurrentProfileWithoutBodyAndKeepsExistingStoreHint() throws {
        let f = try fixture()

        let control = try f.alice.makeOMEMO2Control(jid: f.bob.owner, deviceID: 42)

        XCTAssertEqual(metadata(control).count, 1)
        XCTAssertEqual(metadata(control).first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
        XCTAssertNil(metadata(control).first?.attribute(forName: "name"))
        XCTAssertNil(control.element(forName: "body"))
        XCTAssertEqual(SCEReceivePolicy.children(of: control, named: "store", xmlns: "urn:xmpp:hints").count, 1)
        XCTAssertNil(control.element(forName: "encrypted")?.element(forName: "payload"))
        control.addAttribute(withName: "from", stringValue: f.alice.owner)
        guard case .consumed(.control) = f.bob.prepareIncoming(control) else { return XCTFail("Expected genuine bodyless ratchet control") }
    }

    func testActualDisplayedMarkerForEncryptedConversationMakesNoEMEClaimAndPreservesStore() throws {
        for type in [ClientSynchronizationManager.ConversationType.omemo, .omemo1, .axolotl] {
            let item = MessageStorageItem()
            item.owner = "alice@example.test"
            item.opponent = "bob@example.test"
            item.messageId = UUID().uuidString
            item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: item.owner)
            item.conversationType = type
            item.outgoing = false
            let realm = try WRealm.safe()
            try realm.write { realm.add(item) }
            let stream = CapturingStream()
            let markers = ChatMarkersManager(withOwner: item.owner, withoutAfterburnTimer: true)

            markers.displayed(stream, message: item.primary)

            let marker = try XCTUnwrap(stream.messages.first)
            XCTAssertTrue(metadata(marker).isEmpty, type.rawValue)
            XCTAssertNil(marker.element(forName: "encrypted"), type.rawValue)
            XCTAssertEqual(marker.element(forName: "displayed")?.attributeStringValue(forName: "id"), item.messageId)
            XCTAssertEqual(marker.element(forName: "conversation")?.attributeStringValue(forName: "type"), type.rawValue)
            XCTAssertEqual(SCEReceivePolicy.children(of: marker, named: "store", xmlns: "urn:xmpp:hints").count, 1)
            XCTAssertEqual(marker.to?.bare, item.opponent)
        }
    }

    func testProductionSenderUsesActualProviderProfileForAllEncryptedConversationKindsAfterHooks() throws {
        let scenarios = [ClientSynchronizationManager.ConversationType.omemo, .omemo1, .axolotl].flatMap { type in
            [false, true].map { (type, $0) }
        }
        for (type, retry) in scenarios {
            let f = try fixture()
            let account = Account(jid: f.alice.owner, queue: DispatchQueue(label: "OutgoingMetadata-account-\(UUID().uuidString)"))
            account.omemo = f.alice
            account.chatMarkers = ChatMarkersManager(withOwner: f.alice.owner, withoutAfterburnTimer: true)
            account.sendReadiness.onReadinessChanged = nil
            account.sendReadiness.markStreamManagementEnabled()
            let stream = CapturingStream()
            account.xmppStream = stream
            let oldUsers = AccountManager.shared.users
            AccountManager.shared.users = oldUsers + [account]
            defer {
                AccountManager.shared.users = oldUsers
                account.messages.updateSendingMessagesTimer?.invalidate()
                account.messages.updateSendingMessagesTimer = nil
            }
            let item = MessageStorageItem()
            item.owner = f.alice.owner
            item.opponent = f.bob.owner
            item.messageId = UUID().uuidString
            item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: item.owner)
            item.conversationType = type
            item.body = "secret"
            item.legacyBody = "secret"
            item.outgoing = true
            item.date = Date()
            item.sentDate = item.date
            let realm = try WRealm.safe()
            try realm.write { realm.add(item) }
            let sent = expectation(description: "wire stanza for \(type.rawValue), retry=\(retry)")
            stream.onMessage = { _ in sent.fulfill() }
            let stale = try DDXMLElement(xmlString: "<e:encryption xmlns:e='urn:xmpp:eme:0' namespace='eu.siacs.conversations.axolotl' name='old'/>")

            account.messages.processSender(item: item.primary, retry: retry, childs: [stale])
            wait(for: [sent], timeout: 3)

            let message = try XCTUnwrap(stream.messages.first)
            XCTAssertEqual(metadata(message).count, 1, type.rawValue)
            XCTAssertEqual(metadata(message).first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2", type.rawValue)
            XCTAssertNil(metadata(message).first?.attribute(forName: "name"), type.rawValue)
            XCTAssertEqual(message.element(forName: "encrypted")?.uri, "urn:xmpp:omemo:2")
            XCTAssertNotNil(message.body, "Existing fallback remains on the wire")
            XCTAssertNotEqual(message.body, "secret")
            XCTAssertNil(message.element(forName: "store", xmlns: "urn:xmpp:hints"), "This task must not add storage hints")
            XCTAssertEqual(getOriginId(message), item.messageId)
            XCTAssertEqual(message.elementID, item.messageId)
            XCTAssertEqual(message.from?.bare, item.owner)
            XCTAssertEqual(message.to?.bare, item.opponent)
            XCTAssertNotNil(message.element(forName: "markable"), "Final hook decoration is preserved")
            XCTAssertEqual(SCEReceivePolicy.children(of: message, named: "retry", xmlns: "https://xabber.com/protocol/delivery").count, retry ? 1 : 0)
            guard case let .verified(clean, _, _) = f.bob.prepareIncoming(message) else { return XCTFail("Expected valid final wire payload") }
            XCTAssertEqual(clean.body, "secret")
        }
    }

    func testTrustSharingShapedProviderMessageKeepsProfileAndCiphertextInsideXENWrapper() throws {
        let f = try fixture()
        let share = DDXMLElement(name: "share", xmlns: TrustSharingSignature.xmlns)
        let payload = try XCTUnwrap(f.alice.prepareStanzaContent(
            message: "", date: Date(), jid: f.bob.owner, additionalContent: [share], ignoreTimeSignature: true
        ))
        let message = try stanza("<body>Message was encrypted by OMEMO</body>")
        message.addAttribute(withName: "from", stringValue: f.alice.owner)
        message.addAttribute(withName: "to", stringValue: f.bob.owner)
        message.addOriginId("trust-origin")
        message.addChild(try XCTUnwrap(f.alice.encryptMessage(message: payload, to: f.bob.owner)))
        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)
        let before = message.xmlString
        let notifications = XMPPNotificationsManager(withOwner: f.alice.owner)

        let packet = notifications.formIQ(to: try XCTUnwrap(XMPPJID(string: f.bob.owner)), child: message)

        XCTAssertTrue(packet is XMPPIQ)
        XCTAssertTrue(SCEReceivePolicy.children(of: packet, named: "encryption", xmlns: eme).isEmpty)
        let notify = try XCTUnwrap(packet.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns))
        let notification = try XCTUnwrap(notify.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns))
        let forwarded = try XCTUnwrap(notification.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"))
        let inner = XMPPMessage(from: try XCTUnwrap(forwarded.element(forName: "message", xmlns: "jabber:client")))
        XCTAssertEqual(inner.xmlString, before)
        XCTAssertEqual(metadata(inner).count, 1)
        XCTAssertEqual(metadata(inner).first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
        XCTAssertNil(metadata(inner).first?.attribute(forName: "name"))
        XCTAssertNil(inner.element(forName: "store", xmlns: "urn:xmpp:hints"))
        XCTAssertEqual(getOriginId(inner), "trust-origin")
        guard case let .verified(clean, _, _) = f.bob.prepareIncoming(inner) else { return XCTFail("Expected unchanged authentic trust-shaped payload") }
        XCTAssertNotNil(clean.element(forName: "share", xmlns: TrustSharingSignature.xmlns))
    }

    private func stanza(_ content: String) throws -> XMPPMessage {
        XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='alice@example.test' to='bob@example.test' type='chat' id='wire-id'>\(content)</message>"))
    }

    private func metadata(_ message: XMPPMessage) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: message, named: "encryption", xmlns: eme)
    }

    private func childrenExceptEME(_ message: XMPPMessage) -> [String] {
        (message.children ?? []).compactMap { child in
            guard let element = child as? DDXMLElement else { return child.xmlString }
            return SCEReceivePolicy.matches(element, name: "encryption", namespace: eme) ? nil : element.xmlString
        }
    }

    private final class CapturingStream: XMPPStream {
        var messages: [XMPPMessage] = []
        var onMessage: ((XMPPMessage) -> Void)?
        override func send(_ element: DDXMLElement) {
            guard let message = element as? XMPPMessage else { return }
            let copy = message.copy() as! XMPPMessage
            messages.append(copy)
            onMessage?(copy)
        }
    }

    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private struct Fixture {
        let alice: OmemoManager
        let bob: OmemoManager
        let memory: Memory
    }

    private func fixture() throws -> Fixture {
        let memory = Memory()
        let alice = OmemoManager(withOwner: "alice-\(UUID().uuidString.lowercased())@example.test")
        let bob = OmemoManager(withOwner: "bob-\(UUID().uuidString.lowercased())@example.test")
        let aliceStore = try XabberOMEMO2Storage(owner: alice.owner, persistence: memory)
        let bobStore = try XabberOMEMO2Storage(owner: bob.owner, persistence: memory)
        _ = try aliceStore.prepare(deviceID: 41, preKeyCount: 3)
        let bobBundle = try bobStore.prepare(deviceID: 42, preKeyCount: 3)
        let preKey = try XCTUnwrap(bobBundle.preKeys.first)
        try aliceStore.initiateSession(jid: bob.owner, deviceID: 42, bundle: OMEMO2Bundle(
            identityKey: bobBundle.identityKey, signedPreKey: bobBundle.signedPreKey,
            signedPreKeyID: bobBundle.signedPreKeyID, signature: bobBundle.signature,
            preKey: preKey.publicKey, preKeyID: preKey.id
        ))
        alice.omemo2Storage = aliceStore
        bob.omemo2Storage = bobStore
        try alice.ensureOMEMO2Prepared()
        try bob.ensureOMEMO2Prepared()
        let device = SignalDeviceStorageItem()
        device.owner = alice.owner
        device.jid = bob.owner
        device.deviceId = 42
        device.primary = SignalDeviceStorageItem.genPrimary(owner: alice.owner, jid: bob.owner, deviceId: 42)
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bobBundle.identityKey)
        device.state = .trusted
        let realm = try WRealm.safe()
        try realm.write { realm.add(device, update: .modified) }
        try advertiseDevices(to: alice, jid: alice.owner, ids: [41])
        try advertiseDevices(to: alice, jid: bob.owner, ids: [42])
        try advertiseDevices(to: bob, jid: bob.owner, ids: [42])
        try advertiseDevices(to: bob, jid: alice.owner, ids: [41])
        return Fixture(alice: alice, bob: bob, memory: memory)
    }

    private func advertiseDevices(to manager: OmemoManager, jid: String, ids: [Int]) throws {
        let devices = ids.map { "<device id='\($0)'/>" }.joined()
        let headline = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(jid)' type='headline'>
          <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='urn:xmpp:omemo:2:devices'><item id='current'>
              <devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices>
            </item></items>
          </event>
        </message>
        """)
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(headline))
    }

    private func envelope(_ fixture: Fixture, body: String) -> String {
        "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>\(body)</body></content><rpad>fixture padding</rpad><from jid='\(fixture.alice.owner)'/><to jid='\(fixture.bob.owner)'/></envelope>"
    }
}
