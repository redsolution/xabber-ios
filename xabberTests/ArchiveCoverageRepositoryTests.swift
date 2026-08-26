import XCTest
import RealmSwift
@testable import xabber

@MainActor
final class ArchiveCoverageRepositoryTests: XCTestCase {
    private var configuration: Realm.Configuration!
    private var retainedRealm: Realm!
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    override func setUp() {
        super.setUp()
        configuration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ArchiveCoverageRepositoryTests.\(UUID().uuidString)"
        )
        retainedRealm = try! Realm(configuration: configuration)
    }

    override func tearDown() {
        retainedRealm = nil
        configuration = nil
        super.tearDown()
    }

    func testCommitRequiresPersistedConversationMessagesBeforeCoverageProof() async throws {
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-missing")
        let page = try validatedPage(
            request: request,
            primaryIDs: ["missing-primary-20", "missing-primary-10"]
        )

        do {
            _ = try await repository.commit(
                page,
                request: request,
                freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-missing")
            )
            XCTFail("Coverage must not commit without durable message rows")
        } catch {
            XCTAssertEqual(error as? ArchiveCoverageRepositoryError, .missingPersistedMessages)
        }

        let realm = try await Realm(configuration: configuration)
        XCTAssertNil(
            realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: conversation.owner,
                    jid: conversation.jid,
                    conversationType: conversation.conversationType
                )
            )
        )
    }

    func testCommitAdmitsVerifiedWindowWhenEveryArchiveResultWasIntentionallyConsumed() async throws {
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-consumed-only")
        let page = try ArchiveTransportReceiptValidator.validate(
            ArchiveTransportReceipt(
                queryID: request.queryID,
                connectionGeneration: request.connectionGeneration,
                resultArchiveIDs: ["20", "10"],
                messagePrimaryIDs: [],
                first: "20",
                last: "10",
                complete: true,
                cheapPageCount: 2,
                deliveredResultCount: 2,
                persistedResultCount: 0,
                intentionallyConsumedResultCount: 2,
                failedPersistenceCount: 0,
                finalReceived: true
            ),
            for: request
        )

        let result = try await repository.commit(
            page,
            request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-consumed-only")
        )

        guard case .verified(let snapshot) = result else {
            return XCTFail("Expected consumed-only archive proof to verify an empty visible window")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, [])
        XCTAssertTrue(snapshot.verifiedSegment.reachesArchiveStart)
        XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)

        let realm = try await Realm(configuration: configuration)
        let storage = try XCTUnwrap(
            realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: conversation.owner,
                    jid: conversation.jid,
                    conversationType: conversation.conversationType
                )
            )
        )
        XCTAssertEqual(storage.segments.count, 1)
        XCTAssertTrue(storage.segments[0].isVerified)
    }

    func testCommitPersistsCoverageAfterRowsAndProjectsLegacyOneWay() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-commit")
        let page = try validatedPage(request: request, primaryIDs: ["p20", "p10"])

        let result = try await repository.commit(
            page,
            request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-commit")
        )

        guard case .verified(let snapshot) = result else {
            return XCTFail("Expected verified repository commit")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p10", "p20"])
        XCTAssertEqual(snapshot.coverageGeneration, 1)

        let realm = try await Realm(configuration: configuration)
        let primary = ConversationArchiveCoverageStorageItem.genPrimary(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )
        let storage = try XCTUnwrap(
            realm.object(ofType: ConversationArchiveCoverageStorageItem.self, forPrimaryKey: primary)
        )
        XCTAssertEqual(storage.segments.count, 1)
        XCTAssertTrue(storage.segments[0].isVerified)
        XCTAssertEqual(storage.lastObservedXEPSYNCFingerprint, "session:1")
        XCTAssertEqual(storage.coverageGeneration, 1)
        XCTAssertTrue(
            realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: primary
            )?.newerLiveEdgeReached == true
        )
    }

    func testNewSessionCommitReplacesStaleSessionCoverageInsteadOfAccumulatingIt() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()

        let firstRequest = makeRequest(
            queryID: "q-session-one",
            connectionGeneration: 1
        )
        _ = try await repository.commit(
            validatedPage(
                request: firstRequest,
                primaryIDs: ["p20", "p10"]
            ),
            request: firstRequest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: firstRequest.queryID
            )
        )

        let secondRequest = makeRequest(
            queryID: "q-session-two",
            connectionGeneration: 2
        )
        _ = try await repository.commit(
            validatedPage(
                request: secondRequest,
                primaryIDs: ["p20", "p10"]
            ),
            request: secondRequest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 2,
                queryID: secondRequest.queryID
            )
        )

        let realm = try await Realm(configuration: configuration)
        realm.refresh()
        let storage = try XCTUnwrap(
            realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: conversation.owner,
                    jid: conversation.jid,
                    conversationType: conversation.conversationType
                )
            )
        )
        XCTAssertEqual(storage.archiveFreshnessFingerprint, "session:2")
        XCTAssertEqual(storage.segments.count, 1)
        XCTAssertEqual(
            Set(storage.segments.map(\.fingerprint)),
            Set(["session:2"])
        )
    }

    func testOlderCommitReturnsOneMergedVerifiedWindowAroundBoundary() async throws {
        for archivedID in ["20", "50", "100", "200"] {
            try persistMessage(primary: "p\(archivedID)", archivedID: archivedID)
        }
        let repository = makeRepository()
        let latestRequest = makeRequest(queryID: "q-latest")
        let latestPage = try ArchiveTransportReceiptValidator.validate(
            ArchiveTransportReceipt(
                queryID: latestRequest.queryID,
                connectionGeneration: latestRequest.connectionGeneration,
                resultArchiveIDs: ["200", "100"],
                messagePrimaryIDs: ["p200", "p100"],
                first: "200",
                last: "100",
                complete: false,
                cheapPageCount: 2,
                deliveredResultCount: 2,
                persistedResultCount: 2,
                intentionallyConsumedResultCount: 0,
                failedPersistenceCount: 0,
                finalReceived: true
            ),
            for: latestRequest
        )
        _ = try await repository.commit(
            latestPage,
            request: latestRequest,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-latest")
        )

        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let olderRequest = ArchiveTransportRequest(
            queryID: "q-older",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 1,
            pageSize: 100,
            contextBefore: 2,
            contextAfter: 2,
            proofFingerprint: "session:1",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let olderPage = try ArchiveTransportReceiptValidator.validate(
            ArchiveTransportReceipt(
                queryID: olderRequest.queryID,
                connectionGeneration: olderRequest.connectionGeneration,
                resultArchiveIDs: ["50", "20"],
                messagePrimaryIDs: ["p50", "p20"],
                first: "50",
                last: "20",
                complete: true,
                cheapPageCount: 2,
                deliveredResultCount: 2,
                persistedResultCount: 2,
                intentionallyConsumedResultCount: 0,
                failedPersistenceCount: 0,
                finalReceived: true
            ),
            for: olderRequest
        )

        let result = try await repository.commit(
            olderPage,
            request: olderRequest,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-older")
        )

        guard case .verified(let snapshot) = result else {
            return XCTFail("Expected one verified merged window")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p20", "p50", "p100", "p200"])
        XCTAssertEqual(snapshot.verifiedSegment.oldest.rawValue, "20")
        XCTAssertEqual(snapshot.verifiedSegment.newest.rawValue, "200")
        XCTAssertTrue(snapshot.verifiedSegment.reachesArchiveStart)
        XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)
    }

    func testCompletedEmptyOlderPageMarksVerifiedArchiveStartWithoutDroppingBoundary() async throws {
        for archivedID in ["100", "200"] {
            try persistMessage(primary: "p\(archivedID)", archivedID: archivedID)
        }
        let repository = makeRepository()
        let latestRequest = makeRequest(queryID: "q-empty-edge-latest")
        _ = try await repository.commit(
            ArchiveTransportReceiptValidator.validate(
                receipt(
                    request: latestRequest,
                    archiveIDs: ["200", "100"],
                    primaryIDs: ["p200", "p100"],
                    complete: false
                ),
                for: latestRequest
            ),
            request: latestRequest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: latestRequest.queryID
            )
        )

        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let olderRequest = ArchiveTransportRequest(
            queryID: "q-empty-older-edge",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 1,
            pageSize: 100,
            contextBefore: 100,
            contextAfter: 0,
            proofFingerprint: "session:1",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let emptyPage = try ArchiveTransportReceiptValidator.validate(
            receipt(
                request: olderRequest,
                archiveIDs: [],
                primaryIDs: [],
                complete: true
            ),
            for: olderRequest
        )

        let result = try await repository.commit(
            emptyPage,
            request: olderRequest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: olderRequest.queryID
            )
        )

        guard case .verified(let snapshot) = result else {
            return XCTFail("Expected the empty completed boundary to update current proof")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p100"])
        XCTAssertEqual(snapshot.verifiedSegment.oldest, boundary)
        XCTAssertEqual(snapshot.verifiedSegment.newest.rawValue, "200")
        XCTAssertTrue(snapshot.verifiedSegment.reachesArchiveStart)
        XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)

        let realm = try await Realm(configuration: configuration)
        realm.refresh()
        let storage = try XCTUnwrap(
            realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: conversation.owner,
                    jid: conversation.jid,
                    conversationType: conversation.conversationType
                )
            )
        )
        XCTAssertEqual(storage.segments.count, 1)
        XCTAssertTrue(storage.segments[0].reachesArchiveStart)
    }

    func testCompletedEmptyNewerPageMarksVerifiedLiveEdgeWithoutDroppingBoundary() async throws {
        for archivedID in ["100", "200"] {
            try persistMessage(primary: "p\(archivedID)", archivedID: archivedID)
        }
        let oldest = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let newest = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let storage = ConversationArchiveCoverageStorageItem.ensure(
                key: conversation,
                in: realm
            )
            storage.archiveFreshnessFingerprint = "session:1"
            storage.coverageGeneration = 1
            storage.segments = [try XCTUnwrap(ArchiveCoverageSegment(
                oldest: oldest,
                newest: newest,
                reachesArchiveStart: true,
                reachesLiveEdge: false,
                fingerprint: "session:1",
                isVerified: true
            ))]
        }

        let newerRequest = ArchiveTransportRequest(
            queryID: "q-empty-newer-edge",
            conversation: conversation,
            locator: .newer(after: newest),
            connectionGeneration: 1,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 100,
            proofFingerprint: "session:1",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let emptyPage = try ArchiveTransportReceiptValidator.validate(
            receipt(
                request: newerRequest,
                archiveIDs: [],
                primaryIDs: [],
                complete: true
            ),
            for: newerRequest
        )

        let result = try await makeRepository().commit(
            emptyPage,
            request: newerRequest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: newerRequest.queryID
            )
        )

        guard case .verified(let snapshot) = result else {
            return XCTFail("Expected the empty completed boundary to update current proof")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p200"])
        XCTAssertTrue(snapshot.verifiedSegment.reachesArchiveStart)
        XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)
        realm.refresh()
        let storage = try XCTUnwrap(
            realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: conversation.owner,
                    jid: conversation.jid,
                    conversationType: conversation.conversationType
                )
            )
        )
        XCTAssertTrue(storage.segments[0].reachesLiveEdge)
    }

    func testExactTargetBecomesCoverageOnlyAfterOlderAndNewerProofs() async throws {
        for archivedID in ["80", "90", "100", "110", "120"] {
            try persistMessage(primary: "p\(archivedID)", archivedID: archivedID)
        }
        let target = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let intent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .archiveID(target),
            contextBefore: 30,
            contextAfter: 30,
            priority: .target
        )
        let exactRequest = ArchiveTransportRequest(
            queryID: "q-exact",
            conversation: conversation,
            locator: intent.locator,
            connectionGeneration: 1,
            pageSize: 60,
            contextBefore: 30,
            contextAfter: 30,
            proofFingerprint: "session:1",
            isUnfiltered: false,
            producesContinuousCoverage: false
        )
        let exactPage = try ArchiveTransportReceiptValidator.validate(
            receipt(
                request: exactRequest,
                archiveIDs: ["100"],
                primaryIDs: ["p100"],
                complete: true
            ),
            for: exactRequest
        )
        let repository = makeRepository()
        let materialized = try await repository.commit(
            exactPage,
            request: exactRequest,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-exact")
        )
        XCTAssertEqual(materialized, .materializedWithoutCoverage)

        let olderRequest = directionalRequest(
            queryID: "q-anchor-older",
            locator: .older(before: target),
            fingerprint: "session:1"
        )
        let newerRequest = directionalRequest(
            queryID: "q-anchor-newer",
            locator: .newer(after: target),
            fingerprint: "session:1"
        )
        let olderPage = try ArchiveTransportReceiptValidator.validate(
            receipt(
                request: olderRequest,
                archiveIDs: ["90", "80"],
                primaryIDs: ["p90", "p80"],
                complete: true
            ),
            for: olderRequest
        )
        let newerPage = try ArchiveTransportReceiptValidator.validate(
            receipt(
                request: newerRequest,
                archiveIDs: ["120", "110"],
                primaryIDs: ["p120", "p110"],
                complete: true
            ),
            for: newerRequest
        )
        let anchor = try await repository.materializedAnchor(
            conversation: conversation,
            locator: intent.locator,
            candidateArchiveIDs: exactPage.chronologicalArchiveIDs
        )

        let snapshot = try await repository.commitAnchorWindow(
            intent: intent,
            anchor: try XCTUnwrap(anchor),
            exactPage: exactPage,
            olderPage: olderPage,
            newerPage: newerPage,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-anchor-context")
        )

        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p80", "p90", "p100", "p110", "p120"])
        XCTAssertEqual(snapshot.verifiedSegment.oldest.rawValue, "80")
        XCTAssertEqual(snapshot.verifiedSegment.newest.rawValue, "120")
        XCTAssertTrue(snapshot.verifiedSegment.reachesArchiveStart)
        XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)
    }

    func testPersistedLiveMessageExtendsProofButMaterializesOnlyRequestedLiveRow() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-live-base")
        _ = try await repository.commit(
            validatedPage(request: request, primaryIDs: ["p20", "p10"]),
            request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-live-base")
        )
        try persistMessage(primary: "p30", archivedID: "30")
        let intent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: 1,
            contextAfter: 0,
            priority: .visibleIntegrity
        )

        let snapshot = try await repository.extendLiveEdge(
            for: intent,
            primaryID: "p30",
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "live-message-30")
        )

        XCTAssertEqual(snapshot?.messagePrimaryIDs, ["p30"])
        XCTAssertEqual(snapshot?.verifiedSegment.oldest.rawValue, "10")
        XCTAssertEqual(snapshot?.verifiedSegment.newest.rawValue, "30")
        XCTAssertTrue(snapshot?.verifiedSegment.reachesLiveEdge == true)
    }

    func testLiveMessageCannotExtendCoverageWithStaleFingerprint() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-live-stale")
        _ = try await repository.commit(
            validatedPage(request: request, primaryIDs: ["p20", "p10"]),
            request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "q-live-stale")
        )
        try persistMessage(primary: "p30", archivedID: "30")

        let snapshot = try await repository.extendLiveEdge(
            for: ArchiveWindowIntent(
                conversation: conversation,
                locator: .latest,
                contextBefore: 80,
                contextAfter: 0,
                priority: .visibleIntegrity
            ),
            primaryID: "p30",
            freshnessToken: .sessionMAM(connectionGeneration: 2, queryID: "stale-live-message-30")
        )

        XCTAssertNil(snapshot)
    }

    func testAuthoritativeEmptyIsDurableForMatchingFingerprintOnly() async throws {
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-empty", connectionGeneration: 20)
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
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
        let page = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        _ = try await repository.commit(
            page,
            request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 20, queryID: "q-empty")
        )
        let intent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: 80,
            contextAfter: 0,
            priority: .visibleIntegrity
        )

        let matching = try await repository.verifiedAdmission(
            for: intent,
            freshnessToken: .sessionMAM(connectionGeneration: 20, queryID: "empty-admission")
        )
        let stale = try await repository.verifiedAdmission(
            for: intent,
            freshnessToken: .sessionMAM(connectionGeneration: 21, queryID: "stale-empty-admission")
        )
        XCTAssertEqual(matching, .authoritativeEmpty)
        XCTAssertNil(stale)
    }

    func testMigratedProvisionalCoverageNeverAdmitsWithoutSessionMAMCommit() async throws {
        let completedStamp = "snapshot-7"
        let candidate = ArchiveSyncFingerprint(
            completedSnapshotStamp: completedStamp,
            lastArchiveID: "20",
            lastMessageID: "m20",
            unreadAfterID: "10",
            unreadCount: 2
        ).stableValue
        let oldest = ArchiveCursor(rawValue: "10")!
        let newest = ArchiveCursor(rawValue: "20")!
        let provisional = ArchiveCoverageSegment(
            oldest: oldest,
            newest: newest,
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: candidate,
            isVerified: false
        )!
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let coverage = ConversationArchiveCoverageStorageItem.ensure(key: conversation, in: realm)
            coverage.segments = [provisional]
            coverage.lastObservedXEPSYNCFingerprint = candidate
        }

        let repository = makeRepository()
        let admission = try await repository.verifiedAdmission(
            for: ArchiveWindowIntent(
                conversation: conversation,
                locator: .latest,
                contextBefore: 80,
                contextAfter: 0,
                priority: .visibleIntegrity
            ),
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: "first-session-proof"
            )
        )
        XCTAssertNil(admission)

        let verifiedRealm = try await Realm(configuration: configuration)
        verifiedRealm.refresh()
        let storage = try XCTUnwrap(
            verifiedRealm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: conversation.owner,
                    jid: conversation.jid,
                    conversationType: conversation.conversationType
                )
            )
        )
        XCTAssertFalse(storage.segments[0].isVerified)
        XCTAssertEqual(storage.segments[0].fingerprint, candidate)
        XCTAssertEqual(storage.coverageGeneration, 0)
    }

    private func makeRepository() -> RealmArchiveCoverageRepository {
        let configuration = self.configuration!
        return RealmArchiveCoverageRepository {
            try Realm(configuration: configuration)
        }
    }

    private func makeRequest(
        queryID: String,
        connectionGeneration: UInt64 = 1
    ) -> ArchiveTransportRequest {
        ArchiveTransportRequest(
            queryID: queryID,
            conversation: conversation,
            locator: .latest,
            connectionGeneration: connectionGeneration,
            pageSize: 80,
            contextBefore: 80,
            contextAfter: 0,
            proofFingerprint: "session:\(connectionGeneration)",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
    }

    private func validatedPage(
        request: ArchiveTransportRequest,
        primaryIDs: [String]
    ) throws -> ValidatedArchiveTransportPage {
        try ArchiveTransportReceiptValidator.validate(
            ArchiveTransportReceipt(
                queryID: request.queryID,
                connectionGeneration: request.connectionGeneration,
                resultArchiveIDs: ["20", "10"],
                messagePrimaryIDs: primaryIDs,
                first: "20",
                last: "10",
                complete: true,
                cheapPageCount: 2,
                deliveredResultCount: 2,
                persistedResultCount: 2,
                intentionallyConsumedResultCount: 0,
                failedPersistenceCount: 0,
                finalReceived: true
            ),
            for: request
        )
    }

    private func directionalRequest(
        queryID: String,
        locator: ArchiveWindowLocator,
        fingerprint: String
    ) -> ArchiveTransportRequest {
        ArchiveTransportRequest(
            queryID: queryID,
            conversation: conversation,
            locator: locator,
            connectionGeneration: 1,
            pageSize: 30,
            contextBefore: 30,
            contextAfter: 30,
            proofFingerprint: fingerprint,
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
    }

    private func receipt(
        request: ArchiveTransportRequest,
        archiveIDs: [String],
        primaryIDs: [String],
        complete: Bool
    ) -> ArchiveTransportReceipt {
        ArchiveTransportReceipt(
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
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )
    }

    private func persistMessage(primary: String, archivedID: String) throws {
        let realm = try Realm(configuration: configuration)
        try realm.write {
            let message = MessageStorageItem()
            message.primary = primary
            message.owner = conversation.owner
            message.opponent = conversation.jid
            message.conversationType = conversation.conversationType
            message.archivedId = archivedID
            message.messageId = "m\(archivedID)"
            message.date = Date(timeIntervalSince1970: TimeInterval(archivedID) ?? 0)
            realm.add(message, update: .modified)
        }
    }
}
