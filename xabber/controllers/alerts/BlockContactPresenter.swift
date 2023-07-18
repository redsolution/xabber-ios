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

struct BlockContactPresenter {
    let username: String
    let jid: String
    let owner: String
    let isBlocked: Bool
    
    
    func present(in view: UIViewController, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: self.isBlocked ? "Unblock contact"
                                        .localizeString(id: "chat_settings__button_unblock_contact", arguments: []) :
                                        "Block contact".localizeString(id: "contact_block", arguments: []),
                                      message: ["Do you want to ".localizeString(id: "contact_list_do_you_want", arguments: []), self.isBlocked ?
                                                "Unblock".localizeString(id: "contact_bar_unblock", arguments: []) :
                                                "Block".localizeString(id: "contact_bar_block", arguments: []), self.username].joined(),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: self.isBlocked ? "Unblock".localizeString(id: "contact_bar_unblock", arguments: []) :
                                        "Block".localizeString(id: "contact_bar_block", arguments: []),
                                      style: .destructive, handler: { (_) in
            AccountManager.shared.users.first(where: {$0.jid == self.owner})?.action({ (user, stream) in
                if self.isBlocked {
                    user.blocked.unblockContact(stream, jid: self.jid)
                } else {
                    user.blocked.blockContact(stream, jid: self.jid)
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
