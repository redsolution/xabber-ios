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

import Foundation

struct ChatSearchPresentationState: Equatable {
    enum SurfaceMode: Equatable {
        case chat
        case list
        case calendar
    }

    enum ResultPhase: Equatable {
        case idle
        case debouncing
        case searching
        case results
        case empty
        case error
    }

    enum PositioningPhase: Equatable {
        case idle
        case positioningResult(index: Int)
        case resolvingDate(Date)
    }

    enum CalendarOrigin: Equatable {
        case chat
        case list
    }

    enum Event: Equatable {
        case activate
        case queryChanged(String)
        case debounceElapsed(generation: Int)
        case resultsReceived(count: Int, generation: Int)
        case emptyReceived(generation: Int)
        case failed(generation: Int)
        case resultCommitted(index: Int, generation: Int)
        case navigationStarted(index: Int, generation: Int)
        case navigationFinished(generation: Int)
        case openList
        case closeList
        case openCalendar
        case cancelCalendar
        case completeCalendarDate(Date)
        case cancelSearch
    }

    struct Visibility: Equatable {
        let top: Bool
        let bottom: Bool
        let arrows: Bool
        let list: Bool
        let calendar: Bool
        let spinner: Bool

        static let hidden = Visibility(
            top: false,
            bottom: false,
            arrows: false,
            list: false,
            calendar: false,
            spinner: false
        )
    }

    static let inactive = ChatSearchPresentationState(
        isActive: false,
        surfaceMode: .chat,
        resultPhase: .idle,
        positioningPhase: .idle,
        calendarOrigin: nil,
        query: "",
        resultCount: 0,
        committedResultIndex: nil,
        generation: 0
    )

    private(set) var isActive: Bool
    private(set) var surfaceMode: SurfaceMode
    private(set) var resultPhase: ResultPhase
    private(set) var positioningPhase: PositioningPhase
    private(set) var calendarOrigin: CalendarOrigin?
    private(set) var query: String
    private(set) var resultCount: Int
    private(set) var committedResultIndex: Int?
    private(set) var generation: Int

    var visibility: Visibility {
        guard isActive else {
            return .hidden
        }

        let hasCommittedResult = committedResultIndex.map(resultIndices.contains) == true
        return Visibility(
            top: true,
            bottom: surfaceMode != .calendar,
            arrows: surfaceMode == .chat &&
                resultPhase == .results &&
                resultCount > 1 &&
                hasCommittedResult,
            list: surfaceMode == .list,
            calendar: surfaceMode == .calendar,
            spinner: resultPhase == .searching || positioningPhase.isPositioning
        )
    }

    var legacyPanelState: ChatSearchLegacyPanelState {
        guard isActive else {
            return .idle
        }

        switch resultPhase {
        case .idle, .debouncing:
            return .idle
        case .searching:
            return .loading
        case .empty, .error:
            return .emptyResults
        case .results:
            return .results(
                current: committedResultIndex ?? -1,
                total: resultCount,
                isLoadingContext: positioningPhase.isPositioning
            )
        }
    }

    mutating func reduce(_ event: Event) {
        switch event {
        case .activate:
            guard !isActive else {
                return
            }
            isActive = true
            surfaceMode = .chat
            resultPhase = .idle
            positioningPhase = .idle
            calendarOrigin = nil
            query = ""
            resultCount = 0
            committedResultIndex = nil

        case .queryChanged(let rawQuery):
            guard isActive,
                  surfaceMode != .calendar else {
                return
            }
            generation &+= 1
            query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            resultPhase = query.isEmpty ? .idle : .debouncing
            positioningPhase = .idle
            resultCount = 0
            committedResultIndex = nil
            if surfaceMode == .list {
                surfaceMode = .chat
            }

        case .debounceElapsed(let eventGeneration):
            guard accepts(eventGeneration),
                  resultPhase == .debouncing else {
                return
            }
            resultPhase = .searching

        case .resultsReceived(let count, let eventGeneration):
            guard accepts(eventGeneration),
                  query.isNotEmpty else {
                return
            }
            resultCount = max(0, count)
            committedResultIndex = nil
            positioningPhase = .idle
            resultPhase = resultCount > 0 ? .results : .empty
            enforceListInvariant()

        case .emptyReceived(let eventGeneration):
            guard accepts(eventGeneration) else {
                return
            }
            resultPhase = .empty
            resultCount = 0
            committedResultIndex = nil
            positioningPhase = .idle
            enforceListInvariant()

        case .failed(let eventGeneration):
            guard accepts(eventGeneration) else {
                return
            }
            resultPhase = .error
            resultCount = 0
            committedResultIndex = nil
            positioningPhase = .idle
            enforceListInvariant()

        case .resultCommitted(let index, let eventGeneration):
            guard accepts(eventGeneration),
                  surfaceMode != .calendar,
                  resultPhase == .results,
                  resultIndices.contains(index) else {
                return
            }
            committedResultIndex = index
            positioningPhase = .idle

        case .navigationStarted(let index, let eventGeneration):
            guard accepts(eventGeneration),
                  surfaceMode != .calendar,
                  resultPhase == .results,
                  resultIndices.contains(index) else {
                return
            }
            positioningPhase = .positioningResult(index: index)

        case .navigationFinished(let eventGeneration):
            guard accepts(eventGeneration),
                  surfaceMode != .calendar else {
                return
            }
            if case .positioningResult = positioningPhase {
                positioningPhase = .idle
            }

        case .openList:
            guard canOpenList,
                  surfaceMode == .chat else {
                return
            }
            surfaceMode = .list

        case .closeList:
            guard surfaceMode == .list else {
                return
            }
            surfaceMode = .chat

        case .openCalendar:
            guard isActive else {
                return
            }
            switch surfaceMode {
            case .chat:
                calendarOrigin = .chat
            case .list:
                calendarOrigin = .list
            case .calendar:
                return
            }
            surfaceMode = .calendar

        case .cancelCalendar:
            guard surfaceMode == .calendar,
                  let calendarOrigin else {
                return
            }
            surfaceMode = calendarOrigin == .list ? .list : .chat
            self.calendarOrigin = nil

        case .completeCalendarDate(let date):
            guard surfaceMode == .calendar else {
                return
            }
            generation &+= 1
            isActive = false
            surfaceMode = .chat
            resultPhase = .idle
            positioningPhase = .resolvingDate(date)
            calendarOrigin = nil
            query = ""
            resultCount = 0
            committedResultIndex = nil

        case .cancelSearch:
            generation &+= 1
            isActive = false
            surfaceMode = .chat
            resultPhase = .idle
            positioningPhase = .idle
            calendarOrigin = nil
            query = ""
            resultCount = 0
            committedResultIndex = nil
        }
    }

    private var resultIndices: Range<Int> {
        0..<resultCount
    }

    private var canOpenList: Bool {
        guard isActive,
              resultPhase == .results,
              let committedResultIndex else {
            return false
        }
        return resultIndices.contains(committedResultIndex)
    }

    private func accepts(_ eventGeneration: Int) -> Bool {
        isActive && eventGeneration == generation
    }

    private mutating func enforceListInvariant() {
        guard surfaceMode == .list,
              !canOpenList else {
            return
        }
        surfaceMode = .chat
    }
}

enum ChatSearchLegacyPanelState: Equatable {
    case idle
    case loading
    case emptyResults
    case results(current: Int, total: Int, isLoadingContext: Bool)
}

private extension ChatSearchPresentationState.PositioningPhase {
    var isPositioning: Bool {
        if case .positioningResult = self {
            return true
        }
        return false
    }
}
