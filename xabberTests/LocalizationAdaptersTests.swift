import XCTest
@testable import xabber

final class LocalizationAdaptersTests: XCTestCase {
    private var defaultsSuites: [String] = []

    override func tearDown() {
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        super.tearDown()
    }

    func testLegacyStringAdapterSafelyFormatsStringArgumentsForNumericPlaceholders() {
        let result = "%d files for %@".localizeString(
            id: "test.localization.adapters.legacy_format",
            arguments: ["3", "Alice"]
        )

        XCTAssertEqual(result, "3 files for Alice")
    }

    func testPushLocalizationFacadeUsesSharedRuntime() {
        let result = PushNotificationLocalization.string(
            "test.localization.adapters.push_format",
            fallback: "Hello, %@",
            "Alice"
        )

        XCTAssertEqual(
            result,
            L10n.format(
                "test.localization.adapters.push_format",
                fallback: "Hello, %@",
                arguments: ["Alice"]
            )
        )
    }

    func testPushNewMessageUsesSharedRuntime() {
        XCTAssertEqual(
            PushNotificationLocalization.newMessage(),
            L10n.text(
                "plurals.new_chat_messages.item_0",
                fallback: "New message"
            )
        )
    }

    func testChatSearchProductionUsesSharedLocalizationContext() {
        XCTAssertEqual(
            ChatSearchLocalization.production().locale,
            L10n.context.locale
        )
    }

    func testPushRequestBootstrapRereadsSelectionAndMatchesAppContext() {
        let suite = "LocalizationAdaptersTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let store = LanguagePreferenceStore(defaults: defaults)
        let provider = LprojBundleProvider(resourceBundle: .main)
        let pushRuntime = LocalizationRuntime(initialBundleProvider: provider)
        let appRuntime = LocalizationRuntime(initialBundleProvider: provider)
        let locale = Locale(identifier: "en_US")
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertTrue(store.saveSelection(.fixed(.english)))
        let firstRequest = PushNotificationLocalization.prepareForIncomingRequest(
            runtime: pushRuntime,
            preferenceStore: store,
            bundleProvider: provider,
            preferredLanguages: ["en-US"],
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        XCTAssertEqual(firstRequest.resolvedLanguage, .english)

        XCTAssertTrue(store.saveSelection(.fixed(.arabic)))
        let secondRequest = PushNotificationLocalization.prepareForIncomingRequest(
            runtime: pushRuntime,
            preferenceStore: store,
            bundleProvider: provider,
            preferredLanguages: ["en-US"],
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        let appContext = appRuntime.bootstrap(
            preferenceStore: store,
            bundleProvider: provider,
            preferredLanguages: ["en-US"],
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )

        XCTAssertEqual(secondRequest.resolvedLanguage, .arabic)
        XCTAssertEqual(secondRequest.semanticSignature, appContext.semanticSignature)
        XCTAssertEqual(
            pushRuntime.service.text(key: "chat_reply", fallback: "Reply"),
            appRuntime.service.text(key: "chat_reply", fallback: "Reply")
        )
    }
}
