import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentOrderedSelectionTests: XCTestCase {
    func testSelectionPolicySelectsDraftsInTapOrder() {
        let policy = ChatAttachmentSelectionPolicy(maximumSelectedCount: 10)
        let first = makeAssetDraft(localIdentifier: "asset-1")
        let second = makeAssetDraft(localIdentifier: "asset-2")

        let firstResult = policy.toggle(draft: first, in: [])
        let secondResult = policy.toggle(draft: second, in: firstResult.drafts)

        XCTAssertEqual(secondResult.drafts.map(\.id), [first.id, second.id])
        XCTAssertEqual(secondResult, .selected([first, second]))
    }

    func testSelectionPolicyDeselectsAndRenumbersRemainingDraftsByArrayOrder() {
        let policy = ChatAttachmentSelectionPolicy(maximumSelectedCount: 10)
        let first = makeAssetDraft(localIdentifier: "asset-1")
        let second = makeAssetDraft(localIdentifier: "asset-2")
        let third = makeAssetDraft(localIdentifier: "asset-3")

        let result = policy.toggle(draft: second, in: [first, second, third])

        XCTAssertEqual(result, .deselected([first, third]))
        XCTAssertEqual(result.drafts.map(\.id), [first.id, third.id])
    }

    func testSelectionPolicyBlocksEleventhUnselectedDraft() {
        let policy = ChatAttachmentSelectionPolicy(maximumSelectedCount: 10)
        let selected = (0..<10).map { makeAssetDraft(localIdentifier: "asset-\($0)") }
        let eleventh = makeAssetDraft(localIdentifier: "asset-10")

        let result = policy.toggle(draft: eleventh, in: selected)

        XCTAssertEqual(
            result,
            .blocked(reason: .maximumSelectionCountReached, drafts: selected)
        )
    }

    func testSelectionPolicyAllowsDeselectWhileAtLimit() {
        let policy = ChatAttachmentSelectionPolicy(maximumSelectedCount: 10)
        let selected = (0..<10).map { makeAssetDraft(localIdentifier: "asset-\($0)") }

        let result = policy.toggle(draft: selected[4], in: selected)

        XCTAssertEqual(result.drafts.count, 9)
        XCTAssertFalse(result.drafts.contains(selected[4]))
    }

    func testSelectionPolicyPreservesMixedDraftOrder() {
        let policy = ChatAttachmentSelectionPolicy(maximumSelectedCount: 10)
        let asset = makeAssetDraft(localIdentifier: "asset-1")
        let captured = makeCapturedDraft(filename: "capture.jpg")
        let file = makeFileDraft()
        let nextAsset = makeAssetDraft(localIdentifier: "asset-2")

        let result = policy.toggle(draft: nextAsset, in: [asset, captured, file])

        XCTAssertEqual(result.drafts.map(\.id), [
            asset.id,
            captured.id,
            file.id,
            nextAsset.id
        ])
    }

    func testGalleryDraftBuilderCreatesPendingDraftFromPhotoKitAsset() {
        let asset = makeAsset(
            localIdentifier: "asset-1",
            mediaKind: .video,
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 65
        )

        let draft = ChatAttachmentGalleryDraftBuilder().makeDraft(from: asset)

        XCTAssertEqual(draft.id, AttachmentAssetDraft(assetLocalIdentifier: "asset-1").id)
        XCTAssertEqual(draft.source, .gallery)
        XCTAssertEqual(draft.mediaKind, .video)
        XCTAssertEqual(draft.filename, "asset-1.mov")
        XCTAssertEqual(draft.byteSize, 0)
        XCTAssertEqual(draft.duration, 65)
        XCTAssertEqual(draft.dimensions, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(draft.thumbnailState, .none)
        XCTAssertEqual(draft.preparationState, .pending)
    }

    func testAssetTapCreatesPendingGalleryDraftAndUpdatesSelectionCount() {
        let asset = makeAsset(localIdentifier: "asset-1")
        let controller = makeGalleryController(dataProvider: FakeTask11GalleryDataProvider(assets: [asset]))
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.collectionView(
            controller.galleryCollectionView,
            didSelectItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-1").id
        ])
        XCTAssertEqual(selectionCounts, [1])
    }

    func testTappingSelectedAssetDeselectsAndRenumbersRemainingDrafts() {
        let firstAsset = makeAsset(localIdentifier: "asset-1")
        let secondAsset = makeAsset(localIdentifier: "asset-2")
        let controller = makeGalleryController(
            dataProvider: FakeTask11GalleryDataProvider(assets: [firstAsset, secondAsset])
        )
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.collectionView(controller.galleryCollectionView, didSelectItemAt: IndexPath(item: 1, section: 0))
        controller.collectionView(controller.galleryCollectionView, didSelectItemAt: IndexPath(item: 2, section: 0))
        controller.collectionView(controller.galleryCollectionView, didSelectItemAt: IndexPath(item: 1, section: 0))

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-2").id
        ])
        XCTAssertEqual(selectionCounts, [1, 2, 1])
        XCTAssertEqual(controller.gallerySelectionOrder(forAssetLocalIdentifier: "asset-2"), 1)
    }

    func testTappingCapturedItemRemovesDraftAndTemporaryFile() {
        let capturedDraft = makeCapturedDraft(filename: "capture.jpg")
        let draftBuilder = FakeTask11CameraDraftBuilder(draft: capturedDraft)
        let controller = makeGalleryController(cameraDraftBuilder: draftBuilder)
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts([capturedDraft])
        controller.collectionView(
            controller.galleryCollectionView,
            didSelectItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertTrue(controller.selectedDrafts.isEmpty)
        XCTAssertEqual(selectionCounts, [1, 0])
        XCTAssertEqual(draftBuilder.removedDraftIDs, [capturedDraft.id])
        XCTAssertEqual(controller.galleryItems, [.camera])
    }

    func testMaxCountBlockDoesNotMutateSelectionOrCount() {
        let asset = makeAsset(localIdentifier: "asset-10")
        let controller = makeGalleryController(dataProvider: FakeTask11GalleryDataProvider(assets: [asset]))
        let selected = (0..<10).map { makeAssetDraft(localIdentifier: "asset-\($0)") }
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts(selected)
        controller.collectionView(
            controller.galleryCollectionView,
            didSelectItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertEqual(controller.selectedDrafts, selected)
        XCTAssertEqual(selectionCounts, [10])
    }

    func testPhotoLibraryRefreshPreservesCapturedAndFileDraftsWhilePruningAssets() {
        let authorizer = FakeTask11PhotoLibraryAuthorizer(status: .limited)
        authorizer.accessibleAssetLocalIdentifiers = ["asset-kept"]
        let dataProvider = FakeTask11GalleryDataProvider(assets: [
            makeAsset(localIdentifier: "asset-gone")
        ])
        let captured = makeCapturedDraft(filename: "capture.jpg")
        let file = makeFileDraft()
        let controller = makeGalleryController(
            photoLibraryAuthorizer: authorizer,
            dataProvider: dataProvider
        )

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-kept"),
            makeAssetDraft(localIdentifier: "asset-gone"),
            captured,
            file
        ])
        dataProvider.assets = [makeAsset(localIdentifier: "asset-kept")]
        controller.handlePhotoLibraryDidChange()

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-kept").id,
            captured.id,
            file.id
        ])
        XCTAssertEqual(controller.gallerySelectionOrder(forAssetLocalIdentifier: "asset-kept"), 1)
    }

    func testSelectedOverlaysSurviveFullscreenPresentationStateCallbacks() {
        let asset = makeAsset(localIdentifier: "asset-1")
        let gallery = makeGalleryController(dataProvider: FakeTask11GalleryDataProvider(assets: [asset]))
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task11GallerySourceControllerFactory(gallery: gallery)
        )

        sheet.loadViewIfNeeded()
        gallery.replaceSelectedDrafts([makeAssetDraft(localIdentifier: "asset-1")])
        sheet.chatAttachmentSheetPresentationStateDidChange(.expanded)
        sheet.chatAttachmentSheetPresentationStateDidChange(.compact)

        XCTAssertEqual(gallery.displayMode, .full)
        XCTAssertEqual(gallery.gallerySelectionOrder(forAssetLocalIdentifier: "asset-1"), 1)
    }

    func testCellReuseDoesNotLeakSelectedOrBlockedState() {
        let cell = ChatAttachmentGalleryCollectionViewCell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let selectedState = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(makeAsset(localIdentifier: "asset-1")),
            thumbnailState: .image,
            selectionOrder: 1
        )
        let unselectedState = ChatAttachmentGalleryCellStatePolicy.state(
            for: .asset(makeAsset(localIdentifier: "asset-2")),
            thumbnailState: .image,
            selectionOrder: nil,
            isSelectionBlocked: true
        )

        cell.configure(state: selectedState, image: nil)
        XCTAssertFalse(cell.selectionBadgeLabel.isHidden)

        cell.prepareForReuse()
        cell.configure(state: unselectedState, image: nil)

        XCTAssertTrue(cell.selectionBadgeLabel.isHidden)
        XCTAssertTrue(cell.selectionRingView.isHidden)
        XCTAssertFalse(cell.selectionBlockedView.isHidden)
    }

    private func makeGalleryController(
        photoLibraryAuthorizer: FakeTask11PhotoLibraryAuthorizer = FakeTask11PhotoLibraryAuthorizer(status: .authorized),
        cameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding = FakeTask11CameraDraftBuilder(draft: makeCapturedDraft(filename: "capture.jpg")),
        dataProvider: FakeTask11GalleryDataProvider = FakeTask11GalleryDataProvider()
    ) -> ChatAttachmentGallerySourceViewController {
        ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: photoLibraryAuthorizer,
            limitedLibraryPresenter: FakeTask11LimitedLibraryPresenter(),
            settingsOpener: FakeTask11ApplicationSettingsOpener(),
            galleryDataProvider: dataProvider,
            thumbnailProvider: FakeTask11GalleryThumbnailProvider(),
            cameraDraftBuilder: cameraDraftBuilder
        )
    }

    private static func makeContext() -> ChatAttachmentFlowContext {
        ChatAttachmentFlowContext(
            owner: "alice@example.com",
            jid: "bob@example.com",
            conversationType: .regular,
            forwardedMessageIds: []
        )
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
        byteSize: 0,
        duration: nil,
        dimensions: nil,
        preparationState: .pending
    )
}

private func makeCapturedDraft(filename: String) -> AttachmentDraft {
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

private final class Task11GallerySourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private let gallery: ChatAttachmentGallerySourceViewController

    init(gallery: ChatAttachmentGallerySourceViewController) {
        self.gallery = gallery
    }

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        if source == .gallery {
            return gallery
        }

        return ChatAttachmentPlaceholderSourceViewController(source: source)
    }
}

private final class FakeTask11PhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
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

private final class FakeTask11LimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    func presentLimitedLibraryPicker(from viewController: UIViewController) {}
}

private final class FakeTask11ApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {}
}

private final class FakeTask11GalleryDataProvider: ChatAttachmentGalleryDataProviding {
    var assets: [ChatAttachmentGalleryAsset]

    init(assets: [ChatAttachmentGalleryAsset] = []) {
        self.assets = assets
    }

    func fetchAssets() -> [ChatAttachmentGalleryAsset] {
        assets
    }
}

private final class FakeTask11GalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
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

private final class FakeTask11CameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding {
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
