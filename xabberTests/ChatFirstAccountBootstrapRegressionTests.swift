import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

/// Focused regression manifest for the first-account chat bootstrap incident.
///
/// This standalone source is included in the xabberTests target; executable
/// integration coverage also remains beside the existing chat and
/// MessageManager fixtures so the incident contract stays discoverable.
final class ChatFirstAccountBootstrapRegressionTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatFirstAccountBootstrapRegressionTests-\(name)"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
    }

    override func tearDown() {
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testForcedBlockingStateRequiresACommittedSkeletonFrame() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .blockingArchive,
                hasCommittedContent: false,
                forceRender: true,
                hasCommittedSkeletonRows: false
            ),
            .apply
        )
    }

    func testInitialBootstrapTransportUsesPrimaryStreamThroughBootstrapGate() {
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: true,
                primaryBootstrapGateActive: true
            ),
            .primaryAccount
        )
    }

    func testRawFinalRemainsTimeoutEligibleUntilQueryPersistenceTerminates() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "raw-final-owner@example.com",
            jid: "raw-final-peer@example.com",
            conversationType: .regular
        )
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: "raw-final-persisting",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == lease.queryId }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: manager,
            cancelTransport: {}
        )

        let persistenceStarted = expectation(description: "query persistence entered")
        let allowPersistence = DispatchSemaphore(value: 0)
        manager.messagePersistenceChunkObserver = { _, _ in
            persistenceStarted.fulfill()
            allowPersistence.wait()
        }
        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: lease.queryId
        ))

        let schedulerReleased = expectation(description: "scheduler released after persistence")
        let releaseLock = NSLock()
        var didReleaseScheduler = false
        coordinator.attachSchedulerCompletion(key: key, queryId: lease.queryId) {
            releaseLock.lock()
            didReleaseScheduler = true
            releaseLock.unlock()
            schedulerReleased.fulfill()
        }

        let final = makeFinalEvent(key: key, queryId: lease.queryId, count: 1)
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(final))
        wait(for: [persistenceStarted], timeout: 2)

        XCTAssertEqual(coordinator.cachedEndPageEvent(key: key, queryId: lease.queryId), final)
        XCTAssertNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))
        releaseLock.lock()
        let releasedBeforePersistence = didReleaseScheduler
        releaseLock.unlock()
        XCTAssertFalse(releasedBeforePersistence)

        now = now.addingTimeInterval(46)
        coordinator.expireDueAttemptsForTesting()
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "must-not-restart",
            timeout: 45
        ) { _, _, _ in }
        guard case .terminal(let failure) = reopened else {
            allowPersistence.signal()
            return XCTFail("persisting raw final must remain protected by timeout")
        }
        XCTAssertEqual(failure.reason, .timeout)

        allowPersistence.signal()
        wait(for: [schedulerReleased], timeout: 2)
        manager.messagePersistenceChunkObserver = nil
        manager.unsubscribeReceiver()
    }

    func testReopenReceivesPostPersistenceCommittedPage() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "reopen-owner@example.com",
            jid: "reopen-peer@example.com",
            conversationType: .regular
        )
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: "reopen-committed-page",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == lease.queryId }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: manager,
            cancelTransport: {}
        )
        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: lease.queryId
        ))

        let final = makeFinalEvent(key: key, queryId: lease.queryId, count: 1)
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(final))
        XCTAssertTrue(waitUntil {
            coordinator.cachedCommittedPage(key: key, queryId: lease.queryId) != nil
        })

        let committed = try XCTUnwrap(
            coordinator.cachedCommittedPage(key: key, queryId: lease.queryId)
        )
        XCTAssertEqual(committed.event, final)
        XCTAssertEqual(committed.completion.persistenceSummary.persistedRows, 1)

        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "reopen-must-join",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let reopenedLease) = reopened else {
            return XCTFail("reopened controller must join the committed operation")
        }
        XCTAssertEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertEqual(
            coordinator.cachedCommittedPage(key: key, queryId: reopenedLease.queryId),
            committed
        )

        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
        let sourceRemoved = expectation(description: "persistence source removed")
        ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
            owner: key.owner,
            queryId: lease.queryId,
            completion: { sourceRemoved.fulfill() }
        )
        wait(for: [sourceRemoved], timeout: 2)
        manager.unsubscribeReceiver()
    }

    func testPersistedBootstrapPageExpandsSingleSnapshotRowIntoLatestWindow() throws {
        let owner = "snapshot-owner@example.com"
        let peer = "snapshot-peer@example.com"
        let snapshotQueryId = "snapshot-page"
        let bootstrapQueryId = "bootstrap-page"
        let manager = makeMessageManager(owner: owner)
        manager.archiveQueryIdPersistenceResolver = {
            $0 == snapshotQueryId || $0 == bootstrapQueryId
        }

        manager.beginArchiveQueryBatch(queryId: snapshotQueryId)
        manager.receiveArchived(try makeArchivedMessage(
            owner: owner,
            peer: peer,
            index: 80,
            queryId: snapshotQueryId
        ))
        XCTAssertEqual(
            manager.finishArchiveQueryBatchSummary(queryId: snapshotQueryId).persistedRows,
            1
        )

        manager.beginArchiveQueryBatch(queryId: bootstrapQueryId)
        for index in 1...80 {
            manager.receiveArchived(try makeArchivedMessage(
                owner: owner,
                peer: peer,
                index: index,
                queryId: bootstrapQueryId
            ))
        }
        let summary = manager.finishArchiveQueryBatchSummary(queryId: bootstrapQueryId)

        XCTAssertEqual(summary.savedNew, 79)
        XCTAssertEqual(summary.updatedExisting, 1)
        XCTAssertEqual(summary.persistedRows, 80)

        let realm = try WRealm.safe()
        let provider = ChatLocalHistoryPageProvider(
            realm: realm,
            owner: owner,
            jid: peer,
            conversationType: .regular
        )
        XCTAssertEqual(
            provider.latest(limit: 80).count,
            80,
            "the committed initial page must replace the one-row snapshot window"
        )

        manager.unsubscribeReceiver()
    }

    @MainActor
    func testTrustedBootstrapRefreshReopensLatestAfterSingleSnapshotFrameWasCommitted() throws {
        let owner = "refresh-owner@example.com"
        let peer = "refresh-peer@example.com"
        let snapshotQueryId = "refresh-snapshot-page"
        let bootstrapQueryId = "refresh-bootstrap-page"
        let manager = makeMessageManager(owner: owner)
        manager.archiveQueryIdPersistenceResolver = {
            $0 == snapshotQueryId || $0 == bootstrapQueryId
        }

        manager.beginArchiveQueryBatch(queryId: snapshotQueryId)
        manager.receiveArchived(try makeArchivedMessage(
            owner: owner,
            peer: peer,
            index: 80,
            queryId: snapshotQueryId
        ))
        XCTAssertEqual(
            manager.finishArchiveQueryBatchSummary(queryId: snapshotQueryId).persistedRows,
            1
        )

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = peer
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: peer, displayName: "Peer")
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.configureDataset()
        controller.beginInitialBootstrapTracking(queryId: bootstrapQueryId, timeout: nil)
        controller.allowsStaleLocalHistoryDuringInitialBootstrap = true

        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: peer,
                owner: owner,
                conversationType: .regular
            )
        ))
        XCTAssertTrue(controller.prepareInitialLocalFirstFrame(
            chatInstance: chat,
            performPendingOpenMessageRequest: false
        ))
        XCTAssertTrue(waitUntil {
            if case .committed = controller.initialLocalFirstFramePhase {
                return controller.virtualTimelineState.residentPrimaryKeys.count == 1
            }
            return false
        })

        manager.beginArchiveQueryBatch(queryId: bootstrapQueryId)
        for index in 1...80 {
            manager.receiveArchived(try makeArchivedMessage(
                owner: owner,
                peer: peer,
                index: index,
                queryId: bootstrapQueryId
            ))
        }
        XCTAssertEqual(
            manager.finishArchiveQueryBatchSummary(queryId: bootstrapQueryId).persistedRows,
            80
        )

        XCTAssertTrue(controller.refreshInitialBootstrapTimelineAfterPersistenceIfNeeded(
            queryId: bootstrapQueryId,
            hasPersistedPageContent: true
        ))
        XCTAssertTrue(
            waitUntil {
                controller.virtualTimelineState.residentPrimaryKeys.count == 80
            },
            "the trusted persistence barrier must invalidate the already committed one-row frame"
        )

        controller.performTerminalChatResourceTeardownForTesting()
        manager.unsubscribeReceiver()
    }

    func testInteractiveBootstrapRunsNextAndHoldsMamLaneAcrossHundredsOfRepairs() {
        let scheduler = AccountXMPPTaskScheduler(configuration: .test(defaultCooldown: 0))
        let currentStarted = expectation(description: "current MAM task started")
        let interactiveStarted = expectation(description: "interactive bootstrap started")
        let firstRepairStarted = expectation(description: "first queued repair started")
        let stateLock = NSLock()
        var finishCurrent: (() -> Void)?
        var finishInteractivePersistence: (() -> Void)?
        var finishFirstRepair: (() -> Void)?
        var repairStartCount = 0

        scheduler.enqueue(
            priority: .background,
            resource: .mamArchive,
            deduplicationKey: "current-mam"
        ) { finish in
            finishCurrent = finish
            currentStarted.fulfill()
        }
        wait(for: [currentStarted], timeout: 1)

        for index in 0..<300 {
            scheduler.enqueue(
                priority: .background,
                resource: .mamArchive,
                deduplicationKey: "repair-\(index)"
            ) { finish in
                stateLock.lock()
                repairStartCount += 1
                let isFirst = repairStartCount == 1
                if isFirst {
                    finishFirstRepair = finish
                }
                stateLock.unlock()
                if isFirst {
                    firstRepairStarted.fulfill()
                } else {
                    finish()
                }
            }
        }
        scheduler.enqueue(
            priority: .interactive,
            resource: .mamArchive,
            deduplicationKey: "initial-chat-bootstrap"
        ) { finish in
            finishInteractivePersistence = finish
            interactiveStarted.fulfill()
        }

        finishCurrent?()
        wait(for: [interactiveStarted], timeout: 1)
        stateLock.lock()
        let repairsBeforePersistence = repairStartCount
        stateLock.unlock()
        XCTAssertEqual(repairsBeforePersistence, 0)

        // Production invokes this completion only from the query persistence
        // terminal, so the shared MAM resource remains owned until this point.
        finishInteractivePersistence?()
        wait(for: [firstRepairStarted], timeout: 1)
        stateLock.lock()
        let repairsAfterPersistence = repairStartCount
        stateLock.unlock()
        XCTAssertEqual(repairsAfterPersistence, 1)

        scheduler.reset()
        finishFirstRepair?()
    }

    func testDetachedBackgroundPrefetchHoldsEightyOneRowsUntilFinalAndPersistsOneBoundedBatch() throws {
        let owner = "background-prefetch-owner@example.com"
        let peer = "background-prefetch-peer@example.com"
        let queryId = "MAM next history: background-prefetch"
        let manager = makeMessageManager(owner: owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        let terminal = expectation(description: "detached persistence terminal")
        let transaction = ChatDetachedRemoteHistoryPersistenceTransaction(
            owner: owner,
            jid: peer,
            conversationType: .regular,
            queryIds: [queryId],
            terminal: { terminalQueryId in
                XCTAssertEqual(terminalQueryId, queryId)
                terminal.fulfill()
            }
        )
        transaction.registerPersistenceSource(manager, queryId: queryId)

        for index in 1...81 {
            manager.receiveArchived(try makeArchivedMessage(
                owner: owner,
                peer: peer,
                index: index,
                queryId: queryId
            ))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        XCTAssertTrue(manager.isArchiveQueryBatchActive(queryId: queryId))
        XCTAssertEqual(manager.messagePersistenceChunkSizes, [])
        XCTAssertEqual(try WRealm.safe().objects(MessageStorageItem.self).count, 0)
        XCTAssertEqual(
            manager.performMessageQueueSync {
                manager.queuedMessages.filter { $0.queryId == queryId }.count
            },
            81,
            "archive results must not enter ordinary one-row drain before raw <fin>"
        )

        let state = MessageArchivePageEndState(
            queryExhausted: false,
            archiveEnded: false,
            persistedMessageCount: 0
        )
        transaction.requestCallbacks.onEndPage?(queryId, state, "archive-81", "archive-1", 81)
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(manager.messagePersistenceChunkSizes, [81])
        XCTAssertTrue(manager.messagePersistenceChunkSizes.allSatisfy { $0 <= 100 })
        XCTAssertFalse(manager.isArchiveQueryBatchActive(queryId: queryId))
        XCTAssertFalse(manager.hasPendingMessages(forQueryId: queryId))
        XCTAssertEqual(try WRealm.safe().objects(MessageStorageItem.self).count, 81)

        transaction.requestCallbacks.onEndPage?(queryId, state, "archive-81", "archive-1", 81)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(manager.messagePersistenceChunkSizes, [81])
        manager.unsubscribeReceiver()
    }

    func testDetachedBackgroundPrefetchFailureFlushesPartialBatchBeforeTerminalAndUnregisters() throws {
        let owner = "background-failure-owner@example.com"
        let peer = "background-failure-peer@example.com"
        let queryId = "MAM next history: background-failure"
        let manager = makeMessageManager(owner: owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        let terminal = expectation(description: "failure terminal after persistence")
        let transaction = ChatDetachedRemoteHistoryPersistenceTransaction(
            owner: owner,
            jid: peer,
            conversationType: .regular,
            queryIds: [queryId],
            terminal: { terminalQueryId in
                XCTAssertEqual(terminalQueryId, queryId)
                terminal.fulfill()
            }
        )
        transaction.registerPersistenceSource(manager, queryId: queryId)
        for index in 1...5 {
            manager.receiveArchived(try makeArchivedMessage(
                owner: owner,
                peer: peer,
                index: index,
                queryId: queryId
            ))
        }
        let failure = MessageArchiveRequestFailureEvent(
            owner: owner,
            queryId: queryId,
            streamKind: .uiAction,
            reason: .uiActionDisconnect,
            errorDescription: "connection unavailable",
            pendingQueryCount: 1
        )
        let preparationFinished = expectation(description: "failure preparation persisted")

        XCTAssertTrue(MessageArchiveRequestFailurePreparationDispatcher.prepare(failure) {
            XCTAssertFalse(manager.isArchiveQueryBatchActive(queryId: queryId))
            XCTAssertEqual(try? WRealm.safe().objects(MessageStorageItem.self).count, 5)
            preparationFinished.fulfill()
            _ = MessageArchiveRequestFailureDispatcher.publish(failure)
        })

        wait(for: [preparationFinished, terminal], timeout: 3)
        XCTAssertEqual(manager.messagePersistenceChunkSizes, [5])
        XCTAssertFalse(manager.hasPendingMessages(forQueryId: queryId))

        transaction.requestCallbacks.onEndPage?(
            queryId,
            MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 0
            ),
            "archive-5",
            "archive-1",
            5
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(manager.messagePersistenceChunkSizes, [5])
        manager.unsubscribeReceiver()
    }

    private func makeMessageManager(owner: String) -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        return manager
    }

    private func makeArchivedMessage(
        owner: String,
        peer: String,
        index: Int,
        queryId: String
    ) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message to='\(owner)' from='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)' id='archive-\(index)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(peer)' to='\(owner)' type='chat' id='message-\(index)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='archive-\(index)'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='message-\(index)'/>
                <body>regression</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-07-20T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        return try XMPPMessage(from: root)
    }

    private func makeFinalEvent(
        key: ChatInitialBootstrapRequestKey,
        queryId: String,
        count: Int
    ) -> MessageArchiveEndPageEvent {
        MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: count
            ),
            first: count > 0 ? "archive-1" : "",
            last: count > 0 ? "archive-\(count)" : "",
            count: count,
            streamKind: .primary,
            source: .localCallback
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
