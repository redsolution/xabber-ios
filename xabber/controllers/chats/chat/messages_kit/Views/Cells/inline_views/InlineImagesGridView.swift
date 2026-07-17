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
        enum ThumbnailPresentationState: Equatable {
            case loading
            case ready
            case unavailable
        }
        
        var primary: String
        var url: URL?
        var representedRequest: InlineAttachmentRepresentedRequest
        var representedThumbnailRequest: ChatThumbnailRequest?
        var representedThumbnailConsumer: ChatThumbnailConsumer?
        var thumbnailSubscription: ChatThumbnailSubscription?
        let visibleConsumerID = UUID()
        private(set) var thumbnailPresentationState: ThumbnailPresentationState = .loading
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
            url: URL?,
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
            showLoadingPlaceholder()
        }

        func showLoadingPlaceholder() {
            thumbnailPresentationState = .loading
            contentMode = .center
            tintColor = .tertiaryLabel
            backgroundColor = .secondarySystemBackground
            image = UIImage(systemName: "photo")
            updateSensitiveAppearance()
        }

        func showThumbnail(_ image: UIImage) {
            thumbnailPresentationState = .ready
            contentMode = .scaleAspectFill
            backgroundColor = .clear
            self.image = image
            updateSensitiveAppearance()
        }

        func showUnavailablePlaceholder() {
            thumbnailPresentationState = .unavailable
            contentMode = .center
            tintColor = .secondaryLabel
            backgroundColor = .secondarySystemBackground
            image = UIImage(systemName: "photo.badge.exclamationmark")
                ?? UIImage(systemName: "photo")
            updateSensitiveAppearance()
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
            let item = attachments[index]
            let request = InlineAttachmentRepresentedRequest(
                containerPrimary: containerPrimary,
                referencePrimary: item.primary,
                resourceIdentity: item.url?.absoluteString ?? "unavailable:\(item.primary)"
            )
            let view = InlineMessageImageView(
                frame: rect,
                primary: item.primary,
                url: item.url,
                isSensitive: item.isSensitive && !item.isSensitiveRevealed,
                representedRequest: request
            )
            self.contentViews.append(view)
            self.addSubview(view)
            self.views.append(view)
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
            let view = self.views[index]
            let request = InlineAttachmentRepresentedRequest(
                containerPrimary: containerPrimary,
                referencePrimary: item.primary,
                resourceIdentity: item.url?.absoluteString ?? "unavailable:\(item.primary)"
            )
            view.frame = rect
            view.primary = item.primary
            view.isSensitive = item.isSensitive && !item.isSensitiveRevealed
            view.representedRequest = request
            view.url = item.url
        }
        refreshThumbnailBindings()
    }

    func refreshThumbnailBindings() {
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        let style = ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        views.forEach { view in
            guard view.frame.width > 0, view.frame.height > 0 else { return }
            guard let url = view.url else {
                view.cancelThumbnailBinding()
                view.showUnavailablePlaceholder()
                return
            }
            let request = ChatThumbnailRequest(
                url: url,
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
            view.showLoadingPlaceholder()
            view.representedThumbnailRequest = request
            view.representedThumbnailConsumer = consumer
            view.thumbnailSubscription = thumbnailPipeline.acquire(
                request,
                consumer: consumer
            ) { [weak view] result in
                guard let view,
                      view.representedThumbnailRequest == request,
                      view.representedThumbnailConsumer == consumer else {
                    return
                }
                switch result {
                case .success(let delivery):
                    view.showThumbnail(delivery.image)
                case .failure:
                    view.showUnavailablePlaceholder()
                }
            }
        }
    }
    
    func handleTouch(at point: CGPoint, callback: (([URL], URL, String, Bool) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        let urls = views.compactMap(\.url)
        views.forEach {
            item in
            if !isMyTouch {
                if item.frame.contains(point), let url = item.url {
                    callback?(urls, url, item.primary, item.isSensitive)
                    isMyTouch = true
                }
            }
        }
        return isMyTouch
    }
}
