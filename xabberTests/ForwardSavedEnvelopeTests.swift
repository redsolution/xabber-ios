import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ForwardSavedEnvelopeTests: XCTestCase {
    private let owner = "saved-owner@example.test"
    private let service = "saved@example.test"

    func testSavedCarrierWithTwoRootsAndCommentKeepsWholeContent() throws {
        let sourceA = try original("a")
        let sourceB = try original("b")
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [sourceA, sourceB], comment: "my note").first)
        let message = carrier(unit)

        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: message, owner: owner, favoritesNode: service))

        XCTAssertFalse(envelope.isForwardedSaved)
        XCTAssertNil(envelope.innerMessage)
        XCTAssertEqual(envelope.storageMessage.elementID, "carrier")
        XCTAssertEqual(admittedInlineForwardReferences(in: envelope.storageMessage).count, 2)
        XCTAssertTrue(envelope.storageMessage.body?.hasSuffix("my note") == true)
    }

    func testSingleForwardWithOwnCommentKeepsCommentInSavedCarrier() throws {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [original("a")], comment: "keep comment").first)
        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: carrier(unit), owner: owner, favoritesNode: service))

        XCTAssertFalse(envelope.isForwardedSaved)
        XCTAssertEqual(envelope.storageMessage.elementID, "carrier")
        XCTAssertTrue(envelope.storageMessage.body?.hasSuffix("keep comment") == true)
    }

    func testPureSingleSaveWrapperStillUnwrapsOriginalAndKeepsItsTimestamp() throws {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [original("a")], comment: "").first)
        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: carrier(unit), owner: owner, favoritesNode: service))

        XCTAssertTrue(envelope.isForwardedSaved)
        XCTAssertEqual(envelope.storageMessage.elementID, "a")
        XCTAssertEqual(envelope.originalFromJid, "author@example.test")
        XCTAssertEqual(envelope.sentDate, Date(timeIntervalSince1970: 1))
    }

    func testOverlappingCanonicalForwardPreventsSingleSaveWrapperUnwrap() throws {
        let message = try malformedCarrier(mixedPayload: false)

        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: message, owner: owner, favoritesNode: service))

        XCTAssertFalse(envelope.isForwardedSaved)
        XCTAssertNil(envelope.innerMessage)
        XCTAssertEqual(envelope.storageMessage.elementID, "carrier")
        XCTAssertEqual(canonicalForwardCount(in: envelope.storageMessage), 2)
    }

    func testMixedCanonicalForwardPayloadPreventsSingleSaveWrapperUnwrap() throws {
        let message = try malformedCarrier(mixedPayload: true)

        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: message, owner: owner, favoritesNode: service))

        XCTAssertFalse(envelope.isForwardedSaved)
        XCTAssertEqual(envelope.storageMessage.elementID, "carrier")
        XCTAssertEqual(canonicalForwardCount(in: envelope.storageMessage), 2)
        XCTAssertNotNil(SCEReceivePolicy.children(of: envelope.storageMessage, named: "reference", xmlns: "https://xabber.com/protocol/references").last?
            .element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files"))
    }

    func testLegacySavedLoaderKeepsMalformedCarrierForPlannerToReject() throws {
        let message = try malformedCarrier(mixedPayload: false)
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: name))
        let row = MessageStorageItem()
        row.owner = owner
        row.opponent = service
        row.conversationType = .saved
        row.outgoing = true
        row.messageId = "carrier"
        row.primary = MessageStorageItem.genPrimary(messageId: row.messageId, owner: owner)
        row.date = Date(timeIntervalSince1970: 2)
        row.sentDate = row.date
        row.originalStanza = message
        try realm.write {
            realm.add(row)
            row.storeStanza(in: realm)
        }

        let source = try XCTUnwrap(ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm).first)

        XCTAssertEqual(source.message.elementID, "carrier")
        XCTAssertEqual(canonicalForwardCount(in: source.message), 2)
        XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: [source], comment: "")) { error in
            XCTAssertEqual(error as? ForwardPreparationError, .malformedSource(row.primary))
        }
    }

    func testForeignForwardLookalikesDoNotPreventPureSaveWrapperUnwrap() throws {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [original("a")], comment: "").first)
        let message = carrier(unit)
        message.addChild(try DDXMLElement(xmlString: """
            <reference xmlns='urn:example:foreign' type='mutable' begin='0' end='1'>
              <forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='other@example.test' to='\(owner)' id='foreign-reference'><body>Foreign reference</body></message></forwarded>
            </reference>
            """))
        message.addChild(try DDXMLElement(xmlString: """
            <reference xmlns='https://xabber.com/protocol/references' type='data'>
              <forwarded xmlns='urn:example:foreign'><message xmlns='jabber:client' from='other@example.test' to='\(owner)' id='foreign-forwarded'><body>Foreign forwarded</body></message></forwarded>
            </reference>
            """))

        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: message, owner: owner, favoritesNode: service))

        XCTAssertTrue(envelope.isForwardedSaved)
        XCTAssertEqual(envelope.storageMessage.elementID, "a")
    }

    func testUnknownOriginalDateIsAcceptedWithoutInventingForwardDelay() throws {
        let unknown = try original("unknown")
        let source = ForwardSourceSnapshot(message: unknown.message, date: nil, selectionID: "unknown")
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [source], comment: "").first)
        let envelope = try XCTUnwrap(SavedMessageParser.parse(messageContainer: carrier(unit), owner: owner, favoritesNode: service))

        XCTAssertTrue(envelope.isForwardedSaved)
        XCTAssertNil(envelope.originalDate)
        XCTAssertEqual(envelope.date, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(envelope.sentDate, envelope.date, "Local chronology may use delivery without asserting an original timestamp")
    }

    func testStrippedSaveRetainsOuterCardSnapshotInExistingMetadataProjection() throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: name)
        defer { Realm.Configuration.defaultConfiguration = previous }
        let card = ForwardContactCard(jid: "author@example.test", name: "Historical Author", nickname: nil,
                                     kind: .individual, privacy: nil, avatarURI: "https://example.test/avatar.png")
        let source = try original("a")
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [source], comment: "").first)
        let message = carrier(unit)
        message.addChild(ForwardContactDataCodec.encode(card))
        let realm = try WRealm.safe()
        let manager = XMPPFavoritesManager(withOwner: owner)

        let stored = try XCTUnwrap(manager.receiveSaved(message: message, realm: realm, commitTransaction: true,
                                                       favoritesNodeOverride: service))

        XCTAssertEqual(ForwardContactDataCodec.matchingCard(for: card.jid, references: stored.references.toArray()), card)
        let loaded = try XCTUnwrap(ForwardSourceLoader.load(ids: [stored.primary], owner: owner, realm: realm).first)
        XCTAssertEqual(loaded.attributionCard, card)
        XCTAssertEqual(loaded.message.elementID, "a")
    }

    private func original(_ id: String) throws -> ForwardSourceSnapshot {
        let message = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='author@example.test/phone' to='\(owner)' type='chat' id='\(id)'><body>Original \(id)</body></message>")
        return ForwardSourceSnapshot(message: message, date: Date(timeIntervalSince1970: 1), selectionID: id)
    }

    private func malformedCarrier(mixedPayload: Bool) throws -> XMPPMessage {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [original("a")], comment: "").first)
        let message = carrier(unit)
        let overlapping = try XCTUnwrap(admittedInlineForwardReferences(in: message).first?.copy() as? DDXMLElement)
        let inner = try XCTUnwrap(overlapping.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?
            .element(forName: "message", xmlns: "jabber:client"))
        inner.removeAttribute(forName: "id")
        inner.addAttribute(withName: "id", stringValue: "second-original")
        inner.element(forName: "body", xmlns: "jabber:client")?.stringValue = "Second original"
        if mixedPayload {
            overlapping.addChild(try DDXMLElement(xmlString: """
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file><media-type>application/pdf</media-type><name>second.pdf</name></file>
                  <sources><uri>https://files.example.test/second.pdf</uri></sources>
                </file-sharing>
                """))
        }
        message.addChild(overlapping)
        return message
    }

    private func canonicalForwardCount(in message: XMPPMessage) -> Int {
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references").filter {
            !SCEReceivePolicy.children(of: $0, named: "forwarded", xmlns: "urn:xmpp:forward:0").isEmpty
        }.count
    }

    private func carrier(_ unit: ForwardPreparedUnit) -> XMPPMessage {
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: service), elementID: "carrier", child: nil)
        message.setXmlns("jabber:client")
        message.addAttribute(withName: "from", stringValue: owner)
        message.addOriginId("carrier")
        let time = DDXMLElement(name: "time", xmlns: "https://xabber.com/protocol/delivery")
        time.addAttribute(withName: "stamp", stringValue: Date(timeIntervalSince1970: 2).XMPPFormattedDate)
        message.addChild(time)
        unit.appendContent(to: message)
        return message
    }
}
