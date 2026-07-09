import XCTest
@testable import xabber

final class ChatReloadInvalidationPolicyTests: XCTestCase {
    func testSensitiveMediaRevealUsesTargetedCurrentWindowRefresh() {
        let plan = ChatReloadInvalidationPolicy.sensitiveMediaRevealPlan()

        guard case .targetedDiff = plan.mode else {
            return XCTFail("Sensitive media reveal should remap through targeted diff")
        }
        XCTAssertFalse(plan.animated)
        XCTAssertFalse(plan.invalidateLayout)
        XCTAssertTrue(plan.suppressDefaultBottomScroll)
    }

    func testDeliveryAndReadStateUpdatesAreContentOnlyWhenSizeIsUnchanged() {
        let old = makeDatasource(
            state: .sending,
            indicator: .sending,
            isRead: false
        )
        let new = makeDatasource(
            state: .read,
            indicator: .read,
            isRead: true
        )

        let diff = diff(old: [old], new: [new])

        XCTAssertEqual(diff.contentOnlyUpdates, [
            ChatMessageContentUpdate(primary: "message-1", indexPath: IndexPath(item: 0, section: 0))
        ])
        XCTAssertTrue(diff.reloads.isEmpty)
        XCTAssertFalse(diff.hasCollectionUpdates)
    }

    func testMediaDownloadCompletionUsesContentOnlyUpdateWhenMeasuredSizeIsUnchanged() {
        let old = makeDatasource(files: [
            FileAttachment(
                primary: "file-1",
                url: URL(string: "file:///tmp/report.pdf"),
                size: 1_024,
                name: "report.pdf",
                downloaded: false
            )
        ])
        let new = makeDatasource(files: [
            FileAttachment(
                primary: "file-1",
                url: URL(string: "file:///tmp/report.pdf"),
                size: 1_024,
                name: "report.pdf",
                downloaded: true
            )
        ])

        let diff = diff(old: [old], new: [new])

        XCTAssertEqual(diff.contentOnlyUpdates, [
            ChatMessageContentUpdate(primary: "message-1", indexPath: IndexPath(item: 0, section: 0))
        ])
        XCTAssertTrue(diff.reloads.isEmpty)
        XCTAssertTrue(diff.inserts.isEmpty)
        XCTAssertTrue(diff.deletes.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
    }

    func testMessageEditWithChangedMeasuredSizeInvalidatesOnlyAffectedMessageLayout() {
        let old = makeDatasource(text: "Short")
        let new = makeDatasource(
            text: "A much longer edited message that changes the measured bubble height",
            editDate: Date(timeIntervalSince1970: 2_000)
        )

        let diff = diff(
            old: [old],
            new: [new],
            oldSize: CGSize(width: 320, height: 44),
            newSize: CGSize(width: 320, height: 88)
        )

        XCTAssertTrue(diff.contentOnlyUpdates.isEmpty)
        XCTAssertEqual(diff.reloads, [IndexPath(item: 0, section: 0)])
        XCTAssertTrue(diff.inserts.isEmpty)
        XCTAssertTrue(diff.deletes.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
    }

    func testOlderPrependWithCapturedAnchorUsesAnchorReloadInsteadOfKeepOffsetReload() {
        let plan = ChatHistoryPageApplyPolicy.plan(direction: .older, hasCapturedAnchor: true)

        XCTAssertFalse(plan.keepOffset)
        XCTAssertEqual(plan.restorePhase, .applyTransaction)
        XCTAssertEqual(plan.applyCategory, .olderAnchorReload)
    }

    func testNewerAnchorCaptureTreatsBottomPlaceholderAsNonLiveBottom() {
        XCTAssertTrue(ChatHistoryPageAnchorCapturePolicy.shouldCaptureNewerAnchor(
            isNearBottom: true,
            isResidentAtLiveTail: false,
            hasBottomBoundaryPlaceholder: true,
            hasBottomVirtualPlaceholder: true,
            hasNewerRemoteLoad: true
        ))
    }

    func testNewerAnchorCaptureKeepsLiveBottomLatestBehavior() {
        XCTAssertFalse(ChatHistoryPageAnchorCapturePolicy.shouldCaptureNewerAnchor(
            isNearBottom: true,
            isResidentAtLiveTail: true,
            hasBottomBoundaryPlaceholder: false,
            hasBottomVirtualPlaceholder: false,
            hasNewerRemoteLoad: false
        ))
    }

    func testNewerAnchorCaptureTreatsNonLiveLocalBottomAsVirtualBottom() {
        XCTAssertTrue(ChatHistoryPageAnchorCapturePolicy.shouldCaptureNewerAnchor(
            isNearBottom: true,
            isResidentAtLiveTail: false,
            hasBottomBoundaryPlaceholder: false,
            hasBottomVirtualPlaceholder: false,
            hasNewerRemoteLoad: false
        ))
    }

    func testSearchObserverRefreshAwayFromBottomPreservesVisibleNewerAnchor() {
        XCTAssertTrue(ChatObserverRefreshAnchorRestorePolicy.shouldSuppressOpenLatest(
            isSearchModeActive: true,
            isNearBottom: false,
            hasPendingForceLatestOpen: false
        ))
        XCTAssertEqual(
            ChatObserverRefreshAnchorRestorePolicy.visibleAnchorDirection(
                isSearchModeActive: true,
                isNearBottom: false,
                willOpenLatest: false,
                hasSearchAnchorWork: false,
                isShowingBootstrapPlaceholder: false
            ),
            .newer
        )
        XCTAssertEqual(
            ChatObserverRefreshAnchorRestorePolicy.restorePhase(hasCapturedAnchor: true),
            .completion
        )
    }

    func testSearchObserverRefreshAtLiveBottomKeepsLatestBehavior() {
        XCTAssertFalse(ChatObserverRefreshAnchorRestorePolicy.shouldSuppressOpenLatest(
            isSearchModeActive: true,
            isNearBottom: true,
            hasPendingForceLatestOpen: false
        ))
        XCTAssertNil(ChatObserverRefreshAnchorRestorePolicy.visibleAnchorDirection(
            isSearchModeActive: true,
            isNearBottom: true,
            willOpenLatest: true,
            hasSearchAnchorWork: false,
            isShowingBootstrapPlaceholder: false
        ))
    }

    func testSearchObserverRefreshDoesNotSuppressExplicitForceLatest() {
        XCTAssertFalse(ChatObserverRefreshAnchorRestorePolicy.shouldSuppressOpenLatest(
            isSearchModeActive: true,
            isNearBottom: false,
            hasPendingForceLatestOpen: true
        ))
        XCTAssertNil(ChatObserverRefreshAnchorRestorePolicy.visibleAnchorDirection(
            isSearchModeActive: true,
            isNearBottom: false,
            willOpenLatest: true,
            hasSearchAnchorWork: false,
            isShowingBootstrapPlaceholder: false
        ))
    }

    func testTailAppendPinsBottomOnlyWhenNearBottomAndNotAnchorDeferred() {
        let oldItems = [
            makeDatasource(primary: "m1"),
            makeDatasource(primary: "m2")
        ]
        let newItems = oldItems + [makeDatasource(primary: "m3")]
        let oldSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: oldItems)
        let newSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: newItems)

        XCTAssertTrue(ChatTailAppendBottomPinPolicy.shouldPinBottom(
            old: oldSnapshot,
            new: newSnapshot,
            wasNearBottom: true,
            isDefaultBottomScrollDeferred: false,
            suppressDefaultBottomScroll: false,
            containsOnlyFakeMessages: false,
            outgoingAutoScrollDecision: .notHandled
        ))
        XCTAssertFalse(ChatTailAppendBottomPinPolicy.shouldPinBottom(
            old: oldSnapshot,
            new: newSnapshot,
            wasNearBottom: false,
            isDefaultBottomScrollDeferred: false,
            suppressDefaultBottomScroll: false,
            containsOnlyFakeMessages: false,
            outgoingAutoScrollDecision: .notHandled
        ))
        XCTAssertFalse(ChatTailAppendBottomPinPolicy.shouldPinBottom(
            old: oldSnapshot,
            new: newSnapshot,
            wasNearBottom: true,
            isDefaultBottomScrollDeferred: true,
            suppressDefaultBottomScroll: false,
            containsOnlyFakeMessages: false,
            outgoingAutoScrollDecision: .notHandled
        ))
    }

    func testInitialSkeletonRevealKeepsForcedNewestBottomAlignmentTarget() throws {
        let items = [
            makeDatasource(primary: "oldest"),
            makeDatasource(primary: "newest")
        ]

        XCTAssertEqual(
            ChatBottomAlignmentTargetPolicy.indexPath(for: .newestRealMessage, in: items),
            IndexPath(item: 0, section: 1)
        )
    }

    private func diff(
        old oldItems: [ChatViewController.Datasource],
        new newItems: [ChatViewController.Datasource],
        oldSize: CGSize = CGSize(width: 320, height: 44),
        newSize: CGSize = CGSize(width: 320, height: 44)
    ) -> ChatDatasourceCoordinator.DiffResult {
        ChatDatasourceCoordinator.diff(
            old: ChatDatasourceCoordinator.makeSnapshot(items: oldItems),
            new: ChatDatasourceCoordinator.makeSnapshot(items: newItems),
            oldSizeProvider: { _ in oldSize },
            newSizeProvider: { _ in newSize }
        )
    }

    private func makeDatasource(
        primary: String = "message-1",
        text: String = "Hello",
        state: MessageStorageItem.MessageSendingState = .deliver,
        indicator: IndicatorType = .read,
        editDate: Date? = nil,
        files: [FileAttachment] = [],
        isRead: Bool = true
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: true,
            sender: Sender(id: "owner@example.com", displayName: "Owner"),
            messageId: "\(primary)-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: editDate,
            kind: .attributedText(NSAttributedString(string: text)),
            withAuthor: false,
            withAvatar: false,
            error: state == .error,
            errorType: "",
            canPinMessage: true,
            canEditMessage: true,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: true,
            isEdited: editDate != nil,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: files.isNotEmpty,
            isDownloaded: files.allSatisfy(\.downloaded),
            state: state,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "\(primary)-archived",
            queryIds: nil,
            isRead: isRead,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: files,
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: indicator,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }
}
