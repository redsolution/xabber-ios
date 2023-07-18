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
import CocoaLumberjack


extension UIImage {
    enum ImageDataType {
        case png
        case jpeg(CGFloat)
    }
    
    func toBase64(_ type: ImageDataType) -> String? {
        let imageData: NSData
        switch type {
        case .png:
            guard let data = self.pngData() else {
                DDLogDebug("cant get png from image. \(#function)")
                return nil
            }
            imageData = data as NSData
        case .jpeg(let compression):
            guard let data = self.jpegData(compressionQuality: compression) else {
                DDLogDebug("cant get jpeg from image. \(#function)")
                return nil
            }
            imageData = data as NSData
        }
        return imageData.base64EncodedString(options: .lineLength64Characters)
    }
}
