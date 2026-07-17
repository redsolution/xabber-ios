import XCTest
import RealmSwift
@testable import xabber

final class ChatPerformanceLabTests: XCTestCase {
    func testFixtureScalesExposeEveryGoalDatasetSize() {
        XCTAssertEqual(
            ChatPerformanceFixtureScale.allCases.map(\.rowCount),
            [100, 10_000, 100_000, 1_000_000]
        )
    }

    func testMillionRowFixtureStreamsOneRowAtATimeAndCleansUp() throws {
        let store = CountingFixtureStore(isEphemeral: true)

        let run = try ChatPerformanceFixtureGenerator.withFixture(
            scale: .million,
            batchSize: 4_096,
            store: store
        ) { report in
            XCTAssertEqual(store.persistedRowCount, 1_000_000)
            return report.persistedRowCount
        }

        XCTAssertEqual(run.result, 1_000_000)
        XCTAssertEqual(run.generation.maximumGeneratedRowsInMemory, 1)
        XCTAssertEqual(run.generation.batchCount, 245)
        XCTAssertEqual(run.deletedRowCount, 1_000_000)
        XCTAssertEqual(run.remainingRowCountAfterCleanup, 0)
    }

    func testThinFixturePersistsInIsolatedRealmAndCleansUp() throws {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatPerformanceLabTests-\(UUID().uuidString)"
        )
        let realm = try Realm(configuration: configuration)
        let store = RealmFixtureStore(realm: realm)

        let run = try ChatPerformanceFixtureGenerator.withFixture(
            scale: .small,
            batchSize: 32,
            store: store
        ) { report in
            XCTAssertEqual(report.persistedRowCount, 100)
            XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 100)
            return realm.objects(MessageStorageItem.self).last?.primary
        }

        XCTAssertEqual(run.result, "chat-performance-fixture-99")
        XCTAssertEqual(run.deletedRowCount, 100)
        XCTAssertEqual(run.remainingRowCountAfterCleanup, 0)
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 0)
    }

    func testFixtureRefusesNonEphemeralStoreBeforeWriting() {
        let store = CountingFixtureStore(isEphemeral: false)

        XCTAssertThrowsError(try ChatPerformanceFixtureGenerator.withFixture(
            scale: .small,
            batchSize: 16,
            store: store,
            body: { _ in () }
        )) { error in
            XCTAssertEqual(error as? ChatPerformanceFixtureError, .storeIsNotEphemeral)
        }

        XCTAssertEqual(store.persistedRowCount, 0)
        XCTAssertEqual(store.cleanupCallCount, 0)
    }

    func testFixtureCleansPartialRowsWhenPersistenceFails() {
        let store = CountingFixtureStore(isEphemeral: true, failingOrdinal: 7)

        XCTAssertThrowsError(try ChatPerformanceFixtureGenerator.withFixture(
            scale: .small,
            batchSize: 16,
            store: store,
            body: { _ in () }
        ))

        XCTAssertEqual(store.cleanupCallCount, 1)
        XCTAssertEqual(store.persistedRowCount, 0)
    }

    func testRichFixtureCoversEveryRequiredRenderFeature() {
        let rows = ChatPerformanceRichFixture.rows
        let features = rows.reduce(into: ChatPerformanceFixtureFeature()) { partial, row in
            partial.formUnion(row.features)
        }

        XCTAssertTrue(features.isSuperset(of: .allRequired))
        XCTAssertTrue(rows.contains { $0.features.contains(.oneImage) })
        XCTAssertTrue(rows.contains { $0.features.contains(.fiveImages) })
        XCTAssertTrue(rows.contains { !$0.markupRanges.isEmpty })
    }

    func testRichFixtureUTF16RangesStayInsideSyntheticBody() {
        let markedRows = ChatPerformanceRichFixture.rows.filter { !$0.markupRanges.isEmpty }

        XCTAssertFalse(markedRows.isEmpty)
        markedRows.forEach { row in
            let utf16Length = (row.body as NSString).length
            row.markupRanges.forEach { range in
                XCTAssertGreaterThanOrEqual(range.location, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(range), utf16Length)
            }
        }
    }
}
private enum FixtureStoreError: Error {
    case expectedFailure
}

private final class CountingFixtureStore: ChatPerformanceFixturePersisting {
    let isEphemeral: Bool
    private(set) var persistedRowCount = 0
    private(set) var cleanupCallCount = 0
    private let failingOrdinal: Int?

    init(isEphemeral: Bool, failingOrdinal: Int? = nil) {
        self.isEphemeral = isEphemeral
        self.failingOrdinal = failingOrdinal
    }

    func prepare(totalRowCount: Int) throws {}
    func beginBatch(_ range: Range<Int>) throws {}

    func persist(_ row: ChatPerformanceThinFixtureRow) throws {
        if row.ordinal == failingOrdinal {
            throw FixtureStoreError.expectedFailure
        }
        persistedRowCount += 1
    }

    func endBatch() throws {}

    func cleanup() throws -> Int {
        cleanupCallCount += 1
        let deleted = persistedRowCount
        persistedRowCount = 0
        return deleted
    }
}

private final class RealmFixtureStore: ChatPerformanceFixturePersisting {
    let isEphemeral: Bool
    private let realm: Realm
    private let fixtureOwner = "chat-performance-owner"

    var persistedRowCount: Int {
        realm.objects(MessageStorageItem.self)
            .where { $0.owner == fixtureOwner }
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
        message.primary = "chat-performance-fixture-\(row.ordinal)"
        message.owner = fixtureOwner
        message.opponent = "chat-performance-peer"
        message.conversationType = .regular
        message.archivedId = "fixture-archive-\(row.ordinal)"
        message.messageId = "fixture-message-\(row.ordinal)"
        message.date = Date(timeIntervalSince1970: TimeInterval(row.timestampSeconds))
        message.sentDate = message.date
        message.body = "fixture-variant-\(row.bodyVariant)"
        realm.add(message, update: .modified)
    }

    func endBatch() throws {
        try realm.commitWrite()
    }

    func cleanup() throws -> Int {
        if realm.isInWriteTransaction {
            realm.cancelWrite()
        }
        let rows = realm.objects(MessageStorageItem.self)
            .where { $0.owner == fixtureOwner }
        let deleted = rows.count
        try realm.write {
            realm.delete(rows)
        }
        return deleted
    }
}
