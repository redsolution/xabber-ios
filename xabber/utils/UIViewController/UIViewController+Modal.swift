//
//  UIViewController+Modal.swift
//  xabber
//
//  Created by Игорь Болдин on 27.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack

enum StackedNavigationRoute: Equatable {
    case currentNavigationPush
    case splitDetailReplacement

    var usesNavigationControllerWrapper: Bool {
        self == .splitDetailReplacement
    }

    var requiresDeferredPrimaryHide: Bool {
        self == .splitDetailReplacement
    }

    var targetColumn: UISplitViewController.Column? {
        switch self {
        case .currentNavigationPush:
            return nil
        case .splitDetailReplacement:
            return .secondary
        }
    }
}

struct StackedNavigationRouteContext: Equatable {
    let interfaceType: CommonConfigManager.InterfaceType
    let isPhone: Bool
    let hasSplitViewController: Bool
    let isSplitCollapsed: Bool
    let splitHorizontalSizeClass: UIUserInterfaceSizeClass
    let windowHorizontalSizeClass: UIUserInterfaceSizeClass
    let presenterHorizontalSizeClass: UIUserInterfaceSizeClass

    init(
        interfaceType: CommonConfigManager.InterfaceType,
        isPhone: Bool,
        hasSplitViewController: Bool,
        isSplitCollapsed: Bool,
        splitHorizontalSizeClass: UIUserInterfaceSizeClass,
        windowHorizontalSizeClass: UIUserInterfaceSizeClass,
        presenterHorizontalSizeClass: UIUserInterfaceSizeClass
    ) {
        self.interfaceType = interfaceType
        self.isPhone = isPhone
        self.hasSplitViewController = hasSplitViewController
        self.isSplitCollapsed = isSplitCollapsed
        self.splitHorizontalSizeClass = splitHorizontalSizeClass
        self.windowHorizontalSizeClass = windowHorizontalSizeClass
        self.presenterHorizontalSizeClass = presenterHorizontalSizeClass
    }
}

enum StackedNavigationRoutePolicy {
    static func route(for context: StackedNavigationRouteContext) -> StackedNavigationRoute {
        switch context.interfaceType {
        case .tabs:
            return .currentNavigationPush
        case .split:
            if context.isPhone || !context.hasSplitViewController || context.isSplitCollapsed {
                return .currentNavigationPush
            }
            if context.splitHorizontalSizeClass == .compact || context.windowHorizontalSizeClass == .compact {
                return .currentNavigationPush
            }
            return .splitDetailReplacement
        }
    }
}

enum ChatBackgroundPresentationMode: Equatable {
    case automatic
    case sharedSplitBackdrop
    case localChatBackdrop
}

struct ChatBackgroundPresentationContext: Equatable {
    let route: StackedNavigationRoute
    let interfaceType: CommonConfigManager.InterfaceType
    let continuousSplitBackgroundMode: ContinuousSplitBackgroundMode

    init(
        route: StackedNavigationRoute,
        interfaceType: CommonConfigManager.InterfaceType,
        continuousSplitBackgroundMode: ContinuousSplitBackgroundMode
    ) {
        self.route = route
        self.interfaceType = interfaceType
        self.continuousSplitBackgroundMode = continuousSplitBackgroundMode
    }

    init(
        route: StackedNavigationRoute,
        interfaceType: CommonConfigManager.InterfaceType,
        isContinuousSplitBackgroundActive: Bool
    ) {
        self.init(
            route: route,
            interfaceType: interfaceType,
            continuousSplitBackgroundMode: isContinuousSplitBackgroundActive ? .sharedBackdrop : .inactive
        )
    }
}

enum ChatBackgroundPresentationPolicy {
    static func mode(for context: ChatBackgroundPresentationContext) -> ChatBackgroundPresentationMode {
        guard context.interfaceType == .split else {
            return .automatic
        }

        switch context.continuousSplitBackgroundMode {
        case .sharedBackdrop:
            switch context.route {
            case .currentNavigationPush:
                return .localChatBackdrop
            case .splitDetailReplacement:
                return .sharedSplitBackdrop
            }
        case .stockCompact:
            return context.route == .currentNavigationPush ? .localChatBackdrop : .automatic
        case .inactive, .deferred:
            return .automatic
        }
    }

    static func destinationMode(
        for destination: UIViewController,
        context: ChatBackgroundPresentationContext
    ) -> ChatBackgroundPresentationMode? {
        guard destination is ChatViewController else {
            return nil
        }
        return mode(for: context)
    }
}

protocol StackedNavigationPresentationPreparing: AnyObject {
    func prepareForStackedNavigationPresentation(targetBounds: CGRect?)
}

@discardableResult
func showModal(_ vc: UIViewController, parent parentVc: UIViewController? = nil, replaceParent: Bool = true) -> Bool {
    var parent: UIViewController? = parentVc
//    if (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc != nil {
//        parent = (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc
//    } else {
    switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            parent = AppRootCoordinator.active?.tabController
        case .split:
            parent = AppRootCoordinator.active?.splitController
    }
    parent = parent ?? SceneWindowProvider.presentationRootViewController
    guard let parent = parent else {
        return false
    }
    
    if replaceParent {
        AppRootCoordinator.active?.currentPresentedVc = vc
        (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc = vc
    }
//    }
    let nvc = UINavigationController(rootViewController: vc)
    nvc.modalPresentationStyle = .formSheet
    nvc.modalTransitionStyle = .coverVertical
    if UIDevice.current.userInterfaceIdiom == .pad {
        if let popoverController = nvc.popoverPresentationController {
            popoverController.sourceView = parent.view
            popoverController.sourceRect = CGRect(x: parent.view.bounds.midX, y: parent.view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = [.any]
        }
    }
    
    if let adaptiveDelegate = parentVc as? UIAdaptivePresentationControllerDelegate {
        nvc.presentationController?.delegate = adaptiveDelegate
    }
    
    parent.definesPresentationContext = true
    if let presentedViewController = parent.presentedViewController {
        presentedViewController.present(nvc, animated: true)
    } else {
        parent.present(nvc, animated: true, completion: nil)
    }
    return true
}

private func splitController(for presenter: UIViewController) -> UISplitViewController? {
    (presenter as? UISplitViewController) ?? presenter.splitViewController ?? AppRootCoordinator.active?.splitController
}

func stackedNavigationRoute(for presenter: UIViewController) -> StackedNavigationRoute {
    let splitViewController = splitController(for: presenter)
    let context = StackedNavigationRouteContext(
        interfaceType: CommonConfigManager.shared.interfaceType,
        isPhone: UIDevice.current.userInterfaceIdiom == .phone,
        hasSplitViewController: splitViewController != nil,
        isSplitCollapsed: splitViewController?.isCollapsed ?? true,
        splitHorizontalSizeClass: splitViewController?.traitCollection.horizontalSizeClass ?? .unspecified,
        windowHorizontalSizeClass: splitViewController?.view.window?.traitCollection.horizontalSizeClass ?? .unspecified,
        presenterHorizontalSizeClass: presenter.traitCollection.horizontalSizeClass
    )
    return StackedNavigationRoutePolicy.route(for: context)
}

private func currentNavigationController(for presenter: UIViewController) -> UINavigationController? {
    if let navigationController = presenter as? UINavigationController {
        return navigationController
    }
    if let navigationController = presenter.navigationController {
        return navigationController
    }
    guard let splitController = splitController(for: presenter) else {
        return nil
    }
    let navigationControllers = splitController.viewControllers.compactMap { $0 as? UINavigationController }
    return navigationControllers.first { $0.topViewController is LastChatsViewController }
        ?? navigationControllers.last
}

private func prepareStackedDestination(_ vc: UIViewController, targetBounds: CGRect?) {
    let start = CFAbsoluteTimeGetCurrent()
    (vc as? StackedNavigationPresentationPreparing)?
        .prepareForStackedNavigationPresentation(targetBounds: targetBounds)
#if DEBUG
    DDLogDebug("showStacked.prepareStackedDestination for \(type(of: vc)) took \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start))s")
#endif
}

private func configureStackedChatBackgroundPresentation(
    _ vc: UIViewController,
    route: StackedNavigationRoute,
    presenter: UIViewController
) {
    guard let chatViewController = vc as? ChatViewController,
          let mode = ChatBackgroundPresentationPolicy.destinationMode(
            for: vc,
            context: ChatBackgroundPresentationContext(
                route: route,
                interfaceType: CommonConfigManager.shared.interfaceType,
                continuousSplitBackgroundMode: ContinuousSplitBackgroundExperiment.mode(for: presenter)
            )
          ) else {
        return
    }

    chatViewController.backgroundPresentationMode = mode
}

private func splitSecondaryTargetBounds(
    splitViewController: UISplitViewController?,
    presenter: UIViewController
) -> CGRect? {
    if let secondary = splitViewController?.viewController(for: .secondary),
       !secondary.view.bounds.isEmpty {
        return secondary.view.bounds
    }
    if let splitViewController,
       !splitViewController.view.bounds.isEmpty {
        return splitViewController.view.bounds
    }
    return presenter.view.bounds.isEmpty ? nil : presenter.view.bounds
}

private func hidePrimaryAfterDetailTransition(_ splitViewController: UISplitViewController?) {
    guard let splitViewController else {
        return
    }
    let hidePrimary: () -> Void = { [weak splitViewController] in
        splitViewController?.hide(.primary)
    }

    if let coordinator = splitViewController.transitionCoordinator {
        coordinator.animate(alongsideTransition: nil) { context in
            guard !context.isCancelled else { return }
            hidePrimary()
        }
        return
    }

    DispatchQueue.main.async(execute: hidePrimary)
}

public func showStacked(_ vc: UIViewController, in presenter: UIViewController) {
    let start = CFAbsoluteTimeGetCurrent()
    let splitViewController = splitController(for: presenter)
    let route = stackedNavigationRoute(for: presenter)

    switch route {
    case .currentNavigationPush:
        let navigationController = currentNavigationController(for: presenter)
        let targetBounds = navigationController?.view.bounds ?? presenter.view.bounds
        let backgroundMode = ContinuousSplitBackgroundExperiment.mode(for: presenter)
        configureStackedChatBackgroundPresentation(vc, route: route, presenter: presenter)
        if backgroundMode != .stockCompact {
            prepareStackedDestination(vc, targetBounds: targetBounds)
        }
//            presenter.splitViewController?.showDetailViewController(NavBarController(rootViewController: vc), sender: presenter)
        if let navigationController {
            navigationController.pushViewController(vc, animated: true)
        } else {
            presenter.show(vc, sender: presenter)
        }
    case .splitDetailReplacement:
        guard let splitViewController else {
            let navigationController = currentNavigationController(for: presenter)
            configureStackedChatBackgroundPresentation(vc, route: .currentNavigationPush, presenter: presenter)
            prepareStackedDestination(vc, targetBounds: navigationController?.view.bounds ?? presenter.view.bounds)
            navigationController?.pushViewController(vc, animated: true)
            return
        }
//            presenter.splitViewController?.showDetailViewController(vc, sender: presenter)
        let nvc = UINavigationController(rootViewController: vc)
        nvc.applyTransparentSplitAppearance(
            backgroundMode: ContinuousSplitBackgroundExperiment.mode(for: splitViewController)
        )
//            nvc.setNavigationBarHidden(false, animated: false)
        configureStackedChatBackgroundPresentation(vc, route: route, presenter: presenter)
        prepareStackedDestination(
            vc,
            targetBounds: splitSecondaryTargetBounds(
                splitViewController: splitViewController,
                presenter: presenter
            )
        )
        splitViewController.setViewController(nvc, for: .secondary)
        splitViewController.show(.secondary)
        hidePrimaryAfterDetailTransition(splitViewController)
    }
#if DEBUG
    DDLogDebug("showStacked route:\(route) for \(type(of: vc)) took \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start))s")
#endif
}

public func showDetail(_ vc: UIViewController, currentVc: UIViewController?) {
    let presenter = currentVc
        ?? AppRootCoordinator.active?.splitController
        ?? SceneWindowProvider.presentationRootViewController
    guard let presenter else {
        return
    }

    let present: () -> Void = {
        showStacked(vc, in: presenter)
    }
    if let currentVc {
        currentVc.dismiss(animated: true, completion: present)
    } else {
        present()
    }
}
