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

struct XTokenInvalidatePresenter {
    
    func present(jid: String, title: String, message: String, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ok".localizeString(id: "ok", arguments: []), style: .cancel, handler: nil))
        let bounds = UIScreen.main.bounds
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController?.view
                popoverController.sourceRect = CGRect(x: bounds.midX,
                                                      y: bounds.midY,
                                                      width: 0,
                                                      height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController?.present(alert, animated: true, completion: completion)
    }
}
