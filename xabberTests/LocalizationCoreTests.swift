import Foundation
import XCTest
@testable import xabber

final class LocalizationCoreTests: XCTestCase {
    private var defaultsSuites: [String] = []
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        defaultsSuites.removeAll()
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSupportedLanguagesExposeStableProductMetadata() {
        XCTAssertEqual(
            SupportedLanguage.allCases.map(\.rawValue),
            ["en", "ru", "fr", "es", "ar", "zh-Hans"]
        )
        XCTAssertEqual(
            SupportedLanguage.allCases.map(\.nativeDisplayName),
            ["English", "Русский", "Français", "Español", "العربية", "简体中文"]
        )
        XCTAssertEqual(
            SupportedLanguage.allCases.map(\.accessibilityIdentifierSuffix),
            ["en", "ru", "fr", "es", "ar", "zh-Hans"]
        )
        XCTAssertEqual(SupportedLanguage.arabic.layoutDirection, .rightToLeft)
        XCTAssertTrue(
            SupportedLanguage.allCases
                .filter { $0 != .arabic }
                .allSatisfy { $0.layoutDirection == .leftToRight }
        )
    }

    func testSystemResolverSkipsUnsupportedPreferredLanguages() {
        let resolution = LanguageResolver.resolve(
            selection: .system,
            preferredLanguages: ["de-DE", "ru-RU", "en-US"]
        )

        XCTAssertEqual(resolution.language, .russian)
        XCTAssertEqual(resolution.source, .system)
        XCTAssertEqual(resolution.preferredLanguageIdentifier, "ru-RU")
    }

    func testSystemResolverDoesNotTreatTraditionalChineseAsSimplifiedChinese() {
        XCTAssertEqual(
            LanguageResolver.resolve(
                selection: .system,
                preferredLanguages: ["zh-Hant-TW", "es-MX"]
            ).language,
            .spanish
        )
        XCTAssertEqual(
            LanguageResolver.resolve(
                selection: .system,
                preferredLanguages: ["zh-TW", "zh-HK"]
            ).language,
            .english
        )
        XCTAssertEqual(
            LanguageResolver.resolve(
                selection: .system,
                preferredLanguages: ["zh-US", "fr-FR"]
            ).language,
            .french
        )
    }

    func testSystemResolverRecognizesSimplifiedChineseIdentifiers() {
        for identifier in [
            "zh", "zh-CN", "zh-SG", "zh-MY", "zh-Hans", "zh-Hans-CN", "zh-Hans-TW"
        ] {
            XCTAssertEqual(
                LanguageResolver.resolve(
                    selection: .system,
                    preferredLanguages: [identifier]
                ).language,
                .simplifiedChinese,
                identifier
            )
        }
    }

    func testFixedSelectionWinsOverSystemPreferences() {
        let resolution = LanguageResolver.resolve(
            selection: .fixed(.arabic),
            preferredLanguages: ["ru-RU"]
        )

        XCTAssertEqual(resolution.language, .arabic)
        XCTAssertEqual(resolution.source, .fixed)
        XCTAssertNil(resolution.preferredLanguageIdentifier)
    }

    func testResolvedLocaleKeepsSystemRegion() {
        let locale = SupportedLanguage.french.locale(basedOn: Locale(identifier: "en_US"))

        XCTAssertEqual(locale.languageCode, "fr")
        XCTAssertEqual(locale.regionCode, "US")
    }

    func testResolvedLocaleReplacesOnlyLanguageAndScriptComponents() {
        let base = Locale(
            identifier: "en_US@calendar=buddhist;numbers=arab;hours=h23"
        )
        let locale = SupportedLanguage.simplifiedChinese.locale(basedOn: base)
        let components = Locale.components(fromIdentifier: locale.identifier)

        XCTAssertEqual(components[NSLocale.Key.languageCode.rawValue], "zh")
        XCTAssertEqual(components[NSLocale.Key.scriptCode.rawValue], "Hans")
        XCTAssertEqual(components[NSLocale.Key.countryCode.rawValue], "US")
        XCTAssertEqual(components["calendar"], "buddhist")
        XCTAssertEqual(components["numbers"], "arab")
        XCTAssertEqual(components["hours"], "h23")
    }

    func testSelectionStorageValuesRoundTrip() {
        let selections: [AppLanguageSelection] = [
            .system,
            .fixed(.english),
            .fixed(.russian),
            .fixed(.french),
            .fixed(.spanish),
            .fixed(.arabic),
            .fixed(.simplifiedChinese)
        ]

        for selection in selections {
            XCTAssertEqual(
                AppLanguageSelection(storageValue: selection.storageValue),
                selection
            )
        }
        XCTAssertNil(AppLanguageSelection(storageValue: "de"))
        XCTAssertNil(AppLanguageSelection(storageValue: "zh-Hant"))
    }

    func testLegacyMigratorMapsSupportedLegacyValues() {
        let fixtures: [(String?, AppLanguageSelection)] = [
            (nil, .system),
            ("", .system),
            ("Default", .system),
            ("English 🇬🇧", .fixed(.english)),
            ("Русский язык 🇷🇺", .fixed(.russian)),
            ("Français 🇫🇷", .fixed(.french)),
            ("Español 🇪🇸", .fixed(.spanish)),
            ("عربي 🇸🇦", .fixed(.arabic)),
            ("中國人 🇨🇳", .fixed(.simplifiedChinese)),
            ("简体中文 🇨🇳", .fixed(.simplifiedChinese)),
            ("fr-CA", .fixed(.french)),
            ("ru_RU", .fixed(.russian)),
            ("zh-CN", .fixed(.simplifiedChinese))
        ]

        for (legacyValue, expected) in fixtures {
            XCTAssertEqual(
                LegacyLanguageSelectionMigrator.selection(from: legacyValue),
                expected,
                legacyValue ?? "nil"
            )
        }
    }

    func testLegacyMigratorMapsEveryRemovedLanguageToSystem() {
        let removedLegacyValues = [
            "Shqip 🇦🇱", "Հայերէն 🇦🇲", "Azərbaycan dili 🇦🇿", "Беларуская мова 🇧🇾",
            "Bosanski 🇧🇦", "Български 🇧🇬", "Català", "Hrvatski 🇭🇷", "Čeština 🇨🇿",
            "Dansk 🇩🇰", "Nederlands 🇳🇱", "Eesti keel 🇪🇪", "Filipino 🇵🇭", "Suomi 🇫🇮",
            "ქართული ენა 🇬🇪", "Deutsch 🇩🇪", "ελληνικά 🇬🇷", "हिन्दी 🇮🇳", "העברעאיש 🇮🇱",
            "Magyar 🇭🇺", "Íslenska 🇮🇸", "Gaeilge 🇮🇪", "Italiano 🇮🇹", "Bahasa Indonesia 🇮🇩",
            "日本語 🇯🇵", "한국어 🇰🇷", "کوردی", "Klingon", "Кыргыз тили 🇰🇬", "Lingua Latina 🇻🇦",
            "Lietuvių kalba 🇱🇹", "Lëtzebuergesch 🇱🇺", "Македонски 🇲🇰", "മലയാളം 🇲🇾",
            "मराठी 🇮🇳", "Монгол 🇲🇳", "नेपाली 🇳🇵", "Bokmål 🇳🇴", "Norsk 🇳🇴", "Occitan 🇫🇷",
            "فارسی 🇮🇷", "Polski 🇵🇱", "Português 🇵🇹", "Português do Brasil 🇧🇷", "ਪੰਜਾਬੀ 🇮🇳",
            "Limba română 🇷🇴", "ᱥᱟᱱᱛᱟᱲᱤ 🇮🇳", "Scots Leid 🏴󠁧󠁢󠁳󠁣󠁴󠁿",
            "Cрпски / srpski  🇷🇸", "සිංහල 🇱🇰", "Slovenčina 🇸🇰", "Slovenščina 🇸🇮",
            "Kiswahili 🇹🇿", "Svenska 🇸🇪", "Тоҷикӣ 🇹🇯", "தமிழ் 🇮🇳", "తెలుగు 🇮🇳",
            "Türkçe 🇹🇷", "Türkmen dili 🇹🇲", "Українська мова 🇺🇦", "Ўзбек тили 🇺🇿",
            "Tiếng Việt 🇻🇳", "Cymraeg 🏴󠁧󠁢󠁷󠁬󠁳󠁿", "Èdè Yorùbá 🇳🇬", "isiZulu 🇿🇦"
        ]

        for legacyValue in removedLegacyValues {
            XCTAssertEqual(
                LegacyLanguageSelectionMigrator.selection(from: legacyValue),
                .system,
                legacyValue
            )
        }
    }

    func testLegacyMigratorMapsRemovedLanguageCodesToSystem() {
        let removedCodes = [
            "sq", "hy", "az", "be", "bs", "bg", "ca", "zh-Hant", "zh-TW",
            "hr", "cs", "da", "nl", "et", "fil", "fi", "ka", "de", "el",
            "hi", "he", "hu", "is", "ga", "it", "id", "ja", "ko", "ku",
            "tlh", "ky", "la", "lt", "lb", "mk", "ms", "mr", "mn", "ne",
            "nb", "nb-NO", "oc", "fa", "pl", "pt", "pt-BR", "pa", "ro",
            "sat", "sco", "sr", "si", "sk", "sl", "sw", "sv", "tg", "ta",
            "te", "tr", "tk", "uk", "uz", "vi", "cy", "yo", "zu"
        ]

        for legacyCode in removedCodes {
            XCTAssertEqual(
                LegacyLanguageSelectionMigrator.selection(from: legacyCode),
                .system,
                legacyCode
            )
        }
    }

    func testPreferenceStoreMigratesLegacyValueAndRemovesLegacyKey() {
        let defaults = makeDefaults()
        defaults.set("Русский язык 🇷🇺", forKey: LanguagePreferenceStore.legacyKey)
        let store = LanguagePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.loadSelection(), .fixed(.russian))
        XCTAssertEqual(
            defaults.string(forKey: LanguagePreferenceStore.selectionKey),
            SupportedLanguage.russian.rawValue
        )
        XCTAssertNil(defaults.object(forKey: LanguagePreferenceStore.legacyKey))
    }

    func testPreferenceStoreKeepsValidNewSelectionOverLegacyValue() {
        let defaults = makeDefaults()
        defaults.set("ar", forKey: LanguagePreferenceStore.selectionKey)
        defaults.set("English 🇬🇧", forKey: LanguagePreferenceStore.legacyKey)
        let store = LanguagePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.loadSelection(), .fixed(.arabic))
        XCTAssertNil(defaults.object(forKey: LanguagePreferenceStore.legacyKey))
    }

    func testPreferenceStoreNormalizesInvalidValuesToSystem() {
        let defaults = makeDefaults()
        defaults.set("not-a-language", forKey: LanguagePreferenceStore.selectionKey)
        defaults.set("Deutsch 🇩🇪", forKey: LanguagePreferenceStore.legacyKey)
        let store = LanguagePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.loadSelection(), .system)
        XCTAssertEqual(defaults.string(forKey: LanguagePreferenceStore.selectionKey), "system")
        XCTAssertNil(defaults.object(forKey: LanguagePreferenceStore.legacyKey))
    }

    func testPreferenceStoreIsSharedAcrossInstancesUsingSameSuite() {
        let suite = makeSuiteName()
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationAppGroup-\(UUID().uuidString)", isDirectory: true)
        guard let writer = LanguagePreferenceStore.appGroup(
            suiteName: suite,
            containerURLProvider: { _ in containerURL }
        ),
              let reader = LanguagePreferenceStore.appGroup(
                suiteName: suite,
                containerURLProvider: { _ in containerURL }
              ) else {
            return XCTFail("Expected an isolated UserDefaults suite")
        }

        XCTAssertTrue(writer.saveSelection(.fixed(.spanish)))
        XCTAssertEqual(reader.loadSelection(), .fixed(.spanish))
    }

    func testUnavailableAppGroupDoesNotCreateASeparatePersistentStore() {
        let suite = makeSuiteName()

        XCTAssertNil(
            LanguagePreferenceStore.appGroup(
                suiteName: suite,
                containerURLProvider: { _ in nil }
            )
        )
    }

    func testLocalizationServiceFallsBackToEnglishBeforeCallerFallback() throws {
        let fixture = try makeBundleFixture(
            strings: [
                .english: ["greeting": "Hello"],
                .french: [:]
            ]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .french,
                selection: .fixed(.french),
                provider: fixture.provider
            )
        )

        XCTAssertEqual(
            service.text(key: "greeting", fallback: "Fallback"),
            "Hello"
        )
        XCTAssertEqual(
            service.text(key: "unknown", fallback: "Fallback"),
            "Fallback"
        )
        XCTAssertEqual(
            service.text(key: "unknown", fallback: "   "),
            "unknown"
        )
    }

    func testMissingEnglishLprojDoesNotUseImplicitRootLocalization() throws {
        let fixture = try makeBundleFixture(
            strings: [.french: [:]],
            rootStrings: ["greeting": "Implicit root value"]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .french,
                selection: .fixed(.french),
                provider: fixture.provider
            )
        )

        XCTAssertEqual(
            service.text(key: "greeting", fallback: "Explicit fallback"),
            "Explicit fallback"
        )
    }

    func testLocalizationServiceTreatsWhitespaceTranslationAsMissing() throws {
        let fixture = try makeBundleFixture(
            strings: [
                .english: ["greeting": "Hello"],
                .arabic: ["greeting": "  \n "]
            ]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .arabic,
                selection: .fixed(.arabic),
                provider: fixture.provider
            )
        )

        XCTAssertEqual(service.text(key: "greeting", fallback: "Fallback"), "Hello")
    }

    func testLocalizationServiceFormatsTypedArgumentsWithResolvedLocale() throws {
        let fixture = try makeBundleFixture(
            strings: [
                .english: ["welcome": "Hello, %@ (%d)"],
                .french: ["welcome": "Bonjour, %@ (%d)"]
            ]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .french,
                selection: .fixed(.french),
                provider: fixture.provider,
                baseLocale: Locale(identifier: "en_US")
            )
        )

        XCTAssertEqual(
            service.format(
                key: "welcome",
                fallback: "Hi, %@ (%d)",
                arguments: ["Alice", 3]
            ),
            "Bonjour, Alice (3)"
        )
    }

    func testLegacyFormatSafelyAdaptsStringArgumentsForNumericSpecifiers() throws {
        let fixture = try makeBundleFixture(
            strings: [.english: ["legacy": "%1$d files from %2$@"]]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .english,
                selection: .fixed(.english),
                provider: fixture.provider
            )
        )

        XCTAssertEqual(
            service.legacyFormat(
                key: "legacy",
                fallback: "%1$d files from %2$@",
                arguments: ["3", "Alice"]
            ),
            "3 files from Alice"
        )
    }

    func testPluralUsesCatalogRulesForAllSupportedLanguages() throws {
        let forms: [SupportedLanguage: [String: String]] = [
            .english: ["one": "%d en-one", "other": "%d en-other"],
            .russian: ["one": "%d ru-one", "few": "%d ru-few", "many": "%d ru-many", "other": "%d ru-other"],
            .french: ["one": "%d fr-one", "other": "%d fr-other"],
            .spanish: ["one": "%d es-one", "other": "%d es-other"],
            .arabic: ["zero": "%d ar-zero", "one": "%d ar-one", "two": "%d ar-two", "few": "%d ar-few", "many": "%d ar-many", "other": "%d ar-other"],
            .simplifiedChinese: ["other": "%d zh-other"]
        ]
        let fixture = try makeBundleFixture(
            strings: Dictionary(uniqueKeysWithValues: SupportedLanguage.allCases.map { ($0, [:]) }),
            pluralForms: forms
        )
        let cases: [(SupportedLanguage, Int, String)] = [
            (.english, 1, "1 en-one"), (.english, 2, "2 en-other"),
            (.russian, 1, "1 ru-one"), (.russian, 2, "2 ru-few"), (.russian, 5, "5 ru-many"),
            (.french, 1, "1 fr-one"), (.french, 2, "2 fr-other"),
            (.spanish, 1, "1 es-one"), (.spanish, 2, "2 es-other"),
            (.arabic, 0, "0 ar-zero"), (.arabic, 1, "1 ar-one"), (.arabic, 2, "2 ar-two"),
            (.arabic, 3, "3 ar-few"), (.arabic, 11, "11 ar-many"), (.arabic, 100, "100 ar-other"),
            (.simplifiedChinese, 2, "2 zh-other")
        ]

        for (language, count, expected) in cases {
            let service = LocalizationService(
                context: makeContext(
                    language: language,
                    selection: .fixed(language),
                    provider: fixture.provider
                )
            )
            XCTAssertEqual(
                service.plural(key: "item_count", count: count, fallback: "%d fallback"),
                expected,
                "\(language.rawValue): \(count)"
            )
        }
    }

    func testPluralPlacesCountBeforeAdditionalTypedArguments() throws {
        let fixture = try makeBundleFixture(
            strings: [.english: [:]],
            pluralForms: [
                .english: [
                    "one": "%d item by %@",
                    "other": "%d items by %@"
                ]
            ]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .english,
                selection: .fixed(.english),
                provider: fixture.provider
            )
        )

        XCTAssertEqual(
            service.plural(
                key: "item_count",
                count: 3,
                fallback: "%d items by %@",
                arguments: ["Alice"]
            ),
            "3 items by Alice"
        )
    }

    func testAttributedMarkdownEscapesArgumentsButParsesCatalogMarkup() throws {
        let fixture = try makeBundleFixture(
            strings: [.english: ["welcome_markdown": "**Welcome, %@**"]]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .english,
                selection: .fixed(.english),
                provider: fixture.provider
            )
        )

        let value = service.attributedMarkdown(
            key: "welcome_markdown",
            fallback: "Welcome, %@",
            arguments: ["A_*B"]
        )

        XCTAssertEqual(value.string, "Welcome, A_*B")
    }

    func testAttributedMarkdownDoesNotCreateLinksFromArguments() throws {
        let fixture = try makeBundleFixture(
            strings: [.english: ["welcome_markdown": "**Welcome, %@**"]]
        )
        let service = LocalizationService(
            context: makeContext(
                language: .english,
                selection: .fixed(.english),
                provider: fixture.provider
            )
        )

        let value = service.attributedMarkdown(
            key: "welcome_markdown",
            fallback: "Welcome, %@",
            arguments: ["<https://example.com>"]
        )
        var containsLink = false
        value.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: value.length)
        ) { attribute, _, _ in
            containsLink = containsLink || attribute != nil
        }

        XCTAssertEqual(value.string, "Welcome, <https://example.com>")
        XCTAssertFalse(containsLink)
    }

    func testFormatterFactoryUsesContextLocaleCalendarAndTimeZone() throws {
        let fixture = try makeBundleFixture(strings: [.english: [:], .french: [:]])
        var calendar = Calendar(identifier: .buddhist)
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Yekaterinburg"))
        calendar.timeZone = timeZone
        let context = makeContext(
            language: .french,
            selection: .fixed(.french),
            provider: fixture.provider,
            baseLocale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: timeZone,
            revision: 42
        )
        let factory = LocalizationFormatterFactory(context: context)

        let dateFormatter = factory.dateFormatter(dateStyle: .short, timeStyle: .short)
        let numberFormatter = factory.numberFormatter(style: .decimal)
        let relativeFormatter = factory.relativeDateTimeFormatter()
        let listFormatter = factory.listFormatter()
        let byteFormatter = factory.byteCountFormatter(countStyle: .file)

        XCTAssertEqual(factory.revision, 42)
        XCTAssertEqual(dateFormatter.locale.languageCode, "fr")
        XCTAssertEqual(dateFormatter.locale.regionCode, "US")
        XCTAssertEqual(dateFormatter.calendar.identifier, .buddhist)
        XCTAssertEqual(dateFormatter.timeZone, timeZone)
        XCTAssertEqual(numberFormatter.locale.languageCode, "fr")
        XCTAssertEqual(relativeFormatter.locale.languageCode, "fr")
        XCTAssertEqual(listFormatter.locale.languageCode, "fr")
        XCTAssertEqual(byteFormatter.countStyle, .file)
    }

    func testLocalizationServicePublishesOnlyCompleteContextSnapshots() throws {
        let fixture = try makeBundleFixture(
            strings: [
                .english: ["value": "English"],
                .arabic: ["value": "Arabic"]
            ]
        )
        let english = makeContext(
            language: .english,
            selection: .fixed(.english),
            provider: fixture.provider,
            revision: 1
        )
        let arabic = makeContext(
            language: .arabic,
            selection: .fixed(.arabic),
            provider: fixture.provider,
            revision: 2
        )
        let service = LocalizationService(context: english)
        let failureLock = NSLock()
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            service.replaceContext(index.isMultiple(of: 2) ? english : arabic)
            let snapshot = service.context
            let validEnglish = snapshot.resolvedLanguage == .english
                && snapshot.layoutDirection == .leftToRight
                && snapshot.locale.languageCode == "en"
                && snapshot.revision == 1
            let validArabic = snapshot.resolvedLanguage == .arabic
                && snapshot.layoutDirection == .rightToLeft
                && snapshot.locale.languageCode == "ar"
                && snapshot.revision == 2
            if !(validEnglish || validArabic) {
                failureLock.lock()
                failures.append("Torn snapshot: \(snapshot)")
                failureLock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.first ?? "")
    }

    func testRuntimeRefreshKeepsRevisionWhenSemanticInputsAreUnchanged() throws {
        let fixture = try makeBundleFixture(strings: [.english: [:]])
        let defaults = makeDefaults()
        let store = LanguagePreferenceStore(defaults: defaults)
        XCTAssertTrue(store.saveSelection(.fixed(.english)))
        let runtime = LocalizationRuntime(
            initialBundleProvider: fixture.provider,
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let initial = runtime.bootstrap(
            preferenceStore: store,
            bundleProvider: fixture.provider,
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let refreshed = runtime.refresh(
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(refreshed.revision, initial.revision)
        XCTAssertEqual(refreshed, initial)
    }

    func testRuntimeRefreshAdvancesRevisionWhenSystemLanguageChanges() throws {
        let fixture = try makeBundleFixture(strings: [.english: [:], .russian: [:]])
        let defaults = makeDefaults()
        let store = LanguagePreferenceStore(defaults: defaults)
        XCTAssertTrue(store.saveSelection(.system))
        let runtime = LocalizationRuntime(
            initialBundleProvider: fixture.provider,
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let initial = runtime.bootstrap(
            preferenceStore: store,
            bundleProvider: fixture.provider,
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let refreshed = runtime.refresh(
            preferredLanguages: ["ru-RU"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(refreshed.resolvedLanguage, .russian)
        XCTAssertGreaterThan(refreshed.revision, initial.revision)
    }

    func testRuntimeRefreshAdvancesRevisionWhenCalendarWeekRulesChange() throws {
        let fixture = try makeBundleFixture(strings: [.english: [:]])
        let defaults = makeDefaults()
        let store = LanguagePreferenceStore(defaults: defaults)
        XCTAssertTrue(store.saveSelection(.fixed(.english)))
        let runtime = LocalizationRuntime(initialBundleProvider: fixture.provider)
        var initialCalendar = Calendar(identifier: .gregorian)
        initialCalendar.firstWeekday = 1
        initialCalendar.minimumDaysInFirstWeek = 1
        let initial = runtime.bootstrap(
            preferenceStore: store,
            bundleProvider: fixture.provider,
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: initialCalendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        var changedCalendar = initialCalendar
        changedCalendar.firstWeekday = 2
        changedCalendar.minimumDaysInFirstWeek = 4

        let refreshed = runtime.refresh(
            preferredLanguages: ["en"],
            locale: Locale(identifier: "en_US"),
            calendar: changedCalendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(refreshed.calendar.firstWeekday, 2)
        XCTAssertEqual(refreshed.calendar.minimumDaysInFirstWeek, 4)
        XCTAssertGreaterThan(refreshed.revision, initial.revision)
    }

    func testRuntimeRefreshKeepsFixedLanguageWhileUpdatingRegionAndTimeZone() throws {
        let fixture = try makeBundleFixture(strings: [.english: [:], .french: [:]])
        let defaults = makeDefaults()
        let store = LanguagePreferenceStore(defaults: defaults)
        XCTAssertTrue(store.saveSelection(.fixed(.french)))
        let utc = TimeZone(secondsFromGMT: 0)!
        let runtime = LocalizationRuntime(initialBundleProvider: fixture.provider)
        let initial = runtime.bootstrap(
            preferenceStore: store,
            bundleProvider: fixture.provider,
            preferredLanguages: ["en-US"],
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: utc
        )
        let changedTimeZone = TimeZone(secondsFromGMT: 3_600)!

        let refreshed = runtime.refresh(
            preferredLanguages: ["ru-RU"],
            locale: Locale(identifier: "en_GB"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: changedTimeZone
        )

        XCTAssertEqual(refreshed.resolvedLanguage, .french)
        XCTAssertEqual(refreshed.locale.regionCode, "GB")
        XCTAssertEqual(refreshed.timeZone, changedTimeZone)
        XCTAssertEqual(refreshed.calendar.timeZone, changedTimeZone)
        XCTAssertGreaterThan(refreshed.revision, initial.revision)
    }

    // MARK: - Helpers

    private func makeSuiteName() -> String {
        let suite = "LocalizationCoreTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return suite
    }

    private func makeDefaults() -> UserDefaults {
        let suite = makeSuiteName()
        return UserDefaults(suiteName: suite)!
    }

    private func makeContext(
        language: SupportedLanguage,
        selection: AppLanguageSelection,
        provider: LocalizedBundleProviding,
        baseLocale: Locale = Locale(identifier: "en_US"),
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
        revision: UInt64 = 1
    ) -> LocalizationContext {
        LanguageResolver.makeContext(
            selection: selection,
            preferredLanguages: [language.rawValue],
            baseLocale: baseLocale,
            calendar: calendar,
            timeZone: timeZone,
            bundleProvider: provider,
            revision: revision
        )
    }

    private func makeBundleFixture(
        strings: [SupportedLanguage: [String: String]],
        pluralForms: [SupportedLanguage: [String: String]] = [:],
        rootStrings: [String: String]? = nil
    ) throws -> BundleFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationCoreTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Fixture.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        temporaryDirectories.append(root)

        let info: [String: Any] = [
            "CFBundleIdentifier": "tests.localization.\(UUID().uuidString)",
            "CFBundleName": "LocalizationFixture",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": strings.keys.map(\.rawValue)
        ]
        try writePropertyList(info, to: bundleURL.appendingPathComponent("Info.plist"))

        if let rootStrings {
            try writePropertyList(
                rootStrings,
                to: bundleURL.appendingPathComponent("Localizable.strings")
            )
        }

        for language in Set(strings.keys).union(pluralForms.keys) {
            let lprojURL = bundleURL.appendingPathComponent("\(language.rawValue).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: true)
            try writePropertyList(
                strings[language] ?? [:],
                to: lprojURL.appendingPathComponent("Localizable.strings")
            )
            if let forms = pluralForms[language] {
                let stringsDict: [String: Any] = [
                    "item_count": [
                        "NSStringLocalizedFormatKey": "%#@items@",
                        "items": [
                            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                            "NSStringFormatValueTypeKey": "d"
                        ].merging(forms) { _, form in form }
                    ]
                ]
                try writePropertyList(
                    stringsDict,
                    to: lprojURL.appendingPathComponent("Localizable.stringsdict")
                )
            }
        }

        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))
        return BundleFixture(bundle: bundle)
    }

    private func writePropertyList(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}

private struct BundleFixture {
    let bundle: Bundle

    var provider: LprojBundleProvider {
        LprojBundleProvider(resourceBundle: bundle)
    }
}
