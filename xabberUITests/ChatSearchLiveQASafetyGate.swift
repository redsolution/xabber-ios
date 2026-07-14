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

import Foundation
import XCTest

/// Pure, testable authorization policy for live-account search QA.
///
/// Absolute safety contract: this policy never authorizes reset, erase, logout,
/// account removal, data deletion, Realm cleanup, credential entry, uninstall,
/// or container mutation. Callers must evaluate it before constructing an
/// `XCUIApplication`, and therefore necessarily before `launch()`.
struct ChatSearchLiveQASafetyPolicy {
    enum Decision: Equatable {
        case skipBeforeApplicationCreation(reason: String)
        case blockingFailure(reason: String)
        case allowed

        var isSkipBeforeApplicationCreation: Bool {
            if case .skipBeforeApplicationCreation = self { return true }
            return false
        }

        var isBlockingFailure: Bool {
            if case .blockingFailure = self { return true }
            return false
        }

        var isAllowed: Bool { self == .allowed }
    }

    enum MissingLiveStateDisposition: Equatable {
        case failWithoutLoginAutomation
    }

    enum TeardownOperation: Equatable {
        case cancelSearch
        case terminateProcess
    }

    static let optInEnvironmentKey = "XABBER_LIVE_SEARCH_QA"
    static let simulatorOverrideEnvironmentKey = "XABBER_LIVE_SEARCH_QA_ALLOW_ANY_SIMULATOR"
    static let expectedSimulatorUDID = "7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF"
    static let dialogCandidates = ["Andrew Nenakhov", "Alexey Boldin"]
    static let searchQuery = "test"
    static let forbiddenDestructiveTokens = [
        "reset",
        "erase",
        "logout",
        "remove-account",
        "delete-data",
        "clean-realm"
    ]

    static let missingSignedInStateDisposition = MissingLiveStateDisposition.failWithoutLoginAutomation
    static let missingDialogDisposition = MissingLiveStateDisposition.failWithoutLoginAutomation
    static let permitsCredentialEntry = false
    static let permitsAccountMutation = false
    static let allowedTeardownOperations: [TeardownOperation] = [.cancelSearch, .terminateProcess]
    static let permitsDataCleanup = false
    static let permitsApplicationUninstall = false

    static func decision(
        environment: [String: String],
        launchArguments: [String],
        simulatorUDID: String?
    ) -> Decision {
        guard environment[optInEnvironmentKey] == "1" else {
            return .skipBeforeApplicationCreation(
                reason: "Set \(optInEnvironmentKey)=1 to authorize non-destructive live search QA."
            )
        }

        if let destructiveInput = firstDestructiveInput(
            environment: environment,
            launchArguments: launchArguments
        ) {
            return .blockingFailure(
                reason: "Live search QA rejected destructive input: \(destructiveInput)"
            )
        }

        let hasExplicitSimulatorOverride =
            environment[simulatorOverrideEnvironmentKey] == "1"
        guard simulatorUDID == expectedSimulatorUDID || hasExplicitSimulatorOverride else {
            return .blockingFailure(
                reason: "Live search QA requires simulator \(expectedSimulatorUDID); got \(simulatorUDID ?? "none")."
            )
        }

        return .allowed
    }

    private static func firstDestructiveInput(
        environment: [String: String],
        launchArguments: [String]
    ) -> String? {
        let inputs = launchArguments + environment.flatMap { [$0.key, $0.value] }
        return inputs.first { input in
            let normalized = input
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            return forbiddenDestructiveTokens.contains { normalized.contains($0) }
        }
    }
}

struct ChatSearchLiveQASafetyGate {
    struct Authorization: Equatable {
        let dialogCandidates: [String]
        let query: String
    }

    struct BlockingError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Must remain the first executable statement in every live UI scenario.
    /// No `XCUIApplication` may be created before this method returns.
    static func requireAuthorization(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchArguments: [String] = [],
        simulatorUDID: String? = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
    ) throws -> Authorization {
        switch ChatSearchLiveQASafetyPolicy.decision(
            environment: environment,
            launchArguments: launchArguments,
            simulatorUDID: simulatorUDID
        ) {
        case .skipBeforeApplicationCreation(let reason):
            throw XCTSkip(reason)
        case .blockingFailure(let reason):
            XCTFail(reason)
            throw BlockingError(reason: reason)
        case .allowed:
            return Authorization(
                dialogCandidates: ChatSearchLiveQASafetyPolicy.dialogCandidates,
                query: ChatSearchLiveQASafetyPolicy.searchQuery
            )
        }
    }
}
