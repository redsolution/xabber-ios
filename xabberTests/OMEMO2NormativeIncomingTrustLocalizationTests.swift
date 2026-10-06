import Foundation
import XCTest
@testable import xabber

final class OMEMO2NormativeIncomingTrustLocalizationTests: XCTestCase {
    func testIncomingUntrustedWarningExistsAndCompilesInAllSupportedLocales() throws {
        let expectedEnglish = [
            "chat_omemo_untrusted_sender_warning": "This message was received from an untrusted device."
        ]
        let supported = Set(SupportedLanguage.allCases.map(\.rawValue))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalogData = try Data(contentsOf: repo.appendingPathComponent("xabber/translations/Localizable.xcstrings"))
        let catalogRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalog = try XCTUnwrap(catalogRoot["strings"] as? [String: [String: Any]])
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "appex" && $0.lastPathComponent.contains("push-extension") })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        for (key, expected) in expectedEnglish {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), supported, key)
            for locale in supported.sorted() {
                let localized = try XCTUnwrap(localizations[locale] as? [String: Any], "\(locale)/\(key)")
                let unit = try XCTUnwrap(localized["stringUnit"] as? [String: Any], "\(locale)/\(key)")
                let value = try XCTUnwrap(unit["value"] as? String, "\(locale)/\(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(locale)/\(key)")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(locale)/\(key)")
                if locale == SupportedLanguage.english.rawValue { XCTAssertEqual(value, expected, key) }
                for bundle in [Bundle.main, extensionBundle] {
                    let resourceRoot = try XCTUnwrap(bundle.resourceURL)
                    let resource = resourceRoot.appendingPathComponent("\(locale).lproj").appendingPathComponent("Localizable.strings")
                    let data = try Data(contentsOf: resource)
                    let compiled = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String])
                    XCTAssertEqual(compiled[key], value, "\(bundle.bundleURL.lastPathComponent)/\(locale)/\(key)")
                }
            }
        }
    }

}
