import XCTest
@testable import xabber

final class ChatArchiveEnginePresentationTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    @MainActor
    func testBoundaryLoadingIndicatorAnimatesAboveTimelineContent() {
        let controller = ChatViewController()
        let rootView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.view = rootView
        rootView.addSubview(controller.messageLoadingActivityIndicator)
        let timelineContent = UIView(frame: rootView.bounds)
        rootView.addSubview(timelineContent)
        controller.messageLoadingActivityIndicator.stopAnimating()
        controller.messageLoadingActivityIndicator.isHidden = true

        controller.setArchiveLoading(true)

        XCTAssertFalse(controller.messageLoadingActivityIndicator.isHidden)
        XCTAssertTrue(controller.messageLoadingActivityIndicator.isAnimating)
        XCTAssertTrue(rootView.subviews.last === controller.messageLoadingActivityIndicator)

        controller.setArchiveLoading(false)

        XCTAssertTrue(controller.messageLoadingActivityIndicator.isHidden)
        XCTAssertFalse(controller.messageLoadingActivityIndicator.isAnimating)
    }

    func testBoundarySpinnerFollowsEngineActivityWithoutCoveringFullSkeleton() {
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: .idle,
                isShowingFullSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: .idle,
                pendingPresentationTarget: .older(
                    before: ArchiveCursor(rawValue: "10")!
                ),
                isShowingFullSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: ArchiveWindowActivity(activeBoundaryRequestCount: 1),
                isShowingFullSkeleton: false
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: ArchiveWindowActivity(activeBoundaryRequestCount: 1),
                isShowingFullSkeleton: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldReplaceCommittedContentWithSkeleton(
                for: .older(before: ArchiveCursor(rawValue: "10")!)
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldReplaceCommittedContentWithSkeleton(
                for: .archiveID(ArchiveCursor(rawValue: "10")!)
            )
        )
    }

    func testUserLatestJumpBuildsAnEngineTargetInsteadOfRematerializingLocalArchive() {
        let intent = ChatArchiveWindowPresentationPolicy.latestTargetIntent(
            conversation: conversation
        )

        XCTAssertEqual(intent.conversation, conversation)
        XCTAssertEqual(intent.locator, .latest)
        XCTAssertEqual(intent.contextBefore, ArchivePageSizing.initial)
        XCTAssertEqual(intent.contextAfter, 0)
        XCTAssertEqual(intent.priority, .target)
    }

    func testHardCutRejectsLegacyTimelineCommitsWhileArchiveEngineOwnsPresentation() {
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldAdmitDatasourceApply(
                isArchiveEnginePresentationActive: true,
                owner: .legacy
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldAdmitDatasourceApply(
                isArchiveEnginePresentationActive: true,
                owner: .archiveEngine
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldAdmitDatasourceApply(
                isArchiveEnginePresentationActive: false,
                owner: .legacy
            )
        )
    }

    func testSkeletonRemainsFullUntilMatchingUIKitGenerationCommits() throws {
        let snapshot = try makeSnapshot(generation: 7)
        let state = ArchiveWindowState.verified(snapshot)

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: state,
                committedCoverageGeneration: nil
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: state,
                committedCoverageGeneration: 6
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: state,
                committedCoverageGeneration: 7
            )
        )
    }

    func testOfflineAndRetryStateNeverRevealPreviouslyCommittedCache() throws {
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: .skeleton(reason: .offline, target: .latest),
                committedCoverageGeneration: 99
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: .retryableFailure(
                    ArchiveRetryableFailure(
                        message: "timeout",
                        retryCount: 7,
                        canRetry: true
                    ),
                    target: .latest
                ),
                committedCoverageGeneration: 99
            )
        )
    }

    func testVerifiedTimelineFactoryRejectsMissingOrOutOfCoverageRows() throws {
        let segment = try makeSegment(oldest: "10", newest: "30")
        let key = ChatTimelineConversationKey(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )
        let p10 = message(primary: "p10", archiveID: "10")
        let p20 = message(primary: "p20", archiveID: "20")
        let p40 = message(primary: "p40", archiveID: "40")

        XCTAssertNil(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [p10],
                expectedPrimaryIDs: ["p10", "p20"],
                segment: segment,
                conversationKey: key
            )
        )
        XCTAssertNil(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [p10, p40],
                expectedPrimaryIDs: ["p10", "p40"],
                segment: segment,
                conversationKey: key
            )
        )
    }

    func testVerifiedTimelineFactoryOrdersRowsAndRepresentsBothUnknownEdges() throws {
        let segment = try makeSegment(
            oldest: "10",
            newest: "30",
            reachesArchiveStart: false,
            reachesLiveEdge: false
        )
        let key = ChatTimelineConversationKey(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )
        let snapshot = try XCTUnwrap(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [
                    message(primary: "p30", archiveID: "30"),
                    message(primary: "p10", archiveID: "10"),
                    message(primary: "p20", archiveID: "20"),
                ],
                expectedPrimaryIDs: ["p10", "p20", "p30"],
                segment: segment,
                conversationKey: key
            )
        )

        XCTAssertEqual(snapshot.items.map(\.primary), ["p10", "p20", "p30"])
        XCTAssertEqual(snapshot.state.residentPrimaryKeys, ["p10", "p20", "p30"])
        XCTAssertEqual(
            snapshot.state.segments,
            [
                .unknownOlder,
                .loadedRange(oldestArchiveId: "10", newestArchiveId: "30"),
                .unknownNewer,
            ]
        )
        XCTAssertFalse(snapshot.state.isResidentAtLiveTail)
    }

    func testVerifiedTimelineFactoryRepresentsConsumedOnlyArchiveWindowWithoutRows() throws {
        let segment = try makeSegment(
            oldest: "10",
            newest: "20",
            reachesArchiveStart: true,
            reachesLiveEdge: true
        )
        let key = ChatTimelineConversationKey(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )

        let snapshot = try XCTUnwrap(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [],
                expectedPrimaryIDs: [],
                segment: segment,
                conversationKey: key
            )
        )

        XCTAssertEqual(snapshot.items, [])
        XCTAssertEqual(snapshot.state.residentPrimaryKeys, [])
        XCTAssertEqual(
            snapshot.state.segments,
            [
                .loadedRange(oldestArchiveId: "10", newestArchiveId: "20"),
                .liveTail,
            ]
        )
        XCTAssertTrue(snapshot.state.isResidentAtLiveTail)
    }

    func testConsumedOnlyLatestWindowDoesNotRequireANonexistentBottomMessage() throws {
        XCTAssertNil(
            ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                for: .latest,
                itemCount: 0
            )
        )
        XCTAssertEqual(
            ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                for: .latest,
                itemCount: 1
            ),
            .newestRealMessage
        )
        XCTAssertNil(
            ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                for: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))),
                itemCount: 1
            )
        )
    }

    func testHardCutRejectsLegacyBootstrapRematerializationWhileEngineOwnsPresentation() {
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldRunLegacyBootstrapRematerialization(
                isArchiveEnginePresentationActive: true
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldRunLegacyBootstrapRematerialization(
                isArchiveEnginePresentationActive: false
            )
        )
    }

    func testVerifiedPrefetchCanKeepAlreadyCommittedWindowVisibleDuringAtomicApply() throws {
        let current = try makeSnapshot(generation: 7)
        let incoming = try makeSnapshot(
            generation: 8,
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "10")))
        )

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldPreserveCommittedContent(
                currentState: .verified(current),
                committedCoverageGeneration: 7,
                incoming: incoming
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldPreserveCommittedContent(
                currentState: .skeleton(reason: .boundaryGap, target: incoming.target),
                committedCoverageGeneration: nil,
                incoming: incoming
            )
        )
    }

    func testRepeatedPresentationStartForSameSemanticIntentPreservesCommittedProof() {
        let current = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let duplicate = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )

        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: true,
                currentIntent: current,
                incomingIntent: duplicate
            )
        )
    }

    func testPresentationStartResetsOnlyForFirstLifecycleAdmission() throws {
        let current = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let target = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: false,
                currentIntent: nil,
                incomingIntent: current
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: true,
                currentIntent: current,
                incomingIntent: target
            )
        )
    }

    func testDuplicateVerifiedEmissionIsCoalescedWhilePendingAndAfterCommit() throws {
        let snapshot = try makeSnapshot(generation: 7)
        let state = ArchiveWindowState.verified(snapshot)

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: state,
                committedCoverageGeneration: nil,
                pendingSnapshot: snapshot,
                incoming: snapshot
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: state,
                committedCoverageGeneration: 7,
                pendingSnapshot: nil,
                incoming: snapshot
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: state,
                committedCoverageGeneration: nil,
                pendingSnapshot: nil,
                incoming: snapshot
            )
        )
    }

    func testPrefetchRequiresMatchingCommittedProof() throws {
        let snapshot = try makeSnapshot(generation: 7)

        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: nil,
                isShowingSkeleton: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: 6,
                isShowingSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: 7,
                isShowingSkeleton: false
            )
        )
    }

    func testPendingOpenRequestWaitsForVerifiedPresentationCommit() throws {
        let snapshot = try makeSnapshot(generation: 7)
        let state = ArchiveWindowState.verified(snapshot)

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
                isPresentationActive: true,
                state: state,
                committedCoverageGeneration: nil,
                pendingSnapshot: snapshot,
                isShowingSkeleton: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
                isPresentationActive: true,
                state: state,
                committedCoverageGeneration: 7,
                pendingSnapshot: nil,
                isShowingSkeleton: false
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
                isPresentationActive: false,
                state: nil,
                committedCoverageGeneration: nil,
                pendingSnapshot: nil,
                isShowingSkeleton: false
            )
        )
    }

    func testOnlyBoundaryExpansionPreservesTheExistingViewportAnchor() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "10"))

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .older(before: cursor)
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .newer(after: cursor)
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .latest
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .archiveID(cursor)
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .timestamp(Date())
            )
        )
    }

    func testOlderBoundaryApplyNeverDropsOffsetWhenLiveAnchorIsTemporarilyUnavailable() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        let retainedAnchor = ChatHistoryPageAnchor(
            primary: "visible-message",
            viewportRelativeMinY: 37
        )

        XCTAssertEqual(
            ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                for: .older(before: cursor),
                live: nil,
                retained: retainedAnchor
            ),
            retainedAnchor
        )

        let retainedPlan = ChatArchiveWindowPresentationPolicy.boundaryApplyPlan(
            for: .older(before: cursor),
            hasCapturedAnchor: true
        )
        XCTAssertFalse(retainedPlan.keepOffset)
        XCTAssertEqual(retainedPlan.restorePhase, .applyTransaction)

        let offsetFallbackPlan = ChatArchiveWindowPresentationPolicy.boundaryApplyPlan(
            for: .older(before: cursor),
            hasCapturedAnchor: false
        )
        XCTAssertTrue(offsetFallbackPlan.keepOffset)
        XCTAssertEqual(offsetFallbackPlan.restorePhase, .none)
    }

    func testCurrentBoundaryAnchorSupersedesAnchorCapturedAtRequestStart() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        let retainedAnchor = ChatHistoryPageAnchor(
            primary: "request-start-message",
            viewportRelativeMinY: 20
        )
        let liveAnchor = ChatHistoryPageAnchor(
            primary: "current-visible-message",
            viewportRelativeMinY: 44
        )

        XCTAssertEqual(
            ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                for: .older(before: cursor),
                live: liveAnchor,
                retained: retainedAnchor
            ),
            liveAnchor
        )
        XCTAssertNil(
            ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                for: .latest,
                live: liveAnchor,
                retained: retainedAnchor
            )
        )
    }

    func testMissingBoundaryAnchorFallsBackToSkeletonInsteadOfJumpingTheViewport() throws {
        let locator = ArchiveWindowLocator.older(
            before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        )

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: locator,
                hasUsableAnchor: false,
                hasCommittedContent: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: locator,
                hasUsableAnchor: true,
                hasCommittedContent: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: .latest,
                hasUsableAnchor: false,
                hasCommittedContent: true
            )
        )
    }

    func testBoundaryPresentationRetriesTransientAtomicFailuresOnlyTwice() {
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .alignmentUnresolved(target: "anchor", error: 2),
                completedRetryCount: 0
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .targetMissing(primary: "anchor"),
                completedRetryCount: 1
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .alignmentUnresolved(target: "anchor", error: 2),
                completedRetryCount: 2
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .superseded,
                completedRetryCount: 0
            )
        )
    }

    func testPrependViewportFallbackAdmitsOnlyAnExactOldSuffix() {
        XCTAssertTrue(
            ChatPrependViewportFallbackPolicy.isEligible(
                previousPrimaryIDs: ["m67", "m68", "m69"],
                nextPrimaryIDs: ["m1", "m2", "m67", "m68", "m69"],
                anchorPrimary: "m68"
            )
        )
        XCTAssertFalse(
            ChatPrependViewportFallbackPolicy.isEligible(
                previousPrimaryIDs: ["m67", "m68", "m69"],
                nextPrimaryIDs: ["m1", "m67", "inserted", "m68", "m69"],
                anchorPrimary: "m68"
            )
        )
        XCTAssertFalse(
            ChatPrependViewportFallbackPolicy.isEligible(
                previousPrimaryIDs: ["m67", "m68", "m69"],
                nextPrimaryIDs: ["m1", "m2", "m67", "m68", "m69"],
                anchorPrimary: "missing"
            )
        )
    }

    func testPrependViewportFallbackUsesContentHeightDeltaAndClamps() {
        XCTAssertEqual(
            ChatPrependViewportFallbackPolicy.targetContentOffsetY(
                previousContentOffsetY: 120,
                previousContentHeight: 700,
                nextContentHeight: 1_100,
                minimumContentOffsetY: -20,
                maximumContentOffsetY: 900
            ),
            520,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatPrependViewportFallbackPolicy.targetContentOffsetY(
                previousContentOffsetY: 800,
                previousContentHeight: 700,
                nextContentHeight: 1_100,
                minimumContentOffsetY: -20,
                maximumContentOffsetY: 900
            ),
            900,
            accuracy: 0.001
        )
    }

    private func makeSnapshot(
        generation: UInt64,
        target: ArchiveWindowLocator = .latest
    ) throws -> ArchiveWindowSnapshot {
        ArchiveWindowSnapshot(
            messagePrimaryIDs: ["p10"],
            target: target,
            verifiedSegment: try makeSegment(oldest: "10", newest: "10"),
            coverageGeneration: generation,
            freshnessToken: .xepSync(fingerprint: "sync")
        )
    }

    private func makeSegment(
        oldest: String,
        newest: String,
        reachesArchiveStart: Bool = true,
        reachesLiveEdge: Bool = true
    ) throws -> ArchiveCoverageSegment {
        try XCTUnwrap(
            ArchiveCoverageSegment(
                oldest: XCTUnwrap(ArchiveCursor(rawValue: oldest)),
                newest: XCTUnwrap(ArchiveCursor(rawValue: newest)),
                reachesArchiveStart: reachesArchiveStart,
                reachesLiveEdge: reachesLiveEdge,
                fingerprint: "sync",
                isVerified: true
            )
        )
    }

    private func message(primary: String, archiveID: String) -> MessageStorageItem {
        let value = MessageStorageItem()
        value.primary = primary
        value.owner = conversation.owner
        value.opponent = conversation.jid
        value.conversationType = conversation.conversationType
        value.archivedId = archiveID
        value.date = Date(timeIntervalSince1970: TimeInterval(archiveID) ?? 0)
        return value
    }
}
