import RealmSwift
import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryFullscreenIntegrationTests: XCTestCase {
    private var originalRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        originalRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "MediaGalleryFullscreenIntegrationTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = originalRealmConfiguration
        originalRealmConfiguration = nil
        super.tearDown()
    }

    func testAllFourControllersBuildAndApplySnapshotsUsingExpectedLayouts() throws {
        let photoController = makePhotoController()
        let videoController = makeVideoController()
        let filesController = makeFilesController()
        let voiceController = makeVoiceController()

        photoController.apply([datasourceItem(kind: .image, primary: "image")])
        videoController.apply([datasourceItem(kind: .video, primary: "video")])
        filesController.apply([datasourceItem(kind: .file, primary: "file")])
        voiceController.apply([datasourceItem(kind: .voice, primary: "voice")])

        XCTAssertEqual(photoController.collectionView.numberOfItems(inSection: 0), 1)
        XCTAssertEqual(videoController.collectionView.numberOfItems(inSection: 0), 1)
        XCTAssertEqual(filesController.collectionView.numberOfItems(inSection: 0), 1)
        XCTAssertEqual(voiceController.collectionView.numberOfItems(inSection: 0), 1)

        let photoLayout = try XCTUnwrap(
            photoController.collectionView.collectionViewLayout as? MediaGalleryThreeColumnFlowLayout
        )
        let videoLayout = try XCTUnwrap(
            videoController.collectionView.collectionViewLayout as? MediaGalleryThreeColumnFlowLayout
        )
        XCTAssertEqual(photoLayout.policy.columnCount, 3)
        XCTAssertEqual(videoLayout.policy.columnCount, 3)
        XCTAssertEqual(
            photoLayout.policy.squareItemSize(containerWidth: 390),
            CGSize(width: 358.0 / 3.0, height: 358.0 / 3.0)
        )
        XCTAssertEqual(
            videoLayout.policy.squareItemSize(containerWidth: 390),
            CGSize(width: 358.0 / 3.0, height: 358.0 / 3.0)
        )

        let fileLayout = try XCTUnwrap(
            filesController.collectionView.collectionViewLayout as? MediaGalleryFileListFlowLayout
        )
        let voiceLayout = try XCTUnwrap(
            voiceController.collectionView.collectionViewLayout as? MediaGalleryVoiceListFlowLayout
        )
        XCTAssertEqual(
            fileLayout.policy.itemSize(containerWidth: 390),
            CGSize(width: 374, height: 64)
        )
        XCTAssertEqual(
            voiceLayout.policy.itemSize(containerWidth: 390),
            CGSize(width: 374, height: 80)
        )
    }

    func testAllSectionsUseNewestFirstVisibleOnlyRealmSnapshots() throws {
        let realm = try Realm()
        try realm.write {
            [
                MessageMediaAttachmentStorageItem.Kind.image,
                .video,
                .file,
                .voice
            ].forEach { kind in
                realm.add(storedItem(kind: kind, suffix: "older", date: 10))
                realm.add(storedItem(kind: kind, suffix: "newer", date: 20))
                realm.add(storedItem(kind: kind, suffix: "hidden", date: 30, hidden: true))
            }
        }

        let controllers: [BaseMediaGalleryForChatViewController] = [
            makePhotoController(),
            makeVideoController(),
            makeFilesController(),
            makeVoiceController()
        ]

        controllers.forEach { $0.loadDatasource() }

        XCTAssertEqual(controllers[0].collectionObserver?.map(\.primary), ["image-newer", "image-older"])
        XCTAssertEqual(controllers[1].collectionObserver?.map(\.primary), ["video-newer", "video-older"])
        XCTAssertEqual(controllers[2].collectionObserver?.map(\.primary), ["file-newer", "file-older"])
        XCTAssertEqual(controllers[3].collectionObserver?.map(\.primary), ["voice-newer", "voice-older"])
        XCTAssertTrue(
            controllers.allSatisfy { controller in
                controller.collectionObserver?.allSatisfy { !$0.isLocallyHiddenByReport } == true
            }
        )
    }

    func testSensitiveRevealStateRemainsPerControllerSessionForImagesAndVideos() {
        let image = storedItem(kind: .image, suffix: "sensitive", date: 1)
        image.isSensitive = true
        let video = storedItem(kind: .video, suffix: "sensitive", date: 2)
        video.isSensitive = true

        let firstPhotoSession = makePhotoController()
        let secondPhotoSession = makePhotoController()
        firstPhotoSession.revealedSensitiveMediaPrimaries.insert(image.primary)

        let firstVideoSession = makeVideoController()
        let secondVideoSession = makeVideoController()
        firstVideoSession.revealedSensitiveMediaPrimaries.insert(video.primary)

        XCTAssertTrue(
            MediaGalleryDatasourceMapper.map(
                image,
                revealedSensitiveMediaPrimaries: firstPhotoSession.revealedSensitiveMediaPrimaries
            ).isSensitiveRevealed
        )
        XCTAssertFalse(
            MediaGalleryDatasourceMapper.map(
                image,
                revealedSensitiveMediaPrimaries: secondPhotoSession.revealedSensitiveMediaPrimaries
            ).isSensitiveRevealed
        )
        XCTAssertTrue(
            MediaGalleryDatasourceMapper.map(
                video,
                revealedSensitiveMediaPrimaries: firstVideoSession.revealedSensitiveMediaPrimaries
            ).isSensitiveRevealed
        )
        XCTAssertFalse(
            MediaGalleryDatasourceMapper.map(
                video,
                revealedSensitiveMediaPrimaries: secondVideoSession.revealedSensitiveMediaPrimaries
            ).isSensitiveRevealed
        )
        XCTAssertTrue(image.isSensitive)
        XCTAssertTrue(video.isSensitive)
    }

    func testRouteBearingFileAndVoiceRowsExposeJumpActions() {
        let filesController = makeFilesController()
        let voiceController = makeVoiceController()
        let file = datasourceItem(kind: .file, primary: "file-route")
        let voice = datasourceItem(kind: .voice, primary: "voice-route")

        let fileIdentifiers = Set(
            filesController.contextMenuActions(for: file)
                .compactMap { ($0 as? UIAction)?.identifier.rawValue }
        )
        let voiceIdentifiers = Set(
            voiceController.contextMenuActions(for: voice)
                .compactMap { ($0 as? UIAction)?.identifier.rawValue }
        )

        XCTAssertTrue(fileIdentifiers.contains(MediaGalleryFileMenuIdentifier.goToMessage.rawValue))
        XCTAssertTrue(fileIdentifiers.contains(MediaGalleryFileMenuIdentifier.report.rawValue))
        XCTAssertTrue(voiceIdentifiers.contains(MediaGalleryVoiceMenuIdentifier.goToMessage.rawValue))
        XCTAssertTrue(voiceIdentifiers.contains(MediaGalleryVoiceMenuIdentifier.report.rawValue))
    }

    private func makePhotoController() -> PhotoGalleryForChatViewController {
        let controller = PhotoGalleryForChatViewController()
        configure(controller)
        return controller
    }

    private func makeVideoController() -> VideoGalleryForChatViewController {
        let controller = VideoGalleryForChatViewController()
        configure(controller)
        return controller
    }

    private func makeFilesController() -> FilesGalleryForChatViewController {
        let controller = FilesGalleryForChatViewController()
        configure(controller)
        return controller
    }

    private func makeVoiceController() -> VoiceGalleryForChatViewController {
        let controller = VoiceGalleryForChatViewController()
        controller.playbackCoordinator = IntegrationVoicePlaybackCoordinator()
        configure(controller)
        return controller
    }

    private func configure(_ controller: BaseMediaGalleryForChatViewController) {
        controller.owner = Self.owner
        controller.jid = Self.jid
        controller.conversationType = .regular
        controller.loadViewIfNeeded()
    }

    private func storedItem(
        kind: MessageMediaAttachmentStorageItem.Kind,
        suffix: String,
        date: TimeInterval,
        hidden: Bool = false
    ) -> MessageMediaAttachmentStorageItem {
        let item = MessageMediaAttachmentStorageItem()
        let kindName = galleryKindName(kind)
        item.primary = "\(kindName)-\(suffix)"
        item.owner = Self.owner
        item.jid = Self.jid
        item.conversationType = .regular
        item.kind = kind
        item.messagePrimary = "message-\(kindName)-\(suffix)"
        item.archiveId = "archive-\(kindName)-\(suffix)"
        item.filename = "\(kindName)-\(suffix).bin"
        item.url_ = "https://gallery.example/\(kindName)-\(suffix).bin"
        item.date = Date(timeIntervalSince1970: date)
        item.isLocallyHiddenByReport = hidden
        return item
    }

    private func galleryKindName(
        _ kind: MessageMediaAttachmentStorageItem.Kind
    ) -> String {
        switch kind {
        case .image:
            return "image"
        case .video:
            return "video"
        case .file:
            return "file"
        case .voice:
            return "voice"
        default:
            return "other-\(kind.rawValue)"
        }
    }

    private func datasourceItem(
        kind: MessageMediaAttachmentStorageItem.Kind,
        primary: String
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        let url = URL(string: "https://gallery.example/\(primary).bin")
        return BaseMediaGalleryForChatViewController.Datasource(
            kind: kind,
            primary: primary,
            owner: Self.owner,
            jid: Self.jid,
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            filename: "\(primary).bin",
            url: url,
            messagePrimary: "message-\(primary)",
            archiveId: "archive-\(primary)",
            isDownloaded: kind == .voice,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: 1_024,
            formattedByteSize: "1 KB",
            durationSeconds: kind == .video || kind == .voice ? 12 : nil,
            formattedDuration: kind == .video || kind == .voice ? "0:12" : nil,
            previewURL: kind == .video
                ? URL(string: "https://gallery.example/\(primary)-preview.jpg")
                : nil,
            previewCacheIdentity: nil,
            mediaType: nil,
            decodedURL: kind == .voice ? URL(fileURLWithPath: "/tmp/\(primary).m4a") : nil,
            pcm: kind == .voice ? [0.2, 0.6] : [],
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }

    private static let owner = "owner@example.com"
    private static let jid = "contact@example.com"
}

private final class IntegrationVoicePlaybackCoordinator: MediaGalleryVoicePlaybackCoordinating {
    func addObserver(_ observer: @escaping (VoiceMessageStateChange) -> Void) -> UUID {
        UUID()
    }

    func removeObserver(_ token: UUID?) {}

    func state(for descriptor: VoiceMessageDescriptor) -> VoiceMessagePlaybackState {
        descriptor.isLocallyAvailable ? .downloaded : .notDownloaded
    }

    func handleTap(_ descriptor: VoiceMessageDescriptor) {}

    func setVisibleVoiceMessages(_ visibleDescriptors: [VoiceMessageDescriptor]) {}
}
