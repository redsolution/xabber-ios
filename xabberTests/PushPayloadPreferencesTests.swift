import XCTest
@testable import xabber

final class PushPayloadPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "PushPayloadPreferencesTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    func testMissingOrInvalidPreferencePreservesCompactDefault() {
        XCTAssertEqual(PushPayloadPreferences.read(defaults: defaults), .summary)
        defaults.set("partial", forKey: PushPayloadPreferences.key)
        XCTAssertEqual(PushPayloadPreferences.read(defaults: defaults), .summary)
    }

    func testChangedPreferenceIsDurableBeforeRegistrationRefresh() {
        var refreshedModes: [PushPayloadMode] = []
        PushPayloadPreferences.set(.full, defaults: defaults) {
            refreshedModes.append(PushPayloadPreferences.read(defaults: self.defaults))
        }
        XCTAssertEqual(defaults.string(forKey: PushPayloadPreferences.key), "full")
        XCTAssertEqual(refreshedModes, [.full])
        let reopened = UserDefaults(suiteName: suite)
        XCTAssertEqual(PushPayloadPreferences.read(defaults: reopened), .full)
    }

    func testRepeatedChoiceDoesNotRefreshAndSoundSettingsRemainIndependent() {
        defaults.set(false, forKey: NotificationSoundPreference.messages.rawValue)
        defaults.set("full", forKey: PushPayloadPreferences.key)
        var refreshes = 0
        PushPayloadPreferences.set(.full, defaults: defaults) { refreshes += 1 }
        XCTAssertEqual(refreshes, 0)
        PushPayloadPreferences.set(.summary, defaults: defaults) { refreshes += 1 }
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(PushPayloadPreferences.read(defaults: defaults), .summary)
        XCTAssertFalse(defaults.bool(forKey: NotificationSoundPreference.messages.rawValue))
    }
}
