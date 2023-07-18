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

class QuoteMessageSizeCalculator: MessageSizeCalculator {

    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body).withSize(16)
    public var commentAdditionalInset: CGFloat = 0
    
    override func messageContainerMaxWidth(for message: MessageType) -> CGFloat {
        let maxWidth = super.messageContainerMaxWidth(for: message)
        let textInsets = messageLabelInsets(for: message)
        return maxWidth - textInsets.horizontal
    }
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        var messageContainerSize: CGSize = .zero
        let maxWidth = messageContainerMaxWidth(for: message)
        if !isConfigured {
            inlineForwardsSizes = messageContainerAdditionalSizes(for: message)
        }
        var inlineMessageContainers = inlineForwardsSizes
        var bodyContainer: CGSize = .zero
        let lastLineWidth: CGFloat
        switch message.kind {
        case .quote(let quotes, let author):
            quotes.forEach {
                item in
                let textSize = labelSize(for: item.body, considering: maxWidth - (item.isQuote ? 12 : 0))
                bodyContainer.height += textSize.height
                bodyContainer.height += 4
                bodyContainer.width = max(textSize.width + (item.isQuote ? 12 : 0), bodyContainer.width)
            }
            if message.withAuthor {
                let authorSize = labelSize(for: author, considering: maxWidth)
                if bodyContainer.width < authorSize.width {
                    bodyContainer.width = authorSize.width
                }
            }
            if let text = quotes.last?.body {
                lastLineWidth = UILabel.lastLineWidth(text: text, width: bodyContainer.width)
            } else {
                lastLineWidth = bodyContainer.width
            }
            let labelInsets = messageLabelInsets(for: message)
            bodyContainer.width += labelInsets.horizontal
            bodyContainer.width += 16
        default:
            fatalError("messageContainerSize text received unhandled MessageDataType: \(message.kind)")
        }
        inlineMessageContainers.append(bodyContainer)
        let messageInsets = messageLabelInsets(for: message)
        messageContainerSize = CGSize(width: inlineMessageContainers.compactMap { return $0.width }.max() ?? maxWidth,
                                      height: inlineMessageContainers.compactMap { return $0.height }.reduce(0,+))

        let dateWidth: CGFloat = message.isEdited ? 112 : 72
        let lastLineDelta = messageContainerSize.width - lastLineWidth
        if lastLineDelta < dateWidth {
            if bodyContainer.height < 24 && messageContainerSize.width + dateWidth < maxWidth {
                messageContainerSize.width = lastLineWidth + dateWidth
                messageContainerSize.height += messageInsets.top + 6
            } else {
                messageContainerSize.height += messageInsets.vertical
            }
            
        } else {
            messageContainerSize.height += messageInsets.top + 6
        }
        if messageContainerSize.width < dateWidth {
            messageContainerSize.width = dateWidth
        }
        
        messageContainerSize.width += messageInsets.horizontal
        
        if message.withAuthor {
            messageContainerSize.height += 22
        }
        return messageContainerSize
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? MessagesCollectionViewLayoutAttributes else { return }

        let dataSource = messagesLayout.messagesDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)

        attributes.messageLabelInsets = messageLabelInsets(for: message)
        attributes.messageLabelFont = messageLabelFont

        switch message.kind {
        case .quote(_,_):
            attributes.messageLabelFont = UIFont.preferredFont(forTextStyle: .body)
        default:
            break
        }
    }
}

