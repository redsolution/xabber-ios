import XCTest
import RealmSwift
@testable import xabber

final class ChatLocalHistoryPageProviderWindowingTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"
    private let sharedDate = Date(timeIntervalSince1970: 1_700_100_000)

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatLocalHistoryPageProviderWindowingTests-\(name)-\(UUID().uuidString)"
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

    func testLatestReturnsNewestChronologicalDedupeWindow() throws {
        try insertMessages((0..<8).map {
            spec(primary: "p\($0)", archivedId: "\($0)", timestamp: TimeInterval($0))
        })

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let items = try provider(diagnostics: diagnostics).latest(limit: 3)

        XCTAssertEqual(items.map(\.primary), ["p5", "p6", "p7"])
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 12)
    }

    func testInitialLatestWindowUsesOneExactEightyCandidateOperation() throws {
        try insertMessages((0..<320).map {
            spec(
                primary: "p\($0)",
                archivedId: "\($0)",
                timestamp: TimeInterval($0)
            )
        })

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let items = try provider(diagnostics: diagnostics)
            .initialLatestWindow(limit: 80)

        XCTAssertEqual(items.count, 80)
        XCTAssertEqual(items.first?.primary, "p240")
        XCTAssertEqual(items.last?.primary, "p319")
        XCTAssertEqual(diagnostics.records.map(\.operation), ["latestWindow"])
        XCTAssertEqual(diagnostics.records.map(\.candidateCount), [80])
        XCTAssertEqual(diagnostics.queryCount, 1)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertEqual(diagnostics.maxCandidateCount, 80)
    }

    func testOlderBeforeBoundaryDedupeUsesBoundedCandidates() throws {
        try insertMessages([
            spec(primary: "p0", archivedId: "0", timestamp: 0),
            spec(primary: "p1", archivedId: "1", timestamp: 1),
            spec(primary: "dup-old", archivedId: "dup", messageId: "dup-message", timestamp: 2),
            spec(primary: "dup-new", archivedId: "dup", messageId: "dup-message", timestamp: 3),
            spec(primary: "p4", archivedId: "4", timestamp: 4),
            spec(primary: "p5", archivedId: "5", timestamp: 5),
            spec(primary: "p6", archivedId: "6", timestamp: 6)
        ])

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let items = try provider(diagnostics: diagnostics).older(
            before: boundary(primary: "p6", archivedId: "6", timestamp: 6),
            limit: 4
        )

        XCTAssertEqual(items.map(\.primary), ["p1", "dup-old", "p4", "p5"])
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 8)
    }

    func testNewerAfterBoundaryDedupeUsesBoundedCandidates() throws {
        try insertMessages([
            spec(primary: "p0", archivedId: "0", timestamp: 0),
            spec(primary: "p1", archivedId: "1", timestamp: 1),
            spec(primary: "dup-old", archivedId: "dup", messageId: "dup-message", timestamp: 2),
            spec(primary: "dup-new", archivedId: "dup", messageId: "dup-message", timestamp: 3),
            spec(primary: "p4", archivedId: "4", timestamp: 4),
            spec(primary: "p5", archivedId: "5", timestamp: 5)
        ])

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let items = try provider(diagnostics: diagnostics).newer(
            after: boundary(primary: "p0", archivedId: "0", timestamp: 0),
            limit: 4
        )

        XCTAssertEqual(items.map(\.primary), ["p1", "dup-old", "p4", "p5"])
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 8)
    }

    func testSameDateMessagesPreserveTimelinePositionOrdering() throws {
        try insertMessages([
            spec(primary: "p300", archivedId: "300", timestamp: sharedDate.timeIntervalSince1970),
            spec(primary: "p100", archivedId: "100", timestamp: sharedDate.timeIntervalSince1970),
            spec(primary: "p200", archivedId: "200", timestamp: sharedDate.timeIntervalSince1970),
            spec(primary: "p400", archivedId: "400", timestamp: sharedDate.timeIntervalSince1970)
        ])

        let provider = try provider(diagnostics: ChatLocalHistoryPageProviderDiagnostics())

        XCTAssertEqual(provider.latest(limit: 4).map(\.primary), ["p100", "p200", "p300", "p400"])
        XCTAssertEqual(
            provider.older(before: boundary(primary: "p300", archivedId: "300", date: sharedDate), limit: 2).map(\.primary),
            ["p100", "p200"]
        )
        XCTAssertEqual(
            provider.newer(after: boundary(primary: "p200", archivedId: "200", date: sharedDate), limit: 2).map(\.primary),
            ["p300", "p400"]
        )
    }

    func testAroundAnchorReturnsRequestedLocalContextWithoutFullScan() throws {
        try insertMessages((0..<10).map {
            spec(primary: "p\($0)", archivedId: "\($0)", timestamp: TimeInterval($0))
        })
        let anchor = try XCTUnwrap(try message(primary: "p5"))

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let items = try provider(diagnostics: diagnostics).around(anchor: anchor, before: 2, after: 3)

        XCTAssertEqual(items.map(\.primary), ["p3", "p4", "p5", "p6", "p7", "p8"])
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertEqual(diagnostics.records.map(\.operation), ["older", "newer"])
    }

    func testFirstIncomingWindowSkipsOutgoingRowsAndUsesOneExactBoundedOperation() throws {
        let start = sharedDate.timeIntervalSince1970
        try insertMessages((0..<120).map { index in
            let timestamp = start + TimeInterval(index)
            return spec(
                primary: "p\(index)",
                archivedId: "\(Int64(timestamp * 1_000_000))",
                timestamp: timestamp,
                outgoing: index == 40 || index == 41
            )
        })

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let window = try XCTUnwrap(
            try provider(diagnostics: diagnostics).firstIncomingWindow(
                afterArchiveBoundaryId: "\(Int64((start + 39) * 1_000_000))",
                before: 40,
                after: 39
            )
        )

        XCTAssertEqual(window.target.primary, "p42")
        XCTAssertEqual(window.items.count, 80)
        XCTAssertEqual(window.resultCount, 80)
        XCTAssertEqual(window.materializedCandidateCount, 80)
        XCTAssertEqual(window.items.first?.primary, "p2")
        XCTAssertEqual(window.items.last?.primary, "p81")
        XCTAssertTrue(window.items.contains { $0.primary == window.target.primary })
        XCTAssertEqual(diagnostics.records.map(\.operation), ["firstIncomingWindow"])
        XCTAssertEqual(diagnostics.records.map(\.candidateCount), [80])
        XCTAssertEqual(diagnostics.queryCount, 1)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 80)
    }

    func testMessageWindowPreservesLookupPriorityWithOneBoundedOperationPerResolution() throws {
        let start = sharedDate.timeIntervalSince1970
        let specs = (0..<120).map { index in
            let timestamp = start + TimeInterval(index)
            return spec(
                primary: "p\(index)",
                archivedId: "\(Int64(timestamp * 1_000_000))",
                timestamp: timestamp
            )
        }
        try insertMessages(specs)

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = try provider(diagnostics: diagnostics)
        let primaryWins = try XCTUnwrap(provider.messageWindow(
            primary: "p42",
            archivedId: specs[50].archivedId,
            messageId: specs[60].messageId,
            before: 40,
            after: 39
        ))
        let archiveFallback = try XCTUnwrap(provider.messageWindow(
            primary: "missing-primary",
            archivedId: specs[50].archivedId,
            messageId: specs[60].messageId,
            before: 40,
            after: 39
        ))
        let messageFallback = try XCTUnwrap(provider.messageWindow(
            primary: "missing-primary",
            archivedId: "missing-archive",
            messageId: specs[60].messageId,
            before: 40,
            after: 39
        ))

        XCTAssertEqual(primaryWins.target.primary, "p42")
        XCTAssertEqual(archiveFallback.target.primary, "p50")
        XCTAssertEqual(messageFallback.target.primary, "p60")
        XCTAssertEqual(primaryWins.items.count, 80)
        XCTAssertEqual(archiveFallback.items.count, 80)
        XCTAssertEqual(messageFallback.items.count, 80)
        XCTAssertEqual(primaryWins.materializedCandidateCount, 80)
        XCTAssertEqual(archiveFallback.materializedCandidateCount, 80)
        XCTAssertEqual(messageFallback.materializedCandidateCount, 80)
        XCTAssertEqual(
            diagnostics.records.map(\.operation),
            ["messageWindow", "messageWindow", "messageWindow"]
        )
        XCTAssertEqual(diagnostics.records.map(\.candidateCount), [80, 80, 80])
        XCTAssertEqual(diagnostics.queryCount, 3)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 80)
    }

    func testLargeConversationUsesBoundedCandidateWindows() throws {
        try insertMessages((0..<6_000).map {
            spec(primary: "p\($0)", archivedId: "\($0)", timestamp: TimeInterval($0))
        })
        let anchor = try XCTUnwrap(try message(primary: "p3200"))

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = try provider(diagnostics: diagnostics)

        XCTAssertEqual(provider.latest(limit: 40).map(\.primary).first, "p5960")
        XCTAssertEqual(
            provider.older(before: boundary(primary: "p4500", archivedId: "4500", timestamp: 4_500), limit: 40).map(\.primary).first,
            "p4460"
        )
        XCTAssertEqual(
            provider.newer(after: boundary(primary: "p2500", archivedId: "2500", timestamp: 2_500), limit: 40).map(\.primary).last,
            "p2540"
        )
        XCTAssertEqual(provider.around(anchor: anchor, before: 20, after: 20).count, 41)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 240)
    }

    private func provider(diagnostics: ChatLocalHistoryPageProviderDiagnostics) throws -> ChatLocalHistoryPageProvider {
        ChatLocalHistoryPageProvider(
            realm: try WRealm.safe(),
            owner: owner,
            jid: jid,
            conversationType: .regular,
            diagnostics: diagnostics
        )
    }

    private func message(primary: String) throws -> MessageStorageItem? {
        try WRealm.safe().object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
    }

    private func boundary(primary: String, archivedId: String, timestamp: TimeInterval) -> ChatTimelineBoundary {
        boundary(
            primary: primary,
            archivedId: archivedId,
            date: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func boundary(primary: String, archivedId: String, date: Date) -> ChatTimelineBoundary {
        ChatTimelineBoundary(
            primary: primary,
            archivedId: archivedId,
            messageId: "message-\(primary)",
            date: date
        )
    }

    private func spec(
        primary: String,
        archivedId: String,
        messageId: String? = nil,
        timestamp: TimeInterval,
        outgoing: Bool = false
    ) -> MessageSpec {
        MessageSpec(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId ?? "message-\(primary)",
            date: Date(timeIntervalSince1970: timestamp),
            outgoing: outgoing
        )
    }

    private func insertMessages(_ specs: [MessageSpec]) throws {
        let realm = try WRealm.safe()
        try realm.write {
            specs.forEach { spec in
                let message = MessageStorageItem()
                message.primary = spec.primary
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.archivedId = spec.archivedId
                message.messageId = spec.messageId
                message.date = spec.date
                message.sentDate = spec.date
                message.body = spec.primary
                message.outgoing = spec.outgoing
                message.refreshHistoryPositionComponents()
                realm.add(message, update: .modified)
            }
        }
    }

    private struct MessageSpec {
        let primary: String
        let archivedId: String
        let messageId: String
        let date: Date
        let outgoing: Bool
    }
}
