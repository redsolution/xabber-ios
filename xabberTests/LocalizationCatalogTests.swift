import XCTest
@testable import xabber

final class LocalizationCatalogTests: XCTestCase {
    private let supportedLocales = Set(SupportedLanguage.allCases.map(\.rawValue))

    func testCompiledAppAndExtensionContainOnlySupportedLocalizations() throws {
        let extensionBundle = try pushExtensionBundle()

        XCTAssertEqual(
            topLevelLocalizationDirectories(in: .main),
            supportedLocales.union(["Base"])
        )
        XCTAssertEqual(
            topLevelLocalizationDirectories(in: extensionBundle),
            supportedLocales
        )
    }

    func testCompiledLocalizationResourcesAreIdenticalInAppAndExtension() throws {
        let extensionBundle = try pushExtensionBundle()

        for locale in supportedLocales.sorted() {
            let appResources = localizedResourceNames(locale: locale, bundle: .main)
            let extensionResources = localizedResourceNames(
                locale: locale,
                bundle: extensionBundle
            )
            XCTAssertTrue(
                appResources.contains("Localizable.strings"),
                "Missing compiled strings for \(locale)"
            )
            XCTAssertEqual(
                appResources,
                extensionResources,
                "Compiled resource set differs for \(locale)"
            )

            for resource in appResources.sorted() {
                let appData = try XCTUnwrap(localizedResourceData(
                    resource,
                    locale: locale,
                    bundle: .main
                ))
                let extensionData = try XCTUnwrap(localizedResourceData(
                    resource,
                    locale: locale,
                    bundle: extensionBundle
                ))
                XCTAssertEqual(
                    appData,
                    extensionData,
                    "Compiled resource differs for \(locale)/\(resource)"
                )
            }
        }
    }

    func testSimpleTranslationPlaceholderSignaturesMatchEnglish() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)
        let explicitEnglishKeys = try catalogStrings().compactMap { key, value -> String? in
            guard let localizations = value["localizations"] as? [String: Any],
                  localizations[SupportedLanguage.english.rawValue] != nil else {
                return nil
            }
            return key
        }

        for locale in supportedLocales.subtracting([SupportedLanguage.english.rawValue]) {
            let localized = try strings(locale: locale)
            for key in explicitEnglishKeys {
                guard let englishValue = english[key] else { continue }
                guard let localizedValue = localized[key] else { continue }
                XCTAssertEqual(
                    placeholderSignature(localizedValue),
                    placeholderSignature(englishValue),
                    "Placeholder mismatch for \(locale)/\(key)"
                )
            }
        }
    }

    func testResolvedCatalogConflictsUseCanonicalValues() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)

        XCTAssertNil(english["chat"])
        XCTAssertEqual(english["feedback"], "Feedback")
        XCTAssertEqual(
            english["public_group_invitation"],
            "You are invited to join this public group"
        )
        XCTAssertEqual(
            english["incognito_group_invitation"],
            "You are invited to join this incognito group"
        )
        XCTAssertEqual(english["settings_language_system"], "System")
        XCTAssertNotNil(english["settings__dialog_change_language__header"])
    }

    func testCanonicalEnglishContainsStageTwoConflictResolutions() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)

        XCTAssertEqual(
            english["settings_account__label_active_sessions"],
            "Active sessions"
        )
        XCTAssertEqual(
            english["settings_account__label_active_devices"],
            "Active devices"
        )
        XCTAssertEqual(
            english["signin_server_capabilities_retryable_subtitle"],
            "Server capabilities will be checked again automatically."
        )
        XCTAssertEqual(
            english["signin_server_capabilities_partial_failure_subtitle"],
            "Some server capabilities could not be verified right now. You can continue safely; the app will retry automatically."
        )
        XCTAssertEqual(english["push_invitation_sender_unknown"], "Someone")
        XCTAssertEqual(english["push_sender_unknown"], "Somebody")
        XCTAssertNil(english["somebody"])
    }

    func testActiveKeyManifestHasCompleteEnglishAndNoUnresolvedLookups() throws {
        let manifest = try localizationManifest()
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)

        let summary = try XCTUnwrap(manifest["summary"] as? [String: Any])
        XCTAssertEqual(summary["activeWithoutEnglish"] as? Int, 0)
        XCTAssertEqual(summary["unresolvedDynamicCalls"] as? Int, 0)
        XCTAssertEqual(summary["directLookups"] as? Int, 0)
        XCTAssertEqual(summary["dynamicDomains"] as? Int, 7)
        XCTAssertTrue(try XCTUnwrap(
            manifest["unresolvedDynamicCalls"] as? [[String: Any]]
        ).isEmpty)
        XCTAssertTrue(try XCTUnwrap(
            manifest["directLookups"] as? [[String: Any]]
        ).isEmpty)

        let catalog = try catalogStrings()
        let activeKeys = try XCTUnwrap(
            manifest["activeKeys"] as? [[String: Any]]
        )
        XCTAssertFalse(activeKeys.isEmpty)
        for active in activeKeys {
            let key = try XCTUnwrap(active["key"] as? String)
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let english = try XCTUnwrap(
                localizations[SupportedLanguage.english.rawValue],
                key
            )
            XCTAssertTrue(
                containsNonemptyLocalizedValue(english),
                "Active key has no nonempty English value: \(key)"
            )
        }
    }

    func testManifestCallsitesMatchCatalogPlaceholderContracts() throws {
        let manifest = try localizationManifest()
        let activeKeys = try XCTUnwrap(
            manifest["activeKeys"] as? [[String: Any]]
        )

        for active in activeKeys {
            let key = try XCTUnwrap(active["key"] as? String)
            let expected = try XCTUnwrap(
                active["formatSignature"] as? [[String: Any]],
                key
            )
            let expectedCount = expected.compactMap { $0["argument"] as? Int }.max() ?? 0
            let callsites = try XCTUnwrap(
                active["callsites"] as? [[String: Any]],
                key
            )
            for callsite in callsites {
                let api = try XCTUnwrap(callsite["api"] as? String, key)
                let argumentCount = try XCTUnwrap(
                    callsite["argumentCount"] as? Int,
                    "Unknown argument count for \(key)"
                )
                let providedCount = argumentCount + (api == "plural" ? 1 : 0)
                XCTAssertEqual(
                    providedCount,
                    expectedCount,
                    "Argument count mismatch for \(key)"
                )

                guard callsite["typeSafety"] as? String != "typeUnchecked",
                      callsite["fallback"] is String,
                      let actual = callsite["formatSignature"] as? [[String: Any]] else {
                    continue
                }
                let matches = signaturesEqual(actual, expected) || (
                    api == "plural" &&
                    signaturesEqual(actual, removingPluralCount(from: expected))
                )
                XCTAssertTrue(matches, "Placeholder signature mismatch for \(key)")
            }
        }
    }

    func testCorrectedFormattingKeysSubstituteRuntimeArguments() {
        let english = localizationService(language: .english)
        let domain = "xmpp.example.test"
        let group = "Friends"
        let contact = "Alex"

        let certificate = english.format(
            key: "account_identity_not_verified_proceed_anyway",
            fallback: "The identity of \"%@\" cannot be verified.",
            arguments: [domain]
        )
        let duplicateCircle = english.format(
            key: "account_circle_already_exists",
            fallback: "Circle \"%@\" already exists",
            arguments: [group]
        )
        let deleteContact = english.format(
            key: "contact_delete_confirm_short",
            fallback: "Do you really want to delete contact %@?",
            arguments: [contact]
        )

        XCTAssertTrue(certificate.contains(domain))
        XCTAssertTrue(duplicateCircle.contains(group))
        XCTAssertTrue(deleteContact.contains(contact))
        XCTAssertFalse(certificate.contains("%@"))
        XCTAssertFalse(duplicateCircle.contains("%@"))
        XCTAssertFalse(deleteContact.contains("%@"))
    }

    func testStageTwoNativePluralsReplaceActiveManualFamilies() throws {
        let catalog = try catalogStrings()
        let expectedPluralKeys = [
            "groupchat__toast__invitations_sent",
            "chat_list__attachment_preview__photos_count",
            "chat_list__attachment_preview__videos_count",
            "chat_list__attachment_preview__files_count",
            "chat_list__attachment_preview__voice_messages_count"
        ]

        for key in expectedPluralKeys {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let english = try XCTUnwrap(
                localizations[SupportedLanguage.english.rawValue] as? [String: Any],
                key
            )
            let variations: [String: Any]
            if let direct = english["variations"] as? [String: Any] {
                variations = direct
            } else {
                let substitutions = try XCTUnwrap(
                    english["substitutions"] as? [String: Any],
                    key
                )
                let substitution = try XCTUnwrap(
                    substitutions.values.first as? [String: Any],
                    key
                )
                variations = try XCTUnwrap(
                    substitution["variations"] as? [String: Any],
                    key
                )
            }
            let plural = try XCTUnwrap(
                variations["plural"] as? [String: Any],
                key
            )
            XCTAssertNotNil(plural["other"], key)
        }

        XCTAssertFalse(
            catalog.keys.contains { $0.hasPrefix("plurals.last_chat_attachment_preview__") }
        )
        XCTAssertFalse(
            catalog.keys.contains { $0.hasPrefix("plurals.groupchat__toast__invitations_sent.") }
        )
    }

    func testActivePlainTextConfirmationContainsNoLegacyHTML() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)
        let value = try XCTUnwrap(english["contact_delete_confirm_short"])

        XCTAssertEqual(value, "Do you really want to delete contact %@?")
        XCTAssertFalse(value.contains("<b>"))
        XCTAssertFalse(value.contains("</b>"))
    }

    func testInvitationPluralSelectsGrammarWithoutDisplayingCount() {
        let english = localizationService(language: .english)
        let russian = localizationService(language: .russian)
        let french = localizationService(language: .french)

        XCTAssertEqual(
            english.plural(
                key: "groupchat__toast__invitations_sent",
                count: 1,
                fallback: "Invitation sent"
            ),
            "Invitation sent"
        )
        XCTAssertEqual(
            english.plural(
                key: "groupchat__toast__invitations_sent",
                count: 3,
                fallback: "Invitations sent"
            ),
            "Invitations sent"
        )
        XCTAssertEqual(
            russian.plural(
                key: "groupchat__toast__invitations_sent",
                count: 1,
                fallback: "Invitation sent"
            ),
            "Приглашение отправлено"
        )
        XCTAssertEqual(
            russian.plural(
                key: "groupchat__toast__invitations_sent",
                count: 21,
                fallback: "Invitations sent"
            ),
            "Приглашение отправлено"
        )
        XCTAssertEqual(
            russian.plural(
                key: "groupchat__toast__invitations_sent",
                count: 5,
                fallback: "Invitations sent"
            ),
            "Приглашения отправлены"
        )
        XCTAssertEqual(
            french.plural(
                key: "groupchat__toast__invitations_sent",
                count: 2,
                fallback: "Invitations sent"
            ),
            "Invitations sent"
        )
    }

    func testLastChatAttachmentPluralsUseEnglishRussianAndEnglishFallback() {
        let english = localizationService(language: .english)
        let russian = localizationService(language: .russian)
        let french = localizationService(language: .french)
        let cases = [
            ("chat_list__attachment_preview__photos_count", "2 Photos", "2 фото"),
            ("chat_list__attachment_preview__videos_count", "2 Videos", "2 видео"),
            ("chat_list__attachment_preview__files_count", "2 Files", "2 файла"),
            ("chat_list__attachment_preview__voice_messages_count", "2 Voice messages", "2 голосовых сообщения")
        ]

        for (key, englishValue, russianValue) in cases {
            XCTAssertEqual(
                english.plural(key: key, count: 2, fallback: englishValue),
                englishValue,
                key
            )
            XCTAssertEqual(
                russian.plural(key: key, count: 2, fallback: englishValue),
                russianValue,
                key
            )
            XCTAssertEqual(
                french.plural(key: key, count: 2, fallback: englishValue),
                englishValue,
                key
            )
        }
    }

    private func pushExtensionBundle() throws -> Bundle {
        let plugInsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil
        )
        let url = try XCTUnwrap(
            urls.first {
                $0.pathExtension == "appex" &&
                    $0.lastPathComponent.contains("push-extension")
            }
        )
        return try XCTUnwrap(Bundle(url: url))
    }

    private func localizationService(language: SupportedLanguage) -> LocalizationService {
        let provider = LprojBundleProvider(resourceBundle: .main)
        let context = LanguageResolver.makeContext(
            selection: .fixed(language),
            preferredLanguages: [language.rawValue],
            baseLocale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bundleProvider: provider,
            revision: 1
        )
        return LocalizationService(context: context)
    }

    private func topLevelLocalizationDirectories(in bundle: Bundle) -> Set<String> {
        guard let resourceURL = bundle.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else {
            return []
        }
        return Set(
            urls
                .filter { $0.pathExtension == "lproj" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    private func localizedResourceData(
        _ resource: String,
        locale: String,
        bundle: Bundle
    ) throws -> Data? {
        guard let root = bundle.resourceURL else {
            return nil
        }
        let url = root
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent(resource)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func localizedResourceNames(
        locale: String,
        bundle: Bundle
    ) -> Set<String> {
        guard let root = bundle.resourceURL else { return [] }
        let localeURL = root.appendingPathComponent("\(locale).lproj", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: localeURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return Set(
            urls
                .map(\.lastPathComponent)
                .filter { $0 == "Localizable.strings" || $0 == "Localizable.stringsdict" }
        )
    }

    private func catalogStrings() throws -> [String: [String: Any]] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("xabber/translations/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(json as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func localizationManifest() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot
            .appendingPathComponent("docs/localization/active-keys.json")
        let data = try Data(contentsOf: manifestURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func containsNonemptyLocalizedValue(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let string = dictionary["value"] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return dictionary.values.contains(where: containsNonemptyLocalizedValue)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNonemptyLocalizedValue)
        }
        return false
    }

    private func signaturesEqual(
        _ lhs: [[String: Any]],
        _ rhs: [[String: Any]]
    ) -> Bool {
        NSArray(array: lhs).isEqual(to: rhs)
    }

    private func removingPluralCount(
        from signature: [[String: Any]]
    ) -> [[String: Any]] {
        signature.filter { item in
            guard item["argument"] as? Int == 1,
                  item["role"] == nil,
                  let conversion = item["conversion"] as? String else {
                return true
            }
            return !["d", "i", "u"].contains(String(conversion.suffix(1)))
        }
    }

    private func strings(locale: String) throws -> [String: String] {
        guard let root = Bundle.main.resourceURL else {
            return [:]
        }
        let url = root
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: String])
    }

    private func placeholderSignature(_ value: String) -> [String] {
        let pattern = #"%(?!%)(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return String(value[range])
        }.sorted()
    }
}

enum LocalizationCatalogTestFixture {
    static func localizedKeys(for language: String) throws -> Set<String> {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("xabber/translations/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]] else {
            throw NSError(
                domain: "LocalizationCatalogTestFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Localizable.xcstrings"]
            )
        }
        return Set(strings.compactMap { key, entry in
            guard let localizations = entry["localizations"] as? [String: Any],
                  let localization = localizations[language],
                  containsNonemptyLocalizedValue(localization) else {
                return nil
            }
            return key
        })
    }

    private static func containsNonemptyLocalizedValue(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let string = dictionary["value"] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return dictionary.values.contains(where: containsNonemptyLocalizedValue)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNonemptyLocalizedValue)
        }
        return false
    }
}
