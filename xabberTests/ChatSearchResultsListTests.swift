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
import UIKit
@testable import xabber

final class ChatSearchResultsListTests: XCTestCase {
    func testRenderModelOrdersNewestFirstDeduplicatesAndHandlesBoundaryCounts() {
        let newest = makeResult(id: .archived("newest"), minute: 3)
        let middle = makeResult(id: .archived("middle"), minute: 2)
        let oldest = makeResult(id: .archived("oldest"), minute: 1)
        let duplicateOldest = makeResult(
            id: .archived("oldest"),
            minute: 1,
            snippet: "more complete oldest result",
            avatarURL: "https://example.com/oldest.jpg"
        )

        let model = ChatSearchResultsListRenderModel(
            generation: 8,
            results: [oldest, newest, duplicateOldest, middle],
            selectedID: newest.id,
            phase: .populated
        )

        XCTAssertEqual(model.results.map(\.id), [newest.id, middle.id, oldest.id])
        XCTAssertEqual(model.results.last?.snippet, duplicateOldest.snippet)
        XCTAssertTrue(model.canPresent)

        for count in [0, 1, 250, 1_000] {
            let results = (0..<count).map { index in
                makeResult(id: .primary("row-\(index)"), minute: index)
            }
            let boundaryModel = ChatSearchResultsListRenderModel(
                generation: UInt64(count + 1),
                results: Array(results.reversed()),
                selectedID: results.first?.id,
                phase: results.isEmpty ? .empty : .populated
            )
            XCTAssertEqual(boundaryModel.results.count, count)
            XCTAssertEqual(Set(boundaryModel.results.map(\.id)).count, count)
        }
    }

    func testListCannotPresentWithoutCommittedIdentityInCurrentResults() {
        let result = makeResult(id: .primary("only"), minute: 1)

        XCTAssertFalse(ChatSearchResultsListRenderModel(
            generation: 1,
            results: [],
            selectedID: nil,
            phase: .empty
        ).canPresent)
        XCTAssertFalse(ChatSearchResultsListRenderModel(
            generation: 1,
            results: [result],
            selectedID: .primary("missing"),
            phase: .populated
        ).canPresent)
        XCTAssertTrue(ChatSearchResultsListRenderModel(
            generation: 1,
            results: [result],
            selectedID: result.id,
            phase: .loadingNextPage
        ).canPresent)
    }

    func testSnapshotPlanUsesStableIdentityAndReconfiguresOnlyChangedRows() {
        let unchanged = makeResult(id: .primary("unchanged"), minute: 3)
        let oldChanged = makeResult(id: .primary("changed"), minute: 2, snippet: "old")
        let newChanged = makeResult(
            id: .primary("changed"),
            minute: 2,
            snippet: "new",
            avatarURL: "https://example.com/changed.jpg"
        )
        let added = makeResult(id: .primary("added"), minute: 4)

        let plan = ChatSearchResultsListSnapshotPlan.make(
            previous: [unchanged, oldChanged],
            incoming: [oldChanged, added, unchanged, newChanged],
            visibleAnchor: nil
        )

        XCTAssertEqual(plan.itemIDs, [added.id, unchanged.id, newChanged.id])
        XCTAssertEqual(plan.reconfiguredIDs, [newChanged.id])
        XCTAssertFalse(plan.reconfiguredIDs.contains(unchanged.id))
    }

    func testSnapshotPlanRetainsStableVisibleAnchorAcrossIncrementalAppend() {
        let first = makeResult(id: .primary("first"), minute: 3)
        let second = makeResult(id: .primary("second"), minute: 2)
        let appended = makeResult(id: .primary("appended"), minute: 1)
        let anchor = ChatSearchResultsListScrollAnchor(id: second.id, offsetFromTop: 7.5)

        let plan = ChatSearchResultsListSnapshotPlan.make(
            previous: [first, second],
            incoming: [appended, second, first],
            visibleAnchor: anchor
        )

        XCTAssertEqual(plan.itemIDs, [first.id, second.id, appended.id])
        XCTAssertEqual(plan.retainedAnchor, anchor)

        let removal = ChatSearchResultsListSnapshotPlan.make(
            previous: [first, second],
            incoming: [first],
            visibleAnchor: anchor
        )
        XCTAssertNil(removal.retainedAnchor)
    }

    func testControllerRendersEveryStateWithoutGenericCardSurfaces() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.view.backgroundColor, .systemBackground)
        XCTAssertEqual(controller.tableView.backgroundColor, .systemBackground)
        XCTAssertEqual(controller.emptyView.backgroundColor, .clear)
        XCTAssertEqual(controller.errorView.backgroundColor, .clear)
        XCTAssertNil(controller.view.accessibilityIdentifier)
        XCTAssertEqual(controller.tableView.accessibilityIdentifier, "chat_search_results_list")

        controller.render(model(generation: 1, results: [], phase: .loadingFirstPage))
        XCTAssertFalse(controller.firstPageLoadingView.isHidden)
        XCTAssertTrue(controller.emptyView.isHidden)
        XCTAssertTrue(controller.errorView.isHidden)

        controller.render(model(generation: 1, results: [], phase: .empty))
        XCTAssertFalse(controller.emptyView.isHidden)
        XCTAssertTrue(controller.firstPageLoadingView.isHidden)

        controller.render(model(generation: 1, results: [], phase: .error))
        XCTAssertFalse(controller.errorView.isHidden)
        XCTAssertTrue(controller.emptyView.isHidden)

        let result = makeResult(id: .primary("visible"), minute: 1)
        controller.render(model(generation: 1, results: [result], phase: .populated))
        XCTAssertFalse(controller.tableView.isHidden)
        XCTAssertTrue(controller.errorView.isHidden)
        XCTAssertFalse(controller.isPagingIndicatorVisible)

        controller.render(model(generation: 1, results: [result], phase: .loadingNextPage))
        XCTAssertFalse(controller.tableView.isHidden)
        XCTAssertEqual(controller.displayedResultIDs, [result.id])
        XCTAssertTrue(controller.isPagingIndicatorVisible)
    }

    func testStaleGenerationIsIgnoredAndPagingKeepsPartialResultsVisible() {
        let controller = makeController()
        let current = makeResult(id: .primary("current"), minute: 2)
        controller.loadViewIfNeeded()

        controller.render(model(generation: 10, results: [current], phase: .populated))
        controller.render(model(generation: 9, results: [], phase: .empty))

        XCTAssertEqual(controller.latestGeneration, 10)
        XCTAssertEqual(controller.displayedResultIDs, [current.id])
        XCTAssertTrue(controller.emptyView.isHidden)

        controller.render(model(generation: 10, results: [current], phase: .loadingNextPage))
        XCTAssertEqual(controller.displayedResultIDs, [current.id])
        XCTAssertTrue(controller.isPagingIndicatorVisible)
    }

    func testControllerSnapshotDoesNotReconfigureUnchangedRows() {
        let controller = makeController()
        let first = makeResult(id: .primary("first"), minute: 2)
        let second = makeResult(id: .primary("second"), minute: 1)
        controller.loadViewIfNeeded()

        controller.render(model(generation: 3, results: [first, second], phase: .populated))
        XCTAssertTrue(controller.lastReconfiguredResultIDs.isEmpty)

        controller.render(model(generation: 3, results: [first, second], phase: .populated))
        XCTAssertTrue(controller.lastReconfiguredResultIDs.isEmpty)

        let changedSecond = makeResult(
            id: second.id,
            minute: 1,
            snippet: "changed second"
        )
        controller.render(model(
            generation: 3,
            results: [first, changedSecond],
            phase: .populated
        ))
        XCTAssertEqual(controller.lastReconfiguredResultIDs, [second.id])
    }

    func testSelectionCallbackUsesStableIdentityRatherThanIndex() {
        let controller = makeController()
        let newer = makeResult(id: .archived("newer"), minute: 2)
        let older = makeResult(id: .archived("older"), minute: 1)
        var selected: ChatSearchResult.ID?
        controller.onSelectResult = { selected = $0 }
        controller.loadViewIfNeeded()
        controller.render(model(
            generation: 5,
            results: [older, newer],
            selectedID: newer.id,
            phase: .populated
        ))

        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 1, section: 0)
        )

        XCTAssertEqual(selected, older.id)
    }

    func testAccessibilityIdentifiersCoverListRowsEmptyErrorAndPaging() throws {
        let controller = makeController()
        let result = makeResult(id: .archived("archive-42"), minute: 1)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.emptyView.accessibilityIdentifier, "chat_search_results_empty")
        XCTAssertEqual(controller.errorView.accessibilityIdentifier, "chat_search_results_error")
        XCTAssertEqual(
            controller.firstPageLoadingView.accessibilityIdentifier,
            "chat_search_results_paging"
        )
        XCTAssertEqual(
            controller.pagingIndicatorView.accessibilityIdentifier,
            "chat_search_results_paging"
        )

        controller.render(model(
            generation: 4,
            results: [result],
            selectedID: result.id,
            phase: .populated
        ))
        let dataSource = try XCTUnwrap(controller.tableView.dataSource)
        let cell = dataSource.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(
            cell.accessibilityIdentifier,
            "chat_search_result_row.archived.archive-42"
        )
    }

    func testInsetsAccountForChromeBottomBarKeyboardAndSafeAreas() {
        let safeArea = UIEdgeInsets(top: 47, left: 11, bottom: 34, right: 13)

        XCTAssertEqual(
            ChatSearchResultsListInsetsPolicy.contentInsets(
                safeAreaInsets: safeArea,
                keyboardOverlap: 0
            ),
            UIEdgeInsets(top: 107, left: 11, bottom: 74, right: 13)
        )
        XCTAssertEqual(
            ChatSearchResultsListInsetsPolicy.contentInsets(
                safeAreaInsets: safeArea,
                keyboardOverlap: 320
            ),
            UIEdgeInsets(top: 107, left: 11, bottom: 360, right: 13)
        )

        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.updateContentInsets(
            safeAreaInsets: safeArea,
            keyboardOverlap: 320
        )
        XCTAssertEqual(
            controller.tableView.contentInset,
            UIEdgeInsets(top: 107, left: 11, bottom: 360, right: 13)
        )
        XCTAssertEqual(controller.tableView.scrollIndicatorInsets, controller.tableView.contentInset)
    }

    func testContainmentIsIdempotentAndRemovalReleasesListStateWithoutResigningInput() {
        let parent = UIViewController()
        parent.loadViewIfNeeded()
        let textField = ResignTrackingTextField()
        parent.view.addSubview(textField)
        let controller = makeController()
        controller.onSelectResult = { _ in }
        controller.onRetry = { _ in }
        controller.render(model(
            generation: 2,
            results: [makeResult(id: .primary("one"), minute: 1)],
            phase: .populated
        ))

        ChatSearchResultsListContainment.install(
            controller,
            in: parent.view,
            parent: parent
        )
        ChatSearchResultsListContainment.install(
            controller,
            in: parent.view,
            parent: parent
        )

        XCTAssertTrue(controller.parent === parent)
        XCTAssertTrue(controller.view.superview === parent.view)
        XCTAssertEqual(parent.children.filter { $0 === controller }.count, 1)
        XCTAssertEqual(textField.resignCallCount, 0)
        XCTAssertNotNil(controller.diffableDataSource)

        ChatSearchResultsListContainment.remove(controller)

        XCTAssertNil(controller.parent)
        XCTAssertNil(controller.view.superview)
        XCTAssertTrue(controller.isPreparedForRemoval)
        XCTAssertNil(controller.diffableDataSource)
        XCTAssertTrue(controller.displayedResultIDs.isEmpty)
        XCTAssertNil(controller.onSelectResult)
        XCTAssertNil(controller.onRetry)
        XCTAssertEqual(textField.resignCallCount, 0)
    }

    func testRetryUsesCurrentNonStaleGeneration() {
        let controller = makeController()
        var retriedGenerations: [UInt64] = []
        controller.onRetry = { retriedGenerations.append($0) }
        controller.loadViewIfNeeded()

        controller.render(model(generation: 7, results: [], phase: .error))
        controller.render(model(generation: 6, results: [], phase: .error))
        controller.errorRetryButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(retriedGenerations, [7])
    }

    func testProgrammaticScrollTargetsStableSelectedIdentity() {
        let controller = makeController()
        let newest = makeResult(id: .primary("newest"), minute: 2)
        let oldest = makeResult(id: .primary("oldest"), minute: 1)
        controller.loadViewIfNeeded()
        controller.render(model(
            generation: 1,
            results: [oldest, newest],
            selectedID: oldest.id,
            phase: .populated
        ))

        XCTAssertTrue(controller.scrollToResult(id: oldest.id, animated: false))
        XCTAssertEqual(controller.lastProgrammaticScrollID, oldest.id)
        XCTAssertFalse(controller.scrollToResult(id: .primary("missing"), animated: false))
        XCTAssertEqual(controller.lastProgrammaticScrollID, oldest.id)
    }

    func testLargeSyntheticSnapshotHasStableBoundsAndNoDuplicateRows() {
        let controller = makeController()
        let rows = (0..<1_000).map { index in
            makeResult(id: .primary("large-\(index)"), minute: index)
        }
        controller.loadViewIfNeeded()

        controller.render(model(
            generation: 88,
            results: Array(rows.reversed()) + [rows[500]],
            selectedID: rows[500].id,
            phase: .loadingNextPage
        ))

        XCTAssertEqual(controller.displayedResultIDs.count, 1_000)
        XCTAssertEqual(Set(controller.displayedResultIDs).count, 1_000)
        XCTAssertEqual(controller.displayedResultIDs.first, rows.last?.id)
        XCTAssertEqual(controller.displayedResultIDs.last, rows.first?.id)
        XCTAssertTrue(controller.isPagingIndicatorVisible)
    }

    private func makeController() -> ChatSearchResultsListViewController {
        ChatSearchResultsListViewController()
    }

    private func model(
        generation: UInt64,
        results: [ChatSearchResult],
        selectedID: ChatSearchResult.ID? = nil,
        phase: ChatSearchResultsListRenderModel.Phase
    ) -> ChatSearchResultsListRenderModel {
        ChatSearchResultsListRenderModel(
            generation: generation,
            results: results,
            selectedID: selectedID ?? results.first?.id,
            phase: phase
        )
    }

    private func makeResult(
        id: ChatSearchResult.ID,
        minute: Int,
        snippet: String = "test message",
        avatarURL: String? = nil
    ) -> ChatSearchResult {
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + minute * 60))
        return ChatSearchResult(
            id: id,
            scope: ChatSearchResult.Scope(
                owner: "owner@example.com",
                jid: "andrew@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            ),
            anchor: ChatSearchResult.Anchor(
                primary: stableToken(id),
                archivedId: stableToken(id),
                messageId: "message-\(stableToken(id))",
                authorId: nil,
                date: date
            ),
            outgoing: false,
            senderTitle: "Andrew Nenakhov",
            body: snippet,
            snippet: snippet,
            deliveryState: .delivered,
            avatar: ChatSearchResult.Avatar(
                identity: "contact:owner@example.com|andrew@example.com",
                fallbackTitle: "Andrew Nenakhov",
                url: avatarURL,
                source: .contact(jid: "andrew@example.com", owner: "owner@example.com")
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

private final class ResignTrackingTextField: UITextField {
    private(set) var resignCallCount = 0

    override func resignFirstResponder() -> Bool {
        resignCallCount += 1
        return super.resignFirstResponder()
    }
}
