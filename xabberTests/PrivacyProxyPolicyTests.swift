import XCTest
@testable import xabber

final class PrivacyProxyPolicyTests: XCTestCase {
    func testCommonConfigDecodesAllFourPlistValues() throws {
        let expected: [(String, CommonConfigManager.PrivacyProxyPolicy)] = [
            ("always", .always), ("manual", .manual), ("payed", .payed), ("never", .never)
        ]

        for (value, policy) in expected {
            XCTAssertEqual(try decodeConfig(policyValue: value).privacyProxyPolicy, policy)
        }
    }

    func testLegacyAndUnrecognizedConfigDefaultToNever() throws {
        XCTAssertEqual(try decodeConfig(policyValue: nil).privacyProxyPolicy, .never)
        XCTAssertEqual(try decodeConfig(policyValue: "unknown").privacyProxyPolicy, .never)
    }

    func testAlwaysRequiresProxyEvenWithLocalPreferenceOff() {
        let policy = CommonConfigManager.PrivacyProxyPolicy.always

        XCTAssertTrue(policy.requiresProxyForExternalMedia)
        XCTAssertFalse(policy.showsProxyControls)
        XCTAssertFalse(policy.canEnableProxyInSettings(hasActivePremium: true))
        XCTAssertTrue(policy.usesProxy(localProxyEnabled: false, hasActivePremium: false))
    }

    func testManualFollowsLocalPreferenceWithoutPremium() {
        let policy = CommonConfigManager.PrivacyProxyPolicy.manual

        XCTAssertFalse(policy.requiresProxyForExternalMedia)
        XCTAssertTrue(policy.showsProxyControls)
        XCTAssertTrue(policy.canEnableProxyInSettings(hasActivePremium: false))
        XCTAssertTrue(policy.usesProxy(localProxyEnabled: true, hasActivePremium: false))
        XCTAssertFalse(policy.usesProxy(localProxyEnabled: false, hasActivePremium: true))
    }

    func testPayedShowsControlsAndRequiresActivePremiumToUseProxy() {
        let policy = CommonConfigManager.PrivacyProxyPolicy.payed

        XCTAssertFalse(policy.requiresProxyForExternalMedia)
        XCTAssertTrue(policy.showsProxyControls)
        XCTAssertTrue(policy.canEnableProxyInSettings(hasActivePremium: true))
        XCTAssertFalse(policy.canEnableProxyInSettings(hasActivePremium: false))
        XCTAssertTrue(policy.usesProxy(localProxyEnabled: true, hasActivePremium: true))
        XCTAssertFalse(policy.usesProxy(localProxyEnabled: true, hasActivePremium: false))
        XCTAssertFalse(policy.usesProxy(localProxyEnabled: false, hasActivePremium: true))
    }

    func testNeverDisablesProxyDespiteLocalPreferenceAndPremium() {
        let policy = CommonConfigManager.PrivacyProxyPolicy.never

        XCTAssertFalse(policy.requiresProxyForExternalMedia)
        XCTAssertFalse(policy.showsProxyControls)
        XCTAssertFalse(policy.canEnableProxyInSettings(hasActivePremium: true))
        XCTAssertFalse(policy.usesProxy(localProxyEnabled: true, hasActivePremium: true))
    }

    private func decodeConfig(policyValue: String?) throws -> CommonConfigManager.CommonConfig {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "common_config", withExtension: "plist"))
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        var values = try XCTUnwrap(plist as? [String: Any])
        values["privacy_proxy_policy"] = policyValue
        let configData = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        return try PropertyListDecoder().decode(CommonConfigManager.CommonConfig.self, from: configData)
    }
}
