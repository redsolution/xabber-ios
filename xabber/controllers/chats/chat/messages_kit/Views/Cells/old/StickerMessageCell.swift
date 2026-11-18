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
    let warningLabel = MessageContentCell.makeMessageWarningLabel()
    let timeMarker = TimeMarkerView()
    private enum DeliveryState {
        case idle
        case loading
        case loaded
        case failed
        case awaitingConsent
        case unavailable
    }

    internal let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear
        return view
    }()

    var thumbnailPipeline: ChatThumbnailServing = ChatMediaThumbnailPipeline.shared
    var stickerCatalogue = ChatStickerCatalogue.shared
    private lazy var showExternalImageButton = ExternalImageConsentButton(in: imageView)
    private(set) var representedStickerPrimary: String?
    private var representedMessagePrimary: String?
    private var representedAttachment: ImageAttachment?
    private var representedThumbnailRequest: ChatThumbnailRequest?
    private var representedThumbnailConsumer: ChatThumbnailConsumer?
    private var thumbnailSubscription: ChatThumbnailSubscription?
    private var deliveryState: DeliveryState = .idle
    private let visibleConsumerID = UUID()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: .privacyProxyAvailabilityDidChange, object: nil)
        guard window != nil else { return }
        center.addObserver(self, selector: #selector(proxyAvailabilityDidChange),
                           name: .privacyProxyAvailabilityDidChange, object: nil)
        retryUnavailableStickerThroughProxy()
    }

    @objc private func proxyAvailabilityDidChange(_ notification: Notification) {
        guard notification.userInfo?["owner"] as? String == stickerOwner else { return }
        retryUnavailableStickerThroughProxy()
    }

    private func retryUnavailableStickerThroughProxy() {
        guard deliveryState == .awaitingConsent || deliveryState == .failed,
              PrivacyProxyMediaRouter.shared.canResolveImagesThroughProxy(owner: stickerOwner),
              case .reachable = AccountManager.shared.find(for: stickerOwner)?.disco.privacyProxyAvailability else { return }
        cancelOffscreenWork()
        refreshStickerBinding()
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            let imageSize = attributes.imagesInlineViewSize == .zero
                ? attributes.messageContainerSize : attributes.imagesInlineViewSize
            func alignedX(for width: CGFloat) -> CGFloat {
                attributes.side == .right ? attributes.messageContainerSize.width - width : 0
            }
            imageView.frame = CGRect(x: alignedX(for: imageSize.width), y: 0,
                                     width: imageSize.width, height: imageSize.height)
            let warningSize = attributes.warningInlineViewSize
            warningLabel.frame = CGRect(x: alignedX(for: warningSize.width), y: imageView.frame.maxY,
                                         width: warningSize.width, height: warningSize.height)
            let markerSize = attributes.timeMarkerSize
            timeMarker.isHidden = markerSize == .zero
            if !timeMarker.isHidden {
                let markerFrame = CGRect(x: alignedX(for: markerSize.width),
                                         y: warningLabel.frame.maxY + attributes.timeMarkerInsets.top,
                                         width: markerSize.width, height: markerSize.height)
                timeMarker.updateImageStyle(frame: markerFrame, indicator: attributes.timeMarkerIndicator,
                                            tail: attributes.tail, cornerRadius: attributes.cornerRadius)
            }
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
        warningLabel.text = nil
        warningLabel.isHidden = true
        timeMarker.isHidden = true
    }

    func cancelOffscreenWork() {
        thumbnailSubscription?.cancel()
        thumbnailSubscription = nil
        representedThumbnailRequest = nil
        representedThumbnailConsumer = nil
        deliveryState = .idle
        showExternalImageButton.reset()
        imageView.image = nil
    }

    func resumeOnscreenWork() {
        refreshStickerBinding()
    }

    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.bubble.isHidden = true
        self.messageContainerView.addSubview(imageView)
        self.messageContainerView.addSubview(warningLabel)
        timeMarker.setupSubviews()
        timeMarker.isHidden = true
        messageContainerView.addSubview(timeMarker)
    }

    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        updateStickerContent(with: message)
    }

    override func reconfigureContent(with message: MessageType, at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView) {
        super.reconfigureContent(with: message, at: indexPath, and: messagesCollectionView)
        updateStickerContent(with: message)
    }

    override func reconfigureContent(with message: MessageType, at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView, changeMask: ChatMessageChangeMask) {
        super.reconfigureContent(with: message, at: indexPath, and: messagesCollectionView, changeMask: changeMask)
        updateStickerContent(with: message)
    }

    private func updateStickerContent(with message: MessageType) {
        warningLabel.text = message.messageWarningText
        warningLabel.isHidden = message.messageWarningText == nil
        guard case .sticker(let attachment) = message.kind else { return }
        timeMarker.configure(text: message.timeMarkerText, indicator: message.indicator, withBackplate: true)
        represent(attachment, messagePrimary: message.primary, owner: message.owner)
        refreshStickerBinding()
    }

    func bindSticker(
        _ attachment: ImageAttachment,
        messagePrimary: String,
        displaySize: CGSize,
        scale: Double,
        traitStyle: ChatThumbnailTraitStyle,
        owner: String = ""
    ) {
        represent(attachment, messagePrimary: messagePrimary, owner: owner)
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
        messagePrimary: String,
        owner: String
    ) {
        if representedStickerPrimary != attachment.primary ||
            representedMessagePrimary != messagePrimary ||
            representedAttachment?.url != attachment.url ||
            representedAttachment?.inlineThumbnail != attachment.inlineThumbnail ||
            representedAttachment?.outgoingStickerPackURL != attachment.outgoingStickerPackURL ||
            representedAttachment?.encryptedAttachment != attachment.encryptedAttachment ||
            stickerOwner != owner {
            cancelOffscreenWork()
        }
        stickerOwner = owner
        representedAttachment = attachment
        representedStickerPrimary = attachment.primary
        representedMessagePrimary = messagePrimary
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

    private var stickerOwner = ""

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
            traitStyle: traitStyle,
            encryptedAttachment: attachment.encryptedAttachment,
            owner: stickerOwner,
            installedStickerPack: stickerCatalogue.installedManifest(for: attachment, owner: stickerOwner)
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
        showExternalImageButton.reset()
        imageView.image = attachment.inlineThumbnail.flatMap { UIImage(data: $0) }
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
            case .failure(let error):
                if error == .loadFailed, self.imageView.image != nil {
                    self.deliveryState = .loaded
                } else if error == .loadFailed, PrivacyProxyMediaRouter.shared.canRequestDirectImage(
                    url, owner: request.owner, installedStickerPack: request.installedStickerPack
                ) {
                    self.deliveryState = .awaitingConsent
                    self.showExternalImageButton.isHidden = false
                    self.showExternalImageButton.onTap = { [weak self] in
                        self?.requestDirectSticker(request, consumer: consumer)
                    }
                } else {
                    self.deliveryState = error == .authenticationFailed ? .unavailable : .failed
                }
            }
        }
    }

    private func requestDirectSticker(_ request: ChatThumbnailRequest, consumer: ChatThumbnailConsumer) {
        ExternalImageConsent.present(for: request.url, owner: request.owner, from: imageView, shouldGrant: { [weak self] in
            guard let self else { return false }
            return self.representedThumbnailRequest == request &&
                self.representedThumbnailConsumer == consumer &&
                self.deliveryState == .awaitingConsent
        }) { [weak self] in
            guard let self else { return }
            self.cancelOffscreenWork()
            self.refreshStickerBinding()
        }
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        guard deliveryState == .awaitingConsent, imageView.frame.contains(touchPoint) else { return false }
        showExternalImageButton.onTap?()
        return true
    }
    
    override func layoutMessageContainerView(with attributes: MessagesCollectionViewLayoutAttributes) {
        super.layoutMessageContainerView(with: attributes)
        // The sticker, warning and time marker already exclude the outer cell margins.
        messageContainerView.frame.size = attributes.messageContainerSize
    }

    override open func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        let modifiedLocation = CGPoint(x: touchLocation.x, y: frame.height - touchLocation.y)
        var isTapHandled: Bool = false
        switch true {
        case messageContainerView.frame.contains(touchLocation):
            _ = cellContentView(canHandle: convert(touchLocation, to: messageContainerView))
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
