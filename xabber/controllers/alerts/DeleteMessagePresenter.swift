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

struct DeleteMessagePresenter {
    let username: String
    let groupchat: Bool
    let sended: Bool
    
    func present(in view: UIViewController, animated: Bool, completion: @escaping ((Bool?)->Void)) {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if groupchat{
            alert.addAction(UIAlertAction(title: "Delete for all".localizeString(id: "dialog_clear_chat_history__option_delete_for_all", arguments: []), style: .default, handler: { (_) in
                completion(true)
            }))
        } else if !sended {
            alert.addAction(UIAlertAction(title: "Delete".localizeString(id: "delete_chat_button", arguments: []), style: .default, handler: { (_) in
                completion(nil)
            }))
        } else {
            alert.addAction(UIAlertAction(title: "Delete for me".localizeString(id: "delete_for_me_chat_button", arguments: []), style: .default, handler: { (_) in
                completion(false)
            }))
            alert.addAction(UIAlertAction(title: "Delete for me and \(username) ", style: .default, handler: { (_) in
                completion(true)
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel, handler: { (_) in
            
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
