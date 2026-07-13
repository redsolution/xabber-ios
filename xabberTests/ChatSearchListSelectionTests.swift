//
//  ChatSearchListSelectionTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchListSelectionTests: XCTestCase {
    func testCurrentGenerationStableIdentityClosesListAndPreservesSearchState() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 4)
        prepareCommittedResults(controller, results: results, selectedIndex: 0)
        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)
        let query = controller.searchPresentationState.query
        let generation = controller.searchPresentationState.generation

        controller.searchResultNavigationState = .positioning(index: 0)
        list.onSelectResult?(results[2].id)

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .chat)
        XCTAssertEqual(controller.searchPresentationState.query, query)
        XCTAssertEqual(controller.searchPresentationState.generation, generation)
        XCTAssertEqual(controller.searchResultPresentations, results)
        XCTAssertEqual(controller.searchPresentationState.committedResultIndex, 0)
        XCTAssertEqual(controller.selectedSearchResultId, stableToken(results[0].id))
        guard case .pending(let index, let direction) = controller.searchResultNavigationState else {
            return XCTFail("Row selection must enter the existing pending navigation state")
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(direction, .up)
        XCTAssertEqual(list.retainedModeSwitchScrollAnchor?.id, results[2].id)
    }

    func testStaleGenerationTapIsIgnoredWithoutClosingListOrChangingNavigation() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 3)
        prepareCommittedResults(controller, results: results, selectedIndex: 1)
        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)
        let staleGeneration = UInt64(controller.searchPresentationState.generation)

        controller.reduceSearchPresentationState(.queryChanged("replacement"))
        controller.reduceSearchPresentationState(
            .resultsReceived(
                count: results.count,
                generation: controller.searchPresentationState.generation
            )
        )
        controller.reduceSearchPresentationState(
            .resultCommitted(index: 1, generation: controller.searchPresentationState.generation)
        )
        controller.reduceSearchPresentationState(.openList)
        controller.handleChatSearchListResultSelection(
            results[2].id,
            generation: staleGeneration
        )

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .list)
        XCTAssertEqual(controller.searchResultNavigationState, .idle)
        XCTAssertNil(list.retainedModeSwitchScrollAnchor)
    }

    func testRapidTapsCoalesceToLastKnownResultIntent() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 5)
        prepareCommittedResults(controller, results: results, selectedIndex: 0)
        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)
        controller.searchResultNavigationState = .positioning(index: 0)

        list.onSelectResult?(results[1].id)
        list.onSelectResult?(results[4].id)

        guard case .pending(let index, let direction) = controller.searchResultNavigationState else {
            return XCTFail("Rapid taps must retain one latest pending intent")
        }
        XCTAssertEqual(index, 4)
        XCTAssertEqual(direction, .up)
        XCTAssertEqual(list.retainedModeSwitchScrollAnchor?.id, results[4].id)
        XCTAssertEqual(controller.searchPresentationState.committedResultIndex, 0)
    }

    func testTapDuringPagingUsesAlreadyKnownDetachedResult() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 3)
        prepareCommittedResults(controller, results: results, selectedIndex: 0)
        controller.searchOlderPageNavigationGate = ChatSearchOlderPageNavigationGate(generation: 0)
        _ = controller.searchOlderPageNavigationGate.offer(
            cursor: "older",
            generation: 0,
            loadedResultCount: results.count
        )
        _ = controller.searchOlderPageNavigationGate.requestNavigation(generation: 0)
        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)
        XCTAssertTrue(list.isPagingIndicatorVisible)
        controller.searchResultNavigationState = .positioning(index: 0)

        list.onSelectResult?(results[2].id)

        guard case .pending(let index, _) = controller.searchResultNavigationState else {
            return XCTFail("Paging must not invalidate already rendered row identities")
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(controller.searchResultPresentations, results)
    }

    func testArchivedResultBuildsExactSafeSearchAnchorRequest() throws {
        let controller = makeLoadedController()
        let result = makeResult(index: 0, archivedID: "archive-42")
        prepareCommittedResults(controller, results: [result], selectedIndex: 0)

        let request = try XCTUnwrap(controller.makeSearchResultOpenMessageRequest(at: 0))

        XCTAssertEqual(request.source, ChatOpenMessageRequestSource.search)
        XCTAssertFalse(request.markReadOnVisible)
        XCTAssertTrue(request.highlight)
        XCTAssertEqual(request.anchor.archivedId, "archive-42")
        XCTAssertNil(request.anchor.messagePrimary)
        XCTAssertEqual(request.anchor.messageId, result.anchor.messageId)
        XCTAssertEqual(request.anchor.authorId, result.anchor.authorId)
        XCTAssertEqual(request.anchor.sourceDate, result.anchor.date)
        XCTAssertEqual(request.chatJid, result.scope.jid)
        XCTAssertEqual(request.owner, result.scope.owner)
        XCTAssertEqual(
            request.conversationType,
            ClientSynchronizationManager.ConversationType.regular
        )
    }

    func testMissingArchivedIDUsesPrimaryMessageAndDateFallback() throws {
        let controller = makeLoadedController()
        let result = makeResult(index: 0, archivedID: "")
        prepareCommittedResults(controller, results: [result], selectedIndex: 0)

        let request = try XCTUnwrap(controller.makeSearchResultOpenMessageRequest(at: 0))

        XCTAssertNil(request.anchor.archivedId)
        XCTAssertEqual(request.anchor.messagePrimary, result.anchor.primary)
        XCTAssertEqual(request.anchor.messageId, result.anchor.messageId)
        XCTAssertEqual(request.anchor.sourceDate, result.anchor.date)
        XCTAssertEqual(request.source, ChatOpenMessageRequestSource.search)
        XCTAssertFalse(request.markReadOnVisible)
    }

    func testSelectionKeepsCommittedCounterUntilPositioningSuccessAndFailureIsRecoverable() {
        var presentation = committedListPresentation(resultCount: 3, selectedIndex: 0)
        let generation = presentation.generation

        presentation.reduce(.closeList)
        presentation.reduce(.navigationStarted(index: 2, generation: generation))
        XCTAssertEqual(presentation.committedResultIndex, 0)
        XCTAssertEqual(presentation.positioningPhase, .positioningResult(index: 2))

        presentation.reduce(.navigationFinished(generation: generation))
        XCTAssertEqual(presentation.committedResultIndex, 0)
        XCTAssertEqual(presentation.positioningPhase, .idle)
        presentation.reduce(.openList)
        XCTAssertEqual(presentation.surfaceMode, .list)
        presentation.reduce(.closeList)
        presentation.reduce(.navigationStarted(index: 2, generation: generation))
        presentation.reduce(.resultCommitted(index: 2, generation: generation))
        XCTAssertEqual(presentation.committedResultIndex, 2)
    }

    func testUnknownIdentityAndScopeMismatchDoNotProduceNavigationRequest() {
        let controller = makeLoadedController()
        let results = makeResults(count: 2)
        prepareCommittedResults(controller, results: results, selectedIndex: 0)

        XCTAssertNil(controller.makeSearchResultOpenMessageRequest(at: 99))
        let mismatchedScope = makeResult(
            index: 0,
            archivedID: "archive-0",
            owner: "other-owner@example.com"
        )
        controller.searchResultPresentations[0] = mismatchedScope
        controller.searchMessagesQueue[0] = makeLegacyMessage(mismatchedScope)
        XCTAssertNil(controller.makeSearchResultOpenMessageRequest(at: 0))
        controller.handleChatSearchListResultSelection(
            ChatSearchResult.ID.archived("unknown"),
            generation: UInt64(controller.searchPresentationState.generation)
        )
        XCTAssertEqual(controller.searchResultNavigationState, .idle)
        XCTAssertEqual(controller.searchPresentationState.committedResultIndex, 0)
    }

    private func makeLoadedController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "owner@example.com"
        controller.jid = "andrew@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Andrew Nenakhov")
        controller.showSkeletonObserver.accept(false)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func prepareCommittedResults(
        _ controller: ChatViewController,
        results: [ChatSearchResult],
        selectedIndex: Int
    ) {
        controller.reduceSearchPresentationState(.activate)
        controller.reduceSearchPresentationState(.queryChanged("test"))
        controller.searchResultPresentations = results
        controller.searchMessagesQueue = results.map(makeLegacyMessage)
        let generation = controller.searchPresentationState.generation
        controller.reduceSearchPresentationState(
            .resultsReceived(count: results.count, generation: generation)
        )
        controller.selectedSearchResultId = stableToken(results[selectedIndex].id)
        controller.reduceSearchPresentationState(
            .resultCommitted(index: selectedIndex, generation: generation)
        )
    }

    private func committedListPresentation(
        resultCount: Int,
        selectedIndex: Int
    ) -> ChatSearchPresentationState {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        let generation = state.generation
        state.reduce(.resultsReceived(count: resultCount, generation: generation))
        state.reduce(.resultCommitted(index: selectedIndex, generation: generation))
        state.reduce(.openList)
        return state
    }

    private func makeLegacyMessage(_ result: ChatSearchResult) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = result.anchor.primary
        item.archivedId = result.anchor.archivedId
        item.messageId = result.anchor.messageId
        item.owner = result.scope.owner
        item.opponent = result.scope.jid
        item.conversationType_ = result.scope.conversationTypeRawValue
        item.body = result.body
        item.date = result.anchor.date
        return item
    }

    private func makeResults(count: Int) -> [ChatSearchResult] {
        (0..<count).map { makeResult(index: $0, archivedID: "archive-\($0)") }
    }

    private func makeResult(
        index: Int,
        archivedID: String,
        owner: String = "owner@example.com"
    ) -> ChatSearchResult {
        let primary = "primary-\(index)"
        return ChatSearchResult(
            id: archivedID.isEmpty ? .primary(primary) : .archived(archivedID),
            scope: ChatSearchResult.Scope(
                owner: owner,
                jid: "andrew@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            ),
            anchor: ChatSearchResult.Anchor(
                primary: primary,
                archivedId: archivedID,
                messageId: "message-\(index)",
                authorId: index.isMultiple(of: 2) ? "author-\(index)" : nil,
                date: Date(timeIntervalSince1970: 1_800_000_000 - TimeInterval(index * 60))
            ),
            outgoing: false,
            senderTitle: "Andrew Nenakhov",
            body: "test message \(index)",
            snippet: "test message \(index)",
            deliveryState: .delivered,
            avatar: ChatSearchResult.Avatar(
                identity: "andrew@example.com",
                fallbackTitle: "Andrew Nenakhov",
                url: nil,
                source: .contact(jid: "andrew@example.com", owner: owner)
            )
        )
    }

    private func stableToken(_ id: ChatSearchResult.ID) -> String {
        switch id {
        case .archived(let value), .primary(let value):
            return value
        }
    }
}
