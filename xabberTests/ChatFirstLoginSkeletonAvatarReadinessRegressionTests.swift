import XCTest
import UIKit
import RealmSwift
import XMPPFramework
@testable import xabber

/// Follow-up coverage for the authenticated first-login replay where the
/// navigation fallback committed skeleton rows, local history was already
/// durable, and no terminal content frame replaced the skeleton.
@MainActor
final class ChatFirstLoginSkeletonAvatarReadinessRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
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
        super.tearDown()
    }

    func testCommittedSnapshotReceiptSurvivesPumpAndPresentationAcknowledgements() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = makeKey(suffix: "late-join")
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-before-open",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("snapshot repair must own the first lease")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )

        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: lease.queryId, count: 0)
        ))
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        XCTAssertNotNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))

        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))
        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ), "snapshot-pump and UI acknowledgements must be idempotent")

        let lateOpen = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "must-not-create-duplicate",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        )
        guard case .joined(let joinedLease) = lateOpen else {
            return XCTFail("late chat open must join the committed receipt")
        }
        XCTAssertEqual(joinedLease.queryId, lease.queryId)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        XCTAssertNotNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))
    }

    func testNewSnapshotInvalidatesOnlyCommittedReceipt() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = makeKey(suffix: "new-boundary")
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-old-boundary",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("snapshot repair must own the first lease")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )

        XCTAssertFalse(coordinator.invalidateCommittedReceipt(key: key))
        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))

        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: lease.queryId, count: 0)
        ))
        XCTAssertTrue(coordinator.invalidateCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))
        XCTAssertNil(coordinator.readiness(for: key))

        guard case .start(let replacement) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-new-boundary",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("a changed boundary must reserve one replacement lease")
        }
        XCTAssertNotEqual(replacement.queryId, lease.queryId)
    }

    func testNonDurableCommitAcknowledgementAllowsOneFreshFollowUpLease() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = makeKey(suffix: "non-durable-follow-up")
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-incomplete",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the incomplete snapshot must own its lease")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false
        )
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        XCTAssertFalse(coordinator.readiness(for: key)?.hasDurableCoverage ?? true)
        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))
        XCTAssertNil(coordinator.readiness(for: key))

        guard case .start(let followUp) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-follow-up",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("non-durable proof must not absorb the follow-up")
        }
        XCTAssertNotEqual(followUp.queryId, lease.queryId)
    }

    func testLateResolveStartCannotReattachResourcesToAcknowledgedReceipt() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = makeKey(suffix: "late-resolve")
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "fast-final",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the first request must own its lease")
        }
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: lease.queryId, count: 0)
        ))
        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))

        let manager = MessageManager(withOwner: key.owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: manager,
            cancelTransport: {}
        )

        var didReplayStart = false
        var replayedMessages: MessageManager? = manager
        guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "must-join-receipt",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, messages in
                didReplayStart = true
                replayedMessages = messages
            }
        ) else {
            return XCTFail("late open must still join the durable receipt")
        }
        XCTAssertEqual(joinedLease.queryId, lease.queryId)
        XCTAssertTrue(didReplayStart)
        XCTAssertNil(replayedMessages)
        XCTAssertNotNil(coordinator.cachedCommittedPage(
            key: key,
            queryId: lease.queryId
        ))
    }

    func testCommittedReceiptReleasesHeavyPersistenceResourcesBeforeAnyConsumerAcknowledges() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = makeKey(suffix: "commit-resource-release")
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "consumer-detached-before-commit",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the persistence transaction must own its lease")
        }

        let manager = MessageManager(withOwner: key.owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        coordinator.preparePersistenceSource(
            key: key,
            queryId: lease.queryId,
            messages: manager
        )
        XCTAssertTrue(coordinator.hasRetainedResourcesForTesting(
            key: key,
            queryId: lease.queryId
        ))

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true
        )

        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        XCTAssertNotNil(coordinator.cachedCommittedPage(key: key, queryId: lease.queryId))
        XCTAssertFalse(coordinator.hasRetainedResourcesForTesting(
            key: key,
            queryId: lease.queryId
        ), "terminal commit must leave only the lightweight readiness receipt")

        guard case .joined(let lateLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "late-consumer",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the released receipt must remain joinable")
        }
        XCTAssertEqual(lateLease.queryId, lease.queryId)
    }

    func testAccountPurgePreventsReceiptReuseAfterRelogin() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = makeKey(suffix: "account-relogin")
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "old-account-session",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the old account session must own its lease")
        }
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            makeFinalEvent(key: key, queryId: lease.queryId, count: 0)
        ))
        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: key,
            queryId: lease.queryId
        ))

        coordinator.purge(owner: key.owner)
        XCTAssertNil(coordinator.readiness(for: key))
        guard case .start(let reloginLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "new-account-session",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("re-login must not join archive proof from the deleted account")
        }
        XCTAssertNotEqual(reloginLease.queryId, lease.queryId)
    }

    func testKnownBoundaryDurableEmptyReceiptIsReusedUntilFingerprintChanges() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatFirstLoginSkeletonAvatarReadinessRegressionTests-fingerprint-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "receipt-fingerprint-owner@example.com"
        let peer = "receipt-fingerprint-peer@example.com"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: peer,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = peer
        chat.conversationType = .regular
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.syncSnapshotLastArchiveId = "500"
        try realm.write {
            realm.add(chat)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: peer,
                conversationType: .regular,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = "500"
            archiveState.lastSnapshotMessageId = "snapshot-message-500"
        }
        let committedFingerprint = try XCTUnwrap(
            MessageArchiveManager.currentConversationArchiveBoundaryFingerprint(
                owner: owner,
                jid: peer,
                conversationType: .regular
            )
        )
        let readiness = ConversationArchiveReadiness(
            phase: .committed,
            hasDurableCoverage: true,
            confirmsEmptyConversation: true,
            persistedVisibleRowCount: 0,
            boundaryFingerprint: committedFingerprint
        )
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = peer
        controller.conversationType = .regular
        let key = ChatInitialBootstrapRequestKey(
            owner: owner,
            jid: peer,
            conversationType: .regular
        )
        guard case .start(let lease) = ChatInitialBootstrapRequestCoordinator.shared.acquireOrJoin(
            key: key,
            proposedQueryId: "known-boundary-receipt",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the retained receipt fixture must reserve a lease")
        }
        ChatInitialBootstrapRequestCoordinator.shared.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            boundaryFingerprint: committedFingerprint
        )

        XCTAssertTrue(controller.currentBootstrapRequiresArchiveConfirmation())
        XCTAssertTrue(controller.committedArchiveReceiptMatchesCurrentBoundary(readiness))
        XCTAssertFalse(controller.shouldInvalidateCommittedArchiveReceipt(
            readiness,
            requiresArchiveConfirmation: true
        ), "known boundary alone must not invalidate confirmed empty proof")

        try realm.write {
            // Reproduce the inconsistent state left by older code: readiness
            // flags are true even though a newer known remote boundary has no
            // local rows yet.
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.syncSnapshotLastArchiveId = "900"
            let archiveState = try XCTUnwrap(realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: peer,
                    owner: owner,
                    conversationType: .regular
                )
            ))
            archiveState.lastSnapshotArchiveId = "900"
            archiveState.lastSnapshotMessageId = "snapshot-message-900"
        }
        XCTAssertFalse(controller.committedArchiveReceiptMatchesCurrentBoundary(readiness))
        XCTAssertTrue(controller.shouldInvalidateCommittedArchiveReceipt(
            readiness,
            requiresArchiveConfirmation: true
        ))
        let effectiveReadiness = try XCTUnwrap(controller.archiveReadinessForBootstrap(
            localMessageCount: 0,
            chatInstance: chat
        ))
        XCTAssertEqual(effectiveReadiness.phase, .queued)
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 0,
                isSynced: chat.isSynced,
                isInitialArchiveLoaded: chat.isInitialArchiveLoaded,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false,
                archiveReadiness: effectiveReadiness
            )),
            .blockingArchive,
            "stale proof plus legacy true flags must never publish empty"
        )
    }

    func testDeferredCommitPublishesAtomicPostCommitBoundaryFingerprint() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatFirstLoginSkeletonAvatarReadinessRegressionTests-post-commit-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "post-commit-fingerprint-owner@example.com"
        let peer = "post-commit-fingerprint-peer@example.com"
        let queryId = "post-commit-fingerprint-query"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: peer,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = peer
        chat.conversationType = .regular
        chat.isSynced = false
        chat.isInitialArchiveLoaded = false
        try realm.write {
            realm.add(chat)
        }
        XCTAssertNil(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: peer,
                owner: owner,
                conversationType: .regular
            )
        ))

        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        XCTAssertEqual(
            manager.syncChat(
                stream,
                jid: peer,
                conversationType: .regular,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>0</count>
            </set>
          </fin>
        </iq>
        """, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        XCTAssertTrue(manager.read(stream, withIQ: XMPPIQ(from: root)))
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committed
        )

        let committedFingerprint = try XCTUnwrap(
            manager.consumeCommittedArchiveBoundaryFingerprint(queryId: queryId)
        )
        let currentFingerprint = try XCTUnwrap(
            MessageArchiveManager.currentConversationArchiveBoundaryFingerprint(
                owner: owner,
                jid: peer,
                conversationType: .regular
            )
        )
        XCTAssertTrue(committedFingerprint.archiveStateExists)
        XCTAssertEqual(committedFingerprint, currentFingerprint)
        XCTAssertNil(manager.consumeCommittedArchiveBoundaryFingerprint(queryId: queryId))
    }

    func testTerminalReceiptReconciliationDoesNotConsumeRealFollowUpBudget() {
        let reconciliation = SnapshotRepairFollowUpBudgetPolicy.decision(
            requiresFollowUp: true,
            currentConsumedCount: 0,
            consumesBudget: false
        )
        XCTAssertTrue(reconciliation.shouldSchedule)
        XCTAssertFalse(reconciliation.didExhaust)
        XCTAssertEqual(reconciliation.nextConsumedCount, 0)

        let firstRealFollowUp = SnapshotRepairFollowUpBudgetPolicy.decision(
            requiresFollowUp: true,
            currentConsumedCount: reconciliation.nextConsumedCount,
            consumesBudget: true
        )
        XCTAssertTrue(firstRealFollowUp.shouldSchedule)
        XCTAssertFalse(firstRealFollowUp.didExhaust)
        XCTAssertEqual(firstRealFollowUp.nextConsumedCount, 1)

        let exhausted = SnapshotRepairFollowUpBudgetPolicy.decision(
            requiresFollowUp: true,
            currentConsumedCount: firstRealFollowUp.nextConsumedCount,
            consumesBudget: true
        )
        XCTAssertFalse(exhausted.shouldSchedule)
        XCTAssertTrue(exhausted.didExhaust)
        XCTAssertEqual(exhausted.nextConsumedCount, 1)
    }

    func testOnlyDurableStaleReceiptGetsFreeReconciliationAttempt() {
        let provenBoundary = MessageArchiveManager.ConversationArchiveBoundaryFingerprint(
            chatExists: true,
            archiveStateExists: true,
            chatSnapshotArchiveId: "500",
            archiveSnapshotArchiveId: "500",
            archiveSnapshotMessageId: "message-500",
            unreadAfterId: nil,
            unreadCount: 0
        )
        let currentBoundary = MessageArchiveManager.ConversationArchiveBoundaryFingerprint(
            chatExists: true,
            archiveStateExists: true,
            chatSnapshotArchiveId: "900",
            archiveSnapshotArchiveId: "900",
            archiveSnapshotMessageId: "message-900",
            unreadAfterId: nil,
            unreadCount: 0
        )
        let durableStale = ConversationArchiveReadiness(
            phase: .committed,
            hasDurableCoverage: true,
            confirmsEmptyConversation: true,
            persistedVisibleRowCount: 0,
            boundaryFingerprint: provenBoundary
        )
        XCTAssertFalse(SnapshotRepairTerminalReceiptBudgetPolicy.consumesFollowUpBudget(
            readiness: durableStale,
            currentBoundaryFingerprint: currentBoundary
        ))

        let nondurable = ConversationArchiveReadiness(
            phase: .committed,
            hasDurableCoverage: false,
            confirmsEmptyConversation: false,
            persistedVisibleRowCount: 0,
            boundaryFingerprint: provenBoundary
        )
        XCTAssertTrue(SnapshotRepairTerminalReceiptBudgetPolicy.consumesFollowUpBudget(
            readiness: nondurable,
            currentBoundaryFingerprint: currentBoundary
        ))
        XCTAssertTrue(SnapshotRepairTerminalReceiptBudgetPolicy.consumesFollowUpBudget(
            readiness: ConversationArchiveReadiness(
                phase: .failed,
                hasDurableCoverage: false,
                confirmsEmptyConversation: false,
                persistedVisibleRowCount: 0
            ),
            currentBoundaryFingerprint: currentBoundary
        ))
        XCTAssertTrue(SnapshotRepairTerminalReceiptBudgetPolicy.consumesFollowUpBudget(
            readiness: durableStale,
            currentBoundaryFingerprint: provenBoundary
        ), "valid current proof is not stale reconciliation")
    }

    func testCommittedSkeletonDoesNotTerminateCancelledLocalContentPreparation() {
        XCTAssertTrue(ChatInitialLocalFirstFrameSupersessionPolicy.shouldRetry(
            mappingWasCancelled: true,
            hasTerminalNonSkeletonPresentation: false,
            didRunDisappearanceCleanup: false
        ))
        XCTAssertFalse(ChatInitialLocalFirstFrameSupersessionPolicy.shouldRetry(
            mappingWasCancelled: true,
            hasTerminalNonSkeletonPresentation: true,
            didRunDisappearanceCleanup: false
        ))
        XCTAssertFalse(ChatInitialLocalFirstFrameSupersessionPolicy.shouldRetry(
            mappingWasCancelled: true,
            hasTerminalNonSkeletonPresentation: false,
            didRunDisappearanceCleanup: true
        ))
    }

    func testPreparedEmptyFrameCannotReplaceLiveBlockingSkeleton() {
        XCTAssertFalse(ChatPreparedInitialFrameCommitPolicy.shouldCommit(
            hasMappedRealRows: false,
            liveLoadingState: .blockingArchive
        ))
        XCTAssertFalse(ChatPreparedInitialFrameCommitPolicy.shouldCommit(
            hasMappedRealRows: false,
            liveLoadingState: .blockingTarget
        ))
        XCTAssertTrue(ChatPreparedInitialFrameCommitPolicy.shouldCommit(
            hasMappedRealRows: true,
            liveLoadingState: .blockingArchive
        ))
        XCTAssertTrue(ChatPreparedInitialFrameCommitPolicy.shouldCommit(
            hasMappedRealRows: false,
            liveLoadingState: .empty
        ))
        XCTAssertFalse(ChatPreparedInitialFrameCommitPolicy.shouldCommit(
            hasMappedRealRows: false,
            liveLoadingState: .content
        ), "a stale empty preparation must not erase newer local content")
    }

    func testLateEmptyLocalPreparationKeepsKnownBoundarySkeletonCommitted() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatFirstLoginSkeletonAvatarReadinessRegressionTests-empty-race-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "first-login-empty-race-owner@example.com"
        let peer = "first-login-empty-race-peer@example.com"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: peer,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = peer
        chat.conversationType = .regular
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.syncSnapshotLastArchiveId = "known-remote-archive-id"
        try realm.write {
            realm.add(chat)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: peer,
                conversationType: .regular,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = "known-remote-archive-id"
            archiveState.lastSnapshotMessageId = "known-remote-message-id"
        }

        let key = ChatInitialBootstrapRequestKey(
            owner: owner,
            jid: peer,
            conversationType: .regular
        )
        guard case .start = ChatInitialBootstrapRequestCoordinator.shared.acquireOrJoin(
            key: key,
            proposedQueryId: "known-boundary-active-lease",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the changed snapshot must reserve an active lease")
        }

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = peer
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: peer, displayName: "Peer")
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        XCTAssertTrue(controller.prepareInitialLocalFirstFrame(
            chatInstance: chat,
            performPendingOpenMessageRequest: false
        ))
        XCTAssertTrue(waitUntil(timeout: 3) {
            controller.initialLocalFirstFrameMappingToken == nil
        })

        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testSchedulerDeduplicationSeparatesReplacementLeasesForSameConversation() {
        let key = makeKey(suffix: "scheduler-replacement")
        XCTAssertNotEqual(
            key.schedulerDeduplicationKey(queryId: "expired-query"),
            key.schedulerDeduplicationKey(queryId: "replacement-query")
        )
        XCTAssertTrue(
            key.schedulerDeduplicationKey(queryId: "replacement-query")
                .hasPrefix(key.schedulerDeduplicationKey)
        )
    }

    func testSnapshotTriggerWhileTargetIsActiveRequiresAnotherPumpGeneration() {
        XCTAssertTrue(SnapshotRepairRetriggerPolicy.shouldMarkDirty(
            isAlreadyScheduled: true,
            isActiveTarget: true
        ))
        XCTAssertFalse(SnapshotRepairRetriggerPolicy.shouldMarkDirty(
            isAlreadyScheduled: true,
            isActiveTarget: false
        ))
        XCTAssertFalse(SnapshotRepairRetriggerPolicy.shouldMarkDirty(
            isAlreadyScheduled: false,
            isActiveTarget: false
        ))
    }

    func testResolvedLocalAnchorStillOwnsSkeletonToContentTransition() {
        XCTAssertTrue(ChatAnchorBootstrapTransitionPolicy.usesBootstrapLoading(
            isShowingBootstrapPlaceholder: true,
            wouldOtherwiseBlockForAnchor: false
        ))
        XCTAssertTrue(ChatAnchorBootstrapTransitionPolicy.usesBootstrapLoading(
            isShowingBootstrapPlaceholder: false,
            wouldOtherwiseBlockForAnchor: true
        ))
        XCTAssertFalse(ChatAnchorBootstrapTransitionPolicy.usesBootstrapLoading(
            isShowingBootstrapPlaceholder: false,
            wouldOtherwiseBlockForAnchor: false
        ))
    }

    func testSupersededLocalAnchorMappingRetriesUntilSkeletonBecomesContent() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatFirstLoginSkeletonAvatarReadinessRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "first-login-anchor-owner@example.com"
        let peer = "first-login-anchor-peer@example.com"
        let messagePrimary = "first-login-anchor-message"
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = messagePrimary
        message.owner = owner
        message.opponent = peer
        message.body = "Persisted message"
        message.messageId = "first-login-anchor-message-id"
        message.archivedId = "first-login-anchor-archive-id"
        message.date = Date(timeIntervalSince1970: 1_700_000_000)
        message.sentDate = message.date
        message.conversationType = .regular
        message.isRead = false

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: peer,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = peer
        chat.conversationType = .regular
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.lastMessage = message
        chat.messageDate = message.date
        chat.unread = 1
        try realm.write {
            realm.add(message)
            realm.add(chat)
        }

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = peer
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: peer, displayName: "Peer")
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.configureDataset()
        controller.pendingOpenMessageRequest = ChatOpenMessageRequest(
            chatJid: peer,
            owner: owner,
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: messagePrimary,
                archivedId: message.archivedId,
                messageId: message.messageId,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: message.date
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .initialUnreadBoundary
        )
        controller.applyBootstrapLoadingState(
            .blockingTarget,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        XCTAssertTrue(controller.prepareInitialLocalFirstFrame(
            chatInstance: chat,
            performPendingOpenMessageRequest: false
        ))
        _ = controller.beginDatasetMappingJobForTesting()

        XCTAssertTrue(waitUntil(timeout: 3) {
            controller.datasource.contains {
                !$0.isFakeMessage && $0.archivedId == message.archivedId
            } && !controller.showSkeletonObserver.value
        }, """
        the superseded mapping must not leave the committed skeleton terminal; \
        phase=\(controller.initialLocalFirstFramePhase), \
        rows=\(controller.datasource.count), \
        contentSize=\(controller.messagesCollectionView.contentSize), \
        bounds=\(controller.messagesCollectionView.bounds), \
        offset=\(controller.messagesCollectionView.contentOffset)
        """)
        let realRows = controller.datasource.filter { !$0.isFakeMessage }
        XCTAssertEqual(realRows.count, 1)
        XCTAssertEqual(realRows.first?.archivedId, message.archivedId)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testAvatarActionHasVisibleFallbackBeforeAsyncImageArrives() throws {
        let action = #selector(dummyAction)
        let item = ChatNavigationAvatarItemFactory.makeItem(
            image: nil,
            target: self,
            action: action
        )

        let image = try XCTUnwrap(item.image)
        XCTAssertEqual(image.size.width, ChatNavigationAvatarItemFactory.imageSize, accuracy: 0.001)
        XCTAssertEqual(image.size.height, ChatNavigationAvatarItemFactory.imageSize, accuracy: 0.001)
        XCTAssertEqual(image.renderingMode, .alwaysOriginal)
        XCTAssertEqual(item.action, action)
        XCTAssertTrue(item.target === self)
        XCTAssertEqual(
            item.accessibilityIdentifier,
            ChatNavigationAvatarItemFactory.accessibilityIdentifier
        )
    }

    @objc private func dummyAction() {}

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func makeKey(suffix: String) -> ChatInitialBootstrapRequestKey {
        ChatInitialBootstrapRequestKey(
            owner: "first-login-\(suffix)-owner@example.com",
            jid: "first-login-\(suffix)-peer@example.com",
            conversationType: .regular
        )
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
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: count
            ),
            first: count > 0 ? "archive-1" : "",
            last: count > 0 ? "archive-\(count)" : "",
            count: count,
            streamKind: .primary,
            source: .localCallback
        )
    }
}
