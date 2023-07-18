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

struct InvalidPasswordPresenter {
    
    
    func present(in view: UIViewController, jid: String, title: String, message: String, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { (field) in
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Close".localizeString(id: "close", arguments: []), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Connect".localizeString(id: "connect", arguments: []), style: .default, handler: { (action) in
            guard let field = alert.textFields?.first,
                let password = field.text,
                password.isNotEmpty else {
                return
            }
            //TODO
//            AccountManager.shared.find(for: jid)?.action({ (user, stream) in
//                user.password = password
//                user.storePassword()
//            })
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
