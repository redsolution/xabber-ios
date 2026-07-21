import XCTest
@testable import xabber

final class ChatLifecycleMemoryDiagnosticsTests: XCTestCase {
    override func tearDown() {
        ChatArchiveDebugTrace.resetTestingConfiguration()
        ChatHistoryLoadActivityRegistry.resetForTests()
        super.tearDown()
    }

    func testResourceBudgetsAreCentralizedAndBounded() {
        XCTAssertEqual(ChatPerformanceResourceBudgets.timelineTargetPageMultiplier, 5)
        XCTAssertEqual(ChatPerformanceResourceBudgets.timelineHardPageMultiplier, 6)
        XCTAssertEqual(ChatPerformanceResourceBudgets.displayModelCount, 2_048)
        XCTAssertEqual(ChatPerformanceResourceBudgets.layoutCount, 2_048)
        XCTAssertEqual(ChatPerformanceResourceBudgets.thumbnailCount, 192)
        XCTAssertEqual(ChatPerformanceResourceBudgets.thumbnailMemoryBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(ChatPerformanceResourceBudgets.thumbnailConcurrentWork, 4)
        XCTAssertEqual(ChatPerformanceResourceBudgets.thumbnailQueuedWork, 48)
        XCTAssertEqual(ChatPerformanceResourceBudgets.locationDiskEntryCount, 96)
        XCTAssertEqual(ChatPerformanceResourceBudgets.locationDiskBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(ChatPerformanceResourceBudgets.locationTTL, 7 * 24 * 60 * 60)
        XCTAssertEqual(ChatPerformanceResourceBudgets.locationConcurrentWork, 2)
        XCTAssertEqual(ChatPerformanceResourceBudgets.locationQueuedWork, 24)
        XCTAssertEqual(ChatPerformanceResourceBudgets.generatedAvatarCount, 256)
        XCTAssertEqual(ChatPerformanceResourceBudgets.waveformArtifactCount, 256)
    }

    func testDisabledArchiveTraceDoesNotEvaluateEventOrPayload() {
        var eventEvaluationCount = 0
        var payloadEvaluationCount = 0
        ChatArchiveDebugTrace.configureForTesting(
            enabled: false,
            sampleEvery: 1,
            sink: { _ in XCTFail("disabled trace emitted") }
        )

        ChatArchiveDebugTrace.log(
            {
                eventEvaluationCount += 1
                return "disabled-event"
            }(),
            {
                payloadEvaluationCount += 1
                return [("count", 1)]
            }()
        )

        XCTAssertEqual(eventEvaluationCount, 0)
        XCTAssertEqual(payloadEvaluationCount, 0)
    }

    func testArchiveTraceIsSampledAndDropsEveryStringIdentityField() {
        var lines: [String] = []
        ChatArchiveDebugTrace.configureForTesting(
            enabled: true,
            sampleEvery: 2,
            sink: { lines.append($0) }
        )

        for index in 0..<6 {
            ChatArchiveDebugTrace.log("sample-event", [
                ("owner", "private-owner@example.com"),
                ("jid", "private-chat@example.com"),
                ("body", "private body"),
                ("url", "https://private.example/file"),
                ("path", "/private/path"),
                ("queryId", "private-query"),
                ("messagePrimary", "private-primary"),
                ("archiveId", "private-archive"),
                ("count", index),
                ("finished", true)
            ])
        }

        XCTAssertEqual(lines.count, 3)
        let output = lines.joined(separator: "\n")
        XCTAssertTrue(output.contains("count="))
        XCTAssertTrue(output.contains("finished=true"))
        [
            "private-owner", "private-chat", "private body", "private.example",
            "/private/path", "private-query", "private-primary", "private-archive"
        ].forEach { XCTAssertFalse(output.contains($0), "leaked: \($0)") }
    }

    func testArchiveTraceSampleRateCanBeMadeDeterministicForManualAcceptance() {
        XCTAssertEqual(
            ChatArchiveDebugTrace.resolvedSampleEvery(environment: [
                ChatArchiveDebugTrace.sampleEveryEnvironmentKey: "1"
            ]),
            1
        )
        XCTAssertEqual(
            ChatArchiveDebugTrace.resolvedSampleEvery(environment: [
                ChatArchiveDebugTrace.sampleEveryEnvironmentKey: "0"
            ]),
            ChatArchiveDebugTrace.productionSampleEvery
        )
        XCTAssertEqual(
            ChatArchiveDebugTrace.resolvedSampleEvery(environment: [:]),
            ChatArchiveDebugTrace.productionSampleEvery
        )
    }

    func testTwentyCyclePlateauAcceptsTenPercentAndRejectsGrowthBeyondBudget() {
        let stable = ChatMemoryPlateauDiagnostics.evaluate(
            samples: [100, 112, 108, 105, 104, 103, 104, 105, 104, 105, 104, 104, 105, 104, 105, 105, 104, 105, 104, 105],
            warmupCycleCount: 5,
            maximumGrowthRatio: 0.10
        )
        let growing = ChatMemoryPlateauDiagnostics.evaluate(
            samples: Array(stride(from: 100, through: 290, by: 10)),
            warmupCycleCount: 5,
            maximumGrowthRatio: 0.10
        )

        XCTAssertEqual(stable.measuredCycleCount, 15)
        XCTAssertTrue(stable.isWithinBudget)
        XCTAssertLessThanOrEqual(stable.growthRatio, 0.10)
        XCTAssertFalse(growing.isWithinBudget)
        XCTAssertGreaterThan(growing.growthRatio, 0.10)
    }

    @MainActor
    func testMemoryPressurePreservesViewportPendingTargetAndPlaceholderState() {
        let controller = ChatViewController()
        controller.owner = "memory-owner@example.com"
        controller.jid = "memory-chat@example.com"
        controller.conversationType = .regular
        controller.loadViewIfNeeded()
        let request = makeRequest(controller: controller, primary: "target")
        controller.pendingOpenMessageRequest = request
        controller.showSkeletonObserver.accept(false)
        controller.messagesCollectionView.contentOffset = CGPoint(x: 0, y: 17)

        let beforeDatasource = controller.datasource.map(\.primary)
        let beforeOffset = controller.messagesCollectionView.contentOffset
        controller.handleChatMemoryPressureForTesting()

        XCTAssertEqual(controller.datasource.map(\.primary), beforeDatasource)
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, beforeOffset)
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)
        XCTAssertFalse(controller.showSkeletonObserver.value)
    }

    @MainActor
    func testTerminalTeardownCancelsEveryOwnedRegistryAndIsIdempotent() {
        let controller = ChatViewController()
        controller.owner = "teardown-owner@example.com"
        controller.jid = "teardown-chat@example.com"
        controller.conversationType = .regular
        controller.loadViewIfNeeded()

        let request = makeRequest(controller: controller, primary: "target")
        let token = ChatAnchorTransactionToken(rawValue: "teardown-token")
        var state = ChatAnchorExecutionState(request: request, transactionToken: token)
        state.remoteQueryId = "teardown-query"
        state.isRemoteFetchInFlight = true
        controller.activeAnchorExecutionState = state
        _ = controller.anchorTransactionGate.begin(token: token, requestIdentity: "target")
        _ = controller.anchorTransactionGate.acquire(.query("teardown-query"), token: token)
        controller.anchorTransactionTokenByQueryId["teardown-query"] = token
        let anchorTimeout = DispatchWorkItem {}
        controller.anchorTransactionTimeoutWorkItems["teardown-query"] = anchorTimeout
        let searchDebounce = DispatchWorkItem {}
        controller.searchSessionDebounceWorkItem = searchDebounce
        let bootstrapTimeout = DispatchWorkItem {}
        controller.initialBootstrapTimeoutWorkItem = bootstrapTimeout
        let bootstrapFallback = DispatchWorkItem {}
        controller.initialBootstrapLocalHistoryFallbackWorkItem = bootstrapFallback
        controller.beginChatHistoryLoadActivity(reason: "teardown-test")
        SignatureManager.shared.delegate = controller
        controller.registerRemoteHistoryEndPageDispatcher(queryId: "teardown-query")
        controller.registerRemoteHistoryFailureDispatcher(queryId: "teardown-query")
        controller.scrollWorkScheduler.enqueue(
            ChatScrollWorkRequest(
                contentOffsetY: 0,
                gestureTranslationY: 0,
                isUserScrolling: false,
                visibleIndexPaths: [],
                work: [.updateFloatingDate]
            )
        )
        _ = controller.beginDatasetMappingJobForTesting()

        controller.performTerminalChatResourceTeardownForTesting()
        controller.performTerminalChatResourceTeardownForTesting()

        XCTAssertTrue(controller.chatLifecycleResourceSnapshot.isIdle)
        XCTAssertTrue(anchorTimeout.isCancelled)
        XCTAssertTrue(searchDebounce.isCancelled)
        XCTAssertTrue(bootstrapTimeout.isCancelled)
        XCTAssertTrue(bootstrapFallback.isCancelled)
        XCTAssertFalse(ChatHistoryLoadActivityRegistry.hasActiveHistoryLoad)
        XCTAssertNil(SignatureManager.shared.delegate)
    }

    @MainActor
    func testControllerDeallocatesAfterTerminalTeardown() {
        weak var weakController: ChatViewController?
        autoreleasepool {
            var controller: ChatViewController? = ChatViewController()
            controller?.owner = "dealloc-owner@example.com"
            controller?.jid = "dealloc-chat@example.com"
            controller?.conversationType = .regular
            controller?.loadViewIfNeeded()
            controller?.performTerminalChatResourceTeardownForTesting()
            weakController = controller
            controller = nil
        }

        XCTAssertNil(weakController)
    }

    @MainActor
    func testCancellingUnpresentedStackedPreparationDropsRetainedCompletionsAndController() {
        weak var weakController: ChatViewController?
        weak var weakMappingToken: ChatDatasetMappingCancellationToken?
        var callbackCount = 0

        autoreleasepool {
            var controller: ChatViewController? = ChatViewController()
            controller?.owner = "cancelled-preparation-owner@example.com"
            controller?.jid = "cancelled-preparation-chat@example.com"
            controller?.conversationType = .regular
            controller?.isPreparingStackedNavigationPresentation = true
            let retainedController = controller
            controller?.initialLocalFirstFrameCompletions.append {
                _ = retainedController
                callbackCount += 1
            }
            controller?.pendingBootstrapFirstFrameReadinessCompletions.append {
                _ = retainedController
                callbackCount += 1
            }
            let mappingToken = controller?.beginDatasetMappingJobForTesting()
            controller?.initialLocalFirstFrameMappingToken = mappingToken
            weakMappingToken = mappingToken
            weakController = controller

            controller?.cancelStackedNavigationPresentationPreparation()

            XCTAssertTrue(mappingToken?.isCancelled == true)
            XCTAssertTrue(controller?.initialLocalFirstFrameCompletions.isEmpty == true)
            XCTAssertTrue(controller?.pendingBootstrapFirstFrameReadinessCompletions.isEmpty == true)
            XCTAssertNil(controller?.initialLocalFirstFrameMappingToken)
            XCTAssertFalse(controller?.isPreparingStackedNavigationPresentation == true)
            controller = nil
        }

        XCTAssertEqual(callbackCount, 0)
        XCTAssertNil(weakController)
        XCTAssertNil(weakMappingToken)
    }

    private func makeRequest(
        controller: ChatViewController,
        primary: String
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: primary,
                archivedId: nil,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: nil
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .external
        )
    }
}
