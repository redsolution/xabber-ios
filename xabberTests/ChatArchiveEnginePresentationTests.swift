import XCTest
@testable import xabber

final class ChatArchiveEnginePresentationTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

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
