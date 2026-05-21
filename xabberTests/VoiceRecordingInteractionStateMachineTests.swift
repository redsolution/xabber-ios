//
//  VoiceRecordingInteractionStateMachineTests.swift
//  xabberTests
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
@testable import xabber

final class VoiceRecordingInteractionStateMachineTests: XCTestCase {
    func testPressThenValidReleaseSendsRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        XCTAssertEqual(machine.beginPress(sessionID: sessionID, at: 10), [.requestStartRecording(sessionID)])
        XCTAssertEqual(machine.recorderStarted(sessionID: sessionID), [.showRecording(sessionID)])
        XCTAssertEqual(machine.endPress(at: 11.1), [.finishRecording(sessionID, .sendImmediately)])
        XCTAssertEqual(machine.state, .sending(sessionID: sessionID))
    }

    func testPressThenShortReleaseCancelsRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)

        XCTAssertEqual(machine.endPress(at: 10.5), [.cancelRecording(sessionID)])
        XCTAssertEqual(machine.state, .cancelling(sessionID: sessionID))
    }

    func testPressThenDragLeftCancelsRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)

        XCTAssertEqual(
            machine.dragChanged(to: CGPoint(x: -121, y: 0)),
            [.updateDrag(CGPoint(x: -121, y: 0)), .cancelRecording(sessionID)]
        )
        XCTAssertEqual(machine.state, .cancelling(sessionID: sessionID))
    }

    func testPressThenDragUpLocksRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)

        XCTAssertEqual(
            machine.dragChanged(to: CGPoint(x: 0, y: -109)),
            [.updateDrag(CGPoint(x: 0, y: -109)), .lockRecording(sessionID)]
        )
        XCTAssertEqual(machine.state, .lockedRecording(sessionID: sessionID, startedAt: 10))
        XCTAssertEqual(machine.endPress(at: 11.5), [])
        XCTAssertEqual(machine.state, .lockedRecording(sessionID: sessionID, startedAt: 10))
    }

    func testLockedRecordingDragLeftCancelsRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))

        XCTAssertEqual(
            machine.dragChanged(to: CGPoint(x: -121, y: 0)),
            [.updateDrag(CGPoint(x: -121, y: 0)), .cancelRecording(sessionID)]
        )
        XCTAssertEqual(machine.state, .cancelling(sessionID: sessionID))
    }

    func testLockedRecordingNonCancelDragKeepsRecordingLocked() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))

        XCTAssertEqual(
            machine.dragChanged(to: CGPoint(x: -60, y: 0)),
            [.updateDrag(CGPoint(x: -60, y: 0))]
        )
        XCTAssertEqual(machine.state, .lockedRecording(sessionID: sessionID, startedAt: 10))
    }

    func testLockedStopCreatesPreview() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))

        XCTAssertEqual(machine.stopLockedRecording(at: 11.2), [.finishRecording(sessionID, .preview)])
        XCTAssertEqual(machine.state, .preview(sessionID: sessionID))
    }

    func testLockedSendImmediatelySendsRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))

        XCTAssertEqual(machine.sendLockedRecording(at: 11.2), [.finishRecording(sessionID, .sendImmediately)])
        XCTAssertEqual(machine.state, .sending(sessionID: sessionID))
    }

    func testLockedSendTooQuicklyCancelsRecording() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))

        XCTAssertEqual(machine.sendLockedRecording(at: 10.5), [.cancelRecording(sessionID)])
        XCTAssertEqual(machine.state, .cancelling(sessionID: sessionID))
    }

    func testPreviewDeleteResets() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))
        _ = machine.stopLockedRecording(at: 11.2)

        XCTAssertEqual(machine.deletePreview(), [.deletePreview(sessionID), .resetUI])
        XCTAssertEqual(machine.state, .idle)
    }

    func testPreviewSendDispatchesSendRequest() {
        var machine = VoiceRecordingInteractionStateMachine()
        let sessionID = UUID()

        _ = machine.beginPress(sessionID: sessionID, at: 10)
        _ = machine.recorderStarted(sessionID: sessionID)
        _ = machine.dragChanged(to: CGPoint(x: 0, y: -109))
        _ = machine.stopLockedRecording(at: 11.2)

        XCTAssertEqual(machine.sendPreview(), [.sendPreview(sessionID)])
        XCTAssertEqual(machine.state, .sending(sessionID: sessionID))
    }

    func testVoiceReferenceBuilderPreservesMediaContract() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/voice.raw"))
        let reference = VoiceMessageReferenceBuilder.make(
            owner: "alice@example.com",
            jid: "bob@example.com",
            conversationType: .regular,
            rawUrl: url,
            duration: 3,
            meteringLevels: [0.1, 0.5]
        )

        XCTAssertEqual(reference.kind, .voice)
        XCTAssertEqual(reference.mimeType, "audio")
        XCTAssertEqual(reference.duration, 3)
        XCTAssertEqual(reference.meteringLevels ?? [], [0.1, 0.5])
        XCTAssertEqual(reference.decodedUrl, url)
        XCTAssertEqual(reference.url, url.absoluteString)
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "audio/ogg")
        XCTAssertEqual(reference.metadata?["duration"] as? String, "3")
        XCTAssertEqual(reference.metadata?["meters"] as? String, "0.1 0.5")
        XCTAssertEqual(reference.metadata?["pcm"] as? String, "0.1 0.5")
    }
}
