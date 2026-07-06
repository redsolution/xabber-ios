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
import ObjectiveC

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

enum NavigationExitAction: Equatable {
    case dismissModal
    case popNavigationStack
    case revealSplitList
    case none
}

struct NavigationExitPolicyContext: Equatable {
    let route: StackedNavigationRoute
    let isInsidePresentedModalNavigation: Bool
    let canPopNavigation: Bool
    let hasSplitViewController: Bool
    let isSplitCollapsed: Bool

    init(
        route: StackedNavigationRoute,
        isInsidePresentedModalNavigation: Bool,
        canPopNavigation: Bool,
        hasSplitViewController: Bool,
        isSplitCollapsed: Bool
    ) {
        self.route = route
        self.isInsidePresentedModalNavigation = isInsidePresentedModalNavigation
        self.canPopNavigation = canPopNavigation
        self.hasSplitViewController = hasSplitViewController
        self.isSplitCollapsed = isSplitCollapsed
    }

    init(destination: UIViewController, route: StackedNavigationRoute) {
        let navigationController = destination.navigationController
        let splitViewController = destination.splitViewController ?? navigationController?.splitViewController
        let destinationIndex = navigationController?.viewControllers.firstIndex { $0 === destination }

        self.init(
            route: route,
            isInsidePresentedModalNavigation: navigationController?.presentingViewController != nil ||
                destination.presentingViewController != nil,
            canPopNavigation: destinationIndex.map { $0 > 0 } ?? false,
            hasSplitViewController: splitViewController != nil,
            isSplitCollapsed: splitViewController?.isCollapsed ?? true
        )
    }
}

enum NavigationExitPolicy {
    static func action(for context: NavigationExitPolicyContext) -> NavigationExitAction {
        if context.isInsidePresentedModalNavigation {
            return .dismissModal
        }

        switch context.route {
        case .splitDetailReplacement:
            if context.hasSplitViewController {
                return .revealSplitList
            }
        case .currentNavigationPush:
            if context.canPopNavigation {
                return .popNavigationStack
            }
        }

        if context.canPopNavigation {
            return .popNavigationStack
        }
        if context.hasSplitViewController && !context.isSplitCollapsed {
            return .revealSplitList
        }
        return .none
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

struct ModalPresentationCurrentControllerAccess {
    let get: () -> UIViewController?
    let set: (UIViewController?) -> Void

    static var application: ModalPresentationCurrentControllerAccess {
        ModalPresentationCurrentControllerAccess(
            get: {
                AppRootCoordinator.active?.currentPresentedVc
                    ?? (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc
            },
            set: { viewController in
                if let coordinator = AppRootCoordinator.active {
                    coordinator.currentPresentedVc = viewController
                }
                (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc = viewController
            }
        )
    }
}

final class ModalPresentationContainmentController: NSObject, UIAdaptivePresentationControllerDelegate {
    private weak var presentingView: UIView?
    private weak var navigationController: UINavigationController?
    private weak var rootViewController: UIViewController?
    private weak var presentedContentViewController: UIViewController?
    private weak var forwardedDelegate: UIAdaptivePresentationControllerDelegate?
    private let currentControllerAccess: ModalPresentationCurrentControllerAccess

    private var previousPresentingAccessibilityElementsHidden = false
    private var previousNavigationAccessibilityViewIsModal = false
    private var previousRootAccessibilityViewIsModal = false
    private var isActive = false
    private var didRestore = false

    init(
        presentingView: UIView,
        navigationController: UINavigationController,
        rootViewController: UIViewController,
        presentedContentViewController: UIViewController,
        forwardedDelegate: UIAdaptivePresentationControllerDelegate?,
        currentControllerAccess: ModalPresentationCurrentControllerAccess = .application
    ) {
        self.presentingView = presentingView
        self.navigationController = navigationController
        self.rootViewController = rootViewController
        self.presentedContentViewController = presentedContentViewController
        self.forwardedDelegate = forwardedDelegate
        self.currentControllerAccess = currentControllerAccess
        super.init()
    }

    deinit {
        restoreIfNeeded()
    }

    func activate() {
        guard !isActive else {
            return
        }
        isActive = true

        if let presentingView {
            previousPresentingAccessibilityElementsHidden = presentingView.accessibilityElementsHidden
            presentingView.accessibilityElementsHidden = true
        }

        if let navigationView = navigationController?.view {
            previousNavigationAccessibilityViewIsModal = navigationView.accessibilityViewIsModal
            navigationView.accessibilityViewIsModal = true
        }

        if let rootView = rootViewController?.view {
            previousRootAccessibilityViewIsModal = rootView.accessibilityViewIsModal
            rootView.accessibilityViewIsModal = true
        }
    }

    func presentationDidComplete() {
        let focusTarget = rootViewController?.viewIfLoaded ?? navigationController?.viewIfLoaded
        UIAccessibility.post(notification: .screenChanged, argument: focusTarget)
    }

    func restoreIfNeeded() {
        guard !didRestore else {
            return
        }
        didRestore = true

        presentingView?.accessibilityElementsHidden = previousPresentingAccessibilityElementsHidden
        navigationController?.viewIfLoaded?.accessibilityViewIsModal = previousNavigationAccessibilityViewIsModal
        rootViewController?.viewIfLoaded?.accessibilityViewIsModal = previousRootAccessibilityViewIsModal

        if let presentedContentViewController,
           currentControllerAccess.get() === presentedContentViewController {
            currentControllerAccess.set(nil)
        }
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        forwardedDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        forwardedDelegate?.presentationControllerWillDismiss?(presentationController)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        restoreIfNeeded()
        forwardedDelegate?.presentationControllerDidDismiss?(presentationController)
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        forwardedDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
    }

    static func install(
        on navigationController: UINavigationController,
        rootViewController: UIViewController,
        presentingViewController: UIViewController,
        presentedContentViewController: UIViewController,
        forwardedDelegate: UIAdaptivePresentationControllerDelegate?,
        currentControllerAccess: ModalPresentationCurrentControllerAccess = .application
    ) -> ModalPresentationContainmentController {
        let controller = ModalPresentationContainmentController(
            presentingView: presentingViewController.view,
            navigationController: navigationController,
            rootViewController: rootViewController,
            presentedContentViewController: presentedContentViewController,
            forwardedDelegate: forwardedDelegate,
            currentControllerAccess: currentControllerAccess
        )
        controller.activate()
        navigationController.presentationController?.delegate = controller
        objc_setAssociatedObject(
            navigationController,
            &modalPresentationContainmentControllerKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return controller
    }
}

private var modalPresentationContainmentControllerKey: UInt8 = 0

@discardableResult
func presentContainedNavigationModal(
    _ navigationController: UINavigationController,
    rootViewController: UIViewController,
    presentedContentViewController: UIViewController,
    from presenter: UIViewController,
    replaceCurrentPresented: Bool = true,
    forwardedDelegate: UIAdaptivePresentationControllerDelegate? = nil,
    currentControllerAccess: ModalPresentationCurrentControllerAccess = .application,
    completion: (() -> Void)? = nil
) -> Bool {
    if replaceCurrentPresented {
        currentControllerAccess.set(presentedContentViewController)
    }

    navigationController.modalPresentationStyle = .formSheet
    navigationController.modalTransitionStyle = .coverVertical
    if UIDevice.current.userInterfaceIdiom == .pad {
        if let popoverController = navigationController.popoverPresentationController {
            popoverController.sourceView = presenter.view
            popoverController.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = [.any]
        }
    }

    presenter.definesPresentationContext = true
    let presentingViewController = presenter.presentedViewController ?? presenter
    let containmentController = ModalPresentationContainmentController.install(
        on: navigationController,
        rootViewController: rootViewController,
        presentingViewController: presentingViewController,
        presentedContentViewController: presentedContentViewController,
        forwardedDelegate: forwardedDelegate,
        currentControllerAccess: currentControllerAccess
    )
    if let presentedViewController = presenter.presentedViewController {
        presentedViewController.present(navigationController, animated: true) {
            containmentController.presentationDidComplete()
            completion?()
        }
    } else {
        presenter.present(navigationController, animated: true) {
            containmentController.presentationDidComplete()
            completion?()
        }
    }
    return true
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

//    }
    let nvc = UINavigationController(rootViewController: vc)
    return presentContainedNavigationModal(
        nvc,
        rootViewController: vc,
        presentedContentViewController: vc,
        from: parent,
        replaceCurrentPresented: replaceParent,
        forwardedDelegate: parentVc as? UIAdaptivePresentationControllerDelegate
    )
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

func makeStackedDetailNavigationController(
    rootViewController: UIViewController,
    splitViewController: UISplitViewController
) -> UINavigationController {
    let navigationController = UINavigationController(rootViewController: rootViewController)
    let backgroundMode = ContinuousSplitBackgroundExperiment.mode(for: splitViewController)
    if rootViewController is ChatViewController {
        navigationController.applyTransparentSplitContainerBackground(backgroundMode: backgroundMode)
    } else {
        navigationController.applyTransparentSplitAppearance(
            backgroundMode: backgroundMode
        )
    }
    return navigationController
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
        let nvc = makeStackedDetailNavigationController(
            rootViewController: vc,
            splitViewController: splitViewController
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
