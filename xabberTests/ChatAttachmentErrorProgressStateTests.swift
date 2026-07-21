import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import xabber

@MainActor
final class ChatAttachmentErrorProgressStateTests: XCTestCase {
    func testDraftStatusPolicyMapsPreparationStatesToVisibleStates() {
        let pending = draft(id: "asset:pending", state: .pending)
        let preparing = draft(id: "asset:preparing", state: .preparing)
        let prepared = preparedDraft(id: "asset:prepared")
        let unavailable = draft(id: "asset:gone", state: .unavailable(.assetUnavailable))

        XCTAssertEqual(ChatAttachmentDraftStatusPolicy.viewModel(for: pending).kind, .pending)
        XCTAssertEqual(ChatAttachmentDraftStatusPolicy.viewModel(for: preparing).kind, .preparing)
        XCTAssertEqual(ChatAttachmentDraftStatusPolicy.viewModel(for: prepared).kind, .ready)

        let unavailableViewModel = ChatAttachmentDraftStatusPolicy.viewModel(for: unavailable)
        XCTAssertEqual(unavailableViewModel.kind, .unavailable)
        XCTAssertTrue(unavailableViewModel.showsRetryAction)
        XCTAssertTrue(unavailableViewModel.showsRemoveAction)
        XCTAssertTrue(unavailableViewModel.blocksSend)
    }

    func testBatchStatusPolicyPrefersUnavailableThenPreparingAndReadyStates() {
        let prepared = preparedDraft(id: "asset:prepared")
        let pending = draft(id: "asset:pending", state: .pending)
        let preparing = draft(id: "asset:preparing", state: .preparing)
        let unavailable = draft(id: "asset:gone", state: .unavailable(.iCloudDownloadFailed))

        XCTAssertEqual(ChatAttachmentBatchStatusPolicy.viewModel(for: []).kind, .hidden)
        XCTAssertEqual(ChatAttachmentBatchStatusPolicy.viewModel(for: [prepared]).kind, .ready)
        XCTAssertEqual(ChatAttachmentBatchStatusPolicy.viewModel(for: [locationDraft(snapshotURL: URL(fileURLWithPath: "/tmp/map.png"))]).kind, .ready)
        XCTAssertEqual(ChatAttachmentBatchStatusPolicy.viewModel(for: [locationDraft(snapshotURL: nil)]).kind, .ready)

        let preparingViewModel = ChatAttachmentBatchStatusPolicy.viewModel(for: [prepared, pending, preparing])
        XCTAssertEqual(preparingViewModel.kind, .preparing)
        XCTAssertEqual(preparingViewModel.progress ?? -1, Float(1.0 / 3.0), accuracy: 0.001)

        let unavailableViewModel = ChatAttachmentBatchStatusPolicy.viewModel(for: [prepared, unavailable, pending])
        XCTAssertEqual(unavailableViewModel.kind, .blocked)
        XCTAssertEqual(unavailableViewModel.blockedItemCount, 1)
        XCTAssertTrue(unavailableViewModel.blocksSend)
    }

    func testSendFeedbackPolicyMapsBlockingReasonsToVisibleMessages() {
        let cloudStorage = ChatAttachmentSendFeedbackPolicy.viewModel(for: .cloudStorageUnavailable)
        let unprepared = ChatAttachmentSendFeedbackPolicy.viewModel(for: .unpreparedDrafts)
        let failed = ChatAttachmentSendFeedbackPolicy.viewModel(for: .sendFailed)

        XCTAssertEqual(cloudStorage.kind, .blocking)
        XCTAssertTrue(cloudStorage.message.contains("File transfer"))
        XCTAssertEqual(unprepared.kind, .attentionRequired)
        XCTAssertTrue(unprepared.message.contains("not ready"))
        XCTAssertEqual(failed.kind, .retryableFailure)
        XCTAssertTrue(failed.showsRetryAction)
    }

    func testMediaUploadTracePrivacyPolicyRejectsIdentityAndCredentialFields() {
        ["owner", "jid", "token", "endpoint", "URL", "galleryURL", "baseURL"].forEach {
            XCTAssertFalse(ChatAttachmentMediaUploadTracePrivacyPolicy.shouldIncludeDetail(named: $0))
        }
        XCTAssertTrue(ChatAttachmentMediaUploadTracePrivacyPolicy.shouldIncludeDetail(named: "draftCount"))
        XCTAssertTrue(ChatAttachmentMediaUploadTracePrivacyPolicy.shouldIncludeDetail(named: "conversationType"))
    }

    func testSheetDoesNotShowPreparingBannerForPendingSelectionBeforeSend() {
        let source = Task20SelectionSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let pending = draft(id: "asset:pending", state: .pending)
        let unavailable = draft(id: "asset:gone", state: .unavailable(.photosAccessLost))

        sheet.loadViewIfNeeded()
        source.replaceDrafts([pending])

        XCTAssertTrue(sheet.statusBannerView.isHidden)

        source.replaceDrafts([pending, unavailable])

        XCTAssertFalse(sheet.statusBannerView.isHidden)
        XCTAssertEqual(sheet.statusBannerView.titleLabel.text, "Some attachments need attention")
        XCTAssertEqual(sheet.selectedItemCount, 2)
    }

    func testPreviewShowsUnavailableDraftRetryAndRemoveActions() {
        let unavailable = draft(id: "asset:gone", state: .unavailable(.assetUnavailable))
        let delegate = Task20PreviewDelegate()
        let preview = ChatAttachmentPreviewViewController(drafts: [unavailable])
        preview.delegate = delegate

        preview.loadViewIfNeeded()

        XCTAssertFalse(preview.statusBannerView.isHidden)
        XCTAssertEqual(preview.statusBannerView.titleLabel.text, "Attachment unavailable")
        XCTAssertFalse(preview.statusBannerView.retryButton.isHidden)
        XCTAssertFalse(preview.statusBannerView.removeButton.isHidden)

        preview.statusBannerView.retryButton.sendActions(for: .touchUpInside)
        preview.statusBannerView.removeButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.retryDraftIDs, [unavailable.id])
        XCTAssertEqual(delegate.removedDraftIDs, [unavailable.id])
    }

    func testRetryUnavailableDraftFromPreviewStartsPreparingWithoutChangingOrder() {
        let source = Task20SelectionSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let first = preparedDraft(id: "asset:first")
        let unavailable = draft(id: "asset:gone", state: .unavailable(.iCloudDownloadFailed))

        sheet.loadViewIfNeeded()
        source.replaceDrafts([first, unavailable])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)

        let preview = try! XCTUnwrap(sheet.previewViewController)
        preview.goToNextDraft()
        preview.statusBannerView.retryButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(sheet.selectedAttachmentDrafts.map(\.id), [first.id, unavailable.id])
        XCTAssertEqual(sheet.selectedAttachmentDrafts[1].preparationState, .preparing)
        XCTAssertEqual(sheet.selectedItemCount, 2)
        XCTAssertEqual(preview.currentDraft?.preparationState, .pending)
    }

    func testFileSourceShowsLoadingStateWhileDocumentPickerIsOpen() {
        let presenter = Task20DocumentPickerPresenter()
        let source = ChatAttachmentFileSourceViewController(documentPickerPresenter: presenter)

        source.loadViewIfNeeded()
        source.chooseFilesButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(source.isImportingDocuments)
        XCTAssertFalse(source.errorMessageLabel.isHidden)
        XCTAssertEqual(source.errorMessageLabel.text, "Loading files...")
        XCTAssertFalse(source.chooseFilesButton.isEnabled)

        presenter.complete(.cancelled)

        XCTAssertFalse(source.isImportingDocuments)
        XCTAssertTrue(source.errorMessageLabel.isHidden)
        XCTAssertTrue(source.chooseFilesButton.isEnabled)
    }

    func testCoordinatorKeepsSheetOpenAndShowsSendFeedbackWhenSendIsBlocked() {
        let prepared = preparedDraft(id: "asset:prepared")
        let source = Task20SelectionSourceController(source: .gallery)
        let sendCoordinator = Task20SendCoordinator(result: .blocked(.cloudStorageUnavailable))
        let presenter = UIViewController()
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter,
            context: Self.context,
            sourceControllerFactory: Task20SourceFactory(source: source),
            sendCoordinator: sendCoordinator,
            presentationHandler: { _, _, _, completion in completion?() }
        )
        let delegate = Task20FlowDelegate()
        coordinator.delegate = delegate

        coordinator.start()
        let sheet = try! XCTUnwrap(coordinator.sheetViewController)
        source.replaceDrafts([prepared])
        sheet.selectionComposerBarView.sendButton.sendActions(for: .touchUpInside)

        XCTAssertNotNil(coordinator.sheetViewController)
        XCTAssertEqual(delegate.failures, [])
        XCTAssertFalse(sheet.statusBannerView.isHidden)
        XCTAssertEqual(sheet.statusBannerView.titleLabel.text, "File transfer unavailable")
    }

    func testCloudStoragePendingRetryRequestsSendAgainForPreparedDrafts() {
        let prepared = preparedDraft(id: "asset:prepared")
        let source = Task20SelectionSourceController(source: .gallery)
        let delegate = Task20PickerDelegate()
        let sheet = makeSheet(source: source)
        sheet.delegate = delegate

        sheet.loadViewIfNeeded()
        source.replaceDrafts([prepared])
        sheet.applySendBlockedReason(.cloudStoragePending)
        sheet.statusBannerView.retryButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.requestedDraftIDs, [[prepared.id]])
        XCTAssertTrue(sheet.statusBannerView.isHidden)
    }

    func testCloudStoragePendingRetryFromPreviewRequestsSendAgainInsteadOfRetryingPreparedDraft() {
        let prepared = preparedDraft(id: "asset:prepared")
        let source = Task20SelectionSourceController(source: .gallery)
        let delegate = Task20PickerDelegate()
        let sheet = makeSheet(source: source)
        sheet.delegate = delegate

        sheet.loadViewIfNeeded()
        source.replaceDrafts([prepared])
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        let preview = try! XCTUnwrap(sheet.previewViewController)
        sheet.applySendBlockedReason(.cloudStoragePending)

        preview.statusBannerView.retryButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.requestedDraftIDs, [[prepared.id]])
        XCTAssertEqual(sheet.selectedAttachmentDrafts.first?.preparationState, prepared.preparationState)
        XCTAssertTrue(preview.statusBannerView.isHidden)
    }

    private static let context = ChatAttachmentFlowContext(
        owner: "alice@example.com",
        jid: "bob@example.com",
        conversationType: .regular,
        forwardedMessageIds: []
    )

    private func makeSheet(source: Task20SelectionSourceController) -> ChatAttachmentSheetViewController {
        ChatAttachmentSheetViewController(
            context: Self.context,
            sourceControllerFactory: Task20SourceFactory(source: source),
            previewPresentationHandler: { _, _, _, completion in completion?() },
            previewDismissalHandler: { _, _, completion in completion?() }
        )
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

    private func locationDraft(snapshotURL: URL?) -> AttachmentDraft {
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
}

private final class Task20PreviewDelegate: ChatAttachmentPreviewViewControllerDelegate {
    var removedDraftIDs: [String] = []
    var retryDraftIDs: [String] = []

    func chatAttachmentPreviewViewControllerDidClose(_ preview: ChatAttachmentPreviewViewController) {}

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRemoveDraftWithID draftID: String
    ) {
        removedDraftIDs.append(draftID)
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRetryDraftWithID draftID: String
    ) {
        retryDraftIDs.append(draftID)
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didReplaceDraftWithID draftID: String,
        updatedDraft: AttachmentDraft
    ) {}

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRequestSend drafts: [AttachmentDraft]
    ) {}
}

private final class Task20PickerDelegate: ChatAttachmentPickerViewControllerDelegate {
    private(set) var requestedDraftIDs: [[String]] = []

    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentPickerViewController) {}
    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentPickerViewController) {}

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    ) {
        requestedDraftIDs.append(drafts.map(\.id))
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestPremiumFor owner: String
    ) {}

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didFailWith error: ChatAttachmentFlowError
    ) {}

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didUpdateSelectionCount count: Int
    ) {}
}

private final class Task20SelectionSourceController: UIViewController,
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

    func replaceDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
        onSelectionCountChanged?(drafts.count)
        onSelectedAttachmentDraftsChanged?(drafts)
    }

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
    }

    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        selectedAttachmentDrafts.removeAll { $0.id == draftID }
        onSelectionCountChanged?(selectedAttachmentDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedAttachmentDrafts)
        return selectedAttachmentDrafts
    }

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

private final class Task20SourceFactory: ChatAttachmentSourceControllerFactory {
    let source: Task20SelectionSourceController

    init(source: Task20SelectionSourceController) {
        self.source = source
    }

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        self.source
    }
}

private final class Task20DocumentPickerPresenter: ChatAttachmentDocumentPickerPresenting {
    private var completion: ((ChatAttachmentDocumentPickerResult) -> Void)?

    func presentDocumentPicker(
        from viewController: UIViewController,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        completion: @escaping (ChatAttachmentDocumentPickerResult) -> Void
    ) {
        self.completion = completion
    }

    func complete(_ result: ChatAttachmentDocumentPickerResult) {
        completion?(result)
        completion = nil
    }
}

private final class Task20SendCoordinator: ChatAttachmentSendCoordinating {
    let result: ChatAttachmentSendResult

    init(result: ChatAttachmentSendResult) {
        self.result = result
    }

    func send(
        drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState,
        context: ChatAttachmentFlowContext,
        completion: @escaping (ChatAttachmentSendResult) -> Void
    ) {
        completion(result)
    }
}

private final class Task20FlowDelegate: ChatAttachmentFlowCoordinatorDelegate {
    var failures: [ChatAttachmentFlowError] = []

    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) {}
    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) {}
    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    ) {}
    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    ) {
        failures.append(error)
    }
}
