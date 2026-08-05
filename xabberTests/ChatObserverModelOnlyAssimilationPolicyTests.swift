import XCTest
import UIKit
@testable import xabber

final class ChatObserverModelOnlyAssimilationPolicyTests: XCTestCase {
    func testExactDatasourceAndLayoutNoOpIsAccepted() {
        let row = datasource()

        XCTAssertEqual(
            decision(current: [row], mapped: [row]),
            .exactNoOp
        )
    }

    func testExactModelNoOpDoesNotRequireACompleteLayoutCache() {
        let row = datasource()

        XCTAssertEqual(
            decision(
                current: [row],
                mapped: [row],
                hasCurrentLayout: false,
                hasMappedLayout: false
            ),
            .exactNoOp
        )
    }

    func testIncomingDeliverToReadOnlyTransitionIsAccepted() {
        let unread = datasource(
            primary: "incoming-unread",
            archivedId: "archive-unread"
        )
        var read = unread
        read.state = .read
        read.isRead = true
        let unchanged = datasource(
            primary: "incoming-unchanged",
            archivedId: "archive-unchanged",
            state: .read,
            isRead: true
        )

        XCTAssertEqual(
            decision(
                current: [unread, unchanged],
                mapped: [read, unchanged]
            ),
            .incomingReadOnly(changedPrimaries: ["incoming-unread"])
        )
    }

    func testThroughReadKeepsDateSeparatorInvariantAndAcceptsOnlyIncomingRows() {
        var dateSeparator = datasource(
            primary: "date-separator",
            archivedId: "archive-date-separator",
            state: .none,
            isRead: ChatDateSeparatorPresentationPolicy.isRead
        )
        dateSeparator.isFakeMessage = true
        dateSeparator.kind = .date(NSAttributedString(string: "Today"))
        let firstUnread = datasource(
            primary: "incoming-first",
            archivedId: "archive-first"
        )
        let targetUnread = datasource(
            primary: "incoming-target",
            archivedId: "archive-target"
        )
        var firstRead = firstUnread
        firstRead.state = .read
        firstRead.isRead = true
        var targetRead = targetUnread
        targetRead.state = .read
        targetRead.isRead = true

        XCTAssertTrue(ChatDateSeparatorPresentationPolicy.isRead)
        XCTAssertEqual(
            decision(
                current: [dateSeparator, firstUnread, targetUnread],
                mapped: [dateSeparator, firstRead, targetRead]
            ),
            .incomingReadOnly(
                changedPrimaries: [firstUnread.primary, targetUnread.primary]
            )
        )
    }

    func testUnreadMentionPresentationProjectionIgnoresGeneralUnreadCountButDetectsMentionChanges() {
        let mention = ChatUnreadMentionItem(
            notificationPrimary: "notification",
            messagePrimary: "message",
            archivedId: "archive",
            messageId: "message-id",
            chatPrimary: "chat",
            authorId: "author",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            targetMemberId: "member",
            groupchatJid: "room@example.com"
        )
        let baseline = ChatUnreadMentionPresentationMetadata(
            ChatTimelineUnreadMetadata(
                unreadCount: 3,
                mentions: [mention],
                candidateCount: 1,
                latestUnreadMentionArchivedId: mention.archivedId
            )
        )
        let generalReadOnly = ChatUnreadMentionPresentationMetadata(
            ChatTimelineUnreadMetadata(
                unreadCount: 1,
                mentions: [mention],
                candidateCount: 9,
                latestUnreadMentionArchivedId: mention.archivedId
            )
        )
        let consumedMention = ChatUnreadMentionPresentationMetadata(
            ChatTimelineUnreadMetadata(
                unreadCount: 1,
                mentions: [],
                candidateCount: 0,
                latestUnreadMentionArchivedId: nil
            )
        )

        XCTAssertEqual(baseline, generalReadOnly)
        XCTAssertNotEqual(baseline, consumedMention)
        XCTAssertNil(
            ChatUnreadMentionPresentationTrackingPolicy.trackedProjection(
                authoritative: .empty,
                appliedMentions: [mention]
            ),
            "a provisional Realm fallback must not mask the next authoritative empty frame"
        )
        XCTAssertEqual(
            ChatUnreadMentionPresentationTrackingPolicy.trackedProjection(
                authoritative: .empty,
                appliedMentions: []
            ),
            consumedMention
        )
        let hintOnlyMetadata = ChatTimelineUnreadMetadata(
            unreadCount: 1,
            mentions: [],
            candidateCount: 0,
            latestUnreadMentionArchivedId: "archive-hint"
        )
        let hintOnlyItems = ChatUnreadMentionPresentationItemsPolicy.items(
            metadata: hintOnlyMetadata,
            chatPrimary: "chat",
            groupchatJid: "room@example.com"
        )
        XCTAssertEqual(hintOnlyItems.count, 1)
        XCTAssertEqual(hintOnlyItems.first?.archivedId, "archive-hint")
        XCTAssertNil(hintOnlyItems.first?.notificationPrimary)
        XCTAssertTrue(
            ChatUnreadMentionPresentationItemsPolicy.items(
                metadata: .empty,
                chatPrimary: "chat",
                groupchatJid: "room@example.com"
            ).isEmpty,
            "authoritative hint removal must clear the queryless fallback"
        )
        let hintProjection = ChatUnreadMentionPresentationMetadata(
            hintOnlyMetadata
        )
        XCTAssertEqual(
            ChatUnreadMentionPresentationReconciliationPolicy.decision(
                lastApplied: hintProjection,
                metadata: hintOnlyMetadata,
                chatPrimary: "chat",
                groupchatJid: "room@example.com"
            ),
            .unchanged,
            "repeating identical metadata must schedule zero presentation writes"
        )
        XCTAssertEqual(
            ChatUnreadMentionPresentationReconciliationPolicy.decision(
                lastApplied: hintProjection,
                metadata: .empty,
                chatPrimary: "chat",
                groupchatJid: "room@example.com"
            ),
            .apply(metadata: consumedMention, items: []),
            "external hint removal must clear the provisional navigator target"
        )
        XCTAssertEqual(
            ChatUnreadMentionPresentationReconciliationPolicy.decision(
                lastApplied: consumedMention,
                metadata: ChatTimelineUnreadMetadata(
                    unreadCount: 1,
                    mentions: [mention],
                    candidateCount: 1,
                    latestUnreadMentionArchivedId: mention.archivedId
                ),
                chatPrimary: "chat",
                groupchatJid: "room@example.com"
            ),
            .apply(metadata: baseline, items: [mention]),
            "an external mention must become visible without a Realm fallback query"
        )
    }

    func testUnreadMentionBadgeClaimClearsWhenFinalTargetDisappears() {
        XCTAssertTrue(
            ChatUnreadMentionBadgeClaimPolicy.shouldClearClaim(
                claimedNotificationPrimary: "claimed-notification",
                nextJumpNotificationPrimary: nil
            ),
            "consuming the final mention must release its badge claim"
        )
        XCTAssertFalse(
            ChatUnreadMentionBadgeClaimPolicy.shouldClearClaim(
                claimedNotificationPrimary: "claimed-notification",
                nextJumpNotificationPrimary: "claimed-notification"
            )
        )
        XCTAssertTrue(
            ChatUnreadMentionBadgeClaimPolicy.shouldClearClaim(
                claimedNotificationPrimary: "claimed-notification",
                nextJumpNotificationPrimary: "next-notification"
            )
        )
        XCTAssertFalse(
            ChatUnreadMentionBadgeClaimPolicy.shouldClearClaim(
                claimedNotificationPrimary: nil,
                nextJumpNotificationPrimary: nil
            )
        )
    }

    func testUnreadMentionPresentationCommitRequiresNavigatorApply() {
        let previouslyApplied = ChatUnreadMentionPresentationMetadata(
            ChatTimelineUnreadMetadata(
                unreadCount: 1,
                mentions: [],
                candidateCount: 0,
                latestUnreadMentionArchivedId: "previous-hint"
            )
        )

        XCTAssertEqual(
            ChatUnreadMentionPresentationCommitPolicy.nextTrackedProjection(
                previous: previouslyApplied,
                authoritative: .empty,
                appliedMentions: [],
                didApplyNavigatorState: false
            ),
            previouslyApplied,
            "a model-only rebuild deferred by search/anchor work must not claim presentation ownership"
        )
        XCTAssertEqual(
            ChatUnreadMentionPresentationCommitPolicy.nextTrackedProjection(
                previous: previouslyApplied,
                authoritative: .empty,
                appliedMentions: [],
                didApplyNavigatorState: true
            ),
            ChatUnreadMentionPresentationMetadata(.empty),
            "the consumed empty state becomes tracked only after navigator apply"
        )
    }

    func testUnreadMentionPresentationTrackingAcceptsOnlyMatchingHintFallback()
        throws {
        let metadata = ChatTimelineUnreadMetadata(
            unreadCount: 1,
            mentions: [],
            candidateCount: 0,
            latestUnreadMentionArchivedId: "authoritative-hint"
        )
        let matchingFallback = try XCTUnwrap(
            ChatUnreadMentionFallbackPolicy.fallbackItem(
                mentionId: "authoritative-hint",
                chatPrimary: "chat",
                currentMemberId: nil,
                groupchatJid: "room@example.com",
                date: Date(timeIntervalSince1970: 0)
            )
        )
        let staleFallback = try XCTUnwrap(
            ChatUnreadMentionFallbackPolicy.fallbackItem(
                mentionId: "stale-hint",
                chatPrimary: "chat",
                currentMemberId: nil,
                groupchatJid: "room@example.com",
                date: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(
            ChatUnreadMentionPresentationTrackingPolicy.trackedProjection(
                authoritative: metadata,
                appliedMentions: [matchingFallback]
            ),
            ChatUnreadMentionPresentationMetadata(metadata)
        )
        XCTAssertNil(
            ChatUnreadMentionPresentationTrackingPolicy.trackedProjection(
                authoritative: metadata,
                appliedMentions: [staleFallback]
            )
        )
        XCTAssertNil(
            ChatUnreadMentionPresentationTrackingPolicy.trackedProjection(
                authoritative: .empty,
                appliedMentions: [matchingFallback]
            ),
            "a fallback without an authoritative hint remains provisional"
        )
    }

    func testOutgoingDeliverToReadTransitionIsRejected() {
        let delivered = datasource(outgoing: true)
        var read = delivered
        read.state = .read
        read.isRead = true

        XCTAssertEqual(
            decision(current: [delivered], mapped: [read]),
            .requiresUIKitApply
        )
    }

    func testPartialReverseAndNonReadTransitionsAreRejected() {
        let delivered = datasource()
        var stateOnly = delivered
        stateOnly.state = .read
        var flagOnly = delivered
        flagOnly.isRead = true
        var failed = delivered
        failed.state = .error
        failed.error = true
        failed.errorType = "failed"
        var read = delivered
        read.state = .read
        read.isRead = true

        for (name, current, mapped) in [
            ("state-only", delivered, stateOnly),
            ("flag-only", delivered, flagOnly),
            ("non-read", delivered, failed),
            ("reverse", read, delivered)
        ] {
            XCTAssertEqual(
                decision(current: [current], mapped: [mapped]),
                .requiresUIKitApply,
                name
            )
        }
    }

    func testStructuralReorderIdentityAndDuplicateChangesAreRejected() {
        let first = datasource(
            primary: "first",
            archivedId: "archive-first"
        )
        let second = datasource(
            primary: "second",
            archivedId: "archive-second",
            state: .read,
            isRead: true
        )
        var changedIdentity = first
        changedIdentity.primary = "replacement"
        var duplicatePrimary = second
        duplicatePrimary.primary = first.primary
        var duplicateArchive = second
        duplicateArchive.archivedId = first.archivedId

        let cases: [(String, [ChatViewController.Datasource], [ChatViewController.Datasource])] = [
            ("insert", [first], [first, second]),
            ("delete", [first, second], [first]),
            ("reorder", [first, second], [second, first]),
            ("identity", [first], [changedIdentity]),
            ("duplicate-primary", [first, duplicatePrimary], [first, duplicatePrimary]),
            ("duplicate-archive", [first, duplicateArchive], [first, duplicateArchive])
        ]

        for (name, current, mapped) in cases {
            XCTAssertEqual(
                decision(current: current, mapped: mapped),
                .requiresUIKitApply,
                name
            )
        }
    }

    func testVisualContentAvatarAttachmentErrorIndicatorAndPermissionChangesAreRejected() {
        let delivered = datasource()
        var read = delivered
        read.state = .read
        read.isRead = true

        var text = read
        text.kind = .attributedText(NSAttributedString(string: "edited"))
        var avatar = read
        avatar.avatarUrl = "avatar-v2"
        var attachment = read
        attachment.images = [
            ImageAttachment(
                primary: "image-1",
                url: URL(string: "file:///tmp/image.jpg"),
                size: CGSize(width: 120, height: 80)
            )
        ]
        var error = read
        error.error = true
        error.errorType = "failed"
        error.errorMetadata = ["certValid": false]
        var indicator = read
        indicator.indicator = .read
        var permission = read
        permission.canDeleteMessage = false
        var query = read
        query.queryIds = "query-v2"
        var archive = read
        archive.archivedId = "archive-v2"
        var sender = read
        sender.sender = Sender(id: sender.sender.id, displayName: "Changed sender")
        var timeMarker = read
        timeMarker.timeMarkerText = NSAttributedString(string: "12:01")

        for (name, mapped) in [
            ("text", text),
            ("avatar", avatar),
            ("attachment", attachment),
            ("error", error),
            ("indicator", indicator),
            ("permission", permission),
            ("query", query),
            ("archive", archive),
            ("sender", sender),
            ("time-marker", timeMarker)
        ] {
            XCTAssertEqual(
                decision(current: [delivered], mapped: [mapped]),
                .requiresUIKitApply,
                name
            )
        }
    }

    func testForwardAttributedVisualChangeRejectsModelOnlyAssimilation() {
        let oldNestedText = NSAttributedString(
            string: "Nested forward",
            attributes: [
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        let newNestedText = NSAttributedString(
            string: "Nested forward",
            attributes: [
                .foregroundColor: UIColor.systemRed,
                .underlineStyle: NSUnderlineStyle.double.rawValue
            ]
        )
        var delivered = datasource()
        delivered.forwards = nestedForwards(text: oldNestedText)
        var read = delivered
        read.state = .read
        read.isRead = true
        read.forwards = nestedForwards(text: newNestedText)

        XCTAssertEqual(
            decision(current: [delivered], mapped: [read]),
            .requiresUIKitApply
        )
    }

    func testLayoutChangeOrMissingLayoutIsRejected() {
        let delivered = datasource()
        var read = delivered
        read.state = .read
        read.isRead = true

        XCTAssertEqual(
            decision(
                current: [delivered],
                mapped: [read],
                mappedLayout: .empty(
                    cellSize: CGSize(width: 320, height: 96)
                )
            ),
            .requiresUIKitApply
        )
        XCTAssertEqual(
            decision(
                current: [delivered],
                mapped: [read],
                hasCurrentLayout: false
            ),
            .requiresUIKitApply
        )
        XCTAssertEqual(
            decision(
                current: [delivered],
                mapped: [read],
                hasMappedLayout: false
            ),
            .requiresUIKitApply
        )
    }

    func testChangedFakeOrDateSeparatorRowIsRejected() {
        var fake = datasource()
        fake.isFakeMessage = true
        fake.kind = .date(NSAttributedString(string: "Today"))
        var changed = fake
        changed.state = .read
        changed.isRead = true

        XCTAssertEqual(
            decision(current: [fake], mapped: [changed]),
            .requiresUIKitApply
        )
        XCTAssertEqual(
            decision(
                current: [fake],
                mapped: [fake],
                hasCurrentLayout: false,
                hasMappedLayout: false
            ),
            .exactNoOp
        )
    }

    func testEveryRouteGuardFallsThroughToUIKitApply() {
        let delivered = datasource()
        var read = delivered
        read.state = .read
        read.isRead = true
        let routes = [
            route(isTargetedDiff: false),
            route(invalidatesLayout: true),
            route(hasBoundaryPlaceholder: true),
            route(usesDefaultApplyCategory: false),
            route(hasPendingOutgoingAutoScroll: true),
            route(hasExplicitSearchOrAnchorMutation: true)
        ]

        for candidateRoute in routes {
            XCTAssertEqual(
                decision(
                    current: [delivered],
                    mapped: [read],
                    route: candidateRoute
                ),
                .requiresUIKitApply
            )
        }
    }

    func testNonObserverCurrentRouteAlwaysRequiresUIKitApply() {
        let delivered = datasource()
        var read = delivered
        read.state = .read
        read.isRead = true

        XCTAssertEqual(
            decision(
                current: [delivered],
                mapped: [read],
                route: route(isObserverCurrentRoute: false)
            ),
            .requiresUIKitApply
        )
    }

    func testIncomingReadOnlyCommitInstallsMappedModelAndCompletesWithoutWindowOrBoundaryRefresh() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
            ),
            encoding: .utf8
        )
        let branchStart = try XCTUnwrap(
            source.range(of: "                case .incomingReadOnly:\n")
        )
        let suffix = source[branchStart.upperBound...]
        let branchEnd = try XCTUnwrap(
            suffix.range(of: "                case .requiresUIKitApply:\n")
        )
        let branch = String(suffix[..<branchEnd.lowerBound])

        XCTAssertTrue(
            branch.contains(
                "self.datasourceSnapshot = mappedDatasourceSnapshot"
            )
        )
        XCTAssertTrue(
            branch.contains("self.datasource = mappedDatasource")
        )
        XCTAssertTrue(branch.contains("completion?()"))

        for forbiddenWork in [
            "syncCurrentPage",
            "refreshScrollBoundaryAvailabilityCache",
            "residentDatasetWindow",
            "scrollBoundaryAvailabilityCache",
            "WRealm.safe",
            "hasOlderLocalPage",
            "hasNewerLocalPage"
        ] {
            XCTAssertFalse(
                branch.contains(forbiddenWork),
                "incoming read-only assimilation must not perform \(forbiddenWork)"
            )
        }
    }

    private func decision(
        current: [ChatViewController.Datasource],
        mapped: [ChatViewController.Datasource],
        currentLayout: ChatMessageLayout = .empty(
            cellSize: CGSize(width: 320, height: 64)
        ),
        mappedLayout: ChatMessageLayout = .empty(
            cellSize: CGSize(width: 320, height: 64)
        ),
        hasCurrentLayout: Bool = true,
        hasMappedLayout: Bool = true,
        route: ChatObserverModelOnlyAssimilationRoute = ChatObserverModelOnlyAssimilationRoute(
            isObserverCurrentRoute: true,
            isTargetedDiff: true,
            invalidatesLayout: false,
            hasBoundaryPlaceholder: false,
            usesDefaultApplyCategory: true,
            hasPendingOutgoingAutoScroll: false,
            hasExplicitSearchOrAnchorMutation: false
        )
    ) -> ChatObserverModelOnlyAssimilationDecision {
        ChatObserverModelOnlyAssimilationPolicy.decision(
            current: ChatDatasourceSnapshot(items: current),
            mapped: ChatDatasourceSnapshot(items: mapped),
            currentLayout: { _ in
                hasCurrentLayout ? currentLayout : nil
            },
            mappedLayout: { _ in
                hasMappedLayout ? mappedLayout : nil
            },
            route: route
        )
    }

    private func route(
        isObserverCurrentRoute: Bool = true,
        isTargetedDiff: Bool = true,
        invalidatesLayout: Bool = false,
        hasBoundaryPlaceholder: Bool = false,
        usesDefaultApplyCategory: Bool = true,
        hasPendingOutgoingAutoScroll: Bool = false,
        hasExplicitSearchOrAnchorMutation: Bool = false
    ) -> ChatObserverModelOnlyAssimilationRoute {
        ChatObserverModelOnlyAssimilationRoute(
            isObserverCurrentRoute: isObserverCurrentRoute,
            isTargetedDiff: isTargetedDiff,
            invalidatesLayout: invalidatesLayout,
            hasBoundaryPlaceholder: hasBoundaryPlaceholder,
            usesDefaultApplyCategory: usesDefaultApplyCategory,
            hasPendingOutgoingAutoScroll: hasPendingOutgoingAutoScroll,
            hasExplicitSearchOrAnchorMutation:
                hasExplicitSearchOrAnchorMutation
        )
    }

    private func nestedForwards(
        text: NSAttributedString
    ) -> [MessageAttachment] {
        let nested = MessageAttachment(
            primary: "nested-forward",
            author: "Nested author",
            jid: "nested@example.com",
            outgoing: false,
            textMessage: text,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarker: NSAttributedString(string: "11:59"),
            subforwards: []
        )
        return [MessageAttachment(
            primary: "root-forward",
            author: "Root author",
            jid: "root@example.com",
            outgoing: false,
            textMessage: NSAttributedString(string: "Root forward"),
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarker: NSAttributedString(string: "12:00"),
            subforwards: [nested]
        )]
    }

    private func datasource(
        primary: String = "incoming",
        archivedId: String? = "archive-incoming",
        outgoing: Bool = false,
        state: MessageStorageItem.MessageSendingState = .deliver,
        isRead: Bool = false
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "group@example.com",
            owner: "owner@example.com",
            outgoing: outgoing,
            sender: Sender(
                id: outgoing ? "owner@example.com" : "member-id",
                displayName: "Sender"
            ),
            messageId: "message-\(primary)",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "Hello")),
            withAuthor: !outgoing,
            withAvatar: !outgoing,
            reservesAvatarSpace: !outgoing,
            error: false,
            errorType: "",
            canPinMessage: true,
            canEditMessage: false,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: outgoing,
            isEdited: false,
            groupchatAuthorRole: "member",
            groupchatAuthorId: outgoing ? "" : "member-id",
            groupchatAuthorNickname: outgoing ? "" : "Member",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: state,
            searchString: nil,
            errorMetadata: nil,
            messageWarningText: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: archivedId,
            queryIds: "query-1",
            isRead: isRead,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: true,
            isFakeMessage: false,
            images: [],
            videos: [],
            locations: [],
            contacts: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: outgoing ? nil : "avatar-v1",
            attributedAuthor: outgoing
                ? nil
                : NSAttributedString(string: "Member")
        )
    }
}
