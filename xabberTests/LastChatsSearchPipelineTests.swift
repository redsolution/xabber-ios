import XCTest
@testable import xabber

final class LastChatsSearchPipelineTests: XCTestCase {
    private let configuration = LastChatsSearchPipeline.Configuration(
        pageSize: 50,
        maximumResidentPagesPerProvider: 2,
        maximumResidentItems: 120
    )

    func testBeginCreatesOneBoundedRequestPerProviderAndMonotonicGeneration() {
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let providers: [LastChatsSearchProviderID] = [
            .localDirectory,
            .localMessages,
            .encryptedMessages,
            .remoteArchive(owner: "owner@example.com", conversationTypeRawValue: "regular")
        ]

        let first = pipeline.begin(query: " test ", providers: providers)
        let second = pipeline.begin(query: "new", providers: providers)

        XCTAssertEqual(first.count, providers.count)
        XCTAssertTrue(first.allSatisfy { $0.generation == 1 && $0.limit == 50 && $0.cursor == nil })
        XCTAssertEqual(first.map(\.provider), providers)
        XCTAssertTrue(second.allSatisfy { $0.generation == 2 && $0.query == "new" })
        XCTAssertEqual(pipeline.snapshot.generation, 2)
        XCTAssertTrue(pipeline.snapshot.items.isEmpty)
    }

    func testOldGenerationPageFinalAndFailureCannotPublishIntoCurrentSnapshot() throws {
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let provider = LastChatsSearchProviderID.localMessages
        let old = try XCTUnwrap(pipeline.begin(query: "test", providers: [provider]).first)
        _ = pipeline.begin(query: "new", providers: [provider])

        XCTAssertFalse(pipeline.receive(.page(page(for: old, range: 0..<10, next: "older"))))
        XCTAssertFalse(pipeline.receive(.finished(old)))
        XCTAssertFalse(pipeline.receive(.failed(old, reason: .providerUnavailable)))
        XCTAssertTrue(pipeline.snapshot.items.isEmpty)
        XCTAssertEqual(pipeline.snapshot.generation, 2)
    }

    func testIncrementalPagesStayNewestFirstDeduplicateAndNeverFullSort() throws {
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let first = try XCTUnwrap(
            pipeline.begin(query: "test", providers: [.localMessages]).first
        )
        let firstPage = LastChatsSearchProviderPage(
            request: first,
            items: [item(5), item(3), item(4), item(5, revision: 2)],
            nextCursor: .init(opaque: "older-1")
        )

        XCTAssertTrue(pipeline.receive(.page(firstPage)))
        let next = try XCTUnwrap(pipeline.requestNextPage(for: .localMessages))
        XCTAssertTrue(pipeline.receive(.page(page(for: next, range: 0..<3, next: nil))))
        XCTAssertTrue(pipeline.receive(.finished(next)))

        XCTAssertEqual(pipeline.snapshot.items.map(\.stableID), ["5", "4", "3", "2", "1", "0"])
        XCTAssertEqual(pipeline.snapshot.items.first?.revision, 2)
        XCTAssertEqual(pipeline.snapshot.counters.fullSortCount, 0)
        XCTAssertEqual(pipeline.snapshot.counters.acceptedPageCount, 2)
        XCTAssertLessThan(pipeline.snapshot.counters.orderComparisonCount, 30)
    }

    func testDuplicateContinuationRequestIsCoalescedAndTerminalProviderCannotRestart() throws {
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let initial = try XCTUnwrap(
            pipeline.begin(query: "test", providers: [.encryptedMessages]).first
        )
        XCTAssertTrue(pipeline.receive(.page(page(for: initial, range: 50..<55, next: "older"))))

        let next = try XCTUnwrap(pipeline.requestNextPage(for: .encryptedMessages))
        XCTAssertNil(pipeline.requestNextPage(for: .encryptedMessages))
        XCTAssertTrue(pipeline.receive(.page(page(for: next, range: 40..<45, next: nil))))
        XCTAssertTrue(pipeline.receive(.finished(next)))
        XCTAssertNil(pipeline.requestNextPage(for: .encryptedMessages))
        XCTAssertEqual(pipeline.snapshot.counters.coalescedRequestCount, 1)
    }

    func testSlidingProviderPageWindowAndGlobalResidentCapRemainBounded() throws {
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let provider = LastChatsSearchProviderID.localMessages
        var request = try XCTUnwrap(pipeline.begin(query: "test", providers: [provider]).first)

        for pageIndex in 0..<5 {
            let upper = 500 - pageIndex * 30
            let lower = upper - 30
            let nextCursor = pageIndex == 4 ? nil : LastChatsSearchCursor(opaque: "page-\(pageIndex + 1)")
            XCTAssertTrue(
                pipeline.receive(
                    .page(page(for: request, range: lower..<upper, next: nextCursor?.opaque))
                )
            )
            if pageIndex < 4 {
                request = try XCTUnwrap(pipeline.requestNextPage(for: provider))
            }
        }

        XCTAssertLessThanOrEqual(pipeline.snapshot.items.count, 60)
        XCTAssertLessThanOrEqual(pipeline.snapshot.items.count, configuration.maximumResidentItems)
        XCTAssertEqual(pipeline.snapshot.residentPageCount(for: provider), 2)
        XCTAssertGreaterThan(pipeline.snapshot.counters.trimmedItemCount, 0)
        XCTAssertEqual(pipeline.snapshot.items.map(\.stableID), pipeline.snapshot.items.map(\.stableID).sorted(by: >))
    }

    func testLocalRemoteAndEncryptedProvidersShareOnePlanAndEncryptedStaysLocalOnly() {
        let providers = LastChatsSearchProviderPlan.make(enabledOwners: ["a@example.com", "b@example.com"])

        XCTAssertTrue(providers.contains(.localDirectory))
        XCTAssertTrue(providers.contains(.localMessages))
        XCTAssertTrue(providers.contains(.encryptedMessages))
        XCTAssertTrue(providers.contains(.remoteArchive(owner: "a@example.com", conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue)))
        XCTAssertTrue(providers.contains(.remoteArchive(owner: "a@example.com", conversationTypeRawValue: ClientSynchronizationManager.ConversationType.group.rawValue)))
        XCTAssertFalse(providers.contains { provider in
            guard case .remoteArchive(_, let rawValue) = provider else { return false }
            return rawValue.contains("omemo") || rawValue.contains("axolotl")
        })
        XCTAssertEqual(Set(providers).count, providers.count)
    }

    func testLocalRemoteAndEncryptedPagesUseTheSameTerminalContract() throws {
        let providers: [LastChatsSearchProviderID] = [
            .localMessages,
            .encryptedMessages,
            .remoteArchive(
                owner: "owner@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            )
        ]
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let requests = pipeline.begin(query: "test", providers: providers)

        for (index, request) in requests.enumerated() {
            XCTAssertTrue(
                pipeline.receive(
                    .page(
                        LastChatsSearchProviderPage(
                            request: request,
                            items: [item(index + 1)],
                            nextCursor: nil
                        )
                    )
                )
            )
            XCTAssertTrue(pipeline.receive(.finished(request)))
        }

        XCTAssertEqual(pipeline.snapshot.terminalByProvider.count, providers.count)
        XCTAssertTrue(providers.allSatisfy { pipeline.snapshot.terminalByProvider[$0] == .finished })
        XCTAssertFalse(pipeline.snapshot.isLoading)
    }

    func testRealmLocalLoaderSeparatesRegularAndEncryptedRowsAndPagesByKeyset() throws {
        let owner = "g17a-\(UUID().uuidString)@example.com"
        let query = "g17a-bounded-\(UUID().uuidString)"
        let realm = try WRealm.safe()
        var rows: [MessageStorageItem] = []
        for index in 0..<130 {
            let row = MessageStorageItem()
            row.primary = "g17a-regular-\(index)-\(UUID().uuidString)"
            row.owner = owner
            row.opponent = "regular@example.com"
            row.body = "\(query)-regular"
            row.messageType = MessageStorageItem.MessageDisplayType.text.rawValue
            row.conversationType = .regular
            row.date = Date(timeIntervalSince1970: TimeInterval(10_000 + index))
            rows.append(row)
        }
        for index in 0..<70 {
            let row = MessageStorageItem()
            row.primary = "g17a-encrypted-\(index)-\(UUID().uuidString)"
            row.owner = owner
            row.opponent = "encrypted@example.com"
            row.body = "\(query)-encrypted"
            row.messageType = MessageStorageItem.MessageDisplayType.text.rawValue
            row.conversationType = .omemo
            row.date = Date(timeIntervalSince1970: TimeInterval(20_000 + index))
            rows.append(row)
        }
        try realm.write {
            realm.add(rows)
        }
        defer {
            try? realm.write {
                realm.delete(realm.objects(MessageStorageItem.self).filter("owner == %@", owner))
            }
        }

        let loader = LastChatsSearchLocalPageLoader(enabledOwners: [owner])
        let regularRequest = LastChatsSearchPageRequest(
            generation: 1,
            provider: .localMessages,
            query: query,
            cursor: nil,
            ordinal: 0,
            limit: 50
        )
        let regularFirst = loader.load(regularRequest)
        let regularSecond = loader.load(
            LastChatsSearchPageRequest(
                generation: 1,
                provider: .localMessages,
                query: query,
                cursor: try XCTUnwrap(regularFirst.nextCursor),
                ordinal: 1,
                limit: 50
            )
        )
        let encrypted = loader.load(
            LastChatsSearchPageRequest(
                generation: 1,
                provider: .encryptedMessages,
                query: query,
                cursor: nil,
                ordinal: 0,
                limit: 50
            )
        )

        XCTAssertEqual(regularFirst.items.count, 50)
        XCTAssertEqual(regularSecond.items.count, 50)
        XCTAssertEqual(encrypted.items.count, 50)
        XCTAssertNotNil(regularSecond.nextCursor)
        XCTAssertNotNil(encrypted.nextCursor)
        XCTAssertTrue(regularFirst.items.allSatisfy {
            $0.conversationTypeRawValue == ClientSynchronizationManager.ConversationType.regular.rawValue
        })
        XCTAssertTrue(regularFirst.items.allSatisfy {
            $0.provenance?.targetKind == .message
                && $0.provenance?.provider == .localMessages
                && $0.provenance?.queryGeneration == regularRequest.generation
                && $0.provenance?.messagePrimary == $0.storagePrimary
                && $0.provenance?.sourceDate == $0.date
        })
        XCTAssertTrue(encrypted.items.allSatisfy {
            $0.conversationTypeRawValue == ClientSynchronizationManager.ConversationType.omemo.rawValue
        })
        XCTAssertLessThan(regularSecond.items[0].date, regularFirst.items.last?.date ?? .distantPast)
    }

    func testHundredAndMillionMatchingRowsMaterializeOnlyPageSizePlusLookahead() {
        let hundred = CountingIntegerCollection(count: 100)
        let million = CountingIntegerCollection(count: 1_000_000)

        let hundredPage = LastChatsSearchPageMaterializer.materialize(hundred, limit: 50) { String($0) }
        let millionPage = LastChatsSearchPageMaterializer.materialize(million, limit: 50) { String($0) }

        XCTAssertEqual(hundredPage.items.count, 50)
        XCTAssertEqual(millionPage.items.count, 50)
        XCTAssertTrue(hundredPage.hasMore)
        XCTAssertTrue(millionPage.hasMore)
        XCTAssertEqual(hundredPage.metrics.materializedCount, 51)
        XCTAssertEqual(millionPage.metrics.materializedCount, 51)
        XCTAssertEqual(hundred.readCount, 51)
        XCTAssertEqual(million.readCount, 51)
    }

    func testMillionNonmatchingProjectionMaterializesZeroRows() {
        let nonmatching = CountingIntegerCollection(count: 0, logicalSourceCount: 1_000_000)

        let page = LastChatsSearchPageMaterializer.materialize(nonmatching, limit: 50) { String($0) }

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.metrics.materializedCount, 0)
        XCTAssertEqual(page.metrics.logicalSourceCount, 1_000_000)
        XCTAssertEqual(nonmatching.readCount, 0)
    }

    func testCancellationInvalidatesGenerationAndRejectsLateCurrentRequestCallbacks() throws {
        var pipeline = LastChatsSearchPipeline(configuration: configuration)
        let request = try XCTUnwrap(
            pipeline.begin(query: "test", providers: [.localMessages]).first
        )

        pipeline.cancel()

        XCTAssertFalse(pipeline.receive(.page(page(for: request, range: 0..<5, next: nil))))
        XCTAssertFalse(pipeline.receive(.finished(request)))
        XCTAssertTrue(pipeline.snapshot.items.isEmpty)
        XCTAssertTrue(pipeline.snapshot.isCancelled)
        XCTAssertGreaterThan(pipeline.snapshot.generation, request.generation)
    }

    func testBackgroundPageExecutorCancelsBeforePublicationAndDeliversAcceptedPageOnMain() async throws {
        let expectation = expectation(description: "accepted page")
        let request = LastChatsSearchPageRequest(
            generation: 1,
            provider: .localMessages,
            query: "test",
            cursor: nil,
            ordinal: 0,
            limit: 50
        )
        let executor = LastChatsSearchBackgroundPageExecutor { request in
            XCTAssertFalse(Thread.isMainThread)
            return LastChatsSearchProviderPage(
                request: request,
                items: [self.item(1)],
                nextCursor: nil
            )
        }
        let cancelled = executor.load(request: request) { _ in
            XCTFail("Cancelled page must not publish")
        }
        cancelled.cancel()

        _ = executor.load(request: request) { page in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(page.items.map(\.stableID), ["1"])
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2)
    }

    func testSourcePolicyRemovesFullMessageMaterializationAndWholeQueueSortFromLastChatsController() throws {
        let source = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("xabber/controllers/chats/search/SearchResultsViewController.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(
            source.slice(
                from: "final class ChatSearchResultsController",
                to: "extension SearchResultsViewController:"
            )
        )

        XCTAssertFalse(body.contains(".toArray()"))
        XCTAssertFalse(body.contains("messagesQueue.sorted"))
        XCTAssertFalse(body.contains("messagesQueue.append"))
        XCTAssertTrue(body.contains("LastChatsSearchPipeline"))
        XCTAssertTrue(body.contains("LastChatsSearchBackgroundPageExecutor"))
    }

    private func page(
        for request: LastChatsSearchPageRequest,
        range: Range<Int>,
        next: String?
    ) -> LastChatsSearchProviderPage {
        LastChatsSearchProviderPage(
            request: request,
            items: range.map { item($0) },
            nextCursor: next.map(LastChatsSearchCursor.init(opaque:))
        )
    }

    private func item(_ index: Int, revision: UInt64 = 1) -> LastChatsSearchItem {
        LastChatsSearchItem(
            stableID: String(index),
            kind: .message,
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationTypeRawValue: "regular",
            storagePrimary: "primary-\(index)",
            date: Date(timeIntervalSince1970: TimeInterval(index)),
            revision: revision
        )
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class CountingIntegerCollection: RandomAccessCollection, LastChatsSearchLogicalSourceCountProviding {
    typealias Index = Int
    typealias Element = Int

    let startIndex = 0
    let endIndex: Int
    let logicalSourceCount: Int
    private(set) var readCount = 0

    init(count: Int, logicalSourceCount: Int? = nil) {
        endIndex = count
        self.logicalSourceCount = logicalSourceCount ?? count
    }

    subscript(position: Int) -> Int {
        readCount += 1
        return position
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
