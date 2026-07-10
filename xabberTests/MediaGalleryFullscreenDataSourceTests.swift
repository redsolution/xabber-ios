import RealmSwift
import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryFullscreenDataSourceTests: XCTestCase {
    private var originalRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        originalRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "MediaGalleryFullscreenDataSourceTests-\(name)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = originalRealmConfiguration
        originalRealmConfiguration = nil
        super.tearDown()
    }

    func testMapperExposesVideoMetadataAndSessionRevealState() throws {
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let item = makeItem(kind: .video, primary: "video-primary")
        item.filename = "clip.mp4"
        item.sizeBytes = 2_048
        item.verySmallThumb = try XCTUnwrap(thumb.jpegData(compressionQuality: 0.8)).base64EncodedString()
        item.isSensitive = true
        item.metadata = [
            "duration": 65,
            "media-type": "video/mp4",
            "thumbnail": "https://gallery.example/previews/clip.jpg"
        ]

        let mapped = MediaGalleryDatasourceMapper.map(
            item,
            revealedSensitiveMediaPrimaries: [item.primary]
        )

        XCTAssertEqual(mapped.primary, "video-primary")
        XCTAssertEqual(mapped.kind, .video)
        XCTAssertEqual(mapped.url?.absoluteString, "https://gallery.example/files/video-primary")
        XCTAssertEqual(mapped.messagePrimary, "message-video-primary")
        XCTAssertEqual(mapped.archiveId, "archive-video-primary")
        XCTAssertEqual(mapped.filename, "clip.mp4")
        XCTAssertEqual(mapped.byteSize, 2_048)
        XCTAssertEqual(mapped.formattedByteSize, AccountQuotaStorageItem.beautify(size: 2_048))
        XCTAssertEqual(mapped.durationSeconds, 65)
        XCTAssertEqual(mapped.formattedDuration, "1:05")
        XCTAssertEqual(mapped.previewURL?.absoluteString, "https://gallery.example/previews/clip.jpg")
        XCTAssertEqual(mapped.previewCacheIdentity, "https://gallery.example/previews/clip.jpg")
        XCTAssertEqual(mapped.verySmallThumb, item.verySmallThumb)
        XCTAssertNotNil(mapped.thumb)
        XCTAssertTrue(mapped.isSensitive)
        XCTAssertTrue(mapped.isSensitiveRevealed)
    }

    func testMapperExposesVoicePlaybackMetadata() {
        let item = makeItem(kind: .voice, primary: "voice-primary")
        item.filename = "voice.ogg"
        item.isDownloaded = true
        item.metadata = [
            "duration": "7",
            "decodedUrl": "file:///tmp/voice.wav",
            "pcm": "0.1 0.25 0.5"
        ]

        let mapped = MediaGalleryDatasourceMapper.map(
            item,
            revealedSensitiveMediaPrimaries: []
        )

        XCTAssertEqual(mapped.kind, .voice)
        XCTAssertEqual(mapped.decodedURL?.absoluteString, "file:///tmp/voice.wav")
        XCTAssertTrue(mapped.isDownloaded)
        XCTAssertEqual(mapped.pcm, [0.1, 0.25, 0.5])
        XCTAssertEqual(mapped.durationSeconds, 7)
        XCTAssertEqual(mapped.formattedDuration, "0:07")
    }

    func testMapperRetainsRouteDataWhenMediaURLIsInvalid() {
        let item = makeItem(kind: .file, primary: "invalid-url-file")
        item.url_ = "not a url %"

        let mapped = MediaGalleryDatasourceMapper.map(
            item,
            revealedSensitiveMediaPrimaries: []
        )

        XCTAssertNil(mapped.url)
        XCTAssertEqual(mapped.messagePrimary, "message-invalid-url-file")
        XCTAssertEqual(mapped.archiveId, "archive-invalid-url-file")
    }

    func testFileAndVoiceGalleriesUseBaseRealmQuerySortedNewestFirst() throws {
        let realm = try Realm()
        let oldFile = makeItem(kind: .file, primary: "old-file", date: Date(timeIntervalSince1970: 10))
        let newFile = makeItem(kind: .file, primary: "new-file", date: Date(timeIntervalSince1970: 20))
        let voice = makeItem(kind: .voice, primary: "voice", date: Date(timeIntervalSince1970: 30))
        try realm.write {
            realm.add([oldFile, newFile, voice])
        }

        let filesController = FilesGalleryForChatViewController()
        filesController.owner = Self.owner
        filesController.jid = Self.jid
        filesController.conversationType = .regular
        filesController.loadViewIfNeeded()
        filesController.loadDatasource()

        XCTAssertEqual(filesController.collectionObserver?.map(\.primary), ["new-file", "old-file"])

        let voiceController = VoiceGalleryForChatViewController()
        voiceController.owner = Self.owner
        voiceController.jid = Self.jid
        voiceController.conversationType = .regular
        voiceController.loadViewIfNeeded()
        voiceController.loadDatasource()

        XCTAssertEqual(voiceController.collectionObserver?.map(\.primary), ["voice"])
    }

    private func makeItem(
        kind: MessageMediaAttachmentStorageItem.Kind,
        primary: String,
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> MessageMediaAttachmentStorageItem {
        let item = MessageMediaAttachmentStorageItem()
        item.primary = primary
        item.owner = Self.owner
        item.jid = Self.jid
        item.conversationType = .regular
        item.kind = kind
        item.messagePrimary = "message-\(primary)"
        item.archiveId = "archive-\(primary)"
        item.filename = "\(primary).bin"
        item.url_ = "https://gallery.example/files/\(primary)"
        item.date = date
        return item
    }

    private static let owner = "owner@example.com"
    private static let jid = "contact@example.com"
}
