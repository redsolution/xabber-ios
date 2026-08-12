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
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
    }

    override func tearDown() {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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

    func testInitialBootstrapTransportBypassesBusyPrimaryGateWithUIActionStream() {
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: true,
                primaryBootstrapGateActive: true
            ),
            .uiAction
        )
    }

    @MainActor
    func testFreshEmptyBootstrapCommitTransitionsCommittedSkeletonToEmptyOnce() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatFreshEmptyBootstrap-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let controller = ChatViewController()
        controller.owner = "fresh-empty-owner@example.com"
        controller.jid = "call.me.bot@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(
            id: controller.owner,
            displayName: "Owner"
        )
        controller.opponentSender = Sender(
            id: controller.jid,
            displayName: "Call Me Bot"
        )
        controller.loadViewIfNeeded()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "fresh-empty-bootstrap",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("fresh empty chat must own its bootstrap lease")
        }

        let archiveManager = MessageArchiveManager(withOwner: key.owner)
        let startResult = archiveManager.syncChat(
            XMPPStream(),
            jid: key.jid,
            conversationType: .regular,
            pageSize: 80,
            queryId: lease.queryId,
            callback: nil
        )
        XCTAssertEqual(
            startResult,
            .bootstrapStarted(queryId: lease.queryId)
        )
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: startResult,
            messages: nil,
            archiveManager: archiveManager,
            cancelTransport: {}
        )
        controller.beginInitialBootstrapTracking(
            queryId: lease.queryId,
            timeout: nil
        )

        XCTAssertTrue(archiveManager.read(
            XMPPStream(),
            withIQ: try makeArchiveFinalIQ(
                queryId: lease.queryId,
                complete: true,
                count: 0
            )
        ))
        XCTAssertTrue(waitUntil {
            controller.appliedBootstrapLoadingState == .empty &&
                controller.datasource.isEmpty &&
                !controller.showSkeletonObserver.value
        })

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .empty)
        XCTAssertTrue(controller.datasource.isEmpty)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        guard case .joined(let reopenedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "fresh-empty-reopen",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("reopen must reuse the durable empty receipt")
        }
        XCTAssertEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertTrue(coordinator.releaseInteractiveCommittedJoinReservation(
            key: key,
            queryId: reopenedLease.queryId
        ))
        XCTAssertTrue(coordinator.invalidateCommittedReceipt(
            key: key,
            queryId: reopenedLease.queryId
        ))
    }

    func testNonDurableCommittedEmptyProofSchedulesLatestFollowUp() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "non-durable-empty-owner@example.com",
            jid: "non-durable-empty-peer@example.com",
            conversationType: .regular
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "non-durable-empty",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false,
            resultCount: 0,
            confirmsEmptyConversation: true,
            hasPresentationMaterialization: false
        )

        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        XCTAssertFalse(
            coordinator.readiness(for: key)?.hasDurableCoverage ?? true
        )
        XCTAssertFalse(
            coordinator.readiness(for: key)?.confirmsEmptyConversation ?? true
        )
        XCTAssertEqual(
            coordinator.pendingFollowUpRequest(for: key)?.fingerprint.target,
            .latest,
            "a non-durable page-level empty proof must not strand the skeleton"
        )
        XCTAssertEqual(
            coordinator.pendingFollowUpRequest(for: key)?.purpose,
            .snapshotRepair
        )
    }

    func testDurableMaterializedCommitDoesNotScheduleFollowUp() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "materialized-owner@example.com",
            jid: "materialized-peer@example.com",
            conversationType: .regular
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "materialized-bootstrap",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            resultCount: 1,
            persistedRowsForQuery: 1,
            visibleRowsForConversation: 1,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: true
        )

        XCTAssertTrue(
            coordinator.readiness(for: key)?.hasDurableCoverage ?? false
        )
        XCTAssertEqual(
            coordinator.readiness(for: key)?.persistedVisibleRowCount,
            1
        )
        XCTAssertNil(coordinator.pendingFollowUpRequest(for: key))
    }

    func testDeferredCommittedResultDoesNotUseASecondLegacyReadinessRead() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(
            source.contains("hasPersistenceConfirmedReadiness("),
            "deferred .committed is the same-transaction durable authority"
        )
    }

    func testJoinedCommittedReceiptSurvivesSnapshotInvalidationUntilUIObservationAttaches() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "first-process-owner@example.com",
            jid: "first-process-peer@example.com",
            conversationType: .regular
        )
        guard case .start(let snapshotLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "first-process-snapshot",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("snapshot persistence must own the first lease")
        }
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: snapshotLease.queryId,
            // The page itself reached durable Realm persistence, but the
            // first-process snapshot can already require a follow-up boundary.
            hasDurableCoverage: false,
            resultCount: 1,
            persistedRowsForQuery: 1,
            visibleRowsForConversation: 1
        )

        guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "first-process-interactive-open",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("interactive open must join the committed receipt")
        }
        XCTAssertEqual(joinedLease.queryId, snapshotLease.queryId)

        // The snapshot pump can invalidate its terminal ownership in the exact
        // interval between `acquireOrJoin` and the controller registering its
        // readiness observer. The joined UI must still see the persisted page
        // and its follow-up proof;
        // otherwise it has already skipped starting transport and its committed
        // skeleton has no remaining terminal source.
        XCTAssertTrue(coordinator.invalidateCommittedReceipt(
            key: key,
            queryId: snapshotLease.queryId
        ))

        var observedPhase: ConversationArchiveLoadPhase?
        let observation = coordinator.observe(
            key: key,
            consumesInteractiveCommittedJoin: true
        ) { readiness in
            observedPhase = readiness?.phase
        }
        XCTAssertEqual(observedPhase, .committed)
        XCTAssertEqual(
            coordinator.readiness(for: key)?.persistedVisibleRowCount,
            1
        )
        XCTAssertNotNil(coordinator.cachedCommittedPage(
            key: key,
            queryId: snapshotLease.queryId
        ))

        coordinator.detach(key: key, observation: observation)
        XCTAssertNil(coordinator.readiness(for: key))
    }

    func testAbandonedInteractiveCommittedJoinReleasesItsInvalidationReservation() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "abandoned-owner@example.com",
            jid: "abandoned-peer@example.com",
            conversationType: .regular
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "abandoned-snapshot",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("snapshot persistence must own the first lease")
        }
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false,
            resultCount: 1,
            persistedRowsForQuery: 1,
            visibleRowsForConversation: 1
        )
        guard case .joined = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "abandoned-interactive",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("interactive open must reserve the committed receipt")
        }

        XCTAssertTrue(coordinator.invalidateCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))
        XCTAssertTrue(coordinator.releaseInteractiveCommittedJoinReservation(
            key: key,
            queryId: lease.queryId
        ))
        XCTAssertNil(coordinator.readiness(for: key))
    }

    func testNonDurableSnapshotRepairCommitStartsOneBoundedLatestFollowUp() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "snapshot-only-owner@example.com",
            jid: "snapshot-only-peer@example.com",
            conversationType: .regular
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-only-first",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("snapshot persistence must own the first lease")
        }
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false
        )
        guard case .start(let followUpLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-only-join",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("non-durable receipt must roll into its pending repair")
        }
        XCTAssertEqual(followUpLease.queryId, "snapshot-only-join")
        XCTAssertEqual(followUpLease.targetFingerprint.target, .latest)

        guard case .joined(let duplicateLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-only-duplicate",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the bounded repair must remain single-flight")
        }
        XCTAssertEqual(duplicateLease.queryId, followUpLease.queryId)
        XCTAssertFalse(coordinator.invalidateCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .queued)
    }

    func testRawFinalReleasesMamLaneAndLeaseSurvivesUntilQueryPersistenceTerminates() throws {
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

        let schedulerReleased = expectation(description: "scheduler released at wire terminal")
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
        wait(for: [schedulerReleased], timeout: 1)

        XCTAssertEqual(coordinator.cachedEndPageEvent(key: key, queryId: lease.queryId), final)
        XCTAssertNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))
        releaseLock.lock()
        let releasedBeforePersistence = didReleaseScheduler
        releaseLock.unlock()
        XCTAssertTrue(
            releasedBeforePersistence,
            "raw <fin> must release the wire scheduler resource without waiting for Realm"
        )

        now = now.addingTimeInterval(46)
        coordinator.expireDueAttemptsForTesting()
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "must-not-restart",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let reopenedLease) = reopened else {
            allowPersistence.signal()
            return XCTFail("reopen must join the raw-final persistence lease")
        }
        XCTAssertEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))
        XCTAssertNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))

        allowPersistence.signal()
        XCTAssertTrue(waitUntil {
            coordinator.cachedCommittedPage(key: key, queryId: lease.queryId) != nil
        })
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
        manager.messagePersistenceChunkObserver = nil
        manager.unsubscribeReceiver()
    }

    func testRawFinalReleasesWireBeforeAReadinessObserverCanBlock() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "observer-wire-owner@example.com",
            jid: "observer-wire-peer@example.com",
            conversationType: .regular
        )
        let queryId = "observer-wire-query"
        guard case .start = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }
        coordinator.resolveStart(
            key: key,
            queryId: queryId,
            result: .bootstrapStarted(queryId: queryId),
            messages: nil,
            cancelTransport: {}
        )

        let schedulerReleased = expectation(description: "wire released first")
        coordinator.attachSchedulerCompletion(key: key, queryId: queryId) {
            schedulerReleased.fulfill()
        }
        let observerEntered = expectation(description: "observer entered persistence")
        let releaseObserver = DispatchSemaphore(value: 0)
        let observation = coordinator.observe(key: key) { readiness in
            guard readiness?.phase == .persistence else { return }
            observerEntered.fulfill()
            XCTAssertEqual(releaseObserver.wait(timeout: .now() + 5), .success)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = MessageArchiveEndPageDispatcher.publish(
                self.makeFinalEvent(key: key, queryId: queryId, count: 0)
            )
        }
        wait(for: [observerEntered, schedulerReleased], timeout: 1)
        releaseObserver.signal()
        coordinator.detach(key: key, observation: observation)
    }

    func testRawTransportFailureReleasesMamLaneBeforePartialBatchPersistenceTerminates() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "wire-failure-owner@example.com",
            jid: "wire-failure-peer@example.com",
            conversationType: .regular
        )
        let queryId = "wire-failure-query"
        guard case .start = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        coordinator.resolveStart(
            key: key,
            queryId: queryId,
            result: .bootstrapStarted(queryId: queryId),
            messages: manager,
            cancelTransport: {}
        )

        let schedulerReleased = expectation(description: "wire lane released")
        coordinator.attachSchedulerCompletion(key: key, queryId: queryId) {
            schedulerReleased.fulfill()
        }

        let persistenceStarted = expectation(description: "partial batch flush started")
        let allowPersistence = DispatchSemaphore(value: 0)
        manager.messagePersistenceChunkObserver = { _, _ in
            persistenceStarted.fulfill()
            XCTAssertEqual(allowPersistence.wait(timeout: .now() + 5), .success)
        }
        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: queryId
        ))

        let event = MessageArchiveRequestFailureEvent(
            owner: key.owner,
            queryId: queryId,
            streamKind: .primary,
            reason: .serverError,
            errorDescription: "transport failed",
            pendingQueryCount: 1
        )
        let persistenceTerminal = expectation(description: "failure preparation terminal")
        XCTAssertTrue(MessageArchiveRequestFailurePreparationDispatcher.prepare(event) {
            persistenceTerminal.fulfill()
        })
        wait(for: [persistenceStarted], timeout: 2)
        wait(for: [schedulerReleased], timeout: 0.5)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: queryId))

        allowPersistence.signal()
        wait(for: [persistenceTerminal], timeout: 2)
        manager.messagePersistenceChunkObserver = nil
        manager.unsubscribeReceiver()
    }

    func testTransportTimeoutPublishesRetryAndReleasesWireBeforeCleanupFlush() throws {
        var now = Date(timeIntervalSince1970: 20_000)
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "wire-timeout-owner@example.com",
            jid: "wire-timeout-peer@example.com",
            conversationType: .regular
        )
        let queryId = "wire-timeout-query"
        guard case .start = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 1,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        coordinator.resolveStart(
            key: key,
            queryId: queryId,
            result: .bootstrapStarted(queryId: queryId),
            messages: manager,
            cancelTransport: {}
        )

        let schedulerReleased = expectation(description: "timeout releases wire")
        coordinator.attachSchedulerCompletion(key: key, queryId: queryId) {
            schedulerReleased.fulfill()
        }
        let retryPublished = expectation(description: "timeout publishes retry")
        let retryToken = MessageArchiveRequestFailureDispatcher.register(
            owner: key.owner,
            queryId: queryId,
            delivery: .synchronous
        ) { event in
            XCTAssertEqual(event.reason, .timeout)
            retryPublished.fulfill()
        }

        let persistenceStarted = expectation(description: "cleanup flush started")
        let allowPersistence = DispatchSemaphore(value: 0)
        manager.messagePersistenceChunkObserver = { _, _ in
            persistenceStarted.fulfill()
            XCTAssertEqual(allowPersistence.wait(timeout: .now() + 5), .success)
        }
        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: queryId
        ))

        now = now.addingTimeInterval(2)
        coordinator.expireDueAttemptsForTesting()
        wait(for: [schedulerReleased, retryPublished, persistenceStarted], timeout: 1)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .failed)

        allowPersistence.signal()
        MessageArchiveRequestFailureDispatcher.unregister(retryToken)
        manager.messagePersistenceChunkObserver = nil
        manager.unsubscribeReceiver()
    }

    func testReopenDoesNotDiscardRawFinalPersistenceLeaseWhenRealmFlagsAreAlreadyTrue() throws {
        let controller = ChatViewController()
        controller.owner = "raw-final-reopen-owner@example.com"
        controller.jid = "raw-final-reopen-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        controller.configureDataset()

        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = controller.conversationType
        chat.messageDate = Date(timeIntervalSince1970: 1_753_000_000)
        chat.lastMessageId = "snapshot-message-id"
        chat.syncSnapshotLastArchiveId = "archive-1"
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.setPrimary(withOwner: controller.owner)
        try realm.write {
            realm.add(chat, update: .modified)
        }

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: "raw-final-reopen",
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

        let persistenceStarted = expectation(description: "raw final persistence entered")
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
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: lease.queryId, count: 1)
        ))
        wait(for: [persistenceStarted], timeout: 2)
        XCTAssertNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))

        controller.requestInitialBootstrapArchive()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let leaseSurvivedReopen = coordinator.isActive(key: key, queryId: lease.queryId)
        XCTAssertTrue(
            leaseSurvivedReopen,
            "raw Realm readiness flags must not discard an archive transaction still persisting"
        )
        XCTAssertEqual(controller.initialBootstrapQueryId, lease.queryId)
        XCTAssertTrue(controller.isInitialBootstrapInFlight)

        let persistenceCommitted = expectation(
            description: "raw final persistence committed after reopen"
        )
        let readinessToken = coordinator.observe(key: key) { readiness in
            if readiness?.phase == .committed {
                persistenceCommitted.fulfill()
            }
        }
        allowPersistence.signal()
        wait(for: [persistenceCommitted], timeout: 2)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        coordinator.detach(key: key, observation: readinessToken)
        controller.performTerminalChatResourceTeardownForTesting()
        manager.messagePersistenceChunkObserver = nil
        manager.unsubscribeReceiver()
    }

    func testKnownRemoteSnapshotWithReadinessFlagsButNoLocalRowsRequiresRepair() throws {
        let controller = ChatViewController()
        controller.owner = "inconsistent-owner@example.com"
        controller.jid = "inconsistent-peer@example.com"
        controller.conversationType = .regular

        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = controller.conversationType
        chat.messageDate = Date(timeIntervalSince1970: 1_753_000_000)
        chat.lastMessageId = "known-remote-message"
        chat.syncSnapshotLastArchiveId = "known-remote-archive"
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.setPrimary(withOwner: controller.owner)
        try realm.write {
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = "known-remote-archive"
            archiveState.lastSnapshotMessageId = "known-remote-message"
        }

        XCTAssertEqual(controller.localHistoryMessageCountForBootstrap(), 0)
        XCTAssertTrue(
            controller.currentBootstrapRequiresArchiveConfirmation(),
            "known remote history without a local timeline must be repaired instead of shown as empty"
        )
    }

    func testSyncChatStartsConsistencyRepairForReadinessFlagsWithKnownBoundaryAndNoLocalRows() throws {
        let owner = "inconsistent-sync-owner@example.com"
        let peer = "inconsistent-sync-peer@example.com"
        let queryId = "known-boundary-consistency-repair"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = peer
        chat.conversationType = .regular
        chat.messageDate = Date(timeIntervalSince1970: 1_753_000_000)
        chat.lastMessageId = "known-remote-message"
        chat.syncSnapshotLastArchiveId = "known-remote-archive"
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.setPrimary(withOwner: owner)
        try realm.write {
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: peer,
                conversationType: .regular,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = "known-remote-archive"
            archiveState.lastSnapshotMessageId = "known-remote-message"
        }

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: peer,
                conversationType: .regular,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId),
            "flags=true with a known remote boundary and zero local rows is inconsistent and must start repair"
        )
    }

    func testInitialBootstrapPersistenceTimeoutTransitionsToRetryWithoutCommittingReadiness() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "persistence-timeout-owner@example.com",
            jid: "persistence-timeout-peer@example.com",
            conversationType: .regular
        )
        let queryId = "bootstrap-persistence-timeout"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = key.owner
        chat.jid = key.jid
        chat.conversationType = .regular
        chat.messageDate = Date(timeIntervalSince1970: 1_753_000_000)
        chat.isSynced = false
        chat.isInitialArchiveLoaded = false
        chat.setPrimary(withOwner: key.owner)
        try realm.write {
            realm.add(chat, update: .modified)
        }

        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("test setup must own the bootstrap lease")
        }
        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        coordinator.resolveStart(
            key: key,
            queryId: queryId,
            result: .bootstrapStarted(queryId: queryId),
            messages: manager,
            cancelTransport: {}
        )

        let persistenceStarted = expectation(description: "bootstrap persistence started")
        let allowPersistence = DispatchSemaphore(value: 0)
        manager.messagePersistenceChunkObserver = { _, _ in
            persistenceStarted.fulfill()
            XCTAssertEqual(allowPersistence.wait(timeout: .now() + 5), .success)
        }
        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: queryId
        ))

        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: queryId, count: 1)
        ))
        wait(for: [persistenceStarted], timeout: 2)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .persistence)

        coordinator.expirePersistenceAttemptForTesting(
            key: key,
            queryId: lease.queryId
        )
        let failedReadiness = try XCTUnwrap(coordinator.readiness(for: key))
        XCTAssertEqual(failedReadiness.phase, .failed)
        XCTAssertFalse(failedReadiness.hasDurableCoverage)
        XCTAssertFalse(failedReadiness.confirmsEmptyConversation)
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 0,
                isSynced: false,
                isInitialArchiveLoaded: false,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: true,
                archiveReadiness: failedReadiness
            )),
            .failure(fallback: .empty)
        )

        realm.refresh()
        XCTAssertFalse(chat.isInitialArchiveLoaded)
        XCTAssertFalse(chat.isSynced)

        allowPersistence.signal()
        XCTAssertTrue(waitUntil {
            !manager.hasPendingMessages(forQueryId: queryId)
        })
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .failed)
        manager.messagePersistenceChunkObserver = nil
        manager.unsubscribeReceiver()
    }

    func testPersistenceCommitClaimWinsOverRacingTimeout() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "commit-claim-owner@example.com",
            jid: "commit-claim-peer@example.com",
            conversationType: .regular
        )
        let queryId = "bootstrap-commit-claim"
        guard case .start(let lease) = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        coordinator.resolveStart(
            key: key,
            queryId: queryId,
            result: .bootstrapStarted(queryId: queryId),
            messages: manager,
            cancelTransport: {}
        )

        let commitClaimed = expectation(description: "persistence commit claimed")
        let allowCommit = DispatchSemaphore(value: 0)
        coordinator.persistenceCommitClaimObserver = { claimedQueryId in
            guard claimedQueryId == queryId else { return }
            commitClaimed.fulfill()
            XCTAssertEqual(allowCommit.wait(timeout: .now() + 5), .success)
        }

        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: queryId
        ))
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: queryId, count: 1)
        ))
        wait(for: [commitClaimed], timeout: 2)

        coordinator.expirePersistenceAttemptForTesting(
            key: key,
            queryId: lease.queryId
        )
        XCTAssertEqual(
            coordinator.readiness(for: key)?.phase,
            .persistence,
            "a timeout cannot steal a transaction after persistence claimed its commit"
        )

        allowCommit.signal()
        XCTAssertTrue(waitUntil {
            coordinator.readiness(for: key)?.phase == .committed
        })
        manager.unsubscribeReceiver()
    }

    func testPersistenceTimeoutPublishesRetryBeforeBlockedCleanupFinishes() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "retry-before-cleanup-owner@example.com",
            jid: "retry-before-cleanup-peer@example.com",
            conversationType: .regular
        )
        let queryId = "bootstrap-retry-before-cleanup"
        guard case .start = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeMessageManager(owner: key.owner)
        manager.archiveQueryIdPersistenceResolver = { $0 == queryId }
        coordinator.resolveStart(
            key: key,
            queryId: queryId,
            result: .bootstrapStarted(queryId: queryId),
            messages: manager,
            cancelTransport: {}
        )

        let persistenceStarted = expectation(description: "persistence is blocked")
        let allowPersistence = DispatchSemaphore(value: 0)
        manager.messagePersistenceChunkObserver = { _, _ in
            persistenceStarted.fulfill()
            XCTAssertEqual(allowPersistence.wait(timeout: .now() + 5), .success)
        }
        manager.receiveArchived(try makeArchivedMessage(
            owner: key.owner,
            peer: key.jid,
            index: 1,
            queryId: queryId
        ))

        let retryPublished = expectation(description: "retry published immediately")
        let retryToken = MessageArchiveRequestFailureDispatcher.register(
            owner: key.owner,
            queryId: queryId,
            delivery: .synchronous
        ) { event in
            XCTAssertEqual(event.reason, .timeout)
            retryPublished.fulfill()
        }

        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: queryId, count: 1)
        ))
        wait(for: [persistenceStarted], timeout: 2)
        coordinator.expirePersistenceAttemptForTesting(key: key, queryId: queryId)
        wait(for: [retryPublished], timeout: 0.5)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .failed)

        allowPersistence.signal()
        MessageArchiveRequestFailureDispatcher.unregister(retryToken)
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

    func testInteractiveBootstrapRunsNextAndReleasesMamLaneAtWireTerminalAcrossHundredsOfRepairs() {
        let scheduler = AccountXMPPTaskScheduler(configuration: .test(defaultCooldown: 0))
        let currentStarted = expectation(description: "current MAM task started")
        let interactiveStarted = expectation(description: "interactive bootstrap started")
        let firstRepairStarted = expectation(description: "first queued repair started")
        let stateLock = NSLock()
        var finishCurrent: (() -> Void)?
        var finishInteractiveWire: (() -> Void)?
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
            finishInteractiveWire = finish
            interactiveStarted.fulfill()
        }

        finishCurrent?()
        wait(for: [interactiveStarted], timeout: 1)
        stateLock.lock()
        let repairsBeforeWireTerminal = repairStartCount
        stateLock.unlock()
        XCTAssertEqual(repairsBeforeWireTerminal, 0)

        // The scheduler owns only the transport lane. Persistence may continue
        // independently after raw <fin> releases this completion.
        finishInteractiveWire?()
        wait(for: [firstRepairStarted], timeout: 1)
        stateLock.lock()
        let repairsAfterWireTerminal = repairStartCount
        stateLock.unlock()
        XCTAssertEqual(repairsAfterWireTerminal, 1)

        scheduler.reset()
        finishFirstRepair?()
    }

    func testRegularIdleBootstrapDefersCoverageUntilQueryPersistenceCommit() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/MessageArchiveManager.swift"
            ),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(
            source.range(of: "private func startNextRegularIdleBackfillIfNeeded()")
        )
        let nextMethodStart = try XCTUnwrap(
            source.range(
                of: "internal func archiveRequestGenerationSnapshot()",
                range: methodStart.upperBound..<source.endIndex
            )
        )
        let methodSource = String(
            source[methodStart.lowerBound..<nextMethodStart.lowerBound]
        )

        XCTAssertTrue(
            methodSource.contains("beginArchiveQueryBatch(queryId: queryId)"),
            "idle bootstrap must register a query-scoped persistence batch before transport"
        )
        XCTAssertTrue(
            methodSource.contains("deferCoverageCommitUntilConsumerProof: true"),
            "raw idle-bootstrap <fin> must not mutate archive coverage or readiness"
        )
        XCTAssertTrue(
            methodSource.contains("finishArchiveQueryBatchAsync(") ||
                methodSource.contains("flushQueryMessagesAsync("),
            "idle bootstrap must await its query-scoped Realm flush"
        )
        XCTAssertTrue(
            methodSource.contains("commitAfterPersistence("),
            "idle bootstrap must commit coverage only from persistence terminal"
        )
        XCTAssertTrue(
            methodSource.contains(
                "releaseArchiveQueryBatchIngressExpectation("
            ),
            "idle persistence timeout must not leave a parked archive batch blocking later work"
        )
        XCTAssertFalse(
            methodSource.contains("callback: finishIdleAttempt"),
            "raw <fin> callback must not be the persistence/readiness terminal"
        )
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

    private func makeArchiveFinalIQ(
        queryId: String,
        complete: Bool,
        count: Int
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(count)</count>
              <first></first>
              <last></last>
            </set>
          </fin>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
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
