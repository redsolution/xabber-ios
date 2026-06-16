//
//  NavigationBarItemOwnership.swift
//  xabber
//
//  Created by Codex on 01.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

enum NavigationBarItemOwnership {
    enum Side {
        case left
        case right
    }

    enum Assignment {
        case none
        case item(UIBarButtonItem)
        case items([UIBarButtonItem])
    }

    private static func currentItems(
        on navigationItem: UINavigationItem,
        side: Side
    ) -> [UIBarButtonItem] {
        switch side {
        case .left:
            if let items = navigationItem.leftBarButtonItems {
                return items
            }
            return navigationItem.leftBarButtonItem.map { [$0] } ?? []
        case .right:
            if let items = navigationItem.rightBarButtonItems {
                return items
            }
            return navigationItem.rightBarButtonItem.map { [$0] } ?? []
        }
    }

    private static func items(for assignment: Assignment) -> [UIBarButtonItem] {
        switch assignment {
        case .none:
            return []
        case .item(let item):
            return [item]
        case .items(let items):
            return items
        }
    }

    private static func itemsMatch(
        current: [UIBarButtonItem],
        desired: [UIBarButtonItem]
    ) -> Bool {
        guard current.count == desired.count else {
            return false
        }
        return zip(current, desired).allSatisfy { $0 === $1 }
    }

    static func clear(
        _ navigationItem: UINavigationItem,
        sides: [Side] = [.left, .right],
        animated: Bool = false
    ) {
        sides.forEach { side in
            switch side {
            case .left:
                navigationItem.setLeftBarButtonItems(nil, animated: animated)
                navigationItem.setLeftBarButton(nil, animated: animated)
                navigationItem.leftBarButtonItems = nil
                navigationItem.leftBarButtonItem = nil
            case .right:
                navigationItem.setRightBarButtonItems(nil, animated: animated)
                navigationItem.setRightBarButton(nil, animated: animated)
                navigationItem.rightBarButtonItems = nil
                navigationItem.rightBarButtonItem = nil
            }
        }
    }

    static func clearIfChanged(
        _ navigationItem: UINavigationItem,
        sides: [Side] = [.left, .right],
        animated: Bool = false
    ) {
        sides.forEach { side in
            guard !currentItems(on: navigationItem, side: side).isEmpty else {
                return
            }
            clear(navigationItem, sides: [side], animated: animated)
        }
    }

    static func set(
        _ assignment: Assignment,
        on navigationItem: UINavigationItem,
        side: Side,
        animated: Bool
    ) {
        clear(navigationItem, sides: [side], animated: false)

        switch (side, assignment) {
        case (.left, .none):
            break
        case (.left, .item(let item)):
            navigationItem.setLeftBarButton(item, animated: animated)
        case (.left, .items(let items)):
            navigationItem.setLeftBarButtonItems(items, animated: animated)
        case (.right, .none):
            break
        case (.right, .item(let item)):
            navigationItem.setRightBarButton(item, animated: animated)
        case (.right, .items(let items)):
            navigationItem.setRightBarButtonItems(items, animated: animated)
        }
    }

    static func setIfChanged(
        _ assignment: Assignment,
        on navigationItem: UINavigationItem,
        side: Side,
        animated: Bool
    ) {
        let desiredItems = items(for: assignment)
        guard !itemsMatch(current: currentItems(on: navigationItem, side: side), desired: desiredItems) else {
            return
        }
        set(assignment, on: navigationItem, side: side, animated: animated)
    }

    static func apply(
        to navigationItem: UINavigationItem,
        left: Assignment? = nil,
        right: Assignment? = nil,
        animated: Bool
    ) {
        clear(navigationItem, animated: false)

        if let left {
            switch left {
            case .none:
                break
            case .item(let item):
                navigationItem.setLeftBarButton(item, animated: animated)
            case .items(let items):
                navigationItem.setLeftBarButtonItems(items, animated: animated)
            }
        }

        if let right {
            switch right {
            case .none:
                break
            case .item(let item):
                navigationItem.setRightBarButton(item, animated: animated)
            case .items(let items):
                navigationItem.setRightBarButtonItems(items, animated: animated)
            }
        }
    }

    static func applyIfChanged(
        to navigationItem: UINavigationItem,
        left: Assignment? = nil,
        right: Assignment? = nil,
        animated: Bool
    ) {
        if let left {
            setIfChanged(left, on: navigationItem, side: .left, animated: animated)
        }
        if let right {
            setIfChanged(right, on: navigationItem, side: .right, animated: animated)
        }
    }
}

enum NavigationLargeTitlePolicy {
    private static var prefersLargeTitles: Bool {
        CommonConfigManager.shared.config.use_large_title
    }

    static func apply(to viewController: UIViewController) {
        viewController.navigationItem.largeTitleDisplayMode = prefersLargeTitles ? .automatic : .never
        viewController.navigationController?.navigationBar.prefersLargeTitles = prefersLargeTitles
    }

    static func apply(
        to navigationController: UINavigationController,
        rootViewController: UIViewController? = nil
    ) {
        navigationController.navigationBar.prefersLargeTitles = prefersLargeTitles
        (rootViewController ?? navigationController.viewControllers.first)?.navigationItem.largeTitleDisplayMode =
            prefersLargeTitles ? .automatic : .never
    }
}
