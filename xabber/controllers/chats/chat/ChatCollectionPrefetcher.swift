import CoreGraphics
import Foundation
import UIKit

struct ChatCollectionPrefetchIdentity: Hashable {
    enum Kind: String, Hashable {
        case image
        case sticker
        case videoPreview
        case avatar
        case contactAvatar
        case locationSnapshot
    }

    let kind: Kind
    let messagePrimary: String
    let referencePrimary: String
}

struct ChatCollectionPrefetchSize: Hashable {
    let width: Double
    let height: Double

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    func scaled(by scale: Double) -> ChatCollectionPrefetchSize {
        ChatCollectionPrefetchSize(
            width: ceil(width * scale),
            height: ceil(height * scale)
        )
    }

    var cacheComponent: String {
        "\(Int(ceil(width)))x\(Int(ceil(height)))"
    }
}

typealias ChatCollectionPrefetchImageRequest = ChatThumbnailRequest

struct ChatCollectionPrefetchLocation: Hashable {
    let latitude: Double
    let longitude: Double
    let address: String?
    let geoURI: String

    var resolvedLocation: ChatAttachmentResolvedLocation {
        ChatAttachmentResolvedLocation(
            coordinate: AttachmentLocationCoordinate(
                latitude: latitude,
                longitude: longitude
            ),
            displayAddress: address,
            accuracy: nil
        )
    }
}

struct ChatCollectionPrefetchImageReference: Hashable {
    let primary: String
    /// Full source identity retained for opening/download semantics.
    let url: URL?
    /// Optional bounded resource used by the thumbnail pipeline.
    let previewURL: URL?
    let size: ChatCollectionPrefetchSize?

    init(
        primary: String,
        url: URL?,
        previewURL: URL? = nil,
        size: ChatCollectionPrefetchSize? = nil
    ) {
        self.primary = primary
        self.url = url
        self.previewURL = previewURL
        self.size = size
    }
}

struct ChatCollectionPrefetchVideoReference: Hashable {
    let primary: String
    let url: URL?
    let previewURL: URL?
    let size: ChatCollectionPrefetchSize?

    init(
        primary: String,
        url: URL?,
        previewURL: URL?,
        size: ChatCollectionPrefetchSize? = nil
    ) {
        self.primary = primary
        self.url = url
        self.previewURL = previewURL
        self.size = size
    }
}

struct ChatCollectionPrefetchLocationReference: Hashable {
    let primary: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let geoURI: String
    let snapshotURL: URL?

    var location: ChatCollectionPrefetchLocation {
        ChatCollectionPrefetchLocation(
            latitude: latitude,
            longitude: longitude,
            address: address,
            geoURI: geoURI
        )
    }
}

struct ChatCollectionPrefetchContactReference: Hashable {
    let primary: String
    let owner: String
    let jid: String
    let avatarURL: URL?
    let displayName: String
    let colorKey: String

    init(
        primary: String,
        owner: String,
        jid: String,
        avatarURL: URL?,
        displayName: String = "",
        colorKey: String? = nil
    ) {
        self.primary = primary
        self.owner = owner
        self.jid = jid
        self.avatarURL = avatarURL
        self.displayName = displayName.isNotEmpty ? displayName : jid
        self.colorKey = colorKey ?? (jid.isNotEmpty ? jid : owner)
    }
}

struct ChatCollectionPrefetchItem: Hashable {
    let messagePrimary: String
    let owner: String
    let jid: String
    let avatarURL: URL?
    let avatarEntityIdentity: String
    let avatarDisplayName: String
    let sticker: ChatCollectionPrefetchImageReference?
    let images: [ChatCollectionPrefetchImageReference]
    let videos: [ChatCollectionPrefetchVideoReference]
    let locations: [ChatCollectionPrefetchLocationReference]
    let contacts: [ChatCollectionPrefetchContactReference]

    init(
        messagePrimary: String,
        owner: String,
        jid: String,
        avatarURL: URL?,
        avatarEntityIdentity: String? = nil,
        avatarDisplayName: String? = nil,
        sticker: ChatCollectionPrefetchImageReference? = nil,
        images: [ChatCollectionPrefetchImageReference],
        videos: [ChatCollectionPrefetchVideoReference],
        locations: [ChatCollectionPrefetchLocationReference],
        contacts: [ChatCollectionPrefetchContactReference]
    ) {
        self.messagePrimary = messagePrimary
        self.owner = owner
        self.jid = jid
        self.avatarURL = avatarURL
        self.avatarEntityIdentity = avatarEntityIdentity ?? ""
        self.avatarDisplayName = avatarDisplayName ?? jid
        self.sticker = sticker
        self.images = images
        self.videos = videos
        self.locations = locations
        self.contacts = contacts
    }
}

enum ChatCollectionPrefetchResource: Hashable {
    case image(identity: ChatCollectionPrefetchIdentity, request: ChatCollectionPrefetchImageRequest)
    case videoPreview(identity: ChatCollectionPrefetchIdentity, request: ChatCollectionPrefetchImageRequest)
    case avatar(identity: ChatCollectionPrefetchIdentity, request: ChatAvatarRequest)
    case locationSnapshot(identity: ChatCollectionPrefetchIdentity, request: ChatLocationSnapshotRequest)
}

struct ChatCollectionPrefetchContext {
    let locationSnapshotSize: ChatCollectionPrefetchSize
    let mediaContainerSize: ChatCollectionPrefetchSize
    let avatarSize: ChatCollectionPrefetchSize
    let contactAvatarSize: ChatCollectionPrefetchSize
    let screenScale: Double
    let traitStyle: ChatThumbnailTraitStyle

    init(
        locationSnapshotSize: ChatCollectionPrefetchSize,
        mediaContainerSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 220, height: 220),
        avatarSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 32, height: 32),
        contactAvatarSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 36, height: 36),
        screenScale: Double = 2,
        traitStyle: ChatThumbnailTraitStyle = .unspecified
    ) {
        self.locationSnapshotSize = locationSnapshotSize
        self.mediaContainerSize = mediaContainerSize
        self.avatarSize = avatarSize
        self.contactAvatarSize = contactAvatarSize
        self.screenScale = screenScale
        self.traitStyle = traitStyle
    }

    static func empty(
        mediaContainerSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 220, height: 220),
        screenScale: Double = 2,
        traitStyle: ChatThumbnailTraitStyle = .unspecified
    ) -> ChatCollectionPrefetchContext {
        return ChatCollectionPrefetchContext(
            locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220),
            mediaContainerSize: mediaContainerSize,
            screenScale: screenScale,
            traitStyle: traitStyle
        )
    }
}

protocol ChatCollectionContentPrefetching: AnyObject {
    func prefetch(_ resources: Set<ChatCollectionPrefetchResource>)
    func cancelPrefetching(_ resources: Set<ChatCollectionPrefetchResource>)
}

final class ChatCollectionPrefetchCoordinator {
    typealias ItemProvider = (IndexPath) -> ChatCollectionPrefetchItem?
    typealias ContextProvider = () -> ChatCollectionPrefetchContext

    private let itemProvider: ItemProvider
    private let contextProvider: ContextProvider
    private let prefetcher: ChatCollectionContentPrefetching
    private var activeResourcesByIndexPath: [IndexPath: Set<ChatCollectionPrefetchResource>] = [:]
    private var ownerIndexPathsByResource: [ChatCollectionPrefetchResource: Set<IndexPath>] = [:]

    init(
        itemProvider: @escaping ItemProvider,
        contextProvider: @escaping ContextProvider,
        prefetcher: ChatCollectionContentPrefetching
    ) {
        self.itemProvider = itemProvider
        self.contextProvider = contextProvider
        self.prefetcher = prefetcher
    }

    func prefetchItems(at indexPaths: [IndexPath]) {
        let context = contextProvider()
        var resourcesToPrefetch = Set<ChatCollectionPrefetchResource>()

        indexPaths.forEach { indexPath in
            guard let item = itemProvider(indexPath) else {
                return
            }

            let resources = ChatCollectionPrefetchPlanner.resources(
                for: item,
                indexPath: indexPath,
                context: context
            )
            let existingResources = activeResourcesByIndexPath[indexPath] ?? []
            let removedResources = existingResources.subtracting(resources)
            let addedResources = resources.subtracting(existingResources)
            var resourcesToCancel = Set<ChatCollectionPrefetchResource>()
            removedResources.forEach { resource in
                if removeOwner(indexPath, from: resource) {
                    resourcesToCancel.insert(resource)
                }
            }
            if resourcesToCancel.isNotEmpty {
                prefetcher.cancelPrefetching(resourcesToCancel)
            }

            activeResourcesByIndexPath[indexPath] = resources
            addedResources.forEach { resource in
                if addOwner(indexPath, to: resource) {
                    resourcesToPrefetch.insert(resource)
                }
            }
        }

        if resourcesToPrefetch.isNotEmpty {
            prefetcher.prefetch(resourcesToPrefetch)
        }
    }

    func cancelPrefetchingForItems(at indexPaths: [IndexPath]) {
        var resourcesToCancel = Set<ChatCollectionPrefetchResource>()
        indexPaths.forEach { indexPath in
            if let resources = activeResourcesByIndexPath.removeValue(forKey: indexPath) {
                resources.forEach { resource in
                    if removeOwner(indexPath, from: resource) {
                        resourcesToCancel.insert(resource)
                    }
                }
            }
        }

        if resourcesToCancel.isNotEmpty {
            prefetcher.cancelPrefetching(resourcesToCancel)
        }
    }

    func cancelAll() {
        let resourcesToCancel = Set(ownerIndexPathsByResource.keys)
        activeResourcesByIndexPath.removeAll()
        ownerIndexPathsByResource.removeAll()
        if resourcesToCancel.isNotEmpty {
            prefetcher.cancelPrefetching(resourcesToCancel)
        }
    }

    var activeResourceCount: Int {
        ownerIndexPathsByResource.count
    }

    private func addOwner(_ indexPath: IndexPath, to resource: ChatCollectionPrefetchResource) -> Bool {
        let wasUnowned = ownerIndexPathsByResource[resource]?.isEmpty ?? true
        ownerIndexPathsByResource[resource, default: []].insert(indexPath)
        return wasUnowned
    }

    private func removeOwner(_ indexPath: IndexPath, from resource: ChatCollectionPrefetchResource) -> Bool {
        guard var owners = ownerIndexPathsByResource[resource] else { return false }
        owners.remove(indexPath)
        if owners.isEmpty {
            ownerIndexPathsByResource.removeValue(forKey: resource)
            return true
        }
        ownerIndexPathsByResource[resource] = owners
        return false
    }
}

enum ChatCollectionPrefetchPlanner {
    static func resources(
        for item: ChatCollectionPrefetchItem,
        indexPath _: IndexPath,
        context: ChatCollectionPrefetchContext
    ) -> Set<ChatCollectionPrefetchResource> {
        var resources = Set<ChatCollectionPrefetchResource>()

        if let sticker = item.sticker, let url = sticker.url {
            let sourceSize = sticker.size?.cgSize ?? CGSize(
                square: ChatStickerLayoutPolicy.maximumSide
            )
            let renderedSize = ChatStickerLayoutPolicy.renderedSize(
                sourceSize: sourceSize,
                availableWidth: CGFloat(context.mediaContainerSize.width)
            )
            resources.insert(.image(
                identity: identity(
                    .sticker,
                    messagePrimary: item.messagePrimary,
                    referencePrimary: sticker.primary
                ),
                request: imageRequest(
                    url: url,
                    displaySize: ChatCollectionPrefetchSize(
                        width: Double(renderedSize.width),
                        height: Double(renderedSize.height)
                    ),
                    context: context
                )
            ))
        }

        let imageFrames = mediaFrames(count: item.images.count, containerSize: context.mediaContainerSize)
        item.images.enumerated().forEach { index, image in
            guard let url = image.previewURL ?? image.url else { return }
            resources.insert(.image(
                identity: identity(.image, messagePrimary: item.messagePrimary, referencePrimary: image.primary),
                request: imageRequest(url: url, displaySize: displaySize(at: index, in: imageFrames, fallback: context.mediaContainerSize), context: context)
            ))
        }

        let videoFrames = mediaFrames(
            count: item.videos.count,
            containerSize: videoContainerSize(for: item.videos, fallback: context.mediaContainerSize)
        )
        item.videos.enumerated().forEach { index, video in
            guard let url = video.previewURL else { return }
            resources.insert(.videoPreview(
                identity: identity(.videoPreview, messagePrimary: item.messagePrimary, referencePrimary: video.primary),
                request: imageRequest(url: url, displaySize: displaySize(at: index, in: videoFrames, fallback: context.mediaContainerSize), context: context)
            ))
        }

        if item.avatarURL != nil || item.avatarEntityIdentity.isNotEmpty {
            resources.insert(.avatar(
                identity: identity(.avatar, messagePrimary: item.messagePrimary, referencePrimary: item.messagePrimary),
                request: ChatAvatarRequest(
                    entityIdentity: item.avatarEntityIdentity,
                    remoteURL: item.avatarURL,
                    displayName: item.avatarDisplayName,
                    colorKey: item.avatarEntityIdentity.isNotEmpty ? item.avatarEntityIdentity : item.owner,
                    displaySize: context.avatarSize,
                    scale: context.screenScale,
                    traitStyle: context.traitStyle
                )
            ))
        }

        item.contacts.forEach { contact in
            resources.insert(.avatar(
                identity: identity(.contactAvatar, messagePrimary: item.messagePrimary, referencePrimary: contact.primary),
                request: ChatAvatarRequest(
                    entityIdentity: contact.jid,
                    remoteURL: contact.avatarURL,
                    displayName: contact.displayName,
                    colorKey: contact.colorKey,
                    displaySize: context.contactAvatarSize,
                    scale: context.screenScale,
                    traitStyle: context.traitStyle
                )
            ))
        }

        item.locations.forEach { location in
            resources.insert(.locationSnapshot(
                identity: identity(.locationSnapshot, messagePrimary: item.messagePrimary, referencePrimary: location.primary),
                request: ChatLocationSnapshotRequest(
                    latitude: location.latitude,
                    longitude: location.longitude,
                    sourceURL: location.snapshotURL,
                    displaySize: context.locationSnapshotSize,
                    scale: context.screenScale,
                    mapStyle: .standard,
                    traitStyle: context.traitStyle
                )
            ))
        }

        return resources
    }

    private static func imageRequest(
        url: URL,
        displaySize: ChatCollectionPrefetchSize,
        context: ChatCollectionPrefetchContext
    ) -> ChatCollectionPrefetchImageRequest {
        ChatCollectionPrefetchImageRequest(
            url: url,
            displaySize: displaySize,
            scale: context.screenScale,
            traitStyle: context.traitStyle
        )
    }

    private static func displaySize(
        at index: Int,
        in frames: [CGRect],
        fallback: ChatCollectionPrefetchSize
    ) -> ChatCollectionPrefetchSize {
        guard frames.indices.contains(index) else {
            return fallback
        }
        return ChatCollectionPrefetchSize(
            width: Double(max(1, frames[index].width)),
            height: Double(max(1, frames[index].height))
        )
    }

    private static func mediaFrames(
        count: Int,
        containerSize: ChatCollectionPrefetchSize
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let halfPadding: CGFloat = 2
        let width = CGFloat(containerSize.width)
        let height = CGFloat(containerSize.height)
        switch count {
        case 1:
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        case 2:
            return [
                CGRect(x: 0, y: 0, width: (width / 2) - halfPadding, height: height),
                CGRect(x: (width / 2) + halfPadding, y: 0, width: (width / 2) - halfPadding, height: height)
            ]
        case 3:
            return [
                CGRect(x: 0, y: 0, width: (width / 2) - halfPadding, height: height),
                CGRect(x: (width / 2) + halfPadding, y: 0, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding),
                CGRect(x: (width / 2) + halfPadding, y: (height / 2) + halfPadding, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding)
            ]
        case 4:
            return [
                CGRect(x: 0, y: 0, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding),
                CGRect(x: (width / 2) + halfPadding, y: 0, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding),
                CGRect(x: 0, y: (height / 2) + halfPadding, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding),
                CGRect(x: (width / 2) + halfPadding, y: (height / 2) + halfPadding, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding)
            ]
        default:
            return [
                CGRect(x: 0, y: 0, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding),
                CGRect(x: 0, y: (height / 2) + halfPadding, width: (width / 2) - halfPadding, height: (height / 2) - halfPadding),
                CGRect(x: (width / 2) + halfPadding, y: 0, width: (width / 2) - halfPadding, height: (height / 3) - halfPadding),
                CGRect(x: (width / 2) + halfPadding, y: (height / 3) + halfPadding, width: (width / 2) - halfPadding, height: (height / 3) - (halfPadding * 2)),
                CGRect(x: (width / 2) + halfPadding, y: ((height / 3) * 2) + halfPadding, width: (width / 2) - halfPadding, height: (height / 3) - halfPadding)
            ]
        }
    }

    private static func videoContainerSize(
        for videos: [ChatCollectionPrefetchVideoReference],
        fallback: ChatCollectionPrefetchSize
    ) -> ChatCollectionPrefetchSize {
        guard videos.isNotEmpty, videos.allSatisfy({ $0.size != nil }) else {
            return fallback
        }
        let layoutMaximum = max(1, fallback.width + 4)
        let width = max(1, min(videos.compactMap(\.size?.width).max() ?? layoutMaximum, layoutMaximum) - 4)
        let height = max(
            1,
            videos.compactMap(\.size?.height).reduce(0) { result, height in
                result + min(height, layoutMaximum) + 4
            } - 4
        )
        return ChatCollectionPrefetchSize(width: width, height: height)
    }

    private static func identity(
        _ kind: ChatCollectionPrefetchIdentity.Kind,
        messagePrimary: String,
        referencePrimary: String
    ) -> ChatCollectionPrefetchIdentity {
        ChatCollectionPrefetchIdentity(
            kind: kind,
            messagePrimary: messagePrimary,
            referencePrimary: referencePrimary
        )
    }
}

final class ChatCollectionContentPrefetcher: ChatCollectionContentPrefetching {
    private let locationSnapshotPipeline: ChatLocationSnapshotServing
    private let avatarPipeline: ChatAvatarServing
    private let thumbnailPipeline: ChatThumbnailServing
    private var imagePrefetchers: [ChatCollectionPrefetchResource: ChatThumbnailSubscription] = [:]
    private var avatarPrefetchers: [ChatCollectionPrefetchResource: ChatAvatarSubscription] = [:]
    private var locationSnapshotPrefetchers: [ChatCollectionPrefetchResource: ChatLocationSnapshotSubscription] = [:]
    private var avatarTokens: [ChatCollectionPrefetchResource: UUID] = [:]
    private var locationSnapshotTokens: [ChatCollectionPrefetchResource: UUID] = [:]

    var activeImagePrefetchCount: Int {
        imagePrefetchers.count
    }

    var activeLocationSnapshotCount: Int {
        locationSnapshotPrefetchers.count
    }

    var activeAvatarPrefetchCount: Int {
        avatarPrefetchers.count
    }

    init(
        locationSnapshotPipeline: ChatLocationSnapshotServing = ChatLocationSnapshotPipeline.shared,
        avatarPipeline: ChatAvatarServing = ChatAvatarPipeline.shared,
        thumbnailPipeline: ChatThumbnailServing = ChatMediaThumbnailPipeline.shared
    ) {
        self.locationSnapshotPipeline = locationSnapshotPipeline
        self.avatarPipeline = avatarPipeline
        self.thumbnailPipeline = thumbnailPipeline
    }

    func prefetch(_ resources: Set<ChatCollectionPrefetchResource>) {
        ChatPerformanceSignposts.measure(.mediaPrefetch) {
            resources.forEach { resource in
                switch resource {
                case .image(_, let request),
                     .videoPreview(_, let request):
                    startImagePrefetch(for: resource, request: request)
                case .avatar(let identity, let request):
                    startAvatarPrefetch(for: resource, identity: identity, request: request)
                case .locationSnapshot(let identity, let request):
                    startLocationSnapshotPrefetch(for: resource, identity: identity, request: request)
                }
            }
        }
    }

    func cancelPrefetching(_ resources: Set<ChatCollectionPrefetchResource>) {
        resources.forEach { resource in
            if let prefetcher = imagePrefetchers.removeValue(forKey: resource) {
                prefetcher.cancel()
            }
            if let prefetcher = avatarPrefetchers.removeValue(forKey: resource) {
                prefetcher.cancel()
            }
            if let prefetcher = locationSnapshotPrefetchers.removeValue(forKey: resource) {
                prefetcher.cancel()
            }
            avatarTokens.removeValue(forKey: resource)
            locationSnapshotTokens.removeValue(forKey: resource)
        }
    }

    private func startImagePrefetch(
        for resource: ChatCollectionPrefetchResource,
        request: ChatCollectionPrefetchImageRequest
    ) {
        guard imagePrefetchers[resource] == nil else { return }
        guard let identity = resource.thumbnailIdentity else { return }
        imagePrefetchers[resource] = thumbnailPipeline.acquire(
            request,
            consumer: ChatThumbnailConsumer(identity: identity, role: .prefetch),
            completion: nil
        )
    }

    private func startLocationSnapshotPrefetch(
        for resource: ChatCollectionPrefetchResource,
        identity: ChatCollectionPrefetchIdentity,
        request: ChatLocationSnapshotRequest
    ) {
        guard locationSnapshotPrefetchers[resource] == nil else { return }
        let token = UUID()
        locationSnapshotTokens[resource] = token
        let subscription = locationSnapshotPipeline.acquire(
            request,
            consumer: ChatLocationSnapshotConsumer(identity: identity, role: .prefetch)
        ) { [weak self] _ in
            guard let self,
                  self.locationSnapshotTokens[resource] == token else {
                return
            }
            self.locationSnapshotTokens.removeValue(forKey: resource)
            self.locationSnapshotPrefetchers.removeValue(forKey: resource)
        }
        if locationSnapshotTokens[resource] == token {
            locationSnapshotPrefetchers[resource] = subscription
        } else {
            subscription.cancel()
        }
    }

    private func startAvatarPrefetch(
        for resource: ChatCollectionPrefetchResource,
        identity: ChatCollectionPrefetchIdentity,
        request: ChatAvatarRequest
    ) {
        guard avatarPrefetchers[resource] == nil else { return }
        let token = UUID()
        avatarTokens[resource] = token
        let subscription = avatarPipeline.acquire(
            request,
            consumer: ChatAvatarConsumer(identity: identity, role: .prefetch)
        ) { [weak self] _ in
            guard let self, self.avatarTokens[resource] == token else { return }
            self.avatarTokens.removeValue(forKey: resource)
            self.avatarPrefetchers.removeValue(forKey: resource)
        }
        if avatarTokens[resource] == token {
            avatarPrefetchers[resource] = subscription
        } else {
            subscription.cancel()
        }
    }
}

extension ChatViewController.Datasource {
    var collectionPrefetchItem: ChatCollectionPrefetchItem {
        let sticker: ChatCollectionPrefetchImageReference?
        if case .sticker(let attachment) = kind {
            sticker = ChatCollectionPrefetchImageReference(
                primary: attachment.primary,
                url: attachment.url,
                size: ChatCollectionPrefetchSize(
                    width: Double(attachment.size.width),
                    height: Double(attachment.size.height)
                )
            )
        } else {
            sticker = nil
        }
        return ChatCollectionPrefetchItem(
            messagePrimary: primary,
            owner: owner,
            jid: jid,
            avatarURL: avatarUrl.flatMap(URL.init(string:)),
            avatarEntityIdentity: withAvatar
                ? (groupchatAuthorId.isNotEmpty ? groupchatAuthorId : jid)
                : "",
            avatarDisplayName: groupchatAuthorNickname,
            sticker: sticker,
            images: images.map {
                ChatCollectionPrefetchImageReference(
                    primary: $0.primary,
                    url: $0.url,
                    previewURL: $0.previewUrl
                )
            },
            videos: videos.map {
                ChatCollectionPrefetchVideoReference(
                    primary: $0.primary,
                    url: $0.url,
                    previewURL: $0.previewUrl,
                    size: ChatCollectionPrefetchSize(
                        width: Double($0.size.width),
                        height: Double($0.size.height)
                    )
                )
            },
            locations: locations.map {
                ChatCollectionPrefetchLocationReference(
                    primary: $0.primary,
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    address: $0.address,
                    geoURI: $0.geoURI,
                    snapshotURL: $0.snapshotURL
                )
            },
            contacts: contacts.map {
                ChatCollectionPrefetchContactReference(
                    primary: $0.primary,
                    owner: $0.owner,
                    jid: $0.jid,
                    avatarURL: $0.avatarURL.flatMap(URL.init(string:)),
                    displayName: $0.title,
                    colorKey: $0.jid
                )
            }
        )
    }
}

extension ChatViewController {
    internal func chatCollectionPrefetchItem(at indexPath: IndexPath) -> ChatCollectionPrefetchItem? {
        datasourceItem(at: indexPath)?.collectionPrefetchItem
    }

    internal func chatCollectionPrefetchContext() -> ChatCollectionPrefetchContext {
        let flowLayout = messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
        let layoutWidth = flowLayout?.itemWidth ?? messagesCollectionView.bounds.width
        // ChatMessageLayoutCalculator subtracts 76 points from the item width,
        // caps a top-level message at 420, then the media view removes 4 points.
        let width = max(1, min(420, layoutWidth - 76) - 4)
        let mediaSize = ChatCollectionPrefetchSize(width: Double(width), height: Double(width))
        return ChatCollectionPrefetchContext(
            locationSnapshotSize: mediaSize,
            mediaContainerSize: mediaSize,
            avatarSize: ChatCollectionPrefetchSize(width: 32, height: 32),
            contactAvatarSize: ChatCollectionPrefetchSize(width: 36, height: 36),
            screenScale: Double(view.window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle)
        )
    }
}

private extension ChatCollectionPrefetchResource {
    var thumbnailIdentity: ChatCollectionPrefetchIdentity? {
        switch self {
        case .image(let identity, _),
             .videoPreview(let identity, _),
             .avatar(let identity, _):
            return identity
        case .locationSnapshot:
            return nil
        }
    }
}
