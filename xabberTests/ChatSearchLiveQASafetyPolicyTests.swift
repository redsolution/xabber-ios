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

final class ChatSearchLiveQASafetyPolicyTests: XCTestCase {
    func testMissingOrNonExactOptInSkipsBeforeApplicationCreation() {
        let missing = ChatSearchLiveQASafetyPolicy.decision(
            environment: [:],
            launchArguments: [],
            simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
        )
        let nonExact = ChatSearchLiveQASafetyPolicy.decision(
            environment: [ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "true"],
            launchArguments: [],
            simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
        )

        XCTAssertTrue(missing.isSkipBeforeApplicationCreation)
        XCTAssertTrue(nonExact.isSkipBeforeApplicationCreation)
    }

    func testExactOptInRequiresExpectedSimulatorUDID() {
        let decision = ChatSearchLiveQASafetyPolicy.decision(
            environment: [ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1"],
            launchArguments: [],
            simulatorUDID: "unexpected-simulator"
        )

        XCTAssertTrue(decision.isBlockingFailure)
        XCTAssertFalse(decision.isAllowed)
    }

    func testExpectedSimulatorAndExplicitOverrideAreTheOnlyAllowedDestinations() {
        let expected = ChatSearchLiveQASafetyPolicy.decision(
            environment: [ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1"],
            launchArguments: [],
            simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
        )
        let overridden = ChatSearchLiveQASafetyPolicy.decision(
            environment: [
                ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1",
                ChatSearchLiveQASafetyPolicy.simulatorOverrideEnvironmentKey: "1"
            ],
            launchArguments: [],
            simulatorUDID: "explicitly-overridden-simulator"
        )

        XCTAssertTrue(expected.isAllowed)
        XCTAssertTrue(overridden.isAllowed)
    }

    func testDestructiveLaunchArgumentsAreRejected() {
        for token in ChatSearchLiveQASafetyPolicy.forbiddenDestructiveTokens {
            let decision = ChatSearchLiveQASafetyPolicy.decision(
                environment: [ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1"],
                launchArguments: ["--UITest-\(token)"],
                simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
            )

            XCTAssertTrue(decision.isBlockingFailure, "Expected \(token) to be blocked")
        }
    }

    func testDestructiveEnvironmentKeysAndValuesAreRejected() {
        for token in ChatSearchLiveQASafetyPolicy.forbiddenDestructiveTokens {
            let destructiveKey = ChatSearchLiveQASafetyPolicy.decision(
                environment: [
                    ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1",
                    "XABBER_\(token)": "1"
                ],
                launchArguments: [],
                simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
            )
            let destructiveValue = ChatSearchLiveQASafetyPolicy.decision(
                environment: [
                    ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1",
                    "XABBER_QA_ACTION": token
                ],
                launchArguments: [],
                simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
            )

            XCTAssertTrue(destructiveKey.isBlockingFailure, "Expected key containing \(token) to be blocked")
            XCTAssertTrue(destructiveValue.isBlockingFailure, "Expected value containing \(token) to be blocked")
        }
    }

    func testPlatformInjectedResetDiagnosticsDoNotMasqueradeAsDestructiveQAInput() {
        let decision = ChatSearchLiveQASafetyPolicy.decision(
            environment: [
                ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1",
                "PERFC_RESET_INSERT_LIBRARIES": "1"
            ],
            launchArguments: [],
            simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
        )

        XCTAssertTrue(decision.isAllowed)
    }

    func testLiveScenarioUsesOnlyApprovedDialogsAndExactQuery() {
        XCTAssertEqual(
            ChatSearchLiveQASafetyPolicy.dialogCandidates,
            ["Andrew Nenakhov", "Alexey Boldin"]
        )
        XCTAssertEqual(ChatSearchLiveQASafetyPolicy.searchQuery, "test")
    }

    func testMissingAccountOrDialogFailsWithoutLoginAutomation() {
        XCTAssertEqual(
            ChatSearchLiveQASafetyPolicy.missingSignedInStateDisposition,
            .failWithoutLoginAutomation
        )
        XCTAssertEqual(
            ChatSearchLiveQASafetyPolicy.missingDialogDisposition,
            .failWithoutLoginAutomation
        )
        XCTAssertFalse(ChatSearchLiveQASafetyPolicy.permitsCredentialEntry)
        XCTAssertFalse(ChatSearchLiveQASafetyPolicy.permitsAccountMutation)
    }

    func testTeardownAllowsOnlySearchCancellationAndProcessTermination() {
        XCTAssertEqual(
            ChatSearchLiveQASafetyPolicy.allowedTeardownOperations,
            [.cancelSearch, .terminateProcess]
        )
        XCTAssertFalse(ChatSearchLiveQASafetyPolicy.permitsDataCleanup)
        XCTAssertFalse(ChatSearchLiveQASafetyPolicy.permitsApplicationUninstall)
    }

    func testLiveTimeoutPolicyMatchesBoundedScenarioContract() {
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.appShell, 30)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.dialogLookupPerCandidate, 20)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.searchEntry, 10)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.searchInput, 5)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.terminalResults, 45)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.modeOrCalendarTransition, 5)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.finalSignedInShell, 10)
        XCTAssertEqual(ChatSearchLiveQATimeoutPolicy.globalBudget, 180)
    }

    func testCounterParserAcceptsPositionAndMessageCountValues() {
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(from: "1 of 2"),
            .init(current: 1, total: 2)
        )
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(from: "17 of 17"),
            .init(current: 17, total: 17)
        )
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "1 message"), 1)
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "25 messages"), 25)
        XCTAssertNil(ChatSearchLiveQACountParser.position(from: "No messages"))
        XCTAssertNil(ChatSearchLiveQACountParser.messageCount(from: "Search failed"))
    }

    func testCounterParserAcceptsRussianAndGroupedLocalizedValues() {
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(from: "1 из 261"),
            .init(current: 1, total: 261)
        )
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(from: "1\u{00A0}234 из 2\u{202F}345"),
            .init(current: 1_234, total: 2_345)
        )
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(from: "1 among 261"),
            .init(current: 1, total: 261)
        )
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(
                from: "\u{06F1}\u{066C}\u{06F2}\u{06F3}\u{06F4} از \u{06F2}\u{066C}\u{06F3}\u{06F4}\u{06F5}"
            ),
            .init(current: 1_234, total: 2_345)
        )
        XCTAssertEqual(
            ChatSearchLiveQACountParser.position(
                from: "\u{0967}\u{0968},\u{0969}\u{096A},\u{096B}\u{096C}\u{096D} में से "
                    + "\u{0967}\u{0968},\u{0969}\u{096A},\u{096B}\u{096C}\u{096E}"
            ),
            .init(current: 1_234_567, total: 1_234_568)
        )

        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "1 сообщение"), 1)
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "2 сообщения"), 2)
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "5 сообщений"), 5)
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "261 сообщение"), 261)
        XCTAssertEqual(
            ChatSearchLiveQACountParser.messageCount(from: "1\u{00A0}234 сообщения"),
            1_234
        )
        XCTAssertEqual(ChatSearchLiveQACountParser.messageCount(from: "261 result"), 261)
        XCTAssertEqual(
            ChatSearchLiveQACountParser.messageCount(
                from: "\u{06F1}\u{066C}\u{06F2}\u{06F3}\u{06F4} پیام"
            ),
            1_234
        )
        XCTAssertEqual(
            ChatSearchLiveQACountParser.messageCount(
                from: "12\u{00A0}34\u{202F}567 messages"
            ),
            1_234_567
        )
    }

    func testCounterParserRejectsMalformedLocalizedValues() {
        XCTAssertNil(ChatSearchLiveQACountParser.position(from: "1 из"))
        XCTAssertNil(ChatSearchLiveQACountParser.position(from: "из 261"))
        XCTAssertNil(ChatSearchLiveQACountParser.position(from: "2 из 1"))
        XCTAssertNil(ChatSearchLiveQACountParser.messageCount(from: "261"))
        XCTAssertNil(ChatSearchLiveQACountParser.messageCount(from: "Search failed 261"))
        XCTAssertNil(ChatSearchLiveQACountParser.messageCount(from: "1 из 261"))
        XCTAssertNil(ChatSearchLiveQACountParser.messageCount(from: "-1 messages"))
        XCTAssertNil(ChatSearchLiveQACountParser.messageCount(from: "1.5 messages"))
    }

    func testPopulatedListCounterRemainsReadableDuringNextPagePaging() {
        XCTAssertEqual(
            ChatSearchLiveQAListCountPolicy.consistentTotal(
                rowAccessibilityValues: ["1 из 260"],
                countAccessibilityValues: ["Количество результатов поиска", "260 сообщений"],
                minimumTotal: 260
            ),
            260
        )
        XCTAssertEqual(
            ChatSearchLiveQAListCountPolicy.consistentTotal(
                rowAccessibilityValues: ["1 из 261"],
                countAccessibilityValues: ["261 сообщение"],
                minimumTotal: 260
            ),
            261
        )
        XCTAssertNil(
            ChatSearchLiveQAListCountPolicy.consistentTotal(
                rowAccessibilityValues: ["1 из 260"],
                countAccessibilityValues: ["261 сообщение"],
                minimumTotal: 260
            )
        )
        XCTAssertNil(
            ChatSearchLiveQAListCountPolicy.consistentTotal(
                rowAccessibilityValues: ["2 из 260"],
                countAccessibilityValues: ["260 сообщений"],
                minimumTotal: 260
            )
        )
        XCTAssertNil(
            ChatSearchLiveQAListCountPolicy.consistentTotal(
                rowAccessibilityValues: ["1 из 259"],
                countAccessibilityValues: ["259 сообщений"],
                minimumTotal: 260
            )
        )
        XCTAssertNil(
            ChatSearchLiveQAListCountPolicy.consistentTotal(
                rowAccessibilityValues: ["Search failed"],
                countAccessibilityValues: ["260 сообщений"],
                minimumTotal: 260
            )
        )

        let terminalObservation = ChatSearchLiveQATerminalObservationPolicy.observe(
            isLoading: { true },
            elementExists: { true },
            value: { ["260 сообщений"] }
        )
        XCTAssertNil(terminalObservation)
    }

    func testBoundarySelectionRetriesWhenPagingMakesTargetNonOldest() {
        XCTAssertEqual(
            ChatSearchLiveQABoundarySelectionPolicy.decision(
                targetCurrent: 260,
                selectedPosition: .init(current: 260, total: 261)
            ),
            .retryList(minimumTotal: 261)
        )
        XCTAssertEqual(
            ChatSearchLiveQABoundarySelectionPolicy.decision(
                targetCurrent: 260,
                selectedPosition: .init(current: 260, total: 260)
            ),
            .verifyBoundary(.init(current: 260, total: 260))
        )
        XCTAssertNil(
            ChatSearchLiveQABoundarySelectionPolicy.decision(
                targetCurrent: 260,
                selectedPosition: .init(current: 259, total: 260)
            )
        )
        XCTAssertNil(
            ChatSearchLiveQABoundarySelectionPolicy.decision(
                targetCurrent: 260,
                selectedPosition: .init(current: 260, total: 259)
            )
        )
    }

    func testBoundaryReadinessRequiresStableOldestOrPagingDecision() {
        let oldest = ChatSearchLiveQABoundaryReadinessPolicy.Decision.acceptOldest(
            .init(current: 260, total: 260)
        )
        let requestOlder = ChatSearchLiveQABoundaryReadinessPolicy.Decision.requestOlderPage(
            .init(current: 260, total: 260)
        )
        let retry = ChatSearchLiveQABoundaryReadinessPolicy.Decision.retryList(
            minimumTotal: 261
        )

        XCTAssertEqual(
            ChatSearchLiveQABoundaryReadinessPolicy.decision(
                targetCurrent: 260,
                observedPosition: .init(current: 260, total: 261),
                previousEnabled: false
            ),
            retry
        )
        XCTAssertEqual(
            ChatSearchLiveQABoundaryReadinessPolicy.decision(
                targetCurrent: 260,
                observedPosition: .init(current: 260, total: 260),
                previousEnabled: false
            ),
            oldest
        )
        XCTAssertEqual(
            ChatSearchLiveQABoundaryReadinessPolicy.decision(
                targetCurrent: 260,
                observedPosition: .init(current: 260, total: 260),
                previousEnabled: true
            ),
            requestOlder
        )
        XCTAssertNil(
            ChatSearchLiveQABoundaryReadinessPolicy.decision(
                targetCurrent: 260,
                observedPosition: .init(current: 259, total: 260),
                previousEnabled: false
            )
        )

        var tracker = ChatSearchLiveQABoundaryReadinessTracker()
        XCTAssertNil(tracker.observe(oldest))
        XCTAssertEqual(tracker.observe(oldest), oldest)
        XCTAssertNil(tracker.observe(nil))
        XCTAssertNil(tracker.observe(requestOlder))
        XCTAssertNil(tracker.observe(retry))
        XCTAssertEqual(tracker.observe(retry), retry)
    }

    func testBoundaryBudgetCapsWaitsAndSeparatesGrowthFromPageRequests() {
        let deadline = Date(timeIntervalSince1970: 180)
        XCTAssertEqual(
            ChatSearchLiveQABoundaryDeadlinePolicy.remainingTimeout(
                until: deadline,
                now: Date(timeIntervalSince1970: 0),
                maximum: 45
            ),
            45
        )
        XCTAssertEqual(
            ChatSearchLiveQABoundaryDeadlinePolicy.remainingTimeout(
                until: deadline,
                now: Date(timeIntervalSince1970: 160),
                maximum: 45
            ),
            20
        )
        XCTAssertNil(
            ChatSearchLiveQABoundaryDeadlinePolicy.remainingTimeout(
                until: deadline,
                now: deadline,
                maximum: 45
            )
        )

        var budget = ChatSearchLiveQABoundaryAttemptBudget(
            maximumPageRequests: 2,
            maximumGrowthRetries: 3
        )
        XCTAssertTrue(budget.consume(.growthRetry))
        XCTAssertTrue(budget.consume(.growthRetry))
        XCTAssertTrue(budget.consume(.growthRetry))
        XCTAssertFalse(budget.consume(.growthRetry))
        XCTAssertTrue(budget.consume(.pageRequest))
        XCTAssertTrue(budget.consume(.pageRequest))
        XCTAssertFalse(budget.consume(.pageRequest))
    }

    func testElementLookupPolicyAlwaysPrefersStableIdentifier() {
        XCTAssertEqual(
            ChatSearchLiveQAElementLookupPolicy.strategy(
                stableIdentifier: "chat_search_input",
                visibleTextFallback: "Search"
            ),
            .stableIdentifier("chat_search_input")
        )
        XCTAssertEqual(
            ChatSearchLiveQAElementLookupPolicy.strategy(
                stableIdentifier: nil,
                visibleTextFallback: "Andrew Nenakhov"
            ),
            .visibleText("Andrew Nenakhov")
        )
    }

    func testTerminalObservationSkipsLoadingAndAbsentElementReads() {
        var loadingReads = 0
        var existenceReads = 0
        var valueReads = 0
        var loading = true

        let loadingObservation = ChatSearchLiveQATerminalObservationPolicy.observe(
            isLoading: {
                loadingReads += 1
                return loading
            },
            elementExists: {
                existenceReads += 1
                return true
            },
            value: {
                valueReads += 1
                return ["must not be read"]
            }
        )

        XCTAssertNil(loadingObservation)
        XCTAssertEqual(loadingReads, 1)
        XCTAssertEqual(existenceReads, 0)
        XCTAssertEqual(valueReads, 0)

        loading = false
        let absent = ChatSearchLiveQATerminalObservationPolicy.observe(
            isLoading: {
                loadingReads += 1
                return loading
            },
            elementExists: {
                existenceReads += 1
                return false
            },
            value: {
                valueReads += 1
                return ["must not be read"]
            }
        )

        XCTAssertEqual(absent?.exists, false)
        XCTAssertNil(absent?.value)
        XCTAssertEqual(loadingReads, 3)
        XCTAssertEqual(existenceReads, 1)
        XCTAssertEqual(valueReads, 0)
    }

    func testTerminalObservationReadsExistingElementOnce() {
        var loadingReads = 0
        var existenceReads = 0
        var valueReads = 0

        let observation = ChatSearchLiveQATerminalObservationPolicy.observe(
            isLoading: {
                loadingReads += 1
                return false
            },
            elementExists: {
                existenceReads += 1
                return true
            },
            value: {
                valueReads += 1
                return ["1 of 2"]
            }
        )

        XCTAssertEqual(observation?.exists, true)
        XCTAssertEqual(observation?.value, ["1 of 2"])
        XCTAssertEqual(loadingReads, 3)
        XCTAssertEqual(existenceReads, 1)
        XCTAssertEqual(valueReads, 1)
    }

    func testTerminalObservationRejectsHierarchyThatStartsLoadingDuringProbe() {
        var loadingStates = [false, false, true]
        var existenceReads = 0
        var valueReads = 0

        let observation = ChatSearchLiveQATerminalObservationPolicy.observe(
            isLoading: { loadingStates.removeFirst() },
            elementExists: {
                existenceReads += 1
                return true
            },
            value: {
                valueReads += 1
                return ["1 of 2"]
            }
        )

        XCTAssertNil(observation)
        XCTAssertEqual(existenceReads, 1)
        XCTAssertEqual(valueReads, 1)
        XCTAssertTrue(loadingStates.isEmpty)
    }

    func testTerminalEmptyTrackerRequiresStableCounterlessSearchState() {
        var tracker = ChatSearchLiveQAEmptyStateTracker(requiredStableObservationCount: 2)

        XCTAssertFalse(
            tracker.observe(
                isLoading: true,
                hasExplicitEmpty: false,
                hasResultsCounter: true,
                hasSearchInput: true,
                hasResultControls: false
            )
        )
        XCTAssertFalse(
            tracker.observe(
                isLoading: false,
                hasExplicitEmpty: false,
                hasResultsCounter: false,
                hasSearchInput: true,
                hasResultControls: false
            )
        )
        XCTAssertTrue(
            tracker.observe(
                isLoading: false,
                hasExplicitEmpty: false,
                hasResultsCounter: false,
                hasSearchInput: true,
                hasResultControls: false
            )
        )
        XCTAssertFalse(
            tracker.observe(
                isLoading: false,
                hasExplicitEmpty: false,
                hasResultsCounter: true,
                hasSearchInput: true,
                hasResultControls: false
            )
        )
        XCTAssertFalse(
            tracker.observe(
                isLoading: false,
                hasExplicitEmpty: false,
                hasResultsCounter: false,
                hasSearchInput: true,
                hasResultControls: false
            )
        )
        XCTAssertFalse(
            tracker.observe(
                isLoading: true,
                hasExplicitEmpty: true,
                hasResultsCounter: false,
                hasSearchInput: true,
                hasResultControls: false
            )
        )
        XCTAssertTrue(
            tracker.observe(
                isLoading: false,
                hasExplicitEmpty: true,
                hasResultsCounter: false,
                hasSearchInput: true,
                hasResultControls: true
            )
        )
    }

    func testDateJumpScenarioRequiresSecondExactOptInBeforeApplicationCreation() {
        let missing = ChatSearchLiveQASafetyPolicy.dateJumpDecision(
            environment: [ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1"],
            launchArguments: [],
            simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
        )
        let enabled = ChatSearchLiveQASafetyPolicy.dateJumpDecision(
            environment: [
                ChatSearchLiveQASafetyPolicy.optInEnvironmentKey: "1",
                ChatSearchLiveQASafetyPolicy.dateJumpOptInEnvironmentKey: "1"
            ],
            launchArguments: [],
            simulatorUDID: ChatSearchLiveQASafetyPolicy.expectedSimulatorUDID
        )

        XCTAssertTrue(missing.isSkipBeforeApplicationCreation)
        XCTAssertTrue(enabled.isAllowed)
    }

    func testSharedSchemeBridgesExactShellOptInsIntoUITestRunner() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemeURL = repositoryRoot
            .appendingPathComponent("xabber.xcodeproj")
            .appendingPathComponent("xcshareddata/xcschemes/Debug.xcscheme")
        let scheme = try String(contentsOf: schemeURL, encoding: .utf8)

        XCTAssertTrue(scheme.contains("shouldUseLaunchSchemeArgsEnv = \"YES\""))
        XCTAssertTrue(
            scheme.contains(
                "key = \"XABBER_LIVE_SEARCH_QA\"\n            value = \"$(XABBER_LIVE_SEARCH_QA)\""
            )
        )
        XCTAssertTrue(
            scheme.contains(
                "key = \"XABBER_LIVE_SEARCH_DATE_JUMP_QA\"\n            value = \"$(XABBER_LIVE_SEARCH_DATE_JUMP_QA)\""
            )
        )
    }

    func testLiveSmokeSubmitsWithKeyboardReturnAndWaitsForKeyboardDismissal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let smokeURL = repositoryRoot
            .appendingPathComponent("xabberUITests")
            .appendingPathComponent("ChatSearchLiveSmokeTests.swift")
        let source = try String(contentsOf: smokeURL, encoding: .utf8)

        XCTAssertFalse(source.contains("submit.tap()"))
        XCTAssertTrue(source.contains("input.typeText(\"\\n\")"))
        XCTAssertTrue(source.contains("!app.keyboards.firstMatch.exists"))
        XCTAssertTrue(source.contains("waitForTerminalOutcome(in: app)"))
    }
}
