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

struct ChatScrollWorkRequest: Equatable {
    let contentOffsetY: CGFloat
    let gestureTranslationY: CGFloat
    let isUserScrolling: Bool
    let visibleIndexPaths: [IndexPath]
    let work: ChatScrollWorkOptions

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
