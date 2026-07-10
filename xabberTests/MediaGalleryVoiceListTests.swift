import RealmSwift
import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryVoiceListTests: XCTestCase {
    private var originalRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        originalRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "MediaGalleryVoiceListTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = originalRealmConfiguration
        originalRealmConfiguration = nil
        super.tearDown()
    }

    func testRealmQueryShowsOnlyVisibleVoiceRowsNewestFirst() throws {
        let realm = try Realm()
        let older = storedItem(kind: .voice, primary: "older", date: 10)
        let newer = storedItem(kind: .voice, primary: "newer", date: 20)
        let hidden = storedItem(kind: .voice, primary: "hidden", date: 30)
        hidden.isLocallyHiddenByReport = true
        try realm.write {
            realm.add([
                older,
                newer,
                hidden,
                storedItem(kind: .file, primary: "file", date: 40),
                storedItem(kind: .image, primary: "image", date: 50),
                storedItem(kind: .video, primary: "video", date: 60)
            ])
        }

        let controller = makeController()
        controller.loadDatasource()

        XCTAssertEqual(controller.collectionObserver?.map(\.primary), ["newer", "older"])
        XCTAssertTrue(controller.collectionObserver?.allSatisfy { $0.kind == .voice } == true)
    }

    func testDatasourceMapsCompleteVoiceDescriptorIncludingRouteAnchor() throws {
        let item = datasourceItem(
            url: URL(string: "https://gallery.example/voice.ogg"),
            decodedURL: URL(fileURLWithPath: "/tmp/voice.m4a"),
            duration: 65,
            downloaded: true,
            pcm: [0.1, 0.4, 0.9]
        )

        let descriptor = MediaGalleryVoiceDescriptorMapper.descriptor(for: item)

        XCTAssertEqual(descriptor.referencePrimary, item.primary)
        XCTAssertEqual(descriptor.containerMessagePrimary, item.messagePrimary)
        XCTAssertEqual(descriptor.archivedId, item.archiveId)
        XCTAssertEqual(descriptor.remoteURL, item.url)
        XCTAssertEqual(descriptor.decodedURL, item.decodedURL)
        XCTAssertEqual(descriptor.duration, 65)
        XCTAssertTrue(descriptor.downloaded)
        XCTAssertEqual(descriptor.pcm, [0.1, 0.4, 0.9])
        XCTAssertEqual(descriptor.sentDate, item.date)
        XCTAssertTrue(descriptor.isLocallyAvailable)
    }

    func testMissingWaveformUsesDeterministicVisibleFallbackBars() {
        let first = MediaGalleryVoiceWaveformPolicy.levels(for: [])
        let second = MediaGalleryVoiceWaveformPolicy.levels(for: [])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 48)
        XCTAssertTrue(first.allSatisfy { $0 > 0 })
        XCTAssertGreaterThan(Set(first).count, 1)
        XCTAssertEqual(
            MediaGalleryVoiceWaveformPolicy.levels(for: [-1, 0.5, 2]),
            [0.08, 0.5, 1]
        )
    }

    func testRowStateDerivesControlWaveformProgressAndDurationText() {
        let descriptor = MediaGalleryVoiceDescriptorMapper.descriptor(
            for: datasourceItem(duration: 65, downloaded: true, pcm: [])
        )

        let downloaded = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .downloaded
        )
        XCTAssertEqual(downloaded.controlIconSystemName, "play.fill")
        XCTAssertEqual(downloaded.durationText, "1:05")
        XCTAssertEqual(downloaded.waveformProgress, 0)
        XCTAssertFalse(downloaded.waveformLevels.isEmpty)

        let remote = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .notDownloaded
        )
        XCTAssertEqual(remote.controlIconSystemName, "square.and.arrow.down")

        let playing = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .playing(currentTime: 5, duration: 65)
        )
        XCTAssertEqual(playing.controlIconSystemName, "pause.fill")
        XCTAssertEqual(playing.durationText, "0:05 / 1:05")
        XCTAssertEqual(playing.waveformProgress, 5.0 / 65.0, accuracy: 0.0001)

        let paused = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .paused(currentTime: 8, duration: 65)
        )
        XCTAssertEqual(paused.controlIconSystemName, "play.fill")
        XCTAssertEqual(paused.durationText, "0:08 / 1:05")
        XCTAssertEqual(paused.waveformProgress, 8.0 / 65.0, accuracy: 0.0001)

        let downloading = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .downloading(progress: 0.42)
        )
        XCTAssertEqual(downloading.controlIconSystemName, "xmark")
        XCTAssertEqual(downloading.durationText, "1:05 · 42%")
    }

    func testVoiceListUsesStableFullWidthRows() {
        let policy = MediaGalleryVoiceListLayoutPolicy()

        XCTAssertEqual(policy.rowHeight, 80)
        XCTAssertEqual(
            policy.itemSize(
                containerWidth: 390,
                contentInset: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
            ),
            CGSize(width: 366, height: 80)
        )
    }

    func testCellRepeatedConfigureDoesNotDuplicateHierarchyTargetsOrConstraints() {
        let cell = VoiceGalleryForChatViewController.GalleryVoiceItemCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 80)
        )
        let descriptor = MediaGalleryVoiceDescriptorMapper.descriptor(
            for: datasourceItem(duration: 65, downloaded: true, pcm: [])
        )
        let first = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .downloaded
        )
        let second = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: .playing(currentTime: 13, duration: 65)
        )

        cell.configure(state: first, onPrimaryAction: {}, onJumpToMessage: {})
        let subviewCount = cell.contentView.subviews.count
        let constraintCount = cell.contentView.constraints.count
        let targetCount = cell.controlButton.allTargets.count
        let customActionCount = cell.accessibilityCustomActions?.count
        cell.configure(state: second, onPrimaryAction: {}, onJumpToMessage: {})

        XCTAssertEqual(cell.contentView.subviews.count, subviewCount)
        XCTAssertEqual(cell.contentView.constraints.count, constraintCount)
        XCTAssertEqual(cell.controlButton.allTargets.count, targetCount)
        XCTAssertEqual(cell.accessibilityCustomActions?.count, customActionCount)
        XCTAssertEqual(cell.waveformView.gestureRecognizers?.count ?? 0, 0)
        XCTAssertEqual(cell.controlButton.bounds.width, 44)
        XCTAssertEqual(cell.controlButton.bounds.height, 44)
        XCTAssertEqual(cell.renderedState, second)
        XCTAssertEqual(cell.renderedWaveformLevels, second.waveformLevels)
        XCTAssertEqual(cell.waveformView.currentGradientPercentage, Float(second.waveformProgress))
    }

    func testEmptyStateAndContextMenuKeepJumpAndReportActions() {
        let controller = makeController()
        let router = FakeVoiceMessageNavigationRouter()
        controller.messageNavigationRouter = router
        let item = datasourceItem()

        controller.apply([])
        XCTAssertFalse(controller.emptyStateLabel.isHidden)
        controller.apply([item])
        XCTAssertTrue(controller.emptyStateLabel.isHidden)

        let identifiers = controller.contextMenuActions(for: item)
            .compactMap { ($0 as? UIAction)?.identifier.rawValue }
        XCTAssertEqual(
            Set(identifiers),
            Set([
                MediaGalleryVoiceMenuIdentifier.goToMessage.rawValue,
                MediaGalleryVoiceMenuIdentifier.report.rawValue
            ])
        )

        controller.performMessageJump(for: item)
        XCTAssertEqual(router.requests.count, 1)
        XCTAssertEqual(router.requests.first?.source, .mediaGallery)
    }

    private func makeController() -> VoiceGalleryForChatViewController {
        let controller = VoiceGalleryForChatViewController()
        controller.owner = Self.owner
        controller.jid = Self.jid
        controller.conversationType = .regular
        controller.loadViewIfNeeded()
        return controller
    }

    private func storedItem(
        kind: MessageMediaAttachmentStorageItem.Kind,
        primary: String,
        date: TimeInterval
    ) -> MessageMediaAttachmentStorageItem {
        let item = MessageMediaAttachmentStorageItem()
        item.primary = primary
        item.owner = Self.owner
        item.jid = Self.jid
        item.conversationType = .regular
        item.kind = kind
        item.messagePrimary = "message-\(primary)"
        item.archiveId = "archive-\(primary)"
        item.filename = "\(primary).ogg"
        item.url_ = "https://gallery.example/\(primary).ogg"
        item.date = Date(timeIntervalSince1970: date)
        return item
    }

    private func datasourceItem(
        url: URL? = URL(string: "https://gallery.example/voice.ogg"),
        decodedURL: URL? = nil,
        duration: TimeInterval = 12,
        downloaded: Bool = false,
        pcm: [Float] = [0.1, 0.5]
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .voice,
            primary: "voice-primary",
            owner: Self.owner,
            jid: Self.jid,
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            filename: "voice.ogg",
            url: url,
            messagePrimary: "message-primary",
            archiveId: "archive-id",
            isDownloaded: downloaded,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: 1_024,
            formattedByteSize: AccountQuotaStorageItem.beautify(size: 1_024),
            durationSeconds: duration,
            formattedDuration: MediaGalleryDatasourceMapper.formatDuration(duration),
            previewURL: nil,
            previewCacheIdentity: nil,
            mediaType: "audio/ogg",
            decodedURL: decodedURL,
            pcm: pcm,
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }

    private static let owner = "owner@example.com"
    private static let jid = "contact@example.com"
}

@MainActor
private final class FakeVoiceMessageNavigationRouter: MediaGalleryMessageNavigationRouting {
    private(set) var requests: [ChatOpenMessageRequest] = []

    func route(
        _ request: ChatOpenMessageRequest,
        from presenter: UIViewController
    ) -> MediaGalleryMessageNavigationRouteResult {
        requests.append(request)
        return .navigationStack
    }
}
