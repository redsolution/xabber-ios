import Foundation

struct ArchiveRetryClock: @unchecked Sendable {
    let sleep: @Sendable (TimeInterval) async -> Void
    let jitter: @Sendable (TimeInterval) -> TimeInterval

    static let production = ArchiveRetryClock(
        sleep: { delay in
            guard delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        jitter: { upperBound in
            Double.random(in: 0...max(upperBound, 0))
        }
    )

    static let immediate = ArchiveRetryClock(
        sleep: { _ in await Task.yield() },
        jitter: { _ in 0 }
    )
}

actor AccountArchiveEngine {
    private struct ConnectionState {
        let generation: UInt64
        let completedXEPSYNCFingerprint: String?
        let waitsForXEPSYNC: Bool
    }

    private struct ActiveExecution {
        let id: UUID
        var intent: ArchiveWindowIntent
    }

    private let owner: String
    private let repository: ArchiveCoverageRepository
    private let transport: ArchiveTransport
    private let retryClock: ArchiveRetryClock
    private let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30]

    private var connection: ConnectionState?
    private var latestIntentByConversation: [ArchiveConversationKey: ArchiveWindowIntent] = [:]
    private var states: [ArchiveConversationKey: ArchiveWindowState] = [:]
    private var activeByDescriptor: [ArchiveIntentDescriptor: ActiveExecution] = [:]
    private var continuations: [ArchiveConversationKey: [UUID: AsyncStream<ArchiveWindowState>.Continuation]] = [:]

    init(
        owner: String,
        repository: ArchiveCoverageRepository,
        transport: ArchiveTransport,
        retryClock: ArchiveRetryClock = .production
    ) {
        self.owner = owner
        self.repository = repository
        self.transport = transport
        self.retryClock = retryClock
    }

    func states(for conversation: ArchiveConversationKey) -> AsyncStream<ArchiveWindowState> {
        let token = UUID()
        return AsyncStream { continuation in
            continuations[conversation, default: [:]][token] = continuation
            if let state = states[conversation] {
                continuation.yield(state)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token, for: conversation) }
            }
        }
    }

    func currentState(for conversation: ArchiveConversationKey) -> ArchiveWindowState? {
        states[conversation]
    }

    func submit(_ intent: ArchiveWindowIntent) {
        guard intent.conversation.owner == owner else { return }
        ArchiveEngineObservability.event(
            .queued,
            value: intent.priority.rawValue
        )
        if let current = latestIntentByConversation[intent.conversation],
           current.semanticDescriptor == intent.semanticDescriptor,
           current.priority > intent.priority {
            return
        }
        latestIntentByConversation[intent.conversation] = intent
        guard let connection else {
            publish(
                .skeleton(reason: .offline, target: intent.locator),
                for: intent.conversation
            )
            return
        }
        startOrJoin(intent, skeletonReason: .unverifiedCoverage)
    }

    func connectionDidBecomeReady(
        generation: UInt64,
        completedXEPSYNCFingerprint: String?,
        waitsForXEPSYNC: Bool = false
    ) {
        let normalizedFingerprint = completedXEPSYNCFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = normalizedFingerprint?.isEmpty == false
            ? normalizedFingerprint
            : nil
        let previous = connection
        connection = ConnectionState(
            generation: generation,
            completedXEPSYNCFingerprint: fingerprint,
            waitsForXEPSYNC: waitsForXEPSYNC
        )

        // Running SQL cannot be cancelled reliably. Remove ownership so the
        // new generation can start; late receipts fail the generation check.
        activeByDescriptor.removeAll(keepingCapacity: true)
        for intent in latestIntentByConversation.values {
            let reason: ArchiveSkeletonReason =
                previous?.completedXEPSYNCFingerprint != fingerprint
                    ? .staleFingerprint
                    : .unverifiedCoverage
            publish(.skeleton(reason: reason, target: intent.locator), for: intent.conversation)
            startOrJoin(intent, skeletonReason: reason)
        }
    }

    func connectionDidDisconnect() {
        connection = nil
        activeByDescriptor.removeAll(keepingCapacity: true)
        for intent in latestIntentByConversation.values {
            publish(
                .skeleton(reason: .offline, target: intent.locator),
                for: intent.conversation
            )
        }
    }

    func retry(conversation: ArchiveConversationKey) {
        guard let intent = latestIntentByConversation[conversation],
              connection != nil else {
            return
        }
        activeByDescriptor.removeValue(forKey: intent.semanticDescriptor)
        startOrJoin(intent, skeletonReason: .loadingTarget)
    }

    func liveMessageDidPersist(
        conversation: ArchiveConversationKey,
        primaryID: String
    ) async {
        let hasVisibleProof: Bool
        switch states[conversation] {
        case .verified, .authoritativeEmpty:
            hasVisibleProof = true
        case .skeleton, .retryableFailure, .none:
            hasVisibleProof = false
        }
        guard conversation.owner == owner,
              let connection,
              let intent = latestIntentByConversation[conversation],
              hasVisibleProof else {
            return
        }
        let freshnessToken: ArchiveFreshnessToken = connection.completedXEPSYNCFingerprint.map {
            .xepSync(fingerprint: $0)
        } ?? .sessionMAM(
            connectionGeneration: connection.generation,
            queryID: "archive.engine.live.\(primaryID)"
        )
        do {
            if let snapshot = try await repository.extendLiveEdge(
                for: intent,
                primaryID: primaryID,
                freshnessToken: freshnessToken
            ), self.connection?.generation == connection.generation {
                publish(.verified(snapshot), for: conversation)
            }
        } catch {
            // A live-edge projection is opportunistic. The existing verified
            // window remains valid; a later interactive newest request repairs
            // any failure without exposing an unproved row.
        }
    }

    private func startOrJoin(
        _ intent: ArchiveWindowIntent,
        skeletonReason: ArchiveSkeletonReason
    ) {
        let descriptor = intent.semanticDescriptor
        if var active = activeByDescriptor[descriptor] {
            ArchiveEngineObservability.event(.duplicateJoin)
            guard intent.priority > active.intent.priority else { return }
            let previousPriority = active.intent.priority
            active.intent = intent
            activeByDescriptor[descriptor] = active
            if intent.priority >= .target ||
                (intent.priority == .visibleIntegrity &&
                    previousPriority == .nearEdgePrefetch) {
                publish(
                    .skeleton(reason: .boundaryGap, target: intent.locator),
                    for: intent.conversation
                )
            }
            Task { await transport.promote(descriptor: descriptor, to: intent.priority) }
            return
        }
        if !preservesVerifiedPresentation(for: intent) {
            publish(
                .skeleton(reason: skeletonReason, target: intent.locator),
                for: intent.conversation
            )
        }
        let execution = ActiveExecution(id: UUID(), intent: intent)
        activeByDescriptor[descriptor] = execution
        Task { [weak self] in
            await self?.execute(
                descriptor: descriptor,
                executionID: execution.id
            )
        }
    }

    private func execute(
        descriptor: ArchiveIntentDescriptor,
        executionID: UUID
    ) async {
        guard let execution = activeByDescriptor[descriptor],
              execution.id == executionID,
              let connection else {
            return
        }
        let intent = execution.intent

        if let fingerprint = connection.completedXEPSYNCFingerprint {
            do {
                try await repository.verifyProvisionalCoverage(
                    owner: owner,
                    fingerprint: fingerprint
                )
                let token = ArchiveFreshnessToken.xepSync(fingerprint: fingerprint)
                if let admission = try await repository.verifiedAdmission(
                    for: intent,
                    freshnessToken: token
                ), isCurrent(executionID, descriptor: descriptor, generation: connection.generation) {
                    switch admission {
                    case .verified(let snapshot):
                        publish(.verified(snapshot), for: intent.conversation)
                    case .authoritativeEmpty:
                        publish(
                            .authoritativeEmpty(
                                target: intent.locator,
                                freshnessToken: token
                            ),
                            for: intent.conversation
                        )
                    }
                    finish(executionID, descriptor: descriptor)
                    return
                }
            } catch {
                // Storage failures follow the same bounded retry path as the
                // transport because no content may be admitted without it.
            }
        }

        var failureCount = 0
        var nextGapBoundary: ArchiveCursor?
        while isCurrent(executionID, descriptor: descriptor, generation: connection.generation) {
            let queryID = "archive.engine.\(UUID().uuidString)"
            let proofFingerprint = connection.completedXEPSYNCFingerprint ??
                "session:\(connection.generation)"
            let requestIntent: ArchiveWindowIntent
            if case .gap(let olderBoundary, let originalNewerBoundary) = intent.locator,
               let nextGapBoundary {
                requestIntent = ArchiveWindowIntent(
                    id: intent.id,
                    conversation: intent.conversation,
                    locator: .gap(
                        olderBoundary: olderBoundary,
                        newerBoundary: min(nextGapBoundary, originalNewerBoundary)
                    ),
                    contextBefore: intent.contextBefore,
                    contextAfter: intent.contextAfter,
                    priority: intent.priority
                )
            } else {
                requestIntent = intent
            }
            let request = makeRequest(
                intent: requestIntent,
                queryID: queryID,
                generation: connection.generation,
                proofFingerprint: proofFingerprint
            )
            let freshnessToken: ArchiveFreshnessToken = connection.completedXEPSYNCFingerprint.map {
                .xepSync(fingerprint: $0)
            } ?? .sessionMAM(
                connectionGeneration: connection.generation,
                queryID: queryID
            )
            do {
                let receipt = try await transport.request(
                    request,
                    priority: activeByDescriptor[descriptor]?.intent.priority ?? intent.priority
                )
                let page = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
                guard isCurrent(
                    executionID,
                    descriptor: descriptor,
                    generation: connection.generation
                ) else { return }
                let commit = try await repository.commit(
                    page,
                    request: request,
                    freshnessToken: freshnessToken
                )
                ArchiveEngineObservability.event(
                    .proof,
                    value: page.messagePrimaryIDs.count
                )
                guard isCurrent(
                    executionID,
                    descriptor: descriptor,
                    generation: connection.generation
                ) else { return }
                switch commit {
                case .verified(let snapshot):
                    publish(
                        .verified(retarget(snapshot, to: intent.locator)),
                        for: intent.conversation
                    )
                    if intent.priority == .nearEdgePrefetch {
                        ArchiveEngineObservability.event(.prefetchResult, value: 1)
                    }
                case .authoritativeEmpty:
                    publish(
                        .authoritativeEmpty(
                            target: intent.locator,
                            freshnessToken: freshnessToken
                        ),
                        for: intent.conversation
                    )
                case .materializedWithoutCoverage:
                    let snapshot = try await verifyMaterializedTargetWindow(
                        intent: intent,
                        exactPage: page,
                        connection: connection,
                        proofFingerprint: proofFingerprint,
                        freshnessToken: freshnessToken,
                        executionID: executionID,
                        descriptor: descriptor
                    )
                    guard isCurrent(
                        executionID,
                        descriptor: descriptor,
                        generation: connection.generation
                    ) else { return }
                    publish(.verified(snapshot), for: intent.conversation)
                case .coverageAdvanced(let boundary):
                    guard case .gap(let olderBoundary, let newerBoundary) = request.locator,
                          boundary > olderBoundary,
                          boundary < newerBoundary else {
                        throw ArchiveTransportError.malformedCursor
                    }
                    nextGapBoundary = boundary
                    failureCount = 0
                    continue
                }
                finish(executionID, descriptor: descriptor)
                return
            } catch {
                failureCount += 1
                let retryable = isRetryable(error)
                ArchiveEngineObservability.event(
                    .retry,
                    value: failureCount,
                    auxiliary: retryable ? 1 : 0
                )
                guard retryable, failureCount <= retryDelays.count else {
                    if isCurrent(
                        executionID,
                        descriptor: descriptor,
                        generation: connection.generation
                    ) {
                        if !preservesVerifiedPresentation(for: intent) {
                            publish(
                                .retryableFailure(
                                    ArchiveRetryableFailure(
                                        message: String(describing: error),
                                        retryCount: failureCount,
                                        canRetry: retryable
                                    ),
                                    target: intent.locator
                                ),
                                for: intent.conversation
                            )
                        }
                        if intent.priority == .nearEdgePrefetch {
                            ArchiveEngineObservability.event(.prefetchResult, value: 0)
                        }
                        finish(executionID, descriptor: descriptor)
                    }
                    return
                }
                let upperBound = retryDelays[failureCount - 1]
                await retryClock.sleep(retryClock.jitter(upperBound))
            }
        }
    }

    private func verifyMaterializedTargetWindow(
        intent: ArchiveWindowIntent,
        exactPage: ValidatedArchiveTransportPage,
        connection: ConnectionState,
        proofFingerprint: String,
        freshnessToken: ArchiveFreshnessToken,
        executionID: UUID,
        descriptor: ArchiveIntentDescriptor
    ) async throws -> ArchiveWindowSnapshot {
        guard let anchor = try await repository.materializedAnchor(
            conversation: intent.conversation,
            locator: intent.locator,
            candidateArchiveIDs: exactPage.chronologicalArchiveIDs
        ) else {
            throw ArchiveTransportError.malformedCursor
        }
        let olderRequest = ArchiveTransportRequest(
            queryID: "archive.engine.anchor.older.\(UUID().uuidString)",
            conversation: intent.conversation,
            locator: .older(before: anchor.cursor),
            connectionGeneration: connection.generation,
            pageSize: max(1, intent.contextBefore),
            contextBefore: intent.contextBefore,
            contextAfter: 0,
            proofFingerprint: proofFingerprint,
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let olderReceipt = try await transport.request(
            olderRequest,
            priority: activeByDescriptor[descriptor]?.intent.priority ?? intent.priority
        )
        guard isCurrent(
            executionID,
            descriptor: descriptor,
            generation: connection.generation
        ) else {
            throw ArchiveTransportError.disconnected
        }
        let olderPage = try ArchiveTransportReceiptValidator.validate(
            olderReceipt,
            for: olderRequest
        )

        let newerRequest = ArchiveTransportRequest(
            queryID: "archive.engine.anchor.newer.\(UUID().uuidString)",
            conversation: intent.conversation,
            locator: .newer(after: anchor.cursor),
            connectionGeneration: connection.generation,
            pageSize: max(1, intent.contextAfter),
            contextBefore: 0,
            contextAfter: intent.contextAfter,
            proofFingerprint: proofFingerprint,
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let newerReceipt = try await transport.request(
            newerRequest,
            priority: activeByDescriptor[descriptor]?.intent.priority ?? intent.priority
        )
        guard isCurrent(
            executionID,
            descriptor: descriptor,
            generation: connection.generation
        ) else {
            throw ArchiveTransportError.disconnected
        }
        let newerPage = try ArchiveTransportReceiptValidator.validate(
            newerReceipt,
            for: newerRequest
        )
        return try await repository.commitAnchorWindow(
            intent: intent,
            anchor: anchor,
            exactPage: exactPage,
            olderPage: olderPage,
            newerPage: newerPage,
            freshnessToken: freshnessToken
        )
    }

    private func retarget(
        _ snapshot: ArchiveWindowSnapshot,
        to locator: ArchiveWindowLocator
    ) -> ArchiveWindowSnapshot {
        guard snapshot.target != locator else { return snapshot }
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: snapshot.messagePrimaryIDs,
            target: locator,
            verifiedSegment: snapshot.verifiedSegment,
            coverageGeneration: snapshot.coverageGeneration,
            freshnessToken: snapshot.freshnessToken
        )
    }

    private func makeRequest(
        intent: ArchiveWindowIntent,
        queryID: String,
        generation: UInt64,
        proofFingerprint: String
    ) -> ArchiveTransportRequest {
        let requestLocator: ArchiveWindowLocator
        let pageSize: Int
        switch intent.locator {
        case .latest:
            requestLocator = intent.locator
            pageSize = ArchivePageSizing.initial
        case .archiveID, .timestamp:
            requestLocator = intent.locator
            pageSize = max(1, intent.contextBefore + intent.contextAfter)
        case .firstUnread(.some(let boundary)):
            // `after` is strict on the server, so it cannot prove that the
            // unread boundary itself joins the newer page. Materialize the
            // exact row first, then use the same two-sided anchor proof as a
            // search jump. This prevents a one-row discontinuity.
            requestLocator = .archiveID(boundary)
            pageSize = 1
        case .firstUnread(.none), .older, .newer, .gap:
            requestLocator = intent.locator
            pageSize = ArchivePageSizing.history
        }
        let continuous = requestLocator.isContinuousArchiveWindow
        return ArchiveTransportRequest(
            queryID: queryID,
            conversation: intent.conversation,
            locator: requestLocator,
            connectionGeneration: generation,
            pageSize: pageSize,
            contextBefore: intent.contextBefore,
            contextAfter: intent.contextAfter,
            proofFingerprint: proofFingerprint,
            isUnfiltered: continuous,
            producesContinuousCoverage: continuous
        )
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let transportError = error as? ArchiveTransportError {
            return transportError.isRetryable
        }
        if error is ArchiveTransportValidationError {
            return false
        }
        return true
    }

    private func preservesVerifiedPresentation(for intent: ArchiveWindowIntent) -> Bool {
        guard intent.priority == .nearEdgePrefetch,
              case .verified = states[intent.conversation] else {
            return false
        }
        return true
    }

    private func isCurrent(
        _ executionID: UUID,
        descriptor: ArchiveIntentDescriptor,
        generation: UInt64
    ) -> Bool {
        connection?.generation == generation &&
            activeByDescriptor[descriptor]?.id == executionID
    }

    private func finish(_ executionID: UUID, descriptor: ArchiveIntentDescriptor) {
        guard activeByDescriptor[descriptor]?.id == executionID else { return }
        activeByDescriptor.removeValue(forKey: descriptor)
    }

    private func publish(
        _ state: ArchiveWindowState,
        for conversation: ArchiveConversationKey
    ) {
        states[conversation] = state
        continuations[conversation]?.values.forEach { $0.yield(state) }
    }

    private func removeContinuation(_ token: UUID, for conversation: ArchiveConversationKey) {
        continuations[conversation]?.removeValue(forKey: token)
        if continuations[conversation]?.isEmpty == true {
            continuations.removeValue(forKey: conversation)
        }
    }

#if DEBUG
    func waitUntilIdleForTesting() async {
        for _ in 0..<2_000 {
            if activeByDescriptor.isEmpty { return }
            await Task.yield()
        }
    }
#endif
}
