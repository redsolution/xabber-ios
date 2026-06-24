import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentPhotosPermissionTests: XCTestCase {
    func testPermissionPolicyMapsEveryAuthorizationStatus() {
        XCTAssertEqual(ChatAttachmentPhotosPermissionPolicy.state(for: .notDetermined), .requestAccess)
        XCTAssertEqual(ChatAttachmentPhotosPermissionPolicy.state(for: .limited), .ready(isLimited: true))
        XCTAssertEqual(ChatAttachmentPhotosPermissionPolicy.state(for: .authorized), .ready(isLimited: false))
        XCTAssertEqual(ChatAttachmentPhotosPermissionPolicy.state(for: .denied), .blocked(reason: .denied))
        XCTAssertEqual(ChatAttachmentPhotosPermissionPolicy.state(for: .restricted), .blocked(reason: .restricted))
        XCTAssertEqual(ChatAttachmentPhotosPermissionPolicy.state(for: .unavailable), .blocked(reason: .unavailable))
    }

    func testNotDeterminedRendersRequestButtonAndRequestsOnlyAfterTap() {
        let authorizer = FakePhotoLibraryAuthorizer(status: .notDetermined)
        authorizer.requestResult = .limited
        let controller = makeGalleryController(authorizer: authorizer)

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.permissionState, .requestAccess)
        XCTAssertFalse(controller.allowAccessButton.isHidden)
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertTrue(controller.openSettingsButton.isHidden)
        XCTAssertEqual(authorizer.requestCount, 0)

        controller.allowAccessButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(controller.permissionState, .ready(isLimited: true))
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertNil(controller.fullGalleryActionMenuButton.superview)
        XCTAssertTrue(controller.fullGalleryActionMenuButton.isHidden)
    }

    func testLimitedStateIsReadyWithoutFullGalleryActionMenu() {
        let authorizer = FakePhotoLibraryAuthorizer(status: .limited)
        let limitedPresenter = FakeLimitedLibraryPresenter()
        let controller = makeGalleryController(
            authorizer: authorizer,
            limitedLibraryPresenter: limitedPresenter
        )

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.permissionState, .ready(isLimited: true))
        XCTAssertTrue(controller.allowAccessButton.isHidden)
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertNil(controller.fullGalleryActionMenuButton.superview)
        XCTAssertTrue(controller.fullGalleryActionMenuButton.isHidden)
        XCTAssertTrue(controller.openSettingsButton.isHidden)

        controller.fullGalleryActionMenuButton.sendActions(for: .touchUpInside)

        XCTAssertNil(limitedPresenter.presentedFrom)
    }

    func testDeniedStateRendersSettingsAction() {
        let settingsOpener = FakeApplicationSettingsOpener()
        let controller = makeGalleryController(
            authorizer: FakePhotoLibraryAuthorizer(status: .denied),
            settingsOpener: settingsOpener
        )

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.permissionState, .blocked(reason: .denied))
        XCTAssertTrue(controller.allowAccessButton.isHidden)
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertFalse(controller.openSettingsButton.isHidden)

        controller.openSettingsButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(settingsOpener.openCount, 1)
    }

    func testRestrictedStateDoesNotRenderSettingsAction() {
        let settingsOpener = FakeApplicationSettingsOpener()
        let controller = makeGalleryController(
            authorizer: FakePhotoLibraryAuthorizer(status: .restricted),
            settingsOpener: settingsOpener
        )

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.permissionState, .blocked(reason: .restricted))
        XCTAssertTrue(controller.allowAccessButton.isHidden)
        XCTAssertTrue(controller.manageLimitedLibraryButton.isHidden)
        XCTAssertTrue(controller.openSettingsButton.isHidden)
    }

    func testSelectionRefreshKeepsAccessiblePhotoDraftsAndRemovesDisappearedAssets() {
        let keptAsset = makeAssetDraft(localIdentifier: "asset-kept")
        let disappearedAsset = makeAssetDraft(localIdentifier: "asset-gone")
        let fileDraft = makeFileDraft()

        let refreshed = ChatAttachmentGallerySelectionRefreshPolicy.refreshedDrafts(
            [keptAsset, disappearedAsset, fileDraft],
            authorizationStatus: .limited,
            isAssetAccessible: { $0 == "asset-kept" }
        )

        XCTAssertEqual(refreshed.map(\.id), [keptAsset.id, fileDraft.id])
    }

    func testLosingPhotosAccessRemovesOnlyGalleryAssetDrafts() {
        let galleryAsset = makeAssetDraft(localIdentifier: "asset-denied")
        let fileDraft = makeFileDraft()

        let refreshed = ChatAttachmentGallerySelectionRefreshPolicy.refreshedDrafts(
            [galleryAsset, fileDraft],
            authorizationStatus: .denied,
            isAssetAccessible: { _ in true }
        )

        XCTAssertEqual(refreshed.map(\.id), [fileDraft.id])
    }

    func testPhotoLibraryChangeRefreshesPermissionAndSelectionCount() {
        let authorizer = FakePhotoLibraryAuthorizer(status: .limited)
        authorizer.accessibleAssetLocalIdentifiers = ["asset-kept"]
        let controller = makeGalleryController(authorizer: authorizer)
        var selectionCounts: [Int] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.replaceSelectedDrafts([
            makeAssetDraft(localIdentifier: "asset-kept"),
            makeAssetDraft(localIdentifier: "asset-gone")
        ])

        controller.handlePhotoLibraryDidChange()

        XCTAssertEqual(controller.selectedDrafts.map(\.id), [AttachmentAssetDraft(assetLocalIdentifier: "asset-kept").id])
        XCTAssertEqual(selectionCounts, [2, 1])
        XCTAssertEqual(controller.permissionState, .ready(isLimited: true))
    }

    private func makeGalleryController(
        authorizer: FakePhotoLibraryAuthorizer,
        limitedLibraryPresenter: FakeLimitedLibraryPresenter = FakeLimitedLibraryPresenter(),
        settingsOpener: FakeApplicationSettingsOpener = FakeApplicationSettingsOpener()
    ) -> ChatAttachmentGallerySourceViewController {
        ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: authorizer,
            limitedLibraryPresenter: limitedLibraryPresenter,
            settingsOpener: settingsOpener
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

private final class FakePhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
    var authorizationStatus: ChatAttachmentPhotosAuthorizationStatus
    var requestResult: ChatAttachmentPhotosAuthorizationStatus
    var requestCount = 0
    var registerCount = 0
    var unregisterCount = 0
    var accessibleAssetLocalIdentifiers: Set<String> = []

    init(status: ChatAttachmentPhotosAuthorizationStatus) {
        self.authorizationStatus = status
        self.requestResult = status
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentPhotosAuthorizationStatus) -> Void) {
        requestCount += 1
        authorizationStatus = requestResult
        completion(requestResult)
    }

    func registerChangeObserver(_ observer: AnyObject) {
        registerCount += 1
    }

    func unregisterChangeObserver(_ observer: AnyObject) {
        unregisterCount += 1
    }

    func containsAsset(localIdentifier: String) -> Bool {
        accessibleAssetLocalIdentifiers.contains(localIdentifier)
    }
}

private final class FakeLimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    private(set) weak var presentedFrom: UIViewController?

    func presentLimitedLibraryPicker(from viewController: UIViewController) {
        presentedFrom = viewController
    }
}

private final class FakeApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    private(set) var openCount = 0

    func openApplicationSettings() {
        openCount += 1
    }
}
