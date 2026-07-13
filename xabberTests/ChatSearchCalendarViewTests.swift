//
//  ChatSearchCalendarViewTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchCalendarViewTests: XCTestCase {
    func testRootSurfaceUsesReferenceHierarchyAndPublicMaterialFallback() {
        let view = makeView(prefersNativeGlass: false)

        XCTAssertEqual(view.accessibilityIdentifier, "chat_search_calendar")
        XCTAssertIdentical(view.surfaceView.superview, view)
        XCTAssertTrue(view.surfaceView.effect is UIBlurEffect)
        XCTAssertEqual(view.surfaceView.layer.cornerRadius, 24, accuracy: 0.001)
        XCTAssertEqual(
            view.surfaceView.layer.maskedCorners,
            [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        )
        XCTAssertEqual(view.backgroundColor, .clear)
        XCTAssertEqual(view.surfaceView.contentView.backgroundColor, .systemBackground)
    }

    func testHeaderHasCenteredSearchTitleAndDetachedFortyFourPointCloseControl() {
        let view = makeView()

        XCTAssertEqual(view.titleLabel.text, "Search")
        XCTAssertEqual(view.titleLabel.textAlignment, .center)
        XCTAssertEqual(view.closeButton.accessibilityIdentifier, "chat_search_calendar_close")
        XCTAssertEqual(view.closeButton.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(view.closeButton.frame.minX, 16, accuracy: 0.001)
        XCTAssertEqual(view.titleLabel.center.x, view.bounds.midX, accuracy: 0.001)
    }

    func testMonthNavigationAndDisclosureReflectImmutableSnapshot() {
        var model = makeModel(now: makeDate(1970, 1, 2))
        let view = makeView(snapshot: model.snapshot)

        XCTAssertEqual(view.monthButton.accessibilityIdentifier, "chat_search_calendar_month")
        XCTAssertEqual(view.monthButton.title(for: .normal), model.snapshot.monthTitle)
        XCTAssertEqual(view.previousButton.accessibilityIdentifier, "chat_search_calendar_previous_month")
        XCTAssertEqual(view.nextButton.accessibilityIdentifier, "chat_search_calendar_next_month")
        XCTAssertGreaterThanOrEqual(view.previousButton.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(view.nextButton.bounds.height, 44)
        XCTAssertFalse(view.previousButton.isEnabled)
        XCTAssertTrue(view.nextButton.isEnabled)

        XCTAssertTrue(model.navigateMonth(.next))
        view.render(snapshot: model.snapshot, animated: false)
        XCTAssertEqual(view.monthButton.title(for: .normal), model.snapshot.monthTitle)
        XCTAssertTrue(view.previousButton.isEnabled)
    }

    func testWeekdayAndDayGridUsesSevenEqualColumnsAndAtMostFortyTwoStableSlots() throws {
        let view = makeView(width: 390)
        let snapshot = try XCTUnwrap(view.renderedSnapshot)

        XCTAssertEqual(view.weekdayLabels.count, 7)
        XCTAssertEqual(snapshot.daySlots.count, snapshot.rowCount * 7)
        XCTAssertLessThanOrEqual(snapshot.daySlots.count, 42)
        XCTAssertLessThanOrEqual(view.collectionView.bounds.width, 390)

        let layout = try XCTUnwrap(view.collectionView.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.minimumInteritemSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(layout.minimumLineSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(layout.itemSize.width * 7, view.collectionView.bounds.width, accuracy: 0.01)
    }

    func testOutsideMonthDayCellIsBlankNoninteractiveAndAbsentFromAccessibility() throws {
        let hidden = try XCTUnwrap(makeModel(now: makeDate(2026, 7, 13)).snapshot.daySlots.first { !$0.isInVisibleMonth })
        let cell = ChatSearchCalendarDayCell(frame: CGRect(x: 0, y: 0, width: 44, height: 44))

        cell.configure(with: hidden)

        XCTAssertNil(cell.dayLabel.text)
        XCTAssertTrue(cell.selectionCircleView.isHidden)
        XCTAssertFalse(cell.isUserInteractionEnabled)
        XCTAssertFalse(cell.isAccessibilityElement)
        XCTAssertNil(cell.accessibilityIdentifier)
    }

    func testSelectedTodayDisabledAndFutureVisualStatesRemainDistinct() throws {
        let now = makeDate(2026, 7, 13)
        var model = makeModel(now: now)
        let today = try XCTUnwrap(model.snapshot.daySlots.first { $0.isToday })
        let selectedCell = ChatSearchCalendarDayCell(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        selectedCell.configure(with: today)

        XCTAssertFalse(selectedCell.selectionCircleView.isHidden)
        XCTAssertEqual(selectedCell.selectionCircleView.backgroundColor, .systemBlue)
        XCTAssertEqual(selectedCell.dayLabel.textColor, .white)
        XCTAssertTrue(selectedCell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(try XCTUnwrap(selectedCell.accessibilityValue).contains("Today"))

        XCTAssertTrue(model.navigateMonth(.next))
        let future = try XCTUnwrap(model.snapshot.daySlots.first { $0.dayNumber == 20 })
        let futureCell = ChatSearchCalendarDayCell(frame: .zero)
        futureCell.configure(with: future)
        XCTAssertTrue(futureCell.isUserInteractionEnabled)
        XCTAssertFalse(futureCell.accessibilityTraits.contains(.notEnabled))

        let disabled = ChatSearchCalendarModel.DaySlot(
            id: .day(era: 1, year: 1969, month: 12, day: 31),
            date: makeDate(1969, 12, 31),
            dayNumber: 31,
            isInVisibleMonth: true,
            isEnabled: false,
            isInteractive: false,
            isSelected: false,
            isToday: false
        )
        let disabledCell = ChatSearchCalendarDayCell(frame: .zero)
        disabledCell.configure(with: disabled)
        XCTAssertTrue(disabledCell.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(disabledCell.dayLabel.textColor, .tertiaryLabel)
    }

    func testReuseClearsSelectionTodayAndAccessibilityState() throws {
        let snapshot = makeModel(now: makeDate(2026, 7, 13)).snapshot
        let selected = try XCTUnwrap(snapshot.daySlots.first { $0.isSelected })
        let ordinary = try XCTUnwrap(snapshot.daySlots.first { $0.isInteractive && !$0.isSelected && !$0.isToday })
        let cell = ChatSearchCalendarDayCell(frame: .zero)

        cell.configure(with: selected)
        cell.prepareForReuse()
        cell.configure(with: ordinary)

        XCTAssertTrue(cell.selectionCircleView.isHidden)
        XCTAssertEqual(cell.dayLabel.textColor, .label)
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertFalse((cell.accessibilityValue ?? "").contains("Today"))
    }

    func testFourThroughSixRowsProduceDynamicUnclippedSheetFrames() {
        var previousHeight: CGFloat = 0
        for rows in 4...6 {
            let frames = ChatSearchCalendarLayout.frames(
                in: CGRect(x: 0, y: 0, width: 390, height: 844),
                rowCount: rows,
                isMonthYearPickerPresented: false,
                safeAreaInsets: .zero
            )
            XCTAssertEqual(frames.grid.height, CGFloat(rows) * 44, accuracy: 0.001)
            XCTAssertGreaterThan(frames.sheetHeight, previousHeight)
            XCTAssertLessThanOrEqual(frames.done.maxY, frames.sheetHeight)
            XCTAssertLessThanOrEqual(frames.sheetHeight, 844)
            previousHeight = frames.sheetHeight
        }
    }

    func testIPhone16ePortraitLayoutKeepsEveryControlInsideSheet() {
        let view = makeView(width: 390, height: 844)
        let subviews = [
            view.closeButton,
            view.titleLabel,
            view.monthButton,
            view.previousButton,
            view.nextButton,
            view.weekdayContainerView,
            view.collectionView,
            view.doneButton
        ]

        for subview in subviews {
            XCTAssertTrue(view.bounds.contains(subview.frame), "Clipped \(type(of: subview)) at \(subview.frame)")
        }
        XCTAssertEqual(view.doneButton.bounds.height, 52, accuracy: 0.001)
        XCTAssertEqual(view.doneButton.frame.minX, 30, accuracy: 0.001)
        XCTAssertEqual(view.doneButton.frame.maxX, 360, accuracy: 0.001)
    }

    func testMonthYearPickerUsesSeparateControlsAndDeterministicCallbacks() {
        var model = makeModel(now: makeDate(2026, 7, 13))
        model.toggleMonthYearPicker()
        let view = makeView(snapshot: model.snapshot)
        var selected: (Int, Int)?
        var dismissCount = 0
        var applyCount = 0
        view.onSelectMonthYear = { selected = ($0, $1) }
        view.onDismissMonthYearPicker = { dismissCount += 1 }
        view.onApplyMonthYearPicker = { applyCount += 1 }

        XCTAssertFalse(view.monthYearPickerContainerView.isHidden)
        XCTAssertTrue(view.weekdayContainerView.isHidden)
        XCTAssertTrue(view.collectionView.isHidden)
        XCTAssertNotIdentical(view.monthPicker, view.yearPicker)
        XCTAssertEqual(view.monthPicker.selectedRow(inComponent: 0), 6)
        XCTAssertEqual(view.yearPickerYears[view.yearPicker.selectedRow(inComponent: 0)], 2026)

        view.monthPicker.selectRow(11, inComponent: 0, animated: false)
        view.monthPicker.delegate?.pickerView?(view.monthPicker, didSelectRow: 11, inComponent: 0)
        XCTAssertEqual(selected?.0, 12)
        XCTAssertEqual(selected?.1, 2026)

        view.pickerCloseButton.sendActions(for: .touchUpInside)
        view.pickerApplyButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(applyCount, 1)
    }

    func testMonthRenderRecordsReferenceSwipeAndSynchronizesTitleGridAndPicker() throws {
        var model = makeModel(now: makeDate(2026, 7, 13))
        let view = makeView(snapshot: model.snapshot, animationSpec: .production)
        XCTAssertTrue(model.navigateMonth(.next))

        view.render(snapshot: model.snapshot, animated: true, monthDirection: .next)

        let transition = try XCTUnwrap(view.lastMonthTransition)
        XCTAssertEqual(transition.duration, 0.30, accuracy: 0.001)
        XCTAssertEqual(transition.mode, .horizontalSlide)
        XCTAssertEqual(transition.travelDirection, .left)
        XCTAssertEqual(view.monthButton.title(for: .normal), model.snapshot.monthTitle)
        XCTAssertEqual(view.renderedSnapshot, model.snapshot)
        XCTAssertEqual(view.monthPicker.selectedRow(inComponent: 0), model.snapshot.pickerMonth - 1)
    }

    func testReduceMotionAndRTLResolveMonthTransitionSemantically() throws {
        var model = makeModel(now: makeDate(2026, 7, 13))
        let reducedSpec = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let reduced = makeView(snapshot: model.snapshot, animationSpec: reducedSpec)
        XCTAssertTrue(model.navigateMonth(.next))
        reduced.render(snapshot: model.snapshot, animated: true, monthDirection: .next)
        XCTAssertEqual(reduced.lastMonthTransition?.mode, .crossfade)
        XCTAssertEqual(
            try XCTUnwrap(reduced.lastMonthTransition).travelDirection,
            ChatSearchAnimationSpec.HorizontalTravelDirection.none
        )

        var rtlModel = makeModel(now: makeDate(2026, 7, 13))
        let rtl = makeView(snapshot: rtlModel.snapshot, animationSpec: .production)
        rtl.semanticContentAttribute = .forceRightToLeft
        rtl.layoutIfNeeded()
        XCTAssertTrue(rtlModel.navigateMonth(.next))
        rtl.render(snapshot: rtlModel.snapshot, animated: true, monthDirection: .next)
        XCTAssertEqual(try XCTUnwrap(rtl.lastMonthTransition).travelDirection, .right)
        XCTAssertEqual(rtl.collectionView.semanticContentAttribute, .forceRightToLeft)
    }

    func testCallbacksAreSeparateAndDayCallbackUsesStableSlotIdentity() throws {
        let view = makeView()
        var close = 0
        var previous = 0
        var next = 0
        var month = 0
        var done = 0
        var selectedID: ChatSearchCalendarModel.DaySlot.ID?
        view.onClose = { close += 1 }
        view.onPreviousMonth = { previous += 1 }
        view.onNextMonth = { next += 1 }
        view.onToggleMonthYearPicker = { month += 1 }
        view.onDone = { done += 1 }
        view.onSelectDay = { selectedID = $0 }

        view.closeButton.sendActions(for: .touchUpInside)
        view.previousButton.sendActions(for: .touchUpInside)
        view.nextButton.sendActions(for: .touchUpInside)
        view.monthButton.sendActions(for: .touchUpInside)
        view.doneButton.sendActions(for: .touchUpInside)
        let index = try XCTUnwrap(view.renderedSnapshot?.daySlots.firstIndex { $0.isInteractive })
        view.collectionView.delegate?.collectionView?(
            view.collectionView,
            didSelectItemAt: IndexPath(item: index, section: 0)
        )

        XCTAssertEqual(close, 1)
        XCTAssertEqual(previous, view.previousButton.isEnabled ? 1 : 0)
        XCTAssertEqual(next, 1)
        XCTAssertEqual(month, 1)
        XCTAssertEqual(done, 1)
        XCTAssertEqual(selectedID, view.renderedSnapshot?.daySlots[index].id)
    }

    func testSwipeGestureReportsVisualDirectionWithoutOwningModelMutation() {
        let view = makeView()
        var directions: [ChatSearchCalendarModel.VisualSwipeDirection] = []
        view.onSwipeMonth = { directions.append($0) }

        view.handleSwipe(.left)
        view.handleSwipe(.right)

        XCTAssertEqual(directions, [.left, .right])
    }

    func testDynamicTypeAndContrastUseAdaptiveSystemStylesWithoutOverlap() {
        let view = makeView()

        XCTAssertTrue(view.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertTrue(view.monthButton.titleLabel?.adjustsFontForContentSizeCategory == true)
        XCTAssertTrue(view.doneButton.titleLabel?.adjustsFontForContentSizeCategory == true)
        XCTAssertLessThanOrEqual(view.titleLabel.frame.maxY, view.monthButton.frame.minY)
        XCTAssertLessThanOrEqual(view.monthButton.frame.maxY, view.weekdayContainerView.frame.minY)

        let light = UITraitCollection(userInterfaceStyle: .light)
        let darkHighContrast = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(accessibilityContrast: .high)
        ])
        XCTAssertNotEqual(
            ChatSearchCalendarDayCell.Colors.day.resolvedColor(with: light),
            ChatSearchCalendarDayCell.Colors.day.resolvedColor(with: darkHighContrast)
        )
        XCTAssertNotEqual(
            ChatSearchCalendarDayCell.Colors.selectedFill.resolvedColor(with: light),
            ChatSearchCalendarDayCell.Colors.selectedText.resolvedColor(with: light)
        )
    }

    private struct FixedClock: ChatSearchCalendarClock {
        let now: Date
    }

    private func makeView(
        width: CGFloat = 390,
        height: CGFloat? = nil,
        snapshot: ChatSearchCalendarModel.Snapshot? = nil,
        animationSpec: ChatSearchAnimationSpec = .immediate,
        prefersNativeGlass: Bool = false
    ) -> ChatSearchCalendarView {
        let resolvedSnapshot = snapshot ?? makeModel(now: makeDate(2026, 7, 13)).snapshot
        let targetHeight = height ?? ChatSearchCalendarLayout.frames(
            in: CGRect(x: 0, y: 0, width: width, height: 844),
            rowCount: resolvedSnapshot.rowCount,
            isMonthYearPickerPresented: resolvedSnapshot.isMonthYearPickerPresented,
            safeAreaInsets: .zero
        ).sheetHeight
        let view = ChatSearchCalendarView(
            frame: CGRect(x: 0, y: 0, width: width, height: targetHeight),
            snapshot: resolvedSnapshot,
            animationSpec: animationSpec,
            prefersNativeGlass: prefersNativeGlass
        )
        view.layoutIfNeeded()
        return view
    }

    private func makeModel(now: Date) -> ChatSearchCalendarModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return ChatSearchCalendarModel(
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            clock: FixedClock(now: now)
        )
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 10,
            minute: 51
        ))!
    }
}
