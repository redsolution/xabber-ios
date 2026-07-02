import XCTest
@testable import xabber

final class ChatScrollBoundaryCacheTests: XCTestCase {
    private let key = ChatTimelineConversationKey(
        owner: "owner@example.com",
        jid: "romeo@example.com",
        conversationType: .regular
    )
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testRefreshQueriesProviderOnceAndScrollSnapshotDoesNotQueryAgain() {
        let provider = FakeScrollBoundaryAvailabilityProvider(
            hasOlderLocalPage: true,
            hasNewerLocalPage: false
        )
        var cache = ChatScrollBoundaryAvailabilityCache.empty

        cache.refresh(
            conversationKey: key,
            timelineState: timelineState(oldestArchivedId: "100", newestArchivedId: "200"),
            archiveState: archiveState(fullArchiveLoaded: false),
            provider: provider,
            hasConfirmedArchiveEndThisSession: false,
            hasUsedArchiveEndVerificationProbe: false
        )

        XCTAssertEqual(provider.olderQueryCount, 1)
        XCTAssertEqual(provider.newerQueryCount, 1)

        provider.resetCounts()
        let availability = cache.availability(for: key)

        XCTAssertEqual(provider.totalQueryCount, 0)
        XCTAssertTrue(availability?.hasLocalOlderPage == true)
        XCTAssertFalse(availability?.hasLocalNewerPage == true)
        XCTAssertTrue(availability?.hasRemoteOlderPage == true)
        XCTAssertFalse(availability?.hasRemoteNewerPage == true)
    }

    func testRefreshUpdatesAvailabilityAfterResidentWindowChanges() {
        let provider = FakeScrollBoundaryAvailabilityProvider(
            hasOlderLocalPage: true,
            hasNewerLocalPage: false
        )
        var cache = ChatScrollBoundaryAvailabilityCache.empty

        cache.refresh(
            conversationKey: key,
            timelineState: timelineState(oldestArchivedId: "100", newestArchivedId: "200"),
            archiveState: archiveState(fullArchiveLoaded: true, newerLiveEdgeReached: true),
            provider: provider,
            hasConfirmedArchiveEndThisSession: true,
            hasUsedArchiveEndVerificationProbe: true
        )
        XCTAssertTrue(cache.availability(for: key)?.hasLocalOlderPage == true)
        XCTAssertFalse(cache.availability(for: key)?.hasLocalNewerPage == true)

        provider.hasOlderLocalPage = false
        provider.hasNewerLocalPage = true
        cache.refresh(
            conversationKey: key,
            timelineState: timelineState(oldestArchivedId: "050", newestArchivedId: "250"),
            archiveState: archiveState(fullArchiveLoaded: true, newerLiveEdgeReached: true),
            provider: provider,
            hasConfirmedArchiveEndThisSession: true,
            hasUsedArchiveEndVerificationProbe: true
        )

        XCTAssertFalse(cache.availability(for: key)?.hasLocalOlderPage == true)
        XCTAssertTrue(cache.availability(for: key)?.hasLocalNewerPage == true)
    }

    func testAvailabilityIsScopedToConversationIdentity() {
        let provider = FakeScrollBoundaryAvailabilityProvider(
            hasOlderLocalPage: true,
            hasNewerLocalPage: true
        )
        var cache = ChatScrollBoundaryAvailabilityCache.empty
        let otherKey = ChatTimelineConversationKey(
            owner: key.owner,
            jid: "juliet@example.com",
            conversationType: key.conversationType
        )

        cache.refresh(
            conversationKey: key,
            timelineState: timelineState(oldestArchivedId: "100", newestArchivedId: "200"),
            archiveState: archiveState(fullArchiveLoaded: false, newerLiveEdgeReached: false),
            provider: provider,
            hasConfirmedArchiveEndThisSession: false,
            hasUsedArchiveEndVerificationProbe: false
        )

        XCTAssertNotNil(cache.availability(for: key))
        XCTAssertNil(cache.availability(for: otherKey))
    }

    func testKnownArchiveGapsKeepRemoteBoundaryDirectionsAvailable() {
        let provider = FakeScrollBoundaryAvailabilityProvider(
            hasOlderLocalPage: false,
            hasNewerLocalPage: false
        )
        let gapAbove = RegularChatArchiveGap(
            olderRangeNewestArchiveId: "080",
            newerRangeOldestArchiveId: "100"
        )
        let gapBelow = RegularChatArchiveGap(
            olderRangeNewestArchiveId: "200",
            newerRangeOldestArchiveId: "240"
        )
        var cache = ChatScrollBoundaryAvailabilityCache.empty

        cache.refresh(
            conversationKey: key,
            timelineState: timelineState(oldestArchivedId: "100", newestArchivedId: "200"),
            archiveState: archiveState(
                fullArchiveLoaded: true,
                newerLiveEdgeReached: true,
                knownGaps: [gapAbove, gapBelow]
            ),
            provider: provider,
            hasConfirmedArchiveEndThisSession: true,
            hasUsedArchiveEndVerificationProbe: true
        )

        let availability = cache.availability(for: key)
        XCTAssertTrue(availability?.hasKnownArchiveGapAbove == true)
        XCTAssertTrue(availability?.hasKnownArchiveGapBelow == true)
        XCTAssertTrue(availability?.hasRemoteOlderPage == true)
        XCTAssertTrue(availability?.hasRemoteNewerPage == true)
    }

    func testInFlightRemotePageSuppressesDuplicateRemoteTrigger() {
        let provider = FakeScrollBoundaryAvailabilityProvider(
            hasOlderLocalPage: false,
            hasNewerLocalPage: false
        )
        var cache = ChatScrollBoundaryAvailabilityCache.empty
        let state = timelineState(
            oldestArchivedId: "100",
            newestArchivedId: "200",
            activeRemoteLoad: ChatTimelineRemoteLoad(
                queryId: "query-1",
                direction: .older,
                decision: .remoteOlderPage,
                cursorId: "100"
            )
        )

        cache.refresh(
            conversationKey: key,
            timelineState: state,
            archiveState: archiveState(fullArchiveLoaded: false, newerLiveEdgeReached: false),
            provider: provider,
            hasConfirmedArchiveEndThisSession: false,
            hasUsedArchiveEndVerificationProbe: false
        )

        let availability = cache.availability(for: key)
        XCTAssertTrue(availability?.isRemotePageInFlight == true)
        XCTAssertFalse(availability?.hasRemoteOlderPage == true)
        XCTAssertFalse(availability?.hasRemoteNewerPage == true)

        XCTAssertNil(ChatHistoryPagingPolicy.triggerDirection(
            isUserScrolling: true,
            canLoadDatasource: true,
            gestureTranslationY: 48,
            boundaryContext: ChatHistoryPagingBoundaryContext(
                firstRealSection: 0,
                lastRealSection: 1,
                visibleRealSections: [0]
            ),
            currentPageMinIndex: 0,
            currentPageMaxIndex: 2,
            totalCount: 2,
            hasLocalOlderAvailable: availability?.hasLocalOlderPage == true,
            hasLocalNewerAvailable: availability?.hasLocalNewerPage == true,
            hasRemoteOlderAvailable: availability?.hasRemoteOlderPage == true,
            hasRemoteNewerAvailable: availability?.hasRemoteNewerPage == true
        ))
    }

    private func timelineState(
        oldestArchivedId: String,
        newestArchivedId: String,
        activeRemoteLoad: ChatTimelineRemoteLoad? = nil
    ) -> ChatVirtualTimelineState {
        ChatVirtualTimelineState(
            conversationKey: key,
            segments: [],
            oldest: boundary(archivedId: oldestArchivedId),
            newest: boundary(archivedId: newestArchivedId),
            residentPrimaryKeys: ["primary-\(oldestArchivedId)", "primary-\(newestArchivedId)"],
            residentArchivedIds: [oldestArchivedId, newestArchivedId],
            activeRemoteLoad: activeRemoteLoad,
            activePlaceholder: activeRemoteLoad.map { $0.direction == .older ? .top : .bottom },
            isResidentAtLiveTail: false
        )
    }

    private func boundary(archivedId: String) -> ChatTimelineBoundary {
        ChatTimelineBoundary(
            primary: "primary-\(archivedId)",
            archivedId: archivedId,
            messageId: "message-\(archivedId)",
            date: date
        )
    }

    private func archiveState(
        fullArchiveLoaded: Bool,
        newerLiveEdgeReached: Bool = true,
        knownGaps: [RegularChatArchiveGap] = []
    ) -> ChatArchiveStateSnapshot {
        ChatArchiveStateSnapshot(
            primaryKey: "chat-primary",
            persistedCursorId: "100",
            fullArchiveLoaded: fullArchiveLoaded,
            newestCursorId: "200",
            newerLiveEdgeReached: newerLiveEdgeReached,
            hasKnownNewerGap: knownGaps.isNotEmpty,
            knownGaps: knownGaps
        )
    }
}

private final class FakeScrollBoundaryAvailabilityProvider: ChatScrollBoundaryLocalHistoryAvailabilityProviding {
    var hasOlderLocalPage: Bool
    var hasNewerLocalPage: Bool
    private(set) var olderQueryCount = 0
    private(set) var newerQueryCount = 0

    var totalQueryCount: Int {
        olderQueryCount + newerQueryCount
    }

    init(hasOlderLocalPage: Bool, hasNewerLocalPage: Bool) {
        self.hasOlderLocalPage = hasOlderLocalPage
        self.hasNewerLocalPage = hasNewerLocalPage
    }

    func hasOlderLocalPage(before boundary: ChatTimelineBoundary) -> Bool {
        olderQueryCount += 1
        return hasOlderLocalPage
    }

    func hasNewerLocalPage(after boundary: ChatTimelineBoundary) -> Bool {
        newerQueryCount += 1
        return hasNewerLocalPage
    }

    func resetCounts() {
        olderQueryCount = 0
        newerQueryCount = 0
    }
}
