import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatAttachmentFileSourceTests: XCTestCase {
    func testFileDraftBuilderImportsReadableFileAsPreparedDraft() throws {
        let sourceURL = try makeTemporaryFile(named: "document.pdf", contents: Data([1, 2, 3, 4]))
        let outputDirectory = makeTemporaryDirectory()
        let builder = ChatAttachmentFileDraftBuilder(
            outputDirectory: outputDirectory,
            uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000015")! }
        )

        let draft = try builder.makeDraft(from: sourceURL)

        XCTAssertEqual(draft.id, AttachmentFileDraft(url: sourceURL).id)
        XCTAssertEqual(draft.source, .file)
        XCTAssertEqual(draft.mediaKind, .file)
        XCTAssertEqual(draft.filename, "document.pdf")
        XCTAssertEqual(draft.byteSize, 4)
        XCTAssertEqual(draft.thumbnailState, .none)

        guard case .prepared(let file) = draft.preparationState else {
            return XCTFail("Expected prepared file draft")
        }

        XCTAssertEqual(file.filename, "document.pdf")
        XCTAssertEqual(file.byteSize, 4)
        XCTAssertEqual(file.mediaType, "application/pdf")
        XCTAssertEqual(file.referenceURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(file.localFileURL.path.hasPrefix(outputDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.localFileURL.path))
    }

    func testFileDraftBuilderMapsMimeBucketsToMediaKinds() throws {
        let builder = ChatAttachmentFileDraftBuilder(outputDirectory: makeTemporaryDirectory())

        let image = try builder.makeDraft(from: makeTemporaryFile(named: "image.jpg", contents: jpegData()))
        let animated = try builder.makeDraft(from: makeTemporaryFile(named: "anim.gif", contents: Data([1, 2, 3])))
        let video = try builder.makeDraft(from: makeTemporaryFile(named: "clip.mov", contents: Data([1, 2, 3])))
        let audio = try builder.makeDraft(from: makeTemporaryFile(named: "song.mp3", contents: Data([1, 2, 3])))
        let file = try builder.makeDraft(from: makeTemporaryFile(named: "archive.zip", contents: Data([1, 2, 3])))

        XCTAssertEqual(image.mediaKind, .image)
        XCTAssertEqual(animated.mediaKind, .animatedImage)
        XCTAssertEqual(video.mediaKind, .video)
        XCTAssertEqual(audio.mediaKind, .audio)
        XCTAssertEqual(file.mediaKind, .file)
    }

    func testFileDraftBuilderRejectsUnreadableEmptyAndOversizedFiles() throws {
        let outputDirectory = makeTemporaryDirectory()
        let builder = ChatAttachmentFileDraftBuilder(
            outputDirectory: outputDirectory,
            maximumFileSize: 3,
            securityScopedResourceAccessor: FakeTask15SecurityScopedResourceAccessor(canAccess: false)
        )

        XCTAssertThrowsError(try builder.makeDraft(from: URL(fileURLWithPath: "/tmp/missing-task15-file.bin"))) { error in
            XCTAssertEqual(error as? ChatAttachmentFileDraftBuilderError, .unreadableFile)
        }

        let emptyURL = try makeTemporaryFile(named: "empty.bin", contents: Data())
        XCTAssertThrowsError(try builder.makeDraft(from: emptyURL)) { error in
            XCTAssertEqual(error as? ChatAttachmentFileDraftBuilderError, .emptyFile)
        }

        let largeURL = try makeTemporaryFile(named: "large.bin", contents: Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try builder.makeDraft(from: largeURL)) { error in
            XCTAssertEqual(error as? ChatAttachmentFileDraftBuilderError, .oversizedFile(maximumSize: 3))
        }
    }

    func testChooseFilesButtonPresentsDocumentPickerForItemMultiSelect() {
        let presenter = FakeTask15DocumentPickerPresenter()
        let controller = makeFileSource(documentPickerPresenter: presenter)

        controller.loadViewIfNeeded()
        controller.chooseFilesButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertTrue(presenter.presentedFrom === controller)
        XCTAssertEqual(presenter.requestedContentTypes, [.item])
        XCTAssertEqual(presenter.requestedAllowsMultipleSelection, true)
    }

    func testDocumentPickerCancelKeepsSelectionUnchanged() throws {
        let presenter = FakeTask15DocumentPickerPresenter()
        let controller = makeFileSource(documentPickerPresenter: presenter)
        let existingDraft = try makePreparedFileDraft(filename: "existing.pdf")

        controller.loadViewIfNeeded()
        controller.syncSelectedAttachmentDrafts([existingDraft])
        controller.chooseFilesButton.sendActions(for: .touchUpInside)
        presenter.complete(.cancelled)

        XCTAssertEqual(controller.selectedAttachmentDrafts.map(\.id), [existingDraft.id])
    }

    func testPickedDocumentsAppendPreparedDraftsInOrderAndSkipFailures() throws {
        let firstURL = try makeTemporaryFile(named: "first.pdf", contents: Data([1]))
        let failedURL = URL(fileURLWithPath: "/tmp/missing-task15-file.pdf")
        let secondURL = try makeTemporaryFile(named: "second.txt", contents: Data([2]))
        let presenter = FakeTask15DocumentPickerPresenter()
        let controller = makeFileSource(documentPickerPresenter: presenter)
        var emittedDraftIDs: [[String]] = []
        controller.onSelectedAttachmentDraftsChanged = { emittedDraftIDs.append($0.map(\.id)) }

        controller.loadViewIfNeeded()
        controller.chooseFilesButton.sendActions(for: .touchUpInside)
        presenter.complete(.picked([firstURL, failedURL, secondURL]))

        XCTAssertEqual(controller.selectedAttachmentDrafts.map(\.filename), ["first.pdf", "second.txt"])
        XCTAssertEqual(emittedDraftIDs.last, controller.selectedAttachmentDrafts.map(\.id))
        XCTAssertEqual(controller.lastImportFailures.count, 1)
        XCTAssertFalse(controller.errorMessageLabel.isHidden)
    }

    func testPickingEleventhDocumentIsBlockedWithoutMutatingSelection() throws {
        let presenter = FakeTask15DocumentPickerPresenter()
        let controller = makeFileSource(documentPickerPresenter: presenter)
        let selected = try (0..<10).map { try makePreparedFileDraft(filename: "file-\($0).pdf") }
        let extraURL = try makeTemporaryFile(named: "extra.pdf", contents: Data([1]))

        controller.loadViewIfNeeded()
        controller.syncSelectedAttachmentDrafts(selected)
        controller.chooseFilesButton.sendActions(for: .touchUpInside)
        presenter.complete(.picked([extraURL]))

        XCTAssertEqual(controller.selectedAttachmentDrafts, selected)
        XCTAssertEqual(controller.lastImportFailures, [.maximumSelectionCountReached])
    }

    func testMixedGalleryAndFileSelectionSurvivesSourceSwitchesAndKeepsOrder() throws {
        let gallery = ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: FakeTask15PhotoLibraryAuthorizer(status: .authorized),
            limitedLibraryPresenter: FakeTask15LimitedLibraryPresenter(),
            settingsOpener: FakeTask15ApplicationSettingsOpener(),
            galleryDataProvider: FakeTask15GalleryDataProvider(),
            thumbnailProvider: FakeTask15GalleryThumbnailProvider()
        )
        let presenter = FakeTask15DocumentPickerPresenter()
        let fileSource = makeFileSource(documentPickerPresenter: presenter)
        let factory = Task15SourceFactory(gallery: gallery, file: fileSource)
        let sheet = ChatAttachmentSheetViewController(
            context: Self.context,
            sourceControllerFactory: factory
        )
        let galleryDraft = makeGalleryDraft(localIdentifier: "asset-1")
        let fileURL = try makeTemporaryFile(named: "document.pdf", contents: Data([1, 2]))

        sheet.loadViewIfNeeded()
        gallery.replaceSelectedDrafts([galleryDraft])
        sheet.switchSource(to: .file)
        fileSource.chooseFilesButton.sendActions(for: .touchUpInside)
        presenter.complete(.picked([fileURL]))
        sheet.switchSource(to: .gallery)

        XCTAssertEqual(sheet.selectedAttachmentDrafts.map(\.id), [
            galleryDraft.id,
            AttachmentFileDraft(url: fileURL).id
        ])
        XCTAssertEqual(gallery.selectedAttachmentDrafts.map(\.id), sheet.selectedAttachmentDrafts.map(\.id))
        XCTAssertEqual(fileSource.selectedAttachmentDrafts.map(\.id), sheet.selectedAttachmentDrafts.map(\.id))
        XCTAssertEqual(sheet.selectedItemCount, 2)
        XCTAssertTrue(sheet.selectionPreviewBarView.isHidden)
        XCTAssertFalse(sheet.selectionComposerBarView.isHidden)
        XCTAssertEqual(sheet.selectionComposerBarView.selectedCount, 2)
    }

    func testRemovingFileDraftCleansImportedFileAndReferenceBuilderUsesPreparedFile() throws {
        let sourceURL = try makeTemporaryFile(named: "document.pdf", contents: Data([1, 2, 3]))
        let outputDirectory = makeTemporaryDirectory()
        let builder = ChatAttachmentFileDraftBuilder(outputDirectory: outputDirectory)
        let controller = makeFileSource(fileDraftBuilder: builder)
        let draft = try builder.makeDraft(from: sourceURL)
        let importedURL: URL

        guard case .prepared(let file) = draft.preparationState else {
            return XCTFail("Expected prepared file draft")
        }
        importedURL = file.localFileURL

        controller.loadViewIfNeeded()
        controller.syncSelectedAttachmentDrafts([draft])

        let reference = try XCTUnwrap(
            ChatAttachmentReferenceBuilder()
                .makeReferences(from: [draft], context: Self.context)
                .first
        )
        XCTAssertEqual(reference.localFileUrl, importedURL)
        XCTAssertEqual(reference.metadata?["uri"] as? String, sourceURL.standardizedFileURL.absoluteString)
        XCTAssertEqual(reference.metadata?["filename"] as? String, "document.pdf")

        controller.removeSelectedAttachmentDraft(withID: draft.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: importedURL.path))
        XCTAssertTrue(controller.selectedAttachmentDrafts.isEmpty)
    }

    private static let context = ChatAttachmentFlowContext(
        owner: "alice@example.com",
        jid: "bob@example.com",
        conversationType: .regular,
        forwardedMessageIds: []
    )

    private func makeFileSource(
        documentPickerPresenter: ChatAttachmentDocumentPickerPresenting = FakeTask15DocumentPickerPresenter(),
        fileDraftBuilder: ChatAttachmentFileDraftBuilding? = nil
    ) -> ChatAttachmentFileSourceViewController {
        ChatAttachmentFileSourceViewController(
            documentPickerPresenter: documentPickerPresenter,
            fileDraftBuilder: fileDraftBuilder ?? ChatAttachmentFileDraftBuilder(outputDirectory: makeTemporaryDirectory())
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-task15-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeTemporaryFile(named filename: String, contents: Data) throws -> URL {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try contents.write(to: url)
        return url
    }

    private func makePreparedFileDraft(filename: String) throws -> AttachmentDraft {
        let url = try makeTemporaryFile(named: filename, contents: Data([1]))
        return try ChatAttachmentFileDraftBuilder(outputDirectory: makeTemporaryDirectory()).makeDraft(from: url)
    }

    private func makeGalleryDraft(localIdentifier: String) -> AttachmentDraft {
        AttachmentDraft(
            id: AttachmentAssetDraft(assetLocalIdentifier: localIdentifier).id,
            source: .gallery,
            mediaKind: .image,
            thumbnailState: .none,
            filename: "\(localIdentifier).jpg",
            byteSize: 0,
            duration: nil,
            dimensions: CGSize(width: 12, height: 8),
            preparationState: .pending
        )
    }

    private func jpegData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            .image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            .jpegData(compressionQuality: 0.9) ?? Data([1, 2, 3])
    }
}

private final class FakeTask15DocumentPickerPresenter: ChatAttachmentDocumentPickerPresenting {
    private(set) var presentCount = 0
    private(set) weak var presentedFrom: UIViewController?
    private(set) var requestedContentTypes: [UTType] = []
    private(set) var requestedAllowsMultipleSelection = false
    private var completion: ((ChatAttachmentDocumentPickerResult) -> Void)?

    func presentDocumentPicker(
        from viewController: UIViewController,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        completion: @escaping (ChatAttachmentDocumentPickerResult) -> Void
    ) {
        presentCount += 1
        presentedFrom = viewController
        requestedContentTypes = contentTypes
        requestedAllowsMultipleSelection = allowsMultipleSelection
        self.completion = completion
    }

    func complete(_ result: ChatAttachmentDocumentPickerResult) {
        completion?(result)
        completion = nil
    }
}

private final class FakeTask15SecurityScopedResourceAccessor: ChatAttachmentSecurityScopedResourceAccessing {
    let canAccess: Bool
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    init(canAccess: Bool) {
        self.canAccess = canAccess
    }

    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        startedURLs.append(url)
        return canAccess
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        stoppedURLs.append(url)
    }
}

private final class Task15SourceFactory: ChatAttachmentSourceControllerFactory {
    let gallery: ChatAttachmentGallerySourceViewController
    let file: ChatAttachmentFileSourceViewController

    init(gallery: ChatAttachmentGallerySourceViewController, file: ChatAttachmentFileSourceViewController) {
        self.gallery = gallery
        self.file = file
    }

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        switch source {
        case .gallery:
            return gallery
        case .file:
            return file
        case .geolocation:
            return ChatAttachmentPlaceholderSourceViewController(source: source)
        }
    }
}

private final class FakeTask15PhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
    var authorizationStatus: ChatAttachmentPhotosAuthorizationStatus

    init(status: ChatAttachmentPhotosAuthorizationStatus) {
        self.authorizationStatus = status
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentPhotosAuthorizationStatus) -> Void) {
        completion(authorizationStatus)
    }

    func registerChangeObserver(_ observer: AnyObject) {}
    func unregisterChangeObserver(_ observer: AnyObject) {}
    func containsAsset(localIdentifier: String) -> Bool { true }
}

private final class FakeTask15LimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    func presentLimitedLibraryPicker(from viewController: UIViewController) {}
}

private final class FakeTask15ApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {}
}

private final class FakeTask15GalleryDataProvider: ChatAttachmentGalleryDataProviding {
    func fetchAssets() -> [ChatAttachmentGalleryAsset] { [] }
}

private final class FakeTask15GalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
    func requestThumbnail(
        for asset: ChatAttachmentGalleryAsset,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentGalleryThumbnailResult) -> Void
    ) -> Int {
        0
    }

    func cancelThumbnailRequest(_ requestID: Int) {}
    func startCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {}
    func stopCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {}
}
