import XCTest
import UIKit
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

        try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 844, height: 390)
        )
        XCTAssertTrue(
            controller.isNearBottom(threshold: 1),
            "Landscape remap must keep the resident live tail aligned"
        )

        try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 390, height: 844)
        )
        XCTAssertTrue(
            controller.isNearBottom(threshold: 1),
            "Returning to portrait must not land in older history"
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

        try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 844, height: 390)
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            portraitViewportY,
            accuracy: 1,
            "Landscape remap must restore the pre-transition message anchor"
        )

        try remapControllerForSizeTransition(
            controller,
            to: CGSize(width: 390, height: 844)
        )
        XCTAssertEqual(
            try viewportY(for: anchorPrimary, in: controller),
            portraitViewportY,
            accuracy: 1,
            "Returning to portrait must restore the same message-relative anchor"
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

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
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

    private func remapControllerForSizeTransition(
        _ controller: ChatViewController,
        to size: CGSize
    ) throws {
        let sectionInsets = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as? UICollectionViewFlowLayout
        ).sectionInset.horizontal
        var preparationFinished = false
        controller.prepareAndApplyCurrentDatasourceLayouts(
            layoutWidthOverride: max(1, size.width - sectionInsets)
        ) {
            preparationFinished = true
        }
        controller.view.bounds.size = size
        controller.shouldChangeFrame()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(waitUntil { preparationFinished })
        controller.messagesCollectionView.layoutIfNeeded()
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
