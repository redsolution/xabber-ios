import QuartzCore
import XCTest
import UIKit
@testable import xabber

final class ChatInitialPresentationAtomicityRegressionTests: XCTestCase {
    private let owner = "atomic-frame-owner@example.com"
    private let jid = "atomic-frame-peer@example.com"

    func testSkeletonToNewestCommitsReloadAndTargetOffsetInsideOneVisualTransaction() throws {
        let (controller, collectionView) = makeController()
        installCommittedSkeleton(in: controller)
        collectionView.setContentOffset(CGPoint(x: 0, y: 160), animated: false)
        collectionView.resetRecordedEvents()

        let realRows = (0..<80).map { makeDatasource(primary: "message-\($0)") }
        var receiptBottomDistance: CGFloat?
        var receiptEventCount: Int?
        var receiptTransactionToken: String?
        var receiptActionsDisabled: Bool?

        controller.applyChatDatasource(
            realRows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            forceBottomAlignmentTarget: .newestRealMessage,
            presentationCommitMode: .atomicInitialFrame,
            completion: {
                receiptEventCount = collectionView.recordedEvents.count
                receiptBottomDistance = self.bottomDistance(in: controller)
                receiptTransactionToken = ChatDatasourcePresentationTransactionContext.currentToken
                receiptActionsDisabled = CATransaction.disableActions()
            }
        )

        let reload = try XCTUnwrap(collectionView.recordedEvents.first(where: { $0.kind == .reload }))
        let targetOffset = try XCTUnwrap(collectionView.recordedEvents.last(where: { $0.kind == .offset }))
        let reloadIndex = try XCTUnwrap(
            collectionView.recordedEvents.firstIndex(where: { $0.kind == .reload })
        )
        let targetOffsetIndex = try XCTUnwrap(
            collectionView.recordedEvents.lastIndex(where: { $0.kind == .offset })
        )
        let finalLayoutIndex = try XCTUnwrap(
            collectionView.recordedEvents.lastIndex(where: { $0.kind == .layout })
        )
        XCTAssertTrue(reload.actionsDisabled)
        XCTAssertFalse(reload.viewAnimationsEnabled)
        XCTAssertTrue(targetOffset.actionsDisabled)
        XCTAssertFalse(targetOffset.viewAnimationsEnabled)
        XCTAssertNotNil(reload.presentationTransactionToken)
        XCTAssertEqual(targetOffset.presentationTransactionToken, reload.presentationTransactionToken)
        XCTAssertLessThan(reloadIndex, targetOffsetIndex)
        XCTAssertLessThan(
            targetOffsetIndex,
            finalLayoutIndex,
            "the visual transaction must finish layout only after installing the newest offset"
        )
        XCTAssertTrue(
            collectionView.recordedEvents[reloadIndex...finalLayoutIndex].allSatisfy {
                $0.presentationTransactionToken == reload.presentationTransactionToken
            },
            "reload, positioning, and the final layout must share one visual transaction"
        )
        XCTAssertGreaterThan(targetOffset.offsetY, 160)
        XCTAssertEqual(receiptEventCount, collectionView.recordedEvents.count)
        XCTAssertNil(receiptTransactionToken)
        XCTAssertEqual(receiptActionsDisabled, false)
        XCTAssertLessThanOrEqual(try XCTUnwrap(receiptBottomDistance), 0.5)
        XCTAssertEqual(controller.datasource.map(\.primary), realRows.map(\.primary))

        let committedOffsetY = collectionView.contentOffset.y
        let committedReloadCount = collectionView.recordedEvents.filter { $0.kind == .reload }.count
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(collectionView.contentOffset.y, committedOffsetY, accuracy: 0.001)
        XCTAssertEqual(
            collectionView.recordedEvents.filter { $0.kind == .reload }.count,
            committedReloadCount,
            "the first-frame receipt must not schedule a second initial reload"
        )
    }

    func testAtomicInitialFrameReceiptPublishesAfterResolvedAnchorAlignment() throws {
        let (controller, collectionView) = makeController()
        installCommittedSkeleton(in: controller)
        collectionView.resetRecordedEvents()
        let realRows = (0..<60).map { makeDatasource(primary: "anchor-message-\($0)") }
        let anchorPrimary = realRows[32].primary
        let requestedViewportY: CGFloat = 180
        var result: ChatViewportTransactionResult?
        var viewportYAtReceipt: CGFloat?

        controller.applyChatDatasource(
            realRows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: anchorPrimary,
            restoreAnchor: ChatHistoryPageAnchor(
                primary: anchorPrimary,
                viewportRelativeMinY: requestedViewportY
            ),
            presentationCommitMode: .atomicInitialFrame,
            transactionCompletion: {
                result = $0
                viewportYAtReceipt = self.viewportY(
                    for: anchorPrimary,
                    in: controller
                )
            }
        )

        guard case .committed(let diagnostics) = result else {
            return XCTFail("Expected the anchor frame to commit")
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(diagnostics.anchorError), 1)
        XCTAssertEqual(try XCTUnwrap(viewportYAtReceipt), requestedViewportY, accuracy: 1)
        XCTAssertTrue(
            try XCTUnwrap(collectionView.recordedEvents.last(where: { $0.kind == .offset }))
                .actionsDisabled
        )
    }

    func testUnresolvedAtomicTargetRestoresCommittedSkeletonAndDoesNotPublishContent() {
        let (controller, collectionView) = makeController()
        installCommittedSkeleton(in: controller)
        let skeletonPrimaries = controller.datasource.map(\.primary)
        collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        let skeletonOffsetY = collectionView.contentOffset.y
        collectionView.resetRecordedEvents()
        var transactionResult: ChatViewportTransactionResult?
        var contentReceiptCount = 0

        controller.applyChatDatasource(
            (0..<40).map { makeDatasource(primary: "real-\($0)") },
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            forceBottomAlignmentTarget: .message(
                ChatMessageAnchorRef(
                    messagePrimary: "missing-target",
                    archivedId: nil,
                    messageId: nil,
                    authorId: nil,
                    bodyFingerprint: nil,
                    sourceDate: nil
                )
            ),
            presentationCommitMode: .atomicInitialFrame,
            transactionCompletion: { transactionResult = $0 },
            completion: { contentReceiptCount += 1 }
        )

        guard case .failed(.targetMissing(let missingPrimary), _) = transactionResult else {
            return XCTFail("Expected typed target failure")
        }
        XCTAssertEqual(missingPrimary, "missing-target")
        XCTAssertEqual(contentReceiptCount, 0)
        XCTAssertEqual(controller.datasource.map(\.primary), skeletonPrimaries)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(collectionView.contentOffset.y, skeletonOffsetY, accuracy: 0.001)
        XCTAssertEqual(
            collectionView.recordedEvents.filter { $0.kind == .reload }.count,
            0,
            "a missing initial target must fail preflight before replacing the skeleton"
        )
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertFalse(controller.hasCommittedRealContentInCurrentLifecycle)
    }

    func testSinglePostLayoutAlignmentDriftReceivesOneBoundedCorrectionAndCommitsNewestFrame() throws {
        let (controller, collectionView) = makeController()
        installCommittedSkeleton(in: controller)
        collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        collectionView.resetRecordedEvents()
        collectionView.injectOffsetDriftsAfterOffsets = [8]
        let realRows = (0..<80).map { makeDatasource(primary: "drift-\($0)") }
        var transactionResult: ChatViewportTransactionResult?
        var contentReceiptCount = 0
        var bottomDistanceAtReceipt: CGFloat?

        controller.applyChatDatasource(
            realRows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            forceBottomAlignmentTarget: .newestRealMessage,
            presentationCommitMode: .atomicInitialFrame,
            transactionCompletion: { transactionResult = $0 },
            completion: {
                contentReceiptCount += 1
                bottomDistanceAtReceipt = self.bottomDistance(in: controller)
            }
        )

        guard case .committed(let diagnostics) = transactionResult else {
            return XCTFail("Expected one bounded final alignment correction to commit the frame")
        }
        XCTAssertEqual(diagnostics.finalAlignmentCorrectionCount, 1)
        XCTAssertEqual(contentReceiptCount, 1)
        XCTAssertEqual(controller.datasource.map(\.primary), realRows.map(\.primary))
        XCTAssertFalse(controller.datasource.contains(where: \.isFakeMessage))
        XCTAssertLessThanOrEqual(try XCTUnwrap(bottomDistanceAtReceipt), 0.5)
        XCTAssertEqual(
            collectionView.recordedEvents.filter { $0.kind == .reload }.count,
            1,
            "a corrected initial frame must install real content exactly once"
        )
        XCTAssertEqual(
            collectionView.recordedEvents.filter { $0.kind == .offset }.count,
            2,
            "initial bottom alignment may receive exactly one final in-transaction correction"
        )
        XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)

        let committedOffsetY = collectionView.contentOffset.y
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))

        XCTAssertEqual(collectionView.contentOffset.y, committedOffsetY, accuracy: 0.001)
        XCTAssertEqual(
            collectionView.recordedEvents.filter { $0.kind == .reload }.count,
            1,
            "the correction must not schedule another initial-frame apply"
        )
    }

    func testSecondPostLayoutAlignmentDriftFailsAfterBoundedCorrectionAndPreservesSkeleton() {
        let (controller, collectionView) = makeController()
        installCommittedSkeleton(in: controller)
        let skeletonPrimaries = controller.datasource.map(\.primary)
        collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        let skeletonOffsetY = collectionView.contentOffset.y
        collectionView.resetRecordedEvents()
        collectionView.injectOffsetDriftsAfterOffsets = [8, 8]
        var transactionResult: ChatViewportTransactionResult?
        var contentReceiptCount = 0

        controller.applyChatDatasource(
            (0..<80).map { makeDatasource(primary: "repeated-drift-\($0)") },
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            forceBottomAlignmentTarget: .newestRealMessage,
            presentationCommitMode: .atomicInitialFrame,
            transactionCompletion: { transactionResult = $0 },
            completion: { contentReceiptCount += 1 }
        )

        guard case .failed(.alignmentUnresolved(_, let error), let diagnostics) = transactionResult else {
            return XCTFail("Expected a second drift to exhaust the bounded correction")
        }
        XCTAssertGreaterThan(error, 0.5)
        XCTAssertEqual(diagnostics.finalAlignmentCorrectionCount, 1)
        XCTAssertEqual(contentReceiptCount, 0)
        XCTAssertEqual(controller.datasource.map(\.primary), skeletonPrimaries)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(collectionView.contentOffset.y, skeletonOffsetY, accuracy: 0.001)
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertFalse(controller.hasCommittedRealContentInCurrentLifecycle)
    }

    func testAtomicPresentationFailureUsesOneFreshMappingGenerationThenTerminalRetry() {
        let descriptor = ChatLocalFirstFrameDescriptor(
            target: .latest,
            request: nil
        )
        XCTAssertEqual(
            ChatInitialFramePresentationFailureRecoveryPolicy.action(
                failedDescriptor: descriptor,
                previouslyRetriedDescriptor: nil
            ),
            .remapFreshGeneration
        )
        XCTAssertEqual(
            ChatInitialFramePresentationFailureRecoveryPolicy.action(
                failedDescriptor: descriptor,
                previouslyRetriedDescriptor: descriptor
            ),
            .showTerminalRetry
        )
        XCTAssertEqual(
            ChatInitialFramePresentationFailureRecoveryPolicy.action(
                failedDescriptor: ChatLocalFirstFrameDescriptor(
                    target: .message(
                        ChatTimelineAnchor(
                            primary: "different-target",
                            archivedId: nil,
                            messageId: nil,
                            date: nil
                        )
                    ),
                    request: nil
                ),
                previouslyRetriedDescriptor: descriptor
            ),
            .remapFreshGeneration,
            "a different requested frame owns its own bounded retry"
        )
    }

    func testLogicalCommitKeepsRealFailureUntilTrustedArchivePageSucceeds() {
        XCTAssertEqual(
            ChatInitialFrameLogicalCommitStatePolicy.loadingState(
                previous: .failure(fallback: .content),
                committedItemsAreEmpty: false,
                hasTrustedPersistedBootstrapPage: false
            ),
            .failure(fallback: .content)
        )
        XCTAssertEqual(
            ChatInitialFrameLogicalCommitStatePolicy.loadingState(
                previous: .failure(fallback: .content),
                committedItemsAreEmpty: false,
                hasTrustedPersistedBootstrapPage: true
            ),
            .content
        )
        XCTAssertEqual(
            ChatInitialFrameLogicalCommitStatePolicy.loadingState(
                previous: .blockingArchive,
                committedItemsAreEmpty: false,
                hasTrustedPersistedBootstrapPage: false
            ),
            .content
        )
    }

    func testBootstrapCannotFinishWhilePersistedInitialFrameIsStillPresenting() {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        }
        let (controller, _) = makeController()
        let descriptor = ChatLocalFirstFrameDescriptor(
            target: .latest,
            request: nil
        )
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.applyChatDatasource(
            [makeDatasource(primary: "low-level-committed-row")],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.initialLocalFirstFramePhase = .presenting(descriptor)
        controller.initialBootstrapQueryId = "presenting-bootstrap-query"
        controller.isInitialBootstrapInFlight = true
        controller.didReceiveInitialBootstrapEndPage = true
        controller.initialBootstrapPersistedMessageCount = 1
        controller.initialBootstrapPersistedRowsForQuery = 1
        controller.initialBootstrapVisibleRowsForConversation = 1

        XCTAssertFalse(
            controller.completeInitialBootstrapIfNeeded(),
            "a low-level datasource commit is not the formal atomic first-frame receipt"
        )
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertEqual(
            controller.initialLocalFirstFramePhase,
            .presenting(descriptor)
        )
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
    }

    func testCoverageFollowUpFailureCannotOverlayRetryOnCommittedContent() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .content,
                next: .failure(fallback: .content),
                hasCommittedContent: true,
                forceRender: true
            ),
            .apply,
            "ordinary archive failures over stale content must retain their Retry affordance"
        )

        let (controller, collectionView) = makeController()
        let committedRows = (0..<12).map {
            makeDatasource(primary: "committed-before-follow-up-\($0)")
        }
        controller.applyChatDatasource(
            committedRows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.appliedBootstrapLoadingState = .content
        controller.showSkeletonObserver.accept(false)
        controller.initialFirstContentApplyCount = 1
        collectionView.resetRecordedEvents()
        controller.hasAttemptedInitialBootstrapBoundaryFollowUp = true
        controller.beginInitialBootstrapTracking(
            queryId: "coverage-only-failure",
            timeout: nil
        )

        controller.handleInitialBootstrapRemoteArchiveFailure(
            queryId: "coverage-only-failure",
            reason: .timeout,
            streamKind: .primary,
            errorDescription: nil
        )

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .content)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertFalse(controller.allowsBootstrapFailureFallback)
        XCTAssertEqual(
            controller.datasource.map(\.primary),
            committedRows.map(\.primary)
        )
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
        XCTAssertTrue(collectionView.recordedEvents.isEmpty)
    }

    func testStoreChangeIsCoalescedWhileInitialFrameIsPreparingOrPresenting() {
        let descriptor = ChatLocalFirstFrameDescriptor(
            target: .latest,
            request: nil
        )
        XCTAssertEqual(
            ChatInitialFrameStoreChangeRoutingPolicy.action(
                phase: .preparing(descriptor),
                hasCommittedTimelinePresentation: false
            ),
            .coalesce
        )
        XCTAssertEqual(
            ChatInitialFrameStoreChangeRoutingPolicy.action(
                phase: .presenting(descriptor),
                hasCommittedTimelinePresentation: false
            ),
            .coalesce
        )
        XCTAssertEqual(
            ChatInitialFrameStoreChangeRoutingPolicy.action(
                phase: .committed(descriptor),
                hasCommittedTimelinePresentation: true
            ),
            .apply
        )
        XCTAssertEqual(
            ChatInitialFrameStoreChangeRoutingPolicy.action(
                phase: .failedPresentation(descriptor),
                hasCommittedTimelinePresentation: true
            ),
            .coalesce,
            "terminal Retry must not admit a generic non-atomic datasource refresh"
        )
    }

    func testObserverRefreshStaysBehindBarrierUntilAtomicFrameCommits() {
        let descriptor = ChatLocalFirstFrameDescriptor(
            target: .latest,
            request: nil
        )
        XCTAssertTrue(
            ChatInitialFrameObserverRefreshBarrierPolicy.shouldDefer(
                phase: .blockedArchiveBootstrap(descriptor),
                hasCommittedTimelinePresentation: true
            )
        )
        XCTAssertTrue(
            ChatInitialFrameObserverRefreshBarrierPolicy.shouldDefer(
                phase: .failedPresentation(descriptor),
                hasCommittedTimelinePresentation: true
            )
        )
        XCTAssertFalse(
            ChatInitialFrameObserverRefreshBarrierPolicy.shouldDefer(
                phase: .committed(descriptor),
                hasCommittedTimelinePresentation: true
            )
        )
    }

    func testLegacyFloatingDatePathHidesCommittedSkeletonSentinelDate() {
        let (controller, _) = makeController()
        installCommittedSkeleton(in: controller)
        controller.pinnedDateView.isHidden = false

        controller.updateFloatingDate()

        XCTAssertTrue(controller.pinnedDateView.isHidden)
    }

    func testObserverRefreshDuringPresentingIsCoalescedWithoutReplacingSkeleton() {
        let (controller, _) = makeController()
        installCommittedSkeleton(in: controller)
        let skeletonPrimaries = controller.datasource.map(\.primary)
        controller.pendingArchiveObserverRefresh = false
        controller.initialLocalFirstFramePhase = .presenting(
            ChatLocalFirstFrameDescriptor(target: .latest, request: nil)
        )

        controller.handleTimelineSessionRefresh()

        XCTAssertTrue(controller.pendingArchiveObserverRefresh)
        XCTAssertEqual(controller.datasource.map(\.primary), skeletonPrimaries)
        XCTAssertTrue(controller.showSkeletonObserver.value)
    }

    func testPresentingPhaseCannotPublishLogicalReadinessReceipt() {
        let (controller, _) = makeController()
        let realRows = [makeDatasource(primary: "committed-before-phase")]
        controller.applyChatDatasource(
            realRows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        let descriptor = ChatLocalFirstFrameDescriptor(target: .latest, request: nil)
        controller.initialLocalFirstFramePhase = .presenting(descriptor)
        var receiptCount = 0

        controller.whenBootstrapFirstFramePresentationIsReady {
            receiptCount += 1
        }
        controller.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()

        XCTAssertEqual(
            receiptCount,
            0,
            "logical readiness must remain sealed until presenting advances to committed"
        )

        controller.initialLocalFirstFramePhase = .committed(descriptor)
        controller.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()

        XCTAssertEqual(receiptCount, 1)
    }

    func testSameNewestObserverRefreshIsDiscardedAfterInitialFrameReceipt() {
        XCTAssertEqual(
            ChatInitialFramePendingObserverRefreshPolicy.action(
                displayedNewestPrimary: "newest",
                residentNewestPrimary: "newest"
            ),
            .cancelAlreadyCurrent
        )
        XCTAssertEqual(
            ChatInitialFramePendingObserverRefreshPolicy.action(
                displayedNewestPrimary: "newest",
                residentNewestPrimary: "newer-tail"
            ),
            .flushNewerTail
        )
    }

    func testLiveTailObserverRefreshKeepsTheBoundedInitialWindow() {
        XCTAssertTrue(
            ChatTimelineObserverRefreshWindowPolicy.shouldReuseCurrentBoundedWindow(
                isTimelineEmpty: false,
                isResidentAtLiveTail: true,
                isShowingBootstrapPlaceholder: false,
                hasPendingForceLatestOpen: false
            )
        )
        XCTAssertFalse(
            ChatTimelineObserverRefreshWindowPolicy.shouldReuseCurrentBoundedWindow(
                isTimelineEmpty: false,
                isResidentAtLiveTail: true,
                isShowingBootstrapPlaceholder: false,
                hasPendingForceLatestOpen: true
            )
        )
        XCTAssertFalse(
            ChatTimelineObserverRefreshWindowPolicy.shouldReuseCurrentBoundedWindow(
                isTimelineEmpty: true,
                isResidentAtLiveTail: true,
                isShowingBootstrapPlaceholder: false,
                hasPendingForceLatestOpen: false
            )
        )
    }

    func testEmptyDatasourceAtomicApplyDoesNotPublishAnIntermediateRealFrame() {
        let (controller, collectionView) = makeController()
        installCommittedSkeleton(in: controller)
        collectionView.resetRecordedEvents()
        var receiptCount = 0

        controller.applyChatDatasource(
            [],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationCommitMode: .atomicInitialFrame,
            completion: { receiptCount += 1 }
        )

        XCTAssertEqual(receiptCount, 1)
        XCTAssertTrue(controller.datasource.isEmpty)
        XCTAssertEqual(collectionView.numberOfSections, 0)
        XCTAssertEqual(
            collectionView.recordedEvents.filter { $0.kind == .reload }.count,
            1
        )
    }

    private func makeController() -> (
        controller: ChatViewController,
        collectionView: RecordingMessagesCollectionView
    ) {
        let collectionView = RecordingMessagesCollectionView()
        let controller = ChatViewController()
        controller.messagesCollectionView = collectionView
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.configureDataset()
        return (controller, collectionView)
    }

    private func installCommittedSkeleton(in controller: ChatViewController) {
        let skeletonRows = (0..<30).map {
            makeDatasource(primary: "skeleton-\($0)", isFakeMessage: true)
        }
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(true)
        controller.applyChatDatasource(
            skeletonRows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
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
    ) -> CGFloat? {
        guard let section = controller.datasourceSnapshot.primaryIndex[primary] else {
            return nil
        }
        let indexPath = IndexPath(item: 0, section: section)
        let frame = controller.messagesCollectionView
            .layoutAttributesForItem(at: indexPath)?.frame
            ?? controller.messagesCollectionView.cellForItem(at: indexPath)?.frame
        return frame.map { $0.minY - controller.messagesCollectionView.contentOffset.y }
    }

    private func makeDatasource(
        primary: String,
        isFakeMessage: Bool = false
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: "Peer"),
            messageId: "\(primary)-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: isFakeMessage
                ? .skeleton(NSAttributedString(string: primary))
                : .attributedText(NSAttributedString(
                    string: "\(primary) \(String(repeating: "history ", count: 8))"
                )),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
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
            archivedId: "archive-\(primary)",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: isFakeMessage,
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

private final class RecordingMessagesCollectionView: MessagesCollectionView {
    enum EventKind: Equatable {
        case reload
        case layout
        case offset
    }

    struct Event: Equatable {
        let kind: EventKind
        let actionsDisabled: Bool
        let viewAnimationsEnabled: Bool
        let offsetY: CGFloat
        let presentationTransactionToken: String?
    }

    private(set) var recordedEvents: [Event] = []
    private var recordsEvents = false
    private var didRecordOffsetSinceLastLayout = false
    var injectOffsetDriftsAfterOffsets: [CGFloat] = []

    func resetRecordedEvents() {
        recordedEvents.removeAll(keepingCapacity: true)
        recordsEvents = true
        didRecordOffsetSinceLastLayout = false
    }

    override func reloadData() {
        record(.reload)
        super.reloadData()
    }

    override func layoutSubviews() {
        record(.layout)
        super.layoutSubviews()
        if recordsEvents,
           didRecordOffsetSinceLastLayout,
           !injectOffsetDriftsAfterOffsets.isEmpty {
            let drift = injectOffsetDriftsAfterOffsets.removeFirst()
            didRecordOffsetSinceLastLayout = false
            super.setContentOffset(
                CGPoint(x: contentOffset.x, y: contentOffset.y + drift),
                animated: false
            )
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if recordsEvents {
            if !injectOffsetDriftsAfterOffsets.isEmpty,
               contentOffset.y > 500 {
                didRecordOffsetSinceLastLayout = true
            }
            recordedEvents.append(Event(
                kind: .offset,
                actionsDisabled: CATransaction.disableActions(),
                viewAnimationsEnabled: UIView.areAnimationsEnabled,
                offsetY: contentOffset.y,
                presentationTransactionToken: ChatDatasourcePresentationTransactionContext.currentToken
            ))
        }
        super.setContentOffset(contentOffset, animated: animated)
    }

    private func record(_ kind: EventKind) {
        guard recordsEvents else { return }
        recordedEvents.append(Event(
            kind: kind,
            actionsDisabled: CATransaction.disableActions(),
            viewAnimationsEnabled: UIView.areAnimationsEnabled,
            offsetY: contentOffset.y,
            presentationTransactionToken: ChatDatasourcePresentationTransactionContext.currentToken
        ))
    }
}
