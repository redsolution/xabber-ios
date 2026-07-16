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

enum ChatSearchLiveQATimeoutPolicy {
    static let appShell: TimeInterval = 30
    static let dialogLookupPerCandidate: TimeInterval = 20
    static let searchEntry: TimeInterval = 10
    static let searchInput: TimeInterval = 5
    static let terminalResults: TimeInterval = 45
    static let modeOrCalendarTransition: TimeInterval = 5
    static let finalSignedInShell: TimeInterval = 10
    static let globalBudget: TimeInterval = 180
}

enum ChatSearchLiveQACountParser {
    struct Position: Equatable {
        let current: Int
        let total: Int
    }

    static func position(from rawValue: String) -> Position? {
        let parts = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first,
              let last = parts.last,
              formattedDigits(from: first) != nil,
              formattedDigits(from: last) != nil,
              parts.contains(where: { formattedDigits(from: $0) == nil }),
              let values = numericValues(in: parts),
              values.count == 2,
              let current = values.first,
              let total = values.last,
              current > 0,
              total >= current else {
            return nil
        }
        return Position(current: current, total: total)
    }

    static func messageCount(from rawValue: String) -> Int? {
        let parts = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2,
              let first = parts.first,
              let last = parts.last,
              formattedDigits(from: first) != nil,
              formattedDigits(from: last) == nil,
              let values = numericValues(in: parts),
              values.count == 1,
              let count = values.first,
              count >= 0 else {
            return nil
        }
        return count
    }

    private static func numericValues(in parts: [Substring]) -> [Int]? {
        var runs: [(groups: [String], usesGrouping: Bool)] = []
        var pendingGroups: [String] = []
        var pendingUsesGrouping = false

        func commitPendingGroups() {
            if !pendingGroups.isEmpty {
                runs.append((pendingGroups, pendingUsesGrouping))
            }
            pendingGroups = []
            pendingUsesGrouping = false
        }

        for part in parts {
            guard let groups = digitGroups(from: part) else {
                commitPendingGroups()
                continue
            }

            if !pendingGroups.isEmpty || groups.count > 1 {
                pendingUsesGrouping = true
            }
            pendingGroups.append(contentsOf: groups)
        }
        commitPendingGroups()

        var values: [Int] = []
        for run in runs {
            guard !run.usesGrouping || isValidGrouping(run.groups),
                  let value = Int(run.groups.joined()) else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    private static func formattedDigits(from rawValue: Substring) -> String? {
        guard let groups = digitGroups(from: rawValue),
              groups.count == 1 || isValidGrouping(groups) else {
            return nil
        }
        return groups.joined()
    }

    private static func digitGroups(from rawValue: Substring) -> [String]? {
        var groups = [""]
        for character in rawValue {
            if let digit = character.wholeNumberValue {
                groups[groups.count - 1].append(String(digit))
            } else if character.isPunctuation,
                      groups.last?.isEmpty == false {
                groups.append("")
            } else {
                return nil
            }
        }

        guard groups.last?.isEmpty == false else {
            return nil
        }
        return groups
    }

    private static func isValidGrouping(_ groups: [String]) -> Bool {
        guard groups.count > 1,
              let first = groups.first,
              let last = groups.last else {
            return false
        }

        let usesWesternGrouping = (1...3).contains(first.count)
            && groups.dropFirst().allSatisfy { $0.count == 3 }
        let usesIndianGrouping = (1...2).contains(first.count)
            && last.count == 3
            && groups.dropFirst().dropLast().allSatisfy { $0.count == 2 }
        return usesWesternGrouping || usesIndianGrouping
    }
}

enum ChatSearchLiveQAListCountPolicy {
    static func consistentTotal(
        rowAccessibilityValues: [String],
        countAccessibilityValues: [String],
        minimumTotal: Int
    ) -> Int? {
        guard minimumTotal > 0 else { return nil }
        let positions = rowAccessibilityValues
            .compactMap(ChatSearchLiveQACountParser.position(from:))
            .filter { $0.current == 1 && $0.total >= minimumTotal }
        let counts = Set(
            countAccessibilityValues
                .compactMap(ChatSearchLiveQACountParser.messageCount(from:))
        )
        return positions
            .map(\.total)
            .first(where: counts.contains)
    }
}

enum ChatSearchLiveQABoundarySelectionPolicy {
    enum Decision: Equatable {
        case retryList(minimumTotal: Int)
        case verifyBoundary(ChatSearchLiveQACountParser.Position)
    }

    static func decision(
        targetCurrent: Int,
        selectedPosition: ChatSearchLiveQACountParser.Position
    ) -> Decision? {
        guard targetCurrent > 0,
              selectedPosition.current == targetCurrent,
              selectedPosition.total >= selectedPosition.current else {
            return nil
        }

        if selectedPosition.current < selectedPosition.total {
            return .retryList(minimumTotal: selectedPosition.total)
        }
        return .verifyBoundary(selectedPosition)
    }
}

enum ChatSearchLiveQABoundaryReadinessPolicy {
    enum Decision: Equatable {
        case retryList(minimumTotal: Int)
        case requestOlderPage(ChatSearchLiveQACountParser.Position)
        case acceptOldest(ChatSearchLiveQACountParser.Position)
    }

    static func decision(
        targetCurrent: Int,
        observedPosition: ChatSearchLiveQACountParser.Position,
        previousEnabled: Bool
    ) -> Decision? {
        guard targetCurrent > 0,
              observedPosition.current == targetCurrent,
              observedPosition.total >= observedPosition.current else {
            return nil
        }

        if observedPosition.current < observedPosition.total {
            return .retryList(minimumTotal: observedPosition.total)
        }
        return previousEnabled
            ? .requestOlderPage(observedPosition)
            : .acceptOldest(observedPosition)
    }
}

struct ChatSearchLiveQABoundaryReadinessTracker {
    private let requiredStableObservationCount: Int
    private var previousDecision: ChatSearchLiveQABoundaryReadinessPolicy.Decision?
    private var consecutiveObservationCount = 0

    init(requiredStableObservationCount: Int = 2) {
        precondition(requiredStableObservationCount > 0)
        self.requiredStableObservationCount = requiredStableObservationCount
    }

    mutating func observe(
        _ decision: ChatSearchLiveQABoundaryReadinessPolicy.Decision?
    ) -> ChatSearchLiveQABoundaryReadinessPolicy.Decision? {
        guard let decision else {
            previousDecision = nil
            consecutiveObservationCount = 0
            return nil
        }

        if previousDecision == decision {
            consecutiveObservationCount += 1
        } else {
            previousDecision = decision
            consecutiveObservationCount = 1
        }
        return consecutiveObservationCount >= requiredStableObservationCount
            ? decision
            : nil
    }
}

enum ChatSearchLiveQABoundaryDeadlinePolicy {
    static func remainingTimeout(
        until deadline: Date,
        now: Date,
        maximum: TimeInterval
    ) -> TimeInterval? {
        guard maximum > 0 else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return min(maximum, remaining)
    }
}

struct ChatSearchLiveQABoundaryAttemptBudget {
    enum Attempt {
        case growthRetry
        case pageRequest
    }

    private let maximumPageRequests: Int
    private let maximumGrowthRetries: Int
    private var pageRequestCount = 0
    private var growthRetryCount = 0

    init(maximumPageRequests: Int, maximumGrowthRetries: Int) {
        precondition(maximumPageRequests >= 0)
        precondition(maximumGrowthRetries >= 0)
        self.maximumPageRequests = maximumPageRequests
        self.maximumGrowthRetries = maximumGrowthRetries
    }

    mutating func consume(_ attempt: Attempt) -> Bool {
        switch attempt {
        case .growthRetry:
            guard growthRetryCount < maximumGrowthRetries else { return false }
            growthRetryCount += 1
        case .pageRequest:
            guard pageRequestCount < maximumPageRequests else { return false }
            pageRequestCount += 1
        }
        return true
    }
}

enum ChatSearchLiveQAElementLookupPolicy {
    enum Strategy: Equatable {
        case stableIdentifier(String)
        case visibleText(String)
    }

    static func strategy(
        stableIdentifier: String?,
        visibleTextFallback: String
    ) -> Strategy {
        if let stableIdentifier,
           !stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .stableIdentifier(stableIdentifier)
        }
        return .visibleText(visibleTextFallback)
    }
}

enum ChatSearchLiveQATerminalObservationPolicy {
    struct Element<Value> {
        let exists: Bool
        let value: Value?
    }

    static func observe<Value>(
        isLoading: () -> Bool,
        elementExists: () -> Bool,
        value: () -> Value
    ) -> Element<Value>? {
        guard !isLoading() else { return nil }
        let exists = elementExists()
        guard !isLoading() else { return nil }
        guard exists else { return Element(exists: false, value: nil) }

        let resolvedValue = value()
        guard !isLoading() else { return nil }
        return Element(exists: true, value: resolvedValue)
    }
}

struct ChatSearchLiveQAEmptyStateTracker {
    private let requiredStableObservationCount: Int
    private(set) var consecutiveCandidateCount = 0

    init(requiredStableObservationCount: Int = 2) {
        precondition(requiredStableObservationCount > 0)
        self.requiredStableObservationCount = requiredStableObservationCount
    }

    mutating func observe(
        isLoading: Bool,
        hasExplicitEmpty: Bool,
        hasResultsCounter: Bool,
        hasSearchInput: Bool,
        hasResultControls: Bool
    ) -> Bool {
        guard !isLoading else {
            consecutiveCandidateCount = 0
            return false
        }
        if hasExplicitEmpty {
            consecutiveCandidateCount = 0
            return true
        }

        let isCandidate = !hasResultsCounter
            && hasSearchInput
            && !hasResultControls
        consecutiveCandidateCount = isCandidate
            ? consecutiveCandidateCount + 1
            : 0
        return consecutiveCandidateCount >= requiredStableObservationCount
    }

    mutating func reset() {
        consecutiveCandidateCount = 0
    }
}

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
    static let dateJumpOptInEnvironmentKey = "XABBER_LIVE_SEARCH_DATE_JUMP_QA"
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

    static func dateJumpDecision(
        environment: [String: String],
        launchArguments: [String],
        simulatorUDID: String?
    ) -> Decision {
        let baseDecision = decision(
            environment: environment,
            launchArguments: launchArguments,
            simulatorUDID: simulatorUDID
        )
        guard baseDecision.isAllowed else {
            return baseDecision
        }
        guard environment[dateJumpOptInEnvironmentKey] == "1" else {
            return .skipBeforeApplicationCreation(
                reason: "Set \(dateJumpOptInEnvironmentKey)=1 to authorize controlled date-jump QA."
            )
        }
        return .allowed
    }

    private static func firstDestructiveInput(
        environment: [String: String],
        launchArguments: [String]
    ) -> String? {
        let xabberEnvironmentInputs = environment
            .filter { key, _ in key.uppercased().hasPrefix("XABBER_") }
            .flatMap { [$0.key, $0.value] }
        let inputs = launchArguments + xabberEnvironmentInputs
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

    static func requireDateJumpAuthorization(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchArguments: [String] = [],
        simulatorUDID: String? = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
    ) throws -> Authorization {
        switch ChatSearchLiveQASafetyPolicy.dateJumpDecision(
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
