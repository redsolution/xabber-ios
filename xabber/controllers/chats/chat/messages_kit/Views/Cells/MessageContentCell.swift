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
import Kingfisher

/// A subclass of `MessageCollectionViewCell` used to display text, media, and location messages.
class MessageContentCell: MessageCollectionViewCell {

    let deliveryIndicatorSize: CGSize = CGSize(square: 16)
    
    private var initialFrame = CGRect()
    private var reachedReplyState: Bool = false
    
    open var avatarView = AvatarView()
    var panGesture = UIPanGestureRecognizer()

    var messageContainerView: MessageContainerView = {
        let containerView = MessageContainerView()
        containerView.setup()
        return containerView
    }()

    var cellTopLabelBackplateView: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        view.layer.cornerRadius = 12
        view.layer.masksToBounds = true
        
        return view
    }()
    
    var cellTopLabel: InsetLabel = {
        let label = InsetLabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()
    
    var messageTopLabel: InsetLabel = {
        let label = InsetLabel()
        label.numberOfLines = 0
        return label
    }()

    var messageBottomLabel: InsetLabel = {
        let label = InsetLabel()
        label.numberOfLines = 0
        return label
    }()
    
    var messageDeliveryIndicator: UIImageView = {
        let view = UIImageView()
//        view.isHidden = true
        return view
    }()
    
    let messageErrorButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 16))//24
        button.backgroundColor = .clear
        button.setImage(imageLiteral("exclamationmark.circle.fill"), for: .normal)
        button.tintColor = MDCPalette.red.tint700
        
        return button
    }()
    
    let errorButtonBackgroundView: UIView = {
        let view = UIView(frame: CGRect(square: 30))
        
        view.layer.cornerRadius = 15
        view.layer.masksToBounds = true
        view.backgroundColor = .clear
        let blurEffect = UIBlurEffect(style: UIBlurEffect.Style.regular)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.frame = view.bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(blurEffectView, at: 0)
        
        return view
    }()
    
    let backgroundContentView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        
        return view
    }()
    
    let replyIcon: UIImageView = {
        let view = UIImageView()
        view.image = imageLiteral("reply")?.withRenderingMode(.alwaysTemplate)
        view.tintColor = .white
        view.alpha = 0
        
        return view
    }()
    
    var replyIconBackground: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        view.layer.cornerRadius = 18
        view.layer.masksToBounds = true
        view.alpha = 0
        
        return view
    }()
    
    weak var delegate: MessageCellDelegate?
    
    var canPerformAction: Bool = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(onPanGesture))
        panGesture.delegate = self
        
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        setupSubviews()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupSubviews() {
        contentView.addSubview(backgroundContentView)
        
        backgroundContentView.addSubview(errorButtonBackgroundView)
        backgroundContentView.addSubview(messageErrorButton)
        backgroundContentView.addSubview(avatarView)
        contentView.addSubview(cellTopLabelBackplateView)
        contentView.addSubview(cellTopLabel)
        backgroundContentView.addSubview(messageContainerView)
        backgroundContentView.addSubview(messageTopLabel)
        backgroundContentView.addSubview(messageBottomLabel)
        backgroundContentView.addSubview(messageDeliveryIndicator)
        
        backgroundContentView.addSubview(replyIconBackground)
        backgroundContentView.addSubview(replyIcon)
        
        self.contentView.addGestureRecognizer(panGesture)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cellTopLabel.text = nil
        messageTopLabel.text = nil
        messageBottomLabel.text = nil
        canPerformAction = true
        error = false
        avatarView.isHidden = false
        self.messageErrorButton.isHidden = true
        self.errorButtonBackgroundView.isHidden = true
        avatarView.image = nil
    }
    
    var error: Bool = false
    var canPinMessages: Bool = false
    var canEditMessage: Bool = false
    var canDeleteMessage: Bool = false

    // MARK: - Configuration

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        backgroundContentView.frame = contentView.frame
        
        guard let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes else { return }
        // Call this before other laying out other subviews
//        layoutForwardBackground(with: attributes)
        layoutMessageContainerView(with: attributes)
        layoutBottomLabel(with: attributes)
        layoutCellTopLabel(with: attributes)
        layoutMessageTopLabel(with: attributes)
        layoutDeliveryIndicator(with: attributes)
        layoutAvatarView(with: attributes)
        layoutErrorButton(with: attributes)
        layoutReplyIcon()
        
        self.initialFrame = self.contentView.frame
    }

    @objc
    func onMessageErrorButtonTouchUp(_ sender: UIButton) {
        self.delegate?.didTapErrorButton(cell: self)
    }
    
    /// Used to configure the cell.
    ///
    /// - Parameters:
    ///   - message: The `MessageType` this cell displays.
    ///   - indexPath: The `IndexPath` for this cell.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this cell is contained.
    ///
    var isBurnedMessage: Bool = false
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        guard let dataSource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDataSource)
        }
        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }
        self.layer.shouldRasterize = true
        self.layer.rasterizationScale = UIScreen.main.scale
        error = message.error
        if error {
            if message.errorType == "omemo" {
                messageErrorButton.setImage(imageLiteral( "alert")?.withRenderingMode(.alwaysTemplate), for: .normal)
                messageErrorButton.tintColor = .systemRed
                messageErrorButton.backgroundColor = .clear
            } else if message.errorType == "cert_error" {
                let icon = displayDelegate.messageErrorIcon(for: message, at: indexPath, on: messagesCollectionView) ?? "exclamationmark.triangle.fill"
                messageErrorButton.setImage(imageLiteral( icon), for: .normal)
                if icon != "exclamationmark.triangle.fill" {
                    messageErrorButton.tintColor = .systemGreen
                } else {
                    messageErrorButton.tintColor = .systemRed
                }
                messageErrorButton.backgroundColor = .clear
            } else {
                messageErrorButton.setImage(imageLiteral("exclamationmark.circle.fill"), for: .normal)
                messageErrorButton.tintColor = MDCPalette.red.tint700
                messageErrorButton.backgroundColor = .clear
            }
            self.errorButtonBackgroundView.isHidden = false
            self.messageErrorButton.isHidden = false
        } else {
            if message.errorType == "omemo" {
                self.messageContainerView.alpha = 0.35
                self.errorButtonBackgroundView.isHidden = true
                self.messageErrorButton.isHidden = true
            } else if message.errorType == "cert_error" {
                self.messageContainerView.alpha = 1.0
                self.errorButtonBackgroundView.isHidden = false
                self.messageErrorButton.isHidden = false
                let icon = displayDelegate.messageErrorIcon(for: message, at: indexPath, on: messagesCollectionView) ?? "exclamationmark.triangle.fill"
                messageErrorButton.setImage(imageLiteral( icon)?.withRenderingMode(.alwaysTemplate), for: .normal)
                if icon != "exclamationmark.triangle.fill" {
                    messageErrorButton.tintColor = .systemGreen
                } else {
                    messageErrorButton.tintColor = .systemRed
                }
                messageErrorButton.backgroundColor = .clear
            } else {
                self.messageContainerView.alpha = 1.0
                self.errorButtonBackgroundView.isHidden = true
                self.messageErrorButton.isHidden = true
            }
            
        }
        
        messageErrorButton.setNeedsLayout()
        
        self.messageErrorButton.addTarget(self, action: #selector(onMessageErrorButtonTouchUp), for: .touchUpInside)
        
        canPinMessages = message.canPinMessage
        canEditMessage = message.canEditMessage
        canDeleteMessage = message.canDeleteMessage
        delegate = messagesCollectionView.messageCellDelegate

        if message.withAvatar {
            if let url = displayDelegate.urlForAvatarView(at: indexPath) {
                DefaultAvatarManager.shared.getGroupAvatar(url: url.absoluteString, userId: "", jid: message.jid, owner: message.owner, size: 32) { image in
                    if let image = image {
                        self.avatarView.image = image
                    }
//                    else {
//                        self.avatarView.setDefaultAvatar(for: username, owner: owner)
//                    }
                }
            }
        }

        self.isBurnedMessage = displayDelegate.isBurnedMessage(at: indexPath)
        let messageColor = displayDelegate.backgroundColor(for: message, at: indexPath, in: messagesCollectionView)
        let messageStyle = displayDelegate.messageStyle(for: message, at: indexPath, in: messagesCollectionView)
        let isSelected = displayDelegate.isSelected(for: message, at: indexPath, in: messagesCollectionView)

        canPerformAction = dataSource.canPerformAction()
        
        messageContainerView.bubbleImage.tintColor = messageColor
        messageContainerView.style = messageStyle
        messageContainerView.isSelected = isSelected
        
        let topCellLabelText: NSAttributedString? = dataSource.cellTopLabelAttributedText(for: message, at: indexPath)
        let topMessageLabelText = dataSource.messageTopLabelAttributedText(for: message, at: indexPath)
        let bottomText = dataSource.messageBottomLabelAttributedText(for: message, at: indexPath)

        cellTopLabel.attributedText = topCellLabelText
        messageTopLabel.attributedText = topMessageLabelText
        messageBottomLabel.attributedText = bottomText 

        self.contentView.backgroundColor = .clear
        drawDeliveryIndicator(at: indexPath, in: messagesCollectionView)
        drawSelectionMode()
    }

    open func hilghlightCell(color: UIColor, duration: TimeInterval) {
        let endColor = contentView.backgroundColor
        contentView.backgroundColor = color
        UIView.animate(withDuration: duration) {
            self.contentView.backgroundColor = endColor
        }
    }
    
    /// Handle tap gesture on contentView and its subviews.
    func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        var isTapHandled: Bool = false
        switch true {
        case messageContainerView.frame.contains(touchLocation) && !cellContentView(canHandle: convert(touchLocation, to: messageContainerView)):
            delegate?.didTapMessage(in: self)
            isTapHandled = true
        default:
            break
        }
        if self.contentView.frame.contains(touchLocation) && !isTapHandled {
            delegate?.didTap(in: self)
        }
    }
    
    func handleLongTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        if self.contentView.frame.contains(touchLocation) {
            delegate?.onLongTap(cell: self)
        }
    }
    
    @objc
    func onPanGesture() {
        if panGesture.state == .changed {
            UIView.performWithoutAnimation {
                var deltaX: CGFloat = 0
                
                let rawDelta = self.panGesture.translation(in: self.panGesture.view).x
                switch true {
                case (rawDelta < -60):
                    deltaX = -60
                case (rawDelta > 0):
                    deltaX = 0
                default:
                    deltaX = rawDelta
                }
                
                let origin = CGPoint(x: self.initialFrame.minX +
                                        deltaX,
                                     y: self.initialFrame.minY)
                self.backgroundContentView.frame = CGRect(origin: origin, size: messageContainerView.frame.size)
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
            if abs(self.backgroundContentView.frame.minX - self.initialFrame.minX) >= 45 {
                if self.reachedReplyState == false {
                    FeedbackManager.shared.generate(feedback: .success)
                    UIView.animate(withDuration: 0.3) {
                        self.replyIcon.alpha = 1
                        self.replyIconBackground.alpha = 1
                    }
                    self.reachedReplyState = true
                }
            }
        } else if panGesture.state == .ended {
            if self.reachedReplyState == true {
                self.reachedReplyState = false
                delegate?.onSwipe(cell: self)
            }
            UIView.animate(withDuration: 0.3) {
                self.backgroundContentView.frame.origin.x = self.initialFrame.minX
                self.replyIcon.alpha = 0
                self.replyIconBackground.alpha = 0
            }
        }
    }

    func setSelected(_ color: UIColor) {
        messageContainerView.isSelected = !messageContainerView.isSelected
        drawSelectionMode()
    }
    
    internal func drawSelectionMode() {
        if messageContainerView.isSelected {
            self.contentView.backgroundColor = UIColor.blue.withAlphaComponent(0.2)
        } else {
            self.contentView.backgroundColor = .clear
        }
    }
    
    func isSelected() -> Bool {
        return messageContainerView.isSelected
    }
    
    /// Handle long press gesture, return true when gestureRecognizer's touch point in `messageContainerView`'s frame
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let touchPoint = gestureRecognizer.location(in: self)
        if gestureRecognizer.isKind(of: UILongPressGestureRecognizer.self) {
            return messageContainerView.frame.contains(touchPoint)
        }
        if gestureRecognizer.isKind(of: UIPanGestureRecognizer.self) {
            return abs(panGesture.velocity(in: panGesture.view).x) > abs(panGesture.velocity(in: panGesture.view).y)
        }
        return false
    }

    /// Handle `ContentView`'s tap gesture, return false when `ContentView` doesn't needs to handle gesture
    func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return false
    }

    // MARK: - Origin Calculations

    func drawDeliveryIndicator(at indexPath: IndexPath, in messageCollectionView: MessagesCollectionView) {
        let state = messageCollectionView.messagesDisplayDelegate?.deliveryState(at: indexPath) ?? .none
        switch state {
            case .none:
                self.messageDeliveryIndicator.isHidden = true
            default:
                self.messageDeliveryIndicator.isHidden = false
                switch state {
                    case .sending, .notSended, .uploading:
                        self.messageDeliveryIndicator.image = imageLiteral("clock", dimension: 12)
                        self.messageDeliveryIndicator.tintColor = .systemBlue
                    case .sended:
                        self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark", dimension: 12)
                        self.messageDeliveryIndicator.tintColor = .systemGray
                    case .deliver:
                        self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark", dimension: 12)
                        self.messageDeliveryIndicator.tintColor = .systemGreen
                    case .read:
                        self.messageDeliveryIndicator.image = imageLiteral("xabber.checkmark.double", dimension: 12)
                        self.messageDeliveryIndicator.tintColor = .systemGreen
                    case .error:
                        error = true
                        self.messageDeliveryIndicator.image = imageLiteral("info.circle", dimension: 12)
                        self.messageDeliveryIndicator.tintColor = .systemRed
                    case .none:
                        break
                }
        }
    }
    
    func layoutDeliveryIndicator(with attributes: MessagesCollectionViewLayoutAttributes) {
        self.messageDeliveryIndicator.frame = CGRect(origin: CGPoint(x: self.messageBottomLabel.frame.maxX + 4,
                                                                     y: self.messageBottomLabel.frame.minY),
                                                     size: deliveryIndicatorSize)
    }
    
    func layoutAvatarView(with attributes: MessagesCollectionViewLayoutAttributes) {
        var origin: CGPoint = .zero

        switch attributes.avatarPosition.horizontal {
        case .cellLeading:
            origin.x = 6
        case .cellTrailing:
            origin.x = attributes.frame.width - attributes.avatarSize.width
        case .natural:
            fatalError(MessageKitError.avatarPositionUnresolved)
        }

        switch attributes.avatarPosition.vertical {
        case .messageLabelTop:
            origin.y = messageTopLabel.frame.minY
        case .messageTop: // Needs messageContainerView frame to be set
            origin.y = messageContainerView.frame.minY
        case .messageBottom: // Needs messageContainerView frame to be set
            origin.y = messageContainerView.frame.maxY - attributes.avatarSize.height
        case .messageCenter: // Needs messageContainerView frame to be set
            origin.y = messageContainerView.frame.midY - (attributes.avatarSize.height/2)
        case .cellBottom:
            origin.y = attributes.frame.height - attributes.avatarSize.height - 4
        default:
            break
        }
        
        avatarView.frame = CGRect(origin: origin, size: attributes.avatarSize)
    }

    func layoutMessageContainerView(with attributes: MessagesCollectionViewLayoutAttributes) {
        var origin: CGPoint = .zero
        origin.y = attributes.cellTopLabelSize.height + attributes.messageTopLabelSize.height + attributes.messageContainerPadding.top
        switch attributes.avatarPosition.horizontal {
        case .cellLeading:
            origin.x = attributes.avatarSize.width + attributes.messageContainerPadding.left
            
        case .cellTrailing:
            origin.x = attributes.frame.width - attributes.avatarSize.width - attributes.messageContainerSize.width - attributes.messageContainerPadding.right - 4
            
        case .natural:
            fatalError(MessageKitError.avatarPositionUnresolved)
        }
        messageContainerView.frame = CGRect(origin: origin, size: attributes.messageContainerSize)
    }

    func layoutCellTopLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        
        let size = attributes.cellTopLabelSize
        let origin = CGPoint(x: (contentView.frame.width - size.width) / 2, y: 0)
        cellTopLabel.frame = CGRect(origin: origin, size: CGSize(width: size.width, height: size.height - 4))
        cellTopLabelBackplateView.frame = CGRect(
            origin: CGPoint(x: (contentView.frame.width - size.width) / 2 - 8 , y: 0),
            size: CGSize(width: size.width + 16, height: size.height - 4)
        )
    }
    
    func layoutMessageTopLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        messageTopLabel.textAlignment = .left
        messageTopLabel.textInsets = UIEdgeInsets(left: 8)
        messageTopLabel.lineBreakMode = .byTruncatingTail
        
        let y = messageContainerView.frame.minY
        var origin = CGPoint(x: attributes.avatarSize.width, y: y + 4)
        switch attributes.avatarPosition.horizontal {
        case .cellLeading:
            origin.x += 12
        case .cellTrailing:
            origin.x = attributes.frame.width - attributes.avatarSize.width - attributes.messageContainerSize.width - attributes.messageContainerPadding.right - 4
        case .natural:
            break
        }
        messageTopLabel.frame = CGRect(origin: origin,
                                       size: CGSize(width: attributes.messageContainerSize.width - 10,
                                                    height: attributes.shouldShowTopLabel ? 20 : 0))
    }

    func layoutErrorButton(with attributes: MessagesCollectionViewLayoutAttributes) {
        switch attributes.avatarPosition.horizontal {
            case .cellLeading:
                let origin = CGPoint(
                    x: attributes.messageContainerSize.width + 16,
                    y: attributes.frame.height - 32//32
                )
                messageErrorButton.frame = CGRect(origin: origin, size: CGSize(square: 24))//24
            case .cellTrailing:
                let origin = CGPoint(
                    x: attributes.frame.width - attributes.avatarSize.width - attributes.messageContainerSize.width - attributes.messageContainerPadding.right - 24 - 16,
                    y: attributes.frame.height - 32//32
                )
                messageErrorButton.frame = CGRect(origin: origin, size: CGSize(square: 24))//20
            case .natural:
                break
        }
        
        errorButtonBackgroundView.center = messageErrorButton.center
    }
    
    func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        
        // check is our bottom label from income message
        
//        attributes.
        
        var origin: CGPoint = .zero
        origin.y = messageContainerView.frame.maxY - 20
        switch attributes.avatarPosition.horizontal {
            case .cellLeading, .natural:
                origin.x = messageContainerView.frame.width + attributes.avatarSize.width - attributes.messageBottomLabelSize.width - 4 - 20
            case .cellTrailing:
                origin.x = attributes.frame.width - attributes.messageBottomLabelSize.width - deliveryIndicatorSize.width - attributes.messageContainerPadding.right - 18 - 4 - 20
                if !attributes.showMessageStateIndicator {
                    origin.x += 18
                }
        }
        
        let size = CGSize(width: attributes.messageBottomLabelSize.width + 20, height: attributes.messageBottomLabelSize.height)
        
        messageBottomLabel.textAlignment = .right
        messageBottomLabel.frame = CGRect(origin: origin, size: size)
    }
    
    func layoutReplyIcon() {
        replyIcon.frame = CGRect(x: backgroundContentView.frame.width + 8,
                                 y: backgroundContentView.frame.midY - 10,
                                 width: 20,
                                 height: 20)
        replyIconBackground.frame = CGRect(x: backgroundContentView.frame.width,
                                           y: backgroundContentView.frame.midY - 18,
                                           width: 36,
                                           height: 36)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
//        var out: [Selector] = []
//        if !canPerformAction { return false }
//        if error {
//            out = [
//                NSSelectorFromString("retrySendingMessage:"),
//                NSSelectorFromString("copy:"),
//                NSSelectorFromString("deleteMessage:")
//                ]
//        } else {
//            out = [
//                NSSelectorFromString("replyMessage:"),
//                NSSelectorFromString("shareMessage:"),
//                NSSelectorFromString("copy:"),
//            ]
//            if canDeleteMessage {
//                out.append(NSSelectorFromString("deleteMessage:"))
//            }
//            if canEditMessage {
//                out.append(NSSelectorFromString("editMessage:"))
//            }
//            if canPinMessages {
//                out.append(NSSelectorFromString("pinMessage:"))
//            }
//        }
//        return out.contains(action)
    }
    
    
//    @objc
//    internal func editMessage(_ sender: Any) {
//        delegate?.onEdit(cell: self)
//    }
//    
//    @objc
//    internal func copyMessage(_ sender: Any) {
//        delegate?.onCopyMessage(cell: self)
//    }
//    
//    @objc
//    internal func shareMessage(_ sender: Any) {
//        delegate?.onShareMessage(cell: self)
//    }
//    
//    @objc
//    internal func replyMessage(_ sender: Any) {
//        delegate?.onReplyMessage(cell: self)
//    }
//    
//    @objc
//    internal func deleteMessage(_ sender: Any) {
//        delegate?.onDeleteMessage(cell: self)
//    }
//    
//    @objc
//    internal func pinMessage(_ sender: Any) {
//        delegate?.onPinMessage(cell: self)
//    }
//    
//    @objc
//    internal func moreAction(_ sender: Any) {
//        delegate?.onMoreAction(cell: self)
//    }
//    
//    @objc
//    internal func retrySendingMessage(_ sender: Any) {
//        delegate?.onRetrySending(cell: self)
//    }
}


extension MessageContentCell: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
//        if gestureRecognizer.isKind(of: UIPanGestureRecognizer.self) {
//            return false
//        } else {
            return false
//        }
    }
    
//    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
//        let touchPoint = gestureRecognizer.location(in: self)
//        if gestureRecognizer.isKind(of: UILongPressGestureRecognizer.self) {
//            return messageContainerView.frame.contains(touchPoint)
//        }
//        if gestureRecognizer.isKind(of: UIPanGestureRecognizer.self) {
//            return abs(panGesture.velocity(in: panGesture.view).x) > abs(panGesture.velocity(in: panGesture.view).y)
//        }
//        return false
        
//        guard gestureRecognizer.isKind(of: UILongPressGestureRecognizer.self) else {
//            return abs(panGesture.velocity(in: panGesture.view).x) > abs(panGesture.velocity(in: panGesture.view).y)
//            return false
//        }
        
//    }
}
