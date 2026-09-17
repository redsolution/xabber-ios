import Foundation

enum LocalizationMissingReason: String {
    case missing
    case empty
}

typealias LocalizationMissingKeyHandler = (
    _ key: String,
    _ language: SupportedLanguage,
    _ reason: LocalizationMissingReason
) -> Void

protocol Localizing: AnyObject {
    var context: LocalizationContext { get }
    var formatters: LocalizationFormatterFactory { get }

    func text(key: String, fallback: String, table: String?) -> String
    func format(
        key: String,
        fallback: String,
        arguments: [CVarArg],
        table: String?
    ) -> String
    func plural(
        key: String,
        count: Int,
        fallback: String,
        arguments: [CVarArg],
        table: String?
    ) -> String
    func attributedMarkdown(
        key: String,
        fallback: String,
        arguments: [CVarArg],
        table: String?
    ) -> NSAttributedString
}

extension Localizing {
    func text(key: String, fallback: String, table: String? = nil) -> String {
        text(key: key, fallback: fallback, table: table)
    }

    func format(
        key: String,
        fallback: String,
        arguments: [CVarArg],
        table: String? = nil
    ) -> String {
        format(key: key, fallback: fallback, arguments: arguments, table: table)
    }

    func plural(
        key: String,
        count: Int,
        fallback: String,
        arguments: [CVarArg] = [],
        table: String? = nil
    ) -> String {
        plural(
            key: key,
            count: count,
            fallback: fallback,
            arguments: arguments,
            table: table
        )
    }

    func attributedMarkdown(
        key: String,
        fallback: String,
        arguments: [CVarArg] = [],
        table: String? = nil
    ) -> NSAttributedString {
        attributedMarkdown(
            key: key,
            fallback: fallback,
            arguments: arguments,
            table: table
        )
    }
}

final class LocalizationService: Localizing {
    private let contextLock = NSLock()
    private var storedContext: LocalizationContext
    private let missingKeyHandler: LocalizationMissingKeyHandler?

    init(
        context: LocalizationContext,
        missingKeyHandler: LocalizationMissingKeyHandler? = nil
    ) {
        storedContext = context
        self.missingKeyHandler = missingKeyHandler
    }

    var context: LocalizationContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        return storedContext
    }

    var formatters: LocalizationFormatterFactory {
        LocalizationFormatterFactory(context: context)
    }

    @discardableResult
    func replaceContext(_ context: LocalizationContext) -> LocalizationContext {
        contextLock.lock()
        storedContext = context
        contextLock.unlock()
        return context
    }

    func text(key: String, fallback: String, table: String? = nil) -> String {
        let snapshot = context
        return localizedTemplate(
            key: key,
            fallback: fallback,
            table: table,
            context: snapshot
        )
    }

    func format(
        key: String,
        fallback: String,
        arguments: [CVarArg],
        table: String? = nil
    ) -> String {
        let snapshot = context
        let template = localizedTemplate(
            key: key,
            fallback: fallback,
            table: table,
            context: snapshot
        )
        return format(template: template, locale: snapshot.locale, arguments: arguments)
    }

    func legacyFormat(
        key: String,
        fallback: String,
        arguments: [String],
        table: String? = nil
    ) -> String {
        let snapshot = context
        let template = localizedTemplate(
            key: key,
            fallback: fallback,
            table: table,
            context: snapshot
        )
        let safeTemplate = Self.objectFormatTemplate(from: template)
        return format(
            template: safeTemplate,
            locale: snapshot.locale,
            arguments: arguments.map { $0 as CVarArg }
        )
    }

    func plural(
        key: String,
        count: Int,
        fallback: String,
        arguments: [CVarArg] = [],
        table: String? = nil
    ) -> String {
        let snapshot = context
        let template = localizedTemplate(
            key: key,
            fallback: fallback,
            table: table,
            context: snapshot
        )
        var pluralArguments: [CVarArg] = [count]
        pluralArguments.append(contentsOf: arguments)
        return format(
            template: template,
            locale: snapshot.locale,
            arguments: pluralArguments
        )
    }

    func attributedMarkdown(
        key: String,
        fallback: String,
        arguments: [CVarArg] = [],
        table: String? = nil
    ) -> NSAttributedString {
        let snapshot = context
        let template = localizedTemplate(
            key: key,
            fallback: fallback,
            table: table,
            context: snapshot
        )
        let protectedArguments = Self.protectedMarkdownArguments(arguments)
        let markdown = format(
            template: template,
            locale: snapshot.locale,
            arguments: protectedArguments.formatArguments
        )

        do {
            let value = try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            let result = NSMutableAttributedString(
                attributedString: NSAttributedString(value)
            )
            for replacement in protectedArguments.replacements {
                while true {
                    let range = (result.string as NSString).range(of: replacement.token)
                    guard range.location != NSNotFound else { break }
                    // Insert untrusted values only after parsing. The inserted
                    // text inherits trusted catalog styling but can never add
                    // Markdown links or presentation intents of its own.
                    result.replaceCharacters(in: range, with: replacement.value)
                }
            }
            return result
        } catch {
            let plainText = format(
                template: template,
                locale: snapshot.locale,
                arguments: arguments
            )
            return NSAttributedString(string: plainText)
        }
    }

    private func localizedTemplate(
        key: String,
        fallback: String,
        table: String?,
        context: LocalizationContext
    ) -> String {
        if let value = lookup(key: key, table: table, bundle: context.localizedBundle) {
            return value
        }

        if context.resolvedLanguage != .english {
            missingKeyHandler?(key, context.resolvedLanguage, lookupFailureReason(
                key: key,
                table: table,
                bundle: context.localizedBundle
            ))
        }

        if context.localizedBundle.bundlePath != context.englishBundle.bundlePath,
           let value = lookup(key: key, table: table, bundle: context.englishBundle) {
            return value
        }

        if context.resolvedLanguage == .english
            || context.localizedBundle.bundlePath != context.englishBundle.bundlePath {
            missingKeyHandler?(key, .english, lookupFailureReason(
                key: key,
                table: table,
                bundle: context.englishBundle
            ))
        }

        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return key
    }

    private func lookup(
        key: String,
        table: String?,
        bundle: Bundle
    ) -> String? {
        let sentinel = "\u{E000}xabber.localization.missing.\(key)\u{E001}"
        let value = bundle.localizedString(
            forKey: key,
            value: sentinel,
            table: table
        )
        guard value != sentinel,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func lookupFailureReason(
        key: String,
        table: String?,
        bundle: Bundle
    ) -> LocalizationMissingReason {
        let sentinel = "\u{E000}xabber.localization.missing.\(key)\u{E001}"
        let value = bundle.localizedString(
            forKey: key,
            value: sentinel,
            table: table
        )
        if value == sentinel {
            return .missing
        }
        return .empty
    }

    private func format(
        template: String,
        locale: Locale,
        arguments: [CVarArg]
    ) -> String {
        guard !arguments.isEmpty else {
            return template
        }
        return String(format: template, locale: locale, arguments: arguments)
    }

    private static func protectedMarkdownArguments(
        _ arguments: [CVarArg]
    ) -> (
        formatArguments: [CVarArg],
        replacements: [(token: String, value: String)]
    ) {
        var replacements: [(token: String, value: String)] = []
        let formatArguments: [CVarArg] = arguments.enumerated().map { index, argument in
            let value: String?
            if let string = argument as? String {
                value = string
            } else if let string = argument as? NSString {
                value = string as String
            } else {
                value = nil
            }
            guard let value else { return argument }

            let token = "\u{E000}xabber_markdown_argument_\(index)_\(UUID().uuidString)\u{E001}"
            replacements.append((token: token, value: value))
            return token as CVarArg
        }
        return (formatArguments, replacements)
    }

    private static func objectFormatTemplate(from template: String) -> String {
        let pattern = #"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?[diuoxXfFeEgGaAcCsSp]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return template
        }

        var result = template
        let matches = expression.matches(
            in: template,
            range: NSRange(template.startIndex..., in: template)
        )
        for match in matches.reversed() {
            let position: String?
            if match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: template) {
                position = String(template[range])
            } else {
                position = nil
            }
            let replacement = position.map { "%\($0)$@" } ?? "%@"
            guard let range = Range(match.range, in: result) else {
                continue
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

struct LocalizationFormatterFactory {
    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone
    let revision: UInt64

    init(context: LocalizationContext) {
        locale = context.locale
        calendar = context.calendar
        timeZone = context.timeZone
        revision = context.revision
    }

    func dateFormatter(
        dateStyle: DateFormatter.Style = .none,
        timeStyle: DateFormatter.Style = .none
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    func relativeDateTimeFormatter(
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .full,
        dateTimeStyle: RelativeDateTimeFormatter.DateTimeStyle = .numeric
    ) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = unitsStyle
        formatter.dateTimeStyle = dateTimeStyle
        return formatter
    }

    func numberFormatter(
        style: NumberFormatter.Style = .none
    ) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = style
        return formatter
    }

    func byteCountFormatter(
        countStyle: ByteCountFormatter.CountStyle = .file,
        allowedUnits: ByteCountFormatter.Units = .useAll,
        includesUnit: Bool = true,
        includesCount: Bool = true
    ) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = countStyle
        formatter.allowedUnits = allowedUnits
        formatter.includesUnit = includesUnit
        formatter.includesCount = includesCount
        return formatter
    }

    func listFormatter() -> ListFormatter {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter
    }
}
