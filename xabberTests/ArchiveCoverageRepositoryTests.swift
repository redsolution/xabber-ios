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
                freshnessToken: .xepSync(fingerprint: "sync-1")
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

    func testCommitPersistsCoverageAfterRowsAndProjectsLegacyOneWay() async throws {
        try persistMessage(primary: "p10", archivedID: "10")
        try persistMessage(primary: "p20", archivedID: "20")
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-commit")
        let page = try validatedPage(request: request, primaryIDs: ["p20", "p10"])

        let result = try await repository.commit(
            page,
            request: request,
            freshnessToken: .xepSync(fingerprint: "sync-1")
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
        XCTAssertEqual(storage.lastObservedXEPSYNCFingerprint, "sync-1")
        XCTAssertEqual(storage.coverageGeneration, 1)
        XCTAssertTrue(
            realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: primary
            )?.newerLiveEdgeReached == true
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
            freshnessToken: .xepSync(fingerprint: "sync-1")
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
            proofFingerprint: "sync-1",
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
            freshnessToken: .xepSync(fingerprint: "sync-1")
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

    func testAuthoritativeEmptyIsDurableForMatchingFingerprintOnly() async throws {
        let repository = makeRepository()
        let request = makeRequest(queryID: "q-empty")
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
            freshnessToken: .xepSync(fingerprint: "sync-empty")
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
            freshnessToken: .xepSync(fingerprint: "sync-empty")
        )
        let stale = try await repository.verifiedAdmission(
            for: intent,
            freshnessToken: .xepSync(fingerprint: "sync-other")
        )
        XCTAssertEqual(matching, .authoritativeEmpty)
        XCTAssertNil(stale)
    }

    func testProvisionalCoverageActivatesOnlyForExactReconstructedSyncFingerprint() async throws {
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
            let chat = LastChatsStorageItem()
            chat.owner = conversation.owner
            chat.jid = conversation.jid
            chat.conversationType = conversation.conversationType
            chat.primary = LastChatsStorageItem.genPrimary(
                jid: conversation.jid,
                owner: conversation.owner,
                conversationType: conversation.conversationType
            )
            chat.syncSnapshotLastArchiveId = "20"
            chat.lastMessageId = "m20"
            chat.syncUnreadAfterId = "10"
            chat.syncUnreadCount = 2
            realm.add(chat, update: .modified)
        }

        let repository = makeRepository()
        try await repository.verifyProvisionalCoverage(
            owner: conversation.owner,
            fingerprint: completedStamp
        )

        let verifiedRealm = try await Realm(configuration: configuration)
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
        XCTAssertTrue(storage.segments[0].isVerified)
        XCTAssertEqual(storage.segments[0].fingerprint, completedStamp)
    }

    private func makeRepository() -> RealmArchiveCoverageRepository {
        let configuration = self.configuration!
        return RealmArchiveCoverageRepository {
            try Realm(configuration: configuration)
        }
    }

    private func makeRequest(queryID: String) -> ArchiveTransportRequest {
        ArchiveTransportRequest(
            queryID: queryID,
            conversation: conversation,
            locator: .latest,
            connectionGeneration: 1,
            pageSize: 80,
            contextBefore: 80,
            contextAfter: 0,
            proofFingerprint: "sync-1",
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
