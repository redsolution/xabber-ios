import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

final class OMEMO2SCEReceiveTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private var oldRealm: Realm.Configuration!
    override func setUp() {
        super.setUp()
        oldRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: UUID().uuidString)
    }
    override func tearDown() {
        Realm.Configuration.defaultConfiguration = oldRealm
        super.tearDown()
    }

    func testAuthenticatedContentReplacesEveryExternalSensitiveExtension() throws {
        let f = try fixture()
        let message = try packet(f, content: "<body xmlns='jabber:client'>verified</body><ephemeral xmlns='urn:xmpp:ephemeral:0' timer='17'/>")
        addInjection(message)
        guard case let .verified(clean, proof) = f.bob.prepareIncoming(message) else { return XCTFail("Expected authenticated content") }
        XCTAssertTrue(proof.isAuthenticated)
        XCTAssertEqual(clean.body, "verified")
        XCTAssertEqual(clean.elements(forName: "ephemeral").count, 1)
        XCTAssertEqual(clean.element(forName: "ephemeral")?.attributeStringValue(forName: "timer"), "17")
        for name in ["reference", "displayed", "time-signature", "omemo-result__system", "envelope"] {
            XCTAssertNil(clean.element(forName: name), name)
        }
        XCTAssertNotNil(clean.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2"))
        XCTAssertEqual(message.body, "injected", "Receive preparation must not mutate the wire input")
    }

    func testActualAttachmentOnlyCiphertextKeepsOnlyVerifiedMediaInSyncAndLocalPreview() throws {
        let f = try fixture()
        let message = try packet(f, content: """
        <r:reference xmlns:r='https://xabber.com/protocol/references' type='mutable'>
          <f:file-sharing xmlns:f='https://xabber.com/protocol/files'>
            <f:file><f:media-type>image/jpeg</f:media-type><f:name>verified.jpg</f:name></f:file>
            <f:sources><f:uri>https://example.test/verified.jpg</f:uri></f:sources>
          </f:file-sharing>
        </r:reference>
        """)
        addInjection(message)
        let conversation = try DDXMLElement(xmlString: """
        <conversation xmlns='https://xabber.com/protocol/synchronization' jid='\(f.alice.owner)' type='urn:xmpp:omemo:2'>
          <metadata node='https://xabber.com/protocol/synchronization'><last-message>\(message.xmlString)</last-message></metadata>
        </conversation>
        """)

        let prepared = f.bob.prepareSyncConversation(conversation)
        XCTAssertEqual(prepared.lastMessageEncryption, .authenticatedSCE(profile: .omemo2))
        XCTAssertFalse(prepared.lastMessageWasConsumed)
        let cleanConversation = try XCTUnwrap(prepared.materializedElement())
        let clean = try XCTUnwrap(cleanConversation.element(forName: "metadata")?.element(forName: "last-message")?.element(forName: "message"))
        XCTAssertNil(clean.element(forName: "body"))
        let references = SCEReceivePolicy.children(of: clean, named: "reference", xmlns: "https://xabber.com/protocol/references")
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.attributeStringValue(forName: "type"), "mutable")
        let sharing = try XCTUnwrap(references.first?.element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files"))
        XCTAssertEqual(sharing.element(forName: "file")?.element(forName: "name")?.stringValue, "verified.jpg")
        XCTAssertEqual(sharing.element(forName: "sources")?.element(forName: "uri")?.stringValue, "https://example.test/verified.jpg")
        XCTAssertNil(clean.element(forName: "omemo-result__system"))

        let syncPreview = try XCTUnwrap(LastChatListSyncPreviewParser.projection(
            owner: f.bob.owner, conversationPrimary: "verified-attachment", lastMessageID: "message-id",
            messageElement: clean, encryption: prepared.lastMessageEncryption
        ))
        XCTAssertTrue(syncPreview.isAttachment)
        XCTAssertNotEqual(syncPreview.text, "injected")
        let localPreview = LocalMessageNotificationPreviewFactory.make(
            originalStanzaXML: message.xmlString, owner: f.bob.owner, routeJid: f.alice.owner,
            conversationType: "omemo", archivedId: "archive-id", messageId: "message-id", sentAt: Date(),
            fallbackBody: "injected", senderJid: f.alice.owner, senderNickname: nil, senderUserId: nil,
            encryption: prepared.lastMessageEncryption, verifiedStanza: clean
        )
        XCTAssertEqual(localPreview.body, "Image")
        XCTAssertEqual(localPreview.mediaItems.map(\.url), ["https://example.test/verified.jpg"])
    }

    func testActualLegacySignalHistoryUsesAuthenticatedSCEAndConsumesReplay() throws {
        let f = try legacyFixture()
        for (index, message) in f.messages.enumerated() {
            addInjection(message)
            let key = try XCTUnwrap(message.element(forName: "encrypted")?.element(forName: "header")?.element(forName: "keys")?.element(forName: "key")?.stringValue)
            XCTAssertEqual(try Omemo2PayloadCodec.decodeBase64(key).first, 0x33)
            let archive = XMPPMessage(from: try DDXMLElement(xmlString: """
            <message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'>
              <result xmlns='urn:xmpp:mam:2' id='legacy-archive-\(index)' queryid='legacy-query'>
                <forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2020-01-02T03:04:05Z'/>\(message.xmlString)</forwarded>
              </result>
            </message>
            """))

            guard case let .verified(clean, proof) = f.bob.prepareIncoming(archive, context: .archive) else {
                return XCTFail("Expected actual legacy history to remain readable")
            }
            XCTAssertEqual(proof, .authenticatedSCE(profile: .legacySignal))
            let bare = try XCTUnwrap(getArchivedMessageContainer(clean))
            XCTAssertEqual(bare.body, "legacy history \(index)")
            for name in ["reference", "ephemeral", "displayed", "time-signature", "omemo-result__system", "envelope"] {
                XCTAssertNil(bare.element(forName: name), name)
            }
            XCTAssertEqual(getMAMQueryId(clean), "legacy-query")
            XCTAssertTrue(clean.xmlString.contains("2020-01-02T03:04:05Z"))
            guard case .consumed(.duplicate) = f.bob.prepareIncoming(archive, context: .archive) else {
                return XCTFail("A replay of actual legacy ciphertext must not create an error bubble")
            }
        }
    }

    func testRealMAMAndBothCarbonWrappersKeepTransportMetadata() throws {
        for kind in ["mam", "sent", "received"] {
            let f = try fixture()
            let inner = try packet(f, content: "<body xmlns='jabber:client'>\(kind)</body><origin-id xmlns='urn:xmpp:sid:0' id='authenticated-id'/>")
            addInjection(inner)
            inner.addChild(try DDXMLElement(xmlString: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(f.bob.owner)' id='server-id'/>"))
            let container = kind == "mam" ? "<result xmlns='urn:xmpp:mam:2' id='archive-id' queryid='query-id'>" : "<\(kind) xmlns='urn:xmpp:carbons:2'>"
            let close = kind == "mam" ? "</result>" : "</\(kind)>"
            let wrapper = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'>\(container)<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-09-30T10:00:00Z'/>\(inner.xmlString)</forwarded>\(close)</message>"))
            guard case let .verified(clean, proof) = f.bob.prepareIncoming(wrapper, context: .archive) else { return XCTFail("Expected verified \(kind)") }
            let bare = try XCTUnwrap(kind == "mam" ? getArchivedMessageContainer(clean) : (kind == "sent" ? getCarbonCopyMessageContainer(clean) : getCarbonForwardedMessageContainer(clean)))
            XCTAssertTrue(proof.isAuthenticated)
            XCTAssertEqual(bare.body, kind)
            XCTAssertEqual(bare.from?.bare, f.alice.owner)
            XCTAssertEqual(bare.to?.bare, f.bob.owner)
            XCTAssertEqual(getOriginId(bare), "authenticated-id")
            XCTAssertEqual(getStanzaId(bare, owner: f.bob.owner), "server-id")
            XCTAssertTrue(clean.xmlString.contains("2026-09-30T10:00:00Z"))
            if kind == "mam" { XCTAssertEqual(getMAMQueryId(clean), "query-id") }
            XCTAssertNil(bare.element(forName: "reference"))
        }
    }

    func testPayloadFailureCannotBeOverriddenByWireSuccessOrSignatureAndDoesNotCommit() throws {
        let f = try fixture()
        let message = try packet(f, content: "<body xmlns='jabber:client'>secret</body>")
        addInjection(message)
        let payload = try XCTUnwrap(message.element(forName: "encrypted")?.element(forName: "payload"))
        var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(payload.stringValue)))
        bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()
        let before = f.memory.records[f.bob.owner]
        guard case let .failed(clean, _) = f.bob.prepareIncoming(message) else { return XCTFail("Expected real failure") }
        XCTAssertEqual(f.memory.records[f.bob.owner], before)
        for name in ["body", "reference", "ephemeral", "displayed", "time-signature", "omemo-result__system"] {
            XCTAssertNil(clean.element(forName: name), name)
        }
    }

    func testControlAndReplayHaveDistinctConsumedResults() throws {
        let f = try fixture()
        let control = try packet(f, content: nil)
        guard case .consumed(.control) = f.bob.prepareIncoming(control) else { return XCTFail("Expected control") }
        guard case .consumed(.duplicate) = f.bob.prepareIncoming(control) else { return XCTFail("Expected duplicate") }
    }

    func testAuthenticatedMalformedSCECannotCommitRatchet() throws {
        for xml in [
            "<envelope xmlns='urn:foreign'><content/><rpad>pad</rpad></envelope>",
            "<envelope xmlns='urn:xmpp:sce:1'><content/><content/><rpad>pad</rpad></envelope>",
            "<envelope xmlns='urn:xmpp:sce:1'><content/><rpad>pad</rpad><from jid='attacker@example.test'/></envelope>"
        ] {
            let f = try fixture()
            let message = try packet(f, xml: xml)
            addInjection(message)
            let before = f.memory.records[f.bob.owner]
            guard case let .failed(clean, _) = f.bob.prepareIncoming(message) else { return XCTFail("Expected SCE validation failure") }
            XCTAssertEqual(f.memory.records[f.bob.owner], before)
            XCTAssertNil(clean.element(forName: "body"))
            XCTAssertNil(clean.element(forName: "reference"))
        }
    }

    func testSyncAmbiguousLastMessageCannotMixAuthenticationOrCommitState() throws {
        let f = try fixture()
        let encrypted = try packet(f, content: "<body xmlns='jabber:client'>verified</body>")
        let conversation = try DDXMLElement(xmlString: """
          <conversation xmlns='https://xabber.com/protocol/synchronization' jid='\(f.alice.owner)'>
            <metadata node='https://xabber.com/protocol/synchronization'><last-message>
              \(encrypted.xmlString)
              <message xmlns='jabber:client'><body>injected preview</body></message>
            </last-message></metadata>
          </conversation>
        """)
        let before = f.memory.records[f.bob.owner]
        let prepared = f.bob.prepareSyncConversation(conversation)
        XCTAssertTrue(prepared.lastMessageWasConsumed)
        XCTAssertFalse(prepared.lastMessageEncryption.isAuthenticated)
        XCTAssertEqual(f.memory.records[f.bob.owner], before)
        XCTAssertNil(prepared.materializedElement()?.element(forName: "metadata")?.element(forName: "last-message"))
    }

    func testDirectForwardAndPriorityReconstructBeforeSemanticConsumers() throws {
        for kind in ["forwarded", "priority-message"] {
            let f = try fixture()
            let inner = try packet(f, content: "<body xmlns='jabber:client'>verified</body>")
            addInjection(inner)
            let forwarding = "<forwarded xmlns='urn:xmpp:forward:0'>\(inner.xmlString)</forwarded>"
            let wrapper = kind == "forwarded" ? forwarding : "<priority-message xmlns='https://xabber.com/protocol/priority'>\(forwarding)</priority-message>"
            let wire = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='relay.example.test' to='\(f.bob.owner)'><body>outer injection</body><accept xmlns='urn:xmpp:jingle-message:0' id='injected-call'/>\(wrapper)</message>"))
            guard case let .verified(clean, proof) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected verified \(kind)") }
            let leaf = kind == "forwarded" ? getForwardedMessage(clean) : getPriorityMessageContainer(clean)
            XCTAssertEqual(try XCTUnwrap(leaf).body, "verified")
            XCTAssertTrue(proof.isAuthenticated)
            XCTAssertNil(clean.element(forName: "body"))
            XCTAssertNil(clean.element(forName: "accept"))
            XCTAssertNil(leaf?.element(forName: "reference"))
        }
    }

    func testEncryptedRewriteUsesProtectedContentAndProtectedEditMarker() throws {
        let f = try fixture()
        let inner = try packet(f, content: "<body xmlns='jabber:client'>verified edit</body><replaced xmlns='https://xabber.com/protocol/rewrite' stamp='2026-09-30T10:00:00Z'/>")
        addInjection(inner)
        inner.addChild(try DDXMLElement(xmlString: "<replaced xmlns='https://xabber.com/protocol/rewrite' stamp='2001-01-01T00:00:00Z'/>"))
        let wire = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' type='headline' from='relay.example.test' to='\(f.bob.owner)'><replace xmlns='https://xabber.com/protocol/rewrite#notify' id='server-id' conversation='\(f.alice.owner)' type='omemo' version='7'>\(inner.xmlString)</replace></message>"))
        guard case let .verified(clean, proof) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected verified edit") }
        let replace = try XCTUnwrap(SCEReceivePolicy.children(of: clean, named: "replace", xmlns: "https://xabber.com/protocol/rewrite#notify").first)
        let leaf = try XCTUnwrap(SCEReceivePolicy.children(of: replace, named: "message", xmlns: "jabber:client").first)
        XCTAssertEqual(replace.attributeStringValue(forName: "version"), "7")
        XCTAssertEqual(replace.attributeStringValue(forName: "id"), "server-id")
        XCTAssertTrue(proof.isAuthenticated)
        XCTAssertEqual(leaf.element(forName: "body")?.stringValue, "verified edit")
        XCTAssertEqual(SCEReceivePolicy.children(of: leaf, named: "replaced", xmlns: "https://xabber.com/protocol/rewrite").count, 1)
        XCTAssertEqual(leaf.element(forName: "replaced")?.attributeStringValue(forName: "stamp"), "2026-09-30T10:00:00Z")
        XCTAssertNil(leaf.element(forName: "reference"))
    }

    func testControlAndReplayNeverReturnDisplayableContentAcrossTransportPaths() throws {
        for kind in ["live", "mam", "sent", "received", "forwarded", "priority", "rewrite"] {
            let f = try fixture()
            let inner = try packet(f, content: nil)
            addInjection(inner)
            let forward = "<forwarded xmlns='urn:xmpp:forward:0'>\(inner.xmlString)</forwarded>"
            let wrapped: String
            switch kind {
            case "mam": wrapped = "<result xmlns='urn:xmpp:mam:2' queryid='query' id='archive'>\(forward)</result>"
            case "sent", "received": wrapped = "<\(kind) xmlns='urn:xmpp:carbons:2'>\(forward)</\(kind)>"
            case "forwarded": wrapped = forward
            case "priority": wrapped = "<priority-message xmlns='https://xabber.com/protocol/priority'>\(forward)</priority-message>"
            case "rewrite": wrapped = "<replace xmlns='https://xabber.com/protocol/rewrite#notify'>\(inner.xmlString)</replace>"
            default: wrapped = ""
            }
            let wire = kind == "live" ? inner : XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'>\(wrapped)</message>"))
            let control = f.bob.prepareIncoming(wire)
            guard case .consumed(.control) = control else { return XCTFail("Expected control for \(kind)") }
            XCTAssertNil(control.message)
            let replay = f.bob.prepareIncoming(wire)
            guard case .consumed(.duplicate) = replay else { return XCTFail("Expected duplicate for \(kind)") }
            XCTAssertNil(replay.message)
        }
    }

    func testCodecDropsEMEAndStanzaIDButRetainsOriginIDAndQualifiedBody() throws {
        let xml = "<s:envelope xmlns:s='urn:xmpp:sce:1'><s:content><body xmlns='foreign'>wrong</body><c:body xmlns:c='jabber:client'>right</c:body><origin-id xmlns='urn:xmpp:sid:0' id='origin'/><stanza-id xmlns='urn:xmpp:sid:0' id='server'/><encryption xmlns='urn:xmpp:eme:0' namespace='fake'/><store xmlns='urn:xmpp:hints'/></s:content><s:rpad>pad</s:rpad></s:envelope>"
        let sealed = try Omemo2PayloadCodec.seal(xml)
        let opened = try XCTUnwrap(Omemo2PayloadCodec.open(sealed.ciphertext, keyAndMAC: sealed.keyAndMAC, expectedFrom: nil, expectedTo: nil))
        let content = try XCTUnwrap(SCEReceivePolicy.children(of: opened, named: "content", xmlns: "urn:xmpp:sce:1").first)
        XCTAssertEqual(SCEReceivePolicy.children(of: content, named: "body", xmlns: "jabber:client").first?.stringValue, "right")
        XCTAssertNotNil(content.element(forName: "origin-id"))
        for name in ["stanza-id", "encryption", "store"] { XCTAssertNil(content.element(forName: name)) }
    }

    func testPlaintextEnvelopeAndNetworkInternalMarkerNeverBecomeProof() throws {
        let manager = OmemoManager(withOwner: "bob@example.test")
        let wire = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='alice@example.test' to='bob@example.test'><body>plain</body><envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>forged</body></content></envelope><omemo-result__system result='true'/></message>"))
        let result = manager.prepareIncoming(wire)
        guard case let .notEncrypted(clean) = result else { return XCTFail("Expected plain message") }
        XCTAssertFalse(result.provenance.isAuthenticated)
        XCTAssertEqual(clean.body, "plain")
        XCTAssertNil(clean.element(forName: "envelope"))
        XCTAssertNil(clean.element(forName: "omemo-result__system"))
    }

    func testForeignTransportMetadataInsideCiphertextCannotSelectIdentityOrDate() throws {
        let f = try fixture()
        let message = try packet(f, content: """
          <body xmlns='jabber:client'>verified</body>
          <stanza-id xmlns='urn:foreign' id='forged-server-id'/>
          <time xmlns='urn:foreign' stamp='2001-01-01T00:00:00Z'/>
          <delay xmlns='urn:foreign' stamp='2001-01-01T00:00:00Z'/>
          <archived xmlns='urn:foreign' id='forged-archive-id'/>
          <addresses xmlns='urn:foreign'><address type='ofrom' jid='attacker@example.test'/></addresses>
        """)
        message.addChild(try DDXMLElement(xmlString: "<s:stanza-id xmlns:s='urn:xmpp:sid:0' id='server-id' by='\(f.bob.owner)'/>"))
        message.addChild(try DDXMLElement(xmlString: "<d:time xmlns:d='https://xabber.com/protocol/delivery' stamp='2026-09-30T10:00:00Z'/>"))
        guard case let .verified(clean, _) = f.bob.prepareIncoming(message) else { return XCTFail("Expected verified message") }
        XCTAssertEqual(getStanzaId(clean, owner: f.bob.owner), "server-id")
        XCTAssertEqual(getDeliveryDate(clean), "2026-09-30T10:00:00Z".xmppDate)
        for name in ["stanza-id", "time", "delay", "archived", "addresses"] {
            XCTAssertTrue((clean.children?.compactMap { $0 as? DDXMLElement } ?? [])
                .filter { $0.localName == name }.allSatisfy { $0.uri != "urn:foreign" }, name)
        }
    }

    func testPrefixedTransportWrappersAndSupportedOldNamespacesUseVerifiedContent() throws {
        let variants = (0...3).map { ("result", "urn:xmpp:mam:\($0)") } +
            (0...2).flatMap { [("sent", "urn:xmpp:carbons:\($0)"), ("received", "urn:xmpp:carbons:\($0)")] }
        for (name, namespace) in variants {
            let f = try fixture()
            let bare = try packet(f, content: "<c:body xmlns:c='jabber:client'>prefixed</c:body>")
            let inner = bare.xmlString.replacingOccurrences(of: "<message ", with: "<c:message xmlns:c='jabber:client' ")
                .replacingOccurrences(of: "</message>", with: "</c:message>")
            let wire = XMPPMessage(from: try DDXMLElement(xmlString: "<c:message xmlns:c='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'><w:\(name) xmlns:w='\(namespace)' id='archive' queryid='query'><f:forwarded xmlns:f='urn:xmpp:forward:0'><d:delay xmlns:d='urn:xmpp:delay' stamp='2026-09-30T10:00:00Z'/>\(inner)</f:forwarded></w:\(name)></c:message>"))
            guard case let .verified(clean, _) = f.bob.prepareIncoming(wire) else { return XCTFail("Failed \(namespace)/\(name)") }
            let recovered = name == "result" ? getArchivedMessageContainer(clean) :
                (name == "sent" ? getCarbonCopyMessageContainer(clean) : getCarbonForwardedMessageContainer(clean))
            XCTAssertEqual(try XCTUnwrap(recovered).body, "prefixed")
            if name == "result" { XCTAssertEqual(getMAMResultID(clean), "archive") }
        }
    }

    func testInvalidCarbonAddressingAndAmbiguousCiphertextCannotCommitState() throws {
        for kind in ["foreign-carbon", "outer-ciphertext", "wrapper-ciphertext", "forwarded-ciphertext", "foreign-message"] {
            let f = try fixture()
            let bare = try packet(f, content: "<body xmlns='jabber:client'>verified</body>")
            let ciphertext = try XCTUnwrap(bare.element(forName: "encrypted")).xmlString
            let inner = kind == "foreign-message" ? bare.xmlString.replacingOccurrences(of: "xmlns=\"jabber:client\"", with: "xmlns=\"foreign\"") : bare.xmlString
            let owner = kind == "foreign-carbon" ? "attacker@example.test" : f.bob.owner
            let wire = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(owner)' to='\(owner)'>\(kind == "outer-ciphertext" ? ciphertext : "")<received xmlns='urn:xmpp:carbons:2'>\(kind == "wrapper-ciphertext" ? ciphertext : "")<forwarded xmlns='urn:xmpp:forward:0'>\(kind == "forwarded-ciphertext" ? ciphertext : "")\(inner)</forwarded></received></message>"))
            let before = f.memory.records[f.bob.owner]
            guard case .consumed(.invalidTransport) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected invalid transport: \(kind)") }
            XCTAssertEqual(f.memory.records[f.bob.owner], before, kind)
        }
    }

    private struct Fixture {
        let alice: XabberOMEMO2Storage
        let bob: OmemoManager
        let bobID: Int
        let memory: Memory
    }

    /// Key material stays in memory; session callbacks use the production
    /// adapter against this test's isolated Realm, without credential writes.
    private final class LegacyKeyStore: NSObject, SignalStore {
        var identity: SignalIdentityKeyPair!
        let sessions: XabberAxolotlStorage
        let registrationID: UInt32
        private var preKeys: [UInt32: Data] = [:]
        private var signedPreKeys: [UInt32: Data] = [:]
        private var identities: [String: Data] = [:]
        private var senderKeys: [String: Data] = [:]

        init(owner: String, registrationID: UInt32) {
            sessions = XabberAxolotlStorage(withOwner: owner)
            self.registrationID = registrationID
        }

        private func key(_ address: SignalAddress) -> String { "\(address.name):\(address.deviceId)" }
        func sessionRecord(for address: SignalAddress) -> Data? { sessions.sessionRecord(for: address) }
        func storeSessionRecord(_ recordData: Data, for address: SignalAddress) -> Bool { sessions.storeSessionRecord(recordData, for: address) }
        func sessionRecordExists(for address: SignalAddress) -> Bool { sessions.sessionRecordExists(for: address) }
        func deleteSessionRecord(for address: SignalAddress) -> Bool { sessions.deleteSessionRecord(for: address) }
        func allDeviceIds(forAddressName name: String) -> [NSNumber] { sessions.allDeviceIds(forAddressName: name) }
        func deleteAllSessions(forAddressName name: String) -> Int32 { sessions.deleteAllSessions(forAddressName: name) }
        func loadPreKey(withId id: UInt32) -> Data? { preKeys[id] }
        func storePreKey(_ data: Data, preKeyId id: UInt32) -> Bool { preKeys[id] = data; return true }
        func containsPreKey(withId id: UInt32) -> Bool { preKeys[id] != nil }
        func deletePreKey(withId id: UInt32) -> Bool { preKeys.removeValue(forKey: id); return true }
        func loadSignedPreKey(withId id: UInt32) -> Data? { signedPreKeys[id] }
        func storeSignedPreKey(_ data: Data, signedPreKeyId id: UInt32) -> Bool { signedPreKeys[id] = data; return true }
        func containsSignedPreKey(withId id: UInt32) -> Bool { signedPreKeys[id] != nil }
        func removeSignedPreKey(withId id: UInt32) -> Bool { signedPreKeys.removeValue(forKey: id); return true }
        func getIdentityKeyPair() -> SignalIdentityKeyPair { identity }
        func getLocalRegistrationId() -> UInt32 { registrationID }
        func saveIdentity(_ address: SignalAddress, identityKey: Data?) -> Bool { identities[key(address)] = identityKey; return true }
        func isTrustedIdentity(_ address: SignalAddress, identityKey: Data) -> Bool { identities[key(address)].map { $0 == identityKey } ?? true }
        func storeSenderKey(_ senderKey: Data, address: SignalAddress, groupId: String) -> Bool { senderKeys["\(groupId):\(key(address))"] = senderKey; return true }
        func loadSenderKey(for address: SignalAddress, groupId: String) -> Data? { senderKeys["\(groupId):\(key(address))"] }
    }

    private func legacyFixture() throws -> (bob: OmemoManager, messages: [XMPPMessage]) {
        let f = try fixture()
        let aliceKeys = LegacyKeyStore(owner: f.alice.owner, registrationID: 41)
        let bobKeys = LegacyKeyStore(owner: f.bob.owner, registrationID: 42)
        let aliceStorage = SignalStorage(signalStore: aliceKeys)
        let bobStorage = SignalStorage(signalStore: bobKeys)
        let aliceContext = try XCTUnwrap(SignalContext(storage: aliceStorage))
        let bobContext = try XCTUnwrap(SignalContext(storage: bobStorage))
        let aliceHelper = try XCTUnwrap(SignalKeyHelper(context: aliceContext))
        let bobHelper = try XCTUnwrap(SignalKeyHelper(context: bobContext))
        aliceKeys.identity = try XCTUnwrap(aliceHelper.generateIdentityKeyPair())
        bobKeys.identity = try XCTUnwrap(bobHelper.generateIdentityKeyPair())
        let preKey = try XCTUnwrap(bobHelper.generatePreKeys(withStartingPreKeyId: 1, count: 1).first)
        let signedPreKey = try XCTUnwrap(bobHelper.generateSignedPreKey(withIdentity: bobKeys.identity, signedPreKeyId: 1))
        XCTAssertTrue(bobKeys.storePreKey(try XCTUnwrap(preKey.serializedData()), preKeyId: preKey.preKeyId))
        XCTAssertTrue(bobKeys.storeSignedPreKey(try XCTUnwrap(signedPreKey.serializedData()), signedPreKeyId: signedPreKey.preKeyId))
        let bundle = try SignalPreKeyBundle(
            registrationId: bobKeys.registrationID, deviceId: 42,
            preKeyId: preKey.preKeyId, preKeyPublic: try XCTUnwrap(preKey.keyPair).publicKey,
            signedPreKeyId: signedPreKey.preKeyId, signedPreKeyPublic: try XCTUnwrap(signedPreKey.keyPair).publicKey,
            signature: signedPreKey.signature, identityKey: bobKeys.identity.publicKey
        )
        let aliceCipher = SignalSessionCipher(address: SignalAddress(name: f.bob.owner, deviceId: 42), context: aliceContext)
        let bobCipher = SignalSessionCipher(address: SignalAddress(name: f.alice.owner, deviceId: 41), context: bobContext)
        try SignalSessionBuilder(address: aliceCipher.address, context: aliceContext).processPreKeyBundle(bundle)
        let bootstrap = try aliceCipher.encryptData(Data("bootstrap existing legacy session".utf8))
        XCTAssertEqual(try bobCipher.decryptCiphertext(bootstrap), Data("bootstrap existing legacy session".utf8))
        XCTAssertTrue(bobKeys.sessions.sessionRecordExists(for: bobCipher.address))
        f.bob.localStore = bobKeys.sessions
        f.bob.signalStorage = bobStorage
        f.bob.signalContext = bobContext

        let messages = try (0..<2).map { index in
            let sealed = try Omemo2PayloadCodec.seal("<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>legacy history \(index)</body></content><rpad>padding</rpad><from jid='\(f.alice.owner)'/><to jid='\(f.bob.owner)'/></envelope>")
            let wrapped = try aliceCipher.encryptData(sealed.keyAndMAC)
            return XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' type='chat' from='\(f.alice.owner)/ios' to='\(f.bob.owner)' id='legacy-\(index)'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='41'><keys jid='\(f.bob.owner)'><key rid='42' kex='\(wrapped.type == .preKeyMessage ? "true" : "false")'>\(wrapped.data.base64EncodedString())</key></keys></header><payload>\(sealed.ciphertext.base64EncodedString())</payload></encrypted></message>"))
        }
        return (f.bob, messages)
    }

    private func fixture() throws -> Fixture {
        let memory = Memory()
        let suffix = UUID().uuidString.lowercased()
        let alice = try XabberOMEMO2Storage(owner: "alice-\(suffix)@example.test", persistence: memory)
        let bobStore = try XabberOMEMO2Storage(owner: "bob-\(suffix)@example.test", persistence: memory)
        _ = try alice.prepare(deviceID: 41, preKeyCount: 3)
        let bundle = try bobStore.prepare(deviceID: 42, preKeyCount: 3)
        let key = try XCTUnwrap(bundle.preKeys.first)
        try alice.initiateSession(jid: bobStore.owner, deviceID: bundle.deviceID, bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey, signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: key.publicKey, preKeyID: key.id))
        let bob = OmemoManager(withOwner: bobStore.owner)
        bob.omemo2Storage = bobStore
        _ = try bob.ensureOMEMO2Prepared()
        return Fixture(alice: alice, bob: bob, bobID: bundle.deviceID, memory: memory)
    }

    private func packet(_ f: Fixture, content: String?) throws -> XMPPMessage {
        try packet(f, xml: content.map { "<envelope xmlns='urn:xmpp:sce:1'><content>\($0)</content><rpad>padding</rpad><from jid='\(f.alice.owner)'/><to jid='\(f.bob.owner)'/></envelope>" })
    }

    private func packet(_ f: Fixture, xml: String?) throws -> XMPPMessage {
        let sealed = try xml.map { try Omemo2PayloadCodec.seal($0) }
        let wrapped = try f.alice.encrypt(sealed?.keyAndMAC ?? Data(repeating: 0, count: 32), jid: f.bob.owner, deviceID: f.bobID)
        let payload = sealed.map { "<payload>\($0.ciphertext.base64EncodedString())</payload>" } ?? ""
        return XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' type='chat' from='\(f.alice.owner)/ios' to='\(f.bob.owner)' id='message-id'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='41'><keys jid='\(f.bob.owner)'><key rid='\(f.bobID)' kex='\(wrapped.isKeyExchange ? "true" : "false")'>\(wrapped.data.base64EncodedString())</key></keys></header>\(payload)</encrypted></message>"))
    }

    private func addInjection(_ message: XMPPMessage) {
        for xml in ["<body xmlns='jabber:client'>injected</body>", "<reference xmlns='https://xabber.com/protocol/references' type='data'><file-sharing xmlns='https://xabber.com/protocol/files'/></reference>", "<ephemeral xmlns='urn:xmpp:ephemeral:0' timer='1'/>", "<displayed xmlns='urn:xmpp:chat-markers:0' id='victim'/>", "<time-signature xmlns='urn:xmpp:x509:0'/>", "<omemo-result__system result='true'/>", "<envelope xmlns='urn:xmpp:sce:1'/>"] {
            message.addChild(try! DDXMLElement(xmlString: xml))
        }
    }
}
