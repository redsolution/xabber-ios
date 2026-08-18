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
        guard !connection.waitsForXEPSYNC else {
            publish(
                .skeleton(reason: .unverifiedCoverage, target: intent.locator),
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
            if !waitsForXEPSYNC {
                startOrJoin(intent, skeletonReason: reason)
            }
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
              connection?.waitsForXEPSYNC == false else {
            return
        }
        activeByDescriptor.removeValue(forKey: intent.semanticDescriptor)
        startOrJoin(intent, skeletonReason: .loadingTarget)
    }

    private func startOrJoin(
        _ intent: ArchiveWindowIntent,
        skeletonReason: ArchiveSkeletonReason
    ) {
        let descriptor = intent.semanticDescriptor
        if var active = activeByDescriptor[descriptor] {
            guard intent.priority > active.intent.priority else { return }
            active.intent = intent
            activeByDescriptor[descriptor] = active
            Task { await transport.promote(descriptor: descriptor, to: intent.priority) }
            return
        }
        publish(
            .skeleton(reason: skeletonReason, target: intent.locator),
            for: intent.conversation
        )
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
        while isCurrent(executionID, descriptor: descriptor, generation: connection.generation) {
            let queryID = "archive.engine.\(UUID().uuidString)"
            let proofFingerprint = connection.completedXEPSYNCFingerprint ??
                "session:\(connection.generation)"
            let request = makeRequest(
                intent: intent,
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
                guard isCurrent(
                    executionID,
                    descriptor: descriptor,
                    generation: connection.generation
                ) else { return }
                switch commit {
                case .verified(let snapshot):
                    publish(.verified(snapshot), for: intent.conversation)
                case .authoritativeEmpty:
                    publish(
                        .authoritativeEmpty(
                            target: intent.locator,
                            freshnessToken: freshnessToken
                        ),
                        for: intent.conversation
                    )
                case .materializedWithoutCoverage:
                    publish(
                        .skeleton(reason: .loadingTarget, target: intent.locator),
                        for: intent.conversation
                    )
                }
                finish(executionID, descriptor: descriptor)
                return
            } catch {
                failureCount += 1
                let retryable = isRetryable(error)
                guard retryable, failureCount <= retryDelays.count else {
                    if isCurrent(
                        executionID,
                        descriptor: descriptor,
                        generation: connection.generation
                    ) {
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
                        finish(executionID, descriptor: descriptor)
                    }
                    return
                }
                let upperBound = retryDelays[failureCount - 1]
                await retryClock.sleep(retryClock.jitter(upperBound))
            }
        }
    }

    private func makeRequest(
        intent: ArchiveWindowIntent,
        queryID: String,
        generation: UInt64,
        proofFingerprint: String
    ) -> ArchiveTransportRequest {
        let pageSize: Int
        switch intent.locator {
        case .latest:
            pageSize = ArchivePageSizing.initial
        case .archiveID, .timestamp:
            pageSize = max(1, intent.contextBefore + intent.contextAfter)
        case .firstUnread, .older, .newer, .gap:
            pageSize = ArchivePageSizing.history
        }
        let continuous = intent.locator.isContinuousArchiveWindow
        return ArchiveTransportRequest(
            queryID: queryID,
            conversation: intent.conversation,
            locator: intent.locator,
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
