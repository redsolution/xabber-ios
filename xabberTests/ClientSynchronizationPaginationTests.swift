import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class ClientSynchronizationPaginationTests: XCTestCase {
    private var owner: String = ""

    override func setUp() {
        super.setUp()
        owner = "sync-\(UUID().uuidString)@example.com"
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ClientSynchronizationPaginationTests-\(name)")
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
            let account = AccountStorageItem()
            account.jid = owner
            account.username = "sync"
            account.enabled = true
            realm.add(account, update: .modified)
        }
    }

    private func prepareManagedAccount() {
        AccountManager.shared.add(withJid: owner, autoConnect: false)
        AccountManager.shared.find(for: owner)?.blocked.lastUpdate = Date()
    }

    private func makeElement(_ xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return try XCTUnwrap(document.rootElement())
    }

    private func makeIQ(_ xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml))
    }

    private func storedClientSyncValue(_ key: String) -> String? {
        SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: key)
    }

    private func storedClientSyncBool(_ key: String) -> Bool {
        SettingManager.shared.getKeyBool(for: owner, scope: .clientSynchronization, key: key) == true
    }

    private func lastChatCount() throws -> Int {
        try WRealm.safe().objects(LastChatsStorageItem.self).filter("owner == %@", owner).count
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        in requests: () -> [ClientSynchronizationManager.SyncRequestDiagnostics],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try waitUntil("sync request count \(expectedCount)", file: file, line: line) {
            requests().count >= expectedCount
        }
    }

    private func conversationXML(
        jid: String,
        messageId: String,
        archiveId: String,
        stamp: String = "1776840442469439",
        body: String = "Hello"
    ) -> String {
        """
        <conversation jid='\(jid)' type='urn:xabber:chat' stamp='\(stamp)' status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <unread count='0'/>
            <last-message>
              <message from='\(jid)' to='\(owner)' id='\(messageId)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(archiveId)'/>
                <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-03-24T12:34:56Z'/>
                <body>\(body)</body>
              </message>
            </last-message>
          </metadata>
        </conversation>
        """
    }

    private func unreadConversationXML(
        jid: String,
        unread: Int,
        after: String,
        stamp: String = "1776840442469439"
    ) -> String {
        """
        <conversation jid='\(jid)' type='urn:xabber:chat' stamp='\(stamp)' status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <unread count='\(unread)' after='\(after)'/>
          </metadata>
        </conversation>
        """
    }

    private func snapshotIQ(
        id: String,
        stamp: String = "1776840442469439",
        conversations: [String],
        rsmFirst: String? = nil,
        rsmFirstIndex: Int? = nil,
        rsmLast: String? = nil,
        rsmCount: Int? = nil
    ) throws -> XMPPIQ {
        let firstXML: String
        if let rsmFirst {
            let index = rsmFirstIndex.map { " index='\($0)'" } ?? ""
            firstXML = "<first\(index)>\(rsmFirst)</first>"
        } else {
            firstXML = ""
        }
        let lastXML = rsmLast.map { "<last>\($0)</last>" } ?? ""
        let countXML = rsmCount.map { "<count>\($0)</count>" } ?? ""
        return try makeIQ("""
        <iq type='result' id='\(id)'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='\(stamp)'>
            \(conversations.joined(separator: "\n"))
            <set xmlns='http://jabber.org/protocol/rsm'>
              \(firstXML)
              \(lastXML)
              \(countXML)
            </set>
          </query>
        </iq>
        """)
    }

    private func insertSyncedLastChat(jid: String) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.isSynced = true
        LastChatUnreadCounter.refreshTotal(for: chat)
        try realm.write {
            realm.add(chat, update: .modified)
            _ = RegularChatArchiveSyncStateStorageItem.ensure(owner: owner, jid: jid, conversationType: .regular, in: realm)
        }
    }

    func testIncrementalSyncAfterCompletedSnapshotDoesNotHoldBootstrapGate() throws {
        let completedStamp = "1784280770721454"
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: "last_completed_snapshot_stamp",
            value: completedStamp
        )
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: "last_recognized_event_stamp",
            value: completedStamp
        )
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        manager.syncRequestObserver = { requests.append($0) }

        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertEqual(try XCTUnwrap(requests.last).stamp, completedStamp)
        XCTAssertFalse(manager.isBootstrapCriticalSyncInProgress())
    }

    func testInitialSyncWithoutCompletedSnapshotHoldsBootstrapGate() {
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true

        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.isBootstrapCriticalSyncInProgress())
    }

    func testInitialSnapshotRequestsAndAppliesAllThreePagesBeforeCompletion() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        manager.syncRequestObserver = { requests.append($0) }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "page-1",
            conversations: [
                conversationXML(jid: "chat-1@example.com", messageId: "m1", archiveId: "a1"),
                conversationXML(jid: "chat-2@example.com", messageId: "m2", archiveId: "a2")
            ],
            rsmFirst: "cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "cursor-2",
            rsmCount: 5
        )))
        try waitUntil("first page applied") { try self.lastChatCount() == 2 }
        try waitUntil("second page requested") { requests.last?.after == "cursor-2" }
        XCTAssertEqual(requests.last?.after, "cursor-2")
        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)
        XCTAssertTrue(storedClientSyncValue("last_recognized_event_stamp")?.isEmpty ?? true)
        XCTAssertNotEqual(storedClientSyncValue("version"), "1776840442469439")

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "page-2",
            conversations: [
                conversationXML(jid: "chat-3@example.com", messageId: "m3", archiveId: "a3"),
                conversationXML(jid: "chat-4@example.com", messageId: "m4", archiveId: "a4")
            ],
            rsmFirst: "cursor-3",
            rsmFirstIndex: 2,
            rsmLast: "cursor-4",
            rsmCount: 5
        )))
        try waitUntil("second page applied") { try self.lastChatCount() == 4 }
        try waitUntil("third page requested") { requests.last?.after == "cursor-4" }
        XCTAssertEqual(requests.last?.after, "cursor-4")
        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "page-3",
            conversations: [
                conversationXML(jid: "chat-5@example.com", messageId: "m5", archiveId: "a5")
            ],
            rsmFirst: "cursor-5",
            rsmFirstIndex: 4,
            rsmLast: "cursor-5",
            rsmCount: 5
        )))
        try waitUntil("final page applied") {
            try self.lastChatCount() == 5 &&
                self.storedClientSyncValue("last_completed_snapshot_stamp") == "1776840442469439" &&
                self.storedClientSyncValue("last_recognized_event_stamp") == "1776840442469439" &&
                self.storedClientSyncValue("version") == "1776840442469439"
        }
        XCTAssertEqual(storedClientSyncValue("last_recognized_event_stamp"), "1776840442469439")
        XCTAssertEqual(storedClientSyncValue("version"), "1776840442469439")
    }

    func testFreshFullSnapshotContinuationPreservesOmittedStamp() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        manager.syncRequestObserver = { requests.append($0) }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "nostamp-page-1",
            conversations: [
                conversationXML(jid: "nostamp-1@example.com", messageId: "m1", archiveId: "a1")
            ],
            rsmFirst: "nostamp-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "nostamp-cursor-2",
            rsmCount: 2
        )))

        try waitForRequestCount(1, in: { requests })
        XCTAssertNil(requests.last?.stamp)
        XCTAssertEqual(requests.last?.after, "nostamp-cursor-2")
    }

    func testInitialSnapshotAppliesThreeHundredTwoConversationFixtureAcrossAllPages() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        manager.syncRequestObserver = { requests.append($0) }

        let total = 302
        var applied = 0
        var responseId = "bulk-page-1"

        while applied < total {
            let pageStart = applied
            let remaining = total - applied
            let pageCount = min(manager.pageSize, remaining)
            let pageNumber = pageStart / manager.pageSize + 1
            let pageConversations = (0..<pageCount).map { offset in
                let index = pageStart + offset
                return conversationXML(
                    jid: "bulk-\(index)@example.com",
                    messageId: "bulk-m-\(index)",
                    archiveId: "bulk-a-\(index)",
                    stamp: "1776840442469\(String(format: "%03d", index % 1000))"
                )
            }
            let lastCursor = "bulk-cursor-\(min(total - 1, pageStart + pageCount - 1))"

            XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
                id: responseId,
                conversations: pageConversations,
                rsmFirst: "bulk-cursor-\(pageStart)",
                rsmFirstIndex: pageStart,
                rsmLast: lastCursor,
                rsmCount: total
            )))

            applied += pageCount
            try waitUntil("bulk page \(pageNumber) applied") {
                try self.lastChatCount() == applied
            }

            if applied < total {
                try waitForRequestCount(pageNumber, in: { requests })
                let request = try XCTUnwrap(requests.last)
                XCTAssertNil(request.stamp)
                XCTAssertEqual(request.after, lastCursor)
                responseId = request.id
                XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)
            }
        }

        try waitUntil("bulk snapshot complete") {
            try self.lastChatCount() == total &&
                self.storedClientSyncValue("last_completed_snapshot_stamp") == "1776840442469439" &&
                self.storedClientSyncValue("last_recognized_event_stamp") == "1776840442469439"
        }
    }

    func testIncompleteSnapshotRestartRequestsFreshSnapshotWhenNoCompletedSnapshotExists() throws {
        prepareManagedAccount()
        let firstManager = ClientSynchronizationManager(withOwner: owner)
        firstManager.isAvailable = true

        XCTAssertTrue(firstManager.read(withIQ: try snapshotIQ(
            id: "restart-page-1",
            conversations: [
                conversationXML(jid: "restart-1@example.com", messageId: "m1", archiveId: "a1"),
                conversationXML(jid: "restart-2@example.com", messageId: "m2", archiveId: "a2")
            ],
            rsmFirst: "restart-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "restart-cursor-2",
            rsmCount: 4
        )))
        try waitUntil("incomplete first page applied") { try self.lastChatCount() == 2 }
        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)

        let relaunchedManager = ClientSynchronizationManager(withOwner: owner)
        relaunchedManager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        relaunchedManager.syncRequestObserver = { requests.append($0) }

        XCTAssertTrue(relaunchedManager.sync(XMPPStream()))
        XCTAssertNil(requests.last?.stamp)
        XCTAssertNil(requests.last?.after)
    }

    func testTrackedSyncResultWithMalformedSnapshotQueryKeepsIncompleteMarkerAndAllowsSafeRetry() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        manager.syncRequestObserver = { requests.append($0) }

        XCTAssertTrue(manager.sync(XMPPStream()))
        let request = try XCTUnwrap(requests.last)

        XCTAssertTrue(manager.read(withIQ: try makeIQ("""
        <iq type='result' id='\(request.id)'>
          <query xmlns='https://xabber.com/protocol/synchronization'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>302</count>
            </set>
          </query>
        </iq>
        """)))

        XCTAssertTrue(storedClientSyncBool("snapshot_bootstrap_in_progress"))
        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests.last?.stamp)
        XCTAssertNil(requests.last?.after)
        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)
        XCTAssertTrue(storedClientSyncValue("last_recognized_event_stamp")?.isEmpty ?? true)
    }

    func testPostBootstrapWorkRunsOnlyAfterFinalSnapshotPage() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var didRunPostBootstrapWork = false

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "post-bootstrap-page-1",
            conversations: [
                conversationXML(jid: "post-bootstrap-1@example.com", messageId: "pb1", archiveId: "pba1")
            ],
            rsmFirst: "post-bootstrap-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "post-bootstrap-cursor-2",
            rsmCount: 2
        )))
        try waitUntil("post-bootstrap first page applied") { try self.lastChatCount() == 1 }

        XCTAssertTrue(manager.deferPostBootstrapWorkIfNeeded {
            didRunPostBootstrapWork = true
        })
        XCTAssertFalse(didRunPostBootstrapWork)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "post-bootstrap-page-2",
            conversations: [
                conversationXML(jid: "post-bootstrap-2@example.com", messageId: "pb2", archiveId: "pba2")
            ],
            rsmFirst: "post-bootstrap-cursor-2",
            rsmFirstIndex: 1,
            rsmLast: "post-bootstrap-cursor-2",
            rsmCount: 2
        )))

        try waitUntil("post-bootstrap work flushed") {
            didRunPostBootstrapWork
        }
    }

    func testSnapshotRepairIsDeferredUntilFullSnapshotCompletes() throws {
        prepareManagedAccount()
        let jid = "repair@example.com"
        try insertSyncedLastChat(jid: jid)
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var observedRepairs: [MessageArchiveManager.SnapshotRepairTarget] = []
        AccountManager.shared.find(for: owner)?.mam.snapshotRepairEnqueueObserver = { target, _, _ in
            observedRepairs.append(target)
        }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "repair-page-1",
            conversations: [
                unreadConversationXML(jid: jid, unread: 2, after: "after-2")
            ],
            rsmFirst: "repair-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "repair-cursor-1",
            rsmCount: 2
        )))
        try waitUntil("repair first page applied") {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .regular)
            )
            return chat?.syncUnreadCount == 2
        }
        XCTAssertTrue(observedRepairs.isEmpty)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "repair-page-2",
            conversations: [],
            rsmFirst: "repair-cursor-2",
            rsmFirstIndex: 2,
            rsmLast: nil,
            rsmCount: 2
        )))
        try waitUntil("repair target flushed after final page") {
            observedRepairs == [.init(jid: jid, conversationType: .regular)]
        }
    }

    func testDuplicateConversationKeysAcrossPagesAreIdempotentAndPaginationContinues() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "duplicate-page-1",
            conversations: [
                conversationXML(jid: "duplicate@example.com", messageId: "dup-old", archiveId: "dup-a1"),
                conversationXML(jid: "unique-1@example.com", messageId: "u1", archiveId: "u-a1")
            ],
            rsmFirst: "duplicate-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "duplicate-cursor-2",
            rsmCount: 3
        )))
        try waitUntil("duplicate first page applied") { try self.lastChatCount() == 2 }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "duplicate-page-2",
            conversations: [
                conversationXML(jid: "duplicate@example.com", messageId: "dup-new", archiveId: "dup-a2"),
                conversationXML(jid: "unique-2@example.com", messageId: "u2", archiveId: "u-a2")
            ],
            rsmFirst: "duplicate-cursor-3",
            rsmFirstIndex: 2,
            rsmLast: "duplicate-cursor-3",
            rsmCount: 3
        )))
        try waitUntil("duplicate final page applied") {
            try self.lastChatCount() == 3 &&
                self.storedClientSyncValue("last_completed_snapshot_stamp") == "1776840442469439"
        }
    }

    func testRepeatedContinuationCursorDoesNotMarkSnapshotComplete() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        var requests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []
        manager.syncRequestObserver = { requests.append($0) }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "stalled-page-1",
            conversations: [
                conversationXML(jid: "stalled-1@example.com", messageId: "s1", archiveId: "s-a1")
            ],
            rsmFirst: "stalled-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "stalled-cursor-repeat",
            rsmCount: 3
        )))
        try waitUntil("stalled second page requested") { requests.last?.after == "stalled-cursor-repeat" }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "stalled-page-2",
            conversations: [
                conversationXML(jid: "stalled-2@example.com", messageId: "s2", archiveId: "s-a2")
            ],
            rsmFirst: "stalled-cursor-2",
            rsmFirstIndex: 1,
            rsmLast: "stalled-cursor-repeat",
            rsmCount: 3
        )))
        try waitUntil("stalled page applied") { try self.lastChatCount() == 2 }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))

        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)
        XCTAssertTrue(storedClientSyncValue("last_recognized_event_stamp")?.isEmpty ?? true)
        XCTAssertNotEqual(storedClientSyncValue("version"), "1776840442469439")
    }

    func testV3InviteConversationFromSnapshotDoesNotCreateFakeChat() throws {
        prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        let groupchat = "stage@example.com"

        let inviteConversation = """
        <conversation jid='\(groupchat)' type='https://xabber.com/protocol/groups' stamp='1776840442469439' status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <last-message>
              <message from='\(groupchat)/Group' to='\(owner)' id='sync-invite'>
                <invite xmlns='https://xabber.com/protocol/groups' jid='\(groupchat)'/>
              </message>
            </last-message>
          </metadata>
        </conversation>
        """

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: "invite-page",
            conversations: [inviteConversation],
            rsmFirst: "invite-cursor",
            rsmFirstIndex: 0,
            rsmLast: "invite-cursor",
            rsmCount: 1
        )))

        try waitUntil("invite stored") {
            try WRealm.safe()
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner == %@ AND groupchat == %@", self.owner, groupchat)
                .count == 1
        }
        XCTAssertNil(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchat, owner: owner, conversationType: .group)
        ))
    }
}
