import Foundation

/// The resident chat resource envelope. These values are deliberately kept in
/// one place so a performance change cannot silently grow an unrelated cache
/// or work queue. Disk-backed location snapshots survive memory pressure;
/// speculative subscriptions are cancelled by the controller instead.
enum ChatPerformanceResourceBudgets {
    static let timelineTargetPageMultiplier = 5
    static let timelineHardPageMultiplier = 6

    static let displayModelCount = 2_048
    static let layoutCount = 2_048

    static let thumbnailCount = 192
    static let thumbnailMemoryBytes = 64 * 1_024 * 1_024
    static let thumbnailConcurrentWork = 4
    static let thumbnailQueuedWork = 48

    static let locationDiskEntryCount = 96
    static let locationDiskBytes = 64 * 1_024 * 1_024
    static let locationTTL: TimeInterval = 7 * 24 * 60 * 60
    static let locationConcurrentWork = 2
    static let locationQueuedWork = 24

    static let generatedAvatarCount = 256
    static let waveformArtifactCount = 256
}

struct ChatMemoryPlateauResult: Equatable {
    let measuredCycleCount: Int
    let minimumResidentBytes: Int
    let maximumResidentBytes: Int
    let growthRatio: Double
    let isWithinBudget: Bool
}

enum ChatMemoryPlateauDiagnostics {
    /// Evaluates the warmed steady-state envelope rather than comparing the
    /// first cold allocation with the final sample. A 20-cycle scenario uses
    /// five warm-up cycles and must remain inside a 10% resident range.
    static func evaluate(
        samples: [Int],
        warmupCycleCount: Int,
        maximumGrowthRatio: Double
    ) -> ChatMemoryPlateauResult {
        let warmupCount = min(max(0, warmupCycleCount), samples.count)
        let measured = Array(samples.dropFirst(warmupCount))
        guard let minimum = measured.min(),
              let maximum = measured.max(),
              minimum >= 0 else {
            return ChatMemoryPlateauResult(
                measuredCycleCount: measured.count,
                minimumResidentBytes: 0,
                maximumResidentBytes: 0,
                growthRatio: 0,
                isWithinBudget: false
            )
        }

        let denominator = Double(max(1, minimum))
        let growthRatio = Double(maximum - minimum) / denominator
        return ChatMemoryPlateauResult(
            measuredCycleCount: measured.count,
            minimumResidentBytes: minimum,
            maximumResidentBytes: maximum,
            growthRatio: growthRatio,
            isWithinBudget: growthRatio <= max(0, maximumGrowthRatio)
        )
    }
}

/// Detached counts only: the snapshot must never retain a controller, session,
/// work item, query token or media subscription while being reported.
struct ChatLifecycleResourceSnapshot: Equatable {
    let timelinePreparations: Int
    let mappingJobs: Int
    let scheduledScrollRequests: Int
    let prefetchResources: Int
    let anchorTransactions: Int
    let anchorQueries: Int
    let anchorTimeouts: Int
    let searchWorkItems: Int
    let retryWorkItems: Int
    let remoteDispatchers: Int
    let activeRemoteQueries: Int
    let historyLoadActivities: Int
    let timers: Int
    let navigationWorkItems: Int
    let observerRegistrations: Int
    let animations: Int

    var activeResourceCount: Int {
        [
            timelinePreparations,
            mappingJobs,
            scheduledScrollRequests,
            prefetchResources,
            anchorTransactions,
            anchorQueries,
            anchorTimeouts,
            searchWorkItems,
            retryWorkItems,
            remoteDispatchers,
            activeRemoteQueries,
            historyLoadActivities,
            timers,
            navigationWorkItems,
            observerRegistrations,
            animations
        ].reduce(0, +)
    }

    var isIdle: Bool {
        activeResourceCount == 0
    }
}
