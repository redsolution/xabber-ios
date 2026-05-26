//
//  CallsListCoordinatorTests.swift
//  xabberTests
//
//  Created by Codex on 25.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
import RealmSwift
@testable import xabber

final class CallsListCoordinatorTests: XCTestCase {
    private let owner = "owner@example.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "CallsListCoordinatorTests-\(UUID().uuidString)"
        )
    }

    func testCallStateAndDirectionMapToFilters() {
        XCTAssertEqual(CallsListCoordinator.filter(for: .missed, outgoing: false), .missed)
        XCTAssertEqual(CallsListCoordinator.filter(for: .received, outgoing: false), .incoming)
        XCTAssertEqual(CallsListCoordinator.filter(for: .made, outgoing: false), .incoming)
        XCTAssertEqual(CallsListCoordinator.filter(for: .made, outgoing: true), .outgoing)
        XCTAssertEqual(CallsListCoordinator.filter(for: .none, outgoing: true), .outgoing)
        XCTAssertEqual(CallsListCoordinator.filter(for: .busy, outgoing: false), .declined)
        XCTAssertEqual(CallsListCoordinator.filter(for: .noanswer, outgoing: true), .declined)
    }

    func testFilteredDatasourceReturnsMatchingCallsOnly() throws {
        let realm = try WRealm.safe()
        try realm.write {
            addCall(to: realm, jid: "missed@example.com", callState: .missed, outgoing: false, dateOffset: 1)
            addCall(to: realm, jid: "incoming@example.com", callState: .received, outgoing: false, dateOffset: 2)
            addCall(to: realm, jid: "outgoing@example.com", callState: .made, outgoing: true, dateOffset: 3)
            addCall(to: realm, jid: "declined@example.com", callState: .busy, outgoing: false, dateOffset: 4)
        }

        let state = CallsListCoordinator.deriveState(
            realm: realm,
            enabledAccounts: [owner],
            filter: .outgoing
        )

        XCTAssertEqual(state.listDatasource.map(\.jid), ["outgoing@example.com"])
        XCTAssertEqual(state.listDatasource.first?.direction, .outgoing)
    }

    func testCategoryDatasourceCountsNonDeletedEnabledAccountCalls() throws {
        let realm = try WRealm.safe()
        try realm.write {
            addCall(to: realm, jid: "missed@example.com", callState: .missed, outgoing: false, dateOffset: 1)
            addCall(to: realm, jid: "incoming@example.com", callState: .received, outgoing: false, dateOffset: 2)
            addCall(to: realm, jid: "outgoing@example.com", callState: .made, outgoing: true, dateOffset: 3)
            addCall(to: realm, jid: "declined@example.com", callState: .noanswer, outgoing: true, dateOffset: 4)
            addCall(to: realm, jid: "deleted@example.com", callState: .missed, outgoing: false, dateOffset: 5, isDeleted: true)
            addCall(to: realm, owner: "disabled@example.com", jid: "ignored@example.com", callState: .missed, outgoing: false, dateOffset: 6)
        }

        let state = CallsListCoordinator.deriveState(
            realm: realm,
            enabledAccounts: [owner],
            filter: .all
        )

        XCTAssertEqual(state.counters, CallsListCoordinator.Counters(total: 4, missed: 1, incoming: 1, outgoing: 1, declined: 1))
        let categoryRows = state.categoriesDatasource.flatMap { $0 }.filter { !$0.isHeader }
        XCTAssertEqual(categoryRows.map(\.key), [
            CallsListFilter.missed.rawValue,
            CallsListFilter.incoming.rawValue,
            CallsListFilter.outgoing.rawValue,
            CallsListFilter.declined.rawValue
        ])
        XCTAssertNil(categoryRows.first(where: { $0.key == CallsListFilter.all.rawValue }))
        XCTAssertEqual(categoryRows.first(where: { $0.key == CallsListFilter.missed.rawValue })?.subtitle, "1")
        XCTAssertEqual(categoryRows.first(where: { $0.key == CallsListFilter.incoming.rawValue })?.subtitle, "")
        XCTAssertEqual(categoryRows.first(where: { $0.key == CallsListFilter.outgoing.rawValue })?.subtitle, "")
        XCTAssertEqual(categoryRows.first(where: { $0.key == CallsListFilter.declined.rawValue })?.subtitle, "")
        XCTAssertTrue(categoryRows.first(where: { $0.key == CallsListFilter.missed.rawValue })?.color.isEqual(UIColor.systemRed) == true)
        XCTAssertTrue(categoryRows.first(where: { $0.key == CallsListFilter.incoming.rawValue })?.color.isEqual(UIColor.systemGreen) == true)
        XCTAssertTrue(categoryRows.first(where: { $0.key == CallsListFilter.outgoing.rawValue })?.color.isEqual(UIColor.systemGreen) == true)
        XCTAssertTrue(categoryRows.first(where: { $0.key == CallsListFilter.declined.rawValue })?.color.isEqual(UIColor.systemRed) == true)
    }

    func testSelectedCategoryChangesListFilter() {
        let controller = LastCallsViewController()

        controller.shouldFilterBy(category: CallsListFilter.missed.rawValue)
        XCTAssertEqual(controller.filter.value, .missed)

        controller.shouldFilterBy(category: nil)
        XCTAssertEqual(controller.filter.value, .all)
    }

    func testRegularWidthFactoryCreatesCategoriesAndWiredList() throws {
        let controllers = CallsSectionCoordinator.makeControllers(regularWidth: true)
        let categoriesController = try XCTUnwrap(controllers.categoriesController)

        XCTAssertTrue(categoriesController.filterDelegate as? LastCallsViewController === controllers.listController)
    }

    func testCompactFactoryCreatesListOnly() {
        let controllers = CallsSectionCoordinator.makeControllers(regularWidth: false)

        XCTAssertNil(controllers.categoriesController)
        XCTAssertTrue(controllers.listController.filter.value == .all)
    }

    func testCompactListExposesSelectedCategoryMenuOnLeftNavbar() throws {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.tabs.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let controller = LastCallsViewController()
        controller.filter.accept(.declined)
        controller.loadViewIfNeeded()
        controller.configureBars()

        let leftItems = try XCTUnwrap(controller.navigationItem.leftBarButtonItems)
        let filterButton = try XCTUnwrap(leftItems.first { $0.accessibilityIdentifier == "calls_filter_menu_button" })
        let actions = try XCTUnwrap(filterButton.menu?.children.compactMap { $0 as? UIAction })
        let declinedAction = try XCTUnwrap(actions.first { $0.identifier.rawValue == "calls.filter.\(CallsListFilter.declined.rawValue)" })

        XCTAssertEqual(actions.map(\.identifier.rawValue), [
            "calls.filter.\(CallsListFilter.missed.rawValue)",
            "calls.filter.\(CallsListFilter.incoming.rawValue)",
            "calls.filter.\(CallsListFilter.outgoing.rawValue)",
            "calls.filter.\(CallsListFilter.declined.rawValue)"
        ])
        XCTAssertEqual(declinedAction.state, .on)
        XCTAssertEqual(declinedAction.title, CallsListFilter.declined.title)
    }

    func testCompactListDoesNotCheckCategoryMenuWhenInternalAllFilterIsActive() throws {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.tabs.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let controller = LastCallsViewController()
        controller.filter.accept(.all)
        controller.loadViewIfNeeded()
        controller.configureBars()

        let leftItems = try XCTUnwrap(controller.navigationItem.leftBarButtonItems)
        let filterButton = try XCTUnwrap(leftItems.first { $0.accessibilityIdentifier == "calls_filter_menu_button" })
        let actions = try XCTUnwrap(filterButton.menu?.children.compactMap { $0 as? UIAction })

        XCTAssertFalse(actions.contains { $0.identifier.rawValue == "calls.filter.\(CallsListFilter.all.rawValue)" })
        XCTAssertTrue(actions.allSatisfy { $0.state == .off })
    }

    private func addCall(
        to realm: Realm,
        owner: String? = nil,
        jid: String,
        callState: MessageStorageItem.VoIPCallState,
        outgoing: Bool,
        dateOffset: TimeInterval,
        isDeleted: Bool = false
    ) {
        let owner = owner ?? self.owner
        let message = MessageStorageItem()
        message.primary = "\(owner)-\(jid)-\(dateOffset)"
        message.owner = owner
        message.opponent = jid
        message.messageType = MessageStorageItem.MessageDisplayType.call.rawValue
        message.date = Date(timeIntervalSince1970: dateOffset)
        message.outgoing = outgoing
        message.isDeleted = isDeleted

        let reference = MessageReferenceStorageItem()
        reference.primary = "ref-\(message.primary)"
        reference.owner = owner
        reference.messageId = message.primary
        reference.kind = .call
        reference.metadata = ["callState": callState.rawValue]
        message.references.append(reference)

        realm.add(message)
    }
}

@MainActor
final class CallsVisualStyleTests: XCTestCase {
    private var previousInterfaceType: String!
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "CallsVisualStyleTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousInterfaceType = nil
        previousRealmConfiguration = nil
        super.tearDown()
    }

    private func addEnabledAccount(owner: String, colorKey: String, order: Int) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let account = AccountStorageItem()
            account.jid = owner
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

    func testCallsListTableUsesInsetGroupedTransparentSplitAppearance() {
        let controller = LastCallsViewController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
    }

    func testCallsCategoriesTableUsesInsetGroupedTransparentSplitAppearanceAndNativeSpacing() {
        let controller = CallsCategoriesViewController()
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

    func testCallsListCellsUsePlainSystemBackgroundWithoutGlass() {
        let cell = LastCallsViewController.ItemCell(style: .default, reuseIdentifier: LastCallsViewController.ItemCell.cellName)

        cell.applyPlainGroupedSystemBackground()

        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertNil(cell.backgroundConfiguration?.visualEffect)
        XCTAssertEqual(cell.contentView.backgroundColor, .clear)
        XCTAssertNil(cell.configurationUpdateHandler)
        XCTAssertNil(cell.selectedBackgroundView)
        XCTAssertEqual(cell.selectionStyle, .none)
    }

    func testCallsCategoryRowsUsePlainSystemBackgroundWithoutGlass() {
        let owner = "calls-selected-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "red")
        addEnabledAccount(owner: owner, colorKey: "red", order: 0)
        let unselectedController = CallsCategoriesViewController()
        unselectedController.loadViewIfNeeded()

        let unselectedCategory = unselectedController.tableView(
            unselectedController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertEqual(unselectedCategory.backgroundColor, .systemBackground)
        XCTAssertNil(unselectedCategory.backgroundConfiguration?.visualEffect)
        XCTAssertEqual(unselectedCategory.contentView.backgroundColor, .clear)
        XCTAssertNotNil(unselectedCategory.configurationUpdateHandler)
        XCTAssertNil(unselectedCategory.selectedBackgroundView)
        XCTAssertEqual(unselectedCategory.selectionStyle, .none)
        XCTAssertEqual(unselectedCategory.layer.borderWidth, 0)
        XCTAssertEqual(unselectedCategory.layer.shadowOpacity, 0)

        let selectedController = CallsCategoriesViewController()
        selectedController.loadViewIfNeeded()
        selectedController.selectFilter(.missed, animated: false, notify: false)
        let selectedCategory = selectedController.tableView(
            selectedController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertTrue(
            selectedCategory.backgroundColor?.isEqual(AccountColorManager.shared.palette(for: owner).tint50) == true
        )
        XCTAssertNil(selectedCategory.backgroundConfiguration?.visualEffect)

        let deselectedController = CallsCategoriesViewController()
        deselectedController.loadViewIfNeeded()
        deselectedController.selectFilter(.incoming, animated: false, notify: false)
        let deselectedCategory = deselectedController.tableView(
            deselectedController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertEqual(deselectedCategory.backgroundColor, .systemBackground)
    }

    func testAccountSelectionHighlightFallsBackToFirstEnabledAccountByOrder() {
        let firstOwner = "first-highlight-\(UUID().uuidString)@example.com"
        let secondOwner = "second-highlight-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: firstOwner, colorKey: "blue")
        registerAccountColor(owner: secondOwner, colorKey: "red")
        addEnabledAccount(owner: secondOwner, colorKey: "red", order: 2)
        addEnabledAccount(owner: firstOwner, colorKey: "blue", order: 1)

        let fallbackColor = AccountSelectionHighlightStyle.tint50(
            owner: nil,
            fallbackOwners: [secondOwner, firstOwner]
        )

        XCTAssertTrue(fallbackColor.isEqual(AccountColorManager.shared.palette(for: firstOwner).tint50))
    }

    func testCallsCategoriesRowsUseFixedHeightAndHeaderStaysAutomatic() {
        let controller = CallsCategoriesViewController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: IndexPath(row: 0, section: 0)),
            UITableView.automaticDimension
        )
        XCTAssertEqual(
            controller.tableView(controller.tableView, heightForRowAt: IndexPath(row: 0, section: 1)),
            44
        )
    }

    func testCallsCategoriesNavigationAppearanceRemovesOnlyHairline() {
        let controller = CallsCategoriesViewController()
        _ = UINavigationController(rootViewController: controller)

        controller.loadViewIfNeeded()

        [
            controller.navigationItem.standardAppearance,
            controller.navigationItem.scrollEdgeAppearance,
            controller.navigationItem.compactAppearance
        ].forEach { appearance in
            XCTAssertNotNil(appearance)
            let shadowColor = appearance?.shadowColor
            XCTAssertTrue(shadowColor == nil || shadowColor?.cgColor.alpha == 0)
            let shadowImage = appearance?.shadowImage
            XCTAssertTrue(shadowImage == nil || shadowImage?.size == .zero)
        }
        if #available(iOS 15.0, *) {
            XCTAssertNotNil(controller.navigationItem.compactScrollEdgeAppearance)
        }
    }

    func testSharedContinuousSplitGlassEffectUsesNativeGlassWhenAvailable() throws {
        let effect = ContinuousSplitCellBackgroundStyle.makeEffect(isHighlighted: false)

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertFalse(glassEffect.isInteractive)
            XCTAssertEqual(glassEffect.tintColor, ContinuousSplitCellBackgroundStyle.nativeGlassTintColor)
        } else {
            XCTAssertTrue(effect is UIBlurEffect)
        }
    }

    func testSharedContinuousSplitGlassFallbackUsesExistingBlurMaterials() {
        let normalEffect = ContinuousSplitCellBackgroundStyle.makeEffect(
            isHighlighted: false,
            prefersNativeGlass: false
        )
        let highlightedEffect = ContinuousSplitCellBackgroundStyle.makeEffect(
            isHighlighted: true,
            prefersNativeGlass: false
        )

        XCTAssertTrue(normalEffect is UIBlurEffect)
        XCTAssertTrue(highlightedEffect is UIBlurEffect)
        XCTAssertEqual(ContinuousSplitCellBackgroundStyle.normalFallbackBlurStyle, .systemThinMaterial)
        XCTAssertEqual(ContinuousSplitCellBackgroundStyle.highlightedFallbackBlurStyle, .systemMaterial)
    }
}
