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

struct DeleteContactPresenter {
    let username: String
    let jid: String
    let owner: String
    
    
    func present(in view: UIViewController, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: "Delete contact".localizeString(id: "contact_delete_full", arguments: []), message: "Do you want to delete \(self.username) from your roster?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete".localizeString(id: "contact_delete", arguments: []), style: .destructive, handler: { (_) in
            view.navigationController?.setNavigationBarHidden(false, animated: true)
            view.navigationController?.popToRootViewController(animated: true)
            AccountManager.shared.users.first(where: {$0.jid == self.owner})?.action({ (user, stream) in
                user.roster.removeContact(stream, jid: self.jid) { (jid, error, success) in
                    if !success {
                        DispatchQueue.main.async {
                            var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                            if let error = error {
                                switch error {
                                case "item-not-found":
                                    message = "JID \(self.jid) not found".localizeString(id: "contact_jid_not_found", arguments: ["\(self.jid)"])
                                case "forbidden":
                                    message = "Can`t perform request".localizeString(id: "contact_cant_perform_request", arguments: [])
                                case "remote-server-not-found":
                                    message = "Remote server not found".localizeString(id: "message_manager_error_no_remote_server", arguments: [])
                                default: break
                                }
                            }
                            view.view.makeToast(message)
                        }
                    }
                    completion?()
                }
            })
        }))
        alert.addAction(UIAlertAction(title: "Delete and block".localizeString(id: "contact_block_and_delete", arguments: []), style: .destructive, handler: { (_) in
            view.navigationController?.setNavigationBarHidden(false, animated: true)
            view.navigationController?.popToRootViewController(animated: true)
            AccountManager.shared.users.first(where: {$0.jid == self.owner})?.action({ (user, stream) in
                user.roster.removeContact(stream, jid: self.jid) { (jid, error, success) in
                    if success {
                        user.blocked.blockContact(stream, jid: self.jid)
                    } else {
                        var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                        if let error = error {
                            switch error {
                            case "item-not-found":
                                message = "JID \(self.jid) not found".localizeString(id: "contact_jid_not_found", arguments: ["\(self.jid)"])
                            case "forbidden":
                                message = "Can`t perform request".localizeString(id: "contact_cant_perform_request", arguments: [])
                            case "remote-server-not-found":
                                message = "Remote server not found".localizeString(id: "message_manager_error_no_remote_server", arguments: [])
                            default: break
                            }
                        }
                        view.view.makeToast(message)
                    }
                    completion?()
                }
            })
        }))
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = view.view
                popoverController.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        view.present(alert, animated:  animated, completion: completion)
    }
}
