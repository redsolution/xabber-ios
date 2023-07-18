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

import UIKit

public struct LabelAlignment {

    public var textAlignment: NSTextAlignment
    public var textInsets: UIEdgeInsets
    
    public init(textAlignment: NSTextAlignment, textInsets: UIEdgeInsets) {
        self.textAlignment = textAlignment
        self.textInsets = textInsets
    }

}

// MARK: - Equatable Conformance

extension LabelAlignment: Equatable {

    public static func == (lhs: LabelAlignment, rhs: LabelAlignment) -> Bool {
        return lhs.textAlignment == rhs.textAlignment && lhs.textInsets == rhs.textInsets
    }

}
