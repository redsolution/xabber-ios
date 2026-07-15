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
import CoreMedia
import CocoaLumberjack
import RealmSwift

class InlineImagesGridView: InlineAttachmentView {
    
    class InlineMessageImageView: UIImageView {
        
        var primary: String
        var url: URL
        var representedRequest: InlineAttachmentRepresentedRequest
        var representedThumbnailRequest: ChatThumbnailRequest?
        var representedThumbnailConsumer: ChatThumbnailConsumer?
        var thumbnailSubscription: ChatThumbnailSubscription?
        let visibleConsumerID = UUID()
        var isSensitive: Bool {
            didSet {
                updateSensitiveAppearance()
            }
        }
        
        private var sensitiveOverlay: SensitiveMediaOverlayView?

        var hasSensitiveOverlay: Bool {
            sensitiveOverlay != nil
        }
        
        init(
            frame: CGRect,
            primary: String,
            url: URL,
            isSensitive: Bool,
            representedRequest: InlineAttachmentRepresentedRequest
        ) {
            self.primary = primary
            self.url = url
            self.isSensitive = isSensitive
            self.representedRequest = representedRequest
            super.init(frame: frame)
            setup()
            updateSensitiveAppearance()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setup() {
            self.layer.masksToBounds = true
        }
        
        private func updateSensitiveAppearance() {
            if isSensitive {
                let overlay = sensitiveOverlay ?? SensitiveMediaOverlayView()
                if sensitiveOverlay == nil {
                    sensitiveOverlay = overlay
                    overlay.isUserInteractionEnabled = false
                    addSubview(overlay)
                }
                overlay.frame = bounds
                bringSubviewToFront(overlay)
            } else {
                sensitiveOverlay?.removeFromSuperview()
                sensitiveOverlay = nil
            }
        }

        func cancelThumbnailBinding() {
            thumbnailSubscription?.cancel()
            thumbnailSubscription = nil
            representedThumbnailRequest = nil
            representedThumbnailConsumer = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            sensitiveOverlay?.frame = bounds
        }
        
    }
    
    var views: [InlineMessageImageView] = []
    var thumbnailPipeline: ChatThumbnailServing = ChatMediaThumbnailPipeline.shared

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshThumbnailBindings()
    }

    func resetState() {
        views.forEach {
            $0.cancelThumbnailBinding()
            $0.image = nil
            $0.removeFromSuperview()
        }
        views = []
        contentViews.removeAll()
        grid.removeAll()
    }

    public func prepareGrid(_ attachments: [ImageAttachment]) -> [CGRect] {
        var rects: [CGRect] = []
        let halfPadding: CGFloat = 2
        let containerSize: CGSize = frame.size
        switch attachments
            .count {
        case 0: break
        case 1:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: containerSize.width,
                                height: containerSize.height))
        case 2:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: containerSize.height))
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: containerSize.height))
        case 3:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: containerSize.height))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,//halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
        case 4:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: 0,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
        default:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: 0,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 3) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: (containerSize.height / 3) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 3) - (halfPadding * 2)))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: ((containerSize.height / 3) * 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 3) - halfPadding))
        }
        return rects
    }
    
    func configure(
        _ attachments: [ImageAttachment],
        representedBy containerPrimary: String = ""
    ) {
//        subviews.forEach { $0.removeFromSuperview() }
        resetState()
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            if let url = attachments[index].url {
                let request = InlineAttachmentRepresentedRequest(
                    containerPrimary: containerPrimary,
                    referencePrimary: attachments[index].primary,
                    resourceIdentity: url.absoluteString
                )
                let view = InlineMessageImageView(
                    frame: rect,
                    primary: attachments[index].primary,
                    url: url,
                    isSensitive: attachments[index].isSensitive && !attachments[index].isSensitiveRevealed,
                    representedRequest: request
                )
                self.contentViews.append(view)
                view.contentMode = .scaleAspectFill
//                view.layer.masksToBounds = true
//                view.layer.borderColor = UIColor.black.withAlphaComponent(0.1).cgColor
//                view.layer.borderWidth = 1
//                view.layer.cornerRadius = 7
//                view.layer.masksToBounds = true
                self.addSubview(view)
                self.views.append(view)
            } else {
                
            }
            
        }
        refreshThumbnailBindings()
    }

    func updateContent(
        _ attachments: [ImageAttachment],
        representedBy containerPrimary: String = ""
    ) {
        if attachments.isEmpty {
            resetState()
            return
        }

        guard self.views.map(\.primary) == attachments.map(\.primary),
              self.views.count == attachments.count else {
            configure(attachments, representedBy: containerPrimary)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            guard let url = item.url else { return }
            let view = self.views[index]
            let request = InlineAttachmentRepresentedRequest(
                containerPrimary: containerPrimary,
                referencePrimary: item.primary,
                resourceIdentity: url.absoluteString
            )
            view.frame = rect
            view.primary = item.primary
            view.isSensitive = item.isSensitive && !item.isSensitiveRevealed
            view.representedRequest = request
            view.url = url
        }
        refreshThumbnailBindings()
    }

    func refreshThumbnailBindings() {
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        let style = ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        views.forEach { view in
            guard view.frame.width > 0, view.frame.height > 0 else { return }
            let request = ChatThumbnailRequest(
                url: view.url,
                displaySize: ChatCollectionPrefetchSize(
                    width: Double(view.frame.width),
                    height: Double(view.frame.height)
                ),
                scale: scale,
                traitStyle: style
            )
            let consumer = ChatThumbnailConsumer(
                identity: ChatCollectionPrefetchIdentity(
                    kind: .image,
                    messagePrimary: view.representedRequest.containerPrimary,
                    referencePrimary: view.primary
                ),
                role: .visible(view.visibleConsumerID)
            )
            guard view.representedThumbnailRequest != request ||
                    view.representedThumbnailConsumer != consumer else {
                return
            }

            view.cancelThumbnailBinding()
            view.image = nil
            view.representedThumbnailRequest = request
            view.representedThumbnailConsumer = consumer
            view.thumbnailSubscription = thumbnailPipeline.acquire(
                request,
                consumer: consumer
            ) { [weak view] result in
                guard let view,
                      view.representedThumbnailRequest == request,
                      view.representedThumbnailConsumer == consumer,
                      case .success(let delivery) = result else {
                    return
                }
                view.image = delivery.image
            }
        }
    }
    
    func handleTouch(at point: CGPoint, callback: (([URL], URL, String, Bool) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        let urls = views.compactMap { $0.url }
        views.forEach {
            item in
            if !isMyTouch {
                if item.frame.contains(point) {
                    callback?(urls, item.url, item.primary, item.isSensitive)
                    isMyTouch = true
                }
            }
        }
        return isMyTouch
    }
}
