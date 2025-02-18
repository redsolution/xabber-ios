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
import MaterialComponents.MDCPalettes

class SystemMessageCell: MessageContentCell {
    /// The `MessageCellDelegate` for the cell.
    override weak var delegate: MessageCellDelegate? {
        didSet {
            messageLabel.delegate = delegate
        }
    }
    
    /// The label used to display the message's text.
    var messageLabel = MessageLabel()
    
    // MARK: - Methods
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            messageLabel.frame = messageContainerView.bounds
            messageLabel.layer.cornerRadius = messageContainerView.bounds.height / 2//18
            messageLabel.layer.masksToBounds = true
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(messageLabel)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        
//        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
//            fatalError(MessageKitError.nilMessagesDisplayDelegate)
//        }
        
//        messageLabel.backgroundColor = .red
        messageContainerView.bubbleImage.isHidden = true
        messageContainerView.shadowImage.isHidden = true
        
        
//        messageLabel.backgroundColor = displayDelegate.accountPalette().tint100.withAlphaComponent(0.45)// MDCPalette.grey.tint800.withAlphaComponent(0.45)
        messageLabel.textColor = .white
        messageLabel.isHidden = false
        self.backgroundColor = .clear
        messageLabel.configure {
            switch message.kind {
                case .system(let text):
                    messageLabel.attributedText = text
                    messageLabel.backgroundColor = .clear
                case .date(let text):
                    messageLabel.attributedText = text
                    messageLabel.isHidden = false
                    self.backgroundColor = .clear
                    messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.2)
                case .unread(let text):
                    messageLabel.attributedText = text
                    messageLabel.backgroundColor = .clear
                    self.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            default:
                break
            }
            messageLabel.textAlignment = .center
        }
    }
    
    override func layoutAvatarView(with attributes: MessagesCollectionViewLayoutAttributes) {
        self.avatarView.frame = .zero
    }
    
    override func layoutMessageContainerView(with attributes: MessagesCollectionViewLayoutAttributes) {
        var origin: CGPoint = .zero
        origin.y = attributes.cellTopLabelSize.height + attributes.messageTopLabelSize.height + attributes.messageContainerPadding.top
        origin.x = (attributes.frame.width - attributes.messageContainerSize.width) / 2
        messageContainerView.frame = CGRect(origin: origin, size: attributes.messageContainerSize)
    }
    override func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        messageBottomLabel.frame = .zero
    }
    
    override func layoutMessageTopLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        messageTopLabel.frame = .zero
    }
    
    /// Used to handle the cell's contentView's tap gesture.
    /// Return false when the contentView does not need to handle the gesture.
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return messageLabel.handleGesture(touchPoint)
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        var out: [Selector] = []
        if !canPerformAction { return false }
        out = [
            NSSelectorFromString("copy:"),
        ]
        return out.contains(action)
    }
    
    override func panGestureObserver() {
        return
    }
}
