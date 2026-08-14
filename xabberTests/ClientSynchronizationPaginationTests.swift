import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

private final class ClientSyncRequestRecorder {
    private let lock = NSLock()
    private var recordedRequests: [ClientSynchronizationManager.SyncRequestDiagnostics] = []

    func record(_ request: ClientSynchronizationManager.SyncRequestDiagnostics) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    var last: ClientSynchronizationManager.SyncRequestDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.last
    }

    func request(at index: Int) -> ClientSynchronizationManager.SyncRequestDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        guard recordedRequests.indices.contains(index) else {
            return nil
        }
        return recordedRequests[index]
    }
}

final class ClientSynchronizationPaginationTests: XCTestCase {
    private var owner: String = ""
    private var previousRealmConfiguration: Realm.Configuration?
    private var managers: [ClientSynchronizationManager] = []

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
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

    override func tearDown() {
        managers.forEach { $0.waitForPendingSnapshotApplies() }
        managers.forEach { manager in
            manager.syncRequestObserver = nil
            manager.beforeApplyingSyncPayload = nil
            manager.initialPresenceSendAttemptObserver = nil
            manager.beforeResettingSyncResult = nil
            manager.beforeResettingSnapshotFailure = nil
            manager.beforeDispatchingSnapshotContinuation = nil
            manager.reset()
        }
        AccountManager.shared.find(for: owner)?.mam.snapshotRepairEnqueueObserver = nil
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        managers.removeAll()
        if let previousRealmConfiguration {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }
        previousRealmConfiguration = nil
        owner = ""
        super.tearDown()
    }

    private func makeManager(
        recording requests: ClientSyncRequestRecorder? = nil
    ) -> ClientSynchronizationManager {
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        if let requests {
            manager.syncRequestObserver = { requests.record($0) }
        }
        managers.append(manager)
        return manager
    }

    private func startTrackedSnapshot(
        with manager: ClientSynchronizationManager,
        recording requests: ClientSyncRequestRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ClientSynchronizationManager.SyncRequestDiagnostics {
        XCTAssertTrue(manager.sync(XMPPStream()), file: file, line: line)
        return try XCTUnwrap(
            requests.request(at: 0),
            "Initial synchronization request was not recorded",
            file: file,
            line: line
        )
    }

    private func waitForRequest(
        at index: Int,
        in requests: ClientSyncRequestRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ClientSynchronizationManager.SyncRequestDiagnostics {
        try waitUntil("sync request at index \(index)", file: file, line: line) {
            requests.count > index
        }
        return try XCTUnwrap(
            requests.request(at: index),
            "Synchronization request at index \(index) was not recorded",
            file: file,
            line: line
        )
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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)

        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertEqual(try XCTUnwrap(requests.last).stamp, completedStamp)
        XCTAssertFalse(manager.isBootstrapCriticalSyncInProgress())
    }

    func testInitialSyncWithoutCompletedSnapshotHoldsBootstrapGate() {
        let manager = makeManager()

        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.isBootstrapCriticalSyncInProgress())
    }

    func testInitialSnapshotRequestsAndAppliesAllThreePagesBeforeCompletion() throws {
        prepareManagedAccount()
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
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
        let secondRequest = try waitForRequest(at: 1, in: requests)
        XCTAssertEqual(secondRequest.after, "cursor-2")
        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)
        XCTAssertTrue(storedClientSyncValue("last_recognized_event_stamp")?.isEmpty ?? true)
        XCTAssertNotEqual(storedClientSyncValue("version"), "1776840442469439")

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: secondRequest.id,
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
        let thirdRequest = try waitForRequest(at: 2, in: requests)
        XCTAssertEqual(thirdRequest.after, "cursor-4")
        XCTAssertTrue(storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: thirdRequest.id,
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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
            conversations: [
                conversationXML(jid: "nostamp-1@example.com", messageId: "m1", archiveId: "a1")
            ],
            rsmFirst: "nostamp-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "nostamp-cursor-2",
            rsmCount: 2
        )))

        let continuationRequest = try waitForRequest(at: 1, in: requests)
        XCTAssertNil(continuationRequest.stamp)
        XCTAssertEqual(continuationRequest.after, "nostamp-cursor-2")
    }

    func testInitialSnapshotAppliesThreeHundredTwoConversationFixtureAcrossAllPages() throws {
        prepareManagedAccount()
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)

        let total = 302
        var applied = 0
        var responseId = try startTrackedSnapshot(with: manager, recording: requests).id

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
                let request = try waitForRequest(at: pageNumber, in: requests)
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
        let firstRequests = ClientSyncRequestRecorder()
        let firstManager = makeManager(recording: firstRequests)
        let firstRequest = try startTrackedSnapshot(with: firstManager, recording: firstRequests)

        XCTAssertTrue(firstManager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
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

        let relaunchedRequests = ClientSyncRequestRecorder()
        let relaunchedManager = makeManager(recording: relaunchedRequests)
        let relaunchedRequest = try startTrackedSnapshot(
            with: relaunchedManager,
            recording: relaunchedRequests
        )

        XCTAssertNil(relaunchedRequest.stamp)
        XCTAssertNil(relaunchedRequest.after)
    }

    func testTrackedSyncResultWithMalformedSnapshotQueryKeepsIncompleteMarkerAndAllowsSafeRetry() throws {
        prepareManagedAccount()
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let request = try startTrackedSnapshot(with: manager, recording: requests)

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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)
        var didRunPostBootstrapWork = false

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
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

        let secondRequest = try waitForRequest(at: 1, in: requests)
        XCTAssertEqual(secondRequest.after, "post-bootstrap-cursor-2")
        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: secondRequest.id,
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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)
        var observedRepairs: [MessageArchiveManager.SnapshotRepairTarget] = []
        AccountManager.shared.find(for: owner)?.mam.snapshotRepairEnqueueObserver = { target, _, _ in
            observedRepairs.append(target)
        }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
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

        let secondRequest = try waitForRequest(at: 1, in: requests)
        XCTAssertEqual(secondRequest.after, "repair-cursor-1")
        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: secondRequest.id,
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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
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

        let secondRequest = try waitForRequest(at: 1, in: requests)
        XCTAssertEqual(secondRequest.after, "duplicate-cursor-2")
        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: secondRequest.id,
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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
            conversations: [
                conversationXML(jid: "stalled-1@example.com", messageId: "s1", archiveId: "s-a1")
            ],
            rsmFirst: "stalled-cursor-1",
            rsmFirstIndex: 0,
            rsmLast: "stalled-cursor-repeat",
            rsmCount: 3
        )))
        let secondRequest = try waitForRequest(at: 1, in: requests)
        XCTAssertEqual(secondRequest.after, "stalled-cursor-repeat")

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: secondRequest.id,
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
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(with: manager, recording: requests)
        let groupchat = "stage@example.com"

        let inviteConversation = """
        <conversation jid='\(groupchat)' type='https://xabber.com/protocol/groups' stamp='1776840442469439' status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <last-message>
              <message type='chat' from='\(groupchat)/Group' to='\(owner)' id='sync-invite'>
                <body>You have been invited to the group chat.</body>
                <invite xmlns='https://xabber.com/protocol/groups' jid='\(groupchat)'/>
              </message>
            </last-message>
          </metadata>
        </conversation>
        """

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
            conversations: [inviteConversation],
            rsmFirst: "invite-cursor",
            rsmFirstIndex: 0,
            rsmLast: "invite-cursor",
            rsmCount: 1
        )))

        try waitUntil("invite stored") {
            try GroupRepository(realm: WRealm.safe()).incomingInvite(
                owner: self.owner,
                groupJID: groupchat
            ) != nil
        }
        XCTAssertNil(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchat, owner: owner, conversationType: .group)
        ))
    }

    func testCanonicalGroupSynchronizationSignalsDistinguishActiveInviteAndDeleted() throws {
        let active = try makeElement("""
        <conversation jid='Stage@Groups.Example.com/Group'
                      type='https://xabber.com/protocol/groups'
                      status='active'/>
        """)
        let invite = try makeElement("""
        <conversation jid='stage@groups.example.com'
                      type='https://xabber.com/protocol/groups'
                      status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <last-message>
              <message type='chat' from='stage@groups.example.com/Group' to='\(owner)'>
                <body>You have been invited to the group chat.</body>
                <invite xmlns='https://xabber.com/protocol/groups'
                        jid='stage@groups.example.com'/>
              </message>
            </last-message>
          </metadata>
        </conversation>
        """)
        let deleted = try makeElement("""
        <conversation jid='stage@groups.example.com'
                      type='https://xabber.com/protocol/groups'
                      status='deleted'/>
        """)

        XCTAssertEqual(
            ClientSynchronizationManager.canonicalGroupSynchronizationSignal(from: active),
            .active(groupJID: "stage@groups.example.com")
        )
        XCTAssertEqual(
            ClientSynchronizationManager.canonicalGroupSynchronizationSignal(from: invite),
            .pendingInvite(groupJID: "stage@groups.example.com")
        )
        XCTAssertEqual(
            ClientSynchronizationManager.canonicalGroupSynchronizationSignal(from: deleted),
            .deleted(groupJID: "stage@groups.example.com")
        )
    }

    func testGenericSynchronizationApplierDoesNotCreateGroupProjectionWithoutBothMembership() throws {
        let realm = try WRealm.safe()
        let conversation = try makeElement("""
        <conversation jid='stage@groups.example.com'
                      type='https://xabber.com/protocol/groups'
                      status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <unread count='4'/>
          </metadata>
        </conversation>
        """)
        var genericCallbacks: [String] = []

        let result = try ClientSyncPageApplier.apply(
            owner: owner,
            realm: realm,
            conversations: [conversation],
            accountCreateDate: nil,
            applyConversationState: { _, _ in
                genericCallbacks.append("metadata")
                return true
            },
            readInvites: { _, _ in
                genericCallbacks.append("invite")
                return false
            },
            readConversation: { _, _, _ in
                genericCallbacks.append("conversation")
                return nil
            },
            readMarkers: { _, _ in genericCallbacks.append("markers") },
            readPresence: { _, _ in genericCallbacks.append("presence") }
        )

        XCTAssertTrue(genericCallbacks.isEmpty)
        XCTAssertEqual(result.summary.skippedConversationCount, 1)
        XCTAssertTrue(realm.objects(LastChatsStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(RosterStorageItem.self).filter("owner == %@", owner).isEmpty)
        XCTAssertTrue(realm.objects(ResourceStorageItem.self).filter("owner == %@", owner).isEmpty)
    }

    func testGenericSynchronizationApplierMayProjectGroupOnlyAfterBothMembership() throws {
        let realm = try WRealm.safe()
        let group = "stage@groups.example.com"
        try GroupRepository(realm: realm).admitSnapshot(
            GroupSnapshot(jid: group),
            membership: .both,
            memberID: "member-self",
            owner: owner,
            groupJID: group
        )
        let conversation = try makeElement("""
        <conversation jid='\(group)'
                      type='https://xabber.com/protocol/groups'
                      status='active'/>
        """)
        var genericCallbacks: [String] = []

        _ = try ClientSyncPageApplier.apply(
            owner: owner,
            realm: realm,
            conversations: [conversation],
            accountCreateDate: nil,
            applyConversationState: { _, _ in
                genericCallbacks.append("metadata")
                return true
            },
            readInvites: { _, _ in false },
            readConversation: { _, _, _ in
                genericCallbacks.append("conversation")
                return nil
            },
            readMarkers: { _, _ in genericCallbacks.append("markers") },
            readPresence: { _, _ in genericCallbacks.append("presence") }
        )

        XCTAssertEqual(
            genericCallbacks,
            ["metadata", "conversation", "markers", "presence"]
        )
    }
}
