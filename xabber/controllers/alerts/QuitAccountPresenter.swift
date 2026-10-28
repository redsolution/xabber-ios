//
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
//
//

import Foundation
import UIKit

enum QuitAccountCleanupRoute: Equatable {
    case onboarding
    case root
}

struct QuitAccountCleanupFlowState {
    private(set) var isInProgress: Bool = false

    var canStartQuit: Bool {
        !isInProgress
    }

    var canPerformSecurityAction: Bool {
        !isInProgress
    }

    @discardableResult
    mutating func beginCleanup() -> Bool {
        guard !isInProgress else {
            return false
        }
        isInProgress = true
        return true
    }

    mutating func complete(hasRemainingAccounts: Bool) -> QuitAccountCleanupRoute {
        isInProgress = false
        return hasRemainingAccounts ? .root : .onboarding
    }

    mutating func failCleanup() {
        isInProgress = false
    }
}

struct QuitAccountPresenter {
    let jid: String
    
    static func confirmationMessage(jid: String) -> String {
        [
            "You are quitting".localizeString(id: "account_quitting", arguments: []),
            jid,
            "account. Account data will be deleted from this device. Your data on server will not be affected.".localizeString(id: "account_data_deletion", arguments: [])
        ].joined(separator: " ")
    }
    
    typealias CleanupHandler = (_ jid: String, _ completion: @escaping (AccountDeletionCleanupResult) -> Void) -> Void

    func presentAndQuit(in view: UIViewController, beforeCleanup: @escaping () -> Void) {
        present(in: view, animated: true) {
            self.beginCleanup(in: view, beforeCleanup: beforeCleanup)
        }
    }

    @discardableResult
    func beginCleanup(
        in view: UIViewController,
        beforeCleanup: () -> Void = {},
        deletionHandler: @escaping CleanupHandler = { jid, completion in
            AccountManager.shared.deleteAccountAsync(by: jid, completion: completion)
        }
    ) -> Bool {
        guard view.view.isUserInteractionEnabled else { return false }
        let window = view.view.window
        let navigation = view.navigationController
        let wasModalInPresentation = (navigation ?? view).isModalInPresentation
        let wasPopGestureEnabled = navigation?.interactivePopGestureRecognizer?.isEnabled
        let wasBackButtonHidden = view.navigationItem.hidesBackButton
        let wasLeftButtonEnabled = view.navigationItem.leftBarButtonItem?.isEnabled
        let wasRightButtonEnabled = view.navigationItem.rightBarButtonItem?.isEnabled
        view.view.isUserInteractionEnabled = false
        (navigation ?? view).isModalInPresentation = true
        navigation?.interactivePopGestureRecognizer?.isEnabled = false
        view.navigationItem.hidesBackButton = true
        view.navigationItem.leftBarButtonItem?.isEnabled = false
        view.navigationItem.rightBarButtonItem?.isEnabled = false
        let progress = Self.makeProgressView(in: view.view)
        beforeCleanup()
        // Retain the presenter until cleanup and navigation have both completed.
        DispatchQueue.main.async {
            deletionHandler(jid) { result in
                progress.removeFromSuperview()
                view.view.isUserInteractionEnabled = true
                (navigation ?? view).isModalInPresentation = wasModalInPresentation
                if let wasPopGestureEnabled {
                    navigation?.interactivePopGestureRecognizer?.isEnabled = wasPopGestureEnabled
                }
                view.navigationItem.hidesBackButton = wasBackButtonHidden
                if let wasLeftButtonEnabled {
                    view.navigationItem.leftBarButtonItem?.isEnabled = wasLeftButtonEnabled
                }
                if let wasRightButtonEnabled {
                    view.navigationItem.rightBarButtonItem?.isEnabled = wasRightButtonEnabled
                }
                guard result.succeeded else {
                    Self.presentCleanupFailure(in: view)
                    return
                }
                let route: QuitAccountCleanupRoute = AccountManager.shared.emptyAccountsList() ? .onboarding : .root
                Self.routeAfterCleanup(route, from: view, window: window)
            }
        }
        return true
    }

    static func presentCleanupFailure(in view: UIViewController) {
        let alert = UIAlertController(
            title: L10n.text("devices__list__account_data_could_not_be_deleted", fallback: "Account data could not be deleted"),
            message: L10n.text("devices__list__please_try_again", fallback: "Please try again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.text("common__action__ok", fallback: "OK"), style: .default))
        view.present(alert, animated: true)
    }

    static func routeAfterCleanup(
        _ route: QuitAccountCleanupRoute,
        from view: UIViewController,
        window requestedWindow: UIWindow? = nil
    ) {
        let window = requestedWindow ?? view.viewIfLoaded?.window ?? AppRootCoordinator.active?.window
        let sceneCoordinator = (window?.windowScene?.delegate as? SceneDelegate)?.rootCoordinator.flatMap {
            $0.window === window ? $0 : nil
        }
        let activeCoordinator = AppRootCoordinator.active.flatMap { $0.window === window ? $0 : nil }
        let coordinator = sceneCoordinator ?? activeCoordinator
        let finish = {
            coordinator?.clearPresentedModalStateForRootRebuild()
            switch route {
            case .onboarding:
                if let coordinator {
                    coordinator.rebuildRootAfterAccountRemoval()
                } else {
                    let appDelegate = UIApplication.shared.delegate as? AppDelegate
                    AppDelegate.setupRootViewController(instance: appDelegate, window: window, userInfo: nil)
                }
            case .root:
                view.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                view.navigationController?.navigationBar.shadowImage = nil
                view.navigationController?.popToRootViewController(animated: false)
            }
        }
        if let root = window?.rootViewController, root.presentedViewController != nil {
            // Dismiss the entire account/settings stack before replacing its root.
            root.dismiss(animated: false, completion: finish)
        } else {
            finish()
        }
    }

    static func makeProgressView(in view: UIView) -> UIView {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        overlay.isAccessibilityElement = true
        overlay.accessibilityLabel = "Deleting account data from this device".localizeString(id: "account_quit_cleanup_progress_accessibility", arguments: [])
        overlay.accessibilityTraits = .updatesFrequently
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        let label = UILabel()
        label.text = "Deleting account data...".localizeString(id: "account_quit_cleanup_progress", arguments: [])
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [indicator, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        overlay.addSubview(stack)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.layoutMarginsGuide.trailingAnchor)
        ])
        return overlay
    }

    func present(in view: UIViewController, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: "Quit account"
                                        .localizeString(id: "settings_account__button_quit_account", arguments: []),
                                      message: Self.confirmationMessage(jid: jid),
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Quit".localizeString(id: "quit", arguments: []), style: .destructive, handler: { (_) in
            completion?()
        }))
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = view.view
                popoverController.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        view.present(alert, animated:  animated, completion: nil)
    }
}
