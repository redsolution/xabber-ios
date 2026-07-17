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

class StickerMessageCell: MessageContentCell, ChatOffscreenWorkManaging {
    private enum DeliveryState {
        case idle
        case loading
        case loaded
        case failed
    }

    internal let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = ChatStickerPlaceholder.color
        return view
    }()

    var thumbnailPipeline: ChatThumbnailServing = ChatMediaThumbnailPipeline.shared
    private(set) var representedStickerPrimary: String?
    private var representedMessagePrimary: String?
    private var representedAttachment: ImageAttachment?
    private var representedThumbnailRequest: ChatThumbnailRequest?
    private var representedThumbnailConsumer: ChatThumbnailConsumer?
    private var thumbnailSubscription: ChatThumbnailSubscription?
    private var deliveryState: DeliveryState = .idle
    private let visibleConsumerID = UUID()

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            imageView.frame = CGRect(origin: .zero, size: attributes.messageContainerSize)
            refreshStickerBinding()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelOffscreenWork()
        representedStickerPrimary = nil
        representedMessagePrimary = nil
        representedAttachment = nil
        representedThumbnailRequest = nil
        representedThumbnailConsumer = nil
        deliveryState = .idle
        imageView.image = nil
        imageView.backgroundColor = ChatStickerPlaceholder.color
    }

    func cancelOffscreenWork() {
        thumbnailSubscription?.cancel()
        thumbnailSubscription = nil
        representedThumbnailRequest = nil
        representedThumbnailConsumer = nil
        deliveryState = .idle
        imageView.image = nil
        imageView.backgroundColor = ChatStickerPlaceholder.color
    }

    func resumeOnscreenWork() {
        refreshStickerBinding()
    }

    override func setupSubviews() {
        super.setupSubviews()
        self.messageContainerView.addSubview(imageView)
    }

    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        switch message.kind {
        case .sticker(let attachment):
            represent(attachment, messagePrimary: message.primary)
            refreshStickerBinding()
        default: break
        }
    }

    func bindSticker(
        _ attachment: ImageAttachment,
        messagePrimary: String,
        displaySize: CGSize,
        scale: Double,
        traitStyle: ChatThumbnailTraitStyle
    ) {
        represent(attachment, messagePrimary: messagePrimary)
        imageView.frame = CGRect(origin: .zero, size: displaySize)
        acquireSticker(
            attachment,
            messagePrimary: messagePrimary,
            displaySize: displaySize,
            scale: scale,
            traitStyle: traitStyle
        )
    }

    private func represent(
        _ attachment: ImageAttachment,
        messagePrimary: String
    ) {
        if representedStickerPrimary != attachment.primary ||
            representedMessagePrimary != messagePrimary {
            cancelOffscreenWork()
        }
        representedAttachment = attachment
        representedStickerPrimary = attachment.primary
        representedMessagePrimary = messagePrimary
        imageView.image = nil
        imageView.backgroundColor = ChatStickerPlaceholder.color
    }

    private func refreshStickerBinding() {
        guard let attachment = representedAttachment,
              let messagePrimary = representedMessagePrimary,
              imageView.bounds.width > 0,
              imageView.bounds.height > 0 else {
            return
        }
        acquireSticker(
            attachment,
            messagePrimary: messagePrimary,
            displaySize: imageView.bounds.size,
            scale: Double(window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        )
    }

    private func acquireSticker(
        _ attachment: ImageAttachment,
        messagePrimary: String,
        displaySize: CGSize,
        scale: Double,
        traitStyle: ChatThumbnailTraitStyle
    ) {
        guard let url = attachment.url,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return
        }
        let request = ChatThumbnailRequest(
            url: url,
            displaySize: ChatCollectionPrefetchSize(
                width: Double(displaySize.width),
                height: Double(displaySize.height)
            ),
            scale: scale,
            traitStyle: traitStyle
        )
        let consumer = ChatThumbnailConsumer(
            identity: ChatCollectionPrefetchIdentity(
                kind: .sticker,
                messagePrimary: messagePrimary,
                referencePrimary: attachment.primary
            ),
            role: .visible(visibleConsumerID)
        )
        if representedThumbnailRequest == request,
           representedThumbnailConsumer == consumer,
           deliveryState != .failed {
            return
        }

        thumbnailSubscription?.cancel()
        representedThumbnailRequest = request
        representedThumbnailConsumer = consumer
        deliveryState = .loading
        imageView.image = nil
        imageView.backgroundColor = ChatStickerPlaceholder.color
        thumbnailSubscription = thumbnailPipeline.acquire(
            request,
            consumer: consumer
        ) { [weak self] result in
            guard let self,
                  self.representedThumbnailRequest == request,
                  self.representedThumbnailConsumer == consumer else {
                return
            }
            switch result {
            case .success(let delivery):
                self.deliveryState = .loaded
                self.imageView.image = delivery.image
                self.imageView.backgroundColor = .clear
            case .failure:
                self.deliveryState = .failed
                self.imageView.image = nil
                self.imageView.backgroundColor = ChatStickerPlaceholder.color
            }
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
        
//        var origin: CGPoint = .zero
//        origin.y = messageContainerView.frame.maxY - 18
//        switch attributes.avatarPosition.horizontal {
//        case .cellLeading, .natural:
//            origin.x = messageContainerView.frame.width + attributes.avatarSize.width - attributes.messageBottomLabelSize.width - 4
//            messageBottomLabel.textAlignment = .right
//            messageBottomLabel.frame = CGRect(origin: origin, size: attributes.messageBottomLabelSize)
//            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 4)
//        case .cellTrailing:
//            origin.x = attributes.frame.width - attributes.messageBottomLabelSize.width - deliveryIndicatorSize.width - attributes.messageContainerPadding.right - 16 - 4
//            messageBottomLabel.textAlignment = .left
//            var size = attributes.messageBottomLabelSize
//            if !attributes.showMessageStateIndicator {
//                origin.x += 18
//                size.width -= 18
//            }
//            messageBottomLabel.frame = CGRect(origin: origin, size: CGSize(width: size.width + 18 + 6,
//                                                                           height: size.height))
//            messageBottomLabel.textInsets = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 0)
//        }
//        
//        
//        messageBottomLabel.textColor = .white//MDCPalette.grey.tint50
//        messageBottomLabel.backgroundColor = MDCPalette.grey.tint600.withAlphaComponent(0.3)
//        messageBottomLabel.layer.cornerRadius = 2
//        messageBottomLabel.layer.masksToBounds = true
    }
    
    override func layoutDeliveryIndicator(with attributes: MessagesCollectionViewLayoutAttributes) {
        self.messageDeliveryIndicator.frame = CGRect(origin: CGPoint(x: self.messageBottomLabel.frame.maxX - 20,
                                                                     y: self.messageBottomLabel.frame.minY),
                                                     size: deliveryIndicatorSize)
    }
    
//    override func drawDeliveryIndicator(at indexPath: IndexPath, in messageCollectionView: MessagesCollectionView) {
//        let state = messageCollectionView.messagesDisplayDelegate?.deliveryState(at: indexPath) ?? .none
//        switch state {
//        case .none:
//            self.messageDeliveryIndicator.isHidden = true
//            return
//        default: self.messageDeliveryIndicator.isHidden = false
//        }
//        switch state {
//            case .sending, .notSended, .uploading:
//                self.messageDeliveryIndicator.image = imageLiteral( "clock")
//                self.messageDeliveryIndicator.tintColor = .systemBlue
//            case .sended:
//                self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark")
//                self.messageDeliveryIndicator.tintColor = .systemGray
//            case .deliver:
//                self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark")
//                self.messageDeliveryIndicator.tintColor = .systemGreen
//            case .read:
//                self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark.double")
//                self.messageDeliveryIndicator.tintColor = .systemGreen
//            case .error:
//                error = true
//                self.messageDeliveryIndicator.image = imageLiteral("info.circle")
//                self.messageDeliveryIndicator.tintColor = .systemRed
//            case .none:
//                break
//        }
//    }
    
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
