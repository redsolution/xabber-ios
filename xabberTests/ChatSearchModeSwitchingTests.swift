//
//  ChatSearchModeSwitchingTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchModeSwitchingTests: XCTestCase {
    func testModeCallbackShowsInlineListAndReturnsToChatWithoutLosingSearchState() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 3)
        prepareCommittedResults(controller, results: results, selectedIndex: 1)
        let query = controller.searchPresentationState.query
        let generation = controller.searchPresentationState.generation
        let selectedID = controller.selectedSearchResultId

        controller.onSearchPanelChangeChatViewState()

        let list = try XCTUnwrap(controller.searchResultsListViewController)
        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .list)
        XCTAssertTrue(list.parent === controller)
        XCTAssertFalse(list.view.isHidden)
        XCTAssertTrue(list.view.isUserInteractionEnabled)
        XCTAssertTrue(controller.messagesCollectionView.isHidden)
        XCTAssertEqual(list.displayedResultIDs, results.map(\.id))
        XCTAssertEqual(list.lastProgrammaticScrollID, results[1].id)
        XCTAssertEqual(controller.searchPresentationState.query, query)
        XCTAssertEqual(controller.searchPresentationState.generation, generation)
        XCTAssertEqual(controller.selectedSearchResultId, selectedID)
        XCTAssertEqual(controller.xabberInputView.searchPanel.counterLabel.text, "3 messages")
        XCTAssertEqual(
            controller.xabberInputView.searchPanel.viewModeButton.title(for: .normal),
            "Show as Chat"
        )
        XCTAssertTrue(controller.searchNavigationButtonsView.isHidden)

        controller.onSearchPanelChangeChatViewState()

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .chat)
        XCTAssertTrue(list.view.isHidden)
        XCTAssertFalse(list.view.isUserInteractionEnabled)
        XCTAssertFalse(controller.messagesCollectionView.isHidden)
        XCTAssertEqual(controller.searchPresentationState.query, query)
        XCTAssertEqual(controller.searchPresentationState.generation, generation)
        XCTAssertEqual(controller.selectedSearchResultId, selectedID)
        XCTAssertEqual(controller.xabberInputView.searchPanel.counterLabel.text, "2 of 3")
        XCTAssertEqual(
            controller.xabberInputView.searchPanel.viewModeButton.title(for: .normal),
            "Show as List"
        )
        XCTAssertFalse(controller.searchNavigationButtonsView.isHidden)
    }

    func testRapidTogglesReuseOneChildAndRestoreStableListPosition() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 20)
        prepareCommittedResults(controller, results: results, selectedIndex: 5)

        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)

        controller.onSearchPanelChangeChatViewState()
        controller.onSearchPanelChangeChatViewState()
        controller.onSearchPanelChangeChatViewState()
        controller.onSearchPanelChangeChatViewState()

        XCTAssertIdentical(controller.searchResultsListViewController, list)
        XCTAssertEqual(controller.children.filter { $0 === list }.count, 1)
        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .list)
        XCTAssertEqual(list.lastProgrammaticScrollID, results[5].id)
    }

    func testListModeSwitchRestoresStableVisiblePosition() {
        let results = makeResults(count: 20)
        let list = ChatSearchResultsListViewController()
        list.loadViewIfNeeded()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        list.view.frame = window.bounds
        window.addSubview(list.view)
        window.isHidden = false

        list.render(
            ChatSearchResultsListRenderModel(
                generation: 1,
                results: results,
                selectedID: results[5].id,
                phase: .populated
            ),
            animated: false
        )
        list.view.layoutIfNeeded()
        list.tableView.layoutIfNeeded()
        XCTAssertTrue(list.scrollToResult(id: results[10].id, animated: false))
        list.tableView.layoutIfNeeded()
        let offsetBeforeToggle = list.tableView.contentOffset

        list.prepareForModeSwitchToChat()
        list.prepareForModeSwitchToList(selectedID: results[5].id)

        XCTAssertEqual(list.tableView.contentOffset.y, offsetBeforeToggle.y, accuracy: 0.5)

        list.prepareForRemoval()
        window.layoutIfNeeded()
        window.isHidden = true
        list.view.removeFromSuperview()
    }

    func testModeSwitchPreservesOpenOrClosedKeyboardIntent() throws {
        XCTAssertFalse(ChatSearchModeSwitchKeyboardPolicy.shouldDismissKeyboard(for: .modeControl))
        XCTAssertTrue(
            ChatSearchModeSwitchKeyboardPolicy.shouldDismissKeyboard(for: .listInteractiveDrag)
        )

        let focusRequested = makeLoadedController()
        prepareCommittedResults(
            focusRequested,
            results: makeResults(count: 2),
            selectedIndex: 0
        )
        XCTAssertFalse(focusRequested.searchNavigationView.requestInputFocusWhenAttached())
        XCTAssertTrue(focusRequested.searchNavigationView.hasPendingFocusRequest)

        focusRequested.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(focusRequested.searchResultsListViewController)
        XCTAssertEqual(list.tableView.keyboardDismissMode, .interactive)
        XCTAssertTrue(focusRequested.searchNavigationView.hasPendingFocusRequest)
        focusRequested.onSearchPanelChangeChatViewState()
        XCTAssertTrue(focusRequested.searchNavigationView.hasPendingFocusRequest)

        let keyboardClosed = makeLoadedController()
        prepareCommittedResults(
            keyboardClosed,
            results: makeResults(count: 2),
            selectedIndex: 0
        )
        XCTAssertFalse(keyboardClosed.searchNavigationView.hasPendingFocusRequest)
        keyboardClosed.onSearchPanelChangeChatViewState()
        keyboardClosed.onSearchPanelChangeChatViewState()
        XCTAssertFalse(keyboardClosed.searchNavigationView.hasPendingFocusRequest)
    }

    func testListCanOpenWhileNextPageIsLoading() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 2)
        prepareCommittedResults(controller, results: results, selectedIndex: 0)
        controller.searchOlderPageNavigationGate = ChatSearchOlderPageNavigationGate(generation: 0)
        _ = controller.searchOlderPageNavigationGate.offer(
            cursor: "older-page",
            generation: 0,
            loadedResultCount: results.count
        )
        _ = controller.searchOlderPageNavigationGate.requestNavigation(generation: 0)

        controller.onSearchPanelChangeChatViewState()

        let list = try XCTUnwrap(controller.searchResultsListViewController)
        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .list)
        XCTAssertTrue(list.isPagingIndicatorVisible)
        XCTAssertEqual(list.displayedResultIDs, results.map(\.id))
    }

    func testMissingCommittedResultRejectsListWithoutCreatingChild() {
        let controller = makeLoadedController()
        let results = makeResults(count: 2)
        prepareUncommittedResults(controller, results: results)

        controller.onSearchPanelChangeChatViewState()

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .chat)
        XCTAssertNil(controller.searchResultsListViewController)
        XCTAssertTrue(controller.xabberInputView.searchPanel.trailingSurfaceView.isHidden)
        XCTAssertTrue(controller.xabberInputView.searchPanel.viewModeButton.isHidden)
        XCTAssertFalse(controller.xabberInputView.searchPanel.viewModeButton.isEnabled)
    }

    func testQueryReplacementFromListImmediatelyReturnsToChatUntilNewCommit() throws {
        let controller = makeLoadedController()
        let results = makeResults(count: 2)
        prepareCommittedResults(controller, results: results, selectedIndex: 0)
        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)

        controller.reduceSearchPresentationState(.queryChanged("replacement"))

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .chat)
        XCTAssertTrue(list.view.isHidden)
        XCTAssertFalse(controller.messagesCollectionView.isHidden)
        XCTAssertNil(controller.searchPresentationState.committedResultIndex)
        XCTAssertTrue(controller.xabberInputView.searchPanel.trailingSurfaceView.isHidden)

        let generation = controller.searchPresentationState.generation
        controller.reduceSearchPresentationState(.resultsReceived(count: 1, generation: generation))
        XCTAssertTrue(controller.xabberInputView.searchPanel.trailingSurfaceView.isHidden)
        controller.reduceSearchPresentationState(.resultCommitted(index: 0, generation: generation))
        XCTAssertFalse(controller.xabberInputView.searchPanel.trailingSurfaceView.isHidden)
    }

    func testCalendarOpenedFromListRemembersListOrigin() {
        let controller = makeLoadedController()
        prepareCommittedResults(controller, results: makeResults(count: 2), selectedIndex: 0)
        controller.onSearchPanelChangeChatViewState()

        controller.onSearchPanelOpenCalendar()

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .calendar)
        XCTAssertEqual(controller.searchPresentationState.calendarOrigin, .list)
        controller.reduceSearchPresentationState(.cancelCalendar)
        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .list)
    }

    func testCancelFromListRemovesChildAndResetsSearchSurface() throws {
        let controller = makeLoadedController()
        prepareCommittedResults(controller, results: makeResults(count: 2), selectedIndex: 0)
        controller.inSearchMode.accept(true)
        controller.onSearchPanelChangeChatViewState()
        let list = try XCTUnwrap(controller.searchResultsListViewController)

        controller.cancelSearchModeFromSearchUI()

        XCTAssertFalse(controller.searchPresentationState.isActive)
        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .chat)
        XCTAssertNil(controller.searchResultsListViewController)
        XCTAssertNil(list.parent)
        XCTAssertTrue(list.isPreparedForRemoval)
        XCTAssertFalse(controller.messagesCollectionView.isHidden)
    }

    private func makeLoadedController() -> ChatViewController {
        let controller = ChatViewController()
        configureIdentity(controller)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func configureIdentity(_ controller: ChatViewController) {
        controller.owner = "owner@example.com"
        controller.jid = "andrew@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Andrew Nenakhov")
        controller.showSkeletonObserver.accept(false)
    }

    private func prepareCommittedResults(
        _ controller: ChatViewController,
        results: [ChatSearchResult],
        selectedIndex: Int
    ) {
        prepareUncommittedResults(controller, results: results)
        let generation = controller.searchPresentationState.generation
        controller.selectedSearchResultId = stableToken(results[selectedIndex].id)
        controller.reduceSearchPresentationState(
            .resultCommitted(index: selectedIndex, generation: generation)
        )
    }

    private func prepareUncommittedResults(
        _ controller: ChatViewController,
        results: [ChatSearchResult]
    ) {
        controller.reduceSearchPresentationState(.activate)
        controller.reduceSearchPresentationState(.queryChanged("test"))
        controller.searchResultPresentations = results
        controller.searchMessagesQueue = results.map(makeLegacyMessage)
        controller.reduceSearchPresentationState(
            .resultsReceived(
                count: results.count,
                generation: controller.searchPresentationState.generation
            )
        )
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
        (0..<count).map { index in
            let token = "result-\(index)"
            return ChatSearchResult(
                id: .archived(token),
                scope: ChatSearchResult.Scope(
                    owner: "owner@example.com",
                    jid: "andrew@example.com",
                    conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
                ),
                anchor: ChatSearchResult.Anchor(
                    primary: "primary-\(token)",
                    archivedId: token,
                    messageId: "message-\(token)",
                    authorId: nil,
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
                    source: .contact(jid: "andrew@example.com", owner: "owner@example.com")
                )
            )
        }
    }

    private func stableToken(_ id: ChatSearchResult.ID) -> String {
        switch id {
        case .archived(let value), .primary(let value):
            return value
        }
    }
}
