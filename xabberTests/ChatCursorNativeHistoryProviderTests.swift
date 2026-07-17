import XCTest
import RealmSwift
@testable import xabber

final class ChatCursorNativeHistoryProviderTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "cursor@example.com"
    private let sharedDate = Date(timeIntervalSince1970: 1_700_200_000)

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatCursorNativeHistoryProviderTests-\(name)-\(UUID().uuidString)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testLatestUsesCompoundTieCursorBeforeApplyingCandidateLimit() throws {
        try insertSameTimestampMessages(count: 1_000)
        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()

        let items = try provider(diagnostics: diagnostics).latest(limit: 40)

        XCTAssertEqual(items.map(\.archivedId), expectedIds(960..<1_000))
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 160)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
    }

    func testOlderAndNewerRoundTripAcrossLargeSameTimestampBucket() throws {
        try insertSameTimestampMessages(count: 1_000)
        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = try provider(diagnostics: diagnostics)

        let latest = provider.latest(limit: 40)
        let latestOldest = try XCTUnwrap(latest.first)
        let older = provider.older(before: ChatTimelineBoundary(message: latestOldest), limit: 40)
        let olderNewest = try XCTUnwrap(older.last)
        let newer = provider.newer(after: ChatTimelineBoundary(message: olderNewest), limit: 40)

        XCTAssertEqual(older.map(\.archivedId), expectedIds(920..<960))
        XCTAssertEqual(newer.map(\.archivedId), expectedIds(960..<1_000))
        XCTAssertEqual(Set((older + newer).map(\.primary)).count, 80)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 160)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
    }

    func testHundredThousandSameTimestampRowsStayCursorAdjacentAndBounded() throws {
        try insertSameTimestampMessages(count: 100_000)
        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = try provider(diagnostics: diagnostics)

        let boundary = try XCTUnwrap(provider.message(
            primary: "primary-00050000",
            archivedId: nil,
            messageId: nil
        ))
        let older = provider.older(before: ChatTimelineBoundary(message: boundary), limit: 64)
        let newer = provider.newer(after: ChatTimelineBoundary(message: boundary), limit: 64)

        XCTAssertEqual(older.map(\.archivedId), expectedIds(49_936..<50_000))
        XCTAssertEqual(newer.map(\.archivedId), expectedIds(50_001..<50_065))
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 256)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
    }

    func testFixedBudgetPlanRecordsNoCountOffsetExpansionOrFullBucketOperations() throws {
        try insertSameTimestampMessages(count: 1_000)
        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = try provider(diagnostics: diagnostics)
        let boundary = ChatTimelineBoundary(
            primary: "primary-00000500",
            archivedId: "00000500",
            messageId: "message-00000500",
            date: sharedDate
        )

        _ = provider.latest(limit: 40)
        _ = provider.older(before: boundary, limit: 40)
        _ = provider.newer(after: boundary, limit: 40)

        XCTAssertEqual(diagnostics.queryCount, 3)
        XCTAssertEqual(diagnostics.countQueryCount, 0)
        XCTAssertEqual(diagnostics.offsetQueryCount, 0)
        XCTAssertEqual(diagnostics.expansionCount, 0)
        XCTAssertEqual(diagnostics.fullSameDateBucketMaterializationCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 160)
    }

    func testDirectLookupPriorityIsPrimaryThenArchiveThenMessageAndAlwaysScoped() throws {
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(makeMessage(
                primary: "primary-winner",
                archivedId: "archive-primary",
                messageId: "message-primary"
            ))
            realm.add(makeMessage(
                primary: "archive-winner",
                archivedId: "archive-fallback",
                messageId: "message-archive"
            ))
            realm.add(makeMessage(
                primary: "message-winner",
                archivedId: "archive-message",
                messageId: "message-fallback"
            ))
            let deleted = makeMessage(
                primary: "deleted",
                archivedId: "archive-deleted",
                messageId: "message-deleted"
            )
            deleted.isDeleted = true
            realm.add(deleted)
            realm.add(makeMessage(
                primary: "out-of-scope",
                archivedId: "archive-other",
                messageId: "message-other",
                opponent: "other@example.com"
            ))
        }
        let provider = try provider(diagnostics: ChatLocalHistoryPageProviderDiagnostics())

        XCTAssertEqual(provider.message(
            primary: "primary-winner",
            archivedId: "archive-fallback",
            messageId: "message-fallback"
        )?.primary, "primary-winner")
        XCTAssertEqual(provider.message(
            primary: nil,
            archivedId: "archive-fallback",
            messageId: "message-fallback"
        )?.primary, "archive-winner")
        XCTAssertEqual(provider.message(
            primary: nil,
            archivedId: nil,
            messageId: "message-fallback"
        )?.primary, "message-winner")
        XCTAssertNil(provider.message(primary: "deleted", archivedId: "archive-deleted", messageId: "message-deleted"))
        XCTAssertNil(provider.message(primary: "out-of-scope", archivedId: "archive-other", messageId: "message-other"))
    }

    func testCancelledProviderDoesNotIssueOrMaterializeQuery() throws {
        try insertSameTimestampMessages(count: 100)
        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = ChatLocalHistoryPageProvider(
            realm: try WRealm.safe(),
            owner: owner,
            jid: jid,
            conversationType: .regular,
            diagnostics: diagnostics,
            isCancelled: { true }
        )

        XCTAssertTrue(provider.latest(limit: 40).isEmpty)
        XCTAssertEqual(diagnostics.queryCount, 0)
        XCTAssertEqual(diagnostics.maxCandidateCount, 0)
    }

    func testProviderOpensAndQueriesRealmOnOwningWorkerThread() throws {
        let identifier = "ChatCursorNativeHistoryProviderTests-worker-\(UUID().uuidString)"
        let configuration = Realm.Configuration(inMemoryIdentifier: identifier)
        let retainedRealm = try Realm(configuration: configuration)
        try retainedRealm.write {
            for index in 0..<100 {
                retainedRealm.add(makeMessage(
                    primary: "worker-\(index)",
                    archivedId: formattedId(index),
                    messageId: "worker-message-\(index)",
                    date: sharedDate.addingTimeInterval(TimeInterval(index))
                ))
            }
        }
        let expectation = expectation(description: "worker Realm query")

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[String], Error> = Result {
                let workerRealm = try Realm(configuration: configuration)
                let provider = ChatLocalHistoryPageProvider(
                    realm: workerRealm,
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: .regular
                )
                return provider.latest(limit: 10).map(\.primary)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let primaries):
                    XCTAssertEqual(primaries.count, 10)
                case .failure(let error):
                    XCTFail("Worker-owned Realm query failed: \(error)")
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(retainedRealm.objects(MessageStorageItem.self).count, 100)
    }

    func testLinkedIndexHandlesMiddleInsertDeletionAndCorruptChainFallback() throws {
        let realm = try WRealm.safe()
        try realm.write {
            try persistIndexed(makeMessage(
                primary: "p0",
                archivedId: "0",
                messageId: "message-0",
                date: sharedDate
            ), in: realm)
            try persistIndexed(makeMessage(
                primary: "p2",
                archivedId: "2",
                messageId: "message-2",
                date: sharedDate.addingTimeInterval(2)
            ), in: realm)
            try persistIndexed(makeMessage(
                primary: "p1",
                archivedId: "1",
                messageId: "message-1",
                date: sharedDate.addingTimeInterval(1)
            ), in: realm)
        }
        let provider = try provider(diagnostics: ChatLocalHistoryPageProviderDiagnostics())

        XCTAssertEqual(provider.latest(limit: 10).map(\.primary), ["p0", "p1", "p2"])

        try realm.write {
            let middle = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p1"))
            middle.markAutoDeleted()
        }
        let state = try XCTUnwrap(
            realm.object(
                ofType: ChatLocalHistoryIndexStorageItem.self,
                forPrimaryKey: ChatLocalHistoryIndexStorageItem.genPrimary(
                    owner: owner,
                    jid: jid,
                    conversationType: ClientSynchronizationManager.ConversationType.regular
                )
            )
        )
        XCTAssertEqual(state.indexedVisibleCount, 2)
        XCTAssertEqual(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p0")?.historyNextMessagePrimary,
            "p2"
        )
        XCTAssertEqual(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2")?.historyPreviousMessagePrimary,
            "p0"
        )
        XCTAssertEqual(provider.latest(limit: 10).map(\.primary), ["p0", "p2"])

        try realm.write {
            let newest = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "p2"))
            newest.historyPreviousMessagePrimary = "missing-primary"
        }
        XCTAssertEqual(provider.latest(limit: 10).map(\.primary), ["p0", "p2"])
    }

    func testLinkedIndexPreservesLegacyNumericCaseInsensitiveOrderInsideEqualDateBucket() throws {
        let realm = try WRealm.safe()
        try realm.write {
            try persistIndexed(makeMessage(
                primary: "uuid-c",
                archivedId: "uuid-archive-c",
                messageId: "message-uuid-c",
                date: sharedDate
            ), in: realm)
            try persistIndexed(makeMessage(
                primary: "0000",
                archivedId: "not-a-timestamp",
                messageId: "message-0000",
                date: sharedDate
            ), in: realm)
            try persistIndexed(makeMessage(
                primary: "zzzz",
                archivedId: "another-uuid",
                messageId: "message-zzzz",
                date: sharedDate
            ), in: realm)
        }

        XCTAssertEqual(
            try provider(diagnostics: ChatLocalHistoryPageProviderDiagnostics())
                .latest(limit: 10)
                .map(\.primary),
            ["zzzz", "0000", "uuid-c"]
        )
    }

    private func provider(
        diagnostics: ChatLocalHistoryPageProviderDiagnostics
    ) throws -> ChatLocalHistoryPageProvider {
        ChatLocalHistoryPageProvider(
            realm: try WRealm.safe(),
            owner: owner,
            jid: jid,
            conversationType: .regular,
            diagnostics: diagnostics
        )
    }

    private func insertSameTimestampMessages(count: Int) throws {
        let realm = try WRealm.safe()
        let insertionOrder = (0..<count).map { ($0 * 37) % count }
        try realm.write {
            for index in insertionOrder {
                let id = formattedId(index)
                let message = MessageStorageItem()
                message.primary = "primary-\(id)"
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.archivedId = id
                message.messageId = "message-\(id)"
                message.date = sharedDate
                message.sentDate = sharedDate
                message.body = id
                realm.add(message, update: .modified)
            }
        }
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        messageId: String,
        opponent: String? = nil,
        date: Date? = nil
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = opponent ?? jid
        message.conversationType = .regular
        message.archivedId = archivedId
        message.messageId = messageId
        message.date = date ?? sharedDate
        message.sentDate = message.date
        message.body = primary
        return message
    }

    private func persistIndexed(_ message: MessageStorageItem, in realm: Realm) throws {
        realm.add(message, update: .modified)
        let stored = try XCTUnwrap(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: message.primary)
        )
        ChatLocalHistoryLinkedIndex.upsert(stored, in: realm)
    }

    private func expectedIds(_ range: Range<Int>) -> [String] {
        range.map(formattedId)
    }

    private func formattedId(_ index: Int) -> String {
        String(format: "%08d", index)
    }
}

final class ChatCursorNativeHistoryScaleTests: XCTestCase {
    func testMillionRowTimelineSessionKeepsResidentAndOperationsBounded() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatTimelineSessionScaleTests-million-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let realm = try Realm(configuration: configuration)
        let fixtureStore = CursorRealmFixtureStore(realm: realm)
        let run = try ChatPerformanceFixtureGenerator.withFixture(
            scale: .million,
            batchSize: 4_096,
            store: fixtureStore
        ) { generation -> [String: Any] in
            let sessionStore = RealmChatTimelineSessionStore(
                owner: fixtureStore.owner,
                jid: fixtureStore.jid,
                conversationType: .regular
            )
            var session: ChatTimelineSession? = ChatTimelineSession(
                store: sessionStore,
                pageSize: 64,
                conversationKey: ChatTimelineConversationKey(
                    owner: fixtureStore.owner,
                    jid: fixtureStore.jid,
                    conversationType: .regular
                ),
                archiveState: ChatArchiveStateSnapshot(
                    primaryKey: "million-scale",
                    persistedCursorId: nil,
                    fullArchiveLoaded: true,
                    newestCursorId: nil,
                    newerLiveEdgeReached: true,
                    hasKnownNewerGap: false,
                    knownGaps: []
                )
            )
            defer { session = nil }

            let started = CFAbsoluteTimeGetCurrent()
            let latest = try XCTUnwrap(session).openLatest()
            let older = try XCTUnwrap(session).pageOlder()
            let newer = try XCTUnwrap(session).pageNewer()
            let around = try XCTUnwrap(session).openAround(
                anchor: ChatTimelineAnchor(
                    primary: fixtureStore.primary(generation.requestedRowCount / 2),
                    archivedId: nil,
                    messageId: nil,
                    date: nil
                )
            )
            let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
            let diagnostics = sessionStore.diagnosticsSnapshot

            XCTAssertEqual(generation.persistedRowCount, 1_000_000)
            XCTAssertLessThanOrEqual(latest.items.count, latest.residentHardLimit)
            XCTAssertLessThanOrEqual(older.items.count, older.residentHardLimit)
            XCTAssertLessThanOrEqual(newer.items.count, newer.residentHardLimit)
            XCTAssertLessThanOrEqual(around.items.count, around.residentHardLimit)
            XCTAssertTrue(around.items.contains {
                $0.primary == fixtureStore.primary(generation.requestedRowCount / 2)
            })
            XCTAssertEqual(diagnostics.fullScanCount, 0)
            XCTAssertLessThanOrEqual(
                diagnostics.maxCandidateCount,
                around.residentHardLimit * 4
            )
            XCTAssertLessThanOrEqual(elapsedMilliseconds, 500)

            return [
                "rowCount": generation.persistedRowCount,
                "elapsedMilliseconds": elapsedMilliseconds,
                "residentHardLimit": around.residentHardLimit,
                "maxCandidateCount": diagnostics.maxCandidateCount,
                "queryCount": diagnostics.queryCount,
                "fullScanCount": diagnostics.fullScanCount
            ]
        }

        XCTAssertEqual(run.deletedRowCount, 1_000_000)
        XCTAssertEqual(run.remainingRowCountAfterCleanup, 0)
        let data = try JSONSerialization.data(withJSONObject: run.result, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "chat-timeline-session-million-row-report.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRealRealmScaleMatrixKeepsQueryOperationsPageBounded() throws {
        let scales: [ChatPerformanceFixtureScale] = [.small, .hundredThousand, .million]
        var reports: [[String: Any]] = []

        for scale in scales {
            let configuration = Realm.Configuration(
                inMemoryIdentifier: "ChatCursorNativeHistoryScaleTests-\(scale.rawValue)-\(UUID().uuidString)"
            )
            let realm = try Realm(configuration: configuration)
            let store = CursorRealmFixtureStore(realm: realm)
            let run = try ChatPerformanceFixtureGenerator.withFixture(
                scale: scale,
                batchSize: 4_096,
                store: store
            ) { generation -> [String: Any] in
                let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
                let provider = ChatLocalHistoryPageProvider(
                    realm: realm,
                    owner: store.owner,
                    jid: store.jid,
                    conversationType: .regular,
                    diagnostics: diagnostics
                )
                let started = CFAbsoluteTimeGetCurrent()
                let latest = provider.latest(limit: 64)
                let latestOldest = try XCTUnwrap(latest.first)
                let older = provider.older(before: ChatTimelineBoundary(message: latestOldest), limit: 64)
                let newerBoundary = try XCTUnwrap(older.last)
                let newer = provider.newer(after: ChatTimelineBoundary(message: newerBoundary), limit: 64)
                let anchor = try XCTUnwrap(provider.message(
                    primary: store.primary(generation.requestedRowCount / 2),
                    archivedId: nil,
                    messageId: nil
                ))
                let around = provider.around(anchor: anchor, before: 32, after: 32)
                let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)

                XCTAssertEqual(latest.count, 64)
                XCTAssertEqual(older.count, min(64, max(0, generation.requestedRowCount - 64)))
                XCTAssertEqual(newer.map(\.primary), latest.map(\.primary))
                XCTAssertEqual(around.count, 65)
                XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 256)
                XCTAssertEqual(diagnostics.countQueryCount, 0)
                XCTAssertEqual(diagnostics.offsetQueryCount, 0)
                XCTAssertEqual(diagnostics.expansionCount, 0)
                XCTAssertEqual(diagnostics.fullScanCount, 0)
                XCTAssertEqual(diagnostics.fullSameDateBucketMaterializationCount, 0)
                XCTAssertLessThanOrEqual(
                    elapsedMilliseconds,
                    500,
                    "Cursor reads exceeded the calibrated simulator budget at \(scale.rawValue) rows"
                )

                return [
                    "rowCount": generation.requestedRowCount,
                    "elapsedMilliseconds": elapsedMilliseconds,
                    "maxCandidateCount": diagnostics.maxCandidateCount,
                    "queryCount": diagnostics.queryCount
                ]
            }

            reports.append(run.result)
            XCTAssertEqual(run.deletedRowCount, scale.rowCount)
            XCTAssertEqual(run.remainingRowCountAfterCleanup, 0)
        }

        let data = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "chat-history-real-realm-scale-report.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class CursorRealmFixtureStore: ChatPerformanceFixturePersisting {
    let owner = "chat-history-scale-owner"
    let jid = "chat-history-scale-peer"
    let isEphemeral: Bool
    private let realm: Realm

    var persistedRowCount: Int {
        realm.objects(MessageStorageItem.self)
            .filter("owner == %@", owner)
            .count
    }

    init(realm: Realm) {
        self.realm = realm
        self.isEphemeral = realm.configuration.inMemoryIdentifier != nil
    }

    func prepare(totalRowCount: Int) throws {}

    func beginBatch(_ range: Range<Int>) throws {
        realm.beginWrite()
    }

    func persist(_ row: ChatPerformanceThinFixtureRow) throws {
        let message = MessageStorageItem()
        message.primary = primary(row.ordinal)
        message.owner = owner
        message.opponent = jid
        message.conversationType = .regular
        message.archivedId = String(format: "%012d", row.ordinal)
        message.messageId = "scale-message-\(String(format: "%012d", row.ordinal))"
        message.date = Date(timeIntervalSince1970: TimeInterval(row.timestampSeconds))
        message.sentDate = message.date
        message.body = "v\(row.bodyVariant)"
        realm.add(message, update: .modified)
        if let stored = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: message.primary) {
            ChatLocalHistoryLinkedIndex.upsert(stored, in: realm)
        }
    }

    func endBatch() throws {
        try realm.commitWrite()
    }

    func cleanup() throws -> Int {
        if realm.isInWriteTransaction {
            realm.cancelWrite()
        }
        let rows = realm.objects(MessageStorageItem.self)
            .filter("owner == %@", owner)
        let count = rows.count
        try realm.write {
            realm.delete(rows)
        }
        return count
    }

    func primary(_ ordinal: Int) -> String {
        "chat-history-scale-\(String(format: "%012d", ordinal))"
    }
}
