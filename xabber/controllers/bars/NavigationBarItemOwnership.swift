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
}
