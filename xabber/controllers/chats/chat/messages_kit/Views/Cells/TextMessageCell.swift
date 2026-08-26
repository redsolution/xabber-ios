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
import MapKit
import MaterialComponents.MDCPalettes

struct TextMessageCellAvatarIdentity: Equatable {
    let messagePrimary: String
    let avatarUrl: String
    let userId: String
    let jid: String
    let owner: String
    let displayName: String
    let request: ChatAvatarRequest
}

class InlineLocationsGridView: InlineAttachmentView {
    final class LocationView: UIView {
        private let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.16)
            return view
        }()

        private let pinView: UIImageView = {
            let view = UIImageView(image: UIImage(systemName: "mappin.circle.fill"))
            view.tintColor = MDCPalette.red.tint500
            view.contentMode = .scaleAspectFit
            return view
        }()

        private let addressLabel: UILabel = {
            let label = UILabel()
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            label.layer.cornerRadius = 10
            label.layer.masksToBounds = true
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.textAlignment = .center
            return label
        }()

        var location: LocationAttachment
        private let snapshotPipeline: ChatLocationSnapshotServing
        private var screenScale: Double
        private var traitStyle: ChatThumbnailTraitStyle
        private var representedContainerPrimary = ""
        private(set) var representedSnapshotRequest: ChatLocationSnapshotRequest?
        private var snapshotSubscription: ChatLocationSnapshotSubscription?
        private var snapshotDeliveryToken: UUID?
        private var isSnapshotWorkEnabled = true
        private var snapshotNeedsResume = false

        var renderedSnapshotImage: UIImage? {
            imageView.image
        }

        init(
            frame: CGRect,
            location: LocationAttachment,
            snapshotPipeline: ChatLocationSnapshotServing,
            screenScale: Double,
            traitStyle: ChatThumbnailTraitStyle
        ) {
            self.location = location
            self.snapshotPipeline = snapshotPipeline
            self.screenScale = max(1, screenScale)
            self.traitStyle = traitStyle
            super.init(frame: frame)
            setup()
            update(location, representedBy: "")
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func updateRenderingEnvironment(
            screenScale: Double,
            traitStyle: ChatThumbnailTraitStyle
        ) {
            let nextScale = max(1, screenScale)
            guard self.screenScale != nextScale || self.traitStyle != traitStyle else { return }
            snapshotSubscription?.cancel()
            snapshotSubscription = nil
            snapshotDeliveryToken = nil
            representedSnapshotRequest = nil
            self.screenScale = nextScale
            self.traitStyle = traitStyle
            snapshotNeedsResume = !isSnapshotWorkEnabled
            setNeedsLayout()
        }

        private func setup() {
            clipsToBounds = true
            addSubview(imageView)
            addSubview(pinView)
            addSubview(addressLabel)
            accessibilityTraits = [.button, .image]
        }

        func update(
            _ location: LocationAttachment,
            representedBy containerPrimary: String = ""
        ) {
            let previousIdentity = representedAttachmentIdentity
            let nextIdentity = InlineAttachmentRepresentedRequest(
                containerPrimary: containerPrimary,
                referencePrimary: location.primary,
                resourceIdentity: [
                    String(location.coordinate.latitude),
                    String(location.coordinate.longitude),
                    location.snapshotURL?.absoluteString ?? ""
                ].joined(separator: "|")
            )
            if previousIdentity != nextIdentity {
                snapshotSubscription?.cancel()
                snapshotSubscription = nil
                snapshotDeliveryToken = nil
                representedSnapshotRequest = nil
                if previousIdentity?.resourceIdentity != nextIdentity.resourceIdentity {
                    imageView.image = nil
                }
            }
            self.location = location
            representedContainerPrimary = containerPrimary
            representedAttachmentIdentity = nextIdentity
            addressLabel.text = location.address?.isNotEmpty == true ? location.address : location.geoURI
            accessibilityLabel = addressLabel.text
            setNeedsLayout()
        }

        func resetState() {
            snapshotSubscription?.cancel()
            snapshotSubscription = nil
            snapshotDeliveryToken = nil
            representedSnapshotRequest = nil
            representedContainerPrimary = ""
            representedAttachmentIdentity = nil
            snapshotNeedsResume = false
            imageView.image = nil
            addressLabel.text = nil
            accessibilityLabel = nil
        }

        func cancelOffscreenWork() {
            isSnapshotWorkEnabled = false
            guard snapshotSubscription != nil else { return }
            snapshotSubscription?.cancel()
            snapshotSubscription = nil
            snapshotDeliveryToken = nil
            representedSnapshotRequest = nil
            snapshotNeedsResume = true
        }

        func resumeOnscreenWork() {
            isSnapshotWorkEnabled = true
            snapshotNeedsResume = false
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            pinView.frame = CGRect(
                x: (bounds.width - 34) / 2,
                y: (bounds.height - 34) / 2,
                width: 34,
                height: 34
            )
            let labelHeight: CGFloat = 28
            addressLabel.frame = CGRect(
                x: 10,
                y: bounds.height - labelHeight - 10,
                width: max(0, bounds.width - 20),
                height: labelHeight
            )
            loadSnapshotIfNeeded()
        }

        private func loadSnapshotIfNeeded() {
            guard isSnapshotWorkEnabled,
                  bounds.width > 1,
                  bounds.height > 1 else {
                return
            }
            let request = snapshotRequest(
                for: location,
                size: bounds.size
            )
            guard representedSnapshotRequest != request else { return }
            snapshotSubscription?.cancel()
            representedSnapshotRequest = request
            let deliveryToken = UUID()
            snapshotDeliveryToken = deliveryToken
            let consumerIdentity = ChatCollectionPrefetchIdentity(
                kind: .locationSnapshot,
                messagePrimary: representedContainerPrimary.isEmpty
                    ? location.primary
                    : representedContainerPrimary,
                referencePrimary: location.primary
            )
            let subscription = snapshotPipeline.acquire(
                request,
                consumer: ChatLocationSnapshotConsumer(
                    identity: consumerIdentity,
                    role: .visible(UUID())
                )
            ) { [weak self, request, deliveryToken] result in
                guard let self,
                      self.representedSnapshotRequest == request,
                      self.snapshotDeliveryToken == deliveryToken,
                      case .success(let delivery) = result else {
                    return
                }
                self.snapshotSubscription = nil
                self.snapshotDeliveryToken = nil
                self.snapshotNeedsResume = false
                self.imageView.image = delivery.image
            }
            if snapshotDeliveryToken == deliveryToken {
                snapshotSubscription = subscription
            } else {
                subscription.cancel()
            }
        }

        private func snapshotRequest(
            for location: LocationAttachment,
            size: CGSize
        ) -> ChatLocationSnapshotRequest {
            ChatLocationSnapshotRequest(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                sourceURL: location.snapshotURL,
                displaySize: ChatCollectionPrefetchSize(
                    width: Double(size.width),
                    height: Double(size.height)
                ),
                scale: screenScale,
                mapStyle: .standard,
                traitStyle: traitStyle
            )
        }

        private var representedAttachmentIdentity: InlineAttachmentRepresentedRequest?
    }

    var views: [LocationView] = []
    private let snapshotPipeline: ChatLocationSnapshotServing
    private var screenScale: Double
    private var traitStyle: ChatThumbnailTraitStyle
    private var isSnapshotWorkEnabled = true

    init(
        snapshotPipeline: ChatLocationSnapshotServing = ChatLocationSnapshotPipeline.shared,
        screenScale: Double = Double(UIScreen.main.scale),
        traitStyle: ChatThumbnailTraitStyle = ChatThumbnailTraitStyle(UIScreen.main.traitCollection.userInterfaceStyle)
    ) {
        self.snapshotPipeline = snapshotPipeline
        self.screenScale = max(1, screenScale)
        self.traitStyle = traitStyle
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateRenderingEnvironment(
        screenScale: Double,
        traitStyle: ChatThumbnailTraitStyle
    ) {
        let nextScale = max(1, screenScale)
        guard self.screenScale != nextScale || self.traitStyle != traitStyle else { return }
        self.screenScale = nextScale
        self.traitStyle = traitStyle
        views.forEach {
            $0.updateRenderingEnvironment(screenScale: nextScale, traitStyle: traitStyle)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRenderingEnvironment(
            screenScale: Double(window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        updateRenderingEnvironment(
            screenScale: Double(window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        )
    }

    func resetState() {
        views.forEach { view in
            view.resetState()
            view.removeFromSuperview()
        }
        views.removeAll()
        contentViews.removeAll()
        grid.removeAll()
    }

    func cancelOffscreenWork() {
        isSnapshotWorkEnabled = false
        views.forEach { $0.cancelOffscreenWork() }
    }

    func resumeOnscreenWork() {
        isSnapshotWorkEnabled = true
        views.forEach { $0.resumeOnscreenWork() }
    }

    func prepareGrid(_ attachments: [LocationAttachment]) -> [CGRect] {
        guard attachments.isNotEmpty else {
            return []
        }
        let width = frame.width
        var offset: CGFloat = 0
        return attachments.map { _ in
            defer { offset += width + ChatLocationAttachmentLayoutPolicy.itemSpacing }
            return CGRect(x: 0, y: offset, width: width, height: width)
        }
    }

    func configure(
        _ attachments: [LocationAttachment],
        representedBy containerPrimary: String = ""
    ) {
        resetState()

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let view = LocationView(
                frame: rect,
                location: attachments[index],
                snapshotPipeline: snapshotPipeline,
                screenScale: screenScale,
                traitStyle: traitStyle
            )
            if !isSnapshotWorkEnabled {
                view.cancelOffscreenWork()
            }
            addSubview(view)
            view.update(attachments[index], representedBy: containerPrimary)
            views.append(view)
            contentViews.append(view)
        }
    }

    func updateContent(
        _ attachments: [LocationAttachment],
        representedBy containerPrimary: String = ""
    ) {
        if attachments.isEmpty {
            resetState()
            return
        }

        guard views.map(\.location.primary) == attachments.map(\.primary),
              views.count == attachments.count else {
            configure(attachments, representedBy: containerPrimary)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            views[index].frame = rect
            views[index].update(
                attachments[index],
                representedBy: containerPrimary
            )
        }
    }

    func handleTouch(at point: CGPoint, callback: ((LocationAttachment) -> Void)?) -> Bool {
        for item in views where item.frame.contains(point) {
            callback?(item.location)
            return true
        }
        return false
    }
}

public class TextMessageCell: MessageContentCell, ChatOffscreenWorkManaging {
    
    let offsetBetweenForwards: CGFloat = 2
    
    let timeMarker: TimeMarkerView = {
        let marker = TimeMarkerView(frame: .zero)
        
        marker.setupSubviews()
        
        return marker
    }()
    
    let authorView: MessageLabel = {
        let view = MessageLabel()
        
        return view
    }()
    
    var forwardsContainer: InlineForwardsContainerView = {
        let view = InlineForwardsContainerView(frame: .zero)
//        view.backgroundColor = .orange
        return view
    }()
    
    var filesView: InlineFilesGridView = {
        let view = InlineFilesGridView()
                
//        view.backgroundColor = .brown
        
        return view
    }()
    
    var audiosView: InlineAudiosGridView = {
        let view = InlineAudiosGridView()
        
//        view.backgroundColor = .yellow
        
        return view
    }()
    
    var videosView: InlineVideosGridView = {
        let view = InlineVideosGridView()
                
        return view
    }()

    var locationsView: InlineLocationsGridView = {
        let view = InlineLocationsGridView()

        return view
    }()

    var contactsView: InlineContactsGridView = {
        let view = InlineContactsGridView()

        return view
    }()
    
    var imagesView: InlineImagesGridView = {
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

    let warningLabel: InsetLabel = {
        let label = InsetLabel()
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemOrange
        label.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        label.textInsets = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    var avatarPipeline: ChatAvatarServing = ChatAvatarPipeline.shared
    private(set) var representedAvatarIdentity: TextMessageCellAvatarIdentity?
    private var avatarSubscription: ChatAvatarSubscription?
    private var avatarDeliveryToken: UUID?
    private var isAvatarWorkEnabled = true
    private var avatarNeedsResume = false
    
    
        
    override weak var delegate: MessageCellDelegate? {
        didSet {
            messageLabel.delegate = delegate
        }
    }
    
    
    public override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes else {
            return
        }
        // During a structural collection update UIKit can briefly deliver the
        // new row's attributes to the old visible cell at the same index path.
        // Keep the base cell transition, but never apply another message's
        // text/media geometry to the represented content.
        guard messagePrimary.isEmpty || attributes.messagePrimary == messagePrimary else {
            return
        }
        layoutAuthorView(with: attributes)
        layoutForwardsContainer(with: attributes)
        layoutImagesView(with: attributes)
        layoutVideosView(with: attributes)
        layoutLocationsView(with: attributes)
        layoutContactsView(with: attributes)
        layoutAudiosView(with: attributes)
        layoutFilesView(with: attributes)
        layoutLabelView(with: attributes)
        layoutWarningLabel(with: attributes)
        layoutTimeMarker(with: attributes)
        ChatMessageFrameGeometryValidator.assertValid(
            frames: [
                .init(name: "author", frame: authorView.frame),
                .init(name: "forwards", frame: forwardsContainer.frame),
                .init(name: "images", frame: imagesView.frame),
                .init(name: "videos", frame: videosView.frame),
                .init(name: "locations", frame: locationsView.frame),
                .init(name: "contacts", frame: contactsView.frame),
                .init(name: "audios", frame: audiosView.frame),
                .init(name: "files", frame: filesView.frame),
                .init(name: "text", frame: labelContainer.frame),
                .init(name: "warning", frame: warningLabel.frame),
                .init(name: "time", frame: timeMarker.frame)
            ],
            containerBounds: CGRect(origin: .zero, size: attributes.messageContainerSize)
        )
    }
    
    func layoutAuthorView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offset: CGFloat = 0
        self.authorView.frame = CGRect(
            origin: CGPoint(
                x: attributes.messageLabelInsets.left,
                y: offset
            ),
            size: attributes.authorInlineSize
        )
    }
    
    func layoutTimeMarker(with attributes: MessagesCollectionViewLayoutAttributes) {
        var frame = CGRect(
            origin: CGPoint(
                x: attributes.messageContainerSize.width - attributes.timeMarkerSize.width - attributes.timeMarkerInsets.right - attributes.tailWidth - attributes.messageContainerPadding.right - attributes.messageContainerMargin.right,
                y: attributes.messageContainerSize.height - attributes.timeMarkerSize.height - attributes.timeMarkerInsets.bottom - attributes.messageContainerPadding.bottom - attributes.messageContainerMargin.bottom - 2
            ),
            size: attributes.timeMarkerSize
        )
        if attributes.timeMarkerWithBackplate {
            frame = CGRect(
                origin: CGPoint(
                    x: attributes.messageContainerSize.width - attributes.timeMarkerSize.width - attributes.timeMarkerInsets.right - attributes.tailWidth - attributes.messageContainerPadding.right - attributes.messageContainerMargin.right - 3,
                    y: attributes.messageContainerSize.height - attributes.timeMarkerSize.height - attributes.timeMarkerInsets.bottom - attributes.messageContainerPadding.bottom - attributes.messageContainerMargin.bottom - 7
                ),
                size: attributes.timeMarkerSize
            )
        }
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
//                if attributes.isImageMessage {
                    //radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
                    radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.timestamp.getRadiusFor(index: attributes.cornerRadius)
//                }
                
            default:
                break
        }
        self.timeMarker.update(frame: frame, indicator: attributes.timeMarkerIndicator, radius: radius.leftBottom)
    }
    
    func layoutForwardsContainer(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.forwardsContainer.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 0, y:0),
            size: attributes.forwardsContainerViewSize.padding(width: 0, height: 4)
        )
        self.forwardsContainer.layout(with: attributes)
    }
    
    func layoutImagesView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.imagesView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 2, y: 2),
            size: attributes.imagesInlineViewSize.padding(width: 4, height: 4)
        )
//        let radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: "16")
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
//                if attributes.isImageMessage {
//                    
//                } else {
//                    
//                }
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.image.getRadiusFor(index: attributes.cornerRadius)
            default:
                break
        }
        self.imagesView.configure(
            side: .right,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
        self.imagesView.refreshThumbnailBindings()
    }
    
    func layoutVideosView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.videosView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 2, y: 2),
            size: attributes.videosInlineViewSize.padding(width: 4, height: 4)
        )
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.bubble.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.bubble.getRadiusFor(index: attributes.cornerRadius)
            default:
                break
        }
        self.videosView.configure(
            side: .right,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
        self.videosView.refreshThumbnailBindings()
    }
    
    func layoutAudiosView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.locationsInlineViewSize,
            attributes.contactsInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.audiosView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: attributes.audioInlineViewSize
        )
    }

    func layoutLocationsView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.locationsView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset).padding(x: 2, y: 2),
            size: attributes.locationsInlineViewSize.padding(width: 4, height: 4)
        )
        var radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
        switch attributes.tail {
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubble.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.bubbles.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.curvy.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.stripes.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.transparent.image.image.getRadiusFor(index: attributes.cornerRadius)
            case MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue:
                radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.wedge.image.image.getRadiusFor(index: attributes.cornerRadius)
            default:
                break
        }
        self.locationsView.configure(
            side: .right,
            radiusLU: radius.leftUpper,
            radiusRU: radius.rightUpper,
            radiusRB: radius.rightBottom,
            radiusLB: radius.leftBottom
        )
    }

    func layoutContactsView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.locationsInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.contactsView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: attributes.contactsInlineViewSize
        )
    }
    
    func layoutFilesView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.locationsInlineViewSize,
            attributes.contactsInlineViewSize,
            attributes.audioInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        self.filesView.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: attributes.filesInlineViewSize
        )
    }
    
    func layoutLabelView(with attributes: MessagesCollectionViewLayoutAttributes) {
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.locationsInlineViewSize,
            attributes.contactsInlineViewSize,
            attributes.audioInlineViewSize,
            attributes.filesInlineViewSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        labelContainer.frame = CGRect(
            origin: CGPoint(x: 0, y: offset),
            size: CGSize(
                width: attributes.textInlineViewSize.width + attributes.messageLabelInsets.horizontal,
                height: attributes.textInlineViewSize.height + attributes.messageLabelInsets.vertical
            )
        )
        messageLabel.frame = CGRect(
            origin: CGPoint(
                x: attributes.messageLabelInsets.left,
                y: attributes.messageLabelInsets.top
            ),
            size: attributes.textInlineViewSize
        )
    }

    func layoutWarningLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        let labelContainerSize = CGSize(
            width: attributes.textInlineViewSize.width + attributes.messageLabelInsets.horizontal,
            height: attributes.textInlineViewSize == .zero ? 0 : attributes.textInlineViewSize.height + attributes.messageLabelInsets.vertical
        )
        let offsetItems = [
            attributes.authorInlineSize,
            attributes.forwardsContainerViewSize,
            attributes.imagesInlineViewSize,
            attributes.videosInlineViewSize,
            attributes.locationsInlineViewSize,
            attributes.contactsInlineViewSize,
            attributes.audioInlineViewSize,
            attributes.filesInlineViewSize,
            labelContainerSize
        ]
        let offset = offsetItems.compactMap { $0.height }.reduce(0, +)
        warningLabel.frame = CGRect(
            origin: CGPoint(x: attributes.messageLabelInsets.left, y: offset),
            size: attributes.warningInlineViewSize
        )
    }
    
    public override func prepareForReuse() {
        
        super.prepareForReuse()
        
        avatarSubscription?.cancel()
        avatarSubscription = nil
        avatarDeliveryToken = nil
        representedAvatarIdentity = nil
        avatarNeedsResume = false
        messagePrimary = ""
        avatarView.image = nil
        avatarView.isHidden = true
        messageLabel.attributedText = nil
        messageLabel.text = nil
        forwardsContainer.resetState()
        resetReusableAttachmentState()
        authorView.text = nil
        warningLabel.text = nil
        warningLabel.isHidden = true
    }
    
    
    override func setupSubviews() {
        super.setupSubviews()
        containerView.addSubview(authorView)
        containerView.addSubview(forwardsContainer)
        containerView.addSubview(imagesView)
        containerView.addSubview(videosView)
        containerView.addSubview(locationsView)
        containerView.addSubview(contactsView)
        containerView.addSubview(audiosView)
        containerView.addSubview(filesView)
        
        containerView.addSubview(labelContainer)
        containerView.addSubview(warningLabel)
        containerView.addSubview(timeMarker)
        labelContainer.addSubview(messageLabel)
    }
    
    var messagePrimary: String = ""

    private lazy var messageLongPressGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressGesture(_:)))
        gesture.delaysTouchesBegan = true
        return gesture
    }()
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        applyTextContent(with: message, at: indexPath, and: messagesCollectionView, reuseInlineViews: true)
    }

    override func reconfigureContent(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        applyTextContent(with: message, at: indexPath, and: messagesCollectionView, reuseInlineViews: true)
    }

    override func reconfigureContent(
        with message: MessageType,
        at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView,
        changeMask: ChatMessageChangeMask
    ) {
        let lightweightMask: ChatMessageChangeMask = [.chrome, .fileTransferState]
        if changeMask.subtracting(lightweightMask).isEmpty {
            if changeMask.contains(.chrome) {
                applyChromeUpdate(with: message, at: indexPath, and: messagesCollectionView)
            }
            if changeMask.contains(.fileTransferState) {
                applyFileTransferStateUpdate(with: message)
            }
            return
        }
        applyTextContent(with: message, at: indexPath, and: messagesCollectionView, reuseInlineViews: true)
    }

    @discardableResult
    override func renderVoiceMessageState(
        referencePrimary: String,
        state: VoiceMessagePlaybackState
    ) -> Bool {
        audiosView.render(state: state, for: referencePrimary) ||
            forwardsContainer.renderVoiceMessageState(
                referencePrimary: referencePrimary,
                state: state
            )
    }

    private func applyChromeUpdate(
        with message: MessageType,
        at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView
    ) {
        messagePrimary = message.primary
        super.reconfigureContent(
            with: message,
            at: indexPath,
            and: messagesCollectionView,
            changeMask: [.chrome]
        )
        warningLabel.text = message.messageWarningText
        warningLabel.isHidden = message.messageWarningText == nil
        timeMarker.configure(
            text: message.timeMarkerText,
            indicator: message.indicator,
            withBackplate: usesTimeMarkerBackplate(for: message)
        )
    }

    private func applyFileTransferStateUpdate(with message: MessageType) {
        messagePrimary = message.primary
        filesView.updateTransferStates(message.files, representedBy: message.primary)
        forwardsContainer.updateFileTransferStates(message.forwards)
    }

    func cancelOffscreenWork() {
        isAvatarWorkEnabled = false
        if avatarSubscription != nil {
            avatarSubscription?.cancel()
            avatarSubscription = nil
            avatarDeliveryToken = nil
            avatarNeedsResume = representedAvatarIdentity != nil
        }
        locationsView.cancelOffscreenWork()
        contactsView.cancelOffscreenWork()
        audiosView.cancelOffscreenWork()
        filesView.cancelOffscreenWork()
        forwardsContainer.cancelOffscreenWork()
    }

    func resumeOnscreenWork() {
        isAvatarWorkEnabled = true
        if avatarNeedsResume, let identity = representedAvatarIdentity {
            startAvatarRequest(identity)
        }
        locationsView.resumeOnscreenWork()
        contactsView.resumeOnscreenWork()
        audiosView.resumeOnscreenWork()
        filesView.resumeOnscreenWork()
        forwardsContainer.resumeOnscreenWork()
    }

    private func applyTextContent(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView, reuseInlineViews: Bool) {
        self.messagePrimary = message.primary
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        messageLabel.configure {
            switch message.kind {
                case .attributedText(let text):
                    messageLabel.attributedText = text
                default:
                    break
            }
        }
        authorView.attributedText = message.attributedAuthor
        warningLabel.text = message.messageWarningText
        warningLabel.isHidden = message.messageWarningText == nil
        let palette = AccountColorManager.shared.palette(for: message.owner)
        self.timeMarker.configure(
            text: message.timeMarkerText,
            indicator: message.indicator,
            withBackplate: usesTimeMarkerBackplate(for: message)
        )
        if reuseInlineViews {
            self.imagesView.updateContent(message.images, representedBy: message.primary)
            self.locationsView.updateContent(message.locations, representedBy: message.primary)
            self.contactsView.updateContent(
                message.contacts,
                palette: palette,
                representedBy: message.primary
            )
            self.filesView.updateContent(
                message.files,
                palette: palette,
                representedBy: message.primary
            )
        } else {
            self.imagesView.configure(message.images, representedBy: message.primary)
            self.locationsView.configure(message.locations, representedBy: message.primary)
            self.contactsView.configure(
                message.contacts,
                palette: palette,
                representedBy: message.primary
            )
            self.filesView.configure(
                message.files,
                palette: palette,
                representedBy: message.primary
            )
        }
        self.audiosView.delegate = delegate
        if reuseInlineViews {
            self.audiosView.updateContent(message.audios, palette: palette)
            self.forwardsContainer.updateContent(message.forwards, palette: palette, delegate: delegate)
            self.videosView.updateContent(message.videos, representedBy: message.primary)
        } else {
            self.audiosView.configure(message.audios, palette: palette)
            self.forwardsContainer.configure(message.forwards, palette: palette, delegate: delegate)
            self.videosView.configure(message.videos, representedBy: message.primary)
        }
        self.imagesView.layer.backgroundColor = MDCPalette.grey.tint100.cgColor
        
        ensureLongPressGestureInstalled()
        configureAvatar(for: message)
    }

    private func usesTimeMarkerBackplate(for message: MessageType) -> Bool {
        guard message.images.isNotEmpty || message.videos.isNotEmpty || message.locations.isNotEmpty,
              message.files.isEmpty,
              message.contacts.isEmpty,
              message.audios.isEmpty,
              case .attributedText(let text) = message.kind else {
            return false
        }
        return text.string.isEmpty
    }

    private func resetReusableAttachmentState() {
        imagesView.resetState()
        videosView.resetState()
        locationsView.resetState()
        contactsView.resetState()
        audiosView.resetState()
        filesView.resetState()
    }

    private func configureAvatar(for message: MessageType) {
        guard message.withAvatar else {
            avatarSubscription?.cancel()
            avatarSubscription = nil
            avatarDeliveryToken = nil
            representedAvatarIdentity = nil
            avatarNeedsResume = false
            avatarView.isHidden = true
            avatarView.image = nil
            return
        }

        avatarView.isHidden = false
        let request = ChatAvatarRequest(
            entityIdentity: message.groupchatAuthorId.isNotEmpty
                ? message.groupchatAuthorId
                : message.jid,
            remoteURL: message.avatarUrl.flatMap(URL.init(string:)),
            displayName: message.groupchatAuthorNickname,
            colorKey: message.groupchatAuthorId.isNotEmpty
                ? message.groupchatAuthorId
                : message.owner,
            displaySize: ChatCollectionPrefetchSize(width: 32, height: 32),
            scale: Double(window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        )
        let identity = TextMessageCellAvatarIdentity(
            messagePrimary: message.primary,
            avatarUrl: message.avatarUrl ?? "",
            userId: message.groupchatAuthorId,
            jid: message.jid,
            owner: message.owner,
            displayName: message.groupchatAuthorNickname,
            request: request
        )
        if representedAvatarIdentity == identity {
            if isAvatarWorkEnabled, avatarNeedsResume {
                startAvatarRequest(identity)
            }
            return
        }
        let previousRequest = representedAvatarIdentity?.request
        avatarSubscription?.cancel()
        avatarSubscription = nil
        avatarDeliveryToken = nil
        representedAvatarIdentity = identity
        if previousRequest != request {
            avatarView.image = nil
        }
        guard isAvatarWorkEnabled else {
            avatarNeedsResume = true
            return
        }
        startAvatarRequest(identity)
    }

    private func startAvatarRequest(_ identity: TextMessageCellAvatarIdentity) {
        avatarNeedsResume = false
        let deliveryToken = UUID()
        avatarDeliveryToken = deliveryToken
        let prefetchIdentity = ChatCollectionPrefetchIdentity(
            kind: .avatar,
            messagePrimary: identity.messagePrimary,
            referencePrimary: identity.userId.isNotEmpty
                ? identity.userId
                : identity.messagePrimary
        )
        let subscription = avatarPipeline.acquire(
            identity.request,
            consumer: ChatAvatarConsumer(
                identity: prefetchIdentity,
                role: .visible(UUID())
            )
        ) { [weak self, identity, deliveryToken] result in
            guard let self,
                  self.representedAvatarIdentity == identity,
                  self.avatarDeliveryToken == deliveryToken,
                  self.isAvatarWorkEnabled else {
                return
            }
            self.avatarSubscription = nil
            self.avatarDeliveryToken = nil
            self.avatarNeedsResume = false
            if case .success(let delivery) = result {
                self.avatarView.image = delivery.image
            }
        }
        if avatarDeliveryToken == deliveryToken {
            avatarSubscription = subscription
        } else {
            subscription.cancel()
        }
    }

    private func ensureLongPressGestureInstalled() {
        guard !(containerView.gestureRecognizers ?? []).contains(where: { $0 === messageLongPressGesture }) else {
            return
        }
        containerView.addGestureRecognizer(messageLongPressGesture)
    }
    
    @objc
    private func handleLongPressGesture(_ sender: UILongPressGestureRecognizer) {
        print("press")
        guard sender.state == .began else { return }
        self.delegate?.onLongTapMessage(cell: self)
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        if self.filesView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.filesView.frame.minX, y: -self.filesView.frame.minY)
            if self.filesView.handleTouch(at: translatedPoint, callback: { url in
                self.delegate?.didTapOnFile(url: url)
            }) {
                return true
            }
        }
        if self.imagesView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.imagesView.frame.minX, y: -self.imagesView.frame.minY)
            if self.imagesView.handleTouch(at: translatedPoint, callback: { (urls, url, referencePrimary, isSensitive) in
                self.delegate?.didTapOnPhoto(message: self.messagePrimary, urls: urls, url: url, referencePrimary: referencePrimary, isSensitive: isSensitive)
            }) {
                return true
            }
        }
        if self.videosView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.videosView.frame.minX, y: -self.videosView.frame.minY)
            if self.videosView.handleTouch(at: translatedPoint, callback: { (_, url, referencePrimary, isSensitive) in
                self.delegate?.didTapOnVideo(message: self.messagePrimary, url: url, referencePrimary: referencePrimary, isSensitive: isSensitive)
            }) {
                return true
            }
        }
        if self.locationsView.frame.contains(touchPoint) {
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
        }
        if self.contactsView.frame.contains(touchPoint) {
            let translatedPoint = touchPoint.translate(x: -self.contactsView.frame.minX, y: -self.contactsView.frame.minY)
            if self.contactsView.handleTouch(at: translatedPoint, callback: { contact in
                self.delegate?.didTapOnContact(message: self.messagePrimary, contact: contact)
            }) {
                return true
            }
        }
        if self.forwardsContainer.frame.contains(touchPoint) {
            let forwardPoint = messageContainerView.convert(touchPoint, to: forwardsContainer)
            if forwardsContainer.handleTouch(at: forwardPoint) {
                return true
            }
        }
        let labelPoint = messageContainerView.convert(touchPoint, to: messageLabel)
        return messageLabel.handleGesture(labelPoint)
    }
    
}
