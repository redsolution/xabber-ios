import XCTest
@testable import xabber

@MainActor
final class PrivacyProxySettingsTests: XCTestCase {
    private let endpoint = URL(string: "https://proxy.example.net/")!

    func testServerDiscoveryDeallocatesWithPrivacyProxyEnabled() {
        let config = CommonConfigManager.shared
        let previousPolicy = config.config.privacy_proxy_policy
        config.config.privacy_proxy_policy = CommonConfigManager.PrivacyProxyPolicy.manual.rawValue
        defer { config.config.privacy_proxy_policy = previousPolicy }

        var manager: ServerDiscoManager? = ServerDiscoManager(withOwner: "proxy-teardown@example.test")
        weak var releasedManager = manager
        XCTAssertNotNil(releasedManager)

        manager = nil

        XCTAssertNil(releasedManager)
    }

    func testConnectionProbesAdvertisedProxyBeforeSettingsOpenAndRetriesFailureOnce() async {
        var calls: [URL] = []
        let firstResult = expectation(description: "First connection publishes failure")
        let secondResult = expectation(description: "Second connection publishes success")
        let reachability = PrivacyProxyReachability(probe: { url in
            calls.append(url)
            return calls.count == 2
        }, onChange: { availability in
            if availability == .unreachable(host: "proxy.example.net") { firstResult.fulfill() }
            if availability == .reachable(host: "proxy.example.net") { secondResult.fulfill() }
        })
        reachability.connect(discovery: .unknown)
        reachability.updateDiscovery(.advertised(endpoint))
        await fulfillment(of: [firstResult], timeout: 2)
        reachability.updateDiscovery(.advertised(endpoint))
        XCTAssertEqual(calls, [endpoint])

        reachability.disconnect()
        reachability.connect(discovery: .advertised(endpoint))
        await fulfillment(of: [secondResult], timeout: 2)
        reachability.disconnect()
        reachability.connect(discovery: .advertised(endpoint))
        await Task.yield()
        XCTAssertEqual(calls, [endpoint, endpoint])
        XCTAssertEqual(reachability.availability, .reachable(host: "proxy.example.net"))
    }

    func testDisconnectAndEndpointReplacementIgnoreAnInterruptedResult() async {
        let originalStarted = expectation(description: "Original endpoint is being checked")
        let newEndpoint = URL(string: "https://replacement.example.net/")!
        let replacementFinished = expectation(description: "New endpoint check completed")
        var finishOriginal: CheckedContinuation<Bool, Never>?
        let reachability = PrivacyProxyReachability(probe: { url in
            if url == newEndpoint { return true }
            return await withCheckedContinuation {
                finishOriginal = $0
                originalStarted.fulfill()
            }
        }, onChange: { availability in
            if availability == .reachable(host: "replacement.example.net") { replacementFinished.fulfill() }
        })
        reachability.connect(discovery: .advertised(endpoint))
        await fulfillment(of: [originalStarted], timeout: 2)
        reachability.disconnect()
        reachability.updateDiscovery(.advertised(newEndpoint))
        reachability.connect(discovery: .advertised(newEndpoint))
        await fulfillment(of: [replacementFinished], timeout: 2)

        finishOriginal?.resume(returning: false)
        await Task.yield()
        XCTAssertEqual(reachability.availability, .reachable(host: "replacement.example.net"))
        reachability.updateDiscovery(.notAdvertised)
        XCTAssertEqual(reachability.availability, .notAdvertised)
    }

    func testUnknownAndMissingDiscoveryKeepSwitchHidden() {
        var availability = PrivacyProxySettings.Availability.checking
        let settings = PrivacyProxySettings(
            policy: .manual,
            availability: { availability },
            hasActivePremium: { false },
            readPreference: { false },
            writePreference: { _ in XCTFail("The switch is unavailable") }
        )

        settings.refresh()
        XCTAssertEqual(settings.state.availability, .checking)
        XCTAssertFalse(settings.state.showsSwitch)

        availability = .notAdvertised
        settings.refresh()
        XCTAssertEqual(settings.state.availability, .notAdvertised)
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(true))
    }

    func testReachableProxyPersistsBothManualSwitchChoices() {
        var preference = false
        var changes: [Bool] = []
        let settings = PrivacyProxySettings(
            policy: .manual,
            availability: { .reachable(host: "proxy.example.net") },
            hasActivePremium: { false },
            readPreference: { preference },
            writePreference: { preference = $0; changes.append($0) }
        )

        settings.refresh()
        XCTAssertEqual(settings.state.availability, .reachable(host: "proxy.example.net"))
        XCTAssertTrue(settings.state.showsSwitch)
        XCTAssertTrue(settings.state.canChangeSwitch)
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertTrue(settings.setEnabled(true))
        XCTAssertTrue(settings.state.isEnabled)
        XCTAssertTrue(settings.setEnabled(false))
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertEqual(changes, [true, false])
    }

    func testUnreachableProxyCannotChangeStoredPreference() {
        let settings = PrivacyProxySettings(
            policy: .manual,
            availability: { .unreachable(host: "proxy.example.net") },
            hasActivePremium: { false },
            readPreference: { true },
            writePreference: { _ in XCTFail("The switch is unavailable") }
        )

        settings.refresh()
        XCTAssertEqual(settings.state.availability, .unreachable(host: "proxy.example.net"))
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(false))
    }

    func testPaidSwitchTracksEntitlementWithCachedAvailability() {
        var hasPremium = false
        var preference = false
        let settings = PrivacyProxySettings(
            policy: .payed,
            availability: { .reachable(host: "proxy.example.net") },
            hasActivePremium: { hasPremium },
            readPreference: { preference },
            writePreference: { preference = $0 }
        )

        settings.refresh()
        XCTAssertEqual(settings.state.availability, .reachable(host: "proxy.example.net"))
        XCTAssertTrue(settings.state.showsSwitch)
        XCTAssertTrue(settings.state.requiresPremium)
        XCTAssertFalse(settings.state.canChangeSwitch)
        XCTAssertFalse(settings.setEnabled(true))

        hasPremium = true
        settings.refresh()
        XCTAssertTrue(settings.state.canChangeSwitch)
        XCTAssertTrue(settings.setEnabled(true))

        hasPremium = false
        settings.refresh()
        XCTAssertTrue(settings.state.requiresPremium)
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertTrue(preference)
    }

    func testAlwaysReportsReachableProxyWithoutEditableSwitch() {
        let settings = PrivacyProxySettings(
            policy: .always,
            availability: { .reachable(host: "proxy.example.net") },
            hasActivePremium: { false },
            readPreference: { false },
            writePreference: { _ in XCTFail("The policy fixes proxy usage") }
        )

        settings.refresh()
        XCTAssertEqual(settings.state.availability, .reachable(host: "proxy.example.net"))
        XCTAssertTrue(settings.state.isEnabled)
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(false))
    }

    func testNeverDoesNotShowSwitchWithReachableProxy() {
        let settings = PrivacyProxySettings(
            policy: .never,
            availability: { .reachable(host: "proxy.example.net") },
            hasActivePremium: { true },
            readPreference: { true },
            writePreference: { _ in XCTFail("The policy fixes proxy usage") }
        )

        settings.refresh()
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(true))
    }
}
