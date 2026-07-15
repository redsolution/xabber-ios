import MaterialComponents.MDCPalettes
import XCTest
@testable import xabber

@MainActor
final class ChatFileAttachmentPipelineTests: XCTestCase {
    func testPresentationMetadataIsPreparedBeforeBindingAndIsIdempotent() throws {
        let attachment = file(
            primary: "document",
            name: "performance-report.pdf",
            size: 4_096,
            mimeType: "application/pdf"
        )
        let serving = RecordingFileTransferServing()
        let grid = makeGrid(serving: serving)

        grid.configure([attachment], palette: .blue, representedBy: "message")
        let view = try XCTUnwrap(grid.views.first)
        let initialFrame = view.frame

        XCTAssertEqual(attachment.presentation.displayName, "performance-report.pdf")
        XCTAssertEqual(attachment.presentation.formattedSize, "4 KB")
        XCTAssertEqual(attachment.presentation.icon, .pdf)
        XCTAssertEqual(view.metadataBindCount, 1)
        XCTAssertEqual(serving.requests.count, 1)

        grid.updateContent([attachment], palette: .blue, representedBy: "message")

        XCTAssertEqual(view.metadataBindCount, 1)
        XCTAssertEqual(serving.requests.count, 1)
        XCTAssertEqual(view.frame, initialFrame)
    }

    func testDelayedProgressAndCompletionFromOldAttachmentCannotMutateReusedView() throws {
        let serving = RecordingFileTransferServing()
        let grid = makeGrid(serving: serving)
        grid.configure([file(primary: "a")], palette: .blue, representedBy: "message-a")
        let view = try XCTUnwrap(grid.views.first)
        let oldSubscription = try XCTUnwrap(serving.subscriptions.first)

        grid.updateContent([file(primary: "b")], palette: .green, representedBy: "message-b")
        XCTAssertEqual(oldSubscription.cancelCount, 1)
        XCTAssertEqual(view.representedRequest?.containerPrimary, "message-b")
        XCTAssertEqual(view.renderedTransferState, .idle)

        oldSubscription.emit(.transferring(progress: 0.75))
        oldSubscription.emit(.available)

        XCTAssertEqual(view.representedRequest?.referencePrimary, "b")
        XCTAssertEqual(view.renderedTransferState, .idle)
    }

    func testProgressRetryErrorSuccessDoNotChangeGeometryOrGrowSubviewsAndTasks() throws {
        let serving = RecordingFileTransferServing()
        let grid = makeGrid(serving: serving)
        grid.configure([file(primary: "document")], palette: .purple, representedBy: "message")
        let view = try XCTUnwrap(grid.views.first)
        let subscription = try XCTUnwrap(serving.subscriptions.first)
        let initialFrame = view.frame
        let initialSubviewCount = view.subviews.count
        let initialLayerCount = view.layer.sublayers?.count ?? 0

        for state in [
            ChatFileTransferState.transferring(progress: 0.1),
            .failed,
            .transferring(progress: 0.5),
            .available,
            .failed,
            .transferring(progress: 0.9)
        ] {
            subscription.emit(state)
            XCTAssertEqual(view.frame, initialFrame)
            XCTAssertEqual(view.subviews.count, initialSubviewCount)
            XCTAssertEqual(view.layer.sublayers?.count ?? 0, initialLayerCount)
            XCTAssertEqual(serving.activeSubscriptionCount, 1)
        }

        XCTAssertEqual(serving.requests.count, 1)
        XCTAssertEqual(view.renderedTransferState, .transferring(progress: 0.9))
    }

    func testResetCancelsSubscriptionAndClearsProgressState() throws {
        let serving = RecordingFileTransferServing()
        let grid = makeGrid(serving: serving)
        grid.configure([file(primary: "document")], palette: .blue, representedBy: "message")
        let oldView = try XCTUnwrap(grid.views.first)
        let subscription = try XCTUnwrap(serving.subscriptions.first)
        subscription.emit(.transferring(progress: 0.6))

        grid.resetState()

        XCTAssertEqual(subscription.cancelCount, 1)
        XCTAssertEqual(serving.activeSubscriptionCount, 0)
        XCTAssertNil(oldView.representedRequest)
        XCTAssertEqual(oldView.renderedTransferState, .idle)
        XCTAssertTrue(grid.views.isEmpty)
        XCTAssertTrue(grid.subviews.isEmpty)
    }

    func testDisappearanceCancelsSubscriptionAndAppearanceResumesExactlyOnce() throws {
        let serving = RecordingFileTransferServing()
        let grid = makeGrid(serving: serving)
        grid.configure([file(primary: "document")], palette: .blue, representedBy: "message")
        let view = try XCTUnwrap(grid.views.first)
        let firstSubscription = try XCTUnwrap(serving.subscriptions.first)
        firstSubscription.emit(.transferring(progress: 0.4))

        grid.cancelOffscreenWork()

        XCTAssertEqual(firstSubscription.cancelCount, 1)
        XCTAssertEqual(serving.activeSubscriptionCount, 0)
        XCTAssertEqual(view.renderedTransferState, .idle)
        XCTAssertEqual(view.representedRequest?.referencePrimary, "document")

        grid.resumeOnscreenWork()
        grid.resumeOnscreenWork()

        XCTAssertEqual(serving.requests.count, 2)
        XCTAssertEqual(serving.activeSubscriptionCount, 1)
        XCTAssertEqual(view.representedRequest?.referencePrimary, "document")
    }

    func testForwardedFileUsesForwardPrimaryInFullRepresentedIdentity() throws {
        let serving = RecordingFileTransferServing()
        let forwardView = InlineMessageAttachmentView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 100)
        )
        forwardView.filesView.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
        forwardView.filesView.transferPipeline = serving

        forwardView.updateContent(
            MessageAttachment(
                primary: "forward-primary",
                author: "Alexey",
                jid: "alexey@example.com",
                outgoing: false,
                textMessage: nil,
                images: [],
                videos: [],
                files: [file(primary: "forward-file")],
                audios: [],
                timeMarker: NSAttributedString(string: "12:00"),
                subforwards: []
            ),
            palette: .blue
        )

        let request = try XCTUnwrap(serving.requests.first)
        XCTAssertEqual(request.containerPrimary, "forward-primary")
        XCTAssertEqual(request.referencePrimary, "forward-file")
    }

    func testDownloadedOnlyDiffProducesStateOnlyChangeMaskAndNoMediaRequest() {
        let old = datasource(files: [file(primary: "document", downloaded: false)])
        let new = datasource(files: [file(primary: "document", downloaded: true)])
        let size = CGSize(width: 320, height: 72)

        let mask = ChatMessageUpdatePolicy.changeMask(
            old: old,
            new: new,
            oldSize: size,
            newSize: size
        )
        let plan = ChatMessageCellUpdatePlan(changeMask: mask)

        XCTAssertEqual(mask, [.fileTransferState])
        XCTAssertEqual(plan.operations, [.cellBindFileTransferState])
        XCTAssertEqual(plan.mediaRequestCount, 0)
        XCTAssertFalse(plan.rebuildsText)
        XCTAssertFalse(plan.invalidatesLayout)
        XCTAssertFalse(plan.rebindsAttachments)
        XCTAssertFalse(plan.reloadsAvatar)
    }

    func testMimePresentationChangeUsesAttachmentRebindInsteadOfStateOnlyUpdate() {
        let old = datasource(files: [file(
            primary: "document",
            name: "attachment.bin",
            mimeType: "application/octet-stream"
        )])
        let new = datasource(files: [file(
            primary: "document",
            name: "attachment.bin",
            mimeType: "application/pdf"
        )])
        let size = CGSize(width: 320, height: 72)

        let mask = ChatMessageUpdatePolicy.changeMask(
            old: old,
            new: new,
            oldSize: size,
            newSize: size
        )

        XCTAssertTrue(mask.contains(.attachments))
        XCTAssertFalse(mask.contains(.fileTransferState))
    }

    func testPrefetchMetadataNeverStartsFullDocumentDownload() {
        let pipeline = ChatFileAttachmentPipeline()
        let attachments = (0..<100).map { file(primary: "file-\($0)") }

        attachments.forEach { pipeline.prefetchMetadata(for: $0) }

        XCTAssertEqual(pipeline.metrics.metadataPrefetchCount, 100)
        XCTAssertEqual(pipeline.metrics.fullDocumentDownloadCount, 0)
        XCTAssertEqual(pipeline.metrics.activeSubscriptionCount, 0)
    }

    func testPublishedStatesAreNotRetainedAfterObserversDisappear() {
        let pipeline = ChatFileAttachmentPipeline()

        for index in 0..<1_000 {
            let request = file(primary: "file-\(index)")
                .representedRequest(containerPrimary: "message-\(index)")
            let token = pipeline.subscribe(to: request, consumerID: UUID()) { _ in }
            pipeline.publish(.transferring(progress: 0.5), for: request)
            token.cancel()
        }

        XCTAssertEqual(pipeline.metrics.activeSubscriptionCount, 0)
        XCTAssertEqual(pipeline.metrics.retainedStateCount, 0)
        XCTAssertEqual(pipeline.metrics.fullDocumentDownloadCount, 0)
    }

    private func makeGrid(serving: RecordingFileTransferServing) -> InlineFilesGridView {
        let grid = InlineFilesGridView(frame: CGRect(x: 0, y: 0, width: 220, height: 44))
        grid.transferPipeline = serving
        return grid
    }

    private func file(
        primary: String,
        name: String = "document.pdf",
        size: Double = 1_024,
        mimeType: String = "application/pdf",
        downloaded: Bool = false
    ) -> FileAttachment {
        FileAttachment(
            primary: primary,
            url: URL(string: "https://files.example.com/\(primary).pdf"),
            size: size,
            name: name,
            mimeType: mimeType,
            downloaded: downloaded
        )
    }

    private func datasource(files: [FileAttachment]) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: "message",
            jid: "alexey@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "alexey@example.com", displayName: "Alexey"),
            messageId: "message-id",
            sentDate: Date(timeIntervalSince1970: 100),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: false,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "archive",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            locations: [],
            contacts: [],
            files: files,
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }
}

private final class RecordingFileTransferServing: ChatFileTransferServing {
    private(set) var requests: [ChatFileAttachmentRequest] = []
    private(set) var subscriptions: [RecordingFileTransferSubscription] = []

    var activeSubscriptionCount: Int {
        subscriptions.filter { $0.cancelCount == 0 }.count
    }

    func subscribe(
        to request: ChatFileAttachmentRequest,
        consumerID: UUID,
        receive: @escaping (ChatFileTransferState) -> Void
    ) -> ChatFileTransferSubscription {
        let subscription = RecordingFileTransferSubscription(receive: receive)
        requests.append(request)
        subscriptions.append(subscription)
        return subscription
    }

    func publish(_ state: ChatFileTransferState, for request: ChatFileAttachmentRequest) {}
}

private final class RecordingFileTransferSubscription: ChatFileTransferSubscription {
    private var receive: ((ChatFileTransferState) -> Void)?
    private(set) var cancelCount = 0

    init(receive: @escaping (ChatFileTransferState) -> Void) {
        self.receive = receive
    }

    func emit(_ state: ChatFileTransferState) {
        receive?(state)
    }

    func cancel() {
        guard receive != nil else { return }
        cancelCount += 1
        receive = nil
    }
}
