//
//  ChatComposerRecordSendSeparationTests.swift
//  xabberTests
//
//  Created by Codex on 10.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatComposerRecordSendSeparationTests: XCTestCase {
    private var animationsWereEnabled = true

    override func setUp() {
        super.setUp()
        animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UIView.setAnimationsEnabled(animationsWereEnabled)
        super.tearDown()
    }

    func testEmptyComposerShowsExternalRecordAndHidesInFieldSend() throws {
        let inputView = makeInputView()
        let composerSurface = try XCTUnwrap(composerEffectView(containing: inputView.textField))

        XCTAssertEqual(inputView.currentComposerActionMode, .record)
        XCTAssertFalse(inputView.recordButton.isHidden)
        XCTAssertTrue(inputView.sendButton.isHidden)
        XCTAssertFalse(inputView.recordButton.isDescendant(of: composerSurface.contentView))
        XCTAssertTrue(inputView.sendButton.isDescendant(of: composerSurface.contentView))

        let composerFrame = composerSurface.convert(composerSurface.bounds, to: inputView)
        let recordFrame = inputView.recordButton.convert(inputView.recordButton.bounds, to: inputView)
        XCTAssertLessThanOrEqual(composerFrame.maxX, recordFrame.minX - 5.5)
    }

    func testWhitespaceOnlyComposerRemainsInRecordMode() {
        let inputView = makeInputView()
        inputView.shouldHideTimer = false
        XCTAssertFalse(inputView.timerButton.isHidden)

        inputView.textField.text = "  \n\t "
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()

        XCTAssertEqual(inputView.currentComposerActionMode, .record)
        XCTAssertFalse(inputView.recordButton.isHidden)
        XCTAssertTrue(inputView.sendButton.isHidden)
        XCTAssertTrue(inputView.timerButton.isHidden)
    }

    func testTextComposerExpandsAndShowsTransparentInFieldSend() throws {
        let inputView = makeInputView()

        inputView.textField.text = "Hello"
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()

        let composerSurface = try XCTUnwrap(composerEffectView(containing: inputView.textField))
        let composerFrame = composerSurface.convert(composerSurface.bounds, to: inputView)
        let sendFrame = inputView.sendButton.convert(inputView.sendButton.bounds, to: inputView)

        XCTAssertEqual(inputView.currentComposerActionMode, .textSend)
        XCTAssertTrue(inputView.recordButton.isHidden)
        XCTAssertFalse(inputView.sendButton.isHidden)
        XCTAssertTrue(inputView.sendButton.isDescendant(of: composerSurface.contentView))
        XCTAssertEqual(composerFrame.maxX, inputView.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(sendFrame.midX, inputView.bounds.maxX - NativeGlassBarStyle.buttonSize / 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(inputView.textField.frame.maxX, inputView.sendButton.frame.minX)
        XCTAssertEqual((inputView.sendButton.backgroundColor ?? .clear).cgColor.alpha, 0, accuracy: 0.001)
        XCTAssertNil(descendantEffectView(in: inputView.sendButton))
    }

    func testRapidEmptyBoundaryChangesFinishInLatestActionMode() {
        let inputView = makeInputView()

        inputView.textField.text = "First"
        inputView.textViewDidChange(force: true)
        inputView.textField.text = ""
        inputView.textViewDidChange(force: true)
        inputView.textField.text = "Latest"
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()

        XCTAssertEqual(inputView.currentComposerActionMode, .textSend)
        XCTAssertTrue(inputView.recordButton.isHidden)
        XCTAssertFalse(inputView.sendButton.isHidden)
        XCTAssertEqual(inputView.recordButton.transform, .identity)
        XCTAssertEqual(inputView.sendButton.transform, .identity)
    }

    func testStableLayoutDoesNotReintroduceInnerSendChrome() {
        let inputView = makeInputView()
        inputView.textField.text = "Stable"
        inputView.textViewDidChange(force: true)

        for _ in 0..<5 {
            inputView.setNeedsLayout()
            inputView.layoutIfNeeded()

            XCTAssertNil(inputView.sendButton.configuration)
            XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
            XCTAssertEqual(inputView.currentComposerActionMode, .textSend)
        }
    }

    func testStableLayoutKeepsComposerGlassSurfaceAndEffectKind() throws {
        let inputView = makeInputView()
        let composerSurface = try XCTUnwrap(composerEffectView(containing: inputView.textField))
        let initialEffect = try XCTUnwrap(composerSurface.effect)

        for _ in 0..<5 {
            inputView.setNeedsLayout()
            inputView.layoutIfNeeded()

            XCTAssertTrue(composerEffectView(containing: inputView.textField) === composerSurface)
            XCTAssertEqual(
                String(describing: type(of: try XCTUnwrap(composerSurface.effect))),
                String(describing: type(of: initialEffect))
            )
        }
    }

    func testMultilineTextKeepsTextSendModeAndCapsTextViewHeight() {
        let inputView = makeInputView()

        inputView.textField.text = Array(repeating: "Long composer line", count: 20).joined(separator: "\n")
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()

        XCTAssertEqual(inputView.currentComposerActionMode, .textSend)
        XCTAssertTrue(inputView.recordButton.isHidden)
        XCTAssertFalse(inputView.sendButton.isHidden)
        XCTAssertLessThanOrEqual(inputView.textField.bounds.height, inputView.maxTextViewHeight + 0.001)
        XCTAssertTrue(inputView.textField.isScrollEnabled)
    }

    func testReadinessDisablesBothActionsWithoutDisablingAttachments() {
        let inputView = makeInputView()

        inputView.isSendButtonEnabled = false
        inputView.updateComposerActionReadiness()

        XCTAssertFalse(inputView.recordButton.isEnabled)
        XCTAssertFalse(inputView.sendButton.isEnabled)
        XCTAssertTrue(inputView.attachButton.isEnabled)
    }

    func testScheduledMessagesStayInEmptyRecordModeAndHideForTextSend() {
        let inputView = makeInputView()
        inputView.hasScheduledMessagesForCurrentChat = true
        inputView.layoutIfNeeded()

        XCTAssertEqual(inputView.currentComposerActionMode, .record)
        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)

        inputView.textField.text = "New message"
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()

        XCTAssertEqual(inputView.currentComposerActionMode, .textSend)
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)
        XCTAssertFalse(inputView.sendButton.isHidden)
    }

    func testTrailingActionFrameTracksRecordThenTextSendWithoutHorizontalJump() throws {
        let inputView = makeInputView()

        let recordAnchor = try XCTUnwrap(inputView.trailingActionFrame(in: inputView))
        let recordFrame = inputView.recordButton.convert(inputView.recordButton.bounds, to: inputView)
        XCTAssertEqual(recordAnchor, recordFrame)

        inputView.textField.text = "Hello"
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()

        let sendAnchor = try XCTUnwrap(inputView.trailingActionFrame(in: inputView))
        let sendFrame = inputView.sendButton.convert(inputView.sendButton.bounds, to: inputView)
        XCTAssertEqual(sendAnchor, sendFrame)
        XCTAssertEqual(sendAnchor.midX, recordAnchor.midX, accuracy: 0.001)
    }

    func testComposerActionsExposeStableAccessibleIdentity() {
        let inputView = makeInputView()

        XCTAssertEqual(inputView.recordButton.accessibilityIdentifier, "chat.composer.record_button")
        XCTAssertEqual(inputView.recordButton.accessibilityLabel, "Record voice message")
        XCTAssertEqual(inputView.sendButton.accessibilityIdentifier, "chat.composer.send_button")
        XCTAssertEqual(inputView.sendButton.accessibilityLabel, "Send message")
        XCTAssertEqual(inputView.recordButton.bounds.size, CGSize(square: NativeGlassBarStyle.buttonSize))
        XCTAssertEqual(inputView.sendButton.bounds.size, CGSize(square: NativeGlassBarStyle.buttonSize))
    }

    func testRecordingCancelHintKeepsGapBetweenChevronAndTitle() throws {
        let panel = ModernXabberInputView.RecordPanel(frame: CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: ModernXabberInputView.defaultBarHeight
        ))

        panel.update()
        panel.slideToCancelButton.layoutIfNeeded()

        let imageView = try XCTUnwrap(panel.slideToCancelButton.imageView)
        let titleLabel = try XCTUnwrap(panel.slideToCancelButton.titleLabel)
        let imageFrame = imageView.convert(imageView.bounds, to: panel.slideToCancelButton)
        let titleFrame = titleLabel.convert(titleLabel.bounds, to: panel.slideToCancelButton)

        XCTAssertGreaterThanOrEqual(
            titleFrame.minX - imageFrame.maxX,
            8 - 0.001
        )
    }

    func testRecordingCancelHintUsesOneLineAtProductionComposerWidth() throws {
        let inputView = makeInputView()
        inputView.changeState(to: .record)
        inputView.layoutIfNeeded()
        inputView.recordPanel.resetElements()
        inputView.recordPanel.slideToCancelButton.layoutIfNeeded()

        let button = inputView.recordPanel.slideToCancelButton
        let titleLabel = try XCTUnwrap(button.titleLabel)
        let titleFrame = titleLabel.convert(titleLabel.bounds, to: button)

        XCTAssertEqual(titleLabel.numberOfLines, 1)
        XCTAssertLessThanOrEqual(titleFrame.height, titleLabel.font.lineHeight + 0.5)
        XCTAssertLessThanOrEqual(titleFrame.maxX, button.bounds.maxX + 0.001)
    }

    func testRecordingVisualsIgnoreIncidentalInitialFingerDrift() {
        let inputView = makeInputView()
        inputView.changeState(to: .record)
        inputView.recordButton.showPulse()
        inputView.showRecordingLockOverlay(isLocked: false, allowsStop: false, animated: false)

        inputView.updateVoiceRecordingDragUI(CGPoint(x: -5, y: -4))

        XCTAssertEqual(inputView.recordButton.recordingVisualTranslation, .zero)
        XCTAssertEqual(inputView.recordLockButton.transform.tx, 0, accuracy: 0.001)
        XCTAssertEqual(inputView.recordLockButton.transform.ty, 0, accuracy: 0.001)
        XCTAssertEqual(inputView.recordPanel.slideToCancelButton.alpha, 1, accuracy: 0.001)
    }

    func testRecordingVisualDragStartsContinuouslyAfterActivationThreshold() {
        let inputView = makeInputView()
        inputView.changeState(to: .record)
        inputView.recordButton.showPulse()
        inputView.showRecordingLockOverlay(isLocked: false, allowsStop: false, animated: false)

        inputView.updateVoiceRecordingDragUI(CGPoint(x: -20, y: -18))

        XCTAssertEqual(
            inputView.recordButton.recordingVisualTranslation,
            CGPoint(x: -16, y: -12)
        )
        XCTAssertEqual(inputView.recordLockButton.transform.tx, -16, accuracy: 0.001)
        XCTAssertEqual(inputView.recordLockButton.transform.ty, -12, accuracy: 0.001)
    }

    func testRecordingIndicatorUsesSolidCoreAndMeteredHaloWithoutGlass() throws {
        let inputView = makeInputView()
        inputView.changeState(to: .record)
        inputView.recordButton.showPulse()
        inputView.layoutIfNeeded()

        let pulseView = inputView.recordButton.pulseView
        XCTAssertFalse(pulseView.isHidden)
        XCTAssertTrue(pulseView.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
        XCTAssertNil(descendantEffectView(in: pulseView))
        XCTAssertFalse(inputView.recordButton.recordingCoreView.isAccessibilityElement)
        XCTAssertFalse(inputView.recordButton.recordingHaloView.isAccessibilityElement)

        inputView.updateRecordingMeteringLevel(0, animated: false)
        let quietCoreScale = inputView.recordButton.recordingCoreView.transform.a
        let quietHaloScale = inputView.recordButton.recordingHaloView.transform.a
        let quietHaloAlpha = inputView.recordButton.recordingHaloView.alpha

        inputView.updateRecordingMeteringLevel(1, animated: false)

        XCTAssertGreaterThan(inputView.recordButton.recordingCoreView.transform.a, quietCoreScale)
        XCTAssertGreaterThan(inputView.recordButton.recordingHaloView.transform.a, quietHaloScale)
        XCTAssertGreaterThan(inputView.recordButton.recordingHaloView.alpha, quietHaloAlpha)
        XCTAssertLessThanOrEqual(inputView.recordButton.recordingHaloView.frame.width, 128.001)
        XCTAssertTrue(inputView.recordButton.tintColor.isEqual(UIColor.white))
    }

    func testRecordingResetRestoresIdleMicAndHidesSolidIndicator() throws {
        let inputView = makeInputView()
        let idleImage = try XCTUnwrap(buttonGlyphImage(inputView.recordButton))

        inputView.changeState(to: .record)
        inputView.recordButton.showPulse()
        inputView.updateRecordingMeteringLevel(1, animated: false)
        inputView.cancelRecord()
        inputView.layoutIfNeeded()

        XCTAssertTrue(inputView.recordButton.pulseView.isHidden)
        XCTAssertEqual(inputView.recordButton.recordingVisualTranslation, .zero)
        XCTAssertEqual(inputView.recordButton.recordingCoreView.transform, .identity)
        XCTAssertEqual(inputView.recordButton.recordingHaloView.transform, .identity)
        XCTAssertTrue(buttonGlyphImage(inputView.recordButton)?.isEqual(idleImage) == true)
        XCTAssertEqual(inputView.recordButton.accessibilityLabel, "Record voice message")
    }

    func testVoicePreviewUsesExternalSendActionAndRestoresMicOnReset() throws {
        let inputView = makeInputView()
        let sessionID = UUID()
        let idleMic = try XCTUnwrap(buttonGlyphImage(inputView.recordButton))

        inputView.applyVoiceRecordingActions(
            inputView.voiceRecordingInteraction.beginPress(sessionID: sessionID, at: 0)
        )
        inputView.applyVoiceRecordingActions(
            inputView.voiceRecordingInteraction.recorderStarted(sessionID: sessionID)
        )
        inputView.applyVoiceRecordingActions(
            inputView.voiceRecordingInteraction.dragChanged(to: CGPoint(x: 0, y: -109))
        )
        inputView.stopLockedAudioRecording()
        inputView.audioRecordingPreviewReady(sessionID: sessionID)
        inputView.layoutIfNeeded()

        let previewSend = try XCTUnwrap(buttonGlyphImage(inputView.recordButton))
        XCTAssertEqual(inputView.state, .recordAndPlay)
        XCTAssertFalse(inputView.recordButton.isHidden)
        XCTAssertTrue(inputView.sendButton.isHidden)
        XCTAssertEqual(inputView.recordButton.accessibilityLabel, "Send voice message")
        XCTAssertFalse(previewSend.isEqual(idleMic))

        inputView.cancelRecord()
        inputView.layoutIfNeeded()

        XCTAssertEqual(inputView.state, .normal)
        XCTAssertEqual(inputView.recordButton.accessibilityLabel, "Record voice message")
        XCTAssertTrue(buttonGlyphImage(inputView.recordButton)?.isEqual(idleMic) == true)
    }

    private func makeInputView() -> ModernXabberInputView {
        let inputView = ModernXabberInputView(frame: CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: ModernXabberInputView.defaultBarHeight
        ))
        inputView.isSendButtonEnabled = true
        inputView.changeState(to: .normal)
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()
        return inputView
    }

    private func composerEffectView(containing view: UIView) -> UIVisualEffectView? {
        var candidate = view.superview
        while let current = candidate {
            if let effect = current as? UIVisualEffectView {
                return effect
            }
            candidate = current.superview
        }
        return nil
    }

    private func descendantEffectView(in view: UIView) -> UIVisualEffectView? {
        if let effect = view as? UIVisualEffectView {
            return effect
        }
        for subview in view.subviews {
            if let effect = descendantEffectView(in: subview) {
                return effect
            }
        }
        return nil
    }

    private func buttonGlyphImage(_ button: UIButton) -> UIImage? {
        button.image(for: .normal) ?? button.configuration?.image
    }
}
