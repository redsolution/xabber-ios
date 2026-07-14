//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation

enum ChatRenderOperation: String, CaseIterable {
    case rowsEnumerated
    case candidatesMaterialized
    case richSnapshotsBuilt
    case textMeasurements = "glyphMeasurements"
    case layoutCacheHits
    case layoutCacheMisses
    case reloads
    case layoutFlushes
    case offsetMutations
    case cellBindChrome
    case cellBindText = "cellBindContent"
    case cellBindLayout
    case cellBindAttachments
    case cellBindAvatar
    case mediaRequests
    case mediaDownloads
    case mediaDecodes
    case activeTasks
    case activeTimers
    case scrollFrames
    case visibleRowsVisited
    case storeQueries
    case floatingDateUpdates
    case voiceQueueUpdates
    case observerRefreshCommits
    case datasourceApplies
    case structuralInserts
    case structuralDeletes
    case structuralMoves
}

struct ChatRenderOperationSnapshot: Equatable {
    private let values: [ChatRenderOperation: Int]

    init(values: [ChatRenderOperation: Int]) {
        self.values = values
    }

    subscript(operation: ChatRenderOperation) -> Int {
        values[operation] ?? 0
    }

    var sortedFieldNames: [String] {
        values.keys.map(\.rawValue).sorted()
    }

    var unsafeFieldNames: [String] {
        sortedFieldNames.filter { fieldName in
            let normalized = fieldName
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            return ChatPerformanceMetricSnapshot.privateTokenFragments.contains { token in
                normalized.contains(token)
            }
        }
    }

    var isPrivacySafe: Bool {
        unsafeFieldNames.isEmpty
    }
}

struct ChatRenderOperationBudgetViolation: Equatable {
    let operation: ChatRenderOperation
    let actual: Int
    let maximum: Int
}

/// A deterministic operation-count gate. Timing and frame-time measurements
/// intentionally live outside this type because simulator wall-clock is not a
/// stable CI signal.
struct ChatRenderOperationBudget {
    private let maximums: [ChatRenderOperation: Int]

    init(maximums: [ChatRenderOperation: Int]) {
        precondition(maximums.values.allSatisfy { $0 >= 0 })
        self.maximums = maximums
    }

    func violations(in snapshot: ChatRenderOperationSnapshot) -> [ChatRenderOperationBudgetViolation] {
        ChatRenderOperation.allCases.compactMap { operation in
            guard let maximum = maximums[operation] else {
                return nil
            }
            let actual = snapshot[operation]
            guard actual > maximum else {
                return nil
            }
            return ChatRenderOperationBudgetViolation(
                operation: operation,
                actual: actual,
                maximum: maximum
            )
        }
    }
}

/// Thread-safe deterministic counters for tests and performance diagnostics.
///
/// The API accepts only closed enum values and integer amounts. It cannot retain
/// message bodies, identifiers, URLs, paths, JIDs, or account data.
final class ChatRenderOperationCounter {
    private let lock = NSLock()
    private var enabled: Bool
    private var values: [ChatRenderOperation: Int] = [:]

    init(isEnabled: Bool) {
        self.enabled = isEnabled
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        enabled = isEnabled
        lock.unlock()
    }

    func record(_ operation: ChatRenderOperation) {
        record(operation, by: 1)
    }

    func record(_ operation: ChatRenderOperation, by amount: @autoclosure () -> Int) {
        lock.lock()
        let shouldRecord = enabled
        lock.unlock()

        guard shouldRecord else {
            return
        }

        let resolvedAmount = amount()
        guard resolvedAmount > 0 else {
            return
        }

        lock.lock()
        values[operation, default: 0] += resolvedAmount
        lock.unlock()
    }

    func incrementGauge(_ operation: ChatRenderOperation) {
        lock.lock()
        if enabled {
            values[operation, default: 0] += 1
        }
        lock.unlock()
    }

    func decrementGauge(_ operation: ChatRenderOperation) {
        lock.lock()
        if enabled {
            values[operation] = max(0, (values[operation] ?? 0) - 1)
        }
        lock.unlock()
    }

    func snapshot() -> ChatRenderOperationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ChatRenderOperationSnapshot(values: values)
    }

    func reset() {
        lock.lock()
        values.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
