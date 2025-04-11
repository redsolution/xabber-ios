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


extension CGSize {
    internal init(square: CGFloat) {
        self.init(width: square, height: square)
    }
    var x2: CGSize {
        return CGSize(width: self.width * 2, height: self.height * 2)
    }
    
    var x3: CGSize {
        return CGSize(width: self.width * 3, height: self.height * 3)
    }
    
    func scale(with multiplier: CGFloat) -> CGSize {
        return CGSize(width: self.width * multiplier, height: self.height * multiplier)
    }
    
    func swapCoords() -> CGSize {
        return CGSize(width: self.height, height: self.width)
    }
    
    // if one of side of current size less than args size - return true, else return false
    func lessThan(_ size: CGSize) -> Bool{
        if size.width > self.width {
            return true
        }
        if size.height > self.height {
            return true
        }
        return false
    }
    
    func margin(width: CGFloat, height: CGFloat) -> CGSize {
        if self == .zero {
            return .zero
        }
        return CGSize(
            width: self.width + width,
            height: self.height + height
        )
    }
    
    func padding(width: CGFloat, height: CGFloat) -> CGSize {
        if self == .zero {
            return .zero
        }
        return CGSize(
            width: self.width - width,
            height: self.height - height
        )
    }
}
