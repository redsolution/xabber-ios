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

extension AccountEditViewController: UITextFieldDelegate {
    
    func textWasEdited(_ textField: UITextField) -> Bool {
        guard let key = textField.restorationIdentifier else {
            return false
        }
        save(textField.text, for: key)
        return true
    }
    
    func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        return textWasEdited(textField)
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        _ = textWasEdited(textField)
        textField.resignFirstResponder()
        return true
    }
}
