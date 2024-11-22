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

class TextMessageCell: CommonMessageCell {
    
    var messageLabel = MessageLabel()
    
    var audiosInlineView: InlineAudioGridView = {
        let view = InlineAudioGridView()
        
        return view
    }()
    
    var filesInlineView: InlineFilesGridView = {
        let view = InlineFilesGridView()
        
        return view
    }()
    
    var imagesInlineView: InlineImagesGridView = {
        let view = InlineImagesGridView()
        
        return view
    }()
    
    var videosInlineView: InlineVideosGridView = {
        let view = InlineVideosGridView()
        
        return view
    }()
    
    override weak var delegate: MessageCellDelegate? {
        didSet {
            messageLabel.delegate = delegate
        }
    }
    
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
//            let additionalYOffset = attributes.audioInlineViewSize.height + attributes.filesInlineViewSize.height + attributes.imagesInlineViewSize.height + attributes.
            var messageLabelOffset: CGFloat = 0
            audiosInlineView.frame = CGRect(
                x: messageContainerView.bounds.minX + 8,
                y: messageContainerView.bounds.minY + messageLabelOffset,
                width: messageContainerView.bounds.width - 16,
                height: attributes.audioInlineViewSize.height
            )
            messageLabelOffset += attributes.audioInlineViewSize.height
            
            filesInlineView.frame = CGRect(
                x: messageContainerView.bounds.minX + 8,
                y: messageContainerView.bounds.minY + messageLabelOffset,
                width: messageContainerView.bounds.width - 16,
                height: attributes.filesInlineViewSize.height
            )
            messageLabelOffset += attributes.filesInlineViewSize.height
            
            imagesInlineView.frame = CGRect(
                x: messageContainerView.bounds.minX + 8,
                y: messageContainerView.bounds.minY + messageLabelOffset,
                width: messageContainerView.bounds.width - 16,
                height: attributes.imagesInlineViewSize.height
            )
            messageLabelOffset += attributes.imagesInlineViewSize.height
            
            videosInlineView.frame = CGRect(
                x: messageContainerView.bounds.minX + 8,
                y: messageContainerView.bounds.minY + messageLabelOffset,
                width: messageContainerView.bounds.width - 16,
                height: attributes.videosInlineViewSize.height
            )
            messageLabelOffset += attributes.videosInlineViewSize.height
            if messageLabelOffset > 0 {
                messageLabelOffset += 8
            }
            
            messageLabel.frame = CGRect(x: messageContainerView.bounds.minX + attributes.messageLabelInsets.left,
                                        y: messageContainerView.bounds.minY + attributes.inlineForwardsOffset + messageLabelOffset + attributes.messageLabelInsets.top,
                                        width: messageContainerView.bounds.width - attributes.messageLabelInsets.horizontal,
                                        height: messageContainerView.bounds.height - attributes.inlineForwardsOffset)
        }
    }
    
    override func prepareForReuse() {
        
        super.prepareForReuse()
        messageLabel.attributedText = nil
        messageLabel.text = nil
    }
    
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(audiosInlineView)
        messageContainerView.addSubview(filesInlineView)
        messageContainerView.addSubview(imagesInlineView)
        messageContainerView.addSubview(videosInlineView)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)

        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }

        let enabledDetectors = displayDelegate.enabledDetectors(for: message, at: indexPath, in: messagesCollectionView)
        
        self.audiosInlineView.configure(message.references, messageId: message.messageId, indexPath: indexPath)
        self.filesInlineView.configure(message.references, messageId: message.messageId, indexPath: indexPath)
        self.imagesInlineView.configure(message.references, messageId: message.messageId, indexPath: indexPath)
        self.videosInlineView.configure(message.references, messageId: message.messageId, indexPath: indexPath)
        
        
        messageLabel.configure {
            messageLabel.enabledDetectors = enabledDetectors
            for detector in enabledDetectors {
                let attributes = displayDelegate.detectorAttributes(for: detector, and: message, at: indexPath)
                messageLabel.setAttributes(attributes, detector: detector)
            }
            switch message.kind {
            case .text(let text), .emoji(let text):
                messageLabel.text = text
                messageLabel.textColor = UIColor.label
                if let font = messageLabel.messageLabelFont {
                    messageLabel.font = font
                }
            case .attributedText(let text, _, _):
                messageLabel.attributedText = text
            default:
                break
            }
        }
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return messageLabel.handleGesture(touchPoint)
    }
    
}
