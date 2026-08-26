import XCTest
@testable import xabber

final class ChatVirtualTimelineEngineTests: XCTestCase {
    private let owner = "owner@example.com"
    private let jid = "chat@example.com"

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
            isVerified: true
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
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: String(oldest))),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: String(newest))),
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

    private func makeMessages(_ range: ClosedRange<Int>) -> [MessageStorageItem] {
        range.map { value in
            let item = MessageStorageItem()
            item.primary = "primary-\(value)"
            item.owner = owner
            item.opponent = jid
            item.archivedId = String(value)
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

    init(messages: [MessageStorageItem]) {
        self.messages = ChatTimelineOrdering.deduplicatedChronological(messages)
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        Array(messages.suffix(limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else {
            return []
        }
        return Array(messages.prefix(index).suffix(limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }),
              index + 1 < messages.count else {
            return []
        }
        return Array(messages[(index + 1)...].prefix(limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
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
}
