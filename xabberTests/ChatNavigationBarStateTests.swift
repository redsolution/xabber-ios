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
            left: .none,
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
            left: .none,
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

    func testChatAvatarItemFactoryProducesStockBarButtonItem() {
        let image = makeImage()
        let avatarImage = ChatNavigationAvatarItemFactory.avatarImage(from: image)
        let item = ChatNavigationAvatarItemFactory.makeItem(
            image: avatarImage,
            target: self,
            action: #selector(dummyAction)
        )

        XCTAssertNil(item.customView)
        XCTAssertNotNil(item.image)
        XCTAssertEqual(item.image?.renderingMode, .alwaysOriginal)
        XCTAssertEqual(item.accessibilityIdentifier, ChatNavigationAvatarItemFactory.accessibilityIdentifier)
    }

    @objc
    private func dummyAction() {}

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
