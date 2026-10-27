import XCTest
@testable import xabber

final class ChatVirtualTimelineEngineTests: XCTestCase {
    private let owner = "owner@example.com"
    private let jid = "chat@example.com"

    func testOpaqueScopeMembershipComesOnlyFromServerLedger() throws {
        let ids = ["z-first", "0009", "A/middle", "2", "!last"]
        let scope = try makeScope(orderedIDs: ids)

        for id in ids {
            XCTAssertTrue(scope.contains(try XCTUnwrap(ArchiveCursor(rawValue: id))))
        }
        XCTAssertFalse(scope.contains(try XCTUnwrap(ArchiveCursor(rawValue: "9"))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(ArchiveCursor(rawValue: "1"))))
        XCTAssertTrue(scope.isBefore(
            try XCTUnwrap(ArchiveCursor(rawValue: "z-first")),
            try XCTUnwrap(ArchiveCursor(rawValue: "!last"))
        ))
        XCTAssertFalse(scope.isBefore(
            try XCTUnwrap(ArchiveCursor(rawValue: "unproved")),
            try XCTUnwrap(ArchiveCursor(rawValue: "!last"))
        ))
    }

    func testResidentMAMIndexDistinguishesCanonicalUnicodeSpellings() throws {
        let ids = ["caf\u{00E9}", "cafe\u{0301}"]
        let index = ChatTimelineResidentIndex(items: makeOpaqueMessages(ids))

        XCTAssertEqual(index.index(archiveCursor: try XCTUnwrap(ArchiveCursor(rawValue: ids[0]))), 0)
        XCTAssertEqual(index.index(archiveCursor: try XCTUnwrap(ArchiveCursor(rawValue: ids[1]))), 1)
    }

    func testVerifiedInstallAndRematerializationPreserveServerOrderOverReversedDates() throws {
        let ids = ["z-first", "0009", "A/middle", "!last"]
        let messages = makeOpaqueMessages(ids)
        let scope = try makeScope(orderedIDs: ids)
        var engine = makeEngine(
            provider: VirtualTimelinePageProvider(messages: messages.reversed()),
            scope: scope
        )

        let snapshot = try XCTUnwrap(engine.installVerified(
            items: [messages[3], messages[1], messages[0], messages[2]],
            expectedPrimaryIDs: messages.map(\.primary),
            direction: nil,
            scope: scope
        ))

        XCTAssertEqual(snapshot.items.map(\.mamArchiveId), ids)
        XCTAssertEqual(snapshot.state.residentArchivedIds, ids)
        XCTAssertEqual(engine.currentSnapshot().items.map(\.mamArchiveId), ids)
    }

    func testOpaqueReversePagingUsesLedgerDespiteReversedTimestamps() throws {
        let ids = (1...601).map { "uid/\(10_000 - $0 * 3)" }
        let messages = makeOpaqueMessages(ids)
        let provider = VirtualTimelinePageProvider(messages: messages.reversed())
        let scope = try makeScope(orderedIDs: ids)
        var engine = makeEngine(provider: provider, scope: scope)
        _ = try XCTUnwrap(engine.installVerified(
            items: Array(messages.suffix(500)),
            expectedPrimaryIDs: messages.suffix(500).map(\.primary),
            direction: nil,
            scope: scope
        ))

        let firstOlder = try localSnapshot(engine.page(.older))
        XCTAssertEqual(firstOlder.items.map(\.mamArchiveId), Array(ids.suffix(600)))
        let secondOlder = try localSnapshot(engine.page(.older))
        XCTAssertEqual(secondOlder.items.map(\.mamArchiveId), Array(ids.prefix(600)))
        let newer = try localSnapshot(engine.page(.newer))
        XCTAssertEqual(newer.items.map(\.mamArchiveId), Array(ids.suffix(600)))
        XCTAssertTrue(newer.state.isResidentAtLiveTail)
        XCTAssertEqual(provider.olderCalls, 0, "verified paging cannot use timestamp-based queries")
        XCTAssertEqual(provider.newerCalls, 0, "verified paging cannot use timestamp-based queries")
        XCTAssertTrue(provider.archiveCursorQuerySizes.allSatisfy { $0 <= 100 })
    }

    func testScopeExtensionRequiresPriorLedgerAsContiguousOrderedSubsequence() throws {
        let previous = try makeScope(orderedIDs: ["b", "alpha", "0009"])
        XCTAssertTrue(try makeScope(
            orderedIDs: ["older/z", "b", "alpha", "0009"], generation: 2
        ).canExtend(previous, direction: .older))
        XCTAssertTrue(try makeScope(
            orderedIDs: ["b", "alpha", "0009", "newer/!"], generation: 2
        ).canExtend(previous, direction: .newer))
        XCTAssertFalse(try makeScope(
            orderedIDs: ["b", "0009", "alpha"], generation: 2
        ).canExtend(previous, direction: .newer))
        XCTAssertFalse(try makeScope(
            orderedIDs: ["b", "unproved-gap", "alpha", "0009"], generation: 2
        ).canExtend(previous, direction: .older))
        XCTAssertFalse(try makeScope(
            orderedIDs: ["b", "alpha"], generation: 2
        ).canExtend(previous, direction: .older))
    }

    func testScopeIdentityRejectsContradictorySameGenerationLedgerAndChangedGeneration() throws {
        let original = try makeScope(orderedIDs: ["first", "ab", "c", "last"])
        XCTAssertEqual(original, try makeScope(orderedIDs: ["first", "ab", "c", "last"]))
        XCTAssertNotEqual(original, try makeScope(orderedIDs: ["first", "c", "ab", "last"]))
        XCTAssertNotEqual(original, try makeScope(orderedIDs: ["first", "a", "bc", "last"]))
        XCTAssertNotEqual(original, try makeScope(
            orderedIDs: ["first", "ab", "c", "last"], generation: 2
        ))
    }

    func testOpaqueTargetContextUsesLedgerNotTimestampOrLexicalExtrema() throws {
        let ids = ["z-first", "9", "A-target", "0001", "!last"]
        let messages = makeOpaqueMessages(ids)
        let provider = VirtualTimelinePageProvider(messages: messages.reversed())
        let scope = try makeScope(orderedIDs: ids)
        var engine = makeEngine(provider: provider, scope: scope)

        let outcome = engine.openAround(
            primary: messages[2].primary,
            archiveCursor: try XCTUnwrap(ArchiveCursor(rawValue: ids[2])),
            before: 1,
            after: 1
        )

        guard case .local(let snapshot) = outcome else {
            return XCTFail("An exact opaque member target must materialize locally")
        }
        XCTAssertEqual(snapshot.items.map(\.mamArchiveId), Array(ids[1...3]))
        XCTAssertEqual(provider.aroundCalls, 0)
        XCTAssertEqual(provider.archiveCursorQuerySizes, [3])
    }

    func testConsumedLedgerPagesAdvanceInBoundedChunksWithoutInferringUIDMinOrMax() throws {
        let ids = (0..<205).map { "opaque/\(10_000 - $0)" }
        let messages = makeOpaqueMessages(ids)
        let resident = messages.last!
        let hiddenEdge = messages.first!
        hiddenEdge.isLocallyHiddenByReport = true
        let provider = VirtualTimelinePageProvider(messages: [hiddenEdge, resident])
        let scope = try makeScope(orderedIDs: ids, reachesArchiveStart: false)
        var engine = makeEngine(provider: provider, scope: scope)
        _ = try XCTUnwrap(engine.installVerified(
            items: [resident], expectedPrimaryIDs: [resident.primary], direction: nil, scope: scope
        ))

        guard case .needsArchiveExpansion(.older) = engine.page(.older) else {
            return XCTFail("Consumed pages must reach the exact ledger edge without showing hidden rows")
        }
        XCTAssertEqual(engine.currentSnapshot().items.map(\.primary), [resident.primary])
        XCTAssertEqual(provider.archiveCursorQuerySizes, [100, 100, 4])
    }

    func testThreeHundredSixtyThreeLoadedRowsStayResidentWithoutEviction() throws {
        let messages = makeMessages(1...1_000)
        let provider = VirtualTimelinePageProvider(messages: messages)
        let scope = try makeScope(oldest: 1, newest: 1_000)
        var engine = makeEngine(provider: provider, scope: scope)

        XCTAssertNotNil(engine.installVerified(
            items: Array(messages[920...999]),
            expectedPrimaryIDs: primaryIDs(921...1_000),
            direction: nil,
            scope: scope
        ))
        XCTAssertNotNil(engine.installVerified(
            items: Array(messages[820...919]),
            expectedPrimaryIDs: primaryIDs(821...920),
            direction: .older,
            scope: scope
        ))
        XCTAssertNotNil(engine.installVerified(
            items: Array(messages[720...819]),
            expectedPrimaryIDs: primaryIDs(721...820),
            direction: .older,
            scope: scope
        ))
        let snapshot = try XCTUnwrap(engine.installVerified(
            items: Array(messages[637...719]),
            expectedPrimaryIDs: primaryIDs(638...720),
            direction: .older,
            scope: scope
        ))

        XCTAssertEqual(snapshot.items.count, 363)
        XCTAssertEqual(snapshot.items.map(\.primary), primaryIDs(638...1_000))
        XCTAssertEqual(Set(snapshot.items.map(\.primary)).count, 363)
        XCTAssertTrue(snapshot.state.isResidentAtLiveTail)
    }

    func testConsumedOnlyVerifiedWindowInstallsEmptyResidentWithoutLosingProof() throws {
        let provider = VirtualTimelinePageProvider(messages: [])
        let scope = try makeScope(oldest: 10, newest: 20)
        var engine = makeEngine(provider: provider, scope: scope)

        let snapshot = try XCTUnwrap(engine.installVerified(
            items: [],
            expectedPrimaryIDs: [],
            direction: nil,
            scope: scope
        ))

        XCTAssertEqual(snapshot.items, [])
        XCTAssertEqual(snapshot.state.residentPrimaryKeys, [])
        XCTAssertEqual(
            snapshot.state.segments,
            [
                .loadedRange(oldestArchiveId: "10", newestArchiveId: "20"),
                .liveTail,
            ]
        )
        XCTAssertTrue(snapshot.state.isResidentAtLiveTail)
        XCTAssertEqual(engine.verifiedScope, scope)
    }

    func testDirectionalEvictionStartsOnlyAboveSixPages() throws {
        let messages = makeMessages(1...1_000)
        let provider = VirtualTimelinePageProvider(messages: messages)
        let scope = try makeScope(oldest: 1, newest: 1_000)
        var engine = makeEngine(provider: provider, scope: scope)
        _ = try XCTUnwrap(engine.installVerified(
            items: Array(messages[500...999]),
            expectedPrimaryIDs: primaryIDs(501...1_000),
            direction: nil,
            scope: scope
        ))

        let firstOlder = try localSnapshot(engine.page(.older))
        XCTAssertEqual(firstOlder.items.map(\.primary), primaryIDs(401...1_000))
        XCTAssertEqual(firstOlder.items.count, 600)

        let secondOlder = try localSnapshot(engine.page(.older))
        XCTAssertEqual(secondOlder.items.map(\.primary), primaryIDs(301...900))
        XCTAssertEqual(secondOlder.items.count, 600)
        XCTAssertFalse(secondOlder.state.isResidentAtLiveTail)

        let newer = try localSnapshot(engine.page(.newer))
        XCTAssertEqual(newer.items.map(\.primary), primaryIDs(401...1_000))
        XCTAssertEqual(newer.items.count, 600)
        XCTAssertTrue(newer.state.isResidentAtLiveTail)
    }

    func testLocalPagingFiltersRowsOutsideImmutableVerifiedScope() throws {
        let messages = makeMessages(1...1_000)
        let provider = VirtualTimelinePageProvider(messages: messages)
        let scope = try makeScope(
            oldest: 101,
            newest: 1_000,
            reachesArchiveStart: false
        )
        var engine = makeEngine(provider: provider, scope: scope)
        _ = try XCTUnwrap(engine.installVerified(
            items: Array(messages[100...199]),
            expectedPrimaryIDs: primaryIDs(101...200),
            direction: nil,
            scope: scope
        ))

        let outcome = engine.page(.older)

        guard case .needsArchiveExpansion(.older) = outcome else {
            return XCTFail("Rows 1...100 are outside proof and must not become visible: \(outcome)")
        }
        XCTAssertEqual(engine.currentSnapshot().items.map(\.primary), primaryIDs(101...200))
    }

    func testVerifiedScopeUsesMAMResultCursorWhenProtocolStanzaIDDiffers() throws {
        let item = makeMessages(1...1)[0]
        item.archivedId = "100"
        item.mamArchiveId = "200"
        let provider = VirtualTimelinePageProvider(messages: [item])
        let scope = try makeScope(oldest: 200, newest: 200)
        var engine = makeEngine(provider: provider, scope: scope)

        let snapshot = try XCTUnwrap(engine.installVerified(
            items: [item],
            expectedPrimaryIDs: [item.primary],
            direction: nil,
            scope: scope
        ))

        XCTAssertEqual(snapshot.state.oldest?.archivedId, "200")
        XCTAssertEqual(snapshot.state.newest?.archivedId, "200")
        XCTAssertEqual(snapshot.state.residentArchivedIds, ["200"])
    }

    func testVerifiedScopeRejectsLegacyRawProtocolIDWithoutMAMResultID() throws {
        let item = makeMessages(1...1)[0]
        item.archivedId = "200"
        item.mamArchiveId = ""
        let provider = VirtualTimelinePageProvider(messages: [item])
        let scope = try makeScope(oldest: 200, newest: 200)
        var engine = makeEngine(provider: provider, scope: scope)

        XCTAssertNil(engine.installVerified(
            items: [item],
            expectedPrimaryIDs: [item.primary],
            direction: nil,
            scope: scope
        ))
    }

    func testDedupKeepsRawStanzaAndTypedMAMRowsWhenIDsCollide() {
        let typedMAM = makeMessages(1...1)[0]
        typedMAM.primary = "typed-mam"
        typedMAM.archivedId = "100"
        typedMAM.mamArchiveId = "200"

        let rawStanza = makeMessages(2...2)[0]
        rawStanza.primary = "raw-stanza"
        rawStanza.archivedId = "200"
        rawStanza.mamArchiveId = ""

        let deduplicated = ChatTimelineOrdering.deduplicatedChronological(
            [typedMAM, rawStanza]
        )

        XCTAssertEqual(Set(deduplicated.map(\.primary)), ["typed-mam", "raw-stanza"])
    }

    func testProvenArchiveCollisionRowsSurviveLocalAndVerifiedTimelineOrdering() throws {
        let (original, fork) = makeArchiveCollisionPair()
        XCTAssertTrue(fork.usesDisambiguatedArchiveIdentity)
        let local = ChatTimelineOrdering.deduplicatedChronological([fork, original])
        XCTAssertEqual(local.map(\.primary), [original.primary, fork.primary])
        XCTAssertEqual(local.map(\.body), ["original payload", "different archived payload"])

        let scope = try makeScope(orderedIDs: [fork.mamArchiveId, original.mamArchiveId])
        XCTAssertEqual(scope.ordered([original, fork]).map(\.primary), [fork.primary, original.primary])
        var engine = makeEngine(
            provider: VirtualTimelinePageProvider(messages: [original, fork]),
            scope: scope
        )
        let snapshot = try XCTUnwrap(engine.installVerified(
            items: [original, fork],
            expectedPrimaryIDs: [original.primary, fork.primary],
            direction: nil,
            scope: scope
        ))
        XCTAssertEqual(snapshot.items.map(\.primary), [fork.primary, original.primary])
        XCTAssertEqual(snapshot.items.map(\.body), ["different archived payload", "original payload"])
        XCTAssertEqual(engine.currentSnapshot().items.count, 2)
    }

    func testArchiveCollisionWeakAliasExemptionRequiresTheExactCompleteIdentityTuple() throws {
        let invalidIdentities: [(String, (MessageStorageItem) -> Void)] = [
            ("owner", { $0.owner = "different-owner@example.com" }),
            ("peer", { $0.opponent = "different-peer@example.com" }),
            ("type", { $0.conversationType = .omemo }),
            ("message", { $0.messageId = "different-protocol-message" }),
            ("MAM result", { $0.mamArchiveId = "different-outer-UID" }),
            ("MAM UTF8 spelling", { $0.mamArchiveId = "fork/cafe\u{0301}" }),
            ("missing MAM result", { $0.mamArchiveId = "" }),
            ("fabricated marker", { $0.primary = "mam-disambiguated:forged" }),
            ("suffix", { $0.primary += "-unproved-suffix" })
        ]
        for (label, invalidate) in invalidIdentities {
            let (_, item) = makeArchiveCollisionPair()
            invalidate(item)
            XCTAssertFalse(item.usesDisambiguatedArchiveIdentity, label)
            let keys = ChatTimelineMessageIdentity.keys(for: item)
            XCTAssertTrue(keys.contains("message:\(item.messageId)"), label)
            XCTAssertTrue(keys.contains("raw:\(item.archivedId)"), label)
        }

        let (original, forged) = makeArchiveCollisionPair()
        forged.primary = "mam-disambiguated:forged"
        XCTAssertEqual(ChatTimelineOrdering.deduplicatedChronological([original, forged]).count, 1,
            "An arbitrary marker must not bypass existing alias deduplication")
        let scope = try makeScope(orderedIDs: [original.mamArchiveId, forged.mamArchiveId])
        XCTAssertEqual(scope.ordered([original, forged]).count, 1)
    }

    func testArchiveCollisionRowsStillDeduplicateStrongMAMAndPrimaryIdentities() throws {
        let (sameMAMOriginal, sameMAMFork) = makeArchiveCollisionPair()
        sameMAMOriginal.mamArchiveId = sameMAMFork.mamArchiveId
        XCTAssertTrue(sameMAMFork.usesDisambiguatedArchiveIdentity)
        XCTAssertEqual(ChatTimelineOrdering.deduplicatedChronological([sameMAMOriginal, sameMAMFork]).count, 1)
        let sameMAMScope = try makeScope(orderedIDs: [sameMAMFork.mamArchiveId])
        XCTAssertEqual(sameMAMScope.ordered([sameMAMOriginal, sameMAMFork]).count, 1)

        let (samePrimaryOriginal, samePrimaryFork) = makeArchiveCollisionPair()
        samePrimaryOriginal.primary = samePrimaryFork.primary
        XCTAssertTrue(samePrimaryFork.usesDisambiguatedArchiveIdentity)
        XCTAssertEqual(ChatTimelineOrdering.deduplicatedChronological([samePrimaryOriginal, samePrimaryFork]).count, 1)
        let samePrimaryScope = try makeScope(orderedIDs: [samePrimaryOriginal.mamArchiveId, samePrimaryFork.mamArchiveId])
        XCTAssertEqual(samePrimaryScope.ordered([samePrimaryOriginal, samePrimaryFork]).count, 1)
    }

    func testOrdinaryArchiveRowsKeepExistingWeakAliasDeduplication() throws {
        let (original, ordinary) = makeArchiveCollisionPair()
        ordinary.primary = "ordinary-unproved-primary"
        XCTAssertFalse(ordinary.usesDisambiguatedArchiveIdentity)
        XCTAssertEqual(ChatTimelineOrdering.deduplicatedChronological([ordinary, original]).count, 1)
        let scope = try makeScope(orderedIDs: [original.mamArchiveId, ordinary.mamArchiveId])
        XCTAssertEqual(scope.ordered([original, ordinary]).count, 1)
    }

    func testPagingRejectsRawBoundaryWithoutTypedMAMCursor() throws {
        let item = makeMessages(200...200)[0]
        let scope = try makeScope(oldest: 200, newest: 200)
        let rawOnlyBoundary = ChatTimelineBoundary(
            primary: item.primary,
            archivedId: "200",
            messageId: item.messageId,
            date: item.date
        )
        let state = ChatVirtualTimelineState(
            conversationKey: conversationKey,
            segments: [
                .loadedRange(oldestArchiveId: "200", newestArchiveId: "200"),
                .liveTail,
            ],
            oldest: rawOnlyBoundary,
            newest: rawOnlyBoundary,
            residentPrimaryKeys: [item.primary],
            residentArchivedIds: ["200"],
            isResidentAtLiveTail: true
        )
        var engine = ChatVirtualTimelineEngine(
            provider: VirtualTimelinePageProvider(messages: [item]),
            pageSize: 100,
            state: state,
            verifiedScope: scope
        )

        guard case .invalidProof = engine.page(.older) else {
            return XCTFail("Raw boundary identity cannot authorize verified paging")
        }
    }

    func testHiddenExactScopeEdgeExhaustsLocalProofAndRequestsScopeExpansion() throws {
        let hiddenEdge = makeMessages(1...1)[0]
        hiddenEdge.isLocallyHiddenByReport = true
        let resident = makeMessages(101...200)
        let provider = VirtualTimelinePageProvider(messages: [hiddenEdge] + resident)
        let scope = try makeScope(
            oldest: 1,
            newest: 200,
            reachesArchiveStart: false
        )
        var engine = makeEngine(provider: provider, scope: scope)
        _ = try XCTUnwrap(engine.installVerified(
            items: resident,
            expectedPrimaryIDs: primaryIDs(101...200),
            direction: nil,
            scope: scope
        ))

        let outcome = engine.page(.older)

        guard case .needsArchiveExpansion(.older) = outcome else {
            return XCTFail("Hidden scope edge must exhaust local proof without becoming visible")
        }
        XCTAssertEqual(engine.currentSnapshot().items.map(\.primary), primaryIDs(101...200))
    }

    func testDeletedExactScopeEdgeCanProveArchiveStartWithoutDisplayingRow() throws {
        let deletedEdge = makeMessages(1...1)[0]
        deletedEdge.isDeleted = true
        let resident = makeMessages(101...200)
        let provider = VirtualTimelinePageProvider(messages: [deletedEdge] + resident)
        let scope = try makeScope(oldest: 1, newest: 200)
        var engine = makeEngine(provider: provider, scope: scope)
        _ = try XCTUnwrap(engine.installVerified(
            items: resident,
            expectedPrimaryIDs: primaryIDs(101...200),
            direction: nil,
            scope: scope
        ))

        let outcome = engine.page(.older)

        guard case .endReached(let snapshot) = outcome else {
            return XCTFail("Deleted archive edge must terminate local paging without a row")
        }
        XCTAssertEqual(snapshot.items.map(\.primary), primaryIDs(101...200))
    }

    func testInstallRejectsAnyMissingOutOfScopeDeletedOrWrongConversationRow() throws {
        let messages = makeMessages(1...20)
        let provider = VirtualTimelinePageProvider(messages: messages)
        let scope = try makeScope(oldest: 5, newest: 15)
        var engine = makeEngine(provider: provider, scope: scope)

        XCTAssertNil(engine.installVerified(
            items: [messages[3], messages[4]],
            expectedPrimaryIDs: [messages[3].primary, messages[4].primary],
            direction: nil,
            scope: scope
        ))

        messages[5].isDeleted = true
        XCTAssertNil(engine.installVerified(
            items: [messages[5]],
            expectedPrimaryIDs: [messages[5].primary],
            direction: nil,
            scope: scope
        ))
        messages[5].isDeleted = false
        messages[5].opponent = "other@example.com"
        XCTAssertNil(engine.installVerified(
            items: [messages[5]],
            expectedPrimaryIDs: [messages[5].primary],
            direction: nil,
            scope: scope
        ))

        XCTAssertNil(engine.installVerified(
            items: [messages[6]],
            expectedPrimaryIDs: [messages[6].primary, "missing-primary"],
            direction: nil,
            scope: scope
        ))
        XCTAssertTrue(engine.currentSnapshot().items.isEmpty)
    }

    func testScopeRequiresVerifiedSegmentAndMatchingFreshnessProof() throws {
        let oldest = try XCTUnwrap(ArchiveCursor(rawValue: "1"))
        let newest = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        let provisional = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: oldest,
            newest: newest,
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: "session:1",
            isVerified: false
        ))

        XCTAssertNil(ChatTimelineVerifiedScope(
            conversationKey: conversationKey,
            segment: provisional,
            coverageGeneration: 1,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: "provisional-query"
            )
        ))

        let verified = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: oldest,
            newest: newest,
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: "session:1",
            isVerified: true,
            orderedArchiveIDs: (1...10).compactMap { ArchiveCursor(rawValue: String($0)) }
        ))
        XCTAssertNil(ChatTimelineVerifiedScope(
            conversationKey: conversationKey,
            segment: verified,
            coverageGeneration: 1,
            freshnessToken: .sessionMAM(
                connectionGeneration: 2,
                queryID: "different-session-query"
            )
        ))
    }

    private func makeArchiveCollisionPair() -> (MessageStorageItem, MessageStorageItem) {
        let messages = makeOpaqueMessages(["original-outer-UID", "fork/caf\u{00E9}"])
        let original = messages[0]
        let fork = messages[1]
        for item in messages {
            item.messageId = "shared-protocol-origin"
            item.archivedId = "shared-protocol-stanza"
        }
        original.primary = MessageStorageItem.genPrimary(messageId: original.messageId, owner: owner)
        original.body = "original payload"
        original.date = Date(timeIntervalSince1970: 100)
        original.sentDate = original.date
        fork.primary = MessageStorageItem.disambiguatedArchivePrimary(
            messageId: fork.messageId, owner: owner, opponent: jid,
            conversationType: .regular, mamArchiveId: fork.mamArchiveId
        )
        fork.body = "different archived payload"
        fork.date = Date(timeIntervalSince1970: 200)
        fork.sentDate = fork.date
        return (original, fork)
    }

    private var conversationKey: ChatTimelineConversationKey {
        ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
    }

    private func makeEngine(
        provider: ChatTimelinePageProviding,
        scope: ChatTimelineVerifiedScope
    ) -> ChatVirtualTimelineEngine {
        ChatVirtualTimelineEngine(
            provider: provider,
            pageSize: 100,
            state: .empty(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            verifiedScope: scope
        )
    }

    private func makeScope(
        oldest: Int,
        newest: Int,
        reachesArchiveStart: Bool = true,
        reachesLiveEdge: Bool = true,
        generation: UInt64 = 1,
        connectionGeneration: UInt64 = 42
    ) throws -> ChatTimelineVerifiedScope {
        try makeScope(
            orderedIDs: (oldest...newest).map(String.init),
            reachesArchiveStart: reachesArchiveStart,
            reachesLiveEdge: reachesLiveEdge,
            generation: generation,
            connectionGeneration: connectionGeneration
        )
    }

    private func makeScope(
        orderedIDs: [String],
        reachesArchiveStart: Bool = true,
        reachesLiveEdge: Bool = true,
        generation: UInt64 = 1,
        connectionGeneration: UInt64 = 42
    ) throws -> ChatTimelineVerifiedScope {
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            orderedArchiveIDs: orderedIDs.compactMap { ArchiveCursor(rawValue: $0) },
            reachesArchiveStart: reachesArchiveStart,
            reachesLiveEdge: reachesLiveEdge,
            fingerprint: "session:\(connectionGeneration)",
            isVerified: true
        ))
        return try XCTUnwrap(ChatTimelineVerifiedScope(
            conversationKey: conversationKey,
            segment: segment,
            coverageGeneration: generation,
            freshnessToken: .sessionMAM(
                connectionGeneration: connectionGeneration,
                queryID: "query-\(generation)"
            )
        ))
    }

    private func makeOpaqueMessages(_ ids: [String]) -> [MessageStorageItem] {
        ids.enumerated().map { index, id in
            let item = MessageStorageItem()
            item.primary = "opaque-primary-\(index)"
            item.owner = owner
            item.opponent = jid
            item.archivedId = "protocol-\(index)"
            item.mamArchiveId = id
            item.messageId = "opaque-message-\(index)"
            item.date = Date(timeIntervalSince1970: TimeInterval(100_000 - index))
            item.sentDate = item.date
            item.conversationType = .regular
            return item
        }
    }

    private func makeMessages(_ range: ClosedRange<Int>) -> [MessageStorageItem] {
        range.map { value in
            let item = MessageStorageItem()
            item.primary = "primary-\(value)"
            item.owner = owner
            item.opponent = jid
            item.archivedId = String(value)
            item.mamArchiveId = String(value)
            item.messageId = "message-\(value)"
            item.date = Date(timeIntervalSince1970: TimeInterval(value))
            item.sentDate = item.date
            item.conversationType = .regular
            return item
        }
    }

    private func primaryIDs(_ range: ClosedRange<Int>) -> [String] {
        range.map { "primary-\($0)" }
    }

    private func localSnapshot(
        _ outcome: ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatTimelineSnapshot {
        guard case .local(let snapshot) = outcome else {
            XCTFail("Expected local boundary outcome, got \(outcome)", file: file, line: line)
            throw VirtualTimelineTestError.unexpectedOutcome
        }
        return snapshot
    }
}

private enum VirtualTimelineTestError: Error {
    case unexpectedOutcome
}

private final class VirtualTimelinePageProvider: ChatTimelinePageProviding {
    private let messages: [MessageStorageItem]
    private(set) var olderCalls = 0
    private(set) var newerCalls = 0
    private(set) var aroundCalls = 0
    private(set) var archiveCursorQuerySizes: [Int] = []

    init<S: Sequence>(messages: S) where S.Element == MessageStorageItem {
        self.messages = Array(messages)
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        Array(messages.suffix(limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        olderCalls += 1
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else {
            return []
        }
        return Array(messages.prefix(index).suffix(limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        newerCalls += 1
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }),
              index + 1 < messages.count else {
            return []
        }
        return Array(messages[(index + 1)...].prefix(limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        aroundCalls += 1
        guard let index = messages.firstIndex(where: { $0.primary == anchor.primary }) else {
            return []
        }
        let lower = max(0, index - before)
        let upper = min(messages.count, index + after + 1)
        return Array(messages[lower..<upper])
    }

    func message(primary: String?, archivedId: String?, messageId: String?) -> MessageStorageItem? {
        if let primary, let result = messages.first(where: { $0.primary == primary }) {
            return result
        }
        if let archivedId, let result = messages.first(where: { $0.archivedId == archivedId }) {
            return result
        }
        if let messageId, let result = messages.first(where: { $0.messageId == messageId }) {
            return result
        }
        return nil
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        let byPrimary = Dictionary(uniqueKeysWithValues: messages.map { ($0.primary, $0) })
        return primaryKeys.compactMap { byPrimary[$0] }
    }

    func items(archiveCursorIDs: [String]) -> [MessageStorageItem] {
        archiveCursorQuerySizes.append(archiveCursorIDs.count)
        let requested = Set(archiveCursorIDs)
        return messages.filter { requested.contains($0.mamArchiveId) }
    }
}
