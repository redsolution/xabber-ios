import XCTest
@testable import xabber

final class ChatFinalIntegrationGateTests: XCTestCase {
    func testOnboardingLifecycleNeverClearsGlobalCredentials() throws {
        let root = try XCTUnwrap(repositoryRoot())
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/onboarding/OnboardingViewController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(
            source.contains("CredentialsManager.shared.clearKeychain()"),
            "Onboarding may be shown transiently during install/restore and must never erase account credentials"
        )
    }

    func testChatSupportsPortraitAndBothLandscapeOrientations() throws {
        let root = try XCTUnwrap(repositoryRoot())
        let controllerSource = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/messages_kit/Controllers/MessagesViewController.swift"
            ),
            encoding: .utf8
        )
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: root.appendingPathComponent("xabber/Info.plist"))
        )
        let orientations = try XCTUnwrap(
            plist["UISupportedInterfaceOrientations"] as? [String]
        )

        XCTAssertTrue(controllerSource.contains("override var shouldAutorotate: Bool"))
        XCTAssertTrue(controllerSource.contains("return true"))
        XCTAssertEqual(
            Set(orientations),
            Set([
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ])
        )
    }

    func testDeterministicLaunchRequiresExplicitUITestMarkerAndRejectsLiveOrHostedModes() {
        let arguments = ["xabber", "--xabber-chat-performance-fixture", "million"]
        let uiEnvironment = [ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey: "1"]

        XCTAssertEqual(
            ChatPerformanceUITestLaunchPolicy.descriptor(
                arguments: arguments,
                environment: uiEnvironment
            ),
            ChatPerformanceUITestLaunchDescriptor(scale: .million)
        )
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: arguments,
            environment: [:]
        ))
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: arguments,
            environment: uiEnvironment.merging([
                AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1",
                AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey: "1"
            ]) { _, new in new }
        ))
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: arguments,
            environment: uiEnvironment.merging([
                ChatLiveQASafetyPolicy.modeEnvironmentKey: ChatLiveQAMode.readOnly.rawValue
            ]) { _, new in new }
        ))
    }

    func testSmallAndMillionOpenHaveTheSameBoundedFirstFrameAndOperationEnvelope() {
        let small = ChatPerformanceScenarioContract.initial(scale: .small)
        let million = ChatPerformanceScenarioContract.initial(scale: .million)

        XCTAssertEqual(small.logicalMessageCount, 100)
        XCTAssertEqual(million.logicalMessageCount, 1_000_000)
        XCTAssertLessThanOrEqual(small.residentMessageCount, ChatPerformanceScenarioContract.residentHardLimit)
        XCTAssertLessThanOrEqual(million.residentMessageCount, ChatPerformanceScenarioContract.residentHardLimit)
        XCTAssertEqual(small.operationSnapshot, million.operationSnapshot)
        XCTAssertEqual(small.operationSnapshot.fullHistoryEnumerations, 0)
        XCTAssertEqual(small.operationSnapshot.datasourceApplies, 1)
        XCTAssertLessThanOrEqual(small.operationSnapshot.forcedLayouts, 1)
        XCTAssertLessThanOrEqual(small.operationSnapshot.programmaticOffsets, 1)
        XCTAssertEqual(small.operationSnapshot.delayedCorrections, 0)
    }

    func testScriptedScenarioPreservesAnchorAndUsesOneMediaArtifact() {
        var state = ChatPerformanceScenarioContract.initial(scale: .million)

        state = ChatPerformanceScenarioContract.reduce(state, event: .fastScroll(.older))
        state = ChatPerformanceScenarioContract.reduce(state, event: .fastScroll(.newer))
        state = ChatPerformanceScenarioContract.reduce(state, event: .incomingWhileScrolled)
        state = ChatPerformanceScenarioContract.reduce(state, event: .optimisticSend)
        state = ChatPerformanceScenarioContract.reduce(state, event: .editOptimisticMessage)
        state = ChatPerformanceScenarioContract.reduce(state, event: .deleteOptimisticMessage)
        state = ChatPerformanceScenarioContract.reduce(state, event: .mediaPrefetch)
        state = ChatPerformanceScenarioContract.reduce(state, event: .mediaBecameVisible)
        state = ChatPerformanceScenarioContract.reduce(state, event: .showSkeleton)
        state = ChatPerformanceScenarioContract.reduce(state, event: .revealSkeleton)
        state = ChatPerformanceScenarioContract.reduce(state, event: .searchExactTarget(query: "test"))

        XCTAssertLessThanOrEqual(abs(state.anchorDrift), 1)
        XCTAssertEqual(state.mediaDownloadCount, 1)
        XCTAssertEqual(state.mediaDecodeCount, 1)
        XCTAssertEqual(state.mediaVisibleCacheHitCount, 1)
        XCTAssertEqual(state.optimisticMessageCount, 0)
        XCTAssertFalse(state.isSkeletonVisible)
        XCTAssertEqual(state.exactTargetPrimary, ChatPerformanceScenarioContract.exactTargetPrimary)
        XCTAssertEqual(state.intermediateLatestFrameCount, 0)
        XCTAssertEqual(state.operationSnapshot.delayedCorrections, 0)
        XCTAssertTrue(state.activeResourcesAreIdle)
    }

    func testLiveModesAreSeparatedAndMutationRegistryDeletesOnlyRunOwnedIDs() throws {
        XCTAssertNoThrow(try ChatLiveQASafetyPolicy.validate(
            mode: .readOnly,
            environment: [ChatLiveQASafetyPolicy.modeEnvironmentKey: ChatLiveQAMode.readOnly.rawValue],
            launchArguments: []
        ))
        XCTAssertThrowsError(try ChatLiveQASafetyPolicy.validate(
            mode: .mutation,
            environment: [
                ChatLiveQASafetyPolicy.modeEnvironmentKey: ChatLiveQAMode.mutation.rawValue,
                "XABBER_PASSWORD": "forbidden"
            ],
            launchArguments: []
        ))
        XCTAssertThrowsError(try ChatLiveQASafetyPolicy.validate(
            mode: .readOnly,
            environment: [
                ChatLiveQASafetyPolicy.modeEnvironmentKey: ChatLiveQAMode.readOnly.rawValue,
                ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey: "1"
            ],
            launchArguments: []
        ))

        var registry = ChatLiveMutationRegistry(runID: "20260715T120000Z-ABC123")
        XCTAssertTrue(registry.prefix.hasPrefix("chat-perf-qa-"))
        registry.registerCreatedMessage(id: "created-1")
        registry.registerCreatedMessage(id: "created-2")
        XCTAssertTrue(registry.canDelete(messageID: "created-1"))
        XCTAssertFalse(registry.canDelete(messageID: "preexisting"))
        try registry.recordDeletion(messageID: "created-1")
        XCTAssertThrowsError(try registry.recordDeletion(messageID: "preexisting"))
        XCTAssertEqual(registry.remainingCreatedMessageIDs, ["created-2"])
    }

    func testReleaseProbeRequiresTwentyCyclesAndComputesMemoryPlateauWithoutPrivatePayload() throws {
        let state = ChatPerformanceScenarioContract.initial(scale: .million)
        let operationCounter = ChatRenderOperationCounter(isEnabled: true)
        operationCounter.record(.datasourceApplies, by: 42)
        // The probe deliberately crosses a date boundary. Each of its 21
        // append/remove pairs changes both a message row and a date-separator
        // row, so the collection-view diff contains 42 structural items in
        // each direction.
        operationCounter.record(.structuralInserts, by: 42)
        operationCounter.record(.structuralDeletes, by: 42)
        let sample = ChatPerformanceReleaseSample(
            scale: .million,
            firstStableMilliseconds: 24,
            cycleResidentBytes: Array(repeating: 100, count: 5) + Array(repeating: 109, count: 15),
            optimisticLocalRowMilliseconds: 12,
            state: state,
            releaseOperations: operationCounter.snapshot()
        )

        XCTAssertEqual(sample.cycleCount, 20)
        XCTAssertEqual(sample.residentGrowthPercent, 9, accuracy: 0.001)
        XCTAssertTrue(sample.passesDeterministicBudgets)
        XCTAssertTrue(sample.passesActualOperationBudgets)
        XCTAssertTrue(sample.passesMemoryPlateauBudget)
        XCTAssertEqual(
            ChatPerformanceReleaseSample.reportFileName,
            "chat-performance-release-report.txt"
        )

        let report = try sample.reportLine()
        XCTAssertTrue(report.hasPrefix(ChatPerformanceReleaseSample.reportPrefix))
        XCTAssertTrue(report.contains("\"scale\":\"million\""))
        XCTAssertTrue(report.contains("\"actualDatasourceApplies\":42"))
        XCTAssertTrue(report.contains("\"actualStructuralInserts\":42"))
        XCTAssertTrue(report.contains("\"actualStructuralDeletes\":42"))
        XCTAssertTrue(report.contains("\"actualReloads\":0"))
        XCTAssertTrue(report.contains("\"actualOperationBudgetsPass\":true"))
        XCTAssertFalse(report.contains("@"))
        XCTAssertFalse(report.lowercased().contains("messageid"))
        XCTAssertFalse(report.lowercased().contains("body"))
    }

    func testReleaseTraceRunnerRecordsExplicitSimulatorLimitationsAndAllowsProbeToFinish() throws {
        let root = try XCTUnwrap(repositoryRoot())
        let runner = try String(
            contentsOf: root.appendingPathComponent("tools/run_chat_release_performance.sh"),
            encoding: .utf8
        )
        let analyzer = try String(
            contentsOf: root.appendingPathComponent("tools/analyze_chat_release_performance.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(runner.contains("--time-limit 30s"))
        XCTAssertTrue(runner.contains("SWIFT_OPTIMIZATION_LEVEL=-O"))
        XCTAssertTrue(runner.contains("ONLY_ACTIVE_ARCH=YES"))
        XCTAssertTrue(runner.contains("simctl get_app_container"))
        XCTAssertTrue(runner.contains("chat-performance-release-report.txt"))
        XCTAssertTrue(runner.contains("rm -f \"$release_report_path\""))
        XCTAssertTrue(runner.contains("cp \"$release_report_path\" \"$target_stdout\""))
        XCTAssertTrue(runner.contains("Recording of 'Network Connections' is not supported in the Simulator"))
        XCTAssertTrue(runner.contains("network-simulator-unavailable.txt"))
        XCTAssertTrue(analyzer.contains("network_status=\"simulator-unsupported\""))
        XCTAssertTrue(analyzer.contains("hardware-network-gate: not-measured"))
        XCTAssertTrue(analyzer.contains("actualOperationBudgetsPass"))
        XCTAssertTrue(analyzer.contains("actualDatasourceApplies"))
        XCTAssertTrue(analyzer.contains("actualStructuralInserts"))
        XCTAssertTrue(analyzer.contains("actualStructuralDeletes"))
        XCTAssertTrue(analyzer.contains("42/42/42/0/0"))
    }

    func testLiveReportGateRequiresTheFullReadOnlyAndMutationSafetyMatrix() throws {
        let root = try XCTUnwrap(repositoryRoot())
        let runner = try String(
            contentsOf: root.appendingPathComponent("tools/run_chat_live_qa.sh"),
            encoding: .utf8
        )

        for requiredField in [
            "authorized_dialog_only: true",
            "foreign_mutations: 0",
            "logout_reset_delete_account: false",
            "exact_search_target_first_frame: pass",
            "bidirectional_paging: pass",
            "rotation: pass",
            "dynamic_type_largest: pass",
            "background_foreground: pass",
            "network_throttling_recovery: simulator-unsupported",
            "deterministic_network_recovery: pass",
            "network_recovery_tier: deterministic-simulator",
            "optimistic_send_edit_delete: pass",
            "server_delete_effects:",
            "mam_tombstone_effects:",
            "read_marker_effects:"
        ] {
            XCTAssertTrue(runner.contains(requiredField), "missing live gate field: \(requiredField)")
        }
    }

    func testProductionLegacyInventoryAndGoalRunnerOwnFinalGates() throws {
        let root = try XCTUnwrap(repositoryRoot())
        let projectSource = try String(
            contentsOf: root.appendingPathComponent("xabber.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let manifest = try String(
            contentsOf: root.appendingPathComponent("tools/chat_goal_test_manifest.sh"),
            encoding: .utf8
        )
        let runner = try String(
            contentsOf: root.appendingPathComponent("tools/run_chat_goal_tests.sh"),
            encoding: .utf8
        )
        let releaseRunner = try String(
            contentsOf: root.appendingPathComponent("tools/run_chat_release_performance.sh"),
            encoding: .utf8
        )
        let releaseAnalyzer = try String(
            contentsOf: root.appendingPathComponent("tools/analyze_chat_release_performance.sh"),
            encoding: .utf8
        )
        let chatSources = try productionChatSource(root: root)

        XCTAssertTrue(projectSource.contains("com.apple.product-type.bundle.ui-testing"))
        XCTAssertTrue(projectSource.contains("xabberChatPerformanceUITests"))
        XCTAssertTrue(manifest.contains("xabberTests/ChatFinalIntegrationGateTests"))
        XCTAssertTrue(runner.contains("deterministic-ui"))
        XCTAssertTrue(runner.contains("release-performance"))
        XCTAssertTrue(runner.contains("live-read-only"))
        XCTAssertTrue(runner.contains("live-mutation"))
        XCTAssertTrue(releaseRunner.contains("for scale in small million"))
        XCTAssertTrue(releaseRunner.contains("XABBER_CHAT_PERFORMANCE_RELEASE_PROBE"))
        XCTAssertTrue(releaseAnalyzer.contains("simulator-trend-non-gating"))
        XCTAssertTrue(releaseAnalyzer.contains("hardware-frame-gate: not-measured"))
        XCTAssertFalse(chatSources.contains("class ChatPage"))
        XCTAssertFalse(chatSources.contains("struct ChatPage"))
        XCTAssertFalse(chatSources.contains("SubforwardsViewController"))
        XCTAssertFalse(chatSources.contains("InlineCallGridView"))
        XCTAssertFalse(chatSources.contains("VoIPCallMessageCell"))
        XCTAssertFalse(projectSource.contains("SubforwardsViewController+"))
        XCTAssertFalse(projectSource.contains("VoIPCallMessageCell.swift"))
        XCTAssertFalse(chatSources.contains("updateInsets()  // Recompute and apply as above"))
        XCTAssertFalse(chatSources.contains("let formatter = DateFormatter()\n//"))
    }

    func testG20ManifestIncludesEveryPriorTaskVersionedSelector() throws {
        let root = try XCTUnwrap(repositoryRoot())
        let manifest = try String(
            contentsOf: root.appendingPathComponent("tools/chat_goal_test_manifest.sh"),
            encoding: .utf8
        )
        let preflightStart = try XCTUnwrap(manifest.range(
            of: "chat_goal_preflight_selectors() {"
        ))
        let focusedStart = try XCTUnwrap(manifest.range(
            of: "chat_goal_focused_selectors() {"
        ))
        let smokeStart = try XCTUnwrap(manifest.range(
            of: "chat_goal_smoke_selectors() {"
        ))
        let preflightSource = String(manifest[
            preflightStart.lowerBound..<focusedStart.lowerBound
        ])
        let expression = try NSRegularExpression(
            pattern: #"(?ms)^\s+(G(?:\d+[AB]?))\) cat <<'SELECTORS'\n(.*?)\nSELECTORS"#
        )
        let sourceRange = NSRange(
            preflightSource.startIndex..<preflightSource.endIndex,
            in: preflightSource
        )
        var selectorsByTask: [String: Set<String>] = [:]
        for match in expression.matches(in: preflightSource, range: sourceRange) {
            guard let taskRange = Range(match.range(at: 1), in: preflightSource),
                  let selectorsRange = Range(match.range(at: 2), in: preflightSource) else {
                continue
            }
            let task = String(preflightSource[taskRange])
            selectorsByTask[task] = Set(
                preflightSource[selectorsRange]
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { $0.hasPrefix("xabberTests/") }
            )
        }

        let focusedSource = String(manifest[
            focusedStart.lowerBound..<smokeStart.lowerBound
        ])
        let focusedExpression = try NSRegularExpression(
            pattern: #"(?ms)if \[\[ \"\$1\" == \"G(?:\d+[AB]?)\" \]\]; then\s+cat <<'SELECTORS'\n(.*?)\nSELECTORS"#
        )
        let focusedRange = NSRange(
            focusedSource.startIndex..<focusedSource.endIndex,
            in: focusedSource
        )
        var focusedSelectors = Set<String>()
        for match in focusedExpression.matches(in: focusedSource, range: focusedRange) {
            guard let selectorsRange = Range(match.range(at: 1), in: focusedSource) else {
                continue
            }
            focusedSelectors.formUnion(
                focusedSource[selectorsRange]
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { $0.hasPrefix("xabberTests/") }
            )
        }

        let finalSelectors = try XCTUnwrap(selectorsByTask["G20"])
        var requiredSelectors = selectorsByTask
            .filter { $0.key != "G20" }
            .reduce(into: Set<String>()) { result, entry in
                result.formUnion(entry.value)
            }
        requiredSelectors.formUnion(focusedSelectors)
        let missing = requiredSelectors.filter { selector in
            if finalSelectors.contains(selector) {
                return false
            }
            let components = selector.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 2 else {
                return true
            }
            let owningSuite = components.prefix(2).joined(separator: "/")
            return !finalSelectors.contains(owningSuite)
        }.sorted()

        XCTAssertTrue(
            missing.isEmpty,
            "G20 must include every versioned G00-G19 selector; missing: \(missing)"
        )
    }

    private func repositoryRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("xabber.xcodeproj/project.pbxproj").path
            ) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func productionChatSource(root: URL) throws -> String {
        let chatRoot = root.appendingPathComponent("xabber/controllers/chats/chat")
        let enumerator = FileManager.default.enumerator(
            at: chatRoot,
            includingPropertiesForKeys: nil
        )
        let urls = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        return try urls.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
