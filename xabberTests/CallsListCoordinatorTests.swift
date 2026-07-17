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
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "CallsListCoordinatorTests-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
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

    func testCountersRemainUnfilteredBySelectedCategoryAndSearch() throws {
        let realm = try WRealm.safe()
        try realm.write {
            addCall(to: realm, jid: "alpha@example.com", callState: .missed, outgoing: false, dateOffset: 3)
            addCall(to: realm, jid: "beta@example.com", callState: .missed, outgoing: false, dateOffset: 2)
            addCall(to: realm, jid: "alpha-incoming@example.com", callState: .received, outgoing: false, dateOffset: 1)
        }

        let state = CallsListCoordinator.deriveState(
            realm: realm,
            enabledAccounts: [owner],
            filter: .missed,
            searchQuery: "alpha"
        )

        XCTAssertEqual(state.listDatasource.map(\.jid), ["alpha@example.com"])
        XCTAssertEqual(state.counters, CallsListCoordinator.Counters(total: 3, missed: 2, incoming: 1, outgoing: 0, declined: 0))
    }

    func testSearchQueryMatchesCallDirectionTitle() throws {
        let realm = try WRealm.safe()
        try realm.write {
            addCall(to: realm, jid: "first@example.com", callState: .missed, outgoing: false, dateOffset: 2)
            addCall(to: realm, jid: "second@example.com", callState: .received, outgoing: false, dateOffset: 1)
        }

        let state = CallsListCoordinator.deriveState(
            realm: realm,
            enabledAccounts: [owner],
            filter: .all,
            searchQuery: LastCallsViewController.DisplayCallDirection.missed.title
        )

        XCTAssertEqual(state.listDatasource.map(\.jid), ["first@example.com"])
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
        XCTAssertEqual(state.categoriesDatasource.first?.first?.isSelectable, false)
        let categoryRows = state.categoriesDatasource.flatMap { $0 }.filter { !$0.isHeader }
        XCTAssertTrue(categoryRows.allSatisfy(\.isSelectable))
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
            inMemoryIdentifier: "CallsVisualStyleTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        retainedTraitWindows.forEach { $0.isHidden = true }
        retainedTraitWindows.removeAll()
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        CommonConfigManager.shared.config.use_large_title = previousUseLargeTitle
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousInterfaceType = nil
        previousUseLargeTitle = nil
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

    @discardableResult
    private func addCall(
        owner: String,
        jid: String,
        state: MessageStorageItem.VoIPCallState,
        outgoing: Bool,
        date: Date = Date()
    ) -> String {
        let realm = try! WRealm.safe()
        let primary = "call-\(UUID().uuidString)"
        try! realm.write {
            let message = MessageStorageItem()
            message.primary = primary
            message.owner = owner
            message.opponent = jid
            message.messageType = MessageStorageItem.MessageDisplayType.call.rawValue
            message.date = date
            message.outgoing = outgoing

            let reference = MessageReferenceStorageItem()
            reference.primary = "ref-\(primary)"
            reference.owner = owner
            reference.messageId = primary
            reference.kind = .call
            reference.metadata = ["callState": state.rawValue]
            message.references.append(reference)
            realm.add(message)
        }
        return primary
    }

    private func registerAccountColor(owner: String, colorKey: String) {
        AccountColorManager.shared.accounts.insert(
            AccountColorManager.ColorForJid(
                jid: owner,
                color: AccountColorManager.shared.colorForKey(colorKey)
            )
        )
    }

    private func makeSolidAvatarImage(color: UIColor, size: CGSize = CGSize(width: 48, height: 48)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func assertImage(
        _ image: UIImage?,
        matches expectedImage: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(image?.size, expectedImage.size, file: file, line: line)
        XCTAssertEqual(image?.pngData(), expectedImage.pngData(), file: file, line: line)
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
        if let navigationController = child as? UINavigationController {
            navigationController.topViewController?.loadViewIfNeeded()
        }
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        return parent
    }

    func testCallsRootLargeTitleFollowsCommonConfig() {
        assertLargeTitle(useLargeTitle: true, makeController: LastCallsViewController.init)
        assertLargeTitle(useLargeTitle: false, makeController: LastCallsViewController.init)
    }

    func testCallsCategoriesLargeTitleFollowsCommonConfig() {
        assertLargeTitle(useLargeTitle: true, makeController: CallsCategoriesViewController.init)
        assertLargeTitle(useLargeTitle: false, makeController: CallsCategoriesViewController.init)
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

    func testCallsListTableUsesInsetGroupedTransparentSplitAppearanceInRegularWidth() {
        let controller = LastCallsViewController()
        let container = embedInTraitContainer(controller, horizontalSizeClass: .regular)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
    }

    func testCallsListTableUsesStockBackgroundInCompactSplitWidth() {
        let controller = LastCallsViewController()
        let container = embedInTraitContainer(controller, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertTrue(controller.tableView.backgroundColor?.isEqual(UIColor.systemGroupedBackground) == true)
        XCTAssertTrue(controller.tableView.isOpaque)
        XCTAssertTrue(controller.view.backgroundColor?.isEqual(UIColor.systemBackground) == true)
        XCTAssertTrue(controller.view.isOpaque)
    }

    func testCallsConfigureSearchBarInstallsBottomSearchWithoutMutatingAppearance() {
        let controller = LastCallsViewController()
        _ = UINavigationController(rootViewController: controller)
        let standardAppearance = UINavigationBarAppearance()
        let scrollEdgeAppearance = UINavigationBarAppearance()
        let compactAppearance = UINavigationBarAppearance()
        standardAppearance.backgroundColor = .systemRed
        scrollEdgeAppearance.backgroundColor = .systemGreen
        compactAppearance.backgroundColor = .systemBlue
        controller.navigationItem.standardAppearance = standardAppearance
        controller.navigationItem.scrollEdgeAppearance = scrollEdgeAppearance
        controller.navigationItem.compactAppearance = compactAppearance
        let searchBar = controller.searchController.searchBar
        let searchBarBackground = searchBar.backgroundColor
        let textFieldBackground = searchBar.searchTextField.backgroundColor
        let textFieldLayerBackground = searchBar.searchTextField.layer.backgroundColor

        controller.loadViewIfNeeded()
        controller.configureSearchBar()

        XCTAssertNil(controller.navigationItem.searchController)
        XCTAssertTrue(controller.bottomSearchHostView.superview === controller.view)
        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
        XCTAssertEqual(controller.navigationItem.standardAppearance?.backgroundColor, standardAppearance.backgroundColor)
        XCTAssertEqual(controller.navigationItem.scrollEdgeAppearance?.backgroundColor, scrollEdgeAppearance.backgroundColor)
        XCTAssertEqual(controller.navigationItem.compactAppearance?.backgroundColor, compactAppearance.backgroundColor)
        XCTAssertEqual(searchBar.backgroundColor, searchBarBackground)
        XCTAssertEqual(searchBar.searchTextField.backgroundColor, textFieldBackground)
        XCTAssertTrue(searchBar.searchTextField.layer.backgroundColor === textFieldLayerBackground)
    }

    func testCallsConfigureBarsReusesNavigationItemsWhenStateIsUnchanged() {
        let controller = LastCallsViewController()

        controller.configureBars(animated: false)
        let leftItem = controller.navigationItem.leftBarButtonItem
        let rightItem = controller.navigationItem.rightBarButtonItem

        controller.configureBars(animated: false)

        XCTAssertTrue(controller.navigationItem.leftBarButtonItem === leftItem)
        XCTAssertTrue(controller.navigationItem.rightBarButtonItem === rightItem)
        XCTAssertNil(controller.navigationItem.searchController)
    }

    func testCallsBottomSearchExpandsWithoutShowingLegacyBottomBar() throws {
        let controller = LastCallsViewController()
        let container = embedInTraitContainer(controller, horizontalSizeClass: .regular)

        container.loadViewIfNeeded()
        controller.configureSearchBar()

        XCTAssertNil(controller.navigationItem.searchController)
        XCTAssertTrue(controller.bottomBar.superview == nil || controller.bottomBar.isHidden)
        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        controller.bottomSearchHostView.animatorFactory = { _, curve in
            UIViewPropertyAnimator(duration: 10, curve: curve)
        }

        controller.bottomSearchHostView.collapsedButton.sendActions(for: .touchUpInside)
        let expansionAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        expansionAnimator.pauseAnimation()
        expansionAnimator.stopAnimation(false)
        expansionAnimator.finishAnimation(at: .end)

        XCTAssertTrue(controller.bottomSearchHostView.isExpanded)
        XCTAssertTrue(controller.bottomSearchHostView.collapsedButton.isHidden)
        XCTAssertFalse(controller.bottomSearchHostView.surfaceView.isHidden)
        XCTAssertTrue(controller.bottomBar.superview == nil || controller.bottomBar.isHidden)
    }

    func testCallsCategoriesTableUsesInsetGroupedTransparentSplitAppearanceAndNativeSpacingInRegularWidth() {
        let controller = CallsCategoriesViewController()
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

    func testCallsCategoriesTableUsesStockBackgroundInCompactSplitWidth() {
        let controller = CallsCategoriesViewController()
        let container = embedInTraitContainer(controller, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertTrue(controller.tableView.backgroundColor?.isEqual(UIColor.systemGroupedBackground) == true)
        XCTAssertTrue(controller.tableView.isOpaque)
        XCTAssertTrue(controller.view.backgroundColor?.isEqual(UIColor.systemBackground) == true)
        XCTAssertTrue(controller.view.isOpaque)
        XCTAssertNil(controller.navigationItem.standardAppearance)
        XCTAssertNil(controller.navigationItem.scrollEdgeAppearance)
        XCTAssertNil(controller.navigationItem.compactAppearance)
        if #available(iOS 15.0, *) {
            XCTAssertNil(controller.navigationItem.compactScrollEdgeAppearance)
        }
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
        assertNoSelectionOutline(in: cell)
    }

    func testCallsListCellUsesCachedAvatarSynchronously() {
        let avatarURL = "https://example.com/calls-avatar-\(UUID().uuidString).png"
        let cachedImage = makeSolidAvatarImage(color: .systemOrange)
        DefaultAvatarManager.shared.storeImage(for: avatarURL, image: cachedImage)
        let cell = LastCallsViewController.ItemCell(
            style: .default,
            reuseIdentifier: LastCallsViewController.ItemCell.cellName
        )

        cell.configure(
            owner: "owner@example.com",
            jid: "juliet@example.com",
            avatarUrl: avatarURL,
            username: "Juliet",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            direction: .incoming,
            outgoing: false
        )

        assertImage(cell.avatarView.image, matches: cachedImage)
    }

    func testCallsRowsDoNotUseUIKitFocusOutline() {
        let listController = LastCallsViewController()
        listController.loadViewIfNeeded()

        XCTAssertFalse(listController.tableView(listController.tableView, canFocusRowAt: IndexPath(row: 0, section: 0)))

        let categoriesController = CallsCategoriesViewController()
        categoriesController.loadViewIfNeeded()

        XCTAssertFalse(categoriesController.tableView(categoriesController.tableView, canFocusRowAt: IndexPath(row: 0, section: 1)))
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
        assertNoSelectionOutline(in: unselectedCategory)

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
        assertNoSelectionOutline(in: selectedCategory)

        let deselectedController = CallsCategoriesViewController()
        deselectedController.loadViewIfNeeded()
        deselectedController.selectFilter(.incoming, animated: false, notify: false)
        let deselectedCategory = deselectedController.tableView(
            deselectedController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertEqual(deselectedCategory.backgroundColor, .systemBackground)
        assertNoSelectionOutline(in: deselectedCategory)
    }

    func testCallsCategoryIntroHeaderIsInformationalOnly() {
        final class FilterSpy: CallsControllerFilterProtocol {
            var categories: [String?] = []

            func shouldFilterBy(category: String?) {
                categories.append(category)
            }
        }

        let controller = CallsCategoriesViewController()
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
        XCTAssertTrue(spy.categories.isEmpty)
        XCTAssertEqual(controller.tableView.indexPathsForSelectedRows ?? [], selectedRowsBeforeHeaderTap)

        XCTAssertTrue(controller.tableView(controller.tableView, shouldHighlightRowAt: categoryIndexPath))
        XCTAssertEqual(controller.tableView(controller.tableView, willSelectRowAt: categoryIndexPath), categoryIndexPath)
        controller.tableView(controller.tableView, didSelectRowAt: categoryIndexPath)
        XCTAssertEqual(spy.categories, [CallsListFilter.missed.rawValue])
    }

    func testCallsCompactSplitUsesBottomBarAndClearsNavbarDuplicates() throws {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "calls_back_to_chats_button")
        XCTAssertTrue(controller.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        XCTAssertFalse(controller.isCallsCompactBottomBarHidden)
        XCTAssertEqual(controller.callsCompactBottomBarFilterButton.accessibilityIdentifier, "calls_missed_filter_button")
        XCTAssertEqual(controller.callsCompactBottomBarPrimaryButton.accessibilityIdentifier, "calls_start_call_bottom_button")
        XCTAssertEqual(
            controller.callsCompactBottomBarCenterTitle,
            "Start Call".localizeString(id: "calls_empty_start_call", arguments: [])
        )
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.isCallsCompactStartCallButtonEnabled)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.accessibilityElementsHidden)
        XCTAssertTrue(controller.bottomSearchHostView.superview === controller.view)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
    }

    func testMissedFilterHiddenWhenUnfilteredMissedCountIsZero() {
        let owner = "calls-zero-missed-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        addCall(owner: owner, jid: "incoming@example.com", state: .received, outgoing: false)
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()

        controller.reloadCallDatasource()

        XCTAssertEqual(controller.currentCallsCounters?.missed, 0)
        XCTAssertTrue(controller.callsCompactBottomBarFilterButton.isHidden)
    }

    func testMissedFilterVisibleWhenMissedCountIsPositiveEvenIfSearchHasNoRows() {
        let owner = "calls-search-missed-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        addCall(owner: owner, jid: "missed@example.com", state: .missed, outgoing: false)
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.callsSearchQuery = "no matching call"

        controller.reloadCallDatasource()

        XCTAssertTrue(controller.datasource.isEmpty)
        XCTAssertEqual(controller.currentCallsCounters?.missed, 1)
        XCTAssertFalse(controller.callsCompactBottomBarFilterButton.isHidden)
    }

    func testActiveMissedFilterResetsToAllWhenLastMissedCallDisappears() {
        let owner = "calls-normalize-missed-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        addCall(owner: owner, jid: "incoming@example.com", state: .received, outgoing: false)
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.filter.accept(.missed)

        controller.reloadCallDatasource()

        XCTAssertEqual(controller.filter.value, .all)
        XCTAssertEqual(controller.datasource.map(\.jid), ["incoming@example.com"])
        XCTAssertTrue(controller.callsCompactBottomBarFilterButton.isHidden)
    }

    func testNonMissedCallsDoNotKeepMissedFilterVisible() {
        let owner = "calls-non-missed-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        addCall(owner: owner, jid: "incoming@example.com", state: .received, outgoing: false)
        addCall(owner: owner, jid: "outgoing@example.com", state: .made, outgoing: true)
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()

        controller.reloadCallDatasource()

        XCTAssertEqual(controller.currentCallsCounters?.total, 2)
        XCTAssertEqual(controller.currentCallsCounters?.missed, 0)
        XCTAssertTrue(controller.callsCompactBottomBarFilterButton.isHidden)
    }

    func testStartCallActionIsHiddenWhileItHasNoTarget() {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()

        controller.reloadCallDatasource()

        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.callsCompactBottomBarPrimaryButton.isEnabled)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.accessibilityElementsHidden)
        XCTAssertFalse(controller.callsCompactBottomBarPrimaryButton.isAccessibilityElement)
    }

    func testHiddenCallsActionsDoNotMoveSearchFrame() {
        let owner = "calls-fixed-search-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        let callPrimary = addCall(
            owner: owner,
            jid: "missed@example.com",
            state: .missed,
            outgoing: false
        )
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.reloadCallDatasource()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let visibleFilterSearchFrame = controller.bottomSearchHostView.collapsedButton.convert(
            controller.bottomSearchHostView.collapsedButton.bounds,
            to: controller.view
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: callPrimary)?.isDeleted = true
        }

        controller.reloadCallDatasource()
        controller.view.layoutIfNeeded()

        XCTAssertTrue(controller.callsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertEqual(
            controller.bottomSearchHostView.collapsedButton.convert(
                controller.bottomSearchHostView.collapsedButton.bounds,
                to: controller.view
            ),
            visibleFilterSearchFrame
        )
    }

    func testCallsCollapsedSearchPassesTouchesThroughHiddenActionSlots() {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.reloadCallDatasource()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let filterPoint = controller.view.convert(
            CGPoint(
                x: controller.callsCompactBottomBarFilterButton.bounds.midX,
                y: controller.callsCompactBottomBarFilterButton.bounds.midY
            ),
            from: controller.callsCompactBottomBarFilterButton
        )
        let primaryPoint = controller.view.convert(
            CGPoint(
                x: controller.callsCompactBottomBarPrimaryButton.bounds.midX,
                y: controller.callsCompactBottomBarPrimaryButton.bounds.midY
            ),
            from: controller.callsCompactBottomBarPrimaryButton
        )
        let searchButton = controller.bottomSearchHostView.collapsedButton
        let searchPoint = controller.view.convert(
            CGPoint(x: searchButton.bounds.midX, y: searchButton.bounds.midY),
            from: searchButton
        )

        XCTAssertTrue(controller.callsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.view.hitTest(filterPoint, with: nil) === controller.callsCompactBottomBarFilterButton)
        XCTAssertFalse(controller.view.hitTest(primaryPoint, with: nil) === controller.callsCompactBottomBarPrimaryButton)
        XCTAssertTrue(controller.view.hitTest(searchPoint, with: nil) === searchButton)
    }

    func testCallsRegularWidthNavbarAndCategoryControllerRemainUnchanged() {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
        container.loadViewIfNeeded()
        let leftIdentifiers = controller.navigationItem.leftBarButtonItems?.compactMap(\.accessibilityIdentifier)
        let rightIdentifiers = controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier)
        let categoriesController = CallsCategoriesViewController()
        categoriesController.loadViewIfNeeded()
        let categoryKeys = categoriesController.datasource.flatMap { $0 }.map(\.key)

        controller.reloadCallDatasource()

        XCTAssertEqual(controller.navigationItem.leftBarButtonItems?.compactMap(\.accessibilityIdentifier), leftIdentifiers)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier), rightIdentifiers)
        XCTAssertEqual(categoriesController.datasource.flatMap { $0 }.map(\.key), categoryKeys)
        XCTAssertTrue(controller.isCallsCompactBottomBarHidden)
    }

    func testCallsLastRowRemainsAboveBottomSearchAtMaximumOffset() {
        let controller = LastCallsViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.loadViewIfNeeded()
        controller.reloadCallDatasource()
        controller.view.layoutIfNeeded()
        controller.tableView.contentSize = CGSize(width: 393, height: 1_600)
        controller.updateTableInsetsForBottomSearch()
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

    func testCallsUsesGeometryBasedBottomOverlayInsetCoordinator() {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.updateTableInsetsForBottomSearch()

        XCTAssertGreaterThan(controller.bottomOverlayInsetCoordinator.appliedBottomContribution, 0)
        XCTAssertEqual(
            controller.tableView.contentInset.bottom,
            controller.bottomOverlayInsetCoordinator.appliedBottomContribution,
            accuracy: 0.001
        )
    }

    func testCallsCompactBottomFilterReceivesHitWhenSearchHostIsCollapsed() {
        let owner = "calls-filter-hit-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        addCall(owner: owner, jid: "missed@example.com", state: .missed, outgoing: false)
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        controller.reloadCallDatasource()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let button = controller.callsCompactBottomBarFilterButton
        let buttonPoint = controller.view.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button
        )

        XCTAssertTrue(controller.view.hitTest(buttonPoint, with: nil) === button)
    }

    func testCallsCompactBottomFilterTogglesAllAndMissedCalls() {
        let owner = "calls-filter-toggle-\(UUID().uuidString)@example.com"
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        addCall(owner: owner, jid: "missed@example.com", state: .missed, outgoing: false)
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        controller.reloadCallDatasource()

        XCTAssertEqual(controller.filter.value, .all)
        XCTAssertFalse(controller.isCallsCompactMissedFilterActive)

        controller.callsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.filter.value, .missed)
        XCTAssertTrue(controller.isCallsCompactMissedFilterActive)

        controller.callsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.filter.value, .all)
        XCTAssertFalse(controller.isCallsCompactMissedFilterActive)
    }

    func testCallsCompactSearchExpansionHidesActionsOnlyAfterMorphAndRestoresBeforeCollapse() throws {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        controller.bottomSearchHostView.animatorFactory = { _, curve in
            UIViewPropertyAnimator(duration: 10, curve: curve)
        }

        XCTAssertFalse(controller.isCallsCompactBottomBarHidden)

        controller.bottomSearchHostView.collapsedButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(controller.bottomSearchHostView.isExpanded)
        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .expanding)
        XCTAssertFalse(controller.isCallsCompactBottomBarHidden)
        let expansionAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        expansionAnimator.pauseAnimation()
        expansionAnimator.stopAnimation(false)
        expansionAnimator.finishAnimation(at: .end)

        XCTAssertTrue(controller.isCallsCompactBottomBarHidden)

        controller.bottomSearchHostView.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .collapsing)
        XCTAssertFalse(controller.isCallsCompactBottomBarHidden)
        let collapseAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        collapseAnimator.pauseAnimation()
        collapseAnimator.stopAnimation(false)
        collapseAnimator.finishAnimation(at: .end)
    }

    func testCallsTraitChangeHidesCompactBottomBarInRegularWidth() {
        let controller = LastCallsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        parent.loadViewIfNeeded()
        XCTAssertFalse(controller.isCallsCompactBottomBarHidden)

        parent.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: .regular),
            forChild: navigationController
        )
        controller.traitCollectionDidChange(UITraitCollection(horizontalSizeClass: .compact))

        XCTAssertTrue(controller.isCallsCompactBottomBarHidden)
    }

    func testCallsCategoriesRegularNavbarShowsSidebarButtonImmediately() {
        let controller = CallsCategoriesViewController()

        controller.loadViewIfNeeded()
        controller.configureLeadingNavigationItem(forRegularWidth: true, animated: false)

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "calls_sidebar_menu_button")
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

    func testCallsCategoriesNavigationAppearanceUsesUIKitDefaultChrome() {
        let controller = CallsCategoriesViewController()
        _ = UINavigationController(rootViewController: controller)

        controller.loadViewIfNeeded()

        XCTAssertNil(controller.navigationItem.standardAppearance)
        XCTAssertNil(controller.navigationItem.scrollEdgeAppearance)
        XCTAssertNil(controller.navigationItem.compactAppearance)
        if #available(iOS 15.0, *) {
            XCTAssertNil(controller.navigationItem.compactScrollEdgeAppearance)
        }
    }

    func testSharedContinuousSplitGlassEffectUsesNativeGlassWhenAvailable() throws {
        let effect = ContinuousSplitCellBackgroundStyle.makeEffect(isHighlighted: false)

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertFalse(glassEffect.isInteractive)
            XCTAssertEqual(glassEffect.tintColor, XabberGlassStyle.nativeGlassTintColor)
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
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .splitCellNormal), .systemThinMaterial)
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .splitCellHighlighted), .systemMaterial)
    }
}
