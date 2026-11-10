import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

/// Regression coverage for cursor preservation, bounded page overlap and
/// event-version ordering. All storage and accounts are test-local.
final class ClientSyncLatencyRemediationTests: XCTestCase {
    private final class Requests {
        private let lock = NSLock()
        private var values: [ClientSynchronizationManager.SyncRequestDiagnostics] = []

        func append(_ value: ClientSynchronizationManager.SyncRequestDiagnostics) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return values.count
        }

        func at(_ index: Int) -> ClientSynchronizationManager.SyncRequestDiagnostics? {
            lock.lock()
            defer { lock.unlock() }
            return values.indices.contains(index) ? values[index] : nil
        }
    }

    private final class Counter {
        private let lock = NSLock()
        private var value = 0

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private var previousRealm: Realm.Configuration!
    private var retainedRealm: Realm!
    private var owner = ""
    private var managers: [ClientSynchronizationManager] = []
    private let baseline = "1700000000000000"

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        owner = "sync-latency-\(UUID().uuidString.lowercased())@example.test"
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: owner)
        retainedRealm = try WRealm.safe()
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept([])
        AccountManager.shared.connectingUsers.accept([])
        AccountManager.shared.authenticatedUsers.accept([])
        let stored = AccountStorageItem()
        stored.jid = owner
        stored.username = "sync-latency"
        stored.enabled = true
        try retainedRealm.write { retainedRealm.add(stored, update: .modified) }
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        account.blocked.lastUpdate = Date()
        AccountManager.shared.users.append(account)
    }

    override func tearDownWithError() throws {
        for manager in managers {
            manager.waitForPendingSnapshotApplies()
            manager.syncRequestObserver = nil
            manager.beforeApplyingSyncPayload = nil
            manager.beforePreparingSyncPage = nil
            manager.beforeRecordingSnapshotPush = nil
            manager.beforeCommittingSyncPage = nil
            manager.beforeDispatchingSnapshotContinuation = nil
            manager.reset()
        }
        managers.removeAll()
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept([])
        AccountManager.shared.connectingUsers.accept([])
        AccountManager.shared.authenticatedUsers.accept([])
        retainedRealm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        previousRealm = nil
        owner = ""
    }

    func testPersistedEventStampIsKeptWhenAnArchivedRowHasNoPreview() throws {
        storeBaseline()
        let row = LastChatsStorageItem()
        row.jid = "hidden-missing-preview@example.test"
        row.conversationType = .regular
        row.setPrimary(withOwner: owner)
        row.lastMessageId = "not-materialized"
        row.isArchived = true
        try retainedRealm.write { retainedRealm.add(row) }
        let requests = Requests()
        let manager = makeManager(requests)

        XCTAssertTrue(manager.sync(XMPPStream()))

        XCTAssertEqual(try XCTUnwrap(requests.at(0)).stamp, baseline,
                       "A presentation-cache miss must not discard the processed synchronization cursor")
    }

    func testFirstFullSnapshotPaginatesThenTheNextSyncUsesItsFinalStamp() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        XCTAssertTrue(manager.sync(XMPPStream()))
        let first = try XCTUnwrap(requests.at(0))
        XCTAssertNil(first.stamp)
        XCTAssertTrue(manager.readSnapshot(try page(id: first.id, stamp: "1700000000000200",
            conversations: [conversation(jid: "page-one@example.test", stamp: "1700000000000100", message: "one")],
            index: 0, count: 2, cursor: "next-page")))
        XCTAssertTrue(waitUntil { requests.count == 2 })
        let second = try XCTUnwrap(requests.at(1))
        XCTAssertNil(second.stamp)
        XCTAssertEqual(second.after, "next-page")
        XCTAssertTrue(manager.readSnapshot(try page(id: second.id, stamp: "1700000000000200",
            conversations: [conversation(jid: "page-two@example.test", stamp: "1700000000000200", message: "two")],
            index: 1, count: 2, cursor: "last-page")))
        manager.waitForPendingSnapshotApplies()

        XCTAssertTrue(manager.sync(XMPPStream()))

        XCTAssertEqual(try XCTUnwrap(requests.at(2)).stamp, "1700000000000200")
        XCTAssertNil(requests.at(2)?.after)
    }

    func testStartupRecentsWitnessIsPublishedAfterFirstPageCommitsBeforeFinalPage() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        manager.prepareForAuthenticatedStream(didResume: false)
        let commitEntered = expectation(description: "first page reached commit boundary")
        let release = DispatchSemaphore(value: 0)
        manager.beforeCommittingSyncPage = {
            commitEntered.fulfill()
            _ = release.wait(timeout: .now() + 3)
        }
        defer { release.signal() }
        let owner = self.owner
        let notices = Counter()
        let batchToken = NotificationCenter.default.addObserver(forName: ClientSyncPageBatch.didCommitNotification,
                                                                 object: nil, queue: nil) { notice in
            guard let receipt = notice.object as? ClientSyncPageBatch.Receipt, receipt.owner == owner else { return }
            XCTAssertTrue(manager.hasReceivedStartupRecentsResponse())
        }
        let readinessToken = NotificationCenter.default.addObserver(
            forName: ClientSynchronizationManager.startupRecentsReadinessDidChange,
            object: nil, queue: nil
        ) { notice in
            guard notice.object as? String == owner else { return }
            XCTAssertFalse(ClientSyncPageBatch.shared.isBatchActive(owner: owner))
            notices.increment()
        }
        defer {
            NotificationCenter.default.removeObserver(batchToken)
            NotificationCenter.default.removeObserver(readinessToken)
        }

        XCTAssertTrue(manager.sync(XMPPStream()))
        let first = try XCTUnwrap(requests.at(0))
        let jid = "initial-page@example.test"
        XCTAssertTrue(manager.readSnapshot(try page(id: first.id, stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "first")],
            index: 0, count: 2, cursor: "next")))
        wait(for: [commitEntered], timeout: 1)
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())
        XCTAssertFalse(manager.isStartupRecentsReady())
        XCTAssertEqual(notices.count, 0)

        release.signal()
        manager.waitForPendingSnapshotApplies()

        XCTAssertTrue(manager.hasReceivedStartupRecentsResponse())
        XCTAssertTrue(manager.isStartupRecentsReady())
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(try chat(jid)?.lastMessageId, "first")
        XCTAssertTrue(manager.isStartupSynchronizationPending(), "First-page presentation cannot release the full startup barrier")
        manager.reset()
        XCTAssertTrue(manager.hasReceivedStartupRecentsResponse(), "Reconnect must not re-arm the launch skeleton")
    }

    func testEmptyFirstResponseWitnessesRecentsAfterResumeWithoutStartupTrafficGate() throws {
        storeBaseline()
        let requests = Requests()
        let manager = makeManager(requests)
        manager.prepareForAuthenticatedStream(didResume: true)
        XCTAssertFalse(manager.isStartupSynchronizationPending())
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse(), "The persisted cursor is not a new response")

        XCTAssertTrue(manager.sync(XMPPStream()))
        let first = try XCTUnwrap(requests.at(0))
        XCTAssertEqual(first.stamp, baseline)
        XCTAssertTrue(manager.readSnapshot(try page(id: first.id, stamp: baseline,
            conversations: [], index: 0, count: 0, cursor: "empty")))
        manager.waitForPendingSnapshotApplies()

        XCTAssertTrue(manager.hasReceivedStartupRecentsResponse())
    }

    func testPushUntrackedForeignOrFailedSnapshotCannotWitnessStartupRecentsResponse() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        XCTAssertTrue(manager.readPush(try push(stamp: baseline, conversations: [])))
        XCTAssertTrue(manager.readSnapshot(try page(id: "untracked", stamp: baseline,
            conversations: [], index: 0, count: 0, cursor: "empty")))
        manager.waitForPendingSnapshotApplies()
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())

        XCTAssertTrue(manager.sync(XMPPStream()))
        let foreign = try page(id: XCTUnwrap(requests.at(0)).id, stamp: baseline,
            conversations: [], index: 0, count: 0, cursor: "foreign")
        foreign.addAttribute(withName: "from", stringValue: "foreign@elsewhere.test")
        XCTAssertTrue(manager.readSnapshot(foreign))
        manager.waitForPendingSnapshotApplies()
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())

        manager.beforeApplyingSyncPayload = { throw NSError(domain: "startup-recents-test", code: 1) }
        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(1)).id, stamp: baseline,
            conversations: [], index: 0, count: 0, cursor: "failed")))
        manager.waitForPendingSnapshotApplies()
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())
    }

    func testLegacyStartupRecentsWitnessRequiresCorrelatedSuccessfulInitialRoster() throws {
        let account = try XCTUnwrap(AccountManager.shared.find(for: owner))
        let manager = account.syncManager
        defer { account.roster.clearInitialRosterSession() }
        account.roster.request(account.xmppStream)
        let errorID = try XCTUnwrap(account.roster.queryIds.last)
        XCTAssertTrue(account.roster.read(withIQ: try iq("""
            <iq type='error' id='\(errorID)'><error type='cancel'/></iq>
            """)))
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())

        account.roster.request(account.xmppStream)
        let invalidID = try XCTUnwrap(account.roster.queryIds.last)
        XCTAssertTrue(account.roster.read(withIQ: try iq("<iq type='result' id='\(invalidID)'><unrelated/></iq>")))
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())

        account.roster.request(account.xmppStream)
        let successID = try XCTUnwrap(account.roster.queryIds.last)
        XCTAssertFalse(account.roster.read(withIQ: try iq("<iq type='result' id='old-request'/>")))
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())
        XCTAssertTrue(account.roster.read(withIQ: try iq("<iq type='result' id='\(successID)'/>")))
        XCTAssertTrue(manager.hasReceivedStartupRecentsResponse())
    }

    func testOlderPushCannotRollBackConversationOrRecognizedCursor() throws {
        storeBaseline()
        let manager = makeManager()
        let jid = "ordered-peer@example.test"
        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000300",
            conversations: [conversation(jid: jid, stamp: "1700000000000300", message: "newer", unread: 3)])))
        manager.waitForPendingSnapshotApplies()

        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "older", unread: 1)])))
        manager.waitForPendingSnapshotApplies()

        let stored = try XCTUnwrap(chat(jid))
        XCTAssertEqual(stored.lastMessageId, "newer")
        XCTAssertEqual(stored.syncUnreadCount, 3)
        XCTAssertEqual(stored.updateTS, 1_700_000_000_000_300)
        XCTAssertEqual(storedValue("last_recognized_event_stamp"), "1700000000000300")
    }

    func testExactReplayDoesNotCommitTheSameConversationAgain() throws {
        storeBaseline()
        let commits = Counter()
        let manager = makeManager()
        manager.beforeCommittingSyncPage = { commits.increment() }
        let xml = try push(stamp: "1700000000000200", conversations: [
            conversation(jid: "replay-peer@example.test", stamp: "1700000000000200", message: "same-event")
        ])
        XCTAssertTrue(manager.readPush(xml))
        manager.waitForPendingSnapshotApplies()
        let firstCommitCount = commits.count
        XCTAssertEqual(firstCommitCount, 1)

        XCTAssertTrue(manager.readPush(xml))
        manager.waitForPendingSnapshotApplies()

        XCTAssertEqual(commits.count, firstCommitCount,
                       "An exact event replay must not repeat a Realm write transaction")
    }

    func testNewerRevisionOfTheSameConversationStillApplies() throws {
        storeBaseline()
        let manager = makeManager()
        let jid = "new-revision@example.test"
        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "first")])) )
        manager.waitForPendingSnapshotApplies()

        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000300",
            conversations: [conversation(jid: jid, stamp: "1700000000000300", message: "second")])) )
        manager.waitForPendingSnapshotApplies()

        XCTAssertEqual(try XCTUnwrap(chat(jid)).lastMessageId, "second")
        XCTAssertEqual(storedValue("last_recognized_event_stamp"), "1700000000000300")
    }

    func testFinalAcceptedConversationRecordOwnsPreviewWhenPageRepeatsItsIdentity() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        let jid = "repeated-page-peer@example.test"
        XCTAssertTrue(manager.sync(XMPPStream()))
        let request = try XCTUnwrap(requests.at(0))
        XCTAssertTrue(manager.readSnapshot(try page(
            id: request.id,
            stamp: "1700000000000300",
            conversations: [
                conversation(jid: jid, stamp: "1700000000000100", message: "first"),
                conversation(jid: jid, stamp: "1700000000000300", message: "current"),
                conversation(jid: jid, stamp: "1700000000000200", message: "late-stale")
            ],
            index: 0, count: 3, cursor: "final"
        )))
        manager.waitForPendingSnapshotApplies()

        let stored = try XCTUnwrap(chat(jid))
        XCTAssertEqual(stored.lastMessageId, "current")
        let preview = LastChatListSyncPreviewStore.shared.projection(
            owner: owner,
            conversationPrimary: stored.primary,
            expectedLastMessageID: "current"
        )
        XCTAssertEqual(preview?.text, "current")
    }

    func testOlderActiveEventCannotResurrectADeletedConversation() throws {
        storeBaseline()
        let manager = makeManager()
        let jid = "deleted-peer@example.test"
        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "before-delete")])) )
        manager.waitForPendingSnapshotApplies()
        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000300", conversations: [
            "<conversation jid='\(jid)' type='urn:xabber:chat' stamp='1700000000000300' status='deleted'/>"
        ])))
        manager.waitForPendingSnapshotApplies()
        XCTAssertNil(try chat(jid))

        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000100",
            conversations: [conversation(jid: jid, stamp: "1700000000000100", message: "obsolete-active")])) )
        manager.waitForPendingSnapshotApplies()

        XCTAssertNil(try chat(jid))
        XCTAssertEqual(storedValue("last_recognized_event_stamp"), "1700000000000300")
    }

    func testNewerPushWinsOverAnAlreadyQueuedOlderSnapshotPage() throws {
        storeBaseline()
        let requests = Requests()
        let manager = makeManager(requests)
        let entered = expectation(description: "snapshot reached its apply boundary")
        let returned = expectation(description: "push callback returned")
        let release = DispatchSemaphore(value: 0)
        let applications = Counter()
        manager.beforeApplyingSyncPayload = {
            if applications.increment() == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        defer { release.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        let request = try XCTUnwrap(requests.at(0))
        let jid = "interleaved-peer@example.test"
        XCTAssertTrue(manager.readSnapshot(try page(id: request.id, stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "snapshot-old")],
            index: 0, count: 1, cursor: "finished")))
        wait(for: [entered], timeout: 1)
        let newer = try push(stamp: "1700000000000300", conversations: [
            conversation(jid: jid, stamp: "1700000000000300", message: "push-new")
        ])

        DispatchQueue.global().async {
            _ = manager.readPush(newer)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 1)
        release.signal()
        manager.waitForPendingSnapshotApplies()

        XCTAssertEqual(try XCTUnwrap(chat(jid)).lastMessageId, "push-new")
        XCTAssertEqual(storedValue("last_recognized_event_stamp"), "1700000000000300")
    }

    func testNewerEncryptedDeletionCannotBeResurrectedByAQueuedOlderSnapshot() throws {
        storeBaseline()
        let jid = "deleted-encrypted@example.test"
        let row = LastChatsStorageItem()
        row.jid = jid
        row.conversationType = .omemo
        row.setPrimary(withOwner: owner)
        row.updateTS = 1_700_000_000_000_100
        try retainedRealm.write { retainedRealm.add(row) }
        let requests = Requests()
        let manager = makeManager(requests)
        let entered = expectation(description: "older encrypted page reached apply boundary")
        let release = DispatchSemaphore(value: 0)
        let applications = Counter()
        manager.beforeApplyingSyncPayload = {
            if applications.increment() == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        defer { release.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(0)).id,
            stamp: "1700000000000200", conversations: [
                conversation(jid: jid, stamp: "1700000000000200", message: "older-encrypted", type: .omemo)
            ], index: 0, count: 1, cursor: "finished")))
        wait(for: [entered], timeout: 1)

        XCTAssertTrue(manager.readPush(try push(stamp: "1700000000000300", conversations: [
            "<conversation jid='\(jid)' type='\(ClientSynchronizationManager.ConversationType.omemo.rawValue)' stamp='1700000000000300' status='deleted'/>"
        ])))
        XCTAssertNil(try chat(jid, type: .omemo))
        release.signal()
        manager.waitForPendingSnapshotApplies()

        XCTAssertNil(try chat(jid, type: .omemo),
                     "An older encrypted page must respect a newer deletion after its row has gone")
    }

    func testNewGenerationReconcilesAnIdenticalEventAfterLocalStateChanged() throws {
        storeBaseline()
        let manager = makeManager()
        let jid = "generation-replay@example.test"
        let event = try push(stamp: "1700000000000200", conversations: [
            conversation(jid: jid, stamp: "1700000000000200", message: "server-state")
        ])
        XCTAssertTrue(manager.readPush(event))
        let row = try XCTUnwrap(chat(jid))
        try retainedRealm.write { row.lastMessageId = "local-state" }
        manager.reset()

        XCTAssertTrue(manager.readPush(event))

        XCTAssertEqual(try XCTUnwrap(chat(jid)).lastMessageId, "server-state",
                       "A previous stream generation cannot suppress this generation's reconciliation")
    }

    func testExactReplayRebuildsAMissingConversationProjection() throws {
        storeBaseline()
        let manager = makeManager()
        let jid = "missing-replay@example.test"
        let event = try push(stamp: "1700000000000200", conversations: [
            conversation(jid: jid, stamp: "1700000000000200", message: "server-state")
        ])
        XCTAssertTrue(manager.readPush(event))
        let row = try XCTUnwrap(chat(jid))
        try retainedRealm.write { retainedRealm.delete(row) }

        XCTAssertTrue(manager.readPush(event))

        XCTAssertEqual(try XCTUnwrap(chat(jid)).lastMessageId, "server-state",
                       "An absent projection must not be treated as an already applied event")
    }

    func testPushCursorIsNotLostWhenFinalSnapshotCommitsDuringItsDispositionCheck() throws {
        storeBaseline()
        let requests = Requests()
        let manager = makeManager(requests)
        let applyEntered = expectation(description: "final apply held")
        let pushChecked = expectation(description: "push checked active snapshot")
        let pushReturned = expectation(description: "push returned")
        let releaseApply = DispatchSemaphore(value: 0)
        let releasePush = DispatchSemaphore(value: 0)
        let calls = Counter()
        manager.beforeApplyingSyncPayload = {
            if calls.increment() == 1 { applyEntered.fulfill(); _ = releaseApply.wait(timeout: .now() + 3) }
        }
        manager.beforeRecordingSnapshotPush = {
            pushChecked.fulfill(); _ = releasePush.wait(timeout: .now() + 3)
        }
        defer { releaseApply.signal(); releasePush.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        let jid = "final-push-interleaving@example.test"
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(0)).id, stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "snapshot")],
            index: 0, count: 1, cursor: "final")))
        wait(for: [applyEntered], timeout: 1)
        let newer = try push(stamp: "1700000000000300", conversations: [
            conversation(jid: jid, stamp: "1700000000000300", message: "newer-push")
        ])
        DispatchQueue.global().async { _ = manager.readPush(newer); pushReturned.fulfill() }
        wait(for: [pushChecked], timeout: 1)

        releaseApply.signal()
        manager.waitForPendingSnapshotApplies()
        releasePush.signal()
        wait(for: [pushReturned], timeout: 1)

        XCTAssertEqual(storedValue("last_recognized_event_stamp"), "1700000000000300")
    }

    func testContinuationIsRequestedWhilePreviousPageApplyIsBlocked() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        let entered = expectation(description: "page apply started")
        let release = DispatchSemaphore(value: 0)
        let applications = Counter()
        manager.beforeApplyingSyncPayload = {
            if applications.increment() == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        defer { release.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        let first = try XCTUnwrap(requests.at(0))

        XCTAssertTrue(manager.readSnapshot(try page(id: first.id, stamp: "1700000000000200",
            conversations: [conversation(jid: "overlapped-page@example.test", stamp: "1700000000000100", message: "first")],
            index: 0, count: 2, cursor: "next-before-apply")))
        wait(for: [entered], timeout: 1)

        XCTAssertTrue(waitUntil(timeout: 0.5) { requests.count == 2 },
                      "Cursor networking must overlap the already accepted page's expensive apply")
    }

    func testPipelineHoldsAtTwoUncommittedPagesUntilTheFirstCommit() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        let entered = expectation(description: "first apply is held")
        let release = DispatchSemaphore(value: 0)
        let applications = Counter()
        manager.beforeApplyingSyncPayload = {
            if applications.increment() == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        }
        defer { release.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(0)).id, stamp: "1700000000000300",
            conversations: [conversation(jid: "bounded-one@example.test", stamp: "1700000000000100", message: "one")],
            index: 0, count: 3, cursor: "bounded-next")))
        wait(for: [entered], timeout: 1)
        XCTAssertTrue(waitUntil { requests.count == 2 })
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(1)).id, stamp: "1700000000000300",
            conversations: [conversation(jid: "bounded-two@example.test", stamp: "1700000000000200", message: "two")],
            index: 1, count: 3, cursor: "bounded-third")))

        XCTAssertFalse(waitUntil(timeout: 0.2) { requests.count > 2 },
                       "Do not retain an unbounded series of pages while persistence is blocked")
        release.signal()
        XCTAssertTrue(waitUntil { requests.count == 3 })
    }

    func testFinalResponseDoesNotReleaseStartupWhileEarlierApplyIsHeld() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        manager.prepareForAuthenticatedStream(didResume: false)
        let entered = expectation(description: "first startup page is held")
        let release = DispatchSemaphore(value: 0)
        let applications = Counter()
        manager.beforeApplyingSyncPayload = {
            if applications.increment() == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        }
        defer { release.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(0)).id, stamp: "1700000000000200",
            conversations: [conversation(jid: "startup-one@example.test", stamp: "1700000000000100", message: "one")],
            index: 0, count: 2, cursor: "startup-next")))
        wait(for: [entered], timeout: 1)
        XCTAssertTrue(waitUntil { requests.count == 2 })
        XCTAssertTrue(manager.readSnapshot(try page(id: XCTUnwrap(requests.at(1)).id, stamp: "1700000000000200",
            conversations: [conversation(jid: "startup-two@example.test", stamp: "1700000000000200", message: "two")],
            index: 1, count: 2, cursor: "startup-final")))

        XCTAssertTrue(manager.isStartupSynchronizationPending())
        XCTAssertFalse(manager.isSynced())
        XCTAssertTrue(storedValue("last_completed_snapshot_stamp")?.isEmpty ?? true)
        release.signal()
        manager.waitForPendingSnapshotApplies()
        XCTAssertFalse(manager.isStartupSynchronizationPending())
        XCTAssertTrue(manager.isSynced())
    }

    func testSnapshotCallbackReturnsBeforePreparationAndResetCancelsQueuedWork() throws {
        let requests = Requests()
        let manager = makeManager(requests)
        let entered = expectation(description: "background preparation entered")
        let release = DispatchSemaphore(value: 0)
        manager.beforePreparingSyncPage = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        defer { release.signal() }
        XCTAssertTrue(manager.sync(XMPPStream()))
        let request = try XCTUnwrap(requests.at(0))
        let jid = "cancelled-preparation@example.test"

        XCTAssertTrue(manager.readSnapshot(try page(id: request.id, stamp: "1700000000000200",
            conversations: [conversation(jid: jid, stamp: "1700000000000200", message: "cancelled")],
            index: 0, count: 1, cursor: "final")))
        wait(for: [entered], timeout: 1)
        manager.reset()
        release.signal()
        manager.waitForPendingSnapshotApplies()

        XCTAssertNil(try chat(jid))
        XCTAssertTrue(storedValue("last_recognized_event_stamp")?.isEmpty ?? true)
        XCTAssertFalse(manager.hasReceivedStartupRecentsResponse())
    }

    func testDurablePreviewReloadIsRenderOnlyAndScopedToItsAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = LastChatListSyncPreviewProjection(owner: owner, conversationPrimary: "render-only",
            lastMessageID: "message-one", text: "Cached list preview")
        let writer = LastChatListSyncPreviewStore(directory: directory)
        writer.apply([.upsert(projection)], for: owner)
        writer.waitForPendingPersistence()
        let reader = LastChatListSyncPreviewStore(directory: directory)

        _ = reader.projection(owner: owner, conversationPrimary: projection.conversationPrimary,
                              expectedLastMessageID: projection.lastMessageID)
        reader.waitForPendingPersistence()

        XCTAssertEqual(reader.projection(owner: owner, conversationPrimary: projection.conversationPrimary,
            expectedLastMessageID: projection.lastMessageID), projection)
        XCTAssertNil(reader.projection(owner: owner + ".other", conversationPrimary: projection.conversationPrimary,
            expectedLastMessageID: projection.lastMessageID))
        reader.waitForPendingPersistence()
        XCTAssertEqual(try WRealm.safe().objects(MessageStorageItem.self).count, 0)
        XCTAssertTrue(storedValue("last_recognized_event_stamp")?.isEmpty ?? true)
    }

    func testDelayedPreviewLoadCannotOverwriteANewerLiveMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = LastChatListSyncPreviewProjection(owner: owner, conversationPrimary: "delayed",
            lastMessageID: "old", text: "Old")
        let newer = LastChatListSyncPreviewProjection(owner: owner, conversationPrimary: "delayed",
            lastMessageID: "new", text: "New")
        let writer = LastChatListSyncPreviewStore(directory: directory)
        writer.apply([.upsert(old)], for: owner)
        writer.waitForPendingPersistence()
        let entered = expectation(description: "disk load held")
        let release = DispatchSemaphore(value: 0)
        let reader = LastChatListSyncPreviewStore(directory: directory, beforeLoading: {
            entered.fulfill(); _ = release.wait(timeout: .now() + 3)
        })
        defer { release.signal() }
        _ = reader.projection(owner: owner, conversationPrimary: "delayed", expectedLastMessageID: "old")
        wait(for: [entered], timeout: 1)

        reader.apply([.upsert(newer)], for: owner)
        release.signal()
        reader.waitForPendingPersistence()

        XCTAssertEqual(reader.projection(owner: owner, conversationPrimary: "delayed", expectedLastMessageID: "new"), newer)
        XCTAssertNil(reader.projection(owner: owner, conversationPrimary: "delayed", expectedLastMessageID: "old"))
    }

    func testAccountClearRejectsAnAlreadyRunningPreviewLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = LastChatListSyncPreviewProjection(owner: owner, conversationPrimary: "cleared",
            lastMessageID: "old", text: "Old")
        let writer = LastChatListSyncPreviewStore(directory: directory)
        writer.apply([.upsert(projection)], for: owner)
        writer.waitForPendingPersistence()
        let entered = expectation(description: "disk load before account clear")
        let release = DispatchSemaphore(value: 0)
        let reader = LastChatListSyncPreviewStore(directory: directory, beforeLoading: {
            entered.fulfill(); _ = release.wait(timeout: .now() + 3)
        })
        defer { release.signal() }
        _ = reader.projection(owner: owner, conversationPrimary: "cleared", expectedLastMessageID: "old")
        wait(for: [entered], timeout: 1)

        reader.removeAll(for: owner)
        release.signal()
        reader.waitForPendingPersistence()

        XCTAssertNil(reader.projection(owner: owner, conversationPrimary: "cleared", expectedLastMessageID: "old"))
        let afterClear = LastChatListSyncPreviewStore(directory: directory)
        _ = afterClear.projection(owner: owner, conversationPrimary: "cleared", expectedLastMessageID: "old")
        afterClear.waitForPendingPersistence()
        XCTAssertNil(afterClear.projection(owner: owner, conversationPrimary: "cleared", expectedLastMessageID: "old"))
    }

    private func makeManager(_ requests: Requests? = nil) -> ClientSynchronizationManager {
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        if let requests { manager.syncRequestObserver = { requests.append($0) } }
        managers.append(manager)
        return manager
    }

    private func storeBaseline() {
        for key in ["last_completed_snapshot_stamp", "last_recognized_event_stamp"] {
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization,
                                          key: key, value: baseline)
        }
    }

    private func storedValue(_ key: String) -> String? {
        SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: key)
    }

    private func chat(_ jid: String, type: ClientSynchronizationManager.ConversationType = .regular) throws -> LastChatsStorageItem? {
        let realm = try WRealm.safe()
        realm.refresh()
        return realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey:
            LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: type))
    }

    private func conversation(jid: String, stamp: String, message: String, unread: Int = 0,
                              type: ClientSynchronizationManager.ConversationType = .regular) -> String {
        """
        <conversation jid='\(jid)' type='\(type.rawValue)' stamp='\(stamp)' status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <unread count='\(unread)'/>
            <last-message><message xmlns='jabber:client' from='\(jid)' to='\(owner)' id='\(message)'>
              <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-11-06T10:00:00Z'/>
              <body>\(message)</body>
            </message></last-message>
          </metadata>
        </conversation>
        """
    }

    private func push(stamp: String, conversations: [String]) throws -> XMPPIQ {
        try iq("""
        <iq type='set'><synchronization xmlns='https://xabber.com/protocol/synchronization' stamp='\(stamp)'>
          \(conversations.joined(separator: "\n"))
        </synchronization></iq>
        """)
    }

    private func page(id: String, stamp: String, conversations: [String],
                      index: Int, count: Int, cursor: String) throws -> XMPPIQ {
        try iq("""
        <iq type='result' id='\(id)'><query xmlns='https://xabber.com/protocol/synchronization' stamp='\(stamp)'>
          \(conversations.joined(separator: "\n"))
          <set xmlns='http://jabber.org/protocol/rsm'>
            <first index='\(index)'>first-\(index)</first><last>\(cursor)</last><count>\(count)</count>
          </set>
        </query></iq>
        """)
    }

    private func iq(_ xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
