import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ForwardRewritePersistenceTests: XCTestCase {
    private let owner = "forward-edit-owner@example.test"
    private let peer = "edit-peer@example.test"
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

    func testCommentEditReparsesStoredRawGraphAndKeepsOriginalAndCard() throws {
        let (manager, row) = try carrier()

        XCTAssertTrue(manager.editSimpleMessage("new 😀 & comment", primary: row.primary))

        XCTAssertEqual(row.body, "new 😀 & comment")
        XCTAssertEqual(row.inlineForwards.count, 1)
        XCTAssertEqual(row.inlineForwards.first?.parentId, row.primary)
        XCTAssertEqual(row.inlineForwards.first?.messageId, "original")
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let ref = try XCTUnwrap(admittedInlineForwardReferences(in: raw).first)
        let original = try XCTUnwrap(inlineForwardPayloadMessage(from: ref)?.message)
        XCTAssertEqual(original.body, "Original text")
        XCTAssertEqual(original.element(forName: "extension", xmlns: "urn:example:original")?.stringValue, "keep")
        XCTAssertEqual(ForwardContactDataCodec.cards(in: raw).first?.jid, peer)
        XCTAssertEqual(parseInlineMessages(raw, parentId: row.primary, jid: peer, owner: owner).first?.body,
                       row.inlineForwards.first?.body)
        XCTAssertTrue(raw.body?.hasSuffix("new 😀 & comment") == true)
    }

    func testMissingRawRejectsEditWithoutChangingCurrentGraphOrComment() throws {
        let (manager, row) = try carrier()
        row.originalStanza = nil
        let stored = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: row.primary + "_stanza"))
        try realm.write { realm.delete(stored) }

        XCTAssertFalse(manager.editSimpleMessage("must stay in draft", primary: row.primary))

        XCTAssertEqual(row.body, "old comment")
        XCTAssertEqual(row.inlineForwards.first?.messageId, "original")
        XCTAssertNil(row.editDate)
    }

    func testForeignOwnerCannotEditPreparedForwardingCarrier() throws {
        let (_, row) = try carrier()
        let foreignManager = MessageManager(withOwner: "another-edit-owner@example.test", activeStream: false)

        XCTAssertFalse(foreignManager.editSimpleMessage("wrong owner", primary: row.primary))

        XCTAssertEqual(row.body, "old comment")
        XCTAssertNil(row.editDate)
    }

    func testInvalidOriginalRangeRejectsReplacementWithoutChangingProjection() throws {
        let (manager, row) = try carrier()
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let ref = try XCTUnwrap(admittedInlineForwardReferences(in: raw).first)
        ref.removeAttribute(forName: "end")
        ref.addAttribute(withName: "end", integerValue: 999_999)
        row.originalStanza = nil
        try realm.write {
            realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: row.primary + "_stanza")?.stanza = raw.xmlString
        }

        XCTAssertFalse(manager.editSimpleMessage("replacement", primary: row.primary))

        XCTAssertEqual(row.body, "old comment")
        XCTAssertEqual(row.inlineForwards.first?.messageId, "original")
        XCTAssertNil(row.editDate)
    }

    func testPreparedTrailingPlainCommentCanBeEditedWithoutCreatingForwardMarkers() throws {
        let (manager, row) = try carrier(donatedOnly: true)
        XCTAssertTrue(row.inlineForwards.isEmpty)

        XCTAssertTrue(manager.editSimpleMessage("edited plain comment", primary: row.primary))

        XCTAssertEqual(row.body, "edited plain comment")
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        XCTAssertEqual(raw.body, "edited plain comment")
        XCTAssertTrue(admittedInlineForwardReferences(in: raw).isEmpty)
    }

    func testVerifiedOwnSentEncryptedHistoryEditDropsOnlyObsoleteTransportEncryption() throws {
        let (manager, row, _) = try receivedEncryptedCarrier(verified: true)

        XCTAssertTrue(manager.editSimpleMessage("verified history edit", primary: row.primary))

        let edited = try XMPPMessage(xmlString: storedXML(row))
        XCTAssertTrue(SCEReceivePolicy.children(of: edited, named: "encrypted", xmlns: "urn:xmpp:omemo:2").isEmpty)
        XCTAssertTrue(SCEReceivePolicy.children(of: edited, named: "encryption", xmlns: "urn:xmpp:eme:0")
            .filter { $0.attributeStringValue(forName: "namespace") == "urn:xmpp:omemo:2" }.isEmpty)
        XCTAssertNotNil(edited.element(forName: "encryption", xmlns: "urn:example:opaque"))
        XCTAssertEqual(row.body, "verified history edit")
        XCTAssertEqual(row.inlineForwards.count, 1)
        let reference = try XCTUnwrap(admittedInlineForwardReferences(in: edited).first)
        let original = try XCTUnwrap(inlineForwardPayloadMessage(from: reference)?.message)
        XCTAssertEqual(original.elementID, "original")
        XCTAssertEqual(original.body, "Original text")
        XCTAssertEqual(original.element(forName: "extension", xmlns: "urn:example:original")?.stringValue, "keep")
        XCTAssertEqual(ForwardContactDataCodec.cards(in: edited).first?.jid, peer)
    }

    func testMissingEncryptedHistoryProofRejectsEditBeforeChangingLocalOrRawContent() throws {
        let (manager, row, raw) = try receivedEncryptedCarrier(verified: false)

        XCTAssertFalse(manager.editSimpleMessage("unverified edit", primary: row.primary))

        XCTAssertEqual(row.body, "old comment")
        XCTAssertNil(row.editDate)
        XCTAssertEqual(try storedXML(row), raw)
        XCTAssertEqual(row.inlineForwards.first?.messageId, "original")
    }

    func testStaleEncryptedHistoryProofCannotAuthorizeChangedOpaqueContent() throws {
        let (manager, row, _) = try receivedEncryptedCarrier(verified: true)
        let changed = try XMPPMessage(xmlString: storedXML(row))
        changed.element(forName: "encryption", xmlns: "urn:example:opaque")?.stringValue = "changed"
        try realm.write {
            realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: row.primary + "_stanza")?.stanza = changed.xmlString
        }

        XCTAssertFalse(manager.editSimpleMessage("stale proof edit", primary: row.primary))

        XCTAssertEqual(row.body, "old comment")
        XCTAssertNil(row.editDate)
        XCTAssertEqual(try storedXML(row), changed.xmlString)
    }

    private func receivedEncryptedCarrier(verified: Bool) throws -> (MessageManager, MessageStorageItem, String) {
        let (manager, row) = try carrier()
        let raw = try XMPPMessage(xmlString: storedXML(row))
        raw.addChild(try DDXMLElement(xmlString: "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='42'/><payload>old ciphertext</payload></encrypted>"))
        raw.addChild(try DDXMLElement(xmlString: "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:2' name='OMEMO'/>"))
        raw.addChild(try DDXMLElement(xmlString: "<encryption xmlns='urn:example:opaque'>keep opaque</encryption>"))
        row.originalStanza = raw
        row.incomingEncryption = verified ? .authenticatedSCE(profile: .omemo2) : .unverifiedOMEMO
        try realm.write {
            row.systemMetadata = nil
            row.conversationType = .omemo
            row.storeStanza(in: realm)
        }
        let saved = try storedXML(row)
        XCTAssertEqual(row.canForwardAuthenticatedPlaintext(stanzaXML: saved, owner: owner), verified)
        row.originalStanza = nil
        row.incomingEncryption = .plaintext
        return (manager, row, saved)
    }

    private func storedXML(_ row: MessageStorageItem) throws -> String {
        try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: row.primary + "_stanza")).stanza
    }

    private func carrier(donatedOnly: Bool = false) throws -> (MessageManager, MessageStorageItem) {
        let source = MessageStorageItem()
        source.primary = "edit-source"
        source.owner = owner
        source.opponent = peer
        source.messageId = "original"
        source.sentDate = Date(timeIntervalSince1970: 1)
        let raw = MessageStanzaStorageItem()
        raw.set(source.messageId, for: owner, with: """
        <message xmlns='jabber:client' from='\(peer)/phone' to='\(owner)' type='chat' id='original'>
          <body>Original text</body><extension xmlns='urn:example:original'>keep</extension>
        </message>
        """, at: source.sentDate, primary: source.primary)
        if donatedOnly {
            let original = try XMPPMessage(xmlString: raw.stanza)
            let snapshot = ForwardSourceSnapshot(message: original, date: source.sentDate, selectionID: "original")
            let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [snapshot], comment: "").first)
            let wrapper = XMPPMessage(messageType: .chat, to: XMPPJID(string: owner), elementID: "selected-carrier", child: nil)
            wrapper.setXmlns("jabber:client")
            wrapper.addAttribute(withName: "from", stringValue: peer)
            unit.appendContent(to: wrapper)
            raw.stanza = wrapper.xmlString
            source.messageId = "selected-carrier"
        }
        try realm.write { realm.add(source); realm.add(raw) }
        let manager = MessageManager(withOwner: owner, activeStream: false)
        let id = manager.sendSimpleMessage("old comment", to: peer, forwarded: [source.primary], conversationType: .regular)
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self,
                                             forPrimaryKey: MessageStorageItem.genPrimary(messageId: id, owner: owner)))
        try realm.write { row.archivedId = "archive-carrier" }
        return (manager, row)
    }
}
