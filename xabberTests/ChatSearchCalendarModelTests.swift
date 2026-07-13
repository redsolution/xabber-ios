//
//  ChatSearchCalendarModelTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
@testable import xabber

final class ChatSearchCalendarModelTests: XCTestCase {
    func testInitialSnapshotUsesInjectedNowAndDateJumpSemantics() throws {
        let now = makeDate(2026, 7, 13, 10, 51, timeZone: yekaterinburg)
        let model = makeModel(now: now)

        XCTAssertEqual(model.semantics, .dateJump)
        XCTAssertEqual(model.selectedDate, now)
        XCTAssertEqual(model.snapshot.selectedDate, now)
        XCTAssertEqual(
            dateComponents(model.snapshot.visibleMonthStart, timeZone: yekaterinburg),
            DateComponents(year: 2026, month: 7, day: 1)
        )
        let selected = try XCTUnwrap(model.snapshot.daySlots.first(where: { $0.isSelected }))
        XCTAssertEqual(selected.dayNumber, 13)
        XCTAssertTrue(selected.isToday)
        XCTAssertTrue(model.snapshot.isDoneEnabled)
    }

    func testSelectingCivilDayPreservesWallClockComponentsAndDoesNotMutateSearchState() throws {
        let now = makeDate(2026, 7, 13, 10, 51, 27, timeZone: yekaterinburg)
        var model = makeModel(now: now)
        var presentation = activeCalendarPresentation()
        let query = presentation.query
        let target = try XCTUnwrap(model.snapshot.daySlots.first(where: { $0.dayNumber == 21 }))

        XCTAssertTrue(model.selectDay(id: target.id))

        let components = calendar(timeZone: yekaterinburg).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: model.selectedDate
        )
        XCTAssertEqual(components, DateComponents(year: 2026, month: 7, day: 21, hour: 10, minute: 51, second: 27))
        XCTAssertEqual(presentation.query, query)
        XCTAssertEqual(presentation.surfaceMode, .calendar)
    }

    func testSnapshotUsesOnlyOccupiedWeeksAndHidesOutsideMonthSlots() {
        let fourRows = makeModel(now: makeDate(2026, 2, 12, 10, 51, timeZone: yekaterinburg))
        let fiveRows = makeModel(now: makeDate(2026, 7, 13, 10, 51, timeZone: yekaterinburg))
        let sixRows = makeModel(now: makeDate(2026, 8, 13, 10, 51, timeZone: yekaterinburg))

        XCTAssertEqual(fourRows.snapshot.rowCount, 4)
        XCTAssertEqual(fourRows.snapshot.daySlots.count, 28)
        XCTAssertEqual(fiveRows.snapshot.rowCount, 5)
        XCTAssertEqual(fiveRows.snapshot.daySlots.count, 35)
        XCTAssertEqual(sixRows.snapshot.rowCount, 6)
        XCTAssertEqual(sixRows.snapshot.daySlots.count, 42)

        let outside = sixRows.snapshot.daySlots.filter { !$0.isInVisibleMonth }
        XCTAssertFalse(outside.isEmpty)
        XCTAssertTrue(outside.allSatisfy { $0.dayNumber == nil && !$0.isEnabled && !$0.isInteractive })
    }

    func testWeekdayOrderUsesInjectedSundayOrMondayFirstWeekday() {
        let now = makeDate(2026, 7, 13, 10, 51, timeZone: utc)
        var sundayCalendar = calendar(timeZone: utc)
        sundayCalendar.firstWeekday = 1
        var mondayCalendar = calendar(timeZone: utc)
        mondayCalendar.firstWeekday = 2

        let sunday = ChatSearchCalendarModel(
            calendar: sundayCalendar,
            locale: Locale(identifier: "en_US_POSIX"),
            clock: FixedClock(now: now)
        )
        let monday = ChatSearchCalendarModel(
            calendar: mondayCalendar,
            locale: Locale(identifier: "en_US_POSIX"),
            clock: FixedClock(now: now)
        )

        XCTAssertEqual(sunday.snapshot.weekdaySymbols.first, "Sun")
        XCTAssertEqual(monday.snapshot.weekdaySymbols.first, "Mon")
        XCTAssertEqual(Set(sunday.snapshot.weekdaySymbols), Set(monday.snapshot.weekdaySymbols))
    }

    func testFebruaryLeapAndNonLeapDayCounts() {
        let leap = makeModel(now: makeDate(2024, 2, 10, 10, 51, timeZone: utc), timeZone: utc)
        let nonLeap = makeModel(now: makeDate(2023, 2, 10, 10, 51, timeZone: utc), timeZone: utc)

        XCTAssertEqual(leap.snapshot.daySlots.filter(\.isInVisibleMonth).count, 29)
        XCTAssertEqual(nonLeap.snapshot.daySlots.filter(\.isInVisibleMonth).count, 28)
        XCTAssertNotNil(leap.snapshot.daySlots.first(where: { $0.dayNumber == 29 }))
        XCTAssertNil(nonLeap.snapshot.daySlots.first(where: { $0.dayNumber == 29 }))
    }

    func testMonthNavigationCrossesDecemberAndJanuary() {
        var model = makeModel(now: makeDate(2026, 12, 15, 10, 51, timeZone: utc), timeZone: utc)

        XCTAssertTrue(model.navigateMonth(.next))
        XCTAssertEqual(dateComponents(model.snapshot.visibleMonthStart), DateComponents(year: 2027, month: 1, day: 1))
        XCTAssertTrue(model.navigateMonth(.previous))
        XCTAssertEqual(dateComponents(model.snapshot.visibleMonthStart), DateComponents(year: 2026, month: 12, day: 1))
    }

    func testDSTSpringAndFallCivilDayReplacementUsesCalendarArithmetic() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let springStart = makeDate(2026, 3, 7, 10, 51, timeZone: zone)
        var spring = makeModel(now: springStart, timeZone: zone)
        let springTarget = try XCTUnwrap(spring.snapshot.daySlots.first(where: { $0.dayNumber == 9 }))
        XCTAssertTrue(spring.selectDay(id: springTarget.id))
        XCTAssertEqual(spring.selectedDate.timeIntervalSince(springStart), 47 * 60 * 60, accuracy: 0.1)
        XCTAssertEqual(calendar(timeZone: zone).component(.hour, from: spring.selectedDate), 10)

        let fallStart = makeDate(2026, 10, 31, 10, 51, timeZone: zone)
        var fall = makeModel(now: fallStart, timeZone: zone)
        XCTAssertTrue(fall.navigateMonth(.next))
        let fallTarget = try XCTUnwrap(fall.snapshot.daySlots.first(where: { $0.dayNumber == 2 }))
        XCTAssertTrue(fall.selectDay(id: fallTarget.id))
        XCTAssertEqual(fall.selectedDate.timeIntervalSince(fallStart), 49 * 60 * 60, accuracy: 0.1)
        XCTAssertEqual(calendar(timeZone: zone).component(.hour, from: fall.selectedDate), 10)
    }

    func testDefaultRepresentableRangeAndBoundaryMonthNavigation() {
        XCTAssertEqual(ChatSearchCalendarModel.defaultMinimumDate, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            ChatSearchCalendarModel.defaultMaximumDate,
            Date(timeIntervalSince1970: TimeInterval(Int32.max - 1))
        )

        let minimum = makeModel(now: makeDate(1970, 1, 2, 1, 0, timeZone: utc), timeZone: utc)
        XCTAssertFalse(minimum.snapshot.canNavigatePreviousMonth)
        XCTAssertTrue(minimum.snapshot.canNavigateNextMonth)

        var beforeMaximum = makeModel(now: makeDate(2037, 12, 15, 1, 0, timeZone: utc), timeZone: utc)
        XCTAssertTrue(beforeMaximum.snapshot.canNavigateNextMonth)
        XCTAssertTrue(beforeMaximum.navigateMonth(.next))
        XCTAssertEqual(dateComponents(beforeMaximum.snapshot.visibleMonthStart), DateComponents(year: 2038, month: 1, day: 1))
        XCTAssertFalse(beforeMaximum.snapshot.canNavigateNextMonth)
        XCTAssertTrue(beforeMaximum.snapshot.canNavigatePreviousMonth)
    }

    func testFutureMonthsAndDaysRemainEnabledInsideRepresentableRange() throws {
        var model = makeModel(now: makeDate(2026, 7, 13, 10, 51, timeZone: utc), timeZone: utc)

        XCTAssertTrue(model.navigateMonth(.next))
        let future = try XCTUnwrap(model.snapshot.daySlots.first(where: { $0.dayNumber == 20 }))
        XCTAssertTrue(future.isEnabled)
        XCTAssertTrue(future.isInteractive)
        XCTAssertTrue(model.selectDay(id: future.id))
        XCTAssertEqual(dateComponents(model.selectedDate), DateComponents(year: 2026, month: 8, day: 20))
    }

    func testDoneRequiresValidSelectionAndEventsKeepCancelAndCompletionDistinct() throws {
        let now = makeDate(2026, 7, 13, 10, 51, timeZone: utc)
        let model = makeModel(now: now, timeZone: utc)
        let completion = try XCTUnwrap(model.completionEvent)

        XCTAssertEqual(model.cancelEvent, .cancelCalendar)
        XCTAssertEqual(completion, .completeCalendarDate(now))
        XCTAssertNotEqual(model.cancelEvent, completion)

        var cancelState = activeCalendarPresentation()
        let cancelQuery = cancelState.query
        cancelState.reduce(model.cancelEvent)
        XCTAssertTrue(cancelState.isActive)
        XCTAssertEqual(cancelState.query, cancelQuery)
        XCTAssertEqual(cancelState.surfaceMode, .chat)

        var doneState = activeCalendarPresentation()
        doneState.reduce(completion)
        XCTAssertFalse(doneState.isActive)
        XCTAssertEqual(doneState.query, "")
        XCTAssertEqual(doneState.positioningPhase, .resolvingDate(now))
    }

    func testMonthTitleUsesInjectedLocale() {
        let now = makeDate(2026, 7, 13, 10, 51, timeZone: utc)
        let model = ChatSearchCalendarModel(
            calendar: calendar(timeZone: utc),
            locale: Locale(identifier: "fr_FR"),
            clock: FixedClock(now: now)
        )

        XCTAssertEqual(model.snapshot.monthTitle, "juillet 2026")
    }

    func testMonthYearPickerDisclosureSynchronizesAndAppliesSelection() {
        var model = makeModel(now: makeDate(2026, 7, 13, 10, 51, timeZone: utc), timeZone: utc)

        model.toggleMonthYearPicker()
        XCTAssertTrue(model.snapshot.isMonthYearPickerPresented)
        XCTAssertEqual(model.snapshot.pickerMonth, 7)
        XCTAssertEqual(model.snapshot.pickerYear, 2026)

        XCTAssertTrue(model.selectMonthYear(month: 12, year: 2027))
        XCTAssertEqual(model.snapshot.pickerMonth, 12)
        XCTAssertEqual(model.snapshot.pickerYear, 2027)
        XCTAssertTrue(model.applyMonthYearPickerSelection())
        XCTAssertFalse(model.snapshot.isMonthYearPickerPresented)
        XCTAssertEqual(dateComponents(model.snapshot.visibleMonthStart), DateComponents(year: 2027, month: 12, day: 1))
    }

    func testSwipePlanIsSemanticAndRTLVisualDirectionAware() {
        let model = makeModel(now: makeDate(2026, 7, 13, 10, 51, timeZone: utc), timeZone: utc)

        let ltrLeft = model.monthTransition(for: .left, layoutDirection: .leftToRight)
        XCTAssertEqual(ltrLeft?.monthDirection, .next)
        XCTAssertEqual(ltrLeft?.visualDirection, .left)
        let rtlLeft = model.monthTransition(for: .left, layoutDirection: .rightToLeft)
        XCTAssertEqual(rtlLeft?.monthDirection, .previous)
        XCTAssertEqual(rtlLeft?.visualDirection, .left)
        let rtlRight = model.monthTransition(for: .right, layoutDirection: .rightToLeft)
        XCTAssertEqual(rtlRight?.monthDirection, .next)
        XCTAssertEqual(rtlRight?.visualDirection, .right)
    }

    func testReplacingDayNeverNormalizesSelectedTimeToMidnight() throws {
        let now = makeDate(2026, 7, 13, 10, 51, timeZone: yekaterinburg)
        var model = makeModel(now: now)
        let target = try XCTUnwrap(model.snapshot.daySlots.first(where: { $0.dayNumber == 14 }))

        XCTAssertTrue(model.selectDay(id: target.id))

        let components = calendar(timeZone: yekaterinburg).dateComponents(
            [.day, .hour, .minute],
            from: model.selectedDate
        )
        XCTAssertEqual(components, DateComponents(day: 14, hour: 10, minute: 51))
        XCTAssertNotEqual(calendar(timeZone: yekaterinburg).startOfDay(for: model.selectedDate), model.selectedDate)
    }

    func testSnapshotsAreDeterministicAndEquatable() {
        let now = makeDate(2026, 7, 13, 10, 51, timeZone: utc)
        let first = makeModel(now: now, timeZone: utc)
        let second = makeModel(now: now, timeZone: utc)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshot, second.snapshot)
    }

    private struct FixedClock: ChatSearchCalendarClock {
        let now: Date
    }

    private var utc: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    private var yekaterinburg: TimeZone {
        TimeZone(identifier: "Asia/Yekaterinburg")!
    }

    private func makeModel(
        now: Date,
        timeZone: TimeZone? = nil
    ) -> ChatSearchCalendarModel {
        let resolvedTimeZone = timeZone ?? yekaterinburg
        return ChatSearchCalendarModel(
            calendar: calendar(timeZone: resolvedTimeZone),
            locale: Locale(identifier: "en_US_POSIX"),
            clock: FixedClock(now: now)
        )
    }

    private func calendar(timeZone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = timeZone
        value.firstWeekday = 1
        return value
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int = 0,
        timeZone: TimeZone
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar(timeZone: timeZone)
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }

    private func dateComponents(
        _ date: Date,
        timeZone: TimeZone? = nil
    ) -> DateComponents {
        calendar(timeZone: timeZone ?? utc).dateComponents([.year, .month, .day], from: date)
    }

    private func activeCalendarPresentation() -> ChatSearchPresentationState {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        state.reduce(.resultsReceived(count: 1, generation: state.generation))
        state.reduce(.resultCommitted(index: 0, generation: state.generation))
        state.reduce(.openCalendar)
        return state
    }
}
