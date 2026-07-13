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
//

import Foundation

protocol ChatSearchCalendarClock {
    var now: Date { get }
}

struct ChatSearchCalendarSystemClock: ChatSearchCalendarClock {
    var now: Date { Date() }
}

struct ChatSearchCalendarModel: Equatable {
    enum Semantics: Equatable {
        case dateJump
    }

    enum MonthDirection: Equatable {
        case previous
        case next

        fileprivate var calendarOffset: Int {
            switch self {
            case .previous:
                return -1
            case .next:
                return 1
            }
        }
    }

    enum VisualSwipeDirection: Equatable {
        case left
        case right
    }

    enum LayoutDirection: Equatable {
        case leftToRight
        case rightToLeft
    }

    struct MonthTransition: Equatable {
        let monthDirection: MonthDirection
        let visualDirection: VisualSwipeDirection
        let targetMonthStart: Date
    }

    struct DaySlot: Equatable, Identifiable {
        enum ID: Hashable {
            case day(era: Int, year: Int, month: Int, day: Int)
            case hidden(monthStart: TimeInterval, slot: Int)
        }

        let id: ID
        let date: Date?
        let dayNumber: Int?
        let isInVisibleMonth: Bool
        let isEnabled: Bool
        let isInteractive: Bool
        let isSelected: Bool
        let isToday: Bool
    }

    struct Snapshot: Equatable {
        let semantics: Semantics
        let visibleMonthStart: Date
        let selectedDate: Date
        let monthTitle: String
        let weekdaySymbols: [String]
        let daySlots: [DaySlot]
        let rowCount: Int
        let canNavigatePreviousMonth: Bool
        let canNavigateNextMonth: Bool
        let isDoneEnabled: Bool
        let isMonthYearPickerPresented: Bool
        let pickerMonth: Int
        let pickerYear: Int
        let pickerMonthSymbols: [String]
        let pickerYearRange: ClosedRange<Int>
    }

    static let defaultMinimumDate = Date(timeIntervalSince1970: 0)
    static let defaultMaximumDate = Date(
        timeIntervalSince1970: TimeInterval(Int32.max - 1)
    )

    let semantics = Semantics.dateJump
    let minimumDate: Date
    let maximumDate: Date

    private let calendar: Calendar
    private let locale: Locale
    private let today: Date
    private(set) var selectedDate: Date
    private var visibleMonthStart: Date
    private var isMonthYearPickerPresented = false
    private var pickerMonth: Int
    private var pickerYear: Int

    init<Clock: ChatSearchCalendarClock>(
        calendar: Calendar,
        locale: Locale,
        clock: Clock,
        minimumDate: Date = Self.defaultMinimumDate,
        maximumDate: Date = Self.defaultMaximumDate
    ) {
        var resolvedCalendar = calendar
        resolvedCalendar.locale = locale
        self.calendar = resolvedCalendar
        self.locale = locale

        let lowerBound = min(minimumDate, maximumDate)
        let upperBound = max(minimumDate, maximumDate)
        self.minimumDate = lowerBound
        self.maximumDate = upperBound
        today = clock.now
        selectedDate = min(max(clock.now, lowerBound), upperBound)

        let monthStart = Self.startOfMonth(
            containing: selectedDate,
            calendar: resolvedCalendar
        )
        visibleMonthStart = monthStart
        let components = resolvedCalendar.dateComponents(
            [.month, .year],
            from: monthStart
        )
        pickerMonth = components.month ?? 1
        pickerYear = components.year ?? 1970
    }

    var snapshot: Snapshot {
        let slotsAndRows = makeDaySlots()
        return Snapshot(
            semantics: semantics,
            visibleMonthStart: visibleMonthStart,
            selectedDate: selectedDate,
            monthTitle: makeMonthTitle(),
            weekdaySymbols: makeWeekdaySymbols(),
            daySlots: slotsAndRows.slots,
            rowCount: slotsAndRows.rowCount,
            canNavigatePreviousMonth: targetMonth(for: .previous) != nil,
            canNavigateNextMonth: targetMonth(for: .next) != nil,
            isDoneEnabled: isSelectable(selectedDate),
            isMonthYearPickerPresented: isMonthYearPickerPresented,
            pickerMonth: pickerMonth,
            pickerYear: pickerYear,
            pickerMonthSymbols: makePickerMonthSymbols(),
            pickerYearRange: makePickerYearRange()
        )
    }

    var cancelEvent: ChatSearchPresentationState.Event {
        .cancelCalendar
    }

    var completionEvent: ChatSearchPresentationState.Event? {
        guard isSelectable(selectedDate) else {
            return nil
        }
        return .completeCalendarDate(selectedDate)
    }

    mutating func selectDay(id: DaySlot.ID) -> Bool {
        guard let slot = snapshot.daySlots.first(where: { $0.id == id }),
              slot.isInteractive,
              let date = slot.date,
              isSelectable(date) else {
            return false
        }
        selectedDate = date
        return true
    }

    @discardableResult
    mutating func navigateMonth(_ direction: MonthDirection) -> Bool {
        guard let target = targetMonth(for: direction) else {
            return false
        }
        setVisibleMonth(target)
        return true
    }

    func monthTransition(
        for visualDirection: VisualSwipeDirection,
        layoutDirection: LayoutDirection
    ) -> MonthTransition? {
        let monthDirection: MonthDirection
        switch (visualDirection, layoutDirection) {
        case (.left, .leftToRight), (.right, .rightToLeft):
            monthDirection = .next
        case (.right, .leftToRight), (.left, .rightToLeft):
            monthDirection = .previous
        }
        guard let target = targetMonth(for: monthDirection) else {
            return nil
        }
        return MonthTransition(
            monthDirection: monthDirection,
            visualDirection: visualDirection,
            targetMonthStart: target
        )
    }

    mutating func toggleMonthYearPicker() {
        isMonthYearPickerPresented.toggle()
        if isMonthYearPickerPresented {
            synchronizePickerWithVisibleMonth()
        }
    }

    @discardableResult
    mutating func selectMonthYear(month: Int, year: Int) -> Bool {
        guard let monthStart = makeMonthStart(month: month, year: year),
              monthIntersectsRepresentableRange(monthStart) else {
            return false
        }
        pickerMonth = month
        pickerYear = year
        return true
    }

    @discardableResult
    mutating func applyMonthYearPickerSelection() -> Bool {
        guard isMonthYearPickerPresented,
              let monthStart = makeMonthStart(month: pickerMonth, year: pickerYear),
              monthIntersectsRepresentableRange(monthStart) else {
            return false
        }
        setVisibleMonth(monthStart)
        isMonthYearPickerPresented = false
        return true
    }

    mutating func dismissMonthYearPicker() {
        isMonthYearPickerPresented = false
        synchronizePickerWithVisibleMonth()
    }

    private func makeDaySlots() -> (slots: [DaySlot], rowCount: Int) {
        guard let dayRange = calendar.range(
            of: .day,
            in: .month,
            for: visibleMonthStart
        ) else {
            return ([], 0)
        }
        let firstVisibleWeekday = calendar.component(.weekday, from: visibleMonthStart)
        let leadingCount = (
            firstVisibleWeekday - calendar.firstWeekday + 7
        ) % 7
        let occupiedSlotCount = leadingCount + dayRange.count
        let rowCount = min(6, max(4, (occupiedSlotCount + 6) / 7))
        let slotCount = rowCount * 7
        let visibleComponents = calendar.dateComponents(
            [.era, .year, .month],
            from: visibleMonthStart
        )
        let era = visibleComponents.era ?? 1
        let year = visibleComponents.year ?? 1970
        let month = visibleComponents.month ?? 1

        let slots = (0..<slotCount).map { slotIndex -> DaySlot in
            let day = slotIndex - leadingCount + 1
            guard dayRange.contains(day) else {
                return DaySlot(
                    id: .hidden(
                        monthStart: visibleMonthStart.timeIntervalSinceReferenceDate,
                        slot: slotIndex
                    ),
                    date: nil,
                    dayNumber: nil,
                    isInVisibleMonth: false,
                    isEnabled: false,
                    isInteractive: false,
                    isSelected: false,
                    isToday: false
                )
            }

            let date = dateByReplacingSelectedCivilDay(
                era: era,
                year: year,
                month: month,
                day: day
            )
            let isEnabled = date.map(isSelectable) == true
            return DaySlot(
                id: .day(era: era, year: year, month: month, day: day),
                date: date,
                dayNumber: day,
                isInVisibleMonth: true,
                isEnabled: isEnabled,
                isInteractive: isEnabled,
                isSelected: date.map {
                    calendar.isDate($0, inSameDayAs: selectedDate)
                } == true,
                isToday: date.map {
                    calendar.isDate($0, inSameDayAs: today)
                } == true
            )
        }
        return (slots, rowCount)
    }

    private func dateByReplacingSelectedCivilDay(
        era: Int,
        year: Int,
        month: Int,
        day: Int
    ) -> Date? {
        var components = calendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: selectedDate
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.era = era
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            return nil
        }
        let resolved = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: date
        )
        guard resolved.era == era,
              resolved.year == year,
              resolved.month == month,
              resolved.day == day else {
            return nil
        }
        return date
    }

    private func makeMonthTitle() -> String {
        formatting.monthTitle(for: visibleMonthStart)
    }

    private func makePickerMonthSymbols() -> [String] {
        formatting.pickerMonthSymbols()
    }

    private func makePickerYearRange() -> ClosedRange<Int> {
        let minimumYear = calendar.component(.year, from: minimumDate)
        let maximumYear = calendar.component(.year, from: maximumDate)
        return min(minimumYear, maximumYear)...max(minimumYear, maximumYear)
    }

    private func makeWeekdaySymbols() -> [String] {
        formatting.weekdaySymbols()
    }

    private var formatting: ChatSearchFormatting {
        ChatSearchFormatting(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    private func targetMonth(for direction: MonthDirection) -> Date? {
        guard let candidate = calendar.date(
            byAdding: .month,
            value: direction.calendarOffset,
            to: visibleMonthStart
        ) else {
            return nil
        }
        let monthStart = Self.startOfMonth(containing: candidate, calendar: calendar)
        return monthIntersectsRepresentableRange(monthStart) ? monthStart : nil
    }

    private func monthIntersectsRepresentableRange(_ monthStart: Date) -> Bool {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else {
            return false
        }
        return interval.end > minimumDate && interval.start <= maximumDate
    }

    private func makeMonthStart(month: Int, year: Int) -> Date? {
        guard (1...12).contains(month) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        return components.date.map {
            Self.startOfMonth(containing: $0, calendar: calendar)
        }
    }

    private mutating func setVisibleMonth(_ monthStart: Date) {
        visibleMonthStart = Self.startOfMonth(
            containing: monthStart,
            calendar: calendar
        )
        synchronizePickerWithVisibleMonth()
    }

    private mutating func synchronizePickerWithVisibleMonth() {
        let components = calendar.dateComponents(
            [.month, .year],
            from: visibleMonthStart
        )
        pickerMonth = components.month ?? pickerMonth
        pickerYear = components.year ?? pickerYear
    }

    private func isSelectable(_ date: Date) -> Bool {
        date >= minimumDate && date <= maximumDate
    }

    private static func startOfMonth(
        containing date: Date,
        calendar: Calendar
    ) -> Date {
        if let interval = calendar.dateInterval(of: .month, for: date) {
            return interval.start
        }
        var components = calendar.dateComponents([.era, .year, .month], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.day = 1
        components.hour = 0
        return calendar.date(from: components) ?? date
    }
}
