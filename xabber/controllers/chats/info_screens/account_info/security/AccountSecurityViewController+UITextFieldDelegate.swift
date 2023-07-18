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

extension AccountSecurityViewController: UITextFieldDelegate {
    
    func updateCreditionals(_ textField: UITextField) -> Bool {
        switch textField.restorationIdentifier {
        case "password":
            password = textField.text ?? ""
        default: break
        }
        doneButtonActive.accept(validate())
        return true
    }
    
    func validate() -> Bool {
        if password != initialPassword { return true }
        return false
    }
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        _ = updateCreditionals(textField)
    }
    
    func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        return updateCreditionals(textField)
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return updateCreditionals(textField)
    }
    
}
