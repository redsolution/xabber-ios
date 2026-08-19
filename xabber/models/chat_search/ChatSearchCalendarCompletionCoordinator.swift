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
//

import Foundation
import XMPPFramework

struct ChatSearchCalendarCompletionRequest: Equatable, Sendable {
    let id: UUID
    let generation: UInt64
    let scope: ChatSearchResult.Scope
    let selectedTimestamp: Date
    let displayedCandidates: [ChatSearchTimestampAnchor]
    let displayedCoverage: ChatSearchTimestampCoverageProof?

    var localRequest: ChatSearchTimestampResolutionRequest {
        ChatSearchTimestampResolutionRequest(
            id: id,
            scope: scope,
            selectedTimestamp: selectedTimestamp,
            displayedCandidates: displayedCandidates,
            displayedCoverage: displayedCoverage
        )
    }
}

enum ChatSearchCalendarCompletionOutcome: Equatable, Sendable {
    case resolved(ChatSearchTimestampAnchor)
    case noMessage
    case failed(ChatSearchTimestampMAMFailure)
    case cancelled
}

protocol ChatSearchCalendarCompletionCoordinating: AnyObject {
    var activeRequestID: UUID? { get }

    @discardableResult
    func begin(
        _ request: ChatSearchCalendarCompletionRequest,
        completion: @escaping (ChatSearchCalendarCompletionOutcome) -> Void
    ) -> Bool

    @discardableResult
    func cancel() -> Bool
}

final class ChatSearchCalendarCompletionCoordinator: ChatSearchCalendarCompletionCoordinating {
    private struct ActiveRequest {
        let request: ChatSearchCalendarCompletionRequest
        let completion: (ChatSearchCalendarCompletionOutcome) -> Void
    }

    private let localResolver: ChatSearchTimestampResolving
    private let remoteResolver: ChatSearchTimestampMAMResolving
    private let stateLock = NSRecursiveLock()
    private var active: ActiveRequest?

    var activeRequestID: UUID? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active?.request.id
    }

    init(
        localResolver: ChatSearchTimestampResolving,
        remoteResolver: ChatSearchTimestampMAMResolving
    ) {
        self.localResolver = localResolver
        self.remoteResolver = remoteResolver
    }

    @discardableResult
    func begin(
        _ request: ChatSearchCalendarCompletionRequest,
        completion: @escaping (ChatSearchCalendarCompletionOutcome) -> Void
    ) -> Bool {
        stateLock.lock()
        guard active == nil else {
            stateLock.unlock()
            return false
        }
        active = ActiveRequest(request: request, completion: completion)
        stateLock.unlock()

        localResolver.resolve(request.localRequest) { [weak self] outcome in
            self?.receiveLocal(outcome, request: request)
        }
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        stateLock.lock()
        guard let active else {
            stateLock.unlock()
            return false
        }
        self.active = nil
        stateLock.unlock()

        _ = localResolver.cancel(requestID: active.request.id)
        _ = remoteResolver.cancel(requestID: active.request.id)
        deliver(active.completion, outcome: .cancelled)
        return true
    }

    private func receiveLocal(
        _ outcome: ChatSearchTimestampResolutionOutcome,
        request: ChatSearchCalendarCompletionRequest
    ) {
        guard isCurrent(request) else { return }
        switch outcome {
        case .resolvedLocal(let anchor):
            finish(request, outcome: .resolved(anchor))
        case .needsRemote(let fallback):
            remoteResolver.resolve(
                fallback,
                requestID: request.id,
                generation: request.generation
            ) { [weak self] remoteOutcome in
                self?.receiveRemote(remoteOutcome, request: request)
            }
        case .noMessage:
            finish(request, outcome: .noMessage)
        case .cancelled:
            finish(request, outcome: .cancelled)
        }
    }

    private func receiveRemote(
        _ outcome: ChatSearchTimestampMAMResolutionOutcome,
        request: ChatSearchCalendarCompletionRequest
    ) {
        guard isCurrent(request) else { return }
        switch outcome {
        case .resolved(let anchor):
            finish(request, outcome: .resolved(anchor))
        case .noMessage:
            finish(request, outcome: .noMessage)
        case .failed(let failure):
            finish(request, outcome: .failed(failure))
        case .cancelled:
            finish(request, outcome: .cancelled)
        }
    }

    private func isCurrent(_ request: ChatSearchCalendarCompletionRequest) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active?.request.id == request.id &&
            active?.request.generation == request.generation &&
            active?.request.scope == request.scope
    }

    private func finish(
        _ request: ChatSearchCalendarCompletionRequest,
        outcome: ChatSearchCalendarCompletionOutcome
    ) {
        stateLock.lock()
        guard let active,
              active.request.id == request.id,
              active.request.generation == request.generation,
              active.request.scope == request.scope else {
            stateLock.unlock()
            return
        }
        self.active = nil
        stateLock.unlock()
        deliver(active.completion, outcome: outcome)
    }

    private func deliver(
        _ completion: @escaping (ChatSearchCalendarCompletionOutcome) -> Void,
        outcome: ChatSearchCalendarCompletionOutcome
    ) {
        if Thread.isMainThread {
            completion(outcome)
        } else {
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }
}

enum ChatSearchCalendarAnchorRequestFactory {
    static func make(
        anchor: ChatSearchTimestampAnchor,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatOpenMessageRequest? {
        guard anchor.scope.owner.isNotEmpty,
              anchor.scope.jid.isNotEmpty,
              anchor.scope.conversationTypeRawValue == conversationType.rawValue else {
            return nil
        }
        let archivedID = anchor.anchor.archivedId.isNotEmpty
            ? anchor.anchor.archivedId
            : nil
        let primary = archivedID == nil && anchor.anchor.primary.isNotEmpty
            ? anchor.anchor.primary
            : nil
        guard archivedID != nil || primary != nil else { return nil }

        return ChatOpenMessageRequest(
            chatJid: anchor.scope.jid,
            owner: anchor.scope.owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: primary,
                archivedId: archivedID,
                messageId: anchor.anchor.messageId.isNotEmpty
                    ? anchor.anchor.messageId
                    : nil,
                authorId: anchor.anchor.authorId?.isNotEmpty == true
                    ? anchor.anchor.authorId
                    : nil,
                bodyFingerprint: nil,
                sourceDate: anchor.anchor.date
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .search
        )
    }
}

/// Bridges the asynchronous account/UI-action stream selection to the bounded
/// timestamp resolver without making connection wait time part of UIKit state.
final class ChatSearchTimestampMAMTransport {
    private let stateLock = NSRecursiveLock()
    private var activeQueryIDs: Set<String> = []
    private var managersByQueryID: [String: MessageArchiveManager] = [:]
    private var schedulerCompletionsByQueryID: [String: () -> Void] = [:]

    @discardableResult
    func start(
        plan: ChatSearchTimestampMAMRequestPlan,
        callbacks: MessageArchiveManager.RequestCallbacks
    ) -> Bool {
        guard plan.scope.owner.isNotEmpty,
              plan.scope.jid.isNotEmpty,
              let conversationType = plan.conversationType,
              ChatSearchTimestampMAMSupportPolicy.supports(conversationType) else {
            return false
        }

        stateLock.lock()
        guard !activeQueryIDs.contains(plan.queryId) else {
            stateLock.unlock()
            return false
        }
        activeQueryIDs.insert(plan.queryId)
        stateLock.unlock()

        guard let account = AccountManager.shared.find(for: plan.scope.owner) else {
            failStart(plan: plan, callbacks: callbacks, streamKind: .unknown)
            return false
        }
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .foreground,
            resource: .mamArchive,
            deduplicationKey: "archive.timestamp.\(plan.scope.owner).\(plan.queryId)",
            requiresAuthenticatedStream: true,
            unavailable: { [weak self] in
                self?.failStart(
                    plan: plan,
                    callbacks: callbacks,
                    streamKind: .primary
                )
            }
        ) { [weak self] user, stream, finish in
            guard let self else {
                finish()
                return
            }
            self.send(
                plan: plan,
                callbacks: callbacks,
                stream: stream,
                manager: user.mam,
                streamKind: .primary,
                schedulerCompletion: finish
            )
        }
        return true
    }

    func cancel(queryID: String) {
        stateLock.lock()
        activeQueryIDs.remove(queryID)
        let isOnWire = managersByQueryID[queryID] != nil
        let schedulerCompletion = isOnWire
            ? nil
            : schedulerCompletionsByQueryID.removeValue(forKey: queryID)
        stateLock.unlock()
        // An on-wire SQL query is not cancellable. Keep its scheduler lease
        // until the matching final/failure callback, while the resolver's
        // generation gate ignores its late result.
        schedulerCompletion?()
    }

    private func send(
        plan: ChatSearchTimestampMAMRequestPlan,
        callbacks: MessageArchiveManager.RequestCallbacks,
        stream: XMPPStream,
        manager: MessageArchiveManager,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        schedulerCompletion: @escaping () -> Void
    ) {
        stateLock.lock()
        guard activeQueryIDs.contains(plan.queryId) else {
            stateLock.unlock()
            schedulerCompletion()
            return
        }
        managersByQueryID[plan.queryId] = manager
        schedulerCompletionsByQueryID[plan.queryId] = schedulerCompletion
        stateLock.unlock()

        let wrappedCallbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: callbacks.onMessage,
            onEndPage: { [weak self] queryID, state, first, last, count in
                self?.finish(queryID: queryID)
                callbacks.onEndPage?(queryID, state, first, last, count)
            },
            onFailure: { [weak self] event in
                self?.finish(queryID: event.queryId)
                callbacks.onFailure?(event)
            }
        )
        guard manager.requestTimestampLookup(
            stream,
            plan: plan,
            requestCallbacks: wrappedCallbacks
        ) else {
            failStart(plan: plan, callbacks: callbacks, streamKind: streamKind)
            return
        }
    }

    private func failStart(
        plan: ChatSearchTimestampMAMRequestPlan,
        callbacks: MessageArchiveManager.RequestCallbacks,
        streamKind: MessageArchiveEndPageEvent.StreamKind
    ) {
        stateLock.lock()
        let wasActive = activeQueryIDs.remove(plan.queryId) != nil
        managersByQueryID.removeValue(forKey: plan.queryId)
        let schedulerCompletion = schedulerCompletionsByQueryID.removeValue(
            forKey: plan.queryId
        )
        stateLock.unlock()
        schedulerCompletion?()
        guard wasActive else { return }
        callbacks.onFailure?(
            MessageArchiveRequestFailureEvent(
                owner: plan.scope.owner,
                queryId: plan.queryId,
                streamKind: streamKind,
                reason: .requestStartFailed,
                errorDescription: nil,
                pendingQueryCount: 1
            )
        )
    }

    private func finish(queryID: String) {
        stateLock.lock()
        activeQueryIDs.remove(queryID)
        managersByQueryID.removeValue(forKey: queryID)
        let schedulerCompletion = schedulerCompletionsByQueryID.removeValue(
            forKey: queryID
        )
        stateLock.unlock()
        schedulerCompletion?()
    }
}
