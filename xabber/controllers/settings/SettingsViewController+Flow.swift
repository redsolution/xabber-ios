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

extension SettingsViewController {
    
    @objc
    internal func dismissScreen() {
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc
    internal func onEdit(sender: AnyObject) {
        self.tableView.setEditing(true, animated: true)
        navigationItem.setRightBarButton(doneEditButton, animated: true)
    }
    
    @objc
    internal func onDoneEditing(sender: AnyObject) {
        self.tableView.setEditing(false, animated: true)
        navigationItem.setRightBarButton(editButton, animated: true)
    }
    
    @objc
    internal func showAccountColorViewController() {
        let vc = AccountColorViewController()
        vc.isModal = true
        vc.configure(for: jid)
        showModal(vc, from: self)
    }

    @objc
    internal func addAccount() {
        let vc = SignInCreditionalsViewController()
        vc.isModal = true
        showModal(vc, from: self)
    }
    
    internal func showAccountInfo(_ jid: String, isEnabled: Bool) {
        let vc = AccountInfoViewController()
        vc.jid = jid
        vc.configureTokens(for: jid)
        navigationController?.pushViewController(vc, animated: true)
        if isEnabled {
            AccountManager.shared.find(for: jid)?.action({ (user, stream) in
                user.blocked.requestBlocklist(stream)
            })
        }
    }

    internal func showSettings(by key: String?) {
        guard let key = key,
            let datasource = SettingManager.shared.getDatasource(by: key) else {
            self.view.makeToast("Feature is non implemented")
            return
        }
        let vc = SettingsItemDetailViewController()
        self.hidesBottomBarWhenPushed = false
        vc.hidesBottomBarWhenPushed = true
        vc.configure(for: datasource)
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func onDeleteXMPPAccount(jid: String) {
        let presenter = QuitAccountPresenter(jid: jid)
        presenter.present(in: self, animated: true) {
            AccountManager.shared.deleteAccount(by: jid)
            if AccountManager.shared.emptyAccountsList() {
                DispatchQueue.main.async {
                    let vc = OnboardingViewController()
                    
                    let navigationController = UINavigationController(rootViewController: vc)
                    
                    navigationController.isNavigationBarHidden = true
                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                }
            }
        }
    }
}
