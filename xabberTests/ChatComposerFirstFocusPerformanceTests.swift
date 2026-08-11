//
//  ChatComposerFirstFocusPerformanceTests.swift
//  xabberTests
//
//  Created by Codex on 10.08.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import AVFoundation
import XCTest
@testable import xabber

final class ChatComposerFirstFocusPerformanceTests: XCTestCase {
    func testOrderedFirstFocusLifecycleUsesOneOpaqueTraceAndTerminates() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 16)
        var records: [ChatComposerFocusDiagnosticRecord] = []

        let start = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 1_000,
            stage: .touchBegan,
            isMainThread: true
        ))
        records.append(start.record)
        XCTAssertTrue(start.didStart)

        records.append(try XCTUnwrap(state.record(
            stage: .becomeFirstResponderBegin,
            atMilliseconds: 1_010,
            isMainThread: true
        )))
        records.append(try XCTUnwrap(state.record(
            stage: .shouldBeginEditing,
            atMilliseconds: 1_020,
            isMainThread: true
        )))
        records.append(try XCTUnwrap(state.record(
            stage: .didBeginEditing,
            atMilliseconds: 1_030,
            isMainThread: true
        )))
        records.append(try XCTUnwrap(state.record(
            stage: .keyboardWillShow,
            atMilliseconds: 1_040,
            durationMilliseconds: 250,
            value: 301,
            isMainThread: true
        )))
        records.append(try XCTUnwrap(state.record(
            stage: .mainQueueHeartbeatRecovered,
            atMilliseconds: 1_050,
            durationMilliseconds: 40,
            value: 2,
            isMainThread: true
        )))
        records.append(contentsOf: state.finish(
            stage: .keyboardDidShow,
            atMilliseconds: 1_300,
            isMainThread: true
        ))

        XCTAssertEqual(
            records.map(\.stage),
            [
                .touchBegan,
                .becomeFirstResponderBegin,
                .shouldBeginEditing,
                .didBeginEditing,
                .keyboardWillShow,
                .mainQueueHeartbeatRecovered,
                .traceSummary,
                .keyboardDidShow
            ]
        )
        XCTAssertEqual(Set(records.map(\.traceID)), [start.record.traceID])
        XCTAssertEqual(records.map(\.elapsedMilliseconds), records.map(\.elapsedMilliseconds).sorted())
        XCTAssertEqual(records.suffix(2).first?.value, 40)
        XCTAssertTrue(state.isTerminal)
        XCTAssertFalse(state.isActive)
    }

    func testDuplicateMilestonesAndLateCallbacksAreIgnored() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 10)
        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 10,
            stage: .touchBegan,
            isMainThread: true
        ))

        XCTAssertNotNil(state.record(
            stage: .didBeginEditing,
            atMilliseconds: 20,
            isMainThread: true
        ))
        XCTAssertNil(state.record(
            stage: .didBeginEditing,
            atMilliseconds: 21,
            isMainThread: true
        ))
        XCTAssertEqual(
            state.finish(
                stage: .keyboardDidShow,
                atMilliseconds: 30,
                isMainThread: true
            ).map(\.stage),
            [.traceSummary, .keyboardDidShow]
        )

        XCTAssertNil(state.record(
            stage: .keyboardWillChangeFrame,
            atMilliseconds: 31,
            isMainThread: true
        ))
        XCTAssertNil(state.beginIfNeeded(
            atMilliseconds: 40,
            stage: .touchBegan,
            isMainThread: true
        ))
        XCTAssertTrue(state.finish(
            stage: .traceTimedOut,
            atMilliseconds: 50,
            isMainThread: false
        ).isEmpty)
    }

    func testMainQueueProbeReportsEachOverdueThresholdOnceAndAcknowledgesTotalDelay() {
        var probe = ChatComposerMainQueueHeartbeatProbeState(
            identifier: 2,
            scheduledAtMilliseconds: 100
        )

        XCTAssertNil(probe.recordOverdue(
            thresholdMilliseconds: 250,
            atMilliseconds: 349
        ))
        XCTAssertEqual(
            probe.recordOverdue(
                thresholdMilliseconds: 250,
                atMilliseconds: 350
            ),
            250
        )
        XCTAssertNil(probe.recordOverdue(
            thresholdMilliseconds: 250,
            atMilliseconds: 400
        ))
        XCTAssertEqual(
            probe.recordOverdue(
                thresholdMilliseconds: 1_000,
                atMilliseconds: 1_350
            ),
            1_250
        )
        XCTAssertEqual(probe.acknowledge(atMilliseconds: 23_600), 23_500)
        XCTAssertNil(probe.acknowledge(atMilliseconds: 23_700))
        XCTAssertNil(probe.recordOverdue(
            thresholdMilliseconds: 3_000,
            atMilliseconds: 23_700
        ))
    }

    func testCancelledTentativeTouchAllowsASecondTraceAttempt() throws {
        var state = ChatComposerFocusTraceState(
            maximumRecordCount: 16,
            maximumTraceAttempts: 3
        )
        let first = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 100,
            stage: .touchBegan,
            isMainThread: true
        ))

        let cancellation = state.abandonForRetry(
            stage: .traceCancelled,
            atMilliseconds: 120,
            onlyBeforeResponderAttempt: true,
            isMainThread: true
        )

        XCTAssertEqual(cancellation.map(\.stage), [.traceSummary, .traceCancelled])
        XCTAssertFalse(state.isTerminal)
        XCTAssertFalse(state.isActive)

        let second = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 200,
            stage: .touchBegan,
            isMainThread: true
        ))
        XCTAssertNotEqual(first.record.traceID, second.record.traceID)
        XCTAssertEqual(second.record.traceID, first.record.traceID + 1)

        _ = state.finish(
            stage: .keyboardDidShow,
            atMilliseconds: 300,
            isMainThread: true
        )
        XCTAssertTrue(state.isTerminal)
    }

    func testTouchCancellationDoesNotAbandonAnActiveResponderAttempt() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 16)
        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 100,
            stage: .touchBegan,
            isMainThread: true
        ))
        _ = try XCTUnwrap(state.record(
            stage: .becomeFirstResponderBegin,
            atMilliseconds: 110,
            isMainThread: true
        ))

        XCTAssertTrue(state.abandonForRetry(
            stage: .traceCancelled,
            atMilliseconds: 120,
            onlyBeforeResponderAttempt: true,
            isMainThread: true
        ).isEmpty)
        XCTAssertTrue(state.isActive)
    }

    func testTouchCancellationMilestoneKeepsTentativeTraceActive() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 16)
        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 100,
            stage: .touchHitTest,
            isMainThread: true
        ))

        let cancelled = try XCTUnwrap(state.record(
            stage: .touchCancelled,
            atMilliseconds: 110,
            isMainThread: true
        ))
        let nextTouch = try XCTUnwrap(state.record(
            stage: .touchHitTest,
            atMilliseconds: 200,
            isMainThread: true
        ))

        XCTAssertEqual(cancelled.stage, .touchCancelled)
        XCTAssertEqual(nextTouch.occurrence, 2)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.isTerminal)
    }

    func testHitTestWatchdogPolicyRequiresATouchInsideComposer() {
        XCTAssertTrue(ChatComposerTouchHitTestPolicy.shouldStart(
            isDiagnosticsEnabled: true,
            isTouchEvent: true,
            containsPoint: true
        ))
        XCTAssertFalse(ChatComposerTouchHitTestPolicy.shouldStart(
            isDiagnosticsEnabled: false,
            isTouchEvent: true,
            containsPoint: true
        ))
        XCTAssertFalse(ChatComposerTouchHitTestPolicy.shouldStart(
            isDiagnosticsEnabled: true,
            isTouchEvent: false,
            containsPoint: true
        ))
        XCTAssertFalse(ChatComposerTouchHitTestPolicy.shouldStart(
            isDiagnosticsEnabled: true,
            isTouchEvent: true,
            containsPoint: false
        ))
    }

    func testRepeatedTimeoutsAreBoundedBeforeDiagnosticsBecomeTerminal() throws {
        var state = ChatComposerFocusTraceState(
            maximumRecordCount: 8,
            maximumTraceAttempts: 2
        )

        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 0,
            stage: .touchBegan,
            isMainThread: true
        ))
        XCTAssertFalse(state.abandonForRetry(
            stage: .traceTimedOut,
            atMilliseconds: 35_000,
            onlyBeforeResponderAttempt: false,
            isMainThread: false
        ).isEmpty)
        XCTAssertFalse(state.isTerminal)

        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 36_000,
            stage: .touchBegan,
            isMainThread: true
        ))
        XCTAssertFalse(state.abandonForRetry(
            stage: .traceTimedOut,
            atMilliseconds: 71_000,
            onlyBeforeResponderAttempt: false,
            isMainThread: false
        ).isEmpty)
        XCTAssertTrue(state.isTerminal)
        XCTAssertNil(state.beginIfNeeded(
            atMilliseconds: 72_000,
            stage: .touchBegan,
            isMainThread: true
        ))
    }

    func testRepeatedCallbackSpansKeepMatchingOccurrenceIdentifiers() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 24)
        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 0,
            stage: .touchBegan,
            isMainThread: true
        ))

        let firstBegin = try XCTUnwrap(state.record(
            stage: .selectionChangeBegin,
            atMilliseconds: 10,
            isMainThread: true
        ))
        let firstEnd = try XCTUnwrap(state.record(
            stage: .selectionChangeEnd,
            atMilliseconds: 11,
            occurrence: firstBegin.occurrence,
            isMainThread: true
        ))
        let secondBegin = try XCTUnwrap(state.record(
            stage: .selectionChangeBegin,
            atMilliseconds: 20,
            isMainThread: true
        ))
        let secondEnd = try XCTUnwrap(state.record(
            stage: .selectionChangeEnd,
            atMilliseconds: 21,
            occurrence: secondBegin.occurrence,
            isMainThread: true
        ))
        let firstFrame = try XCTUnwrap(state.record(
            stage: .appFrameHandlerBegin,
            atMilliseconds: 30,
            isMainThread: true
        ))
        let secondFrame = try XCTUnwrap(state.record(
            stage: .appFrameHandlerBegin,
            atMilliseconds: 40,
            isMainThread: true
        ))

        XCTAssertEqual([firstBegin.occurrence, firstEnd.occurrence], [1, 1])
        XCTAssertEqual([secondBegin.occurrence, secondEnd.occurrence], [2, 2])
        XCTAssertEqual([firstFrame.occurrence, secondFrame.occurrence], [1, 2])
    }

    func testHeartbeatDelayIsPreservedInTerminalSummary() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 8)
        _ = try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 0,
            stage: .touchBegan,
            isMainThread: true
        ))

        state.noteMainQueueDelay(23_582)
        let terminalRecords = state.finish(
            stage: .keyboardDidShow,
            atMilliseconds: 24_000,
            isMainThread: true
        )

        XCTAssertEqual(terminalRecords.first?.stage, .traceSummary)
        XCTAssertEqual(terminalRecords.first?.value, 23_582)
    }

    func testKeyboardCompletionRequiresTheTrackedVisibleFirstResponder() {
        XCTAssertTrue(ChatComposerKeyboardCompletionPolicy.shouldFinish(
            hasTrackedComposer: true,
            isFirstResponder: true,
            isAttachedToWindow: true,
            isSceneForegroundActive: true
        ))
        XCTAssertFalse(ChatComposerKeyboardCompletionPolicy.shouldFinish(
            hasTrackedComposer: false,
            isFirstResponder: true,
            isAttachedToWindow: true,
            isSceneForegroundActive: true
        ))
        XCTAssertFalse(ChatComposerKeyboardCompletionPolicy.shouldFinish(
            hasTrackedComposer: true,
            isFirstResponder: false,
            isAttachedToWindow: true,
            isSceneForegroundActive: true
        ))
        XCTAssertFalse(ChatComposerKeyboardCompletionPolicy.shouldFinish(
            hasTrackedComposer: true,
            isFirstResponder: true,
            isAttachedToWindow: false,
            isSceneForegroundActive: true
        ))
        XCTAssertFalse(ChatComposerKeyboardCompletionPolicy.shouldFinish(
            hasTrackedComposer: true,
            isFirstResponder: true,
            isAttachedToWindow: true,
            isSceneForegroundActive: false
        ))
    }

    func testRecordBudgetKeepsTerminalSummaryAndCapsGapSpam() throws {
        var state = ChatComposerFocusTraceState(maximumRecordCount: 8)
        var records = [try XCTUnwrap(state.beginIfNeeded(
            atMilliseconds: 0,
            stage: .touchBegan,
            isMainThread: true
        )).record]

        for index in 1...20 {
            if let record = state.record(
                stage: .mainQueueHeartbeatOverdue,
                atMilliseconds: UInt64(index * 1_000),
                durationMilliseconds: index * 1_000,
                value: index,
                isMainThread: false
            ) {
                records.append(record)
            }
        }
        records.append(contentsOf: state.finish(
            stage: .traceTimedOut,
            atMilliseconds: 30_000,
            isMainThread: false
        ))

        XCTAssertEqual(records.count, 8)
        XCTAssertEqual(records.suffix(2).map(\.stage), [.traceSummary, .traceTimedOut])
        XCTAssertEqual(records.suffix(2).first?.value, 20_000)
    }

    func testDiagnosticLineContainsOnlyFixedStagesAndNumericMetrics() {
        let record = ChatComposerFocusDiagnosticRecord(
            traceID: 7,
            stage: .mainQueueHeartbeatOverdue,
            elapsedMilliseconds: 3_010,
            durationMilliseconds: 3_000,
            isMainThread: false,
            value: 3_000,
            value2: 2
        )

        XCTAssertEqual(
            record.diagnosticLine,
            "CHAT_COMPOSER_FOCUS_TRACE trace=7 event=main_queue_heartbeat_overdue occurrence=1 elapsed_ms=3010 duration_ms=3000 main=0 value=3000 value2=2"
        )

        let normalized = record.diagnosticLine.lowercased()
        [
            "owner", "jid", "body", "text=", "account", "token", "url=",
            "path=", "xml", "stanza", "language", "device_name", "pasteboard"
        ].forEach { forbidden in
            XCTAssertFalse(normalized.contains(forbidden), "diagnostic leaked field: \(forbidden)")
        }
    }

    func testVoiceRecordingConfiguresAudioSessionOnlyForRecordingLifetime() throws {
        let session = VoiceRecordingAudioSessionFake()
        let controller = VoiceRecordingAudioSessionController(session: session)

        XCTAssertTrue(session.operations.isEmpty)

        try controller.prepareForRecording()
        controller.deactivate()

        XCTAssertEqual(
            session.operations,
            [
                .setCategory(
                    category: .playAndRecord,
                    mode: .default,
                    options: .defaultToSpeaker
                ),
                .setAllowHaptics(true),
                .setActive(true),
                .setActive(false),
                .setAllowHaptics(false),
                .setCategory(
                    category: .ambient,
                    mode: .default,
                    options: []
                )
            ]
        )
    }

    func testVoiceRecordingActivationContinuesWhenOptionalHapticsFails() throws {
        let session = VoiceRecordingAudioSessionFake()
        session.hapticsError = VoiceRecordingAudioSessionFake.TestError.hapticsUnavailable
        let controller = VoiceRecordingAudioSessionController(session: session)

        try controller.prepareForRecording()
        controller.deactivate()

        XCTAssertEqual(
            session.operations,
            [
                .setCategory(
                    category: .playAndRecord,
                    mode: .default,
                    options: .defaultToSpeaker
                ),
                .setAllowHaptics(true),
                .setActive(true),
                .setActive(false),
                .setCategory(
                    category: .ambient,
                    mode: .default,
                    options: []
                )
            ]
        )
    }

    func testVoiceRecordingStartFailureRestoresPreviousConfiguration() throws {
        let session = VoiceRecordingAudioSessionFake(
            category: .playback,
            mode: .spokenAudio,
            categoryOptions: .duckOthers,
            allowsRecordingHaptics: false
        )
        let controller = VoiceRecordingAudioSessionController(session: session)
        let failedStart: () throws -> Void = {
            throw VoiceRecordingAudioSessionFake.TestError.recorderStartFailed
        }

        XCTAssertThrowsError(
            try controller.performRecordingStart(failedStart)
        )

        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        XCTAssertEqual(session.categoryOptions, .duckOthers)
        XCTAssertFalse(session.allowHapticsAndSystemSoundsDuringRecording)
        XCTAssertEqual(
            Array(session.operations.suffix(3)),
            [
                .setActive(false),
                .setAllowHaptics(false),
                .setCategory(
                    category: .playback,
                    mode: .spokenAudio,
                    options: .duckOthers
                )
            ]
        )
    }

    func testVoiceRecordingActivationFailureRollsBackConfiguration() {
        let session = VoiceRecordingAudioSessionFake()
        session.activationError = VoiceRecordingAudioSessionFake.TestError.activationUnavailable
        let controller = VoiceRecordingAudioSessionController(session: session)

        XCTAssertThrowsError(try controller.prepareForRecording())

        XCTAssertEqual(session.category, .ambient)
        XCTAssertEqual(session.mode, .default)
        XCTAssertEqual(session.categoryOptions, [])
        XCTAssertFalse(session.allowHapticsAndSystemSoundsDuringRecording)
        XCTAssertEqual(
            Array(session.operations.suffix(4)),
            [
                .setActive(true),
                .setActive(false),
                .setAllowHaptics(false),
                .setCategory(
                    category: .ambient,
                    mode: .default,
                    options: []
                )
            ]
        )
    }

    func testVoiceRecordingCleanupDoesNotOverwriteAnotherAudioOwner() throws {
        let session = VoiceRecordingAudioSessionFake()
        let controller = VoiceRecordingAudioSessionController(session: session)
        try controller.prepareForRecording()
        session.replaceConfiguration(
            category: .playAndRecord,
            mode: .voiceChat,
            categoryOptions: [.defaultToSpeaker, .allowBluetoothHFP],
            allowsRecordingHaptics: true
        )
        let operationsBeforeCleanup = session.operations

        controller.deactivate()

        XCTAssertEqual(session.operations, operationsBeforeCleanup)
        XCTAssertEqual(session.mode, .voiceChat)
    }

    func testFirstFocusRecoveryRetriesExactInterruptedPresentationOnlyOnce() {
        var state = ChatComposerFirstFocusRecoveryState()
        let eligibility = ChatComposerFirstFocusRecoveryEligibility(
            isComposerFirstResponder: true,
            isComposerAttached: true,
            isSceneForegroundActive: true,
            isChatVisible: true,
            isNavigationStable: true,
            isInteractiveDismissalActive: false
        )

        state.noteEditingBegan()
        state.noteKeyboardWillShow(isComposerFirstResponder: true)

        XCTAssertTrue(state.consumeRetryOnKeyboardWillHide(eligibility: eligibility))
        XCTAssertTrue(state.allowsScheduledRecovery)
        XCTAssertFalse(state.consumeRetryOnKeyboardWillHide(eligibility: eligibility))

        state.noteKeyboardWillShow(isComposerFirstResponder: true)
        XCTAssertFalse(state.consumeRetryOnKeyboardWillHide(eligibility: eligibility))
    }

    func testFirstFocusRecoveryStopsAfterKeyboardDidShow() {
        var state = ChatComposerFirstFocusRecoveryState()
        state.noteEditingBegan()
        state.noteKeyboardWillShow(isComposerFirstResponder: true)
        state.noteKeyboardDidShow(isComposerFirstResponder: true)

        XCTAssertFalse(state.consumeRetryOnKeyboardWillHide(
            eligibility: .fullyEligible
        ))
        XCTAssertFalse(state.allowsScheduledRecovery)
    }

    func testFirstFocusRecoveryInvalidatesScheduledRetryWhenKeyboardDidShowArrives() {
        var state = ChatComposerFirstFocusRecoveryState()
        state.noteEditingBegan()
        state.noteKeyboardWillShow(isComposerFirstResponder: true)
        XCTAssertTrue(state.consumeRetryOnKeyboardWillHide(
            eligibility: .fullyEligible
        ))
        XCTAssertTrue(state.allowsScheduledRecovery)

        state.noteKeyboardDidShow(isComposerFirstResponder: true)

        XCTAssertFalse(state.allowsScheduledRecovery)
    }

    func testFirstFocusRecoveryInvalidatesScheduledRetryWhenEditingEnds() {
        var state = ChatComposerFirstFocusRecoveryState()
        state.noteEditingBegan()
        state.noteKeyboardWillShow(isComposerFirstResponder: true)
        XCTAssertTrue(state.consumeRetryOnKeyboardWillHide(
            eligibility: .fullyEligible
        ))

        state.noteEditingEnded()

        XCTAssertFalse(state.allowsScheduledRecovery)
    }

    func testFirstFocusRecoveryRejectsIncompleteOrIneligibleSequences() {
        var state = ChatComposerFirstFocusRecoveryState()

        XCTAssertFalse(state.consumeRetryOnKeyboardWillHide(
            eligibility: .fullyEligible
        ))

        state.noteEditingBegan()
        state.noteKeyboardWillShow(isComposerFirstResponder: true)
        XCTAssertFalse(state.consumeRetryOnKeyboardWillHide(
            eligibility: ChatComposerFirstFocusRecoveryEligibility(
                isComposerFirstResponder: true,
                isComposerAttached: true,
                isSceneForegroundActive: true,
                isChatVisible: true,
                isNavigationStable: true,
                isInteractiveDismissalActive: true
            )
        ))
        XCTAssertFalse(state.consumeRetryOnKeyboardWillHide(
            eligibility: .fullyEligible
        ))
    }
}

private final class VoiceRecordingAudioSessionFake: VoiceRecordingAudioSession {
    enum TestError: Error {
        case activationUnavailable
        case hapticsUnavailable
        case recorderStartFailed
    }

    enum Operation: Equatable {
        case setCategory(
            category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            options: AVAudioSession.CategoryOptions
        )
        case setAllowHaptics(Bool)
        case setActive(Bool)
    }

    private(set) var operations: [Operation] = []
    var activationError: Error?
    var hapticsError: Error?
    private(set) var category: AVAudioSession.Category
    private(set) var mode: AVAudioSession.Mode
    private(set) var categoryOptions: AVAudioSession.CategoryOptions
    private(set) var allowHapticsAndSystemSoundsDuringRecording: Bool

    init(
        category: AVAudioSession.Category = .ambient,
        mode: AVAudioSession.Mode = .default,
        categoryOptions: AVAudioSession.CategoryOptions = [],
        allowsRecordingHaptics: Bool = false
    ) {
        self.category = category
        self.mode = mode
        self.categoryOptions = categoryOptions
        self.allowHapticsAndSystemSoundsDuringRecording = allowsRecordingHaptics
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        operations.append(.setCategory(
            category: category,
            mode: mode,
            options: options
        ))
        self.category = category
        self.mode = mode
        self.categoryOptions = options
    }

    func setAllowHapticsAndSystemSoundsDuringRecording(_ inValue: Bool) throws {
        operations.append(.setAllowHaptics(inValue))
        if let hapticsError {
            throw hapticsError
        }
        allowHapticsAndSystemSoundsDuringRecording = inValue
    }

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws {
        operations.append(.setActive(active))
        if active, let activationError {
            throw activationError
        }
    }

    func replaceConfiguration(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        categoryOptions: AVAudioSession.CategoryOptions,
        allowsRecordingHaptics: Bool
    ) {
        self.category = category
        self.mode = mode
        self.categoryOptions = categoryOptions
        self.allowHapticsAndSystemSoundsDuringRecording = allowsRecordingHaptics
    }
}
