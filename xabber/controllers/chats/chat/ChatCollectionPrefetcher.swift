import CoreGraphics
import Foundation
import UIKit
import CocoaLumberjack

struct ChatCollectionPrefetchIdentity: Hashable {
    enum Kind: String, Hashable {
        case image
        case videoPreview
        case avatar
        case contactAvatar
        case locationSnapshot
    }

    let kind: Kind
    let messagePrimary: String
    let referencePrimary: String
}

struct ChatCollectionPrefetchConversationKey: Hashable {
    let owner: String
    let jid: String
    let conversationType: String

    init(owner: String, jid: String, conversationType: String) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
    }

    init(_ key: ChatTimelineConversationKey) {
        self.init(
            owner: key.owner,
            jid: key.jid,
            conversationType: key.conversationType.rawValue
        )
    }

    var resolvedConversationType: ClientSynchronizationManager.ConversationType {
        ClientSynchronizationManager.ConversationType(rawValue: conversationType) ?? .regular
    }
}

struct ChatCollectionPrefetchBoundary: Hashable {
    let primary: String
    let archivedId: String?
    let messageId: String?
    let timestamp: TimeInterval

    init(primary: String, archivedId: String?, messageId: String?, timestamp: TimeInterval) {
        self.primary = primary
        self.archivedId = archivedId
        self.messageId = messageId
        self.timestamp = timestamp
    }

    init(_ boundary: ChatTimelineBoundary) {
        self.init(
            primary: boundary.primary,
            archivedId: boundary.archivedId,
            messageId: boundary.messageId,
            timestamp: boundary.date.timeIntervalSince1970
        )
    }

    var timelineBoundary: ChatTimelineBoundary {
        ChatTimelineBoundary(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId,
            date: Date(timeIntervalSince1970: timestamp)
        )
    }
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
    let url: URL?
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
}

struct ChatCollectionPrefetchItem: Hashable {
    let messagePrimary: String
    let owner: String
    let jid: String
    let avatarURL: URL?
    let images: [ChatCollectionPrefetchImageReference]
    let videos: [ChatCollectionPrefetchVideoReference]
    let locations: [ChatCollectionPrefetchLocationReference]
    let contacts: [ChatCollectionPrefetchContactReference]
}

enum ChatCollectionPrefetchPageDirection: String, Hashable {
    case older
    case newer
}

struct ChatCollectionPrefetchPageWarmup: Hashable {
    let direction: ChatCollectionPrefetchPageDirection
    let conversationKey: ChatCollectionPrefetchConversationKey
    let boundary: ChatCollectionPrefetchBoundary
}

enum ChatCollectionPrefetchResource: Hashable {
    case image(identity: ChatCollectionPrefetchIdentity, request: ChatCollectionPrefetchImageRequest)
    case videoPreview(identity: ChatCollectionPrefetchIdentity, request: ChatCollectionPrefetchImageRequest)
    case avatar(identity: ChatCollectionPrefetchIdentity, request: ChatCollectionPrefetchImageRequest)
    case locationSnapshot(identity: ChatCollectionPrefetchIdentity, location: ChatCollectionPrefetchLocation, size: ChatCollectionPrefetchSize)
    case pageWarmup(ChatCollectionPrefetchPageWarmup)
}

struct ChatCollectionPrefetchContext {
    let conversationKey: ChatCollectionPrefetchConversationKey
    let availability: ChatScrollBoundaryAvailability
    let oldestBoundary: ChatCollectionPrefetchBoundary?
    let newestBoundary: ChatCollectionPrefetchBoundary?
    let firstRealSection: Int?
    let lastRealSection: Int?
    let locationSnapshotSize: ChatCollectionPrefetchSize
    let mediaContainerSize: ChatCollectionPrefetchSize
    let avatarSize: ChatCollectionPrefetchSize
    let contactAvatarSize: ChatCollectionPrefetchSize
    let screenScale: Double
    let traitStyle: ChatThumbnailTraitStyle
    let pageWarmupDistance: Int

    init(
        conversationKey: ChatCollectionPrefetchConversationKey,
        availability: ChatScrollBoundaryAvailability,
        oldestBoundary: ChatCollectionPrefetchBoundary?,
        newestBoundary: ChatCollectionPrefetchBoundary?,
        firstRealSection: Int?,
        lastRealSection: Int?,
        locationSnapshotSize: ChatCollectionPrefetchSize,
        mediaContainerSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 220, height: 220),
        avatarSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 32, height: 32),
        contactAvatarSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 40, height: 40),
        screenScale: Double = 2,
        traitStyle: ChatThumbnailTraitStyle = .unspecified,
        pageWarmupDistance: Int = 2
    ) {
        self.conversationKey = conversationKey
        self.availability = availability
        self.oldestBoundary = oldestBoundary
        self.newestBoundary = newestBoundary
        self.firstRealSection = firstRealSection
        self.lastRealSection = lastRealSection
        self.locationSnapshotSize = locationSnapshotSize
        self.mediaContainerSize = mediaContainerSize
        self.avatarSize = avatarSize
        self.contactAvatarSize = contactAvatarSize
        self.screenScale = screenScale
        self.traitStyle = traitStyle
        self.pageWarmupDistance = pageWarmupDistance
    }

    static func empty(
        conversationKey: ChatCollectionPrefetchConversationKey,
        mediaContainerSize: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 220, height: 220),
        screenScale: Double = 2,
        traitStyle: ChatThumbnailTraitStyle = .unspecified
    ) -> ChatCollectionPrefetchContext {
        ChatCollectionPrefetchContext(
            conversationKey: conversationKey,
            availability: .empty,
            oldestBoundary: nil,
            newestBoundary: nil,
            firstRealSection: nil,
            lastRealSection: nil,
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
        indexPath: IndexPath,
        context: ChatCollectionPrefetchContext
    ) -> Set<ChatCollectionPrefetchResource> {
        var resources = Set<ChatCollectionPrefetchResource>()

        let imageFrames = mediaFrames(count: item.images.count, containerSize: context.mediaContainerSize)
        item.images.enumerated().forEach { index, image in
            guard let url = image.url else { return }
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

        if let avatarURL = item.avatarURL {
            resources.insert(.avatar(
                identity: identity(.avatar, messagePrimary: item.messagePrimary, referencePrimary: item.messagePrimary),
                request: imageRequest(url: avatarURL, displaySize: context.avatarSize, context: context)
            ))
        }

        item.contacts.forEach { contact in
            guard let avatarURL = contact.avatarURL else { return }
            resources.insert(.avatar(
                identity: identity(.contactAvatar, messagePrimary: item.messagePrimary, referencePrimary: contact.primary),
                request: imageRequest(url: avatarURL, displaySize: context.contactAvatarSize, context: context)
            ))
        }

        item.locations.forEach { location in
            guard location.snapshotURL == nil else { return }
            resources.insert(.locationSnapshot(
                identity: identity(.locationSnapshot, messagePrimary: item.messagePrimary, referencePrimary: location.primary),
                location: location.location,
                size: context.locationSnapshotSize
            ))
        }

        pageWarmups(for: indexPath, context: context).forEach { warmup in
            resources.insert(.pageWarmup(warmup))
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

    private static func pageWarmups(
        for indexPath: IndexPath,
        context: ChatCollectionPrefetchContext
    ) -> [ChatCollectionPrefetchPageWarmup] {
        let distance = max(0, context.pageWarmupDistance)
        var warmups: [ChatCollectionPrefetchPageWarmup] = []
        if context.availability.hasLocalOlderPage,
           let firstRealSection = context.firstRealSection,
           indexPath.section <= firstRealSection + distance,
           let oldestBoundary = context.oldestBoundary {
            warmups.append(ChatCollectionPrefetchPageWarmup(
                direction: .older,
                conversationKey: context.conversationKey,
                boundary: oldestBoundary
            ))
        }

        if context.availability.hasLocalNewerPage,
           let lastRealSection = context.lastRealSection,
           indexPath.section >= lastRealSection - distance,
           let newestBoundary = context.newestBoundary {
            warmups.append(ChatCollectionPrefetchPageWarmup(
                direction: .newer,
                conversationKey: context.conversationKey,
                boundary: newestBoundary
            ))
        }

        return warmups
    }
}

protocol ChatCollectionPageWarmupTask: AnyObject {
    func cancel()
}

protocol ChatCollectionPageWarmupProviding: AnyObject {
    func warmup(_ request: ChatCollectionPrefetchPageWarmup, limit: Int) -> ChatCollectionPageWarmupTask
}

private final class ChatCollectionPageWarmupCancellationToken: ChatCollectionPageWarmupTask {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

final class ChatCollectionLocalHistoryPageWarmupProvider: ChatCollectionPageWarmupProviding {
    typealias WorkQueue = (@escaping () -> Void) -> Void

    private let workQueue: WorkQueue

    init(workQueue: @escaping WorkQueue = { work in
        DispatchQueue.global(qos: .utility).async(execute: work)
    }) {
        self.workQueue = workQueue
    }

    func warmup(_ request: ChatCollectionPrefetchPageWarmup, limit: Int) -> ChatCollectionPageWarmupTask {
        let token = ChatCollectionPageWarmupCancellationToken()
        workQueue {
            guard !token.isCancelled else { return }
            do {
                let provider = ChatLocalHistoryPageProvider(
                    realm: try WRealm.safe(),
                    owner: request.conversationKey.owner,
                    jid: request.conversationKey.jid,
                    conversationType: request.conversationKey.resolvedConversationType
                )
                switch request.direction {
                case .older:
                    _ = provider.older(before: request.boundary.timelineBoundary, limit: limit)
                case .newer:
                    _ = provider.newer(after: request.boundary.timelineBoundary, limit: limit)
                }
            } catch {
                DDLogDebug("ChatCollectionLocalHistoryPageWarmupProvider: \(error.localizedDescription)")
            }
        }
        return token
    }
}

final class ChatCollectionContentPrefetcher: ChatCollectionContentPrefetching {
    private let locationSnapshotProvider: ChatLocationSnapshotProviding
    private let pageWarmupProvider: ChatCollectionPageWarmupProviding
    private let thumbnailPipeline: ChatThumbnailServing
    private let pageWarmupLimit: Int
    private var imagePrefetchers: [ChatCollectionPrefetchResource: ChatThumbnailSubscription] = [:]
    private var activeLocationSnapshots = Set<ChatCollectionPrefetchResource>()
    private var locationSnapshotTokens: [ChatCollectionPrefetchResource: UUID] = [:]
    private var pageWarmupTasks: [ChatCollectionPrefetchResource: ChatCollectionPageWarmupTask] = [:]

    var activeImagePrefetchCount: Int {
        imagePrefetchers.count
    }

    var activeLocationSnapshotCount: Int {
        activeLocationSnapshots.count
    }

    var activePageWarmupTaskCount: Int {
        pageWarmupTasks.count
    }

    init(
        locationSnapshotProvider: ChatLocationSnapshotProviding = MapKitChatLocationSnapshotProvider(),
        pageWarmupProvider: ChatCollectionPageWarmupProviding = ChatCollectionLocalHistoryPageWarmupProvider(),
        pageWarmupLimit: Int,
        thumbnailPipeline: ChatThumbnailServing = ChatMediaThumbnailPipeline.shared
    ) {
        self.locationSnapshotProvider = locationSnapshotProvider
        self.pageWarmupProvider = pageWarmupProvider
        self.pageWarmupLimit = pageWarmupLimit
        self.thumbnailPipeline = thumbnailPipeline
    }

    func prefetch(_ resources: Set<ChatCollectionPrefetchResource>) {
        ChatPerformanceSignposts.measure(.mediaPrefetch) {
            resources.forEach { resource in
                switch resource {
                case .image(_, let request),
                     .videoPreview(_, let request),
                     .avatar(_, let request):
                    startImagePrefetch(for: resource, request: request)
                case .locationSnapshot(_, let location, let size):
                    startLocationSnapshotPrefetch(for: resource, location: location, size: size)
                case .pageWarmup(let request):
                    guard pageWarmupTasks[resource] == nil else { return }
                    pageWarmupTasks[resource] = pageWarmupProvider.warmup(
                        request,
                        limit: pageWarmupLimit
                    )
                }
            }
        }
    }

    func cancelPrefetching(_ resources: Set<ChatCollectionPrefetchResource>) {
        resources.forEach { resource in
            if let prefetcher = imagePrefetchers.removeValue(forKey: resource) {
                prefetcher.cancel()
            }
            if let task = pageWarmupTasks.removeValue(forKey: resource) {
                task.cancel()
            }
            activeLocationSnapshots.remove(resource)
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
        location: ChatCollectionPrefetchLocation,
        size: ChatCollectionPrefetchSize
    ) {
        guard !activeLocationSnapshots.contains(resource) else { return }
        let token = UUID()
        activeLocationSnapshots.insert(resource)
        locationSnapshotTokens[resource] = token
        locationSnapshotProvider.makeSnapshot(
            for: location.resolvedLocation,
            size: size.cgSize
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      self.locationSnapshotTokens[resource] == token else {
                    return
                }
                self.locationSnapshotTokens.removeValue(forKey: resource)
                self.activeLocationSnapshots.remove(resource)
            }
        }
    }
}

extension ChatViewController.Datasource {
    var collectionPrefetchItem: ChatCollectionPrefetchItem {
        ChatCollectionPrefetchItem(
            messagePrimary: primary,
            owner: owner,
            jid: jid,
            avatarURL: avatarUrl.flatMap(URL.init(string:)),
            images: images.map {
                ChatCollectionPrefetchImageReference(
                    primary: $0.primary,
                    url: $0.url
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
                    avatarURL: $0.avatarURL.flatMap(URL.init(string:))
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
        let conversationKey = chatTimelineConversationKey
        let normalizedState = virtualTimelineState.normalized(
            owner: conversationKey.owner,
            jid: conversationKey.jid,
            conversationType: conversationKey.conversationType
        )
        let firstRealSection = datasource.firstIndex(where: { !$0.isFakeMessage })
        let lastRealSection = datasource.lastIndex(where: { !$0.isFakeMessage })
        let flowLayout = messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
        let layoutWidth = flowLayout?.itemWidth ?? messagesCollectionView.bounds.width
        // ChatMessageLayoutCalculator subtracts 76 points from the item width,
        // caps a top-level message at 420, then the media view removes 4 points.
        let width = max(1, min(420, layoutWidth - 76) - 4)
        let mediaSize = ChatCollectionPrefetchSize(width: Double(width), height: Double(width))
        return ChatCollectionPrefetchContext(
            conversationKey: ChatCollectionPrefetchConversationKey(conversationKey),
            availability: scrollBoundaryAvailabilityCache.availability(for: conversationKey) ?? .empty,
            oldestBoundary: normalizedState.oldest.map(ChatCollectionPrefetchBoundary.init),
            newestBoundary: normalizedState.newest.map(ChatCollectionPrefetchBoundary.init),
            firstRealSection: firstRealSection,
            lastRealSection: lastRealSection,
            locationSnapshotSize: mediaSize,
            mediaContainerSize: mediaSize,
            avatarSize: ChatCollectionPrefetchSize(width: 32, height: 32),
            contactAvatarSize: ChatCollectionPrefetchSize(width: 40, height: 40),
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
        case .locationSnapshot, .pageWarmup:
            return nil
        }
    }
}
