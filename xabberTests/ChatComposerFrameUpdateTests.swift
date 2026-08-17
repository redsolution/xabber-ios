import XCTest
@testable import xabber

final class ChatComposerFrameUpdateTests: XCTestCase {
    func testNormalComposerMetricsSeparateVisualHeightFromKeyboardObstruction() {
        let visualHeight: CGFloat = 64
        let bottomSafeAreaHeight: CGFloat = 34
        let cases: [(keyboardOverlap: CGFloat, expectedObstruction: CGFloat)] = [
            (300, 364),
            (164, 228),
            (84, 148),
            (0, 98)
        ]

        for testCase in cases {
            let metrics = ChatComposerKeyboardLayoutMetrics.make(
                visualHeight: visualHeight,
                visibleKeyboardHeight: testCase.keyboardOverlap,
                bottomSafeAreaHeight: bottomSafeAreaHeight,
                searchOwnsKeyboard: false
            )

            XCTAssertEqual(metrics.visualHeight, visualHeight, accuracy: 0.001)
            XCTAssertEqual(
                metrics.collectionObstructionHeight,
                testCase.expectedObstruction,
                accuracy: 0.001,
                "Unexpected collection obstruction for keyboard overlap \(testCase.keyboardOverlap)"
            )
        }
    }

    func testSearchComposerMetricsDoNotAppendKeyboardOrSafeAreaTail() {
        let metrics = ChatComposerKeyboardLayoutMetrics.make(
            visualHeight: 64,
            visibleKeyboardHeight: 300,
            bottomSafeAreaHeight: 34,
            searchOwnsKeyboard: true
        )

        XCTAssertEqual(metrics.visualHeight, 64, accuracy: 0.001)
        XCTAssertEqual(metrics.collectionObstructionHeight, 64, accuracy: 0.001)
    }

    func testComposerKeyboardMetricsClampNegativeGeometry() {
        let metrics = ChatComposerKeyboardLayoutMetrics.make(
            visualHeight: -64,
            visibleKeyboardHeight: -300,
            bottomSafeAreaHeight: -34,
            searchOwnsKeyboard: false
        )

        XCTAssertEqual(metrics.visualHeight, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.collectionObstructionHeight, 0, accuracy: 0.001)
    }

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
        XCTAssertFalse(actions.contains(.preserveViewportForInsetChange))
        XCTAssertTrue(actions.contains(.alignBottomToCurrentInsets))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .updateInsets(280))),
            try XCTUnwrap(actions.firstIndex(of: .alignBottomToCurrentInsets))
        )
        XCTAssertEqual(actions.filter { $0 == .updateInsets(280) }.count, 1)
    }

    func testKeyboardFrameChangeAwayFromBottomSkipsSynchronousAnchorWork() throws {
        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .keyboardFrame,
                hasMessages: true,
                previousInputHeight: 88,
                inputHeight: 280,
                anchorRestoration: .none
            )
        )

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertFalse(actions.contains(.invalidateLayoutCache))
        XCTAssertFalse(actions.contains(.invalidateLayout))
        XCTAssertFalse(actions.contains(.layoutIfNeeded))
        XCTAssertFalse(actions.contains(.restoreVisibleAnchor))
        XCTAssertTrue(actions.contains(.preserveViewportForInsetChange))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .updateInsets(280))),
            try XCTUnwrap(actions.firstIndex(of: .preserveViewportForInsetChange))
        )
        XCTAssertEqual(actions.filter { $0 == .updateInsets(280) }.count, 1)
    }

    func testKeyboardViewportOffsetTracksBottomInsetOnOpenAndHide() {
        let openInsets = UIEdgeInsets(top: 96, left: 0, bottom: 364, right: 0)
        let openedOffset = ChatKeyboardViewportOffsetPolicy.targetContentOffsetY(
            previousContentOffsetY: 620,
            previousBottomInset: 64,
            contentHeight: 1_600,
            viewportHeight: 844,
            newContentInsets: openInsets
        )

        XCTAssertEqual(openedOffset, 920, accuracy: 0.001)

        let closedOffset = ChatKeyboardViewportOffsetPolicy.targetContentOffsetY(
            previousContentOffsetY: openedOffset,
            previousBottomInset: openInsets.bottom,
            contentHeight: 1_600,
            viewportHeight: 844,
            newContentInsets: UIEdgeInsets(top: 96, left: 0, bottom: 64, right: 0)
        )

        XCTAssertEqual(closedOffset, 620, accuracy: 0.001)
    }

    func testKeyboardViewportOffsetKeepsShortContentAtNewBottomAlignedMinimum() {
        let targetOffset = ChatKeyboardViewportOffsetPolicy.targetContentOffsetY(
            previousContentOffsetY: -600,
            previousBottomInset: 64,
            contentHeight: 180,
            viewportHeight: 844,
            newContentInsets: UIEdgeInsets(top: 300, left: 0, bottom: 364, right: 0)
        )

        XCTAssertEqual(targetOffset, -300, accuracy: 0.001)
    }

    func testKeyboardViewportOffsetClampsToNewScrollableBounds() {
        XCTAssertEqual(
            ChatKeyboardViewportOffsetPolicy.targetContentOffsetY(
                previousContentOffsetY: 1_500,
                previousBottomInset: 64,
                contentHeight: 1_600,
                viewportHeight: 844,
                newContentInsets: UIEdgeInsets(top: 96, left: 0, bottom: 364, right: 0)
            ),
            1_120,
            accuracy: 0.001
        )
    }

    func testKeyboardViewportOffsetDoesNotClampWhenBottomInsetIsUnchanged() {
        XCTAssertEqual(
            ChatKeyboardViewportOffsetPolicy.targetContentOffsetY(
                previousContentOffsetY: 1_500,
                previousBottomInset: 64,
                contentHeight: 1_600,
                viewportHeight: 844,
                newContentInsets: UIEdgeInsets(top: 96, left: 0, bottom: 64, right: 0)
            ),
            1_500,
            accuracy: 0.001
        )
    }
}
