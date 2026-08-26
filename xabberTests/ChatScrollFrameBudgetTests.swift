import XCTest
import UIKit
@testable import xabber

final class ChatScrollFrameBudgetTests: XCTestCase {
    func testTenThousandTicksCoalesceToOneVisibleOnlyFrame() {
        let metadata = residentMetadata(rowCount: 384)
        let visibleIndexPaths = (100..<112).map { IndexPath(item: 0, section: $0) }
        let visible = metadata.capture(indexPaths: visibleIndexPaths)
        var scheduled: [() -> Void] = []
        var decisions: [ChatScrollFrameDecision] = []
        let counter = ChatRenderOperationCounter(isEnabled: true)
        let planner = ChatScrollFramePlanner(operationCounter: counter)
        let scheduler = ChatScrollWorkScheduler(
            schedule: { scheduled.append($0) },
            handler: { request in
                decisions.append(planner.plan(request: request, currentReadPosition: nil))
            }
        )

        for tick in 0..<10_000 {
            scheduler.enqueue(
                ChatScrollWorkRequest(
                    contentOffsetY: CGFloat(tick),
                    gestureTranslationY: -12,
                    isUserScrolling: true,
                    visibleIndexPaths: visibleIndexPaths,
                    visibleMetadata: visible,
                    work: [
                        .updateScrollPosition,
                        .updateFloatingDate,
                        .advanceReadBoundary,
                        .updateVoiceQueue,
                        .evaluateBoundaryPaging
                    ]
                )
            )
        }

        XCTAssertEqual(scheduled.count, 1)
        scheduled[0]()

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].diagnostics.visibleRowVisits, 12)
        XCTAssertEqual(decisions[0].diagnostics.storeQueryCount, 0)
        XCTAssertEqual(decisions[0].diagnostics.textMeasurementCount, 0)
        XCTAssertEqual(decisions[0].diagnostics.layoutMeasurementCount, 0)
        XCTAssertTrue(decisions[0].diagnostics.isWithinBudget(maxVisibleRows: 12))
        let operations = counter.snapshot()
        XCTAssertEqual(operations[.scrollFrames], 1)
        XCTAssertEqual(operations[.visibleRowsVisited], 12)
        XCTAssertEqual(operations[.storeQueries], 0)
        XCTAssertEqual(operations[.textMeasurements], 0)
        XCTAssertEqual(operations[.layoutCacheMisses], 0)
    }

    func testFrameWorkIsInvariantToResidentWindowSize() {
        let visibleIndexPaths = (10..<18).map { IndexPath(item: 0, section: $0) }
        let small = residentMetadata(rowCount: 80).capture(indexPaths: visibleIndexPaths)
        let large = residentMetadata(rowCount: 384).capture(indexPaths: visibleIndexPaths)

        let smallDecision = ChatScrollFramePlanner().plan(
            request: request(visible: small),
            currentReadPosition: nil
        )
        let largeDecision = ChatScrollFramePlanner().plan(
            request: request(visible: large),
            currentReadPosition: nil
        )

        XCTAssertEqual(smallDecision.diagnostics.visibleRowVisits, 8)
        XCTAssertEqual(largeDecision.diagnostics.visibleRowVisits, 8)
        XCTAssertEqual(smallDecision.diagnostics, largeDecision.diagnostics)
    }

    func testStaleVisibleGenerationKeepsOnlyOffsetBookkeeping() {
        let visible = residentMetadata(rowCount: 20).capture(
            indexPaths: [IndexPath(item: 0, section: 4)]
        )
        let request = ChatScrollWorkRequest(
            contentOffsetY: 40,
            gestureTranslationY: -10,
            isUserScrolling: true,
            visibleIndexPaths: [IndexPath(item: 0, section: 4)],
            visibleMetadata: visible,
            work: [
                .updateScrollPosition,
                .updateFloatingDate,
                .advanceReadBoundary,
                .updateVoiceQueue,
                .evaluateBoundaryPaging
            ]
        )

        let work = request.effectiveWork(
            isInteractionGateActive: false,
            currentVisibleMetadataGeneration: visible.generation + 1
        )

        XCTAssertEqual(work, [.updateScrollPosition])
    }

    func testCachedResidentEdgesDriveBothBoundaryContexts() {
        let metadata = residentMetadata(rowCount: 30, firstRealSection: 2, lastRealSection: 27)
        let top = metadata.capture(indexPaths: [IndexPath(item: 0, section: 2)])
        let bottom = metadata.capture(indexPaths: [IndexPath(item: 0, section: 27)])

        XCTAssertEqual(
            top.boundaryContext,
            ChatHistoryPagingBoundaryContext(
                firstRealSection: 2,
                lastRealSection: 27,
                visibleRealSections: [2]
            )
        )
        XCTAssertEqual(
            bottom.boundaryContext,
            ChatHistoryPagingBoundaryContext(
                firstRealSection: 2,
                lastRealSection: 27,
                visibleRealSections: [27]
            )
        )
        XCTAssertEqual(metadata.capture(indexPaths: [IndexPath(item: 1, section: 2)]).rows, [])
    }

    func testVisibleStableReadCursorNeverRegressesAfterTrimOrEdit() throws {
        let planner = ChatScrollFramePlanner()
        let old = visibleRow(section: 0, ordinal: 10, isRead: false)
        let current = visibleRow(section: 1, ordinal: 20, isRead: false)
        let newer = visibleRow(section: 2, ordinal: 30, isRead: false)
        let initialVisible = ChatScrollVisibleMetadata(
            generation: 1,
            residentRowCount: 3,
            rows: [old, current],
            boundaryContext: boundaryContext(first: 0, last: 2, visible: [0, 1])
        )
        let initial = planner.plan(request: request(visible: initialVisible), currentReadPosition: nil)
        let advanced = try XCTUnwrap(initial.readTarget)
        XCTAssertEqual(advanced.primary, current.primary)

        let trimmedAndEdited = ChatScrollVisibleMetadata(
            generation: 2,
            residentRowCount: 2,
            rows: [visibleRow(section: 0, ordinal: 10, isRead: false)],
            boundaryContext: boundaryContext(first: 0, last: 1, visible: [0])
        )
        XCTAssertNil(
            planner.plan(
                request: request(visible: trimmedAndEdited),
                currentReadPosition: advanced.position
            ).readTarget
        )

        let newerAfterReindex = ChatScrollVisibleMetadata(
            generation: 3,
            residentRowCount: 2,
            rows: [ChatScrollVisibleRow(
                section: 0,
                primary: newer.primary,
                position: newer.position,
                isOutgoing: false,
                isRead: false,
                rowKind: .message,
                isFakeMessage: false,
                sentDate: newer.sentDate,
                voiceDescriptors: []
            )],
            boundaryContext: boundaryContext(first: 0, last: 1, visible: [0])
        )
        XCTAssertEqual(
            planner.plan(
                request: request(visible: newerAfterReindex),
                currentReadPosition: advanced.position
            ).readTarget?.primary,
            newer.primary
        )
    }

    func testFloatingDateUpdatesOnlyWhenTopVisibleSectionOrDayChanges() {
        let planner = ChatScrollFramePlanner()
        let first = metadata(rows: [visibleRow(section: 4, ordinal: 4, day: 10)])
        let same = metadata(rows: [visibleRow(section: 4, ordinal: 4, day: 10)])
        let changedSection = metadata(rows: [visibleRow(section: 5, ordinal: 5, day: 10)])
        let changedDay = metadata(rows: [visibleRow(section: 5, ordinal: 5, day: 11)])

        XCTAssertNotNil(planner.plan(request: request(visible: first), currentReadPosition: nil).floatingDate)
        XCTAssertNil(planner.plan(request: request(visible: same), currentReadPosition: nil).floatingDate)
        XCTAssertNotNil(planner.plan(request: request(visible: changedSection), currentReadPosition: nil).floatingDate)
        XCTAssertNotNil(planner.plan(request: request(visible: changedDay), currentReadPosition: nil).floatingDate)
    }

    func testSkeletonRowsNeverPublishTheirSentinelDateAsFloatingChrome() {
        let planner = ChatScrollFramePlanner()
        let skeleton = metadata(rows: (0..<8).map {
            visibleRow(
                section: $0,
                ordinal: $0,
                day: 11_323,
                isFakeMessage: true
            )
        })

        let decision = planner.plan(
            request: request(visible: skeleton),
            currentReadPosition: nil
        )

        XCTAssertNil(
            decision.floatingDate,
            "placeholder dates are layout data and must never become visible chat chrome"
        )
    }

    func testVoiceQueueUsesPreparedDescriptorsAndUpdatesOnlyForChangedSignature() throws {
        let planner = ChatScrollFramePlanner()
        let firstDescriptor = voiceDescriptor(primary: "voice-1", downloaded: false)
        let updatedDescriptor = voiceDescriptor(primary: "voice-1", downloaded: true)
        let secondDescriptor = voiceDescriptor(primary: "voice-2", downloaded: true)

        let first = planner.plan(
            request: request(visible: metadata(rows: [visibleRow(section: 0, ordinal: 1, voices: [firstDescriptor])])),
            currentReadPosition: nil
        )
        XCTAssertEqual(try XCTUnwrap(first.voiceDescriptors).map(\.referencePrimary), ["voice-1"])

        let unchanged = planner.plan(
            request: request(visible: metadata(rows: [visibleRow(section: 0, ordinal: 1, voices: [firstDescriptor])])),
            currentReadPosition: nil
        )
        XCTAssertNil(unchanged.voiceDescriptors)
        XCTAssertEqual(unchanged.diagnostics.voiceDescriptorBuildCount, 0)

        let contentVersionChanged = planner.plan(
            request: request(visible: metadata(rows: [visibleRow(section: 0, ordinal: 1, voices: [updatedDescriptor])])),
            currentReadPosition: nil
        )
        XCTAssertTrue(try XCTUnwrap(contentVersionChanged.voiceDescriptors).first?.downloaded == true)

        let identityChanged = planner.plan(
            request: request(visible: metadata(rows: [visibleRow(section: 0, ordinal: 1, voices: [updatedDescriptor, secondDescriptor])])),
            currentReadPosition: nil
        )
        XCTAssertEqual(try XCTUnwrap(identityChanged.voiceDescriptors).map(\.referencePrimary), ["voice-1", "voice-2"])
    }

    func testPreparedVoiceTraversalHasExplicitDepthAndNodeBudgets() {
        struct Node: Equatable {
            let value: Int
            let children: [Node]
        }
        let tree = Node(
            value: 0,
            children: [Node(value: 1, children: [Node(value: 2, children: [Node(value: 3, children: [])])])]
        )

        let result = ChatPreparedVoiceTraversal.prepare(
            roots: [tree],
            budget: ChatPreparedVoiceTraversalBudget(maxDepth: 2, maxVisitedNodes: 2),
            children: \.children,
            descriptors: { [$0.value] }
        )

        XCTAssertEqual(result.descriptors, [0, 1])
        XCTAssertEqual(result.visitedNodeCount, 2)
        XCTAssertTrue(result.didReachBudget)
    }

    func testMovingObserverBurstFlushesNewestGenerationExactlyOnceAtRest() {
        var coalescer = ChatObserverRefreshGenerationCoalescer()

        for generation in UInt64(1)...UInt64(1_000) {
            XCTAssertEqual(
                coalescer.receive(generation: generation, motionState: .decelerating),
                .deferred
            )
        }

        XCTAssertNil(coalescer.flush(motionState: .dragging))
        XCTAssertEqual(coalescer.flush(motionState: .resting), 1_000)
        XCTAssertNil(coalescer.flush(motionState: .resting))
        XCTAssertEqual(coalescer.committedGenerationCount, 1)
    }

    func testFrameBudgetReportsForbiddenAndUnboundedWork() {
        let diagnostics = ChatScrollFrameDiagnostics(
            visibleRowVisits: 13,
            storeQueryCount: 1,
            textMeasurementCount: 1,
            layoutMeasurementCount: 1,
            floatingDateUpdateCount: 0,
            voiceDescriptorBuildCount: 0,
            voiceQueueUpdateCount: 0
        )

        XCTAssertFalse(diagnostics.isWithinBudget(maxVisibleRows: 12))
        XCTAssertEqual(
            diagnostics.violations(maxVisibleRows: 12),
            [.visibleRows, .storeQuery, .textMeasurement, .layoutMeasurement]
        )
    }

    func testScrollExecutionSourceContainsNoStoreFullMapFormattingOrRecursiveVoiceWork() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let prefetchSource = try String(contentsOf: root.appendingPathComponent(
            "xabber/controllers/chats/chat/datasource/ChatViewController+PrefetchDatasource.swift"
        ))
        let controllerSource = try String(contentsOf: root.appendingPathComponent(
            "xabber/controllers/chats/chat/ChatViewController.swift"
        ))
        let execution = try XCTUnwrap(functionBody(named: "performCoalescedScrollWork", in: prefetchSource))
        let boundaryDecision = try XCTUnwrap(functionBody(named: "interactiveBoundaryPagingDirection", in: prefetchSource))
        let boundarySubmission = try XCTUnwrap(functionBody(named: "requestTimelineBoundaryIfNeeded", in: prefetchSource))

        ["WRealm.safe", "ChatLocalHistoryPageProvider", "orderedViewportReadMessages", "DateFormatter", "layoutIfNeeded", "sizeThatFits", "voiceMessageDescriptors("].forEach {
            XCTAssertFalse(execution.contains($0), "forbidden scroll-frame work: \($0)")
        }
        [boundaryDecision, boundarySubmission].forEach { source in
            ["WRealm.safe", "ChatLocalHistoryPageProvider", "datasource.contains", "collectionViewLayout", "ChatArchiveDebugTrace"].forEach {
                XCTAssertFalse(source.contains($0), "forbidden boundary-frame work: \($0)")
            }
        }
        XCTAssertTrue(
            boundarySubmission.contains("requestTimelineBoundary(direction:"),
            "The bounded scroll decision must enter the single local-first timeline gateway"
        )
        XCTAssertFalse(
            boundarySubmission.contains("submitArchiveEnginePage("),
            "Scroll-frame work must never bypass verified local paging with direct MAM"
        )
        XCTAssertFalse(
            prefetchSource.contains("shortContentRemotePagingSuppressionContext"),
            "The deleted legacy boundary planner must not return through a frame-budget helper"
        )
        XCTAssertFalse(controllerSource.contains("attachment.subforwards.forEach {\n            descriptors.append(contentsOf: voiceMessageDescriptors"))
        XCTAssertFalse(controllerSource.contains("for forward in attachment.subforwards"))
    }

    private func request(visible: ChatScrollVisibleMetadata) -> ChatScrollWorkRequest {
        ChatScrollWorkRequest(
            contentOffsetY: 10,
            gestureTranslationY: -10,
            isUserScrolling: true,
            visibleIndexPaths: visible.rows.map { IndexPath(item: 0, section: $0.section) },
            visibleMetadata: visible,
            work: [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue, .evaluateBoundaryPaging]
        )
    }

    private func residentMetadata(
        rowCount: Int,
        firstRealSection: Int = 0,
        lastRealSection: Int? = nil
    ) -> ChatScrollResidentMetadata {
        let last = lastRealSection ?? max(0, rowCount - 1)
        return ChatScrollResidentMetadata(
            generation: 1,
            rows: (0..<rowCount).map { visibleRow(section: $0, ordinal: $0) },
            firstRealSection: firstRealSection,
            lastRealSection: last
        )
    }

    private func metadata(rows: [ChatScrollVisibleRow]) -> ChatScrollVisibleMetadata {
        ChatScrollVisibleMetadata(
            generation: 1,
            residentRowCount: max(rows.count, 10),
            rows: rows,
            boundaryContext: boundaryContext(
                first: rows.map(\.section).min(),
                last: rows.map(\.section).max(),
                visible: rows.map(\.section)
            )
        )
    }

    private func boundaryContext(
        first: Int?,
        last: Int?,
        visible: [Int]
    ) -> ChatHistoryPagingBoundaryContext {
        ChatHistoryPagingBoundaryContext(
            firstRealSection: first,
            lastRealSection: last,
            visibleRealSections: visible
        )
    }

    private func visibleRow(
        section: Int,
        ordinal: Int,
        isRead: Bool = true,
        day: Int = 10,
        isFakeMessage: Bool = false,
        voices: [VoiceMessageDescriptor] = []
    ) -> ChatScrollVisibleRow {
        let date = Date(timeIntervalSince1970: TimeInterval(day * 86_400 + ordinal))
        return ChatScrollVisibleRow(
            section: section,
            primary: "primary-\(ordinal)",
            position: ChatTimelinePositionKey(
                primary: "primary-\(ordinal)",
                archivedId: "\(ordinal)",
                messageId: "message-\(ordinal)",
                date: date
            ),
            isOutgoing: false,
            isRead: isRead,
            rowKind: .message,
            isFakeMessage: isFakeMessage,
            sentDate: date,
            voiceDescriptors: voices
        )
    }

    private func voiceDescriptor(primary: String, downloaded: Bool) -> VoiceMessageDescriptor {
        VoiceMessageDescriptor(
            referencePrimary: primary,
            containerMessagePrimary: "container-\(primary)",
            remoteURL: URL(string: "https://example.org/\(primary).ogg"),
            decodedURL: downloaded ? URL(fileURLWithPath: "/tmp/\(primary).m4a") : nil,
            duration: 12,
            downloaded: downloaded,
            pcm: [0.1],
            sentDate: Date(timeIntervalSince1970: 1)
        )
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let nameRange = source.range(of: "func \(name)") else { return nil }
        guard let openingBrace = source[nameRange.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
