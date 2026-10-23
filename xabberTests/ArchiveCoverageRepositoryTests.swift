import XCTest
import RealmSwift
import XMPPFramework
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
        ChatArchiveDebugTrace.resetTestingConfiguration()
        retainedRealm = nil
        configuration = nil
        super.tearDown()
    }


    func testOpaquePagePersistsServerOrderAndMembershipWithoutDateOrIDSorting() async throws {
        let repository = makeRepository()
        var request = makeRequest(queryID: "opaque-order")
        request.usesFlippedPage = false
        for (primary, id) in [("p-z", "z"), ("p-2", "2"), ("p-a", "a")] {
            try persistMessage(primary: primary, archivedID: id)
        }
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: ["z", "2", "a"], primaryIDs: ["p-z", "p-2", "p-a"], complete: true), for: request)
        let result = try await repository.commit(page, request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: request.queryID))
        guard case .verified(let snapshot) = result else { return XCTFail("Expected opaque ordered proof") }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p-z", "p-2", "p-a"])
        XCTAssertEqual(snapshot.verifiedSegment.orderedArchiveIDs.map(\.rawValue), ["z", "2", "a"])
        XCTAssertFalse(snapshot.verifiedSegment.contains(ArchiveCursor(rawValue: "5")!))
    }

    func testMaterializationAndCoverageKeepCanonicallyEquivalentUIDsDistinct() async throws {
        let ids = ["caf\u{00E9}", "cafe\u{0301}"]
        let primaries = ["p-composed", "p-decomposed"]
        for (primary, id) in zip(primaries, ids) {
            try persistMessage(primary: primary, archivedID: id)
        }
        let repository = makeRepository()
        let materialized = try await repository.materializedMessages(conversation: conversation, archiveIDs: ids)
        XCTAssertEqual(materialized.map(\.primaryID), primaries)
        XCTAssertEqual(materialized.map { Array($0.archiveID.utf8) }, ids.map { Array($0.utf8) })

        var request = makeRequest(queryID: "unicode-materialization")
        request.usesFlippedPage = false
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: ids, primaryIDs: primaries, complete: true), for: request)
        let token = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: request.queryID)
        let result = try await repository.commit(page, request: request, freshnessToken: token)
        guard case .verified(let snapshot) = result else { return XCTFail("Expected exact UID coverage") }
        XCTAssertEqual(snapshot.messagePrimaryIDs, primaries)
        XCTAssertEqual(snapshot.verifiedSegment.orderedArchiveIDs.map { Array($0.rawValue.utf8) },
            ids.map { Array($0.utf8) })
        let anchor = try await repository.materializedAnchor(conversation: conversation,
            locator: .archiveID(ArchiveCursor(rawValue: ids[1])!), candidateArchiveIDs: ids)
        XCTAssertEqual(anchor?.primaryID, primaries[1])
    }

    func testSuccessfulEmptyUnknownPageIsNoProgressWithoutCoverageOrFalseEmpty() async throws {
        let repository = makeRepository()
        let request = makeRequest(queryID: "opaque-no-progress")
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: [], primaryIDs: [], complete: false), for: request)
        let result = try await repository.commit(page, request: request,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: request.queryID))
        XCTAssertEqual(result, .noProgress)
        let realm = try await Realm(configuration: configuration)
        XCTAssertTrue(realm.objects(ConversationArchiveCoverageStorageItem.self).isEmpty)
    }


    func testConflictingOpaqueOrderDoesNotReplacePreviouslyCommittedProof() async throws {
        let repository = makeRepository()
        var request = makeRequest(queryID: "opaque-consistent")
        request.usesFlippedPage = false
        for (primary, id) in [("p-z", "z"), ("p-2", "2"), ("p-a", "a")] {
            try persistMessage(primary: primary, archivedID: id)
        }
        let token = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: request.queryID)
        let first = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: ["z", "2", "a"], primaryIDs: ["p-z", "p-2", "p-a"], complete: true), for: request)
        _ = try await repository.commit(first, request: request, freshnessToken: token)
        let conflicting = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: ["2", "z", "a"], primaryIDs: ["p-2", "p-z", "p-a"], complete: true), for: request)
        do {
            _ = try await repository.commit(conflicting, request: request, freshnessToken: token)
            XCTFail("A contradictory page cannot replace server order")
        } catch {
            XCTAssertEqual(error as? ArchiveCoverageRepositoryError, .persistedMessageIdentityMismatch)
        }
        let realm = try await Realm(configuration: configuration)
        let stored = try XCTUnwrap(realm.objects(ConversationArchiveCoverageStorageItem.self).first)
        XCTAssertEqual(stored.coverageGeneration, 1)
        XCTAssertEqual(stored.segments.first?.orderedArchiveIDs.map(\.rawValue), ["z", "2", "a"])
    }

    func testCorruptCoverageMetadataCannotBeAdmittedAsAnEmptyArchive() async throws {
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let stored = ConversationArchiveCoverageStorageItem.ensure(key: conversation, in: realm)
            stored.archiveFreshnessFingerprint = "session:1"
            stored.coverageGeneration = 1
            stored.segmentsJSON = "{broken"
        }
        let admission = try await makeRepository().verifiedAdmission(for: currentTailIntent(.latest),
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "read-corruption"))
        XCTAssertNil(admission)
    }


    func testLatestLargeLedgerMaterializesOnlyItsBoundedEightyRowWindow() async throws {
        let probe = ArchiveMaterializationProbe()
        let configuration = self.configuration!
        let repository = RealmArchiveCoverageRepository(realmProvider: { try Realm(configuration: configuration) },
            materializationBatchObserver: { probe.record(ids: $0, rows: $1) })
        let ids = (0..<100_000).map { ArchiveCursor(rawValue: "opaque/" + String($0))! }
        let segment = try XCTUnwrap(ArchiveCoverageSegment(orderedArchiveIDs: ids,
            reachesArchiveStart: true, reachesLiveEdge: true, fingerprint: "session:1", isVerified: true))
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let storage = ConversationArchiveCoverageStorageItem.ensure(key: conversation, in: realm)
            storage.archiveFreshnessFingerprint = "session:1"
            storage.coverageGeneration = 1
            storage.segments = [segment]
            for index in Array(99_920..<100_000) + [0, 1] {
                let message = MessageStorageItem()
                message.primary = "p/" + String(index)
                message.owner = conversation.owner
                message.opponent = conversation.jid
                message.conversationType = conversation.conversationType
                message.mamArchiveId = ids[index].rawValue
                message.date = Date(timeIntervalSince1970: Double(100_000 - index))
                realm.add(message)
            }
        }
        let admission = try await repository.verifiedAdmission(for: currentTailIntent(.latest),
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "large-ledger"))
        guard case .verified(let snapshot) = admission else { return XCTFail("Expected bounded persisted admission") }
        XCTAssertEqual(snapshot.messagePrimaryIDs, (99_920..<100_000).map { "p/" + String($0) })
        XCTAssertEqual(probe.batches.map(\.ids), [80])
        XCTAssertEqual(probe.batches.map(\.rows), [80])
    }

    func testSparseOpaqueLedgerScansBoundedBatchesWithoutDroppingVisibleRows() async throws {
        let probe = ArchiveMaterializationProbe()
        let configuration = self.configuration!
        let repository = RealmArchiveCoverageRepository(realmProvider: { try Realm(configuration: configuration) },
            materializationBatchObserver: { probe.record(ids: $0, rows: $1) })
        let ids = (0..<240).map { ArchiveCursor(rawValue: "opaque/" + String($0))! }
        let segment = try XCTUnwrap(ArchiveCoverageSegment(orderedArchiveIDs: ids,
            reachesArchiveStart: true, reachesLiveEdge: true, fingerprint: "session:1", isVerified: true))
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let storage = ConversationArchiveCoverageStorageItem.ensure(key: conversation, in: realm)
            storage.archiveFreshnessFingerprint = "session:1"
            storage.coverageGeneration = 1
            storage.segments = [segment]
            for index in [1, 119, 160, 220] {
                let message = MessageStorageItem()
                message.primary = "p/" + String(index)
                message.owner = conversation.owner
                message.opponent = conversation.jid
                message.conversationType = conversation.conversationType
                message.mamArchiveId = ids[index].rawValue
                message.isDeleted = index == 220
                realm.add(message)
            }
        }
        let intent = ArchiveWindowIntent(conversation: conversation, locator: .latest,
            contextBefore: 2, contextAfter: 0, priority: .visibleIntegrity)
        let admission = try await repository.verifiedAdmission(for: intent,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "sparse-ledger"))
        guard case .verified(let snapshot) = admission else { return XCTFail("Expected sparse visible admission") }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p/119", "p/160"])
        XCTAssertTrue(probe.batches.allSatisfy { $0.ids <= 100 && $0.rows <= 100 })
        XCTAssertLessThan(probe.batches.reduce(0) { $0 + $1.rows }, 10)
    }

    func testMissingPersistedRowsEmitExactUnsampledCommitDiagnostic() async throws {
        var traceLines: [String] = []
        ChatArchiveDebugTrace.configureForTesting(
            enabled: true,
            sampleEvery: 100,
            sink: { traceLines.append($0) }
        )
        let repository = makeRepository()
        let request = makeRequest(queryID: "private-query-missing-rows")
        let page = try validatedPage(
            request: request,
            primaryIDs: ["private-primary-20", "private-primary-10"]
        )

        do {
            _ = try await repository.commit(
                page,
                request: request,
                freshnessToken: .sessionMAM(
                    connectionGeneration: 1,
                    queryID: request.queryID
                )
            )
            XCTFail("Coverage must reject a page whose primary rows are absent")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCoverageRepositoryError,
                .missingPersistedMessages
            )
        }

        let rejection = try XCTUnwrap(
            traceLines.first {
                $0.contains("event=archiveCoverageCommitRejected")
            }
        )
        XCTAssertTrue(rejection.contains("reasonCode=1"))
        XCTAssertTrue(rejection.contains("pagePrimaryCount=2"))
        XCTAssertTrue(rejection.contains("uniquePagePrimaryCount=2"))
        XCTAssertTrue(rejection.contains("persistedRowCount=0"))
        XCTAssertTrue(rejection.contains("queryId=private-query-missing-rows"))
        XCTAssertTrue(rejection.contains("jid=juliet@example.org"))
        XCTAssertFalse(rejection.contains("private-primary"))
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

    func testMaterializedMessagesRequireMAMResultID() async throws {
        try persistMessage(primary: "p200", archivedID: "100", mamArchiveID: "200")
        try persistMessage(primary: "legacy-p300", archivedID: "300", mamArchiveID: "")
        let repository = makeRepository()

        let materialized = try await repository.materializedMessages(
            conversation: conversation,
            archiveIDs: ["200", "300"]
        )

        XCTAssertEqual(
            materialized,
            [
                ArchiveMaterializedMessageIdentity(archiveID: "200", primaryID: "p200")
            ]
        )
    }

    func testMaterializedMessagesIgnoreLegacyRawRowThatCollidesWithMAMResultID() async throws {
        try persistMessage(primary: "legacy-p200", archivedID: "200", mamArchiveID: "")
        try persistMessage(primary: "replayed-p200", archivedID: "100", mamArchiveID: "200")

        let materialized = try await makeRepository().materializedMessages(
            conversation: conversation,
            archiveIDs: ["200"]
        )

        XCTAssertEqual(
            materialized,
            [
                ArchiveMaterializedMessageIdentity(
                    archiveID: "200",
                    primaryID: "replayed-p200"
                )
            ]
        )
    }

    func testCommitRejectsLegacyRawArchiveIDWithoutMAMResultID() async throws {
        try persistMessage(primary: "legacy-p20", archivedID: "20", mamArchiveID: "")
        try persistMessage(primary: "p10", archivedID: "10", mamArchiveID: "10")
        let request = makeRequest(queryID: "q-legacy-raw-id")
        let page = try validatedPage(
            request: request,
            primaryIDs: ["legacy-p20", "p10"]
        )

        do {
            _ = try await makeRepository().commit(
                page,
                request: request,
                freshnessToken: .sessionMAM(
                    connectionGeneration: request.connectionGeneration,
                    queryID: request.queryID
                )
            )
            XCTFail("A raw protocol stanza ID cannot authorize MAM coverage")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCoverageRepositoryError,
                .malformedPersistedArchiveID
            )
        }
    }

    func testCommitUsesMAMResultIDsWhenProtocolStanzaIDsDiffer() async throws {
        try persistMessage(primary: "p20", archivedID: "100", mamArchiveID: "20")
        try persistMessage(primary: "p10", archivedID: "50", mamArchiveID: "10")
        let request = makeRequest(queryID: "q-mam-result-identity")
        let page = try validatedPage(request: request, primaryIDs: ["p20", "p10"])

        let result = try await makeRepository().commit(
            page,
            request: request,
            freshnessToken: .sessionMAM(
                connectionGeneration: request.connectionGeneration,
                queryID: request.queryID
            )
        )

        guard case .verified(let snapshot) = result else {
            return XCTFail("Expected MAM result IDs to satisfy the coverage proof")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p10", "p20"])
        XCTAssertEqual(snapshot.verifiedSegment.oldest.rawValue, "10")
        XCTAssertEqual(snapshot.verifiedSegment.newest.rawValue, "20")
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
                isVerified: true,
                orderedArchiveIDs: [oldest, newest]
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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

    func testLatestAdmissionRejectsStaleLiveEdgeWhenNewerDurableMAMRowExists() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-live-edge-before-detach")
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: request.connectionGeneration,
            queryID: request.queryID
        )
        _ = try await repository.commit(
            validatedPage(request: request, primaryIDs: ["p20", "p10"]),
            request: request,
            freshnessToken: freshnessToken
        )

        // Models a MAM-backed row persisted while no chat presentation is
        // attached, so the previously proven live edge was not extended.
        try persistMessage(primary: "p30", archivedID: "30")
        let tailRealm = try await Realm(configuration: configuration)
        try tailRealm.write {
            let chat = LastChatsStorageItem()
            chat.owner = conversation.owner
            chat.jid = conversation.jid
            chat.conversationType = conversation.conversationType
            chat.primary = LastChatsStorageItem.genPrimary(jid: conversation.jid,
                owner: conversation.owner, conversationType: conversation.conversationType)
            chat.lastMessage = tailRealm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p30")
            chat.lastMessageId = "m30"
            tailRealm.add(chat, update: .modified)
        }

        let admission = try await repository.verifiedAdmission(
            for: ArchiveWindowIntent(
                conversation: conversation,
                locator: .latest,
                contextBefore: 80,
                contextAfter: 0,
                priority: .visibleIntegrity
            ),
            freshnessToken: freshnessToken
        )

        XCTAssertNil(
            admission,
            "A newer durable MAM cursor must force a fresh latest request"
        )
    }

    func testLatestAdmissionRequiresFreshMAMForCurrentNormallyPersistedLiveTail() async throws {
        let repository = makeRepository()
        let token = try await seedCurrentTailCoverage(repository)
        let primary = try persistNormalLiveTail()
        let before = try await repository.verifiedAdmission(
            for: currentTailIntent(.latest), freshnessToken: token
        )
        XCTAssertNil(before, "A server-accepted current live tail must invalidate the cached latest page")

        let realm = try await Realm(configuration: configuration)
        realm.refresh()
        let live = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual(live.archivedId, "opaque-delivery-reference")
        XCTAssertEqual(live.mamArchiveId, "", "A raw stanza reference cannot become a MAM cursor")
        XCTAssertEqual(realm.object(ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversation.jid,
                owner: conversation.owner, conversationType: conversation.conversationType))?.lastMessage?.primary,
            primary, "Use the current tail produced by ordinary message persistence")

        let request = makeRequest(queryID: "q-current-live-tail-owned-MAM")
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: ["30", "20", "10"], primaryIDs: [primary, "p20", "p10"], complete: true), for: request)
        // The normal MAM projection reconciles the actual outer result identity
        // before the validated transport page can commit archive membership.
        try realm.write {
            let projection = MessageStorageItem()
            projection.owner = live.owner
            projection.opponent = live.opponent
            projection.conversationType = live.conversationType
            projection.messageId = live.messageId
            projection.date = live.date
            projection.sentDate = live.sentDate
            projection.shouldReconcileMAMArchiveIdentity = true
            projection.mamArchiveId = "30"
            _ = projection.applyMessagePersistence(in: realm, silentNotifications: true)
        }
        _ = try await repository.commit(page, request: request, freshnessToken: token)
        let after = try await repository.verifiedAdmission(
            for: currentTailIntent(.latest), freshnessToken: token
        )
        guard case .verified(let snapshot) = after else {
            return XCTFail("Only the fresh owned archive page should restore latest admission")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p10", "p20", primary])
        XCTAssertEqual(snapshot.verifiedSegment.newest.rawValue, "30")
    }

    func testFirstUnreadWithoutBoundaryRejectsCachedPageMissingCurrentLiveTail() async throws {
        let repository = makeRepository()
        let token = try await seedCurrentTailCoverage(repository)
        _ = try persistNormalLiveTail()
        let admission = try await repository.verifiedAdmission(
            for: currentTailIntent(.firstUnread(after: nil)), freshnessToken: token
        )
        XCTAssertNil(admission)
    }

    func testAuthoritativeEmptyCannotReadmitAfterCurrentNormallyPersistedLiveTail() async throws {
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-empty-before-normal-live-tail")
        let token = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: request.queryID)
        let page = try ArchiveTransportReceiptValidator.validate(receipt(request: request,
            archiveIDs: [], primaryIDs: [], complete: true), for: request)
        _ = try await repository.commit(page, request: request, freshnessToken: token)
        _ = try persistNormalLiveTail()
        let admission = try await repository.verifiedAdmission(
            for: currentTailIntent(.latest), freshnessToken: token
        )
        XCTAssertNil(admission, "The old empty proof cannot suppress a new durable current live tail")
    }

    func testCurrentTailInvalidationIgnoresOlderNonTailAndUnacknowledgedOrInvisibleRows() async throws {
        let repository = makeRepository()
        let token = try await seedCurrentTailCoverage(repository)
        _ = try persistNormalLiveTail(originID: "older-live", stamp: "1970-01-01T00:00:15Z")
        try await assertCurrentTailAdmission(repository, token: token, context: "older non-tail")

        _ = try persistNormalLiveTail(originID: "pending-outgoing", rawReference: nil) {
            $0.outgoing = true
            $0.state = .sending
        }
        try await assertCurrentTailAdmission(repository, token: token, context: "unacknowledged pending tail")

        let hidden = try persistNormalLiveTail(originID: "hidden-live")
        try mutateTail(hidden) { $0.isLocallyHiddenByReport = true }
        try await assertCurrentTailAdmission(repository, token: token, context: "hidden tail")

        let deleted = try persistNormalLiveTail(originID: "deleted-live")
        try mutateTail(deleted) { $0.isDeleted = true }
        try await assertCurrentTailAdmission(repository, token: token, context: "deleted tail")

        let tombstoned = try persistNormalLiveTail(originID: "tombstoned-live")
        try mutateTail(tombstoned) { $0.deleteState = .autoDeleted }
        try await assertCurrentTailAdmission(repository, token: token, context: "nonvisible tombstone tail")

        let expired = try persistNormalLiveTail(originID: "expired-live")
        try mutateTail(expired) { $0.autoDeleteExpiresAt = 1 }
        try await assertCurrentTailAdmission(repository, token: token, context: "operationally expired tail")

        for field in ["owner", "opponent", "conversationType"] {
            let foreign = try persistNormalLiveTail(originID: "wrong-\(field)")
            try mutateTail(foreign) {
                switch field {
                case "owner": $0.owner = "other-owner@example.org"
                case "opponent": $0.opponent = "other-peer@example.org"
                default: $0.conversationType = .omemo
                }
            }
            try await assertCurrentTailAdmission(repository, token: token, context: "wrong \(field)")
        }
    }

    private func currentTailIntent(_ locator: ArchiveWindowLocator) -> ArchiveWindowIntent {
        ArchiveWindowIntent(conversation: conversation, locator: locator,
            contextBefore: 80, contextAfter: 0, priority: .visibleIntegrity)
    }

    private func seedCurrentTailCoverage(_ repository: RealmArchiveCoverageRepository) async throws -> ArchiveFreshnessToken {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let request = makeRequest(queryID: "q-proven-before-live-tail")
        let token = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: request.queryID)
        _ = try await repository.commit(validatedPage(request: request, primaryIDs: ["p20", "p10"]),
            request: request, freshnessToken: token)
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            let chat = LastChatsStorageItem()
            chat.owner = conversation.owner
            chat.jid = conversation.jid
            chat.conversationType = conversation.conversationType
            chat.primary = LastChatsStorageItem.genPrimary(jid: conversation.jid,
                owner: conversation.owner, conversationType: conversation.conversationType)
            chat.lastMessage = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p20")
            chat.lastMessageId = "m20"
            realm.add(chat, update: .modified)
        }
        return token
    }

    private func persistNormalLiveTail(originID: String = "normal-live-tail",
        rawReference: String? = "opaque-delivery-reference", stamp: String = "1970-01-01T00:00:30Z",
        configure: (MessageStorageItem) -> Void = { _ in }) throws -> String {
        let reference = rawReference.map {
            "<stanza-id xmlns='urn:xmpp:sid:0' by='\(conversation.owner)' id='\($0)'/>"
        } ?? ""
        let wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(conversation.jid)/device' to='\(conversation.owner)' id='\(originID)' type='chat'><body>live tail</body><origin-id xmlns='urn:xmpp:sid:0' id='\(originID)'/>\(reference)<time xmlns='https://xabber.com/protocol/delivery' by='\(conversation.owner)' stamp='\(stamp)'/></message>")
        let item = MessageStorageItem()
        item.configureIncomingMessage(wire, owner: conversation.owner, opponent: conversation.jid,
            outgoing: false, isRead: false, date: try XCTUnwrap(getDeliveryTime(wire, owner: conversation.owner)))
        item.state = .deliver
        configure(item)
        let realm = try Realm(configuration: configuration)
        try realm.write { _ = item.applyMessagePersistence(in: realm, silentNotifications: true) }
        return item.primary
    }

    private func mutateTail(_ primary: String, _ change: (MessageStorageItem) -> Void) throws {
        let realm = try Realm(configuration: configuration)
        let item = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        try realm.write { change(item) }
    }

    private func assertCurrentTailAdmission(_ repository: RealmArchiveCoverageRepository,
        token: ArchiveFreshnessToken, context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let admission = try await repository.verifiedAdmission(
            for: currentTailIntent(.latest), freshnessToken: token
        )
        guard case .verified(let snapshot) = admission else {
            return XCTFail("Valid cached MAM proof must remain available: \(context)", file: file, line: line)
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p10", "p20"], context, file: file, line: line)
    }

    func testLegacySessionOneCoverageCannotAdmitRandomizedProcessGeneration() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let legacyRequest = makeRequest(
            queryID: "q-prior-process",
            connectionGeneration: 1
        )
        _ = try await repository.commit(
            validatedPage(request: legacyRequest, primaryIDs: ["p20", "p10"]),
            request: legacyRequest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: legacyRequest.queryID
            )
        )

        let currentGeneration = ArchiveConnectionGenerationAllocator.take()
        let admission = try await repository.verifiedAdmission(
            for: ArchiveWindowIntent(
                conversation: conversation,
                locator: .latest,
                contextBefore: 80,
                contextAfter: 0,
                priority: .visibleIntegrity
            ),
            freshnessToken: .sessionMAM(
                connectionGeneration: currentGeneration,
                queryID: "q-current-process"
            )
        )

        XCTAssertGreaterThanOrEqual(currentGeneration, UInt64(1) << 32)
        XCTAssertNil(
            admission,
            "A new process namespace must reject persisted session:1 coverage"
        )
    }

    func testLatestAdmissionIgnoresNewerMAMRowsOutsideVisibleConversationScope() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-live-edge-scoped")
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: request.connectionGeneration,
            queryID: request.queryID
        )
        _ = try await repository.commit(
            validatedPage(request: request, primaryIDs: ["p20", "p10"]),
            request: request,
            freshnessToken: freshnessToken
        )

        try persistMessage(primary: "other-conversation", archivedID: "30")
        try persistMessage(primary: "hidden", archivedID: "40")
        try persistMessage(primary: "deleted", archivedID: "50")
        let realm = try await Realm(configuration: configuration)
        try realm.write {
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "other-conversation"
            )?.opponent = "mercutio@example.org"
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "hidden"
            )?.isLocallyHiddenByReport = true
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "deleted"
            )?.isDeleted = true
        }

        let admission = try await repository.verifiedAdmission(
            for: ArchiveWindowIntent(
                conversation: conversation,
                locator: .latest,
                contextBefore: 80,
                contextAfter: 0,
                priority: .visibleIntegrity
            ),
            freshnessToken: freshnessToken
        )

        guard case .verified(let snapshot) = admission else {
            return XCTFail("Out-of-scope rows must not invalidate a current live edge")
        }
        XCTAssertEqual(snapshot.messagePrimaryIDs, ["p10", "p20"])
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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
            producesContinuousCoverage: true,
            usesFlippedPage: true
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

    private func persistMessage(
        primary: String,
        archivedID: String,
        mamArchiveID: String? = nil
    ) throws {
        let realm = try Realm(configuration: configuration)
        try realm.write {
            let message = MessageStorageItem()
            message.primary = primary
            message.owner = conversation.owner
            message.opponent = conversation.jid
            message.conversationType = conversation.conversationType
            message.archivedId = archivedID
            message.mamArchiveId = mamArchiveID ?? archivedID
            message.messageId = "m\(archivedID)"
            message.date = Date(timeIntervalSince1970: TimeInterval(archivedID) ?? 0)
            realm.add(message, update: .modified)
        }
    }
}

private final class ArchiveMaterializationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(ids: Int, rows: Int)] = []
    func record(ids: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        values.append((ids, rows))
    }
    var batches: [(ids: Int, rows: Int)] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
