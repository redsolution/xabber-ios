import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentGalleryGridTests: XCTestCase {
    func testItemPolicyFiltersImageAndVideoAssetsSortsDescendingAndPrependsCamera() {
        let olderImage = makeAsset(localIdentifier: "asset-c", mediaKind: .image, creationDate: Date(timeIntervalSince1970: 10))
        let newestVideo = makeAsset(localIdentifier: "asset-b", mediaKind: .video, creationDate: Date(timeIntervalSince1970: 20))
        let tiedImage = makeAsset(localIdentifier: "asset-a", mediaKind: .image, creationDate: Date(timeIntervalSince1970: 20))
        let unsupportedFile = makeAsset(localIdentifier: "asset-file", mediaKind: .file, creationDate: Date(timeIntervalSince1970: 30))

        let items = ChatAttachmentGalleryItemPolicy.items(from: [
            olderImage,
            newestVideo,
            tiedImage,
            unsupportedFile
        ])

        XCTAssertEqual(items, [
            .camera,
            .asset(tiedImage),
            .asset(newestVideo),
            .asset(olderImage)
        ])
    }

    func testItemPolicyPlacesCapturedDraftsAfterCameraBeforePhotoKitAssets() {
        let capturedDraft = makeCapturedDraft(filename: "capture.jpg")
        let asset = makeAsset(localIdentifier: "asset-1")

        let items = ChatAttachmentGalleryItemPolicy.items(
            from: [asset],
            capturedDrafts: [capturedDraft]
        )

        XCTAssertEqual(items, [
            .camera,
            .captured(ChatAttachmentGalleryCapturedMedia(draft: capturedDraft)!),
            .asset(asset)
        ])
    }

    func testItemPolicyReturnsCameraOnlyWhenThereAreNoAssets() {
        XCTAssertEqual(ChatAttachmentGalleryItemPolicy.items(from: []), [.camera])
    }

    func testSectionPolicyPlacesCameraAndFirstFourItemsInFeaturedSection() {
        let assets = (1...6).map { makeAsset(localIdentifier: "asset-\($0)") }
        let items = ChatAttachmentGalleryItemPolicy.items(from: assets)
        let sections = ChatAttachmentGallerySectionPolicy.sectionedItems(from: items)

        XCTAssertEqual(sections[0], Array(items.prefix(5)))
        XCTAssertEqual(sections[1], Array(items.dropFirst(5)))
        XCTAssertEqual(
            ChatAttachmentGallerySectionPolicy.item(at: IndexPath(item: 0, section: 0), in: items),
            .camera
        )
        XCTAssertEqual(
            ChatAttachmentGallerySectionPolicy.item(at: IndexPath(item: 0, section: 1), in: items),
            items[5]
        )
        XCTAssertEqual(
            ChatAttachmentGallerySectionPolicy.globalIndex(for: IndexPath(item: 0, section: 1), in: items),
            5
        )
    }

    func testCellStatePolicyBuildsDisabledCameraState() {
        let state = ChatAttachmentGalleryCellStatePolicy.state(for: .camera)

        XCTAssertEqual(state.thumbnailState, .cameraDisabled)
        XCTAssertEqual(state.selectionOrder, nil)
        XCTAssertEqual(state.selectionIndicatorState, .hidden)
        XCTAssertEqual(state.videoDurationLabel, nil)
        XCTAssertFalse(state.isCameraEnabled)
    }

    func testCellStatePolicyBuildsEnabledCameraState() {
        let state = ChatAttachmentGalleryCellStatePolicy.state(for: .camera, isCameraEnabled: true)

        XCTAssertEqual(state.thumbnailState, .camera)
        XCTAssertEqual(state.selectionOrder, nil)
        XCTAssertEqual(state.selectionIndicatorState, .hidden)
        XCTAssertEqual(state.videoDurationLabel, nil)
        XCTAssertTrue(state.isCameraEnabled)
    }

    func testCellStatePolicyBuildsCapturedVideoStateWithSelectionOrderAndDurationBadge() {
        let capturedDraft = makeCapturedDraft(filename: "capture.mov", duration: 126)
        let capturedMedia = ChatAttachmentGalleryCapturedMedia(draft: capturedDraft)!

        let state = ChatAttachmentGalleryCellStatePolicy.state(
            for: .captured(capturedMedia),
            thumbnailState: .image,
            selectionOrder: 2
        )

        XCTAssertEqual(state.thumbnailState, .image)
        XCTAssertEqual(state.selectionOrder, 2)
        XCTAssertEqual(state.selectionIndicatorState, .selected(order: 2))
        XCTAssertEqual(state.videoDurationLabel, "2:06")
        XCTAssertTrue(state.isCameraEnabled)
    }

    func testCellStatePolicyBuildsSelectedVideoLoadingStateWithDurationBadge() {
        let video = makeAsset(
            localIdentifier: "video-1",
            mediaKind: .video,
            duration: 65
        )

        let state = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(video),
            thumbnailState: .loading,
            selectionOrder: 3
        )

        XCTAssertEqual(state.thumbnailState, .loading)
        XCTAssertEqual(state.selectionOrder, 3)
        XCTAssertEqual(state.selectionIndicatorState, .selected(order: 3))
        XCTAssertEqual(state.videoDurationLabel, "1:05")
        XCTAssertTrue(state.isCameraEnabled)
    }

    func testCellStatePolicyBuildsUnselectedAndMaxCountBlockedSelectionStates() {
        let image = makeAsset(localIdentifier: "image-1", mediaKind: .image)

        let unselectedState = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(image),
            thumbnailState: .image
        )
        let blockedState = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(image),
            thumbnailState: .image,
            isSelectionBlocked: true
        )

        XCTAssertEqual(unselectedState.selectionOrder, nil)
        XCTAssertEqual(unselectedState.selectionIndicatorState, .available)
        XCTAssertEqual(blockedState.selectionOrder, nil)
        XCTAssertEqual(blockedState.selectionIndicatorState, .blocked)
    }

    func testCellStatePolicyPreservesCloudAndFailureStates() {
        let image = makeAsset(localIdentifier: "image-1", mediaKind: .image)

        let cloudState = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(image),
            thumbnailState: .iCloud,
            selectionOrder: nil
        )
        let failedState = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(image),
            thumbnailState: .failed,
            selectionOrder: nil
        )

        XCTAssertEqual(cloudState.thumbnailState, .iCloud)
        XCTAssertEqual(cloudState.selectionIndicatorState, .available)
        XCTAssertEqual(failedState.thumbnailState, .failed)
        XCTAssertEqual(failedState.selectionIndicatorState, .available)
    }

    func testCellPrepareForReuseCancelsThumbnailRequest() {
        let cell = ChatAttachmentGalleryCollectionViewCell(frame: .zero)
        var cancelCount = 0
        cell.onPrepareForReuse = {
            cancelCount += 1
        }

        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .camera),
            image: nil
        )
        cell.prepareForReuse()

        XCTAssertEqual(cancelCount, 1)
        XCTAssertNil(cell.representedItem)
    }

    func testEnabledCameraCellDetachesPreviewProviderOnReuseWithoutStoppingSession() {
        let cell = ChatAttachmentGalleryCollectionViewCell(frame: .zero)
        let previewProvider = FakeGalleryCameraPreviewProvider(startResult: .started)

        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .camera, isCameraEnabled: true),
            image: nil,
            cameraPreviewProvider: previewProvider
        )

        XCTAssertEqual(previewProvider.startCount, 1)
        XCTAssertFalse(cell.cameraPreviewContainerView.isHidden)

        cell.prepareForReuse()

        XCTAssertEqual(previewProvider.detachCount, 1)
        XCTAssertEqual(previewProvider.stopCount, 0)
        XCTAssertTrue(cell.cameraPreviewContainerView.isHidden)
    }

    func testCameraCellReuseCanStartPreviewAgainWithoutStoppingSharedProvider() {
        let cell = ChatAttachmentGalleryCollectionViewCell(frame: .zero)
        let previewProvider = FakeGalleryCameraPreviewProvider(startResult: .started)
        let asset = makeAsset(localIdentifier: "asset-after-camera")

        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .camera, isCameraEnabled: true),
            image: nil,
            cameraPreviewProvider: previewProvider
        )
        cell.prepareForReuse()
        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .asset(asset), thumbnailState: .image),
            image: UIImage()
        )
        cell.prepareForReuse()
        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .camera, isCameraEnabled: true),
            image: nil,
            cameraPreviewProvider: previewProvider
        )

        XCTAssertEqual(previewProvider.startCount, 2)
        XCTAssertEqual(previewProvider.detachCount, 1)
        XCTAssertEqual(previewProvider.stopCount, 0)
        XCTAssertFalse(cell.cameraPreviewContainerView.isHidden)
        XCTAssertTrue(cell.cameraImageView.isHidden)
    }

    func testEnabledCameraCellFallsBackWhenPreviewProviderFails() {
        let cell = ChatAttachmentGalleryCollectionViewCell(frame: .zero)
        let previewProvider = FakeGalleryCameraPreviewProvider(startResult: .failed)

        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .camera, isCameraEnabled: true),
            image: nil,
            cameraPreviewProvider: previewProvider
        )

        XCTAssertEqual(previewProvider.startCount, 1)
        XCTAssertTrue(cell.cameraPreviewContainerView.isHidden)
        XCTAssertFalse(cell.cameraImageView.isHidden)
    }

    func testAuthorizedControllerLoadsGridAndHidesPermissionControls() {
        let firstAsset = makeAsset(localIdentifier: "asset-1", creationDate: Date(timeIntervalSince1970: 2))
        let secondAsset = makeAsset(localIdentifier: "asset-2", creationDate: Date(timeIntervalSince1970: 1))
        let controller = makeGalleryController(
            authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeGalleryDataProvider(assets: [secondAsset, firstAsset])
        )

        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.galleryCollectionView.isHidden)
        XCTAssertTrue(controller.allowAccessButton.isHidden)
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertTrue(controller.openSettingsButton.isHidden)
        XCTAssertTrue(controller.emptyGalleryLabel.isHidden)
        XCTAssertEqual(controller.galleryItems, [.camera, .asset(firstAsset), .asset(secondAsset)])
    }

    func testInitialPhotoEnumerationDoesNotBlockPickerPresentation() {
        let fetchFinished = expectation(description: "photo enumeration finished")
        let dataProvider = SlowGalleryDataProvider(fetchFinished: fetchFinished)
        let controller = ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: FakeGalleryPhotoLibraryAuthorizer(status: .authorized),
            limitedLibraryPresenter: FakeGalleryLimitedLibraryPresenter(),
            settingsOpener: FakeGalleryApplicationSettingsOpener(),
            galleryDataProvider: dataProvider,
            thumbnailProvider: FakeGalleryThumbnailProvider(),
            loadsGalleryAsynchronously: true
        )

        let startedAt = Date()
        controller.loadViewIfNeeded()

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertTrue(controller.galleryItems.isEmpty)
        wait(for: [fetchFinished], timeout: 1)
    }

    func testLimitedControllerLoadsGridWithoutFullTopBarAction() {
        let asset = makeAsset(localIdentifier: "limited-asset")
        let controller = makeGalleryController(
            authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .limited),
            dataProvider: FakeGalleryDataProvider(assets: [asset])
        )

        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.galleryCollectionView.isHidden)
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertNil(controller.fullGalleryActionMenuButton.superview)
        XCTAssertTrue(controller.fullGalleryActionMenuButton.isHidden)
        XCTAssertTrue(controller.emptyGalleryLabel.isHidden)
        XCTAssertEqual(controller.galleryItems, [.camera, .asset(asset)])
    }

    func testReadyControllerShowsEmptyStateWhenOnlyDisabledCameraTileExists() {
        let controller = makeGalleryController(
            authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeGalleryDataProvider(assets: [])
        )

        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.galleryCollectionView.isHidden)
        XCTAssertFalse(controller.emptyGalleryLabel.isHidden)
        XCTAssertEqual(controller.galleryItems, [.camera])
    }

    func testBlockedAndRequestPermissionStatesKeepGridHidden() {
        let denied = makeGalleryController(authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .denied))
        let notDetermined = makeGalleryController(authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .notDetermined))

        denied.loadViewIfNeeded()
        notDetermined.loadViewIfNeeded()

        XCTAssertTrue(denied.galleryCollectionView.isHidden)
        XCTAssertTrue(notDetermined.galleryCollectionView.isHidden)
        XCTAssertFalse(denied.openSettingsButton.isHidden)
        XCTAssertFalse(notDetermined.allowAccessButton.isHidden)
    }

    func testSelectingVisibleAssetUpdatesSelectionOverlayWithoutThumbnailRerequest() throws {
        let assets = (1...3).map { makeAsset(localIdentifier: "asset-\($0)") }
        let thumbnailProvider = FakeGalleryThumbnailProvider()
        let controller = makeGalleryController(
            authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeGalleryDataProvider(assets: assets),
            thumbnailProvider: thumbnailProvider
        )
        let window = showGalleryController(controller)
        _ = window
        let firstAssetIndexPath = IndexPath(item: 1, section: 0)
        let cell = try visibleGalleryCell(in: controller, at: firstAssetIndexPath)
        let requestedAssetIDsBeforeSelection = thumbnailProvider.requestedAssetIDs

        controller.collectionView(controller.galleryCollectionView, didSelectItemAt: firstAssetIndexPath)
        controller.galleryCollectionView.layoutIfNeeded()

        XCTAssertEqual(thumbnailProvider.requestedAssetIDs, requestedAssetIDsBeforeSelection)
        XCTAssertTrue(cell.thumbnailImageView.image == nil || cell.loadingView.isAnimating)
        XCTAssertTrue(cell.selectionRingView.isHidden)
        XCTAssertFalse(cell.selectionBadgeLabel.isHidden)
        XCTAssertEqual(cell.selectionBadgeLabel.text, "1")
    }

    func testDeselectingMiddleVisibleAssetRenumbersBadgesWithoutThumbnailRerequest() throws {
        let assets = (1...4).map { makeAsset(localIdentifier: "asset-\($0)") }
        let thumbnailProvider = FakeGalleryThumbnailProvider()
        let controller = makeGalleryController(
            authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeGalleryDataProvider(assets: assets),
            thumbnailProvider: thumbnailProvider
        )
        let window = showGalleryController(controller)
        _ = window
        controller.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-1"),
            makeAssetDraft(localIdentifier: "asset-2"),
            makeAssetDraft(localIdentifier: "asset-3")
        ])
        controller.galleryCollectionView.layoutIfNeeded()
        let secondAssetIndexPath = IndexPath(item: 2, section: 0)
        let thirdAssetIndexPath = IndexPath(item: 3, section: 0)
        _ = try visibleGalleryCell(in: controller, at: secondAssetIndexPath)
        let thirdCell = try visibleGalleryCell(in: controller, at: thirdAssetIndexPath)
        let requestedAssetIDsBeforeDeselection = thumbnailProvider.requestedAssetIDs

        controller.collectionView(controller.galleryCollectionView, didSelectItemAt: secondAssetIndexPath)
        controller.galleryCollectionView.layoutIfNeeded()

        XCTAssertEqual(thumbnailProvider.requestedAssetIDs, requestedAssetIDsBeforeDeselection)
        XCTAssertFalse(thirdCell.selectionBadgeLabel.isHidden)
        XCTAssertEqual(thirdCell.selectionBadgeLabel.text, "2")
    }

    func testLeavingMaximumSelectionCountRefreshesVisibleBlockedStateWithoutThumbnailRerequest() throws {
        let assets = (1...3).map { makeAsset(localIdentifier: "asset-\($0)") }
        let thumbnailProvider = FakeGalleryThumbnailProvider()
        let controller = makeGalleryController(
            authorizer: FakeGalleryPhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeGalleryDataProvider(assets: assets),
            thumbnailProvider: thumbnailProvider,
            maximumSelectedDraftCount: 2
        )
        let window = showGalleryController(controller)
        _ = window
        controller.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-1"),
            makeAssetDraft(localIdentifier: "asset-2")
        ])
        controller.galleryCollectionView.layoutIfNeeded()
        let firstAssetIndexPath = IndexPath(item: 1, section: 0)
        let thirdAssetIndexPath = IndexPath(item: 3, section: 0)
        let thirdCell = try visibleGalleryCell(in: controller, at: thirdAssetIndexPath)
        XCTAssertFalse(thirdCell.selectionBlockedView.isHidden)
        let requestedAssetIDsBeforeDeselection = thumbnailProvider.requestedAssetIDs

        controller.collectionView(controller.galleryCollectionView, didSelectItemAt: firstAssetIndexPath)
        controller.galleryCollectionView.layoutIfNeeded()

        XCTAssertEqual(thumbnailProvider.requestedAssetIDs, requestedAssetIDsBeforeDeselection)
        XCTAssertTrue(thirdCell.selectionBlockedView.isHidden)
        XCTAssertFalse(thirdCell.selectionRingView.isHidden)
    }

    func testCellSelectionIndicatorUpdatePreservesThumbnailAndRebuildsAccessibility() {
        let cell = ChatAttachmentGalleryCollectionViewCell(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        let image = UIImage()
        let asset = makeAsset(localIdentifier: "asset-1")
        cell.configure(
            state: ChatAttachmentGalleryCellStatePolicy.state(for: .asset(asset), thumbnailState: .image),
            image: image
        )

        cell.updateSelectionIndicator(.selected(order: 2))

        XCTAssertTrue(cell.thumbnailImageView.image === image)
        XCTAssertFalse(cell.selectionBadgeLabel.isHidden)
        XCTAssertEqual(cell.selectionBadgeLabel.text, "2")
        XCTAssertEqual(
            cell.accessibilityValue,
            ChatAttachmentLocalization.string(.accessibilitySelectedOrder, arguments: ["2"])
        )

        cell.updateSelectionIndicator(.available)

        XCTAssertTrue(cell.thumbnailImageView.image === image)
        XCTAssertTrue(cell.selectionBadgeLabel.isHidden)
        XCTAssertFalse(cell.selectionRingView.isHidden)
        XCTAssertEqual(cell.accessibilityValue, ChatAttachmentLocalization.string(.accessibilityNotSelected))
        XCTAssertFalse(cell.accessibilityLabel?.contains("2") == true)
    }

    func testPhotoLibraryChangeRefreshesAssetsAndPrunesOnlyInaccessibleGalleryDrafts() {
        let authorizer = FakeGalleryPhotoLibraryAuthorizer(status: .limited)
        authorizer.accessibleAssetLocalIdentifiers = ["asset-kept"]
        let dataProvider = FakeGalleryDataProvider(assets: [
            makeAsset(localIdentifier: "asset-gone")
        ])
        let controller = makeGalleryController(
            authorizer: authorizer,
            dataProvider: dataProvider
        )
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-kept"),
            makeAssetDraft(localIdentifier: "asset-gone"),
            makeFileDraft()
        ])
        dataProvider.assets = [
            makeAsset(localIdentifier: "asset-kept")
        ]

        controller.handlePhotoLibraryDidChange()

        XCTAssertEqual(controller.galleryItems, [.camera, .asset(makeAsset(localIdentifier: "asset-kept"))])
        XCTAssertEqual(controller.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-kept").id,
            AttachmentFileDraft(url: URL(fileURLWithPath: "/tmp/document.pdf")).id
        ])
        XCTAssertEqual(selectionCounts, [3, 2])
    }

    private func makeGalleryController(
        authorizer: FakeGalleryPhotoLibraryAuthorizer,
        dataProvider: FakeGalleryDataProvider = FakeGalleryDataProvider(),
        thumbnailProvider: FakeGalleryThumbnailProvider = FakeGalleryThumbnailProvider(),
        maximumSelectedDraftCount: Int = 10
    ) -> ChatAttachmentGallerySourceViewController {
        ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: authorizer,
            limitedLibraryPresenter: FakeGalleryLimitedLibraryPresenter(),
            settingsOpener: FakeGalleryApplicationSettingsOpener(),
            galleryDataProvider: dataProvider,
            thumbnailProvider: thumbnailProvider,
            maximumSelectedDraftCount: maximumSelectedDraftCount
        )
    }

    private func showGalleryController(
        _ controller: ChatAttachmentGallerySourceViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        controller.galleryCollectionView.layoutIfNeeded()
        XCTAssertFalse(controller.galleryCollectionView.visibleCells.isEmpty, file: file, line: line)
        return window
    }

    private func visibleGalleryCell(
        in controller: ChatAttachmentGallerySourceViewController,
        at indexPath: IndexPath,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatAttachmentGalleryCollectionViewCell {
        controller.galleryCollectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        controller.galleryCollectionView.layoutIfNeeded()
        return try XCTUnwrap(
            controller.galleryCollectionView.cellForItem(at: indexPath) as? ChatAttachmentGalleryCollectionViewCell,
            file: file,
            line: line
        )
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

    private func makeCapturedDraft(filename: String, duration: Int? = nil) -> AttachmentDraft {
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        let mediaKind: AttachmentMediaKind = filename.hasSuffix(".mov") ? .video : .image
        return AttachmentDraft(
            id: AttachmentCapturedDraft(url: url).id,
            source: .gallery,
            mediaKind: mediaKind,
            thumbnailState: .available(key: url.absoluteString),
            filename: filename,
            byteSize: 1,
            duration: duration,
            dimensions: CGSize(width: 8, height: 8),
            preparationState: .pending
        )
    }
}

private final class SlowGalleryDataProvider: ChatAttachmentGalleryDataProviding {
    private let fetchFinished: XCTestExpectation

    init(fetchFinished: XCTestExpectation) {
        self.fetchFinished = fetchFinished
    }

    func fetchAssets() -> [ChatAttachmentGalleryAsset] {
        Thread.sleep(forTimeInterval: 0.25)
        fetchFinished.fulfill()
        return []
    }
}

private final class FakeGalleryPhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
    var authorizationStatus: ChatAttachmentPhotosAuthorizationStatus
    var requestResult: ChatAttachmentPhotosAuthorizationStatus
    var accessibleAssetLocalIdentifiers: Set<String> = []

    init(status: ChatAttachmentPhotosAuthorizationStatus) {
        self.authorizationStatus = status
        self.requestResult = status
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentPhotosAuthorizationStatus) -> Void) {
        authorizationStatus = requestResult
        completion(requestResult)
    }

    func registerChangeObserver(_ observer: AnyObject) {}
    func unregisterChangeObserver(_ observer: AnyObject) {}

    func containsAsset(localIdentifier: String) -> Bool {
        accessibleAssetLocalIdentifiers.contains(localIdentifier)
    }
}

private final class FakeGalleryLimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    func presentLimitedLibraryPicker(from viewController: UIViewController) {}
}

private final class FakeGalleryApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {}
}

private final class FakeGalleryDataProvider: ChatAttachmentGalleryDataProviding {
    var assets: [ChatAttachmentGalleryAsset]

    init(assets: [ChatAttachmentGalleryAsset] = []) {
        self.assets = assets
    }

    func fetchAssets() -> [ChatAttachmentGalleryAsset] {
        assets
    }
}

private final class FakeGalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
    private(set) var cancelledRequestIDs: [Int] = []
    private(set) var cachedAssetIDs: [String] = []
    private(set) var stoppedCachingAssetIDs: [String] = []
    private(set) var requestedAssetIDs: [String] = []
    private var nextRequestID = 1

    func requestThumbnail(
        for asset: ChatAttachmentGalleryAsset,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentGalleryThumbnailResult) -> Void
    ) -> Int {
        requestedAssetIDs.append(asset.localIdentifier)
        defer {
            nextRequestID += 1
        }
        return nextRequestID
    }

    func cancelThumbnailRequest(_ requestID: Int) {
        cancelledRequestIDs.append(requestID)
    }

    func startCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {
        cachedAssetIDs.append(contentsOf: assets.map(\.localIdentifier))
    }

    func stopCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {
        stoppedCachingAssetIDs.append(contentsOf: assets.map(\.localIdentifier))
    }
}

private final class FakeGalleryCameraPreviewProvider: ChatAttachmentCameraPreviewProviding {
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
