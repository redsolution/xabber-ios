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
//

import XCTest
@testable import xabber

final class ChatSearchSessionStateTests: XCTestCase {
    func testWhitespaceOnlyQueryStaysIdleAndDoesNotScheduleRequest() {
        var session = ChatSearchSession()

        let effects = session.accept(query: " \n\t ", scope: regularScope)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertNil(session.normalizedQuery)
        XCTAssertEqual(session.providerPhase, .idle)
        XCTAssertFalse(session.isProviderSearching)
    }

    func testEveryAcceptedQueryChangeCreatesMonotonicGeneration() throws {
        var session = ChatSearchSession()
        var generations: [UInt64] = []

        for query in ["t", "te", "tes", "test"] {
            let effects = session.accept(query: query, scope: regularScope)
            generations.append(try XCTUnwrap(scheduledRequest(in: effects)).generation)
        }

        XCTAssertEqual(generations, [1, 2, 3, 4])
        XCTAssertEqual(session.generation, 4)
        XCTAssertEqual(session.normalizedQuery, "test")
    }

    func testDebounceStartsOnlyLatestGenerationAfter300Milliseconds() throws {
        var session = ChatSearchSession()
        let first = try XCTUnwrap(scheduledRequest(in: session.accept(query: "tes", scope: regularScope)))
        let latestEffects = session.accept(query: "test", scope: regularScope)
        let latest = try XCTUnwrap(scheduledRequest(in: latestEffects))

        XCTAssertEqual(scheduledDelay(in: latestEffects), 300)
        XCTAssertTrue(session.debounceElapsed(generation: first.generation).isEmpty)
        XCTAssertEqual(
            session.debounceElapsed(generation: latest.generation),
            [.startProviderRequest(latest)]
        )
        XCTAssertTrue(session.isProviderSearching)
    }

    func testReturnFlushStartsRequestImmediatelyWithoutDebounceDuplicate() throws {
        var session = ChatSearchSession()
        let request = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )

        XCTAssertEqual(
            session.flush(),
            [.cancelDebounce(generation: request.generation), .startProviderRequest(request)]
        )
        XCTAssertTrue(session.debounceElapsed(generation: request.generation).isEmpty)
    }

    func testChangingQueryCancelsPreviousDebounceAndProviderRegistration() throws {
        var debouncingSession = ChatSearchSession()
        let debouncing = try XCTUnwrap(
            scheduledRequest(in: debouncingSession.accept(query: "tes", scope: regularScope))
        )

        let debounceReplacement = debouncingSession.accept(query: "test", scope: regularScope)

        XCTAssertTrue(debounceReplacement.contains(.cancelDebounce(generation: debouncing.generation)))

        var searchingSession = ChatSearchSession()
        let searching = try XCTUnwrap(
            scheduledRequest(in: searchingSession.accept(query: "tes", scope: regularScope))
        )
        _ = searchingSession.flush()

        let providerReplacement = searchingSession.accept(query: "test", scope: regularScope)

        XCTAssertTrue(providerReplacement.contains(.cancelProviderRequest(generation: searching.generation)))
    }

    func testStaleResultFinalAndErrorEventsAreIgnored() throws {
        var session = ChatSearchSession()
        let old = try XCTUnwrap(scheduledRequest(in: session.accept(query: "tes", scope: regularScope)))
        _ = session.flush()
        _ = session.accept(query: "test", scope: regularScope)
        _ = session.flush()

        XCTAssertFalse(session.receive(.result(generation: old.generation, id: .archived("old"))))
        XCTAssertFalse(session.receive(.finished(generation: old.generation)))
        XCTAssertFalse(session.receive(.failed(generation: old.generation)))
        XCTAssertEqual(session.resultCount, 0)
        XCTAssertEqual(session.providerPhase, .searching)
    }

    func testCancelInvalidatesDebounceProviderDateResolverAndPendingNavigation() throws {
        var debouncingSession = ChatSearchSession()
        let debouncing = try XCTUnwrap(
            scheduledRequest(in: debouncingSession.accept(query: "test", scope: regularScope))
        )
        XCTAssertEqual(
            debouncingSession.cancel(),
            [.cancelDebounce(generation: debouncing.generation)]
        )

        var activeSession = ChatSearchSession()
        let active = try XCTUnwrap(
            scheduledRequest(in: activeSession.accept(query: "test", scope: regularScope))
        )
        _ = activeSession.flush()
        activeSession.beginDateResolution()
        activeSession.beginPendingNavigation()

        let effects = activeSession.cancel()

        XCTAssertTrue(effects.contains(.cancelProviderRequest(generation: active.generation)))
        XCTAssertTrue(effects.contains(.cancelDateResolver))
        XCTAssertTrue(effects.contains(.cancelPendingNavigation))
        XCTAssertNil(activeSession.normalizedQuery)
        XCTAssertEqual(activeSession.providerPhase, .idle)
        XCTAssertGreaterThan(activeSession.generation, active.generation)
    }

    func testIdenticalNormalizedQueryDoesNotCreateDuplicateRequest() {
        var session = ChatSearchSession()

        let first = session.accept(query: " test ", scope: regularScope)
        let duplicate = session.accept(query: "test", scope: regularScope)

        XCTAssertNotNil(scheduledRequest(in: first))
        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertEqual(session.generation, 1)
    }

    func testProviderSelectionUsesOnlyConversationEncryptionContract() throws {
        var session = ChatSearchSession()

        let regular = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )
        let group = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: groupScope))
        )
        let encrypted = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: encryptedScope))
        )

        XCTAssertEqual(regular.provider, .remoteArchive)
        XCTAssertEqual(group.provider, .remoteArchive)
        XCTAssertEqual(encrypted.provider, .localEncrypted)
    }

    func testFirstResultIsPendingUntilPositioningSucceeds() throws {
        var session = ChatSearchSession()
        let request = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )
        _ = session.flush()

        XCTAssertTrue(session.receive(.result(generation: request.generation, id: .archived("1"))))
        XCTAssertEqual(session.pendingTarget, .archived("1"))
        XCTAssertNil(session.committedSelection)

        XCTAssertTrue(
            session.positioningSucceeded(
                generation: request.generation,
                id: .archived("1")
            )
        )
        XCTAssertNil(session.pendingTarget)
        XCTAssertEqual(session.committedSelection, .archived("1"))
    }

    func testContextLoadingIsIndependentFromProviderSpinnerAndResults() throws {
        var session = ChatSearchSession()
        let request = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )
        _ = session.flush()
        _ = session.receive(.result(generation: request.generation, id: .archived("1")))
        _ = session.receive(.finished(generation: request.generation))

        session.setContextLoading(true)

        XCTAssertFalse(session.isProviderSearching)
        XCTAssertTrue(session.isContextLoading)
        XCTAssertEqual(session.resultCount, 1)
        XCTAssertEqual(session.pendingTarget, .archived("1"))
    }

    private var regularScope: ChatSearchSession.Scope {
        ChatSearchSession.Scope(
            owner: "owner@example.com",
            jid: "andrew@example.com",
            conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue,
            isEncrypted: false
        )
    }

    private var groupScope: ChatSearchSession.Scope {
        ChatSearchSession.Scope(
            owner: "owner@example.com",
            jid: "group@example.com",
            conversationTypeRawValue: ClientSynchronizationManager.ConversationType.group.rawValue,
            isEncrypted: false
        )
    }

    private var encryptedScope: ChatSearchSession.Scope {
        ChatSearchSession.Scope(
            owner: "owner@example.com",
            jid: "andrew@example.com",
            conversationTypeRawValue: ClientSynchronizationManager.ConversationType.omemo.rawValue,
            isEncrypted: true
        )
    }

    private func scheduledRequest(
        in effects: [ChatSearchSession.Effect]
    ) -> ChatSearchSession.Request? {
        effects.compactMap { effect in
            guard case .scheduleDebounce(let request, _) = effect else {
                return nil
            }
            return request
        }.first
    }

    private func scheduledDelay(in effects: [ChatSearchSession.Effect]) -> Int? {
        effects.compactMap { effect in
            guard case .scheduleDebounce(_, let milliseconds) = effect else {
                return nil
            }
            return milliseconds
        }.first
    }
}
