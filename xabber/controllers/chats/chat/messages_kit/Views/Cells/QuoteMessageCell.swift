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
import MaterialComponents.MDCPalettes

class QuoteMessageCell: CommonMessageCell {
    
    var mediaView: InlineQuoteGridView = {
        let view = InlineQuoteGridView()
        
        return view
    }()
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            let insets = attributes.messageLabelInsets
            mediaView.frame = CGRect(x: messageContainerView.bounds.minX + insets.left + 8,
                                     y: messageContainerView.bounds.minY + attributes.inlineForwardsOffset + insets.top,
                                     width: messageContainerView.bounds.width - 16 - insets.horizontal,
                                     height: messageContainerView.bounds.height - attributes.inlineForwardsOffset - insets.vertical)
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(mediaView)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)

        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate,
            let datasource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }
        let accountColor = displayDelegate.accountPalette()
        switch message.kind {
        case .quote(let quotes, let author):
            mediaView.datasource = datasource
            mediaView.configure(quotes, messageId: message.messageId, indexPath: indexPath, color: accountColor.tint400)
        default: break
        }
        
    }
    
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        var handleTouch: Bool = false
        if mediaView.frame.contains(touchPoint) {
            let convertedPoint = CGPoint(x: touchPoint.x, y: touchPoint.y - mediaView.frame.minY)
            mediaView.handleTouch(at: convertedPoint) { (messageId, index, isSubforward) in
                self.delegate?.onTapAttachment(cell: self, inlineItem: false, messageId: messageId, index: index, isSubforward: isSubforward)
                handleTouch = true
            }
        }
        
        return handleTouch
    }
}
