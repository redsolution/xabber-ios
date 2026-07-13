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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//

import Foundation

enum ChatSearchTimestampMAMDirection: String, Equatable, Sendable {
    case atOrAfter
    case latestBefore
}

struct ChatSearchTimestampMAMRequestPlan: Equatable, Sendable {
    let queryId: String
    let requestID: UUID
    let generation: UInt64
    let scope: ChatSearchResult.Scope
    let selectedTimestamp: Date
    let direction: ChatSearchTimestampMAMDirection

    var conversationType: ClientSynchronizationManager.ConversationType? {
        ClientSynchronizationManager.ConversationType(
            rawValue: scope.conversationTypeRawValue
        )
    }

    var start: Date? {
        direction == .atOrAfter ? selectedTimestamp : nil
    }

    var end: Date? {
        direction == .latestBefore ? selectedTimestamp : nil
    }

    var nextPage: String? {
        direction == .latestBefore ? "" : nil
    }

    var flipPage: Bool {
        direction == .latestBefore
    }

    let max = 1

    static func make(
        fallback: ChatSearchTimestampRemoteFallback,
        requestID: UUID,
        generation: UInt64,
        direction: ChatSearchTimestampMAMDirection
    ) -> ChatSearchTimestampMAMRequestPlan {
        ChatSearchTimestampMAMRequestPlan(
            queryId: [
                "MAM timestamp",
                requestID.uuidString.lowercased(),
                String(generation),
                direction.rawValue
            ].joined(separator: ":"),
            requestID: requestID,
            generation: generation,
            scope: fallback.scope,
            selectedTimestamp: fallback.selectedTimestamp,
            direction: direction
        )
    }
}

struct ChatSearchTimestampMAMFailure: Equatable, Sendable {
    let reason: MessageArchiveRequestFailureReason
    let description: String?
}

enum ChatSearchTimestampMAMResolutionOutcome: Equatable, Sendable {
    case resolved(ChatSearchTimestampAnchor)
    case noMessage
    case failed(ChatSearchTimestampMAMFailure)
    case cancelled
}

protocol ChatSearchTimestampMAMResolving: AnyObject {
    func resolve(
        _ fallback: ChatSearchTimestampRemoteFallback,
        requestID: UUID,
        generation: UInt64,
        completion: @escaping (ChatSearchTimestampMAMResolutionOutcome) -> Void
    )

    @discardableResult
    func cancel(requestID: UUID) -> Bool
}

final class ChatSearchTimestampMAMResolver: ChatSearchTimestampMAMResolving {
    struct Dependencies {
        typealias Start = (
            ChatSearchTimestampMAMRequestPlan,
            MessageArchiveManager.RequestCallbacks
        ) -> Bool
        typealias Cancel = (String) -> Void

        let start: Start
        let cancel: Cancel

        init(start: @escaping Start, cancel: @escaping Cancel) {
            self.start = start
            self.cancel = cancel
        }
    }

    private struct ActiveRequest {
        let fallback: ChatSearchTimestampRemoteFallback
        let generation: UInt64
        let completion: (ChatSearchTimestampMAMResolutionOutcome) -> Void
        var direction: ChatSearchTimestampMAMDirection?
        var queryId: String?
        var candidate: ChatSearchTimestampAnchor?
        var finalizedQueryIds: Set<String> = []
    }

    private let dependencies: Dependencies
    private let stateLock = NSRecursiveLock()
    private var activeRequests: [UUID: ActiveRequest] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func resolve(
        _ fallback: ChatSearchTimestampRemoteFallback,
        requestID: UUID,
        generation: UInt64,
        completion: @escaping (ChatSearchTimestampMAMResolutionOutcome) -> Void
    ) {
        guard let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: fallback.scope.conversationTypeRawValue
        ) else {
            deliver(
                completion,
                outcome: .failed(.init(reason: .requestStartFailed, description: nil))
            )
            return
        }
        if conversationType.isEncrypted {
            deliver(completion, outcome: .noMessage)
            return
        }
        guard [.regular, .group, .channel].contains(conversationType) else {
            deliver(
                completion,
                outcome: .failed(.init(reason: .requestStartFailed, description: nil))
            )
            return
        }

        stateLock.lock()
        let replacedQueryId = activeRequests[requestID]?.queryId
        activeRequests[requestID] = ActiveRequest(
            fallback: fallback,
            generation: generation,
            completion: completion
        )
        stateLock.unlock()
        if let replacedQueryId {
            dependencies.cancel(replacedQueryId)
        }
        startAttempt(
            requestID: requestID,
            generation: generation,
            direction: .atOrAfter
        )
    }

    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        stateLock.lock()
        guard let active = activeRequests.removeValue(forKey: requestID) else {
            stateLock.unlock()
            return false
        }
        stateLock.unlock()
        if let queryId = active.queryId {
            dependencies.cancel(queryId)
        }
        deliver(active.completion, outcome: .cancelled)
        return true
    }

    private func startAttempt(
        requestID: UUID,
        generation: UInt64,
        direction: ChatSearchTimestampMAMDirection
    ) {
        stateLock.lock()
        guard var active = activeRequests[requestID],
              active.generation == generation else {
            stateLock.unlock()
            return
        }
        let plan = ChatSearchTimestampMAMRequestPlan.make(
            fallback: active.fallback,
            requestID: requestID,
            generation: generation,
            direction: direction
        )
        active.direction = direction
        active.queryId = plan.queryId
        active.candidate = nil
        activeRequests[requestID] = active
        stateLock.unlock()

        let callbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: { [weak self] item, queryId in
                self?.receive(
                    item,
                    queryId: queryId,
                    requestID: requestID,
                    generation: generation
                )
            },
            onEndPage: { [weak self] queryId, state, _, _, _ in
                self?.receiveFinal(
                    queryId: queryId,
                    pageState: state,
                    requestID: requestID,
                    generation: generation
                )
            },
            onFailure: { [weak self] event in
                self?.receiveFailure(
                    event,
                    requestID: requestID,
                    generation: generation
                )
            }
        )
        guard dependencies.start(plan, callbacks) else {
            finish(
                requestID: requestID,
                generation: generation,
                queryId: plan.queryId,
                outcome: .failed(.init(reason: .requestStartFailed, description: nil))
            )
            return
        }
    }

    private func receive(
        _ item: MessageStorageItem,
        queryId: String,
        requestID: UUID,
        generation: UInt64
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var active = activeRequests[requestID],
              active.generation == generation,
              active.queryId == queryId,
              let direction = active.direction,
              let anchor = ChatSearchTimestampAnchor.make(
                  from: item,
                  scope: active.fallback.scope
              ), isEligible(
                  anchor,
                  for: direction,
                  selectedTimestamp: active.fallback.selectedTimestamp
              ) else {
            return
        }
        if let current = active.candidate,
           !isPreferred(anchor, over: current, for: direction) {
            return
        }
        active.candidate = anchor
        activeRequests[requestID] = active
    }

    private func receiveFinal(
        queryId: String,
        pageState: MessageArchivePageEndState,
        requestID: UUID,
        generation: UInt64
    ) {
        stateLock.lock()
        guard var active = activeRequests[requestID],
              active.generation == generation,
              active.queryId == queryId,
              let direction = active.direction,
              active.finalizedQueryIds.insert(queryId).inserted else {
            stateLock.unlock()
            return
        }
        let persistedCandidate = pageState.persistedMessageCount > 0
            ? active.candidate
            : nil
        activeRequests[requestID] = active
        stateLock.unlock()

        if let persistedCandidate {
            finish(
                requestID: requestID,
                generation: generation,
                queryId: queryId,
                outcome: .resolved(persistedCandidate)
            )
        } else if direction == .atOrAfter {
            startAttempt(
                requestID: requestID,
                generation: generation,
                direction: .latestBefore
            )
        } else {
            finish(
                requestID: requestID,
                generation: generation,
                queryId: queryId,
                outcome: .noMessage
            )
        }
    }

    private func receiveFailure(
        _ event: MessageArchiveRequestFailureEvent,
        requestID: UUID,
        generation: UInt64
    ) {
        finish(
            requestID: requestID,
            generation: generation,
            queryId: event.queryId,
            outcome: .failed(.init(
                reason: event.reason,
                description: event.errorDescription
            ))
        )
    }

    private func finish(
        requestID: UUID,
        generation: UInt64,
        queryId: String,
        outcome: ChatSearchTimestampMAMResolutionOutcome
    ) {
        stateLock.lock()
        guard let active = activeRequests[requestID],
              active.generation == generation,
              active.queryId == queryId else {
            stateLock.unlock()
            return
        }
        activeRequests.removeValue(forKey: requestID)
        stateLock.unlock()
        deliver(active.completion, outcome: outcome)
    }

    private func deliver(
        _ completion: @escaping (ChatSearchTimestampMAMResolutionOutcome) -> Void,
        outcome: ChatSearchTimestampMAMResolutionOutcome
    ) {
        if Thread.isMainThread {
            completion(outcome)
        } else {
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    private func isEligible(
        _ anchor: ChatSearchTimestampAnchor,
        for direction: ChatSearchTimestampMAMDirection,
        selectedTimestamp: Date
    ) -> Bool {
        switch direction {
        case .atOrAfter:
            return anchor.anchor.date >= selectedTimestamp
        case .latestBefore:
            return anchor.anchor.date < selectedTimestamp
        }
    }

    private func isPreferred(
        _ candidate: ChatSearchTimestampAnchor,
        over current: ChatSearchTimestampAnchor,
        for direction: ChatSearchTimestampMAMDirection
    ) -> Bool {
        if candidate.anchor.date != current.anchor.date {
            switch direction {
            case .atOrAfter:
                return candidate.anchor.date < current.anchor.date
            case .latestBefore:
                return candidate.anchor.date > current.anchor.date
            }
        }
        return tieSortsBefore(candidate, current)
    }

    private func tieSortsBefore(
        _ lhs: ChatSearchTimestampAnchor,
        _ rhs: ChatSearchTimestampAnchor
    ) -> Bool {
        switch (lhs.id, rhs.id) {
        case let (.archived(lhsID), .archived(rhsID)):
            let comparison = compareArchiveIds(lhsID, rhsID) ?? .orderedSame
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.anchor.primary < rhs.anchor.primary
        case (.archived, .primary):
            return true
        case (.primary, .archived):
            return false
        case let (.primary(lhsID), .primary(rhsID)):
            return lhsID < rhsID
        }
    }
}
