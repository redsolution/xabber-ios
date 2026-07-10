import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryVideoCellStateTests: XCTestCase {
    func testMapperFormatsNumericDurationAndExposesPreviewURL() throws {
        let item = MessageMediaAttachmentStorageItem()
        item.kind = .video
        item.primary = "video"
        item.url_ = "https://gallery.example/video.mp4"
        item.metadata = [
            "duration": 3_661,
            "thumbnail": "https://gallery.example/video-preview.jpg"
        ]

        let mapped = MediaGalleryDatasourceMapper.map(
            item,
            revealedSensitiveMediaPrimaries: []
        )

        XCTAssertEqual(mapped.durationSeconds, 3_661)
        XCTAssertEqual(mapped.formattedDuration, "1:01:01")
        XCTAssertEqual(mapped.previewURL?.absoluteString, "https://gallery.example/video-preview.jpg")
        XCTAssertEqual(mapped.previewCacheIdentity, "https://gallery.example/video-preview.jpg")
    }

    func testMapperFallsBackToFormattedVideoDurationAndCachePreviewKey() {
        let item = MessageMediaAttachmentStorageItem()
        item.kind = .video
        item.primary = "cached-video"
        item.url_ = "https://gallery.example/cached-video.mp4"
        item.metadata = [
            "duration": 0,
            "video_duration": "1:05",
            "thumbnail": "generated-preview-cache-key"
        ]

        let mapped = MediaGalleryDatasourceMapper.map(
            item,
            revealedSensitiveMediaPrimaries: []
        )

        XCTAssertEqual(mapped.durationSeconds, 65)
        XCTAssertEqual(mapped.formattedDuration, "1:05")
        XCTAssertNil(mapped.previewURL)
        XCTAssertEqual(mapped.previewCacheIdentity, "generated-preview-cache-key")
    }

    func testPreviewPolicySelectsURLCacheKeyEmbeddedThumbThenPlaceholder() throws {
        let previewURL = try XCTUnwrap(URL(string: "https://gallery.example/preview.jpg"))
        let remoteState = MediaGalleryVideoCellStatePolicy.state(
            for: item(primary: "remote", previewURL: previewURL),
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )
        let cacheState = MediaGalleryVideoCellStatePolicy.state(
            for: item(primary: "cache", previewCacheIdentity: "preview-cache-key"),
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )
        let thumbState = MediaGalleryVideoCellStatePolicy.state(
            for: item(primary: "thumb", thumb: solidImage()),
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )
        let placeholderState = MediaGalleryVideoCellStatePolicy.state(
            for: item(primary: "placeholder"),
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )

        guard case .request(let request) = remoteState.previewSource else {
            return XCTFail("Expected a display-size-aware preview request")
        }
        XCTAssertEqual(request.url, previewURL)
        XCTAssertEqual(cacheState.previewSource, .cacheKey("preview-cache-key"))
        XCTAssertEqual(thumbState.previewSource, .embeddedThumbnail)
        XCTAssertEqual(placeholderState.previewSource, .placeholder)
    }

    func testMissingDurationHidesBadgeWhilePlayAndPlaceholderStayVisible() {
        let state = MediaGalleryVideoCellStatePolicy.state(
            for: item(primary: "placeholder"),
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )
        let cell = VideoGalleryForChatViewController.GalleryItemCell(
            frame: CGRect(x: 0, y: 0, width: 120, height: 120)
        )

        cell.configure(state: state, embeddedThumbnail: nil)

        XCTAssertTrue(cell.durationLabel.isHidden)
        XCTAssertNil(cell.durationLabel.text)
        XCTAssertFalse(cell.playIconContainer.isHidden)
        XCTAssertFalse(cell.placeholderImageView.isHidden)
        XCTAssertEqual(cell.placeholderImageView.image, UIImage(systemName: "video.fill"))
    }

    func testKnownDurationUsesMonospacedBadgeAndPlayIcon() {
        let state = MediaGalleryVideoCellStatePolicy.state(
            for: item(primary: "duration", duration: 65),
            displaySize: CGSize(width: 120, height: 120),
            scale: 3
        )
        let cell = VideoGalleryForChatViewController.GalleryItemCell(
            frame: CGRect(x: 0, y: 0, width: 120, height: 120)
        )

        cell.configure(state: state, embeddedThumbnail: nil)

        XCTAssertEqual(cell.durationLabel.text, "1:05")
        XCTAssertFalse(cell.durationLabel.isHidden)
        XCTAssertFalse(cell.playIconContainer.isHidden)
        XCTAssertEqual(cell.playIconView.image, UIImage(systemName: "play.fill"))
    }

    func testSensitiveSelectionConfirmsBeforePlaybackThenPlaysAfterReveal() throws {
        let playbackURL = try XCTUnwrap(URL(string: "https://gallery.example/video.mp4"))
        let hidden = item(
            primary: "sensitive",
            playbackURL: playbackURL,
            isSensitive: true,
            isSensitiveRevealed: false
        )
        let revealed = item(
            primary: "sensitive",
            playbackURL: playbackURL,
            isSensitive: true,
            isSensitiveRevealed: true
        )

        XCTAssertEqual(
            MediaGalleryVideoSelectionPolicy.action(for: hidden),
            .confirmSensitive(playbackURL)
        )
        XCTAssertEqual(
            MediaGalleryVideoSelectionPolicy.action(for: revealed),
            .play(playbackURL)
        )
    }

    private func item(
        primary: String,
        playbackURL: URL? = URL(string: "https://gallery.example/video.mp4"),
        previewURL: URL? = nil,
        previewCacheIdentity: String? = nil,
        thumb: UIImage? = nil,
        duration: TimeInterval? = nil,
        isSensitive: Bool = false,
        isSensitiveRevealed: Bool = false
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .video,
            primary: primary,
            owner: "owner@example.com",
            jid: "contact@example.com",
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 100),
            filename: "\(primary).mp4",
            url: playbackURL,
            messagePrimary: "message-\(primary)",
            archiveId: "archive-\(primary)",
            isDownloaded: false,
            verySmallThumb: nil,
            thumb: thumb,
            byteSize: 0,
            formattedByteSize: "0 B",
            durationSeconds: duration,
            formattedDuration: duration.map(MediaGalleryDatasourceMapper.formatDuration),
            previewURL: previewURL,
            previewCacheIdentity: previewCacheIdentity ?? previewURL?.absoluteString,
            mediaType: "video/mp4",
            decodedURL: nil,
            pcm: [],
            isSensitive: isSensitive,
            isSensitiveRevealed: isSensitiveRevealed
        )
    }

    private func solidImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}
