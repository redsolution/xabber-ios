import Foundation

protocol LanguagePreferenceStoring: AnyObject {
    func loadSelection() -> AppLanguageSelection

    @discardableResult
    func saveSelection(_ selection: AppLanguageSelection) -> Bool
}

enum LegacyLanguageSelectionMigrator {
    private static let namedLanguages: [String: SupportedLanguage] = [
        "English 🇬🇧": .english,
        "Русский язык 🇷🇺": .russian,
        "Русский": .russian,
        "Français 🇫🇷": .french,
        "Français": .french,
        "Español 🇪🇸": .spanish,
        "Español": .spanish,
        "عربي 🇸🇦": .arabic,
        "العربية": .arabic,
        "中國人 🇨🇳": .simplifiedChinese,
        "简体中文 🇨🇳": .simplifiedChinese,
        "简体中文": .simplifiedChinese
    ]

    static func selection(from legacyValue: String?) -> AppLanguageSelection {
        guard let value = legacyValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.caseInsensitiveCompare("Default") != .orderedSame,
              value.caseInsensitiveCompare("system") != .orderedSame else {
            return .system
        }

        if let language = namedLanguages[value] {
            return .fixed(language)
        }
        if let language = SupportedLanguage.match(identifier: value) {
            return .fixed(language)
        }
        return .system
    }
}

final class LanguagePreferenceStore: LanguagePreferenceStoring {
    static let selectionKey = "localization_selection_v1"
    static let legacyKey = "languages_current_language_"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func appGroup(
        suiteName: String,
        containerURLProvider: (String) -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: $0
            )
        }
    ) -> LanguagePreferenceStore? {
        let suiteName = suiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suiteName.isEmpty,
              containerURLProvider(suiteName) != nil,
              let defaults = UserDefaults(suiteName: suiteName) else {
            return nil
        }
        return LanguagePreferenceStore(defaults: defaults)
    }

    func loadSelection() -> AppLanguageSelection {
        lock.lock()
        defer { lock.unlock() }

        if let storedValue = defaults.string(forKey: Self.selectionKey),
           let storedSelection = AppLanguageSelection(storageValue: storedValue) {
            defaults.removeObject(forKey: Self.legacyKey)
            return storedSelection
        }

        let legacyValue = defaults.string(forKey: Self.legacyKey)
        let migratedSelection = LegacyLanguageSelectionMigrator.selection(from: legacyValue)
        if saveSelectionWithoutLock(migratedSelection) {
            defaults.removeObject(forKey: Self.legacyKey)
        }
        return migratedSelection
    }

    @discardableResult
    func saveSelection(_ selection: AppLanguageSelection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveSelectionWithoutLock(selection)
    }

    private func saveSelectionWithoutLock(_ selection: AppLanguageSelection) -> Bool {
        defaults.set(selection.storageValue, forKey: Self.selectionKey)
        return defaults.string(forKey: Self.selectionKey) == selection.storageValue
    }
}
