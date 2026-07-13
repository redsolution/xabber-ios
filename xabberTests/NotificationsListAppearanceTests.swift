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
    private var previousUseLargeTitle: Bool!
    private var previousRealmConfiguration: Realm.Configuration!
    private var retainedTraitWindows: [UIWindow] = []

    override func setUp() {
        super.setUp()
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        previousUseLargeTitle = CommonConfigManager.shared.config.use_large_title
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "NotificationsListAppearanceTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        CommonConfigManager.shared.config.use_large_title = previousUseLargeTitle
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        retainedTraitWindows.forEach { $0.isHidden = true }
        retainedTraitWindows.removeAll()
        previousInterfaceType = nil
        previousUseLargeTitle = nil
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

    private final class TraitWindow: UIWindow {
        private let horizontalSizeClass: UIUserInterfaceSizeClass

        init(horizontalSizeClass: UIUserInterfaceSizeClass) {
            self.horizontalSizeClass = horizontalSizeClass
            super.init(frame: UIScreen.main.bounds)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var traitCollection: UITraitCollection {
            UITraitCollection(traitsFrom: [
                super.traitCollection,
                UITraitCollection(horizontalSizeClass: horizontalSizeClass)
            ])
        }
    }

    func testNotificationsRootLargeTitleFollowsCommonConfig() {
        assertLargeTitle(useLargeTitle: true, makeController: NotificationsListViewController.init)
        assertLargeTitle(useLargeTitle: false, makeController: NotificationsListViewController.init)
    }

    func testNotificationsCategoriesLargeTitleFollowsCommonConfig() {
        assertLargeTitle(useLargeTitle: true, makeController: NotificationsCategoriesViewController.init)
        assertLargeTitle(useLargeTitle: false, makeController: NotificationsCategoriesViewController.init)
    }

    private func assertLargeTitle(
        useLargeTitle: Bool,
        makeController: () -> UIViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        CommonConfigManager.shared.config.use_large_title = useLargeTitle
        let controller = makeController()
        let navigationController = UINavigationController(rootViewController: controller)
        NavigationLargeTitlePolicy.apply(to: navigationController, rootViewController: controller)

        navigationController.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        XCTAssertEqual(navigationController.navigationBar.prefersLargeTitles, useLargeTitle, file: file, line: line)
        XCTAssertEqual(
            controller.navigationItem.largeTitleDisplayMode,
            useLargeTitle ? .automatic : .never,
            file: file,
            line: line
        )
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

    private func addNotification(
        owner: String,
        uniqueId: String,
        category: XMPPNotificationsManager.Category = .info,
        isRead: Bool,
        text: String,
        jid: String = "server@example.com",
        associatedJid: String? = nil,
        originalSenderJid: String? = nil,
        dateOffset: TimeInterval = 0
    ) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let item = NotificationStorageItem()
            item.owner = owner
            item.jid = jid
            item.uniqueId = uniqueId
            item.primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uniqueId)
            item.category = category
            item.isRead = isRead
            item.text = text
            item.fallbackText = text
            item.associatedJid = associatedJid
            item.originalSenderJid = originalSenderJid
            item.shouldShow = true
            item.date = Date(timeIntervalSince1970: 1_711_283_200 + dateOffset)
            realm.add(item, update: .modified)
        }
    }

    private func setNotificationRead(
        owner: String,
        uniqueId: String,
        isRead: Bool,
        jid: String = "server@example.com"
    ) {
        let realm = try! WRealm.safe()
        let primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uniqueId)
        try! realm.write {
            realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary)?.isRead = isRead
        }
    }

    func testNotificationsListUsesInsetGroupedTransparentSplitAppearance() {
        let controller = NotificationsListViewController()
        let container = embedInTraitContainer(controller, horizontalSizeClass: .regular)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
        XCTAssertEqual(controller.emptyView.backgroundColor, .clear)
        XCTAssertFalse(controller.emptyView.isOpaque)
        XCTAssertNil(controller.navigationItem.standardAppearance)
        XCTAssertNil(controller.navigationItem.scrollEdgeAppearance)
        XCTAssertNil(controller.navigationItem.compactAppearance)
        if #available(iOS 15.0, *) {
            XCTAssertNil(controller.navigationItem.compactScrollEdgeAppearance)
        }
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:heightForHeaderInSection:))))
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:heightForFooterInSection:))))
    }

    func testNotificationsCategoriesUseInsetGroupedTransparentSplitAppearanceAndNativeSpacing() {
        let controller = NotificationsCategoriesViewController()
        let container = embedInTraitContainer(controller, horizontalSizeClass: .regular)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
        XCTAssertNil(controller.navigationItem.standardAppearance)
        XCTAssertNil(controller.navigationItem.scrollEdgeAppearance)
        XCTAssertNil(controller.navigationItem.compactAppearance)
        if #available(iOS 15.0, *) {
            XCTAssertNil(controller.navigationItem.compactScrollEdgeAppearance)
        }
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

    func testNotificationsCompactSplitUsesBottomBarAndClearsNavbarDuplicates() throws {
        let controller = NotificationsListViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "notifications_back_to_chats_button")
        XCTAssertTrue(controller.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        XCTAssertFalse(controller.isNotificationsCompactBottomBarHidden)
        XCTAssertEqual(controller.notificationsCompactBottomBarFilterButton.accessibilityIdentifier, "notifications_unread_filter_button")
        XCTAssertEqual(controller.notificationsCompactBottomBarPrimaryButton.accessibilityIdentifier, "notifications_read_all_bottom_button")
        XCTAssertEqual(
            controller.notificationsCompactBottomBarCenterTitle,
            "Read all".localizeString(id: "notifications_read_all_button", arguments: [])
        )
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isEnabled)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.accessibilityElementsHidden)
        XCTAssertTrue(controller.bottomSearchHostView.superview === controller.view)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
    }

    func testZeroMatchingUnreadHidesUnreadFilterAndReadAll() {
        let owner = "notifications-zero-unread-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "read-info", category: .info, isRead: true, text: "Read info")
        addNotification(owner: owner, uniqueId: "unread-device", category: .device, isRead: false, text: "Security")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let filterButton = controller.notificationsCompactBottomBarFilterButton
        let readAllButton = controller.notificationsCompactBottomBarPrimaryButton
        let filterPoint = controller.view.convert(
            CGPoint(x: filterButton.bounds.midX, y: filterButton.bounds.midY),
            from: filterButton
        )
        let readAllPoint = controller.view.convert(
            CGPoint(x: readAllButton.bounds.midX, y: readAllButton.bounds.midY),
            from: readAllButton
        )
        let searchButton = controller.bottomSearchHostView.collapsedButton
        let searchPoint = controller.view.convert(
            CGPoint(x: searchButton.bounds.midX, y: searchButton.bounds.midY),
            from: searchButton
        )

        XCTAssertTrue(filterButton.isHidden)
        XCTAssertFalse(filterButton.isEnabled)
        XCTAssertFalse(filterButton.isAccessibilityElement)
        XCTAssertTrue(filterButton.accessibilityElementsHidden)
        XCTAssertTrue(readAllButton.isHidden)
        XCTAssertFalse(readAllButton.isEnabled)
        XCTAssertFalse(readAllButton.isAccessibilityElement)
        XCTAssertTrue(readAllButton.accessibilityElementsHidden)
        XCTAssertFalse(controller.view.hitTest(filterPoint, with: nil) === filterButton)
        XCTAssertFalse(controller.view.hitTest(readAllPoint, with: nil) === readAllButton)
        XCTAssertTrue(controller.view.hitTest(searchPoint, with: nil) === searchButton)
    }

    func testMatchingUnreadShowsUnreadFilterAndReadAll() {
        let owner = "notifications-matching-unread-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Unread info")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertFalse(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isEnabled)
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isAccessibilityElement)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isEnabled)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isAccessibilityElement)
    }

    func testReadNotificationInAnotherCategoryDoesNotAffectCurrentAvailability() {
        let owner = "notifications-other-category-read-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Unread info")
        addNotification(owner: owner, uniqueId: "read-device", category: .device, isRead: true, text: "Read security")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertFalse(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isEnabled)
    }

    func testUnreadNotificationInAnotherAccountDoesNotAffectPinnedAccountScope() {
        let owner = "notifications-pinned-\(UUID().uuidString)@example.com"
        let otherOwner = "notifications-other-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, order: 0)
        addEnabledAccount(owner: otherOwner, order: 1)
        addNotification(owner: owner, uniqueId: "read-info", category: .info, isRead: true, text: "Read info")
        addNotification(owner: otherOwner, uniqueId: "unread-info", category: .info, isRead: false, text: "Other unread")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
    }

    func testLocalSearchDoesNotChangeUnreadActionAvailability() {
        let owner = "notifications-search-availability-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Alpha outage")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()

        controller.bottomSearchHostView.setQuery("no matching notification", notify: true)
        controller.updateNotificationsCompactBottomBarState()

        XCTAssertFalse(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isEnabled)
    }

    func testActiveUnreadFilterResetsWhenLastMatchingUnreadBecomesRead() {
        let owner = "notifications-reset-unread-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Unread info")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.unreadOnly.accept(true)
        controller.updateNotificationsCompactBottomBarState()
        setNotificationRead(owner: owner, uniqueId: "unread-info", isRead: true)

        controller.updateNotificationsCompactBottomBarState()

        XCTAssertFalse(controller.unreadOnly.value)
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
    }

    func testReadAllHidesBothActionsAfterMatchingRowsAreMarkedRead() {
        let owner = "notifications-read-all-hide-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Unread info")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.unreadOnly.accept(true)
        controller.updateNotificationsCompactBottomBarState()

        controller.notificationsCompactBottomBarPrimaryButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.unreadOnly.value)
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isEnabled)
    }

    func testHiddenNotificationActionsDoNotMoveSearchFrame() {
        let owner = "notifications-fixed-search-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Unread info")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let visibleActionsSearchFrame = controller.bottomSearchHostView.collapsedButton.convert(
            controller.bottomSearchHostView.collapsedButton.bounds,
            to: controller.view
        )
        setNotificationRead(owner: owner, uniqueId: "unread-info", isRead: true)

        controller.updateNotificationsCompactBottomBarState()
        controller.view.layoutIfNeeded()

        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertEqual(
            controller.bottomSearchHostView.collapsedButton.convert(
                controller.bottomSearchHostView.collapsedButton.bounds,
                to: controller.view
            ),
            visibleActionsSearchFrame
        )
    }

    func testRegularWidthNavbarReadAllAndFiltersRemainUnchanged() {
        let controller = NotificationsListViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
        container.loadViewIfNeeded()
        let originalIdentifiers = controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier)

        controller.updateNotificationsCompactBottomBarState()
        controller.configureBars(animated: false)

        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier),
            originalIdentifiers
        )
        XCTAssertTrue(originalIdentifiers?.contains("notifications_filter_menu_button") == true)
        XCTAssertTrue(originalIdentifiers?.contains("notifications_mark_all_read_button") == true)
        XCTAssertTrue(controller.isNotificationsCompactBottomBarHidden)
    }

    func testNotificationsLastRowRemainsAboveBottomSearchAtMaximumOffset() {
        let controller = NotificationsListViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        controller.tableView.contentSize = CGSize(width: 393, height: 1_600)
        controller.updateNotificationsTableInsetsForBottomSearch()
        let maximumOffsetY = max(
            -controller.tableView.adjustedContentInset.top,
            controller.tableView.contentSize.height
                + controller.tableView.adjustedContentInset.bottom
                - controller.tableView.bounds.height
        )
        controller.tableView.contentOffset.y = maximumOffsetY

        let contentBottomY = controller.tableView.convert(
            CGPoint(x: 0, y: controller.tableView.contentSize.height),
            to: controller.view
        ).y
        let searchFrame = controller.bottomSearchHostView.collapsedButton.convert(
            controller.bottomSearchHostView.collapsedButton.bounds,
            to: controller.view
        )

        XCTAssertLessThanOrEqual(
            contentBottomY,
            searchFrame.minY - FloatingBottomBarView.Metrics.tableInsetPadding + 0.001
        )
    }

    func testNotificationsUsesGeometryBasedBottomOverlayInsetCoordinator() {
        let controller = NotificationsListViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.updateNotificationsTableInsetsForBottomSearch()

        XCTAssertGreaterThan(controller.bottomOverlayInsetCoordinator.appliedBottomContribution, 0)
        XCTAssertEqual(
            controller.tableView.contentInset.bottom,
            controller.bottomOverlayInsetCoordinator.appliedBottomContribution,
            accuracy: 0.001
        )
    }

    func testNotificationsRegularWidthKeepsNavbarActionsAndHidesCompactBottomBar() throws {
        let controller = NotificationsListViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

        container.loadViewIfNeeded()

        XCTAssertTrue(controller.isNotificationsCompactBottomBarHidden)
        XCTAssertFalse(controller.navigationItem.rightBarButtonItems?.isEmpty ?? true)
    }

    func testNotificationsCompactBottomFilterReceivesHitWhenSearchHostIsCollapsed() {
        let owner = "notifications-filter-hit-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-info", category: .info, isRead: false, text: "Unread info")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let button = controller.notificationsCompactBottomBarFilterButton
        let buttonPoint = controller.view.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button
        )

        XCTAssertTrue(controller.view.hitTest(buttonPoint, with: nil) === button)
    }

    func testNotificationsCompactUnreadFilterTogglesWithoutChangingCategoryOrAccount() {
        let owner = "notifications-unread-filter-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "unread-mention", category: .mention, isRead: false, text: "Unread mention")
        let controller = NotificationsListViewController()
        controller.filter.accept(.mentions)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertFalse(controller.isNotificationsCompactUnreadFilterActive)

        controller.notificationsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(controller.isNotificationsCompactUnreadFilterActive)
        XCTAssertEqual(controller.filter.value, .mentions)
        XCTAssertEqual(controller.filterAccount.value, owner)

        controller.notificationsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.isNotificationsCompactUnreadFilterActive)
        XCTAssertEqual(controller.filter.value, .mentions)
        XCTAssertEqual(controller.filterAccount.value, owner)
    }

    func testMarkAllStillTargetsOnlyCurrentCategoryAndAccountScope() throws {
        let owner = "notifications-read-all-\(UUID().uuidString)@example.com"
        let otherOwner = "notifications-read-all-other-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addEnabledAccount(owner: otherOwner)
        addNotification(owner: owner, uniqueId: "matching-unread", category: .info, isRead: false, text: "Matching info")
        addNotification(owner: owner, uniqueId: "wrong-category", category: .device, isRead: false, text: "Security")
        addNotification(owner: otherOwner, uniqueId: "wrong-owner", category: .info, isRead: false, text: "Other owner")
        addNotification(owner: owner, uniqueId: "already-read", category: .info, isRead: true, text: "Already read")
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        controller.notificationsCompactBottomBarPrimaryButton.sendActions(for: .touchUpInside)

        let realm = try WRealm.safe()
        func isRead(_ uniqueId: String, owner targetOwner: String = owner) -> Bool {
            realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: targetOwner,
                    jid: "server@example.com",
                    uniqueId: uniqueId
                )
            )?.isRead ?? false
        }

        XCTAssertTrue(isRead("matching-unread"))
        XCTAssertFalse(isRead("wrong-category"))
        XCTAssertFalse(isRead("wrong-owner", owner: otherOwner))
        XCTAssertTrue(isRead("already-read"))
        XCTAssertFalse(controller.isNotificationsCompactReadAllButtonEnabled)
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
    }

    func testNotificationsLocalSearchFiltersStoredNotificationRows() {
        let owner = "notifications-search-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "alpha", category: .info, isRead: false, text: "Alpha outage", dateOffset: 2)
        addNotification(owner: owner, uniqueId: "beta", category: .info, isRead: false, text: "Beta maintenance", dateOffset: 1)
        let controller = NotificationsListViewController()

        let snapshot = controller.buildDatasourceSnapshot(
            filter: .all,
            filterAccount: nil,
            unreadOnly: false,
            searchQuery: "alpha"
        )
        let rows = snapshot.datasource.flatMap(\.childs).filter { !$0.isHeader }

        XCTAssertEqual(rows.map(\.primary), [
            NotificationStorageItem.genPrimary(owner: owner, jid: "server@example.com", uniqueId: "alpha")
        ])
    }

    func testNotificationsCompactSearchExpansionHidesActionsOnlyAfterMorphAndRestoresBeforeCollapse() throws {
        let controller = NotificationsListViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        controller.bottomSearchHostView.animatorFactory = { _, curve in
            UIViewPropertyAnimator(duration: 10, curve: curve)
        }

        XCTAssertFalse(controller.isNotificationsCompactBottomBarHidden)

        controller.bottomSearchHostView.collapsedButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(controller.bottomSearchHostView.isExpanded)
        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .expanding)
        XCTAssertFalse(controller.isNotificationsCompactBottomBarHidden)
        let expansionAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        expansionAnimator.pauseAnimation()
        expansionAnimator.stopAnimation(false)
        expansionAnimator.finishAnimation(at: .end)

        XCTAssertTrue(controller.isNotificationsCompactBottomBarHidden)

        controller.bottomSearchHostView.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .collapsing)
        XCTAssertFalse(controller.isNotificationsCompactBottomBarHidden)
        let collapseAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        collapseAnimator.pauseAnimation()
        collapseAnimator.stopAnimation(false)
        collapseAnimator.finishAnimation(at: .end)
    }

    func testNotificationsCategoriesRegularNavbarShowsSidebarButtonImmediately() {
        let controller = NotificationsCategoriesViewController()

        controller.loadViewIfNeeded()
        controller.configureLeadingNavigationItem(forRegularWidth: true, animated: false)

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "notifications_sidebar_menu_button")
    }

    @discardableResult
    private func embedInTraitContainer(
        _ child: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> UIViewController {
        let parent = UIViewController()
        let window = TraitWindow(horizontalSizeClass: horizontalSizeClass)
        window.rootViewController = parent
        window.isHidden = false
        retainedTraitWindows.append(window)
        parent.loadViewIfNeeded()
        parent.addChild(child)
        parent.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: horizontalSizeClass),
            forChild: child
        )
        child.loadViewIfNeeded()
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        applyContinuousSplitAppearanceAfterAttach(to: child)
        return parent
    }

    private func applyContinuousSplitAppearanceAfterAttach(to viewController: UIViewController) {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(viewController)
        if let navigationController = viewController as? UINavigationController {
            navigationController.viewControllers.forEach(applyContinuousSplitAppearanceAfterAttach)
        }
        if let notificationsController = viewController as? NotificationsListViewController {
            notificationsController.refreshContinuousSplitBackgroundAppearance()
        }
        if let categoryController = viewController as? NotificationsCategoriesViewController {
            categoryController.tableView.applyContinuousSplitInsetGroupedAppearance()
        }
    }
}
