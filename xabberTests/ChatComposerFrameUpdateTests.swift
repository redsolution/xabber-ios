import UIKit
import XCTest
@testable import xabber

final class ChatComposerFrameUpdateTests: XCTestCase {
    func testStickerPanelReplacesComposerAndKeyboardObstruction() {
        let metrics = ChatComposerKeyboardLayoutMetrics.make(
            visualHeight: 64,
            visibleKeyboardHeight: 320,
            bottomSafeAreaHeight: 34,
            searchOwnsKeyboard: false,
            stickerPanelHeight: 300
        )

        XCTAssertEqual(metrics.visualHeight, 64)
        XCTAssertEqual(metrics.collectionObstructionHeight, 334)
    }

    func testStickerPanelUsesDockedKeyboardHeightWithoutRepeatingSafeArea() {
        XCTAssertEqual(ChatStickerPanelLayout.contentHeight(
            viewHeight: 844,
            topSafeAreaHeight: 90,
            bottomSafeAreaHeight: 34,
            dockedKeyboardHeight: 334
        ), 300)
    }

    func testStickerPanelAdaptsToShortWindowAfterRotation() {
        let height = ChatStickerPanelLayout.contentHeight(
            viewHeight: 390,
            topSafeAreaHeight: 44,
            bottomSafeAreaHeight: 21,
            dockedKeyboardHeight: 334
        )

        XCTAssertLessThanOrEqual(height, 180)
        XCTAssertGreaterThan(height, 120)
    }

    func testStickerPanelDoesNotLearnFloatingOrHardwareKeyboardHeight() {
        let bounds = CGRect(x: 0, y: 0, width: 770, height: 980)
        XCTAssertNil(ChatStickerPanelLayout.dockedKeyboardHeight(
            in: bounds,
            keyboardFrame: CGRect(x: 180, y: 730, width: 280, height: 250)
        ))
        XCTAssertNil(ChatStickerPanelLayout.dockedKeyboardHeight(
            in: bounds,
            keyboardFrame: CGRect(x: 0, y: 920, width: 770, height: 60)
        ))
        XCTAssertEqual(ChatStickerPanelLayout.dockedKeyboardHeight(
            in: bounds,
            keyboardFrame: CGRect(x: 0, y: 670, width: 770, height: 310)
        ), 310)
    }

    func testStickerPanelRestoresVisibleHistoryAnchorWithoutReloading() throws {
        let actions = ChatComposerFrameUpdatePlanner.actions(for: .init(
            source: .stickerPanel,
            hasMessages: true,
            previousInputHeight: 64,
            inputHeight: 300,
            anchorRestoration: .visibleAnchor
        ))

        XCTAssertFalse(actions.contains(.reloadData))
        XCTAssertFalse(actions.contains(.scrollToBottom))
        XCTAssertFalse(actions.contains(.preserveViewportForInsetChange))
        XCTAssertLessThan(
            try XCTUnwrap(actions.firstIndex(of: .updateInsets(300))),
            try XCTUnwrap(actions.firstIndex(of: .restoreVisibleAnchor))
        )
    }

    @MainActor
    func testChatEmbedsStickerPanelAndPreservesDraftAcrossToggle() throws {
        let chat = makeStickerChat()
        defer { chat.performTerminalChatResourceTeardownForTesting() }
        let input = chat.xabberInputView!
        let draft = NSAttributedString(string: "Draft",
                                       attributes: [.font: UIFont.boldSystemFont(ofSize: 16)])
        input.textField.attributedText = draft
        let selection = NSRange(location: 2, length: 0)
        input.textField.selectedRange = selection
        let originalInset = chat.messagesCollectionView.contentInset.bottom

        chat.stickerPickerButtonTouchUp()

        let panel = try XCTUnwrap(chat.inlineStickerPanel)
        XCTAssertTrue(panel.parent === chat)
        XCTAssertNil(chat.presentedViewController)
        XCTAssertTrue(input.isHidden)
        XCTAssertGreaterThan(chat.messagesCollectionView.contentInset.bottom, originalInset)

        chat.setInlineStickerPanelVisible(false, animated: false)

        XCTAssertFalse(input.isHidden)
        XCTAssertEqual(input.textField.attributedText, draft)
        XCTAssertEqual(input.textField.selectedRange, selection)
        XCTAssertEqual(chat.messagesCollectionView.contentInset.bottom, originalInset, accuracy: 0.5)
    }

    @MainActor
    func testStickerPanelSurvivesSettingsAndDetachesWhenChatChanges() throws {
        let chat = makeStickerChat()
        let navigation = UINavigationController(rootViewController: chat)
        defer { chat.performTerminalChatResourceTeardownForTesting() }
        chat.stickerPickerButtonTouchUp()
        let panel = try XCTUnwrap(chat.inlineStickerPanel)
        let settings = ChatStickerPackSettingsViewController(owner: chat.owner)
        chat.stickerPackSettingsController = settings
        navigation.pushViewController(settings, animated: false)

        chat.performTerminalChatResourceTeardownForTesting()
        navigation.popViewController(animated: false)

        XCTAssertTrue(chat.inlineStickerPanel === panel)
        XCTAssertTrue(chat.isInlineStickerPanelVisible)

        chat.jid = "other-sticker-chat@example.com"

        XCTAssertNil(chat.inlineStickerPanel)
        XCTAssertNil(panel.parent)
        XCTAssertFalse(chat.xabberInputView.isHidden)
    }

    @MainActor
    private func makeStickerChat() -> ChatViewController {
        let chat = ChatViewController()
        chat.owner = "sticker-owner@example.com"
        chat.jid = "sticker-contact@example.com"
        chat.conversationType = .regular
        chat.ownerSender = Sender(id: chat.owner, displayName: "Owner")
        chat.opponentSender = Sender(id: chat.jid, displayName: "Contact")
        chat.showSkeletonObserver.accept(false)
        chat.loadViewIfNeeded()
        chat.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        chat.view.layoutIfNeeded()
        return chat
    }

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
