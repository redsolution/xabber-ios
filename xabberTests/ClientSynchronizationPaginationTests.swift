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
            manager.beforeCommittingSyncPage = nil
            manager.initialPresenceSendAttemptObserver = nil
            manager.beforeResettingSyncResult = nil
            manager.beforeResettingSnapshotFailure = nil
            manager.beforeDispatchingSnapshotContinuation = nil
            manager.reset()
        }
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

    private func groupListConversationXML(
        jid: String,
        unread: Int = 0,
        stamp: String = "1776840442469439"
    ) -> String {
        """
        <conversation jid='\(jid)'
                      type='https://xabber.com/protocol/groups'
                      stamp='\(stamp)'
                      status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <unread count='\(unread)'/>
          </metadata>
        </conversation>
        """
    }

    private var timelineConversationTypes: [ClientSynchronizationManager.ConversationType] {
        [
            .regular,
            .group,
            .channel,
            .omemo,
            .omemo1,
            .axolotl,
            .saved,
        ]
    }

    private func listOnlyConversationXML(
        jid: String,
        type: ClientSynchronizationManager.ConversationType,
        index: Int,
        stamp: String = "1776840442469439"
    ) -> String {
        let archiveID = 9_000_000 + index
        let status = index.isMultiple(of: 2) ? "active" : "archived"
        let archiveOwner = type == .group ? jid : owner
        return """
        <conversation jid='\(jid)'
                      type='\(type.rawValue)'
                      stamp='\(stamp)'
                      status='\(status)'
                      pinned='\(index + 1)'
                      mute='1893456000'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <unread count='\(index + 1)' after='\(archiveID - 1)'/>
            <displayed id='\(archiveID - 2)'/>
            <delivered id='\(archiveID - 3)'/>
            <last-message>
              <message from='\(jid)' to='\(owner)' id='list-message-\(index)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(archiveOwner)' id='\(archiveID)'/>
                <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-03-24T12:34:56Z'/>
                <body>Preview \(index)</body>
              </message>
            </last-message>
          </metadata>
          <presence from='\(jid)' type='subscribe'/>
        </conversation>
        """
    }

    private func seedRosterPresenceAndAvatar(
        jid: String,
        avatarURL: String
    ) throws -> String {
        let realm = try WRealm.safe()
        let rosterPrimary = RosterStorageItem.genPrimary(
            jid: jid,
            owner: owner
        )
        try realm.write {
            let roster = RosterStorageItem()
            roster.primary = rosterPrimary
            roster.owner = owner
            roster.jid = jid
            roster.username = "Egor Merkushkin"
            roster.subscribtion = .both
            roster.avatarMinUrl = avatarURL
            realm.add(roster, update: .modified)

            let resource = ResourceStorageItem()
            resource.primary = ResourceStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                resource: "xabber-web"
            )
            resource.owner = owner
            resource.jid = jid
            resource.resource = "xabber-web"
            resource.priority = 67
            resource.timestamp = Date(timeIntervalSince1970: 1_787_651_471)
            resource.status = .online
            resource.entity = .contact
            realm.add(resource, update: .modified)
        }
        return rosterPrimary
    }

    private func cachedRegularArchiveMessage(
        jid: String,
        primary: String,
        messageId: String,
        archivedId: String,
        date: Date
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = .regular
        message.body = "Cached archive message"
        message.legacyBody = message.body
        message.displayAs = .text
        message.messageId = messageId
        message.archivedId = archivedId
        message.date = date
        message.sentDate = date
        message.outgoing = false
        message.isRead = true
        message.state = .deliver
        return message
    }

    private func applyRegularListOnlyPush(
        manager: ClientSynchronizationManager,
        jid: String,
        id: String
    ) throws {
        let push = try makeIQ("""
        <iq type='set' id='\(id)'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1787651471639186'>
            \(listOnlyConversationXML(
                jid: jid,
                type: .regular,
                index: 0,
                stamp: "1784625681843225"
            ))
          </synchronization>
        </iq>
        """)
        XCTAssertTrue(manager.read(withIQ: push))
    }

    private func assertListOnlyTimelineProjection(
        expectedUnreadOffset: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let realm = try WRealm.safe()
        let chats = realm.objects(LastChatsStorageItem.self)
            .filter("owner == %@", owner)
        let previewDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-03-24T12:34:56Z"),
            file: file,
            line: line
        )
        XCTAssertEqual(chats.count, timelineConversationTypes.count, file: file, line: line)
        XCTAssertEqual(
            Set(chats.map(\.conversationType_)),
            Set(timelineConversationTypes.map(\.rawValue)),
            file: file,
            line: line
        )
        for (index, type) in timelineConversationTypes.enumerated() {
            let jid = type == .saved
                ? "favorites.example.com"
                : "list-\(index)@example.com"
            let chat = try XCTUnwrap(
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: type
                    )
                ),
                file: file,
                line: line
            )
            XCTAssertEqual(chat.syncUnreadCount, index + expectedUnreadOffset, file: file, line: line)
            XCTAssertEqual(chat.unread, index + expectedUnreadOffset, file: file, line: line)
            XCTAssertEqual(chat.pinnedPosition, Double(index + 1), file: file, line: line)
            XCTAssertTrue(chat.isPinned, file: file, line: line)
            XCTAssertEqual(chat.muteExpired, 1_893_456_000, file: file, line: line)
            XCTAssertEqual(chat.lastMessageId, "list-message-\(index)", file: file, line: line)
            XCTAssertEqual(
                chat.messageDate.timeIntervalSince1970,
                previewDate.timeIntervalSince1970,
                accuracy: 0.001,
                file: file,
                line: line
            )
            XCTAssertEqual(chat.displayedId, String(8_999_998 + index), file: file, line: line)
            XCTAssertEqual(chat.deliveredId, String(8_999_997 + index), file: file, line: line)
            XCTAssertEqual(chat.syncUnreadAfterId, String(8_999_999 + index), file: file, line: line)
            XCTAssertEqual(chat.syncSnapshotLastArchiveId, String(9_000_000 + index), file: file, line: line)
            XCTAssertEqual(chat.isArchived, !index.isMultiple(of: 2), file: file, line: line)
            XCTAssertNil(chat.lastMessage, file: file, line: line)
            XCTAssertNil(chat.rosterItem, file: file, line: line)
            let synchronizedPreview = try XCTUnwrap(
                LastChatListSyncPreviewStore.shared.projection(
                    owner: owner,
                    conversationPrimary: chat.primary,
                    expectedLastMessageID: chat.lastMessageId
                ),
                file: file,
                line: line
            )
            XCTAssertEqual(
                synchronizedPreview.text,
                "Preview \(index)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self).filter("owner == %@", owner).count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            realm.objects(RosterStorageItem.self).filter("owner == %@", owner).count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            realm.objects(ResourceStorageItem.self).filter("owner == %@", owner).count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            realm.objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            realm.objects(RegularChatArchiveSyncStateStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            realm.objects(GroupSelfMembershipStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            realm.objects(GroupSnapshotStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0,
            file: file,
            line: line
        )
        let account = try XCTUnwrap(
            AccountManager.shared.find(for: owner),
            file: file,
            line: line
        )
        let queuedItems = account.messages.performMessageQueueSync {
            account.messages.queuedMessages
        }
        XCTAssertTrue(queuedItems.isEmpty, file: file, line: line)
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

    func testIncrementalSyncAfterCompletedSnapshotIsNotInitialChatListSynchronization() throws {
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
        XCTAssertFalse(manager.isInitialChatListSynchronizationInProgress())
        XCTAssertFalse(manager.isInitialListSynchronizationTrafficGateActive())
    }

    func testInitialSyncWithoutCompletedSnapshotMarksChatListSynchronization() {
        let manager = makeManager()

        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.isInitialChatListSynchronizationInProgress())
        XCTAssertTrue(manager.isInitialListSynchronizationTrafficGateActive())

        manager.reset()

        XCTAssertFalse(
            manager.isInitialListSynchronizationTrafficGateActive(),
            "A failed/reset initial request must not strand auxiliary work"
        )
    }

    func testFreshSnapshotUsesTwentyThenContinuationUsesSixtyAndTrackedMaximumForFinality() throws {
        prepareManagedAccount()
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(
            with: manager,
            recording: requests
        )
        XCTAssertNil(firstRequest.stamp)
        XCTAssertNil(firstRequest.after)
        XCTAssertEqual(firstRequest.max, 20)

        let firstPage = (0..<20).map { index in
            conversationXML(
                jid: "viewport-\(index)@example.com",
                messageId: "viewport-message-\(index)",
                archiveId: "viewport-archive-\(index)"
            )
        }
        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
            conversations: firstPage,
            rsmFirst: "viewport-cursor-0",
            rsmFirstIndex: 0,
            rsmLast: "viewport-cursor-19"
        )))

        try waitUntil("viewport page applied") {
            try self.lastChatCount() == 20
        }
        let continuation = try waitForRequest(at: 1, in: requests)
        XCTAssertEqual(continuation.after, "viewport-cursor-19")
        XCTAssertEqual(continuation.max, 60)

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: continuation.id,
            conversations: [
                conversationXML(
                    jid: "viewport-tail@example.com",
                    messageId: "viewport-tail-message",
                    archiveId: "viewport-tail-archive"
                )
            ],
            rsmFirst: "viewport-cursor-20",
            rsmFirstIndex: 20,
            rsmLast: "viewport-cursor-20"
        )))

        try waitUntil("short continuation completes snapshot") {
            try self.lastChatCount() == 21 &&
                self.storedClientSyncValue("last_completed_snapshot_stamp") == "1776840442469439"
        }
        XCTAssertEqual(requests.count, 2)
    }

    func testIncrementalSyncKeepsSixtyItemPageSize() throws {
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
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.stamp, completedStamp)
        XCTAssertNil(request.after)
        XCTAssertEqual(request.max, 60)
    }

    func testColdRelaunchRecoversMissingListPreviewWithFreshTwentyItemPage() throws {
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
        let realm = try WRealm.safe()
        try realm.write {
            let chat = LastChatsStorageItem()
            chat.jid = "missing-preview@example.com"
            chat.conversationType = .regular
            chat.setPrimary(withOwner: owner)
            chat.lastMessageId = "missing-preview-message"
            realm.add(chat)
        }
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projectionCount(for: owner),
            0
        )

        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)

        XCTAssertTrue(manager.sync(XMPPStream()))
        let request = try XCTUnwrap(requests.last)
        XCTAssertNil(request.stamp)
        XCTAssertNil(request.after)
        XCTAssertEqual(request.max, 20)
    }

    func testColdRelaunchRecoveryChecksEveryRowWhenOneProjectionAlreadyExists() throws {
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
        let projectedJID = "projected-preview@example.com"
        let projectedMessageID = "projected-preview-message"
        let missingJID = "still-missing-preview@example.com"
        let realm = try WRealm.safe()
        try realm.write {
            [
                (projectedJID, projectedMessageID),
                (missingJID, "still-missing-preview-message")
            ].forEach { jid, messageID in
                let chat = LastChatsStorageItem()
                chat.jid = jid
                chat.conversationType = .regular
                chat.setPrimary(withOwner: owner)
                chat.lastMessageId = messageID
                realm.add(chat)
            }
        }
        LastChatListSyncPreviewStore.shared.apply(
            [
                .upsert(LastChatListSyncPreviewProjection(
                    owner: owner,
                    conversationPrimary: LastChatsStorageItem.genPrimary(
                        jid: projectedJID,
                        owner: owner,
                        conversationType: .regular
                    ),
                    lastMessageID: projectedMessageID,
                    text: "Already projected"
                ))
            ],
            for: owner
        )
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projectionCount(for: owner),
            1
        )

        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)

        XCTAssertTrue(manager.sync(XMPPStream()))
        let request = try XCTUnwrap(requests.last)
        XCTAssertNil(request.stamp)
        XCTAssertNil(request.after)
        XCTAssertEqual(request.max, 20)
    }

    func testInterruptedFreshPreviewRecoveryDoesNotResumeFromOldCompletedStamp() throws {
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
        let recoveredJID = "interrupted-recovered@example.com"
        let missingJID = "interrupted-missing@example.com"
        let realm = try WRealm.safe()
        try realm.write {
            [recoveredJID, missingJID].forEach { jid in
                let chat = LastChatsStorageItem()
                chat.jid = jid
                chat.conversationType = .regular
                chat.setPrimary(withOwner: owner)
                chat.lastMessageId = "message-\(jid)"
                realm.add(chat)
            }
        }

        let firstRequests = ClientSyncRequestRecorder()
        let firstManager = makeManager(recording: firstRequests)
        XCTAssertTrue(firstManager.sync(XMPPStream()))
        let firstRequest = try XCTUnwrap(firstRequests.last)
        XCTAssertNil(firstRequest.stamp)
        XCTAssertTrue(firstManager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
            conversations: [
                conversationXML(
                    jid: recoveredJID,
                    messageId: "message-\(recoveredJID)",
                    archiveId: "interrupted-archive-1"
                )
            ],
            rsmFirst: "interrupted-cursor-0",
            rsmFirstIndex: 0,
            rsmLast: "interrupted-cursor-1",
            rsmCount: 2
        )))
        try waitUntil("partial preview recovery applied") {
            LastChatListSyncPreviewStore.shared.projection(
                owner: self.owner,
                conversationPrimary: LastChatsStorageItem.genPrimary(
                    jid: recoveredJID,
                    owner: self.owner,
                    conversationType: .regular
                ),
                expectedLastMessageID: "message-\(recoveredJID)"
            ) != nil
        }
        XCTAssertTrue(storedClientSyncBool("snapshot_bootstrap_in_progress"))

        let relaunchedRequests = ClientSyncRequestRecorder()
        let relaunchedManager = makeManager(recording: relaunchedRequests)
        XCTAssertTrue(relaunchedManager.sync(XMPPStream()))
        let relaunchedRequest = try XCTUnwrap(relaunchedRequests.last)
        XCTAssertNil(relaunchedRequest.stamp)
        XCTAssertNil(relaunchedRequest.after)
        XCTAssertEqual(relaunchedRequest.max, 20)
    }

    func testListOnlyPushPreservesMaterializedLinkWithMatchingArchiveIdentity() throws {
        let jid = "materialized-preview@example.com"
        let messagePrimary = "materialized-preview-primary"
        let sharedArchiveID = "1784280770721455"
        let realm = try WRealm.safe()
        try realm.write {
            let message = MessageStorageItem()
            message.primary = messagePrimary
            message.owner = owner
            message.opponent = jid
            message.conversationType = .regular
            message.messageId = "materialized-message"
            message.archivedId = sharedArchiveID
            message.body = "Already materialized preview"
            message.date = Date(timeIntervalSince1970: 100)
            realm.add(message)

            let chat = LastChatsStorageItem()
            chat.jid = jid
            chat.conversationType = .regular
            chat.setPrimary(withOwner: owner)
            chat.lastMessageId = message.messageId
            chat.lastMessage = message
            chat.messageDate = message.date
            realm.add(chat)
        }

        let manager = makeManager()
        let push = try makeIQ("""
        <iq type='set' id='preserve-materialized-preview'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1784280770721455'>
            \(conversationXML(
                jid: jid,
                messageId: sharedArchiveID,
                archiveId: sharedArchiveID,
                body: "Same archived message from synchronization"
            ))
          </synchronization>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: push))

        let stored = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            )
        )
        XCTAssertEqual(stored.lastMessageId, sharedArchiveID)
        XCTAssertEqual(stored.lastMessage?.primary, messagePrimary)
    }

    func testListOnlySyncLinksRosterStateThatPredatesNewRegularLastChatsProjection() throws {
        let jid = "egor.merkushkin@example.com"
        let avatarURL = "https://gallery.example.com/egor/64_avatar.webp"
        let rosterPrimary = try seedRosterPresenceAndAvatar(
            jid: jid,
            avatarURL: avatarURL
        )
        let manager = makeManager()

        try applyRegularListOnlyPush(
            manager: manager,
            jid: jid,
            id: "list-only-existing-roster"
        )

        let realm = try WRealm.safe()
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
        XCTAssertEqual(chat.rosterItem?.primary, rosterPrimary)
        XCTAssertEqual(chat.rosterItem?.getPrimaryResource()?.status, .online)
        XCTAssertEqual(chat.rosterItem?.avatarMinUrl, avatarURL)
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
    }

    func testListOnlySyncLinksPredatingRosterStateForEveryEncryptedDirectConversationType() throws {
        let encryptedTypes: [ClientSynchronizationManager.ConversationType] = [
            .omemo,
            .omemo1,
            .axolotl,
        ]
        var rosterPrimaryByType: [String: String] = [:]
        let conversations = try encryptedTypes.enumerated().map { index, type in
            let jid = "encrypted-\(index)@example.com"
            rosterPrimaryByType[type.rawValue] = try seedRosterPresenceAndAvatar(
                jid: jid,
                avatarURL: "https://gallery.example.com/encrypted-\(index)/64_avatar.webp"
            )
            return listOnlyConversationXML(
                jid: jid,
                type: type,
                index: (index + 1) * 2,
                stamp: "1784625681843225"
            )
        }
        let manager = makeManager()
        let push = try makeIQ("""
        <iq type='set' id='list-only-encrypted-existing-roster'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1787651471639186'>
            \(conversations.joined(separator: "\n"))
          </synchronization>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: push))

        let realm = try WRealm.safe()
        for (index, type) in encryptedTypes.enumerated() {
            let jid = "encrypted-\(index)@example.com"
            let chat = try XCTUnwrap(
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: type
                    )
                )
            )
            XCTAssertEqual(
                chat.rosterItem?.primary,
                rosterPrimaryByType[type.rawValue]
            )
            XCTAssertEqual(chat.rosterItem?.getPrimaryResource()?.status, .online)
            XCTAssertEqual(
                chat.rosterItem?.avatarMinUrl,
                "https://gallery.example.com/encrypted-\(index)/64_avatar.webp"
            )
        }
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
    }

    @MainActor
    func testListOnlySyncProjectsOnlinePresenceAndXEP0084AvatarBeforeChatOpen() throws {
        let previousLockedConversationType =
            CommonConfigManager.shared.config.locked_conversation_type
        CommonConfigManager.shared.config.locked_conversation_type =
            ClientSynchronizationManager.ConversationType.regular.rawValue
        defer {
            CommonConfigManager.shared.config.locked_conversation_type =
                previousLockedConversationType
        }

        let jid = "online-before-open@example.com"
        let avatarURL = "https://gallery.example.com/online/64_avatar.webp"
        _ = try seedRosterPresenceAndAvatar(
            jid: jid,
            avatarURL: avatarURL
        )
        let manager = makeManager()
        try applyRegularListOnlyPush(
            manager: manager,
            jid: jid,
            id: "list-only-presentation-before-open"
        )

        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.enabledAccounts.accept([owner])
        controller.showSkeleton.accept(false)
        controller.updateDatasource(.chats)
        controller.runDatasetUpdateTask()

        try waitUntil("Last Chats row mapped before opening chat") {
            controller.datasource.contains { $0.jid == jid }
        }
        let row = try XCTUnwrap(
            controller.datasource.first { $0.jid == jid }
        )
        XCTAssertEqual(row.status, .online)
        XCTAssertEqual(row.avatarUrl, avatarURL)
    }

    func testInitialSnapshotProjectsEveryTimelineConversationTypeAsListOnly() throws {
        prepareManagedAccount()
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let request = try startTrackedSnapshot(with: manager, recording: requests)
        let conversations = timelineConversationTypes.enumerated().map { index, type in
            listOnlyConversationXML(
                jid: type == .saved
                    ? "favorites.example.com"
                    : "list-\(index)@example.com",
                type: type,
                index: index
            )
        }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: request.id,
            conversations: conversations,
            rsmFirst: "list-only-first",
            rsmFirstIndex: 0,
            rsmLast: "list-only-last",
            rsmCount: conversations.count
        )))

        try waitUntil("seven list-only timeline projections") {
            try self.lastChatCount() == self.timelineConversationTypes.count
        }
        manager.waitForPendingSnapshotApplies()
        try assertListOnlyTimelineProjection()
    }

    func testIncrementalSyncUpdatesEveryTimelineConversationTypeAsListOnly() throws {
        prepareManagedAccount()
        let realm = try WRealm.safe()
        try realm.write {
            for (index, type) in timelineConversationTypes.enumerated() {
                let item = LastChatsStorageItem()
                item.owner = owner
                item.jid = type == .saved
                    ? "favorites.example.com"
                    : "list-\(index)@example.com"
                item.conversationType = type
                item.setPrimary(withOwner: owner)
                realm.add(item, update: .modified)
            }
        }
        let manager = makeManager()
        let conversations = timelineConversationTypes.enumerated().map { index, type in
            listOnlyConversationXML(
                jid: type == .saved
                    ? "favorites.example.com"
                    : "list-\(index)@example.com",
                type: type,
                index: index,
                stamp: "1776840442469440"
            )
        }
        let push = try makeIQ("""
        <iq type='set' id='incremental-list-only'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1776840442469440'>
            \(conversations.joined(separator: "\n"))
          </synchronization>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: push))
        try assertListOnlyTimelineProjection()
    }

    func testListOnlyPreviewProjectionSurvivesSnapshotPaginationWithoutTimelinePersistence() throws {
        prepareManagedAccount()
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let firstRequest = try startTrackedSnapshot(
            with: manager,
            recording: requests
        )
        let firstJID = "preview-page-1@example.com"
        let secondJID = "preview-page-2@example.com"

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: firstRequest.id,
            conversations: [
                conversationXML(
                    jid: firstJID,
                    messageId: "preview-message-1",
                    archiveId: "9100001",
                    body: "First page preview"
                )
            ],
            rsmFirst: "preview-cursor-0",
            rsmFirstIndex: 0,
            rsmLast: "preview-cursor-1",
            rsmCount: 2
        )))

        try waitUntil("first preview page applied") {
            try self.lastChatCount() == 1
        }
        let secondRequest = try waitForRequest(at: 1, in: requests)
        let firstPrimary = LastChatsStorageItem.genPrimary(
            jid: firstJID,
            owner: owner,
            conversationType: .regular
        )
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: firstPrimary,
                expectedLastMessageID: "preview-message-1"
            )?.text,
            "First page preview"
        )

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: secondRequest.id,
            conversations: [
                conversationXML(
                    jid: secondJID,
                    messageId: "preview-message-2",
                    archiveId: "9100002",
                    body: "Second page preview"
                )
            ],
            rsmFirst: "preview-cursor-1",
            rsmFirstIndex: 1,
            rsmLast: "preview-cursor-2",
            rsmCount: 2
        )))

        try waitUntil("second preview page applied") {
            try self.lastChatCount() == 2
        }
        manager.waitForPendingSnapshotApplies()
        let secondPrimary = LastChatsStorageItem.genPrimary(
            jid: secondJID,
            owner: owner,
            conversationType: .regular
        )
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: firstPrimary,
                expectedLastMessageID: "preview-message-1"
            )?.text,
            "First page preview"
        )
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: secondPrimary,
                expectedLastMessageID: "preview-message-2"
            )?.text,
            "Second page preview"
        )

        let realm = try WRealm.safe()
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(XabberRealmSchema.current, 19)
    }

    func testListOnlyPreviewParserUsesSafeAttachmentAndSystemFallbacks() throws {
        let attachmentMessage = try makeElement("""
        <message id='sync-file'>
          <reference xmlns='urn:xmpp:reference:0' type='data'>
            <file-sharing xmlns='urn:xmpp:sfs:0'/>
          </reference>
        </message>
        """)
        let attachment = try XCTUnwrap(
            LastChatListSyncPreviewParser.projection(
                owner: owner,
                conversationPrimary: "file-primary",
                lastMessageID: "sync-file",
                messageElement: attachmentMessage
            )
        )
        XCTAssertEqual(
            attachment.text,
            "File".localizeString(id: "chat_message_file", arguments: [])
        )
        XCTAssertTrue(attachment.isAttachment)
        XCTAssertFalse(attachment.isSystemMessage)

        let systemMessage = try makeElement("""
        <message id='sync-system'>
          <event xmlns='https://xabber.com/protocol/groups'/>
        </message>
        """)
        let system = try XCTUnwrap(
            LastChatListSyncPreviewParser.projection(
                owner: owner,
                conversationPrimary: "system-primary",
                lastMessageID: "sync-system",
                messageElement: systemMessage
            )
        )
        XCTAssertEqual(system.text, "System message")
        XCTAssertFalse(system.isAttachment)
        XCTAssertTrue(system.isSystemMessage)
    }

    func testOMEMOSyncPreviewKeepsServerFallbackWhenDecryptedPayloadContainsOnlyAttachment() throws {
        let manager = OmemoManager(withOwner: owner)
        let query = try makeElement("""
        <query xmlns='https://xabber.com/protocol/synchronization'>
          <conversation jid='encrypted@example.com' type='urn:xmpp:omemo:2'>
            <metadata node='https://xabber.com/protocol/synchronization'>
              <last-message>
                <message from='encrypted@example.com' to='\(owner)' id='encrypted-file'>
                  <body>Encrypted attachment</body>
                  <encrypted xmlns='urn:xmpp:omemo:2'>
                    <header sid='42'/>
                  </encrypted>
                </message>
              </last-message>
            </metadata>
          </conversation>
        </query>
        """)
        let decryptedEnvelope = try makeElement("""
        <envelope xmlns='urn:xmpp:sce:1'>
          <content>
            <reference xmlns='urn:xmpp:reference:0' type='data'>
              <file-sharing xmlns='urn:xmpp:sfs:0'/>
            </reference>
          </content>
        </envelope>
        """)

        let modified = manager.modifySyncQuery(
            query,
            decryptMessage: { _ in decryptedEnvelope }
        )

        let message = try XCTUnwrap(
            modified.element(forName: "conversation")?
                .element(forName: "metadata")?
                .element(forName: "last-message")?
                .element(forName: "message")
        )
        XCTAssertEqual(message.element(forName: "body")?.stringValue, "Encrypted attachment")
        XCTAssertNil(
            message.elements(forName: "body").first {
                $0.stringValue == "Failed to decrypt"
            }
        )
        XCTAssertNotNil(
            message.element(forName: "reference", xmlns: "urn:xmpp:reference:0")
        )
        XCTAssertEqual(
            message.element(forName: "omemo-result__system")?
                .attributeBoolValue(forName: "result"),
            true
        )
        XCTAssertEqual(
            try WRealm.safe().objects(MessageStorageItem.self)
                .filter("owner == %@", owner).count,
            0
        )
        XCTAssertEqual(
            try WRealm.safe().objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner).count,
            0
        )
    }

    func testOMEMOSyncPreviewUsesAttachmentFallbackAfterBodylessDecryptSuccess() throws {
        let manager = OmemoManager(withOwner: owner)
        let query = try makeElement("""
        <query xmlns='https://xabber.com/protocol/synchronization'>
          <conversation jid='encrypted@example.com' type='urn:xmpp:omemo:2'>
            <metadata node='https://xabber.com/protocol/synchronization'>
              <last-message>
                <message from='encrypted@example.com' to='\(owner)' id='encrypted-file'>
                  <encrypted xmlns='urn:xmpp:omemo:2'>
                    <header sid='42'/>
                  </encrypted>
                </message>
              </last-message>
            </metadata>
          </conversation>
        </query>
        """)
        let decryptedEnvelope = try makeElement("""
        <envelope xmlns='urn:xmpp:sce:1'>
          <content>
            <reference xmlns='urn:xmpp:reference:0' type='data'>
              <file-sharing xmlns='urn:xmpp:sfs:0'/>
            </reference>
          </content>
        </envelope>
        """)

        let modified = manager.modifySyncQuery(
            query,
            decryptMessage: { _ in decryptedEnvelope }
        )

        let message = try XCTUnwrap(
            modified.element(forName: "conversation")?
                .element(forName: "metadata")?
                .element(forName: "last-message")?
                .element(forName: "message")
        )
        XCTAssertNil(message.element(forName: "body"))
        XCTAssertEqual(
            LastChatListSyncPreviewParser.projection(
                owner: owner,
                conversationPrimary: "encrypted-file-primary",
                lastMessageID: "encrypted-file",
                messageElement: message
            )?.text,
            "File".localizeString(id: "chat_message_file", arguments: [])
        )
    }

    func testOMEMOSyncPreviewKeepsServerFallbackOnActualDecryptFailure() throws {
        let manager = OmemoManager(withOwner: owner)
        let query = try makeElement("""
        <query xmlns='https://xabber.com/protocol/synchronization'>
          <conversation jid='encrypted@example.com' type='urn:xmpp:omemo:2'>
            <metadata node='https://xabber.com/protocol/synchronization'>
              <last-message>
                <message from='encrypted@example.com' to='\(owner)' id='encrypted-failure'>
                  <body>Safe encrypted preview</body>
                  <encrypted xmlns='urn:xmpp:omemo:2'>
                    <header sid='42'/>
                  </encrypted>
                </message>
              </last-message>
            </metadata>
          </conversation>
        </query>
        """)

        let modified = manager.modifySyncQuery(query)

        let message = try XCTUnwrap(
            modified.element(forName: "conversation")?
                .element(forName: "metadata")?
                .element(forName: "last-message")?
                .element(forName: "message")
        )
        XCTAssertEqual(message.element(forName: "body")?.stringValue, "Safe encrypted preview")
        XCTAssertNil(message.element(forName: "omemo-result__system"))
        XCTAssertEqual(
            try WRealm.safe().objects(MessageStorageItem.self)
                .filter("owner == %@", owner).count,
            0
        )
        XCTAssertEqual(
            try WRealm.safe().objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner).count,
            0
        )
    }

    func testListOnlyPreviewProjectionClearsOnDeleteAndAccountTeardownButSurvivesReset() throws {
        let manager = makeManager()
        let jid = "preview-lifecycle@example.com"
        let primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )

        func push(id: String, conversation: String) throws -> XMPPIQ {
            try makeIQ("""
            <iq type='set' id='\(id)'>
              <synchronization xmlns='https://xabber.com/protocol/synchronization'
                               stamp='1776840442469440'>
                \(conversation)
              </synchronization>
            </iq>
            """)
        }

        XCTAssertTrue(manager.read(withIQ: try push(
            id: "preview-create",
            conversation: conversationXML(
                jid: jid,
                messageId: "preview-lifecycle-1",
                archiveId: "9200001",
                body: "Lifecycle preview"
            )
        )))
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "preview-lifecycle-1"
            )?.text,
            "Lifecycle preview"
        )

        XCTAssertTrue(manager.read(withIQ: try push(
            id: "preview-delete",
            conversation: """
            <conversation jid='\(jid)'
                          type='urn:xabber:chat'
                          stamp='1776840442469441'
                          status='deleted'/>
            """
        )))
        XCTAssertNil(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "preview-lifecycle-1"
            )
        )

        XCTAssertTrue(manager.read(withIQ: try push(
            id: "preview-recreate",
            conversation: conversationXML(
                jid: jid,
                messageId: "preview-lifecycle-2",
                archiveId: "9200002",
                body: "Reset preview"
            )
        )))
        XCTAssertNotNil(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "preview-lifecycle-2"
            )
        )
        let preparationEpochBeforeReset =
            LastChatListSyncPreviewStore.shared.preparationEpoch(for: owner)
        manager.reset()
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projectionCount(for: owner),
            1
        )
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "preview-lifecycle-2"
            )?.text,
            "Reset preview"
        )
        XCTAssertNotEqual(
            LastChatListSyncPreviewStore.shared.preparationEpoch(for: owner),
            preparationEpochBeforeReset
        )

        LastChatListSyncPreviewStore.shared.apply(
            [
                .upsert(LastChatListSyncPreviewProjection(
                    owner: owner,
                    conversationPrimary: primary,
                    lastMessageID: "preview-stale",
                    text: "Stale preview"
                ))
            ],
            for: owner,
            expectedEpoch: preparationEpochBeforeReset
        )
        XCTAssertNil(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "preview-stale"
            )
        )

        XCTAssertTrue(manager.read(withIQ: try push(
            id: "preview-after-reset",
            conversation: conversationXML(
                jid: jid,
                messageId: "preview-lifecycle-3",
                archiveId: "9200003",
                body: "Teardown preview"
            )
        )))
        XCTAssertNotNil(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "preview-lifecycle-3"
            )
        )
        ClientSynchronizationManager.remove(
            for: owner,
            commitTransaction: false
        )
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projectionCount(for: owner),
            0
        )
    }

    func testDeletedRegularListProjectionRejectsCachedArchiveReplayUntilFreshActiveSync() throws {
        let previousLockedConversationType =
            CommonConfigManager.shared.config.locked_conversation_type
        CommonConfigManager.shared.config.locked_conversation_type =
            ClientSynchronizationManager.ConversationType.regular.rawValue
        defer {
            CommonConfigManager.shared.config.locked_conversation_type =
                previousLockedConversationType
        }
        let jid = "deleted-regular-replay@example.com"
        let cachedDate = Date(timeIntervalSince1970: 1_784_625_681)
        let cached = cachedRegularArchiveMessage(
            jid: jid,
            primary: "deleted-regular-cached",
            messageId: "deleted-regular-message",
            archivedId: "1784625681838707",
            date: cachedDate
        )
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(cached, update: .modified)
        }

        let manager = makeManager()
        try applyRegularListOnlyPush(
            manager: manager,
            jid: jid,
            id: "deleted-regular-create"
        )
        let delete = try makeIQ("""
        <iq type='set' id='deleted-regular-delete'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1787651471639187'>
            <conversation jid='\(jid)'
                          type='urn:xabber:chat'
                          stamp='1787651471639187'
                          status='deleted'/>
          </synchronization>
        </iq>
        """)
        XCTAssertTrue(manager.read(withIQ: delete))
        manager.reset()

        let replayWhileDeleted = cachedRegularArchiveMessage(
            jid: jid,
            primary: cached.primary,
            messageId: cached.messageId,
            archivedId: cached.archivedId,
            date: cachedDate
        )
        replayWhileDeleted.queryIds = "archive.engine.deleted.replay"
        replayWhileDeleted.shouldPersistArchiveQueryId = true
        _ = replayWhileDeleted.save(
            commitTransaction: true,
            silentNotifications: true
        )

        XCTAssertNil(
            realm.objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@ AND isArchived == false",
                    owner,
                    jid,
                    ClientSynchronizationManager.ConversationType.regular.rawValue
                )
                .first,
            "A durable XEP-SYNC deletion must survive manager reset and reject a late cached MAM row."
        )

        let uncachedReplay = cachedRegularArchiveMessage(
            jid: jid,
            primary: "deleted-regular-uncached",
            messageId: "deleted-regular-uncached-message",
            archivedId: "1784625681838706",
            date: cachedDate.addingTimeInterval(-1)
        )
        uncachedReplay.queryIds = "archive.engine.deleted.uncached"
        uncachedReplay.shouldPersistArchiveQueryId = true
        _ = uncachedReplay.save(
            commitTransaction: true,
            silentNotifications: true
        )
        XCTAssertNotNil(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: uncachedReplay.primary
            ),
            "Deletion blocks only list resurrection; archive persistence must still retain the row."
        )
        XCTAssertNil(
            realm.objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@ AND isArchived == false",
                    owner,
                    jid,
                    ClientSynchronizationManager.ConversationType.regular.rawValue
                )
                .first
        )

        let relaunchedManager = makeManager()
        let authoritativeActiveWithoutStatus = try makeIQ("""
        <iq type='set' id='deleted-regular-authoritative-active'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1787651471639188'>
            <conversation jid='\(jid)' stamp='1787651471639188'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread count='0'/>
              </metadata>
            </conversation>
          </synchronization>
        </iq>
        """)
        XCTAssertTrue(
            relaunchedManager.read(withIQ: authoritativeActiveWithoutStatus)
        )
        let activeChat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            )
        )
        XCTAssertFalse(activeChat.isArchived)
        try realm.write {
            realm.delete(activeChat)
        }

        let replayAfterActive = cachedRegularArchiveMessage(
            jid: jid,
            primary: cached.primary,
            messageId: cached.messageId,
            archivedId: cached.archivedId,
            date: cachedDate
        )
        replayAfterActive.queryIds = "archive.engine.after.active"
        replayAfterActive.shouldPersistArchiveQueryId = true
        _ = replayAfterActive.save(
            commitTransaction: true,
            silentNotifications: true
        )

        let restored = try XCTUnwrap(
            realm.objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@ AND isArchived == false",
                    owner,
                    jid,
                    ClientSynchronizationManager.ConversationType.regular.rawValue
                )
                .first
        )
        XCTAssertEqual(restored.lastMessage?.primary, cached.primary)
        XCTAssertEqual(restored.messageDate, cachedDate)
    }

    func testAccountSettingsCleanupClearsDurableRegularDeletionTombstone() throws {
        let jid = "deleted-regular-account-cleanup@example.com"
        let cachedDate = Date(timeIntervalSince1970: 1_784_625_681)
        let cached = cachedRegularArchiveMessage(
            jid: jid,
            primary: "deleted-regular-cleanup-cached",
            messageId: "deleted-regular-cleanup-message",
            archivedId: "1784625681838708",
            date: cachedDate
        )
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(cached, update: .modified)
        }

        let manager = makeManager()
        let delete = try makeIQ("""
        <iq type='set' id='deleted-regular-cleanup-delete'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1787651471639188'>
            <conversation jid='\(jid)'
                          type='urn:xabber:chat'
                          stamp='1787651471639188'
                          status='deleted'/>
          </synchronization>
        </iq>
        """)
        XCTAssertTrue(manager.read(withIQ: delete))

        SettingManager.shared.clear(for: owner)

        let replay = cachedRegularArchiveMessage(
            jid: jid,
            primary: cached.primary,
            messageId: cached.messageId,
            archivedId: cached.archivedId,
            date: cachedDate
        )
        replay.queryIds = "archive.engine.after.account.cleanup"
        replay.shouldPersistArchiveQueryId = true
        _ = replay.save(
            commitTransaction: true,
            silentNotifications: true
        )

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

    func testResetBeforeAtomicPageCommitRollsBackEveryListProjection() throws {
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let request = try startTrackedSnapshot(
            with: manager,
            recording: requests
        )
        let commitReached = expectation(
            description: "page mutations reached atomic commit boundary"
        )
        let releaseCommit = DispatchSemaphore(value: 0)
        manager.beforeCommittingSyncPage = {
            commitReached.fulfill()
            _ = releaseCommit.wait(timeout: .now() + 5)
        }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: request.id,
            conversations: [
                conversationXML(
                    jid: "stale-page-1@example.com",
                    messageId: "stale-page-message-1",
                    archiveId: "9300001"
                ),
                conversationXML(
                    jid: "stale-page-2@example.com",
                    messageId: "stale-page-message-2",
                    archiveId: "9300002"
                )
            ],
            rsmFirst: "stale-page-first",
            rsmFirstIndex: 0,
            rsmLast: "stale-page-last",
            rsmCount: 2
        )))
        wait(for: [commitReached], timeout: 2)

        manager.reset()
        releaseCommit.signal()
        manager.waitForPendingSnapshotApplies()

        XCTAssertEqual(try lastChatCount(), 0)
        XCTAssertEqual(
            LastChatListSyncPreviewStore.shared.projectionCount(for: owner),
            0
        )
        XCTAssertTrue(
            storedClientSyncValue("last_completed_snapshot_stamp")?.isEmpty ?? true
        )
        XCTAssertTrue(
            storedClientSyncValue("last_recognized_event_stamp")?.isEmpty ?? true
        )
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

    func testInitialSnapshotProjectsThreeHundredUnknownGroupsAsListOnlyRows() throws {
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let request = try startTrackedSnapshot(
            with: manager,
            recording: requests
        )
        let conversations = (0..<300).map { index in
            groupListConversationXML(
                jid: "stage-\(index)@groups.example.com",
                unread: index % 7
            )
        }

        XCTAssertTrue(manager.read(withIQ: try snapshotIQ(
            id: request.id,
            conversations: conversations,
            rsmFirst: "group-cursor-0",
            rsmFirstIndex: 0,
            rsmLast: "group-cursor-299",
            rsmCount: 300
        )))

        try waitUntil("three hundred list-only group rows", timeout: 5) {
            let realm = try WRealm.safe()
            return realm.objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND conversationType_ == %@",
                    self.owner,
                    ClientSynchronizationManager.ConversationType.group.rawValue
                )
                .count == 300
        }

        let realm = try WRealm.safe()
        XCTAssertEqual(
            realm.objects(GroupSelfMembershipStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(GroupSnapshotStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(ResourceStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(requests.count, 1)
    }

    func testListOnlyGroupPreviewProjectsAuthorWithoutTimelineRosterOrHydrationWrites() throws {
        let groupJID = "stage@groups.example.com"
        let primary = LastChatsStorageItem.genPrimary(
            jid: groupJID,
            owner: owner,
            conversationType: .group
        )
        let requests = ClientSyncRequestRecorder()
        let manager = makeManager(recording: requests)
        let push = try makeIQ("""
        <iq type='set' id='group-list-preview-author'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1776840442469440'>
            <conversation jid='\(groupJID)'
                          type='https://xabber.com/protocol/groups'
                          stamp='1776840442469439'
                          status='active'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread count='0'/>
                <last-message>
                  <message type='chat'
                           from='\(groupJID)'
                           to='\(owner)'
                           id='group-list-message-1'>
                    <stanza-id xmlns='urn:xmpp:sid:0'
                               by='\(groupJID)'
                               id='9200001'/>
                    <time xmlns='https://xabber.com/protocol/delivery'
                          stamp='2026-03-24T12:34:56Z'/>
                    <body>Photo</body>
                    <x xmlns='https://xabber.com/protocol/groups'>
                      <user id='member-42'>
                        <jid>alice@example.com</jid>
                        <nickname>Alice</nickname>
                      </user>
                    </x>
                  </message>
                </last-message>
              </metadata>
            </conversation>
          </synchronization>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: push))
        try waitUntil("group author list preview applied") {
            LastChatListSyncPreviewStore.shared.projection(
                owner: self.owner,
                conversationPrimary: primary,
                expectedLastMessageID: "group-list-message-1"
            ) != nil
        }

        let projection = try XCTUnwrap(
            LastChatListSyncPreviewStore.shared.projection(
                owner: owner,
                conversationPrimary: primary,
                expectedLastMessageID: "group-list-message-1"
            )
        )
        XCTAssertEqual(projection.groupchatNickname, "Alice")
        XCTAssertEqual(projection.groupchatAuthorColorKey, "member-42")

        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: primary
            )
        )
        XCTAssertNil(chat.lastMessage)
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(RosterStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(ResourceStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(GroupSnapshotStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(GroupSelfMembershipStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(GroupMemberStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(GroupPermissionSetStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            requests.count,
            0,
            "A list-only group preview must not start group or archive IQ work."
        )
    }

    func testIncrementalSyncProjectsThreeHundredUnknownGroupsWithoutHydration() throws {
        let manager = makeManager()
        let conversations = (0..<300).map { index in
            groupListConversationXML(
                jid: "incremental-\(index)@groups.example.com",
                unread: index % 5,
                stamp: "1776840442469440"
            )
        }
        let push = try makeIQ("""
        <iq type='set' id='incremental-groups'>
          <synchronization xmlns='https://xabber.com/protocol/synchronization'
                           stamp='1776840442469440'>
            \(conversations.joined(separator: "\n"))
          </synchronization>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: push))

        let realm = try WRealm.safe()
        XCTAssertEqual(
            realm.objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND conversationType_ == %@",
                    owner,
                    ClientSynchronizationManager.ConversationType.group.rawValue
                )
                .count,
            300
        )
        XCTAssertEqual(
            realm.objects(GroupSelfMembershipStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            0
        )
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

    func testV3InviteShapedSnapshotPayloadCreatesNeitherInviteNorListRow() throws {
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

        manager.waitForPendingSnapshotApplies()
        XCTAssertNil(try GroupRepository(realm: WRealm.safe()).incomingInvite(
            owner: owner,
            groupJID: groupchat
        ))
        let realm = try WRealm.safe()
        XCTAssertNil(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: groupchat,
                    owner: owner,
                    conversationType: .group
                )
            )
        )
        XCTAssertEqual(
            storedClientSyncValue("last_completed_snapshot_stamp"),
            "1776840442469439",
            "Fail-closed invite handling must still complete the list-only page"
        )
    }

    func testCanonicalGroupSynchronizationSignalsUseOnlyListStatus() throws {
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
            .active(groupJID: "stage@groups.example.com")
        )
        XCTAssertEqual(
            ClientSynchronizationManager.canonicalGroupSynchronizationSignal(from: deleted),
            .deleted(groupJID: "stage@groups.example.com")
        )
    }

    func testGenericSynchronizationApplierCreatesListOnlyGroupProjectionWithoutMembership() throws {
        let realm = try WRealm.safe()
        let group = "stage@groups.example.com"
        let conversation = try makeElement("""
        <conversation jid='\(group)'
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
            applyConversationState: { _, _ in
                genericCallbacks.append("metadata")
                let item = LastChatsStorageItem()
                item.owner = self.owner
                item.jid = group
                item.conversationType = .group
                item.setPrimary(withOwner: self.owner)
                realm.add(item, update: .modified)
                return true
            }
        )

        XCTAssertEqual(
            genericCallbacks,
            ["metadata"],
            "An unverified XEP-SYNC group is chat-list state only; it must not materialize timeline, marker, or presence work"
        )
        XCTAssertEqual(result.summary.createdChatCount, 1)
        XCTAssertEqual(result.summary.skippedConversationCount, 0)
        XCTAssertNotNil(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: group,
                    owner: owner,
                    conversationType: .group
                )
            )
        )
    }

    func testGenericSynchronizationApplierRemainsListOnlyAfterBothMembership() throws {
        let realm = try WRealm.safe()
        let group = "stage@groups.example.com"
        try GroupRepository(realm: realm).admitSnapshot(
            GroupSnapshot(jid: group),
            membership: .both,
            memberID: "member-self",
            owner: owner,
            groupJID: group,
            members: [
                GroupMember(
                    id: "member-self",
                    jid: owner,
                    role: .member
                )
            ]
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
            applyConversationState: { _, _ in
                genericCallbacks.append("metadata")
                return true
            }
        )

        XCTAssertEqual(genericCallbacks, ["metadata"])
    }
}

final class ClientSynchronizationArchiveIsolationContractTests: XCTestCase {
    func testClientSyncPageApplierExposesNoTimelineRosterMarkerOrPresenceCallbacks() throws {
        let source = try productionSource(
            "xmpp/XEP-0CCC/ClientSynchronizationManager.swift"
        )
        let applier = try sourceSection(
            source,
            from: "struct ClientSyncPageApplier {",
            to: "class ClientSynchronizationManager:"
        )
        let applyPath = try sourceSection(
            source,
            from: "private func applySyncPayload(",
            to: "private func beginApplyingPage("
        )
        let forbiddenApplierTokens = [
            "MessageManager.MessageQueueItem",
            "queueItems",
            "readConversation:",
            "readInvites:",
            "readMarkers:",
            "readPresence:",
        ]
        let forbiddenApplyPathTokens = [
            "processQueueItems(",
            "readConversation(",
            "readMessageMarkers(",
            "readPresence(",
        ]

        XCTAssertEqual(forbiddenApplierTokens.filter(applier.contains), [])
        XCTAssertEqual(forbiddenApplyPathTokens.filter(applyPath.contains), [])
    }

    func testXEPSYNCContainsNoTimelineArchiveRequestOrRepairOrchestration() throws {
        let source = try productionSource(
            "xmpp/XEP-0CCC/ClientSynchronizationManager.swift"
        )
        let forbiddenTokens = [
            "requestArchive(",
            "requestCanonicalGroupHistory(",
            "requestInitialMAM(",
            "SnapshotRepairTarget",
            "snapshotRepair",
            "idleBackfill",
            "archiveXEPSYNCSnapshotDidComplete("
        ]

        let violations = forbiddenTokens.filter(source.contains)

        XCTAssertEqual(
            violations,
            [],
            "Initial/full XEP-SYNC may update chat-list metadata, but must not request or invalidate timeline archive windows"
        )
    }

    func testAccountArchiveEngineConnectionIsIndependentFromXEPSYNCCompletion() throws {
        let source = try productionSource("models/account/Account.swift")

        XCTAssertFalse(
            source.contains("waitsForXEPSYNC"),
            "Opening a chat must not wait for XEP-SYNC"
        )
        XCTAssertFalse(
            source.contains("func archiveXEPSYNCSnapshotDidComplete("),
            "XEP-SYNC completion must not replace archive-engine connection freshness"
        )

        let syncSource = try productionSource(
            "xmpp/XEP-0CCC/ClientSynchronizationManager.swift"
        )
        XCTAssertFalse(
            syncSource.contains("archiveEngine"),
            "Client synchronization must not call or mutate the timeline archive engine"
        )
    }

    func testCanonicalGroupSynchronizationIsListOnlyAndStartsNoGroupIQRecovery() throws {
        let syncSource = try productionSource(
            "xmpp/XEP-0CCC/ClientSynchronizationManager.swift"
        )
        XCTAssertFalse(
            syncSource.contains("recoverCanonicalGroupMembershipFromSynchronization("),
            "An active XEP-SYNC group row must update the chat list without starting group details, members, or permissions IQs"
        )

        let integrationSource = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        XCTAssertFalse(
            integrationSource.contains("func recoverCanonicalGroupMembershipFromSynchronization("),
            "The eager per-sync-row recovery entry point must be deleted instead of retained as an unused legacy path"
        )
    }

    func testAuthenticationAndResumeDoNotFanOutCanonicalGroupMetadataIQs() throws {
        let source = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        let resumeBody = try sourceSection(
            source,
            from: "func recoverCanonicalGroupRuntimeAfterStreamManagementResume()",
            to: "func recoverCanonicalGroupRuntimeAfterFullAuthentication()"
        )
        let fullAuthenticationBody = try sourceSection(
            source,
            from: "func recoverCanonicalGroupRuntimeAfterFullAuthentication()",
            to: "func reconcileCanonicalGroupDeletionFromSynchronization("
        )
        let forbiddenFanOutTokens = [
            ".activeGroups(",
            "groupMembershipDidActivate("
        ]

        XCTAssertEqual(
            forbiddenFanOutTokens.filter(resumeBody.contains),
            [],
            "Stream resume may rebind the typed transport, but it must not enumerate and hydrate every group"
        )
        XCTAssertEqual(
            forbiddenFanOutTokens.filter(fullAuthenticationBody.contains),
            [],
            "Full authentication may prepare the typed transport, but it must not enumerate and hydrate every group"
        )
    }

    func testCanonicalGroupLifecycleContainsNoEagerHistoryPathOutsideArchiveEngine() throws {
        let integrationSource = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        let managerSource = try productionSource(
            "xmpp/messages/message_archive/MessageArchiveManager.swift"
        )

        XCTAssertFalse(
            integrationSource.contains("requestCanonicalGroupHistory("),
            "Membership activation must update group state only; opening the group submits its visible window through AccountArchiveEngine"
        )
        XCTAssertFalse(
            managerSource.contains("func requestCanonicalGroupHistory("),
            "The eager canonical-group bootstrap entry point must be deleted rather than retained as an unused legacy route"
        )
    }

    func testInitialXEPSYNCHasNoCrossFileArchiveReleaseHooks() throws {
        let syncSource = try productionSource(
            "xmpp/XEP-0CCC/ClientSynchronizationManager.swift"
        )
        let accountSource = try productionSource("models/account/Account.swift")
        let connectionSource = try productionSource(
            "models/account/extensions/AccountConnectBehaviorExtension.swift"
        )

        let syncReleaseHooks = [
            "pendingPostBootstrapWork",
            "deferPostBootstrapWorkIfNeeded(",
            "flushBootstrapQueuedPrimaryStanzas(",
            "bootstrapGateDidChange("
        ]
        XCTAssertEqual(
            syncReleaseHooks.filter(syncSource.contains),
            [],
            "Completing initial XEP-SYNC must not release deferred account traffic or queued MAM consumers"
        )

        XCTAssertFalse(
            accountSource.contains("self?.syncManager.isBootstrapCriticalSyncInProgress() ?? false"),
            "The account scheduler must not use chat-list synchronization as an admission gate"
        )

        let deferredArchiveConsumers = [
            "self.notifications.update(self.xmppStream)",
            "self.favorites.update(self.xmppStream)",
            "updatePostBootstrapArchives"
        ]
        XCTAssertEqual(
            deferredArchiveConsumers.filter(connectionSource.contains),
            [],
            "Notifications and Saved archive refreshes must not be deferred work launched by initial XEP-SYNC completion"
        )
    }

    func testAuxiliaryArchiveRefreshesUseBackgroundMAMPriority() throws {
        let notificationsSource = try productionSource(
            "xmpp/notifications/XMPPNotificationsManager.swift"
        )
        let notificationUpdate = try sourceSection(
            notificationsSource,
            from: "public func update(_ stream: XMPPStream)",
            to: "private final func performLatestSync("
        )
        XCTAssertTrue(notificationUpdate.contains("priority: .background"))
        XCTAssertFalse(notificationUpdate.contains("priority: .foreground"))

        let favoritesSource = try productionSource(
            "xmpp/favorites/XMPPFavoritesManager.swift"
        )
        let favoritesUpdate = try sourceSection(
            favoritesSource,
            from: "func updateArchive(_ stream: XMPPStream)",
            to: "static func remove(for owner: String"
        )
        XCTAssertTrue(favoritesUpdate.contains("priority: .background"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("xabber", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSection(
        _ source: String,
        from startToken: String,
        to endToken: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken))
        let end = try XCTUnwrap(
            source.range(
                of: endToken,
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
