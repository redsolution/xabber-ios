import XCTest
import UIKit
import RealmSwift
import RxSwift
@testable import xabber

final class ChatCollectionAnchorPreservationTests: XCTestCase {
    private let owner = "viewport-owner@example.com"
    private let jid = "viewport-peer@example.com"

    func testTransactionAllowsAtMostOneForcedLayoutAndOneProgrammaticOffsetMutation() {
        var forcedLayoutCount = 0
        var offsetMutationCount = 0
        var result: ChatViewportTransactionResult?
        let transaction = makeTransaction { result = $0 }

        XCTAssertTrue(transaction.performForcedLayout {
            forcedLayoutCount += 1
        })
        XCTAssertFalse(transaction.performForcedLayout {
            forcedLayoutCount += 1
        })

        XCTAssertTrue(transaction.performProgrammaticOffsetMutation(
            currentOffsetY: 10,
            targetOffsetY: 42,
            isAutomatic: true
        ) { targetOffsetY in
            offsetMutationCount += 1
            XCTAssertEqual(targetOffsetY, 42, accuracy: 0.001)
        })
        XCTAssertFalse(transaction.performProgrammaticOffsetMutation(
            currentOffsetY: 42,
            targetOffsetY: 64,
            isAutomatic: true
        ) { _ in
            offsetMutationCount += 1
        })

        transaction.recordFinalInsets(UIEdgeInsets(top: 8, left: 0, bottom: 16, right: 0))
        XCTAssertTrue(transaction.commit(anchorError: 0.25))

        XCTAssertEqual(forcedLayoutCount, 1)
        XCTAssertEqual(offsetMutationCount, 1)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected a committed transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 1)
        XCTAssertEqual(diagnostics.nextRunLoopCorrectionCount, 0)
        XCTAssertEqual(try XCTUnwrap(diagnostics.anchorError), 0.25, accuracy: 0.001)
        XCTAssertEqual(diagnostics.insetDelta.top, 8, accuracy: 0.001)
        XCTAssertEqual(diagnostics.insetDelta.bottom, 16, accuracy: 0.001)
    }

    func testMissingTargetIsTypedFailureAndDoesNotRunSuccessTwice() {
        var results: [ChatViewportTransactionResult] = []
        let transaction = makeTransaction { results.append($0) }

        XCTAssertTrue(transaction.fail(.targetMissing(primary: "deleted-message")))
        XCTAssertFalse(transaction.commit(anchorError: nil))
        XCTAssertFalse(transaction.fail(.targetMissing(primary: "deleted-message")))
        XCTAssertEqual(results.count, 1)

        guard case .failed(let failure, let diagnostics) = results.first else {
            return XCTFail("Expected a typed failure")
        }
        XCTAssertEqual(failure, .targetMissing(primary: "deleted-message"))
        XCTAssertEqual(diagnostics.forcedLayoutCount, 0)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
    }

    func testUserInteractionSuppressesAutomaticOffsetMutation() {
        var offsetMutationCount = 0
        var result: ChatViewportTransactionResult?
        let transaction = makeTransaction { result = $0 }

        transaction.markUserInteractionDetected()
        XCTAssertFalse(transaction.performProgrammaticOffsetMutation(
            currentOffsetY: 20,
            targetOffsetY: 80,
            isAutomatic: true
        ) { _ in
            offsetMutationCount += 1
        })
        XCTAssertTrue(transaction.commit(anchorError: nil))

        XCTAssertEqual(offsetMutationCount, 0)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected a committed transaction")
        }
        XCTAssertTrue(diagnostics.automaticOffsetMutationSuppressedByUserInteraction)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
    }

    func testExplicitTargetOffsetStillAppliesDuringUserInteraction() {
        var appliedOffsetY: CGFloat?
        let transaction = makeTransaction(completion: { _ in })

        transaction.markUserInteractionDetected()
        XCTAssertTrue(transaction.performProgrammaticOffsetMutation(
            currentOffsetY: 20,
            targetOffsetY: 80,
            isAutomatic: false
        ) { appliedOffsetY = $0 })
        XCTAssertEqual(try XCTUnwrap(appliedOffsetY), 80, accuracy: 0.001)
    }

    func testAnchorTargetMathPreservesViewportPositionForPrependTrimAndHeightChanges() {
        let anchor = ChatViewportAnchor(primary: "anchor", viewportRelativeMinY: 120)
        let cases: [(name: String, resolvedMinY: CGFloat, expectedOffsetY: CGFloat)] = [
            ("prepend", 520, 400),
            ("newer append below viewport", 320, 200),
            ("trim above", 220, 100),
            ("height edit above", 370, 250),
            ("height edit inside", 335, 215),
            ("height edit below", 320, 200)
        ]

        for entry in cases {
            let target = ChatViewportTransactionTargetPolicy.targetContentOffsetY(
                anchor: anchor,
                resolvedAnchorMinY: entry.resolvedMinY,
                minimumContentOffsetY: -20,
                maximumContentOffsetY: 900
            )
            XCTAssertEqual(target, entry.expectedOffsetY, accuracy: 0.001, entry.name)
            XCTAssertEqual(entry.resolvedMinY - target, anchor.viewportRelativeMinY, accuracy: 0.001, entry.name)
        }
    }

    func testAnchorTargetMathClampsToScrollableBounds() {
        let anchor = ChatViewportAnchor(primary: "anchor", viewportRelativeMinY: 120)

        XCTAssertEqual(
            ChatViewportTransactionTargetPolicy.targetContentOffsetY(
                anchor: anchor,
                resolvedAnchorMinY: 20,
                minimumContentOffsetY: -40,
                maximumContentOffsetY: 500
            ),
            -40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatViewportTransactionTargetPolicy.targetContentOffsetY(
                anchor: anchor,
                resolvedAnchorMinY: 900,
                minimumContentOffsetY: -40,
                maximumContentOffsetY: 500
            ),
            500,
            accuracy: 0.001
        )
    }

    func testPreservedOffsetPolicyMarksOutOfBoundsOffsetAsMandatorySafetyClamp() {
        let decision = ChatViewportTransactionTargetPolicy.preservedContentOffsetDecision(
            requestedOffsetY: 900,
            minimumContentOffsetY: -20,
            maximumContentOffsetY: 180
        )

        XCTAssertEqual(decision.targetOffsetY, 180, accuracy: 0.001)
        XCTAssertTrue(decision.isSafetyClamp)
    }

    func testPreservedOffsetPolicyKeepsInBoundsRestorationAutomatic() {
        let decision = ChatViewportTransactionTargetPolicy.preservedContentOffsetDecision(
            requestedOffsetY: 120,
            minimumContentOffsetY: -20,
            maximumContentOffsetY: 180
        )

        XCTAssertEqual(decision.targetOffsetY, 120, accuracy: 0.001)
        XCTAssertFalse(decision.isSafetyClamp)
    }

    func testNewerPageRestoresCapturedAnchorInsideApplyTransaction() {
        let plan = ChatHistoryPageApplyPolicy.plan(direction: .newer, hasCapturedAnchor: true)

        XCTAssertEqual(plan.restorePhase, .applyTransaction)
        XCTAssertFalse(plan.keepOffset)
    }

    func testBottomPinRequiresResidentLiveTail() {
        let oldItems = [makeDatasource(primary: "m1"), makeDatasource(primary: "m2")]
        let newItems = oldItems + [makeDatasource(primary: "m3")]
        let oldSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: oldItems)
        let newSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: newItems)

        XCTAssertFalse(ChatTailAppendBottomPinPolicy.shouldPinBottom(
            old: oldSnapshot,
            new: newSnapshot,
            wasNearBottom: true,
            isResidentAtLiveTail: false,
            isDefaultBottomScrollDeferred: false,
            suppressDefaultBottomScroll: false,
            containsOnlyFakeMessages: false,
            outgoingAutoScrollDecision: .notHandled
        ))
        XCTAssertTrue(ChatTailAppendBottomPinPolicy.shouldPinBottom(
            old: oldSnapshot,
            new: newSnapshot,
            wasNearBottom: true,
            isResidentAtLiveTail: true,
            isDefaultBottomScrollDeferred: false,
            suppressDefaultBottomScroll: false,
            containsOnlyFakeMessages: false,
            outgoingAutoScrollDecision: .notHandled
        ))
    }

    func testOutgoingTailAppendIsBottomAlignedBeforeControllerBatchCompletion() throws {
        XCTAssertTrue(Thread.isMainThread)
        let collectionView = ChatTailAppendBatchCompletionCollectionView()
        let controller = makeController(collectionView: collectionView)
        installDetachedComposerGeometry(in: controller)
        let initialItems = (0..<24).map {
            makeDatasource(primary: "outgoing-tail-initial-\($0)")
        }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        controller.requestOutgoingAutoScrollAfterDatasourceUpdate()
        controller.scrollFrameOperationCounter.reset()

        let outgoingPrimary = "outgoing-tail-appended"
        var outgoing = makeDatasource(primary: outgoingPrimary)
        outgoing.outgoing = true
        outgoing.isOutgoing = true
        outgoing.sender = controller.ownerSender
        outgoing.state = .sending
        outgoing.indicator = .sending
        outgoing.kind = .attributedText(NSAttributedString(
            string: String(repeating: "atomic outgoing message ", count: 6)
        ))

        struct BoundaryObservation {
            let bottomDistance: CGFloat
            let composerClearance: CGFloat
            let contentOffsetY: CGFloat
        }
        var boundaryObservation: BoundaryObservation?
        var transactionResult: ChatViewportTransactionResult?
        let batchBoundary = expectation(description: "batch boundary observed")
        let transactionCompleted = expectation(description: "viewport transaction completed")
        collectionView.beforeForwardingBatchCompletion = {
            let section = try? XCTUnwrap(
                controller.datasourceSnapshot.primaryIndex[outgoingPrimary]
            )
            let attributes = section.flatMap {
                controller.messagesCollectionView.layoutAttributesForItem(
                    at: IndexPath(item: 0, section: $0)
                )
            }
            if let attributes {
                let rowViewportMaxY = attributes.frame.maxY -
                    controller.messagesCollectionView.contentOffset.y
                boundaryObservation = BoundaryObservation(
                    bottomDistance: ChatTailAppendBottomPinPolicy.bottomDistance(
                        contentHeight: controller.messagesCollectionView.contentSize.height,
                        viewportHeight: controller.messagesCollectionView.bounds.height,
                        contentInsets: controller.messagesCollectionView.contentInset,
                        contentOffsetY: controller.messagesCollectionView.contentOffset.y
                    ),
                    composerClearance: controller.xabberInputView.frame.minY - rowViewportMaxY,
                    contentOffsetY: controller.messagesCollectionView.contentOffset.y
                )
            }
            batchBoundary.fulfill()
        }

        controller.applyChatDatasource(
            initialItems + [outgoing],
            mode: .targetedDiff,
            animated: true,
            transactionCompletion: {
                transactionResult = $0
                transactionCompleted.fulfill()
            }
        )

        wait(for: [batchBoundary, transactionCompleted], timeout: 2)
        let boundary = try XCTUnwrap(boundaryObservation)
        XCTAssertLessThanOrEqual(boundary.bottomDistance, 0.5)
        XCTAssertGreaterThanOrEqual(
            boundary.composerClearance,
            ChatFloatingHeaderLayoutPolicy.composerMessageSpacing - 0.5
        )
        guard case .committed(let diagnostics) = transactionResult else {
            return XCTFail("Expected committed outgoing tail transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
        XCTAssertEqual(diagnostics.insetDelta.bottom, 0, accuracy: 0.001)
        let operations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(operations[.structuralInserts], 1)
        XCTAssertEqual(operations[.reloads], 0)

        let nextRunLoop = expectation(description: "next run loop remains stable")
        DispatchQueue.main.async {
            XCTAssertEqual(
                controller.messagesCollectionView.contentOffset.y,
                boundary.contentOffsetY,
                accuracy: 0.001
            )
            nextRunLoop.fulfill()
        }
        wait(for: [nextRunLoop], timeout: 1)
    }

    func testShortOutgoingTailAppendWithDateSeparatorAndKeyboardIsAtomic() throws {
        XCTAssertTrue(Thread.isMainThread)
        let collectionView = ChatTailAppendBatchCompletionCollectionView()
        let controller = makeController(collectionView: collectionView)
        let initialItems = [
            makeDatasource(primary: "short-tail-initial-0"),
            makeDatasource(primary: "short-tail-initial-1")
        ]
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )

        installDetachedComposerGeometry(
            in: controller,
            visualHeight: ModernXabberInputView.defaultBarHeight + 220
        )
        XCTAssertGreaterThan(controller.messagesCollectionView.contentInset.bottom, 200)
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        controller.requestOutgoingAutoScrollAfterDatasourceUpdate()
        controller.scrollFrameOperationCounter.reset()

        var dateSeparator = makeDatasource(primary: "short-tail-date")
        dateSeparator.isFakeMessage = true
        dateSeparator.kind = .date(NSAttributedString(string: "Today"))
        dateSeparator.state = .none
        dateSeparator.isRead = ChatDateSeparatorPresentationPolicy.isRead

        let outgoingPrimary = "short-tail-outgoing"
        var outgoing = makeDatasource(primary: outgoingPrimary)
        outgoing.outgoing = true
        outgoing.isOutgoing = true
        outgoing.sender = controller.ownerSender
        outgoing.state = .sending
        outgoing.indicator = .sending
        outgoing.kind = .attributedText(NSAttributedString(string: "One line"))

        struct BoundaryObservation {
            let bottomDistance: CGFloat
            let composerClearance: CGFloat
            let contentOffsetY: CGFloat
        }
        var boundaryObservation: BoundaryObservation?
        var transactionResult: ChatViewportTransactionResult?
        let batchBoundary = expectation(description: "short batch boundary observed")
        let transactionCompleted = expectation(description: "short viewport transaction completed")
        collectionView.beforeForwardingBatchCompletion = {
            let section = controller.datasourceSnapshot.primaryIndex[outgoingPrimary]
            let attributes = section.flatMap {
                controller.messagesCollectionView.layoutAttributesForItem(
                    at: IndexPath(item: 0, section: $0)
                )
            }
            if let attributes {
                let rowViewportMaxY = attributes.frame.maxY -
                    controller.messagesCollectionView.contentOffset.y
                boundaryObservation = BoundaryObservation(
                    bottomDistance: ChatTailAppendBottomPinPolicy.bottomDistance(
                        contentHeight: controller.messagesCollectionView.contentSize.height,
                        viewportHeight: controller.messagesCollectionView.bounds.height,
                        contentInsets: controller.messagesCollectionView.contentInset,
                        contentOffsetY: controller.messagesCollectionView.contentOffset.y
                    ),
                    composerClearance: controller.xabberInputView.frame.minY - rowViewportMaxY,
                    contentOffsetY: controller.messagesCollectionView.contentOffset.y
                )
            }
            batchBoundary.fulfill()
        }

        controller.applyChatDatasource(
            initialItems + [dateSeparator, outgoing],
            mode: .targetedDiff,
            animated: true,
            transactionCompletion: {
                transactionResult = $0
                transactionCompleted.fulfill()
            }
        )

        wait(for: [batchBoundary, transactionCompleted], timeout: 2)
        let boundary = try XCTUnwrap(boundaryObservation)
        XCTAssertLessThanOrEqual(boundary.bottomDistance, 0.5)
        XCTAssertGreaterThanOrEqual(
            boundary.composerClearance,
            ChatFloatingHeaderLayoutPolicy.composerMessageSpacing - 0.5
        )
        guard case .committed(let diagnostics) = transactionResult else {
            return XCTFail("Expected committed short outgoing tail transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
        XCTAssertEqual(diagnostics.insetDelta.bottom, 0, accuracy: 0.001)
        let operations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(operations[.structuralInserts], 2)
        XCTAssertEqual(operations[.reloads], 0)

        let nextRunLoop = expectation(description: "short next run loop remains stable")
        DispatchQueue.main.async {
            XCTAssertEqual(
                controller.messagesCollectionView.contentOffset.y,
                boundary.contentOffsetY,
                accuracy: 0.001
            )
            nextRunLoop.fulfill()
        }
        wait(for: [nextRunLoop], timeout: 1)
    }

    func testIncomingLiveTailAppendIsBottomAlignedBeforeBatchCompletion() throws {
        XCTAssertTrue(Thread.isMainThread)
        let collectionView = ChatTailAppendBatchCompletionCollectionView()
        let controller = makeController(collectionView: collectionView)
        installDetachedComposerGeometry(in: controller)
        let initialItems = (0..<24).map {
            makeDatasource(primary: "incoming-tail-initial-\($0)")
        }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(controller.virtualTimelineState.isResidentAtLiveTail)
        controller.scrollFrameOperationCounter.reset()

        let incomingPrimary = "incoming-tail-appended"
        let incoming = makeDatasource(primary: incomingPrimary)
        struct BoundaryObservation {
            let bottomDistance: CGFloat
            let composerClearance: CGFloat
            let contentOffsetY: CGFloat
        }
        var boundaryObservation: BoundaryObservation?
        var transactionResult: ChatViewportTransactionResult?
        let batchBoundary = expectation(description: "incoming batch boundary observed")
        let transactionCompleted = expectation(description: "incoming viewport transaction completed")
        collectionView.beforeForwardingBatchCompletion = {
            let section = controller.datasourceSnapshot.primaryIndex[incomingPrimary]
            let attributes = section.flatMap {
                controller.messagesCollectionView.layoutAttributesForItem(
                    at: IndexPath(item: 0, section: $0)
                )
            }
            if let attributes {
                let rowViewportMaxY = attributes.frame.maxY -
                    controller.messagesCollectionView.contentOffset.y
                boundaryObservation = BoundaryObservation(
                    bottomDistance: ChatTailAppendBottomPinPolicy.bottomDistance(
                        contentHeight: controller.messagesCollectionView.contentSize.height,
                        viewportHeight: controller.messagesCollectionView.bounds.height,
                        contentInsets: controller.messagesCollectionView.contentInset,
                        contentOffsetY: controller.messagesCollectionView.contentOffset.y
                    ),
                    composerClearance: controller.xabberInputView.frame.minY - rowViewportMaxY,
                    contentOffsetY: controller.messagesCollectionView.contentOffset.y
                )
            }
            batchBoundary.fulfill()
        }

        controller.applyChatDatasource(
            initialItems + [incoming],
            mode: .targetedDiff,
            animated: true,
            transactionCompletion: {
                transactionResult = $0
                transactionCompleted.fulfill()
            }
        )

        wait(for: [batchBoundary, transactionCompleted], timeout: 2)
        let boundary = try XCTUnwrap(boundaryObservation)
        XCTAssertLessThanOrEqual(boundary.bottomDistance, 0.5)
        XCTAssertGreaterThanOrEqual(
            boundary.composerClearance,
            ChatFloatingHeaderLayoutPolicy.composerMessageSpacing - 0.5
        )
        guard case .committed(let diagnostics) = transactionResult else {
            return XCTFail("Expected committed incoming tail transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
        XCTAssertEqual(diagnostics.insetDelta.bottom, 0, accuracy: 0.001)
        let operations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(operations[.structuralInserts], 1)
        XCTAssertEqual(operations[.reloads], 0)

        let nextRunLoop = expectation(description: "incoming next run loop remains stable")
        DispatchQueue.main.async {
            XCTAssertEqual(
                controller.messagesCollectionView.contentOffset.y,
                boundary.contentOffsetY,
                accuracy: 0.001
            )
            nextRunLoop.fulfill()
        }
        wait(for: [nextRunLoop], timeout: 1)
    }

    func testContentOnlyTransactionDoesNotMutateOffset() {
        var offsetMutationCount = 0
        var result: ChatViewportTransactionResult?
        let transaction = ChatViewportTransaction(
            snapshotDiff: ChatViewportSnapshotDiff(oldItemCount: 2, newItemCount: 2),
            contentChanges: [.contentOnly],
            layoutChanges: [],
            initialInsets: .zero,
            anchorStrategy: .preserveContentOffset(40),
            completion: { result = $0 }
        )

        XCTAssertFalse(transaction.performProgrammaticOffsetMutation(
            currentOffsetY: 40,
            targetOffsetY: 40,
            isAutomatic: true
        ) { _ in
            offsetMutationCount += 1
        })
        XCTAssertTrue(transaction.commit(anchorError: nil))

        XCTAssertEqual(offsetMutationCount, 0)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected a committed transaction")
        }
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
    }

    @MainActor
    func testAtomicInitialFrameReplacesPreReceiptScrollWorkWithOneCurrentPostReceiptResample() throws {
        let controller = makeController()
        let staleGeneration = controller.scrollResidentMetadata.generation
        var scheduledCallbacks: [() -> Void] = []
        var handledRequests: [ChatScrollWorkRequest] = []
        var transactionResult: ChatViewportTransactionResult?
        var receiptObservedCommittedTransaction: [Bool] = []
        var receiptStructuralState: [(before: Bool, after: Bool)] = []
        var receiptDatasourceApplyDeltas: [Int] = []
        var receiptOffsetMutationDeltas: [Int] = []
        controller.scrollWorkScheduler = ChatScrollWorkScheduler(
            schedule: { scheduledCallbacks.append($0) },
            handler: { request in
                handledRequests.append(request)
                guard request.isPostAtomicInitialFrameReceiptResample else {
                    return
                }
                if case .committed = transactionResult {
                    receiptObservedCommittedTransaction.append(true)
                } else {
                    receiptObservedCommittedTransaction.append(false)
                }
                let structuralBefore =
                    controller.isChatDatasourceStructuralTransactionActive
                let operationsBefore =
                    controller.scrollFrameOperationCounter.snapshot()
                controller.performCoalescedScrollWork(request)
                let operationsAfter =
                    controller.scrollFrameOperationCounter.snapshot()
                receiptStructuralState.append((
                    before: structuralBefore,
                    after: controller.isChatDatasourceStructuralTransactionActive
                ))
                receiptDatasourceApplyDeltas.append(
                    operationsAfter[.datasourceApplies] -
                        operationsBefore[.datasourceApplies]
                )
                receiptOffsetMutationDeltas.append(
                    operationsAfter[.offsetMutations] -
                        operationsBefore[.offsetMutations]
                )
            }
        )
        controller.scrollWorkScheduler.enqueue(ChatScrollWorkRequest(
            contentOffsetY: -9_999,
            gestureTranslationY: 777,
            isUserScrolling: false,
            visibleIndexPaths: [],
            visibleMetadata: .empty,
            meaningfullyVisibleReadPrimaries: ["stale-pre-receipt"],
            work: [
                .updateScrollPosition,
                .updateFloatingDate,
                .advanceReadBoundary,
                .updateVoiceQueue,
                .evaluateBoundaryPaging
            ]
        ))
        XCTAssertEqual(controller.scrollWorkScheduler.pendingRequestCount, 1)

        let items = (0..<12).map { makeDatasource(primary: "atomic-post-receipt-\($0)") }
        controller.applyChatDatasource(
            items,
            mode: .fullReload(),
            animated: false,
            invalidateLayout: false,
            suppressDefaultBottomScroll: true,
            forceBottomAlignmentTarget: .newestRealMessage,
            presentationCommitMode: .atomicInitialFrame,
            transactionCompletion: { transactionResult = $0 }
        )
        guard case .committed = transactionResult else {
            return XCTFail("Atomic initial frame must commit before its resample")
        }
        let committedOffset = controller.messagesCollectionView.contentOffset
        let committedGeneration = controller.scrollResidentMetadata.generation
        XCTAssertGreaterThan(committedGeneration, staleGeneration)
        XCTAssertEqual(controller.scrollWorkScheduler.pendingRequestCount, 0)
        XCTAssertEqual(
            handledRequests.count,
            1,
            "The receipt-owned metadata pass must execute before coalescing is possible"
        )
        XCTAssertEqual(receiptObservedCommittedTransaction, [true])
        XCTAssertEqual(receiptStructuralState.map { $0.before }, [false])
        XCTAssertEqual(receiptStructuralState.map { $0.after }, [false])
        XCTAssertEqual(
            receiptDatasourceApplyDeltas,
            [0],
            "Receipt metadata must not reenter datasource application"
        )
        XCTAssertEqual(
            receiptOffsetMutationDeltas,
            [0],
            "Receipt metadata must not mutate the collection offset"
        )
        let handled = try XCTUnwrap(handledRequests.first)
        XCTAssertEqual(handled.visibleMetadata.generation, committedGeneration)
        XCTAssertTrue(handled.isPostAtomicInitialFrameReceiptResample)
        XCTAssertEqual(
            handled.work,
            [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue]
        )
        XCTAssertEqual(
            handled.effectiveWork(
                isInteractionGateActive: true,
                currentVisibleMetadataGeneration: committedGeneration
            ),
            [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue],
            "Required post-receipt work must survive the chat-open responsiveness gate"
        )
        XCTAssertFalse(handled.work.contains(.updateScrollPosition))
        XCTAssertFalse(handled.work.contains(.evaluateBoundaryPaging))
        XCTAssertNotEqual(handled.contentOffsetY, -9_999)
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, committedOffset)

        let normalVisibleIndexPaths = controller.messagesCollectionView
            .indexPathsForVisibleItems
        controller.scrollWorkScheduler.enqueue(ChatScrollWorkRequest(
            contentOffsetY: committedOffset.y,
            gestureTranslationY: -20,
            isUserScrolling: true,
            visibleIndexPaths: normalVisibleIndexPaths,
            visibleMetadata: controller.scrollResidentMetadata.capture(
                indexPaths: normalVisibleIndexPaths
            ),
            work: [.updateScrollPosition, .evaluateBoundaryPaging]
        ))
        XCTAssertEqual(controller.scrollWorkScheduler.pendingRequestCount, 1)
        XCTAssertEqual(
            handledRequests.count,
            1,
            "A later normal scroll must not merge back into the flushed receipt pass"
        )

        let callbacks = scheduledCallbacks
        XCTAssertGreaterThanOrEqual(
            callbacks.count,
            2,
            "Stale and later normal scheduled generations must be distinct"
        )
        callbacks.forEach { $0() }

        XCTAssertEqual(handledRequests.count, 2)
        let normal = try XCTUnwrap(handledRequests.last)
        XCTAssertFalse(normal.isPostAtomicInitialFrameReceiptResample)
        XCTAssertEqual(normal.work, [.updateScrollPosition, .evaluateBoundaryPaging])
        XCTAssertEqual(normal.visibleMetadata.generation, committedGeneration)
        XCTAssertEqual(
            normal.effectiveWork(
                isInteractionGateActive: true,
                currentVisibleMetadataGeneration: committedGeneration
            ),
            [.updateScrollPosition, .evaluateBoundaryPaging],
            "Normal user work remains a separate, non-privileged generation"
        )
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, committedOffset)
        XCTAssertEqual(controller.scrollWorkScheduler.pendingRequestCount, 0)
    }

    func testKeepOffsetWindowShrinkClampsViewportInsideNewContentBounds() {
        let controller = makeController()
        let initialItems = (0..<80).map { makeDatasource(primary: "initial-\($0)") }
        let replacementItems = (0..<2).map { makeDatasource(primary: "replacement-\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        let oldOffsetY = controller.messagesCollectionView.contentOffset.y

        controller.applyChatDatasource(
            replacementItems,
            mode: .windowReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.layoutIfNeeded()

        let minimumOffsetY = -controller.messagesCollectionView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            controller.messagesCollectionView.contentSize.height -
                controller.messagesCollectionView.bounds.height +
                controller.messagesCollectionView.adjustedContentInset.bottom
        )
        XCTAssertGreaterThan(oldOffsetY, maximumOffsetY)
        XCTAssertGreaterThanOrEqual(
            controller.messagesCollectionView.contentOffset.y,
            minimumOffsetY - 0.5
        )
        XCTAssertLessThanOrEqual(
            controller.messagesCollectionView.contentOffset.y,
            maximumOffsetY + 0.5
        )
    }

    func testRemovedLegacyViewportCorrectionPrimitivesDoNotReturn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "xabber/controllers/chats/chat/ChatViewController.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift",
            "xabber/controllers/chats/chat/messages_kit/Views/MessagesCollectionView.swift"
        ]
        let sourcesByPath = try Dictionary(uniqueKeysWithValues: relativePaths.map {
            (
                $0,
                try String(contentsOf: repositoryRoot.appendingPathComponent($0), encoding: .utf8)
            )
        })
        let sources = sourcesByPath.values.joined(separator: "\n")

        for token in [
            "scheduleOutgoingBottomRealignment",
            "performBatchUpdates(nil)",
            "reloadDataAndKeepOffset",
            "UIView.setAnimationsEnabled(false)"
        ] {
            XCTAssertFalse(sources.contains(token), "Removed viewport legacy token remains: \(token)")
        }
        let viewportApplySources = relativePaths.dropFirst().compactMap { sourcesByPath[$0] }
            .joined(separator: "\n")
        XCTAssertFalse(
            viewportApplySources.contains("removeAllAnimations()"),
            "Viewport apply must not clear layer animations; terminal resource teardown may"
        )
    }

    func testControllerPrependCommitsAnchorWithOneLayoutAndOneOffsetMutation() throws {
        let controller = makeController()
        let initialItems = (40..<80).map { makeDatasource(primary: "m\($0)") }
        let expandedItems = (0..<80).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 12),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()

        let anchorPrimary = initialItems[12].primary
        let viewportRelativeMinY = try viewportY(for: anchorPrimary, in: controller)
        let anchor = ChatViewportAnchor(
            primary: anchorPrimary,
            viewportRelativeMinY: viewportRelativeMinY
        )
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            expandedItems,
            mode: .windowReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            applyCategory: .olderAnchorReload,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: anchor.primary,
            restoreAnchor: anchor,
            transactionCompletion: { result = $0 }
        )

        XCTAssertEqual(try viewportY(for: anchorPrimary, in: controller), viewportRelativeMinY, accuracy: 1)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected committed prepend transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
        XCTAssertEqual(diagnostics.nextRunLoopCorrectionCount, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(diagnostics.anchorError), 1)

        let committedOffsetY = controller.messagesCollectionView.contentOffset.y
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(controller.messagesCollectionView.contentOffset.y, committedOffsetY, accuracy: 0.001)
    }

    func testControllerTargetDeletionReportsFailureWithoutLegacySuccessCompletion() throws {
        let controller = makeController()
        let initialItems = (0..<30).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 10),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let deletedPrimary = initialItems[10].primary
        let anchor = ChatViewportAnchor(
            primary: deletedPrimary,
            viewportRelativeMinY: try viewportY(for: deletedPrimary, in: controller)
        )
        var result: ChatViewportTransactionResult?
        var legacyCompletionCalled = false

        controller.applyChatDatasource(
            initialItems.filter { $0.primary != deletedPrimary },
            mode: .windowReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: deletedPrimary,
            restoreAnchor: anchor,
            transactionCompletion: { result = $0 },
            completion: { legacyCompletionCalled = true }
        )

        guard case .failed(let failure, let diagnostics) = result else {
            return XCTFail("Expected target-missing transaction failure")
        }
        XCTAssertEqual(failure, .targetMissing(primary: deletedPrimary))
        XCTAssertFalse(legacyCompletionCalled)
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
    }

    func testControllerChromeUpdateWithoutPreparedLayoutReconfiguresWithoutOffset() throws {
        let controller = makeController()
        let initialItems = (0..<40).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 10),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let initialOffsetY = controller.messagesCollectionView.contentOffset.y
        var updatedItems = initialItems
        updatedItems[10].isRead.toggle()
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            updatedItems,
            mode: .targetedDiff,
            animated: false,
            suppressDefaultBottomScroll: true,
            transactionCompletion: { result = $0 }
        )

        XCTAssertTrue(waitUntil { result != nil })
        XCTAssertEqual(controller.messagesCollectionView.contentOffset.y, initialOffsetY, accuracy: 0.001)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected committed content-only transaction")
        }
        XCTAssertFalse(diagnostics.contentChanges.contains(.contentOnly))
        XCTAssertTrue(diagnostics.layoutChanges.contains(.reconfigureItems))
        XCTAssertEqual(diagnostics.programmaticOffsetMutationCount, 0)
    }

    func testControllerTrimAboveViewportPreservesAnchor() throws {
        let controller = makeController()
        let initialItems = (0..<80).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 40),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let anchorPrimary = initialItems[40].primary
        let viewportRelativeMinY = try viewportY(for: anchorPrimary, in: controller)
        let anchor = ChatViewportAnchor(
            primary: anchorPrimary,
            viewportRelativeMinY: viewportRelativeMinY
        )
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            Array(initialItems.dropFirst(20)),
            mode: .windowReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: anchor.primary,
            restoreAnchor: anchor,
            transactionCompletion: { result = $0 }
        )

        XCTAssertEqual(try viewportY(for: anchorPrimary, in: controller), viewportRelativeMinY, accuracy: 1)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected committed trim transaction")
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(diagnostics.anchorError), 1)
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
    }

    func testControllerHeightEditsAboveInsideAndBelowViewportPreserveAnchor() throws {
        for editedIndex in [5, 20, 35] {
            let controller = makeController()
            let initialItems = (0..<45).map { makeDatasource(primary: "m\($0)") }
            controller.applyChatDatasource(
                initialItems,
                mode: .fullReload(),
                animated: false,
                suppressDefaultBottomScroll: true
            )
            controller.messagesCollectionView.scrollToItem(
                at: IndexPath(item: 0, section: 20),
                at: .top,
                animated: false
            )
            controller.messagesCollectionView.layoutIfNeeded()
            let anchorPrimary = initialItems[20].primary
            let viewportRelativeMinY = try viewportY(for: anchorPrimary, in: controller)
            let anchor = ChatViewportAnchor(
                primary: anchorPrimary,
                viewportRelativeMinY: viewportRelativeMinY
            )
            var editedItems = initialItems
            editedItems[editedIndex].kind = .attributedText(NSAttributedString(
                string: String(repeating: "height-changing message ", count: 40)
            ))
            var result: ChatViewportTransactionResult?

            controller.applyChatDatasource(
                editedItems,
                mode: .fullReload(),
                animated: false,
                suppressDefaultBottomScroll: true,
                anchorRestorePhase: .applyTransaction,
                anchorPrimary: anchor.primary,
                restoreAnchor: anchor,
                transactionCompletion: { result = $0 }
            )

            XCTAssertEqual(
                try viewportY(for: anchorPrimary, in: controller),
                viewportRelativeMinY,
                accuracy: 1,
                "editedIndex=\(editedIndex)"
            )
            guard case .committed(let diagnostics) = result else {
                return XCTFail("Expected committed height-edit transaction for index \(editedIndex)")
            }
            XCTAssertLessThanOrEqual(try XCTUnwrap(diagnostics.anchorError), 1)
            XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
            XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
        }
    }

    func testControllerKeyboardInsetAndIncomingAppendPreserveAnchorAtomically() throws {
        let controller = makeController()
        let initialItems = (0..<40).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 10),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let anchorPrimary = initialItems[10].primary
        let viewportRelativeMinY = try viewportY(for: anchorPrimary, in: controller)
        let anchor = ChatViewportAnchor(
            primary: anchorPrimary,
            viewportRelativeMinY: viewportRelativeMinY
        )
        var composerFrame = controller.xabberInputView.frame
        composerFrame.size.height += 220
        controller.xabberInputView.frame = composerFrame
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            initialItems + [makeDatasource(primary: "incoming")],
            mode: .targetedDiff,
            animated: false,
            suppressDefaultBottomScroll: true,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: anchor.primary,
            restoreAnchor: anchor,
            transactionCompletion: { result = $0 }
        )

        XCTAssertTrue(waitUntil { result != nil })
        XCTAssertEqual(try viewportY(for: anchorPrimary, in: controller), viewportRelativeMinY, accuracy: 1)
        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected committed keyboard and incoming transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
        XCTAssertEqual(diagnostics.nextRunLoopCorrectionCount, 0)
        XCTAssertGreaterThan(diagnostics.insetDelta.bottom, 100)
    }

    func testWidthTransitionCommitWaitsForActualCollectionViewport() {
        let targetSize = CGSize(width: 844, height: 390)

        XCTAssertFalse(
            ChatWidthTransitionCommitReadinessPolicy.isReady(
                targetViewSize: targetSize,
                targetLayoutWidth: 844,
                viewBounds: CGRect(origin: .zero, size: targetSize),
                collectionBounds: CGRect(
                    origin: .zero,
                    size: CGSize(width: 390, height: 844)
                ),
                sectionInsets: .zero
            ),
            "Target root bounds alone must not install landscape layouts into a portrait collection viewport"
        )
        XCTAssertTrue(
            ChatWidthTransitionCommitReadinessPolicy.isReady(
                targetViewSize: targetSize,
                targetLayoutWidth: 844,
                viewBounds: CGRect(origin: .zero, size: targetSize),
                collectionBounds: CGRect(origin: .zero, size: targetSize),
                sectionInsets: .zero
            )
        )
    }

    func testWidthTransitionFinalizationWaitsForUpdateCATransactionLayoutAndSemanticProof() throws {
        let targetSize = CGSize(width: 844, height: 390)
        var gate = ChatWidthTransitionLayoutFinalizationGate(
            generation: 8,
            targetViewSize: targetSize,
            targetLayoutWidth: 844
        )

        XCTAssertFalse(gate.recordCollectionUpdateCompletion(
            generation: 7,
            didFinish: true
        ))
        XCTAssertTrue(gate.recordCollectionUpdateCompletion(
            generation: 8,
            didFinish: true
        ))
        XCTAssertNil(gate.completeIfReady())
        XCTAssertTrue(gate.recordCATransactionCompletion(generation: 8))
        XCTAssertNil(gate.completeIfReady())
        XCTAssertTrue(gate.recordLayoutObservation(
            generation: 8,
            targetGeometryReady: true,
            targetCacheReady: true,
            targetContentSizeReady: true,
            semanticViewportReady: false
        ))
        XCTAssertNil(gate.completeIfReady())
        XCTAssertTrue(gate.recordLayoutObservation(
            generation: 8,
            targetGeometryReady: true,
            targetCacheReady: true,
            targetContentSizeReady: true,
            semanticViewportReady: true
        ))

        let receipt = try XCTUnwrap(gate.completeIfReady())
        XCTAssertEqual(receipt.generation, 8)
        XCTAssertEqual(receipt.targetViewSize, targetSize)
        XCTAssertEqual(receipt.targetLayoutWidth, 844)
        XCTAssertNil(gate.completeIfReady())
    }

    func testWidthTransitionBoundsAdjustmentPreservesAnchorAndLiveTail() {
        let sourceGeometry = ChatWidthTransitionSourceGeometry(
            contentHeight: 8_000,
            contentOffsetY: 7_246
        )
        XCTAssertEqual(
            ChatWidthTransitionBoundsAdjustmentPolicy.adjustmentY(
                viewportRestoration: .message(
                    ChatHistoryPageAnchor(
                        primary: "anchor",
                        viewportRelativeMinY: -62
                    )
                ),
                sourceGeometry: sourceGeometry,
                targetViewportHeight: 390,
                contentInsets: UIEdgeInsets(
                    top: 106,
                    left: 0,
                    bottom: 90,
                    right: 0
                )
            ),
            0,
            accuracy: 0.001,
            "The natural bounds invalidation must cancel UIKit's viewport-height offset so the source item-relative anchor survives"
        )
        XCTAssertEqual(
            ChatWidthTransitionBoundsAdjustmentPolicy.adjustmentY(
                viewportRestoration: .bottom,
                sourceGeometry: sourceGeometry,
                targetViewportHeight: 390,
                contentInsets: UIEdgeInsets(
                    top: 106,
                    left: 0,
                    bottom: 90,
                    right: 0
                )
            ),
            454,
            accuracy: 0.001,
            "The same bounds invalidation must move the old content bottom by exactly the viewport-height delta before target layouts arrive"
        )
    }

    func testWidthTransitionLayoutAdjustmentsSeparateNaturalAndLateOwnership() {
        let anchor = ChatHistoryPageAnchor(
            primary: "anchor",
            viewportRelativeMinY: -62
        )
        let messageAdjustments =
            ChatWidthTransitionLayoutAdjustmentPolicy.adjustments(
                viewportRestoration: .message(anchor),
                totalHeightDelta: 82,
                precedingAnchorHeightDelta: 20.5
            )
        XCTAssertEqual(
            messageAdjustments.targetBoundsY,
            20.5,
            accuracy: 0.001,
            "A target snapshot already available at the natural bounds pass owns the exact delta before the requested anchor"
        )
        XCTAssertEqual(
            messageAdjustments.postBoundsMetricsY,
            0,
            accuracy: 0.001,
            "A late target snapshot must not cancel UIKit's native row preservation; the layout target-offset contract owns the exact requested anchor"
        )
        let bottomAdjustments =
            ChatWidthTransitionLayoutAdjustmentPolicy.adjustments(
                viewportRestoration: .bottom,
                totalHeightDelta: 82,
                precedingAnchorHeightDelta: nil
            )
        XCTAssertEqual(
            bottomAdjustments.targetBoundsY,
            82,
            accuracy: 0.001,
            "A retained reverse snapshot must add its complete content-height delta to the portrait bounds adjustment"
        )
        XCTAssertEqual(
            bottomAdjustments.postBoundsMetricsY,
            0,
            accuracy: 0.001,
            "A late metrics commit must keep UIKit's native live-tail preservation instead of applying the total height delta twice"
        )
    }

    func testFlowLayoutConsumesSemanticAdjustmentAtTargetBoundsInvalidation() throws {
        let controller = makeController()
        let flowLayout = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout
        )
        let targetBounds = CGRect(
            origin: .zero,
            size: CGSize(width: 844, height: 390)
        )
        let targetLayoutWidth = max(
            1,
            targetBounds.width - flowLayout.sectionInset.horizontal
        )
        flowLayout.stageWidthTransitionBoundsAdjustment(
            targetLayoutWidth: targetLayoutWidth,
            contentOffsetAdjustmentY: 454
        )

        let context = flowLayout.invalidationContext(
            forBoundsChange: targetBounds
        )

        XCTAssertEqual(
            context.contentOffsetAdjustment.y,
            454,
            accuracy: 0.001,
            "The natural bounds context, not a later manual invalidation, must own semantic viewport adjustment"
        )

        flowLayout.stageWidthTransitionBoundsAdjustment(
            targetLayoutWidth: targetLayoutWidth,
            contentOffsetAdjustmentY: -454
        )
        flowLayout.stageWidthTransitionLayout(
            flowLayout.cache.reuseSnapshot(),
            targetLayoutWidth: targetLayoutWidth,
            targetBoundsContentOffsetAdjustmentY: 82,
            postBoundsMetricsContentOffsetAdjustmentY: 0,
            targetContentOffset: nil
        )

        let retainedReverseContext = flowLayout.invalidationContext(
            forBoundsChange: targetBounds
        )

        XCTAssertEqual(
            retainedReverseContext.contentOffsetAdjustment.y,
            -372,
            accuracy: 0.001,
            "When the retained target cache activates in the bounds pass, viewport and exact layout deltas must be one atomic adjustment"
        )
    }

    func testHostedLateMetricsUpdateUsesLayoutTargetOffsetAtDisplayScale() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let controller = makeController()
        let items = (0..<80).map {
            makeDatasource(primary: "late-metrics-\($0)")
        }
        controller.applyChatDatasource(
            items,
            mode: .fullReload(),
            animated: false,
            invalidateLayout: true,
            suppressDefaultBottomScroll: true
        )
        var preparationFinished = false
        controller.prepareAndApplyCurrentDatasourceLayouts {
            preparationFinished = true
        }
        XCTAssertTrue(waitUntil { preparationFinished })
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 40),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let flowLayout = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout
        )
        flowLayout.resetWidthTransitionInvalidationDiagnostics()
        let currentBounds = controller.messagesCollectionView.bounds
        let currentLayoutWidth = max(
            1,
            currentBounds.width - flowLayout.sectionInset.horizontal
        )
        let anchorIndexPath = IndexPath(item: 0, section: 40)
        let anchorFrame = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: anchorIndexPath
            )?.frame
        )
        let offsetBefore = controller.messagesCollectionView.contentOffset.y
        let desiredOffsetY = offsetBefore + 20.5
        let desiredViewportY = anchorFrame.minY - desiredOffsetY
        flowLayout.stageWidthTransitionLayout(
            flowLayout.cache.reuseSnapshot(),
            targetLayoutWidth: currentLayoutWidth,
            targetBoundsContentOffsetAdjustmentY: 82,
            postBoundsMetricsContentOffsetAdjustmentY: 0,
            targetContentOffset: .message(
                indexPath: anchorIndexPath,
                viewportRelativeMinY: desiredViewportY
            )
        )

        let context = flowLayout.invalidationContext(
            forBoundsChange: currentBounds
        )
        UIView.performWithoutAnimation {
            flowLayout.commitStagedWidthTransitionInvalidation(context)
            controller.messagesCollectionView.layoutIfNeeded()
        }

        let invalidationDiagnostic = try XCTUnwrap(
            flowLayout.widthTransitionInvalidationDiagnostics.last
        )
        let targetOffsetDiagnostic = try XCTUnwrap(
            flowLayout.widthTransitionTargetOffsetDiagnostics.last
        )
        XCTAssertEqual(
            invalidationDiagnostic.phase,
            .postBoundsMetrics
        )
        XCTAssertFalse(
            invalidationDiagnostic.installedSnapshotBeforeSuper,
            "The late commit must let UIKit capture the source cache before target geometry is installed"
        )
        XCTAssertEqual(
            invalidationDiagnostic.semanticAdjustmentY,
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            flowLayout.widthTransitionInvalidationCommitModes.last,
            .targetOffsetUpdate
        )
        XCTAssertEqual(targetOffsetDiagnostic.proposedY, offsetBefore, accuracy: 1)
        XCTAssertEqual(targetOffsetDiagnostic.resolvedY, desiredOffsetY, accuracy: 0.001)
        let pixelTolerance = 1 / max(UIScreen.main.scale, 1)
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            desiredOffsetY,
            accuracy: pixelTolerance,
            "UIKit may quantize the layout-owned target to the nearest display pixel"
        )
        let resolvedFrame = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: anchorIndexPath
            )?.frame
        )
        XCTAssertEqual(
            resolvedFrame.minY -
                controller.messagesCollectionView.contentOffset.y,
            desiredViewportY,
            accuracy: pixelTolerance,
            "The update pass must atomically commit the requested semantic viewport anchor"
        )
#else
        throw XCTSkip("Width-transition lifecycle diagnostics require DEBUG/lab")
#endif
    }

    func testHostedLateMetricsBottomUpdateOwnsExactSettledTailAtBatchCompletion() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let controller = makeController()
        let items = (0..<80).map {
            makeDatasource(primary: "late-bottom-\($0)")
        }
        controller.applyChatDatasource(
            items,
            mode: .fullReload(),
            animated: false,
            invalidateLayout: true,
            suppressDefaultBottomScroll: true
        )
        var preparationFinished = false
        controller.prepareAndApplyCurrentDatasourceLayouts {
            preparationFinished = true
        }
        XCTAssertTrue(waitUntil { preparationFinished })
        controller.messagesCollectionView.layoutIfNeeded()

        let flowLayout = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout
        )
        flowLayout.resetWidthTransitionInvalidationDiagnostics()
        let collectionView = controller.messagesCollectionView
        let currentBounds = collectionView.bounds
        let currentLayoutWidth = max(
            1,
            currentBounds.width - flowLayout.sectionInset.horizontal
        )
        let exactBottomY = max(
            -collectionView.contentInset.top,
            flowLayout.collectionViewContentSize.height +
                collectionView.contentInset.bottom -
                collectionView.bounds.height
        )
        collectionView.setContentOffset(
            CGPoint(x: 0, y: exactBottomY - 80),
            animated: false
        )
        flowLayout.stageWidthTransitionLayout(
            flowLayout.cache.reuseSnapshot(),
            targetLayoutWidth: currentLayoutWidth,
            targetBoundsContentOffsetAdjustmentY: 0,
            postBoundsMetricsContentOffsetAdjustmentY: 0,
            targetContentOffset: .bottom
        )

        let context = flowLayout.invalidationContext(
            forBoundsChange: currentBounds
        )
        var didReachBatchCompletion = false
        UIView.performWithoutAnimation {
            flowLayout.commitStagedWidthTransitionInvalidation(
                context
            ) { _ in
                didReachBatchCompletion = true
            }
            collectionView.layoutIfNeeded()
        }

        XCTAssertTrue(waitUntil { didReachBatchCompletion })
        XCTAssertEqual(
            flowLayout.widthTransitionInvalidationCommitModes.last,
            .targetOffsetUpdate
        )
        let settledBottomY = max(
            -collectionView.contentInset.top,
            flowLayout.collectionViewContentSize.height +
                collectionView.contentInset.bottom -
                collectionView.bounds.height
        )
        XCTAssertEqual(
            collectionView.contentOffset.y,
            settledBottomY,
            accuracy: 1 / max(UIScreen.main.scale, 1),
            "The late target-width cache and live-tail offset must be one completed UICollectionView update"
        )
#else
        throw XCTSkip("Width-transition lifecycle diagnostics require DEBUG/lab")
#endif
    }

    func testNonRotationLayoutPreparationCancelsWidthTransitionOwnership() {
        let controller = makeController()
        let items = (0..<20).map {
            makeDatasource(primary: "rotation-cancel-\($0)")
        }
        controller.applyChatDatasource(
            items,
            mode: .fullReload(),
            animated: false,
            invalidateLayout: true,
            suppressDefaultBottomScroll: true
        )
        let targetSize = CGSize(width: 844, height: 390)
        controller.prepareAndInstallCurrentDatasourceLayoutsForWidthTransition(
            targetViewSize: targetSize,
            layoutWidthOverride: targetSize.width
        )
        let widthGeneration = controller.layoutPreparationGeneration
        XCTAssertEqual(
            controller.activeWidthTransitionLayoutTargetSize,
            targetSize
        )

        var replacementFinished = false
        controller.prepareAndApplyCurrentDatasourceLayouts {
            replacementFinished = true
        }

        XCTAssertEqual(
            controller.layoutPreparationGeneration,
            widthGeneration + 1
        )
        XCTAssertNil(controller.activeWidthTransitionLayoutTargetSize)
        XCTAssertNil(controller.activeWidthTransitionLayoutGeneration)
        XCTAssertNil(controller.pendingWidthTransitionLayoutRemap)
        XCTAssertTrue(waitUntil { replacementFinished })
        XCTAssertNil(controller.activeWidthTransitionLayoutTargetSize)
        XCTAssertNil(controller.pendingWidthTransitionLayoutRemap)
    }

    func testControllerLayoutRemapKeepsLiveTailAcrossPortraitLandscapePortrait() throws {
        let controller = makeController()
        let items = (0..<80).map { index -> ChatViewController.Datasource in
            var item = makeDatasource(primary: "rotation-\(index)")
            item.kind = .attributedText(NSAttributedString(
                string: index.isMultiple(of: 3)
                    ? String(repeating: "width-sensitive historical message ", count: 14)
                    : "short message \(index)"
            ))
            return item
        }
        controller.applyChatDatasource(
            items,
            mode: .fullReload(),
            animated: false,
            invalidateLayout: true,
            suppressDefaultBottomScroll: true
        )
        var initialPreparationFinished = false
        controller.prepareAndApplyCurrentDatasourceLayouts {
            initialPreparationFinished = true
        }
        XCTAssertTrue(waitUntil { initialPreparationFinished })
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(controller.isNearBottom(threshold: 1))
        let operationsBeforeRotation =
            controller.scrollFrameOperationCounter.snapshot()
        let datasourceGenerationBeforeRotation =
            controller.scrollResidentMetadata.generation

        let landscapeDiagnostics = try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 844, height: 390)
        )
        XCTAssertTrue(
            controller.isNearBottom(threshold: 1),
            "Landscape remap must keep the resident live tail aligned; \(landscapeDiagnostics)"
        )
        try assertLiveTailUsesAtomicInvalidation(
            controller,
            expectedMode: .targetOffsetUpdate
        )

        let portraitDiagnostics = try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 390, height: 844)
        )
        XCTAssertTrue(
            controller.isNearBottom(threshold: 1),
            "Returning to portrait must not land in older history; \(portraitDiagnostics)"
        )
        try assertLiveTailUsesAtomicInvalidation(
            controller,
            expectedMode: .targetOffsetUpdate
        )
        XCTAssertNil(controller.pendingWidthTransitionLayoutFinalization)
        let operationsAfterRotation =
            controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(
            operationsAfterRotation[.datasourceApplies] -
                operationsBeforeRotation[.datasourceApplies],
            0,
            "Width-only rotation must remap prepared layouts without republishing identical chat data"
        )
        XCTAssertEqual(
            operationsAfterRotation[.reloads] -
                operationsBeforeRotation[.reloads],
            0,
            "Width-only rotation must not reload an unchanged datasource"
        )
        XCTAssertEqual(
            operationsAfterRotation[.offsetMutations] -
                operationsBeforeRotation[.offsetMutations],
            0,
            "Semantic bottom preservation must not use a post-commit datasource offset transaction"
        )
        XCTAssertEqual(
            controller.scrollResidentMetadata.generation,
            datasourceGenerationBeforeRotation,
            "Layout-only rotation must not publish a new datasource generation"
        )
        let committedOffsetY = controller.messagesCollectionView.contentOffset.y
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            committedOffsetY,
            accuracy: 0.001,
            "Rotation restoration must not schedule a delayed correction"
        )
    }

    func testControllerLayoutRemapPreservesVisibleMessageAcrossPortraitLandscapePortrait() throws {
        let controller = makeController()
        let items = (0..<80).map { index -> ChatViewController.Datasource in
            var item = makeDatasource(primary: "rotation-anchor-\(index)")
            item.kind = .attributedText(NSAttributedString(
                string: index.isMultiple(of: 3)
                    ? String(repeating: "width-sensitive historical message ", count: 14)
                    : "short message \(index)"
            ))
            return item
        }
        controller.applyChatDatasource(
            items,
            mode: .fullReload(),
            animated: false,
            invalidateLayout: true,
            suppressDefaultBottomScroll: true
        )
        var initialPreparationFinished = false
        controller.prepareAndApplyCurrentDatasourceLayouts {
            initialPreparationFinished = true
        }
        XCTAssertTrue(waitUntil { initialPreparationFinished })
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 40),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let capturedAnchor = try XCTUnwrap(
            controller.capturePagingAnchorIfNeeded(direction: .older)
        )
        let anchorPrimary = capturedAnchor.primary
        let portraitViewportY = capturedAnchor.viewportRelativeMinY
        let operationsBeforeRotation =
            controller.scrollFrameOperationCounter.snapshot()
        let datasourceGenerationBeforeRotation =
            controller.scrollResidentMetadata.generation

        let landscapeDiagnostics = try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 844, height: 390)
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            portraitViewportY,
            accuracy: 1,
            "Landscape remap must restore the pre-transition message anchor; \(landscapeDiagnostics)"
        )

        let portraitDiagnostics = try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 390, height: 844)
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            portraitViewportY,
            accuracy: 1,
            "Returning to portrait must restore the same message-relative anchor; \(portraitDiagnostics)"
        )
        let operationsAfterRotation =
            controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(
            operationsAfterRotation[.datasourceApplies] -
                operationsBeforeRotation[.datasourceApplies],
            0,
            "Anchored width remap must not republish identical chat data"
        )
        XCTAssertEqual(
            operationsAfterRotation[.reloads] -
                operationsBeforeRotation[.reloads],
            0,
            "Anchored width remap must not reload an unchanged datasource"
        )
        XCTAssertEqual(
            operationsAfterRotation[.offsetMutations] -
                operationsBeforeRotation[.offsetMutations],
            0,
            "Anchored rotation must not use a post-commit datasource offset transaction"
        )
        XCTAssertEqual(
            controller.scrollResidentMetadata.generation,
            datasourceGenerationBeforeRotation,
            "Anchored layout-only rotation must retain the datasource generation"
        )
        let committedViewportY = try viewportY(
            for: anchorPrimary,
            in: controller
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            committedViewportY,
            accuracy: 0.001,
            "Rotation anchor restoration must not schedule a delayed correction"
        )
    }

    private func makeTransaction(
        completion: @escaping (ChatViewportTransactionResult) -> Void
    ) -> ChatViewportTransaction {
        ChatViewportTransaction(
            snapshotDiff: ChatViewportSnapshotDiff(oldItemCount: 20, newItemCount: 30),
            contentChanges: [.reload, .structural],
            layoutChanges: [.invalidateLayout],
            initialInsets: .zero,
            anchorStrategy: .message(ChatViewportAnchor(primary: "anchor", viewportRelativeMinY: 120)),
            completion: completion
        )
    }

    private func makeController(
        collectionView: MessagesCollectionView? = nil
    ) -> ChatViewController {
        let controller = ChatViewController()
        if let collectionView {
            controller.messagesCollectionView = collectionView
        }
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        controller.showSkeletonObserver.accept(false)
        return controller
    }

    private func installDetachedComposerGeometry(
        in controller: ChatViewController,
        visualHeight: CGFloat = ModernXabberInputView.defaultBarHeight
    ) {
        let horizontalInset = ModernXabberInputView.edgeHorizontalInset
        controller.xabberInputView.heightConstraint?.constant = visualHeight
        controller.xabberInputView.frame = CGRect(
            x: horizontalInset,
            y: controller.view.bounds.height - visualHeight,
            width: controller.view.bounds.width - 2 * horizontalInset,
            height: visualHeight
        )
        controller.updateChatCollectionInsets(inputHeight: visualHeight)
    }

    private func remapControllerForSizeTransition(
        _ controller: ChatViewController,
        to size: CGSize
    ) throws -> String {
        let flowLayout = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout
        )
        let sectionInsets = flowLayout.sectionInset.horizontal
#if DEBUG || CHAT_PERFORMANCE_LAB
        flowLayout.resetWidthTransitionInvalidationDiagnostics()
#endif
        var preparationFinished = false
        controller.prepareAndInstallCurrentDatasourceLayoutsForWidthTransition(
            targetViewSize: size,
            layoutWidthOverride: max(1, size.width - sectionInsets)
        ) {
            preparationFinished = true
        }
        controller.view.bounds.size = size
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(
            controller.messagesCollectionView.bounds.width,
            size.width,
            accuracy: 0.001,
            "The hosted transition must install the target collection viewport before committing its width cache"
        )
        XCTAssertEqual(
            controller.messagesCollectionView.bounds.height,
            size.height,
            accuracy: 0.001
        )
        let installedLayoutWidth = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout
        ).cache.reuseSnapshot().key(
            forPrimary: try XCTUnwrap(controller.datasource.first?.primary)
        )?.context.normalizedWidth
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(installedLayoutWidth),
            max(1, size.width - sectionInsets) + 0.001,
            "A narrower viewport must atomically activate a compatible retained snapshot before FlowLayout queries item sizes"
        )
        XCTAssertTrue(waitUntil { preparationFinished })
        controller.messagesCollectionView.layoutIfNeeded()
#if DEBUG || CHAT_PERFORMANCE_LAB
        let diagnostics = flowLayout.widthTransitionInvalidationDiagnostics
        let targetOffsetDiagnostics =
            flowLayout.widthTransitionTargetOffsetDiagnostics
        let commitModes =
            flowLayout.widthTransitionInvalidationCommitModes
        XCTAssertFalse(
            diagnostics.isEmpty,
            "A real hosted width transition must consume a staged semantic invalidation"
        )
        return (
            diagnostics.map(\.description) +
            targetOffsetDiagnostics.map(\.description) +
            commitModes.map { "commitMode=\($0.rawValue)" }
        ).joined(separator: " | ")
#else
        return "diagnostics unavailable"
#endif
    }

    private func assertLiveTailUsesAtomicInvalidation(
        _ controller: ChatViewController,
        expectedMode: ChatWidthTransitionInvalidationCommitMode
    ) throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let flowLayout = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout
        )
        XCTAssertEqual(
            flowLayout.widthTransitionInvalidationCommitModes.last,
            expectedMode,
            "A late live-tail cache must use the exact target-offset update; a retained cache stays in the natural bounds transaction"
        )
        XCTAssertTrue(
            flowLayout.widthTransitionTargetOffsetDiagnostics.isEmpty,
            "Live-tail target ownership must remain distinct from message-anchor diagnostics"
        )
#endif
    }

    private func viewportY(
        for primary: String,
        in controller: ChatViewController
    ) throws -> CGFloat {
        let section = try XCTUnwrap(controller.datasourceSnapshot.primaryIndex[primary])
        let indexPath = IndexPath(item: 0, section: section)
        let frame = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(at: indexPath)?.frame
                ?? controller.messagesCollectionView.cellForItem(at: indexPath)?.frame
        )
        return frame.minY - controller.messagesCollectionView.contentOffset.y
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func makeDatasource(primary: String) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: "Peer"),
            messageId: primary,
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: primary)),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: true,
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
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: primary,
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .read,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }
}

final class ChatTailAppendBatchCompletionCollectionView: MessagesCollectionView {
    var beforeForwardingBatchCompletion: (() -> Void)?

    override func performBatchUpdates(
        _ updates: (() -> Void)?,
        completion: ((Bool) -> Void)? = nil
    ) {
        super.performBatchUpdates(updates) { [weak self] finished in
            self?.layoutIfNeeded()
            self?.beforeForwardingBatchCompletion?()
            completion?(finished)
        }
    }
}

@MainActor
final class ChatLayoutLifecycleTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatLayoutLifecycleTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testLargestDynamicTypePreservesBottomAndExplicitAnchorAcrossFirstFrameRemap() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        for mode in ChatLayoutLifecycleMode.allCases {
            let anchorIndex = 120
            let hosted = try makeHostedController(
                contentSizeCategory: .accessibilityExtraExtraExtraLarge,
                suffix: "dynamic-type-\(mode.rawValue)",
                seededMessageCount: 320,
                initialAnchorIndex: mode == .anchor ? anchorIndex : nil
            )
            let controller = hosted.controller
            let collectionView = hosted.collectionView
            defer {
                controller.datasourceDidSetForTests = nil
                controller.initialFirstFrameMappingBarrierForTests = nil
                controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = nil
                controller.performanceFixtureRemoteHistoryActionHandler = nil
                controller.performTerminalChatResourceTeardownForTesting()
            }

            var publications: [[ChatViewController.Datasource]] = []
            var commitDiagnostics: [ChatPerformanceInitialFrameCommitDiagnostics] = []
            var mappingBarrierThreads: [Bool] = []
            var remoteActions: [ChatPerformanceFixtureRemoteHistoryAction] = []
            controller.datasourceDidSetForTests = { publications.append($0) }
            controller.initialFirstFrameMappingBarrierForTests = {
                mappingBarrierThreads.append(Thread.isMainThread)
            }
            controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
                commitDiagnostics.append($0)
            }
            controller.performanceFixtureRemoteHistoryActionHandler = { action in
                remoteActions.append(action)
                return .consumedByFixtureTransport
            }
            controller.scrollFrameOperationCounter.reset()
            collectionView.resetRecordedEvents()

            var presentationCompleted = false
            controller.prepareForStackedNavigationPresentation(
                targetBounds: hosted.host.view.bounds
            ) {
                presentationCompleted = true
            }
            XCTAssertTrue(
                waitUntil { presentationCompleted && commitDiagnostics.count == 1 },
                "\(mode.rawValue): production first-frame commit did not complete"
            )
            controller.view.layoutIfNeeded()
            collectionView.layoutIfNeeded()

            XCTAssertEqual(
                controller.traitCollection.preferredContentSizeCategory,
                .accessibilityExtraExtraExtraLarge,
                mode.rawValue
            )
            XCTAssertEqual(mappingBarrierThreads.count, 1, mode.rawValue)
            XCTAssertEqual(mappingBarrierThreads, [false], mode.rawValue)
            XCTAssertEqual(publications.count, 1, mode.rawValue)
            let publishedRows = try XCTUnwrap(publications.first)
            let publishedMessageRows = publishedRows.filter {
                ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .message
            }
            let publishedDateRows = publishedRows.filter {
                ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .date
            }
            XCTAssertEqual(publishedMessageRows.count, 80, mode.rawValue)
            XCTAssertEqual(publishedDateRows.count, 1, mode.rawValue)
            XCTAssertTrue(
                publishedMessageRows.allSatisfy { !$0.isFakeMessage },
                mode.rawValue
            )
            XCTAssertTrue(
                publishedDateRows.allSatisfy(\.isFakeMessage),
                mode.rawValue
            )
            XCTAssertFalse(
                publishedRows.contains {
                    ChatVisiblePositionPolicy.rowKind(for: $0.kind) ==
                        .skeleton
                },
                mode.rawValue
            )
            XCTAssertEqual(controller.initialFirstContentApplyCount, 1, mode.rawValue)
            XCTAssertEqual(commitDiagnostics.count, 1, mode.rawValue)
            let diagnostics = try XCTUnwrap(commitDiagnostics.first)
            XCTAssertEqual(diagnostics.requestSource, mode == .anchor ? .search : nil)
            XCTAssertEqual(diagnostics.requestHighlight, mode == .anchor, mode.rawValue)
            XCTAssertEqual(diagnostics.targetKind, mode == .anchor ? .anchor : .latest)
            XCTAssertFalse(diagnostics.preparedOnMainThread, mode.rawValue)
            XCTAssertFalse(diagnostics.mappedOnMainThread, mode.rawValue)
            XCTAssertGreaterThan(diagnostics.storeQueryCount, 0, mode.rawValue)
            XCTAssertLessThanOrEqual(diagnostics.storeQueryCount, 2, mode.rawValue)
            XCTAssertEqual(diagnostics.mainThreadStoreQueryCount, 0, mode.rawValue)
            XCTAssertEqual(diagnostics.fullScanCount, 0, mode.rawValue)
            XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 80, mode.rawValue)
            XCTAssertEqual(diagnostics.realDatasourceApplyCount, 1, mode.rawValue)
            XCTAssertEqual(diagnostics.atomicLayoutCommitCount, 1, mode.rawValue)
            XCTAssertEqual(diagnostics.realRowCount, 80, mode.rawValue)
            XCTAssertLessThanOrEqual(
                diagnostics.viewportDiagnostics.programmaticOffsetMutationCount,
                1,
                mode.rawValue
            )
            XCTAssertEqual(
                diagnostics.viewportDiagnostics.finalAlignmentCorrectionCount,
                0,
                mode.rawValue
            )
            XCTAssertEqual(
                diagnostics.viewportDiagnostics.nextRunLoopCorrectionCount,
                0,
                mode.rawValue
            )
            XCTAssertEqual(
                controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
                1,
                mode.rawValue
            )
            XCTAssertEqual(
                controller.scrollFrameOperationCounter.snapshot()[.reloads],
                1,
                mode.rawValue
            )
            XCTAssertEqual(
                collectionView.recordedEvents.filter { $0 == .reload }.count,
                1,
                mode.rawValue
            )
            XCTAssertTrue(remoteActions.isEmpty, mode.rawValue)
            XCTAssertFalse(controller.showSkeletonObserver.value, mode.rawValue)
            XCTAssertFalse(
                controller.datasource.contains {
                    ChatVisiblePositionPolicy.rowKind(for: $0.kind) ==
                        .skeleton
                },
                mode.rawValue
            )

            switch mode {
            case .latest:
                XCTAssertLessThanOrEqual(bottomDistance(in: controller), 0.5, mode.rawValue)
                XCTAssertNil(diagnostics.viewportDiagnostics.anchorError, mode.rawValue)
                XCTAssertEqual(
                    controller.datasource.last?.primary,
                    "largest-dynamic-type-latest-319",
                    mode.rawValue
                )
            case .anchor:
                let anchorPrimary = "largest-dynamic-type-anchor-\(anchorIndex)"
                XCTAssertLessThanOrEqual(
                    try XCTUnwrap(diagnostics.viewportDiagnostics.anchorError),
                    1,
                    mode.rawValue
                )
                XCTAssertTrue(controller.datasource.contains { $0.primary == anchorPrimary })
                XCTAssertFalse(controller.datasource.contains {
                    $0.primary == "largest-dynamic-type-anchor-319"
                })
                let section = try XCTUnwrap(controller.datasourceSnapshot.primaryIndex[anchorPrimary])
                let attributes = try XCTUnwrap(
                    collectionView.layoutAttributesForItem(
                        at: IndexPath(item: 0, section: section)
                    )
                )
                let expectedAnchorY = ChatAnchorCenteringPolicy.viewportRelativeMinY(
                    viewportHeight: collectionView.bounds.height,
                    targetHeight: attributes.frame.height
                )
                XCTAssertEqual(
                    try viewportY(for: anchorPrimary, in: controller),
                    expectedAnchorY,
                    accuracy: 1,
                    mode.rawValue
                )
            }

            let committedDatasourceGeneration = controller.datasetMappingGeneration
            let committedSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
            let committedLayoutGeneration = controller.layoutPreparationGeneration
            let committedOffset = collectionView.contentOffset
            let committedEventCount = collectionView.recordedEvents.count
            let committedOperations = controller.scrollFrameOperationCounter.snapshot()
            let committedPublicationCount = publications.count
            let committedReceiptCount = controller.initialFirstContentApplyCount
            XCTAssertTrue(waitForCausalMainQueueDrain(), mode.rawValue)
            XCTAssertEqual(collectionView.contentOffset, committedOffset, mode.rawValue)
            XCTAssertEqual(collectionView.recordedEvents.count, committedEventCount, mode.rawValue)
            XCTAssertEqual(
                controller.scrollFrameOperationCounter.snapshot(),
                committedOperations,
                mode.rawValue
            )
            XCTAssertEqual(publications.count, committedPublicationCount, mode.rawValue)
            XCTAssertEqual(controller.initialFirstContentApplyCount, committedReceiptCount, mode.rawValue)
            XCTAssertEqual(controller.datasetMappingGeneration, committedDatasourceGeneration, mode.rawValue)
            XCTAssertEqual(
                controller.bootstrapSkeletonMappingGeneration,
                committedSkeletonGeneration,
                mode.rawValue
            )
            XCTAssertEqual(controller.layoutPreparationGeneration, committedLayoutGeneration, mode.rawValue)
        }
#else
        throw XCTSkip("Production first-frame diagnostics are available in DEBUG/lab builds")
#endif
    }

    func testBackgroundForegroundAfterContentPreservesDatasourceAnchorAndNeverShowsSkeletonOrLatest() throws {
        for mode in ChatLayoutLifecycleMode.allCases {
            let hosted = try makeHostedController(
                contentSizeCategory: .large,
                suffix: "committed-\(mode.rawValue)"
            )
            let controller = hosted.controller
            let collectionView = hosted.collectionView
            defer { controller.performTerminalChatResourceTeardownForTesting() }

            var mappingContext = controller.captureDatasourceMappingContext()
            mappingContext.showSkeleton = false
            let mappingResult = controller.mapDataset(
                dataset: makeStorageRows(
                    prefix: "committed-\(mode.rawValue)",
                    owner: controller.owner,
                    jid: controller.jid,
                    count: 80
                ),
                context: mappingContext
            )
            let anchorPrimary = mappingResult.datasource[40].primary
            let requestedAnchorY: CGFloat = 180
            var transactionResult: ChatViewportTransactionResult?
            controller.applyChatDatasource(
                mappingResult.datasource,
                mode: .fullReload(),
                animated: false,
                invalidateLayout: false,
                preparedLayouts: mappingResult.layoutSnapshot,
                suppressDefaultBottomScroll: true,
                forceBottomAlignmentTarget: mode == .latest
                    ? .newestRealMessage
                    : nil,
                anchorRestorePhase: mode == .anchor
                    ? .applyTransaction
                    : .none,
                anchorPrimary: mode == .anchor ? anchorPrimary : nil,
                restoreAnchor: mode == .anchor
                    ? ChatHistoryPageAnchor(
                        primary: anchorPrimary,
                        viewportRelativeMinY: requestedAnchorY
                    )
                    : nil,
                presentationCommitMode: .atomicInitialFrame,
                transactionCompletion: { transactionResult = $0 }
            )
            guard case .committed = transactionResult else {
                return XCTFail("\(mode.rawValue): committed-content setup must succeed")
            }

            let descriptor = ChatLocalFirstFrameDescriptor(
                target: mode == .latest
                    ? .latest
                    : .message(ChatTimelineAnchor(
                        primary: anchorPrimary,
                        archivedId: mappingResult.datasource[40].archivedId,
                        messageId: mappingResult.datasource[40].messageId,
                        date: mappingResult.datasource[40].sentDate
                    )),
                request: nil
            )
            controller.initialLocalFirstFramePhase = .committed(descriptor)
            controller.initialFirstContentApplyCount = 1
            controller.appliedBootstrapLoadingState = .content
            controller.showSkeletonObserver.accept(false)
            controller.loadDatasourceObserver.accept(true)
            controller.syncCurrentPage(
                with: ChatDatasetWindow(
                    minIndex: 0,
                    maxIndex: mappingResult.datasource.count
                )
            )
            controller.virtualTimelineState = ChatVirtualTimelineState(
                conversationKey: controller.chatTimelineConversationKey,
                segments: [
                    .loadedRange(
                        oldestArchiveId: mappingResult.datasource.first?.archivedId,
                        newestArchiveId: mappingResult.datasource.last?.archivedId
                    ),
                    .liveTail
                ],
                oldest: nil,
                newest: nil,
                residentPrimaryKeys: mappingResult.datasource.map(\.primary),
                residentArchivedIds: mappingResult.datasource.compactMap(\.archivedId),
                activeRemoteLoad: nil,
                activePlaceholder: nil,
                isResidentAtLiveTail: true
            )
            controller.messagesCollectionView.layoutIfNeeded()

            var skeletonEmissions: [Bool] = []
            var loadingEmissions: [Bool] = []
            let skeletonDisposable = controller.showSkeletonObserver
                .asObservable()
                .subscribe(onNext: { skeletonEmissions.append($0) })
            let loadingDisposable = controller.loadDatasourceObserver
                .asObservable()
                .subscribe(onNext: { loadingEmissions.append($0) })
            skeletonEmissions.removeAll(keepingCapacity: true)
            loadingEmissions.removeAll(keepingCapacity: true)
            defer {
                skeletonDisposable.dispose()
                loadingDisposable.dispose()
            }

            collectionView.resetRecordedEvents()
            controller.scrollFrameOperationCounter.reset()
            let committed = captureCommittedSnapshot(controller)
            let semanticOffsetBefore = try semanticOffset(
                mode: mode,
                anchorPrimary: anchorPrimary,
                controller: controller
            )

            controller.handleApplicationDidEnterBackground()
            XCTAssertFalse(controller.isInitialFramePresentationLifecycleEligible, mode.rawValue)
            XCTAssertEqual(captureCommittedSnapshot(controller), committed, "\(mode.rawValue) background")
            XCTAssertEqual(
                try semanticOffset(
                    mode: mode,
                    anchorPrimary: anchorPrimary,
                    controller: controller
                ),
                semanticOffsetBefore,
                accuracy: mode == .latest ? 0.5 : 1,
                "\(mode.rawValue) background semantic position"
            )

            controller.willEnterForeground()
            controller.didBecomeActive()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(controller.isInitialFramePresentationLifecycleEligible, mode.rawValue)
            XCTAssertEqual(captureCommittedSnapshot(controller), committed, "\(mode.rawValue) foreground")
            XCTAssertEqual(
                try semanticOffset(
                    mode: mode,
                    anchorPrimary: anchorPrimary,
                    controller: controller
                ),
                semanticOffsetBefore,
                accuracy: mode == .latest ? 0.5 : 1,
                "\(mode.rawValue) foreground semantic position"
            )
            XCTAssertTrue(waitForCausalMainQueueDrain(), mode.rawValue)

            XCTAssertEqual(captureCommittedSnapshot(controller), committed, "\(mode.rawValue) delayed")
            XCTAssertTrue(skeletonEmissions.isEmpty, mode.rawValue)
            XCTAssertTrue(loadingEmissions.isEmpty, mode.rawValue)
            XCTAssertTrue(
                collectionView.recordedEvents.filter { $0 == .reload || $0 == .offset }.isEmpty,
                mode.rawValue
            )
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.offsetMutations], 0)
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.layoutFlushes], 0)
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.storeQueries], 0)
            XCTAssertNil(controller.pendingInitialFrameLifecyclePresentation, mode.rawValue)
        }
    }

    private func makeHostedController(
        contentSizeCategory: UIContentSizeCategory,
        suffix: String,
        seededMessageCount: Int = 0,
        initialAnchorIndex: Int? = nil
    ) throws -> ChatLayoutLifecycleHostedController {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let collectionView = ChatLayoutLifecycleRecordingCollectionView()
        let controller = ChatViewController()
        controller.messagesCollectionView = collectionView
        controller.owner = "layout-owner-\(suffix)@example.com"
        controller.jid = "layout-peer-\(suffix)@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        try seedConversation(
            controller,
            messageCount: seededMessageCount,
            messagePrefix: "largest-\(suffix)"
        )
        if let initialAnchorIndex {
            controller.queueOpenMessageRequest(
                ChatOpenMessageRequest(
                    chatJid: controller.jid,
                    owner: controller.owner,
                    conversationType: .regular,
                    anchor: ChatMessageAnchorRef(
                        messagePrimary: "largest-\(suffix)-\(initialAnchorIndex)",
                        archivedId: archiveId(for: initialAnchorIndex),
                        messageId: "message-largest-\(suffix)-\(initialAnchorIndex)",
                        authorId: nil,
                        bodyFingerprint: nil,
                        sourceDate: Date(
                            timeIntervalSince1970:
                                1_700_000_000 + Double(initialAnchorIndex)
                        )
                    ),
                    highlight: true,
                    markReadOnVisible: false,
                    source: .search
                )
            )
        }

        host.addChild(controller)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
            forChild: controller
        )
        controller.loadViewIfNeeded()
        controller.view.frame = host.view.bounds
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        host.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.configureDataset()
        XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, contentSizeCategory)
        return ChatLayoutLifecycleHostedController(
            host: host,
            controller: controller,
            collectionView: collectionView
        )
    }

    private func seedConversation(
        _ controller: ChatViewController,
        messageCount: Int = 0,
        messagePrefix: String = "layout"
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType
        )
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = controller.conversationType
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        let messages = makeStorageRows(
            prefix: messagePrefix,
            owner: controller.owner,
            jid: controller.jid,
            count: messageCount
        )
        try realm.write {
            messages.forEach { realm.add($0, update: .modified) }
            if let last = messages.last {
                chat.lastMessage = last
                chat.lastMessageId = last.messageId
                chat.messageDate = last.date
                chat.syncSnapshotLastArchiveId = last.archivedId
                chat.fullArchiveLoaded = true
            }
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = chat.syncSnapshotLastArchiveId
            archiveState.olderArchiveEndReached = messages.isNotEmpty
            archiveState.newerLiveEdgeReached = true
            if let first = messages.first?.archivedId,
               let last = messages.last?.archivedId {
                archiveState.loadedRanges = [
                    RegularChatArchiveIDRange(
                        oldestArchiveId: first,
                        newestArchiveId: last
                    )
                ]
                archiveState.recomputeBoundsAndGaps()
            }
        }
    }

    private func makeStorageRows(
        prefix: String,
        owner: String,
        jid: String,
        count: Int
    ) -> [MessageStorageItem] {
        (0..<count).map { index in
            let primary = "\(prefix)-\(index)"
            let message = MessageStorageItem()
            message.primary = primary
            message.owner = owner
            message.opponent = jid
            message.conversationType = .regular
            message.messageId = "message-\(primary)"
            message.archivedId = archiveId(for: index)
            message.body = index.isMultiple(of: 3)
                ? String(repeating: "Largest Dynamic Type self-sizing message ", count: 10)
                : "Message \(index)"
            message.legacyBody = message.body
            message.date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            message.sentDate = message.date
            message.outgoing = index.isMultiple(of: 4)
            message.displayAs = .text
            message.state = .deliver
            message.isRead = true
            return message
        }
    }

    private func archiveId(for index: Int) -> String {
        String((Int64(1_700_000_000) + Int64(index)) * 1_000_000)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func waitForCausalMainQueueDrain() -> Bool {
        var completed = false
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    completed = true
                }
            }
        }
        return waitUntil { completed }
    }

    private func captureCommittedSnapshot(
        _ controller: ChatViewController
    ) -> ChatCommittedLifecycleSnapshot {
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        return ChatCommittedLifecycleSnapshot(
            primaries: controller.datasource.map(\.primary),
            messageIds: controller.datasource.map(\.messageId),
            datasourceSnapshotPrimaries: controller.datasourceSnapshot.items.map(\.primary),
            residentWindow: controller.residentDatasetWindow,
            residentPrimaryKeys: controller.virtualTimelineState.residentPrimaryKeys,
            residentArchivedIds: controller.virtualTimelineState.residentArchivedIds,
            virtualTimelineState: controller.virtualTimelineState,
            datasourceGeneration: controller.datasetMappingGeneration,
            skeletonGeneration: controller.bootstrapSkeletonMappingGeneration,
            layoutGeneration: controller.layoutPreparationGeneration,
            contentSize: controller.messagesCollectionView.contentSize,
            contentOffset: controller.messagesCollectionView.contentOffset,
            descriptorPhase: controller.initialLocalFirstFramePhase,
            loadingState: controller.appliedBootstrapLoadingState,
            firstContentReceiptCount: controller.initialFirstContentApplyCount,
            skeletonVisible: controller.showSkeletonObserver.value,
            datasourceLoadingEnabled: controller.loadDatasourceObserver.value,
            pendingForceLatestOpen: controller.pendingForceLatestOpen
        )
    }

    private func semanticOffset(
        mode: ChatLayoutLifecycleMode,
        anchorPrimary: String,
        controller: ChatViewController
    ) throws -> CGFloat {
        switch mode {
        case .latest:
            return bottomDistance(in: controller)
        case .anchor:
            return try viewportY(for: anchorPrimary, in: controller)
        }
    }

    private func bottomDistance(in controller: ChatViewController) -> CGFloat {
        ChatTailAppendBottomPinPolicy.bottomDistance(
            contentHeight: controller.messagesCollectionView.contentSize.height,
            viewportHeight: controller.messagesCollectionView.bounds.height,
            contentInsets: controller.messagesCollectionView.contentInset,
            contentOffsetY: controller.messagesCollectionView.contentOffset.y
        )
    }

    private func viewportY(
        for primary: String,
        in controller: ChatViewController
    ) throws -> CGFloat {
        let section = try XCTUnwrap(controller.datasourceSnapshot.primaryIndex[primary])
        let indexPath = IndexPath(item: 0, section: section)
        let frame = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(at: indexPath)?.frame
                ?? controller.messagesCollectionView.cellForItem(at: indexPath)?.frame
        )
        return frame.minY - controller.messagesCollectionView.contentOffset.y
    }
}

private enum ChatLayoutLifecycleMode: String, CaseIterable {
    case latest
    case anchor
}

private struct ChatLayoutLifecycleHostedController {
    let host: UIViewController
    let controller: ChatViewController
    let collectionView: ChatLayoutLifecycleRecordingCollectionView
}

private struct ChatCommittedLifecycleSnapshot: Equatable {
    let primaries: [String]
    let messageIds: [String]
    let datasourceSnapshotPrimaries: [String]
    let residentWindow: ChatDatasetWindow
    let residentPrimaryKeys: [String]
    let residentArchivedIds: [String]
    let virtualTimelineState: ChatVirtualTimelineState
    let datasourceGeneration: Int
    let skeletonGeneration: Int
    let layoutGeneration: Int
    let contentSize: CGSize
    let contentOffset: CGPoint
    let descriptorPhase: ChatLocalFirstFramePhase
    let loadingState: ChatBootstrapLoadingState?
    let firstContentReceiptCount: Int
    let skeletonVisible: Bool
    let datasourceLoadingEnabled: Bool
    let pendingForceLatestOpen: Bool
}

final class ChatLayoutLifecycleRecordingCollectionView: MessagesCollectionView {
    enum Event: Equatable {
        case reload
        case layout
        case offset
    }

    private(set) var recordedEvents: [Event] = []
    private var recordsEvents = false

    func resetRecordedEvents() {
        recordedEvents.removeAll(keepingCapacity: true)
        recordsEvents = true
    }

    override func reloadData() {
        if recordsEvents { recordedEvents.append(.reload) }
        super.reloadData()
    }

    override func layoutSubviews() {
        if recordsEvents { recordedEvents.append(.layout) }
        super.layoutSubviews()
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if recordsEvents { recordedEvents.append(.offset) }
        super.setContentOffset(contentOffset, animated: animated)
    }
}

// MARK: - Exact local-target production-path acceptance

@MainActor
class ChatLocalTargetProductionTestCase: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatLocalTargetProductionTestCase-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func makeHostedController(
        suffix: String,
        messageRanges: [Range<Int>],
        coverageRanges: [Range<Int>],
        initialTargetIndex: Int? = nil,
        targetBounds: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844)
    ) throws -> ChatLocalTargetHostedController {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = targetBounds

        let collectionView = ChatLayoutLifecycleRecordingCollectionView()
        let controller = ChatViewController()
        controller.messagesCollectionView = collectionView
        controller.owner = "exact-owner-\(suffix)@example.com"
        controller.jid = "exact-peer-\(suffix)@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        try seedConversation(
            controller: controller,
            messageRanges: messageRanges,
            coverageRanges: coverageRanges
        )
        if let initialTargetIndex {
            controller.queueOpenMessageRequest(
                makeExactRequest(index: initialTargetIndex, controller: controller)
            )
        }

        host.addChild(controller)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .large),
            forChild: controller
        )
        controller.loadViewIfNeeded()
        controller.view.frame = host.view.bounds
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        host.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        return ChatLocalTargetHostedController(
            host: host,
            controller: controller,
            collectionView: collectionView
        )
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    func installEvidence(
        on controller: ChatViewController
    ) -> ChatLocalTargetProductionEvidence {
        let evidence = ChatLocalTargetProductionEvidence()
        controller.datasourceDidSetForTests = { [weak evidence] rows in
            evidence?.publications.append(rows)
        }
        controller.initialFirstFrameMappingBarrierForTests = { [weak evidence] in
            evidence?.mappingBarrierMainThreadFlags.append(Thread.isMainThread)
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            [weak evidence] diagnostics in
            evidence?.commitDiagnostics.append(diagnostics)
        }
        controller.performanceFixtureRemoteHistoryActionHandler = {
            [weak evidence] action in
            evidence?.remoteActions.append(action)
            return .consumedByFixtureTransport
        }
        return evidence
    }
#endif

    func clearEvidenceHooks(_ controller: ChatViewController) {
#if DEBUG || CHAT_PERFORMANCE_LAB
        controller.datasourceDidSetForTests = nil
        controller.initialFirstFrameMappingBarrierForTests = nil
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = nil
        controller.performanceFixtureRemoteHistoryActionHandler = nil
#endif
    }

    func prepareInitialFrame(
        _ hosted: ChatLocalTargetHostedController,
        evidence: ChatLocalTargetProductionEvidence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var completed = false
        hosted.controller.prepareForStackedNavigationPresentation(
            targetBounds: hosted.host.view.bounds
        ) {
            completed = true
        }
        XCTAssertTrue(
            waitUntil {
                completed && evidence.commitDiagnostics.count == 1
            },
            "production first-frame commit did not complete",
            file: file,
            line: line
        )
        hosted.controller.view.layoutIfNeeded()
        hosted.collectionView.layoutIfNeeded()
    }

    @discardableResult
    func assertExactLocalFirstFrame(
        _ hosted: ChatLocalTargetHostedController,
        evidence: ChatLocalTargetProductionEvidence,
        targetIndex: Int,
        excludedLatestIndex: Int,
        expectedRemoteActionCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatPerformanceInitialFrameCommitDiagnostics {
        let controller = hosted.controller
        let targetPrimary = messagePrimary(for: targetIndex)
        let excludedLatestPrimary = messagePrimary(for: excludedLatestIndex)

        XCTAssertEqual(evidence.mappingBarrierMainThreadFlags.count, 1, file: file, line: line)
        XCTAssertEqual(evidence.mappingBarrierMainThreadFlags, [false], file: file, line: line)
        XCTAssertEqual(evidence.publications.count, 1, file: file, line: line)
        let publishedRows = try XCTUnwrap(evidence.publications.first, file: file, line: line)
        let publishedMessageRows = publishedRows.filter {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .message
        }
        let publishedDateRows = publishedRows.filter {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .date
        }
        XCTAssertEqual(
            publishedMessageRows.count,
            ChatInitialFirstFrameHistoryConfiguration.pageSize,
            file: file,
            line: line
        )
        XCTAssertEqual(publishedDateRows.count, 1, file: file, line: line)
        XCTAssertEqual(
            publishedRows.count,
            publishedMessageRows.count + publishedDateRows.count,
            file: file,
            line: line
        )
        XCTAssertTrue(
            publishedMessageRows.allSatisfy { !$0.isFakeMessage },
            file: file,
            line: line
        )
        XCTAssertTrue(
            publishedDateRows.allSatisfy { $0.isFakeMessage },
            file: file,
            line: line
        )
        XCTAssertFalse(
            publishedRows.contains {
                ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
            },
            file: file,
            line: line
        )
        XCTAssertTrue(
            publishedMessageRows.contains { $0.primary == targetPrimary },
            file: file,
            line: line
        )
        XCTAssertFalse(
            publishedMessageRows.contains { $0.primary == excludedLatestPrimary },
            "the global latest frame must never publish before the exact local target",
            file: file,
            line: line
        )
        XCTAssertEqual(controller.datasource.map(\.primary), publishedRows.map(\.primary), file: file, line: line)
        XCTAssertFalse(controller.showSkeletonObserver.value, file: file, line: line)
        XCTAssertFalse(
            controller.datasource.contains {
                ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
            },
            file: file,
            line: line
        )
        XCTAssertFalse(controller.virtualTimelineState.isResidentAtLiveTail, file: file, line: line)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1, file: file, line: line)
        XCTAssertNil(controller.pendingOpenMessageRequest, file: file, line: line)
        XCTAssertNil(controller.activeAnchorExecutionState, file: file, line: line)
        XCTAssertEqual(evidence.remoteActions.count, expectedRemoteActionCount, file: file, line: line)

        XCTAssertEqual(evidence.commitDiagnostics.count, 1, file: file, line: line)
        let diagnostics = try XCTUnwrap(evidence.commitDiagnostics.first, file: file, line: line)
        XCTAssertEqual(diagnostics.requestSource, .search, file: file, line: line)
        XCTAssertTrue(diagnostics.requestHighlight, file: file, line: line)
        XCTAssertEqual(diagnostics.targetKind, .anchor, file: file, line: line)
        XCTAssertFalse(diagnostics.preparedOnMainThread, file: file, line: line)
        XCTAssertFalse(diagnostics.mappedOnMainThread, file: file, line: line)
        XCTAssertGreaterThan(diagnostics.storeQueryCount, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(diagnostics.storeQueryCount, 2, file: file, line: line)
        XCTAssertEqual(diagnostics.mainThreadStoreQueryCount, 0, file: file, line: line)
        XCTAssertEqual(diagnostics.fullScanCount, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            diagnostics.maxCandidateCount,
            ChatInitialFirstFrameHistoryConfiguration.pageSize,
            file: file,
            line: line
        )
        XCTAssertEqual(diagnostics.realDatasourceApplyCount, 1, file: file, line: line)
        XCTAssertEqual(diagnostics.atomicLayoutCommitCount, 1, file: file, line: line)
        XCTAssertEqual(
            diagnostics.realRowCount,
            ChatInitialFirstFrameHistoryConfiguration.pageSize,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            diagnostics.viewportDiagnostics.programmaticOffsetMutationCount,
            1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(diagnostics.viewportDiagnostics.anchorError, file: file, line: line),
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.viewportDiagnostics.finalAlignmentCorrectionCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.viewportDiagnostics.nextRunLoopCorrectionCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.reloads],
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            hosted.collectionView.recordedEvents.filter { $0 == .reload }.count,
            1,
            file: file,
            line: line
        )
        try assertCentered(primary: targetPrimary, in: controller, file: file, line: line)
        return diagnostics
    }

    func assertCentered(
        primary: String,
        in controller: ChatViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        controller.messagesCollectionView.layoutIfNeeded()
        let section = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[primary],
            file: file,
            line: line
        )
        let indexPath = IndexPath(item: 0, section: section)
        let attributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(at: indexPath),
            file: file,
            line: line
        )
        let expectedViewportY = ChatAnchorCenteringPolicy.viewportRelativeMinY(
            viewportHeight: controller.messagesCollectionView.bounds.height,
            targetHeight: attributes.frame.height
        )
        let actualViewportY = try exactTargetViewportY(
            primary: primary,
            controller: controller,
            file: file,
            line: line
        )
        XCTAssertEqual(actualViewportY, expectedViewportY, accuracy: 1, file: file, line: line)
    }

    func exactTargetViewportY(
        primary: String,
        controller: ChatViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGFloat {
        controller.messagesCollectionView.layoutIfNeeded()
        let section = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[primary],
            file: file,
            line: line
        )
        let attributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: section)
            ),
            file: file,
            line: line
        )
        return attributes.frame.minY -
            controller.messagesCollectionView.contentOffset.y
    }

    func makeExactRequest(
        index: Int,
        controller: ChatViewController
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: controller.jid,
            owner: controller.owner,
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: messagePrimary(for: index),
                archivedId: archiveId(for: index),
                messageId: messageId(for: index),
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: messageDate(for: index)
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
    }

    func persistGapRepair(
        controller: ChatViewController,
        missingRange: Range<Int>
    ) throws {
        let realm = try WRealm.safe()
        let archiveState = try XCTUnwrap(
            realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: controller.jid,
                    owner: controller.owner,
                    conversationType: .regular
                )
            )
        )
        var didObserveInitialCoverage = false
        var didObserveClosedGap = false
        let archiveStatePrimary = archiveState.primary
        let observation = realm.objects(RegularChatArchiveSyncStateStorageItem.self)
            .filter("primary == %@", archiveStatePrimary)
            .observe { change in
                switch change {
                case .initial:
                    didObserveInitialCoverage = true
                case .update(let rows, _, _, _):
                    if rows.first?.knownGaps.isEmpty == true {
                        didObserveClosedGap = true
                    }
                case .error(let error):
                    XCTFail("gap-repair coverage observation failed: \(error)")
                }
            }
        defer { observation.invalidate() }
        XCTAssertTrue(waitUntil { didObserveInitialCoverage })
        try realm.write {
            missingRange.forEach { index in
                realm.add(makeMessage(index: index, controller: controller), update: .modified)
            }
            archiveState.loadedRanges = [
                RegularChatArchiveIDRange(
                    oldestArchiveId: archiveId(for: 0),
                    newestArchiveId: archiveId(for: 399)
                )
            ]
            archiveState.recomputeBoundsAndGaps()
        }
        XCTAssertTrue(archiveState.knownGaps.isEmpty)
        XCTAssertTrue(
            waitUntil { didObserveClosedGap },
            "the persisted background repair must cross a causal Realm notification boundary"
        )
    }

    func messagePrimary(for index: Int) -> String {
        "exact-message-\(index)"
    }

    func messageId(for index: Int) -> String {
        "exact-message-id-\(index)"
    }

    func archiveId(for index: Int) -> String {
        String((Int64(1_700_000_000) + Int64(index)) * 1_000_000)
    }

    func messageDate(for index: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
    }

    func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func waitForCausalMainQueueDrain() -> Bool {
        var completed = false
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    completed = true
                }
            }
        }
        return waitUntil { completed }
    }

    private func seedConversation(
        controller: ChatViewController,
        messageRanges: [Range<Int>],
        coverageRanges: [Range<Int>]
    ) throws {
        let indices = messageRanges.flatMap { Array($0) }.sorted()
        let messages = indices.map { makeMessage(index: $0, controller: controller) }
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: controller.jid,
            owner: controller.owner,
            conversationType: .regular
        )
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = .regular
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.fullArchiveLoaded = true
        if let last = messages.last {
            chat.lastMessage = last
            chat.lastMessageId = last.messageId
            chat.messageDate = last.date
            chat.syncSnapshotLastArchiveId = last.archivedId
        }

        let realm = try WRealm.safe()
        try realm.write {
            messages.forEach { realm.add($0, update: .modified) }
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .regular,
                in: realm
            )
            archiveState.loadedRanges = coverageRanges.compactMap { range in
                guard let first = range.first, let last = range.last else { return nil }
                return RegularChatArchiveIDRange(
                    oldestArchiveId: archiveId(for: first),
                    newestArchiveId: archiveId(for: last)
                )
            }
            archiveState.olderArchiveEndReached = true
            archiveState.newerLiveEdgeReached = true
            archiveState.lastSnapshotArchiveId = chat.syncSnapshotLastArchiveId
            archiveState.recomputeBoundsAndGaps()
        }
    }

    private func makeMessage(
        index: Int,
        controller: ChatViewController
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = messagePrimary(for: index)
        message.owner = controller.owner
        message.opponent = controller.jid
        message.conversationType = .regular
        message.messageId = messageId(for: index)
        message.archivedId = archiveId(for: index)
        message.body = index.isMultiple(of: 5)
            ? String(repeating: "Bounded exact local message \(index). ", count: 5)
            : "Bounded exact local message \(index)"
        message.legacyBody = message.body
        message.date = messageDate(for: index)
        message.sentDate = message.date
        message.outgoing = index.isMultiple(of: 3)
        message.displayAs = .text
        message.state = .read
        message.isRead = true
        return message
    }
}

@MainActor
final class ChatLoadedTargetIntegrationTests: ChatLocalTargetProductionTestCase {
    func testVisibleExactTargetCentersAndHighlightsWithoutDatasourceApplyOrMAM() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let windowScene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let hosted = try makeHostedController(
            suffix: "x01-visible",
            messageRanges: [0..<400],
            coverageRanges: [0..<400],
            targetBounds: windowScene.coordinateSpace.bounds
        )
        let controller = hosted.controller
        let collectionView = hosted.collectionView
        let evidence = installEvidence(on: controller)
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = hosted.host
        defer {
            clearEvidenceHooks(controller)
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        controller.scrollFrameOperationCounter.reset()
        collectionView.resetRecordedEvents()
        prepareInitialFrame(hosted, evidence: evidence)
        XCTAssertTrue(evidence.remoteActions.isEmpty)
        window.makeKeyAndVisible()
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(controller.view.window === window)
        XCTAssertEqual(window.windowScene?.activationState, .foregroundActive)
        XCTAssertTrue(
            waitUntil {
                controller.initialLocalFirstFrameCoreAnimationReceiptGeneration != nil &&
                    controller.initialLocalFirstFramePresentationOwnership == nil &&
                    controller.timelineSession?.snapshot.items.isEmpty == false
            },
            "loaded-target navigation must start from the acknowledged production first frame"
        )

        let visibleSections = collectionView.indexPathsForVisibleItems
            .map(\.section)
            .filter { controller.datasource.indices.contains($0) }
            .sorted()
        let targetSection = try XCTUnwrap(
            visibleSections.first(where: { section in
                let row = controller.datasource[section]
                return !row.isFakeMessage &&
                    ChatVisiblePositionPolicy.rowKind(for: row.kind) ==
                        .message
            })
        )
        let target = controller.datasource[targetSection]
        XCTAssertNotNil(collectionView.cellForItem(at: IndexPath(item: 0, section: targetSection)))

        evidence.publications.removeAll(keepingCapacity: true)
        evidence.remoteActions.removeAll(keepingCapacity: true)
        evidence.commitDiagnostics.removeAll(keepingCapacity: true)
        evidence.mappingBarrierMainThreadFlags.removeAll(keepingCapacity: true)
        controller.scrollFrameOperationCounter.reset()
        collectionView.resetRecordedEvents()
        let committedPrimaries = controller.datasource.map(\.primary)
        let committedSnapshotPrimaries = controller.datasourceSnapshot.items.map(\.primary)
        let committedResidentWindow = controller.residentDatasetWindow
        let committedDatasetGeneration = controller.datasetMappingGeneration
        let committedSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let committedLayoutGeneration = controller.layoutPreparationGeneration
        let committedTimelineGeneration = controller.timelineSession?.snapshot.generation
        var callbacks: [String] = []

        controller.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: controller.jid,
                owner: controller.owner,
                conversationType: .regular,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: target.primary,
                    archivedId: target.archivedId,
                    messageId: target.messageId,
                    authorId: nil,
                    bodyFingerprint: nil,
                    sourceDate: target.sentDate
                ),
                highlight: true,
                markReadOnVisible: false,
                source: .search
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: false,
                onPositioningStarted: { callbacks.append("started") },
                onFailed: { callbacks.append("failed") },
                onPositioned: { callbacks.append("positioned") }
            )
        )

        XCTAssertEqual(callbacks, ["started", "positioned"])
        XCTAssertTrue(evidence.publications.isEmpty)
        XCTAssertTrue(evidence.remoteActions.isEmpty)
        XCTAssertTrue(evidence.commitDiagnostics.isEmpty)
        XCTAssertTrue(evidence.mappingBarrierMainThreadFlags.isEmpty)
        XCTAssertEqual(controller.datasource.map(\.primary), committedPrimaries)
        XCTAssertEqual(controller.datasourceSnapshot.items.map(\.primary), committedSnapshotPrimaries)
        XCTAssertEqual(controller.residentDatasetWindow, committedResidentWindow)
        XCTAssertEqual(controller.datasetMappingGeneration, committedDatasetGeneration)
        XCTAssertEqual(controller.bootstrapSkeletonMappingGeneration, committedSkeletonGeneration)
        XCTAssertEqual(controller.layoutPreparationGeneration, committedLayoutGeneration)
        XCTAssertEqual(controller.timelineSession?.snapshot.generation, committedTimelineGeneration)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
        XCTAssertLessThanOrEqual(
            collectionView.recordedEvents.filter { $0 == .offset }.count,
            1
        )
        try assertCentered(primary: target.primary, in: controller)
        let positionedSection = try XCTUnwrap(controller.datasourceSnapshot.primaryIndex[target.primary])
        let positionedCell = try XCTUnwrap(
            collectionView.cellForItem(
                at: IndexPath(item: 0, section: positionedSection)
            ) as? MessageContentCell
        )
        XCTAssertTrue(positionedCell.isSelected())
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)

        let positionedOffset = collectionView.contentOffset
        let positionedViewportY = try exactTargetViewportY(
            primary: target.primary,
            controller: controller
        )
        let positionedEventCount = collectionView.recordedEvents.count
        let positionedOperations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertTrue(waitForCausalMainQueueDrain())
        XCTAssertEqual(collectionView.contentOffset, positionedOffset)
        XCTAssertEqual(
            try exactTargetViewportY(
                primary: target.primary,
                controller: controller
            ),
            positionedViewportY,
            accuracy: 0.001
        )
        XCTAssertEqual(collectionView.recordedEvents.count, positionedEventCount)
        let drainedOperations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(
            drainedOperations[.scrollFrames] - positionedOperations[.scrollFrames],
            1,
            "the positioned offset may produce one coalesced visible-metadata frame"
        )
        XCTAssertEqual(
            drainedOperations[.visibleRowsVisited] -
                positionedOperations[.visibleRowsVisited],
            collectionView.indexPathsForVisibleItems.count
        )
        ChatRenderOperation.allCases
            .filter { $0 != .scrollFrames && $0 != .visibleRowsVisited }
            .forEach { operation in
                XCTAssertEqual(
                    drainedOperations[operation],
                    positionedOperations[operation],
                    "positioned metadata must not perform \(operation.rawValue)"
                )
            }
        try assertCentered(primary: target.primary, in: controller)
        XCTAssertTrue(positionedCell.isSelected())
        XCTAssertEqual(controller.datasetMappingGeneration, committedDatasetGeneration)
#else
        throw XCTSkip("Production first-frame diagnostics are available in DEBUG/lab builds")
#endif
    }
}

@MainActor
final class ChatLocalTargetWindowIntegrationTests: ChatLocalTargetProductionTestCase {
    func testLocalTargetOutsideResidentWindowUsesBoundedLocalFirstFrameWithoutLatestOrMAM() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let targetIndex = 120
        let hosted = try makeHostedController(
            suffix: "x02-outside-resident",
            messageRanges: [0..<400],
            coverageRanges: [0..<400],
            initialTargetIndex: targetIndex
        )
        let controller = hosted.controller
        let collectionView = hosted.collectionView
        let evidence = installEvidence(on: controller)
        defer {
            clearEvidenceHooks(controller)
            controller.performTerminalChatResourceTeardownForTesting()
        }
        controller.scrollFrameOperationCounter.reset()
        collectionView.resetRecordedEvents()

        prepareInitialFrame(hosted, evidence: evidence)
        try assertExactLocalFirstFrame(
            hosted,
            evidence: evidence,
            targetIndex: targetIndex,
            excludedLatestIndex: 399,
            expectedRemoteActionCount: 0
        )

        let committedOffset = collectionView.contentOffset
        let committedEvents = collectionView.recordedEvents
        let committedOperations = controller.scrollFrameOperationCounter.snapshot()
        let committedGenerations = [
            controller.datasetMappingGeneration,
            controller.bootstrapSkeletonMappingGeneration,
            controller.layoutPreparationGeneration
        ]
        XCTAssertTrue(waitForCausalMainQueueDrain())
        XCTAssertEqual(collectionView.contentOffset, committedOffset)
        XCTAssertEqual(collectionView.recordedEvents, committedEvents)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot(), committedOperations)
        XCTAssertEqual(evidence.publications.count, 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
        XCTAssertEqual(
            [
                controller.datasetMappingGeneration,
                controller.bootstrapSkeletonMappingGeneration,
                controller.layoutPreparationGeneration
            ],
            committedGenerations
        )
#else
        throw XCTSkip("Production first-frame diagnostics are available in DEBUG/lab builds")
#endif
    }
}

@MainActor
final class ChatGapLocalTargetTests: ChatLocalTargetProductionTestCase {
    func testTargetOnNewerGapSidePublishesDirectlyAndBackgroundRepairCannotMoveIt() throws {
        try assertGapSide(
            suffix: "g03-newer-side",
            targetIndex: 280,
            expectedNewerPage: false,
            expectedOlderPage: true
        )
    }

    func testTargetOnOlderGapSidePublishesDirectlyAndBackgroundRepairCannotMoveIt() throws {
        try assertGapSide(
            suffix: "g04-older-side",
            targetIndex: 120,
            expectedNewerPage: true,
            expectedOlderPage: false
        )
    }

    private func assertGapSide(
        suffix: String,
        targetIndex: Int,
        expectedNewerPage: Bool,
        expectedOlderPage: Bool
    ) throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let hosted = try makeHostedController(
            suffix: suffix,
            messageRanges: [0..<160, 240..<400],
            coverageRanges: [0..<160, 240..<400],
            initialTargetIndex: targetIndex
        )
        let controller = hosted.controller
        let collectionView = hosted.collectionView
        let evidence = installEvidence(on: controller)
        defer {
            clearEvidenceHooks(controller)
            controller.performTerminalChatResourceTeardownForTesting()
        }
        controller.scrollFrameOperationCounter.reset()
        collectionView.resetRecordedEvents()

        prepareInitialFrame(hosted, evidence: evidence)
        try assertExactLocalFirstFrame(
            hosted,
            evidence: evidence,
            targetIndex: targetIndex,
            excludedLatestIndex: 399,
            expectedRemoteActionCount: 1
        )
        let action = try XCTUnwrap(evidence.remoteActions.first)
        XCTAssertEqual(action.kind, .anchorContextPrefetch)
        XCTAssertEqual(action.source, .search)
        XCTAssertEqual(action.newerPageSize != nil, expectedNewerPage)
        XCTAssertEqual(action.olderPageSize != nil, expectedOlderPage)
        let targetContextPerSide = max(1, controller.datasourcePageSize / 2)
        XCTAssertEqual(
            action.newerPageSize,
            expectedNewerPage ? targetContextPerSide - 39 : nil
        )
        XCTAssertEqual(
            action.olderPageSize,
            expectedOlderPage ? targetContextPerSide - 40 : nil
        )
        XCTAssertTrue(action.requiresRemoteFetch)

        // The descriptor above came from the real background-prefetch planner;
        // only its network transport was intercepted. Continue at the real
        // post-commit ChatTimelineSession observation boundary before applying
        // the detached-persistence outcome below.
        controller.timelineSession?.activateStoreObservation()
        XCTAssertTrue(waitForCausalMainQueueDrain())
        XCTAssertTrue(waitUntil {
            controller.timelineSession?.activeStoreObservationWorkCount == 0
        })
        let targetPrimary = messagePrimary(for: targetIndex)
        let targetViewportY = try viewportY(primary: targetPrimary, controller: controller)
        let committedOffset = collectionView.contentOffset
        let committedPrimaries = controller.datasource.map(\.primary)
        let committedSnapshotPrimaries = controller.datasourceSnapshot.items.map(\.primary)
        let committedResidentWindow = controller.residentDatasetWindow
        let committedTimelineGeneration = controller.timelineSession?.snapshot.generation
        let committedDatasetGeneration = controller.datasetMappingGeneration
        let committedSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let committedLayoutGeneration = controller.layoutPreparationGeneration
        let committedOperations = controller.scrollFrameOperationCounter.snapshot()
        let committedEvents = collectionView.recordedEvents
        let committedPublicationCount = evidence.publications.count

        // Model the successful detached persistence outcome after the real
        // descriptor/observation admission. The repaired rows are adjacent to,
        // but outside, the resident exact frame.
        try persistGapRepair(controller: controller, missingRange: 160..<240)
        XCTAssertTrue(waitForCausalMainQueueDrain())
        XCTAssertTrue(waitUntil {
            controller.timelineSession?.activeStoreObservationWorkCount == 0
        })
        controller.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        let repairedTargetViewportY = try viewportY(
            primary: targetPrimary,
            controller: controller
        )

        XCTAssertEqual(controller.datasource.map(\.primary), committedPrimaries)
        XCTAssertEqual(controller.datasourceSnapshot.items.map(\.primary), committedSnapshotPrimaries)
        XCTAssertEqual(controller.residentDatasetWindow, committedResidentWindow)
        XCTAssertEqual(controller.timelineSession?.snapshot.generation, committedTimelineGeneration)
        XCTAssertEqual(controller.datasetMappingGeneration, committedDatasetGeneration)
        XCTAssertEqual(controller.bootstrapSkeletonMappingGeneration, committedSkeletonGeneration)
        XCTAssertEqual(controller.layoutPreparationGeneration, committedLayoutGeneration)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
        XCTAssertEqual(evidence.publications.count, committedPublicationCount)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot(), committedOperations)
        XCTAssertEqual(collectionView.recordedEvents, committedEvents)
        XCTAssertEqual(collectionView.contentOffset.x, committedOffset.x, accuracy: 0.001)
        XCTAssertEqual(collectionView.contentOffset.y, committedOffset.y, accuracy: 0.001)
        XCTAssertEqual(
            repairedTargetViewportY,
            targetViewportY,
            accuracy: 1
        )
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
#else
        throw XCTSkip("Production first-frame diagnostics are available in DEBUG/lab builds")
#endif
    }

    private func viewportY(
        primary: String,
        controller: ChatViewController
    ) throws -> CGFloat {
        controller.messagesCollectionView.layoutIfNeeded()
        let section = try XCTUnwrap(controller.datasourceSnapshot.primaryIndex[primary])
        let attributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: section)
            )
        )
        return attributes.frame.minY - controller.messagesCollectionView.contentOffset.y
    }
}

struct ChatLocalTargetHostedController {
    let host: UIViewController
    let controller: ChatViewController
    let collectionView: ChatLayoutLifecycleRecordingCollectionView
}

final class ChatLocalTargetProductionEvidence {
    var publications: [[ChatViewController.Datasource]] = []
    var commitDiagnostics: [ChatPerformanceInitialFrameCommitDiagnostics] = []
    var mappingBarrierMainThreadFlags: [Bool] = []
    var remoteActions: [ChatPerformanceFixtureRemoteHistoryAction] = []
}
