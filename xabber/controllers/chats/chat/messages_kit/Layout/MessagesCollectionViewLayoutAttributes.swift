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

/// The layout attributes used by a `MessageCollectionViewCell` to layout its subviews.
open class MessagesCollectionViewLayoutAttributes: UICollectionViewLayoutAttributes {

    // MARK: - Properties

    public var avatarSize: CGSize = .zero
    public var avatarPosition = AvatarPosition(vertical: .cellBottom)

    public var messageContainerSize: CGSize = .zero
    public var messageContainerPadding: UIEdgeInsets = .zero
    public var messageLabelFont: UIFont = UIFont.preferredFont(forTextStyle: .body)
    public var messageLabelInsets: UIEdgeInsets = .zero
    public var inlineForwardsOffset: CGFloat = 0.0
    public var inlineForwardsSizes: [CGSize] = []

    public var cellTopLabelAlignment = LabelAlignment(textAlignment: .center, textInsets: .zero)
    public var cellTopLabelSize: CGSize = .zero
    
    public var messageTopLabelAlignment = LabelAlignment(textAlignment: .center, textInsets: .zero)
    public var messageTopLabelSize: CGSize = .zero

    public var messageBottomLabelAlignment = LabelAlignment(textAlignment: .center, textInsets: .zero)
    public var messageBottomLabelSize: CGSize = CGSize(width: 42, height: 16)
    public var messageBottomPadding: CGFloat = 4
    
    public var inlineMessageMargin: UIEdgeInsets = UIEdgeInsets(top: 4, bottom: 4, left: 4, right: 4)
    
    public var showMessageStateIndicator: Bool = true
    
    public var shouldShowTopLabel: Bool = false

    // MARK: - Methods

    open override func copy(with zone: NSZone? = nil) -> Any {
        // swiftlint:disable force_cast
        let copy = super.copy(with: zone) as! MessagesCollectionViewLayoutAttributes
        copy.avatarSize = avatarSize
        copy.avatarPosition = avatarPosition
        copy.messageContainerSize = messageContainerSize
        copy.messageContainerPadding = messageContainerPadding
        copy.messageLabelFont = messageLabelFont
        copy.messageLabelInsets = messageLabelInsets
        copy.cellTopLabelAlignment = cellTopLabelAlignment
        copy.cellTopLabelSize = cellTopLabelSize
        copy.messageTopLabelAlignment = messageTopLabelAlignment
        copy.messageTopLabelSize = messageTopLabelSize
        copy.messageBottomLabelAlignment = messageBottomLabelAlignment
        copy.messageBottomLabelSize = messageBottomLabelSize
        
        copy.messageBottomPadding = messageBottomPadding
        
        copy.shouldShowTopLabel = shouldShowTopLabel
        copy.inlineForwardsOffset = inlineForwardsOffset
        copy.inlineForwardsSizes = inlineForwardsSizes
        copy.inlineMessageMargin = inlineMessageMargin
        copy.showMessageStateIndicator = showMessageStateIndicator
        
        return copy
        // swiftlint:enable force_cast
    }

    open override func isEqual(_ object: Any?) -> Bool {
        // MARK: - LEAVE this as is
        if let attributes = object as? MessagesCollectionViewLayoutAttributes {
            return super.isEqual(object) && attributes.avatarSize == avatarSize
                && attributes.avatarPosition == attributes.avatarPosition
                && attributes.messageContainerSize == messageContainerSize
                && attributes.messageContainerPadding == messageContainerPadding
                && attributes.messageLabelFont == messageLabelFont
                && attributes.messageLabelInsets == messageLabelInsets
                && attributes.cellTopLabelAlignment == cellTopLabelAlignment
                && attributes.cellTopLabelSize == cellTopLabelSize
                && attributes.messageTopLabelAlignment == messageTopLabelAlignment
                && attributes.messageTopLabelSize == messageTopLabelSize
                && attributes.messageBottomLabelAlignment == messageBottomLabelAlignment
                && attributes.messageBottomLabelSize == messageBottomLabelSize
                && attributes.messageBottomPadding == messageBottomPadding
                && attributes.shouldShowTopLabel == shouldShowTopLabel
                && attributes.inlineForwardsOffset == inlineForwardsOffset
                && attributes.inlineForwardsSizes == inlineForwardsSizes
                && attributes.inlineMessageMargin == inlineMessageMargin
                && attributes.showMessageStateIndicator == showMessageStateIndicator
        } else {
            return false
        }
    }
}
