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
    let warningLabel = MessageContentCell.makeMessageWarningLabel()
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
        updateBubbleVisibility()
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            
            messageLabel.textInsets = attributes.messageLabelInsets
            messageLabel.frame = CGRect(origin: .zero, size: attributes.textInlineViewSize)
            if attributes.warningInlineViewSize == .zero {
                messageLabel.center = messageContainerView.center
            } else {
                messageLabel.center = CGPoint(x: messageContainerView.bounds.midX,
                    y: attributes.textInlineViewSize.height / 2)
            }
            warningLabel.frame = CGRect(
                origin: CGPoint(x: (messageContainerView.bounds.width - attributes.warningInlineViewSize.width) / 2,
                    y: attributes.textInlineViewSize.height),
                size: attributes.warningInlineViewSize)
            messageLabel.layer.cornerRadius = attributes.textInlineViewSize.height / 2//18
            messageLabel.layer.masksToBounds = true
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
        messageLabel.backgroundColor = .clear
        warningLabel.text = nil
        warningLabel.isHidden = true
        backgroundColor = .clear
        updateBubbleVisibility()
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(warningLabel)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        updateBubbleVisibility()
        updateWarning(with: message)
        
//        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
//            fatalError(MessageKitError.nilMessagesDisplayDelegate)
//        }
        
//        messageLabel.backgroundColor = .red
//        messageContainerView.bubbleImage.isHidden = true
//        messageContainerView.shadowImage.isHidden = true
        
        
//        messageLabel.backgroundColor = displayDelegate.accountPalette().tint100.withAlphaComponent(0.45)// MDCPalette.grey.tint800.withAlphaComponent(0.45)
        messageLabel.textColor = .white
        messageLabel.isHidden = false
        self.backgroundColor = .clear
        messageLabel.configure {
            switch message.kind {
                case .call(let call):
                    if call.incoming {
                        if call.missed {
                            messageLabel.attributedText = NSAttributedString(string: L10n.text("chat_message_missed_call", fallback: "Missed call"), attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1),
                                .foregroundColor: UIColor.white,
                            ])
                        } else {
                            messageLabel.attributedText = NSAttributedString(string: L10n.text("chat_message_incoming", fallback: "Incoming call"), attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1),
                                .foregroundColor: UIColor.white,
                            ])
                        }
                    } else {
                        if call.missed {
                            messageLabel.attributedText = NSAttributedString(string: L10n.text("chat_message_outgoing", fallback: "Outgoing call"), attributes: [
                                                                .font: UIFont.preferredFont(forTextStyle: .caption1),
                                                                .foregroundColor: UIColor.white,
                                                            ])
                        } else {
                            messageLabel.attributedText = NSAttributedString(string: L10n.text("chat_message_outgoing", fallback: "Outgoing call"), attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1),
                                .foregroundColor: UIColor.white,
                            ])
                        }
                    }
                    messageLabel.backgroundColor = .clear
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

    override func reconfigureContent(with message: MessageType, at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView) {
        super.reconfigureContent(with: message, at: indexPath, and: messagesCollectionView)
        updateWarning(with: message)
    }

    override func reconfigureContent(with message: MessageType, at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView, changeMask: ChatMessageChangeMask) {
        super.reconfigureContent(with: message, at: indexPath, and: messagesCollectionView, changeMask: changeMask)
        updateWarning(with: message)
    }

    private func updateWarning(with message: MessageType) {
        if case .system = message.kind { warningLabel.text = message.messageWarningText }
        else { warningLabel.text = nil }
        warningLabel.isHidden = warningLabel.text == nil
    }
    
    override func layoutAvatarView(with attributes: MessagesCollectionViewLayoutAttributes) {
        self.avatarView.frame = .zero
    }
    
    override func layoutMessageContainerView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let origin: CGPoint = .zero
//        origin.y = attributes.messageContainerPadding.top
//        origin.x = (attributes.frame.width - attributes.messageContainerSize.width) / 2
//        origin.x = attributes.frame.midX - attributes.textInlineViewSize.width / 2
        messageContainerView.frame = CGRect(origin: origin, size: attributes.messageContainerSize)
        updateBubbleVisibility()
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
        let labelPoint = messageContainerView.convert(touchPoint, to: messageLabel)
        return messageLabel.handleGesture(labelPoint)
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

    private func updateBubbleVisibility() {
        messageContainerView.bubble.isHidden = true
        messageContainerView.bubble.layer.mask = nil
        messageContainerView.bubble.layer.backgroundColor = UIColor.clear.cgColor
        messageContainerView.bubble.backgroundColor = .clear
        messageContainerView.backgroundColor = .clear
        containerView.isHidden = true
        containerView.backgroundColor = .clear
    }
}
