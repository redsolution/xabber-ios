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
