import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchPerformanceTests: XCTestCase {
    private enum Budget {
        static let purePreparationMilliseconds = 50.0
        static let snapshotModelMilliseconds = 100.0
        static let mainApplyMilliseconds = 100.0
        static let maximumScalingRatio = 2.5
    }

    func testMeasuredBaselineForOneAndTwoThousandResultPreparation() {
        let oneThousand = makeIncomingResults(uniqueCount: 1_000)
        let twoThousand = makeIncomingResults(uniqueCount: 2_000)

        let oneThousandSamples = samples {
            let prepared = ChatSearchResultCollection.orderedAndDeduplicated(oneThousand)
            XCTAssertEqual(prepared.count, 1_000)
        }
        let twoThousandSamples = samples {
            let prepared = ChatSearchResultCollection.orderedAndDeduplicated(twoThousand)
            XCTAssertEqual(prepared.count, 2_000)
        }
        let oneThousandMedian = median(oneThousandSamples)
        let twoThousandMedian = median(twoThousandSamples)
        let ratio = twoThousandMedian / max(oneThousandMedian, 0.001)

        printPerformance(
            "baseline.prepare",
            values: [
                "1000_median_ms": oneThousandMedian,
                "2000_median_ms": twoThousandMedian,
                "scaling_ratio": ratio
            ]
        )
        XCTAssertLessThan(oneThousandMedian, Budget.purePreparationMilliseconds)
        XCTAssertLessThanOrEqual(ratio, Budget.maximumScalingRatio)
    }

    func testMeasuredBaselineForSnapshotModelAndSynchronousMainApply() {
        let results = ChatSearchResultCollection.orderedAndDeduplicated(
            makeIncomingResults(uniqueCount: 1_000)
        )
        let preparedResults = ChatSearchPreparedResults(results)
        let previous = Array(results.prefix(750))
        let anchor = ChatSearchResultsListScrollAnchor(
            id: previous[400].id,
            offsetFromTop: 11.5
        )
        let snapshotSamples = samples {
            let plan = ChatSearchResultsListSnapshotPlan.make(
                previous: previous,
                preparedIncoming: preparedResults,
                visibleAnchor: anchor
            )
            XCTAssertEqual(plan.itemIDs.count, 1_000)
            XCTAssertEqual(plan.retainedAnchor, anchor)
        }

        let controller = ChatSearchResultsListViewController()
        controller.loadViewIfNeeded()
        controller.render(makeModel(results: previous, phase: .loadingNextPage))
        let preparedModel = ChatSearchResultsListRenderModel(
            generation: 25,
            preparedResults: preparedResults,
            selectedID: preparedResults.results.first?.id,
            phase: .populated
        )
        let applySamples = samples(iterations: 5) {
            XCTAssertTrue(Thread.isMainThread)
            controller.render(preparedModel)
        }
        let snapshotMedian = median(snapshotSamples)
        let applyMaximum = applySamples.max() ?? .infinity

        printPerformance(
            "optimized.snapshot",
            values: [
                "model_median_ms": snapshotMedian,
                "main_apply_max_ms": applyMaximum
            ]
        )
        XCTAssertLessThan(snapshotMedian, Budget.snapshotModelMilliseconds)
        XCTAssertLessThan(applyMaximum, Budget.mainApplyMilliseconds)
    }

    func testFourIncrementalPagesRetainAnchorAndNeverReconfigureUnchangedRows() {
        let allResults = ChatSearchResultCollection.orderedAndDeduplicated(
            makeIncomingResults(uniqueCount: 1_000, includeDuplicates: false)
        )
        let anchor = ChatSearchResultsListScrollAnchor(
            id: allResults[100].id,
            offsetFromTop: 9.25
        )
        var previous: [ChatSearchResult] = []

        for page in 1...4 {
            let incoming = Array(allResults.prefix(page * 250))
            let plan = ChatSearchResultsListSnapshotPlan.make(
                previous: previous,
                incoming: incoming,
                visibleAnchor: page == 1 ? nil : anchor
            )
            XCTAssertEqual(plan.itemIDs.count, page * 250)
            XCTAssertTrue(plan.reconfiguredIDs.isEmpty)
            if page > 1 {
                XCTAssertEqual(plan.retainedAnchor, anchor)
            }
            previous = incoming
        }
    }

    func testPreparedResultsAreNormalizedOnceAndReusedByModelPlanAndController() {
        let incoming = makeIncomingResults(uniqueCount: 1_000)
        let expected = ChatSearchResultCollection.orderedAndDeduplicated(incoming)
        let prepared = ChatSearchPreparedResults(incoming)
        let model = ChatSearchResultsListRenderModel(
            generation: 25,
            preparedResults: prepared,
            selectedID: prepared.results.first?.id,
            phase: .populated
        )
        let plan = ChatSearchResultsListSnapshotPlan.make(
            previous: [],
            preparedIncoming: prepared,
            visibleAnchor: nil
        )
        let controller = ChatSearchResultsListViewController()
        controller.loadViewIfNeeded()
        controller.render(model)

        XCTAssertEqual(prepared.results, expected)
        XCTAssertTrue(model.preparedResults === prepared)
        XCTAssertEqual(plan.itemIDs, expected.map(\.id))
        XCTAssertTrue(controller.lastAppliedPreparedResults === prepared)
    }

    func testVisibleBodyHighlightCacheDoesNotRecomputeUnchangedQueryAndModel() {
        let cache = ChatSearchHighlightCache(countLimit: 128)
        let style = ChatSearchHighlightStyle.telegram(
            for: UITraitCollection(userInterfaceStyle: .light)
        )
        let visibleBodies = (0..<100).map { index in
            NSAttributedString(
                string: "visible \(index) " + String(repeating: "test content ", count: 32)
            )
        }

        let firstPass = visibleBodies.map {
            cache.applying(to: $0, query: "test", style: style)
        }
        XCTAssertEqual(cache.computationCount, 100)
        let secondPass = visibleBodies.map {
            cache.applying(to: $0, query: "test", style: style)
        }

        XCTAssertEqual(cache.computationCount, 100)
        XCTAssertEqual(firstPass, secondPass)
        _ = cache.applying(to: visibleBodies[0], query: "content", style: style)
        XCTAssertEqual(cache.computationCount, 101)
    }

    func testPreparationRunsOffMainAndOnlyUIKitApplyReturnsToMain() async {
        let incoming = makeIncomingResults(uniqueCount: 1_000)
        let prepared = await Task.detached(priority: .userInitiated) {
            XCTAssertFalse(Thread.isMainThread)
            return ChatSearchPreparedResults(incoming)
        }.value

        XCTAssertTrue(Thread.isMainThread)
        let controller = ChatSearchResultsListViewController()
        controller.loadViewIfNeeded()
        controller.render(ChatSearchResultsListRenderModel(
            generation: 25,
            preparedResults: prepared,
            selectedID: prepared.results.first?.id,
            phase: .populated
        ))
        XCTAssertTrue(controller.lastAppliedPreparedResults === prepared)
    }

    func testAvatarWorkStartsOnlyForConfiguredCellAndCancelsOnReuse() {
        let loader = PerformanceAvatarLoader()
        let result = makeResult(index: 1, complete: true)
        let prepared = ChatSearchPreparedResults([result])

        _ = ChatSearchResultsListSnapshotPlan.make(
            previous: [],
            preparedIncoming: prepared,
            visibleAnchor: nil
        )
        XCTAssertEqual(loader.loadCount, 0)

        let cell = ChatSearchResultCell(avatarLoader: loader)
        cell.configure(with: result)
        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertFalse(loader.cancellation.isCancelled)

        cell.prepareForReuse()
        XCTAssertTrue(loader.cancellation.isCancelled)
    }

    func testXCTClockMetricExcludesNetworkAndAnimationFromPurePreparation() {
        let incoming = makeIncomingResults(uniqueCount: 1_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            autoreleasepool {
                let prepared = ChatSearchResultCollection.orderedAndDeduplicated(incoming)
                XCTAssertEqual(prepared.count, 1_000)
            }
        }
    }

    private func makeModel(
        results: [ChatSearchResult],
        phase: ChatSearchResultsListRenderModel.Phase
    ) -> ChatSearchResultsListRenderModel {
        ChatSearchResultsListRenderModel(
            generation: 25,
            results: results,
            selectedID: results.first?.id,
            phase: phase
        )
    }

    private func makeIncomingResults(
        uniqueCount: Int,
        includeDuplicates: Bool = true
    ) -> [ChatSearchResult] {
        let results = (0..<uniqueCount).map { index in
            makeResult(index: index, complete: true)
        }
        guard includeDuplicates else {
            return Array(results.reversed())
        }
        let duplicates = stride(from: 0, to: uniqueCount, by: 4).map { index in
            makeResult(index: index, complete: false)
        }
        return Array((results + duplicates).reversed())
    }

    private func makeResult(index: Int, complete: Bool) -> ChatSearchResult {
        let id = String(index)
        let body = complete
            ? "test long detached body \(index) " + String(repeating: "content ", count: 24)
            : ""
        return ChatSearchResult(
            id: .archived(id),
            scope: ChatSearchResult.Scope(
                owner: "owner@example.com",
                jid: "peer@example.com",
                conversationTypeRawValue: "regular"
            ),
            anchor: ChatSearchResult.Anchor(
                primary: complete ? "primary-\(index)" : "",
                archivedId: id,
                messageId: complete ? "message-\(index)" : "",
                authorId: nil,
                date: Date(timeIntervalSince1970: TimeInterval(index))
            ),
            outgoing: index.isMultiple(of: 2),
            senderTitle: complete ? "Andrew" : "",
            body: body,
            snippet: body,
            deliveryState: complete ? .read : .pending,
            avatar: ChatSearchResult.Avatar(
                identity: "avatar-\(index)",
                fallbackTitle: "Andrew",
                url: complete ? "https://example.com/\(index).jpg" : nil,
                source: .contact(jid: "peer@example.com", owner: "owner@example.com")
            )
        )
    }

    private func samples(
        iterations: Int = 9,
        operation: () -> Void
    ) -> [Double] {
        (0..<iterations).map { _ in
            let started = ProcessInfo.processInfo.systemUptime
            autoreleasepool(invoking: operation)
            return (ProcessInfo.processInfo.systemUptime - started) * 1_000
        }
    }

    private func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func printPerformance(_ label: String, values: [String: Double]) {
        let details = values.keys.sorted().map { key in
            "\(key)=\(String(format: "%.3f", values[key] ?? 0))"
        }.joined(separator: " ")
        print("CHAT_SEARCH_PERF \(label) \(details)")
    }
}

private final class PerformanceAvatarLoader: ChatSearchResultAvatarLoading {
    final class Cancellation: ChatSearchResultAvatarLoadCancelling {
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    let cancellation = Cancellation()
    private(set) var loadCount = 0

    func loadAvatar(
        for avatar: ChatSearchResult.Avatar,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatSearchResultAvatarLoadCancelling? {
        loadCount += 1
        return cancellation
    }
}
