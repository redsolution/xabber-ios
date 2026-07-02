import CoreGraphics
import Foundation
import Kingfisher
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
}

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
    case image(identity: ChatCollectionPrefetchIdentity, url: URL)
    case videoPreview(identity: ChatCollectionPrefetchIdentity, url: URL)
    case avatar(identity: ChatCollectionPrefetchIdentity, url: URL)
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
    let pageWarmupDistance: Int

    init(
        conversationKey: ChatCollectionPrefetchConversationKey,
        availability: ChatScrollBoundaryAvailability,
        oldestBoundary: ChatCollectionPrefetchBoundary?,
        newestBoundary: ChatCollectionPrefetchBoundary?,
        firstRealSection: Int?,
        lastRealSection: Int?,
        locationSnapshotSize: ChatCollectionPrefetchSize,
        pageWarmupDistance: Int = 2
    ) {
        self.conversationKey = conversationKey
        self.availability = availability
        self.oldestBoundary = oldestBoundary
        self.newestBoundary = newestBoundary
        self.firstRealSection = firstRealSection
        self.lastRealSection = lastRealSection
        self.locationSnapshotSize = locationSnapshotSize
        self.pageWarmupDistance = pageWarmupDistance
    }

    static func empty(conversationKey: ChatCollectionPrefetchConversationKey) -> ChatCollectionPrefetchContext {
        ChatCollectionPrefetchContext(
            conversationKey: conversationKey,
            availability: .empty,
            oldestBoundary: nil,
            newestBoundary: nil,
            firstRealSection: nil,
            lastRealSection: nil,
            locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220)
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
            if removedResources.isNotEmpty {
                prefetcher.cancelPrefetching(removedResources)
            }

            activeResourcesByIndexPath[indexPath] = resources
            resourcesToPrefetch.formUnion(resources)
        }

        if resourcesToPrefetch.isNotEmpty {
            prefetcher.prefetch(resourcesToPrefetch)
        }
    }

    func cancelPrefetchingForItems(at indexPaths: [IndexPath]) {
        var resourcesToCancel = Set<ChatCollectionPrefetchResource>()
        indexPaths.forEach { indexPath in
            if let resources = activeResourcesByIndexPath.removeValue(forKey: indexPath) {
                resourcesToCancel.formUnion(resources)
            }
        }

        if resourcesToCancel.isNotEmpty {
            prefetcher.cancelPrefetching(resourcesToCancel)
        }
    }

    func cancelAll() {
        let resourcesToCancel = activeResourcesByIndexPath.values.reduce(into: Set<ChatCollectionPrefetchResource>()) { result, resources in
            result.formUnion(resources)
        }
        activeResourcesByIndexPath.removeAll()
        if resourcesToCancel.isNotEmpty {
            prefetcher.cancelPrefetching(resourcesToCancel)
        }
    }
}

enum ChatCollectionPrefetchPlanner {
    static func resources(
        for item: ChatCollectionPrefetchItem,
        indexPath: IndexPath,
        context: ChatCollectionPrefetchContext
    ) -> Set<ChatCollectionPrefetchResource> {
        var resources = Set<ChatCollectionPrefetchResource>()

        item.images.forEach { image in
            guard let url = image.url else { return }
            resources.insert(.image(
                identity: identity(.image, messagePrimary: item.messagePrimary, referencePrimary: image.primary),
                url: url
            ))
        }

        item.videos.forEach { video in
            guard let url = video.previewURL else { return }
            resources.insert(.videoPreview(
                identity: identity(.videoPreview, messagePrimary: item.messagePrimary, referencePrimary: video.primary),
                url: url
            ))
        }

        if let avatarURL = item.avatarURL {
            resources.insert(.avatar(
                identity: identity(.avatar, messagePrimary: item.messagePrimary, referencePrimary: item.messagePrimary),
                url: avatarURL
            ))
        }

        item.contacts.forEach { contact in
            guard let avatarURL = contact.avatarURL else { return }
            resources.insert(.avatar(
                identity: identity(.contactAvatar, messagePrimary: item.messagePrimary, referencePrimary: contact.primary),
                url: avatarURL
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
    private let pageWarmupLimit: Int
    private var imagePrefetchers: [ChatCollectionPrefetchResource: ImagePrefetcher] = [:]
    private var activeLocationSnapshots = Set<ChatCollectionPrefetchResource>()
    private var pageWarmupTasks: [ChatCollectionPrefetchResource: ChatCollectionPageWarmupTask] = [:]

    init(
        locationSnapshotProvider: ChatLocationSnapshotProviding = MapKitChatLocationSnapshotProvider(),
        pageWarmupProvider: ChatCollectionPageWarmupProviding = ChatCollectionLocalHistoryPageWarmupProvider(),
        pageWarmupLimit: Int
    ) {
        self.locationSnapshotProvider = locationSnapshotProvider
        self.pageWarmupProvider = pageWarmupProvider
        self.pageWarmupLimit = pageWarmupLimit
    }

    func prefetch(_ resources: Set<ChatCollectionPrefetchResource>) {
        resources.forEach { resource in
            switch resource {
            case .image(_, let url),
                 .videoPreview(_, let url),
                 .avatar(_, let url):
                startImagePrefetch(for: resource, url: url)
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

    func cancelPrefetching(_ resources: Set<ChatCollectionPrefetchResource>) {
        resources.forEach { resource in
            if let prefetcher = imagePrefetchers.removeValue(forKey: resource) {
                prefetcher.stop()
            }
            if let task = pageWarmupTasks.removeValue(forKey: resource) {
                task.cancel()
            }
            activeLocationSnapshots.remove(resource)
        }
    }

    private func startImagePrefetch(for resource: ChatCollectionPrefetchResource, url: URL) {
        guard imagePrefetchers[resource] == nil else { return }
        let prefetcher = ImagePrefetcher(
            urls: [url],
            options: [.alsoPrefetchToMemory, .backgroundDecode]
        )
        imagePrefetchers[resource] = prefetcher
        prefetcher.start()
    }

    private func startLocationSnapshotPrefetch(
        for resource: ChatCollectionPrefetchResource,
        location: ChatCollectionPrefetchLocation,
        size: ChatCollectionPrefetchSize
    ) {
        guard !activeLocationSnapshots.contains(resource) else { return }
        activeLocationSnapshots.insert(resource)
        locationSnapshotProvider.makeSnapshot(
            for: location.resolvedLocation,
            size: size.cgSize
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.activeLocationSnapshots.remove(resource)
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
                    previewURL: $0.previewUrl
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
        let width = max(
            1,
            min(
                320,
                messagesCollectionView.bounds.width -
                    messagesCollectionView.adjustedContentInset.left -
                    messagesCollectionView.adjustedContentInset.right
            )
        )
        return ChatCollectionPrefetchContext(
            conversationKey: ChatCollectionPrefetchConversationKey(conversationKey),
            availability: scrollBoundaryAvailabilityCache.availability(for: conversationKey) ?? .empty,
            oldestBoundary: normalizedState.oldest.map(ChatCollectionPrefetchBoundary.init),
            newestBoundary: normalizedState.newest.map(ChatCollectionPrefetchBoundary.init),
            firstRealSection: firstRealSection,
            lastRealSection: lastRealSection,
            locationSnapshotSize: ChatCollectionPrefetchSize(width: Double(width), height: Double(width))
        )
    }
}
