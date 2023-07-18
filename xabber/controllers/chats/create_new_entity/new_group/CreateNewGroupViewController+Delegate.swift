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

protocol CreateNewGroupViewControllerDelegate {
    func willUpdateTextField(_ itemId: String, value: String?)
    func onChangeDescription(_ text: String?)
}

extension CreateNewGroupViewController: CreateNewGroupViewControllerDelegate {
    func willUpdateTextField(_ itemId: String, value: String?) {
        switch itemId {
        case "name":
            if canGenerateLocalpart {
                localpart = value?.slugify()?.lowercased()
            }
            name.accept(value)//?.isEmpty ?? true ? nil : value
        case "localpart":
            if let value = value {
                canGenerateLocalpart = value.isEmpty
            } else {
                canGenerateLocalpart = true
            }
            localpart = value
        default: break
        }
    }
    
    func onChangeDescription(_ text: String?) {
        descr = text ?? ""
    }
}
