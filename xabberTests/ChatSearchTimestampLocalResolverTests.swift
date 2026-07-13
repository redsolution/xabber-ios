//
//  ChatSearchTimestampLocalResolverTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import RealmSwift
@testable import xabber

final class ChatSearchTimestampLocalResolverTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var testConfiguration: Realm.Configuration!
    private var realm: Realm!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatSearchTimestampLocalResolverTests-\(name)-\(UUID().uuidString)"
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

    func testStrictScopeExcludesDeletedSystemHiddenAndOtherChatRows() throws {
        let selected = Date(timeIntervalSince1970: 100)
        try addMessages([
            makeMessage(primary: "matching", archivedId: "10", date: selected),
            makeMessage(primary: "wrong-owner", archivedId: "11", owner: "other@example.com", date: selected),
            makeMessage(primary: "wrong-jid", archivedId: "12", jid: "alexey@example.com", date: selected),
            makeMessage(primary: "wrong-type", archivedId: "13", conversationType: .group, date: selected),
            makeMessage(primary: "deleted", archivedId: "14", date: selected, isDeleted: true),
            makeMessage(primary: "system", archivedId: "15", date: selected, messageType: .system),
            makeMessage(primary: "hidden", archivedId: "16", date: selected, isLocallyHiddenByReport: true)
        ])
        try addCoverage(
            scope: regularScope,
            ranges: [("1", "20")],
            olderEnd: true,
            newerEdge: true
        )

        let outcome = try resolve(makeRequest(selectedTimestamp: selected))

        XCTAssertEqual(outcome, .resolvedLocal(anchor(primary: "matching", archivedId: "10", date: selected)))
    }

    func testChoosesEarliestMessageAtOrAfterExactTimestamp() throws {
        let selected = Date(timeIntervalSince1970: 100)
        try addMessages([
            makeMessage(primary: "before", archivedId: "1", date: selected.addingTimeInterval(-1)),
            makeMessage(primary: "first-after", archivedId: "2", date: selected.addingTimeInterval(1)),
            makeMessage(primary: "later-after", archivedId: "3", date: selected.addingTimeInterval(2))
        ])
        try addCoverage(scope: regularScope, ranges: [("1", "3")])

        let outcome = try resolve(makeRequest(selectedTimestamp: selected))

        XCTAssertEqual(
            outcome,
            .resolvedLocal(
                anchor(
                    primary: "first-after",
                    archivedId: "2",
                    date: selected.addingTimeInterval(1)
                )
            )
        )
    }

    func testFallsBackToLatestMessageBeforeTimestampWhenNothingFollows() throws {
        let selected = Date(timeIntervalSince1970: 200)
        try addMessages([
            makeMessage(primary: "older", archivedId: "1", date: selected.addingTimeInterval(-2)),
            makeMessage(primary: "latest-before", archivedId: "2", date: selected.addingTimeInterval(-1))
        ])
        try addCoverage(
            scope: regularScope,
            ranges: [("1", "2")],
            newerEdge: true
        )

        let outcome = try resolve(makeRequest(selectedTimestamp: selected))

        XCTAssertEqual(
            outcome,
            .resolvedLocal(
                anchor(
                    primary: "latest-before",
                    archivedId: "2",
                    date: selected.addingTimeInterval(-1)
                )
            )
        )
    }

    func testExactTimestampIsIncludedAndTieUsesNumericArchiveThenPrimaryOrdering() throws {
        let selected = Date(timeIntervalSince1970: 300)
        try addMessages([
            makeMessage(primary: "primary-z-20", archivedId: "20", date: selected),
            makeMessage(primary: "primary-z", archivedId: "10", date: selected),
            makeMessage(primary: "primary-a", archivedId: "10", date: selected)
        ])
        try addCoverage(scope: regularScope, ranges: [("1", "30")])

        let outcome = try resolve(makeRequest(selectedTimestamp: selected))

        XCTAssertEqual(outcome, .resolvedLocal(anchor(primary: "primary-a", archivedId: "10", date: selected)))
    }

    func testDisplayedCandidateAndCoverageCanResolveWithoutOpeningRealm() throws {
        let selected = Date(timeIntervalSince1970: 400)
        let before = anchor(primary: "before", archivedId: "40", date: selected.addingTimeInterval(-1))
        let after = anchor(primary: "after", archivedId: "41", date: selected.addingTimeInterval(1))
        let realmOpenCount = TimestampLockedBox(0)
        let resolver = ChatSearchTimestampResolver(
            realmConfiguration: testConfiguration,
            realmFactory: { configuration in
                realmOpenCount.withValue { $0 += 1 }
                return try Realm(configuration: configuration)
            }
        )
        let request = makeRequest(
            selectedTimestamp: selected,
            displayedCandidates: [after, before],
            displayedCoverage: coverage(ranges: [("40", "41")])
        )

        let outcome = try resolve(request, resolver: resolver)

        XCTAssertEqual(outcome, .resolvedLocal(after))
        XCTAssertEqual(realmOpenCount.value, 0)
    }

    func testCoverageProofDistinguishesContinuousWindowFromGapAndFullEmptyArchive() {
        let selected = Date(timeIntervalSince1970: 500)
        let before = anchor(primary: "before", archivedId: "50", date: selected.addingTimeInterval(-1))
        let after = anchor(primary: "after", archivedId: "60", date: selected.addingTimeInterval(1))

        XCTAssertTrue(
            ChatSearchTimestampLocalCoveragePolicy.isSufficient(
                selectedTimestamp: selected,
                nearestBefore: before,
                nearestAfter: after,
                proof: coverage(ranges: [("1", "100")])
            )
        )
        XCTAssertFalse(
            ChatSearchTimestampLocalCoveragePolicy.isSufficient(
                selectedTimestamp: selected,
                nearestBefore: before,
                nearestAfter: after,
                proof: coverage(ranges: [("1", "55"), ("56", "100")])
            )
        )
        XCTAssertTrue(
            ChatSearchTimestampLocalCoveragePolicy.isSufficient(
                selectedTimestamp: selected,
                nearestBefore: nil,
                nearestAfter: nil,
                proof: coverage(ranges: [], olderEnd: true, newerEdge: true)
            )
        )
    }

    func testEncryptedConversationAlwaysFinishesLocallyAndNeverNeedsRemote() throws {
        let selected = Date(timeIntervalSince1970: 600)
        let encryptedScope = scope(conversationType: .omemo)
        try addMessages([
            makeMessage(
                primary: "encrypted",
                archivedId: "60",
                conversationType: .omemo,
                date: selected.addingTimeInterval(1)
            )
        ])

        let resolved = try resolve(
            makeRequest(scope: encryptedScope, selectedTimestamp: selected)
        )

        XCTAssertEqual(
            resolved,
            .resolvedLocal(
                anchor(
                    primary: "encrypted",
                    archivedId: "60",
                    date: selected.addingTimeInterval(1),
                    scope: encryptedScope
                )
            )
        )

        try realm.write {
            realm.deleteAll()
        }
        let empty = try resolve(
            makeRequest(
                id: UUID(),
                scope: encryptedScope,
                selectedTimestamp: selected
            )
        )
        XCTAssertEqual(empty, .noMessage)
    }

    func testIncompleteRegularAndGroupCoverageNeedsRemoteWithTwoBoundedCandidates() throws {
        let selected = Date(timeIntervalSince1970: 700)
        for conversationType in [
            ClientSynchronizationManager.ConversationType.regular,
            .group
        ] {
            try realm.write { realm.deleteAll() }
            let requestScope = scope(conversationType: conversationType)
            try addMessages([
                makeMessage(
                    primary: "before",
                    archivedId: "70",
                    conversationType: conversationType,
                    date: selected.addingTimeInterval(-1)
                ),
                makeMessage(
                    primary: "after",
                    archivedId: "80",
                    conversationType: conversationType,
                    date: selected.addingTimeInterval(1)
                ),
                makeMessage(
                    primary: "later",
                    archivedId: "90",
                    conversationType: conversationType,
                    date: selected.addingTimeInterval(2)
                )
            ])

            let outcome = try resolve(
                makeRequest(
                    id: UUID(),
                    scope: requestScope,
                    selectedTimestamp: selected
                )
            )
            guard case .needsRemote(let remote) = outcome else {
                return XCTFail("Expected remote fallback for \(conversationType), got \(outcome)")
            }
            XCTAssertEqual(remote.scope, requestScope)
            XCTAssertEqual(remote.selectedTimestamp, selected)
            XCTAssertEqual(remote.localCandidates.count, 2)
            XCTAssertEqual(remote.localCandidates.map(\.anchor.primary), ["after", "before"])
        }
    }

    func testCompleteRegularArchiveWithoutEligibleMessagesReturnsNoMessage() throws {
        try addMessages([
            makeMessage(primary: "system", archivedId: "1", date: Date(), messageType: .system)
        ])
        try addCoverage(
            scope: regularScope,
            ranges: [],
            olderEnd: true,
            newerEdge: true
        )

        let outcome = try resolve(makeRequest(selectedTimestamp: Date(timeIntervalSince1970: 800)))

        XCTAssertEqual(outcome, .noMessage)
    }

    func testDSTTimestampUsesExactAbsoluteInstantWithoutLocaleDayNormalization() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let selected = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 59, second: 59))
        )
        let afterDSTJump = selected.addingTimeInterval(1)
        try addMessages([
            makeMessage(primary: "before", archivedId: "100", date: selected.addingTimeInterval(-1)),
            makeMessage(primary: "after", archivedId: "101", date: afterDSTJump)
        ])
        try addCoverage(scope: regularScope, ranges: [("100", "101")])

        let outcome = try resolve(makeRequest(selectedTimestamp: selected))

        XCTAssertEqual(outcome, .resolvedLocal(anchor(primary: "after", archivedId: "101", date: afterDSTJump)))
        XCTAssertEqual(calendar.component(.hour, from: afterDSTJump), 3)
    }

    func testRealmReadRunsOffMainAndReturnedAnchorIsDetachedFromMutation() throws {
        let selected = Date(timeIntervalSince1970: 900)
        try addMessages([
            makeMessage(primary: "detached", archivedId: "900", date: selected)
        ])
        try addCoverage(scope: regularScope, ranges: [("900", "900")])
        let openedOffMain = TimestampLockedBox(false)
        let resolver = ChatSearchTimestampResolver(
            realmConfiguration: testConfiguration,
            realmFactory: { configuration in
                openedOffMain.withValue { $0 = !Thread.isMainThread }
                return try Realm(configuration: configuration)
            }
        )

        let outcome = try resolve(makeRequest(selectedTimestamp: selected), resolver: resolver)
        let stored = try XCTUnwrap(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "detached")
        )
        try realm.write {
            stored.messageId = "mutated"
            stored.date = selected.addingTimeInterval(100)
        }

        XCTAssertTrue(openedOffMain.value)
        XCTAssertEqual(outcome, .resolvedLocal(anchor(primary: "detached", archivedId: "900", date: selected)))
    }

    func testCancelBeforeRealmCompletionEmitsOnlyCancelledAndSuppressesLateResult() throws {
        let selected = Date(timeIntervalSince1970: 1_000)
        try addMessages([
            makeMessage(primary: "late", archivedId: "1000", date: selected)
        ])
        let realmStarted = expectation(description: "background Realm factory started")
        let cancelled = expectation(description: "cancelled outcome")
        let lateResult = expectation(description: "late resolution suppressed")
        lateResult.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        let resolver = ChatSearchTimestampResolver(
            realmConfiguration: testConfiguration,
            realmFactory: { configuration in
                realmStarted.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                return try Realm(configuration: configuration)
            }
        )
        let request = makeRequest(selectedTimestamp: selected)

        resolver.resolve(request) { outcome in
            if outcome == .cancelled {
                cancelled.fulfill()
            } else {
                lateResult.fulfill()
            }
        }
        wait(for: [realmStarted], timeout: 1)
        XCTAssertTrue(resolver.cancel(requestID: request.id))
        gate.signal()

        wait(for: [cancelled, lateResult], timeout: 1)
    }

    func testInjectedConfigurationNeverUsesRealAccountRealm() throws {
        let inspectedConfiguration = TimestampLockedBox<Realm.Configuration?>(nil)
        let resolver = ChatSearchTimestampResolver(
            realmConfiguration: testConfiguration,
            realmFactory: { configuration in
                inspectedConfiguration.withValue { $0 = configuration }
                return try Realm(configuration: configuration)
            }
        )

        _ = try resolve(
            makeRequest(
                scope: scope(conversationType: .omemo),
                selectedTimestamp: Date(timeIntervalSince1970: 1_100)
            ),
            resolver: resolver
        )

        XCTAssertEqual(inspectedConfiguration.value?.inMemoryIdentifier, testConfiguration.inMemoryIdentifier)
        XCTAssertNil(inspectedConfiguration.value?.fileURL)
    }

    private var regularScope: ChatSearchResult.Scope {
        scope(conversationType: .regular)
    }

    private func scope(
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatSearchResult.Scope {
        ChatSearchResult.Scope(
            owner: "owner@example.com",
            jid: "andrew@example.com",
            conversationTypeRawValue: conversationType.rawValue
        )
    }

    private func makeRequest(
        id: UUID = UUID(),
        scope: ChatSearchResult.Scope? = nil,
        selectedTimestamp: Date,
        displayedCandidates: [ChatSearchTimestampAnchor] = [],
        displayedCoverage: ChatSearchTimestampCoverageProof? = nil
    ) -> ChatSearchTimestampResolutionRequest {
        ChatSearchTimestampResolutionRequest(
            id: id,
            scope: scope ?? regularScope,
            selectedTimestamp: selectedTimestamp,
            displayedCandidates: displayedCandidates,
            displayedCoverage: displayedCoverage
        )
    }

    private func resolve(
        _ request: ChatSearchTimestampResolutionRequest,
        resolver: ChatSearchTimestampResolver? = nil
    ) throws -> ChatSearchTimestampResolutionOutcome {
        let resolver = resolver ?? ChatSearchTimestampResolver(
            realmConfiguration: testConfiguration
        )
        let completed = expectation(description: "timestamp resolution \(request.id)")
        var captured: ChatSearchTimestampResolutionOutcome?
        resolver.resolve(request) { outcome in
            captured = outcome
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        return try XCTUnwrap(captured)
    }

    private func addMessages(_ messages: [MessageStorageItem]) throws {
        try realm.write {
            realm.add(messages)
        }
    }

    private func addCoverage(
        scope: ChatSearchResult.Scope,
        ranges: [(String, String)],
        olderEnd: Bool = false,
        newerEdge: Bool = false
    ) throws {
        let conversationType = try XCTUnwrap(
            ClientSynchronizationManager.ConversationType(
                rawValue: scope.conversationTypeRawValue
            )
        )
        try realm.write {
            let state = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: scope.owner,
                jid: scope.jid,
                conversationType: conversationType,
                in: realm
            )
            state.loadedRanges = ranges.map {
                RegularChatArchiveIDRange(oldestArchiveId: $0.0, newestArchiveId: $0.1)
            }
            state.olderArchiveEndReached = olderEnd
            state.newerLiveEdgeReached = newerEdge
            state.recomputeBoundsAndGaps()
        }
    }

    private func coverage(
        ranges: [(String, String)],
        olderEnd: Bool = false,
        newerEdge: Bool = false
    ) -> ChatSearchTimestampCoverageProof {
        ChatSearchTimestampCoverageProof(
            loadedRanges: ranges.map {
                .init(oldestArchiveId: $0.0, newestArchiveId: $0.1)
            },
            olderArchiveEndReached: olderEnd,
            newerLiveEdgeReached: newerEdge
        )
    }

    private func anchor(
        primary: String,
        archivedId: String,
        date: Date,
        scope: ChatSearchResult.Scope? = nil
    ) -> ChatSearchTimestampAnchor {
        ChatSearchTimestampAnchor(
            id: archivedId.isEmpty ? .primary(primary) : .archived(archivedId),
            scope: scope ?? regularScope,
            anchor: ChatSearchResult.Anchor(
                primary: primary,
                archivedId: archivedId,
                messageId: "message-\(primary)",
                authorId: nil,
                date: date
            )
        )
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        owner: String = "owner@example.com",
        jid: String = "andrew@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        date: Date,
        isDeleted: Bool = false,
        messageType: MessageStorageItem.MessageDisplayType = .text,
        isLocallyHiddenByReport: Bool = false
    ) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = primary
        item.archivedId = archivedId
        item.messageId = "message-\(primary)"
        item.owner = owner
        item.opponent = jid
        item.conversationType = conversationType
        item.date = date
        item.body = primary
        item.isDeleted = isDeleted
        item.messageType = messageType.rawValue
        item.isLocallyHiddenByReport = isLocallyHiddenByReport
        return item
    }
}

private final class TimestampLockedBox<Value> {
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
