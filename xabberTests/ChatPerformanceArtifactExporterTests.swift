import XCTest
@testable import xabber

final class ChatPerformanceArtifactExporterTests: XCTestCase {
    private var applicationHomeDirectory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        applicationHomeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChatPerformanceArtifactExporterHome-\(UUID().uuidString)"
            )
        temporaryDirectory = applicationHomeDirectory
            .appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let applicationHomeDirectory {
            try? FileManager.default.removeItem(at: applicationHomeDirectory)
        }
        applicationHomeDirectory = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testSwiftPhaseManifestMatchesExactPythonCanonicalJSONHashFixture() {
        XCTAssertEqual(
            ChatPerformancePhaseManifest.sha256,
            "4ebdf02fa9bafac0e23baa3ef45bdef435189064971ccb4ff7a8114ab78424dc"
        )
        XCTAssertTrue(ChatPerformancePhaseManifest.canonicalJSON.hasPrefix(
            "{\"phases\":[\"chat.open_request\""
        ))
        XCTAssertTrue(ChatPerformancePhaseManifest.canonicalJSON.hasSuffix(
            "\"chat.message_persistence\"],\"schema_version\":1}"
        ))
    }

    func testArtifactFailuresExposeOnlyClosedPrivacySafeDiagnosticCodes() {
        XCTAssertEqual(
            ChatPerformanceArtifactExportError.incompleteMarkerSequence
                .diagnosticFailureCode,
            .incompleteMarkerSequence
        )
        XCTAssertEqual(
            ChatPerformanceArtifactExportError.incompleteTraceContract
                .diagnosticFailureCode,
            .incompleteTraceContract
        )
        XCTAssertEqual(
            ChatPerformanceArtifactExportError.invalidRecordOrder
                .diagnosticFailureCode,
            .invalidRecordOrder
        )
        XCTAssertEqual(
            ChatPerformanceArtifactExportError.artifactWriteFailed
                .diagnosticFailureCode,
            .artifactWriteFailed
        )
        XCTAssertEqual(
            ChatOpenVideoEvidenceTerminalFailureCode.allCases.map(\.rawValue),
            [
                "none",
                "stable-frame-rejected",
                "marker-rejected",
                "terminal-evidence-invalidated",
                "artifact-finalization-failed"
            ]
        )
        XCTAssertEqual(
            ChatOpenPerformanceStableFrameSealFailureCode.allCases
                .map(\.rawValue),
            [
                "none",
                "bound-primary-context-unavailable",
                "current-primary-context-unavailable",
                "primary-context-mismatch",
                "lifecycle-context-mismatch",
                "semantic-target-unavailable",
                "presentation-receipt-pending",
                "stable-frame-not-scheduled",
                "stable-frame-consume-rejected"
            ]
        )
        XCTAssertEqual(
            ChatOpenPerformanceStableFrameSealDiagnostics(
                failureCode: .presentationReceiptPending,
                attempted: true,
                boundPrimaryContextAvailable: true,
                currentPrimaryContextAvailable: true,
                primaryContextMatches: true,
                lifecycleContextMatches: true,
                semanticTargetAvailable: true,
                requiredPresentationReceiptRecorded: false,
                stableFrameScheduled: false,
                stableFrameAlreadyEmitted: false,
                stableFrameConsumed: false
            ).accessibilityFields,
            [
                "stableFrameFailure=presentation-receipt-pending",
                "stableFrameAttempted=true",
                "stableFrameBoundPrimary=true",
                "stableFrameCurrentPrimary=true",
                "stableFramePrimaryMatch=true",
                "stableFrameLifecycleCurrent=true",
                "stableFrameSemanticTarget=true",
                "stableFrameReceipt=false",
                "stableFrameScheduled=false",
                "stableFrameAlreadyEmitted=false",
                "stableFrameConsumed=false"
            ]
        )
        XCTAssertTrue(
            ChatPerformanceArtifactExportFailureCode.allCases.allSatisfy {
                !$0.rawValue.isEmpty && $0.rawValue.unicodeScalars.allSatisfy {
                    $0.isASCII &&
                        (CharacterSet.lowercaseLetters.contains($0) ||
                         CharacterSet.decimalDigits.contains($0) ||
                         $0.value == 45)
                }
            }
        )
    }

    func testTraceContractDiagnosticsIdentifyMissingAndDuplicateRequiredRecords()
        throws {
        let missingPaths = makePaths(prefix: "trace-missing-receipt")
        let missing = try XCTUnwrap(try makeSession(paths: missingPaths))
        let missingContext = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try missing.bindTraceContext(
            missingContext,
            contract: .initialLocalContent
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .openRequest,
            context: missingContext
        ))
        emitLocalQueryMapAndPresentation(context: missingContext)
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .stableFrame,
            context: missingContext
        ))
        try recordAllMarkers(missing)

        XCTAssertThrowsError(try missing.finalize()) { error in
            XCTAssertEqual(
                error as? ChatPerformanceArtifactExportError,
                .incompleteTraceContract
            )
        }
        XCTAssertEqual(
            missing.diagnosticTraceContractFailureDetails,
            ChatPerformanceArtifactTraceContractFailureDiagnostics(
                code: .requiredRecordMissing,
                phaseCode: ChatPerformancePhaseManifest.code(
                    for: .contentReceipt
                ),
                relatedPhaseCode: 0,
                recordKindCode: ChatPerformanceTraceRecord.Kind.event.rawValue,
                observedCount: 0,
                expectedCount: 1,
                beginCount: 0,
                endCount: 0,
                terminalCode: 0,
                expectedTerminalCode: 0
            )
        )

        let duplicatePaths = makePaths(prefix: "trace-duplicate-query")
        let duplicate = try XCTUnwrap(try makeSession(paths: duplicatePaths))
        let duplicateContext = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try duplicate.bindTraceContext(
            duplicateContext,
            contract: .initialLocalContent
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .openRequest,
            context: duplicateContext
        ))
        emitLocalQueryMapAndPresentation(context: duplicateContext)
        emitLocalQueryMapAndPresentation(context: duplicateContext)
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .contentReceipt,
            context: duplicateContext
        ))
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .stableFrame,
            context: duplicateContext
        ))
        try recordAllMarkers(duplicate)

        XCTAssertThrowsError(try duplicate.finalize())
        let duplicateDetails =
            duplicate.diagnosticTraceContractFailureDetails
        XCTAssertEqual(duplicateDetails.code, .requiredRecordDuplicate)
        XCTAssertEqual(
            duplicateDetails.phaseCode,
            ChatPerformancePhaseManifest.code(for: .localHistoryQuery)
        )
        XCTAssertEqual(
            duplicateDetails.recordKindCode,
            ChatPerformanceTraceRecord.Kind.begin.rawValue
        )
        XCTAssertEqual(duplicateDetails.observedCount, 2)
        XCTAssertEqual(duplicateDetails.expectedCount, 1)
    }

    func testEnvironmentRequiresBothDistinctRelativeExportPathsOrNeither() throws {
        XCTAssertNil(try ChatPerformanceArtifactExportSession.makeIfRequested(
            environment: [:]
        ))
        XCTAssertThrowsError(try ChatPerformanceArtifactExportSession.makeIfRequested(
            environment: [
                ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                    "Library/Caches/signposts.json"
            ]
        )) { error in
            XCTAssertEqual(
                error as? ChatPerformanceArtifactExportError,
                .incompleteEnvironment
            )
        }
        XCTAssertThrowsError(try ChatPerformanceArtifactExportSession.makeIfRequested(
            environment: [
                ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                    temporaryDirectory.appendingPathComponent("signposts.json").path,
                ChatPerformanceArtifactExportEnvironment.markerEventPathKey:
                    temporaryDirectory.appendingPathComponent("markers.json").path
            ]
        )) { error in
            XCTAssertEqual(
                error as? ChatPerformanceArtifactExportError,
                .invalidRelativeDestination
            )
        }
        XCTAssertThrowsError(try ChatPerformanceArtifactExportSession.makeIfRequested(
            environment: [
                ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                    "Library/Caches/same.json",
                ChatPerformanceArtifactExportEnvironment.markerEventPathKey:
                    "Library/Caches/same.json"
            ]
        )) { error in
            XCTAssertEqual(
                error as? ChatPerformanceArtifactExportError,
                .duplicateDestination
            )
        }
    }

    func testEnvironmentRejectsDestinationsOutsideOwnCanonicalContainer() throws {
        XCTAssertThrowsError(try ChatPerformanceArtifactExportSession
            .makeIfRequested(
                environment: [
                    ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                        "../outside/signposts.json",
                    ChatPerformanceArtifactExportEnvironment.markerEventPathKey:
                        "Library/Caches/markers.json"
                ],
                applicationHomeDirectory: applicationHomeDirectory
            )) { error in
                XCTAssertEqual(
                    error as? ChatPerformanceArtifactExportError,
                    .invalidRelativeDestination
                )
            }

        XCTAssertThrowsError(try ChatPerformanceArtifactExportSession
            .makeIfRequested(
                environment: [
                    ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                        "Library/Caches/signposts.json",
                    ChatPerformanceArtifactExportEnvironment.markerEventPathKey:
                        "Library/Caches/markers.json",
                    ChatPerformanceArtifactExportEnvironment.dataContainerPathKey:
                        applicationHomeDirectory.path
                ],
                applicationHomeDirectory: applicationHomeDirectory
            )) { error in
                XCTAssertEqual(
                    error as? ChatPerformanceArtifactExportError,
                    .incompleteEnvironment
                )
            }
    }

    func testMarkerEventSchemaContainsClosedIDVisualCodeAndUptimeButNoSourceIndex() throws {
        let paths = makePaths()
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = emitLocalContentTrace()
        try session.bindTraceContext(context, contract: .initialLocalContent)
        try recordAllMarkers(session)

        try session.finalize()

        let markerRoot = try jsonObject(at: paths.markers)
        XCTAssertEqual(
            Set(markerRoot.keys),
            ["schema_version", "marker_manifest_sha256", "events"]
        )
        XCTAssertEqual(markerRoot["schema_version"] as? Int, 1)
        let events = try XCTUnwrap(markerRoot["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(
            events.compactMap { $0["marker_id"] as? String },
            ["M1", "M2", "M3"]
        )
        XCTAssertEqual(
            events.compactMap { $0["visual_code"] as? String },
            ["vertical_bars", "checkerboard", "concentric_rings"]
        )
        XCTAssertEqual(
            events.compactMap { $0["uptime_ns"] as? UInt64 },
            [100, 200, 300]
        )
        XCTAssertTrue(events.allSatisfy {
            Set($0.keys) == ["marker_id", "visual_code", "uptime_ns"]
        })

        let payload = try String(contentsOf: paths.markers, encoding: .utf8)
            .lowercased()
        XCTAssertFalse(payload.contains("source_index"))
        XCTAssertFalse(payload.contains("fps"))
        XCTAssertFalse(payload.contains("path"))
        XCTAssertFalse(payload.contains("owner"))
        XCTAssertFalse(payload.contains("jid"))
        XCTAssertFalse(payload.contains("query"))
        XCTAssertFalse(payload.contains("message"))
        XCTAssertFalse(payload.contains("archive"))
    }

    func testLateRouteEvidenceRevocationInvalidatesFinalizedSessionAndArtifacts()
        throws {
        let paths = makePaths(prefix: "late-route-revocation")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = emitLocalContentTrace()
        try session.bindTraceContext(context, contract: .initialLocalContent)
        try recordAllMarkers(session)
        try session.finalize()
        XCTAssertTrue(session.didFinalizeSuccessfully)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.markers.path))

        session.revokeFinalizedEvidenceAcceptance()

        XCTAssertFalse(session.didFinalizeSuccessfully)
        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testTraceExportUsesClosedNumericSchemaAndExactPhaseManifestHash() throws {
        let paths = makePaths()
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialLocalContent)
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .openRequest,
            context: context,
            counters: ["rowCount": 3]
        ))
        emitLocalContentTail(context: context)
        try recordAllMarkers(session)

        try session.finalize()

        let traceRoot = try jsonObject(at: paths.signposts)
        XCTAssertEqual(
            Set(traceRoot.keys),
            ["schema_version", "phase_manifest_sha256", "phase_count", "records"]
        )
        XCTAssertEqual(traceRoot["schema_version"] as? Int, 1)
        XCTAssertEqual(
            traceRoot["phase_manifest_sha256"] as? String,
            ChatPerformancePhaseManifest.sha256
        )
        XCTAssertEqual(
            traceRoot["phase_count"] as? Int,
            ChatPerformanceSignpostPhase.allCases.count
        )
        let records = try XCTUnwrap(traceRoot["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 9)
        let openRecord = try XCTUnwrap(records.first {
            ($0["phase_code"] as? Int) ==
                ChatPerformancePhaseManifest.code(for: .openRequest)
        })
        XCTAssertEqual(
            Set(openRecord.keys),
            [
                "sequence", "record_kind_code", "phase_code", "trace_id",
                "generation", "operation_kind_code", "purpose_code",
                "terminal_code", "uptime_ns", "thread_code", "counters"
            ]
        )
        XCTAssertEqual(openRecord["trace_id"] as? UInt64, context.traceID)
        XCTAssertEqual(openRecord["generation"] as? UInt64, context.generation)
        XCTAssertEqual(
            openRecord["phase_code"] as? Int,
            ChatPerformancePhaseManifest.code(for: .openRequest)
        )
        let counters = try XCTUnwrap(openRecord["counters"] as? [[String: Any]])
        XCTAssertEqual(counters.count, 1)
        XCTAssertEqual(Set(counters[0].keys), ["code", "value"])
        XCTAssertEqual(
            counters[0]["code"] as? Int,
            ChatPerformancePublicCounterCode.rowCount.rawValue
        )
        XCTAssertEqual(counters[0]["value"] as? Int, 3)

        let payload = try String(contentsOf: paths.signposts, encoding: .utf8)
            .lowercased()
        XCTAssertFalse(payload.contains("owner@example.com"))
        XCTAssertFalse(payload.contains(paths.signposts.path.lowercased()))
        XCTAssertFalse(payload.contains(paths.markers.path.lowercased()))
    }

    func testTraceExportBindsPublicVideoMatrixRouteAndFixtureScenario() throws {
        let paths = makePaths(prefix: "video-route")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = emitLocalContentTrace()
        try session.bindVideoRouteEvidence(
            matrixRouteCode: "N01",
            fixtureScenario: "preloaded-latest"
        )
        try session.bindTraceContext(context, contract: .initialLocalContent)
        try recordAllMarkers(session)

        try session.finalize()

        let root = try jsonObject(at: paths.signposts)
        XCTAssertEqual(root["matrix_route_code"] as? String, "N01")
        XCTAssertEqual(root["fixture_scenario"] as? String, "preloaded-latest")
        XCTAssertEqual(
            Set(root.keys),
            [
                "schema_version", "phase_manifest_sha256", "phase_count",
                "matrix_route_code", "fixture_scenario", "records"
            ]
        )
    }

    func testRouteSessionRefreshesOnlyItsStaleArtifactPair() throws {
        let paths = makePaths()
        let sentinel = Data("do-not-overwrite".utf8)
        try sentinel.write(to: paths.markers)
        let unrelated = temporaryDirectory.appendingPathComponent("unrelated.json")
        try sentinel.write(to: unrelated)
        let session = try XCTUnwrap(try makeSession(paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
        let context = emitLocalContentTrace()
        try session.bindTraceContext(context, contract: .initialLocalContent)
        try recordAllMarkers(session)

        try session.finalize()

        XCTAssertNotEqual(try Data(contentsOf: paths.markers), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
    }

    func testUnknownCounterFailsClosedWithoutWritingEitherArtifact() throws {
        let paths = makePaths()
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialLocalContent)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        emitLocalContentTail(context: context)
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .observerRefresh,
            context: context,
            counters: ["unknownButNumeric": 1]
        ))
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testMarkerTransitionRejectsMismatchDuplicateAndOutOfOrder() throws {
        let paths = makePaths()
        let mismatch = try XCTUnwrap(try makeSession(paths: paths))
        XCTAssertThrowsError(try mismatch.recordMarkerTransition(
            markerID: .m1,
            visualCode: .checkerboard,
            uptimeNanoseconds: 100
        ))

        let duplicatePaths = makePaths(prefix: "duplicate")
        let duplicate = try XCTUnwrap(try makeSession(paths: duplicatePaths))
        try duplicate.recordMarkerTransition(
            markerID: .m1,
            visualCode: .verticalBars,
            uptimeNanoseconds: 100
        )
        XCTAssertThrowsError(try duplicate.recordMarkerTransition(
            markerID: .m1,
            visualCode: .verticalBars,
            uptimeNanoseconds: 200
        ))

        let orderPaths = makePaths(prefix: "order")
        let order = try XCTUnwrap(try makeSession(paths: orderPaths))
        XCTAssertThrowsError(try order.recordMarkerTransition(
            markerID: .m2,
            visualCode: .checkerboard,
            uptimeNanoseconds: 100
        ))
    }

    func testMarkerExportFailureMakesScenarioReceiptFailClosed() throws {
        let paths = makePaths(prefix: "missing-parent")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = emitLocalContentTrace()
        try session.bindTraceContext(context, contract: .initialLocalContent)
        try recordAllMarkers(session)
        try FileManager.default.removeItem(at: temporaryDirectory)

        XCTAssertThrowsError(try session.finalize())
        XCTAssertTrue(session.didFail)
        XCTAssertFalse(session.didFinalizeSuccessfully)
    }

    func testArchiveContractRejectsTraceMissingRealLifecycle() throws {
        let paths = makePaths(prefix: "missing-archive")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = emitLocalContentTrace()
        try session.bindTraceContext(context, contract: .initialArchiveContent)
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testArchiveContractAcceptsOneOrderedCommittedLifecycleForBoundContext() throws {
        let paths = makePaths(prefix: "complete-archive")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveContent)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-owner@example.com"
        let queryID = "private-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: owner,
            queryID: queryID,
            context: context,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))
        emitLocalContentTail(context: context)
        try recordAllMarkers(session)

        try session.finalize()

        XCTAssertTrue(session.didFinalizeSuccessfully)
        let payload = try String(contentsOf: paths.signposts, encoding: .utf8)
            .lowercased()
        XCTAssertFalse(payload.contains(owner.lowercased()))
        XCTAssertFalse(payload.contains(queryID.lowercased()))
    }

    func testCanonicalDurableLocalEmptyAcceptsNoArchiveLifecycle() throws {
        let paths = makePaths(prefix: "local-empty")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = emitLocalEmptyTrace()
        try session.bindTraceContext(context, contract: .initialLocalEmpty)
        try recordAllMarkers(session)

        try session.finalize()

        let root = try jsonObject(at: paths.signposts)
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let archivePhaseCodes = Set([
            ChatPerformanceSignpostPhase.leaseQueued,
            .leaseTransport,
            .leasePersistence,
            .rawFinal,
            .ingressComplete,
            .persistenceTerminal
        ].map { ChatPerformancePhaseManifest.code(for: $0) })
        XCTAssertTrue(records.allSatisfy { record in
            guard let phaseCode = record["phase_code"] as? Int else {
                return false
            }
            return !archivePhaseCodes.contains(phaseCode)
        })
        XCTAssertTrue(session.didFinalizeSuccessfully)
    }

    func testRemoteRepairToEmptyRequiresCommittedArchiveLifecycleBeforeEmptyReceipt() throws {
        let paths = makePaths(prefix: "archive-empty")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveEmpty)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-empty-owner@example.com"
        let queryID = "private-empty-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: owner,
            queryID: queryID,
            context: context,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))
        emitLocalEmptyTail(context: context)
        try recordAllMarkers(session)

        try session.finalize()

        XCTAssertTrue(session.didFinalizeSuccessfully)
    }

    func testArchiveRepairToEmptyWithoutSkeletonReceiptCannotExport() throws {
        let paths = makePaths(prefix: "archive-empty-no-skeleton")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveEmpty)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        emitCommittedInitialArchiveLifecycle(
            context: context,
            owner: "private-no-skeleton-owner@example.com",
            queryID: "private-no-skeleton-query"
        )
        emitLocalEmptyTail(context: context)
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testHealthyLocalContentWithSkeletonReceiptCannotExport() throws {
        let paths = makePaths(prefix: "local-content-with-skeleton")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialLocalContent)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        emitLocalContentTail(context: context)
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())
        XCTAssertTrue(session.didFail)
    }

    func testArchiveContentWithContentAndEmptyReceiptsCannotExport() throws {
        let paths = makePaths(prefix: "archive-content-and-empty")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveContent)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        emitCommittedInitialArchiveLifecycle(
            context: context,
            owner: "private-double-receipt-owner@example.com",
            queryID: "private-double-receipt-query"
        )
        emitLocalContentTail(context: context)
        XCTAssertTrue(ChatPerformanceSignposts.event(.emptyReceipt, context: context))
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())
        XCTAssertTrue(session.didFail)
    }

    func testArchiveFailureExportsStableSkeletonAndOneTypedFailedTerminal() throws {
        let paths = makePaths(prefix: "archive-failure")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveFailure)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.stableFrame, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-failure-owner@example.com"
        let queryID = "private-failure-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: owner,
            queryID: queryID,
            context: context,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .failed,
            persistedCount: 0,
            failedCount: 1
        ))
        try recordAllMarkers(session)

        try session.finalize()

        let root = try jsonObject(at: paths.signposts)
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let failedCode = ChatPerformanceIntervalTerminal.failed.rawValue
        XCTAssertEqual(records.filter {
            ($0["terminal_code"] as? UInt64) == failedCode
        }.count, 2)
        XCTAssertTrue(session.didFinalizeSuccessfully)
    }

    func testArchiveTransportFailureClosesOnlyActiveTransportInterval() throws {
        let paths = makePaths(prefix: "transport-failure")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveFailure)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.stableFrame, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-transport-owner@example.com"
        let queryID = "private-transport-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.terminate(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .failed
        ))
        try recordAllMarkers(session)

        try session.finalize()

        let root = try jsonObject(at: paths.signposts)
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(records.filter {
            ($0["terminal_code"] as? UInt64) ==
                ChatPerformanceIntervalTerminal.failed.rawValue
        }.count, 1)
        XCTAssertTrue(session.didFinalizeSuccessfully)
    }

    func testActiveArchiveDwellBeyondFiveSecondsExportsAfterOneCancelledTeardown() throws {
        let paths = makePaths(prefix: "active-dwell")
        var clockValues: [UInt64] = [
            100,
            200,
            300,
            400,
            5_000_000_401
        ]
        let session = try XCTUnwrap(try makeSession(
            paths: paths,
            monotonicClock: {
                precondition(!clockValues.isEmpty)
                return clockValues.removeFirst()
            }
        ))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(
            context,
            contract: .initialArchiveActiveDwellThenCancel
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.stableFrame, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        XCTAssertEqual(registry.register(
            owner: "private-dwell-owner@example.com",
            queryID: "private-dwell-query",
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.terminate(
            owner: "private-dwell-owner@example.com",
            queryID: "private-dwell-query",
            context: context,
            terminal: .cancelled
        ))
        try recordAllMarkers(session)

        try session.finalize()

        let root = try jsonObject(at: paths.signposts)
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(records.filter {
            ($0["terminal_code"] as? UInt64) ==
                ChatPerformanceIntervalTerminal.cancelled.rawValue
        }.count, 1)
        XCTAssertTrue(session.didFinalizeSuccessfully)
    }

    func testActiveArchiveDwellCannotExportBeforeTestOwnedCancellation() throws {
        let paths = makePaths(prefix: "active-before-cancel")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(
            context,
            contract: .initialArchiveActiveDwellThenCancel
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.stableFrame, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        XCTAssertEqual(registry.register(
            owner: "private-active-owner@example.com",
            queryID: "private-active-query",
            context: context,
            operation: .initialOpen
        ), .started)
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        registry.cancelAllForTesting()
        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testFiveSecondLeaseWithOnlyLateStableSkeletonCannotExportAsDwell() throws {
        let paths = makePaths(prefix: "late-stable-dwell")
        var clockValues: [UInt64] = [
            100,
            200,
            300,
            4_999_000_300,
            5_000_000_300
        ]
        let session = try XCTUnwrap(try makeSession(
            paths: paths,
            monotonicClock: {
                precondition(!clockValues.isEmpty)
                return clockValues.removeFirst()
            }
        ))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(
            context,
            contract: .initialArchiveActiveDwellThenCancel
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-late-stable-owner@example.com"
        let queryID = "private-late-stable-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(ChatPerformanceSignposts.event(.stableFrame, context: context))
        XCTAssertTrue(registry.terminate(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .cancelled
        ))
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testArchiveFailureBeforeStableSkeletonCannotExport() throws {
        let paths = makePaths(prefix: "failure-before-stable")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        try session.bindTraceContext(context, contract: .initialArchiveFailure)
        XCTAssertTrue(ChatPerformanceSignposts.event(.openRequest, context: context))
        XCTAssertTrue(ChatPerformanceSignposts.event(.skeletonReceipt, context: context))
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-early-failure-owner@example.com"
        let queryID = "private-early-failure-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.terminate(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .failed
        ))
        XCTAssertTrue(ChatPerformanceSignposts.event(.stableFrame, context: context))
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testArchiveFailureAfterContentOrEmptyReceiptCannotExport() throws {
        for receiptPhase in [
            ChatPerformanceSignpostPhase.contentReceipt,
            .emptyReceipt
        ] {
            let paths = makePaths(prefix: "failure-after-\(receiptPhase.rawValue)")
            let session = try XCTUnwrap(try makeSession(paths: paths))
            let context = ChatOpenPerformanceTraceContextFactory.make(
                kind: .initialOpen,
                purpose: .normalRoute
            )
            try session.bindTraceContext(
                context,
                contract: .initialArchiveFailure
            )
            XCTAssertTrue(ChatPerformanceSignposts.event(
                .openRequest,
                context: context
            ))
            XCTAssertTrue(ChatPerformanceSignposts.event(
                .skeletonReceipt,
                context: context
            ))
            XCTAssertTrue(ChatPerformanceSignposts.event(
                .stableFrame,
                context: context
            ))
            XCTAssertTrue(ChatPerformanceSignposts.event(
                receiptPhase,
                context: context
            ))
            let registry = ChatArchivePerformanceTraceRegistry()
            let owner = "private-late-failure-owner@example.com"
            let queryID = "private-late-failure-\(receiptPhase.rawValue)"
            XCTAssertEqual(registry.register(
                owner: owner,
                queryID: queryID,
                context: context,
                operation: .initialOpen
            ), .started)
            XCTAssertTrue(registry.transportStarted(
                owner: owner,
                queryID: queryID,
                context: context
            ))
            XCTAssertTrue(registry.terminate(
                owner: owner,
                queryID: queryID,
                context: context,
                terminal: .failed
            ))
            try recordAllMarkers(session)

            XCTAssertThrowsError(try session.finalize())

            XCTAssertTrue(session.didFail)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: paths.signposts.path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: paths.markers.path
            ))
        }
    }

    func testRelativeExportContractResolvesInsideActualRuntimeContainer() throws {
        let replacementHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChatPerformanceArtifactExporterReplacementHome-\(UUID().uuidString)"
            )
        let replacementArtifactDirectory = replacementHome
            .appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(
            at: replacementArtifactDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: replacementHome) }

        let session = try XCTUnwrap(
            try ChatPerformanceArtifactExportSession.makeIfRequested(
                environment: [
                    ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                        "Library/Caches/chat-open-N01-signposts.json",
                    ChatPerformanceArtifactExportEnvironment.markerEventPathKey:
                        "Library/Caches/chat-open-N01-markers.json"
                ],
                applicationHomeDirectory: replacementHome
            )
        )
        let context = emitLocalContentTrace()
        try session.bindTraceContext(context, contract: .initialLocalContent)
        try recordAllMarkers(session)

        try session.finalize()

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            replacementArtifactDirectory
                .appendingPathComponent("chat-open-N01-signposts.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            replacementArtifactDirectory
                .appendingPathComponent("chat-open-N01-markers.json").path
        ))
    }

    func testFinalizeRejectsUnboundTraceContext() throws {
        let paths = makePaths(prefix: "unbound")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        _ = emitLocalContentTrace()
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())
        XCTAssertTrue(session.didFail)
    }

    func testBoundScenarioRejectsUnlinkedSecondInitialOpenContext() throws {
        let paths = makePaths(prefix: "mixed-context")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let accepted = emitLocalContentTrace()
        try session.bindTraceContext(accepted, contract: .initialLocalContent)
        _ = emitLocalContentTrace()
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testInitialArchiveContextsRejectBalancedPagingPhases() throws {
        let cases: [(
            suffix: String,
            contract: ChatPerformanceArtifactTraceContract,
            receipt: ChatPerformanceSignpostPhase
        )] = [
            ("content", .initialArchiveContent, .contentReceipt),
            ("empty", .initialArchiveEmpty, .emptyReceipt)
        ]
        for testCase in cases {
            let paths = makePaths(
                prefix: "initial-\(testCase.suffix)-with-page-phases"
            )
            let session = try XCTUnwrap(try makeSession(paths: paths))
            let context = ChatOpenPerformanceTraceContextFactory.make(
                kind: .initialOpen,
                purpose: .normalRoute
            )
            try session.bindTraceContext(context, contract: testCase.contract)
            XCTAssertTrue(ChatPerformanceSignposts.event(
                .openRequest,
                context: context
            ))
            XCTAssertTrue(ChatPerformanceSignposts.event(
                .skeletonReceipt,
                context: context
            ))
            emitCommittedInitialArchiveLifecycle(
                context: context,
                owner: "private-initial-page-\(testCase.suffix)@example.com",
                queryID: "private-initial-page-\(testCase.suffix)"
            )
            emitBalancedPageOnlyPhases(context: context)
            emitLocalQueryMapAndPresentation(context: context)
            XCTAssertTrue(ChatPerformanceSignposts.event(
                testCase.receipt,
                context: context
            ))
            XCTAssertTrue(ChatPerformanceSignposts.event(
                .stableFrame,
                context: context
            ))
            try recordAllMarkers(session)

            XCTAssertThrowsError(try session.finalize())

            XCTAssertTrue(session.didFail)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: paths.signposts.path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: paths.markers.path
            ))
        }
    }

    func testExplicitCommittedLinkedPagingContextCanCoexistWithInitialOpen() throws {
        let paths = makePaths(prefix: "linked-page")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let initialContext = emitLocalContentTrace()
        try session.bindTraceContext(
            initialContext,
            contract: .initialLocalContent
        )
        let pageContext = ChatOpenPerformanceTraceContextFactory.make(
            kind: .paging,
            purpose: .normalRoute
        )
        try session.bindLinkedTraceContext(pageContext)
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-page-owner@example.com"
        let queryID = "private-page-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: pageContext,
            operation: .olderPage
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: pageContext
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: owner,
            queryID: queryID,
            context: pageContext,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: owner,
            queryID: queryID,
            context: pageContext,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: owner,
            queryID: queryID,
            context: pageContext,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))
        var apply = ChatPerformanceSignposts.begin(
            .pageApply,
            context: pageContext
        )
        XCTAssertTrue(apply.end(terminal: .committed))
        try recordAllMarkers(session)

        try session.finalize()

        let root = try jsonObject(at: paths.signposts)
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let traceIDs = Set(records.compactMap { $0["trace_id"] as? UInt64 })
        XCTAssertEqual(
            traceIDs,
            Set([initialContext.traceID, pageContext.traceID])
        )
        XCTAssertTrue(session.didFinalizeSuccessfully)
    }

    func testLinkedPagingContextRejectsBalancedInitialLeasePhases() throws {
        let paths = makePaths(prefix: "linked-page-with-lease-phases")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let initialContext = emitLocalContentTrace()
        try session.bindTraceContext(initialContext, contract: .initialLocalContent)
        let pageContext = emitCommittedLinkedPageTrace()
        try session.bindLinkedTraceContext(pageContext)
        emitBalancedInitialLeaseOnlyPhases(context: pageContext)
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    func testLinkedPagingContextRejectsInitialLocalHistoryQuery() throws {
        let paths = makePaths(prefix: "linked-page-with-local-query")
        let session = try XCTUnwrap(try makeSession(paths: paths))
        let initialContext = emitLocalContentTrace()
        try session.bindTraceContext(initialContext, contract: .initialLocalContent)
        let pageContext = emitCommittedLinkedPageTrace()
        try session.bindLinkedTraceContext(pageContext)
        var localQuery = ChatPerformanceSignposts.begin(
            .localHistoryQuery,
            context: pageContext
        )
        XCTAssertTrue(localQuery.end(terminal: .committed))
        try recordAllMarkers(session)

        XCTAssertThrowsError(try session.finalize())

        XCTAssertTrue(session.didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signposts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markers.path))
    }

    private struct ExportPaths {
        let signposts: URL
        let markers: URL
    }

    private func makePaths(prefix: String = "artifact") -> ExportPaths {
        ExportPaths(
            signposts: temporaryDirectory.appendingPathComponent(
                "chat-open-\(prefix)-signposts.json"
            ),
            markers: temporaryDirectory.appendingPathComponent(
                "chat-open-\(prefix)-markers.json"
            )
        )
    }

    private func makeSession(
        paths: ExportPaths,
        monotonicClock: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> ChatPerformanceArtifactExportSession? {
        try ChatPerformanceArtifactExportSession.makeIfRequested(environment: [
            ChatPerformanceArtifactExportEnvironment.signpostPathKey:
                "Library/Caches/\(paths.signposts.lastPathComponent)",
            ChatPerformanceArtifactExportEnvironment.markerEventPathKey:
                "Library/Caches/\(paths.markers.lastPathComponent)"
        ], applicationHomeDirectory: applicationHomeDirectory,
           monotonicClock: monotonicClock)
    }

    @discardableResult
    private func emitLocalContentTrace() -> ChatOpenPerformanceTraceContext {
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .openRequest,
            context: context
        ))
        emitLocalContentTail(context: context)
        return context
    }

    private func emitCommittedInitialArchiveLifecycle(
        context: ChatOpenPerformanceTraceContext,
        owner: String,
        queryID: String
    ) {
        let registry = ChatArchivePerformanceTraceRegistry()
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: owner,
            queryID: queryID,
            context: context,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))
    }

    private func emitCommittedLinkedPageTrace() -> ChatOpenPerformanceTraceContext {
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .paging,
            purpose: .normalRoute
        )
        let registry = ChatArchivePerformanceTraceRegistry()
        let owner = "private-linked-page-owner@example.com"
        let queryID = "private-linked-page-query"
        XCTAssertEqual(registry.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .olderPage
        ), .started)
        XCTAssertTrue(registry.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: owner,
            queryID: queryID,
            context: context,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: owner,
            queryID: queryID,
            context: context,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))
        var apply = ChatPerformanceSignposts.begin(
            .pageApply,
            context: context
        )
        XCTAssertTrue(apply.end(terminal: .committed))
        return context
    }

    private func emitBalancedPageOnlyPhases(
        context: ChatOpenPerformanceTraceContext
    ) {
        XCTAssertTrue(ChatPerformanceSignposts.event(.pagePlan, context: context))
        var query = ChatPerformanceSignposts.begin(.pageQuery, context: context)
        XCTAssertTrue(query.end(terminal: .committed))
        var persist = ChatPerformanceSignposts.begin(.pagePersist, context: context)
        XCTAssertTrue(persist.end(terminal: .committed))
        var apply = ChatPerformanceSignposts.begin(.pageApply, context: context)
        XCTAssertTrue(apply.end(terminal: .committed))
    }

    private func emitBalancedInitialLeaseOnlyPhases(
        context: ChatOpenPerformanceTraceContext
    ) {
        var queued = ChatPerformanceSignposts.begin(.leaseQueued, context: context)
        XCTAssertTrue(queued.end(terminal: .committed))
        var transport = ChatPerformanceSignposts.begin(
            .leaseTransport,
            context: context
        )
        XCTAssertTrue(transport.end(terminal: .committed))
        var persistence = ChatPerformanceSignposts.begin(
            .leasePersistence,
            context: context
        )
        XCTAssertTrue(persistence.end(terminal: .committed))
    }

    private func emitLocalEmptyTrace() -> ChatOpenPerformanceTraceContext {
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .initialOpen,
            purpose: .normalRoute
        )
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .openRequest,
            context: context
        ))
        emitLocalEmptyTail(context: context)
        return context
    }

    private func emitLocalContentTail(
        context: ChatOpenPerformanceTraceContext
    ) {
        emitLocalQueryMapAndPresentation(context: context)
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .contentReceipt,
            context: context
        ))
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .stableFrame,
            context: context
        ))
    }

    private func emitLocalEmptyTail(
        context: ChatOpenPerformanceTraceContext
    ) {
        emitLocalQueryMapAndPresentation(context: context)
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .emptyReceipt,
            context: context
        ))
        XCTAssertTrue(ChatPerformanceSignposts.event(
            .stableFrame,
            context: context
        ))
    }

    private func emitLocalQueryMapAndPresentation(
        context: ChatOpenPerformanceTraceContext
    ) {
        var query = ChatPerformanceSignposts.begin(
            .localHistoryQuery,
            context: context
        )
        XCTAssertTrue(query.end(terminal: .committed))
        var map = ChatPerformanceSignposts.begin(.mapDataset, context: context)
        XCTAssertTrue(map.end(terminal: .committed))
        var presenting = ChatPerformanceSignposts.begin(
            .presenting,
            context: context
        )
        XCTAssertTrue(presenting.end(terminal: .committed))
    }

    private func recordAllMarkers(
        _ session: ChatPerformanceArtifactExportSession
    ) throws {
        try session.recordMarkerTransition(
            markerID: .m1,
            visualCode: .verticalBars,
            uptimeNanoseconds: 100
        )
        try session.recordMarkerTransition(
            markerID: .m2,
            visualCode: .checkerboard,
            uptimeNanoseconds: 200
        )
        try session.recordMarkerTransition(
            markerID: .m3,
            visualCode: .concentricRings,
            uptimeNanoseconds: 300
        )
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
    }
}
