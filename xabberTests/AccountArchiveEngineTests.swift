import XCTest
@testable import xabber

final class AccountArchiveEngineTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testOfflineOpenAlwaysPublishesFullSkeletonEvenWithCachedSnapshot() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(fingerprint: "sync-1"))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        let intent = latestIntent(priority: .visibleIntegrity)
        await engine.submit(intent)

        let state = await engine.currentState(for: conversation)
        let requestCount = await transport.requestCount
        XCTAssertEqual(state, .skeleton(reason: .offline, target: .latest))
        XCTAssertEqual(requestCount, 0)
    }

    func testMatchingCompletedSyncActivatesProvisionalCoverageWithoutMAMProbe() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(fingerprint: "sync-2"))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(
            generation: 3,
            completedXEPSYNCFingerprint: "sync-2"
        )
        await engine.submit(latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        guard case .verified(let snapshot) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected verified snapshot")
        }
        XCTAssertEqual(snapshot.freshnessToken, .xepSync(fingerprint: "sync-2"))
        let requestCount = await transport.requestCount
        let verifiedFingerprints = await repository.verifiedFingerprints
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(verifiedFingerprints, ["sync-2"])
    }

    func testVisibleIntentUsesSessionMAMProofWhileXEPSYNCSnapshotIsStillLoading() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )

        await engine.connectionDidBecomeReady(
            generation: 4,
            completedXEPSYNCFingerprint: nil,
            waitsForXEPSYNC: true
        )
        await engine.submit(latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
        guard case .authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(let generation, _)
        ) = await engine.currentState(for: conversation) else {
            return XCTFail("Expected current-session MAM proof while XEP-SYNC is loading")
        }
        XCTAssertEqual(generation, 4)

        await engine.connectionDidBecomeReady(
            generation: 4,
            completedXEPSYNCFingerprint: "sync-ready"
        )
        await engine.waitUntilIdleForTesting()
        let readyRequestCount = await transport.requestCount
        XCTAssertEqual(readyRequestCount, 2)
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
        await engine.connectionDidBecomeReady(generation: 5, completedXEPSYNCFingerprint: "sync-3")

        await engine.submit(latestIntent(priority: .nearEdgePrefetch))
        await engine.submit(latestIntent(priority: .visibleIntegrity))
        await transport.resumeRequests(with: .emptyLatest(generation: 5, fingerprint: "sync-3"))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        let promotedPriorities = await transport.promotedPriorities
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(promotedPriorities, [.visibleIntegrity])
        guard case .authoritativeEmpty = await engine.currentState(for: conversation) else {
            return XCTFail("Expected authoritative empty terminal")
        }
    }

    func testFingerprintChangeReturnsSkeletonAndIgnoresLateOldGenerationReceipt() async throws {
        let repository = ArchiveEngineRepositorySpy()
        let transport = ArchiveEngineTransportSpy()
        await transport.suspendRequests()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 8, completedXEPSYNCFingerprint: "sync-old")
        await engine.submit(latestIntent(priority: .visibleIntegrity))

        await engine.connectionDidBecomeReady(generation: 9, completedXEPSYNCFingerprint: "sync-new")
        let staleState = await engine.currentState(for: conversation)
        XCTAssertEqual(staleState, .skeleton(reason: .staleFingerprint, target: .latest))

        await transport.resumeRequests(with: .emptyLatest(generation: 8, fingerprint: "sync-old"))
        await engine.waitUntilIdleForTesting()
        let lateState = await engine.currentState(for: conversation)
        XCTAssertNotEqual(
            lateState,
            .authoritativeEmpty(
                target: .latest,
                freshnessToken: .xepSync(fingerprint: "sync-old")
            )
        )
    }

    func testDisconnectImmediatelyReplacesVerifiedContentWithSkeletonAndReconnectResumesIntent() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(fingerprint: "sync-4"))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(generation: 10, completedXEPSYNCFingerprint: "sync-4")
        await engine.submit(latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()
        guard case .verified = await engine.currentState(for: conversation) else {
            return XCTFail("Expected verified before disconnect")
        }

        await engine.connectionDidDisconnect()
        let offlineState = await engine.currentState(for: conversation)
        XCTAssertEqual(offlineState, .skeleton(reason: .offline, target: .latest))

        await repository.setSnapshot(nil)
        await transport.setImmediateReceipt(.emptyLatest(generation: 11, fingerprint: "sync-5"))
        await engine.connectionDidBecomeReady(generation: 11, completedXEPSYNCFingerprint: "sync-5")
        await engine.waitUntilIdleForTesting()
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testTransientFailureUsesSevenBackoffRetriesThenExposesRetryAction() async throws {
        let transport = FailingArchiveEngineTransport(error: .timeout)
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(
            generation: 11,
            completedXEPSYNCFingerprint: "sync-retry"
        )

        await engine.submit(latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 8)
        guard case .retryableFailure(let failure, target: .latest) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected retryable failure after bounded retries")
        }
        XCTAssertEqual(failure.retryCount, 8)
        XCTAssertTrue(failure.canRetry)
    }

    func testPermanentProtocolFailureDoesNotRetryAutomatically() async throws {
        let transport = FailingArchiveEngineTransport(error: .protocolViolation)
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveEngineRepositorySpy(),
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(
            generation: 12,
            completedXEPSYNCFingerprint: "sync-permanent"
        )

        await engine.submit(latestIntent(priority: .visibleIntegrity))
        await engine.waitUntilIdleForTesting()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
        guard case .retryableFailure(let failure, target: .latest) =
                await engine.currentState(for: conversation) else {
            return XCTFail("Expected terminal protocol failure")
        }
        XCTAssertEqual(failure.retryCount, 1)
        XCTAssertFalse(failure.canRetry)
    }

    func testNearEdgePrefetchKeepsCurrentlyVerifiedWindowVisibleWhileRequestRuns() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(fingerprint: "sync-prefetch"))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(
            generation: 12,
            completedXEPSYNCFingerprint: "sync-prefetch"
        )
        await engine.submit(latestIntent(priority: .visibleIntegrity))
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
        await engine.submit(prefetch)

        let stateWhilePrefetchRuns = await engine.currentState(for: conversation)
        XCTAssertEqual(stateWhilePrefetchRuns, .verified(current))
    }

    func testInteractiveBoundaryLoadKeepsVerifiedWindowAndPublishesActivityUntilDisconnect() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(fingerprint: "sync-boundary"))
        let transport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(
            generation: 14,
            completedXEPSYNCFingerprint: "sync-boundary"
        )
        await engine.submit(latestIntent(priority: .visibleIntegrity))
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
        await engine.submit(boundaryIntent)

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
            .skeleton(reason: .offline, target: boundaryIntent.locator)
        )
    }

    func testOlderBoundarySnapshotRetainsThePreviouslyVerifiedVisibleTail() throws {
        let previous = try makeBoundarySnapshot(
            ids: ["p200", "p250", "p300"],
            target: .latest,
            oldest: "200",
            newest: "300",
            generation: 1
        )
        let incoming = try makeBoundarySnapshot(
            ids: ["p100", "p150", "p200", "p250"],
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "200"))),
            oldest: "100",
            newest: "300",
            generation: 2
        )

        let merged = ArchiveBoundarySnapshotMergePolicy.merge(
            previousState: .verified(previous),
            incoming: incoming
        )

        XCTAssertEqual(
            merged.messagePrimaryIDs,
            ["p100", "p150", "p200", "p250", "p300"]
        )
        XCTAssertEqual(merged.target, incoming.target)
        XCTAssertEqual(merged.verifiedSegment, incoming.verifiedSegment)
        XCTAssertEqual(merged.coverageGeneration, 2)
    }

    func testBoundarySnapshotDoesNotMergeAcrossFreshnessProofs() throws {
        let previous = try makeBoundarySnapshot(
            ids: ["old"],
            target: .latest,
            oldest: "200",
            newest: "300",
            generation: 1,
            fingerprint: "sync-old"
        )
        let incoming = try makeBoundarySnapshot(
            ids: ["new"],
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "200"))),
            oldest: "100",
            newest: "300",
            generation: 2,
            fingerprint: "sync-new"
        )

        XCTAssertEqual(
            ArchiveBoundarySnapshotMergePolicy.merge(
                previousState: .verified(previous),
                incoming: incoming
            ),
            incoming
        )
    }

    func testRepeatedOlderBoundaryMergeKeepsAnchorSideAndBoundsPresentationWindow() throws {
        let previous = try makeBoundarySnapshot(
            ids: (200...499).map { "p\($0)" },
            target: .latest,
            oldest: "200",
            newest: "500",
            generation: 1
        )
        let incoming = try makeBoundarySnapshot(
            ids: (100...249).map { "p\($0)" },
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "200"))),
            oldest: "100",
            newest: "500",
            generation: 2
        )

        let merged = ArchiveBoundarySnapshotMergePolicy.merge(
            previousState: .verified(previous),
            incoming: incoming
        )

        XCTAssertEqual(
            merged.messagePrimaryIDs.count,
            ArchiveBoundarySnapshotMergePolicy.maximumMessageCount
        )
        XCTAssertEqual(merged.messagePrimaryIDs.first, "p100")
        XCTAssertTrue(merged.messagePrimaryIDs.contains("p200"))
        XCTAssertFalse(merged.messagePrimaryIDs.contains("p499"))
    }

    func testTerminalBoundaryFailureClearsActivityWithoutDiscardingVerifiedWindow() async throws {
        let repository = ArchiveEngineRepositorySpy()
        await repository.setSnapshot(makeSnapshot(fingerprint: "sync-boundary-failure"))
        let initialTransport = ArchiveEngineTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: initialTransport,
            retryClock: .immediate
        )
        await engine.connectionDidBecomeReady(
            generation: 15,
            completedXEPSYNCFingerprint: "sync-boundary-failure"
        )
        await engine.submit(latestIntent(priority: .visibleIntegrity))
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
        await failureEngine.connectionDidBecomeReady(
            generation: 15,
            completedXEPSYNCFingerprint: "sync-boundary-failure"
        )
        await failureEngine.submit(latestIntent(priority: .visibleIntegrity))
        await failureEngine.waitUntilIdleForTesting()
        guard case .verified(let admitted) = await failureEngine.currentState(for: conversation) else {
            return XCTFail("Expected verified admission")
        }
        await failureRepository.setSnapshot(nil)

        await failureEngine.submit(
            ArchiveWindowIntent(
                conversation: conversation,
                locator: .older(before: admitted.verifiedSegment.oldest),
                contextBefore: ArchivePageSizing.history,
                contextAfter: ArchivePageSizing.initial,
                priority: .visibleIntegrity
            )
        )
        await failureEngine.waitUntilIdleForTesting()

        let terminalState = await failureEngine.currentState(for: conversation)
        let terminalActivity = await failureEngine.currentActivity(for: conversation)
        let terminalRequestCount = await failingTransport.requestCount
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

        await engine.connectionDidBecomeReady(
            generation: 13,
            completedXEPSYNCFingerprint: "sync-gap"
        )
        await engine.submit(intent)
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
            await engine.connectionDidBecomeReady(
                generation: UInt64(20 + offset),
                completedXEPSYNCFingerprint: "sync-\(offset)"
            )
            await engine.submit(
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

    private func latestIntent(priority: ArchiveIntentPriority) -> ArchiveWindowIntent {
        ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: priority
        )
    }

    private func makeSnapshot(fingerprint: String) -> ArchiveWindowSnapshot {
        let oldest = ArchiveCursor(rawValue: "10")!
        let newest = ArchiveCursor(rawValue: "20")!
        let segment = ArchiveCoverageSegment(
            oldest: oldest,
            newest: newest,
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: fingerprint,
            isVerified: true
        )!
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: ["p10", "p20"],
            target: .latest,
            verifiedSegment: segment,
            coverageGeneration: 1,
            freshnessToken: .xepSync(fingerprint: fingerprint)
        )
    }

    private func makeBoundarySnapshot(
        ids: [String],
        target: ArchiveWindowLocator,
        oldest: String,
        newest: String,
        generation: UInt64,
        fingerprint: String = "sync-boundary-merge"
    ) throws -> ArchiveWindowSnapshot {
        let segment = try XCTUnwrap(
            ArchiveCoverageSegment(
                oldest: XCTUnwrap(ArchiveCursor(rawValue: oldest)),
                newest: XCTUnwrap(ArchiveCursor(rawValue: newest)),
                reachesArchiveStart: false,
                reachesLiveEdge: true,
                fingerprint: fingerprint,
                isVerified: true
            )
        )
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: ids,
            target: target,
            verifiedSegment: segment,
            coverageGeneration: generation,
            freshnessToken: .xepSync(fingerprint: fingerprint)
        )
    }
}

private actor PagingGapArchiveRepositorySpy: ArchiveCoverageRepository {
    func verifyProvisionalCoverage(owner: String, fingerprint: String) async throws {}

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

    func promote(
        descriptor: ArchiveIntentDescriptor,
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

    func promote(
        descriptor: ArchiveIntentDescriptor,
        to priority: ArchiveIntentPriority
    ) async {}
}

private actor ArchiveEngineRepositorySpy: ArchiveCoverageRepository {
    private var snapshot: ArchiveWindowSnapshot?
    private(set) var verifiedFingerprints: [String] = []

    func setSnapshot(_ snapshot: ArchiveWindowSnapshot?) {
        self.snapshot = snapshot
    }

    func verifyProvisionalCoverage(
        owner: String,
        fingerprint: String
    ) async throws {
        verifiedFingerprints.append(fingerprint)
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
            generation: request.connectionGeneration,
            fingerprint: request.proofFingerprint
        ).replacingIdentity(from: request)
    }

    func promote(descriptor: ArchiveIntentDescriptor, to priority: ArchiveIntentPriority) async {
        promotedPriorities.append(priority)
    }
}

private extension ArchiveTransportReceipt {
    static func emptyLatest(generation: UInt64, fingerprint: String) -> ArchiveTransportReceipt {
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
