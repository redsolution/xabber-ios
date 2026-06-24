import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentCameraCaptureTests: XCTestCase {
    func testCameraPolicyStatesCoverAvailabilityPermissionAndMediaSupport() {
        XCTAssertEqual(
            ChatAttachmentCameraPermissionPolicy.state(
                isCameraAvailable: true,
                authorizationStatus: .authorized,
                availableMediaTypes: ["public.image"]
            ),
            .ready
        )
        XCTAssertEqual(
            ChatAttachmentCameraPermissionPolicy.state(
                isCameraAvailable: true,
                authorizationStatus: .notDetermined,
                availableMediaTypes: ["public.movie"]
            ),
            .requestAuthorization
        )
        XCTAssertEqual(
            ChatAttachmentCameraPermissionPolicy.state(
                isCameraAvailable: false,
                authorizationStatus: .authorized,
                availableMediaTypes: ["public.image"]
            ),
            .blocked(reason: .cameraUnavailable)
        )
        XCTAssertEqual(
            ChatAttachmentCameraPermissionPolicy.state(
                isCameraAvailable: true,
                authorizationStatus: .denied,
                availableMediaTypes: ["public.image"]
            ),
            .blocked(reason: .permissionDenied)
        )
        XCTAssertEqual(
            ChatAttachmentCameraPermissionPolicy.state(
                isCameraAvailable: true,
                authorizationStatus: .restricted,
                availableMediaTypes: ["public.image"]
            ),
            .blocked(reason: .permissionRestricted)
        )
        XCTAssertEqual(
            ChatAttachmentCameraPermissionPolicy.state(
                isCameraAvailable: true,
                authorizationStatus: .authorized,
                availableMediaTypes: ["public.audio"]
            ),
            .blocked(reason: .unsupportedMediaTypes)
        )
    }

    func testImageCaptureBuildsPendingGalleryDraftWithStableCapturedIdentity() throws {
        let outputDirectory = try makeTemporaryDirectory()
        let builder = ChatAttachmentCameraCaptureDraftBuilder(
            outputDirectory: outputDirectory,
            uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
        let image = makeImage(size: CGSize(width: 24, height: 12))

        let draft = try builder.makeDraft(from: .image(image))

        XCTAssertEqual(draft.source, .gallery)
        XCTAssertEqual(draft.mediaKind, .image)
        XCTAssertEqual(draft.filename, "captured-image-00000000-0000-0000-0000-000000000001.jpg")
        XCTAssertGreaterThan(draft.byteSize, 0)
        XCTAssertEqual(draft.dimensions, CGSize(width: 24, height: 12))
        XCTAssertEqual(draft.duration, nil)
        XCTAssertEqual(draft.preparationState, .pending)
        XCTAssertTrue(draft.id.hasPrefix("captured:file://"))
        XCTAssertNotNil(AttachmentCapturedDraft.url(from: draft.id))
        XCTAssertEqual(draft.thumbnailState, .available(key: AttachmentCapturedDraft.url(from: draft.id)!.absoluteString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentCapturedDraft.url(from: draft.id)!.path))
    }

    func testVideoCaptureBuildsPendingGalleryDraftWithMetadataAndStableCapturedIdentity() throws {
        let outputDirectory = try makeTemporaryDirectory()
        let sourceVideoURL = outputDirectory.appendingPathComponent("source.mov")
        try Data([0, 1, 2, 3]).write(to: sourceVideoURL)
        let metadataProvider = FakeCameraVideoMetadataProvider(
            metadata: ChatAttachmentCameraVideoMetadata(
                duration: 13,
                dimensions: CGSize(width: 1920, height: 1080),
                thumbnailImage: makeImage(size: CGSize(width: 16, height: 9))
            )
        )
        let builder = ChatAttachmentCameraCaptureDraftBuilder(
            outputDirectory: outputDirectory.appendingPathComponent("captures", isDirectory: true),
            uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! },
            videoMetadataProvider: metadataProvider
        )

        let draft = try builder.makeDraft(from: .video(sourceVideoURL))

        XCTAssertEqual(draft.source, .gallery)
        XCTAssertEqual(draft.mediaKind, .video)
        XCTAssertEqual(draft.filename, "captured-video-00000000-0000-0000-0000-000000000002.mov")
        XCTAssertEqual(draft.byteSize, 4)
        XCTAssertEqual(draft.duration, 13)
        XCTAssertEqual(draft.dimensions, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(draft.preparationState, .pending)
        XCTAssertTrue(draft.id.hasPrefix("captured:file://"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentCapturedDraft.url(from: draft.id)!.path))
        if case .available(let key) = draft.thumbnailState {
            XCTAssertTrue(key.hasPrefix("file://"))
        } else {
            XCTFail("Expected generated video thumbnail key")
        }
    }

    func testEnabledCameraTilePresentsCamera() {
        let presenter = FakeCameraPresenter()
        let controller = makeGalleryController(cameraPresenter: presenter)

        controller.loadViewIfNeeded()
        controller.handleCameraTileTapped()

        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testNotDeterminedCameraDoesNotRequestAuthorizationOnSheetOpen() {
        let authorizer = FakeCameraAuthorizer(status: .notDetermined)
        let previewProvider = FakeTask10CameraPreviewProvider()
        let controller = makeGalleryController(
            cameraAuthorizer: authorizer,
            cameraPreviewProvider: previewProvider
        )

        controller.loadViewIfNeeded()

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(previewProvider.startCount, 0)
    }

    func testAuthorizedCameraPreviewStartsInCellAndStopsBeforeCapture() throws {
        let presenter = FakeCameraPresenter()
        let previewProvider = FakeTask10CameraPreviewProvider()
        let controller = makeGalleryController(
            cameraPresenter: presenter,
            cameraPreviewProvider: previewProvider
        )

        controller.loadViewIfNeeded()
        _ = try XCTUnwrap(controller.galleryCollectionView.dataSource)
            .collectionView(
                controller.galleryCollectionView,
                cellForItemAt: IndexPath(item: 0, section: 0)
            )

        XCTAssertEqual(previewProvider.startCount, 1)

        controller.handleCameraTileTapped()

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(previewProvider.stopCount, 1)
    }

    func testUnavailableDeniedAndRestrictedCameraTilesDoNotPresentCamera() {
        let unavailablePresenter = FakeCameraPresenter(isCameraAvailable: false)
        let deniedPresenter = FakeCameraPresenter()
        let restrictedPresenter = FakeCameraPresenter()
        let unavailable = makeGalleryController(cameraPresenter: unavailablePresenter)
        let denied = makeGalleryController(
            cameraAuthorizer: FakeCameraAuthorizer(status: .denied),
            cameraPresenter: deniedPresenter
        )
        let restricted = makeGalleryController(
            cameraAuthorizer: FakeCameraAuthorizer(status: .restricted),
            cameraPresenter: restrictedPresenter
        )

        [unavailable, denied, restricted].forEach { controller in
            controller.loadViewIfNeeded()
            controller.handleCameraTileTapped()
        }

        XCTAssertEqual(unavailablePresenter.presentCount, 0)
        XCTAssertEqual(deniedPresenter.presentCount, 0)
        XCTAssertEqual(restrictedPresenter.presentCount, 0)
    }

    func testNotDeterminedCameraTapRequestsAuthorizationAndPresentsOnlyWhenGranted() {
        let authorizer = FakeCameraAuthorizer(status: .notDetermined)
        authorizer.requestResult = .authorized
        let presenter = FakeCameraPresenter()
        let controller = makeGalleryController(
            cameraAuthorizer: authorizer,
            cameraPresenter: presenter
        )

        controller.loadViewIfNeeded()
        controller.handleCameraTileTapped()

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testCameraCancelDoesNotChangeSelectedDraftsOrSelectionCount() {
        let presenter = FakeCameraPresenter()
        let draftBuilder = FakeCameraDraftBuilder(draft: makeTask10CapturedDraft(filename: "capture.jpg"))
        let controller = makeGalleryController(
            cameraPresenter: presenter,
            cameraDraftBuilder: draftBuilder
        )
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.handleCameraTileTapped()
        presenter.complete(.cancelled)

        XCTAssertTrue(controller.selectedDrafts.isEmpty)
        XCTAssertTrue(selectionCounts.isEmpty)
    }

    func testSuccessfulCaptureAppendsSelectedCapturedItemAndUpdatesSelectionCount() {
        let presenter = FakeCameraPresenter()
        let capturedDraft = makeTask10CapturedDraft(filename: "capture.jpg")
        let draftBuilder = FakeCameraDraftBuilder(draft: capturedDraft)
        let controller = makeGalleryController(
            cameraPresenter: presenter,
            cameraDraftBuilder: draftBuilder
        )
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.handleCameraTileTapped()
        presenter.complete(.captured(.image(makeImage())))

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [capturedDraft.id])
        XCTAssertEqual(selectionCounts, [1])
        XCTAssertEqual(controller.galleryItems.first, .camera)
        XCTAssertEqual(controller.galleryItems.dropFirst().first, .captured(ChatAttachmentGalleryCapturedMedia(draft: capturedDraft)!))
    }

    func testCapturedMediaDoesNotExceedTenSelectedDraftLimit() {
        let presenter = FakeCameraPresenter()
        let capturedDraft = makeTask10CapturedDraft(filename: "overflow.jpg")
        let controller = makeGalleryController(
            cameraPresenter: presenter,
            cameraDraftBuilder: FakeCameraDraftBuilder(draft: capturedDraft)
        )
        let existingDrafts = (0..<10).map { makeTask10CapturedDraft(filename: "capture-\($0).jpg") }

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts(existingDrafts)
        controller.handleCameraTileTapped()
        presenter.complete(.captured(.image(makeImage())))

        XCTAssertEqual(controller.selectedDrafts.count, 10)
        XCTAssertFalse(controller.selectedDrafts.contains(capturedDraft))
    }

    func testPhotoLibraryRefreshPreservesCapturedDraftsWhilePruningInaccessibleAssetDrafts() {
        let authorizer = FakeTask10PhotoLibraryAuthorizer(status: .limited)
        authorizer.accessibleAssetLocalIdentifiers = ["asset-kept"]
        let dataProvider = FakeTask10GalleryDataProvider(assets: [makeAsset(localIdentifier: "asset-gone")])
        let capturedDraft = makeTask10CapturedDraft(filename: "capture.jpg")
        let controller = makeGalleryController(
            photoLibraryAuthorizer: authorizer,
            dataProvider: dataProvider
        )

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-kept"),
            makeAssetDraft(localIdentifier: "asset-gone"),
            capturedDraft,
            makeFileDraft()
        ])
        dataProvider.assets = [makeAsset(localIdentifier: "asset-kept")]
        controller.handlePhotoLibraryDidChange()

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-kept").id,
            capturedDraft.id,
            AttachmentFileDraft(url: URL(fileURLWithPath: "/tmp/document.pdf")).id
        ])
        XCTAssertEqual(controller.galleryItems, [
            .camera,
            .captured(ChatAttachmentGalleryCapturedMedia(draft: capturedDraft)!),
            .asset(makeAsset(localIdentifier: "asset-kept"))
        ])
    }

    func testAssetTapSelectsPendingGalleryDraft() {
        let presenter = FakeCameraPresenter()
        let controller = makeGalleryController(
            cameraPresenter: presenter,
            dataProvider: FakeTask10GalleryDataProvider(assets: [makeAsset(localIdentifier: "asset-1")])
        )

        controller.loadViewIfNeeded()
        controller.collectionView(
            controller.galleryCollectionView,
            didSelectItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-1").id
        ])
        XCTAssertEqual(presenter.presentCount, 0)
    }

    private func makeGalleryController(
        photoLibraryAuthorizer: FakeTask10PhotoLibraryAuthorizer = FakeTask10PhotoLibraryAuthorizer(status: .authorized),
        cameraAuthorizer: FakeCameraAuthorizer = FakeCameraAuthorizer(status: .authorized),
        cameraPresenter: FakeCameraPresenter = FakeCameraPresenter(),
        cameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding = FakeCameraDraftBuilder(draft: makeTask10CapturedDraft(filename: "capture.jpg")),
        cameraPreviewProvider: ChatAttachmentCameraPreviewProviding = FakeTask10CameraPreviewProvider(),
        dataProvider: FakeTask10GalleryDataProvider = FakeTask10GalleryDataProvider()
    ) -> ChatAttachmentGallerySourceViewController {
        ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: photoLibraryAuthorizer,
            limitedLibraryPresenter: FakeTask10LimitedLibraryPresenter(),
            settingsOpener: FakeTask10ApplicationSettingsOpener(),
            galleryDataProvider: dataProvider,
            thumbnailProvider: FakeTask10GalleryThumbnailProvider(),
            cameraAuthorizer: cameraAuthorizer,
            cameraPresenter: cameraPresenter,
            cameraDraftBuilder: cameraDraftBuilder,
            cameraPreviewProvider: cameraPreviewProvider
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-camera-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImage(size: CGSize = CGSize(width: 8, height: 8)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeAsset(
        localIdentifier: String,
        mediaKind: AttachmentMediaKind = .image,
        creationDate: Date? = Date(timeIntervalSince1970: 1),
        pixelSize: CGSize = CGSize(width: 120, height: 90),
        duration: TimeInterval? = nil
    ) -> ChatAttachmentGalleryAsset {
        ChatAttachmentGalleryAsset(
            localIdentifier: localIdentifier,
            mediaKind: mediaKind,
            creationDate: creationDate,
            pixelSize: pixelSize,
            duration: duration
        )
    }

    private func makeAssetDraft(localIdentifier: String) -> AttachmentDraft {
        AttachmentDraft(
            id: AttachmentAssetDraft(assetLocalIdentifier: localIdentifier).id,
            source: .gallery,
            mediaKind: .image,
            thumbnailState: .none,
            filename: "\(localIdentifier).jpg",
            byteSize: 1,
            duration: nil,
            dimensions: nil,
            preparationState: .pending
        )
    }

    private func makeFileDraft() -> AttachmentDraft {
        AttachmentDraft(
            id: AttachmentFileDraft(url: URL(fileURLWithPath: "/tmp/document.pdf")).id,
            source: .file,
            mediaKind: .file,
            thumbnailState: .none,
            filename: "document.pdf",
            byteSize: 1,
            duration: nil,
            dimensions: nil,
            preparationState: .pending
        )
    }
}

private func makeTask10CapturedDraft(filename: String) -> AttachmentDraft {
    let url = URL(fileURLWithPath: "/tmp/\(filename)")
    return AttachmentDraft(
        id: AttachmentCapturedDraft(url: url).id,
        source: .gallery,
        mediaKind: filename.hasSuffix(".mov") ? .video : .image,
        thumbnailState: .available(key: url.absoluteString),
        filename: filename,
        byteSize: 1,
        duration: nil,
        dimensions: CGSize(width: 8, height: 8),
        preparationState: .pending
    )
}

private final class FakeCameraAuthorizer: ChatAttachmentCameraAuthorizing {
    var authorizationStatus: ChatAttachmentCameraAuthorizationStatus
    var requestResult: ChatAttachmentCameraAuthorizationStatus
    private(set) var requestCount = 0

    init(status: ChatAttachmentCameraAuthorizationStatus) {
        self.authorizationStatus = status
        self.requestResult = status
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentCameraAuthorizationStatus) -> Void) {
        requestCount += 1
        authorizationStatus = requestResult
        completion(requestResult)
    }
}

private final class FakeCameraPresenter: ChatAttachmentCameraPresenting {
    var isCameraAvailable: Bool
    var availableMediaTypes: [String]
    private(set) var presentCount = 0
    private var completion: ((ChatAttachmentCameraPresentingResult) -> Void)?

    init(
        isCameraAvailable: Bool = true,
        availableMediaTypes: [String] = ["public.image", "public.movie"]
    ) {
        self.isCameraAvailable = isCameraAvailable
        self.availableMediaTypes = availableMediaTypes
    }

    func presentCamera(
        from viewController: UIViewController,
        completion: @escaping (ChatAttachmentCameraPresentingResult) -> Void
    ) {
        presentCount += 1
        self.completion = completion
    }

    func complete(_ result: ChatAttachmentCameraPresentingResult) {
        completion?(result)
        completion = nil
    }
}

private final class FakeCameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding {
    let draft: AttachmentDraft
    private(set) var removedDraftIDs: [String] = []

    init(draft: AttachmentDraft) {
        self.draft = draft
    }

    func makeDraft(from capture: ChatAttachmentCameraCapture) throws -> AttachmentDraft {
        draft
    }

    func removeTemporaryFiles(for draft: AttachmentDraft) {
        removedDraftIDs.append(draft.id)
    }
}

private final class FakeTask10CameraPreviewProvider: ChatAttachmentCameraPreviewProviding {
    private let startResult: ChatAttachmentCameraPreviewStartResult
    private(set) var isPreviewRunning = false
    private(set) var startCount = 0
    private(set) var detachCount = 0
    private(set) var stopCount = 0

    init(startResult: ChatAttachmentCameraPreviewStartResult = .started) {
        self.startResult = startResult
    }

    func startPreview(
        in view: UIView,
        completion: @escaping (ChatAttachmentCameraPreviewStartResult) -> Void
    ) {
        startCount += 1
        isPreviewRunning = startResult == .started
        completion(startResult)
    }

    func detachPreview(from view: UIView) {
        detachCount += 1
    }

    func stopPreview() {
        stopCount += 1
        isPreviewRunning = false
    }
}

private final class FakeCameraVideoMetadataProvider: ChatAttachmentCameraVideoMetadataProviding {
    let metadata: ChatAttachmentCameraVideoMetadata

    init(metadata: ChatAttachmentCameraVideoMetadata) {
        self.metadata = metadata
    }

    func metadata(forVideoAt url: URL) throws -> ChatAttachmentCameraVideoMetadata {
        metadata
    }
}

private final class FakeTask10PhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
    var authorizationStatus: ChatAttachmentPhotosAuthorizationStatus
    var accessibleAssetLocalIdentifiers: Set<String> = []

    init(status: ChatAttachmentPhotosAuthorizationStatus) {
        self.authorizationStatus = status
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentPhotosAuthorizationStatus) -> Void) {
        completion(authorizationStatus)
    }

    func registerChangeObserver(_ observer: AnyObject) {}
    func unregisterChangeObserver(_ observer: AnyObject) {}

    func containsAsset(localIdentifier: String) -> Bool {
        accessibleAssetLocalIdentifiers.contains(localIdentifier)
    }
}

private final class FakeTask10LimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    func presentLimitedLibraryPicker(from viewController: UIViewController) {}
}

private final class FakeTask10ApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {}
}

private final class FakeTask10GalleryDataProvider: ChatAttachmentGalleryDataProviding {
    var assets: [ChatAttachmentGalleryAsset]

    init(assets: [ChatAttachmentGalleryAsset] = []) {
        self.assets = assets
    }

    func fetchAssets() -> [ChatAttachmentGalleryAsset] {
        assets
    }
}

private final class FakeTask10GalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
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
