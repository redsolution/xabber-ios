//
//  ChatSearchAccessibilityTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchAccessibilityTests: XCTestCase {
    func testAnnouncementStateLocalizesTerminalEventsAndSuppressesOnlyDuplicateChatter() {
        var state = ChatSearchAccessibilityAnnouncementState()

        XCTAssertEqual(
            state.message(
                for: .noResults,
                generation: 7,
                localization: localization
            ),
            "No messages"
        )
        XCTAssertNil(
            state.message(
                for: .noResults,
                generation: 7,
                localization: localization
            )
        )
        XCTAssertEqual(
            state.message(
                for: .positioningFailure,
                generation: 7,
                localization: localization
            ),
            "Search failed"
        )
        XCTAssertEqual(
            state.message(
                for: .positioningFailure,
                generation: 8,
                localization: localization
            ),
            "Search failed"
        )
        XCTAssertEqual(
            state.message(
                for: .dateNoMessage,
                generation: 8,
                localization: localization
            ),
            "No messages"
        )
    }

    func testControllerAnnouncesEmptyResultsOnlyOnceForCurrentGeneration() {
        let controller = ChatViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.activateSearchModeFromExternalRoute(activateKeyboard: false, animated: false)
        var announcements: [String] = []
        controller.chatSearchAccessibilityAnnouncementHandler = { announcements.append($0) }

        controller.searchMessagesQueue = []
        controller.applySearchResults(emptyList: true)
        controller.applySearchResults(emptyList: true)

        XCTAssertEqual(
            announcements,
            [ChatSearchLocalization.production().text(.announcementNoMessages)]
        )
    }

    func testIdentifierCatalogIsStableUniqueAndKeepsInfoCardEntryAliases() {
        let expected: [(String, String)] = [
            (ChatSearchAccessibilityIdentifier.entry, "chat_search_entry"),
            (ChatSearchAccessibilityIdentifier.topBar, "chat_search_top_bar"),
            (ChatSearchAccessibilityIdentifier.input, "chat_search_input"),
            (ChatSearchAccessibilityIdentifier.submit, "chat_search_submit"),
            (ChatSearchAccessibilityIdentifier.clear, "chat_search_clear"),
            (ChatSearchAccessibilityIdentifier.cancel, "chat_search_cancel"),
            (ChatSearchAccessibilityIdentifier.loading, "chat_search_loading"),
            (ChatSearchAccessibilityIdentifier.resultsPanel, "chat_search_results_panel"),
            (ChatSearchAccessibilityIdentifier.resultsCount, "chat_search_results_count"),
            (ChatSearchAccessibilityIdentifier.viewModeControl, "chat_search_view_mode_control"),
            (ChatSearchAccessibilityIdentifier.calendarButton, "chat_search_calendar_button"),
            (ChatSearchAccessibilityIdentifier.previousResult, "chat_search_previous_result"),
            (ChatSearchAccessibilityIdentifier.nextResult, "chat_search_next_result"),
            (ChatSearchAccessibilityIdentifier.resultsList, "chat_search_results_list"),
            (ChatSearchAccessibilityIdentifier.resultsEmpty, "chat_search_results_empty"),
            (ChatSearchAccessibilityIdentifier.resultsError, "chat_search_results_error"),
            (ChatSearchAccessibilityIdentifier.resultsPaging, "chat_search_results_paging"),
            (ChatSearchAccessibilityIdentifier.calendar, "chat_search_calendar"),
            (ChatSearchAccessibilityIdentifier.calendarClose, "chat_search_calendar_close"),
            (ChatSearchAccessibilityIdentifier.calendarMonth, "chat_search_calendar_month"),
            (ChatSearchAccessibilityIdentifier.calendarPreviousMonth, "chat_search_calendar_previous_month"),
            (ChatSearchAccessibilityIdentifier.calendarNextMonth, "chat_search_calendar_next_month"),
            (ChatSearchAccessibilityIdentifier.calendarMonthYearPicker, "chat_search_calendar_month_year_picker"),
            (ChatSearchAccessibilityIdentifier.calendarDone, "chat_search_calendar_done")
        ]

        expected.forEach { XCTAssertEqual($0.0, $0.1) }
        XCTAssertEqual(Set(expected.map(\.0)).count, expected.count)
        XCTAssertEqual(
            Set(ChatSearchAccessibilityIdentifier.infoCardEntryIdentifiers),
            ["contact_info_search_button", "group_info_search_button"]
        )
        XCTAssertEqual(
            ChatSearchAccessibilityIdentifier.resultRow(.archived("archive-42")),
            "chat_search_result_row.archived.archive-42"
        )
        XCTAssertEqual(
            ChatSearchAccessibilityIdentifier.calendarDay(
                .day(era: 1, year: 2026, month: 7, day: 13)
            ),
            "chat_search_calendar_day.1.2026.7.13"
        )
    }

    func testTopChromeExposesLocalizedControlsValuesAndVisibleOnlyOrder() throws {
        let view = ChatSearchNavigationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60),
            prefersNativeGlass: false,
            localization: localization
        )
        view.render(.init(query: "test", isRemoteSearching: false))

        XCTAssertEqual(view.accessibilityIdentifier, ChatSearchAccessibilityIdentifier.topBar)
        XCTAssertFalse(view.isAccessibilityElement)
        XCTAssertEqual(view.textField.accessibilityValue, "test")
        XCTAssertEqual(
            accessibilityIDs(in: view),
            [
                ChatSearchAccessibilityIdentifier.input,
                ChatSearchAccessibilityIdentifier.submit,
                ChatSearchAccessibilityIdentifier.clear,
                ChatSearchAccessibilityIdentifier.cancel
            ]
        )
        try assertLocalizedButton(view.submitButton)
        try assertLocalizedButton(view.clearButton)
        try assertLocalizedButton(view.cancelButton)
        XCTAssertNil(view.submitButton.accessibilityHint)
        XCTAssertNil(view.clearButton.accessibilityHint)
        XCTAssertTrue(view.loadingIndicator.accessibilityElementsHidden)

        view.render(.init(query: "test", isRemoteSearching: true))

        XCTAssertTrue(view.submitButton.accessibilityElementsHidden)
        XCTAssertFalse(view.loadingIndicator.accessibilityElementsHidden)
        XCTAssertTrue(view.loadingAccessibilityElement.isAccessibilityElement)
        XCTAssertEqual(
            accessibilityIDs(in: view),
            [
                ChatSearchAccessibilityIdentifier.input,
                ChatSearchAccessibilityIdentifier.loading,
                ChatSearchAccessibilityIdentifier.clear,
                ChatSearchAccessibilityIdentifier.cancel
            ]
        )
    }

    func testBottomPanelCounterAndOrderFollowCommittedPositionOnly() throws {
        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 0, y: 0, width: 358, height: 40),
            animationSpec: .immediate,
            localization: localization
        )

        panel.applyRenderState(.loading, surfaceMode: .chat, animated: false)
        XCTAssertNil(panel.counterLabel.accessibilityValue)
        XCTAssertTrue(panel.viewModeButton.accessibilityElementsHidden)

        panel.applyRenderState(
            .results(current: 0, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )

        XCTAssertEqual(panel.accessibilityIdentifier, ChatSearchAccessibilityIdentifier.resultsPanel)
        XCTAssertEqual(panel.calendarButton.accessibilityIdentifier, ChatSearchAccessibilityIdentifier.calendarButton)
        XCTAssertEqual(panel.counterLabel.accessibilityIdentifier, ChatSearchAccessibilityIdentifier.resultsCount)
        XCTAssertEqual(panel.counterLabel.accessibilityValue, "1 of 3")
        XCTAssertEqual(panel.viewModeButton.accessibilityIdentifier, ChatSearchAccessibilityIdentifier.viewModeControl)
        XCTAssertEqual(
            accessibilityIDs(in: panel),
            [
                ChatSearchAccessibilityIdentifier.calendarButton,
                ChatSearchAccessibilityIdentifier.resultsCount,
                ChatSearchAccessibilityIdentifier.viewModeControl
            ]
        )
        try assertLocalizedButton(panel.calendarButton)
        try assertLocalizedButton(panel.viewModeButton)

        panel.applyRenderState(.emptyResults, surfaceMode: .chat, animated: false)
        XCTAssertEqual(panel.counterLabel.accessibilityValue, "No messages")
        XCTAssertTrue(panel.viewModeButton.accessibilityElementsHidden)
    }

    func testFloatingArrowsDescribeOlderNewerBoundariesAndLeaveTreeWhenHidden() throws {
        let view = ChatSearchNavigationButtonsView(
            frame: CGRect(origin: .zero, size: ChatSearchNavigationButtonsLayout.stackSize),
            animationSpec: .immediate,
            localization: localization
        )
        view.render(
            .init(
                isVisible: true,
                isPreviousEnabled: true,
                isNextEnabled: false,
                isBusy: false
            ),
            animated: false
        )

        XCTAssertFalse(view.accessibilityElementsHidden)
        XCTAssertEqual(accessibilityIDs(in: view), [
            ChatSearchAccessibilityIdentifier.previousResult,
            ChatSearchAccessibilityIdentifier.nextResult
        ])
        XCTAssertEqual(view.previousButton.accessibilityLabel, "Previous result")
        XCTAssertEqual(view.previousButton.accessibilityValue, "Older message")
        XCTAssertEqual(view.nextButton.accessibilityLabel, "Next result")
        XCTAssertEqual(view.nextButton.accessibilityValue, "No newer results")
        XCTAssertFalse(view.nextButton.isEnabled)
        try assertLocalizedButton(view.previousButton)
        try assertLocalizedButton(view.nextButton)

        view.render(.hidden, animated: false)

        XCTAssertTrue(view.accessibilityElementsHidden)
        XCTAssertFalse(view.isUserInteractionEnabled)
    }

    func testExpandedAccessibilityFrameTracksMovedAncestorWithoutRelayout() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let container = UIView(frame: CGRect(x: 0, y: 600, width: 390, height: 100))
        let navigationButtons = ChatSearchNavigationButtonsView(
            frame: CGRect(
                x: 334,
                y: 0,
                width: ChatSearchNavigationButtonsLayout.stackSize.width,
                height: ChatSearchNavigationButtonsLayout.stackSize.height
            ),
            animationSpec: .immediate,
            localization: localization
        )
        window.addSubview(container)
        container.addSubview(navigationButtons)
        window.isHidden = false
        navigationButtons.render(
            .init(
                isVisible: true,
                isPreviousEnabled: true,
                isNextEnabled: false,
                isBusy: false
            ),
            animated: false
        )
        navigationButtons.layoutIfNeeded()

        XCTAssertEqual(
            navigationButtons.previousButton.accessibilityFrame.size,
            CGSize(width: 44, height: 44)
        )
        XCTAssertEqual(
            navigationButtons.previousButton.accessibilityFrame.midY,
            620,
            accuracy: 0.5
        )

        container.frame.origin.y = 300

        XCTAssertEqual(
            navigationButtons.previousButton.accessibilityFrame.midY,
            320,
            accuracy: 0.5,
            "The expanded hit frame must remain relative to its moved container instead of caching obsolete screen coordinates."
        )
    }

    func testResultRowUsesAutomationPrefixAndCombinesPlainPresentation() throws {
        let cell = ChatSearchResultCell(
            avatarLoader: AccessibilityAvatarLoader(),
            dateFormatter: ChatSearchResultDateFormatter(
                locale: Locale(identifier: "en_US_POSIX"),
                calendar: calendar,
                timeZone: calendar.timeZone
            ),
            now: { self.date(2026, 7, 13, hour: 16) }
        )
        let result = makeResult()

        cell.configure(with: result)

        XCTAssertEqual(
            cell.accessibilityIdentifier,
            ChatSearchAccessibilityIdentifier.resultRow(result.id)
        )
        XCTAssertEqual(cell.accessibilityHint, "Double tap to jump to this message")
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        ["You", "test message", cell.dateLabel.text, "Delivered"].forEach { component in
            XCTAssertTrue(cell.accessibilityLabel?.contains(component ?? "missing") == true)
        }
        XCTAssertEqual(cell.snippetLabel.text, "test message")
        XCTAssertEqual(cell.snippetLabel.attributedText?.string, "test message")
        var hasBackgroundAttribute = false
        cell.snippetLabel.attributedText?.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: cell.snippetLabel.attributedText?.length ?? 0)
        ) { value, _, stop in
            if value != nil {
                hasBackgroundAttribute = true
                stop.pointee = true
            }
        }
        XCTAssertFalse(hasBackgroundAttribute)
    }

    func testCalendarHasUniqueDayHooksPickerContainerAndSemanticDayState() throws {
        var model = makeCalendarModel()
        let view = makeCalendarView(snapshot: model.snapshot)
        let selected = try XCTUnwrap(model.snapshot.daySlots.first { $0.isSelected })
        let selectedCell = ChatSearchCalendarDayCell(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        selectedCell.configure(
            with: selected,
            localization: localization,
            formatting: formatting
        )

        XCTAssertEqual(view.accessibilityIdentifier, ChatSearchAccessibilityIdentifier.calendar)
        XCTAssertEqual(
            view.monthYearPickerContainerView.accessibilityIdentifier,
            ChatSearchAccessibilityIdentifier.calendarMonthYearPicker
        )
        XCTAssertEqual(view.monthButton.accessibilityValue, model.snapshot.monthTitle)
        XCTAssertEqual(
            selectedCell.accessibilityIdentifier,
            ChatSearchAccessibilityIdentifier.calendarDay(selected.id)
        )
        XCTAssertTrue(selectedCell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(selectedCell.accessibilityValue?.contains("Selected") == true)
        XCTAssertTrue(selectedCell.accessibilityValue?.contains("Today") == true)
        XCTAssertNil(selectedCell.accessibilityHint)
        XCTAssertEqual(
            accessibilityIDs(in: view),
            [
                ChatSearchAccessibilityIdentifier.calendarClose,
                ChatSearchAccessibilityIdentifier.calendarMonth,
                ChatSearchAccessibilityIdentifier.calendarPreviousMonth,
                ChatSearchAccessibilityIdentifier.calendarNextMonth,
                ChatSearchAccessibilityIdentifier.calendarDone
            ]
        )

        let visibleIDs = model.snapshot.daySlots
            .filter(\.isInVisibleMonth)
            .map { ChatSearchAccessibilityIdentifier.calendarDay($0.id) }
        XCTAssertEqual(Set(visibleIDs).count, visibleIDs.count)

        model.toggleMonthYearPicker()
        view.render(snapshot: model.snapshot, animated: false)
        XCTAssertFalse(view.monthYearPickerContainerView.accessibilityElementsHidden)
        XCTAssertTrue(view.collectionView.accessibilityElementsHidden)

        let hidden = try XCTUnwrap(model.snapshot.daySlots.first { !$0.isInVisibleMonth })
        let hiddenCell = ChatSearchCalendarDayCell(frame: .zero)
        hiddenCell.configure(with: hidden, localization: localization, formatting: formatting)
        XCTAssertFalse(hiddenCell.isAccessibilityElement)
        XCTAssertNil(hiddenCell.accessibilityIdentifier)
    }

    func testControllerOrderUsesCurrentSurfaceAndOmitsAnimatedOutRegions() {
        let controller = ChatViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.activateSearchModeFromExternalRoute(activateKeyboard: false, animated: false)

        controller.refreshChatSearchAccessibilityOrder()
        XCTAssertEqual(
            accessibilityObjectIDs(in: controller.view),
            [
                ObjectIdentifier(controller.searchNavigationView),
                ObjectIdentifier(controller.messagesCollectionView),
                ObjectIdentifier(controller.xabberInputView.searchPanel)
            ]
        )

        controller.searchNavigationButtonsView.render(
            .init(
                isVisible: true,
                isPreviousEnabled: true,
                isNextEnabled: true,
                isBusy: false
            ),
            animated: false
        )
        controller.refreshChatSearchAccessibilityOrder()
        XCTAssertEqual(
            accessibilityObjectIDs(in: controller.view),
            [
                ObjectIdentifier(controller.searchNavigationView),
                ObjectIdentifier(controller.messagesCollectionView),
                ObjectIdentifier(controller.searchNavigationButtonsView),
                ObjectIdentifier(controller.xabberInputView.searchPanel)
            ]
        )

        controller.searchNavigationButtonsView.render(.hidden, animated: false)
        controller.refreshChatSearchAccessibilityOrder()
        XCTAssertFalse(accessibilityObjectIDs(in: controller.view).contains(
            ObjectIdentifier(controller.searchNavigationButtonsView)
        ))
    }

    func testCalendarOverlayFocusAndAccessibilityVisibilitySettleWithPresentation() {
        let controller = ChatSearchCalendarViewController(
            model: makeCalendarModel(),
            animationSpec: .immediate,
            prefersNativeGlass: false
        )
        let parent = UIViewController()
        parent.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let returnFocus = UIButton(type: .system)
        parent.view.addSubview(returnFocus)

        controller.install(in: parent, containerView: parent.view)
        controller.present(
            generation: 7,
            animated: false,
            focusReturnView: returnFocus,
            isGenerationCurrent: { $0 == 7 }
        )

        XCTAssertFalse(controller.view.accessibilityElementsHidden)
        XCTAssertFalse(controller.calendarView.accessibilityElementsHidden)
        XCTAssertIdentical(
            controller.lastAccessibilityFocusTarget,
            controller.calendarView.preferredAccessibilityFocusView
        )

        controller.dismiss(
            generation: 7,
            animated: false,
            isGenerationCurrent: { $0 == 7 },
            completion: nil
        )

        XCTAssertTrue(controller.view.accessibilityElementsHidden)
        XCTAssertTrue(controller.calendarView.accessibilityElementsHidden)
        XCTAssertIdentical(controller.lastAccessibilityFocusTarget, returnFocus)
    }

    private var localization: ChatSearchLocalization {
        ChatSearchLocalization(
            locale: Locale(identifier: "en_US_POSIX"),
            lookup: { _, fallback in fallback }
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }

    private var formatting: ChatSearchFormatting {
        ChatSearchFormatting(
            locale: localization.locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    private func makeCalendarModel() -> ChatSearchCalendarModel {
        ChatSearchCalendarModel(
            calendar: calendar,
            locale: localization.locale,
            clock: AccessibilityClock(now: date(2026, 7, 13, hour: 10))
        )
    }

    private func makeCalendarView(
        snapshot: ChatSearchCalendarModel.Snapshot
    ) -> ChatSearchCalendarView {
        let height = ChatSearchCalendarLayout.frames(
            in: CGRect(x: 0, y: 0, width: 390, height: 844),
            rowCount: snapshot.rowCount,
            isMonthYearPickerPresented: snapshot.isMonthYearPickerPresented,
            safeAreaInsets: .zero
        ).sheetHeight
        let view = ChatSearchCalendarView(
            frame: CGRect(x: 0, y: 0, width: 390, height: height),
            snapshot: snapshot,
            animationSpec: .immediate,
            prefersNativeGlass: false,
            localization: localization
        )
        view.layoutIfNeeded()
        return view
    }

    private func makeResult() -> ChatSearchResult {
        ChatSearchResult(
            id: .archived("archive-42"),
            scope: .init(
                owner: "owner@example.com",
                jid: "andrew@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            ),
            anchor: .init(
                primary: "primary-42",
                archivedId: "archive-42",
                messageId: "message-42",
                authorId: nil,
                date: date(2026, 7, 13, hour: 9)
            ),
            outgoing: true,
            senderTitle: "You",
            body: "test message",
            snippet: "test message",
            deliveryState: .delivered,
            avatar: .init(
                identity: "contact:owner@example.com|owner@example.com",
                fallbackTitle: "You",
                url: nil,
                source: .contact(jid: "owner@example.com", owner: "owner@example.com")
            )
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: 51
        ))!
    }

    private func accessibilityIDs(in view: UIView) -> [String] {
        (view.accessibilityElements ?? []).compactMap { element in
            if let view = element as? UIView {
                return view.accessibilityIdentifier
            }
            return (element as? UIAccessibilityElement)?.accessibilityIdentifier
        }
    }

    private func accessibilityObjectIDs(in view: UIView) -> [ObjectIdentifier] {
        (view.accessibilityElements as? [UIView])?.map(ObjectIdentifier.init) ?? []
    }

    private func assertLocalizedButton(
        _ button: UIButton,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(button.isHidden, file: file, line: line)
        XCTAssertFalse(button.accessibilityElementsHidden, file: file, line: line)
        XCTAssertFalse(
            try XCTUnwrap(button.accessibilityLabel, file: file, line: line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            file: file,
            line: line
        )
    }
}

private struct AccessibilityClock: ChatSearchCalendarClock {
    let now: Date
}

private final class AccessibilityAvatarLoader: ChatSearchResultAvatarLoading {
    @discardableResult
    func loadAvatar(
        for avatar: ChatSearchResult.Avatar,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatSearchResultAvatarLoadCancelling? {
        completion(nil)
        return nil
    }
}
