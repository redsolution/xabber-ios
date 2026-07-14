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

    func testLiveSmokeLetsDebouncedTypingCommitWithoutTappingMagnifierProxy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let smokeURL = repositoryRoot
            .appendingPathComponent("xabberUITests")
            .appendingPathComponent("ChatSearchLiveSmokeTests.swift")
        let source = try String(contentsOf: smokeURL, encoding: .utf8)

        XCTAssertFalse(source.contains("submit.tap()"))
        XCTAssertTrue(source.contains("waitForTerminalOutcome(in: app)"))
    }
}
