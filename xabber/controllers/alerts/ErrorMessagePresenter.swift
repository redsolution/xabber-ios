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

struct ErrorMessagePresenter {
    
    
    func present(in view: UIViewController, alert: Bool = false, title: String? = nil, message: String, animated: Bool, completion: (()->Void)?) {
        if alert {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Close".localizeString(id: "close", arguments: []), style: .cancel, handler: { (action) in
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
        } else {
            view.view?.makeToast(message,
                                 duration: 3.0,
                                 position: .bottom)
            completion?()
        }
        
    }
}
