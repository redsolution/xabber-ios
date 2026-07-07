import XCTest
@testable import xabber

final class ChatComposerFrameUpdateTests: XCTestCase {
    func testComposerOnlyFrameChangeNeverRequestsReload() {
        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .containerBounds,
                hasMessages: true,
                previousInputHeight: 64,
                inputHeight: 120,
                anchorRestoration: .bottom
            )
        )

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertTrue(actions.contains(.invalidateLayoutCache))
        XCTAssertTrue(actions.contains(.invalidateLayout))
        XCTAssertTrue(actions.contains(.layoutIfNeeded))
    }

    func testComposerHeightIncreasePreservesBottomAnchorAfterLayout() throws {
        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .composerHeight,
                hasMessages: true,
                previousInputHeight: 44,
                inputHeight: 112,
                anchorRestoration: .bottom
            )
        )

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertFalse(actions.contains(.invalidateLayoutCache))
        XCTAssertFalse(actions.contains(.invalidateLayout))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .layoutIfNeeded)),
            try XCTUnwrap(actions.firstIndex(of: .scrollToBottom))
        )
    }

    func testComposerHeightIncreasePreservesVisibleAnchorWhenReadingHistory() throws {
        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .composerHeight,
                hasMessages: true,
                previousInputHeight: 44,
                inputHeight: 112,
                anchorRestoration: .visibleAnchor
            )
        )

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertFalse(actions.contains(.scrollToBottom))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .layoutIfNeeded)),
            try XCTUnwrap(actions.firstIndex(of: .restoreVisibleAnchor))
        )
    }

    func testKeyboardFrameChangeUsesSingleLayoutPassWithoutInvalidatingMessages() {
        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .keyboardFrame,
                hasMessages: true,
                previousInputHeight: 88,
                inputHeight: 280,
                anchorRestoration: .bottom
            )
        )

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertFalse(actions.contains(.invalidateLayoutCache))
        XCTAssertFalse(actions.contains(.invalidateLayout))
        XCTAssertFalse(actions.contains(.scrollToBottom))
        XCTAssertEqual(actions.filter { $0 == .layoutIfNeeded }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .updateInsets(280) }.count, 2)
    }
}
