import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryVideoPrefetchTests: XCTestCase {
    func testVideoPlannerRequestsPreviewInsteadOfRawPlaybackURL() throws {
        let playbackURL = try XCTUnwrap(URL(string: "https://gallery.example/video.mp4"))
        let previewURL = try XCTUnwrap(URL(string: "https://gallery.example/video-preview.jpg"))
        let item = videoItem(playbackURL: playbackURL, previewURL: previewURL)

        let request = try XCTUnwrap(MediaGalleryImageRequestPlanner.request(
            for: item,
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        ))

        XCTAssertEqual(request.url, previewURL)
        XCTAssertNotEqual(request.url, playbackURL)
    }

    func testVideoPlannerNeverFallsBackToRawPlaybackURL() throws {
        let playbackURL = try XCTUnwrap(URL(string: "https://gallery.example/video.mp4"))
        let item = videoItem(playbackURL: playbackURL, previewURL: nil)

        let request = MediaGalleryImageRequestPlanner.request(
            for: item,
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )

        XCTAssertNil(request)
    }

    func testVideoPlannerRejectsPreviewMetadataThatEqualsPlaybackURL() throws {
        let playbackURL = try XCTUnwrap(URL(string: "https://gallery.example/video.mp4"))
        let item = videoItem(playbackURL: playbackURL, previewURL: playbackURL)

        let request = MediaGalleryImageRequestPlanner.request(
            for: item,
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )

        XCTAssertNil(request)
    }

    func testVideoPrefetchCoordinatorIsBoundsSafeAndCancelable() throws {
        let previewURL = try XCTUnwrap(URL(string: "https://gallery.example/video-preview.jpg"))
        let datasource = [videoItem(previewURL: previewURL)]
        let factory = FakeVideoPreviewPrefetchTaskFactory()
        let coordinator = MediaGalleryImagePrefetchCoordinator(
            itemProvider: { indexPath in
                guard datasource.indices.contains(indexPath.item) else { return nil }
                return datasource[indexPath.item]
            },
            displaySizeProvider: { CGSize(width: 120, height: 120) },
            scaleProvider: { 3 },
            taskFactory: factory
        )

        coordinator.prefetchItems(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 9, section: 0)
        ])

        XCTAssertEqual(factory.requests.map(\.url), [previewURL])
        XCTAssertEqual(factory.tasks.first?.startCount, 1)

        coordinator.cancelPrefetchingForItems(at: [IndexPath(item: 0, section: 0)])

        XCTAssertEqual(factory.tasks.first?.stopCount, 1)
        XCTAssertEqual(coordinator.activeRequestCount, 0)
    }

    private func videoItem(
        playbackURL: URL? = URL(string: "https://gallery.example/video.mp4"),
        previewURL: URL? = nil
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .video,
            primary: "video",
            owner: "owner@example.com",
            jid: "contact@example.com",
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 100),
            filename: "video.mp4",
            url: playbackURL,
            messagePrimary: "message-video",
            archiveId: "archive-video",
            isDownloaded: false,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: 0,
            formattedByteSize: "0 B",
            durationSeconds: 65,
            formattedDuration: "1:05",
            previewURL: previewURL,
            previewCacheIdentity: previewURL?.absoluteString,
            mediaType: "video/mp4",
            decodedURL: nil,
            pcm: [],
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }
}

private final class FakeVideoPreviewPrefetchTaskFactory: MediaGalleryImagePrefetchTaskMaking {
    private(set) var requests: [MediaGalleryImageRequest] = []
    private(set) var tasks: [FakeVideoPreviewPrefetchTask] = []

    func makeTask(for request: MediaGalleryImageRequest) -> MediaGalleryImagePrefetchTask {
        requests.append(request)
        let task = FakeVideoPreviewPrefetchTask()
        tasks.append(task)
        return task
    }
}

private final class FakeVideoPreviewPrefetchTask: MediaGalleryImagePrefetchTask {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}
