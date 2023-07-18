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

internal class NSLayoutConstraintSet {
    
    internal var top: NSLayoutConstraint?
    internal var bottom: NSLayoutConstraint?
    internal var left: NSLayoutConstraint?
    internal var right: NSLayoutConstraint?
    internal var centerX: NSLayoutConstraint?
    internal var centerY: NSLayoutConstraint?
    internal var width: NSLayoutConstraint?
    internal var height: NSLayoutConstraint?
    
    internal init(top: NSLayoutConstraint? = nil, bottom: NSLayoutConstraint? = nil,
                left: NSLayoutConstraint? = nil, right: NSLayoutConstraint? = nil,
                centerX: NSLayoutConstraint? = nil, centerY: NSLayoutConstraint? = nil,
                width: NSLayoutConstraint? = nil, height: NSLayoutConstraint? = nil) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }

    /// All of the currently configured constraints
    private var availableConstraints: [NSLayoutConstraint] {
        let constraints = [top, bottom, left, right, centerX, centerY, width, height]
        var available: [NSLayoutConstraint] = []
        for constraint in constraints {
            if let value = constraint {
                available.append(value)
            }
        }
        return available
    }
    
    /// Activates all of the non-nil constraints
    ///
    /// - Returns: Self
    @discardableResult
    internal func activate() -> Self {
        NSLayoutConstraint.activate(availableConstraints)
        return self
    }
    
    /// Deactivates all of the non-nil constraints
    ///
    /// - Returns: Self
    @discardableResult
    internal func deactivate() -> Self {
        NSLayoutConstraint.deactivate(availableConstraints)
        return self
    }
}
