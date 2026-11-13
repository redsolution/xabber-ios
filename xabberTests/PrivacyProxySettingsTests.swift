import XCTest
@testable import xabber

@MainActor
final class PrivacyProxySettingsTests: XCTestCase {
    private let endpoint = URL(string: "https://proxy.example.net/")!

    func testUnknownAndMissingDiscoveryKeepSwitchHiddenWithoutProbe() {
        var discovery = ServerDiscoManager.PrivacyProxyDiscovery.unknown
        let settings = PrivacyProxySettings(
            policy: .manual,
            discovery: { discovery },
            hasActivePremium: { false },
            readPreference: { false },
            writePreference: { _ in XCTFail("The switch is unavailable") },
            probe: { _ in XCTFail("There is no endpoint to probe"); return false }
        )

        settings.refresh()
        XCTAssertEqual(settings.state.availability, .checking)
        XCTAssertFalse(settings.state.showsSwitch)

        discovery = .notAdvertised
        settings.refresh()
        XCTAssertEqual(settings.state.availability, .notAdvertised)
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(true))
    }

    func testReachableProxyPersistsBothManualSwitchChoices() async {
        var preference = false
        var changes: [Bool] = []
        let settings = PrivacyProxySettings(
            policy: .manual,
            discovery: { .advertised(self.endpoint) },
            hasActivePremium: { false },
            readPreference: { preference },
            writePreference: { preference = $0; changes.append($0) },
            probe: { $0 == self.endpoint }
        )

        await refresh(settings, expecting: .reachable(host: "proxy.example.net"))
        XCTAssertTrue(settings.state.showsSwitch)
        XCTAssertTrue(settings.state.canChangeSwitch)
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertTrue(settings.setEnabled(true))
        XCTAssertTrue(settings.state.isEnabled)
        XCTAssertTrue(settings.setEnabled(false))
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertEqual(changes, [true, false])
    }

    func testUnreachableProxyCannotChangeStoredPreference() async {
        let settings = PrivacyProxySettings(
            policy: .manual,
            discovery: { .advertised(self.endpoint) },
            hasActivePremium: { false },
            readPreference: { true },
            writePreference: { _ in XCTFail("The switch is unavailable") },
            probe: { _ in false }
        )

        await refresh(settings, expecting: .unreachable(host: "proxy.example.net"))
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(false))
    }

    func testPaidSwitchTracksEntitlementWithoutRepeatingSuccessfulProbe() async {
        var hasPremium = false
        var preference = false
        var probes = 0
        let settings = PrivacyProxySettings(
            policy: .payed,
            discovery: { .advertised(self.endpoint) },
            hasActivePremium: { hasPremium },
            readPreference: { preference },
            writePreference: { preference = $0 },
            probe: { _ in probes += 1; return true }
        )

        await refresh(settings, expecting: .reachable(host: "proxy.example.net"))
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
        XCTAssertEqual(probes, 1)
    }

    func testLateResultFromReplacedEndpointCannotEnableSwitch() async {
        var discovery = ServerDiscoManager.PrivacyProxyDiscovery.advertised(endpoint)
        let firstStarted = expectation(description: "Original endpoint probe")
        var finishFirst: CheckedContinuation<Bool, Never>?
        let settings = PrivacyProxySettings(
            policy: .manual,
            discovery: { discovery },
            hasActivePremium: { false },
            readPreference: { false },
            writePreference: { _ in XCTFail("A stale probe must not permit changes") },
            probe: { url in
                guard url == self.endpoint else { return false }
                return await withCheckedContinuation {
                    finishFirst = $0
                    firstStarted.fulfill()
                }
            }
        )

        settings.refresh()
        await fulfillment(of: [firstStarted], timeout: 2)
        discovery = .advertised(URL(string: "https://replacement.example.net/")!)
        await refresh(settings, expecting: .unreachable(host: "replacement.example.net"))
        finishFirst?.resume(returning: true)
        await Task.yield()

        XCTAssertEqual(settings.state.availability, .unreachable(host: "replacement.example.net"))
        XCTAssertFalse(settings.setEnabled(true))
    }

    func testAlwaysReportsReachableProxyWithoutEditableSwitch() async {
        let settings = PrivacyProxySettings(
            policy: .always,
            discovery: { .advertised(self.endpoint) },
            hasActivePremium: { false },
            readPreference: { false },
            writePreference: { _ in XCTFail("The policy fixes proxy usage") },
            probe: { _ in true }
        )

        await refresh(settings, expecting: .reachable(host: "proxy.example.net"))
        XCTAssertTrue(settings.state.isEnabled)
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(false))
    }

    func testNeverDoesNotProbeAdvertisedProxyOrShowSwitch() {
        let settings = PrivacyProxySettings(
            policy: .never,
            discovery: { .advertised(self.endpoint) },
            hasActivePremium: { true },
            readPreference: { true },
            writePreference: { _ in XCTFail("The policy fixes proxy usage") },
            probe: { _ in XCTFail("The settings are hidden"); return true }
        )

        settings.refresh()
        XCTAssertFalse(settings.state.isEnabled)
        XCTAssertFalse(settings.state.showsSwitch)
        XCTAssertFalse(settings.setEnabled(true))
    }

    private func refresh(
        _ settings: PrivacyProxySettings,
        expecting availability: PrivacyProxySettings.Availability
    ) async {
        let probed = expectation(description: "Proxy reachability determined")
        settings.onChange = { state in
            if state.availability == availability { probed.fulfill() }
        }
        settings.refresh()
        await fulfillment(of: [probed], timeout: 2)
        settings.onChange = nil
        XCTAssertEqual(settings.state.availability, availability)
    }
}
