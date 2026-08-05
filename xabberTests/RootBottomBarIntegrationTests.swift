//
//  RootBottomBarIntegrationTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class RootBottomBarIntegrationTests: XCTestCase {
    private final class TraitWindow: UIWindow {
        private let horizontalSizeClass: UIUserInterfaceSizeClass
        private let contentSizeCategory: UIContentSizeCategory

        init(
            windowScene: UIWindowScene,
            horizontalSizeClass: UIUserInterfaceSizeClass,
            contentSizeCategory: UIContentSizeCategory = .large
        ) {
            self.horizontalSizeClass = horizontalSizeClass
            self.contentSizeCategory = contentSizeCategory
            super.init(windowScene: windowScene)
            frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var traitCollection: UITraitCollection {
            UITraitCollection(traitsFrom: [
                super.traitCollection,
                UITraitCollection(horizontalSizeClass: horizontalSizeClass),
                UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
            ])
        }
    }

    private final class HeldMentionChatViewController:
        ChatViewController,
        StackedNavigationPresentationPreparationControlling {
        private var preparationHandle:
            StackedNavigationPresentationPreparationHandle?

        func makeStackedNavigationPresentationPreparation(
            targetBounds: CGRect?,
            completion: @escaping () -> Void
        ) -> StackedNavigationPresentationPreparationHandle {
            let handle = StackedNavigationPresentationPreparationHandle(
                completion: completion
            )
            preparationHandle = handle
            return handle
        }
    }

    private var previousInterfaceType: String!
    private var previousRealmConfiguration: Realm.Configuration!
    private weak var previousKeyWindow: UIWindow?
    private weak var fixtureWindowScene: UIWindowScene?
    private var retainedTraitWindows: [UIWindow] = []
    private var retainedTraitContainers: [UIViewController] = []

    override func setUp() {
        super.setUp()
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        guard let previousKeyWindow = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { window in
                window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
            })),
            let fixtureWindowScene = previousKeyWindow.windowScene else {
            preconditionFailure("A foreground XCTest key window is required for UIKit fixtures")
        }
        self.previousKeyWindow = previousKeyWindow
        self.fixtureWindowScene = fixtureWindowScene
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "RootBottomBarIntegrationTests-\(name)-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        retainedTraitWindows.reversed().forEach { window in
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            window.subviews.forEach { $0.removeFromSuperview() }
        }
        retainedTraitWindows.removeAll()
        retainedTraitContainers.removeAll()
        previousKeyWindow?.makeKey()
        AccountManager.shared.users.removeAll()
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousInterfaceType = nil
        previousRealmConfiguration = nil
        previousKeyWindow = nil
        fixtureWindowScene = nil
        super.tearDown()
    }

    func testLeftMenuRouteMatrixCreatesSevenSearchRootsAndExcludesSettings() throws {
        let menu = LeftMenuViewController()
        menu.previousSelectedKey = nil

        menu.didSelectRootScreenBy(key: "chat")
        menu.didSelectRootScreenBy(key: "calls")
        menu.didSelectRootScreenBy(key: "notifications")
        menu.didSelectRootScreenBy(key: "contacts", category: "contacts")
        menu.didSelectRootScreenBy(key: "groups", category: "public")
        menu.didSelectRootScreenBy(key: "archive")
        menu.didSelectRootScreenBy(key: "saved")

        let chats = try XCTUnwrap(menu.chatsVc)
        let calls = try XCTUnwrap(menu.callsVc)
        let notifications = try XCTUnwrap(menu.notificationsVc)
        let contacts = try XCTUnwrap(menu.contactsVc)
        let groups = try XCTUnwrap(menu.groupsVc)
        let archive = try XCTUnwrap(menu.archivedVc)
        let saved = try XCTUnwrap(menu.savedMessagesChatsVc)
        XCTAssertEqual(chats.filter.value, .chats)
        XCTAssertEqual(archive.filter.value, .archived)
        XCTAssertFalse(archive.shouldShowBottomBar)
        XCTAssertEqual(saved.filter.value, .saved)
        XCTAssertFalse(saved.shouldShowBottomBar)
        XCTAssertFalse(contacts.isGroup)
        XCTAssertTrue(groups.isGroup)

        let searchHosts = [
            chats.bottomSearchHostView,
            calls.bottomSearchHostView,
            notifications.bottomSearchHostView,
            contacts.bottomSearchHostView,
            groups.bottomSearchHostView,
            archive.bottomSearchHostView,
            saved.bottomSearchHostView
        ]
        XCTAssertEqual(searchHosts.count, 7)
        XCTAssertTrue(searchHosts.allSatisfy {
            $0.collapsedButton.accessibilityIdentifier == "bottom_search_button"
                && $0.searchTextField.accessibilityIdentifier == "bottom_search_text_field"
                && $0.cancelButton.accessibilityIdentifier == "bottom_search_cancel_button"
        })

        let settingsRoute = LeftMenuViewController()
        settingsRoute.previousSelectedKey = nil
        settingsRoute.didSelectRootScreenBy(key: "settings")
        XCTAssertNil(settingsRoute.chatsVc)
        XCTAssertNil(settingsRoute.callsVc)
        XCTAssertNil(settingsRoute.notificationsVc)
        XCTAssertNil(settingsRoute.contactsVc)
        XCTAssertNil(settingsRoute.groupsVc)
        XCTAssertNil(settingsRoute.archivedVc)
        XCTAssertNil(settingsRoute.savedMessagesChatsVc)
    }

    func testChatsArchiveAndSavedActionMatrix() {
        struct Case {
            let unread: Int
            let connecting: Bool
            let filter: LastChatsViewController.Filter
            let shouldShowBottomBar: Bool
            let searchHidesActions: Bool
            let expectedActions: FloatingBottomBarView.ActionPresentation
            let expectedBarHidden: Bool
        }

        let cases = [
            Case(
                unread: 0,
                connecting: false,
                filter: .chats,
                shouldShowBottomBar: true,
                searchHidesActions: false,
                expectedActions: .init(isLeftVisible: false, isCenterVisible: false),
                expectedBarHidden: false
            ),
            Case(
                unread: 3,
                connecting: false,
                filter: .chats,
                shouldShowBottomBar: true,
                searchHidesActions: false,
                expectedActions: .allVisible,
                expectedBarHidden: false
            ),
            Case(
                unread: 3,
                connecting: true,
                filter: .unread,
                shouldShowBottomBar: true,
                searchHidesActions: false,
                expectedActions: .init(isLeftVisible: true, isCenterVisible: false),
                expectedBarHidden: false
            ),
            Case(
                unread: 3,
                connecting: false,
                filter: .archived,
                shouldShowBottomBar: false,
                searchHidesActions: false,
                expectedActions: .init(isLeftVisible: false, isCenterVisible: false),
                expectedBarHidden: true
            ),
            Case(
                unread: 3,
                connecting: false,
                filter: .saved,
                shouldShowBottomBar: false,
                searchHidesActions: false,
                expectedActions: .init(isLeftVisible: false, isCenterVisible: false),
                expectedBarHidden: true
            ),
            Case(
                unread: 3,
                connecting: false,
                filter: .chats,
                shouldShowBottomBar: true,
                searchHidesActions: true,
                expectedActions: .allVisible,
                expectedBarHidden: true
            )
        ]

        cases.forEach { item in
            let presentation = LastChatsViewController.bottomBarPresentation(
                unreadChatsCount: item.unread,
                hasConnectingEnabledAccounts: item.connecting,
                filter: item.filter,
                shouldShowBottomBar: item.shouldShowBottomBar,
                hidesUnderlyingActions: item.searchHidesActions
            )

            XCTAssertEqual(presentation.actions, item.expectedActions)
            XCTAssertEqual(presentation.isActionBarHidden, item.expectedBarHidden)
        }
    }

    func testContactsAndGroupsAvailabilityMatrixKeepsPrimaryAndSearchFixed() async {
        var controllers: [ContactsViewController] = []
        for isGroup in [false, true] {
            let controller = ContactsViewController()
            controllers.append(controller)
            controller.isGroup = isGroup
            let navigationController = embedInTraitContainer(
                UINavigationController(rootViewController: controller),
                horizontalSizeClass: .compact
            )
            layout(navigationController, root: controller)

            controller.applyMappedDataset(
                [[]],
                featureHasAnyContent: true,
                hasResolvedSnapshot: true,
                filterablePresenceRowCount: 1,
                forceFullReload: true
            )
            controller.view.layoutIfNeeded()
            let primaryFrame = frame(of: controller.contactsCompactBottomBarPrimaryButton, in: controller.view)
            let searchFrame = frame(of: controller.bottomSearchHostView.collapsedButton, in: controller.view)
            XCTAssertFalse(controller.contactsCompactBottomBarFilterButton.isHidden)
            XCTAssertFalse(controller.contactsCompactBottomBarPrimaryButton.isHidden)

            controller.applyMappedDataset(
                [[]],
                featureHasAnyContent: false,
                hasResolvedSnapshot: true,
                filterablePresenceRowCount: 0,
                forceFullReload: true
            )
            controller.view.layoutIfNeeded()

            XCTAssertTrue(controller.contactsCompactBottomBarFilterButton.isHidden)
            XCTAssertFalse(controller.contactsCompactBottomBarPrimaryButton.isHidden)
            XCTAssertEqual(frame(of: controller.contactsCompactBottomBarPrimaryButton, in: controller.view), primaryFrame)
            XCTAssertEqual(frame(of: controller.bottomSearchHostView.collapsedButton, in: controller.view), searchFrame)
            XCTAssertEqual(
                controller.contactsCompactBottomBarFilterButton.accessibilityIdentifier,
                isGroup ? "groups_online_filter_button" : "contacts_online_filter_button"
            )
            XCTAssertEqual(
                controller.contactsCompactBottomBarPrimaryButton.accessibilityIdentifier,
                isGroup ? "groups_create_group_bottom_button" : "contacts_add_contact_bottom_button"
            )
        }

        await quiesceContactsDatasetWorkBeforeFixtureDetachment(controllers)
    }

    func testCallsAvailabilityMatrixAlwaysHidesStartCallAndKeepsSearchFixed() {
        let controller = LastCallsViewController()
        let navigationController = embedInTraitContainer(
            UINavigationController(rootViewController: controller),
            horizontalSizeClass: .compact
        )
        layout(navigationController, root: controller)
        controller.currentCallsCounters = .init(total: 1, missed: 1, incoming: 0, outgoing: 0, declined: 0)
        controller.updateCallsCompactBottomBarState()
        controller.view.layoutIfNeeded()
        let searchFrame = frame(of: controller.bottomSearchHostView.collapsedButton, in: controller.view)

        XCTAssertFalse(controller.callsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertEqual(controller.callsCompactBottomBarFilterButton.accessibilityIdentifier, "calls_missed_filter_button")
        XCTAssertEqual(controller.callsCompactBottomBarPrimaryButton.accessibilityIdentifier, "calls_start_call_bottom_button")

        controller.currentCallsCounters = .init(total: 1, missed: 0, incoming: 1, outgoing: 0, declined: 0)
        controller.updateCallsCompactBottomBarState()
        controller.view.layoutIfNeeded()

        XCTAssertTrue(controller.callsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.callsCompactBottomBarPrimaryButton.isEnabled)
        XCTAssertTrue(controller.callsCompactBottomBarPrimaryButton.accessibilityElementsHidden)
        XCTAssertEqual(frame(of: controller.bottomSearchHostView.collapsedButton, in: controller.view), searchFrame)
    }

    func testNotificationsAvailabilityMatrixUsesScopedUnreadAndNormalizesEmptyFilter() {
        let owner = "notifications-matrix@owner.example"
        addEnabledAccount(owner: owner)
        addNotification(owner: owner, uniqueId: "matrix-unread", isRead: false)
        let controller = NotificationsListViewController()
        controller.filter.accept(.info)
        controller.filterAccount.accept(owner)
        let navigationController = embedInTraitContainer(
            UINavigationController(rootViewController: controller),
            horizontalSizeClass: .compact
        )
        layout(navigationController, root: controller)
        controller.updateNotificationsCompactBottomBarState()
        controller.view.layoutIfNeeded()
        let searchFrame = frame(of: controller.bottomSearchHostView.collapsedButton, in: controller.view)

        XCTAssertFalse(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertEqual(controller.notificationsCompactBottomBarFilterButton.accessibilityIdentifier, "notifications_unread_filter_button")
        XCTAssertEqual(controller.notificationsCompactBottomBarPrimaryButton.accessibilityIdentifier, "notifications_read_all_bottom_button")

        controller.unreadOnly.accept(true)
        setNotificationRead(owner: owner, uniqueId: "matrix-unread", isRead: true)
        controller.updateNotificationsCompactBottomBarState()
        controller.view.layoutIfNeeded()

        XCTAssertFalse(controller.unreadOnly.value)
        XCTAssertTrue(controller.notificationsCompactBottomBarFilterButton.isHidden)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.isHidden)
        XCTAssertFalse(controller.notificationsCompactBottomBarPrimaryButton.isEnabled)
        XCTAssertTrue(controller.notificationsCompactBottomBarPrimaryButton.accessibilityElementsHidden)
        XCTAssertEqual(frame(of: controller.bottomSearchHostView.collapsedButton, in: controller.view), searchFrame)
    }

    func testProductionTabRootMentionTapUsesSceneCoordinatorAndKeepsExactRequestWithoutLatestFallback() throws {
        let owner = "tabs-mention-owner@example.com"
        let groupchatJid = "tabs-mention-room@example.com"
        let sourceDate = Date(timeIntervalSince1970: 1_722_614_400)
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousNotifyDelegate = NotifyManager.shared.leftMenuDelegate
        let modalAccess = ModalPresentationCurrentControllerAccess.application
        let previousPresentedController = modalAccess.get()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        var lastChats: LastChatsViewController?
        var retainedDestination: HeldMentionChatViewController?
        defer {
            lastChats?.resetChatNavigationTransaction(cancelled: true)
            retainedDestination?.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
            NotifyManager.shared.leftMenuDelegate = previousNotifyDelegate
            modalAccess.set(previousPresentedController)
            AppRootCoordinator.active = previousActiveCoordinator
        }

        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.tabs.rawValue
        addEnabledAccount(owner: owner)
        let notification = NotificationStorageItem()
        notification.primary = "tabs-mention-notification"
        notification.owner = owner
        notification.jid = "notifications.example.com"
        notification.associatedJid = groupchatJid
        notification.uniqueId = "tabs-mention-wrapper"
        notification.messageId = "outer-notification-id"
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.date = sourceDate
        notification.sourceConversationType = .group
        notification.sourceChatJid = groupchatJid
        notification.sourceArchivedId = "mention-archived-id"
        notification.sourceMessageId = "mention-message-id"
        notification.sourceSenderId = "mention-author-id"
        notification.sourceBodyFingerprint =
            MentionNotificationSync.normalizedBodyFingerprint("Hello @you")
        notification.sourceMessageDate = sourceDate
        notification.mentionLinkStatus = .resolved
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(notification, update: .modified)
        }
        let expectedRequest = try XCTUnwrap(
            NotificationsListViewController.mentionOpenRequest(for: notification)
        )

        modalAccess.set(nil)
        let coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        coordinator.rebuildRoot(userInfo: nil)
        modalAccess.set(nil)
        let tabController = try XCTUnwrap(coordinator.tabController)
        let chatsNavigationController = try XCTUnwrap(
            tabController.viewControllers?.first as? UINavigationController
        )
        let productionLastChats = try XCTUnwrap(
            chatsNavigationController.viewControllers.first
                as? LastChatsViewController
        )
        lastChats = productionLastChats
        let destination = HeldMentionChatViewController()
        var destinationFactoryCount = 0
        retainedDestination = destination
        productionLastChats.compactChatDestinationFactory = {
            destinationFactoryCount += 1
            return destination
        }
        let notificationsNavigationController = try XCTUnwrap(
            tabController.viewControllers?[2] as? UINavigationController
        )
        let notifications = try XCTUnwrap(
            notificationsNavigationController.viewControllers.first
                as? NotificationsListViewController
        )
        // This synthetic datasource is only the row-materialization seam. The
        // selected Realm item, UIKit didSelect, route authority, Last Chats
        // single-flight and exact request ownership below are production paths;
        // this selector is not canonical hosted/video evidence.
        notifications.datasource = [
            NotificationsListViewController.Datasource(
                title: "Mentions",
                key: "notifications",
                childs: [
                    NotificationsListViewController.DatasourceChild(
                        primary: notification.primary,
                        category: .mention,
                        owner: owner,
                        jid: groupchatJid,
                        title: NSAttributedString(string: "Mention"),
                        date: sourceDate,
                        badgeIcon: "at",
                        isRead: false,
                        isHeader: false
                    )
                ]
            )
        ]

        XCTAssertTrue(
            (notifications.leftMenuDelegate as AnyObject?) ===
                (coordinator as AnyObject),
            "The production tabs root must install its scene coordinator as the route authority"
        )
        tabController.selectedIndex = 2
        XCTAssertEqual(destinationFactoryCount, 0)
        XCTAssertNil(productionLastChats.chatNavigationSingleFlight.state)
        XCTAssertNil(productionLastChats.retainedCompactChatNavigationDestination)
        XCTAssertNil(productionLastChats.chatOpenIntentOwnership)
        XCTAssertFalse(destination.isViewLoaded)

        notifications.tableView(
            notifications.tableView,
            didSelectRowAt: IndexPath(row: 0, section: 0)
        )

        let ownership = try XCTUnwrap(
            productionLastChats.chatOpenIntentOwnership,
            "A real mention tap must not be silently dropped by an unwired optional delegate"
        )
        let retained = try XCTUnwrap(
            productionLastChats.retainedCompactChatNavigationDestination
        )
        let singleFlight = try XCTUnwrap(
            productionLastChats.chatNavigationSingleFlight.state
        )
        XCTAssertEqual(tabController.selectedIndex, 0)
        XCTAssertEqual(destinationFactoryCount, 1)
        XCTAssertTrue(retained.controller === destination)
        XCTAssertEqual(retained.token, singleFlight.token)
        XCTAssertEqual(retained.target, singleFlight.target)
        XCTAssertEqual(singleFlight.phase, .preparing)
        XCTAssertEqual(ownership.target.owner, owner)
        XCTAssertEqual(ownership.target.jid, groupchatJid)
        XCTAssertEqual(ownership.target.conversationType, .group)
        XCTAssertEqual(singleFlight.target, ownership.target)
        XCTAssertEqual(
            ownership.destinationIdentifier,
            ObjectIdentifier(destination)
        )
        guard case .message(let routedRequest) = ownership.intent else {
            return XCTFail("A mention tap must retain the exact request, never latest")
        }
        XCTAssertEqual(routedRequest, expectedRequest)
        XCTAssertEqual(routedRequest.source, .mentionNotification)
        XCTAssertEqual(routedRequest.owner, owner)
        XCTAssertEqual(routedRequest.chatJid, groupchatJid)
        XCTAssertEqual(routedRequest.conversationType, .group)
        XCTAssertEqual(routedRequest.anchor.archivedId, "mention-archived-id")
        XCTAssertEqual(routedRequest.anchor.messageId, "mention-message-id")
        XCTAssertEqual(destination.pendingOpenMessageRequest, expectedRequest)
        XCTAssertFalse(destination.isViewLoaded)
        XCTAssertEqual(chatsNavigationController.viewControllers.count, 1)
        XCTAssertTrue(
            chatsNavigationController.viewControllers.first ===
                productionLastChats
        )
        XCTAssertFalse(
            chatsNavigationController.viewControllers.contains {
                $0 is ChatViewController
            },
            "The held production route must not be rescued by a direct fallback push"
        )
    }

    func testAllActionVisibilityCombinationsKeepFramesAndHiddenStateDeterministic() {
        let view = FloatingBottomBarView(frame: CGRect(x: 0, y: 0, width: 360, height: 44))
        view.layoutIfNeeded()
        view.centerEffectView.layoutIfNeeded()
        let leftFrame = view.leftButton.frame
        let centerFrame = view.centerEffectView.frame
        let combinations = [
            FloatingBottomBarView.ActionPresentation(isLeftVisible: true, isCenterVisible: true),
            .init(isLeftVisible: false, isCenterVisible: true),
            .init(isLeftVisible: true, isCenterVisible: false),
            .init(isLeftVisible: false, isCenterVisible: false)
        ]

        combinations.forEach { presentation in
            view.applyActionPresentation(presentation)
            view.layoutIfNeeded()

            XCTAssertEqual(view.leftButton.frame, leftFrame)
            XCTAssertEqual(view.centerEffectView.frame, centerFrame)
            assertAction(view.leftButton, isVisible: presentation.isLeftVisible)
            assertAction(view.centerButton, isVisible: presentation.isCenterVisible)
            XCTAssertEqual(view.centerEffectView.isHidden, !presentation.isCenterVisible)
            XCTAssertEqual(view.centerEffectView.isUserInteractionEnabled, presentation.isCenterVisible)
        }

        XCTAssertTrue(XabberGlassStyle.makeEffect(role: .bar, prefersNativeGlass: false) is UIBlurEffect)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(XabberGlassStyle.makeEffect(role: .bar) is UIGlassEffect)
        }
    }

    func testSearchMatrixSettlesBothRapidReversalsAndReduceMotionEndpoints() throws {
        let view = BottomSearchHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))
        let window = makeTraitWindow(horizontalSizeClass: .compact)
        window.addSubview(view)
        retainedTraitWindows.append(window)
        window.makeKeyAndVisible()
        XCTAssertTrue(window.windowScene === fixtureWindowScene)
        XCTAssertTrue(window.isKeyWindow)
        window.layoutIfNeeded()
        view.layoutIfNeeded()
        view.animatorFactory = { _, curve in UIViewPropertyAnimator(duration: 10, curve: curve) }

        view.setExpanded(true, animated: true)
        let expansion = try XCTUnwrap(view.transitionAnimator)
        expansion.pauseAnimation()
        expansion.fractionComplete = 0.4
        view.setExpanded(false, animated: true)
        expansion.pauseAnimation()
        expansion.stopAnimation(false)
        expansion.finishAnimation(at: .start)
        XCTAssertEqual(view.transitionPhase, .collapsed)
        XCTAssertFalse(view.collapsedButton.isHidden)
        XCTAssertTrue(view.surfaceView.isHidden)

        view.setExpanded(true, animated: false)
        view.setExpanded(false, animated: true)
        let collapse = try XCTUnwrap(view.transitionAnimator)
        collapse.pauseAnimation()
        collapse.fractionComplete = 0.4
        view.setExpanded(true, animated: true)
        collapse.pauseAnimation()
        collapse.stopAnimation(false)
        collapse.finishAnimation(at: .start)
        XCTAssertEqual(view.transitionPhase, .expanded)
        XCTAssertTrue(view.collapsedButton.isHidden)
        XCTAssertFalse(view.surfaceView.isHidden)

        view.reduceMotionEnabledProvider = { true }
        view.setExpanded(false, animated: true)
        XCTAssertEqual(view.transitionPhase, .collapsed)
        XCTAssertNil(view.transitionAnimator)
    }

    func testEveryTableOwnerKeepsBottomClearanceAndPreservesAwayFromBottomOffset() {
        let chats = LastChatsViewController()
        let contacts = ContactsViewController()
        let calls = LastCallsViewController()
        let notifications = NotificationsListViewController()
        let harnesses: [(UIViewController, UITableView, BottomSearchHostView, () -> Void)] = [
            (chats, chats.tableView, chats.bottomSearchHostView, chats.updateTableInsetsForFloatingToolbar),
            (contacts, contacts.tableView, contacts.bottomSearchHostView, contacts.updateTableInsetsForBottomSearch),
            (calls, calls.tableView, calls.bottomSearchHostView, calls.updateTableInsetsForBottomSearch),
            (notifications, notifications.tableView, notifications.bottomSearchHostView, notifications.updateNotificationsTableInsetsForBottomSearch)
        ]

        for (controller, tableView, searchHost, updateInsets) in harnesses {
            let navigationController = embedInTraitContainer(
                UINavigationController(rootViewController: controller),
                horizontalSizeClass: .compact
            )
            layout(navigationController, root: controller)
            guard let attachedWindow = controller.view.window else {
                XCTFail("The table owner must be attached before layout and inset updates")
                continue
            }
            XCTAssertTrue(controller.navigationController === navigationController)
            XCTAssertTrue(retainedTraitWindows.contains { $0 === attachedWindow })
            tableView.contentSize = CGSize(width: 393, height: 1_600)
            tableView.contentOffset.y = 200

            updateInsets()

            XCTAssertEqual(tableView.contentOffset.y, 200, accuracy: 0.001)
            let maximumOffsetY = max(
                -tableView.adjustedContentInset.top,
                tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height
            )
            tableView.contentOffset.y = maximumOffsetY
            let contentBottomY = tableView.convert(
                CGPoint(x: 0, y: tableView.contentSize.height),
                to: controller.view
            ).y
            let searchFrame = frame(of: searchHost.collapsedButton, in: controller.view)
            XCTAssertLessThanOrEqual(
                contentBottomY,
                searchFrame.minY - FloatingBottomBarView.Metrics.tableInsetPadding + 0.001
            )
        }
    }

    func testRegularWidthMatrixKeepsCompactBarsHiddenAndNavbarStateStable() {
        let chats = LastChatsViewController()
        let contacts = ContactsViewController()
        let calls = LastCallsViewController()
        let notifications = NotificationsListViewController()

        let chatNavigation = embedInDetachedTraitContainer(
            UINavigationController(rootViewController: chats),
            horizontalSizeClass: .regular
        )
        let contactsNavigation = embedInDetachedTraitContainer(
            UINavigationController(rootViewController: contacts),
            horizontalSizeClass: .regular
        )
        let callsNavigation = embedInDetachedTraitContainer(
            UINavigationController(rootViewController: calls),
            horizontalSizeClass: .regular
        )
        let notificationsNavigation = embedInDetachedTraitContainer(
            UINavigationController(rootViewController: notifications),
            horizontalSizeClass: .regular
        )
        let roots: [(UINavigationController, UIViewController)] = [
            (chatNavigation, chats as UIViewController),
            (contactsNavigation, contacts as UIViewController),
            (callsNavigation, calls as UIViewController),
            (notificationsNavigation, notifications as UIViewController)
        ]
        roots.forEach { navigationController, root in
            XCTAssertEqual(navigationController.traitCollection.horizontalSizeClass, .regular)
            XCTAssertNil(root.view.window)
        }
        let contactsIdentifiers = contacts.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier)
        let callsIdentifiers = calls.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier)
        let notificationIdentifiers = notifications.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier)
        let chatsBottomBarWasHidden = chats.isFloatingBottomBarHidden

        chats.updateFloatingToolbarFilterButtonState()
        contacts.updateContactsCompactBottomBarState()
        calls.updateCallsCompactBottomBarState()
        notifications.updateNotificationsCompactBottomBarState()

        XCTAssertEqual(chats.isFloatingBottomBarHidden, chatsBottomBarWasHidden)
        XCTAssertTrue(contacts.isContactsCompactBottomBarHidden)
        XCTAssertTrue(calls.isCallsCompactBottomBarHidden)
        XCTAssertTrue(notifications.isNotificationsCompactBottomBarHidden)
        XCTAssertEqual(contacts.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier), contactsIdentifiers)
        XCTAssertEqual(calls.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier), callsIdentifiers)
        XCTAssertEqual(notifications.navigationItem.rightBarButtonItems?.compactMap(\.accessibilityIdentifier), notificationIdentifiers)
    }

    func testAccessibilityDynamicTypeMatrixKeepsSearchAndAvailableActionsReachable() {
        let controller = ContactsViewController()
        let navigationController = embedInTraitContainer(
            UINavigationController(rootViewController: controller),
            horizontalSizeClass: .compact,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        layout(navigationController, root: controller)
        controller.applyMappedDataset(
            [[]],
            featureHasAnyContent: true,
            hasResolvedSnapshot: true,
            filterablePresenceRowCount: 1,
            forceFullReload: true
        )

        XCTAssertEqual(controller.contactsCompactBottomBarPrimaryButton.bounds.height, FloatingBottomBarView.Metrics.height)
        XCTAssertTrue(controller.contactsCompactBottomBarPrimaryButton.isAccessibilityElement)
        XCTAssertEqual(controller.bottomSearchHostView.collapsedButton.accessibilityLabel, "Search")
        guard let attachedWindow = controller.view.window else {
            return XCTFail("The accessibility search fixture must be attached before expansion")
        }
        attachedWindow.makeKeyAndVisible()
        XCTAssertTrue(attachedWindow.windowScene === fixtureWindowScene)
        XCTAssertTrue(attachedWindow.isKeyWindow)
        controller.bottomSearchHostView.setExpanded(true, animated: false)
        XCTAssertEqual(controller.bottomSearchHostView.cancelButton.accessibilityLabel, "Cancel search")
        XCTAssertFalse(controller.bottomSearchHostView.searchTextField.isHidden)
    }

    func testProductionRootsDoNotUseVisibleDisabledTransitionalAPI() throws {
        let sourcePaths = [
            "xabber/controllers/bars/bottom_bar/FloatingBottomBarView.swift",
            "xabber/controllers/chats/last_chats_list/LastChatsViewController.swift",
            "xabber/controllers/chats/contact_list/ContactsViewController.swift",
            "xabber/controllers/calls/last_calls/LastCallsViewController.swift",
            "xabber/controllers/notifications/NotificationsListViewController.swift"
        ]

        for relativePath in sourcePaths {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertFalse(source.contains("setCenterButtonEnabled"), relativePath)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @discardableResult
    private func embedInTraitContainer(
        _ child: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> UINavigationController {
        let navigationController = embedInDetachedTraitContainer(
            child,
            horizontalSizeClass: horizontalSizeClass,
            contentSizeCategory: contentSizeCategory
        )
        guard let parent = navigationController.parent else {
            preconditionFailure("The retained trait container must own its navigation child")
        }
        let window = makeTraitWindow(
            horizontalSizeClass: horizontalSizeClass,
            contentSizeCategory: contentSizeCategory
        )
        parent.view.frame = window.bounds
        navigationController.view.frame = parent.view.bounds
        retainedTraitWindows.append(window)
        window.addSubview(parent.view)
        window.layoutIfNeeded()
        return navigationController
    }

    private func makeTraitWindow(
        horizontalSizeClass: UIUserInterfaceSizeClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> TraitWindow {
        guard let fixtureWindowScene else {
            preconditionFailure("The fixture window scene must be captured during setUp")
        }
        return TraitWindow(
            windowScene: fixtureWindowScene,
            horizontalSizeClass: horizontalSizeClass,
            contentSizeCategory: contentSizeCategory
        )
    }

    private func quiesceContactsDatasetWorkBeforeFixtureDetachment(
        _ controllers: [ContactsViewController]
    ) async {
        controllers.forEach { controller in
            controller.unsubscribe()
            controller.datasetGeneration += 1
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        for controller in controllers {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.updateQueue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }
    }

    @discardableResult
    private func embedInDetachedTraitContainer(
        _ child: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> UINavigationController {
        let navigationController: UINavigationController
        if let child = child as? UINavigationController {
            navigationController = child
        } else {
            navigationController = UINavigationController(rootViewController: child)
        }
        let parent = UIViewController()
        parent.loadViewIfNeeded()
        parent.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        parent.addChild(navigationController)
        parent.setOverrideTraitCollection(
            UITraitCollection(traitsFrom: [
                UITraitCollection(horizontalSizeClass: horizontalSizeClass),
                UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
            ]),
            forChild: navigationController
        )
        navigationController.loadViewIfNeeded()
        navigationController.view.frame = parent.view.bounds
        navigationController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.addSubview(navigationController.view)
        navigationController.didMove(toParent: parent)
        navigationController.topViewController?.loadViewIfNeeded()
        retainedTraitContainers.append(parent)
        return navigationController
    }

    private func layout(_ navigationController: UINavigationController, root: UIViewController) {
        navigationController.view.superview?.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        root.view.layoutIfNeeded()
    }

    private func frame(of view: UIView, in container: UIView) -> CGRect {
        view.convert(view.bounds, to: container)
    }

    private func assertAction(
        _ button: UIButton,
        isVisible: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(button.isHidden, !isVisible, file: file, line: line)
        XCTAssertEqual(button.isEnabled, isVisible, file: file, line: line)
        XCTAssertEqual(button.isUserInteractionEnabled, isVisible, file: file, line: line)
        XCTAssertEqual(button.isAccessibilityElement, isVisible, file: file, line: line)
        XCTAssertEqual(button.accessibilityElementsHidden, !isVisible, file: file, line: line)
    }

    private func addEnabledAccount(owner: String) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let account = AccountStorageItem()
            account.jid = owner
            account.username = owner
            account.enabled = true
            account.colorKey = "blue"
            realm.add(account, update: .modified)
        }
    }

    private func addNotification(owner: String, uniqueId: String, isRead: Bool) {
        let realm = try! WRealm.safe()
        try! realm.write {
            let item = NotificationStorageItem()
            item.owner = owner
            item.jid = "server@example.com"
            item.uniqueId = uniqueId
            item.primary = NotificationStorageItem.genPrimary(
                owner: owner,
                jid: item.jid,
                uniqueId: uniqueId
            )
            item.category = .info
            item.isRead = isRead
            item.text = "Notification"
            item.fallbackText = "Notification"
            item.shouldShow = true
            item.date = Date(timeIntervalSince1970: 1_711_283_200)
            realm.add(item, update: .modified)
        }
    }

    private func setNotificationRead(owner: String, uniqueId: String, isRead: Bool) {
        let realm = try! WRealm.safe()
        let primary = NotificationStorageItem.genPrimary(
            owner: owner,
            jid: "server@example.com",
            uniqueId: uniqueId
        )
        try! realm.write {
            realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary)?.isRead = isRead
        }
    }
}
