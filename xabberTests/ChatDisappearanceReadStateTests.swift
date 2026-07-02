import XCTest
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

    func testNavigationDisappearanceFlushesPendingVisibleTargetWithoutReadingNewest() throws {
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
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.runtimeUnreadCount, 1)
        XCTAssertEqual(chat.unread, 1)
        XCTAssertEqual(chat.lastReadId, "100")
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

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
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
