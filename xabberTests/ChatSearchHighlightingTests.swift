import XCTest
import UIKit
@testable import xabber

final class ChatSearchHighlightingTests: XCTestCase {
    private let fixedStyle = ChatSearchHighlightStyle(
        backgroundColor: UIColor(red: 1.0, green: 0.82, blue: 0.2, alpha: 1),
        foregroundColor: UIColor(red: 0.16, green: 0.12, blue: 0.0, alpha: 1)
    )

    func testRangeFinderReturnsEveryCaseInsensitiveOccurrence() {
        let text = "Test test TEST"

        let ranges = ChatSearchQueryRangeFinder.ranges(
            in: text,
            query: "test",
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ranges, [
            NSRange(location: 0, length: 4),
            NSRange(location: 5, length: 4),
            NSRange(location: 10, length: 4)
        ])
    }

    func testRangeFinderIsDiacriticInsensitive() {
        let text = "café CAFE cafe\u{301}"

        let ranges = ChatSearchQueryRangeFinder.ranges(
            in: text,
            query: "cafe",
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["café", "CAFE", "cafe\u{301}"])
    }

    func testRangeFinderNeverSplitsComposedEmojiRanges() {
        let text = "a 👨‍👩‍👧‍👦 b 👨‍👩‍👧‍👦 c"

        let ranges = ChatSearchQueryRangeFinder.ranges(
            in: text,
            query: "👨‍👩‍👧‍👦",
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { Range($0, in: text) != nil })
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["👨‍👩‍👧‍👦", "👨‍👩‍👧‍👦"])
    }

    func testRangeFinderUsesDeterministicNonOverlappingProgress() {
        let ranges = ChatSearchQueryRangeFinder.ranges(
            in: "aaaa",
            query: "aa",
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ranges, [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2)
        ])
    }

    func testRangeFinderCoversMultilineBody() {
        let text = "test first\nsecond TEST\nthird test"

        let ranges = ChatSearchQueryRangeFinder.ranges(
            in: text,
            query: "test",
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0).lowercased() }, ["test", "test", "test"])
    }

    func testWhitespaceAndEmptyQueryProduceNoRanges() {
        XCTAssertTrue(ChatSearchQueryRangeFinder.ranges(in: "test", query: "").isEmpty)
        XCTAssertTrue(ChatSearchQueryRangeFinder.ranges(in: "test", query: " \n\t ").isEmpty)
        XCTAssertTrue(ChatSearchQueryRangeFinder.ranges(in: "", query: "test").isEmpty)
    }

    func testHighlighterAddsYellowStyleToEveryOccurrence() throws {
        let source = NSAttributedString(
            string: "Test test TEST",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )

        let highlighted = ChatSearchHighlighter.applying(
            to: source,
            query: "test",
            style: fixedStyle,
            locale: Locale(identifier: "en_US_POSIX")
        )

        let ranges = ChatSearchQueryRangeFinder.ranges(in: highlighted.string, query: "test")
        XCTAssertEqual(ranges.count, 3)
        for range in ranges {
            let attributes = highlighted.attributes(at: range.location, effectiveRange: nil)
            XCTAssertEqual(attributes[.backgroundColor] as? UIColor, fixedStyle.backgroundColor)
            XCTAssertEqual(attributes[.foregroundColor] as? UIColor, fixedStyle.foregroundColor)
            XCTAssertNotNil(attributes[ChatSearchHighlighter.markerAttribute])
        }
    }

    func testHighlighterPreservesLinkAndMentionAttributes() {
        let text = NSMutableAttributedString(string: "visit test and @test")
        let linkRange = (text.string as NSString).range(of: "test")
        let mentionRange = (text.string as NSString).range(of: "@test")
        text.addAttribute(.link, value: URL(string: "https://example.com/test")!, range: linkRange)
        text.addAttribute(.xabberChatSearchTestMention, value: "romeo@example.com", range: mentionRange)

        let highlighted = ChatSearchHighlighter.applying(
            to: text,
            query: "test",
            style: fixedStyle
        )

        XCTAssertNotNil(highlighted.attribute(.link, at: linkRange.location, effectiveRange: nil))
        XCTAssertEqual(
            highlighted.attribute(.xabberChatSearchTestMention, at: mentionRange.location, effectiveRange: nil) as? String,
            "romeo@example.com"
        )
        XCTAssertNotNil(highlighted.attribute(.backgroundColor, at: linkRange.location, effectiveRange: nil))
        XCTAssertNotNil(highlighted.attribute(.backgroundColor, at: mentionRange.location + 1, effectiveRange: nil))
    }

    func testQueryReplacementRestoresOldSemanticAttributesAndHighlightsNewRanges() {
        let source = NSMutableAttributedString(string: "old new")
        let oldRange = NSRange(location: 0, length: 3)
        let newRange = NSRange(location: 4, length: 3)
        source.addAttribute(.backgroundColor, value: UIColor.systemPurple, range: oldRange)
        source.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: oldRange)

        let oldHighlighted = ChatSearchHighlighter.applying(
            to: source,
            query: "old",
            style: fixedStyle
        )
        let replaced = ChatSearchHighlighter.applying(
            to: oldHighlighted,
            query: "new",
            style: fixedStyle
        )

        XCTAssertEqual(replaced.attribute(.backgroundColor, at: oldRange.location, effectiveRange: nil) as? UIColor, .systemPurple)
        XCTAssertEqual(replaced.attribute(.foregroundColor, at: oldRange.location, effectiveRange: nil) as? UIColor, .systemBlue)
        XCTAssertNil(replaced.attribute(ChatSearchHighlighter.markerAttribute, at: oldRange.location, effectiveRange: nil))
        XCTAssertEqual(replaced.attribute(.backgroundColor, at: newRange.location, effectiveRange: nil) as? UIColor, fixedStyle.backgroundColor)
        XCTAssertNotNil(replaced.attribute(ChatSearchHighlighter.markerAttribute, at: newRange.location, effectiveRange: nil))
    }

    func testRemovingHighlightRestoresOriginalAttributes() {
        let source = NSMutableAttributedString(string: "test plain")
        let queryRange = NSRange(location: 0, length: 4)
        source.addAttribute(.backgroundColor, value: UIColor.systemTeal, range: queryRange)
        source.addAttribute(.foregroundColor, value: UIColor.systemIndigo, range: queryRange)

        let highlighted = ChatSearchHighlighter.applying(to: source, query: "test", style: fixedStyle)
        let cleared = ChatSearchHighlighter.removing(from: highlighted)

        XCTAssertEqual(cleared.string, source.string)
        XCTAssertEqual(cleared.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? UIColor, .systemTeal)
        XCTAssertEqual(cleared.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .systemIndigo)
        XCTAssertNil(cleared.attribute(ChatSearchHighlighter.markerAttribute, at: 0, effectiveRange: nil))
    }

    func testEmptyBodyAndWhitespaceQueryAreNoOp() {
        let empty = NSAttributedString(string: "")
        let source = NSAttributedString(string: "test", attributes: [.link: "https://example.com"])

        XCTAssertEqual(ChatSearchHighlighter.applying(to: empty, query: "test", style: fixedStyle), empty)
        XCTAssertEqual(ChatSearchHighlighter.applying(to: source, query: "  ", style: fixedStyle), source)
    }

    func testSelectionIdentityDoesNotChangeHighlightRanges() {
        let source = NSAttributedString(string: "test test")

        let first = ChatSearchHighlighter.applying(to: source, query: "test", style: fixedStyle)
        let second = ChatSearchHighlighter.applying(to: source, query: "test", style: fixedStyle)

        XCTAssertEqual(markedRanges(in: first), markedRanges(in: second))
        XCTAssertEqual(markedRanges(in: first).count, 2)
    }

    func testTextCellPrepareForReuseClearsHighlightedAttributedText() {
        let cell = TextMessageCell(frame: .zero)
        cell.messageLabel.attributedText = ChatSearchHighlighter.applying(
            to: NSAttributedString(string: "test"),
            query: "test",
            style: fixedStyle
        )

        cell.prepareForReuse()

        XCTAssertNil(cell.messageLabel.attributedText)
        XCTAssertEqual(cell.contentView.backgroundColor ?? .clear, .clear)
    }

    func testLightAndDarkStylesAreDistinctAndMeetTextContrast() {
        let light = ChatSearchHighlightStyle.telegram(
            for: UITraitCollection(userInterfaceStyle: .light)
        )
        let dark = ChatSearchHighlightStyle.telegram(
            for: UITraitCollection(userInterfaceStyle: .dark)
        )

        XCTAssertFalse(light.backgroundColor.isEqual(dark.backgroundColor))
        XCTAssertGreaterThanOrEqual(contrastRatio(light.foregroundColor, light.backgroundColor), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(dark.foregroundColor, dark.backgroundColor), 4.5)
    }

    private func markedRanges(in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(
            ChatSearchHighlighter.markerAttribute,
            in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        return ranges
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) /
            (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

private extension NSAttributedString.Key {
    static let xabberChatSearchTestMention = NSAttributedString.Key("xabber.test.mention")
}
