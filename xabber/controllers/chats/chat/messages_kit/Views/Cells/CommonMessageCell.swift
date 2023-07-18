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

class CommonMessageCell: MessageContentCell {

//    var leftInlineOffset1: CGFloat = 0
    
    var inlineMessagesStack: UIView = {
        let view = UIView()

        return view
    }()
    
    var subforwards: [InlineMessageView] = []
    var needRedrawSubforward: Bool = true


    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            let insets = attributes.messageLabelInsets
            inlineMessagesStack.frame = CGRect(x: messageContainerView.bounds.minX + insets.left,
                                               y: messageContainerView.bounds.minY,
                                               width: messageContainerView.bounds.width - insets.horizontal,
                                               height: attributes.inlineForwardsOffset)
            if needRedrawSubforward {
                layoutInlines(with: attributes)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        needRedrawSubforward = true
    }

    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(inlineMessagesStack)
    }

    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        needRedrawSubforward = false
        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate,
            let datasource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }

        let accountColor = displayDelegate.inlineAccountColor()
        let accountPalette = displayDelegate.accountPalette()
        configureInlineMessages(for: message, indexPath: indexPath, accountColor: accountColor, palette: accountPalette, datasource: datasource)
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return false
    }
    
    override func layoutMessageContainerView(with attributes: MessagesCollectionViewLayoutAttributes) {
        super.layoutMessageContainerView(with: attributes)
    }
    
    func layoutInlines(with attributes: MessagesCollectionViewLayoutAttributes) {
        var offset: CGFloat = attributes.shouldShowTopLabel ? 24 : 4
        inlineMessagesStack.subviews.forEach { $0.removeFromSuperview() }
        self.subforwards.removeAll()
        attributes.inlineForwardsSizes.enumerated().forEach {
            index, item in
            let itemFrame: CGRect
            itemFrame = CGRect(origin: CGPoint(x: attributes.inlineMessageMargin.left,
                                               y: offset + attributes.inlineMessageMargin.top),
                               size: CGSize(width: item.width - attributes.inlineMessageMargin.horizontal,
                                            height: item.height - attributes.inlineMessageMargin.vertical))
            offset += item.height
            let view = InlineMessageView(frame: itemFrame, for: index)
            inlineMessagesStack.addSubview(view)
            subforwards.append(view)
        }
    }
    
    
    
    func configureInlineMessages(for message: MessageType, indexPath: IndexPath, accountColor: UIColor, palette: MDCPalette, datasource: MessagesDataSource) {
        for item in inlineMessagesStack.subviews {
            guard let view = item as? InlineMessageView,
                view.index < message.forwards.count else {
                    continue
            }
            view.datasource = datasource
            view.update(message, indexPath: indexPath, with: message.forwards[view.index], accountColor: accountColor, palette: palette)
        }
    }

    override open func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        let modifiedLocation = CGPoint(x: touchLocation.x, y: frame.height - touchLocation.y)
        var isTapHandled: Bool = false
        switch true {
        case messageContainerView.frame.contains(touchLocation) && !cellContentView(canHandle: convert(touchLocation, to: messageContainerView)):
            let viewPoint = convert(touchLocation, to: messageContainerView)
            if contentView.frame.contains(viewPoint) {
                for item in subforwards {
                    if item.frame.contains(viewPoint) {
                        let convertedPoint = CGPoint(x: viewPoint.x, y: viewPoint.y - item.frame.minY)
                        item.handleTouch(at: convertedPoint) { (messageId, index, isSubforward) in
                            self.delegate?.onTapAttachment(cell: self, inlineItem: true, messageId: messageId, index: index, isSubforward: isSubforward)
                        }
                    }
                }
            }
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
    
    func updateAudio(next state: InlineAudioGridView.AudioCellPlayingState, messageId: String?) {
        guard let messageId = messageId,
            let subforwardIndex = subforwards.firstIndex(where: { $0.messageId == messageId }) else {
            return
        }
        subforwards[subforwardIndex].update(state: state)
    }
    
    func updateDurationLabel(with text: String?, messageId: String?) {
        guard let messageId = messageId,
            let subforwardIndex = subforwards.firstIndex(where: { $0.messageId == messageId }) else {
            return
        }
        subforwards[subforwardIndex].update(durationLabel: text)
    }
}
