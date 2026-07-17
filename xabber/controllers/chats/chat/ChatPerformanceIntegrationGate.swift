import Foundation

#if DEBUG || CHAT_PERFORMANCE_LAB
struct ChatPerformanceUITestLaunchDescriptor: Equatable {
    let scale: ChatPerformanceFixtureScale
}

enum ChatPerformanceUITestLaunchPolicy {
    static let launchArgument = "--xabber-chat-performance-fixture"
    static let uiTestMarkerKey = "XABBER_CHAT_PERFORMANCE_UI_TEST"

    static func descriptor(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ChatPerformanceUITestLaunchDescriptor? {
        guard environment[uiTestMarkerKey] == "1",
              environment[AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey] == nil,
              environment[AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey] == nil,
              environment[ChatLiveQASafetyPolicy.modeEnvironmentKey] == nil,
              let flagIndex = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(flagIndex + 1),
              arguments.filter({ $0 == launchArgument }).count == 1,
              let scale = ChatPerformanceFixtureScale(rawValue: arguments[flagIndex + 1]) else {
            return nil
        }

        return ChatPerformanceUITestLaunchDescriptor(scale: scale)
    }
}

enum ChatPerformanceScenarioScrollDirection: Equatable {
    case older
    case newer
}

struct ChatPerformanceScenarioOperationSnapshot: Equatable {
    var fullHistoryEnumerations: Int
    var datasourceApplies: Int
    var forcedLayouts: Int
    var programmaticOffsets: Int
    var delayedCorrections: Int
}

struct ChatPerformanceScenarioState: Equatable {
    let scale: ChatPerformanceFixtureScale
    let logicalMessageCount: Int
    var residentMessageCount: Int
    var operationSnapshot: ChatPerformanceScenarioOperationSnapshot
    var anchorDrift: Double
    var mediaDownloadCount: Int
    var mediaDecodeCount: Int
    var mediaVisibleCacheHitCount: Int
    var optimisticMessageCount: Int
    var editedMessageCount: Int
    var isSkeletonVisible: Bool
    var exactTargetPrimary: String?
    var intermediateLatestFrameCount: Int
    var activeResourcesAreIdle: Bool
}

enum ChatPerformanceScenarioEvent: Equatable {
    case fastScroll(ChatPerformanceScenarioScrollDirection)
    case incomingWhileScrolled
    case optimisticSend
    case editOptimisticMessage
    case deleteOptimisticMessage
    case mediaPrefetch
    case mediaBecameVisible
    case showSkeleton
    case revealSkeleton
    case searchExactTarget(query: String)
}

enum ChatPerformanceScenarioContract {
    static let residentHardLimit = 360
    static let firstFrameMessageCount = 80
    static let exactTargetPrimary = "chat-performance-exact-target"

    static func initial(scale: ChatPerformanceFixtureScale) -> ChatPerformanceScenarioState {
        ChatPerformanceScenarioState(
            scale: scale,
            logicalMessageCount: scale.rowCount,
            residentMessageCount: min(firstFrameMessageCount, scale.rowCount),
            operationSnapshot: ChatPerformanceScenarioOperationSnapshot(
                fullHistoryEnumerations: 0,
                datasourceApplies: 1,
                forcedLayouts: 1,
                programmaticOffsets: 1,
                delayedCorrections: 0
            ),
            anchorDrift: 0,
            mediaDownloadCount: 0,
            mediaDecodeCount: 0,
            mediaVisibleCacheHitCount: 0,
            optimisticMessageCount: 0,
            editedMessageCount: 0,
            isSkeletonVisible: false,
            exactTargetPrimary: nil,
            intermediateLatestFrameCount: 0,
            activeResourcesAreIdle: true
        )
    }

    static func reduce(
        _ state: ChatPerformanceScenarioState,
        event: ChatPerformanceScenarioEvent
    ) -> ChatPerformanceScenarioState {
        var next = state
        next.activeResourcesAreIdle = false

        switch event {
        case .fastScroll:
            next.residentMessageCount = min(residentHardLimit, max(firstFrameMessageCount, state.residentMessageCount))
            next.anchorDrift = 0
        case .incomingWhileScrolled:
            next.residentMessageCount = min(residentHardLimit, state.residentMessageCount + 1)
            next.anchorDrift = 0
        case .optimisticSend:
            next.optimisticMessageCount += 1
            next.residentMessageCount = min(residentHardLimit, state.residentMessageCount + 1)
        case .editOptimisticMessage:
            if next.optimisticMessageCount > 0 {
                next.editedMessageCount += 1
            }
        case .deleteOptimisticMessage:
            if next.optimisticMessageCount > 0 {
                next.optimisticMessageCount -= 1
                next.residentMessageCount = max(0, state.residentMessageCount - 1)
            }
        case .mediaPrefetch:
            if next.mediaDownloadCount == 0 {
                next.mediaDownloadCount = 1
                next.mediaDecodeCount = 1
            }
        case .mediaBecameVisible:
            if next.mediaDownloadCount == 1, next.mediaDecodeCount == 1 {
                next.mediaVisibleCacheHitCount += 1
            }
        case .showSkeleton:
            next.isSkeletonVisible = true
        case .revealSkeleton:
            next.isSkeletonVisible = false
        case .searchExactTarget(let query):
            if query.compare("test", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                next.exactTargetPrimary = exactTargetPrimary
                next.anchorDrift = 0
            }
        }

        next.activeResourcesAreIdle = true
        return next
    }
}

struct ChatPerformanceReleaseSample: Equatable {
    static let reportPrefix = "CHAT_PERF_RELEASE_REPORT "
    static let reportFileName = "chat-performance-release-report.txt"
    static let expectedDatasourceApplies = 42
    // Each probe mutation changes a message row and its deliberately isolated
    // date-separator row. Twenty paging cycles plus the optimistic-send cycle
    // therefore produce 21 * 2 structural items in each direction.
    static let expectedStructuralInserts = 42
    static let expectedStructuralDeletes = 42

    let scale: ChatPerformanceFixtureScale
    let firstStableMilliseconds: Double
    let cycleResidentBytes: [UInt64]
    let optimisticLocalRowMilliseconds: Double
    let state: ChatPerformanceScenarioState
    let releaseOperations: ChatRenderOperationSnapshot

    var cycleCount: Int { cycleResidentBytes.count }

    var residentGrowthPercent: Double {
        guard cycleResidentBytes.count == 20,
              cycleResidentBytes[4] > 0,
              let maximumAfterWarmup = cycleResidentBytes.dropFirst(5).max() else {
            return .infinity
        }
        let baseline = Double(cycleResidentBytes[4])
        return max(0, (Double(maximumAfterWarmup) - baseline) / baseline * 100)
    }

    var passesMemoryPlateauBudget: Bool {
        residentGrowthPercent <= 10
    }

    var passesOptimisticTrendBudget: Bool {
        optimisticLocalRowMilliseconds <= 100
    }

    var passesActualOperationBudgets: Bool {
        releaseOperations[.datasourceApplies] == Self.expectedDatasourceApplies
            && releaseOperations[.structuralInserts] == Self.expectedStructuralInserts
            && releaseOperations[.structuralDeletes] == Self.expectedStructuralDeletes
            && releaseOperations[.structuralMoves] == 0
            && releaseOperations[.reloads] == 0
    }

    var passesDeterministicBudgets: Bool {
        let operations = state.operationSnapshot
        return cycleCount == 20
            && state.residentMessageCount <= ChatPerformanceScenarioContract.residentHardLimit
            && operations.fullHistoryEnumerations == 0
            && operations.forcedLayouts <= 1
            && operations.programmaticOffsets <= 1
            && operations.delayedCorrections == 0
            && abs(state.anchorDrift) <= 1
            && state.activeResourcesAreIdle
            && passesActualOperationBudgets
    }

    func reportLine() throws -> String {
        let operations = state.operationSnapshot
        let payload: [String: Any] = [
            "version": 1,
            "scale": scale.rawValue,
            "logicalMessageCount": state.logicalMessageCount,
            "residentMessageCount": state.residentMessageCount,
            "firstStableMilliseconds": firstStableMilliseconds,
            "cycleCount": cycleCount,
            "residentCycle5Bytes": cycleResidentBytes.count == 20 ? cycleResidentBytes[4] : 0,
            "residentMaxCycles6To20Bytes": cycleResidentBytes.dropFirst(5).max() ?? 0,
            "residentGrowthPercent": residentGrowthPercent,
            "optimisticLocalRowMilliseconds": optimisticLocalRowMilliseconds,
            "fullHistoryEnumerations": operations.fullHistoryEnumerations,
            "datasourceApplies": operations.datasourceApplies,
            "forcedLayouts": operations.forcedLayouts,
            "programmaticOffsets": operations.programmaticOffsets,
            "delayedCorrections": operations.delayedCorrections,
            "anchorDrift": state.anchorDrift,
            "mediaDownloads": state.mediaDownloadCount,
            "mediaDecodes": state.mediaDecodeCount,
            "mediaVisibleCacheHits": state.mediaVisibleCacheHitCount,
            "editedMessages": state.editedMessageCount,
            "actualDatasourceApplies": releaseOperations[.datasourceApplies],
            "actualStructuralInserts": releaseOperations[.structuralInserts],
            "actualStructuralDeletes": releaseOperations[.structuralDeletes],
            "actualStructuralMoves": releaseOperations[.structuralMoves],
            "actualReloads": releaseOperations[.reloads],
            "actualOperationBudgetsPass": passesActualOperationBudgets,
            "deterministicBudgetsPass": passesDeterministicBudgets,
            "memoryPlateauPass": passesMemoryPlateauBudget,
            "optimisticTrendPass": passesOptimisticTrendBudget
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return Self.reportPrefix + json
    }
}

enum ChatLiveQAMode: String, Equatable {
    case readOnly = "read-only"
    case mutation
}

enum ChatLiveQASafetyError: Error, Equatable {
    case modeMismatch
    case deterministicModeMixedWithLive
    case hostedModeMixedWithLive
    case forbiddenSecretTransport(String)
    case messageNotOwnedByRun(String)
}

enum ChatLiveQASafetyPolicy {
    static let modeEnvironmentKey = "XABBER_CHAT_LIVE_QA_MODE"
    private static let forbiddenSecretFragments = [
        "password", "passwd", "credential", "secret", "private_key", "access_token", "refresh_token"
    ]

    static func validate(
        mode: ChatLiveQAMode,
        environment: [String: String],
        launchArguments: [String]
    ) throws {
        guard environment[modeEnvironmentKey] == mode.rawValue else {
            throw ChatLiveQASafetyError.modeMismatch
        }
        guard environment[ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey] == nil,
              !launchArguments.contains(ChatPerformanceUITestLaunchPolicy.launchArgument) else {
            throw ChatLiveQASafetyError.deterministicModeMixedWithLive
        }
        guard environment[AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey] == nil,
              environment[AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey] == nil else {
            throw ChatLiveQASafetyError.hostedModeMixedWithLive
        }

        for key in environment.keys {
            let normalized = key.lowercased()
            if forbiddenSecretFragments.contains(where: normalized.contains) {
                throw ChatLiveQASafetyError.forbiddenSecretTransport(key)
            }
        }
        for argument in launchArguments {
            let normalized = argument.lowercased()
            if forbiddenSecretFragments.contains(where: normalized.contains) {
                throw ChatLiveQASafetyError.forbiddenSecretTransport("launch-argument")
            }
        }
    }
}

struct ChatLiveMutationRegistry: Equatable {
    let runID: String
    let prefix: String
    private(set) var createdMessageIDs: Set<String> = []
    private(set) var deletedMessageIDs: Set<String> = []

    init(runID: String) {
        self.runID = runID
        self.prefix = "chat-perf-qa-\(runID)-"
    }

    mutating func registerCreatedMessage(id: String) {
        guard id.isNotEmpty else { return }
        createdMessageIDs.insert(id)
    }

    func canDelete(messageID: String) -> Bool {
        createdMessageIDs.contains(messageID) && !deletedMessageIDs.contains(messageID)
    }

    mutating func recordDeletion(messageID: String) throws {
        guard canDelete(messageID: messageID) else {
            throw ChatLiveQASafetyError.messageNotOwnedByRun(messageID)
        }
        deletedMessageIDs.insert(messageID)
    }

    var remainingCreatedMessageIDs: [String] {
        createdMessageIDs.subtracting(deletedMessageIDs).sorted()
    }
}
#endif
