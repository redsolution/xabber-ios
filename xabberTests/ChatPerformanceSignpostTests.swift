import XCTest
@testable import xabber

final class ChatPerformanceSignpostTests: XCTestCase {
    func testPhaseNamesAreStableAndNonPrivate() {
        XCTAssertEqual(
            ChatPerformanceSignpostPhase.allCases.map(\.rawValue),
            [
                "chat.open_request",
                "chat.local_snapshot_ready",
                "chat.first_content_committed",
                "chat.first_stable_frame",
                "chat.open_to_first_frame",
                "chat.map_dataset",
                "chat.datasource_diff",
                "chat.datasource_apply",
                "chat.layout_apply",
                "chat.scroll_processing",
                "chat.send_to_local_row",
                "chat.local_history_query",
                "chat.display_model_cache",
                "chat.observer_refresh",
                "chat.reference_prepare",
                "chat.media_prefetch",
                "chat.media_visible_hit",
                "chat.page_plan",
                "chat.page_query",
                "chat.page_persist",
                "chat.page_apply",
                "chat.anchor_received",
                "chat.anchor_resolved",
                "chat.anchor_centered",
                "chat.message_persistence"
            ]
        )

        let privateTokens = ChatPerformanceMetricSnapshot.privateTokenFragments
        for name in ChatPerformanceSignpostPhase.allCases.map(\.rawValue) {
            for token in privateTokens {
                XCTAssertFalse(name.localizedCaseInsensitiveContains(token), "\(name) contains private token \(token)")
            }
        }
    }

    func testMeasureReturnsBodyValue() {
        let value = ChatPerformanceSignposts.measure(.mapDataset) {
            "mapped"
        }

        XCTAssertEqual(value, "mapped")
    }

    func testMeasurePropagatesThrownError() {
        enum SampleError: Error, Equatable {
            case expected
        }

        XCTAssertThrowsError(try ChatPerformanceSignposts.measure(.datasourceApply) {
            throw SampleError.expected
        }) { error in
            XCTAssertEqual(error as? SampleError, .expected)
        }
    }

    func testIntervalEndIsIdempotent() {
        var interval = ChatPerformanceSignposts.begin(.scrollProcessing)

        XCTAssertTrue(interval.isActive)
        XCTAssertTrue(interval.end())
        XCTAssertFalse(interval.isActive)
        XCTAssertFalse(interval.end())
    }

    func testPointEventAcceptsStableMilestonePhase() {
        ChatPerformanceSignposts.event(.firstContentCommitted)
    }

    func testMetricSnapshotsExposeOnlyPrivacySafeCounterFields() {
        let snapshot = ChatPerformanceMetricSnapshot(
            phase: .referencePrepare,
            counters: [
                "referenceCount": 3,
                "durationMs": 42,
                "slowReferenceCount": 1
            ]
        )

        XCTAssertEqual(snapshot.counter("referenceCount"), 3)
        XCTAssertTrue(snapshot.isPrivacySafe)
        XCTAssertTrue(snapshot.unsafeFieldNames.isEmpty)
        XCTAssertEqual(snapshot.sortedCounterNames, ["durationMs", "referenceCount", "slowReferenceCount"])
    }

    func testReferencePrepareMetricsDoNotStoreIdentifiersOrPaths() {
        let metrics = ChatReferencePrepareMetrics(
            referenceCount: 2,
            durationMs: 17,
            slowReferenceCount: 1
        )
        let snapshot = metrics.snapshot

        XCTAssertEqual(snapshot.phase, .referencePrepare)
        XCTAssertEqual(snapshot.counter("referenceCount"), 2)
        XCTAssertEqual(snapshot.counter("durationMs"), 17)
        XCTAssertEqual(snapshot.counter("slowReferenceCount"), 1)
        XCTAssertTrue(snapshot.isPrivacySafe)
        XCTAssertFalse(snapshot.sortedCounterNames.contains("url"))
        XCTAssertFalse(snapshot.sortedCounterNames.contains("path"))
        XCTAssertFalse(snapshot.sortedCounterNames.contains("body"))
        XCTAssertFalse(snapshot.sortedCounterNames.contains("token"))
    }
}
