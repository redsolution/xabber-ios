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

enum NativeSectionNavigationBarPolicy {
    static func resetNavigationItemAppearance(_ navigationItem: UINavigationItem) {
        if navigationItem.standardAppearance != nil {
            navigationItem.standardAppearance = nil
        }
        if navigationItem.scrollEdgeAppearance != nil {
            navigationItem.scrollEdgeAppearance = nil
        }
        if navigationItem.compactAppearance != nil {
            navigationItem.compactAppearance = nil
        }
        if #available(iOS 15.0, *) {
            if navigationItem.compactScrollEdgeAppearance != nil {
                navigationItem.compactScrollEdgeAppearance = nil
            }
        }
    }

    static func apply(to viewController: UIViewController) {
        resetNavigationItemAppearance(viewController.navigationItem)
    }
}

/// Local title chrome shares the material used by the composer and bottom bars.
enum NavigationTitlePillSurface {
    static let accessibilityIdentifier = "navigation_title_pill_surface"

    static func install(on view: UIView, role: XabberGlassStyle.SurfaceRole) {
        guard !view.subviews.contains(where: { $0.accessibilityIdentifier == accessibilityIdentifier }) else { return }
        let surface = UIVisualEffectView()
        XabberGlassStyle.applySurface(to: surface, role: role, cornerStyle: .capsule, interactive: true)
        surface.isUserInteractionEnabled = false
        surface.accessibilityIdentifier = accessibilityIdentifier
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(surface, at: 0)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

final class NavigationTitlePillView: UIView {
    private let label = UILabel()
    var preferredPillWidth: CGFloat = 0 {
        didSet {
            if abs(oldValue - preferredPillWidth) > 0.5 { invalidateIntrinsicContentSize() }
        }
    }

    var text: String? {
        get { label.text }
        set {
            label.text = newValue
            accessibilityLabel = newValue
            invalidateIntrinsicContentSize()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        NavigationTitlePillSurface.install(on: self, role: .bar)
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "recent_chats_title_pill"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: preferredPillWidth > 0 ? preferredPillWidth : label.intrinsicContentSize.width + 32, height: max(NativeGlassBarStyle.minimumHeight, label.font.lineHeight + 16))
    }
}

/// Reserve the outer navigation controls while balancing the top and bottom pills.
enum NavigationTitlePillSizing {
    static func width(columnWidth: CGFloat, bottomPillWidth: CGFloat) -> CGFloat {
        let available = max(0, columnWidth - 112)
        return bottomPillWidth > 0 ? min(bottomPillWidth, available) : available
    }
}
