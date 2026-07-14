//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software Foundation,
//  Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import UIKit

struct ChatSearchHighlightStyle: Equatable {
    let backgroundColor: UIColor
    let foregroundColor: UIColor

    static func telegram(for traitCollection: UITraitCollection) -> ChatSearchHighlightStyle {
        switch traitCollection.userInterfaceStyle {
        case .dark:
            return ChatSearchHighlightStyle(
                backgroundColor: UIColor(red: 0.96, green: 0.72, blue: 0.12, alpha: 1),
                foregroundColor: UIColor(red: 0.08, green: 0.06, blue: 0.0, alpha: 1)
            )
        default:
            return ChatSearchHighlightStyle(
                backgroundColor: UIColor(red: 1.0, green: 0.82, blue: 0.2, alpha: 1),
                foregroundColor: UIColor(red: 0.16, green: 0.12, blue: 0.0, alpha: 1)
            )
        }
    }
}

final class ChatSearchHighlightCache {
    private struct Key: Hashable {
        let sourceHash: Int
        let sourceLength: Int
        let query: String?
        let localeIdentifier: String
        let backgroundHash: Int
        let foregroundHash: Int
    }

    private struct Entry {
        let source: NSAttributedString
        let style: ChatSearchHighlightStyle
        let output: NSAttributedString
    }

    private let countLimit: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var storedComputationCount = 0

    init(countLimit: Int) {
        self.countLimit = max(1, countLimit)
    }

    var computationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedComputationCount
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func applying(
        to source: NSAttributedString,
        query: String?,
        style: ChatSearchHighlightStyle,
        locale: Locale = .current
    ) -> NSAttributedString {
        let key = Key(
            sourceHash: source.hash,
            sourceLength: source.length,
            query: query,
            localeIdentifier: locale.identifier,
            backgroundHash: style.backgroundColor.hash,
            foregroundHash: style.foregroundColor.hash
        )

        lock.lock()
        if let entry = entries[key],
           entry.style == style,
           entry.source.isEqual(to: source) {
            let output = entry.output
            lock.unlock()
            return output
        }
        lock.unlock()

        let computed = ChatSearchHighlighter.applyingUncached(
            to: source,
            query: query,
            style: style,
            locale: locale
        )
        let immutableOutput = NSAttributedString(attributedString: computed)

        lock.lock()
        storedComputationCount += 1
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = Entry(
            source: NSAttributedString(attributedString: source),
            style: style,
            output: immutableOutput
        )
        while entries.count > countLimit,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        lock.unlock()
        return immutableOutput
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

enum ChatSearchQueryRangeFinder {
    static func ranges(
        in text: String,
        query: String,
        locale: Locale = .current
    ) -> [NSRange] {
        guard text.isNotEmpty,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else {
            return []
        }

        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange,
                locale: locale
            )
            guard match.location != NSNotFound, match.length > 0 else {
                break
            }

            matches.append(match)
            let nextLocation = NSMaxRange(match)
            guard nextLocation <= source.length else {
                break
            }
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }

        return matches
    }
}

enum ChatSearchHighlighter {
    static let markerAttribute = NSAttributedString.Key("xabber.chat.search.highlight")

    private static let sharedCache = ChatSearchHighlightCache(countLimit: 256)

    static var cachedEntryCount: Int {
        sharedCache.count
    }

    static func removeCachedResults() {
        sharedCache.removeAll()
    }

    private static let originalBackgroundAttribute =
        NSAttributedString.Key("xabber.chat.search.original-background")
    private static let originalForegroundAttribute =
        NSAttributedString.Key("xabber.chat.search.original-foreground")

    static func applying(
        to source: NSAttributedString,
        query: String?,
        style: ChatSearchHighlightStyle,
        locale: Locale = .current
    ) -> NSAttributedString {
        sharedCache.applying(
            to: source,
            query: query,
            style: style,
            locale: locale
        )
    }

    fileprivate static func applyingUncached(
        to source: NSAttributedString,
        query: String?,
        style: ChatSearchHighlightStyle,
        locale: Locale = .current
    ) -> NSAttributedString {
        let mutable = removing(from: source)
        guard let query else {
            return mutable
        }

        let ranges = ChatSearchQueryRangeFinder.ranges(
            in: mutable.string,
            query: query,
            locale: locale
        )
        guard ranges.isNotEmpty else {
            return mutable
        }

        for range in ranges {
            preserveAttribute(
                .backgroundColor,
                as: originalBackgroundAttribute,
                in: mutable,
                range: range
            )
            preserveAttribute(
                .foregroundColor,
                as: originalForegroundAttribute,
                in: mutable,
                range: range
            )
            mutable.addAttributes(
                [
                    markerAttribute: true,
                    .backgroundColor: style.backgroundColor,
                    .foregroundColor: style.foregroundColor
                ],
                range: range
            )
        }

        return mutable
    }

    static func removing(from source: NSAttributedString) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: source)
        guard mutable.length > 0 else {
            return mutable
        }

        let fullRange = NSRange(location: 0, length: mutable.length)
        var highlightedRanges: [NSRange] = []
        mutable.enumerateAttribute(markerAttribute, in: fullRange) { value, range, _ in
            if value != nil {
                highlightedRanges.append(range)
            }
        }

        for range in highlightedRanges {
            let backgrounds = preservedValues(
                for: originalBackgroundAttribute,
                in: mutable,
                range: range
            )
            let foregrounds = preservedValues(
                for: originalForegroundAttribute,
                in: mutable,
                range: range
            )

            mutable.removeAttribute(.backgroundColor, range: range)
            mutable.removeAttribute(.foregroundColor, range: range)
            mutable.removeAttribute(markerAttribute, range: range)
            mutable.removeAttribute(originalBackgroundAttribute, range: range)
            mutable.removeAttribute(originalForegroundAttribute, range: range)

            restore(backgrounds, attribute: .backgroundColor, in: mutable)
            restore(foregrounds, attribute: .foregroundColor, in: mutable)
        }

        return mutable
    }

    private static func preserveAttribute(
        _ attribute: NSAttributedString.Key,
        as backupAttribute: NSAttributedString.Key,
        in text: NSMutableAttributedString,
        range: NSRange
    ) {
        var values: [(value: Any, range: NSRange)] = []
        text.enumerateAttribute(attribute, in: range) { value, effectiveRange, _ in
            values.append((value ?? NSNull(), effectiveRange))
        }
        for value in values {
            text.addAttribute(backupAttribute, value: value.value, range: value.range)
        }
    }

    private static func preservedValues(
        for attribute: NSAttributedString.Key,
        in text: NSAttributedString,
        range: NSRange
    ) -> [(value: Any, range: NSRange)] {
        var values: [(value: Any, range: NSRange)] = []
        text.enumerateAttribute(attribute, in: range) { value, effectiveRange, _ in
            values.append((value ?? NSNull(), effectiveRange))
        }
        return values
    }

    private static func restore(
        _ values: [(value: Any, range: NSRange)],
        attribute: NSAttributedString.Key,
        in text: NSMutableAttributedString
    ) {
        for value in values where !(value.value is NSNull) {
            text.addAttribute(attribute, value: value.value, range: value.range)
        }
    }
}
