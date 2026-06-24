import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentAccessibilityLocalizationTests: XCTestCase {
    func testRequiredLocalizationKeysExistInEnglishAndRussian() throws {
        let english = try localizationKeys(for: "en")
        let russian = try localizationKeys(for: "ru")

        for key in ChatAttachmentLocalization.requiredKeys {
            XCTAssertTrue(english.contains(key), "Missing English localization for \(key)")
            XCTAssertTrue(russian.contains(key), "Missing Russian localization for \(key)")
        }
    }

    func testSourceBarExposesLocalizedLabelsAndAccessibilityValues() throws {
        let sourceBar = ChatAttachmentSourceBarView()
        sourceBar.configure(
            configuration: ChatAttachmentSourceBarConfiguration(
                sourceAvailability: [
                    .gallery: .available,
                    .file: .disabled,
                    .geolocation: .hidden
                ]
            ),
            selectedSource: .gallery
        )

        let galleryButton = try XCTUnwrap(sourceBar.button(for: .gallery))
        let fileButton = try XCTUnwrap(sourceBar.button(for: .file))

        XCTAssertEqual(galleryButton.configuration?.title, ChatAttachmentLocalization.string(.sourceGalleryTitle))
        XCTAssertEqual(galleryButton.accessibilityLabel, ChatAttachmentLocalization.string(.sourceGalleryAccessibilityLabel))
        XCTAssertEqual(galleryButton.accessibilityValue, ChatAttachmentLocalization.string(.accessibilitySelected))
        XCTAssertTrue(galleryButton.accessibilityTraits.contains(.selected))

        XCTAssertEqual(fileButton.configuration?.title, ChatAttachmentLocalization.string(.sourceFileTitle))
        XCTAssertEqual(fileButton.accessibilityLabel, ChatAttachmentLocalization.string(.sourceFileAccessibilityLabel))
        XCTAssertEqual(fileButton.accessibilityValue, ChatAttachmentLocalization.string(.accessibilityUnavailable))
        XCTAssertTrue(fileButton.accessibilityTraits.contains(.notEnabled))
    }

    func testStatusBannerExposesLocalizedActionsAndProgressAccessibility() {
        let drafts = [
            preparedDraft(id: "asset:ready"),
            draft(id: "asset:pending", state: .pending),
            draft(id: "asset:preparing", state: .preparing)
        ]
        let viewModel = ChatAttachmentBatchStatusPolicy.viewModel(for: drafts)
        let banner = ChatAttachmentStatusBannerView()

        banner.apply(viewModel)

        XCTAssertEqual(banner.titleLabel.text, ChatAttachmentLocalization.string(.statusPreparingAttachmentsTitle))
        XCTAssertEqual(banner.messageLabel.text, ChatAttachmentLocalization.string(.statusReadyCountMessage, arguments: ["1", "3"]))
        XCTAssertEqual(banner.progressView.accessibilityValue, ChatAttachmentLocalization.string(.statusReadyCountMessage, arguments: ["1", "3"]))
        XCTAssertEqual(banner.retryButton.accessibilityLabel, ChatAttachmentLocalization.string(.actionRetry))
        XCTAssertEqual(banner.removeButton.accessibilityLabel, ChatAttachmentLocalization.string(.actionRemove))
        XCTAssertTrue(banner.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertTrue(banner.messageLabel.adjustsFontForContentSizeCategory)
    }

    func testGalleryCellAccessibilityLabelsIncludeSelectionAndDisabledStates() {
        let selectedCell = ChatAttachmentGalleryCollectionViewCell(frame: .zero)
        let image = ChatAttachmentGalleryAsset(
            localIdentifier: "image-1",
            mediaKind: .image,
            creationDate: nil,
            pixelSize: CGSize(width: 100, height: 100),
            duration: nil
        )

        selectedCell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(
                for: .asset(image),
                thumbnailState: .image,
                selectionOrder: 2
            ),
            image: nil
        )

        XCTAssertEqual(
            selectedCell.accessibilityLabel,
            [
                ChatAttachmentLocalization.string(.galleryPhotoAccessibilityLabel),
                ChatAttachmentLocalization.string(.accessibilitySelectedOrder, arguments: ["2"])
            ].joined(separator: ", ")
        )
        XCTAssertEqual(selectedCell.accessibilityValue, ChatAttachmentLocalization.string(.accessibilitySelectedOrder, arguments: ["2"]))

        let cameraCell = ChatAttachmentGalleryCollectionViewCell(frame: .zero)
        cameraCell.configure(state: ChatAttachmentGalleryCellStatePolicy.state(for: .camera), image: nil)

        XCTAssertEqual(cameraCell.accessibilityLabel, ChatAttachmentLocalization.string(.galleryCameraUnavailableAccessibilityLabel))
        XCTAssertEqual(cameraCell.accessibilityValue, ChatAttachmentLocalization.string(.accessibilityUnavailable))
    }

    func testPreviewCaptionAndEditorControlsExposeLocalizedAccessibility() {
        let captionInput = ChatAttachmentCaptionInputView()
        let editor = ChatAttachmentImageEditorViewController(
            draft: draft(id: "asset:image", state: .pending),
            image: UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            },
            outputBuilder: ChatAttachmentImageEditOutputBuilder()
        )
        editor.loadViewIfNeeded()

        XCTAssertEqual(captionInput.textView.accessibilityLabel, ChatAttachmentLocalization.string(.captionAccessibilityLabel))
        XCTAssertEqual(captionInput.textView.accessibilityHint, ChatAttachmentLocalization.string(.captionPlaceholder))
        XCTAssertTrue(captionInput.textView.adjustsFontForContentSizeCategory)

        XCTAssertEqual(editor.cancelButton.accessibilityLabel, ChatAttachmentLocalization.string(.actionCancel))
        XCTAssertEqual(editor.rotateButton.accessibilityLabel, ChatAttachmentLocalization.string(.editorRotateAction))
        XCTAssertEqual(editor.doneButton.accessibilityLabel, ChatAttachmentLocalization.string(.actionDone))
    }

    private func localizationKeys(for language: String) throws -> Set<String> {
        let sourceRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = sourceRootURL
            .appendingPathComponent("xabber/translations/\(language).lproj/Localizable.strings")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let pattern = #"^\s*"([^"]+)"\s*="#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return Set(regex.matches(in: contents, options: [], range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: contents) else {
                return nil
            }
            return String(contents[keyRange])
        })
    }

    private func draft(
        id: String,
        state: AttachmentPreparationState,
        source: ChatAttachmentSource = .gallery,
        mediaKind: AttachmentMediaKind = .image
    ) -> AttachmentDraft {
        AttachmentDraft(
            id: id,
            source: source,
            mediaKind: mediaKind,
            thumbnailState: .none,
            filename: "\(id.replacingOccurrences(of: ":", with: "-")).jpg",
            byteSize: 0,
            duration: nil,
            dimensions: CGSize(width: 10, height: 10),
            preparationState: state
        )
    }

    private func preparedDraft(id: String) -> AttachmentDraft {
        let filename = "\(id.replacingOccurrences(of: ":", with: "-")).jpg"
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        let file = AttachmentPreparedFile(
            localFileURL: url,
            referenceURL: url,
            filename: filename,
            byteSize: 10,
            mediaType: "image/jpeg",
            dimensions: CGSize(width: 10, height: 10),
            duration: nil,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )
        return draft(id: id, state: .prepared(file))
    }
}
