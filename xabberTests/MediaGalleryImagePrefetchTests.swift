import Kingfisher
import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryImagePrefetchTests: XCTestCase {
    func testPlannerPrefersPreviewAndFallsBackToFullImageURL() throws {
        let fullURL = try XCTUnwrap(URL(string: "https://gallery.example/full.jpg"))
        let previewURL = try XCTUnwrap(URL(string: "https://gallery.example/thumb.jpg"))
        let displaySize = CGSize(width: 120, height: 120)

        let preferred = try XCTUnwrap(MediaGalleryImageRequestPlanner.request(
            for: item(primary: "preferred", url: fullURL, previewURL: previewURL),
            displaySize: displaySize,
            scale: 3
        ))
        let fallback = try XCTUnwrap(MediaGalleryImageRequestPlanner.request(
            for: item(primary: "fallback", url: fullURL),
            displaySize: displaySize,
            scale: 3
        ))

        XCTAssertEqual(preferred.url, previewURL)
        XCTAssertEqual(fallback.url, fullURL)
    }

    func testRequestIdentityIncludesURLDisplaySizeAndScale() throws {
        let firstURL = try XCTUnwrap(URL(string: "https://gallery.example/first.jpg"))
        let secondURL = try XCTUnwrap(URL(string: "https://gallery.example/second.jpg"))
        let baseline = MediaGalleryImageRequest(url: firstURL, displaySize: CGSize(width: 120, height: 120), scale: 3)

        XCTAssertNotEqual(baseline, MediaGalleryImageRequest(url: secondURL, displaySize: baseline.displaySize, scale: baseline.scale))
        XCTAssertNotEqual(baseline, MediaGalleryImageRequest(url: firstURL, displaySize: CGSize(width: 121, height: 120), scale: baseline.scale))
        XCTAssertNotEqual(baseline, MediaGalleryImageRequest(url: firstURL, displaySize: baseline.displaySize, scale: 2))
        XCTAssertTrue(baseline.cacheKey.contains("360x360@3"))
    }

    func testRequestUsesDownsamplingBackgroundDecodeAndDisplayScale() throws {
        let url = try XCTUnwrap(URL(string: "https://gallery.example/image.jpg"))
        let request = MediaGalleryImageRequest(
            url: url,
            displaySize: CGSize(width: 120, height: 80),
            scale: 3
        )

        XCTAssertTrue(request.kingfisherOptions.contains { option in
            if case .backgroundDecode = option { return true }
            return false
        })
        XCTAssertTrue(request.kingfisherOptions.contains { option in
            if case .processor(let processor) = option {
                return processor.identifier.contains("DownsamplingImageProcessor")
            }
            return false
        })
        XCTAssertTrue(request.kingfisherOptions.contains { option in
            if case .scaleFactor(let scale) = option { return scale == 3 }
            return false
        })
        XCTAssertEqual(request.pixelSize, CGSize(width: 360, height: 240))
    }

    func testCoordinatorIgnoresOutOfBoundsIndexPaths() {
        let factory = FakeMediaGalleryImagePrefetchTaskFactory()
        let datasource = [item(primary: "only")]
        let coordinator = makeCoordinator(datasource: datasource, factory: factory)

        coordinator.prefetchItems(at: [IndexPath(item: 4, section: 0)])

        XCTAssertTrue(factory.requests.isEmpty)
        XCTAssertEqual(coordinator.activeRequestCount, 0)
    }

    func testCoordinatorDeduplicatesAlreadyActiveRequest() {
        let factory = FakeMediaGalleryImagePrefetchTaskFactory()
        let datasource = [item(primary: "one")]
        let coordinator = makeCoordinator(datasource: datasource, factory: factory)
        let indexPath = IndexPath(item: 0, section: 0)

        coordinator.prefetchItems(at: [indexPath])
        coordinator.prefetchItems(at: [indexPath])

        XCTAssertEqual(factory.requests.count, 1)
        XCTAssertEqual(factory.tasks.first?.startCount, 1)
        XCTAssertEqual(coordinator.activeRequestCount, 1)
    }

    func testCoordinatorCancelsByIndexPathAndCancelAll() throws {
        let factory = FakeMediaGalleryImagePrefetchTaskFactory()
        let datasource = [
            item(
                primary: "one",
                url: try XCTUnwrap(URL(string: "https://gallery.example/one.jpg"))
            ),
            item(
                primary: "two",
                url: try XCTUnwrap(URL(string: "https://gallery.example/two.jpg"))
            )
        ]
        let coordinator = makeCoordinator(datasource: datasource, factory: factory)

        coordinator.prefetchItems(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 1, section: 0)
        ])
        coordinator.cancelPrefetchingForItems(at: [IndexPath(item: 0, section: 0)])

        XCTAssertEqual(factory.tasks[0].stopCount, 1)
        XCTAssertEqual(factory.tasks[1].stopCount, 0)
        XCTAssertEqual(coordinator.activeRequestCount, 1)

        coordinator.cancelAll()

        XCTAssertEqual(factory.tasks[1].stopCount, 1)
        XCTAssertEqual(coordinator.activeRequestCount, 0)
    }

    func testLateCellCallbackCannotApplyAfterCellRepresentsAnotherItem() throws {
        let loader = FakeMediaGalleryImageLoader()
        let cell = PhotoGalleryForChatViewController.GalleryPhotoItemCell(
            frame: CGRect(x: 0, y: 0, width: 120, height: 120),
            imageLoader: loader
        )
        let firstRequest = MediaGalleryImageRequest(
            url: try XCTUnwrap(URL(string: "https://gallery.example/first.jpg")),
            displaySize: cell.bounds.size,
            scale: 3
        )
        let secondRequest = MediaGalleryImageRequest(
            url: try XCTUnwrap(URL(string: "https://gallery.example/second.jpg")),
            displaySize: cell.bounds.size,
            scale: 3
        )

        cell.configure(primary: "first", request: firstRequest, thumb: nil, isSensitive: false)
        cell.configure(primary: "second", request: secondRequest, thumb: nil, isSensitive: false)
        loader.completeLoad(at: 0, outcome: .failure)

        XCTAssertNil(cell.failurePlaceholderPrimary)

        loader.completeLoad(at: 1, outcome: .failure)

        XCTAssertEqual(cell.failurePlaceholderPrimary, "second")

        cell.prepareForReuse()
        loader.completeLoad(at: 1, outcome: .failure)

        XCTAssertNil(cell.failurePlaceholderPrimary)
        XCTAssertGreaterThanOrEqual(loader.cancelCount, 1)
    }

    private func makeCoordinator(
        datasource: [BaseMediaGalleryForChatViewController.Datasource],
        factory: FakeMediaGalleryImagePrefetchTaskFactory
    ) -> MediaGalleryImagePrefetchCoordinator {
        MediaGalleryImagePrefetchCoordinator(
            itemProvider: { indexPath in
                guard datasource.indices.contains(indexPath.item) else { return nil }
                return datasource[indexPath.item]
            },
            displaySizeProvider: { CGSize(width: 120, height: 120) },
            scaleProvider: { 3 },
            taskFactory: factory
        )
    }

    private func item(
        primary: String,
        url: URL? = URL(string: "https://gallery.example/image.jpg"),
        previewURL: URL? = nil
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .image,
            primary: primary,
            owner: "owner@example.com",
            jid: "contact@example.com",
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 100),
            filename: "\(primary).jpg",
            url: url,
            messagePrimary: "message-\(primary)",
            archiveId: "archive-\(primary)",
            isDownloaded: false,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: 0,
            formattedByteSize: "0 B",
            durationSeconds: nil,
            formattedDuration: nil,
            previewURL: previewURL,
            previewCacheIdentity: previewURL?.absoluteString,
            mediaType: "image/jpeg",
            decodedURL: nil,
            pcm: [],
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }
}

private final class FakeMediaGalleryImagePrefetchTaskFactory: MediaGalleryImagePrefetchTaskMaking {
    private(set) var requests: [MediaGalleryImageRequest] = []
    private(set) var tasks: [FakeMediaGalleryImagePrefetchTask] = []

    func makeTask(for request: MediaGalleryImageRequest) -> MediaGalleryImagePrefetchTask {
        requests.append(request)
        let task = FakeMediaGalleryImagePrefetchTask()
        tasks.append(task)
        return task
    }
}

private final class FakeMediaGalleryImagePrefetchTask: MediaGalleryImagePrefetchTask {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private final class FakeMediaGalleryImageLoader: MediaGalleryImageLoading {
    private(set) var cancelCount = 0
    private var completions: [(MediaGalleryImageLoadOutcome) -> Void] = []

    func load(
        request: MediaGalleryImageRequest,
        into imageView: UIImageView,
        placeholder: UIView?,
        completion: @escaping (MediaGalleryImageLoadOutcome) -> Void
    ) {
        completions.append(completion)
    }

    func cancelLoad(in imageView: UIImageView) {
        cancelCount += 1
    }

    func completeLoad(at index: Int, outcome: MediaGalleryImageLoadOutcome) {
        completions[index](outcome)
    }
}
