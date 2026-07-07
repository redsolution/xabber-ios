//
//  ChatComposerSendButtonIconTests.swift
//  xabberTests
//
//  Created by Codex on 03.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
@testable import xabber

@MainActor
final class ChatComposerSendButtonIconTests: XCTestCase {
    private static let maxCompactGlyphDimension = NativeGlassBarStyle.buttonSize / 2

    func testTypingPolicySkipsLayoutAndControlAnimationForStableOneLineSendState() {
        let previousVisualState = ComposerTypingVisualState(
            sendButtonState: .send,
            timerHidden: true,
            scheduledMessagesVisible: false
        )
        let nextVisualState = ComposerTypingVisualState(
            sendButtonState: .send,
            timerHidden: true,
            scheduledMessagesVisible: false
        )

        let decision = ComposerTypingUpdatePolicy.decision(
            force: false,
            requiredContentHeight: ModernXabberInputView.minimumComposerHeight,
            currentContentHeight: ModernXabberInputView.minimumComposerHeight,
            previousVisualState: previousVisualState,
            nextVisualState: nextVisualState
        )

        XCTAssertFalse(decision.shouldInvalidateIntrinsicContentSize)
        XCTAssertFalse(decision.shouldUpdateControls)
    }

    func testTypingPolicyUpdatesControlsWhenComposerCrossesEmptyBoundary() {
        let previousVisualState = ComposerTypingVisualState(
            sendButtonState: .record,
            timerHidden: false,
            scheduledMessagesVisible: true
        )
        let nextVisualState = ComposerTypingVisualState(
            sendButtonState: .send,
            timerHidden: true,
            scheduledMessagesVisible: false
        )

        let decision = ComposerTypingUpdatePolicy.decision(
            force: false,
            requiredContentHeight: ModernXabberInputView.minimumComposerHeight,
            currentContentHeight: ModernXabberInputView.minimumComposerHeight,
            previousVisualState: previousVisualState,
            nextVisualState: nextVisualState
        )

        XCTAssertFalse(decision.shouldInvalidateIntrinsicContentSize)
        XCTAssertTrue(decision.shouldUpdateControls)
    }

    func testHiddenComposerPanelsDoNotStartWithZeroSizedConstraintHosts() {
        let inputView = ModernXabberInputView(frame: .zero)

        XCTAssertTrue(inputView.selectionPanel.isHidden)
        XCTAssertGreaterThanOrEqual(inputView.selectionPanel.bounds.width, NativeGlassBarStyle.buttonSize)
        XCTAssertGreaterThanOrEqual(inputView.selectionPanel.bounds.height, NativeGlassBarStyle.minimumHeight)
        XCTAssertTrue(inputView.searchPanel.isHidden)
        XCTAssertGreaterThanOrEqual(inputView.searchPanel.bounds.width, NativeGlassBarStyle.buttonSize)
        XCTAssertGreaterThanOrEqual(inputView.searchPanel.bounds.height, 38)
    }

    func testHiddenMentionPanelIsDetachedUntilSuggestionsAreShown() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let inputView = ModernXabberInputView(frame: CGRect(
            x: 0,
            y: 651,
            width: 390,
            height: ModernXabberInputView.defaultBarHeight
        ))

        host.addSubview(inputView)

        XCTAssertTrue(inputView.mentionPanel.isHidden)
        XCTAssertNil(inputView.mentionPanel.superview)
    }

    func testComposerSendButtonImagesStayCompact() throws {
        let recordImage = try XCTUnwrap(ModernXabberInputView.composerSendButtonImage(for: .record))
        let sendImage = try XCTUnwrap(ModernXabberInputView.composerSendButtonImage(for: .send))

        XCTAssertLessThanOrEqual(max(recordImage.size.width, recordImage.size.height), Self.maxCompactGlyphDimension)
        XCTAssertLessThanOrEqual(max(sendImage.size.width, sendImage.size.height), Self.maxCompactGlyphDimension)
    }

    func testChangeSendButtonStatePreservesGlyphTintAndTapTarget() throws {
        let inputView = ModernXabberInputView(frame: CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: ModernXabberInputView.defaultBarHeight
        ))
        inputView.layoutIfNeeded()

        inputView.isSendButtonEnabled = true
        inputView.changeSendButtonState(to: .record)

        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertEqual(inputView.sendButton.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(inputView.sendButton.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertLessThanOrEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.maxCompactGlyphDimension)
        XCTAssertTrue(inputView.sendButton.tintColor.isEqual(UIColor.secondaryLabel))

        inputView.changeSendButtonState(to: .send)

        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertEqual(inputView.sendButton.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(inputView.sendButton.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertLessThanOrEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.maxCompactGlyphDimension)
        XCTAssertTrue(inputView.sendButton.tintColor.isEqual(inputView.accountPalette.tint600))
        XCTAssertTrue(inputView.sendButton.isEnabled)

        inputView.isSendButtonEnabled = false
        inputView.changeSendButtonState(to: .send)

        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertFalse(inputView.sendButton.isEnabled)
        XCTAssertTrue(inputView.sendButton.tintColor.isEqual(UIColor.secondaryLabel))
    }

    func testRepeatedStateRefreshesDoNotDropSendButtonGlyph() throws {
        let inputView = ModernXabberInputView(frame: CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: ModernXabberInputView.defaultBarHeight
        ))
        inputView.layoutIfNeeded()
        inputView.isSendButtonEnabled = true

        for _ in 0..<3 {
            inputView.changeSendButtonState(to: .send)
            XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
            XCTAssertLessThanOrEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.maxCompactGlyphDimension)

            inputView.changeSendButtonState(to: .record)
            XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
            XCTAssertLessThanOrEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.maxCompactGlyphDimension)
        }
    }

    private func buttonGlyphImage(_ button: UIButton) -> UIImage? {
        button.image(for: .normal) ?? button.configuration?.image
    }

    private func buttonGlyphMaxDimension(_ button: UIButton) throws -> CGFloat {
        let image = try XCTUnwrap(buttonGlyphImage(button))
        return max(image.size.width, image.size.height)
    }
}
