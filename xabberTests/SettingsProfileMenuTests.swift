import UIKit
import XCTest

@testable import xabber

final class SettingsProfileMenuTests: XCTestCase {

    func testMenuFactorySeparatesBlockListAndPreservesAccountColorPolicy() {
        let unlockedSections = SettingsAccountProfileMenuFactory.makeSections(
            accountColorLocked: false
        )

        XCTAssertEqual(
            unlockedSections.map(\.section),
            [.profile, .blockList, .circles, .delete]
        )
        XCTAssertEqual(
            unlockedSections[0].childs.compactMap(\.key),
            [.accountStatus, .accountVcard, .accountPassword, .accountColor]
        )
        XCTAssertEqual(
            unlockedSections[1].childs.compactMap(\.key),
            [.accountBlockedContacts]
        )
        XCTAssertEqual(
            unlockedSections[2].childs.compactMap(\.key),
            [.accountCircles]
        )

        let lockedSections = SettingsAccountProfileMenuFactory.makeSections(
            accountColorLocked: true
        )
        XCTAssertEqual(
            lockedSections[0].childs.compactMap(\.key),
            [.accountStatus, .accountVcard, .accountPassword]
        )
    }

    func testMenuRowsUseFilledSquareIconsWithoutSecondaryText() throws {
        let sections = SettingsAccountProfileMenuFactory.makeSections(
            accountColorLocked: false
        )
        let rows = sections
            .flatMap(\.childs)
            .filter { $0.key != .accountDelete }
        let status = try XCTUnwrap(rows.first(where: { $0.key == .accountStatus }))
        let iconRows = rows.filter { $0.key != .accountStatus }

        XCTAssertEqual(rows.count, 6)
        XCTAssertNil(status.icon)
        XCTAssertTrue(rows.allSatisfy { $0.subtitle == nil })
        for row in iconRows {
            let icon = try XCTUnwrap(row.icon)
            XCTAssertTrue(icon.hasSuffix(".square.fill"), "Unexpected icon: \(icon)")
            XCTAssertNotNil(imageLiteral(icon, dimension: 24))
        }
    }

    func testStatusUsesPreviousStatusInfoCellWithTextDescription() throws {
        let controller = makeController()
        let statusIndexPath = IndexPath(row: 0, section: 0)

        let cell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: statusIndexPath
            ) as? StatusInfoCell
        )

        XCTAssertEqual(cell.titleLabel.text, "Status")
        XCTAssertEqual(cell.subtitleLabel.text, "Offline")
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: statusIndexPath),
            defaultRowHeight
        )
    }

    func testProfileMenuRowsRenderAsSingleLineIconCells() throws {
        let controller = makeController()
        let profileIndexPath = IndexPath(row: 1, section: 0)

        let cell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: profileIndexPath
            ) as? SimpleTableViewController.ProfileMenuCell
        )

        XCTAssertEqual(cell.textLabel?.text, "Profile")
        XCTAssertNil(cell.detailTextLabel)
        XCTAssertNotNil(cell.imageView?.image)
        XCTAssertEqual(cell.accessibilityIdentifier, "settings_profile_account_vcard")
        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: profileIndexPath),
            defaultRowHeight
        )
    }

    func testCirclesRowPushesDedicatedConfiguredPlaceholderController() throws {
        let controller = makeController(jid: "alice@example.com")
        let navigationController = UINavigationController(rootViewController: controller)
        let circlesSection = try XCTUnwrap(
            controller.datasource?.childs.firstIndex(where: { $0.section == .circles })
        )

        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 0, section: circlesSection)
        )

        let circlesController = try XCTUnwrap(
            navigationController.topViewController as? AccountCirclesViewController
        )
        circlesController.loadViewIfNeeded()
        XCTAssertEqual(circlesController.jid, "alice@example.com")
        XCTAssertEqual(circlesController.title, "Circles")
        XCTAssertFalse(circlesController.placeholderLabel.text?.isEmpty ?? true)
        XCTAssertEqual(
            circlesController.placeholderLabel.accessibilityIdentifier,
            "settings_circles_placeholder"
        )
    }

    func testLegacyRowsWithoutIconMetadataKeepTheirOriginalCells() {
        let controller = SimpleTableViewController()
        controller.jid = "alice@example.com"
        controller.datasource = SettingsViewController.Datasource(
            section: .profile,
            childs: [
                SettingsViewController.Datasource(
                    section: .status,
                    childs: [
                        SettingsViewController.Datasource(
                            section: .status,
                            title: "Status",
                            key: .accountStatus
                        )
                    ]
                ),
                SettingsViewController.Datasource(
                    section: .profile,
                    childs: [
                        SettingsViewController.Datasource(
                            section: .profile,
                            title: "Account color",
                            key: .accountColor
                        )
                    ]
                )
            ]
        )
        controller.loadViewIfNeeded()

        XCTAssertTrue(
            controller.tableView(
                controller.tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) is StatusInfoCell
        )
        let accountColorCell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertFalse(accountColorCell is SimpleTableViewController.ProfileMenuCell)
        XCTAssertEqual(accountColorCell.textLabel?.text, "Account color")
        XCTAssertFalse(accountColorCell.detailTextLabel?.text?.isEmpty ?? true)
    }

    private func makeController(jid: String = "alice@example.com") -> SimpleTableViewController {
        let controller = SimpleTableViewController()
        controller.jid = jid
        controller.datasource = SettingsViewController.Datasource(
            section: .profile,
            title: "Profile, status, password",
            childs: SettingsAccountProfileMenuFactory.makeSections(
                accountColorLocked: false
            )
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private var defaultRowHeight: CGFloat {
        if #available(iOS 26, *) {
            return 52
        }
        return 44
    }
}
