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

/**
 A UIStackView that's intended for holding `InputBarButtonItem`s
 
 ## Important Notes ##
 1. Default alignment is .fill
 2. Default distribution is .fill
 3. The distribution property needs to be based on its arranged subviews intrinsicContentSize so it is not recommended to change it
 */
final class InputStackView: UIStackView {
    
    /// The stack view position in the MessageInputBar
    ///
    /// - left: Left Stack View
    /// - right: Bottom Stack View
    /// - bottom: Left Stack View
    /// - top: Top Stack View
    public enum Position {
        case left, right, bottom, top
    }
    
    // MARK: Initialization
    
    public convenience init(axis: NSLayoutConstraint.Axis, spacing: CGFloat) {
        self.init(frame: .zero)
        self.axis = axis
        self.spacing = spacing
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required public init(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    // MARK: - Setup
    
    /// Sets up the default properties
    final func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        distribution = .fill
        alignment = .center
    }
}
