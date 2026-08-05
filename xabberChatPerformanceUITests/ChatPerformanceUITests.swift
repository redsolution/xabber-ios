import Foundation
import XCTest
import notify

private enum ChatPerformanceArtifactRouteEnvironmentError: Error {
    case unknownMatrixRoute
}

private enum ChatPerformanceArtifactRouteEnvironment {
    static let signpostKey = "XABBER_CHAT_SIGNPOST_EXPORT_PATH"
    static let markerEventKey =
        "XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH"
    private static let matrixRouteCodes: Set<String> = [
        "N01", "N04", "N08", "E01", "E02-content", "E04", "E02-empty",
        "E10", "E11", "X01", "X02", "X03", "P01", "P02", "P04",
        "P09", "P13", "P14", "G02", "G05", "G06", "G07", "V01",
        "V08", "V10"
    ]

    static func routeBoundValues(
        matrixRouteCode: String
    ) throws -> [String: String] {
        guard matrixRouteCodes.contains(matrixRouteCode) else {
            throw ChatPerformanceArtifactRouteEnvironmentError
                .unknownMatrixRoute
        }
        let prefix = "Library/Caches/chat-open-\(matrixRouteCode)"
        return [
            signpostKey: "\(prefix)-signposts.json",
            markerEventKey: "\(prefix)-markers.json"
        ]
    }
}

final class ChatPerformanceUITests: XCTestCase {
    private enum SkeletonAcknowledgementIPC {
        static let tokenLaunchArgument =
            "--xabber-chat-open-skeleton-ack-token"
        static let notificationNamePrefix =
            "com.xabber.codex.chat-open-fixture.skeleton-observed."

        static func notificationName(token: String) -> String {
            notificationNamePrefix + token.lowercased()
        }
    }

    private var app: XCUIApplication!
    private var openScenarioSkeletonAcknowledgementNotificationName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        openScenarioSkeletonAcknowledgementNotificationName = nil
        XCUIDevice.shared.orientation = .portrait
    }

    func testArtifactExportEnvironmentIsInternallyRouteBound() throws {
        XCTAssertEqual(try ChatPerformanceArtifactRouteEnvironment
            .routeBoundValues(matrixRouteCode: "N01"), [
                ChatPerformanceArtifactRouteEnvironment.signpostKey:
                    "Library/Caches/chat-open-N01-signposts.json",
                ChatPerformanceArtifactRouteEnvironment.markerEventKey:
                    "Library/Caches/chat-open-N01-markers.json"
            ])
        XCTAssertThrowsError(try ChatPerformanceArtifactRouteEnvironment
            .routeBoundValues(matrixRouteCode: "N01-r5"))
    }

    func testSmallHistoryOpensWithBoundedFirstFrame() {
        launch(scale: "small")

        let status = waitForReady()
        XCTAssertTrue(status.label.contains("logical=100"))
        XCTAssertTrue(status.label.contains("resident=80"))
        XCTAssertTrue(status.label.contains("applies=1"))
        XCTAssertTrue(status.label.contains("layouts=1"))
        XCTAssertTrue(status.label.contains("offsets=1"))
    }

    func testMillionHistoryOpensWithSameBoundedFirstFrame() {
        launch(scale: "million")

        let status = waitForReady(timeout: 12)
        XCTAssertTrue(status.label.contains("logical=1000000"))
        XCTAssertTrue(status.label.contains("resident=80"))
        XCTAssertTrue(status.label.contains("applies=1"))
        XCTAssertTrue(status.label.contains("layouts=1"))
        XCTAssertTrue(status.label.contains("offsets=1"))
    }

    func testScrollIncomingAndOptimisticSendEditDeleteStayStable() {
        launch(scale: "million")
        _ = waitForReady(timeout: 12)

        let timeline = app.collectionViews["chat.performance.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        timeline.swipeDown(velocity: .fast)
        timeline.swipeUp(velocity: .fast)

        app.buttons["chat.performance.incoming"].tap()
        let composer = app.textViews["chat.composer.text_field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("deterministic optimistic test")
        let send = app.buttons["chat.composer.send_button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        let state = app.staticTexts["chat.performance.state"]
        XCTAssertTrue(waitForLabel(state, containing: "optimistic=1"))
        app.buttons["chat.performance.edit"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "edited=1"))
        app.buttons["chat.performance.delete"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "optimistic=0"))
        XCTAssertTrue(state.label.contains("anchor=0.0"))
    }

    func testRotationReflowsTimelineAndPreservesAnchorWithoutCorrection() {
        launch(scale: "million")
        _ = waitForReady(timeout: 12)
        let timeline = app.collectionViews["chat.performance.timeline"]
        let state = app.staticTexts["chat.performance.state"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))

        XCUIDevice.shared.orientation = .landscapeLeft

        let landscape = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.width > element.frame.height
        }
        let expectation = XCTNSPredicateExpectation(predicate: landscape, object: timeline)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Timeline did not reflow to landscape. device=\(XCUIDevice.shared.orientation.rawValue) app=\(app.frame) timeline=\(timeline.frame)"
        )
        XCTAssertTrue(waitForLabel(state, containing: "anchor=0.0"))
        XCTAssertTrue(state.label.contains("corrections=0"))

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        XCUIDevice.shared.orientation == .landscapeRight
                    },
                    object: XCUIDevice.shared
                )],
                timeout: 5
            ),
            .completed
        )
        XCTAssertTrue(waitForLabel(state, containing: "anchor=0.0"))
        XCTAssertTrue(state.label.contains("corrections=0"))

        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.height > element.frame.width
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: portrait, object: timeline)],
                timeout: 5
            ),
            .completed
        )
    }

    func testMediaSkeletonAndExactSearchRouteAreAtomic() {
        launch(scale: "million")
        _ = waitForReady(timeout: 12)
        let state = app.staticTexts["chat.performance.state"]

        app.buttons["chat.performance.media_prefetch"].tap()
        app.buttons["chat.performance.media_visible"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "media=1/1/1"))

        app.buttons["chat.performance.skeleton"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "skeleton=true"))
        app.buttons["chat.performance.reveal"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "skeleton=false"))

        app.buttons["chat.performance.lastchats_search"].tap()
        let search = app.searchFields["lastchats.performance.search_input"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("test")
        let result = app.cells["lastchats.performance.exact_result"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        XCTAssertTrue(waitForLabel(
            state,
            containing: "target=chat-performance-exact-target"
        ))
    }

    func testChatOpenN01PreloadedLatestVideoRoute() {
        launch(openScenario: "preloaded-latest", matrixRouteCode: "N01")

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "preloaded-latest",
            phase: "content",
            target: "latest",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true
        )
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        XCTAssertEqual(metrics["anchorMilli"], "-")
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenE01ConfirmedEmptyVideoRoute() {
        launch(openScenario: "confirmed-empty", matrixRouteCode: "E01")

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "confirmed-empty",
            phase: "empty",
            target: "empty",
            initialSkeleton: 0,
            realRows: 0,
            datasourceApplies: 1,
            seededMessages: 0,
            seededDurable: true
        )
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertEqual(metrics["anchorMilli"], "-")
    }

    func testChatOpenE02ContentVideoRoute() {
        launch(
            openScenario: "bootstrap-empty-to-content",
            matrixRouteCode: "E02-content"
        )
        assertOpenScenarioSkeletonIsObservable(
            scenario: "bootstrap-empty-to-content"
        )

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "bootstrap-empty-to-content",
            phase: "content",
            target: "latest",
            initialSkeleton: 30,
            realRows: 80,
            datasourceApplies: 2,
            seededMessages: 0,
            seededDurable: false
        )
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        XCTAssertEqual(metrics["anchorMilli"], "-")
    }

    func testChatOpenE04UnsyncedStaleLocalRowsVideoRoute() {
        launch(
            openScenario: "bootstrap-stale-local-to-content",
            matrixRouteCode: "E04"
        )
        assertOpenScenarioSkeletonIsObservable(
            scenario: "bootstrap-stale-local-to-content"
        )

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertCommonOpenMetrics(
            metrics,
            scenario: "bootstrap-stale-local-to-content",
            phase: "content",
            target: "latest",
            initialSkeleton: 30,
            realRows: 80,
            datasourceApplies: 2,
            seededMessages: 320,
            seededDurable: false
        )
        XCTAssertGreaterThan(intMetric("skeletonGeneration", in: metrics), 0)
        XCTAssertEqual(intMetric("stalePreTerminalRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("mixedSkeletonRealFrames", in: metrics), 0)
        XCTAssertGreaterThan(intMetric("heldSkeletonTicks", in: metrics), 0)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 1)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 1)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 1)
        XCTAssertEqual(metrics["cursor"], "latest")
        XCTAssertEqual(intMetric("bootstrapLeaseStarts", in: metrics), 1)
        XCTAssertEqual(intMetric("bootstrapLeaseJoins", in: metrics), 0)
        XCTAssertEqual(intMetric("bootstrapCompleted", in: metrics), 1)
        XCTAssertEqual(intMetric("bootstrapTransports", in: metrics), 1)
        XCTAssertEqual(intMetric("bootstrapRequests", in: metrics), 1)
        XCTAssertEqual(intMetric("bootstrapFinals", in: metrics), 1)
        XCTAssertEqual(intMetric("bootstrapDelivered", in: metrics), 80)
        XCTAssertEqual(intMetric("bootstrapPersisted", in: metrics), 80)
        XCTAssertEqual(metrics["finalNewerEdge"], "true")
        XCTAssertEqual(metrics["finalOlderEnd"], "false")
        XCTAssertEqual(metrics["finalFullArchive"], "false")
        XCTAssertEqual(intMetric("storeQueryBaseline", in: metrics), 0)
        XCTAssertEqual(intMetric("storeQueries", in: metrics), 4)
        XCTAssertEqual(intMetric("storeLifetimeQueries", in: metrics), 4)
        XCTAssertEqual(intMetric("mainThreadStoreQueries", in: metrics), 0)
        XCTAssertEqual(intMetric("fullScans", in: metrics), 0)
        XCTAssertLessThanOrEqual(intMetric("maxCandidates", in: metrics), 80)
        XCTAssertEqual(intMetric("observerActivations", in: metrics), 1)
        XCTAssertGreaterThanOrEqual(
            intMetric("observerRealmQueries", in: metrics),
            1
        )
        XCTAssertLessThanOrEqual(
            intMetric("observerRealmQueries", in: metrics),
            2
        )
        XCTAssertEqual(intMetric("mainThreadObserverRealmQueries", in: metrics), 0)
        XCTAssertEqual(
            intMetric("observerInitialCallbacks", in: metrics),
            intMetric("observerRealmQueries", in: metrics)
        )
        XCTAssertEqual(intMetric("mainThreadObserverInitialCallbacks", in: metrics), 0)
        XCTAssertLessThanOrEqual(
            intMetric("observerMaxInitialCandidates", in: metrics),
            80
        )
        XCTAssertEqual(intMetric("observerMetadataQueries", in: metrics), 0)
        XCTAssertEqual(
            intMetric("mainThreadObserverMetadataQueries", in: metrics),
            0
        )
        XCTAssertEqual(intMetric("observerMetadataFullScans", in: metrics), 0)
        XCTAssertEqual(intMetric("observerCatchUpMutations", in: metrics), 0)
        XCTAssertEqual(intMetric("observerPending", in: metrics), 0)
        XCTAssertEqual(intMetric("transportStarts", in: metrics), 1)
        XCTAssertEqual(intMetric("transportEnvelopes", in: metrics), 80)
        XCTAssertEqual(intMetric("transportIngress", in: metrics), 80)
        XCTAssertGreaterThanOrEqual(intMetric("transportFinals", in: metrics), 2)
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        XCTAssertEqual(metrics["anchorMilli"], "-")
    }

    func testChatOpenP01NotificationExactLocalVideoRoute() {
        launch(openScenario: "notification-exact-local", matrixRouteCode: "P01")

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "notification-exact-local",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true,
            expectedHighlight: true
        )
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 500)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenX01SearchExactLocalVideoRoute() {
        launch(openScenario: "search-exact-local", matrixRouteCode: "X01")

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "search-exact-local",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true,
            expectedHighlight: true
        )
        XCTAssertEqual(metrics["source"], "search")
        XCTAssertEqual(metrics["markReadOnVisible"], "false")
        XCTAssertEqual(intMetric("targetOrdinal", in: metrics), 160)
        XCTAssertEqual(intMetric("targetMatches", in: metrics), 1)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 0)
        XCTAssertEqual(metrics["cursor"], "none")
        XCTAssertEqual(intMetric("stalePreTerminalRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("mixedSkeletonRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertEqual(intMetric("corrections", in: metrics), 0)
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 1_000)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenG05KnownGapMissingTargetVideoRoute() {
        launch(openScenario: "known-gap-missing-target", matrixRouteCode: "G05")
        assertOpenScenarioSkeletonIsObservable(
            scenario: "known-gap-missing-target"
        )

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "known-gap-missing-target",
            phase: "content",
            target: "anchor",
            initialSkeleton: 30,
            realRows: 80,
            datasourceApplies: 2,
            seededMessages: 160,
            seededDurable: true
        )
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 500)
        assertPhaseSeparatedRemoteStoreProof(
            metrics,
            expectedTerminalQueries: 3
        )
        XCTAssertEqual(intMetric("initialArchiveRequests", in: metrics), 3)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 5)
        XCTAssertEqual(intMetric("postInitialArchiveRequests", in: metrics), 2)
        XCTAssertEqual(intMetric("initialGapRequests", in: metrics), 2)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 4)
        XCTAssertEqual(intMetric("postInitialGapRequests", in: metrics), 2)
        XCTAssertEqual(intMetric("transportStarts", in: metrics), 3)
        XCTAssertGreaterThanOrEqual(intMetric("transportFinals", in: metrics), 10)
        XCTAssertEqual(intMetric("mainThreadStoreQueries", in: metrics), 0)
        XCTAssertEqual(intMetric("fullScans", in: metrics), 0)
        XCTAssertLessThanOrEqual(intMetric("maxCandidates", in: metrics), 80)
        XCTAssertEqual(metrics["preparedOnMain"], "false")
        XCTAssertEqual(metrics["mappedOnMain"], "false")
    }

    func testChatOpenN04UnreadBoundaryLocalVideoRoute() {
        launch(openScenario: "unread-boundary-local", matrixRouteCode: "N04")

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "unread-boundary-local",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true
        )
        XCTAssertEqual(metrics["source"], "initial-unread-boundary")
        XCTAssertEqual(metrics["highlight"], "false")
        XCTAssertEqual(intMetric("targetOrdinal", in: metrics), 160)
        XCTAssertEqual(intMetric("targetMatches", in: metrics), 1)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 0)
        XCTAssertEqual(metrics["cursor"], "none")
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 1_000)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenN08SavedPositionLocalVideoRoute() {
        launch(openScenario: "saved-position-local", matrixRouteCode: "N08")

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "saved-position-local",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true
        )
        XCTAssertEqual(metrics["source"], "saved-visible-position")
        XCTAssertEqual(metrics["highlight"], "false")
        XCTAssertEqual(intMetric("targetOrdinal", in: metrics), 160)
        XCTAssertEqual(intMetric("targetMatches", in: metrics), 1)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 0)
        XCTAssertEqual(metrics["cursor"], "none")
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 1_000)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenG02LatestWithUnrelatedOlderGapVideoRoute() {
        launch(
            openScenario: "latest-with-unrelated-older-gap",
            matrixRouteCode: "G02"
        )

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "latest-with-unrelated-older-gap",
            phase: "content",
            target: "latest",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 160,
            seededDurable: true
        )
        XCTAssertEqual(metrics["source"], "default")
        XCTAssertEqual(metrics["highlight"], "false")
        XCTAssertEqual(metrics["targetOrdinal"], "-")
        XCTAssertEqual(intMetric("targetMatches", in: metrics), 0)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 1)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 0)
        XCTAssertEqual(metrics["cursor"], "none")
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        XCTAssertEqual(metrics["anchorMilli"], "-")
        XCTAssertEqual(intMetric("corrections", in: metrics), 0)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenE02EmptyVideoRoute() {
        launch(
            openScenario: "bootstrap-empty-to-trusted-empty",
            matrixRouteCode: "E02-empty"
        )
        assertOpenScenarioSkeletonIsObservable(
            scenario: "bootstrap-empty-to-trusted-empty"
        )

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "bootstrap-empty-to-trusted-empty",
            phase: "empty",
            target: "empty",
            initialSkeleton: 30,
            realRows: 0,
            datasourceApplies: 2,
            seededMessages: 0,
            seededDurable: false
        )
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 1)
        XCTAssertEqual(metrics["cursor"], "latest")
        XCTAssertEqual(metrics["retry"], "false")
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertEqual(metrics["anchorMilli"], "-")
    }

    func testChatOpenE10HeldBootstrapWatchdogVideoRoute() {
        launch(
            openScenario: "bootstrap-held-over-watchdog",
            matrixRouteCode: "E10"
        )
        assertOpenScenarioSkeletonIsObservable(
            scenario: "bootstrap-held-over-watchdog"
        )

        let metrics = waitForOpenScenarioStable(timeout: 22)
        assertSkeletonTerminalMetrics(
            metrics,
            scenario: "bootstrap-held-over-watchdog",
            phase: "skeleton",
            target: "latest",
            initialOffsetMutations: 1,
            retryVisible: false
        )
        XCTAssertGreaterThanOrEqual(
            intMetric("skeletonDwellMillis", in: metrics),
            5_000
        )
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 1)
        XCTAssertEqual(metrics["cursor"], "latest")
        XCTAssertEqual(intMetric("bootstrapCancelled", in: metrics), 1)
    }

    func testChatOpenE11TypedFailureRetryVideoRoute() {
        launch(
            openScenario: "bootstrap-terminal-failure-retry",
            matrixRouteCode: "E11"
        )
        assertOpenScenarioSkeletonIsObservable(
            scenario: "bootstrap-terminal-failure-retry"
        )

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertSkeletonTerminalMetrics(
            metrics,
            scenario: "bootstrap-terminal-failure-retry",
            phase: "failed",
            target: "empty",
            initialOffsetMutations: 1,
            retryVisible: true
        )
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 1)
        XCTAssertEqual(metrics["cursor"], "latest")
        XCTAssertEqual(intMetric("bootstrapFailed", in: metrics), 1)
    }

    func testChatOpenX02SearchExactLocalOutsideWindowVideoRoute() {
        launch(
            openScenario: "search-exact-local-outside-window",
            matrixRouteCode: "X02"
        )

        let metrics = waitForOpenScenarioStable()
        assertCommonOpenMetrics(
            metrics,
            scenario: "search-exact-local-outside-window",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true,
            expectedHighlight: true
        )
        assertExactAnchorProof(
            metrics,
            source: "search",
            targetOrdinal: 40,
            highlight: true,
            archiveRequests: 0,
            gapRequests: 0,
            cursor: "none"
        )
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenX03SearchExactRemoteVideoRoute() {
        launch(openScenario: "search-exact-remote", matrixRouteCode: "X03")
        assertOpenScenarioSkeletonIsObservable(
            scenario: "search-exact-remote"
        )

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertRemoteExactRouteProof(
            metrics,
            scenario: "search-exact-remote",
            source: "search",
            highlight: true,
            seededMessages: 0,
            seededDurable: false,
            gapRequests: 0
        )
    }

    func testChatOpenP02NotificationExactRemoteVideoRoute() {
        launch(openScenario: "notification-exact-remote", matrixRouteCode: "P02")
        assertOpenScenarioSkeletonIsObservable(
            scenario: "notification-exact-remote"
        )

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertRemoteExactRouteProof(
            metrics,
            scenario: "notification-exact-remote",
            source: "push-notification",
            highlight: true,
            seededMessages: 0,
            seededDurable: false,
            gapRequests: 0
        )
    }

    func testChatOpenP04ColdPushExactVideoRoute() {
        launch(openScenario: "cold-push-exact", matrixRouteCode: "P04")
        let state = assertOpenScenarioSkeletonIsObservable(
            scenario: "cold-push-exact",
            acknowledge: false
        )
        XCTAssertTrue(waitForLabel(
            state,
            containing: "hostColdConsumesAfterStable=0"
        ))
        assertRouteHostFields(
            metricsFromLabel(state.label),
            coldPendingBeforeRoot: 1,
            coldConsumesAfterStable: 0
        )
        postOpenScenarioSkeletonAcknowledgement()

        let metrics = waitForOpenScenarioStable(timeout: 18)
        assertRemoteExactRouteProof(
            metrics,
            scenario: "cold-push-exact",
            source: "push-notification",
            highlight: true,
            seededMessages: 0,
            seededDurable: false,
            gapRequests: 0
        )
        assertRouteHostFields(
            metrics,
            coldPendingBeforeRoot: 1,
            coldConsumesAfterStable: 1
        )
    }

    func testChatOpenP13DeletedMentionAdvancesVideoRoute() {
        launch(openScenario: "mention-deleted-advance", matrixRouteCode: "P13")

        let source = app.otherElements[
            "chat-performance-p13-notifications-screen"
        ]
        XCTAssertTrue(source.waitForExistence(timeout: 4))
        let row = app.cells[
            "chat-performance-p13-deleted-mention-row"
        ]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.isHittable)
        row.tap()

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertCommonOpenMetrics(
            metrics,
            scenario: "mention-deleted-advance",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true,
            expectedHighlight: true
        )
        XCTAssertEqual(metrics["source"], "mention-notification")
        XCTAssertEqual(metrics["markReadOnVisible"], "true")
        XCTAssertEqual(intMetric("targetOrdinal", in: metrics), 160)
        XCTAssertEqual(intMetric("targetMatches", in: metrics), 1)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 0)
        XCTAssertEqual(metrics["cursor"], "none")
        XCTAssertEqual(intMetric("stalePreTerminalRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("mixedSkeletonRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertEqual(intMetric("corrections", in: metrics), 0)
        XCTAssertEqual(metrics["hostKind"], "notifications-deleted-mention")
        XCTAssertEqual(metrics["hostP13RowVisibleBeforeTap"], "true")
        XCTAssertEqual(intMetric("hostP13RowTaps", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP13Attempts", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP13Invalidations", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP13Advances", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP13Unavailable", in: metrics), 0)
        XCTAssertEqual(intMetric("hostP13SelectedNext", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP13UnrelatedPreserved", in: metrics), 1)
        XCTAssertEqual(metrics["hostRoot"], "true")
        XCTAssertEqual(intMetric("hostRouteAttempts", in: metrics), 1)
        XCTAssertEqual(intMetric("hostNativePushes", in: metrics), 1)
        XCTAssertEqual(metrics["hostOpaqueBeforeRow"], "true")
        XCTAssertEqual(intMetric("hostLastChatsExposures", in: metrics), 0)
        XCTAssertEqual(intMetric("hostAccountMaterializations", in: metrics), 1)
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 1_000)
        assertLocalRouteProductionProof(metrics)

        // Take a second cross-process AX snapshot after XCTest has drained the
        // app's current main-loop work. P13 must still expose the live terminal
        // receipt; an immutable dictionary captured before a late duplicate is
        // not sufficient evidence.
        let liveTerminal = app.staticTexts["chat.open.fixture.stable"]
        XCTAssertTrue(liveTerminal.waitForExistence(timeout: 2))
        _ = liveTerminal.screenshot()
        let liveMetrics = metricsFromLabel(liveTerminal.label)
        XCTAssertEqual(liveMetrics["scenario"], "mention-deleted-advance")
        XCTAssertEqual(liveMetrics["phase"], "content")
        XCTAssertEqual(liveMetrics["stable"], "true")
        XCTAssertEqual(intMetric("receipt", in: liveMetrics), 1)
        XCTAssertEqual(intMetric("hostP13Attempts", in: liveMetrics), 1)
    }

    func testChatOpenP14LastChatsSeededMentionVideoRoute() {
        launch(
            openScenario: "last-chats-seeded-mention-exact",
            matrixRouteCode: "P14"
        )

        let source = app.otherElements[
            "chat-performance-last-chats-screen"
        ]
        XCTAssertTrue(source.waitForExistence(timeout: 4))
        let row = app.cells["chat-performance-p14-mention-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        XCTAssertTrue(row.isHittable)
        row.tap()

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertCommonOpenMetrics(
            metrics,
            scenario: "last-chats-seeded-mention-exact",
            phase: "content",
            target: "anchor",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true,
            expectedHighlight: false
        )
        XCTAssertEqual(metrics["source"], "mention-notification")
        XCTAssertEqual(metrics["markReadOnVisible"], "true")
        XCTAssertEqual(intMetric("targetOrdinal", in: metrics), 160)
        XCTAssertEqual(intMetric("targetMatches", in: metrics), 1)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0)
        XCTAssertEqual(intMetric("archiveRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("gapRequests", in: metrics), 0)
        XCTAssertEqual(metrics["cursor"], "none")
        XCTAssertEqual(intMetric("stalePreTerminalRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("mixedSkeletonRealFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertEqual(intMetric("corrections", in: metrics), 0)
        XCTAssertEqual(metrics["hostKind"], "last-chats-seeded-mention")
        XCTAssertEqual(metrics["hostP14RowVisibleBeforeTap"], "true")
        XCTAssertEqual(intMetric("hostP14RowTaps", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP14PendingBeforeTap", in: metrics), 0)
        XCTAssertEqual(intMetric("hostP14AdmissionsBeforeTap", in: metrics), 0)
        XCTAssertEqual(intMetric("hostP14Admissions", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP14AdmissionsBeforeViewLoad", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP14GroupProofs", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP14ExplicitRequests", in: metrics), 1)
        XCTAssertEqual(intMetric("hostP14UnreadRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("hostP14SavedRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("hostP14LatestRequests", in: metrics), 0)
        XCTAssertEqual(intMetric("mentionUnreadFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("mentionSavedFrames", in: metrics), 0)
        XCTAssertEqual(intMetric("mentionReadEager", in: metrics), 0)
        XCTAssertEqual(intMetric("mentionReadScheduled", in: metrics), 1)
        XCTAssertEqual(intMetric("mentionReadCommitted", in: metrics), 1)
        XCTAssertEqual(intMetric("mentionReadFlushes", in: metrics), 1)
        XCTAssertEqual(metrics["mentionUnreadBeforeTap"], "true")
        XCTAssertEqual(metrics["mentionUnreadAtAdmission"], "true")
        XCTAssertEqual(metrics["mentionUnreadAtInitialCommit"], "true")
        XCTAssertEqual(metrics["mentionReadAtTerminal"], "true")
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 1_000)
        assertRouteHostFields(
            metrics,
            coldPendingBeforeRoot: 0,
            coldConsumesAfterStable: 0
        )
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenP09NotificationKnownGapTargetVideoRoute() {
        launch(
            openScenario: "notification-known-gap-target",
            matrixRouteCode: "P09"
        )
        assertOpenScenarioSkeletonIsObservable(
            scenario: "notification-known-gap-target"
        )

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertRemoteExactRouteProof(
            metrics,
            scenario: "notification-known-gap-target",
            source: "push-notification",
            highlight: true,
            seededMessages: 160,
            seededDurable: true,
            gapRequests: 2
        )
    }

    func testChatOpenG06OlderCrossingGapVideoRoute() {
        launch(openScenario: "older-crossing-gap", matrixRouteCode: "G06")
        tapOpenScenarioPostInitialAction(
            scenario: "older-crossing-gap"
        )

        let metrics = waitForOpenScenarioStable(timeout: 18)
        assertInteractiveGapRouteProof(
            metrics,
            scenario: "older-crossing-gap",
            target: "latest",
            expectedLatestCommits: 1,
            expectedCursor: "before",
            expectedArchiveRequests: 1,
            expectedGapRequests: 1,
            expectedTransportStarts: 1,
            minimumTransportFinals: 2
        )
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
    }

    func testChatOpenG07NewerCrossingGapVideoRoute() {
        launch(openScenario: "newer-crossing-gap", matrixRouteCode: "G07")
        tapOpenScenarioPostInitialAction(
            scenario: "newer-crossing-gap"
        )

        let metrics = waitForOpenScenarioStable(timeout: 18)
        assertInteractiveGapRouteProof(
            metrics,
            scenario: "newer-crossing-gap",
            target: "anchor",
            expectedLatestCommits: 0,
            expectedCursor: "after",
            expectedArchiveRequests: 3,
            expectedGapRequests: 3,
            expectedTransportStarts: 2,
            minimumTransportFinals: 6
        )
        XCTAssertEqual(metrics["bottomMilli"], "-")
        XCTAssertLessThanOrEqual(intMetric("anchorMilli", in: metrics), 1_000)
    }

    func testChatOpenV01LastChatsAnimatedPushVideoRoute() {
        launch(openScenario: "last-chats-animated-push", matrixRouteCode: "V01")

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertCommonOpenMetrics(
            metrics,
            scenario: "last-chats-animated-push",
            phase: "content",
            target: "latest",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true
        )
        assertRouteHostFields(
            metrics,
            coldPendingBeforeRoot: 0,
            coldConsumesAfterStable: 0
        )
        XCTAssertEqual(intMetric("postInteractions", in: metrics), 1)
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenV08RotationRealPipelineVideoRoute() {
        launch(openScenario: "rotation-real-pipeline", matrixRouteCode: "V08")
        waitForOpenScenarioPostInitialReadiness(
            scenario: "rotation-real-pipeline"
        )
        let timeline = app.collectionViews["chat.performance.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForTimeline(timeline, portrait: false))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForTimeline(timeline, portrait: true))

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertCommonOpenMetrics(
            metrics,
            scenario: "rotation-real-pipeline",
            phase: "content",
            target: "latest",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true
        )
        XCTAssertEqual(intMetric("postInteractions", in: metrics), 1)
        XCTAssertEqual(intMetric("rotations", in: metrics), 2)
        let rawOffsetMutations = intMetric(
            "rawOffsetMutations",
            in: metrics
        )
        let initialPositioningOffsets = intMetric(
            "initialPositioningOffsets",
            in: metrics
        )
        let rotationOwnedOffsets = intMetric(
            "rotationOwnedOffsets",
            in: metrics
        )
        XCTAssertEqual(rawOffsetMutations, 3)
        XCTAssertEqual(initialPositioningOffsets, 1)
        XCTAssertEqual(rotationOwnedOffsets, 2)
        XCTAssertEqual(
            rawOffsetMutations,
            initialPositioningOffsets + rotationOwnedOffsets
        )
        XCTAssertEqual(intMetric("offsetMutations", in: metrics), 1)
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        assertLocalRouteProductionProof(metrics)
    }

    func testChatOpenV10BackgroundForegroundVideoRoute() {
        launch(
            openScenario: "committed-content-background-foreground",
            matrixRouteCode: "V10"
        )
        waitForOpenScenarioPostInitialReadiness(
            scenario: "committed-content-background-foreground"
        )

        XCUIDevice.shared.press(.home)
        app.activate()

        let metrics = waitForOpenScenarioStable(timeout: 16)
        assertCommonOpenMetrics(
            metrics,
            scenario: "committed-content-background-foreground",
            phase: "content",
            target: "latest",
            initialSkeleton: 0,
            realRows: 80,
            datasourceApplies: 1,
            seededMessages: 320,
            seededDurable: true
        )
        XCTAssertEqual(intMetric("postInteractions", in: metrics), 1)
        XCTAssertEqual(intMetric("backgrounds", in: metrics), 1)
        XCTAssertEqual(intMetric("foregrounds", in: metrics), 1)
        XCTAssertLessThanOrEqual(intMetric("bottomMilli", in: metrics), 500)
        assertLocalRouteProductionProof(metrics)
    }

    private func launch(scale: String) {
        app = XCUIApplication()
        app.launchArguments = ["--xabber-chat-performance-fixture", scale]
        app.launchEnvironment = ["XABBER_CHAT_PERFORMANCE_UI_TEST": "1"]
        app.launch()
    }

    private func launch(
        openScenario: String,
        matrixRouteCode: String
    ) {
        let acknowledgementToken = UUID().uuidString.lowercased()
        openScenarioSkeletonAcknowledgementNotificationName =
            SkeletonAcknowledgementIPC.notificationName(
                token: acknowledgementToken
            )
        app = XCUIApplication()
        app.launchArguments = [
            "--xabber-chat-performance-fixture",
            "small",
            "--xabber-chat-open-scenario",
            openScenario,
            SkeletonAcknowledgementIPC.tokenLaunchArgument,
            acknowledgementToken
        ]
        var launchEnvironment = ["XABBER_CHAT_PERFORMANCE_UI_TEST": "1"]
        do {
            launchEnvironment.merge(
                try ChatPerformanceArtifactRouteEnvironment.routeBoundValues(
                    matrixRouteCode: matrixRouteCode
                )
            ) { _, forwarded in forwarded }
        } catch {
            XCTFail("Invalid closed artifact route contract: \(error)")
            return
        }
        app.launchEnvironment = launchEnvironment
        app.launch()
    }

    @discardableResult
    private func assertOpenScenarioSkeletonIsObservable(
        scenario: String,
        acknowledge: Bool = true
    ) -> XCUIElement {
        let state = app.staticTexts["chat.open.fixture.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForLabel(state, containing: "scenario=\(scenario)"))
        XCTAssertTrue(waitForLabel(state, containing: "phase=skeleton"))
        XCTAssertTrue(waitForLabel(state, containing: "skeleton=30"))
        if acknowledge {
            postOpenScenarioSkeletonAcknowledgement()
        }
        return state
    }

    private func postOpenScenarioSkeletonAcknowledgement(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let notificationName =
                openScenarioSkeletonAcknowledgementNotificationName else {
            XCTFail("Missing per-launch skeleton acknowledgement name", file: file, line: line)
            return
        }
        openScenarioSkeletonAcknowledgementNotificationName = nil
        let status = notificationName.withCString { notify_post($0) }
        XCTAssertEqual(status, 0, file: file, line: line)
    }

    private func waitForOpenScenarioStable(
        timeout: TimeInterval = 12
    ) -> [String: String] {
        let stable = app.staticTexts["chat.open.fixture.stable"]
        XCTAssertTrue(stable.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabel(stable, containing: "stable=true", timeout: timeout))
        let label = stable.label
        ["@invalid", "owner=", "jid=", "messageId=", "body="].forEach {
            XCTAssertFalse(label.contains($0), "Accessibility receipt exposed private field \($0)")
        }
        return Dictionary(uniqueKeysWithValues: label.split(separator: " ").compactMap { field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        })
    }

    private func metricsFromLabel(_ label: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: label.split(separator: " ").compactMap {
            field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        })
    }

    private func assertExactAnchorProof(
        _ metrics: [String: String],
        source: String,
        targetOrdinal: Int,
        highlight: Bool,
        archiveRequests: Int,
        gapRequests: Int,
        cursor: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(metrics["source"], source, file: file, line: line)
        XCTAssertEqual(
            metrics["highlight"],
            String(highlight),
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("targetOrdinal", in: metrics, file: file, line: line),
            targetOrdinal,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("targetMatches", in: metrics, file: file, line: line),
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("latestCommits", in: metrics, file: file, line: line),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("archiveLeases", in: metrics, file: file, line: line),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("archiveRequests", in: metrics, file: file, line: line),
            archiveRequests,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("gapRequests", in: metrics, file: file, line: line),
            gapRequests,
            file: file,
            line: line
        )
        XCTAssertEqual(metrics["cursor"], cursor, file: file, line: line)
        XCTAssertEqual(metrics["bottomMilli"], "-", file: file, line: line)
        XCTAssertLessThanOrEqual(
            intMetric("anchorMilli", in: metrics, file: file, line: line),
            1_000,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("postCommitOffsets", in: metrics, file: file, line: line),
            0,
            file: file,
            line: line
        )
    }

    private func assertRemoteExactRouteProof(
        _ metrics: [String: String],
        scenario: String,
        source: String,
        highlight: Bool,
        seededMessages: Int,
        seededDurable: Bool,
        gapRequests: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertCommonOpenMetrics(
            metrics,
            scenario: scenario,
            phase: "content",
            target: "anchor",
            initialSkeleton: 30,
            realRows: 80,
            datasourceApplies: 2,
            seededMessages: seededMessages,
            seededDurable: seededDurable,
            expectedHighlight: highlight
        )
        assertExactAnchorProof(
            metrics,
            source: source,
            targetOrdinal: 160,
            highlight: highlight,
            archiveRequests: 5,
            gapRequests: gapRequests * 2,
            cursor: "around-target",
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "initialArchiveRequests",
                in: metrics,
                file: file,
                line: line
            ),
            3,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "postInitialArchiveRequests",
                in: metrics,
                file: file,
                line: line
            ),
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "initialGapRequests",
                in: metrics,
                file: file,
                line: line
            ),
            gapRequests,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "postInitialGapRequests",
                in: metrics,
                file: file,
                line: line
            ),
            gapRequests,
            file: file,
            line: line
        )
        assertPhaseSeparatedRemoteStoreProof(
            metrics,
            expectedTerminalQueries: 3,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("mainThreadStoreQueries", in: metrics, file: file, line: line),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("fullScans", in: metrics, file: file, line: line),
            0,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            intMetric("maxCandidates", in: metrics, file: file, line: line),
            80,
            file: file,
            line: line
        )
        XCTAssertEqual(metrics["preparedOnMain"], "false", file: file, line: line)
        XCTAssertEqual(metrics["mappedOnMain"], "false", file: file, line: line)
        XCTAssertEqual(
            intMetric("transportStarts", in: metrics, file: file, line: line),
            3,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            intMetric("transportFinals", in: metrics, file: file, line: line),
            10,
            file: file,
            line: line
        )
    }

    private func assertPhaseSeparatedRemoteStoreProof(
        _ metrics: [String: String],
        expectedTerminalQueries: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedInitialQueries = 2
        XCTAssertEqual(
            intMetric("initialStoreQueries", in: metrics, file: file, line: line),
            expectedInitialQueries,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("storeQueries", in: metrics, file: file, line: line),
            expectedTerminalQueries,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "storeLifetimeQueries",
                in: metrics,
                file: file,
                line: line
            ),
            expectedTerminalQueries,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "blockingInitialStoreQueries",
                in: metrics,
                file: file,
                line: line
            ),
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "postInitialStoreQueries",
                in: metrics,
                file: file,
                line: line
            ),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            expectedInitialQueries +
                intMetric(
                    "blockingInitialStoreQueries",
                    in: metrics,
                    file: file,
                    line: line
                ) +
                intMetric(
                    "postInitialStoreQueries",
                    in: metrics,
                    file: file,
                    line: line
                ),
            expectedTerminalQueries,
            "phase counts must account for the complete route lifetime",
            file: file,
            line: line
        )

        let initialOperations = storeOperationMetrics(
            "initialStoreOps",
            in: metrics,
            file: file,
            line: line
        )
        XCTAssertEqual(
            initialOperations,
            ["message-window": 1, "post-bootstrap": 1],
            file: file,
            line: line
        )
        XCTAssertEqual(
            storeOperationMetrics(
                "blockingInitialStoreOps",
                in: metrics,
                file: file,
                line: line
            ),
            ["post-bootstrap": 1],
            file: file,
            line: line
        )
        let terminalOperations = storeOperationMetrics(
            "terminalStoreOps",
            in: metrics,
            file: file,
            line: line
        )
        XCTAssertEqual(
            terminalOperations,
            ["message-window": 1, "post-bootstrap": 2],
            file: file,
            line: line
        )

        let postInitialOperations = storeOperationMetrics(
            "postInitialStoreOps",
            in: metrics,
            file: file,
            line: line
        )
        XCTAssertEqual(
            postInitialOperations,
            [:],
            file: file,
            line: line
        )
    }

    private func storeOperationMetrics(
        _ key: String,
        in metrics: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String: Int] {
        guard let rawValue = metrics[key] else {
            XCTFail("Missing \(key) metric", file: file, line: line)
            return [:]
        }
        guard rawValue != "none" else { return [:] }
        var result: [String: Int] = [:]
        for rawField in rawValue.split(separator: ",") {
            let pair = rawField.split(separator: ":", maxSplits: 1)
            guard pair.count == 2,
                  let count = Int(pair[1]),
                  count > 0 else {
                XCTFail(
                    "Malformed \(key) operation field: \(rawField)",
                    file: file,
                    line: line
                )
                continue
            }
            result[String(pair[0]), default: 0] += count
        }
        return result
    }

    private func assertSkeletonTerminalMetrics(
        _ metrics: [String: String],
        scenario: String,
        phase: String,
        target: String,
        initialOffsetMutations: Int,
        retryVisible: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(metrics["scenario"], scenario, file: file, line: line)
        XCTAssertEqual(metrics["phase"], phase, file: file, line: line)
        XCTAssertEqual(metrics["target"], target, file: file, line: line)
        XCTAssertEqual(intMetric("initialSkeleton", in: metrics), 30, file: file, line: line)
        XCTAssertEqual(intMetric("skeleton", in: metrics), 30, file: file, line: line)
        XCTAssertEqual(intMetric("real", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(intMetric("applies", in: metrics), 1, file: file, line: line)
        XCTAssertEqual(intMetric("firstContent", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(intMetric("visualCommits", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(intMetric("blankFrames", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(
            intMetric("offsetMutations", in: metrics),
            initialOffsetMutations,
            file: file,
            line: line
        )
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(intMetric("corrections", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(metrics["retry"], String(retryVisible), file: file, line: line)
        XCTAssertEqual(metrics["skeletonIdentityStable"], "true", file: file, line: line)
        XCTAssertEqual(metrics["skeletonGeometryStable"], "true", file: file, line: line)
        XCTAssertEqual(intMetric("receipt", in: metrics), 1, file: file, line: line)
        XCTAssertEqual(metrics["stable"], "true", file: file, line: line)
        XCTAssertEqual(metrics["storageLease"], "true", file: file, line: line)
        XCTAssertEqual(metrics["storageEphemeral"], "true", file: file, line: line)
        XCTAssertEqual(intMetric("seeded", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(metrics["seededDurable"], "false", file: file, line: line)
        XCTAssertEqual(intMetric("fixtureRealmQueriesAfterAdmission", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(intMetric("activeWork", in: metrics), 0, file: file, line: line)
    }

    private func assertInteractiveGapRouteProof(
        _ metrics: [String: String],
        scenario: String,
        target: String,
        expectedLatestCommits: Int,
        expectedCursor: String,
        expectedArchiveRequests: Int,
        expectedGapRequests: Int,
        expectedTransportStarts: Int,
        minimumTransportFinals: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertCommonOpenMetrics(
            metrics,
            scenario: scenario,
            phase: "content",
            target: target,
            initialSkeleton: 0,
            realRows: 160,
            datasourceApplies: 2,
            seededMessages: 160,
            seededDurable: true
        )
        XCTAssertEqual(intMetric("archiveLeases", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(
            intMetric("archiveRequests", in: metrics),
            expectedArchiveRequests,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric("gapRequests", in: metrics),
            expectedGapRequests,
            file: file,
            line: line
        )
        XCTAssertEqual(metrics["cursor"], expectedCursor, file: file, line: line)
        XCTAssertEqual(intMetric("latestCommits", in: metrics), expectedLatestCommits, file: file, line: line)
        XCTAssertEqual(intMetric("postInteractions", in: metrics), 1, file: file, line: line)
        XCTAssertLessThanOrEqual(
            intMetric("pagingAnchorMilli", in: metrics, file: file, line: line),
            1_000,
            file: file,
            line: line
        )
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(
            intMetric("transportStarts", in: metrics),
            expectedTransportStarts,
            file: file,
            line: line
        )
        XCTAssertEqual(intMetric("transportEnvelopes", in: metrics), 80, file: file, line: line)
        XCTAssertEqual(intMetric("transportIngress", in: metrics), 80, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            intMetric("transportFinals", in: metrics),
            minimumTransportFinals,
            file: file,
            line: line
        )
    }

    private func assertRouteHostFields(
        _ metrics: [String: String],
        coldPendingBeforeRoot: Int,
        coldConsumesAfterStable: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(metrics["hostRoot"], "true", file: file, line: line)
        XCTAssertEqual(metrics["hostLastChatsBefore"], "true", file: file, line: line)
        XCTAssertEqual(intMetric("hostRouteAttempts", in: metrics), 1, file: file, line: line)
        XCTAssertEqual(intMetric("hostNativePushes", in: metrics), 1, file: file, line: line)
        XCTAssertEqual(metrics["hostOpaqueBeforeRow"], "true", file: file, line: line)
        XCTAssertEqual(intMetric("hostLastChatsExposures", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(
            intMetric("hostColdPendingBeforeRoot", in: metrics),
            coldPendingBeforeRoot,
            file: file,
            line: line
        )
        XCTAssertEqual(intMetric("hostAccountMaterializations", in: metrics), 1, file: file, line: line)
        XCTAssertEqual(intMetric("hostColdConsumesBeforeStable", in: metrics), 0, file: file, line: line)
        XCTAssertEqual(
            intMetric("hostColdConsumesAfterStable", in: metrics),
            coldConsumesAfterStable,
            file: file,
            line: line
        )
    }

    private func tapOpenScenarioPostInitialAction(scenario: String) {
        waitForOpenScenarioPostInitialReadiness(scenario: scenario)
        let button = app.buttons["chat.open.fixture.perform_post_initial"]
        XCTAssertTrue(button.waitForExistence(timeout: 4))
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func waitForOpenScenarioPostInitialReadiness(scenario: String) {
        let state = app.staticTexts["chat.open.fixture.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForLabel(state, containing: "scenario=\(scenario)"))
        XCTAssertTrue(waitForLabel(state, containing: "postReady=true", timeout: 8))
        XCTAssertTrue(waitForLabel(state, containing: "real=80"))
    }

    private func waitForTimeline(
        _ timeline: XCUIElement,
        portrait: Bool
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return portrait
                ? element.frame.height > element.frame.width
                : element.frame.width > element.frame.height
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: timeline
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func assertCommonOpenMetrics(
        _ metrics: [String: String],
        scenario: String,
        phase: String,
        target: String,
        initialSkeleton: Int,
        realRows: Int,
        datasourceApplies: Int,
        seededMessages: Int,
        seededDurable: Bool,
        expectedHighlight: Bool = false
    ) {
        XCTAssertEqual(metrics["scenario"], scenario)
        XCTAssertEqual(metrics["phase"], phase)
        XCTAssertEqual(metrics["target"], target)
        XCTAssertEqual(metrics["highlight"], String(expectedHighlight))
        XCTAssertEqual(intMetric("initialSkeleton", in: metrics), initialSkeleton)
        XCTAssertEqual(intMetric("skeleton", in: metrics), 0)
        XCTAssertEqual(intMetric("real", in: metrics), realRows)
        XCTAssertEqual(intMetric("applies", in: metrics), datasourceApplies)
        XCTAssertEqual(intMetric("firstContent", in: metrics), 1)
        XCTAssertEqual(intMetric("visualCommits", in: metrics), 1)
        XCTAssertEqual(intMetric("blankFrames", in: metrics), 0)
        XCTAssertLessThanOrEqual(intMetric("offsetMutations", in: metrics), 1)
        XCTAssertEqual(intMetric("postCommitOffsets", in: metrics), 0)
        XCTAssertEqual(intMetric("corrections", in: metrics), 0)
        XCTAssertEqual(intMetric("receipt", in: metrics), 1)
        XCTAssertEqual(metrics["stable"], "true")
        XCTAssertEqual(metrics["storageLease"], "true")
        XCTAssertEqual(metrics["storageEphemeral"], "true")
        XCTAssertEqual(intMetric("seeded", in: metrics), seededMessages)
        XCTAssertEqual(metrics["seededChat"], "true")
        XCTAssertEqual(metrics["seededArchive"], "true")
        XCTAssertEqual(metrics["seededDurable"], String(seededDurable))
        XCTAssertGreaterThan(intMetric("generation", in: metrics), 0)
        XCTAssertEqual(intMetric("fixtureRealmQueriesAfterAdmission", in: metrics), 0)
        XCTAssertEqual(intMetric("activeWork", in: metrics), 0)
        XCTAssertEqual(intMetric("transportMainViolations", in: metrics), 0)
        XCTAssertEqual(intMetric("transportUIOffMain", in: metrics), 0)
    }

    private func assertLocalRouteProductionProof(
        _ metrics: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            intMetric("storeQueries", in: metrics, file: file, line: line),
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            intMetric(
                "mainThreadStoreQueries",
                in: metrics,
                file: file,
                line: line
            ),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(intMetric("fullScans", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            intMetric("maxCandidates", in: metrics, file: file, line: line),
            80,
            file: file,
            line: line
        )
        XCTAssertEqual(metrics["preparedOnMain"], "false", file: file, line: line)
        XCTAssertEqual(metrics["mappedOnMain"], "false", file: file, line: line)
        XCTAssertEqual(intMetric("realApplies", in: metrics, file: file, line: line), 1, file: file, line: line)
        XCTAssertEqual(intMetric("layoutCommits", in: metrics, file: file, line: line), 1, file: file, line: line)
        XCTAssertEqual(intMetric("committedRoutes", in: metrics, file: file, line: line), 1, file: file, line: line)
        XCTAssertEqual(metrics["committedTarget"], metrics["target"], file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapLeaseStarts", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapLeaseJoins", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapActive", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapCompleted", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapFailed", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapCancelled", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertEqual(intMetric("bootstrapTransports", in: metrics, file: file, line: line), 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            intMetric("terminalQuietMillis", in: metrics, file: file, line: line),
            500,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            intMetric("terminalResets", in: metrics, file: file, line: line),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(intMetric("activeWork", in: metrics, file: file, line: line), 0, file: file, line: line)
    }

    private func intMetric(
        _ key: String,
        in metrics: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        guard let raw = metrics[key], let value = Int(raw) else {
            XCTFail("Missing integer metric \(key): \(metrics)", file: file, line: line)
            return .max
        }
        return value
    }

    @discardableResult
    private func waitForReady(timeout: TimeInterval = 8) -> XCUIElement {
        let status = app.staticTexts["chat.performance.ready"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabel(status, containing: "ready", timeout: timeout))
        return status
    }

    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
