import XCTest
@testable import xabber

final class ChatPerformanceSignpostTests: XCTestCase {
    func testPhaseNamesAreStableAndNonPrivate() {
        XCTAssertEqual(
            ChatPerformanceSignpostPhase.allCases.map(\.rawValue),
            [
                "chat.open_to_first_frame",
                "chat.map_dataset",
                "chat.datasource_diff",
                "chat.datasource_apply",
                "chat.layout_apply",
                "chat.scroll_processing",
                "chat.send_to_local_row"
            ]
        )

        let privateTokens = ["owner", "jid", "body", "account", "token", "private", "text"]
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
}
