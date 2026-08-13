import XCTest
@testable import xabber

final class GroupRequestCoordinatorTests: XCTestCase {
    func testRequestIsRegisteredBeforeSendAndSynchronousResultCompletesIt() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 10,
            scheduler: scheduler
        )
        var wasPendingInsideSend = false
        var receivedResult: Result<String, GroupRequestError>?

        let disposition = coordinator.registerAndSend(
            id: "iq-1",
            send: {
                wasPendingInsideSend = coordinator.pendingRequestCount == 1
                XCTAssertEqual(
                    coordinator.receive(id: "iq-1", response: .result("created")),
                    .completed
                )
            },
            completion: { receivedResult = $0 }
        )

        XCTAssertEqual(disposition, .accepted)
        XCTAssertTrue(wasPendingInsideSend)
        XCTAssertEqual(try? receivedResult?.get(), "created")
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
        XCTAssertEqual(scheduler.pendingActionCount, 0)
    }

    func testResultIsCorrelatedByIQIDWithoutAffectingOtherRequests() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 10,
            scheduler: scheduler
        )
        var firstResult: Result<String, GroupRequestError>?
        var secondResult: Result<String, GroupRequestError>?

        coordinator.registerAndSend(
            id: "iq-1",
            send: {},
            completion: { firstResult = $0 }
        )
        coordinator.registerAndSend(
            id: "iq-2",
            send: {},
            completion: { secondResult = $0 }
        )

        XCTAssertEqual(
            coordinator.receive(id: "unknown", response: .result("wrong")),
            .ignored
        )
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)

        XCTAssertEqual(
            coordinator.receive(id: "iq-2", response: .result("second")),
            .completed
        )
        XCTAssertNil(firstResult)
        XCTAssertEqual(try? secondResult?.get(), "second")

        XCTAssertEqual(
            coordinator.receive(id: "iq-1", response: .result("first")),
            .completed
        )
        XCTAssertEqual(try? firstResult?.get(), "first")
    }

    func testIQErrorCompletesWithTypedFailure() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 10,
            scheduler: scheduler
        )
        let stanzaError = GroupRequestIQError(
            condition: "forbidden",
            text: "Only owners may update this group"
        )
        var receivedResult: Result<String, GroupRequestError>?

        coordinator.registerAndSend(
            id: "iq-1",
            send: {},
            completion: { receivedResult = $0 }
        )
        XCTAssertEqual(
            coordinator.receive(id: "iq-1", response: .error(stanzaError)),
            .completed
        )

        guard case let .failure(.iq(receivedError)) = receivedResult else {
            return XCTFail("Expected a typed IQ error")
        }
        XCTAssertEqual(receivedError, stanzaError)
    }

    func testTimeoutCompletesOnceAndLateResultIsIgnored() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 5,
            scheduler: scheduler
        )
        var results: [Result<String, GroupRequestError>] = []

        coordinator.registerAndSend(
            id: "iq-1",
            send: {},
            completion: { results.append($0) }
        )

        scheduler.advance(by: 4.9)
        XCTAssertTrue(results.isEmpty)

        scheduler.advance(by: 0.1)
        XCTAssertEqual(results.count, 1)
        guard case .failure(.timeout) = results.first else {
            return XCTFail("Expected timeout")
        }

        XCTAssertEqual(
            coordinator.receive(id: "iq-1", response: .result("late")),
            .ignored
        )
        scheduler.advance(by: 100)
        XCTAssertEqual(results.count, 1)
    }

    func testDisconnectCancelsAllPendingRequestsAndTheirTimeouts() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 5,
            scheduler: scheduler
        )
        var results: [String: Result<String, GroupRequestError>] = [:]

        coordinator.registerAndSend(
            id: "iq-1",
            send: {},
            completion: { results["iq-1"] = $0 }
        )
        coordinator.registerAndSend(
            id: "iq-2",
            send: {},
            completion: { results["iq-2"] = $0 }
        )

        XCTAssertEqual(scheduler.pendingActionCount, 2)
        XCTAssertEqual(coordinator.cancelPendingRequestsForDisconnect(), 2)
        XCTAssertEqual(coordinator.pendingRequestCount, 0)
        XCTAssertEqual(scheduler.pendingActionCount, 0)

        for id in ["iq-1", "iq-2"] {
            guard case .failure(.disconnected) = results[id] else {
                return XCTFail("Expected disconnect for \(id)")
            }
            XCTAssertEqual(
                coordinator.receive(id: id, response: .result("late")),
                .ignored
            )
        }

        scheduler.advance(by: 100)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(coordinator.cancelPendingRequestsForDisconnect(), 0)
    }

    func testDuplicateAndUnsolicitedResponsesAreIgnored() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 10,
            scheduler: scheduler
        )
        var results: [Result<String, GroupRequestError>] = []

        coordinator.registerAndSend(
            id: "iq-1",
            send: {},
            completion: { results.append($0) }
        )

        XCTAssertEqual(
            coordinator.receive(id: "iq-1", response: .result("first")),
            .completed
        )
        XCTAssertEqual(
            coordinator.receive(id: "iq-1", response: .result("duplicate")),
            .ignored
        )
        XCTAssertEqual(
            coordinator.receive(id: "unsolicited", response: .result("unknown")),
            .ignored
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try? results.first?.get(), "first")
    }

    func testDuplicateRequestIDIsRejectedWithoutSendingOrReplacingOriginal() {
        let scheduler = ManualGroupRequestTimeoutScheduler()
        let coordinator = GroupRequestCoordinator<String>(
            defaultTimeout: 10,
            scheduler: scheduler
        )
        var originalResult: Result<String, GroupRequestError>?
        var duplicateResult: Result<String, GroupRequestError>?
        var originalSendCount = 0
        var duplicateSendCount = 0

        XCTAssertEqual(
            coordinator.registerAndSend(
                id: "iq-1",
                send: { originalSendCount += 1 },
                completion: { originalResult = $0 }
            ),
            .accepted
        )
        XCTAssertEqual(
            coordinator.registerAndSend(
                id: "iq-1",
                send: { duplicateSendCount += 1 },
                completion: { duplicateResult = $0 }
            ),
            .rejectedDuplicateRequestID
        )

        XCTAssertEqual(originalSendCount, 1)
        XCTAssertEqual(duplicateSendCount, 0)
        XCTAssertNil(originalResult)
        guard case let .failure(.duplicateRequestID(id)) = duplicateResult else {
            return XCTFail("Expected duplicate request ID failure")
        }
        XCTAssertEqual(id, "iq-1")

        XCTAssertEqual(
            coordinator.receive(id: "iq-1", response: .result("original")),
            .completed
        )
        XCTAssertEqual(try? originalResult?.get(), "original")
    }
}

private final class ManualGroupRequestTimeoutScheduler: GroupRequestTimeoutScheduling {
    private struct ScheduledAction {
        let deadline: TimeInterval
        let token: Token
    }

    private final class Token: GroupRequestTimeoutCancellation {
        private let lock = NSLock()
        private let action: () -> Void
        private var isCancelled = false
        private var hasRun = false

        init(action: @escaping () -> Void) {
            self.action = action
        }

        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !isCancelled && !hasRun
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func runIfPending() {
            lock.lock()
            guard !isCancelled, !hasRun else {
                lock.unlock()
                return
            }
            hasRun = true
            lock.unlock()
            action()
        }
    }

    private var now: TimeInterval = 0
    private var scheduledActions: [ScheduledAction] = []

    var pendingActionCount: Int {
        scheduledActions.reduce(into: 0) { count, scheduledAction in
            if scheduledAction.token.isPending {
                count += 1
            }
        }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> GroupRequestTimeoutCancellation {
        let token = Token(action: action)
        scheduledActions.append(
            ScheduledAction(deadline: now + delay, token: token)
        )
        return token
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let dueActions = scheduledActions
            .filter { $0.deadline <= now }
            .sorted { $0.deadline < $1.deadline }
        dueActions.forEach { $0.token.runIfPending() }
    }
}
