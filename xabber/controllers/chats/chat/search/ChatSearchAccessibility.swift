//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation

struct ChatSearchAccessibilityAnnouncementState {
    enum Event: Hashable {
        case noResults
        case searchFailure
        case dateNoMessage
        case dateFailure
        case positioningFailure
    }

    private var lastGenerationByEvent: [Event: Int] = [:]

    mutating func message(
        for event: Event,
        generation: Int,
        localization: ChatSearchLocalization
    ) -> String? {
        guard lastGenerationByEvent[event] != generation else {
            return nil
        }
        lastGenerationByEvent[event] = generation

        switch event {
        case .noResults, .dateNoMessage:
            return localization.text(.announcementNoMessages)
        case .searchFailure, .dateFailure, .positioningFailure:
            return localization.text(.announcementSearchError)
        }
    }
}

enum ChatSearchAccessibilityIdentifier {
    static let entry = "chat_search_entry"
    static let topBar = "chat_search_top_bar"
    static let input = "chat_search_input"
    static let submit = "chat_search_submit"
    static let clear = "chat_search_clear"
    static let cancel = "chat_search_cancel"
    static let loading = "chat_search_loading"

    static let resultsPanel = "chat_search_results_panel"
    static let resultsCount = "chat_search_results_count"
    static let viewModeControl = "chat_search_view_mode_control"
    static let calendarButton = "chat_search_calendar_button"
    static let previousResult = "chat_search_previous_result"
    static let nextResult = "chat_search_next_result"

    static let resultsList = "chat_search_results_list"
    static let resultRow = "chat_search_result_row"
    static let resultsEmpty = "chat_search_results_empty"
    static let resultsError = "chat_search_results_error"
    static let resultsPaging = "chat_search_results_paging"

    static let calendar = "chat_search_calendar"
    static let calendarClose = "chat_search_calendar_close"
    static let calendarMonth = "chat_search_calendar_month"
    static let calendarPreviousMonth = "chat_search_calendar_previous_month"
    static let calendarNextMonth = "chat_search_calendar_next_month"
    static let calendarMonthYearPicker = "chat_search_calendar_month_year_picker"
    static let calendarDay = "chat_search_calendar_day"
    static let calendarDone = "chat_search_calendar_done"

    /// Existing Info Card identifiers remain supported by automation while
    /// `entry` names the cross-screen semantic action.
    static let contactInfoEntry = "contact_info_search_button"
    static let groupInfoEntry = "group_info_search_button"
    static let infoCardEntryIdentifiers = [contactInfoEntry, groupInfoEntry]

    static func resultRow(_ id: ChatSearchResult.ID) -> String {
        switch id {
        case let .archived(value):
            return "\(resultRow).archived.\(value)"
        case let .primary(value):
            return "\(resultRow).primary.\(value)"
        }
    }

    static func calendarDay(_ id: ChatSearchCalendarModel.DaySlot.ID) -> String? {
        switch id {
        case let .day(era, year, month, day):
            return "\(calendarDay).\(era).\(year).\(month).\(day)"
        case .hidden:
            return nil
        }
    }
}
