//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation
import UIKit

enum ChatMessageLayoutCalculator {
    static func measure(
        _ message: ChatViewController.Datasource,
        _ context: ChatMessageLayoutContext
    ) -> ChatMessageLayout {
        measure(message as MessageType, context: context)
    }

    static func measure(
        _ message: MessageType,
        context: ChatMessageLayoutContext
    ) -> ChatMessageLayout {
        switch message.kind {
        case .attributedText, .emoji, .skeleton:
            return Worker(context: context).commonLayout(for: message)
        case .system, .date, .unread, .call:
            return Worker(context: context).systemLayout(for: message)
        case .initial:
            return Worker(context: context).initialLayout(for: message)
        case .sticker:
            return Worker(context: context).stickerLayout(for: message)
        }
    }

    private struct Worker {
        private let context: ChatMessageLayoutContext
        private let messageContainerMargin = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        private let messageContainerPadding = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        private let messageLabelInsets = UIEdgeInsets(top: 0, left: 6, bottom: 2, right: 6)
        private let timeMarkerInsets = UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        private let messagePadding: CGFloat = 64
        private let inlineContainerSizePadding = UIEdgeInsets(top: 2, left: 2, bottom: 0, right: 2)

        init(context: ChatMessageLayoutContext) {
            self.context = context
        }

        func commonLayout(for message: MessageType) -> ChatMessageLayout {
            let maxWidth = messageContainerMaxWidth()
            let timeMarkerSize = labelSize(
                for: message.timeMarkerText,
                maxWidth: maxWidth
            ).margin(width: message.indicator == .none ? 10 : 24, height: 2)
            let authorSize = labelSize(
                for: message.attributedAuthor,
                maxWidth: maxWidth
            ).margin(width: messageLabelInsets.horizontal, height: messageLabelInsets.vertical)
            let labelSize = inlineLabelSize(for: message, maxWidth: maxWidth)
            let maxFilesWidth = max(labelSize.width, CommonMessageSizeCalculator.inlineFileViewWidth)
            let maxContactsWidth = max(labelSize.width, CommonMessageSizeCalculator.inlineContactViewWidth)
            let maxAudioWidth = max(labelSize.width, 320)
            let audioSize = inlineAudioSize(
                count: message.audios.count,
                maxWidth: maxAudioWidth
            )
            let contactsSize = inlineFixedRowsSize(
                count: message.contacts.count,
                rowHeight: CommonMessageSizeCalculator.inlineFileViewHeight,
                maxWidth: maxContactsWidth,
                addsTrailingPadding: true
            )
            let filesSize = inlineFixedRowsSize(
                count: message.files.count,
                rowHeight: CommonMessageSizeCalculator.inlineFileViewHeight,
                maxWidth: maxFilesWidth,
                addsTrailingPadding: true
            )
            let videosSize = inlineVideosSize(message.videos, maxWidth: maxWidth)
            let imagesSize = message.images.isEmpty ? .zero : CGSize(width: maxWidth, height: maxWidth)
            let locationsSize = ChatLocationAttachmentLayoutPolicy.inlineSize(
                for: message.locations,
                max: CGSize(width: maxWidth, height: maxWidth)
            )
            let warningSize = warningLabelSize(
                text: message.messageWarningText,
                maxWidth: maxWidth
            )
            let forwards = attachmentLayouts(message.forwards)
            let isImageMessage = message.images.isNotEmpty ||
                message.videos.isNotEmpty || message.locations.isNotEmpty
            let timeMarkerWithBackplate = isImageMessage &&
                message.files.isEmpty && message.contacts.isEmpty && message.audios.isEmpty &&
                messageText(message).isEmpty

            var paddedLabelSize: CGSize = .zero
            if labelSize != .zero {
                paddedLabelSize = CGSize(
                    width: labelSize.width + messageLabelInsets.horizontal,
                    height: labelSize.height + messageLabelInsets.vertical
                )
            }

            let totalSizes = [
                authorSize,
                imagesSize,
                videosSize,
                locationsSize,
                contactsSize,
                filesSize,
                audioSize,
                paddedLabelSize,
                warningSize
            ] + forwards.map {
                $0.messageContainer.margin(width: 0, height: inlineContainerSizePadding.vertical)
            }
            var container = CGSize(
                width: totalSizes.map(\.width).max() ?? maxWidth,
                height: totalSizes.map(\.height).reduce(0, +) +
                    messageContainerPadding.vertical + messageContainerMargin.vertical
            )

            if warningSize != .zero {
                container.height += timeMarkerSize.height
            } else if container.height < (message.withAuthor ? 58 : 38) {
                if container.width + timeMarkerSize.width >= maxWidth {
                    container.height += 20
                } else {
                    container.width += timeMarkerSize.width
                }
            } else if case .attributedText(let text) = message.kind {
                let lastLineSize = lastLineLabelSize(for: text, size: paddedLabelSize)
                if container.width - lastLineSize.width < timeMarkerSize.width {
                    container.height += timeMarkerSize.height
                }
                if text.string.isEmpty, forwards.isNotEmpty {
                    container.height += 16
                }
            }

            container.width += messageContainerPadding.horizontal + CommonMessageSizeCalculator.tailWidth
            container.width = max(
                container.width,
                timeMarkerSize.width + CommonMessageSizeCalculator.tailWidth +
                    timeMarkerInsets.right + messageContainerPadding.right +
                    messageContainerMargin.right + (timeMarkerWithBackplate ? 3 : 0)
            )
            container.height = max(
                container.height,
                timeMarkerSize.height + timeMarkerInsets.bottom +
                    messageContainerPadding.bottom + messageContainerMargin.bottom +
                    (timeMarkerWithBackplate ? 7 : 2)
            )
            let forwardsContainer = message.forwards.isEmpty
                ? .zero
                : CGSize(
                    width: max(forwards.map { $0.messageContainer.width }.max() ?? maxWidth, 64),
                    height: forwards.map {
                        $0.messageContainer.height + inlineContainerSizePadding.vertical
                    }.reduce(0, +)
                )
            var layout = ChatMessageLayout.empty(
                cellSize: CGSize(width: context.normalizedWidth, height: container.height)
            )
            layout.messagePrimary = message.primary
            layout.messageContainerSize = container
            layout.messageContainerMargin = messageContainerMargin
            layout.messageContainerPadding = messageContainerPadding
            layout.messageLabelInsets = messageLabelInsets
            layout.forwardsContainerViewSize = forwardsContainer
            layout.forwardsInlineViewSize = forwards
            layout.audioInlineViewSize = audioSize
            layout.imagesInlineViewSize = imagesSize
            layout.videosInlineViewSize = videosSize
            layout.locationsInlineViewSize = locationsSize
            layout.contactsInlineViewSize = contactsSize
            layout.filesInlineViewSize = filesSize
            layout.textInlineViewSize = labelSize
            layout.warningInlineViewSize = warningSize
            layout.authorInlineSize = authorSize
            layout.side = message.isOutgoing ? .right : .left
            layout.tail = message.tailed ? context.messageStyle : "no_tail"
            layout.cornerRadius = context.cornerRadius
            layout.tailWidth = CommonMessageSizeCalculator.tailWidth
            layout.timeMarkerSize = timeMarkerSize
            layout.timeMarkerIndicator = message.indicator
            layout.timeMarkerRadius = 7
            layout.timeMarkerInsets = timeMarkerInsets
            layout.inlineContainerSizePadding = inlineContainerSizePadding
            layout.avatarPosition = context.avatarMode == "top"
                ? AvatarPosition(horizontal: .cellLeading, vertical: .messageTop)
                : AvatarPosition(horizontal: .cellLeading, vertical: .cellBottom)
            layout.isImageMessage = isImageMessage
            layout.timeMarkerWithBackplate = timeMarkerWithBackplate
            if message.reservesAvatarSpace {
                layout.avatarSize = CGSize(square: 32)
            }
            return layout
        }

        func systemLayout(for message: MessageType) -> ChatMessageLayout {
            let attributedText: NSAttributedString
            switch message.kind {
            case .call(let call):
                let text: String
                if call.incoming {
                    text = call.missed ? "Missed call" : "Incoming call"
                } else {
                    text = "Outgoing call"
                }
                attributedText = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .caption1),
                        .foregroundColor: UIColor.white
                    ]
                )
            case .system(let text), .date(let text), .unread(let text):
                attributedText = text
            default:
                attributedText = NSAttributedString()
            }
            let insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            var textSize = labelSize(for: attributedText, maxWidth: messageContainerMaxWidth())
            textSize.width = max(112, textSize.width + insets.horizontal)
            textSize.height += insets.vertical
            var layout = ChatMessageLayout.empty(
                cellSize: CGSize(width: context.normalizedWidth, height: textSize.height)
            )
            layout.messagePrimary = message.primary
            layout.messageContainerSize = CGSize(width: context.normalizedWidth, height: textSize.height)
            layout.messageLabelInsets = insets
            layout.textInlineViewSize = textSize
            return layout
        }

        func initialLayout(for message: MessageType) -> ChatMessageLayout {
            let description: NSAttributedString
            if case .initial(let value) = message.kind {
                description = value
            } else {
                description = NSAttributedString()
            }
            let maxWidth = messageContainerMaxWidth()
            let size = CGSize(
                width: maxWidth,
                height: 104 + labelSize(for: description, maxWidth: maxWidth).height
            )
            var layout = ChatMessageLayout.empty(
                cellSize: CGSize(width: context.normalizedWidth, height: size.height)
            )
            layout.messagePrimary = message.primary
            layout.messageContainerSize = size
            layout.messageLabelInsets = UIEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
            return layout
        }

        func stickerLayout(for message: MessageType) -> ChatMessageLayout {
            let sourceSize: CGSize
            if case .sticker(let attachment) = message.kind {
                sourceSize = attachment.size
            } else {
                sourceSize = CGSize(square: ChatStickerLayoutPolicy.maximumSide)
            }
            let renderedSize = ChatStickerLayoutPolicy.renderedSize(
                sourceSize: sourceSize,
                availableWidth: messageContainerMaxWidth()
            )
            let margin = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            var layout = ChatMessageLayout.empty(
                cellSize: CGSize(
                    width: context.normalizedWidth,
                    height: renderedSize.height + margin.vertical
                )
            )
            layout.messagePrimary = message.primary
            layout.messageContainerSize = renderedSize
            layout.messageContainerMargin = margin
            layout.messageContainerPadding = .zero
            layout.messageLabelInsets = .zero
            layout.side = message.isOutgoing ? .right : .left
            layout.tail = "none"
            layout.cornerRadius = context.cornerRadius
            layout.isImageMessage = true
            if message.reservesAvatarSpace {
                layout.avatarSize = CGSize(square: 32)
            }
            return layout
        }

        private func attachmentLayouts(
            _ attachments: [MessageAttachment]
        ) -> [MessageAttachmentSizes] {
            let maxWidth = messageContainerMaxWidth(inlineLevel: 1)
            return attachments.map { attachment in
                let timeMarker = labelSize(
                    for: attachment.timeMarker,
                    maxWidth: maxWidth
                ).margin(width: 8, height: 2)
                let author = labelSize(
                    for: attachment.attributedAuthor,
                    maxWidth: maxWidth
                ).margin(width: 4, height: 2)
                let text = labelSize(
                    for: attachment.textMessage,
                    maxWidth: maxWidth
                ).margin(width: 4, height: 0)
                let images = attachment.images.isEmpty
                    ? .zero
                    : CGSize(width: maxWidth, height: maxWidth)
                        .margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
                let videos = inlineVideosSize(
                    attachment.videos,
                    maxWidth: maxWidth
                ).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
                let locations = ChatLocationAttachmentLayoutPolicy.inlineSize(
                    for: attachment.locations,
                    max: CGSize(width: maxWidth, height: maxWidth)
                ).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
                let contacts = inlineFixedRowsSize(
                    count: attachment.contacts.count,
                    rowHeight: CommonMessageSizeCalculator.inlineFileViewHeight,
                    maxWidth: CommonMessageSizeCalculator.inlineContactViewWidth,
                    addsTrailingPadding: true
                ).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
                let files = inlineFixedRowsSize(
                    count: attachment.files.count,
                    rowHeight: CommonMessageSizeCalculator.inlineFileViewHeight,
                    maxWidth: CommonMessageSizeCalculator.inlineFileViewWidth,
                    addsTrailingPadding: true
                ).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
                let audios = inlineAudioSize(
                    count: attachment.audios.count,
                    maxWidth: 320
                ).margin(width: 0, height: CommonMessageSizeCalculator.attachmentPadding.vertical)
                let paddedText = text == .zero ? .zero : text
                let components = [author, paddedText, images, videos, locations, contacts, files, audios]
                var container = CGSize(
                    width: components.map(\.width).max() ?? maxWidth,
                    height: components.map(\.height).reduce(0, +)
                )
                if container.height < 60 {
                    if container.width + timeMarker.width >= maxWidth {
                        container.height += timeMarker.height
                    } else {
                        container.width += timeMarker.width
                    }
                } else if text.height > 0 {
                    let lastLine = lastLineLabelSize(for: attachment.textMessage, size: paddedText)
                    if container.width - lastLine.width < timeMarker.width {
                        container.height += timeMarker.height
                    }
                } else if audios.height == 0 && contacts.height == 0 && files.height == 0 {
                    container.height += timeMarker.height
                }
                return MessageAttachmentSizes(
                    textLabelSize: text,
                    imagesContainerSize: images,
                    videosContainerSize: videos,
                    locationsContainerSize: locations,
                    contactsContainerSize: contacts,
                    filesContainerSize: files,
                    audiosContainerSize: audios,
                    containerSize: container,
                    authorSize: author,
                    messageContainer: container.margin(width: 12, height: 10),
                    timeMarker: timeMarker
                )
            }
        }

        private func inlineLabelSize(for message: MessageType, maxWidth: CGFloat) -> CGSize {
            switch message.kind {
            case .attributedText(let text), .skeleton(let text):
                guard text.string.isNotEmpty else { return .zero }
                return labelSize(for: text, maxWidth: maxWidth)
            default:
                return .zero
            }
        }

        private func warningLabelSize(text: String?, maxWidth: CGFloat) -> CGSize {
            guard let text, text.isNotEmpty else { return .zero }
            let insets = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .medium)]
            )
            let size = labelSize(for: attributed, maxWidth: max(1, maxWidth - insets.horizontal))
            guard size != .zero else { return .zero }
            return CGSize(
                width: min(maxWidth, size.width + insets.horizontal),
                height: size.height + insets.vertical
            )
        }

        private func inlineVideosSize(_ videos: [VideoAttachment], maxWidth: CGFloat) -> CGSize {
            guard videos.isNotEmpty else { return .zero }
            let defaultSide = max(8, min(128, maxWidth))
            let sizes = videos.map { video -> CGSize in
                guard video.size.width.isFinite,
                      video.size.height.isFinite,
                      video.size.width > 4,
                      video.size.height > 4 else {
                    return CGSize(square: defaultSide)
                }
                return CGSize(
                    width: min(video.size.width, maxWidth),
                    height: min(video.size.height, maxWidth)
                )
            }
            return CGSize(
                width: sizes.map(\.width).max() ?? defaultSide,
                height: sizes.reduce(0) { $0 + $1.height + 4 }
            )
        }

        private func inlineFixedRowsSize(
            count: Int,
            rowHeight: CGFloat,
            maxWidth: CGFloat,
            addsTrailingPadding: Bool
        ) -> CGSize {
            guard count > 0 else { return .zero }
            return CGSize(
                width: maxWidth,
                height: rowHeight * CGFloat(count) +
                    (addsTrailingPadding ? CommonMessageSizeCalculator.inlineSubviewPadding : 0)
            )
        }

        private func inlineAudioSize(count: Int, maxWidth: CGFloat) -> CGSize {
            guard count > 0 else { return .zero }
            return CGSize(
                width: maxWidth,
                height: CGFloat(count) * (
                    CommonMessageSizeCalculator.inlineAudioViewHeight +
                    CommonMessageSizeCalculator.inlineSubviewPadding
                )
            )
        }

        private func messageContainerMaxWidth(inlineLevel: Int = 0) -> CGFloat {
            var width = context.normalizedWidth - messageContainerMargin.horizontal -
                messageContainerPadding.horizontal - messagePadding
            width = min(width, 420)
            if inlineLevel > 0 {
                width -= CGFloat(8 * inlineLevel)
            }
            return max(1, width)
        }

        private func labelSize(for text: NSAttributedString?, maxWidth: CGFloat) -> CGSize {
            guard let text else { return .zero }
            let rect = text.boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).standardized
            let size = CGSize(width: ceil(rect.width), height: ceil(rect.height))
            return size.width == 0 ? .zero : size
        }

        private func lastLineLabelSize(for text: NSAttributedString?, size: CGSize) -> CGSize {
            guard size.width > 0 else { return .zero }
            return labelSize(for: text?.splitIntoLines(for: size).last, maxWidth: size.width)
        }

        private func messageText(_ message: MessageType) -> String {
            guard case .attributedText(let text) = message.kind else { return "" }
            return text.string
        }
    }
}
