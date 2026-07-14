import UIKit
import MaterialComponents.MDCPalettes

struct ChatAttributedBodyReference {
    enum Kind: Equatable {
        case markup
        case mention
    }

    let kind: Kind
    let begin: Int
    let end: Int
    let styles: [String]
    let destination: String?
    let mentionColor: UIColor?

    private init(
        kind: Kind,
        begin: Int,
        end: Int,
        styles: [String],
        destination: String?,
        mentionColor: UIColor?
    ) {
        self.kind = kind
        self.begin = begin
        self.end = end
        self.styles = styles
        self.destination = destination
        self.mentionColor = mentionColor
    }

    static func markup(
        begin: Int,
        end: Int,
        styles: [String],
        destination: String? = nil
    ) -> ChatAttributedBodyReference {
        ChatAttributedBodyReference(
            kind: .markup,
            begin: begin,
            end: end,
            styles: styles,
            destination: destination,
            mentionColor: nil
        )
    }

    static func mention(
        begin: Int,
        end: Int,
        destination: String?,
        color: UIColor? = nil
    ) -> ChatAttributedBodyReference {
        ChatAttributedBodyReference(
            kind: .mention,
            begin: begin,
            end: end,
            styles: [],
            destination: destination,
            mentionColor: color
        )
    }

    init(
        storageReference reference: MessageReferenceStorageItem,
        mentionColor: UIColor?
    ) {
        self.kind = reference.kind == .mention ? .mention : .markup
        self.begin = reference.begin
        self.end = reference.end
        self.styles = reference.metadata?["styles"] as? [String] ?? []
        self.destination = reference.metadata?["uri"] as? String ?? reference.url
        self.mentionColor = mentionColor
    }

    func intersectedRange(renderedUTF16Length: Int) -> NSRange? {
        guard begin < end, renderedUTF16Length > 0 else { return nil }
        let lowerBound = max(0, begin)
        let upperBound = min(renderedUTF16Length, end)
        guard lowerBound < upperBound else { return nil }
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }
}

enum ChatAttributedBodyFormatter {
    private static let plainURLDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Attribute precedence is intentionally stable: base attributes, markup,
    /// mention presentation/destination, plain URL fill, then search background.
    /// Search is an overlay and never replaces semantic font, color, or link data.
    static func format(
        body: String,
        references: [ChatAttributedBodyReference],
        attributes: [NSAttributedString.Key: Any],
        searchedText: String? = nil,
        searchedTextColor: UIColor? = nil,
        detectsPlainURLs: Bool = true
    ) -> NSAttributedString {
        let string = NSMutableAttributedString(string: body)
        let fullRange = NSRange(location: 0, length: string.length)
        if fullRange.length > 0 {
            string.addAttributes(attributes, range: fullRange)
        }

        let preparedReferences = references.compactMap { reference -> (ChatAttributedBodyReference, NSRange)? in
            guard let range = reference.intersectedRange(renderedUTF16Length: string.length) else {
                return nil
            }
            return (reference, range)
        }

        for (reference, range) in preparedReferences where reference.kind == .markup {
            applyMarkup(reference, range: range, to: string, fallbackAttributes: attributes)
        }
        for (reference, range) in preparedReferences where reference.kind == .mention {
            applyMention(reference, range: range, to: string, fallbackAttributes: attributes)
        }
        if detectsPlainURLs {
            applyPlainURLs(to: string)
        }
        if let searchedText, searchedText.isNotEmpty {
            applySearchHighlights(
                searchedText,
                color: searchedTextColor ?? MDCPalette.blue.tint200,
                to: string
            )
        }

        if fullRange.length > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 1.5
            paragraph.allowsDefaultTighteningForTruncation = true
            string.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        }
        return string
    }

    static func containsMatch(in body: String, query: String) -> Bool {
        guard query.isNotEmpty else { return false }
        return (body as NSString).range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ).location != NSNotFound
    }

    private static func applyMarkup(
        _ reference: ChatAttributedBodyReference,
        range: NSRange,
        to string: NSMutableAttributedString,
        fallbackAttributes: [NSAttributedString.Key: Any]
    ) {
        let styles = Set(reference.styles)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if styles.contains("bold") { traits.insert(.traitBold) }
        if styles.contains("italic") { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let baseFont = font(in: string, at: range.location, fallbackAttributes: fallbackAttributes) {
            string.addAttribute(.font, value: font(baseFont, adding: traits), range: range)
        }
        if styles.contains("underline") {
            string.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if styles.contains("strike") {
            string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if styles.contains("uri"), let destination = normalizedDestination(reference.destination) {
            string.addAttribute(.link, value: destination, range: range)
        }
    }

    private static func applyMention(
        _ reference: ChatAttributedBodyReference,
        range: NSRange,
        to string: NSMutableAttributedString,
        fallbackAttributes: [NSAttributedString.Key: Any]
    ) {
        if let baseFont = font(in: string, at: range.location, fallbackAttributes: fallbackAttributes) {
            string.addAttribute(.font, value: font(baseFont, adding: .traitBold), range: range)
        }
        if let mentionColor = reference.mentionColor {
            string.addAttribute(.foregroundColor, value: mentionColor, range: range)
        }
        if let destination = normalizedDestination(reference.destination) {
            string.addAttribute(.link, value: destination, range: range)
        }
    }

    private static func applyPlainURLs(to string: NSMutableAttributedString) {
        guard string.length > 0, let detector = plainURLDetector else { return }
        let fullRange = NSRange(location: 0, length: string.length)
        for result in detector.matches(in: string.string, options: [], range: fullRange) {
            guard let url = result.url,
                  !containsLinkAttribute(in: result.range, string: string) else {
                continue
            }
            string.addAttribute(.link, value: url, range: result.range)
        }
    }

    private static func containsLinkAttribute(
        in range: NSRange,
        string: NSAttributedString
    ) -> Bool {
        var found = false
        string.enumerateAttribute(.link, in: range) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    private static func applySearchHighlights(
        _ query: String,
        color: UIColor,
        to string: NSMutableAttributedString
    ) {
        let source = string.string as NSString
        var remaining = NSRange(location: 0, length: source.length)
        while remaining.length > 0 {
            let match = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remaining
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            string.addAttribute(.backgroundColor, value: color, range: match)
            let nextLocation = NSMaxRange(match)
            remaining = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
    }

    private static func font(
        in string: NSAttributedString,
        at location: Int,
        fallbackAttributes: [NSAttributedString.Key: Any]
    ) -> UIFont? {
        string.attribute(.font, at: location, effectiveRange: nil) as? UIFont
            ?? fallbackAttributes[.font] as? UIFont
    }

    private static func font(
        _ baseFont: UIFont,
        adding traits: UIFontDescriptor.SymbolicTraits
    ) -> UIFont {
        let combinedTraits = baseFont.fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = baseFont.fontDescriptor.withSymbolicTraits(combinedTraits) else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: 0)
    }

    private static func normalizedDestination(_ destination: String?) -> String? {
        guard let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              destination.isNotEmpty else {
            return nil
        }
        return destination
    }
}
