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

class MessageSizeCalculator: CellSizeCalculator {

    public init(layout: MessagesCollectionViewFlowLayout? = nil) {
        super.init()
        
        self.layout = layout
    }

//    public var incomingAvatarSize = CGSize(width: 30, height: 30)
//    public var outgoingAvatarSize = CGSize(width: 30, height: 30)
    
    static public let fileViewHeight: CGFloat = 60
    static public let audioViewHeight: CGFloat = 60
    
    let minMessageWidth: CGFloat = 112
    let bottomLabelWidth: CGFloat = 60
    let bottomCellPadding: CGFloat = 4
    
    var avatarSize = CGSize(square: 32)
    
//    var incomingAvatarSize = CGSize(square: 40)
//    var outgoingAvatarSize = CGSize.zero

    var avatarPosition = AvatarPosition(vertical: .messageBottom)

    var incomingMessagePadding = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 12)
    var outgoingMessagePadding = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 4)
    var inlineMessageMargin = UIEdgeInsets(top: 4, bottom: 0, left: 4, right: 4)
    var inlineMessagePadding = UIEdgeInsets(top: 4, bottom: 4, left: 0, right: 0)
    
    public var incomingMessageLabelInsets = UIEdgeInsets(top: 6, left: 8, bottom: 20, right: 0)
    public var outgoingMessageLabelInsets = UIEdgeInsets(top: 6, left: 0, bottom: 20, right: 8)

    var incomingMessageTopLabelAlignment = LabelAlignment(textAlignment: .left, textInsets: UIEdgeInsets(left: 20))
    var outgoingMessageTopLabelAlignment = LabelAlignment(textAlignment: .right, textInsets: UIEdgeInsets(right: 20))

    var incomingMessageBottomLabelAlignment = LabelAlignment(textAlignment: .left, textInsets: UIEdgeInsets(right: 20))
    var outgoingMessageBottomLabelAlignment = LabelAlignment(textAlignment: .right, textInsets: UIEdgeInsets(right: 44))
    var additionalPaddingForMinForwardComment: CGFloat = 0
    
    var inlineForwardsSizes: [CGSize] = []

    var isConfigured: Bool = false
    
    internal func messageLabelInsets(for message: MessageType) -> UIEdgeInsets {
        let dataSource = messagesLayout.messagesDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return isFromCurrentSender ? outgoingMessageLabelInsets : incomingMessageLabelInsets
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        guard let attributes = attributes as? MessagesCollectionViewLayoutAttributes else { return }

        let dataSource = messagesLayout.messagesDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        inlineForwardsSizes = messageContainerAdditionalSizes(for: message)
        attributes.inlineForwardsSizes = inlineForwardsSizes
        attributes.inlineForwardsOffset = inlineForwardsSizes.compactMap { return $0.height }.reduce(0, +)
        attributes.messageContainerSize = messageContainerSize(for: message)
        if message.withAuthor {
            switch message.kind {
            case .photos(_): attributes.inlineForwardsOffset += 24
            default: attributes.inlineForwardsOffset += 20
            }
        }
        attributes.inlineMessageMargin = inlineMessageMargin
        additionalPaddingForMinForwardComment = 0
        attributes.avatarSize = avatarSize(for: message)
        attributes.avatarPosition = avatarPosition(for: message)
        
        attributes.messageContainerPadding = messageContainerPadding(for: message)
        attributes.cellTopLabelSize = cellTopLabelSize(for: message, at: indexPath)
        attributes.messageTopLabelSize = messageTopLabelSize(for: message, at: indexPath)
        attributes.messageTopLabelAlignment = messageTopLabelAlignment(for: message)

        attributes.messageLabelInsets = messageLabelInsets(for: message)
        
        attributes.messageBottomLabelAlignment = messageBottomLabelAlignment(for: message)
//        attributes.messageBottomLabelSize = messageBottomLabelSize(for: message, at: indexPath)
        attributes.messageBottomPadding = dataSource.messageBottomPadding(at: indexPath)
        if message.isEdited {
            attributes.messageBottomLabelSize.width += 40
        }
        attributes.shouldShowTopLabel = message.withAuthor
        attributes.showMessageStateIndicator = dataSource.showDeliveryIndicator()
        isConfigured = true
    }

    override func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let dataSource = messagesLayout.messagesDataSource
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        inlineForwardsSizes = messageContainerAdditionalSizes(for: message)
        let itemHeight = cellContentHeight(for: message, at: indexPath)
        return CGSize(width: messagesLayout.itemWidth, height: itemHeight)
    }

    func cellContentHeight(for message: MessageType, at indexPath: IndexPath) -> CGFloat {
        var totalHeight: CGFloat = 0
        
        let cellTopLabelHeight = cellTopLabelSize(for: message, at: indexPath).height
        
        let containerSize: CGSize = messageContainerSize(for: message)
//        let topLabelHeight: CGFloat = message.withAuthor ? 20 : 0
        
        
        totalHeight += cellTopLabelHeight
//        totalHeight += topLabelHeight55
        totalHeight += bottomCellPadding
        totalHeight += containerSize.height
        
//        print(containerSize)
        
        return totalHeight
    }

    // MARK: - Avatar

    func avatarPosition(for message: MessageType) -> AvatarPosition {
        let dataSource = messagesLayout.messagesDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        var position = avatarPosition

        switch position.horizontal {
        case .cellTrailing, .cellLeading:
            break
        case .natural:
            position.horizontal = isFromCurrentSender ? .cellTrailing : .cellLeading
        }
        return position
    }

    func avatarSize(for message: MessageType) -> CGSize {
//        let dataSource = messagesLayout.messagesDataSource
        if message.withAvatar {
            return avatarSize
        } else {
            return .zero
        }
    }

    // MARK: - Top cell Label

    func cellTopLabelSize(for message: MessageType, at indexPath: IndexPath) -> CGSize {
        let layoutDelegate = messagesLayout.messagesLayoutDelegate
        let collectionView = messagesLayout.messagesCollectionView
        var height = layoutDelegate.cellTopLabelHeight(for: message, at: indexPath, in: collectionView)
        if let text = messagesLayout.messagesDataSource.cellTopLabelAttributedText(for: message, at: indexPath) {
            height += 24
            let width = labelSize(for: text, considering: messagesLayout.itemWidth).width
            return CGSize(width: width, height: height)
        }
        
        return CGSize(width: messagesLayout.itemWidth, height: height)
    }

    func cellTopLabelAlignment(for message: MessageType) -> LabelAlignment {
//        let dataSource = messagesLayout.messagesDataSource
//        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return LabelAlignment(textAlignment: .center, textInsets: .zero)
    }
    
    // MARK: - Top message Label
    
    func messageTopLabelSize(for message: MessageType, at indexPath: IndexPath) -> CGSize {
        let layoutDelegate = messagesLayout.messagesLayoutDelegate
        let collectionView = messagesLayout.messagesCollectionView
        let height = layoutDelegate.messageTopLabelHeight(for: message, at: indexPath, in: collectionView)
        return CGSize(width: messagesLayout.itemWidth, height: height)
    }
    
    func messageTopLabelAlignment(for message: MessageType) -> LabelAlignment {
        let dataSource = messagesLayout.messagesDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return isFromCurrentSender ? outgoingMessageTopLabelAlignment : incomingMessageTopLabelAlignment
    }

    // MARK: - Bottom Label

    func messageBottomLabelSize(for message: MessageType, at indexPath: IndexPath) -> CGSize {
//        let layoutDelegate = messagesLayout.messagesLayoutDelegate
//        let collectionView = messagesLayout.messagesCollectionView
//        let height = layoutDelegate.messageBottomLabelHeight(for: message, at: indexPath, in: collectionView)
        let height: CGFloat = 16
        return CGSize(width: messagesLayout.itemWidth, height: height)
    }

    func messageBottomLabelAlignment(for message: MessageType) -> LabelAlignment {
        let dataSource = messagesLayout.messagesDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return isFromCurrentSender ? outgoingMessageBottomLabelAlignment : incomingMessageBottomLabelAlignment
    }
    
    func messageBottomPadding(at indexPath: IndexPath) -> CGFloat {
        return messagesLayout.messagesDataSource.messageBottomPadding(at: indexPath)
    }

    // MARK: - MessageContainer

//    func messageInlineContainerPadding(for message: MessageType) -> UIEdgeInsets {
//        return UIEdgeInsets(top: 4, bottom: 4, left: 8, right: 16)
//    }
    
    func messageContainerPadding(for message: MessageType) -> UIEdgeInsets {
        let dataSource = messagesLayout.messagesDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return isFromCurrentSender ? outgoingMessagePadding : incomingMessagePadding
    }

    func messageContainerAdditionalSizes(for message: MessageType) -> [CGSize] {
        let maxWidthInlines = messageInlineContainerMaxWidth(for: message)
        
        return message
            .forwards
            .compactMap {
                item in
                var size: CGSize = .zero
                switch item.kind {
                case .text:
                    let authorSize = labelSize(for: item.attributedAuthor,
                                               considering: maxWidthInlines)
                    size = labelSize(for: item.attributedBody,
                                     considering: maxWidthInlines)
                    
                    if size.width < (maxWidthInlines + 54) && size.height < 25  {
                        size.width += 54
                    } else {
                        size.height += 20
                    }
                    if size.width < authorSize.width + 16 {
                        size.width = authorSize.width + 16
                    }
                    size.height += 20
                case .quote:
                    let authorSize = labelSize(for: item.attributedAuthor,
                                               considering: maxWidthInlines)
                    item.attributedQuotes.forEach {
                        let quoteSize = labelSize(for: $0.body, considering: maxWidthInlines - ($0.isQuote ? 12 : 0))
//                        print(quoteSize)
                        size.height += quoteSize.height
                        size.height += 4
                        size.width = max(size.width, quoteSize.width + ($0.isQuote ? 12 : 0))
                    }
                    
                    if size.width < (maxWidthInlines + 54) && size.height < 24  {
                        size.width += 54
                    } else {
                        size.height += 20
                    }
                    if size.width < authorSize.width + 16 {
                        size.width = authorSize.width + 16
                    }
                    size.height += 20
                case .images:
                    let items = item
                        .references
                        .filter({ $0.mimeType == MimeIconTypes.image.rawValue })
                    
                    if items.count == 1 {
                        if let item = items.first,
                           let imageSize = item.sizeInPx {
                            var calculatedWidth = imageSize.width
                            var calculatedHeight = imageSize.height
                            
                            if imageSize.width > maxWidthInlines {
                                calculatedWidth = maxWidthInlines
                                calculatedHeight = maxWidthInlines * imageSize.height / imageSize.width
                                if calculatedHeight > maxWidthInlines {
                                    calculatedWidth = maxWidthInlines * calculatedWidth / calculatedHeight
                                    calculatedHeight = maxWidthInlines
                                }
                            } else if imageSize.height > maxWidthInlines {
                                calculatedHeight = maxWidthInlines
                                calculatedWidth = maxWidthInlines * imageSize.width / imageSize.height
                                if calculatedWidth > maxWidthInlines {
                                    calculatedHeight = maxWidthInlines * calculatedHeight / calculatedWidth
                                    calculatedWidth = maxWidthInlines
                                }
                            }
                            size = CGSize(width: max(120, calculatedWidth), height: max(120, calculatedHeight))
                        } else {
                            size = CGSize(width: maxWidthInlines, height: maxWidthInlines + 20)
                        }
                    } else {
                        size = CGSize(width: maxWidthInlines, height: maxWidthInlines + 20)
                    }
                
                case .videos:
                    size = CGSize(width: maxWidthInlines, height: maxWidthInlines + 20)
                case .files:
                    let count = item
                        .references
                        .filter { [.media, .voice].contains($0.kind) }
                        .count
                    size = CGSize(width: maxWidthInlines,
                                  height: MessageSizeCalculator.fileViewHeight * CGFloat(count) - 4)
                    
                    size.height += 20
                case .voice:
                    let count = item
                        .references
                        .filter { $0.kind == .voice }
                        .count
                    size = CGSize(width: maxWidthInlines,
                                  height: MessageSizeCalculator.audioViewHeight * CGFloat(count) - 4)
                    
                    size.height += 20
                }
                
                if item.subforwards.isNotEmpty {
                    size.height += 24
                    let subforwardLabelSize = labelSize(for: item.forwardedBody, considering: maxWidthInlines)
                    if size.width < subforwardLabelSize.width + 16 {
                        size.width = subforwardLabelSize.width + 16
                    }
                }
                
                size.width += inlineMessageMargin.horizontal
                size.height += inlineMessageMargin.vertical
                
                size.width += inlineMessagePadding.horizontal
                size.height += inlineMessagePadding.vertical
                
                return size
            }
    }
    
    func messageContainerSize(for message: MessageType) -> CGSize {
        // Returns .zero by default
        return .zero
    }

    func messageInlineContainerMaxWidth(for message: MessageType) -> CGFloat {
        let avatarWidth = avatarSize(for: message).width
        let insets = messageLabelInsets(for: message)
        let messageMargin = inlineMessageMargin
        let messagePadding = inlineMessagePadding //messageInlineContainerPadding(for: message)
        let width = messagesLayout.itemWidth - avatarWidth - messagePadding.horizontal - messageMargin.horizontal - insets.horizontal - 8//16
        return width > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages - avatarWidth - messagePadding.horizontal - messageMargin.horizontal - insets.horizontal - 0 : width
    }
    
    func messageContainerMaxWidth(for message: MessageType) -> CGFloat {
        let avatarWidth = avatarSize(for: message).width + 8//CGFloat(48)
        let messagePadding = messageContainerPadding(for: message)
        let width = messagesLayout.itemWidth - avatarWidth - messagePadding.horizontal - 48//16
        return width > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages : width
    }

    // MARK: - Helpers

    var messagesLayout: MessagesCollectionViewFlowLayout {
        guard let layout = layout as? MessagesCollectionViewFlowLayout else {
            fatalError("Layout object is missing or is not a MessagesCollectionViewFlowLayout")
        }
        return layout
    }

    internal func labelSize(for attributedText: NSAttributedString, considering maxWidth: CGFloat) -> CGSize {
        let constraintBox = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let rect = attributedText.boundingRect(with: constraintBox, options: [
            .usesLineFragmentOrigin,
            .usesFontLeading
        ], context: nil).integral
        if rect.width == 0 {
            return CGSize(width: 0, height: 8)
        }
        return CGSize(width: rect.size.width + 4, height: rect.size.height + 4)
    }
}
