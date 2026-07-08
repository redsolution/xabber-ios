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

    func testKeyboardFrameChangeAtBottomRealignsWithoutSynchronousMessageLayout() throws {
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
        XCTAssertFalse(actions.contains(.layoutIfNeeded))
        XCTAssertTrue(actions.contains(.alignBottomToCurrentInsets))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .updateInsets(280))),
            try XCTUnwrap(actions.firstIndex(of: .alignBottomToCurrentInsets))
        )
        XCTAssertEqual(actions.filter { $0 == .updateInsets(280) }.count, 1)
    }

    func testKeyboardFrameChangeKeepsLayoutBeforeVisibleAnchorRestore() throws {
        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .keyboardFrame,
                hasMessages: true,
                previousInputHeight: 88,
                inputHeight: 280,
                anchorRestoration: .visibleAnchor
            )
        )

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertFalse(actions.contains(.invalidateLayoutCache))
        XCTAssertFalse(actions.contains(.invalidateLayout))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .layoutIfNeeded)),
            try XCTUnwrap(actions.firstIndex(of: .restoreVisibleAnchor))
        )
        XCTAssertEqual(actions.filter { $0 == .updateInsets(280) }.count, 2)
    }
}
