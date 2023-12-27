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

public func base64ToImage(_ string: String) -> UIImage? {
    let stringArr = string.components(separatedBy: ".")
    var string = string
    if stringArr.count > 1 {
        string = stringArr[1]
    } else {
        string = stringArr[0]
    }
    guard let data = Data(base64Encoded: string, options: .ignoreUnknownCharacters) else { return nil }
    return UIImage(data: data)
}

public func imageToBase64(_ image: UIImage) -> String? {
    guard let collection = image.pngData()?.bytes else { return nil }
    let string = Data(collection).base64EncodedString()
    return string
}
