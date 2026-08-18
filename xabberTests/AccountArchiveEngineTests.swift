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

    func testXEPSYNCCapableSessionKeepsSkeletonAndDoesNotFallbackToMAMBeforeSnapshotProof() async throws {
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

        let waitingRequestCount = await transport.requestCount
        let waitingState = await engine.currentState(for: conversation)
        XCTAssertEqual(waitingRequestCount, 0)
        XCTAssertEqual(
            waitingState,
            .skeleton(reason: .unverifiedCoverage, target: .latest)
        )

        await engine.connectionDidBecomeReady(
            generation: 4,
            completedXEPSYNCFingerprint: "sync-ready"
        )
        await engine.waitUntilIdleForTesting()
        let readyRequestCount = await transport.requestCount
        XCTAssertEqual(readyRequestCount, 1)
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
