import UIKit
import XCTest

@testable import xabber

final class SettingsProfileMenuTests: XCTestCase {

    func testAccountColorRowsExposeTheirPaletteAsLeadingCircularIndicators() throws {
        let controller = AccountColorViewController()
        controller.update()

        XCTAssertEqual(controller.datasource.count, AccountColorManager.colors.count)

        for (row, colorItem) in zip(controller.datasource, AccountColorManager.colors) {
            XCTAssertTrue(row.color.isEqual(colorItem.primary))
        }

        let firstCell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? AccountColorViewController.InfoCell
        )
        layout(cell: firstCell)

        XCTAssertTrue(
            firstCell.colorIndicatorView.backgroundColor?.isEqual(
                AccountColorManager.colors[0].primary
            ) == true
        )
        XCTAssertEqual(firstCell.colorIndicatorView.bounds.width, 24, accuracy: 0.5)
        XCTAssertEqual(firstCell.colorIndicatorView.bounds.height, 24, accuracy: 0.5)
        XCTAssertEqual(firstCell.colorIndicatorView.layer.cornerRadius, 12, accuracy: 0.5)
        XCTAssertEqual(firstCell.stack.arrangedSubviews.first, firstCell.colorIndicatorView)
        XCTAssertEqual(firstCell.stack.arrangedSubviews.dropFirst().first, firstCell.titleLabel)
        XCTAssertEqual(
            firstCell.titleLabel.bounds.width,
            firstCell.titleLabel.intrinsicContentSize.width,
            accuracy: 0.5
        )
        XCTAssertEqual(
            firstCell.titleLabel.frame.minX - firstCell.colorIndicatorView.frame.maxX,
            12,
            accuracy: 0.5
        )
    }

    func testAccountColorCellReuseUpdatesSwatchAndSelectionWithoutDuplicatingContent() {
        let cell = AccountColorViewController.InfoCell(style: .default, reuseIdentifier: nil)

        cell.configure(for: "Red", color: .systemRed, active: true)
        cell.configure(for: "Blue", color: .systemBlue, active: false)

        XCTAssertEqual(cell.titleLabel.text, "Blue")
        XCTAssertTrue(cell.colorIndicatorView.backgroundColor?.isEqual(UIColor.systemBlue) == true)
        XCTAssertEqual(cell.accessoryType, .none)
        XCTAssertEqual(cell.stack.arrangedSubviews.count, 3)
    }

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

        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(SettingsMenuIconMetrics.dimension, 24)
        XCTAssertTrue(rows.allSatisfy { $0.subtitle == nil })
        XCTAssertEqual(
            rows.first(where: { $0.key == .accountStatus })?.icon,
            "bolt.square.fill"
        )
        for row in rows {
            let icon = try XCTUnwrap(row.icon)
            XCTAssertTrue(icon.hasSuffix(".square.fill"), "Unexpected icon: \(icon)")
            XCTAssertNotNil(
                imageLiteral(icon, dimension: SettingsMenuIconMetrics.dimension)
            )
        }
    }

    func testStatusUsesPreviousCellWithLeadingSettingsSizedIconAndDescription() throws {
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
        XCTAssertTrue(cell.stack.arrangedSubviews.first === cell.leadingIconSpacer)
        XCTAssertFalse(cell.leadingIconSpacer.isHidden)
        XCTAssertEqual(
            cell.leadingIconView.image?.size,
            imageLiteral(
                "bolt.square.fill",
                dimension: SettingsMenuIconMetrics.dimension
            )?.size
        )
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
        XCTAssertEqual(
            cell.imageView?.image?.size,
            imageLiteral(
                "custom.person.square.fill",
                dimension: SettingsMenuIconMetrics.dimension
            )?.size
        )
        XCTAssertEqual(cell.accessibilityIdentifier, "settings_profile_account_vcard")
        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: profileIndexPath),
            defaultRowHeight
        )
    }

    func testStatusLeadingIconAlignsWithProfileMenuImageColumn() throws {
        let controller = makeController()
        let statusCell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? StatusInfoCell
        )
        let profileCell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: IndexPath(row: 1, section: 0)
            ) as? SimpleTableViewController.ProfileMenuCell
        )

        layout(cell: statusCell)
        layout(cell: profileCell)

        let statusIconMinX = statusCell.leadingIconView.convert(
            statusCell.leadingIconView.bounds,
            to: statusCell.contentView
        ).minX
        let profileImageView = try XCTUnwrap(profileCell.imageView)
        let profileIconMinX = profileImageView.convert(
            profileImageView.bounds,
            to: profileCell.contentView
        ).minX

        XCTAssertEqual(
            statusIconMinX,
            profileIconMinX,
            accuracy: 0.5,
            "Status content margins: \(statusCell.contentView.layoutMargins); "
                + "Profile content margins: \(profileCell.contentView.layoutMargins); "
                + "Profile cell margins: \(profileCell.layoutMargins)"
        )
    }

    func testCirclesRowPushesConfiguredCRUDController() throws {
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
        XCTAssertEqual(circlesController.tableView.style, .insetGrouped)
        XCTAssertEqual(circlesController.tableView.accessibilityIdentifier, "settings_circles_list")
        XCTAssertEqual(circlesController.emptyStateLabel.accessibilityIdentifier, "settings_circles_empty")
        XCTAssertEqual(circlesController.navigationItem.rightBarButtonItem?.accessibilityIdentifier, "settings_circles_add")
    }

    func testCloudStorageRowShowsQuotaAndPremiumBadgeIcon() throws {
        let controller = SettingsViewController()
        controller.datasource = [
            SettingsViewController.Datasource(
                section: .accountSettings,
                childs: [
                    SettingsViewController.Datasource(
                        section: .accountSettings,
                        title: "Cloud storage",
                        icon: SettingsCloudStorageQuotaDisplayState.basicIconName,
                        color: .systemBlue,
                        key: .manageStorage
                    )
                ]
            )
        ]
        controller.cloudStorageQuotaDisplayState = .resolve(
            hasCachedQuota: true,
            quotaBytes: 300_000_000,
            isRefreshing: false,
            lastRefreshFailed: false,
            isAvailable: true,
            galleryType: .premium
        )

        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let expectedIcon = try XCTUnwrap(
            imageLiteral(
                SettingsCloudStorageQuotaDisplayState.premiumIconName,
                dimension: SettingsMenuIconMetrics.dimension
            )
        )

        XCTAssertEqual(cell.detailTextLabel?.text, "300 MB")
        XCTAssertTrue(cell.imageView?.image?.isEqual(expectedIcon) == true)
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

    private func layout(cell: UITableViewCell) {
        cell.frame = CGRect(x: 0, y: 0, width: 350, height: defaultRowHeight)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.contentView.layoutIfNeeded()
    }
}
