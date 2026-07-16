import UIKit
import XCTest
@testable import xabber

final class ChatMediaThumbnailPipelineTests: XCTestCase {
    func testPrefetchAndVisibleRequestsHaveIdenticalProcessedIdentity() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/photo.jpg"))
        let renderedSize = ChatCollectionPrefetchSize(width: 180, height: 120)
        let resources = ChatCollectionPrefetchPlanner.resources(
            for: item(imageURL: url),
            indexPath: IndexPath(item: 0, section: 0),
            context: .empty(
                conversationKey: conversationKey(),
                mediaContainerSize: renderedSize,
                screenScale: 3,
                traitStyle: .dark
            )
        )
        let prefetched = try XCTUnwrap(resources.compactMap { resource -> ChatThumbnailRequest? in
            guard case .image(_, let request) = resource else { return nil }
            return request
        }.first)
        let visible = ChatThumbnailRequest(
            url: url,
            displaySize: renderedSize,
            scale: 3,
            traitStyle: .dark
        )

        XCTAssertEqual(prefetched, visible)
        XCTAssertEqual(prefetched.pixelSize, ChatCollectionPrefetchSize(width: 540, height: 360))
        XCTAssertEqual(prefetched.cacheKey, visible.cacheKey)
        XCTAssertEqual(prefetched.processorIdentifier, visible.processorIdentifier)
    }

    func testVideoPrefetchUsesSameRenderedFrameAsVisibleGrid() throws {
        let previewURL = try XCTUnwrap(URL(string: "https://cdn.example.com/video-preview.jpg"))
        let grid = InlineVideosGridView(frame: CGRect(x: 0, y: 0, width: 96, height: 80))
        let serving = RecordingChatThumbnailServing()
        grid.thumbnailPipeline = serving
        let video = VideoAttachment(
            primary: "video",
            url: URL(string: "https://cdn.example.com/video.mp4"),
            size: CGSize(width: 100, height: 80),
            previewUrl: previewURL,
            duration: 4,
            downloaded: true
        )
        grid.configure([video], representedBy: "message")
        let visible = try XCTUnwrap(serving.requests.first)
        let resources = ChatCollectionPrefetchPlanner.resources(
            for: ChatCollectionPrefetchItem(
                messagePrimary: "message",
                owner: "owner@example.com",
                jid: "chat@example.com",
                avatarURL: nil,
                images: [],
                videos: [.init(
                    primary: "video",
                    url: video.url,
                    previewURL: previewURL,
                    size: .init(width: 100, height: 80)
                )],
                locations: [],
                contacts: []
            ),
            indexPath: IndexPath(item: 0, section: 0),
            context: .empty(
                conversationKey: conversationKey(),
                mediaContainerSize: .init(width: 96, height: 96),
                screenScale: Double(UIScreen.main.scale),
                traitStyle: ChatThumbnailTraitStyle(grid.traitCollection.userInterfaceStyle)
            )
        )
        let prefetched = try XCTUnwrap(resources.compactMap { resource -> ChatThumbnailRequest? in
            guard case .videoPreview(_, let request) = resource else { return nil }
            return request
        }.first)

        XCTAssertEqual(prefetched, visible)
        XCTAssertEqual(prefetched.displaySize, .init(width: 96, height: 80))
    }

    func testProcessedPrefetchIsConsumedByVisibleBindingWithoutSecondLoadOrDecode() {
        let loader = FakeChatThumbnailLoader()
        let cache = FakeChatThumbnailCache()
        let pipeline = ChatMediaThumbnailPipeline(loader: loader, cache: cache, maxConcurrentWork: 2)
        let request = thumbnailRequest(path: "shared.jpg")
        var prefetchDelivery: ChatThumbnailDelivery?
        var visibleDelivery: ChatThumbnailDelivery?

        let prefetch = pipeline.acquire(request, consumer: consumer("message", "image", role: .prefetch)) {
            prefetchDelivery = try? $0.get()
        }
        XCTAssertEqual(loader.startedRequests, [request])
        withExtendedLifetime(prefetch) {
            loader.completeFirst(with: .success(payload(pixelWidth: 440, pixelHeight: 440)))
        }
        XCTAssertEqual(prefetchDelivery?.source, .loader)

        let visible = pipeline.acquire(request, consumer: consumer("message", "image", role: .visible(UUID()))) {
            visibleDelivery = try? $0.get()
        }
        withExtendedLifetime(visible) {}

        XCTAssertEqual(loader.startedRequests, [request])
        XCTAssertEqual(loader.decodeCount, 1)
        XCTAssertEqual(visibleDelivery?.source, .processedMemoryCache)
        XCTAssertEqual(pipeline.metrics.processedMemoryCacheHitCount, 1)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 0)
        XCTAssertEqual(pipeline.metrics.queuedWorkCount, 0)
    }

    func testSameURLWithDifferentSizeScaleOrStyleUsesDistinctProcessedIdentity() {
        let url = URL(string: "https://cdn.example.com/shared.jpg")!
        let base = ChatThumbnailRequest(
            url: url,
            displaySize: .init(width: 120, height: 80),
            scale: 2,
            traitStyle: .light
        )
        let resized = ChatThumbnailRequest(
            url: url,
            displaySize: .init(width: 240, height: 160),
            scale: 2,
            traitStyle: .light
        )
        let rescaled = ChatThumbnailRequest(
            url: url,
            displaySize: .init(width: 120, height: 80),
            scale: 3,
            traitStyle: .light
        )
        let restyled = ChatThumbnailRequest(
            url: url,
            displaySize: .init(width: 120, height: 80),
            scale: 2,
            traitStyle: .dark
        )

        XCTAssertEqual(Set([base, resized, rescaled, restyled]).count, 4)
        XCTAssertEqual(Set([base.cacheKey, resized.cacheKey, rescaled.cacheKey, restyled.cacheKey]).count, 4)
        XCTAssertEqual(Set([base.processorIdentifier, resized.processorIdentifier, rescaled.processorIdentifier]).count, 3)
    }

    func testSharedWorkLivesUntilFinalConsumerReleasesIt() {
        let loader = FakeChatThumbnailLoader()
        let pipeline = ChatMediaThumbnailPipeline(
            loader: loader,
            cache: FakeChatThumbnailCache(),
            maxConcurrentWork: 2
        )
        let request = thumbnailRequest(path: "shared.jpg")
        let first = pipeline.acquire(request, consumer: consumer("m1", "r1", role: .prefetch), completion: nil)
        let second = pipeline.acquire(request, consumer: consumer("m2", "r2", role: .prefetch), completion: nil)

        XCTAssertEqual(loader.startedRequests.count, 1)
        XCTAssertEqual(pipeline.metrics.deduplicatedAcquireCount, 1)
        first.cancel()
        XCTAssertEqual(loader.tasks.first?.cancelCount, 0)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 1)

        second.cancel()
        XCTAssertEqual(loader.tasks.first?.cancelCount, 1)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 0)
        XCTAssertEqual(pipeline.metrics.queuedWorkCount, 0)
    }

    func testCancelledConsumerDoesNotReceiveDelayedResultAfterReuse() {
        let loader = FakeChatThumbnailLoader()
        let pipeline = ChatMediaThumbnailPipeline(
            loader: loader,
            cache: FakeChatThumbnailCache(),
            maxConcurrentWork: 1
        )
        var deliveries = 0
        let subscription = pipeline.acquire(
            thumbnailRequest(path: "old.jpg"),
            consumer: consumer("message", "reference", role: .visible(UUID()))
        ) { _ in
            deliveries += 1
        }

        subscription.cancel()
        loader.completeFirst(with: .success(payload(pixelWidth: 440, pixelHeight: 440)))

        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 0)
    }

    func testOversizedLoaderResultIsRejectedAndNeverCached() {
        let loader = FakeChatThumbnailLoader()
        let cache = FakeChatThumbnailCache()
        let pipeline = ChatMediaThumbnailPipeline(loader: loader, cache: cache, maxConcurrentWork: 1)
        let request = thumbnailRequest(path: "8k.jpg", width: 220, height: 220, scale: 3)
        var result: Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>?

        let subscription = pipeline.acquire(
            request,
            consumer: consumer("message", "8k", role: .visible(UUID()))
        ) { result = $0 }
        withExtendedLifetime(subscription) {
            loader.completeFirst(with: .success(payload(pixelWidth: 8_000, pixelHeight: 8_000)))
        }

        XCTAssertEqual(try? result?.get().pixelSize, nil)
        XCTAssertEqual(result?.failure, .oversizedResult)
        XCTAssertNil(cache.image(for: request))
        XCTAssertEqual(pipeline.metrics.rejectedOversizedResultCount, 1)
    }

    func testRapidFlingKeepsConcurrencyAndQueuedMemoryBounded() {
        let loader = FakeChatThumbnailLoader()
        let pipeline = ChatMediaThumbnailPipeline(
            loader: loader,
            cache: FakeChatThumbnailCache(),
            maxConcurrentWork: 3,
            maxQueuedWork: 24
        )
        let subscriptions = (0..<100).map { index in
            pipeline.acquire(
                thumbnailRequest(path: "image-\(index).jpg"),
                consumer: consumer("message-\(index)", "reference-\(index)", role: .prefetch),
                completion: nil
            )
        }

        XCTAssertEqual(loader.startedRequests.count, 3)
        XCTAssertEqual(pipeline.metrics.peakConcurrentWorkCount, 3)
        XCTAssertLessThanOrEqual(pipeline.metrics.queuedWorkCount, 24)
        XCTAssertEqual(pipeline.metrics.droppedQueuedWorkCount, 73)

        subscriptions.forEach { $0.cancel() }
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 0)
        XCTAssertEqual(pipeline.metrics.queuedWorkCount, 0)
    }

    func testVisibleBindingPreemptsQueuedPrefetchAtQueueLimit() {
        let loader = FakeChatThumbnailLoader()
        let pipeline = ChatMediaThumbnailPipeline(
            loader: loader,
            cache: FakeChatThumbnailCache(),
            maxConcurrentWork: 1,
            maxQueuedWork: 1
        )
        let running = thumbnailRequest(path: "running.jpg")
        let queuedPrefetch = thumbnailRequest(path: "queued-prefetch.jpg")
        let visible = thumbnailRequest(path: "visible.jpg")
        let runningSubscription = pipeline.acquire(running, consumer: consumer("m1", "r1", role: .prefetch), completion: nil)
        let queuedSubscription = pipeline.acquire(queuedPrefetch, consumer: consumer("m2", "r2", role: .prefetch), completion: nil)

        let visibleSubscription = pipeline.acquire(visible, consumer: consumer("m3", "r3", role: .visible(UUID())), completion: nil)
        withExtendedLifetime([runningSubscription, queuedSubscription, visibleSubscription]) {
            loader.completeFirst(with: .success(payload(pixelWidth: 440, pixelHeight: 440)))
        }

        XCTAssertEqual(loader.startedRequests, [running, visible])
        XCTAssertEqual(pipeline.metrics.droppedQueuedWorkCount, 1)
        XCTAssertEqual(pipeline.metrics.queuedWorkCount, 0)
    }

    func testVisibleBindingPreemptsRunningPrefetchWhenAllSlotsAreBusy() {
        let loader = FakeChatThumbnailLoader()
        let pipeline = ChatMediaThumbnailPipeline(
            loader: loader,
            cache: FakeChatThumbnailCache(),
            maxConcurrentWork: 1,
            maxQueuedWork: 1
        )
        let prefetch = thumbnailRequest(path: "slow-prefetch.jpg")
        let visible = thumbnailRequest(path: "visible-now.jpg")
        let prefetchSubscription = pipeline.acquire(
            prefetch,
            consumer: consumer("m1", "r1", role: .prefetch),
            completion: nil
        )

        let visibleSubscription = pipeline.acquire(
            visible,
            consumer: consumer("m2", "r2", role: .visible(UUID())),
            completion: nil
        )

        XCTAssertEqual(loader.startedRequests, [prefetch, visible])
        XCTAssertEqual(loader.tasks.first?.cancelCount, 1)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 1)
        XCTAssertEqual(pipeline.metrics.droppedQueuedWorkCount, 1)
        withExtendedLifetime([prefetchSubscription, visibleSubscription]) {}
    }

    func testUnchangedVideoPreviewAndSensitiveRevealDoNotRebindThumbnail() {
        let serving = RecordingChatThumbnailServing()
        let grid = InlineVideosGridView(frame: CGRect(x: 0, y: 0, width: 220, height: 220))
        grid.thumbnailPipeline = serving
        let preview = URL(string: "https://cdn.example.com/preview.jpg")!
        let video = VideoAttachment(
            primary: "video",
            url: URL(string: "https://cdn.example.com/video.mp4"),
            size: CGSize(width: 1_920, height: 1_080),
            previewUrl: preview,
            duration: 3,
            downloaded: true,
            isSensitive: true
        )

        grid.configure([video], representedBy: "message")
        XCTAssertEqual(serving.requests.count, 1)
        XCTAssertTrue(grid.views[0].hasSensitiveOverlay)

        grid.updateContent([video], representedBy: "message")
        XCTAssertEqual(serving.requests.count, 1)

        video.isSensitiveRevealed = true
        grid.updateContent([video], representedBy: "message")
        XCTAssertEqual(serving.requests.count, 1)
        XCTAssertFalse(grid.views[0].hasSensitiveOverlay)

        video.previewUrl = URL(string: "https://cdn.example.com/changed-preview.jpg")!
        grid.updateContent([video], representedBy: "message")
        XCTAssertEqual(serving.requests.count, 2)
        XCTAssertEqual(serving.subscriptions.first?.cancelCount, 1)
    }

    func testSensitiveOverlayIsLazyAndRevealAffectsOnlyTargetReference() {
        let serving = RecordingChatThumbnailServing()
        let grid = InlineImagesGridView(frame: CGRect(x: 0, y: 0, width: 220, height: 220))
        grid.thumbnailPipeline = serving
        let first = imageAttachment(primary: "first", path: "first.jpg", sensitive: false)
        let second = imageAttachment(primary: "second", path: "second.jpg", sensitive: true)

        grid.configure([first, second], representedBy: "message")
        XCTAssertFalse(grid.views[0].hasSensitiveOverlay)
        XCTAssertTrue(grid.views[1].hasSensitiveOverlay)

        second.isSensitiveRevealed = true
        grid.updateContent([first, second], representedBy: "message")

        XCTAssertFalse(grid.views[0].hasSensitiveOverlay)
        XCTAssertFalse(grid.views[1].hasSensitiveOverlay)
        XCTAssertEqual(serving.requests.count, 2)
    }

    func testMissingHistoricalImageURLRendersExplicitUnavailableState() {
        let grid = InlineImagesGridView(frame: CGRect(x: 0, y: 0, width: 220, height: 220))
        let attachment = ImageAttachment(
            primary: "missing-image",
            url: nil,
            size: CGSize(width: 1_000, height: 1_000)
        )

        grid.configure([attachment], representedBy: "historical-message")

        XCTAssertEqual(grid.views.count, 1)
        XCTAssertEqual(grid.views[0].thumbnailPresentationState, .unavailable)
        XCTAssertNotNil(grid.views[0].image)
    }

    func testThumbnailFailureReplacesLoadingStateWithUnavailablePlaceholder() {
        let serving = RecordingChatThumbnailServing()
        let grid = InlineImagesGridView(frame: CGRect(x: 0, y: 0, width: 220, height: 220))
        grid.thumbnailPipeline = serving

        grid.configure([
            imageAttachment(primary: "failed-image", path: "failed.jpg", sensitive: false)
        ], representedBy: "historical-message")

        XCTAssertEqual(grid.views[0].thumbnailPresentationState, .loading)
        serving.complete(at: 0, with: .failure(.loadFailed))
        XCTAssertEqual(grid.views[0].thumbnailPresentationState, .unavailable)
        XCTAssertNotNil(grid.views[0].image)
    }

    func testMemoryWarningCancelsPrefetchWorkButKeepsVisibleConsumerAlive() {
        let loader = FakeChatThumbnailLoader()
        let cache = FakeChatThumbnailCache()
        let pipeline = ChatMediaThumbnailPipeline(loader: loader, cache: cache, maxConcurrentWork: 2)
        let request = thumbnailRequest(path: "shared.jpg")
        let prefetch = pipeline.acquire(request, consumer: consumer("m", "r", role: .prefetch), completion: nil)
        let visible = pipeline.acquire(request, consumer: consumer("m", "r", role: .visible(UUID())), completion: nil)

        pipeline.handleMemoryWarning()

        XCTAssertEqual(cache.removeAllCount, 1)
        XCTAssertEqual(loader.tasks.first?.cancelCount, 0)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 1)
        prefetch.cancel()
        visible.cancel()
        XCTAssertEqual(loader.tasks.first?.cancelCount, 1)
    }

    private func item(imageURL: URL) -> ChatCollectionPrefetchItem {
        ChatCollectionPrefetchItem(
            messagePrimary: "message",
            owner: "owner@example.com",
            jid: "chat@example.com",
            avatarURL: nil,
            images: [.init(primary: "image", url: imageURL)],
            videos: [],
            locations: [],
            contacts: []
        )
    }

    private func conversationKey() -> ChatCollectionPrefetchConversationKey {
        .init(owner: "owner@example.com", jid: "chat@example.com", conversationType: "regular")
    }

    private func thumbnailRequest(
        path: String,
        width: Double = 220,
        height: Double = 220,
        scale: Double = 2
    ) -> ChatThumbnailRequest {
        ChatThumbnailRequest(
            url: URL(string: "https://cdn.example.com/\(path)")!,
            displaySize: .init(width: width, height: height),
            scale: scale,
            traitStyle: .light
        )
    }

    private func consumer(
        _ message: String,
        _ reference: String,
        role: ChatThumbnailConsumer.Role
    ) -> ChatThumbnailConsumer {
        ChatThumbnailConsumer(
            identity: .init(kind: .image, messagePrimary: message, referencePrimary: reference),
            role: role
        )
    }

    private func payload(pixelWidth: Int, pixelHeight: Int) -> ChatThumbnailImage {
        ChatThumbnailImage(
            image: UIImage(),
            pixelSize: .init(width: Double(pixelWidth), height: Double(pixelHeight))
        )
    }

    private func imageAttachment(primary: String, path: String, sensitive: Bool) -> ImageAttachment {
        ImageAttachment(
            primary: primary,
            url: URL(string: "https://cdn.example.com/\(path)"),
            size: CGSize(width: 1_000, height: 1_000),
            isSensitive: sensitive
        )
    }
}

private final class FakeChatThumbnailLoader: ChatThumbnailLoading {
    final class Task: ChatThumbnailLoadTask {
        private(set) var cancelCount = 0

        func cancel() {
            cancelCount += 1
        }
    }

    struct Operation {
        let request: ChatThumbnailRequest
        let task: Task
        let completion: (Result<ChatThumbnailImage, ChatThumbnailPipelineError>) -> Void
    }

    private(set) var operations: [Operation] = []
    private(set) var startedRequests: [ChatThumbnailRequest] = []
    private(set) var tasks: [Task] = []
    private(set) var decodeCount = 0

    func load(
        _ request: ChatThumbnailRequest,
        completion: @escaping (Result<ChatThumbnailImage, ChatThumbnailPipelineError>) -> Void
    ) -> ChatThumbnailLoadTask {
        let task = Task()
        startedRequests.append(request)
        tasks.append(task)
        operations.append(Operation(request: request, task: task, completion: completion))
        return task
    }

    func completeFirst(with result: Result<ChatThumbnailImage, ChatThumbnailPipelineError>) {
        guard operations.isNotEmpty else { return }
        let operation = operations.removeFirst()
        if case .success = result {
            decodeCount += 1
        }
        operation.completion(result)
    }
}

private final class FakeChatThumbnailCache: ChatThumbnailCaching {
    private var storage: [ChatThumbnailRequest: ChatThumbnailImage] = [:]
    private(set) var removeAllCount = 0

    func image(for request: ChatThumbnailRequest) -> ChatThumbnailImage? {
        storage[request]
    }

    func store(_ image: ChatThumbnailImage, for request: ChatThumbnailRequest) {
        storage[request] = image
    }

    func removeAll() {
        removeAllCount += 1
        storage.removeAll()
    }
}

private final class RecordingChatThumbnailServing: ChatThumbnailServing {
    private(set) var requests: [ChatThumbnailRequest] = []
    private(set) var subscriptions: [FakeChatThumbnailSubscription] = []
    private var completions: [((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?] = []

    func acquire(
        _ request: ChatThumbnailRequest,
        consumer: ChatThumbnailConsumer,
        completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    ) -> ChatThumbnailSubscription {
        let subscription = FakeChatThumbnailSubscription()
        requests.append(request)
        subscriptions.append(subscription)
        completions.append(completion)
        return subscription
    }

    func complete(
        at index: Int,
        with result: Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>
    ) {
        completions[index]?(result)
    }
}

private final class FakeChatThumbnailSubscription: ChatThumbnailSubscription {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private extension Result where Failure == ChatThumbnailPipelineError {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
