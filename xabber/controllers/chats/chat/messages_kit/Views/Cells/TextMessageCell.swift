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

import UIKit
import MaterialComponents.MDCPalettes

public class TextMessageCell: MessageContentCell {
    
    let offsetBetweenForwards: CGFloat = 2
    
    let timeMarker: TimeMarkerView = {
        let marker = TimeMarkerView(frame: .zero)
        
        marker.setupSubviews()
        
        return marker
    }()
    
    let authorView: MessageLabel = {
        let view = MessageLabel()
        
        return view
    }()
    
    var forwardsContainer: InlineForwardsContainerView = {
        let view = InlineForwardsContainerView(frame: .zero)
//        view.backgroundColor = .orange
        return view
    }()
    
    var filesView: InlineFilesGridView = {
        let view = InlineFilesGridView()
                
//        view.backgroundColor = .brown
        
        return view
    }()
    
    var audiosView: InlineAudiosGridView = {
        let view = InlineAudiosGridView()
        
//        view.backgroundColor = .yellow
        
        return view
    }()
    
    var videosView: InlineVideosGridView = {
        let view = InlineVideosGridView()
                
        return view
    }()
    
    var imagesView: InlineImagesGridView = {
        let view = InlineImagesGridView()
                
        return view
    }()
    
    let labelContainer: UIView = {
        let view = UIView()
        
        return view
    }()
    
    let messageLabel: MessageLabel = {
        let label = MessageLabel()
                
        return label
    }()
    
    
        
    override weak var delegate: MessageCellDelegate? {
        didSet {
            messageLabel.delegate = delegate
        }
    }
    
    
    public override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            layoutAuthorView(with: attributes)
            layoutForwardsContainer(with: attributes)
            layoutImagesView(with: attributes)
            layoutVideosView(with: attributes)
            layoutAudiosView(with: attributes)
            layoutFilesView(with: attributes)
            layoutLabelView(with: attributes)
            layoutTimeMarker(with: attributes)
        }
        super.apply(layoutAttributes)
    }
    
    func layoutAuthorView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offset: CGFloat = 0
        self.authorView.frame = CGRect(
            origin: CGPoint(
                x: attributes.messageLabelInsets.left,
                y: offset
            ),
            size: attributes.authorInlineSize
        )
    }
    
    func layoutTimeMarker(with attributes: MessagesCollectionViewLayoutAttributes) {
        var frame = CGRect(
            origin: CGPoint(
                x: attributes.messageContainerSize.width - attributes.timeMarkerSize.width - attributes.timeMarkerInsets.right - attributes.tailWidth - attributes.messageContainerPadding.right - attributes.messageContainerMargin.right,
                y: attributes.messageContainerSize.height - attributes.timeMarkerSize.height - attributes.timeMarkerInsets.bottom - attributes.messageContainerPadding.bottom - attributes.messageContainerMargin.bottom - 2
            ),
            size: attributes.timeMarkerSize
        )
        if attributes.timeMarkerWithBackplate {
            frame = CGRect(
                origin: CGPoint(
                    x: attributes.messageContainerSize.width - attributes.timeMarkerSize.width - attributes.timeMarkerInsets.right - attributes.tailWidth - attributes.messageContainerPadding.right - attributes.messageContainerMargin.right - 3,
                    y: attributes.messageContainerSize.height - attributes.timeMarkerSize.height - attributes.timeMarkerInsets.bottom - attributes.messageContainerPadding.bottom - attributes.messageContainerMargin.bottom - 7
                ),
                size: attributes.timeMarkerSize
            )
        }
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
//                if attributes.isImageMessage {
                    //radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            default:
                break
        }
        self.timeMarker.update(frame: frame, indicator: attributes.timeMarkerIndicator, radius: radius.leftBottom)
    }
    
    func layoutForwardsContainer(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.forwardsContainer.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 0, y:0),
            size: attributes.forwardsContainerViewSize.padding(width: 0, height: 4)
        )
        self.forwardsContainer.layout(with: attributes)
    }
    
    func layoutImagesView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.imagesView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 2, y: 2),
            size: attributes.imagesInlineViewSize.padding(width: 4, height: 4)
        )
//        let radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: "16")
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.image.getRadiusFor(index: attributes.cornerRadius)
            default:
                break
        }
        self.imagesView.configure(
            side: .right,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
    }
    
    func layoutVideosView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.videosView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 2, y: 2),
            size: attributes.videosInlineViewSize.padding(width: 4, height: 4)
        )
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.bubble.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.bubble.getRadiusFor(index: attributes.cornerRadius)
            default:
                break
        }
        self.videosView.configure(
            side: .right,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
    }
    
    func layoutAudiosView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.audiosView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: attributes.audioInlineViewSize
        )
    }
    
    func layoutFilesView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.audioInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.filesView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: attributes.filesInlineViewSize
        )
    }
    
    func layoutLabelView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.audioInlineViewSize,
            attributes.filesInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        labelContainer.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: CGSize(
                width: attributes.textInlineViewSize.width + attributes.messageLabelInsets.horizontal,
                height: attributes.textInlineViewSize.width + attributes.messageLabelInsets.vertical
            )
        )
        messageLabel.frame = CGRect(
            origin: CGPoint(
                x: attributes.messageLabelInsets.left,
                y: attributes.messageLabelInsets.top
            ),
            size: attributes.textInlineViewSize
        )
    }
    
    public override func prepareForReuse() {
        
        super.prepareForReuse()
        
        messageLabel.attributedText = nil
        messageLabel.text = nil
//        forwardsContainer.subviews.forEach { $0.removeFromSuperview() }
//        forwardsContainer.inlineViews.removeAll()
        forwardsContainer.resetState()
        imagesView.subviews.forEach { $0.removeFromSuperview() }
        imagesView.views.removeAll()
        audiosView.subviews.forEach { $0.removeFromSuperview() }
        audiosView.views.removeAll()
        filesView.subviews.forEach { $0.removeFromSuperview() }
        filesView.views.removeAll()
        videosView.subviews.forEach { $0.removeFromSuperview() }
        videosView.views.removeAll()
        authorView.text = nil
    }
    
    
    override func setupSubviews() {
        super.setupSubviews()
        containerView.addSubview(authorView)
        containerView.addSubview(forwardsContainer)
        containerView.addSubview(imagesView)
        containerView.addSubview(videosView)
        containerView.addSubview(audiosView)
        containerView.addSubview(filesView)
        
        containerView.addSubview(labelContainer)
        containerView.addSubview(timeMarker)
        labelContainer.addSubview(messageLabel)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        messageLabel.configure {
            switch message.kind {
                case .attributedText(let text):
                    messageLabel.attributedText = text
                default:
                    break
            }
        }
        authorView.attributedText = message.attributedAuthor
        var timeMarkerWithBackplate: Bool = false
        if message.images.isNotEmpty || message.videos.isNotEmpty,
           message.files.isEmpty,
           message.audios.isEmpty {
            switch message.kind {
                case .attributedText(let text):
                    if text.string.isEmpty {
                        timeMarkerWithBackplate = true
                    }
                default:
                    break
            }
        }
        let palette = AccountColorManager.shared.palette(for: message.owner)
        self.timeMarker.configure(text: message.timeMarkerText, indicator: message.indicator, withBackplate: timeMarkerWithBackplate)
        self.imagesView.configure(message.images)
        self.filesView.configure(message.files, palette: palette)
        self.audiosView.delegate = delegate
        self.audiosView.configure(message.audios, palette: palette)
        self.forwardsContainer.configure(message.forwards, palette: palette, delegate: delegate)
        self.videosView.configure(message.videos)
        self.imagesView.layer.backgroundColor = MDCPalette.grey.tint100.cgColor
        
        
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressGesture(_:)))
//        tapGesture.require(toFail: longPressGesture)
        longPressGesture.delaysTouchesBegan = true
        self.containerView.addGestureRecognizer(longPressGesture)
        if message.withAvatar {
            if let avatarUrl = message.avatarUrl {
                let userId = message.groupchatAuthorId
                DefaultAvatarManager.shared.getGroupAvatar(url: avatarUrl, userId: userId, jid: message.jid, owner: message.owner, size: 32) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: message.groupchatAuthorNickname, owner: message.owner, size: 32)
                    }
                }
            } else {
                avatarView.isHidden = true
            }
        } else {
            avatarView.isHidden = true
        }
    }
    
    @objc
    private func handleLongPressGesture(_ sender: UILongPressGestureRecognizer) {
        print("press")
        guard sender.state == .began else { return }
        self.delegate?.onLongTapMessage(cell: self)
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        if self.filesView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.filesView.frame.minX, y: -self.filesView.frame.minY)
            if self.filesView.handleTouch(at: translatedPoint, callback: { url in
                self.delegate?.didTapOnFile(url: url)
            }) {
                return true
            }
        }
        if self.imagesView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.imagesView.frame.minX, y: -self.imagesView.frame.minY)
            if self.imagesView.handleTouch(at: translatedPoint, callback: { (urls, url) in
                self.delegate?.didTapOnPhoto(urls: urls, url: url)
            }) {
                return true
            }
        }
        if self.videosView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.videosView.frame.minX, y: -self.videosView.frame.minY)
            if self.videosView.handleTouch(at: translatedPoint, callback: { (urls, url) in
                self.delegate?.didTapOnVideo(url: url)
            }) {
                return true
            }
        }
        if self.forwardsContainer.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.forwardsContainer.frame.minX, y: -self.forwardsContainer.frame.minY)
            self.forwardsContainer.handleTouch(at: translatedPoint)
        }
        return messageLabel.handleGesture(touchPoint)
    }
    
}
