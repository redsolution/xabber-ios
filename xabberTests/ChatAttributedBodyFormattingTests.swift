import XCTest
@testable import xabber

@MainActor
final class ChatAttributedBodyFormattingTests: XCTestCase {
    func testLeadingTrailingNewlinesAndZWJMentionKeepSourceUTF16Range() throws {
        let body = "\n👨‍👩‍👧 @Alex\n"
        let mentionRange = (body as NSString).range(of: "@Alex")
        let baseFont = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )

        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [
                .mention(
                    begin: mentionRange.location,
                    end: NSMaxRange(mentionRange),
                    destination: "xmpp:alex@example.com"
                )
            ],
            attributes: [.font: baseFont, .foregroundColor: UIColor.label]
        )

        XCTAssertEqual(rendered.string, body)
        XCTAssertEqual(rendered.attribute(.link, at: mentionRange.location, effectiveRange: nil) as? String, "xmpp:alex@example.com")
        let mentionFont = try XCTUnwrap(rendered.attribute(.font, at: mentionRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(mentionFont.pointSize, baseFont.pointSize)
        XCTAssertTrue(mentionFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testRangesAreUTF16SafeForCombiningMarksAndRTL() throws {
        let body = "e\u{301} مرحبا"
        let combiningRange = (body as NSString).range(of: "e\u{301}")
        let rtlRange = (body as NSString).range(of: "مرحبا")
        let baseFont = UIFont.preferredFont(forTextStyle: .body)

        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [
                .markup(begin: combiningRange.location, end: NSMaxRange(combiningRange), styles: ["italic"]),
                .mention(begin: rtlRange.location, end: NSMaxRange(rtlRange), destination: "xmpp:rtl@example.com")
            ],
            attributes: [.font: baseFont]
        )

        let combiningFont = try XCTUnwrap(rendered.attribute(.font, at: combiningRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(combiningFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(rendered.attribute(.link, at: rtlRange.location, effectiveRange: nil) as? String, "xmpp:rtl@example.com")
    }

    func testMalformedRangesAreIgnoredAndPartiallyOutOfBoundsRangesAreClipped() {
        let body = "abcdef"
        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [
                .markup(begin: 4, end: 2, styles: ["bold"]),
                .markup(begin: 99, end: 120, styles: ["italic"]),
                .markup(begin: -3, end: 2, styles: ["underline"]),
                .markup(begin: 4, end: 40, styles: ["strike"])
            ],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )

        XCTAssertEqual(rendered.string, body)
        XCTAssertEqual(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(rendered.attribute(.underlineStyle, at: 2, effectiveRange: nil))
        XCTAssertEqual(rendered.attribute(.strikethroughStyle, at: 5, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertFalse((rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    func testBoldItalicAndMentionDeriveTraitsFromDynamicTypeBaseFont() throws {
        let body = "bold mention"
        let baseFont = UIFont.preferredFont(
            forTextStyle: .title2,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)
        )
        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [
                .markup(begin: 0, end: 4, styles: ["bold", "italic"]),
                .mention(begin: 5, end: 12, destination: "xmpp:mention@example.com")
            ],
            attributes: [.font: baseFont]
        )

        let markupFont = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(markupFont.pointSize, baseFont.pointSize)
        XCTAssertTrue(markupFont.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]))
        let mentionFont = try XCTUnwrap(rendered.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(mentionFont.pointSize, baseFont.pointSize)
        XCTAssertTrue(mentionFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testAllCaseAndDiacriticInsensitiveMatchesAreHighlighted() {
        let body = "test TÉST te\u{301}st test"
        let highlight = UIColor.systemGreen
        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
            searchedText: "test",
            searchedTextColor: highlight
        )
        var highlightedRanges: [NSRange] = []
        rendered.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if let value = value as? UIColor, value.isEqual(highlight) {
                highlightedRanges.append(range)
            }
        }

        XCTAssertEqual(highlightedRanges.count, 4)
        XCTAssertEqual(highlightedRanges.map { (rendered.string as NSString).substring(with: $0) }, ["test", "TÉST", "te\u{301}st", "test"])
        XCTAssertTrue(ChatAttributedBodyFormatter.containsMatch(in: body, query: "tést"))
        XCTAssertFalse(ChatAttributedBodyFormatter.containsMatch(in: body, query: "missing"))
    }

    func testOverlapPrecedenceKeepsMentionDestinationAndSearchAsOverlay() throws {
        let body = "open @Alex now"
        let mentionRange = (body as NSString).range(of: "@Alex")
        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [
                .markup(begin: 0, end: 10, styles: ["bold", "uri"], destination: "https://markup.example"),
                .mention(
                    begin: mentionRange.location,
                    end: NSMaxRange(mentionRange),
                    destination: "xmpp:alex@example.com",
                    color: .systemPurple
                )
            ],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label],
            searchedText: "alex",
            searchedTextColor: .systemYellow
        )

        XCTAssertEqual(rendered.attribute(.link, at: 1, effectiveRange: nil) as? String, "https://markup.example")
        XCTAssertEqual(rendered.attribute(.link, at: mentionRange.location, effectiveRange: nil) as? String, "xmpp:alex@example.com")
        XCTAssertTrue((rendered.attribute(.foregroundColor, at: mentionRange.location, effectiveRange: nil) as? UIColor)?.isEqual(UIColor.systemPurple) == true)
        XCTAssertTrue((rendered.attribute(.backgroundColor, at: mentionRange.location + 1, effectiveRange: nil) as? UIColor)?.isEqual(UIColor.systemYellow) == true)
        let font = try XCTUnwrap(rendered.attribute(.font, at: mentionRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testPlainURLGetsSemanticLinkWithoutOverwritingExplicitDestination() {
        let body = "https://plain.example explicit"
        let explicitRange = (body as NSString).range(of: "explicit")
        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: [
                .markup(
                    begin: explicitRange.location,
                    end: NSMaxRange(explicitRange),
                    styles: ["uri"],
                    destination: "https://semantic.example"
                )
            ],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )

        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://plain.example"))
        XCTAssertEqual(rendered.attribute(.link, at: explicitRange.location, effectiveRange: nil) as? String, "https://semantic.example")
    }

    func testRegularSavedStorageAndForwardPathsHaveFormattingParity() throws {
        let body = "\nOpen test test\n"
        let openRange = (body as NSString).range(of: "Open")
        let baseAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.preferredFont(forTextStyle: .body)]

        let item = MessageStorageItem()
        item.body = body
        item.owner = "owner@example.com"
        item.opponent = "alex@example.com"
        item.conversationType = .regular
        item.references.append(makeMarkupReference(range: openRange))
        let presentation = SavedMessageDisplayPolicy.presentation(for: item, currentUserJid: item.owner)
        let snapshot = ChatMessageDisplaySnapshot(item: item, presentation: presentation)

        let forward = MessageForwardsInlineStorageItem()
        forward.body = body
        forward.owner = item.owner
        forward.references.append(makeMarkupReference(range: openRange))

        let outputs = [
            item.createRefBody(baseAttributes, searchedText: "test", searchedTextColor: .systemGreen),
            SavedMessageDisplayPolicy.attributedBody(for: presentation, attributes: baseAttributes, searchedText: "test", searchedTextColor: .systemGreen),
            snapshot.attributedBody(attributes: baseAttributes, searchedText: "test", searchedTextColor: .systemGreen),
            forward.createRefBody(baseAttributes, searchedText: "test", searchedTextColor: .systemGreen)
        ]

        XCTAssertTrue(outputs.allSatisfy { $0.string == body })
        for output in outputs {
            XCTAssertEqual(output.attribute(.link, at: openRange.location, effectiveRange: nil) as? String, "https://example.com")
            XCTAssertTrue((output.attribute(.font, at: openRange.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
            XCTAssertEqual(highlightCount(in: output, color: .systemGreen), 2)
        }
    }

    func testAttributedRangeFontAndLinkDestinationChangeContentSignature() {
        let first = makeDatasource(attributedText: attributed("same", link: "https://one.example", range: NSRange(location: 0, length: 2), font: .systemFont(ofSize: 17)))
        let changedLink = makeDatasource(attributedText: attributed("same", link: "https://two.example", range: NSRange(location: 0, length: 2), font: .systemFont(ofSize: 17)))
        let changedRange = makeDatasource(attributedText: attributed("same", link: "https://one.example", range: NSRange(location: 1, length: 2), font: .systemFont(ofSize: 17)))
        let changedFont = makeDatasource(attributedText: attributed("same", link: "https://one.example", range: NSRange(location: 0, length: 2), font: .systemFont(ofSize: 21)))

        let firstSignature = ChatMessageUpdatePolicy.contentSignature(for: first)
        XCTAssertNotEqual(firstSignature, ChatMessageUpdatePolicy.contentSignature(for: changedLink))
        XCTAssertNotEqual(firstSignature, ChatMessageUpdatePolicy.contentSignature(for: changedRange))
        XCTAssertNotEqual(firstSignature, ChatMessageUpdatePolicy.contentSignature(for: changedFont))
        XCTAssertTrue(ChatMessageUpdatePolicy.shouldUpdateContent(old: first, new: changedLink))
    }

    private func makeMarkupReference(range: NSRange) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .markup
        reference.range = range
        reference.metadata = ["styles": ["bold", "uri"], "uri": "https://example.com"]
        return reference
    }

    private func highlightCount(in string: NSAttributedString, color: UIColor) -> Int {
        var count = 0
        string.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let value = value as? UIColor, value.isEqual(color) { count += 1 }
        }
        return count
    }

    private func attributed(_ text: String, link: String, range: NSRange, font: UIFont) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text, attributes: [.font: font])
        value.addAttribute(.link, value: link, range: range)
        return value
    }

    private func makeDatasource(attributedText: NSAttributedString) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: "message-1",
            jid: "alex@example.com",
            owner: "owner@example.com",
            outgoing: true,
            sender: Sender(id: "owner@example.com", displayName: "Owner"),
            messageId: "message-id",
            sentDate: Date(timeIntervalSince1970: 100),
            editDate: nil,
            kind: .attributedText(attributedText),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: true,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: true,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "archived-1",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            locations: [],
            contacts: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .read,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }
}
