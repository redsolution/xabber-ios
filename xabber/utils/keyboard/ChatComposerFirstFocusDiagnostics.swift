//
//  ChatComposerFirstFocusDiagnostics.swift
//  xabber
//
//  Created by Codex on 10.08.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import AVFoundation
import CocoaLumberjack
import Foundation
import UIKit

enum ChatComposerFocusDiagnosticStage: String, CaseIterable {
    case touchHitTest = "touch_hit_test"
    case touchBegan = "touch_began"
    case touchReturned = "touch_returned"
    case touchEndedBegin = "touch_ended_begin"
    case touchEndedReturn = "touch_ended_return"
    case touchCancelled = "touch_cancelled"
    case becomeFirstResponderBegin = "become_first_responder_begin"
    case becomeFirstResponderEnd = "become_first_responder_end"
    case actionQueryBegin = "action_query_begin"
    case actionQueryEnd = "action_query_end"
    case shouldBeginEditing = "should_begin_editing"
    case didBeginEditing = "did_begin_editing"
    case selectionChangeBegin = "selection_change_begin"
    case selectionChangeEnd = "selection_change_end"
    case keyboardWillShow = "keyboard_will_show"
    case keyboardWillChangeFrame = "keyboard_will_change_frame"
    case keyboardDidChangeFrame = "keyboard_did_change_frame"
    case keyboardDidShow = "keyboard_did_show"
    case keyboardWillHide = "keyboard_will_hide"
    case appFrameHandlerBegin = "app_frame_handler_begin"
    case appFrameHandlerEnd = "app_frame_handler_end"
    case environmentSnapshot = "environment_snapshot"
    case composerTimingSnapshot = "composer_timing_snapshot"
    case mainQueueHeartbeatStarted = "main_queue_heartbeat_started"
    case mainQueueHeartbeatOverdue = "main_queue_heartbeat_overdue"
    case mainQueueHeartbeatRecovered = "main_queue_heartbeat_recovered"
    case audioBootstrapCategoryBegin = "audio_bootstrap_category_begin"
    case audioBootstrapCategoryEnd = "audio_bootstrap_category_end"
    case audioBootstrapHapticsBegin = "audio_bootstrap_haptics_begin"
    case audioBootstrapHapticsEnd = "audio_bootstrap_haptics_end"
    case audioSessionInterruption = "audio_session_interruption"
    case audioSessionRouteChange = "audio_session_route_change"
    case audioMediaServicesLost = "audio_media_services_lost"
    case audioMediaServicesReset = "audio_media_services_reset"
    case traceSummary = "trace_summary"
    case traceTimedOut = "trace_timed_out"
    case traceCancelled = "trace_cancelled"

    fileprivate var allowsRepeatedEmission: Bool {
        switch self {
        case .touchHitTest,
             .touchBegan,
             .touchReturned,
             .touchEndedBegin,
             .touchEndedReturn,
             .touchCancelled,
             .becomeFirstResponderBegin,
             .becomeFirstResponderEnd,
             .actionQueryBegin,
             .actionQueryEnd,
             .selectionChangeBegin,
             .selectionChangeEnd,
             .keyboardWillShow,
             .keyboardWillChangeFrame,
             .keyboardDidChangeFrame,
             .keyboardWillHide,
             .appFrameHandlerBegin,
             .appFrameHandlerEnd,
             .mainQueueHeartbeatOverdue,
             .mainQueueHeartbeatRecovered,
             .audioSessionInterruption,
             .audioSessionRouteChange:
            return true
        default:
            return false
        }
    }
}

struct ChatComposerFocusDiagnosticRecord: Equatable {
    static let prefix = "CHAT_COMPOSER_FOCUS_TRACE"

    let traceID: UInt64
    let stage: ChatComposerFocusDiagnosticStage
    let occurrence: Int
    let elapsedMilliseconds: Int
    let durationMilliseconds: Int
    let isMainThread: Bool
    let value: Int
    let value2: Int

    init(
        traceID: UInt64,
        stage: ChatComposerFocusDiagnosticStage,
        occurrence: Int = 1,
        elapsedMilliseconds: Int,
        durationMilliseconds: Int = 0,
        isMainThread: Bool,
        value: Int = 0,
        value2: Int = 0
    ) {
        self.traceID = traceID
        self.stage = stage
        self.occurrence = max(1, occurrence)
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.isMainThread = isMainThread
        self.value = value
        self.value2 = value2
    }

    var diagnosticLine: String {
        [
            Self.prefix,
            "trace=\(traceID)",
            "event=\(stage.rawValue)",
            "occurrence=\(occurrence)",
            "elapsed_ms=\(elapsedMilliseconds)",
            "duration_ms=\(durationMilliseconds)",
            "main=\(isMainThread ? 1 : 0)",
            "value=\(value)",
            "value2=\(value2)"
        ].joined(separator: " ")
    }
}

struct ChatComposerFocusTraceStart: Equatable {
    let record: ChatComposerFocusDiagnosticRecord
    let didStart: Bool
}

struct ChatComposerFocusTraceState {
    private struct ActiveTrace {
        let traceID: UInt64
        let startedAtMilliseconds: UInt64
    }

    private let maximumRecordCount: Int
    private let maximumTraceAttempts: Int
    private var activeTrace: ActiveTrace?
    private var nextTraceID: UInt64 = 1
    private var traceAttemptCount = 0
    private var emittedStages: Set<ChatComposerFocusDiagnosticStage> = []
    private var stageOccurrences: [ChatComposerFocusDiagnosticStage: Int] = [:]
    private var emittedRecordCount = 0
    private var maximumMainQueueDelayMilliseconds = 0
    private var didStartResponderAttempt = false
    private(set) var isTerminal = false

    init(
        maximumRecordCount: Int = 64,
        maximumTraceAttempts: Int = 3
    ) {
        self.maximumRecordCount = max(4, maximumRecordCount)
        self.maximumTraceAttempts = max(1, maximumTraceAttempts)
    }

    var isActive: Bool {
        activeTrace != nil && !isTerminal
    }

    var activeTraceID: UInt64? {
        activeTrace?.traceID
    }

    mutating func beginIfNeeded(
        atMilliseconds now: UInt64,
        stage: ChatComposerFocusDiagnosticStage,
        isMainThread: Bool
    ) -> ChatComposerFocusTraceStart? {
        guard !isTerminal else {
            return nil
        }

        if activeTrace != nil {
            guard let record = record(
                stage: stage,
                atMilliseconds: now,
                isMainThread: isMainThread
            ) else {
                return nil
            }
            return ChatComposerFocusTraceStart(record: record, didStart: false)
        }

        guard traceAttemptCount < maximumTraceAttempts else {
            isTerminal = true
            return nil
        }

        resetPerTraceMetrics()
        let trace = ActiveTrace(
            traceID: nextTraceID,
            startedAtMilliseconds: now
        )
        nextTraceID &+= 1
        traceAttemptCount += 1
        activeTrace = trace
        emittedStages.insert(stage)
        stageOccurrences[stage] = 1
        emittedRecordCount = 1
        return ChatComposerFocusTraceStart(
            record: ChatComposerFocusDiagnosticRecord(
                traceID: trace.traceID,
                stage: stage,
                occurrence: 1,
                elapsedMilliseconds: 0,
                isMainThread: isMainThread
            ),
            didStart: true
        )
    }

    mutating func record(
        stage: ChatComposerFocusDiagnosticStage,
        atMilliseconds now: UInt64,
        durationMilliseconds: Int = 0,
        value: Int = 0,
        value2: Int = 0,
        occurrence: Int? = nil,
        isMainThread: Bool
    ) -> ChatComposerFocusDiagnosticRecord? {
        guard let trace = activeTrace, !isTerminal else {
            return nil
        }

        if stage == .becomeFirstResponderBegin {
            didStartResponderAttempt = true
        }

        if stage == .mainQueueHeartbeatOverdue ||
            stage == .mainQueueHeartbeatRecovered {
            noteMainQueueDelay(durationMilliseconds)
        }

        if !stage.allowsRepeatedEmission, emittedStages.contains(stage) {
            return nil
        }
        // Two slots are always reserved for the terminal summary and terminal
        // event, even if a service repeatedly posts the same notification.
        guard emittedRecordCount < maximumRecordCount - 2 else {
            return nil
        }

        let eventOccurrence: Int
        if let occurrence {
            eventOccurrence = max(1, occurrence)
            stageOccurrences[stage] = max(
                stageOccurrences[stage] ?? 0,
                eventOccurrence
            )
        } else {
            eventOccurrence = (stageOccurrences[stage] ?? 0) + 1
            stageOccurrences[stage] = eventOccurrence
        }
        emittedStages.insert(stage)
        emittedRecordCount += 1
        return ChatComposerFocusDiagnosticRecord(
            traceID: trace.traceID,
            stage: stage,
            occurrence: eventOccurrence,
            elapsedMilliseconds: Self.elapsed(
                from: trace.startedAtMilliseconds,
                to: now
            ),
            durationMilliseconds: durationMilliseconds,
            isMainThread: isMainThread,
            value: value,
            value2: value2
        )
    }

    mutating func noteMainQueueDelay(_ durationMilliseconds: Int) {
        maximumMainQueueDelayMilliseconds = max(
            maximumMainQueueDelayMilliseconds,
            max(0, durationMilliseconds)
        )
    }

    mutating func abandonForRetry(
        stage: ChatComposerFocusDiagnosticStage,
        atMilliseconds now: UInt64,
        onlyBeforeResponderAttempt: Bool,
        durationMilliseconds: Int = 0,
        value: Int = 0,
        value2: Int = 0,
        isMainThread: Bool
    ) -> [ChatComposerFocusDiagnosticRecord] {
        guard activeTrace != nil,
              !isTerminal,
              !onlyBeforeResponderAttempt || !didStartResponderAttempt else {
            return []
        }

        let records = makeTerminalRecords(
            stage: stage,
            atMilliseconds: now,
            durationMilliseconds: durationMilliseconds,
            value: value,
            value2: value2,
            isMainThread: isMainThread
        )
        activeTrace = nil
        resetPerTraceMetrics()
        isTerminal = traceAttemptCount >= maximumTraceAttempts
        return records
    }

    mutating func finish(
        stage: ChatComposerFocusDiagnosticStage,
        atMilliseconds now: UInt64,
        durationMilliseconds: Int = 0,
        value: Int = 0,
        value2: Int = 0,
        isMainThread: Bool
    ) -> [ChatComposerFocusDiagnosticRecord] {
        guard activeTrace != nil, !isTerminal else {
            return []
        }

        let records = makeTerminalRecords(
            stage: stage,
            atMilliseconds: now,
            durationMilliseconds: durationMilliseconds,
            value: value,
            value2: value2,
            isMainThread: isMainThread
        )
        activeTrace = nil
        resetPerTraceMetrics()
        isTerminal = true
        return records
    }

    private func makeTerminalRecords(
        stage: ChatComposerFocusDiagnosticStage,
        atMilliseconds now: UInt64,
        durationMilliseconds: Int,
        value: Int,
        value2: Int,
        isMainThread: Bool
    ) -> [ChatComposerFocusDiagnosticRecord] {
        guard let trace = activeTrace else {
            return []
        }
        let elapsed = Self.elapsed(
            from: trace.startedAtMilliseconds,
            to: now
        )
        let summary = ChatComposerFocusDiagnosticRecord(
            traceID: trace.traceID,
            stage: .traceSummary,
            occurrence: 1,
            elapsedMilliseconds: elapsed,
            durationMilliseconds: elapsed,
            isMainThread: isMainThread,
            value: maximumMainQueueDelayMilliseconds,
            value2: emittedRecordCount
        )
        let terminal = ChatComposerFocusDiagnosticRecord(
            traceID: trace.traceID,
            stage: stage,
            occurrence: (stageOccurrences[stage] ?? 0) + 1,
            elapsedMilliseconds: elapsed,
            durationMilliseconds: durationMilliseconds,
            isMainThread: isMainThread,
            value: value,
            value2: value2
        )
        return [summary, terminal]
    }

    private mutating func resetPerTraceMetrics() {
        emittedStages.removeAll(keepingCapacity: true)
        stageOccurrences.removeAll(keepingCapacity: true)
        emittedRecordCount = 0
        maximumMainQueueDelayMilliseconds = 0
        didStartResponderAttempt = false
    }

    private static func elapsed(from start: UInt64, to end: UInt64) -> Int {
        guard end >= start else {
            return 0
        }
        return Int(clamping: end - start)
    }
}

struct ChatComposerMainQueueHeartbeatProbeState: Equatable {
    let identifier: Int
    let scheduledAtMilliseconds: UInt64

    private var emittedThresholds: Set<Int> = []
    private var isAcknowledged = false

    init(identifier: Int, scheduledAtMilliseconds: UInt64) {
        self.identifier = identifier
        self.scheduledAtMilliseconds = scheduledAtMilliseconds
    }

    mutating func recordOverdue(
        thresholdMilliseconds: Int,
        atMilliseconds now: UInt64
    ) -> Int? {
        guard !isAcknowledged,
              thresholdMilliseconds >= 0,
              !emittedThresholds.contains(thresholdMilliseconds) else {
            return nil
        }
        let delay = elapsed(atMilliseconds: now)
        guard delay >= thresholdMilliseconds else {
            return nil
        }
        emittedThresholds.insert(thresholdMilliseconds)
        return delay
    }

    mutating func acknowledge(atMilliseconds now: UInt64) -> Int? {
        guard !isAcknowledged else {
            return nil
        }
        isAcknowledged = true
        return elapsed(atMilliseconds: now)
    }

    private func elapsed(atMilliseconds now: UInt64) -> Int {
        guard now >= scheduledAtMilliseconds else {
            return 0
        }
        return Int(clamping: now - scheduledAtMilliseconds)
    }
}

struct ChatComposerKeyboardCompletionPolicy {
    static func shouldFinish(
        hasTrackedComposer: Bool,
        isFirstResponder: Bool,
        isAttachedToWindow: Bool,
        isSceneForegroundActive: Bool
    ) -> Bool {
        hasTrackedComposer &&
            isFirstResponder &&
            isAttachedToWindow &&
            isSceneForegroundActive
    }
}

struct ChatComposerTouchHitTestPolicy {
    static func shouldStart(
        isDiagnosticsEnabled: Bool,
        isTouchEvent: Bool,
        containsPoint: Bool
    ) -> Bool {
        isDiagnosticsEnabled &&
            isTouchEvent &&
            containsPoint
    }
}

final class ChatComposerFocusDiagnosticLogger {
    typealias Sink = (ChatComposerFocusDiagnosticRecord) -> Void

    static let live = ChatComposerFocusDiagnosticLogger { record in
        DDLogInfo(record.diagnosticLine)
    }

    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func record(_ record: ChatComposerFocusDiagnosticRecord) {
        sink(record)
    }
}

final class ChatComposerFirstFocusDiagnostics {
    struct Span {
        fileprivate let traceID: UInt64
        fileprivate let occurrence: Int
        fileprivate let startedAtMilliseconds: UInt64
    }

    struct PreFocusSpan {
        fileprivate let startedAtMilliseconds: UInt64
    }

    static let shared = ChatComposerFirstFocusDiagnostics()
    static let traceTimeoutMilliseconds = 35_000
    static let heartbeatIntervalMilliseconds = 250
    static let heartbeatThresholdsMilliseconds = [1_000, 3_000, 10_000, 20_000]
    static let heartbeatRecoveryLoggingThresholdMilliseconds = 1_000

    private let lock = NSLock()
    private let logger: ChatComposerFocusDiagnosticLogger
    private let notificationCenter: NotificationCenter
    private let monitorQueue = DispatchQueue(
        label: "com.xabber.chat-composer-focus-diagnostics",
        qos: .userInitiated
    )
    private let logQueue = DispatchQueue(
        label: "com.xabber.chat-composer-focus-diagnostics.log",
        qos: .utility
    )
    private let clock: () -> UInt64

    private var state = ChatComposerFocusTraceState()
    private var heartbeatProbe: ChatComposerMainQueueHeartbeatProbeState?
    private var heartbeatTraceID: UInt64?
    private var nextHeartbeatIdentifier = 1
    private var observerTokens: [NSObjectProtocol] = []
    private var composerReadyAtMilliseconds: UInt64?
    private var chatViewDidAppearAtMilliseconds: UInt64?
    private weak var trackedInputView: UITextView?

    private init(
        logger: ChatComposerFocusDiagnosticLogger = .live,
        notificationCenter: NotificationCenter = .default,
        clock: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds / 1_000_000
        }
    ) {
        self.logger = logger
        self.notificationCenter = notificationCenter
        self.clock = clock
        installObservers()
    }

    deinit {
        observerTokens.forEach(notificationCenter.removeObserver)
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isActive
    }

    func noteComposerReady() {
        let now = clock()
        lock.lock()
        if !state.isTerminal {
            composerReadyAtMilliseconds = now
        }
        lock.unlock()
    }

    func noteChatViewDidAppear() {
        let now = clock()
        lock.lock()
        if !state.isTerminal {
            chatViewDidAppearAtMilliseconds = now
        }
        lock.unlock()
    }

    @discardableResult
    func beginIfNeeded(
        stage: ChatComposerFocusDiagnosticStage,
        windowAttached: Bool,
        inputView: UITextView
    ) -> Span? {
        let now = clock()
        let start: ChatComposerFocusTraceStart?
        var records: [ChatComposerFocusDiagnosticRecord] = []

        lock.lock()
        start = state.beginIfNeeded(
            atMilliseconds: now,
            stage: stage,
            isMainThread: Thread.isMainThread
        )
        if let start {
            records.append(start.record)
            if start.didStart {
                trackedInputView = inputView
                if let environment = state.record(
                    stage: .environmentSnapshot,
                    atMilliseconds: now,
                    value: windowAttached ? 1 : 0,
                    value2: UIApplication.shared.applicationState.rawValue,
                    isMainThread: Thread.isMainThread
                ) {
                    records.append(environment)
                }
                if let timing = state.record(
                    stage: .composerTimingSnapshot,
                    atMilliseconds: now,
                    value: Self.elapsed(
                        from: composerReadyAtMilliseconds,
                        to: now
                    ),
                    value2: Self.elapsed(
                        from: chatViewDidAppearAtMilliseconds,
                        to: now
                    ),
                    isMainThread: Thread.isMainThread
                ) {
                    records.append(timing)
                }
            }
        }
        lock.unlock()

        guard let start else {
            return nil
        }
        emit(records)

        if start.didStart {
            monitorQueue.async { [weak self] in
                self?.startMonitoring(traceID: start.record.traceID)
            }
        }

        return Span(
            traceID: start.record.traceID,
            occurrence: start.record.occurrence,
            startedAtMilliseconds: now
        )
    }

    func beginSpan(
        stage: ChatComposerFocusDiagnosticStage
    ) -> Span? {
        let now = clock()
        let record: ChatComposerFocusDiagnosticRecord?

        lock.lock()
        notePendingHeartbeatDelay(atMilliseconds: now)
        record = state.record(
            stage: stage,
            atMilliseconds: now,
            isMainThread: Thread.isMainThread
        )
        lock.unlock()

        guard let record else {
            return nil
        }
        emit(record)
        return Span(
            traceID: record.traceID,
            occurrence: record.occurrence,
            startedAtMilliseconds: now
        )
    }

    func endSpan(
        _ span: Span?,
        stage: ChatComposerFocusDiagnosticStage,
        value: Int = 0,
        value2: Int = 0
    ) {
        guard let span else {
            return
        }
        let now = clock()
        let record: ChatComposerFocusDiagnosticRecord?

        lock.lock()
        guard state.activeTraceID == span.traceID else {
            lock.unlock()
            return
        }
        notePendingHeartbeatDelay(atMilliseconds: now)
        record = state.record(
            stage: stage,
            atMilliseconds: now,
            durationMilliseconds: Self.elapsed(
                from: span.startedAtMilliseconds,
                to: now
            ),
            value: value,
            value2: value2,
            occurrence: span.occurrence,
            isMainThread: Thread.isMainThread
        )
        lock.unlock()

        if let record {
            emit(record)
        }
    }

    func record(
        stage: ChatComposerFocusDiagnosticStage,
        durationMilliseconds: Int = 0,
        value: Int = 0,
        value2: Int = 0
    ) {
        let now = clock()
        let record: ChatComposerFocusDiagnosticRecord?

        lock.lock()
        notePendingHeartbeatDelay(atMilliseconds: now)
        record = state.record(
            stage: stage,
            atMilliseconds: now,
            durationMilliseconds: durationMilliseconds,
            value: value,
            value2: value2,
            isMainThread: Thread.isMainThread
        )
        lock.unlock()

        if let record {
            emit(record)
        }
    }

    func finish(
        stage: ChatComposerFocusDiagnosticStage,
        durationMilliseconds: Int = 0,
        value: Int = 0,
        value2: Int = 0,
        expectedTraceID: UInt64? = nil
    ) {
        let now = clock()
        let records: [ChatComposerFocusDiagnosticRecord]

        lock.lock()
        if let expectedTraceID,
           state.activeTraceID != expectedTraceID {
            lock.unlock()
            return
        }
        notePendingHeartbeatDelay(atMilliseconds: now)
        records = state.finish(
            stage: stage,
            atMilliseconds: now,
            durationMilliseconds: durationMilliseconds,
            value: value,
            value2: value2,
            isMainThread: Thread.isMainThread
        )
        clearRuntimeTraceState()
        lock.unlock()

        emit(records)
    }

    func abandonForRetry(
        stage: ChatComposerFocusDiagnosticStage,
        onlyBeforeResponderAttempt: Bool,
        expectedTraceID: UInt64? = nil
    ) {
        let now = clock()
        let records: [ChatComposerFocusDiagnosticRecord]

        lock.lock()
        if let expectedTraceID,
           state.activeTraceID != expectedTraceID {
            lock.unlock()
            return
        }
        notePendingHeartbeatDelay(atMilliseconds: now)
        records = state.abandonForRetry(
            stage: stage,
            atMilliseconds: now,
            onlyBeforeResponderAttempt: onlyBeforeResponderAttempt,
            isMainThread: Thread.isMainThread
        )
        if !records.isEmpty {
            clearRuntimeTraceState()
        }
        lock.unlock()

        emit(records)
    }

    func beginPreFocusSpan(
        stage: ChatComposerFocusDiagnosticStage
    ) -> PreFocusSpan {
        emit(ChatComposerFocusDiagnosticRecord(
            traceID: 0,
            stage: stage,
            elapsedMilliseconds: 0,
            isMainThread: Thread.isMainThread
        ))
        return PreFocusSpan(startedAtMilliseconds: clock())
    }

    func endPreFocusSpan(
        _ span: PreFocusSpan,
        stage: ChatComposerFocusDiagnosticStage,
        succeeded: Bool,
        errorCode: Int = 0
    ) {
        let now = clock()
        emit(ChatComposerFocusDiagnosticRecord(
            traceID: 0,
            stage: stage,
            elapsedMilliseconds: 0,
            durationMilliseconds: Self.elapsed(
                from: span.startedAtMilliseconds,
                to: now
            ),
            isMainThread: Thread.isMainThread,
            value: succeeded ? 1 : 0,
            value2: errorCode
        ))
    }

    private func startMonitoring(traceID: UInt64) {
        let now = clock()
        let record: ChatComposerFocusDiagnosticRecord?

        lock.lock()
        guard state.activeTraceID == traceID else {
            lock.unlock()
            return
        }
        heartbeatTraceID = traceID
        heartbeatProbe = nil
        record = state.record(
            stage: .mainQueueHeartbeatStarted,
            atMilliseconds: now,
            value: Self.heartbeatIntervalMilliseconds,
            isMainThread: Thread.isMainThread
        )
        lock.unlock()

        if let record {
            emit(record)
        }
        heartbeatTick(traceID: traceID)
        scheduleTimeout(traceID: traceID)
    }

    private func scheduleTimeout(traceID: UInt64) {
        monitorQueue.asyncAfter(
            deadline: .now() + .milliseconds(Self.traceTimeoutMilliseconds)
        ) { [weak self] in
            self?.abandonForRetry(
                stage: .traceTimedOut,
                onlyBeforeResponderAttempt: false,
                expectedTraceID: traceID
            )
        }
    }

    private func heartbeatTick(traceID: UInt64) {
        let now = clock()
        var records: [ChatComposerFocusDiagnosticRecord] = []
        var heartbeatIdentifierToAcknowledge: Int?

        lock.lock()
        guard state.activeTraceID == traceID,
              heartbeatTraceID == traceID else {
            lock.unlock()
            return
        }

        if var probe = heartbeatProbe {
            state.noteMainQueueDelay(Self.elapsed(
                from: probe.scheduledAtMilliseconds,
                to: now
            ))
            for threshold in Self.heartbeatThresholdsMilliseconds {
                guard let delay = probe.recordOverdue(
                    thresholdMilliseconds: threshold,
                    atMilliseconds: now
                ) else {
                    continue
                }
                if let record = state.record(
                    stage: .mainQueueHeartbeatOverdue,
                    atMilliseconds: now,
                    durationMilliseconds: delay,
                    value: threshold,
                    value2: probe.identifier,
                    isMainThread: Thread.isMainThread
                ) {
                    records.append(record)
                }
            }
            heartbeatProbe = probe
        } else {
            let identifier = nextHeartbeatIdentifier
            nextHeartbeatIdentifier &+= 1
            heartbeatProbe = ChatComposerMainQueueHeartbeatProbeState(
                identifier: identifier,
                scheduledAtMilliseconds: now
            )
            heartbeatIdentifierToAcknowledge = identifier
        }
        lock.unlock()

        emit(records)
        if let heartbeatIdentifierToAcknowledge {
            DispatchQueue.main.async { [weak self] in
                self?.acknowledgeHeartbeat(
                    identifier: heartbeatIdentifierToAcknowledge,
                    traceID: traceID
                )
            }
        }
        monitorQueue.asyncAfter(
            deadline: .now() + .milliseconds(Self.heartbeatIntervalMilliseconds)
        ) { [weak self] in
            self?.heartbeatTick(traceID: traceID)
        }
    }

    private func acknowledgeHeartbeat(identifier: Int, traceID: UInt64) {
        let now = clock()
        let record: ChatComposerFocusDiagnosticRecord?

        lock.lock()
        guard state.activeTraceID == traceID,
              heartbeatTraceID == traceID,
              var probe = heartbeatProbe,
              probe.identifier == identifier,
              let delay = probe.acknowledge(atMilliseconds: now) else {
            lock.unlock()
            return
        }
        heartbeatProbe = nil
        state.noteMainQueueDelay(delay)
        record = delay >= Self.heartbeatRecoveryLoggingThresholdMilliseconds
            ? state.record(
                stage: .mainQueueHeartbeatRecovered,
                atMilliseconds: now,
                durationMilliseconds: delay,
                value: identifier,
                isMainThread: Thread.isMainThread
            )
            : nil
        lock.unlock()

        if let record {
            emit(record)
        }
    }

    private func notePendingHeartbeatDelay(atMilliseconds now: UInt64) {
        guard heartbeatTraceID == state.activeTraceID,
              let heartbeatProbe else {
            return
        }
        state.noteMainQueueDelay(Self.elapsed(
            from: heartbeatProbe.scheduledAtMilliseconds,
            to: now
        ))
    }

    private func clearRuntimeTraceState() {
        heartbeatProbe = nil
        heartbeatTraceID = nil
        trackedInputView = nil
    }

    private func emit(_ record: ChatComposerFocusDiagnosticRecord) {
        emit([record])
    }

    private func emit(_ records: [ChatComposerFocusDiagnosticRecord]) {
        guard !records.isEmpty else {
            return
        }
        let logger = self.logger
        logQueue.async {
            records.forEach { logger.record($0) }
        }
    }

    private func installObservers() {
        observeKeyboard(
            UIResponder.keyboardWillShowNotification,
            stage: .keyboardWillShow
        )
        observeKeyboard(
            UIResponder.keyboardWillChangeFrameNotification,
            stage: .keyboardWillChangeFrame
        )
        observeKeyboard(
            UIResponder.keyboardDidChangeFrameNotification,
            stage: .keyboardDidChangeFrame
        )
        observerTokens.append(notificationCenter.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleKeyboardDidShow(notification)
        })
        observeKeyboard(
            UIResponder.keyboardWillHideNotification,
            stage: .keyboardWillHide
        )

        observerTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.abandonForRetry(
                stage: .traceCancelled,
                onlyBeforeResponderAttempt: false
            )
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let value = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.intValue ?? 0
            self?.record(stage: .audioSessionInterruption, value: value)
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let value = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue ?? 0
            self?.record(stage: .audioSessionRouteChange, value: value)
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.record(stage: .audioMediaServicesLost)
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.record(stage: .audioMediaServicesReset)
        })
    }

    private func handleKeyboardDidShow(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleKeyboardDidShow(notification)
            }
            return
        }

        let inputView: UITextView?
        lock.lock()
        inputView = trackedInputView
        lock.unlock()

        let shouldFinish = ChatComposerKeyboardCompletionPolicy.shouldFinish(
            hasTrackedComposer: inputView != nil,
            isFirstResponder: inputView?.isFirstResponder == true,
            isAttachedToWindow: inputView?.window != nil,
            isSceneForegroundActive:
                inputView?.window?.windowScene?.activationState == .foregroundActive
        )
        guard shouldFinish else {
            return
        }

        let metrics = Self.keyboardMetrics(notification)
        finish(
            stage: .keyboardDidShow,
            durationMilliseconds: metrics.durationMilliseconds,
            value: metrics.endHeight,
            value2: metrics.curve
        )
    }

    private func observeKeyboard(
        _ name: Notification.Name,
        stage: ChatComposerFocusDiagnosticStage
    ) {
        observerTokens.append(notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let metrics = Self.keyboardMetrics(notification)
            self?.record(
                stage: stage,
                durationMilliseconds: metrics.durationMilliseconds,
                value: metrics.endHeight,
                value2: metrics.curve
            )
        })
    }

    private static func keyboardMetrics(
        _ notification: Notification
    ) -> (durationMilliseconds: Int, endHeight: Int, curve: Int) {
        let userInfo = notification.userInfo
        let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let frame = (userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let curve = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? 0
        return (
            durationMilliseconds: max(0, Int((duration * 1_000).rounded())),
            endHeight: max(0, Int(frame.height.rounded())),
            curve: curve
        )
    }

    private static func elapsed(from start: UInt64?, to end: UInt64) -> Int {
        guard let start, end >= start else {
            return 0
        }
        return Int(clamping: end - start)
    }
}
