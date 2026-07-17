import XCTest
@testable import xabber

final class ChatCollectionPrefetchTests: XCTestCase {
    func testPrefetchGroupsSupportedResourcesByMessageAndReferenceIdentity() {
        let imageURL = URL(string: "https://cdn.example.com/shared.jpg")!
        let videoPreviewURL = URL(string: "https://cdn.example.com/video-preview.jpg")!
        let avatarURL = URL(string: "https://cdn.example.com/avatar.png")!
        let contactAvatarURL = URL(string: "https://cdn.example.com/contact-avatar.png")!
        let mediaSize = ChatCollectionPrefetchSize(width: 240, height: 240)
        let avatarSize = ChatCollectionPrefetchSize(width: 32, height: 32)
        let contactAvatarSize = ChatCollectionPrefetchSize(width: 40, height: 40)
        let screenScale = 3.0
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let newest = boundary(primary: "newest", archivedId: "10")
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                switch indexPath.section {
                case 0:
                    return self.item(
                        primary: "m1",
                        avatarURL: avatarURL,
                        images: [.init(primary: "img1", url: imageURL)],
                        videos: [.init(primary: "vid1", url: URL(string: "https://cdn.example.com/video.mov")!, previewURL: videoPreviewURL)],
                        locations: [.init(primary: "loc1", latitude: 51.5, longitude: -0.12, address: "London", geoURI: "geo:51.5,-0.12", snapshotURL: nil)],
                        contacts: [.init(primary: "contact1", owner: "owner@example.com", jid: "friend@example.com", avatarURL: contactAvatarURL)]
                    )
                case 1:
                    return self.item(
                        primary: "m2",
                        images: [.init(primary: "img2", url: imageURL)]
                    )
                default:
                    return nil
                }
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: false,
                        hasKnownArchiveGapAbove: false,
                        hasKnownArchiveGapBelow: false,
                        hasRemoteOlderPage: false,
                        hasRemoteNewerPage: false,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: newest,
                    firstRealSection: 0,
                    lastRealSection: 1,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220),
                    mediaContainerSize: mediaSize,
                    avatarSize: avatarSize,
                    contactAvatarSize: contactAvatarSize,
                    screenScale: screenScale
                )
            },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 0, section: 1)
        ])

        let resources = prefetcher.prefetchedResources()
        XCTAssertTrue(resources.contains(.image(identity: identity(.image, message: "m1", reference: "img1"), request: mediaRequest(url: imageURL, size: mediaSize, scale: screenScale))))
        XCTAssertTrue(resources.contains(.image(identity: identity(.image, message: "m2", reference: "img2"), request: mediaRequest(url: imageURL, size: mediaSize, scale: screenScale))))
        XCTAssertTrue(resources.contains(.videoPreview(identity: identity(.videoPreview, message: "m1", reference: "vid1"), request: mediaRequest(url: videoPreviewURL, size: mediaSize, scale: screenScale))))
        XCTAssertTrue(resources.contains(.avatar(
            identity: identity(.avatar, message: "m1", reference: "m1"),
            request: ChatAvatarRequest(
                entityIdentity: "",
                remoteURL: avatarURL,
                displayName: "chat@example.com",
                colorKey: "owner@example.com",
                displaySize: avatarSize,
                scale: screenScale,
                traitStyle: .unspecified
            )
        )))
        XCTAssertTrue(resources.contains(.avatar(
            identity: identity(.contactAvatar, message: "m1", reference: "contact1"),
            request: ChatAvatarRequest(
                entityIdentity: "friend@example.com",
                remoteURL: contactAvatarURL,
                displayName: "friend@example.com",
                colorKey: "friend@example.com",
                displaySize: contactAvatarSize,
                scale: screenScale,
                traitStyle: .unspecified
            )
        )))
        XCTAssertTrue(resources.contains(.locationSnapshot(
            identity: identity(.locationSnapshot, message: "m1", reference: "loc1"),
            request: ChatLocationSnapshotRequest(
                latitude: 51.5,
                longitude: -0.12,
                displaySize: ChatCollectionPrefetchSize(width: 220, height: 220),
                scale: screenScale,
                mapStyle: .standard,
                traitStyle: .unspecified
            )
        )))
        XCTAssertTrue(resources.contains(.pageWarmup(ChatCollectionPrefetchPageWarmup(
            direction: .older,
            conversationKey: key,
            boundary: oldest
        ))))
    }

    func testCancellationUsesStoredIdentitiesInsteadOfCurrentIndexPathItem() {
        let oldURL = URL(string: "https://cdn.example.com/old.jpg")!
        let newURL = URL(string: "https://cdn.example.com/new.jpg")!
        var currentItem = item(primary: "old-message", images: [.init(primary: "old-image", url: oldURL)])
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { _ in currentItem },
            contextProvider: { .empty(conversationKey: self.conversationKey()) },
            prefetcher: prefetcher
        )
        let indexPath = IndexPath(item: 0, section: 0)

        coordinator.prefetchItems(at: [indexPath])
        currentItem = item(primary: "new-message", images: [.init(primary: "new-image", url: newURL)])
        coordinator.cancelPrefetchingForItems(at: [indexPath])

        let cancelled = prefetcher.cancelledResources()
        XCTAssertTrue(cancelled.contains(.image(identity: identity(.image, message: "old-message", reference: "old-image"), request: mediaRequest(url: oldURL))))
        XCTAssertFalse(cancelled.contains(.image(identity: identity(.image, message: "new-message", reference: "new-image"), request: mediaRequest(url: newURL))))
    }

    func testIndexPathShiftKeepsStableResourceUntilItsFinalOwnerCancels() {
        let url = URL(string: "https://cdn.example.com/stable.jpg")!
        let stableItem = item(primary: "stable-message", images: [.init(primary: "stable-image", url: url)])
        var currentSection = 0
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                indexPath.section == currentSection ? stableItem : nil
            },
            contextProvider: { .empty(conversationKey: self.conversationKey()) },
            prefetcher: prefetcher
        )
        let oldIndexPath = IndexPath(item: 0, section: 0)
        let shiftedIndexPath = IndexPath(item: 0, section: 1)
        let resource = ChatCollectionPrefetchResource.image(
            identity: identity(.image, message: "stable-message", reference: "stable-image"),
            request: mediaRequest(url: url)
        )

        coordinator.prefetchItems(at: [oldIndexPath])
        currentSection = 1
        coordinator.prefetchItems(at: [shiftedIndexPath])
        coordinator.cancelPrefetchingForItems(at: [oldIndexPath])

        XCTAssertFalse(prefetcher.cancelledResources().contains(resource))

        coordinator.cancelPrefetchingForItems(at: [shiftedIndexPath])
        XCTAssertTrue(prefetcher.cancelledResources().contains(resource))
    }

    func testPrefetchRequestsIncludeDownsamplingCacheKeysForRenderedSize() throws {
        let imageURL = URL(string: "https://cdn.example.com/full-resolution.jpg")!
        let resources = ChatCollectionPrefetchPlanner.resources(
            for: item(
                primary: "message",
                images: [.init(primary: "image", url: imageURL)]
            ),
            indexPath: IndexPath(item: 0, section: 0),
            context: .empty(
                conversationKey: conversationKey(),
                mediaContainerSize: ChatCollectionPrefetchSize(width: 180, height: 120),
                screenScale: 3
            )
        )

        let request = try XCTUnwrap(resources.compactMap { resource -> ChatCollectionPrefetchImageRequest? in
            if case .image(_, let request) = resource {
                return request
            }
            return nil
        }.first)
        XCTAssertEqual(request.displaySize, ChatCollectionPrefetchSize(width: 180, height: 120))
        XCTAssertEqual(request.pixelSize, ChatCollectionPrefetchSize(width: 540, height: 360))
        XCTAssertEqual(request.scale, 3)
        XCTAssertTrue(request.cacheKey.contains("540x360@3"))
    }

    func testContentPrefetcherDoesNotStartDuplicateImageWork() {
        let imageURL = URL(string: "https://cdn.example.com/duplicate.jpg")!
        let pipeline = FakeChatCollectionThumbnailPipeline()
        let prefetcher = ChatCollectionContentPrefetcher(
            locationSnapshotPipeline: FakeChatLocationSnapshotProvider(),
            pageWarmupProvider: FakeChatCollectionPageWarmupProvider(),
            pageWarmupLimit: 20,
            thumbnailPipeline: pipeline
        )
        let resource = ChatCollectionPrefetchResource.image(
            identity: identity(.image, message: "message", reference: "image"),
            request: mediaRequest(url: imageURL)
        )

        prefetcher.prefetch([resource])
        prefetcher.prefetch([resource])

        XCTAssertEqual(pipeline.requests.count, 1)
        XCTAssertEqual(prefetcher.activeImagePrefetchCount, 1)
    }

    func testCoordinatorCancelAllClearsImageWarmupAndLocationWork() {
        let imageURL = URL(string: "https://cdn.example.com/image.jpg")!
        let snapshotProvider = FakeChatLocationSnapshotProvider()
        let warmupProvider = FakeChatCollectionPageWarmupProvider()
        let thumbnailPipeline = FakeChatCollectionThumbnailPipeline()
        let contentPrefetcher = ChatCollectionContentPrefetcher(
            locationSnapshotPipeline: snapshotProvider,
            pageWarmupProvider: warmupProvider,
            pageWarmupLimit: 20,
            thumbnailPipeline: thumbnailPipeline
        )
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { _ in
                self.item(
                    primary: "message",
                    images: [.init(primary: "image", url: imageURL)],
                    locations: [.init(primary: "loc", latitude: 51.5, longitude: -0.12, address: "London", geoURI: "geo:51.5,-0.12", snapshotURL: nil)]
                )
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: false,
                        hasKnownArchiveGapAbove: false,
                        hasKnownArchiveGapBelow: false,
                        hasRemoteOlderPage: false,
                        hasRemoteNewerPage: false,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: nil,
                    firstRealSection: 0,
                    lastRealSection: 0,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220)
                )
            },
            prefetcher: contentPrefetcher
        )

        coordinator.prefetchItems(at: [IndexPath(item: 0, section: 0)])
        XCTAssertEqual(contentPrefetcher.activeImagePrefetchCount, 1)
        XCTAssertEqual(contentPrefetcher.activePageWarmupTaskCount, 1)
        XCTAssertEqual(contentPrefetcher.activeLocationSnapshotCount, 1)

        coordinator.cancelAll()

        XCTAssertEqual(thumbnailPipeline.subscriptions.first?.cancelCount, 1)
        XCTAssertEqual(warmupProvider.tasks.first?.cancelCount, 1)
        XCTAssertEqual(contentPrefetcher.activeImagePrefetchCount, 0)
        XCTAssertEqual(contentPrefetcher.activePageWarmupTaskCount, 0)
        XCTAssertEqual(contentPrefetcher.activeLocationSnapshotCount, 0)

        snapshotProvider.completeAll(with: .failure(.loadFailed))
        XCTAssertEqual(contentPrefetcher.activeLocationSnapshotCount, 0)
    }

    func testUploadingImagePrefetchUsesLocalFileURLUntilRemoteExists() throws {
        let localURL = URL(fileURLWithPath: "/tmp/uploading-local-image.jpg")
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.com/uploaded-image.jpg"))
        let uploading = mediaReference(primary: "uploading", localURL: localURL, remoteURL: nil)
        let uploaded = mediaReference(primary: "uploaded", localURL: localURL, remoteURL: remoteURL)

        XCTAssertEqual(ChatViewController.mapReferenceAttachments([uploading]).images.first?.url, localURL)
        XCTAssertEqual(ChatViewController.mapReferenceAttachments([uploaded]).images.first?.url, remoteURL)
    }

    func testStaleIndexPathsAfterDatasetShrinkDoNotPrefetchWrongContent() {
        let visibleURL = URL(string: "https://cdn.example.com/visible.jpg")!
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                indexPath.section == 0
                    ? self.item(primary: "visible", images: [.init(primary: "visible-image", url: visibleURL)])
                    : nil
            },
            contextProvider: { .empty(conversationKey: self.conversationKey()) },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [IndexPath(item: 0, section: 4)])

        XCTAssertTrue(prefetcher.prefetchedResources().isEmpty)
    }

    func testPageWarmupUsesOnlyCachedLocalBoundaryAvailability() {
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let newest = boundary(primary: "newest", archivedId: "10")
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                self.item(primary: "m\(indexPath.section)")
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: true,
                        hasKnownArchiveGapAbove: true,
                        hasKnownArchiveGapBelow: true,
                        hasRemoteOlderPage: true,
                        hasRemoteNewerPage: true,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: newest,
                    firstRealSection: 0,
                    lastRealSection: 9,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220),
                    pageWarmupDistance: 1
                )
            },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 0, section: 9)
        ])

        let pageWarmups = prefetcher.prefetchedResources().compactMap { resource -> ChatCollectionPrefetchPageWarmup? in
            if case .pageWarmup(let warmup) = resource {
                return warmup
            }
            return nil
        }
        XCTAssertEqual(Set(pageWarmups.map(\.direction)), [.older, .newer])
        XCTAssertTrue(pageWarmups.allSatisfy { $0.conversationKey == key })
        XCTAssertTrue(pageWarmups.contains(ChatCollectionPrefetchPageWarmup(direction: .older, conversationKey: key, boundary: oldest)))
        XCTAssertTrue(pageWarmups.contains(ChatCollectionPrefetchPageWarmup(direction: .newer, conversationKey: key, boundary: newest)))
    }

    func testShortResidentRangeCanWarmBothLocalBoundariesFromSameIndexPath() {
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let newest = boundary(primary: "newest", archivedId: "10")
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { _ in
                self.item(primary: "only-visible-message")
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: true,
                        hasKnownArchiveGapAbove: false,
                        hasKnownArchiveGapBelow: false,
                        hasRemoteOlderPage: false,
                        hasRemoteNewerPage: false,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: newest,
                    firstRealSection: 0,
                    lastRealSection: 0,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220),
                    pageWarmupDistance: 0
                )
            },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [IndexPath(item: 0, section: 0)])

        let pageWarmups = prefetcher.prefetchedResources().compactMap { resource -> ChatCollectionPrefetchPageWarmup? in
            if case .pageWarmup(let warmup) = resource {
                return warmup
            }
            return nil
        }
        XCTAssertEqual(Set(pageWarmups), [
            ChatCollectionPrefetchPageWarmup(direction: .older, conversationKey: key, boundary: oldest),
            ChatCollectionPrefetchPageWarmup(direction: .newer, conversationKey: key, boundary: newest)
        ])
    }

    private func item(
        primary: String,
        owner: String = "owner@example.com",
        jid: String = "chat@example.com",
        avatarURL: URL? = nil,
        images: [ChatCollectionPrefetchImageReference] = [],
        videos: [ChatCollectionPrefetchVideoReference] = [],
        locations: [ChatCollectionPrefetchLocationReference] = [],
        contacts: [ChatCollectionPrefetchContactReference] = []
    ) -> ChatCollectionPrefetchItem {
        ChatCollectionPrefetchItem(
            messagePrimary: primary,
            owner: owner,
            jid: jid,
            avatarURL: avatarURL,
            images: images,
            videos: videos,
            locations: locations,
            contacts: contacts
        )
    }

    private func identity(
        _ kind: ChatCollectionPrefetchIdentity.Kind,
        message: String,
        reference: String
    ) -> ChatCollectionPrefetchIdentity {
        ChatCollectionPrefetchIdentity(
            kind: kind,
            messagePrimary: message,
            referencePrimary: reference
        )
    }

    private func conversationKey() -> ChatCollectionPrefetchConversationKey {
        ChatCollectionPrefetchConversationKey(
            owner: "owner@example.com",
            jid: "chat@example.com",
            conversationType: "regular"
        )
    }

    private func boundary(primary: String, archivedId: String) -> ChatCollectionPrefetchBoundary {
        ChatCollectionPrefetchBoundary(
            primary: primary,
            archivedId: archivedId,
            messageId: "message-\(primary)",
            timestamp: 100
        )
    }

    private func mediaRequest(
        url: URL,
        size: ChatCollectionPrefetchSize = ChatCollectionPrefetchSize(width: 220, height: 220),
        scale: Double = 2
    ) -> ChatCollectionPrefetchImageRequest {
        ChatCollectionPrefetchImageRequest(url: url, displaySize: size, scale: scale)
    }

    private func mediaReference(primary: String, localURL: URL, remoteURL: URL?) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = primary
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.metadata = ["media-type": "image/jpeg"]
        reference.localFileUrl = localURL
        reference.downloadUrl = remoteURL
        return reference
    }
}

private final class FakeChatCollectionContentPrefetcher: ChatCollectionContentPrefetching {
    private var prefetched: [Set<ChatCollectionPrefetchResource>] = []
    private var cancelled: [Set<ChatCollectionPrefetchResource>] = []

    func prefetch(_ resources: Set<ChatCollectionPrefetchResource>) {
        prefetched.append(resources)
    }

    func cancelPrefetching(_ resources: Set<ChatCollectionPrefetchResource>) {
        cancelled.append(resources)
    }

    func prefetchedResources() -> Set<ChatCollectionPrefetchResource> {
        prefetched.reduce(into: Set<ChatCollectionPrefetchResource>()) { partialResult, resources in
            partialResult.formUnion(resources)
        }
    }

    func cancelledResources() -> Set<ChatCollectionPrefetchResource> {
        cancelled.reduce(into: Set<ChatCollectionPrefetchResource>()) { partialResult, resources in
            partialResult.formUnion(resources)
        }
    }
}

private final class FakeChatCollectionThumbnailPipeline: ChatThumbnailServing {
    private(set) var requests: [ChatThumbnailRequest] = []
    private(set) var subscriptions: [FakeChatCollectionThumbnailSubscription] = []

    func acquire(
        _ request: ChatThumbnailRequest,
        consumer: ChatThumbnailConsumer,
        completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    ) -> ChatThumbnailSubscription {
        let subscription = FakeChatCollectionThumbnailSubscription()
        requests.append(request)
        subscriptions.append(subscription)
        return subscription
    }
}

private final class FakeChatCollectionThumbnailSubscription: ChatThumbnailSubscription {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class FakeChatCollectionPageWarmupProvider: ChatCollectionPageWarmupProviding {
    private(set) var tasks: [FakeChatCollectionPageWarmupTask] = []

    func warmup(_ request: ChatCollectionPrefetchPageWarmup, limit: Int) -> ChatCollectionPageWarmupTask {
        let task = FakeChatCollectionPageWarmupTask()
        tasks.append(task)
        return task
    }
}

private final class FakeChatCollectionPageWarmupTask: ChatCollectionPageWarmupTask {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class FakeChatLocationSnapshotProvider: ChatLocationSnapshotServing {
    private var completions: [(Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void] = []
    private(set) var subscriptions: [FakeChatLocationSnapshotSubscription] = []

    @discardableResult
    func acquire(
        _ request: ChatLocationSnapshotRequest,
        consumer: ChatLocationSnapshotConsumer,
        completion: ((Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void)?
    ) -> ChatLocationSnapshotSubscription {
        let subscription = FakeChatLocationSnapshotSubscription()
        subscriptions.append(subscription)
        completions.append(completion ?? { _ in })
        return subscription
    }

    func completeAll(with result: Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) {
        let completions = completions
        self.completions.removeAll()
        completions.forEach { $0(result) }
    }
}

private final class FakeChatLocationSnapshotSubscription: ChatLocationSnapshotSubscription {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}
