import XCTest
import UIKit
import RealmSwift
@testable import xabber

final class ChatDisappearanceReadStateTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatDisappearanceReadStateTests-\(name)-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testNavigationDisappearanceDoesNotFlushPendingReadWithoutActivePresentation() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatDisappearanceReadStateTests.account"))
        AccountManager.shared.users.append(account)
        let controller = makeController()
        try seedPartiallyReadChat()
        controller.datasource = [
            makeDatasource(primary: "visible-primary", archivedId: "100", sentDate: Date(timeIntervalSince1970: 100)),
            makeDatasource(primary: "newest-primary", archivedId: "200", sentDate: Date(timeIntervalSince1970: 200))
        ]
        controller.messagesToReadObserver.accept(["visible-primary"])

        controller.runNavigationDisappearanceCleanupIfNeeded()

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 1)
        XCTAssertEqual(chat.runtimeUnreadCount, 1)
        XCTAssertEqual(chat.unread, 2)
        XCTAssertEqual(chat.lastReadId, "50")
        XCTAssertEqual(controller.messagesToReadObserver.value, ["visible-primary"])
    }

    func testBackgroundCleanupDoesNotClearUnreadWhenNoVisibleTargetPending() throws {
        let controller = makeController()
        try seedPartiallyReadChat()

        controller.handleApplicationDidEnterBackground()

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 1)
        XCTAssertEqual(chat.runtimeUnreadCount, 1)
        XCTAssertEqual(chat.unread, 2)
        XCTAssertFalse(chat.isPrereaded)
    }

    @MainActor
    func testNavigationDisappearanceClearsSavedAnchorAtRealLiveBottomBeforeSessionInvalidation() throws {
        let controller = try makePositionedController(isResidentAtLiveTail: true)
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(controller.isNearBottom())
        XCTAssertFalse(try storedChat().lastVisibleMessagePrimary?.isEmpty ?? true)

        controller.runNavigationDisappearanceCleanupIfNeeded()

        let chat = try storedChat()
        XCTAssertNil(chat.lastVisibleMessagePrimary,
                     "Leaving live bottom must not replace it with the viewport's center message")
        XCTAssertNil(chat.lastVisibleMessageArchivedId)
        XCTAssertNil(chat.lastVisibleMessageId)
        XCTAssertTrue(controller.timelineSession?.snapshot.items.isEmpty == true,
                      "Position persistence must complete before normal archive teardown empties the session")
        XCTAssertNil(LastChatsViewController.initialOpenRequest(
            owner: owner, jid: jid, conversationType: .regular,
            explicitOpenMessageRequest: nil, in: try WRealm.safe()
        ), "The unchanged zero-unread chat must reopen at live bottom")
    }

    @MainActor
    func testBottomOfBoundedHistoricalWindowKeepsSavedAnchorOnDisappearance() throws {
        let controller = try makePositionedController(isResidentAtLiveTail: false)
        controller.scrollToBottom(animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(controller.isNearBottom())

        controller.saveCurrentVisibleMessagePositionIfNeeded(reason: .programmaticBottom)
        let historicalAnchor = try XCTUnwrap(try storedChat().lastVisibleMessagePrimary,
                                            "The bottom of a historical window is not the live chat bottom")
        controller.runNavigationDisappearanceCleanupIfNeeded()

        XCTAssertEqual(try storedChat().lastVisibleMessagePrimary, historicalAnchor)
        XCTAssertEqual(LastChatsViewController.initialOpenRequest(
            owner: owner, jid: jid, conversationType: .regular,
            explicitOpenMessageRequest: nil, in: try WRealm.safe()
        )?.anchor.messagePrimary, historicalAnchor)
    }

    @MainActor
    func testNavigationDisappearancePreservesReadingPositionAwayFromLiveBottom() throws {
        let controller = try makePositionedController(isResidentAtLiveTail: true)
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 8), at: .top, animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertFalse(controller.isNearBottom())
        controller.saveCurrentVisibleMessagePositionIfNeeded()
        let readingAnchor = try XCTUnwrap(try storedChat().lastVisibleMessagePrimary)

        controller.runNavigationDisappearanceCleanupIfNeeded()

        XCTAssertEqual(try storedChat().lastVisibleMessagePrimary, readingAnchor)
    }

    @MainActor
    func testNavigationDisappearanceDoesNotSaveRowsFromAnUnfinishedAnchorNavigation() throws {
        let controller = try makePositionedController(isResidentAtLiveTail: true)
        controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 8), at: .top, animated: false
        )
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertFalse(controller.isNearBottom())
        controller.pendingOpenMessageRequest = ChatOpenMessageRequest(
            chatJid: jid, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: "position-30", archivedId: nil,
                          messageId: nil, authorId: nil, bodyFingerprint: nil,
                          sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition
        )

        controller.runNavigationDisappearanceCleanupIfNeeded()

        XCTAssertEqual(try storedChat().lastVisibleMessagePrimary, "position-0",
                       "Teardown must not erase pending-target protection before saving the viewport")
    }

    func testCachedOldLatestMAMRecreatesMissingRegularLastChatsProjectionForListDiscovery() throws {
        let oldLatestDate = Date(timeIntervalSince1970: 1_784_625_681)
        let cached = makeMessage(
            primary: "cached-old-latest",
            archivedId: "1784625681838707",
            messageId: "old-latest-message",
            date: oldLatestDate
        )
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(cached, update: .modified)
        }

        let replay = makeMessage(
            primary: cached.primary,
            archivedId: cached.archivedId,
            messageId: cached.messageId,
            date: oldLatestDate
        )
        replay.queryIds = "archive.engine.replayed-latest"
        replay.shouldPersistArchiveQueryId = true

        _ = replay.save(
            commitTransaction: true,
            silentNotifications: true
        )

        let expectedPrimary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: expectedPrimary
            )
        )
        XCTAssertFalse(chat.isArchived)
        XCTAssertEqual(chat.lastMessage?.primary, cached.primary)
        XCTAssertEqual(chat.messageDate, oldLatestDate)
        XCTAssertNotNil(
            realm.objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@ AND isArchived == false",
                    owner,
                    jid,
                    ClientSynchronizationManager.ConversationType.regular.rawValue
                )
                .first
        )
    }

    func testCachedOldToNewLatestMAMAdvancesRestoredRegularProjectionChronologically() throws {
        let oldDate = Date(timeIntervalSince1970: 1_784_625_681)
        let newestDate = Date(timeIntervalSince1970: 1_784_625_741)
        let cachedOld = makeMessage(
            primary: "cached-page-old",
            archivedId: "1784625681838707",
            messageId: "cached-page-old-message",
            date: oldDate
        )
        let cachedNewest = makeMessage(
            primary: "cached-page-newest",
            archivedId: "1784625741838707",
            messageId: "cached-page-newest-message",
            date: newestDate
        )
        let realm = try WRealm.safe()
        try realm.write {
            realm.add([cachedOld, cachedNewest], update: .modified)
        }

        let replayOld = makeMessage(
            primary: cachedOld.primary,
            archivedId: cachedOld.archivedId,
            messageId: cachedOld.messageId,
            date: oldDate
        )
        replayOld.queryIds = "archive.engine.latest.old"
        replayOld.shouldPersistArchiveQueryId = true
        let replayNewest = makeMessage(
            primary: cachedNewest.primary,
            archivedId: cachedNewest.archivedId,
            messageId: cachedNewest.messageId,
            date: newestDate
        )
        replayNewest.queryIds = "archive.engine.latest.newest"
        replayNewest.shouldPersistArchiveQueryId = true

        _ = replayOld.save(
            commitTransaction: true,
            silentNotifications: true
        )
        _ = replayNewest.save(
            commitTransaction: true,
            silentNotifications: true
        )
        _ = replayOld.save(
            commitTransaction: true,
            silentNotifications: true
        )

        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            )
        )
        XCTAssertEqual(chat.lastMessage?.primary, cachedNewest.primary)
        XCTAssertEqual(chat.lastMessageId, cachedNewest.messageId)
        XCTAssertEqual(chat.messageDate, newestDate)
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        return controller
    }

    @MainActor
    private func makePositionedController(isResidentAtLiveTail: Bool) throws -> ChatViewController {
        let realm = try WRealm.safe()
        let messages = (0..<40).map { index in
            let message = makeMessage(
                primary: "position-\(index)", archivedId: "archive-\(index)",
                messageId: "message-position-\(index)",
                date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
            )
            message.isRead = true
            message.state = .read
            return message
        }
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.lastMessage = messages.last
        chat.lastMessageId = try XCTUnwrap(messages.last).messageId
        chat.messageDate = try XCTUnwrap(messages.last).sentDate
        chat.syncSnapshotLastArchiveId = "archive-39"
        chat.lastVisibleMessagePrimary = "position-0"
        chat.lastVisibleMessageArchivedId = "archive-0"
        chat.lastVisibleMessageId = "message-position-0"
        chat.lastVisibleMessageDate = messages[0].sentDate
        chat.lastVisiblePositionSavedAtLastMessageId = chat.lastMessageId
        chat.lastVisiblePositionSavedAtSnapshotLastArchiveId = chat.syncSnapshotLastArchiveId
        try realm.write {
            realm.add(messages, update: .modified)
            realm.add(chat, update: .modified)
        }

        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let key = ChatTimelineConversationKey(owner: owner, jid: jid, conversationType: .regular)
        let session = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: owner, jid: jid, conversationType: .regular),
            pageSize: 40, conversationKey: key, observesStoreImmediately: false
        )
        controller.timelineSession = session
        _ = session.commit(ChatTimelineSnapshot(
            items: messages.map { $0.freeze() },
            state: ChatVirtualTimelineState(
                conversationKey: key,
                segments: isResidentAtLiveTail ? [.liveTail] : [.unknownNewer],
                oldest: nil, newest: nil,
                residentPrimaryKeys: messages.map(\.primary),
                residentArchivedIds: messages.map(\.archivedId),
                isResidentAtLiveTail: isResidentAtLiveTail
            ),
            anchorRestore: nil
        ))
        controller.showSkeletonObserver.accept(false)
        controller.applyChatDatasource(
            messages.map { makeDatasource(primary: $0.primary, archivedId: $0.archivedId, sentDate: $0.sentDate) },
            mode: .fullReload(), animated: false, invalidateLayout: true,
            suppressDefaultBottomScroll: true, presentationOwner: .archiveEngine
        )
        var didPrepareLayouts = false
        controller.prepareAndApplyCurrentDatasourceLayouts { didPrepareLayouts = true }
        let deadline = Date().addingTimeInterval(3)
        while !didPrepareLayouts, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(didPrepareLayouts)
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertGreaterThan(controller.messagesCollectionView.contentSize.height,
                             controller.messagesCollectionView.bounds.height)
        return controller
    }

    private func seedPartiallyReadChat() throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = "50"
        chat.syncSnapshotLastArchiveId = "100"
        chat.lastReadId = "50"
        chat.runtimeUnreadCount = 1
        chat.unread = 2

        let visible = makeMessage(
            primary: "visible-primary",
            archivedId: "100",
            messageId: "message-visible",
            date: Date(timeIntervalSince1970: 100)
        )
        let newest = makeMessage(
            primary: "newest-primary",
            archivedId: "200",
            messageId: "message-newest",
            date: Date(timeIntervalSince1970: 200),
            unreadCounterBucket: .runtime
        )
        chat.lastMessage = newest
        chat.lastMessageId = newest.messageId
        chat.messageDate = newest.sentDate

        try realm.write {
            realm.add([visible, newest], update: .modified)
            realm.add(chat, update: .modified)
        }
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        messageId: String,
        date: Date,
        unreadCounterBucket: MessageStorageItem.UnreadCounterBucket = .none
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = .regular
        message.body = "hello"
        message.legacyBody = "hello"
        message.displayAs = .text
        message.messageId = messageId
        message.archivedId = archivedId
        message.date = date
        message.sentDate = date
        message.outgoing = false
        message.isRead = false
        message.state = .deliver
        message.unreadCounterBucket = unreadCounterBucket
        return message
    }

    private func makeDatasource(
        primary: String,
        archivedId: String,
        sentDate: Date
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: jid),
            messageId: "message-\(primary)",
            sentDate: sentDate,
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "Hello")),
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
            state: .deliver,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: archivedId,
            queryIds: nil,
            isRead: false,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }

    private func storedChat() throws -> LastChatsStorageItem {
        try XCTUnwrap(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        ))
    }
}
