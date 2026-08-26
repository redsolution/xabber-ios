import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchLifecycleTests: XCTestCase {
    func testFiftyActivateCancelCyclesLeaveNoTransientChildOrCallbacks() {
        let controller = makeLoadedController()
        let baselineChildren = controller.children.count

        for index in 0..<50 {
            prepareCommittedSearch(controller, suffix: index)
            controller.onSearchPanelChangeChatViewState()
            XCTAssertNotNil(controller.searchResultsListViewController)

            controller.cancelSearchModeFromSearchUI()

            XCTAssertFalse(controller.searchPresentationState.isActive)
            XCTAssertNil(controller.searchResultsListViewController)
            XCTAssertNil(controller.searchCalendarViewController)
            XCTAssertEqual(controller.children.count, baselineChildren)
            XCTAssertFalse(controller.view.subviews.contains {
                $0.accessibilityIdentifier == "chat_search_mode_transition_snapshot" ||
                    $0.accessibilityIdentifier == ChatSearchCalendarViewController.dimAccessibilityIdentifier
            })
        }
    }

    func testNavigationTeardownCancelsAsyncOwnershipAndRestoresNormalChat() throws {
        let controller = makeLoadedController()
        prepareCommittedSearch(controller, suffix: 1)
        controller.onSearchPanelChangeChatViewState()
        controller.onSearchPanelOpenCalendar()
        let workItem = DispatchWorkItem {}
        controller.searchSessionDebounceWorkItem = workItem
        controller.searchSessionDebounceGeneration = controller.searchSession.generation

        controller.teardownChatSearchLifecycle(reason: .navigationAway)

        XCTAssertTrue(workItem.isCancelled)
        XCTAssertNil(controller.searchResultsListViewController)
        XCTAssertNil(controller.searchCalendarViewController)
        XCTAssertNil(controller.searchSessionDebounceWorkItem)
        XCTAssertTrue(controller.searchSessionGenerationByQueryId.isEmpty)
        XCTAssertFalse(controller.searchPresentationState.isActive)
        XCTAssertEqual(controller.searchSession.providerPhase, .idle)
        XCTAssertEqual(controller.xabberInputView.state, .normal)
        XCTAssertFalse(controller.messagesCollectionView.isHidden)
        XCTAssertTrue(controller.messagesCollectionView.isUserInteractionEnabled)
    }

    func testTeardownReleasesListCalendarAndAvatarRequestOwners() throws {
        weak var weakList: ChatSearchResultsListViewController?
        weak var weakCalendar: ChatSearchCalendarViewController?
        weak var weakController: ChatViewController?
        autoreleasepool {
            let controller = makeLoadedController()
            weakController = controller
            prepareCommittedSearch(controller, suffix: 2)
            controller.onSearchPanelChangeChatViewState()
            controller.onSearchPanelOpenCalendar()
            weakList = controller.searchResultsListViewController
            weakCalendar = controller.searchCalendarViewController

            controller.teardownChatSearchLifecycle(reason: .navigationAway)

            XCTAssertNil(controller.searchResultsListViewController)
            XCTAssertNil(controller.searchCalendarViewController)
        }

        XCTAssertNil(weakList)
        XCTAssertNil(weakCalendar)
        XCTAssertNil(weakController)
    }

    func testBackgroundInterruptCancelsWorkAndSettlesReducerWithoutDroppingQuery() {
        let controller = makeLoadedController()
        controller.reduceSearchPresentationState(.activate)
        controller.reduceSearchPresentationState(.queryChanged("test"))
        controller.acceptSearchSessionQuery("test", flushImmediately: false)
        let originalGeneration = controller.searchSession.generation

        controller.handleChatSearchApplicationDidEnterBackground()

        XCTAssertEqual(controller.searchSession.generation, originalGeneration)
        XCTAssertEqual(controller.searchSession.normalizedQuery, "test")
        XCTAssertEqual(controller.searchSession.providerPhase, .failed)
        XCTAssertEqual(controller.searchPresentationState.resultPhase, .error)
        XCTAssertNil(controller.searchSessionDebounceWorkItem)
        XCTAssertFalse(controller.searchModeTransitionCoordinator.isTransitioning)
        XCTAssertFalse(controller.searchChromeTransitionCoordinator.isTransitioning)
    }

    func testBackgroundKeepsCompletedResultsAndForegroundRendersCurrentScope() {
        let controller = makeLoadedController()
        prepareCommittedSearch(controller, suffix: 3)
        let resultIDs = controller.searchResultPresentations.map(\.id)
        let generation = controller.searchPresentationState.generation

        controller.handleChatSearchApplicationDidEnterBackground()
        controller.handleChatSearchApplicationWillEnterForeground()

        XCTAssertEqual(controller.searchPresentationState.generation, generation)
        XCTAssertEqual(controller.searchResultPresentations.map(\.id), resultIDs)
        XCTAssertEqual(controller.makeChatSearchResultsListRenderModel()?.results.map(\.id), resultIDs)
    }

    func testLayoutInterruptionRemovesTransitionArtifactsAndPreservesFinalMode() {
        let controller = makeLoadedController()
        prepareCommittedSearch(controller, suffix: 4)
        controller.onSearchPanelChangeChatViewState()

        controller.handleChatSearchLayoutInterruption()

        XCTAssertFalse(controller.searchModeTransitionCoordinator.isTransitioning)
        XCTAssertEqual(controller.searchModeTransitionCoordinator.activeOverlayCount, 0)
        XCTAssertEqual(controller.searchModeTransitionCoordinator.settledMode, .list)
        XCTAssertTrue(controller.messagesCollectionView.isHidden)
        XCTAssertFalse(controller.searchResultsListViewController?.view.isHidden ?? true)
    }

    func testMemoryWarningClearsExpendableSearchCachesButKeepsIdentityState() throws {
        let controller = makeLoadedController()
        prepareCommittedSearch(controller, suffix: 5)
        let style = ChatSearchHighlightStyle.telegram(for: .init(userInterfaceStyle: .light))
        _ = ChatSearchHighlighter.applying(
            to: NSAttributedString(string: "test message"),
            query: "test",
            style: style
        )
        _ = ChatSearchFormatting(
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ).resultDate(for: Date(timeIntervalSince1970: 1_700_000_000), relativeTo: Date())
        let query = controller.searchPresentationState.query
        let resultIDs = controller.searchResultPresentations.map(\.id)
        XCTAssertGreaterThan(ChatSearchHighlighter.cachedEntryCount, 0)
        XCTAssertGreaterThan(ChatSearchFormatterCache.shared.cachedFormatterCount, 0)

        controller.handleChatSearchMemoryWarning()

        XCTAssertEqual(ChatSearchHighlighter.cachedEntryCount, 0)
        XCTAssertEqual(ChatSearchFormatterCache.shared.cachedFormatterCount, 0)
        XCTAssertEqual(controller.searchPresentationState.query, query)
        XCTAssertEqual(controller.searchResultPresentations.map(\.id), resultIDs)
    }

    func testScopeChangeInvalidatesGenerationAndRejectsPreviousPeerResults() {
        let controller = makeLoadedController()
        prepareCommittedSearch(controller, suffix: 6)
        let oldGeneration = controller.searchPresentationState.generation
        controller.jid = "alexey@example.com"

        XCTAssertTrue(controller.invalidateChatSearchForCurrentScopeIfNeeded())
        XCTAssertGreaterThan(controller.searchPresentationState.generation, oldGeneration)
        XCTAssertFalse(controller.searchPresentationState.isActive)
        XCTAssertTrue(controller.searchResultPresentations.isEmpty)
        XCTAssertNil(controller.makeChatSearchResultsListRenderModel())
    }

    func testObserverRemovalIsIdempotentAcrossLifecycleTeardown() {
        let controller = makeLoadedController()
        controller.addObservers()
        XCTAssertTrue(controller.chatObserversRegistered)

        controller.teardownChatSearchLifecycle(reason: .navigationAway)
        controller.removeObservers()
        controller.removeObservers()

        XCTAssertFalse(controller.chatObserversRegistered)
        XCTAssertEqual(controller.chatSearchObserverRemovalCount, 1)
    }

    func testRemovedSearchHierarchyDoesNotRetainKeyboardOwnedViews() throws {
        weak var weakListView: UIView?
        autoreleasepool {
            let controller = makeLoadedController()
            prepareCommittedSearch(controller, suffix: 7)
            controller.onSearchPanelChangeChatViewState()
            let list = try! XCTUnwrap(controller.searchResultsListViewController)
            weakListView = list.view

            controller.teardownChatSearchLifecycle(reason: .navigationAway)

            XCTAssertEqual(list.containmentConstraintCount, 0)
            XCTAssertNil(list.parent)
            XCTAssertNil(list.view.superview)
            XCTAssertFalse(controller.searchInputBar.isFirstResponder)
            XCTAssertFalse(controller.searchBar.isFirstResponder)
            XCTAssertEqual(controller.xabberInputView.state, .normal)
        }
        XCTAssertNil(weakListView)
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

    private func prepareCommittedSearch(_ controller: ChatViewController, suffix: Int) {
        let result = makeResult(suffix: suffix)
        controller.reduceSearchPresentationState(.activate)
        controller.reduceSearchPresentationState(.queryChanged("test"))
        controller.searchResultPresentations = [result]
        let item = MessageStorageItem()
        item.primary = result.anchor.primary
        item.archivedId = result.anchor.archivedId
        item.messageId = result.anchor.messageId
        controller.searchMessagesQueue = [item]
        let generation = controller.searchPresentationState.generation
        controller.reduceSearchPresentationState(.resultsReceived(count: 1, generation: generation))
        controller.selectedSearchResultId = result.anchor.archivedId
        controller.reduceSearchPresentationState(.resultCommitted(index: 0, generation: generation))
        controller.inSearchMode.accept(true)
        controller.xabberInputView.changeState(to: .search)
    }

    private func makeResult(suffix: Int) -> ChatSearchResult {
        ChatSearchResult(
            id: .archived("archive-\(suffix)"),
            scope: .init(
                owner: "owner@example.com",
                jid: "andrew@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            ),
            anchor: .init(
                primary: "primary-\(suffix)",
                archivedId: "archive-\(suffix)",
                messageId: "message-\(suffix)",
                authorId: nil,
                date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + suffix))
            ),
            outgoing: false,
            senderTitle: "Andrew",
            body: "test",
            snippet: "test",
            deliveryState: .read,
            avatar: .init(
                identity: "andrew",
                fallbackTitle: "Andrew",
                url: nil,
                source: .contact(jid: "andrew@example.com", owner: "owner@example.com")
            )
        )
    }
}
