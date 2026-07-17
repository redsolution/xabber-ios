import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSkeletonLifecycleTests: XCTestCase {
    override func tearDown() {
        SkeletonMessageCell.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    func testSkeletonMappingKeepsDeterministicIDsDatesTextAndHeights() {
        let controller = makeController()
        var context = controller.captureDatasourceMappingContext()
        context.showSkeleton = true

        let first = controller.mapDataset(dataset: [], context: context)
        let second = controller.mapDataset(dataset: [], context: context)

        XCTAssertEqual(first.datasource.map(\.primary), second.datasource.map(\.primary))
        XCTAssertEqual(first.datasource.map(\.messageId), second.datasource.map(\.messageId))
        XCTAssertEqual(first.datasource.map(\.sentDate), second.datasource.map(\.sentDate))
        XCTAssertEqual(first.datasource.map(messageText), second.datasource.map(messageText))
        XCTAssertEqual(
            first.datasource.compactMap { first.layoutSnapshot.layout(forPrimary: $0.primary)?.cellSize },
            second.datasource.compactMap { second.layoutSnapshot.layout(forPrimary: $0.primary)?.cellSize }
        )
        XCTAssertEqual(Set(first.datasource.map(\.primary)).count, first.datasource.count)
        XCTAssertEqual(first.datasource.count, ChatSkeletonTemplate.descriptors.count)
    }

    func testMappedSkeletonMinimumHeightMatchesEquivalentTextMessage() throws {
        let controller = makeController()
        var context = controller.captureDatasourceMappingContext()
        context.showSkeleton = true

        let result = controller.mapDataset(dataset: [], context: context)
        let skeleton = try XCTUnwrap(result.datasource.first)
        let skeletonLayout = try XCTUnwrap(
            result.layoutSnapshot.layout(forPrimary: skeleton.primary)
        )
        let skeletonText = try XCTUnwrap(messageText(skeleton))
        var textMessage = makeDatasource(primary: "minimum-text-message")
        textMessage.kind = .attributedText(NSAttributedString(
            string: skeletonText,
            attributes: context.bodyTextAttributes
        ))
        textMessage.outgoing = skeleton.outgoing
        textMessage.isOutgoing = skeleton.isOutgoing
        textMessage.timeMarkerText = NSAttributedString(
            string: "12:00",
            attributes: context.timeMarkerAttributes
        )
        textMessage.indicator = .none
        let textLayout = ChatMessageLayoutCalculator.measure(
            textMessage,
            context.layoutContext
        )

        XCTAssertEqual(
            skeletonLayout.cellSize.height,
            textLayout.cellSize.height,
            accuracy: 0.5
        )
        XCTAssertEqual(
            skeletonLayout.messageContainerSize.height,
            textLayout.messageContainerSize.height,
            accuracy: 0.5
        )
    }

    func testRepeatedVisibleConfigureDoesNotRestartSkeletonAnimation() {
        let cell = SkeletonMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))

        cell.updateAnimationVisibility(isVisible: true, reduceMotion: false)
        cell.updateAnimationVisibility(isVisible: true, reduceMotion: false)

        XCTAssertEqual(cell.activeSkeletonAnimationCount, 1)
        XCTAssertEqual(cell.skeletonAnimationStartCount, 1)
    }

    func testOffscreenReuseStopsAnimationAndVisibleResumeStartsOne() {
        let cell = SkeletonMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        cell.updateAnimationVisibility(isVisible: true, reduceMotion: false)

        cell.cancelOffscreenWork()
        XCTAssertEqual(cell.activeSkeletonAnimationCount, 0)

        cell.resumeOnscreenWork()
        XCTAssertEqual(cell.activeSkeletonAnimationCount, 1)
        XCTAssertEqual(cell.skeletonAnimationStartCount, 2)

        cell.prepareForReuse()
        XCTAssertEqual(cell.activeSkeletonAnimationCount, 0)
    }

    func testReduceMotionUsesStaticSkeleton() {
        let cell = SkeletonMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))

        cell.updateAnimationVisibility(isVisible: true, reduceMotion: true)

        XCTAssertEqual(cell.activeSkeletonAnimationCount, 0)
        XCTAssertEqual(cell.messageContainerView.alpha, SkeletonMessageCell.staticPlaceholderAlpha, accuracy: 0.001)
    }

    func testReducerImmediatelyUsesValidLocalContent() {
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 80,
                isSynced: true,
                isInitialArchiveLoaded: true,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false
            )),
            .content
        )
    }

    func testReducerUsesOnlyTargetBlockingStateForMissingExternalTarget() {
        let state = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 80,
            isSynced: true,
            isInitialArchiveLoaded: true,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: true,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false
        ))

        XCTAssertEqual(state, .blockingTarget)
        XCTAssertTrue(state.showsSkeleton)
        XCTAssertTrue(state.locksTimeline)
    }

    func testReducerSeparatesArchiveBlockingEmptyAndRetryableFailure() {
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 0,
                isSynced: false,
                isInitialArchiveLoaded: false,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false
            )),
            .blockingArchive
        )
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 0,
                isSynced: true,
                isInitialArchiveLoaded: true,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false
            )),
            .empty
        )

        let failure = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: false,
            isInitialArchiveLoaded: false,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: true
        ))
        XCTAssertEqual(failure, .failure(fallback: .empty))
        XCTAssertTrue(failure.showsRetry)
        XCTAssertFalse(failure.locksTimeline)
        XCTAssertFalse(failure.showsSkeleton)
    }

    func testFailurePresentationExposesRetryWithoutTimelineLock() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.applyBootstrapLoadingState(.failure(fallback: .empty))

        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
        XCTAssertTrue(controller.loadDatasourceObserver.value)

        var retryCount = 0
        controller.bootstrapFailureView.onRetry = { retryCount += 1 }
        let retryButton = try XCTUnwrap(
            allSubviews(of: controller.bootstrapFailureView)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "chat.bootstrap.retry" }
        )
        retryButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(retryCount, 1)

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
    }

    func testBootstrapTransportPrefersReadyPrimaryAccountAndFallsBackOnlyWhenNeeded() {
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: true,
                primaryBootstrapGateActive: false
            ),
            .primaryAccount
        )
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: false,
                primaryBootstrapGateActive: false
            ),
            .uiAction
        )
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: false,
                primaryStreamReady: false,
                primaryBootstrapGateActive: false
            ),
            .uiAction
        )
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: true,
                primaryBootstrapGateActive: true
            ),
            .uiAction
        )
    }

    func testEqualReducerStateIsAnApplicationNoOp() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .blockingArchive
            ),
            .noOp
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .content
            ),
            .apply
        )
    }

    func testCommittedContentCannotReenterBootstrapSkeletonDuringPagingMetadataRefresh() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .content,
                next: .blockingArchive
            ),
            .noOp
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .content,
                next: .blockingTarget
            ),
            .noOp
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .blockingTarget,
                hasCommittedContent: true
            ),
            .noOp
        )
    }

    func testLateBlockingMetadataKeepsCommittedMessageDatasourceInteractive() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = [makeDatasource(primary: "committed-message")]
        controller.appliedBootstrapLoadingState = .content
        controller.showSkeletonObserver.accept(false)
        controller.setDatasourceLoadingEnabled(true)

        controller.applyBootstrapLoadingState(.blockingArchive, forceRender: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .content)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), ["committed-message"])
        XCTAssertTrue(controller.loadDatasourceObserver.value)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
    }

    func testSavedPositionRealDatasourceCommitSealsLifecycleWhenLoadingTrackerIsStale() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(false)
        controller.setDatasourceLoadingEnabled(true)

        controller.applyChatDatasource(
            [makeDatasource(primary: "saved-position-message")],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)

        controller.applyBootstrapLoadingState(.blockingTarget, forceRender: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), ["saved-position-message"])
        XCTAssertTrue(controller.loadDatasourceObserver.value)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
    }

    func testDatasetReconfigurationCannotForgetEarlierCommittedContentWhilePlaceholderIsVisible() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.hasCommittedRealContentInCurrentLifecycle = true
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(false)
        controller.datasource = [makeDatasource(primary: "temporary-placeholder", isFakeMessage: true)]

        controller.configureDataset()
        controller.applyBootstrapLoadingState(.blockingTarget, forceRender: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), ["temporary-placeholder"])
    }

    func testSkeletonToEightyRowsHasOneCommitAndNoEmptyIntermediateFrame() {
        let plan = ChatBootstrapAtomicRevealPlan.resolve(
            previous: .blockingArchive,
            destinationRowCount: 80
        )

        XCTAssertEqual(plan.datasourceApplyCount, 1)
        XCTAssertEqual(plan.destinationRowCount, 80)
        XCTAssertEqual(plan.intermediateEmptyFrameCount, 0)
    }

    func testBoundaryOverlayDoesNotChangeTimelineIdentityOrGeometry() {
        let identities = (0..<80).map { "message-\($0)" }

        XCTAssertFalse(ChatBoundaryLoadingPresentationPolicy.usesTimelineRow)
        XCTAssertEqual(
            ChatBoundaryLoadingPresentationPolicy.geometryDelta(
                messageRowCount: identities.count,
                contentHeight: 6_400
            ),
            .zero
        )
        XCTAssertEqual(identities, (0..<80).map { "message-\($0)" })
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "skeleton-owner@example.com"
        controller.jid = "skeleton-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.showSkeletonObserver.accept(true)
        return controller
    }

    private func messageText(_ item: ChatViewController.Datasource) -> String? {
        guard case .skeleton(let text) = item.kind else { return nil }
        return text.string
    }

    private func makeDatasource(
        primary: String,
        isFakeMessage: Bool = false
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "skeleton-peer@example.com",
            owner: "skeleton-owner@example.com",
            outgoing: false,
            sender: Sender(id: "skeleton-peer@example.com", displayName: "Peer"),
            messageId: "\(primary)-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: isFakeMessage
                ? .skeleton(NSAttributedString(string: primary))
                : .attributedText(NSAttributedString(string: primary)),
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

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
