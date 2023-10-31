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
import Kingfisher
import MaterialComponents.MDCPalettes

class StickerMessageCell: MessageContentCell {
    internal var imageView: UIImageView = {
        let view = UIImageView()
        
        return view
    }()
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            let insets = attributes.messageLabelInsets
            imageView.frame = CGRect(x: messageContainerView.bounds.minX + insets.left + 2,
                                     y: messageContainerView.bounds.minY + attributes.inlineForwardsOffset + insets.top + 2,
                                     width: messageContainerView.bounds.width - insets.horizontal - 4,
                                     height: messageContainerView.bounds.height - attributes.inlineForwardsOffset - insets.vertical - 4)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }

    override func setupSubviews() {
        super.setupSubviews()
        self.messageContainerView.addSubview(imageView)
    }

    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate,
            let datasource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }
        self.messageContainerView.bubbleImage.image = nil
        self.messageContainerView.shadowImage.image = nil
        switch message.kind {
        case .sticker(let reference):
            guard let uri = reference.metadata?["uri"] as? String,
                let url = URL(string: uri) else {
                    return
            }
            imageView.kf.indicatorType = .activity
            imageView.kf.setImage(
                with: KF.ImageResource(downloadURL: url),
                placeholder: InlineGridImagePlaceholderView(frame: CGRect(origin: .zero,
                                                                          size: imageView.frame.size)),
                options: []
            )
            imageView.contentMode = .scaleAspectFill
            imageView.layer.cornerRadius = 2
            imageView.layer.masksToBounds = true
        default: break
        }
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return false
    }
    
    override func layoutMessageContainerView(with attributes: MessagesCollectionViewLayoutAttributes) {
        super.layoutMessageContainerView(with: attributes)
    }

    override open func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        let modifiedLocation = CGPoint(x: touchLocation.x, y: frame.height - touchLocation.y)
        var isTapHandled: Bool = false
        switch true {
        case messageContainerView.frame.contains(touchLocation) && !cellContentView(canHandle: convert(touchLocation, to: messageContainerView)):
            isTapHandled = true
        case messageTopLabel.frame.contains(touchLocation):
            delegate?.didTapMessageTopLabel(in: self)
            isTapHandled = true
        case messageBottomLabel.frame.contains(touchLocation):
            delegate?.didTapMessageBottomLabel(in: self)
            isTapHandled = true
        case avatarView.frame.contains(modifiedLocation):
            delegate?.didTapAvatar(in: self)
            isTapHandled = true
        default:
            break
        }
        if self.contentView.frame.contains(touchLocation) && !isTapHandled {
            delegate?.didTap(in: self)
        }
    }
    
    override func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        
        // check is our bottom label from income message
        
        var origin: CGPoint = .zero
        origin.y = messageContainerView.frame.maxY - 18
        switch attributes.avatarPosition.horizontal {
        case .cellLeading, .natural:
            origin.x = messageContainerView.frame.width + attributes.avatarSize.width - attributes.messageBottomLabelSize.width - 4
            messageBottomLabel.textAlignment = .right
            messageBottomLabel.frame = CGRect(origin: origin, size: attributes.messageBottomLabelSize)
            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 4)
        case .cellTrailing:
            origin.x = attributes.frame.width - attributes.messageBottomLabelSize.width - deliveryIndicatorSize.width - attributes.messageContainerPadding.right - 16 - 4
            messageBottomLabel.textAlignment = .left
            var size = attributes.messageBottomLabelSize
            if !attributes.showMessageStateIndicator {
                origin.x += 18
                size.width -= 18
            }
            messageBottomLabel.frame = CGRect(origin: origin, size: CGSize(width: size.width + 18 + 6,
                                                                           height: size.height))
            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 0)
        }
        
        
        messageBottomLabel.textColor = .white//MDCPalette.grey.tint50
        messageBottomLabel.backgroundColor = MDCPalette.grey.tint600.withAlphaComponent(0.3)
        messageBottomLabel.layer.cornerRadius = 2
        messageBottomLabel.layer.masksToBounds = true
    }
    
    override func layoutDeliveryIndicator(with attributes: MessagesCollectionViewLayoutAttributes) {
        self.messageDeliveryIndicator.frame = CGRect(origin: CGPoint(x: self.messageBottomLabel.frame.maxX - 20,
                                                                     y: self.messageBottomLabel.frame.minY),
                                                     size: deliveryIndicatorSize)
    }
    
    override func drawDeliveryIndicator(at indexPath: IndexPath, in messageCollectionView: MessagesCollectionView) {
        let state = messageCollectionView.messagesDisplayDelegate?.deliveryState(at: indexPath) ?? .none
        switch state {
        case .none:
            self.messageDeliveryIndicator.isHidden = true
            return
        default: self.messageDeliveryIndicator.isHidden = false
        }
        switch state {
        case .sending, .notSended, .uploading:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "clock").withRenderingMode(.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.lightBlue.tint700
        case .sended:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "check").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.grey.tint600
        case .deliver:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "check").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.lightGreen.tint700
        case .read:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "check-all").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.lightGreen.tint700
        case .error:
            error = true
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "alert-circle-outline").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.red.tint400
        case .none: break
        }
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        var out: [Selector] = []
        if !canPerformAction { return false }
        if error {
            out = [
                NSSelectorFromString("retrySendingMessage:"),
                NSSelectorFromString("copy:"),
                NSSelectorFromString("deleteMessage:")
                ]
        } else {
            out = [
                NSSelectorFromString("copy:"),
            ]
        }
        return out.contains(action)
    }
    
}
