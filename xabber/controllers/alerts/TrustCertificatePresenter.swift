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

struct TrustCertificatePresenter {
    let domain: String
    let jid: String
    func present(in view: UIViewController, animated: Bool, completion: @escaping ((Bool)->Void)) {
        let alert = UIAlertController(title: "Unknown certificate".localizeString(id: "account_unknown_certificate", arguments: []),
                                      message: "The identity of  \"\(domain)\" cannot be verified. Do you want to connect to this server anyway?"
                                        .localizeString(id: "account_identity_not_verified_proceed_anyway", arguments: []),
                                      preferredStyle: .alert)
//        alert.addAction(UIAlertAction(title: "Once", style: .default, handler: { (_) in
//            completion(true)
//        }))
        alert.addAction(UIAlertAction(title: "Connect".localizeString(id: "connect", arguments: []), style: .default, handler: { (_) in
            SettingManager.shared.saveItem(for: self.jid, scope: .trustCertificatePolicy, key: "allowed", value: "true")
            completion(true)
        }))
        alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel, handler: { (_) in
            completion(false)
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
