//
//  InlineForwardsContainerView.swift
//  xabber
//
//  Created by Игорь Болдин on 11.03.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class InlineMessageAttachmentView: ModernContainerView {

    let quoteLine: UIView = {
        let view = UIView(frame: .zero)
        
        view.backgroundColor = MDCPalette.purple.tint500
        
        return view
    }()

    let authorLabel: MessageLabel = {
        let label = MessageLabel(frame: .zero)
        
//        label.backgroundColor = .white
        
        return label
    }()
    
    let containerView: ModernContainerView = {
        let view = ModernContainerView(frame: .zero)
        
//        view.backgroundColor = .green
        
        return view
    }()
    
    let filesView: InlineFilesGridView = {
        let view = InlineFilesGridView()
                
        return view
    }()
    
    let audiosView: InlineAudiosGridView = {
        let view = InlineAudiosGridView()
        
        return view
    }()
    
    let videosView: InlineVideosGridView = {
        let view = InlineVideosGridView()
        
//        view.backgroundColor = .black
        
        return view
    }()

    let locationsView: InlineLocationsGridView = {
        let view = InlineLocationsGridView()

        return view
    }()

    let contactsView: InlineContactsGridView = {
        let view = InlineContactsGridView()

        return view
    }()
    
    let imagesView: InlineImagesGridView = {
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
    
    let timeMarker: TimeMarkerView = {
        let marker = TimeMarkerView(frame: .zero)
        
        marker.setupSubviews()
//        marker.backgroundColor = .red
        
        return marker
    }()
    
    weak var delegate: MessageCellDelegate? {
        didSet {
            messageLabel.delegate = delegate
        }
    }
    
    func layoutTimeMarker(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let frame = CGRect(
            origin: CGPoint(
                x: size.containerSize.width - size.timeMarker.width - attributes.timeMarkerInsets.right,
                y: size.containerSize.height - size.timeMarker.height
            ),
            size: size.timeMarker
        )
        self.timeMarker.update(frame: frame, indicator: .none, radius: attributes.timeMarkerRadius)
    }
    
    func layoutContainerView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        self.containerView.frame = CGRect(
            origin: CGPoint(x: attributes.inlineContainerSizeInsets.left, y: attributes.inlineContainerSizeInsets.top),
            size: CGSize(
                width: size.containerSize.width,// - 14,
                height: size.containerSize.height// - 12
            )
        )
        self.quoteLine.frame = CGRect(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: 2, height: self.frame.height)
        )
    }
    
    func layoutAuthorLabel(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems: [CGSize] = [
            
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.authorLabel.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(
                x: attributes.messageLabelInsets.left,
                y: CommonMessageSizeCalculator.attachmentPadding.top
            ),
            size: size
                .authorSize
                .padding(
                    width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                    height: CommonMessageSizeCalculator.attachmentPadding.vertical
                )
        )
    }
    
    func layoutImagesView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems: [CGSize] = [
            size.authorSize,
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.imagesView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: size.imagesContainerSize
        )
        let radius = CommonConfigManager.shared.messageStyleConfig.containers.level_1.border.getRadiusFor(index: attributes.cornerRadius)
        self.imagesView.configure(
            side: .left,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
    }
    
    func layoutVideosView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.videosView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(
                x: CommonMessageSizeCalculator.attachmentPadding.left,
                y: CommonMessageSizeCalculator.attachmentPadding.top
            ),
            size: size.videosContainerSize.padding(
                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: CommonMessageSizeCalculator.attachmentPadding.vertical
            )
        )
        let radius = CommonConfigManager.shared.messageStyleConfig.containers.level_1.border.getRadiusFor(index: attributes.cornerRadius)
        self.videosView.configure(
            side: .left,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
    }
    
    func layoutAudiosView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize,
            size.videosContainerSize,
            size.locationsContainerSize,
            size.contactsContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.audiosView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
//                .padding(
//                x: CommonMessageSizeCalculator.attachmentPadding.left,
//                y: CommonMessageSizeCalculator.attachmentPadding.top
//            ),
            size: size.audiosContainerSize
//                .padding(
//                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
//                height: CommonMessageSizeCalculator.attachmentPadding.vertical
//            )
        )
    }

    func layoutLocationsView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize,
            size.videosContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.locationsView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: size.locationsContainerSize
        )
        let radius = CommonConfigManager.shared.messageStyleConfig.containers.level_1.border.getRadiusFor(index: attributes.cornerRadius)
        self.locationsView.configure(
            side: .left,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
    }

    func layoutContactsView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize,
            size.videosContainerSize,
            size.locationsContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.contactsView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(
                x: CommonMessageSizeCalculator.attachmentPadding.left,
                y: CommonMessageSizeCalculator.attachmentPadding.top
            ),
            size: size.contactsContainerSize.padding(
                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: CommonMessageSizeCalculator.attachmentPadding.vertical
            )
        )
    }
    
    func layoutFilesView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize,
            size.videosContainerSize,
            size.locationsContainerSize,
            size.contactsContainerSize,
            size.audiosContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.filesView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(
                x: CommonMessageSizeCalculator.attachmentPadding.left,
                y: CommonMessageSizeCalculator.attachmentPadding.top
            ),
            size: size.filesContainerSize.padding(
                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: CommonMessageSizeCalculator.attachmentPadding.vertical
            )
        )
    }
    
    func layoutLabelView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize,
            size.videosContainerSize,
            size.audiosContainerSize,
            size.locationsContainerSize,
            size.contactsContainerSize,
            size.filesContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        labelContainer.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(
                x: CommonMessageSizeCalculator.attachmentPadding.left + 4,
                y: CommonMessageSizeCalculator.attachmentPadding.top
            ),
            size: size.textLabelSize.padding(
                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: CommonMessageSizeCalculator.attachmentPadding.vertical
            )
        )
        messageLabel.frame = CGRect(
            origin: CGPoint.zero.padding(
                x: CommonMessageSizeCalculator.attachmentPadding.left,
                y: 0
            ),
            size: size.textLabelSize.padding(
                width: CommonMessageSizeCalculator.attachmentPadding.horizontal,
                height: 0
            )
        )
    }
    
    func setupSubviews() {
        guard containerView.superview !== self else {
            return
        }
        addSubview(containerView)
        containerView.addSubview(authorLabel)
        containerView.addSubview(imagesView)
        containerView.addSubview(videosView)
        containerView.addSubview(locationsView)
        containerView.addSubview(contactsView)
        containerView.addSubview(audiosView)
        containerView.addSubview(filesView)
        containerView.addSubview(labelContainer)
        containerView.addSubview(timeMarker)
        labelContainer.addSubview(messageLabel)
        addSubview(quoteLine)
    }
    
    var palette: MDCPalette = .amber
    var messagePrimary: String = ""
    func configure(_ message: MessageAttachment, palette: MDCPalette) {
        updateContent(message, palette: palette)
    }

    func updateContent(_ message: MessageAttachment, palette: MDCPalette) {
        if messagePrimary.isNotEmpty,
           messagePrimary != message.primary {
            resetAttachmentContent()
        }
        self.messagePrimary = message.primary
        imagesView.updateContent(message.images, representedBy: message.primary)
        videosView.updateContent(message.videos, representedBy: message.primary)
        locationsView.updateContent(message.locations, representedBy: message.primary)
        contactsView.updateContent(message.contacts, palette: palette)
        audiosView.delegate = self.delegate
        audiosView.updateContent(message.audios, palette: palette)
        filesView.updateContent(message.files, palette: palette)
        messageLabel.attributedText = message.textMessage
        authorLabel.attributedText = message.attributedAuthor
//        let radius = CommonConfigManager.shared.messageStyleConfig.containers.level_1.border.getRadiusFor(index: "16")
//        configure(
//            side: .left,
//            radiusLU: radius.leftUpper,
//            radiusRU: radius.rightUpper,
//            radiusRB: radius.rightBottom,
//            radiusLB: radius.leftBottom
//        )
        self.timeMarker.configure(text: message.timeMarker, indicator: .none, withBackplate: false)
        if message.outgoing {
            self.layer.backgroundColor = MDCPalette.grey.tint100.cgColor
        } else {
            self.layer.backgroundColor = palette.tint100.cgColor//MDCPalette.blue.tint100.cgColor
        }
        self.quoteLine.backgroundColor = palette.tint500
        self.setNeedsLayout()
//        configure(tail: "none", side: .left, radiusLU: 12, radiusRU: 12, radiusRB: 10, radiusLB: 12, padding: 0)
//        self.bubble.layer.backgroundColor = MDCPalette.green.tint100.cgColor
        
    }

    func prepareForReuse() {
        resetAttachmentContent()
        delegate = nil
        messagePrimary = ""
        messageLabel.attributedText = nil
        authorLabel.attributedText = nil
        layer.backgroundColor = UIColor.clear.cgColor
        quoteLine.backgroundColor = UIColor.clear
    }

    private func resetAttachmentContent() {
        imagesView.resetState()
        videosView.resetState()
        locationsView.resetState()
        contactsView.resetState()
        audiosView.resetState()
        filesView.resetState()
    }

    func reflowAttachmentFrames(for message: MessageAttachment) {
        reflow(
            views: imagesView.views,
            frames: imagesView.prepareGrid(message.images)
        )
        reflow(
            views: videosView.views,
            frames: videosView.prepareGrid(message.videos)
        )
        reflow(
            views: locationsView.views,
            frames: locationsView.prepareGrid(message.locations)
        )
        reflow(
            views: contactsView.views,
            frames: contactsView.prepareGrid(message.contacts)
        )
        reflow(
            views: audiosView.views,
            frames: audiosView.prepareGrid(message.audios)
        )
        reflow(
            views: filesView.views,
            frames: filesView.prepareGrid(message.files)
        )
        imagesView.refreshThumbnailBindings()
        videosView.refreshThumbnailBindings()
    }

    private func reflow<View: UIView>(
        views: [View],
        frames: [CGRect]
    ) {
        for (viewIndex, view) in views.enumerated() {
            guard frames.indices.contains(viewIndex) else { continue }
            view.frame = frames[viewIndex]
        }
    }
    
    func handleTouch(at touchPoint: CGPoint) -> Bool {
//        for (index, item) in grid.enumerated() {
//            if item.cell.contains(point) {
//                //                callback?(messageId, index, false)
//            }
//        }
        if self.filesView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.filesView.frame.minX, y: -self.filesView.frame.minY)
            if self.filesView.handleTouch(at: translatedPoint, callback: { url in
                self.delegate?.didTapOnFile(url: url)
            }) {
                return true
            }
        } else if self.imagesView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.imagesView.frame.minX, y: -self.imagesView.frame.minY)
            if self.imagesView.handleTouch(at: translatedPoint, callback: { (urls, url, referencePrimary, isSensitive) in
//                if isSensitive {
////                    fatalError()
//                }
                self.delegate?.didTapOnPhoto(message: self.messagePrimary, urls: urls, url: url, referencePrimary: referencePrimary, isSensitive: isSensitive)
            }) {
                return true
            }
        } else if self.videosView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.videosView.frame.minX, y: -self.videosView.frame.minY)
            if self.videosView.handleTouch(at: translatedPoint, callback: { (_, url, referencePrimary, isSensitive) in
                self.delegate?.didTapOnVideo(message: self.messagePrimary, url: url, referencePrimary: referencePrimary, isSensitive: isSensitive)
            }) {
                return true
            }
        } else if self.locationsView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.locationsView.frame.minX, y: -self.locationsView.frame.minY)
            if self.locationsView.handleTouch(at: translatedPoint, callback: { location in
                self.delegate?.didTapOnLocation(
                    message: self.messagePrimary,
                    referencePrimary: location.primary,
                    coordinate: location.coordinate,
                    address: location.address,
                    geoURI: location.geoURI
                )
            }) {
                return true
            }
        } else if self.contactsView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.contactsView.frame.minX, y: -self.contactsView.frame.minY)
            if self.contactsView.handleTouch(at: translatedPoint, callback: { contact in
                self.delegate?.didTapOnContact(message: self.messagePrimary, contact: contact)
            }) {
                return true
            }
        } else {
            let labelPoint = convert(touchPoint, to: messageLabel)
            return messageLabel.handleGesture(labelPoint)
        }
        return false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

class InlineForwardsContainerView: InlineAttachmentView {
    
    var inlineViews: [InlineMessageAttachmentView] = []
    private var representedMessages: [MessageAttachment] = []
    private var representedPalette: MDCPalette = .amber
    private weak var representedDelegate: MessageCellDelegate?
    private var representedLayoutAttributes: MessagesCollectionViewLayoutAttributes?
    private var hasAppliedLayout = false

    func layout(with attributes: MessagesCollectionViewLayoutAttributes) {
        representedLayoutAttributes = attributes
        hasAppliedLayout = true
        synchronizeChildren(updateExistingContent: false)
    }

    func configure(_ messages: [MessageAttachment], palette: MDCPalette, delegate: MessageCellDelegate?) {
        representedMessages = messages
        representedPalette = palette
        representedDelegate = delegate
        if messages.isEmpty {
            resetState()
            return
        }
        synchronizeChildren(updateExistingContent: true)
    }

    func updateContent(_ messages: [MessageAttachment], palette: MDCPalette, delegate: MessageCellDelegate?) {
        representedMessages = messages
        representedPalette = palette
        representedDelegate = delegate
        if messages.isEmpty {
            resetState()
            return
        }

        synchronizeChildren(updateExistingContent: true)
    }

    func resetState() {
        representedMessages.removeAll()
        representedDelegate = nil
        representedLayoutAttributes = nil
        hasAppliedLayout = false
        inlineViews.forEach { view in
            view.prepareForReuse()
            view.removeFromSuperview()
        }
        inlineViews.removeAll()
        contentViews.removeAll()
        grid.removeAll()
    }

    private func synchronizeChildren(updateExistingContent: Bool) {
        let layoutSizes = representedLayoutAttributes?.forwardsInlineViewSize ?? []
        let desiredCount: Int
        if hasAppliedLayout {
            if representedMessages.isEmpty {
                desiredCount = layoutSizes.count
            } else {
                desiredCount = min(representedMessages.count, layoutSizes.count)
            }
        } else {
            desiredCount = representedMessages.count
        }

        while inlineViews.count < desiredCount {
            let view = InlineMessageAttachmentView(frame: .zero)
            view.setupSubviews()
            inlineViews.append(view)
            addSubview(view)
        }
        while inlineViews.count > desiredCount {
            let view = inlineViews.removeLast()
            view.prepareForReuse()
            view.removeFromSuperview()
        }

        for index in 0..<desiredCount {
            let view = inlineViews[index]
            if let message = representedMessages[safe: index] {
                if view.messagePrimary != message.primary {
                    if view.messagePrimary.isNotEmpty {
                        view.prepareForReuse()
                    }
                    view.delegate = representedDelegate
                    view.configure(message, palette: representedPalette)
                } else if updateExistingContent {
                    view.delegate = representedDelegate
                    view.updateContent(message, palette: representedPalette)
                }
            }
        }

        guard let attributes = representedLayoutAttributes else {
            return
        }
        layoutChildren(with: attributes)
    }

    private func layoutChildren(
        with attributes: MessagesCollectionViewLayoutAttributes
    ) {
        var offset: CGFloat = 0
        for (index, view) in inlineViews.enumerated() {
            guard let sizeItem = attributes.forwardsInlineViewSize[safe: index] else {
                continue
            }
            view.frame = CGRect(
                origin: CGPoint(x: 0, y: offset).padding(
                    x: attributes.inlineContainerSizePadding.left,
                    y: attributes.inlineContainerSizePadding.top
                ),
                size: sizeItem.messageContainer.padding(
                    width: attributes.inlineContainerSizePadding.horizontal,
                    height: attributes.inlineContainerSizePadding.vertical
                )
            )
            view.layoutContainerView(with: sizeItem, attributes: attributes)
            view.layoutAuthorLabel(with: sizeItem, attributes: attributes)
            view.layoutImagesView(with: sizeItem, attributes: attributes)
            view.layoutVideosView(with: sizeItem, attributes: attributes)
            view.layoutLocationsView(with: sizeItem, attributes: attributes)
            view.layoutContactsView(with: sizeItem, attributes: attributes)
            view.layoutAudiosView(with: sizeItem, attributes: attributes)
            view.layoutFilesView(with: sizeItem, attributes: attributes)
            view.layoutLabelView(with: sizeItem, attributes: attributes)
            view.layoutTimeMarker(with: sizeItem, attributes: attributes)

            offset += sizeItem.messageContainer.height
                + attributes.inlineContainerSizePadding.vertical
            let radius = CommonConfigManager.shared.messageStyleConfig
                .containers.level_1.border
                .getRadiusFor(index: attributes.cornerRadius)
            view.configure(
                side: attributes.side,
                radiusLU: radius.leftUpper,
                radiusRU: radius.rightUpper,
                radiusRB: radius.rightBottom,
                radiusLB: radius.leftBottom
            )
            if let message = representedMessages[safe: index] {
                view.reflowAttachmentFrames(for: message)
            }
        }
    }
    
    func handleTouch(at touchPoint: CGPoint) -> Bool {
        for item in inlineViews where item.frame.contains(touchPoint) {
            let itemPoint = convert(touchPoint, to: item)
            if item.handleTouch(at: itemPoint) {
                return true
            }
        }
        return false
    }
}
