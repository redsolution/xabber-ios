import Foundation

enum LocalizationLayoutDirection: String, Codable {
    case leftToRight
    case rightToLeft
}

enum SupportedLanguage: String, CaseIterable, Codable, Hashable {
    case english = "en"
    case russian = "ru"
    case french = "fr"
    case spanish = "es"
    case arabic = "ar"
    case simplifiedChinese = "zh-Hans"

    var nativeDisplayName: String {
        switch self {
        case .english:
            return "English"
        case .russian:
            return "Русский"
        case .french:
            return "Français"
        case .spanish:
            return "Español"
        case .arabic:
            return "العربية"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    var accessibilityIdentifierSuffix: String {
        rawValue
    }

    var layoutDirection: LocalizationLayoutDirection {
        self == .arabic ? .rightToLeft : .leftToRight
    }

    func locale(basedOn baseLocale: Locale) -> Locale {
        let languageCode = self == .simplifiedChinese ? "zh" : rawValue
        let scriptCode = self == .simplifiedChinese ? "Hans" : nil

        if #available(iOS 16.0, macOS 13.0, *) {
            var components = Locale.Components(locale: baseLocale)
            var languageComponents = components.languageComponents
            languageComponents.languageCode = Locale.LanguageCode(languageCode)
            languageComponents.script = scriptCode.map { Locale.Script($0) }
            components.languageComponents = languageComponents
            return Locale(components: components)
        }

        var components = Locale.components(fromIdentifier: baseLocale.identifier)
        components[NSLocale.Key.languageCode.rawValue] = languageCode
        if let scriptCode {
            components[NSLocale.Key.scriptCode.rawValue] = scriptCode
        } else {
            components.removeValue(forKey: NSLocale.Key.scriptCode.rawValue)
        }
        return Locale(identifier: Locale.identifier(fromComponents: components))
    }

    static func match(identifier: String) -> SupportedLanguage? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else {
            return nil
        }

        let components = normalized.split(separator: "-").map(String.init)
        guard let languageCode = components.first else {
            return nil
        }

        switch languageCode {
        case "en":
            return .english
        case "ru":
            return .russian
        case "fr":
            return .french
        case "es":
            return .spanish
        case "ar":
            return .arabic
        case "zh":
            let qualifiers = Set(components.dropFirst())
            if qualifiers.contains("hant") {
                return nil
            }
            if qualifiers.contains("hans") {
                return .simplifiedChinese
            }
            guard qualifiers.isEmpty
                    || !qualifiers.isDisjoint(with: ["cn", "sg", "my"]) else {
                return nil
            }
            return .simplifiedChinese
        default:
            return nil
        }
    }
}

enum AppLanguageSelection: Equatable, Hashable, Codable {
    case system
    case fixed(SupportedLanguage)

    var storageValue: String {
        switch self {
        case .system:
            return "system"
        case let .fixed(language):
            return language.rawValue
        }
    }

    init?(storageValue: String) {
        let normalized = storageValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "system" {
            self = .system
        } else if let language = SupportedLanguage(rawValue: normalized) {
            self = .fixed(language)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let selection = AppLanguageSelection(storageValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported language selection: \(value)"
            )
        }
        self = selection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

enum LocalizationResolutionSource: String, Codable {
    case system
    case fixed
}

struct LanguageResolution: Equatable {
    let language: SupportedLanguage
    let source: LocalizationResolutionSource
    let preferredLanguageIdentifier: String?
}

struct LocalizationContextSignature: Equatable {
    let selection: AppLanguageSelection
    let resolvedLanguage: SupportedLanguage
    let source: LocalizationResolutionSource
    let localeIdentifier: String
    let calendarIdentifier: Calendar.Identifier
    let calendarLocaleIdentifier: String?
    let calendarTimeZoneIdentifier: String
    let calendarFirstWeekday: Int
    let calendarMinimumDaysInFirstWeek: Int
    let timeZoneIdentifier: String
    let layoutDirection: LocalizationLayoutDirection
    let localizedBundlePath: String
    let englishBundlePath: String
}

struct LocalizationContext: Equatable {
    let selection: AppLanguageSelection
    let resolvedLanguage: SupportedLanguage
    let source: LocalizationResolutionSource
    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone
    let localizedBundle: Bundle
    let englishBundle: Bundle
    let layoutDirection: LocalizationLayoutDirection
    let revision: UInt64

    var language: SupportedLanguage {
        resolvedLanguage
    }

    var bundle: Bundle {
        localizedBundle
    }

    var semanticSignature: LocalizationContextSignature {
        LocalizationContextSignature(
            selection: selection,
            resolvedLanguage: resolvedLanguage,
            source: source,
            localeIdentifier: locale.identifier,
            calendarIdentifier: calendar.identifier,
            calendarLocaleIdentifier: calendar.locale?.identifier,
            calendarTimeZoneIdentifier: calendar.timeZone.identifier,
            calendarFirstWeekday: calendar.firstWeekday,
            calendarMinimumDaysInFirstWeek: calendar.minimumDaysInFirstWeek,
            timeZoneIdentifier: timeZone.identifier,
            layoutDirection: layoutDirection,
            localizedBundlePath: localizedBundle.bundlePath,
            englishBundlePath: englishBundle.bundlePath
        )
    }

    func isSemanticallyEquivalent(to other: LocalizationContext) -> Bool {
        semanticSignature == other.semanticSignature
    }

    func replacingRevision(_ revision: UInt64) -> LocalizationContext {
        LocalizationContext(
            selection: selection,
            resolvedLanguage: resolvedLanguage,
            source: source,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            localizedBundle: localizedBundle,
            englishBundle: englishBundle,
            layoutDirection: layoutDirection,
            revision: revision
        )
    }

    static func == (lhs: LocalizationContext, rhs: LocalizationContext) -> Bool {
        lhs.revision == rhs.revision && lhs.semanticSignature == rhs.semanticSignature
    }
}

protocol LocalizedBundleProviding {
    var resourceBundle: Bundle { get }
    func bundle(for language: SupportedLanguage) -> Bundle?
}

struct LprojBundleProvider: LocalizedBundleProviding {
    let resourceBundle: Bundle

    init(resourceBundle: Bundle = .main) {
        self.resourceBundle = resourceBundle
    }

    func bundle(for language: SupportedLanguage) -> Bundle? {
        guard let path = resourceBundle.path(
            forResource: language.rawValue,
            ofType: "lproj"
        ) else {
            return nil
        }
        return Bundle(path: path)
    }
}

enum LanguageResolver {
    static func resolve(
        selection: AppLanguageSelection,
        preferredLanguages: [String]
    ) -> LanguageResolution {
        switch selection {
        case let .fixed(language):
            return LanguageResolution(
                language: language,
                source: .fixed,
                preferredLanguageIdentifier: nil
            )
        case .system:
            for identifier in preferredLanguages {
                if let language = SupportedLanguage.match(identifier: identifier) {
                    return LanguageResolution(
                        language: language,
                        source: .system,
                        preferredLanguageIdentifier: identifier
                    )
                }
            }
            return LanguageResolution(
                language: .english,
                source: .system,
                preferredLanguageIdentifier: nil
            )
        }
    }

    static func makeContext(
        selection: AppLanguageSelection,
        preferredLanguages: [String],
        baseLocale: Locale,
        calendar: Calendar,
        timeZone: TimeZone,
        bundleProvider: LocalizedBundleProviding,
        revision: UInt64
    ) -> LocalizationContext {
        let resolution = resolve(
            selection: selection,
            preferredLanguages: preferredLanguages
        )
        let locale = resolution.language.locale(basedOn: baseLocale)
        let firstWeekday = calendar.firstWeekday
        let minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        localizedCalendar.timeZone = timeZone
        localizedCalendar.firstWeekday = firstWeekday
        localizedCalendar.minimumDaysInFirstWeek = minimumDaysInFirstWeek

        // Never fall through to the resource bundle here. Its implicit lookup
        // follows the process language and would make the result depend on the
        // app/extension host instead of this localization context.
        let englishBundle = bundleProvider.bundle(for: .english) ?? Bundle()
        let localizedBundle = bundleProvider.bundle(for: resolution.language)
            ?? englishBundle

        return LocalizationContext(
            selection: selection,
            resolvedLanguage: resolution.language,
            source: resolution.source,
            locale: locale,
            calendar: localizedCalendar,
            timeZone: timeZone,
            localizedBundle: localizedBundle,
            englishBundle: englishBundle,
            layoutDirection: resolution.language.layoutDirection,
            revision: revision
        )
    }
}
