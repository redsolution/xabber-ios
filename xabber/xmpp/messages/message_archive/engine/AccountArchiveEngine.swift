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

enum ArchiveAdmissionRetryPolicy {
    private static let transientIQConditions: Set<String> = [
        "internal-server-error",
        "remote-server-timeout",
        "resource-constraint",
        "service-unavailable"
    ]

    static func retryDecision(for error: Error) -> Bool? {
        if let admissionError = error as? ArchiveConversationAdmissionError {
            switch admissionError {
            case .disconnected, .staleConnection:
                return true
            case .ownerMismatch,
                 .invalidGroupJID,
                 .missingSelfMemberID,
                 .inactiveSelfMembership,
                 .tombstoned:
                return false
            }
        }
        if let requestError = error as? GroupRequestError {
            switch requestError {
            case .timeout, .disconnected, .cancelled:
                return true
            case .iq(let iqError):
                return transientIQConditions.contains(
                    iqError.condition.lowercased()
                )
            case .duplicateRequestID:
                return false
            }
        }
        if let serviceError = error as? GroupchatServiceError {
            switch serviceError {
            case .notPrepared:
                return true
            case .iq(let iqError):
                return iqError.condition.map {
                    transientIQConditions.contains($0.lowercased())
                } ?? false
            case .invalidJID,
                 .invalidRequestID,
                 .missingCreatedGroupJID,
                 .invalidDemotionPermissions,
                 .invalidPermissionResetBaseline,
                 .unexpectedPayload,
                 .responseDecoding:
                return false
            }
        }
        if error is GroupRepositoryError ||
            error is GroupCommandCodecError ||
            error is GroupProtocolCodecError ||
            error is GroupStanzaRouterError {
            return false
        }
        return nil
    }

    static func isRetryable(_ error: Error) -> Bool {
        retryDecision(for: error) ?? false
    }
}

actor AccountArchiveEngine {
    private struct ConnectionState {
        let generation: UInt64
    }

    private enum ConnectionTransitionState: Equatable {
        case ready(generation: UInt64)
        case disconnected
    }

    private struct ConnectionTransition {
        let sequence: UInt64
        let state: ConnectionTransitionState
    }

    private struct ActiveExecution {
        let id: UUID
        var intent: ArchiveWindowIntent
        var requestIDs: Set<UUID>
    }

    /// Ownership retained after a terminal archive failure while presentation
    /// backoff is waiting. A retry callback may only consume the exact failed
    /// execution in the same authenticated stream generation. Any newer submit,
    /// replacement or reconnect invalidates this value before it can start work.
    private struct AutomaticRetryOwnership {
        let descriptor: ArchiveIntentDescriptor
        let failedExecutionID: UUID
        let connectionGeneration: UInt64
    }

    private struct SearchExecution {
        let clientQueryID: String
        let scope: ArchiveSearchScope
        let query: String
        let generation: UInt64
        var residentPages: [ArchiveSearchPage] = []
        var cursorStack: [String] = []
        var nextCursor: String?
        var loadedPageCount = 0
        var requestAttempt = 0
        var isComplete = false
        var isLoading = false
        var shouldResumeAfterReconnect = false
    }

    private let owner: String
    private let repository: ArchiveCoverageRepository
    private let transport: ArchiveTransport
    private let admissionProvider: ArchiveConversationAdmissionProviding
    private let retryClock: ArchiveRetryClock
    private let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30]

    private var connection: ConnectionState?
    private var pendingConnectionGeneration: UInt64?
    private var latestConnectionTransition: ConnectionTransition?
    private var latestIntentByConversation:
        [ArchiveConversationKey: ArchiveWindowIntent] = [:]
    // Directional paging is session-relative. This map retains the last
    // replacement-safe target across local paging, live projection and reconnect.
    private var replacementIntentByConversation:
        [ArchiveConversationKey: ArchiveWindowIntent] = [:]
    private var states: [ArchiveConversationKey: ArchiveWindowState] = [:]
    private var currentLiveEdgeAdmissions:
        [ArchiveConversationKey: ArchiveLiveEdgeAdmission] = [:]
    private var activities: [ArchiveConversationKey: ArchiveWindowActivity] = [:]
    private var activeByDescriptor: [ArchiveIntentDescriptor: ActiveExecution] = [:]
    private var automaticRetryOwnershipByConversation:
        [ArchiveConversationKey: AutomaticRetryOwnership] = [:]
    private var continuations: [ArchiveConversationKey: [UUID: AsyncStream<ArchiveWindowState>.Continuation]] = [:]
    private var liveEdgeContinuations:
        [ArchiveConversationKey: [UUID: AsyncStream<ArchiveLiveEdgeAdmission>.Continuation]] = [:]
    private var localOutgoingContinuations:
        [ArchiveConversationKey: [UUID: AsyncStream<ChatTimelineLocalOutgoingAdmission>.Continuation]] = [:]
    private var pendingLocalOutgoingAdmissions:
        [ArchiveConversationKey: [ChatTimelineLocalOutgoingAdmission]] = [:]
    private var activityContinuations: [ArchiveConversationKey: [UUID: AsyncStream<ArchiveWindowActivity>.Continuation]] = [:]
    private var boundaryTerminalContinuations:
        [ArchiveConversationKey: [UUID: AsyncStream<ArchiveBoundaryTerminalOutcome>.Continuation]] = [:]
    private var searchGeneration: UInt64 = 0
    private var searchExecutions: [ArchiveSearchScope: SearchExecution] = [:]
    private var searchStates: [ArchiveSearchScope: ArchiveSearchState] = [:]
    private var searchContinuations: [ArchiveSearchScope: [UUID: AsyncStream<ArchiveSearchState>.Continuation]] = [:]
    private var presentationDemandIDs: [ArchiveConversationKey: Set<UUID>] = [:]

    init(
        owner: String,
        repository: ArchiveCoverageRepository,
        transport: ArchiveTransport,
        admissionProvider: ArchiveConversationAdmissionProviding,
        retryClock: ArchiveRetryClock = .production
    ) {
        self.owner = owner
        self.repository = repository
        self.transport = transport
        self.admissionProvider = admissionProvider
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

    func liveEdgeAdmissions(
        for conversation: ArchiveConversationKey
    ) -> AsyncStream<ArchiveLiveEdgeAdmission> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            liveEdgeContinuations[conversation, default: [:]][token] = continuation
            if let admission = currentLiveEdgeAdmissions[conversation] {
                continuation.yield(admission)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeLiveEdgeContinuation(
                        token,
                        for: conversation
                    )
                }
            }
        }
    }

    func currentLiveEdgeAdmission(
        for conversation: ArchiveConversationKey
    ) -> ArchiveLiveEdgeAdmission? {
        currentLiveEdgeAdmissions[conversation]
    }

    func localOutgoingAdmissions(
        for conversation: ArchiveConversationKey
    ) -> AsyncStream<ChatTimelineLocalOutgoingAdmission> {
        let token = UUID()
        return AsyncStream { continuation in
            localOutgoingContinuations[conversation, default: [:]][token] =
                continuation
            pendingLocalOutgoingAdmissions[conversation]?.forEach {
                continuation.yield($0)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeLocalOutgoingContinuation(
                        token,
                        for: conversation
                    )
                }
            }
        }
    }

    /// Publishes only a typed presentation admission. Archive state, coverage,
    /// cursors and transport ownership are deliberately untouched.
    func localOutgoingDidPersist(
        _ admission: ChatTimelineLocalOutgoingAdmission
    ) {
        guard admission.conversation.owner == owner,
              admission.primaryID.isNotEmpty else {
            return
        }
        var pending = pendingLocalOutgoingAdmissions[
            admission.conversation,
            default: []
        ]
        pending.removeAll { $0.primaryID == admission.primaryID }
        pending.append(admission)
        if pending.count > 600 {
            pending = Array(pending.suffix(600))
        }
        pendingLocalOutgoingAdmissions[admission.conversation] = pending
        localOutgoingContinuations[admission.conversation]?.values.forEach {
            $0.yield(admission)
        }
    }

    func activities(for conversation: ArchiveConversationKey) -> AsyncStream<ArchiveWindowActivity> {
        let token = UUID()
        return AsyncStream { continuation in
            activityContinuations[conversation, default: [:]][token] = continuation
            continuation.yield(activities[conversation] ?? .idle)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeActivityContinuation(token, for: conversation) }
            }
        }
    }

    func currentActivity(for conversation: ArchiveConversationKey) -> ArchiveWindowActivity {
        activities[conversation] ?? .idle
    }

    func boundaryTerminals(
        for conversation: ArchiveConversationKey
    ) -> AsyncStream<ArchiveBoundaryTerminalOutcome> {
        let token = UUID()
        return AsyncStream { continuation in
            boundaryTerminalContinuations[conversation, default: [:]][token] =
                continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeBoundaryTerminalContinuation(
                        token,
                        for: conversation
                    )
                }
            }
        }
    }

    func attachPresentationDemand(
        for conversation: ArchiveConversationKey,
        demandID: UUID
    ) {
        guard conversation.owner == owner else { return }
        presentationDemandIDs[conversation, default: []].insert(demandID)
    }

    func detachPresentationDemand(
        for conversation: ArchiveConversationKey,
        demandID: UUID
    ) {
        presentationDemandIDs[conversation]?.remove(demandID)
        guard presentationDemandIDs[conversation]?.isEmpty != false else {
            return
        }
        // A request that has already reached the transport remains owned by
        // the engine until its terminal receipt is validated and committed.
        // Dropping presentation demand only prevents publication and future
        // reconnect work; removing the execution here would discard a valid
        // in-flight page before persistence/coverage accounting completes.
        presentationDemandIDs.removeValue(forKey: conversation)
        latestIntentByConversation.removeValue(forKey: conversation)
        replacementIntentByConversation.removeValue(forKey: conversation)
        automaticRetryOwnershipByConversation.removeValue(forKey: conversation)
        states.removeValue(forKey: conversation)
        currentLiveEdgeAdmissions.removeValue(forKey: conversation)
        activities.removeValue(forKey: conversation)
    }

    func searchStates(
        for conversation: ArchiveConversationKey
    ) -> AsyncStream<ArchiveSearchState> {
        searchStates(for: .conversation(conversation))
    }

    func searchStates(
        for scope: ArchiveSearchScope
    ) -> AsyncStream<ArchiveSearchState> {
        let token = UUID()
        return AsyncStream { continuation in
            searchContinuations[scope, default: [:]][token] = continuation
            if let state = searchStates[scope] {
                continuation.yield(state)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSearchContinuation(token, for: scope) }
            }
        }
    }

    @discardableResult
    func startSearch(_ intent: ArchiveSearchIntent) -> UInt64 {
        guard intent.scope.owner == owner,
              intent.clientQueryID.isNotEmpty,
              intent.query.isNotEmpty else {
            return 0
        }
        let joinedGeneration = searchExecutions.values.first(where: {
            $0.clientQueryID == intent.clientQueryID &&
                $0.query == intent.query
        })?.generation
        if let existing = searchExecutions[intent.scope],
           existing.clientQueryID == intent.clientQueryID,
           existing.query == intent.query {
            return existing.generation
        }
        let executionGeneration: UInt64
        if let joinedGeneration {
            // One global UI query may need multiple server scopes (for example,
            // regular plus group archives). They share one query generation
            // while each scope retains independent cursor/page state.
            executionGeneration = joinedGeneration
        } else {
            searchGeneration &+= 1
            // A genuinely new query invalidates every old scope. Running SQL is
            // allowed to finish, but its receipt no longer has actor ownership.
            searchExecutions.removeAll(keepingCapacity: true)
            searchStates.removeAll(keepingCapacity: true)
            executionGeneration = searchGeneration
        }
        var execution = SearchExecution(
            clientQueryID: intent.clientQueryID,
            scope: intent.scope,
            query: intent.query,
            generation: executionGeneration
        )
        execution.shouldResumeAfterReconnect = connection == nil
        searchExecutions[intent.scope] = execution
        if connection == nil {
            publishSearchFailure(
                execution,
                error: ArchiveTransportError.disconnected
            )
        } else {
            _ = startSearchPage(for: intent.scope)
        }
        return executionGeneration
    }

    @discardableResult
    func requestNextSearchPage(
        conversation: ArchiveConversationKey,
        clientQueryID: String
    ) -> Bool {
        requestNextSearchPage(
            scope: .conversation(conversation),
            clientQueryID: clientQueryID
        )
    }

    @discardableResult
    func requestNextSearchPage(
        scope: ArchiveSearchScope,
        clientQueryID: String
    ) -> Bool {
        guard var execution = searchExecutions[scope],
              execution.clientQueryID == clientQueryID,
              !execution.isComplete,
              !execution.isLoading else {
            return false
        }
        if connection == nil {
            execution.shouldResumeAfterReconnect = true
            searchExecutions[scope] = execution
            return true
        }
        return startSearchPage(for: scope)
    }

    func cancelSearch(
        conversation: ArchiveConversationKey,
        clientQueryID: String? = nil
    ) {
        cancelSearch(
            scope: .conversation(conversation),
            clientQueryID: clientQueryID
        )
    }

    func cancelSearch(
        scope: ArchiveSearchScope,
        clientQueryID: String? = nil
    ) {
        guard let execution = searchExecutions[scope],
              clientQueryID == nil || execution.clientQueryID == clientQueryID else {
            return
        }
        // Server-side SQL may already be running. Removing actor ownership is
        // sufficient: every late receipt is rejected by generation/query checks.
        searchGeneration &+= 1
        searchExecutions.removeValue(forKey: scope)
        searchStates.removeValue(forKey: scope)
    }

    func submit(_ intent: ArchiveWindowIntent) {
        guard intent.conversation.owner == owner,
              hasPresentationDemand(for: intent.conversation) else {
            return
        }
        ArchiveEngineObservability.event(
            .queued,
            value: intent.priority.rawValue
        )
        // A concrete submit supersedes every delayed callback retained for an
        // older failed execution, even when the semantic descriptor is equal.
        automaticRetryOwnershipByConversation.removeValue(
            forKey: intent.conversation
        )
        let acceptedIntent: ArchiveWindowIntent
        if let current = latestIntentByConversation[intent.conversation],
           current.semanticDescriptor == intent.semanticDescriptor,
           current.priority > intent.priority {
            if var active = activeByDescriptor[intent.semanticDescriptor] {
                active.requestIDs.insert(intent.id)
                activeByDescriptor[intent.semanticDescriptor] = active
                ArchiveEngineObservability.event(.duplicateJoin)
                return
            }
            // The previous execution is already terminal. Preserve its higher
            // scheduling class while accepting the new request ID as a fresh
            // owned execution; otherwise a later low-priority request is lost.
            acceptedIntent = ArchiveWindowIntent(
                id: intent.id,
                conversation: intent.conversation,
                locator: intent.locator,
                contextBefore: intent.contextBefore,
                contextAfter: intent.contextAfter,
                priority: current.priority
            )
        } else {
            acceptedIntent = intent
        }
        if currentLiveEdgeAdmissions[acceptedIntent.conversation]?.presentationIntent !=
                acceptedIntent.semanticDescriptor {
            currentLiveEdgeAdmissions.removeValue(forKey: acceptedIntent.conversation)
        }
        rememberReplacementIntent(for: acceptedIntent)
        latestIntentByConversation[acceptedIntent.conversation] = acceptedIntent
        guard connection != nil else {
            publish(
                .skeleton(reason: .offline, target: acceptedIntent.locator),
                for: acceptedIntent.conversation
            )
            return
        }
        startOrJoin(acceptedIntent, skeletonReason: .unverifiedCoverage)
    }

    func connectionDidBecomeReady(
        generation: UInt64,
        transitionSequence: UInt64? = nil
    ) async {
        guard acceptConnectionTransition(
            sequence: transitionSequence,
            state: .ready(generation: generation)
        ) else {
            return
        }
        guard connection?.generation != generation,
              pendingConnectionGeneration != generation else {
            return
        }

        // Hide the new generation until the group-admission transport has
        // rebound. A submit that arrives during this await remains queued as
        // the latest intent and cannot start a duplicate MAM.
        connection = nil
        pendingConnectionGeneration = generation
        currentLiveEdgeAdmissions.removeAll(keepingCapacity: true)
        automaticRetryOwnershipByConversation.removeAll(keepingCapacity: true)
        let formerlyActiveConversations = cancelAllActiveExecutions()
        formerlyActiveConversations.forEach { publishActivity(for: $0) }
        await admissionProvider.connectionDidBecomeReady(generation: generation)
        guard pendingConnectionGeneration == generation,
              latestConnectionTransition?.state ==
                .ready(generation: generation) else {
            return
        }
        connection = ConnectionState(generation: generation)
        pendingConnectionGeneration = nil
        replaceDirectionalIntentsForFreshConnection()
        for intent in latestIntentByConversation.values {
            let reason = ArchiveSkeletonReason.unverifiedCoverage
            publish(.skeleton(reason: reason, target: intent.locator), for: intent.conversation)
            startOrJoin(intent, skeletonReason: reason)
        }
        for scope in Array(searchExecutions.keys) {
            guard var execution = searchExecutions[scope],
                  !execution.isComplete,
                  execution.shouldResumeAfterReconnect else { continue }
            execution.isLoading = false
            execution.shouldResumeAfterReconnect = false
            searchExecutions[scope] = execution
            _ = startSearchPage(for: scope)
        }
    }

    func connectionDidDisconnect(
        transitionSequence: UInt64? = nil
    ) async {
        guard acceptConnectionTransition(
            sequence: transitionSequence,
            state: .disconnected
        ) else {
            return
        }
        connection = nil
        pendingConnectionGeneration = nil
        currentLiveEdgeAdmissions.removeAll(keepingCapacity: true)
        automaticRetryOwnershipByConversation.removeAll(keepingCapacity: true)
        let formerlyActiveConversations = cancelAllActiveExecutions()
        formerlyActiveConversations.forEach { publishActivity(for: $0) }
        replaceDirectionalIntentsForFreshConnection()
        for intent in latestIntentByConversation.values {
            publish(
                .skeleton(reason: .offline, target: intent.locator),
                for: intent.conversation
            )
        }
        for scope in Array(searchExecutions.keys) {
            guard var execution = searchExecutions[scope] else { continue }
            guard !execution.isComplete else { continue }
            execution.shouldResumeAfterReconnect = execution.isLoading
            execution.isLoading = false
            searchExecutions[scope] = execution
            publishSearchFailure(
                execution,
                error: ArchiveTransportError.disconnected
            )
        }
        await admissionProvider.connectionDidDisconnect()
    }

    func retry(conversation: ArchiveConversationKey) {
        guard let connection,
              let ownership = automaticRetryOwnershipByConversation[conversation],
              ownership.connectionGeneration == connection.generation,
              let intent = latestIntentByConversation[conversation],
              intent.semanticDescriptor == ownership.descriptor,
              hasPresentationDemand(for: conversation) else {
            automaticRetryOwnershipByConversation.removeValue(
                forKey: conversation
            )
            return
        }
        guard activeByDescriptor[ownership.descriptor]?.id !=
                ownership.failedExecutionID else {
            return
        }
        guard activeByDescriptor[ownership.descriptor] == nil else {
            // A newer submit or reconnect already owns this semantic request.
            // Joining requires no second transport request and, crucially, no
            // cancelled terminal that could release its presentation gate.
            automaticRetryOwnershipByConversation.removeValue(
                forKey: conversation
            )
            return
        }
        automaticRetryOwnershipByConversation.removeValue(forKey: conversation)
        startOrJoin(intent, skeletonReason: .loadingTarget)
    }

    func liveMessageDidPersist(
        conversation: ArchiveConversationKey,
        primaryID: String
    ) async {
        let initialCoverageGeneration: UInt64
        let initialSegment: ArchiveCoverageSegment?
        let initialFingerprint: String
        switch states[conversation] {
        case .verified(let snapshot):
            guard snapshot.verifiedSegment.reachesLiveEdge else { return }
            initialCoverageGeneration = snapshot.coverageGeneration
            initialSegment = snapshot.verifiedSegment
            initialFingerprint = snapshot.freshnessToken.fingerprint
        case .authoritativeEmpty(_, let freshnessToken):
            initialCoverageGeneration = 0
            initialSegment = nil
            initialFingerprint = freshnessToken.fingerprint
        case .skeleton, .retryableFailure, .none:
            return
        }
        guard conversation.owner == owner,
              let connection,
              primaryID.isNotEmpty,
              let ownershipIntent = replacementIntentByConversation[conversation],
              let presentationIntent = latestIntentByConversation[conversation] else {
            return
        }
        let latestProjectionIntent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            // A live receipt proves the newly persisted edge, not a new
            // 80-message presentation window. Re-projecting the full latest
            // page here made every receipt unexpectedly materialize old rows
            // and move the viewport away from the composer.
            contextBefore: 1,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: connection.generation,
            queryID: "archive.engine.live.\(primaryID)"
        )
        do {
            if let snapshot = try await repository.extendLiveEdge(
                for: latestProjectionIntent,
                primaryID: primaryID,
                freshnessToken: freshnessToken
            ), snapshot.target == .latest,
               snapshot.messagePrimaryIDs.contains(primaryID),
               snapshot.verifiedSegment.isVerified,
               snapshot.verifiedSegment.reachesLiveEdge,
               snapshot.verifiedSegment.fingerprint == freshnessToken.fingerprint,
               snapshot.freshnessToken.fingerprint == freshnessToken.fingerprint,
               snapshot.coverageGeneration >= initialCoverageGeneration,
               initialSegment.map({
                   snapshot.verifiedSegment.oldest <= $0.oldest &&
                       snapshot.verifiedSegment.newest >= $0.newest
               }) ?? true,
               self.connection?.generation == connection.generation,
               hasPresentationDemand(for: conversation),
               replacementIntentByConversation[conversation]?
                .semanticDescriptor == ownershipIntent.semanticDescriptor,
               latestIntentByConversation[conversation]?
                .semanticDescriptor == presentationIntent.semanticDescriptor,
               liveEdgeSnapshot(
                    snapshot,
                    canAdvanceCurrentStateFor: conversation,
                    fingerprint: initialFingerprint
               ) {
                publishLiveEdgeAdmission(
                    ArchiveLiveEdgeAdmission(
                        conversation: conversation,
                        primaryID: primaryID,
                        latestWindow: snapshot,
                        presentationIntent: presentationIntent.semanticDescriptor
                    ),
                    for: conversation
                )
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
            active.requestIDs.insert(intent.id)
            activeByDescriptor[descriptor] = active
            guard intent.priority > active.intent.priority else { return }
            let previousPriority = active.intent.priority
            active.intent = intent
            activeByDescriptor[descriptor] = active
            if intent.priority >= .target ||
                (intent.priority == .visibleIntegrity &&
                    previousPriority == .nearEdgePrefetch),
               !preservesVerifiedPresentation(for: intent) {
                publish(
                    .skeleton(reason: .boundaryGap, target: intent.locator),
                    for: intent.conversation
                )
            }
            if let connectionGeneration = connection?.generation {
                Task {
                    await transport.promote(
                        descriptor: descriptor,
                        connectionGeneration: connectionGeneration,
                        to: intent.priority
                    )
                }
            }
            return
        }
        if !preservesVerifiedPresentation(for: intent) {
            publish(
                .skeleton(reason: skeletonReason, target: intent.locator),
                for: intent.conversation
            )
        }
        let execution = ActiveExecution(
            id: UUID(),
            intent: intent,
            requestIDs: [intent.id]
        )
        activeByDescriptor[descriptor] = execution
        publishActivity(for: intent.conversation)
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
        var admissionFailureCount = 0
        while isCurrent(
            executionID,
            descriptor: descriptor,
            generation: connection.generation
        ) {
            guard isCurrentPresentation(
                executionID,
                descriptor: descriptor,
                intent: intent,
                generation: connection.generation
            ) else {
                finish(executionID, descriptor: descriptor)
                return
            }
            do {
                _ = try await admissionProvider.admit(
                    intent.conversation,
                    connectionGeneration: connection.generation
                )
                break
            } catch {
                guard isCurrentPresentation(
                    executionID,
                    descriptor: descriptor,
                    intent: intent,
                    generation: connection.generation
                ) else {
                    finish(executionID, descriptor: descriptor)
                    return
                }
                admissionFailureCount += 1
                let retryable = isRetryable(error)
                ArchiveEngineObservability.event(
                    .retry,
                    value: admissionFailureCount,
                    auxiliary: retryable ? 1 : 0
                )
                guard retryable,
                      admissionFailureCount <= retryDelays.count else {
                    if isCurrentPresentation(
                        executionID,
                        descriptor: descriptor,
                        intent: intent,
                        generation: connection.generation
                    ) {
                        let terminalFailure = ArchiveRetryableFailure(
                            message: String(describing: error),
                            retryCount: admissionFailureCount,
                            canRetry: retryable,
                            recoveryAction: recoveryAction(for: error)
                        )
                        retainAutomaticRetryOwnership(
                            for: intent,
                            descriptor: descriptor,
                            failedExecutionID: executionID,
                            connectionGeneration: connection.generation,
                            failure: terminalFailure
                        )
                        if !preservesVerifiedPresentation(for: intent) {
                            publish(
                                .retryableFailure(
                                    terminalFailure,
                                    target: intent.locator
                                ),
                                for: intent.conversation
                            )
                        }
                        finish(
                            executionID,
                            descriptor: descriptor,
                            result: .failed(terminalFailure)
                        )
                    }
                    return
                }
                let upperBound = retryDelays[admissionFailureCount - 1]
                await retryClock.sleep(retryClock.jitter(upperBound))
            }
        }
        guard isCurrentPresentation(
            executionID,
            descriptor: descriptor,
            intent: intent,
            generation: connection.generation
        ) else {
            finish(executionID, descriptor: descriptor)
            return
        }
        let admissionToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: connection.generation,
            queryID: "archive.engine.admission.\(connection.generation)"
        )
        do {
            if let admission = try await repository.verifiedAdmission(
                for: intent,
                freshnessToken: admissionToken
            ), isCurrentPresentation(
                executionID,
                descriptor: descriptor,
                intent: intent,
                generation: connection.generation
            ) {
                switch admission {
                case .verified(let snapshot):
                    publish(.verified(snapshot), for: intent.conversation)
                case .authoritativeEmpty:
                    publish(
                        .authoritativeEmpty(
                            target: intent.locator,
                            freshnessToken: admissionToken
                        ),
                        for: intent.conversation
                    )
                }
                finish(
                    executionID,
                    descriptor: descriptor,
                    result: .succeeded
                )
                return
            }
        } catch {
            // Without a current-session admission the transport request is
            // still the only proof that may make the window visible.
        }

        var failureCount = 0
        var nextGapBoundary: ArchiveCursor?
        var consumedOnlyContinuationBoundary: ArchiveCursor?
        var consumedOnlyContinuationBoundaries = Set<ArchiveCursor>()
        while isCurrentPresentation(
            executionID,
            descriptor: descriptor,
            intent: intent,
            generation: connection.generation
        ) {
            let queryID = "archive.engine.\(UUID().uuidString)"
            let proofFingerprint = "session:\(connection.generation)"
            let requestIntent: ArchiveWindowIntent
            if let consumedOnlyContinuationBoundary {
                requestIntent = ArchiveWindowIntent(
                    id: intent.id,
                    conversation: intent.conversation,
                    locator: .older(before: consumedOnlyContinuationBoundary),
                    contextBefore: intent.contextBefore,
                    contextAfter: intent.contextAfter,
                    priority: intent.priority
                )
            } else if case .gap(let olderBoundary, let originalNewerBoundary) = intent.locator,
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
            let freshnessToken = ArchiveFreshnessToken.sessionMAM(
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
                let ownsPresentation = isCurrentPresentation(
                    executionID,
                    descriptor: descriptor,
                    intent: intent,
                    generation: connection.generation
                )
                switch commit {
                case .verified(let snapshot):
                    let continuesConsumedOnlyLatest: Bool
                    if case .latest = intent.locator,
                       intent.priority >= .target,
                       page.deliveredResultCount > 0,
                       page.intentionallyConsumedResultCount == page.deliveredResultCount,
                       page.messagePrimaryIDs.isEmpty,
                       snapshot.messagePrimaryIDs.isEmpty,
                       !page.requestComplete,
                       snapshot.verifiedSegment.isVerified,
                       snapshot.verifiedSegment.fingerprint == proofFingerprint,
                       snapshot.verifiedSegment.reachesLiveEdge,
                       !snapshot.verifiedSegment.reachesArchiveStart {
                        let nextBoundary = snapshot.verifiedSegment.oldest
                        if case .older(let previousBoundary) = request.locator,
                           nextBoundary >= previousBoundary {
                            throw ArchiveTransportValidationError.nonAdvancingCursor
                        }
                        guard consumedOnlyContinuationBoundaries.insert(nextBoundary).inserted else {
                            throw ArchiveTransportValidationError.nonAdvancingCursor
                        }
                        consumedOnlyContinuationBoundary = nextBoundary
                        continuesConsumedOnlyLatest = true
                    } else {
                        continuesConsumedOnlyLatest = false
                    }
                    if continuesConsumedOnlyLatest {
                        guard ownsPresentation else {
                            finish(executionID, descriptor: descriptor)
                            return
                        }
                        failureCount = 0
                        continue
                    }
                    if ownsPresentation {
                        let retargeted = retarget(snapshot, to: intent.locator)
                        publish(.verified(retargeted), for: intent.conversation)
                    }
                    if ownsPresentation,
                       intent.priority == .nearEdgePrefetch {
                        ArchiveEngineObservability.event(.prefetchResult, value: 1)
                    }
                case .authoritativeEmpty:
                    if ownsPresentation {
                        publish(
                            .authoritativeEmpty(
                                target: intent.locator,
                                freshnessToken: freshnessToken
                            ),
                            for: intent.conversation
                        )
                    }
                case .materializedWithoutCoverage:
                    guard ownsPresentation else {
                        finish(executionID, descriptor: descriptor)
                        return
                    }
                    let snapshot = try await verifyMaterializedTargetWindow(
                        intent: intent,
                        exactPage: page,
                        connection: connection,
                        proofFingerprint: proofFingerprint,
                        freshnessToken: freshnessToken,
                        executionID: executionID,
                        descriptor: descriptor
                    )
                    guard isCurrentPresentation(
                        executionID,
                        descriptor: descriptor,
                        intent: intent,
                        generation: connection.generation
                    ) else {
                        finish(executionID, descriptor: descriptor)
                        return
                    }
                    publish(.verified(snapshot), for: intent.conversation)
                case .coverageAdvanced(let boundary):
                    guard ownsPresentation else {
                        finish(executionID, descriptor: descriptor)
                        return
                    }
                    guard case .gap(let olderBoundary, let newerBoundary) = request.locator,
                          boundary > olderBoundary,
                          boundary < newerBoundary else {
                        throw ArchiveTransportError.malformedCursor
                    }
                    nextGapBoundary = boundary
                    failureCount = 0
                    continue
                }
                finish(
                    executionID,
                    descriptor: descriptor,
                    result: ownsPresentation ? .succeeded : .cancelled
                )
                return
            } catch {
                guard isCurrentPresentation(
                    executionID,
                    descriptor: descriptor,
                    intent: intent,
                    generation: connection.generation
                ) else {
                    finish(executionID, descriptor: descriptor)
                    return
                }
                failureCount += 1
                let retryable = isRetryable(error)
                ArchiveEngineObservability.event(
                    .retry,
                    value: failureCount,
                    auxiliary: retryable ? 1 : 0
                )
                guard retryable, failureCount <= retryDelays.count else {
                    if isCurrentPresentation(
                        executionID,
                        descriptor: descriptor,
                        intent: intent,
                        generation: connection.generation
                    ) {
                        let terminalFailure = ArchiveRetryableFailure(
                            message: String(describing: error),
                            retryCount: failureCount,
                            canRetry: retryable,
                            recoveryAction: recoveryAction(for: error)
                        )
                        retainAutomaticRetryOwnership(
                            for: intent,
                            descriptor: descriptor,
                            failedExecutionID: executionID,
                            connectionGeneration: connection.generation,
                            failure: terminalFailure
                        )
                        if !preservesVerifiedPresentation(for: intent) {
                            publish(
                                .retryableFailure(
                                    terminalFailure,
                                    target: intent.locator
                                ),
                                for: intent.conversation
                            )
                        }
                        if intent.priority == .nearEdgePrefetch {
                            ArchiveEngineObservability.event(.prefetchResult, value: 0)
                        }
                        finish(
                            executionID,
                            descriptor: descriptor,
                            result: .failed(terminalFailure)
                        )
                    }
                    return
                }
                let upperBound = retryDelays[failureCount - 1]
                await retryClock.sleep(retryClock.jitter(upperBound))
            }
        }
        finish(executionID, descriptor: descriptor)
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
        guard isCurrentPresentation(
            executionID,
            descriptor: descriptor,
            intent: intent,
            generation: connection.generation
        ) else {
            throw ArchiveTransportError.disconnected
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
        guard isCurrentPresentation(
            executionID,
            descriptor: descriptor,
            intent: intent,
            generation: connection.generation
        ) else {
            _ = try? await repository.commit(
                olderPage,
                request: olderRequest,
                freshnessToken: freshnessToken
            )
            throw ArchiveTransportError.disconnected
        }

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

    @discardableResult
    private func startSearchPage(for scope: ArchiveSearchScope) -> Bool {
        guard let connection,
              var execution = searchExecutions[scope],
              !execution.isLoading,
              !execution.isComplete else {
            return false
        }
        execution.isLoading = true
        execution.requestAttempt += 1
        searchExecutions[scope] = execution
        publishSearch(
            .loading(searchSnapshot(execution)),
            for: scope
        )
        let generation = execution.generation
        let connectionGeneration = connection.generation
        Task { [weak self] in
            await self?.executeSearchPage(
                scope: scope,
                generation: generation,
                connectionGeneration: connectionGeneration
            )
        }
        return true
    }

    private func executeSearchPage(
        scope: ArchiveSearchScope,
        generation: UInt64,
        connectionGeneration: UInt64
    ) async {
        guard currentSearchExecution(
            scope: scope,
            generation: generation,
            connectionGeneration: connectionGeneration
        ) != nil else {
            return
        }
        do {
            if let conversation = scope.conversation {
                _ = try await admissionProvider.admit(
                    conversation,
                    connectionGeneration: connectionGeneration
                )
            }
            guard let admittedExecution = currentSearchExecution(
                scope: scope,
                generation: generation,
                connectionGeneration: connectionGeneration
            ) else {
                return
            }
            let request = ArchiveSearchTransportRequest(
                queryID: "archive.engine.search.\(UUID().uuidString)",
                scope: scope,
                query: admittedExecution.query,
                connectionGeneration: connectionGeneration,
                pageCursor: admittedExecution.nextCursor,
                pageSize: ArchivePageSizing.search
            )
            let receipt = try await transport.searchPage(
                request,
                priority: .searchCurrentPage
            )
            let page = try ArchiveSearchTransportReceiptValidator.validate(
                receipt,
                for: request
            )
            guard var current = currentSearchExecution(
                scope: scope,
                generation: generation,
                connectionGeneration: connectionGeneration
            ) else {
                return
            }

            let requestCursorKey = request.pageCursor ?? ""
            if let continuation = page.continuationCursor,
               current.cursorStack.contains(continuation) ||
                continuation == requestCursorKey {
                throw ArchiveTransportValidationError.nonAdvancingCursor
            }
            if !current.cursorStack.contains(requestCursorKey) {
                current.cursorStack.append(requestCursorKey)
            }
            current.loadedPageCount += 1
            current.residentPages.append(
                ArchiveSearchPage(
                    index: current.loadedPageCount - 1,
                    requestCursor: request.pageCursor,
                    continuationCursor: page.continuationCursor,
                    messages: page.messages,
                    isComplete: page.isComplete
                )
            )
            if current.residentPages.count > 3 {
                current.residentPages.removeFirst(
                    current.residentPages.count - 3
                )
            }
            current.nextCursor = page.continuationCursor
            current.isComplete = page.isComplete
            current.isLoading = false
            searchExecutions[scope] = current
            ArchiveEngineObservability.event(
                .searchPage,
                value: page.messages.count,
                auxiliary: current.loadedPageCount
            )
            publishSearch(
                .results(searchSnapshot(current)),
                for: scope
            )
        } catch {
            guard var current = currentSearchExecution(
                scope: scope,
                generation: generation,
                connectionGeneration: connectionGeneration
            ) else {
                return
            }
            current.isLoading = false
            if !isRetryable(error) {
                current.isComplete = true
            }
            searchExecutions[scope] = current
            publishSearchFailure(current, error: error)
        }
    }

    private func currentSearchExecution(
        scope: ArchiveSearchScope,
        generation: UInt64,
        connectionGeneration: UInt64
    ) -> SearchExecution? {
        guard connection?.generation == connectionGeneration,
              let execution = searchExecutions[scope],
              execution.generation == generation else {
            return nil
        }
        return execution
    }

    private func searchSnapshot(
        _ execution: SearchExecution
    ) -> ArchiveSearchSnapshot {
        ArchiveSearchSnapshot(
            clientQueryID: execution.clientQueryID,
            generation: execution.generation,
            query: execution.query,
            residentPages: execution.residentPages,
            cursorStack: execution.cursorStack,
            requestAttempt: execution.requestAttempt,
            continuationCursor: execution.nextCursor,
            isComplete: execution.isComplete,
            isLoading: execution.isLoading
        )
    }

    private func publishSearchFailure(
        _ execution: SearchExecution,
        error: Error
    ) {
        publishSearch(
            .retryableFailure(
                searchSnapshot(execution),
                ArchiveSearchFailure(
                    message: String(describing: error),
                    canRetry: isRetryable(error)
                )
            ),
            for: execution.scope
        )
    }

    private func publishSearch(
        _ state: ArchiveSearchState,
        for scope: ArchiveSearchScope
    ) {
        searchStates[scope] = state
        searchContinuations[scope]?.values.forEach { $0.yield(state) }
    }

    private func removeSearchContinuation(
        _ token: UUID,
        for scope: ArchiveSearchScope
    ) {
        searchContinuations[scope]?.removeValue(forKey: token)
        if searchContinuations[scope]?.isEmpty == true {
            searchContinuations.removeValue(forKey: scope)
        }
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
        if let admissionRetryDecision =
            ArchiveAdmissionRetryPolicy.retryDecision(for: error) {
            return admissionRetryDecision
        }
        if let transportError = error as? ArchiveTransportError {
            return transportError.isRetryable
        }
        if error is ArchiveTransportValidationError {
            return false
        }
        return true
    }

    private func recoveryAction(
        for error: Error
    ) -> ArchiveFailureRecoveryAction {
        if let transportError = error as? ArchiveTransportError,
           transportError == .authentication {
            return .recoverAccount
        }
        return .retry
    }

    private func acceptConnectionTransition(
        sequence: UInt64?,
        state: ConnectionTransitionState
    ) -> Bool {
        // Account supplies source-order sequences. The nil path preserves the
        // direct test API and orders those calls at actor admission.
        let latestSequence = latestConnectionTransition?.sequence ?? 0
        let candidate = sequence ?? (latestSequence &+ 1)
        guard candidate > latestSequence else { return false }
        latestConnectionTransition = ConnectionTransition(
            sequence: candidate,
            state: state
        )
        return true
    }

    private func rememberReplacementIntent(for intent: ArchiveWindowIntent) {
        switch intent.locator {
        case .latest, .firstUnread, .archiveID, .timestamp:
            replacementIntentByConversation[intent.conversation] = intent
        case .older, .newer, .gap:
            guard replacementIntentByConversation[intent.conversation] == nil else {
                return
            }
            replacementIntentByConversation[intent.conversation] =
                failClosedReplacementIntent(for: intent)
        }
    }

    private func replaceDirectionalIntentsForFreshConnection() {
        for conversation in Array(latestIntentByConversation.keys) {
            guard let current = latestIntentByConversation[conversation] else {
                continue
            }
            let replacement = replacementIntentByConversation[conversation] ??
                failClosedReplacementIntent(for: current)
            replacementIntentByConversation[conversation] = replacement
            latestIntentByConversation[conversation] = replacement
        }
    }

    private func failClosedReplacementIntent(
        for intent: ArchiveWindowIntent
    ) -> ArchiveWindowIntent {
        ArchiveWindowIntent(
            conversation: intent.conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
    }

    private func preservesVerifiedPresentation(for intent: ArchiveWindowIntent) -> Bool {
        guard case .verified = states[intent.conversation] else {
            return false
        }
        switch intent.locator {
        case .older, .newer, .gap:
            return true
        case .latest, .firstUnread, .archiveID, .timestamp:
            return false
        }
    }

    private func isCurrent(
        _ executionID: UUID,
        descriptor: ArchiveIntentDescriptor,
        generation: UInt64
    ) -> Bool {
        connection?.generation == generation &&
            activeByDescriptor[descriptor]?.id == executionID
    }

    private func retainAutomaticRetryOwnership(
        for intent: ArchiveWindowIntent,
        descriptor: ArchiveIntentDescriptor,
        failedExecutionID: UUID,
        connectionGeneration: UInt64,
        failure: ArchiveRetryableFailure
    ) {
        guard failure.recoveryAction == .retry,
              isCurrent(
                failedExecutionID,
                descriptor: descriptor,
                generation: connectionGeneration
              ),
              hasPresentationDemand(for: intent.conversation),
              latestIntentByConversation[intent.conversation]?
                .semanticDescriptor == descriptor else {
            return
        }
        automaticRetryOwnershipByConversation[intent.conversation] =
            AutomaticRetryOwnership(
                descriptor: descriptor,
                failedExecutionID: failedExecutionID,
                connectionGeneration: connectionGeneration
            )
    }

    private func hasPresentationDemand(
        for conversation: ArchiveConversationKey
    ) -> Bool {
        presentationDemandIDs[conversation]?.isEmpty == false
    }

    private func isCurrentPresentation(
        _ executionID: UUID,
        descriptor: ArchiveIntentDescriptor,
        intent: ArchiveWindowIntent,
        generation: UInt64
    ) -> Bool {
        isCurrent(
            executionID,
            descriptor: descriptor,
            generation: generation
        ) &&
            hasPresentationDemand(for: intent.conversation) &&
            latestIntentByConversation[intent.conversation]?
                .semanticDescriptor == descriptor
    }

    private func finish(
        _ executionID: UUID,
        descriptor: ArchiveIntentDescriptor,
        result: ArchiveBoundaryTerminalResult = .cancelled
    ) {
        guard let execution = activeByDescriptor[descriptor],
              execution.id == executionID else { return }
        publishBoundaryTerminal(
            result,
            descriptor: descriptor,
            execution: execution
        )
        activeByDescriptor.removeValue(forKey: descriptor)
        publishActivity(for: execution.intent.conversation)
    }

    private func cancelAllActiveExecutions() -> Set<ArchiveConversationKey> {
        let executions = activeByDescriptor
        activeByDescriptor.removeAll(keepingCapacity: true)
        for (descriptor, execution) in executions {
            publishBoundaryTerminal(
                .cancelled,
                descriptor: descriptor,
                execution: execution
            )
        }
        return Set(executions.values.map(\.intent.conversation))
    }

    private func publishBoundaryTerminal(
        _ result: ArchiveBoundaryTerminalResult,
        descriptor: ArchiveIntentDescriptor,
        execution: ActiveExecution
    ) {
        switch descriptor.locator {
        case .older, .newer, .gap:
            break
        case .latest, .firstUnread, .archiveID, .timestamp:
            return
        }
        let conversation = descriptor.conversation
        for requestID in execution.requestIDs {
            let outcome = ArchiveBoundaryTerminalOutcome(
                requestID: requestID,
                descriptor: descriptor,
                result: result
            )
            boundaryTerminalContinuations[conversation]?.values.forEach {
                $0.yield(outcome)
            }
        }
    }

    private func publish(
        _ state: ArchiveWindowState,
        for conversation: ArchiveConversationKey
    ) {
        guard hasPresentationDemand(for: conversation) else { return }
        if case .verified(let snapshot) = state {
            removePendingLocalOutgoingAdmissions(
                primaryIDs: Set(snapshot.messagePrimaryIDs),
                for: conversation
            )
        }
        states[conversation] = state
        continuations[conversation]?.values.forEach { $0.yield(state) }
    }

    private func publishLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission,
        for conversation: ArchiveConversationKey
    ) {
        guard hasPresentationDemand(for: conversation) else { return }
        removePendingLocalOutgoingAdmissions(
            primaryIDs: Set([admission.primaryID]),
            for: conversation
        )
        currentLiveEdgeAdmissions[conversation] = admission
        liveEdgeContinuations[conversation]?.values.forEach {
            $0.yield(admission)
        }
    }

    private func liveEdgeSnapshot(
        _ snapshot: ArchiveWindowSnapshot,
        canAdvanceCurrentStateFor conversation: ArchiveConversationKey,
        fingerprint: String
    ) -> Bool {
        switch states[conversation] {
        case .verified(let current):
            return current.verifiedSegment.reachesLiveEdge &&
                current.freshnessToken.fingerprint == fingerprint &&
                snapshot.freshnessToken.fingerprint == fingerprint &&
                snapshot.coverageGeneration >= current.coverageGeneration &&
                snapshot.verifiedSegment.oldest <= current.verifiedSegment.oldest &&
                snapshot.verifiedSegment.newest >= current.verifiedSegment.newest
        case .authoritativeEmpty(_, let freshnessToken):
            return freshnessToken.fingerprint == fingerprint &&
                snapshot.freshnessToken.fingerprint == fingerprint
        case .skeleton, .retryableFailure, .none:
            return false
        }
    }

    private func removeContinuation(_ token: UUID, for conversation: ArchiveConversationKey) {
        continuations[conversation]?.removeValue(forKey: token)
        if continuations[conversation]?.isEmpty == true {
            continuations.removeValue(forKey: conversation)
        }
    }

    private func removeLiveEdgeContinuation(
        _ token: UUID,
        for conversation: ArchiveConversationKey
    ) {
        liveEdgeContinuations[conversation]?.removeValue(forKey: token)
        if liveEdgeContinuations[conversation]?.isEmpty == true {
            liveEdgeContinuations.removeValue(forKey: conversation)
        }
    }

    private func removeLocalOutgoingContinuation(
        _ token: UUID,
        for conversation: ArchiveConversationKey
    ) {
        localOutgoingContinuations[conversation]?.removeValue(forKey: token)
        if localOutgoingContinuations[conversation]?.isEmpty == true {
            localOutgoingContinuations.removeValue(forKey: conversation)
        }
    }

    private func removePendingLocalOutgoingAdmissions(
        primaryIDs: Set<String>,
        for conversation: ArchiveConversationKey
    ) {
        guard !primaryIDs.isEmpty,
              var pending = pendingLocalOutgoingAdmissions[conversation] else {
            return
        }
        pending.removeAll { primaryIDs.contains($0.primaryID) }
        if pending.isEmpty {
            pendingLocalOutgoingAdmissions.removeValue(forKey: conversation)
        } else {
            pendingLocalOutgoingAdmissions[conversation] = pending
        }
    }

    private func removeBoundaryTerminalContinuation(
        _ token: UUID,
        for conversation: ArchiveConversationKey
    ) {
        boundaryTerminalContinuations[conversation]?.removeValue(
            forKey: token
        )
        if boundaryTerminalContinuations[conversation]?.isEmpty == true {
            boundaryTerminalContinuations.removeValue(forKey: conversation)
        }
    }

    private func publishActivity(for conversation: ArchiveConversationKey) {
        let count = activeByDescriptor.values.reduce(into: 0) { count, execution in
            guard execution.intent.conversation == conversation,
                  hasPresentationDemand(for: conversation),
                  latestIntentByConversation[conversation]?.semanticDescriptor ==
                    execution.intent.semanticDescriptor else {
                return
            }
            switch execution.intent.locator {
            case .older, .newer, .gap:
                count += 1
            case .latest, .firstUnread, .archiveID, .timestamp:
                break
            }
        }
        let activity = ArchiveWindowActivity(activeBoundaryRequestCount: count)
        activities[conversation] = activity
        activityContinuations[conversation]?.values.forEach { $0.yield(activity) }
    }

    private func removeActivityContinuation(
        _ token: UUID,
        for conversation: ArchiveConversationKey
    ) {
        activityContinuations[conversation]?.removeValue(forKey: token)
        if activityContinuations[conversation]?.isEmpty == true {
            activityContinuations.removeValue(forKey: conversation)
        }
    }

#if DEBUG
    func waitUntilIdleForTesting() async {
        for _ in 0..<2_000 {
            if activeByDescriptor.isEmpty,
               !searchExecutions.values.contains(where: \.isLoading) {
                return
            }
            await Task.yield()
        }
    }
#endif
}
