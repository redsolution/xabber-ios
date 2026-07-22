import XCTest
import UIKit
import RealmSwift
@testable import xabber

private final class ChatSkeletonWeakBox<Value: AnyObject> {
    weak var value: Value?
}

@MainActor
final class ChatSkeletonLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SkeletonMessageCell.reduceMotionOverrideForTesting = nil
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
    }

    override func tearDown() {
        SkeletonMessageCell.reduceMotionOverrideForTesting = nil
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        super.tearDown()
    }

    func testRepeatedBootstrapAcquireJoinsOriginalQueryAndKeepsAbsoluteDeadline() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )

        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-first",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let firstLease) = first else {
            return XCTFail("first acquire must own transport start")
        }

        now = now.addingTimeInterval(12)
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-reopen",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let reopenedLease) = reopened else {
            return XCTFail("reopen must join the active bootstrap")
        }

        XCTAssertEqual(reopenedLease.queryId, firstLease.queryId)
        XCTAssertEqual(reopenedLease.deadline, firstLease.deadline)
        XCTAssertEqual(
            coordinator.remainingTimeout(key: key, queryId: firstLease.queryId),
            33,
            accuracy: 0.001
        )
    }

    func testControllerTeardownLeavesBootstrapLeaseForReopenedController() {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let firstController = makeController()
        let key = firstController.initialBootstrapRequestKey
        var cancellationCount = 0
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-controller-first",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let firstLease) = first else {
            return XCTFail("first controller must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: firstLease.queryId,
            result: .bootstrapStarted(queryId: firstLease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        firstController.beginInitialBootstrapTracking(
            queryId: firstLease.queryId,
            timeout: nil
        )

        firstController.performTerminalChatResourceTeardownForTesting()

        XCTAssertNil(firstController.initialBootstrapQueryId)
        XCTAssertFalse(firstController.isInitialBootstrapInFlight)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: firstLease.queryId))
        XCTAssertEqual(cancellationCount, 0)

        let reopenedController = makeController()
        let reopened = coordinator.acquire(
            key: reopenedController.initialBootstrapRequestKey,
            proposedQueryId: "bootstrap-controller-reopen",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let reopenedLease) = reopened else {
            return XCTFail("reopened controller must join the surviving transport lease")
        }
        XCTAssertEqual(reopenedLease.queryId, firstLease.queryId)
        XCTAssertEqual(reopenedLease.deadline, firstLease.deadline)
        XCTAssertEqual(cancellationCount, 0)

        XCTAssertTrue(coordinator.complete(key: key, queryId: firstLease.queryId))
    }

    func testDelayedBootstrapStartResultCannotReviveTornDownController() {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let controller = makeController()
        let key = controller.initialBootstrapRequestKey
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-delayed-start",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("test setup must own transport start")
        }
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)

        controller.handleSyncChatStartResult(
            .bootstrapStarted(queryId: lease.queryId),
            expectedQueryId: lease.queryId
        )
        controller.performTerminalChatResourceTeardownForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(controller.initialBootstrapTimeoutWorkItem)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
    }

    func testStaleNoopStartResultCannotResetNewerBootstrapTracking() {
        let controller = makeController()
        controller.beginInitialBootstrapTracking(queryId: "bootstrap-old", timeout: nil)
        controller.handleSyncChatStartResult(
            .noop,
            expectedQueryId: "bootstrap-old"
        )
        controller.beginInitialBootstrapTracking(queryId: "bootstrap-new", timeout: nil)

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.initialBootstrapQueryId, "bootstrap-new")
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testArchiveConfirmedChatDoesNotReserveOrEnterBootstrapTracking() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSkeletonLifecycleTests-confirmed-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let controller = makeController()
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = controller.conversationType
        chat.messageDate = Date()
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.setPrimary(withOwner: controller.owner)
        try realm.write {
            realm.add(chat, update: .modified)
        }

        let key = controller.initialBootstrapRequestKey
        var cancellationCount = 0
        let existing = ChatInitialBootstrapRequestCoordinator.shared.acquire(
            key: key,
            proposedQueryId: "bootstrap-confirmed-existing",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let existingLease) = existing else {
            return XCTFail("test setup must reserve the existing bootstrap")
        }
        ChatInitialBootstrapRequestCoordinator.shared.resolveStart(
            key: key,
            queryId: existingLease.queryId,
            result: .bootstrapStarted(queryId: existingLease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        let cachedFinal = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: existingLease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: 0
            ),
            first: "",
            last: "",
            count: 0,
            streamKind: .uiAction,
            source: .unroutedFinalIQ
        )
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(cachedFinal))

        controller.requestInitialBootstrapArchive()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertFalse(ChatInitialBootstrapRequestCoordinator.shared.isActive(
            key: key,
            queryId: existingLease.queryId
        ))
        XCTAssertEqual(cancellationCount, 0)
        let probe = ChatInitialBootstrapRequestCoordinator.shared.acquire(
            key: key,
            proposedQueryId: "bootstrap-confirmed-probe",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let probeLease) = probe else {
            return XCTFail("confirmed local archive must not reserve a bootstrap lease")
        }
        XCTAssertTrue(ChatInitialBootstrapRequestCoordinator.shared.complete(
            key: key,
            queryId: probeLease.queryId
        ))
    }

    func testBootstrapAbsoluteTimeoutCancelsOnceAndPersistsFailureUntilRetry() {
        var now = Date(timeIntervalSince1970: 2_000)
        var cancellationCount = 0
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-timeout",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("first acquire must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )

        now = now.addingTimeInterval(46)
        coordinator.expireDueAttemptsForTesting()
        coordinator.expireDueAttemptsForTesting()

        XCTAssertEqual(cancellationCount, 1)
        let afterTimeout = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-must-not-start",
            timeout: 45
        ) { _, _, _ in }
        guard case .terminal(let event) = afterTimeout else {
            return XCTFail("reopen after timeout must expose terminal state")
        }
        XCTAssertEqual(event.queryId, lease.queryId)
        XCTAssertEqual(event.reason, .timeout)

        coordinator.clearTerminal(key: key)
        let retry = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-retry",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let retryLease) = retry else {
            return XCTFail("explicit retry must create a new attempt")
        }
        XCTAssertEqual(retryLease.queryId, "bootstrap-retry")
    }

    func testExternalTransportFailureCancelsLeaseAndPersistsTerminalState() {
        var cancellationCount = 0
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-disconnect",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("first acquire must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        let failure = MessageArchiveRequestFailureEvent(
            owner: key.owner,
            queryId: lease.queryId,
            streamKind: .uiAction,
            reason: .uiActionDisconnect,
            errorDescription: nil,
            pendingQueryCount: 1
        )

        XCTAssertTrue(MessageArchiveRequestFailureDispatcher.publish(failure))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(cancellationCount, 1)
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-after-disconnect",
            timeout: 45
        ) { _, _, _ in }
        guard case .terminal(let terminalFailure) = reopened else {
            return XCTFail("reopen after disconnect must expose terminal state")
        }
        XCTAssertEqual(terminalFailure.queryId, lease.queryId)
        XCTAssertEqual(terminalFailure.reason, .uiActionDisconnect)
    }

    func testBootstrapCompletionReleasesLeaseWithoutCancellingTransport() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        var cancellationCount = 0
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-complete",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("first acquire must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )

        coordinator.complete(key: key, queryId: lease.queryId)

        XCTAssertEqual(cancellationCount, 0)
        let next = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-next",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let nextLease) = next else {
            return XCTFail("completed attempt must release the conversation lease")
        }
        XCTAssertEqual(nextLease.queryId, "bootstrap-next")
    }

    func testBootstrapFinalPageSurvivesReopenAndCannotBecomeTimeout() {
        var now = Date(timeIntervalSince1970: 3_000)
        var cancellationCount = 0
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-final",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("first acquire must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        let finalEvent = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 1
            ),
            first: "archive-1",
            last: "archive-1",
            count: 1,
            streamKind: .uiAction,
            source: .unroutedFinalIQ
        )

        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(finalEvent))
        // The dispatcher has accepted the final synchronously even if its
        // controller delivery is still waiting on the main queue. The absolute
        // deadline must not overwrite that accepted final with a timeout.
        now = now.addingTimeInterval(60)
        coordinator.expireDueAttemptsForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-must-join-final",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let reopenedLease) = reopened else {
            return XCTFail("reopen must join the final-received attempt")
        }
        XCTAssertEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertEqual(
            coordinator.cachedEndPageEvent(key: key, queryId: lease.queryId),
            finalEvent
        )
        XCTAssertEqual(cancellationCount, 0)
    }

    func testAcceptedFinalCannotLoseToTimeoutBeforeSynchronousHandlerRuns() {
        var now = Date(timeIntervalSince1970: 3_500)
        var cancellationCount = 0
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-accepted-final",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("first acquire must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        let finalEvent = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 1
            ),
            first: "archive-accepted",
            last: "archive-accepted",
            count: 1,
            streamKind: .uiAction,
            source: .unroutedFinalIQ
        )
        let markerAccepted = expectation(description: "final marker accepted")
        let publishFinished = expectation(description: "final publish finished")
        let allowSynchronousDelivery = DispatchSemaphore(value: 0)
        MessageArchiveEndPageDispatcher.setSynchronousDeliveryAcceptedHookForTests { event in
            guard event.queryId == lease.queryId else { return }
            markerAccepted.fulfill()
            allowSynchronousDelivery.wait()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = MessageArchiveEndPageDispatcher.publish(finalEvent)
            publishFinished.fulfill()
        }
        wait(for: [markerAccepted], timeout: 3)

        now = now.addingTimeInterval(60)
        coordinator.expireDueAttemptsForTesting()

        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))
        XCTAssertEqual(cancellationCount, 0)
        allowSynchronousDelivery.signal()
        wait(for: [publishFinished], timeout: 3)

        XCTAssertEqual(
            coordinator.cachedEndPageEvent(key: key, queryId: lease.queryId),
            finalEvent
        )
        XCTAssertEqual(cancellationCount, 0)
    }

    func testControllerTimeoutFallbackCannotOverrideAcceptedFinal() {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let controller = makeController()
        let key = controller.initialBootstrapRequestKey
        var cancellationCount = 0
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-controller-final-race",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("test setup must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)
        let finalEvent = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: 0
            ),
            first: "",
            last: "",
            count: 0,
            streamKind: .uiAction,
            source: .unroutedFinalIQ
        )
        let markerAccepted = expectation(description: "controller race marker accepted")
        let publishFinished = expectation(description: "controller race publish finished")
        let allowSynchronousDelivery = DispatchSemaphore(value: 0)
        MessageArchiveEndPageDispatcher.setSynchronousDeliveryAcceptedHookForTests { event in
            guard event.queryId == lease.queryId else { return }
            markerAccepted.fulfill()
            allowSynchronousDelivery.wait()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MessageArchiveEndPageDispatcher.publish(finalEvent)
            publishFinished.fulfill()
        }
        wait(for: [markerAccepted], timeout: 3)

        controller.scheduleInitialBootstrapTimeout(queryId: lease.queryId, timeout: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertEqual(controller.initialBootstrapQueryId, lease.queryId)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))
        XCTAssertEqual(cancellationCount, 0)

        allowSynchronousDelivery.signal()
        wait(for: [publishFinished], timeout: 3)
        controller.performTerminalChatResourceTeardownForTesting()
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
    }

    func testLateFinalMarkerCannotSuppressAlreadyRecordedTimeoutFailure() {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let controller = makeController()
        let key = controller.initialBootstrapRequestKey
        var cancellationCount = 0
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-timeout-before-marker",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("test setup must own transport start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { cancellationCount += 1 }
        )
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)
        let timeoutEvent = MessageArchiveRequestFailureEvent(
            owner: key.owner,
            queryId: lease.queryId,
            streamKind: .unknown,
            reason: .timeout,
            errorDescription: nil,
            pendingQueryCount: 1
        )
        XCTAssertTrue(coordinator.recordFailure(
            key: key,
            event: timeoutEvent,
            publishEvent: false
        ))
        XCTAssertEqual(cancellationCount, 1)

        let dummyEndToken = MessageArchiveEndPageDispatcher.register(
            owner: key.owner,
            queryId: lease.queryId,
            delivery: .synchronous
        ) { _ in }
        let finalEvent = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: 0
            ),
            first: "",
            last: "",
            count: 0,
            streamKind: .uiAction,
            source: .unroutedFinalIQ
        )
        let markerAccepted = expectation(description: "late final marker accepted")
        let publishFinished = expectation(description: "late final publish finished")
        let allowSynchronousDelivery = DispatchSemaphore(value: 0)
        MessageArchiveEndPageDispatcher.setSynchronousDeliveryAcceptedHookForTests { event in
            guard event.queryId == lease.queryId else { return }
            markerAccepted.fulfill()
            allowSynchronousDelivery.wait()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MessageArchiveEndPageDispatcher.publish(finalEvent)
            publishFinished.fulfill()
        }
        wait(for: [markerAccepted], timeout: 3)

        controller.handleInitialBootstrapRemoteArchiveFailure(
            queryId: lease.queryId,
            reason: .timeout,
            streamKind: .unknown,
            errorDescription: nil
        )

        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(controller.initialBootstrapQueryId)
        allowSynchronousDelivery.signal()
        wait(for: [publishFinished], timeout: 3)
        MessageArchiveEndPageDispatcher.unregister(dummyEndToken)
    }

    func testCachedFinalKeepsMessageManagerAliveUntilReopenConsumesIt() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-strong-persistence-owner",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("first acquire must own transport start")
        }
        let baselineManager = ChatSkeletonWeakBox<MessageManager>()
        autoreleasepool {
            let manager = makeNonRetainingMessageManager(owner: key.owner)
            baselineManager.value = manager
        }
        XCTAssertNil(
            baselineManager.value,
            "the fixture itself must not retain MessageManager"
        )

        let releasedManager = ChatSkeletonWeakBox<MessageManager>()
        autoreleasepool {
            let manager = makeNonRetainingMessageManager(owner: key.owner)
            releasedManager.value = manager
            coordinator.resolveStart(
                key: key,
                queryId: lease.queryId,
                result: .bootstrapStarted(queryId: lease.queryId),
                messages: manager,
                cancelTransport: {}
            )
        }
        let finalEvent = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 1
            ),
            first: "archive-retained",
            last: "archive-retained",
            count: 1,
            streamKind: .uiAction,
            source: .unroutedFinalIQ
        )
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(finalEvent))
        XCTAssertNotNil(releasedManager.value)
        let persistenceDeadline = Date().addingTimeInterval(2)
        while coordinator.cachedCommittedPage(key: key, queryId: lease.queryId) == nil,
              Date() < persistenceDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(
            coordinator.cachedCommittedPage(key: key, queryId: lease.queryId),
            "reopen cache must be published only after the query persistence barrier"
        )

        var reopenedManager: MessageManager?
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-reopen-must-join",
            timeout: 45
        ) { _, _, messages in
            reopenedManager = messages
        }
        guard case .joined(let reopenedLease) = reopened else {
            return XCTFail("reopen must join the final-received attempt")
        }
        XCTAssertEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertTrue(reopenedManager === releasedManager.value)

        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
        reopenedManager = nil
        autoreleasepool {}
        XCTAssertNil(releasedManager.value)
    }

    func testRemoteHistoryPersistenceFlushIsSingleFlightAndMemoizedForLateConsumer() {
        let singleFlight = ChatRemoteHistoryFlushSingleFlight<String, Int>(completedCapacity: 4)
        var producerCount = 0
        var finishProduction: ((Int) -> Void)?
        var received: [Int] = []

        for _ in 0..<2 {
            singleFlight.run(
                key: "shared-query",
                producer: { finish in
                    producerCount += 1
                    finishProduction = finish
                },
                completion: { received.append($0) }
            )
        }

        XCTAssertEqual(producerCount, 1)
        XCTAssertTrue(received.isEmpty)
        finishProduction?(7)
        XCTAssertEqual(received, [7, 7])

        singleFlight.run(
            key: "shared-query",
            producer: { finish in
                producerCount += 1
                finish(0)
            },
            completion: { received.append($0) }
        )

        XCTAssertEqual(producerCount, 1)
        XCTAssertEqual(received, [7, 7, 7])
    }

    func testRemoteHistoryPersistenceFlushMemoizationIsBounded() {
        let singleFlight = ChatRemoteHistoryFlushSingleFlight<String, Int>(completedCapacity: 1)
        var producerCount = 0

        func run(_ key: String) {
            singleFlight.run(
                key: key,
                producer: { finish in
                    producerCount += 1
                    finish(producerCount)
                },
                completion: { _ in }
            )
        }

        run("first")
        run("second")
        run("first")

        XCTAssertEqual(producerCount, 3)
    }

    func testLateBootstrapStartAfterTimeoutCancelsTransportOnlyOnce() {
        var now = Date(timeIntervalSince1970: 4_000)
        var cancellationCount = 0
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            now: { now },
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-late-start",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = first else {
            return XCTFail("first acquire must own transport start")
        }

        now = now.addingTimeInterval(46)
        coordinator.expireDueAttemptsForTesting()
        for _ in 0..<2 {
            coordinator.resolveStart(
                key: key,
                queryId: lease.queryId,
                result: .bootstrapStarted(queryId: lease.queryId),
                messages: nil,
                cancelTransport: { cancellationCount += 1 }
            )
        }

        XCTAssertEqual(cancellationCount, 1)
    }

    func testSkeletonMappingKeepsDeterministicIDsDatesTextAndHeights() {
        let controller = makeController()
        var context = controller.captureDatasourceMappingContext()
        context.showSkeleton = true

        let first = controller.mapDataset(dataset: [], context: context)
        let second = controller.mapDataset(dataset: [], context: context)

        XCTAssertEqual(first.datasource.map(\.primary), second.datasource.map(\.primary))
        XCTAssertEqual(first.datasource.map(\.messageId), second.datasource.map(\.messageId))
        XCTAssertEqual(first.datasource.map(\.sentDate), second.datasource.map(\.sentDate))
        XCTAssertEqual(first.datasource.map(messageText), second.datasource.map(messageText))
        XCTAssertEqual(
            first.datasource.compactMap { first.layoutSnapshot.layout(forPrimary: $0.primary)?.cellSize },
            second.datasource.compactMap { second.layoutSnapshot.layout(forPrimary: $0.primary)?.cellSize }
        )
        XCTAssertEqual(Set(first.datasource.map(\.primary)).count, first.datasource.count)
        XCTAssertEqual(first.datasource.count, ChatSkeletonTemplate.descriptors.count)
    }

    func testMappedSkeletonMinimumHeightMatchesEquivalentTextMessage() throws {
        let controller = makeController()
        var context = controller.captureDatasourceMappingContext()
        context.showSkeleton = true

        let result = controller.mapDataset(dataset: [], context: context)
        let skeleton = try XCTUnwrap(result.datasource.first)
        let skeletonLayout = try XCTUnwrap(
            result.layoutSnapshot.layout(forPrimary: skeleton.primary)
        )
        let skeletonText = try XCTUnwrap(messageText(skeleton))
        var textMessage = makeDatasource(primary: "minimum-text-message")
        textMessage.kind = .attributedText(NSAttributedString(
            string: skeletonText,
            attributes: context.bodyTextAttributes
        ))
        textMessage.outgoing = skeleton.outgoing
        textMessage.isOutgoing = skeleton.isOutgoing
        textMessage.timeMarkerText = NSAttributedString(
            string: "12:00",
            attributes: context.timeMarkerAttributes
        )
        textMessage.indicator = .none
        let textLayout = ChatMessageLayoutCalculator.measure(
            textMessage,
            context.layoutContext
        )

        XCTAssertEqual(
            skeletonLayout.cellSize.height,
            textLayout.cellSize.height,
            accuracy: 0.5
        )
        XCTAssertEqual(
            skeletonLayout.messageContainerSize.height,
            textLayout.messageContainerSize.height,
            accuracy: 0.5
        )
    }

    func testRepeatedVisibleConfigureDoesNotRestartSkeletonAnimation() {
        let cell = SkeletonMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))

        cell.updateAnimationVisibility(isVisible: true, reduceMotion: false)
        cell.updateAnimationVisibility(isVisible: true, reduceMotion: false)

        XCTAssertEqual(cell.activeSkeletonAnimationCount, 1)
        XCTAssertEqual(cell.skeletonAnimationStartCount, 1)
    }

    func testOffscreenReuseStopsAnimationAndVisibleResumeStartsOne() {
        let cell = SkeletonMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        cell.updateAnimationVisibility(isVisible: true, reduceMotion: false)

        cell.cancelOffscreenWork()
        XCTAssertEqual(cell.activeSkeletonAnimationCount, 0)

        cell.resumeOnscreenWork()
        XCTAssertEqual(cell.activeSkeletonAnimationCount, 1)
        XCTAssertEqual(cell.skeletonAnimationStartCount, 2)

        cell.prepareForReuse()
        XCTAssertEqual(cell.activeSkeletonAnimationCount, 0)
    }

    func testReduceMotionUsesStaticSkeleton() {
        let cell = SkeletonMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))

        cell.updateAnimationVisibility(isVisible: true, reduceMotion: true)

        XCTAssertEqual(cell.activeSkeletonAnimationCount, 0)
        XCTAssertEqual(cell.messageContainerView.alpha, SkeletonMessageCell.staticPlaceholderAlpha, accuracy: 0.001)
    }

    func testReducerImmediatelyUsesValidLocalContent() {
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 80,
                isSynced: true,
                isInitialArchiveLoaded: true,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false
            )),
            .content
        )
    }

    func testReducerUsesOnlyTargetBlockingStateForMissingExternalTarget() {
        let state = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 80,
            isSynced: true,
            isInitialArchiveLoaded: true,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: true,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false
        ))

        XCTAssertEqual(state, .blockingTarget)
        XCTAssertTrue(state.showsSkeleton)
        XCTAssertTrue(state.locksTimeline)
    }

    func testReducerSeparatesArchiveBlockingEmptyAndRetryableFailure() {
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 0,
                isSynced: false,
                isInitialArchiveLoaded: false,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false
            )),
            .blockingArchive
        )
        XCTAssertEqual(
            ChatBootstrapLoadingReducer.resolve(.init(
                messageCount: 0,
                isSynced: true,
                isInitialArchiveLoaded: true,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false,
                allowsStaleLocalHistory: false,
                hasTerminalFailure: false
            )),
            .empty
        )

        let failure = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: false,
            isInitialArchiveLoaded: false,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: true
        ))
        XCTAssertEqual(failure, .failure(fallback: .empty))
        XCTAssertTrue(failure.showsRetry)
        XCTAssertFalse(failure.locksTimeline)
        XCTAssertFalse(failure.showsSkeleton)
    }

    func testFailurePresentationExposesRetryWithoutTimelineLock() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.applyBootstrapLoadingState(.failure(fallback: .empty))

        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
        XCTAssertTrue(controller.loadDatasourceObserver.value)

        var retryCount = 0
        controller.bootstrapFailureView.onRetry = { retryCount += 1 }
        let retryButton = try XCTUnwrap(
            allSubviews(of: controller.bootstrapFailureView)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "chat.bootstrap.retry" }
        )
        retryButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(retryCount, 1)

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
    }

    func testBootstrapTransportPrefersReadyPrimaryAccountAndFallsBackOnlyWhenNeeded() {
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: true,
                primaryBootstrapGateActive: false
            ),
            .primaryAccount
        )
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: false,
                primaryBootstrapGateActive: false
            ),
            .uiAction
        )
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: false,
                primaryStreamReady: false,
                primaryBootstrapGateActive: false
            ),
            .uiAction
        )
        XCTAssertEqual(
            ChatInitialBootstrapTransportPolicy.resolve(
                hasPrimaryAccount: true,
                primaryStreamReady: true,
                primaryBootstrapGateActive: true
            ),
            .primaryAccount
        )
    }

    func testEqualReducerStateIsAnApplicationNoOp() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .blockingArchive
            ),
            .noOp
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .content
            ),
            .apply
        )
    }

    func testForcedEqualBlockingStateReappliesUntilSkeletonRowsAreCommitted() {
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
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .blockingArchive,
                hasCommittedContent: false,
                forceRender: true,
                hasCommittedSkeletonRows: true
            ),
            .noOp
        )
    }

    func testBlockedInitialPreparationCompletesOnlyAfterSkeletonRowsCommit() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(true)
        var completionCount = 0
        var hadCommittedFrameAtCompletion = false
        let completion = expectation(description: "committed bootstrap first frame")

        XCTAssertTrue(
            controller.prepareInitialLocalFirstFrame(
                chatInstance: nil,
                performPendingOpenMessageRequest: false
            ) {
                completionCount += 1
                hadCommittedFrameAtCompletion =
                    controller.hasCommittedBootstrapSkeletonRows &&
                    controller.messagesCollectionView.numberOfSections == controller.datasource.count
                completion.fulfill()
            }
        )

        XCTAssertEqual(
            completionCount,
            0,
            "stacked navigation preparation must not complete before the skeleton transaction"
        )
        wait(for: [completion], timeout: 2)
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(hadCommittedFrameAtCompletion)

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testStackedNavigationTimeoutReturnsOnlyAfterSkeletonRowsCommit() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(true)
        controller.isPreparingStackedNavigationPresentation = true

        controller.stackedNavigationPresentationPreparationDidTimeOut()

        XCTAssertFalse(controller.isPreparingStackedNavigationPresentation)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.isCommittedStackedNavigationFirstFrameReady)
        XCTAssertEqual(
            controller.messagesCollectionView.numberOfSections,
            controller.datasource.count,
            "navigation fallback may finish only after the collection transaction commits"
        )

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testStackedNavigationTimeoutSealsPreparedRealRowsWithoutReplacingThemWithSkeleton() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.datasource = [makeDatasource(primary: "prepared-real-message")]
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(true)
        controller.isPreparingStackedNavigationPresentation = true

        controller.stackedNavigationPresentationPreparationDidTimeOut()

        XCTAssertFalse(controller.isPreparingStackedNavigationPresentation)
        XCTAssertEqual(controller.datasource.map(\.primary), ["prepared-real-message"])
        XCTAssertTrue(controller.datasource.allSatisfy { !$0.isFakeMessage })
        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.isCommittedStackedNavigationFirstFrameReady)
        XCTAssertEqual(controller.messagesCollectionView.numberOfSections, 1)

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testFirstFrameTargetedDiffCommitsSynchronouslyWithoutLeavingBatchUpdateInFlight() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyChatDatasource(
            [makeDatasource(primary: "existing-real-message")],
            mode: .fullReload(),
            animated: false
        )
        controller.hasCommittedRealContentInCurrentLifecycle = false
        controller.isPreparingStackedNavigationPresentation = true

        controller.applyChatDatasource(
            [
                makeDatasource(primary: "existing-real-message"),
                makeDatasource(primary: "prepared-real-message")
            ],
            mode: .targetedDiff,
            animated: true
        )

        XCTAssertFalse(controller.isChatDatasourceStructuralTransactionActive)
        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertEqual(controller.messagesCollectionView.numberOfSections, 2)

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testContentTransitionReloadsWhenSkeletonHasNotCommittedAnyRows() {
        XCTAssertTrue(
            ChatBootstrapContentRenderPolicy.shouldReloadInitialWindow(
                forceRender: false,
                isShowingBootstrapPlaceholder: false,
                isDatasourceEmpty: true,
                hasCommittedRealContent: false
            ),
            "content that wins the skeleton race must still map its first frame"
        )
    }

    func testEmptyDatasourceIsNotACommittedBootstrapPlaceholder() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = []

        XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertFalse(controller.isShowingBootstrapPlaceholder)

        controller.applyChatDatasource(
            [makeDatasource(primary: "skeleton", isFakeMessage: true)],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )

        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.isShowingBootstrapPlaceholder)
    }

    func testForcedSkeletonMappingSurvivesOrdinaryMappingCancellation() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(true)

        controller.applyBootstrapLoadingState(.blockingArchive, forceRender: true)
        _ = controller.beginDatasetMappingJobForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
    }

    func testLateSkeletonCannotApplyAfterRealDatasourceRowsAreInstalled() {
        XCTAssertFalse(
            ChatBootstrapMappedSkeletonApplyPolicy.shouldApply(
                generationMatches: true,
                conversationMatches: true,
                loadingShowsSkeleton: true,
                skeletonVisibilityRequested: true,
                hasCommittedRealContent: false,
                hasRealDatasourceRows: true,
                hasCommittedSkeletonRows: false
            )
        )
    }

    func testPersistedInitialPageBypassesUnsyncedBootstrapAvailabilityExactlyOnce() {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSkeletonLifecycleTests-scoped-refresh-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        XCTAssertEqual(
            ChatLocalFirstFrameAvailabilityPolicy.decision(
                isSynced: false,
                isInitialArchiveLoaded: false,
                isInitialBootstrapInFlight: true,
                allowsStaleLocalHistory: false,
                allowsBootstrapFailureFallback: false,
                hasTrustedPersistedBootstrapPage: true
            ),
            .prepareLocal
        )

        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.beginInitialBootstrapTracking(queryId: "scoped-refresh", timeout: nil)

        XCTAssertTrue(controller.refreshInitialBootstrapTimelineAfterPersistenceIfNeeded(
            queryId: "scoped-refresh",
            hasPersistedPageContent: true
        ))
        if case .blockedArchiveBootstrap = controller.initialLocalFirstFramePhase {
            XCTFail("trusted post-persistence refresh must not re-enter the archive skeleton gate")
        }
        XCTAssertFalse(controller.refreshInitialBootstrapTimelineAfterPersistenceIfNeeded(
            queryId: "scoped-refresh",
            hasPersistedPageContent: true
        ))

        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testReopenedCommittedPageStillGetsPresentationWatchdog() {
        XCTAssertEqual(
            ChatInitialBootstrapPresentationWatchdogPolicy.timeout(
                hasCommittedPage: true,
                remainingTransportTimeout: 0,
                presentationTimeout: 45
            ),
            45
        )
    }

    func testCommittedContentCannotReenterBootstrapSkeletonDuringPagingMetadataRefresh() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .content,
                next: .blockingArchive
            ),
            .noOp
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .content,
                next: .blockingTarget
            ),
            .noOp
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .blockingArchive,
                next: .blockingTarget,
                hasCommittedContent: true
            ),
            .noOp
        )
    }

    func testLateBlockingMetadataKeepsCommittedMessageDatasourceInteractive() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = [makeDatasource(primary: "committed-message")]
        controller.appliedBootstrapLoadingState = .content
        controller.showSkeletonObserver.accept(false)
        controller.setDatasourceLoadingEnabled(true)

        controller.applyBootstrapLoadingState(.blockingArchive, forceRender: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .content)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), ["committed-message"])
        XCTAssertTrue(controller.loadDatasourceObserver.value)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
    }

    func testSavedPositionRealDatasourceCommitSealsLifecycleWhenLoadingTrackerIsStale() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(false)
        controller.setDatasourceLoadingEnabled(true)

        controller.applyChatDatasource(
            [makeDatasource(primary: "saved-position-message")],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)

        controller.applyBootstrapLoadingState(.blockingTarget, forceRender: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), ["saved-position-message"])
        XCTAssertTrue(controller.loadDatasourceObserver.value)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
    }

    func testNonEmptyInitialBootstrapFinishesOnlyAfterDatasourceTransactionCommits() {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSkeletonLifecycleTests-ui-commit-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.beginInitialBootstrapTracking(queryId: "bootstrap-ui-commit", timeout: 60)

        XCTAssertTrue(
            controller.handleInitialBootstrapEndPageIfNeeded(
                queryId: "bootstrap-ui-commit",
                state: MessageArchivePageEndState(
                    queryExhausted: false,
                    archiveEnded: false,
                    persistedMessageCount: 1
                ),
                count: 1,
                persistedMessageCount: 1,
                persistedRowsForQuery: 1,
                visibleRowsForConversation: 1
            )
        )
        XCTAssertEqual(controller.initialBootstrapQueryId, "bootstrap-ui-commit")
        XCTAssertFalse(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertNotNil(
            controller.initialBootstrapTimeoutWorkItem,
            "a persisted raw final must not disarm the presentation watchdog"
        )

        controller.applyChatDatasource(
            [makeDatasource(primary: "bootstrap-committed-message")],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(controller.initialBootstrapTimeoutWorkItem)
    }

    func testRawInitialBootstrapFinalCannotCompleteUIBeforeCoordinatorCommit() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let queryId = "bootstrap-coordinator-commit-gate"
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: queryId,
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("test setup must own the bootstrap lease")
        }

        let manager = makeNonRetainingMessageManager(owner: key.owner)
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: manager,
            cancelTransport: {}
        )
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)
        controller.registerRemoteHistoryEndPageDispatcher(queryId: lease.queryId)

        let coordinatorClaimedCommit = expectation(
            description: "coordinator owns the persistence terminal"
        )
        let allowCoordinatorCommit = DispatchSemaphore(value: 0)
        coordinator.persistenceCommitClaimObserver = { claimedQueryId in
            guard claimedQueryId == lease.queryId else { return }
            coordinatorClaimedCommit.fulfill()
            allowCoordinatorCommit.wait()
        }

        let final = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: 0
            ),
            first: "",
            last: "",
            count: 0,
            streamKind: .primary,
            source: .unroutedFinalIQ
        )
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(final))
        wait(for: [coordinatorClaimedCommit], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .persistence)
        XCTAssertEqual(controller.initialBootstrapQueryId, lease.queryId)
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        let coordinatorCommitted = expectation(description: "coordinator committed page")
        let observation = coordinator.observe(key: key) { readiness in
            if readiness?.phase == .committed {
                coordinatorCommitted.fulfill()
            }
        }
        allowCoordinatorCommit.signal()
        wait(for: [coordinatorCommitted], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)

        coordinator.detach(key: key, observation: observation)
        controller.performTerminalChatResourceTeardownForTesting()
        manager.unsubscribeReceiver()
    }

    func testSnapshotObserverCompletionCannotRemoveCommittedPageBeforeJoinedUIConsumesIt() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let queryId = "snapshot-joined-ui-commit-race"
        let acquisition = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: queryId,
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        )
        guard case .start(let lease) = acquisition else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("snapshot repair must own the shared conversation lease")
        }

        var snapshotObserverSawCommit = false
        let snapshotObservation = coordinator.observe(key: key) { readiness in
            if readiness?.phase == .committed {
                snapshotObserverSawCommit = true
            }
        }
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)

        let final = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: 0
            ),
            first: "",
            last: "",
            count: 0,
            streamKind: .primary,
            source: .unroutedFinalIQ
        )
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(final))
        XCTAssertTrue(snapshotObserverSawCommit)

        // Model the snapshot pump's already-enqueued terminal block winning the
        // main-queue race before the joined controller processes its observer hop.
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)

        coordinator.detach(key: key, observation: snapshotObservation)
        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testDatasetReconfigurationCannotForgetEarlierCommittedContentWhilePlaceholderIsVisible() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.hasCommittedRealContentInCurrentLifecycle = true
        controller.appliedBootstrapLoadingState = .blockingArchive
        controller.showSkeletonObserver.accept(false)
        controller.datasource = [makeDatasource(primary: "temporary-placeholder", isFakeMessage: true)]

        controller.configureDataset()
        controller.applyBootstrapLoadingState(.blockingTarget, forceRender: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), ["temporary-placeholder"])
    }

    func testDatasetReconfigurationKeepsPreparedTimelineSessionForUnchangedConversation() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        guard let preparedSession = controller.timelineSession else {
            return XCTFail("Expected the initial dataset configuration to create a timeline session")
        }
        controller.applyChatDatasource(
            [makeDatasource(primary: "prepared-message")],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )

        controller.configureDataset()

        XCTAssertTrue(
            controller.timelineSession === preparedSession,
            "A repeated lifecycle subscription must keep the session that prepared the first frame"
        )
        XCTAssertEqual(controller.datasource.map(\.primary), ["prepared-message"])
    }

    func testDatasetReconfigurationReplacesTimelineSessionWhenConversationScopeChanges() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let initialSession = try XCTUnwrap(controller.timelineSession)

        controller.owner = "replacement-owner@example.com"
        controller.configureDataset()
        let ownerSession = try XCTUnwrap(controller.timelineSession)
        XCTAssertFalse(ownerSession === initialSession)

        controller.jid = "replacement-peer@example.com"
        controller.configureDataset()
        let jidSession = try XCTUnwrap(controller.timelineSession)
        XCTAssertFalse(jidSession === ownerSession)

        controller.conversationType = .group
        controller.configureDataset()
        XCTAssertFalse(try XCTUnwrap(controller.timelineSession) === jidSession)
    }

    func testSkeletonToEightyRowsHasOneCommitAndNoEmptyIntermediateFrame() {
        let plan = ChatBootstrapAtomicRevealPlan.resolve(
            previous: .blockingArchive,
            destinationRowCount: 80
        )

        XCTAssertEqual(plan.datasourceApplyCount, 1)
        XCTAssertEqual(plan.destinationRowCount, 80)
        XCTAssertEqual(plan.intermediateEmptyFrameCount, 0)
    }

    func testBoundaryOverlayDoesNotChangeTimelineIdentityOrGeometry() {
        let identities = (0..<80).map { "message-\($0)" }

        XCTAssertFalse(ChatBoundaryLoadingPresentationPolicy.usesTimelineRow)
        XCTAssertEqual(
            ChatBoundaryLoadingPresentationPolicy.geometryDelta(
                messageRowCount: identities.count,
                contentHeight: 6_400
            ),
            .zero
        )
        XCTAssertEqual(identities, (0..<80).map { "message-\($0)" })
    }

    private func makeNonRetainingMessageManager(owner: String) -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        return manager
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "skeleton-owner@example.com"
        controller.jid = "skeleton-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.showSkeletonObserver.accept(true)
        return controller
    }

    private func messageText(_ item: ChatViewController.Datasource) -> String? {
        guard case .skeleton(let text) = item.kind else { return nil }
        return text.string
    }

    private func makeDatasource(
        primary: String,
        isFakeMessage: Bool = false
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "skeleton-peer@example.com",
            owner: "skeleton-owner@example.com",
            outgoing: false,
            sender: Sender(id: "skeleton-peer@example.com", displayName: "Peer"),
            messageId: "\(primary)-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: isFakeMessage
                ? .skeleton(NSAttributedString(string: primary))
                : .attributedText(NSAttributedString(string: primary)),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "archive-\(primary)",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: isFakeMessage,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .read,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
