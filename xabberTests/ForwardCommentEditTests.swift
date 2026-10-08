import XCTest
import XMPPFramework
@testable import xabber

final class ForwardCommentEditTests: XCTestCase {
    func testEditingCarrierCommentPreservesOriginalPayloadCardAndUnknownXML() throws {
        let original = try source()
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [original], comment: "old comment").first)
        let carrier = XMPPMessage(messageType: .chat, to: XMPPJID(string: "peer@example.test"), elementID: "carrier", child: nil)
        carrier.setXmlns("jabber:client")
        carrier.addAttribute(withName: "from", stringValue: "owner@example.test")
        carrier.addOriginId("carrier")
        unit.appendContent(to: carrier)
        carrier.addChild(try DDXMLElement(xmlString: "<custom xmlns='urn:example:carrier'>keep me</custom>"))
        let markup = try DDXMLElement(xmlString: "<reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='3'><bold xmlns='https://xabber.com/protocol/markup'/></reference>")

        let edited = try MessageManager.messageByEditingForwardComment(carrier, body: "new 😀 & comment", references: [markup])

        XCTAssertEqual(edited.elementID, "carrier")
        XCTAssertEqual(getOriginId(edited), "carrier")
        XCTAssertTrue(edited.body?.hasSuffix("new 😀 & comment") == true)
        XCTAssertFalse(edited.body?.contains("old comment") == true)
        XCTAssertEqual(edited.element(forName: "custom", xmlns: "urn:example:carrier")?.stringValue, "keep me")
        let forwarded = try XCTUnwrap(admittedInlineForwardReferences(in: edited).first)
        let payload = try XCTUnwrap(inlineForwardPayloadMessage(from: forwarded)?.message)
        XCTAssertEqual(payload.elementID, "original")
        XCTAssertEqual(payload.attributeStringValue(forName: "from"), "author@example.test/phone")
        XCTAssertEqual(payload.element(forName: "private", xmlns: "urn:example:original")?.stringValue, "retain")
        XCTAssertEqual(ForwardContactDataCodec.cards(in: edited).first?.name, "Historical Author")
        let commentStart = try XCTUnwrap(forwarded.attributeStringValue(forName: "end").flatMap(Int.init))
        let emittedMarkup = try XCTUnwrap(edited.elements(forName: "reference").first { $0.attributeStringValue(forName: "type") == "decoration" })
        XCTAssertEqual(emittedMarkup.attributeIntegerValue(forName: "begin"), commentStart)
        XCTAssertEqual(emittedMarkup.attributeIntegerValue(forName: "end"), commentStart + 3)
        XCTAssertEqual(carrier.body, unit.body, "Editing must not mutate the prior snapshot")
    }

    func testEditingOnlyCommentRetainsForwardUnitWhenCommentIsCleared() throws {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [source()], comment: "old").first)
        let carrier = XMPPMessage(messageType: .chat, to: nil, elementID: "carrier", child: nil)
        carrier.setXmlns("jabber:client")
        unit.appendContent(to: carrier)

        let edited = try MessageManager.messageByEditingForwardComment(carrier, body: "", references: [])

        XCTAssertEqual(admittedInlineForwardReferences(in: edited).count, 1)
        XCTAssertEqual(edited.body?.xmlEscaping(reverse: false).unicodeScalars.count,
                       edited.element(forName: "reference")?.attributeIntegerValue(forName: "end"))
    }

    func testEditingRejectsMalformedForwardRatherThanDroppingItsOriginal() throws {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [source()], comment: "old").first)
        let carrier = XMPPMessage(messageType: .chat, to: nil, elementID: "carrier", child: nil)
        carrier.setXmlns("jabber:client")
        unit.appendContent(to: carrier)
        let payload = try XCTUnwrap(carrier.element(forName: "reference")?
            .element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?.element(forName: "message"))
        payload.removeAttribute(forName: "from")

        XCTAssertThrowsError(try MessageManager.messageByEditingForwardComment(carrier, body: "new", references: []))
        XCTAssertTrue(carrier.body?.hasSuffix("old") == true)
    }

    func testEditingCommentReplacesOnlyCurrentLevelGroupMentions() throws {
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [source()], comment: "old").first)
        let carrier = XMPPMessage(messageType: .chat, to: nil, elementID: "carrier", child: nil)
        carrier.setXmlns("jabber:client")
        unit.appendContent(to: carrier)
        carrier.addChild(try DDXMLElement(xmlString: "<mentions xmlns='https://xabber.com/protocol/groups'><user id='old'/></mentions>"))
        let replacement = try DDXMLElement(xmlString: "<mentions xmlns='https://xabber.com/protocol/groups'><user id='new'/></mentions>")

        let edited = try MessageManager.messageByEditingForwardComment(carrier, body: "new", references: [], mentions: replacement)

        let mentions = SCEReceivePolicy.children(of: edited, named: "mentions", xmlns: "https://xabber.com/protocol/groups")
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.element(forName: "user")?.attributeStringValue(forName: "id"), "new")
    }

    private func source() throws -> ForwardSourceSnapshot {
        let raw = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='author@example.test/phone' to='owner@example.test' id='original' type='chat'><body>Original 😀 &amp; text</body><private xmlns='urn:example:original'>retain</private></message>")
        let card = ForwardContactCard(jid: "author@example.test", name: "Historical Author", nickname: nil,
                                     kind: .individual, privacy: nil, avatarURI: nil)
        return ForwardSourceSnapshot(message: raw, date: Date(timeIntervalSince1970: 1), selectionID: "original", attributionCard: card)
    }
}
