import CoreGraphics
import Foundation

struct ChatScrollWorkOptions: OptionSet, Equatable {
    let rawValue: Int

    static let updateScrollPosition = ChatScrollWorkOptions(rawValue: 1 << 0)
    static let updateFloatingDate = ChatScrollWorkOptions(rawValue: 1 << 1)
    static let advanceReadBoundary = ChatScrollWorkOptions(rawValue: 1 << 2)
    static let updateVoiceQueue = ChatScrollWorkOptions(rawValue: 1 << 3)
    static let evaluateBoundaryPaging = ChatScrollWorkOptions(rawValue: 1 << 4)
}

final class ChatUIResponsivenessGate {
    enum Reason: Equatable {
        case chatOpen
        case keyboardFrame
        case typing
    }

    enum WorkKind: Equatable {
        case presentationRefresh
        case criticalUserAction
    }

    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    static let shared = ChatUIResponsivenessGate()
    static let defaultHoldDuration: TimeInterval = 0.22
    static let chatOpenHoldDuration: TimeInterval = 0.45
    static let keyboardFrameHoldPadding: TimeInterval = 0.05

    private let now: () -> Date
    private let schedule: Schedule
    private var activeUntil: Date?
    private var generation = 0
    private var pendingDeferredWork: [String: () -> Void] = [:]
    private var isDeferredFlushScheduled = false

    init(
        now: @escaping () -> Date = Date.init,
        schedule: Schedule? = nil
    ) {
        self.now = now
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    var isActive: Bool {
        expireIfNeeded()
        guard let activeUntil else {
            return false
        }
        return now() < activeUntil
    }

    func activate(
        reason: Reason,
        duration: TimeInterval = ChatUIResponsivenessGate.defaultHoldDuration
    ) {
        let expiration = now().addingTimeInterval(max(0, duration))
        if activeUntil.map({ $0 < expiration }) ?? true {
            activeUntil = expiration
        }

        generation += 1
        let scheduledGeneration = generation
        let delay = max(0, expiration.timeIntervalSince(now()))
        schedule(delay) { [weak self] in
            self?.expireIfNeeded(generation: scheduledGeneration)
        }
    }

    func resetForTesting() {
        activeUntil = nil
        generation += 1
        pendingDeferredWork.removeAll()
        isDeferredFlushScheduled = false
    }

    static func shouldDefer(
        workKind: WorkKind,
        isActive: Bool
    ) -> Bool {
        isActive && workKind == .presentationRefresh
    }

    static func holdDuration(keyboardAnimationDuration: TimeInterval) -> TimeInterval {
        max(defaultHoldDuration, max(0, keyboardAnimationDuration) + keyboardFrameHoldPadding)
    }

    func runOrDefer(
        workKind: WorkKind,
        key: String,
        work: @escaping () -> Void
    ) {
        guard Self.shouldDefer(workKind: workKind, isActive: isActive) else {
            work()
            return
        }

        pendingDeferredWork[key] = work
        scheduleDeferredFlushIfNeeded()
    }

    private func expireIfNeeded(generation scheduledGeneration: Int? = nil) {
        if let scheduledGeneration, scheduledGeneration != generation {
            return
        }
        guard let activeUntil,
              now() >= activeUntil else {
            return
        }
        self.activeUntil = nil
    }

    private func scheduleDeferredFlushIfNeeded() {
        guard !isDeferredFlushScheduled else {
            return
        }

        isDeferredFlushScheduled = true
        schedule(Self.defaultHoldDuration) { [weak self] in
            self?.flushDeferredWorkIfReady()
        }
    }

    private func flushDeferredWorkIfReady() {
        isDeferredFlushScheduled = false
        guard !isActive else {
            scheduleDeferredFlushIfNeeded()
            return
        }

        let workItems = Array(pendingDeferredWork.values)
        pendingDeferredWork.removeAll()
        workItems.forEach { $0() }
    }
}

struct ChatScrollWorkRequest: Equatable {
    let contentOffsetY: CGFloat
    let gestureTranslationY: CGFloat
    let isUserScrolling: Bool
    let visibleIndexPaths: [IndexPath]
    let work: ChatScrollWorkOptions

    func effectiveWork(isInteractionGateActive: Bool) -> ChatScrollWorkOptions {
        var effectiveWork = work
        if !isUserScrolling {
            effectiveWork.remove(.evaluateBoundaryPaging)
        }
        if isInteractionGateActive && !isUserScrolling {
            effectiveWork.remove(.updateFloatingDate)
            effectiveWork.remove(.updateVoiceQueue)
        }
        return effectiveWork
    }

    func merging(with newer: ChatScrollWorkRequest) -> ChatScrollWorkRequest {
        ChatScrollWorkRequest(
            contentOffsetY: newer.contentOffsetY,
            gestureTranslationY: newer.gestureTranslationY,
            isUserScrolling: newer.isUserScrolling,
            visibleIndexPaths: newer.visibleIndexPaths,
            work: work.union(newer.work)
        )
    }
}

final class ChatScrollWorkScheduler {
    typealias Schedule = (@escaping () -> Void) -> Void
    typealias Handler = (ChatScrollWorkRequest) -> Void

    static let defaultCooldown: TimeInterval = 1.0 / 60.0

    private let schedule: Schedule
    private let handler: Handler
    private var pendingRequest: ChatScrollWorkRequest?
    private var isScheduled = false
    private var generation = 0

    init(schedule: Schedule? = nil, handler: @escaping Handler) {
        self.schedule = schedule ?? Self.defaultSchedule
        self.handler = handler
    }

    func enqueue(_ request: ChatScrollWorkRequest) {
        if let pendingRequest {
            self.pendingRequest = pendingRequest.merging(with: request)
        } else {
            self.pendingRequest = request
        }

        guard !isScheduled else {
            return
        }

        isScheduled = true
        generation += 1
        let scheduledGeneration = generation
        schedule { [weak self] in
            self?.runScheduled(generation: scheduledGeneration)
        }
    }

    func flush() {
        guard pendingRequest != nil else {
            isScheduled = false
            generation += 1
            return
        }

        isScheduled = false
        generation += 1
        runPending()
    }

    func cancel() {
        pendingRequest = nil
        isScheduled = false
        generation += 1
    }

    private static func defaultSchedule(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + defaultCooldown, execute: work)
    }

    private func runScheduled(generation scheduledGeneration: Int) {
        guard isScheduled,
              scheduledGeneration == generation else {
            return
        }

        isScheduled = false
        runPending()
    }

    private func runPending() {
        guard let request = pendingRequest else {
            return
        }

        pendingRequest = nil
        handler(request)
    }
}
