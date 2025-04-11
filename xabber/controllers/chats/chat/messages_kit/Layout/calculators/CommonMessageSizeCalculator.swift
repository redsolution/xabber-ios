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

public struct MessageAttachmentSizes {
    let textLabelSize: CGSize
    let imagesContainerSize: CGSize
    let videosContainerSize: CGSize
    let filesContainerSize: CGSize
    let audiosContainerSize: CGSize
    let containerSize: CGSize
    let authorSize: CGSize
    let messageContainer: CGSize
    let timeMarker: CGSize
}

class CommonMessageSizeCalculator: CellSizeCalculator {

//    public var incomingMessageLabelInsets = UIEdgeInsets(top: 6, left: 16, bottom: 20, right: 8)
//    public var outgoingMessageLabelInsets = UIEdgeInsets(top: 6, left: 8, bottom: 20, right: 16)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body).withSize(16)
    public var commentAdditionalInset: CGFloat = 0
    
    static let inlineFileViewHeight: CGFloat = 44
    static let inlineAudioViewHeight: CGFloat = 44
    static let inlineSubviewPadding: CGFloat = 0
    static let tailWidth: CGFloat = 8
    static let attachmentPadding: UIEdgeInsets =  UIEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)
    
    private func calcInlineImagesSize(for images: [ImageAttachment], min: CGSize, max: CGSize) -> CGSize {
        if images.isEmpty {
            return .zero
        } else {
            if images.count > 1 {
                return max
            } else {
                return max
//                guard let image = message.images.first else {
//                    return max
//                }
//                if image.size.lessThan(min) {
//                    return min
//                } else {
//                    return image.size
//                }
            }
        }
    }
    
    private func calcInlineVideosSize(for videos: [VideoAttachment], max: CGSize) -> CGSize {
        if videos.isEmpty {
            return .zero
        } else {
            var height: CGFloat = 0
            
            videos.forEach {
                video in
                if video.size.height > max.height {
                    height += max.height
                } else {
                    height += video.size.height
                }
                height += 4
            }
            if height == 0 {
                return .zero
            }
            let width = videos.compactMap { $0.size.width }.max() ?? max.width
            return CGSize(width: width > max.width ? max.width : width, height: height)
        }
    }
    
    private func calcInlineFilesSize(for files: [FileAttachment], max: CGSize) -> CGSize {
        if files.isEmpty {
            return .zero
        } else {
            var height: CGFloat = 0
            
            files.forEach {
                _ in
                height += CommonMessageSizeCalculator.inlineFileViewHeight
//                height += CommonMessageSizeCalculator.inlineSubviewPadding
            }
            if height == 0 {
                return .zero
            }
            height += CommonMessageSizeCalculator.inlineSubviewPadding
            return CGSize(width: max.width, height: height)
        }
    }
    
    private func calcInlineAudioSize(for audios: [AudioAttachment], max: CGSize) -> CGSize {
        if audios.isEmpty {
            return .zero
        } else {
            var height: CGFloat = 0
            
            audios.forEach {
                _ in
                height += CommonMessageSizeCalculator.inlineAudioViewHeight
                height += CommonMessageSizeCalculator.inlineSubviewPadding
            }
            if height == 0 {
                return .zero
            }
            return CGSize(width: max.width, height: height)
        }
    }
    
    private func calcInlineLabelSize(for message: MessageType, max: CGSize) -> CGSize {
        switch message.kind {
            case .attributedText(let text), .skeleton(let text):
                if text.string.isEmpty {
                    return .zero
                }
                return labelSize(for: text, considering: max.width)
            default:
                return .zero
        }
    }
    
    func messageAttachmentsContainerSize(for messageAttachments: [MessageAttachment]) -> [MessageAttachmentSizes] {
        var out: [MessageAttachmentSizes] = []
        let maxWidth = messageContainerMaxWidth(inlineLevel: 1)
        messageAttachments.forEach {
            attachment in
            let timeMarkerSize = labelSize(for: attachment.timeMarker, considering: maxWidth).margin(width: 8, height: 2)
            let authorSize = labelSize(for: attachment.attributedAuthor, considering: maxWidth).margin(width: 4, height: 2).margin(
                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: CommonMessageSizeCalculator.attachmentPadding.vertical
            )
            let textMessageSize = labelSize(for: attachment.textMessage, considering: maxWidth)
                .margin(
                width: 4, //CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: 0//CommonMessageSizeCalculator.attachmentPadding.vertical
            )
//            let maxSizeForLabel = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
            let maxSizeForImages = CGSize(width: maxWidth, height: maxWidth)
            let maxSizeForVideos = CGSize(width: maxWidth, height: maxWidth)
            let maxSizeForAudio = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
            let maxSizeForFiles = CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)
            
            let sizeAudios = calcInlineAudioSize(for: attachment.audios, max: maxSizeForAudio).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
            let sizeFiles = calcInlineFilesSize(for: attachment.files, max: maxSizeForFiles).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
            let sizeVideos = calcInlineVideosSize(for: attachment.videos, max: maxSizeForVideos).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
            let sizeImages = calcInlineImagesSize(for: attachment.images, min: textMessageSize, max: maxSizeForImages).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
            var paddedLabelSize: CGSize = .zero
            if textMessageSize != .zero {
                paddedLabelSize = textMessageSize
//                    .margin(
//                    width: messageLabelInsets.horizontal,
//                    height: messageLabelInsets.vertical
//                )
            }
            let totalSizes = [authorSize, paddedLabelSize, sizeImages, sizeFiles, sizeAudios, sizeVideos]
            var containerSize = CGSize(
                width: totalSizes.compactMap({ $0.width }).max() ?? maxWidth,
                height: totalSizes.compactMap({ $0.height }).reduce(0, +)
            )
            if containerSize.height < 60 {
                if (containerSize.width + timeMarkerSize.width) >= maxWidth {
                    containerSize.height += timeMarkerSize.height
                } else {
                    containerSize.width += timeMarkerSize.width
                }
            } else {
                if textMessageSize.height > 0 {
                    let lastLineSize = lastLineLabelSize(for: attachment.textMessage, for: paddedLabelSize)
                    let freeSpaceWidth = containerSize.width - lastLineSize.width
                    if freeSpaceWidth < timeMarkerSize.width {
                        containerSize.height += timeMarkerSize.height
                    }
                } else {
                    if !(sizeAudios.height > 0 || sizeFiles.height > 0) {
                        containerSize.height += timeMarkerSize.height
                    }
                }
            }
            out.append(
                MessageAttachmentSizes(
                    textLabelSize: textMessageSize,
                    imagesContainerSize: sizeImages,
                    videosContainerSize: sizeVideos,
                    filesContainerSize: sizeFiles,
                    audiosContainerSize: sizeAudios,
                    containerSize: containerSize,
                    authorSize: authorSize,
                    messageContainer: containerSize.margin(width: 12, height: 10),
                    timeMarker: timeMarkerSize
                )
            )
        }
        
        return out
    }
    
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        var messageContainerSize: CGSize = .zero
        
        
        let maxWidth = messageContainerMaxWidth()
        let authorSize = labelSize(for: message.attributedAuthor, considering: maxWidth).margin(width: 4, height: 2)
        let maxSizeForLabel = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        let maxSizeForImages = CGSize(width: maxWidth, height: maxWidth)
        let maxSizeForVideos = CGSize(width: maxWidth, height: maxWidth)
        
        let inlineMessagesSizes = messageAttachmentsContainerSize(for: message.forwards)
        let sizeLabel = calcInlineLabelSize(for: message, max: maxSizeForLabel)
        let maxSizeForFiles = CGSize(width: [sizeLabel.width, 180.0].max() ?? 180.0, height: CGFloat.greatestFiniteMagnitude)
        let maxSizeForAudio = CGSize(width: [sizeLabel.width, 320.0].max() ?? 320.0, height: CGFloat.greatestFiniteMagnitude)
        let sizeAudios = calcInlineAudioSize(for: message.audios, max: maxSizeForAudio)//.margin(width: 0, height: 2)
        let sizeFiles = calcInlineFilesSize(for: message.files, max: maxSizeForFiles)//.margin(width: 0, height: 2)
        let sizeVideos = calcInlineVideosSize(for: message.videos, max: maxSizeForVideos)//.margin(width: 0, height: 2)
        let sizeImages = calcInlineImagesSize(for: message.images, min: sizeLabel, max: maxSizeForImages)//.margin(width: 0, height: 2)
        
        var paddedLabelSize: CGSize = .zero
        if sizeLabel != .zero {
            paddedLabelSize = CGSize(
                width: sizeLabel.width + messageLabelInsets.horizontal,
                height: sizeLabel.height + messageLabelInsets.vertical
            )
        }
        
        let totalSizes = [authorSize, sizeImages, sizeVideos, sizeFiles, sizeAudios, paddedLabelSize] + inlineMessagesSizes.compactMap({ $0.messageContainer })
        
        messageContainerSize.height = totalSizes.compactMap { $0.height }.reduce(0, +) + messageContainerPadding.vertical + messageContainerMargin.vertical
        messageContainerSize.width = totalSizes.compactMap { $0.width }.max() ?? maxWidth
        
        let timeMarkerSize = labelSize(for: message.timeMarkerText, considering: messageContainerSize.width).margin(width: 24, height: 2)
        if messageContainerSize.height < (message.withAuthor ? 58 : 38) {
            if (messageContainerSize.width + timeMarkerSize.width) >= maxWidth {
                messageContainerSize.height += 20
            } else {
                messageContainerSize.width += timeMarkerSize.width
            }
        } else {
            switch message.kind {
                case .attributedText(let text):
                    let lastLineSize = lastLineLabelSize(for: text, for: paddedLabelSize)
                    let freeSpaceWidth = messageContainerSize.width - lastLineSize.width
                    if freeSpaceWidth < timeMarkerSize.width {
                        messageContainerSize.height += timeMarkerSize.height
                    }
                default:
                    break
            }
        }
        messageContainerSize.width = messagesLayout.itemWidth// totalSizes.compactMap { $0.width }.max() ?? maxWidth
        
        return messageContainerSize
    }
    
    func messageContainerSizes(for message: MessageType, attributes: MessagesCollectionViewLayoutAttributes) {
        var messageContainerSize: CGSize = .zero
        
        let timeMarkerSize = labelSize(for: message.timeMarkerText, considering: attributes.messageContainerSize.width).margin(width: message.indicator == .none ? 10 : 24, height: 2)
        
        let maxWidth = messageContainerMaxWidth()
        let authorSize = labelSize(for: message.attributedAuthor, considering: maxWidth).margin(width: messageLabelInsets.horizontal, height: messageLabelInsets.vertical)
        let maxSizeForLabel = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        let maxSizeForImages = CGSize(width: maxWidth, height: maxWidth)
        let maxSizeForVideos = CGSize(width: maxWidth, height: maxWidth)
//        let maxSizeForAudio = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
//        let maxSizeForFiles = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        
        let inlineMessagesSizes = messageAttachmentsContainerSize(for: message.forwards)
        let sizeLabel = calcInlineLabelSize(for: message, max: maxSizeForLabel)
        let maxSizeForFiles = CGSize(width: [sizeLabel.width, 180.0].max() ?? 180.0, height: CGFloat.greatestFiniteMagnitude)
        let maxSizeForAudio = CGSize(width: [sizeLabel.width, 320.0].max() ?? 320.0, height: CGFloat.greatestFiniteMagnitude)
        let sizeAudios = calcInlineAudioSize(for: message.audios, max: maxSizeForAudio)//.margin(width: 0, height: 2)
        let sizeFiles = calcInlineFilesSize(for: message.files, max: maxSizeForFiles)//.margin(width: 0, height: 2)
        let sizeVideos = calcInlineVideosSize(for: message.videos, max: maxSizeForVideos)//.margin(width: 0, height: 2)
        let sizeImages = calcInlineImagesSize(for: message.images, min: sizeLabel, max: maxSizeForImages)//.margin(width: 0, height: 2)
        
        var paddedLabelSize: CGSize = .zero
        if sizeLabel != .zero {
            paddedLabelSize = CGSize(
                width: sizeLabel.width + messageLabelInsets.horizontal,
                height: sizeLabel.height + messageLabelInsets.vertical
            )
        }
        
        let totalSizes = [authorSize, sizeImages, sizeVideos, sizeFiles, sizeAudios, paddedLabelSize] + inlineMessagesSizes.compactMap({ $0.messageContainer })
        
        messageContainerSize.height = totalSizes.compactMap { $0.height }.reduce(0, +) + messageContainerPadding.vertical + messageContainerMargin.vertical
        messageContainerSize.width = totalSizes.compactMap { $0.width }.max() ?? maxWidth
        
        if messageContainerSize.height < (message.withAuthor ? 58 : 38) {
            if (messageContainerSize.width + timeMarkerSize.width) >= maxWidth {
                messageContainerSize.height += 20
            } else {
                messageContainerSize.width += timeMarkerSize.width
            }
        } else {
            switch message.kind {
                case .attributedText(let text):
                    let lastLineSize = lastLineLabelSize(for: text, for: paddedLabelSize)
                    let freeSpaceWidth = messageContainerSize.width - lastLineSize.width
                    if freeSpaceWidth < timeMarkerSize.width {
                        messageContainerSize.height += timeMarkerSize.height
                    }
                default:
                    break
            }
        }
        
        messageContainerSize.width += (messageContainerPadding.horizontal + CommonMessageSizeCalculator.tailWidth)
        
        var forwardsContainerSize: CGSize = .zero
        if message.forwards.isNotEmpty {
            forwardsContainerSize = CGSize(
                width: [(inlineMessagesSizes.compactMap { $0.messageContainer.width }.max() ?? maxWidth), 64.0].max() ?? maxWidth,
                height: inlineMessagesSizes.compactMap { $0.messageContainer.height }.reduce(0, +) + 4
            )
        }
        attributes.authorInlineSize = authorSize
        attributes.filesInlineViewSize = sizeFiles
        attributes.videosInlineViewSize = sizeVideos
        attributes.audioInlineViewSize = sizeAudios
        attributes.imagesInlineViewSize = sizeImages
        attributes.textInlineViewSize = sizeLabel
        attributes.forwardsInlineViewSize = inlineMessagesSizes
        attributes.messageContainerSize = messageContainerSize
        attributes.forwardsContainerViewSize = forwardsContainerSize
        attributes.messageContainerPadding = messageContainerPadding
        attributes.messageContainerMargin = messageContainerMargin
        attributes.side = message.isOutgoing ? .right : .left
        attributes.messageLabelInsets = messageLabelInsets
        let tailStyle = self.messagesLayout.messagesLayoutDelegate.messageCornerStyle()
        attributes.tail = message.tailed ? tailStyle : "no_tail"
        attributes.cornerRadius = self.messagesLayout.messagesLayoutDelegate.messageCornerRadius()
        attributes.tailWidth = CommonMessageSizeCalculator.tailWidth
        attributes.timeMarkerSize = timeMarkerSize
        attributes.timeMarkerRadius = 7
        attributes.timeMarkerIndicator = message.indicator
        if self.messagesLayout.messagesLayoutDelegate.messageAvatarVerticalPosition() == "top" {
            attributes.avatarPosition = AvatarPosition(horizontal: .cellLeading, vertical: .messageTop)
        } else {
            attributes.avatarPosition = AvatarPosition(horizontal: .cellLeading, vertical: .cellBottom)
        }
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
        attributes.timeMarkerWithBackplate = timeMarkerWithBackplate
        
        if message.withAvatar {
            attributes.avatarSize = CGSize(square: 32)
        }
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? MessagesCollectionViewLayoutAttributes else { return }

        let dataSource = messagesLayout.messagesDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        messageContainerSizes(for: message, attributes: attributes)
    }
}

