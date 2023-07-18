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

class VoIPCallMessageCell: CommonMessageCell {
    
    var mediaView: InlineCallGridView = {
        let view = InlineCallGridView()
        
        return view
    }()
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            let insets = attributes.messageLabelInsets
            mediaView.frame = CGRect(
                x: messageContainerView.bounds.minX + insets.left + 4,
                y: messageContainerView.bounds.minY + 2,// + attributes.inlineForwardsOffset,
                width: messageContainerView.bounds.width - insets.horizontal - 4,
                height: messageContainerView.bounds.height - 4// - attributes.inlineForwardsOffset - insets.vertical
            )
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(mediaView)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)

        guard let datasource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }
        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }
        let accountColor = displayDelegate.accountPalette().tint500
        switch message.kind {
        case .call(let calls):
            mediaView.datasource = datasource
            mediaView.tintViewColor = accountColor
            mediaView.configure(
                calls,
                messageId: message.messageId,
                indexPath: indexPath
            )
        default: break
        }
        
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        var handleTouch: Bool = false
        if mediaView.frame.contains(touchPoint) {
            let convertedPoint = CGPoint(x: touchPoint.x, y: touchPoint.y - mediaView.frame.minY)
            mediaView.handleTouch(at: convertedPoint) { (messageId, index, isSubforward) in
                self.delegate?.onTapVoiceCall(cell: self)
                handleTouch = true
            }
        }
        
        return handleTouch
    }
    
    override func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        messageBottomLabel.frame = .zero
    }
}
