import UIKit
import XCTest
@testable import xabber

final class SecuritySettingsViewControllerTests: XCTestCase {
    @MainActor
    func testSecurityAppearsImmediatelyAfterPrivacyForProxyPolicies() throws {
        for policy in [CommonConfigManager.PrivacyProxyPolicy.always, .manual, .payed] {
            let rows = SettingsViewController.makeSettingsRows(proxyPolicy: policy)
            let privacyIndex = try XCTUnwrap(rows.firstIndex { $0.section == .privacy })

            XCTAssertEqual(rows[privacyIndex + 1].section, .security)
            XCTAssertEqual(rows[privacyIndex + 1].key, .securitySettings)
        }
        XCTAssertFalse(SettingsViewController.makeSettingsRows(proxyPolicy: .never)
            .contains { $0.key == .securitySettings })
    }

    @MainActor
    func testMissingProxyShowsStatusWithoutSwitch() {
        let settings = makeSettings(availability: .notAdvertised)
        let controller = SecuritySettingsViewController(owners: ["alice@example.com"]) { _ in settings }
        controller.loadViewIfNeeded()
        settings.refresh()

        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(cell.accessibilityIdentifier, "settings.security.proxy.status")
        XCTAssertNil(cell.accessoryView)
    }

    @MainActor
    func testRouteCardsRemainReadableAtCompactAndWideWidths() throws {
        let controller = SecuritySettingsViewController(owners: []) { _ in
            XCTFail("The illustration does not require an account")
            return makeSettings(availability: .notAdvertised)
        }
        controller.loadViewIfNeeded()
        let indexPath = IndexPath(row: 1, section: controller.numberOfSections(in: controller.tableView) - 1)
        let cell = controller.tableView(controller.tableView, cellForRowAt: indexPath)
        let direct = try XCTUnwrap(descendant(in: cell, identifiedBy: "settings.security.proxy.route.direct"))
        let proxied = try XCTUnwrap(descendant(in: cell, identifiedBy: "settings.security.proxy.route.proxied"))
        XCTAssertTrue(direct.isAccessibilityElement)
        XCTAssertTrue(proxied.isAccessibilityElement)
        XCTAssertFalse(direct.accessibilityValue?.isEmpty ?? true)
        XCTAssertFalse(proxied.accessibilityValue?.isEmpty ?? true)

        layout(cell, atWidth: 300)
        XCTAssertGreaterThan(direct.bounds.width, 0)
        XCTAssertGreaterThanOrEqual(proxied.convert(proxied.bounds, to: cell).minY,
                                    direct.convert(direct.bounds, to: cell).maxY)

        layout(cell, atWidth: 600)
        let directFrame = direct.convert(direct.bounds, to: cell)
        let proxiedFrame = proxied.convert(proxied.bounds, to: cell)
        XCTAssertEqual(directFrame.minY, proxiedFrame.minY, accuracy: 1)
        XCTAssertFalse(directFrame.intersects(proxiedFrame))
    }

    @MainActor
    private func layout(_ cell: UITableViewCell, atWidth width: CGFloat) {
        let size = cell.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    @MainActor
    private func descendant(in view: UIView, identifiedBy identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let match = descendant(in: child, identifiedBy: identifier) { return match }
        }
        return nil
    }

    @MainActor
    func testReachableProxyShowsOneSwitchAndSavesTheLocalChoice() throws {
        var preference = false
        let settings = makeSettings(
            availability: .reachable(host: "proxy.example.com"),
            readPreference: { preference },
            writePreference: { preference = $0 }
        )
        let controller = SecuritySettingsViewController(owners: ["alice@example.com"]) { _ in settings }
        controller.loadViewIfNeeded()
        settings.refresh()

        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 1)
        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let toggle = try XCTUnwrap(cell.accessoryView as? UISwitch)
        XCTAssertEqual(toggle.accessibilityIdentifier, "settings.security.proxy.enabled")
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertFalse(toggle.isOn)

        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)

        XCTAssertTrue(preference)
    }

    @MainActor
    private func makeSettings(
        availability: PrivacyProxySettings.Availability,
        readPreference: @escaping () -> Bool = { false },
        writePreference: @escaping (Bool) -> Void = { _ in }
    ) -> PrivacyProxySettings {
        PrivacyProxySettings(
            policy: .manual,
            availability: { availability },
            hasActivePremium: { false },
            readPreference: readPreference,
            writePreference: writePreference
        )
    }
}
