import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatAttachmentImageEditorTests: XCTestCase {
    func testEditAvailabilityAllowsOnlyStaticImages() {
        XCTAssertTrue(ChatAttachmentImageEditAvailabilityPolicy.isEditable(makeImageDraft(id: "asset:image")))
        XCTAssertFalse(ChatAttachmentImageEditAvailabilityPolicy.isEditable(makeImageDraft(id: "asset:animated", mediaKind: .animatedImage)))
        XCTAssertFalse(ChatAttachmentImageEditAvailabilityPolicy.isEditable(makeImageDraft(id: "asset:video", mediaKind: .video)))
        XCTAssertFalse(ChatAttachmentImageEditAvailabilityPolicy.isEditable(makeImageDraft(id: "file:audio", mediaKind: .audio)))
        XCTAssertFalse(ChatAttachmentImageEditAvailabilityPolicy.isEditable(makeImageDraft(id: "file:document", mediaKind: .file)))
    }

    func testCropGeometryMapsViewportToImageRectAndClampsToImageBounds() {
        let cropRect = ChatAttachmentImageCropGeometryPolicy.cropRect(
            imageSize: CGSize(width: 1000, height: 800),
            viewportSize: CGSize(width: 200, height: 200),
            zoomScale: 2,
            contentOffset: CGPoint(x: 50, y: 100)
        )
        XCTAssertEqual(cropRect, CGRect(x: 25, y: 50, width: 100, height: 100))

        let clampedRect = ChatAttachmentImageCropGeometryPolicy.cropRect(
            imageSize: CGSize(width: 1000, height: 800),
            viewportSize: CGSize(width: 200, height: 200),
            zoomScale: 2,
            contentOffset: CGPoint(x: 5000, y: 5000)
        )
        XCTAssertEqual(clampedRect, CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    func testRotationSwapsOutputDimensionsAndResetsValidGeometry() {
        let state = ChatAttachmentImageCropGeometryPolicy.stateAfterRotatingClockwise(
            imageSize: CGSize(width: 640, height: 480),
            viewportSize: CGSize(width: 320, height: 320),
            currentRotation: .degrees0
        )

        XCTAssertEqual(state.rotation, .degrees90)
        XCTAssertEqual(state.rotatedImageSize, CGSize(width: 480, height: 640))
        XCTAssertTrue(CGRect(origin: .zero, size: state.rotatedImageSize).contains(state.cropRect))
    }

    func testEditedImageOutputDraftPreservesOriginalIdentityAndPreparedJpegMetadata() throws {
        let builder = makeOutputBuilder()
        let sourceDraft = makeImageDraft(id: AttachmentAssetDraft(assetLocalIdentifier: "asset-1").id)
        let image = makeImage(size: CGSize(width: 80, height: 40))

        let editedDraft = try builder.makeEditedDraft(
            sourceDraft: sourceDraft,
            sourceImage: image,
            cropRect: CGRect(x: 10, y: 5, width: 40, height: 20),
            rotation: .degrees0
        )

        XCTAssertTrue(editedDraft.id.hasPrefix("edited:file://"))
        XCTAssertEqual(editedDraft.originalDraftID, sourceDraft.id)
        XCTAssertEqual(editedDraft.source, .gallery)
        XCTAssertEqual(editedDraft.mediaKind, .image)
        XCTAssertEqual(editedDraft.filename, "edited-image-00000000-0000-0000-0000-000000000014.jpg")
        XCTAssertGreaterThan(editedDraft.byteSize, 0)
        XCTAssertEqual(editedDraft.dimensions, CGSize(width: 40, height: 20))

        guard case .prepared(let file) = editedDraft.preparationState else {
            return XCTFail("Expected prepared edited image")
        }

        XCTAssertEqual(file.mediaType, "image/jpeg")
        XCTAssertEqual(file.filename, editedDraft.filename)
        XCTAssertEqual(file.dimensions, editedDraft.dimensions)
        XCTAssertEqual(file.localFileURL, AttachmentEditedDraft.url(from: editedDraft.id))
        XCTAssertEqual(file.referenceURL, file.localFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.localFileURL.path))
    }

    func testCancelEditLeavesOriginalDraftSelectedAndDoesNotBuildOutput() {
        let builder = FakeTask14OutputBuilder()
        let delegate = FakeTask14ImageEditorDelegate()
        let editor = ChatAttachmentImageEditorViewController(
            draft: makeImageDraft(id: "asset:image"),
            image: makeImage(),
            outputBuilder: builder
        )
        editor.delegate = delegate

        editor.loadViewIfNeeded()
        editor.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(builder.makeEditedDraftCallCount, 0)
        XCTAssertEqual(delegate.cancelCount, 1)
        XCTAssertTrue(delegate.finishedDrafts.isEmpty)
    }

    func testApplyingEditReplacesActiveDraftPreservesOrderCountCaptionAndPreview() throws {
        let source = FakeTask14SelectableSourceController(source: .gallery)
        var presentedPreview: ChatAttachmentPreviewViewController?
        let sheet = makeSheet(source: source) { _, preview, _, completion in
            presentedPreview = preview as? ChatAttachmentPreviewViewController
            completion?()
        }
        let first = makeImageDraft(id: AttachmentAssetDraft(assetLocalIdentifier: "first").id)
        let second = makeImageDraft(id: AttachmentAssetDraft(assetLocalIdentifier: "second").id)
        let edited = makePreparedEditedDraft(originalDraftID: second.id, filename: "edited.jpg")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([first, second])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        let preview = try XCTUnwrap(presentedPreview)
        preview.captionInputView.text = "batch caption"
        preview.goToNextDraft()

        sheet.chatAttachmentPreviewViewController(preview, didReplaceDraftWithID: second.id, updatedDraft: edited)

        XCTAssertEqual(source.selectedAttachmentDrafts.map(\.id), [first.id, edited.id])
        XCTAssertEqual(sheet.selectedAttachmentDrafts.map(\.id), [first.id, edited.id])
        XCTAssertEqual(sheet.selectedItemCount, 2)
        XCTAssertEqual(sheet.captionState.rawText, "batch caption")
        XCTAssertEqual(preview.drafts.map(\.id), [first.id, edited.id])
        XCTAssertEqual(preview.currentDraft?.id, edited.id)
    }

    func testReEditingEditedDraftKeepsOriginalIdentityAndUsesEditedFileAsSource() throws {
        let builder = makeOutputBuilder()
        let original = makeImageDraft(id: AttachmentAssetDraft(assetLocalIdentifier: "asset-1").id)
        let firstEdit = try builder.makeEditedDraft(
            sourceDraft: original,
            sourceImage: makeImage(size: CGSize(width: 60, height: 40)),
            cropRect: CGRect(x: 0, y: 0, width: 30, height: 20),
            rotation: .degrees0
        )

        let provider = DefaultChatAttachmentImageEditSourceProvider()
        let loadedImage = try requestEditImage(provider: provider, draft: firstEdit)
        let secondEdit = try builder.makeEditedDraft(
            sourceDraft: firstEdit,
            sourceImage: loadedImage,
            cropRect: CGRect(x: 0, y: 0, width: 15, height: 10),
            rotation: .degrees90
        )

        XCTAssertEqual(secondEdit.originalDraftID, original.id)
        XCTAssertNotEqual(secondEdit.id, firstEdit.id)
    }

    func testReferenceBuilderUsesEditedPreparedOutputFile() throws {
        let builder = makeOutputBuilder()
        let editedDraft = try builder.makeEditedDraft(
            sourceDraft: makeImageDraft(id: "asset:image"),
            sourceImage: makeImage(size: CGSize(width: 80, height: 40)),
            cropRect: CGRect(x: 0, y: 0, width: 40, height: 20),
            rotation: .degrees0
        )

        let reference = try XCTUnwrap(
            ChatAttachmentReferenceBuilder()
                .makeReferences(from: [editedDraft], context: Self.context)
                .first
        )

        let editedURL = try XCTUnwrap(AttachmentEditedDraft.url(from: editedDraft.id))
        XCTAssertEqual(reference.localFileUrl, editedURL)
        XCTAssertEqual(reference.metadata?["uri"] as? String, editedURL.absoluteString)
        XCTAssertEqual(reference.metadata?["filename"] as? String, editedDraft.filename)
    }

    func testEditorDoesNotExposeDrawingOrQualityControls() {
        let editor = ChatAttachmentImageEditorViewController(
            draft: makeImageDraft(id: "asset:image"),
            image: makeImage(),
            outputBuilder: FakeTask14OutputBuilder()
        )

        editor.loadViewIfNeeded()

        XCTAssertNil(editor.view.viewWithAccessibilityIdentifier("chatAttachmentImageEditor.drawingButton"))
        XCTAssertNil(editor.view.viewWithAccessibilityIdentifier("chatAttachmentImageEditor.qualityButton"))
        XCTAssertFalse(editor.rotateButton.isHidden)
        XCTAssertFalse(editor.doneButton.isHidden)
    }

    private static let context = ChatAttachmentFlowContext(
        owner: "alice@example.com",
        jid: "bob@example.com",
        conversationType: .regular,
        forwardedMessageIds: []
    )

    private func makeSheet(
        source: ChatAttachmentSourceControlling,
        previewPresentationHandler: @escaping ChatAttachmentSheetViewController.PreviewPresentationHandler
    ) -> ChatAttachmentSheetViewController {
        ChatAttachmentSheetViewController(
            context: Self.context,
            sourceControllerFactory: FakeTask14SourceControllerFactory(source: source),
            previewPresentationHandler: previewPresentationHandler,
            previewDismissalHandler: { _, _, completion in completion?() }
        )
    }

    private func makeOutputBuilder() -> ChatAttachmentImageEditOutputBuilder {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-task14-tests-\(UUID().uuidString)", isDirectory: true)
        var uuidCounter = 14
        return ChatAttachmentImageEditOutputBuilder(
            outputDirectory: directory,
            uuidProvider: {
                defer { uuidCounter += 1 }
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", uuidCounter))!
            }
        )
    }

    private func requestEditImage(
        provider: DefaultChatAttachmentImageEditSourceProvider,
        draft: AttachmentDraft
    ) throws -> UIImage {
        var result: Result<UIImage, ChatAttachmentImageEditSourceError>?
        provider.requestEditableImage(for: draft, targetSize: CGSize(width: 100, height: 100)) { imageResult in
            result = imageResult
        }

        switch try XCTUnwrap(result) {
        case .success(let image):
            return image
        case .failure(let error):
            throw error
        }
    }

    private func makeImageDraft(
        id: String,
        mediaKind: AttachmentMediaKind = .image
    ) -> AttachmentDraft {
        AttachmentDraft(
            id: id,
            source: .gallery,
            mediaKind: mediaKind,
            thumbnailState: .none,
            filename: "image.jpg",
            byteSize: 0,
            duration: nil,
            dimensions: CGSize(width: 100, height: 80),
            preparationState: .pending
        )
    }

    private func makePreparedEditedDraft(
        originalDraftID: String,
        filename: String
    ) -> AttachmentDraft {
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        let preparedFile = AttachmentPreparedFile(
            localFileURL: url,
            referenceURL: url,
            filename: filename,
            byteSize: 128,
            mediaType: "image/jpeg",
            dimensions: CGSize(width: 20, height: 10),
            duration: nil,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )
        return AttachmentDraft(
            id: AttachmentEditedDraft(url: url).id,
            source: .gallery,
            mediaKind: .image,
            thumbnailState: .available(key: url.absoluteString),
            filename: filename,
            byteSize: 128,
            duration: nil,
            dimensions: CGSize(width: 20, height: 10),
            preparationState: .prepared(preparedFile),
            originalDraftID: originalDraftID
        )
    }

    private func makeImage(size: CGSize = CGSize(width: 20, height: 20)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private final class FakeTask14SelectableSourceController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating {
    let source: ChatAttachmentSource
    var onSelectionCountChanged: ((Int) -> Void)?
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)?
    private(set) var selectedAttachmentDrafts: [AttachmentDraft] = []

    var viewController: UIViewController {
        self
    }

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func replaceSelectedDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
        onSelectionCountChanged?(drafts.count)
        onSelectedAttachmentDraftsChanged?(drafts)
    }

    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        selectedAttachmentDrafts.removeAll { $0.id == draftID }
        onSelectionCountChanged?(selectedAttachmentDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedAttachmentDrafts)
        return selectedAttachmentDrafts
    }

    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft] {
        guard let index = selectedAttachmentDrafts.firstIndex(where: { $0.id == draftID }) else {
            return selectedAttachmentDrafts
        }
        selectedAttachmentDrafts[index] = updatedDraft
        onSelectionCountChanged?(selectedAttachmentDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedAttachmentDrafts)
        return selectedAttachmentDrafts
    }
}

private struct FakeTask14SourceControllerFactory: ChatAttachmentSourceControllerFactory {
    let source: ChatAttachmentSourceControlling

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        self.source
    }
}

private final class FakeTask14OutputBuilder: ChatAttachmentImageEditOutputBuilding {
    var makeEditedDraftCallCount = 0
    var removedDraftIDs: [String] = []

    func makeEditedDraft(
        sourceDraft: AttachmentDraft,
        sourceImage: UIImage,
        cropRect: CGRect,
        rotation: ChatAttachmentImageRotation
    ) throws -> AttachmentDraft {
        makeEditedDraftCallCount += 1
        return sourceDraft
    }

    func removeTemporaryFiles(for draft: AttachmentDraft) {
        removedDraftIDs.append(draft.id)
    }
}

private final class FakeTask14ImageEditorDelegate: ChatAttachmentImageEditorViewControllerDelegate {
    var cancelCount = 0
    var finishedDrafts: [AttachmentDraft] = []
    var failures: [ChatAttachmentImageEditOutputBuilderError] = []

    func chatAttachmentImageEditorViewControllerDidCancel(_ editor: ChatAttachmentImageEditorViewController) {
        cancelCount += 1
    }

    func chatAttachmentImageEditorViewController(
        _ editor: ChatAttachmentImageEditorViewController,
        didFinishWith editedDraft: AttachmentDraft
    ) {
        finishedDrafts.append(editedDraft)
    }

    func chatAttachmentImageEditorViewController(
        _ editor: ChatAttachmentImageEditorViewController,
        didFailWith error: ChatAttachmentImageEditOutputBuilderError
    ) {
        failures.append(error)
    }
}

private extension UIView {
    func viewWithAccessibilityIdentifier(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier {
            return self
        }
        for subview in subviews {
            if let matchingView = subview.viewWithAccessibilityIdentifier(identifier) {
                return matchingView
            }
        }
        return nil
    }
}
