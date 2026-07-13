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
//

import XCTest
import XMPPFramework
@testable import xabber

private final class ChatSearchCapturingXMPPStream: XMPPStream {
    private(set) var sentElements: [DDXMLElement] = []
    var onSendElement: ((DDXMLElement) -> Void)?

    override func send(_ element: DDXMLElement) {
        sentElements.append(element)
        onSendElement?(element)
    }
}

final class ChatSearchMAMPagingTests: XCTestCase {
    private let generation: UInt64 = 7
    private let queryId = "MAM search:7:test"

    func testCompleteFirstPageFinishesOnlyAfterPagePersistenceIsCommitted() throws {
        var session = makeSession()
        XCTAssertTrue(session.accept(result: result("1", timestamp: 1), generation: generation, queryId: queryId))

        XCTAssertTrue(
            session.receiveFinal(
                generation: generation,
                queryId: queryId,
                complete: true,
                first: "1",
                last: "1",
                serverResultCount: 1
            )
        )
        XCTAssertNil(session.terminal)

        let action = session.commitPersistedPage(
            generation: generation,
            queryId: queryId,
            persistedMessageCount: 1
        )

        XCTAssertEqual(action, .terminal(.completed(resultCount: 1, pageCount: 1)))
    }

    func testIncompletePageRequestsNextOlderPageFromRSMFirstCursor() {
        var session = makeSession()
        _ = session.accept(result: result("newer", timestamp: 2), generation: generation, queryId: queryId)
        XCTAssertTrue(
            session.receiveFinal(
                generation: generation,
                queryId: queryId,
                complete: false,
                first: "oldest-on-page",
                last: "newest-on-page",
                serverResultCount: 251
            )
        )

        XCTAssertEqual(
            session.commitPersistedPage(
                generation: generation,
                queryId: queryId,
                persistedMessageCount: 1
            ),
            .requestNext(cursor: "oldest-on-page")
        )
    }

    func testMoreThanOnePageAccumulatesAllResultsNewestFirst() {
        var session = makeSession()
        for index in 1...250 {
            XCTAssertTrue(
                session.accept(
                    result: result("page-1-\(index)", timestamp: TimeInterval(index)),
                    generation: generation,
                    queryId: queryId
                )
            )
        }
        _ = receiveAndCommitPage(
            session: &session,
            complete: false,
            first: "page-1-oldest",
            last: "page-1-newest",
            serverResultCount: 251,
            persistedMessageCount: 250
        )
        XCTAssertTrue(
            session.accept(
                result: result("page-2-oldest", timestamp: 0),
                generation: generation,
                queryId: queryId
            )
        )

        let terminal = receiveAndCommitPage(
            session: &session,
            complete: true,
            first: "page-2-oldest",
            last: "page-2-oldest",
            serverResultCount: 251,
            persistedMessageCount: 1
        )

        XCTAssertEqual(terminal, .terminal(.completed(resultCount: 251, pageCount: 2)))
        XCTAssertEqual(session.orderedResults.count, 251)
        XCTAssertEqual(session.orderedResults.first?.id, .archived("page-1-250"))
        XCTAssertEqual(session.orderedResults.last?.id, .archived("page-2-oldest"))
    }

    func testDuplicateBoundaryResultAcrossPagesIsCollapsed() {
        var session = makeSession()
        XCTAssertTrue(session.accept(result: result("boundary", timestamp: 2), generation: generation, queryId: queryId))
        _ = receiveAndCommitPage(
            session: &session,
            complete: false,
            first: "boundary",
            last: "newest",
            serverResultCount: 2,
            persistedMessageCount: 1
        )

        XCTAssertFalse(session.accept(result: result("boundary", timestamp: 2), generation: generation, queryId: queryId))
        XCTAssertTrue(session.accept(result: result("older", timestamp: 1), generation: generation, queryId: queryId))

        XCTAssertEqual(session.resultCount, 2)
        XCTAssertEqual(session.orderedResults.map(\.id), [.archived("boundary"), .archived("older")])
    }

    func testStaleFinalAndPersistedPageFromPreviousGenerationAreIgnored() {
        var session = makeSession()

        XCTAssertFalse(
            session.receiveFinal(
                generation: generation - 1,
                queryId: queryId,
                complete: true,
                first: "old",
                last: "old",
                serverResultCount: 1
            )
        )
        XCTAssertNil(
            session.commitPersistedPage(
                generation: generation - 1,
                queryId: queryId,
                persistedMessageCount: 1
            )
        )
        XCTAssertNil(session.terminal)
        XCTAssertEqual(session.pageCount, 0)
    }

    func testCancelStopsPendingFinalAndFurtherPagination() {
        var session = makeSession()
        XCTAssertTrue(
            session.receiveFinal(
                generation: generation,
                queryId: queryId,
                complete: false,
                first: "cursor",
                last: "last",
                serverResultCount: 10
            )
        )

        XCTAssertEqual(session.cancel(), .cancelled(resultCount: 0, pageCount: 0))
        XCTAssertNil(
            session.commitPersistedPage(
                generation: generation,
                queryId: queryId,
                persistedMessageCount: 0
            )
        )
        XCTAssertFalse(session.isActive)
    }

    func testNetworkAndIQErrorsProduceTypedFailureTerminal() {
        var session = makeSession()

        XCTAssertEqual(
            session.fail(.server(description: "service-unavailable")),
            .failed(
                reason: .server(description: "service-unavailable"),
                resultCount: 0,
                pageCount: 0
            )
        )
        XCTAssertFalse(session.isActive)
    }

    func testMissingRSMCursorTruncatesInsteadOfLooping() {
        var session = makeSession()
        XCTAssertTrue(
            session.receiveFinal(
                generation: generation,
                queryId: queryId,
                complete: false,
                first: nil,
                last: nil,
                serverResultCount: 25
            )
        )

        XCTAssertEqual(
            session.commitPersistedPage(
                generation: generation,
                queryId: queryId,
                persistedMessageCount: 0
            ),
            .terminal(
                .truncated(reason: .missingCursor, resultCount: 0, pageCount: 1)
            )
        )
    }

    func testRepeatedNoProgressCursorTruncatesInsteadOfCompleting() {
        var session = makeSession()
        XCTAssertEqual(
            receiveAndCommitPage(
                session: &session,
                complete: false,
                first: "same-cursor",
                last: "last-1",
                serverResultCount: 500,
                persistedMessageCount: 0
            ),
            .requestNext(cursor: "same-cursor")
        )

        XCTAssertEqual(
            receiveAndCommitPage(
                session: &session,
                complete: false,
                first: "same-cursor",
                last: "last-2",
                serverResultCount: 500,
                persistedMessageCount: 0
            ),
            .terminal(
                .truncated(reason: .repeatedCursor, resultCount: 0, pageCount: 2)
            )
        )
    }

    func testExplicitPageCapProducesTypedTruncationWithAccumulatedResults() {
        var session = makeSession(maximumPageCount: 2)
        XCTAssertTrue(session.accept(result: result("new", timestamp: 2), generation: generation, queryId: queryId))
        _ = receiveAndCommitPage(
            session: &session,
            complete: false,
            first: "cursor-1",
            last: "last-1",
            serverResultCount: 3,
            persistedMessageCount: 1
        )
        XCTAssertTrue(session.accept(result: result("old", timestamp: 1), generation: generation, queryId: queryId))

        XCTAssertEqual(
            receiveAndCommitPage(
                session: &session,
                complete: false,
                first: "cursor-2",
                last: "last-2",
                serverResultCount: 3,
                persistedMessageCount: 1
            ),
            .terminal(
                .truncated(reason: .pageLimitReached(limit: 2), resultCount: 2, pageCount: 2)
            )
        )
    }

    func testExplicitResultCapNeverMasqueradesAsCompleted() {
        var session = makeSession(maximumResultCount: 2)
        XCTAssertTrue(session.accept(result: result("1", timestamp: 3), generation: generation, queryId: queryId))
        XCTAssertTrue(session.accept(result: result("2", timestamp: 2), generation: generation, queryId: queryId))
        XCTAssertFalse(session.accept(result: result("3", timestamp: 1), generation: generation, queryId: queryId))

        XCTAssertTrue(
            session.receiveFinal(
                generation: generation,
                queryId: queryId,
                complete: true,
                first: "3",
                last: "1",
                serverResultCount: 3
            )
        )
        XCTAssertEqual(
            session.commitPersistedPage(
                generation: generation,
                queryId: queryId,
                persistedMessageCount: 3
            ),
            .terminal(
                .truncated(reason: .resultLimitReached(limit: 2), resultCount: 2, pageCount: 1)
            )
        )
    }

    func testZeroResultsCompleteAsEmpty() {
        var session = makeSession()

        XCTAssertEqual(
            receiveAndCommitPage(
                session: &session,
                complete: false,
                first: nil,
                last: nil,
                serverResultCount: 0,
                persistedMessageCount: 0
            ),
            .terminal(.completed(resultCount: 0, pageCount: 1))
        )
    }

    func testSearchPurposeNeverProducesRegularArchiveCoverageOrHistoryCursor() {
        XCTAssertFalse(MessageArchiveManager.RequestPurpose.search.isArchiveHistoryProducing)
        XCTAssertFalse(
            MessageArchiveManager.HistoryCursorPolicy.shouldPersistCursor(for: .search)
        )
        XCTAssertFalse(
            MessageArchiveManager.ArchiveEndPolicy.canCommitCoverage(for: .search)
        )
    }

    func testIncrementalResultIsAvailableBeforeFinalOrContextFetch() {
        var session = makeSession()

        XCTAssertTrue(
            session.accept(
                result: result("first-visible", timestamp: 1),
                generation: generation,
                queryId: queryId
            )
        )

        XCTAssertEqual(session.resultCount, 1)
        XCTAssertNil(session.terminal)
        XCTAssertEqual(session.pageCount, 0)
    }

    func testStaleResultIsRejectedBeforeItCanEnterIncrementalList() {
        var session = makeSession()

        XCTAssertFalse(
            session.accept(
                result: result("stale", timestamp: 1),
                generation: generation - 1,
                queryId: queryId
            )
        )
        XCTAssertTrue(session.orderedResults.isEmpty)
    }

    func testManagerSearchRequestKeepsWithTextShapeAndRegistersTypedSession() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatSearchCapturingXMPPStream()

        let returnedQueryId = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            max: 250,
            loadFull: true,
            queryId: queryId,
            generation: generation
        )

        XCTAssertEqual(returnedQueryId, queryId)
        XCTAssertTrue(manager.hasActiveSearchArchiveSession(queryId: queryId))
        let iq = try XCTUnwrap(stream.sentElements.first)
        let query = try XCTUnwrap(iq.element(forName: "query"))
        let fields = try XCTUnwrap(query.element(forName: "x"))
            .elements(forName: "field")
        let withText = fields.first {
            $0.attributeStringValue(forName: "var") == "withtext"
        }
        XCTAssertEqual(withText?.element(forName: "value")?.stringValue, "test")
        let set = try XCTUnwrap(query.element(forName: "set"))
        XCTAssertNotNil(set.element(forName: "before"))
        XCTAssertEqual(set.element(forName: "before")?.stringValue ?? "", "")

        manager.cancelSearch(queryId: queryId)
    }

    func testManagerIncompleteFinalRequestsNextPageFromFirstWithoutPrematureCompletion() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        manager.searchContinuationDelay = 0.01
        let stream = ChatSearchCapturingXMPPStream()
        let nextRequest = expectation(description: "next search page")
        let prematureEnd = expectation(description: "no premature end page")
        prematureEnd.isInverted = true
        let cancelled = expectation(description: "cancelled terminal")
        stream.onSendElement = { _ in
            if stream.sentElements.count == 2 {
                nextRequest.fulfill()
            }
        }

        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            queryId: queryId,
            generation: generation,
            requestCallbacks: .init(
                onEndPage: { _, _, _, _, _ in prematureEnd.fulfill() },
                onSearchTerminal: { _, terminal in
                    if case .cancelled = terminal {
                        cancelled.fulfill()
                    }
                }
            )
        )

        XCTAssertTrue(manager.read(stream, withIQ: try finalIQ(
            complete: false,
            first: "oldest-on-page",
            last: "newest-on-page",
            count: 251
        )))

        wait(for: [nextRequest], timeout: 1.0)
        let secondQuery = try XCTUnwrap(stream.sentElements.last?.element(forName: "query"))
        XCTAssertEqual(
            secondQuery.element(forName: "set")?.element(forName: "before")?.stringValue,
            "oldest-on-page"
        )
        XCTAssertTrue(manager.hasActiveSearchArchiveSession(queryId: queryId))
        manager.cancelSearch(queryId: queryId)
        wait(for: [cancelled, prematureEnd], timeout: 0.2)
    }

    func testManagerCompletesOnceAfterIncrementalResultAndFinalPageCommit() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatSearchCapturingXMPPStream()
        let incremental = expectation(description: "incremental result")
        let completed = expectation(description: "typed completed terminal")
        let ended = expectation(description: "legacy end page adapter")
        var receivedState: MessageArchivePageEndState?

        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            queryId: queryId,
            generation: generation,
            requestCallbacks: .init(
                onMessage: { _, _ in incremental.fulfill() },
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    ended.fulfill()
                },
                onSearchTerminal: { _, terminal in
                    XCTAssertEqual(terminal, .completed(resultCount: 1, pageCount: 1))
                    completed.fulfill()
                }
            )
        )

        XCTAssertTrue(manager.readMessage(try resultMessage(archivedId: "archive-1")))
        wait(for: [incremental], timeout: 1.0)
        XCTAssertTrue(manager.read(stream, withIQ: try finalIQ(
            complete: true,
            first: "archive-1",
            last: "archive-1",
            count: 1
        )))

        wait(for: [completed, ended], timeout: 1.0)
        XCTAssertEqual(receivedState?.persistedMessageCount, 1)
        XCTAssertFalse(manager.hasActiveSearchArchiveSession(queryId: queryId))
    }

    func testManagerErrorIQPublishesTypedFailureAndNeverSuccessfulEndPage() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatSearchCapturingXMPPStream()
        let failed = expectation(description: "typed failure callback")
        let terminal = expectation(description: "failed terminal")
        let unexpectedEnd = expectation(description: "no successful end")
        unexpectedEnd.isInverted = true

        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            queryId: queryId,
            generation: generation,
            requestCallbacks: .init(
                onEndPage: { _, _, _, _, _ in unexpectedEnd.fulfill() },
                onFailure: { event in
                    XCTAssertEqual(event.queryId, self.queryId)
                    XCTAssertEqual(event.reason, .serverError)
                    failed.fulfill()
                },
                onSearchTerminal: { _, value in
                    if case .failed(reason: .server, resultCount: 0, pageCount: 0) = value {
                        terminal.fulfill()
                    }
                }
            )
        )

        let error = try element("""
        <iq type='error' id='\(queryId)'>
          <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>
        </iq>
        """)
        XCTAssertTrue(manager.read(stream, withIQ: XMPPIQ(from: error)))

        wait(for: [failed, terminal, unexpectedEnd], timeout: 0.2)
        XCTAssertFalse(manager.hasActiveSearchArchiveSession(queryId: queryId))
        XCTAssertFalse(manager.queryIds.contains(queryId))
    }

    func testManagerMalformedFinalProducesTypedFailureWithoutLooping() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatSearchCapturingXMPPStream()
        let failed = expectation(description: "malformed failure")
        let terminal = expectation(description: "malformed terminal")

        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            queryId: queryId,
            generation: generation,
            requestCallbacks: .init(
                onFailure: { event in
                    XCTAssertEqual(event.reason, .malformedResponse)
                    failed.fulfill()
                },
                onSearchTerminal: { _, value in
                    if case .failed(reason: .malformedResponse, resultCount: 0, pageCount: 0) = value {
                        terminal.fulfill()
                    }
                }
            )
        )

        let malformed = try element("""
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='false' queryid='\(queryId)'/>
        </iq>
        """)
        XCTAssertTrue(manager.read(stream, withIQ: XMPPIQ(from: malformed)))

        wait(for: [failed, terminal], timeout: 1.0)
        XCTAssertEqual(stream.sentElements.count, 1)
        XCTAssertFalse(manager.hasActiveSearchArchiveSession(queryId: queryId))
        XCTAssertFalse(manager.hasPendingSearchContinuation(queryId: queryId))
    }

    func testManagerDuplicateResultMessageIsDeliveredIncrementallyOnlyOnce() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        let stream = ChatSearchCapturingXMPPStream()
        let incremental = expectation(description: "one incremental result")
        incremental.expectedFulfillmentCount = 1
        incremental.assertForOverFulfill = true

        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            queryId: queryId,
            generation: generation,
            requestCallbacks: .init(
                onMessage: { _, _ in incremental.fulfill() }
            )
        )
        let message = try resultMessage(archivedId: "duplicate")

        XCTAssertTrue(manager.readMessage(message))
        XCTAssertTrue(manager.readMessage(message))
        wait(for: [incremental], timeout: 1.0)
        manager.cancelSearch(queryId: queryId)
    }

    func testManagerCancelInvalidatesScheduledContinuationAndCleansState() throws {
        let manager = MessageArchiveManager(withOwner: "owner@example.com")
        manager.searchContinuationDelay = 0.2
        let stream = ChatSearchCapturingXMPPStream()
        let cancelled = expectation(description: "cancelled terminal")

        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "test",
            queryId: queryId,
            generation: generation,
            requestCallbacks: .init(
                onSearchTerminal: { _, terminal in
                    if case .cancelled = terminal {
                        cancelled.fulfill()
                    }
                }
            )
        )
        XCTAssertTrue(manager.read(stream, withIQ: try finalIQ(
            complete: false,
            first: "cursor",
            last: "last",
            count: 2
        )))
        XCTAssertTrue(manager.hasPendingSearchContinuation(queryId: queryId))

        manager.cancelSearch(queryId: queryId)

        wait(for: [cancelled], timeout: 1.0)
        let noSecondRequest = expectation(description: "continuation stays cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            noSecondRequest.fulfill()
        }
        wait(for: [noSecondRequest], timeout: 1.0)
        XCTAssertEqual(stream.sentElements.count, 1)
        XCTAssertFalse(manager.hasPendingSearchContinuation(queryId: queryId))
        XCTAssertFalse(manager.hasActiveSearchArchiveSession(queryId: queryId))
        XCTAssertFalse(manager.queryIds.contains(queryId))
    }

    private func makeSession(
        maximumPageCount: Int? = 1_000,
        maximumResultCount: Int? = nil
    ) -> ChatSearchArchiveSession {
        ChatSearchArchiveSession(
            generation: generation,
            queryId: queryId,
            configuration: .init(
                maximumPageCount: maximumPageCount,
                maximumResultCount: maximumResultCount
            )
        )
    }

    private func result(_ archivedId: String, timestamp: TimeInterval) -> ChatSearchArchiveSession.Result {
        ChatSearchArchiveSession.Result(
            id: .archived(archivedId),
            date: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func element(_ xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return try XCTUnwrap(document.rootElement())
    }

    private func finalIQ(
        complete: Bool,
        first: String?,
        last: String?,
        count: Int
    ) throws -> XMPPIQ {
        let firstElement = first.map { "<first>\($0)</first>" } ?? ""
        let lastElement = last.map { "<last>\($0)</last>" } ?? ""
        return XMPPIQ(from: try element("""
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(count)</count>
              \(firstElement)
              \(lastElement)
            </set>
          </fin>
        </iq>
        """))
    }

    private func resultMessage(archivedId: String) throws -> XMPPMessage {
        XMPPMessage(from: try element("""
        <message to='owner@example.com' from='owner@example.com'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' to='owner@example.com' from='romeo@example.com' type='chat' id='message-1'>
                <archived xmlns='urn:xmpp:mam:tmp' by='owner@example.com' id='\(archivedId)'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.com' id='\(archivedId)'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='owner@example.com' stamp='2026-07-13T10:00:00Z'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='message-1'/>
                <body>test</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-07-13T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """))
    }

    @discardableResult
    private func receiveAndCommitPage(
        session: inout ChatSearchArchiveSession,
        complete: Bool,
        first: String?,
        last: String?,
        serverResultCount: Int,
        persistedMessageCount: Int
    ) -> ChatSearchArchiveSession.Action? {
        XCTAssertTrue(
            session.receiveFinal(
                generation: generation,
                queryId: queryId,
                complete: complete,
                first: first,
                last: last,
                serverResultCount: serverResultCount
            )
        )
        return session.commitPersistedPage(
            generation: generation,
            queryId: queryId,
            persistedMessageCount: persistedMessageCount
        )
    }
}
