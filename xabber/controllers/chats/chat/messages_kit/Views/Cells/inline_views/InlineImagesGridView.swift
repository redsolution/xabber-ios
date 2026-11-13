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
            case awaitingConsent
        }
        
        var primary: String {
            didSet { accessibilityIdentifier = primary.isEmpty ? nil : "chat.attachment.image.\(Data(primary.utf8).base64EncodedString())" }
        }
        /// Resource used by the bounded thumbnail pipeline.
        var url: URL?
        /// First-choice bounded preview. Kept separate from `url` so a failed
        /// preview can fall back once without update passes rearming it.
        private(set) var preferredThumbnailURL: URL?
        /// Full source retained for gallery/open/download callbacks.
        var sourceURL: URL?
        var encryptedAttachment: ChatEncryptedAttachmentDescriptor?
        var representedRequest: InlineAttachmentRepresentedRequest
        var representedThumbnailRequest: ChatThumbnailRequest?
        var representedThumbnailConsumer: ChatThumbnailConsumer?
        var thumbnailSubscription: ChatThumbnailSubscription?
        let visibleConsumerID = UUID()
        private(set) var thumbnailPresentationState: ThumbnailPresentationState = .loading
        private(set) var consentURL: URL?
        private(set) var lastThumbnailError: ChatThumbnailPipelineError?
        var onRequestConsent: (() -> Void)?
        private var didAttemptFullSourceFallback = false
        var isSensitive: Bool {
            didSet {
                updateSensitiveAppearance()
            }
        }
        
        private var sensitiveOverlay: SensitiveMediaOverlayView?
        private lazy var consentLabel: UILabel = {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .label
            label.backgroundColor = .systemBackground
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            label.isHidden = true
            return label
        }()

        var hasSensitiveOverlay: Bool {
            sensitiveOverlay != nil
        }
        
        init(
            frame: CGRect,
            primary: String,
            url: URL?,
            sourceURL: URL?,
            isSensitive: Bool,
            representedRequest: InlineAttachmentRepresentedRequest
        ) {
            self.primary = primary
            self.url = url
            self.preferredThumbnailURL = url
            self.sourceURL = sourceURL
            self.isSensitive = isSensitive
            self.representedRequest = representedRequest
            super.init(frame: frame)
            accessibilityIdentifier = primary.isEmpty ? nil : "chat.attachment.image.\(Data(primary.utf8).base64EncodedString())"
            setup()
            updateSensitiveAppearance()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setup() {
            self.layer.masksToBounds = true
            addSubview(consentLabel)
            NSLayoutConstraint.activate([
                consentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                consentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                consentLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
            ])
            showLoadingPlaceholder()
        }

        func showLoadingPlaceholder() {
            clearConsent()
            lastThumbnailError = nil
            thumbnailPresentationState = .loading
            contentMode = .center
            tintColor = .tertiaryLabel
            backgroundColor = .secondarySystemBackground
            image = UIImage(systemName: "photo")
            updateSensitiveAppearance()
        }

        func showThumbnail(_ image: UIImage) {
            clearConsent()
            thumbnailPresentationState = .ready
            contentMode = .scaleAspectFill
            backgroundColor = .clear
            self.image = image
            updateSensitiveAppearance()
        }

        func showUnavailablePlaceholder(error: ChatThumbnailPipelineError? = nil) {
            clearConsent()
            lastThumbnailError = error
            thumbnailPresentationState = .unavailable
            contentMode = .center
            tintColor = .secondaryLabel
            backgroundColor = .secondarySystemBackground
            image = UIImage(systemName: "photo.badge.exclamationmark")
                ?? UIImage(systemName: "photo")
            updateSensitiveAppearance()
        }

        func showConsentPlaceholder(for url: URL) {
            if thumbnailPresentationState != .ready {
                contentMode = .center
                backgroundColor = .secondarySystemBackground
                image = nil
            }
            thumbnailPresentationState = .awaitingConsent
            consentURL = url
            consentLabel.text = ExternalImageConsent.title
            consentLabel.isHidden = false
            isAccessibilityElement = true
            accessibilityLabel = ExternalImageConsent.title
            accessibilityTraits.insert(.button)
            bringSubviewToFront(consentLabel)
        }

        private func clearConsent() {
            consentURL = nil
            onRequestConsent = nil
            consentLabel.isHidden = true
            isAccessibilityElement = false
            accessibilityLabel = nil
            accessibilityTraits.remove(.button)
        }

        override func accessibilityActivate() -> Bool {
            guard let onRequestConsent else { return super.accessibilityActivate() }
            onRequestConsent()
            return true
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
                if consentURL != nil {
                    bringSubviewToFront(consentLabel)
                }
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

        func updateThumbnailResources(
            preferredURL: URL?,
            sourceURL: URL?
        ) {
            guard preferredThumbnailURL != preferredURL ||
                    self.sourceURL != sourceURL else {
                return
            }
            cancelThumbnailBinding()
            preferredThumbnailURL = preferredURL
            self.sourceURL = sourceURL
            url = preferredURL
            didAttemptFullSourceFallback = false
            showLoadingPlaceholder()
        }

        func beginFullSourceFallback() -> Bool {
            guard !didAttemptFullSourceFallback,
                  let preferredThumbnailURL,
                  let scheme = preferredThumbnailURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let sourceURL,
                  sourceURL != preferredThumbnailURL else {
                return false
            }
            didAttemptFullSourceFallback = true
            url = sourceURL
            return true
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: .privacyProxyAvailabilityDidChange, object: nil)
        guard window != nil else { return }
        center.addObserver(self, selector: #selector(proxyAvailabilityDidChange),
                           name: .privacyProxyAvailabilityDidChange, object: nil)
        retryUnavailableImagesThroughProxy()
    }

    @objc private func proxyAvailabilityDidChange(_ notification: Notification) {
        guard notification.userInfo?["owner"] as? String == mediaOwner else { return }
        retryUnavailableImagesThroughProxy()
    }

    private func retryUnavailableImagesThroughProxy() {
        guard PrivacyProxyMediaRouter.shared.canResolveImagesThroughProxy(owner: mediaOwner),
              case .reachable = AccountManager.shared.find(for: mediaOwner)?.disco.privacyProxyAvailability else { return }
        for view in views where view.consentURL != nil || view.lastThumbnailError == .loadFailed {
            guard let url = view.consentURL ?? view.url else { continue }
            view.cancelThumbnailBinding()
            view.url = url
        }
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
        representedBy containerPrimary: String = "",
        owner: String = ""
    ) {
//        subviews.forEach { $0.removeFromSuperview() }
        resetState()
        mediaOwner = owner
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            let item = attachments[index]
            let presentationURL = item.previewUrl ?? item.url
            let request = InlineAttachmentRepresentedRequest(
                containerPrimary: containerPrimary,
                referencePrimary: item.primary,
                resourceIdentity: presentationURL?.absoluteString ?? "unavailable:\(item.primary)"
            )
            let view = InlineMessageImageView(
                frame: rect,
                primary: item.primary,
                url: presentationURL,
                sourceURL: item.url,
                isSensitive: item.isSensitive && !item.isSensitiveRevealed,
                representedRequest: request
            )
            view.encryptedAttachment = item.encryptedAttachment
            self.contentViews.append(view)
            self.addSubview(view)
            self.views.append(view)
        }
        refreshThumbnailBindings()
    }

    func updateContent(
        _ attachments: [ImageAttachment],
        representedBy containerPrimary: String = "",
        owner: String = ""
    ) {
        if attachments.isEmpty {
            resetState()
            return
        }

        mediaOwner = owner
        guard self.views.map(\.primary) == attachments.map(\.primary),
              self.views.count == attachments.count else {
            configure(attachments, representedBy: containerPrimary, owner: owner)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            let view = self.views[index]
            let presentationURL = item.previewUrl ?? item.url
            let request = InlineAttachmentRepresentedRequest(
                containerPrimary: containerPrimary,
                referencePrimary: item.primary,
                resourceIdentity: presentationURL?.absoluteString ?? "unavailable:\(item.primary)"
            )
            view.frame = rect
            view.primary = item.primary
            view.encryptedAttachment = item.encryptedAttachment
            view.isSensitive = item.isSensitive && !item.isSensitiveRevealed
            view.representedRequest = request
            view.updateThumbnailResources(
                preferredURL: presentationURL,
                sourceURL: item.url
            )
        }
        refreshThumbnailBindings()
    }

    private var mediaOwner = ""

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
                traitStyle: style,
                encryptedAttachment: url == view.sourceURL ? view.encryptedAttachment : nil,
                owner: mediaOwner
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
            let subscription = thumbnailPipeline.acquire(
                request,
                consumer: consumer
            ) { [weak self, weak view] result in
                guard let self, let view,
                      view.representedThumbnailRequest == request,
                      view.representedThumbnailConsumer == consumer else {
                    return
                }
                switch result {
                case .success(let delivery):
                    view.showThumbnail(delivery.image)
                    if let sourceURL = view.sourceURL, sourceURL != url,
                       PrivacyProxyMediaRouter.shared.imageRequiresConsent(sourceURL, owner: request.owner) {
                        self.showConsentPlaceholder(in: view, for: sourceURL)
                    }
                case .failure(let error):
                    if error == .authenticationFailed {
                        view.showUnavailablePlaceholder(error: error)
                    } else if view.beginFullSourceFallback() {
                        self.refreshThumbnailBindings()
                    } else if error == .loadFailed,
                              PrivacyProxyMediaRouter.shared.canRequestDirectImage(url, owner: request.owner) {
                        self.showConsentPlaceholder(in: view, for: url)
                    } else {
                        view.showUnavailablePlaceholder(error: error)
                    }
                }
            }
            if view.representedThumbnailRequest == request,
               view.representedThumbnailConsumer == consumer {
                view.thumbnailSubscription = subscription
            } else {
                // `acquire` may synchronously fail (for example, queue
                // overflow) and start the one-shot full-source fallback.
                // Never let the obsolete preview token overwrite that newer
                // binding when the outer call returns.
                subscription.cancel()
            }
        }
    }

    private func showConsentPlaceholder(in view: InlineMessageImageView, for url: URL) {
        view.showConsentPlaceholder(for: url)
        view.onRequestConsent = { [weak self, weak view] in
            guard let self, let view else { return }
            self.requestDirectImage(url, in: view)
        }
    }

    private func requestDirectImage(_ url: URL, in view: InlineMessageImageView) {
        let owner = mediaOwner
        let request = view.representedRequest
        let encryptedAttachment = view.encryptedAttachment
        ExternalImageConsent.present(for: url, owner: owner, from: view, shouldGrant: { [weak self, weak view] in
            guard let self, let view else { return false }
            return self.mediaOwner == owner &&
                self.views.contains { $0 === view } &&
                view.representedRequest == request &&
                view.encryptedAttachment == encryptedAttachment &&
                (view.sourceURL == url || view.url == url)
        }) { [weak self, weak view] in
            guard let self, let view else { return }
            view.cancelThumbnailBinding()
            view.url = url
            self.refreshThumbnailBindings()
        }
    }
    
    func handleTouch(at point: CGPoint, callback: (([URL], URL, String, Bool) -> Void)?) -> Bool {
        guard let item = views.first(where: { $0.frame.contains(point) }) else { return false }
        if let consentURL = item.consentURL,
           PrivacyProxyMediaRouter.shared.canRequestDirectImage(consentURL, owner: mediaOwner) {
            requestDirectImage(consentURL, in: item)
            return true
        }
        guard let url = item.sourceURL else { return false }
        guard item.lastThumbnailError != .authenticationFailed else { return true }
        if item.url != url || item.thumbnailPresentationState != .ready,
           PrivacyProxyMediaRouter.shared.imageRequiresConsent(url, owner: mediaOwner) {
            requestDirectImage(url, in: item)
            return true
        }
        callback?(views.compactMap(\.sourceURL), url, item.primary, item.isSensitive)
        return true
    }
}
