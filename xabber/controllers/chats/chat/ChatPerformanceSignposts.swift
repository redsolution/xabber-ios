//
//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import os.signpost

enum ChatPerformanceSignpostPhase: String, CaseIterable {
    case openRequest = "chat.open_request"
    case skeletonReceipt = "chat.skeleton_receipt"
    case contentReceipt = "chat.content_receipt"
    case emptyReceipt = "chat.empty_receipt"
    case leaseQueued = "chat.lease_queued"
    case leaseTransport = "chat.lease_transport"
    case leasePersistence = "chat.lease_persistence"
    case rawFinal = "chat.raw_final"
    case ingressComplete = "chat.ingress_complete"
    case persistenceTerminal = "chat.persistence_terminal"
    case presenting = "chat.presenting"
    case stableFrame = "chat.stable_frame"
    case localSnapshotReady = "chat.local_snapshot_ready"
    case firstContentCommitted = "chat.first_content_committed"
    case firstStableFrame = "chat.first_stable_frame"
    case chatOpenToFirstFrame = "chat.open_to_first_frame"
    case mapDataset = "chat.map_dataset"
    case datasourceDiff = "chat.datasource_diff"
    case datasourceApply = "chat.datasource_apply"
    case layoutApply = "chat.layout_apply"
    case scrollProcessing = "chat.scroll_processing"
    case sendToLocalRow = "chat.send_to_local_row"
    case localHistoryQuery = "chat.local_history_query"
    case displayModelCache = "chat.display_model_cache"
    case observerRefresh = "chat.observer_refresh"
    case referencePrepare = "chat.reference_prepare"
    case mediaPrefetch = "chat.media_prefetch"
    case mediaVisibleHit = "chat.media_visible_hit"
    case pagePlan = "chat.page_plan"
    case pageQuery = "chat.page_query"
    case pagePersist = "chat.page_persist"
    case pageApply = "chat.page_apply"
    case anchorReceived = "chat.anchor_received"
    case anchorResolved = "chat.anchor_resolved"
    case anchorCentered = "chat.anchor_centered"
    case messagePersistence = "chat.message_persistence"

    var signpostName: StaticString {
        switch self {
        case .openRequest:
            return "chat.open_request"
        case .skeletonReceipt:
            return "chat.skeleton_receipt"
        case .contentReceipt:
            return "chat.content_receipt"
        case .emptyReceipt:
            return "chat.empty_receipt"
        case .leaseQueued:
            return "chat.lease_queued"
        case .leaseTransport:
            return "chat.lease_transport"
        case .leasePersistence:
            return "chat.lease_persistence"
        case .rawFinal:
            return "chat.raw_final"
        case .ingressComplete:
            return "chat.ingress_complete"
        case .persistenceTerminal:
            return "chat.persistence_terminal"
        case .presenting:
            return "chat.presenting"
        case .stableFrame:
            return "chat.stable_frame"
        case .localSnapshotReady:
            return "chat.local_snapshot_ready"
        case .firstContentCommitted:
            return "chat.first_content_committed"
        case .firstStableFrame:
            return "chat.first_stable_frame"
        case .chatOpenToFirstFrame:
            return "chat.open_to_first_frame"
        case .mapDataset:
            return "chat.map_dataset"
        case .datasourceDiff:
            return "chat.datasource_diff"
        case .datasourceApply:
            return "chat.datasource_apply"
        case .layoutApply:
            return "chat.layout_apply"
        case .scrollProcessing:
            return "chat.scroll_processing"
        case .sendToLocalRow:
            return "chat.send_to_local_row"
        case .localHistoryQuery:
            return "chat.local_history_query"
        case .displayModelCache:
            return "chat.display_model_cache"
        case .observerRefresh:
            return "chat.observer_refresh"
        case .referencePrepare:
            return "chat.reference_prepare"
        case .mediaPrefetch:
            return "chat.media_prefetch"
        case .mediaVisibleHit:
            return "chat.media_visible_hit"
        case .pagePlan:
            return "chat.page_plan"
        case .pageQuery:
            return "chat.page_query"
        case .pagePersist:
            return "chat.page_persist"
        case .pageApply:
            return "chat.page_apply"
        case .anchorReceived:
            return "chat.anchor_received"
        case .anchorResolved:
            return "chat.anchor_resolved"
        case .anchorCentered:
            return "chat.anchor_centered"
        case .messagePersistence:
            return "chat.message_persistence"
        }
    }
}

struct ChatPerformanceMetricSnapshot: Equatable {
    static let privateTokenFragments: [String] = [
        "owner",
        "jid",
        "body",
        "account",
        "token",
        "private",
        "text",
        "url",
        "path",
        "xml",
        "stanza",
        "queryid",
        "messageprimary",
        "notificationprimary",
        "messageid",
        "archiveid",
        "opponent"
    ]

    let phase: ChatPerformanceSignpostPhase
    private let counters: [String: Int]

    init(phase: ChatPerformanceSignpostPhase, counters: [String: Int]) {
        self.phase = phase
        self.counters = counters
    }

    var sortedCounterNames: [String] {
        counters.keys.sorted()
    }

    var unsafeFieldNames: [String] {
        sortedCounterNames.filter { fieldName in
            let normalized = fieldName
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            return Self.privateTokenFragments.contains { token in
                normalized.contains(token)
            }
        }
    }

    var isPrivacySafe: Bool {
        unsafeFieldNames.isEmpty
    }

    func counter(_ name: String) -> Int {
        counters[name] ?? 0
    }
}

/// Process-local correlation only. None of these numeric fields is derived
/// from an account, JID, query, message, archive identifier, or payload.
struct ChatOpenPerformanceTraceContext: Equatable, Hashable {
    let traceID: UInt64
    let generation: UInt64
    let kindCode: UInt64
    let purposeCode: UInt64

    init?(
        traceID: UInt64,
        generation: UInt64,
        kindCode: UInt64,
        purposeCode: UInt64
    ) {
        guard traceID != 0, generation != 0 else {
            return nil
        }
        self.traceID = traceID
        self.generation = generation
        self.kindCode = kindCode
        self.purposeCode = purposeCode
    }
}

enum ChatOpenPerformanceTraceKind: UInt64 {
    case initialOpen = 1
    case paging = 2
}

enum ChatOpenPerformanceTracePurpose: UInt64 {
    case normalRoute = 1
    case notificationRoute = 2
    case explicitTargetRoute = 3
    case fallbackRoute = 4
}

enum ChatOpenPerformanceTraceContextFactory {
    private static let lock = NSLock()
    private static var nextTraceID = UInt64.random(in: 1...UInt64.max)
    private static var nextGeneration = UInt64.random(in: 1...UInt64.max)

    static func make(
        kind: ChatOpenPerformanceTraceKind,
        purpose: ChatOpenPerformanceTracePurpose
    ) -> ChatOpenPerformanceTraceContext {
        lock.lock()
        let traceID = takeNonzero(&nextTraceID)
        let generation = takeNonzero(&nextGeneration)
        lock.unlock()
        // Both allocator values are normalized to nonzero under the lock, so
        // construction cannot fail. Keep the failable public initializer as a
        // guard for externally supplied/test contexts.
        return ChatOpenPerformanceTraceContext(
            traceID: traceID,
            generation: generation,
            kindCode: kind.rawValue,
            purposeCode: purpose.rawValue
        )!
    }

    private static func takeNonzero(_ value: inout UInt64) -> UInt64 {
        if value == 0 {
            value = 1
        }
        let result = value
        value &+= 1
        if value == 0 {
            value = 1
        }
        return result
    }
}

enum ChatPerformanceIntervalTerminal: UInt64, Equatable {
    case committed = 1
    case failed = 2
    case cancelled = 3
}

struct ChatPerformanceTraceRecord: Equatable {
    enum Kind: UInt64, Equatable {
        case event = 1
        case begin = 2
        case end = 3
    }

    let kind: Kind
    let phase: ChatPerformanceSignpostPhase
    let context: ChatOpenPerformanceTraceContext?
    let terminal: ChatPerformanceIntervalTerminal?
    /// Process-local recorder order. It is never derived from product data.
    let emissionSequence: UInt64
    let monotonicNanoseconds: UInt64
    let threadCode: UInt64
    private let counters: [String: Int]

    fileprivate init(
        kind: Kind,
        phase: ChatPerformanceSignpostPhase,
        context: ChatOpenPerformanceTraceContext?,
        terminal: ChatPerformanceIntervalTerminal?,
        emissionSequence: UInt64,
        monotonicNanoseconds: UInt64,
        threadCode: UInt64,
        counters: [String: Int]
    ) {
        self.kind = kind
        self.phase = phase
        self.context = context
        self.terminal = terminal
        self.emissionSequence = emissionSequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.threadCode = threadCode
        self.counters = counters
    }

    var sortedCounterNames: [String] {
        counters.keys.sorted()
    }

    var isPrivacySafe: Bool {
        ChatPerformanceMetricSnapshot(
            phase: phase,
            counters: counters
        ).isPrivacySafe
    }

    func counter(_ name: String) -> Int {
        counters[name] ?? 0
    }
}

/// Lock-safe XCTest/lab sink. Production signposts do not depend on a sink
/// being installed, and installing one never changes the traced code path.
final class ChatPerformanceTraceRecorder {
    private let lock = NSLock()
    private let monotonicClock: () -> UInt64
    private var records: [ChatPerformanceTraceRecord] = []

    init(
        monotonicClock: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.monotonicClock = monotonicClock
    }

    fileprivate func monotonicNanoseconds() -> UInt64 {
        monotonicClock()
    }

    fileprivate func append(_ record: ChatPerformanceTraceRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func snapshot() -> [ChatPerformanceTraceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

final class ChatPerformanceTraceRecorderInstallation {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    fileprivate init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let work: (() -> Void)?
        lock.lock()
        work = cancellation
        cancellation = nil
        lock.unlock()
        work?()
    }

    deinit {
        cancel()
    }
}

struct ChatReferencePrepareMetrics: Equatable {
    let referenceCount: Int
    let durationMs: Int
    let slowReferenceCount: Int

    var snapshot: ChatPerformanceMetricSnapshot {
        ChatPerformanceMetricSnapshot(
            phase: .referencePrepare,
            counters: [
                "referenceCount": referenceCount,
                "durationMs": durationMs,
                "slowReferenceCount": slowReferenceCount
            ]
        )
    }
}

enum ChatPerformanceSignposts {
    static let subsystem = "com.xabber.ios.chat"
    static let category = "performance"
    static let maximumPublicCounterCount = 4

    fileprivate static let log = OSLog(subsystem: subsystem, category: category)
    private static let recorderLock = NSLock()
    private static var recorders: [UUID: ChatPerformanceTraceRecorder] = [:]
    private static var recorderEmissionSequence: UInt64 = 0

    private final class IntervalState {
        let phase: ChatPerformanceSignpostPhase
        let context: ChatOpenPerformanceTraceContext?
        let signpostID: OSSignpostID?

        private let lock = NSLock()
        private var didEnd: Bool

        init(
            phase: ChatPerformanceSignpostPhase,
            context: ChatOpenPerformanceTraceContext?,
            counters: [String: Int],
            isValid: Bool
        ) {
            self.phase = phase
            self.context = context
            self.didEnd = !isValid
            guard isValid else {
                self.signpostID = nil
                return
            }

            let signpostID = OSSignpostID(log: ChatPerformanceSignposts.log)
            self.signpostID = signpostID
            let arguments = ChatPerformanceSignposts.signpostArguments(
                context: context,
                terminal: nil,
                counters: counters
            )
            os_signpost(
                .begin,
                log: ChatPerformanceSignposts.log,
                name: phase.signpostName,
                signpostID: signpostID,
                "trace=%{public}llu generation=%{public}llu kind=%{public}llu purpose=%{public}llu terminal=%{public}llu fields=%{public}llu value0=%{public}lld value1=%{public}lld value2=%{public}lld value3=%{public}lld",
                arguments.traceID,
                arguments.generation,
                arguments.kindCode,
                arguments.purposeCode,
                arguments.terminalCode,
                arguments.counterCount,
                arguments.values[0],
                arguments.values[1],
                arguments.values[2],
                arguments.values[3]
            )
            ChatPerformanceSignposts.publish(
                kind: .begin,
                phase: phase,
                context: context,
                terminal: nil,
                counters: counters
            )
        }

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !didEnd
        }

        func end(
            terminal: ChatPerformanceIntervalTerminal,
            counters: [String: Int]
        ) -> Bool {
            // A caller mistake in optional diagnostic fields must never leave a
            // production interval open. Drop the names, retain only the public
            // rejected-field count, and still publish the requested terminal.
            let terminalCounters = ChatPerformanceSignposts.privacySafeTerminalCounters(
                phase: phase,
                counters: counters
            )

            lock.lock()
            guard !didEnd, let signpostID else {
                lock.unlock()
                return false
            }
            didEnd = true
            lock.unlock()

            let arguments = ChatPerformanceSignposts.signpostArguments(
                context: context,
                terminal: terminal,
                counters: terminalCounters
            )
            os_signpost(
                .end,
                log: ChatPerformanceSignposts.log,
                name: phase.signpostName,
                signpostID: signpostID,
                "trace=%{public}llu generation=%{public}llu kind=%{public}llu purpose=%{public}llu terminal=%{public}llu fields=%{public}llu value0=%{public}lld value1=%{public}lld value2=%{public}lld value3=%{public}lld",
                arguments.traceID,
                arguments.generation,
                arguments.kindCode,
                arguments.purposeCode,
                arguments.terminalCode,
                arguments.counterCount,
                arguments.values[0],
                arguments.values[1],
                arguments.values[2],
                arguments.values[3]
            )
            ChatPerformanceSignposts.publish(
                kind: .end,
                phase: phase,
                context: context,
                terminal: terminal,
                counters: terminalCounters
            )
            return true
        }
    }

    struct Interval {
        let phase: ChatPerformanceSignpostPhase

        private let state: IntervalState

        fileprivate init(
            phase: ChatPerformanceSignpostPhase,
            context: ChatOpenPerformanceTraceContext?,
            counters: [String: Int]
        ) {
            self.phase = phase
            self.state = IntervalState(
                phase: phase,
                context: context,
                counters: counters,
                isValid: ChatPerformanceSignposts.isPrivacySafe(
                    phase: phase,
                    counters: counters
                )
            )
        }

        var isActive: Bool {
            state.isActive
        }

        @discardableResult
        mutating func end() -> Bool {
            state.end(terminal: .committed, counters: [:])
        }

        @discardableResult
        mutating func end(
            terminal: ChatPerformanceIntervalTerminal,
            counters: [String: Int] = [:]
        ) -> Bool {
            state.end(terminal: terminal, counters: counters)
        }
    }

    static func begin(
        _ phase: ChatPerformanceSignpostPhase,
        context: ChatOpenPerformanceTraceContext? = nil,
        counters: [String: Int] = [:]
    ) -> Interval {
        Interval(phase: phase, context: context, counters: counters)
    }

    @discardableResult
    static func event(
        _ phase: ChatPerformanceSignpostPhase,
        context: ChatOpenPerformanceTraceContext? = nil,
        terminal: ChatPerformanceIntervalTerminal? = nil,
        counters: [String: Int] = [:]
    ) -> Bool {
        guard isPrivacySafe(phase: phase, counters: counters) else {
            return false
        }
        let arguments = signpostArguments(
            context: context,
            terminal: terminal,
            counters: counters
        )
        os_signpost(
            .event,
            log: log,
            name: phase.signpostName,
            "trace=%{public}llu generation=%{public}llu kind=%{public}llu purpose=%{public}llu terminal=%{public}llu fields=%{public}llu value0=%{public}lld value1=%{public}lld value2=%{public}lld value3=%{public}lld",
            arguments.traceID,
            arguments.generation,
            arguments.kindCode,
            arguments.purposeCode,
            arguments.terminalCode,
            arguments.counterCount,
            arguments.values[0],
            arguments.values[1],
            arguments.values[2],
            arguments.values[3]
        )
        publish(
            kind: .event,
            phase: phase,
            context: context,
            terminal: terminal,
            counters: counters
        )
        return true
    }

    static func installRecorderForTesting(
        _ recorder: ChatPerformanceTraceRecorder
    ) -> ChatPerformanceTraceRecorderInstallation {
        let identifier = UUID()
        recorderLock.lock()
        recorders[identifier] = recorder
        recorderLock.unlock()
        return ChatPerformanceTraceRecorderInstallation {
            recorderLock.lock()
            recorders.removeValue(forKey: identifier)
            recorderLock.unlock()
        }
    }

    @discardableResult
    static func measure<T>(
        _ phase: ChatPerformanceSignpostPhase,
        context: ChatOpenPerformanceTraceContext? = nil,
        counters: [String: Int] = [:],
        _ body: () throws -> T
    ) rethrows -> T {
        var interval = begin(phase, context: context, counters: counters)
        do {
            let value = try body()
            interval.end(terminal: .committed)
            return value
        } catch {
            interval.end(terminal: .failed)
            throw error
        }
    }

    private static func isPrivacySafe(
        phase: ChatPerformanceSignpostPhase,
        counters: [String: Int]
    ) -> Bool {
        counters.count <= maximumPublicCounterCount &&
            ChatPerformanceMetricSnapshot(
                phase: phase,
                counters: counters
            ).isPrivacySafe
    }

    private static func privacySafeTerminalCounters(
        phase: ChatPerformanceSignpostPhase,
        counters: [String: Int]
    ) -> [String: Int] {
        guard !isPrivacySafe(phase: phase, counters: counters) else {
            return counters
        }
        return ["rejectedFieldCount": counters.count]
    }

    private static func publish(
        kind: ChatPerformanceTraceRecord.Kind,
        phase: ChatPerformanceSignpostPhase,
        context: ChatOpenPerformanceTraceContext?,
        terminal: ChatPerformanceIntervalTerminal?,
        counters: [String: Int]
    ) {
        recorderLock.lock()
        guard !recorders.isEmpty else {
            recorderLock.unlock()
            return
        }
        recorderEmissionSequence &+= 1
        if recorderEmissionSequence == 0 {
            recorderEmissionSequence = 1
        }
        // Publish under the installation lock so concurrent emitters and a
        // racing cancellation have one deterministic linearization point.
        recorders.values.forEach { recorder in
            recorder.append(ChatPerformanceTraceRecord(
                kind: kind,
                phase: phase,
                context: context,
                terminal: terminal,
                emissionSequence: recorderEmissionSequence,
                monotonicNanoseconds: recorder.monotonicNanoseconds(),
                threadCode: Thread.isMainThread ? 1 : 2,
                counters: counters
            ))
        }
        recorderLock.unlock()
    }

    private static func signpostArguments(
        context: ChatOpenPerformanceTraceContext?,
        terminal: ChatPerformanceIntervalTerminal?,
        counters: [String: Int]
    ) -> (
        traceID: UInt64,
        generation: UInt64,
        kindCode: UInt64,
        purposeCode: UInt64,
        terminalCode: UInt64,
        counterCount: UInt64,
        values: [Int64]
    ) {
        var values = counters.keys.sorted().prefix(4).map {
            Int64(clamping: counters[$0] ?? 0)
        }
        while values.count < 4 {
            values.append(0)
        }
        return (
            traceID: context?.traceID ?? 0,
            generation: context?.generation ?? 0,
            kindCode: context?.kindCode ?? 0,
            purposeCode: context?.purposeCode ?? 0,
            terminalCode: terminal?.rawValue ?? 0,
            counterCount: UInt64(counters.count),
            values: values
        )
    }
}

enum ChatOpenPerformancePresentationReceipt: UInt64, Hashable {
    case skeleton = 1
    case content = 2
    case empty = 3

    fileprivate var signpostPhase: ChatPerformanceSignpostPhase {
        switch self {
        case .skeleton:
            return .skeletonReceipt
        case .content:
            return .contentReceipt
        case .empty:
            return .emptyReceipt
        }
    }

    fileprivate var isTerminalPresentation: Bool {
        self != .skeleton
    }
}

struct ChatOpenPerformanceStableFrameEligibility: Equatable {
    let hasWindow: Bool
    let isViewVisible: Bool
    let isForegroundActive: Bool
    let isCurrentPresentation: Bool
    let hasPendingCorrection: Bool
    let isWindowVisible: Bool
    let isSceneForegroundActive: Bool

    init(
        hasWindow: Bool,
        isViewVisible: Bool,
        isForegroundActive: Bool,
        isCurrentPresentation: Bool,
        hasPendingCorrection: Bool,
        isWindowVisible: Bool = true,
        isSceneForegroundActive: Bool = true
    ) {
        self.hasWindow = hasWindow
        self.isViewVisible = isViewVisible
        self.isForegroundActive = isForegroundActive
        self.isCurrentPresentation = isCurrentPresentation
        self.hasPendingCorrection = hasPendingCorrection
        self.isWindowVisible = isWindowVisible
        self.isSceneForegroundActive = isSceneForegroundActive
    }

    static let eligible = ChatOpenPerformanceStableFrameEligibility(
        hasWindow: true,
        isViewVisible: true,
        isForegroundActive: true,
        isCurrentPresentation: true,
        hasPendingCorrection: false,
        isWindowVisible: true,
        isSceneForegroundActive: true
    )

    var permitsStableFrame: Bool {
        hasWindow &&
            isViewVisible &&
            isForegroundActive &&
            isCurrentPresentation &&
            isWindowVisible &&
            isSceneForegroundActive &&
            !hasPendingCorrection
    }
}

struct ChatOpenPerformanceStableFrameLifecycleSnapshot: Equatable {
    let isCurrentContext: Bool
    let hasRequiredPresentationReceipt: Bool
    let hasPendingStableFrame: Bool
    let hasEmittedStableFrame: Bool
}

/// Generation gate for the UI-owned part of a chat-open trace. The lifecycle
/// deliberately knows no account, JID, query, message, or archive identifier:
/// late callbacks can prove only that they still carry the accepted opaque
/// context before publishing a presentation receipt.
final class ChatOpenPerformanceTraceLifecycle {
    private let lock = NSLock()
    private var acceptedContext: ChatOpenPerformanceTraceContext?
    private var presentingInterval: ChatPerformanceSignposts.Interval?
    private var emittedReceipts: Set<ChatOpenPerformancePresentationReceipt> = []
    private var terminalReceipt: ChatOpenPerformancePresentationReceipt?
    private var pendingStableFrameContext: ChatOpenPerformanceTraceContext?
    private var didEmitStableFrame = false

    var currentContext: ChatOpenPerformanceTraceContext? {
        lock.lock()
        defer { lock.unlock() }
        return acceptedContext
    }

    @discardableResult
    func accept(
        context: ChatOpenPerformanceTraceContext,
        emitsOpenRequest: Bool
    ) -> Bool {
        guard context.kindCode == ChatOpenPerformanceTraceKind.initialOpen.rawValue else {
            return false
        }

        lock.lock()
        guard acceptedContext != context else {
            lock.unlock()
            return false
        }
        var cancelledPresentation = presentingInterval
        acceptedContext = context
        presentingInterval = nil
        emittedReceipts.removeAll(keepingCapacity: true)
        terminalReceipt = nil
        pendingStableFrameContext = nil
        didEmitStableFrame = false
        lock.unlock()

        cancelledPresentation?.end(terminal: .cancelled)
        if emitsOpenRequest {
            ChatPerformanceSignposts.event(.openRequest, context: context)
        }
        return true
    }

    func isCurrent(_ context: ChatOpenPerformanceTraceContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptedContext == context
    }

    @discardableResult
    func beginPresenting(context: ChatOpenPerformanceTraceContext) -> Bool {
        lock.lock()
        guard acceptedContext == context,
              presentingInterval == nil,
              terminalReceipt == nil else {
            lock.unlock()
            return false
        }
        presentingInterval = ChatPerformanceSignposts.begin(
            .presenting,
            context: context
        )
        lock.unlock()
        return true
    }

    @discardableResult
    func endPresenting(
        context: ChatOpenPerformanceTraceContext,
        terminal: ChatPerformanceIntervalTerminal
    ) -> Bool {
        lock.lock()
        guard acceptedContext == context,
              var interval = presentingInterval else {
            lock.unlock()
            return false
        }
        presentingInterval = nil
        lock.unlock()
        return interval.end(terminal: terminal)
    }

    @discardableResult
    func recordPresentationReceipt(
        _ receipt: ChatOpenPerformancePresentationReceipt,
        context: ChatOpenPerformanceTraceContext,
        schedulesStableFrame: Bool
    ) -> Bool {
        lock.lock()
        guard acceptedContext == context,
              !emittedReceipts.contains(receipt),
              !didEmitStableFrame else {
            lock.unlock()
            return false
        }
        if receipt.isTerminalPresentation {
            guard terminalReceipt == nil else {
                lock.unlock()
                return false
            }
            terminalReceipt = receipt
        }
        emittedReceipts.insert(receipt)
        if schedulesStableFrame {
            pendingStableFrameContext = context
        }
        lock.unlock()

        return ChatPerformanceSignposts.event(
            receipt.signpostPhase,
            context: context,
            counters: ["receiptCode": Int(receipt.rawValue)]
        )
    }

    func hasRecordedPresentationReceipt(
        _ receipt: ChatOpenPerformancePresentationReceipt,
        context: ChatOpenPerformanceTraceContext
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptedContext == context && emittedReceipts.contains(receipt)
    }

    func hasCommittedTerminalPresentationReceipt(
        context: ChatOpenPerformanceTraceContext
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptedContext == context && terminalReceipt != nil
    }

    func hasEmittedStableFrame(
        context: ChatOpenPerformanceTraceContext
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptedContext == context && didEmitStableFrame
    }

    func stableFrameLifecycleSnapshot(
        context: ChatOpenPerformanceTraceContext,
        requiredReceipt: ChatOpenPerformancePresentationReceipt
    ) -> ChatOpenPerformanceStableFrameLifecycleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ChatOpenPerformanceStableFrameLifecycleSnapshot(
            isCurrentContext: acceptedContext == context,
            hasRequiredPresentationReceipt:
                acceptedContext == context &&
                emittedReceipts.contains(requiredReceipt),
            hasPendingStableFrame:
                acceptedContext == context &&
                pendingStableFrameContext == context,
            hasEmittedStableFrame:
                acceptedContext == context && didEmitStableFrame
        )
    }

    /// Seeds a milestone already emitted by an earlier controller that owned
    /// the same active lease. This is intentionally limited to skeleton: a
    /// terminal content/empty receipt makes the trace non-adoptable.
    @discardableResult
    func adoptPresentationReceipt(
        _ receipt: ChatOpenPerformancePresentationReceipt,
        context: ChatOpenPerformanceTraceContext
    ) -> Bool {
        guard receipt == .skeleton else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard acceptedContext == context,
              !emittedReceipts.contains(receipt),
              terminalReceipt == nil,
              !didEmitStableFrame else {
            return false
        }
        emittedReceipts.insert(receipt)
        return true
    }

    @discardableResult
    func scheduleStableFrame(
        after receipt: ChatOpenPerformancePresentationReceipt,
        context: ChatOpenPerformanceTraceContext
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptedContext == context,
              emittedReceipts.contains(receipt),
              !didEmitStableFrame else {
            return false
        }
        pendingStableFrameContext = context
        return true
    }

    @discardableResult
    func consumeStableFrame(
        context: ChatOpenPerformanceTraceContext,
        eligibility: ChatOpenPerformanceStableFrameEligibility
    ) -> Bool {
        lock.lock()
        guard acceptedContext == context,
              pendingStableFrameContext == context,
              !didEmitStableFrame,
              eligibility.permitsStableFrame else {
            lock.unlock()
            return false
        }
        didEmitStableFrame = true
        pendingStableFrameContext = nil
        lock.unlock()

        return ChatPerformanceSignposts.event(.stableFrame, context: context)
    }

    @discardableResult
    func cancel(context: ChatOpenPerformanceTraceContext) -> Bool {
        lock.lock()
        guard acceptedContext == context else {
            lock.unlock()
            return false
        }
        var cancelledPresentation = presentingInterval
        acceptedContext = nil
        presentingInterval = nil
        pendingStableFrameContext = nil
        lock.unlock()

        cancelledPresentation?.end(terminal: .cancelled)
        return true
    }
}

enum ChatArchivePerformanceTraceOperation: UInt64, Equatable {
    case initialOpen = 1
    case olderPage = 2
    case newerPage = 3

    fileprivate var pageDirectionCode: Int? {
        switch self {
        case .initialOpen:
            return nil
        case .olderPage:
            return 1
        case .newerPage:
            return 2
        }
    }
}

/// Privacy boundary joining the UI-owned opaque open context to a real MAM
/// query. Owner and query identifiers exist only as in-memory lookup keys and
/// are never copied into a signpost, recorder record, or persisted receipt.
final class ChatArchivePerformanceTraceRegistry {
    enum Registration: Equatable {
        case started
        case joined
        case rejected
    }

    private struct QueryKey: Hashable {
        let owner: String
        let queryID: String
    }

    private final class State {
        let context: ChatOpenPerformanceTraceContext
        let operation: ChatArchivePerformanceTraceOperation
        var queuedInterval: ChatPerformanceSignposts.Interval?
        var transportInterval: ChatPerformanceSignposts.Interval?
        var persistenceInterval: ChatPerformanceSignposts.Interval?
        var didStartTransport = false
        var didReceiveRawFinal = false
        var didEmitIngressComplete = false
        var isPersistenceSealed = false
        var expectedIngressCount: Int?
        var receivedIngressCount = 0

        init(
            context: ChatOpenPerformanceTraceContext,
            operation: ChatArchivePerformanceTraceOperation
        ) {
            self.context = context
            self.operation = operation
        }
    }

    private struct Tombstone {
        let context: ChatOpenPerformanceTraceContext
        let terminal: ChatPerformanceIntervalTerminal
    }

    static let shared = ChatArchivePerformanceTraceRegistry()

    private let lock = NSLock()
    private let terminalCapacity: Int
    private var states: [QueryKey: State] = [:]
    private var tombstones: [QueryKey: Tombstone] = [:]
    private var tombstoneOrder: [QueryKey] = []

    init(terminalCapacity: Int = 128) {
        self.terminalCapacity = max(1, terminalCapacity)
    }

    @discardableResult
    func register(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext,
        operation: ChatArchivePerformanceTraceOperation
    ) -> Registration {
        let expectedKindCode: UInt64 = operation == .initialOpen
            ? ChatOpenPerformanceTraceKind.initialOpen.rawValue
            : ChatOpenPerformanceTraceKind.paging.rawValue
        guard !owner.isEmpty,
              !queryID.isEmpty,
              context.kindCode == expectedKindCode else {
            return .rejected
        }
        let key = QueryKey(owner: owner, queryID: queryID)
        lock.lock()
        defer { lock.unlock() }
        if let current = states[key] {
            return current.context == context && current.operation == operation
                ? .joined
                : .rejected
        }
        guard tombstones[key] == nil else {
            // Reusing a wire query identity would make an old final
            // indistinguishable from a new generation. Keep it rejected until
            // the bounded tombstone naturally expires.
            return .rejected
        }

        let state = State(context: context, operation: operation)
        switch operation {
        case .initialOpen:
            state.queuedInterval = ChatPerformanceSignposts.begin(
                .leaseQueued,
                context: context,
                counters: ["operationCode": Int(operation.rawValue)]
            )
        case .olderPage, .newerPage:
            ChatPerformanceSignposts.event(
                .pagePlan,
                context: context,
                counters: [
                    "directionCode": operation.pageDirectionCode ?? 0,
                    "remoteCode": 1
                ]
            )
        }
        states[key] = state
        return .started
    }

    @discardableResult
    func recordLocalPagePlan(
        context: ChatOpenPerformanceTraceContext,
        directionCode: Int
    ) -> Bool {
        ChatPerformanceSignposts.event(
            .pagePlan,
            context: context,
            counters: [
                "directionCode": directionCode,
                "remoteCode": 0
            ]
        )
    }

    func context(owner: String, queryID: String) -> ChatOpenPerformanceTraceContext? {
        let key = QueryKey(owner: owner, queryID: queryID)
        lock.lock()
        let value = states[key]?.context ?? tombstones[key]?.context
        lock.unlock()
        return value
    }

    /// UIKit may consume a remote page only after that exact paging context
    /// reached a committed persistence terminal. An active interval, failed or
    /// cancelled tombstone, wrong generation, and an initial-open context are
    /// all deliberately ineligible for a late datasource apply.
    func permitsPagePresentation(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext
    ) -> Bool {
        guard !owner.isEmpty,
              !queryID.isEmpty,
              context.kindCode == ChatOpenPerformanceTraceKind.paging.rawValue else {
            return false
        }
        let key = QueryKey(owner: owner, queryID: queryID)
        lock.lock()
        let permitsPresentation = tombstones[key]?.context == context &&
            tombstones[key]?.terminal == .committed
        lock.unlock()
        return permitsPresentation
    }

    @discardableResult
    func transportStarted(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext? = nil
    ) -> Bool {
        withMatchingState(owner: owner, queryID: queryID, context: context) { state in
            guard !state.didStartTransport, !state.didReceiveRawFinal else {
                return false
            }
            state.didStartTransport = true
            switch state.operation {
            case .initialOpen:
                Self.end(&state.queuedInterval, terminal: .committed)
                state.transportInterval = ChatPerformanceSignposts.begin(
                    .leaseTransport,
                    context: state.context
                )
            case .olderPage, .newerPage:
                state.transportInterval = ChatPerformanceSignposts.begin(
                    .pageQuery,
                    context: state.context,
                    counters: [
                        "directionCode": state.operation.pageDirectionCode ?? 0
                    ]
                )
            }
            return true
        }
    }

    @discardableResult
    func rawFinal(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext? = nil,
        deliveredCount: Int
    ) -> Bool {
        withMatchingState(owner: owner, queryID: queryID, context: context) { state in
            guard !state.didReceiveRawFinal else {
                return false
            }
            state.didReceiveRawFinal = true
            state.expectedIngressCount = max(0, deliveredCount)
            if !state.didStartTransport {
                // Defensive closure for a synchronous terminal racing the
                // transport-start callback. The request-send hook normally
                // starts this interval before the stream can answer.
                state.didStartTransport = true
                if state.operation == .initialOpen {
                    Self.end(&state.queuedInterval, terminal: .committed)
                    state.transportInterval = ChatPerformanceSignposts.begin(
                        .leaseTransport,
                        context: state.context
                    )
                } else {
                    state.transportInterval = ChatPerformanceSignposts.begin(
                        .pageQuery,
                        context: state.context,
                        counters: [
                            "directionCode": state.operation.pageDirectionCode ?? 0
                        ]
                    )
                }
            }
            Self.end(&state.transportInterval, terminal: .committed)
            ChatPerformanceSignposts.event(
                .rawFinal,
                context: state.context,
                counters: ["deliveredCount": max(0, deliveredCount)]
            )
            let persistencePhase: ChatPerformanceSignpostPhase =
                state.operation == .initialOpen ? .leasePersistence : .pagePersist
            state.persistenceInterval = ChatPerformanceSignposts.begin(
                persistencePhase,
                context: state.context
            )
            _ = emitIngressIfReady(state)
            return true
        }
    }

    @discardableResult
    func sealExpectedIngress(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext? = nil,
        expectedCount: Int?
    ) -> Bool {
        withMatchingState(owner: owner, queryID: queryID, context: context) { state in
            guard state.didReceiveRawFinal, !state.isPersistenceSealed else {
                return false
            }
            state.isPersistenceSealed = true
            if let expectedCount {
                state.expectedIngressCount = max(
                    state.expectedIngressCount ?? 0,
                    max(0, expectedCount)
                )
            }
            _ = emitIngressIfReady(state)
            return true
        }
    }

    @discardableResult
    func recordIngress(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext? = nil,
        receivedCount: Int
    ) -> Bool {
        withMatchingState(owner: owner, queryID: queryID, context: context) { state in
            state.receivedIngressCount = max(
                state.receivedIngressCount,
                max(0, receivedCount)
            )
            return emitIngressIfReady(state)
        }
    }

    @discardableResult
    func persistenceTerminal(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext? = nil,
        terminal: ChatPerformanceIntervalTerminal,
        persistedCount: Int,
        failedCount: Int
    ) -> Bool {
        terminalState(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: terminal,
            emitsPersistenceTerminal: true,
            persistedCount: persistedCount,
            failedCount: failedCount
        )
    }

    @discardableResult
    func terminate(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext? = nil,
        terminal: ChatPerformanceIntervalTerminal
    ) -> Bool {
        terminalState(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: terminal,
            emitsPersistenceTerminal: false,
            persistedCount: 0,
            failedCount: terminal == .failed ? 1 : 0
        )
    }

    func cancelAllForTesting() {
        lock.lock()
        let activeStates = Array(states.values)
        states.removeAll()
        tombstones.removeAll()
        tombstoneOrder.removeAll()
        activeStates.forEach { state in
            Self.end(&state.queuedInterval, terminal: .cancelled)
            Self.end(&state.transportInterval, terminal: .cancelled)
            Self.end(&state.persistenceInterval, terminal: .cancelled)
        }
        lock.unlock()
    }

    private func terminalState(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext?,
        terminal: ChatPerformanceIntervalTerminal,
        emitsPersistenceTerminal: Bool,
        persistedCount: Int,
        failedCount: Int
    ) -> Bool {
        guard !owner.isEmpty, !queryID.isEmpty else {
            return false
        }
        let key = QueryKey(owner: owner, queryID: queryID)
        lock.lock()
        guard let state = states[key],
              context == nil || state.context == context else {
            lock.unlock()
            return false
        }
        if emitsPersistenceTerminal {
            guard state.didReceiveRawFinal,
                  state.persistenceInterval?.isActive == true,
                  terminal != .committed || state.didEmitIngressComplete else {
                lock.unlock()
                return false
            }
            ChatPerformanceSignposts.event(
                .persistenceTerminal,
                context: state.context,
                terminal: terminal,
                counters: [
                    "persistedCount": max(0, persistedCount),
                    "failedCount": max(0, failedCount)
                ]
            )
        }
        Self.end(&state.queuedInterval, terminal: terminal)
        Self.end(&state.transportInterval, terminal: terminal)
        Self.end(
            &state.persistenceInterval,
            terminal: terminal,
            counters: [
                "persistedCount": max(0, persistedCount),
                "failedCount": max(0, failedCount)
            ]
        )
        states.removeValue(forKey: key)
        appendTombstoneLocked(
            Tombstone(context: state.context, terminal: terminal),
            for: key
        )
        lock.unlock()
        return true
    }

    private func withMatchingState(
        owner: String,
        queryID: String,
        context: ChatOpenPerformanceTraceContext?,
        _ body: (State) -> Bool
    ) -> Bool {
        guard !owner.isEmpty, !queryID.isEmpty else {
            return false
        }
        let key = QueryKey(owner: owner, queryID: queryID)
        lock.lock()
        guard let state = states[key],
              context == nil || state.context == context else {
            lock.unlock()
            return false
        }
        let result = body(state)
        lock.unlock()
        return result
    }

    private func emitIngressIfReady(_ state: State) -> Bool {
        guard state.didReceiveRawFinal,
              state.isPersistenceSealed,
              !state.didEmitIngressComplete,
              let expected = state.expectedIngressCount,
              state.receivedIngressCount >= expected else {
            return false
        }
        state.didEmitIngressComplete = true
        ChatPerformanceSignposts.event(
            .ingressComplete,
            context: state.context,
            counters: [
                "receivedCount": state.receivedIngressCount,
                "expectedCount": expected
            ]
        )
        return true
    }

    private func appendTombstoneLocked(_ tombstone: Tombstone, for key: QueryKey) {
        tombstones[key] = tombstone
        tombstoneOrder.removeAll { $0 == key }
        tombstoneOrder.append(key)
        while tombstoneOrder.count > terminalCapacity {
            tombstones.removeValue(forKey: tombstoneOrder.removeFirst())
        }
    }

    private static func end(
        _ interval: inout ChatPerformanceSignposts.Interval?,
        terminal: ChatPerformanceIntervalTerminal,
        counters: [String: Int] = [:]
    ) {
        guard var value = interval else {
            return
        }
        value.end(terminal: terminal, counters: counters)
        interval = value
    }
}
