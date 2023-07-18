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

struct YesNoPresenter {
    
    
    func present(in view: UIViewController, style: UIAlertController.Style = .actionSheet, title: String?, message: String, yesText: String, dangerYes: Bool = false, showCancelAction: Bool = true, noText: String, animated: Bool, completion: @escaping ((Bool)->Void)) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: style)
        alert.addAction(UIAlertAction(title: yesText, style: dangerYes ? .destructive : .default, handler: { (_) in
            completion(true)
        }))
        if showCancelAction {
            alert.addAction(UIAlertAction(title: noText, style: .cancel, handler: { (_) in
                completion(false)
            }))
        }
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
