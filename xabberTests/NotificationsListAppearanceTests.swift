//
//  NotificationsListAppearanceTests.swift
//  xabberTests
//
//  Created by Codex on 26.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class NotificationsListAppearanceTests: XCTestCase {
    private var previousInterfaceType: String!
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "NotificationsListAppearanceTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousInterfaceType = nil
        previousRealmConfiguration = nil
        super.tearDown()
    }

    private func addEnabledAccount(owner: String, colorKey: String = "blue", order: Int = 0) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let account = AccountStorageItem()
            account.jid = owner
            account.username = owner
            account.enabled = true
            account.colorKey = colorKey
            account.order = order
            realm.add(account, update: .modified)
        }
    }

    private func registerAccountColor(owner: String, colorKey: String) {
        AccountColorManager.shared.accounts.insert(
            AccountColorManager.ColorForJid(
                jid: owner,
                color: AccountColorManager.shared.colorForKey(colorKey)
            )
        )
    }

    private func assertNoSelectionOutline(
        in cell: UITableViewCell,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(cell.backgroundConfiguration?.visualEffect, file: file, line: line)
        XCTAssertTrue(
            cell.backgroundConfiguration?.strokeColor == nil
                || cell.backgroundConfiguration?.strokeColor == .clear,
            file: file,
            line: line
        )
        XCTAssertEqual(cell.backgroundConfiguration?.strokeWidth ?? 0, 0, file: file, line: line)
        XCTAssertEqual(cell.backgroundConfiguration?.strokeOutset ?? 0, 0, file: file, line: line)
        XCTAssertNil(cell.backgroundView, file: file, line: line)
        XCTAssertNil(cell.selectedBackgroundView, file: file, line: line)
        XCTAssertNil(cell.multipleSelectionBackgroundView, file: file, line: line)
        XCTAssertEqual(cell.focusStyle, .custom, file: file, line: line)
        XCTAssertEqual(cell.layer.borderWidth, 0, file: file, line: line)
        XCTAssertEqual(cell.layer.shadowOpacity, 0, file: file, line: line)
        XCTAssertEqual(cell.contentView.layer.borderWidth, 0, file: file, line: line)
        XCTAssertEqual(cell.contentView.layer.shadowOpacity, 0, file: file, line: line)
    }

    private final class FilterSpy: NotificationsControllerFilterProtocol {
        var accountFilters: [String?] = []
        var categoryFilters: [String?] = []

        func shouldFilterBy(account: String?) {
            accountFilters.append(account)
        }

        func shouldFilterBy(category: String?) {
            categoryFilters.append(category)
        }
    }

    private func assertInformationalHeaderDoesNotAcceptSelectionFeedback(
        _ cell: UITableViewCell,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(cell.selectionStyle, .none, file: file, line: line)
        XCTAssertNil(cell.backgroundView, file: file, line: line)
        XCTAssertNil(cell.selectedBackgroundView, file: file, line: line)
        XCTAssertNil(cell.multipleSelectionBackgroundView, file: file, line: line)
        XCTAssertEqual(cell.focusStyle, .custom, file: file, line: line)
        XCTAssertEqual(cell.layer.borderWidth, 0, file: file, line: line)
        XCTAssertEqual(cell.layer.shadowOpacity, 0, file: file, line: line)
        XCTAssertEqual(cell.contentView.layer.borderWidth, 0, file: file, line: line)
        XCTAssertEqual(cell.contentView.layer.shadowOpacity, 0, file: file, line: line)
        XCTAssertNil(cell.configurationUpdateHandler, file: file, line: line)

        cell.setHighlighted(true, animated: false)
        XCTAssertFalse(cell.isHighlighted, file: file, line: line)
        cell.setSelected(true, animated: false)
        XCTAssertFalse(cell.isSelected, file: file, line: line)
    }

    private func makeNotificationChild(
        owner: String,
        category: XMPPNotificationsManager.Category = .info,
        isHeader: Bool = false
    ) -> NotificationsListViewController.DatasourceChild {
        NotificationsListViewController.DatasourceChild(
            primary: "\(owner)-\(category.rawValue)-\(isHeader)",
            category: category,
            owner: owner,
            jid: "sender@example.com",
            title: NSAttributedString(string: isHeader ? "Information" : "Information from sender@example.com"),
            message: NSAttributedString(string: isHeader ? "Updates and system messages." : "Notification body"),
            key: "notification-key",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            avatarUrl: nil,
            badgeIcon: isHeader ? "info.square.fill" : NotificationsSupport.badgeIcon(for: category),
            isRead: false,
            isHeader: isHeader
        )
    }

    func testNotificationsListUsesInsetGroupedTransparentSplitAppearance() {
        let controller = NotificationsListViewController()

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
        XCTAssertEqual(controller.emptyView.backgroundColor, .clear)
        XCTAssertFalse(controller.emptyView.isOpaque)
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:heightForHeaderInSection:))))
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:heightForFooterInSection:))))
    }

    func testNotificationsCategoriesUseInsetGroupedTransparentSplitAppearanceAndNativeSpacing() {
        let controller = NotificationsCategoriesViewController()

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:heightForHeaderInSection:))))
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:heightForFooterInSection:))))
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:viewForHeaderInSection:))))
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:viewForFooterInSection:))))
    }

    func testNotificationRowsUsePlainSystemBackgroundWithoutGlass() {
        let owner = "notifications-row-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "blue")
        addEnabledAccount(owner: owner, colorKey: "blue")
        let controller = NotificationsListViewController()
        controller.loadViewIfNeeded()
        controller.datasource = [
            NotificationsListViewController.Datasource(
                title: "Today",
                key: "notifications",
                childs: [makeNotificationChild(owner: owner)]
            )
        ]

        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )

        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, .clear)
        XCTAssertNil(cell.backgroundConfiguration?.visualEffect)
        XCTAssertNil(cell.selectedBackgroundView)
        XCTAssertEqual(cell.selectionStyle, .none)
        assertNoSelectionOutline(in: cell)
    }

    func testSubscriptionRowsUsePlainSystemBackgroundWithoutGlass() {
        let owner = "notifications-subscription-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "green")
        addEnabledAccount(owner: owner, colorKey: "green")
        let controller = NotificationsListViewController()
        controller.loadViewIfNeeded()
        controller.datasource = [
            NotificationsListViewController.Datasource(
                title: "Requests",
                key: "subscribtion_requests",
                childs: [makeNotificationChild(owner: owner, category: .contact)]
            )
        ]

        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )

        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, .clear)
        XCTAssertNil(cell.backgroundConfiguration?.visualEffect)
        XCTAssertNil(cell.selectedBackgroundView)
        XCTAssertEqual(cell.selectionStyle, .none)
        assertNoSelectionOutline(in: cell)
    }

    func testNotificationsCategoryRowsUseFilledSelectionWithoutOutlineAcrossReload() {
        let owner = "notifications-selected-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "orange")
        addEnabledAccount(owner: owner, colorKey: "orange")
        let controller = NotificationsCategoriesViewController()
        controller.loadViewIfNeeded()

        controller.selectFilter(.mentions, animated: false, notify: false)
        controller.tableView.reloadData()

        let selectedCell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 2, section: 2)
        )

        XCTAssertTrue(
            selectedCell.backgroundColor?.isEqual(AccountColorManager.shared.palette(for: owner).tint50) == true
        )
        XCTAssertNil(selectedCell.backgroundConfiguration?.visualEffect)
        XCTAssertNil(selectedCell.selectedBackgroundView)
        XCTAssertEqual(selectedCell.selectionStyle, .none)
        assertNoSelectionOutline(in: selectedCell)

        let unselectedCell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertEqual(unselectedCell.backgroundColor, .systemBackground)
        XCTAssertNil(unselectedCell.backgroundConfiguration?.visualEffect)
        assertNoSelectionOutline(in: unselectedCell)
    }

    func testNotificationsCategoryIntroHeaderIsInformationalOnly() {
        let controller = NotificationsCategoriesViewController()
        controller.loadViewIfNeeded()
        let spy = FilterSpy()
        controller.filterDelegate = spy
        let headerIndexPath = IndexPath(row: 0, section: 0)
        let categoryIndexPath = IndexPath(row: 0, section: 1)
        let selectedRowsBeforeHeaderTap = controller.tableView.indexPathsForSelectedRows ?? []

        XCTAssertEqual(controller.datasource[headerIndexPath.section][headerIndexPath.row].isSelectable, false)
        XCTAssertTrue(controller.datasource[categoryIndexPath.section][categoryIndexPath.row].isSelectable)
        XCTAssertFalse(controller.tableView(controller.tableView, shouldHighlightRowAt: headerIndexPath))
        XCTAssertNil(controller.tableView(controller.tableView, willSelectRowAt: headerIndexPath))
        XCTAssertFalse(controller.tableView(controller.tableView, canFocusRowAt: headerIndexPath))
        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: headerIndexPath),
            UITableView.automaticDimension
        )

        let headerCell = controller.tableView(controller.tableView, cellForRowAt: headerIndexPath)
        assertInformationalHeaderDoesNotAcceptSelectionFeedback(headerCell)

        controller.tableView(controller.tableView, didSelectRowAt: headerIndexPath)
        XCTAssertTrue(spy.categoryFilters.isEmpty)
        XCTAssertEqual(controller.tableView.indexPathsForSelectedRows ?? [], selectedRowsBeforeHeaderTap)

        XCTAssertTrue(controller.tableView(controller.tableView, shouldHighlightRowAt: categoryIndexPath))
        XCTAssertEqual(controller.tableView(controller.tableView, willSelectRowAt: categoryIndexPath), categoryIndexPath)
        controller.tableView(controller.tableView, didSelectRowAt: categoryIndexPath)
        XCTAssertEqual(spy.categoryFilters, [NotificationsListViewController.Filter.all.rawValue])
    }

    func testNotificationsCategoryHeaderUsesAutomaticHeight() {
        let controller = NotificationsCategoriesViewController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: IndexPath(row: 0, section: 0)),
            UITableView.automaticDimension
        )
    }

    func testNotificationsCompactSplitNavbarButtonsAreVisibleAfterLoad() throws {
        let controller = NotificationsListViewController()

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "notifications_back_to_chats_button")
        let rightItems = try XCTUnwrap(controller.navigationItem.rightBarButtonItems)
        XCTAssertEqual(rightItems.compactMap(\.accessibilityIdentifier), [
            "notifications_filter_menu_button",
            "notifications_mark_all_read_button"
        ])
    }

    func testNotificationsCategoriesRegularNavbarShowsSidebarButtonImmediately() {
        let controller = NotificationsCategoriesViewController()

        controller.loadViewIfNeeded()
        controller.configureLeadingNavigationItem(forRegularWidth: true, animated: false)

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "notifications_sidebar_menu_button")
    }
}
