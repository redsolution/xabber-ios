import XCTest
import UIKit
import RealmSwift
import XMPPFramework
@testable import xabber

private final class ChatSkeletonWeakBox<Value: AnyObject> {
    weak var value: Value?
}

private struct ChatInitialFrameRollbackObservation {
    let contentOffset: CGPoint
    let contentInsets: UIEdgeInsets
    let verticalScrollIndicatorInsets: UIEdgeInsets
    let horizontalScrollIndicatorInsets: UIEdgeInsets
    let layoutMatches: Bool
    let showsSkeleton: Bool
    let canLoadDatasource: Bool
    let loadDatasourceRelayValue: Bool
    let showsInitialMessage: Bool
    let bootstrapLoadingState: ChatBootstrapLoadingState?
    let showsBootstrapFailure: Bool
    let allowsBootstrapFailureFallback: Bool
    let preservesBootstrapFailureOverlayUntilRetryCommit: Bool
    let hasCommittedRealContent: Bool
    let hasCommittedSkeletonPresentation: Bool
    let hasCommittedTimelinePresentation: Bool
    let initialContentApplyCount: Int
    let lastAtomicRevealPlan: ChatBootstrapAtomicRevealPlan?
    let hasRenderedStableInitialHistory: Bool
    let initialHistoryAppearancePending: Bool
    let hasCompletedInitialHistoryViewAppearance: Bool
    let showsLoadingIndicator: Bool
    let showsArchiveLoadingIndicator: Bool
    let isCollectionUserInteractionEnabled: Bool
    let isCollectionScrollEnabled: Bool
    let isTimelineInteractionLoading: Bool
    let isTimelineInteractionLocked: Bool
}

private struct ChatTransientHighlightHarness {
    let controller: ChatViewController
    let cell: MessageContentCell
    let primary: String
    let tokenA: ChatInitialFrameEffectToken
    let tokenB: ChatInitialFrameEffectToken
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

    func testArchiveConfirmedChatDoesNotEnterTrackingAndRetainsCommittedReceipt() throws {
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
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType,
                in: realm
            )
            archiveState.newerLiveEdgeReached = true
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
            source: .localCallback
        )
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(cachedFinal))

        controller.requestInitialBootstrapArchive()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertTrue(ChatInitialBootstrapRequestCoordinator.shared.isActive(
            key: key,
            queryId: existingLease.queryId
        ), "durable account-scoped proof must remain available to a later open")
        XCTAssertEqual(cancellationCount, 0)
        let probe = ChatInitialBootstrapRequestCoordinator.shared.acquire(
            key: key,
            proposedQueryId: "bootstrap-confirmed-probe",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let probeLease) = probe else {
            return XCTFail("confirmed local archive must reuse the committed receipt")
        }
        XCTAssertEqual(probeLease.queryId, existingLease.queryId)
        XCTAssertTrue(ChatInitialBootstrapRequestCoordinator.shared.invalidateCommittedReceipt(
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

    func testBootstrapFinalPageSurvivesTimeoutAndStartsFreshGenerationWithoutProof() {
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

        XCTAssertEqual(
            coordinator.cachedEndPageEvent(key: key, queryId: lease.queryId),
            finalEvent
        )
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-fresh-after-unmaterialized-final",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let reopenedLease) = reopened else {
            return XCTFail(
                "a final without presentation proof must start a fresh generation"
            )
        }
        XCTAssertEqual(
            reopenedLease.queryId,
            "bootstrap-fresh-after-unmaterialized-final"
        )
        XCTAssertNotEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertFalse(coordinator.isActive(key: key, queryId: lease.queryId))
        XCTAssertTrue(coordinator.isActive(key: key, queryId: reopenedLease.queryId))
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertTrue(coordinator.complete(key: key, queryId: reopenedLease.queryId))
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
        XCTAssertEqual(cancellationCount, 0)
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

    func testCachedFinalReleasesMessageManagerAndStartsFreshGenerationWithoutProof() {
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
        let persistenceDeadline = Date().addingTimeInterval(2)
        while coordinator.cachedCommittedPage(key: key, queryId: lease.queryId) == nil,
              Date() < persistenceDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(
            coordinator.cachedCommittedPage(key: key, queryId: lease.queryId),
            "reopen cache must be published only after the query persistence barrier"
        )
        let releaseDeadline = Date().addingTimeInterval(2)
        while releasedManager.value != nil,
              Date() < releaseDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(
            releasedManager.value,
            "terminal commit must release the heavy MessageManager owner"
        )

        var reopenedManager: MessageManager?
        let reopened = coordinator.acquire(
            key: key,
            proposedQueryId: "bootstrap-reopen-fresh-generation",
            timeout: 45
        ) { _, _, messages in
            reopenedManager = messages
        }
        guard case .start(let reopenedLease) = reopened else {
            return XCTFail(
                "a nonmaterialized final must start a fresh archive generation"
            )
        }
        XCTAssertEqual(
            reopenedLease.queryId,
            "bootstrap-reopen-fresh-generation"
        )
        XCTAssertNotEqual(reopenedLease.queryId, lease.queryId)
        XCTAssertFalse(coordinator.isActive(key: key, queryId: lease.queryId))
        XCTAssertTrue(coordinator.isActive(key: key, queryId: reopenedLease.queryId))
        XCTAssertNil(reopenedManager)

        XCTAssertTrue(coordinator.complete(key: key, queryId: reopenedLease.queryId))
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
        XCTAssertTrue(controller.bootstrapFailureView.isRetrying)
        XCTAssertFalse(retryButton.isEnabled)

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)

        controller.setBootstrapFailureVisible(true)
        XCTAssertFalse(controller.bootstrapFailureView.isRetrying)
        XCTAssertTrue(retryButton.isEnabled)
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
            .uiAction
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

    func testRepeatedBlockingEventsPreserveRowsGenerationOrderSizeAndOffset() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = nil
        controller.showSkeletonObserver.accept(true)
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        controller.messagesCollectionView.layoutIfNeeded()

        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertEqual(controller.messagesCollectionView.numberOfSections, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.hasCommittedExactBootstrapSkeletonRows)
        let rowIDs = controller.datasource.map(\.primary)
        let messageIDs = controller.datasource.map(\.messageId)
        let rowOrder = controller.datasource.map(\.sentDate)
        let rowFrames = controller.datasource.indices.compactMap { section in
            controller.messagesCollectionView.collectionViewLayout
                .layoutAttributesForItem(
                    at: IndexPath(item: 0, section: section)
                )?.frame
        }
        let datasetGeneration = controller.datasetMappingGeneration
        let skeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let session = controller.timelineSession
        let contentOffset = controller.messagesCollectionView.contentOffset

        controller.scrollFrameOperationCounter.setEnabled(true)
        controller.scrollFrameOperationCounter.reset()

        controller.applyBootstrapLoadingState(
            .blockingTarget,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        XCTAssertEqual(controller.appliedBootstrapLoadingState, .blockingTarget)
        XCTAssertEqual(
            controller.bootstrapSkeletonMappingGeneration,
            skeletonGeneration,
            "the synchronous blocker transition must be state-only"
        )
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.messagesCollectionView.layoutIfNeeded()

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .blockingArchive)
        XCTAssertEqual(controller.datasource.map(\.primary), rowIDs)
        XCTAssertEqual(controller.datasource.map(\.messageId), messageIDs)
        XCTAssertEqual(controller.datasource.map(\.sentDate), rowOrder)
        XCTAssertEqual(
            controller.datasource.indices.compactMap { section in
                controller.messagesCollectionView.collectionViewLayout
                    .layoutAttributesForItem(
                        at: IndexPath(item: 0, section: section)
                    )?.frame
            },
            rowFrames
        )
        XCTAssertEqual(controller.datasetMappingGeneration, datasetGeneration)
        XCTAssertEqual(
            controller.bootstrapSkeletonMappingGeneration,
            skeletonGeneration,
            "an already committed skeleton changes logical blocker without another mapping generation"
        )
        XCTAssertTrue(controller.timelineSession === session)
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, contentOffset)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            0
        )
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.showSkeletonObserver.value)
    }

    func testBlockingStateOnlyTransitionRequiresCurrentLifecycleSkeletonCommit() {
        XCTAssertFalse(
            ChatCommittedSkeletonBlockingTransitionPolicy.shouldApplyStateOnly(
                previous: .blockingArchive,
                next: .blockingTarget,
                hasCommittedExactSkeletonRows: false,
                hasCommittedRealContent: false
            ),
            "a blocker change before the first skeleton commit must retain the render path"
        )
        XCTAssertTrue(
            ChatCommittedSkeletonBlockingTransitionPolicy.shouldApplyStateOnly(
                previous: .blockingArchive,
                next: .blockingTarget,
                hasCommittedExactSkeletonRows: true,
                hasCommittedRealContent: false
            )
        )
        XCTAssertFalse(
            ChatCommittedSkeletonBlockingTransitionPolicy.shouldApplyStateOnly(
                previous: .blockingArchive,
                next: .blockingArchive,
                hasCommittedExactSkeletonRows: true,
                hasCommittedRealContent: false
            ),
            "an equal state is an ordinary no-op, not a semantic transition"
        )
        XCTAssertFalse(
            ChatCommittedSkeletonBlockingTransitionPolicy.shouldApplyStateOnly(
                previous: .blockingArchive,
                next: .content,
                hasCommittedExactSkeletonRows: true,
                hasCommittedRealContent: false
            ),
            "terminal reveal semantics remain on the atomic datasource path"
        )
    }

    func testConversationReplacementRendersANewSkeletonGeneration() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = nil
        controller.showSkeletonObserver.accept(true)
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.hasCommittedExactBootstrapSkeletonRows)
        let firstConversationGeneration = controller.bootstrapSkeletonMappingGeneration
        let firstSession = controller.timelineSession

        controller.jid = "replacement-skeleton-peer@example.com"
        controller.opponentSender = Sender(
            id: controller.jid,
            displayName: "Replacement Peer"
        )
        controller.configureDataset()

        XCTAssertFalse(controller.timelineSession === firstSession)
        XCTAssertFalse(
            controller.hasCommittedExactBootstrapSkeletonRows,
            "conversation replacement must revoke the prior skeleton receipt"
        )

        controller.applyBootstrapLoadingState(
            .blockingTarget,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .blockingTarget)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.datasource.allSatisfy { $0.jid == controller.jid })
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.hasCommittedExactBootstrapSkeletonRows)
        XCTAssertGreaterThan(
            controller.bootstrapSkeletonMappingGeneration,
            firstConversationGeneration,
            "the replacement conversation owns a fresh skeleton mapping generation"
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
            5
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

    func testConfirmedEmptyCannotReenterSkeletonAfterLateBootstrapMetadata() {
        for blockingState in [
            ChatBootstrapLoadingState.blockingArchive,
            .blockingTarget
        ] {
            XCTAssertEqual(
                ChatBootstrapStateApplicationPolicy.decision(
                    previous: .empty,
                    next: blockingState
                ),
                .noOp,
                "a terminal empty first frame is monotonic for one controller lifecycle"
            )
        }

        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = .empty
        controller.showSkeletonObserver.accept(false)
        controller.setDatasourceLoadingEnabled(true)
        let session = controller.timelineSession
        let mappingGeneration = controller.datasetMappingGeneration
        let contentOffset = controller.messagesCollectionView.contentOffset
        let firstContentApplyCount = controller.initialFirstContentApplyCount

        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .empty)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.isEmpty)
        XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertTrue(controller.timelineSession === session)
        XCTAssertEqual(controller.datasetMappingGeneration, mappingGeneration)
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, contentOffset)
        XCTAssertEqual(
            controller.initialFirstContentApplyCount,
            firstContentApplyCount
        )
        XCTAssertTrue(controller.loadDatasourceObserver.value)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
    }

    func testMatchingExactInitialFrameOwnsPendingRequestAcrossStackedFallback() {
        let controller = makeController()
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "stacked-fallback-exact-anchor"
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )

        XCTAssertTrue(
            ChatInitialFramePendingRequestOwnershipPolicy
                .isOwnedByInitialFrame(
                    request: request,
                    phase: .preparing(descriptor)
                ),
            "didShow after the stacked skeleton fallback must not start a second anchor pipeline while the exact initial frame is mapping"
        )
        XCTAssertTrue(
            ChatInitialFramePendingRequestOwnershipPolicy
                .isOwnedByInitialFrame(
                    request: request,
                    phase: .presenting(descriptor)
                ),
            "the exact initial frame keeps ownership through its atomic UIKit transaction"
        )
        XCTAssertFalse(
            ChatInitialFramePendingRequestOwnershipPolicy
                .isOwnedByInitialFrame(
                    request: request,
                    phase: .committed(descriptor)
                ),
            "the initial-frame ownership barrier must end after commit"
        )

        let replacementRequest = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "stacked-fallback-replacement-anchor"
        )
        XCTAssertFalse(
            ChatInitialFramePendingRequestOwnershipPolicy
                .isOwnedByInitialFrame(
                    request: replacementRequest,
                    phase: .preparing(descriptor)
                ),
            "a different exact intent must remain eligible to supersede stale initial-frame ownership"
        )
    }

    func testOwnedDidShowResumeReplaysGenericExactlyOnceAfterBlockedInitialFrame() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "stacked-fallback-blocked-anchor"
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        var genericExecutionCount = 0
        controller.pendingOpenMessageGenericExecutionInterceptorForTests = {
            genericExecutionCount += 1
            return true
        }
        defer {
            controller.pendingOpenMessageGenericExecutionInterceptorForTests = nil
        }

        controller.pendingOpenMessageRequest = request
        controller.initialLocalFirstFramePhase = .preparing(descriptor)
        controller.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
        controller.performPendingOpenMessageRequestIfNeeded(trigger: .manual)

        XCTAssertTrue(
            controller.initialLocalFirstFrameShouldPerformPendingRequest,
            "duplicate didShow/resume callbacks collapse into one terminal replay latch"
        )
        XCTAssertEqual(genericExecutionCount, 0)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)

        controller.initialLocalFirstFramePhase =
            .blockedMissingTarget(descriptor)
        controller.finishInitialLocalFirstFramePreparationForTesting()
        controller.finishInitialLocalFirstFramePreparationForTesting()

        XCTAssertFalse(
            controller.initialLocalFirstFrameShouldPerformPendingRequest
        )
        XCTAssertEqual(
            genericExecutionCount,
            1,
            "the blocked terminal releases exactly one deferred generic execution"
        )
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)
        XCTAssertNil(controller.activeAnchorExecutionState)

        controller.pendingOpenMessageRequest = nil
        controller.initialLocalFirstFramePhase = .committed(descriptor)
        controller.initialLocalFirstFrameShouldPerformPendingRequest = true
        controller.finishInitialLocalFirstFramePreparationForTesting()

        XCTAssertEqual(
            genericExecutionCount,
            1,
            "a successful initial commit has already consumed the request, so its replay is a no-op"
        )
    }

    func testDuplicateQueueDuringPresentingKeepsInitialOwnerAndReplacementStillExecutes() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let targetPrimary = "stacked-fallback-presenting-anchor"
        let targetRow = makeDatasource(primary: targetPrimary)
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: targetRow.archivedId ?? ""
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        controller.datasource = [targetRow]
        controller.datasourceSnapshot = ChatDatasourceSnapshot(
            items: [targetRow]
        )
        controller.pendingOpenMessageRequest = request
        controller.initialLocalFirstFramePhase = .presenting(descriptor)
        let hooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onFailed: nil,
            onPositioned: nil
        )

        controller.queueOpenMessageRequest(request, hooks: hooks)

        XCTAssertEqual(controller.pendingOpenMessageRequest, request)
        XCTAssertNil(
            controller.activeAnchorExecutionState,
            "a duplicate delivery must not enter the loaded-message fast path during the atomic initial transaction"
        )
        XCTAssertNotNil(controller.activeAnchorExecutionHooks)
        XCTAssertTrue(controller.initialLocalFirstFrameShouldPerformPendingRequest)

        var replacementExecutionCount = 0
        controller.pendingOpenMessageGenericExecutionInterceptorForTests = {
            replacementExecutionCount += 1
            return true
        }
        defer {
            controller.pendingOpenMessageGenericExecutionInterceptorForTests = nil
        }
        let replacementRequest = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "stacked-fallback-new-explicit-anchor"
        )

        controller.queueOpenMessageRequest(
            replacementRequest,
            hooks: nil
        )

        XCTAssertEqual(replacementExecutionCount, 1)
        XCTAssertEqual(
            controller.pendingOpenMessageRequest,
            replacementRequest
        )
        XCTAssertFalse(
            controller.initialLocalFirstFrameShouldPerformPendingRequest,
            "the replacement owns its immediate generic execution and must not inherit the old request's terminal replay"
        )
    }

    func testReentrantReplacementRevokesPresentingAttemptAndAtomicallyRestoresPriorViewportBeforeReplay() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.messagesCollectionView.frame = controller.view.bounds
        let priorRow = makeDatasource(primary: "p14-prior-placeholder")
        controller.applyChatDatasource(
            [priorRow],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        controller.messagesCollectionView.contentOffset = CGPoint(x: 0, y: 17)

        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-presenting-a"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-reentrant-b"
        )
        let tokenA = ChatAnchorTransactionToken(rawValue: "p14-token-a")
        let mappingTokenA = ChatDatasetMappingCancellationToken(
            generation: controller.datasetMappingGeneration,
            cancellationCheckInterval: 1
        )
        let session = try XCTUnwrap(controller.timelineSession)
        let descriptorA = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: requestA,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let attemptA = ChatInitialFramePresentationAttempt(
            descriptor: descriptorA,
            mappingToken: mappingTokenA,
            mappingGeneration: controller.datasetMappingGeneration,
            session: session,
            timelineGeneration: session.snapshot.generation,
            anchorTransactionToken: tokenA,
            presentationGeneration: 1,
            performanceTraceContext: nil,
            ownsPerformancePresentingInterval: false
        )
        controller.pendingOpenMessageRequest = requestA
        controller.activeAnchorExecutionState = ChatAnchorExecutionState(
            request: requestA,
            transactionToken: tokenA
        )
        _ = controller.anchorTransactionGate.begin(
            token: tokenA,
            requestIdentity: "p14-presenting-a"
        )
        controller.initialLocalFirstFrameMappingToken = mappingTokenA
        controller.initialLocalFirstFramePhase = .presenting(descriptorA)
        controller.initialLocalFirstFramePresentationOwnership =
            ChatInitialFramePresentationOwnership(
                attempt: attemptA,
                phase: .presenting
            )

        let priorPrimaries = controller.datasource.map(\.primary)
        let priorSnapshotPrimaries = controller.datasourceSnapshot.items.map(\.primary)
        let priorOffset = controller.messagesCollectionView.contentOffset
        let priorInsets = controller.messagesCollectionView.contentInset
        let priorResidentGeneration = controller.scrollResidentMetadata.generation

        controller.queueOpenMessageRequest(requestB, hooks: nil)

        XCTAssertNil(controller.initialLocalFirstFramePresentationOwnership)
        XCTAssertEqual(
            controller.deferredInitialLocalFirstFrameReplacement?.request,
            requestB
        )
        XCTAssertTrue(
            controller.deferredInitialLocalFirstFrameReplacement?
                .supersededAttempt === attemptA
        )
        XCTAssertFalse(
            controller.isCurrentInitialFramePresentationAttempt(
                attemptA,
                phase: .presenting
            )
        )

        var terminalResult: ChatViewportTransactionResult?
        controller.applyChatDatasource(
            [makeDatasource(primary: "p14-stale-a-row")],
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: {
                controller.isCurrentInitialFramePresentationAttempt(
                    attemptA,
                    phase: .presenting
                )
            },
            transactionCompletion: { terminalResult = $0 }
        )

        guard case .failed(.superseded, _) = terminalResult else {
            return XCTFail("superseded A must fail inside the atomic transaction")
        }
        XCTAssertEqual(controller.datasource.map(\.primary), priorPrimaries)
        XCTAssertEqual(
            controller.datasourceSnapshot.items.map(\.primary),
            priorSnapshotPrimaries
        )
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, priorOffset)
        XCTAssertEqual(controller.messagesCollectionView.contentInset, priorInsets)
        XCTAssertGreaterThan(
            controller.scrollResidentMetadata.generation,
            priorResidentGeneration,
            "rollback must monotonically invalidate callbacks captured from transient A"
        )
        XCTAssertEqual(controller.scrollResidentMetadata.residentRowCount, 1)
        XCTAssertNotNil(
            controller.scrollResidentMetadata.position(primary: priorRow.primary)
        )
        XCTAssertNil(
            controller.scrollResidentMetadata.position(
                primary: "p14-stale-a-row"
            ),
            "rollback metadata must not retain transient A"
        )
        XCTAssertEqual(
            controller.deferredInitialLocalFirstFrameReplacement?.request,
            requestB,
            "B must survive while stale A restores the pre-transaction frame"
        )
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
    }

    func testReentrantReplacementDuringRealDatasourcePublicationRollsBackAAndReplaysBExactlyOnce() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-reentrant-publication",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-3"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-5"
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        var didInjectReplacement = false
        var didCaptureDeferredB = false
        var rollbackObservationCount = 0
        var didRestorePreAttemptPagingState = false
        controller.initialFrameSupersededRollbackForTests = {
            expectedWindow,
            expectedBoundary,
            expectedBoundaryCache in
            rollbackObservationCount += 1
            didRestorePreAttemptPagingState =
                controller.residentDatasetWindow == expectedWindow &&
                controller.activeHistoryBoundaryPlaceholder == expectedBoundary &&
                controller.scrollBoundaryAvailabilityCache ==
                    expectedBoundaryCache
        }
        var tokenA: ChatAnchorTransactionToken?
        var bPositionedCount = 0
        controller.datasourceDidSetForTests = { rows in
            guard !didInjectReplacement,
                  rows.contains(where: { !$0.isFakeMessage }) else {
                return
            }
            didInjectReplacement = true
            tokenA = controller.activeAnchorExecutionState?.transactionToken
            controller.queueOpenMessageRequest(
                requestB,
                hooks: ChatAnchorExecutionHooks(
                    direction: .up,
                    animatedScroll: false,
                    onFailed: nil,
                    onPositioned: { bPositionedCount += 1 }
                )
            )
            didCaptureDeferredB =
                controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    requestB
        }
        var stackedCompletionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            stackedCompletionCount += 1
        }

        XCTAssertTrue(waitUntil {
            stackedCompletionCount == 1 &&
                controller.initialFirstContentApplyCount == 1 &&
                probe.commitCount == 1 &&
                controller.initialLocalFirstFramePhase ==
                    .committed(
                        ChatLocalFirstFrameDescriptorPolicy.descriptor(
                            request: requestB,
                            owner: controller.owner,
                            jid: controller.jid,
                            conversationType: controller.conversationType
                        )
                    )
        })
        let finalAttempt = try XCTUnwrap(
            controller.initialLocalFirstFramePresentationOwnership?.attempt
        )
        let finalToken = try XCTUnwrap(finalAttempt.anchorTransactionToken)

        XCTAssertTrue(didInjectReplacement)
        XCTAssertTrue(didCaptureDeferredB)
        XCTAssertEqual(rollbackObservationCount, 1)
        XCTAssertTrue(didRestorePreAttemptPagingState)
        XCTAssertEqual(probe.mappingCount, 2)
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertEqual(probe.commitDiagnostics?.targetKind, .anchor)
        XCTAssertEqual(probe.commitDiagnostics?.realDatasourceApplyCount, 1)
        XCTAssertEqual(probe.commitDiagnostics?.viewportDiagnostics.anchorError, 0)
        XCTAssertEqual(finalAttempt.descriptor.request, requestB)
        XCTAssertEqual(finalAttempt.presentationGeneration, 2)
        XCTAssertNotEqual(finalToken, tokenA)
        XCTAssertEqual(bPositionedCount, 1)
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertNotNil(
            controller.datasource.first {
                $0.archivedId == requestB.anchor.archivedId
            }
        )
    }

    func testPositioningStartedReplacementSeesExactAAttemptAndReplaysBOnce() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-positioning-reentrant",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-2"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-6"
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        var positioningHookCount = 0
        var didObserveExactAttemptBeforeReplacement = false
        var didLatchB = false
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onPositioningStarted: {
                positioningHookCount += 1
                didObserveExactAttemptBeforeReplacement =
                    controller.initialLocalFirstFramePresentationOwnership?
                        .attempt.descriptor.request == requestA &&
                    controller.initialLocalFirstFramePresentationOwnership?
                        .attempt.mappingToken ===
                            controller.initialLocalFirstFrameMappingToken
                controller.queueOpenMessageRequest(requestB, hooks: nil)
                didLatchB =
                    controller.deferredInitialLocalFirstFrameReplacement?
                        .request == requestB
            },
            onFailed: nil,
            onPositioned: nil
        )
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                controller.initialFirstContentApplyCount == 1 &&
                controller.initialLocalFirstFramePhase ==
                    .committed(
                        ChatLocalFirstFrameDescriptorPolicy.descriptor(
                            request: requestB,
                            owner: controller.owner,
                            jid: controller.jid,
                            conversationType: controller.conversationType
                        )
                    )
        })
        XCTAssertEqual(positioningHookCount, 1)
        XCTAssertTrue(didObserveExactAttemptBeforeReplacement)
        XCTAssertTrue(didLatchB)
        XCTAssertEqual(probe.mappingCount, 2)
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertEqual(
            controller.initialLocalFirstFramePresentationOwnership?
                .attempt.descriptor.request,
            requestB
        )
    }

    func testPresentingExactADuplicateCannotReplaceAlreadyDeferredB() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-presenting-a-b-exact-a",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-2",
            highlight: true,
            markReadOnVisible: true
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-6"
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        var didLatchB = false
        var didKeepExactDeferredBObject = false
        var duplicateAStartedCount = 0
        var duplicateAFailedCount = 0
        var duplicateAPositionedCount = 0
        var bPositionedCount = 0
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onPositioningStarted: {
                controller.queueOpenMessageRequest(
                    requestB,
                    hooks: ChatAnchorExecutionHooks(
                        direction: .down,
                        animatedScroll: false,
                        onFailed: nil,
                        onPositioned: { bPositionedCount += 1 }
                    )
                )
                let deferredB =
                    controller.deferredInitialLocalFirstFrameReplacement
                didLatchB = deferredB?.request == requestB
                controller.queueOpenMessageRequest(
                    requestA,
                    hooks: ChatAnchorExecutionHooks(
                        direction: .up,
                        animatedScroll: false,
                        onPositioningStarted: {
                            duplicateAStartedCount += 1
                        },
                        onFailed: { duplicateAFailedCount += 1 },
                        onPositioned: { duplicateAPositionedCount += 1 }
                    )
                )
                if let deferredB {
                    didKeepExactDeferredBObject =
                        controller
                            .deferredInitialLocalFirstFrameReplacement ===
                                deferredB &&
                        deferredB.request == requestB
                }
            },
            onFailed: nil,
            onPositioned: nil
        )
        var aAdmissionCount = 0
        var bAdmissionCount = 0
        controller.performanceOpenMessageRequestAdmissionObserver = {
            request,
            _ in
            if request == requestA {
                aAdmissionCount += 1
            } else if request == requestB {
                bAdmissionCount += 1
            }
        }
        var aReadSchedulingCount = 0
        var bReadSchedulingCount = 0
        controller.mentionReadOnVisibleSchedulingObserverForTests = {
            request in
            if request == requestA {
                aReadSchedulingCount += 1
            } else if request == requestB {
                bReadSchedulingCount += 1
            }
        }
        let highlightCell = MessageContentCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 80)
        )
        controller.transientMessageHighlightCellProviderForTests = { _ in
            highlightCell
        }
        controller.defersTransientMessageHighlightAnimationForTests = true
        var genericExecutionCount = 0
        controller.pendingOpenMessageGenericExecutionInterceptorForTests = {
            genericExecutionCount += 1
            return false
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                controller.initialLocalFirstFramePhase ==
                    .committed(
                        ChatLocalFirstFrameDescriptorPolicy.descriptor(
                            request: requestB,
                            owner: controller.owner,
                            jid: controller.jid,
                            conversationType: controller.conversationType
                        )
                    )
        })
        XCTAssertTrue(didLatchB)
        XCTAssertTrue(didKeepExactDeferredBObject)
        XCTAssertEqual(probe.mappingCount, 2)
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertEqual(aAdmissionCount, 0)
        XCTAssertEqual(bAdmissionCount, 1)
        XCTAssertEqual(genericExecutionCount, 0)
        XCTAssertEqual(duplicateAStartedCount, 0)
        XCTAssertEqual(duplicateAFailedCount, 0)
        XCTAssertEqual(duplicateAPositionedCount, 0)
        XCTAssertEqual(bPositionedCount, 1)
        XCTAssertEqual(aReadSchedulingCount, 0)
        XCTAssertEqual(bReadSchedulingCount, 1)
        XCTAssertNil(
            controller.transientMessageHighlightAnimationCompletionForTests,
            "exact A duplicate must not install A's highlight"
        )
        XCTAssertEqual(
            controller.initialLocalFirstFramePresentationOwnership?
                .attempt.descriptor.request,
            requestB
        )
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
    }

    func testRollbackArchiveSpinnerRestoreSurvivesQueuedHideOnNextMainTurn() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-rollback-spinner",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-1"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-7"
        )
        controller.pendingOpenMessageRequest = requestA
        var snapshotCaptureCount = 0
        controller.initialFrameRollbackSnapshotWillCaptureForTests = {
            snapshotCaptureCount += 1
            guard snapshotCaptureCount == 1 else {
                return
            }
            controller.messageLoadingActivityIndicator.isHidden = false
            controller.showLoadingIndicator.accept(true)
        }
        var diagnosticsCount = 0
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            _ in
            diagnosticsCount += 1
            guard diagnosticsCount == 1 else {
                return
            }
            controller.queueOpenMessageRequest(requestB, hooks: nil)
        }
        var didRestoreSpinnerSynchronously = false
        var didObservePostRollbackMainTurn = false
        var spinnerRemainedVisibleAfterMainTurn = false
        var loadingIndicatorRemainedVisibleAfterMainTurn = false
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            didRestoreSpinnerSynchronously =
                !controller.messageLoadingActivityIndicator.isHidden &&
                controller.showLoadingIndicator.value
            DispatchQueue.main.async {
                spinnerRemainedVisibleAfterMainTurn =
                    !controller.messageLoadingActivityIndicator.isHidden
                loadingIndicatorRemainedVisibleAfterMainTurn =
                    controller.showLoadingIndicator.value
                didObservePostRollbackMainTurn = true
            }
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                didObservePostRollbackMainTurn &&
                diagnosticsCount == 2
        })
        XCTAssertEqual(snapshotCaptureCount, 2)
        XCTAssertTrue(didRestoreSpinnerSynchronously)
        XCTAssertTrue(
            spinnerRemainedVisibleAfterMainTurn,
            "A's queued hide must not overwrite the exact pre-A archive spinner snapshot"
        )
        XCTAssertTrue(loadingIndicatorRemainedVisibleAfterMainTurn)
        XCTAssertEqual(
            controller.initialLocalFirstFramePresentationOwnership?
                .attempt.descriptor.request,
            requestB
        )
    }

    func testCommitDiagnosticsReplacementRestoresSkeletonBeforeBMappingAndSuppressesATerminalEffects() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-terminal-reentrant",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-1"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-7"
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        var diagnosticCallbackCount = 0
        var didLatchBAtATerminal = false
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            diagnosticCallbackCount += 1
            guard diagnosticCallbackCount == 1 else {
                probe.recordCommit($0)
                return
            }
            controller.queueOpenMessageRequest(requestB, hooks: nil)
            didLatchBAtATerminal =
                controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    requestB
        }
        var rollbackCount = 0
        var didRestoreExactBlockingFrame = false
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            rollbackCount += 1
            didRestoreExactBlockingFrame =
                controller.datasource.count == 30 &&
                controller.datasource.allSatisfy(\.isFakeMessage) &&
                controller.hasCommittedBootstrapSkeletonRows &&
                !controller.hasCommittedRealContentInCurrentLifecycle &&
                controller.initialFirstContentApplyCount == 0
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                diagnosticCallbackCount == 2 &&
                controller.initialFirstContentApplyCount == 1 &&
                controller.initialLocalFirstFramePhase ==
                    .committed(
                        ChatLocalFirstFrameDescriptorPolicy.descriptor(
                            request: requestB,
                            owner: controller.owner,
                            jid: controller.jid,
                            conversationType: controller.conversationType
                        )
                    )
        })
        XCTAssertTrue(didLatchBAtATerminal)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertTrue(didRestoreExactBlockingFrame)
        XCTAssertEqual(probe.mappingCount, 2)
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNotNil(
            controller.datasource.first {
                $0.archivedId == requestB.anchor.archivedId
            }
        )
    }

    func testTerminalRollbackCoalescesAThenBThenCAndOnlyMapsLatestC() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-terminal-a-b-c",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-1"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-4"
        )
        let requestC = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-7"
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        var diagnosticsCount = 0
        var shouldInjectCOnRollback = false
        var didLatchB = false
        var didReplaceBWithC = false
        var bPositionedCount = 0
        var cPositionedCount = 0
        var expectedRollbackSnapshot:
            ChatInitialFramePresentationRollbackSnapshot?
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            diagnosticsCount += 1
            guard diagnosticsCount == 1 else {
                probe.recordCommit($0)
                return
            }
            expectedRollbackSnapshot =
                controller.initialLocalFirstFramePresentationOwnership?
                    .attempt.rollbackSnapshot
            shouldInjectCOnRollback = true
            controller.queueOpenMessageRequest(
                requestB,
                hooks: ChatAnchorExecutionHooks(
                    direction: .up,
                    animatedScroll: false,
                    onFailed: nil,
                    onPositioned: { bPositionedCount += 1 }
                )
            )
            didLatchB =
                controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    requestB
        }
        controller.datasourceDidSetForTests = { rows in
            guard shouldInjectCOnRollback,
                  rows.count == ChatSkeletonTemplate.descriptors.count,
                  rows.allSatisfy(\.isFakeMessage),
                  controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    requestB else {
                return
            }
            shouldInjectCOnRollback = false
            controller.queueOpenMessageRequest(
                requestC,
                hooks: ChatAnchorExecutionHooks(
                    direction: .down,
                    animatedScroll: false,
                    onFailed: nil,
                    onPositioned: { cPositionedCount += 1 }
                )
            )
            didReplaceBWithC =
                controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    requestC
        }
        var rollbackCount = 0
        var rollbackInstalledSnapshotLast = false
        var rollbackObservation: ChatInitialFrameRollbackObservation?
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            rollbackCount += 1
            guard let expectedRollbackSnapshot else {
                return
            }
            let actualLayoutSnapshot =
                (controller.messagesCollectionView.collectionViewLayout as?
                    MessagesCollectionViewFlowLayout)?
                    .cache.reuseSnapshot() ?? .empty
            let layoutMatches =
                actualLayoutSnapshot.count ==
                    expectedRollbackSnapshot.layoutSnapshot.count &&
                expectedRollbackSnapshot.datasource.allSatisfy { item in
                    actualLayoutSnapshot.key(forPrimary: item.primary) ==
                        expectedRollbackSnapshot.layoutSnapshot.key(
                            forPrimary: item.primary
                        ) &&
                    actualLayoutSnapshot.layout(forPrimary: item.primary) ==
                        expectedRollbackSnapshot.layoutSnapshot.layout(
                            forPrimary: item.primary
                        )
                }
            rollbackObservation = ChatInitialFrameRollbackObservation(
                contentOffset:
                    controller.messagesCollectionView.contentOffset,
                contentInsets:
                    controller.messagesCollectionView.contentInset,
                verticalScrollIndicatorInsets:
                    controller.messagesCollectionView
                        .verticalScrollIndicatorInsets,
                horizontalScrollIndicatorInsets:
                    controller.messagesCollectionView
                        .horizontalScrollIndicatorInsets,
                layoutMatches: layoutMatches,
                showsSkeleton: controller.showSkeletonObserver.value,
                canLoadDatasource: controller.canLoadDatasource,
                loadDatasourceRelayValue:
                    controller.loadDatasourceObserver.value,
                showsInitialMessage:
                    controller.shouldShowInitialMessage.value,
                bootstrapLoadingState:
                    controller.appliedBootstrapLoadingState,
                showsBootstrapFailure:
                    !controller.bootstrapFailureView.isHidden,
                allowsBootstrapFailureFallback:
                    controller.allowsBootstrapFailureFallback,
                preservesBootstrapFailureOverlayUntilRetryCommit:
                    controller
                        .preservesBootstrapFailureOverlayUntilRetryCommit,
                hasCommittedRealContent:
                    controller.hasCommittedRealContentInCurrentLifecycle,
                hasCommittedSkeletonPresentation:
                    controller
                        .hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle,
                hasCommittedTimelinePresentation:
                    controller
                        .hasCommittedTimelinePresentationInCurrentLifecycle,
                initialContentApplyCount:
                    controller.initialFirstContentApplyCount,
                lastAtomicRevealPlan:
                    controller.lastBootstrapAtomicRevealPlan,
                hasRenderedStableInitialHistory:
                    controller.hasRenderedStableInitialHistory,
                initialHistoryAppearancePending:
                    controller.initialHistoryAppearancePending,
                hasCompletedInitialHistoryViewAppearance:
                    controller.hasCompletedInitialHistoryViewAppearance,
                showsLoadingIndicator:
                    controller.showLoadingIndicator.value,
                showsArchiveLoadingIndicator:
                    !controller.messageLoadingActivityIndicator.isHidden,
                isCollectionUserInteractionEnabled:
                    controller.messagesCollectionView.isUserInteractionEnabled,
                isCollectionScrollEnabled:
                    controller.messagesCollectionView.isScrollEnabled,
                isTimelineInteractionLoading:
                    controller.timelineInteractionState.isLoading,
                isTimelineInteractionLocked:
                    controller.timelineInteractionState.locked
            )
            rollbackInstalledSnapshotLast =
                controller.datasource.count ==
                    ChatSkeletonTemplate.descriptors.count &&
                controller.datasource.allSatisfy(\.isFakeMessage) &&
                controller.activeAnchorExecutionState == nil &&
                controller.initialFirstContentApplyCount == 0
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                diagnosticsCount == 2 &&
                controller.initialLocalFirstFramePhase ==
                    .committed(
                        ChatLocalFirstFrameDescriptorPolicy.descriptor(
                            request: requestC,
                            owner: controller.owner,
                            jid: controller.jid,
                            conversationType: controller.conversationType
                        )
                    )
        })
        XCTAssertTrue(didLatchB)
        XCTAssertTrue(didReplaceBWithC)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertTrue(rollbackInstalledSnapshotLast)
        let rollback = try XCTUnwrap(rollbackObservation)
        let expectedRollback = try XCTUnwrap(expectedRollbackSnapshot)
        XCTAssertEqual(rollback.contentOffset, expectedRollback.contentOffset)
        XCTAssertEqual(rollback.contentInsets, expectedRollback.contentInsets)
        XCTAssertEqual(
            rollback.verticalScrollIndicatorInsets,
            expectedRollback.verticalScrollIndicatorInsets
        )
        XCTAssertEqual(
            rollback.horizontalScrollIndicatorInsets,
            expectedRollback.horizontalScrollIndicatorInsets
        )
        XCTAssertTrue(rollback.layoutMatches)
        XCTAssertEqual(rollback.showsSkeleton, expectedRollback.showsSkeleton)
        XCTAssertEqual(
            rollback.canLoadDatasource,
            expectedRollback.canLoadDatasource
        )
        XCTAssertEqual(
            rollback.loadDatasourceRelayValue,
            expectedRollback.canLoadDatasource
        )
        XCTAssertEqual(
            rollback.showsInitialMessage,
            expectedRollback.showsInitialMessage
        )
        XCTAssertEqual(
            rollback.bootstrapLoadingState,
            expectedRollback.bootstrapLoadingState
        )
        XCTAssertEqual(
            rollback.showsBootstrapFailure,
            expectedRollback.showsBootstrapFailure
        )
        XCTAssertEqual(
            rollback.allowsBootstrapFailureFallback,
            expectedRollback.allowsBootstrapFailureFallback
        )
        XCTAssertEqual(
            rollback.preservesBootstrapFailureOverlayUntilRetryCommit,
            expectedRollback
                .preservesBootstrapFailureOverlayUntilRetryCommit
        )
        XCTAssertEqual(
            rollback.hasCommittedRealContent,
            expectedRollback.hasCommittedRealContent
        )
        XCTAssertEqual(
            rollback.hasCommittedSkeletonPresentation,
            expectedRollback.hasCommittedSkeletonPresentation
        )
        XCTAssertEqual(
            rollback.hasCommittedTimelinePresentation,
            expectedRollback.hasCommittedTimelinePresentation
        )
        XCTAssertEqual(
            rollback.initialContentApplyCount,
            expectedRollback.initialContentApplyCount
        )
        XCTAssertEqual(
            rollback.lastAtomicRevealPlan,
            expectedRollback.lastAtomicRevealPlan
        )
        XCTAssertEqual(
            rollback.hasRenderedStableInitialHistory,
            expectedRollback.hasRenderedStableInitialHistory
        )
        XCTAssertEqual(
            rollback.initialHistoryAppearancePending,
            expectedRollback.initialHistoryAppearancePending
        )
        XCTAssertEqual(
            rollback.hasCompletedInitialHistoryViewAppearance,
            expectedRollback.hasCompletedInitialHistoryViewAppearance
        )
        XCTAssertEqual(
            rollback.showsLoadingIndicator,
            expectedRollback.showsLoadingIndicator
        )
        XCTAssertEqual(
            rollback.showsArchiveLoadingIndicator,
            expectedRollback.showsArchiveLoadingIndicator
        )
        XCTAssertEqual(
            rollback.isCollectionUserInteractionEnabled,
            expectedRollback.isCollectionUserInteractionEnabled
        )
        XCTAssertEqual(
            rollback.isCollectionScrollEnabled,
            expectedRollback.isCollectionScrollEnabled
        )
        XCTAssertEqual(
            rollback.isTimelineInteractionLoading,
            expectedRollback.isTimelineInteractionLoading
        )
        XCTAssertEqual(
            rollback.isTimelineInteractionLocked,
            expectedRollback.isTimelineInteractionLocked
        )
        XCTAssertEqual(
            probe.mappingCount,
            2,
            "only A and latest C may map; intermediate B is never admitted"
        )
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertEqual(bPositionedCount, 0)
        XCTAssertEqual(cPositionedCount, 1)
        XCTAssertEqual(
            controller.initialLocalFirstFramePresentationOwnership?
                .attempt.descriptor.request,
            requestC
        )
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
    }

    func testPostResolveSuppressedIntentInvalidatesQueuedDeferredReplayAndBHasZeroEffects() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-post-resolve-suppressed-c",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-1"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-4",
            highlight: true,
            markReadOnVisible: true
        )
        let requestC = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-6",
            source: .voicePlayer
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        var diagnosticsCount = 0
        var didLatchB = false
        var bPositionedCount = 0
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            diagnosticsCount += 1
            probe.recordCommit($0)
            guard diagnosticsCount == 1 else {
                return
            }
            controller.queueOpenMessageRequest(
                requestB,
                hooks: ChatAnchorExecutionHooks(
                    direction: .up,
                    animatedScroll: false,
                    onFailed: nil,
                    onPositioned: { bPositionedCount += 1 }
                )
            )
            didLatchB =
                controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    requestB
        }
        var didObserveResolvedPreReplayWindow = false
        var didCInvalidateDeferredB = false
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            DispatchQueue.main.async {
                didObserveResolvedPreReplayWindow =
                    controller.initialLocalFirstFrameTerminalizingAttempt == nil &&
                    controller.initialLocalFirstFramePresentationOwnership == nil &&
                    controller.initialLocalFirstFramePhase == .idle &&
                    controller.deferredInitialLocalFirstFrameReplacement?.request ==
                        requestB
                controller.queueOpenMessageRequest(requestC, hooks: nil)
                didCInvalidateDeferredB =
                    controller.deferredInitialLocalFirstFrameReplacement == nil
            }
        }
        var bAdmissionCount = 0
        controller.performanceOpenMessageRequestAdmissionObserver = {
            request,
            _ in
            if request == requestB {
                bAdmissionCount += 1
            }
        }
        var genericExecutionCount = 0
        controller.pendingOpenMessageGenericExecutionInterceptorForTests = {
            genericExecutionCount += 1
            return false
        }
        let highlightCell = MessageContentCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 80)
        )
        controller.transientMessageHighlightCellProviderForTests = { _ in
            highlightCell
        }
        controller.defersTransientMessageHighlightAnimationForTests = true
        var scheduledReadCount = 0
        controller.visibleMentionReadScheduledForTests = {
            scheduledReadCount += $0
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                didCInvalidateDeferredB &&
                controller.datasource.contains { !$0.isFakeMessage } &&
                !controller.pendingForceLatestOpen &&
                !controller.showSkeletonObserver.value
        })
        XCTAssertTrue(didLatchB)
        XCTAssertTrue(didObserveResolvedPreReplayWindow)
        XCTAssertTrue(didCInvalidateDeferredB)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(diagnosticsCount, 1)
        XCTAssertEqual(bAdmissionCount, 0)
        XCTAssertEqual(genericExecutionCount, 0)
        XCTAssertEqual(bPositionedCount, 0)
        XCTAssertEqual(scheduledReadCount, 0)
        XCTAssertNil(
            controller.transientMessageHighlightAnimationCompletionForTests,
            "B must never reach production highlight installation"
        )
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(controller.initialLocalFirstFramePhase, .idle)
        XCTAssertEqual(controller.datasource.last?.archivedId, "archive-7")
    }

    func testTerminalExactADuplicateCannotDisplaceLatchedBOrRunEffects() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-terminal-exact-a-duplicate",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-1",
            highlight: true,
            markReadOnVisible: true
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-6"
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        var diagnosticsCount = 0
        var didLatchB = false
        var didKeepExactDeferredBObject = false
        var duplicateAStartedCount = 0
        var duplicateAFailedCount = 0
        var duplicateAPositionedCount = 0
        var bPositionedCount = 0
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            diagnosticsCount += 1
            guard diagnosticsCount == 1 else {
                probe.recordCommit($0)
                return
            }
            controller.queueOpenMessageRequest(
                requestB,
                hooks: ChatAnchorExecutionHooks(
                    direction: .down,
                    animatedScroll: false,
                    onFailed: nil,
                    onPositioned: { bPositionedCount += 1 }
                )
            )
            let deferredB =
                controller.deferredInitialLocalFirstFrameReplacement
            didLatchB = deferredB?.request == requestB
            controller.queueOpenMessageRequest(
                requestA,
                hooks: ChatAnchorExecutionHooks(
                    direction: .up,
                    animatedScroll: false,
                    onPositioningStarted: {
                        duplicateAStartedCount += 1
                    },
                    onFailed: { duplicateAFailedCount += 1 },
                    onPositioned: { duplicateAPositionedCount += 1 }
                )
            )
            if let deferredB {
                didKeepExactDeferredBObject =
                    controller.deferredInitialLocalFirstFrameReplacement ===
                        deferredB &&
                    deferredB.request == requestB
            }
        }
        var admissionA = 0
        var admissionB = 0
        controller.performanceOpenMessageRequestAdmissionObserver = {
            request,
            _ in
            if request == requestA {
                admissionA += 1
            } else if request == requestB {
                admissionB += 1
            }
        }
        var genericExecutionCount = 0
        controller.pendingOpenMessageGenericExecutionInterceptorForTests = {
            genericExecutionCount += 1
            return false
        }
        let highlightCell = MessageContentCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 80)
        )
        controller.transientMessageHighlightCellProviderForTests = { _ in
            highlightCell
        }
        controller.defersTransientMessageHighlightAnimationForTests = true
        var scheduledReadCount = 0
        controller.visibleMentionReadScheduledForTests = {
            scheduledReadCount += $0
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                diagnosticsCount == 2 &&
                controller.initialLocalFirstFramePhase ==
                    .committed(
                        ChatLocalFirstFrameDescriptorPolicy.descriptor(
                            request: requestB,
                            owner: controller.owner,
                            jid: controller.jid,
                            conversationType: controller.conversationType
                        )
                    )
        })
        XCTAssertTrue(didLatchB)
        XCTAssertTrue(didKeepExactDeferredBObject)
        XCTAssertEqual(probe.mappingCount, 2)
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertEqual(admissionA, 0)
        XCTAssertEqual(admissionB, 1)
        XCTAssertEqual(genericExecutionCount, 0)
        XCTAssertEqual(duplicateAStartedCount, 0)
        XCTAssertEqual(duplicateAFailedCount, 0)
        XCTAssertEqual(duplicateAPositionedCount, 0)
        XCTAssertEqual(bPositionedCount, 1)
        XCTAssertEqual(scheduledReadCount, 0)
        XCTAssertNil(
            controller.transientMessageHighlightAnimationCompletionForTests,
            "aborted A must not install its highlight"
        )
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
    }

    func testSuppressedForceLatestReplacementDuringPresentingCancelsAThenFinishesLoadedLatest() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-suppressed-presenting",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-2"
        )
        let forceLatestRequest = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-4",
            source: .voicePlayer
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        var positioningStartedCount = 0
        var aPositionedCount = 0
        var didLatchSuppressedReplacement = false
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onPositioningStarted: {
                positioningStartedCount += 1
                controller.queueOpenMessageRequest(
                    forceLatestRequest,
                    hooks: nil
                )
                didLatchSuppressedReplacement =
                    controller.deferredInitialLocalFirstFrameReplacement?
                        .request == forceLatestRequest
            },
            onFailed: nil,
            onPositioned: { aPositionedCount += 1 }
        )
        var rollbackCount = 0
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            rollbackCount += 1
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                controller.datasource.contains { !$0.isFakeMessage } &&
                !controller.pendingForceLatestOpen &&
                !controller.showSkeletonObserver.value
        })
        XCTAssertTrue(didLatchSuppressedReplacement)
        XCTAssertEqual(positioningStartedCount, 1)
        XCTAssertEqual(aPositionedCount, 0)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(probe.commitCount, 0)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        XCTAssertEqual(controller.initialLocalFirstFramePhase, .idle)
        XCTAssertNil(controller.initialLocalFirstFramePresentationOwnership)
        XCTAssertNil(controller.initialLocalFirstFrameLatestEffectToken)
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(controller.datasource.last?.archivedId, "archive-7")
    }

    func testSuppressedForceLatestReplacementAwaitingCAReceiptRollsBackAThenFinishesLoadedLatest() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-suppressed-awaiting-ca",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-1"
        )
        let forceLatestRequest = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-5",
            source: .voicePlayer
        )
        controller.pendingOpenMessageRequest = requestA
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        var didLatchSuppressedReplacement = false
        var aPositionedCount = 0
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onFailed: nil,
            onPositioned: { aPositionedCount += 1 }
        )
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
            controller.queueOpenMessageRequest(forceLatestRequest, hooks: nil)
            didLatchSuppressedReplacement =
                controller.deferredInitialLocalFirstFrameReplacement?.request ==
                    forceLatestRequest
        }
        var rollbackCount = 0
        var didRestoreBlockingFrame = false
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            rollbackCount += 1
            didRestoreBlockingFrame =
                controller.datasource.count ==
                    ChatSkeletonTemplate.descriptors.count &&
                controller.datasource.allSatisfy(\.isFakeMessage) &&
                controller.initialFirstContentApplyCount == 0
        }
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                controller.datasource.contains { !$0.isFakeMessage } &&
                !controller.pendingForceLatestOpen &&
                !controller.showSkeletonObserver.value
        })
        XCTAssertTrue(didLatchSuppressedReplacement)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertTrue(didRestoreBlockingFrame)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(probe.commitCount, 1)
        XCTAssertEqual(aPositionedCount, 0)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        XCTAssertEqual(controller.initialLocalFirstFramePhase, .idle)
        XCTAssertNil(controller.initialLocalFirstFramePresentationOwnership)
        XCTAssertNil(controller.initialLocalFirstFrameLatestEffectToken)
        XCTAssertNil(controller.deferredInitialLocalFirstFrameReplacement)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(controller.datasource.last?.archivedId, "archive-7")
    }

    func testReplacementAfterCoreAnimationReceiptUsesLoadedNavigationWithoutSkeletonRollback() throws {
        let controller = try makeColdReadyController(
            suffix: "p14-post-ca-replacement",
            applicationState: .active
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-2"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "archive-6"
        )
        controller.pendingOpenMessageRequest = requestA
        var completionCount = 0
        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }
        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                controller.initialLocalFirstFrameCoreAnimationReceiptGeneration !=
                    nil
        })
        let committedPrimaries = controller.datasource.map(\.primary)
        let committedMappingGeneration = controller.datasetMappingGeneration
        let committedInitialApplyCount = controller.initialFirstContentApplyCount
        var rollbackCount = 0
        controller.initialFrameSupersededRollbackForTests = { _, _, _ in
            rollbackCount += 1
        }
        var remapCount = 0
        controller.initialFirstFrameMappingBarrierForTests = {
            remapCount += 1
        }
        var positioningStartedCount = 0
        var positionedCount = 0
        controller.scrollFrameOperationCounter.setEnabled(true)
        controller.scrollFrameOperationCounter.reset()

        controller.queueOpenMessageRequest(
            requestB,
            hooks: ChatAnchorExecutionHooks(
                direction: .down,
                animatedScroll: false,
                onPositioningStarted: { positioningStartedCount += 1 },
                onFailed: nil,
                onPositioned: { positionedCount += 1 }
            )
        )

        XCTAssertTrue(waitUntil { positionedCount == 1 })
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(remapCount, 0)
        XCTAssertEqual(
            controller.datasetMappingGeneration,
            committedMappingGeneration
        )
        XCTAssertEqual(
            controller.initialFirstContentApplyCount,
            committedInitialApplyCount
        )
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            0
        )
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.reloads],
            0
        )
        XCTAssertEqual(positioningStartedCount, 1)
        XCTAssertEqual(positionedCount, 1)
        XCTAssertEqual(controller.datasource.map(\.primary), committedPrimaries)
        XCTAssertTrue(controller.datasource.contains { !$0.isFakeMessage })
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.initialLocalFirstFramePhase, .idle)
        XCTAssertNil(controller.initialLocalFirstFramePresentationOwnership)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
    }

    func testLifecycleCancelAndTerminalTeardownClearEveryInitialFrameOwner() throws {
        func installOwnedAttempt(
            on controller: ChatViewController,
            generation: UInt64
        ) throws -> (
            attempt: ChatInitialFramePresentationAttempt,
            admission: ChatPostBootstrapInitialFrameAdmission
        ) {
            controller.loadViewIfNeeded()
            controller.configureDataset()
            let requestA = makeTraceAnchorRequest(
                controller: controller,
                archivedId: "p14-lifecycle-a-\(generation)"
            )
            let requestB = makeTraceAnchorRequest(
                controller: controller,
                archivedId: "p14-lifecycle-b-\(generation)"
            )
            let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
                request: requestA,
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType
            )
            let session = try XCTUnwrap(controller.timelineSession)
            let attempt = ChatInitialFramePresentationAttempt(
                descriptor: descriptor,
                mappingToken: nil,
                mappingGeneration: controller.datasetMappingGeneration,
                session: session,
                timelineGeneration: session.snapshot.generation,
                anchorTransactionToken: ChatAnchorTransactionToken(
                    rawValue: "p14-lifecycle-token-\(generation)"
                ),
                presentationGeneration: generation,
                performanceTraceContext: nil,
                ownsPerformancePresentingInterval: false
            )
            controller.initialLocalFirstFramePresentationGeneration = generation
            controller.initialLocalFirstFramePhase = .committed(descriptor)
            controller.initialLocalFirstFramePresentationOwnership =
                ChatInitialFramePresentationOwnership(
                    attempt: attempt,
                    phase: .committed
                )
            controller.initialLocalFirstFrameLatestEffectToken =
                attempt.effectToken
            controller.initialLocalFirstFrameCoreAnimationReceiptGeneration =
                generation
            controller.initialLocalFirstFrameTerminalizingAttempt = attempt
            controller.deferredInitialLocalFirstFrameReplacement =
                ChatDeferredInitialFrameReplacement(
                    supersededAttempt: attempt,
                    request: requestB,
                    hooks: nil
                )
            let mappingToken = ChatDatasetMappingCancellationToken(
                generation: controller.datasetMappingGeneration,
                cancellationCheckInterval: 1
            )
            controller.initialLocalFirstFrameMappingToken = mappingToken
            let admission = ChatPostBootstrapInitialFrameAdmission(
                identity: ChatPostBootstrapInitialFrameAdmissionIdentity(
                    conversationKey: controller.chatTimelineConversationKey,
                    bootstrapQueryId: controller.initialBootstrapQueryId,
                    targetFingerprint:
                        controller.initialBootstrapTargetFingerprint,
                    descriptor: descriptor,
                    datasetMappingGeneration:
                        controller.datasetMappingGeneration,
                    timelineGeneration: session.snapshot.generation
                ),
                mappingToken: mappingToken,
                session: session
            )
            controller.activePostBootstrapInitialFrameAdmission = admission
            controller.readVisiblePresentationCoordinator
                .recordPresentationReceipt()
            controller.readVisiblePresentationCoordinator.enqueue([
                ChatPendingMentionReadCandidate(
                    notificationPrimary:
                        "p14-lifecycle-notification-\(generation)",
                    messagePrimary:
                        "p14-lifecycle-message-\(generation)",
                    initialFrameEffectToken: attempt.effectToken
                )
            ])
            return (attempt, admission)
        }

        func assertOwnersCleared(
            _ controller: ChatViewController,
            attempt: ChatInitialFramePresentationAttempt,
            admission: ChatPostBootstrapInitialFrameAdmission,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                controller.initialLocalFirstFramePhase,
                .idle,
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.initialLocalFirstFramePresentationOwnership,
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.initialLocalFirstFrameLatestEffectToken,
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.initialLocalFirstFrameCoreAnimationReceiptGeneration,
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.initialLocalFirstFrameTerminalizingAttempt,
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.deferredInitialLocalFirstFrameReplacement,
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.activePostBootstrapInitialFrameAdmission,
                file: file,
                line: line
            )
            XCTAssertFalse(
                admission.authorizesCommit,
                file: file,
                line: line
            )
            XCTAssertTrue(
                admission.mappingToken.isCancelled,
                file: file,
                line: line
            )
            XCTAssertTrue(
                controller.readVisiblePresentationCoordinator
                    .pendingMessagePrimaries.isEmpty,
                file: file,
                line: line
            )
            XCTAssertFalse(
                controller.isLatestInitialFrameEffectToken(attempt.effectToken),
                file: file,
                line: line
            )
        }

        let cancelledController = makeController()
        let cancelledOwnership = try installOwnedAttempt(
            on: cancelledController,
            generation: 91
        )
        cancelledController.cancelStackedNavigationPresentationPreparation()
        assertOwnersCleared(
            cancelledController,
            attempt: cancelledOwnership.attempt,
            admission: cancelledOwnership.admission
        )
        cancelledController.performTerminalChatResourceTeardownForTesting()

        let tornDownController = makeController()
        let tornDownOwnership = try installOwnedAttempt(
            on: tornDownController,
            generation: 92
        )
        tornDownController.performTerminalChatResourceTeardownForTesting()
        assertOwnersCleared(
            tornDownController,
            attempt: tornDownOwnership.attempt,
            admission: tornDownOwnership.admission
        )
    }

    func testProductionTransientHighlightStaleCompletionRemovesCapturedZeroAlphaA() throws {
        let harness = try makeTransientHighlightHarness(
            suffix: "stale-a-only"
        )
        defer {
            harness.controller.performTerminalChatResourceTeardownForTesting()
        }

        harness.controller.applyTransientMessageHighlight(
            primary: harness.primary,
            initialFrameEffectToken: harness.tokenA
        )
        let completionA = try XCTUnwrap(
            harness.controller
                .transientMessageHighlightAnimationCompletionForTests
        )
        let overlayA = try XCTUnwrap(harness.cell.contentView.subviews.last)
        XCTAssertEqual(
            ChatAnchorHighlightOverlay.representedPrimary(in: harness.cell),
            harness.primary
        )
        XCTAssertEqual(overlayA.alpha, 0)

        harness.controller.initialLocalFirstFramePresentationGeneration =
            harness.tokenB.presentationGeneration
        harness.controller.initialLocalFirstFrameLatestEffectToken =
            harness.tokenB
        harness.controller.initialLocalFirstFramePhase =
            .committed(harness.tokenB.descriptor)
        completionA(true)

        XCTAssertNil(overlayA.superview)
        XCTAssertNil(
            ChatAnchorHighlightOverlay.representedPrimary(in: harness.cell),
            "stale token revokes effects, not cleanup ownership of captured A"
        )
    }

    func testProductionTransientHighlightStaleACompletionCannotRemoveFreshBOverlay() throws {
        let harness = try makeTransientHighlightHarness(
            suffix: "stale-a-fresh-b"
        )
        defer {
            harness.controller.performTerminalChatResourceTeardownForTesting()
        }

        harness.controller.applyTransientMessageHighlight(
            primary: harness.primary,
            initialFrameEffectToken: harness.tokenA
        )
        let completionA = try XCTUnwrap(
            harness.controller
                .transientMessageHighlightAnimationCompletionForTests
        )
        let overlayA = try XCTUnwrap(harness.cell.contentView.subviews.last)
        harness.controller.initialLocalFirstFramePresentationGeneration =
            harness.tokenB.presentationGeneration
        harness.controller.initialLocalFirstFrameLatestEffectToken =
            harness.tokenB
        harness.controller.initialLocalFirstFramePhase =
            .committed(harness.tokenB.descriptor)
        harness.controller.applyTransientMessageHighlight(
            primary: harness.primary,
            initialFrameEffectToken: harness.tokenB
        )
        let completionB = try XCTUnwrap(
            harness.controller
                .transientMessageHighlightAnimationCompletionForTests
        )
        let overlayB = try XCTUnwrap(harness.cell.contentView.subviews.last)
        XCTAssertFalse(overlayA === overlayB)
        XCTAssertNil(overlayA.superview)
        XCTAssertEqual(overlayB.alpha, 0)

        completionA(true)

        XCTAssertTrue(overlayB.superview === harness.cell.contentView)
        XCTAssertEqual(
            ChatAnchorHighlightOverlay.representedPrimary(in: harness.cell),
            harness.primary
        )
        completionB(true)
        XCTAssertNil(overlayB.superview)
    }

    func testSameRequestFreshPresentationGenerationRejectsLateOldTokenTerminal() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-same-request"
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let session = try XCTUnwrap(controller.timelineSession)
        let tokenA = ChatAnchorTransactionToken(rawValue: "p14-same-token-a")
        let tokenB = ChatAnchorTransactionToken(rawValue: "p14-same-token-b")
        let mappingTokenA = ChatDatasetMappingCancellationToken(
            generation: controller.datasetMappingGeneration,
            cancellationCheckInterval: 1
        )
        let attemptA = ChatInitialFramePresentationAttempt(
            descriptor: descriptor,
            mappingToken: mappingTokenA,
            mappingGeneration: controller.datasetMappingGeneration,
            session: session,
            timelineGeneration: session.snapshot.generation,
            anchorTransactionToken: tokenA,
            presentationGeneration: 41,
            performanceTraceContext: nil,
            ownsPerformancePresentingInterval: false
        )
        let mappingTokenB = controller.beginDatasetMappingJobForTesting()
        let attemptB = ChatInitialFramePresentationAttempt(
            descriptor: descriptor,
            mappingToken: mappingTokenB,
            mappingGeneration: controller.datasetMappingGeneration,
            session: session,
            timelineGeneration: session.snapshot.generation,
            anchorTransactionToken: tokenB,
            presentationGeneration: 42,
            performanceTraceContext: nil,
            ownsPerformancePresentingInterval: false
        )
        controller.pendingOpenMessageRequest = request
        controller.activeAnchorExecutionState = ChatAnchorExecutionState(
            request: request,
            transactionToken: tokenB
        )
        _ = controller.anchorTransactionGate.begin(
            token: tokenB,
            requestIdentity: "p14-same-request"
        )
        controller.initialLocalFirstFrameMappingToken = mappingTokenB
        controller.initialLocalFirstFramePhase = .presenting(descriptor)
        controller.initialLocalFirstFramePresentationOwnership =
            ChatInitialFramePresentationOwnership(
                attempt: attemptB,
                phase: .presenting
            )

        controller.finishPreparedLocalFirstFrameAnchor(
            request: request,
            primary: "p14-stale-a-primary",
            archivedId: "p14-same-request",
            transactionToken: tokenA,
            presentationAttempt: attemptA
        )
        controller.rollbackPreparedLocalFirstFrameAnchor(
            request: request,
            transactionToken: tokenA
        )

        XCTAssertTrue(
            controller.initialLocalFirstFramePresentationOwnership?.attempt ===
                attemptB
        )
        XCTAssertEqual(
            controller.initialLocalFirstFramePresentationOwnership?.phase,
            .presenting
        )
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)
        XCTAssertEqual(controller.activeAnchorExecutionState?.request, request)
        XCTAssertEqual(
            controller.activeAnchorExecutionState?.transactionToken,
            tokenB
        )
        XCTAssertEqual(controller.anchorTransactionGate.snapshot.activeToken, tokenB)
        XCTAssertTrue(controller.initialLocalFirstFrameMappingToken === mappingTokenB)
        XCTAssertFalse(mappingTokenB.isCancelled)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
    }

    func testCommittedAttemptIgnoresMutableMappingGenerationAndRetiredEffectTokenRemainsCurrent() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-committed-generation"
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let session = try XCTUnwrap(controller.timelineSession)
        let attempt = ChatInitialFramePresentationAttempt(
            descriptor: descriptor,
            mappingToken: nil,
            mappingGeneration: controller.datasetMappingGeneration,
            session: session,
            timelineGeneration: session.snapshot.generation,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-committed-generation-token"
            ),
            presentationGeneration: 71,
            performanceTraceContext: nil,
            ownsPerformancePresentingInterval: false
        )
        controller.initialLocalFirstFramePresentationGeneration = 71
        controller.initialLocalFirstFrameLatestEffectToken = attempt.effectToken
        controller.initialLocalFirstFramePhase = .committed(descriptor)
        controller.initialLocalFirstFramePresentationOwnership =
            ChatInitialFramePresentationOwnership(
                attempt: attempt,
                phase: .committed
            )

        _ = controller.beginDatasetMappingJobForTesting()
        _ = session.commit(session.snapshot.timelineSnapshot)

        XCTAssertTrue(
            controller.isCurrentInitialFramePresentationAttempt(
                attempt,
                phase: .committed
            )
        )
        controller.retireCommittedInitialFramePresentationAttempt(attempt)
        XCTAssertNil(controller.initialLocalFirstFramePresentationOwnership)
        XCTAssertTrue(
            controller.isLatestInitialFrameEffectToken(attempt.effectToken),
            "stable-frame retirement must not revoke delayed effects from the exact successful attempt"
        )
    }

    func testSupersededInitialFrameEffectCannotCrossDelayedMentionFlushPermit() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-effect-same-primary"
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let tokenA = ChatInitialFrameEffectToken(
            presentationGeneration: 80,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptor,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-effect-a"
            )
        )
        let tokenB = ChatInitialFrameEffectToken(
            presentationGeneration: 81,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptor,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-effect-b"
            )
        )
        controller.initialLocalFirstFramePresentationGeneration = 81
        controller.initialLocalFirstFrameLatestEffectToken = tokenB
        controller.initialLocalFirstFramePhase = .committed(descriptor)
        let coordinator = controller.readVisiblePresentationCoordinator
        coordinator.recordPresentationReceipt()
        coordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "p14-effect-notification",
                messagePrimary: "p14-effect-message",
                initialFrameEffectToken: tokenA
            )
        ])
        let visibleSnapshot = ChatReadVisiblePresentationSnapshot(
            isApplicationActive: true,
            isWindowAttached: true,
            isWindowSceneForegroundActive: true,
            isKeyWindow: true,
            isTopNavigationDestination: true,
            isVisibleSplitSecondary: false,
            hasCoveringPresentation: false,
            isTransitionActive: false
        )

        XCTAssertNil(
            coordinator.takeFlush(
                snapshot: visibleSnapshot,
                visibleMessagePrimaries: ["p14-effect-message"],
                candidateAdmission: { candidate in
                    candidate.initialFrameEffectToken.map {
                        controller.isLatestInitialFrameEffectToken($0)
                    } ?? true
                }
            )
        )

        coordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "p14-effect-notification",
                messagePrimary: "p14-effect-message",
                initialFrameEffectToken: tokenB
            )
        ])
        let flushB = try XCTUnwrap(
            coordinator.takeFlush(
                snapshot: visibleSnapshot,
                visibleMessagePrimaries: ["p14-effect-message"],
                candidateAdmission: { _ in true }
            )
        )
        XCTAssertTrue(coordinator.claimCurrentMutationPermit(for: flushB))
        coordinator.revoke(initialFrameEffectToken: tokenB)
        var didMutate = false
        XCTAssertFalse(
            coordinator.performFirstPersistentMutationIfPermitted(
                for: flushB,
                { didMutate = true }
            )
        )
        XCTAssertFalse(didMutate)
    }

    func testReadVisibleNilResampleWithoutIdentityPreservesExactInitialFrameOwner() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: makeTraceAnchorRequest(
                controller: controller,
                archivedId: "p14-merge-nil-identity"
            ),
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let token = ChatInitialFrameEffectToken(
            presentationGeneration: 301,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptor,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-merge-nil-identity-token"
            )
        )
        let coordinator = controller.readVisiblePresentationCoordinator
        coordinator.recordPresentationReceipt()
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-nil-notification",
            messagePrimary: "p14-merge-nil-message",
            initialFrameEffectToken: token
        )])
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-nil-notification",
            messagePrimary: "p14-merge-nil-message"
        )])

        let flush = try XCTUnwrap(coordinator.takeFlush(
            snapshot: fullyVisibleReadPresentationSnapshot(),
            visibleMessagePrimaries: ["p14-merge-nil-message"],
            candidateAdmission: { $0.initialFrameEffectToken == token }
        ))
        XCTAssertEqual(flush.candidates.count, 1)
        XCTAssertEqual(flush.candidates.first?.initialFrameEffectToken, token)
        XCTAssertNil(flush.candidates.first?.expectedMessageIdentity)
    }

    func testReadVisibleMergeKeepsCapturedIdentityWhileFreshExactOwnerReplacesOld() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: makeTraceAnchorRequest(
                controller: controller,
                archivedId: "p14-merge-captured-identity"
            ),
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let tokenA = ChatInitialFrameEffectToken(
            presentationGeneration: 302,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptor,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-merge-captured-a"
            )
        )
        let tokenB = ChatInitialFrameEffectToken(
            presentationGeneration: 303,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptor,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-merge-captured-b"
            )
        )
        let identity = ChatReadVisibleMessageIdentity(
            primary: "p14-merge-captured-message",
            owner: controller.owner,
            jid: controller.jid,
            messageId: "p14-merge-captured-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let coordinator = controller.readVisiblePresentationCoordinator
        coordinator.recordPresentationReceipt()
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-captured-notification",
            messagePrimary: identity.primary,
            expectedMessageIdentity: identity,
            initialFrameEffectToken: tokenA
        )])
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-captured-notification",
            messagePrimary: identity.primary,
            initialFrameEffectToken: tokenB
        )])
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-captured-notification",
            messagePrimary: identity.primary
        )])

        let flush = try XCTUnwrap(coordinator.takeFlush(
            snapshot: fullyVisibleReadPresentationSnapshot(),
            visibleMessagePrimaries: [identity.primary]
        ))
        XCTAssertEqual(flush.candidates.first?.initialFrameEffectToken, tokenB)
        XCTAssertEqual(flush.candidates.first?.expectedMessageIdentity, identity)
    }

    func testReadVisibleNilResampleCannotEscapeExactP14Revocation() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: makeTraceAnchorRequest(
                controller: controller,
                archivedId: "p14-merge-revoke-escape"
            ),
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let token = ChatInitialFrameEffectToken(
            presentationGeneration: 304,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptor,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-merge-revoke-token"
            )
        )
        let coordinator = controller.readVisiblePresentationCoordinator
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-revoke-notification",
            messagePrimary: "p14-merge-revoke-message",
            initialFrameEffectToken: token
        )])
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-merge-revoke-notification",
            messagePrimary: "p14-merge-revoke-message"
        )])

        coordinator.revoke(initialFrameEffectToken: token)

        XCTAssertEqual(coordinator.pendingCandidateCount, 0)
        XCTAssertTrue(coordinator.pendingMessagePrimaries.isEmpty)
    }

    func testPostBootstrapTerminalRequiresExactAdmissionAndTerminalGeneration() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let request = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-post-bootstrap-admission"
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        controller.pendingOpenMessageRequest = request
        let mappingTokenA = controller.beginDatasetMappingJobForTesting()
        controller.initialLocalFirstFrameMappingToken = mappingTokenA
        controller.initialLocalFirstFramePhase = .preparing(descriptor)
        let baseGenerationA = session.snapshot.generation
        let admissionA = ChatPostBootstrapInitialFrameAdmission(
            identity: ChatPostBootstrapInitialFrameAdmissionIdentity(
                conversationKey: controller.chatTimelineConversationKey,
                bootstrapQueryId: controller.initialBootstrapQueryId,
                targetFingerprint:
                    controller.initialBootstrapTargetFingerprint,
                descriptor: descriptor,
                datasetMappingGeneration:
                    controller.datasetMappingGeneration,
                timelineGeneration: baseGenerationA
            ),
            mappingToken: mappingTokenA,
            session: session
        )
        controller.activePostBootstrapInitialFrameAdmission = admissionA

        XCTAssertTrue(
            controller.isCurrentPostBootstrapInitialFrameAdmission(
                admissionA,
                session: session,
                requiredTimelineGeneration: baseGenerationA
            )
        )
        _ = session.commit(session.snapshot.timelineSnapshot)
        XCTAssertFalse(
            controller.isCurrentPostBootstrapInitialFrameAdmission(
                admissionA,
                session: session,
                requiredTimelineGeneration: baseGenerationA
            ),
            "a blocked/search-failure terminal from the old base generation must be stale"
        )

        let mappingTokenB = controller.beginDatasetMappingJobForTesting()
        controller.initialLocalFirstFrameMappingToken = mappingTokenB
        controller.initialLocalFirstFramePhase = .preparing(descriptor)
        let baseGenerationB = session.snapshot.generation
        let admissionB = ChatPostBootstrapInitialFrameAdmission(
            identity: ChatPostBootstrapInitialFrameAdmissionIdentity(
                conversationKey: controller.chatTimelineConversationKey,
                bootstrapQueryId: controller.initialBootstrapQueryId,
                targetFingerprint:
                    controller.initialBootstrapTargetFingerprint,
                descriptor: descriptor,
                datasetMappingGeneration:
                    controller.datasetMappingGeneration,
                timelineGeneration: baseGenerationB
            ),
            mappingToken: mappingTokenB,
            session: session
        )
        controller.activePostBootstrapInitialFrameAdmission = admissionB

        XCTAssertFalse(
            controller.isCurrentPostBootstrapInitialFrameAdmission(
                admissionA,
                session: session
            )
        )
        XCTAssertTrue(
            controller.isCurrentPostBootstrapInitialFrameAdmission(
                admissionB,
                session: session,
                requiredTimelineGeneration: baseGenerationB
            )
        )
    }

    func testDifferentExactTargetAdoptsCommittedSkeletonWithoutRemapAndStartsItsLease() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.datasource = []
        controller.appliedBootstrapLoadingState = nil
        controller.showSkeletonObserver.accept(true)
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "trace-anchor-a"
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "trace-anchor-b"
        )
        let recorder = ChatPerformanceTraceRecorder()
        let recorderInstallation = ChatPerformanceSignposts
            .installRecorderForTesting(recorder)
        defer { recorderInstallation.cancel() }

        controller.pendingOpenMessageRequest = requestA
        let contextA = controller.acceptChatOpenPerformanceTrace(
            purpose: .notificationRoute,
            semanticTargetFingerprint: .message(requestA),
            bootstrapTarget: .latest
        )
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(
            controller.chatOpenPerformanceTraceLifecycle
                .hasRecordedPresentationReceipt(.skeleton, context: contextA)
        )

        let rowIDs = controller.datasource.map(\.primary)
        let datasetGeneration = controller.datasetMappingGeneration
        let skeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let contentOffset = controller.messagesCollectionView.contentOffset
        controller.scrollFrameOperationCounter.setEnabled(true)
        controller.scrollFrameOperationCounter.reset()

        controller.pendingOpenMessageRequest = requestB
        let contextB = controller.acceptChatOpenPerformanceTrace(
            purpose: .notificationRoute,
            semanticTargetFingerprint: .message(requestB),
            bootstrapTarget: .latest
        )
        XCTAssertNotEqual(contextB, contextA)
        XCTAssertTrue(
            controller.chatOpenPerformanceTraceLifecycle
                .hasRecordedPresentationReceipt(.skeleton, context: contextB),
            "the new target must adopt the already-visible exact skeleton once"
        )

        controller.applyBootstrapLoadingState(
            .blockingTarget,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        controller.requestInitialBootstrapArchive()

        XCTAssertEqual(controller.datasource.map(\.primary), rowIDs)
        XCTAssertEqual(controller.datasetMappingGeneration, datasetGeneration)
        XCTAssertEqual(
            controller.bootstrapSkeletonMappingGeneration,
            skeletonGeneration
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.x,
            contentOffset.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            contentOffset.y,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            0
        )
        XCTAssertNil(
            controller.pendingInitialBootstrapArchiveRequestAfterSkeletonReceiptShowsFailure,
            "the already-visible skeleton receipt must not leave B behind the gate"
        )
        let queryID = try XCTUnwrap(controller.initialBootstrapQueryId)
        XCTAssertTrue(ChatInitialBootstrapRequestCoordinator.shared.isActive(
            key: controller.initialBootstrapRequestKey,
            queryId: queryID
        ))
        XCTAssertEqual(
            ChatInitialBootstrapRequestCoordinator.shared
                .activePerformanceTraceContext(
                    for: controller.initialBootstrapRequestKey,
                    targetFingerprint: .init(target: .latest, boundary: nil),
                    semanticTargetFingerprint: .message(requestB)
                ),
            contextB
        )
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.context == contextB &&
                    ($0.phase == .openRequest || $0.phase == .skeletonReceipt)
            }.map(\.phase),
            [.openRequest, .skeletonReceipt]
        )
    }

    func testConfirmedEmptyStillAdmitsGenuineContentAndRetryOverlay() {
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .empty,
                next: .content
            ),
            .apply,
            "genuine content may replace confirmed empty without an intermediate skeleton"
        )
        XCTAssertEqual(
            ChatBootstrapStateApplicationPolicy.decision(
                previous: .empty,
                next: .failure(fallback: .empty)
            ),
            .apply,
            "a terminal failure may add Retry over the existing empty presentation"
        )
    }

    func testFreshControllerMayEnterBootstrapSkeletonAfterConfirmedEmptyController() {
        let confirmedEmptyController = makeController()
        confirmedEmptyController.loadViewIfNeeded()
        confirmedEmptyController.datasource = []
        confirmedEmptyController.appliedBootstrapLoadingState = .empty
        confirmedEmptyController.showSkeletonObserver.accept(false)

        let reopenedController = makeController()
        reopenedController.loadViewIfNeeded()
        reopenedController.datasource = []
        reopenedController.appliedBootstrapLoadingState = nil
        reopenedController.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        XCTAssertEqual(confirmedEmptyController.appliedBootstrapLoadingState, .empty)
        XCTAssertFalse(confirmedEmptyController.showSkeletonObserver.value)
        XCTAssertEqual(reopenedController.appliedBootstrapLoadingState, .blockingArchive)
        XCTAssertTrue(reopenedController.showSkeletonObserver.value)
        XCTAssertTrue(reopenedController.hasCommittedBootstrapSkeletonRows)
        XCTAssertEqual(reopenedController.datasource.count, 30)
        XCTAssertTrue(reopenedController.datasource.allSatisfy(\.isFakeMessage))
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
        // Keep this test focused on receipt retention. The fresh-generation
        // follow-up contract is covered separately below.
        controller.hasAttemptedInitialBootstrapBoundaryFollowUp = true
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
        let publishFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MessageArchiveEndPageDispatcher.publish(final)
            publishFinished.signal()
        }
        XCTAssertEqual(
            publishFinished.wait(timeout: .now() + 2),
            .success,
            "background persistence terminal must finish while main is held"
        )
        XCTAssertTrue(snapshotObserverSawCommit)
        XCTAssertNotNil(controller.initialBootstrapReadinessObservationToken)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        let retainedPage = try? XCTUnwrap(
            coordinator.cachedCommittedPage(key: key, queryId: lease.queryId)
        )
        XCTAssertFalse(retainedPage?.hasPresentationMaterialization ?? true)
        XCTAssertFalse(retainedPage?.confirmsEmptyConversation ?? true)
        XCTAssertNotNil(
            coordinator.pendingFollowUpRequest(for: key),
            "coordinator must retain the repair target before snapshot completion"
        )
        XCTAssertFalse(
            controller.completedRemoteHistoryEndPageQueryIds.contains(lease.queryId)
        )

        // Model the snapshot pump winning the terminal race before the joined
        // controller can process the committed receipt on the main queue.
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(
            controller.completedRemoteHistoryEndPageQueryIds.contains(lease.queryId),
            "the joined UI must claim the retained committed page"
        )
        XCTAssertNil(controller.initialBootstrapReadinessObservationToken)
        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)

        coordinator.detach(key: key, observation: snapshotObservation)
        XCTAssertFalse(
            coordinator.isActive(key: key, queryId: lease.queryId),
            "the deferred receipt must be released after every joined consumer detaches"
        )
        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testCommittedPendingFollowUpRollsToFreshQueryGeneration() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let controller = makeController()
        let key = controller.initialBootstrapRequestKey
        let first = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-follow-up-old",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        )
        guard case .start(let oldLease) = first else {
            return XCTFail("snapshot page must own the first generation")
        }

        let final = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: oldLease.queryId,
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
        let pending = try XCTUnwrap(coordinator.pendingFollowUpRequest(for: key))

        let next = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-follow-up-fresh",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: pending.fingerprint,
            observer: { _, _, _ in }
        )
        guard case .start(let freshLease) = next else {
            return XCTFail("pending target must start a fresh archive generation")
        }

        XCTAssertNotEqual(freshLease.queryId, oldLease.queryId)
        XCTAssertFalse(coordinator.isActive(key: key, queryId: oldLease.queryId))
        XCTAssertTrue(coordinator.isActive(key: key, queryId: freshLease.queryId))
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .queued)
        XCTAssertNil(coordinator.pendingFollowUpRequest(for: key))
        XCTAssertTrue(coordinator.complete(key: key, queryId: freshLease.queryId))
    }

    func testCommittedPendingFollowUpWithChangedBoundaryRollsToFreshQueryGeneration() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let controller = makeController()
        let key = controller.initialBootstrapRequestKey
        let oldBoundary = MessageArchiveManager.ConversationArchiveBoundaryFingerprint(
            chatExists: true,
            archiveStateExists: true,
            chatSnapshotArchiveId: "snapshot-old",
            archiveSnapshotArchiveId: "snapshot-old",
            archiveSnapshotMessageId: "message-old",
            unreadAfterId: nil,
            unreadCount: 0
        )
        let currentBoundary = MessageArchiveManager.ConversationArchiveBoundaryFingerprint(
            chatExists: true,
            archiveStateExists: true,
            chatSnapshotArchiveId: "snapshot-current",
            archiveSnapshotArchiveId: "snapshot-current",
            archiveSnapshotMessageId: "message-current",
            unreadAfterId: nil,
            unreadCount: 0
        )
        let first = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-boundary-old",
            timeout: 45,
            purpose: .snapshotRepair,
            targetFingerprint: .init(target: .latest, boundary: oldBoundary),
            observer: { _, _, _ in }
        )
        guard case .start(let oldLease) = first else {
            return XCTFail("snapshot page must own the first generation")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: oldLease.queryId,
            hasDurableCoverage: false,
            boundaryFingerprint: oldBoundary,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: false,
            recommendedFollowUpTarget: .latest
        )
        let pending = try XCTUnwrap(coordinator.pendingFollowUpRequest(for: key))
        XCTAssertEqual(pending.fingerprint.target, .latest)
        XCTAssertEqual(pending.fingerprint.boundary, oldBoundary)

        let requestedFingerprint =
            MessageArchiveManager.ChatBootstrapTargetFingerprint(
                target: .latest,
                boundary: currentBoundary
            )
        let next = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-boundary-current",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: requestedFingerprint,
            observer: { _, _, _ in }
        )
        guard case .start(let freshLease) = next else {
            return XCTFail(
                "the same pending target with a new boundary must start a fresh generation"
            )
        }

        XCTAssertNotEqual(freshLease.queryId, oldLease.queryId)
        XCTAssertEqual(freshLease.targetFingerprint, requestedFingerprint)
        XCTAssertFalse(coordinator.isActive(key: key, queryId: oldLease.queryId))
        XCTAssertTrue(coordinator.isActive(key: key, queryId: freshLease.queryId))
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .queued)
        XCTAssertNil(coordinator.pendingFollowUpRequest(for: key))
        XCTAssertTrue(coordinator.complete(key: key, queryId: freshLease.queryId))
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

    func testConversationARealDatasourceReplacementByBPublishesNoFrameContainingARows() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let oldSession = try XCTUnwrap(controller.timelineSession)
        let oldRows = installCommittedConversationARows(in: controller)
        let oldDatasetGeneration = controller.datasetMappingGeneration
        let oldSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let oldResidentGeneration = controller.scrollResidentMetadata.generation
        let oldPrimary = try XCTUnwrap(oldRows.first?.primary)
        controller.retainedMessageAnchor = ChatRetainedMessageAnchor(
            primary: oldPrimary,
            archivedId: oldRows.first?.archivedId,
            displayRevision: "conversation-a-revision",
            viewportRelativeMinY: 120
        )
        controller.pendingOpenMessageRequest = ChatOpenMessageRequest(
            chatJid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: oldPrimary,
                archivedId: oldRows.first?.archivedId,
                messageId: oldRows.first?.messageId,
                authorId: controller.jid,
                bodyFingerprint: nil,
                sourceDate: oldRows.first?.sentDate
            ),
            highlight: false,
            markReadOnVisible: true,
            source: .pushNotification
        )
        let staleAnchorToken = ChatAnchorTransactionToken(
            rawValue: "conversation-a-anchor-token"
        )
        controller.activeAnchorExecutionState = ChatAnchorExecutionState(
            request: try XCTUnwrap(controller.pendingOpenMessageRequest),
            transactionToken: staleAnchorToken
        )
        var staleAnchorPositionedCallbackCount = 0
        var staleAnchorFailureCallbackCount = 0
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .down,
            animatedScroll: false,
            onFailed: { staleAnchorFailureCallbackCount += 1 },
            onPositioned: { staleAnchorPositionedCallbackCount += 1 }
        )
        _ = controller.anchorTransactionGate.begin(
            token: staleAnchorToken,
            requestIdentity: oldPrimary
        )
        XCTAssertTrue(controller.anchorTransactionGate.acquire(
            .loader,
            token: staleAnchorToken
        ))
        controller.messagesToReadObserver.accept([oldPrimary])
        controller.readVisiblePresentationCoordinator.recordPresentationReceipt()
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "conversation-a-notification",
                messagePrimary: oldPrimary
            )
        ])
        let staleReadFlush = try XCTUnwrap(
            controller.readVisiblePresentationCoordinator.takeFlush(
                snapshot: ChatReadVisiblePresentationSnapshot(
                    isApplicationActive: true,
                    isWindowAttached: true,
                    isWindowSceneForegroundActive: true,
                    isKeyWindow: true,
                    isTopNavigationDestination: true,
                    isVisibleSplitSecondary: false,
                    hasCoveringPresentation: false,
                    isTransitionActive: false
                ),
                visibleMessagePrimaries: [oldPrimary]
            )
        )

        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )
        let replacementJid = "conversation-b-peer@example.com"
        controller.jid = replacementJid
        controller.opponentSender = Sender(id: replacementJid, displayName: "Conversation B")
        controller.configureDataset()

        assertConversationReplacementFrames(
            recorder.frames,
            expectedOwner: controller.owner,
            expectedJid: replacementJid,
            expectedConversationType: .regular,
            forbiddenPrimaries: Set(oldRows.map(\.primary))
        )
        XCTAssertFalse(try XCTUnwrap(controller.timelineSession) === oldSession)
        XCTAssertTrue(try XCTUnwrap(controller.timelineSession).isConfigured(
            for: ChatTimelineConversationKey(
                owner: controller.owner,
                jid: replacementJid,
                conversationType: .regular
            )
        ))
        XCTAssertGreaterThan(controller.datasetMappingGeneration, oldDatasetGeneration)
        XCTAssertGreaterThan(controller.bootstrapSkeletonMappingGeneration, oldSkeletonGeneration)
        XCTAssertGreaterThan(controller.scrollResidentMetadata.generation, oldResidentGeneration)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.hasCommittedExactBootstrapSkeletonRows)
        XCTAssertFalse(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertNil(controller.retainedMessageAnchor)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertNil(controller.activeAnchorExecutionHooks)
        XCTAssertNil(controller.anchorTransactionGate.snapshot.activeToken)
        XCTAssertEqual(
            controller.anchorTransactionGate.accept(
                .scroll,
                token: staleAnchorToken
            ),
            .stale
        )
        XCTAssertFalse(controller.anchorTransactionGate.finish(token: staleAnchorToken))
        XCTAssertEqual(staleAnchorPositionedCallbackCount, 0)
        XCTAssertEqual(staleAnchorFailureCallbackCount, 0)
        XCTAssertEqual(controller.messagesToReadObserver.value, [])
        XCTAssertEqual(controller.readVisiblePresentationCoordinator.pendingCandidateCount, 0)
        XCTAssertEqual(controller.readVisiblePresentationCoordinator.successfulFlushCount, 0)
        XCTAssertFalse(controller.readVisiblePresentationCoordinator.hasPresentationReceipt)
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator
                .claimCurrentMutationPermit(for: staleReadFlush)
        )
        var staleReadMutationCallbackCount = 0
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator
                .performFirstPersistentMutationIfPermitted(for: staleReadFlush) {
                    staleReadMutationCallbackCount += 1
                }
        )
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator.complete(
                flush: staleReadFlush,
                succeeded: true
            )
        )
        XCTAssertEqual(staleReadMutationCallbackCount, 0)
    }

    func testConversationReplacementDetachesCommittedPendingABootstrapWithoutDestroyingSharedReceipt() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let oldRows = installCommittedConversationARows(in: controller)
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let conversationAKey = ChatInitialBootstrapRequestKey(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let acquisition = coordinator.acquireOrJoin(
            key: conversationAKey,
            proposedQueryId: "conversation-a-committed-pending",
            timeout: 45,
            observer: { _, _, _ in }
        )
        guard case .start(let conversationALease) = acquisition else {
            return XCTFail("conversation A must own its account-scoped bootstrap lease")
        }
        controller.initialBootstrapLeaseKey = conversationAKey
        controller.registerRemoteHistoryEndPageDispatcher(
            queryId: conversationALease.queryId
        )
        controller.beginInitialBootstrapTracking(
            queryId: conversationALease.queryId,
            timeout: nil
        )
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertEqual(controller.initialBootstrapQueryId, conversationALease.queryId)
        XCTAssertNotNil(controller.initialBootstrapReadinessObservationToken)
        XCTAssertNotNil(
            controller.remoteHistoryEndPageDispatcherTokens[
                conversationALease.queryId
            ]
        )
        XCTAssertNotNil(
            controller.remoteHistoryFailureDispatcherTokens[
                conversationALease.queryId
            ]
        )
        XCTAssertTrue(coordinator.isActive(
            key: conversationAKey,
            queryId: conversationALease.queryId
        ))

        var staleTimeoutEffectCount = 0
        var staleFallbackEffectCount = 0
        let staleTimeout = DispatchWorkItem { staleTimeoutEffectCount += 1 }
        let staleFallback = DispatchWorkItem { staleFallbackEffectCount += 1 }
        controller.initialBootstrapTimeoutWorkItem = staleTimeout
        controller.initialBootstrapLocalHistoryFallbackWorkItem = staleFallback
        DispatchQueue.main.async(execute: staleTimeout)
        DispatchQueue.main.async(execute: staleFallback)

        let committedPending = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.recordCommittedPageForTesting(
                key: conversationAKey,
                queryId: conversationALease.queryId,
                hasDurableCoverage: true,
                resultCount: oldRows.count
            )
            committedPending.signal()
        }
        XCTAssertEqual(committedPending.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(coordinator.readiness(for: conversationAKey)?.phase, .committed)
        XCTAssertNotNil(coordinator.cachedCommittedPage(
            key: conversationAKey,
            queryId: conversationALease.queryId
        ))
        XCTAssertFalse(
            controller.didReceiveInitialBootstrapEndPage,
            "the committed A callback must still be queued behind the main actor"
        )

        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )
        let conversationBJid = "conversation-b-after-pending-a@example.com"
        controller.jid = conversationBJid
        controller.opponentSender = Sender(
            id: conversationBJid,
            displayName: "Conversation B"
        )
        controller.configureDataset()

        assertConversationReplacementFrames(
            recorder.frames,
            expectedOwner: controller.owner,
            expectedJid: conversationBJid,
            expectedConversationType: .regular,
            forbiddenPrimaries: Set(oldRows.map(\.primary))
        )
        XCTAssertNil(controller.initialBootstrapQueryId)
        XCTAssertNil(controller.initialBootstrapLeaseKey)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(controller.initialBootstrapReadinessObservationKey)
        XCTAssertNil(controller.initialBootstrapReadinessObservationToken)
        XCTAssertNil(controller.initialBootstrapTimeoutWorkItem)
        XCTAssertNil(controller.initialBootstrapLocalHistoryFallbackWorkItem)
        XCTAssertNil(
            controller.remoteHistoryEndPageDispatcherTokens[
                conversationALease.queryId
            ]
        )
        XCTAssertNil(
            controller.remoteHistoryFailureDispatcherTokens[
                conversationALease.queryId
            ]
        )
        let bPrimaries = controller.datasource.map(\.primary)
        let bApplyCount = controller.scrollFrameOperationCounter
            .snapshot()[.datasourceApplies]
        let bFrameCount = recorder.frames.count
        let bDatasetGeneration = controller.datasetMappingGeneration
        let bSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let bResidentGeneration = controller.scrollResidentMetadata.generation
        let bContentOffset = controller.messagesCollectionView.contentOffset
        let bReadGeneration = controller.readVisiblePresentationCoordinator.generation
        let bReadGeometryGeneration = controller.readVisiblePresentationCoordinator
            .geometryGeneration
        let bInitialFirstContentApplyCount = controller.initialFirstContentApplyCount
        XCTAssertNil(controller.retainedMessageAnchor)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(controller.messagesToReadObserver.value, [])

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.datasource.map(\.primary), bPrimaries)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            bApplyCount
        )
        XCTAssertEqual(recorder.frames.count, bFrameCount)
        XCTAssertEqual(controller.datasetMappingGeneration, bDatasetGeneration)
        XCTAssertEqual(
            controller.bootstrapSkeletonMappingGeneration,
            bSkeletonGeneration
        )
        XCTAssertEqual(
            controller.scrollResidentMetadata.generation,
            bResidentGeneration
        )
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, bContentOffset)
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.generation,
            bReadGeneration
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.geometryGeneration,
            bReadGeometryGeneration
        )
        XCTAssertEqual(
            controller.initialFirstContentApplyCount,
            bInitialFirstContentApplyCount
        )
        XCTAssertNil(controller.retainedMessageAnchor)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(controller.messagesToReadObserver.value, [])
        XCTAssertFalse(controller.didReceiveInitialBootstrapEndPage)
        XCTAssertEqual(staleTimeoutEffectCount, 0)
        XCTAssertEqual(staleFallbackEffectCount, 0)
        XCTAssertEqual(coordinator.readiness(for: conversationAKey)?.phase, .committed)
        XCTAssertNotNil(
            coordinator.cachedCommittedPage(
                key: conversationAKey,
                queryId: conversationALease.queryId
            ),
            "switching UI ownership must not acknowledge or destroy A's shared receipt"
        )

        let conversationBKey = controller.initialBootstrapRequestKey
        XCTAssertNotEqual(conversationBKey, conversationAKey)
        let conversationBAcquisition = coordinator.acquireOrJoin(
            key: conversationBKey,
            proposedQueryId: "conversation-b-fresh-query",
            timeout: 45,
            observer: { _, _, _ in }
        )
        guard case .start(let conversationBLease) = conversationBAcquisition else {
            return XCTFail("conversation B must acquire a fresh scoped bootstrap query")
        }
        XCTAssertNotEqual(conversationBLease.queryId, conversationALease.queryId)
        controller.initialBootstrapLeaseKey = conversationBKey
        controller.beginInitialBootstrapTracking(
            queryId: conversationBLease.queryId,
            timeout: nil
        )
        XCTAssertEqual(controller.initialBootstrapQueryId, conversationBLease.queryId)
        XCTAssertEqual(controller.initialBootstrapLeaseKey, conversationBKey)
    }

    func testConversationReplacementCancelsActiveAPagingAndRejectsLateATerminalsBeforeFreshBPaging() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let oldSession = try XCTUnwrap(controller.timelineSession)
        let oldRows = installCommittedConversationARows(in: controller)
        let oldOwner = controller.owner
        let oldJid = controller.jid
        let oldConversationKey = ChatTimelineConversationKey(
            owner: oldOwner,
            jid: oldJid,
            conversationType: .regular
        )
        let oldQueryId = "conversation-a-active-page"
        controller.virtualTimelineState = ChatVirtualTimelineState(
            conversationKey: oldConversationKey,
            segments: [.unknownOlder, .loadingPlaceholder(.top)],
            oldest: nil,
            newest: nil,
            residentPrimaryKeys: [],
            residentArchivedIds: [],
            activeRemoteLoad: ChatTimelineRemoteLoad(
                queryId: oldQueryId,
                direction: .older,
                decision: .remoteOlderPage,
                cursorId: "conversation-a-cursor"
            ),
            activePlaceholder: .top,
            isResidentAtLiveTail: false
        )
        let oldQueryGeneration = Int(oldSession.snapshot.generation)
        controller.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
            queryId: oldQueryId,
            generation: oldQueryGeneration,
            direction: .older,
            chatPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: oldJid,
                owner: oldOwner,
                conversationType: .regular
            ),
            persistedCursorId: "conversation-a-persisted-cursor",
            persistedFullArchiveLoaded: false,
            requestedCursorId: "conversation-a-cursor",
            requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 100),
            preLoadObserverCount: oldRows.count,
            preLoadOldestArchivedId: oldRows.first?.archivedId,
            preLoadNewestArchivedId: oldRows.last?.archivedId,
            preLoadFullArchiveLoaded: false,
            preLoadNewerLiveEdgeReached: true,
            remoteFetchStarted: true,
            isArchiveEndVerificationProbe: false,
            canMutateOlderArchiveEnd: true,
            expectedWindowMaxIndex: 100,
            coverageUpdateKind: .pageOlder(cursorArchiveId: "conversation-a-cursor")
        )

        var oldWireTerminalCount = 0
        var oldPersistenceCleanupCount = 0
        var oldPersistenceBarrierCount = 0
        var oldTimeoutEffectCount = 0
        var oldDeliveryCount = 0
        XCTAssertTrue(controller.remoteHistoryQueryCoordinator.register(
            ChatRemoteHistoryQueryDescriptor(
                conversationKey: oldConversationKey,
                queryId: oldQueryId,
                direction: .older,
                cursorId: "conversation-a-cursor",
                generation: oldQueryGeneration
            ),
            wireTerminal: { oldWireTerminalCount += 1 },
            persistenceCleanup: { oldPersistenceCleanupCount += 1 }
        ) { _, _ in
            oldPersistenceBarrierCount += 1
        })
        XCTAssertTrue(controller.remoteHistoryQueryCoordinator.scheduleTimeout(
            queryId: oldQueryId,
            generation: oldQueryGeneration,
            after: 45,
            terminalReason: .timeout,
            onTimeout: { oldTimeoutEffectCount += 1 }
        ))
        controller.registerRemoteHistoryEndPageDispatcher(queryId: oldQueryId)
        controller.registerRemoteHistoryFailureDispatcher(queryId: oldQueryId)
        controller.remoteHistoryRequestStartedAtByQueryId[oldQueryId] = Date()
        var oldCompletionRetryEffectCount = 0
        let oldCompletionRetry = DispatchWorkItem {
            oldCompletionRetryEffectCount += 1
        }
        controller.interactiveHistoryCompletionRetryWorkItem = oldCompletionRetry
        DispatchQueue.main.async(execute: oldCompletionRetry)
        controller.activeHistoryBoundaryPlaceholder = .top
        controller.timelineInteractionState.locked = true
        controller.beginHistoryLoadingUI(queryId: oldQueryId)
        controller.setDatasourceLoadingEnabled(false)
        let oldPrimary = try XCTUnwrap(oldRows.first?.primary)
        controller.retainedMessageAnchor = ChatRetainedMessageAnchor(
            primary: oldPrimary,
            archivedId: oldRows.first?.archivedId,
            displayRevision: "conversation-a-active-page",
            viewportRelativeMinY: 96
        )
        controller.messagesToReadObserver.accept([oldPrimary])
        controller.readVisiblePresentationCoordinator.recordPresentationReceipt()
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "conversation-a-page-notification",
                messagePrimary: oldPrimary
            )
        ])
        XCTAssertEqual(controller.remoteHistoryQueryCoordinator.activeQueryCount, 1)
        XCTAssertTrue(controller.remoteHistoryQueryCoordinator.hasScheduledTimeout(
            queryId: oldQueryId
        ))
        XCTAssertTrue(MessageArchiveEndPageDispatcher.hasHandler(
            owner: oldOwner,
            queryId: oldQueryId
        ))
        XCTAssertTrue(MessageArchiveRequestFailureDispatcher.hasHandler(
            owner: oldOwner,
            queryId: oldQueryId
        ))

        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )
        let replacementJid = "conversation-b-after-active-page@example.com"
        controller.jid = replacementJid
        controller.opponentSender = Sender(
            id: replacementJid,
            displayName: "Conversation B"
        )
        controller.configureDataset()

        assertConversationReplacementFrames(
            recorder.frames,
            expectedOwner: oldOwner,
            expectedJid: replacementJid,
            expectedConversationType: .regular,
            forbiddenPrimaries: Set(oldRows.map(\.primary))
        )
        XCTAssertNil(controller.interactiveHistoryPageLoadContext)
        XCTAssertNil(controller.interactiveHistoryCompletionRetryWorkItem)
        XCTAssertNil(controller.remoteHistoryFinishingQueryId)
        XCTAssertTrue(controller.remoteHistoryEndPageDispatcherTokens.isEmpty)
        XCTAssertTrue(controller.remoteHistoryFailureDispatcherTokens.isEmpty)
        XCTAssertTrue(controller.remoteHistoryRequestStartedAtByQueryId.isEmpty)
        XCTAssertEqual(controller.remoteHistoryQueryCoordinator.activeQueryCount, 0)
        XCTAssertEqual(
            controller.remoteHistoryQueryCoordinator.terminalReason(queryId: oldQueryId),
            .cancelled
        )
        XCTAssertFalse(controller.remoteHistoryQueryCoordinator.hasScheduledTimeout(
            queryId: oldQueryId
        ))
        XCTAssertNil(oldSession.snapshot.state.activeRemoteLoad)
        XCTAssertNil(controller.virtualTimelineState.activeRemoteLoad)
        XCTAssertNil(controller.activeHistoryBoundaryPlaceholder)
        XCTAssertFalse(controller.timelineInteractionState.locked)
        XCTAssertFalse(controller.timelineInteractionState.isLoading)
        XCTAssertFalse(controller.showLoadingIndicator.value)
        XCTAssertTrue(controller.activeChatHistoryLoadActivityKeys.isEmpty)
        XCTAssertEqual(oldWireTerminalCount, 0)
        XCTAssertEqual(oldPersistenceCleanupCount, 1)
        XCTAssertEqual(oldPersistenceBarrierCount, 0)

        let bPrimaries = controller.datasource.map(\.primary)
        let bDatasetGeneration = controller.datasetMappingGeneration
        let bSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let bResidentGeneration = controller.scrollResidentMetadata.generation
        let bReadGeneration = controller.readVisiblePresentationCoordinator.generation
        let bReadGeometryGeneration = controller.readVisiblePresentationCoordinator
            .geometryGeneration
        let bContentOffset = controller.messagesCollectionView.contentOffset
        let bApplyCount = controller.scrollFrameOperationCounter
            .snapshot()[.datasourceApplies]
        let bFrameCount = recorder.frames.count
        let bTimelineSession = try XCTUnwrap(controller.timelineSession)
        let bTimelineGeneration = bTimelineSession.snapshot.generation
        let bTimelineState = bTimelineSession.snapshot.state
        let bTimelineLoadingState = bTimelineSession.snapshot.loadingState
        let bArchiveCoverage = controller.loadChatArchiveStateSnapshot()

        let lateFinalState = MessageArchivePageEndState(
            queryExhausted: true,
            archiveEnded: false,
            persistedMessageCount: oldRows.count
        )
        XCTAssertEqual(
            controller.remoteHistoryQueryCoordinator.receiveFinal(
                queryId: oldQueryId,
                generation: oldQueryGeneration,
                page: ChatRemoteHistoryFinalPage(
                    state: lateFinalState,
                    first: "conversation-a-first",
                    last: "conversation-a-last",
                    count: oldRows.count
                ),
                completion: { _ in oldDeliveryCount += 1 }
            ),
            .stale
        )
        XCTAssertFalse(MessageArchiveEndPageDispatcher.publish(
            MessageArchiveEndPageEvent(
                owner: oldOwner,
                queryId: oldQueryId,
                state: lateFinalState,
                first: "conversation-a-first",
                last: "conversation-a-last",
                count: oldRows.count,
                streamKind: .uiAction,
                source: .unroutedFinalIQ
            )
        ))
        XCTAssertFalse(MessageArchiveRequestFailureDispatcher.publish(
            MessageArchiveRequestFailureEvent(
                owner: oldOwner,
                queryId: oldQueryId,
                streamKind: .uiAction,
                reason: .serverError,
                errorDescription: "late conversation A failure",
                pendingQueryCount: 0
            )
        ))
        controller.didReceiveEndPage(
            queryId: oldQueryId,
            state: lateFinalState,
            first: "conversation-a-first",
            last: "conversation-a-last",
            count: oldRows.count
        )
        controller.handleInteractiveRemoteArchiveFailure(
            queryId: oldQueryId,
            reason: .serverError,
            streamKind: .uiAction,
            errorDescription: "late conversation A failure"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.datasource.map(\.primary), bPrimaries)
        XCTAssertEqual(controller.datasetMappingGeneration, bDatasetGeneration)
        XCTAssertEqual(
            controller.bootstrapSkeletonMappingGeneration,
            bSkeletonGeneration
        )
        XCTAssertEqual(
            controller.scrollResidentMetadata.generation,
            bResidentGeneration
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.generation,
            bReadGeneration
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.geometryGeneration,
            bReadGeometryGeneration
        )
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, bContentOffset)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            bApplyCount
        )
        XCTAssertEqual(recorder.frames.count, bFrameCount)
        XCTAssertTrue(controller.timelineSession === bTimelineSession)
        XCTAssertEqual(
            bTimelineSession.snapshot.generation,
            bTimelineGeneration
        )
        XCTAssertEqual(bTimelineSession.snapshot.state, bTimelineState)
        XCTAssertEqual(
            bTimelineSession.snapshot.loadingState,
            bTimelineLoadingState
        )
        XCTAssertEqual(
            controller.loadChatArchiveStateSnapshot(),
            bArchiveCoverage,
            "late A terminals must not advance B archive coverage"
        )
        XCTAssertNil(controller.retainedMessageAnchor)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(controller.messagesToReadObserver.value, [])
        XCTAssertEqual(oldWireTerminalCount, 0)
        XCTAssertEqual(oldPersistenceCleanupCount, 1)
        XCTAssertEqual(oldPersistenceBarrierCount, 0)
        XCTAssertEqual(oldTimeoutEffectCount, 0)
        XCTAssertEqual(oldCompletionRetryEffectCount, 0)
        XCTAssertEqual(oldDeliveryCount, 0)

        let bQueryId = "conversation-b-fresh-page"
        let bConversationKey = ChatTimelineConversationKey(
            owner: controller.owner,
            jid: replacementJid,
            conversationType: .regular
        )
        let bGeneration = Int(try XCTUnwrap(controller.timelineSession).snapshot.generation)
        controller.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
            queryId: bQueryId,
            generation: bGeneration,
            direction: .older,
            chatPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: replacementJid,
                owner: controller.owner,
                conversationType: .regular
            ),
            persistedCursorId: "conversation-b-persisted-cursor",
            persistedFullArchiveLoaded: false,
            requestedCursorId: "conversation-b-cursor",
            requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 100),
            preLoadObserverCount: 0,
            preLoadOldestArchivedId: nil,
            preLoadNewestArchivedId: nil,
            preLoadFullArchiveLoaded: false,
            preLoadNewerLiveEdgeReached: false,
            remoteFetchStarted: false,
            isArchiveEndVerificationProbe: false,
            canMutateOlderArchiveEnd: true,
            expectedWindowMaxIndex: 100,
            coverageUpdateKind: .pageOlder(cursorArchiveId: "conversation-b-cursor")
        )
        var bPersistenceCleanupCount = 0
        XCTAssertTrue(controller.remoteHistoryQueryCoordinator.register(
            ChatRemoteHistoryQueryDescriptor(
                conversationKey: bConversationKey,
                queryId: bQueryId,
                direction: .older,
                cursorId: "conversation-b-cursor",
                generation: bGeneration
            ),
            persistenceCleanup: { bPersistenceCleanupCount += 1 }
        ) { _, _ in
            XCTFail("fresh B paging must not enter persistence in this arming proof")
        })
        controller.registerRemoteHistoryEndPageDispatcher(queryId: bQueryId)
        controller.registerRemoteHistoryFailureDispatcher(queryId: bQueryId)
        controller.scheduleInteractiveRemoteArchiveRequestStartWatchdog(
            queryId: bQueryId
        )
        XCTAssertTrue(controller.remoteHistoryQueryCoordinator.hasScheduledTimeout(
            queryId: bQueryId
        ))
        XCTAssertTrue(controller.markInteractiveRemoteArchiveRequestSent(
            queryId: bQueryId,
            direction: .older,
            cursorId: "conversation-b-cursor",
            pageSize: 100,
            streamKind: .uiAction,
            resource: "conversation-b-ui-action",
            bootstrapActive: false
        ))
        XCTAssertEqual(controller.remoteHistoryQueryCoordinator.activeQueryCount, 1)
        XCTAssertTrue(controller.interactiveHistoryPageLoadContext?.remoteFetchStarted == true)
        XCTAssertNotNil(controller.remoteHistoryRequestStartedAtByQueryId[bQueryId])
        XCTAssertTrue(MessageArchiveEndPageDispatcher.hasHandler(
            owner: controller.owner,
            queryId: bQueryId
        ))
        XCTAssertTrue(MessageArchiveRequestFailureDispatcher.hasHandler(
            owner: controller.owner,
            queryId: bQueryId
        ))

        controller.clearRemoteHistoryEndPageDispatchers()
        controller.interactiveHistoryPageLoadContext = nil
        XCTAssertEqual(bPersistenceCleanupCount, 1)
    }

    func testConversationOwnerReplacementPublishesOnlyFreshOwnerSkeleton() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let oldSession = try XCTUnwrap(controller.timelineSession)
        let oldRows = installCommittedConversationARows(in: controller)
        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )
        let replacementOwner = "conversation-b-owner@example.com"

        controller.owner = replacementOwner
        controller.ownerSender = Sender(id: replacementOwner, displayName: "Owner B")
        controller.configureDataset()

        assertConversationReplacementFrames(
            recorder.frames,
            expectedOwner: replacementOwner,
            expectedJid: controller.jid,
            expectedConversationType: .regular,
            forbiddenPrimaries: Set(oldRows.map(\.primary))
        )
        XCTAssertFalse(try XCTUnwrap(controller.timelineSession) === oldSession)
        XCTAssertTrue(controller.hasCommittedExactBootstrapSkeletonRows)
    }

    func testConversationTypeReplacementPublishesOnlyFreshTypeSkeleton() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let oldSession = try XCTUnwrap(controller.timelineSession)
        let oldRows = installCommittedConversationARows(in: controller)
        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )

        controller.conversationType = .group
        controller.configureDataset()

        assertConversationReplacementFrames(
            recorder.frames,
            expectedOwner: controller.owner,
            expectedJid: controller.jid,
            expectedConversationType: .group,
            forbiddenPrimaries: Set(oldRows.map(\.primary))
        )
        XCTAssertFalse(try XCTUnwrap(controller.timelineSession) === oldSession)
        XCTAssertTrue(try XCTUnwrap(controller.timelineSession).isConfigured(
            for: ChatTimelineConversationKey(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group
            )
        ))
        XCTAssertTrue(controller.hasCommittedExactBootstrapSkeletonRows)
    }

    func testUnchangedConversationConfigurePreservesDirectContentWithoutVisualTransaction() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let session = try XCTUnwrap(controller.timelineSession)
        let rows = installCommittedConversationARows(in: controller)
        let anchor = ChatRetainedMessageAnchor(
            primary: rows[1].primary,
            archivedId: rows[1].archivedId,
            displayRevision: "stable-direct-content",
            viewportRelativeMinY: 180
        )
        controller.retainedMessageAnchor = anchor
        let datasetGeneration = controller.datasetMappingGeneration
        let skeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let residentGeneration = controller.scrollResidentMetadata.generation
        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )

        controller.configureDataset()

        XCTAssertTrue(controller.timelineSession === session)
        XCTAssertEqual(controller.datasource.map(\.primary), rows.map(\.primary))
        XCTAssertEqual(controller.retainedMessageAnchor, anchor)
        XCTAssertEqual(controller.datasetMappingGeneration, datasetGeneration)
        XCTAssertEqual(controller.bootstrapSkeletonMappingGeneration, skeletonGeneration)
        XCTAssertEqual(controller.scrollResidentMetadata.generation, residentGeneration)
        XCTAssertTrue(recorder.frames.isEmpty)
        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
    }

    func testRepeatedConfigureDatasetPreservesResidentWindowAnchorAndPerformsZeroReloads() throws {
        let harness = makeConversationReplacementHarness()
        let controller = harness.controller
        let session = try XCTUnwrap(controller.timelineSession)
        let rows = installCommittedConversationARows(in: controller)
        controller.syncCurrentPage(
            with: ChatDatasetWindow(minIndex: 0, maxIndex: rows.count)
        )
        let anchor = ChatRetainedMessageAnchor(
            primary: rows[1].primary,
            archivedId: rows[1].archivedId,
            displayRevision: "stable-repeated-configure",
            viewportRelativeMinY: 180
        )
        controller.retainedMessageAnchor = anchor
        controller.previousContentOffsetY = 73
        harness.collectionView.setContentOffset(
            CGPoint(x: 0, y: 61),
            animated: false
        )

        let residentWindow = controller.residentDatasetWindow
        let retainedOffset = harness.collectionView.contentOffset
        let previousContentOffsetY = controller.previousContentOffsetY
        let datasourcePrimaries = controller.datasource.map(\.primary)
        let datasourceSnapshotPrimaries = controller.datasourceSnapshot.items.map(\.primary)
        let datasourceSnapshotArchivedIds = controller.datasourceSnapshot.items.map(\.archivedId)
        let datasourceSnapshotPrimaryIndex = controller.datasourceSnapshot.primaryIndex
        let datasourceSnapshotArchivedIdIndex = controller.datasourceSnapshot.archivedIdIndex
        let datasourceSnapshotHasDuplicateKeys = controller.datasourceSnapshot.hasDuplicateKeys
        let scrollResidentMetadata = controller.scrollResidentMetadata
        let datasetGeneration = controller.datasetMappingGeneration
        let skeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        let layoutGeneration = controller.layoutPreparationGeneration
        let timelineSnapshot = session.snapshot
        let timelineSnapshotItemIdentities = timelineSnapshot.items.map(ObjectIdentifier.init)
        XCTAssertFalse(residentWindow.isEmpty)
        XCTAssertEqual(residentWindow.count, rows.count)
        XCTAssertEqual(datasourcePrimaries, rows.map(\.primary))
        XCTAssertEqual(datasourceSnapshotPrimaries, rows.map(\.primary))
        XCTAssertEqual(datasourceSnapshotPrimaries.first, rows.first?.primary)
        XCTAssertEqual(datasourceSnapshotPrimaries.last, rows.last?.primary)
        let recorder = installConversationReplacementRecorder(
            controller: controller,
            collectionView: harness.collectionView
        )
        controller.scrollFrameOperationCounter.setEnabled(true)
        controller.scrollFrameOperationCounter.reset()

        for invocation in 1...2 {
            controller.configureDataset()

            XCTAssertTrue(
                controller.timelineSession === session,
                "same-conversation configure #\(invocation) must retain the exact TimelineSession"
            )
            XCTAssertEqual(controller.residentDatasetWindow, residentWindow)
            XCTAssertEqual(controller.residentDatasetWindow.minIndex, 0)
            XCTAssertEqual(controller.residentDatasetWindow.maxIndex, rows.count)
            XCTAssertEqual(controller.datasource.map(\.primary), datasourcePrimaries)
            XCTAssertEqual(
                controller.datasourceSnapshot.items.map(\.primary),
                datasourceSnapshotPrimaries
            )
            XCTAssertEqual(
                controller.datasourceSnapshot.items.map(\.archivedId),
                datasourceSnapshotArchivedIds
            )
            XCTAssertEqual(
                controller.datasourceSnapshot.primaryIndex,
                datasourceSnapshotPrimaryIndex
            )
            XCTAssertEqual(
                controller.datasourceSnapshot.archivedIdIndex,
                datasourceSnapshotArchivedIdIndex
            )
            XCTAssertEqual(
                controller.datasourceSnapshot.hasDuplicateKeys,
                datasourceSnapshotHasDuplicateKeys
            )
            XCTAssertEqual(controller.retainedMessageAnchor, anchor)
            XCTAssertEqual(harness.collectionView.contentOffset, retainedOffset)
            XCTAssertEqual(controller.previousContentOffsetY, previousContentOffsetY)
            XCTAssertEqual(controller.scrollResidentMetadata, scrollResidentMetadata)
            XCTAssertEqual(controller.datasetMappingGeneration, datasetGeneration)
            XCTAssertEqual(
                controller.bootstrapSkeletonMappingGeneration,
                skeletonGeneration
            )
            XCTAssertEqual(controller.layoutPreparationGeneration, layoutGeneration)
            XCTAssertEqual(session.snapshot.generation, timelineSnapshot.generation)
            XCTAssertEqual(session.snapshot.cause, timelineSnapshot.cause)
            XCTAssertEqual(session.snapshot.state, timelineSnapshot.state)
            XCTAssertEqual(session.snapshot.oldest, timelineSnapshot.oldest)
            XCTAssertEqual(session.snapshot.newest, timelineSnapshot.newest)
            XCTAssertEqual(
                session.snapshot.residentIndex.primaryIndexByID,
                timelineSnapshot.residentIndex.primaryIndexByID
            )
            XCTAssertEqual(
                session.snapshot.items.map(ObjectIdentifier.init),
                timelineSnapshotItemIdentities,
                "same-conversation configure #\(invocation) must not replace snapshot item identities"
            )
            XCTAssertTrue(
                recorder.frames.isEmpty,
                "same-conversation configure #\(invocation) must publish no datasource, reload, layout, or offset frame"
            )
        }

        let operations = controller.scrollFrameOperationCounter.snapshot()
        ChatRenderOperation.allCases.forEach { operation in
            XCTAssertEqual(
                operations[operation],
                0,
                "repeated same-conversation configure must not perform \(operation.rawValue)"
            )
        }
        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
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

    private func makeColdReadyController(
        suffix: String,
        applicationState: UIApplication.State
    ) throws -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "cold-owner-\(suffix)@example.com"
        controller.jid = "cold-peer-\(suffix)@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.initialFramePresentationApplicationStateProvider = {
            applicationState
        }
        try seedConversation(
            controller,
            isSynced: true,
            isInitialArchiveLoaded: true
        )
        try insertPersistedMessages(
            owner: controller.owner,
            jid: controller.jid,
            queryId: "cold-local-\(suffix)",
            count: 8
        )
        return controller
    }

    private func seedConversation(
        _ controller: ChatViewController,
        isSynced: Bool,
        isInitialArchiveLoaded: Bool,
        syncUnreadCount: Int = 1,
        snapshotArchiveId: String = "remote-500"
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType
        )
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = controller.conversationType
        chat.isSynced = isSynced
        chat.isInitialArchiveLoaded = isInitialArchiveLoaded
        chat.syncSnapshotLastArchiveId = snapshotArchiveId
        chat.syncUnreadAfterId = syncUnreadCount > 0 ? "remote-499" : nil
        chat.syncUnreadCount = syncUnreadCount
        try realm.write {
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = snapshotArchiveId
            archiveState.newerLiveEdgeReached = false
        }
    }

    private func insertPersistedMessages(
        owner: String,
        jid: String,
        queryId: String,
        count: Int
    ) throws {
        let realm = try WRealm.safe()
        try realm.write {
            for index in 0..<count {
                let primary = "\(queryId)-message-\(index)"
                let message = MessageStorageItem()
                message.primary = primary
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.messageId = primary
                message.archivedId = "archive-\(index)"
                message.body = "Persisted lifecycle row \(index)"
                message.legacyBody = message.body
                message.date = Date(
                    timeIntervalSince1970: 1_700_000_000 + Double(index)
                )
                message.sentDate = message.date
                message.displayAs = .text
                message.state = .deliver
                message.queryIds = queryId
                realm.add(message, update: .modified)
            }
            if let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ) {
                chat.isSynced = true
                chat.isInitialArchiveLoaded = true
                chat.syncUnreadCount = 0
                chat.syncUnreadAfterId = nil
            }
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            archiveState.newerLiveEdgeReached = true
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
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

    private func fullyVisibleReadPresentationSnapshot()
        -> ChatReadVisiblePresentationSnapshot {
        ChatReadVisiblePresentationSnapshot(
            isApplicationActive: true,
            isWindowAttached: true,
            isWindowSceneForegroundActive: true,
            isKeyWindow: true,
            isTopNavigationDestination: true,
            isVisibleSplitSecondary: false,
            hasCoveringPresentation: false,
            isTransitionActive: false
        )
    }

    private func makeTraceAnchorRequest(
        controller: ChatViewController,
        archivedId: String,
        source: ChatOpenMessageRequestSource = .pushNotification,
        highlight: Bool = false,
        markReadOnVisible: Bool = false
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: nil,
                authorId: controller.jid,
                bodyFingerprint: nil,
                sourceDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            highlight: highlight,
            markReadOnVisible: markReadOnVisible,
            source: source
        )
    }

    private func makeTransientHighlightHarness(
        suffix: String
    ) throws -> ChatTransientHighlightHarness {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()
        let primary = "p14-highlight-\(suffix)"
        let row = makeDatasource(
            primary: primary,
            owner: controller.owner,
            jid: controller.jid
        )
        controller.datasource = [row]
        controller.datasourceSnapshot = ChatDatasourceSnapshot(items: [row])
        let cell = MessageContentCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 80)
        )
        controller.transientMessageHighlightCellProviderForTests = { _ in
            cell
        }
        controller.defersTransientMessageHighlightAnimationForTests = true
        let requestA = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-highlight-a-\(suffix)",
            highlight: true
        )
        let requestB = makeTraceAnchorRequest(
            controller: controller,
            archivedId: "p14-highlight-b-\(suffix)",
            highlight: true
        )
        let descriptorA = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: requestA,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let descriptorB = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: requestB,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let session = try XCTUnwrap(controller.timelineSession)
        let tokenA = ChatInitialFrameEffectToken(
            presentationGeneration: 201,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptorA,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-highlight-a-token-\(suffix)"
            )
        )
        let tokenB = ChatInitialFrameEffectToken(
            presentationGeneration: 202,
            sessionIdentifier: ObjectIdentifier(session),
            descriptor: descriptorB,
            anchorTransactionToken: ChatAnchorTransactionToken(
                rawValue: "p14-highlight-b-token-\(suffix)"
            )
        )
        controller.initialLocalFirstFramePresentationGeneration =
            tokenA.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenA
        controller.initialLocalFirstFramePhase = .committed(descriptorA)
        return ChatTransientHighlightHarness(
            controller: controller,
            cell: cell,
            primary: primary,
            tokenA: tokenA,
            tokenB: tokenB
        )
    }

    private func makeConversationReplacementHarness() -> (
        controller: ChatViewController,
        collectionView: ChatConversationReplacementRecordingCollectionView
    ) {
        let controller = makeController()
        let collectionView = ChatConversationReplacementRecordingCollectionView()
        controller.messagesCollectionView = collectionView
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        collectionView.frame = controller.view.bounds
        controller.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        return (controller, collectionView)
    }

    @discardableResult
    private func installCommittedConversationARows(
        in controller: ChatViewController
    ) -> [ChatViewController.Datasource] {
        let rows = (0..<3).map { index in
            makeDatasource(
                primary: "conversation-a-message-\(index)",
                owner: controller.owner,
                jid: controller.jid
            )
        }
        controller.showSkeletonObserver.accept(false)
        controller.appliedBootstrapLoadingState = .content
        controller.applyChatDatasource(
            rows,
            mode: .fullReload(),
            animated: false,
            suppressDefaultBottomScroll: true
        )
        controller.residentDatasetWindow = ChatDatasetWindow(
            minIndex: 0,
            maxIndex: rows.count
        )
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertTrue(controller.hasCommittedRealContentInCurrentLifecycle)
        return rows
    }

    private func installConversationReplacementRecorder(
        controller: ChatViewController,
        collectionView: ChatConversationReplacementRecordingCollectionView
    ) -> ChatConversationReplacementFrameRecorder {
        let recorder = ChatConversationReplacementFrameRecorder()
        let capture: (ChatConversationReplacementBoundary, [ChatViewController.Datasource]) -> Void = {
            [weak controller] boundary, rows in
            guard let controller else { return }
            recorder.append(
                boundary: boundary,
                controller: controller,
                rows: rows
            )
        }
        controller.datasourceDidSetForTests = { rows in
            capture(.datasourceDidSet, rows)
        }
        collectionView.onBoundary = { [weak controller] boundary in
            guard let controller else { return }
            capture(boundary, controller.datasource)
        }
        return recorder
    }

    private func assertConversationReplacementFrames(
        _ frames: [ChatConversationReplacementFrame],
        expectedOwner: String,
        expectedJid: String,
        expectedConversationType: ClientSynchronizationManager.ConversationType,
        forbiddenPrimaries: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(frames.isEmpty, file: file, line: line)
        XCTAssertTrue(
            frames.contains { $0.boundary == .datasourceDidSet },
            "replacement must publish one logical B datasource",
            file: file,
            line: line
        )
        XCTAssertTrue(
            frames.contains { $0.boundary == .reload },
            "replacement must install B at a real collection boundary",
            file: file,
            line: line
        )
        frames.forEach { frame in
            XCTAssertEqual(frame.controllerOwner, expectedOwner, file: file, line: line)
            XCTAssertEqual(frame.controllerJid, expectedJid, file: file, line: line)
            XCTAssertEqual(
                frame.conversationType,
                expectedConversationType,
                file: file,
                line: line
            )
            XCTAssertFalse(
                frame.primaries.isEmpty,
                "conversation replacement may not publish a blank intermediate frame",
                file: file,
                line: line
            )
            XCTAssertTrue(
                forbiddenPrimaries.isDisjoint(with: frame.primaries),
                "a frame for B still contains a row from A",
                file: file,
                line: line
            )
            XCTAssertEqual(Set(frame.rowOwners), [expectedOwner], file: file, line: line)
            XCTAssertEqual(Set(frame.rowJids), [expectedJid], file: file, line: line)
            XCTAssertEqual(frame.primaries.count, 30, file: file, line: line)
            XCTAssertTrue(frame.fakeFlags.allSatisfy { $0 }, file: file, line: line)
        }
        let datasourceFrame = frames.first { $0.boundary == .datasourceDidSet }
        let reloadFrame = frames.first { $0.boundary == .reload }
        XCTAssertNotNil(datasourceFrame?.presentationTransactionToken, file: file, line: line)
        XCTAssertEqual(
            reloadFrame?.presentationTransactionToken,
            datasourceFrame?.presentationTransactionToken,
            "logical replacement and visible reload must share one transaction",
            file: file,
            line: line
        )
        XCTAssertEqual(datasourceFrame?.actionsDisabled, true, file: file, line: line)
        XCTAssertEqual(reloadFrame?.actionsDisabled, true, file: file, line: line)
    }

    private func messageText(_ item: ChatViewController.Datasource) -> String? {
        guard case .skeleton(let text) = item.kind else { return nil }
        return text.string
    }

    private func makeDatasource(
        primary: String,
        owner: String = "skeleton-owner@example.com",
        jid: String = "skeleton-peer@example.com",
        isFakeMessage: Bool = false
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: "Peer"),
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

private enum ChatConversationReplacementBoundary: Equatable {
    case datasourceDidSet
    case reload
    case layout
    case offset
}

private struct ChatConversationReplacementFrame: Equatable {
    let boundary: ChatConversationReplacementBoundary
    let controllerOwner: String
    let controllerJid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let primaries: Set<String>
    let rowOwners: [String]
    let rowJids: [String]
    let fakeFlags: [Bool]
    let presentationTransactionToken: String?
    let actionsDisabled: Bool
}

private final class ChatConversationReplacementFrameRecorder {
    private(set) var frames: [ChatConversationReplacementFrame] = []

    func append(
        boundary: ChatConversationReplacementBoundary,
        controller: ChatViewController,
        rows: [ChatViewController.Datasource]
    ) {
        frames.append(ChatConversationReplacementFrame(
            boundary: boundary,
            controllerOwner: controller.owner,
            controllerJid: controller.jid,
            conversationType: controller.conversationType,
            primaries: Set(rows.map(\.primary)),
            rowOwners: rows.map(\.owner),
            rowJids: rows.map(\.jid),
            fakeFlags: rows.map(\.isFakeMessage),
            presentationTransactionToken:
                ChatDatasourcePresentationTransactionContext.currentToken,
            actionsDisabled: CATransaction.disableActions()
        ))
    }
}

private final class ChatConversationReplacementRecordingCollectionView:
    MessagesCollectionView {
    var onBoundary: ((ChatConversationReplacementBoundary) -> Void)?

    override func reloadData() {
        super.reloadData()
        onBoundary?(.reload)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onBoundary?(.layout)
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(contentOffset, animated: animated)
        onBoundary?(.offset)
    }
}

@MainActor
final class ChatBootstrapConnectivityLifecycleTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatBootstrapConnectivityLifecycleTests-\(name)-\(UUID().uuidString)"
        )
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        XMPPUIActionManager.shared.resetPendingAuthenticationForTests()
    }

    override func tearDown() {
        XMPPUIActionManager.shared.resetPendingAuthenticationForTests()
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testDurableSameBoundaryCommitOverridesStaleUnsyncedPreparedFrameForFollowUpAdmission() {
        let boundary = MessageArchiveManager.ConversationArchiveBoundaryFingerprint(
            chatExists: true,
            archiveStateExists: true,
            chatSnapshotArchiveId: "500",
            archiveSnapshotArchiveId: "500",
            archiveSnapshotMessageId: nil,
            unreadAfterId: nil,
            unreadCount: 0
        )
        let committedReadiness = ConversationArchiveReadiness(
            phase: .committed,
            hasDurableCoverage: true,
            confirmsEmptyConversation: false,
            persistedVisibleRowCount: 1,
            boundaryFingerprint: boundary
        )

        XCTAssertFalse(
            ChatInitialBootstrapBoundaryFollowUpPolicy.requiresFollowUp(
                readiness: committedReadiness,
                committedBoundaryMatchesCurrent: true,
                currentSnapshotRequiresFollowUp: true
            ),
            "a pre-commit frame may remain unsynced, but it cannot override the same-boundary query-scoped commit"
        )
        XCTAssertTrue(
            ChatInitialBootstrapBoundaryFollowUpPolicy.requiresFollowUp(
                readiness: committedReadiness,
                committedBoundaryMatchesCurrent: false,
                currentSnapshotRequiresFollowUp: false
            ),
            "a newer remote boundary must still supersede the retained commit"
        )
        XCTAssertTrue(
            ChatInitialBootstrapBoundaryFollowUpPolicy.requiresFollowUp(
                readiness: ConversationArchiveReadiness(
                    phase: .committed,
                    hasDurableCoverage: false,
                    confirmsEmptyConversation: false,
                    persistedVisibleRowCount: 1,
                    boundaryFingerprint: boundary
                ),
                committedBoundaryMatchesCurrent: true,
                currentSnapshotRequiresFollowUp: false
            ),
            "a committed target page without durable coverage still requires its explicit repair"
        )
    }

    func testSameTargetJoinWithoutAcceptedPerformanceTraceCannotManufactureFollowUp() {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = ChatInitialBootstrapRequestKey(
            owner: "no-trace-join-owner@example.com",
            jid: "no-trace-join-peer@example.com",
            conversationType: .regular
        )
        let target = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "no-trace-original",
            timeout: 45,
            targetFingerprint: target,
            performanceTraceContext: nil,
            performanceSemanticTargetFingerprint: .latest,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the original no-trace request must own the lease")
        }
        XCTAssertNil(lease.performanceTraceContext)
        XCTAssertNil(
            lease.performanceSemanticTargetFingerprint,
            "semantic identity is retained only with an accepted opaque trace"
        )

        for index in 0..<3 {
            guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
                key: key,
                proposedQueryId: "no-trace-repeat-\(index)",
                timeout: 45,
                targetFingerprint: target,
                performanceTraceContext: nil,
                performanceSemanticTargetFingerprint: .latest,
                observer: { _, _, _ in }
            ) else {
                return XCTFail("same-target no-trace opens must join")
            }
            XCTAssertEqual(joinedLease.queryId, lease.queryId)
            XCTAssertNil(
                coordinator.pendingFollowUpRequest(for: key),
                "an untracked semantic value cannot supersede the same transport target"
            )
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            resultCount: 1,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: true,
            recommendedFollowUpTarget: nil
        )
        XCTAssertTrue(coordinator.readiness(for: key)?.hasDurableCoverage == true)
        XCTAssertNil(coordinator.pendingFollowUpRequest(for: key))
    }

    func testOfflineQueuedBootstrapUsesProductionReconnectDispatcherAndSendsSameLeaseExactlyOnce() throws {
        let controller = try makeBlockingController(
            suffix: "production-offline",
            syncUnreadCount: 0,
            snapshotArchiveId: "500"
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let conversationType = controller.conversationType
        let committedPageProbe = ChatOfflineReconnectCommittedPageProbe()
        let committedPageObservation = coordinator.observe(key: key) { readiness in
            guard let readiness,
                  readiness.phase == .committed,
                  let lease = coordinator.committedLease(for: key),
                  let page = coordinator.cachedCommittedPage(
                    key: key,
                    queryId: lease.queryId
                  ) else {
                return
            }
            committedPageProbe.record(
                queryId: lease.queryId,
                readiness: readiness,
                page: page,
                owner: key.owner,
                jid: key.jid,
                conversationType: conversationType,
                hasPendingFollowUp: coordinator.pendingFollowUpRequest(for: key) != nil
            )
            if let observation = committedPageProbe.takeObservation() {
                coordinator.detach(key: key, observation: observation)
            }
        }
        committedPageProbe.installObservation(committedPageObservation)
        defer {
            if let observation = committedPageProbe.takeObservation() {
                coordinator.detach(key: key, observation: observation)
            }
        }

        let stream = ChatOfflineReconnectCapturingStream()
        let archiveManager = MessageArchiveManager(withOwner: controller.owner)
        let messageManager = makeNonRetainingMessageManager(owner: controller.owner)
        messageManager.archiveQueryIdPersistenceResolver = { [weak archiveManager] queryId in
            archiveManager?.shouldPersistArchiveQueryId(queryId) ?? false
        }
        let actionManager = XMPPUIActionManager.shared
        actionManager.preparePendingAuthenticationForTests(
            owner: controller.owner,
            stream: stream,
            archiveManager: archiveManager,
            messageManager: messageManager
        )

        controller.scrollFrameOperationCounter.setEnabled(true)
        controller.scrollFrameOperationCounter.reset()
        controller.requestInitialBootstrapArchive()

        XCTAssertTrue(waitUntil {
            controller.initialBootstrapQueryId != nil &&
                actionManager.pendingPerformRequestCountForTests(
                    owner: controller.owner
                ) == 1
        }, "production performRequest must enqueue one pending-auth archive action")
        let queryId = try XCTUnwrap(controller.initialBootstrapQueryId)
        XCTAssertNil(controller.chatOpenPerformanceTraceContext)
        XCTAssertNil(controller.initialBootstrapPerformanceSemanticTargetFingerprint)
        XCTAssertEqual(
            controller.chatOpenPerformanceSemanticTargetFingerprint(for: nil),
            .latest
        )
        XCTAssertNil(coordinator.pendingFollowUpRequest(for: key))
        XCTAssertEqual(controller.initialBootstrapTargetFingerprint?.target, .latest)
        XCTAssertEqual(
            ChatInitialBootstrapRequestCoordinator.shared.readiness(for: key)?.phase,
            .queued
        )
        XCTAssertEqual(stream.mamSends.count, 0)

        controller.initialBootstrapPresentationDeadline = Date().addingTimeInterval(0.02)
        controller.scheduleInitialBootstrapTimeout(queryId: queryId, timeout: 0.02)
        let queuedSkeleton = captureProductionOfflineSnapshot(controller)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        XCTAssertNil(
            controller.initialBootstrapPresentationDeadline,
            "the shortened presentation watchdog must run without terminating the lease"
        )

        for _ in 0..<3 {
            controller.requestInitialBootstrapArchive()
            XCTAssertNil(
                coordinator.pendingFollowUpRequest(for: key),
                "a repeated offline join must not preinstall a same-target follow-up"
            )
        }
        XCTAssertTrue(waitUntil {
            actionManager.pendingPerformRequestCountForTests(
                owner: controller.owner
            ) == 1
        })
        XCTAssertEqual(
            captureProductionOfflineSnapshot(controller),
            queuedSkeleton,
            "watchdog and repeated offline opens must preserve the exact committed skeleton"
        )
        var diagnostics = ChatInitialBootstrapRequestCoordinator.shared
            .productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.leaseJoinCount, 3)
        XCTAssertEqual(diagnostics.activeLeaseCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 0)
        XCTAssertEqual(stream.mamSends.count, 0)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.offsetMutations], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.layoutFlushes], 0)

        let firstReconnectGeneration =
            actionManager.dispatchAuthenticatedReconnectForTests(
                owner: controller.owner
            )

        XCTAssertTrue(waitUntil {
            actionManager.authenticatedReconnectDispatchReceiptForTests(
                owner: controller.owner
            )?.generation == firstReconnectGeneration &&
                stream.mamSends.count == 1
        }, "one authenticated reconnect action must fully return after one production send")
        let firstReconnectReceipt = try XCTUnwrap(
            actionManager.authenticatedReconnectDispatchReceiptForTests(
                owner: controller.owner
            )
        )
        XCTAssertEqual(firstReconnectReceipt.resumedRequestCount, 1)
        XCTAssertEqual(
            actionManager.pendingPerformRequestCountForTests(
                owner: controller.owner
            ),
            0
        )
        let onlySend = try XCTUnwrap(stream.mamSends.first)
        XCTAssertEqual(onlySend.elementId, queryId)
        XCTAssertEqual(onlySend.queryId, queryId)
        XCTAssertEqual(onlySend.maximum, 80)
        XCTAssertNotNil(onlySend.before, "latest bootstrap must use the newest-page RSM shape")
        XCTAssertNil(onlySend.after)
        XCTAssertFalse(onlySend.wasMainThread)
        XCTAssertEqual(
            controller.initialBootstrapTargetFingerprint?.target,
            .latest
        )
        XCTAssertEqual(controller.initialBootstrapQueryId, queryId)
        XCTAssertEqual(
            ChatInitialBootstrapRequestCoordinator.shared.readiness(for: key)?.phase,
            .transport
        )
        XCTAssertTrue(
            archiveManager.shouldPersistArchiveQueryId(queryId),
            "the returned action must leave its query persistence route active"
        )
        diagnostics = ChatInitialBootstrapRequestCoordinator.shared
            .productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertEqual(diagnostics.activeLeaseCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 1)
        XCTAssertNil(
            coordinator.pendingFollowUpRequest(for: key),
            "returning the original production action must retain one target generation"
        )
        XCTAssertEqual(
            captureProductionOfflineSnapshot(controller),
            queuedSkeleton,
            "transport start must retain the same skeleton/query/target presentation"
        )

        let duplicateReconnectGeneration =
            actionManager.dispatchAuthenticatedReconnectForTests(
                owner: controller.owner
            )
        XCTAssertTrue(waitUntil {
            actionManager.authenticatedReconnectDispatchReceiptForTests(
                owner: controller.owner
            )?.generation == duplicateReconnectGeneration
        })
        XCTAssertEqual(
            actionManager.authenticatedReconnectDispatchReceiptForTests(
                owner: controller.owner
            )?.resumedRequestCount,
            0
        )
        XCTAssertEqual(stream.mamSends.count, 1, "duplicate reconnect has no queued action")

        let archivedMessage = try makeProductionOfflineArchivedMessage(
            owner: controller.owner,
            jid: controller.jid,
            queryId: queryId
        )
        let final = try makeProductionOfflineFinalIQ(queryId: queryId)
        let deliveryProbe = ChatOfflineReconnectDeliveryProbe()
        let allowMessageIngress = DispatchSemaphore(value: 0)
        DispatchQueue(
            label: "ChatBootstrapConnectivityLifecycleTests.archive-delivery"
        ).async {
            let recorded = archiveManager.recordDeferredArchiveResultDelivery(
                archivedMessage
            )
            let acceptedFinal = archiveManager.read(stream, withIQ: final)
            let acceptedDuplicateFinal = archiveManager.read(stream, withIQ: final)
            deliveryProbe.recordRawTerminal(
                recordedEnvelope: recorded,
                acceptedFinal: acceptedFinal,
                acceptedDuplicateFinal: acceptedDuplicateFinal,
                wasMainThread: Thread.isMainThread
            )
            allowMessageIngress.wait()
            messageManager.receiveArchived(archivedMessage)
            deliveryProbe.finishMessageIngress()
        }
        XCTAssertTrue(waitUntil { deliveryProbe.snapshot.didFinishRawTerminal })
        XCTAssertTrue(deliveryProbe.snapshot.recordedEnvelope)
        XCTAssertTrue(deliveryProbe.snapshot.acceptedFinal)
        XCTAssertFalse(
            deliveryProbe.snapshot.acceptedDuplicateFinal,
            "the real query ledger must reject a duplicate terminal before UI ingress"
        )
        XCTAssertFalse(deliveryProbe.snapshot.wasMainThread)
        XCTAssertEqual(archiveManager.expectedPersistenceResultCount(queryId: queryId), 1)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .persistence)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: queryId))
        XCTAssertTrue(archiveManager.shouldPersistArchiveQueryId(queryId))
        XCTAssertNil(
            coordinator.pendingFollowUpRequest(for: key),
            "raw final must not add a target before its retained ingress arrives"
        )
        XCTAssertEqual(
            actionManager.pendingPerformRequestCountForTests(owner: controller.owner),
            0,
            "raw final ownership must park on late ingress without queuing a second transport"
        )

        allowMessageIngress.signal()
        XCTAssertTrue(waitUntil { deliveryProbe.snapshot.isFinished })

        XCTAssertTrue(waitUntil { committedPageProbe.snapshot.didCommit })
        let committedPage = committedPageProbe.snapshot
        XCTAssertEqual(committedPage.queryId, queryId)
        XCTAssertEqual(committedPage.persistedRows, 1)
        XCTAssertEqual(committedPage.visibleRows, 1)
        XCTAssertEqual(committedPage.persistedVisibleRowCount, 1)
        XCTAssertTrue(committedPage.hasDurableCoverage)
        XCTAssertTrue(committedPage.hasPresentationMaterialization)
        XCTAssertNil(committedPage.recommendedFollowUpTarget)
        XCTAssertFalse(
            committedPage.hasPendingFollowUp,
            "a persisted visible newest page for the same boundary must not manufacture a second bootstrap target"
        )
        let realm = try WRealm.safe()
        let committedChat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: controller.conversationType
            )
        ))
        let committedArchiveState = try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: controller.conversationType
            )
        ))
        XCTAssertTrue(committedChat.isSynced)
        XCTAssertTrue(committedChat.isInitialArchiveLoaded)
        XCTAssertTrue(committedArchiveState.newerLiveEdgeReached)
        XCTAssertTrue(committedArchiveState.containsArchiveId("500"))

        XCTAssertTrue(waitUntil(timeout: 5) {
            controller.initialFirstContentApplyCount == 1 &&
                controller.datasource.contains {
                    !$0.isFakeMessage &&
                        $0.messageId == "offline-reconnect-message-500"
                } &&
                !controller.showSkeletonObserver.value &&
                !controller.isInitialBootstrapInFlight
        }, "real MAM ingress/final/persistence must publish one atomic content frame")
        let firstReceiptCount = controller.initialFirstContentApplyCount
        let firstApplyCount = controller.scrollFrameOperationCounter
            .snapshot()[.datasourceApplies]
        XCTAssertEqual(firstReceiptCount, 1)
        XCTAssertEqual(firstApplyCount, 1)

        _ = archiveManager.read(stream, withIQ: final)
        let terminalDuplicateReconnectGeneration =
            actionManager.dispatchAuthenticatedReconnectForTests(
                owner: controller.owner
            )
        XCTAssertTrue(waitUntil {
            actionManager.authenticatedReconnectDispatchReceiptForTests(
                owner: controller.owner
            )?.generation == terminalDuplicateReconnectGeneration
        })
        XCTAssertEqual(
            actionManager.authenticatedReconnectDispatchReceiptForTests(
                owner: controller.owner
            )?.resumedRequestCount,
            0
        )

        XCTAssertEqual(stream.mamSends.count, 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, firstReceiptCount)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            firstApplyCount
        )
        diagnostics = ChatInitialBootstrapRequestCoordinator.shared
            .productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 1)
        XCTAssertEqual(diagnostics.completedLeaseCount, 1)
    }

    func testAuthenticatedReconnectTestSeamUsesSameProductionPendingDispatcherAsRealAuthCallback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/common/XMPPUIActionManager/XMPPUIActionManager.swift"
            ),
            encoding: .utf8
        )
        let delegateSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/common/XMPPUIActionManager/XMPPUIActionManager+Delegate.swift"
            ),
            encoding: .utf8
        )
        let authStart = try XCTUnwrap(
            delegateSource.range(of: "func xmppStreamDidAuthenticate(_ sender: XMPPStream)")
        )
        let authEnd = try XCTUnwrap(
            delegateSource.range(
                of: "func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement)",
                range: authStart.upperBound..<delegateSource.endIndex
            )
        )
        let harnessStart = try XCTUnwrap(
            managerSource.range(of: "final func dispatchAuthenticatedReconnectForTests(owner: String)")
        )
        let harnessEnd = try XCTUnwrap(
            managerSource.range(
                of: "final func pendingPerformRequestCountForTests(owner: String? = nil)",
                range: harnessStart.upperBound..<managerSource.endIndex
            )
        )
        let authCallback = String(delegateSource[authStart.lowerBound..<authEnd.lowerBound])
        let deterministicHarness = String(
            managerSource[harnessStart.lowerBound..<harnessEnd.lowerBound]
        )

        XCTAssertEqual(
            authCallback.components(
                separatedBy: "self.resumePendingPerformRequests(owner: jid)"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            deterministicHarness.components(
                separatedBy: "self.resumePendingPerformRequests(owner: owner)"
            ).count - 1,
            1
        )
    }

    func testOfflineQueuedBootstrapKeepsSkeletonAndResumesSameLeaseOnReconnect() throws {
        XCTAssertEqual(
            ChatInitialBootstrapPresentationWatchdogPolicy.timeout(
                hasCommittedPage: false,
                remainingTransportTimeout: 45
            ),
            5
        )

        let controller = try makeBlockingController(suffix: "offline")
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let boundary = MessageArchiveManager.ConversationArchiveBoundaryFingerprint(
            chatExists: true,
            archiveStateExists: true,
            chatSnapshotArchiveId: "remote-500",
            archiveSnapshotArchiveId: "remote-500",
            archiveSnapshotMessageId: "remote-message-500",
            unreadAfterId: "remote-499",
            unreadCount: 1
        )
        let targetFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .firstUnread(afterArchiveId: "remote-499"),
            boundary: boundary
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "offline-single-flight",
            timeout: 45,
            targetFingerprint: targetFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("offline open must own one queued conversation lease")
        }
        controller.initialBootstrapLeaseKey = key
        controller.initialBootstrapTargetFingerprint = lease.targetFingerprint
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: 0.02)
        controller.scrollFrameOperationCounter.reset()

        let queuedSkeleton = captureBlockingSnapshot(controller, lease: lease)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        for attempt in 0..<3 {
            guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
                key: key,
                proposedQueryId: "offline-repeat-\(attempt)",
                timeout: 45,
                targetFingerprint: targetFingerprint,
                observer: { _, _, _ in }
            ) else {
                return XCTFail("repeated offline signal must join, never enqueue another lease")
            }
            XCTAssertEqual(joinedLease, lease)
        }

        assertBlockingSnapshot(
            captureBlockingSnapshot(controller, lease: lease),
            equals: queuedSkeleton,
            label: "offline watchdog and repeated connectivity events"
        )
        var diagnostics = coordinator.productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertEqual(diagnostics.activeLeaseCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.offsetMutations], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.layoutFlushes], 0)

        var lateTransportCancellationCount = 0
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { lateTransportCancellationCount += 1 }
        )
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { lateTransportCancellationCount += 1 }
        )

        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .transport)
        diagnostics = coordinator.productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 1)
        XCTAssertEqual(lateTransportCancellationCount, 0)
        assertBlockingSnapshot(
            captureBlockingSnapshot(controller, lease: lease),
            equals: queuedSkeleton,
            label: "same lease after reconnect"
        )

        try markConversationDurablyEmpty(controller)
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            boundaryFingerprint: boundary,
            resultCount: 0
        )
        XCTAssertTrue(waitUntil {
            controller.appliedBootstrapLoadingState == .empty &&
                !controller.showSkeletonObserver.value &&
                controller.datasource.isEmpty &&
                controller.initialFirstContentApplyCount == 1 &&
                !controller.isInitialBootstrapInFlight
        })

        let firstReceiptCount = controller.initialFirstContentApplyCount
        let firstApplyCount = controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies]
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            boundaryFingerprint: boundary,
            resultCount: 0
        )
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: { lateTransportCancellationCount += 1 }
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.initialFirstContentApplyCount, firstReceiptCount)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            firstApplyCount
        )
        diagnostics = coordinator.productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 1)
        XCTAssertEqual(diagnostics.completedLeaseCount, 1)
    }

    func testBackgroundForegroundPreservesLeaseSkeletonIdentityAndRequestCount() throws {
        for phase in BootstrapLifecyclePhase.allCases {
            try assertBootstrapLifecycleIsStable(in: phase)
        }

        try assertPreparedTerminalWaitsForForeground(control: .current)
        try assertPreparedTerminalWaitsForForeground(control: .replacement)
        try assertPreparedTerminalWaitsForForeground(control: .cancelled)
    }

    func testColdStackedPreparationUsesBackgroundStateBeforeObserversAndDefersPreparedFrame() throws {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        let controller = try makeColdReadyController(
            suffix: "cold-background",
            applicationState: .background
        )
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        var completionCount = 0

        XCTAssertFalse(controller.isViewLoaded)
        XCTAssertFalse(controller.chatObserversRegistered)
        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertFalse(
            controller.chatObserversRegistered,
            "stacked pre-push preparation runs before viewWillAppear/addObservers"
        )
        XCTAssertTrue(waitUntil {
            controller.pendingInitialFrameLifecyclePresentation != nil
        })
        let retainedPresentation = try XCTUnwrap(
            controller.pendingInitialFrameLifecyclePresentation
        )
        let retainedMappingToken = try XCTUnwrap(retainedPresentation.mappingToken)
        let preparedDatasetGeneration = controller.datasetMappingGeneration
        let preparedSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        XCTAssertFalse(controller.isInitialFramePresentationLifecycleEligible)
        XCTAssertNil(retainedPresentation.identity.bootstrapQueryId)
        XCTAssertEqual(retainedPresentation.identity.descriptor.target, .latest)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertEqual(
            ChatInitialBootstrapRequestCoordinator.shared
                .productionDiagnosticsSnapshot(for: controller.initialBootstrapRequestKey)
                .leaseStartCount,
            0
        )

        controller.scrollFrameOperationCounter.reset()
        controller.willEnterForeground()
        XCTAssertFalse(controller.isInitialFramePresentationLifecycleEligible)
        XCTAssertTrue(
            controller.pendingInitialFrameLifecyclePresentation ===
                retainedPresentation,
            "will-enter while UIApplication is still background must retain the exact continuation"
        )
        XCTAssertTrue(
            try XCTUnwrap(controller.initialLocalFirstFrameMappingToken) ===
                retainedMappingToken
        )
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)

        controller.initialFramePresentationApplicationStateProvider = { .active }
        controller.didBecomeActive()
        XCTAssertTrue(waitUntil {
            completionCount == 1 &&
                controller.initialFirstContentApplyCount == 1 &&
                controller.datasource.filter { !$0.isFakeMessage }.count == 8 &&
                !controller.showSkeletonObserver.value
        })
        XCTAssertNil(controller.pendingInitialFrameLifecyclePresentation)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(controller.datasetMappingGeneration, preparedDatasetGeneration)
        XCTAssertEqual(
            controller.bootstrapSkeletonMappingGeneration,
            preparedSkeletonGeneration
        )
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 1)
        XCTAssertEqual(probe.commitDiagnostics?.storeQueryCount, 2)
        XCTAssertEqual(probe.commitDiagnostics?.realDatasourceApplyCount, 1)

        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        let activeController = try makeColdReadyController(
            suffix: "cold-active-control",
            applicationState: .active
        )
        defer { activeController.performTerminalChatResourceTeardownForTesting() }
        let activeProbe = ChatLifecyclePreparationProbe()
        activeController.initialFirstFrameMappingBarrierForTests = {
            activeProbe.incrementMappingCount()
        }
        var activeCompletionCount = 0
        activeController.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            activeCompletionCount += 1
        }
        XCTAssertTrue(waitUntil {
            activeCompletionCount == 1 &&
                activeController.initialFirstContentApplyCount == 1
        })
        XCTAssertTrue(activeController.isInitialFramePresentationLifecycleEligible)
        XCTAssertNil(activeController.pendingInitialFrameLifecyclePresentation)
        XCTAssertEqual(activeProbe.mappingCount, 1)
        XCTAssertEqual(activeController.datasource.filter { !$0.isFakeMessage }.count, 8)
    }

    func testMemoryWarningWhilePreparedFrameIsBackgroundDeferredPreservesExactContinuationAndCommitsOnceOnForeground() throws {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        let controller = try makeBlockingController(suffix: "prepared-memory-pressure")
        defer { controller.performTerminalChatResourceTeardownForTesting() }
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let targetFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "prepared-memory-pressure",
            timeout: 45,
            targetFingerprint: targetFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("memory-pressure route must own one fresh bootstrap lease")
        }
        controller.initialBootstrapLeaseKey = key
        controller.initialBootstrapTargetFingerprint = lease.targetFingerprint
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )
        try insertPersistedMessages(
            owner: controller.owner,
            jid: controller.jid,
            queryId: lease.queryId,
            count: 8
        )

        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        controller.handleApplicationDidEnterBackground()
        controller.scrollFrameOperationCounter.reset()
        let skeletonBeforeTerminal = captureBlockingSnapshot(controller, lease: lease)

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            resultCount: 8,
            persistedRowsForQuery: 8,
            visibleRowsForConversation: 8
        )
        XCTAssertTrue(waitUntil {
            controller.pendingInitialFrameLifecyclePresentation != nil
        }, "trusted page must reach the real lifecycle publication gate")

        let retainedPresentation = try XCTUnwrap(
            controller.pendingInitialFrameLifecyclePresentation
        )
        let retainedIdentity = retainedPresentation.identity
        let retainedToken = try XCTUnwrap(retainedPresentation.mappingToken)
        let routeDiagnosticsBeforeMemoryPressure = try XCTUnwrap(
            controller.timelineSession
        ).routeStoreDiagnosticsSnapshot
        let skeletonWithPreparedFrame = captureBlockingSnapshot(
            controller,
            lease: lease
        )
        XCTAssertEqual(routeDiagnosticsBeforeMemoryPressure.queryCount, 1)
        XCTAssertEqual(routeDiagnosticsBeforeMemoryPressure.mainThreadQueryCount, 0)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        assertBlockingVisualState(
            skeletonWithPreparedFrame,
            equals: skeletonBeforeTerminal,
            label: "trusted terminal remains unpublished in background"
        )

        controller.handleChatMemoryPressureForTesting()

        XCTAssertTrue(
            controller.pendingInitialFrameLifecyclePresentation === retainedPresentation,
            "memory pressure must preserve the sole fully prepared continuation"
        )
        XCTAssertEqual(
            controller.pendingInitialFrameLifecyclePresentation?.identity,
            retainedIdentity
        )
        XCTAssertTrue(
            try XCTUnwrap(controller.pendingInitialFrameLifecyclePresentation?.mappingToken) ===
                retainedToken
        )
        XCTAssertTrue(
            try XCTUnwrap(controller.initialLocalFirstFrameMappingToken) === retainedToken
        )
        XCTAssertFalse(retainedToken.isCancelled)
        XCTAssertEqual(controller.initialLocalFirstFramePhase, .preparing(retainedIdentity.descriptor))
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(controller.timelineSession).routeStoreDiagnosticsSnapshot,
            routeDiagnosticsBeforeMemoryPressure
        )
        assertBlockingSnapshot(
            captureBlockingSnapshot(controller, lease: lease),
            equals: skeletonWithPreparedFrame,
            label: "memory pressure preserves exact skeleton, query, target and generations"
        )
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.offsetMutations], 0)

        controller.initialFramePresentationApplicationStateProvider = { .active }
        controller.willEnterForeground()
        controller.didBecomeActive()
        XCTAssertTrue(waitUntil {
            controller.initialFirstContentApplyCount == 1 &&
                controller.appliedBootstrapLoadingState == .content &&
                !controller.showSkeletonObserver.value &&
                controller.datasource.filter { !$0.isFakeMessage }.count == 8
        }, "foreground must publish the exact retained frame once")

        XCTAssertNil(controller.pendingInitialFrameLifecyclePresentation)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(probe.commitDiagnostics?.storeQueryCount, 2)
        XCTAssertEqual(probe.commitDiagnostics?.mainThreadStoreQueryCount, 0)
        XCTAssertEqual(probe.commitDiagnostics?.realDatasourceApplyCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(controller.timelineSession).routeStoreDiagnosticsSnapshot,
            routeDiagnosticsBeforeMemoryPressure
        )
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
        XCTAssertTrue(controller.datasource.allSatisfy { !$0.isFakeMessage })
        XCTAssertFalse(controller.appliedBootstrapLoadingState?.showsRetry ?? true)

        let committedPrimaries = controller.datasource.map(\.primary)
        controller.handleChatMemoryPressureForTesting()
        controller.willEnterForeground()
        controller.didBecomeActive()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.datasource.map(\.primary), committedPrimaries)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 1)
    }

    private func assertBootstrapLifecycleIsStable(
        in phase: BootstrapLifecyclePhase
    ) throws {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        let controller = try makeBlockingController(suffix: "phase-\(phase.rawValue)")
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let targetFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .firstUnread(afterArchiveId: "phase-boundary"),
            boundary: nil
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "lifecycle-\(phase.rawValue)",
            timeout: 45,
            targetFingerprint: targetFingerprint,
            observer: { _, _, _ in }
        ) else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("\(phase.rawValue): expected one fresh lease")
        }
        controller.initialBootstrapLeaseKey = key
        controller.initialBootstrapTargetFingerprint = lease.targetFingerprint
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: 45)

        var manager: MessageManager?
        var managerQueueIsSuspended = false
        if phase != .queued {
            let transportManager = makeNonRetainingMessageManager(owner: key.owner)
            manager = transportManager
            coordinator.resolveStart(
                key: key,
                queryId: lease.queryId,
                result: .bootstrapStarted(queryId: lease.queryId),
                messages: transportManager,
                cancelTransport: {}
            )
        }
        if phase == .persistence, let manager {
            manager.queue.suspend()
            managerQueueIsSuspended = true
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
            XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(final), phase.rawValue)
        }
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, phase.coordinatorPhase)

        controller.scrollFrameOperationCounter.reset()
        let beforeBackground = captureBlockingSnapshot(controller, lease: lease)
        let diagnosticsBefore = coordinator.productionDiagnosticsSnapshot(for: key)
        let presentationDeadlineBefore = controller.initialBootstrapPresentationDeadline
        XCTAssertNotNil(presentationDeadlineBefore, phase.rawValue)

        controller.handleApplicationDidEnterBackground()
        XCTAssertFalse(controller.isInitialFramePresentationLifecycleEligible)
        assertBlockingSnapshot(
            captureBlockingSnapshot(controller, lease: lease),
            equals: beforeBackground,
            label: "\(phase.rawValue) background"
        )
        XCTAssertEqual(
            controller.initialBootstrapPresentationDeadline,
            presentationDeadlineBefore,
            "\(phase.rawValue): background must not reset the presentation deadline"
        )
        controller.willEnterForeground()
        controller.didBecomeActive()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(controller.isInitialFramePresentationLifecycleEligible)
        assertBlockingSnapshot(
            captureBlockingSnapshot(controller, lease: lease),
            equals: beforeBackground,
            label: "\(phase.rawValue) foreground"
        )
        XCTAssertEqual(
            controller.initialBootstrapPresentationDeadline,
            presentationDeadlineBefore,
            "\(phase.rawValue): foreground must not reset the presentation deadline"
        )

        let diagnosticsAfter = coordinator.productionDiagnosticsSnapshot(for: key)
        XCTAssertEqual(diagnosticsAfter.leaseStartCount, diagnosticsBefore.leaseStartCount)
        XCTAssertEqual(diagnosticsAfter.transportStartCount, diagnosticsBefore.transportStartCount)
        XCTAssertEqual(diagnosticsAfter.activeLeaseCount, diagnosticsBefore.activeLeaseCount)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.offsetMutations], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.layoutFlushes], 0)

        if managerQueueIsSuspended {
            manager?.queue.resume()
            managerQueueIsSuspended = false
        }
        controller.performTerminalChatResourceTeardownForTesting()
        manager?.unsubscribeReceiver()
        manager?.unsubscribeSender()
    }

    private func assertPreparedTerminalWaitsForForeground(
        control: DeferredPresentationControl
    ) throws {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        let suffix = "prepared-\(control.rawValue)"
        let controller = try makeBlockingController(suffix: suffix)
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let targetFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "prepared-terminal-\(control.rawValue)",
            timeout: 45,
            targetFingerprint: targetFingerprint,
            observer: { _, _, _ in }
        ) else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("\(control.rawValue): expected one fresh lease")
        }
        controller.initialBootstrapLeaseKey = key
        controller.initialBootstrapTargetFingerprint = lease.targetFingerprint
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: nil)
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )
        try insertPersistedMessages(
            owner: controller.owner,
            jid: controller.jid,
            queryId: lease.queryId,
            count: 8
        )

        let probe = ChatLifecyclePreparationProbe()
        controller.initialFirstFrameMappingBarrierForTests = {
            probe.incrementMappingCount()
        }
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = {
            probe.recordCommit($0)
        }
        controller.handleApplicationDidEnterBackground()
        controller.scrollFrameOperationCounter.reset()
        let skeletonBeforeTerminal = captureBlockingSnapshot(controller, lease: lease)

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            resultCount: 8,
            persistedRowsForQuery: 8,
            visibleRowsForConversation: 8
        )
        XCTAssertTrue(waitUntil {
            controller.pendingInitialFrameLifecyclePresentation != nil
        }, "\(control.rawValue): mapped initial frame must stop at the lifecycle gate")
        XCTAssertEqual(controller.initialBootstrapPersistedRowsForQuery, 8)
        XCTAssertEqual(controller.initialBootstrapVisibleRowsForConversation, 8)
        XCTAssertEqual(controller.initialBootstrapResultCount, 8)
        XCTAssertTrue(controller.didReceiveInitialBootstrapEndPage)
        let committedSummary = try XCTUnwrap(
            coordinator.cachedCommittedPage(
                key: key,
                queryId: lease.queryId
            )?.completion.persistenceSummary
        )
        XCTAssertEqual(committedSummary.persistedRows, 8)
        XCTAssertEqual(
            committedSummary.visibleRows(
                owner: key.owner,
                jid: key.jid,
                conversationType: controller.conversationType
            ),
            8
        )

        let pendingIdentity = try XCTUnwrap(
            controller.pendingInitialFrameLifecyclePresentation?.identity
        )
        let retainedPresentation = try XCTUnwrap(
            controller.pendingInitialFrameLifecyclePresentation
        )
        let preparedToken = try XCTUnwrap(
            controller.initialLocalFirstFrameMappingToken
        )
        let preparedDatasetGeneration = controller.datasetMappingGeneration
        let preparedSkeletonGeneration = controller.bootstrapSkeletonMappingGeneration
        XCTAssertEqual(pendingIdentity.bootstrapQueryId, lease.queryId)
        XCTAssertEqual(pendingIdentity.targetFingerprint, targetFingerprint)
        XCTAssertEqual(pendingIdentity.datasetMappingGeneration, preparedDatasetGeneration)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        XCTAssertEqual(controller.initialBootstrapQueryId, lease.queryId)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.reloads], 0)
        assertBlockingVisualState(
            captureBlockingSnapshot(controller, lease: lease),
            equals: skeletonBeforeTerminal,
            label: "\(control.rawValue) committed receipt while backgrounded"
        )

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            resultCount: 8,
            persistedRowsForQuery: 8,
            visibleRowsForConversation: 8
        )
        if let currentPage = coordinator.cachedCommittedPage(
            key: key,
            queryId: lease.queryId
        ) {
            controller.consumeInitialBootstrapCommittedPage(currentPage)
        }
        var duplicatePreparedApplyCount = 0
        controller.retainInitialFrameLifecyclePresentationForTesting(
            identity: pendingIdentity,
            mappingToken: preparedToken
        ) {
            duplicatePreparedApplyCount += 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(
            controller.pendingInitialFrameLifecyclePresentation ===
                retainedPresentation,
            "duplicate CURRENT terminal must retain the original prepared continuation"
        )
        XCTAssertTrue(
            try XCTUnwrap(
                controller.pendingInitialFrameLifecyclePresentation?.mappingToken
            ) === preparedToken,
            "duplicate CURRENT terminal must retain the continuation's exact token"
        )
        XCTAssertTrue(
            try XCTUnwrap(controller.initialLocalFirstFrameMappingToken) ===
                preparedToken,
            "duplicate CURRENT terminal must retain the original mapping token"
        )
        XCTAssertFalse(preparedToken.isCancelled)
        XCTAssertEqual(probe.mappingCount, 1)
        XCTAssertEqual(duplicatePreparedApplyCount, 0)
        XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)

        let stalePage = ChatInitialBootstrapRequestCoordinator.CommittedPage(
            event: MessageArchiveEndPageEvent(
                owner: key.owner,
                queryId: "stale-query",
                state: MessageArchivePageEndState(
                    queryExhausted: true,
                    archiveEnded: true,
                    persistedMessageCount: 8
                ),
                first: "stale-first",
                last: "stale-last",
                count: 8,
                streamKind: .primary,
                source: .localCallback
            ),
            completion: ChatRemoteHistoryCompletionResult(
                state: MessageArchivePageEndState(
                    queryExhausted: true,
                    archiveEnded: true,
                    persistedMessageCount: 8
                ),
                flushedMessageCount: 0,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            )
        )
        controller.consumeInitialBootstrapCommittedPage(stalePage)
        XCTAssertEqual(
            controller.pendingInitialFrameLifecyclePresentation?.identity,
            pendingIdentity,
            "stale committed callbacks must not replace the retained frame"
        )

        switch control {
        case .current:
            controller.willEnterForeground()
            controller.didBecomeActive()
            XCTAssertTrue(waitUntil {
                probe.commitCount == 1
            }, "current: retained frame must publish exactly one UIKit commit receipt")
            XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
            XCTAssertEqual(controller.appliedBootstrapLoadingState, .content)
            XCTAssertFalse(controller.showSkeletonObserver.value)
            XCTAssertFalse(
                controller.isInitialBootstrapInFlight,
                "current: persisted/visible receipt plus committed frame must release bootstrap tracking"
            )
            XCTAssertNil(controller.initialBootstrapQueryId)
            XCTAssertNil(controller.pendingInitialFrameLifecyclePresentation)
            XCTAssertEqual(probe.mappingCount, 1)
            XCTAssertEqual(probe.commitCount, 1)
            XCTAssertEqual(controller.datasetMappingGeneration, preparedDatasetGeneration)
            XCTAssertEqual(
                controller.bootstrapSkeletonMappingGeneration,
                preparedSkeletonGeneration + 1,
                "content publication invalidates the prior skeleton mapping token without rendering another skeleton"
            )
            XCTAssertEqual(probe.commitDiagnostics?.storeQueryCount, 2)
            XCTAssertEqual(probe.commitDiagnostics?.realDatasourceApplyCount, 1)
            XCTAssertEqual(
                controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
                1
            )
            XCTAssertEqual(
                controller.scrollFrameOperationCounter.snapshot()[.reloads],
                1,
                "the generation increment is cancellation only, not a second skeleton reload"
            )
            XCTAssertEqual(controller.datasource.filter { !$0.isFakeMessage }.count, 8)
            XCTAssertFalse(controller.hasCommittedBootstrapSkeletonRows)
            XCTAssertEqual(
                coordinator.productionDiagnosticsSnapshot(for: key).leaseStartCount,
                1
            )
            XCTAssertEqual(
                coordinator.productionDiagnosticsSnapshot(for: key).transportStartCount,
                1
            )
            let committedPrimaries = controller.datasource.map(\.primary)
            controller.willEnterForeground()
            controller.didBecomeActive()
            coordinator.recordCommittedPageForTesting(
                key: key,
                queryId: lease.queryId,
                hasDurableCoverage: true,
                resultCount: 8,
                persistedRowsForQuery: 8,
                visibleRowsForConversation: 8
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(controller.datasource.map(\.primary), committedPrimaries)
            XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
            XCTAssertEqual(probe.mappingCount, 1)
            XCTAssertEqual(duplicatePreparedApplyCount, 0)

        case .replacement:
            controller.beginInitialBootstrapTracking(
                queryId: "replacement-query",
                timeout: nil
            )
            XCTAssertNil(controller.pendingInitialFrameLifecyclePresentation)
            XCTAssertTrue(preparedToken.isCancelled)
            controller.willEnterForeground()
            controller.didBecomeActive()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            assertBlockingVisualState(
                captureBlockingSnapshot(controller, lease: lease),
                equals: skeletonBeforeTerminal,
                label: "replacement query"
            )
            XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)

        case .cancelled:
            controller.resetInitialBootstrapTracking()
            XCTAssertNil(controller.pendingInitialFrameLifecyclePresentation)
            XCTAssertTrue(preparedToken.isCancelled)
            controller.willEnterForeground()
            controller.didBecomeActive()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            assertBlockingVisualState(
                captureBlockingSnapshot(controller, lease: lease),
                equals: skeletonBeforeTerminal,
                label: "cancelled presentation"
            )
            XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
            XCTAssertEqual(controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies], 0)
        }

        controller.initialFirstFrameMappingBarrierForTests = nil
        controller.performanceFixtureInitialFrameCommitDiagnosticsHandler = nil
        controller.performTerminalChatResourceTeardownForTesting()
    }

    private func captureProductionOfflineSnapshot(
        _ controller: ChatViewController
    ) -> ChatProductionOfflineBootstrapSnapshot {
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        let heights = controller.datasource.indices.map { section -> CGFloat in
            controller.messagesCollectionView
                .layoutAttributesForItem(
                    at: IndexPath(item: 0, section: section)
                )?.frame.height ?? -1
        }
        return ChatProductionOfflineBootstrapSnapshot(
            primaries: controller.datasource.map(\.primary),
            messageIds: controller.datasource.map(\.messageId),
            heights: heights,
            contentSize: controller.messagesCollectionView.contentSize,
            contentOffset: controller.messagesCollectionView.contentOffset,
            datasourceSnapshotPrimaries: controller.datasourceSnapshot.items.map(\.primary),
            datasetMappingGeneration: controller.datasetMappingGeneration,
            skeletonMappingGeneration: controller.bootstrapSkeletonMappingGeneration,
            layoutPreparationGeneration: controller.layoutPreparationGeneration,
            bootstrapQueryId: controller.initialBootstrapQueryId,
            targetFingerprint: controller.initialBootstrapTargetFingerprint,
            loadingState: controller.appliedBootstrapLoadingState,
            skeletonVisible: controller.showSkeletonObserver.value,
            firstContentReceiptCount: controller.initialFirstContentApplyCount,
            hasCommittedSkeletonRows: controller.hasCommittedBootstrapSkeletonRows,
            retryVisible: !controller.bootstrapFailureView.isHidden
        )
    }

    private func makeProductionOfflineArchivedMessage(
        owner: String,
        jid: String,
        queryId: String
    ) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)' id='500'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(jid)' to='\(owner)' type='chat' id='offline-reconnect-message-500'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='500'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='offline-reconnect-message-500'/>
                <body>offline reconnect production dispatcher fixture</body>
              </message>
              <delay xmlns='urn:xmpp:delay' stamp='2026-08-01T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """, options: 0)
        return try XMPPMessage(from: XCTUnwrap(document.rootElement()))
    }

    private func makeProductionOfflineFinalIQ(queryId: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>500</first>
              <last>500</last>
            </set>
          </fin>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeBlockingController(
        suffix: String,
        syncUnreadCount: Int = 1,
        snapshotArchiveId: String = "remote-500"
    ) throws -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "lifecycle-owner-\(suffix)@example.com"
        controller.jid = "lifecycle-peer-\(suffix)@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        try seedConversation(
            controller,
            isSynced: false,
            isInitialArchiveLoaded: false,
            syncUnreadCount: syncUnreadCount,
            snapshotArchiveId: snapshotArchiveId
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        return controller
    }

    private func makeColdReadyController(
        suffix: String,
        applicationState: UIApplication.State
    ) throws -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "cold-owner-\(suffix)@example.com"
        controller.jid = "cold-peer-\(suffix)@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.initialFramePresentationApplicationStateProvider = {
            applicationState
        }
        try seedConversation(controller, isSynced: true, isInitialArchiveLoaded: true)
        try insertPersistedMessages(
            owner: controller.owner,
            jid: controller.jid,
            queryId: "cold-local-\(suffix)",
            count: 8
        )
        return controller
    }

    private func seedConversation(
        _ controller: ChatViewController,
        isSynced: Bool,
        isInitialArchiveLoaded: Bool,
        syncUnreadCount: Int = 1,
        snapshotArchiveId: String = "remote-500"
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType
        )
        chat.owner = controller.owner
        chat.jid = controller.jid
        chat.conversationType = controller.conversationType
        chat.isSynced = isSynced
        chat.isInitialArchiveLoaded = isInitialArchiveLoaded
        chat.syncSnapshotLastArchiveId = snapshotArchiveId
        chat.syncUnreadAfterId = syncUnreadCount > 0 ? "remote-499" : nil
        chat.syncUnreadCount = syncUnreadCount
        try realm.write {
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = snapshotArchiveId
            archiveState.newerLiveEdgeReached = false
        }
    }

    private func markConversationDurablyEmpty(_ controller: ChatViewController) throws {
        let realm = try WRealm.safe()
        try realm.write {
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: controller.jid,
                    owner: controller.owner,
                    conversationType: controller.conversationType
                )
            ) else {
                return XCTFail("expected seeded conversation")
            }
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.syncUnreadCount = 0
            chat.syncUnreadAfterId = nil
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType,
                in: realm
            )
            archiveState.newerLiveEdgeReached = true
        }
    }

    private func insertPersistedMessages(
        owner: String,
        jid: String,
        queryId: String,
        count: Int
    ) throws {
        let realm = try WRealm.safe()
        try realm.write {
            for index in 0..<count {
                let primary = "\(queryId)-message-\(index)"
                let message = MessageStorageItem()
                message.primary = primary
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.messageId = primary
                message.archivedId = "archive-\(index)"
                message.body = "Persisted lifecycle row \(index)"
                message.legacyBody = message.body
                message.date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                message.sentDate = message.date
                message.displayAs = .text
                message.state = .deliver
                message.queryIds = queryId
                realm.add(message, update: .modified)
            }
            let newestArchiveId = count > 0 ? "archive-\(count - 1)" : nil
            if let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ) {
                chat.isSynced = true
                chat.isInitialArchiveLoaded = true
                chat.syncUnreadCount = 0
                chat.syncUnreadAfterId = nil
                chat.syncSnapshotLastArchiveId = newestArchiveId
            }
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = newestArchiveId
            if let newestArchiveId {
                archiveState.mergeLoadedRange(
                    first: "archive-0",
                    last: newestArchiveId,
                    updateKind: .bootstrapNewest
                )
            }
            archiveState.newerLiveEdgeReached = true
        }
    }

    private func makeNonRetainingMessageManager(owner: String) -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        return manager
    }

    private func captureBlockingSnapshot(
        _ controller: ChatViewController,
        lease: ChatInitialBootstrapRequestCoordinator.Lease
    ) -> ChatBootstrapBlockingSnapshot {
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        let heights = controller.datasource.indices.map { section -> CGFloat in
            let indexPath = IndexPath(item: 0, section: section)
            return controller.messagesCollectionView
                .layoutAttributesForItem(at: indexPath)?.frame.height ?? -1
        }
        return ChatBootstrapBlockingSnapshot(
            primaries: controller.datasource.map(\.primary),
            messageIds: controller.datasource.map(\.messageId),
            heights: heights,
            contentSize: controller.messagesCollectionView.contentSize,
            contentOffset: controller.messagesCollectionView.contentOffset,
            datasourceSnapshotPrimaries: controller.datasourceSnapshot.items.map(\.primary),
            datasetMappingGeneration: controller.datasetMappingGeneration,
            skeletonMappingGeneration: controller.bootstrapSkeletonMappingGeneration,
            layoutPreparationGeneration: controller.layoutPreparationGeneration,
            bootstrapQueryId: controller.initialBootstrapQueryId,
            leaseQueryId: lease.queryId,
            leaseDeadline: lease.deadline,
            targetFingerprint: controller.initialBootstrapTargetFingerprint,
            loadingState: controller.appliedBootstrapLoadingState,
            skeletonVisible: controller.showSkeletonObserver.value,
            firstContentReceiptCount: controller.initialFirstContentApplyCount,
            hasCommittedSkeletonRows: controller.hasCommittedBootstrapSkeletonRows
        )
    }

    private func assertBlockingSnapshot(
        _ actual: ChatBootstrapBlockingSnapshot,
        equals expected: ChatBootstrapBlockingSnapshot,
        label: String
    ) {
        XCTAssertEqual(actual, expected, label)
    }

    private func assertBlockingVisualState(
        _ actual: ChatBootstrapBlockingSnapshot,
        equals expected: ChatBootstrapBlockingSnapshot,
        label: String
    ) {
        XCTAssertEqual(actual.primaries, expected.primaries, label)
        XCTAssertEqual(actual.messageIds, expected.messageIds, label)
        XCTAssertEqual(actual.heights, expected.heights, label)
        XCTAssertEqual(actual.contentSize, expected.contentSize, label)
        XCTAssertEqual(actual.contentOffset, expected.contentOffset, label)
        XCTAssertEqual(
            actual.datasourceSnapshotPrimaries,
            expected.datasourceSnapshotPrimaries,
            label
        )
        XCTAssertEqual(actual.skeletonMappingGeneration, expected.skeletonMappingGeneration, label)
        XCTAssertEqual(actual.layoutPreparationGeneration, expected.layoutPreparationGeneration, label)
        XCTAssertEqual(actual.loadingState, expected.loadingState, label)
        XCTAssertEqual(actual.skeletonVisible, expected.skeletonVisible, label)
        XCTAssertEqual(actual.firstContentReceiptCount, expected.firstContentReceiptCount, label)
        XCTAssertEqual(actual.hasCommittedSkeletonRows, expected.hasCommittedSkeletonRows, label)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}

private enum BootstrapLifecyclePhase: String, CaseIterable {
    case queued
    case transport
    case persistence

    var coordinatorPhase: ConversationArchiveLoadPhase {
        switch self {
        case .queued:
            return .queued
        case .transport:
            return .transport
        case .persistence:
            return .persistence
        }
    }
}

private enum DeferredPresentationControl: String {
    case current
    case replacement
    case cancelled
}

private struct ChatBootstrapBlockingSnapshot: Equatable {
    let primaries: [String]
    let messageIds: [String]
    let heights: [CGFloat]
    let contentSize: CGSize
    let contentOffset: CGPoint
    let datasourceSnapshotPrimaries: [String]
    let datasetMappingGeneration: Int
    let skeletonMappingGeneration: Int
    let layoutPreparationGeneration: Int
    let bootstrapQueryId: String?
    let leaseQueryId: String
    let leaseDeadline: Date
    let targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint?
    let loadingState: ChatBootstrapLoadingState?
    let skeletonVisible: Bool
    let firstContentReceiptCount: Int
    let hasCommittedSkeletonRows: Bool
}

private struct ChatProductionOfflineBootstrapSnapshot: Equatable {
    let primaries: [String]
    let messageIds: [String]
    let heights: [CGFloat]
    let contentSize: CGSize
    let contentOffset: CGPoint
    let datasourceSnapshotPrimaries: [String]
    let datasetMappingGeneration: Int
    let skeletonMappingGeneration: Int
    let layoutPreparationGeneration: Int
    let bootstrapQueryId: String?
    let targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint?
    let loadingState: ChatBootstrapLoadingState?
    let skeletonVisible: Bool
    let firstContentReceiptCount: Int
    let hasCommittedSkeletonRows: Bool
    let retryVisible: Bool
}

private struct ChatOfflineReconnectMAMSend: Equatable {
    let elementId: String?
    let queryId: String?
    let maximum: Int?
    let before: String?
    let after: String?
    let wasMainThread: Bool
}

private final class ChatOfflineReconnectCapturingStream: XMPPStream {
    private let captureLock = NSLock()
    private var capturedMAMSends: [ChatOfflineReconnectMAMSend] = []

    var mamSends: [ChatOfflineReconnectMAMSend] {
        captureLock.lock()
        defer { captureLock.unlock() }
        return capturedMAMSends
    }

    override func send(_ element: DDXMLElement) {
        guard let query = element.element(
            forName: "query",
            xmlns: "urn:xmpp:mam:2"
        ) else {
            return
        }
        let set = query.element(
            forName: "set",
            xmlns: "http://jabber.org/protocol/rsm"
        )
        let before: String?
        if let beforeElement = set?.element(forName: "before") {
            before = beforeElement.stringValue ?? ""
        } else {
            before = nil
        }
        let after: String?
        if let afterElement = set?.element(forName: "after") {
            after = afterElement.stringValue ?? ""
        } else {
            after = nil
        }
        let maximum = set?.element(forName: "max")?.stringValue.flatMap {
            Int($0)
        }
        let snapshot = ChatOfflineReconnectMAMSend(
            elementId: element.attributeStringValue(forName: "id"),
            queryId: query.attributeStringValue(forName: "queryid"),
            maximum: maximum,
            before: before,
            after: after,
            wasMainThread: Thread.isMainThread
        )
        captureLock.lock()
        capturedMAMSends.append(snapshot)
        captureLock.unlock()
    }
}

private final class ChatOfflineReconnectDeliveryProbe {
    struct Snapshot {
        let didFinishRawTerminal: Bool
        let isFinished: Bool
        let recordedEnvelope: Bool
        let acceptedFinal: Bool
        let acceptedDuplicateFinal: Bool
        let wasMainThread: Bool
    }

    private let lock = NSLock()
    private var storedSnapshot = Snapshot(
        didFinishRawTerminal: false,
        isFinished: false,
        recordedEnvelope: false,
        acceptedFinal: false,
        acceptedDuplicateFinal: false,
        wasMainThread: true
    )

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func recordRawTerminal(
        recordedEnvelope: Bool,
        acceptedFinal: Bool,
        acceptedDuplicateFinal: Bool,
        wasMainThread: Bool
    ) {
        lock.lock()
        storedSnapshot = Snapshot(
            didFinishRawTerminal: true,
            isFinished: false,
            recordedEnvelope: recordedEnvelope,
            acceptedFinal: acceptedFinal,
            acceptedDuplicateFinal: acceptedDuplicateFinal,
            wasMainThread: wasMainThread
        )
        lock.unlock()
    }

    func finishMessageIngress() {
        lock.lock()
        storedSnapshot = Snapshot(
            didFinishRawTerminal: storedSnapshot.didFinishRawTerminal,
            isFinished: true,
            recordedEnvelope: storedSnapshot.recordedEnvelope,
            acceptedFinal: storedSnapshot.acceptedFinal,
            acceptedDuplicateFinal: storedSnapshot.acceptedDuplicateFinal,
            wasMainThread: storedSnapshot.wasMainThread
        )
        lock.unlock()
    }
}

private final class ChatOfflineReconnectCommittedPageProbe {
    struct Snapshot {
        let didCommit: Bool
        let queryId: String?
        let persistedRows: Int
        let visibleRows: Int
        let persistedVisibleRowCount: Int
        let hasDurableCoverage: Bool
        let hasPresentationMaterialization: Bool
        let recommendedFollowUpTarget:
            MessageArchiveManager.ChatBootstrapPageTarget?
        let hasPendingFollowUp: Bool
    }

    private let lock = NSLock()
    private var observation:
        ChatInitialBootstrapRequestCoordinator.ObservationToken?
    private var storedSnapshot = Snapshot(
        didCommit: false,
        queryId: nil,
        persistedRows: 0,
        visibleRows: 0,
        persistedVisibleRowCount: 0,
        hasDurableCoverage: false,
        hasPresentationMaterialization: false,
        recommendedFollowUpTarget: nil,
        hasPendingFollowUp: false
    )

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func installObservation(
        _ observation: ChatInitialBootstrapRequestCoordinator.ObservationToken
    ) {
        lock.lock()
        self.observation = observation
        lock.unlock()
    }

    func takeObservation()
        -> ChatInitialBootstrapRequestCoordinator.ObservationToken? {
        lock.lock()
        defer { lock.unlock() }
        let observation = self.observation
        self.observation = nil
        return observation
    }

    func record(
        queryId: String,
        readiness: ConversationArchiveReadiness,
        page: ChatInitialBootstrapRequestCoordinator.CommittedPage,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        hasPendingFollowUp: Bool
    ) {
        let persistenceSummary = page.completion.persistenceSummary
        lock.lock()
        storedSnapshot = Snapshot(
            didCommit: true,
            queryId: queryId,
            persistedRows: persistenceSummary.persistedRows,
            visibleRows: persistenceSummary.visibleRows(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ),
            persistedVisibleRowCount: readiness.persistedVisibleRowCount,
            hasDurableCoverage: readiness.hasDurableCoverage,
            hasPresentationMaterialization: page.hasPresentationMaterialization,
            recommendedFollowUpTarget: page.recommendedFollowUpTarget,
            hasPendingFollowUp: hasPendingFollowUp
        )
        lock.unlock()
    }
}

private final class ChatLifecyclePreparationProbe {
    private let lock = NSLock()
    private var storedMappingCount = 0
    private var storedCommitDiagnostics: ChatPerformanceInitialFrameCommitDiagnostics?
    private var storedCommitCount = 0

    var mappingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMappingCount
    }

    var commitDiagnostics: ChatPerformanceInitialFrameCommitDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return storedCommitDiagnostics
    }

    var commitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCommitCount
    }

    func incrementMappingCount() {
        lock.lock()
        storedMappingCount += 1
        lock.unlock()
    }

    func recordCommit(_ diagnostics: ChatPerformanceInitialFrameCommitDiagnostics) {
        lock.lock()
        storedCommitCount += 1
        storedCommitDiagnostics = diagnostics
        lock.unlock()
    }
}
