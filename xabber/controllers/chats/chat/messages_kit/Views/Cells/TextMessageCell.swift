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

protocol TextMessageCellAvatarLoading: AnyObject {
    func loadGroupAvatar(
        url: String,
        userId: String,
        jid: String,
        owner: String,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    )
}

final class DefaultTextMessageCellAvatarLoader: TextMessageCellAvatarLoading {
    func loadGroupAvatar(
        url: String,
        userId: String,
        jid: String,
        owner: String,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) {
        DefaultAvatarManager.shared.getGroupAvatar(
            url: url,
            userId: userId,
            jid: jid,
            owner: owner,
            size: size,
            callback: completion
        )
    }
}

struct TextMessageCellAvatarIdentity: Equatable {
    let messagePrimary: String
    let avatarUrl: String
    let userId: String
    let jid: String
    let owner: String
    let displayName: String
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
        private let snapshotProvider: ChatLocationSnapshotProviding
        private var requestedSnapshotKey: String?

        init(
            frame: CGRect,
            location: LocationAttachment,
            snapshotProvider: ChatLocationSnapshotProviding
        ) {
            self.location = location
            self.snapshotProvider = snapshotProvider
            super.init(frame: frame)
            setup()
            update(location)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            clipsToBounds = true
            addSubview(imageView)
            addSubview(pinView)
            addSubview(addressLabel)
            accessibilityTraits = [.button, .image]
        }

        func update(_ location: LocationAttachment) {
            self.location = location
            requestedSnapshotKey = nil
            imageView.image = location.snapshotURL.flatMap { UIImage(contentsOfFile: $0.path) }
            addressLabel.text = location.address?.isNotEmpty == true ? location.address : location.geoURI
            accessibilityLabel = addressLabel.text
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
            guard imageView.image == nil,
                  bounds.width > 1,
                  bounds.height > 1 else {
                return
            }
            let key = "\(location.primary):\(Int(bounds.width))x\(Int(bounds.height))"
            guard requestedSnapshotKey != key else {
                return
            }
            requestedSnapshotKey = key
            let resolvedLocation = ChatAttachmentResolvedLocation(
                coordinate: AttachmentLocationCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ),
                displayAddress: location.address,
                accuracy: nil
            )
            snapshotProvider.makeSnapshot(
                for: resolvedLocation,
                size: bounds.size
            ) { [weak self, primary = location.primary] result in
                DispatchQueue.main.async {
                    guard let self,
                          self.location.primary == primary,
                          case .success(let url) = result,
                          let image = UIImage(contentsOfFile: url.path) else {
                        return
                    }
                    self.location.snapshotURL = url
                    self.imageView.image = image
                }
            }
        }
    }

    var views: [LocationView] = []
    private let snapshotProvider: ChatLocationSnapshotProviding

    init(snapshotProvider: ChatLocationSnapshotProviding = MapKitChatLocationSnapshotProvider()) {
        self.snapshotProvider = snapshotProvider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    func configure(_ attachments: [LocationAttachment]) {
        views.forEach { $0.removeFromSuperview() }
        views = []
        contentViews.removeAll()

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let view = LocationView(
                frame: rect,
                location: attachments[index],
                snapshotProvider: snapshotProvider
            )
            addSubview(view)
            views.append(view)
            contentViews.append(view)
        }
    }

    func updateContent(_ attachments: [LocationAttachment]) {
        if attachments.isEmpty {
            views.forEach { $0.removeFromSuperview() }
            views = []
            contentViews.removeAll()
            return
        }

        guard views.map(\.location.primary) == attachments.map(\.primary),
              views.count == attachments.count else {
            configure(attachments)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            views[index].frame = rect
            views[index].update(attachments[index])
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

public class TextMessageCell: MessageContentCell {
    
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

    var avatarLoader: TextMessageCellAvatarLoading = DefaultTextMessageCellAvatarLoader()
    private(set) var representedAvatarIdentity: TextMessageCellAvatarIdentity?
    
    
        
    override weak var delegate: MessageCellDelegate? {
        didSet {
            messageLabel.delegate = delegate
        }
    }
    
    
    public override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
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
        
        representedAvatarIdentity = nil
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
        var timeMarkerWithBackplate: Bool = false
        if message.images.isNotEmpty || message.videos.isNotEmpty || message.locations.isNotEmpty,
           message.files.isEmpty,
           message.contacts.isEmpty,
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
        let palette = AccountColorManager.shared.palette(for: message.owner)
        self.timeMarker.configure(text: message.timeMarkerText, indicator: message.indicator, withBackplate: timeMarkerWithBackplate)
        if reuseInlineViews {
            self.imagesView.updateContent(message.images)
            self.locationsView.updateContent(message.locations)
            self.contactsView.updateContent(message.contacts, palette: palette)
            self.filesView.updateContent(message.files, palette: palette)
        } else {
            self.imagesView.configure(message.images)
            self.locationsView.configure(message.locations)
            self.contactsView.configure(message.contacts, palette: palette)
            self.filesView.configure(message.files, palette: palette)
        }
        self.audiosView.delegate = delegate
        if reuseInlineViews {
            self.audiosView.updateContent(message.audios, palette: palette)
            self.forwardsContainer.updateContent(message.forwards, palette: palette, delegate: delegate)
            self.videosView.updateContent(message.videos)
        } else {
            self.audiosView.configure(message.audios, palette: palette)
            self.forwardsContainer.configure(message.forwards, palette: palette, delegate: delegate)
            self.videosView.configure(message.videos)
        }
        self.imagesView.layer.backgroundColor = MDCPalette.grey.tint100.cgColor
        
        ensureLongPressGestureInstalled()
        configureAvatar(for: message)
    }

    private func resetReusableAttachmentState() {
        imagesView.resetState()
        videosView.resetState()
        audiosView.views.forEach { view in
            view.resetWaveform()
            view.resetState()
            view.delegate = nil
        }
    }

    private func configureAvatar(for message: MessageType) {
        guard message.withAvatar else {
            representedAvatarIdentity = nil
            avatarView.isHidden = true
            avatarView.image = nil
            return
        }

        avatarView.isHidden = false
        let fallback = UIImageView.getDefaultAvatar(
            for: message.groupchatAuthorNickname,
            owner: message.owner,
            size: 32
        )
        guard let avatarUrl = message.avatarUrl else {
            representedAvatarIdentity = nil
            avatarView.image = fallback
            return
        }

        let identity = TextMessageCellAvatarIdentity(
            messagePrimary: message.primary,
            avatarUrl: avatarUrl,
            userId: message.groupchatAuthorId,
            jid: message.jid,
            owner: message.owner,
            displayName: message.groupchatAuthorNickname
        )
        representedAvatarIdentity = identity
        avatarView.image = fallback

        avatarLoader.loadGroupAvatar(
            url: avatarUrl,
            userId: message.groupchatAuthorId,
            jid: message.jid,
            owner: message.owner,
            size: 32
        ) { [weak self] image in
            let applyImage = {
                guard let self,
                      self.representedAvatarIdentity == identity else {
                    return
                }
                self.avatarView.image = image ?? fallback
            }
            if Thread.isMainThread {
                applyImage()
            } else {
                DispatchQueue.main.async(execute: applyImage)
            }
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
            let translatedPoint = touchPoint.translate(x: -self.forwardsContainer.frame.minX, y: -self.forwardsContainer.frame.minY)
            self.forwardsContainer.handleTouch(at: translatedPoint)
        }
        return messageLabel.handleGesture(touchPoint)
    }
    
}
