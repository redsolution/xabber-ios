import XCTest
import CoreLocation
@testable import xabber

@MainActor
final class ChatLocationSnapshotPipelineTests: XCTestCase {
    func testRequestIdentityIncludesCoordinatePixelSizeScaleMapAndInterfaceStyle() {
        let base = request()

        XCTAssertNotEqual(base, request(latitude: 56.0))
        XCTAssertNotEqual(base, request(longitude: 61.0))
        XCTAssertNotEqual(base, request(width: 180))
        XCTAssertNotEqual(base, request(scale: 2))
        XCTAssertNotEqual(base, request(mapStyle: .mutedStandard))
        XCTAssertNotEqual(base, request(traitStyle: .dark))
        XCTAssertEqual(base.pixelSize, ChatCollectionPrefetchSize(width: 360, height: 360))
        XCTAssertTrue(base.cacheKey.contains("360x360"))
    }

    func testPrefetchAndVisibleConsumersShareOneGeneration() {
        let loader = G14FakeLocationSnapshotLoader()
        let pipeline = ChatLocationSnapshotPipeline(
            loader: loader,
            maxConcurrentWork: 2,
            maxQueuedWork: 4
        )
        let target = request()
        let identity = locationIdentity()
        let image = testImage(color: .systemBlue)
        var visibleImage: UIImage?

        let prefetch = pipeline.acquire(
            target,
            consumer: ChatLocationSnapshotConsumer(identity: identity, role: .prefetch),
            completion: nil
        )
        let visible = pipeline.acquire(
            target,
            consumer: ChatLocationSnapshotConsumer(identity: identity, role: .visible(UUID()))
        ) { result in
            visibleImage = try? result.get().image
        }

        XCTAssertEqual(loader.requests, [target])
        XCTAssertEqual(pipeline.metrics.underlyingLoadCount, 1)
        XCTAssertEqual(pipeline.metrics.deduplicatedAcquireCount, 1)

        prefetch.cancel()
        XCTAssertEqual(loader.tasks.first?.cancelCount, 0)

        loader.complete(at: 0, with: .success(ChatLocationSnapshotArtifact(
            image: image,
            pngData: image.pngData() ?? Data()
        )))

        XCTAssertTrue(visibleImage === image)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 0)
        visible.cancel()
    }

    func testFinalConsumerCancellationCancelsUnderlyingGenerationExactlyOnce() {
        let loader = G14FakeLocationSnapshotLoader()
        let pipeline = ChatLocationSnapshotPipeline(loader: loader, maxConcurrentWork: 1)
        let target = request()
        let identity = locationIdentity()

        let first = pipeline.acquire(
            target,
            consumer: ChatLocationSnapshotConsumer(identity: identity, role: .prefetch),
            completion: nil
        )
        let second = pipeline.acquire(
            target,
            consumer: ChatLocationSnapshotConsumer(identity: identity, role: .visible(UUID())),
            completion: nil
        )

        first.cancel()
        XCTAssertEqual(loader.tasks[0].cancelCount, 0)
        second.cancel()
        second.cancel()

        XCTAssertEqual(loader.tasks[0].cancelCount, 1)
        XCTAssertEqual(pipeline.metrics.activeWorkCount, 0)
    }

    func testDifferentSizeStyleAndSourceVariantsDoNotCoalesce() {
        let loader = G14FakeLocationSnapshotLoader()
        let pipeline = ChatLocationSnapshotPipeline(loader: loader, maxConcurrentWork: 8)
        let identity = locationIdentity()
        let variants = [
            request(),
            request(width: 180),
            request(scale: 2),
            request(mapStyle: .mutedStandard),
            request(sourceURL: URL(fileURLWithPath: "/tmp/outgoing-location.png"))
        ]

        let subscriptions = variants.map { target in
            pipeline.acquire(
                target,
                consumer: ChatLocationSnapshotConsumer(identity: identity, role: .visible(UUID())),
                completion: nil
            )
        }

        XCTAssertEqual(loader.requests.count, variants.count)
        XCTAssertEqual(Set(loader.requests), Set(variants))
        subscriptions.forEach { $0.cancel() }
    }

    func testLocationViewKeepsUnchangedRequestAndRejectsOldSizeCompletion() {
        let pipeline = G14FakeLocationSnapshotServing()
        let location = LocationAttachment(
            primary: "location",
            coordinate: CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62),
            address: "Moscow",
            geoURI: "geo:55.75,37.62",
            snapshotURL: nil
        )
        let view = InlineLocationsGridView.LocationView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 120),
            location: location,
            snapshotPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light
        )
        view.update(location, representedBy: "message")
        view.layoutIfNeeded()
        let firstImage = testImage(color: .red)
        let currentImage = testImage(color: .green)

        XCTAssertEqual(pipeline.requests.count, 1)
        view.update(location, representedBy: "message")
        view.layoutIfNeeded()
        XCTAssertEqual(pipeline.requests.count, 1)

        view.frame.size = CGSize(width: 180, height: 180)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        XCTAssertEqual(pipeline.requests.count, 2)
        XCTAssertEqual(pipeline.subscriptions[0].cancelCount, 1)
        pipeline.complete(at: 0, image: firstImage)
        XCTAssertFalse(view.renderedSnapshotImage === firstImage)
        pipeline.complete(at: 1, image: currentImage)
        XCTAssertTrue(view.renderedSnapshotImage === currentImage)

        view.updateRenderingEnvironment(screenScale: 3, traitStyle: .dark)
        view.layoutIfNeeded()

        XCTAssertEqual(pipeline.requests.count, 3)
        XCTAssertEqual(pipeline.requests[2].traitStyle, .dark)
        pipeline.complete(at: 1, image: firstImage)
        XCTAssertTrue(view.renderedSnapshotImage === currentImage)
        let darkImage = testImage(color: .purple)
        pipeline.complete(at: 2, image: darkImage)
        XCTAssertTrue(view.renderedSnapshotImage === darkImage)
    }

    func testLocationViewCancelsOffscreenAndRejectsCancelledGenerationAfterResume() {
        let pipeline = G14FakeLocationSnapshotServing()
        let location = LocationAttachment(
            primary: "location",
            coordinate: CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62),
            address: "Moscow",
            geoURI: "geo:55.75,37.62",
            snapshotURL: nil
        )
        let view = InlineLocationsGridView.LocationView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 120),
            location: location,
            snapshotPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light
        )
        view.layoutIfNeeded()
        let staleImage = testImage(color: .red)
        let currentImage = testImage(color: .green)

        view.cancelOffscreenWork()
        XCTAssertEqual(pipeline.subscriptions[0].cancelCount, 1)
        view.resumeOnscreenWork()
        view.layoutIfNeeded()
        XCTAssertEqual(pipeline.requests.count, 2)

        pipeline.complete(at: 0, image: staleImage)
        XCTAssertFalse(view.renderedSnapshotImage === staleImage)
        pipeline.complete(at: 1, image: currentImage)
        XCTAssertTrue(view.renderedSnapshotImage === currentImage)
    }

    func testSynchronousLocationCacheHitDoesNotLeaveRestartableVisibleSubscription() {
        let image = testImage(color: .blue)
        let pipeline = G14FakeLocationSnapshotServing(immediateImage: image)
        let location = LocationAttachment(
            primary: "location",
            coordinate: CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62),
            address: "Moscow",
            geoURI: "geo:55.75,37.62",
            snapshotURL: nil
        )
        let view = InlineLocationsGridView.LocationView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 120),
            location: location,
            snapshotPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light
        )

        view.layoutIfNeeded()
        view.cancelOffscreenWork()
        view.resumeOnscreenWork()
        view.layoutIfNeeded()

        XCTAssertEqual(pipeline.requests.count, 1)
        XCTAssertTrue(view.renderedSnapshotImage === image)
    }

    func testDiskCacheEvictsOldestHonorsTTLAndCleansLegacyUUIDFilesOffMain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("g14-location-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 10_000)
        let cache = ChatLocationSnapshotDiskCache(
            directoryURL: directory,
            maxEntryCount: 2,
            maxDiskBytes: 1_000_000,
            ttl: 60,
            now: { now }
        )
        let first = request(latitude: 1)
        let second = request(latitude: 2)
        let third = request(latitude: 3)
        let image = testImage(color: .orange)
        let artifact = ChatLocationSnapshotArtifact(image: image, pngData: try XCTUnwrap(image.pngData()))

        waitForStore(cache, artifact: artifact, request: first)
        now.addTimeInterval(1)
        waitForStore(cache, artifact: artifact, request: second)
        now.addTimeInterval(1)
        waitForStore(cache, artifact: artifact, request: third)

        var metrics = waitForMetrics(cache)
        XCTAssertEqual(metrics.entryCount, 2)
        XCTAssertLessThanOrEqual(metrics.memoryEntryCount, 2)
        XCTAssertLessThanOrEqual(metrics.memoryBytes, 24 * 1_024 * 1_024)
        XCTAssertEqual(metrics.mainThreadFileAccessCount, 0)
        XCTAssertNil(waitForLoad(cache, request: first))
        XCTAssertNotNil(waitForLoad(cache, request: third))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("9C52BDAA-C429-4D4A-AB64-7FD433228B44.png")
        try Data([1, 2, 3]).write(to: legacyURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120)],
            ofItemAtPath: legacyURL.path
        )
        now.addTimeInterval(120)
        waitForCleanup(cache)

        metrics = waitForMetrics(cache)
        XCTAssertEqual(metrics.entryCount, 0)
        XCTAssertEqual(metrics.memoryEntryCount, 0)
        XCTAssertEqual(metrics.memoryBytes, 0)
        XCTAssertEqual(metrics.mainThreadFileAccessCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    private func request(
        latitude: Double = 55.75,
        longitude: Double = 37.62,
        width: Double = 120,
        scale: Double = 3,
        mapStyle: ChatLocationSnapshotMapStyle = .standard,
        traitStyle: ChatThumbnailTraitStyle = .light,
        sourceURL: URL? = nil
    ) -> ChatLocationSnapshotRequest {
        ChatLocationSnapshotRequest(
            latitude: latitude,
            longitude: longitude,
            sourceURL: sourceURL,
            displaySize: ChatCollectionPrefetchSize(width: width, height: width),
            scale: scale,
            mapStyle: mapStyle,
            traitStyle: traitStyle
        )
    }

    private func locationIdentity() -> ChatCollectionPrefetchIdentity {
        ChatCollectionPrefetchIdentity(
            kind: .locationSnapshot,
            messagePrimary: "message",
            referencePrimary: "location"
        )
    }

    private func testImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func waitForStore(
        _ cache: ChatLocationSnapshotDiskCache,
        artifact: ChatLocationSnapshotArtifact,
        request: ChatLocationSnapshotRequest
    ) {
        let expectation = expectation(description: "store")
        cache.store(artifact, for: request) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func waitForLoad(
        _ cache: ChatLocationSnapshotDiskCache,
        request: ChatLocationSnapshotRequest
    ) -> ChatLocationSnapshotArtifact? {
        let expectation = expectation(description: "load")
        var result: ChatLocationSnapshotArtifact?
        cache.load(request) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return result
    }

    private func waitForCleanup(_ cache: ChatLocationSnapshotDiskCache) {
        let expectation = expectation(description: "cleanup")
        cache.cleanup { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func waitForMetrics(
        _ cache: ChatLocationSnapshotDiskCache
    ) -> ChatLocationSnapshotDiskCacheMetrics {
        let expectation = expectation(description: "metrics")
        var result: ChatLocationSnapshotDiskCacheMetrics?
        cache.inspect {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return result ?? ChatLocationSnapshotDiskCacheMetrics(
            entryCount: -1,
            totalBytes: -1,
            memoryEntryCount: -1,
            memoryBytes: -1,
            mainThreadFileAccessCount: -1
        )
    }
}

private final class G14FakeLocationSnapshotTask: ChatLocationSnapshotLoadTask {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class G14FakeLocationSnapshotLoader: ChatLocationSnapshotLoading {
    private(set) var requests: [ChatLocationSnapshotRequest] = []
    private(set) var tasks: [G14FakeLocationSnapshotTask] = []
    private var completions: [(Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>) -> Void] = []

    func load(
        _ request: ChatLocationSnapshotRequest,
        completion: @escaping (Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>) -> Void
    ) -> ChatLocationSnapshotLoadTask {
        let task = G14FakeLocationSnapshotTask()
        requests.append(request)
        tasks.append(task)
        completions.append(completion)
        return task
    }

    func complete(
        at index: Int,
        with result: Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>
    ) {
        completions[index](result)
    }
}

private final class G14FakeLocationSnapshotSubscription: ChatLocationSnapshotSubscription {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class G14FakeLocationSnapshotServing: ChatLocationSnapshotServing {
    private let immediateImage: UIImage?
    private(set) var requests: [ChatLocationSnapshotRequest] = []
    private(set) var subscriptions: [G14FakeLocationSnapshotSubscription] = []
    private var completions: [(Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void] = []

    init(immediateImage: UIImage? = nil) {
        self.immediateImage = immediateImage
    }

    func acquire(
        _ request: ChatLocationSnapshotRequest,
        consumer: ChatLocationSnapshotConsumer,
        completion: ((Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void)?
    ) -> ChatLocationSnapshotSubscription {
        let subscription = G14FakeLocationSnapshotSubscription()
        requests.append(request)
        subscriptions.append(subscription)
        completions.append(completion ?? { _ in })
        if let immediateImage {
            completion?(.success(ChatLocationSnapshotDelivery(image: immediateImage, source: .diskCache)))
        }
        return subscription
    }

    func complete(at index: Int, image: UIImage) {
        completions[index](.success(ChatLocationSnapshotDelivery(image: image, source: .loader)))
    }
}
