//
//  ContactsListAppearanceTests.swift
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
final class ContactsListAppearanceTests: XCTestCase {
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
            inMemoryIdentifier: "ContactsListAppearanceTests-\(name)-\(UUID().uuidString)"
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

    private func addCircle(name: String, owner: String) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let group = RosterGroupStorageItem()
            group.primary = RosterGroupStorageItem.genPrimary(name: name, owner: owner)
            group.owner = owner
            group.name = name
            group.isSystemGroup = false
            realm.add(group, update: .modified)
        }
    }

    private func addRosterItem(
        owner: String,
        jid: String,
        isContact: Bool = true,
        subscription: RosterStorageItem.Subsccribtion = .both,
        ask: RosterStorageItem.Ask = .none,
        groups: [String] = []
    ) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let item = RosterStorageItem()
            item.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
            item.owner = owner
            item.jid = jid
            item.username = jid
            item.isContact = isContact
            item.subscribtion = subscription
            item.ask = ask
            item.groups.append(objectsIn: groups)
            realm.add(item, update: .modified)
        }
    }

    private func addJoinedGroup(
        owner: String,
        jid: String,
        privacy: GroupPrivacy = .publicGroup,
        peerToPeer: Bool = false,
        groups: [String] = []
    ) {
        let realm = try! WRealm.safe()
        let repository = GroupRepository(realm: realm)
        try! repository.setSelfMembership(
            .both,
            memberID: "self-member",
            owner: owner,
            groupJID: jid
        )
        try! repository.applySnapshot(
            GroupSnapshot(
                jid: jid,
                privacy: privacy,
                parentJID: peerToPeer ? "parent@example.com" : nil,
                info: GroupInfo(name: jid)
            ),
            owner: owner,
            groupJID: jid
        )
        try! realm.write {
            let rosterItem = RosterStorageItem()
            rosterItem.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
            rosterItem.owner = owner
            rosterItem.jid = jid
            rosterItem.username = jid
            rosterItem.isContact = false
            rosterItem.subscribtion = .both
            rosterItem.groups.append(objectsIn: groups)
            realm.add(rosterItem, update: .modified)
        }
    }

    private func addIncomingGroupInvite(owner: String, groupJid: String) {
        let realm = try! WRealm.safe()
        try! GroupRepository(realm: realm).storeInvite(
            GroupInviteRecord(
                groupJID: groupJid,
                direction: .incoming,
                target: "inviter@example.com",
                inviter: GroupMember(
                    id: "inviter-member",
                    jid: "inviter@example.com"
                ),
                preview: GroupSnapshot(
                    jid: groupJid,
                    privacy: .publicGroup,
                    info: GroupInfo(name: groupJid)
                )
            ),
            owner: owner
        )
    }

    private func deriveContactsState(
        category: String?,
        filteredAccounts: Set<String> = [],
        filteredGroups: Set<String> = [],
        showOffline: Bool = true,
        isGroup: Bool = false,
        searchQuery: String? = nil
    ) -> ContactsListCoordinator.DerivedState {
        let realm = try! WRealm.safe()
        let state = ContactsFilterState(
            category: category,
            filteredAccounts: filteredAccounts,
            filteredGroups: filteredGroups,
            showOffline: showOffline,
            isGroup: isGroup,
            searchQuery: searchQuery
        )
        return ContactsListCoordinator.deriveState(
            realm: realm,
            state: state,
            datasourceBuilder: { _, _ in [[]] }
        )
    }

    private func registerAccountColor(owner: String, colorKey: String) {
        AccountColorManager.shared.accounts.insert(
            AccountColorManager.ColorForJid(
                jid: owner,
                color: AccountColorManager.shared.colorForKey(colorKey)
            )
        )
    }

    private func makeSolidAvatarImage(color: UIColor = .systemRed, size: CGSize = CGSize(width: 64, height: 64)) -> UIImage {
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

    private final class FilterSpy: ContactsControllerFilterProtocol {
        var offlineVisibilityCalls = 0
        var categoryFilters: [String?] = []
        var accountFilters: [String?] = []
        var groupFilters: [[String]] = []

        func changeOfflineVisibilityState() -> Bool {
            offlineVisibilityCalls += 1
            return false
        }

        func shouldFilterBy(groups: [String]) {
            groupFilters.append(groups)
        }

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
        if let contactsController = viewController as? ContactsViewController {
            contactsController.tableView.applyContinuousSplitInsetGroupedAppearance()
        }
        if let categoryController = viewController as? ContactsCategoryViewController {
            categoryController.tableView.applyContinuousSplitInsetGroupedAppearance()
        }
    }

    func testContactsRootLargeTitleFollowsCommonConfig() {
        assertContactsLargeTitle(useLargeTitle: true, isGroup: false)
        assertContactsLargeTitle(useLargeTitle: false, isGroup: false)
    }

    func testGroupsRootLargeTitleFollowsCommonConfig() {
        assertContactsLargeTitle(useLargeTitle: true, isGroup: true)
        assertContactsLargeTitle(useLargeTitle: false, isGroup: true)
    }

    func testScopedContactSearchFiltersContactRowsAndDropsHeadersAndButtons() {
        let contact = ContactsViewController.Datasource(
            owner: "owner@example.com",
            title: "Alice Contact",
            jid: "alice@example.com",
            subtitle: "alice@example.com",
            groups: ["Friends"],
            conversationType: .regular
        )
        let header = ContactsViewController.Datasource(
            owner: "",
            title: "Contact Requests",
            jid: "",
            subtitle: "",
            groups: [],
            conversationType: .regular,
            isHeader: true
        )
        let button = ContactsViewController.Datasource(
            owner: "",
            title: "Show all",
            jid: "",
            subtitle: "",
            groups: [],
            conversationType: .regular,
            isButton: true
        )

        let results = ContactsListSupport.filteredDatasourceRows(
            [header, button, contact],
            searchQuery: "alice"
        )

        XCTAssertEqual(results, [contact])
    }

    func testScopedGroupSearchMatchesGroupMetadataAndMembers() {
        let group = ContactsViewController.Datasource(
            owner: "owner@example.com",
            title: "Roadmap Group",
            jid: "roadmap@example.com",
            subtitle: "Planning",
            groups: ["Work"],
            conversationType: .group,
            descr: "Product planning",
            members: [
                ContactsViewController.GroupDisplayMember(
                    name: "Juliet",
                    jid: "juliet@example.com",
                    uuid: "member-1"
                )
            ],
            entity: .groupchat
        )
        let otherGroup = ContactsViewController.Datasource(
            owner: "owner@example.com",
            title: "Random Group",
            jid: "random@example.com",
            subtitle: "Other",
            groups: [],
            conversationType: .group,
            entity: .groupchat
        )

        let results = ContactsListSupport.filteredDatasourceRows(
            [group, otherGroup],
            searchQuery: "juliet"
        )

        XCTAssertEqual(results, [group])
    }

    func testContactsCategoriesLargeTitleFollowsCommonConfig() {
        assertCategoryLargeTitle(useLargeTitle: true, isGroup: false)
        assertCategoryLargeTitle(useLargeTitle: false, isGroup: false)
    }

    private func assertContactsLargeTitle(
        useLargeTitle: Bool,
        isGroup: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        CommonConfigManager.shared.config.use_large_title = useLargeTitle
        let controller = ContactsViewController()
        controller.isGroup = isGroup
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

    private func assertCategoryLargeTitle(
        useLargeTitle: Bool,
        isGroup: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        CommonConfigManager.shared.config.use_large_title = useLargeTitle
        let controller = ContactsCategoryViewController()
        controller.isGroup = isGroup
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

    func testContactsListUsesInsetGroupedTransparentSplitAppearanceAndBottomSearchInRegularWidth() {
        let controller = ContactsViewController()
        XCTAssertEqual(controller.searchController.searchBar.searchBarStyle, .default)
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

        XCTAssertFalse(controller.searchController.hidesBottomBarWhenPushed)
        XCTAssertFalse(controller.searchController.definesPresentationContext)
        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.view.backgroundColor, .clear)
        XCTAssertFalse(controller.view.isOpaque)
        XCTAssertNil(controller.navigationItem.searchController)
        XCTAssertTrue(controller.bottomSearchHostView.superview === controller.view)
        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
        XCTAssertTrue(controller.isContactsCompactBottomBarHidden)
        XCTAssertFalse(controller.searchController.hidesBottomBarWhenPushed)
        XCTAssertFalse(controller.searchController.definesPresentationContext)
    }

    func testContactsListUsesStockBackgroundAndBottomSearchInCompactSplitWidth() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertTrue(controller.tableView.backgroundColor?.isEqual(UIColor.systemGroupedBackground) == true)
        XCTAssertTrue(controller.tableView.isOpaque)
        XCTAssertTrue(controller.view.backgroundColor?.isEqual(UIColor.systemBackground) == true)
        XCTAssertTrue(controller.view.isOpaque)
        XCTAssertNil(controller.navigationItem.searchController)
        XCTAssertTrue(controller.bottomSearchHostView.superview === controller.view)
        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        XCTAssertEqual(
            controller.contactsCompactBottomBarCenterTitle,
            "Add Contact".localizeString(id: "contacts_empty_add_contact", arguments: [])
        )
    }

    func testContactsUsesGeometryBasedBottomOverlayInsetCoordinator() {
        let controller = ContactsViewController()
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

    func testContactsConfigureSearchBarInstallsBottomSearchWithoutMutatingAppearance() {
        let controller = ContactsViewController()
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

    func testContactsConfigureBarsReusesNavigationItemsWhenStateIsUnchanged() {
        let controller = ContactsViewController()

        controller.configureBars(animated: false)
        let leftItem = controller.navigationItem.leftBarButtonItem
        let rightItems = controller.navigationItem.rightBarButtonItems

        controller.configureBars(animated: false)

        XCTAssertTrue(controller.navigationItem.leftBarButtonItem === leftItem)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.count, rightItems?.count)
        zip(controller.navigationItem.rightBarButtonItems ?? [], rightItems ?? []).forEach { current, previous in
            XCTAssertTrue(current === previous)
        }
        XCTAssertNil(controller.navigationItem.searchController)
    }

    func testContactsBottomSearchExpandsWithoutShowingLegacyBottomBar() throws {
        let controller = ContactsViewController()
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

    func testContactsCompactBottomSearchExpansionHidesActionBarOnlyAfterMorphAndRestoresBeforeCollapse() throws {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        controller.bottomSearchHostView.animatorFactory = { _, curve in
            UIViewPropertyAnimator(duration: 10, curve: curve)
        }

        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)

        controller.bottomSearchHostView.collapsedButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(controller.bottomSearchHostView.isExpanded)
        XCTAssertFalse(controller.bottomSearchHostView.surfaceView.isHidden)
        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .expanding)
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        let expansionAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        expansionAnimator.pauseAnimation()
        expansionAnimator.stopAnimation(false)
        expansionAnimator.finishAnimation(at: .end)

        XCTAssertTrue(controller.isContactsCompactBottomBarHidden)

        controller.bottomSearchHostView.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.bottomSearchHostView.isExpanded)
        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .collapsing)
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        let collapseAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        collapseAnimator.pauseAnimation()
        collapseAnimator.stopAnimation(false)
        collapseAnimator.finishAnimation(at: .end)

        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
    }

    func testGroupsListUsesSameInsetGroupedTransparentSplitAppearanceInRegularWidth() {
        let controller = ContactsViewController()
        controller.isGroup = true
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

    func testGroupsListUsesStockBackgroundInCompactSplitWidth() {
        let controller = ContactsViewController()
        controller.isGroup = true
        let container = embedInTraitContainer(controller, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.tableView.tableHeaderView)
        XCTAssertNil(controller.tableView.tableFooterView)
        XCTAssertTrue(controller.tableView.backgroundColor?.isEqual(UIColor.systemGroupedBackground) == true)
        XCTAssertTrue(controller.tableView.isOpaque)
        XCTAssertTrue(controller.view.backgroundColor?.isEqual(UIColor.systemBackground) == true)
        XCTAssertTrue(controller.view.isOpaque)
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        XCTAssertEqual(
            controller.contactsCompactBottomBarCenterTitle,
            "Create Group".localizeString(id: "create_group", arguments: [])
        )
    }

    func testContactsCategoryUsesInsetGroupedTransparentSplitAppearanceAndNativeSpacingInRegularWidth() {
        let controller = ContactsCategoryViewController()
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
        XCTAssertFalse(controller.responds(to: #selector(UITableViewDelegate.tableView(_:viewForFooterInSection:))))
    }

    func testContactsCategoryUsesStockBackgroundInCompactSplitWidth() {
        let controller = ContactsCategoryViewController()
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

    func testContactRowsUsePlainSystemBackgroundWithoutGlass() {
        let cell = ContactsViewController.ContactCell(
            style: .default,
            reuseIdentifier: ContactsViewController.ContactCell.cellName
        )

        cell.configure(
            title: "Alice",
            subtitle: "alice@example.com",
            bottomLine: nil,
            groups: ["Friends"],
            jid: "alice@example.com",
            owner: "owner@example.com",
            showAvatar: true,
            avatarUrl: nil,
            entity: .contact,
            status: .online
        )
        cell.applyPlainGroupedSystemBackground()

        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertNil(cell.backgroundConfiguration?.visualEffect)
        XCTAssertEqual(cell.contentView.backgroundColor, .clear)
        XCTAssertNil(cell.configurationUpdateHandler)
        XCTAssertNil(cell.selectedBackgroundView)
        XCTAssertEqual(cell.selectionStyle, .none)
        XCTAssertEqual(cell.layer.borderWidth, 0)
        XCTAssertEqual(cell.layer.shadowOpacity, 0)
        assertNoSelectionOutline(in: cell)

        cell.prepareForReuse()
        cell.applyPlainGroupedSystemBackground()

        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertNil(cell.backgroundConfiguration?.visualEffect)
        assertNoSelectionOutline(in: cell)
    }

    func testContactCellUsesCachedAvatarSynchronously() {
        let avatarURL = "https://example.com/contact-avatar-\(UUID().uuidString).png"
        let cachedImage = makeSolidAvatarImage(color: .systemBlue)
        DefaultAvatarManager.shared.storeImage(for: avatarURL, image: cachedImage)
        let cell = ContactsViewController.ContactCell(
            style: .default,
            reuseIdentifier: ContactsViewController.ContactCell.cellName
        )

        cell.configure(
            title: "Alice",
            subtitle: "alice@example.com",
            bottomLine: nil,
            groups: ["Friends"],
            jid: "alice@example.com",
            owner: "owner@example.com",
            showAvatar: true,
            avatarUrl: avatarURL,
            entity: .contact,
            status: .online
        )

        assertImage(cell.avatarView.image, matches: cachedImage)
    }

    func testDefaultAvatarManagerCachedAvatarDoesNotSendIntermediateNil() {
        let avatarURL = "https://example.com/default-avatar-manager-\(UUID().uuidString).png"
        let cachedImage = makeSolidAvatarImage(color: .systemGreen)
        DefaultAvatarManager.shared.storeImage(for: avatarURL, image: cachedImage)
        let imageReceived = expectation(description: "cached image received")
        var callbacks: [UIImage?] = []

        DefaultAvatarManager.shared.getAvatar(
            url: avatarURL,
            jid: "alice@example.com",
            owner: "owner@example.com",
            size: 64
        ) { image in
            callbacks.append(image)
            if image != nil {
                imageReceived.fulfill()
            }
        }

        wait(for: [imageReceived], timeout: 1.0)

        XCTAssertEqual(callbacks.count, 1)
        assertImage(callbacks.first ?? nil, matches: cachedImage)
    }

    func testContactsCategoryRowsUsePlainSystemBackgroundWithSelectedTint() {
        let owner = "contacts-selected-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "red")
        addEnabledAccount(owner: owner, colorKey: "red", order: 0)
        let selectedController = ContactsCategoryViewController()
        selectedController.loadViewIfNeeded()
        selectedController.filterDidSelect(category: "all")

        XCTAssertTrue(selectedController.tableView.indexPathsForSelectedRows?.isEmpty ?? true)

        let selectedCell = selectedController.tableView(
            selectedController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertTrue(
            selectedCell.backgroundColor?.isEqual(AccountColorManager.shared.palette(for: owner).tint50) == true
        )
        XCTAssertNil(selectedCell.backgroundConfiguration?.visualEffect)
        XCTAssertEqual(selectedCell.contentView.backgroundColor, .clear)
        XCTAssertNotNil(selectedCell.configurationUpdateHandler)
        XCTAssertNil(selectedCell.selectedBackgroundView)
        XCTAssertEqual(selectedCell.selectionStyle, .none)
        XCTAssertEqual(selectedCell.layer.borderWidth, 0)
        XCTAssertEqual(selectedCell.layer.shadowOpacity, 0)
        assertNoSelectionOutline(in: selectedCell)

        let unselectedController = ContactsCategoryViewController()
        unselectedController.loadViewIfNeeded()
        unselectedController.filterDidSelect(category: "requests")
        let unselectedCell = unselectedController.tableView(
            unselectedController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertEqual(unselectedCell.backgroundColor, .systemBackground)
        XCTAssertNil(unselectedCell.backgroundConfiguration?.visualEffect)
        assertNoSelectionOutline(in: unselectedCell)
    }

    func testContactsCategoryIntroHeaderIsInformationalOnly() {
        let controller = ContactsCategoryViewController()
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
        XCTAssertTrue(spy.groupFilters.isEmpty)
        XCTAssertEqual(controller.tableView.indexPathsForSelectedRows ?? [], selectedRowsBeforeHeaderTap)

        XCTAssertTrue(controller.tableView(controller.tableView, shouldHighlightRowAt: categoryIndexPath))
        XCTAssertEqual(controller.tableView(controller.tableView, willSelectRowAt: categoryIndexPath), categoryIndexPath)
        controller.tableView(controller.tableView, didSelectRowAt: categoryIndexPath)
        XCTAssertEqual(spy.categoryFilters, ["all"])
    }

    func testContactsCategoryCircleSelectionKeepsPlainSelectedBackground() {
        let owner = "contacts-circle-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "orange")
        addEnabledAccount(owner: owner, colorKey: "orange", order: 0)
        addCircle(name: "Friends", owner: owner)
        let controller = ContactsCategoryViewController()
        controller.loadViewIfNeeded()
        controller.filterDidSelect(groups: ["Friends"])

        XCTAssertTrue(controller.tableView.indexPathsForSelectedRows?.isEmpty ?? true)

        let circleCell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 3)
        )

        XCTAssertTrue(
            circleCell.backgroundColor?.isEqual(AccountColorManager.shared.palette(for: owner).tint50) == true
        )
        XCTAssertNil(circleCell.backgroundConfiguration?.visualEffect)
        XCTAssertNil(circleCell.selectedBackgroundView)
        XCTAssertEqual(circleCell.selectionStyle, .none)
        assertNoSelectionOutline(in: circleCell)
    }

    func testGroupsCategoryRowsUsePlainSystemBackgroundWithSelectedTint() {
        let owner = "groups-selected-\(UUID().uuidString)@example.com"
        registerAccountColor(owner: owner, colorKey: "blue")
        addEnabledAccount(owner: owner, colorKey: "blue", order: 0)
        let controller = ContactsCategoryViewController()
        controller.isGroup = true
        controller.loadViewIfNeeded()
        controller.filterDidSelect(category: "public")

        XCTAssertTrue(controller.tableView.indexPathsForSelectedRows?.isEmpty ?? true)

        let selectedCell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )

        XCTAssertTrue(
            selectedCell.backgroundColor?.isEqual(AccountColorManager.shared.palette(for: owner).tint50) == true
        )
        XCTAssertNil(selectedCell.backgroundConfiguration?.visualEffect)
        assertNoSelectionOutline(in: selectedCell)
    }

    func testGroupsCategoryIntroHeaderIsInformationalOnly() {
        let controller = ContactsCategoryViewController()
        controller.isGroup = true
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
        XCTAssertTrue(spy.groupFilters.isEmpty)
        XCTAssertEqual(controller.tableView.indexPathsForSelectedRows ?? [], selectedRowsBeforeHeaderTap)

        XCTAssertTrue(controller.tableView(controller.tableView, shouldHighlightRowAt: categoryIndexPath))
        XCTAssertEqual(controller.tableView(controller.tableView, willSelectRowAt: categoryIndexPath), categoryIndexPath)
        controller.tableView(controller.tableView, didSelectRowAt: categoryIndexPath)
        XCTAssertEqual(spy.categoryFilters, ["public"])
    }

    func testContactsOnlineFilterHiddenWhenCurrentUnfilteredScopeHasNoRosterRows() {
        addEnabledAccount(owner: "owner@example.com")

        let derivedState = deriveContactsState(category: "all")

        XCTAssertEqual(derivedState.filterablePresenceRowCount, 0)
    }

    func testContactsRequestOnlyScopeDoesNotCountAsOnlineFilterData() {
        let owner = "owner@example.com"
        addEnabledAccount(owner: owner)
        addRosterItem(
            owner: owner,
            jid: "request@example.com",
            subscription: .none,
            ask: .in
        )
        let derivedState = deriveContactsState(category: "subscribtions")

        XCTAssertTrue(ContactsListSupport.hasAnyContactAreaContent(context: derivedState.context))
        XCTAssertEqual(derivedState.filterablePresenceRowCount, 0)
    }

    func testContactsOnlineFilterVisibleWithOfflineOnlyContact() {
        let owner = "owner@example.com"
        addEnabledAccount(owner: owner)
        addRosterItem(owner: owner, jid: "offline@example.com")

        let derivedState = deriveContactsState(category: "all")

        XCTAssertEqual(derivedState.filterablePresenceRowCount, 1)
    }

    func testContactsOnlineFilterAvailabilityIgnoresSearchQuery() {
        let owner = "owner@example.com"
        addEnabledAccount(owner: owner)
        addRosterItem(owner: owner, jid: "alice@example.com")

        let derivedState = deriveContactsState(category: "all", searchQuery: "missing")

        XCTAssertEqual(derivedState.filterablePresenceRowCount, 1)
    }

    func testContactsOnlineFilterAvailabilityIgnoresCurrentOnlineFilterResult() {
        let owner = "owner@example.com"
        addEnabledAccount(owner: owner)
        addRosterItem(owner: owner, jid: "offline@example.com")

        let derivedState = deriveContactsState(category: "online", showOffline: false)

        XCTAssertEqual(derivedState.filterablePresenceRowCount, 1)
    }

    func testContactsActiveOnlineFilterResetsWhenLastApplicableContactDisappears() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.category = "online"
        controller.showOffline = false

        controller.applyMappedDataset(
            [[]],
            featureHasAnyContent: true,
            hasResolvedSnapshot: true,
            filterablePresenceRowCount: 0,
            forceFullReload: true
        )

        XCTAssertEqual(controller.category, "all")
        XCTAssertTrue(controller.showOffline)
        XCTAssertTrue(controller.contactsCompactBottomBarFilterButton.isHidden)
    }

    func testGroupsOnlineFilterHiddenWhenCurrentUnfilteredScopeHasNoJoinedGroups() {
        addEnabledAccount(owner: "owner@example.com")

        let derivedState = deriveContactsState(category: "public", isGroup: true)

        XCTAssertEqual(derivedState.filterablePresenceRowCount, 0)
    }

    func testGroupsInvitationOnlyScopeDoesNotCountAsOnlineFilterData() {
        let owner = "owner@example.com"
        addEnabledAccount(owner: owner)
        addIncomingGroupInvite(owner: owner, groupJid: "invited@conference.example.com")
        let derivedState = deriveContactsState(category: "invitations", isGroup: true)

        XCTAssertTrue(ContactsListSupport.hasAnyGroupAreaContent(context: derivedState.context))
        XCTAssertEqual(derivedState.filterablePresenceRowCount, 0)
    }

    func testGroupsOnlineFilterVisibleWithOfflineOnlyJoinedGroup() {
        let owner = "owner@example.com"
        addEnabledAccount(owner: owner)
        addJoinedGroup(owner: owner, jid: "room@conference.example.com")

        let derivedState = deriveContactsState(category: "public", isGroup: true)

        XCTAssertEqual(derivedState.filterablePresenceRowCount, 1)
    }

    func testGroupsActiveOnlineFilterResetsWhenLastApplicableGroupDisappears() {
        let controller = ContactsViewController()
        controller.isGroup = true
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        controller.category = "public"
        controller.showOffline = false

        controller.applyMappedDataset(
            [[]],
            featureHasAnyContent: true,
            hasResolvedSnapshot: true,
            filterablePresenceRowCount: 0,
            forceFullReload: true
        )

        XCTAssertEqual(controller.category, "public")
        XCTAssertTrue(controller.showOffline)
        XCTAssertTrue(controller.contactsCompactBottomBarFilterButton.isHidden)
    }

    func testCategoryAccountAndCircleScopeDriveFilterableRowCount() {
        let firstOwner = "first@example.com"
        let secondOwner = "second@example.com"
        addEnabledAccount(owner: firstOwner)
        addEnabledAccount(owner: secondOwner, order: 1)
        addRosterItem(owner: firstOwner, jid: "friend@example.com", groups: ["Friends"])
        addRosterItem(owner: firstOwner, jid: "coworker@example.com", groups: ["Work"])
        addRosterItem(owner: secondOwner, jid: "other@example.com", groups: ["Friends"])

        let scopedState = deriveContactsState(
            category: "all",
            filteredAccounts: [firstOwner],
            filteredGroups: ["Friends"]
        )
        let requestCategoryState = deriveContactsState(
            category: "requests",
            filteredAccounts: [firstOwner],
            filteredGroups: ["Friends"]
        )

        XCTAssertEqual(scopedState.filterablePresenceRowCount, 1)
        XCTAssertEqual(requestCategoryState.filterablePresenceRowCount, 0)
    }

    func testHidingOnlineFilterDoesNotMovePrimaryOrSearchFrames() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.applyMappedDataset(
            [[]],
            featureHasAnyContent: true,
            hasResolvedSnapshot: true,
            filterablePresenceRowCount: 1,
            forceFullReload: true
        )
        controller.view.layoutIfNeeded()
        let primaryFrame = controller.contactsCompactBottomBarPrimaryButton.convert(
            controller.contactsCompactBottomBarPrimaryButton.bounds,
            to: controller.view
        )
        let searchFrame = controller.bottomSearchHostView.collapsedButton.convert(
            controller.bottomSearchHostView.collapsedButton.bounds,
            to: controller.view
        )

        controller.applyMappedDataset(
            [[]],
            featureHasAnyContent: false,
            hasResolvedSnapshot: true,
            filterablePresenceRowCount: 0,
            forceFullReload: true
        )
        controller.view.layoutIfNeeded()

        XCTAssertTrue(controller.contactsCompactBottomBarFilterButton.isHidden)
        XCTAssertEqual(
            controller.contactsCompactBottomBarPrimaryButton.convert(
                controller.contactsCompactBottomBarPrimaryButton.bounds,
                to: controller.view
            ),
            primaryFrame
        )
        XCTAssertEqual(
            controller.bottomSearchHostView.collapsedButton.convert(
                controller.bottomSearchHostView.collapsedButton.bounds,
                to: controller.view
            ),
            searchFrame
        )
    }

    func testRegularWidthNavbarActionsRemainUnchangedWhenOnlineFilterHasNoData() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
        container.loadViewIfNeeded()
        let identifiers = controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier)

        controller.applyMappedDataset(
            [[]],
            featureHasAnyContent: false,
            hasResolvedSnapshot: true,
            filterablePresenceRowCount: 0,
            forceFullReload: true
        )

        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier),
            identifiers
        )
    }

    func testContactsCompactSplitUsesBottomActionsAndClearsNavbarDuplicates() throws {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "contacts_back_to_chats_button")
        XCTAssertTrue(controller.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        XCTAssertEqual(controller.contactsCompactBottomBarFilterButton.accessibilityIdentifier, "contacts_online_filter_button")
        XCTAssertEqual(controller.contactsCompactBottomBarPrimaryButton.accessibilityIdentifier, "contacts_add_contact_bottom_button")
    }

    func testGroupsCompactSplitUsesBottomActionsAndClearsNavbarDuplicates() throws {
        let controller = ContactsViewController()
        controller.isGroup = true
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "groups_back_to_chats_button")
        XCTAssertTrue(controller.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        XCTAssertEqual(controller.contactsCompactBottomBarFilterButton.accessibilityIdentifier, "groups_online_filter_button")
        XCTAssertEqual(controller.contactsCompactBottomBarPrimaryButton.accessibilityIdentifier, "groups_create_group_bottom_button")
    }

    func testContactsCompactBottomFilterReceivesHitWhenSearchHostIsCollapsed() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()
        container.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let button = controller.contactsCompactBottomBarFilterButton
        let buttonPoint = controller.view.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button
        )

        XCTAssertTrue(controller.view.hitTest(buttonPoint, with: nil) === button)
    }

    func testContactsCompactPrimaryFlowBuildsAddContactController() {
        let controller = ContactsViewController()

        let flowController = controller.makeAddContactFlowViewController()

        XCTAssertTrue(flowController is AddNewContactViewController)
    }

    func testGroupsCompactPrimaryFlowBuildsPublicCreateGroupController() throws {
        let controller = ContactsViewController()
        controller.isGroup = true

        let flowController = try XCTUnwrap(
            controller.makeCreatePublicGroupFlowViewController() as? CreateNewGroupViewController
        )

        XCTAssertFalse(flowController.createIncognitoGroup)
    }

    func testContactsCompactBottomFilterTogglesAllAndOnlineContacts() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.category, "all")
        XCTAssertTrue(controller.showOffline)
        XCTAssertFalse(controller.isContactsCompactOnlineFilterActive)

        controller.contactsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.category, "online")
        XCTAssertFalse(controller.showOffline)
        XCTAssertTrue(controller.isContactsCompactOnlineFilterActive)

        controller.contactsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.category, "all")
        XCTAssertTrue(controller.showOffline)
        XCTAssertFalse(controller.isContactsCompactOnlineFilterActive)
    }

    func testGroupsCompactBottomFilterTogglesOnlineWithoutChangingCategory() {
        let controller = ContactsViewController()
        controller.isGroup = true
        let navigationController = UINavigationController(rootViewController: controller)
        let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        container.loadViewIfNeeded()

        XCTAssertEqual(controller.category, "public")
        XCTAssertTrue(controller.showOffline)
        XCTAssertFalse(controller.isContactsCompactOnlineFilterActive)

        controller.contactsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.category, "public")
        XCTAssertFalse(controller.showOffline)
        XCTAssertTrue(controller.isContactsCompactOnlineFilterActive)

        controller.contactsCompactBottomBarFilterButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.category, "public")
        XCTAssertTrue(controller.showOffline)
        XCTAssertFalse(controller.isContactsCompactOnlineFilterActive)
    }

    func testContactsTraitChangeRestoresRegularNavbarAndHidesCompactBottomBar() {
        let controller = ContactsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

        parent.loadViewIfNeeded()
        XCTAssertFalse(controller.isContactsCompactBottomBarHidden)
        XCTAssertTrue(controller.navigationItem.rightBarButtonItems?.isEmpty ?? true)

        parent.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: .regular),
            forChild: navigationController
        )
        controller.traitCollectionDidChange(UITraitCollection(horizontalSizeClass: .compact))

        XCTAssertTrue(controller.isContactsCompactBottomBarHidden)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier), [
            "contacts_filter_menu_button",
            "contacts_add_button"
        ])
    }

    func testContactsCompactTitleSurvivesRepeatedBarConfiguration() {
        let controller = ContactsViewController()

        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.title, "Contacts")

        controller.configureBars(animated: false)

        XCTAssertEqual(controller.title, "Contacts")
    }

    func testGroupsCompactTitleSurvivesRepeatedBarConfiguration() {
        let controller = ContactsViewController()
        controller.isGroup = true

        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.title, "Public groups")

        controller.configureBars(animated: false)

        XCTAssertEqual(controller.title, "Public groups")
    }

    func testContactsAndGroupsCompactTitlesSurviveAccountFilterBarRefresh() {
        let contactsController = ContactsViewController()
        contactsController.loadViewIfNeeded()

        contactsController.shouldFilterBy(account: "owner@example.com")

        XCTAssertEqual(contactsController.title, "Contacts")

        let groupsController = ContactsViewController()
        groupsController.isGroup = true
        groupsController.loadViewIfNeeded()

        groupsController.shouldFilterBy(account: "owner@example.com")

        XCTAssertEqual(groupsController.title, "Public groups")
    }

    func testContactsAndGroupsCompactCategoryTitlesStillUpdate() {
        let contactsController = ContactsViewController()
        contactsController.loadViewIfNeeded()

        contactsController.shouldFilterBy(category: "online")

        XCTAssertEqual(contactsController.title, "Online contacts")

        let groupsController = ContactsViewController()
        groupsController.isGroup = true
        groupsController.loadViewIfNeeded()

        groupsController.shouldFilterBy(category: "private")

        XCTAssertEqual(groupsController.title, "Private groups")
    }

    func testContactsAndGroupsRowsDoNotUseUIKitFocusOutline() {
        let contactsController = ContactsViewController()
        contactsController.loadViewIfNeeded()

        XCTAssertFalse(contactsController.tableView(contactsController.tableView, canFocusRowAt: IndexPath(row: 0, section: 0)))

        let contactsCategoriesController = ContactsCategoryViewController()
        contactsCategoriesController.loadViewIfNeeded()

        XCTAssertFalse(
            contactsCategoriesController.tableView(
                contactsCategoriesController.tableView,
                canFocusRowAt: IndexPath(row: 0, section: 1)
            )
        )

        let groupsCategoriesController = ContactsCategoryViewController()
        groupsCategoriesController.isGroup = true
        groupsCategoriesController.loadViewIfNeeded()

        XCTAssertFalse(
            groupsCategoriesController.tableView(
                groupsCategoriesController.tableView,
                canFocusRowAt: IndexPath(row: 0, section: 1)
            )
        )
    }

    func testContactsAndGroupsCategoryHeadersUseAutomaticHeight() {
        let contactsController = ContactsCategoryViewController()
        contactsController.loadViewIfNeeded()

        XCTAssertEqual(
            contactsController.tableView(contactsController.tableView, heightForRowAt: IndexPath(row: 0, section: 0)),
            UITableView.automaticDimension
        )

        let groupsController = ContactsCategoryViewController()
        groupsController.isGroup = true
        groupsController.loadViewIfNeeded()

        XCTAssertEqual(
            groupsController.tableView(groupsController.tableView, heightForRowAt: IndexPath(row: 0, section: 0)),
            UITableView.automaticDimension
        )
    }

    func testContactsAndGroupsCategoriesRegularNavbarShowsSidebarButtonImmediately() {
        let contactsController = ContactsCategoryViewController()
        contactsController.loadViewIfNeeded()
        contactsController.configureLeadingNavigationItem(forRegularWidth: true, animated: false)

        XCTAssertEqual(contactsController.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "contacts_sidebar_menu_button")

        let groupsController = ContactsCategoryViewController()
        groupsController.isGroup = true
        groupsController.loadViewIfNeeded()
        groupsController.configureLeadingNavigationItem(forRegularWidth: true, animated: false)

        XCTAssertEqual(groupsController.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "groups_sidebar_menu_button")
    }
}
