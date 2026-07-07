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
    private static let composerActionGlyphDimension: CGFloat = 24

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

    func testComposerSendButtonImagesUseRequestedActionGlyphSize() throws {
        let recordImage = try XCTUnwrap(ModernXabberInputView.composerSendButtonImage(for: .record))
        let sendImage = try XCTUnwrap(ModernXabberInputView.composerSendButtonImage(for: .send))

        XCTAssertEqual(max(recordImage.size.width, recordImage.size.height), Self.composerActionGlyphDimension, accuracy: 0.001)
        XCTAssertEqual(max(sendImage.size.width, sendImage.size.height), Self.composerActionGlyphDimension, accuracy: 0.001)
    }

    func testComposerSendButtonImagesUseSameGlyphBox() throws {
        let expectedGlyphDimension = Self.composerActionGlyphDimension
        let recordImage = try XCTUnwrap(ModernXabberInputView.composerSendButtonImage(for: .record))
        let sendImage = try XCTUnwrap(ModernXabberInputView.composerSendButtonImage(for: .send))
        let recordAlphaBounds = try alphaBounds(of: recordImage)
        let sendAlphaBounds = try alphaBounds(of: sendImage)

        XCTAssertEqual(recordImage.size.width, expectedGlyphDimension, accuracy: 0.001)
        XCTAssertEqual(recordImage.size.height, expectedGlyphDimension, accuracy: 0.001)
        XCTAssertEqual(sendImage.size.width, expectedGlyphDimension, accuracy: 0.001)
        XCTAssertEqual(sendImage.size.height, expectedGlyphDimension, accuracy: 0.001)
        XCTAssertEqual(
            max(recordAlphaBounds.width, recordAlphaBounds.height),
            max(sendAlphaBounds.width, sendAlphaBounds.height),
            accuracy: 1
        )
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
        XCTAssertEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.composerActionGlyphDimension, accuracy: 0.001)
        XCTAssertTrue(inputView.sendButton.tintColor.isEqual(UIColor.secondaryLabel))

        inputView.changeSendButtonState(to: .send)

        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertEqual(inputView.sendButton.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(inputView.sendButton.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.composerActionGlyphDimension, accuracy: 0.001)
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
            XCTAssertEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.composerActionGlyphDimension, accuracy: 0.001)

            inputView.changeSendButtonState(to: .record)
            XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
            XCTAssertEqual(try buttonGlyphMaxDimension(inputView.sendButton), Self.composerActionGlyphDimension, accuracy: 0.001)
        }
    }

    private func buttonGlyphImage(_ button: UIButton) -> UIImage? {
        button.image(for: .normal) ?? button.configuration?.image
    }

    private func buttonGlyphMaxDimension(_ button: UIButton) throws -> CGFloat {
        let image = try XCTUnwrap(buttonGlyphImage(button))
        return max(image.size.width, image.size.height)
    }

    private func alphaBounds(of image: UIImage) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Unable to create bitmap context")
            return .zero
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                guard alpha > 0 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            XCTFail("Image has no visible alpha")
            return .zero
        }

        let scale = image.scale
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }
}
