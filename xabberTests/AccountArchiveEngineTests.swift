import XCTest
@testable import xabber

final class AccountArchiveEngineTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testLocalOutgoingAdmissionsReplayRowsPublishedBeforeSubscription()
        async {
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: ArchiveEngineTransportSpy(),
            retryClock: .immediate
        )
        let expected = (1...3).map { index in
            ChatTimelineLocalOutgoingAdmission(
                conversation: conversation,
                primaryID: "local-\(index)"
            )
        }
        for admission in expected {
            await engine.localOutgoingDidPersist(admission)
        }

        let replayed = expectation(description: "pending local rows replayed")
        let consumer = Task { () -> [ChatTimelineLocalOutgoingAdmission] in
            let stream = await engine.localOutgoingAdmissions(
                for: conversation
            )
            var values: [ChatTimelineLocalOutgoingAdmission] = []
            for await admission in stream {
                values.append(admission)
                if values.count == expected.count {
                    replayed.fulfill()
                    return values
                }
            }
            return values
        }

        await fulfillment(of: [replayed], timeout: 1)
        consumer.cancel()
        let values = await consumer.value
        XCTAssertEqual(values, expected)
    }

    func testGroupAdmissionRetryPolicyRetriesOnlyTransientTransportFailures() {
        XCTAssertTrue(
            ArchiveAdmissionRetryPolicy.isRetryable(GroupRequestError.timeout)
        )
        XCTAssertTrue(
            ArchiveAdmissionRetryPolicy.isRetryable(GroupRequestError.disconnected)
        )
        XCTAssertTrue(
            ArchiveAdmissionRetryPolicy.isRetryable(GroupchatServiceError.notPrepared)
        )
        XCTAssertTrue(
            ArchiveAdmissionRetryPolicy.isRetryable(
                GroupchatServiceError.iq(
                    GroupIQStanzaError(
                        type: "wait",
                        condition: "service-unavailable",
                        text: nil,
                        payload: nil
                    )
                )
            )
        )
    }

    func testGroupAdmissionRetryPolicyRejectsAuthProtocolAndStorageValidationFailures() {
        [
            "forbidden",
            "not-authorized",
            "bad-request",
            "item-not-found"
        ].forEach { condition in
            XCTAssertFalse(
                ArchiveAdmissionRetryPolicy.isRetryable(
                    GroupchatServiceError.iq(
                        GroupIQStanzaError(
                            type: "cancel",
                            condition: condition,
                            text: nil,
                            payload: nil
                        )
                    )
                ),
                "\(condition) must not run seven automatic admission retries"
            )
        }
        XCTAssertFalse(
            ArchiveAdmissionRetryPolicy.isRetryable(
                GroupchatServiceError.invalidJID("not a jid")
            )
        )
        XCTAssertFalse(
            ArchiveAdmissionRetryPolicy.isRetryable(
                GroupRepositoryError.groupJIDMismatch(
                    expected: "group@example.org",
                    received: "other@example.org"
                )
            )
        )
        XCTAssertFalse(
            ArchiveAdmissionRetryPolicy.isRetryable(
                GroupRequestError.duplicateRequestID("duplicate")
            )
        )
    }

    func testOfflineOpenAlwaysPublishesFullSkeletonEvenWithCachedSnapshot() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(sessionGeneration: 1))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        let intent = latestIntent(priority: .visibleIntegrity)
        await submit(engine, intent)

        let state = await engine.currentState(for: conversation)
        let requestCount = await transport.requestCount
        XCTAssertEqual(state, .skeleton(reason: .offline, target: .latest))
        XCTAssertEqual(requestCount, 0)
    }

    func testWindowSubmitWithoutPresentationDemandDoesNotCreateReconnectWork() async {
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 2)

        await engine.submit(latestIntent(priority: .visibleIntegrity))
        for _ in 0..<100 { await Task.yield() }

        let requestCount = await transport.requestCount
        let state = await engine.currentState(for: conversation)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(state)
    }

    func testPreviousSessionCoverageDoesNotAdmitWithoutCurrentSessionMAMProof() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(sessionGeneration: 2))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(generation: 3)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        guard case .authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(let generation, _)
        ) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected a current-session MAM terminal")
        }
        XCTAssertEqual(generation, 3)
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(generation: 4)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
        guard case .authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(let generation, _)
        ) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected current-session MAM proof")
        }
        XCTAssertEqual(generation, 4)

        await engine.connectionDidBecomeReady(generation: 4)
        await engine.waitUntilIdleForTesting()
        let readyRequestCount = await transport.requestCount
        XCTAssertEqual(readyRequestCount, 1)
    }

    func testSubmitDuringAdmissionReadinessWaitStartsExactlyOneCurrentRequest() async {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        let admission = ArchiveEngineAdmissionSpy()
        await admission.suspendReadiness()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )
        let readiness = Task {
            await engine.connectionDidBecomeReady(generation: 43)
        }
        let readinessStarted = await waitForReadiness(
            1,
            admission: admission
        )
        XCTAssertTrue(readinessStarted)

        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let requestsWhileRebinding = await transport.requestCount
        XCTAssertEqual(requestsWhileRebinding, 0)

        await admission.resumeReadiness()
        await readiness.value
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(
            requestCount,
            1,
            "A submit racing transport rebind must queue, not start and then restart"
        )
    }

    func testStaleDisconnectCannotClearNewerReadyWhileAdmissionRebindSuspends() async {
        let transport = ArchiveEngineTransportSpy()
        let admission = ArchiveEngineAdmissionSpy()
        await admission.suspendReadiness()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )
        let readiness = Task {
            await engine.connectionDidBecomeReady(
                generation: 45,
                transitionSequence: 2
            )
        }
        let readinessStarted = await waitForReadiness(
            1,
            admission: admission
        )
        XCTAssertTrue(readinessStarted)

        await engine.connectionDidDisconnect(transitionSequence: 1)
        let disconnectCount = await admission.disconnectCount
        XCTAssertEqual(
            disconnectCount,
            0,
            "An older bridge task must be rejected before it reaches admission"
        )

        await admission.resumeReadiness()
        await readiness.value
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
        guard case .authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(let generation, _)
        ) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected the newer ready transition to remain active")
        }
        XCTAssertEqual(generation, 45)
    }

    func testRepeatedReadinessForSameGenerationKeepsActiveLatestAndAcceptsItsReceipt() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        await transport.suspendRequests()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(generation: 44)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let didStartRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(
            didStartRequest,
            "The session-only latest request must become active"
        )

        await engine.connectionDidBecomeReady(generation: 44)
        for _ in 0..<100 { await Task.yield() }
        let requestCountAfterRepeatedReadiness = await transport.requestCount
        XCTAssertEqual(requestCountAfterRepeatedReadiness, 1)
        let stateAfterRepeatedReadiness = await engine.currentState(for: conversation)
        XCTAssertEqual(
            stateAfterRepeatedReadiness,
            .skeleton(reason: .unverifiedCoverage, target: .latest),
            "Repeated readiness must not invalidate the active semantic-identical window"
        )

        await transport.resumeRequests(
            with: ArchiveTransportReceipt(
                queryID: "placeholder",
                connectionGeneration: 44,
                resultArchiveIDs: ["100"],
                messagePrimaryIDs: ["p100"],
                first: "100",
                last: "100",
                complete: true,
                cheapPageCount: 1,
                deliveredResultCount: 1,
                persistedResultCount: 1,
                intentionallyConsumedResultCount: 0,
                failedPersistenceCount: 0,
                finalReceived: true
            )
        )
        await engine.waitUntilIdleForTesting()

        guard case .verified(let snapshot) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected the original session request to reach verified terminal")
        }
        guard case .sessionMAM(let generation, _) = snapshot.freshnessToken else {
            return XCTFail("The active request must retain its session proof")
        }
        XCTAssertEqual(generation, 44)
        let terminalRequestCount = await transport.requestCount
        XCTAssertEqual(terminalRequestCount, 1)
        let committedTokens = await repository.committedFreshnessTokens
        XCTAssertEqual(committedTokens.count, 1)
        guard case .sessionMAM(let committedGeneration, _) = committedTokens[0] else {
            return XCTFail("Persistence commit must retain the original session proof")
        }
        XCTAssertEqual(committedGeneration, 44)
    }

    func testDuplicateSemanticIntentsJoinOneTransportAndPromotePriority() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        await transport.suspendRequests()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 5)

        await submit(engine, latestIntent(priority: .nearEdgePrefetch))
        let didStartPrefetch = await waitForRequests(1, transport: transport)
        XCTAssertTrue(
            didStartPrefetch,
            "The prefetch must already own the transport before the visible intent joins it"
        )
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let didPromoteActiveRequest = await waitForPromotions(
            1,
            transport: transport
        )
        XCTAssertTrue(
            didPromoteActiveRequest,
            "The semantic-identical visible intent must promote the active request"
        )
        await transport.resumeRequests(with: .emptyLatest(generation: 5))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        let promotedPriorities = await transport.promotedPriorities
        let promotedGenerations = await transport.promotedConnectionGenerations
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(promotedPriorities, [.visibleIntegrity])
        XCTAssertEqual(promotedGenerations, [5])
        guard case .authoritativeEmpty = await engine.currentState(for: conversation) else {
            return XCTFail("Expected authoritative empty terminal")
        }
    }

    func testDelayedAutomaticRetryDoesNotReplaceNewerSemanticExecution() async throws {
        let transport = RetryOwnershipArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 51)

        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let failurePublished = await waitForRetryableLatest(engine)
        XCTAssertTrue(failurePublished)
        let failedState = await engine.currentState(for: conversation)
        guard case .retryableFailure(_, target: .latest) =
                failedState else {
            let firstRequestCount = await transport.requestCount
            return XCTFail(
                "Expected the first execution to retain automatic retry ownership; state=\(String(describing: failedState)) requests=\(firstRequestCount)"
            )
        }

        await engine.submit(latestIntent(priority: .visibleIntegrity))
        let replacementStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(replacementStarted)

        await engine.retry(conversation: conversation)
        for _ in 0..<100 { await Task.yield() }

        let requestCountAfterDelayedRetry = await transport.requestCount
        XCTAssertEqual(
            requestCountAfterDelayedRetry,
            2,
            "A delayed callback owned by the failed execution must not cancel and duplicate its newer replacement"
        )

        await transport.resumeAll(generation: 51)
        await engine.waitUntilIdleForTesting()
        guard case .authoritativeEmpty = await engine.currentState(for: conversation) else {
            return XCTFail("Expected the newer execution to keep ownership through its terminal receipt")
        }
    }

    func testLowerPrioritySemanticRequestAfterCompletionStartsNewOwnedExecution() async {
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 52)

        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        let completedRequestCount = await transport.requestCount
        XCTAssertEqual(completedRequestCount, 1)

        await engine.submit(latestIntent(priority: .nearEdgePrefetch))
        await engine.waitUntilIdleForTesting()

        let repeatedRequestCount = await transport.requestCount
        XCTAssertEqual(
            repeatedRequestCount,
            2,
            "Once the previous execution is terminal, a lower-priority semantic request must be accepted instead of being silently dropped"
        )
    }

    func testDelayedAutomaticRetryFromPreviousConnectionGenerationIsIgnored() async {
        let transport = RetryOwnershipArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 61)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let failurePublished = await waitForRetryableLatest(engine)
        XCTAssertTrue(failurePublished)

        await engine.connectionDidDisconnect()
        await engine.connectionDidBecomeReady(generation: 62)
        let reconnectRequestStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(reconnectRequestStarted)

        await engine.retry(conversation: conversation)
        for _ in 0..<100 { await Task.yield() }

        let requestCountAfterStaleRetry = await transport.requestCount
        XCTAssertEqual(
            requestCountAfterStaleRetry,
            2,
            "A retry ticket from an older stream generation must not replace reconnect work"
        )

        await transport.resumeAll(generation: 62)
        await engine.waitUntilIdleForTesting()
    }

    func testReplacementTargetSuppressesLatePreviousPresentationButKeepsItsCoverageCommit() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ReplacementArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 72)
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let oldIntent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: boundary),
            contextBefore: 100,
            contextAfter: 0,
            priority: .target
        )
        await submit(engine, oldIntent)
        let oldRequestStarted = await transport.waitForRequestCount(1)
        XCTAssertTrue(oldRequestStarted)

        let replacement = latestIntent(priority: .target)
        await submit(engine, replacement)
        let replacementRequestStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(replacementRequestStarted)

        await transport.resume(
            locator: .latest,
            archiveIDs: [],
            primaryIDs: [],
            complete: true
        )
        let replacementFinished = await waitForAuthoritativeLatest(engine)
        XCTAssertTrue(replacementFinished)
        guard case .authoritativeEmpty(target: .latest, _) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected replacement latest target to win presentation")
        }

        await transport.resume(
            locator: .older(before: boundary),
            archiveIDs: ["50"],
            primaryIDs: ["p50"],
            complete: true
        )
        await engine.waitUntilIdleForTesting()

        guard case .authoritativeEmpty(target: .latest, _) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Late previous descriptor must not overwrite current target")
        }
        let committedTokens = await repository.committedFreshnessTokens
        XCTAssertEqual(
            committedTokens.count,
            2,
            "Already-sent superseded work must still persist and commit coverage"
        )
    }

    func testReplacementDuringAnchorContextCommitsReturnedPageWithoutStartingNextOldLeg() async throws {
        let repository = SupersededAnchorArchiveRepositorySpy()
        let transport = ReplacementArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 73)
        let targetCursor = try XCTUnwrap(ArchiveCursor(rawValue: "500"))
        let target = ArchiveWindowIntent(
            conversation: conversation,
            locator: .archiveID(targetCursor),
            contextBefore: 30,
            contextAfter: 30,
            priority: .target
        )
        await submit(engine, target)
        let exactStarted = await transport.waitForRequestCount(1)
        XCTAssertTrue(exactStarted)
        await transport.resume(
            locator: target.locator,
            archiveIDs: ["500"],
            primaryIDs: ["p500"],
            complete: true
        )
        let olderStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(olderStarted)

        await submit(engine, latestIntent(priority: .target))
        let replacementStarted = await transport.waitForRequestCount(3)
        XCTAssertTrue(replacementStarted)
        let older = ArchiveWindowLocator.older(before: targetCursor)
        await transport.resume(
            locator: older,
            archiveIDs: ["470", "499"],
            primaryIDs: ["p470", "p499"],
            complete: true
        )
        await transport.resume(
            locator: .latest,
            archiveIDs: [],
            primaryIDs: [],
            complete: true
        )
        await engine.waitUntilIdleForTesting()

        let committedLocators = await repository.committedLocators
        XCTAssertTrue(committedLocators.contains(target.locator))
        XCTAssertTrue(
            committedLocators.contains(older),
            "The already-returned context page must retain its local coverage value"
        )
        let requestedLocators = await transport.requestedLocators
        XCTAssertFalse(
            requestedLocators.contains(.newer(after: targetCursor)),
            "A superseded target must not start another context MAM"
        )
        let replacementWon = await waitForAuthoritativeLatest(engine)
        XCTAssertTrue(replacementWon)
    }

    func testTargetReplacementSuppressesSuspendedLiveEdgePublication() async throws {
        let initial = makeSnapshot(sessionGeneration: 74)
        let liveSegment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: initial.verifiedSegment.oldest,
            newest: XCTUnwrap(ArchiveCursor(rawValue: "21")),
            reachesArchiveStart: initial.verifiedSegment.reachesArchiveStart,
            reachesLiveEdge: true,
            fingerprint: initial.verifiedSegment.fingerprint,
            isVerified: true
        ))
        let live = ArchiveWindowSnapshot(
            messagePrimaryIDs: initial.messagePrimaryIDs + ["p21"],
            target: .latest,
            verifiedSegment: liveSegment,
            coverageGeneration: initial.coverageGeneration + 1,
            freshnessToken: initial.freshnessToken
        )
        let repository = SuspendingLiveEdgeArchiveRepositorySpy(
            admission: initial,
            liveSnapshot: live
        )
        let transport = ReplacementArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 74)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        await repository.suspendLiveEdge()

        let liveTask = Task {
            await engine.liveMessageDidPersist(
                conversation: conversation,
                primaryID: "p21"
            )
        }
        let liveEdgeStarted = await repository.waitForLiveEdgeRequest()
        XCTAssertTrue(liveEdgeStarted)
        let replacementCursor = try XCTUnwrap(ArchiveCursor(rawValue: "900"))
        let replacement = ArchiveWindowIntent(
            conversation: conversation,
            locator: .archiveID(replacementCursor),
            contextBefore: 30,
            contextAfter: 30,
            priority: .target
        )
        await submit(engine, replacement)
        let replacementStarted = await transport.waitForRequestCount(1)
        XCTAssertTrue(replacementStarted)

        await repository.resumeLiveEdge()
        await liveTask.value
        let staleAdmission = await engine.currentLiveEdgeAdmission(
            for: conversation
        )
        XCTAssertNil(
            staleAdmission,
            "A suspended projection must lose ownership when its target is replaced"
        )
        let state = await engine.currentState(for: conversation)
        guard case .skeleton(_, let presentedTarget) = state else {
            return XCTFail("Expected the replacement target to retain presentation ownership")
        }
        XCTAssertEqual(presentedTarget, replacement.locator)

        await engine.connectionDidDisconnect()
        await transport.resume(
            locator: replacement.locator,
            archiveIDs: [],
            primaryIDs: [],
            complete: true
        )
    }

    func testLivePersistAfterOlderPagingExtendsStableLatestWindow() async throws {
        let initial = makeSnapshot(sessionGeneration: 75)
        let liveSegment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: initial.verifiedSegment.oldest,
            newest: XCTUnwrap(ArchiveCursor(rawValue: "21")),
            reachesArchiveStart: initial.verifiedSegment.reachesArchiveStart,
            reachesLiveEdge: true,
            fingerprint: initial.verifiedSegment.fingerprint,
            isVerified: true
        ))
        let live = ArchiveWindowSnapshot(
            messagePrimaryIDs: initial.messagePrimaryIDs + ["p21"],
            target: .latest,
            verifiedSegment: liveSegment,
            coverageGeneration: initial.coverageGeneration + 1,
            freshnessToken: initial.freshnessToken
        )
        let repository = SuspendingLiveEdgeArchiveRepositorySpy(
            admission: initial,
            liveSnapshot: live
        )
        let transport = ReplacementArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 75)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let older = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: initial.verifiedSegment.oldest),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        await submit(engine, older)
        let olderStarted = await transport.waitForRequestCount(1)
        XCTAssertTrue(olderStarted)

        await engine.liveMessageDidPersist(
            conversation: conversation,
            primaryID: "p21"
        )

        let liveEdgeLocators = await repository.liveEdgeIntentLocators
        XCTAssertEqual(
            liveEdgeLocators,
            [.latest],
            "Directional paging must not narrow live-edge materialization"
        )
        let liveEdgeContextBefore = await repository.liveEdgeContextBefore
        XCTAssertEqual(
            liveEdgeContextBefore,
            [1],
            "A receipt proves one live primary; it must not rematerialize an 80-row latest window"
        )
        let currentAdmission = await engine.currentLiveEdgeAdmission(
            for: conversation
        )
        let admission = try XCTUnwrap(currentAdmission)
        XCTAssertEqual(admission.primaryID, "p21")
        XCTAssertEqual(admission.latestWindow.target, .latest)
        XCTAssertEqual(admission.presentationIntent, older.semanticDescriptor)
        XCTAssertTrue(admission.latestWindow.messagePrimaryIDs.contains("p21"))
        guard case .verified(let ordinaryState) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Live-edge admission must preserve ordinary target state")
        }
        XCTAssertEqual(ordinaryState.target, initial.target)
        XCTAssertEqual(ordinaryState.messagePrimaryIDs, initial.messagePrimaryIDs)
        XCTAssertEqual(
            ordinaryState.coverageGeneration,
            initial.coverageGeneration
        )

        await engine.connectionDidDisconnect()
        await transport.resume(
            locator: older.locator,
            archiveIDs: ["1", "9"],
            primaryIDs: ["p1", "p9"],
            complete: true
        )
    }

    func testDisconnectKeepsOfflineSkeletonWhenLateSessionReceiptArrives() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        await transport.suspendRequests()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 8)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let didStartRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(didStartRequest)

        await engine.connectionDidDisconnect()
        let disconnectedState = await engine.currentState(for: conversation)
        XCTAssertEqual(
            disconnectedState,
            .skeleton(reason: .offline, target: .latest)
        )

        await transport.resumeRequests(with: .emptyLatest(generation: 8))
        for _ in 0..<100 { await Task.yield() }
        let lateState = await engine.currentState(for: conversation)
        XCTAssertEqual(
            lateState,
            .skeleton(reason: .offline, target: .latest)
        )
    }

    func testDisconnectImmediatelyReplacesVerifiedContentWithSkeletonAndReconnectResumesIntent() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(sessionGeneration: 10))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 10)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        guard case .verified = await engine.currentState(for: conversation) else {
            return XCTFail("Expected verified before disconnect")
        }

        await engine.connectionDidDisconnect()
        let offlineState = await engine.currentState(for: conversation)
        XCTAssertEqual(offlineState, .skeleton(reason: .offline, target: .latest))

        await repository.setSnapshot(nil)
        await transport.setImmediateReceipt(.emptyLatest(generation: 11))
        await engine.connectionDidBecomeReady(generation: 11)
        await engine.waitUntilIdleForTesting()
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testReconnectReplaysStableLatestInsteadOfLastDirectionalIntent() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ReplacementArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 76)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        let initialStarted = await transport.waitForRequestCount(1)
        XCTAssertTrue(initialStarted)
        await transport.resume(
            locator: .latest,
            archiveIDs: ["10", "20"],
            primaryIDs: ["p10", "p20"],
            complete: true
        )
        await engine.waitUntilIdleForTesting()

        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        let older = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: boundary),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        await submit(engine, older)
        let olderStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(olderStarted)

        await engine.connectionDidDisconnect()
        await engine.connectionDidBecomeReady(generation: 77)
        let replacementStarted = await transport.waitForRequestCount(3)
        XCTAssertTrue(replacementStarted)
        let requestedLocators = await transport.requestedLocators
        XCTAssertEqual(
            requestedLocators,
            [.latest, older.locator, .latest],
            "A fresh session must replace, not replay, a directional boundary"
        )

        await transport.resume(
            locator: older.locator,
            archiveIDs: ["1", "9"],
            primaryIDs: ["p1", "p9"],
            complete: true
        )
        await transport.resume(
            locator: .latest,
            archiveIDs: [],
            primaryIDs: [],
            complete: true
        )
        await engine.waitUntilIdleForTesting()
        guard case .authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(let generation, _)
        ) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected a fresh latest replacement after reconnect")
        }
        XCTAssertEqual(generation, 77)
    }

    func testReconnectWithoutStableTargetFailsClosedToLatest() async throws {
        let transport = ReplacementArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 78)
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "50"))
        let older = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: boundary),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        await submit(engine, older)
        let olderStarted = await transport.waitForRequestCount(1)
        XCTAssertTrue(olderStarted)

        await engine.connectionDidDisconnect()
        let offlineState = await engine.currentState(for: conversation)
        XCTAssertEqual(
            offlineState,
            .skeleton(reason: .offline, target: .latest)
        )
        await engine.connectionDidBecomeReady(generation: 79)
        let replacementStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(replacementStarted)
        let requestedLocators = await transport.requestedLocators
        XCTAssertEqual(requestedLocators, [older.locator, .latest])

        await transport.resume(
            locator: older.locator,
            archiveIDs: ["1", "49"],
            primaryIDs: ["p1", "p49"],
            complete: true
        )
        await transport.resume(
            locator: .latest,
            archiveIDs: [],
            primaryIDs: [],
            complete: true
        )
        await engine.waitUntilIdleForTesting()
    }

    func testDetachedPresentationFinishesInFlightCommitButDoesNotRestartOnReconnect() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        await transport.suspendRequests()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        let demandID = UUID()
        await engine.attachPresentationDemand(
            for: conversation,
            demandID: demandID
        )
        await engine.connectionDidBecomeReady(generation: 90)
        await engine.submit(latestIntent(priority: .visibleIntegrity))
        let requestStarted = await waitForRequests(1, transport: transport)
        XCTAssertTrue(requestStarted)

        await engine.detachPresentationDemand(
            for: conversation,
            demandID: demandID
        )
        await transport.resumeRequests(with: .emptyLatest(generation: 90))
        await engine.waitUntilIdleForTesting()

        let detachedState = await engine.currentState(for: conversation)
        XCTAssertNil(detachedState)
        let committedTokens = await repository.committedFreshnessTokens
        XCTAssertEqual(committedTokens.count, 1)

        await engine.connectionDidDisconnect()
        await engine.connectionDidBecomeReady(generation: 91)
        for _ in 0..<100 { await Task.yield() }
        let requestCount = await transport.requestCount
        XCTAssertEqual(
            requestCount,
            1,
            "A closed controller must not leave reconnect archive demand behind"
        )
    }

    func testTransientFailureUsesSevenActorBackoffRetriesBeforePresentationAutomaticRecovery() async throws {
        let transport = FailingArchiveEngineTransport(error: .timeout)
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 11)

        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 8)
        guard case .retryableFailure(let failure, target: .latest) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected retryable failure after bounded retries")
        }
        XCTAssertEqual(failure.retryCount, 8)
        XCTAssertTrue(failure.canRetry)
        XCTAssertEqual(
            failure.recoveryAction,
            .retry,
            "The presentation layer must re-submit this semantic request automatically"
        )
    }

    func testProtocolFailurePublishesAutomaticRecoveryStateWithoutActorRetryLoop() async throws {
        let transport = FailingArchiveEngineTransport(error: .protocolViolation)
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 12)

        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
        guard case .retryableFailure(let failure, target: .latest) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected terminal protocol failure")
        }
        XCTAssertEqual(failure.retryCount, 1)
        XCTAssertFalse(failure.canRetry)
        XCTAssertEqual(
            failure.recoveryAction,
            .retry,
            "Protocol failures stop the actor loop, then presentation retries automatically without user UI"
        )
    }

    func testAuthenticationFailureOffersAccountRecoveryWithoutAutomaticRetry() async throws {
        let transport = FailingArchiveEngineTransport(error: .authentication)
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 13)

        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let promotedRequestCount = await transport.requestCount
        XCTAssertEqual(promotedRequestCount, 1)
        guard case .retryableFailure(let failure, target: .latest) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected terminal authentication failure")
        }
        XCTAssertFalse(failure.canRetry)
        XCTAssertEqual(failure.recoveryAction, .recoverAccount)
    }

    func testNearEdgePrefetchKeepsCurrentlyVerifiedWindowVisibleWhileRequestRuns() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(sessionGeneration: 12))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 12)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        guard case .verified(let current) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected verified initial window")
        }
        await repository.setSnapshot(nil)
        await transport.suspendRequests()

        let prefetch = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: current.verifiedSegment.oldest),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .nearEdgePrefetch
        )
        await submit(engine, prefetch)

        let stateWhilePrefetchRuns = await engine.currentState(for: conversation)
        XCTAssertEqual(stateWhilePrefetchRuns, .verified(current))
    }

    func testInteractiveBoundaryLoadKeepsVerifiedWindowAndPublishesActivityUntilDisconnect() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(sessionGeneration: 14))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 14)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        guard case .verified(let current) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected verified initial window")
        }
        await repository.setSnapshot(nil)
        await transport.suspendRequests()

        let boundaryIntent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: current.verifiedSegment.oldest),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        var terminals = await engine.boundaryTerminals(
            for: conversation
        ).makeAsyncIterator()
        await submit(engine, boundaryIntent)

        let stateWhileBoundaryLoads = await engine.currentState(for: conversation)
        let activityWhileBoundaryLoads = await engine.currentActivity(for: conversation)
        XCTAssertEqual(stateWhileBoundaryLoads, .verified(current))
        XCTAssertEqual(
            activityWhileBoundaryLoads,
            ArchiveWindowActivity(activeBoundaryRequestCount: 1)
        )

        await engine.connectionDidDisconnect()

        let disconnectedActivity = await engine.currentActivity(for: conversation)
        let disconnectedState = await engine.currentState(for: conversation)
        XCTAssertEqual(disconnectedActivity, .idle)
        XCTAssertEqual(
            disconnectedState,
            .skeleton(reason: .offline, target: .latest)
        )
        let receivedTerminal = await terminals.next()
        let terminal = try XCTUnwrap(receivedTerminal)
        XCTAssertEqual(terminal.requestID, boundaryIntent.id)
        XCTAssertEqual(terminal.descriptor, boundaryIntent.semanticDescriptor)
        XCTAssertEqual(terminal.result, .cancelled)
    }

    func testBoundarySubmitDoesNotEmitTransientIdleBeforeLoadingActivity() async throws {
        let transport = ArchiveEngineTransportSpy()
        await transport.suspendRequests()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        var activities = await engine.activities(for: conversation).makeAsyncIterator()
        let initialActivity = await activities.next()
        XCTAssertEqual(initialActivity, .idle)
        await engine.connectionDidBecomeReady(generation: 18)
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "100"))

        await submit(engine,
            ArchiveWindowIntent(
                conversation: conversation,
                locator: .older(before: boundary),
                contextBefore: ArchivePageSizing.history,
                contextAfter: ArchivePageSizing.initial,
                priority: .visibleIntegrity
            )
        )

        let loadingActivity = await activities.next()
        XCTAssertEqual(
            loadingActivity,
            ArchiveWindowActivity(activeBoundaryRequestCount: 1),
            "The UI must not observe a false terminal idle between paging intent and transport ownership"
        )
        await engine.connectionDidDisconnect()
    }

    func testBoundaryIntentPublishesOnlyItsMaterializedWindow() async throws {
        let previous = try makeBoundarySnapshot(
            ids: ["p200", "p250", "p300"],
            target: .latest,
            oldest: "200",
            newest: "300",
            generation: 1,
            freshnessGeneration: 1
        )
        let incoming = try makeBoundarySnapshot(
            ids: ["p100", "p150", "p200", "p250"],
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "200"))),
            oldest: "100",
            newest: "300",
            generation: 2,
            freshnessGeneration: 1
        )

        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(previous)
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: ArchiveEngineTransportSpy(),
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 1)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        await repository.setSnapshot(incoming)
        let boundaryIntent = ArchiveWindowIntent(
            conversation: conversation,
            locator: incoming.target,
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        var terminals = await engine.boundaryTerminals(
            for: conversation
        ).makeAsyncIterator()
        await submit(engine, boundaryIntent)
        await engine.waitUntilIdleForTesting()

        let receivedTerminal = await terminals.next()
        let terminal = try XCTUnwrap(receivedTerminal)
        let currentState = await engine.currentState(for: conversation)
        XCTAssertEqual(terminal.requestID, boundaryIntent.id)
        XCTAssertEqual(terminal.descriptor, boundaryIntent.semanticDescriptor)
        XCTAssertEqual(terminal.result, .succeeded)
        XCTAssertEqual(
            currentState,
            .verified(incoming),
            "The success terminal is published only after the verified proof state is authoritative"
        )
    }

    func testTerminalBoundaryFailureClearsActivityWithoutDiscardingVerifiedWindow() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(sessionGeneration: 15))
        let initialTransport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: initialTransport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 15)
        await submit(engine, latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        guard case .verified(let current) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected verified initial window")
        }

        // A separate engine keeps the failure transport immutable while
        // reusing the repository's already verified admission proof.
        let failureRepository = ArchiveEngineRepositorySpy()
        await failureRepository.setSnapshot(current)
        let failingTransport = FailingArchiveEngineTransport(error: .timeout)
        let failureEngine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: failureRepository,
            transport: failingTransport,
            retryClock: .immediate
        )
        await failureEngine.connectionDidBecomeReady(generation: 15)
        await submit(failureEngine, latestIntent(priority: .visibleIntegrity))
        await failureEngine.waitUntilIdleForTesting()
        guard case .verified(let admitted) = await failureEngine.currentState(for: conversation) else {
            return XCTFail("Expected verified admission")
        }
        await failureRepository.setSnapshot(nil)

        let boundaryIntent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: admitted.verifiedSegment.oldest),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        var terminals = await failureEngine.boundaryTerminals(
            for: conversation
        ).makeAsyncIterator()
        await failureEngine.submit(boundaryIntent)
        await failureEngine.waitUntilIdleForTesting()

        let receivedTerminal = await terminals.next()
        let terminal = try XCTUnwrap(receivedTerminal)
        let terminalState = await failureEngine.currentState(for: conversation)
        let terminalActivity = await failureEngine.currentActivity(for: conversation)
        let terminalRequestCount = await failingTransport.requestCount
        XCTAssertEqual(terminal.requestID, boundaryIntent.id)
        XCTAssertEqual(terminal.descriptor, boundaryIntent.semanticDescriptor)
        guard case .failed(let failure) = terminal.result else {
            return XCTFail("Expected a typed boundary failure terminal")
        }
        XCTAssertEqual(failure.retryCount, 8)
        XCTAssertTrue(failure.canRetry)
        XCTAssertEqual(terminalState, .verified(admitted))
        XCTAssertEqual(terminalActivity, .idle)
        XCTAssertEqual(terminalRequestCount, 8)
    }

    func testGapLargerThanOnePageAdvancesCursorUntilContinuousProofCompletes() async throws {
        let repository = PagingGapArchiveRepositorySpy()
        let transport = PagingGapArchiveTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        let older = ArchiveCursor(rawValue: "100")!
        let newer = ArchiveCursor(rawValue: "300")!
        let intent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .gap(olderBoundary: older, newerBoundary: newer),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.history,
            priority: .visibleIntegrity
        )

        await engine.connectionDidBecomeReady(generation: 13)
        await submit(engine, intent)
        await engine.waitUntilIdleForTesting()

        let locators = await transport.requestLocators
        XCTAssertEqual(
            locators,
            [
                .gap(olderBoundary: older, newerBoundary: newer),
                .gap(
                    olderBoundary: older,
                    newerBoundary: ArchiveCursor(rawValue: "201")!
                ),
            ]
        )
        guard case .verified(let snapshot) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected a verified continuous window")
        }
        XCTAssertEqual(snapshot.target, intent.locator)
        XCTAssertEqual(snapshot.verifiedSegment.oldest, older)
        XCTAssertEqual(snapshot.verifiedSegment.newest, newer)
    }

    func testHardCutBootstrapUsesEngineForEveryTimelineConversationType() async throws {
        let supportedTypes: [ClientSynchronizationManager.ConversationType] = [
            .regular,
            .group,
            .channel,
            .omemo,
            .omemo1,
            .axolotl,
            .saved,
        ]

        for (offset, conversationType) in supportedTypes.enumerated() {
            let key = ArchiveConversationKey(
                owner: conversation.owner,
                jid: "timeline-\(offset)@example.org",
                conversationType: conversationType
            )
            let transport = ArchiveEngineTransportSpy()
            let engine = AccountArchiveEngine(
                owner: key.owner,
                repository: ArchiveEngineRepositorySpy(),
                transport: transport,
                retryClock: .immediate
            )
            await engine.connectionDidBecomeReady(generation: UInt64(20 + offset))
        await submit(engine,
                ArchiveWindowIntent(
                    conversation: key,
                    locator: .latest,
                    contextBefore: ArchivePageSizing.initial,
                    contextAfter: 0,
                    priority: .visibleIntegrity
                )
            )
            await engine.waitUntilIdleForTesting()

            let requestedTypes = await transport.requestedConversationTypes
            XCTAssertEqual(requestedTypes, [conversationType])
            guard case .authoritativeEmpty = await engine.currentState(for: key) else {
                return XCTFail("Expected engine-owned terminal for \(conversationType.rawValue)")
            }
        }
    }

    func testGroupAdmissionCompletesBeforeArchiveTransportStarts() async throws {
        let groupConversation = ArchiveConversationKey(
            owner: conversation.owner,
            jid: "stage@groups.example.org",
            conversationType: .group
        )
        let admission = ArchiveEngineAdmissionSpy()
        await admission.suspendAdmission()
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: groupConversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(generation: 71)
        await submit(engine,
            ArchiveWindowIntent(
                conversation: groupConversation,
                locator: .latest,
                contextBefore: ArchivePageSizing.initial,
                contextAfter: 0,
                priority: .visibleIntegrity
            )
        )

        let admissionStarted = await waitForAdmissions(1, admission: admission)
        XCTAssertTrue(admissionStarted)
        let requestCountBeforeAdmission = await transport.requestCount
        XCTAssertEqual(
            requestCountBeforeAdmission,
            0,
            "Group/member admission must complete before the first MAM stanza is sent"
        )

        await admission.resumeAdmission()
        await engine.waitUntilIdleForTesting()

        let admissionCount = await admission.admitCount
        let requestCount = await transport.requestCount
        XCTAssertEqual(admissionCount, 1)
        XCTAssertEqual(requestCount, 1)
    }

    func testPermanentGroupAdmissionFailureSendsNoArchiveRequest() async throws {
        let groupConversation = ArchiveConversationKey(
            owner: conversation.owner,
            jid: "removed@groups.example.org",
            conversationType: .group
        )
        let admission = ArchiveEngineAdmissionSpy(
            terminalError: ArchiveConversationAdmissionError.tombstoned
        )
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: groupConversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(generation: 73)
        await submit(engine,
            ArchiveWindowIntent(
                conversation: groupConversation,
                locator: .latest,
                contextBefore: ArchivePageSizing.initial,
                contextAfter: 0,
                priority: .visibleIntegrity
            )
        )
        await engine.waitUntilIdleForTesting()

        let admissionCount = await admission.admitCount
        let requestCount = await transport.requestCount
        XCTAssertEqual(admissionCount, 1)
        XCTAssertEqual(requestCount, 0)
        guard case .retryableFailure(let failure, target: .latest) =
                await engine.currentState(for: groupConversation) else {
            return XCTFail("A rejected group admission must remain a terminal skeleton state")
        }
        XCTAssertFalse(failure.canRetry)
    }

    func testCurrentSearchArchivePriorityIsInteractive() {
        XCTAssertEqual(
            MessageArchiveTransportAdapter.schedulerPriority(.searchCurrentPage),
            .interactive
        )
    }

    func testArchiveIntentPriorityContainsNoSyncRepairOrBackfillWork() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/engine/ArchiveDomain.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("case snapshotRepair"))
        XCTAssertFalse(source.contains("case idleBackfill"))
    }

    private func latestIntent(priority: ArchiveIntentPriority) -> ArchiveWindowIntent {
        ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: priority
        )
    }

    private func submit(
        _ engine: AccountArchiveEngine,
        _ intent: ArchiveWindowIntent
    ) async {
        await engine.attachPresentationDemand(
            for: intent.conversation,
            demandID: UUID()
        )
        await engine.submit(intent)
    }

    private func waitForAuthoritativeLatest(
        _ engine: AccountArchiveEngine
    ) async -> Bool {
        for _ in 0..<2_000 {
            if case .authoritativeEmpty(target: .latest, _) =
                await engine.currentState(for: conversation) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForRetryableLatest(
        _ engine: AccountArchiveEngine
    ) async -> Bool {
        for _ in 0..<2_000 {
            if case .retryableFailure(_, target: .latest) =
                    await engine.currentState(for: conversation) {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func waitForRequests(
        _ count: Int,
        transport: ArchiveEngineTransportSpy
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await transport.requestCount >= count {
                return true
            }
            await Task.yield()
        }
        return await transport.requestCount >= count
    }

    private func waitForPromotions(
        _ count: Int,
        transport: ArchiveEngineTransportSpy
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await transport.promotedPriorities.count >= count {
                return true
            }
            await Task.yield()
        }
        return await transport.promotedPriorities.count >= count
    }

    private func waitForAdmissions(
        _ count: Int,
        admission: ArchiveEngineAdmissionSpy
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await admission.admitCount >= count {
                return true
            }
            await Task.yield()
        }
        return await admission.admitCount >= count
    }

    private func waitForReadiness(
        _ count: Int,
        admission: ArchiveEngineAdmissionSpy
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await admission.readinessCount >= count {
                return true
            }
            await Task.yield()
        }
        return await admission.readinessCount >= count
    }

    private func makeSnapshot(sessionGeneration: UInt64) -> ArchiveWindowSnapshot {
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: sessionGeneration,
            queryID: "archive.engine.fixture.\(sessionGeneration)"
        )
        let oldest = ArchiveCursor(rawValue: "10")!
        let newest = ArchiveCursor(rawValue: "20")!
        let segment = ArchiveCoverageSegment(
            oldest: oldest,
            newest: newest,
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: freshnessToken.fingerprint,
            isVerified: true
        )!
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: ["p10", "p20"],
            target: .latest,
            verifiedSegment: segment,
            coverageGeneration: 1,
            freshnessToken: freshnessToken
        )
    }

    private func makeBoundarySnapshot(
        ids: [String],
        target: ArchiveWindowLocator,
        oldest: String,
        newest: String,
        generation: UInt64,
        freshnessGeneration: UInt64
    ) throws -> ArchiveWindowSnapshot {
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: freshnessGeneration,
            queryID: "archive.engine.admission.\(freshnessGeneration)"
        )
        let segment = try XCTUnwrap(
            ArchiveCoverageSegment(
                oldest: XCTUnwrap(ArchiveCursor(rawValue: oldest)),
                newest: XCTUnwrap(ArchiveCursor(rawValue: newest)),
                reachesArchiveStart: false,
                reachesLiveEdge: true,
                fingerprint: freshnessToken.fingerprint,
                isVerified: true
            )
        )
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: ids,
            target: target,
            verifiedSegment: segment,
            coverageGeneration: generation,
            freshnessToken: freshnessToken
        )
    }
}

private actor ArchiveEngineAdmissionSpy: ArchiveConversationAdmissionProviding {
    private(set) var admitCount = 0
    private(set) var readinessCount = 0
    private(set) var disconnectCount = 0
    private var currentGeneration: UInt64?
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendReadiness = false
    private var readinessContinuation: CheckedContinuation<Void, Never>?
    private let terminalError: ArchiveConversationAdmissionError?

    init(terminalError: ArchiveConversationAdmissionError? = nil) {
        self.terminalError = terminalError
    }

    func suspendAdmission() {
        shouldSuspend = true
    }

    func resumeAdmission() {
        shouldSuspend = false
        continuation?.resume()
        continuation = nil
    }

    func suspendReadiness() {
        shouldSuspendReadiness = true
    }

    func resumeReadiness() {
        shouldSuspendReadiness = false
        readinessContinuation?.resume()
        readinessContinuation = nil
    }

    func connectionDidBecomeReady(generation: UInt64) async {
        readinessCount += 1
        if shouldSuspendReadiness {
            await withCheckedContinuation { continuation in
                readinessContinuation = continuation
            }
        }
        currentGeneration = generation
    }

    func connectionDidDisconnect() {
        disconnectCount += 1
        currentGeneration = nil
        continuation?.resume()
        continuation = nil
        readinessContinuation?.resume()
        readinessContinuation = nil
    }

    func admit(
        _ conversation: ArchiveConversationKey,
        connectionGeneration: UInt64
    ) async throws -> ArchiveConversationAdmissionResult {
        admitCount += 1
        guard currentGeneration == connectionGeneration else {
            throw ArchiveConversationAdmissionError.staleConnection
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if let terminalError {
            throw terminalError
        }
        return conversation.conversationType == .group ? .admitted : .notRequired
    }
}

/// Test-target-only convenience. Production has no admission bypass: the app
/// initializer must inject its account-scoped group admission coordinator.
extension AccountArchiveEngine {
    init(
        owner: String,
        repository: ArchiveCoverageRepository,
        transport: ArchiveTransport,
        retryClock: ArchiveRetryClock
    ) {
        self.init(
            owner: owner,
            repository: repository,
            transport: transport,
            admissionProvider: ArchiveEngineAdmissionSpy(),
            retryClock: retryClock
        )
    }
}

private actor PagingGapArchiveRepositorySpy: ArchiveCoverageRepository {
    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission? {
        nil
    }

    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit {
        guard case .gap(let older, let newer) = request.locator,
              let pageSegment = page.segment else {
            throw ArchiveTransportError.protocolViolation
        }
        if !page.requestComplete {
            return .coverageAdvanced(nextGapBoundary: pageSegment.oldest)
        }
        let originalNewer = ArchiveCursor(rawValue: "300")!
        guard newer == ArchiveCursor(rawValue: "201")!,
              let segment = ArchiveCoverageSegment(
                  oldest: older,
                  newest: originalNewer,
                  reachesArchiveStart: false,
                  reachesLiveEdge: false,
                  fingerprint: freshnessToken.fingerprint,
                  isVerified: true
              ) else {
            throw ArchiveTransportError.protocolViolation
        }
        return .verified(
            ArchiveWindowSnapshot(
                messagePrimaryIDs: ["p101", "p200", "p201", "p299"],
                target: request.locator,
                verifiedSegment: segment,
                coverageGeneration: 2,
                freshnessToken: freshnessToken
            )
        )
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? { nil }

    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot {
        throw ArchiveTransportError.protocolViolation
    }

    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot? { nil }
}

private actor PagingGapArchiveTransportSpy: ArchiveTransport {
    private(set) var requestLocators: [ArchiveWindowLocator] = []

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        requestLocators.append(request.locator)
        let archiveIDs: [String]
        let complete: Bool
        switch request.locator {
        case .gap(_, let newer) where newer == ArchiveCursor(rawValue: "300")!:
            archiveIDs = ["299", "201"]
            complete = false
        case .gap(_, let newer) where newer == ArchiveCursor(rawValue: "201")!:
            archiveIDs = ["200", "101"]
            complete = true
        default:
            throw ArchiveTransportError.protocolViolation
        }
        return ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: archiveIDs,
            messagePrimaryIDs: archiveIDs.map { "p\($0)" },
            first: archiveIDs.first!,
            last: archiveIDs.last!,
            complete: complete,
            cheapPageCount: archiveIDs.count,
            deliveredResultCount: archiveIDs.count,
            persistedResultCount: archiveIDs.count,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )
    }

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        throw ArchiveTransportError.protocolViolation
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {}
}

private actor FailingArchiveEngineTransport: ArchiveTransport {
    private(set) var requestCount = 0
    private let error: ArchiveTransportError

    init(error: ArchiveTransportError) {
        self.error = error
    }

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        requestCount += 1
        throw error
    }

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        throw error
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {}
}

private actor RetryOwnershipArchiveTransportSpy: ArchiveTransport {
    private struct PendingRequest {
        let request: ArchiveTransportRequest
        let continuation: CheckedContinuation<ArchiveTransportReceipt, Error>
    }

    private(set) var requestCount = 0
    private var pendingRequests: [PendingRequest] = []

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        _ = priority
        requestCount += 1
        if requestCount == 1 {
            throw ArchiveTransportError.protocolViolation
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(
                PendingRequest(
                    request: request,
                    continuation: continuation
                )
            )
        }
    }

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        _ = request
        _ = priority
        throw ArchiveTransportError.protocolViolation
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {
        _ = descriptor
        _ = connectionGeneration
        _ = priority
    }

    func waitForRequestCount(_ expected: Int) async -> Bool {
        for _ in 0..<2_000 {
            if requestCount >= expected { return true }
            await Task.yield()
        }
        return requestCount >= expected
    }

    func resumeAll(generation: UInt64) {
        let requests = pendingRequests
        pendingRequests.removeAll(keepingCapacity: true)
        for pending in requests {
            pending.continuation.resume(
                returning: ArchiveTransportReceipt
                    .emptyLatest(generation: generation)
                    .replacingIdentity(from: pending.request)
            )
        }
    }
}

private actor ArchiveEngineRepositorySpy: ArchiveCoverageRepository {
    private var snapshot: ArchiveWindowSnapshot?
    private(set) var committedFreshnessTokens: [ArchiveFreshnessToken] = []

    func setSnapshot(_ snapshot: ArchiveWindowSnapshot?) {
        self.snapshot = snapshot
    }

    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission? {
        guard var snapshot,
              snapshot.target == intent.locator,
              snapshot.freshnessToken.fingerprint == freshnessToken.fingerprint else {
            return nil
        }
        snapshot = ArchiveWindowSnapshot(
            messagePrimaryIDs: snapshot.messagePrimaryIDs,
            target: snapshot.target,
            verifiedSegment: snapshot.verifiedSegment,
            coverageGeneration: snapshot.coverageGeneration,
            freshnessToken: freshnessToken
        )
        return .verified(snapshot)
    }

    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit {
        committedFreshnessTokens.append(freshnessToken)
        if page.isAuthoritativeEmpty {
            return .authoritativeEmpty
        }
        guard let segment = page.segment else {
            return .materializedWithoutCoverage
        }
        let value = ArchiveWindowSnapshot(
            messagePrimaryIDs: page.messagePrimaryIDs,
            target: request.locator,
            verifiedSegment: segment,
            coverageGeneration: 1,
            freshnessToken: freshnessToken
        )
        snapshot = value
        return .verified(value)
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? {
        nil
    }

    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot {
        throw ArchiveTransportError.protocolViolation
    }

    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot? {
        nil
    }
}

private actor ArchiveEngineTransportSpy: ArchiveTransport {
    private(set) var requestCount = 0
    private(set) var promotedPriorities: [ArchiveIntentPriority] = []
    private(set) var promotedConnectionGenerations: [UInt64] = []
    private(set) var requestedConversationTypes:
        [ClientSynchronizationManager.ConversationType] = []
    private var isSuspended = false
    private var continuation: CheckedContinuation<ArchiveTransportReceipt, Error>?
    private var immediateReceipt: ArchiveTransportReceipt?

    func suspendRequests() {
        isSuspended = true
    }

    func setImmediateReceipt(_ receipt: ArchiveTransportReceipt?) {
        immediateReceipt = receipt
    }

    func resumeRequests(with receipt: ArchiveTransportReceipt) {
        isSuspended = false
        continuation?.resume(returning: receipt)
        continuation = nil
    }

    func request(_ request: ArchiveTransportRequest, priority: ArchiveIntentPriority) async throws -> ArchiveTransportReceipt {
        requestCount += 1
        requestedConversationTypes.append(request.conversation.conversationType)
        if let immediateReceipt {
            return immediateReceipt.replacingIdentity(from: request)
        }
        if isSuspended {
            let receipt = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
            return receipt.replacingIdentity(from: request)
        }
        return .emptyLatest(
            generation: request.connectionGeneration
        ).replacingIdentity(from: request)
    }

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        throw ArchiveTransportError.protocolViolation
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {
        promotedConnectionGenerations.append(connectionGeneration)
        promotedPriorities.append(priority)
    }
}

private actor ReplacementArchiveTransportSpy: ArchiveTransport {
    private struct PendingRequest {
        let request: ArchiveTransportRequest
        let continuation: CheckedContinuation<ArchiveTransportReceipt, Error>
    }

    private var pending: [PendingRequest] = []
    private(set) var requestCount = 0
    private(set) var requestedLocators: [ArchiveWindowLocator] = []

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        _ = priority
        requestCount += 1
        requestedLocators.append(request.locator)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingRequest(
                request: request,
                continuation: continuation
            ))
        }
    }

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        _ = request
        _ = priority
        throw ArchiveTransportError.protocolViolation
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {
        _ = descriptor
        _ = connectionGeneration
        _ = priority
    }

    func waitForRequestCount(_ expected: Int) async -> Bool {
        for _ in 0..<1_000 {
            if requestCount >= expected { return true }
            await Task.yield()
        }
        return false
    }

    func resume(
        locator: ArchiveWindowLocator,
        archiveIDs: [String],
        primaryIDs: [String],
        complete: Bool
    ) {
        guard let index = pending.firstIndex(where: {
            $0.request.locator == locator
        }) else {
            return
        }
        let value = pending.remove(at: index)
        value.continuation.resume(returning: ArchiveTransportReceipt(
            queryID: value.request.queryID,
            connectionGeneration: value.request.connectionGeneration,
            resultArchiveIDs: archiveIDs,
            messagePrimaryIDs: primaryIDs,
            first: archiveIDs.first ?? "",
            last: archiveIDs.last ?? "",
            complete: complete,
            cheapPageCount: archiveIDs.count,
            deliveredResultCount: archiveIDs.count,
            persistedResultCount: primaryIDs.count,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        ))
    }
}

private actor SupersededAnchorArchiveRepositorySpy: ArchiveCoverageRepository {
    private(set) var committedLocators: [ArchiveWindowLocator] = []

    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission? { nil }

    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit {
        committedLocators.append(request.locator)
        return page.isAuthoritativeEmpty
            ? .authoritativeEmpty
            : .materializedWithoutCoverage
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? {
        guard case .archiveID(let cursor) = locator else { return nil }
        return ArchiveMaterializedAnchor(cursor: cursor, primaryID: "p500")
    }

    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot {
        throw ArchiveTransportError.protocolViolation
    }

    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot? { nil }
}

private actor SuspendingLiveEdgeArchiveRepositorySpy: ArchiveCoverageRepository {
    private let admission: ArchiveWindowSnapshot
    private let liveSnapshot: ArchiveWindowSnapshot
    private var suspendsLiveEdge = false
    private var didRequestLiveEdge = false
    private(set) var liveEdgeIntentLocators: [ArchiveWindowLocator] = []
    private(set) var liveEdgeContextBefore: [Int] = []
    private var liveEdgeContinuation: CheckedContinuation<Void, Never>?

    init(
        admission: ArchiveWindowSnapshot,
        liveSnapshot: ArchiveWindowSnapshot
    ) {
        self.admission = admission
        self.liveSnapshot = liveSnapshot
    }

    func suspendLiveEdge() {
        suspendsLiveEdge = true
    }

    func waitForLiveEdgeRequest() async -> Bool {
        for _ in 0..<2_000 {
            if didRequestLiveEdge { return true }
            await Task.yield()
        }
        return didRequestLiveEdge
    }

    func resumeLiveEdge() {
        suspendsLiveEdge = false
        liveEdgeContinuation?.resume()
        liveEdgeContinuation = nil
    }

    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission? {
        guard case .latest = intent.locator,
              freshnessToken.fingerprint == admission.freshnessToken.fingerprint else {
            return nil
        }
        return .verified(
            ArchiveWindowSnapshot(
                messagePrimaryIDs: admission.messagePrimaryIDs,
                target: admission.target,
                verifiedSegment: admission.verifiedSegment,
                coverageGeneration: admission.coverageGeneration,
                freshnessToken: freshnessToken
            )
        )
    }

    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit {
        page.isAuthoritativeEmpty ? .authoritativeEmpty : .materializedWithoutCoverage
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? { nil }

    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot {
        throw ArchiveTransportError.protocolViolation
    }

    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot? {
        didRequestLiveEdge = true
        liveEdgeIntentLocators.append(intent.locator)
        liveEdgeContextBefore.append(intent.contextBefore)
        if suspendsLiveEdge {
            await withCheckedContinuation { continuation in
                liveEdgeContinuation = continuation
            }
        }
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: liveSnapshot.messagePrimaryIDs,
            target: liveSnapshot.target,
            verifiedSegment: liveSnapshot.verifiedSegment,
            coverageGeneration: liveSnapshot.coverageGeneration,
            freshnessToken: freshnessToken
        )
    }
}

private extension ArchiveTransportReceipt {
    static func emptyLatest(generation: UInt64) -> ArchiveTransportReceipt {
        ArchiveTransportReceipt(
            queryID: "placeholder",
            connectionGeneration: generation,
            resultArchiveIDs: [],
            messagePrimaryIDs: [],
            first: "",
            last: "",
            complete: true,
            cheapPageCount: 0,
            deliveredResultCount: 0,
            persistedResultCount: 0,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )
    }

    func replacingIdentity(from request: ArchiveTransportRequest) -> ArchiveTransportReceipt {
        var copy = self
        copy.queryID = request.queryID
        copy.connectionGeneration = request.connectionGeneration
        return copy
    }
}
