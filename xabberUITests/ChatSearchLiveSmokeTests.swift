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

import XCTest

final class ChatSearchLiveSmokeTests: XCTestCase {
    private enum AccessibilityID {
        static let semanticSearchEntry = "chat_search_entry"
        static let chatAvatar = "chat_navigation_avatar_button"
        static let contactInfoSearchEntry = "contact_info_search_button"
        static let groupInfoSearchEntry = "group_info_search_button"
        static let signedInSidebar = "chats_sidebar_menu_button"
        static let signedInFilter = "last_chats_filter_button"

        static let input = "chat_search_input"
        static let submit = "chat_search_submit"
        static let clear = "chat_search_clear"
        static let cancel = "chat_search_cancel"
        static let loading = "chat_search_loading"
        static let resultsCount = "chat_search_results_count"
        static let viewMode = "chat_search_view_mode_control"
        static let calendarButton = "chat_search_calendar_button"
        static let previous = "chat_search_previous_result"
        static let next = "chat_search_next_result"
        static let resultsList = "chat_search_results_list"
        static let resultRowPrefix = "chat_search_result_row."
        static let resultsEmpty = "chat_search_results_empty"
        static let resultsError = "chat_search_results_error"
        static let resultsPaging = "chat_search_results_paging"
        static let calendar = "chat_search_calendar"
        static let calendarClose = "chat_search_calendar_close"
        static let calendarMonth = "chat_search_calendar_month"
        static let calendarPreviousMonth = "chat_search_calendar_previous_month"
        static let calendarNextMonth = "chat_search_calendar_next_month"
        static let calendarMonthYearPicker = "chat_search_calendar_month_year_picker"
        static let calendarDayPrefix = "chat_search_calendar_day."
        static let calendarDone = "chat_search_calendar_done"
    }

    private enum TerminalOutcome: Equatable {
        case results(ChatSearchLiveQACountParser.Position)
        case empty
        case error(String)
    }

    private struct LiveQAError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testTelegramStyleInChatSearchLiveSmoke() throws {
        // The authorization gate must remain the first executable statement.
        let authorization = try ChatSearchLiveQASafetyGate.requireAuthorization()
        executionTimeAllowance = ChatSearchLiveQATimeoutPolicy.globalBudget

        let app = XCUIApplication()
        let startedAt = Date()
        app.launch()
        addTeardownBlock {
            // Process termination is the only unconditional teardown action.
            if app.state != .notRunning {
                app.terminate()
            }
        }

        do {
            try assertGlobalBudget(startedAt: startedAt, stage: "launch")
            try waitForSignedInShell(in: app)

            var selectedDialog: String?
            var terminalOutcome: TerminalOutcome?

            for candidate in authorization.dialogCandidates {
                try assertGlobalBudget(startedAt: startedAt, stage: "dialog-\(candidate)")
                guard try openDialog(named: candidate, in: app) else {
                    continue
                }
                selectedDialog = candidate

                try openInChatSearch(in: app)
                try enterExactQuery(authorization.query, in: app)
                let outcome = try waitForTerminalOutcome(in: app)

                switch outcome {
                case .empty:
                    try closeSearchAndReturnToChats(in: app)
                    selectedDialog = nil
                    continue
                case .error(let reason):
                    throw LiveQAError(
                        message: "Live search returned a typed error in \(candidate): \(reason)"
                    )
                case .results:
                    terminalOutcome = outcome
                }
                break
            }

            guard let selectedDialog,
                  case .results(let initialPosition) = terminalOutcome else {
                throw LiveQAError(
                    message: "Neither Andrew Nenakhov nor Alexey Boldin produced results for exact query test."
                )
            }

            XCTAssertEqual(initialPosition.current, 1)
            attachScreenshot(named: "01-chat", app: app)
            try verifyDeterministicNavigationBranch(
                initialPosition: initialPosition,
                in: app
            )

            var committedPosition = try requirePosition(in: app)
            try openAndVerifyNewestFirstList(
                expectedTotal: committedPosition.total,
                query: authorization.query,
                in: app
            )
            attachScreenshot(named: "02-list", app: app)

            if committedPosition.total > 1 {
                committedPosition = try reachOldestBoundaryFromList(
                    initialTotal: committedPosition.total,
                    query: authorization.query,
                    in: app
                )
                try openAndVerifyNewestFirstList(
                    expectedTotal: committedPosition.total,
                    query: authorization.query,
                    in: app
                )
            }

            try verifyInteractiveKeyboardContract(in: app)
            committedPosition = try requirePosition(in: app)
            try verifyCalendarAndRestore(
                expectedPosition: committedPosition,
                query: authorization.query,
                in: app
            )

            try closeSearch(in: app)
            try wait(
                description: "chat remains open after search cancellation",
                timeout: ChatSearchLiveQATimeoutPolicy.finalSignedInShell,
                app: app
            ) {
                self.element(AccessibilityID.chatAvatar, in: app).exists
                    && !self.hasLoginOrOnboarding(in: app)
            }
            XCTAssertTrue(app.staticTexts[selectedDialog].firstMatch.exists)
            attachScreenshot(named: "04-restored", app: app)
            try assertGlobalBudget(startedAt: startedAt, stage: "finished")
        } catch {
            attachDiagnostics(named: "live-smoke-failure", app: app)
            XCTFail(error.localizedDescription)
        }
    }

    func testCalendarDateJumpForKnownResult() throws {
        // Separate opt-in is evaluated before XCUIApplication exists. Task 24
        // only compiles this controlled scenario; Task 26B performs the run.
        let authorization = try ChatSearchLiveQASafetyGate.requireDateJumpAuthorization()
        executionTimeAllowance = ChatSearchLiveQATimeoutPolicy.globalBudget
        try executeControlledCalendarDateJump(
            authorization: authorization
        )
    }

    private func executeControlledCalendarDateJump(
        authorization: ChatSearchLiveQASafetyGate.Authorization
    ) throws {
        let app = XCUIApplication()
        let startedAt = Date()
        app.launch()
        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        do {
            try assertGlobalBudget(startedAt: startedAt, stage: "date-jump-launch")
            try waitForSignedInShell(in: app)

            var selectedDialog: String?
            var initialPosition: ChatSearchLiveQACountParser.Position?

            for candidate in authorization.dialogCandidates {
                try assertGlobalBudget(startedAt: startedAt, stage: "date-jump-dialog-\(candidate)")
                guard try openDialog(named: candidate, in: app) else {
                    continue
                }

                try openInChatSearch(in: app)
                try enterExactQuery(authorization.query, in: app)

                switch try waitForTerminalOutcome(in: app) {
                case .empty:
                    try closeSearchAndReturnToChats(in: app)
                    continue
                case .error(let reason):
                    throw LiveQAError(
                        message: "Live date-jump search returned a typed error in \(candidate): \(reason)"
                    )
                case .results(let position):
                    selectedDialog = candidate
                    initialPosition = position
                }
                break
            }

            guard let selectedDialog, let initialPosition else {
                throw LiveQAError(
                    message: "Neither Andrew Nenakhov nor Alexey Boldin produced a known result for exact query test."
                )
            }
            XCTAssertEqual(initialPosition.current, 1)
            XCTAssertEqual(
                stringValue(of: element(AccessibilityID.input, in: app)),
                authorization.query
            )

            let calendarButton = element(AccessibilityID.calendarButton, in: app)
            guard calendarButton.waitForExistence(
                timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition
            ), calendarButton.isHittable else {
                throw LiveQAError(message: "Calendar entry is unavailable for controlled date-jump QA.")
            }
            calendarButton.tap()

            let calendar = element(AccessibilityID.calendar, in: app)
            try wait(
                description: "controlled date-jump calendar presentation",
                timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
                app: app
            ) {
                calendar.exists && !app.keyboards.firstMatch.exists
            }

            let selectedDays = calendarDays(in: app).filter(\.isSelected)
            guard selectedDays.count == 1, let selectedDay = selectedDays.first else {
                throw LiveQAError(
                    message: "Expected exactly one calendar day selected from the current known result; got \(selectedDays.count)."
                )
            }
            let selectedDayIdentifier = selectedDay.identifier
            let selectedDayLabel = selectedDay.label
            XCTAssertTrue(selectedDayIdentifier.hasPrefix(AccessibilityID.calendarDayPrefix))
            XCTAssertFalse(selectedDayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let done = element(AccessibilityID.calendarDone, in: app)
            guard done.exists, done.isEnabled, done.isHittable else {
                throw LiveQAError(message: "Calendar Done is not enabled and hittable for the selected day.")
            }
            attachScreenshot(named: "05-date-jump-calendar", app: app)
            done.tap()

            try wait(
                description: "calendar Done closes search and restores the signed-in chat",
                timeout: ChatSearchLiveQATimeoutPolicy.terminalResults,
                app: app
            ) {
                !calendar.exists
                    && !self.element(AccessibilityID.input, in: app).exists
                    && !self.element(AccessibilityID.resultsCount, in: app).exists
                    && !self.isAnySearchLoading(in: app)
                    && self.element(AccessibilityID.chatAvatar, in: app).exists
                    && !self.hasLoginOrOnboarding(in: app)
            }
            XCTAssertTrue(app.staticTexts[selectedDialog].firstMatch.exists)
            attachScreenshot(named: "06-date-jump-restored", app: app)

            let evidence = XCTAttachment(
                string: [
                    "dialog=\(selectedDialog)",
                    "query=\(authorization.query)",
                    "initialPosition=\(initialPosition.current) of \(initialPosition.total)",
                    "selectedDayIdentifier=\(selectedDayIdentifier)",
                    "selectedDayLabel=\(selectedDayLabel)",
                    "searchClosed=true",
                    "signedInChatPreserved=true"
                ].joined(separator: "\n")
            )
            evidence.name = "controlled-calendar-date-jump-evidence"
            evidence.lifetime = .keepAlways
            add(evidence)
            try assertGlobalBudget(startedAt: startedAt, stage: "date-jump-finished")
        } catch {
            attachDiagnostics(named: "calendar-date-jump-failure", app: app)
            XCTFail(error.localizedDescription)
        }
    }

    // MARK: - Signed-in shell and chat routing

    private func waitForSignedInShell(in app: XCUIApplication) throws {
        try wait(
            description: "signed-in Xabber shell",
            timeout: ChatSearchLiveQATimeoutPolicy.appShell,
            app: app
        ) {
            self.hasSignedInShell(in: app) || self.hasLoginOrOnboarding(in: app)
        }
        guard !hasLoginOrOnboarding(in: app) else {
            throw LiveQAError(
                message: "Login/onboarding is visible. Live QA will not enter or change credentials."
            )
        }
        guard hasSignedInShell(in: app) else {
            throw LiveQAError(message: "The existing signed-in Xabber shell was not found.")
        }
    }

    private func hasSignedInShell(in app: XCUIApplication) -> Bool {
        element(AccessibilityID.signedInSidebar, in: app).exists
            || element(AccessibilityID.signedInFilter, in: app).exists
            || element(AccessibilityID.chatAvatar, in: app).exists
            || ChatSearchLiveQASafetyPolicy.dialogCandidates.contains {
                app.staticTexts[$0].firstMatch.exists
            }
    }

    private func hasLoginOrOnboarding(in app: XCUIApplication) -> Bool {
        [
            "Connect existing account",
            "Create new account",
            "Sign In"
        ].contains { app.buttons[$0].firstMatch.exists || app.staticTexts[$0].firstMatch.exists }
    }

    private func openDialog(named candidate: String, in app: XCUIApplication) throws -> Bool {
        if element(AccessibilityID.chatAvatar, in: app).exists,
           app.staticTexts[candidate].firstMatch.exists {
            return true
        }

        let candidateLabel = app.staticTexts[candidate].firstMatch
        guard candidateLabel.waitForExistence(
            timeout: ChatSearchLiveQATimeoutPolicy.dialogLookupPerCandidate
        ) else {
            return false
        }
        guard candidateLabel.isHittable else {
            return false
        }
        candidateLabel.tap()

        try wait(
            description: "chat for \(candidate)",
            timeout: ChatSearchLiveQATimeoutPolicy.searchEntry,
            app: app
        ) {
            self.element(AccessibilityID.chatAvatar, in: app).exists
                && app.staticTexts[candidate].firstMatch.exists
        }
        guard !hasLoginOrOnboarding(in: app) else {
            throw LiveQAError(message: "Opening \(candidate) unexpectedly exposed login/onboarding.")
        }
        return true
    }

    private func openInChatSearch(in app: XCUIApplication) throws {
        let semanticEntry = element(AccessibilityID.semanticSearchEntry, in: app)
        if semanticEntry.exists, semanticEntry.isHittable {
            semanticEntry.tap()
        } else {
            let avatar = element(AccessibilityID.chatAvatar, in: app)
            guard avatar.waitForExistence(timeout: ChatSearchLiveQATimeoutPolicy.searchEntry),
                  avatar.isHittable else {
                throw LiveQAError(message: "Neither chat_search_entry nor the stable Chat Info route exists.")
            }
            avatar.tap()

            try wait(
                description: "Info Card search entry",
                timeout: ChatSearchLiveQATimeoutPolicy.searchEntry,
                app: app
            ) {
                self.element(AccessibilityID.contactInfoSearchEntry, in: app).exists
                    || self.element(AccessibilityID.groupInfoSearchEntry, in: app).exists
            }
            let legacyEntry = [
                element(AccessibilityID.contactInfoSearchEntry, in: app),
                element(AccessibilityID.groupInfoSearchEntry, in: app)
            ].first(where: { $0.exists && $0.isHittable })
            guard let legacyEntry else {
                throw LiveQAError(message: "Info Card search entry is not hittable.")
            }
            legacyEntry.tap()
        }

        let input = element(AccessibilityID.input, in: app)
        guard input.waitForExistence(timeout: ChatSearchLiveQATimeoutPolicy.searchInput) else {
            throw LiveQAError(message: "chat_search_input did not appear after opening search.")
        }
    }

    private func closeSearchAndReturnToChats(in app: XCUIApplication) throws {
        try closeSearch(in: app)

        let navigationButtons = app.navigationBars.buttons.allElementsBoundByIndex
        guard let back = navigationButtons
            .filter({ $0.exists && $0.isHittable })
            .filter({ $0.identifier != AccessibilityID.chatAvatar })
            .sorted(by: { $0.frame.minX < $1.frame.minX })
            .first(where: { $0.frame.midX < app.frame.midX }) else {
            throw LiveQAError(message: "A safe navigation Back control was not found after closing search.")
        }
        back.tap()
        try wait(
            description: "Last Chats after zero-result fallback",
            timeout: ChatSearchLiveQATimeoutPolicy.finalSignedInShell,
            app: app
        ) {
            !self.element(AccessibilityID.chatAvatar, in: app).exists
                && self.hasSignedInShell(in: app)
                && !self.hasLoginOrOnboarding(in: app)
        }
    }

    // MARK: - Search terminal state

    private func enterExactQuery(_ query: String, in app: XCUIApplication) throws {
        XCTAssertEqual(query, "test")
        let input = element(AccessibilityID.input, in: app)
        guard input.exists, input.isHittable else {
            throw LiveQAError(message: "chat_search_input is not hittable.")
        }

        let current = stringValue(of: input)
        if !current.isEmpty {
            let clear = element(AccessibilityID.clear, in: app)
            guard clear.exists, clear.isHittable else {
                throw LiveQAError(message: "Existing search text cannot be cleared through chat_search_clear.")
            }
            clear.tap()
        }
        input.tap()
        var committedPrefix = ""
        for character in query {
            input.typeText(String(character))
            committedPrefix.append(character)
            try wait(
                description: "exact query prefix \(committedPrefix)",
                timeout: ChatSearchLiveQATimeoutPolicy.searchInput,
                app: app
            ) {
                self.stringValue(of: input) == committedPrefix
            }
        }
        XCTAssertEqual(stringValue(of: input), query)
        input.typeText("\n")
        try wait(
            description: "keyboard dismissed after Search",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            !app.keyboards.firstMatch.exists
        }
    }

    private func waitForTerminalOutcome(in app: XCUIApplication) throws -> TerminalOutcome {
        var resolved: TerminalOutcome?
        var observedLoading = false

        try wait(
            description: "terminal committed search outcome",
            timeout: ChatSearchLiveQATimeoutPolicy.terminalResults,
            app: app
        ) {
            let loading = self.isAnySearchLoading(in: app)
            observedLoading = observedLoading || loading

            let error = self.element(AccessibilityID.resultsError, in: app)
            if error.exists {
                resolved = .error(self.accessibilityText(of: error))
                return true
            }

            if let position = self.position(in: app), !loading {
                resolved = .results(position)
                return true
            }

            let explicitEmpty = self.element(AccessibilityID.resultsEmpty, in: app).exists
                || self.accessibilityStrings(
                    of: self.element(AccessibilityID.resultsCount, in: app)
                ).contains(where: self.isNoMessagesText)
            let returnedToSubmit = self.element(AccessibilityID.submit, in: app).exists
            let hasNoResultControls = !self.element(AccessibilityID.viewMode, in: app).exists
                && !self.element(AccessibilityID.previous, in: app).exists
                && !self.element(AccessibilityID.next, in: app).exists
            if !loading,
               explicitEmpty || (observedLoading && returnedToSubmit && hasNoResultControls) {
                resolved = .empty
                return true
            }
            return false
        }

        guard let resolved else {
            throw LiveQAError(message: "Search wait ended without a typed terminal outcome.")
        }
        return resolved
    }

    private func isAnySearchLoading(in app: XCUIApplication) -> Bool {
        element(AccessibilityID.loading, in: app).exists
            || element(AccessibilityID.resultsPaging, in: app).exists
    }

    // MARK: - Result navigation and list

    private func verifyDeterministicNavigationBranch(
        initialPosition: ChatSearchLiveQACountParser.Position,
        in app: XCUIApplication
    ) throws {
        let previous = element(AccessibilityID.previous, in: app)
        let next = element(AccessibilityID.next, in: app)
        guard previous.waitForExistence(
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition
        ), next.exists else {
            throw LiveQAError(message: "Search navigation arrows are not both visible.")
        }

        if initialPosition.total == 1 {
            XCTAssertEqual(initialPosition, .init(current: 1, total: 1))
            XCTAssertFalse(previous.isEnabled)
            XCTAssertFalse(next.isEnabled)
            return
        }

        XCTAssertGreaterThan(initialPosition.total, 1)
        XCTAssertTrue(previous.isEnabled)
        XCTAssertFalse(next.isEnabled)
        previous.tap()
        try waitForPosition(
            .init(current: 2, total: initialPosition.total),
            in: app
        )
        XCTAssertTrue(next.isEnabled)
        next.tap()
        try waitForPosition(initialPosition, in: app)
        XCTAssertFalse(next.isEnabled)
    }

    private func openAndVerifyNewestFirstList(
        expectedTotal: Int,
        query: String,
        in app: XCUIApplication
    ) throws {
        let mode = element(AccessibilityID.viewMode, in: app)
        guard mode.waitForExistence(
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition
        ), mode.isHittable else {
            throw LiveQAError(message: "Show as List control is unavailable.")
        }
        mode.tap()

        let list = element(AccessibilityID.resultsList, in: app)
        try wait(
            description: "newest-first search list",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            let first = self.resultRow(at: 0, in: app)
            return list.exists
                && first.exists
                && ChatSearchLiveQACountParser.position(from: self.stringValue(of: first))
                    == .init(current: 1, total: expectedTotal)
        }

        let count = element(AccessibilityID.resultsCount, in: app)
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: stringValue(of: count)), expectedTotal)

        // Query only the visible newest prefix. Enumerating every XCUIElement
        // eagerly scrolls/prefetches the table and can itself start MAM paging.
        for index in 0..<min(3, expectedTotal) {
            let row = resultRow(at: index, in: app)
            XCTAssertTrue(row.exists)
            XCTAssertEqual(
                ChatSearchLiveQACountParser.position(from: stringValue(of: row)),
                .init(current: index + 1, total: expectedTotal)
            )
            XCTAssertFalse(row.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(
                row.label.localizedCaseInsensitiveContains(query),
                "Expected a plain snippet containing exact query in row \(index + 1)."
            )
        }
    }

    private func reachOldestBoundaryFromList(
        initialTotal: Int,
        query: String,
        in app: XCUIApplication
    ) throws -> ChatSearchLiveQACountParser.Position {
        var total = initialTotal

        for _ in 0..<6 {
            let list = element(AccessibilityID.resultsList, in: app)
            try dismissKeyboardInteractivelyIfNeeded(using: list, in: app)
            let last = resultRow(at: total - 1, in: app)
            guard last.exists else {
                throw LiveQAError(message: "The last loaded list row is unavailable.")
            }
            try makeHittable(last, byScrolling: list, app: app)
            last.tap()
            try waitForPosition(.init(current: total, total: total), in: app)

            let previous = element(AccessibilityID.previous, in: app)
            let next = element(AccessibilityID.next, in: app)
            XCTAssertTrue(next.isEnabled)
            if !previous.isEnabled {
                let oldest = try requirePosition(in: app)
                XCTAssertEqual(oldest.current, oldest.total)
                XCTAssertFalse(previous.isEnabled)
                return oldest
            }

            previous.tap()
            try wait(
                description: "older-page boundary navigation",
                timeout: ChatSearchLiveQATimeoutPolicy.terminalResults,
                app: app
            ) {
                guard let position = self.position(in: app),
                      !self.isAnySearchLoading(in: app) else {
                    return false
                }
                return position.total > total || !previous.isEnabled
            }
            let expanded = try requirePosition(in: app)
            total = expanded.total
            try openAndVerifyNewestFirstList(
                expectedTotal: total,
                query: query,
                in: app
            )
        }

        throw LiveQAError(message: "Older paging did not reach a bounded non-wrapping boundary.")
    }

    private func makeHittable(
        _ element: XCUIElement,
        byScrolling scrollView: XCUIElement,
        app: XCUIApplication
    ) throws {
        guard !element.isHittable else { return }
        // Keep this batch bounded and avoid asking isHittable after every
        // gesture: each query snapshots all 261 live rows and adds seconds of
        // observer overhead. Extra swipes safely bounce at the table's end.
        for _ in 0..<20 {
            scrollView.swipeUp(velocity: .fast)
        }
        guard element.isHittable else {
            attachDiagnostics(named: "result-row-not-hittable", app: app)
            throw LiveQAError(message: "The oldest result row could not be made hittable.")
        }
    }

    // MARK: - Keyboard and calendar

    private func verifyInteractiveKeyboardContract(in app: XCUIApplication) throws {
        let list = element(AccessibilityID.resultsList, in: app)
        guard list.exists else {
            throw LiveQAError(message: "Result list is required for interactive keyboard dismissal.")
        }

        let input = element(AccessibilityID.input, in: app)
        input.tap()
        try wait(
            description: "keyboard before list drag",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { app.keyboards.firstMatch.exists }

        try dismissKeyboardInteractivelyIfNeeded(using: list, in: app)

        let mode = element(AccessibilityID.viewMode, in: app)
        mode.tap()
        try wait(
            description: "Show as Chat after keyboard dismissal",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { !self.element(AccessibilityID.resultsList, in: app).exists }

        input.tap()
        try wait(
            description: "ordinary input tap restores keyboard",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { app.keyboards.firstMatch.exists }

        mode.tap()
        try wait(
            description: "list switch preserves visible keyboard",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            self.element(AccessibilityID.resultsList, in: app).exists
                && app.keyboards.firstMatch.exists
        }
        mode.tap()
        try wait(
            description: "chat switch preserves visible keyboard",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            !self.element(AccessibilityID.resultsList, in: app).exists
                && app.keyboards.firstMatch.exists
        }
    }

    private func verifyCalendarAndRestore(
        expectedPosition: ChatSearchLiveQACountParser.Position,
        query: String,
        in app: XCUIApplication
    ) throws {
        let calendarButton = element(AccessibilityID.calendarButton, in: app)
        guard calendarButton.exists, calendarButton.isHittable else {
            throw LiveQAError(message: "Calendar entry is unavailable.")
        }
        calendarButton.tap()

        let calendar = element(AccessibilityID.calendar, in: app)
        try wait(
            description: "calendar presentation",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            calendar.exists && !app.keyboards.firstMatch.exists
        }

        let close = element(AccessibilityID.calendarClose, in: app)
        let month = element(AccessibilityID.calendarMonth, in: app)
        let previousMonth = element(AccessibilityID.calendarPreviousMonth, in: app)
        let nextMonth = element(AccessibilityID.calendarNextMonth, in: app)
        let done = element(AccessibilityID.calendarDone, in: app)
        [close, month, previousMonth, nextMonth, done].forEach {
            XCTAssertTrue($0.exists)
        }
        XCTAssertLessThan(close.frame.midX, month.frame.midX)
        XCTAssertTrue(nextMonth.isEnabled)
        XCTAssertTrue(done.isEnabled)

        let dayRows = Set(
            calendarDays(in: app).map { Int(($0.frame.midY / 4).rounded()) }
        )
        XCTAssertTrue((4...6).contains(dayRows.count), "Expected a dynamic 4–6-row calendar grid.")

        month.tap()
        try wait(
            description: "month/year disclosure",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { self.element(AccessibilityID.calendarMonthYearPicker, in: app).exists }
        month.tap()
        try wait(
            description: "month/year disclosure dismissal",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { !self.element(AccessibilityID.calendarMonthYearPicker, in: app).exists }

        attachScreenshot(named: "03-calendar", app: app)
        close.tap()
        try wait(
            description: "calendar X preserves search state",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            !calendar.exists
                && self.stringValue(of: self.element(AccessibilityID.input, in: app)) == query
                && self.position(in: app) == expectedPosition
                && !app.keyboards.firstMatch.exists
        }
    }

    private func closeSearch(in app: XCUIApplication) throws {
        let cancel = element(AccessibilityID.cancel, in: app)
        guard cancel.waitForExistence(
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition
        ), cancel.isHittable else {
            throw LiveQAError(message: "Top search X is unavailable.")
        }
        cancel.tap()
        try wait(
            description: "search cancellation",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { !self.element(AccessibilityID.input, in: app).exists }
    }

    // MARK: - Query helpers

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func resultRow(at index: Int, in app: XCUIApplication) -> XCUIElement {
        app.cells
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.resultRowPrefix))
            .element(boundBy: index)
    }

    private func dismissKeyboardInteractivelyIfNeeded(
        using list: XCUIElement,
        in app: XCUIApplication
    ) throws {
        guard app.keyboards.firstMatch.exists else { return }
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
        try wait(
            description: "interactive list drag dismisses keyboard",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) { !app.keyboards.firstMatch.exists }
    }

    private func calendarDays(in app: XCUIApplication) -> [XCUIElement] {
        app.cells
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.calendarDayPrefix))
            .allElementsBoundByIndex
            .filter(\.exists)
    }

    private func position(in app: XCUIApplication) -> ChatSearchLiveQACountParser.Position? {
        accessibilityStrings(of: element(AccessibilityID.resultsCount, in: app))
            .compactMap(ChatSearchLiveQACountParser.position(from:))
            .first
    }

    private func requirePosition(in app: XCUIApplication) throws -> ChatSearchLiveQACountParser.Position {
        guard let position = position(in: app) else {
            throw LiveQAError(message: "Committed result counter is unavailable.")
        }
        return position
    }

    private func waitForPosition(
        _ expected: ChatSearchLiveQACountParser.Position,
        in app: XCUIApplication
    ) throws {
        try wait(
            description: "committed counter \(expected.current) of \(expected.total)",
            timeout: ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition,
            app: app
        ) {
            self.position(in: app) == expected && !self.isAnySearchLoading(in: app)
        }
    }

    private func accessibilityStrings(of element: XCUIElement) -> [String] {
        let values = [element.value as? String, element.label, element.identifier]
        return values.compactMap { value in
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func stringValue(of element: XCUIElement) -> String {
        accessibilityStrings(of: element).first(where: {
            $0 != element.identifier && $0 != element.label
        }) ?? (element.value as? String ?? element.label)
    }

    private func accessibilityText(of element: XCUIElement) -> String {
        accessibilityStrings(of: element).joined(separator: " | ")
    }

    private func isNoMessagesText(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("no message")
            || normalized == "0 messages"
            || normalized == "0 message"
    }

    // MARK: - Bounded waits and evidence

    private func wait(
        description: String,
        timeout: TimeInterval,
        app: XCUIApplication,
        predicate: @escaping () -> Bool
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            attachDiagnostics(named: "timeout-\(sanitized(description))", app: app)
            throw LiveQAError(
                message: "Timed out after \(timeout)s waiting for \(description)."
            )
        }
    }

    private func assertGlobalBudget(startedAt: Date, stage: String) throws {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= ChatSearchLiveQATimeoutPolicy.globalBudget else {
            throw LiveQAError(
                message: "Global 180s live QA budget exceeded at \(stage): \(elapsed)s."
            )
        }
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachDiagnostics(named name: String, app: XCUIApplication) {
        attachScreenshot(named: "\(name)-screenshot", app: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy-and-identifiers"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func sanitized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    override func tearDown() {
        // Teardown never taps send/delete/logout, never changes credentials,
        // and never resets/uninstalls/erases the app or its storage.
        super.tearDown()
    }
}
