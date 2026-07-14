import XCTest
@testable import xabber

final class ChatDisplayRevisionCancellationTests: XCTestCase {
    func testSequentialFifteenHundredRowsReuseRichModelsWithoutLinearLRUWork() {
        let cache = ChatDisplayModelCache(capacity: 2_048)
        let context = makeContext()
        var buildCount = 0

        for index in 0..<1_500 {
            _ = cache.model(for: makeKey(index: index, context: context)) {
                buildCount += 1
                return makeModel(body: "row-\(index)")
            }
        }
        let firstPass = cache.statistics

        for index in 0..<1_500 {
            _ = cache.model(for: makeKey(index: index, context: context)) {
                buildCount += 1
                return makeModel(body: "rebuilt-\(index)")
            }
        }
        let secondPass = cache.statistics
        let secondPassHits = secondPass.hits - firstPass.hits
        let hitRate = Double(secondPassHits) / 1_500.0

        XCTAssertEqual(buildCount, 1_500)
        XCTAssertGreaterThanOrEqual(hitRate, 0.95)
        XCTAssertEqual(secondPass.entryCount, 1_500)
        XCTAssertEqual(secondPass.linearRecencyScanSteps, 0)
    }

    func testReceiptChromeDoesNotChangeRichStorageRevision() {
        let message = makeMessage(primary: "receipt", body: "unchanged rich body")
        let original = ChatMessageRichStorageRevision.capture(
            message,
            revealedSensitiveMediaPrimaries: []
        )
        let originalChrome = ChatMessageChromeStorageRevision.capture(message)

        message.state = .read
        message.isRead = true
        message.messageError = "receipt chrome"
        message.errorMetadata = ["code": 200]
        let receipt = ChatMessageRichStorageRevision.capture(
            message,
            revealedSensitiveMediaPrimaries: []
        )
        let receiptChrome = ChatMessageChromeStorageRevision.capture(message)

        XCTAssertEqual(original, receipt)
        XCTAssertNotEqual(originalChrome, receiptChrome)

        message.body = "edited rich body"
        let edited = ChatMessageRichStorageRevision.capture(
            message,
            revealedSensitiveMediaPrimaries: []
        )
        XCTAssertNotEqual(original, edited)
    }

    func testSensitiveRevealRevisionInvalidatesOnlyOwningMessage() {
        let first = makeMessage(primary: "first", body: "one")
        first.references.append(makeSensitiveReference(primary: "first-media"))
        let second = makeMessage(primary: "second", body: "two")
        second.references.append(makeSensitiveReference(primary: "second-media"))

        let firstHidden = ChatMessageRichStorageRevision.capture(first, revealedSensitiveMediaPrimaries: [])
        let secondHidden = ChatMessageRichStorageRevision.capture(second, revealedSensitiveMediaPrimaries: [])
        let revealed = Set(["first-media"])
        let firstRevealed = ChatMessageRichStorageRevision.capture(first, revealedSensitiveMediaPrimaries: revealed)
        let secondUnrelated = ChatMessageRichStorageRevision.capture(second, revealedSensitiveMediaPrimaries: revealed)

        XCTAssertNotEqual(firstHidden, firstRevealed)
        XCTAssertEqual(secondHidden, secondUnrelated)
    }

    func testCancellationStopsObsoleteWorkWithinThirtyTwoRows() {
        let coordinator = ChatDatasetMappingJobCoordinator(cancellationCheckInterval: 16)
        let obsolete = coordinator.begin(generation: 1)

        for _ in 0..<7 {
            XCTAssertTrue(obsolete.shouldProcessNextRow())
        }
        let current = coordinator.begin(generation: 2)
        while obsolete.shouldProcessNextRow() {}

        XCTAssertTrue(obsolete.isCancelled)
        XCTAssertLessThanOrEqual(obsolete.statistics.rowsProcessedAfterCancellation, 32)
        XCTAssertTrue(current.shouldProcessNextRow())
    }

    func testNewConcurrentMappingJobDoesNotWaitBehindBlockedObsoleteJob() {
        let queue = ChatDatasetMappingQueueFactory.make(label: "ChatDisplayRevisionCancellationTests.concurrent")
        let obsoleteStarted = expectation(description: "obsolete started")
        let currentFinished = expectation(description: "current finished without waiting")
        let releaseObsolete = DispatchSemaphore(value: 0)

        queue.async {
            obsoleteStarted.fulfill()
            releaseObsolete.wait()
        }
        wait(for: [obsoleteStarted], timeout: 1)

        queue.async {
            currentFinished.fulfill()
        }
        wait(for: [currentFinished], timeout: 1)
        releaseObsolete.signal()
    }

    func testLifecycleCancellationDoesNotRetainControllerOrPermitCurrentToken() {
        weak var weakController: ChatViewController?
        var token: ChatDatasetMappingCancellationToken?

        autoreleasepool {
            var controller: ChatViewController? = ChatViewController()
            weakController = controller
            token = controller?.beginDatasetMappingJobForTesting()
            controller?.cancelDatasetMappingJobs()
            controller = nil
        }

        XCTAssertTrue(token?.isCancelled == true)
        XCTAssertNil(weakController)
    }

    func testRecursiveForwardDepthCycleAndBytesProduceBoundedPlaceholder() {
        let deepRoot = makeForward(primary: "depth-0", body: "root")
        var cursor = deepRoot
        for depth in 1...12 {
            let child = makeForward(primary: "depth-\(depth)", body: "nested")
            cursor.subforwards.append(child)
            cursor = child
        }
        let depthSnapshot = ChatMessageForwardSnapshot(
            deepRoot,
            limits: ChatForwardSnapshotLimits(maxDepth: 3, maxNodes: 8, maxBytes: 4_096)
        )

        let cycle = makeForward(primary: "cycle", body: "cycle")
        cycle.subforwards.append(cycle)
        let cycleSnapshot = ChatMessageForwardSnapshot(
            cycle,
            limits: ChatForwardSnapshotLimits(maxDepth: 8, maxNodes: 16, maxBytes: 4_096)
        )

        let oversized = makeForward(primary: "oversized", body: String(repeating: "x", count: 2_048))
        let oversizedSnapshot = ChatMessageForwardSnapshot(
            oversized,
            limits: ChatForwardSnapshotLimits(maxDepth: 8, maxNodes: 16, maxBytes: 128)
        )
        let nodeRoot = makeForward(primary: "node-0", body: "root")
        var nodeCursor = nodeRoot
        for index in 1...10 {
            let child = makeForward(primary: "node-\(index)", body: "node")
            nodeCursor.subforwards.append(child)
            nodeCursor = child
        }
        let nodeSnapshot = ChatMessageForwardSnapshot(
            nodeRoot,
            limits: ChatForwardSnapshotLimits(maxDepth: 20, maxNodes: 3, maxBytes: 4_096)
        )

        XCTAssertTrue(depthSnapshot.containsTruncatedContent)
        XCTAssertLessThanOrEqual(depthSnapshot.maximumObservedDepth, 3)
        XCTAssertLessThanOrEqual(depthSnapshot.nodeCount, 8)
        XCTAssertTrue(forwardBodies(depthSnapshot).contains { $0.contains("unavailable") })
        XCTAssertTrue(cycleSnapshot.containsTruncatedContent)
        XCTAssertTrue(oversizedSnapshot.containsTruncatedContent)
        XCTAssertTrue(oversizedSnapshot.body.contains("unavailable"))
        XCTAssertTrue(nodeSnapshot.containsTruncatedContent)
        XCTAssertLessThanOrEqual(nodeSnapshot.nodeCount, 3)
        XCTAssertTrue(forwardBodies(nodeSnapshot).contains { $0.contains("unavailable") })
    }

    func testMemoryWarningClearsDisplayModelsAndCancelsMappingJob() {
        let controller = ChatViewController()
        let token = controller.beginDatasetMappingJobForTesting()
        _ = controller.displayModelCache.model(for: makeKey(index: 0, context: makeContext())) {
            self.makeModel(body: "cached")
        }
        XCTAssertEqual(controller.displayModelCache.statistics.entryCount, 1)

        controller.didReceiveMemoryWarning()

        XCTAssertEqual(controller.displayModelCache.statistics.entryCount, 0)
        XCTAssertTrue(token.isCancelled)
    }

    func testCacheInvalidationDoesNotAllowAnInFlightBuildToRepopulateEntries() {
        let cache = ChatDisplayModelCache(capacity: 8)
        let buildStarted = expectation(description: "build started")
        let buildFinished = expectation(description: "build finished")
        let releaseBuild = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = cache.model(for: self.makeKey(index: 1, context: self.makeContext())) {
                buildStarted.fulfill()
                releaseBuild.wait()
                return self.makeModel(body: "late")
            }
            buildFinished.fulfill()
        }
        wait(for: [buildStarted], timeout: 1)

        cache.removeAll()
        releaseBuild.signal()
        wait(for: [buildFinished], timeout: 1)

        XCTAssertEqual(cache.statistics.entryCount, 0)
    }

    func testQueuedMappingClosureKeepsOnlyWeakControllerOwnership() {
        let queue = ChatDatasetMappingQueueFactory.make(label: "ChatDisplayRevisionCancellationTests.weak")
        let queuedFinished = expectation(description: "queued closure finished")
        let releaseQueue = DispatchSemaphore(value: 0)
        weak var weakController: ChatViewController?
        var controller: ChatViewController? = ChatViewController()
        weakController = controller
        let token = controller!.beginDatasetMappingJobForTesting()

        queue.async { [weak controller] in
            releaseQueue.wait()
            if !token.isCancelled {
                _ = controller?.owner
            }
            queuedFinished.fulfill()
        }
        controller?.cancelDatasetMappingJobs()
        controller = nil

        XCTAssertNil(weakController)
        releaseQueue.signal()
        wait(for: [queuedFinished], timeout: 1)
    }

    private func makeMessage(primary: String, body: String) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = "owner@example.com"
        message.opponent = "juliet@example.com"
        message.conversationType = .regular
        message.messageId = "\(primary)-message-id"
        message.archivedId = "\(primary)-archive-id"
        message.body = body
        message.legacyBody = body
        message.date = Date(timeIntervalSince1970: 1_700_000_000)
        message.sentDate = message.date
        message.displayAs = .text
        message.state = .deliver
        return message
    }

    private func makeSensitiveReference(primary: String) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = primary
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.url = "https://files.example.com/\(primary).jpg"
        reference.metadata = ["media-type": "image/jpeg", "pcm": "0.1 0.2 0.3"]
        reference.isSensitive = true
        reference.isSensitiveChecked = true
        return reference
    }

    private func makeForward(primary: String, body: String) -> MessageForwardsInlineStorageItem {
        let forward = MessageForwardsInlineStorageItem()
        forward.primary = primary
        forward.messageId = "\(primary)-message-id"
        forward.owner = "owner@example.com"
        forward.opponent = "juliet@example.com"
        forward.jid = "juliet@example.com"
        forward.parentId = "parent-\(primary)"
        forward.body = body
        forward.forwardJid = "juliet@example.com"
        forward.forwardNickname = "Juliet"
        forward.originalDate = Date(timeIntervalSince1970: 1_700_000_050)
        return forward
    }

    private func forwardBodies(_ snapshot: ChatMessageForwardSnapshot) -> [String] {
        [snapshot.body] + snapshot.subforwards.flatMap(forwardBodies)
    }

    private func makeContext() -> ChatDisplayModelCacheContext {
        ChatDisplayModelCacheContext(
            searchText: nil,
            localeIdentifier: "en_US",
            contentSizeCategory: "medium",
            bodyFontName: "body",
            bodyFontPointSize: 17,
            interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue
        )
    }

    private func makeKey(index: Int, context: ChatDisplayModelCacheContext) -> ChatDisplayModelCacheKey {
        ChatDisplayModelCacheKey(
            messagePrimary: "message-\(index)",
            displayRevision: "revision-\(index)",
            context: context
        )
    }

    private func makeModel(body: String) -> ChatCachedDisplayModel {
        ChatCachedDisplayModel(
            kind: .attributedText(NSAttributedString(string: body)),
            mappedReferences: .empty,
            lazyForwards: .eager([]),
            isDownloaded: true,
            timeMarkerText: NSAttributedString(string: "12:00")
        )
    }
}
