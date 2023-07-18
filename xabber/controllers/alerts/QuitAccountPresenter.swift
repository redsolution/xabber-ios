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

struct QuitAccountPresenter {
    let jid: String
    
    
    func present(in view: UIViewController, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: "Quit account"
                                        .localizeString(id: "settings_account__button_quit_account", arguments: []),
                                      message: ["You are quitting".localizeString(id: "account_quitting", arguments: []),
                                                jid, "account. Account data will be deleted from this device. Your data on server will not be affected.".localizeString(id: "account_data_deletion", arguments: [])
                                               ].joined(separator: " "),
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
