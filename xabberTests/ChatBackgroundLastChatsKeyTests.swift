import XCTest
import RealmSwift
@testable import xabber

final class ChatBackgroundLastChatsKeyTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let otherOwner = "other-owner@example.com"
    private let jid = "romeo@example.com"

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatBackgroundLastChatsKeyTests-\(name)-\(UUID().uuidString)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testBackgroundUpdatesOnlyCurrentOwnerWhenSameOpponentExistsForTwoOwners() throws {
        try insertLastChat(owner: owner, jid: jid, isPrereaded: true, unread: 3)
        try insertLastChat(owner: otherOwner, jid: jid, isPrereaded: true, unread: 7)
        let controller = makeController(owner: owner, jid: jid)

        controller.handleApplicationDidEnterBackground()

        let current = try storedChat(owner: owner, jid: jid)
        let other = try storedChat(owner: otherOwner, jid: jid)
        XCTAssertFalse(current.isPrereaded)
        XCTAssertTrue(other.isPrereaded)
        XCTAssertEqual(current.unread, 3)
        XCTAssertEqual(other.unread, 7)
    }

    func testBackgroundDoesNotTouchReversedOwnerAndJidRow() throws {
        try insertLastChat(owner: owner, jid: jid, isPrereaded: true)
        try insertLastChat(owner: jid, jid: owner, isPrereaded: true)
        let controller = makeController(owner: owner, jid: jid)

        controller.handleApplicationDidEnterBackground()

        XCTAssertFalse(try storedChat(owner: owner, jid: jid).isPrereaded)
        XCTAssertTrue(try storedChat(owner: jid, jid: owner).isPrereaded)
    }

    func testBackgroundUsesConversationTypeScopedKey() throws {
        try insertLastChat(owner: owner, jid: jid, conversationType: .regular, isPrereaded: true)
        try insertLastChat(owner: owner, jid: jid, conversationType: .omemo, isPrereaded: true)
        let controller = makeController(owner: owner, jid: jid, conversationType: .omemo)

        controller.handleApplicationDidEnterBackground()

        XCTAssertTrue(try storedChat(owner: owner, jid: jid, conversationType: .regular).isPrereaded)
        XCTAssertFalse(try storedChat(owner: owner, jid: jid, conversationType: .omemo).isPrereaded)
    }

    func testMissingLastChatRowIsSafe() {
        let controller = makeController(owner: owner, jid: jid)

        controller.handleApplicationDidEnterBackground()

        XCTAssertTrue(try! WRealm.safe().objects(LastChatsStorageItem.self).isEmpty)
    }

    private func makeController(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        return controller
    }

    @discardableResult
    private func insertLastChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        isPrereaded: Bool,
        unread: Int = 0
    ) throws -> LastChatsStorageItem {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
        chat.isPrereaded = isPrereaded
        chat.unread = unread
        chat.syncUnreadCount = unread

        try realm.write {
            realm.add(chat, update: .modified)
        }

        return try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: chat.primary))
    }

    private func storedChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) throws -> LastChatsStorageItem {
        try XCTUnwrap(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: ChatBackgroundLastChatsKeyPolicy.primaryKey(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            )
        ))
    }
}
