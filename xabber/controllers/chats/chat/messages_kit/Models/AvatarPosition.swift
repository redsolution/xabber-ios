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

/// Used to determine the `Horizontal` and `Vertical` position of
// an `AvatarView` in a `MessageCollectionViewCell`.
public struct AvatarPosition {
    
    /// An enum representing the horizontal alignment of an `AvatarView`.
    public enum Horizontal {
        
        /// Positions the `AvatarView` on the side closest to the cell's leading edge.
        case cellLeading
        
        /// Positions the `AvatarView` on the side closest to the cell's trailing edge.
        case cellTrailing
        
        /// Positions the `AvatarView` based on whether the message is from the current Sender.
        /// The cell is positioned `.cellTrailling` if `isFromCurrentSender` is true
        /// and `.cellLeading` if false.
        case natural
    }
    
    /// An enum representing the verical alignment for an `AvatarView`.
    public enum Vertical {
        
        /// Aligns the `AvatarView`'s top edge to the cell's top edge.
        case cellTop
        
        /// Aligns the `AvatarView`'s top edge to the `messageTopLabel`'s top edge.
        case messageLabelTop
        
        /// Aligns the `AvatarView`'s top edge to the `MessageContainerView`'s top edge.
        case messageTop
        
        /// Aligns the `AvatarView` center to the `MessageContainerView` center.
        case messageCenter
        
        /// Aligns the `AvatarView`'s bottom edge to the `MessageContainerView`s bottom edge.
        case messageBottom
        
        /// Aligns the `AvatarView`'s bottom edge to the cell's bottom edge.
        case cellBottom
        
    }
    
    // MARK: - Properties
    
    // The vertical position
    public var vertical: Vertical
    
    // The horizontal position
    public var horizontal: Horizontal
    
    // MARK: - Initializers
    
    public init(horizontal: Horizontal, vertical: Vertical) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public init(vertical: Vertical) {
        self.init(horizontal: .natural, vertical: vertical)
    }
    
}

// MARK: - Equatable Conformance

extension AvatarPosition: Equatable {

    public static func == (lhs: AvatarPosition, rhs: AvatarPosition) -> Bool {
        return lhs.vertical == rhs.vertical && lhs.horizontal == rhs.horizontal
    }

}
