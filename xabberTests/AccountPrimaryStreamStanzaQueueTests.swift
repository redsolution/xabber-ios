import XCTest
import RealmSwift
import RxCocoa
import XMPPFramework
@testable import xabber

final class AccountPrimaryStreamStanzaQueueTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "AccountPrimaryStreamStanzaQueueTests-\(name)-\(UUID().uuidString)"
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

    func testTrackerRegistersBeforeSendAndAssignsMissingStanzaId() {
        let harness = makeTrackerHarness()
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: "juliet@example.com"), elementID: nil)
        var events: [String] = []

        let stanzaId = PrimaryStreamStanzaIdentifier.ensureID(on: message)
        let result = harness.tracker.track(
            stanzaId: stanzaId,
            kind: .message,
            replayPolicy: .notReplayable
        )
        events.append("tracked")
        events.append("sent")

        XCTAssertEqual(result, .tracked(stanzaId: stanzaId))
        XCTAssertEqual(message.elementID, stanzaId)
        XCTAssertEqual(events, ["tracked", "sent"])
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), [stanzaId])
    }

    func testAckRemovesOnlyAckedIdsAndLeavesPartialRemainderTracked() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable)
        _ = harness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .notReplayable)

        let removed = harness.tracker.noteAck(ids: ["message-1"])

        XCTAssertEqual(removed.map(\.stanzaId), ["message-1"])
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["message-2"])

        _ = harness.tracker.noteAck(ids: ["message-2"])

        XCTAssertTrue(harness.tracker.snapshotTrackedPrimaryStanzas().isEmpty)
    }

    func testAckTimeoutFiresOnceForSameOldestGeneration() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable)

        harness.scheduler.advance(by: 4.9)
        XCTAssertTrue(harness.timeouts.isEmpty)

        harness.scheduler.advance(by: 0.1)
        XCTAssertEqual(harness.timeouts.map(\.stanzaId), ["message-1"])

        harness.scheduler.advance(by: 20)
        XCTAssertEqual(harness.timeouts.map(\.stanzaId), ["message-1"])
    }

    func testBootstrapClientSyncIQDoesNotArmPrimaryStreamAckTimeout() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "sync-page-1", kind: .iq, replayPolicy: .bootstrapClientSyncIQ)

        harness.scheduler.advance(by: 30)

        XCTAssertTrue(harness.timeouts.isEmpty)
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["sync-page-1"])
    }

    func testLongRunningBackgroundIQDoesNotArmPrimaryStreamAckTimeout() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "mam-snapshot-repair-1", kind: .iq, replayPolicy: .longRunningBackgroundIQ)

        harness.scheduler.advance(by: 30)

        XCTAssertTrue(harness.timeouts.isEmpty)
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["mam-snapshot-repair-1"])
    }

    func testDidFailToSendRemovesTrackedStanzaSafely() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable)

        let removed = harness.tracker.noteSendFailed(id: "message-1")
        let duplicateRemoval = harness.tracker.noteSendFailed(id: "message-1")

        XCTAssertEqual(removed?.stanzaId, "message-1")
        XCTAssertNil(duplicateRemoval)
        XCTAssertTrue(harness.tracker.snapshotTrackedPrimaryStanzas().isEmpty)
    }

    func testSuccessfulResumeReconcilesAckedIdsWithoutReplayRequests() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1"))
        _ = harness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-2"))

        let removed = harness.tracker.noteResumeSucceeded(ackedIds: ["message-1"])

        XCTAssertEqual(removed.map(\.stanzaId), ["message-1"])
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["message-2"])
    }

    func testFailedResumeFullReconnectLetsSendCoordinatorReplayRegularMessageWithRetry() throws {
        var isReady = true
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { isReady }, recorder: recorder)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        isReady = false
        coordinator.streamDidDisconnect(canResume: true)
        coordinator.streamManagementResumeFailed()
        isReady = true
        coordinator.accountDidBecomeSendReady()

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])
        XCTAssertNotNil(recorder.sentMessages.last?.element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
        XCTAssertEqual(
            recorder.sentMessages.last?.element(forName: "origin-id", xmlns: "urn:xmpp:sid:0")?.attributeStringValue(forName: "id"),
            "message-1"
        )
    }

    func testStreamManagementAckDoesNotDrainSendCoordinatorBeforeDeliveryReceipt() throws {
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder)
        let harness = makeTrackerHarness()

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", createdAt: Date(timeIntervalSince1970: 1)))
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-2", createdAt: Date(timeIntervalSince1970: 2)))
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1"))

        _ = harness.tracker.noteAck(ids: ["message-1"])

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])

        coordinator.deliveryReceiptReceived(originId: "message-1", stanzaId: "archive-1")

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-2"])
    }

    func testStaleReadinessKeepsRegularMessageQueuedAndLogsReason() throws {
        let readiness = AccountSendReadinessCoordinator()
        readiness.markStreamManagementEnabled()
        readiness.markSuspectedStale(reason: AccountConnectionStaleReason.primaryStreamAckTimeout.rawValue)
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let logger = AccountPrimaryStreamSendCoordinatorLogger()
        let coordinator = makeSendCoordinator(
            isReady: { readiness.snapshot.canFlushApplicationStanzas },
            recorder: recorder,
            readinessSnapshot: { readiness.snapshot },
            logger: logger
        )

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))

        XCTAssertTrue(recorder.sentMessages.isEmpty)

        let realm = try WRealm.safe()
        let item = try XCTUnwrap(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").first)
        XCTAssertEqual(item.state, .queued)
        XCTAssertNil(item.lastError)

        let notReadyLog = try XCTUnwrap(logger.events.first { $0.event == "account_send_coordinator_drain_skipped_not_ready" })
        XCTAssertEqual(notReadyLog.details["phase"] as? String, "suspectedStale")
        XCTAssertEqual(notReadyLog.details["reason"] as? String, AccountConnectionStaleReason.primaryStreamAckTimeout.rawValue)
        XCTAssertEqual(notReadyLog.details["canFlush"] as? Bool, false)
    }

    func testUserMessageSendBypassesRunningBackgroundSchedulerWork() throws {
        let scheduler = AccountXMPPTaskScheduler(configuration: .test(defaultCooldown: 0))
        let backgroundStarted = expectation(description: "background MAM work started")
        var finishBackground: (() -> Void)?
        scheduler.enqueue(priority: .background, resource: .mamArchive, deduplicationKey: "mam") { finish in
            finishBackground = finish
            backgroundStarted.fulfill()
        }
        wait(for: [backgroundStarted], timeout: 1)

        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])
        finishBackground?()
    }

    func testSchedulerDefersNonInteractiveWorkWhileBootstrapGateIsActive() {
        var isBootstrapActive = true
        let scheduler = AccountXMPPTaskScheduler(
            configuration: .test(defaultCooldown: 0),
            bootstrapGate: { isBootstrapActive }
        )
        let backgroundStarted = expectation(description: "background work is deferred")
        backgroundStarted.isInverted = true
        var backgroundStartHandler: () -> Void = {
            backgroundStarted.fulfill()
        }
        scheduler.enqueue(priority: .background, resource: .mamArchive, deduplicationKey: "background") { finish in
            backgroundStartHandler()
            finish()
        }
        wait(for: [backgroundStarted], timeout: 0.1)

        let interactiveStarted = expectation(description: "interactive work starts")
        scheduler.enqueue(priority: .interactive, resource: .mamArchive, deduplicationKey: "interactive") { finish in
            interactiveStarted.fulfill()
            finish()
        }
        wait(for: [interactiveStarted], timeout: 1)

        let deferredStarted = expectation(description: "deferred work starts after bootstrap")
        backgroundStartHandler = {
            deferredStarted.fulfill()
        }
        isBootstrapActive = false
        scheduler.bootstrapGateDidChange()
        wait(for: [deferredStarted], timeout: 1)
    }

    func testDurableRegularMessagePreemptsLowerPriorityTrackedStanzaWhenTrackerIsFull() {
        let harness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 2, maxRetainedXMLBytes: 1024, ackTimeout: 5)
        )
        XCTAssertEqual(
            harness.tracker.track(stanzaId: "iq-1", kind: .iq, replayPolicy: .notReplayable),
            .tracked(stanzaId: "iq-1")
        )
        XCTAssertEqual(
            harness.tracker.track(stanzaId: "presence-1", kind: .presence, replayPolicy: .latestPresence(scope: "broadcast")),
            .tracked(stanzaId: "presence-1")
        )

        XCTAssertEqual(
            harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1")),
            .tracked(stanzaId: "message-1")
        )

        let tracked = harness.tracker.snapshotTrackedPrimaryStanzas()
        XCTAssertEqual(tracked.count, 2)
        XCTAssertTrue(tracked.contains { $0.stanzaId == "message-1" })
        XCTAssertFalse(tracked.contains { $0.stanzaId == "iq-1" })
    }

    func testDurableRegularMessageDoesNotPreemptAnotherDurableRegularMessage() {
        let harness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 1, maxRetainedXMLBytes: 1024, ackTimeout: 5)
        )
        XCTAssertEqual(
            harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1")),
            .tracked(stanzaId: "message-1")
        )

        XCTAssertEqual(
            harness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-2")),
            .rejected(.countLimit(max: 1))
        )
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["message-1"])
    }

    func testDeliveryReceiptBeforeTimeoutCancelsRetryAndDrainsNextQueuedMessage() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", createdAt: Date(timeIntervalSince1970: 1)))
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-2", createdAt: Date(timeIntervalSince1970: 2)))

        scheduler.advance(by: 4.9)
        coordinator.deliveryReceiptReceived(originId: "message-1", stanzaId: "archive-1")
        scheduler.advance(by: 0.2)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-2"])
        XCTAssertNil(recorder.sentMessages.last?.element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
    }

    func testStreamManagementAckDoesNotSatisfyDeliveryReceiptTimeout() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        let harness = makeTrackerHarness()

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", createdAt: Date(timeIntervalSince1970: 1)))
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-2", createdAt: Date(timeIntervalSince1970: 2)))
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1"))

        _ = harness.tracker.noteAck(ids: ["message-1"])
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])
        XCTAssertNotNil(recorder.sentMessages.last?.element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
    }

    func testFirstDeliveryReceiptTimeoutResendsSameMessageOnceWithRetryElement() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1")

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])
        XCTAssertEqual(
            recorder.sentMessages.last?.element(forName: "origin-id", xmlns: "urn:xmpp:sid:0")?.attributeStringValue(forName: "id"),
            "message-1"
        )
        XCTAssertNotNil(recorder.sentMessages.last?.element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))

        let realm = try WRealm.safe()
        let queueItem = try XCTUnwrap(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").first)
        XCTAssertEqual(queueItem.state, .awaitingReceipt)
        XCTAssertEqual(queueItem.attemptCount, 2)
        XCTAssertTrue(queueItem.replayRequired)
        XCTAssertEqual(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com"))?.state,
            .sending
        )
    }

    func testSecondDeliveryReceiptTimeoutMarksErrorAndDoesNotSendThirdAutomaticAttempt() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1", includeReference: true)
        try storeLastChat()

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        scheduler.advance(by: 5)
        scheduler.advance(by: 5)
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])

        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com")))
        XCTAssertEqual(message.state, .error)
        XCTAssertEqual(message.messageErrorCode, "delivery-receipt-timeout")
        XCTAssertTrue(message.references.first?.hasError == true)
        XCTAssertTrue(
            realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "romeo@example.com", owner: "owner@example.com", conversationType: .regular))?.hasErrorInChat == true
        )

        let queueItem = try XCTUnwrap(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").first)
        XCTAssertEqual(queueItem.state, .terminalFailed)
        XCTAssertEqual(queueItem.attemptCount, 2)
    }

    func testManualRetryAfterTimeoutErrorPreservesOriginIdAndStartsFreshTimeoutCycle() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1")

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        scheduler.advance(by: 5)
        scheduler.advance(by: 5)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", replayRequired: true))
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1", "message-1", "message-1"])
        XCTAssertNotNil(recorder.sentMessages[2].element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
        XCTAssertNotNil(recorder.sentMessages[3].element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
        XCTAssertEqual(
            Set(recorder.sentMessages.compactMap(\.elementID)),
            Set(["message-1"])
        )

        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com")))
        XCTAssertEqual(message.state, .sending)
        XCTAssertNil(message.messageError)
        XCTAssertNil(message.messageErrorCode)
        let queueItem = try XCTUnwrap(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").first)
        XCTAssertEqual(queueItem.state, .awaitingReceipt)
        XCTAssertEqual(queueItem.attemptCount, 2)
    }

    func testDuplicateManualPersistenceDoesNotResetActiveQueueItem() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", replayRequired: false))
        let didEnqueueDuplicate = try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", replayRequired: true))

        XCTAssertFalse(didEnqueueDuplicate)
        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])

        let realm = try WRealm.safe()
        let queueItem = try XCTUnwrap(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").first)
        XCTAssertEqual(queueItem.state, .awaitingReceipt)
        XCTAssertEqual(queueItem.attemptCount, 1)
        XCTAssertFalse(queueItem.replayRequired)
    }

    func testExplicitServerErrorStaysTerminalAndDoesNotEnterAutomaticTimeoutRetry() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        coordinator.terminalFailure(originId: "message-1", error: "Forbidden")
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])

        let realm = try WRealm.safe()
        let queueItem = try XCTUnwrap(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").first)
        XCTAssertEqual(queueItem.state, .terminalFailed)
        XCTAssertEqual(queueItem.lastError, "Forbidden")
    }

    func testLateDeliveryReceiptAfterTimeoutReconcilesMessageToSentAndClearsTimeoutError() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1", includeReference: true)
        try storeLastChat()

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        scheduler.advance(by: 5)
        scheduler.advance(by: 5)

        let receipt = XabberDeliveryReceipt(
            originId: "message-1",
            stanzaId: "archive-1",
            stamp: Date(timeIntervalSince1970: 100)
        )
        let applied = ReliableMessageDeliveryReceiptProcessor.apply(owner: "owner@example.com", receipt: receipt) { originId, stanzaId in
            coordinator.deliveryReceiptReceived(originId: originId, stanzaId: stanzaId)
        }

        XCTAssertTrue(applied)

        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com")))
        XCTAssertEqual(message.state, .sended)
        XCTAssertEqual(message.archivedId, "archive-1")
        XCTAssertNil(message.messageError)
        XCTAssertNil(message.messageErrorCode)
        XCTAssertFalse(message.references.first?.hasError == true)
        XCTAssertFalse(
            realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "romeo@example.com", owner: "owner@example.com", conversationType: .regular))?.hasErrorInChat == true
        )
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).filter("originId == %@", "message-1").count, 0)
    }

    func testDeletingErrorPendingMessageRemovesMessageQueueAndStoredStanza() throws {
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { false }, recorder: recorder)
        try storeSendingMessage(
            originId: "message-1",
            state: .error,
            includeStoredStanza: true
        )
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))

        let primary = MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com")
        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        XCTAssertTrue(PendingOutgoingMessageDeletionPolicy.canDeleteLocally(message))

        XCTAssertTrue(coordinator.deletePendingOutgoingMessage(primary: primary))

        XCTAssertNil(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        XCTAssertNil(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: "\(primary)_stanza"))
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).filter("messagePrimary == %@", primary).count, 0)
    }

    func testDeletingAwaitingPendingMessageCancelsTimeoutRetry() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1")

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        let primary = MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com")

        XCTAssertTrue(coordinator.deletePendingOutgoingMessage(primary: primary))
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])
        XCTAssertEqual(try WRealm.safe().objects(OutgoingMessageQueueItem.self).filter("messagePrimary == %@", primary).count, 0)
    }

    func testDeletingAwaitingFirstMessageUnblocksNextQueuedMessage() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1")
        try storeSendingMessage(originId: "message-2")

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", createdAt: Date(timeIntervalSince1970: 1)))
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-2", createdAt: Date(timeIntervalSince1970: 2)))
        let primary = MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.com")

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])

        XCTAssertTrue(coordinator.deletePendingOutgoingMessage(primary: primary))

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-2"])
    }

    func testPendingOutgoingDeletePolicyExcludesArchivedSentAndIncomingMessages() {
        let archivedError = makeMessageForPendingDeletePolicy(
            outgoing: true,
            state: .error,
            archivedId: "archive-1"
        )
        let unarchivedSent = makeMessageForPendingDeletePolicy(
            outgoing: true,
            state: .sended,
            archivedId: ""
        )
        let incomingError = makeMessageForPendingDeletePolicy(
            outgoing: false,
            state: .error,
            archivedId: ""
        )

        XCTAssertFalse(PendingOutgoingMessageDeletionPolicy.canDeleteLocally(archivedError))
        XCTAssertFalse(PendingOutgoingMessageDeletionPolicy.canDeleteLocally(unarchivedSent))
        XCTAssertFalse(PendingOutgoingMessageDeletionPolicy.canDeleteLocally(incomingError))
    }

    func testStaleDeliveryReceiptTimeoutCallbackIsIgnoredAfterQueueItemDeleted() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        let realm = try WRealm.safe()
        try realm.write {
            realm.delete(realm.objects(OutgoingMessageQueueItem.self))
        }

        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])
    }

    func testSupersededDeliveryReceiptTimeoutCallbackDoesNotCancelCurrentTimer() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        coordinator.streamDidDisconnect(canResume: true)
        coordinator.streamManagementResumeSucceeded()

        scheduler.fireCancelledCallbacks()
        scheduler.advance(by: 5)

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])
        XCTAssertNotNil(recorder.sentMessages.last?.element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
    }

    func testPerChatOrderingRemainsReceiptGatedThroughRetryAndTimeoutError() throws {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder, scheduler: scheduler)
        try storeSendingMessage(originId: "message-1")

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", createdAt: Date(timeIntervalSince1970: 1)))
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-2", createdAt: Date(timeIntervalSince1970: 2)))

        scheduler.advance(by: 5)
        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])

        scheduler.advance(by: 5)
        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1", "message-2"])
    }

    func testQueueCountAndRetainedXMLByteLimitsAreEnforcedWithoutCrashes() {
        let countHarness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 1, maxRetainedXMLBytes: 1024, ackTimeout: 5)
        )
        XCTAssertEqual(
            countHarness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable),
            .tracked(stanzaId: "message-1")
        )
        XCTAssertEqual(
            countHarness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .notReplayable),
            .rejected(.countLimit(max: 1))
        )

        let byteHarness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 10, maxRetainedXMLBytes: 8, ackTimeout: 5)
        )
        XCTAssertEqual(
            byteHarness.tracker.track(
                stanzaId: "iq-1",
                kind: .iq,
                replayPolicy: .safeIdempotentIQ(retainedXML: "<iq id='iq-1'><query/></iq>")
            ),
            .rejected(.retainedXMLByteLimit(max: 8, attempted: 27))
        )
        XCTAssertTrue(byteHarness.tracker.snapshotTrackedPrimaryStanzas().isEmpty)
    }

    func testConcurrentSendAckAndTimeoutAccessIsRaceFree() {
        let harness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 300, maxRetainedXMLBytes: 1024, ackTimeout: 5)
        )
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.xabber.tests.primary-tracker.concurrent", attributes: .concurrent)

        for index in 0..<100 {
            group.enter()
            queue.async {
                _ = harness.tracker.track(stanzaId: "message-\(index)", kind: .message, replayPolicy: .notReplayable)
                group.leave()
            }
        }
        for index in 0..<100 {
            group.enter()
            queue.async {
                _ = harness.tracker.noteAck(ids: ["message-\(index)"])
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        harness.scheduler.advance(by: 5)
        XCTAssertLessThanOrEqual(harness.tracker.snapshotTrackedPrimaryStanzas().count, 100)
    }

    func testNonPrimaryStreamFallsBackToDirectSendRoute() {
        let stream = XMPPStream()

        XCTAssertNil(PrimaryStreamSendRouting.primaryAccount(owner: "missing@example.com", stream: stream))
    }

    func testBootstrapSendGateAllowsOnlySyncAndRequiredProtocolStanzas() {
        let syncQuery = DDXMLElement(name: "query", xmlns: ClientSynchronizationManager.primaryNamespace)
        let rsm = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        rsm.addChild(DDXMLElement(name: "max", stringValue: "60"))
        syncQuery.addChild(rsm)
        let syncIQ = XMPPIQ(iqType: .get, elementID: "sync-1", child: syncQuery)
        let resultIQ = XMPPIQ(iqType: .result, to: XMPPJID(string: "server.example.com"), elementID: "server-request-1")
        let vCardIQ = XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: "romeo@example.com"),
            elementID: "vcard-1",
            child: DDXMLElement(name: "vCard", xmlns: "vcard-temp")
        )
        let userMessage = XMPPMessage(messageType: .chat, to: XMPPJID(string: "romeo@example.com"), elementID: "message-1")
        let unavailable = XMPPPresence(type: .unavailable)

        XCTAssertTrue(AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(syncIQ, replayPolicy: .notReplayable))
        XCTAssertTrue(AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(resultIQ, replayPolicy: .notReplayable))
        XCTAssertTrue(AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(userMessage, replayPolicy: .durableRegularMessage(originId: "message-1")))
        XCTAssertTrue(AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(unavailable, replayPolicy: .latestPresence(scope: "account-unavailable")))
        XCTAssertFalse(AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(vCardIQ, replayPolicy: .notReplayable))
    }

    func testBootstrapSendGateAllowsLoginCriticalSelfDiscoInfoDuringBootstrap() {
        let owner = "romeo@example.com"
        let selfDiscoInfoIQ = XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: owner),
            elementID: "self-disco-info",
            child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        )

        XCTAssertTrue(
            AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(
                selfDiscoInfoIQ,
                replayPolicy: .notReplayable,
                ownerBareJID: owner
            )
        )
    }

    func testBootstrapSendGateQueuesSimilarNonLoginCriticalDiscoDuringBootstrap() {
        let owner = "romeo@example.com"
        let selfDiscoItemsIQ = XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: owner),
            elementID: "self-disco-items",
            child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
        )
        let contactCapsQuery = DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        contactCapsQuery.addAttribute(withName: "node", stringValue: "https://www.xabber.com#wYkv8yTMmB2SC50cZ4Awn07dcTQ=")
        let contactCapsIQ = XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: "juliet@example.com/xabber-ios"),
            elementID: "contact-caps",
            child: contactCapsQuery
        )
        let gate = AccountPrimaryStreamBootstrapSendGate(now: { 42 })

        XCTAssertFalse(
            AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(
                selfDiscoItemsIQ,
                replayPolicy: .notReplayable,
                ownerBareJID: owner
            )
        )
        XCTAssertFalse(
            AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(
                contactCapsIQ,
                replayPolicy: .notReplayable,
                ownerBareJID: owner
            )
        )
        XCTAssertEqual(
            gate.prepareForSend(
                selfDiscoItemsIQ,
                replayPolicy: .notReplayable,
                isBootstrapActive: true,
                ownerBareJID: owner
            ),
            .queued(stanzaId: "self-disco-items")
        )
        XCTAssertEqual(
            gate.prepareForSend(
                contactCapsIQ,
                replayPolicy: .notReplayable,
                isBootstrapActive: true,
                ownerBareJID: owner
            ),
            .queued(stanzaId: "contact-caps")
        )
    }

    func testBootstrapSendGateStillQueuesBackgroundIQsDuringBootstrap() {
        let owner = "romeo@example.com"
        let backgroundIQs = [
            XMPPIQ(iqType: .get, elementID: "roster", child: DDXMLElement(name: "query", xmlns: "jabber:iq:roster")),
            XMPPIQ(iqType: .set, elementID: "push", child: DDXMLElement(name: "enable", xmlns: "https://xabber.com/protocol/push")),
            XMPPIQ(iqType: .get, to: XMPPJID(string: "juliet@example.com"), elementID: "vcard", child: DDXMLElement(name: "vCard", xmlns: "vcard-temp")),
            XMPPIQ(iqType: .get, elementID: "mam", child: DDXMLElement(name: "query", xmlns: "urn:xmpp:mam:2")),
            XMPPIQ(iqType: .get, elementID: "group-info", child: DDXMLElement(name: "group", xmlns: "https://xabber.com/protocol/groups")),
            XMPPIQ(iqType: .get, elementID: "devices", child: DDXMLElement(name: "query", xmlns: "https://xabber.com/protocol/devices#items")),
            XMPPIQ(iqType: .set, elementID: "omemo", child: DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"))
        ]

        backgroundIQs.forEach { iq in
            XCTAssertFalse(
                AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(
                    iq,
                    replayPolicy: .notReplayable,
                    ownerBareJID: owner
                ),
                iq.elementID ?? "missing-id"
            )
        }
    }

    func testAccountManagerKeepsNewAccountJidUntilTerminalSignInState() {
        let manager = AccountManager.shared
        let originalJid = manager.newAccountJid
        let originalObserver = manager.newAccountObservable
        manager.newAccountObservable = BehaviorRelay(value: AccountManager.UserObserver(jid: "", state: .none))
        manager.newAccountJid = "romeo@example.com"
        defer {
            manager.newAccountJid = originalJid
            manager.newAccountObservable = originalObserver
        }

        manager.changeNewUserState(for: "romeo@example.com", to: .auth)
        XCTAssertEqual(manager.newAccountJid, "romeo@example.com")

        manager.changeNewUserState(for: "romeo@example.com", to: .dataLoaded)
        XCTAssertEqual(manager.newAccountJid, "romeo@example.com")

        manager.changeNewUserState(for: "romeo@example.com", to: .capsReceived(["mam"]))
        XCTAssertEqual(manager.newAccountJid, "")
    }

    func testAccountManagerEmitsLateCapsReceivedBeforeClearingNewAccountJid() {
        let manager = AccountManager.shared
        let originalJid = manager.newAccountJid
        let originalObserver = manager.newAccountObservable
        manager.newAccountObservable = BehaviorRelay(value: AccountManager.UserObserver(jid: "", state: .none))
        manager.newAccountJid = "romeo@example.com"
        defer {
            manager.newAccountJid = originalJid
            manager.newAccountObservable = originalObserver
        }

        manager.changeNewUserState(for: "romeo@example.com", to: .auth)
        manager.changeNewUserState(for: "romeo@example.com", to: .dataLoaded)
        manager.changeNewUserState(for: "romeo@example.com", to: .capsReceived(["mam", "xpush"]))

        guard case .capsReceived(let caps) = manager.newAccountObservable.value.state else {
            XCTFail("Expected capsReceived after delayed bootstrap state")
            return
        }
        XCTAssertEqual(caps, ["mam", "xpush"])
        XCTAssertEqual(manager.newAccountJid, "")
    }

    func testAvatarManagerAppliesPubSubMetadataIQResultWithUrl() throws {
        let owner = "owner@example.com"
        let jid = "juliet@example.com"
        let queryId = "avatar-metadata-1:IQ:avatar:pubsub"
        let avatarId = "524722e3c6d197a14d3a06e83c2732d46eb66583"
        let avatarUrl = "https://xmpp.example.com/upload/avatar.png?v=\(avatarId)"
        let manager = XmppAvatarManager(withOwner: owner)
        manager.queryIds.insert(queryId)
        try storeRosterItem(owner: owner, jid: jid)
        let iq = try makeIQ("""
        <iq xmlns="jabber:client" to="\(owner)/ios" from="\(jid)" type="result" id="\(queryId)">
          <pubsub xmlns="http://jabber.org/protocol/pubsub">
            <items node="urn:xmpp:avatar:metadata">
              <item id="\(avatarId)">
                <metadata xmlns="urn:xmpp:avatar:metadata">
                  <info url="\(avatarUrl)" type="image/png" id="\(avatarId)" bytes="1275"/>
                </metadata>
              </item>
            </items>
          </pubsub>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let roster = try XCTUnwrap(try WRealm.safe().object(
            ofType: RosterStorageItem.self,
            forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
        ))
        XCTAssertEqual(roster.avatarMaxUrl, avatarUrl)
        XCTAssertEqual(roster.oldschoolAvatarKey, avatarId)
        XCTAssertFalse(manager.queryIds.contains(queryId))
    }

    func testAvatarManagerConsumesPubSubAvatarErrorIQ() throws {
        let owner = "owner@example.com"
        let jid = "juliet@example.com"
        let queryId = "avatar-metadata-error:IQ:avatar:pubsub"
        let manager = XmppAvatarManager(withOwner: owner)
        manager.queryIds.insert(queryId)
        try storeRosterItem(owner: owner, jid: jid)
        let iq = try makeIQ("""
        <iq xmlns="jabber:client" to="\(owner)/ios" from="\(jid)" type="error" id="\(queryId)">
          <pubsub xmlns="http://jabber.org/protocol/pubsub">
            <items node="urn:xmpp:avatar:metadata" max_items="1"/>
          </pubsub>
          <error code="404" type="cancel">
            <item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
          </error>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let roster = try XCTUnwrap(try WRealm.safe().object(
            ofType: RosterStorageItem.self,
            forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
        ))
        XCTAssertNil(roster.avatarMaxUrl)
        XCTAssertFalse(manager.queryIds.contains(queryId))
    }

    func testBootstrapSendGateQueuesBackgroundStanzasAndFlushesAfterBootstrap() throws {
        var now: TimeInterval = 10
        let gate = AccountPrimaryStreamBootstrapSendGate(now: { now })
        let vCardIQ = XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: "romeo@example.com"),
            elementID: "vcard-1",
            child: DDXMLElement(name: "vCard", xmlns: "vcard-temp")
        )
        let avatarIQ = XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: "romeo@example.com"),
            elementID: "avatar-1",
            child: DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        )

        XCTAssertEqual(
            gate.prepareForSend(vCardIQ, replayPolicy: .notReplayable, isBootstrapActive: true),
            .queued(stanzaId: "vcard-1")
        )
        now = 12
        XCTAssertEqual(
            gate.prepareForSend(avatarIQ, replayPolicy: .notReplayable, isBootstrapActive: true),
            .queued(stanzaId: "avatar-1")
        )
        XCTAssertEqual(gate.queuedCount, 2)

        let queued = gate.drainQueuedStanzas()

        XCTAssertEqual(queued.map(\.stanzaId), ["vcard-1", "avatar-1"])
        XCTAssertEqual(queued.map(\.queuedAge), [2, 0])
        XCTAssertEqual(try XCTUnwrap(queued.first?.makeElement()).name, "iq")
        XCTAssertEqual(gate.queuedCount, 0)
    }

    func testBootstrapSendGateCoalescesLatestPresenceByScope() {
        var now: TimeInterval = 20
        let gate = AccountPrimaryStreamBootstrapSendGate(now: { now })
        let awayPresence = XMPPPresence()
        awayPresence.addAttribute(withName: "id", stringValue: "presence-away")
        awayPresence.addChild(DDXMLElement(name: "show", stringValue: "away"))
        let chatPresence = XMPPPresence()
        chatPresence.addAttribute(withName: "id", stringValue: "presence-chat")
        chatPresence.addChild(DDXMLElement(name: "show", stringValue: "chat"))

        XCTAssertEqual(
            gate.prepareForSend(awayPresence, replayPolicy: .latestPresence(scope: "available:broadcast"), isBootstrapActive: true),
            .queued(stanzaId: "presence-away")
        )
        now = 21
        XCTAssertEqual(
            gate.prepareForSend(chatPresence, replayPolicy: .latestPresence(scope: "available:broadcast"), isBootstrapActive: true),
            .queued(stanzaId: "presence-chat")
        )

        let queued = gate.drainQueuedStanzas()

        XCTAssertEqual(queued.map(\.stanzaId), ["presence-chat"])
        XCTAssertEqual(queued.first?.queuedAge, 0)
    }

    private func makeTrackerHarness(
        configuration: AccountPrimaryStreamStanzaTracker.Configuration = .init(maxTrackedCount: 512, maxRetainedXMLBytes: 512 * 1024, ackTimeout: 5)
    ) -> AccountPrimaryStreamTrackerHarness {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let box = AccountPrimaryStreamTimeoutBox()
        let tracker = AccountPrimaryStreamStanzaTracker(
            configuration: configuration,
            scheduler: scheduler,
            onAckTimeout: { stanza in
                box.timeouts.append(stanza)
            }
        )
        return AccountPrimaryStreamTrackerHarness(
            tracker: tracker,
            scheduler: scheduler,
            timeoutBox: box
        )
    }

    private func makeSendCoordinator(
        owner: String = "owner@example.com",
        isReady: @escaping () -> Bool,
        recorder: AccountPrimaryStreamSendCoordinatorRecorder,
        scheduler: AccountPrimaryStreamTestScheduler = AccountPrimaryStreamTestScheduler(),
        readinessSnapshot: @escaping () -> AccountSendReadinessSnapshot? = { nil },
        logger: AccountPrimaryStreamSendCoordinatorLogger = AccountPrimaryStreamSendCoordinatorLogger()
    ) -> AccountSendCoordinator {
        AccountSendCoordinator(
            environment: AccountSendCoordinator.Environment(
                owner: owner,
                isSendReady: isReady,
                sendReadinessSnapshot: readinessSnapshot,
                decorateMessage: { message, retry, missRetryElement in
                    if retry && !missRetryElement {
                        message.addChild(DDXMLElement(name: "retry", xmlns: "https://xabber.com/protocol/delivery"))
                    }
                    return message
                },
                sendMessage: { message in
                    recorder.sentMessages.append(message.copy() as! XMPPMessage)
                },
                scheduler: scheduler,
                receiptTimeout: 5,
                now: {
                    Date(timeIntervalSince1970: scheduler.now)
                },
                log: { event, details in
                    logger.events.append((event, details))
                }
            )
        )
    }

    private func makeRequest(
        owner: String = "owner@example.com",
        opponent: String = "romeo@example.com",
        originId: String,
        createdAt: Date = Date(timeIntervalSince1970: 1),
        replayRequired: Bool = false
    ) -> AccountQueuedMessageSendRequest {
        AccountQueuedMessageSendRequest(
            owner: owner,
            conversationJid: opponent,
            conversationType: .regular,
            messagePrimary: MessageStorageItem.genPrimary(messageId: originId, owner: owner),
            originId: originId,
            stanzaXML: """
            <message type='chat' to='\(opponent)' id='\(originId)' from='\(owner)'>
              <body>Hello</body>
              <origin-id xmlns='urn:xmpp:sid:0' id='\(originId)'/>
            </message>
            """,
            createdAt: createdAt,
            replayRequired: replayRequired
        )
    }

    private func storeSendingMessage(
        owner: String = "owner@example.com",
        opponent: String = "romeo@example.com",
        originId: String,
        includeReference: Bool = false,
        state: MessageStorageItem.MessageSendingState = .sending,
        archivedId: String = "",
        includeStoredStanza: Bool = false
    ) throws {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.owner = owner
        message.opponent = opponent
        message.outgoing = true
        message.messageId = originId
        message.primary = MessageStorageItem.genPrimary(messageId: originId, owner: owner)
        message.conversationType = .regular
        message.displayAs = .text
        message.body = "Hello"
        message.legacyBody = "Hello"
        message.state = state
        message.archivedId = archivedId
        message.date = Date(timeIntervalSince1970: 1)
        message.sentDate = message.date
        if includeReference {
            let reference = MessageReferenceStorageItem()
            reference.owner = owner
            reference.jid = opponent
            reference.messageId = message.primary
            reference.conversationType = .regular
            reference.kind = .quote
            message.references.append(reference)
        }
        try realm.write {
            realm.add(message, update: .modified)
            if includeStoredStanza {
                let stanza = MessageStanzaStorageItem()
                stanza.set(
                    originId,
                    for: owner,
                    with: makeRequest(owner: owner, opponent: opponent, originId: originId).stanzaXML,
                    at: message.date,
                    primary: message.primary
                )
                realm.add(stanza, update: .modified)
            }
        }
    }

    private func makeMessageForPendingDeletePolicy(
        outgoing: Bool,
        state: MessageStorageItem.MessageSendingState,
        archivedId: String
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.outgoing = outgoing
        message.state = state
        message.archivedId = archivedId
        message.displayAs = .text
        return message
    }

    private func storeLastChat(
        owner: String = "owner@example.com",
        opponent: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(jid: opponent, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.jid = opponent
        chat.conversationType = conversationType
        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func storeRosterItem(owner: String, jid: String) throws {
        let realm = try WRealm.safe()
        let roster = RosterStorageItem()
        roster.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        roster.owner = owner
        roster.jid = jid
        roster.username = "Juliet"
        try realm.write {
            realm.add(roster, update: .modified)
        }
    }

    private func makeIQ(_ xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        return XMPPIQ(from: root)
    }
}

private struct AccountPrimaryStreamTrackerHarness {
    let tracker: AccountPrimaryStreamStanzaTracker
    let scheduler: AccountPrimaryStreamTestScheduler
    private let timeoutBox: AccountPrimaryStreamTimeoutBox

    init(
        tracker: AccountPrimaryStreamStanzaTracker,
        scheduler: AccountPrimaryStreamTestScheduler,
        timeoutBox: AccountPrimaryStreamTimeoutBox
    ) {
        self.tracker = tracker
        self.scheduler = scheduler
        self.timeoutBox = timeoutBox
    }

    var timeouts: [PrimaryStreamTrackedStanza] {
        timeoutBox.timeouts
    }
}

private final class AccountPrimaryStreamTimeoutBox {
    var timeouts: [PrimaryStreamTrackedStanza] = []
}

private final class AccountPrimaryStreamSendCoordinatorRecorder {
    var sentMessages: [XMPPMessage] = []
}

private final class AccountPrimaryStreamSendCoordinatorLogger {
    var events: [(event: String, details: [String: Any?])] = []
}

private final class AccountPrimaryStreamTestScheduler: AccountConnectionResilienceScheduling {
    private final class Scheduled: AccountConnectionResilienceCancellable {
        let id: Int
        let due: TimeInterval
        let block: () -> Void
        var isCancelled = false

        init(id: Int, due: TimeInterval, block: @escaping () -> Void) {
            self.id = id
            self.due = due
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private var nextID = 0
    private var scheduled: [Scheduled] = []

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> AccountConnectionResilienceCancellable {
        nextID += 1
        let scheduled = Scheduled(id: nextID, due: now + max(0, delay), block: block)
        self.scheduled.append(scheduled)
        return scheduled
    }

    func advance(by interval: TimeInterval) {
        now += interval
        while let next = scheduled
            .filter({ !$0.isCancelled && $0.due <= now })
            .sorted(by: { lhs, rhs in
                if lhs.due == rhs.due {
                    return lhs.id < rhs.id
                }
                return lhs.due < rhs.due
            })
            .first {
            next.cancel()
            next.block()
        }
        scheduled.removeAll { $0.isCancelled }
    }

    func fireCancelledCallbacks() {
        let cancelled = scheduled
            .filter(\.isCancelled)
            .sorted(by: { lhs, rhs in
                if lhs.due == rhs.due {
                    return lhs.id < rhs.id
                }
                return lhs.due < rhs.due
            })
        scheduled.removeAll { $0.isCancelled }
        cancelled.forEach {
            $0.block()
        }
    }
}
