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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//

import XCTest
import XMPPFramework
@testable import xabber

private final class ChatTimestampCapturingXMPPStream: XMPPStream {
    private(set) var sentElements: [DDXMLElement] = []

    override func send(_ element: DDXMLElement) {
        sentElements.append(element)
    }
}

private final class ChatTimestampRequestHarness {
    struct Attempt {
        let plan: ChatSearchTimestampMAMRequestPlan
        let callbacks: MessageArchiveManager.RequestCallbacks
    }

    private(set) var attempts: [Attempt] = []
    private(set) var cancelledQueryIds: [String] = []
    var acceptsRequests = true

    func dependencies() -> ChatSearchTimestampMAMResolver.Dependencies {
        .init(
            start: { [weak self] plan, callbacks in
                guard let self else { return false }
                attempts.append(Attempt(plan: plan, callbacks: callbacks))
                return acceptsRequests
            },
            cancel: { [weak self] queryId in
                self?.cancelledQueryIds.append(queryId)
            }
        )
    }
}

final class ChatSearchTimestampMAMResolverTests: XCTestCase {
    private let requestID = UUID(uuidString: "B4798D91-857A-4FC8-96E3-C85542846343")!
    private let generation: UInt64 = 19
    private let selectedTimestamp = Date(timeIntervalSince1970: 1_773_825_600.125)

    func testAtOrAfterRequestUsesExactStartForwardRSMAndNoTextFilter() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatTimestampCapturingXMPPStream()
        let plan = ChatSearchTimestampMAMRequestPlan.make(
            fallback: fallback(),
            requestID: requestID,
            generation: generation,
            direction: .atOrAfter
        )

        XCTAssertTrue(manager.requestTimestampLookup(stream, plan: plan))

        let iq = try XCTUnwrap(stream.sentElements.last)
        let query = try XCTUnwrap(iq.element(forName: "query"))
        let fields = try dataFormFields(in: query)
        let rsm = try XCTUnwrap(query.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm"))
        XCTAssertNil(iq.attributeStringValue(forName: "to"))
        XCTAssertEqual(query.attributeStringValue(forName: "queryid"), plan.queryId)
        XCTAssertEqual(fields["with"], ["romeo@example.com"])
        XCTAssertEqual(fields["start"], [selectedTimestamp.XMPPFormattedDate])
        XCTAssertNil(fields["end"])
        XCTAssertNil(fields["withtext"])
        XCTAssertEqual(rsm.element(forName: "max")?.stringValue, "1")
        XCTAssertNil(rsm.element(forName: "before"))
        XCTAssertNil(rsm.element(forName: "after"))
        XCTAssertNil(query.element(forName: "flip-page"))
    }

    func testLatestBeforeRequestUsesExactEndReverseRSMAndGroupScope() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatTimestampCapturingXMPPStream()
        let plan = ChatSearchTimestampMAMRequestPlan.make(
            fallback: fallback(conversationType: .group),
            requestID: requestID,
            generation: generation,
            direction: .latestBefore
        )

        XCTAssertTrue(manager.requestTimestampLookup(stream, plan: plan))

        let iq = try XCTUnwrap(stream.sentElements.last)
        let query = try XCTUnwrap(iq.element(forName: "query"))
        let fields = try dataFormFields(in: query)
        let rsm = try XCTUnwrap(query.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm"))
        XCTAssertEqual(iq.attributeStringValue(forName: "to"), "romeo@example.com")
        XCTAssertNil(fields["with"])
        XCTAssertNil(fields["start"])
        XCTAssertEqual(fields["end"], [selectedTimestamp.XMPPFormattedDate])
        XCTAssertNil(fields["withtext"])
        XCTAssertEqual(rsm.element(forName: "max")?.stringValue, "1")
        XCTAssertNotNil(rsm.element(forName: "before"))
        XCTAssertEqual(rsm.element(forName: "before")?.stringValue ?? "", "")
        XCTAssertNil(rsm.element(forName: "after"))
        XCTAssertNotNil(query.element(forName: "flip-page"))
    }

    func testTimestampPurposeNeverProducesHistoryCoverageOrCursor() {
        XCTAssertFalse(MessageArchiveManager.RequestPurpose.timestampLookup.isArchiveHistoryProducing)
        XCTAssertFalse(MessageArchiveManager.ArchiveEndPolicy.canCommitCoverage(for: .timestampLookup))
        XCTAssertFalse(MessageArchiveManager.HistoryCursorPolicy.shouldPersistCursor(for: .timestampLookup))
        XCTAssertTrue(MessageArchiveManager.RequestPurpose.timestampLookup.routesMamServerErrorAsRequestFailure)
    }

    func testAfterCandidateWaitsForFinalAndPersistenceProofBeforeCompleting() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "detached result after final")
        var outcomes: [ChatSearchTimestampMAMResolutionOutcome] = []

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcomes.append($0)
            completed.fulfill()
        }
        XCTAssertEqual(harness.attempts.map(\.plan.direction), [.atOrAfter])

        let item = message(archivedId: "after-1", date: selectedTimestamp.addingTimeInterval(2))
        harness.attempts[0].callbacks.onMessage?(item, harness.attempts[0].plan.queryId)
        XCTAssertTrue(outcomes.isEmpty)
        item.archivedId = "mutated-after-callback"
        item.date = selectedTimestamp.addingTimeInterval(200)

        harness.attempts[0].callbacks.onEndPage?(
            harness.attempts[0].plan.queryId,
            pageEnd(persistedMessageCount: 1),
            "after-1",
            "after-1",
            1
        )

        wait(for: [completed], timeout: 1)
        guard case let .resolved(anchor) = outcomes.first else {
            return XCTFail("Expected resolved detached anchor")
        }
        XCTAssertEqual(anchor.id, .archived("after-1"))
        XCTAssertEqual(anchor.anchor.archivedId, "after-1")
        XCTAssertEqual(anchor.anchor.date, selectedTimestamp.addingTimeInterval(2))
    }

    func testMessageWithoutPersistenceProofIsNotReturnedAndFallsBackBefore() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let unexpected = expectation(description: "no premature result")
        unexpected.isInverted = true

        resolver.resolve(fallback(), requestID: requestID, generation: generation) { _ in
            unexpected.fulfill()
        }
        let after = harness.attempts[0]
        after.callbacks.onMessage?(
            message(archivedId: "unproven", date: selectedTimestamp),
            after.plan.queryId
        )
        after.callbacks.onEndPage?(
            after.plan.queryId,
            pageEnd(persistedMessageCount: 0),
            "unproven",
            "unproven",
            1
        )

        XCTAssertEqual(harness.attempts.map(\.plan.direction), [.atOrAfter, .latestBefore])
        wait(for: [unexpected], timeout: 0.05)
    }

    func testEmptyAfterAttemptStartsSingleLatestBeforeAttemptAndResolvesIt() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "before result")
        var outcome: ChatSearchTimestampMAMResolutionOutcome?

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcome = $0
            completed.fulfill()
        }
        finishEmpty(harness.attempts[0])
        XCTAssertEqual(harness.attempts.map(\.plan.direction), [.atOrAfter, .latestBefore])

        let before = harness.attempts[1]
        before.callbacks.onMessage?(
            message(archivedId: "before-1", date: selectedTimestamp.addingTimeInterval(-1)),
            before.plan.queryId
        )
        before.callbacks.onEndPage?(
            before.plan.queryId,
            pageEnd(persistedMessageCount: 1),
            "before-1",
            "before-1",
            1
        )

        wait(for: [completed], timeout: 1)
        guard case let .resolved(anchor) = outcome else {
            return XCTFail("Expected latest-before result")
        }
        XCTAssertEqual(anchor.id, .archived("before-1"))
    }

    func testEmptyBothDirectionsCompletesNoMessageAfterExactlyTwoRequests() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "no message")
        var outcomes: [ChatSearchTimestampMAMResolutionOutcome] = []

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcomes.append($0)
            completed.fulfill()
        }
        finishEmpty(harness.attempts[0])
        finishEmpty(harness.attempts[1])

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcomes, [.noMessage])
        XCTAssertEqual(harness.attempts.count, 2)
    }

    func testExactTimestampIsIncludedByAfterAndStrictlyExcludedFromBefore() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "exact after")
        var outcome: ChatSearchTimestampMAMResolutionOutcome?

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcome = $0
            completed.fulfill()
        }
        let after = harness.attempts[0]
        after.callbacks.onMessage?(message(archivedId: "exact", date: selectedTimestamp), after.plan.queryId)
        after.callbacks.onEndPage?(after.plan.queryId, pageEnd(persistedMessageCount: 1), "exact", "exact", 1)

        wait(for: [completed], timeout: 1)
        guard case let .resolved(anchor) = outcome else { return XCTFail("Expected exact result") }
        XCTAssertEqual(anchor.id, .archived("exact"))
        XCTAssertEqual(harness.attempts.count, 1)
    }

    func testWrongScopeAndWrongDirectionResultsAreIgnored() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())

        resolver.resolve(fallback(), requestID: requestID, generation: generation) { _ in }
        let after = harness.attempts[0]
        after.callbacks.onMessage?(
            message(owner: "other@example.com", archivedId: "wrong-owner", date: selectedTimestamp),
            after.plan.queryId
        )
        after.callbacks.onMessage?(
            message(archivedId: "wrong-direction", date: selectedTimestamp.addingTimeInterval(-1)),
            after.plan.queryId
        )
        after.callbacks.onEndPage?(after.plan.queryId, pageEnd(persistedMessageCount: 2), "", "", 2)

        XCTAssertEqual(harness.attempts.map(\.plan.direction), [.atOrAfter, .latestBefore])
    }

    func testCancelIsTerminalAndStaleCallbacksCannotCompleteAgain() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let cancelled = expectation(description: "cancelled")
        let duplicate = expectation(description: "no duplicate")
        duplicate.isInverted = true
        var count = 0

        resolver.resolve(fallback(), requestID: requestID, generation: generation) { outcome in
            count += 1
            if outcome == .cancelled {
                cancelled.fulfill()
            } else {
                duplicate.fulfill()
            }
        }
        let stale = harness.attempts[0]
        XCTAssertTrue(resolver.cancel(requestID: requestID))
        XCTAssertEqual(harness.cancelledQueryIds, [stale.plan.queryId])
        stale.callbacks.onEndPage?(stale.plan.queryId, pageEnd(persistedMessageCount: 0), "", "", 0)

        wait(for: [cancelled, duplicate], timeout: 0.05)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(resolver.cancel(requestID: requestID))
    }

    func testNewGenerationMakesPriorGenerationCallbacksStale() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "new generation only")
        var oldCount = 0
        var newOutcomes: [ChatSearchTimestampMAMResolutionOutcome] = []

        resolver.resolve(fallback(), requestID: requestID, generation: generation) { _ in
            oldCount += 1
        }
        let stale = harness.attempts[0]
        resolver.resolve(fallback(), requestID: requestID, generation: generation + 1) {
            newOutcomes.append($0)
            completed.fulfill()
        }
        XCTAssertEqual(harness.cancelledQueryIds, [stale.plan.queryId])

        finishEmpty(stale)
        let currentAfter = harness.attempts[1]
        finishEmpty(currentAfter)
        finishEmpty(harness.attempts[2])

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(newOutcomes, [.noMessage])
    }

    func testFailureIsTerminalAndDoesNotStartFallbackLoop() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "failed")
        var outcome: ChatSearchTimestampMAMResolutionOutcome?

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcome = $0
            completed.fulfill()
        }
        let attempt = harness.attempts[0]
        attempt.callbacks.onFailure?(
            MessageArchiveRequestFailureEvent(
                owner: "owner@example.com",
                queryId: attempt.plan.queryId,
                streamKind: .primary,
                reason: .serverError,
                errorDescription: "service-unavailable",
                pendingQueryCount: 1
            )
        )

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(
            outcome,
            .failed(.init(reason: .serverError, description: "service-unavailable"))
        )
        XCTAssertEqual(harness.attempts.count, 1)
    }

    func testRejectedRequestStartIsTypedTerminalFailure() {
        let harness = ChatTimestampRequestHarness()
        harness.acceptsRequests = false
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "start failure")
        var outcome: ChatSearchTimestampMAMResolutionOutcome?

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcome = $0
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(
            outcome,
            .failed(.init(reason: .requestStartFailed, description: nil))
        )
        XCTAssertEqual(harness.attempts.count, 1)
    }

    func testRepeatedFinalCompletesOnlyOnce() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "single terminal")
        let duplicate = expectation(description: "no duplicate terminal")
        duplicate.isInverted = true
        var count = 0

        resolver.resolve(fallback(), requestID: requestID, generation: generation) { _ in
            count += 1
            count == 1 ? completed.fulfill() : duplicate.fulfill()
        }
        let after = harness.attempts[0]
        after.callbacks.onMessage?(message(archivedId: "one", date: selectedTimestamp), after.plan.queryId)
        let end = pageEnd(persistedMessageCount: 1)
        after.callbacks.onEndPage?(after.plan.queryId, end, "one", "one", 1)
        after.callbacks.onEndPage?(after.plan.queryId, end, "one", "one", 1)

        wait(for: [completed, duplicate], timeout: 0.05)
        XCTAssertEqual(count, 1)
    }

    func testEncryptedFallbackNeverStartsMAMRequest() {
        let harness = ChatTimestampRequestHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies())
        let completed = expectation(description: "local-only no message")
        var outcome: ChatSearchTimestampMAMResolutionOutcome?

        resolver.resolve(
            fallback(conversationType: .omemo),
            requestID: requestID,
            generation: generation
        ) {
            outcome = $0
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcome, .noMessage)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testManagerFinalWithoutResultEndsAttemptAndCleansTimestampRegistration() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatTimestampCapturingXMPPStream()
        let ended = expectation(description: "empty final")
        let plan = ChatSearchTimestampMAMRequestPlan.make(
            fallback: fallback(),
            requestID: requestID,
            generation: generation,
            direction: .atOrAfter
        )
        XCTAssertTrue(manager.requestTimestampLookup(
            stream,
            plan: plan,
            requestCallbacks: .init(onEndPage: { queryId, state, _, _, count in
                XCTAssertEqual(queryId, plan.queryId)
                XCTAssertEqual(state.persistedMessageCount, 0)
                XCTAssertEqual(count, 0)
                ended.fulfill()
            })
        ))

        XCTAssertTrue(manager.read(stream, withIQ: try finalIQ(queryId: plan.queryId, count: 0)))

        wait(for: [ended], timeout: 1)
        XCTAssertFalse(manager.queryIds.contains(plan.queryId))
        XCTAssertFalse(manager.searchResultsQueries.contains(plan.queryId))
    }

    func testManagerPersistenceCallbackAndFinalProduceDetachedResolverAnchor() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatTimestampCapturingXMPPStream()
        let resolver = ChatSearchTimestampMAMResolver(
            dependencies: .init(
                start: { plan, callbacks in
                    manager.requestTimestampLookup(
                        stream,
                        plan: plan,
                        requestCallbacks: callbacks
                    )
                },
                cancel: { queryId in
                    _ = manager.cancelTimestampLookup(queryId: queryId)
                }
            )
        )
        let completed = expectation(description: "manager-backed detached result")
        var outcome: ChatSearchTimestampMAMResolutionOutcome?

        resolver.resolve(fallback(), requestID: requestID, generation: generation) {
            outcome = $0
            completed.fulfill()
        }
        let queryId = try XCTUnwrap(
            stream.sentElements.last?.element(forName: "query")?
                .attributeStringValue(forName: "queryid")
        )
        XCTAssertTrue(manager.readMessage(try resultMessage(
            queryId: queryId,
            archivedId: "persisted-anchor"
        )))
        XCTAssertNil(outcome)
        XCTAssertTrue(manager.read(stream, withIQ: try finalIQ(queryId: queryId, count: 1)))

        wait(for: [completed], timeout: 1)
        guard case let .resolved(anchor) = outcome else {
            return XCTFail("Expected detached anchor after manager final")
        }
        XCTAssertEqual(anchor.id, .archived("persisted-anchor"))
        XCTAssertEqual(anchor.anchor.archivedId, "persisted-anchor")
        XCTAssertEqual(anchor.anchor.messageId, "timestamp-message")
        XCTAssertEqual(anchor.anchor.date, Date(timeIntervalSince1970: 1_783_936_800))
    }

    func testManagerErrorRoutesTimestampFailureWithoutSuccessfulEnd() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatTimestampCapturingXMPPStream()
        let failed = expectation(description: "typed timestamp failure")
        let unexpectedEnd = expectation(description: "no successful final")
        unexpectedEnd.isInverted = true
        let plan = ChatSearchTimestampMAMRequestPlan.make(
            fallback: fallback(),
            requestID: requestID,
            generation: generation,
            direction: .atOrAfter
        )
        XCTAssertTrue(manager.requestTimestampLookup(
            stream,
            plan: plan,
            requestCallbacks: .init(
                onEndPage: { _, _, _, _, _ in unexpectedEnd.fulfill() },
                onFailure: { event in
                    XCTAssertEqual(event.queryId, plan.queryId)
                    XCTAssertEqual(event.reason, .serverError)
                    failed.fulfill()
                }
            )
        ))
        let error = try element("""
        <iq type='error' id='\(plan.queryId)'>
          <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: XMPPIQ(from: error)))

        wait(for: [failed, unexpectedEnd], timeout: 0.05)
        XCTAssertFalse(manager.queryIds.contains(plan.queryId))
        XCTAssertFalse(manager.searchResultsQueries.contains(plan.queryId))
    }

    func testManagerRejectsEncryptedTimestampLookupBeforeSendingStanza() {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatTimestampCapturingXMPPStream()
        let plan = ChatSearchTimestampMAMRequestPlan.make(
            fallback: fallback(conversationType: .omemo),
            requestID: requestID,
            generation: generation,
            direction: .atOrAfter
        )

        XCTAssertFalse(manager.requestTimestampLookup(stream, plan: plan))
        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertFalse(manager.queryIds.contains(plan.queryId))
    }

    private func fallback(
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatSearchTimestampRemoteFallback {
        ChatSearchTimestampRemoteFallback(
            scope: .init(
                owner: "owner@example.com",
                jid: "romeo@example.com",
                conversationTypeRawValue: conversationType.rawValue
            ),
            selectedTimestamp: selectedTimestamp,
            localCandidates: []
        )
    }

    private func message(
        owner: String = "owner@example.com",
        archivedId: String,
        date: Date
    ) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.owner = owner
        item.opponent = "romeo@example.com"
        item.conversationType_ = ClientSynchronizationManager.ConversationType.regular.rawValue
        item.archivedId = archivedId
        item.primary = "primary-\(archivedId)"
        item.messageId = "message-\(archivedId)"
        item.date = date
        return item
    }

    private func pageEnd(persistedMessageCount: Int) -> MessageArchivePageEndState {
        MessageArchivePageEndState(
            queryExhausted: true,
            archiveEnded: false,
            persistedMessageCount: persistedMessageCount,
            requestCursorId: nil
        )
    }

    private func finishEmpty(_ attempt: ChatTimestampRequestHarness.Attempt) {
        attempt.callbacks.onEndPage?(
            attempt.plan.queryId,
            pageEnd(persistedMessageCount: 0),
            "",
            "",
            0
        )
    }

    private func dataFormFields(in query: DDXMLElement) throws -> [String: [String]] {
        let form = try XCTUnwrap(query.element(forName: "x", xmlns: "jabber:x:data"))
        return Dictionary(uniqueKeysWithValues: form.elements(forName: "field").compactMap { field in
            guard let name = field.attributeStringValue(forName: "var") else { return nil }
            return (name, field.elements(forName: "value").compactMap(\.stringValue))
        })
    }

    private func finalIQ(queryId: String, count: Int) throws -> XMPPIQ {
        XMPPIQ(from: try element("""
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' queryid='\(queryId)' complete='true'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <first></first><last></last><count>\(count)</count>
            </set>
          </fin>
        </iq>
        """))
    }

    private func resultMessage(queryId: String, archivedId: String) throws -> XMPPMessage {
        XMPPMessage(from: try element("""
        <message to='owner@example.com' from='owner@example.com'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' to='owner@example.com' from='romeo@example.com' type='chat' id='timestamp-message'>
                <archived xmlns='urn:xmpp:mam:tmp' by='owner@example.com' id='\(archivedId)'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.com' id='\(archivedId)'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='owner@example.com' stamp='2026-07-13T10:00:00Z'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='timestamp-message'/>
                <body>calendar lookup payload</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-07-13T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """))
    }

    private func element(_ xml: String) throws -> DDXMLElement {
        try DDXMLElement(xmlString: xml)
    }
}
