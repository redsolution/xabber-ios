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
}
