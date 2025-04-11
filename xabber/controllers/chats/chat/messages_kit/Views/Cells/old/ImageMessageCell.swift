////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import MaterialComponents.MDCPalettes
//
//class ImageMessageCell: CommonMessageCell {
//    var mediaView: InlineImagesGridView = {
//        let view = InlineImagesGridView()
//        
//        return view
//    }()
//    
//    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
//        super.apply(layoutAttributes)
//        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
//            let insets = attributes.messageLabelInsets
//            mediaView.frame = CGRect(
//                x: messageContainerView.bounds.minX + insets.left + 4,//2,
//                y: messageContainerView.bounds.minY + attributes.inlineForwardsOffset + insets.top + 4,//2,
//                width: messageContainerView.bounds.width - insets.horizontal - 8,//4,
//                height: messageContainerView.bounds.height - attributes.inlineForwardsOffset - insets.vertical - 8//4
//            )
//            mediaView.layer.cornerRadius = 4
//            mediaView.layer.masksToBounds = true
//        }
//    }
//    
//    override func setupSubviews() {
//        super.setupSubviews()
//        messageContainerView.addSubview(mediaView)
//    }
//    
//    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
//        super.configure(with: message, at: indexPath, and: messagesCollectionView)
//
//        guard let datasource = messagesCollectionView.messagesDataSource else {
//            fatalError(MessageKitError.nilMessagesDisplayDelegate)
//        }
//        
//        switch message.kind {
//        case .photos(let images):
//            mediaView.datasource = datasource
//            mediaView.configure(images, messageId: nil, indexPath: indexPath)
//        default: break
//        }
//        if let text = messageBottomLabel.attributedText {
//            let dateLabelText = NSMutableAttributedString(attributedString: text)
//            dateLabelText.mutableString.insert(" ", at: 0)
//            messageBottomLabel.attributedText = dateLabelText
//        }
//        
////        messageBottomLabel.attributedText
//    }
//    
//    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
//        var handleTouch: Bool = false
//        if mediaView.frame.contains(touchPoint) {
//            let convertedPoint = CGPoint(x: touchPoint.x, y: touchPoint.y - mediaView.frame.minY)
//            mediaView.handleTouch(at: convertedPoint) { (messageId, index, isSubforward) in
//                self.delegate?.onTapAttachment(cell: self, inlineItem: false, messageId: messageId, index: index, isSubforward: isSubforward)
//                handleTouch = true
//            }
//        }
//        
//        return handleTouch
//    }
//    
//    override func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
//        
//        // check is our bottom label from income message
//        
//        var origin: CGPoint = .zero
//        origin.y = messageContainerView.frame.maxY - 22
//        switch attributes.avatarPosition.horizontal {
//        case .cellLeading, .natural:
//            origin.x = messageContainerView.frame.width + attributes.avatarSize.width - attributes.messageBottomLabelSize.width - 2
//            messageBottomLabel.textAlignment = .center
//            var size = attributes.messageBottomLabelSize
////            size.width += 5
//            messageBottomLabel.frame = CGRect(origin: origin, size: size)
//            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 4)
//        case .cellTrailing:
//            origin.x = attributes.frame.width - attributes.messageBottomLabelSize.width - deliveryIndicatorSize.width - attributes.messageContainerPadding.right - 22
//            messageBottomLabel.textAlignment = .left
//            var size = attributes.messageBottomLabelSize
//            if !attributes.showMessageStateIndicator {
//                origin.x += 18
//                size.width -= 18
//            }
//            messageBottomLabel.frame = CGRect(origin: origin, size: CGSize(width: size.width + 18 + 2,
//                                                                           height: size.height))
//            
//            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 0)
//        }
//        
//        messageBottomLabel.textColor = UIColor.white
//        messageBottomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.25)
//        messageBottomLabel.layer.cornerRadius = 1
//        messageBottomLabel.layer.masksToBounds = true
//    }
//    
//    override func layoutDeliveryIndicator(with attributes: MessagesCollectionViewLayoutAttributes) {
//        self.messageDeliveryIndicator.frame = CGRect(origin: CGPoint(x: self.messageBottomLabel.frame.maxX - 20,
//                                                                     y: self.messageBottomLabel.frame.minY),
//                                                     size: deliveryIndicatorSize)
//    }
//    
//    override func drawDeliveryIndicator(at indexPath: IndexPath, in messageCollectionView: MessagesCollectionView) {
//        let state = messageCollectionView.messagesDisplayDelegate?.deliveryState(at: indexPath) ?? .none
//        switch state {
//            case .none:
//                self.messageDeliveryIndicator.isHidden = true
//                return
//            default:
//                self.messageDeliveryIndicator.isHidden = false
//                switch state {
//                    case .sending, .notSended, .uploading:
//                        self.messageDeliveryIndicator.image = imageLiteral("clock")
//                        self.messageDeliveryIndicator.tintColor = .systemBlue
//                    case .sended:
//                        self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark")
//                        self.messageDeliveryIndicator.tintColor = .systemGray
//                    case .deliver:
//                        self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark")
//                        self.messageDeliveryIndicator.tintColor = .systemGreen
//                    case .read:
//                        self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark.double")
//                        self.messageDeliveryIndicator.tintColor = .systemGreen
//                    case .error:
//                        error = true
//                        self.messageDeliveryIndicator.image = imageLiteral("info.circle")
//                        self.messageDeliveryIndicator.tintColor = .systemRed
//                    case .none:
//                        break
//                }
//        }
//        
//    }
//    
//}
