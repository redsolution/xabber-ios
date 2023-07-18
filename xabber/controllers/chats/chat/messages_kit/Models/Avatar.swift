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

/// An object used to group the information to be used by an `AvatarView`.
public struct Avatar {
    
    // MARK: - Properties
    
    /// The image to be used for an `AvatarView`.
    public let image: UIImage?
    
    /// The placeholder initials to be used in the case where no image is provided.
    ///
    /// The default value of this property is "?".
    public var initials: String = "?"
    
    // MARK: - Initializer
    
    public init(image: UIImage? = nil, initials: String = "?") {
        self.image = image
        self.initials = initials
    }
    
}
