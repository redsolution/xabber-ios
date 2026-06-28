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

    func testCloudStorageFileListingSkipsMalformedRowsAndMapsValidPayload() throws {
        let listing = ChatAttachmentCloudStorageFileListing.make(
            items: [
                [
                    "id": 7,
                    "file": "https://gallery.example/files/report.pdf",
                    "name": "report.pdf",
                    "size": 42,
                    "media_type": "application/pdf",
                    "hash": "remote-hash",
                    "created_at": "2026-06-29T10:11:12.123+0000",
                    "metadata": ["source": "test"]
                ] as NSDictionary,
                [
                    "id": 8,
                    "name": "missing-url.pdf",
                    "size": 12,
                    "media_type": "application/pdf"
                ] as NSDictionary
            ],
            totalObjects: 2,
            objPerPage: 20,
            totalPages: 1,
            page: 1
        )

        let file = try XCTUnwrap(listing.files.first)
        XCTAssertEqual(listing.files.count, 1)
        XCTAssertEqual(file.id, 7)
        XCTAssertEqual(file.remoteURL.absoluteString, "https://gallery.example/files/report.pdf")
        XCTAssertEqual(file.filename, "report.pdf")
        XCTAssertEqual(file.byteSize, 42)
        XCTAssertEqual(file.mediaType, "application/pdf")
        XCTAssertEqual(file.hash, "remote-hash")
        XCTAssertEqual(file.metadata?["source"], "test")
    }

    func testFileSourceLoadsFirstCloudStoragePageAndRendersRowsForOwner() {
        let provider = FakeTask15CloudStorageFileListingProvider(results: [
            .success(makeCloudListing(files: [makeCloudFile(id: 7, filename: "report.pdf")], page: 1, totalPages: 1))
        ])
        let controller = makeFileSource(cloudStorageFileProvider: provider)

        controller.loadViewIfNeeded()

        XCTAssertEqual(provider.requests, [FakeTask15CloudStorageFileListingProvider.Request(owner: Self.context.owner, page: 1)])
        XCTAssertEqual(controller.filesTableView.numberOfSections, 1)
        XCTAssertEqual(controller.filesTableView.numberOfRows(inSection: 0), 1)
        let cell = controller.tableView(
            controller.filesTableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(cell.textLabel?.text ?? cell.contentConfigurationText, "report.pdf")
        XCTAssertEqual(cell.accessibilityIdentifier, "chatAttachmentFile.cloudFileCell.0")
    }

    func testScrollingNearBottomLoadsNextCloudStoragePageOnce() {
        let provider = FakeTask15CloudStorageFileListingProvider(results: [
            .success(makeCloudListing(files: [makeCloudFile(id: 1, filename: "first.pdf")], page: 1, totalPages: 2)),
            .success(makeCloudListing(files: [makeCloudFile(id: 2, filename: "second.pdf")], page: 2, totalPages: 2))
        ])
        let controller = makeFileSource(cloudStorageFileProvider: provider)

        controller.loadViewIfNeeded()
        controller.filesTableView.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        controller.filesTableView.contentSize = CGSize(width: 390, height: 800)
        controller.filesTableView.contentOffset = CGPoint(x: 0, y: 620)
        controller.scrollViewDidScroll(controller.filesTableView)
        controller.scrollViewDidScroll(controller.filesTableView)

        XCTAssertEqual(provider.requests.map(\.page), [1, 2])
        XCTAssertEqual(controller.filesTableView.numberOfRows(inSection: 0), 2)
    }

    func testTappingCloudStorageFileTogglesSelectionAndCheckmark() {
        let provider = FakeTask15CloudStorageFileListingProvider(results: [
            .success(makeCloudListing(files: [makeCloudFile(id: 7, filename: "report.pdf")], page: 1, totalPages: 1))
        ])
        let controller = makeFileSource(cloudStorageFileProvider: provider)
        var emittedCounts: [Int] = []
        controller.onSelectionCountChanged = { emittedCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.tableView(controller.filesTableView, didSelectRowAt: IndexPath(row: 0, section: 0))

        XCTAssertEqual(controller.selectedAttachmentDrafts.map(\.id), ["cloud-file:7"])
        XCTAssertEqual(emittedCounts, [1])
        XCTAssertEqual(
            controller.tableView(controller.filesTableView, cellForRowAt: IndexPath(row: 0, section: 0)).accessoryType,
            .checkmark
        )

        controller.tableView(controller.filesTableView, didSelectRowAt: IndexPath(row: 0, section: 0))

        XCTAssertTrue(controller.selectedAttachmentDrafts.isEmpty)
        XCTAssertEqual(emittedCounts, [1, 0])
    }

    func testLocalPickedFileCoexistsWithSelectedCloudFileInSeparateSection() throws {
        let provider = FakeTask15CloudStorageFileListingProvider(results: [
            .success(makeCloudListing(files: [makeCloudFile(id: 7, filename: "report.pdf")], page: 1, totalPages: 1))
        ])
        let presenter = FakeTask15DocumentPickerPresenter()
        let controller = makeFileSource(
            documentPickerPresenter: presenter,
            cloudStorageFileProvider: provider
        )
        let localURL = try makeTemporaryFile(named: "local.pdf", contents: Data([1]))

        controller.loadViewIfNeeded()
        controller.tableView(controller.filesTableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        controller.chooseFilesButton.sendActions(for: .touchUpInside)
        presenter.complete(.picked([localURL]))

        XCTAssertEqual(controller.selectedAttachmentDrafts.map(\.filename), ["report.pdf", "local.pdf"])
        XCTAssertEqual(controller.filesTableView.numberOfSections, 2)
        XCTAssertEqual(controller.filesTableView.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(controller.filesTableView.numberOfRows(inSection: 1), 1)
    }

    func testMaximumSelectionCountAppliesAcrossLocalAndCloudFiles() throws {
        let provider = FakeTask15CloudStorageFileListingProvider(results: [
            .success(makeCloudListing(files: [
                makeCloudFile(id: 10, filename: "allowed.pdf"),
                makeCloudFile(id: 11, filename: "blocked.pdf")
            ], page: 1, totalPages: 1))
        ])
        let controller = makeFileSource(cloudStorageFileProvider: provider)
        let selected = try (0..<9).map { try makePreparedFileDraft(filename: "file-\($0).pdf") }

        controller.loadViewIfNeeded()
        controller.syncSelectedAttachmentDrafts(selected)
        controller.tableView(controller.filesTableView, didSelectRowAt: IndexPath(row: 0, section: 1))
        controller.tableView(controller.filesTableView, didSelectRowAt: IndexPath(row: 1, section: 1))

        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 10)
        XCTAssertEqual(controller.selectedAttachmentDrafts.last?.filename, "allowed.pdf")
        XCTAssertEqual(controller.lastImportFailures, [.maximumSelectionCountReached])
    }

    func testReferenceBuilderEmitsAlreadyUploadedRemoteReferenceForCloudFileDraft() throws {
        let draft = makeCloudFile(id: 7, filename: "report.pdf").makeAttachmentDraft()

        let reference = try XCTUnwrap(
            ChatAttachmentReferenceBuilder()
                .makeReferences(from: [draft], context: Self.context)
                .first
        )

        XCTAssertTrue(reference.isUploaded)
        XCTAssertNil(reference.localFileUrl)
        XCTAssertEqual(reference.downloadUrl?.absoluteString, "https://gallery.example/files/report.pdf")
        XCTAssertEqual(reference.fileID, 7)
        XCTAssertEqual(reference.filehash, "hash-7")
        XCTAssertEqual(reference.metadata?["uri"] as? String, "https://gallery.example/files/report.pdf")
        XCTAssertEqual(reference.metadata?["filename"] as? String, "report.pdf")
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "application/pdf")
    }

    func testChooseFilesButtonIsLaidOutBelowNavigationTitleWhenHostedInPageSheetWrapper() {
        let gallery = ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: FakeTask15PhotoLibraryAuthorizer(status: .authorized),
            limitedLibraryPresenter: FakeTask15LimitedLibraryPresenter(),
            settingsOpener: FakeTask15ApplicationSettingsOpener(),
            galleryDataProvider: FakeTask15GalleryDataProvider(),
            thumbnailProvider: FakeTask15GalleryThumbnailProvider()
        )
        let fileSource = makeFileSource()
        let picker = ChatAttachmentSheetViewController(
            context: Self.context,
            sourceControllerFactory: Task15SourceFactory(gallery: gallery, file: fileSource)
        )
        let navigationController = UINavigationController(rootViewController: picker)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

        window.rootViewController = navigationController
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        navigationController.loadViewIfNeeded()
        picker.loadViewIfNeeded()
        picker.switchSource(to: .file)
        navigationController.view.setNeedsLayout()
        navigationController.view.layoutIfNeeded()

        let buttonFrame = fileSource.chooseFilesButton.convert(
            fileSource.chooseFilesButton.bounds,
            to: navigationController.view
        )
        let expectedTop = navigationController.navigationBar.frame.maxY + 12

        XCTAssertEqual(picker.navigationItem.title, ChatAttachmentLocalization.string(.sourceFileTitle))
        XCTAssertEqual(buttonFrame.minY, expectedTop, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(buttonFrame.minY, navigationController.navigationBar.frame.maxY)
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
        fileDraftBuilder: ChatAttachmentFileDraftBuilding? = nil,
        cloudStorageFileProvider: ChatAttachmentCloudStorageFileListingProviding? = nil
    ) -> ChatAttachmentFileSourceViewController {
        ChatAttachmentFileSourceViewController(
            owner: cloudStorageFileProvider == nil ? nil : Self.context.owner,
            documentPickerPresenter: documentPickerPresenter,
            fileDraftBuilder: fileDraftBuilder ?? ChatAttachmentFileDraftBuilder(outputDirectory: makeTemporaryDirectory()),
            cloudStorageFileProvider: cloudStorageFileProvider
        )
    }

    private func makeCloudFile(id: Int, filename: String) -> ChatAttachmentCloudStorageFile {
        ChatAttachmentCloudStorageFile(
            id: id,
            remoteURL: URL(string: "https://gallery.example/files/\(filename)")!,
            filename: filename,
            byteSize: 64,
            mediaType: "application/pdf",
            hash: "hash-\(id)",
            createdAt: nil,
            metadata: nil
        )
    }

    private func makeCloudListing(
        files: [ChatAttachmentCloudStorageFile],
        page: Int,
        totalPages: Int
    ) -> ChatAttachmentCloudStorageFileListing {
        ChatAttachmentCloudStorageFileListing(
            files: files,
            totalObjects: files.count,
            objPerPage: 20,
            totalPages: totalPages,
            page: page
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

private final class FakeTask15CloudStorageFileListingProvider: ChatAttachmentCloudStorageFileListingProviding {
    struct Request: Equatable {
        let owner: String
        let page: Int
    }

    private var results: [Result<ChatAttachmentCloudStorageFileListing, Error>]
    private(set) var requests: [Request] = []

    init(results: [Result<ChatAttachmentCloudStorageFileListing, Error>]) {
        self.results = results
    }

    func loadCloudStorageFiles(
        owner: String,
        page: Int,
        completion: @escaping (Result<ChatAttachmentCloudStorageFileListing, Error>) -> Void
    ) {
        requests.append(Request(owner: owner, page: page))
        completion(results.isEmpty ? .failure(NSError(domain: "cloud", code: -1)) : results.removeFirst())
    }
}

private extension UITableViewCell {
    var contentConfigurationText: String? {
        (contentConfiguration as? UIListContentConfiguration)?.text
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
        case .geolocation, .contact:
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
