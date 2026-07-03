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
        XCTAssertEqual(ChatNavigationAvatarItemFactory.imageSize, 42, accuracy: 0.001)
        XCTAssertEqual(itemImage.size.width, 42, accuracy: 0.001)
        XCTAssertEqual(itemImage.size.height, 42, accuracy: 0.001)
        XCTAssertEqual(itemImage.renderingMode, .alwaysOriginal)
        XCTAssertEqual(item.accessibilityIdentifier, ChatNavigationAvatarItemFactory.accessibilityIdentifier)
    }

    func testSavedMessagesAvatarFactoryUsesLargeNavbarAvatarImage() throws {
        let image = try XCTUnwrap(ChatNavigationAvatarItemFactory.savedMessagesImage(
            backgroundColor: .systemBlue,
            iconTintColor: .white
        ))

        XCTAssertEqual(image.size.width, 42, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 42, accuracy: 0.001)
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
