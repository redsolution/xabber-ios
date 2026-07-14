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
    public var locationsInlineViewSize: CGSize = .zero
    public var contactsInlineViewSize: CGSize = .zero
    public var filesInlineViewSize: CGSize = .zero
    public var textInlineViewSize: CGSize = .zero
    public var warningInlineViewSize: CGSize = .zero
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
        copy.locationsInlineViewSize = locationsInlineViewSize
        copy.contactsInlineViewSize = contactsInlineViewSize
        copy.filesInlineViewSize = filesInlineViewSize
        copy.textInlineViewSize = textInlineViewSize
        copy.warningInlineViewSize = warningInlineViewSize
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
            && attributes.forwardsInlineViewSize == forwardsInlineViewSize
            && attributes.audioInlineViewSize == audioInlineViewSize
            && attributes.imagesInlineViewSize == imagesInlineViewSize
            && attributes.videosInlineViewSize == videosInlineViewSize
            && attributes.locationsInlineViewSize == locationsInlineViewSize
            && attributes.contactsInlineViewSize == contactsInlineViewSize
            && attributes.filesInlineViewSize == filesInlineViewSize
            && attributes.textInlineViewSize == textInlineViewSize
            && attributes.warningInlineViewSize == warningInlineViewSize
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

    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(super.hash)
        hasher.combine(messagePrimary)
        combine(avatarSize, into: &hasher)
        combine(avatarPosition, into: &hasher)
        combine(side, into: &hasher)
        combine(messageContainerSize, into: &hasher)
        combine(messageContainerMargin, into: &hasher)
        combine(messageContainerPadding, into: &hasher)
        combine(messageLabelInsets, into: &hasher)
        combine(forwardsContainerViewSize, into: &hasher)
        forwardsInlineViewSize.forEach { combine($0, into: &hasher) }
        combine(audioInlineViewSize, into: &hasher)
        combine(imagesInlineViewSize, into: &hasher)
        combine(videosInlineViewSize, into: &hasher)
        combine(locationsInlineViewSize, into: &hasher)
        combine(contactsInlineViewSize, into: &hasher)
        combine(filesInlineViewSize, into: &hasher)
        combine(textInlineViewSize, into: &hasher)
        combine(warningInlineViewSize, into: &hasher)
        combine(authorInlineSize, into: &hasher)
        hasher.combine(tail)
        hasher.combine(cornerRadius)
        hasher.combine(tailWidth)
        combine(timeMarkerSize, into: &hasher)
        combine(timeMarkerIndicator, into: &hasher)
        hasher.combine(timeMarkerRadius)
        combine(timeMarkerInsets, into: &hasher)
        hasher.combine(timeMarkerWithBackplate)
        combine(inlineContainerSizeInsets, into: &hasher)
        combine(inlineContainerSizePadding, into: &hasher)
        hasher.combine(isImageMessage)
        return hasher.finalize()
    }

    private func combine(_ size: CGSize, into hasher: inout Hasher) {
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    private func combine(_ insets: UIEdgeInsets, into hasher: inout Hasher) {
        hasher.combine(insets.top)
        hasher.combine(insets.left)
        hasher.combine(insets.bottom)
        hasher.combine(insets.right)
    }

    private func combine(_ position: AvatarPosition, into hasher: inout Hasher) {
        switch position.horizontal {
        case .cellLeading: hasher.combine(0)
        case .cellTrailing: hasher.combine(1)
        case .natural: hasher.combine(2)
        }
        switch position.vertical {
        case .cellTop: hasher.combine(0)
        case .messageLabelTop: hasher.combine(1)
        case .messageTop: hasher.combine(2)
        case .messageCenter: hasher.combine(3)
        case .messageBottom: hasher.combine(4)
        case .cellBottom: hasher.combine(5)
        }
    }

    private func combine(_ side: MessageSide, into hasher: inout Hasher) {
        switch side {
        case .left: hasher.combine(0)
        case .right: hasher.combine(1)
        }
    }

    private func combine(_ indicator: IndicatorType, into hasher: inout Hasher) {
        switch indicator {
        case .none: hasher.combine(0)
        case .sending: hasher.combine(1)
        case .sended: hasher.combine(2)
        case .received: hasher.combine(3)
        case .read: hasher.combine(4)
        case .error: hasher.combine(5)
        }
    }

    private func combine(_ sizes: MessageAttachmentSizes, into hasher: inout Hasher) {
        combine(sizes.textLabelSize, into: &hasher)
        combine(sizes.imagesContainerSize, into: &hasher)
        combine(sizes.videosContainerSize, into: &hasher)
        combine(sizes.locationsContainerSize, into: &hasher)
        combine(sizes.contactsContainerSize, into: &hasher)
        combine(sizes.filesContainerSize, into: &hasher)
        combine(sizes.audiosContainerSize, into: &hasher)
        combine(sizes.containerSize, into: &hasher)
        combine(sizes.authorSize, into: &hasher)
        combine(sizes.messageContainer, into: &hasher)
        combine(sizes.timeMarker, into: &hasher)
    }
}
