import XCTest
import RealmSwift
@testable import xabber

final class ChatViewportReadBoundaryTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatViewportReadBoundaryTests-\(name)-\(UUID().uuidString)"
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

    func testBottommostVisibleIncomingAdvancesBoundary() {
        let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: ["incoming-old", "incoming-new"],
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "outgoing-between", orderIndex: 2, outgoing: true),
                orderedMessage(primary: "incoming-new", orderIndex: 3)
            ],
            currentBoundaryIndex: nil
        )

        XCTAssertEqual(target?.primary, "incoming-new")
        XCTAssertEqual(target?.orderIndex, 3)
    }

    func testVisibleOutgoingDoesNotAdvanceIncomingBoundary() {
        let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: ["incoming-old", "outgoing-new"],
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "outgoing-new", orderIndex: 4, outgoing: true)
            ],
            currentBoundaryIndex: nil
        )

        XCTAssertEqual(target?.primary, "incoming-old")
        XCTAssertEqual(target?.orderIndex, 1)
    }

    func testBackwardScrollingDoesNotRegressBoundary() {
        let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: ["incoming-old"],
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "incoming-current", orderIndex: 5)
            ],
            currentBoundaryIndex: 5
        )

        XCTAssertNil(target)
    }

    func testUnresolvedMarkerTargetIsNoOpUntilLoadedInOrder() {
        let orderedMessages = [
            orderedMessage(primary: "incoming-old", orderIndex: 1),
            orderedMessage(primary: "incoming-new", orderIndex: 2)
        ]

        XCTAssertNil(ChatViewportReadBoundaryPolicy.resolvedDisplayedMarkerTarget(
            primary: "missing",
            orderedMessages: orderedMessages,
            currentBoundaryIndex: nil
        ))

        let target = ChatViewportReadBoundaryPolicy.resolvedDisplayedMarkerTarget(
            primary: "incoming-new",
            orderedMessages: orderedMessages,
            currentBoundaryIndex: nil
        )
        XCTAssertEqual(target?.primary, "incoming-new")
        XCTAssertEqual(target?.orderIndex, 2)
    }

    func testPendingFlushUsesLoadedOrderInsteadOfSentDate() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.account"))
        AccountManager.shared.users.append(account)
        let controller = makeController()
        try seedOutOfOrderDateUnreadChat()
        controller.datasource = [
            makeDatasource(primary: "incoming-old", archivedId: "100", sentDate: Date(timeIntervalSince1970: 300)),
            makeDatasource(primary: "incoming-new", archivedId: "200", sentDate: Date(timeIntervalSince1970: 100))
        ]
        controller.messagesToReadObserver.accept(["incoming-old", "incoming-new"])

        XCTAssertTrue(controller.flushPendingVisibleReadTarget())

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
    }

    func testExplicitMarkAllRemainsSeparateAllowedProducer() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.account"))
        AccountManager.shared.users.append(account)
        try seedUnreadChat()

        let viewportTarget = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: Set<String>(),
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "incoming-last", orderIndex: 2)
            ],
            currentBoundaryIndex: nil
        )
        XCTAssertNil(viewportTarget)

        account.messages.readLastMessage(jid: jid, conversationType: .regular)

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.runtimeUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
    }

    private func orderedMessage(
        primary: String,
        orderIndex: Int,
        outgoing: Bool = false,
        isRead: Bool = false,
        isFakeMessage: Bool = false,
        rowKind: ChatVisiblePositionPolicy.RowKind = .message
    ) -> ChatViewportReadBoundaryPolicy.OrderedMessage {
        ChatViewportReadBoundaryPolicy.OrderedMessage(
            primary: primary,
            orderIndex: orderIndex,
            isOutgoing: outgoing,
            isRead: isRead,
            rowKind: rowKind,
            isFakeMessage: isFakeMessage
        )
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
            messageId: primary,
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

    private func seedUnreadChat() throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = "100"
        chat.syncSnapshotLastArchiveId = "100"
        chat.lastReadId = "100"
        chat.runtimeUnreadCount = 1
        chat.unread = 2

        let old = makeMessage(primary: "incoming-old", archivedId: "100", date: Date(timeIntervalSince1970: 100))
        let last = makeMessage(
            primary: "incoming-last",
            archivedId: "200",
            date: Date(timeIntervalSince1970: 200),
            unreadCounterBucket: .runtime
        )
        chat.lastMessage = last
        chat.lastMessageId = last.messageId
        chat.messageDate = last.sentDate

        try realm.write {
            realm.add([old, last], update: .modified)
            realm.add(chat, update: .modified)
        }
    }

    private func seedOutOfOrderDateUnreadChat() throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = "50"
        chat.syncSnapshotLastArchiveId = "200"
        chat.lastReadId = "50"
        chat.runtimeUnreadCount = 0
        chat.unread = 1

        let old = makeMessage(primary: "incoming-old", archivedId: "100", date: Date(timeIntervalSince1970: 300))
        let newestByOrder = makeMessage(primary: "incoming-new", archivedId: "200", date: Date(timeIntervalSince1970: 100))
        chat.lastMessage = newestByOrder
        chat.lastMessageId = newestByOrder.messageId
        chat.messageDate = newestByOrder.sentDate

        try realm.write {
            realm.add([old, newestByOrder], update: .modified)
            realm.add(chat, update: .modified)
        }
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
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
        message.messageId = primary
        message.archivedId = archivedId
        message.date = date
        message.sentDate = date
        message.outgoing = false
        message.isRead = false
        message.state = .deliver
        message.unreadCounterBucket = unreadCounterBucket
        return message
    }

    private func storedChat() throws -> LastChatsStorageItem {
        try XCTUnwrap(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        ))
    }
}
