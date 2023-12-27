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

class XabberAlertController: UIAlertController {
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: false, completion: completion)
    }
}

class ActionSheetPresenter {
    
    struct Item {
        let destructive: Bool
        let title: String
        let value: String
        let isEnabled: Bool?
        
        init(destructive: Bool, title: String, value: String, isEnabled: Bool? = nil) {
            self.destructive = destructive
            self.title = title
            self.value = value
            self.isEnabled = isEnabled
        }
    }
    
    public var alert: XabberAlertController? = nil
//    public var cancelAction: (() -> Void)? = nil
    public var completion: (() -> Void)? = nil
    
    func present(in view: UIViewController, title: String?, message: String?, cancel: String?, values: [Item], animated: Bool, cancelAction: (() -> Void)? = nil, completion: @escaping ((String)->Void)) {
        self.alert = XabberAlertController(title: title, message: message, preferredStyle: .actionSheet)
        values.forEach {
            item in
            let action = UIAlertAction(title: item.title, style: item.destructive ? .destructive : .default, handler: { (action) in
                completion(item.value)
            })
            action.isEnabled = (item.isEnabled ?? true) ? true : false
            alert?.addAction(action)
        }
        if let cancel = cancel {
            alert?.addAction(UIAlertAction(title: cancel, style: .cancel, handler: { (action) in
                cancelAction?()
            }))
        }
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert?.popoverPresentationController {
                popoverController.sourceView = view.view
                popoverController.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        view.present(alert!, animated:  animated, completion: self.completion)
    }
}


