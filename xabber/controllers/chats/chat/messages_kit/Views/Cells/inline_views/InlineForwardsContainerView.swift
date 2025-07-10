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
            size.videosContainerSize
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
    
    func layoutFilesView(with size: MessageAttachmentSizes, attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            size.authorSize,
            size.imagesContainerSize,
            size.videosContainerSize,
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
        addSubview(containerView)
        containerView.addSubview(authorLabel)
        containerView.addSubview(imagesView)
        containerView.addSubview(videosView)
        containerView.addSubview(audiosView)
        containerView.addSubview(filesView)
        containerView.addSubview(labelContainer)
        containerView.addSubview(timeMarker)
        labelContainer.addSubview(messageLabel)
        addSubview(quoteLine)
    }
    
    var palette: MDCPalette = .amber
    
    func configure(_ message: MessageAttachment, palette: MDCPalette) {
        
        imagesView.configure(message.images)
        videosView.configure(message.videos)
        audiosView.delegate = self.delegate
        audiosView.configure(message.audios, palette: palette)
        filesView.configure(message.files, palette: palette)
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
        self.layoutSubviews()
//        configure(tail: "none", side: .left, radiusLU: 12, radiusRU: 12, radiusRB: 10, radiusLB: 12, padding: 0)
//        self.bubble.layer.backgroundColor = MDCPalette.green.tint100.cgColor
        
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
            if self.imagesView.handleTouch(at: translatedPoint, callback: { (urls, url) in
                self.delegate?.didTapOnPhoto(urls: urls, url: url)
            }) {
                return true
            }
        } else if self.videosView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.imagesView.frame.minX, y: -self.videosView.frame.minY)
            if self.videosView.handleTouch(at: translatedPoint, callback: { (urls, url) in
//                self.delegate?.didTapOnVideo(urls: urls, url: url)
            }) {
                return true
            }
        } else {
            let translatedPoint = touchPoint.translate(x: -self.messageLabel.frame.minX, y: -self.messageLabel.frame.minY)
            return messageLabel.handleGesture(translatedPoint)
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
    
    func layout(with attributes: MessagesCollectionViewLayoutAttributes) {
        // Do not remove all subviews immediately; only adjust as needed
        if attributes.forwardsInlineViewSize.isEmpty {
            subviews.forEach { $0.removeFromSuperview() }
            inlineViews.removeAll()
            return
        }
        
        var offset: CGFloat = 0
        for (index, sizeItem) in attributes.forwardsInlineViewSize.enumerated() {
            let view = inlineViews[safe: index] ?? {
                let newView = InlineMessageAttachmentView(frame: .zero)
                inlineViews.append(newView)
                newView.setupSubviews()
                addSubview(newView)
                return newView
            }()
            
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
            
            // Update layout without resetting content
            view.layoutContainerView(with: sizeItem, attributes: attributes)
            view.layoutAuthorLabel(with: sizeItem, attributes: attributes)
            view.layoutImagesView(with: sizeItem, attributes: attributes)
            view.layoutVideosView(with: sizeItem, attributes: attributes)
            view.layoutAudiosView(with: sizeItem, attributes: attributes)
            view.layoutFilesView(with: sizeItem, attributes: attributes)
            view.layoutLabelView(with: sizeItem, attributes: attributes)
            view.layoutTimeMarker(with: sizeItem, attributes: attributes)
            
            offset += sizeItem.messageContainer.height + attributes.inlineContainerSizePadding.vertical
            let radius = CommonConfigManager.shared.messageStyleConfig.containers.level_1.border.getRadiusFor(index: attributes.cornerRadius)
            
            view.configure(
                side: attributes.side,
                radiusLU: radius.leftUpper,
                radiusRU: radius.rightUpper,
                radiusRB: radius.rightBottom,
                radiusLB: radius.leftBottom
            )
        }
        
        // Trim excess views
        while inlineViews.count > attributes.forwardsInlineViewSize.count {
            inlineViews.removeLast().removeFromSuperview()
        }
        
        print("Laid out forwardsContainer with \(attributes.forwardsInlineViewSize.count) sizes, inlineViews: \(inlineViews.count)")
    }
    
//    func layout(with attributes: MessagesCollectionViewLayoutAttributes) {
//        subviews.forEach { $0.removeFromSuperview() }
//        print("REDRAW", attributes.messagePrimary)
//        self.inlineViews.removeAll()
//        if attributes.forwardsInlineViewSize.isEmpty {
//            return
//        }
//        var offset: CGFloat = 0
//        attributes.forwardsInlineViewSize.enumerated().forEach {
//            (index, sizeItem) in
////            let view = inlineViews[index]
//            let view = InlineMessageAttachmentView(frame: CGRect(
//                origin: CGPoint(x: 0, y: offset).padding(
//                    x: attributes.inlineContainerSizePadding.left,
//                    y: attributes.inlineContainerSizePadding.top
//                ),
//                size: sizeItem.messageContainer.padding(
//                    width: attributes.inlineContainerSizePadding.horizontal,
//                    height: attributes.inlineContainerSizePadding.vertical
//                )
//            ))
//            view.frame = CGRect(
//                origin: CGPoint(x: 0, y: offset).padding(
//                    x: attributes.inlineContainerSizePadding.left,
//                    y: attributes.inlineContainerSizePadding.top
//                ),
//                size: sizeItem.messageContainer.padding(
//                    width: attributes.inlineContainerSizePadding.horizontal,
//                    height: attributes.inlineContainerSizePadding.vertical
//                )
//            )
//            addSubview(view)
//            UIView.performWithoutAnimation {
//                view.setupSubviews()
//                view.layoutContainerView(with: sizeItem, attributes: attributes)
//                view.layoutAuthorLabel(with: sizeItem, attributes: attributes)
//                view.layoutImagesView(with: sizeItem, attributes: attributes)
//                view.layoutVideosView(with: sizeItem, attributes: attributes)
//                view.layoutAudiosView(with: sizeItem, attributes: attributes)
//                view.layoutFilesView (with: sizeItem, attributes: attributes)
//                view.layoutLabelView (with: sizeItem, attributes: attributes)
//                view.layoutTimeMarker(with: sizeItem, attributes: attributes)
//            }
//            
//            inlineViews.append(view)
//            offset += sizeItem.messageContainer.height
//        }
//    }
    
    func configure(_ messages: [MessageAttachment], palette: MDCPalette, delegate: MessageCellDelegate?) {
        if messages.isEmpty { return }
        
        messages.enumerated().forEach {
            (index, message) in
//            let view = InlineMessageAttachmentView(frame: .zero)
            if inlineViews.count > index {
                inlineViews[index].delegate = delegate
                inlineViews[index].configure(message, palette: palette)
            }
        }
    }
    
    func resetState() {
        inlineViews.forEach { view in
            view.messageLabel.attributedText = nil
            view.authorLabel.attributedText = nil
            
            view.imagesView.views.removeAll()
            view.filesView.views.removeAll()
            view.audiosView.views.removeAll()
        }
    }
    
    func handleTouch(at touchPoint: CGPoint) {
        var isMyTouch: Bool = false
        self.inlineViews.forEach {
            item in
            if !isMyTouch {
                if item.frame.contains(touchPoint) {
                    let translatedPoint = touchPoint.translate(x: -item.frame.minX, y: -item.frame.minY)
                    if item.handleTouch(at: translatedPoint) {
                        isMyTouch = true
                    }
                }
            }
        }
    }
}
