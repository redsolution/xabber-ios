//
//  LeftMenuSelectionPresentationPolicyTests.swift
//  xabberTests
//
//  Created by Codex on 10.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
import RealmSwift
@testable import xabber

final class LeftMenuSelectionPresentationPolicyTests: XCTestCase {
    private func action(
        isSplitCollapsed: Bool = false,
        splitHorizontalSizeClass: UIUserInterfaceSizeClass = .regular,
        windowHorizontalSizeClass: UIUserInterfaceSizeClass = .regular,
        viewHorizontalSizeClass: UIUserInterfaceSizeClass = .regular
    ) -> LeftMenuSelectionPresentationPolicy.PresentationAction {
        LeftMenuSelectionPresentationPolicy.action(
            isSplitCollapsed: isSplitCollapsed,
            splitHorizontalSizeClass: splitHorizontalSizeClass,
            windowHorizontalSizeClass: windowHorizontalSizeClass,
            viewHorizontalSizeClass: viewHorizontalSizeClass
        )
    }

    func testCollapsedSplitUsesCompactReveal() {
        XCTAssertEqual(
            action(isSplitCollapsed: true),
            .compactRevealSupplementary
        )
    }

    func testCompactSplitTraitUsesCompactReveal() {
        XCTAssertEqual(
            action(splitHorizontalSizeClass: .compact),
            .compactRevealSupplementary
        )
    }

    func testCompactWindowTraitUsesCompactReveal() {
        XCTAssertEqual(
            action(windowHorizontalSizeClass: .compact),
            .compactRevealSupplementary
        )
    }

    func testRegularSplitWithCompactSourceViewTraitUsesRegularRevealAndHidePrimary() {
        XCTAssertEqual(
            action(viewHorizontalSizeClass: .compact),
            .regularRevealSupplementaryAndHidePrimary
        )
    }

    func testRegularTraitsUseRegularRevealAndHidePrimary() {
        XCTAssertEqual(
            action(),
            .regularRevealSupplementaryAndHidePrimary
        )
    }

    func testCompactRevealDoesNotHidePrimary() {
        let action = LeftMenuSelectionPresentationPolicy.PresentationAction.compactRevealSupplementary

        XCTAssertFalse(action.hidesPrimary)
    }

    func testRegularRevealHidesPrimary() {
        let action = LeftMenuSelectionPresentationPolicy.PresentationAction.regularRevealSupplementaryAndHidePrimary

        XCTAssertTrue(action.hidesPrimary)
    }
}

final class LeftMenuSplitPresentationAnimationPolicyTests: XCTestCase {
    func testDestinationPreparationDisablesAnimations() {
        XCTAssertTrue(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: .destinationPreparation)
        )
    }

    func testColumnInstallationDisablesAnimations() {
        XCTAssertTrue(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: .columnInstallation)
        )
    }

    func testCompactRevealUsesNativeAnimations() {
        let phase = LeftMenuSplitPresentationAnimationPolicy.revealPhase(
            for: .compactRevealSupplementary
        )

        XCTAssertFalse(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: phase)
        )
    }

    func testRegularRevealAndHidePrimaryUsesNativeAnimations() {
        let phase = LeftMenuSplitPresentationAnimationPolicy.revealPhase(
            for: .regularRevealSupplementaryAndHidePrimary
        )

        XCTAssertFalse(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: phase)
        )
    }
}

@MainActor
final class SavedMessagesEntryPointTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "SavedMessagesEntryPointTests-\(name)-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        AccountManager.shared.users.removeAll()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testLeftMenuShowsSavedMessagesWhenFavoritesServiceAvailable() {
        let item = LeftMenuSavedMessagesEntryPolicy.menuItem(
            enabledAccountJids: ["owner@example.com"],
            favoritesNodesByOwner: ["owner@example.com": "favorites.example.com"],
            unreadCount: 0
        )

        XCTAssertEqual(item?.key, "saved")
        XCTAssertEqual(item?.title, SavedMessagesChatListPresentationPolicy.title)
        XCTAssertEqual(item?.icon, XMPPFavoritesManagerStorageItem.imageName)
        XCTAssertEqual(item?.subtitle, "0")
    }

    func testLeftMenuHidesSavedMessagesWhenFavoritesServiceUnavailable() {
        XCTAssertNil(LeftMenuSavedMessagesEntryPolicy.menuItem(
            enabledAccountJids: ["owner@example.com"],
            favoritesNodesByOwner: [:],
            unreadCount: 0
        ))
        XCTAssertNil(LeftMenuSavedMessagesEntryPolicy.menuItem(
            enabledAccountJids: ["owner@example.com"],
            favoritesNodesByOwner: ["owner@example.com": ""],
            unreadCount: 0
        ))
    }

    func testSavedMenuTapOpensSavedFilterOrSavedChat() {
        let controller = LeftMenuViewController()

        controller.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(controller.savedMessagesChatsVc?.filter.value, .saved)
        XCTAssertFalse(controller.savedMessagesChatsVc?.shouldShowBottomBar ?? true)
    }

    func testSavedFilterShowsOnlySavedConversationRows() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(owner: "owner@example.com", node: "favorites.example.com")
        try seedLastChat(jid: "favorites.example.com", owner: "owner@example.com", conversationType: .saved)
        try seedLastChat(jid: "romeo@example.com", owner: "owner@example.com", conversationType: .regular)

        let controller = LastChatsViewController()
        controller.enabledAccounts.accept(["owner@example.com"])
        controller.updateDatasource(.saved)

        let rows = try XCTUnwrap(controller.chatsObserver?.toArray())
        XCTAssertEqual(rows.map(\.jid), ["favorites.example.com"])
        XCTAssertTrue(rows.allSatisfy { $0.conversationType == .saved })
    }

    func testSavedRowUsesBookmarkIconAndSavedTitle() {
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.title, "Saved messages")
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.avatarIconName, XMPPFavoritesManagerStorageItem.imageName)
    }

    func testSavedRowShowsAccountSubtitleInMultiAccountMode() {
        XCTAssertEqual(
            SavedMessagesChatListPresentationPolicy.previewText(
                lastMessageText: nil,
                owner: "owner@example.com",
                enabledAccountCount: 2
            ),
            "owner@example.com"
        )
    }

    func testSavedRowDoesNotExposePresenceOrBlockActions() {
        let item = makeSavedDatasource()

        XCTAssertFalse(LastChatsViewController.canShowCallAction(for: item))
        XCTAssertFalse(LastChatsViewController.canShowBlockAction(for: item))
        XCTAssertNil(SavedMessagesChatListPresentationPolicy.entity)
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.status, .offline)
    }

    private func seedAccount(_ jid: String) throws {
        let realm = try WRealm.safe()
        let account = AccountStorageItem()
        account.jid = jid
        account.username = jid
        account.enabled = true

        try realm.write {
            realm.add(account, update: .modified)
        }
    }

    private func seedFavoritesService(owner: String, node: String) throws {
        let realm = try WRealm.safe()
        let item = XMPPFavoritesManagerStorageItem()
        item.owner = owner
        item.node = node

        try realm.write {
            realm.add(item, update: .modified)
        }
    }

    private func seedLastChat(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.owner = owner
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.messageDate = Date(timeIntervalSince1970: conversationType == .saved ? 2 : 1)

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func makeSavedDatasource() -> LastChatsViewController.Datasource {
        LastChatsViewController.Datasource(
            jid: "favorites.example.com",
            owner: "owner@example.com",
            username: SavedMessagesChatListPresentationPolicy.title,
            attributedUsername: nil,
            message: "Save messages here",
            date: nil,
            state: nil,
            isMute: false,
            isSynced: true,
            status: SavedMessagesChatListPresentationPolicy.status,
            entity: SavedMessagesChatListPresentationPolicy.entity,
            conversationType: .saved,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: false,
            color: .clear,
            isDraft: false,
            hasAttachment: false,
            userNickname: nil,
            isSystemMessage: true,
            isPinned: false,
            subRequest: false,
            isEncrypted: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            updateTS: 0,
            isVerificationActionRequired: false,
            specialMessageKind: .none,
            avatars: []
        )
    }
}

final class LeftMenuSplitDestinationPreparerTests: XCTestCase {
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

    private final class RecordingNavigationController: UINavigationController {
        private(set) var loadViewCallCount = 0
        private(set) var layoutSubviewsCallCount = 0

        override func loadView() {
            loadViewCallCount += 1
            super.loadView()
        }

        override func viewDidLayoutSubviews() {
            layoutSubviewsCallCount += 1
            super.viewDidLayoutSubviews()
        }

        func resetRecording() {
            loadViewCallCount = 0
            layoutSubviewsCallCount = 0
        }
    }

    private var retainedTraitWindows: [UIWindow] = []

    override func tearDown() {
        retainedTraitWindows.forEach { $0.isHidden = true }
        retainedTraitWindows.removeAll()
        super.tearDown()
    }

    func testTargetBoundsUsesExistingColumnBoundsBeforeFallbacks() {
        let existingColumnBounds = CGRect(x: 0, y: 0, width: 320, height: 640)
        let splitBounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let presenterBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            existingColumnBounds: existingColumnBounds,
            splitBounds: splitBounds,
            presenterBounds: presenterBounds
        )

        XCTAssertEqual(targetBounds, existingColumnBounds)
    }

    func testTargetBoundsFallsBackToSplitBoundsWhenExistingColumnIsZero() {
        let splitBounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let presenterBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            existingColumnBounds: .zero,
            splitBounds: splitBounds,
            presenterBounds: presenterBounds
        )

        XCTAssertEqual(targetBounds, splitBounds)
    }

    func testTargetBoundsFallsBackToPresenterBoundsWhenSplitAndColumnAreZero() {
        let presenterBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            existingColumnBounds: .zero,
            splitBounds: .zero,
            presenterBounds: presenterBounds
        )

        XCTAssertEqual(targetBounds, presenterBounds)
    }

    func testPrepareSetsNonZeroBoundsAndRunsLayoutBeforePresentation() {
        let viewController = LayoutRecordingViewController()
        let targetBounds = CGRect(x: 0, y: 0, width: 320, height: 640)

        LeftMenuSplitDestinationPreparer.prepare(viewController, targetBounds: targetBounds)

        XCTAssertEqual(viewController.view.bounds.size, targetBounds.size)
        XCTAssertGreaterThan(viewController.layoutPassCount, 0)
    }

    func testPrepareNavigationControllerAlsoPreparesRootController() {
        let rootViewController = LayoutRecordingViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        LeftMenuSplitDestinationPreparer.prepare(navigationController, targetBounds: targetBounds)

        XCTAssertEqual(navigationController.view.bounds.size, targetBounds.size)
        XCTAssertTrue(rootViewController.isViewLoaded)
        XCTAssertFalse(rootViewController.view.bounds.isEmpty)
        XCTAssertGreaterThan(rootViewController.layoutPassCount, 0)
    }

    func testPrepareDefersDetachedLayoutForSearchHostNavigationController() {
        searchHostNavigationControllers().forEach { navigationController in
            guard let navigationController = navigationController as? RecordingNavigationController else {
                XCTFail("Expected recording navigation controller")
                return
            }
            guard let rootViewController = navigationController.topViewController else {
                XCTFail("Expected search host root controller")
                return
            }
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)
            let initialNavigationBounds = navigationController.viewIfLoaded?.bounds
            let initialRootLoaded = rootViewController.isViewLoaded
            navigationController.resetRecording()

            LeftMenuSplitDestinationPreparer.prepare(navigationController, targetBounds: targetBounds)

            XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: navigationController))
            XCTAssertEqual(navigationController.loadViewCallCount, 0)
            XCTAssertEqual(navigationController.layoutSubviewsCallCount, 0)
            XCTAssertEqual(navigationController.viewIfLoaded?.bounds, initialNavigationBounds)
            XCTAssertEqual(rootViewController.isViewLoaded, initialRootLoaded)
            XCTAssertNil(rootViewController.navigationItem.searchController)
        }
    }

    func testPrepareDefersDetachedLayoutForDirectSearchHostController() {
        directSearchHostControllers().forEach { name, viewController in
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            XCTAssertTrue(
                SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: viewController),
                name
            )
            XCTAssertFalse(viewController.isViewLoaded, name)
            XCTAssertNil(viewController.navigationItem.searchController, name)

            LeftMenuSplitDestinationPreparer.prepare(viewController, targetBounds: targetBounds)

            XCTAssertFalse(viewController.isViewLoaded, name)
            XCTAssertNil(viewController.navigationItem.searchController, name)
        }
    }

    func testPrepareAttachedLoadsSearchHostNavigationControllerAfterSplitInstallation() {
        searchHostNavigationControllers().forEach { navigationController in
            guard let rootViewController = navigationController.topViewController else {
                XCTFail("Expected search host root controller")
                return
            }
            let splitViewController = UISplitViewController(style: .tripleColumn)
            splitViewController.setViewController(navigationController, for: .supplementary)
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            LeftMenuSplitDestinationPreparer.prepareAttached(navigationController, targetBounds: targetBounds)

            XCTAssertTrue(navigationController.isViewLoaded)
            XCTAssertTrue(rootViewController.isViewLoaded)
            XCTAssertEqual(navigationController.view.bounds.size, targetBounds.size)
            XCTAssertFalse(rootViewController.view.bounds.isEmpty)
            XCTAssertNil(rootViewController.navigationItem.searchController)
        }
    }

    func testPrepareAttachedLoadsDirectSearchHostController() {
        directSearchHostControllers().forEach { name, viewController in
            let splitViewController = UISplitViewController(style: .tripleColumn)
            let parent = embedInTraitContainer(splitViewController, horizontalSizeClass: .regular)
            parent.loadViewIfNeeded()
            splitViewController.setViewController(viewController, for: .secondary)
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            LeftMenuSplitDestinationPreparer.prepareAttached(viewController, targetBounds: targetBounds)

            XCTAssertTrue(viewController.isViewLoaded, name)
            XCTAssertEqual(viewController.view.bounds.size, targetBounds.size, name)
            XCTAssertNil(viewController.navigationItem.searchController, name)
        }
    }

    func testTransparentSplitAppearanceKeepsNonSearchNavigationStackOnTransparentSplitPath() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: EmptyChatViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
        parent.loadViewIfNeeded()

        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        XCTAssertEqual(navigationController.view.backgroundColor, .clear)
        XCTAssertFalse(navigationController.view.isOpaque)
    }

    func testPrepareBeginsFirstPresentationQuietModeForSupportedController() {
        let viewController = QuietPresentationViewController()
        let targetBounds = CGRect(x: 0, y: 0, width: 320, height: 640)

        LeftMenuSplitDestinationPreparer.prepare(viewController, targetBounds: targetBounds)

        XCTAssertTrue(viewController.isLeftMenuFirstPresentationQuietModeActive)
    }

    func testPrepareNavigationControllerBeginsFirstPresentationQuietModeForRootController() {
        let rootViewController = QuietPresentationViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        LeftMenuSplitDestinationPreparer.prepare(navigationController, targetBounds: targetBounds)

        XCTAssertTrue(rootViewController.isLeftMenuFirstPresentationQuietModeActive)
    }

    func testSearchSectionRootsRequireNativeDefaultNavigationContainers() {
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: ChatViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: LastChatsViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: ContactsViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: ContactsCategoryViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: NotificationsListViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: NotificationsCategoriesViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: LastCallsViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: CallsCategoriesViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: SettingsViewController()))
    }

    func testSearchSectionNavigationContainersRequireDeferredAttachedLayout() {
        searchHostNavigationControllers().forEach { navigationController in
            XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: navigationController))
        }

        XCTAssertFalse(
            SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(
                for: UINavigationController(rootViewController: UIViewController())
            )
        )
    }

    func testSearchSectionRootsRequireDeferredAttachedLayout() {
        directSearchHostControllers().forEach { name, viewController in
            XCTAssertTrue(
                SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: viewController),
                name
            )
        }

        XCTAssertFalse(
            SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: UIViewController())
        )
        XCTAssertFalse(
            SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: EmptyChatViewController())
        )
    }

    func testSearchSectionNavigationContainersDoNotMutateAppearanceWhenSplitTraitsAreUnresolved() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        [
            UINavigationController(rootViewController: ChatViewController()),
            UINavigationController(rootViewController: LastChatsViewController()),
            UINavigationController(rootViewController: ContactsViewController()),
            UINavigationController(rootViewController: NotificationsListViewController()),
            UINavigationController(rootViewController: LastCallsViewController())
        ].forEach { navigationController in
            installStaleTransparentNavigationAppearance(on: navigationController)
            let standardAppearance = navigationController.navigationBar.standardAppearance
            let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
            let compactAppearance = navigationController.navigationBar.compactAppearance
            let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance

            SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

            XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
            XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
            XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        }
    }

    func testCompactSplitNavigationContainersKeepNavbarAppearanceUntouched() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: UIViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        installStaleTransparentNavigationAppearance(on: navigationController)
        let standardAppearance = navigationController.navigationBar.standardAppearance
        let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
        let compactAppearance = navigationController.navigationBar.compactAppearance
        let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        assertCompactNavigationContainerBackground(navigationController)
        XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
        XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
    }

    private func installStaleTransparentNavigationAppearance(on navigationController: UINavigationController) {
        let staleAppearance = UINavigationBarAppearance()
        staleAppearance.configureWithTransparentBackground()
        staleAppearance.shadowColor = .magenta
        navigationController.navigationBar.isTranslucent = true
        navigationController.navigationBar.standardAppearance = staleAppearance
        navigationController.navigationBar.scrollEdgeAppearance = staleAppearance
        navigationController.navigationBar.compactAppearance = staleAppearance
        navigationController.navigationBar.compactScrollEdgeAppearance = staleAppearance
        navigationController.topViewController?.navigationItem.standardAppearance = staleAppearance
        navigationController.topViewController?.navigationItem.scrollEdgeAppearance = staleAppearance
        navigationController.topViewController?.navigationItem.compactAppearance = staleAppearance
        if #available(iOS 15.0, *) {
            navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance = staleAppearance
        }
    }

    private func assertCompactNavigationContainerBackground(
        _ navigationController: UINavigationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(navigationController.view.backgroundColor, .systemBackground, file: file, line: line)
        XCTAssertTrue(navigationController.view.isOpaque, file: file, line: line)
    }

    func testCompactSplitNavigationContainersDoNotApplyTransparentSplitAppearance() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: UIViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        navigationController.navigationBar.isTranslucent = false

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        XCTAssertFalse(navigationController.navigationBar.isTranslucent)
        XCTAssertEqual(navigationController.view.backgroundColor, .systemBackground)
        XCTAssertTrue(navigationController.view.isOpaque)
    }

    func testRegularSplitNonSearchNavigationContainersCanApplyTransparentSplitAppearance() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: UIViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        XCTAssertNotNil(navigationController.navigationBar.standardAppearance)
        XCTAssertNotNil(navigationController.navigationBar.scrollEdgeAppearance)
        XCTAssertNotNil(navigationController.navigationBar.compactAppearance)
    }

    func testRegularSplitSearchNavigationContainersKeepExistingNavigationChromeUntouched() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        [
            UINavigationController(rootViewController: ChatViewController()),
            UINavigationController(rootViewController: LastChatsViewController()),
            UINavigationController(rootViewController: ContactsViewController()),
            UINavigationController(rootViewController: LastCallsViewController())
        ].forEach { navigationController in
            let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
            installStaleTransparentNavigationAppearance(on: navigationController)
            let standardAppearance = navigationController.navigationBar.standardAppearance
            let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
            let compactAppearance = navigationController.navigationBar.compactAppearance
            let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance
            let rootStandardAppearance = navigationController.topViewController?.navigationItem.standardAppearance
            let rootScrollEdgeAppearance = navigationController.topViewController?.navigationItem.scrollEdgeAppearance
            let rootCompactAppearance = navigationController.topViewController?.navigationItem.compactAppearance
            let rootCompactScrollEdgeAppearance: UINavigationBarAppearance?
            if #available(iOS 15.0, *) {
                rootCompactScrollEdgeAppearance = navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance
            } else {
                rootCompactScrollEdgeAppearance = nil
            }

            parent.loadViewIfNeeded()
            SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

            XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
            XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
            XCTAssertTrue(navigationController.topViewController?.navigationItem.standardAppearance === rootStandardAppearance)
            XCTAssertTrue(navigationController.topViewController?.navigationItem.scrollEdgeAppearance === rootScrollEdgeAppearance)
            XCTAssertTrue(navigationController.topViewController?.navigationItem.compactAppearance === rootCompactAppearance)
            if #available(iOS 15.0, *) {
                XCTAssertTrue(
                    navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance === rootCompactScrollEdgeAppearance
                )
            }
            XCTAssertEqual(navigationController.view.backgroundColor, .clear)
            XCTAssertFalse(navigationController.view.isOpaque)
        }
    }

    func testBackgroundRootContainerDoesNotResetSearchHostNavigationChromeInRegularSplit() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: LastChatsViewController())
        installStaleTransparentNavigationAppearance(on: navigationController)
        let standardAppearance = navigationController.navigationBar.standardAppearance
        let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
        let compactAppearance = navigationController.navigationBar.compactAppearance
        let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance
        let rootStandardAppearance = navigationController.topViewController?.navigationItem.standardAppearance
        let rootScrollEdgeAppearance = navigationController.topViewController?.navigationItem.scrollEdgeAppearance
        let rootCompactAppearance = navigationController.topViewController?.navigationItem.compactAppearance
        let rootCompactScrollEdgeAppearance: UINavigationBarAppearance?
        if #available(iOS 15.0, *) {
            rootCompactScrollEdgeAppearance = navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance
        } else {
            rootCompactScrollEdgeAppearance = nil
        }
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.setViewController(navigationController, for: .supplementary)
        let container = BackgroundRootContainerViewController(contentViewController: splitViewController)
        let parent = embedInTraitContainer(container, horizontalSizeClass: .regular)

        parent.loadViewIfNeeded()
        container.view.setNeedsLayout()
        container.view.layoutIfNeeded()
        parent.view.layoutIfNeeded()

        XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
        XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
        XCTAssertTrue(navigationController.topViewController?.navigationItem.standardAppearance === rootStandardAppearance)
        XCTAssertTrue(navigationController.topViewController?.navigationItem.scrollEdgeAppearance === rootScrollEdgeAppearance)
        XCTAssertTrue(navigationController.topViewController?.navigationItem.compactAppearance === rootCompactAppearance)
        if #available(iOS 15.0, *) {
            XCTAssertTrue(
                navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance === rootCompactScrollEdgeAppearance
            )
        }
    }

    func testRegularSplitNonSearchNavigationContainersKeepTransparentSharedBackdropAppearance() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: EmptyChatViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        XCTAssertEqual(navigationController.view.backgroundColor, .clear)
        XCTAssertFalse(navigationController.view.isOpaque)
    }

    func testNonSearchSectionRootsCanUseExistingNavigationContainerChrome() {
        XCTAssertFalse(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: UIViewController()))
        XCTAssertFalse(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: EmptyChatViewController()))
    }

    @discardableResult
    private func embedInTraitContainer(
        _ child: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> UIViewController {
        let parent = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        parent.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: horizontalSizeClass),
            forChild: child
        )
        attachToTraitWindow(parent, horizontalSizeClass: horizontalSizeClass)
        return parent
    }

    private func searchHostNavigationControllers() -> [UINavigationController] {
        let lastChats = LastChatsViewController()
        lastChats.configureSearchBar()

        let contacts = ContactsViewController()
        contacts.configureSearchBar()

        let calls = LastCallsViewController()
        calls.configureSearchBar()

        return [
            RecordingNavigationController(rootViewController: lastChats),
            RecordingNavigationController(rootViewController: contacts),
            RecordingNavigationController(rootViewController: NotificationsListViewController()),
            RecordingNavigationController(rootViewController: calls)
        ]
    }

    private func directSearchHostControllers() -> [(String, UIViewController)] {
        [
            ("Last Chats", LastChatsViewController()),
            ("Contacts", ContactsViewController()),
            ("Contact Categories", ContactsCategoryViewController()),
            ("Notifications", NotificationsListViewController()),
            ("Notification Categories", NotificationsCategoriesViewController()),
            ("Calls", LastCallsViewController()),
            ("Call Categories", CallsCategoriesViewController())
        ]
    }

    private func searchController(for viewController: UIViewController) -> UISearchController? {
        switch viewController {
        case let viewController as LastChatsViewController:
            return viewController.searchController
        case let viewController as ContactsViewController:
            return viewController.searchController
        case let viewController as LastCallsViewController:
            return viewController.searchController
        default:
            return nil
        }
    }

    private func attachToTraitWindow(
        _ viewController: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) {
        let window = TraitWindow(horizontalSizeClass: horizontalSizeClass)
        retainedTraitWindows.append(window)
        window.rootViewController = viewController
        window.frame = UIScreen.main.bounds
        window.isHidden = false
        window.layoutIfNeeded()
    }

}

final class LeftMenuFirstPresentationPolicyTests: XCTestCase {
    func testQuietModeDisablesRequestedTableAnimations() {
        XCTAssertEqual(
            LeftMenuFirstPresentationPolicy.rowAnimation(
                requested: .automatic,
                isQuietModeActive: true
            ),
            .none
        )
        XCTAssertFalse(
            LeftMenuFirstPresentationPolicy.shouldAnimate(
                requested: true,
                isQuietModeActive: true
            )
        )
    }

    func testNormalModePreservesRequestedTableAnimations() {
        XCTAssertEqual(
            LeftMenuFirstPresentationPolicy.rowAnimation(
                requested: .automatic,
                isQuietModeActive: false
            ),
            .automatic
        )
        XCTAssertTrue(
            LeftMenuFirstPresentationPolicy.shouldAnimate(
                requested: true,
                isQuietModeActive: false
            )
        )
    }

    func testQuietModeEndsAfterFirstAppearanceWindow() {
        let viewController = QuietPresentationViewController()
        let quietModeEnded = expectation(description: "quiet mode ended")

        viewController.beginLeftMenuFirstPresentationQuietMode()
        XCTAssertTrue(viewController.isLeftMenuFirstPresentationQuietModeActive)

        viewController.completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame()

        DispatchQueue.main.async {
            DispatchQueue.main.async {
                XCTAssertFalse(viewController.isLeftMenuFirstPresentationQuietModeActive)
                quietModeEnded.fulfill()
            }
        }

        wait(for: [quietModeEnded], timeout: 1.0)
    }
}

private final class LayoutRecordingViewController: UIViewController {
    private(set) var layoutPassCount = 0

    override func loadView() {
        view = UIView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPassCount += 1
    }
}

private final class QuietPresentationViewController: UIViewController, LeftMenuFirstPresentationQuieting {}
