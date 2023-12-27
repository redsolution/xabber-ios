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
    
    internal func quitAccount() {
        let presenter = QuitAccountPresenter(jid: jid)
        presenter.present(in: self, animated: true) {
            self.unsubscribe()
            AccountManager.shared.deleteAccount(by: self.jid)
            if AccountManager.shared.emptyAccountsList() {
                DispatchQueue.main.async {
                    let vc = OnboardingViewController()
                    
                    let navigationController = UINavigationController(rootViewController: vc)
                    
                    navigationController.isNavigationBarHidden = true
                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                }
            } else {
                DispatchQueue.main.async {
                    self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                    self.navigationController?.navigationBar.shadowImage = nil
                    self.navigationController?.popToRootViewController(animated: true)
                }
            }
        }
    }
    
    internal final func onRevokeAll() {
        let items = [
            ActionSheetPresenter.Item(destructive: true, title: "Terminate all other sessions".localizeString(id: "account_terminate_all_other_sessions", arguments: []), value: "terminate")
        ]
        
        let hasConnection = !AccountManager.shared.connectingUsers.value.contains(self.jid)
        
        ActionSheetPresenter().present(
            in: self,
            title: hasConnection ? nil : "No connection",
            message: hasConnection ? nil : "Please wait while connection established",
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: hasConnection ? items : [],
            animated: true) { value in
            switch value {
            case "terminate":
                AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                    user.devices.revokeAll(stream)
                })
            default:
                break
            }
        }
    }
    
    internal final func showTokenInfo(uid: String, canEdit: Bool) {
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
