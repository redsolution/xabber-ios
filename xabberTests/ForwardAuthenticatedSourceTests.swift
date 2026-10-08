import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ForwardAuthenticatedSourceTests: XCTestCase {
    private let owner = "verified-forward-owner@example.test"
    private let peer = "verified-forward-peer@example.test"
    private var previous: Realm.Configuration!
    private var realm: Realm!

    override func setUp() {
        super.setUp()
        previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: name)
        realm = try! WRealm.safe()
    }

    override func tearDown() {
        realm = nil
        Realm.Configuration.defaultConfiguration = previous
        super.tearDown()
    }

    func testAuthenticatedReconstructedSourceGetsProofForExactPersistedXML() throws {
        let incoming = try source()
        incoming.incomingEncryption = .authenticatedSCE(profile: .omemo2)
        let originalXML = try XCTUnwrap(incoming.originalStanza?.xmlString)
        try realm.write {
            realm.add(incoming)
            incoming.storeStanza(in: realm)
        }
        let stored = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: incoming.primary))
        stored.incomingEncryption = .plaintext
        stored.originalStanza = nil

        let raw = try storedXML(for: stored)

        XCTAssertTrue(stored.canForwardAuthenticatedPlaintext(stanzaXML: raw, owner: owner))
        XCTAssertEqual(raw, originalXML, "The proof must not strip ciphertext or modify the saved source")
    }

    func testEveryUnauthenticatedSourceWithPlaintextSiblingsAndSuccessMarkerStaysUnavailable() throws {
        for provenance in [MessageEncryptionProvenance.plaintext, .unverifiedOMEMO, .failedOMEMO,
                           .authenticatedSCE(profile: .legacySignal)] {
            let incoming = try source(id: UUID().uuidString)
            incoming.incomingEncryption = provenance
            incoming.originalStanza?.addChild(DDXMLElement(name: "omemo-result__system", stringValue: "success"))
            try realm.write {
                realm.add(incoming)
                incoming.storeStanza(in: realm)
            }

            XCTAssertFalse(incoming.canForwardAuthenticatedPlaintext(stanzaXML: try storedXML(for: incoming), owner: owner))
        }
    }

    func testChangedBodyOrUnknownExtensionDoesNotMatchVerifiedSource() throws {
        let incoming = try verifiedSource()
        let saved = try storedXML(for: incoming)
        let changedBody = try XMPPMessage(xmlString: saved)
        changedBody.element(forName: "body", xmlns: "jabber:client")?.stringValue = "forged sibling"
        let changedExtension = try XMPPMessage(xmlString: saved)
        changedExtension.element(forName: "extension", xmlns: "urn:example:verified")?.stringValue = "forged extension"

        XCTAssertFalse(incoming.canForwardAuthenticatedPlaintext(stanzaXML: changedBody.xmlString, owner: owner))
        XCTAssertFalse(incoming.canForwardAuthenticatedPlaintext(stanzaXML: changedExtension.xmlString, owner: owner))
        XCTAssertTrue(incoming.canForwardAuthenticatedPlaintext(stanzaXML: saved, owner: owner))
    }

    func testForeignOwnerAndCopiedProofOnAnotherMessageStayUnavailable() throws {
        let incoming = try verifiedSource()
        let raw = try storedXML(for: incoming)
        let other = try source(id: "another-message")
        other.systemMetadata = incoming.systemMetadata

        XCTAssertFalse(incoming.canForwardAuthenticatedPlaintext(stanzaXML: raw, owner: "foreign@example.test"))
        XCTAssertFalse(other.canForwardAuthenticatedPlaintext(stanzaXML: raw, owner: owner))
    }

    func testUnverifiedChangedStanzaStoreClearsPreviouslyVerifiedSourceProof() throws {
        let verified = try verifiedSource()
        let original = try storedXML(for: verified)
        let unverified = try source()
        unverified.incomingEncryption = .unverifiedOMEMO
        unverified.originalStanza?.element(forName: "body", xmlns: "jabber:client")?.stringValue = "changed without authentication"

        try realm.write { unverified.storeStanza(in: realm) }

        XCTAssertFalse(verified.canForwardAuthenticatedPlaintext(stanzaXML: try storedXML(for: verified), owner: owner))
        XCTAssertFalse(verified.canForwardAuthenticatedPlaintext(stanzaXML: original, owner: owner),
                       "A superseded proof must not authorize the old XML after the raw source changed")
    }

    func testExactUnverifiedRepeatKeepsExistingVerifiedSourceProof() throws {
        let verified = try verifiedSource()
        let original = try storedXML(for: verified)
        let repeated = try source()
        repeated.incomingEncryption = .unverifiedOMEMO

        try realm.write { repeated.storeStanza(in: realm) }

        XCTAssertTrue(verified.canForwardAuthenticatedPlaintext(stanzaXML: original, owner: owner))
    }

    func testLegacyPersistedCiphertextCannotAcquireProofFromReplayFingerprint() throws {
        let incoming = try source()
        try realm.write {
            realm.add(incoming)
            incoming.storeStanza(in: realm)
            realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: incoming.primary + "_stanza")?
                .omemo2ReplayFingerprint = Data(repeating: 0x44, count: 32)
        }

        XCTAssertFalse(incoming.canForwardAuthenticatedPlaintext(stanzaXML: try storedXML(for: incoming), owner: owner))
    }

    func testDirectVerifiedSavedSourcePersistsExactProofAndForwardsAuthenticatedContent() throws {
        let message = try savedMessage(id: "saved-verified")
        let manager = XMPPFavoritesManager(withOwner: owner)

        let row = try XCTUnwrap(manager.receiveSaved(message: message, realm: realm, commitTransaction: true,
            favoritesNodeOverride: "saved@example.test", encryption: .authenticatedSCE(profile: .omemo2)))
        let raw = try storedXML(for: row)
        let snapshot = try XCTUnwrap(ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm).first)

        XCTAssertTrue(row.canForwardAuthenticatedPlaintext(stanzaXML: raw, owner: owner))
        XCTAssertEqual(raw, message.xmlString)
        XCTAssertEqual(snapshot.message.body, "Saved verified content")
        XCTAssertFalse(SCEReceivePolicy.hasOMEMO2(snapshot.message))
    }

    func testCachedSavedSourceCannotStampChangedRawUsingItsPreviousTransientAuthority() throws {
        let manager = XMPPFavoritesManager(withOwner: owner)
        let row = try XCTUnwrap(manager.receiveSaved(message: savedMessage(id: "saved-repeat"), realm: realm,
            commitTransaction: true, favoritesNodeOverride: "saved@example.test",
            encryption: .authenticatedSCE(profile: .omemo2)))
        let previousXML = try storedXML(for: row)
        row.incomingEncryption = .authenticatedSCE(profile: .omemo2)
        let changed = try savedMessage(id: "saved-repeat")
        changed.element(forName: "body", xmlns: "jabber:client")?.stringValue = "forged changed plaintext"

        _ = try manager.receiveSaved(message: changed, realm: realm, commitTransaction: true,
            favoritesNodeOverride: "saved@example.test", encryption: .unverifiedOMEMO)

        XCTAssertFalse(row.canForwardAuthenticatedPlaintext(stanzaXML: try storedXML(for: row), owner: owner))
        XCTAssertFalse(row.canForwardAuthenticatedPlaintext(stanzaXML: previousXML, owner: owner))
        XCTAssertThrowsError(try ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm))
    }

    func testVerifiedSavedOuterDoesNotGrantProofToUnwrappedNestedCiphertext() throws {
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='saved@example.test' id='saved-nested'><body>quote</body><time xmlns='https://xabber.com/protocol/delivery' stamp='2026-10-07T10:00:00Z'/><reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='5'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='\(peer)' to='\(owner)' id='nested'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='7'/><payload>nested</payload></encrypted><body>forged nested sibling</body></message></forwarded></reference></message>
        """)
        let row = try XCTUnwrap(XMPPFavoritesManager(withOwner: owner).receiveSaved(message: message, realm: realm,
            commitTransaction: true, favoritesNodeOverride: "saved@example.test",
            encryption: .authenticatedSCE(profile: .omemo2)))

        XCTAssertTrue(row.isSavedForward)
        XCTAssertFalse(row.canForwardAuthenticatedPlaintext(stanzaXML: try storedXML(for: row), owner: owner))
        XCTAssertThrowsError(try ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm))
    }

    func testCentralStanzaStoreDoesNotPromoteSavedForwardOuterAuthority() throws {
        let incoming = try source()
        incoming.isSavedForward = true
        incoming.incomingEncryption = .authenticatedSCE(profile: .omemo2)

        try realm.write {
            realm.add(incoming)
            incoming.storeStanza(in: realm)
        }

        XCTAssertFalse(incoming.canForwardAuthenticatedPlaintext(stanzaXML: try storedXML(for: incoming), owner: owner))
    }

    func testVerifiedIncomingRewritePersistsCurrentXMLWithOriginalExtensionQNamesAndCDATA() throws {
        let row = try verifiedSource()
        try realm.write { row.archivedId = "rewrite-archive"; row.conversationType = .omemo }
        let replacement = try rewriteNotification(encrypted: true)
        let originalXML = replacement.xmlString

        XCTAssertTrue(MessageDeleteManager(withOwner: owner).readRewriteNotify(replacement,
            encryption: .authenticatedSCE(profile: .omemo2)))

        let raw = try storedXML(for: row)
        let snapshot = try XCTUnwrap(ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm).first)
        XCTAssertEqual(row.body, "Current correction")
        XCTAssertTrue(row.canForwardAuthenticatedPlaintext(stanzaXML: raw, owner: owner))
        XCTAssertEqual(snapshot.message.uri, "jabber:client")
        XCTAssertEqual(snapshot.message.body, "Current correction")
        XCTAssertEqual(snapshot.message.element(forName: "opaque", xmlns: "https://xabber.com/protocol/rewrite#notify")?.stringValue,
                       "keep <value> & bytes")
        XCTAssertTrue(raw.contains("<![CDATA[keep <value> & bytes]]>"))
        XCTAssertEqual(replacement.xmlString, originalXML, "Normalizing storage must not mutate the received XML")
    }

    func testPlaintextIncomingRewriteStoresCurrentSourceAndClearsPreviousCryptoProof() throws {
        let row = try verifiedSource()
        let previousXML = try storedXML(for: row)
        try realm.write { row.archivedId = "rewrite-archive"; row.conversationType = .regular }
        let notification = try rewriteNotification(encrypted: false)
        notification.element(forName: "replace", xmlns: "https://xabber.com/protocol/rewrite#notify")?
            .element(forName: "message")?.removeAttribute(forName: "id")

        XCTAssertTrue(MessageDeleteManager(withOwner: owner).readRewriteNotify(notification))

        let raw = try storedXML(for: row)
        let snapshot = try XCTUnwrap(ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm).first)
        XCTAssertEqual(snapshot.message.body, "Current correction")
        XCTAssertEqual(snapshot.message.uri, "jabber:client")
        XCTAssertEqual(snapshot.message.to?.bare, owner)
        XCTAssertEqual(snapshot.message.elementID, row.messageId)
        XCTAssertFalse(row.canForwardAuthenticatedPlaintext(stanzaXML: raw, owner: owner))
        XCTAssertFalse(row.canForwardAuthenticatedPlaintext(stanzaXML: previousXML, owner: owner))
    }

    func testUnverifiedEncryptedRewriteLeavesStoredXMLAndProofUnchanged() throws {
        let row = try verifiedSource()
        try realm.write { row.archivedId = "rewrite-archive"; row.conversationType = .omemo }
        let original = try storedXML(for: row)
        let originalBody = row.body

        XCTAssertTrue(MessageDeleteManager(withOwner: owner).readRewriteNotify(try rewriteNotification(encrypted: true),
            encryption: .unverifiedOMEMO))

        XCTAssertEqual(row.body, originalBody)
        XCTAssertEqual(try storedXML(for: row), original)
        XCTAssertTrue(row.canForwardAuthenticatedPlaintext(stanzaXML: original, owner: owner))
    }

    private func savedMessage(id: String) throws -> XMPPMessage {
        try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='saved@example.test' type='chat' id='\(id)'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='42'/><payload>ciphertext</payload></encrypted><body>Saved verified content</body><time xmlns='https://xabber.com/protocol/delivery' stamp='2026-10-07T10:00:00Z'/></message>
        """)
    }

    private func rewriteNotification(encrypted: Bool) throws -> XMPPMessage {
        let cipher = encrypted ? "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='42'/><payload>new ciphertext</payload></encrypted>" : ""
        let bodyNamespace = encrypted ? "jabber:client" : "https://xabber.com/protocol/rewrite#notify"
        let kind = encrypted ? ClientSynchronizationManager.ConversationType.omemo.rawValue : "regular"
        return try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)' type='headline'><replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(peer)' type='\(kind)' id='rewrite-archive' version='2'><message from='\(peer)' id='replacement'>\(cipher)<body xmlns='\(bodyNamespace)'>Current correction</body><opaque><![CDATA[keep <value> & bytes]]></opaque><replaced xmlns='https://xabber.com/protocol/rewrite' stamp='2026-10-07T11:00:00Z'/></message></replace></message>
        """)
    }

    private func verifiedSource() throws -> MessageStorageItem {
        let incoming = try source()
        incoming.incomingEncryption = .authenticatedSCE(profile: .omemo2)
        try realm.write {
            realm.add(incoming)
            incoming.storeStanza(in: realm)
        }
        return incoming
    }

    private func source(id: String = "verified-original") throws -> MessageStorageItem {
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(peer)/phone' to='\(owner)' type='chat' id='\(id)'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='42'/><payload>ciphertext</payload></encrypted><body>Verified 😀 &amp; text</body><extension xmlns='urn:example:verified'>preserve</extension></message>
        """)
        let row = MessageStorageItem()
        row.owner = owner
        row.opponent = peer
        row.messageId = id
        row.primary = MessageStorageItem.genPrimary(messageId: id, owner: owner)
        row.body = message.body ?? ""
        row.legacyBody = row.body
        row.originalStanza = message
        return row
    }

    private func storedXML(for row: MessageStorageItem) throws -> String {
        try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: row.primary + "_stanza")).stanza
    }
}
