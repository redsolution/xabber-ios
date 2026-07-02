import XCTest
import UIKit
@testable import xabber

final class ChatScrollCoalescingTests: XCTestCase {
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

    func testPagingRequestIsNotDuplicatedWhileRemotePageIsInFlight() {
        var scheduled: [() -> Void] = []
        var requestCount = 0
        var isRemotePageInFlight = false
        let scheduler = ChatScrollWorkScheduler(
            schedule: { scheduled.append($0) },
            handler: { request in
                let direction = ChatHistoryPagingPolicy.triggerDirection(
                    isUserScrolling: request.isUserScrolling,
                    canLoadDatasource: true,
                    gestureTranslationY: request.gestureTranslationY,
                    boundaryContext: ChatHistoryPagingBoundaryContext(
                        firstRealSection: 0,
                        lastRealSection: 3,
                        visibleRealSections: [0]
                    ),
                    currentPageMinIndex: 0,
                    currentPageMaxIndex: 4,
                    totalCount: 4,
                    hasLocalOlderAvailable: false,
                    hasLocalNewerAvailable: false,
                    hasRemoteOlderAvailable: !isRemotePageInFlight,
                    hasRemoteNewerAvailable: false
                )
                if direction != nil {
                    requestCount += 1
                    isRemotePageInFlight = true
                }
            }
        )

        scheduler.enqueue(request(offsetY: -20, gestureTranslationY: 40, visibleSections: [0], work: [.evaluateBoundaryPaging]))
        scheduled.removeFirst()()

        scheduler.enqueue(request(offsetY: -24, gestureTranslationY: 42, visibleSections: [0], work: [.evaluateBoundaryPaging]))
        scheduled.removeFirst()()

        XCTAssertEqual(requestCount, 1)
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
