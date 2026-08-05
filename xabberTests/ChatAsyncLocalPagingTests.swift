import XCTest
@testable import xabber

final class ChatAsyncLocalPagingTests: XCTestCase {
    private let owner = "owner@example.com"
    private let jid = "chat@example.com"

    func testTypedOlderAndNewerLoadsPrepareOffMainWithExactDirection() throws {
        let store = AsyncLocalPagingStore(messages: makeMessages(count: 40))
        let session = makeSession(store: store, pageSize: 4)
        let latest = session.openLatest()
        store.resetQueryRecords()

        let olderExpectation = expectation(description: "older prepared")
        var olderPage: ChatTimelinePreparedLocalPage?
        let olderDisposition = session.loadOlder(
            before: try XCTUnwrap(latest.oldest),
            archiveState: archiveState(),
            expectedGeneration: latest.generation
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .prepared(let page) = result {
                olderPage = page
            }
            olderExpectation.fulfill()
        }

        XCTAssertEqual(olderDisposition, .started)
        wait(for: [olderExpectation], timeout: 2)
        XCTAssertEqual(olderPage?.direction, .older)
        XCTAssertFalse(olderPage?.preparedOnMainThread ?? true)
        XCTAssertEqual(store.queryCounts, QueryCounts(older: 1, newer: 0, resident: 0))

        let around = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-20",
                archivedId: nil,
                messageId: nil,
                date: nil
            )
        )
        store.resetQueryRecords()
        let newerExpectation = expectation(description: "newer prepared")
        var newerPage: ChatTimelinePreparedLocalPage?
        let newerDisposition = session.loadNewer(
            after: try XCTUnwrap(around.newest),
            archiveState: archiveState(),
            expectedGeneration: around.generation
        ) { result in
            if case .prepared(let page) = result {
                newerPage = page
            }
            newerExpectation.fulfill()
        }

        XCTAssertEqual(newerDisposition, .started)
        wait(for: [newerExpectation], timeout: 2)
        XCTAssertEqual(newerPage?.direction, .newer)
        XCTAssertFalse(newerPage?.preparedOnMainThread ?? true)
        XCTAssertEqual(store.queryCounts, QueryCounts(older: 0, newer: 1, resident: 0))
    }

    func testDuplicateBoundaryIntentCoalescesToOneQueryAndOneCompletion() throws {
        let store = AsyncLocalPagingStore(messages: makeMessages(count: 40))
        let session = makeSession(store: store, pageSize: 4)
        let base = session.openLatest()
        store.resetQueryRecords()
        store.blockNextDirectionalQuery()

        let completionExpectation = expectation(description: "single completion")
        completionExpectation.expectedFulfillmentCount = 1
        var completionCount = 0
        let completion: (ChatTimelineLocalPagePreparationResult) -> Void = { _ in
            completionCount += 1
            completionExpectation.fulfill()
        }
        let boundary = try XCTUnwrap(base.oldest)

        let first = session.loadOlder(
            before: boundary,
            archiveState: archiveState(),
            expectedGeneration: base.generation,
            completion: completion
        )
        XCTAssertTrue(store.waitUntilDirectionalQueryStarts(timeout: 1))
        let duplicate = session.loadOlder(
            before: boundary,
            archiveState: archiveState(),
            expectedGeneration: base.generation,
            completion: completion
        )

        XCTAssertEqual(first, .started)
        XCTAssertEqual(duplicate, .coalesced)
        store.releaseDirectionalQuery()
        wait(for: [completionExpectation], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(store.queryCounts, QueryCounts(older: 1, newer: 0, resident: 0))
    }

    func testPreparedPageCommitsExactlyOnceWithoutSecondProviderQuery() throws {
        let store = AsyncLocalPagingStore(messages: makeMessages(count: 40))
        let session = makeSession(store: store, pageSize: 4)
        let base = session.openLatest()
        store.resetQueryRecords()
        let preparedExpectation = expectation(description: "prepared")
        var prepared: ChatTimelinePreparedLocalPage?

        _ = session.loadOlder(
            before: try XCTUnwrap(base.oldest),
            archiveState: archiveState(),
            expectedGeneration: base.generation
        ) { result in
            if case .prepared(let page) = result {
                prepared = page
            }
            preparedExpectation.fulfill()
        }
        wait(for: [preparedExpectation], timeout: 2)
        let page = try XCTUnwrap(prepared)

        let firstCommit = session.commitPreparedLocalPage(page)
        let secondCommit = session.commitPreparedLocalPage(page)

        XCTAssertNotNil(firstCommit)
        XCTAssertNil(secondCommit)
        XCTAssertEqual(store.queryCounts, QueryCounts(older: 1, newer: 0, resident: 0))
        XCTAssertGreaterThan(firstCommit?.generation ?? 0, base.generation)
    }

    func testGenerationChangeMakesInFlightPageStaleAndUncommittable() throws {
        let store = AsyncLocalPagingStore(messages: makeMessages(count: 40))
        let session = makeSession(store: store, pageSize: 4)
        let base = session.openLatest()
        store.resetQueryRecords()
        store.blockNextDirectionalQuery()
        let staleExpectation = expectation(description: "stale")
        var resultWasStale = false

        _ = session.loadOlder(
            before: try XCTUnwrap(base.oldest),
            archiveState: archiveState(),
            expectedGeneration: base.generation
        ) { result in
            if case .stale = result {
                resultWasStale = true
            }
            staleExpectation.fulfill()
        }
        XCTAssertTrue(store.waitUntilDirectionalQueryStarts(timeout: 1))
        _ = session.openLatest(limit: 8)
        store.releaseDirectionalQuery()

        wait(for: [staleExpectation], timeout: 2)
        XCTAssertTrue(resultWasStale)
        XCTAssertEqual(store.queryCounts, QueryCounts(older: 1, newer: 0, resident: 0))
    }

    func testTerminalCancellationClearsActivePreparationAndDeliversOnlyStaleCompletion() throws {
        let store = AsyncLocalPagingStore(messages: makeMessages(count: 40))
        let session = makeSession(store: store, pageSize: 4)
        let base = session.openLatest()
        store.resetQueryRecords()
        store.blockNextDirectionalQuery()
        let staleExpectation = expectation(description: "cancelled preparation is stale")
        var resultWasStale = false

        _ = session.loadOlder(
            before: try XCTUnwrap(base.oldest),
            archiveState: archiveState(),
            expectedGeneration: base.generation
        ) { result in
            if case .stale = result {
                resultWasStale = true
            }
            staleExpectation.fulfill()
        }
        XCTAssertTrue(store.waitUntilDirectionalQueryStarts(timeout: 1))
        XCTAssertEqual(session.activePreparationCount, 1)

        session.cancelLocalPagePreparations()
        XCTAssertEqual(session.activePreparationCount, 0)
        store.releaseDirectionalQuery()

        wait(for: [staleExpectation], timeout: 2)
        XCTAssertTrue(resultWasStale)
        XCTAssertEqual(session.activePreparationCount, 0)
    }

    func testShortLocalPageAndLocalEndRemainTypedPreparedResults() throws {
        let shortStore = AsyncLocalPagingStore(messages: makeMessages(count: 11))
        let shortSession = makeSession(store: shortStore, pageSize: 2)
        let shortBase = shortSession.openLatest()
        let shortExpectation = expectation(description: "short")
        var shortDecision: ChatHistoryPagingLoadDecision?
        _ = shortSession.loadOlder(
            before: try XCTUnwrap(shortBase.oldest),
            archiveState: archiveState(),
            expectedGeneration: shortBase.generation
        ) { result in
            if case .prepared(let page) = result {
                shortDecision = page.snapshot.loadDecision
            }
            shortExpectation.fulfill()
        }

        let endStore = AsyncLocalPagingStore(messages: makeMessages(count: 10))
        let endSession = makeSession(store: endStore, pageSize: 2)
        let endBase = endSession.openLatest()
        let endExpectation = expectation(description: "end")
        var endDecision: ChatHistoryPagingLoadDecision?
        _ = endSession.loadOlder(
            before: try XCTUnwrap(endBase.oldest),
            archiveState: archiveState(),
            expectedGeneration: endBase.generation
        ) { result in
            if case .prepared(let page) = result {
                endDecision = page.snapshot.loadDecision
            }
            endExpectation.fulfill()
        }

        wait(for: [shortExpectation, endExpectation], timeout: 2)
        XCTAssertEqual(shortDecision, .localOnly)
        XCTAssertEqual(endDecision, .endReached)
    }

    func testLiveStoreRefreshKeepsTheCurrentResidentLimitBeforePaging() {
        let store = AsyncLocalPagingStore(messages: makeMessages(count: 40))
        let session = makeSession(store: store, pageSize: 10)
        let initial = session.openLatest(limit: 4)

        store.emit(.latestChanged)

        XCTAssertEqual(initial.items.count, 4)
        XCTAssertEqual(session.snapshot.items.count, 4)
        XCTAssertEqual(session.snapshot.items.map(\.primary), initial.items.map(\.primary))
    }

    private func makeSession(store: AsyncLocalPagingStore, pageSize: Int) -> ChatTimelineSession {
        ChatTimelineSession(
            store: store,
            pageSize: pageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: archiveState()
        )
    }

    private func archiveState() -> ChatArchiveStateSnapshot {
        ChatArchiveStateSnapshot(
            primaryKey: "archive-state",
            persistedCursorId: nil,
            fullArchiveLoaded: true,
            newestCursorId: nil,
            newerLiveEdgeReached: true,
            hasKnownNewerGap: false,
            knownGaps: []
        )
    }

    private func makeMessages(count: Int) -> [MessageStorageItem] {
        (0..<count).map { index in
            let item = MessageStorageItem()
            item.primary = "primary-\(index)"
            item.owner = owner
            item.opponent = jid
            item.archivedId = "archive-\(index)"
            item.messageId = "message-\(index)"
            item.date = Date(timeIntervalSince1970: TimeInterval(index / 3))
            item.sentDate = item.date
            item.historyPositionOrdinal = Int64(index)
            item.conversationType = .regular
            return item
        }
    }
}

final class ChatAsyncLocalPagingSourcePolicyTests: XCTestCase {
    func testControllerDoesNotSynchronouslyPreviewOrAdvanceLocalSessionPages() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(controllerSource.contains("session.previewPage("))
        XCTAssertFalse(controllerSource.contains("timelineSession.pageOlder()"))
        XCTAssertFalse(controllerSource.contains("timelineSession.pageNewer()"))

        let sessionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatTimelineSession.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(sessionSource.contains("func previewPage("))
    }
}

private struct QueryCounts: Equatable {
    let older: Int
    let newer: Int
    let resident: Int
}

private final class AsyncLocalPagingStore: ChatTimelineSessionStore {
    private let lock = NSLock()
    private let messages: [MessageStorageItem]
    private var olderQueryCount = 0
    private var newerQueryCount = 0
    private var residentQueryCount = 0
    private var onChange: ((ChatTimelineStoreChange) -> Void)?
    private var directionalQueryStarted = DispatchSemaphore(value: 0)
    private var directionalQueryRelease: DispatchSemaphore?

    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot { .empty }
    var queryCounts: QueryCounts {
        lock.withAsyncPagingLock {
            QueryCounts(
                older: olderQueryCount,
                newer: newerQueryCount,
                resident: residentQueryCount
            )
        }
    }

    init(messages: [MessageStorageItem]) {
        self.messages = ChatTimelineOrdering.chronological(messages)
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        Array(messages.suffix(limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        recordDirectionalQuery(isOlder: true)
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else { return [] }
        return Array(messages.prefix(index).suffix(limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        recordDirectionalQuery(isOlder: false)
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else { return [] }
        return Array(messages.suffix(from: messages.index(after: index)).prefix(limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: { $0.primary == anchor.primary }) else { return [] }
        let lower = max(0, index - before)
        let upper = min(messages.count, index + after + 1)
        return Array(messages[lower..<upper])
    }

    func message(primary: String?, archivedId: String?, messageId: String?) -> MessageStorageItem? {
        if let primary, let item = messages.first(where: { $0.primary == primary }) { return item }
        if let archivedId, let item = messages.first(where: { $0.archivedId == archivedId }) { return item }
        if let messageId, let item = messages.first(where: { $0.messageId == messageId }) { return item }
        return nil
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        lock.withAsyncPagingLock {
            residentQueryCount += 1
        }
        let requested = Set(primaryKeys)
        return messages.filter { requested.contains($0.primary) }
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata { .empty }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? { nil }

    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        lock.withAsyncPagingLock {
            self.onChange = onChange
        }
        return AsyncLocalPagingObservation()
    }

    func emit(_ change: ChatTimelineStoreChange) {
        lock.withAsyncPagingLock { onChange }?(change)
    }

    func resetQueryRecords() {
        lock.withAsyncPagingLock {
            olderQueryCount = 0
            newerQueryCount = 0
            residentQueryCount = 0
        }
    }

    func blockNextDirectionalQuery() {
        lock.withAsyncPagingLock {
            directionalQueryStarted = DispatchSemaphore(value: 0)
            directionalQueryRelease = DispatchSemaphore(value: 0)
        }
    }

    func waitUntilDirectionalQueryStarts(timeout: TimeInterval) -> Bool {
        directionalQueryStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseDirectionalQuery() {
        lock.withAsyncPagingLock { directionalQueryRelease }?.signal()
    }

    private func recordDirectionalQuery(isOlder: Bool) {
        let release = lock.withAsyncPagingLock { () -> DispatchSemaphore? in
            if isOlder {
                olderQueryCount += 1
            } else {
                newerQueryCount += 1
            }
            directionalQueryStarted.signal()
            return directionalQueryRelease
        }
        release?.wait()
    }
}

private final class AsyncLocalPagingObservation: ChatTimelineStoreObservation {
    func replaceResidentItems(_ items: [MessageStorageItem]) {}
    func invalidate() {}
}

private extension NSLocking {
    func withAsyncPagingLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
