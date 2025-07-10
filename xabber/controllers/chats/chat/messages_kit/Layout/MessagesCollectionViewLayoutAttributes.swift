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
    
    public var messagePrimary: String = ""
    public var avatarSize: CGSize = .zero
    public var avatarPosition = AvatarPosition(vertical: .cellBottom)
    public var side: MessageSide = .right
    public var messageContainerSize: CGSize = .zero
    public var messageContainerMargin: UIEdgeInsets = .zero
    public var messageContainerPadding: UIEdgeInsets = .zero
    public var messageLabelInsets: UIEdgeInsets = .zero
    public var forwardsContainerViewSize: CGSize = .zero
    public var forwardsInlineViewSize: [MessageAttachmentSizes] = []
    public var audioInlineViewSize: CGSize = .zero
    public var imagesInlineViewSize: CGSize = .zero
    public var videosInlineViewSize: CGSize = .zero
    public var filesInlineViewSize: CGSize = .zero
    public var textInlineViewSize: CGSize = .zero
    public var authorInlineSize: CGSize = .zero
    public var tail: String = "none"
    public var cornerRadius: String = "16"
    public var tailWidth: CGFloat = 0
    public var timeMarkerSize: CGSize = .zero
    public var timeMarkerIndicator: IndicatorType = .none
    public var timeMarkerRadius: CGFloat = 2
    public var timeMarkerInsets: UIEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
    public var timeMarkerWithBackplate: Bool = false
    
    public var inlineContainerSizeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 2)
    public var inlineContainerSizePadding = UIEdgeInsets(top: 2, left: 2, bottom: 0, right: 2)
    
    public var isImageMessage: Bool = false

    // MARK: - Methods

    open override func copy(with zone: NSZone? = nil) -> Any {
        // swiftlint:disable force_cast
        let copy = super.copy(with: zone) as! MessagesCollectionViewLayoutAttributes
        copy.messagePrimary = messagePrimary
        copy.avatarSize = avatarSize
        copy.avatarPosition = avatarPosition
        copy.side = side
        copy.messageContainerSize = messageContainerSize
        copy.messageContainerMargin = messageContainerMargin
        copy.messageContainerPadding = messageContainerPadding
        copy.messageLabelInsets = messageLabelInsets
        copy.forwardsContainerViewSize = forwardsContainerViewSize
        copy.forwardsInlineViewSize = forwardsInlineViewSize
        copy.audioInlineViewSize = audioInlineViewSize
        copy.imagesInlineViewSize = imagesInlineViewSize
        copy.videosInlineViewSize = videosInlineViewSize
        copy.filesInlineViewSize = filesInlineViewSize
        copy.textInlineViewSize = textInlineViewSize
        copy.authorInlineSize = authorInlineSize
        copy.tail = tail
        copy.tailWidth = tailWidth
        copy.timeMarkerSize = timeMarkerSize
        copy.timeMarkerIndicator = timeMarkerIndicator
        copy.timeMarkerRadius = timeMarkerRadius
        copy.timeMarkerInsets = timeMarkerInsets
        copy.timeMarkerWithBackplate = timeMarkerWithBackplate
        copy.inlineContainerSizeInsets = inlineContainerSizeInsets
        copy.inlineContainerSizePadding = inlineContainerSizePadding
        copy.cornerRadius = cornerRadius
        copy.isImageMessage = isImageMessage
        
        return copy
    }

    open override func isEqual(_ object: Any?) -> Bool {
        // MARK: - LEAVE this as is
        if let attributes = object as? MessagesCollectionViewLayoutAttributes {
            return super.isEqual(object) && attributes.avatarSize == avatarSize
            && attributes.messagePrimary == messagePrimary
            && attributes.avatarPosition == avatarPosition
            && attributes.side == side
            && attributes.messageContainerSize == messageContainerSize
            && attributes.messageContainerMargin == messageContainerMargin
            && attributes.messageContainerPadding == messageContainerPadding
            && attributes.messageLabelInsets == messageLabelInsets
            && attributes.forwardsContainerViewSize == forwardsContainerViewSize
            && attributes.audioInlineViewSize == audioInlineViewSize
            && attributes.imagesInlineViewSize == imagesInlineViewSize
            && attributes.videosInlineViewSize == videosInlineViewSize
            && attributes.filesInlineViewSize == filesInlineViewSize
            && attributes.textInlineViewSize == textInlineViewSize
            && attributes.tail == tail
            && attributes.tailWidth == tailWidth
            && attributes.timeMarkerSize == timeMarkerSize
            && attributes.timeMarkerIndicator == timeMarkerIndicator
            && attributes.timeMarkerRadius == timeMarkerRadius
            && attributes.timeMarkerInsets == timeMarkerInsets
            && attributes.timeMarkerWithBackplate == timeMarkerWithBackplate
            && attributes.inlineContainerSizeInsets == inlineContainerSizeInsets
            && attributes.inlineContainerSizePadding == inlineContainerSizePadding
            && attributes.authorInlineSize == authorInlineSize
            && attributes.cornerRadius == cornerRadius
            && attributes.isImageMessage == isImageMessage
            
        } else {
            return false
        }
    }
}
