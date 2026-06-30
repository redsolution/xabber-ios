import AVFoundation
import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatAttachmentPreviewViewerTests: XCTestCase {
    func testSelectionComposerBarHiddenAtZeroAndVisibleWhenSelectionChanges() {
        let source = FakeTask12SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()
        XCTAssertTrue(sheet.selectionPreviewBarView.isHidden)
        XCTAssertTrue(sheet.selectionComposerBarView.isHidden)
        XCTAssertFalse(sheet.sourceBarView.isHidden)

        source.replaceSelectedDrafts([makePreparedAssetDraft(localIdentifier: "asset-1")])

        XCTAssertTrue(sheet.selectionPreviewBarView.isHidden)
        XCTAssertEqual(sheet.selectionPreviewBarView.selectedCount, 1)
        XCTAssertFalse(sheet.selectionComposerBarView.isHidden)
        XCTAssertTrue(sheet.sourceBarView.isHidden)
        XCTAssertTrue(sheet.selectionComposerBarView.sendButton.isEnabled)
    }

    func testOpeningPreviewUsesSelectedDraftsInOrder() throws {
        let source = FakeTask12SelectableSourceController(source: .gallery)
        var presentedPreview: ChatAttachmentPreviewViewController?
        let sheet = makeSheet(source: source) { _, preview, _, completion in
            presentedPreview = preview as? ChatAttachmentPreviewViewController
            completion?()
        }
        let first = makeAssetDraft(localIdentifier: "asset-1")
        let second = makeAssetDraft(localIdentifier: "asset-2")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([first, second])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)

        let preview = try XCTUnwrap(presentedPreview)
        XCTAssertEqual(preview.drafts.map(\.id), [first.id, second.id])
        XCTAssertEqual(preview.currentDraft?.id, first.id)
    }

    func testPreviewNavigationUpdatesCurrentIndexAndCount() {
        let preview = makePreview(drafts: [
            makeAssetDraft(localIdentifier: "asset-1"),
            makeAssetDraft(localIdentifier: "asset-2"),
            makeAssetDraft(localIdentifier: "asset-3")
        ])

        preview.loadViewIfNeeded()
        preview.goToNextDraft()

        XCTAssertEqual(preview.currentIndex, 1)
        XCTAssertEqual(preview.countLabel.text, "2 / 3")

        preview.goToPreviousDraft()

        XCTAssertEqual(preview.currentIndex, 0)
        XCTAssertEqual(preview.countLabel.text, "1 / 3")
    }

    func testPreviewSendButtonUsesChatComposerIconOnlyGlassStyle() {
        let preview = makePreview(drafts: [makeAssetDraft(localIdentifier: "asset-1")])

        preview.loadViewIfNeeded()

        XCTAssertNil(preview.sendButton.title(for: .normal))
        XCTAssertNil(preview.sendButton.configuration?.title)
        XCTAssertNotNil(preview.sendButton.image(for: .normal) ?? preview.sendButton.configuration?.image)
        XCTAssertEqual(preview.sendButton.tintColor, .secondaryLabel)
        XCTAssertTrue(
            preview.sendButton.constraints.contains {
                $0.firstAttribute == .width && $0.constant == NativeGlassBarStyle.buttonSize
            }
        )
        XCTAssertTrue(
            preview.sendButton.constraints.contains {
                $0.firstAttribute == .height && $0.constant == NativeGlassBarStyle.buttonSize
            }
        )
    }

    func testPreviewUsesChatLikeComposerAndKeepsEditOutsideComposer() throws {
        let draft = makeAssetDraft(localIdentifier: "asset-1")
        let preview = makePreview(drafts: [draft])

        preview.loadViewIfNeeded()
        preview.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        preview.view.layoutIfNeeded()

        let composer = try XCTUnwrap(
            firstSubview(
                in: preview.view,
                accessibilityIdentifier: "chatAttachmentPreview.composerBar",
                as: UIView.self
            )
        )
        let resetButton = try XCTUnwrap(
            firstSubview(
                in: preview.view,
                accessibilityIdentifier: "chatAttachmentPreview.composer.resetButton",
                as: UIButton.self
            )
        )

        XCTAssertTrue(resetButton.isDescendant(of: composer))
        XCTAssertTrue(preview.captionInputView.isDescendant(of: composer))
        XCTAssertTrue(preview.sendButton.isDescendant(of: composer))
        XCTAssertFalse(preview.editButton.isDescendant(of: composer))
        XCTAssertFalse(preview.editButton.isHidden)
        XCTAssertEqual(resetButton.frame.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(resetButton.frame.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(preview.sendButton.frame.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(preview.sendButton.frame.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(
            preview.captionInputView.frame.minX,
            resetButton.frame.maxX + NativeGlassBarStyle.interItemSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(
            preview.sendButton.frame.minX,
            preview.captionInputView.frame.maxX + NativeGlassBarStyle.interItemSpacing,
            accuracy: 0.001
        )
        XCTAssertNil(resetButton.title(for: .normal))
        XCTAssertNil(resetButton.configuration?.title)
        XCTAssertNotNil(resetButton.image(for: .normal) ?? resetButton.configuration?.image)
    }

    func testPreviewComposerGrowsWithMultilineCaptionAndKeepsCollectionAboveBottomControls() throws {
        let draft = makePreparedAssetDraft(localIdentifier: "asset-1")
        let preview = makePreview(drafts: [draft])

        preview.loadViewIfNeeded()
        preview.view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        preview.view.layoutIfNeeded()

        let bottomControls = try XCTUnwrap(
            firstSubview(
                in: preview.view,
                accessibilityIdentifier: "chatAttachmentPreview.bottomControls",
                as: UIView.self
            )
        )
        let composer = try XCTUnwrap(
            firstSubview(
                in: preview.view,
                accessibilityIdentifier: "chatAttachmentPreview.composerBar",
                as: UIView.self
            )
        )
        let collapsedComposerHeight = NativeGlassBarStyle.minimumHeight
            + 8
            + NativeGlassBarStyle.bottomOffset

        XCTAssertEqual(composer.frame.height, collapsedComposerHeight, accuracy: 0.001)
        XCTAssertEqual(bottomControls.frame.height, collapsedComposerHeight + 8, accuracy: 0.001)
        XCTAssertEqual(preview.collectionView.frame.maxY, bottomControls.frame.minY - 8, accuracy: 0.001)

        preview.captionInputView.textView.text = Array(repeating: "Long caption line", count: 40).joined(separator: "\n")
        preview.captionInputView.textViewDidChange(preview.captionInputView.textView)
        preview.view.layoutIfNeeded()

        let expandedCaptionHeight = preview.captionInputView.frame.height
        let expandedComposerHeight = expandedCaptionHeight + 8 + NativeGlassBarStyle.bottomOffset
        XCTAssertEqual(expandedCaptionHeight, 138, accuracy: 0.001)
        XCTAssertTrue(preview.captionInputView.textView.isScrollEnabled)
        XCTAssertEqual(composer.frame.height, expandedComposerHeight, accuracy: 0.001)
        XCTAssertEqual(bottomControls.frame.height, expandedComposerHeight + 8, accuracy: 0.001)
        XCTAssertEqual(preview.collectionView.frame.maxY, bottomControls.frame.minY - 8, accuracy: 0.001)
        XCTAssertEqual(preview.composerBarView.resetButton.frame.maxY, preview.captionInputView.frame.maxY, accuracy: 0.001)
        XCTAssertEqual(preview.sendButton.frame.maxY, preview.captionInputView.frame.maxY, accuracy: 0.001)
        XCTAssertFalse(preview.editButton.isDescendant(of: composer))
    }

    func testRemovingMiddleDraftUpdatesSourceAndPreview() throws {
        let source = FakeTask12SelectableSourceController(source: .gallery)
        var presentedPreview: ChatAttachmentPreviewViewController?
        let sheet = makeSheet(source: source) { _, preview, _, completion in
            presentedPreview = preview as? ChatAttachmentPreviewViewController
            completion?()
        }
        let first = makeAssetDraft(localIdentifier: "asset-1")
        let second = makeAssetDraft(localIdentifier: "asset-2")
        let third = makeAssetDraft(localIdentifier: "asset-3")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([first, second, third])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        let preview = try XCTUnwrap(presentedPreview)
        preview.goToNextDraft()

        preview.removeCurrentDraft()

        XCTAssertEqual(source.selectedAttachmentDrafts.map(\.id), [first.id, third.id])
        XCTAssertEqual(sheet.selectedAttachmentDrafts.map(\.id), [first.id, third.id])
        XCTAssertEqual(preview.drafts.map(\.id), [first.id, third.id])
        XCTAssertEqual(preview.currentDraft?.id, third.id)
        XCTAssertEqual(preview.countLabel.text, "2 / 2")
    }

    func testRemovingOnlyDraftDismissesPreview() throws {
        let source = FakeTask12SelectableSourceController(source: .gallery)
        var presentedPreview: ChatAttachmentPreviewViewController?
        var dismissedPreviewCount = 0
        let sheet = makeSheet(
            source: source,
            previewPresentationHandler: { _, preview, _, completion in
                presentedPreview = preview as? ChatAttachmentPreviewViewController
                completion?()
            },
            previewDismissalHandler: { _, _, completion in
                dismissedPreviewCount += 1
                completion?()
            }
        )
        let draft = makeAssetDraft(localIdentifier: "asset-1")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        let preview = try XCTUnwrap(presentedPreview)

        preview.removeCurrentDraft()

        XCTAssertTrue(source.selectedAttachmentDrafts.isEmpty)
        XCTAssertNil(sheet.previewViewController)
        XCTAssertEqual(dismissedPreviewCount, 1)
    }

    func testPreviewResetButtonClearsEntireSelectionAndDismissesPreview() throws {
        let source = FakeTask12SelectableSourceController(source: .gallery)
        var presentedPreview: ChatAttachmentPreviewViewController?
        var dismissedPreviewCount = 0
        let sheet = makeSheet(
            source: source,
            previewPresentationHandler: { _, preview, _, completion in
                presentedPreview = preview as? ChatAttachmentPreviewViewController
                completion?()
            },
            previewDismissalHandler: { _, _, completion in
                dismissedPreviewCount += 1
                completion?()
            }
        )
        let first = makeAssetDraft(localIdentifier: "asset-1")
        let second = makeAssetDraft(localIdentifier: "asset-2")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([first, second])
        sheet.selectionComposerBarView.captionInputView.textView.text = "Reset all"
        sheet.selectionComposerBarView.captionInputView.textViewDidChange(
            sheet.selectionComposerBarView.captionInputView.textView
        )
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        let preview = try XCTUnwrap(presentedPreview)
        let resetButton = try XCTUnwrap(
            firstSubview(
                in: preview.view,
                accessibilityIdentifier: "chatAttachmentPreview.composer.resetButton",
                as: UIButton.self
            )
        )

        resetButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(source.selectedAttachmentDrafts.isEmpty)
        XCTAssertTrue(sheet.selectedAttachmentDrafts.isEmpty)
        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertNil(sheet.previewViewController)
        XCTAssertEqual(dismissedPreviewCount, 1)
        XCTAssertFalse(sheet.sourceBarView.isHidden)
        XCTAssertTrue(sheet.selectionComposerBarView.isHidden)
    }

    func testRemovingCapturedDraftUsesGalleryCleanupPath() throws {
        let capturedDraft = makeCapturedDraft(filename: "capture.jpg")
        let draftBuilder = FakeTask12CameraDraftBuilder(draft: capturedDraft)
        let gallery = ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: FakeTask12PhotoLibraryAuthorizer(status: .authorized),
            limitedLibraryPresenter: FakeTask12LimitedLibraryPresenter(),
            settingsOpener: FakeTask12ApplicationSettingsOpener(),
            galleryDataProvider: FakeTask12GalleryDataProvider(),
            thumbnailProvider: FakeTask12GalleryThumbnailProvider(),
            cameraDraftBuilder: draftBuilder
        )
        var presentedPreview: ChatAttachmentPreviewViewController?
        let sheet = makeSheet(source: gallery) { _, preview, _, completion in
            presentedPreview = preview as? ChatAttachmentPreviewViewController
            completion?()
        }

        sheet.loadViewIfNeeded()
        gallery.replaceSelectedDrafts([capturedDraft])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        try XCTUnwrap(presentedPreview).removeCurrentDraft()

        XCTAssertEqual(draftBuilder.removedDraftIDs, [capturedDraft.id])
        XCTAssertTrue(gallery.selectedDrafts.isEmpty)
    }

    func testPreviewRequestsMediaForPhotoKitAndCapturedImageDrafts() {
        let provider = FakeTask12PreviewMediaProvider()
        provider.mediaByDraftID = [
            AttachmentAssetDraft(assetLocalIdentifier: "asset-1").id: .image(UIImage()),
            makeCapturedDraft(filename: "capture.jpg").id: .image(UIImage())
        ]
        let assetDraft = makeAssetDraft(localIdentifier: "asset-1")
        let capturedDraft = makeCapturedDraft(filename: "capture.jpg")
        let preview = makePreview(drafts: [assetDraft, capturedDraft], mediaProvider: provider)

        preview.loadViewIfNeeded()
        _ = preview.collectionView(
            preview.collectionView,
            cellForItemAt: IndexPath(item: 0, section: 0)
        )
        _ = preview.collectionView(
            preview.collectionView,
            cellForItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertEqual(provider.requestedDraftIDs, [assetDraft.id, capturedDraft.id])
    }

    func testPreviewProviderUsesPreparedLocationSnapshotImage() throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("location-preview-\(UUID().uuidString).png")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 12, height: 12),
            format: format
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        try XCTUnwrap(sourceImage.pngData()).write(to: snapshotURL)
        let provider = PhotoKitChatAttachmentPreviewMediaProvider()
        let draft = makePreparedLocationDraft(snapshotURL: snapshotURL)
        var receivedMedia: ChatAttachmentPreviewMedia?

        provider.requestPreviewMedia(
            for: draft,
            targetSize: CGSize(width: 120, height: 120)
        ) { media in
            receivedMedia = media
        }

        guard case .image(let image) = receivedMedia else {
            return XCTFail("Expected location snapshot preview image")
        }
        XCTAssertEqual(image.size.width, sourceImage.size.width)
        XCTAssertEqual(image.size.height, sourceImage.size.height)
    }

    func testVideoPreviewRequestsPlayerPresentation() throws {
        let provider = FakeTask12PreviewMediaProvider()
        let presenter = FakeTask12PreviewVideoPresenter()
        let draft = makeCapturedDraft(filename: "capture.mov")
        provider.mediaByDraftID[draft.id] = .video(
            thumbnail: nil,
            playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/tmp/capture.mov"))
        )
        let preview = makePreview(
            drafts: [draft],
            mediaProvider: provider,
            videoPresenter: presenter
        )

        preview.loadViewIfNeeded()
        let cell = try XCTUnwrap(
            preview.collectionView(
                preview.collectionView,
                cellForItemAt: IndexPath(item: 0, section: 0)
            ) as? ChatAttachmentPreviewCollectionViewCell
        )
        cell.playButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertTrue(presenter.presentedFrom === preview)
    }

    func testGenericFileDraftRendersPlaceholderMetadata() throws {
        let draft = makeFileDraft(filename: "document.pdf", byteSize: 42)
        let preview = makePreview(drafts: [draft])

        preview.loadViewIfNeeded()
        let cell = try XCTUnwrap(
            preview.collectionView(
                preview.collectionView,
                cellForItemAt: IndexPath(item: 0, section: 0)
            ) as? ChatAttachmentPreviewCollectionViewCell
        )

        XCTAssertEqual(cell.placeholderTitleLabel.text, "document.pdf")
        XCTAssertEqual(cell.placeholderSubtitleLabel.text, "42 bytes")
    }

    func testSendButtonDisabledAndSendScopeUsesAllDraftsInOrder() {
        let first = makeAssetDraft(localIdentifier: "asset-1")
        let second = makeAssetDraft(localIdentifier: "asset-2")
        let delegate = FakeTask12PreviewDelegate()
        let preview = makePreview(drafts: [first, second])
        preview.delegate = delegate

        preview.loadViewIfNeeded()
        preview.sendButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(preview.sendButton.isEnabled)
        XCTAssertEqual(delegate.sendDraftIDs, [])
        XCTAssertEqual(
            ChatAttachmentPreviewSendScopePolicy.draftsForSend(
                from: [first, second],
                activeDraftID: second.id
            ).map(\.id),
            [first.id, second.id]
        )
    }

    func testPhotoLibraryRefreshWhilePreviewOpenPrunesAndUpdatesPreview() throws {
        let authorizer = FakeTask12PhotoLibraryAuthorizer(status: .limited)
        authorizer.accessibleAssetLocalIdentifiers = ["asset-kept"]
        let gallery = ChatAttachmentGallerySourceViewController(
            photoLibraryAuthorizer: authorizer,
            limitedLibraryPresenter: FakeTask12LimitedLibraryPresenter(),
            settingsOpener: FakeTask12ApplicationSettingsOpener(),
            galleryDataProvider: FakeTask12GalleryDataProvider(),
            thumbnailProvider: FakeTask12GalleryThumbnailProvider()
        )
        var presentedPreview: ChatAttachmentPreviewViewController?
        let sheet = makeSheet(source: gallery) { _, preview, _, completion in
            presentedPreview = preview as? ChatAttachmentPreviewViewController
            completion?()
        }
        let kept = makeAssetDraft(localIdentifier: "asset-kept")
        let removed = makeAssetDraft(localIdentifier: "asset-removed")

        sheet.loadViewIfNeeded()
        gallery.replaceSelectedDrafts([kept, removed])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        gallery.handlePhotoLibraryDidChange()

        let preview = try XCTUnwrap(presentedPreview)
        XCTAssertEqual(gallery.selectedDrafts.map(\.id), [kept.id])
        XCTAssertEqual(preview.drafts.map(\.id), [kept.id])
        XCTAssertEqual(preview.countLabel.text, "1 / 1")
    }

    private func makeSheet(
        source: ChatAttachmentSourceControlling,
        previewPresentationHandler: @escaping ChatAttachmentSheetViewController.PreviewPresentationHandler = { _, _, _, completion in completion?() },
        previewDismissalHandler: @escaping ChatAttachmentSheetViewController.PreviewDismissalHandler = { _, _, completion in completion?() }
    ) -> ChatAttachmentSheetViewController {
        ChatAttachmentSheetViewController(
            context: ChatAttachmentFlowContext(
                owner: "alice@example.com",
                jid: "bob@example.com",
                conversationType: .regular,
                forwardedMessageIds: []
            ),
            sourceControllerFactory: FakeTask12SourceControllerFactory(source: source),
            previewPresentationHandler: previewPresentationHandler,
            previewDismissalHandler: previewDismissalHandler
        )
    }

    private func makePreview(
        drafts: [AttachmentDraft],
        mediaProvider: ChatAttachmentPreviewMediaProviding = FakeTask12PreviewMediaProvider(),
        videoPresenter: ChatAttachmentPreviewVideoPresenting = FakeTask12PreviewVideoPresenter()
    ) -> ChatAttachmentPreviewViewController {
        ChatAttachmentPreviewViewController(
            drafts: drafts,
            mediaProvider: mediaProvider,
            videoPresenter: videoPresenter
        )
    }

    private func firstSubview<T: UIView>(
        in root: UIView,
        accessibilityIdentifier: String,
        as type: T.Type
    ) -> T? {
        if root.accessibilityIdentifier == accessibilityIdentifier {
            return root as? T
        }

        for subview in root.subviews {
            if let match = firstSubview(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier,
                as: type
            ) {
                return match
            }
        }

        return nil
    }
}

private final class FakeTask12SourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private let source: ChatAttachmentSourceControlling

    init(source: ChatAttachmentSourceControlling) {
        self.source = source
    }

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        self.source.source == source ? self.source : ChatAttachmentPlaceholderSourceViewController(source: source)
    }
}

private final class FakeTask12SelectableSourceController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating,
    ChatAttachmentDraftSelectionSyncing {
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

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
        onSelectionCountChanged?(drafts.count)
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

private final class FakeTask12PreviewMediaProvider: ChatAttachmentPreviewMediaProviding {
    var mediaByDraftID: [String: ChatAttachmentPreviewMedia] = [:]
    private(set) var requestedDraftIDs: [String] = []

    @discardableResult
    func requestPreviewMedia(
        for draft: AttachmentDraft,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentPreviewMedia) -> Void
    ) -> Int {
        requestedDraftIDs.append(draft.id)
        completion(mediaByDraftID[draft.id] ?? .filePlaceholder(filename: draft.filename, byteSize: draft.byteSize))
        return requestedDraftIDs.count
    }

    func cancelPreviewMediaRequest(_ requestID: Int) {}
}

private final class FakeTask12PreviewVideoPresenter: ChatAttachmentPreviewVideoPresenting {
    private(set) var presentCount = 0
    private(set) weak var presentedFrom: UIViewController?

    func presentVideo(playerItem: AVPlayerItem, from viewController: UIViewController) {
        presentCount += 1
        presentedFrom = viewController
    }
}

private final class FakeTask12PreviewDelegate: ChatAttachmentPreviewViewControllerDelegate {
    private(set) var removedDraftIDs: [String] = []
    private(set) var sendDraftIDs: [String] = []

    func chatAttachmentPreviewViewControllerDidClose(_ preview: ChatAttachmentPreviewViewController) {}

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRemoveDraftWithID draftID: String
    ) {
        removedDraftIDs.append(draftID)
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didReplaceDraftWithID draftID: String,
        updatedDraft: AttachmentDraft
    ) {}

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRequestSend drafts: [AttachmentDraft]
    ) {
        sendDraftIDs = drafts.map(\.id)
    }
}

private final class FakeTask12PhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
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

private final class FakeTask12LimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    func presentLimitedLibraryPicker(from viewController: UIViewController) {}
}

private final class FakeTask12ApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {}
}

private final class FakeTask12GalleryDataProvider: ChatAttachmentGalleryDataProviding {
    func fetchAssets() -> [ChatAttachmentGalleryAsset] { [] }
}

private final class FakeTask12GalleryThumbnailProvider: ChatAttachmentGalleryThumbnailProviding {
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

private final class FakeTask12CameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding {
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

private func makeAssetDraft(localIdentifier: String) -> AttachmentDraft {
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

private func makePreparedAssetDraft(localIdentifier: String) -> AttachmentDraft {
    var draft = makeAssetDraft(localIdentifier: localIdentifier)
    let url = URL(fileURLWithPath: "/tmp/\(draft.filename)")
    draft.preparationState = .prepared(
        AttachmentPreparedFile(
            localFileURL: url,
            referenceURL: url,
            filename: draft.filename,
            byteSize: max(1, draft.byteSize),
            mediaType: "image/jpeg",
            dimensions: draft.dimensions,
            duration: draft.duration,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )
    )
    return draft
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
        duration: filename.hasSuffix(".mov") ? 12 : nil,
        dimensions: CGSize(width: 12, height: 8),
        preparationState: .pending
    )
}

private func makeFileDraft(filename: String = "document.pdf", byteSize: Int = 1) -> AttachmentDraft {
    AttachmentDraft(
        id: AttachmentFileDraft(url: URL(fileURLWithPath: "/tmp/\(filename)")).id,
        source: .file,
        mediaKind: .file,
        thumbnailState: .none,
        filename: filename,
        byteSize: byteSize,
        duration: nil,
        dimensions: nil,
        preparationState: .pending
    )
}

private func makePreparedLocationDraft(snapshotURL: URL?) -> AttachmentDraft {
    let location = AttachmentPreparedLocation(
        coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
        displayAddress: "Westminster",
        accuracy: nil,
        geoURI: "geo:51.5007,-0.1246",
        createdAt: Date(timeIntervalSince1970: 1_782_799_200),
        localSnapshotURL: snapshotURL
    )
    return AttachmentDraft(
        id: "location:\(location.geoURI)",
        source: .geolocation,
        mediaKind: .location,
        thumbnailState: .none,
        filename: "Location",
        byteSize: 0,
        duration: nil,
        dimensions: nil,
        preparationState: .preparedLocation(location)
    )
}
