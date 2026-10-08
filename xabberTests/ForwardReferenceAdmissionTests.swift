import XCTest
import XMPPFramework
@testable import xabber

final class ForwardReferenceAdmissionTests: XCTestCase {
    private let owner = "romeo@example.test"
    private let jid = "destination@example.test"

    func testOverlappingForwardDoesNotPublishRichEntryOrMarker() throws {
        let message = try message(
            bodyXML: "first second",
            references: forward(begin: 0, end: 5, id: "first") +
                forward(begin: 4, end: 12, id: "second")
        )

        let inline = parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner)
        let references = parseReferences(message, primary: "parent", jid: jid, owner: owner)

        XCTAssertEqual(inline.map(\.messageId), ["first"])
        XCTAssertEqual(references.filter { $0.kind == .forward }.count, 1)
        XCTAssertEqual(displayBody(message), " second")
    }

    func testAdjacentForwardsShareAdmissionAndPreserveComment() throws {
        let message = try message(
            bodyXML: "firstsecond comment",
            references: forward(begin: 0, end: 5, id: "first") +
                forward(begin: 5, end: 11, id: "second")
        )

        let inline = parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner)
        let references = parseReferences(message, primary: "parent", jid: jid, owner: owner)

        XCTAssertEqual(inline.map(\.messageId), ["first", "second"])
        XCTAssertEqual(references.filter { $0.kind == .forward }.count, 2)
        XCTAssertEqual(displayBody(message), " comment")
    }

    func testMixedForwardAndMediaPayloadKeepsFallbackAndPublishesNeitherKind() throws {
        let reference = """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>
          \(forwarded(id: "mixed"))
          <file-sharing xmlns='https://xabber.com/protocol/files'>
            <file><name>File</name><media-type>image/png</media-type></file>
            <sources><uri>https://example.test/file.png</uri></sources>
          </file-sharing>
        </reference>
        """
        let message = try message(bodyXML: "fallback", references: reference)

        let inline = parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner)
        let references = parseReferences(message, primary: "parent", jid: jid, owner: owner)

        XCTAssertTrue(inline.isEmpty)
        XCTAssertTrue(references.isEmpty)
        XCTAssertEqual(displayBody(message), "fallback")
    }

    func testMalformedForwardDoesNotReserveRangeAgainstValidForward() throws {
        let malformed = """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>
          <forwarded xmlns='urn:xmpp:forward:0'/>
        </reference>
        """
        let message = try message(bodyXML: "fallback", references: malformed + forward(begin: 0, end: 8, id: "valid"))

        let inline = parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner)

        XCTAssertEqual(inline.map(\.messageId), ["valid"])
        XCTAssertEqual(displayBody(message), "")
    }

    func testAdmissionIndicesRemainScopedToQualifiedDirectReferences() throws {
        let message = try message(bodyXML: "fallback note", references: """
        <reference xmlns='urn:foreign' type='mutable' begin='0' end='8'/>
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='99'>\(forwarded(id: "malformed"))</reference>
        \(forward(begin: 0, end: 8, id: "accepted"))
        <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='9' end='13'><bold xmlns='https://xabber.com/protocol/markup'/></reference>
        \(forward(begin: 2, end: 6, id: "overlap"))
        """)

        for _ in 0..<3 {
            let qualified = SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references")

            XCTAssertEqual(qualified.count, 4)
            XCTAssertEqual(admittedMessageContentReferenceIndices(in: message), Set([1, 2]))
            XCTAssertEqual(admittedInlineForwardReferenceIndices(in: message), Set([1]))
            XCTAssertEqual(getReferenceType(qualified[1]), "forward")
            XCTAssertEqual(getReferenceType(qualified[2]), "markup")
        }
        XCTAssertTrue(admittedInlineForwardReferenceIndices(in: message, depth: inlineForwardMaximumDepth).isEmpty)
        XCTAssertEqual(admittedMessageContentReferenceIndices(in: message, depth: inlineForwardMaximumDepth), Set([2]))
    }

    func testQualifiedMediaFallbackElisionUsesSameIndexAdmission() throws {
        let prefix = "caption 😀 &amp; text\n"
        let decodedPrefix = "caption 😀 & text\n"
        let uri = "https://files.example.test/a.jpg"
        let begin = decodedPrefix.xmlEscaping(reverse: false).unicodeScalars.count
        let end = begin + uri.unicodeScalars.count
        let message = try message(bodyXML: prefix + uri, references: """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='\(begin)' end='\(end)'><file-sharing xmlns='https://xabber.com/protocol/files'><sources><uri>\(uri)</uri></sources><file><media-type>image/jpeg</media-type></file></file-sharing></reference>
        """)

        XCTAssertEqual(admittedMessageContentReferenceIndices(in: message), Set([0]))
        XCTAssertTrue(admittedInlineForwardReferenceIndices(in: message).isEmpty)
        XCTAssertEqual(displayBody(message), decodedPrefix)
        XCTAssertEqual(parseReferences(message, primary: "media", jid: jid, owner: owner).map(\.kind), [.media])
    }

    func testScalarWireOffsetsEscapeEmojiFallbackAndRebaseDecorationToUTF16() throws {
        let references = forward(begin: 0, end: 5, id: "emoji") + """
        <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='5' end='8'>
          <bold xmlns='https://xabber.com/protocol/markup'/>
        </reference>
        """
        let message = try message(bodyXML: "😀&gt;😀ok", references: references)

        let parsed = parseReferences(message, primary: "parent", jid: jid, owner: owner)
        let decoration = try XCTUnwrap(parsed.first { $0.kind == .markup })

        XCTAssertEqual(displayBody(message), "😀ok")
        XCTAssertEqual(decoration.begin, 0)
        XCTAssertEqual(decoration.end, 4)
        XCTAssertEqual(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).count, 1)
    }

    func testRepeatedInnerIDHasUniqueScopedPrimaryAndAssignedParent() throws {
        let message = try message(
            bodyXML: "firstsecond",
            references: forward(begin: 0, end: 5, id: "shared") + forward(begin: 5, end: 11, id: "shared")
        )

        let inline = parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner)

        XCTAssertEqual(inline.count, 2)
        XCTAssertEqual(inline.map(\.parentId), ["parent", "parent"])
        XCTAssertEqual(Set(inline.map(\.primary)).count, 2)
        XCTAssertTrue(inline.allSatisfy { $0.primary.isNotEmpty })
    }

    func testInlineReferencesBelongToInlineContainer() throws {
        let original = """
        <forwarded xmlns='urn:xmpp:forward:0'>
          <message xmlns='jabber:client' from='alice@example.test' to='\(owner)' id='decorated'>
            <body>text</body>
            <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='4'>
              <bold xmlns='https://xabber.com/protocol/markup'/>
            </reference>
          </message>
        </forwarded>
        """
        let message = try message(bodyXML: "fallback", references: """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>\(original)</reference>
        """)

        let inline = try XCTUnwrap(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).first)

        XCTAssertEqual(inline.references.first?.messageId, inline.primary)
    }

    func testDisplayOffsetDoesNotReadmitRejectedOverlapInShortPrefix() throws {
        let references = forward(begin: 0, end: 10, id: "accepted") +
            forward(begin: 4, end: 6, id: "rejected") + """
        <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='6' end='14'>
          <bold xmlns='https://xabber.com/protocol/markup'/>
        </reference>
        """
        let message = try message(bodyXML: "abcdefghij rest", references: references)

        let parsed = parseReferences(message, primary: "parent", jid: jid, owner: owner)
        let decoration = try XCTUnwrap(parsed.first { $0.kind == .markup })

        XCTAssertEqual(displayBody(message), " rest")
        XCTAssertEqual(decoration.begin, 0)
        XCTAssertEqual(decoration.end, 4)
    }

    func testDataCardKeepsBodyAndProvidesMatchingForwardSnapshot() throws {
        let card = ForwardContactCard(
            jid: "alice@example.test", name: "Alice Snapshot", nickname: "Ally",
            kind: .individual, privacy: nil, avatarURI: nil
        )
        let message = try message(bodyXML: "fallback comment", references: forward(begin: 0, end: 8, id: "card"))
        message.addChild(ForwardContactDataCodec.encode(card))

        let inline = try XCTUnwrap(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).first)
        let parsed = parseReferences(message, primary: "parent", jid: jid, owner: owner)

        XCTAssertEqual(displayBody(message), " comment")
        XCTAssertEqual(parsed.filter { $0.kind == .forwardContactData }.count, 1)
        XCTAssertEqual(inline.forwardNickname, "Ally")
        XCTAssertEqual(ForwardContactDataCodec.matchingCard(for: card.jid, references: inline.references.toArray()), card)
    }

    func testOuterCardDoesNotBecomeNestedForwardSnapshot() throws {
        let child = forward(begin: 0, end: 5, id: "child")
        let original = """
        <forwarded xmlns='urn:xmpp:forward:0'>
          <message xmlns='jabber:client' from='alice@example.test' to='\(owner)' id='outer'>
            <body>child</body>\(child)
          </message>
        </forwarded>
        """
        let message = try message(bodyXML: "fallback", references: """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>\(original)</reference>
        """)
        message.addChild(ForwardContactDataCodec.encode(ForwardContactCard(
            jid: "alice@example.test", name: "Outer Snapshot", nickname: nil,
            kind: .individual, privacy: nil, avatarURI: nil
        )))

        let inline = try XCTUnwrap(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).first)
        let nested = try XCTUnwrap(inline.subforwards.first)

        XCTAssertEqual(inline.forwardNickname, "Outer Snapshot")
        XCTAssertTrue(nested.forwardNickname.isEmpty)
        XCTAssertEqual(nested.parentId, inline.primary)
        XCTAssertFalse(nested.references.contains { $0.kind == .forwardContactData })
    }

    func testIncognitoGroupAttributionDoesNotExposeRoutingJIDAsAuthor() throws {
        let message = try groupMessage(authorXML: "<user id='member-7'/>", card: ForwardContactCard(
            jid: "source-group@example.test", name: "Carried Group", nickname: nil,
            kind: .group, privacy: .incognito, avatarURI: nil
        ))

        let inline = try XCTUnwrap(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).first)
        let attribution = inline.attribution

        XCTAssertEqual(attribution.routingJID, "source-group@example.test")
        XCTAssertEqual(attribution.sourceGroupJID, "source-group@example.test")
        XCTAssertEqual(attribution.memberID, "member-7")
        XCTAssertNil(attribution.displayableAuthorJID)
        XCTAssertEqual(attribution.groupName, "Carried Group")
        XCTAssertEqual(attribution.groupPrivacy, .incognito)
        XCTAssertEqual(attribution.senderName, "Carried Group")
        XCTAssertEqual(inline.tryToLoadNickname(), "Carried Group")
    }

    func testGroupRealAuthorJIDDoesNotInferPublicPrivacy() throws {
        let message = try groupMessage(authorXML: """
        <user id='member-7'><jid>alice@example.test</jid><nickname>Member Snapshot</nickname></user>
        """, card: ForwardContactCard(
            jid: "source-group@example.test", name: "Unknown Privacy", nickname: nil,
            kind: .group, privacy: nil, avatarURI: nil
        ))

        let inline = try XCTUnwrap(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).first)

        XCTAssertEqual(inline.attribution.sourceGroupJID, "source-group@example.test")
        XCTAssertEqual(inline.attribution.displayableAuthorJID, "alice@example.test")
        XCTAssertNil(inline.attribution.groupPrivacy)
        XCTAssertEqual(inline.attribution.senderName, "Member Snapshot")
    }

    func testIndividualSnapshotDoesNotCreateOriginGroup() throws {
        let message = try message(bodyXML: "fallback", references: forward(begin: 0, end: 8, id: "individual"))
        message.addChild(ForwardContactDataCodec.encode(ForwardContactCard(
            jid: "alice@example.test", name: "Carried Individual", nickname: nil,
            kind: .individual, privacy: nil, avatarURI: nil
        )))

        let inline = try XCTUnwrap(parseInlineMessages(message, parentId: "parent", jid: jid, owner: owner).first)

        XCTAssertEqual(inline.attribution.routingJID, "alice@example.test")
        XCTAssertEqual(inline.attribution.displayableAuthorJID, "alice@example.test")
        XCTAssertNil(inline.attribution.sourceGroupJID)
        XCTAssertNil(inline.attribution.memberID)
        XCTAssertNil(inline.attribution.groupName)
        XCTAssertNil(inline.attribution.groupPrivacy)
        XCTAssertEqual(inline.attribution.senderName, "Carried Individual")
    }

    private func groupMessage(authorXML: String, card: ForwardContactCard) throws -> XMPPMessage {
        let reference = """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>
          <forwarded xmlns='urn:xmpp:forward:0'>
            <message xmlns='jabber:client' type='chat' from='source-group@example.test' to='\(owner)' id='group'>
              <body>original</body><x xmlns='https://xabber.com/protocol/groups'>\(authorXML)</x>
            </message>
          </forwarded>
        </reference>
        """
        let message = try message(bodyXML: "fallback", references: reference)
        message.addChild(ForwardContactDataCodec.encode(card))
        return message
    }

    private func message(bodyXML: String, references: String) throws -> XMPPMessage {
        XMPPMessage(from: try DDXMLElement(xmlString: """
        <message xmlns='jabber:client' from='forwarder@example.test' to='\(owner)' id='carrier'>
          <body>\(bodyXML)</body>\(references)
        </message>
        """))
    }

    private func forward(begin: Int, end: Int, id: String) -> String {
        """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='\(begin)' end='\(end)'>
          \(forwarded(id: id))
        </reference>
        """
    }

    private func forwarded(id: String) -> String {
        """
        <forwarded xmlns='urn:xmpp:forward:0'>
          <message xmlns='jabber:client' from='alice@example.test' to='\(owner)' id='\(id)'><body>original</body></message>
        </forwarded>
        """
    }

    private func displayBody(_ message: XMPPMessage) -> String {
        (message.body ?? "").xmlEscaping(reverse: false).excludeFromBody(
            SCEReceivePolicy.children(of: message, named: "reference", xmlns: "https://xabber.com/protocol/references"),
            groupchat: nil
        )
    }
}
