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

extension DevicesListViewController {
    typealias AccountQuitDeletionHandler = (_ jid: String, _ completion: @escaping (AccountDeletionCleanupResult) -> Void) -> Void
    
    internal func quitAccount() {
        guard accountQuitFlow.canStartQuit else {
            return
        }

        let presenter = QuitAccountPresenter(jid: jid)
        presenter.present(in: self, animated: true) { [weak self] in
            self?.beginConfirmedQuitAccountCleanup()
        }
    }

    @discardableResult
    internal func beginConfirmedQuitAccountCleanup() -> Bool {
        guard accountQuitFlow.beginCleanup() else {
            return false
        }

        setAccountQuitProgressVisible(true)
        DispatchQueue.main.async { [weak self] in
            self?.performConfirmedQuitAccountCleanup()
        }
        return true
    }

    private func performConfirmedQuitAccountCleanup() {
        unsubscribe()
        accountQuitDeletionHandler?(jid) { [weak self] result in
            self?.finishConfirmedQuitAccountCleanup(result)
        } ?? AccountManager.shared.deleteAccountAsync(by: jid) { [weak self] result in
            self?.finishConfirmedQuitAccountCleanup(result)
        }
    }

    private func finishConfirmedQuitAccountCleanup(_ result: AccountDeletionCleanupResult) {
        guard result.succeeded else {
            accountQuitFlow.failCleanup()
            setAccountQuitProgressVisible(false)
            presentAccountQuitCleanupFailure()
            return
        }

        let hasRemainingAccounts = accountQuitRemainingAccountsProvider?()
            ?? !AccountManager.shared.emptyAccountsList()
        let route = accountQuitFlow.complete(hasRemainingAccounts: hasRemainingAccounts)
        setAccountQuitProgressVisible(false)
        routeAfterQuitAccountCleanup(route)
    }

    private func presentAccountQuitCleanupFailure() {
        let alert = UIAlertController(
            title: "Account data could not be deleted",
            message: "Please try again.",
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(
                title: "OK",
                style: .default
            )
        )
        present(alert, animated: true)
    }

    private func routeAfterQuitAccountCleanup(_ route: QuitAccountCleanupRoute) {
        switch route {
        case .onboarding:
            DispatchQueue.main.async {
                let vc = OnboardingViewController()
                let navigationController = UINavigationController(rootViewController: vc)
                navigationController.isNavigationBarHidden = true
                (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
            }
        case .root:
            DispatchQueue.main.async {
                self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                self.navigationController?.navigationBar.shadowImage = nil
                self.navigationController?.popToRootViewController(animated: true)
            }
        }
    }
    
    internal final func onRevokeAll() {
        guard accountQuitFlow.canPerformSecurityAction else {
            return
        }

        let hasConnection = !AccountManager.shared.connectingUsers.value.contains(self.jid)
        guard hasConnection else {
            ActionSheetPresenter().present(
                in: self,
                title: "No connection",
                message: "Please wait while connection established",
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: [],
                animated: true) { _ in
            }
            return
        }

        let confirmation = DevicesTerminateAllSessionsConfirmation.default
        YesNoPresenter().present(
            in: self,
            style: .actionSheet,
            title: confirmation.title,
            message: confirmation.message,
            yesText: confirmation.confirmTitle,
            dangerYes: true,
            noText: confirmation.cancelTitle,
            animated: true) { [weak self] confirmed in
            guard confirmation.effect(confirmed: confirmed) == .revokeAllOtherSessions else {
                return
            }
            self?.revokeAllOtherDeviceSessions()
        }
    }

    private func revokeAllOtherDeviceSessions() {
        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
            user.devices.revokeAll(stream)
        })
    }
    
    internal final func showTokenInfo(uid: String, canEdit: Bool) {
        guard accountQuitFlow.canPerformSecurityAction else {
            return
        }

        let vc = DeviceDetailViewController()
        vc.owner = self.jid
        vc.jid = self.jid
        vc.uid = uid
        vc.canEdit = canEdit
        vc.delegate = self
        self.navigationController?.pushViewController(vc, animated: true)
    }
}

extension DevicesListViewController: XabberUpdateIfNeededDelegate {
    func updateIfNeeded() {
        self.subscribe()
    }
}
