import XCTest
@testable import xabber

final class ChatPerformanceSignpostTests: XCTestCase {
    func testRequiredChatOpenPhaseNamesAreStableAndPrivacySafe() {
        XCTAssertEqual(
            ChatPerformanceSignpostPhase.allCases.map(\.rawValue),
            [
                "chat.open_request",
                "chat.skeleton_receipt",
                "chat.content_receipt",
                "chat.empty_receipt",
                "chat.lease_queued",
                "chat.lease_transport",
                "chat.lease_persistence",
                "chat.raw_final",
                "chat.ingress_complete",
                "chat.persistence_terminal",
                "chat.presenting",
                "chat.stable_frame",
                "chat.local_snapshot_ready",
                "chat.first_content_committed",
                "chat.first_stable_frame",
                "chat.open_to_first_frame",
                "chat.map_dataset",
                "chat.datasource_diff",
                "chat.datasource_apply",
                "chat.layout_apply",
                "chat.scroll_processing",
                "chat.send_to_local_row",
                "chat.local_history_query",
                "chat.display_model_cache",
                "chat.observer_refresh",
                "chat.reference_prepare",
                "chat.media_prefetch",
                "chat.media_visible_hit",
                "chat.page_plan",
                "chat.page_query",
                "chat.page_persist",
                "chat.page_apply",
                "chat.anchor_received",
                "chat.anchor_resolved",
                "chat.anchor_centered",
                "chat.message_persistence"
            ]
        )

        let privateTokens = ChatPerformanceMetricSnapshot.privateTokenFragments
        for name in ChatPerformanceSignpostPhase.allCases.map(\.rawValue) {
            for token in privateTokens {
                XCTAssertFalse(name.localizedCaseInsensitiveContains(token), "\(name) contains private token \(token)")
            }
        }
    }

    func testMeasureReturnsBodyValue() {
        let value = ChatPerformanceSignposts.measure(.mapDataset) {
            "mapped"
        }

        XCTAssertEqual(value, "mapped")
    }

    func testMeasurePropagatesThrownError() {
        enum SampleError: Error, Equatable {
            case expected
        }

        XCTAssertThrowsError(try ChatPerformanceSignposts.measure(.datasourceApply) {
            throw SampleError.expected
        }) { error in
            XCTAssertEqual(error as? SampleError, .expected)
        }
    }

    func testMeasureCarriesOpaqueContextAcrossBeginAndTerminal() throws {
        let context = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 42,
            generation: 8,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.normalRoute.rawValue
        ))
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }

        let value = ChatPerformanceSignposts.measure(
            .localHistoryQuery,
            context: context,
            counters: ["operationCount": 2]
        ) {
            7
        }

        XCTAssertEqual(value, 7)
        let records = recorder.snapshot()
        XCTAssertEqual(records.map(\.kind), [.begin, .end])
        XCTAssertTrue(records.allSatisfy { $0.context == context })
        XCTAssertEqual(records.first?.counter("operationCount"), 2)
        XCTAssertEqual(records.last?.terminal, .committed)
    }

    func testIntervalEndIsIdempotent() {
        var interval = ChatPerformanceSignposts.begin(.scrollProcessing)

        XCTAssertTrue(interval.isActive)
        XCTAssertTrue(interval.end())
        XCTAssertFalse(interval.isActive)
        XCTAssertFalse(interval.end())
    }

    func testPointEventAcceptsStableMilestonePhase() {
        ChatPerformanceSignposts.event(.firstContentCommitted)
    }

    func testMetricSnapshotsExposeOnlyPrivacySafeCounterFields() {
        let snapshot = ChatPerformanceMetricSnapshot(
            phase: .referencePrepare,
            counters: [
                "referenceCount": 3,
                "durationMs": 42,
                "slowReferenceCount": 1
            ]
        )

        XCTAssertEqual(snapshot.counter("referenceCount"), 3)
        XCTAssertTrue(snapshot.isPrivacySafe)
        XCTAssertTrue(snapshot.unsafeFieldNames.isEmpty)
        XCTAssertEqual(snapshot.sortedCounterNames, ["durationMs", "referenceCount", "slowReferenceCount"])
    }

    func testReferencePrepareMetricsDoNotStoreIdentifiersOrPaths() {
        let metrics = ChatReferencePrepareMetrics(
            referenceCount: 2,
            durationMs: 17,
            slowReferenceCount: 1
        )
        let snapshot = metrics.snapshot

        XCTAssertEqual(snapshot.phase, .referencePrepare)
        XCTAssertEqual(snapshot.counter("referenceCount"), 2)
        XCTAssertEqual(snapshot.counter("durationMs"), 17)
        XCTAssertEqual(snapshot.counter("slowReferenceCount"), 1)
        XCTAssertTrue(snapshot.isPrivacySafe)
        XCTAssertFalse(snapshot.sortedCounterNames.contains("url"))
        XCTAssertFalse(snapshot.sortedCounterNames.contains("path"))
        XCTAssertFalse(snapshot.sortedCounterNames.contains("body"))
        XCTAssertFalse(snapshot.sortedCounterNames.contains("token"))
    }

    func testSharedOpaqueTraceContextCorrelatesEventsAndIntervalsWithoutIdentifiers() throws {
        let context = try XCTUnwrap(
            ChatOpenPerformanceTraceContext(
                traceID: 41,
                generation: 7,
                kindCode: 2,
                purposeCode: 3
            )
        )
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }

        XCTAssertTrue(
            ChatPerformanceSignposts.event(
                .skeletonReceipt,
                context: context,
                counters: ["rowCount": 30]
            )
        )
        var interval = ChatPerformanceSignposts.begin(
            .presenting,
            context: context,
            counters: ["candidateCount": 80]
        )
        XCTAssertTrue(
            interval.end(
                terminal: .committed,
                counters: ["applyCount": 1]
            )
        )

        let records = recorder.snapshot()
        XCTAssertEqual(records.map(\.kind), [.event, .begin, .end])
        XCTAssertEqual(records.map(\.phase), [.skeletonReceipt, .presenting, .presenting])
        XCTAssertTrue(records.allSatisfy { $0.context == context })
        XCTAssertTrue(records.allSatisfy(\.isPrivacySafe))
        XCTAssertEqual(records[0].counter("rowCount"), 30)
        XCTAssertEqual(records[2].terminal, .committed)
        XCTAssertEqual(records[2].counter("applyCount"), 1)
        XCTAssertLessThanOrEqual(records[0].monotonicNanoseconds, records[1].monotonicNanoseconds)
        XCTAssertLessThanOrEqual(records[1].monotonicNanoseconds, records[2].monotonicNanoseconds)
    }

    func testIntervalTerminalIsIdempotentForCommitFailureAndCancellation() throws {
        let context = try XCTUnwrap(
            ChatOpenPerformanceTraceContext(
                traceID: 99,
                generation: 4,
                kindCode: 1,
                purposeCode: 8
            )
        )
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }

        var original = ChatPerformanceSignposts.begin(.leaseTransport, context: context)
        var copied = original
        XCTAssertTrue(original.end(terminal: .failed))
        XCTAssertFalse(copied.end(terminal: .cancelled))
        XCTAssertFalse(original.end(terminal: .committed))

        let terminals = recorder.snapshot().filter { $0.kind == .end }
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.terminal, .failed)
    }

    func testRecorderRejectsStringAndIdentifierPayloads() throws {
        let context = try XCTUnwrap(
            ChatOpenPerformanceTraceContext(
                traceID: 73,
                generation: 1,
                kindCode: 0,
                purposeCode: 0
            )
        )
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }

        XCTAssertFalse(
            ChatPerformanceSignposts.event(
                .rawFinal,
                context: context,
                counters: ["queryId": 123]
            )
        )
        XCTAssertFalse(
            ChatPerformanceSignposts.event(
                .ingressComplete,
                context: context,
                counters: ["messagePrimary": 456]
            )
        )
        XCTAssertFalse(
            ChatPerformanceSignposts.event(
                .ingressComplete,
                context: context,
                counters: ["a": 1, "b": 2, "c": 3, "d": 4, "e": 5]
            )
        )
        XCTAssertTrue(
            ChatPerformanceSignposts.event(
                .persistenceTerminal,
                context: context,
                counters: ["receivedCount": 80, "failedCount": 0]
            )
        )

        let records = recorder.snapshot()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.phase, .persistenceTerminal)
        XCTAssertTrue(records.first?.isPrivacySafe == true)
        XCTAssertEqual(records.first?.sortedCounterNames, ["failedCount", "receivedCount"])
    }

    func testRejectedIdentifierTerminalPayloadStillClosesStartedIntervalExactlyOnce() throws {
        let context = try XCTUnwrap(
            ChatOpenPerformanceTraceContext(
                traceID: 81,
                generation: 2,
                kindCode: 1,
                purposeCode: 3
            )
        )
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }

        var interval = ChatPerformanceSignposts.begin(
            .leasePersistence,
            context: context
        )

        XCTAssertTrue(
            interval.end(
                terminal: .failed,
                counters: ["queryId": 17]
            )
        )
        XCTAssertFalse(interval.isActive)
        XCTAssertFalse(interval.end(terminal: .cancelled))

        let records = recorder.snapshot()
        XCTAssertEqual(records.map(\.kind), [.begin, .end])
        XCTAssertEqual(records.last?.terminal, .failed)
        XCTAssertEqual(records.last?.sortedCounterNames, ["rejectedFieldCount"])
        XCTAssertEqual(records.last?.counter("rejectedFieldCount"), 1)
        XCTAssertTrue(records.allSatisfy(\.isPrivacySafe))
    }

    func testConcurrentRecorderSnapshotHasOneStrictMonotonicEmissionOrder() throws {
        let context = try XCTUnwrap(
            ChatOpenPerformanceTraceContext(
                traceID: 82,
                generation: 6,
                kindCode: 1,
                purposeCode: 4
            )
        )
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "chat.performance.trace.recorder.concurrent",
            attributes: .concurrent
        )

        for index in 0..<64 {
            group.enter()
            queue.async {
                ChatPerformanceSignposts.event(
                    .rawFinal,
                    context: context,
                    counters: ["ordinal": index]
                )
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        let records = recorder.snapshot()
        XCTAssertEqual(records.count, 64)
        XCTAssertEqual(Set(records.map(\.emissionSequence)).count, 64)
        XCTAssertEqual(
            records.map(\.emissionSequence),
            records.map(\.emissionSequence).sorted()
        )
        XCTAssertEqual(
            records.map(\.monotonicNanoseconds),
            records.map(\.monotonicNanoseconds).sorted()
        )
    }

    func testContextFactoryCreatesUniqueNonzeroProcessLocalTraceAndGenerationValues() {
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "chat.performance.context.factory.concurrent",
            attributes: .concurrent
        )
        var contexts: [ChatOpenPerformanceTraceContext] = []

        for _ in 0..<128 {
            group.enter()
            queue.async {
                let context = ChatOpenPerformanceTraceContextFactory.make(
                    kind: .initialOpen,
                    purpose: .normalRoute
                )
                lock.lock()
                contexts.append(context)
                lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(contexts.count, 128)
        XCTAssertEqual(Set(contexts.map(\.traceID)).count, 128)
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 128)
        XCTAssertTrue(contexts.allSatisfy { $0.traceID != 0 && $0.generation != 0 })
        XCTAssertTrue(contexts.allSatisfy {
            $0.kindCode == ChatOpenPerformanceTraceKind.initialOpen.rawValue &&
                $0.purposeCode == ChatOpenPerformanceTracePurpose.normalRoute.rawValue
        })
        XCTAssertNil(ChatOpenPerformanceTraceContext(
            traceID: 0,
            generation: 1,
            kindCode: 1,
            purposeCode: 1
        ))
        XCTAssertNil(ChatOpenPerformanceTraceContext(
            traceID: 1,
            generation: 0,
            kindCode: 1,
            purposeCode: 1
        ))
    }

    func testOpenLifecycleEmitsOneAcceptedOpenPresentationReceiptAndStableFrame() throws {
        let context = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 901,
            generation: 41,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.notificationRoute.rawValue
        ))
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }
        let lifecycle = ChatOpenPerformanceTraceLifecycle()

        XCTAssertTrue(lifecycle.accept(context: context, emitsOpenRequest: true))
        XCTAssertFalse(lifecycle.accept(context: context, emitsOpenRequest: true))
        XCTAssertTrue(lifecycle.beginPresenting(context: context))
        XCTAssertTrue(lifecycle.endPresenting(context: context, terminal: .committed))
        XCTAssertTrue(lifecycle.recordPresentationReceipt(
            .content,
            context: context,
            schedulesStableFrame: true
        ))
        XCTAssertTrue(lifecycle.consumeStableFrame(
            context: context,
            eligibility: .eligible
        ))
        XCTAssertFalse(lifecycle.consumeStableFrame(
            context: context,
            eligibility: .eligible
        ))

        let records = recorder.snapshot()
        XCTAssertEqual(
            records.map { "\($0.kind):\($0.phase.rawValue)" },
            [
                "event:chat.open_request",
                "begin:chat.presenting",
                "end:chat.presenting",
                "event:chat.content_receipt",
                "event:chat.stable_frame"
            ]
        )
        XCTAssertTrue(records.allSatisfy { $0.context == context })
    }

    func testStableFrameLifecycleSnapshotSeparatesReceiptAndArmReadiness() throws {
        let context = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 910,
            generation: 50,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.normalRoute.rawValue
        ))
        let lifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(lifecycle.accept(context: context, emitsOpenRequest: false))

        XCTAssertEqual(
            lifecycle.stableFrameLifecycleSnapshot(
                context: context,
                requiredReceipt: .content
            ),
            ChatOpenPerformanceStableFrameLifecycleSnapshot(
                isCurrentContext: true,
                hasRequiredPresentationReceipt: false,
                hasPendingStableFrame: false,
                hasEmittedStableFrame: false
            )
        )

        XCTAssertTrue(lifecycle.recordPresentationReceipt(
            .content,
            context: context,
            schedulesStableFrame: false
        ))
        XCTAssertEqual(
            lifecycle.stableFrameLifecycleSnapshot(
                context: context,
                requiredReceipt: .content
            ),
            ChatOpenPerformanceStableFrameLifecycleSnapshot(
                isCurrentContext: true,
                hasRequiredPresentationReceipt: true,
                hasPendingStableFrame: false,
                hasEmittedStableFrame: false
            )
        )

        XCTAssertTrue(lifecycle.scheduleStableFrame(
            after: .content,
            context: context
        ))
        XCTAssertEqual(
            lifecycle.stableFrameLifecycleSnapshot(
                context: context,
                requiredReceipt: .content
            ),
            ChatOpenPerformanceStableFrameLifecycleSnapshot(
                isCurrentContext: true,
                hasRequiredPresentationReceipt: true,
                hasPendingStableFrame: true,
                hasEmittedStableFrame: false
            )
        )

        XCTAssertTrue(lifecycle.consumeStableFrame(
            context: context,
            eligibility: .eligible
        ))
        XCTAssertEqual(
            lifecycle.stableFrameLifecycleSnapshot(
                context: context,
                requiredReceipt: .content
            ),
            ChatOpenPerformanceStableFrameLifecycleSnapshot(
                isCurrentContext: true,
                hasRequiredPresentationReceipt: true,
                hasPendingStableFrame: false,
                hasEmittedStableFrame: true
            )
        )
    }

    func testReplacingGenerationCancelsPresentationAndRejectsEveryLateReceiptAndTick() throws {
        let original = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 902,
            generation: 42,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.normalRoute.rawValue
        ))
        let replacement = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 903,
            generation: 43,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.explicitTargetRoute.rawValue
        ))
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }
        let lifecycle = ChatOpenPerformanceTraceLifecycle()

        XCTAssertTrue(lifecycle.accept(context: original, emitsOpenRequest: true))
        XCTAssertTrue(lifecycle.beginPresenting(context: original))
        XCTAssertTrue(lifecycle.accept(context: replacement, emitsOpenRequest: true))
        XCTAssertFalse(lifecycle.endPresenting(context: original, terminal: .committed))
        XCTAssertFalse(lifecycle.recordPresentationReceipt(
            .content,
            context: original,
            schedulesStableFrame: true
        ))
        XCTAssertFalse(lifecycle.consumeStableFrame(
            context: original,
            eligibility: .eligible
        ))

        let originalRecords = recorder.snapshot().filter { $0.context == original }
        XCTAssertEqual(originalRecords.map(\.phase), [.openRequest, .presenting, .presenting])
        XCTAssertEqual(originalRecords.last?.terminal, .cancelled)
        XCTAssertFalse(originalRecords.contains {
            $0.phase == .contentReceipt || $0.phase == .emptyReceipt || $0.phase == .stableFrame
        })
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.context == replacement && $0.phase == .openRequest
            }.count,
            1
        )
    }

    func testStableFrameWaitsForVisibleForegroundCurrentCorrectionFreeDisplayTick() throws {
        let context = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 904,
            generation: 44,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.fallbackRoute.rawValue
        ))
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }
        let lifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(lifecycle.accept(context: context, emitsOpenRequest: true))
        XCTAssertTrue(lifecycle.recordPresentationReceipt(
            .empty,
            context: context,
            schedulesStableFrame: true
        ))

        let ineligibleStates: [ChatOpenPerformanceStableFrameEligibility] = [
            .init(hasWindow: false, isViewVisible: true, isForegroundActive: true,
                  isCurrentPresentation: true, hasPendingCorrection: false),
            .init(hasWindow: true, isViewVisible: false, isForegroundActive: true,
                  isCurrentPresentation: true, hasPendingCorrection: false),
            .init(hasWindow: true, isViewVisible: true, isForegroundActive: false,
                  isCurrentPresentation: true, hasPendingCorrection: false),
            .init(hasWindow: true, isViewVisible: true, isForegroundActive: true,
                  isCurrentPresentation: false, hasPendingCorrection: false),
            .init(hasWindow: true, isViewVisible: true, isForegroundActive: true,
                  isCurrentPresentation: true, hasPendingCorrection: true),
            .init(hasWindow: true, isViewVisible: true, isForegroundActive: true,
                  isCurrentPresentation: true, hasPendingCorrection: false,
                  isWindowVisible: false),
            .init(hasWindow: true, isViewVisible: true, isForegroundActive: true,
                  isCurrentPresentation: true, hasPendingCorrection: false,
                  isSceneForegroundActive: false)
        ]
        ineligibleStates.forEach {
            XCTAssertFalse(lifecycle.consumeStableFrame(context: context, eligibility: $0))
        }
        XCTAssertEqual(
            recorder.snapshot().filter { $0.phase == .stableFrame }.count,
            0
        )
        XCTAssertTrue(lifecycle.consumeStableFrame(
            context: context,
            eligibility: .eligible
        ))
        XCTAssertFalse(lifecycle.consumeStableFrame(
            context: context,
            eligibility: .eligible
        ))
        XCTAssertEqual(
            recorder.snapshot().filter { $0.phase == .stableFrame }.count,
            1
        )
    }

    func testTerminalReceiptIsExclusiveAndPresentationCancelIsIdempotent() throws {
        let context = try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: 905,
            generation: 45,
            kindCode: ChatOpenPerformanceTraceKind.initialOpen.rawValue,
            purposeCode: ChatOpenPerformanceTracePurpose.normalRoute.rawValue
        ))
        let recorder = ChatPerformanceTraceRecorder()
        let installation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        defer { installation.cancel() }
        let lifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(lifecycle.accept(context: context, emitsOpenRequest: false))
        XCTAssertTrue(lifecycle.beginPresenting(context: context))
        XCTAssertTrue(lifecycle.cancel(context: context))
        XCTAssertFalse(lifecycle.cancel(context: context))
        XCTAssertFalse(lifecycle.recordPresentationReceipt(
            .empty,
            context: context,
            schedulesStableFrame: true
        ))

        let records = recorder.snapshot()
        XCTAssertEqual(records.map(\.phase), [.presenting, .presenting])
        XCTAssertEqual(records.last?.terminal, .cancelled)
    }

    func testRouteAcceptsOpaqueTraceBeforeConfigureDeliveryOrQueueAtEveryRealEntryPoint() throws {
        let lastChatsSource = try productionSource(
            "xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDelegate.swift"
        )
        let acceptance = try sourceSlice(
            lastChatsSource,
            from: "internal func acceptChatOpenIntent(",
            to: "private func resolvedNavigationSource("
        )
        let resolvedIntent = try XCTUnwrap(acceptance.range(of: "let intent:"))
        let acceptedTrace = try XCTUnwrap(
            acceptance.range(of: "_ = destination.acceptChatOpenPerformanceTrace(")
        )
        let configured = try XCTUnwrap(
            acceptance.range(of: "configureCallback?(destination)")
        )
        let delivered = try XCTUnwrap(
            acceptance.range(of: "chatOpenIntentDeliveryHandler(intent, destination)")
        )
        XCTAssertLessThan(resolvedIntent.lowerBound, acceptedTrace.lowerBound)
        XCTAssertLessThan(acceptedTrace.lowerBound, configured.lowerBound)
        XCTAssertLessThan(configured.lowerBound, delivered.lowerBound)

        let appRootSource = try productionSource(
            "xabber/application/AppRootCoordinator.swift"
        )
        let fallback = try sourceSlice(
            appRootSource,
            from: "private func openChat(",
            to: "private func applyCompatibilityReferences()"
        )
        let acceptOffsets = offsets(
            of: "_ = vc.acceptChatOpenPerformanceTrace(",
            in: fallback
        )
        let queueOffsets = offsets(
            of: "vc.queueOpenMessageRequest(openMessageRequest)",
            in: fallback
        )
        let configureOffsets = offsets(
            of: "configureCallback?(vc)",
            in: fallback
        )
        XCTAssertEqual(acceptOffsets.count, 2)
        XCTAssertEqual(queueOffsets.count, 2)
        XCTAssertEqual(configureOffsets.count, 2)
        for index in 0..<2 {
            XCTAssertLessThan(acceptOffsets[index], configureOffsets[index])
            XCTAssertLessThan(configureOffsets[index], queueOffsets[index])
        }
    }


    private func productionSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        _ source: String,
        from startToken: String,
        to endToken: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken))
        let end = try XCTUnwrap(source.range(
            of: endToken,
            range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func offsets(of token: String, in source: String) -> [Int] {
        var result: [Int] = []
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: token, range: searchRange) {
            result.append(source.distance(from: source.startIndex, to: range.lowerBound))
            searchRange = range.upperBound..<source.endIndex
        }
        return result
    }
}
