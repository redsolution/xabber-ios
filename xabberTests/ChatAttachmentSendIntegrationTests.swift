import XCTest
@testable import xabber

@MainActor
final class ChatAttachmentSendIntegrationTests: XCTestCase {
    func testSendButtonDisabledUntilEverySelectedDraftIsPrepared() {
        let pending = draft(id: "asset:pending", state: .pending)
        let prepared = preparedDraft(id: "asset:prepared", filename: "prepared.jpg")

        XCTAssertFalse(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: []))
        XCTAssertFalse(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [pending, prepared]))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [prepared]))

        let preview = ChatAttachmentPreviewViewController(drafts: [prepared])
        preview.loadViewIfNeeded()

        XCTAssertTrue(preview.sendButton.isEnabled)
    }

    func testInlineSheetSendButtonAllowsPendingButBlocksUnavailableAndPreparingDrafts() {
        let pending = draft(id: "asset:pending", state: .pending)
        let prepared = preparedDraft(id: "asset:prepared", filename: "prepared.jpg")
        let preparing = draft(id: "asset:preparing", state: .preparing)
        let unavailable = draft(id: "asset:gone", state: .unavailable(.assetUnavailable))

        XCTAssertFalse(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: []))
        XCTAssertTrue(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: [pending, prepared]))
        XCTAssertFalse(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: [pending, preparing]))
        XCTAssertFalse(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: [pending, unavailable]))
    }

    func testSendScopeUsesWholeSelectedBatchInOrder() {
        let first = preparedDraft(id: "asset:first", filename: "first.jpg")
        let second = preparedDraft(id: "file:second", filename: "second.pdf", mediaKind: .file, mediaType: "application/pdf")

        let scope = ChatAttachmentPreviewSendScopePolicy.draftsForSend(
            from: [first, second],
            activeDraftID: second.id
        )

        XCTAssertEqual(scope.map(\.id), [first.id, second.id])
    }

    func testCaptionMapsToOutgoingBodyForSendContract() {
        let body = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
            caption: "Batch caption",
            conversationType: .regular
        )

        XCTAssertEqual(body.body, "Batch caption")
        XCTAssertEqual(body.legacyBody, "Batch caption")
    }

    func testCloudStorageUnavailableBlocksBeforeQuotaAndSend() {
        let refresher = FakeTask18QuotaRefresher()
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            quotaRefresher: refresher,
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [preparedDraft(id: "asset:image", filename: "image.jpg")]
        )

        XCTAssertEqual(result, .blocked(.cloudStorageUnavailable))
        XCTAssertEqual(refresher.refreshCallCount, 0)
        XCTAssertTrue(sender.requests.isEmpty)
    }

    func testQuotaAvailableStatesAllowSend() {
        let states: [MediaUploadQuotaPolicy.Access] = [
            MediaUploadQuotaPolicy.access(
                subscriptionsEnabled: true,
                hasActiveSubscription: false,
                hasQuotaItem: false,
                quotaBytes: 0,
                totalBytes: 0
            ),
            MediaUploadQuotaPolicy.access(
                subscriptionsEnabled: true,
                hasActiveSubscription: false,
                hasQuotaItem: true,
                quotaBytes: -1,
                totalBytes: 50_000
            ),
            MediaUploadQuotaPolicy.access(
                subscriptionsEnabled: true,
                hasActiveSubscription: false,
                hasQuotaItem: true,
                quotaBytes: 10_000,
                totalBytes: 1_000
            ),
            MediaUploadQuotaPolicy.access(
                subscriptionsEnabled: true,
                hasActiveSubscription: true,
                hasQuotaItem: true,
                quotaBytes: 0,
                totalBytes: 0
            )
        ]

        XCTAssertEqual(states, [.available, .available, .available, .available])
    }

    func testExhaustedNonPremiumQuotaRequestsPremiumAndDoesNotSend() {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [preparedDraft(id: "asset:image", filename: "image.jpg")]
        )

        XCTAssertEqual(result, .premiumRequired(owner: Self.context.owner))
        XCTAssertTrue(sender.requests.isEmpty)
    }

    func testPreparedDraftsBuildReferencesAndSendOnceWithCaption() throws {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(sender: sender)
        let first = preparedDraft(id: "asset:first", filename: "first.jpg")
        let second = preparedDraft(
            id: "file:second",
            filename: "second.pdf",
            mediaKind: .file,
            mediaType: "application/pdf"
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [first, second],
            captionState: ChatAttachmentCaptionState(rawText: "Caption")
        )

        XCTAssertEqual(result, .sent(referenceCount: 2))
        let request = try XCTUnwrap(sender.requests.first)
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(request.references.compactMap(\.filename), ["first.jpg", "second.pdf"])
        XCTAssertEqual(request.body, "Caption")
        XCTAssertEqual(request.legacyBody, "Caption")
        XCTAssertEqual(request.context.forwardedMessageIds, Self.context.forwardedMessageIds)
    }

    func testUnpreparedOrUnavailableDraftsBlockBeforeQuotaRefresh() {
        let refresher = FakeTask18QuotaRefresher()
        let pipeline = makePipeline(quotaRefresher: refresher)
        let unavailable = draft(id: "asset:gone", state: .unavailable(.assetUnavailable))

        let result = sendSynchronously(pipeline: pipeline, drafts: [unavailable])

        XCTAssertEqual(result, .blocked(.unpreparedDrafts))
        XCTAssertEqual(refresher.refreshCallCount, 0)
    }

    func testRetryAttemptsRecheckQuotaEachTime() {
        let refresher = FakeTask18QuotaRefresher()
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(quotaRefresher: refresher, sender: sender)
        let draft = preparedDraft(id: "asset:image", filename: "image.jpg")

        _ = sendSynchronously(pipeline: pipeline, drafts: [draft])
        _ = sendSynchronously(pipeline: pipeline, drafts: [draft])

        XCTAssertEqual(refresher.refreshCallCount, 2)
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testUploadFailuresUseExistingPersistentFailedMessageRetryPath() {
        let failures: [ChatAttachmentUploadFailure] = [
            .httpStatus(403),
            .httpStatus(413),
            .httpStatus(500),
            .network
        ]

        XCTAssertEqual(
            failures.map(ChatAttachmentUploadFailurePolicy.resolution(for:)),
            Array(
                repeating: .persistentFailedMessageRetry,
                count: failures.count
            )
        )
    }

    private func makePipeline(
        isCloudStorageAvailable: Bool = true,
        quotaRefresher: FakeTask18QuotaRefresher = FakeTask18QuotaRefresher(),
        quotaAccessProvider: FakeTask18QuotaAccessProvider = FakeTask18QuotaAccessProvider(accesses: [.available]),
        sender: FakeTask18MediaMessageSender = FakeTask18MediaMessageSender()
    ) -> ChatAttachmentSendPipeline {
        ChatAttachmentSendPipeline(
            cloudStorageAvailabilityProvider: FakeTask18CloudStorageAvailabilityProvider(isAvailable: isCloudStorageAvailable),
            quotaRefresher: quotaRefresher,
            quotaAccessProvider: quotaAccessProvider,
            mediaMessageSender: sender,
            referenceBuilder: ChatAttachmentReferenceBuilder()
        )
    }

    private func sendSynchronously(
        pipeline: ChatAttachmentSendPipeline,
        drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState = ChatAttachmentCaptionState()
    ) -> ChatAttachmentSendResult {
        let expectation = expectation(description: "send")
        var capturedResult: ChatAttachmentSendResult?

        pipeline.send(
            drafts: drafts,
            captionState: captionState,
            context: Self.context
        ) { result in
            capturedResult = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        return capturedResult ?? .blocked(.sendFailed)
    }

    private static let context = ChatAttachmentFlowContext(
        owner: "alice@example.com",
        jid: "bob@example.com",
        conversationType: .regular,
        forwardedMessageIds: ["forwarded-1"]
    )

    private func preparedDraft(
        id: String,
        filename: String,
        mediaKind: AttachmentMediaKind = .image,
        mediaType: String = "image/jpeg"
    ) -> AttachmentDraft {
        let localURL = URL(fileURLWithPath: "/tmp/\(filename)")
        let preparedFile = AttachmentPreparedFile(
            localFileURL: localURL,
            referenceURL: localURL,
            filename: filename,
            byteSize: 32,
            mediaType: mediaType,
            dimensions: mediaKind == .image ? CGSize(width: 10, height: 10) : nil,
            duration: nil,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )

        return draft(
            id: id,
            filename: filename,
            mediaKind: mediaKind,
            byteSize: 32,
            state: .prepared(preparedFile)
        )
    }

    private func draft(
        id: String,
        filename: String = "draft.jpg",
        mediaKind: AttachmentMediaKind = .image,
        byteSize: Int = 0,
        state: AttachmentPreparationState
    ) -> AttachmentDraft {
        AttachmentDraft(
            id: id,
            source: id.hasPrefix("file:") ? .file : .gallery,
            mediaKind: mediaKind,
            thumbnailState: .none,
            filename: filename,
            byteSize: byteSize,
            duration: nil,
            dimensions: nil,
            preparationState: state
        )
    }
}

private final class FakeTask18CloudStorageAvailabilityProvider: ChatAttachmentCloudStorageAvailabilityProviding {
    private let isAvailable: Bool

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func isCloudStorageAvailable(owner: String) -> Bool {
        isAvailable
    }
}

private final class FakeTask18QuotaRefresher: ChatAttachmentQuotaRefreshing {
    private(set) var refreshCallCount = 0

    func refreshQuota(
        owner: String,
        reason: CloudStorageQuotaRefreshReason,
        force: Bool,
        completion: @escaping (CloudStorageQuotaRefreshResult) -> Void
    ) {
        refreshCallCount += 1
        completion(.success)
    }
}

private final class FakeTask18QuotaAccessProvider: ChatAttachmentQuotaAccessProviding {
    private var accesses: [MediaUploadQuotaPolicy.Access]

    init(accesses: [MediaUploadQuotaPolicy.Access]) {
        self.accesses = accesses
    }

    func currentAccess(owner: String) -> MediaUploadQuotaPolicy.Access {
        accesses.isEmpty ? .available : accesses.removeFirst()
    }
}

private final class FakeTask18MediaMessageSender: ChatAttachmentMediaMessageSending {
    struct Request {
        let references: [MessageReferenceStorageItem]
        let body: String
        let legacyBody: String
        let context: ChatAttachmentFlowContext
    }

    private(set) var requests: [Request] = []

    func sendMediaMessage(
        references: [MessageReferenceStorageItem],
        body: String,
        legacyBody: String,
        context: ChatAttachmentFlowContext,
        completion: @escaping (Bool) -> Void
    ) {
        requests.append(
            Request(
                references: references,
                body: body,
                legacyBody: legacyBody,
                context: context
            )
        )
        completion(true)
    }
}
