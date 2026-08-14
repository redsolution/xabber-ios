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
import XMPPFramework
import RealmSwift
import RxSwift
import RxRealm


extension MessageManager {

    private func routeCanonicalGroupMessage(
        _ message: XMPPMessage
    ) -> Account.CanonicalGroupMessageRouting {
        if let account = AccountManager.shared.find(for: owner) {
            return account.routeCanonicalGroupMessage(message)
        }

        // A detached message manager has no repository owner. It may validate
        // and classify canonical traffic, but must never recreate legacy group
        // storage as a fallback.
        do {
            guard let event = try GroupStanzaRouter.route(message) else {
                return .notGroup
            }
            switch event {
            case .message:
                return .validatedMessage
            case .invite, .reducer, .iq:
                return .consumed
            }
        } catch {
            return .consumed
        }
    }

    @discardableResult
    internal func performMessageQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: self.queueSpecificKey) == self.queueSpecificValue {
            return block()
        }
        return self.queue.sync(execute: block)
    }

    internal func publishQueuedMessagesSnapshot() {
        self.messagesQueue.accept(self.queuedMessages)
    }

    private func adjustPendingMessageCount(
        _ storage: inout [String: Int],
        for queryId: String?,
        delta: Int
    ) {
        guard let queryId, queryId.isNotEmpty else {
            return
        }

        let nextValue = (storage[queryId] ?? 0) + delta
        if nextValue > 0 {
            storage[queryId] = nextValue
        } else {
            storage.removeValue(forKey: queryId)
        }
    }

    private func adjustQueuedMessageCounts(for items: some Sequence<MessageQueueItem>, delta: Int) {
        items.forEach { item in
            self.adjustPendingMessageCount(&self.queuedMessageCountsByQueryId, for: item.queryId, delta: delta)
        }
    }

    private func adjustInFlightMessageCounts(for items: some Sequence<MessageQueueItem>, delta: Int) {
        items.forEach { item in
            self.adjustPendingMessageCount(&self.inFlightMessageCountsByQueryId, for: item.queryId, delta: delta)
        }
    }

    private enum ArchivePersistenceOutcome: Equatable {
        case savedNew
        case updatedExisting
        case skipped
        case failed
    }

    private struct ArchivePersistenceOutcomeItem {
        let queryIds: [String]
        let owner: String
        let opponent: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let archivedId: String
        let isDeleted: Bool
        let outcome: ArchivePersistenceOutcome
    }

    private func updateArchivePersistenceSummary(
        for queryId: String?,
        _ update: (inout ArchivePersistenceSummary) -> Void
    ) {
        guard let queryId,
              queryId.isNotEmpty else {
            return
        }

        var summary = self.archivePersistenceSummariesByQueryId[queryId] ?? ArchivePersistenceSummary()
        update(&summary)
        self.archivePersistenceSummariesByQueryId[queryId] = summary
    }

    private func queryIds(from message: MessageStorageItem) -> [String] {
        message.queryIds?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isNotEmpty } ?? []
    }

    private func recordArchivePersistenceOutcomes(_ outcomes: [ArchivePersistenceOutcomeItem]) {
        self.performMessageQueueSync {
            outcomes.forEach { item in
                item.queryIds.forEach { queryId in
                    self.updateArchivePersistenceSummary(for: queryId) { summary in
                        switch item.outcome {
                        case .savedNew:
                            summary.savedNew += 1
                        case .updatedExisting:
                            summary.updatedExisting += 1
                        case .skipped:
                            summary.skipped += 1
                        case .failed:
                            summary.failed += 1
                        }

                        if item.outcome != .skipped,
                           item.outcome != .failed,
                           !item.isDeleted {
                            summary.recordVisibleRow(
                                owner: item.owner,
                                jid: item.opponent,
                                conversationType: item.conversationType
                            )
                        }
                        if item.outcome == .savedNew || item.outcome == .updatedExisting {
                            summary.recordPersistedArchiveId(
                                item.archivedId,
                                owner: item.owner,
                                jid: item.opponent,
                                conversationType: item.conversationType
                            )
                        }
                    }
                }
            }
        }
    }

    private func archivePersistenceSummarySnapshot(forQueryId queryId: String) -> ArchivePersistenceSummary {
        self.archivePersistenceSummariesByQueryId[queryId] ?? ArchivePersistenceSummary()
    }

    internal func hasPendingMessages(forQueryId queryId: String) -> Bool {
        self.performMessageQueueSync {
            let hasBufferedRows =
                self.queuedMessages.contains { $0.queryId == queryId } ||
                (self.inFlightMessageCountsByQueryId[queryId] ?? 0) > 0
            self.archivePersistenceSchedulingLock.lock()
            let hasSealedPersistence =
                self.sealedArchivePersistenceRequestsByQueryId[queryId] != nil
            self.archivePersistenceSchedulingLock.unlock()
            return hasBufferedRows || hasSealedPersistence
        }
    }

    internal func shouldPersistArchiveQueryId(_ queryId: String?) -> Bool {
        if let archiveQueryIdPersistenceResolver {
            return archiveQueryIdPersistenceResolver(queryId)
        }

        return AccountManager.shared
            .find(for: owner)?
            .mam
            .shouldPersistArchiveQueryId(queryId) ?? false
    }

    internal func clearArchivePersistenceSummary(forQueryId queryId: String) {
        self.performMessageQueueSync {
            self.archivePersistenceSummariesByQueryId.removeValue(forKey: queryId)
        }
    }

    internal func clearArchivePersistenceSummaryWithoutWaiting(forQueryId queryId: String) {
        self.queue.async { [weak self] in
            self?.archivePersistenceSummariesByQueryId.removeValue(forKey: queryId)
        }
    }

    internal func beginArchiveQueryBatch(
        queryId: String,
        priority: ArchivePersistencePriority = .background
    ) {
        guard queryId.isNotEmpty else {
            return
        }
        self.performMessageQueueSync {
            let inserted = self.archiveQueryBatchIds.insert(queryId).inserted
            self.archivePersistenceSchedulingLock.lock()
            let currentPriority = self.archivePersistencePriorityByQueryId[queryId] ?? .background
            self.archivePersistencePriorityByQueryId[queryId] = max(currentPriority, priority)
            if inserted {
                self.completedArchiveQueryBatchSummariesByQueryId.removeValue(forKey: queryId)
                self.completedArchiveQueryBatchSummaryOrder.removeAll { $0 == queryId }
            }
            self.archivePersistenceSchedulingLock.unlock()
            ChatArchiveDebugTrace.log("messageArchiveBatchBegin", [
                ("activeBatchCount", self.archiveQueryBatchIds.count),
                ("priority", priority.rawValue)
            ])
        }
    }

    internal func promoteArchiveQueryBatch(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }
        self.archivePersistenceSchedulingLock.lock()
        let hasRegisteredBatch =
            self.archivePersistencePriorityByQueryId[queryId] != nil ||
            self.sealedArchivePersistenceRequestsByQueryId[queryId] != nil
        if hasRegisteredBatch {
            self.archivePersistencePriorityByQueryId[queryId] = .interactive
            self.sealedArchivePersistenceRequestsByQueryId[queryId]?.priority = .interactive
        }
        let activeRequestCount = self.sealedArchivePersistenceRequestsByQueryId.count
        self.archivePersistenceSchedulingLock.unlock()
        ChatArchiveDebugTrace.log("messageArchiveBatchPromote", [
            ("priority", ArchivePersistencePriority.interactive.rawValue),
            ("promoted", hasRegisteredBatch),
            ("activeRequestCount", activeRequestCount)
        ])
    }

    internal func isArchiveQueryBatchActive(queryId: String) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }
        return self.performMessageQueueSync {
            self.archiveQueryBatchIds.contains(queryId)
        }
    }

    /// Persists the matching query in one serialized queue operation. The
    /// underlying Realm writes remain bounded by `messagePersistenceChunkSize`
    /// (capped at 100) and unrelated/live rows remain eligible for normal drain.
    @discardableResult
    internal func finishArchiveQueryBatchSummary(queryId: String) -> ArchivePersistenceSummary {
        guard queryId.isNotEmpty else {
            return ArchivePersistenceSummary()
        }
        return self.performMessageQueueSync {
            self.archivePersistenceSchedulingLock.lock()
            let completedSummary = self.completedArchiveQueryBatchSummariesByQueryId[queryId]
            self.archivePersistenceSchedulingLock.unlock()
            if let completedSummary {
                return completedSummary
            }

            let summary = self.storeMessagesNowSummary(forQueryId: queryId)
            self.archiveQueryBatchIds.remove(queryId)
            let completions = self.completeArchivePersistenceRequest(
                queryId: queryId,
                summary: summary
            )
            ChatArchiveDebugTrace.log("messageArchiveBatchFinish", [
                ("persistedRows", summary.persistedRows),
                ("processedRows", summary.processedRows),
                ("activeBatchCount", self.archiveQueryBatchIds.count)
            ])
            self.scheduleQueuedMessagesDrainOnQueue()
            completions.forEach { $0(summary) }
            return summary
        }
    }

    internal func finishArchiveQueryBatchAsync(
        queryId: String,
        priority: ArchivePersistencePriority = .background,
        expectedReceivedCount: Int? = nil,
        completion: ((ArchivePersistenceSummary) -> Void)? = nil
    ) {
        self.sealArchiveQueryBatch(
            queryId: queryId,
            priority: priority,
            expectedReceivedCount: expectedReceivedCount,
            completion: completion
        )
    }

    /// Releases the transport-ingress barrier after a real terminal cleanup.
    ///
    /// A raw MAM `<fin>` can reach the coordinator before all result envelopes
    /// enter MessageManager, so the normal persistence path must wait for the
    /// transport-derived expected count. Once the request itself has failed or
    /// is being explicitly finalized, no missing envelope may keep an
    /// interactive batch parked forever. Already delivered rows are still
    /// persisted and its existing completion observers receive one terminal.
    internal func releaseArchiveQueryBatchIngressExpectation(
        queryId: String
    ) {
        guard queryId.isNotEmpty else {
            return
        }
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            var didReleaseExpectation = false
            var shouldSchedulePump = false
            self.archivePersistenceSchedulingLock.lock()
            if let request =
                    self.sealedArchivePersistenceRequestsByQueryId[queryId] {
                didReleaseExpectation = request.expectedReceivedCount != nil
                request.expectedReceivedCount = nil
                request.isAwaitingIngress = false
                if !self.isArchivePersistencePumpScheduled {
                    self.isArchivePersistencePumpScheduled = true
                    shouldSchedulePump = true
                }
            }
            self.archivePersistenceSchedulingLock.unlock()

            ChatArchiveDebugTrace.log(
                "messageArchiveBatchIngressExpectationReleased",
                [
                    ("released", didReleaseExpectation),
                    ("scheduled", shouldSchedulePump)
                ]
            )
            if shouldSchedulePump {
                self.queue.async { [weak self] in
                    self?.runArchivePersistencePumpTurn()
                }
            }
        }
    }

    internal func sealArchiveQueryBatch(
        queryId: String,
        priority: ArchivePersistencePriority? = nil,
        expectedReceivedCount: Int? = nil,
        completion: ((ArchivePersistenceSummary) -> Void)? = nil
    ) {
        guard queryId.isNotEmpty else {
            completion?(ArchivePersistenceSummary())
            return
        }

        var completedSummary: ArchivePersistenceSummary?
        var shouldSchedulePump = false
        var didJoin = false
        var effectivePriority = priority ?? .background
        var activeRequestCount = 0
        let traceContext = ChatArchivePerformanceTraceRegistry.shared.context(
            owner: self.owner,
            queryID: queryId
        )
        self.archivePersistenceSchedulingLock.lock()
        if let summary = self.completedArchiveQueryBatchSummariesByQueryId[queryId] {
            completedSummary = summary
        } else {
            let registeredPriority = self.archivePersistencePriorityByQueryId[queryId] ?? .background
            effectivePriority = max(registeredPriority, priority ?? registeredPriority)
            self.archivePersistencePriorityByQueryId[queryId] = effectivePriority
            if let request = self.sealedArchivePersistenceRequestsByQueryId[queryId] {
                didJoin = true
                request.priority = max(request.priority, effectivePriority)
                if let expectedReceivedCount {
                    request.expectedReceivedCount = max(
                        request.expectedReceivedCount ?? 0,
                        max(0, expectedReceivedCount)
                    )
                }
                if let completion {
                    request.completions.append(completion)
                }
                if request.traceContext == nil {
                    request.traceContext = traceContext
                }
            } else {
                self.archivePersistenceRequestSequence &+= 1
                self.sealedArchivePersistenceRequestsByQueryId[queryId] = ArchivePersistenceRequest(
                    queryId: queryId,
                    sequence: self.archivePersistenceRequestSequence,
                    priority: effectivePriority,
                    expectedReceivedCount: expectedReceivedCount.map { max(0, $0) },
                    traceContext: traceContext,
                    completion: completion
                )
            }
            activeRequestCount = self.sealedArchivePersistenceRequestsByQueryId.count
            if !self.isArchivePersistencePumpScheduled {
                self.isArchivePersistencePumpScheduled = true
                shouldSchedulePump = true
            }
        }
        self.archivePersistenceSchedulingLock.unlock()

        _ = ChatArchivePerformanceTraceRegistry.shared.sealExpectedIngress(
            owner: self.owner,
            queryID: queryId,
            context: traceContext,
            expectedCount: expectedReceivedCount
        )

        ChatArchiveDebugTrace.log("messageArchiveBatchSeal", [
            ("priority", effectivePriority.rawValue),
            ("joined", didJoin),
            ("expectedReceivedCount", expectedReceivedCount),
            ("activeRequestCount", activeRequestCount)
        ])
        if let completedSummary {
            self.queue.async {
                completion?(completedSummary)
            }
            return
        }
        if shouldSchedulePump {
            self.queue.async { [weak self] in
                self?.runArchivePersistencePumpTurn()
            }
        }
    }

    private func completeArchivePersistenceRequest(
        queryId: String,
        summary: ArchivePersistenceSummary
    ) -> [(ArchivePersistenceSummary) -> Void] {
        self.archivePersistenceSchedulingLock.lock()
        defer {
            self.archivePersistenceSchedulingLock.unlock()
        }
        return self.completeArchivePersistenceRequestWhileLocked(
            queryId: queryId,
            summary: summary
        )
    }

    private func completeArchivePersistenceRequestIfExpectedIngressIsAccounted(
        queryId: String,
        summary: ArchivePersistenceSummary
    ) -> (
        expectedReceivedCount: Int?,
        completions: [(ArchivePersistenceSummary) -> Void]?
    ) {
        self.archivePersistenceSchedulingLock.lock()
        defer {
            self.archivePersistenceSchedulingLock.unlock()
        }
        guard let request =
                self.sealedArchivePersistenceRequestsByQueryId[queryId] else {
            return (nil, nil)
        }
        let expectedReceivedCount = request.expectedReceivedCount
        let hasAccountedExpectedIngress =
            expectedReceivedCount.map {
                summary.received >= $0
            } ?? true
        guard hasAccountedExpectedIngress else {
            return (expectedReceivedCount, nil)
        }
        return (
            expectedReceivedCount,
            self.completeArchivePersistenceRequestWhileLocked(
                queryId: queryId,
                summary: summary
            )
        )
    }

    private func completeArchivePersistenceRequestWhileLocked(
        queryId: String,
        summary: ArchivePersistenceSummary
    ) -> [(ArchivePersistenceSummary) -> Void] {
        let request = self.sealedArchivePersistenceRequestsByQueryId.removeValue(forKey: queryId)
        if let traceContext = request?.traceContext {
            _ = ChatArchivePerformanceTraceRegistry.shared.persistenceTerminal(
                owner: self.owner,
                queryID: queryId,
                context: traceContext,
                terminal: summary.failed > 0 ? .failed : .committed,
                persistedCount: summary.persistedRows,
                failedCount: summary.failed
            )
        }
        self.archivePersistencePriorityByQueryId.removeValue(forKey: queryId)
        self.completedArchiveQueryBatchSummariesByQueryId[queryId] = summary
        self.completedArchiveQueryBatchSummaryOrder.removeAll { $0 == queryId }
        self.completedArchiveQueryBatchSummaryOrder.append(queryId)
        while self.completedArchiveQueryBatchSummaryOrder.count > self.completedArchiveQueryBatchSummaryCapacity {
            let evictedQueryId = self.completedArchiveQueryBatchSummaryOrder.removeFirst()
            self.completedArchiveQueryBatchSummariesByQueryId.removeValue(forKey: evictedQueryId)
        }
        let completions = request?.completions ?? []
        return completions
    }

    private func nextArchivePersistenceRequest() -> (
        queryId: String,
        priority: ArchivePersistencePriority,
        expectedReceivedCount: Int?,
        isFirstTurn: Bool
    )? {
        self.archivePersistenceSchedulingLock.lock()
        defer { self.archivePersistenceSchedulingLock.unlock() }
        guard let request = self.sealedArchivePersistenceRequestsByQueryId.values
            .filter({ !$0.isAwaitingIngress })
            .min(by: { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.sequence < rhs.sequence
        }) else {
            // Clear the scheduling flag while holding the same lock used by
            // `sealArchiveQueryBatch`. A seal racing this empty turn will then
            // either be observed here or schedule a replacement pump.
            self.isArchivePersistencePumpScheduled = false
            return nil
        }
        let isFirstTurn = !request.didStartPersistence
        request.didStartPersistence = true
        return (
            request.queryId,
            request.priority,
            request.expectedReceivedCount,
            isFirstTurn
        )
    }

    private func scheduleNextArchivePersistencePumpTurn() {
        self.archivePersistenceSchedulingLock.lock()
        let hasRunnableRequests =
            self.sealedArchivePersistenceRequestsByQueryId.values.contains {
                !$0.isAwaitingIngress
            }
        if !hasRunnableRequests {
            self.isArchivePersistencePumpScheduled = false
        }
        self.archivePersistenceSchedulingLock.unlock()
        if hasRunnableRequests {
            self.queue.async { [weak self] in
                self?.runArchivePersistencePumpTurn()
            }
        }
    }

    private func parkArchivePersistenceRequestAwaitingIngress(queryId: String) {
        self.archivePersistenceSchedulingLock.lock()
        self.sealedArchivePersistenceRequestsByQueryId[queryId]?
            .isAwaitingIngress = true
        self.archivePersistenceSchedulingLock.unlock()
    }

    private func wakeArchivePersistenceRequestAfterIngress(queryId: String) {
        var shouldSchedulePump = false
        self.archivePersistenceSchedulingLock.lock()
        if let request =
                self.sealedArchivePersistenceRequestsByQueryId[queryId],
           request.isAwaitingIngress {
            let receivedCount =
                self.archivePersistenceSummariesByQueryId[queryId]?.received ?? 0
            let hasReachedExpectedIngress =
                request.expectedReceivedCount.map {
                    receivedCount >= $0
                } ?? true
            guard hasReachedExpectedIngress else {
                self.archivePersistenceSchedulingLock.unlock()
                return
            }
            request.isAwaitingIngress = false
            if !self.isArchivePersistencePumpScheduled {
                self.isArchivePersistencePumpScheduled = true
                shouldSchedulePump = true
            }
        }
        self.archivePersistenceSchedulingLock.unlock()

        guard shouldSchedulePump else {
            return
        }
        self.queue.async { [weak self] in
            self?.runArchivePersistencePumpTurn()
        }
    }

    private func hasInteractiveArchivePersistenceRequest() -> Bool {
        self.archivePersistenceSchedulingLock.lock()
        let result = self.sealedArchivePersistenceRequestsByQueryId.values.contains {
            $0.priority == .interactive && !$0.isAwaitingIngress
        }
        self.archivePersistenceSchedulingLock.unlock()
        return result
    }

    /// Persists only the queued archive row targeted by a retract/rewrite
    /// notification. Work is asynchronous so the XMPP receiver never performs
    /// an unscoped synchronous drain. A sealed interactive page owns the queue
    /// until all of its bounded chunks reach persistence terminal.
    internal func persistQueuedMessageForMutation(
        archivedId: String,
        completion: @escaping () -> Void
    ) {
        guard archivedId.isNotEmpty else {
            completion()
            return
        }
        let request = QueuedMutationPersistenceRequest(
            archivedId: archivedId,
            completion: completion
        )
        self.queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.runQueuedMutationPersistenceRequest(request)
        }
    }

    private func runQueuedMutationPersistenceRequest(
        _ request: QueuedMutationPersistenceRequest
    ) {
        guard !self.hasInteractiveArchivePersistenceRequest() else {
            self.deferredQueuedMutationPersistenceRequests.append(request)
            ChatArchiveDebugTrace.log("messageMutationPersistenceDeferred", [
                ("interactivePending", true),
                ("deferredCount", self.deferredQueuedMutationPersistenceRequests.count)
            ])
            return
        }

        let drainLimit = min(max(1, self.messagePersistenceChunkSize), 100)
        let matchingMessages = self.queuedMessages
            .filter {
                getStanzaId($0.message, owner: self.owner) == request.archivedId
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return (lhs.messageId ?? "") < (rhs.messageId ?? "")
            }
        let results = Set(matchingMessages.prefix(drainLimit))
        if results.isNotEmpty {
            self.adjustQueuedMessageCounts(for: results, delta: -1)
            self.queuedMessages.subtract(results)
            self.publishQueuedMessagesSnapshot()
            self.adjustInFlightMessageCounts(for: results, delta: 1)
            self.processQueue(results, callback: { values in
                if let batch = values {
                    _ = self.save(batch, resetChunkMetrics: false)
                }
            })
            self.adjustInFlightMessageCounts(for: results, delta: -1)
            AccountManager.shared.find(for: self.owner)?
                .chatMarkers
                .deleteEphemeralMessages()
        }

        let hasRemainingTarget = self.queuedMessages.contains {
            getStanzaId($0.message, owner: self.owner) == request.archivedId
        }
        ChatArchiveDebugTrace.log("messageMutationPersistenceTurn", [
            ("drainCount", results.count),
            ("drainLimit", drainLimit),
            ("hasRemainingTarget", hasRemainingTarget)
        ])
        if hasRemainingTarget {
            self.deferredQueuedMutationPersistenceRequests.insert(request, at: 0)
        } else {
            request.completion()
        }

        if !self.scheduleNextQueuedMutationPersistenceIfNeeded() {
            self.scheduleQueuedMessagesDrainOnQueue()
        }
    }

    @discardableResult
    private func scheduleNextQueuedMutationPersistenceIfNeeded() -> Bool {
        guard !self.hasInteractiveArchivePersistenceRequest(),
              self.deferredQueuedMutationPersistenceRequests.isNotEmpty else {
            return false
        }
        let request = self.deferredQueuedMutationPersistenceRequests.removeFirst()
        self.queue.async { [weak self] in
            self?.runQueuedMutationPersistenceRequest(request)
        }
        return true
    }

    private func runArchivePersistencePumpTurn() {
        guard let request = self.nextArchivePersistenceRequest() else {
            return
        }

        if request.isFirstTurn {
            self.messagePersistenceChunkSizes.removeAll(keepingCapacity: true)
        }
        let drainLimit = min(max(1, self.messagePersistenceChunkSize), 100)
        let eligibleMessages = self.queuedMessages
            .filter { $0.queryId == request.queryId }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return (lhs.messageId ?? "") < (rhs.messageId ?? "")
            }
        let results = Set(eligibleMessages.prefix(drainLimit))
        if results.isNotEmpty {
            self.adjustQueuedMessageCounts(for: results, delta: -1)
            self.queuedMessages.subtract(results)
            self.publishQueuedMessagesSnapshot()
            self.adjustInFlightMessageCounts(for: results, delta: 1)
        }

        self.archivePersistenceSchedulingLock.lock()
        let activeRequestCount = self.sealedArchivePersistenceRequestsByQueryId.count
        self.archivePersistenceSchedulingLock.unlock()
        ChatArchiveDebugTrace.log("messageArchivePersistenceTurn", [
            ("priority", request.priority.rawValue),
            ("drainCount", results.count),
            ("drainLimit", drainLimit),
            ("queuedRemaining", self.queuedMessageCountsByQueryId[request.queryId] ?? 0),
            ("expectedReceivedCount", request.expectedReceivedCount),
            ("activeRequestCount", activeRequestCount)
        ])

        if results.isNotEmpty {
            self.processQueue(results, callback: { values in
                if let batch = values {
                    _ = self.save(batch, resetChunkMetrics: false)
                }
            })
            self.adjustInFlightMessageCounts(for: results, delta: -1)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()
        }

        let actualQueuedCount = self.queuedMessages.lazy.filter {
            $0.queryId == request.queryId
        }.count
        let cachedQueuedCount =
            self.queuedMessageCountsByQueryId[request.queryId] ?? 0
        let cachedInFlightCount =
            self.inFlightMessageCountsByQueryId[request.queryId] ?? 0
        if actualQueuedCount > 0 {
            self.queuedMessageCountsByQueryId[request.queryId] =
                actualQueuedCount
        } else {
            self.queuedMessageCountsByQueryId.removeValue(
                forKey: request.queryId
            )
        }
        // This method, processQueue, and save all execute synchronously on the
        // serialized MessageManager queue. No matching row can remain
        // genuinely in flight after save returns.
        self.inFlightMessageCountsByQueryId.removeValue(
            forKey: request.queryId
        )

        let summary =
            self.archivePersistenceSummarySnapshot(forQueryId: request.queryId)
        let terminalDecision = actualQueuedCount == 0
            ? self.completeArchivePersistenceRequestIfExpectedIngressIsAccounted(
                queryId: request.queryId,
                summary: summary
            )
            : (
                expectedReceivedCount: request.expectedReceivedCount,
                completions: nil
            )
        let hasAccountedExpectedIngress =
            terminalDecision.completions != nil
        ChatArchiveDebugTrace.log("messageArchivePersistencePostSave", [
            ("priority", request.priority.rawValue),
            ("actualQueuedCount", actualQueuedCount),
            ("cachedQueuedCount", cachedQueuedCount),
            ("cachedInFlightCount", cachedInFlightCount),
            ("receivedCount", summary.received),
            (
                "expectedReceivedCount",
                terminalDecision.expectedReceivedCount
            ),
            ("accountedExpectedIngress", hasAccountedExpectedIngress)
        ])

        if let completions = terminalDecision.completions {
            self.archiveQueryBatchIds.remove(request.queryId)
            ChatArchiveDebugTrace.log("messageArchivePersistenceTerminal", [
                ("priority", request.priority.rawValue),
                ("persistedRows", summary.persistedRows),
                ("processedRows", summary.processedRows),
                ("failedRows", summary.failed),
                ("observerCount", completions.count)
            ])
            completions.forEach { $0(summary) }
        } else if actualQueuedCount == 0 {
            self.parkArchivePersistenceRequestAwaitingIngress(
                queryId: request.queryId
            )
            ChatArchiveDebugTrace.log(
                "messageArchivePersistenceAwaitingIngress",
                [
                    ("priority", request.priority.rawValue),
                    ("receivedCount", summary.received),
                    (
                        "expectedReceivedCount",
                        terminalDecision.expectedReceivedCount
                    )
                ]
            )
        }

        if self.hasInteractiveArchivePersistenceRequest() {
            self.scheduleNextArchivePersistencePumpTurn()
        } else {
            if !self.scheduleNextQueuedMutationPersistenceIfNeeded() {
                self.scheduleQueuedMessagesDrainOnQueue()
            }
            self.scheduleNextArchivePersistencePumpTurn()
        }
    }

    internal func scheduleQueuedMessagesDrainIfNeeded() {
        self.performMessageQueueSync {
            self.scheduleQueuedMessagesDrainOnQueue()
        }
    }

    internal func scheduleQueuedMessagesDrainWithoutWaiting() {
        self.queue.async { [weak self] in
            self?.scheduleQueuedMessagesDrainOnQueue()
        }
    }

    private func isEligibleForOrdinaryDrain(_ item: MessageQueueItem) -> Bool {
        guard let queryId = item.queryId,
              queryId.isNotEmpty else {
            return true
        }
        return !self.archiveQueryBatchIds.contains(queryId)
    }

    private var hasOrdinaryDrainEligibleMessages: Bool {
        self.queuedMessages.contains(where: self.isEligibleForOrdinaryDrain)
    }

    private func scheduleQueuedMessagesDrainOnQueue() {
        guard self.isReceiverActive,
              !self.isQueuedMessagesDrainScheduled,
              !self.hasInteractiveArchivePersistenceRequest(),
              self.hasOrdinaryDrainEligibleMessages else {
            return
        }
        self.isQueuedMessagesDrainScheduled = true
        self.queue.async { [weak self] in
            self?.drainQueuedMessagesAndPersist()
        }
    }

    internal func drainQueuedMessagesAndPersist() {
        self.performMessageQueueSync {
            self.ordinaryDrainWillExecuteHook?()
            guard self.isReceiverActive else {
                self.isQueuedMessagesDrainScheduled = false
                return
            }
            guard !self.hasInteractiveArchivePersistenceRequest() else {
                self.isQueuedMessagesDrainScheduled = false
                ChatArchiveDebugTrace.log("messageOrdinaryDrainYield", [
                    ("interactivePending", true),
                    ("queuedCount", self.queuedMessages.count)
                ])
                return
            }

            let drainLimit = min(max(1, self.messagePersistenceChunkSize), 100)
            let results = self.drainQueuedMessages(maxCount: drainLimit)
            self.adjustInFlightMessageCounts(for: results, delta: 1)
            self.isQueuedMessagesDrainScheduled = false
            ChatArchiveDebugTrace.log("messageOrdinaryDrainStart", [
                ("drainCount", results.count),
                ("drainLimit", drainLimit),
                ("queuedRemaining", self.queuedMessages.count)
            ])
            self.processQueue(results, callback: { values in
                if let batch = values {
                    _ = self.save(batch)
                }
            })
            self.adjustInFlightMessageCounts(for: results, delta: -1)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()

            if self.isReceiverActive,
               self.hasOrdinaryDrainEligibleMessages,
               !self.hasInteractiveArchivePersistenceRequest() {
                self.scheduleQueuedMessagesDrainIfNeeded()
            }
        }
    }

    internal func drainQueuedMessages(maxCount: Int) -> Set<MessageQueueItem> {
        self.performMessageQueueSync {
            let boundedCount = min(max(1, maxCount), 100)
            let eligibleMessages = self.queuedMessages
                .filter(self.isEligibleForOrdinaryDrain)
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date {
                        return lhs.date < rhs.date
                    }
                    return (lhs.messageId ?? "") < (rhs.messageId ?? "")
                }
            let snapshot = Set(eligibleMessages.prefix(boundedCount))
            self.adjustQueuedMessageCounts(for: snapshot, delta: -1)
            self.queuedMessages.subtract(snapshot)
            self.publishQueuedMessagesSnapshot()
            return snapshot
        }
    }
    
    class MessageQueueItem: Hashable {
        
        static func == (lhs: MessageQueueItem, rhs: MessageQueueItem) -> Bool {
            return lhs.message.xmlString == rhs.message.xmlString &&
                lhs.date == rhs.date &&
                lhs.queryId == rhs.queryId
        }
        
        var isRead: Bool = true
        var date: Date = Date()
        var message: XMPPMessage
        var state: MessageStorageItem.MessageSendingState = MessageStorageItem.MessageSendingState.none
        var originalFrom: String = ""
        var archivedFrom: String? = nil
        var originalOutgoing: Bool = false
        var forceUnreadState: Bool? = nil
        var clientSyncMessage: Bool = false
        var queryId: String? = nil
        var groupchatUserCard: DDXMLElement? = nil
        var readDate: Date? = nil
        var messageId: String? = nil
        var shouldPersistArchiveQueryId: Bool = false
        var countsAsRuntimeUnread: Bool = false
        
        init(_ message: XMPPMessage, messageId: String?, archivedFrom: String?, isRead: Bool, date: Date, state: MessageStorageItem.MessageSendingState, forceUnreadState: Bool? = nil, clientSyncMessage: Bool = false, queryId: String?, shouldPersistArchiveQueryId: Bool = false, countsAsRuntimeUnread: Bool = false, groupchatUserCard: DDXMLElement? = nil, readDate: Date? = nil) {
            self.message = message
            self.archivedFrom = archivedFrom
            self.isRead = isRead
            self.date = date
            self.state = state
            self.forceUnreadState = forceUnreadState
            self.clientSyncMessage = clientSyncMessage
            self.groupchatUserCard = groupchatUserCard
            self.queryId = queryId
            self.shouldPersistArchiveQueryId = shouldPersistArchiveQueryId
            self.countsAsRuntimeUnread = countsAsRuntimeUnread
            self.readDate = readDate
            self.messageId = messageId
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(message.xmlString)
            hasher.combine(date)
            hasher.combine(queryId)
        }
    }

    struct ReadStateReconciliationRequest: Hashable {
        let owner: String
        let opponent: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let itemDate: Date
        let readDate: Date?
        let afterburnInterval: Double
    }

    struct ProcessedQueueBatch {
        let messages: [MessageStorageItem]
        let readStateRequests: [ReadStateReconciliationRequest]
        let archiveQueryIdsByPrimary: [String: [String]]

        init(
            messages: [MessageStorageItem],
            readStateRequests: [ReadStateReconciliationRequest],
            archiveQueryIdsByPrimary: [String: [String]] = [:]
        ) {
            self.messages = messages
            self.readStateRequests = readStateRequests
            self.archiveQueryIdsByPrimary = archiveQueryIdsByPrimary
        }

        func chunks(maxSize: Int) -> [ProcessedQueueBatch] {
            let chunkSize = max(1, maxSize)
            guard messages.count > chunkSize else {
                return [self]
            }

            return stride(from: 0, to: messages.count, by: chunkSize).map { startIndex in
                let endIndex = min(startIndex + chunkSize, messages.count)
                let messageChunk = Array(messages[startIndex..<endIndex])
                let chunkPrimaries = Set(messageChunk.map(\.primary))
                let chunkArchiveQueryIds = archiveQueryIdsByPrimary.filter { primary, _ in
                    chunkPrimaries.contains(primary)
                }
                let readStateChunk: [ReadStateReconciliationRequest]
                if readStateRequests.count == messages.count {
                    readStateChunk = Array(readStateRequests[startIndex..<endIndex])
                } else {
                    readStateChunk = startIndex == 0 ? readStateRequests : []
                }
                return ProcessedQueueBatch(
                    messages: messageChunk,
                    readStateRequests: readStateChunk,
                    archiveQueryIdsByPrimary: chunkArchiveQueryIds
                )
            }
        }
    }
    
//    public func resetQueue() {
//        clearQueue()
//        subscribe(true)
//    }
    
    public func receiveClientSyncRaw(_ message: XMPPMessage, groupchatUserCard: DDXMLElement?, isRead: Bool, state: MessageStorageItem.MessageSendingState, date: Date, readDate: Date? = nil) -> MessageQueueItem? {
        return MessageQueueItem(
            message,
            messageId: getOriginId(message),
            archivedFrom: message.from?.bare,
            isRead: isRead,
            date: date,
            state: state,
            forceUnreadState: isRead,
            clientSyncMessage: true,
            queryId: getMAMQueryId(message),
            groupchatUserCard: groupchatUserCard,
            readDate: readDate
        )
    }
    
    public func receiveClientSync(_ message: XMPPMessage, isRead: Bool, state: MessageStorageItem.MessageSendingState, date: Date) {
        enqueue(MessageQueueItem(message,
                                 messageId: getOriginId(message),
                                 archivedFrom: message.from?.bare,
                                 isRead: isRead,
                                 date: date,
                                 state: state,
                                 forceUnreadState: isRead,
                                 clientSyncMessage: true,
                                 queryId: getMAMQueryId(message)))
        
    }
    
    public func receiveTemporary(_ message: XMPPMessage) -> MessageQueueItem? {
        if let date = getDelayedDate(message),
            let messageBare = getArchivedMessageContainer(message) {
             return MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: message.from?.bare,
                                     isRead: message.from?.bare == owner ? true : false,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? date,
                                     state: .deliver,
                                     clientSyncMessage: true,
                                     queryId: getMAMQueryId(message))
        }
        return nil
    }
    
    public func receiveArchived(_ message: XMPPMessage) {
        let queryId = getMAMQueryId(message)
        ChatArchiveDebugTrace.log("mamResultMessageReceived", [
            ("owner", self.owner),
            ("queryId", queryId ?? "-"),
            ("wrapperId", message.element(forName: "result")?.attributeStringValue(forName: "id") ?? "-"),
            ("from", message.from?.bare ?? "-"),
            ("hasArchivedContainer", getArchivedMessageContainer(message) != nil)
        ])
        let delayedDate = getDelayedDate(message)
        let archivedMessage = getArchivedMessageContainer(message)
        let canonicalGroupRouting = routeCanonicalGroupMessage(message)

        // Received/classified/queued accounting is one serialized ingress
        // operation. Concurrent OMEMO/plaintext callbacks cannot let the
        // persistence pump observe the expected count before the final row has
        // entered the query queue or been explicitly classified as skipped.
        self.performMessageQueueSync {
            defer {
                if let queryId,
                   queryId.isNotEmpty {
                    let receivedCount = self
                        .archivePersistenceSummariesByQueryId[queryId]?
                        .received ?? 0
                    _ = ChatArchivePerformanceTraceRegistry.shared.recordIngress(
                        owner: self.owner,
                        queryID: queryId,
                        receivedCount: receivedCount
                    )
                    self.wakeArchivePersistenceRequestAfterIngress(
                        queryId: queryId
                    )
                }
            }
            self.updateArchivePersistenceSummary(for: queryId) { summary in
                summary.received += 1
            }
            guard let delayedDate,
                  let archivedMessage else {
                self.updateArchivePersistenceSummary(for: queryId) { summary in
                    summary.skipped += 1
                }
                return
            }
            if canonicalGroupRouting == .consumed {
                self.updateArchivePersistenceSummary(for: queryId) { summary in
                    summary.skipped += 1
                }
                return
            }

            let shouldPersistArchiveQueryId =
                self.shouldPersistArchiveQueryId(queryId)
            let didQueue = enqueue(MessageQueueItem(
                archivedMessage,
                messageId: getOriginId(archivedMessage),
                archivedFrom: message.from?.bare,
                isRead: true,
                date: getDeliveryTime(
                    archivedMessage,
                    owner: owner
                ) ?? delayedDate,
                state: .deliver,
                queryId: queryId,
                shouldPersistArchiveQueryId:
                    shouldPersistArchiveQueryId
            ))
            if didQueue {
                self.updateArchivePersistenceSummary(for: queryId) { summary in
                    summary.queued += 1
                }
            }
        }
    }
    
    public func receiveCarbon(_ message: XMPPMessage) {
        guard routeCanonicalGroupMessage(message) != .consumed else {
            return
        }
        if let messageBare = getCarbonCopyMessageContainer(message) {
            enqueue(MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: messageBare.from?.bare,
                                     isRead: true,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message)))
//            do {
//                let conversationType = conversationTypeByMessage(message)
//                let realm = try WRealm.safe()
//                try realm.write {
//                    realm
//                        .objects(MessageStorageItem.self)
//                        .filter("owner == %@ AND opponent == %@ AND state_ < %@ AND date <= %@ AND conversationType_ == %@",
//                                owner,
//                                from,
//                                MessageStorageItem.MessageSendingState.read.rawValue,
//                                getDeliveryTime(message, owner: owner) ?? Date(),
//                                conversationType.rawValue)
//                        .forEach {
//                            $0.state = .read
//                            $0.isRead = true
//                            if $0.burnDate <= 1 {
//                                if $0.afterburnInterval > 0 {
//                                    $0.readDate = Date().timeIntervalSince1970
//                                    $0.burnDate = Date().timeIntervalSince1970 + $0.afterburnInterval
//                                }
//                            }
//                        }
//                }
//            } catch {
//                DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
//            }
        }
    }
    
    public func receiveCarbonForwarded(_ message: XMPPMessage) {
        guard routeCanonicalGroupMessage(message) != .consumed else {
            return
        }
        if let messageBare = getCarbonForwardedMessageContainer(message) {
            enqueue(MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: message.from?.bare,
                                     isRead: false,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? Date(),
                                     state: .sended,
                                     queryId: getMAMQueryId(message),
                                     countsAsRuntimeUnread: true))
        }
    }
    
    public func receiveRuntime(_ message: XMPPMessage) {
        if routeCanonicalGroupMessage(message) == .consumed {
            return
        }
        enqueue(MessageQueueItem(message,
                                 messageId: getOriginId(message),
                                 archivedFrom: message.from?.bare,
                                 isRead: false,
                                 date: getDeliveryTime(message, owner: owner) ?? Date(),
                                 state: .sended,
                                 queryId: getMAMQueryId(message),
                                 countsAsRuntimeUnread: true))
    }
    
    
    
    public func updateReadDate(for messageId: String, stanzaId: String, jid: String, date: Date) {
//        RunLoop.current.perform {
        self.prereadedMessages.append(PrereadedMessagesItem(messageId: messageId, stanzaId: stanzaId, date: date, jid: jid))
//        }
        
    }
    
    internal func clearQueue(_ item: MessageQueueItem) {
        self.performMessageQueueSync {
            if self.queuedMessages.remove(item) != nil {
                self.adjustQueuedMessageCounts(for: [item], delta: -1)
            }
            self.publishQueuedMessagesSnapshot()
        }
    }
    
    internal func clearQueue() {
        self.performMessageQueueSync {
            self.adjustQueuedMessageCounts(for: self.queuedMessages, delta: -1)
            self.queuedMessages.removeAll()
            self.publishQueuedMessagesSnapshot()
        }
    }
    
    internal func subscribeReceiver() {
        receiverBag = DisposeBag()
        self.performMessageQueueSync {
            self.isReceiverActive = true
        }
        self.scheduleQueuedMessagesDrainIfNeeded()
    }
    
    internal func unsubscribeReceiver() {
        receiverBag = DisposeBag()
        self.performMessageQueueSync {
            self.isReceiverActive = false
            self.isQueuedMessagesDrainScheduled = false
            self.archivePersistenceSchedulingLock.lock()
            let sealedQueryIds = Set(
                self.sealedArchivePersistenceRequestsByQueryId.keys
            )
            self.archivePersistenceSchedulingLock.unlock()
            let terminalQueryIds = self.archiveQueryBatchIds
                .union(sealedQueryIds)
                .sorted()
            var persistedRows = 0
            var terminalCallbacks: [(
                summary: ArchivePersistenceSummary,
                completions: [(ArchivePersistenceSummary) -> Void]
            )] = []
            terminalQueryIds.forEach { queryId in
                let summary = self.storeMessagesNowSummary(forQueryId: queryId)
                persistedRows += summary.persistedRows
                self.archiveQueryBatchIds.remove(queryId)
                terminalCallbacks.append((
                    summary,
                    self.completeArchivePersistenceRequest(
                        queryId: queryId,
                        summary: summary
                    )
                ))
            }
            self.archiveQueryBatchIds.removeAll()
            if terminalQueryIds.isNotEmpty {
                ChatArchiveDebugTrace.log("messageArchiveBatchLifecycleFlush", [
                    ("queryCount", terminalQueryIds.count),
                    ("persistedRows", persistedRows)
                ])
            }
            terminalCallbacks.forEach { terminal in
                terminal.completions.forEach { $0(terminal.summary) }
            }
        }
        clearQueue()
    }
    
    func processQueue(_ items: Set<MessageQueueItem>, callback: ((ProcessedQueueBatch?) -> Void)) {
        if items.isEmpty {
            return callback(nil)
        }
        let startedAt = Date()
        let queryIds = Set(items.compactMap { $0.queryId?.isNotEmpty == true ? $0.queryId : nil })
            .sorted()
            .joined(separator: ",")
        ChatArchiveDebugTrace.log("messageProcessQueueStart", [
            ("owner", self.owner),
            ("queryId", queryIds),
            ("count", items.count)
        ])
        var messageQueryIds: Set<String> = Set<String>()
        var out: Set<MessageStorageItem> = Set<MessageStorageItem>()
        var readStateRequests: [ReadStateReconciliationRequest] = []
        var archiveQueryIdsByPrimary: [String: [String]] = [:]
        let sortedItems = Array(items).sorted(by: {
            $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970
        })
        
        sortedItems.forEach { (item) in
            if isVoIPMessage(item.message) {
                return
            }
            if routeCanonicalGroupMessage(item.message) == .consumed {
                return
            }
            let systemMessageSource: GroupSystemMessageSource =
                item.queryId?.isNotEmpty == true ? .mam : .live
            let systemMetadata = parseSystemMessageMetadata(
                item.message,
                source: systemMessageSource
            )
            if systemMessageSource == .live {
                let mamOnlySystemType = parseSystemMessageMetadata(
                    item.message,
                    source: .mam
                )?["type"] as? String
                if mamOnlySystemType == GroupSystemEventType.create.rawValue {
                    return
                }
            }
            let instance: MessageStorageItem = MessageStorageItem()
            let from = item.message.from?.bare ?? item.archivedFrom ?? item.originalFrom
            guard let to = item.message.to?.bare else {
                    return
            }
            if let formElement = item.message.element(forName: "x", xmlns: "jabber:x:data"),
                formElement.attributeStringValue(forName: "type") == "submit" {
                return
            }
            let opponent = to != owner ? to : from
            
            var omemoError: Bool = !(item.message.element(forName: "omemo-result__system")?.attributeBoolValue(forName: "result") ?? false)
            var errorMetadata: [String: Any] = [:]
            var isEncryptedMessage: Bool = false
            if item.message.element(forName: "encrypted") != nil {
                isEncryptedMessage = true
                errorMetadata = SignatureManager.MessageError().errorMetadata
            }
            
            let afterburnInterval = item.message.element(forName: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeDoubleValue(forName: "timer") ?? 0
            
            var hasSignElement: Bool = false
            var envelopeContainer: String? = nil
//            print("RECEIVER", #function, item.message.prettyXMLString!)
            if let sign = item.message.element(forName: "time-signature", xmlns: SignatureManager.xmlns){
                omemoError = false
                hasSignElement = true
                envelopeContainer = sign.xmlString
                do {
                    errorMetadata = try SignatureManager.shared.checkSignature(
                        owner: self.owner,
                        for: from,
                        signature: sign,
                        messageDate: item.date
                    ).errorMetadata
                } catch {
                    errorMetadata = SignatureManager.MessageError().errorMetadata
                }
            }
            
            if let userId = groupchatUserElement(from: item.message)?
                .attributeStringValue(forName: "id") {
                do {
                    let realm = try WRealm.safe()
                    let membership = realm.object(
                        ofType: GroupSelfMembershipStorageItem.self,
                        forPrimaryKey: GroupStorageKey.groupPrimary(
                            owner: owner,
                            groupJID: opponent
                        )
                    )
                    item.originalOutgoing = membership?.memberID == userId
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            } else {
                item.originalOutgoing = from == owner
            }
            
//            if item.originalOutgoing || item.state == .read {
//                item.isRead = true
            let conversationType = conversationTypeByMessage(item.message)
            let readDate = item.isRead ? (item.readDate ?? prereadedMessages.first(where: { item.messageId == $0.messageId })?.date) : nil// ?? prereadedConversation.first(where: { $0.jid == opponent && $0.conversationType == conversationType })?.date) : nil
            if let readDate = readDate,
               item.date < readDate {
                item.isRead = true
            } else {
                item.isRead = item.state == .read
            }
            readStateRequests.append(
                ReadStateReconciliationRequest(
                    owner: self.owner,
                    opponent: opponent,
                    conversationType: conversationType,
                    itemDate: item.date,
                    readDate: readDate,
                    afterburnInterval: afterburnInterval
                )
            )
            if systemMetadata != nil {
                instance.configureSystemMessage(item.message,
                                                owner: owner,
                                                opponent: opponent,
                                                date: item.date,
                                                source: systemMessageSource)
                instance.state = .none
                instance.isRead = item.forceUnreadState ?? item.isRead
            } else {
                instance.configureIncomingMessage(item.message,
                                          owner: owner,
                                          opponent: opponent,
                                          outgoing: item.originalOutgoing,
                                          isRead: item.forceUnreadState ?? item.isRead,
                                          date: item.date, isEncrypted: isEncryptedMessage)
                instance.forceUnreadState = item.forceUnreadState
//                print(instance)
                instance.state = item.state
                
            }
            instance.envelopeContainer = envelopeContainer
            instance.updatePrimary()
            if afterburnInterval > 0 {
                instance.applyAutoDeleteTTL(afterburnInterval, startsAt: item.date)
            } else {
                instance.afterburnInterval = afterburnInterval
            }
            
            instance.queryIds = item.shouldPersistArchiveQueryId ? item.queryId : nil
            instance.shouldPersistArchiveQueryId = item.shouldPersistArchiveQueryId
            if let queryId = item.queryId,
               queryId.isNotEmpty {
                archiveQueryIdsByPrimary[instance.primary, default: []].append(queryId)
            }
            instance.countsAsRuntimeUnread = item.countsAsRuntimeUnread &&
                !item.originalOutgoing &&
                !instance.isRead &&
                item.forceUnreadState == nil &&
                !item.clientSyncMessage
            
            if hasSignElement {
                instance.errorMetadata = errorMetadata
            }
            
            if item.clientSyncMessage {
                instance.trustedSource = false
            } else {
                if let queryId = item.queryId {
                    if messageQueryIds.contains(queryId) {
                        instance.trustedSource = true
                    } else {
                        messageQueryIds.insert(queryId)
                        instance.trustedSource = false
                    }
                } else {
                    instance.trustedSource = false
                }
            }
            
            instance.previousId = getPreviousId(item.message)
            XMPPMessageScheduleManager.applyDeferredMetadata(to: instance, source: item.message)
//            print("PIPELINED", item.message)
            
            
            if isEncryptedMessage {
                if !errorMetadata.isEmpty {
                    if omemoError {
                        instance.messageError = "omemo"
                        //                    instance.state = .error
                    } else {
                        if hasSignElement {
                            instance.messageError = "cert_error"
                            //                        instance.state = .error
                        }
                    }
                }
            }
            
//            let conversationType = instance.conversationType
            
//            let readDate = item.isRead ? item.readDate ?? prereadedMessages.first(where: { item.messageId == $0.messageId })?.date ?? prereadedConversation.first(where: { $0.jid == opponent && $0.conversationType == conversationType })?.date : nil
            
            if afterburnInterval > 0 {
                if isEncryptedMessage {
                    if !errorMetadata.isEmpty {
                        if omemoError {
                            instance.markDeleted()
                        }
                    }
                }
            }
            if let readDate = readDate,
               afterburnInterval > 0 {
                instance.isRead = true
                if !item.originalOutgoing {
                    instance.state = .read
                }
                instance.readDate = readDate.timeIntervalSince1970
                if instance.autoDeleteExpiresAt <= 0 {
                    instance.burnDate = readDate.timeIntervalSince1970 + afterburnInterval
                }
                
                if let index = self.prereadedConversation.firstIndex(where: {$0.jid == opponent && $0.conversationType == conversationType}) {
                    if self.prereadedConversation[index].date < readDate {
                        self.prereadedConversation[index].date = readDate
                    }
                } else {
                    self.prereadedConversation.append(PrereadedConversationItem(conversationType: conversationType, date: readDate, jid: opponent))
                }
                
                if instance.effectiveAutoDeleteExpiresAt > 0,
                   instance.effectiveAutoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                    instance.markAutoDeleted()
//                    instance.errorMetadata_ = ""
//                    instance.messageError = nil
                }
            }
            if instance.autoDeleteExpiresAt > 0,
               instance.autoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                instance.markAutoDeleted()
            }
            
            out.insert(instance)
        }
        let batch = ProcessedQueueBatch(
            messages: Array(out).sorted(by: { $0.date < $1.date}),
            readStateRequests: readStateRequests,
            archiveQueryIdsByPrimary: archiveQueryIdsByPrimary
        )
        ChatArchiveDebugTrace.log("messageProcessQueueFinish", [
            ("owner", self.owner),
            ("queryId", queryIds),
            ("inputCount", items.count),
            ("outputCount", batch.messages.count),
            ("readStateRequests", batch.readStateRequests.count),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
        ])
        callback(batch)
    }
    
    @discardableResult
    internal func enqueue(_ item: MessageQueueItem) -> Bool {
        self.performMessageQueueSync {
            let inserted = self.queuedMessages.update(with: item) == nil
            if inserted {
                self.adjustQueuedMessageCounts(for: [item], delta: 1)
            }
            self.publishQueuedMessagesSnapshot()
            self.scheduleQueuedMessagesDrainIfNeeded()
            return inserted
        }
    }
    
    internal func enqueue(collection: [MessageQueueItem]) {
        self.performMessageQueueSync {
            collection.forEach {
                if self.queuedMessages.update(with: $0) == nil {
                    self.adjustQueuedMessageCounts(for: [$0], delta: 1)
                }
            }
            self.publishQueuedMessagesSnapshot()
            self.scheduleQueuedMessagesDrainIfNeeded()
        }
    }
    
    func unsafeSave(_ messages: [MessageStorageItem]) {
        autoreleasepool {
            messages.forEach {
                _ = $0.save(commitTransaction: false)
            }
        }
    }
    
    @discardableResult
    func storeMessagesNow(forQueryId queryId: String? = nil) -> Int {
        storeMessagesNowSummary(forQueryId: queryId).persistedRows
    }

    @discardableResult
    func storeMessagesNowSummary(forQueryId queryId: String? = nil) -> ArchivePersistenceSummary {
        let requestedAt = Date()
        ChatArchiveDebugTrace.log("messageStoreNowRequest", [
            ("owner", self.owner),
            ("queryId", queryId ?? "-")
        ])
        return self.performMessageQueueSync {
            let startedAt = Date()
            let waitMs = ChatArchiveDebugTrace.milliseconds(since: requestedAt)
            let results: Set<MessageQueueItem>
            if let queryId, queryId.isNotEmpty {
                results = Set(self.queuedMessages.filter { $0.queryId == queryId })
            } else {
                results = self.queuedMessages
            }
            let queuedBefore = self.queuedMessages.count
            let queryQueuedBefore = queryId.flatMap { self.queuedMessageCountsByQueryId[$0] } ?? 0
            let queryInFlightBefore = queryId.flatMap { self.inFlightMessageCountsByQueryId[$0] } ?? 0
            ChatArchiveDebugTrace.log("messageStoreNowStart", [
                ("owner", self.owner),
                ("queryId", queryId ?? "-"),
                ("waitMs", waitMs),
                ("queuedBefore", queuedBefore),
                ("queryQueuedBefore", queryQueuedBefore),
                ("queryInFlightBefore", queryInFlightBefore),
                ("drainCount", results.count)
            ])

            guard results.isNotEmpty else {
                if self.queuedMessages.isEmpty {
                    self.isQueuedMessagesDrainScheduled = false
                }
                if let queryId, queryId.isNotEmpty {
                    let summary = self.archivePersistenceSummarySnapshot(forQueryId: queryId)
                    ChatArchiveDebugTrace.log("messageStoreNowEmpty", [
                        ("owner", self.owner),
                        ("queryId", queryId),
                        ("waitMs", waitMs),
                        ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                        ("received", summary.received),
                        ("queued", summary.queued),
                        ("savedNew", summary.savedNew),
                        ("updatedExisting", summary.updatedExisting),
                        ("skipped", summary.skipped),
                        ("failed", summary.failed)
                    ])
                    return summary
                }
                ChatArchiveDebugTrace.log("messageStoreNowEmpty", [
                    ("owner", self.owner),
                    ("queryId", queryId ?? "-"),
                    ("waitMs", waitMs),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
                ])
                return ArchivePersistenceSummary()
            }

            self.adjustQueuedMessageCounts(for: results, delta: -1)
            self.queuedMessages.subtract(results)
            self.publishQueuedMessagesSnapshot()
            self.adjustInFlightMessageCounts(for: results, delta: 1)

            self.processQueue(results, callback: { values in
                if let batch = values {
                    _ = self.save(batch)
                }
            })

            self.adjustInFlightMessageCounts(for: results, delta: -1)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()

            if self.queuedMessages.isEmpty {
                self.isQueuedMessagesDrainScheduled = false
            } else if self.isReceiverActive, !self.isQueuedMessagesDrainScheduled {
                self.scheduleQueuedMessagesDrainOnQueue()
            }

            let summary: ArchivePersistenceSummary
            if let queryId, queryId.isNotEmpty {
                summary = self.archivePersistenceSummarySnapshot(forQueryId: queryId)
            } else {
                summary = ArchivePersistenceSummary()
            }
            ChatArchiveDebugTrace.log("messageStoreNowFinish", [
                ("owner", self.owner),
                ("queryId", queryId ?? "-"),
                ("waitMs", waitMs),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                ("queuedAfter", self.queuedMessages.count),
                ("queryQueuedAfter", queryId.flatMap { self.queuedMessageCountsByQueryId[$0] } ?? 0),
                ("queryInFlightAfter", queryId.flatMap { self.inFlightMessageCountsByQueryId[$0] } ?? 0),
                ("received", summary.received),
                ("queued", summary.queued),
                ("savedNew", summary.savedNew),
                ("updatedExisting", summary.updatedExisting),
                ("skipped", summary.skipped),
                ("failed", summary.failed)
            ])
            return summary
        }
    }
    
    private func reconcileReadStates(_ requests: [ReadStateReconciliationRequest], in realm: Realm) -> Set<String> {
        var clearedNotifications: Set<String> = []
        var affectedChats: Set<String> = []

        requests.forEach { request in
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: request.opponent,
                    owner: request.owner,
                    conversationType: request.conversationType
                )
            ), chat.lastMessage != nil else {
                return
            }

            guard request.itemDate.timeIntervalSinceReferenceDate > chat.messageDate.timeIntervalSinceReferenceDate else {
                return
            }

            affectedChats.insert(request.opponent)

            realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND isRead == %@ AND conversationType_ == %@",
                    request.owner,
                    request.opponent,
                    false,
                    request.conversationType.rawValue
                )
                .forEach {
                    clearedNotifications.insert($0.archivedId)
                    $0.isRead = true
                    if $0.afterburnInterval > 0 && $0.burnDate <= 1 && $0.autoDeleteExpiresAt <= 0,
                       let readDate = request.readDate {
                        $0.readDate = readDate.timeIntervalSince1970
                        $0.burnDate = readDate.timeIntervalSince1970 + request.afterburnInterval
                        if (readDate.timeIntervalSince1970 + request.afterburnInterval) < Date().timeIntervalSince1970 {
                            $0.markAutoDeleted()
                        }
                    }
                }
        }

        if affectedChats.isNotEmpty {
            _ = MentionNotificationSync.reconcileMentionNotifications(
                for: self.owner,
                chats: affectedChats,
                in: realm
            )
        }

        return clearedNotifications
    }

    private func archiveSummary(from outcomes: [ArchivePersistenceOutcomeItem]) -> ArchivePersistenceSummary {
        var summary = ArchivePersistenceSummary()
        outcomes.forEach { item in
            switch item.outcome {
            case .savedNew:
                summary.savedNew += 1
            case .updatedExisting:
                summary.updatedExisting += 1
            case .skipped:
                summary.skipped += 1
            case .failed:
                summary.failed += 1
            }

            if item.outcome != .skipped,
               item.outcome != .failed,
               !item.isDeleted {
                summary.recordVisibleRow(
                    owner: item.owner,
                    jid: item.opponent,
                    conversationType: item.conversationType
                )
            }
            if item.outcome == .savedNew || item.outcome == .updatedExisting {
                summary.recordPersistedArchiveId(
                    item.archivedId,
                    owner: item.owner,
                    jid: item.opponent,
                    conversationType: item.conversationType
                )
            }
        }
        return summary
    }

    private func archiveQueryIds(for message: MessageStorageItem, runtimeQueryIds: [String]?) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        (runtimeQueryIds ?? []).forEach {
            let queryId = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard queryId.isNotEmpty,
                  !seen.contains(queryId) else {
                return
            }
            seen.insert(queryId)
            ids.append(queryId)
        }
        self.queryIds(from: message).forEach {
            guard !seen.contains($0) else {
                return
            }
            seen.insert($0)
            ids.append($0)
        }
        return ids
    }

    private func persistMessage(
        _ message: MessageStorageItem,
        in realm: Realm,
        silentNotifications: Bool,
        runtimeQueryIds: [String]?
    ) -> (ArchivePersistenceOutcomeItem, MessageStorageItem.SaveSideEffects?) {
        message.updatePrimary()
        let existedBefore = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: message.primary) != nil
        let queryIds = self.archiveQueryIds(for: message, runtimeQueryIds: runtimeQueryIds)
        let sideEffects = message.applyMessagePersistence(in: realm, silentNotifications: silentNotifications)

        if sideEffects?.shouldStoreStanza == true {
            message.storeStanza(in: realm)
        }

        let outcome: ArchivePersistenceOutcome
        if sideEffects?.shouldStoreStanza == true {
            outcome = existedBefore ? .updatedExisting : .savedNew
        } else {
            outcome = existedBefore ? .updatedExisting : .skipped
        }

        return (
            ArchivePersistenceOutcomeItem(
                queryIds: queryIds,
                owner: message.owner,
                opponent: message.opponent,
                conversationType: message.conversationType,
                archivedId: message.archivedId,
                isDeleted: message.isDeleted,
                outcome: outcome
            ),
            sideEffects
        )
    }

    private func failedOutcome(for message: MessageStorageItem, runtimeQueryIds: [String]?) -> ArchivePersistenceOutcomeItem {
        ArchivePersistenceOutcomeItem(
            queryIds: self.archiveQueryIds(for: message, runtimeQueryIds: runtimeQueryIds),
            owner: message.owner,
            opponent: message.opponent,
            conversationType: message.conversationType,
            archivedId: message.archivedId,
            isDeleted: message.isDeleted,
            outcome: .failed
        )
    }

    private func saveIndividuallyAfterBatchFailure(
        _ batch: ProcessedQueueBatch,
        silentNotifications: Bool
    ) -> ArchivePersistenceSummary {
        let startedAt = Date()
        let batchQueryIds = Set(batch.archiveQueryIdsByPrimary.values.flatMap { $0 })
            .sorted()
            .joined(separator: ",")
        ChatArchiveDebugTrace.log("messageSaveFallbackStart", [
            ("owner", self.owner),
            ("queryId", batchQueryIds),
            ("count", batch.messages.count)
        ])
        var outcomes: [ArchivePersistenceOutcomeItem] = []
        var persistedMessages: [MessageStorageItem] = []
        var referencePrepareMs = 0
        var referenceCount = 0

        batch.messages.forEach { message in
            do {
                let messageStartedAt = Date()
                let realm = try WRealm.safe()
                var sideEffects: MessageStorageItem.SaveSideEffects?
                var outcome: ArchivePersistenceOutcomeItem?
                try realm.write {
                    let result = self.persistMessage(
                        message,
                        in: realm,
                        silentNotifications: silentNotifications,
                        runtimeQueryIds: batch.archiveQueryIdsByPrimary[message.primary]
                    )
                    outcome = result.0
                    sideEffects = result.1
                }
                if let outcome {
                    outcomes.append(outcome)
                    if outcome.outcome != .failed {
                        persistedMessages.append(message)
                    }
                }
                if let notification = sideEffects?.notification {
                    NotifyManager.shared.update(
                        withMessage: notification.message,
                        messageId: notification.messageId,
                        username: notification.username,
                        opponent: notification.opponent,
                        owner: notification.owner,
                        date: notification.date,
                        displayName: notification.displayName,
                        imageUrl: notification.imageUrl,
                        conversationType: notification.conversationType,
                        preview: notification.preview
                    )
                }
                message.references.forEach { reference in
                    let referenceStartedAt = Date()
                    ChatPerformanceSignposts.measure(.referencePrepare) {
                        reference.prepare()
                    }
                    let durationMs = ChatArchiveDebugTrace.milliseconds(since: referenceStartedAt)
                    referencePrepareMs += durationMs
                    referenceCount += 1
                    if durationMs > 100 {
                        ChatArchiveDebugTrace.log("messageReferencePrepareSlow", [
                            ("owner", self.owner),
                            ("queryId", batch.archiveQueryIdsByPrimary[message.primary]?.joined(separator: ",") ?? message.queryIds ?? "-"),
                            ("referencePrimary", reference.primary),
                            ("kind", reference.kind.rawValue),
                            ("mimeType", reference.mimeType),
                            ("isDownloaded", reference.isDownloaded),
                            ("hasPreview", reference.videoPreviewKey != nil),
                            ("durationMs", durationMs)
                        ])
                    }
                }
                ChatArchiveDebugTrace.log("messageSaveFallbackItem", [
                    ("owner", self.owner),
                    ("queryId", batch.archiveQueryIdsByPrimary[message.primary]?.joined(separator: ",") ?? message.queryIds ?? "-"),
                    ("archivedId", message.archivedId),
                    ("opponent", message.opponent),
                    ("conversationType", message.conversationType.rawValue),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: messageStartedAt))
                ])
            } catch {
                let queryIds = batch.archiveQueryIdsByPrimary[message.primary]
                outcomes.append(self.failedOutcome(for: message, runtimeQueryIds: queryIds))
                DDLogDebug(
                    "MessageManager.save fallback failed queryIds=\(queryIds?.joined(separator: ",") ?? message.queryIds ?? "-") archivedId=\(message.archivedId) messageId=\(message.messageId) opponent=\(message.opponent) conversationType=\(message.conversationType.rawValue) error=\(error.localizedDescription)"
                )
            }
        }

        AccountManager.shared.find(for: self.owner)?.messageSchedule.reconcileDeliveredScheduleMarkers(from: persistedMessages)
        self.recordArchivePersistenceOutcomes(outcomes)
        let summary = self.archiveSummary(from: outcomes)
        ChatArchiveDebugTrace.log("messageSaveFallbackFinish", [
            ("owner", self.owner),
            ("queryId", batchQueryIds),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
            ("referencePrepareMs", referencePrepareMs),
            ("referenceCount", referenceCount),
            ("savedNew", summary.savedNew),
            ("updatedExisting", summary.updatedExisting),
            ("skipped", summary.skipped),
            ("failed", summary.failed)
        ])
        return summary
    }

    @discardableResult
    func save(
        _ batch: ProcessedQueueBatch,
        silentNotifications: Bool = false,
        resetChunkMetrics: Bool = true
    ) -> ArchivePersistenceSummary {
        if resetChunkMetrics {
            self.messagePersistenceChunkSizes.removeAll(keepingCapacity: true)
        }
        guard !batch.messages.isEmpty else {
            return ArchivePersistenceSummary()
        }

        let chunks = batch.chunks(maxSize: min(max(1, self.messagePersistenceChunkSize), 100))
        var summary = ArchivePersistenceSummary()
        chunks.enumerated().forEach { index, chunk in
            self.messagePersistenceChunkSizes.append(chunk.messages.count)
            self.messagePersistenceChunkObserver?(chunk.messages.count, index)
            summary.merge(self.saveSingleBatch(chunk, silentNotifications: silentNotifications))
        }
        return summary
    }

    private func saveSingleBatch(
        _ batch: ProcessedQueueBatch,
        silentNotifications: Bool
    ) -> ArchivePersistenceSummary {
        return ChatPerformanceSignposts.measure(.messagePersistence) {
        let startedAt = Date()
        let batchQueryIds = Set(batch.archiveQueryIdsByPrimary.values.flatMap { $0 })
            .sorted()
            .joined(separator: ",")
        ChatArchiveDebugTrace.log("messageSaveStart", [
            ("owner", self.owner),
            ("queryId", batchQueryIds),
            ("count", batch.messages.count),
            ("readStateRequests", batch.readStateRequests.count)
        ])
        do {
            let realm = try  WRealm.safe()
            var clearedStanzaIDs: Set<String> = []
            var notificationPayloads: [MessageStorageItem.SaveNotificationPayload] = []
            var messagePrimariesToMarkRead: Set<String> = []
            var outcomes: [ArchivePersistenceOutcomeItem] = []
            let affectedChats = Set(batch.messages.compactMap { message -> String? in
                guard message.conversationType == .group else {
                    return nil
                }
                return message.opponent
            })

            try self.archiveBatchSaveFailureInjector?()
            let realmWriteStartedAt = Date()
            try realm.write {
                clearedStanzaIDs = self.reconcileReadStates(batch.readStateRequests, in: realm)
                batch.messages.forEach {
                    let result = self.persistMessage(
                        $0,
                        in: realm,
                        silentNotifications: silentNotifications,
                        runtimeQueryIds: batch.archiveQueryIdsByPrimary[$0.primary]
                    )
                    outcomes.append(result.0)
                    if let notification = result.1?.notification {
                        notificationPayloads.append(notification)
                    }
                }
                if affectedChats.isNotEmpty {
                    messagePrimariesToMarkRead = MentionNotificationSync.reconcileMentionNotifications(
                        for: self.owner,
                        chats: affectedChats,
                        in: realm
                    )
                }
            }
            let realmWriteMs = ChatArchiveDebugTrace.milliseconds(since: realmWriteStartedAt)

            let sideEffectsStartedAt = Date()
            if clearedStanzaIDs.isNotEmpty {
                NotifyManager.shared.clearNotifications(forMessage: Array(clearedStanzaIDs))
            }

            notificationPayloads.forEach {
                NotifyManager.shared.update(
                    withMessage: $0.message,
                    messageId: $0.messageId,
                    username: $0.username,
                    opponent: $0.opponent,
                    owner: $0.owner,
                    date: $0.date,
                    displayName: $0.displayName,
                    imageUrl: $0.imageUrl,
                    conversationType: $0.conversationType,
                    preview: $0.preview
                )
            }

            messagePrimariesToMarkRead.forEach { primary in
                self.readMessage(primary, last: false)
            }
            let sideEffectsMs = ChatArchiveDebugTrace.milliseconds(since: sideEffectsStartedAt)

            let referencePrepareStartedAt = Date()
            var referenceCount = 0
            batch.messages.forEach {
                message in
                message.references.forEach {
                    reference in
                    let referenceStartedAt = Date()
                    ChatPerformanceSignposts.measure(.referencePrepare) {
                        reference.prepare()
                    }
                    let durationMs = ChatArchiveDebugTrace.milliseconds(since: referenceStartedAt)
                    referenceCount += 1
                    if durationMs > 100 {
                        ChatArchiveDebugTrace.log("messageReferencePrepareSlow", [
                            ("owner", self.owner),
                            ("queryId", batch.archiveQueryIdsByPrimary[message.primary]?.joined(separator: ",") ?? message.queryIds ?? "-"),
                            ("referencePrimary", reference.primary),
                            ("kind", reference.kind.rawValue),
                            ("mimeType", reference.mimeType),
                            ("isDownloaded", reference.isDownloaded),
                            ("hasPreview", reference.videoPreviewKey != nil),
                            ("durationMs", durationMs)
                        ])
                    }
                }
            }
            let referencePrepareMs = ChatArchiveDebugTrace.milliseconds(since: referencePrepareStartedAt)
            AccountManager.shared.find(for: self.owner)?.chatMarkers.deleteEphemeralMessages()
            AccountManager.shared.find(for: self.owner)?.messageSchedule.reconcileDeliveredScheduleMarkers(from: batch.messages)
            self.recordArchivePersistenceOutcomes(outcomes)
            let summary = self.archiveSummary(from: outcomes)
            ChatArchiveDebugTrace.log("messageSaveFinish", [
                ("owner", self.owner),
                ("queryId", batchQueryIds),
                ("count", batch.messages.count),
                ("realmWriteMs", realmWriteMs),
                ("sideEffectsMs", sideEffectsMs),
                ("referencePrepareMs", referencePrepareMs),
                ("referenceCount", referenceCount),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                ("savedNew", summary.savedNew),
                ("updatedExisting", summary.updatedExisting),
                ("skipped", summary.skipped),
                ("failed", summary.failed)
            ])
            return summary
        } catch {
            DDLogDebug("MessageManager.save batch failed count=\(batch.messages.count) error=\(error.localizedDescription)")
            return self.saveIndividuallyAfterBatchFailure(batch, silentNotifications: silentNotifications)
        }
        }
    }

    func save(_ messages: [MessageStorageItem], silentNotifications: Bool = false) {
        save(ProcessedQueueBatch(messages: messages, readStateRequests: []), silentNotifications: silentNotifications)
    }
}
