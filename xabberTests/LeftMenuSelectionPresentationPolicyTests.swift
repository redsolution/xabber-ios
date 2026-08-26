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
import XMPPFramework
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

@MainActor
final class LeftMenuSplitContainmentTests: XCTestCase {
    func testColumnInstallationKeepsPrimaryAndUsesSupplementaryNavigationContainer() throws {
        let splitViewController = UISplitViewController(style: .tripleColumn)
        let primary = UIViewController()
        let supplementaryRoot = UIViewController()
        let supplementaryNavigation = UINavigationController(rootViewController: supplementaryRoot)
        let secondary = UIViewController()

        LeftMenuSplitColumnInstaller.install(
            primary: primary,
            supplementaryNavigationController: supplementaryNavigation,
            secondary: secondary,
            in: splitViewController
        )

        XCTAssertIdentical(splitViewController.viewController(for: .primary), primary)
        let installedSupplementary = try XCTUnwrap(
            splitViewController.viewController(for: .supplementary) as? UINavigationController
        )
        XCTAssertIdentical(installedSupplementary, supplementaryNavigation)
        XCTAssertIdentical(installedSupplementary.viewControllers.first, supplementaryRoot)
        XCTAssertIdentical(splitViewController.viewController(for: .secondary), secondary)
    }

    func testColumnInstallationPreservesSecondaryNavigationContainerWhenProvided() throws {
        let splitViewController = UISplitViewController(style: .tripleColumn)
        let primary = UIViewController()
        let supplementaryNavigation = UINavigationController(rootViewController: UIViewController())
        let secondaryNavigation = UINavigationController(rootViewController: UIViewController())

        LeftMenuSplitColumnInstaller.install(
            primary: primary,
            supplementaryNavigationController: supplementaryNavigation,
            secondary: secondaryNavigation,
            in: splitViewController
        )

        XCTAssertIdentical(splitViewController.viewController(for: .secondary), secondaryNavigation)
    }

    func testCompactRevealHidesPrimaryFromAccessibilityButKeepsDestinationColumnsAccessible() {
        let splitViewController = makeInstalledSplitViewController()

        LeftMenuSplitColumnInstaller.applyAccessibilityContainment(
            for: .compactRevealSupplementary,
            in: splitViewController
        )

        XCTAssertTrue(splitViewController.viewController(for: .primary)?.view.accessibilityElementsHidden ?? false)
        XCTAssertFalse(splitViewController.viewController(for: .supplementary)?.view.accessibilityElementsHidden ?? true)
        XCTAssertFalse(splitViewController.viewController(for: .secondary)?.view.accessibilityElementsHidden ?? true)
    }

    func testRegularRevealHidesPrimaryFromAccessibilityButKeepsDestinationColumnsAccessible() {
        let splitViewController = makeInstalledSplitViewController()

        LeftMenuSplitColumnInstaller.applyAccessibilityContainment(
            for: .regularRevealSupplementaryAndHidePrimary,
            in: splitViewController
        )

        XCTAssertTrue(splitViewController.viewController(for: .primary)?.view.accessibilityElementsHidden ?? false)
        XCTAssertFalse(splitViewController.viewController(for: .supplementary)?.view.accessibilityElementsHidden ?? true)
        XCTAssertFalse(splitViewController.viewController(for: .secondary)?.view.accessibilityElementsHidden ?? true)
    }

    func testPrimaryAppearanceRestoresLeftMenuAccessibility() {
        let primary = UIViewController()
        primary.view.accessibilityElementsHidden = true

        LeftMenuSplitColumnInstaller.restorePrimaryAccessibility(for: primary)

        XCTAssertFalse(primary.view.accessibilityElementsHidden)
    }

    private func makeInstalledSplitViewController() -> UISplitViewController {
        let splitViewController = UISplitViewController(style: .tripleColumn)
        LeftMenuSplitColumnInstaller.install(
            primary: UIViewController(),
            supplementaryNavigationController: UINavigationController(rootViewController: UIViewController()),
            secondary: UIViewController(),
            in: splitViewController
        )
        return splitViewController
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
    private var retainedTraitWindows: [UIWindow] = []

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
        let windows = retainedTraitWindows
        UIView.performWithoutAnimation {
            windows.forEach { $0.isHidden = true }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        windows.forEach { $0.rootViewController = nil }
        retainedTraitWindows.removeAll()
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
        XCTAssertEqual(item?.icon, SavedMessagesChatListPresentationPolicy.leftMenuIconName)
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

    func testSavedMenuTapRunsEvenWhenSavedAlreadySelected() {
        let controller = LeftMenuViewController()
        controller.previousSelectedKey = "saved"

        controller.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(controller.savedMessagesChatsVc?.filter.value, .saved)
        XCTAssertFalse(controller.savedMessagesChatsVc?.shouldShowBottomBar ?? true)
    }

    func testSavedMenuCellExposesActionAccessibilityTarget() {
        let cell = MenuItemTableCell(style: .default, reuseIdentifier: MenuItemTableCell.cellName)

        cell.configure(
            title: SavedMessagesChatListPresentationPolicy.title,
            badge: "0",
            icon: XMPPFavoritesManagerStorageItem.imageName,
            isImportant: true,
            accessibilityIdentifier: "left_menu_saved_row"
        )

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertEqual(cell.accessibilityIdentifier, "left_menu_saved_row")
        XCTAssertEqual(cell.accessibilityLabel, SavedMessagesChatListPresentationPolicy.title)
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
    }

    func testActualSingleSavedMenuRowTapUsesAtomicExpandedSplitDetailReplacement() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(owner: "owner@example.com", node: "favorites.example.com")
        try seedLastChat(jid: "favorites.example.com", owner: "owner@example.com", conversationType: .saved)

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }

        let savedRow = try XCTUnwrap(
            host.leftMenu.datasource.first?.firstIndex { $0.key == "saved" }
        )

        host.leftMenu.tableView(
            host.leftMenu.tableView,
            didSelectRowAt: IndexPath(row: savedRow, section: 0)
        )

        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            host.previousSupplementary,
            "The list column must not be installed while Saved chat preparation is pending"
        )
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .secondary),
            host.previousSecondary,
            "The existing detail must remain installed while preparation is pending"
        )
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)

        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            let supplementary = host.splitViewController.viewController(
                for: .supplementary
            ) as? UINavigationController
            let secondary = host.splitViewController.viewController(
                for: .secondary
            ) as? UINavigationController
            return supplementary?.topViewController === host.chatsController &&
                secondary?.topViewController === host.preparedChat &&
                host.chatsController.currentChatVC === host.preparedChat
        })

        XCTAssertEqual(host.leftMenu.previousSelectedKey, "saved")
        let navigationController = try XCTUnwrap(
            host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController
        )
        XCTAssertIdentical(navigationController.topViewController, host.chatsController)
        XCTAssertEqual(host.chatsController.filter.value, .chats)
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
        XCTAssertEqual(host.preparedChat.owner, "owner@example.com")
        XCTAssertEqual(host.preparedChat.jid, "favorites.example.com")
        XCTAssertEqual(host.preparedChat.conversationType, .saved)
    }

    func testStandardExpandedOpenAfterSavedKeepsCurrentDetailAlignedDuringReplacement() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let originalChat = ChatViewController()
        originalChat.owner = "owner@example.com"
        originalChat.jid = "original@example.com"
        originalChat.conversationType = .regular
        host.previousSecondary.setViewControllers(
            [originalChat],
            animated: false
        )
        host.chatsController.currentChatVC = originalChat
        host.chatsController.playerViewToolbar.delegate = originalChat

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === host.preparedChat
        })
        XCTAssertTrue(waitUntilExpandedNavigationIsStable(host))

        let replacementChat = HeldSavedChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            replacementChat
        }
        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "replacement@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))

        XCTAssertTrue(host.chatsController.currentChatVC === host.preparedChat)
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController ===
                    host.preparedChat
        )
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .preparing
        )

        replacementChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === replacementChat &&
                (host.splitViewController.viewController(for: .secondary)
                    as? UINavigationController)?.topViewController ===
                        replacementChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testSettingsModalKeepsPresentedExpandedSavedOwnershipAligned() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let originalChat = ChatViewController()
        originalChat.owner = "owner@example.com"
        originalChat.jid = "original@example.com"
        originalChat.conversationType = .regular
        host.previousSecondary.setViewControllers(
            [originalChat],
            animated: false
        )
        host.chatsController.currentChatVC = originalChat
        host.chatsController.playerViewToolbar.delegate = originalChat

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === host.preparedChat
        })
        let savedToken = try XCTUnwrap(
            host.chatsController.expandedSplitChatNavigationTransaction?.token
        )
        let settingsIndexPath = try XCTUnwrap(
            host.leftMenu.datasource.enumerated().compactMap { section, rows in
                rows.firstIndex(where: { $0.key == "settings" }).map {
                    IndexPath(row: $0, section: section)
                }
            }.first
        )

        host.leftMenu.tableView(
            host.leftMenu.tableView,
            didSelectRowAt: settingsIndexPath
        )

        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.token,
            savedToken
        )
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .presented
        )
        XCTAssertIdentical(
            host.chatsController.currentChatVC,
            host.preparedChat
        )
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController ===
                    host.preparedChat
        )
    }

    func testStandardExpandedOpenWaitsForPendingSavedNativeTerminalBeforeRetryingReplacement() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let originalChat = ChatViewController()
        originalChat.owner = "owner@example.com"
        originalChat.jid = "original@example.com"
        originalChat.conversationType = .regular
        host.previousSecondary.setViewControllers(
            [originalChat],
            animated: false
        )
        host.chatsController.currentChatVC = originalChat
        host.chatsController.playerViewToolbar.delegate = originalChat

        let pendingSavedChat =
            HeldSavedNativeTerminalChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            pendingSavedChat
        }
        host.leftMenu.didSelectRootScreenBy(key: "saved")
        pendingSavedChat.releasePreparation()

        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )
        XCTAssertIdentical(host.chatsController.currentChatVC, originalChat)
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController ===
                    pendingSavedChat
        )

        let replacementChat = HeldSavedChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            replacementChat
        }
        XCTAssertFalse(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "replacement@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))
        XCTAssertEqual(replacementChat.preparationRequestCount, 0)
        XCTAssertIdentical(host.chatsController.currentChatVC, originalChat)
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController ===
                    pendingSavedChat
        )
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )

        pendingSavedChat.completeNativeTerminal(didComplete: true)
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.expandedSplitChatNavigationTransaction?
                .phase == .presented &&
                host.chatsController.currentChatVC === pendingSavedChat &&
                (host.splitViewController.viewController(for: .secondary)
                    as? UINavigationController)?.topViewController ===
                        pendingSavedChat
        })
        XCTAssertTrue(waitUntilExpandedNavigationIsStable(host))
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)

        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "replacement@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))
        XCTAssertEqual(replacementChat.preparationRequestCount, 1)
        replacementChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === replacementChat &&
                (host.splitViewController.viewController(for: .secondary)
                    as? UINavigationController)?.topViewController ===
                        replacementChat
        })
    }

    func testExactSavedExternalOpenDuringPreparationKeepsDirectActivationValid() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        host.leftMenu.didSelectRootScreenBy(key: "saved")
        let originalToken = try XCTUnwrap(
            host.chatsController.expandedSplitChatNavigationTransaction?.token
        )

        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "favorites.example.com",
            conversationType: .saved,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.token,
            originalToken
        )
        XCTAssertEqual(host.preparedChat.preparationRequestCount, 1)
        XCTAssertEqual(host.preparedChat.preparationCancellationCount, 0)

        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === host.preparedChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testExactSavedExternalOpenDuringNativeTerminalDoesNotPoisonValidation() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let pendingSavedChat =
            HeldSavedNativeTerminalChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            pendingSavedChat
        }
        host.leftMenu.didSelectRootScreenBy(key: "saved")
        pendingSavedChat.releasePreparation()
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )

        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "favorites.example.com",
            conversationType: .saved,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))
        XCTAssertEqual(pendingSavedChat.preparationRequestCount, 1)
        XCTAssertEqual(pendingSavedChat.preparationCancellationCount, 0)

        pendingSavedChat.completeNativeTerminal(didComplete: true)
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === pendingSavedChat &&
                (host.splitViewController.viewController(for: .secondary)
                    as? UINavigationController)?.topViewController ===
                        pendingSavedChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testRegularChatThenArchiveThenSavedReconcilesDetachedPresentedTransaction() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let regularChat = HeldSavedChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            regularChat
        }
        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "regular@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))
        regularChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === regularChat &&
                host.chatsController.expandedSplitChatNavigationTransaction?
                    .phase == .presented
        })

        host.leftMenu.didSelectRootScreenBy(key: "archive")
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.splitViewController.transitionCoordinator == nil &&
                host.splitViewController.viewController(for: .supplementary)
                    !== host.chatsController.navigationController
        })
        XCTAssertIdentical(host.chatsController.currentChatVC, regularChat)

        host.chatsController.expandedSplitChatDestinationFactory = {
            host.preparedChat
        }
        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(host.preparedChat.preparationRequestCount, 1)
        XCTAssertNil(host.chatsController.currentChatVC)
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .preparing
        )
        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === host.preparedChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testSavedAfterArchiveReconcilesRestoredButDetachedPreviousChat() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let originalChat = ChatViewController()
        originalChat.owner = "owner@example.com"
        originalChat.jid = "original@example.com"
        originalChat.conversationType = .regular
        host.previousSecondary.setViewControllers(
            [originalChat],
            animated: false
        )
        host.chatsController.currentChatVC = originalChat
        host.chatsController.playerViewToolbar.delegate = originalChat

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === host.preparedChat
        })

        host.leftMenu.didSelectRootScreenBy(key: "archive")
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.splitViewController.transitionCoordinator == nil &&
                host.chatsController
                    .expandedSplitChatNavigationTransaction == nil
        })
        XCTAssertIdentical(host.chatsController.currentChatVC, originalChat)

        let reopenedSavedChat = HeldSavedChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            reopenedSavedChat
        }
        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(reopenedSavedChat.preparationRequestCount, 1)
        XCTAssertNil(host.chatsController.currentChatVC)
        reopenedSavedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === reopenedSavedChat &&
                (host.splitViewController.viewController(for: .secondary)
                    as? UINavigationController)?.topViewController ===
                        reopenedSavedChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testSavedAfterArchiveCancelsDetachedGenericExpandedPreparationWithoutRestoringIt() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let pendingRegularChat = HeldSavedChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            pendingRegularChat
        }
        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "pending@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .preparing
        )

        host.leftMenu.didSelectRootScreenBy(key: "archive")
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.splitViewController.transitionCoordinator == nil
        })
        XCTAssertEqual(pendingRegularChat.preparationCancellationCount, 0)

        host.chatsController.expandedSplitChatDestinationFactory = {
            host.preparedChat
        }
        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(pendingRegularChat.preparationCancellationCount, 1)
        XCTAssertEqual(host.preparedChat.preparationRequestCount, 1)
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.target,
            LastChatsNavigationSingleFlightCoordinator.Target(
                owner: "owner@example.com",
                jid: "favorites.example.com",
                conversationType: .saved
            )
        )
        XCTAssertNil(host.chatsController.currentChatVC)

        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.currentChatVC === host.preparedChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testExpandedDirectSavedRouteFallsBackToCombinedListWhenAvailabilityChangesBeforeCommit() throws {
        try seedAccount("first@example.com", order: 0)
        try seedFavoritesService(
            owner: "first@example.com",
            node: "favorites.first.example.com"
        )
        try seedLastChat(
            jid: "favorites.first.example.com",
            owner: "first@example.com",
            conversationType: .saved
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }

        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            host.previousSupplementary
        )
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .secondary),
            host.previousSecondary
        )

        try seedAccount("second@example.com", order: 1)
        try seedFavoritesService(
            owner: "second@example.com",
            node: "favorites.second.example.com"
        )
        try seedLastChat(
            jid: "favorites.second.example.com",
            owner: "second@example.com",
            conversationType: .saved
        )
        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            guard let savedController = host.leftMenu.savedMessagesChatsVc,
                  let supplementary = host.splitViewController.viewController(
                    for: .supplementary
                  ) as? UINavigationController else {
                return false
            }
            return supplementary.topViewController === savedController
        })

        let savedController = try XCTUnwrap(host.leftMenu.savedMessagesChatsVc)
        XCTAssertEqual(savedController.filter.value, .saved)
        XCTAssertNil(host.chatsController.expandedSplitChatNavigationTransaction)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
        XCTAssertFalse(host.chatsController.currentChatVC === host.preparedChat)
    }

    func testExpandedDirectSavedRouteFallsBackToListWhenRouteChangesBeforeCommit() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        var route = StackedNavigationRoute.splitDetailReplacement
        host.leftMenu.chatNavigationRouteResolver = { _ in route }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        route = .currentNavigationPush
        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        XCTAssertNil(host.chatsController.expandedSplitChatNavigationTransaction)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
    }

    func testExpandedDirectSavedRouteFallsBackToListWhenAccountEpochChangesBeforeCommit() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let initialAccount = NSObject()
        let replacementAccount = NSObject()
        var accountIdentifier = ObjectIdentifier(initialAccount)
        host.chatsController.chatNavigationAccountEpochResolver = { _ in
            LastChatsChatNavigationAccountEpoch(
                accountIdentifier: accountIdentifier,
                isPresent: true,
                isEnabled: true
            )
        }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        accountIdentifier = ObjectIdentifier(replacementAccount)
        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        XCTAssertNil(host.chatsController.expandedSplitChatNavigationTransaction)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
    }

    func testExpandedDirectSavedRouteRevalidatesAvailabilityAfterCommitBeforeNativeTerminal() throws {
        try seedAccount("first@example.com", order: 0)
        try seedFavoritesService(
            owner: "first@example.com",
            node: "favorites.first.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        host.preparedChat.releasePreparation()
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )

        try seedAccount("second@example.com", order: 1)
        try seedFavoritesService(
            owner: "second@example.com",
            node: "favorites.second.example.com"
        )

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        XCTAssertNil(host.chatsController.expandedSplitChatNavigationTransaction)
        XCTAssertFalse(host.chatsController.currentChatVC === host.preparedChat)
    }

    func testExpandedSavedNativeTerminalCancellationRollsBackThenFallsBackAndIgnoresLateCallback() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundExpandedSavedRouteHost()
        defer { releaseForegroundExpandedSavedRouteHost(host) }
        let originalChat = ChatViewController()
        originalChat.owner = "owner@example.com"
        originalChat.jid = "original@example.com"
        originalChat.conversationType = .regular
        host.previousSecondary.setViewControllers(
            [originalChat],
            animated: false
        )
        host.chatsController.currentChatVC = originalChat
        host.chatsController.playerViewToolbar.delegate = originalChat

        let pendingSavedChat =
            HeldSavedNativeTerminalChatViewController()
        host.chatsController.expandedSplitChatDestinationFactory = {
            pendingSavedChat
        }
        host.leftMenu.didSelectRootScreenBy(key: "saved")
        pendingSavedChat.releasePreparation()
        XCTAssertEqual(
            host.chatsController.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController ===
                    pendingSavedChat
        )

        pendingSavedChat.completeNativeTerminal(didComplete: false)

        XCTAssertNil(host.chatsController.expandedSplitChatNavigationTransaction)
        XCTAssertIdentical(host.chatsController.currentChatVC, originalChat)
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .secondary),
            host.previousSecondary,
            "The owned provisional Saved secondary must roll back synchronously"
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        let savedController = try XCTUnwrap(host.leftMenu.savedMessagesChatsVc)
        let installedSupplementary = host.splitViewController.viewController(
            for: .supplementary
        )
        XCTAssertTrue(
            (installedSupplementary as? UINavigationController)?
                .topViewController === savedController
        )

        pendingSavedChat.replayCompletedNativeTerminal(didComplete: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            installedSupplementary
        )
        XCTAssertNil(host.chatsController.expandedSplitChatNavigationTransaction)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === pendingSavedChat
                } ?? false
        )
    }

    func testActualSingleSavedCompactMenuRowTapInstallsChatAsFirstVisibleDestinationWithChatsBackRoot() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(owner: "owner@example.com", node: "favorites.example.com")
        try seedLastChat(jid: "favorites.example.com", owner: "owner@example.com", conversationType: .saved)

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }

        let savedRow = try XCTUnwrap(
            host.leftMenu.datasource.first?.firstIndex { $0.key == "saved" }
        )

        host.leftMenu.tableView(
            host.leftMenu.tableView,
            didSelectRowAt: IndexPath(row: savedRow, section: 0)
        )

        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            host.previousSupplementary,
            "Saved selection must not reveal the ordinary Chats list first"
        )

        host.preparedChat.releasePreparation()

        XCTAssertEqual(
            host.chatsController.chatNavigationSingleFlight.state?.phase,
            .pushing,
            "The transaction must wait for the split reveal terminal"
        )
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            host.previousSupplementary
        )

        XCTAssertTrue(waitUntil(timeout: 1) {
            guard let navigationController = host.splitViewController
                .viewController(for: .supplementary)
                as? UINavigationController else {
                return false
            }
            return navigationController.topViewController ===
                host.preparedChat &&
                host.chatsController.chatNavigationSingleFlight.state?.phase
                    == .presented
        })

        let navigationController = try XCTUnwrap(
            host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController
        )
        XCTAssertEqual(host.chatsController.filter.value, .chats)
        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertIdentical(
            navigationController.viewControllers.first,
            host.chatsController
        )
        XCTAssertIdentical(navigationController.topViewController, host.preparedChat)
        XCTAssertEqual(host.leftMenu.previousSelectedKey, "saved")
        XCTAssertEqual(host.preparedChat.owner, "owner@example.com")
        XCTAssertEqual(host.preparedChat.jid, "favorites.example.com")
        XCTAssertEqual(host.preparedChat.conversationType, .saved)
        let popped = navigationController.popViewController(animated: false)
        XCTAssertIdentical(popped, host.preparedChat)
        XCTAssertIdentical(
            navigationController.topViewController,
            host.chatsController,
            "Back from Saved Messages must return to ordinary Chats"
        )

        host.splitViewController.show(.primary)
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.splitViewController.transitionCoordinator == nil &&
                navigationController.transitionCoordinator == nil
        })

        let reopenedChat = HeldSavedChatViewController()
        host.chatsController.compactChatDestinationFactory = { reopenedChat }
        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(reopenedChat.preparationRequestCount, 1)
        XCTAssertEqual(
            host.chatsController.chatNavigationSingleFlight.state?.phase,
            .preparing
        )
        XCTAssertIdentical(
            navigationController.topViewController,
            host.chatsController
        )

        reopenedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            navigationController.topViewController === reopenedChat &&
                host.chatsController.chatNavigationSingleFlight.state?.phase
                    == .presented
        })
    }


    func testSavedAfterAnotherSectionDoesNotRevealStaleSavedNavigationColumn() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }
        host.leftMenu.didSelectRootScreenBy(key: "saved")
        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.chatNavigationSingleFlight.state?.phase ==
                .presented
        })
        let savedNavigationController = host.chatsController.navigationController

        host.leftMenu.didSelectRootScreenBy(key: "archive")
        let archiveNavigationController = try XCTUnwrap(
            host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController
        )
        XCTAssertIdentical(
            archiveNavigationController.topViewController,
            host.leftMenu.archivedVc
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.splitViewController.transitionCoordinator == nil &&
                savedNavigationController?.transitionCoordinator == nil &&
                savedNavigationController?.viewIfLoaded?.window == nil
        })

        let reopenedChat = HeldSavedChatViewController()
        host.chatsController.compactChatDestinationFactory = { reopenedChat }
        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(reopenedChat.preparationRequestCount, 1)
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            archiveNavigationController,
            "The stale Saved navigation stack must not be revealed before the new chat is prepared"
        )

        reopenedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            guard let supplementary = host.splitViewController.viewController(
                for: .supplementary
            ) as? UINavigationController else {
                return false
            }
            return supplementary !== archiveNavigationController &&
                supplementary.topViewController === reopenedChat
        })
    }

    func testSingleAvailableSavedSelectionOpensChatDirectly() {
        let availableChats = [
            LeftMenuSavedMessagesSelectionPolicy.SavedChat(owner: "owner@example.com", jid: "favorites.example.com")
        ]

        let decision = LeftMenuSavedMessagesSelectionPolicy.decision(
            availableChats: availableChats
        )

        XCTAssertEqual(decision, .openChatDirectly(availableChats[0]))
    }

    func testMultipleAvailableSavedSelectionShowsListWithoutOpeningAChat() {
        let first = LeftMenuSavedMessagesSelectionPolicy.SavedChat(owner: "first@example.com", jid: "favorites.first.example.com")
        let second = LeftMenuSavedMessagesSelectionPolicy.SavedChat(owner: "second@example.com", jid: "favorites.second.example.com")

        let decision = LeftMenuSavedMessagesSelectionPolicy.decision(
            availableChats: [first, second]
        )

        XCTAssertEqual(decision, .showSavedList)
    }

    func testNoAvailableSavedSelectionShowsListFallback() {
        XCTAssertEqual(
            LeftMenuSavedMessagesSelectionPolicy.decision(availableChats: []),
            .showSavedList
        )
    }

    func testActualZeroAvailabilitySavedSelectionInstallsListWithoutAutoOpeningChat() throws {
        let controller = LeftMenuViewController()
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.viewControllers = [
            controller,
            UINavigationController(rootViewController: LastChatsViewController()),
            UINavigationController(rootViewController: EmptyChatViewController())
        ]
        attachToTraitWindow(
            splitViewController,
            horizontalSizeClass: .compact
        )
        controller.loadViewIfNeeded()

        controller.didSelectRootScreenBy(key: "saved")

        let savedController = try XCTUnwrap(controller.savedMessagesChatsVc)
        let navigationController = try XCTUnwrap(
            splitViewController.viewController(for: .supplementary)
                as? UINavigationController
        )
        XCTAssertIdentical(navigationController.topViewController, savedController)
        XCTAssertEqual(savedController.filter.value, .saved)
        XCTAssertNil(savedController.currentChatVC)
        XCTAssertFalse(navigationController.topViewController is ChatViewController)
    }

    func testUnavailableCompactDirectActivationContextFallsBackToSavedList() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }
        let unexpectedVisibleNavigationController = UINavigationController(
            rootViewController: host.chatsController
        )
        host.splitViewController.setViewController(
            unexpectedVisibleNavigationController,
            for: .secondary
        )
        host.splitViewController.show(.secondary)
        unexpectedVisibleNavigationController.loadViewIfNeeded()
        host.splitViewController.view.layoutIfNeeded()
        XCTAssertTrue(waitUntil(timeout: 1) {
            unexpectedVisibleNavigationController.viewIfLoaded?.window != nil
        })

        host.leftMenu.didSelectRootScreenBy(key: "saved")

        let savedController = try XCTUnwrap(host.leftMenu.savedMessagesChatsVc)
        let supplementary = try XCTUnwrap(
            host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController
        )
        XCTAssertIdentical(supplementary.topViewController, savedController)
        XCTAssertEqual(savedController.filter.value, .saved)
        XCTAssertNil(savedController.currentChatVC)
        XCTAssertEqual(host.leftMenu.previousSelectedKey, "saved")
        XCTAssertEqual(host.preparedChat.preparationRequestCount, 0)
    }

    func testSeveralEnabledAccountsWithOnlyOneFavoritesServiceOpenThatChatDirectly() {
        let chats = LeftMenuSavedMessagesSelectionPolicy.savedChats(
            enabledAccountJids: ["first@example.com", "second@example.com"],
            favoritesNodesByOwner: [
                "second@example.com": "favorites.second.example.com"
            ]
        )

        XCTAssertEqual(
            LeftMenuSavedMessagesSelectionPolicy.decision(availableChats: chats),
            .openChatDirectly(
                .init(
                    owner: "second@example.com",
                    jid: "favorites.second.example.com"
                )
            )
        )
    }

    func testActualSeveralEnabledAccountsWithOneDiscoveredServiceOpenThatSavedChatDirectly() throws {
        try seedAccount("first@example.com", order: 0)
        try seedAccount("second@example.com", order: 1)
        try seedFavoritesService(
            owner: "second@example.com",
            node: "favorites.second.example.com"
        )
        try seedLastChat(
            jid: "favorites.second.example.com",
            owner: "second@example.com",
            conversationType: .saved
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }

        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertEqual(host.preparedChat.owner, "second@example.com")
        XCTAssertEqual(host.preparedChat.jid, "favorites.second.example.com")
        XCTAssertEqual(host.preparedChat.conversationType, .saved)
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)

        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.chatNavigationSingleFlight.state?.phase ==
                .presented
        })
    }

    func testActualMultipleSavedMenuRowTapShowsCombinedListWithoutOpeningFirstChat() throws {
        try seedAccount("first@example.com", order: 0)
        try seedAccount("second@example.com", order: 1)
        try seedFavoritesService(owner: "first@example.com", node: "favorites.first.example.com")
        try seedFavoritesService(owner: "second@example.com", node: "favorites.second.example.com")
        try seedLastChat(
            jid: "favorites.first.example.com",
            owner: "first@example.com",
            conversationType: .saved,
            messageDate: Date(timeIntervalSince1970: 10)
        )
        try seedLastChat(
            jid: "favorites.second.example.com",
            owner: "second@example.com",
            conversationType: .saved,
            messageDate: Date(timeIntervalSince1970: 20)
        )

        let controller = LeftMenuViewController()
        controller.loadViewIfNeeded()

        let savedRow = try XCTUnwrap(
            controller.datasource.first?.firstIndex { $0.key == "saved" }
        )
        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: savedRow, section: 0)
        )

        let savedController = try XCTUnwrap(controller.savedMessagesChatsVc)
        XCTAssertEqual(savedController.filter.value, .saved)
        XCTAssertFalse(savedController.shouldShowBottomBar)
        XCTAssertNil(savedController.currentChatVC)
        XCTAssertFalse(
            savedController.navigationController?.topViewController
                is ChatViewController
        )
        savedController.enabledAccounts.accept([
            "first@example.com",
            "second@example.com"
        ])
        savedController.updateDatasource(.saved)
        let rows = try XCTUnwrap(savedController.chatsObserver?.toArray())
        XCTAssertEqual(rows.map { "\($0.owner)|\($0.jid)" }, [
            "second@example.com|favorites.second.example.com",
            "first@example.com|favorites.first.example.com"
        ])
        XCTAssertTrue(rows.allSatisfy { $0.conversationType == .saved })
    }

    func testPendingDirectSavedRouteRevalidatesAvailabilityBeforeCommit() throws {
        try seedAccount("first@example.com", order: 0)
        try seedFavoritesService(owner: "first@example.com", node: "favorites.first.example.com")
        try seedLastChat(jid: "favorites.first.example.com", owner: "first@example.com", conversationType: .saved)

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }

        let savedRow = try XCTUnwrap(
            host.leftMenu.datasource.first?.firstIndex { $0.key == "saved" }
        )
        host.leftMenu.tableView(
            host.leftMenu.tableView,
            didSelectRowAt: IndexPath(row: savedRow, section: 0)
        )

        try seedAccount("second@example.com", order: 1)
        try seedFavoritesService(owner: "second@example.com", node: "favorites.second.example.com")
        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        let savedController = try XCTUnwrap(host.leftMenu.savedMessagesChatsVc)
        XCTAssertEqual(savedController.filter.value, .saved)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
    }

    func testRepeatedSavedTapCoalescesPendingCompactActivation() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        let firstState = try XCTUnwrap(
            host.chatsController.chatNavigationSingleFlight.state
        )

        host.leftMenu.didSelectRootScreenBy(key: "saved")

        let coalescedState = try XCTUnwrap(
            host.chatsController.chatNavigationSingleFlight.state
        )
        XCTAssertEqual(coalescedState.token, firstState.token)
        XCTAssertEqual(coalescedState.target, firstState.target)
        XCTAssertEqual(coalescedState.phase, .preparing)
        XCTAssertEqual(host.preparedChat.preparationRequestCount, 1)
        XCTAssertEqual(host.preparedChat.preparationCancellationCount, 0)
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            host.previousSupplementary
        )

        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.chatNavigationSingleFlight.state?.phase ==
                .presented
        })
    }

    func testExactSavedExternalOpenDuringCompactPreparationDoesNotRevealChatsOrCancelRoute() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }
        host.leftMenu.didSelectRootScreenBy(key: "saved")
        let originalState = try XCTUnwrap(
            host.chatsController.chatNavigationSingleFlight.state
        )

        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: "owner@example.com",
            jid: "favorites.example.com",
            conversationType: .saved,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))

        let coalescedState = try XCTUnwrap(
            host.chatsController.chatNavigationSingleFlight.state
        )
        XCTAssertEqual(coalescedState.token, originalState.token)
        XCTAssertEqual(coalescedState.target, originalState.target)
        XCTAssertEqual(coalescedState.phase, .preparing)
        XCTAssertEqual(host.preparedChat.preparationRequestCount, 1)
        XCTAssertEqual(host.preparedChat.preparationCancellationCount, 0)
        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            host.previousSupplementary,
            "External coalescing must not reveal the ordinary Chats list"
        )

        host.preparedChat.releasePreparation()
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.chatsController.chatNavigationSingleFlight.state?.phase ==
                .presented &&
                host.chatsController.currentChatVC === host.preparedChat
        })
        XCTAssertNil(host.leftMenu.savedMessagesChatsVc)
    }

    func testCompactDirectSavedRouteFallsBackWhenRouteChangesBeforeCommit() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }
        var route = StackedNavigationRoute.currentNavigationPush
        host.leftMenu.chatNavigationRouteResolver = { _ in route }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        route = .splitDetailReplacement
        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        XCTAssertNil(host.chatsController.chatNavigationSingleFlight.state)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
    }

    func testCompactDirectSavedRouteFallsBackWhenAccountEpochChangesBeforeCommit() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }
        let initialAccount = NSObject()
        let replacementAccount = NSObject()
        var accountIdentifier = ObjectIdentifier(initialAccount)
        host.chatsController.chatNavigationAccountEpochResolver = { _ in
            LastChatsChatNavigationAccountEpoch(
                accountIdentifier: accountIdentifier,
                isPresent: true,
                isEnabled: true
            )
        }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        accountIdentifier = ObjectIdentifier(replacementAccount)
        host.preparedChat.releasePreparation()

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        XCTAssertNil(host.chatsController.chatNavigationSingleFlight.state)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
    }

    func testCompactDirectSavedRouteFallsBackWhenHierarchyChangesAfterPushCommit() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }

        host.leftMenu.didSelectRootScreenBy(key: "saved")
        host.preparedChat.releasePreparation()
        XCTAssertEqual(
            host.chatsController.chatNavigationSingleFlight.state?.phase,
            .pushing
        )

        let newerSecondary = UINavigationController(
            rootViewController: UIViewController()
        )
        host.splitViewController.setViewController(
            newerSecondary,
            for: .secondary
        )

        XCTAssertTrue(waitUntil(timeout: 1) {
            host.leftMenu.savedMessagesChatsVc?.filter.value == .saved
        })
        XCTAssertNil(host.chatsController.chatNavigationSingleFlight.state)
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController)?.viewControllers.contains {
                    $0 === host.preparedChat
                } ?? false
        )
    }

    func testSelectingAnotherRootCancelsPendingDirectSavedRouteAndMakesLateCompletionInert() throws {
        try seedAccount("owner@example.com")
        try seedFavoritesService(
            owner: "owner@example.com",
            node: "favorites.example.com"
        )

        let host = try makeForegroundCompactSavedRouteHost()
        defer { releaseForegroundCompactSavedRouteHost(host) }

        host.leftMenu.didSelectRootScreenBy(key: "saved")

        XCTAssertTrue(host.chatsController.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertTrue(host.chatsController.hasActiveOutgoingChatOpenNavigationPreparation)
        XCTAssertTrue(host.chatsController.hasPendingChatNavigationPreparationTimeout)
        XCTAssertNotNil(host.chatsController.chatNavigationSingleFlight.state)

        host.leftMenu.didSelectRootScreenBy(key: "archive")
        let replacementSupplementary = host.splitViewController.viewController(
            for: .supplementary
        )

        XCTAssertFalse(host.chatsController.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertFalse(host.chatsController.hasActiveOutgoingChatOpenNavigationPreparation)
        XCTAssertFalse(host.chatsController.hasPendingChatNavigationPreparationTimeout)
        XCTAssertNil(host.chatsController.chatNavigationSingleFlight.state)
        XCTAssertEqual(host.preparedChat.preparationCancellationCount, 1)

        host.preparedChat.releasePreparation()

        XCTAssertIdentical(
            host.splitViewController.viewController(for: .supplementary),
            replacementSupplementary
        )
        XCTAssertFalse(
            (replacementSupplementary as? UINavigationController)?
                .viewControllers.contains { $0 === host.preparedChat } ?? false
        )
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

    func testSavedFilterAggregatesDiscoveredFavoritesAcrossEnabledAccounts() throws {
        try seedAccount("first@example.com", order: 0)
        try seedAccount("second@example.com", order: 1)
        try seedFavoritesService(
            owner: "first@example.com",
            node: "favorites.first.example.com"
        )
        try seedFavoritesService(
            owner: "second@example.com",
            node: "favorites.second.example.com"
        )
        try seedLastChat(
            jid: "favorites.first.example.com",
            owner: "first@example.com",
            conversationType: .saved,
            messageDate: Date(timeIntervalSince1970: 10)
        )
        try seedLastChat(
            jid: "favorites.second.example.com",
            owner: "second@example.com",
            conversationType: .saved,
            messageDate: Date(timeIntervalSince1970: 20)
        )

        let controller = LastChatsViewController()
        controller.enabledAccounts.accept([
            "first@example.com",
            "second@example.com"
        ])
        controller.updateDatasource(.saved)

        let rows = try XCTUnwrap(controller.chatsObserver?.toArray())
        XCTAssertEqual(rows.map { "\($0.owner)|\($0.jid)" }, [
            "second@example.com|favorites.second.example.com",
            "first@example.com|favorites.first.example.com"
        ])
        XCTAssertTrue(rows.allSatisfy { $0.conversationType == .saved })
    }

    func testSavedRowUsesBookmarkIconAndSavedTitle() {
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.title, "Saved messages")
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.leftMenuIconName, "bookmark")
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.avatarIconName, XMPPFavoritesManagerStorageItem.imageName)
        XCTAssertEqual(SavedMessagesChatListPresentationPolicy.avatarIconName, "bookmark.fill")
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

    private func seedAccount(_ jid: String, order: Int = 0) throws {
        let realm = try WRealm.safe()
        let account = AccountStorageItem()
        account.jid = jid
        account.username = jid
        account.enabled = true
        account.order = order

        try realm.write {
            realm.add(account, update: .modified)
        }
    }

    private func seedFavoritesService(owner: String, node: String) throws {
        let realm = try WRealm.safe()
        let item = XMPPFavoritesManagerStorageItem()
        item.primary = XMPPFavoritesManagerStorageItem.genPrimary(owner: owner)
        item.owner = owner
        item.node = node

        try realm.write {
            realm.add(item, update: .modified)
        }
    }

    private func seedLastChat(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        messageDate: Date? = nil
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.owner = owner
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.messageDate = messageDate ?? Date(
            timeIntervalSince1970: conversationType == .saved ? 2 : 1
        )

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

    private struct ForegroundCompactSavedRouteHost {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let splitViewController: UISplitViewController
        let leftMenu: LeftMenuViewController
        let chatsController: LastChatsViewController
        let previousSupplementary: UINavigationController
        let previousSecondary: UINavigationController
        let preparedChat: HeldSavedChatViewController
    }

    private func makeForegroundCompactSavedRouteHost() throws
        -> ForegroundCompactSavedRouteHost {
        let windowScene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let leftMenu = LeftMenuViewController()
        let chatsController = LastChatsViewController()
        let accountIdentity = NSObject()
        let preparedChat = HeldSavedChatViewController()
        let previousSupplementary = UINavigationController(
            rootViewController: LastChatsViewController()
        )
        let previousSecondary = UINavigationController(
            rootViewController: EmptyChatViewController()
        )
        let splitViewController = UISplitViewController(style: .tripleColumn)

        leftMenu.chatsVc = chatsController
        leftMenu.chatNavigationRouteResolver = { _ in .currentNavigationPush }
        chatsController.chatNavigationRouteResolver = {
            _ in .currentNavigationPush
        }
        chatsController.chatNavigationAccountEpochResolver = { _ in
            LastChatsChatNavigationAccountEpoch(
                accountIdentifier: ObjectIdentifier(accountIdentity),
                isPresent: true,
                isEnabled: true
            )
        }
        chatsController.compactChatDestinationFactory = { preparedChat }
        splitViewController.setViewController(leftMenu, for: .primary)
        splitViewController.setViewController(
            previousSupplementary,
            for: .supplementary
        )
        splitViewController.setViewController(
            previousSecondary,
            for: .secondary
        )

        let window = TraitWindow(
            windowScene: windowScene,
            horizontalSizeClass: .compact
        )
        retainedTraitWindows.append(window)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = splitViewController
        splitViewController.loadViewIfNeeded()
        leftMenu.loadViewIfNeeded()
        UIView.performWithoutAnimation {
            splitViewController.show(.primary)
            splitViewController.view.layoutIfNeeded()
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(waitUntil(timeout: 1) {
            let supplementary = splitViewController.viewController(
                for: .supplementary
            )
            let supplementaryTop = (supplementary as? UINavigationController)?
                .topViewController ?? supplementary
            let secondary = splitViewController.viewController(for: .secondary)
            let secondaryTop = (secondary as? UINavigationController)?
                .topViewController ?? secondary
            return UIApplication.shared.applicationState == .active &&
                window.isKeyWindow &&
                !window.isHidden &&
                window.windowScene?.activationState == .foregroundActive &&
                splitViewController.viewIfLoaded?.window === window &&
                splitViewController.transitionCoordinator == nil &&
                supplementary?.transitionCoordinator == nil &&
                supplementaryTop?.transitionCoordinator == nil &&
                secondary?.transitionCoordinator == nil &&
                secondaryTop?.transitionCoordinator == nil &&
                splitViewController.presentedViewController == nil &&
                supplementary?.presentedViewController == nil &&
                supplementaryTop?.presentedViewController == nil &&
                secondary?.presentedViewController == nil &&
                secondaryTop?.presentedViewController == nil
        })

        return ForegroundCompactSavedRouteHost(
            window: window,
            previousKeyWindow: previousKeyWindow,
            splitViewController: splitViewController,
            leftMenu: leftMenu,
            chatsController: chatsController,
            previousSupplementary: previousSupplementary,
            previousSecondary: previousSecondary,
            preparedChat: preparedChat
        )
    }

    private func releaseForegroundCompactSavedRouteHost(
        _ host: ForegroundCompactSavedRouteHost
    ) {
        host.chatsController.resetChatNavigationTransaction(cancelled: true)
        host.window.isHidden = true
        host.window.rootViewController = nil
        host.previousKeyWindow?.makeKey()
    }

    private struct ForegroundExpandedSavedRouteHost {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let splitViewController: UISplitViewController
        let leftMenu: LeftMenuViewController
        let chatsController: LastChatsViewController
        let previousSupplementary: UINavigationController
        let previousSecondary: UINavigationController
        let preparedChat: HeldSavedChatViewController
    }

    private func makeForegroundExpandedSavedRouteHost() throws
        -> ForegroundExpandedSavedRouteHost {
        let windowScene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let leftMenu = LeftMenuViewController()
        let chatsController = LastChatsViewController()
        let accountIdentity = NSObject()
        let preparedChat = HeldSavedChatViewController()
        let previousSupplementary = UINavigationController(
            rootViewController: UIViewController()
        )
        let previousSecondary = UINavigationController(
            rootViewController: EmptyChatViewController()
        )
        let splitViewController = UISplitViewController(style: .tripleColumn)

        leftMenu.chatsVc = chatsController
        leftMenu.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        chatsController.chatNavigationRouteResolver = {
            _ in .splitDetailReplacement
        }
        chatsController.chatNavigationAccountEpochResolver = { _ in
            LastChatsChatNavigationAccountEpoch(
                accountIdentifier: ObjectIdentifier(accountIdentity),
                isPresent: true,
                isEnabled: true
            )
        }
        chatsController.expandedSplitChatDestinationFactory = { preparedChat }
        chatsController.expandedSplitStableVisibilityOverride = { _ in true }
        splitViewController.setViewController(leftMenu, for: .primary)
        splitViewController.setViewController(
            previousSupplementary,
            for: .supplementary
        )
        splitViewController.setViewController(
            previousSecondary,
            for: .secondary
        )

        let window = TraitWindow(
            windowScene: windowScene,
            horizontalSizeClass: .regular
        )
        retainedTraitWindows.append(window)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = splitViewController
        window.makeKeyAndVisible()
        splitViewController.loadViewIfNeeded()
        splitViewController.show(.supplementary)
        leftMenu.loadViewIfNeeded()
        splitViewController.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        _ = waitUntil(timeout: 1) {
            splitViewController.transitionCoordinator == nil
        }

        return ForegroundExpandedSavedRouteHost(
            window: window,
            previousKeyWindow: previousKeyWindow,
            splitViewController: splitViewController,
            leftMenu: leftMenu,
            chatsController: chatsController,
            previousSupplementary: previousSupplementary,
            previousSecondary: previousSecondary,
            preparedChat: preparedChat
        )
    }

    private func releaseForegroundExpandedSavedRouteHost(
        _ host: ForegroundExpandedSavedRouteHost
    ) {
        host.chatsController.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: false
        )
        host.window.isHidden = true
        host.window.rootViewController = nil
        host.previousKeyWindow?.makeKey()
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        } while Date() < deadline
        return condition()
    }

    private func waitUntilExpandedNavigationIsStable(
        _ host: ForegroundExpandedSavedRouteHost
    ) -> Bool {
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.02)
        )
        return waitUntil(timeout: 1) {
            let supplementary = host.splitViewController.viewController(
                for: .supplementary
            )
            let supplementaryTop =
                (supplementary as? UINavigationController)?
                    .topViewController ?? supplementary
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            let secondaryTop = (secondary as? UINavigationController)?
                .topViewController ?? secondary
            return host.splitViewController.transitionCoordinator == nil &&
                supplementary?.transitionCoordinator == nil &&
                supplementaryTop?.transitionCoordinator == nil &&
                secondary?.transitionCoordinator == nil &&
                secondaryTop?.transitionCoordinator == nil
        }
    }


    private class HeldSavedChatViewController:
        ChatViewController,
        StackedNavigationPresentationPreparationControlling {
        private var preparationHandle:
            StackedNavigationPresentationPreparationHandle?
        private(set) var preparationCancellationCount = 0
        private(set) var preparationRequestCount = 0

        func makeStackedNavigationPresentationPreparation(
            targetBounds: CGRect?,
            completion: @escaping () -> Void
        ) -> StackedNavigationPresentationPreparationHandle {
            preparationRequestCount += 1
            let handle = StackedNavigationPresentationPreparationHandle(
                cancellation: { [weak self] in
                    self?.preparationCancellationCount += 1
                },
                completion: completion
            )
            preparationHandle = handle
            return handle
        }

        func releasePreparation() {
            guard let preparationHandle else {
                XCTFail("Expected a pending Saved chat preparation")
                return
            }
            self.preparationHandle = nil
            preparationHandle.finish()
        }
    }

    private final class SavedLifecycleChatViewController: ChatViewController {
        private(set) var viewWillAppearCount = 0

        override func viewWillAppear(_ animated: Bool) {
            viewWillAppearCount += 1
            super.viewWillAppear(animated)
        }
    }

    private final class HeldSavedNativeTerminalChatViewController:
        HeldSavedChatViewController,
        StackedNavigationNativeTransitionCompletionRegistering {
        private var nativeTerminalCompletion: ((Bool) -> Void)?
        private var completedNativeTerminalCompletion: ((Bool) -> Void)?

        func registerStackedNavigationNativeTransitionCompletion(
            transitionOwner: UIViewController?,
            completion: @escaping (Bool) -> Void
        ) -> Bool {
            nativeTerminalCompletion = completion
            return true
        }

        func completeNativeTerminal(didComplete: Bool) {
            guard let nativeTerminalCompletion else {
                XCTFail("Expected a pending native terminal")
                return
            }
            self.nativeTerminalCompletion = nil
            completedNativeTerminalCompletion = nativeTerminalCompletion
            nativeTerminalCompletion(didComplete)
        }

        func replayCompletedNativeTerminal(didComplete: Bool) {
            guard let completedNativeTerminalCompletion else {
                XCTFail("Expected a completed native terminal callback")
                return
            }
            completedNativeTerminalCompletion(didComplete)
        }
    }

    private final class TraitWindow: UIWindow {
        private let horizontalSizeClass: UIUserInterfaceSizeClass

        init(horizontalSizeClass: UIUserInterfaceSizeClass) {
            self.horizontalSizeClass = horizontalSizeClass
            super.init(frame: UIScreen.main.bounds)
        }

        init(
            windowScene: UIWindowScene,
            horizontalSizeClass: UIUserInterfaceSizeClass
        ) {
            self.horizontalSizeClass = horizontalSizeClass
            super.init(windowScene: windowScene)
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
