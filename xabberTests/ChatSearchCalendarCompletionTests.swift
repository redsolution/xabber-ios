//
//  ChatSearchCalendarCompletionTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchCalendarCompletionTests: XCTestCase {
    func testCoordinatorResolvesLocallyWithoutStartingRemoteFallback() {
        let local = RecordingTimestampLocalResolver()
        let remote = RecordingTimestampMAMResolver()
        let coordinator = ChatSearchCalendarCompletionCoordinator(
            localResolver: local,
            remoteResolver: remote
        )
        let request = makeCompletionRequest()
        let anchor = makeTimestampAnchor(archivedID: "local-anchor")
        var outcomes: [ChatSearchCalendarCompletionOutcome] = []

        XCTAssertTrue(coordinator.begin(request) { outcomes.append($0) })
        local.complete(requestID: request.id, with: .resolvedLocal(anchor))

        XCTAssertEqual(local.resolveCalls.map(\.id), [request.id])
        XCTAssertTrue(remote.resolveCalls.isEmpty)
        XCTAssertEqual(outcomes, [.resolved(anchor)])
        XCTAssertNil(coordinator.activeRequestID)
    }

    func testCoordinatorStartsRemoteOnlyForNeedsRemoteAndMapsResolvedAnchor() {
        let local = RecordingTimestampLocalResolver()
        let remote = RecordingTimestampMAMResolver()
        let coordinator = ChatSearchCalendarCompletionCoordinator(
            localResolver: local,
            remoteResolver: remote
        )
        let request = makeCompletionRequest(generation: 44)
        let fallback = ChatSearchTimestampRemoteFallback(
            scope: request.scope,
            selectedTimestamp: request.selectedTimestamp,
            localCandidates: []
        )
        let anchor = makeTimestampAnchor(archivedID: "remote-anchor")
        var outcomes: [ChatSearchCalendarCompletionOutcome] = []

        XCTAssertTrue(coordinator.begin(request) { outcomes.append($0) })
        local.complete(requestID: request.id, with: .needsRemote(fallback))

        XCTAssertEqual(remote.resolveCalls.count, 1)
        XCTAssertEqual(remote.resolveCalls.first?.fallback, fallback)
        XCTAssertEqual(remote.resolveCalls.first?.requestID, request.id)
        XCTAssertEqual(remote.resolveCalls.first?.generation, request.generation)

        remote.complete(requestID: request.id, with: .resolved(anchor))

        XCTAssertEqual(outcomes, [.resolved(anchor)])
        XCTAssertNil(coordinator.activeRequestID)
    }

    func testCoordinatorCancellationIsTerminalAndSuppressesLateLocalOrRemoteCallbacks() {
        let local = RecordingTimestampLocalResolver()
        let remote = RecordingTimestampMAMResolver()
        let coordinator = ChatSearchCalendarCompletionCoordinator(
            localResolver: local,
            remoteResolver: remote
        )
        let request = makeCompletionRequest()
        let fallback = ChatSearchTimestampRemoteFallback(
            scope: request.scope,
            selectedTimestamp: request.selectedTimestamp,
            localCandidates: []
        )
        var outcomes: [ChatSearchCalendarCompletionOutcome] = []

        XCTAssertTrue(coordinator.begin(request) { outcomes.append($0) })
        local.complete(requestID: request.id, with: .needsRemote(fallback), retainingCompletion: true)
        XCTAssertTrue(coordinator.cancel())
        local.complete(requestID: request.id, with: .noMessage)
        remote.complete(
            requestID: request.id,
            with: .failed(.init(reason: .serverError, description: "late"))
        )

        XCTAssertEqual(local.cancelledRequestIDs, [request.id])
        XCTAssertEqual(remote.cancelledRequestIDs, [request.id])
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNil(coordinator.activeRequestID)
    }

    func testCoordinatorRejectsDuplicateBeginUntilCurrentRequestTerminates() {
        let local = RecordingTimestampLocalResolver()
        let remote = RecordingTimestampMAMResolver()
        let coordinator = ChatSearchCalendarCompletionCoordinator(
            localResolver: local,
            remoteResolver: remote
        )
        let first = makeCompletionRequest()
        let duplicate = makeCompletionRequest()

        XCTAssertTrue(coordinator.begin(first) { _ in })
        XCTAssertFalse(coordinator.begin(duplicate) { _ in })
        XCTAssertEqual(local.resolveCalls.count, 1)

        local.complete(requestID: first.id, with: .noMessage)
        XCTAssertTrue(coordinator.begin(duplicate) { _ in })
        XCTAssertEqual(local.resolveCalls.count, 2)
    }

    func testCalendarCloseCallsNoResolverAndPreservesQueryResultsSelectionAndOrigin() throws {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: true)
        let before = controller.searchPresentationState
        let selectedID = controller.selectedSearchResultId

        controller.onSearchPanelOpenCalendar()
        XCTAssertEqual(controller.searchPresentationState.calendarOrigin, .list)
        controller.dismissChatSearchCalendar(animated: false)

        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .list)
        XCTAssertEqual(controller.searchPresentationState.query, before.query)
        XCTAssertEqual(controller.searchPresentationState.resultCount, before.resultCount)
        XCTAssertEqual(
            controller.searchPresentationState.committedResultIndex,
            before.committedResultIndex
        )
        XCTAssertEqual(controller.selectedSearchResultId, selectedID)
        XCTAssertTrue(harness.local.resolveCalls.isEmpty)
        XCTAssertTrue(harness.remote.resolveCalls.isEmpty)
        XCTAssertFalse(controller.isChatSearchCalendarDateResolutionLoading)
    }

    func testDoneFromChatClosesSearchRestoresComposerAndQueuesSafeUnhighlightedLocalAnchor() throws {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: false)
        let timestamp = Date(timeIntervalSince1970: 1_786_000_000)
        let anchor = makeTimestampAnchor(archivedID: "calendar-local", date: timestamp)
        harness.local.onResolve = { _ in .resolvedLocal(anchor) }

        controller.onSearchPanelOpenCalendar()
        controller.completeChatSearchCalendar(at: timestamp, animated: false)

        let request = try XCTUnwrap(controller.pendingOpenMessageRequest)
        XCTAssertFalse(controller.searchPresentationState.isActive)
        XCTAssertEqual(controller.searchPresentationState.surfaceMode, .chat)
        XCTAssertEqual(controller.searchPresentationState.positioningPhase, .idle)
        XCTAssertEqual(controller.searchPresentationState.query, "")
        XCTAssertTrue(controller.searchResultPresentations.isEmpty)
        XCTAssertTrue(controller.searchMessagesQueue.isEmpty)
        XCTAssertNil(controller.searchResultsListViewController)
        XCTAssertEqual(controller.xabberInputView.state, .normal)
        XCTAssertFalse(controller.inSearchMode.value)
        XCTAssertFalse(controller.isChatSearchCalendarDateResolutionLoading)
        XCTAssertEqual(request.source, .search)
        XCTAssertFalse(request.markReadOnVisible)
        XCTAssertFalse(request.highlight)
        XCTAssertEqual(request.anchor.archivedId, "calendar-local")
        XCTAssertEqual(request.anchor.sourceDate, timestamp)
        XCTAssertTrue(harness.remote.resolveCalls.isEmpty)
    }

    func testDoneFromListClearsListAndRemoteResultUsesSameSafeAnchorPipeline() throws {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: true)
        let timestamp = Date(timeIntervalSince1970: 1_786_000_120)
        let fallback = ChatSearchTimestampRemoteFallback(
            scope: makeScope(),
            selectedTimestamp: timestamp,
            localCandidates: []
        )
        let anchor = makeTimestampAnchor(archivedID: "calendar-remote", date: timestamp)
        harness.local.onResolve = { _ in .needsRemote(fallback) }
        harness.remote.onResolve = { _, _, _ in .resolved(anchor) }

        controller.onSearchPanelOpenCalendar()
        controller.completeChatSearchCalendar(at: timestamp, animated: false)

        let request = try XCTUnwrap(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.searchResultsListViewController)
        XCTAssertFalse(controller.messagesCollectionView.isHidden)
        XCTAssertEqual(harness.remote.resolveCalls.count, 1)
        XCTAssertEqual(request.source, .search)
        XCTAssertFalse(request.markReadOnVisible)
        XCTAssertFalse(request.highlight)
        XCTAssertEqual(request.anchor.archivedId, "calendar-remote")
    }

    func testNoMessageStopsDateLoaderLeavesAnchorPositionUntouchedAndAnnounces() {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: false)
        harness.local.onResolve = { _ in .noMessage }
        var announcements: [String] = []
        controller.chatSearchCalendarDateAnnouncementHandler = { announcements.append($0) }

        controller.onSearchPanelOpenCalendar()
        controller.completeChatSearchCalendar(at: Date(timeIntervalSince1970: 1_786_000_240), animated: false)

        XCTAssertFalse(controller.isChatSearchCalendarDateResolutionLoading)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(controller.searchPresentationState.positioningPhase, .idle)
        XCTAssertEqual(announcements, ["No messages"])
        XCTAssertTrue(harness.remote.resolveCalls.isEmpty)
    }

    func testRemoteErrorStopsDateLoaderShowsRecoverableIndicationAndDoesNotRetry() {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: false)
        let timestamp = Date(timeIntervalSince1970: 1_786_000_360)
        harness.local.onResolve = { request in
            .needsRemote(
                .init(
                    scope: request.scope,
                    selectedTimestamp: request.selectedTimestamp,
                    localCandidates: []
                )
            )
        }
        harness.remote.onResolve = { _, _, _ in
            .failed(.init(reason: .serverError, description: "temporary"))
        }
        var errors: [String] = []
        controller.chatSearchCalendarDateErrorHandler = { errors.append($0) }

        controller.onSearchPanelOpenCalendar()
        controller.completeChatSearchCalendar(at: timestamp, animated: false)

        XCTAssertFalse(controller.isChatSearchCalendarDateResolutionLoading)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(errors, ["Internal error"])
        XCTAssertEqual(harness.local.resolveCalls.count, 1)
        XCTAssertEqual(harness.remote.resolveCalls.count, 1)
    }

    func testDoubleDoneStartsOneResolutionAndNavigationAwayCancelsWithoutLateAnchor() {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: false)
        let timestamp = Date(timeIntervalSince1970: 1_786_000_480)

        controller.onSearchPanelOpenCalendar()
        controller.completeChatSearchCalendar(at: timestamp, animated: false)
        controller.completeChatSearchCalendar(at: timestamp, animated: false)

        XCTAssertEqual(harness.local.resolveCalls.count, 1)
        XCTAssertTrue(controller.isChatSearchCalendarDateResolutionLoading)
        let requestID = harness.local.resolveCalls[0].id

        controller.cancelChatSearchCalendarDateResolution()
        harness.local.complete(
            requestID: requestID,
            with: .resolvedLocal(makeTimestampAnchor(archivedID: "stale"))
        )

        XCTAssertEqual(harness.local.cancelledRequestIDs, [requestID])
        XCTAssertFalse(controller.isChatSearchCalendarDateResolutionLoading)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(controller.searchPresentationState.positioningPhase, .idle)
    }

    func testBackgroundCancelsActiveDateResolutionAndLateCompletionCannotOpenMessage() {
        let harness = makeControllerHarness()
        let controller = harness.controller
        prepareCommittedSearch(controller, listMode: false)

        controller.onSearchPanelOpenCalendar()
        controller.completeChatSearchCalendar(
            at: Date(timeIntervalSince1970: 1_786_000_540),
            animated: false
        )
        let requestID = harness.local.resolveCalls[0].id

        controller.handleApplicationDidEnterBackground()
        harness.local.complete(
            requestID: requestID,
            with: .resolvedLocal(makeTimestampAnchor(archivedID: "late-background"))
        )

        XCTAssertEqual(harness.local.cancelledRequestIDs, [requestID])
        XCTAssertFalse(controller.isChatSearchCalendarDateResolutionLoading)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(controller.searchPresentationState.positioningPhase, .idle)
    }

    func testAnchorRequestFactoryRejectsScopeMismatchAndUsesPrimaryFallbackWhenArchiveIsMissing() throws {
        let primary = ChatSearchTimestampAnchor(
            id: .primary("primary-only"),
            scope: makeScope(),
            anchor: .init(
                primary: "primary-only",
                archivedId: "",
                messageId: "message-only",
                authorId: nil,
                date: Date(timeIntervalSince1970: 1_786_000_600)
            )
        )

        let request = try XCTUnwrap(
            ChatSearchCalendarAnchorRequestFactory.make(
                anchor: primary,
                conversationType: .regular
            )
        )
        XCTAssertEqual(request.anchor.messagePrimary, "primary-only")
        XCTAssertNil(request.anchor.archivedId)
        XCTAssertFalse(request.highlight)
        XCTAssertFalse(request.markReadOnVisible)

        XCTAssertNil(
            ChatSearchCalendarAnchorRequestFactory.make(
                anchor: primary,
                conversationType: .group
            )
        )
    }

    private func makeControllerHarness() -> CalendarCompletionControllerHarness {
        let local = RecordingTimestampLocalResolver()
        let remote = RecordingTimestampMAMResolver()
        let coordinator = ChatSearchCalendarCompletionCoordinator(
            localResolver: local,
            remoteResolver: remote
        )
        let controller = ChatViewController()
        controller.owner = makeScope().owner
        controller.jid = makeScope().jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Andrew Nenakhov")
        controller.showSkeletonObserver.accept(false)
        controller.searchCalendarCompletionCoordinator = coordinator
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return .init(controller: controller, local: local, remote: remote)
    }

    private func prepareCommittedSearch(_ controller: ChatViewController, listMode: Bool) {
        let result = makeResult()
        controller.reduceSearchPresentationState(.activate)
        controller.reduceSearchPresentationState(.queryChanged("test"))
        controller.searchResultPresentations = [result]
        controller.searchMessagesQueue = [makeLegacyMessage(result)]
        let generation = controller.searchPresentationState.generation
        controller.reduceSearchPresentationState(.resultsReceived(count: 1, generation: generation))
        controller.selectedSearchResultId = "existing-result"
        controller.reduceSearchPresentationState(.resultCommitted(index: 0, generation: generation))
        controller.inSearchMode.accept(true)
        controller.xabberInputView.changeState(to: .search)
        controller.searchBar.text = "test"
        controller.searchInputBar.text = "test"
        if listMode {
            controller.onSearchPanelChangeChatViewState()
        }
    }

    private func makeCompletionRequest(generation: UInt64 = 43) -> ChatSearchCalendarCompletionRequest {
        ChatSearchCalendarCompletionRequest(
            id: UUID(),
            generation: generation,
            scope: makeScope(),
            selectedTimestamp: Date(timeIntervalSince1970: 1_786_000_000),
            displayedCandidates: [],
            displayedCoverage: nil
        )
    }

    private func makeScope() -> ChatSearchResult.Scope {
        ChatSearchResult.Scope(
            owner: "owner@example.com",
            jid: "andrew@example.com",
            conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
        )
    }

    private func makeTimestampAnchor(
        archivedID: String,
        date: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) -> ChatSearchTimestampAnchor {
        ChatSearchTimestampAnchor(
            id: .archived(archivedID),
            scope: makeScope(),
            anchor: .init(
                primary: "primary-\(archivedID)",
                archivedId: archivedID,
                messageId: "message-\(archivedID)",
                authorId: nil,
                date: date
            )
        )
    }

    private func makeResult() -> ChatSearchResult {
        ChatSearchResult(
            id: .archived("existing-result"),
            scope: makeScope(),
            anchor: .init(
                primary: "primary-existing-result",
                archivedId: "existing-result",
                messageId: "message-existing-result",
                authorId: nil,
                date: Date(timeIntervalSince1970: 1_785_999_000)
            ),
            outgoing: false,
            senderTitle: "Andrew Nenakhov",
            body: "test message",
            snippet: "test message",
            deliveryState: .delivered,
            avatar: .init(
                identity: "andrew@example.com",
                fallbackTitle: "Andrew Nenakhov",
                url: nil,
                source: .contact(jid: "andrew@example.com", owner: "owner@example.com")
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
}

@MainActor
private struct CalendarCompletionControllerHarness {
    let controller: ChatViewController
    let local: RecordingTimestampLocalResolver
    let remote: RecordingTimestampMAMResolver
}

private final class RecordingTimestampLocalResolver: ChatSearchTimestampResolving {
    private(set) var resolveCalls: [ChatSearchTimestampResolutionRequest] = []
    private(set) var cancelledRequestIDs: [UUID] = []
    var onResolve: ((ChatSearchTimestampResolutionRequest) -> ChatSearchTimestampResolutionOutcome)?
    private var completions: [UUID: (ChatSearchTimestampResolutionOutcome) -> Void] = [:]

    func resolve(
        _ request: ChatSearchTimestampResolutionRequest,
        completion: @escaping (ChatSearchTimestampResolutionOutcome) -> Void
    ) {
        resolveCalls.append(request)
        completions[request.id] = completion
        if let outcome = onResolve?(request) {
            completions.removeValue(forKey: request.id)?(outcome)
        }
    }

    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        cancelledRequestIDs.append(requestID)
        return completions[requestID] != nil
    }

    func complete(
        requestID: UUID,
        with outcome: ChatSearchTimestampResolutionOutcome,
        retainingCompletion: Bool = false
    ) {
        let completion = completions[requestID]
        if !retainingCompletion {
            completions.removeValue(forKey: requestID)
        }
        completion?(outcome)
    }
}

private final class RecordingTimestampMAMResolver: ChatSearchTimestampMAMResolving {
    struct ResolveCall: Equatable {
        let fallback: ChatSearchTimestampRemoteFallback
        let requestID: UUID
        let generation: UInt64
    }

    private(set) var resolveCalls: [ResolveCall] = []
    private(set) var cancelledRequestIDs: [UUID] = []
    var onResolve: ((ChatSearchTimestampRemoteFallback, UUID, UInt64) -> ChatSearchTimestampMAMResolutionOutcome)?
    private var completions: [UUID: (ChatSearchTimestampMAMResolutionOutcome) -> Void] = [:]

    func resolve(
        _ fallback: ChatSearchTimestampRemoteFallback,
        requestID: UUID,
        generation: UInt64,
        completion: @escaping (ChatSearchTimestampMAMResolutionOutcome) -> Void
    ) {
        resolveCalls.append(.init(fallback: fallback, requestID: requestID, generation: generation))
        completions[requestID] = completion
        if let outcome = onResolve?(fallback, requestID, generation) {
            completions.removeValue(forKey: requestID)?(outcome)
        }
    }

    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        cancelledRequestIDs.append(requestID)
        return completions[requestID] != nil
    }

    func complete(requestID: UUID, with outcome: ChatSearchTimestampMAMResolutionOutcome) {
        completions.removeValue(forKey: requestID)?(outcome)
    }
}
