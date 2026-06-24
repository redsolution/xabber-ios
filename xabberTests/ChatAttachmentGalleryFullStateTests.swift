import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentGalleryFullStateTests: XCTestCase {
    func testExpandedSheetStateKeepsGalleryFullModeWithoutTopBar() {
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeTask9GalleryDataProvider(assets: [
                makeAsset(localIdentifier: "asset-1")
            ])
        )
        let sheet = makeSheet(gallery: gallery)

        sheet.loadViewIfNeeded()
        sheet.chatAttachmentSheetPresentationStateDidChange(.expanded)

        XCTAssertEqual(gallery.displayMode, .full)
        XCTAssertNil(gallery.fullGalleryTopBarView.superview)
        XCTAssertNil(gallery.galleryTitleLabel.superview)
        XCTAssertNil(gallery.dismissFullGalleryButton.superview)
        XCTAssertNil(gallery.fullGalleryActionMenuButton.superview)
        XCTAssertNil(gallery.albumSelectionButton)
    }

    func testCompactStateKeepsFullscreenGalleryWithoutTopBarAndPreservesSelectedDrafts() {
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeTask9GalleryDataProvider(assets: [
                makeAsset(localIdentifier: "asset-selected")
            ])
        )
        let sheet = makeSheet(gallery: gallery)

        sheet.loadViewIfNeeded()
        gallery.replaceSelectedDrafts([makeAssetDraft(localIdentifier: "asset-selected")])
        sheet.chatAttachmentSheetPresentationStateDidChange(.expanded)
        sheet.chatAttachmentSheetPresentationStateDidChange(.compact)

        XCTAssertEqual(gallery.displayMode, .full)
        XCTAssertNil(gallery.fullGalleryTopBarView.superview)
        XCTAssertEqual(gallery.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-selected").id
        ])
    }

    func testCollapseButtonIsRemovedAndDoesNotRequestCompactState() {
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .authorized)
        )
        let sheet = makeSheet(gallery: gallery)
        sheet.loadViewIfNeeded()
        sheet.chatAttachmentSheetPresentationStateDidChange(.expanded)

        XCTAssertNil(gallery.collapseFullGalleryButton.superview)
        gallery.collapseFullGalleryButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(sheet.presentationState, .expanded)
        XCTAssertEqual(gallery.displayMode, .full)
    }

    func testDismissButtonIsRemovedAndDoesNotEmitDismissRequest() {
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .authorized)
        )
        var dismissCount = 0
        gallery.onDismissRequested = {
            dismissCount += 1
        }

        gallery.loadViewIfNeeded()
        gallery.setDisplayMode(.full)
        gallery.dismissFullGalleryButton.sendActions(for: .touchUpInside)

        XCTAssertNil(gallery.dismissFullGalleryButton.superview)
        XCTAssertEqual(dismissCount, 0)
    }

    func testLimitedAccessDoesNotShowTopBarActionMenu() {
        let limitedPresenter = FakeTask9LimitedLibraryPresenter()
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .limited),
            limitedLibraryPresenter: limitedPresenter
        )

        gallery.loadViewIfNeeded()
        gallery.setDisplayMode(.full)
        gallery.fullGalleryActionMenuButton.sendActions(for: .touchUpInside)

        XCTAssertNil(gallery.fullGalleryActionMenuButton.superview)
        XCTAssertTrue(gallery.fullGalleryActionMenuButton.isHidden)
        XCTAssertEqual(limitedPresenter.presentCount, 0)
    }

    func testAuthorizedAccessDoesNotShowTopBarActionMenu() {
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .authorized)
        )

        gallery.loadViewIfNeeded()
        gallery.setDisplayMode(.full)

        XCTAssertNil(gallery.fullGalleryActionMenuButton.superview)
        XCTAssertTrue(gallery.fullGalleryActionMenuButton.isHidden)
    }

    func testDateIndicatorPolicyUsesFirstVisibleAssetMonthAndIgnoresCameraOrMissingDates() {
        let januaryAsset = makeAsset(
            localIdentifier: "jan",
            creationDate: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let noDateAsset = makeAsset(localIdentifier: "no-date", creationDate: nil)

        XCTAssertEqual(
            ChatAttachmentGalleryDateIndicatorPolicy.label(for: .asset(januaryAsset)),
            "Jan 2026"
        )
        XCTAssertNil(ChatAttachmentGalleryDateIndicatorPolicy.label(for: .camera))
        XCTAssertNil(ChatAttachmentGalleryDateIndicatorPolicy.label(for: .captured(ChatAttachmentGalleryCapturedMedia(draft: makeCapturedDraft(filename: "capture.jpg"))!)))
        XCTAssertNil(ChatAttachmentGalleryDateIndicatorPolicy.label(for: .asset(noDateAsset)))
        XCTAssertNil(ChatAttachmentGalleryDateIndicatorPolicy.label(for: nil))
    }

    func testDateIndicatorUpdatesFromVisibleAssetAndHidesOnIdle() {
        let gallery = makeGalleryController(
            authorizer: FakeTask9PhotoLibraryAuthorizer(status: .authorized),
            dataProvider: FakeTask9GalleryDataProvider(assets: [
                makeAsset(
                    localIdentifier: "feb",
                    creationDate: Date(timeIntervalSince1970: 1_769_904_000)
                )
            ])
        )

        gallery.loadViewIfNeeded()
        gallery.setDisplayMode(.full)
        gallery.updateDateIndicator(forVisibleItemAt: 1)

        XCTAssertEqual(gallery.dateIndicatorLabel.text, "Feb 2026")
        XCTAssertFalse(gallery.dateIndicatorLabel.isHidden)

        gallery.hideDateIndicatorForIdleState()

        XCTAssertTrue(gallery.dateIndicatorLabel.isHidden)
    }

    func testPhotoLibraryChangeInFullModeRefreshesAssetsAndPrunesOnlyInaccessibleGalleryDrafts() {
        let authorizer = FakeTask9PhotoLibraryAuthorizer(status: .limited)
        authorizer.accessibleAssetLocalIdentifiers = ["asset-kept"]
        let dataProvider = FakeTask9GalleryDataProvider(assets: [
            makeAsset(localIdentifier: "asset-gone")
        ])
        let gallery = makeGalleryController(
            authorizer: authorizer,
            dataProvider: dataProvider
        )
        let capturedDraft = makeCapturedDraft(filename: "capture.jpg")
        gallery.loadViewIfNeeded()
        gallery.setDisplayMode(.full)
        gallery.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-kept"),
            makeAssetDraft(localIdentifier: "asset-gone"),
            capturedDraft,
            makeFileDraft()
        ])
        dataProvider.assets = [makeAsset(localIdentifier: "asset-kept")]

        gallery.handlePhotoLibraryDidChange()

        XCTAssertEqual(gallery.displayMode, .full)
        XCTAssertNil(gallery.fullGalleryTopBarView.superview)
        XCTAssertEqual(gallery.galleryItems, [
            .camera,
            .captured(ChatAttachmentGalleryCapturedMedia(draft: capturedDraft)!),
            .asset(makeAsset(localIdentifier: "asset-kept"))
        ])
        XCTAssertEqual(gallery.selectedDrafts.map(\.id), [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-kept").id,
            capturedDraft.id,
            AttachmentFileDraft(url: URL(fileURLWithPath: "/tmp/document.pdf")).id
        ])
    }

    private func makeSheet(
        gallery: ChatAttachmentGallerySourceViewController
    ) -> ChatAttachmentSheetViewController {
        ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task9GallerySourceControllerFactory(gallery: gallery)
        )
    }

    private func makeGalleryController(
        authorizer: FakeTask9PhotoLibraryAuthorizer,
        limitedLibraryPresenter: FakeTask9LimitedLibraryPresenter = FakeTask9LimitedLibraryPresenter(),
        dataProvider: FakeTask9GalleryDataProvider = FakeTask9GalleryDataProvider()
    ) -> ChatAttachmentGallerySourceViewController {
        ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: authorizer,
            limitedLibraryPresenter: limitedLibraryPresenter,
            settingsOpener: FakeTask9ApplicationSettingsOpener(),
            galleryDataProvider: dataProvider,
            thumbnailProvider: FakeTask9GalleryThumbnailProvider()
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
}

private final class Task9GallerySourceControllerFactory: ChatAttachmentSourceControllerFactory {
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

private final class FakeTask9PhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
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

private final class FakeTask9LimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    private(set) var presentCount = 0

    func presentLimitedLibraryPicker(from viewController: UIViewController) {
        presentCount += 1
    }
}

private final class FakeTask9ApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {}
}

private final class FakeTask9GalleryDataProvider: ChatAttachmentGalleryDataProviding {
    var assets: [ChatAttachmentGalleryAsset]

    init(assets: [ChatAttachmentGalleryAsset] = []) {
        self.assets = assets
    }

    func fetchAssets() -> [ChatAttachmentGalleryAsset] {
        assets
    }
}

private final class FakeTask9GalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
    func requestThumbnail(
        for asset: ChatAttachmentGalleryAsset,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentGalleryThumbnailResult) -> Void
    ) -> Int {
        1
    }

    func cancelThumbnailRequest(_ requestID: Int) {}
    func startCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {}
    func stopCachingThumbnails(for assets: [ChatAttachmentGalleryAsset], targetSize: CGSize) {}
}
