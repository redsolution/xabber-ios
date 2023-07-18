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

class ImageMessageCell: CommonMessageCell {
    var mediaView: InlineImagesGridView = {
        let view = InlineImagesGridView()
        
        return view
    }()
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            let insets = attributes.messageLabelInsets
            mediaView.frame = CGRect(
                x: messageContainerView.bounds.minX + insets.left + 0,//2,
                y: messageContainerView.bounds.minY + attributes.inlineForwardsOffset + insets.top + 0,//2,
                width: messageContainerView.bounds.width - insets.horizontal - 0,//4,
                height: messageContainerView.bounds.height - attributes.inlineForwardsOffset - insets.vertical - 0//4
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
        
        switch message.kind {
        case .photos(let images):
            mediaView.datasource = datasource
            mediaView.configure(images, messageId: nil, indexPath: indexPath)
        default: break
        }
        if let text = messageBottomLabel.attributedText {
            let dateLabelText = NSMutableAttributedString(attributedString: text)
            dateLabelText.mutableString.insert(" ", at: 0)
            messageBottomLabel.attributedText = dateLabelText
        }
        
//        messageBottomLabel.attributedText
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
    
    override func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        
        // check is our bottom label from income message
        
        var origin: CGPoint = .zero
        origin.y = messageContainerView.frame.maxY - 18
        switch attributes.avatarPosition.horizontal {
        case .cellLeading, .natural:
            origin.x = messageContainerView.frame.width + attributes.avatarSize.width - attributes.messageBottomLabelSize.width - 2
            messageBottomLabel.textAlignment = .right
            var size = attributes.messageBottomLabelSize
            size.width += 5
            messageBottomLabel.frame = CGRect(origin: origin, size: size)
            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 4)
        case .cellTrailing:
            origin.x = attributes.frame.width - attributes.messageBottomLabelSize.width - deliveryIndicatorSize.width - attributes.messageContainerPadding.right - 16 - 4 - 2
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
        
        messageBottomLabel.textColor = MDCPalette.grey.tint50
        messageBottomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
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
            self.messageDeliveryIndicator.tintColor = MDCPalette.lightBlue.tint400
        case .sended:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "check").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.grey.tint50
        case .deliver:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "check").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.lightGreen.tint400
        case .read:
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "check-all").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.lightGreen.tint400
        case .error:
            error = true
            self.messageDeliveryIndicator.image = #imageLiteral(resourceName: "alert-circle-outline").withRenderingMode(UIImage.RenderingMode.alwaysTemplate)
            self.messageDeliveryIndicator.tintColor = MDCPalette.red.tint400
        case .none: break
        }
    }
    
}
