import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryVoicePlaybackTests: XCTestCase {
    func testNotDownloadedTapUsesCoordinatorDownloadQueue() {
        let downloader = GalleryFakeVoiceDownloader()
        let player = GalleryFakeVoicePlayer()
        let coordinator = VoiceMessagePlaybackCoordinator(downloader: downloader, player: player)
        let controller = makeController(coordinator: coordinator)
        let item = datasourceItem(primary: "remote", downloaded: false)

        controller.handlePrimaryAction(for: item)

        XCTAssertEqual(downloader.startedPrimaries, ["remote"])
        XCTAssertEqual(
            coordinator.state(for: MediaGalleryVoiceDescriptorMapper.descriptor(for: item)),
            .downloading(progress: 0)
        )
    }

    func testDownloadedTapStartsPlaybackAndPlayingTapPauses() {
        let downloader = GalleryFakeVoiceDownloader()
        let player = GalleryFakeVoicePlayer()
        let coordinator = VoiceMessagePlaybackCoordinator(downloader: downloader, player: player)
        let controller = makeController(coordinator: coordinator)
        let item = datasourceItem(primary: "local", downloaded: true)

        controller.handlePrimaryAction(for: item)
        controller.handlePrimaryAction(for: item)

        XCTAssertEqual(player.startedPrimaries, ["local"])
        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertEqual(
            coordinator.state(for: MediaGalleryVoiceDescriptorMapper.descriptor(for: item)),
            .paused(currentTime: 0, duration: 12)
        )
    }

    func testVisibleDownloadedVoiceAutoAdvancesInGalleryOrder() {
        let downloader = GalleryFakeVoiceDownloader()
        let player = GalleryFakeVoicePlayer()
        let coordinator = VoiceMessagePlaybackCoordinator(downloader: downloader, player: player)
        let controller = makeController(coordinator: coordinator)
        let current = datasourceItem(primary: "current", downloaded: true, date: 20)
        let next = datasourceItem(primary: "next", downloaded: true, date: 10)
        controller.datasource = [current, next]
        controller.updateVisibleVoiceMessages(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 1, section: 0)
        ])

        controller.handlePrimaryAction(for: current)
        player.onFinish?()
        drainMainQueue()

        XCTAssertEqual(player.startedPrimaries, ["current", "next"])
        XCTAssertEqual(coordinator.currentPlaybackSnapshot?.referencePrimary, "next")
    }

    func testVisibleDescriptorUpdatesAreSortedDeduplicatedAndBoundsSafe() {
        let coordinator = GalleryFakeVoiceCoordinator()
        let controller = makeController(coordinator: coordinator)
        controller.datasource = [
            datasourceItem(primary: "first", downloaded: true),
            datasourceItem(primary: "second", downloaded: false),
            datasourceItem(primary: "third", downloaded: true)
        ]

        controller.updateVisibleVoiceMessages(at: [
            IndexPath(item: 2, section: 0),
            IndexPath(item: 0, section: 0),
            IndexPath(item: 2, section: 0),
            IndexPath(item: 99, section: 0)
        ])

        XCTAssertEqual(coordinator.lastVisibleDescriptors.map(\.referencePrimary), ["first", "third"])
    }

    func testVisibleDescriptorRefreshPropagatesDownloadedMetadataForSameRow() {
        let coordinator = GalleryFakeVoiceCoordinator()
        let controller = makeController(coordinator: coordinator)
        controller.datasource = [datasourceItem(primary: "voice", downloaded: false)]
        let indexPath = IndexPath(item: 0, section: 0)

        controller.updateVisibleVoiceMessages(at: [indexPath])
        XCTAssertFalse(coordinator.lastVisibleDescriptors[0].downloaded)
        XCTAssertNil(coordinator.lastVisibleDescriptors[0].decodedURL)

        controller.datasource = [datasourceItem(primary: "voice", downloaded: true)]
        controller.updateVisibleVoiceMessages(at: [indexPath])

        XCTAssertTrue(coordinator.lastVisibleDescriptors[0].downloaded)
        XCTAssertNotNil(coordinator.lastVisibleDescriptors[0].decodedURL)
    }

    func testControllerRegistersOneObserverAndRemovesItWhenLeaving() {
        let coordinator = GalleryFakeVoiceCoordinator()
        let controller = makeController(coordinator: coordinator)

        controller.beginPlaybackObservation()
        controller.beginPlaybackObservation()
        XCTAssertEqual(coordinator.addObserverCount, 1)
        XCTAssertEqual(coordinator.activeObserverCount, 1)

        controller.endPlaybackObservation()
        XCTAssertEqual(coordinator.removeObserverCount, 1)
        XCTAssertEqual(coordinator.activeObserverCount, 0)
        XCTAssertTrue(coordinator.lastVisibleDescriptors.isEmpty)
    }

    func testPlaybackStateChangeUpdatesAffectedVisibleCellOnly() throws {
        let coordinator = GalleryFakeVoiceCoordinator()
        let controller = makeController(coordinator: coordinator)
        let first = datasourceItem(primary: "first", downloaded: true)
        let second = datasourceItem(primary: "second", downloaded: true)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        controller.collectionView.frame = controller.view.bounds
        controller.apply([first, second])
        controller.collectionView.layoutIfNeeded()
        let firstCell = try XCTUnwrap(
            controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
                as? VoiceGalleryForChatViewController.GalleryVoiceItemCell
        )
        let secondCell = try XCTUnwrap(
            controller.collectionView.cellForItem(at: IndexPath(item: 1, section: 0))
                as? VoiceGalleryForChatViewController.GalleryVoiceItemCell
        )
        controller.beginPlaybackObservation()

        coordinator.emit(
            VoiceMessageStateChange(
                referencePrimary: "first",
                containerMessagePrimary: first.messagePrimary,
                state: .playing(currentTime: 3, duration: 12),
                previousState: .downloaded
            )
        )

        XCTAssertEqual(firstCell.renderedState?.playbackState, .playing(currentTime: 3, duration: 12))
        XCTAssertEqual(secondCell.renderedState?.playbackState, .downloaded)
    }

    private func makeController(
        coordinator: MediaGalleryVoicePlaybackCoordinating
    ) -> VoiceGalleryForChatViewController {
        let controller = VoiceGalleryForChatViewController()
        controller.owner = "owner@example.com"
        controller.jid = "contact@example.com"
        controller.conversationType = .regular
        controller.playbackCoordinator = coordinator
        controller.loadViewIfNeeded()
        return controller
    }

    private func datasourceItem(
        primary: String,
        downloaded: Bool,
        date: TimeInterval = 1
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .voice,
            primary: primary,
            owner: "owner@example.com",
            jid: "contact@example.com",
            conversationType: .regular,
            date: Date(timeIntervalSince1970: date),
            filename: "\(primary).ogg",
            url: URL(string: "https://gallery.example/\(primary).ogg"),
            messagePrimary: "message-\(primary)",
            archiveId: "archive-\(primary)",
            isDownloaded: downloaded,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: 1_024,
            formattedByteSize: "1 KB",
            durationSeconds: 12,
            formattedDuration: "0:12",
            previewURL: nil,
            previewCacheIdentity: nil,
            mediaType: "audio/ogg",
            decodedURL: downloaded ? URL(fileURLWithPath: "/tmp/\(primary).m4a") : nil,
            pcm: [0.1, 0.5],
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}

private final class GalleryFakeVoiceDownloadTask: VoiceMessageDownloadTask {
    private(set) var cancelCalled = false

    func cancel() {
        cancelCalled = true
    }
}

private final class GalleryFakeVoiceDownloader: VoiceMessageDownloading {
    private(set) var startedPrimaries: [String] = []

    func download(
        _ descriptor: VoiceMessageDescriptor,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<VoiceMessageDownloadedFile, Error>) -> Void
    ) -> VoiceMessageDownloadTask {
        startedPrimaries.append(descriptor.referencePrimary)
        return GalleryFakeVoiceDownloadTask()
    }
}

private final class GalleryFakeVoicePlayer: VoiceMessagePlaying {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 12
    var isPlaying = false
    var onFinish: (() -> Void)?
    private(set) var startedPrimaries: [String] = []
    private(set) var pauseCount = 0

    func start(url: URL, referencePrimary: String, at time: TimeInterval) throws -> TimeInterval {
        startedPrimaries.append(referencePrimary)
        currentTime = time
        isPlaying = true
        return duration
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }

    func resume() {
        isPlaying = true
    }

    func stop() {
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        currentTime = time
    }
}

private final class GalleryFakeVoiceCoordinator: MediaGalleryVoicePlaybackCoordinating {
    private var observers: [UUID: (VoiceMessageStateChange) -> Void] = [:]
    var states: [String: VoiceMessagePlaybackState] = [:]
    private(set) var lastVisibleDescriptors: [VoiceMessageDescriptor] = []
    private(set) var handledDescriptors: [VoiceMessageDescriptor] = []
    private(set) var addObserverCount = 0
    private(set) var removeObserverCount = 0

    var activeObserverCount: Int { observers.count }

    func addObserver(_ observer: @escaping (VoiceMessageStateChange) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        addObserverCount += 1
        return token
    }

    func removeObserver(_ token: UUID?) {
        guard let token else { return }
        observers.removeValue(forKey: token)
        removeObserverCount += 1
    }

    func state(for descriptor: VoiceMessageDescriptor) -> VoiceMessagePlaybackState {
        states[descriptor.referencePrimary] ?? (descriptor.isLocallyAvailable ? .downloaded : .notDownloaded)
    }

    func handleTap(_ descriptor: VoiceMessageDescriptor) {
        handledDescriptors.append(descriptor)
    }

    func setVisibleVoiceMessages(_ visibleDescriptors: [VoiceMessageDescriptor]) {
        lastVisibleDescriptors = visibleDescriptors
    }

    func emit(_ change: VoiceMessageStateChange) {
        states[change.referencePrimary] = change.state
        observers.values.forEach { $0(change) }
    }
}
