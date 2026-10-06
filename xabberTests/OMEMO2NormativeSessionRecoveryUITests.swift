import UIKit
import RealmSwift
import XCTest
@testable import xabber

@MainActor
final class OMEMO2NormativeSessionRecoveryUITests: XCTestCase {
    func testEnabledAccountOffersReplacementBesideThisDeviceWithoutChangingDeviceControls() throws {
        try withController(enabled: true) { controller, table in
            XCTAssertEqual(controller.tableView(table, numberOfRowsInSection: 0), 3)
            guard controller.tableView(table, numberOfRowsInSection: 0) == 3 else { return }
            let action = controller.tableView(table, cellForRowAt: IndexPath(row: 2, section: 0))
            XCTAssertEqual(action.accessibilityIdentifier, "omemo.sessions.replace")
            XCTAssertEqual(controller.tableView(table, numberOfRowsInSection: 0), 3)
        }
    }

    func testSelectingReplacementOffersExplicitConfirmationAndCancellation() throws {
        try withController(enabled: true) { controller, table in
            table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 2, section: 0))
            let prompt = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
            XCTAssertEqual(prompt.view.accessibilityIdentifier, "omemo.sessions.replace.confirmation")
            XCTAssertEqual(prompt.actions.map(\.style), [.cancel, .destructive])
            XCTAssertFalse(prompt.message?.isEmpty ?? true)
        }
    }

    func testDisabledAccountDoesNotOfferReplacement() throws {
        try withController(enabled: false) { controller, table in
            XCTAssertEqual(controller.numberOfSections(in: table), 0)
        }
    }

    func testReceiveAndSessionReplacementTranslationsExistAndCompileInAllSupportedLocales() throws {
        let expectedEnglish = [
            "omemo_sessions_replace": "Replace encryption sessions",
            "omemo_sessions_replace_confirmation": "Replace all encryption sessions for this account? Your fingerprint, trusted devices and message history will be kept.",
            "omemo_sessions_replace_failed": "Could not replace encryption sessions. Try again.",
            "omemo_sessions_replace_success": "Encryption sessions replaced. They will be rebuilt when you send a message.",
            "chat_list__preview__decrypt_failed": "Failed to decrypt",
            "chat_list__preview__encrypted_message": "Encrypted message",
            "xabber_axolotl_storage__localized_error_description__omemo2_state_requires_profile_storage": "Existing OMEMO2 state must be prepared without replacing legacy key material"
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

    private func withController(enabled: Bool, _ body: (AccountEncryptionInfoViewController, UITableView) throws -> Void) throws {
        let old = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N07-UI-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = old }
        let realm = try WRealm.safe()
        let account = AccountStorageItem()
        account.jid = "ui-replacement-\(UUID())@example.test"
        account.isEncryptionEnabled = enabled
        try realm.write { realm.add(account) }
        let controller = AccountEncryptionInfoViewController()
        controller.owner = account.jid
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { controller.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil }
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(controller.view.subviews.first(where: { $0 is UITableView }) as? UITableView)
        try body(controller, table)
    }
}
