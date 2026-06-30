import Photos
import UIKit

struct ChatAttachmentGalleryAsset: Hashable {
    let localIdentifier: String
    let mediaKind: AttachmentMediaKind
    let creationDate: Date?
    let pixelSize: CGSize
    let duration: TimeInterval?

    static func == (lhs: ChatAttachmentGalleryAsset, rhs: ChatAttachmentGalleryAsset) -> Bool {
        lhs.localIdentifier == rhs.localIdentifier
            && lhs.mediaKind == rhs.mediaKind
            && lhs.creationDate == rhs.creationDate
            && Double(lhs.pixelSize.width) == Double(rhs.pixelSize.width)
            && Double(lhs.pixelSize.height) == Double(rhs.pixelSize.height)
            && lhs.duration == rhs.duration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(localIdentifier)
        hasher.combine(mediaKindHashKey)
        hasher.combine(creationDate)
        hasher.combine(Double(pixelSize.width))
        hasher.combine(Double(pixelSize.height))
        hasher.combine(duration)
    }

    private var mediaKindHashKey: Int {
        switch mediaKind {
        case .image:
            return 0
        case .video:
            return 1
        case .animatedImage:
            return 2
        case .audio:
            return 3
        case .file:
            return 4
        case .location:
            return 5
        case .contact:
            return 6
        }
    }
}

struct ChatAttachmentGalleryCapturedMedia: Hashable {
    let id: String
    let mediaKind: AttachmentMediaKind
    let filename: String
    let localFileURL: URL
    let thumbnailURL: URL?
    let pixelSize: CGSize?
    let duration: TimeInterval?

    init?(draft: AttachmentDraft) {
        guard let localFileURL = AttachmentCapturedDraft.url(from: draft.id) ?? AttachmentEditedDraft.url(from: draft.id) else {
            return nil
        }

        self.id = draft.id
        self.mediaKind = draft.mediaKind
        self.filename = draft.filename
        self.localFileURL = localFileURL
        if case .available(let key) = draft.thumbnailState {
            self.thumbnailURL = URL(string: key)
        } else {
            self.thumbnailURL = nil
        }
        self.pixelSize = draft.dimensions
        self.duration = draft.duration.map(TimeInterval.init)
    }

    static func == (lhs: ChatAttachmentGalleryCapturedMedia, rhs: ChatAttachmentGalleryCapturedMedia) -> Bool {
        lhs.id == rhs.id
            && lhs.mediaKind == rhs.mediaKind
            && lhs.filename == rhs.filename
            && lhs.localFileURL == rhs.localFileURL
            && lhs.thumbnailURL == rhs.thumbnailURL
            && lhs.pixelSize == rhs.pixelSize
            && lhs.duration == rhs.duration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(mediaKindHashKey)
        hasher.combine(filename)
        hasher.combine(localFileURL)
        hasher.combine(thumbnailURL)
        hasher.combine(pixelSize.map { Double($0.width) })
        hasher.combine(pixelSize.map { Double($0.height) })
        hasher.combine(duration)
    }

    private var mediaKindHashKey: Int {
        switch mediaKind {
        case .image:
            return 0
        case .video:
            return 1
        case .animatedImage:
            return 2
        case .audio:
            return 3
        case .file:
            return 4
        case .location:
            return 5
        case .contact:
            return 6
        }
    }
}

enum ChatAttachmentGalleryItem: Hashable {
    case camera
    case captured(ChatAttachmentGalleryCapturedMedia)
    case asset(ChatAttachmentGalleryAsset)
}

enum ChatAttachmentGalleryDisplayMode: Equatable {
    case compact
    case full
}

enum ChatAttachmentGalleryDateIndicatorPolicy {
    static func label(for item: ChatAttachmentGalleryItem?) -> String? {
        guard case .asset(let asset)? = item,
              let creationDate = asset.creationDate else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: creationDate)
    }
}

protocol ChatAttachmentGalleryDataProviding: AnyObject {
    func fetchAssets() -> [ChatAttachmentGalleryAsset]
}

enum ChatAttachmentGalleryThumbnailResult {
    case image(UIImage)
    case iCloud
    case failed
}

protocol ChatAttachmentGalleryThumbnailProviding: AnyObject {
    @discardableResult
    func requestThumbnail(
        for asset: ChatAttachmentGalleryAsset,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentGalleryThumbnailResult) -> Void
    ) -> Int

    func cancelThumbnailRequest(_ requestID: Int)
    func startCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize)
    func stopCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize)
}

enum ChatAttachmentGalleryItemPolicy {
    static func items(
        from assets: [ChatAttachmentGalleryAsset],
        capturedDrafts: [AttachmentDraft] = []
    ) -> [ChatAttachmentGalleryItem] {
        let visibleAssets = assets
            .filter { asset in
                asset.mediaKind == .image || asset.mediaKind == .video
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.creationDate ?? .distantPast
                let rhsDate = rhs.creationDate ?? .distantPast

                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }

                return lhs.localIdentifier < rhs.localIdentifier
            }

        let capturedItems = capturedDrafts.compactMap(ChatAttachmentGalleryCapturedMedia.init(draft:))
            .map(ChatAttachmentGalleryItem.captured)

        return [.camera] + capturedItems + visibleAssets.map(ChatAttachmentGalleryItem.asset)
    }
}

enum ChatAttachmentGallerySectionPolicy {
    static let featuredItemLimit = 5

    static func sectionedItems(from items: [ChatAttachmentGalleryItem]) -> [[ChatAttachmentGalleryItem]] {
        guard !items.isEmpty else {
            return [[], []]
        }

        let featuredItems = Array(items.prefix(featuredItemLimit))
        let gridItems = Array(items.dropFirst(featuredItemLimit))
        return [featuredItems, gridItems]
    }

    static func item(
        at indexPath: IndexPath,
        in items: [ChatAttachmentGalleryItem]
    ) -> ChatAttachmentGalleryItem? {
        let sectionedItems = sectionedItems(from: items)
        guard sectionedItems.indices.contains(indexPath.section),
              sectionedItems[indexPath.section].indices.contains(indexPath.item) else {
            return nil
        }

        return sectionedItems[indexPath.section][indexPath.item]
    }

    static func globalIndex(
        for indexPath: IndexPath,
        in items: [ChatAttachmentGalleryItem]
    ) -> Int? {
        let sectionedItems = sectionedItems(from: items)
        guard sectionedItems.indices.contains(indexPath.section),
              sectionedItems[indexPath.section].indices.contains(indexPath.item) else {
            return nil
        }

        if indexPath.section == 0 {
            return indexPath.item
        }

        return sectionedItems[0].count + indexPath.item
    }
}

enum ChatAttachmentGalleryScrollResolution: Equatable {
    case expandAndHoldContent
    case collapseAndHoldContent
    case allowContentScroll
}

enum ChatAttachmentGalleryScrollExpansionPolicy {
    static func resolution(
        displayMode: ChatAttachmentGalleryDisplayMode,
        contentOffsetY: CGFloat
    ) -> ChatAttachmentGalleryScrollResolution {
        _ = displayMode
        _ = contentOffsetY
        return .allowContentScroll
    }
}

enum ChatAttachmentGalleryCellThumbnailState: Equatable {
    case camera
    case cameraDisabled
    case loading
    case image
    case iCloud
    case failed
}

enum ChatAttachmentGallerySelectionIndicatorState: Equatable {
    case hidden
    case available
    case selected(order: Int)
    case blocked
}

struct ChatAttachmentGalleryCellState: Equatable {
    let item: ChatAttachmentGalleryItem
    let thumbnailState: ChatAttachmentGalleryCellThumbnailState
    let selectionIndicatorState: ChatAttachmentGallerySelectionIndicatorState
    let videoDurationLabel: String?
    let isCameraEnabled: Bool

    var selectionOrder: Int? {
        guard case .selected(let order) = selectionIndicatorState else {
            return nil
        }

        return order
    }
}

enum ChatAttachmentGalleryCellStatePolicy {
    static func state(
        for item: ChatAttachmentGalleryItem,
        thumbnailState: ChatAttachmentGalleryCellThumbnailState = .loading,
        selectionOrder: Int? = nil,
        isCameraEnabled: Bool = false,
        isSelectionBlocked: Bool = false
    ) -> ChatAttachmentGalleryCellState {
        switch item {
        case .camera:
            return ChatAttachmentGalleryCellState(
                item: item,
                thumbnailState: isCameraEnabled ? .camera : .cameraDisabled,
                selectionIndicatorState: .hidden,
                videoDurationLabel: nil,
                isCameraEnabled: isCameraEnabled
            )
        case .captured(let capturedMedia):
            return ChatAttachmentGalleryCellState(
                item: item,
                thumbnailState: thumbnailState,
                selectionIndicatorState: selectionIndicatorState(
                    selectionOrder: selectionOrder,
                    isSelectionBlocked: isSelectionBlocked
                ),
                videoDurationLabel: videoDurationLabel(for: capturedMedia.duration, mediaKind: capturedMedia.mediaKind),
                isCameraEnabled: true
            )
        case .asset(let asset):
            return ChatAttachmentGalleryCellState(
                item: item,
                thumbnailState: thumbnailState,
                selectionIndicatorState: selectionIndicatorState(
                    selectionOrder: selectionOrder,
                    isSelectionBlocked: isSelectionBlocked
                ),
                videoDurationLabel: videoDurationLabel(for: asset.duration, mediaKind: asset.mediaKind),
                isCameraEnabled: true
            )
        }
    }

    private static func selectionIndicatorState(
        selectionOrder: Int?,
        isSelectionBlocked: Bool
    ) -> ChatAttachmentGallerySelectionIndicatorState {
        if let selectionOrder {
            return .selected(order: selectionOrder)
        }

        return isSelectionBlocked ? .blocked : .available
    }

    private static func videoDurationLabel(
        for duration: TimeInterval?,
        mediaKind: AttachmentMediaKind
    ) -> String? {
        guard mediaKind == .video,
              let duration,
              duration > 0 else {
            return nil
        }

        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

final class ChatAttachmentGalleryCollectionViewCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatAttachmentGalleryCollectionViewCell"

    let thumbnailImageView = UIImageView()
    let cameraPreviewContainerView = UIView()
    let cameraImageView = UIImageView()
    let durationLabel = UILabel()
    let selectionBadgeLabel = UILabel()
    let selectionRingView = UIView()
    let selectionBlockedView = UIView()
    let loadingView = UIActivityIndicatorView(style: .medium)
    let cloudImageView = UIImageView(image: UIImage(systemName: "icloud"))
    let failureImageView = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))

    var representedItem: ChatAttachmentGalleryItem?
    var onPrepareForReuse: (() -> Void)?
    private weak var activeCameraPreviewProvider: ChatAttachmentCameraPreviewProviding?
    private var baseAccessibilityLabel: String?
    private var baseAccessibilityValue: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPrepareForReuse?()
        onPrepareForReuse = nil
        activeCameraPreviewProvider?.detachPreview(from: cameraPreviewContainerView)
        activeCameraPreviewProvider = nil
        representedItem = nil
        thumbnailImageView.image = nil
        cameraPreviewContainerView.isHidden = true
        cameraImageView.isHidden = true
        durationLabel.isHidden = true
        selectionBadgeLabel.isHidden = true
        selectionBadgeLabel.text = nil
        selectionRingView.isHidden = true
        selectionBlockedView.isHidden = true
        cloudImageView.isHidden = true
        failureImageView.isHidden = true
        loadingView.stopAnimating()
        contentView.alpha = 1
        isUserInteractionEnabled = true
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityTraits = []
        baseAccessibilityLabel = nil
        baseAccessibilityValue = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cameraPreviewContainerView.layer.sublayers?.forEach { layer in
            layer.frame = cameraPreviewContainerView.bounds
        }
    }

    func configure(
        state: ChatAttachmentGalleryCellState,
        image: UIImage?,
        cameraPreviewProvider: ChatAttachmentCameraPreviewProviding? = nil
    ) {
        representedItem = state.item
        thumbnailImageView.image = image
        durationLabel.text = state.videoDurationLabel
        durationLabel.isHidden = state.videoDurationLabel == nil

        if activeCameraPreviewProvider !== cameraPreviewProvider {
            activeCameraPreviewProvider?.detachPreview(from: cameraPreviewContainerView)
            activeCameraPreviewProvider = nil
        }
        cameraPreviewContainerView.isHidden = true
        cameraImageView.isHidden = true
        selectionBadgeLabel.isHidden = true
        selectionRingView.isHidden = true
        selectionBlockedView.isHidden = true
        cloudImageView.isHidden = true
        failureImageView.isHidden = true
        loadingView.stopAnimating()
        contentView.alpha = 1
        isUserInteractionEnabled = true
        accessibilityTraits = []
        applySelectionIndicatorVisualState(state.selectionIndicatorState)

        switch state.thumbnailState {
        case .camera:
            if let cameraPreviewProvider {
                cameraImageView.isHidden = false
                activeCameraPreviewProvider = cameraPreviewProvider
                cameraPreviewProvider.startPreview(in: cameraPreviewContainerView) { [weak self, weak cameraPreviewProvider] result in
                    guard let self,
                          self.activeCameraPreviewProvider === cameraPreviewProvider,
                          self.representedItem == state.item else {
                        return
                    }

                    switch result {
                    case .started:
                        self.cameraImageView.isHidden = true
                        self.cameraPreviewContainerView.isHidden = false
                    case .failed:
                        self.cameraPreviewContainerView.isHidden = true
                        self.cameraImageView.isHidden = false
                    }
                }
            } else {
                cameraImageView.isHidden = false
            }
            accessibilityLabel = ChatAttachmentLocalization.string(.galleryCameraAccessibilityLabel)
            accessibilityValue = nil
            accessibilityTraits = [.button]
        case .cameraDisabled:
            cameraImageView.isHidden = false
            contentView.alpha = 0.52
            isUserInteractionEnabled = false
            accessibilityLabel = ChatAttachmentLocalization.string(.galleryCameraUnavailableAccessibilityLabel)
            accessibilityValue = ChatAttachmentLocalization.string(.accessibilityUnavailable)
            accessibilityTraits = []
        case .loading:
            loadingView.startAnimating()
            accessibilityLabel = ChatAttachmentLocalization.string(.galleryLoadingPhotoAccessibilityLabel)
            accessibilityValue = nil
        case .image:
            accessibilityLabel = ChatAttachmentLocalization.string(.galleryPhotoAccessibilityLabel)
            accessibilityValue = nil
        case .iCloud:
            cloudImageView.isHidden = false
            accessibilityLabel = ChatAttachmentLocalization.string(.galleryPhotoICloudAccessibilityLabel)
            accessibilityValue = nil
        case .failed:
            failureImageView.isHidden = false
            accessibilityLabel = ChatAttachmentLocalization.string(.galleryPhotoUnavailableAccessibilityLabel)
            accessibilityValue = ChatAttachmentLocalization.string(.accessibilityUnavailable)
        }

        baseAccessibilityLabel = accessibilityLabel
        baseAccessibilityValue = accessibilityValue
        applySelectionAccessibility(for: state.selectionIndicatorState)
    }

    func updateSelectionIndicator(_ selectionIndicatorState: ChatAttachmentGallerySelectionIndicatorState) {
        applySelectionIndicatorVisualState(selectionIndicatorState)
        accessibilityLabel = baseAccessibilityLabel
        accessibilityValue = baseAccessibilityValue
        applySelectionAccessibility(for: selectionIndicatorState)
    }

    private func setupView() {
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true

        cameraPreviewContainerView.backgroundColor = .black
        cameraPreviewContainerView.clipsToBounds = true
        cameraPreviewContainerView.translatesAutoresizingMaskIntoConstraints = false

        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false

        cameraImageView.image = UIImage(systemName: "camera.fill")
        cameraImageView.tintColor = .secondaryLabel
        cameraImageView.contentMode = .scaleAspectFit
        cameraImageView.translatesAutoresizingMaskIntoConstraints = false

        durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 7
        durationLabel.layer.masksToBounds = true
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        selectionBadgeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        selectionBadgeLabel.textColor = .white
        selectionBadgeLabel.backgroundColor = .systemBlue
        selectionBadgeLabel.textAlignment = .center
        selectionBadgeLabel.layer.cornerRadius = 11
        selectionBadgeLabel.layer.masksToBounds = true
        selectionBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        selectionRingView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        selectionRingView.layer.borderColor = UIColor.white.cgColor
        selectionRingView.layer.borderWidth = 2
        selectionRingView.layer.cornerRadius = 11
        selectionRingView.layer.masksToBounds = true
        selectionRingView.translatesAutoresizingMaskIntoConstraints = false

        selectionBlockedView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        selectionBlockedView.layer.borderColor = UIColor.tertiaryLabel.cgColor
        selectionBlockedView.layer.borderWidth = 2
        selectionBlockedView.layer.cornerRadius = 11
        selectionBlockedView.layer.masksToBounds = true
        selectionBlockedView.translatesAutoresizingMaskIntoConstraints = false

        loadingView.hidesWhenStopped = true
        loadingView.color = .secondaryLabel
        loadingView.translatesAutoresizingMaskIntoConstraints = false

        cloudImageView.tintColor = .secondaryLabel
        cloudImageView.contentMode = .scaleAspectFit
        cloudImageView.translatesAutoresizingMaskIntoConstraints = false

        failureImageView.tintColor = .secondaryLabel
        failureImageView.contentMode = .scaleAspectFit
        failureImageView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(thumbnailImageView)
        contentView.addSubview(cameraPreviewContainerView)
        contentView.addSubview(cameraImageView)
        contentView.addSubview(durationLabel)
        contentView.addSubview(selectionRingView)
        contentView.addSubview(selectionBlockedView)
        contentView.addSubview(selectionBadgeLabel)
        contentView.addSubview(loadingView)
        contentView.addSubview(cloudImageView)
        contentView.addSubview(failureImageView)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnailImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            cameraPreviewContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cameraPreviewContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cameraPreviewContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cameraPreviewContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            cameraImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            cameraImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cameraImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.34),
            cameraImageView.heightAnchor.constraint(equalTo: cameraImageView.widthAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            durationLabel.heightAnchor.constraint(equalToConstant: 18),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),

            selectionRingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            selectionRingView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            selectionRingView.widthAnchor.constraint(equalToConstant: 22),
            selectionRingView.heightAnchor.constraint(equalToConstant: 22),

            selectionBlockedView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            selectionBlockedView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            selectionBlockedView.widthAnchor.constraint(equalToConstant: 22),
            selectionBlockedView.heightAnchor.constraint(equalToConstant: 22),

            selectionBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            selectionBadgeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            selectionBadgeLabel.widthAnchor.constraint(equalToConstant: 22),
            selectionBadgeLabel.heightAnchor.constraint(equalToConstant: 22),

            loadingView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            cloudImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            cloudImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cloudImageView.widthAnchor.constraint(equalToConstant: 28),
            cloudImageView.heightAnchor.constraint(equalToConstant: 28),

            failureImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failureImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failureImageView.widthAnchor.constraint(equalToConstant: 28),
            failureImageView.heightAnchor.constraint(equalToConstant: 28)
        ])

        prepareForReuse()
    }

    private func applySelectionIndicatorVisualState(
        _ selectionIndicatorState: ChatAttachmentGallerySelectionIndicatorState
    ) {
        selectionBadgeLabel.isHidden = true
        selectionBadgeLabel.text = nil
        selectionRingView.isHidden = true
        selectionBlockedView.isHidden = true

        switch selectionIndicatorState {
        case .hidden:
            break
        case .available:
            selectionRingView.isHidden = false
        case .selected(let order):
            selectionBadgeLabel.text = "\(order)"
            selectionBadgeLabel.isHidden = false
        case .blocked:
            selectionBlockedView.isHidden = false
        }
    }

    private func applySelectionAccessibility(
        for selectionIndicatorState: ChatAttachmentGallerySelectionIndicatorState
    ) {
        let selectionLabel: String?
        switch selectionIndicatorState {
        case .hidden:
            selectionLabel = nil
        case .available:
            selectionLabel = ChatAttachmentLocalization.string(.accessibilityNotSelected)
        case .selected(let order):
            selectionLabel = ChatAttachmentLocalization.string(.accessibilitySelectedOrder, arguments: ["\(order)"])
        case .blocked:
            selectionLabel = ChatAttachmentLocalization.string(.accessibilitySelectionLimitReached)
        }

        guard let selectionLabel else {
            return
        }

        accessibilityLabel = [accessibilityLabel, selectionLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityValue = selectionLabel
    }
}

final class PhotoKitChatAttachmentGalleryDataProvider: ChatAttachmentGalleryDataProviding {
    func fetchAssets() -> [ChatAttachmentGalleryAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let fetchResult = PHAsset.fetchAssets(with: options)
        var assets: [ChatAttachmentGalleryAsset] = []
        assets.reserveCapacity(fetchResult.count)

        fetchResult.enumerateObjects { asset, _, _ in
            guard let mediaKind = AttachmentMediaKind(photoKitMediaType: asset.mediaType) else {
                return
            }

            assets.append(
                ChatAttachmentGalleryAsset(
                    localIdentifier: asset.localIdentifier,
                    mediaKind: mediaKind,
                    creationDate: asset.creationDate,
                    pixelSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight)),
                    duration: mediaKind == .video ? asset.duration : nil
                )
            )
        }

        return assets
    }
}

final class PhotoKitChatAttachmentGalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
    private let imageManager: PHCachingImageManager

    init(imageManager: PHCachingImageManager = PHCachingImageManager()) {
        self.imageManager = imageManager
    }

    @discardableResult
    func requestThumbnail(
        for asset: ChatAttachmentGalleryAsset,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentGalleryThumbnailResult) -> Void
    ) -> Int {
        guard let photoAsset = photoAsset(for: asset) else {
            completion(.failed)
            return Int(PHInvalidImageRequestID)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let requestID = imageManager.requestImage(
            for: photoAsset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if (info?[PHImageCancelledKey] as? Bool) == true {
                return
            }

            if let image {
                completion(.image(image))
                return
            }

            if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                completion(.iCloud)
                return
            }

            completion(.failed)
        }

        return Int(requestID)
    }

    func cancelThumbnailRequest(_ requestID: Int) {
        imageManager.cancelImageRequest(PHImageRequestID(requestID))
    }

    func startCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {
        let photoAssets = assets.compactMap(photoAsset(for:))
        guard !photoAssets.isEmpty else {
            return
        }

        imageManager.startCachingImages(
            for: photoAssets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    func stopCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {
        let photoAssets = assets.compactMap(photoAsset(for:))
        guard !photoAssets.isEmpty else {
            return
        }

        imageManager.stopCachingImages(
            for: photoAssets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    private func photoAsset(for asset: ChatAttachmentGalleryAsset) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject
    }
}

private extension AttachmentMediaKind {
    init?(photoKitMediaType: PHAssetMediaType) {
        switch photoKitMediaType {
        case .image:
            self = .image
        case .video:
            self = .video
        case .audio, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }
}
