import XCTest
import RealmSwift
@testable import xabber

@MainActor
final class ChatSavedPositionPresentationCacheTests: XCTestCase {
    private var realm: Realm!
    private var configuration: Realm.Configuration!
    private let owner = "owner@example.org"
    private let peer = "peer@example.org"

    override func setUp() {
        super.setUp()
        configuration = makeRealmMigrationConfiguration(scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ChatSavedPositionPresentationCacheTests.\(UUID().uuidString)")
        realm = try! Realm(configuration: configuration)
    }

    override func tearDown() {
        realm = nil
        configuration = nil
        super.tearDown()
    }

    func testColdSavedWindowUsesDurableExactCoverageWithoutGrantingNewSessionAuthority() async throws {
        let request = try seed()
        let storage = try XCTUnwrap(realm.objects(ConversationArchiveCoverageStorageItem.self).first)
        let before = storage.segmentsJSON
        let window = try XCTUnwrap(ChatSavedPositionPresentationCache.read(request: request, realm: realm))

        XCTAssertEqual(window.anchorPrimary, "p1")
        XCTAssertEqual(window.rows.map(\.primary), ["p0", "p1", "p2"])
        XCTAssertTrue(window.rows.allSatisfy(\.isFrozen))
        XCTAssertEqual(storage.segmentsJSON, before)
        XCTAssertEqual(storage.archiveFreshnessFingerprint, "session:41")
        let config = configuration!
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: config) }
        let admission = try await repository.verifiedAdmission(for: ArchiveWindowIntent(
            conversation: .init(owner: owner, jid: peer, conversationType: .regular),
            locator: .archiveID(try XCTUnwrap(ArchiveCursor(rawValue: "cursor-a"))),
            contextBefore: 30, contextAfter: 30, priority: .target),
            freshnessToken: .sessionMAM(connectionGeneration: 42, queryID: "new-launch"))
        XCTAssertNil(admission, "Cached presentation cannot manufacture a fresh MAM proof")
    }

    func testChangedSavedEdgeCannotPresentAnOldWindow() throws {
        let request = try seed()
        let chat = try XCTUnwrap(realm.objects(LastChatsStorageItem.self).first)
        try realm.write { chat.lastMessageId = "new-tail" }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testMissingUsableCoverageAndCurrentLocalIndexRetainsBlockingTarget() throws {
        let request = try seed()
        try realm.write { realm.delete(realm.objects(ConversationArchiveCoverageStorageItem.self)) }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testProvisionalCoverageWithoutCurrentLocalIndexCannotPresentSavedWindow() throws {
        let request = try seed(verified: false)
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testMissingCoveredNeighboursTrimToExactContiguousSavedRunWithoutGrantingAuthority() async throws {
        let request = try seed(ids: ["z", "gap-left", "k", "a", "y", "gap-right", "b"], anchorIndex: 3)
        let storage = try XCTUnwrap(realm.objects(ConversationArchiveCoverageStorageItem.self).first)
        let before = storage.segmentsJSON
        try realm.write {
            realm.delete(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p1")!)
            realm.delete(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p5")!)
        }

        let window = try XCTUnwrap(ChatSavedPositionPresentationCache.read(request: request, realm: realm))

        XCTAssertEqual(window.anchorPrimary, "p3")
        XCTAssertEqual(window.rows.map(\.primary), ["p2", "p3", "p4"],
            "Missing neighbours bound the presentation context; farther rows cannot cross either hole")
        XCTAssertEqual(window.rows.map(\.mamArchiveId), ["k", "a", "y"],
            "Use the verified ledger order, without sorting opaque UIDs or message dates")
        XCTAssertTrue(window.rows.allSatisfy(\.isFrozen))
        XCTAssertEqual(storage.segmentsJSON, before, "Rendering cannot rewrite durable proof across holes")
        XCTAssertEqual(storage.coverageGeneration, 7)
        let config = configuration!
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: config) }
        let admission = try await repository.verifiedAdmission(for: ArchiveWindowIntent(
            conversation: .init(owner: owner, jid: peer, conversationType: .regular),
            locator: .archiveID(try XCTUnwrap(ArchiveCursor(rawValue: "a"))),
            contextBefore: 30, contextAfter: 30, priority: .target),
            freshnessToken: .sessionMAM(connectionGeneration: 42, queryID: "new-launch"))
        XCTAssertNil(admission, "A trimmed cached presentation cannot grant this launch's archive authority")
    }

    func testDuplicateCoveredNeighbourTrimsBeforeAmbiguousUID() throws {
        let request = try seed(ids: ["z", "gap-left", "k", "a", "y", "gap-right", "b"], anchorIndex: 3)
        try addDuplicateCursor(primary: "duplicate-left", cursor: "gap-left")
        try addDuplicateCursor(primary: "duplicate-right", cursor: "gap-right")

        let window = try XCTUnwrap(ChatSavedPositionPresentationCache.read(request: request, realm: realm))

        XCTAssertEqual(window.rows.map(\.primary), ["p2", "p3", "p4"],
            "Duplicate cursor neighbours end the exact local context instead of picking a row or crossing it")
    }

    func testMissingCoveredSavedTargetRetainsBlockingTarget() throws {
        let request = try seed()
        try realm.write { realm.delete(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p1")!) }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testDuplicateSavedTargetCursorRetainsBlockingTarget() throws {
        let request = try seed()
        try addDuplicateCursor(primary: "duplicate-target", cursor: "cursor-a")
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testHiddenTargetAndWrongScopeCannotRevealCachedContent() throws {
        let request = try seed()
        let target = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p1"))
        try realm.write { target.isLocallyHiddenByReport = true }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
        try realm.write { target.isLocallyHiddenByReport = false; target.opponent = "other@example.org" }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testExplicitRouteCannotUseSavedWindowException() throws {
        let saved = try seed()
        let explicit = ChatOpenMessageRequest(chatJid: peer, owner: owner, conversationType: .regular,
            anchor: saved.anchor, highlight: false, markReadOnVisible: false, source: .search)
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: explicit, realm: realm))
    }


    func testExactEligibleSavedTargetOutsideLatestLedgerUsesReciprocalLocalIndexRenderingOnly() async throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let storage = try XCTUnwrap(realm.objects(ConversationArchiveCoverageStorageItem.self).first)
        let before = storage.segmentsJSON

        let window = try XCTUnwrap(ChatSavedPositionPresentationCache.read(request: request, realm: realm))

        XCTAssertEqual(window.anchorPrimary, "p3")
        guard case .localAdjacency(let version, let orderedPrimaries) = window.provenance else {
            return XCTFail("Local rendering must identify local provenance, without manufacturing a verified segment")
        }
        XCTAssertEqual(version, ChatLocalHistoryIndexStorageItem.currentVersion)
        XCTAssertEqual(orderedPrimaries, (0...6).map { "p\($0)" })
        XCTAssertNil(window.segment, "No archive segment can be inferred from local adjacency")
        XCTAssertEqual(window.rows.map(\.primary), (0...6).map { "p\($0)" })
        XCTAssertEqual(window.rows.map(\.mamArchiveId), ["z", "gap-left", "k", "a", "y", "gap-right", "b"],
            "Local rendering follows persisted reciprocal links; opaque UID spelling supplies no chronology")
        XCTAssertTrue(window.rows.allSatisfy(\.isFrozen))
        XCTAssertEqual(storage.segmentsJSON, before, "Do not add local links to the server-verified ledger")
        XCTAssertEqual(storage.coverageGeneration, 7)
        let config = configuration!
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: config) }
        let admission = try await repository.verifiedAdmission(for: ArchiveWindowIntent(
            conversation: .init(owner: owner, jid: peer, conversationType: .regular),
            locator: .archiveID(try XCTUnwrap(ArchiveCursor(rawValue: "a"))),
            contextBefore: 30, contextAfter: 30, priority: .target),
            freshnessToken: .sessionMAM(connectionGeneration: 42, queryID: "new-launch"))
        XCTAssertNil(admission, "Local adjacency is presentation only, never a fresh archive proof")
    }

    func testLocalSavedRenderingRejectsBrokenReciprocalNeighbour() throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let previous = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2"))
        try realm.write { previous.historyNextMessagePrimary = nil }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testLocalSavedRenderingRejectsCycleRatherThanRevisitingTarget() throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let previous = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2"))
        let target = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p3"))
        try realm.write {
            previous.historyPreviousMessagePrimary = target.primary
            target.historyNextMessagePrimary = previous.primary
        }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testLocalSavedRenderingRejectsNeighbourFromAnotherScope() throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let previous = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2"))
        try realm.write { previous.opponent = "other@example.org" }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testLocalSavedRenderingRejectsStaleIndexStateAndStaleRowVersion() throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let state = try XCTUnwrap(ChatLocalHistoryLinkedIndex.state(
            owner: owner, jid: peer, conversationType: .regular, in: realm))
        try realm.write { state.version = 0 }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
        let previous = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2"))
        try realm.write {
            state.version = ChatLocalHistoryIndexStorageItem.currentVersion
            previous.historyLinkedIndexVersion = 0
        }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    func testLocalSavedRenderingRejectsInvalidPersistedLocalOrder() throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let previous = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2"))
        try realm.write { previous.date = Date(timeIntervalSince1970: 1_000) }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm),
            "Reciprocal links alone cannot authorize a locally reversed chain")
    }

    func testLocalSavedRenderingRejectsUnreadOrChangedSavedFingerprints() throws {
        let request = try seedLocalIndexedWindowOutsideCoverage()
        let chat = try XCTUnwrap(realm.objects(LastChatsStorageItem.self).first)
        try realm.write { chat.unread = 1; chat.runtimeUnreadCount = 1 }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
        try realm.write {
            chat.unread = 0; chat.runtimeUnreadCount = 0
            chat.lastVisiblePositionSavedAtSnapshotLastArchiveId = "changed-edge"
        }
        XCTAssertNil(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
    }

    private func seedLocalIndexedWindowOutsideCoverage() throws -> ChatOpenMessageRequest {
        let ids = ["z", "gap-left", "k", "a", "y", "gap-right", "b"]
        let request = try seed(ids: ids, anchorIndex: 3)
        try realm.write {
            for i in ids.indices {
                let row = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p\(i)")!
                row.date = Date(timeIntervalSince1970: Double(i))
                row.sentDate = row.date
            }
            try ChatLocalHistoryLinkedIndex.rebuildConversation(
                owner: owner, jid: peer, conversationType: .regular, in: realm)
            let storage = realm.objects(ConversationArchiveCoverageStorageItem.self).first!
            storage.segments = [ArchiveCoverageSegment(
                orderedArchiveIDs: ids.prefix(3).map { ArchiveCursor(rawValue: $0)! },
                reachesArchiveStart: false, reachesLiveEdge: false,
                fingerprint: "session:41", isVerified: true)!]
        }
        return request
    }

    private func addDuplicateCursor(primary: String, cursor: String) throws {
        let duplicate = MessageStorageItem()
        duplicate.primary = primary; duplicate.messageId = "m-\(primary)"
        duplicate.owner = owner; duplicate.opponent = peer; duplicate.conversationType = .regular
        duplicate.mamArchiveId = cursor; duplicate.archivedId = "reference-\(primary)"
        duplicate.body = "Ambiguous cursor row"; duplicate.legacyBody = duplicate.body
        try realm.write { realm.add(duplicate) }
    }

    private func seed(
        verified: Bool = true,
        ids: [String] = ["cursor-c", "cursor-a", "cursor-z"],
        anchorIndex: Int = 1
    ) throws -> ChatOpenMessageRequest {
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            orderedArchiveIDs: ids.map { ArchiveCursor(rawValue: $0)! },
            reachesArchiveStart: false, reachesLiveEdge: false,
            fingerprint: "session:41", isVerified: verified))
        try realm.write {
            for (i, id) in ids.enumerated() {
                let row = MessageStorageItem()
                row.primary = "p\(i)"; row.messageId = "m\(i)"
                row.owner = owner; row.opponent = peer; row.conversationType = .regular
                row.archivedId = "reference-\(i)"; row.mamArchiveId = id
                row.date = Date(timeIntervalSince1970: Double(100 - i))
                row.sentDate = row.date; row.body = "Saved text \(i)"; row.legacyBody = row.body
                realm.add(row)
            }
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(jid: peer, owner: owner, conversationType: .regular)
            chat.owner = owner; chat.jid = peer; chat.conversationType = .regular
            chat.lastMessageId = "tail"; chat.syncSnapshotLastArchiveId = "tail-cursor"
            chat.lastVisibleMessagePrimary = "p\(anchorIndex)"; chat.lastVisibleMessageId = "m\(anchorIndex)"
            chat.lastVisibleMessageArchivedId = ids[anchorIndex]
            chat.lastVisibleMessageDate = Date(timeIntervalSince1970: Double(100 - anchorIndex))
            chat.lastVisiblePositionSavedAtLastMessageId = "tail"
            chat.lastVisiblePositionSavedAtSnapshotLastArchiveId = "tail-cursor"
            realm.add(chat)
            let coverage = ConversationArchiveCoverageStorageItem.ensure(key: .init(
                owner: owner, jid: peer, conversationType: .regular), in: realm)
            coverage.segments = [segment]; coverage.coverageGeneration = 7
            coverage.archiveFreshnessFingerprint = "session:41"
        }
        return ChatOpenMessageRequest(chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: "p\(anchorIndex)", archivedId: ids[anchorIndex], messageId: "m\(anchorIndex)",
                authorId: nil, bodyFingerprint: nil, sourceDate: Date(timeIntervalSince1970: Double(100 - anchorIndex))),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition)
    }
}
