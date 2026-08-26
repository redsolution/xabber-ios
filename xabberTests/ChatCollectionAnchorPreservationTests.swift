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

    func testOutgoingTailAppendUsesImmediateReloadAndAlignsAboveComposer() throws {
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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

        var transactionResult: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            initialItems + [outgoing],
            mode: .targetedDiff,
            animated: true,
            presentationOwner: .archiveEngine,
            transactionCompletion: {
                transactionResult = $0
            }
        )

        let section = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[outgoingPrimary]
        )
        let attributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: section)
            )
        )
        let rowViewportMaxY = attributes.frame.maxY -
            controller.messagesCollectionView.contentOffset.y
        let committedOffsetY = controller.messagesCollectionView.contentOffset.y
        XCTAssertLessThanOrEqual(
            ChatTailAppendBottomPinPolicy.bottomDistance(
                contentHeight: controller.messagesCollectionView.contentSize.height,
                viewportHeight: controller.messagesCollectionView.bounds.height,
                contentInsets: controller.messagesCollectionView.contentInset,
                contentOffsetY: committedOffsetY
            ),
            0.5
        )
        XCTAssertGreaterThanOrEqual(
            controller.xabberInputView.frame.minY - rowViewportMaxY,
            ChatFloatingHeaderLayoutPolicy.composerMessageSpacing - 0.5
        )
        guard case .committed(let diagnostics) = transactionResult else {
            return XCTFail("Expected committed outgoing tail transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
        XCTAssertEqual(diagnostics.insetDelta.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(collectionView.performBatchUpdateCount, 0)
        let operations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(operations[.reloads], 1)

        let nextRunLoop = expectation(description: "next run loop remains stable")
        DispatchQueue.main.async {
            XCTAssertEqual(
                controller.messagesCollectionView.contentOffset.y,
                committedOffsetY,
                accuracy: 0.001
            )
            nextRunLoop.fulfill()
        }
        wait(for: [nextRunLoop], timeout: 1)
    }

    func testShortOutgoingWithKeyboardUsesImmediateReloadAndStaysAboveComposer() throws {
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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

        var transactionResult: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            initialItems + [dateSeparator, outgoing],
            mode: .targetedDiff,
            animated: true,
            presentationOwner: .archiveEngine,
            transactionCompletion: {
                transactionResult = $0
            }
        )

        let section = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[outgoingPrimary]
        )
        let attributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: section)
            )
        )
        let rowViewportMaxY = attributes.frame.maxY -
            controller.messagesCollectionView.contentOffset.y
        let committedOffsetY = controller.messagesCollectionView.contentOffset.y
        XCTAssertLessThanOrEqual(
            ChatTailAppendBottomPinPolicy.bottomDistance(
                contentHeight: controller.messagesCollectionView.contentSize.height,
                viewportHeight: controller.messagesCollectionView.bounds.height,
                contentInsets: controller.messagesCollectionView.contentInset,
                contentOffsetY: committedOffsetY
            ),
            0.5
        )
        XCTAssertGreaterThanOrEqual(
            controller.xabberInputView.frame.minY - rowViewportMaxY,
            ChatFloatingHeaderLayoutPolicy.composerMessageSpacing - 0.5
        )
        guard case .committed(let diagnostics) = transactionResult else {
            return XCTFail("Expected committed short outgoing tail transaction")
        }
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
        XCTAssertEqual(diagnostics.insetDelta.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(collectionView.performBatchUpdateCount, 0)
        let operations = controller.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(operations[.reloads], 1)

        let nextRunLoop = expectation(description: "short next run loop remains stable")
        DispatchQueue.main.async {
            XCTAssertEqual(
                controller.messagesCollectionView.contentOffset.y,
                committedOffsetY,
                accuracy: 0.001
            )
            nextRunLoop.fulfill()
        }
        wait(for: [nextRunLoop], timeout: 1)
    }

    func testOutgoingAppendOverridesCapturedAnchorAndRepairsAccumulatedKeyboardDrift() throws {
        XCTAssertTrue(Thread.isMainThread)
        let collectionView = ChatTailAppendBatchCompletionCollectionView()
        let controller = makeController(collectionView: collectionView)
        installKeyboardComposerGeometry(in: controller, keyboardHeight: 335)
        let initialItems = (0..<30).map {
            makeDatasource(primary: "keyboard-drift-initial-\($0)")
        }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine
        )
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()

        let alignedOffsetY = controller.messagesCollectionView.contentOffset.y
        let accumulatedDrift: CGFloat = 70
        controller.messagesCollectionView.setContentOffset(
            CGPoint(
                x: controller.messagesCollectionView.contentOffset.x,
                y: alignedOffsetY - accumulatedDrift
            ),
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        let capturedAnchor = try XCTUnwrap(
            controller.capturePagingAnchorIfNeeded(direction: .older)
        )
        let anchorSection = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[capturedAnchor.primary]
        )
        let anchorBefore = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: anchorSection)
            )
        ).frame.minY - controller.messagesCollectionView.contentOffset.y

        controller.requestOutgoingAutoScrollAfterDatasourceUpdate()
        let outgoingPrimary = "keyboard-drift-outgoing"
        var outgoing = makeDatasource(primary: outgoingPrimary)
        outgoing.outgoing = true
        outgoing.isOutgoing = true
        outgoing.sender = controller.ownerSender
        outgoing.state = .sending
        outgoing.indicator = .sending
        outgoing.kind = .attributedText(NSAttributedString(string: "Newest outgoing"))
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            initialItems + [outgoing],
            mode: .targetedDiff,
            animated: false,
            suppressDefaultBottomScroll: true,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: capturedAnchor.primary,
            restoreAnchor: capturedAnchor,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { true },
            transactionCompletion: { result = $0 }
        )

        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected a committed outgoing transaction")
        }
        let outgoingSection = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[outgoingPrimary]
        )
        let outgoingAttributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: outgoingSection)
            )
        )
        let expectedOffsetY = ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
            targetMaxY: outgoingAttributes.frame.maxY,
            contentHeight: controller.messagesCollectionView.contentSize.height,
            viewportHeight: controller.messagesCollectionView.bounds.height,
            contentInsets: controller.messagesCollectionView.contentInset
        )
        XCTAssertGreaterThan(
            expectedOffsetY - (alignedOffsetY - accumulatedDrift),
            accumulatedDrift,
            "The winning send must repair prior drift and include the appended row height"
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            expectedOffsetY,
            accuracy: 0.5
        )
        let outgoingFrameInView = controller.messagesCollectionView.convert(
            outgoingAttributes.frame,
            to: controller.view
        )
        let composerFrameInView = controller.xabberInputView.convert(
            controller.xabberInputView.bounds,
            to: controller.view
        )
        XCTAssertGreaterThanOrEqual(
            composerFrameInView.minY - outgoingFrameInView.maxY,
            ChatFloatingHeaderLayoutPolicy.composerMessageSpacing - 0.5
        )
        let anchorAfter = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: anchorSection)
            )
        ).frame.minY - controller.messagesCollectionView.contentOffset.y
        XCTAssertEqual(
            anchorBefore - anchorAfter,
            expectedOffsetY - (alignedOffsetY - accumulatedDrift),
            accuracy: 0.5,
            "The transcript must move as one viewport, not overlay the new bubble under the composer"
        )
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
    }

    func testRejectedOutgoingAtomicApplyRetainsScrollIntentAndTargetAnchorUntilWinningRetry() throws {
        XCTAssertTrue(Thread.isMainThread)
        let controller = makeController()
        installKeyboardComposerGeometry(in: controller, keyboardHeight: 335)
        let initialItems = (0..<24).map {
            makeDatasource(primary: "rejected-outgoing-initial-\($0)")
        }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine
        )
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        let retainedTargetAnchor = ChatRetainedMessageAnchor(
            primary: "opened-historical-target",
            archivedId: "opened-historical-archive-id",
            displayRevision: "opened-historical-revision",
            viewportRelativeMinY: 120
        )
        controller.retainedMessageAnchor = retainedTargetAnchor
        controller.requestOutgoingAutoScrollAfterDatasourceUpdate()

        let outgoingPrimary = "rejected-outgoing-row"
        var outgoing = makeDatasource(primary: outgoingPrimary)
        outgoing.outgoing = true
        outgoing.isOutgoing = true
        outgoing.sender = controller.ownerSender
        outgoing.state = .sending
        outgoing.indicator = .sending
        outgoing.kind = .attributedText(NSAttributedString(string: "Retry me"))
        var rejectedResult: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            initialItems + [outgoing],
            mode: .targetedDiff,
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { false },
            transactionCompletion: { rejectedResult = $0 }
        )

        guard case .failed(.superseded, _) = rejectedResult else {
            return XCTFail("Expected the first apply to be superseded")
        }
        XCTAssertNotNil(
            controller.pendingOutgoingAutoScrollRequest,
            "A rejected UIKit apply must not consume the user's send scroll intent"
        )
        XCTAssertEqual(
            controller.retainedMessageAnchor,
            retainedTargetAnchor,
            "A rejected outgoing apply must preserve the historical target until a send is presented"
        )

        var winningResult: ChatViewportTransactionResult?
        controller.applyChatDatasource(
            initialItems + [outgoing],
            mode: .targetedDiff,
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { true },
            transactionCompletion: { winningResult = $0 }
        )

        guard case .committed = winningResult else {
            return XCTFail("Expected the retry to commit")
        }
        XCTAssertNil(controller.pendingOutgoingAutoScrollRequest)
        XCTAssertNil(
            controller.retainedMessageAnchor,
            "The matching committed send owns the viewport and must release the historical target"
        )
        let outgoingSection = try XCTUnwrap(
            controller.datasourceSnapshot.primaryIndex[outgoingPrimary]
        )
        let outgoingAttributes = try XCTUnwrap(
            controller.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: outgoingSection)
            )
        )
        let expectedOffsetY = ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
            targetMaxY: outgoingAttributes.frame.maxY,
            contentHeight: controller.messagesCollectionView.contentSize.height,
            viewportHeight: controller.messagesCollectionView.bounds.height,
            contentInsets: controller.messagesCollectionView.contentInset
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            expectedOffsetY,
            accuracy: 0.5
        )
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            presentationOwner: .archiveEngine,
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
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
        )
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        let oldOffsetY = controller.messagesCollectionView.contentOffset.y

        controller.applyChatDatasource(
            replacementItems,
            mode: .windowReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            presentationOwner: .archiveEngine,
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

    func testArchiveEngineStyleAtomicPrependFullReloadCommitsWithoutDelayedAnchorDrift() throws {
        let controller = makeController()
        let initialItems = (67..<140).map { makeDatasource(primary: "m\($0)") }
        let expandedItems = (0..<140).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 2),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()

        let anchorPrimary = initialItems[2].primary
        let viewportRelativeMinY = try viewportY(for: anchorPrimary, in: controller)
        let anchor = ChatViewportAnchor(
            primary: anchorPrimary,
            viewportRelativeMinY: viewportRelativeMinY
        )
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            expandedItems,
            mode: .fullReload(keepOffset: false),
            animated: false,
            suppressDefaultBottomScroll: true,
            applyCategory: .olderAnchorReload,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: anchor.primary,
            restoreAnchor: anchor,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { true },
            transactionCompletion: { result = $0 }
        )

        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected atomic prepend transaction to commit")
        }
        XCTAssertEqual(try viewportY(for: anchorPrimary, in: controller), viewportRelativeMinY, accuracy: 1)
        XCTAssertEqual(diagnostics.forcedLayoutCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.programmaticOffsetMutationCount, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(diagnostics.anchorError), 1)

        let committedOffsetY = controller.messagesCollectionView.contentOffset.y
        let committedViewportY = try viewportY(for: anchorPrimary, in: controller)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            committedOffsetY,
            accuracy: 0.001,
            "Archive page apply must not schedule a second offset correction"
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            committedViewportY,
            accuracy: 0.001,
            "The visible message must not jump after the atomic commit"
        )
    }

    func testControllerTargetDeletionReportsFailureWithoutLegacySuccessCompletion() throws {
        let controller = makeController()
        let initialItems = (0..<30).map { makeDatasource(primary: "m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            presentationOwner: .archiveEngine,
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
                suppressDefaultBottomScroll: true,
                presentationOwner: .archiveEngine,
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
                presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
        _ = controller.updateChatInputViewForCurrentKeyboardLayout(
            visibleKeyboardHeight: 220
        )
        var result: ChatViewportTransactionResult?

        controller.applyChatDatasource(
            initialItems + [makeDatasource(primary: "incoming")],
            mode: .targetedDiff,
            animated: false,
            suppressDefaultBottomScroll: true,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: anchor.primary,
            restoreAnchor: anchor,
            presentationOwner: .archiveEngine,
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

    func testKeyboardOpenAndHidePreserveReadingViewportByInsetDelta() throws {
        let controller = makeController()
        let initialItems = (0..<40).map { makeDatasource(primary: "keyboard-m\($0)") }
        controller.applyChatDatasource(
            initialItems,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
        )
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 10),
            at: .top,
            animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()

        let anchorPrimary = initialItems[10].primary
        let initialViewportY = try viewportY(for: anchorPrimary, in: controller)
        let initialOffsetY = controller.messagesCollectionView.contentOffset.y
        let initialBottomInset = controller.messagesCollectionView.contentInset.bottom

        controller.keyboardWillChangeFrameNotification(Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                    cgRect: CGRect(x: 0, y: 544, width: 390, height: 300)
                ),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
            ]
        ))

        let openedBottomInset = controller.messagesCollectionView.contentInset.bottom
        let openingInsetDelta = openedBottomInset - initialBottomInset
        XCTAssertEqual(openingInsetDelta, 300, accuracy: 0.001)
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y - initialOffsetY,
            openingInsetDelta,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            initialViewportY - openingInsetDelta,
            accuracy: 0.001
        )

        controller.keyboardWillChangeFrameNotification(Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                    cgRect: CGRect(x: 0, y: 844, width: 390, height: 300)
                ),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
            ]
        ))

        XCTAssertEqual(
            controller.messagesCollectionView.contentInset.bottom,
            initialBottomInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            initialOffsetY,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            initialViewportY,
            accuracy: 0.001
        )
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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

    private func installKeyboardComposerGeometry(
        in controller: ChatViewController,
        keyboardHeight: CGFloat
    ) {
        let visualHeight = ModernXabberInputView.defaultBarHeight
        let horizontalInset = ModernXabberInputView.edgeHorizontalInset
        controller.currentChatKeyboardVisibleHeight = keyboardHeight
        controller.xabberInputView.heightConstraint?.constant = visualHeight
        controller.xabberInputView.frame = CGRect(
            x: horizontalInset,
            y: controller.view.bounds.height - keyboardHeight - visualHeight,
            width: controller.view.bounds.width - 2 * horizontalInset,
            height: visualHeight
        )
        controller.updateChatCollectionInsets(
            inputHeight: visualHeight + keyboardHeight
        )
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
    private(set) var performBatchUpdateCount = 0

    override func performBatchUpdates(
        _ updates: (() -> Void)?,
        completion: ((Bool) -> Void)? = nil
    ) {
        performBatchUpdateCount += 1
        super.performBatchUpdates(updates) { [weak self] finished in
            self?.layoutIfNeeded()
            self?.beforeForwardingBatchCompletion?()
            completion?(finished)
        }
    }
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
