//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//

import XCTest
import UIKit
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class LastChatsViewControllerBehaviorTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var previousConnectingAccounts: Set<String>!
    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        previousConnectingAccounts = AccountManager.shared.connectingUsers.value
        previousLanguage = TranslationsManager.shared.currentLang
        TranslationsManager.shared.currentLang = "en"
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsViewControllerBehaviorTests-\(name)-\(UUID().uuidString)"
        )
        ChatUIResponsivenessGate.shared.resetForTesting()
    }

    override func tearDown() {
        ChatUIResponsivenessGate.shared.resetForTesting()
        AccountManager.shared.connectingUsers.accept(previousConnectingAccounts)
        previousConnectingAccounts = nil
        TranslationsManager.shared.currentLang = previousLanguage
        previousLanguage = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testConfigureBarsTabsWithNoSecurityShowsOnlyAddButton() {
        withInterfaceType(.tabs, useYubikey: false) {
            let controller = LastChatsViewController()
            controller.configureBars()

            let rightItems = navigationBarItems(controller.navigationItem.rightBarButtonItems,
                                               controller.navigationItem.rightBarButtonItem)

            XCTAssertEqual(rightItems.count, 1)
            XCTAssertFalse(rightItems.contains(controller.securityButton))
        }
    }

    func testConfigureBarsTabsWithSecurityShowsAddAndSecurityButtons() {
        withInterfaceType(.tabs, useYubikey: true) {
            let controller = LastChatsViewController()
            controller.configureBars()

            let rightItems = navigationBarItems(controller.navigationItem.rightBarButtonItems,
                                               controller.navigationItem.rightBarButtonItem)

            XCTAssertEqual(rightItems.count, 2)
            XCTAssertTrue(rightItems.contains(controller.securityButton))
        }
    }

    func testConfigureBarsSplitShowsOnlyAddButton() {
        withInterfaceType(.split, useYubikey: true) {
            let controller = LastChatsViewController()
            controller.configureBars()

            let rightItems = navigationBarItems(controller.navigationItem.rightBarButtonItems,
                                               controller.navigationItem.rightBarButtonItem)

            XCTAssertEqual(rightItems.count, 1)
            XCTAssertFalse(rightItems.contains(controller.securityButton))
        }
    }

    func testUpdateTitleAlwaysShowsChats() {
        let controller = LastChatsViewController()
        let expected = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])

        controller.updateTitle(.unread)
        XCTAssertEqual(controller.title, expected)

        controller.updateTitle(.archived)
        XCTAssertEqual(controller.title, expected)

        controller.updateTitle(.saved)
        XCTAssertEqual(controller.title, expected)
    }

    func testRootLargeTitleFollowsCommonConfig() {
        assertLargeTitle(useLargeTitle: true)
        assertLargeTitle(useLargeTitle: false)
    }

    func testFloatingBottomBarTitleShowsMarkAllAsReadAction() {
        let controller = LastChatsViewController()

        XCTAssertEqual(
            controller.floatingBottomBarTitle,
            "Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: [])
        )
    }

    func testLastChatsUsesGeometryBasedBottomOverlayInsetCoordinator() {
        let controller = LastChatsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()

        controller.updateTableInsetsForFloatingToolbar()

        XCTAssertGreaterThan(controller.bottomOverlayInsetCoordinator.appliedBottomContribution, 0)
        XCTAssertEqual(
            controller.tableView.contentInset.bottom,
            controller.bottomOverlayInsetCoordinator.appliedBottomContribution,
            accuracy: 0.001
        )
    }

    func testZeroUnreadHidesUnreadActionsWithoutMovingSearchButton() {
        let controller = LastChatsViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.loadViewIfNeeded()
        AccountManager.shared.connectingUsers.accept([])

        controller.updateUnreadChatsCounter(count: 1)
        controller.view.layoutIfNeeded()
        let searchFrameWithActions = controller.bottomSearchHostView.collapsedButton.convert(
            controller.bottomSearchHostView.collapsedButton.bounds,
            to: controller.view
        )

        controller.updateUnreadChatsCounter(count: 0)
        controller.view.layoutIfNeeded()
        let searchFrameWithoutActions = controller.bottomSearchHostView.collapsedButton.convert(
            controller.bottomSearchHostView.collapsedButton.bounds,
            to: controller.view
        )

        XCTAssertTrue(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.markAllReadButton.isHidden)
        XCTAssertEqual(searchFrameWithoutActions, searchFrameWithActions)
    }

    func testUnreadChatsShowFilterAndMarkAllActions() {
        let controller = LastChatsViewController()
        AccountManager.shared.connectingUsers.accept([])

        controller.updateUnreadChatsCounter(count: 1)

        XCTAssertFalse(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertFalse(controller.markAllReadButton.isHidden)
        XCTAssertTrue(controller.floatingBottomBarFilterButton.isEnabled)
        XCTAssertTrue(controller.markAllReadButton.isEnabled)
    }

    func testConnectingAccountHidesOnlyMarkAllAction() {
        withConnectingAccount { controller, ownerJid in
            AccountManager.shared.connectingUsers.accept([ownerJid])

            controller.updateUnreadChatsCounter(count: 1)

            XCTAssertFalse(controller.floatingBottomBarFilterButton.isHidden)
            XCTAssertTrue(controller.markAllReadButton.isHidden)
        }
    }

    func testDisconnectedAccountRestoresMarkAllAction() {
        withConnectingAccount { controller, ownerJid in
            AccountManager.shared.connectingUsers.accept([ownerJid])
            controller.updateUnreadChatsCounter(count: 1)

            AccountManager.shared.connectingUsers.accept([])
            controller.updateUnreadChatsCounter(count: 1)

            XCTAssertFalse(controller.floatingBottomBarFilterButton.isHidden)
            XCTAssertFalse(controller.markAllReadButton.isHidden)
            XCTAssertTrue(controller.markAllReadButton.isEnabled)
        }
    }

    func testUnreadFilterReturnsToChatsWhenLastUnreadDisappears() {
        let controller = LastChatsViewController()
        AccountManager.shared.connectingUsers.accept([])
        controller.updateUnreadChatsCounter(count: 1)
        controller.filter.accept(.unread)

        controller.updateUnreadChatsCounter(count: 0)

        XCTAssertEqual(controller.filter.value, .chats)
        XCTAssertEqual(controller.normalState, .chats)
        XCTAssertTrue(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.markAllReadButton.isHidden)
    }

    func testMarkAllReturnsUnreadFilterToChatsWhenNoUnreadTargetsRemain() {
        let controller = LastChatsViewController()
        AccountManager.shared.connectingUsers.accept([])
        controller.updateUnreadChatsCounter(count: 1)
        controller.filter.accept(.unread)

        controller.onTitleBarButtonTapped()

        XCTAssertEqual(controller.filter.value, .chats)
        XCTAssertTrue(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.markAllReadButton.isHidden)
    }

    func testSearchQueryDoesNotChangeUnreadActionAvailability() {
        let controller = LastChatsViewController()
        AccountManager.shared.connectingUsers.accept([])
        controller.updateUnreadChatsCounter(count: 1)
        let visibilityBeforeQuery = unreadActionVisibility(of: controller)

        controller.bottomSearchHostView.setQuery("needle", notify: true)
        controller.updateFloatingToolbarFilterButtonState()

        XCTAssertEqual(unreadActionVisibility(of: controller), visibilityBeforeQuery)
    }

    func testArchivedRouteIsSearchOnlyEvenWhenUnreadChatsExist() {
        let controller = LastChatsViewController()
        controller.filter.accept(.archived)

        controller.updateUnreadChatsCounter(count: 1)

        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        XCTAssertTrue(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.markAllReadButton.isHidden)
        XCTAssertFalse(controller.bottomSearchHostView.isHidden)
    }

    func testSavedRouteIsSearchOnlyEvenWhenUnreadChatsExist() {
        let controller = LastChatsViewController()
        controller.filter.accept(.saved)

        controller.updateUnreadChatsCounter(count: 1)

        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        XCTAssertTrue(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.markAllReadButton.isHidden)
        XCTAssertFalse(controller.bottomSearchHostView.isHidden)
    }

    func testRouteWithoutBottomActionsRemainsSearchOnly() {
        let controller = LastChatsViewController()
        controller.shouldShowBottomBar = false

        controller.updateUnreadChatsCounter(count: 1)

        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        XCTAssertTrue(controller.floatingBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.markAllReadButton.isHidden)
        XCTAssertFalse(controller.bottomSearchHostView.isHidden)
    }

    func testLastChatContentEndsAboveCollapsedSearchButtonAtMaximumOffset() {
        let controller = LastChatsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.updateUnreadChatsCounter(count: 0)
        controller.view.layoutIfNeeded()
        controller.tableView.contentSize = CGSize(width: 393, height: 1_600)
        controller.updateTableInsetsForFloatingToolbar()

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

    func testBottomSearchExpansionHidesActionBarOnlyAfterMorphAndRestoresItBeforeCollapse() throws {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.bottomSearchHostView.animatorFactory = { _, curve in
            UIViewPropertyAnimator(duration: 10, curve: curve)
        }

        XCTAssertFalse(controller.isFloatingBottomBarHidden)

        controller.bottomSearchHostView.collapsedButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .expanding)
        XCTAssertFalse(controller.isFloatingBottomBarHidden)
        let expansionAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        expansionAnimator.pauseAnimation()
        expansionAnimator.stopAnimation(false)
        expansionAnimator.finishAnimation(at: .end)

        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .expanded)
        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        XCTAssertFalse(controller.bottomSearchHostView.surfaceView.isHidden)

        controller.bottomSearchHostView.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .collapsing)
        XCTAssertFalse(controller.isFloatingBottomBarHidden)
        let collapseAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        collapseAnimator.pauseAnimation()
        collapseAnimator.stopAnimation(false)
        collapseAnimator.finishAnimation(at: .end)

        XCTAssertEqual(controller.bottomSearchHostView.transitionPhase, .collapsed)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
    }

    func testSavedRouteKeepsActionBarHiddenAcrossSearchMorph() throws {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.filter.accept(.saved)
        controller.bottomSearchPresentationStateDidChange()
        controller.bottomSearchHostView.animatorFactory = { _, curve in
            UIViewPropertyAnimator(duration: 10, curve: curve)
        }

        XCTAssertTrue(controller.isFloatingBottomBarHidden)

        controller.bottomSearchHostView.collapsedButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        let expansionAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        expansionAnimator.pauseAnimation()
        expansionAnimator.stopAnimation(false)
        expansionAnimator.finishAnimation(at: .end)
        XCTAssertTrue(controller.isFloatingBottomBarHidden)

        controller.bottomSearchHostView.cancelButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        let collapseAnimator = try XCTUnwrap(controller.bottomSearchHostView.transitionAnimator)
        collapseAnimator.pauseAnimation()
        collapseAnimator.stopAnimation(false)
        collapseAnimator.finishAnimation(at: .end)
        XCTAssertTrue(controller.isFloatingBottomBarHidden)
    }

    func testBottomSearchCollapsedPassesHitsToLastChatsActionButtons() {
        let controller = LastChatsViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.loadViewIfNeeded()
        controller.updateUnreadChatsCounter(count: 1)
        controller.view.layoutIfNeeded()

        let filterButton = controller.floatingBottomBarFilterButton
        let markAllButton = controller.markAllReadButton
        let filterPoint = controller.view.convert(
            CGPoint(x: filterButton.bounds.midX, y: filterButton.bounds.midY),
            from: filterButton
        )
        let markAllPoint = controller.view.convert(
            CGPoint(x: markAllButton.bounds.midX, y: markAllButton.bounds.midY),
            from: markAllButton
        )

        XCTAssertTrue(controller.view.hitTest(filterPoint, with: nil) === filterButton)
        XCTAssertTrue(controller.view.hitTest(markAllPoint, with: nil) === markAllButton)
    }

    func testChatSearchMapsGroupMessagesIntoMessageResults() throws {
        let owner = "owner@example.com"
        let groupJid = "group@example.com"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(jid: groupJid, owner: owner, conversationType: .group)
        chat.owner = owner
        chat.jid = groupJid
        chat.conversationType = .group

        let message = MessageStorageItem()
        message.primary = "group-message-primary"
        message.owner = owner
        message.opponent = groupJid
        message.conversationType = .group
        message.body = "group search needle"
        message.date = Date(timeIntervalSince1970: 10)
        message.archivedId = "archive-group-message"

        try realm.write {
            realm.add(chat, update: .modified)
            realm.add(message, update: .modified)
        }

        let updater = ChatSearchResultsController()
        try updater.replaceMessageStorageItemsForTesting([message])

        XCTAssertEqual(updater.numberOfSections(), 1)
        XCTAssertEqual(updater.titleForHeader(in: 0), "Messages".localizeString(id: "groupchat_member_messages", arguments: []))
        let result = try XCTUnwrap(updater.item(at: IndexPath(row: 0, section: 0)))
        XCTAssertEqual(result.jid, groupJid)
        XCTAssertEqual(result.conversationType, .group)
        XCTAssertEqual(result.entity, .groupchat)
        XCTAssertEqual(result.messageArchiveId, "archive-group-message")
    }

    func testMarkAllAsReadTargetsOnlyUnreadNonArchivedEnabledChats() {
        let targets = LastChatsViewController.unreadChatReadTargets(
            from: [
                .init(
                    owner: "enabled@example.com",
                    jid: "unread@example.com",
                    conversationType: .regular,
                    isArchived: false,
                    unread: 2,
                    lastMessagePrimary: "primary-1",
                    lastMessageId: "message-1"
                ),
                .init(
                    owner: "enabled@example.com",
                    jid: "read@example.com",
                    conversationType: .regular,
                    isArchived: false,
                    unread: 0,
                    lastMessagePrimary: "primary-2",
                    lastMessageId: "message-2"
                ),
                .init(
                    owner: "enabled@example.com",
                    jid: "archived@example.com",
                    conversationType: .regular,
                    isArchived: true,
                    unread: 3,
                    lastMessagePrimary: "primary-3",
                    lastMessageId: "message-3"
                ),
                .init(
                    owner: "disabled@example.com",
                    jid: "disabled@example.com",
                    conversationType: .regular,
                    isArchived: false,
                    unread: 1,
                    lastMessagePrimary: "primary-4",
                    lastMessageId: "message-4"
                ),
                .init(
                    owner: "enabled@example.com",
                    jid: "fallback@example.com",
                    conversationType: .omemo,
                    isArchived: false,
                    unread: 1,
                    lastMessagePrimary: nil,
                    lastMessageId: "server-last-id"
                )
            ],
            enabledAccounts: ["enabled@example.com"]
        )

        XCTAssertEqual(
            targets,
            [
                .init(
                    owner: "enabled@example.com",
                    messageTarget: .init(
                        jid: "unread@example.com",
                        conversationType: .regular,
                        lastMessagePrimary: "primary-1",
                        lastMessageId: "message-1"
                    )
                ),
                .init(
                    owner: "enabled@example.com",
                    messageTarget: .init(
                        jid: "fallback@example.com",
                        conversationType: .omemo,
                        lastMessagePrimary: nil,
                        lastMessageId: "server-last-id"
                    )
                )
            ]
        )
    }

    func testReconfigureVisibleRowAppliesImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com", message: "old")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))

        let wasReconfigured = controller.reconfigureVisibleRow(at: IndexPath(row: 0, section: 0))

        XCTAssertTrue(wasReconfigured)
    }

    func testReloadTableViewOrDeferReloadsImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.setSelectedChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType, animated: false)

        controller.reloadTableViewOrDeferForActiveSwipe()

        XCTAssertEqual(controller.tableView.indexPathForSelectedRow, indexPath)
    }

    func testCompactChatReturnClearsSelectedChatRow() throws {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        controller.setSelectedChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType, animated: false)

        XCTAssertEqual(controller.tableView.indexPathForSelectedRow, indexPath)
        XCTAssertTrue(controller.isSelectedChat(item))

        controller.clearSelectedChatSelectionOnReturnIfNeeded(route: .currentNavigationPush, animated: false)

        XCTAssertNil(controller.tableView.indexPathForSelectedRow)
        XCTAssertFalse(controller.isSelectedChat(item))
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: indexPath) as? ChatListTableViewCell)
        XCTAssertEqual(cell.backgroundColor, .systemBackground)
    }

    func testSplitDetailChatReturnKeepsSelectedChatRow() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        controller.setSelectedChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType, animated: false)

        controller.clearSelectedChatSelectionOnReturnIfNeeded(route: .splitDetailReplacement, animated: false)

        XCTAssertEqual(controller.tableView.indexPathForSelectedRow, indexPath)
        XCTAssertTrue(controller.isSelectedChat(item))
    }

    func testApplyReplacementUpdatesExecutesImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: oldSections, showsSkeleton: false)
        controller.tableView.reloadData()

        let changes = ChangesWithIndexPath(
            inserts: [],
            deletes: [],
            replaces: [indexPath],
            moves: []
        )
        controller.applyReplacementUpdates(
            changes: changes,
            oldSections: oldSections,
            newSections: oldSections,
            reloads: [indexPath],
            reconfigures: []
        )

        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
    }

    func testApplyStructuralUpdatesRunImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let newSections: [LastChatsViewController.DatasourceSection] = []
        let done = expectation(description: "apply structural updates applied")
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: oldSections, showsSkeleton: false)
        controller.tableView.reloadData()

        let changes = ChangesWithIndexPath(
            insertedSections: [],
            deletedSections: [0],
            inserts: [],
            deletes: [],
            replaces: [],
            moves: []
        )

        controller.apply(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: false,
            newShowsSkeleton: false,
            prepare: {
                controller.setDatasource([], sections: newSections, showsSkeleton: false)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)

        XCTAssertTrue(controller.datasource.isEmpty)
    }

    func testQuietModeStructuralChangesUseReloadFallback() {
        let structural = ChangesWithIndexPath(
            inserts: [IndexPath(row: 0, section: 0)],
            deletes: [],
            replaces: [],
            moves: []
        )
        let replacementOnly = ChangesWithIndexPath(
            inserts: [],
            deletes: [],
            replaces: [IndexPath(row: 0, section: 0)],
            moves: []
        )

        XCTAssertTrue(
            LastChatsViewController.shouldReloadStructuralTableChanges(
                structural,
                isQuietModeActive: true
            )
        )
        XCTAssertFalse(
            LastChatsViewController.shouldReloadStructuralTableChanges(
                structural,
                isQuietModeActive: false
            )
        )
        XCTAssertFalse(
            LastChatsViewController.shouldReloadStructuralTableChanges(
                replacementOnly,
                isQuietModeActive: true
            )
        )
    }

    func testApplyQuietModeStructuralUpdatesReloadsTable() {
        let controller = LastChatsViewController()
        let oldItem = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let newItem = makeDatasource(jid: "juliet@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [oldItem], showsSkeleton: false)
        let newSections = LastChatsViewController.makeDatasourceSections(from: [oldItem, newItem], showsSkeleton: false)
        let staleVisibleSections = LastChatsViewController.makeDatasourceSections(from: [], showsSkeleton: false)
        let done = expectation(description: "quiet mode structural reload applied")
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([], sections: staleVisibleSections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.beginLeftMenuFirstPresentationQuietMode()

        let changes = LastChatsViewController.sectionedChanges(
            oldSections: oldSections,
            newSections: newSections
        )

        controller.apply(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: false,
            newShowsSkeleton: false,
            prepare: {
                controller.setDatasource([oldItem, newItem], sections: newSections, showsSkeleton: false)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)

        XCTAssertEqual(controller.datasource.map(\.jid), ["romeo@example.com", "juliet@example.com"])
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 2)
    }

    func testApplyWithDisconnectedTableViewUpdatesDatasourceWithoutBatching() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [], showsSkeleton: false)
        let newSections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let done = expectation(description: "disconnected table update applied")
        XCTAssertNil(controller.tableView.dataSource)

        let changes = LastChatsViewController.sectionedChanges(
            oldSections: oldSections,
            newSections: newSections
        )

        controller.apply(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: false,
            newShowsSkeleton: false,
            prepare: {
                controller.setDatasource([item], sections: newSections, showsSkeleton: false)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)

        XCTAssertEqual(controller.datasource.map(\.jid), ["romeo@example.com"])
        XCTAssertNil(controller.tableView.dataSource)
    }

    func testChatListCellUsesCachedAvatarSynchronously() {
        let avatarURL = "https://example.com/chat-avatar-\(UUID().uuidString).png"
        let cachedImage = makeSolidAvatarImage(color: .systemPurple)
        DefaultAvatarManager.shared.storeImage(for: avatarURL, image: cachedImage)
        let cell = ChatListTableViewCell(style: .default, reuseIdentifier: ChatListTableViewCell.cellName)

        cell.configure(
            "romeo@example.com",
            owner: "owner@example.com",
            username: "Romeo",
            attributedUsername: nil,
            message: "Hello",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            deliveryState: nil,
            isMute: false,
            isSynced: true,
            isGroupchat: false,
            status: .online,
            entity: .contact,
            conversationType: .regular,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: false,
            indicator: .clear,
            isDraft: false,
            isAttachment: false,
            groupchatNickname: nil,
            isSystem: false,
            isPinned: false,
            subRequest: false,
            avatarUrl: avatarURL,
            hasErrorInChat: false,
            verAction: false
        )

        assertImage(cell.avatarView.image, matches: cachedImage)
    }

    func testLastChatPreviewUsesItalicLocationLabelInsteadOfGeoFallback() {
        let message = MessageStorageItem()
        message.body = "geo:51.5007,-0.1246"
        message.legacyBody = message.body
        let reference = MessageReferenceStorageItem()
        reference.kind = .geoloc
        reference.url = message.body
        reference.metadata = [
            "lat": 51.5007,
            "lon": -0.1246,
            "uri": message.body
        ]
        message.references.append(reference)

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(preview.text, MessageStorageItem.locationDisplayText)
        XCTAssertTrue(preview.isItalic)
    }

    func testLastChatPreviewUsesItalicContactLabelWithNicknameBeforeFallbackBody() {
        let message = MessageStorageItem()
        message.body = "Alice Capulet (alice@example.com)"
        message.legacyBody = message.body
        let reference = MessageReferenceStorageItem()
        reference.kind = .contact
        reference.metadata = [
            "contact_jid": "alice@example.com",
            "nickname": "Ally",
            "given": "Alice",
            "family": "Capulet"
        ]
        message.references.append(reference)

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(
            preview.text,
            "Contact: %@".localizeString(id: "recent_chat__last_message__contact", arguments: ["Ally"])
        )
        XCTAssertTrue(preview.isItalic)
    }

    func testLastChatPreviewUsesContactFullNameWhenNicknameIsMissing() {
        let message = MessageStorageItem()
        message.body = "Alice Capulet (alice@example.com)"
        message.legacyBody = message.body
        let reference = MessageReferenceStorageItem()
        reference.kind = .contact
        reference.metadata = [
            "contact_jid": "alice@example.com",
            "given": "Alice",
            "family": "Capulet"
        ]
        message.references.append(reference)

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(
            preview.text,
            "Contact: %@".localizeString(id: "recent_chat__last_message__contact", arguments: ["Alice Capulet"])
        )
        XCTAssertTrue(preview.isItalic)
    }

    func testListOnlySynchronizationPreviewReplacesBlankChatListFallback() throws {
        let projection = LastChatListSyncPreviewProjection(
            owner: "owner@example.com",
            conversationPrimary: "chat-primary",
            lastMessageID: "sync-message-1",
            text: "Preview received from synchronization"
        )

        let preview = LastChatMessagePreviewPolicy.preview(
            for: nil,
            synchronizedProjection: projection,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(
            preview.text,
            "Preview received from synchronization"
        )
        XCTAssertFalse(preview.isItalic)
    }

    func testListOnlySynchronizationSystemEventRemainsItalic() {
        let projection = LastChatListSyncPreviewProjection(
            owner: "owner@example.com",
            conversationPrimary: "chat-primary",
            lastMessageID: "sync-system-message",
            text: "System message",
            isSystemMessage: true
        )

        let preview = LastChatMessagePreviewPolicy.preview(
            for: nil,
            synchronizedProjection: projection,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(preview.text, "System message")
        XCTAssertTrue(preview.isItalic)
    }

    func testMaterializedLastMessageTakesPrecedenceOverSynchronizationPreview() {
        let message = MessageStorageItem()
        message.body = "Materialized preview"
        message.legacyBody = message.body
        let projection = LastChatListSyncPreviewProjection(
            owner: "owner@example.com",
            conversationPrimary: "chat-primary",
            lastMessageID: "sync-message-1",
            text: "Synchronization preview"
        )

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            synchronizedProjection: projection,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(preview.text, "Materialized preview")
    }

    func testListOnlyDirectForwardPreviewMatchesMaterializedForwardBeforeNestedMedia() throws {
        let materialized = makeMaterializedForwardPreviewMessage(
            nicknames: ["Alice"]
        )
        let materializedPreview = LastChatMessagePreviewPolicy.preview(
            for: materialized,
            blankMessageText: "Start messaging here"
        )
        let synchronizedPreview = try XCTUnwrap(
            LastChatListSyncPreviewParser.projection(
                owner: "owner@example.com",
                conversationPrimary: "sync-forward",
                lastMessageID: "sync-forward-message",
                messageElement: makeSyncForwardPreviewMessageWithNestedPhoto()
            )
        )

        XCTAssertEqual(
            synchronizedPreview.text,
            "Forwarded message".localizeString(
                id: "chat_message_forwarded_message",
                arguments: []
            )
        )
        XCTAssertEqual(synchronizedPreview.text, materializedPreview.text)
        XCTAssertFalse(
            synchronizedPreview.isAttachment,
            "Nested media belongs to the forwarded payload, not to the outer chat-list row."
        )
    }

    func testMaterializedMultipleForwardPreviewUsesForwardCount() {
        let message = makeMaterializedForwardPreviewMessage(
            nicknames: ["Alice", "Bob", "Carol"]
        )

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(
            preview.text,
            "%@ forwarded messages".localizeString(
                id: "chat_message_some_forwarded_messages",
                arguments: ["3"]
            )
        )
    }

    func testMaterializedAttachmentPreviewsUseTypedSingularAndPluralLabels() {
        let cases: [(LastChatsPreviewAttachmentKind, Int, String)] = [
            (.photo, 1, "Photo"),
            (.photo, 3, "3 Photos"),
            (.video, 1, "Video"),
            (.video, 3, "3 Videos"),
            (.file, 1, "File"),
            (.file, 3, "3 Files"),
            (.voice, 1, "Voice message"),
            (.voice, 3, "3 Voice messages")
        ]

        for (kind, count, expected) in cases {
            let preview = LastChatMessagePreviewPolicy.preview(
                for: makeMaterializedAttachmentPreviewMessage(
                    kind: kind,
                    count: count
                ),
                blankMessageText: "Start messaging here"
            )

            XCTAssertEqual(
                preview.text,
                expected,
                "Unexpected materialized Last Chats preview for \(kind) x\(count)."
            )
            XCTAssertFalse(
                preview.isItalic,
                "An ordinary attachment sent by a participant is not a system event."
            )
        }
    }

    func testListOnlySyncAttachmentPreviewsUseTypedSingularAndPluralLabels() throws {
        let cases: [(LastChatsPreviewAttachmentKind, Int, String)] = [
            (.photo, 1, "Photo"),
            (.photo, 3, "3 Photos"),
            (.video, 1, "Video"),
            (.video, 3, "3 Videos"),
            (.file, 1, "File"),
            (.file, 3, "3 Files"),
            (.voice, 1, "Voice message"),
            (.voice, 3, "3 Voice messages")
        ]

        for (kind, count, expected) in cases {
            let projection = try XCTUnwrap(
                LastChatListSyncPreviewParser.projection(
                    owner: "owner@example.com",
                    conversationPrimary: "sync-\(kind)-\(count)",
                    lastMessageID: "sync-message-\(kind)-\(count)",
                    messageElement: makeSyncAttachmentPreviewMessage(
                        kind: kind,
                        count: count
                    )
                )
            )

            XCTAssertEqual(
                projection.text,
                expected,
                "The list-only projection must not surface the attachment fallback URL for \(kind) x\(count)."
            )
            XCTAssertTrue(projection.isAttachment)
            XCTAssertFalse(
                projection.isSystemMessage,
                "An ordinary synchronized attachment is not a group/system event."
            )
        }
    }

    func testEnglishAttachmentPreviewKeepsSingularContractAndCountsTwentyOne() {
        let cases: [(LastChatAttachmentPreviewKind, String, String)] = [
            (.photo, "Photo", "21 Photos"),
            (.video, "Video", "21 Videos"),
            (.file, "File", "21 Files"),
            (.voice, "Voice message", "21 Voice messages")
        ]

        for (kind, singular, counted) in cases {
            XCTAssertEqual(
                LastChatAttachmentPreviewFormatter.text(
                    for: Array(repeating: kind, count: 1)
                ),
                singular
            )
            XCTAssertEqual(
                LastChatAttachmentPreviewFormatter.text(
                    for: Array(repeating: kind, count: 21)
                ),
                counted
            )
        }
    }

    func testRussianAttachmentPreviewIncludesCountForTwentyOneEndingForms() {
        TranslationsManager.shared.currentLang =
            TranslationsManager.Languages.ru.rawValue
        let cases: [(LastChatAttachmentPreviewKind, String, String)] = [
            (.photo, "Фото", "фото"),
            (.video, "Видео", "видео"),
            (.file, "Файл", "файл"),
            (.voice, "Голосовое сообщение", "голосовое сообщение")
        ]

        for (kind, singular, countedNoun) in cases {
            XCTAssertEqual(
                LastChatAttachmentPreviewFormatter.text(
                    for: Array(repeating: kind, count: 1)
                ),
                singular
            )
            for count in [21, 31, 101] {
                XCTAssertEqual(
                    LastChatAttachmentPreviewFormatter.text(
                        for: Array(repeating: kind, count: count)
                    ),
                    "\(count) \(countedNoun)"
                )
            }
        }
    }

    func testAttachmentCaptionWinsOverTypedLabelAndFallbackURLInBothPreviewPaths() throws {
        let caption = "Trip caption"
        let materialized = LastChatMessagePreviewPolicy.preview(
            for: makeMaterializedAttachmentPreviewMessage(
                kind: .photo,
                count: 3,
                caption: caption
            ),
            blankMessageText: "Start messaging here"
        )
        let synchronized = try XCTUnwrap(
            LastChatListSyncPreviewParser.projection(
                owner: "owner@example.com",
                conversationPrimary: "sync-caption",
                lastMessageID: "sync-caption-message",
                messageElement: makeSyncAttachmentPreviewMessage(
                    kind: .photo,
                    count: 3,
                    caption: caption
                )
            )
        )

        XCTAssertEqual(materialized.text, caption)
        XCTAssertEqual(synchronized.text, caption)
        XCTAssertFalse(synchronized.text.contains("https://"))
        XCTAssertFalse(materialized.isItalic)
        XCTAssertFalse(synchronized.isSystemMessage)
    }

    func testMaterializedAttachmentPreviewExcludesLocallyHiddenReferencesFromCount() {
        let preview = LastChatMessagePreviewPolicy.preview(
            for: makeMaterializedAttachmentPreviewMessage(
                kind: .photo,
                count: 4,
                hiddenIndexes: [1]
            ),
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(preview.text, "3 Photos")
        XCTAssertFalse(preview.isItalic)
    }

    func testOrdinaryGroupAttachmentDatasourceDoesNotBecomeSystemPreview() throws {
        let owner = "group-preview-owner@example.com"
        let groupJID = "stage@example.com"
        let message = makeMaterializedAttachmentPreviewMessage(
            kind: .photo,
            count: 1
        )
        message.primary = "group-preview-message"
        message.messageId = "group-preview-message-id"
        message.owner = owner
        message.opponent = groupJID
        message.conversationType = .group
        message.date = Date(timeIntervalSince1970: 100)
        let participant = MessageReferenceStorageItem()
        participant.primary = "group-preview-participant"
        participant.kind = .groupchat
        participant.owner = owner
        participant.jid = groupJID
        participant.metadata = [
            "id": "member-42",
            "jid": "alice@example.com",
            "nickname": "Alice"
        ]
        message.references.insert(participant, at: 0)

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: groupJID,
            owner: owner,
            conversationType: .group
        )
        chat.owner = owner
        chat.jid = groupJID
        chat.conversationType = .group
        chat.messageDate = message.date
        chat.lastMessageId = message.messageId
        chat.lastMessage = message

        let realm = try WRealm.safe()
        try realm.write {
            realm.add(message, update: .modified)
            realm.add(chat, update: .modified)
        }

        let controller = LastChatsViewController()
        controller.enabledAccounts.accept([owner])
        controller.showSkeleton.accept(false)
        controller.runDatasetUpdateTask()

        XCTAssertTrue(waitForLastChatsDataset(controller, containing: groupJID))
        let datasource = try XCTUnwrap(
            controller.datasource.first(where: { $0.jid == groupJID })
        )
        XCTAssertEqual(datasource.userNickname, "Alice")
        XCTAssertEqual(datasource.userColorKey, "member-42")
        XCTAssertFalse(
            datasource.isSystemMessage,
            "An attachment-only participant message must keep normal body typography."
        )
    }

    func testMaterializedForwardDatasourcePreservesForwardNickname() throws {
        let owner = "forward-preview-owner@example.com"
        let groupJID = "forward-stage@example.com"
        let message = makeMaterializedForwardPreviewMessage(
            nicknames: ["Alice", "Bob"]
        )
        message.primary = "forward-preview-message"
        message.messageId = "forward-preview-message-id"
        message.owner = owner
        message.opponent = groupJID
        message.conversationType = .group
        message.date = Date(timeIntervalSince1970: 100)
        message.inlineForwards.forEach {
            $0.owner = owner
            $0.jid = groupJID
            $0.opponent = groupJID
        }

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: groupJID,
            owner: owner,
            conversationType: .group
        )
        chat.owner = owner
        chat.jid = groupJID
        chat.conversationType = .group
        chat.messageDate = message.date
        chat.lastMessageId = message.messageId
        chat.lastMessage = message

        let realm = try WRealm.safe()
        try realm.write {
            realm.add(message, update: .modified)
            realm.add(chat, update: .modified)
        }

        let controller = LastChatsViewController()
        controller.enabledAccounts.accept([owner])
        controller.showSkeleton.accept(false)
        controller.runDatasetUpdateTask()

        XCTAssertTrue(waitForLastChatsDataset(controller, containing: groupJID))
        let datasource = try XCTUnwrap(
            controller.datasource.first(where: { $0.jid == groupJID })
        )
        XCTAssertEqual(datasource.userNickname, "Alice")
    }

    func testListOnlyGroupProjectionSuppliesAuthorToLastChatsWithoutMaterializedMessage() throws {
        let owner = "group-list-preview-owner@example.com"
        let groupJID = "stage-list-only@example.com"
        let primary = LastChatsStorageItem.genPrimary(
            jid: groupJID,
            owner: owner,
            conversationType: .group
        )
        let chat = LastChatsStorageItem()
        chat.primary = primary
        chat.owner = owner
        chat.jid = groupJID
        chat.conversationType = .group
        chat.messageDate = Date(timeIntervalSince1970: 100)
        chat.lastMessageId = "group-list-message-1"

        let realm = try WRealm.safe()
        try realm.write {
            realm.add(chat, update: .modified)
        }
        LastChatListSyncPreviewStore.shared.apply(
            [
                .upsert(
                    LastChatListSyncPreviewProjection(
                        owner: owner,
                        conversationPrimary: primary,
                        lastMessageID: chat.lastMessageId,
                        text: "Photo",
                        isAttachment: true,
                        groupchatNickname: "Alice",
                        groupchatAuthorColorKey: "member-42"
                    )
                )
            ],
            for: owner
        )
        defer {
            LastChatListSyncPreviewStore.shared.removeAll(for: owner)
        }

        let controller = LastChatsViewController()
        controller.enabledAccounts.accept([owner])
        controller.showSkeleton.accept(false)
        controller.runDatasetUpdateTask()

        XCTAssertTrue(waitForLastChatsDataset(controller, containing: groupJID))
        let datasource = try XCTUnwrap(
            controller.datasource.first(where: { $0.jid == groupJID })
        )
        XCTAssertEqual(datasource.userNickname, "Alice")
        XCTAssertEqual(datasource.userColorKey, "member-42")
        XCTAssertFalse(datasource.isSystemMessage)

        let cell = ChatListTableViewCell(
            style: .default,
            reuseIdentifier: ChatListTableViewCell.cellName
        )
        controller.configureChatCell(cell, with: datasource)
        XCTAssertEqual(cell.subtitleLabel.text, "Alice")
        XCTAssertTrue(
            cell.subtitleLabel.textColor.isEqual(
                ChatViewController.getUsernamePalette(for: "member-42").tint500
            )
        )
        let body = try XCTUnwrap(cell.messageLabel.attributedText)
        let attributes = body.attributes(at: 0, effectiveRange: nil)
        let font = try XCTUnwrap(attributes[.font] as? UIFont)
        XCTAssertFalse(
            font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        )
    }

    func testGroupParticipantNicknameUsesParticipantColorWhileBodyKeepsNormalStyle() throws {
        let cell = ChatListTableViewCell(
            style: .default,
            reuseIdentifier: ChatListTableViewCell.cellName
        )
        let participantNickname = "Alice"
        let participantColorKey = "member-42"

        cell.configure(
            "stage@example.com",
            owner: "owner@example.com",
            username: "Stage",
            attributedUsername: nil,
            message: "Photo",
            date: Date(timeIntervalSince1970: 100),
            deliveryState: nil,
            isMute: false,
            isSynced: true,
            isGroupchat: true,
            status: .offline,
            entity: .groupchat,
            conversationType: .group,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: false,
            indicator: .clear,
            isDraft: false,
            isAttachment: true,
            groupchatNickname: participantNickname,
            groupchatAuthorColorKey: participantColorKey,
            isSystem: false,
            isPinned: false,
            subRequest: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            verAction: false
        )

        XCTAssertEqual(cell.subtitleLabel.text, participantNickname)
        XCTAssertTrue(
            cell.subtitleLabel.textColor.isEqual(
                ChatViewController.getUsernamePalette(for: participantColorKey).tint500
            )
        )
        XCTAssertFalse(try XCTUnwrap(cell.subtitleLabel.font).fontDescriptor.symbolicTraits.contains(.traitItalic))

        let body = try XCTUnwrap(cell.messageLabel.attributedText)
        let bodyAttributes = body.attributes(at: 0, effectiveRange: nil)
        let bodyFont = try XCTUnwrap(bodyAttributes[.font] as? UIFont)
        let bodyColor = (bodyAttributes[.foregroundColor] as? UIColor)
            ?? cell.messageLabel.textColor
        XCTAssertFalse(bodyFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(bodyColor?.isEqual(UIColor.secondaryLabel) == true)
    }

    func testColdListPreviewResolverUsesExactDurableMessageWithoutRealmWrites() throws {
        let owner = "cold-preview-owner@example.com"
        let jid = "cold-preview-chat@example.com"
        let expectedArchiveID = "1784280770721455"
        let realm = try WRealm.safe()
        try realm.write {
            let chat = LastChatsStorageItem()
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = .regular
            chat.setPrimary(withOwner: owner)
            chat.lastMessageId = expectedArchiveID
            realm.add(chat)

            let exact = MessageStorageItem()
            exact.primary = "cold-preview-exact"
            exact.owner = owner
            exact.opponent = jid
            exact.conversationType = .regular
            exact.messageId = "local-origin-id"
            exact.archivedId = expectedArchiveID
            exact.body = "Durable local preview"
            exact.date = Date(timeIntervalSince1970: 200)
            realm.add(exact)

            let wrongConversation = MessageStorageItem()
            wrongConversation.primary = "cold-preview-wrong-conversation"
            wrongConversation.owner = owner
            wrongConversation.opponent = "other-chat@example.com"
            wrongConversation.conversationType = .regular
            wrongConversation.messageId = "wrong-conversation-origin-id"
            wrongConversation.archivedId = expectedArchiveID
            wrongConversation.body = "Wrong conversation"
            wrongConversation.date = Date(timeIntervalSince1970: 300)
            realm.add(wrongConversation)

            let wrongType = MessageStorageItem()
            wrongType.primary = "cold-preview-wrong-type"
            wrongType.owner = owner
            wrongType.opponent = jid
            wrongType.conversationType = .group
            wrongType.messageId = "wrong-type-origin-id"
            wrongType.archivedId = expectedArchiveID
            wrongType.body = "Wrong type"
            wrongType.date = Date(timeIntervalSince1970: 400)
            realm.add(wrongType)
        }

        let chat = try XCTUnwrap(realm.objects(LastChatsStorageItem.self).first)
        let messageCountBeforeResolution = realm.objects(MessageStorageItem.self).count

        let resolved = LastChatMaterializedPreviewResolver.resolve(
            in: realm,
            for: [chat]
        )

        XCTAssertEqual(resolved[chat.primary]?.primary, "cold-preview-exact")
        XCTAssertEqual(resolved[chat.primary]?.body, "Durable local preview")
        XCTAssertNil(chat.lastMessage)
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self).count,
            messageCountBeforeResolution
        )
    }

    func testColdListPreviewResolverMatchesMessageIDAndRejectsMissingIdentity() throws {
        let owner = "cold-preview-message-id-owner@example.com"
        let jid = "cold-preview-message-id-chat@example.com"
        let realm = try WRealm.safe()
        try realm.write {
            let matchingChat = LastChatsStorageItem()
            matchingChat.owner = owner
            matchingChat.jid = jid
            matchingChat.conversationType = .omemo
            matchingChat.setPrimary(withOwner: owner)
            matchingChat.lastMessageId = "local-message-id"
            realm.add(matchingChat)

            let missingChat = LastChatsStorageItem()
            missingChat.owner = owner
            missingChat.jid = "missing-preview@example.com"
            missingChat.conversationType = .regular
            missingChat.setPrimary(withOwner: owner)
            missingChat.lastMessageId = "not-materialized"
            realm.add(missingChat)

            let message = MessageStorageItem()
            message.primary = "cold-preview-message-id"
            message.owner = owner
            message.opponent = jid
            message.conversationType = .omemo
            message.messageId = "local-message-id"
            message.archivedId = "different-archive-id"
            message.body = "Matched by message ID"
            message.date = Date(timeIntervalSince1970: 100)
            realm.add(message)
        }

        let chats = realm.objects(LastChatsStorageItem.self).toArray()
        let resolved = LastChatMaterializedPreviewResolver.resolve(
            in: realm,
            for: chats
        )
        let matchingPrimary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .omemo
        )
        let missingPrimary = LastChatsStorageItem.genPrimary(
            jid: "missing-preview@example.com",
            owner: owner,
            conversationType: .regular
        )

        XCTAssertEqual(
            resolved[matchingPrimary]?.body,
            "Matched by message ID"
        )
        XCTAssertNil(resolved[missingPrimary])
    }

    func testSyncOnlyIdentityUsesSuccessfulVCardTitleWithoutRoster() {
        XCTAssertEqual(
            LastChatsIdentityTitlePolicy.title(
                rosterDisplayName: nil,
                synchronizedVCardTitle: "Juliet Capulet",
                jid: "juliet@example.com"
            ),
            "Juliet Capulet"
        )
        XCTAssertEqual(
            LastChatsIdentityTitlePolicy.title(
                rosterDisplayName: "Roster title",
                synchronizedVCardTitle: "VCard title",
                jid: "juliet@example.com"
            ),
            "Roster title"
        )
    }

    func testLastChatsVCardHydrationIsVisibleRowsOnlyWithoutAppearanceBulkFanout() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController.swift"
            ),
            encoding: .utf8
        )
        let tableDelegate = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDatasource.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(controller.contains("scheduleBulkVCardHydration"))
        XCTAssertFalse(controller.contains("lazyLoadMissedVCards"))
        XCTAssertTrue(tableDelegate.contains("willDisplay cell"))
        XCTAssertTrue(tableDelegate.contains("requestVisibleVCard"))
    }

    func testSynchronizationPreviewStoreIsAccountScopedIdentityCheckedAndObservable() {
        let owner = "preview-owner@example.com"
        let otherOwner = "preview-other@example.com"
        let projection = LastChatListSyncPreviewProjection(
            owner: owner,
            conversationPrimary: "chat-primary",
            lastMessageID: "sync-message-1",
            text: "Observable preview"
        )
        let notification = expectation(
            description: "preview projection change is observable"
        )
        let token = NotificationCenter.default.addObserver(
            forName: LastChatListSyncPreviewStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            if note.object as? String == owner {
                notification.fulfill()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            LastChatListSyncPreviewStore.shared.removeAll(for: owner)
            LastChatListSyncPreviewStore.shared.removeAll(for: otherOwner)
        }

        LastChatListSyncPreviewStore.shared.apply(
            [.upsert(projection)],
            for: owner
        )
        wait(for: [notification], timeout: 1)

        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: "chat-primary",
                expectedLastMessageID: "sync-message-1"
            ),
            projection
        )
        XCTAssertNil(
            LastChatListSyncPreviewStore.shared.projection(
                owner: otherOwner,
                conversationPrimary: "chat-primary",
                expectedLastMessageID: "sync-message-1"
            )
        )
        XCTAssertNil(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: "chat-primary",
                expectedLastMessageID: "stale-message"
            )
        )
    }

    func testBootstrapDatasetUpdatePolicySuppressesExpensiveAnimatedWorkOnlyDuringBootstrap() {
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(requestedAnimated: true, isBootstrapActive: true))
        XCTAssertTrue(LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(requestedAnimated: true, isBootstrapActive: false))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(requestedAnimated: false, isBootstrapActive: false))

        XCTAssertTrue(LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(isBootstrapActive: true))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(isBootstrapActive: false))
        XCTAssertTrue(LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(isBootstrapActive: true, hasScheduledUpdate: false))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(isBootstrapActive: false, hasScheduledUpdate: false))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(isBootstrapActive: true, hasScheduledUpdate: true))
    }

    func testProjectionRefreshCoalescerBatchesRosterResourceAndVCardInvalidations() {
        var coalescer = LastChatsProjectionRefreshCoalescer()

        let first = coalescer.register(.roster)
        let duplicateRoster = coalescer.register(.roster)
        let resource = coalescer.register(.resource)
        let vCard = coalescer.register(.vCard("romeo@example.com|owner@example.com"))
        let duplicateVCard = coalescer.register(
            .vCard("romeo@example.com|owner@example.com")
        )

        XCTAssertTrue(first.shouldScheduleDeadline)
        XCTAssertFalse(duplicateRoster.shouldScheduleDeadline)
        XCTAssertFalse(resource.shouldScheduleDeadline)
        XCTAssertFalse(vCard.shouldScheduleDeadline)
        XCTAssertFalse(duplicateVCard.shouldScheduleDeadline)
        XCTAssertTrue(first.shouldRescheduleQuietFlush)
        XCTAssertTrue(duplicateVCard.shouldRescheduleQuietFlush)
        XCTAssertEqual(coalescer.pendingInvalidationCount, 3)
    }

    func testProjectionRefreshCoalescerFlushPreservesFinalStateAndStartsFreshWindow() {
        var coalescer = LastChatsProjectionRefreshCoalescer()
        _ = coalescer.register(.vCard("first@example.com|owner@example.com"))
        _ = coalescer.register(.vCard("second@example.com|owner@example.com"))
        _ = coalescer.register(.resource)

        let flushed = coalescer.flush()
        let next = coalescer.register(.roster)

        XCTAssertEqual(
            flushed,
            Set([
                .vCard("first@example.com|owner@example.com"),
                .vCard("second@example.com|owner@example.com"),
                .resource
            ])
        )
        XCTAssertEqual(coalescer.pendingInvalidationCount, 1)
        XCTAssertTrue(next.shouldScheduleDeadline)
        XCTAssertTrue(next.shouldRescheduleQuietFlush)
    }

    func testFirstDatasetApplyAnimationOwnershipSurvivesDropAndEndsAfterCommit() {
        XCTAssertTrue(
            LastChatsFirstDatasetApplyOwnershipPolicy.pendingAfterCycle(
                wasPending: true,
                didCommitDatasetApply: false
            )
        )
        XCTAssertFalse(
            LastChatsFirstDatasetApplyOwnershipPolicy.pendingAfterCycle(
                wasPending: true,
                didCommitDatasetApply: true
            )
        )
        XCTAssertFalse(
            LastChatsFirstDatasetApplyOwnershipPolicy.pendingAfterCycle(
                wasPending: false,
                didCommitDatasetApply: true
            )
        )
    }

    func testBootstrapDatasetUpdatePolicyTreatsActiveChatHistoryLoadAsPressure() {
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: false,
                isChatHistoryLoadActive: true,
                isChatUIResponsivenessGateActive: false
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: true,
                isChatHistoryLoadActive: false,
                isChatUIResponsivenessGateActive: false
            )
        )
        XCTAssertFalse(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: false,
                isChatHistoryLoadActive: false,
                isChatUIResponsivenessGateActive: false
            )
        )

        XCTAssertFalse(
            LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(
                requestedAnimated: true,
                isDatasetUpdatePressureActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(
                isDatasetUpdatePressureActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(
                isDatasetUpdatePressureActive: true,
                hasScheduledUpdate: false
            )
        )
    }

    func testBootstrapDatasetUpdatePolicyTreatsActiveChatInteractionGateAsPresentationPressure() {
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: false,
                isChatHistoryLoadActive: false,
                isChatUIResponsivenessGateActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(
                isDatasetUpdatePressureActive: true,
                hasScheduledUpdate: false
            )
        )
        XCTAssertFalse(
            LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(
                requestedAnimated: true,
                isDatasetUpdatePressureActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(
                isDatasetUpdatePressureActive: true
            )
        )
    }

    func testOutgoingChatOpenBeginsLastChatsMutationDeferralBeforePush() {
        let controller = LastChatsViewController()

        XCTAssertFalse(controller.isNavigationTransitionActive)

        controller.beginOutgoingChatOpenNavigationDeferral()

        XCTAssertTrue(controller.isNavigationTransitionActive)
        XCTAssertTrue(
            LastChatsNavigationTransitionMutationPolicy.shouldDeferMutation(
                isTransitionActive: controller.isNavigationTransitionActive,
                isCriticalForFirstFrame: false
            )
        )
        XCTAssertFalse(
            LastChatsNavigationTransitionMutationPolicy.shouldDeferMutation(
                isTransitionActive: controller.isNavigationTransitionActive,
                isCriticalForFirstFrame: true
            )
        )
    }

    func testActiveCanonicalGroupSuppressesOnlyItsRegularLastChatsShadow() {
        let owner = "owner@example.com"
        let group = "stage@example.com"
        let activeGroupPrimaries: Set<String> = [
            GroupStorageKey.groupPrimary(owner: owner, groupJID: group)
        ]

        XCTAssertTrue(
            CanonicalGroupRegularShadowPolicy.shouldSuppress(
                owner: owner,
                jid: group,
                conversationType: .regular,
                activeGroupPrimaries: activeGroupPrimaries
            )
        )
        XCTAssertFalse(
            CanonicalGroupRegularShadowPolicy.shouldSuppress(
                owner: owner,
                jid: group,
                conversationType: .group,
                activeGroupPrimaries: activeGroupPrimaries
            )
        )
        XCTAssertFalse(
            CanonicalGroupRegularShadowPolicy.shouldSuppress(
                owner: owner,
                jid: "juliet@example.com",
                conversationType: .regular,
                activeGroupPrimaries: activeGroupPrimaries
            )
        )
    }

    private func withInterfaceType(_ interfaceType: CommonConfigManager.InterfaceType, useYubikey: Bool, block: () -> Void) {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousUseYubikey = CommonConfigManager.shared.config.use_yubikey
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            CommonConfigManager.shared.config.use_yubikey = previousUseYubikey
        }

        CommonConfigManager.shared.config.interface_type = interfaceType.rawValue
        CommonConfigManager.shared.config.use_yubikey = useYubikey
        block()
    }

    private func withConnectingAccount(
        _ block: (LastChatsViewController, String) -> Void
    ) {
        let controller = LastChatsViewController()
        let ownerJid = "owner@example.com"
        controller.enabledAccounts.accept([ownerJid])
        block(controller, ownerJid)
    }

    private func unreadActionVisibility(of controller: LastChatsViewController) -> [Bool] {
        [
            !controller.floatingBottomBarFilterButton.isHidden,
            !controller.markAllReadButton.isHidden
        ]
    }

    private enum LastChatsPreviewAttachmentKind: CustomStringConvertible {
        case photo
        case video
        case file
        case voice

        var description: String {
            switch self {
            case .photo: return "photo"
            case .video: return "video"
            case .file: return "file"
            case .voice: return "voice"
            }
        }

        var mediaType: String {
            switch self {
            case .photo: return "image/jpeg"
            case .video: return "video/mp4"
            case .file: return "application/pdf"
            case .voice: return "audio/ogg"
            }
        }

        func filename(at index: Int) -> String {
            switch self {
            case .photo: return "photo-\(index).jpg"
            case .video: return "video-\(index).mp4"
            case .file: return "file-\(index).pdf"
            case .voice: return "voice-\(index).ogg"
            }
        }
    }

    private func makeMaterializedAttachmentPreviewMessage(
        kind: LastChatsPreviewAttachmentKind,
        count: Int,
        hiddenIndexes: Set<Int> = [],
        caption: String? = nil
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = "materialized-preview-\(kind)-\(UUID().uuidString)"
        message.messageId = message.primary
        message.owner = "owner@example.com"
        message.opponent = "juliet@example.com"
        message.conversationType = .regular
        message.body = caption ?? ""
        message.legacyBody = message.body

        (0..<count).forEach { index in
            let filename = kind.filename(at: index)
            let remoteURL = "https://gallery.example/files/token-\(index)/\(filename)"
            let reference = MessageReferenceStorageItem()
            reference.primary = "materialized-reference-\(kind)-\(index)-\(UUID().uuidString)"
            reference.owner = message.owner
            reference.jid = message.opponent
            reference.messageId = message.messageId
            reference.url = remoteURL
            reference.isLocallyHiddenByReport = hiddenIndexes.contains(index)
            if kind == .voice {
                reference.kind = .voice
                reference.mimeType = "audio"
                reference.metadata = [
                    "media-type": kind.mediaType,
                    "name": filename,
                    "duration": 3,
                    "size": 1_024,
                    "uri": remoteURL
                ]
            } else {
                reference.kind = .media
                reference.mimeType = MimeIcon(kind.mediaType).value.rawValue
                reference.metadata = [
                    "media-type": kind.mediaType,
                    "name": filename,
                    "size": 1_024,
                    "uri": remoteURL
                ]
            }
            message.references.append(reference)
        }
        return message
    }

    private func makeMaterializedForwardPreviewMessage(
        nicknames: [String]
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = "materialized-forward-\(UUID().uuidString)"
        message.messageId = message.primary
        message.owner = "owner@example.com"
        message.opponent = "juliet@example.com"
        message.conversationType = .regular
        message.body = ""
        message.legacyBody = ""

        nicknames.enumerated().forEach { index, nickname in
            let forward = MessageForwardsInlineStorageItem()
            forward.primary = "materialized-inline-forward-\(index)-\(UUID().uuidString)"
            forward.messageId = forward.primary
            forward.parentId = message.primary
            forward.owner = message.owner
            forward.jid = message.opponent
            forward.opponent = "sender-\(index)@example.com"
            forward.forwardJid = forward.opponent
            forward.forwardNickname = nickname
            forward.body = "Forwarded body \(index)"
            message.inlineForwards.append(forward)
        }
        return message
    }

    private func makeSyncForwardPreviewMessageWithNestedPhoto() throws -> DDXMLElement {
        let fallback = "Forwarded fallback"
        let remoteURL = "https://gallery.example/files/photo.jpg"
        let document = try DDXMLDocument(
            xmlString: """
            <message from='juliet@example.com/mobile'
                     to='owner@example.com'
                     type='chat'
                     id='sync-forward-message'>
              <body>\(fallback)</body>
              <reference xmlns='https://xabber.com/protocol/references'
                         type='mutable'
                         begin='0'
                         end='\(fallback.unicodeScalars.count)'>
                <forwarded xmlns='urn:xmpp:forward:0'>
                  <delay xmlns='urn:xmpp:delay' stamp='2026-08-26T10:00:00.000Z'/>
                  <message from='alice@example.com/mobile'
                           to='owner@example.com'
                           type='chat'
                           id='forwarded-photo-message'>
                    <body>\(remoteURL)</body>
                    <reference xmlns='https://xabber.com/protocol/references'
                               type='mutable'
                               begin='0'
                               end='\(remoteURL.unicodeScalars.count)'>
                      <file-sharing xmlns='https://xabber.com/protocol/files'>
                        <file>
                          <media-type>image/jpeg</media-type>
                          <name>photo.jpg</name>
                          <size>1024</size>
                        </file>
                        <sources><uri>\(remoteURL)</uri></sources>
                      </file-sharing>
                    </reference>
                  </message>
                </forwarded>
              </reference>
            </message>
            """,
            options: 0
        )
        return try XCTUnwrap(document.rootElement())
    }

    private func makeSyncAttachmentPreviewMessage(
        kind: LastChatsPreviewAttachmentKind,
        count: Int,
        caption: String? = nil
    ) throws -> DDXMLElement {
        let filenames = (0..<count).map(kind.filename(at:))
        let remoteURLs = filenames.enumerated().map { index, filename in
            "https://gallery.example/files/token-\(index)/\(filename)"
        }
        let bodyComponents = ([caption].compactMap { $0 }) + remoteURLs
        let body = bodyComponents.joined(separator: "\n")
        var offset = caption.map {
            $0.xmlEscaping(reverse: false).unicodeScalars.count + 1
        } ?? 0
        let referencesXML = zip(filenames, remoteURLs).map { filename, remoteURL -> String in
            let begin = offset
            let end = begin + remoteURL.xmlEscaping(reverse: false).unicodeScalars.count
            offset = end + 1

            let fileSharing = """
            <file-sharing xmlns='https://xabber.com/protocol/files'>
              <file>
                <media-type>\(kind.mediaType)</media-type>
                <name>\(filename)</name>
                <size>1024</size>
                \(kind == .voice ? "<duration>3</duration>" : "")
              </file>
              <sources>
                <uri>\(remoteURL)</uri>
              </sources>
            </file-sharing>
            """
            let payload = kind == .voice
                ? "<voice-message xmlns='https://xabber.com/protocol/voice-messages'>\(fileSharing)</voice-message>"
                : fileSharing
            return """
            <reference xmlns='https://xabber.com/protocol/references'
                       type='mutable'
                       begin='\(begin)'
                       end='\(end)'>
              \(payload)
            </reference>
            """
        }.joined(separator: "\n")
        let document = try DDXMLDocument(
            xmlString: """
            <message from='juliet@example.com/mobile'
                     to='owner@example.com'
                     type='chat'
                     id='sync-preview-message'>
              <body>\(body)</body>
              \(referencesXML)
            </message>
            """,
            options: 0
        )
        return try XCTUnwrap(document.rootElement())
    }

    private func waitForLastChatsDataset(
        _ controller: LastChatsViewController,
        containing jid: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if controller.datasource.contains(where: { $0.jid == jid }) {
                return true
            }
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        } while Date() < deadline
        return controller.datasource.contains(where: { $0.jid == jid })
    }

    private func assertLargeTitle(
        useLargeTitle: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let previousUseLargeTitle = CommonConfigManager.shared.config.use_large_title
        defer {
            CommonConfigManager.shared.config.use_large_title = previousUseLargeTitle
        }
        CommonConfigManager.shared.config.use_large_title = useLargeTitle
        let controller = LastChatsViewController()
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

    private func navigationBarItems(
        _ items: [UIBarButtonItem]?,
        _ singleItem: UIBarButtonItem?
    ) -> [UIBarButtonItem] {
        if let items, !items.isEmpty {
            return items
        }

        return singleItem.map { [$0] } ?? []
    }

    private func makeSolidAvatarImage(color: UIColor, size: CGSize = CGSize(width: 64, height: 64)) -> UIImage {
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

    private func makeDatasource(
        jid: String,
        owner: String = "owner@example.com",
        message: String = "Hello",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> LastChatsViewController.Datasource {
        LastChatsViewController.Datasource(
            jid: jid,
            owner: owner,
            username: "Romeo",
            attributedUsername: nil,
            message: message,
            date: Date(timeIntervalSince1970: 1_711_283_200),
            state: nil,
            isMute: false,
            isSynced: true,
            status: .offline,
            entity: conversationType == .regular || conversationType.isEncrypted ? .contact : .groupchat,
            conversationType: conversationType,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: false,
            color: .clear,
            isDraft: false,
            hasAttachment: false,
            userNickname: nil,
            isSystemMessage: false,
            isPinned: false,
            subRequest: false,
            isEncrypted: conversationType.isEncrypted,
            avatarUrl: nil,
            hasErrorInChat: false,
            updateTS: 0,
            isVerificationActionRequired: false,
            specialMessageKind: .none,
            avatars: []
        )
    }
}
