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

extension AccountInfoViewController {
        
    internal final func onRevokeAll() {
        let items = [
            ActionSheetPresenter.Item(destructive: true, title: "Terminate all other sessions".localizeString(id: "account_terminate_all_other_sessions", arguments: []), value: "terminate")
        ]
        
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: items,
            animated: true) { value in
            switch value {
            case "terminate":
                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                    session.devices?.revokeAll(stream)
                } fail: {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.devices.revokeAll(stream)
                    })
                }
            default:
                break
            }
        }
    }
    
    internal final func showTokenInfo(uid: String, canEdit: Bool) {
        let vc = TokenInfoViewController()
        vc.modalTransitionStyle = .coverVertical
        vc.modalPresentationStyle = .overCurrentContext
        vc.jid = self.jid
        vc.uid = uid
        vc.canEdit = canEdit
        vc.delegate = self
        self.present(vc, animated: true, completion: nil)
    }
}

extension AccountInfoViewController: XabberUpdateIfNeededDelegate {
    func updateIfNeeded() {
        self.subscribe()
    }
}
