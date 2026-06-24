import XCTest
@testable import xabber

final class ChatAttachmentMediaPreparationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-task17-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testImagePreparationBuildsPreparedFileOffMainQueue() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let draft = pendingDraft(id: "asset:image-1", mediaKind: .image, filename: "image.jpg")
        let expectation = expectation(description: "prepared")

        var preparedDrafts: [AttachmentDraft] = []
        coordinator.prepare(drafts: [draft]) { drafts in
            preparedDrafts = drafts
            expectation.fulfill()
        }

        loader.complete(
            id: draft.id,
            result: .success(
                ChatAttachmentLoadedMedia(
                    content: .data(Data([1, 2, 3, 4])),
                    referenceURL: URL(fileURLWithPath: "/photos/image-1.jpg"),
                    filename: "image-1.jpg",
                    mediaType: "image/jpeg",
                    mediaKind: .image,
                    dimensions: CGSize(width: 640, height: 480),
                    duration: nil
                )
            )
        )

        wait(for: [expectation], timeout: 2)

        let prepared = try XCTUnwrap(preparedDrafts.first)
        guard case .prepared(let file) = prepared.preparationState else {
            return XCTFail("Expected prepared draft")
        }

        XCTAssertEqual(prepared.id, draft.id)
        XCTAssertEqual(prepared.mediaKind, .image)
        XCTAssertEqual(prepared.dimensions, CGSize(width: 640, height: 480))
        XCTAssertEqual(file.filename, "image-1.jpg")
        XCTAssertEqual(file.byteSize, 4)
        XCTAssertEqual(file.mediaType, "image/jpeg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.localFileURL.path))
        XCTAssertFalse(loader.completionWasDeliveredOnMainThread)
    }

    func testBatchPreparationPreservesDraftOrderWhenLoadsCompleteOutOfOrder() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let first = pendingDraft(id: "asset:first", mediaKind: .image, filename: "first.jpg")
        let second = pendingDraft(id: "asset:second", mediaKind: .image, filename: "second.jpg")
        let expectation = expectation(description: "prepared")
        var preparedIDs: [String] = []

        coordinator.prepare(drafts: [first, second]) { drafts in
            preparedIDs = drafts.map(\.id)
            expectation.fulfill()
        }

        loader.complete(id: second.id, result: .success(loadedData(filename: "second.jpg")))
        loader.complete(id: first.id, result: .success(loadedData(filename: "first.jpg")))

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(preparedIDs, [first.id, second.id])
    }

    func testVideoPreparationPreservesMetadataAndPreview() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let draft = pendingDraft(id: "asset:video-1", mediaKind: .video, filename: "video.mov")
        let sourceURL = try makeFile(named: "source-video.mov", contents: Data([9, 8, 7]))
        let previewURL = try makeFile(named: "preview.jpg", contents: Data([6, 5]))
        let expectation = expectation(description: "prepared")
        var preparedDraft: AttachmentDraft?

        coordinator.prepare(drafts: [draft]) { drafts in
            preparedDraft = drafts.first
            expectation.fulfill()
        }

        loader.complete(
            id: draft.id,
            result: .success(
                ChatAttachmentLoadedMedia(
                    content: .file(sourceURL),
                    referenceURL: URL(fileURLWithPath: "/photos/video-1.mov"),
                    filename: "video-1.mov",
                    mediaType: "video/quicktime",
                    mediaKind: .video,
                    dimensions: CGSize(width: 1920, height: 1080),
                    duration: 72,
                    videoPreviewKey: "preview-key",
                    videoOrientation: "landscapeRight",
                    videoPreviewLocalURL: previewURL
                )
            )
        )

        wait(for: [expectation], timeout: 2)

        let prepared = try XCTUnwrap(preparedDraft)
        guard case .prepared(let file) = prepared.preparationState else {
            return XCTFail("Expected prepared draft")
        }

        XCTAssertEqual(file.duration, 72)
        XCTAssertEqual(file.videoDurationLabel, "1:12")
        XCTAssertEqual(file.videoPreviewKey, "preview-key")
        XCTAssertEqual(file.videoOrientation, "landscapeRight")
        XCTAssertEqual(file.videoPreviewLocalURL, previewURL)
        XCTAssertEqual(file.dimensions, CGSize(width: 1920, height: 1080))
    }

    func testAnimatedImagePreparationPreservesMimeTypeAndData() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let draft = pendingDraft(id: "asset:gif-1", mediaKind: .animatedImage, filename: "anim.gif")
        let expectation = expectation(description: "prepared")
        var preparedDraft: AttachmentDraft?

        coordinator.prepare(drafts: [draft]) { drafts in
            preparedDraft = drafts.first
            expectation.fulfill()
        }

        loader.complete(
            id: draft.id,
            result: .success(
                ChatAttachmentLoadedMedia(
                    content: .data(Data([0x47, 0x49, 0x46])),
                    referenceURL: URL(fileURLWithPath: "/photos/anim.gif"),
                    filename: "anim.gif",
                    mediaType: "image/gif",
                    mediaKind: .animatedImage,
                    dimensions: CGSize(width: 320, height: 240),
                    duration: nil
                )
            )
        )

        wait(for: [expectation], timeout: 2)

        let prepared = try XCTUnwrap(preparedDraft)
        guard case .prepared(let file) = prepared.preparationState else {
            return XCTFail("Expected prepared draft")
        }

        XCTAssertEqual(prepared.mediaKind, .animatedImage)
        XCTAssertEqual(file.mediaType, "image/gif")
        XCTAssertEqual(file.byteSize, 3)
        XCTAssertEqual(try Data(contentsOf: file.localFileURL), Data([0x47, 0x49, 0x46]))
    }

    func testPreparationFailuresMarkDraftUnavailable() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let missing = pendingDraft(id: "asset:missing", mediaKind: .image, filename: "missing.jpg")
        let icloud = pendingDraft(id: "asset:icloud", mediaKind: .image, filename: "icloud.jpg")
        let expectation = expectation(description: "prepared")
        var preparedDrafts: [AttachmentDraft] = []

        coordinator.prepare(drafts: [missing, icloud]) { drafts in
            preparedDrafts = drafts
            expectation.fulfill()
        }

        loader.complete(id: missing.id, result: .failure(.assetUnavailable))
        loader.complete(id: icloud.id, result: .failure(.iCloudDownloadFailed))

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(preparedDrafts.map(\.preparationState), [
            .unavailable(.assetUnavailable),
            .unavailable(.iCloudDownloadFailed)
        ])
        XCTAssertThrowsError(
            try ChatAttachmentReferenceBuilder().makeReferences(
                from: preparedDrafts,
                context: ChatAttachmentFlowContext(
                    owner: "alice@example.com",
                    jid: "bob@example.com",
                    conversationType: .regular,
                    forwardedMessageIds: []
                )
            )
        )
    }

    func testMissingLoadedFileMarksDraftUnreadable() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let draft = pendingDraft(id: "captured:missing-video", mediaKind: .video, filename: "missing.mov")
        let expectation = expectation(description: "prepared")
        var preparedDraft: AttachmentDraft?

        coordinator.prepare(drafts: [draft]) { drafts in
            preparedDraft = drafts.first
            expectation.fulfill()
        }

        loader.complete(
            id: draft.id,
            result: .success(
                ChatAttachmentLoadedMedia(
                    content: .file(temporaryDirectory.appendingPathComponent("does-not-exist.mov")),
                    referenceURL: URL(fileURLWithPath: "/tmp/does-not-exist.mov"),
                    filename: "does-not-exist.mov",
                    mediaType: "video/quicktime",
                    mediaKind: .video,
                    dimensions: nil,
                    duration: nil
                )
            )
        )

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(preparedDraft?.preparationState, .unavailable(.unreadableFile))
    }

    func testCancellationCancelsProviderAndSuppressesCompletion() {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let draft = pendingDraft(id: "asset:cancel", mediaKind: .image, filename: "cancel.jpg")
        let expectation = expectation(description: "cancelled preparation does not complete")
        expectation.isInverted = true

        let task = coordinator.prepare(drafts: [draft]) { _ in
            expectation.fulfill()
        }
        task.cancel()

        wait(for: [expectation], timeout: 0.2)
        XCTAssertEqual(loader.cancelledRequestIDs, [draft.id])
    }

    func testPreparedDraftsAreReturnedWithoutReloading() throws {
        let loader = FakeTask17MediaLoader()
        let coordinator = makeCoordinator(loader: loader)
        let prepared = preparedDraft(id: "file:prepared")
        let expectation = expectation(description: "prepared")
        var preparedDrafts: [AttachmentDraft] = []

        coordinator.prepare(drafts: [prepared]) { drafts in
            preparedDrafts = drafts
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(preparedDrafts, [prepared])
        XCTAssertTrue(loader.requestedDraftIDs.isEmpty)
    }

    func testFailurePolicyMapsLowMemoryToPreparationFailed() {
        XCTAssertEqual(
            ChatAttachmentMediaPreparationFailurePolicy.unavailableReason(for: .lowMemory),
            .preparationFailed
        )
    }

    private func makeCoordinator(loader: FakeTask17MediaLoader) -> ChatAttachmentMediaPreparationCoordinator {
        ChatAttachmentMediaPreparationCoordinator(
            loader: loader,
            fileWriter: ChatAttachmentMediaPreparationFileWriter(
                outputDirectory: temporaryDirectory,
                uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000111")! }
            ),
            processingQueue: DispatchQueue(label: "ChatAttachmentMediaPreparationTests.processing"),
            completionQueue: .main
        )
    }

    private func pendingDraft(
        id: String,
        mediaKind: AttachmentMediaKind,
        filename: String
    ) -> AttachmentDraft {
        AttachmentDraft(
            id: id,
            source: .gallery,
            mediaKind: mediaKind,
            thumbnailState: .none,
            filename: filename,
            byteSize: 0,
            duration: nil,
            dimensions: nil,
            preparationState: .pending
        )
    }

    private func preparedDraft(id: String) -> AttachmentDraft {
        let preparedFile = AttachmentPreparedFile(
            localFileURL: URL(fileURLWithPath: "/tmp/prepared.jpg"),
            referenceURL: URL(fileURLWithPath: "/tmp/prepared.jpg"),
            filename: "prepared.jpg",
            byteSize: 12,
            mediaType: "image/jpeg",
            dimensions: CGSize(width: 10, height: 10),
            duration: nil,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )

        return AttachmentDraft(
            id: id,
            source: .file,
            mediaKind: .image,
            thumbnailState: .available(key: preparedFile.localFileURL.absoluteString),
            filename: preparedFile.filename,
            byteSize: preparedFile.byteSize,
            duration: nil,
            dimensions: preparedFile.dimensions,
            preparationState: .prepared(preparedFile)
        )
    }

    private func loadedData(filename: String) -> ChatAttachmentLoadedMedia {
        ChatAttachmentLoadedMedia(
            content: .data(Data([1])),
            referenceURL: URL(fileURLWithPath: "/photos/\(filename)"),
            filename: filename,
            mediaType: "image/jpeg",
            mediaKind: .image,
            dimensions: CGSize(width: 100, height: 100),
            duration: nil
        )
    }

    private func makeFile(named filename: String, contents: Data) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(filename)
        try contents.write(to: url)
        return url
    }
}

private final class FakeTask17MediaLoader: ChatAttachmentMediaPreparationLoading {
    private(set) var requestedDraftIDs: [String] = []
    private(set) var cancelledRequestIDs: [String] = []
    private(set) var completionWasDeliveredOnMainThread = false
    private var completions: [String: (Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>) -> Void] = [:]

    @discardableResult
    func loadMedia(
        for draft: AttachmentDraft,
        completion: @escaping (Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable {
        requestedDraftIDs.append(draft.id)
        completions[draft.id] = { result in
            self.completionWasDeliveredOnMainThread = Thread.isMainThread
            completion(result)
        }
        return FakeTask17Cancellable { [weak self] in
            self?.cancelledRequestIDs.append(draft.id)
        }
    }

    func complete(
        id: String,
        result: Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>
    ) {
        guard let completion = completions.removeValue(forKey: id) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            completion(result)
        }
    }
}

private final class FakeTask17Cancellable: ChatAttachmentMediaPreparationCancellable {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}
