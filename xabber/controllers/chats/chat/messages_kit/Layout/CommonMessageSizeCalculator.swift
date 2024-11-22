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

class CommonMessageSizeCalculator: MessageSizeCalculator {

//    public var incomingMessageLabelInsets = UIEdgeInsets(top: 6, left: 16, bottom: 20, right: 8)
//    public var outgoingMessageLabelInsets = UIEdgeInsets(top: 6, left: 8, bottom: 20, right: 16)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body).withSize(16)
    public var commentAdditionalInset: CGFloat = 0
    

    
    override func messageContainerMaxWidth(for message: MessageType) -> CGFloat {
        let maxWidth = super.messageContainerMaxWidth(for: message)
        let textInsets = messageLabelInsets(for: message)
        return maxWidth //- textInsets.horizontal
    }

    override func sizeForInlineAudioMedia(for message: any MessageType) -> CGSize {
        let audio = message.references.filter ({ $0.kind == .voice })
        if audio.isEmpty {
            return .zero
        }
        let mediaMaxWidth = messageContainerMaxWidth(for: message) > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages : messageContainerMaxWidth(for: message)
        let mediaFileHeight: CGFloat = 60
        
        return CGSize(width: mediaMaxWidth, height: mediaFileHeight * CGFloat(audio.count))
    }
    
    override func sizeForInlineFilesMedia(for message: any MessageType) -> CGSize {
        
        let fileTypes = Set([
            MimeIconTypes.file.rawValue,
            MimeIconTypes.archive.rawValue,
            MimeIconTypes.document.rawValue,
            MimeIconTypes.pdf.rawValue,
            MimeIconTypes.presentation.rawValue,
            MimeIconTypes.audio.rawValue,
        ])
        let files = message.references.filter ({ $0.kind == .media && fileTypes.contains($0.mimeType) })
        if files.isEmpty {
            return .zero
        }
        let mediaMaxWidth = messageContainerMaxWidth(for: message) > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages : messageContainerMaxWidth(for: message)
        let mediaFileHeight: CGFloat = 60
        
        return CGSize(width: mediaMaxWidth, height: mediaFileHeight * CGFloat(files.count))
    }
    
    private final func sizeForMediaItems(_ message: MessageType) -> CGSize {
        let mediaMaxWidth = messageContainerMaxWidth(for: message) > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages : messageContainerMaxWidth(for: message)
        return CGSize(width: mediaMaxWidth, height: mediaMaxWidth)
    }
    
    private final func sizeForMediaItem(_ message: MessageType) -> CGSize {
        let fileTypes = Set([
            MimeIconTypes.image.rawValue,
            MimeIconTypes.video.rawValue,
        ])
        let files = message.references.filter ({ $0.kind == .media && fileTypes.contains($0.mimeType) })
        let maxWidth = messageContainerMaxWidth(for: message) > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages : messageContainerMaxWidth(for: message)
        let maxHeight: CGFloat = UIScreen.main.bounds.height / 2
        let minHeight: CGFloat = 128
        let minWidth: CGFloat = 128
        if let size = files.first?.sizeInPx {

            var calculatedWidth = size.width
            var calculatedHeight = size.height

            if size.width > maxWidth {
                calculatedWidth = maxWidth
                calculatedHeight = maxWidth * size.height / size.width
                if calculatedHeight > maxHeight {
                    calculatedWidth = maxHeight * calculatedWidth / calculatedHeight
                    calculatedHeight = maxHeight
                }
            } else if size.height > maxHeight {
                calculatedHeight = maxHeight
                calculatedWidth = maxHeight * size.width / size.height
                if calculatedWidth > maxWidth {
                    calculatedHeight = maxWidth * calculatedHeight / calculatedWidth
                    calculatedWidth = maxWidth
                }
            }
            return CGSize(width: max(minWidth, calculatedWidth), height: max(minHeight, calculatedHeight))
        } else {
            return CGSize(width: maxWidth, height: maxWidth)
        }
    }
    
    override func sizeForInlineImagesMedia(for message: any MessageType) -> CGSize {
        let images = message.references.filter ({ $0.kind == .media && $0.mimeType == MimeIconTypes.image.rawValue })
        if images.isEmpty {
            return .zero
        } else if images.count == 0 {
            return sizeForMediaItem(message)
        } else {
            return sizeForMediaItems(message)
        }
    }
    
    override func sizeForInlineVideosMedia(for message: any MessageType) -> CGSize {
        let images = message.references.filter ({ $0.kind == .media && $0.mimeType == MimeIconTypes.video.rawValue })
        if images.isEmpty {
            return .zero
        } else if images.count == 0 {
            return sizeForMediaItem(message)
        } else {
            return sizeForMediaItems(message)
        }
    }
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        
        
        
        var messageContainerSize: CGSize = .zero
        let maxWidth = messageContainerMaxWidth(for: message)
        if !isConfigured {
            inlineForwardsSizes = messageContainerAdditionalSizes(for: message)
        }
        var inlineMessageContainers = inlineForwardsSizes
        var bodyContainer: CGSize = .zero
        let lastLineWidth: CGFloat
        switch message.kind {
            case .attributedText(let text, _, let author):
                bodyContainer = labelSize(for: text, considering: maxWidth)
                if message.withAuthor {
                    let authorSize = labelSize(for: author, considering: maxWidth)
                    if bodyContainer.width < authorSize.width {
                        bodyContainer.width = authorSize.width
                    }
                }
                lastLineWidth = UILabel.lastLineWidth(text: text, width: maxWidth)
                let labelInsets = messageLabelInsets(for: message)
                bodyContainer.width += labelInsets.horizontal
                if message.isOutgoing {
//                    bodyContainer.width += 16
                }
                if message.references.isNotEmpty {
                    let audioInlines  = sizeForInlineAudioMedia(for:  message)
                    let filesInlines  = sizeForInlineFilesMedia(for:  message)
                    let imagesInlines = sizeForInlineImagesMedia(for: message)
                    let videosInlines = sizeForInlineVideosMedia(for: message)
                    var inlinesHeight: CGFloat = 0.0
                    inlinesHeight += audioInlines.height
                    inlinesHeight += filesInlines.height
                    inlinesHeight += imagesInlines.height
                    inlinesHeight += videosInlines.height
                    
                    if inlinesHeight > 0 {
                        inlinesHeight += 8
                    }
                    bodyContainer.height += inlinesHeight
                    
                    if bodyContainer.width < audioInlines.width {
                        bodyContainer.width = audioInlines.width
                    }
                    if bodyContainer.width < filesInlines.width {
                        bodyContainer.width = filesInlines.width
                    }
                    if bodyContainer.width < imagesInlines.width {
                        bodyContainer.width = imagesInlines.width
                    }
                    if bodyContainer.width < videosInlines.width {
                        bodyContainer.width = videosInlines.width
                    }
                    
                }
            case .skeleton(let text):
                bodyContainer = labelSize(for: text, considering: maxWidth)
                lastLineWidth = 64.0
                let labelInsets = messageLabelInsets(for: message)
                bodyContainer.width += labelInsets.horizontal
                bodyContainer.width += 16
            default:
                fatalError("messageContainerSize text received unhandled MessageDataType: \(message.kind)")
        }
        inlineMessageContainers.append(bodyContainer)
        let messageInsets = messageLabelInsets(for: message)
        messageContainerSize = CGSize(width: inlineMessageContainers.compactMap { return $0.width }.max() ?? maxWidth,
                                      height: inlineMessageContainers.compactMap { return $0.height }.reduce(0,+))

        var dateWidth: CGFloat = message.isEdited ? 112 : (message.isOutgoing ? 88 : 72)
        if message.afterburnInterval > 0 {
            dateWidth += 12
        }
        let lastLineDelta = messageContainerSize.width - lastLineWidth
        if lastLineDelta < dateWidth {
            if (messageContainerSize.width + (dateWidth - lastLineDelta)) <= maxWidth + 16 {
                messageContainerSize.width = lastLineWidth + dateWidth
                messageContainerSize.height += messageInsets.top + 6
            } else {
                messageContainerSize.height += messageInsets.vertical
            }
        } else {
            messageContainerSize.height += messageInsets.top
        }
        if messageContainerSize.width < dateWidth {
            messageContainerSize.width = dateWidth
        }
        
        messageContainerSize.width += messageInsets.horizontal
        
        if message.withAuthor {
            messageContainerSize.height += 20
        }
        return messageContainerSize
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? MessagesCollectionViewLayoutAttributes else { return }

        let dataSource = messagesLayout.messagesDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)

        attributes.messageLabelInsets = messageLabelInsets(for: message)
        attributes.messageLabelFont = messageLabelFont

        switch message.kind {
        case .attributedText(let text, _, _):
            guard text.string.isNotEmpty,
                let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else {
                    return
            }
            attributes.messageLabelFont = font
        default:
            break
        }
    }
}

