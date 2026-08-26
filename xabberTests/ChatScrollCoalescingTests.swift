import XCTest
import UIKit
@testable import xabber

final class ChatScrollCoalescingTests: XCTestCase {
    func testInteractionGateDefersPresentationRefreshButNotCriticalUserActions() {
        XCTAssertTrue(
            ChatUIResponsivenessGate.shouldDefer(
                workKind: .presentationRefresh,
                isActive: true
            )
        )
        XCTAssertFalse(
            ChatUIResponsivenessGate.shouldDefer(
                workKind: .criticalUserAction,
                isActive: true
            )
        )
        XCTAssertFalse(
            ChatUIResponsivenessGate.shouldDefer(
                workKind: .presentationRefresh,
                isActive: false
            )
        )
    }

    func testInteractionGateExtendsUntilLatestActivationExpires() {
        var now = Date(timeIntervalSince1970: 100)
        var scheduled: [(TimeInterval, () -> Void)] = []
        let gate = ChatUIResponsivenessGate(
            now: { now },
            schedule: { delay, work in scheduled.append((delay, work)) }
        )

        gate.activate(reason: .keyboardFrame, duration: 0.2)
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(scheduled.count, 1)

        now = Date(timeIntervalSince1970: 100.1)
        gate.activate(reason: .typing, duration: 0.2)
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(scheduled.count, 1)

        now = Date(timeIntervalSince1970: 100.25)
        scheduled[0].1()
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(scheduled.count, 2)

        now = Date(timeIntervalSince1970: 100.31)
        scheduled[1].1()
        XCTAssertFalse(gate.isActive)
    }

    func testKeyboardFrameHoldDurationCoversAnimationDuration() {
        XCTAssertEqual(
            ChatUIResponsivenessGate.holdDuration(keyboardAnimationDuration: 0),
            ChatUIResponsivenessGate.defaultHoldDuration
        )
        XCTAssertEqual(
            ChatUIResponsivenessGate.holdDuration(keyboardAnimationDuration: 0.35),
            0.40,
            accuracy: 0.001
        )
    }

    func testInteractionGateCoalescesPresentationRefreshUntilInactive() {
        var now = Date(timeIntervalSince1970: 100)
        var scheduled: [(TimeInterval, () -> Void)] = []
        let gate = ChatUIResponsivenessGate(
            now: { now },
            schedule: { delay, work in scheduled.append((delay, work)) }
        )
        var calls: [String] = []

        gate.activate(reason: .keyboardFrame, duration: 0.2)
        gate.runOrDefer(workKind: .presentationRefresh, key: "toolbar") {
            calls.append("first")
        }
        gate.runOrDefer(workKind: .presentationRefresh, key: "toolbar") {
            calls.append("second")
        }

        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(scheduled.count, 2)

        now = Date(timeIntervalSince1970: 100.21)
        scheduled[1].1()

        XCTAssertEqual(calls, ["second"])
    }

    func testNonUserScrollNeverEvaluatesBoundaryPaging() {
        let request = ChatScrollWorkRequest(
            contentOffsetY: 0,
            gestureTranslationY: 0,
            isUserScrolling: false,
            visibleIndexPaths: [IndexPath(item: 0, section: 0)],
            work: [.updateScrollPosition, .evaluateBoundaryPaging]
        )

        let effectiveWork = request.effectiveWork(isInteractionGateActive: false)

        XCTAssertFalse(effectiveWork.contains(.evaluateBoundaryPaging))
        XCTAssertTrue(effectiveWork.contains(.updateScrollPosition))
    }

    func testInteractionGateDropsNonCriticalProgrammaticScrollWork() {
        let request = ChatScrollWorkRequest(
            contentOffsetY: 0,
            gestureTranslationY: 0,
            isUserScrolling: false,
            visibleIndexPaths: [IndexPath(item: 0, section: 0)],
            work: [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue, .evaluateBoundaryPaging]
        )

        let effectiveWork = request.effectiveWork(isInteractionGateActive: true)

        XCTAssertFalse(effectiveWork.contains(.updateFloatingDate))
        XCTAssertFalse(effectiveWork.contains(.updateVoiceQueue))
        XCTAssertFalse(effectiveWork.contains(.evaluateBoundaryPaging))
        XCTAssertTrue(effectiveWork.contains(.advanceReadBoundary))
    }

    func testRapidScrollEventsProduceOneExecutionWithNewestState() {
        var scheduled: [() -> Void] = []
        var executions: [ChatScrollWorkRequest] = []
        let scheduler = ChatScrollWorkScheduler(
            schedule: { scheduled.append($0) },
            handler: { executions.append($0) }
        )

        scheduler.enqueue(request(offsetY: 12, visibleSections: [1], work: [.updateScrollPosition, .advanceReadBoundary]))
        scheduler.enqueue(request(offsetY: 48, visibleSections: [7], work: [.updateVoiceQueue]))

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertTrue(executions.isEmpty)

        scheduled[0]()

        XCTAssertEqual(executions.count, 1)
        XCTAssertEqual(executions[0].contentOffsetY, 48)
        XCTAssertEqual(executions[0].visibleIndexPaths.map(\.section), [7])
        XCTAssertTrue(executions[0].work.contains(.updateScrollPosition))
        XCTAssertTrue(executions[0].work.contains(.advanceReadBoundary))
        XCTAssertTrue(executions[0].work.contains(.updateVoiceQueue))
    }

    func testFlushRunsPendingWorkAndInvalidatesScheduledCallback() {
        var scheduled: [() -> Void] = []
        var executions: [ChatScrollWorkRequest] = []
        let scheduler = ChatScrollWorkScheduler(
            schedule: { scheduled.append($0) },
            handler: { executions.append($0) }
        )

        scheduler.enqueue(request(offsetY: 20, visibleSections: [2]))
        scheduler.flush()

        XCTAssertEqual(executions.count, 1)
        XCTAssertEqual(executions[0].contentOffsetY, 20)

        scheduled[0]()

        XCTAssertEqual(executions.count, 1)
    }

    func testReadBoundaryUsesNewestScheduledVisibleState() {
        let orderedMessages = [
            orderedMessage(primary: "incoming-old", orderIndex: 1),
            orderedMessage(primary: "incoming-new", orderIndex: 3)
        ]
        let primaryBySection = [
            1: "incoming-old",
            3: "incoming-new"
        ]
        var scheduled: [() -> Void] = []
        var selectedPrimary: String?
        var selectedBoundaryIndex: Int?
        let scheduler = ChatScrollWorkScheduler(
            schedule: { scheduled.append($0) },
            handler: { request in
                let visiblePrimaries = Set(request.visibleIndexPaths.compactMap { primaryBySection[$0.section] })
                guard let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
                    visiblePrimaries: visiblePrimaries,
                    orderedMessages: orderedMessages,
                    currentBoundaryIndex: selectedBoundaryIndex
                ) else {
                    return
                }
                selectedPrimary = target.primary
                selectedBoundaryIndex = target.orderIndex
            }
        )

        scheduler.enqueue(request(offsetY: 10, visibleSections: [1], work: [.advanceReadBoundary]))
        scheduler.enqueue(request(offsetY: 40, visibleSections: [3], work: [.advanceReadBoundary]))
        scheduled[0]()

        XCTAssertEqual(selectedPrimary, "incoming-new")
        XCTAssertEqual(selectedBoundaryIndex, 3)
    }

    private func request(
        offsetY: CGFloat,
        gestureTranslationY: CGFloat = 0,
        visibleSections: [Int],
        work: ChatScrollWorkOptions = [.updateScrollPosition, .updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue, .evaluateBoundaryPaging]
    ) -> ChatScrollWorkRequest {
        ChatScrollWorkRequest(
            contentOffsetY: offsetY,
            gestureTranslationY: gestureTranslationY,
            isUserScrolling: true,
            visibleIndexPaths: visibleSections.map { IndexPath(item: 0, section: $0) },
            work: work
        )
    }

    private func orderedMessage(
        primary: String,
        orderIndex: Int
    ) -> ChatViewportReadBoundaryPolicy.OrderedMessage {
        ChatViewportReadBoundaryPolicy.OrderedMessage(
            primary: primary,
            orderIndex: orderIndex,
            isOutgoing: false,
            isRead: false,
            rowKind: .message,
            isFakeMessage: false
        )
    }
}
