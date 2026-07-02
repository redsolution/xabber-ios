import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ChatAttachmentSendIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()

        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatAttachmentSendIntegrationTests-\(name)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    func testSendButtonDisabledUntilEverySelectedDraftIsPrepared() {
        let pending = draft(id: "asset:pending", state: .pending)
        let prepared = preparedDraft(id: "asset:prepared", filename: "prepared.jpg")

        XCTAssertFalse(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: []))
        XCTAssertFalse(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [pending, prepared]))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [prepared]))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [locationDraft(snapshotURL: nil)]))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [locationDraft()]))

        let preview = ChatAttachmentPreviewViewController(drafts: [prepared])
        preview.loadViewIfNeeded()

        XCTAssertTrue(preview.sendButton.isEnabled)
    }

    func testInlineSheetSendButtonRequiresPreparedDrafts() {
        let pending = draft(id: "asset:pending", state: .pending)
        let prepared = preparedDraft(id: "asset:prepared", filename: "prepared.jpg")
        let preparing = draft(id: "asset:preparing", state: .preparing)
        let unavailable = draft(id: "asset:gone", state: .unavailable(.assetUnavailable))

        XCTAssertFalse(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: []))
        XCTAssertFalse(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: [pending, prepared]))
        XCTAssertTrue(ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: [prepared]))
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

    func testAllCloudStorageFileDraftsSkipAvailabilityQuotaAndPostSendRefresh() throws {
        let refresher = FakeTask18QuotaRefresher()
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            quotaRefresher: refresher,
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [cloudFileDraft(id: 7, filename: "report.pdf")]
        )

        XCTAssertEqual(result, .sent(referenceCount: 1))
        XCTAssertEqual(refresher.refreshCallCount, 0)
        let request = try XCTUnwrap(sender.requests.first)
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(request.references.first).isUploaded)
        XCTAssertEqual(request.references.first?.downloadUrl?.absoluteString, "https://gallery.example/files/report.pdf")
    }

    func testLocationDraftsSkipAvailabilityQuotaAndPostSendRefresh() throws {
        let refresher = FakeTask18QuotaRefresher()
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            quotaRefresher: refresher,
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [locationDraft()]
        )

        XCTAssertEqual(result, .sent(referenceCount: 1))
        XCTAssertEqual(refresher.refreshCallCount, 0)
        let request = try XCTUnwrap(sender.requests.first)
        let reference = try XCTUnwrap(request.references.first)
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(reference.kind, .geoloc)
        XCTAssertTrue(reference.isUploaded)
        XCTAssertNil(reference.localFileUrl)
        XCTAssertNil(reference.downloadUrl)
        XCTAssertEqual(request.body, "geo:51.5007,-0.1246")
        XCTAssertEqual(request.legacyBody, "geo:51.5007,-0.1246")
    }

    func testLocationDraftIgnoresStaleCaptionAndSendsOnlyGeoFallback() throws {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [locationDraft()],
            captionState: ChatAttachmentCaptionState(rawText: "Westminster")
        )

        XCTAssertEqual(result, .sent(referenceCount: 1))
        let request = try XCTUnwrap(sender.requests.first)
        XCTAssertEqual(request.body, "geo:51.5007,-0.1246")
        XCTAssertEqual(request.legacyBody, "geo:51.5007,-0.1246")
        XCTAssertEqual(request.references.first?.begin, 0)
        XCTAssertEqual(request.references.first?.end, request.body.xmlEscaping(reverse: false).count)
    }

    func testContactDraftsSkipAvailabilityQuotaAndPostSendRefresh() throws {
        let refresher = FakeTask18QuotaRefresher()
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            quotaRefresher: refresher,
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [contactDraft()]
        )

        XCTAssertEqual(result, .sent(referenceCount: 1))
        XCTAssertEqual(refresher.refreshCallCount, 0)
        let request = try XCTUnwrap(sender.requests.first)
        let reference = try XCTUnwrap(request.references.first)
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertFalse(request.requiresUpload)
        XCTAssertEqual(reference.kind, .contact)
        XCTAssertTrue(reference.isUploaded)
        XCTAssertNil(reference.localFileUrl)
        XCTAssertNil(reference.downloadUrl)
        XCTAssertEqual(request.body, "Alice Capulet (alice@example.com)")
        XCTAssertEqual(request.legacyBody, "Alice Capulet (alice@example.com)")
        XCTAssertEqual(reference.begin, 0)
        XCTAssertEqual(reference.end, request.body.xmlEscaping(reverse: false).count)
    }

    func testContactDraftWithCaptionSendsCaptionAndFallbackWithoutUpload() throws {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [contactDraft()],
            captionState: ChatAttachmentCaptionState(rawText: "Meet this contact")
        )

        XCTAssertEqual(result, .sent(referenceCount: 1))
        let request = try XCTUnwrap(sender.requests.first)
        let reference = try XCTUnwrap(request.references.first)
        XCTAssertFalse(request.requiresUpload)
        XCTAssertEqual(request.body, "Meet this contact\nAlice Capulet (alice@example.com)")
        XCTAssertEqual(request.legacyBody, request.body)
        XCTAssertEqual(reference.begin, "Meet this contact".xmlEscaping(reverse: false).count)
        XCTAssertEqual(reference.end, request.body.xmlEscaping(reverse: false).count)
    }

    func testMixedLocalAndCloudDraftsKeepCloudStorageAvailabilityGate() {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [
                cloudFileDraft(id: 7, filename: "report.pdf"),
                preparedDraft(id: "file:local", filename: "local.pdf", mediaKind: .file, mediaType: "application/pdf")
            ]
        )

        XCTAssertEqual(result, .blocked(.cloudStorageUnavailable))
        XCTAssertTrue(sender.requests.isEmpty)
    }

    func testMixedLocalAndLocationDraftsKeepCloudStorageAvailabilityGate() {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            isCloudStorageAvailable: false,
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [
                locationDraft(),
                preparedDraft(id: "file:local", filename: "local.pdf", mediaKind: .file, mediaType: "application/pdf")
            ]
        )

        XCTAssertEqual(result, .blocked(.cloudStorageUnavailable))
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

    func testExhaustedNonPremiumQuotaRequestsCloudStorageManagementAndDoesNotSend() {
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(
            quotaAccessProvider: FakeTask18QuotaAccessProvider(accesses: [.premiumRequired]),
            sender: sender
        )

        let result = sendSynchronously(
            pipeline: pipeline,
            drafts: [preparedDraft(id: "asset:image", filename: "image.jpg")]
        )

        XCTAssertEqual(result, .cloudStorageQuotaExceeded(owner: Self.context.owner))
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
        XCTAssertTrue(request.requiresUpload)
        XCTAssertEqual(request.references.compactMap(\.filename), ["first.jpg", "second.pdf"])
        XCTAssertEqual(request.body, "Caption")
        XCTAssertEqual(request.legacyBody, "Caption")
        XCTAssertEqual(request.context.forwardedMessageIds, Self.context.forwardedMessageIds)
    }

    func testPreparedDraftSendCompletesBeforeQuotaRefreshFinishes() throws {
        let refresher = FakeTask18QuotaRefresher(automaticallyCompletes: false)
        let sender = FakeTask18MediaMessageSender()
        let pipeline = makePipeline(quotaRefresher: refresher, sender: sender)
        let sendExpectation = expectation(description: "send completes before quota refresh")
        var capturedResult: ChatAttachmentSendResult?

        pipeline.send(
            drafts: [preparedDraft(id: "asset:image", filename: "image.jpg")],
            captionState: ChatAttachmentCaptionState(rawText: "Caption"),
            context: Self.context
        ) { result in
            capturedResult = result
            sendExpectation.fulfill()
        }

        wait(for: [sendExpectation], timeout: 0.1)

        XCTAssertEqual(capturedResult, .sent(referenceCount: 1))
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(refresher.refreshCallCount, 1)
        XCTAssertEqual(refresher.pendingCompletionCount, 1)

        refresher.completePending()
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

    func testWillSendMediaMessageWithCaptionCreatesUploadingRowBeforeUploadContinuation() throws {
        let manager = MessageManager(withOwner: Self.context.owner, activeStream: false)
        let reference = mediaReference(filename: "image.jpg")

        let primary = manager.willSendMediaMessage(
            [reference],
            to: Self.context.jid,
            forwarded: Self.context.forwardedMessageIds,
            conversationType: Self.context.conversationType,
            body: "Caption",
            legacyBody: "Caption"
        )

        let realm = try WRealm.safe()
        let messagePrimary = try XCTUnwrap(primary)
        let stored = try XCTUnwrap(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: messagePrimary
            )
        )
        XCTAssertEqual(stored.owner, Self.context.owner)
        XCTAssertEqual(stored.opponent, Self.context.jid)
        XCTAssertEqual(stored.conversationType, Self.context.conversationType)
        XCTAssertEqual(stored.state, .uploading)
        XCTAssertEqual(stored.body, "Caption")
        XCTAssertEqual(stored.legacyBody, "Caption")
        XCTAssertEqual(stored.references.count, 1)
        XCTAssertEqual(stored.references.first?.messageId, stored.primary)
        XCTAssertEqual(stored.references.first?.owner, Self.context.owner)
        XCTAssertEqual(stored.references.first?.jid, Self.context.jid)
        XCTAssertEqual(stored.references.first?.filename, "image.jpg")
    }

    func testSendSimpleMessageWithUploadedCloudFileBuildsDeliveryFallbackBody() throws {
        let manager = MessageManager(withOwner: Self.context.owner, activeStream: false)
        let remoteURL = "https://gallery.example/files/0KDMUitNQAVC/xabber-logs-20260610-104152-anomaly-warn.zip"
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.mimeType = "file"
        reference.isUploaded = true
        reference.url = remoteURL
        reference.metadata = [
            "filename": "xabber-logs-20260610-104152-anomaly-warn.zip",
            "size": 152922,
            "media-type": "application/zip",
            "uri": remoteURL,
            "name": "xabber-logs-20260610-104152-anomaly-warn.zip",
            "hash": "ef0e8bbe0777e7d431c72baddc5d0e6046401b95"
        ]

        let originId = manager.sendSimpleMessage(
            "",
            to: Self.context.jid,
            forwarded: [],
            conversationType: Self.context.conversationType,
            references: [reference]
        )

        let realm = try WRealm.safe()
        let stored = try XCTUnwrap(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: MessageStorageItem.genPrimary(messageId: originId, owner: Self.context.owner)
            )
        )
        let stanzaRow = try XCTUnwrap(
            realm.object(
                ofType: MessageStanzaStorageItem.self,
                forPrimaryKey: "\(stored.primary)_stanza"
            )
        )
        let document = try DDXMLDocument(xmlString: stanzaRow.stanza, options: 0)
        let stanzaElement = try XCTUnwrap(document.rootElement())
        let stanza = XMPPMessage(from: stanzaElement)

        XCTAssertEqual(stored.body, "")
        XCTAssertEqual(stored.legacyBody, "\(remoteURL)\n")
        XCTAssertEqual(stored.references.first?.begin, 0)
        XCTAssertGreaterThan(stored.references.first?.end ?? 0, remoteURL.count)
        XCTAssertEqual(stanza.body, "\(remoteURL)\n")
    }

    func testWillSendMediaMessageWithCaptionReturnsNilForEmptyAttachmentsAndCreatesNoRow() throws {
        let manager = MessageManager(withOwner: Self.context.owner, activeStream: false)

        let primary = manager.willSendMediaMessage(
            [],
            to: Self.context.jid,
            forwarded: [],
            conversationType: Self.context.conversationType,
            body: "Caption",
            legacyBody: "Caption"
        )

        let realm = try WRealm.safe()
        XCTAssertNil(primary)
        XCTAssertTrue(realm.objects(MessageStorageItem.self).isEmpty)
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

    private func cloudFileDraft(id: Int, filename: String) -> AttachmentDraft {
        ChatAttachmentCloudStorageFile(
            id: id,
            remoteURL: URL(string: "https://gallery.example/files/\(filename)")!,
            filename: filename,
            byteSize: 32,
            mediaType: "application/pdf",
            hash: "hash-\(id)",
            createdAt: nil,
            metadata: nil
        ).makeAttachmentDraft()
    }

    private func locationDraft(
        snapshotURL: URL? = URL(fileURLWithPath: "/tmp/location-snapshot.png")
    ) -> AttachmentDraft {
        let location = AttachmentPreparedLocation(
            coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
            displayAddress: "Westminster",
            accuracy: 12.5,
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

    private func contactDraft() -> AttachmentDraft {
        let contact = AttachmentPreparedContact(
            jid: "alice@example.com",
            nickname: "Alice",
            given: "Alice",
            family: "Capulet",
            displayTitle: "Alice Capulet",
            avatarURL: "https://example.com/avatars/alice.png",
            avatarMetadata: [
                "avatar_id": "avatar-hash",
                "avatar_type": "image/png"
            ]
        )
        return AttachmentDraft(
            id: "contact:\(contact.jid)",
            source: .contact,
            mediaKind: .contact,
            thumbnailState: .none,
            filename: contact.displayTitle,
            byteSize: 0,
            duration: nil,
            dimensions: nil,
            preparationState: .preparedContact(contact)
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

    private func mediaReference(filename: String) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.metadata = [
            "filename": filename,
            "size": 32,
            "media-type": "image/jpeg",
            "uri": "file:///tmp/\(filename)",
            "name": filename
        ]
        reference.localFileUrl = URL(fileURLWithPath: "/tmp/\(filename)")
        reference.conversationType = Self.context.conversationType
        return reference
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
    private let automaticallyCompletes: Bool
    private(set) var refreshCallCount = 0
    private var pendingCompletions: [(CloudStorageQuotaRefreshResult) -> Void] = []

    var pendingCompletionCount: Int {
        pendingCompletions.count
    }

    init(automaticallyCompletes: Bool = true) {
        self.automaticallyCompletes = automaticallyCompletes
    }

    func refreshQuota(
        owner: String,
        reason: CloudStorageQuotaRefreshReason,
        force: Bool,
        completion: @escaping (CloudStorageQuotaRefreshResult) -> Void
    ) {
        refreshCallCount += 1
        if automaticallyCompletes {
            completion(.success)
        } else {
            pendingCompletions.append(completion)
        }
    }

    func completePending(result: CloudStorageQuotaRefreshResult = .success) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0(result) }
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
        let requiresUpload: Bool
        let context: ChatAttachmentFlowContext
    }

    private(set) var requests: [Request] = []

    func sendMediaMessage(
        references: [MessageReferenceStorageItem],
        body: String,
        legacyBody: String,
        requiresUpload: Bool,
        context: ChatAttachmentFlowContext,
        completion: @escaping (Bool) -> Void
    ) {
        requests.append(
            Request(
                references: references,
                body: body,
                legacyBody: legacyBody,
                requiresUpload: requiresUpload,
                context: context
            )
        )
        completion(true)
    }
}
