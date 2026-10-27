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
            primary: sameTimestampFixturePrimary(50_000),
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
            primary: sameTimestampFixturePrimary(500),
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

    func testSearchResolutionUsesTypedMAMCursorBeforeRawStanzaID() throws {
        let realm = try WRealm.safe()
        let target = makeMessage(
            primary: "typed-mam-target",
            archivedId: "100",
            messageId: "target-message"
        )
        target.mamArchiveId = "200"
        let legacyRawCollision = makeMessage(
            primary: "legacy-raw-collision",
            archivedId: "100",
            messageId: "legacy-message"
        )
        try realm.write {
            realm.add([target, legacyRawCollision])
        }
        let provider = try provider(
            diagnostics: ChatLocalHistoryPageProviderDiagnostics()
        )

        let resolved = provider.searchMessage(
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: "100",
                archiveCursor: try XCTUnwrap(ArchiveCursor(rawValue: "200")),
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: nil
            )
        )

        XCTAssertEqual(resolved?.primary, target.primary)
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

    func testLinkedIndexUsesStablePrimaryOrderInsteadOfOpaqueArchiveTokenSpellings() throws {
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
            ["0000", "uuid-c", "zzzz"]
        )
    }

    func testAscendingOlderPageUpsertMaterializesAtMostTwoNeighborsAtDifferentHistorySizes() throws {
        let realm = try WRealm.safe()
        let pageSize = 24

        for historySize in [100, 2_000] {
            var materializedCounts: [Int] = []
            try realm.write {
                realm.deleteAll()
                for index in 0..<historySize {
                    try persistIndexed(makeMessage(
                        primary: "tail-\(formattedId(index))",
                        archivedId: "tail-archive-\(index)",
                        messageId: "tail-message-\(index)",
                        date: sharedDate.addingTimeInterval(TimeInterval(index))
                    ), in: realm)
                }
                for index in 0..<pageSize {
                    try persistIndexed(makeMessage(
                        primary: "older-\(formattedId(index))",
                        archivedId: "older-archive-\(index)",
                        messageId: "older-message-\(index)",
                        date: sharedDate.addingTimeInterval(TimeInterval(index - pageSize))
                    ), in: realm, neighborMaterializationObserver: {
                        materializedCounts.append($0)
                    })
                }
            }

            XCTAssertEqual(materializedCounts.count, pageSize)
            XCTAssertGreaterThan(materializedCounts.reduce(0, +), 0,
                                 "The budget must observe actual interior insertions")
            XCTAssertLessThanOrEqual(materializedCounts.max() ?? 0, 2)
            XCTAssertLessThanOrEqual(materializedCounts.reduce(0, +), pageSize * 2)
            try assertLinkedChain(
                (0..<pageSize).map { "older-\(formattedId($0))" } +
                    (0..<historySize).map { "tail-\(formattedId($0))" },
                in: realm
            )
        }
    }

    func testInteriorReplayKeepsLinksAndCountWithBoundedNeighborMaterialization() throws {
        let realm = try WRealm.safe()
        let primaries = (0..<12).map { "replay-\(formattedId($0))" }
        var materializedCounts: [Int] = []
        try realm.write {
            for (index, primary) in primaries.enumerated() {
                try persistIndexed(makeMessage(
                    primary: primary,
                    archivedId: "protocol-\(index)",
                    messageId: "replay-message-\(index)",
                    date: sharedDate.addingTimeInterval(TimeInterval(index))
                ), in: realm)
            }
            let replay = try XCTUnwrap(realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: primaries[5]
            ))
            let positionBeforeReplay = MessageHistoryOrderKey(message: replay)
            replay.mamArchiveId = "opaque-reconciled-MAM-token"
            replay.body = "replayed content"
            replay.isRead = true
            replay.queryIds = "replayed-query"
            XCTAssertEqual(MessageHistoryOrderKey(message: replay), positionBeforeReplay)
            ChatLocalHistoryLinkedIndex.upsert(
                replay,
                in: realm,
                neighborMaterializationObserver: { materializedCounts.append($0) }
            )
        }

        XCTAssertEqual(materializedCounts.count, 1)
        XCTAssertLessThanOrEqual(materializedCounts[0], 2)
        try assertLinkedChain(primaries, in: realm)
    }

    func testAscendingOlderBatchUsesConstantRangeQueryBudgetAtDifferentHistorySizes() throws {
        let realm = try WRealm.safe()
        for historySize in [100, 2_000] {
            var rangeQueries = 0
            try realm.write {
                realm.deleteAll()
                for index in 0..<historySize {
                    try persistIndexed(makeMessage(primary: "batch-tail-\(formattedId(index))",
                        archivedId: "tail-\(index)", messageId: "tail-\(index)",
                        date: sharedDate.addingTimeInterval(TimeInterval(index))), in: realm)
                }
                let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
                for index in 0..<24 {
                    try persistIndexed(makeMessage(primary: "batch-older-\(formattedId(index))",
                        archivedId: "opaque-\(index)", messageId: "older-\(index)",
                        date: sharedDate.addingTimeInterval(TimeInterval(index - 24))),
                        in: realm, batchContext: context)
                }
            }
            XCTAssertLessThanOrEqual(rangeQueries, 2,
                "An adjacent older batch must not repeat Realm sorts for every row")
            try assertLinkedChain((0..<24).map { "batch-older-\(formattedId($0))" } +
                (0..<historySize).map { "batch-tail-\(formattedId($0))" }, in: realm)
        }
    }

    func testBatchHintUsesCompleteTupleForSameDateAdjacentRows() throws {
        let realm = try WRealm.safe()
        let primaries = [0, 2, 3, 10].map { "\(formattedId($0))-batch-tie" }
        var rangeQueries = 0
        try realm.write {
            for index in [0, 3] {
                try persistIndexed(makeMessage(primary: primaries[index], archivedId: "opaque-\(index)",
                    messageId: "tie-\(index)"), in: realm)
            }
            let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
            for index in [1, 2] {
                try persistIndexed(makeMessage(primary: primaries[index], archivedId: "unrelated-\(index)",
                    messageId: "tie-\(index)"), in: realm, batchContext: context)
            }
        }
        XCTAssertEqual(rangeQueries, 2, "Only the first interior row needs a range lookup")
        try assertLinkedChain(primaries, in: realm)
    }

    func testInvalidBatchHintVersionOrReciprocalLinkFallsBackToRangeQueries() throws {
        let realm = try WRealm.safe()
        for staleVersion in [true, false] {
            var rangeQueries = 0
            try realm.write {
                realm.deleteAll()
                for (primary, offset) in [("hint-head", 0), ("hint-tail", 10)] {
                    try persistIndexed(makeMessage(primary: primary, archivedId: primary, messageId: primary,
                        date: sharedDate.addingTimeInterval(TimeInterval(offset))), in: realm)
                }
                let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
                try persistIndexed(makeMessage(primary: "hint-previous", archivedId: "previous", messageId: "previous",
                    date: sharedDate.addingTimeInterval(2)), in: realm, batchContext: context)
                rangeQueries = 0
                let previous = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "hint-previous"))
                if staleVersion {
                    previous.historyLinkedIndexVersion = 0
                } else {
                    realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "hint-tail")?.historyPreviousMessagePrimary = "hint-head"
                }
                try persistIndexed(makeMessage(primary: "hint-next", archivedId: "next", messageId: "next",
                    date: sharedDate.addingTimeInterval(3)), in: realm, batchContext: context)
            }
            XCTAssertEqual(rangeQueries, 2, "An unproved hint must use the existing keyset fallback")
            try assertLinkedChain(["hint-head", "hint-previous", "hint-next", "hint-tail"], in: realm,
                versionOverrides: staleVersion ? ["hint-previous": 0] : [:])
        }
    }

    func testDeletedHintFallsBackWithoutReintroducingItsRow() throws {
        let realm = try WRealm.safe()
        var rangeQueries = 0
        try realm.write {
            for (primary, offset) in [("deleted-head", 0), ("deleted-tail", 10)] {
                try persistIndexed(makeMessage(primary: primary, archivedId: primary, messageId: primary,
                    date: sharedDate.addingTimeInterval(TimeInterval(offset))), in: realm)
            }
            let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
            try persistIndexed(makeMessage(primary: "deleted-hint", archivedId: "hint", messageId: "hint",
                date: sharedDate.addingTimeInterval(2)), in: realm, batchContext: context)
            try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "deleted-hint")).markDeleted()
            rangeQueries = 0
            try persistIndexed(makeMessage(primary: "deleted-next", archivedId: "next", messageId: "next",
                date: sharedDate.addingTimeInterval(3)), in: realm, batchContext: context)
        }
        XCTAssertEqual(rangeQueries, 2)
        try assertLinkedChain(["deleted-head", "deleted-next", "deleted-tail"], in: realm)
    }

    func testForeignScopeAndNonAdjacentBatchHintUseRangeFallback() throws {
        let realm = try WRealm.safe()
        var rangeQueries = 0
        try realm.write {
            for (primary, offset) in [("gap-head", 0), ("gap-middle", 50), ("gap-tail", 100)] {
                try persistIndexed(makeMessage(primary: primary, archivedId: primary, messageId: primary,
                    date: sharedDate.addingTimeInterval(TimeInterval(offset))), in: realm)
            }
            let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
            let foreign = makeMessage(primary: "foreign-hint", archivedId: "foreign", messageId: "foreign",
                opponent: "foreign@example.com", date: sharedDate.addingTimeInterval(1))
            try persistIndexed(foreign, in: realm, batchContext: context)
            try persistIndexed(makeMessage(primary: "gap-previous", archivedId: "previous", messageId: "previous",
                date: sharedDate.addingTimeInterval(10)), in: realm, batchContext: context)
            XCTAssertEqual(rangeQueries, 2, "A foreign conversation cannot supply a local hint")
            rangeQueries = 0
            try persistIndexed(makeMessage(primary: "gap-next", archivedId: "next", messageId: "next",
                date: sharedDate.addingTimeInterval(70)), in: realm, batchContext: context)
            XCTAssertEqual(rangeQueries, 2, "A nonadjacent hint cannot skip an existing middle row")
            rangeQueries = 0
            try persistIndexed(makeMessage(primary: "gap-adjacent", archivedId: "adjacent", messageId: "adjacent",
                date: sharedDate.addingTimeInterval(71)), in: realm, batchContext: context)
        }
        XCTAssertEqual(rangeQueries, 0)
        try assertLinkedChain(["gap-head", "gap-previous", "gap-middle", "gap-next", "gap-adjacent", "gap-tail"], in: realm)
        let foreign = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "foreign-hint"))
        XCTAssertNil(foreign.historyPreviousMessagePrimary)
        XCTAssertNil(foreign.historyNextMessagePrimary)
    }

    func testUnlinkedDeletedCandidateDoesNotReplaceSuccessfulBatchHint() throws {
        let realm = try WRealm.safe()
        var rangeQueries = 0
        try realm.write {
            for (primary, offset) in [("success-head", 0), ("success-tail", 10)] {
                try persistIndexed(makeMessage(primary: primary, archivedId: primary, messageId: primary,
                    date: sharedDate.addingTimeInterval(TimeInterval(offset))), in: realm)
            }
            let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
            try persistIndexed(makeMessage(primary: "success-hint", archivedId: "hint", messageId: "hint",
                date: sharedDate.addingTimeInterval(2)), in: realm, batchContext: context)
            let deleted = makeMessage(primary: "success-deleted", archivedId: "deleted", messageId: "deleted",
                date: sharedDate.addingTimeInterval(2.5))
            deleted.isDeleted = true
            try persistIndexed(deleted, in: realm, batchContext: context)
            rangeQueries = 0
            try persistIndexed(makeMessage(primary: "success-next", archivedId: "next", messageId: "next",
                date: sharedDate.addingTimeInterval(3)), in: realm, batchContext: context)
        }
        XCTAssertEqual(rangeQueries, 0)
        try assertLinkedChain(["success-head", "success-hint", "success-next", "success-tail"], in: realm)
    }

    func testExistingEndpointReplayCannotCertifyACorruptReciprocalGapAsBatchHint() throws {
        let realm = try WRealm.safe()
        var rangeQueries = 0
        try realm.write {
            for (primary, offset) in [("corrupt-oldest", 0), ("corrupt-omitted", 5), ("corrupt-newest", 10)] {
                try persistIndexed(makeMessage(primary: primary, archivedId: primary, messageId: primary,
                    date: sharedDate.addingTimeInterval(TimeInterval(offset))), in: realm)
            }
            let oldest = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "corrupt-oldest"))
            let omitted = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "corrupt-omitted"))
            let newest = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "corrupt-newest"))
            oldest.historyNextMessagePrimary = newest.primary
            newest.historyPreviousMessagePrimary = oldest.primary
            XCTAssertEqual(omitted.historyLinkedIndexVersion, ChatLocalHistoryIndexStorageItem.currentVersion)

            let context = ChatLocalHistoryLinkedIndex.BatchContext(onRangeQueries: { rangeQueries += $0 })
            ChatLocalHistoryLinkedIndex.upsert(oldest, in: realm, batchContext: context)
            rangeQueries = 0
            try persistIndexed(makeMessage(primary: "corrupt-incoming", archivedId: "incoming", messageId: "incoming",
                date: sharedDate.addingTimeInterval(3)), in: realm, batchContext: context)
        }
        XCTAssertEqual(rangeQueries, 2, "Replaying an existing endpoint does not prove its neighbor is globally adjacent")
        let incoming = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "corrupt-incoming"))
        XCTAssertEqual(incoming.historyPreviousMessagePrimary, "corrupt-oldest")
        XCTAssertEqual(incoming.historyNextMessagePrimary, "corrupt-omitted")
        XCTAssertEqual(realm.object(ofType: MessageStorageItem.self,
            forPrimaryKey: "corrupt-omitted")?.historyPreviousMessagePrimary, incoming.primary)
    }

    func testSameTimestampInteriorUpsertUsesTheCompletePositionTuple() throws {
        let realm = try WRealm.safe()
        let messages = ["alpha", "beta", "gamma", "delta", "epsilon"].map { suffix in
            makeMessage(
                primary: "same-prefix-14-\(suffix)",
                archivedId: "opaque-\(suffix)",
                messageId: "same-date-\(suffix)"
            )
        }.sorted { MessageHistoryOrderKey(message: $0) < MessageHistoryOrderKey(message: $1) }
        XCTAssertEqual(Set(messages.map(\.historyPositionHigh)).count, 1)
        XCTAssertEqual(Set(messages.map(\.historyPositionLow)).count, 1)
        var materializedCounts: [Int] = []
        try realm.write {
            for index in [0, 2, 4] {
                try persistIndexed(messages[index], in: realm)
            }
            for index in [1, 3] {
                try persistIndexed(messages[index], in: realm, neighborMaterializationObserver: {
                    materializedCounts.append($0)
                })
            }
        }

        XCTAssertEqual(materializedCounts.count, 2)
        XCTAssertTrue(materializedCounts.allSatisfy { $0 <= 2 })
        try assertLinkedChain(messages.map(\.primary), in: realm)
    }

    func testInteriorNeighborLookupRemainsScopedToOwnerJIDAndConversationType() throws {
        let realm = try WRealm.safe()
        let localPrimaries = ["scoped-010", "scoped-020", "scoped-030"]
        var materializedCounts: [Int] = []
        try realm.write {
            for primary in [localPrimaries[0], localPrimaries[2]] {
                try persistIndexed(makeMessage(primary: primary, archivedId: primary,
                                              messageId: primary), in: realm)
            }
            let foreignOwner = makeMessage(primary: "scoped-018", archivedId: "foreign-owner",
                                           messageId: "foreign-owner")
            foreignOwner.owner = "another-owner@example.com"
            let foreignJID = makeMessage(primary: "scoped-019", archivedId: "foreign-jid",
                                         messageId: "foreign-jid", opponent: "another-chat@example.com")
            let foreignType = makeMessage(primary: "scoped-021", archivedId: "foreign-type",
                                          messageId: "foreign-type")
            foreignType.conversationType = .omemo
            for message in [foreignOwner, foreignJID, foreignType] {
                try persistIndexed(message, in: realm)
            }
            try persistIndexed(makeMessage(primary: localPrimaries[1], archivedId: "local-middle",
                                          messageId: "local-middle"), in: realm,
                               neighborMaterializationObserver: { materializedCounts.append($0) })
        }

        XCTAssertEqual(materializedCounts.count, 1)
        XCTAssertLessThanOrEqual(materializedCounts[0], 2)
        try assertLinkedChain(localPrimaries, in: realm)
        for primary in ["scoped-018", "scoped-019", "scoped-021"] {
            let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
            XCTAssertNil(message.historyPreviousMessagePrimary)
            XCTAssertNil(message.historyNextMessagePrimary)
        }
    }

    func testOrderMutationAndDeletedRowReinsertionKeepTheLinkedChainCoherent() throws {
        let realm = try WRealm.safe()
        let primaries = (0..<7).map { "mutation-\(formattedId($0))" }
        var materializedCounts: [Int] = []
        try realm.write {
            for (index, primary) in primaries.enumerated() {
                try persistIndexed(makeMessage(primary: primary, archivedId: primary, messageId: primary,
                                              date: sharedDate.addingTimeInterval(TimeInterval(index))), in: realm)
            }
            let moved = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primaries[3]))
            moved.date = sharedDate.addingTimeInterval(10)
            ChatLocalHistoryLinkedIndex.upsert(moved, in: realm)
        }
        try assertLinkedChain(primaries.filter { $0 != primaries[3] } + [primaries[3]], in: realm)

        try realm.write {
            let moved = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primaries[3]))
            moved.date = sharedDate.addingTimeInterval(2.5)
            ChatLocalHistoryLinkedIndex.upsert(moved, in: realm,
                neighborMaterializationObserver: { materializedCounts.append($0) })
        }
        try assertLinkedChain(primaries, in: realm)

        try realm.write {
            let removed = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primaries[3]))
            removed.isDeleted = true
            ChatLocalHistoryLinkedIndex.upsert(removed, in: realm)
        }
        try assertLinkedChain(primaries.filter { $0 != primaries[3] }, in: realm)
        try realm.write {
            let restored = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primaries[3]))
            restored.isDeleted = false
            ChatLocalHistoryLinkedIndex.upsert(restored, in: realm,
                neighborMaterializationObserver: { materializedCounts.append($0) })
        }
        try assertLinkedChain(primaries, in: realm)
        XCTAssertEqual(materializedCounts.count, 2)
        XCTAssertTrue(materializedCounts.allSatisfy { $0 <= 2 })
    }

    private func assertLinkedChain(
        _ expectedPrimaries: [String],
        in realm: Realm,
        versionOverrides: [String: Int] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let state = try XCTUnwrap(ChatLocalHistoryLinkedIndex.state(
            owner: owner, jid: jid, conversationType: .regular, in: realm
        ), file: file, line: line)
        XCTAssertEqual(state.indexedVisibleCount, expectedPrimaries.count, file: file, line: line)
        XCTAssertEqual(state.oldestMessagePrimary, expectedPrimaries.first, file: file, line: line)
        XCTAssertEqual(state.newestMessagePrimary, expectedPrimaries.last, file: file, line: line)
        for (index, primary) in expectedPrimaries.enumerated() {
            let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
                                       file: file, line: line)
            XCTAssertEqual(message.historyPreviousMessagePrimary,
                           index > 0 ? expectedPrimaries[index - 1] : nil, file: file, line: line)
            XCTAssertEqual(message.historyNextMessagePrimary,
                           index + 1 < expectedPrimaries.count ? expectedPrimaries[index + 1] : nil,
                           file: file, line: line)
            XCTAssertEqual(message.historyLinkedIndexVersion, versionOverrides[primary] ?? ChatLocalHistoryIndexStorageItem.currentVersion,
                           file: file, line: line)
        }
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
                message.primary = sameTimestampFixturePrimary(index)
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

    private func persistIndexed(
        _ message: MessageStorageItem,
        in realm: Realm,
        neighborMaterializationObserver: ((Int) -> Void)? = nil,
        batchContext: ChatLocalHistoryLinkedIndex.BatchContext? = nil
    ) throws {
        realm.add(message, update: .modified)
        let stored = try XCTUnwrap(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: message.primary)
        )
        ChatLocalHistoryLinkedIndex.upsert(stored, in: realm,
            neighborMaterializationObserver: neighborMaterializationObserver,
            batchContext: batchContext)
    }

    private func expectedIds(_ range: Range<Int>) -> [String] {
        range.map(formattedId)
    }

    private func formattedId(_ index: Int) -> String {
        String(format: "%08d", index)
    }

    private func sameTimestampFixturePrimary(_ index: Int) -> String {
        // Keep expected adjacency independent of opaque archive IDs and SHA
        // ties: ordinal bytes differ within the stored primary-prefix tuple.
        "\(formattedId(index))-primary"
    }
}

final class ChatCursorNativeHistoryScaleTests: XCTestCase {

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
