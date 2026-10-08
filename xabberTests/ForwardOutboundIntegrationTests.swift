import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ForwardOutboundIntegrationTests: XCTestCase {
    private var previousConfiguration: Realm.Configuration!
    private let owner = "forward-owner@example.test"

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: name)
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    func testSourcesAreSerializedInChronologicalOrder() throws {
        let older = try source("older", at: 1)
        let newer = try source("newer", at: 2)
        let items = MessageManager(withOwner: owner, activeStream: false).formForwardedMessages([newer, older])
        XCTAssertEqual(items.map(\.date), [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
    }

    func testMissingSourceRejectsWholePreparationInsteadOfSendingSubset() throws {
        let valid = try source("valid", at: 1)
        XCTAssertTrue(MessageManager(withOwner: owner, activeStream: false).formForwardedMessages([valid, "missing"]).isEmpty)
    }

    func testSourceBelongingToAnotherOwnerCannotBeForwarded() throws {
        let foreign = try source("foreign", at: 1, sourceOwner: "another@example.test")
        XCTAssertTrue(MessageManager(withOwner: owner, activeStream: false).formForwardedMessages([foreign]).isEmpty)
    }

    func testSavedFinalReferenceRangeFitsExactBody() throws {
        let primary = try source("saved", at: 1)
        let manager = XMPPFavoritesManager(withOwner: owner)
        manager.configure(for: "saved@example.test")
        let message = try XCTUnwrap(manager.buildForwardMessage(for: [primary]))
        let end = try XCTUnwrap(message.element(forName: "reference")?.attributeIntegerValue(forName: "end"))
        XCTAssertEqual(end, message.body?.xmlEscaping(reverse: false).unicodeScalars.count)
        XCTAssertEqual(parseInlineMessages(message, parentId: "saved", jid: "saved@example.test", owner: owner).count, 1)
    }

    func testSourceRoutingIdentityAndUnknownExtensionArePreserved() throws {
        let primary = try source("original", at: 1)
        let item = try XCTUnwrap(MessageManager(withOwner: owner, activeStream: false).formForwardedMessages([primary]).first)
        let original = try XCTUnwrap(item.referenceElement.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?.element(forName: "message"))
        XCTAssertEqual(original.attributeStringValue(forName: "from"), "author@example.test/resource")
        XCTAssertEqual(original.attributeStringValue(forName: "id"), "original")
        XCTAssertEqual(original.element(forName: "custom", xmlns: "urn:example:original")?.stringValue, "keep")
    }

    func testGroupSnapshotProducesExplicitPrivacyAndHostedAvatarCard() throws {
        let primary = try source("group", at: 1)
        let realm = try WRealm.safe()
        let group = GroupSnapshotStorageItem()
        group.primary = GroupStorageKey.groupPrimary(owner: owner, groupJID: "author@example.test")
        group.owner = owner
        group.groupJID = "author@example.test"
        group.name = "My group"
        group.privacyRaw = "incognito"
        group.avatarURL = "https://files.example.test/group.png"
        try realm.write { realm.add(group) }

        let card = try XCTUnwrap(ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm).first?.attributionCard)

        XCTAssertEqual(card.kind, .group)
        XCTAssertEqual(card.privacy, .incognito)
        XCTAssertEqual(card.name, "My group")
        XCTAssertEqual(card.avatarURI, "https://files.example.test/group.png")
    }

    func testForeignOwnerProfileIsNotUsedAsForwardingSnapshot() throws {
        let primary = try source("profile", at: 1)
        let realm = try WRealm.safe()
        let profile = vCardStorageItem()
        profile.jid = "author@example.test"
        profile.owner = "another@example.test"
        profile.fn = "Foreign account name"
        try realm.write { realm.add(profile) }

        let card = try XCTUnwrap(ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm).first?.attributionCard)

        XCTAssertEqual(card.name, "author@example.test")
        XCTAssertNil(card.nickname)
    }

    func testOwnedRawSourceWithoutDisplayProjectionRemainsForwardable() throws {
        let primary = try source("raw-only", at: 1)
        let realm = try WRealm.safe()
        try realm.write { realm.delete(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)!) }

        let snapshot = try XCTUnwrap(ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm).first)

        XCTAssertEqual(snapshot.message.attributeStringValue(forName: "id"), "raw-only")
        XCTAssertEqual(snapshot.date, Date(timeIntervalSince1970: 1))
    }

    func testCanonicalGroupAuthorWithoutLocalGroupSnapshotHasUnknownPrivacy() throws {
        let primary = try source("group-unknown", at: 1, additionalXML: """
        <x xmlns='https://xabber.com/protocol/groups'><user id='member-1'>
          <nickname>Alice</nickname><jid>alice@example.test</jid>
        </user></x>
        """)
        let card = try XCTUnwrap(ForwardSourceLoader.load(ids: [primary], owner: owner, realm: WRealm.safe()).first?.attributionCard)
        XCTAssertEqual(card.jid, "author@example.test")
        XCTAssertEqual(card.kind, .group)
        XCTAssertNil(card.privacy)
    }

    func testOwnerScopedRosterSnapshotCarriesHostedAvatar() throws {
        let primary = try source("roster", at: 1)
        let realm = try WRealm.safe()
        let roster = RosterStorageItem()
        roster.primary = RosterStorageItem.genPrimary(jid: "author@example.test", owner: owner)
        roster.jid = "author@example.test"
        roster.owner = owner
        roster.username = "Alice"
        roster.avatarMaxUrl = "https://files.example.test/alice.png"
        try realm.write { realm.add(roster) }

        let card = try XCTUnwrap(ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm).first?.attributionCard)
        XCTAssertEqual(card.name, "Alice")
        XCTAssertEqual(card.avatarURI, "https://files.example.test/alice.png")
    }

    func testCommentDecorationHasDisplayOffsetsLocallyAndWireOffsetsInCarrier() throws {
        let primary = try source("markup", at: 1)
        let decoration = MessageReferenceStorageItem()
        decoration.kind = .markup
        decoration.begin = 0
        decoration.end = 4
        decoration.metadata = ["styles": ["bold"]]
        let manager = MessageManager(withOwner: owner, activeStream: false)
        let id = manager.sendSimpleMessage("bold", to: "destination@example.test", forwarded: [primary],
                                           conversationType: .regular, references: [decoration])
        let realm = try WRealm.safe()
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self,
                                             forPrimaryKey: MessageStorageItem.genPrimary(messageId: id, owner: owner)))
        let local = try XCTUnwrap(row.references.first { $0.kind == .markup })
        XCTAssertEqual(row.body, "bold")
        XCTAssertEqual(local.begin, 0)
        XCTAssertEqual(local.end, 4)
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let forwarded = try XCTUnwrap(admittedInlineForwardReferences(in: raw).last)
        let prefix = try XCTUnwrap(forwarded.attributeStringValue(forName: "end").flatMap(Int.init))
        let wire = try XCTUnwrap(raw.elements(forName: "reference").first { $0.attributeStringValue(forName: "type") == "decoration" })
        XCTAssertEqual(wire.attributeIntegerValue(forName: "begin"), prefix)
        XCTAssertEqual(wire.attributeIntegerValue(forName: "end"), prefix + 4)
    }

    func testVerifiedReconstructedSourceForwardsPlaintextWithoutItsOuterCiphertext() throws {
        let primary = try authenticatedSource("verified")
        let realm = try WRealm.safe()
        let raw = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: primary + "_stanza"))
        let originalXML = raw.stanza

        let sources = try ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm)
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: sources, comment: "").first)
        let payload = try XCTUnwrap(unit.refs.first?.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?.element(forName: "message"))

        XCTAssertEqual(payload.element(forName: "body", xmlns: "jabber:client")?.stringValue, "verified plaintext")
        XCTAssertFalse(SCEReceivePolicy.hasOMEMO2(payload))
        XCTAssertEqual(payload.element(forName: "custom", xmlns: "urn:example:original")?.stringValue, "keep")
        XCTAssertEqual(raw.stanza, originalXML)
    }

    func testReplacedRawCiphertextCannotBorrowStoredVerifiedPlaintextProof() throws {
        let primary = try authenticatedSource("changed")
        let realm = try WRealm.safe()
        let raw = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: primary + "_stanza"))
        try realm.write { raw.stanza = raw.stanza.replacingOccurrences(of: "verified plaintext", with: "injected plaintext") }

        XCTAssertThrowsError(try ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm)) { error in
            XCTAssertEqual(error as? ForwardPreparationError, .unavailablePlaintext(primary))
        }
    }

    func testOuterVerificationDoesNotAuthorizeNestedCiphertextPlaintextSiblings() throws {
        let primary = try authenticatedSource("nested", additionalXML: """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='18'>
          <forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='nested@example.test/phone' to='\(owner)' id='nested'>
            <encrypted xmlns='urn:xmpp:omemo:2'><header sid='8'/><payload>nested</payload></encrypted><body>forged sibling</body>
          </message></forwarded>
        </reference>
        """)
        let realm = try WRealm.safe()
        let sources = try ForwardSourceLoader.load(ids: [primary], owner: owner, realm: realm)

        XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: sources, comment: "")) { error in
            XCTAssertEqual(error as? ForwardPreparationError, .unavailablePlaintext(primary))
        }
    }

    private func authenticatedSource(_ id: String, additionalXML: String = "") throws -> String {
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='author@example.test/resource' to='\(owner)' type='chat' id='\(id)'>
          <encrypted xmlns='urn:xmpp:omemo:2'><header sid='7'/><payload>outer</payload></encrypted>
          <body>verified plaintext</body><custom xmlns='urn:example:original'>keep</custom>\(additionalXML)
        </message>
        """)
        let row = MessageStorageItem()
        row.configureIncomingMessage(message, owner: owner, opponent: "author@example.test", outgoing: false,
                                     isRead: true, date: Date(timeIntervalSince1970: 1))
        // This unit fixture exercises the typed persistence boundary. Actual
        // ciphertext verification is covered by the existing OMEMO receive suites.
        row.incomingEncryption = .authenticatedSCE(profile: .omemo2)
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(row, update: .modified)
            row.storeStanza(in: realm)
        }
        return row.primary
    }

    @discardableResult
    private func source(_ id: String, at time: TimeInterval, sourceOwner: String? = nil, additionalXML: String = "") throws -> String {
        let account = sourceOwner ?? owner
        let primary = "source-\(id)"
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='author@example.test/resource' to='\(account)' type='chat' id='\(id)'>
          <body>😀&gt; original</body><custom xmlns='urn:example:original'>keep</custom>\(additionalXML)
        </message>
        """)
        let row = MessageStorageItem()
        row.primary = primary
        row.owner = account
        row.opponent = "author@example.test"
        row.messageId = id
        row.date = Date(timeIntervalSince1970: time)
        row.sentDate = row.date
        let raw = MessageStanzaStorageItem()
        raw.set(id, for: account, with: message.xmlString, at: row.date, primary: primary)
        let realm = try WRealm.safe()
        try realm.write { realm.add(row); realm.add(raw) }
        return primary
    }
}
