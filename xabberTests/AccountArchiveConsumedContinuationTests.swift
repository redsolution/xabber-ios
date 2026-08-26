import XCTest
@testable import xabber

final class AccountArchiveConsumedContinuationTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testIncompleteConsumedOnlyLatestContinuesOlderWithoutPublishingIntermediateEmpty() async throws {
        let repository = ConsumedContinuationArchiveRepository()
        let transport = ConsumedContinuationArchiveTransport()
        let admission = ConsumedContinuationAdmissionStub()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: repository,
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )
        let stateStream = await engine.states(for: conversation)
        let stateRecorder = ConsumedContinuationStateRecorder()
        let stateRecordingTask = Task {
            for await state in stateStream {
                await stateRecorder.append(state)
            }
        }
        defer { stateRecordingTask.cancel() }

        await engine.connectionDidBecomeReady(generation: 41)
        let demandID = UUID()
        await engine.attachPresentationDemand(
            for: conversation,
            demandID: demandID
        )
        await engine.submit(
            ArchiveWindowIntent(
                conversation: conversation,
                locator: .latest,
                contextBefore: ArchivePageSizing.initial,
                contextAfter: 0,
                priority: .visibleIntegrity
            )
        )

        let firstRequestStarted = await waitForRequests(
            1,
            transport: transport
        )
        XCTAssertTrue(firstRequestStarted)
        let firstRecordValue = await transport.record(at: 0)
        let firstRecord = try XCTUnwrap(firstRecordValue)
        XCTAssertEqual(firstRecord.request.locator, .latest)
        XCTAssertEqual(firstRecord.request.connectionGeneration, 41)
        XCTAssertEqual(firstRecord.priority, .visibleIntegrity)

        let firstResolved = await transport.resolve(
            at: 0,
            with: .consumedOnly(
                archiveIDs: ["10", "20"],
                complete: false
            )
        )
        XCTAssertTrue(firstResolved)

        let secondRequestStarted = await waitForRequests(
            2,
            transport: transport
        )
        XCTAssertTrue(
            secondRequestStarted,
            "An incomplete consumed-only latest page must continue before exposing an empty timeline"
        )
        guard secondRequestStarted else { return }

        guard case .skeleton(_, target: .latest) =
            await engine.currentState(for: conversation) else {
            return XCTFail(
                "The initial skeleton must remain while the consumed-only continuation is pending"
            )
        }

        let secondRecordValue = await transport.record(at: 1)
        let secondRecord = try XCTUnwrap(secondRecordValue)
        let firstOldest = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        XCTAssertEqual(secondRecord.request.locator, .older(before: firstOldest))
        XCTAssertEqual(
            secondRecord.request.connectionGeneration,
            firstRecord.request.connectionGeneration
        )
        XCTAssertEqual(secondRecord.priority, .visibleIntegrity)
        let maximumOutstandingRequestCount = await transport.maximumOutstandingRequestCount
        XCTAssertEqual(
            maximumOutstandingRequestCount,
            1,
            "Continuation pages must reuse the account MAM lane sequentially"
        )

        let secondResolved = await transport.resolve(
            at: 1,
            with: .visible(
                archiveIDs: ["8", "9"],
                primaryIDs: ["visible-8", "visible-9"],
                complete: false
            )
        )
        XCTAssertTrue(secondResolved)
        await engine.waitUntilIdleForTesting()

        guard case .verified(let snapshot) =
            await engine.currentState(for: conversation) else {
            return XCTFail("The first materialized continuation page must finish the latest intent")
        }
        XCTAssertEqual(snapshot.target, .latest)
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["visible-8", "visible-9"])
        XCTAssertEqual(snapshot.verifiedSegment.oldest.rawValue, "8")
        XCTAssertEqual(snapshot.verifiedSegment.newest.rawValue, "20")
        XCTAssertFalse(snapshot.verifiedSegment.reachesArchiveStart)
        XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)

        let finalStateRecorded = await waitForVisibleState(
            in: stateRecorder,
            primaryIDs: snapshot.messagePrimaryIDs
        )
        XCTAssertTrue(finalStateRecorded)
        let recordedStates = await stateRecorder.values
        XCTAssertFalse(
            recordedStates.contains { $0.isPublishedEmpty },
            "A verified or authoritative empty state must not be published between continuation pages"
        )
    }

    private func waitForRequests(
        _ expectedCount: Int,
        transport: ConsumedContinuationArchiveTransport
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await transport.requestCount >= expectedCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await transport.requestCount >= expectedCount
    }

    private func waitForVisibleState(
        in recorder: ConsumedContinuationStateRecorder,
        primaryIDs: [String]
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await recorder.containsVerified(primaryIDs: primaryIDs) {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await recorder.containsVerified(primaryIDs: primaryIDs)
    }
}

private extension ArchiveWindowState {
    var isPublishedEmpty: Bool {
        switch self {
        case .verified(let snapshot):
            return snapshot.messagePrimaryIDs.isEmpty
        case .authoritativeEmpty:
            return true
        case .skeleton, .retryableFailure:
            return false
        }
    }
}

private actor ConsumedContinuationStateRecorder {
    private(set) var values: [ArchiveWindowState] = []

    func append(_ state: ArchiveWindowState) {
        values.append(state)
    }

    func containsVerified(primaryIDs: [String]) -> Bool {
        values.contains { state in
            guard case .verified(let snapshot) = state else { return false }
            return snapshot.messagePrimaryIDs == primaryIDs
        }
    }
}

private actor ConsumedContinuationAdmissionStub:
    ArchiveConversationAdmissionProviding {
    private var connectionGeneration: UInt64?

    func connectionDidBecomeReady(generation: UInt64) {
        connectionGeneration = generation
    }

    func connectionDidDisconnect() {
        connectionGeneration = nil
    }

    func admit(
        _ conversation: ArchiveConversationKey,
        connectionGeneration: UInt64
    ) async throws -> ArchiveConversationAdmissionResult {
        guard self.connectionGeneration == connectionGeneration else {
            throw ArchiveConversationAdmissionError.staleConnection
        }
        return .notRequired
    }
}

private actor ConsumedContinuationArchiveRepository: ArchiveCoverageRepository {
    private var latestSegment: ArchiveCoverageSegment?
    private var coverageGeneration: UInt64 = 0

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
        coverageGeneration &+= 1
        switch request.locator {
        case .latest:
            guard page.deliveredResultCount > 0,
                  page.intentionallyConsumedResultCount == page.deliveredResultCount,
                  page.messagePrimaryIDs.isEmpty,
                  !page.requestComplete,
                  let segment = page.segment,
                  segment.reachesLiveEdge,
                  !segment.reachesArchiveStart else {
                throw ArchiveTransportError.protocolViolation
            }
            latestSegment = segment
            return .verified(
                ArchiveWindowSnapshot(
                    messagePrimaryIDs: [],
                    target: request.locator,
                    verifiedSegment: segment,
                    coverageGeneration: coverageGeneration,
                    freshnessToken: freshnessToken
                )
            )

        case .older(let boundary):
            guard let latestSegment,
                  boundary == latestSegment.oldest,
                  let pageSegment = page.segment,
                  page.messagePrimaryIDs.isNotEmpty,
                  pageSegment.fingerprint == latestSegment.fingerprint,
                  let mergedSegment = ArchiveCoverageSegment(
                      oldest: pageSegment.oldest,
                      newest: latestSegment.newest,
                      reachesArchiveStart: pageSegment.reachesArchiveStart,
                      reachesLiveEdge: latestSegment.reachesLiveEdge,
                      fingerprint: latestSegment.fingerprint,
                      isVerified: true
                  ) else {
                throw ArchiveTransportError.protocolViolation
            }
            return .verified(
                ArchiveWindowSnapshot(
                    messagePrimaryIDs: page.messagePrimaryIDs,
                    target: request.locator,
                    verifiedSegment: mergedSegment,
                    coverageGeneration: coverageGeneration,
                    freshnessToken: freshnessToken
                )
            )

        default:
            throw ArchiveTransportError.protocolViolation
        }
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

private struct ConsumedContinuationRequestRecord: Sendable {
    let request: ArchiveTransportRequest
    let priority: ArchiveIntentPriority
}

private enum ConsumedContinuationPage: Sendable {
    case consumedOnly(archiveIDs: [String], complete: Bool)
    case visible(archiveIDs: [String], primaryIDs: [String], complete: Bool)

    func receipt(for request: ArchiveTransportRequest) -> ArchiveTransportReceipt {
        let archiveIDs: [String]
        let primaryIDs: [String]
        let complete: Bool
        let consumedCount: Int
        switch self {
        case .consumedOnly(let ids, let isComplete):
            archiveIDs = ids
            primaryIDs = []
            complete = isComplete
            consumedCount = ids.count
        case .visible(let ids, let idsForStorage, let isComplete):
            archiveIDs = ids
            primaryIDs = idsForStorage
            complete = isComplete
            consumedCount = 0
        }
        return ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: archiveIDs,
            messagePrimaryIDs: primaryIDs,
            first: archiveIDs.first ?? "",
            last: archiveIDs.last ?? "",
            complete: complete,
            cheapPageCount: archiveIDs.count,
            deliveredResultCount: archiveIDs.count,
            persistedResultCount: primaryIDs.count,
            intentionallyConsumedResultCount: consumedCount,
            failedPersistenceCount: 0,
            finalReceived: true
        )
    }
}

private actor ConsumedContinuationArchiveTransport: ArchiveTransport {
    private(set) var records: [ConsumedContinuationRequestRecord] = []
    private(set) var maximumOutstandingRequestCount = 0
    private var outstandingRequestCount = 0
    private var continuations:
        [Int: CheckedContinuation<ArchiveTransportReceipt, Error>] = [:]

    var requestCount: Int { records.count }

    func record(at index: Int) -> ConsumedContinuationRequestRecord? {
        guard records.indices.contains(index) else { return nil }
        return records[index]
    }

    func resolve(
        at index: Int,
        with page: ConsumedContinuationPage
    ) -> Bool {
        guard records.indices.contains(index),
              let continuation = continuations.removeValue(forKey: index) else {
            return false
        }
        continuation.resume(returning: page.receipt(for: records[index].request))
        return true
    }

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        let index = records.count
        records.append(
            ConsumedContinuationRequestRecord(
                request: request,
                priority: priority
            )
        )
        outstandingRequestCount += 1
        maximumOutstandingRequestCount = max(
            maximumOutstandingRequestCount,
            outstandingRequestCount
        )
        defer { outstandingRequestCount -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
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
