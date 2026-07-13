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

final class ChatSearchPresentationStateTests: XCTestCase {
    func testInactiveStartsOnChatSurfaceWithIdleResults() {
        let state = ChatSearchPresentationState.inactive

        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertEqual(state.resultPhase, .idle)
        XCTAssertEqual(state.positioningPhase, .idle)
        XCTAssertEqual(state.visibility, .hidden)
    }

    func testQueryLifecycleChangesResultPhaseWithoutCreatingScreenModes() {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        let generation = state.generation

        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertEqual(state.resultPhase, .debouncing)

        state.reduce(.debounceElapsed(generation: generation))
        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertEqual(state.resultPhase, .searching)

        state.reduce(.resultsReceived(count: 3, generation: generation))
        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertEqual(state.resultPhase, .results)
    }

    func testSearchCanResolveToEmptyOrErrorWithoutChangingSurfaceMode() {
        var emptyState = activeSearchingState()
        let generation = emptyState.generation
        emptyState.reduce(.emptyReceived(generation: generation))

        XCTAssertEqual(emptyState.surfaceMode, .chat)
        XCTAssertEqual(emptyState.resultPhase, .empty)

        var errorState = activeSearchingState()
        errorState.reduce(.failed(generation: errorState.generation))

        XCTAssertEqual(errorState.surfaceMode, .chat)
        XCTAssertEqual(errorState.resultPhase, .error)
    }

    func testListRequiresCommittedCurrentResultAndPreservesSearchData() {
        var state = activeResultsState(count: 3)
        let generation = state.generation

        state.reduce(.openList)
        XCTAssertEqual(state.surfaceMode, .chat)

        state.reduce(.resultCommitted(index: 1, generation: generation))
        let committedState = state
        state.reduce(.openList)

        XCTAssertEqual(state.surfaceMode, .list)
        XCTAssertEqual(state.query, committedState.query)
        XCTAssertEqual(state.resultCount, committedState.resultCount)
        XCTAssertEqual(state.committedResultIndex, committedState.committedResultIndex)

        state.reduce(.closeList)
        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertEqual(state.query, committedState.query)
        XCTAssertEqual(state.resultCount, committedState.resultCount)
        XCTAssertEqual(state.committedResultIndex, committedState.committedResultIndex)
    }

    func testListCannotOpenForSearchingEmptyOrErrorState() {
        var searching = activeSearchingState()
        searching.reduce(.openList)
        XCTAssertEqual(searching.surfaceMode, .chat)

        searching.reduce(.emptyReceived(generation: searching.generation))
        searching.reduce(.openList)
        XCTAssertEqual(searching.surfaceMode, .chat)

        var failed = activeSearchingState()
        failed.reduce(.failed(generation: failed.generation))
        failed.reduce(.openList)
        XCTAssertEqual(failed.surfaceMode, .chat)
    }

    func testCalendarCancelRestoresChatOriginAndPreservesSearchData() {
        var state = activeResultsState(count: 2, committedIndex: 0)
        let beforeCalendar = state

        state.reduce(.openCalendar)
        XCTAssertEqual(state.surfaceMode, .calendar)
        XCTAssertEqual(state.calendarOrigin, .chat)
        XCTAssertEqual(state.resultPhase, beforeCalendar.resultPhase)

        state.reduce(.cancelCalendar)
        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertNil(state.calendarOrigin)
        XCTAssertEqual(state.query, beforeCalendar.query)
        XCTAssertEqual(state.resultCount, beforeCalendar.resultCount)
        XCTAssertEqual(state.committedResultIndex, beforeCalendar.committedResultIndex)
        XCTAssertEqual(state.resultPhase, beforeCalendar.resultPhase)
    }

    func testCalendarCancelRestoresListOriginAndPreservesSearchData() {
        var state = activeResultsState(count: 2, committedIndex: 1)
        state.reduce(.openList)
        let beforeCalendar = state

        state.reduce(.openCalendar)
        XCTAssertEqual(state.surfaceMode, .calendar)
        XCTAssertEqual(state.calendarOrigin, .list)

        state.reduce(.cancelCalendar)
        XCTAssertEqual(state.surfaceMode, .list)
        XCTAssertNil(state.calendarOrigin)
        XCTAssertEqual(state.query, beforeCalendar.query)
        XCTAssertEqual(state.resultCount, beforeCalendar.resultCount)
        XCTAssertEqual(state.committedResultIndex, beforeCalendar.committedResultIndex)
    }

    func testCompletingCalendarClearsTextSearchAndStartsDateResolution() {
        let date = Date(timeIntervalSince1970: 1_721_234_567)
        var state = activeResultsState(count: 2, committedIndex: 1)
        state.reduce(.openList)
        state.reduce(.openCalendar)

        state.reduce(.completeCalendarDate(date))

        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertEqual(state.resultPhase, .idle)
        XCTAssertEqual(state.positioningPhase, .resolvingDate(date))
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.resultCount, 0)
        XCTAssertNil(state.committedResultIndex)
        XCTAssertNil(state.calendarOrigin)
    }

    func testCancelSearchFromEverySurfaceReturnsInactive() {
        let chat = activeResultsState(count: 2, committedIndex: 0)
        var list = chat
        list.reduce(.openList)
        var calendar = list
        calendar.reduce(.openCalendar)

        for original in [chat, list, calendar] {
            var state = original
            state.reduce(.cancelSearch)

            XCTAssertFalse(state.isActive)
            XCTAssertEqual(state.surfaceMode, .chat)
            XCTAssertEqual(state.resultPhase, .idle)
            XCTAssertEqual(state.positioningPhase, .idle)
            XCTAssertEqual(state.query, "")
            XCTAssertEqual(state.resultCount, 0)
            XCTAssertNil(state.committedResultIndex)
        }
    }

    func testStaleGenerationEventsAreIgnored() {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("first"))
        let staleGeneration = state.generation
        state.reduce(.queryChanged("test"))
        let expected = state

        state.reduce(.resultsReceived(count: 5, generation: staleGeneration))
        state.reduce(.emptyReceived(generation: staleGeneration))
        state.reduce(.failed(generation: staleGeneration))
        state.reduce(.resultCommitted(index: 0, generation: staleGeneration))

        XCTAssertEqual(state, expected)
    }

    func testImpossibleListAndCalendarNavigationTransitionsDoNotChangeState() {
        var noSelection = activeResultsState(count: 2)
        let beforeList = noSelection
        noSelection.reduce(.openList)
        XCTAssertEqual(noSelection, beforeList)

        var calendar = activeResultsState(count: 2, committedIndex: 0)
        calendar.reduce(.openCalendar)
        let beforeNavigation = calendar
        calendar.reduce(.navigationStarted(index: 1, generation: calendar.generation))
        calendar.reduce(.resultCommitted(index: 1, generation: calendar.generation))

        XCTAssertEqual(calendar, beforeNavigation)
    }

    func testDerivedVisibilityIsDeterministicForSearchSurfacesAndSpinnerPhases() {
        var state = ChatSearchPresentationState.inactive
        XCTAssertEqual(state.visibility, .hidden)

        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        XCTAssertEqual(
            state.visibility,
            .init(top: true, bottom: true, arrows: false, list: false, calendar: false, spinner: false)
        )

        state.reduce(.debounceElapsed(generation: state.generation))
        XCTAssertTrue(state.visibility.spinner)

        state.reduce(.resultsReceived(count: 2, generation: state.generation))
        state.reduce(.resultCommitted(index: 0, generation: state.generation))
        XCTAssertTrue(state.visibility.arrows)

        state.reduce(.openList)
        XCTAssertEqual(
            state.visibility,
            .init(top: true, bottom: true, arrows: false, list: true, calendar: false, spinner: false)
        )

        state.reduce(.openCalendar)
        XCTAssertEqual(
            state.visibility,
            .init(top: true, bottom: true, arrows: false, list: false, calendar: true, spinner: false)
        )
    }

    func testLegacyPanelMappingKeepsCurrentRenderContract() {
        var state = activeSearchingState()
        XCTAssertEqual(state.legacyPanelState, .loading)

        state.reduce(.resultsReceived(count: 3, generation: state.generation))
        XCTAssertEqual(state.legacyPanelState, .results(current: -1, total: 3, isLoadingContext: false))

        state.reduce(.resultCommitted(index: 1, generation: state.generation))
        XCTAssertEqual(state.legacyPanelState, .results(current: 1, total: 3, isLoadingContext: false))

        state.reduce(.navigationStarted(index: 2, generation: state.generation))
        XCTAssertEqual(state.legacyPanelState, .results(current: 1, total: 3, isLoadingContext: true))
    }

    private func activeSearchingState() -> ChatSearchPresentationState {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        state.reduce(.debounceElapsed(generation: state.generation))
        return state
    }

    private func activeResultsState(
        count: Int,
        committedIndex: Int? = nil
    ) -> ChatSearchPresentationState {
        var state = activeSearchingState()
        state.reduce(.resultsReceived(count: count, generation: state.generation))
        if let committedIndex {
            state.reduce(.resultCommitted(index: committedIndex, generation: state.generation))
        }
        return state
    }
}
