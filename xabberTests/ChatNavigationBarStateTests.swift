//
//  ChatNavigationBarStateTests.swift
//  xabberTests
//
//  Created by Codex on 01.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatNavigationBarStateTests: XCTestCase {
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

    private var retainedTraitWindows: [UIWindow] = []

    override func tearDown() {
        retainedTraitWindows.forEach { $0.isHidden = true }
        retainedTraitWindows.removeAll()
        super.tearDown()
    }

    func testGroupNavbarStatusUsesMemberCountAndRejectsResourcePresence() {
        XCTAssertFalse(
            ChatGroupNavbarStatusPolicy.allowsResourcePresence(
                conversationType: .group
            )
        )
        XCTAssertTrue(
            ChatGroupNavbarStatusPolicy.allowsResourcePresence(
                conversationType: .regular
            )
        )

        var localizationRequests: [(fallback: String, id: String, arguments: [String])] = []
        let localize: (String, String, [String]) -> String = { fallback, id, arguments in
            localizationRequests.append((fallback, id, arguments))
            if id == "groupchats_some_members", let count = arguments.first {
                return "\(count) members"
            }
            return fallback
        }

        XCTAssertEqual(
            ChatGroupNavbarStatusPolicy.localizedText(
                memberCount: 0,
                localize: localize
            ),
            "No members"
        )
        XCTAssertEqual(
            ChatGroupNavbarStatusPolicy.localizedText(
                memberCount: 1,
                localize: localize
            ),
            "1 member"
        )
        XCTAssertEqual(
            ChatGroupNavbarStatusPolicy.localizedText(
                memberCount: 5,
                localize: localize
            ),
            "5 members"
        )
        XCTAssertEqual(localizationRequests.map(\.id), [
            "groupchats_no_members",
            "groupchats_one_member",
            "groupchats_some_members"
        ])
        XCTAssertEqual(localizationRequests.last?.arguments, ["5"])
    }

    func testGroupInitStatusReplacesContactPresenceFallbackWithCanonicalMemberCount() {
        let chat = ChatViewController()
        chat.conversationType = .group
        chat.contactStatus = "last seen recently"
        chat.canonicalGroupProjectionState = ChatGroupProjectionState(
            pinnedMessageIDs: nil,
            selfMemberID: "self-1",
            members: [GroupMember(id: "self-1")],
            memberCount: 5,
            capabilities: GroupCapabilities.derive(role: nil, permissionSet: nil),
            isActive: true,
            isDeleted: false
        )

        chat.initStatus()

        let expected = ChatGroupNavbarStatusPolicy.localizedText(memberCount: 5)
        XCTAssertEqual(chat.contactStatus, expected)
        XCTAssertEqual(chat.statusTextObserver.value, expected)
        XCTAssertFalse(chat.shouldShowNormalStatus)
    }

    func testReplacingStaleRightItemsLeavesOnlyRequestedItem() {
        let navigationItem = UINavigationItem()
        let staleSingle = makeBarButtonItem(identifier: "stale-single")
        let staleFirst = makeBarButtonItem(identifier: "stale-first")
        let staleSecond = makeBarButtonItem(identifier: "stale-second")
        let replacement = makeBarButtonItem(identifier: "replacement")

        navigationItem.rightBarButtonItem = staleSingle
        navigationItem.rightBarButtonItems = [staleFirst, staleSecond]

        NavigationBarItemOwnership.set(
            .item(replacement),
            on: navigationItem,
            side: .right,
            animated: false
        )

        XCTAssertTrue(navigationItem.rightBarButtonItem === replacement)
        XCTAssertEqual(navigationItem.rightBarButtonItems?.count, 1)
        XCTAssertTrue(navigationItem.rightBarButtonItems?.first === replacement)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === staleSingle }) ?? true)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === staleFirst }) ?? true)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === staleSecond }) ?? true)
    }

    func testReplacingChatSearchAndListModesDoesNotRetainStaleItems() {
        let navigationItem = UINavigationItem()
        let listLeft = makeBarButtonItem(identifier: "list-left")
        let listRightFirst = makeBarButtonItem(identifier: "list-right-first")
        let listRightSecond = makeBarButtonItem(identifier: "list-right-second")
        let chatAvatar = makeBarButtonItem(identifier: "chat-avatar")
        let searchItem = makeBarButtonItem(identifier: "search")

        NavigationBarItemOwnership.apply(
            to: navigationItem,
            left: .item(listLeft),
            right: .items([listRightFirst, listRightSecond]),
            animated: false
        )
        XCTAssertTrue(navigationItem.leftBarButtonItem === listLeft)
        XCTAssertEqual(navigationItem.rightBarButtonItems?.count, 2)

        NavigationBarItemOwnership.apply(
            to: navigationItem,
            left: NavigationBarItemOwnership.Assignment.none,
            right: .item(chatAvatar),
            animated: false
        )
        XCTAssertNil(navigationItem.leftBarButtonItem)
        XCTAssertNil(navigationItem.leftBarButtonItems)
        XCTAssertTrue(navigationItem.rightBarButtonItem === chatAvatar)
        XCTAssertEqual(navigationItem.rightBarButtonItems?.count, 1)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === listRightFirst }) ?? true)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === listRightSecond }) ?? true)

        NavigationBarItemOwnership.apply(
            to: navigationItem,
            left: NavigationBarItemOwnership.Assignment.none,
            right: .item(searchItem),
            animated: false
        )
        XCTAssertTrue(navigationItem.rightBarButtonItem === searchItem)
        XCTAssertEqual(navigationItem.rightBarButtonItems?.count, 1)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === chatAvatar }) ?? true)

        NavigationBarItemOwnership.apply(
            to: navigationItem,
            left: .item(listLeft),
            right: .items([listRightFirst, listRightSecond]),
            animated: false
        )
        XCTAssertTrue(navigationItem.leftBarButtonItem === listLeft)
        XCTAssertEqual(navigationItem.rightBarButtonItems?.count, 2)
        XCTAssertFalse(navigationItem.rightBarButtonItems?.contains(where: { $0 === searchItem }) ?? true)
    }

    func testChatAvatarItemFactoryProducesStockBarButtonItem() throws {
        let image = makeImage()
        let avatarImage = ChatNavigationAvatarItemFactory.avatarImage(from: image)
        let item = ChatNavigationAvatarItemFactory.makeItem(
            image: avatarImage,
            target: self,
            action: #selector(dummyAction)
        )

        XCTAssertNil(item.customView)
        let itemImage = try XCTUnwrap(item.image)
        XCTAssertEqual(ChatNavigationAvatarItemFactory.imageSize, 32, accuracy: 0.001)
        XCTAssertEqual(itemImage.size.width, 32, accuracy: 0.001)
        XCTAssertEqual(itemImage.size.height, 32, accuracy: 0.001)
        XCTAssertEqual(itemImage.renderingMode, .alwaysOriginal)
        XCTAssertEqual(item.accessibilityIdentifier, ChatNavigationAvatarItemFactory.accessibilityIdentifier)
    }

    func testSavedMessagesAvatarFactoryUsesDefaultNavbarAvatarImage() throws {
        let image = try XCTUnwrap(ChatNavigationAvatarItemFactory.savedMessagesImage(
            backgroundColor: .systemBlue,
            iconTintColor: .white
        ))

        XCTAssertEqual(image.size.width, 32, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 32, accuracy: 0.001)
    }

    func testAccountNavigationButtonDefersAvatarAndStatusRenderingUntilSourceReturns() {
        let button = AccountNavButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        let sentinelImage = makeImage()
        button.avatarView.image = sentinelImage
        let initialStatusColor = button.statusView.color

        button.setRenderingFrozen(true)
        button.update(jid: "owner@example.com", status: .online)

        XCTAssertTrue(button.isRenderingFrozen)
        XCTAssertTrue(button.avatarView.image === sentinelImage)
        XCTAssertTrue(button.statusView.color.isEqual(initialStatusColor))

        button.setRenderingFrozen(false)

        XCTAssertFalse(button.isRenderingFrozen)
        XCTAssertNotNil(button.avatarView.image)
        XCTAssertFalse(button.avatarView.image === sentinelImage)
        XCTAssertFalse(button.statusView.color.isEqual(initialStatusColor))
        XCTAssertEqual(button.intrinsicContentSize, CGSize(width: 44, height: 44))
    }

    func testChatAvatarUnavailableCompletionTerminalizesUnchangedSourceAndKeepsGeneratedFallback() {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "avatar-nil-\(UUID().uuidString)@example.com"
        chat.conversationType = .regular
        chat.navigationAvatarItem = ChatNavigationAvatarItemFactory.makeItem(
            image: nil,
            target: nil,
            action: #selector(dummyAction)
        )
        var loadCount = 0
        chat.navigationAvatarImageLoader = { _, _, _, _, completion in
            loadCount += 1
            completion(.unavailable)
        }

        chat.refreshNavigationAvatarImage()
        let generatedFallback = chat.navigationAvatarItem?.image
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        chat.refreshNavigationAvatarImage()

        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(chat.navigationAvatarItem?.image === generatedFallback)
        XCTAssertEqual(
            chat.navigationAvatarTerminalRequestKey,
            chat.navigationAvatarRequestKey
        )
        XCTAssertNil(chat.navigationAvatarPendingResolvedRequestKey)
        XCTAssertNil(chat.navigationAvatarPendingResolvedImage)

        chat.jid = "avatar-next-\(UUID().uuidString)@example.com"
        chat.refreshNavigationAvatarImage()

        XCTAssertEqual(loadCount, 2, "a changed source key must permit one new load")
    }

    func testChatAvatarTransientFailureRetriesAndKeepsFallbackUntilResolved() {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "avatar-retry-\(UUID().uuidString)@example.com"
        chat.conversationType = .regular
        chat.navigationAvatarItem = ChatNavigationAvatarItemFactory.makeItem(
            image: nil,
            target: nil,
            action: #selector(dummyAction)
        )
        chat.navigationAvatarRetryDelayProvider = { attempt in
            attempt == 0 ? 0 : nil
        }
        let loadedImage = makeImage()
        var loadCount = 0
        chat.navigationAvatarImageLoader = { _, _, _, _, completion in
            loadCount += 1
            completion(loadCount == 1 ? .failed : .loaded(loadedImage))
        }

        chat.refreshNavigationAvatarImage()
        let generatedFallback = chat.navigationAvatarItem?.image
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(loadCount, 2)
        XCTAssertTrue(chat.navigationAvatarItem?.image === generatedFallback)
        XCTAssertEqual(
            chat.navigationAvatarTerminalRequestKey,
            chat.navigationAvatarRequestKey
        )
        XCTAssertEqual(
            chat.navigationAvatarPendingResolvedRequestKey,
            chat.navigationAvatarRequestKey
        )
        XCTAssertNotNil(chat.navigationAvatarPendingResolvedImage)
        XCTAssertNil(chat.navigationAvatarRetryWorkItem)

        let rootViewController = UIViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let window = TraitWindow(horizontalSizeClass: .compact)
        window.rootViewController = navigationController
        navigationController.loadViewIfNeeded()
        navigationController.view.frame = window.bounds
        window.makeKeyAndVisible()
        retainedTraitWindows.append(window)
        navigationController.pushViewController(chat, animated: false)
        chat.loadViewIfNeeded()
        chat.configureNavbar()

        XCTAssertEqual(loadCount, 2)
        XCTAssertFalse(chat.navigationAvatarItem?.image === generatedFallback)
        XCTAssertNil(chat.navigationAvatarPendingResolvedRequestKey)
        XCTAssertNil(chat.navigationAvatarPendingResolvedImage)
    }

    func testChatAvatarCompletionBeforeTopVisibleAppliesPendingImageOnceAfterPush() {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "avatar-hidden-\(UUID().uuidString)@example.com"
        chat.conversationType = .regular
        chat.navigationAvatarItem = ChatNavigationAvatarItemFactory.makeItem(
            image: nil,
            target: nil,
            action: #selector(dummyAction)
        )
        let loadedImage = makeImage()
        var loadCount = 0
        chat.navigationAvatarImageLoader = { _, _, _, _, completion in
            loadCount += 1
            completion(.loaded(loadedImage))
        }

        chat.refreshNavigationAvatarImage()
        let generatedFallback = chat.navigationAvatarItem?.image
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        chat.refreshNavigationAvatarImage()

        XCTAssertFalse(chat.isTopVisibleChatController)
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(chat.navigationAvatarItem?.image === generatedFallback)
        XCTAssertEqual(
            chat.navigationAvatarTerminalRequestKey,
            chat.navigationAvatarRequestKey
        )
        XCTAssertEqual(
            chat.navigationAvatarPendingResolvedRequestKey,
            chat.navigationAvatarRequestKey
        )
        XCTAssertNotNil(chat.navigationAvatarPendingResolvedImage)

        let rootViewController = UIViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let window = TraitWindow(horizontalSizeClass: .compact)
        window.rootViewController = navigationController
        navigationController.loadViewIfNeeded()
        navigationController.view.frame = window.bounds
        window.makeKeyAndVisible()
        retainedTraitWindows.append(window)
        navigationController.pushViewController(chat, animated: false)
        chat.loadViewIfNeeded()
        navigationController.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        chat.configureNavbar()

        let resolvedImage = chat.navigationAvatarItem?.image
        XCTAssertFalse(resolvedImage === generatedFallback)
        XCTAssertNil(chat.navigationAvatarPendingResolvedRequestKey)
        XCTAssertNil(chat.navigationAvatarPendingResolvedImage)

        chat.configureNavbar()
        chat.refreshNavigationAvatarImage()

        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(chat.navigationAvatarItem?.image === resolvedImage)
    }

    func testCompactChatConfigureNavbarKeepsUIKitStockNavigationAppearance() {
        withInterfaceType(.split) {
            let viewController = ChatViewController()
            let navigationController = UINavigationController(rootViewController: viewController)
            let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

            container.loadViewIfNeeded()
            viewController.configureNavbar()

            assertNativeChatNavigationItemAppearance(viewController)
            assertChatExtendsUnderNavigationBar(viewController)
        }
    }

    func testRegularChatConfigureNavbarKeepsUIKitStockNavigationAppearance() {
        withInterfaceType(.split) {
            let viewController = ChatViewController()
            let navigationController = UINavigationController(rootViewController: viewController)
            let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
            let standardAppearance = navigationController.navigationBar.standardAppearance
            let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
            let compactAppearance = navigationController.navigationBar.compactAppearance
            let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance
            let isTranslucent = navigationController.navigationBar.isTranslucent

            container.loadViewIfNeeded()
            viewController.configureNavbar()

            assertNativeChatNavigationItemAppearance(viewController)
            XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
            XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
            XCTAssertEqual(navigationController.navigationBar.isTranslucent, isTranslucent)
            assertChatExtendsUnderNavigationBar(viewController)
        }
    }

    func testRepeatedNormalChatNavbarConfigurationPreservesLeftItemAndRightAvatarIdentity() {
        let rootViewController = UIViewController()
        let viewController = ChatViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.pushViewController(viewController, animated: false)
        viewController.loadViewIfNeeded()

        let systemOwnedLeftItemProxy = makeBarButtonItem(identifier: "system-back-proxy")
        viewController.navigationItem.leftBarButtonItem = systemOwnedLeftItemProxy

        viewController.configureNavbar()
        let firstAvatarItem = viewController.navigationItem.rightBarButtonItem
        let firstAvatarImage = firstAvatarItem?.image
        let firstTitle = viewController.titleLabel.attributedText
        XCTAssertTrue(
            viewController.navigationItem.leftBarButtonItem === systemOwnedLeftItemProxy,
            "normal chat setup must not clear UIKit-owned left navigation state"
        )

        viewController.configureNavbar()

        XCTAssertTrue(viewController.navigationItem.leftBarButtonItem === systemOwnedLeftItemProxy)
        XCTAssertTrue(
            viewController.navigationItem.rightBarButtonItem === firstAvatarItem,
            "repeated lifecycle callbacks must not replace an unchanged avatar item during push"
        )
        XCTAssertTrue(
            viewController.navigationItem.rightBarButtonItem?.image === firstAvatarImage,
            "repeated lifecycle callbacks must not reinstall an unchanged avatar image"
        )
        XCTAssertTrue(
            viewController.titleLabel.attributedText === firstTitle,
            "repeated lifecycle callbacks must not reinstall unchanged title content"
        )
        XCTAssertFalse(viewController.navigationItem.hidesBackButton)
        XCTAssertFalse(
            viewController.navigationItem.leftItemsSupplementBackButton,
            "normal chat chrome must leave the leading side exclusively to UIKit's native Back item"
        )
        XCTAssertTrue(navigationController.popViewController(animated: false) === viewController)
    }

    func testSavedChatNavbarUsesStableSearchItemAndNoninteractiveTitle() throws {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "favorites.example.com"
        chat.conversationType = .saved
        chat.loadViewIfNeeded()

        chat.configureNavbar()
        let searchItem = try XCTUnwrap(chat.savedMessagesSearchNavigationItem)

        XCTAssertTrue(chat.navigationItem.rightBarButtonItem === searchItem)
        XCTAssertEqual(
            searchItem.accessibilityIdentifier,
            ChatSearchAccessibilityIdentifier.entry
        )
        XCTAssertEqual(
            searchItem.accessibilityLabel,
            "Search".localizeString(id: "search", arguments: [])
        )
        XCTAssertNotNil(searchItem.image)
        XCTAssertTrue(searchItem.target === chat)
        XCTAssertEqual(
            searchItem.action,
            #selector(ChatViewController.activateSavedMessagesSearch(_:))
        )
        XCTAssertFalse(chat.titleButton.isUserInteractionEnabled)
        XCTAssertFalse(chat.titleButton.isAccessibilityElement)
        XCTAssertTrue(
            chat.titleButton.actions(
                forTarget: chat,
                forControlEvent: .touchUpInside
            )?.isEmpty ?? true
        )

        chat.configureNavbar()

        XCTAssertTrue(chat.savedMessagesSearchNavigationItem === searchItem)
        XCTAssertTrue(chat.navigationItem.rightBarButtonItem === searchItem)
    }

    func testSavedChatSearchItemActivatesStandardInChatSearch() throws {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "favorites.example.com"
        chat.conversationType = .saved
        chat.loadViewIfNeeded()
        chat.configureNavbar()
        let searchItem = try XCTUnwrap(chat.savedMessagesSearchNavigationItem)
        let action = try XCTUnwrap(searchItem.action)

        XCTAssertTrue(
            UIApplication.shared.sendAction(
                action,
                to: searchItem.target,
                from: searchItem,
                for: nil
            )
        )

        XCTAssertTrue(chat.inSearchMode.value)
        XCTAssertTrue(chat.searchPresentationState.isActive)
    }

    func testSavedChatSearchExitRestoresSameSearchItem() throws {
        let rootViewController = UIViewController()
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "favorites.example.com"
        chat.conversationType = .saved
        let navigationController = UINavigationController(
            rootViewController: rootViewController
        )
        navigationController.pushViewController(chat, animated: false)
        chat.loadViewIfNeeded()
        chat.configureNavbar()
        let searchItem = try XCTUnwrap(chat.savedMessagesSearchNavigationItem)

        chat.inSearchMode.accept(true)
        chat.navigationItem.titleView = nil
        chat.navigationItem.rightBarButtonItem = nil
        chat.inSearchMode.accept(false)

        XCTAssertFalse(chat.restoreNormalNavbarAfterSearchIfNeeded())
        XCTAssertTrue(chat.navigationItem.titleView === chat.titleButton)
        XCTAssertTrue(chat.navigationItem.rightBarButtonItem === searchItem)
        XCTAssertFalse(chat.navigationItem.hidesBackButton)
    }

    func testSavedChatShowInfoDoesNotPresentContactCard() {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "favorites.example.com"
        chat.conversationType = .saved
        let navigationController = UINavigationController(
            rootViewController: chat
        )
        let window = TraitWindow(horizontalSizeClass: .compact)
        window.rootViewController = navigationController
        window.frame = UIScreen.main.bounds
        window.makeKeyAndVisible()
        retainedTraitWindows.append(window)
        navigationController.loadViewIfNeeded()
        chat.loadViewIfNeeded()

        chat.showInfo()

        XCTAssertNil(chat.presentedViewController)
        XCTAssertNil(navigationController.presentedViewController)
    }

    func testRegularAndGroupChatNavbarsKeepInfoActions() throws {
        for conversationType in [
            ClientSynchronizationManager.ConversationType.regular,
            .group
        ] {
            let chat = ChatViewController()
            chat.owner = "owner@example.com"
            chat.jid = "conversation@example.com"
            chat.conversationType = conversationType
            chat.loadViewIfNeeded()

            chat.configureNavbar()

            let avatarItem = try XCTUnwrap(chat.navigationAvatarItem)
            XCTAssertTrue(chat.navigationItem.rightBarButtonItem === avatarItem)
            XCTAssertTrue(avatarItem.target === chat)
            XCTAssertEqual(
                avatarItem.action,
                #selector(ChatViewController.showInfo)
            )
            XCTAssertTrue(chat.titleButton.isUserInteractionEnabled)
            XCTAssertTrue(chat.titleButton.isAccessibilityElement)
            XCTAssertEqual(
                chat.titleButton.actions(
                    forTarget: chat,
                    forControlEvent: .touchUpInside
                ),
                [NSStringFromSelector(#selector(ChatViewController.onTitleButtonTouchUp(_:)))]
            )
        }
    }

    func testAnimatedPushFromRealLastChatsKeepsNativeBackAndAvatarStableDuringCallbacks() throws {
        try withInterfaceType(.tabs) {
            let lastChats = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: lastChats)
            let window = TraitWindow(horizontalSizeClass: .compact)
            window.rootViewController = navigationController
            navigationController.loadViewIfNeeded()
            navigationController.view.frame = window.bounds
            window.makeKeyAndVisible()
            retainedTraitWindows.append(window)
            lastChats.loadViewIfNeeded()
            lastChats.configureBars(updateNavigationItems: true)
            navigationController.view.layoutIfNeeded()
            settleNavigationLifecycle(navigationController)

            XCTAssertEqual(lastChats.navigationItem.backButtonDisplayMode, .minimal)
            XCTAssertTrue(lastChats.navigationItem.leftBarButtonItem === lastChats.accountBarButton)

            let token = UUID()
            let target = LastChatsNavigationSingleFlightCoordinator.Target(
                owner: "owner@example.com",
                jid: "romeo@example.com",
                conversationType: .regular
            )
            let seededBackItem = UIBarButtonItem(
                title: "Chats",
                style: .plain,
                target: self,
                action: #selector(legacyBackAction)
            )
            seededBackItem.accessibilityIdentifier = "legacy-back"
            lastChats.navigationItem.backBarButtonItem = seededBackItem
            _ = lastChats.chatNavigationSingleFlight.request(target: target, token: token)
            lastChats.beginOutgoingChatOpenNavigationDeferral(
                token: token,
                preparationTimeout: 60
            )
            let nativeBackItem = try XCTUnwrap(
                lastChats.navigationItem.backBarButtonItem,
                "the source must provide UIKit a stable Back item before the animated push begins"
            )
            XCTAssertTrue(
                nativeBackItem === seededBackItem,
                "normalization must retain an existing source Back item identity"
            )
            XCTAssertEqual(
                nativeBackItem.title,
                "",
                "the explicit UIKit-owned Back item must not publish a visual title"
            )
            XCTAssertNil(
                nativeBackItem.target,
                "the source Back item must leave activation in UINavigationController ownership"
            )
            XCTAssertNil(
                nativeBackItem.action,
                "the source Back item must not replace UIKit's native pop action"
            )
            XCTAssertFalse(
                nativeBackItem.accessibilityLabel?.isEmpty ?? true,
                "the title-free native Back item must retain localized accessibility semantics"
            )
            nativeBackItem.title = "Chats"
            nativeBackItem.target = self
            nativeBackItem.action = #selector(legacyBackAction)
            lastChats.beginOutgoingChatOpenNavigationDeferral(
                token: token,
                preparationTimeout: 60
            )
            XCTAssertTrue(lastChats.navigationItem.backBarButtonItem === nativeBackItem)
            XCTAssertEqual(nativeBackItem.title, "")
            XCTAssertNil(nativeBackItem.target)
            XCTAssertNil(nativeBackItem.action)
            XCTAssertTrue(lastChats.commitChatNavigationPush(token: token, target: target))

            let chat = ChatViewController()
            chat.owner = target.owner
            chat.jid = target.jid
            chat.conversationType = target.conversationType
            // `showStacked` prepares the destination before committing the
            // real push. Mirror that contract so UIKit receives stable title
            // and avatar items at the start of its transition.
            chat.loadViewIfNeeded()
            chat.configureNavbar()
            navigationController.pushViewController(chat, animated: true)

            // These callbacks reproduce the first-login churn that used to
            // replace source and destination navigation items during push.
            chat.configureNavbar()
            lastChats.configureBars(updateNavigationItems: true)
            chat.configureNavbar()

            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            navigationController.view.layoutIfNeeded()
            navigationController.navigationBar.layoutIfNeeded()

            XCTAssertTrue(navigationController.topViewController === chat)
            XCTAssertTrue(navigationController.navigationBar.topItem === chat.navigationItem)
            XCTAssertTrue(navigationController.navigationBar.backItem === lastChats.navigationItem)
            XCTAssertTrue(
                navigationController.navigationBar.backItem?.backBarButtonItem === nativeBackItem,
                "repeated source and destination callbacks must preserve the native Back item identity"
            )
            XCTAssertEqual(
                navigationController.navigationBar.backItem?.backBarButtonItem?.title,
                "",
                "the animated push must keep the native Back indicator visually title-free"
            )
            XCTAssertTrue(
                lastChats.isNavigationTransitionActive,
                "the hidden source must remain frozen until it is both top and appeared"
            )
            XCTAssertFalse(chat.navigationItem.hidesBackButton)
            XCTAssertFalse(chat.navigationItem.leftItemsSupplementBackButton)
            XCTAssertNil(chat.navigationItem.leftBarButtonItem)
            XCTAssertFalse(
                isEffectivelyVisible(
                    lastChats.accountNavButton,
                    in: navigationController.navigationBar
                ),
                "UIKit may retain transition views, but the source account control must not remain visible or interactive"
            )

            let avatarItem = try XCTUnwrap(chat.navigationItem.rightBarButtonItem)
            XCTAssertTrue(avatarItem === chat.navigationAvatarItem)
            XCTAssertNotNil(avatarItem.image)

            let navigationBar = navigationController.navigationBar
            let backFrame = try XCTUnwrap(
                visibleNavigationItemFrame(
                    in: navigationBar,
                    horizontalRegion: 0...88
                ),
                "animated push must expose UIKit's native leading Back platter"
            )
            XCTAssertGreaterThanOrEqual(backFrame.width, 44)
            XCTAssertGreaterThanOrEqual(backFrame.height, 44)
            XCTAssertTrue(
                visibleTexts(
                    in: navigationBar,
                    horizontalRegion: backFrame.minX...backFrame.maxX
                ).isEmpty,
                "the native Back affordance must render only the chevron, without a visible source title"
            )
            XCTAssertEqual(
                navigationBar.backItem?
                    .backBarButtonItem?
                    .accessibilityIdentifier,
                LastChatsViewController.nativeChatBackAccessibilityIdentifier
            )

            let avatarControl = try XCTUnwrap(
                visibleControl(
                    in: navigationBar,
                    horizontalRegion: max(0, navigationBar.bounds.width - 88)...navigationBar.bounds.width
                ),
                "the generated chat avatar must be installed in the first visible navigation frame"
            )
            let avatarHitTarget = effectiveInteractiveFrame(
                for: avatarControl,
                in: navigationBar
            )
            XCTAssertGreaterThanOrEqual(avatarHitTarget.width, 44)
            XCTAssertGreaterThanOrEqual(avatarHitTarget.height, 44)

            // iOS 26 hosts the native Back action in a private portal that is
            // intentionally absent from hosted XCTest automationElements.
            // The logical native owner and 44-point platter are asserted
            // above; exercise the same UINavigationController pop lifecycle
            // directly here. End-to-end touch activation remains a UI/live
            // acceptance scenario.
            XCTAssertTrue(
                navigationController.popViewController(animated: true) === chat
            )
            settleNavigationLifecycle(
                navigationController,
                duration: 0.8
            )

            XCTAssertTrue(
                navigationController.topViewController === lastChats,
                "the native navigation stack must return to Last Chats"
            )
            XCTAssertFalse(lastChats.isNavigationTransitionActive)
            XCTAssertTrue(lastChats.navigationItem.leftBarButtonItem === lastChats.accountBarButton)
        }
    }

    @objc
    private func legacyBackAction() {}

    func testNarrowChatTitleUsesStableMaximumWidthConstraintWithoutMinimumWidthChurn() throws {
        let rootViewController = UIViewController()
        let chat = ChatViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.pushViewController(chat, animated: false)
        navigationController.view.frame = CGRect(x: 0, y: 0, width: 240, height: 844)
        chat.loadViewIfNeeded()
        chat.configureNavbar()
        navigationController.view.layoutIfNeeded()
        navigationController.navigationBar.layoutIfNeeded()

        let widthConstraint = try XCTUnwrap(
            chat.titleButton.constraints.first(where: {
                $0.firstItem === chat.titleButton && $0.firstAttribute == .width
            })
        )
        XCTAssertEqual(widthConstraint.relation, .lessThanOrEqual)
        XCTAssertLessThanOrEqual(widthConstraint.constant, 64.5)
        let initialConstraintIdentity = ObjectIdentifier(widthConstraint)
        let initialConstant = widthConstraint.constant

        chat.viewDidLayoutSubviews()
        chat.viewDidLayoutSubviews()

        let finalWidthConstraint = try XCTUnwrap(
            chat.titleButton.constraints.first(where: {
                $0.firstItem === chat.titleButton && $0.firstAttribute == .width
            })
        )
        XCTAssertEqual(ObjectIdentifier(finalWidthConstraint), initialConstraintIdentity)
        XCTAssertEqual(finalWidthConstraint.constant, initialConstant, accuracy: 0.001)
    }

    func testRegularWidthChatTitleUsesAvailableSpaceBetweenNavigationItems() throws {
        let rootViewController = UIViewController()
        let chat = ChatViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.pushViewController(chat, animated: false)
        navigationController.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        chat.loadViewIfNeeded()
        chat.configureNavbar()
        navigationController.view.layoutIfNeeded()
        navigationController.navigationBar.layoutIfNeeded()
        chat.viewDidLayoutSubviews()

        let widthConstraint = try XCTUnwrap(
            chat.titleButton.constraints.first(where: {
                $0.firstItem === chat.titleButton && $0.firstAttribute == .width
            })
        )
        let expectedSafeCenterWidth = navigationController.navigationBar.bounds.width - 176

        XCTAssertEqual(widthConstraint.relation, .lessThanOrEqual)
        XCTAssertEqual(widthConstraint.constant, expectedSafeCenterWidth, accuracy: 0.5)
        XCTAssertGreaterThan(
            widthConstraint.constant,
            140,
            "a regular-width chat title should not keep the legacy fixed cap when navbar space is free"
        )
    }

    func testChatTitleKeepsLastWidthCapWhenNavigationGeometryIsUnavailable() throws {
        let chat = ChatViewController()
        chat.loadViewIfNeeded()
        chat.configureNavbar()

        let widthConstraint = try XCTUnwrap(
            chat.titleButton.constraints.first(where: {
                $0.firstItem === chat.titleButton && $0.firstAttribute == .width
            })
        )
        let establishedWidth = widthConstraint.constant

        chat.view.frame = .zero
        chat.viewDidLayoutSubviews()

        XCTAssertEqual(
            widthConstraint.constant,
            establishedWidth,
            accuracy: 0.001,
            "a transient zero-width layout must not collapse the last safe title width"
        )
        XCTAssertGreaterThan(establishedWidth, 0)
    }

    func testCancelledInteractivePopKeepsChatChromeAndHiddenLastChatsFrozen() throws {
        try withInterfaceType(.tabs) {
            let lastChats = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: lastChats)
            let window = TraitWindow(horizontalSizeClass: .compact)
            window.rootViewController = navigationController
            navigationController.loadViewIfNeeded()
            navigationController.view.frame = window.bounds
            window.makeKeyAndVisible()
            retainedTraitWindows.append(window)
            lastChats.loadViewIfNeeded()
            lastChats.configureBars(updateNavigationItems: true)
            navigationController.view.layoutIfNeeded()
            settleNavigationLifecycle(navigationController)

            let token = UUID()
            let target = LastChatsNavigationSingleFlightCoordinator.Target(
                owner: "owner@example.com",
                jid: "romeo@example.com",
                conversationType: .regular
            )
            _ = lastChats.chatNavigationSingleFlight.request(target: target, token: token)
            lastChats.beginOutgoingChatOpenNavigationDeferral(
                token: token,
                preparationTimeout: 60
            )
            XCTAssertTrue(lastChats.commitChatNavigationPush(token: token, target: target))
            XCTAssertTrue(lastChats.chatNavigationSingleFlight.markPresented(token: token, target: target))

            let chat = ChatViewController()
            chat.owner = target.owner
            chat.jid = target.jid
            chat.conversationType = target.conversationType
            navigationController.pushViewController(chat, animated: false)
            chat.loadViewIfNeeded()
            chat.configureNavbar()
            settleNavigationLifecycle(navigationController)
            let avatarItemBeforeCancellation = try XCTUnwrap(chat.navigationAvatarItem)
            let sourceSearchController = UISearchController(searchResultsController: nil)
            lastChats.navigationItem.searchController = sourceSearchController
            lastChats.configureSearchBar()
            XCTAssertTrue(lastChats.navigationItem.searchController === sourceSearchController)
            var staleTransitionWorkDidRun = false
            XCTAssertTrue(
                lastChats.deferUntilNavigationTransitionCompletesIfNeeded {
                    staleTransitionWorkDidRun = true
                }
            )

            // Hosted XCTest defers custom interactive-transition contexts
            // until the test call stack returns. Exercise the exact production
            // completion callbacks deterministically instead of replacing
            // UIKit's private edge-pop machinery.
            chat.beginNavigationTransitionDeferralIfNeeded(
                forceActiveWithoutCoordinator: true
            )
            XCTAssertTrue(chat.isNavigationTransitionActive)
            lastChats.configureBars(updateNavigationItems: true)
            lastChats.completeNavigationTransitionDeferral(cancelled: true)
            chat.completeNavigationTransitionDeferral(cancelled: true)
            settleNavigationLifecycle(navigationController)

            XCTAssertTrue(navigationController.topViewController === chat)
            XCTAssertTrue(navigationController.navigationBar.topItem === chat.navigationItem)
            XCTAssertTrue(chat.navigationAvatarItem === avatarItemBeforeCancellation)
            XCTAssertTrue(chat.navigationItem.rightBarButtonItem === avatarItemBeforeCancellation)
            XCTAssertNotNil(avatarItemBeforeCancellation.image)
            XCTAssertFalse(chat.navigationItem.hidesBackButton)
            XCTAssertFalse(chat.navigationItem.leftItemsSupplementBackButton)
            XCTAssertTrue(
                lastChats.isNavigationTransitionActive,
                "a cancelled pop must not thaw the still-hidden Last Chats source"
            )
            XCTAssertTrue(lastChats.accountNavButton.isRenderingFrozen)
            XCTAssertTrue(lastChats.navigationItem.searchController === sourceSearchController)
            XCTAssertFalse(staleTransitionWorkDidRun)

            XCTAssertTrue(navigationController.popViewController(animated: false) === chat)
            settleNavigationLifecycle(navigationController, duration: 0.2)

            XCTAssertTrue(navigationController.topViewController === lastChats)
            XCTAssertFalse(lastChats.isNavigationTransitionActive)
            XCTAssertFalse(lastChats.accountNavButton.isRenderingFrozen)
            XCTAssertTrue(lastChats.navigationItem.leftBarButtonItem === lastChats.accountBarButton)
            XCTAssertNil(lastChats.navigationItem.searchController)
            XCTAssertFalse(
                staleTransitionWorkDidRun,
                "work captured by a cancelled pop must not replay on the next successful return"
            )
        }
    }

    func testCancelledInteractivePopReconcilesSelectionExitAndRestoresNativeBack() throws {
        try assertCancelledInteractivePopReconcilesModeExit(.selection)
    }

    func testCancelledInteractivePopReconcilesSearchExitAndRestoresNativeBack() throws {
        try assertCancelledInteractivePopReconcilesModeExit(.search)
    }

    func testSelectionNavbarRestorationDefersEveryItemUntilTransitionCompletes() {
        let viewController = ChatViewController()
        let navigationController = UINavigationController(rootViewController: viewController)
        viewController.loadViewIfNeeded()
        viewController.configureNavbar()

        viewController.navigationItem.leftBarButtonItem = viewController.deleteSelectionBarButton
        viewController.navigationItem.rightBarButtonItem = viewController.cancelSelectionBarButton
        viewController.navigationItem.titleView = viewController.selectionCountLabel
        viewController.navigationItem.setHidesBackButton(true, animated: false)
        viewController.isNavigationTransitionActive = true

        XCTAssertTrue(viewController.restoreNormalNavbarAfterSelectionIfNeeded())
        XCTAssertTrue(viewController.navigationItem.leftBarButtonItem === viewController.deleteSelectionBarButton)
        XCTAssertTrue(viewController.navigationItem.rightBarButtonItem === viewController.cancelSelectionBarButton)
        XCTAssertTrue(viewController.navigationItem.titleView === viewController.selectionCountLabel)
        XCTAssertTrue(viewController.navigationItem.hidesBackButton)

        viewController.isNavigationTransitionActive = false
        viewController.flushPendingNavigationTransitionWork()

        XCTAssertNil(viewController.navigationItem.leftBarButtonItem)
        XCTAssertFalse(viewController.navigationItem.rightBarButtonItem === viewController.cancelSelectionBarButton)
        XCTAssertTrue(viewController.navigationItem.titleView === viewController.titleButton)
        XCTAssertFalse(viewController.navigationItem.hidesBackButton)
        _ = navigationController
    }

    func testSearchNavbarRestorationDefersTitleAndAvatarUntilTransitionCompletes() {
        let rootViewController = UIViewController()
        let viewController = ChatViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.pushViewController(viewController, animated: false)
        viewController.loadViewIfNeeded()

        viewController.inSearchMode.accept(false)
        viewController.navigationItem.titleView = nil
        viewController.navigationItem.rightBarButtonItem = nil
        viewController.navigationItem.setHidesBackButton(true, animated: false)
        viewController.isNavigationTransitionActive = true

        XCTAssertTrue(viewController.restoreNormalNavbarAfterSearchIfNeeded())
        XCTAssertNil(viewController.navigationItem.titleView)
        XCTAssertNil(viewController.navigationItem.rightBarButtonItem)
        XCTAssertTrue(viewController.navigationItem.hidesBackButton)

        viewController.isNavigationTransitionActive = false
        viewController.flushPendingNavigationTransitionWork()

        XCTAssertTrue(viewController.navigationItem.titleView === viewController.titleButton)
        XCTAssertTrue(viewController.navigationItem.rightBarButtonItem === viewController.navigationAvatarItem)
        XCTAssertFalse(viewController.navigationItem.hidesBackButton)
        XCTAssertFalse(viewController.navigationItem.leftItemsSupplementBackButton)
    }

    func testSplitDetailNavigationControllerFactoryUsesPlainNativeNavigationControllerForChat() throws {
        withInterfaceType(.split) {
            let splitViewController = UISplitViewController(style: .tripleColumn)
            let container = embedInTraitContainer(splitViewController, horizontalSizeClass: .regular)
            container.loadViewIfNeeded()

            let chat = ChatViewController()
            chat.owner = "owner@example.com"
            chat.jid = "romeo@example.com"
            chat.conversationType = .regular

            let detailNavigationController = makeStackedDetailNavigationController(
                rootViewController: chat,
                splitViewController: splitViewController
            )
            XCTAssertTrue(type(of: detailNavigationController) == UINavigationController.self)
            XCTAssertFalse(detailNavigationController is NavBarController)
            XCTAssertTrue(detailNavigationController.topViewController === chat)
            chat.configureNavbar()
            assertNativeChatNavigationItemAppearance(chat)
            assertChatExtendsUnderNavigationBar(chat)
            assertSharedBackdropNavigationContainerBackground(detailNavigationController)
            XCTAssertFalse(
                detailNavigationController.navigationBar.standardAppearance ===
                    detailNavigationController.navigationBar.scrollEdgeAppearance
            )
            XCTAssertFalse(
                detailNavigationController.navigationBar.standardAppearance ===
                    detailNavigationController.navigationBar.compactAppearance
            )
        }
    }

    func testNativeSharedBackdropContainerTransparencyLeavesNavigationBarChromeUntouched() {
        let viewController = ChatViewController()
        let navigationController = UINavigationController(rootViewController: viewController)
        let standardAppearance = navigationController.navigationBar.standardAppearance
        let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
        let compactAppearance = navigationController.navigationBar.compactAppearance
        let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance
        let isTranslucent = navigationController.navigationBar.isTranslucent

        navigationController.applyTransparentSplitContainerBackground(backgroundMode: .sharedBackdrop)

        assertSharedBackdropNavigationContainerBackground(navigationController)
        XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
        XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
        XCTAssertEqual(navigationController.navigationBar.isTranslucent, isTranslucent)
    }

    func testSharedSplitBackdropChatBackgroundKeepsContentTransparentWithoutGlobalModeDependency() {
        withInterfaceType(.split) {
            let viewController = ChatViewController()
            viewController.backgroundPresentationMode = .sharedSplitBackdrop
            let navigationController = UINavigationController(rootViewController: viewController)
            let container = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)

            container.loadViewIfNeeded()
            viewController.configureBackground()

            XCTAssertEqual(viewController.view.backgroundColor, .clear)
            XCTAssertFalse(viewController.view.isOpaque)
            XCTAssertEqual(viewController.messagesCollectionView.backgroundColor, .clear)
        }
    }

    func testLegacyAutomaticChatBackgroundFillsViewBehindNavigationBar() {
        withInterfaceType(.tabs) {
            let viewController = ChatViewController()
            viewController.backgroundPresentationMode = .automatic
            let navigationController = UINavigationController(rootViewController: viewController)
            let container = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

            container.loadViewIfNeeded()
            viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            viewController.view.bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
            viewController.configureBackground()

            XCTAssertEqual(viewController.backgroundView.frame, viewController.view.bounds)
            XCTAssertEqual(viewController.backgroundImage.frame, viewController.backgroundView.bounds)
            XCTAssertEqual(viewController.gradientView.frame, viewController.view.bounds)
        }
    }

    func testChatViewControllerSourceDoesNotReferenceLegacyNavBarControllerChrome() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("xabber")
            .appendingPathComponent("controllers")
            .appendingPathComponent("chats")
            .appendingPathComponent("chat")
            .appendingPathComponent("ChatViewController.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("NavBarController"))
        XCTAssertFalse(source.contains("clearAdditionalPanel"))
        XCTAssertFalse(source.contains("hideAdditionalPanel"))
        XCTAssertFalse(source.contains("topToolbar"))
    }

    @objc
    private func dummyAction() {}

    private func assertNativeChatNavigationItemAppearance(
        _ viewController: ChatViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(viewController.navigationItem.standardAppearance, file: file, line: line)
        XCTAssertNil(viewController.navigationItem.scrollEdgeAppearance, file: file, line: line)
        XCTAssertNil(viewController.navigationItem.compactAppearance, file: file, line: line)
        if #available(iOS 15.0, *) {
            XCTAssertNil(viewController.navigationItem.compactScrollEdgeAppearance, file: file, line: line)
        }
    }

    private func assertSharedBackdropNavigationContainerBackground(
        _ navigationController: UINavigationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(navigationController.view.backgroundColor, .clear, file: file, line: line)
        XCTAssertFalse(navigationController.view.isOpaque, file: file, line: line)
    }

    private func assertChatExtendsUnderNavigationBar(
        _ viewController: ChatViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(viewController.extendedLayoutIncludesOpaqueBars, file: file, line: line)
        XCTAssertTrue(viewController.edgesForExtendedLayout.contains(.top), file: file, line: line)
        XCTAssertTrue(viewController.edgesForExtendedLayout.contains(.bottom), file: file, line: line)
    }

    private func descendantControls(in view: UIView) -> [UIControl] {
        let directControls = view.subviews.compactMap { $0 as? UIControl }
        return directControls + view.subviews.flatMap(descendantControls(in:))
    }

    private func visibleControl(
        in navigationBar: UINavigationBar,
        horizontalRegion: ClosedRange<CGFloat>
    ) -> UIControl? {
        descendantControls(in: navigationBar).first(where: { control in
            guard isEffectivelyVisible(control, in: navigationBar),
                  control.isUserInteractionEnabled else {
                return false
            }
            let frame = control.convert(control.bounds, to: navigationBar)
            return horizontalRegion.overlaps(frame.minX...frame.maxX)
        })
    }

    private func isEffectivelyVisible(_ view: UIView, in ancestor: UIView) -> Bool {
        guard view === ancestor || view.isDescendant(of: ancestor),
              view.window != nil,
              !view.isHidden,
              view.alpha > 0.01 else {
            return false
        }

        var currentAncestor = view.superview
        while let ancestorView = currentAncestor, ancestorView !== ancestor {
            guard !ancestorView.isHidden, ancestorView.alpha > 0.01 else {
                return false
            }
            currentAncestor = ancestorView.superview
        }

        let frame = view.convert(view.bounds, to: ancestor)
        return !frame.isEmpty && frame.intersects(ancestor.bounds)
    }

    private func visibleNavigationItemFrame(
        in navigationBar: UINavigationBar,
        horizontalRegion: ClosedRange<CGFloat>
    ) -> CGRect? {
        descendantViews(in: navigationBar)
            .compactMap { view -> CGRect? in
                guard isEffectivelyVisible(view, in: navigationBar) else {
                    return nil
                }
                let frame = view.convert(view.bounds, to: navigationBar)
                guard frame.width >= 44,
                      frame.height >= 44,
                      frame.width <= horizontalRegion.upperBound
                        - horizontalRegion.lowerBound,
                      frame.height <= navigationBar.bounds.height + 12,
                      frame.maxX > horizontalRegion.lowerBound,
                      frame.minX < horizontalRegion.upperBound else {
                    return nil
                }
                return frame
            }
            .min(by: { lhs, rhs in
                lhs.width * lhs.height < rhs.width * rhs.height
            })
    }

    private func descendantViews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendantViews(in:))
    }

    private func visibleTexts(
        in navigationBar: UINavigationBar,
        horizontalRegion: ClosedRange<CGFloat>
    ) -> [String] {
        descendantViews(in: navigationBar).compactMap { view in
            guard let label = view as? UILabel,
                  isEffectivelyVisible(label, in: navigationBar),
                  let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            let frame = label.convert(label.bounds, to: navigationBar)
            guard frame.maxX > horizontalRegion.lowerBound,
                  frame.minX < horizontalRegion.upperBound else {
                return nil
            }
            return text
        }
    }

    private func effectiveInteractiveFrame(
        for interactiveView: UIView,
        in navigationBar: UINavigationBar
    ) -> CGRect {
        var candidateView: UIView? = interactiveView
        var bestFrame = interactiveView.convert(interactiveView.bounds, to: navigationBar)

        while let view = candidateView,
              view !== navigationBar {
            let frame = view.convert(view.bounds, to: navigationBar)
            if isEffectivelyVisible(view, in: navigationBar),
               view.isUserInteractionEnabled,
               frame.width <= 88,
               frame.height <= navigationBar.bounds.height + 12,
               frame.width * frame.height > bestFrame.width * bestFrame.height {
                bestFrame = frame
            }
            candidateView = view.superview
        }

        return bestFrame
    }

    private func settleNavigationLifecycle(
        _ navigationController: UINavigationController,
        duration: TimeInterval = 0.1
    ) {
        navigationController.view.layoutIfNeeded()
        navigationController.navigationBar.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        navigationController.view.layoutIfNeeded()
        navigationController.navigationBar.layoutIfNeeded()
    }

    private enum NavigationModeUnderTest {
        case selection
        case search
    }

    private func assertCancelledInteractivePopReconcilesModeExit(
        _ mode: NavigationModeUnderTest
    ) throws {
        try withInterfaceType(.tabs) {
            let lastChats = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: lastChats)
            let window = TraitWindow(horizontalSizeClass: .compact)
            window.rootViewController = navigationController
            navigationController.loadViewIfNeeded()
            navigationController.view.frame = window.bounds
            window.makeKeyAndVisible()
            retainedTraitWindows.append(window)
            lastChats.loadViewIfNeeded()
            lastChats.configureBars(updateNavigationItems: true)
            navigationController.view.layoutIfNeeded()
            settleNavigationLifecycle(navigationController)

            let token = UUID()
            let target = LastChatsNavigationSingleFlightCoordinator.Target(
                owner: "owner@example.com",
                jid: "romeo@example.com",
                conversationType: .regular
            )
            _ = lastChats.chatNavigationSingleFlight.request(target: target, token: token)
            lastChats.beginOutgoingChatOpenNavigationDeferral(
                token: token,
                preparationTimeout: 60
            )
            XCTAssertTrue(lastChats.commitChatNavigationPush(token: token, target: target))
            XCTAssertTrue(lastChats.chatNavigationSingleFlight.markPresented(token: token, target: target))

            let chat = ChatViewController()
            chat.owner = target.owner
            chat.jid = target.jid
            chat.conversationType = target.conversationType
            navigationController.pushViewController(chat, animated: false)
            chat.loadViewIfNeeded()
            chat.configureNavbar()
            settleNavigationLifecycle(navigationController)

            switch mode {
            case .selection:
                chat.isInSelectionMode.accept(true)
                chat.invalidateNavigationAvatarItem()
                NavigationBarItemOwnership.apply(
                    to: chat.navigationItem,
                    left: .item(chat.deleteSelectionBarButton),
                    right: .item(chat.cancelSelectionBarButton),
                    animated: false
                )
                chat.navigationItem.titleView = chat.selectionCountLabel
                chat.navigationItem.setHidesBackButton(true, animated: false)
            case .search:
                chat.inSearchMode.accept(true)
                chat.invalidateNavigationAvatarItem()
                NavigationBarItemOwnership.apply(
                    to: chat.navigationItem,
                    left: NavigationBarItemOwnership.Assignment.none,
                    right: NavigationBarItemOwnership.Assignment.none,
                    animated: false
                )
                chat.navigationItem.titleView = nil
                chat.navigationItem.setHidesBackButton(true, animated: false)
            }

            chat.beginNavigationTransitionDeferralIfNeeded(
                forceActiveWithoutCoordinator: true
            )
            XCTAssertTrue(chat.isNavigationTransitionActive)

            switch mode {
            case .selection:
                chat.isInSelectionMode.accept(false)
                XCTAssertTrue(chat.restoreNormalNavbarAfterSelectionIfNeeded())
            case .search:
                chat.inSearchMode.accept(false)
                XCTAssertTrue(chat.restoreNormalNavbarAfterSearchIfNeeded())
            }
            var staleModeRestoreWorkDidRun = false
            XCTAssertTrue(
                chat.deferUntilNavigationTransitionCompletesIfNeeded {
                    staleModeRestoreWorkDidRun = true
                }
            )

            chat.completeNavigationTransitionDeferral(cancelled: true)
            settleNavigationLifecycle(navigationController)

            XCTAssertTrue(navigationController.topViewController === chat)
            XCTAssertNil(chat.navigationItem.leftBarButtonItem)
            XCTAssertFalse(chat.navigationItem.hidesBackButton)
            XCTAssertFalse(chat.navigationItem.leftItemsSupplementBackButton)
            XCTAssertTrue(chat.navigationItem.titleView === chat.titleButton)
            XCTAssertTrue(chat.navigationItem.rightBarButtonItem === chat.navigationAvatarItem)
            XCTAssertFalse(chat.needsNavigationChromeReconciliationAfterCancelledTransition)
            XCTAssertFalse(staleModeRestoreWorkDidRun)

            let backFrame = try XCTUnwrap(
                visibleNavigationItemFrame(
                    in: navigationController.navigationBar,
                    horizontalRegion: 0...88
                )
            )
            XCTAssertTrue(
                navigationController.navigationBar.backItem
                    === lastChats.navigationItem
            )
            XCTAssertGreaterThanOrEqual(backFrame.width, 44)
            XCTAssertGreaterThanOrEqual(backFrame.height, 44)
        }
    }

    private func withInterfaceType(
        _ interfaceType: CommonConfigManager.InterfaceType,
        block: () throws -> Void
    ) rethrows {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        CommonConfigManager.shared.config.interface_type = interfaceType.rawValue
        try block()
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
        return parent
    }

    private func makeBarButtonItem(identifier: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "circle"),
            style: .plain,
            target: nil,
            action: nil
        )
        item.accessibilityIdentifier = identifier
        return item
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            UIColor.systemRed.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
}
