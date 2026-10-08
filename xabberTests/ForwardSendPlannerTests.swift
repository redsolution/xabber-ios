import Foundation
import XCTest
import XMPPFramework
@testable import xabber

/// Outgoing forwarding is planned before transport, encryption or Realm writes.
/// These tests inspect real, qualified wire payloads rather than UI models.
final class ForwardSendPlannerTests: XCTestCase {
    private let referencesNS = "https://xabber.com/protocol/references"
    private let forwardNS = "urn:xmpp:forward:0"
    private let cardsNS = "urn:ietf:params:xml:ns:vcard-4.0"
    private let groupsNS = "https://xabber.com/protocol/groups"
    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_700_000_100)

    func testCurrentLevelEntriesUseAscendingDatesAndStableSelectionOrderForTies() throws {
        let sources = try [
            snapshot(id: "new", body: "new", date: newer),
            snapshot(id: "tie-a", body: "tie a", date: older),
            snapshot(id: "tie-b", body: "tie b", date: older),
        ]

        let units = try ForwardSendPlanner.plan(sources: sources, comment: "my comment")

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual((try requiredUnit(units, at: 0)).kind, .forwardEnvelope)
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).map { $0.attributeStringValue(forName: "id") },
                       ["tie-a", "tie-b", "new"])
        XCTAssertTrue((try requiredUnit(units, at: 0)).body.hasSuffix("my comment"))
        try assertFlat(units)
    }

    func testSnapshotDoesNotChangeWhenOriginalMessageIsMutated() throws {
        let original = try message(id: "immutable", body: "captured content")
        let source = ForwardSourceSnapshot(message: original, date: older, selectionID: "selected")
        original.element(forName: "body", xmlns: "jabber:client")?.stringValue = "later mutation"
        original.addAttribute(withName: "from", stringValue: "mallory@example.test/changed")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        let entry = try XCTUnwrap(try entries(try XCTUnwrap(units.first)).first)
        XCTAssertEqual(body(entry), "captured content")
        XCTAssertEqual(entry.attributeStringValue(forName: "from"), "alice@example.test/laptop")
    }

    func testForwardKeepsFullOriginalAddressingIDAndUnknownExtension() throws {
        let original = try message(id: "preserved", body: "hello", additionalXML: """
            <payload xmlns='urn:example:original-extension' token='kept'><value>original</value></payload>
            """)
        let source = ForwardSourceSnapshot(message: original, date: older, selectionID: "source")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        let entry = try XCTUnwrap(try entries(try XCTUnwrap(units.first)).first)
        XCTAssertEqual(entry.attributeStringValue(forName: "from"), "alice@example.test/laptop")
        XCTAssertEqual(entry.attributeStringValue(forName: "to"), "bob@example.test/phone")
        XCTAssertEqual(entry.attributeStringValue(forName: "id"), "preserved")
        XCTAssertEqual(entry.element(forName: "payload", xmlns: "urn:example:original-extension")?
            .attributeStringValue(forName: "token"), "kept")
    }

    func testPureForwardDonatesOneEnvelopeAndTypedCommentIsTrailingPlainMessage() throws {
        let original = try message(id: "original", body: "original")
        let carrier = try quotedCarrier(id: "carrier", original: original, ownText: "")
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "new comment")

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual((try requiredUnit(units, at: 0)).kind, .forwardEnvelope)
        XCTAssertEqual((try requiredUnit(units, at: 1)).kind, .plain)
        XCTAssertEqual((try requiredUnit(units, at: 1)).body, "new comment")
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).map { $0.attributeStringValue(forName: "id") }, ["original"])
        XCTAssertEqual(try XCTUnwrap(try entries((try requiredUnit(units, at: 0))).first).xmlString, original.xmlString)
        try assertFlat(units)
    }

    func testDonatedEnvelopePrecedesSeparateCurrentLevelCommentEnvelope() throws {
        let original = try message(id: "original", body: "original")
        let carrier = try quotedCarrier(id: "carrier", original: original, ownText: "carrier comment")
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "new comment")

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).map(body), ["original"])
        XCTAssertEqual(try entries((try requiredUnit(units, at: 1))).map(body), ["carrier comment"])
        XCTAssertTrue((try requiredUnit(units, at: 1)).body.hasSuffix("new comment"))
        try assertFlat(units)
    }

    func testOwnCommentEqualToOriginalTextIsPreservedByReferenceRanges() throws {
        let original = try message(id: "original", body: "original")
        let carrier = try quotedCarrier(id: "carrier", original: original, ownText: "original")
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).map(body), ["original"])
        XCTAssertEqual(try entries((try requiredUnit(units, at: 1))).map(body), ["original"])
        XCTAssertEqual(try entries((try requiredUnit(units, at: 1))).first?.attributeStringValue(forName: "id"), "carrier")
    }

    func testHistoricNestedForwardBecomesFlatUnitsWithoutLosingComments() throws {
        let original = try message(id: "original", body: "original")
        let middle = try quotedCarrier(id: "middle", original: original, ownText: "middle comment")
        let outer = try quotedCarrier(id: "outer", original: middle, ownText: "outer comment")
        let source = ForwardSourceSnapshot(message: outer, date: newer, selectionID: "outer")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "new comment")

        XCTAssertEqual(try units.flatMap { try entries($0).map(body) },
                       ["original", "middle comment", "outer comment"])
        XCTAssertTrue(try XCTUnwrap(units.last).body.hasSuffix("new comment"))
        try assertFlat(units)
    }

    func testDonatedEnvelopeKeepsAssociatedDataCardWithoutWrappingItIntoAnotherForward() throws {
        let original = try message(id: "original", body: "original")
        let card = """
            <reference xmlns='https://xabber.com/protocol/references' type='data'>
              <vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>
                <fn><text>Alice</text></fn><impp><uri>xmpp:alice@example.test</uri></impp>
              </vcard>
            </reference>
            """
        let carrier = try quotedCarrier(id: "carrier", original: original, ownText: "", additionalXML: card)
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        XCTAssertEqual(units.count, 1)
        let output = rendered((try requiredUnit(units, at: 0)))
        let cards = children(output, named: "reference", namespace: referencesNS).filter {
            $0.attributeStringValue(forName: "type") == "data" &&
                $0.element(forName: "vcard", xmlns: cardsNS) != nil
        }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.element(forName: "vcard", xmlns: cardsNS)?
            .element(forName: "fn")?.element(forName: "text")?.stringValue, "Alice")
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).count, 1)
        try assertFlat(units)
    }

    func testHideCommentsRemovesCurrentTextButKeepsMediaAndDonatedEnvelope() throws {
        let original = try message(id: "original", body: "original")
        let uri = "https://files.example.test/image.png"
        let prefix = "> Alice:\n> original\n"
        let mediaEnd = 26 + uri.unicodeScalars.count
        let carrier = try message(id: "carrier", body: prefix + uri + "\nprivate carrier comment", additionalXML: """
            \(forwardReference(original: original, end: 26))
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='26' end='\(mediaEnd)'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file><media-type>image/png</media-type><name>image.png</name></file>
                <sources><uri>\(uri)</uri></sources>
              </file-sharing>
            </reference>
            """)
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "new comment",
            options: ForwardSendOptions(hideComments: true))

        XCTAssertEqual(units.count, 2)
        let donated = try XCTUnwrap(units.first)
        let attachmentUnit = try XCTUnwrap(units.dropFirst().first)
        XCTAssertEqual(try entries(donated).map(body), ["original"])
        let attachmentEntry = try XCTUnwrap(try entries(attachmentUnit).first)
        XCTAssertFalse(body(attachmentEntry).contains("private carrier comment"))
        XCTAssertTrue(body(attachmentEntry).contains(uri))
        XCTAssertEqual(children(attachmentEntry, named: "reference", namespace: referencesNS).filter {
            $0.element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files") != nil
        }.count, 1)
        XCTAssertTrue(attachmentUnit.body.hasSuffix("new comment"))
        try assertFlat(units)
    }

    func testHideCommentsOnTextOnlySourceLeavesOnlyNewComment() throws {
        let source = try snapshot(id: "text", body: "private original comment", date: older)

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "new comment",
            options: ForwardSendOptions(hideComments: true))

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual((try requiredUnit(units, at: 0)).kind, .plain)
        XCTAssertEqual((try requiredUnit(units, at: 0)).body, "new comment")
        XCTAssertFalse(rendered((try requiredUnit(units, at: 0))).xmlString.contains("private original comment"))
    }

    func testHideSenderFlattensEveryLevelIntoPlainMessagesAndNewCommentIsLast() throws {
        let original = try message(id: "original", body: "original")
        let middle = try quotedCarrier(id: "middle", original: original, ownText: "middle comment")
        let outer = try quotedCarrier(id: "outer", original: middle, ownText: "outer comment")
        let source = ForwardSourceSnapshot(message: outer, date: newer, selectionID: "outer")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "new comment",
            options: ForwardSendOptions(hideSender: true))

        XCTAssertEqual(units.map(\.body), ["original", "middle comment", "outer comment", "new comment"])
        for unit in units {
            XCTAssertEqual(unit.kind, .plain)
            let output = rendered(unit)
            XCTAssertTrue(try entries(unit).isEmpty)
            XCTAssertNil(output.attribute(forName: "from"))
            XCTAssertNil(output.attribute(forName: "to"))
            XCTAssertNil(output.attribute(forName: "id"))
            XCTAssertFalse(output.xmlString.contains("alice@example.test"))
        }
    }

    func testHideSenderRemovesGroupAuthorAndDataCardsButRetainsFileContent() throws {
        let uri = "https://files.example.test/file.pdf"
        let sourceMessage = try message(id: "group", body: uri, additionalXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='data'>
              <user xmlns='https://xabber.com/protocol/groups' id='member-1'>
                <jid>alice@example.test</jid><nickname>Alice</nickname><role>owner</role><badge>VIP</badge>
              </user>
            </reference>
            <reference xmlns='https://xabber.com/protocol/references' type='data'>
              <vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>
                <fn><text>Alice</text></fn><impp><uri>xmpp:alice@example.test</uri></impp>
              </vcard>
            </reference>
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(uri.unicodeScalars.count)'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file><media-type>application/pdf</media-type><name>file.pdf</name></file>
                <sources><uri>\(uri)</uri></sources>
              </file-sharing>
            </reference>
            """)
        let source = ForwardSourceSnapshot(message: sourceMessage, date: older, selectionID: "group")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "",
            options: ForwardSendOptions(hideSender: true))

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual((try requiredUnit(units, at: 0)).kind, .plain)
        let output = rendered((try requiredUnit(units, at: 0)))
        XCTAssertTrue(output.xmlString.contains(uri))
        XCTAssertFalse(output.xmlString.contains("member-1"))
        XCTAssertFalse(output.xmlString.contains("alice@example.test"))
        XCTAssertFalse(output.xmlString.contains(cardsNS))
        XCTAssertFalse(output.xmlString.contains(groupsNS))
    }

    func testForwardStripsGroupRoleButPreservesBadgeJIDAndForeignRole() throws {
        let sourceMessage = try message(id: "group", body: "hello", additionalXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='data'>
              <user xmlns='https://xabber.com/protocol/groups' id='member-1'>
                <jid>alice@example.test</jid><nickname>Alice</nickname><role>owner</role><badge>VIP</badge>
              </user>
            </reference>
            <status xmlns='urn:example:original-extension'><role>keep this</role></status>
            """)
        let source = ForwardSourceSnapshot(message: sourceMessage, date: older, selectionID: "group")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        let entry = try XCTUnwrap(try entries(try XCTUnwrap(units.first)).first)
        let user = try XCTUnwrap(children(entry, named: "reference", namespace: referencesNS)
            .compactMap { $0.element(forName: "user", xmlns: groupsNS) }.first)
        XCTAssertNil(user.element(forName: "role", xmlns: groupsNS))
        XCTAssertEqual(user.element(forName: "badge", xmlns: groupsNS)?.stringValue, "VIP")
        XCTAssertEqual(user.element(forName: "jid", xmlns: groupsNS)?.stringValue, "alice@example.test")
        XCTAssertEqual(entry.element(forName: "status", xmlns: "urn:example:original-extension")?
            .element(forName: "role")?.stringValue, "keep this")
    }

    func testReplyIsOneFlatUnsplittableEnvelopeWithSelectedOwnComment() throws {
        let original = try message(id: "original", body: "original")
        let carrier = try quotedCarrier(id: "carrier", original: original, ownText: "carrier comment")
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "reply", intent: .reply)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual((try requiredUnit(units, at: 0)).kind, .forwardEnvelope)
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).map(body), ["original", "carrier comment"])
        XCTAssertTrue((try requiredUnit(units, at: 0)).body.hasSuffix("reply"))
        try assertFlat(units)
    }

    func testOversizedReplyThrowsInsteadOfSplittingOrTruncating() throws {
        let source = try snapshot(id: "large", body: String(repeating: "🙂", count: 1_000), date: older)

        XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: [source], comment: "reply",
            intent: .reply, byteBudget: 1_024))
    }

    func testNewEnvelopeSplitsByUTF8BudgetAndCommentOnlyAppearsInFinalChunk() throws {
        let text = String(repeating: "🙂", count: 100)
        let sources = try [
            snapshot(id: "one", body: "one " + text, date: older),
            snapshot(id: "two", body: "two " + text, date: newer),
            snapshot(id: "three", body: "three " + text, date: newer),
        ]
        let budget = 1_600

        let units = try ForwardSendPlanner.plan(sources: sources, comment: "ONLY FINAL COMMENT", byteBudget: budget)

        XCTAssertGreaterThan(units.count, 1)
        XCTAssertEqual(try units.flatMap { try entries($0).map { $0.attributeStringValue(forName: "id") } },
                       ["one", "two", "three"])
        for unit in units {
            XCTAssertLessThanOrEqual(renderedContentByteCount(unit), budget)
        }
        XCTAssertTrue(try XCTUnwrap(units.last).body.hasSuffix("ONLY FINAL COMMENT"))
        XCTAssertTrue(units.dropLast().allSatisfy { !$0.body.contains("ONLY FINAL COMMENT") })
        try assertFlat(units)
    }

    func testPreviouslyDeliverableDonatedEnvelopeIsNotSplitByNewEnvelopeBudget() throws {
        let original = try message(id: "original", body: String(repeating: "🙂", count: 1_000))
        let carrier = try quotedCarrier(id: "carrier", original: original, ownText: "")
        let source = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "carrier")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "", byteBudget: 1_024)

        XCTAssertEqual(units.count, 1)
        XCTAssertGreaterThan(renderedContentByteCount((try requiredUnit(units, at: 0))), 1_024)
        XCTAssertEqual(try XCTUnwrap(try entries((try requiredUnit(units, at: 0))).first).xmlString, original.xmlString)
    }

    func testOversizedNewSingleEntryThrowsWithoutTruncatingSource() throws {
        let text = String(repeating: "🙂", count: 1_000)
        let source = try snapshot(id: "large", body: text, date: older)

        XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: [source], comment: "", byteBudget: 1_024))
    }

    func testForwardRangesUseEscapedUnicodeScalarsAndStayContiguous() throws {
        let sources = try [
            snapshot(id: "special", body: "A & <B> 🙂 é", date: older),
            snapshot(id: "second", body: "second 👨‍👩‍👧", date: newer),
        ]

        let units = try ForwardSendPlanner.plan(sources: sources, comment: "tail & 🙂")

        let unit = try XCTUnwrap(units.first)
        let escaped = Array(escape(unit.body).unicodeScalars)
        let references = forwardReferences(rendered(unit))
        XCTAssertEqual(references.count, 2)
        var previousEnd = 0
        for reference in references {
            let begin = try XCTUnwrap(reference.attributeStringValue(forName: "begin").flatMap(Int.init))
            let end = try XCTUnwrap(reference.attributeStringValue(forName: "end").flatMap(Int.init))
            XCTAssertEqual(begin, previousEnd)
            XCTAssertGreaterThan(end, begin)
            XCTAssertLessThanOrEqual(end, escaped.count)
            previousEnd = end
        }
        XCTAssertEqual(String(String.UnicodeScalarView(escaped[previousEnd...])), "tail &amp; 🙂")
    }

    func testMissingOriginalTimestampDoesNotInventForwardedDelay() throws {
        let source = try snapshot(id: "unknown-time", body: "hello", date: nil)

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        let reference = try XCTUnwrap(forwardReferences(rendered(try XCTUnwrap(units.first))).first)
        let forwarded = try XCTUnwrap(reference.element(forName: "forwarded", xmlns: forwardNS))
        XCTAssertNil(forwarded.element(forName: "delay", xmlns: "urn:xmpp:delay"))
    }

    func testForeignForwardLookalikeRemainsUnknownPayloadAndCannotDonateContent() throws {
        let sourceMessage = try message(id: "foreign", body: "own text", additionalXML: """
            <reference xmlns='urn:example:foreign' type='mutable' begin='0' end='8'>
              <forwarded xmlns='urn:xmpp:forward:0'>
                <message xmlns='jabber:client' from='mallory@example.test' to='bob@example.test' id='not-a-forward'>
                  <body>foreign content</body>
                </message>
              </forwarded>
            </reference>
            """)
        let source = ForwardSourceSnapshot(message: sourceMessage, date: older, selectionID: "foreign")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(try entries((try requiredUnit(units, at: 0))).map { $0.attributeStringValue(forName: "id") }, ["foreign"])
        let entry = try XCTUnwrap(try entries((try requiredUnit(units, at: 0))).first)
        XCTAssertEqual(body(entry), "own text")
        XCTAssertNotNil(entry.element(forName: "reference", xmlns: "urn:example:foreign"))
    }

    func testForeignBodyCannotOverrideQualifiedClientBody() throws {
        let sourceMessage = try stanza("""
            <c:message xmlns:c='jabber:client' from='alice@example.test/laptop' to='bob@example.test/phone' id='qname'>
              <body xmlns='urn:example:foreign'>foreign text</body><c:body>qualified text</c:body>
            </c:message>
            """)
        let source = ForwardSourceSnapshot(message: sourceMessage, date: older, selectionID: "qname")

        let units = try ForwardSendPlanner.plan(sources: [source], comment: "")

        XCTAssertEqual(try entries(try XCTUnwrap(units.first)).map(body), ["qualified text"])
    }

    func testMalformedSourceNamespaceOrMissingOriginalAddressingThrows() throws {
        for xml in [
            "<message xmlns='urn:example:foreign' from='alice@example.test' to='bob@example.test'><body>wrong namespace</body></message>",
            "<message xmlns='jabber:client' to='bob@example.test'><body>missing from</body></message>",
            "<message xmlns='jabber:client' from='alice@example.test'><body>missing to</body></message>",
        ] {
            let source = ForwardSourceSnapshot(message: try stanza(xml), date: older, selectionID: "malformed")
            XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: [source], comment: ""), xml)
        }
    }

    func testAmbiguousCanonicalForwardSourceCannotCreateANewNestedForward() throws {
        let original = try message(id: "original", body: "original")
        let carrier = try message(id: "overlapping", body: "> Alice:\n> original\n",
                                  additionalXML: forwardReference(original: original, end: 26)
                                    + forwardReference(original: original, end: 26))
        let source = ForwardSourceSnapshot(message: carrier, date: older, selectionID: "overlapping")

        XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: [source], comment: ""))
    }

    func testInvalidMediaRangeCannotProtectPrivateCommentFromHideComments() throws {
        let source = ForwardSourceSnapshot(message: try message(id: "bad-media", body: "private comment", additionalXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='9999'>
              <file-sharing xmlns='https://xabber.com/protocol/files'><file><name>file.pdf</name></file>
                <sources><uri>https://files.example.test/file.pdf</uri></sources></file-sharing>
            </reference>
            """), date: older, selectionID: "bad-media")

        XCTAssertThrowsError(try ForwardSendPlanner.plan(sources: [source], comment: "",
                                                        options: .init(hideComments: true)))
    }

    func testUnboundedDecorationRangeCannotBeScannedWhileFlatteningCarrier() throws {
        let original = try message(id: "original", body: "original")
        let carrier = try quotedCarrier(id: "bad-decoration", original: original, ownText: "comment", additionalXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='26' end='100000'>
              <bold xmlns='https://xabber.com/protocol/markup'/>
            </reference>
            """)

        XCTAssertThrowsError(try ForwardSendPlanner.plan(
            sources: [ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "bad-decoration")], comment: ""))
    }

    func testHideSenderSortsMixedOwnAndDonatedContentChronologically() throws {
        let oldest = try snapshot(id: "oldest", body: "old own text", date: older.addingTimeInterval(-100))
        let carrier = try quotedCarrier(id: "new-carrier", original: message(id: "child", body: "forwarded text"),
                                        ownText: "new own text")
        let newest = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "new-carrier")

        let units = try ForwardSendPlanner.plan(sources: [newest, oldest], comment: "last",
                                                options: .init(hideSender: true))

        XCTAssertEqual(units.map(\.body), ["old own text", "forwarded text", "new own text", "last"])
    }

    func testReplySortsMixedOwnAndDonatedContentChronologicallyInOneCarrier() throws {
        let oldest = try snapshot(id: "oldest", body: "old own text", date: older.addingTimeInterval(-100))
        let carrier = try quotedCarrier(id: "new-carrier", original: message(id: "child", body: "forwarded text"),
                                        ownText: "new own text")
        let newest = ForwardSourceSnapshot(message: carrier, date: newer, selectionID: "new-carrier")

        let units = try ForwardSendPlanner.plan(sources: [newest, oldest], comment: "last", intent: .reply)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(try entries(requiredUnit(units, at: 0)).map { body($0) },
                       ["old own text", "forwarded text", "new own text"])
        XCTAssertTrue(try requiredUnit(units, at: 0).body.hasSuffix("last"))
    }

    func testEmptySelectionAndCommentProduceNoMessage() throws {
        XCTAssertTrue(try ForwardSendPlanner.plan(sources: [], comment: "").isEmpty)
    }

    func testCommentWithoutSelectionIsOnePlainMessage() throws {
        let units = try ForwardSendPlanner.plan(sources: [], comment: "standalone")

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual((try requiredUnit(units, at: 0)).kind, .plain)
        XCTAssertEqual((try requiredUnit(units, at: 0)).body, "standalone")
        XCTAssertTrue(try entries((try requiredUnit(units, at: 0))).isEmpty)
    }

    func testAppendingPreparedContentDoesNotMoveItsReferencesOrTransportAttributes() throws {
        let source = try snapshot(id: "copy", body: "hello", date: older)
        let unit = try XCTUnwrap(ForwardSendPlanner.plan(sources: [source], comment: "comment").first)
        let first = rendered(unit)

        let second = rendered(unit)
        first.element(forName: "body", xmlns: "jabber:client")?.stringValue = "mutated output"
        forwardReferences(first).first?.detach()

        XCTAssertEqual(body(second), unit.body)
        XCTAssertEqual(try entries(unit).count, 1)
        XCTAssertNil(second.attribute(forName: "from"))
        XCTAssertNil(second.attribute(forName: "to"))
        XCTAssertNil(second.attribute(forName: "id"))
        XCTAssertEqual(children(second, named: "body", namespace: "jabber:client").count, 1)
    }

    // MARK: - Wire fixtures and assertions

    private func requiredUnit(_ units: [ForwardPreparedUnit], at index: Int,
                              file: StaticString = #filePath, line: UInt = #line) throws -> ForwardPreparedUnit {
        try XCTUnwrap(units.indices.contains(index) ? units[index] : nil, file: file, line: line)
    }

    private func snapshot(id: String, body: String, date: Date?) throws -> ForwardSourceSnapshot {
        ForwardSourceSnapshot(message: try message(id: id, body: body), date: date, selectionID: id)
    }

    private func message(id: String, body: String, additionalXML: String = "") throws -> XMPPMessage {
        try stanza("""
            <message xmlns='jabber:client' from='alice@example.test/laptop' to='bob@example.test/phone' type='chat' id='\(id)'>
              <body>\(escape(body))</body>\(additionalXML)
            </message>
            """)
    }

    private func quotedCarrier(id: String, original: XMPPMessage, ownText: String,
                               additionalXML: String = "") throws -> XMPPMessage {
        // Explicit escaped-scalar range: two '>' become '&gt;' (20 + 6 = 26).
        try message(id: id, body: "> Alice:\n> original\n" + ownText,
            additionalXML: forwardReference(original: original, end: 26) + additionalXML)
    }

    private func forwardReference(original: XMPPMessage, end: Int) -> String {
        """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(end)'>
              <forwarded xmlns='urn:xmpp:forward:0'>
                <delay xmlns='urn:xmpp:delay' stamp='2023-11-14T22:13:20Z'/>\(original.xmlString)
              </forwarded>
            </reference>
            """
    }

    private func stanza(_ xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func rendered(_ unit: ForwardPreparedUnit) -> XMPPMessage {
        let message = XMPPMessage(messageType: .chat, to: nil, elementID: nil, child: nil)
        message.setXmlns("jabber:client")
        unit.appendContent(to: message)
        return message
    }

    private func body(_ message: DDXMLElement) -> String {
        children(message, named: "body", namespace: "jabber:client").first?.stringValue ?? ""
    }

    private func children(_ element: DDXMLElement, named: String, namespace: String) -> [DDXMLElement] {
        (element.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
            $0.localName == named && $0.uri == namespace
        }
    }

    private func forwardReferences(_ element: DDXMLElement) -> [DDXMLElement] {
        children(element, named: "reference", namespace: referencesNS).filter {
            $0.attributeStringValue(forName: "type") == "mutable" &&
                $0.element(forName: "forwarded", xmlns: forwardNS) != nil
        }
    }

    private func entries(_ unit: ForwardPreparedUnit) throws -> [DDXMLElement] {
        try forwardReferences(rendered(unit)).map { reference in
            let forwarded = try XCTUnwrap(reference.element(forName: "forwarded", xmlns: forwardNS))
            let messages = children(forwarded, named: "message", namespace: "jabber:client")
            XCTAssertEqual(messages.count, 1)
            return try XCTUnwrap(messages.first)
        }
    }

    private func assertFlat(_ units: [ForwardPreparedUnit], file: StaticString = #filePath, line: UInt = #line) throws {
        for unit in units {
            for entry in try entries(unit) {
                XCTAssertTrue(forwardReferences(entry).isEmpty,
                              "New outgoing forwards must never wrap another forward", file: file, line: line)
            }
        }
    }

    private func renderedContentByteCount(_ unit: ForwardPreparedUnit) -> Int {
        unit.body.utf8.count + unit.refs.reduce(0) { $0 + $1.xmlString.utf8.count }
    }

    private func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
