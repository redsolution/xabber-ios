//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import XCTest
import RealmSwift
@testable import xabber

final class ChatSearchLocalProviderTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var testConfiguration: Realm.Configuration!
    private var realm: Realm!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatSearchLocalProviderTests-\(name)-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        testConfiguration = configuration
        realm = try Realm(configuration: configuration)
    }

    override func tearDownWithError() throws {
        XCTAssertNotNil(testConfiguration.inMemoryIdentifier)
        XCTAssertNil(testConfiguration.fileURL)
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        try super.tearDownWithError()
    }

    func testStrictEncryptedScopeExcludesDeletedSystemAndOtherConversationRows() throws {
        try add([
            makeMessage(primary: "matching", body: "test visible"),
            makeMessage(primary: "wrong-owner", owner: "other@example.com", body: "test"),
            makeMessage(primary: "wrong-jid", jid: "alexey@example.com", body: "test"),
            makeMessage(primary: "wrong-type", conversationType: .regular, body: "test"),
            makeMessage(primary: "deleted", body: "test", isDeleted: true),
            makeMessage(primary: "system", body: "test", messageType: .system),
            makeMessage(primary: "reported", body: "test", isLocallyHiddenByReport: true)
        ])
        let provider = makeProvider()
        let completed = expectation(description: "local provider completed")
        var results: [ChatSearchResult] = []

        provider.search(makeRequest(queryId: "strict")) { event in
            switch event.phase {
            case .batch(let batch):
                results.append(contentsOf: batch)
            case .completed(let total):
                XCTAssertEqual(total, 1)
                completed.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(results.map(\.anchor.primary), ["matching"])
        XCTAssertEqual(ChatSearchLocalProvider.backend, .localRealm)
    }

    func testMatchingIsCaseAndDiacriticInsensitive() throws {
        try add([
            makeMessage(primary: "lower", body: "test"),
            makeMessage(primary: "upper", body: "TEST"),
            makeMessage(primary: "diacritic", body: "Tést"),
            makeMessage(primary: "miss", body: "toast")
        ])
        let provider = makeProvider()
        let completed = expectation(description: "matching completed")
        var identities: Set<ChatSearchResult.ID> = []

        provider.search(makeRequest(queryId: "matching")) { event in
            switch event.phase {
            case .batch(let batch):
                identities.formUnion(batch.map(\.id))
            case .completed:
                completed.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(
            identities,
            [.primary("lower"), .primary("upper"), .primary("diacritic")]
        )
    }

    func testResultsAreNewestFirstWithDeterministicTieBreakAndDuplicateCollapse() throws {
        let date = Date(timeIntervalSince1970: 100)
        try add([
            makeMessage(primary: "older", archivedId: "1", body: "test", date: date.addingTimeInterval(-1)),
            makeMessage(primary: "archive-low", archivedId: "10", body: "test", date: date),
            makeMessage(primary: "archive-high", archivedId: "20", body: "test", date: date),
            makeMessage(primary: "duplicate-sparse", archivedId: "30", body: "test", date: date),
            makeMessage(primary: "duplicate-complete", archivedId: "30", body: "test complete", date: date, state: .read)
        ])
        let provider = makeProvider(batchSize: 2)
        let completed = expectation(description: "ordering completed")
        var results: [ChatSearchResult] = []

        provider.search(makeRequest(queryId: "ordering")) { event in
            switch event.phase {
            case .batch(let batch):
                results.append(contentsOf: batch)
            case .completed(let total):
                XCTAssertEqual(total, 4)
                completed.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(
            results.map(\.id),
            [.archived("30"), .archived("20"), .archived("10"), .archived("1")]
        )
        XCTAssertEqual(results.first?.anchor.primary, "duplicate-complete")
    }

    func testMoreThan250RowsArriveInBoundedMainThreadBatchesWhileRealmReadIsOffMain() throws {
        try add((0..<275).map { index in
            makeMessage(
                primary: "message-\(index)",
                archivedId: "\(index)",
                body: "test \(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        })
        let realmOpenedOffMain = LockedBox(false)
        let provider = ChatSearchLocalProvider(
            realmConfiguration: testConfiguration,
            batchSize: 32,
            realmFactory: { configuration in
                realmOpenedOffMain.withValue { $0 = !Thread.isMainThread }
                return try Realm(configuration: configuration)
            }
        )
        let completed = expectation(description: "large result completed")
        var batches: [[ChatSearchResult]] = []

        provider.search(makeRequest(queryId: "large")) { event in
            XCTAssertTrue(Thread.isMainThread)
            switch event.phase {
            case .batch(let batch):
                XCTAssertLessThanOrEqual(batch.count, 32)
                batches.append(batch)
            case .completed(let total):
                XCTAssertEqual(total, 275)
                completed.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [completed], timeout: 3)
        XCTAssertTrue(realmOpenedOffMain.value)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }.count, 275)
        XCTAssertEqual(batches.first?.first?.anchor.primary, "message-274")
    }

    func testQueryReplacementSuppressesQueuedBatchesAndCompletionFromOldRequest() throws {
        try add((0..<300).map { index in
            makeMessage(
                primary: "old-\(index)",
                body: "test old \(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        } + [makeMessage(primary: "replacement", body: "replacement")])
        let provider = makeProvider(batchSize: 16)
        let replacementCompleted = expectation(description: "replacement completed")
        let oldCompleted = expectation(description: "old must not complete")
        oldCompleted.isInverted = true
        var oldBatchCount = 0
        var replacementResults: [ChatSearchResult] = []

        provider.search(makeRequest(queryId: "old")) { event in
            switch event.phase {
            case .batch:
                oldBatchCount += 1
                if oldBatchCount == 1 {
                    provider.search(self.makeRequest(queryId: "replacement", query: "replacement")) { replacementEvent in
                        switch replacementEvent.phase {
                        case .batch(let batch):
                            replacementResults.append(contentsOf: batch)
                        case .completed:
                            replacementCompleted.fulfill()
                        case .failed(let failure):
                            XCTFail("Unexpected replacement failure: \(failure)")
                        }
                    }
                }
            case .completed:
                oldCompleted.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected old failure: \(failure)")
            }
        }

        wait(for: [replacementCompleted, oldCompleted], timeout: 2)
        XCTAssertEqual(oldBatchCount, 1)
        XCTAssertEqual(replacementResults.map(\.anchor.primary), ["replacement"])
    }

    func testExplicitCancelStopsFurtherBatchApplication() throws {
        try add((0..<300).map { index in
            makeMessage(primary: "cancel-\(index)", body: "test \(index)")
        })
        let provider = makeProvider(batchSize: 16)
        let firstBatch = expectation(description: "first batch")
        let terminal = expectation(description: "cancelled query must not complete")
        terminal.isInverted = true
        let request = makeRequest(queryId: "cancel")
        var batchCount = 0

        provider.search(request) { event in
            switch event.phase {
            case .batch:
                batchCount += 1
                if batchCount == 1 {
                    XCTAssertTrue(provider.cancel(queryId: request.queryId, generation: request.generation))
                    firstBatch.fulfill()
                }
            case .completed:
                terminal.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [firstBatch, terminal], timeout: 1)
        XCTAssertEqual(batchCount, 1)
    }

    func testEmptyQueryCompletesWithoutOpeningRealmOrScanningBodies() {
        let realmOpenCount = LockedBox(0)
        let provider = ChatSearchLocalProvider(
            realmConfiguration: testConfiguration,
            batchSize: 32,
            realmFactory: { configuration in
                realmOpenCount.withValue { $0 += 1 }
                return try Realm(configuration: configuration)
            }
        )
        let completed = expectation(description: "empty completed")

        provider.search(makeRequest(queryId: "empty", query: "   \n")) { event in
            switch event.phase {
            case .batch:
                XCTFail("Empty query must not emit a batch")
            case .completed(let total):
                XCTAssertEqual(total, 0)
                completed.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(realmOpenCount.value, 0)
    }

    func testRegularScopeIsRejectedWithoutOpeningRealmOrRemoteMAM() {
        let realmOpenCount = LockedBox(0)
        let provider = ChatSearchLocalProvider(
            realmConfiguration: testConfiguration,
            batchSize: 32,
            realmFactory: { configuration in
                realmOpenCount.withValue { $0 += 1 }
                return try Realm(configuration: configuration)
            }
        )
        let failed = expectation(description: "regular scope rejected")
        let request = makeRequest(queryId: "regular", conversationType: .regular)

        provider.search(request) { event in
            switch event.phase {
            case .batch, .completed:
                XCTFail("Regular scope must not use the local provider")
            case .failed(let failure):
                XCTAssertEqual(
                    failure,
                    .unsupportedConversationType(
                        ClientSynchronizationManager.ConversationType.regular.rawValue
                    )
                )
                failed.fulfill()
            }
        }

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(realmOpenCount.value, 0)
        XCTAssertEqual(ChatSearchLocalProvider.backend, .localRealm)
    }

    func testResultsAreDetachedFromRealmMutation() throws {
        let item = makeMessage(primary: "detached", archivedId: "7", body: "test before")
        try add([item])
        let provider = makeProvider()
        let completed = expectation(description: "detached completed")
        var captured: ChatSearchResult?

        provider.search(makeRequest(queryId: "detached")) { event in
            switch event.phase {
            case .batch(let batch):
                captured = batch.first
            case .completed:
                completed.fulfill()
            case .failed(let failure):
                XCTFail("Unexpected failure: \(failure)")
            }
        }

        wait(for: [completed], timeout: 2)
        let stored = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "detached"))
        try realm.write {
            stored.body = "after"
            stored.archivedId = "changed"
        }

        XCTAssertEqual(captured?.body, "test before")
        XCTAssertEqual(captured?.id, .archived("7"))
    }

    private func makeProvider(batchSize: Int = 64) -> ChatSearchLocalProvider {
        ChatSearchLocalProvider(
            realmConfiguration: testConfiguration,
            batchSize: batchSize
        )
    }

    private func makeRequest(
        queryId: String,
        query: String = "test",
        generation: UInt64 = 1,
        conversationType: ClientSynchronizationManager.ConversationType = .omemo
    ) -> ChatSearchLocalProvider.Request {
        ChatSearchLocalProvider.Request(
            generation: generation,
            queryId: queryId,
            query: query,
            mappingContext: ChatSearchResultMappingContext(
                scope: ChatSearchResult.Scope(
                    owner: "owner@example.com",
                    jid: "andrew@example.com",
                    conversationTypeRawValue: conversationType.rawValue
                ),
                localizedYou: "You",
                contactDisplayName: "Andrew Nenakhov"
            )
        )
    }

    private func add(_ items: [MessageStorageItem]) throws {
        try realm.write {
            realm.add(items)
        }
    }

    private func makeMessage(
        primary: String,
        archivedId: String = "",
        owner: String = "owner@example.com",
        jid: String = "andrew@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .omemo,
        body: String,
        date: Date = Date(timeIntervalSince1970: 100),
        isDeleted: Bool = false,
        messageType: MessageStorageItem.MessageDisplayType = .text,
        isLocallyHiddenByReport: Bool = false,
        state: MessageStorageItem.MessageSendingState = .none
    ) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = primary
        item.archivedId = archivedId
        item.owner = owner
        item.opponent = jid
        item.conversationType = conversationType
        item.body = body
        item.date = date
        item.isDeleted = isDeleted
        item.messageType = messageType.rawValue
        item.isLocallyHiddenByReport = isLocallyHiddenByReport
        item.state = state
        return item
    }
}

private final class LockedBox<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
