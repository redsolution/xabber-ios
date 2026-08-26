import XCTest
import UIKit
import RealmSwift
@testable import xabber

final class ChatPerformanceLabTests: XCTestCase {
    func testOpenScenarioStoreOperationSummaryIsClosedDeterministicAndPrivacySafe() {
        let summary = ChatOpenRealPipelineFixtureStoreOperationSummary(
            operationCounts: [
                "postBootstrapWindowAndMetadata": 1,
                "messageWindow": 1,
                "private-owner@example.test": 7
            ]
        )

        XCTAssertEqual(summary.totalCount, 9)
        XCTAssertEqual(summary.unknownOperationCount, 7)
        XCTAssertEqual(
            summary.accessibilityValue,
            "message-window:1,post-bootstrap:1,unknown:7"
        )
        XCTAssertFalse(
            summary.accessibilityValue.contains("private-owner@example.test")
        )

        let terminal = ChatOpenRealPipelineFixtureStoreOperationSummary(
            operationCounts: [
                "messageWindow": 1,
                "postBootstrapWindowAndMetadata": 1,
                "resident": 3,
                "unread": 4
            ]
        )
        XCTAssertEqual(
            terminal.subtracting(summary.withoutUnknownOperations)
                .accessibilityValue,
            "resident:3,unread:4"
        )

        let remoteInitial = ChatOpenRealPipelineFixtureStoreOperationSummary(
            operationCounts: [
                "messageWindow": 1,
                "postBootstrapWindowAndMetadata": 2
            ]
        ).partitioningRemoteAnchorInitialFrame()
        XCTAssertEqual(
            remoteInitial.visualInitial.accessibilityValue,
            "message-window:1,post-bootstrap:1"
        )
        XCTAssertEqual(remoteInitial.visualInitial.totalCount, 2)
        XCTAssertEqual(
            remoteInitial.blocking.accessibilityValue,
            "post-bootstrap:1"
        )
        XCTAssertEqual(remoteInitial.blocking.totalCount, 1)
        XCTAssertEqual(
            remoteInitial.visualInitial.totalCount +
                remoteInitial.blocking.totalCount,
            3
        )

        let leakedRemoteInitial =
            ChatOpenRealPipelineFixtureStoreOperationSummary(
                operationCounts: [
                    "message": 6,
                    "messageWindow": 1,
                    "postBootstrapWindowAndMetadata": 2
                ]
            ).partitioningRemoteAnchorInitialFrame()
        XCTAssertEqual(
            leakedRemoteInitial.blocking.accessibilityValue,
            "message:6,post-bootstrap:1",
            "phase attribution must expose unexpected pre-commit work instead of hiding it"
        )
        XCTAssertEqual(leakedRemoteInitial.blocking.totalCount, 7)
    }

    func testRealPipelineLaunchDescriptorParsesEveryChatOpenScenario() throws {
        let acknowledgementToken = "00000000-0000-4000-8000-000000000001"
        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(token: acknowledgementToken)
        )
        for scenario in ChatOpenRealPipelineFixtureScenario.allCases {
            let descriptor = try XCTUnwrap(ChatPerformanceUITestLaunchPolicy.descriptor(
                arguments: [
                    "xabber",
                    ChatPerformanceUITestLaunchPolicy.launchArgument,
                    ChatPerformanceFixtureScale.small.rawValue,
                    ChatPerformanceUITestLaunchPolicy.openScenarioLaunchArgument,
                    scenario.rawValue,
                    ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                        .tokenLaunchArgument,
                    acknowledgementToken
                ],
                environment: [ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey: "1"]
            ))

            XCTAssertEqual(descriptor.scale, .small)
            XCTAssertEqual(descriptor.openScenario, scenario)
            XCTAssertEqual(
                descriptor.requiresExternalSkeletonAcknowledgement,
                ChatOpenRealPipelineFixturePlan(scenario: scenario).requiresRemoteInjection
            )
            XCTAssertEqual(
                descriptor.externalSkeletonAcknowledgementNotificationName,
                ChatOpenRealPipelineFixturePlan(scenario: scenario).requiresRemoteInjection
                    ? acknowledgementName
                    : nil
            )
        }
    }

    func testDarwinSkeletonAcknowledgementIsAllowlistedUniqueAndSingleUse() throws {
        let firstName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract.notificationName(
                token: "00000000-0000-4000-8000-000000000001"
            )
        )
        let secondName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract.notificationName(
                token: "00000000-0000-4000-8000-000000000002"
            )
        )
        XCTAssertNotEqual(firstName, secondName)
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .isAllowlisted(notificationName: firstName)
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .isAllowlisted(notificationName: "com.example.untrusted")
        )
        XCTAssertNil(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(token: "not-a-uuid")
        )
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract.shouldInstallObserver(
                requiresRemoteInjection: true,
                notificationName: firstName
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract.shouldInstallObserver(
                requiresRemoteInjection: false,
                notificationName: firstName
            )
        )

        var consumedGate = ChatOpenRealPipelineFixtureAcknowledgementGate()
        XCTAssertTrue(consumedGate.arm())
        XCTAssertTrue(consumedGate.consume())
        XCTAssertFalse(consumedGate.consume())

        var tornDownGate = ChatOpenRealPipelineFixtureAcknowledgementGate()
        XCTAssertTrue(tornDownGate.arm())
        tornDownGate.invalidate()
        XCTAssertFalse(tornDownGate.consume())
    }

    func testRemoteLaunchDescriptorRejectsMissingInvalidAndDuplicateAcknowledgementTokens() {
        let base = [
            "xabber",
            ChatPerformanceUITestLaunchPolicy.launchArgument,
            ChatPerformanceFixtureScale.small.rawValue,
            ChatPerformanceUITestLaunchPolicy.openScenarioLaunchArgument,
            ChatOpenRealPipelineFixtureScenario.bootstrapEmptyToContent.rawValue
        ]
        let environment = [ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey: "1"]
        let flag = ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
            .tokenLaunchArgument

        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: base,
            environment: environment
        ))
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: base + [flag, "not-a-uuid"],
            environment: environment
        ))
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: base + [
                flag, "00000000-0000-4000-8000-000000000001",
                flag, "00000000-0000-4000-8000-000000000002"
            ],
            environment: environment
        ))
    }

    func testDarwinSkeletonAcknowledgementRequiresCommittedPendingThirtyRowSkeleton() {
        func shouldConsume(
            pending: Bool = true,
            committed: Bool = true,
            showsSkeleton: Bool = true,
            rows: Int = 30
        ) -> Bool {
            ChatOpenRealPipelineFixtureAcknowledgementAdmissionPolicy.shouldConsume(
                hasPendingRemoteInjection: pending,
                hasCommittedBootstrapSkeleton: committed,
                loadingStateShowsSkeleton: showsSkeleton,
                observedSkeletonRows: rows,
                expectedSkeletonRows: 30
            )
        }

        XCTAssertTrue(shouldConsume())
        XCTAssertFalse(shouldConsume(pending: false))
        XCTAssertFalse(shouldConsume(committed: false))
        XCTAssertFalse(shouldConsume(showsSkeleton: false))
        XCTAssertFalse(shouldConsume(rows: 29))
    }

    func testRealPipelineSkeletonContinuationWaitsForUIAcknowledgementAfterObservation() {
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureSkeletonContinuationPolicy.action(
                observedSkeletonRows: 0,
                expectedSkeletonRows: 30,
                requiresExternalAcknowledgement: true,
                didReceiveExternalAcknowledgement: false
            ),
            .waitForSkeleton
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureSkeletonContinuationPolicy.action(
                observedSkeletonRows: 30,
                expectedSkeletonRows: 30,
                requiresExternalAcknowledgement: true,
                didReceiveExternalAcknowledgement: false
            ),
            .waitForExternalAcknowledgement
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureSkeletonContinuationPolicy.action(
                observedSkeletonRows: 30,
                expectedSkeletonRows: 30,
                requiresExternalAcknowledgement: true,
                didReceiveExternalAcknowledgement: true
            ),
            .injectRemotePage
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureSkeletonContinuationPolicy.action(
                observedSkeletonRows: 30,
                expectedSkeletonRows: 30,
                requiresExternalAcknowledgement: false,
                didReceiveExternalAcknowledgement: false
            ),
            .scheduleAutomaticDwell
        )
    }

    func testAcknowledgedRemoteRoutesHaveDistinctCausalTerminalActions() {
        XCTAssertEqual(
            ChatOpenRealPipelineFixturePlan(
                scenario: .bootstrapEmptyToContent
            ).acknowledgedRemoteAction,
            .injectContentPage
        )
        let trustedEmpty = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapEmptyToTrustedEmpty
        )
        XCTAssertEqual(
            trustedEmpty.acknowledgedRemoteAction,
            .injectTrustedEmptyTerminal
        )
        XCTAssertTrue(trustedEmpty.successfulArchiveFinalIsComplete)
        XCTAssertEqual(trustedEmpty.remoteInjectionOrdinalRange, 0..<0)

        let held = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapHeldOverWatchdog
        )
        XCTAssertEqual(
            held.acknowledgedRemoteAction,
            .holdActiveDwellThenCancel
        )
        XCTAssertEqual(held.expectedFinalSkeletonRowCount, 30)
        XCTAssertFalse(held.expectsRetry)

        let failure = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapTerminalFailureRetry
        )
        XCTAssertEqual(
            failure.acknowledgedRemoteAction,
            .injectTypedTerminalFailure
        )
        XCTAssertEqual(failure.expectedFinalSkeletonRowCount, 30)
        XCTAssertTrue(failure.expectsRetry)
        XCTAssertFalse(failure.successfulArchiveFinalIsComplete)
    }

    func testE02TrustedEmptyFinalCarriesExplicitZeroServerCardinalityAndCompleteProof() {
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapEmptyToTrustedEmpty
        )

        XCTAssertEqual(plan.remoteInjectionOrdinalRange, 0..<0)
        XCTAssertEqual(
            plan.successfulArchiveServerResultCount,
            0,
            "A trusted empty final must carry explicit zero cardinality; nil is untrusted missing evidence"
        )
        XCTAssertTrue(plan.successfulArchiveFinalIsComplete)

        let disposition = MessageArchiveManager.archivePageFinalDisposition(
            deliveredResultCount: 0,
            serverResultCount: plan.successfulArchiveServerResultCount,
            complete: plan.successfulArchiveFinalIsComplete,
            requestedPageCursor: nil,
            responseLastCursor: nil
        )
        XCTAssertEqual(disposition.deliveredResultCount, 0)
        XCTAssertEqual(disposition.serverResultCount, 0)
        XCTAssertTrue(disposition.queryExhausted)
    }

    func testRemoteActionLatchConsumesEarlyAcknowledgementExactlyOnceAfterCurrentQueryAdmission() {
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapEmptyToContent
        )
        var latch = ChatOpenRealPipelineFixtureRemoteActionLatch()

        XCTAssertTrue(latch.acknowledge(plan: plan))
        XCTAssertFalse(latch.acknowledge(plan: plan))
        XCTAssertTrue(latch.hasPendingAcknowledgement)
        XCTAssertNil(latch.takeIfReady(
            transportIsReady: true,
            descriptorQueryID: nil
        ))

        XCTAssertTrue(latch.admit(queryID: "bootstrap-query"))
        XCTAssertEqual(
            latch.takeIfReady(
                transportIsReady: true,
                descriptorQueryID: "bootstrap-query"
            ),
            plan
        )
        XCTAssertEqual(latch.dispatchCount, 1)
        XCTAssertFalse(latch.hasPendingAcknowledgement)
        XCTAssertNil(latch.takeIfReady(
            transportIsReady: true,
            descriptorQueryID: "bootstrap-query"
        ))
        XCTAssertFalse(latch.acknowledge(plan: plan))
    }

    func testRemoteActionLatchTracksReplacementAndInvalidationWithoutDispatchingStaleQuery() {
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .notificationExactRemote
        )
        var replacement = ChatOpenRealPipelineFixtureRemoteActionLatch()

        XCTAssertTrue(replacement.acknowledge(plan: plan))
        XCTAssertTrue(replacement.admit(queryID: "superseded-query"))
        XCTAssertTrue(replacement.admit(queryID: "current-query"))
        XCTAssertNil(replacement.takeIfReady(
            transportIsReady: true,
            descriptorQueryID: "superseded-query"
        ))
        XCTAssertEqual(
            replacement.takeIfReady(
                transportIsReady: true,
                descriptorQueryID: "current-query"
            ),
            plan
        )
        XCTAssertEqual(replacement.dispatchCount, 1)

        var tornDown = ChatOpenRealPipelineFixtureRemoteActionLatch()
        XCTAssertTrue(tornDown.acknowledge(plan: plan))
        XCTAssertTrue(tornDown.admit(queryID: "teardown-query"))
        tornDown.invalidate()
        XCTAssertFalse(tornDown.hasPendingAcknowledgement)
        XCTAssertNil(tornDown.admittedQueryID)
        XCTAssertNil(tornDown.takeIfReady(
            transportIsReady: true,
            descriptorQueryID: "teardown-query"
        ))
        XCTAssertFalse(tornDown.acknowledge(plan: plan))
        XCTAssertFalse(tornDown.admit(queryID: "replacement-after-teardown"))
        XCTAssertEqual(tornDown.dispatchCount, 0)
    }

    func testVisibleOffsetSamplerInvalidatesQueuedCallbacksAcrossSkeletonAcknowledgementPause() {
        var gate = ChatOpenRealPipelineFixtureOffsetSamplerGate()

        let initialGeneration = gate.beginSampling()
        XCTAssertTrue(gate.consumeDisplayTick(
            generation: initialGeneration,
            timestamp: 1
        ))

        gate.pause()
        XCTAssertFalse(gate.consumeDisplayTick(
            generation: initialGeneration,
            timestamp: 2
        ))

        let resumedGeneration = gate.beginSampling()
        XCTAssertNotEqual(resumedGeneration, initialGeneration)
        XCTAssertFalse(gate.consumeDisplayTick(
            generation: initialGeneration,
            timestamp: 3
        ))
        XCTAssertTrue(gate.consumeDisplayTick(
            generation: resumedGeneration,
            timestamp: 4
        ))

        gate.stop()
        XCTAssertFalse(gate.consumeDisplayTick(
            generation: resumedGeneration,
            timestamp: 5
        ))
    }

    func testVisibleOffsetMutationEvidenceSeparatesInitialPositioningFromTwoSemanticRotationRemaps() {
        var evidence = ChatOpenRealPipelineFixtureOffsetMutationEvidence()

        evidence.record(.initialPositioning)
        evidence.record(.rotationOwnedSemanticRemap)
        evidence.record(.rotationOwnedSemanticRemap)

        XCTAssertEqual(evidence.rawMutationCount, 3)
        XCTAssertEqual(evidence.initialPositioningMutationCount, 1)
        XCTAssertEqual(evidence.rotationOwnedMutationCount, 2)
        XCTAssertEqual(evidence.observableMutationCount, 1)
        XCTAssertEqual(evidence.postCommitMutationCount, 0)
    }

    func testVisibleOffsetMutationPolicyFailsClosedWhenRotationLosesItsSemanticViewport() {
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: true,
                hasCommittedViewport: true,
                retainedPagingAnchorStayedFixed: false,
                hasRotationInteractionOwnership: true,
                rotationSemanticViewportStayedFixed: false
            ),
            .unexpectedPostCommit
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: true,
                hasCommittedViewport: true,
                retainedPagingAnchorStayedFixed: false,
                hasRotationInteractionOwnership: true,
                rotationSemanticViewportStayedFixed: true
            ),
            .rotationOwnedSemanticRemap
        )
    }

    func testAtomicInitialOffsetGatePublishesOneCommittedViewportTransaction() {
        var gate = ChatOpenRealPipelineFixtureAtomicInitialOffsetGate()

        gate.begin(sourceOffsetY: 0)
        XCTAssertEqual(
            gate.complete(committedOffsetY: 640),
            .init(hasOffsetMovement: true)
        )
        XCTAssertNil(gate.complete(committedOffsetY: 640))
    }

    func testRotationSourceSamplePolicyRequiresFreshSameGenerationPreTransitionViewport() {
        let sample = ChatOpenRealPipelineFixtureRotationSourceSample(
            offsetY: 640,
            viewportSize: CGSize(width: 390, height: 844),
            displayTimestamp: 10,
            samplerGeneration: 7,
            semanticViewportStayedFixed: true
        )

        XCTAssertTrue(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.accepts(
                sample,
                targetViewSize: CGSize(width: 844, height: 390),
                currentTimestamp: 10.1,
                samplerGeneration: 7
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.accepts(
                sample,
                targetViewSize: CGSize(width: 844, height: 390),
                currentTimestamp: 10.3,
                samplerGeneration: 7
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.accepts(
                sample,
                targetViewSize: CGSize(width: 844, height: 390),
                currentTimestamp: 10.1,
                samplerGeneration: 8
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.accepts(
                sample,
                targetViewSize: sample.viewportSize,
                currentTimestamp: 10.1,
                samplerGeneration: 7
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.accepts(
                .init(
                    offsetY: sample.offsetY,
                    viewportSize: sample.viewportSize,
                    displayTimestamp: sample.displayTimestamp,
                    samplerGeneration: sample.samplerGeneration,
                    semanticViewportStayedFixed: false
                ),
                targetViewSize: CGSize(width: 844, height: 390),
                currentTimestamp: 10.1,
                samplerGeneration: 7
            )
        )
    }

    func testRotationSourceSampleAdmissionReportsExactClosedRejectionReason() {
        let sample = ChatOpenRealPipelineFixtureRotationSourceSample(
            offsetY: 640,
            viewportSize: CGSize(width: 390, height: 844),
            displayTimestamp: 10,
            samplerGeneration: 7,
            semanticViewportStayedFixed: true
        )
        let target = CGSize(width: 844, height: 390)

        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                nil,
                targetViewSize: target,
                currentTimestamp: 10.1,
                samplerGeneration: 7
            ),
            .missingSample
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                sample,
                targetViewSize: target,
                currentTimestamp: 10.1,
                samplerGeneration: nil
            ),
            .missingSamplerGeneration
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                sample,
                targetViewSize: target,
                currentTimestamp: 10.3,
                samplerGeneration: 7
            ),
            .staleSample
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                sample,
                targetViewSize: target,
                currentTimestamp: 10.1,
                samplerGeneration: 8
            ),
            .samplerGenerationMismatch
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                sample,
                targetViewSize: sample.viewportSize,
                currentTimestamp: 10.1,
                samplerGeneration: 7
            ),
            .unchangedViewport
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                .init(
                    offsetY: sample.offsetY,
                    viewportSize: sample.viewportSize,
                    displayTimestamp: sample.displayTimestamp,
                    samplerGeneration: sample.samplerGeneration,
                    semanticViewportStayedFixed: false
                ),
                targetViewSize: target,
                currentTimestamp: 10.1,
                samplerGeneration: 7
            ),
            .semanticViewportUnstable
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                sample,
                targetViewSize: target,
                currentTimestamp: 10.1,
                samplerGeneration: 7
            ),
            .accepted
        )
    }

    func testRotationBarrierDiagnosticsExposeEveryCausalReceiptWithoutGeometryPayload() {
        var diagnostics =
            ChatOpenRealPipelineFixtureRotationBarrierDiagnostics()

        diagnostics.recordSourceAdmission(.accepted, didBegin: true)
        diagnostics.recordCoordinatorCompletion(accepted: true)
        diagnostics.recordProductionCommit(.targetSizeMismatch)

        XCTAssertEqual(diagnostics.accessibilityFields, [
            "rotationSource=accepted",
            "rotationBegins=1",
            "rotationCoordinatorSeen=1",
            "rotationCoordinatorAccepted=1",
            "rotationCommitSeen=1",
            "rotationCommit=target-size-mismatch",
            "rotationCommitAccepted=0",
            "rotationEndpoints=0"
        ])

        diagnostics.recordProductionCommit(.accepted)
        diagnostics.recordEndpoint()
        XCTAssertEqual(Array(diagnostics.accessibilityFields.suffix(3)), [
            "rotationCommit=accepted",
            "rotationCommitAccepted=1",
            "rotationEndpoints=1"
        ])
    }

    func testRotationOffsetGateCapturesBothEndpointsWithoutDependingOnDisplayTickTiming() throws {
        var gate = ChatOpenRealPipelineFixtureRotationOffsetGate()
        var evidence = ChatOpenRealPipelineFixtureOffsetMutationEvidence()
        evidence.record(.initialPositioning)

        XCTAssertTrue(gate.begin(
            sourceOffsetY: 640,
            targetViewSize: CGSize(width: 844, height: 390),
            minimumLayoutGenerationExclusive: 4,
            semanticViewportStayedFixed: true
        ))
        gate.observeSemanticViewport(stayedFixed: true)
        XCTAssertTrue(gate.recordCoordinatorCompletion())
        XCTAssertNil(gate.complete(
            targetOffsetY: 240,
            semanticViewportStayedFixed: true
        ))
        XCTAssertTrue(gate.recordProductionLayoutCommit(
            generation: 5,
            targetViewSize: CGSize(width: 844, height: 390)
        ))
        let landscape = try XCTUnwrap(gate.complete(
            targetOffsetY: 240,
            semanticViewportStayedFixed: true
        ))
        evidence.record(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: landscape.hasOffsetMovement,
                hasCommittedViewport: true,
                retainedPagingAnchorStayedFixed: false,
                hasRotationInteractionOwnership: true,
                rotationSemanticViewportStayedFixed:
                    landscape.semanticViewportStayedFixed
            )
        )

        XCTAssertTrue(gate.begin(
            sourceOffsetY: 240,
            targetViewSize: CGSize(width: 390, height: 844),
            minimumLayoutGenerationExclusive: 5,
            semanticViewportStayedFixed: true
        ))
        XCTAssertTrue(gate.recordProductionLayoutCommit(
            generation: 6,
            targetViewSize: CGSize(width: 390, height: 844)
        ))
        XCTAssertNil(gate.complete(
            targetOffsetY: 640,
            semanticViewportStayedFixed: true
        ))
        XCTAssertTrue(gate.recordCoordinatorCompletion())
        let portrait = try XCTUnwrap(gate.complete(
            targetOffsetY: 640,
            semanticViewportStayedFixed: true
        ))
        evidence.record(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: portrait.hasOffsetMovement,
                hasCommittedViewport: true,
                retainedPagingAnchorStayedFixed: false,
                hasRotationInteractionOwnership: true,
                rotationSemanticViewportStayedFixed:
                    portrait.semanticViewportStayedFixed
            )
        )

        XCTAssertEqual(evidence.rawMutationCount, 3)
        XCTAssertEqual(evidence.initialPositioningMutationCount, 1)
        XCTAssertEqual(evidence.rotationOwnedMutationCount, 2)
        XCTAssertEqual(evidence.observableMutationCount, 1)
        XCTAssertEqual(evidence.postCommitMutationCount, 0)
    }

    func testV08SettledEndpointFeedsImmediateReverseAndRejectsCompletedTransitionLateCommit() throws {
        var gate = ChatOpenRealPipelineFixtureRotationOffsetGate()
        var beginCount = 0
        var endpointCount = 0
        let portrait = CGSize(width: 390, height: 844)
        let landscape = CGSize(width: 844, height: 390)

        XCTAssertTrue(gate.begin(
            sourceOffsetY: 4_100,
            targetViewSize: landscape,
            minimumLayoutGenerationExclusive: 4,
            semanticViewportStayedFixed: true
        ))
        beginCount += 1
        XCTAssertEqual(
            gate.admitProductionLayoutCommit(
                generation: 5,
                targetViewSize: landscape
            ),
            .accepted
        )
        XCTAssertTrue(gate.recordCoordinatorCompletion())
        let firstEndpoint = try XCTUnwrap(gate.complete(
            targetOffsetY: 2_497,
            semanticViewportStayedFixed: true
        ))
        endpointCount += 1
        XCTAssertTrue(firstEndpoint.semanticViewportStayedFixed)

        let settledLandscapeSource =
            ChatOpenRealPipelineFixtureRotationSourceSample(
                offsetY: 2_497,
                viewportSize: landscape,
                displayTimestamp: 10.1,
                samplerGeneration: 7,
                semanticViewportStayedFixed: true
            )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureRotationSourceSamplePolicy.admission(
                settledLandscapeSource,
                targetViewSize: portrait,
                currentTimestamp: 10.2,
                samplerGeneration: 7
            ),
            .accepted
        )
        XCTAssertEqual(
            gate.admitProductionLayoutCommit(
                generation: 5,
                targetViewSize: landscape
            ),
            .missingActiveTransition,
            "A late callback from the completed landscape transition must not mutate the next source snapshot"
        )

        XCTAssertTrue(gate.begin(
            sourceOffsetY: settledLandscapeSource.offsetY,
            targetViewSize: portrait,
            minimumLayoutGenerationExclusive: 5,
            semanticViewportStayedFixed: true
        ))
        beginCount += 1
        XCTAssertEqual(
            gate.admitProductionLayoutCommit(
                generation: 5,
                targetViewSize: landscape
            ),
            .staleGeneration,
            "The previous generation cannot satisfy or poison reverse ownership"
        )
        XCTAssertEqual(
            gate.admitProductionLayoutCommit(
                generation: 6,
                targetViewSize: portrait
            ),
            .accepted
        )
        XCTAssertTrue(gate.recordCoordinatorCompletion())
        let secondEndpoint = try XCTUnwrap(gate.complete(
            targetOffsetY: 4_100,
            semanticViewportStayedFixed: true
        ))
        endpointCount += 1
        XCTAssertTrue(secondEndpoint.semanticViewportStayedFixed)
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(endpointCount, 2)
    }

    func testRotationOffsetGateLatchesIntermediateSemanticDriftUntilEndpoint() throws {
        var gate = ChatOpenRealPipelineFixtureRotationOffsetGate()

        XCTAssertTrue(gate.begin(
            sourceOffsetY: 640,
            targetViewSize: CGSize(width: 844, height: 390),
            minimumLayoutGenerationExclusive: 4,
            semanticViewportStayedFixed: true
        ))
        gate.observeSemanticViewport(stayedFixed: false)
        gate.observeSemanticViewport(stayedFixed: true)
        XCTAssertTrue(gate.recordCoordinatorCompletion())
        XCTAssertTrue(gate.recordProductionLayoutCommit(
            generation: 5,
            targetViewSize: CGSize(width: 844, height: 390)
        ))
        let endpoint = try XCTUnwrap(gate.complete(
            targetOffsetY: 240,
            semanticViewportStayedFixed: true
        ))

        XCTAssertTrue(endpoint.hasOffsetMovement)
        XCTAssertFalse(endpoint.semanticViewportStayedFixed)
    }

    func testRotationOffsetGateRejectsStaleOrWrongTargetProductionCommit() {
        var gate = ChatOpenRealPipelineFixtureRotationOffsetGate()

        XCTAssertTrue(gate.begin(
            sourceOffsetY: 640,
            targetViewSize: CGSize(width: 844, height: 390),
            minimumLayoutGenerationExclusive: 4,
            semanticViewportStayedFixed: true
        ))
        XCTAssertEqual(
            gate.admitProductionLayoutCommit(
                generation: 4,
                targetViewSize: CGSize(width: 844, height: 390)
            ),
            .staleGeneration
        )
        XCTAssertEqual(
            gate.admitProductionLayoutCommit(
                generation: 5,
                targetViewSize: CGSize(width: 390, height: 844)
            ),
            .targetSizeMismatch
        )
        XCTAssertTrue(gate.recordCoordinatorCompletion())
        XCTAssertNil(gate.complete(
            targetOffsetY: 240,
            semanticViewportStayedFixed: true
        ))
    }

    func testV08RotationOffsetOwnershipStartsBeforeProductionWidthRemapForwarding() throws {
        let fixture = try chatPerformanceFixtureSource()
        let transition = try sourceMethod(
            named: "override func viewWillTransition(",
            in: fixture
        )
        let ownership = try XCTUnwrap(transition.range(
            of: "openScenarioRotationOffsetGate.begin("
        ))
        let productionForwarding = try XCTUnwrap(transition.range(
            of: "super.viewWillTransition(to: size, with: coordinator)"
        ))
        let source = try XCTUnwrap(transition.range(
            of: "sourceOffsetY: sourceSample.offsetY"
        ))

        XCTAssertLessThan(ownership.lowerBound, productionForwarding.lowerBound)
        XCTAssertLessThan(source.lowerBound, productionForwarding.lowerBound)
        XCTAssertFalse(transition.contains(
            "sourceOffsetY: messagesCollectionView.contentOffset.y"
        ))
    }

    func testV08ProductionWidthRemapPublishesReceiptOnlyAfterFinalTargetLayoutProof() throws {
        let fixture = try chatPerformanceFixtureSource()
        let configuration = try sourceMethod(
            named: "private func configureOpenScenario(",
            in: fixture
        )
        let dataset = try chatDatasetSource()
        let commit = try sourceMethod(
            named: "internal func commitPendingWidthTransitionLayoutRemapIfReady()",
            in: dataset
        )
        let finalizer = try sourceMethod(
            named: "private func finalizeWidthTransitionLayoutIfReady()",
            in: dataset
        )
        let controller = try chatViewControllerSource()
        let layout = try sourceMethod(
            named: "override func viewDidLayoutSubviews()",
            in: controller
        )

        XCTAssertTrue(configuration.contains(
            "performanceFixtureWidthTransitionLayoutCommitHandler ="
        ))
        XCTAssertTrue(commit.contains("CATransaction.setCompletionBlock"))
        XCTAssertTrue(commit.contains(
            "recordWidthTransitionCollectionUpdateCompletion("
        ))
        XCTAssertFalse(commit.contains(
            "performanceFixtureWidthTransitionLayoutCommitHandler?("
        ))
        let staleDatasourceRejection = try XCTUnwrap(commit.range(
            of: "guard stillRepresentsCurrentDatasource else {"
        ))
        let staleDatasourceCancellation = try XCTUnwrap(commit.range(
            of: "cancelPendingWidthTransitionLayoutRemap()"
        ))
        let finalizationInstall = try XCTUnwrap(commit.range(
            of: "pendingWidthTransitionLayoutFinalization ="
        ))
        XCTAssertLessThan(
            staleDatasourceRejection.lowerBound,
            staleDatasourceCancellation.lowerBound
        )
        XCTAssertLessThan(
            staleDatasourceCancellation.lowerBound,
            finalizationInstall.lowerBound
        )
        let proof = try XCTUnwrap(finalizer.range(
            of: "widthTransitionLayoutFinalizationProof("
        ))
        let receipt = try XCTUnwrap(finalizer.range(
            of: "pending.gate.completeIfReady()"
        ))
        let publication = try XCTUnwrap(finalizer.range(
            of: "performanceFixtureWidthTransitionLayoutCommitHandler?("
        ))
        let ordinaryCompletion = try XCTUnwrap(finalizer.range(
            of: "completion?()"
        ))
        XCTAssertLessThan(proof.lowerBound, receipt.lowerBound)
        XCTAssertLessThan(receipt.lowerBound, publication.lowerBound)
        XCTAssertLessThan(
            publication.lowerBound,
            ordinaryCompletion.lowerBound
        )
        let commitCall = try XCTUnwrap(layout.range(
            of: "commitPendingWidthTransitionLayoutRemapIfReady()"
        ))
        let observation = try XCTUnwrap(layout.range(
            of: "recordWidthTransitionLayoutFinalizationObservationIfNeeded()"
        ))
        XCTAssertLessThan(commitCall.lowerBound, observation.lowerBound)
    }

    func testV08RotationBarrierDiagnosticsArePublishedAtEveryCausalEvent() throws {
        let fixture = try chatPerformanceFixtureSource()
        let transition = try sourceMethod(
            named: "override func viewWillTransition(",
            in: fixture
        )
        let commit = try sourceMethod(
            named: "private func recordOpenScenarioWidthTransitionLayoutCommit(",
            in: fixture
        )
        let endpoint = try sourceMethod(
            named: "private func finalizeOpenScenarioRotationOffsetEndpointIfReady()",
            in: fixture
        )
        let render = try sourceMethod(
            named: "private func renderOpenScenarioPhase(",
            in: fixture
        )

        XCTAssertTrue(transition.contains("recordSourceAdmission("))
        XCTAssertTrue(transition.contains("recordCoordinatorCompletion("))
        XCTAssertTrue(commit.contains("recordProductionCommit("))
        XCTAssertTrue(endpoint.contains("recordEndpoint()"))
        XCTAssertTrue(render.contains(
            "openScenarioRotationBarrierDiagnostics.accessibilityFields"
        ))
        XCTAssertTrue(fixture.contains(
            "CHAT_OPEN_FIXTURE_ROTATION_BARRIER"
        ))
    }

    func testRealPipelineLaunchDescriptorRejectsMissingInvalidAndDuplicateScenarioValues() {
        let baseArguments = [
            "xabber",
            ChatPerformanceUITestLaunchPolicy.launchArgument,
            ChatPerformanceFixtureScale.small.rawValue,
            ChatPerformanceUITestLaunchPolicy.openScenarioLaunchArgument
        ]
        let environment = [ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey: "1"]

        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: baseArguments,
            environment: environment
        ))
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: baseArguments + ["not-a-scenario"],
            environment: environment
        ))
        XCTAssertNil(ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: baseArguments + [
                ChatOpenRealPipelineFixtureScenario.preloadedLatest.rawValue,
                ChatPerformanceUITestLaunchPolicy.openScenarioLaunchArgument,
                ChatOpenRealPipelineFixtureScenario.confirmedEmpty.rawValue
            ],
            environment: environment
        ))
    }

    func testRealPipelineScenarioPlansCoverTheFiveRequiredOpeningContracts() {
        let preloaded = ChatOpenRealPipelineFixturePlan(
            scenario: .preloadedLatest
        )
        XCTAssertEqual(preloaded.initialLocalMessageCount, 320)
        XCTAssertEqual(preloaded.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(preloaded.expectedFinalRealRowCount, 80)
        XCTAssertFalse(preloaded.requiresRemoteInjection)
        XCTAssertEqual(preloaded.targetKind, .latest)

        let empty = ChatOpenRealPipelineFixturePlan(scenario: .confirmedEmpty)
        XCTAssertEqual(empty.initialLocalMessageCount, 0)
        XCTAssertEqual(empty.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(empty.expectedFinalRealRowCount, 0)
        XCTAssertTrue(empty.expectsConfirmedEmpty)
        XCTAssertFalse(empty.requiresRemoteInjection)
        XCTAssertEqual(empty.targetKind, .empty)

        let bootstrap = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapEmptyToContent
        )
        XCTAssertEqual(bootstrap.initialLocalMessageCount, 0)
        XCTAssertEqual(bootstrap.expectedInitialSkeletonRowCount, 30)
        XCTAssertEqual(bootstrap.expectedFinalRealRowCount, 80)
        XCTAssertTrue(bootstrap.requiresRemoteInjection)
        XCTAssertEqual(bootstrap.remoteInjectionOrdinalRange, 0..<80)
        XCTAssertEqual(bootstrap.targetKind, .latest)

        let push = ChatOpenRealPipelineFixturePlan(
            scenario: .notificationExactLocal
        )
        XCTAssertEqual(push.initialLocalMessageCount, 320)
        XCTAssertEqual(push.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(push.expectedFinalRealRowCount, 80)
        XCTAssertFalse(push.requiresRemoteInjection)
        XCTAssertEqual(push.targetKind, .anchor)
        XCTAssertEqual(push.expectedRequestSource, .pushNotification)

        let search = ChatOpenRealPipelineFixturePlan(
            scenario: .searchExactLocal
        )
        XCTAssertEqual(search.initialLocalMessageCount, 320)
        XCTAssertEqual(search.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(search.expectedFinalRealRowCount, 80)
        XCTAssertFalse(search.requiresRemoteInjection)
        XCTAssertEqual(search.targetKind, .anchor)
        XCTAssertEqual(search.expectedRequestSource, .search)

        let gap = ChatOpenRealPipelineFixturePlan(
            scenario: .knownGapMissingTarget
        )
        XCTAssertEqual(gap.initialLocalMessageCount, 160)
        XCTAssertEqual(gap.expectedInitialSkeletonRowCount, 30)
        XCTAssertEqual(gap.expectedFinalRealRowCount, 80)
        XCTAssertTrue(gap.requiresRemoteInjection)
        XCTAssertEqual(gap.remoteInjectionOrdinalRange, 120..<200)
        XCTAssertEqual(gap.remoteInjectionOrdinalRange?.count, 80)
        XCTAssertEqual(160 - (gap.remoteInjectionOrdinalRange?.lowerBound ?? 160), 40)
        XCTAssertEqual((gap.remoteInjectionOrdinalRange?.upperBound ?? 161) - 160 - 1, 39)
        XCTAssertEqual(gap.targetKind, .anchor)
    }

    func testEveryVideoRouteSealsAfterItsRenderedPresentationReceipt() {
        let skeletonRoutes: [ChatOpenRealPipelineFixtureScenario] = [
            .bootstrapHeldOverWatchdog,
            .bootstrapTerminalFailureRetry
        ]
        let emptyRoutes: [ChatOpenRealPipelineFixtureScenario] = [
            .confirmedEmpty,
            .bootstrapEmptyToTrustedEmpty
        ]

        XCTAssertEqual(
            ChatOpenRealPipelineFixtureScenario.allCases.count,
            25
        )
        for scenario in ChatOpenRealPipelineFixtureScenario.allCases {
            let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
            if skeletonRoutes.contains(scenario) {
                XCTAssertEqual(
                    plan.stableFramePresentationReceipt,
                    .skeleton,
                    scenario.rawValue
                )
                XCTAssertTrue(plan.allowsSkeletonStableFrame)
            } else if emptyRoutes.contains(scenario) {
                XCTAssertEqual(
                    plan.stableFramePresentationReceipt,
                    .empty,
                    scenario.rawValue
                )
            } else {
                XCTAssertEqual(
                    plan.stableFramePresentationReceipt,
                    .content,
                    scenario.rawValue
                )
            }
        }
    }

    func testE04UnsyncedStaleLocalPlanSeedsRowsButRequiresBlockingSkeleton() {
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapStaleLocalToContent
        )
        let emptyLocalPlan = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapEmptyToContent
        )

        XCTAssertEqual(plan.scenario.rawValue, "bootstrap-stale-local-to-content")
        XCTAssertNotEqual(plan.scenario, emptyLocalPlan.scenario)
        XCTAssertEqual(plan.videoMatrixRouteCode, "E04")
        XCTAssertEqual(plan.initialLocalMessageCount, 320)
        XCTAssertTrue(plan.startsWithoutDurableReadiness)
        XCTAssertEqual(plan.expectedInitialSkeletonRowCount, 30)
        XCTAssertEqual(plan.expectedFinalRealRowCount, 80)
        XCTAssertEqual(plan.expectedDatasourceApplyCount, 2)
        XCTAssertTrue(plan.requiresRemoteInjection)
        XCTAssertTrue(plan.usesFixtureArchiveTransport)
        XCTAssertEqual(plan.remoteInjectionOrdinalRange, 240..<320)
        XCTAssertEqual(plan.remoteInjectionOrdinalRange?.count, 80)
        XCTAssertEqual(plan.acknowledgedRemoteAction, .injectContentPage)
        XCTAssertFalse(plan.successfulArchiveFinalIsComplete)
        XCTAssertEqual(plan.successfulArchiveServerResultCount, 320)
        XCTAssertEqual(
            emptyLocalPlan.successfulArchiveServerResultCount,
            80,
            "Existing E02 content cardinality must stay page-local"
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixturePlan(
                scenario: .notificationExactRemote
            ).successfulArchiveServerResultCount,
            1,
            "Existing exact-target cardinality must stay unchanged"
        )
        XCTAssertEqual(plan.targetKind, .latest)
        XCTAssertNil(plan.expectedRequestSource)
        XCTAssertNil(plan.expectedTargetOrdinal)
    }


    func testEveryMessageTargetRoutePlanMatchesProductionHighlightPolicy() {
        let expectedRoutes: [(
            ChatOpenRealPipelineFixtureScenario,
            ChatOpenMessageRequestSource,
            Bool
        )] = [
            (.notificationExactLocal, .pushNotification, true),
            (.notificationExactRemote, .pushNotification, true),
            (.notificationKnownGapTarget, .pushNotification, true),
            (.coldPushExact, .pushNotification, true),
            (.mentionDeletedAdvance, .mentionNotification, true),
            (.lastChatsSeededMentionExact, .mentionNotification, false),
            (.searchExactLocal, .search, true),
            (.searchExactLocalOutsideWindow, .search, true),
            (.searchExactRemote, .search, true),
            (.knownGapMissingTarget, .directOpenAtMessage, false),
            (.newerCrossingGap, .directOpenAtMessage, false),
            (.unreadBoundaryLocal, .initialUnreadBoundary, false),
            (.savedPositionLocal, .savedVisiblePosition, false)
        ]

        for (scenario, source, highlight) in expectedRoutes {
            let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
            XCTAssertEqual(plan.expectedRequestSource, source, scenario.rawValue)
            XCTAssertEqual(
                plan.expectedRequestHighlight,
                highlight,
                scenario.rawValue
            )
        }

        for scenario in ChatOpenRealPipelineFixtureScenario.allCases where
            !expectedRoutes.contains(where: { $0.0 == scenario }) {
            let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
            XCTAssertNil(plan.expectedRequestSource, scenario.rawValue)
            XCTAssertNil(plan.expectedRequestHighlight, scenario.rawValue)
        }
    }

    func testEveryMessageTargetRoutePlanMatchesProductionMarkReadOnVisiblePolicy() {
        let expectedRoutes: [(
            ChatOpenRealPipelineFixtureScenario,
            Bool
        )] = [
            (.notificationExactLocal, true),
            (.notificationExactRemote, true),
            (.notificationKnownGapTarget, true),
            (.coldPushExact, true),
            (.mentionDeletedAdvance, true),
            (.lastChatsSeededMentionExact, true),
            (.searchExactLocal, false),
            (.searchExactLocalOutsideWindow, false),
            (.searchExactRemote, false),
            (.knownGapMissingTarget, false),
            (.newerCrossingGap, false),
            (.unreadBoundaryLocal, false),
            (.savedPositionLocal, false)
        ]

        for (scenario, markReadOnVisible) in expectedRoutes {
            let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
            XCTAssertEqual(
                plan.expectedRequestMarkReadOnVisible,
                markReadOnVisible,
                scenario.rawValue
            )
        }

        for scenario in ChatOpenRealPipelineFixtureScenario.allCases where
            !expectedRoutes.contains(where: { $0.0 == scenario }) {
            XCTAssertNil(
                ChatOpenRealPipelineFixturePlan(scenario: scenario)
                    .expectedRequestMarkReadOnVisible,
                scenario.rawValue
            )
        }
    }

    func testVideoMatrixRouteCodesIncludeCanonicalX01AndP14Routes() {
        let bindings = ChatOpenRealPipelineFixtureScenario.allCases.compactMap {
            scenario -> (String, String)? in
            guard let matrixRouteCode = ChatOpenRealPipelineFixturePlan(
                scenario: scenario
            ).videoMatrixRouteCode else {
                return nil
            }
            return (matrixRouteCode, scenario.rawValue)
        }
        XCTAssertEqual(bindings.count, 25)
        XCTAssertEqual(Set(bindings.map(\.0)).count, 25)
        XCTAssertEqual(Set(bindings.map(\.1)).count, 25)

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .searchExactLocal
        )
        XCTAssertEqual(plan.videoMatrixRouteCode, "X01")
        XCTAssertEqual(plan.scenario.rawValue, "search-exact-local")
        XCTAssertEqual(plan.expectedRequestSource, .search)
        XCTAssertEqual(plan.expectedRequestHighlight, true)
        XCTAssertEqual(plan.expectedRequestMarkReadOnVisible, false)
        XCTAssertEqual(plan.targetKind, .anchor)
        XCTAssertEqual(plan.expectedTargetOrdinal, 160)
        XCTAssertFalse(plan.requiresRemoteInjection)
        XCTAssertFalse(plan.usesFixtureArchiveTransport)
        XCTAssertFalse(plan.hasKnownGapTopology)
        XCTAssertFalse(plan.requiresPostInitialInteraction)
        XCTAssertEqual(plan.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(plan.expectedDatasourceApplyCount, 1)

        let p13 = ChatOpenRealPipelineFixturePlan(
            scenario: .mentionDeletedAdvance
        )
        XCTAssertEqual(p13.videoMatrixRouteCode, "P13")
        XCTAssertEqual(p13.scenario.rawValue, "mention-deleted-advance")
        XCTAssertEqual(p13.expectedRequestSource, .mentionNotification)
        XCTAssertEqual(p13.expectedRequestHighlight, true)
        XCTAssertEqual(p13.expectedRequestMarkReadOnVisible, true)
        XCTAssertEqual(p13.targetKind, .anchor)
        XCTAssertEqual(p13.expectedTargetOrdinal, 160)
        XCTAssertEqual(p13.p13DeletedMentionOrdinal, 120)
        XCTAssertEqual(p13.p13NextValidMentionOrdinal, 160)
        XCTAssertEqual(p13.initialLocalMessageCount, 320)
        XCTAssertFalse(p13.requiresRemoteInjection)
        XCTAssertEqual(p13.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(p13.expectedDatasourceApplyCount, 1)
        XCTAssertEqual(p13.artifactTraceContract, .initialLocalContent)
    }

    func testP13SynchronousAdmissionDoesNotRequirePostRouteTapReceiptWhileTerminalGateDoes()
        throws {
        let source = try repositorySource(
            "xabber/controllers/chats/chat/ChatPerformanceRouteHost.swift"
        )
        let tapMethod = try sourceMethod(
            named: "internal func performP13SourceRowTapForTesting()",
            in: source
        )
        XCTAssertTrue(tapMethod.contains(
            "tableView(tableView, didSelectRowAt: indexPath)"
        ))
        XCTAssertFalse(
            tapMethod.contains(
                "performanceP13SourceRowTapCountForTesting = 1"
            ),
            "The hosted tap must preserve UIKit ordering: synchronous request admission precedes the post-route tap receipt"
        )

        let admissionMethod = try sourceMethod(
            named: "private func recordP13ProductionRequestAdmission(",
            in: source
        )
        XCTAssertTrue(admissionMethod.contains(
            "performanceP13DatasourceWasProductionAppliedForTesting"
        ))
        XCTAssertTrue(admissionMethod.contains(
            "performanceP13SourceRowVisibleForTesting"
        ))
        XCTAssertFalse(
            admissionMethod.contains(
                "performanceP13SourceRowTapCountForTesting"
            ),
            "The exact synchronous request is admitted before viewWillDisappear and the attempt callback can publish tap evidence"
        )

        func diagnostics(
            tapCount: Int
        ) -> ChatPerformanceRouteHostDiagnostics {
            ChatPerformanceRouteHostDiagnostics(
                rootInstalled: true,
                lastChatsVisibleBeforeRoute: false,
                routeAttemptCount: 1,
                nativePushCount: 1,
                destinationOpaqueBeforeFirstRow: true,
                lastChatsExposureCount: 0,
                coldPendingBeforeRoot: 0,
                accountMaterializationCount: 1,
                coldConsumeBeforeStableCount: 0,
                coldConsumeAfterStableCount: 0,
                hostKind: .notificationsDeletedMention,
                p13SourceRowVisibleBeforeTap: true,
                p13SourceRowTapCount: tapCount,
                p13AttemptCount: 1,
                p13InvalidationCount: 1,
                p13AdvanceCount: 1,
                p13UnavailableCount: 0,
                p13SelectedNextIdentityCount: 1,
                p13UnrelatedGroupPreservedCount: 1
            )
        }
        XCTAssertFalse(
            diagnostics(tapCount: 0).isAccepted(
                for: .mentionDeletedAdvance
            ),
            "Terminal acceptance must remain fail-closed until the real tap receipt arrives"
        )
        XCTAssertTrue(
            diagnostics(tapCount: 1).isAccepted(
                for: .mentionDeletedAdvance
            )
        )
    }

    @MainActor
    func testP13AttemptObserverCountsEveryMatchingProductionCallbackAndRejectsDuplicates()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousInterfaceType =
            CommonConfigManager.shared.config.interface_type
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let previousConnectingUsers =
            AccountManager.shared.connectingUsers.value
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p13-duplicate-attempt-\(UUID().uuidString)"
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            NotifyManager.shared
                .resetPendingMessageNotificationChatRouteForTesting()
            AccountManager.shared.users = previousUsers
            AccountManager.shared.activeUsers.accept(previousActiveUsers)
            AccountManager.shared.authenticatedUsers.accept(
                previousAuthenticatedUsers
            )
            AccountManager.shared.connectingUsers.accept(
                previousConnectingUsers
            )
            CommonConfigManager.shared.config.interface_type =
                previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .mentionDeletedAdvance
        )
        let coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let chatsNavigationController = try XCTUnwrap(
            tabController.viewControllers?.first as? UINavigationController
        )
        let lastChatsHost = try XCTUnwrap(
            chatsNavigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            lastChatsHost.compactChatDestinationFactory() as?
                ChatPerformanceFixtureViewController
        )
        let notificationsHost = try XCTUnwrap(
            (tabController.viewControllers?[2] as? UINavigationController)?
                .viewControllers.first as?
                ChatPerformanceMentionNotificationsRouteHostViewController
        )
        defer {
            chatsNavigationController.delegate = nil
            destination.performOpenScenarioTerminalResourceTeardown()
        }

        let realm = try WRealm.safe()
        let nextNotification = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey:
                destination.p13NextMentionNotificationPrimaryForTesting
        ))
        let request = try XCTUnwrap(
            NotificationsListViewController.mentionOpenRequest(
                for: nextNotification
            )
        )
        let matchingAttempt = NotificationsMentionOpenAttemptDiagnostics(
            tappedNotificationPrimary:
                destination.p13DeletedMentionNotificationPrimaryForTesting,
            resolution: .exact(
                request,
                invalidatedNotificationPrimary:
                    destination
                        .p13DeletedMentionNotificationPrimaryForTesting
            ),
            selectedNotificationPrimary:
                destination.p13NextMentionNotificationPrimaryForTesting,
            didNavigate: true
        )
        let productionObserver = try XCTUnwrap(
            notificationsHost.mentionOpenAttemptObserverForTests
        )

        productionObserver(matchingAttempt)
        productionObserver(matchingAttempt)

        XCTAssertEqual(
            notificationsHost.performanceP13AttemptCountForTesting,
            2,
            "Every admitted matching production callback must remain visible"
        )
        XCTAssertEqual(
            notificationsHost.performanceP13InvalidationCountForTesting,
            1
        )
        XCTAssertEqual(
            notificationsHost.performanceP13AdvanceCountForTesting,
            1
        )
        XCTAssertEqual(
            notificationsHost
                .performanceP13SelectedNextIdentityCountForTesting,
            1
        )
        let routeDiagnostics =
            lastChatsHost.performanceRouteHostDiagnosticsSnapshot
        XCTAssertEqual(routeDiagnostics.p13AttemptCount, 2)
        XCTAssertFalse(
            routeDiagnostics.isAccepted(for: .mentionDeletedAdvance),
            "A duplicate admitted attempt must fail the P13 route gate"
        )
        func otherwiseAcceptedP13Diagnostics(
            attemptCount: Int
        ) -> ChatPerformanceRouteHostDiagnostics {
            ChatPerformanceRouteHostDiagnostics(
                rootInstalled: true,
                lastChatsVisibleBeforeRoute: false,
                routeAttemptCount: 1,
                nativePushCount: 1,
                destinationOpaqueBeforeFirstRow: true,
                lastChatsExposureCount: 0,
                coldPendingBeforeRoot: 0,
                accountMaterializationCount: 1,
                coldConsumeBeforeStableCount: 0,
                coldConsumeAfterStableCount: 0,
                hostKind: .notificationsDeletedMention,
                p13SourceRowVisibleBeforeTap: true,
                p13SourceRowTapCount: 1,
                p13AttemptCount: attemptCount,
                p13InvalidationCount: 1,
                p13AdvanceCount: 1,
                p13UnavailableCount: 0,
                p13SelectedNextIdentityCount: 1,
                p13UnrelatedGroupPreservedCount: 1
            )
        }
        XCTAssertTrue(
            otherwiseAcceptedP13Diagnostics(attemptCount: 1)
                .isAccepted(for: .mentionDeletedAdvance)
        )
        XCTAssertFalse(
            otherwiseAcceptedP13Diagnostics(
                attemptCount: routeDiagnostics.p13AttemptCount
            ).isAccepted(for: .mentionDeletedAdvance),
            "Attempt count must be the only changed rejection predicate"
        )
        XCTAssertNil(destination.openScenarioStableReceipt)
    }

    @MainActor
    func testP14LastChatsSeededMentionResolvesBeforeInitialFramePreparation()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-preparation-\(UUID().uuidString)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: plan.scenario
        ))
        defer { controller.performOpenScenarioTerminalResourceTeardown() }

        XCTAssertEqual(plan.scenario.rawValue, "last-chats-seeded-mention-exact")
        XCTAssertEqual(plan.videoMatrixRouteCode, "P14")
        XCTAssertEqual(plan.artifactTraceContract, .initialLocalContent)
        XCTAssertEqual(controller.conversationType, .group)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(plan.expectedRequestSource, .mentionNotification)
        XCTAssertEqual(plan.expectedRequestHighlight, false)
        XCTAssertEqual(plan.expectedRequestMarkReadOnVisible, true)
        XCTAssertEqual(plan.expectedTargetOrdinal, plan.p14ExplicitMentionOrdinal)
        XCTAssertEqual(plan.initialLocalMessageCount, 320)
        XCTAssertEqual(plan.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(plan.expectedDatasourceApplyCount, 1)
        XCTAssertFalse(plan.requiresRemoteInjection)
        XCTAssertFalse(plan.hasKnownGapTopology)

        let candidates = [
            plan.p14ExplicitMentionOrdinal,
            plan.p14UnreadTargetOrdinal,
            plan.p14SavedTargetOrdinal,
            plan.p14LatestTargetOrdinal
        ]
        XCTAssertEqual(Set(candidates).count, 4)

        let realm = try WRealm.safe()
        let groupMessages = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            controller.owner,
            controller.jid,
            ClientSynchronizationManager.ConversationType.group.rawValue
        )
        let regularMessages = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            controller.owner,
            controller.jid,
            ClientSynchronizationManager.ConversationType.regular.rawValue
        )
        XCTAssertEqual(groupMessages.count, 320)
        XCTAssertEqual(regularMessages.count, 0)
        XCTAssertNil(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: .regular
            )
        ))
        XCTAssertNil(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: .regular
            )
        ))
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: .group
            )
        ))
        XCTAssertEqual(chat.mentionId, controller.openScenarioArchiveId(
            plan.p14ExplicitMentionOrdinal
        ))
        XCTAssertEqual(chat.syncUnreadAfterId, controller.openScenarioArchiveId(
            plan.p14UnreadBoundaryOrdinal
        ))
        XCTAssertEqual(chat.lastVisibleMessagePrimary, controller.openScenarioPrimary(
            plan.p14SavedTargetOrdinal
        ))
        XCTAssertEqual(chat.lastMessageId, controller.openScenarioMessageId(
            plan.p14LatestTargetOrdinal
        ))

        let persistedMentionCandidates = realm.objects(
            NotificationStorageItem.self
        ).filter(
            "owner == %@ AND category_ == %@ AND associatedJid == %@",
            controller.owner,
            XMPPNotificationsManager.Category.mention.rawValue,
            controller.jid
        ).filter {
            $0.sourceArchivedId == chat.mentionId &&
                $0.sourceConversationType == .group
        }
        XCTAssertEqual(persistedMentionCandidates.count, 1)
        let notification = try XCTUnwrap(persistedMentionCandidates.first)
        XCTAssertNotNil(notification.realm)
        XCTAssertEqual(
            notification.primary,
            controller.p14MentionNotificationPrimaryForTesting
        )
        XCTAssertFalse(notification.isRead)
        XCTAssertTrue(notification.shouldShow)
        XCTAssertEqual(notification.category, .mention)
        XCTAssertEqual(notification.sourceConversationType, .group)
        XCTAssertEqual(notification.sourceArchivedId, chat.mentionId)
        XCTAssertEqual(notification.mentionLinkStatus, .resolved)
        let firstUnreadIncomingAfterBoundary = groupMessages
            .filter(
                "outgoing == false AND isRead == false AND date > %@",
                Date(
                    timeIntervalSince1970:
                        1_700_000_000 +
                        TimeInterval(plan.p14UnreadBoundaryOrdinal * 60)
                )
            )
            .sorted(byKeyPath: "date", ascending: true)
            .first
        XCTAssertEqual(
            firstUnreadIncomingAfterBoundary?.archivedId,
            controller.openScenarioArchiveId(plan.p14UnreadTargetOrdinal)
        )
        XCTAssertEqual(controller.p14MentionReadCommittedCountForTesting, 0)
    }

    @MainActor
    func testP14SeededMentionSurvivesProductionStartupReconciliation()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-startup-reconcile-\(UUID().uuidString)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: plan.scenario
        ))
        defer { controller.performOpenScenarioTerminalResourceTeardown() }

        let realm = try WRealm.safe()
        let targetMessage = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: controller.openScenarioPrimary(
                plan.p14ExplicitMentionOrdinal
            )
        ))
        let notification = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: controller.p14MentionNotificationPrimaryForTesting
        ))
        let targetMemberId = try XCTUnwrap(notification.mentionTargetUserId)
        XCTAssertEqual(
            targetMessage.groupchatAuthorId,
            notification.sourceSenderId
        )
        let matchingMentionReferences = targetMessage.references.filter {
            $0.kind == .mention &&
                ($0.metadata?["memberId"] as? String) == targetMemberId &&
                ($0.metadata?["groupchatJid"] as? String) == controller.jid
        }
        XCTAssertEqual(matchingMentionReferences.count, 1)

        var messagePrimariesToMarkRead: Set<String> = []
        try realm.write {
            messagePrimariesToMarkRead =
                MentionNotificationSync.reconcileMentionNotifications(
                    for: controller.owner,
                    in: realm
                )
        }

        XCTAssertTrue(messagePrimariesToMarkRead.isEmpty)
        XCTAssertFalse(notification.isRead)
        XCTAssertTrue(notification.shouldShow)
        XCTAssertEqual(notification.mentionLinkStatus, .resolved)
        let lastChat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: .group
            )
        ))
        let membership = try XCTUnwrap(realm.object(
            ofType: GroupSelfMembershipStorageItem.self,
            forPrimaryKey: GroupStorageKey.groupPrimary(
                owner: controller.owner,
                groupJID: controller.jid
            )
        ))
        XCTAssertEqual(membership.memberID, targetMemberId)
        XCTAssertEqual(
            lastChat.mentionId,
            controller.openScenarioArchiveId(plan.p14ExplicitMentionOrdinal)
        )
        XCTAssertTrue(controller.captureP14MentionPreTapProofIfNeeded())
    }

    @MainActor
    func testP14SeededMentionWinsOnlyForExplicitMentionIntentAfterProductPolicyResolution()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-policy-\(UUID().uuidString)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: plan.scenario
        ))
        defer { controller.performOpenScenarioTerminalResourceTeardown() }
        let realm = try WRealm.safe()

        let explicit = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group,
                in: realm
            )
        )
        let winning = try XCTUnwrap(
            LastChatsViewController.initialOpenRequest(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group,
                explicitOpenMessageRequest: explicit,
                in: realm
            )
        )
        XCTAssertEqual(winning.source, .mentionNotification)
        XCTAssertEqual(
            winning.anchor.archivedId,
            controller.openScenarioArchiveId(plan.p14ExplicitMentionOrdinal)
        )
        XCTAssertFalse(winning.highlight)
        XCTAssertTrue(winning.markReadOnVisible)

        let notification = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: controller.p14MentionNotificationPrimaryForTesting
        ))
        XCTAssertNotNil(notification.realm)
        try realm.write { notification.mentionLinkStatus = .invalidated }
        XCTAssertTrue(
            try XCTUnwrap(realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: controller.jid,
                    owner: controller.owner,
                    conversationType: .group
                )
            )).hasUnreadMention,
            "A badge alone must not be promoted to explicit P14 intent"
        )
        XCTAssertNil(LastChatsViewController.unreadMentionOpenRequest(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group,
            in: realm
        ))
        let generic = try XCTUnwrap(LastChatsViewController.initialOpenRequest(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group,
            explicitOpenMessageRequest: nil,
            in: realm
        ))
        XCTAssertEqual(generic.source, .initialUnreadBoundary)
        XCTAssertEqual(
            generic.anchor.archivedId,
            controller.openScenarioArchiveId(plan.p14UnreadBoundaryOrdinal)
        )
        XCTAssertNotEqual(generic.anchor.archivedId, winning.anchor.archivedId)

        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: .group
            )
        ))
        try realm.write {
            chat.unread = 0
            chat.syncUnreadCount = 0
            chat.runtimeUnreadCount = 0
            chat.syncUnreadAfterId = nil
            chat.lastReadId = nil
        }
        let saved = try XCTUnwrap(LastChatsViewController.initialOpenRequest(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group,
            explicitOpenMessageRequest: nil,
            in: realm
        ))
        XCTAssertEqual(saved.source, .savedVisiblePosition)
        XCTAssertEqual(
            saved.anchor.messagePrimary,
            controller.openScenarioPrimary(plan.p14SavedTargetOrdinal)
        )

        try realm.write {
            chat.lastVisibleMessagePrimary = nil
            chat.lastVisibleMessageArchivedId = nil
            chat.lastVisibleMessageId = nil
            chat.lastVisibleMessageDate = nil
        }
        XCTAssertNil(LastChatsViewController.initialOpenRequest(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group,
            explicitOpenMessageRequest: nil,
            in: realm
        ))
        XCTAssertEqual(
            chat.lastMessageId,
            controller.openScenarioMessageId(plan.p14LatestTargetOrdinal)
        )
    }

    func testReadVisibleReceiptRecordsEarlyButEnqueuesRetryAtViewDidAppearTerminalBoundary()
        throws {
        let controllerSource = try repositorySource(
            "xabber/controllers/chats/chat/ChatViewController.swift"
        )
        let appearance = try sourceMethod(
            named: "override func viewDidAppear(_ animated: Bool)",
            in: controllerSource
        )
        let recordOffset = try XCTUnwrap(appearance.range(
            of: "recordReadVisiblePresentationReceiptHandoff()"
        )?.lowerBound)
        let transitionFallbackOffset = try XCTUnwrap(appearance.range(
            of: "retryReadStateAfterActivePresentationTransitionIfNeeded("
        )?.lowerBound)
        let pendingRequestOffset = try XCTUnwrap(appearance.range(
            of: "performPendingOpenMessageRequestIfNeeded()"
        )?.lowerBound)
        let frameOffset = try XCTUnwrap(appearance.range(
            of: "shouldChangeFrame()"
        )?.lowerBound)
        let observersOffset = try XCTUnwrap(appearance.range(
            of: "addObservers()"
        )?.lowerBound)
        let timingOffset = try XCTUnwrap(appearance.range(
            of: "recordChatOpenTimingFirstMessagesVisibleIfPossible("
        )?.lowerBound)
        let enqueueOffset = try XCTUnwrap(appearance.range(
            of: "enqueuePendingReadStateRetry("
        )?.lowerBound)

        XCTAssertLessThan(recordOffset, transitionFallbackOffset)
        XCTAssertLessThan(transitionFallbackOffset, pendingRequestOffset)
        XCTAssertLessThan(pendingRequestOffset, frameOffset)
        XCTAssertLessThan(frameOffset, observersOffset)
        XCTAssertLessThan(observersOffset, timingOffset)
        XCTAssertLessThan(timingOffset, enqueueOffset)

        let transitionFallback = try sourceMethod(
            named:
                "private func retryReadStateAfterActivePresentationTransitionIfNeeded(",
            in: controllerSource
        )
        XCTAssertTrue(transitionFallback.contains(
            "for handoff: ChatReadVisiblePresentationReceiptHandoff"
        ))
        XCTAssertTrue(transitionFallback.contains(
            "handoff.presentationGeneration"
        ))
        XCTAssertTrue(transitionFallback.contains(
            "enqueuePendingReadStateRetry(for: handoff)"
        ))
    }

    func testBatchALocalRoutePlansKeepDistinctProvenanceAndForbidArchiveTransport() {
        let unread = ChatOpenRealPipelineFixturePlan(
            scenario: .unreadBoundaryLocal
        )
        XCTAssertEqual(unread.initialLocalMessageCount, 320)
        XCTAssertEqual(unread.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(unread.expectedFinalRealRowCount, 80)
        XCTAssertFalse(unread.requiresRemoteInjection)
        XCTAssertEqual(unread.targetKind, .anchor)
        XCTAssertEqual(unread.expectedRequestSource, .initialUnreadBoundary)
        XCTAssertEqual(unread.unreadBoundaryOrdinal, 157)
        XCTAssertEqual(unread.expectedTargetOrdinal, 160)
        XCTAssertFalse(unread.hasUnrelatedOlderGap)

        let saved = ChatOpenRealPipelineFixturePlan(
            scenario: .savedPositionLocal
        )
        XCTAssertEqual(saved.initialLocalMessageCount, 320)
        XCTAssertEqual(saved.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(saved.expectedFinalRealRowCount, 80)
        XCTAssertFalse(saved.requiresRemoteInjection)
        XCTAssertEqual(saved.targetKind, .anchor)
        XCTAssertEqual(saved.expectedRequestSource, .savedVisiblePosition)
        XCTAssertNil(saved.unreadBoundaryOrdinal)
        XCTAssertEqual(saved.expectedTargetOrdinal, 160)
        XCTAssertFalse(saved.hasUnrelatedOlderGap)

        let unrelatedGap = ChatOpenRealPipelineFixturePlan(
            scenario: .latestWithUnrelatedOlderGap
        )
        XCTAssertEqual(unrelatedGap.initialLocalMessageCount, 160)
        XCTAssertEqual(unrelatedGap.expectedInitialSkeletonRowCount, 0)
        XCTAssertEqual(unrelatedGap.expectedFinalRealRowCount, 80)
        XCTAssertFalse(unrelatedGap.requiresRemoteInjection)
        XCTAssertEqual(unrelatedGap.targetKind, .latest)
        XCTAssertNil(unrelatedGap.expectedRequestSource)
        XCTAssertNil(unrelatedGap.expectedTargetOrdinal)
        XCTAssertTrue(unrelatedGap.hasUnrelatedOlderGap)
    }

    func testGroupMentionBulkPlanHasIdenticalCostAtSmallAndMillionLogicalScale() {
        let messageIndexes = Set(MessageStorageItem.indexedProperties())
        XCTAssertTrue(messageIndexes.contains("archivedId"))
        XCTAssertTrue(messageIndexes.contains("messageId"))

        let requests = (0..<80).map { index in
            ChatUnreadMentionBulkLookupRequest(
                notificationPrimary: "notification-\(index)",
                archivedId: index.isMultiple(of: 2) ? "archive-\(index)" : nil,
                messageId: "message-\(index)"
            )
        }
        let candidates = (0..<80).map { index in
            ChatUnreadMentionBulkCandidate(
                primary: "primary-\(String(format: "%03d", index))",
                archivedId: "archive-\(index)",
                messageId: "message-\(index)"
            )
        }
        let plan = ChatUnreadMentionBulkQueryPlan(
            requests: requests,
            limit: 80
        )

        let small = SparseIndexedGroupMentionHistory(
            logicalRowCount: 160,
            indexedCandidates: candidates
        ).execute(plan)
        let million = SparseIndexedGroupMentionHistory(
            logicalRowCount: 1_000_000,
            indexedCandidates: candidates
        ).execute(plan)

        XCTAssertEqual(small.resolution, million.resolution)
        XCTAssertEqual(small.cost, million.cost)
        XCTAssertEqual(small.cost.queryCount, 1)
        XCTAssertEqual(small.cost.fullScanCount, 0)
        XCTAssertEqual(small.cost.countQueryCount, 0)
        XCTAssertEqual(small.cost.offsetQueryCount, 0)
        XCTAssertLessThanOrEqual(small.cost.materializedCandidateCount, 80)
        XCTAssertEqual(plan.candidateLimit, 80)
        XCTAssertLessThanOrEqual(plan.archivedIds.count, 80)
        XCTAssertLessThanOrEqual(plan.messageIds.count, 80)
    }

    func testGroupMentionBulkPolicyIsDeterministicForDuplicateCandidateIdentifiers() {
        let plan = ChatUnreadMentionBulkQueryPlan(
            requests: [
                ChatUnreadMentionBulkLookupRequest(
                    notificationPrimary: "archived",
                    archivedId: "archive-duplicate",
                    messageId: nil
                ),
                ChatUnreadMentionBulkLookupRequest(
                    notificationPrimary: "message",
                    archivedId: nil,
                    messageId: "message-duplicate"
                )
            ],
            limit: 80
        )
        let candidates = [
            ChatUnreadMentionBulkCandidate(
                primary: "primary-z",
                archivedId: "archive-duplicate",
                messageId: "message-duplicate"
            ),
            ChatUnreadMentionBulkCandidate(
                primary: "primary-a",
                archivedId: "archive-duplicate",
                messageId: "message-duplicate"
            )
        ]

        let forward = ChatUnreadMentionBulkResolutionPolicy.resolve(
            plan: plan,
            candidates: candidates
        )
        let reversed = ChatUnreadMentionBulkResolutionPolicy.resolve(
            plan: plan,
            candidates: candidates.reversed()
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward["archived"], "primary-a")
        XCTAssertEqual(forward["message"], "primary-a")
    }

    @MainActor
    func testAnchorAdmissionAndResumeResolveOnlyFromImmutableSessionSnapshot() throws {
        let lookup = try sourceMethod(
            named: "private func sessionAnchorMessage(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(lookup.contains("timelineSession.snapshot"))
        XCTAssertTrue(lookup.contains("snapshot.item("))
        XCTAssertFalse(
            lookup.contains("timelineSession.resolvedMessage("),
            "synchronous anchor admission/resume must not fall through to Realm"
        )
        XCTAssertFalse(
            lookup.contains("resolvedSearchMessageResolution("),
            "archive-only search must wait for its immutable Phase-A proof"
        )
        XCTAssertFalse(
            lookup.contains("timelineSession.firstIncoming("),
            "unread admission must not use the session method whose miss path queries Realm"
        )
    }

    func testRealPipelineDiagnosticsDoNotClassifyServiceRowsAsSkeletons() {
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isSkeletonRow(
                isFakeMessage: true,
                hasSkeletonKind: true
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isSkeletonRow(
                isFakeMessage: true,
                hasSkeletonKind: false
            ),
            "Date separators are fake datasource rows, but are not loading skeletons"
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isSkeletonRow(
                isFakeMessage: false,
                hasSkeletonKind: true
            )
        )
    }

    func testRealPipelineDiagnosticsTreatConfirmedEmptyAsContentNotBlankFrame() {
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.previousOrBlankFrameCount(
                visualCommitCount: 1,
                unexpectedCommittedFrameCount: 0,
                intermediateEmptyFrameCount: 1,
                isConfirmedEmptyTerminal: true
            ),
            0
        )
        XCTAssertEqual(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.previousOrBlankFrameCount(
                visualCommitCount: 1,
                unexpectedCommittedFrameCount: 0,
                intermediateEmptyFrameCount: 1,
                isConfirmedEmptyTerminal: false
            ),
            1
        )
    }

    func testRealPipelineCommitPolicyAcceptsOnlyNoneForConfirmedEmpty() {
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
                targetKind: .empty,
                anchorStrategy: .none
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
                targetKind: .empty,
                anchorStrategy: .bottom
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
                targetKind: .empty,
                anchorStrategy: .message(
                    ChatViewportAnchor(primary: "fixture", viewportRelativeMinY: 0)
                )
            )
        )
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
                targetKind: .latest,
                anchorStrategy: .bottom
            )
        )
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
                targetKind: .anchor,
                anchorStrategy: .message(
                    ChatViewportAnchor(primary: "fixture", viewportRelativeMinY: 0)
                )
            )
        )
    }

    func testRealPipelineTerminalGateRetainsOneOwnerAcrossLateDuplicateCallbackAndPublishesOnce()
        throws {
        var gate = ChatOpenRealPipelineFixtureTerminalPublicationGate()
        let first = try XCTUnwrap(gate.beginObservation())

        XCTAssertTrue(gate.isCurrentObservation(first))
        XCTAssertNil(
            gate.beginObservation(),
            "An idempotent callback cannot supersede the active observation"
        )
        XCTAssertTrue(gate.beginStableTail(observationGeneration: first))
        XCTAssertFalse(gate.isCurrentObservation(first))
        XCTAssertTrue(gate.isCurrentStableTail(first))

        // A route-host callback may arrive after the quiet-window receipt has
        // handed ownership to the compositor/video tail. It must not create a
        // new generation that strands the already-running tail forever.
        XCTAssertNil(
            gate.beginObservation(),
            "A late duplicate callback cannot supersede the stable tail"
        )
        XCTAssertTrue(gate.isCurrentStableTail(first))
        XCTAssertTrue(gate.commitTerminal(observationGeneration: first))
        XCTAssertFalse(gate.isCurrentStableTail(first))
        XCTAssertFalse(gate.commitTerminal(observationGeneration: first))
        XCTAssertNil(gate.beginObservation())
    }

    func testRealPipelineTerminalGatePublishesFailureFromEveryUnpublishedPhase()
        throws {
        var idleGate = ChatOpenRealPipelineFixtureTerminalPublicationGate()
        XCTAssertTrue(idleGate.commitTerminal())
        XCTAssertTrue(idleGate.hasPublishedTerminal)
        XCTAssertFalse(idleGate.commitTerminal())

        var observingGate = ChatOpenRealPipelineFixtureTerminalPublicationGate()
        let observingGeneration = try XCTUnwrap(
            observingGate.beginObservation()
        )
        XCTAssertTrue(observingGate.commitTerminal(
            observationGeneration: observingGeneration
        ))
        XCTAssertTrue(observingGate.hasPublishedTerminal)

        var stableTailGate = ChatOpenRealPipelineFixtureTerminalPublicationGate()
        let stableTailGeneration = try XCTUnwrap(
            stableTailGate.beginObservation()
        )
        XCTAssertTrue(stableTailGate.beginStableTail(
            observationGeneration: stableTailGeneration
        ))
        XCTAssertTrue(stableTailGate.commitTerminal())
        XCTAssertTrue(stableTailGate.hasPublishedTerminal)
    }

    func testHostTerminalObservationStartsForCompletedVisualRouteBeforeAcceptance()
        throws {
        XCTAssertFalse(
            ChatPerformanceRouteHostDiagnostics.zero.isAccepted(
                for: .lastChatsAnimatedPush
            ),
            "The regression requires a route whose terminal diagnostics are rejected"
        )

        let fixture = try chatPerformanceFixtureSource()
        let admission = try sourceMethod(
            named: "private func beginOpenScenarioHostTerminalObservationIfReady()",
            in: fixture
        )
        XCTAssertTrue(admission.contains("openScenarioRouteHostDidComplete"))
        XCTAssertTrue(admission.contains(
            "openScenarioProductionVisualCommitCount == 1"
        ))
        XCTAssertTrue(admission.contains(
            "beginOpenScenarioTerminalObservation("
        ))
        XCTAssertFalse(
            admission.contains("isAccepted(for: scenario)"),
            "Host acceptance is terminal evidence. Rejecting it before the bounded observer starts strands the fixture without a stable or failed receipt."
        )
        let ownerAdmission = try XCTUnwrap(admission.range(
            of: "guard beginOpenScenarioTerminalObservation("
        ))
        let animatedInteraction = try XCTUnwrap(admission.range(
            of: "openScenarioPostInitialInteractionCount &+= 1"
        ))
        XCTAssertLessThan(
            ownerAdmission.lowerBound,
            animatedInteraction.lowerBound,
            "A late callback rejected by the one-shot gate must not mutate frozen terminal evidence"
        )

        let boundedObservation = try sourceMethod(
            named: "private func beginOpenScenarioTerminalObservation(",
            in: fixture
        )
        XCTAssertTrue(boundedObservation.contains(
            "Date().addingTimeInterval(8)"
        ))
        let terminalEvaluation = try sourceMethod(
            named: "private func captureOpenScenarioTerminalEvaluation(",
            in: fixture
        )
        XCTAssertTrue(terminalEvaluation.contains(
            "openScenarioRouteHostDiagnostics.isAccepted(for: plan.scenario)"
        ))
    }


    func testTerminalEvidenceSnapshotInitializerRetainsEveryVideoRouteField() {
        let snapshot = makeTerminalEvidenceSnapshot()

        XCTAssertEqual(snapshot.datasourceGeneration, 1)
        XCTAssertEqual(snapshot.datasourceApplyCount, 2)
        XCTAssertEqual(snapshot.firstContentApplyCount, 3)
        XCTAssertEqual(snapshot.visualCommitCount, 4)
        XCTAssertEqual(snapshot.stalePreTerminalRealFrameCount, 22)
        XCTAssertEqual(snapshot.mixedSkeletonAndRealFrameCount, 23)
        XCTAssertEqual(snapshot.offsetMutationCount, 5)
        XCTAssertEqual(snapshot.postCommitOffsetMutationCount, 6)
        XCTAssertEqual(snapshot.correctionCount, 7)
        XCTAssertEqual(snapshot.archiveRequestCount, 8)
        XCTAssertEqual(snapshot.gapRequestCount, 9)
        XCTAssertTrue(snapshot.retryVisible)
        XCTAssertTrue(snapshot.skeletonIdentityStable)
        XCTAssertTrue(snapshot.skeletonGeometryStable)
        XCTAssertEqual(snapshot.skeletonDwellMilliseconds, 13)
        XCTAssertEqual(snapshot.postInitialInteractionCount, 14)
        XCTAssertEqual(snapshot.pagingAnchorErrorMilliPoints, 15)
        XCTAssertEqual(snapshot.rotationTransitionCount, 16)
        XCTAssertEqual(snapshot.applicationBackgroundCount, 17)
        XCTAssertEqual(snapshot.applicationForegroundCount, 18)
        XCTAssertEqual(snapshot.productionBootstrapLeaseEventCount, 19)
        XCTAssertEqual(snapshot.productionBootstrapTransportCount, 20)
        XCTAssertEqual(snapshot.fixtureRealmQueryCountAfterRouteAdmission, 21)
        XCTAssertEqual(snapshot.activeProductionWorkCount, 0)
        XCTAssertEqual(
            snapshot.transportThreadSnapshot,
            makeTerminalTransportEvidence()
        )
        XCTAssertEqual(snapshot.routeHost, makeTerminalRouteHostEvidence())
        XCTAssertEqual(snapshot.p14Mention, .zero)
        XCTAssertEqual(TerminalEvidenceMutation.allCases.count, 27)
    }

    func testTerminalEvidenceProductionSamplePassesEveryRouteFieldExplicitly() throws {
        let source = try chatPerformanceFixtureSource()
        let capture = try sourceMethod(
            named: "private func captureOpenScenarioTerminalEvaluation(",
            in: source
        )
        let evidenceSuffix = try XCTUnwrap(capture.components(
            separatedBy:
                "let evidence = ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot("
        ).dropFirst().first)
        let initializerCall = try XCTUnwrap(evidenceSuffix.components(
            separatedBy: "let hasMeasurementPurity ="
        ).first)
        let requiredLabels = [
            "datasourceGeneration:",
            "datasourceApplyCount:",
            "firstContentApplyCount:",
            "visualCommitCount:",
            "stalePreTerminalRealFrameCount:",
            "mixedSkeletonAndRealFrameCount:",
            "offsetMutationCount:",
            "postCommitOffsetMutationCount:",
            "correctionCount:",
            "archiveRequestCount:",
            "gapRequestCount:",
            "retryVisible:",
            "skeletonIdentityStable:",
            "skeletonGeometryStable:",
            "skeletonDwellMilliseconds:",
            "postInitialInteractionCount:",
            "pagingAnchorErrorMilliPoints:",
            "rotationTransitionCount:",
            "applicationBackgroundCount:",
            "applicationForegroundCount:",
            "productionBootstrapLeaseEventCount:",
            "productionBootstrapTransportCount:",
            "fixtureRealmQueryCountAfterRouteAdmission:",
            "activeProductionWorkCount:",
            "transportThreadSnapshot:",
            "routeHost:",
            "p14Mention:"
        ]
        for label in requiredLabels {
            XCTAssertTrue(
                initializerCall.contains(label),
                "Production terminal sample omitted \(label)"
            )
        }
        XCTAssertEqual(requiredLabels.count, 27)
    }

    func testTerminalEvidenceEqualityInvalidatesQuietWindowForEveryRetainedField() {
        let baseline = makeTerminalEvidenceSnapshot()

        for mutation in TerminalEvidenceMutation.allCases {
            let changed = makeTerminalEvidenceSnapshot(mutation: mutation)
            XCTAssertNotEqual(
                changed,
                baseline,
                "Terminal evidence field must participate in equality: \(mutation)"
            )

            var gate = ChatOpenRealPipelineFixtureTerminalStabilityGate(
                quietWindow: 0.5
            )
            XCTAssertNil(gate.stableReceiptIfReady(
                evidence: baseline,
                hasExpectedTerminal: true,
                now: 10
            ))
            XCTAssertNil(gate.stableReceiptIfReady(
                evidence: changed,
                hasExpectedTerminal: true,
                now: 10.51
            ))
            XCTAssertNil(gate.stableReceiptIfReady(
                evidence: changed,
                hasExpectedTerminal: true,
                now: 10.99
            ))
            if mutation == .activeProductionWorkCount {
                XCTAssertNil(gate.stableReceiptIfReady(
                    evidence: changed,
                    hasExpectedTerminal: true,
                    now: 11.02
                ))
            } else {
                XCTAssertNotNil(gate.stableReceiptIfReady(
                    evidence: changed,
                    hasExpectedTerminal: true,
                    now: 11.02
                ))
            }
        }
    }

    func testTerminalEvidenceRouteValidationFailsClosedBeforeStableReceipt() throws {
        let accepted = makeTerminalEvidenceSnapshot()
        let rejected = makeTerminalEvidenceSnapshot(mutation: .routeHost)
        let scenario = ChatOpenRealPipelineFixtureScenario.lastChatsAnimatedPush
        XCTAssertTrue(accepted.routeHost.isAccepted(for: scenario))
        XCTAssertFalse(rejected.routeHost.isAccepted(for: scenario))

        var gate = ChatOpenRealPipelineFixtureTerminalStabilityGate(
            quietWindow: 0.5
        )
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: accepted,
            hasExpectedTerminal: true,
            now: 20
        ))
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: rejected,
            hasExpectedTerminal: rejected.routeHost.isAccepted(for: scenario),
            now: 20.6
        ))
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: accepted,
            hasExpectedTerminal: true,
            now: 21
        ))
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: accepted,
            hasExpectedTerminal: true,
            now: 21.49
        ))
        XCTAssertNotNil(gate.stableReceiptIfReady(
            evidence: accepted,
            hasExpectedTerminal: true,
            now: 21.51
        ))

        let source = try chatPerformanceFixtureSource()
        let capture = try sourceMethod(
            named: "private func captureOpenScenarioTerminalEvaluation(",
            in: source
        )
        XCTAssertTrue(capture.contains(
            "openScenarioRouteHostDiagnostics.isAccepted(for: plan.scenario)"
        ))
        XCTAssertTrue(capture.contains(
            "hasExpectedPostInitialInteraction &&\n" +
                "                hasExpectedRouteHost"
        ))
    }


    @MainActor
    func testObserverReplacementAndTeardownCancelTheExactQueueBoundRegistration() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-observer-replacement-\(UUID().uuidString)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let owner = "observer-replacement-owner@example.test"
        let jid = "observer-replacement-peer@example.test"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let realm = try WRealm.safe()
        try seedObserverConversation(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let messages = realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                owner,
                jid,
                conversationType.rawValue
            )
            .sorted(byKeyPath: "date", ascending: true)
            .map { $0.freeze() }
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        ))
        let ledger = ChatTimelineObservationRegistrationLedger()
        let cancellation = expectation(
            description: "old resident and final registrations cancelled"
        )
        cancellation.expectedFulfillmentCount = 3
        cancellation.assertForOverFulfill = true
        let hooks = ChatTimelineStoreObservationTestHooks(
            beforeRealmQuery: nil,
            didRegister: { ledger.recordRegistration($0) },
            didCancel: {
                ledger.recordCancellation($0)
                cancellation.fulfill()
            }
        )
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            observationTestHooks: hooks
        )
        let unexpectedChange = expectation(
            description: "registration replacement does not fabricate a change"
        )
        unexpectedChange.isInverted = true
        let observation = store.observe(
            baseline: ChatTimelineStoreObservationBaseline(
                isAuthoritative: true,
                residentItems: Array(messages.prefix(2)),
                latestMessageFingerprint: chat.lastMessage.map(
                    ChatTimelineObservedMessageFingerprint.init(message:)
                ),
                unreadCount: chat.unread,
                unreadMetadataLimit: 80
            ),
            onChange: { _ in unexpectedChange.fulfill() }
        )

        XCTAssertTrue(waitUntilObserverIdle(observation))
        observation.replaceResidentItems(Array(messages.suffix(2)))
        XCTAssertTrue(waitUntilObserverIdle(observation))
        observation.invalidate()
        wait(for: [cancellation], timeout: 2)
        wait(for: [unexpectedChange], timeout: 0.1)

        XCTAssertEqual(
            ledger.registrations,
            [
                .init(kind: .lastChats, generation: 1),
                .init(kind: .resident, generation: 1),
                .init(kind: .resident, generation: 2)
            ]
        )
        XCTAssertEqual(
            ledger.cancellations,
            [
                .init(kind: .resident, generation: 1),
                .init(kind: .lastChats, generation: 1),
                .init(kind: .resident, generation: 2)
            ]
        )
        let diagnostics = store.diagnosticsSnapshot.observation
        XCTAssertEqual(diagnostics.activationCount, 1)
        XCTAssertEqual(diagnostics.realmQueryCount, 3)
        XCTAssertEqual(diagnostics.mainThreadRealmQueryCount, 0)
        XCTAssertEqual(diagnostics.initialCallbackCount, 3)
        XCTAssertEqual(diagnostics.mainThreadInitialCallbackCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxInitialCandidateCount, 80)
        XCTAssertEqual(diagnostics.pendingWorkCount, 0)
    }

    @MainActor
    func testNonAuthoritativeResidentInitialDeliveryCatchesLinkedSensitivityChange() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-resident-sensitivity-catch-up-\(UUID().uuidString)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let owner = "observer-sensitivity-owner@example.test"
        let jid = "observer-sensitivity-peer@example.test"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let referencePrimary = "observer-sensitivity-reference"
        let realm = try WRealm.safe()
        try seedObserverConversation(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let message = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "observer-primary-0"
        ))
        let reference = MessageReferenceStorageItem()
        reference.primary = referencePrimary
        reference.owner = owner
        reference.jid = jid
        reference.messageId = message.primary
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.url = "https://files.example.test/sensitive.jpg"
        try realm.write {
            realm.add(reference, update: .modified)
            message.references.append(reference)
        }
        let baselineItem = message.freeze()
        let catchUp = expectation(
            description: "linked sensitivity change is delivered from initial resident catch-up"
        )
        catchUp.assertForOverFulfill = true
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            observationTestHooks: ChatTimelineStoreObservationTestHooks(
                beforeRealmQuery: { identity in
                    guard identity == .init(kind: .resident, generation: 1) else {
                        return
                    }
                    let callbackRealm = try! WRealm.safe()
                    let callbackReference = callbackRealm.object(
                        ofType: MessageReferenceStorageItem.self,
                        forPrimaryKey: referencePrimary
                    )!
                    try! callbackRealm.write {
                        callbackReference.isSensitive = true
                        callbackReference.isSensitiveChecked = true
                    }
                },
                didRegister: nil,
                didCancel: nil
            )
        )
        let observation = store.observe(
            baseline: ChatTimelineStoreObservationBaseline(
                isAuthoritative: false,
                residentItems: [baselineItem],
                latestMessageFingerprint: nil,
                unreadCount: 0,
                unreadMetadataLimit: 80
            ),
            onChange: { change in
                guard case .incremental(let batch, _) = change,
                      let payload = batch.mutations.first?.payload,
                      payload.primary == baselineItem.primary,
                      payload.references.first?.isSensitive == true,
                      payload.references.first?.isSensitiveChecked == true else {
                    return
                }
                catchUp.fulfill()
            }
        )

        wait(for: [catchUp], timeout: 2)
        XCTAssertTrue(waitUntilObserverIdle(observation))
        XCTAssertEqual(
            store.diagnosticsSnapshot.observation.catchUpMutationCount,
            1
        )
        observation.invalidate()
    }

    @MainActor
    func testNonAuthoritativeResidentInitialDeliveryCatchesCommittedTombstone() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-resident-tombstone-catch-up-\(UUID().uuidString)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let owner = "observer-tombstone-owner@example.test"
        let jid = "observer-tombstone-peer@example.test"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let messagePrimary = "observer-primary-0"
        let realm = try WRealm.safe()
        try seedObserverConversation(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let message = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: messagePrimary
        ))
        let baselineItem = message.freeze()
        let catchUp = expectation(
            description: "committed tombstone is delivered from initial resident catch-up"
        )
        catchUp.assertForOverFulfill = true
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            observationTestHooks: ChatTimelineStoreObservationTestHooks(
                beforeRealmQuery: { identity in
                    guard identity == .init(kind: .resident, generation: 1) else {
                        return
                    }
                    let callbackRealm = try! WRealm.safe()
                    let callbackMessage = callbackRealm.object(
                        ofType: MessageStorageItem.self,
                        forPrimaryKey: messagePrimary
                    )!
                    try! callbackRealm.write {
                        callbackMessage.isDeleted = true
                    }
                },
                didRegister: nil,
                didCancel: nil
            )
        )
        let observation = store.observe(
            baseline: ChatTimelineStoreObservationBaseline(
                isAuthoritative: false,
                residentItems: [baselineItem],
                latestMessageFingerprint: nil,
                unreadCount: 0,
                unreadMetadataLimit: 80
            ),
            onChange: { change in
                guard case .incremental(let batch, _) = change,
                      let mutation = batch.mutations.first,
                      mutation.identity.primary == messagePrimary,
                      case .delete = mutation.operation else {
                    return
                }
                catchUp.fulfill()
            }
        )

        wait(for: [catchUp], timeout: 2)
        XCTAssertTrue(waitUntilObserverIdle(observation))
        XCTAssertEqual(
            store.diagnosticsSnapshot.observation.catchUpMutationCount,
            1
        )
        observation.invalidate()
    }

    @MainActor
    func testObserverDeinitWithoutExplicitInvalidationDoesNotResurrectLeakOrDeliverCallback() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-observer-deinit-\(UUID().uuidString)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let owner = "observer-deinit-owner@example.test"
        let jid = "observer-deinit-peer@example.test"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let realm = try WRealm.safe()
        try seedObserverConversation(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let residentItems = Array(
            realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                    owner,
                    jid,
                    conversationType.rawValue
                )
                .sorted(byKeyPath: "date", ascending: true)
                .map { $0.freeze() }
        )
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        ))
        let ledger = ChatTimelineObservationRegistrationLedger()
        let cancellation = expectation(
            description: "deinit cancels both queue-bound registrations"
        )
        cancellation.expectedFulfillmentCount = 2
        cancellation.assertForOverFulfill = true
        let unexpectedChange = expectation(
            description: "deinitialized observation cannot deliver"
        )
        unexpectedChange.isInverted = true
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            observationTestHooks: ChatTimelineStoreObservationTestHooks(
                beforeRealmQuery: nil,
                didRegister: { ledger.recordRegistration($0) },
                didCancel: {
                    ledger.recordCancellation($0)
                    cancellation.fulfill()
                }
            )
        )
        var observation: ChatTimelineStoreObservation? = store.observe(
            baseline: ChatTimelineStoreObservationBaseline(
                isAuthoritative: true,
                residentItems: residentItems,
                latestMessageFingerprint: chat.lastMessage.map(
                    ChatTimelineObservedMessageFingerprint.init(message:)
                ),
                unreadCount: chat.unread,
                unreadMetadataLimit: 80
            ),
            onChange: { _ in unexpectedChange.fulfill() }
        )
        XCTAssertTrue(waitUntilObserverIdle(try XCTUnwrap(observation)))
        weak var weakObservation: AnyObject?
        weakObservation = observation

        observation = nil
        XCTAssertNil(weakObservation)
        wait(for: [cancellation], timeout: 2)
        XCTAssertEqual(
            ledger.cancellations,
            [
                .init(kind: .lastChats, generation: 1),
                .init(kind: .resident, generation: 1)
            ]
        )

        try realm.write {
            let latest = realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "observer-primary-2"
            )
            latest?.body = "must not escape a deinitialized observation"
            latest?.editDate = Date(timeIntervalSince1970: 9_999)
        }
        wait(for: [unexpectedChange], timeout: 0.2)
        XCTAssertEqual(store.diagnosticsSnapshot.observation.pendingWorkCount, 0)
    }

    @MainActor
    func testRepeatedNativeBackFixtureSeedingDoesNotMutateManagedRealmPrimaryKeys() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-native-seed-\(UUID().uuidString)"
        )
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let previousConnectingUsers = AccountManager.shared.connectingUsers.value
        defer {
            AccountManager.shared.users = previousUsers
            AccountManager.shared.activeUsers.accept(previousActiveUsers)
            AccountManager.shared.authenticatedUsers.accept(
                previousAuthenticatedUsers
            )
            AccountManager.shared.connectingUsers.accept(previousConnectingUsers)
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let destination = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small
        ))
        let first = ChatPerformanceManualNativeBackLastChatsHostViewController(
            destination: destination
        )
        let second = ChatPerformanceManualNativeBackLastChatsHostViewController(
            destination: destination
        )

        withExtendedLifetime([first, second]) {}
        let realm = try WRealm.safe()
        XCTAssertNotNil(realm.object(
            ofType: AccountStorageItem.self,
            forPrimaryKey: destination.owner
        ))
        XCTAssertNotNil(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: destination.jid,
                owner: destination.owner,
                conversationType: destination.conversationType
            )
        ))
    }

    func testOpenScenarioTerminalObserverContainsNoLayoutIfNeededCalls() throws {
        let body = try sourceMethod(
            named: "private func observeOpenScenarioTerminal(",
            in: chatPerformanceFixtureSource()
        )
        XCTAssertFalse(body.contains("layoutIfNeeded()"))
    }

    func testOpenScenarioDiagnosticsContainsNoLayoutIfNeededCalls() throws {
        let body = try sourceMethod(
            named: "private func makeOpenScenarioDiagnostics(",
            in: chatPerformanceFixtureSource()
        )
        XCTAssertFalse(body.contains("layoutIfNeeded()"))
    }

    func testOpenScenarioStorageProofIsCapturedBeforeMeasuredRouteAdmission() throws {
        let source = try chatPerformanceFixtureSource()
        let preparation = try sourceMethod(
            named: "private func prepareOpenScenarioRealm(",
            in: source
        )
        let configuration = try sourceMethod(
            named: "private func configureOpenScenario(",
            in: source
        )

        XCTAssertTrue(preparation.contains(
            "captureOpenScenarioStorageDiagnostics(in: realm)"
        ))
        XCTAssertFalse(configuration.contains(
            "captureOpenScenarioStorageDiagnostics()"
        ))
        let admission = try XCTUnwrap(configuration.range(
            of: "openScenarioRouteMeasurementHasStarted = true"
        ))
        let routeLoad = try XCTUnwrap(configuration.range(
            of: "loadInitialDatasource(performPendingOpenMessageRequest: false)"
        ))
        XCTAssertLessThan(admission.lowerBound, routeLoad.lowerBound)
    }

    func testStableReceiptReportsZeroFixtureRealmQueriesAfterRouteAdmission() throws {
        XCTAssertTrue(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isMeasurementPure(
                fixtureRealmQueryCountAfterRouteAdmission: 0
            )
        )
        XCTAssertFalse(
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isMeasurementPure(
                fixtureRealmQueryCountAfterRouteAdmission: 1
            )
        )
        let source = try chatPerformanceFixtureSource()
        let diagnostics = try sourceMethod(
            named: "private func makeOpenScenarioDiagnostics(",
            in: source
        )
        let normalizedDiagnostics = diagnostics
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(normalizedDiagnostics.contains(
            "fixtureRealmQueryCountAfterRouteAdmission: " +
                "openScenarioFixtureRealmQueryCountAfterRouteAdmission,"
        ))
        XCTAssertTrue(try chatPerformanceIntegrationGateSource().contains(
            "fixtureRealmQueriesAfterAdmission="
        ))
    }

    func testNonContinuesMAMPublishesDeliveredCountNotServerCardinality() throws {
        let source = try messageArchiveManagerSource()
        let branchStart = try XCTUnwrap(source.range(of:
            "} else {\n                    self.completeCallback(item.callback)"
        ))
        let branchEnd = try XCTUnwrap(source.range(
            of: "self.unregisterArchiveQueryId(queryId)",
            range: branchStart.upperBound..<source.endIndex
        ))
        let nonContinuesBranch = String(
            source[branchStart.lowerBound..<branchEnd.lowerBound]
        )
        XCTAssertTrue(nonContinuesBranch.contains(
            "let count = deliveredResultCount"
        ))
        XCTAssertFalse(nonContinuesBranch.contains(
            "let count = resultCount"
        ))
    }

    @MainActor
    func testFixtureTransportThreadRecorderRejectsMainTransportAndOffMainUI() {
        let recorder = ChatOpenRealPipelineFixtureTransportThreadRecorder()
        let generation = recorder.activate()
        XCTAssertTrue(recorder.beginOperation(generation: generation))
        recorder.record(.mamStart, generation: generation, isMainThread: false)
        recorder.record(.archiveEnvelope, generation: generation, isMainThread: false)
        recorder.record(.messageIngress, generation: generation, isMainThread: false)
        recorder.record(.finalParser, generation: generation, isMainThread: false)
        recorder.endOperation(generation: generation)
        recorder.record(.uiBookkeeping, generation: generation, isMainThread: true)
        recorder.record(.uiReceipt, generation: generation, isMainThread: true)

        let accepted = recorder.snapshot
        XCTAssertEqual(accepted.pendingOperationCount, 0)
        XCTAssertEqual(accepted.transportMainThreadViolationCount, 0)
        XCTAssertEqual(accepted.uiOffMainThreadViolationCount, 0)
        XCTAssertEqual(accepted.mamStartCount, 1)
        XCTAssertEqual(accepted.archiveEnvelopeCount, 1)
        XCTAssertEqual(accepted.messageIngressCount, 1)
        XCTAssertEqual(accepted.finalParserCount, 1)
        XCTAssertEqual(accepted.uiBookkeepingCount, 1)
        XCTAssertEqual(accepted.uiReceiptCount, 1)

        recorder.record(.finalParser, generation: generation, isMainThread: true)
        recorder.record(.uiReceipt, generation: generation, isMainThread: false)
        let rejected = recorder.snapshot
        XCTAssertEqual(rejected.transportMainThreadViolationCount, 1)
        XCTAssertEqual(rejected.uiOffMainThreadViolationCount, 1)
    }


    func testVisibleOffsetSamplingUsesOneDisplayLinkAndNoRecursivePolling() throws {
        var gate = ChatOpenRealPipelineFixtureOffsetSamplerGate()
        let generation = gate.beginSampling()
        XCTAssertTrue(gate.consumeDisplayTick(
            generation: generation,
            timestamp: 10
        ))
        XCTAssertFalse(gate.consumeDisplayTick(
            generation: generation,
            timestamp: 10
        ))
        XCTAssertTrue(gate.consumeDisplayTick(
            generation: generation,
            timestamp: 10.016
        ))
        gate.pause()
        XCTAssertFalse(gate.consumeDisplayTick(
            generation: generation,
            timestamp: 10.032
        ))

        let fixture = try chatPerformanceFixtureSource()
        XCTAssertTrue(fixture.contains("CADisplayLink("))
        XCTAssertTrue(fixture.contains("preferredFramesPerSecond = 60"))
        XCTAssertFalse(fixture.contains("deadline: .now() + 0.008"))
        XCTAssertFalse(fixture.contains("deadline: .now() + 0.01"))
        XCTAssertFalse(fixture.contains("sampleOpenScenarioVisibleOffset(generation:"))
        let displayTick = try sourceMethod(
            named: "@objc private func sampleOpenScenarioVisibleOffset(",
            in: fixture
        )
        XCTAssertTrue(displayTick.contains("consumeDisplayTick("))
        XCTAssertFalse(displayTick.contains("layoutIfNeeded"))
        XCTAssertFalse(displayTick.contains("asyncAfter"))
    }


    func testVideoMarkerPublicationGateKeepsOrderedRunsAndPostM3Tail() {
        var gate = ChatOpenVideoMarkerPublicationGate()
        let generation = gate.begin()

        XCTAssertNil(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: 9.98,
                hasStableTerminalEvidence: false,
                terminalEvidenceIsFrozen: true
            )
        )
        XCTAssertEqual(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: 10,
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ),
            .publish(.m1, .verticalBars)
        )
        for tick in 1..<(ChatOpenVideoMarkerPublicationGate
            .m1MinimumDisplayTickCount - 1) {
            XCTAssertNil(gate.consumeDisplayTick(
                generation: generation,
                timestamp: 10 + (Double(tick) * 0.02),
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ))
        }
        let m2Timestamp = 10 +
            ChatOpenVideoMarkerPublicationGate.m1MinimumVisibleDuration
        XCTAssertEqual(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: m2Timestamp,
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ),
            .publish(.m2, .checkerboard)
        )

        for tick in 1..<(ChatOpenVideoMarkerPublicationGate
            .m2MinimumDisplayTickCount - 1) {
            XCTAssertNil(gate.consumeDisplayTick(
                generation: generation,
                timestamp: m2Timestamp + (Double(tick) * 0.02),
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ))
        }
        let m3Timestamp = m2Timestamp +
            ChatOpenVideoMarkerPublicationGate.m2MinimumVisibleDuration
        XCTAssertEqual(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: m3Timestamp,
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ),
            .publish(.m3, .concentricRings)
        )

        for tick in 1...ChatOpenVideoMarkerPublicationGate
            .m3MinimumPostPublicationTickCount {
            let action = gate.consumeDisplayTick(
                generation: generation,
                timestamp: m3Timestamp + (Double(tick) / 60),
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            )
            if tick < ChatOpenVideoMarkerPublicationGate
                .m3MinimumPostPublicationTickCount {
                XCTAssertNil(action)
            } else {
                XCTAssertEqual(action, .complete)
            }
        }
    }

    func testVideoMarkerM1CannotBeSkippedByImmediateStableTerminal() {
        var gate = ChatOpenVideoMarkerPublicationGate()
        let generation = gate.begin()
        XCTAssertEqual(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: 20,
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ),
            .publish(.m1, .verticalBars)
        )

        // The display-tick count is already sufficient at 50 ms, but the
        // multi-second drift-proof duration floor independently keeps M1
        // visible.
        for tick in 1...5 {
            XCTAssertNil(gate.consumeDisplayTick(
                generation: generation,
                timestamp: 20 + (Double(tick) * 0.01),
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ))
        }
        XCTAssertEqual(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: 20 +
                    ChatOpenVideoMarkerPublicationGate
                        .m1MinimumVisibleDuration,
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: true
            ),
            .publish(.m2, .checkerboard)
        )
    }

    func testVideoMarkerPublicationGateFailsClosedWhenTerminalEvidenceMoves() {
        var gate = ChatOpenVideoMarkerPublicationGate()
        let generation = gate.begin()
        _ = gate.consumeDisplayTick(
            generation: generation,
            timestamp: 1,
            hasStableTerminalEvidence: false,
            terminalEvidenceIsFrozen: true
        )
        _ = gate.consumeDisplayTick(
            generation: generation,
            timestamp: 2,
            hasStableTerminalEvidence: true,
            terminalEvidenceIsFrozen: true
        )

        XCTAssertEqual(
            gate.consumeDisplayTick(
                generation: generation,
                timestamp: 2.02,
                hasStableTerminalEvidence: true,
                terminalEvidenceIsFrozen: false
            ),
            .evidenceInvalidated
        )
        XCTAssertNil(gate.consumeDisplayTick(
            generation: generation,
            timestamp: 3,
            hasStableTerminalEvidence: true,
            terminalEvidenceIsFrozen: true
        ))

        let replacementGeneration = gate.begin()
        XCTAssertNotEqual(replacementGeneration, generation)
        XCTAssertNil(gate.consumeDisplayTick(
            generation: generation,
            timestamp: 4,
            hasStableTerminalEvidence: false,
            terminalEvidenceIsFrozen: true
        ))
    }

    func testFixtureVideoMarkersShareDisplayBoundaryAndDelayStableReceipt() throws {
        let fixture = try chatPerformanceFixtureSource()
        XCTAssertTrue(fixture.contains(
            "final class ChatPerformanceVideoMarkerView: UIView"
        ))
        XCTAssertTrue(fixture.contains("case .verticalBars:"))
        XCTAssertTrue(fixture.contains("case .checkerboard:"))
        XCTAssertTrue(fixture.contains("case .concentricRings:"))
        XCTAssertTrue(fixture.contains("for column in stride(from: 0, to: 6"))
        XCTAssertTrue(fixture.contains("for row in 0..<6"))

        let displayTick = try sourceMethod(
            named: "@objc private func sampleOpenScenarioVisibleOffset(",
            in: fixture
        )
        XCTAssertTrue(displayTick.contains(
            "advanceOpenScenarioVideoMarker(on: displayLink)"
        ))
        XCTAssertFalse(displayTick.contains("asyncAfter"))

        let marker = try sourceMethod(
            named: "private func advanceOpenScenarioVideoMarker(",
            in: fixture
        )
        XCTAssertTrue(marker.contains("displayLink.targetTimestamp"))
        XCTAssertTrue(marker.contains("recordMarkerTransition("))
        XCTAssertTrue(marker.contains(
            "completeOpenScenarioStableReceiptAfterVideoTail()"
        ))

        let completion = try sourceMethod(
            named: "private func completeOpenScenarioStableReceiptAfterVideoTail(",
            in: fixture
        )
        XCTAssertTrue(completion.contains(
            "finalEvaluation.evidence == frozenEvidence"
        ))
        XCTAssertTrue(completion.contains(
            "DispatchQueue.global(qos: .utility).async"
        ))
        XCTAssertFalse(completion.contains(
            "openScenarioArchiveTransportQueue.async"
        ))
        XCTAssertTrue(completion.contains("try exportSession.finalize()"))
        XCTAssertFalse(completion.contains("openScenarioDidStabilize?"))

        let publication = try sourceMethod(
            named: "private func finishOpenScenarioArtifactFinalization(",
            in: fixture
        )
        XCTAssertTrue(publication.contains("openScenarioStableReceipt ="))
        XCTAssertTrue(publication.contains("openScenarioDidStabilize?"))
    }

    func testFixtureDefersTerminalTeardownToConfirmedNavigationDisappearance() throws {
        let fixture = try chatPerformanceFixtureSource()
        let willDisappear = try sourceMethod(
            named: "override func viewWillDisappear(",
            in: fixture
        )
        XCTAssertTrue(willDisappear.contains("super.viewWillDisappear(animated)"))
        XCTAssertFalse(willDisappear.contains(
            "performOpenScenarioTerminalResourceTeardown()"
        ))

        let terminal = try sourceMethod(
            named: "override internal func performTerminalChatResourceTeardown()",
            in: fixture
        )
        XCTAssertTrue(terminal.contains(
            "performOpenScenarioOwnedResourceTeardownIfNeeded()"
        ))
        XCTAssertTrue(terminal.contains(
            "super.performTerminalChatResourceTeardown()"
        ))

        let owned = try sourceMethod(
            named: "private func performOpenScenarioOwnedResourceTeardownIfNeeded()",
            in: fixture
        )
        for observer in [
            "performanceOpenMessageRequestAdmissionObserver = nil",
            "visibleMentionReadScheduledForTests = nil",
            "visibleMentionReadAfterFirstPersistentMutationBarrierForTests = nil",
            "visibleMentionReadTerminalForTests = nil"
        ] {
            XCTAssertTrue(
                owned.contains(observer),
                "P14 teardown omitted observer: \(observer)"
            )
        }
        XCTAssertTrue(owned.contains(
            "visibleUnreadMentionReconciliationWorkItem?.cancel()"
        ))
        XCTAssertTrue(owned.contains(
            "readVisibleStableLayoutRetryWorkItem?.cancel()"
        ))
        XCTAssertTrue(owned.contains(
            "readVisiblePresentationCoordinator.invalidatePresentation()"
        ))
    }



    @MainActor
    func testReadVisibleHierarchyAcceptsTerminalUIWindowForHostedTopDestination()
        throws {
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller =
            ChatReadVisibleWindowHierarchyHostedController()
        let navigationController = UINavigationController(
            rootViewController: controller
        )
        window.rootViewController = navigationController
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 2) {
            window.layoutIfNeeded()
            navigationController.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            return window.isKeyWindow &&
                navigationController.topViewController === controller &&
                navigationController.visibleViewController === controller &&
                controller.viewIfLoaded?.window === window
        })

        var terminalAncestor: UIView = controller.view
        while let superview = terminalAncestor.superview {
            terminalAncestor = superview
        }
        XCTAssertTrue(
            terminalAncestor === window,
            "the real hosted chain must terminate at the expected UIWindow"
        )

        let snapshot = controller.readVisiblePresentationSnapshot()
        XCTAssertTrue(snapshot.isApplicationActive)
        XCTAssertTrue(snapshot.isWindowSceneForegroundActive)
        XCTAssertTrue(snapshot.isKeyWindow)
        XCTAssertTrue(snapshot.isTopNavigationDestination)
        XCTAssertFalse(snapshot.isVisibleSplitSecondary)
        XCTAssertFalse(snapshot.hasCoveringPresentation)
        XCTAssertFalse(snapshot.isTransitionActive)
        XCTAssertTrue(
            snapshot.isWindowAttached,
            "the terminal UIWindow is the expected owner, not a mismatched ancestor"
        )
    }

    @MainActor
    func testReadVisibleHierarchyRetainsEveryWindowAncestorAndGeometryRejection()
        throws {
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller =
            ChatReadVisibleWindowHierarchyHostedController()
        let navigationController = UINavigationController(
            rootViewController: controller
        )
        window.rootViewController = navigationController
        let otherWindow = UIWindow(windowScene: scene)
        otherWindow.frame = scene.coordinateSpace.bounds
        otherWindow.isHidden = false
        defer {
            controller.view.transform = .identity
            window.alpha = 1
            window.isHidden = true
            window.rootViewController = nil
            otherWindow.isHidden = true
            otherWindow.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 2) {
            window.layoutIfNeeded()
            navigationController.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            return controller.viewIfLoaded?.window === window
        })
        let detached = ChatReadVisibleWindowHierarchyHostedController()
        detached.loadViewIfNeeded()
        XCTAssertFalse(
            detached.isViewHierarchyMeaningfullyVisibleForTesting(in: window),
            "a detached destination must not borrow another hierarchy receipt"
        )
        XCTAssertFalse(
            controller.isViewHierarchyMeaningfullyVisibleForTesting(
                in: otherWindow
            ),
            "a descendant owned by another window must be rejected"
        )

        window.isHidden = true
        XCTAssertFalse(
            controller.isViewHierarchyMeaningfullyVisibleForTesting(
                in: window
            )
        )
        window.isHidden = false

        window.alpha = 0
        XCTAssertFalse(
            controller.isViewHierarchyMeaningfullyVisibleForTesting(
                in: window
            )
        )
        window.alpha = 1

        let ancestor = try XCTUnwrap(controller.view.superview)
        ancestor.isHidden = true
        XCTAssertFalse(
            controller.isViewHierarchyMeaningfullyVisibleForTesting(
                in: window
            )
        )
        ancestor.isHidden = false

        ancestor.alpha = 0
        XCTAssertFalse(
            controller.isViewHierarchyMeaningfullyVisibleForTesting(
                in: window
            )
        )
        ancestor.alpha = 1

        controller.view.transform = CGAffineTransform(
            translationX: window.bounds.width - 10,
            y: 0
        )
        XCTAssertFalse(
            controller.isViewHierarchyMeaningfullyVisibleForTesting(
                in: window
            ),
            "a ten-point viewport sliver remains below the 44-point extent"
        )
    }

    @MainActor
    private func withStableLocalOpenScenario(
        _ scenario: ChatOpenRealPipelineFixtureScenario,
        verify: (
            ChatPerformanceFixtureViewController,
            ChatOpenRealPipelineFixtureDiagnostics
        ) throws -> Void
    ) throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-terminal-proof-\(scenario.rawValue)-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: scenario
        ))
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            controller.openScenarioDidStabilize = nil
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let stable = expectation(description: "stable production proof \(scenario.rawValue)")
        controller.openScenarioDidStabilize = { _ in stable.fulfill() }
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        wait(for: [stable], timeout: 12)
        try verify(controller, XCTUnwrap(controller.openScenarioStableReceipt))
    }

    @MainActor
    private func waitUntilObserverIdle(
        _ session: ChatTimelineSession,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while session.activeStoreObservationWorkCount > 0, Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return session.activeStoreObservationWorkCount == 0
    }

    @MainActor
    private func waitUntilObserverIdle(
        _ observation: ChatTimelineStoreObservation,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while observation.activeWorkCount > 0, Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return observation.activeWorkCount == 0
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return condition()
    }

    @MainActor
    private func seedObserverConversation(
        realm: Realm,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) throws {
        let messages = (0..<3).map {
            makeObserverMessage(
                ordinal: $0,
                owner: owner,
                jid: jid,
                conversationType: conversationType
            )
        }
        try realm.write {
            messages.forEach { realm.add($0, update: .modified) }
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = conversationType
            chat.messageDate = messages[2].date
            chat.lastMessageId = messages[2].messageId
            chat.lastMessage = messages[2]
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.fullArchiveLoaded = true
            chat.isAllHistoryLoaded = true
            chat.syncSnapshotLastArchiveId = messages[2].archivedId
            realm.add(chat, update: .modified)

            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
            )
            archiveState.olderArchiveEndReached = true
            archiveState.newerLiveEdgeReached = true
            archiveState.lastSnapshotArchiveId = messages[2].archivedId
            archiveState.mergeLoadedRange(
                first: messages[0].archivedId,
                last: messages[2].archivedId,
                updateKind: .bootstrapNewest
            )
            archiveState.updatedAt = Date()
        }
    }

    @MainActor
    private func makeObserverMessage(
        ordinal: Int,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = "observer-primary-\(ordinal)"
        message.owner = owner
        message.opponent = jid
        message.conversationType = conversationType
        message.archivedId = String(2_000_000_000_000_000 + ordinal)
        message.messageId = "observer-message-\(ordinal)"
        message.date = Date(timeIntervalSince1970: TimeInterval(9_000 + ordinal))
        message.sentDate = message.date
        message.body = "observer body \(ordinal)"
        message.outgoing = false
        message.isRead = true
        message.state = .read
        return message
    }

    func testFixtureScalesExposeEveryGoalDatasetSize() {
        XCTAssertEqual(
            ChatPerformanceFixtureScale.allCases.map(\.rowCount),
            [100, 10_000, 100_000, 1_000_000]
        )
    }

    func testMillionRowFixtureStreamsOneRowAtATimeAndCleansUp() throws {
        let store = CountingFixtureStore(isEphemeral: true)

        let run = try ChatPerformanceFixtureGenerator.withFixture(
            scale: .million,
            batchSize: 4_096,
            store: store
        ) { report in
            XCTAssertEqual(store.persistedRowCount, 1_000_000)
            return report.persistedRowCount
        }

        XCTAssertEqual(run.result, 1_000_000)
        XCTAssertEqual(run.generation.maximumGeneratedRowsInMemory, 1)
        XCTAssertEqual(run.generation.batchCount, 245)
        XCTAssertEqual(run.deletedRowCount, 1_000_000)
        XCTAssertEqual(run.remainingRowCountAfterCleanup, 0)
    }

    func testThinFixturePersistsInIsolatedRealmAndCleansUp() throws {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatPerformanceLabTests-\(UUID().uuidString)"
        )
        let realm = try Realm(configuration: configuration)
        let store = RealmFixtureStore(realm: realm)

        let run = try ChatPerformanceFixtureGenerator.withFixture(
            scale: .small,
            batchSize: 32,
            store: store
        ) { report in
            XCTAssertEqual(report.persistedRowCount, 100)
            XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 100)
            return realm.objects(MessageStorageItem.self).last?.primary
        }

        XCTAssertEqual(run.result, "chat-performance-fixture-99")
        XCTAssertEqual(run.deletedRowCount, 100)
        XCTAssertEqual(run.remainingRowCountAfterCleanup, 0)
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 0)
    }

    func testFixtureRefusesNonEphemeralStoreBeforeWriting() {
        let store = CountingFixtureStore(isEphemeral: false)

        XCTAssertThrowsError(try ChatPerformanceFixtureGenerator.withFixture(
            scale: .small,
            batchSize: 16,
            store: store,
            body: { _ in () }
        )) { error in
            XCTAssertEqual(error as? ChatPerformanceFixtureError, .storeIsNotEphemeral)
        }

        XCTAssertEqual(store.persistedRowCount, 0)
        XCTAssertEqual(store.cleanupCallCount, 0)
    }

    func testFixtureCleansPartialRowsWhenPersistenceFails() {
        let store = CountingFixtureStore(isEphemeral: true, failingOrdinal: 7)

        XCTAssertThrowsError(try ChatPerformanceFixtureGenerator.withFixture(
            scale: .small,
            batchSize: 16,
            store: store,
            body: { _ in () }
        ))

        XCTAssertEqual(store.cleanupCallCount, 1)
        XCTAssertEqual(store.persistedRowCount, 0)
    }

    func testRichFixtureCoversEveryRequiredRenderFeature() {
        let rows = ChatPerformanceRichFixture.rows
        let features = rows.reduce(into: ChatPerformanceFixtureFeature()) { partial, row in
            partial.formUnion(row.features)
        }

        XCTAssertTrue(features.isSuperset(of: .allRequired))
        XCTAssertTrue(rows.contains { $0.features.contains(.oneImage) })
        XCTAssertTrue(rows.contains { $0.features.contains(.fiveImages) })
        XCTAssertTrue(rows.contains { !$0.markupRanges.isEmpty })
    }

    func testRichFixtureUTF16RangesStayInsideSyntheticBody() {
        let markedRows = ChatPerformanceRichFixture.rows.filter { !$0.markupRanges.isEmpty }

        XCTAssertFalse(markedRows.isEmpty)
        markedRows.forEach { row in
            let utf16Length = (row.body as NSString).length
            row.markupRanges.forEach { range in
                XCTAssertGreaterThanOrEqual(range.location, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(range), utf16Length)
            }
        }
    }

    private func chatPerformanceFixtureSource() throws -> String {
        try repositorySource(
            "xabber/controllers/chats/chat/ChatPerformanceFixtureViewController.swift"
        )
    }

    private func assertAcceptedP14HostedReceipt(
        _ receipt: ChatOpenRealPipelineFixtureDiagnostics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(receipt.requestSource, .mentionNotification, file: file, line: line)
        XCTAssertFalse(receipt.requestHighlight, file: file, line: line)
        XCTAssertEqual(receipt.requestMarkReadOnVisible, true, file: file, line: line)
        XCTAssertEqual(receipt.resolvedTargetOrdinal, 160, file: file, line: line)
        XCTAssertEqual(receipt.targetMatchCount, 1, file: file, line: line)
        XCTAssertEqual(receipt.latestVisualCommitCount, 0, file: file, line: line)
        XCTAssertEqual(receipt.storeQueryBaselineCount, 0, file: file, line: line)
        XCTAssertEqual(receipt.initialFrameStoreQueryCount, 2, file: file, line: line)
        XCTAssertEqual(receipt.storeQueryCount, 2, file: file, line: line)
        XCTAssertEqual(receipt.storeLifetimeQueryCount, 2, file: file, line: line)
        XCTAssertEqual(receipt.postInitialStoreQueryCount, 0, file: file, line: line)
        XCTAssertEqual(receipt.mainThreadStoreQueryCount, 0, file: file, line: line)
        XCTAssertEqual(
            receipt.terminalRouteStoreOperationSummary,
            ChatOpenRealPipelineFixtureStoreOperationSummary(
                operationCounts: ["messageWindow": 1, "unread": 1]
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.postInitialStoreOperationSummary,
            ChatOpenRealPipelineFixtureStoreOperationSummary(
                operationCounts: [:]
            ),
            file: file,
            line: line
        )

        let host = receipt.routeHost
        XCTAssertTrue(host.rootInstalled, file: file, line: line)
        XCTAssertTrue(host.lastChatsVisibleBeforeRoute, file: file, line: line)
        XCTAssertEqual(host.routeAttemptCount, 1, file: file, line: line)
        XCTAssertEqual(host.nativePushCount, 1, file: file, line: line)
        XCTAssertTrue(host.destinationOpaqueBeforeFirstRow, file: file, line: line)
        XCTAssertEqual(host.lastChatsExposureCount, 0, file: file, line: line)
        XCTAssertEqual(host.coldPendingBeforeRoot, 0, file: file, line: line)
        XCTAssertEqual(host.accountMaterializationCount, 1, file: file, line: line)
        XCTAssertEqual(host.coldConsumeBeforeStableCount, 0, file: file, line: line)
        XCTAssertEqual(host.coldConsumeAfterStableCount, 0, file: file, line: line)
        XCTAssertEqual(host.hostKind, .lastChatsSeededMention, file: file, line: line)
        XCTAssertTrue(host.p14SourceRowVisibleBeforeTap, file: file, line: line)
        XCTAssertEqual(host.p14SourceRowTapCount, 1, file: file, line: line)
        XCTAssertEqual(host.p14PendingRequestCountBeforeTap, 0, file: file, line: line)
        XCTAssertEqual(host.p14RequestAdmissionCountBeforeTap, 0, file: file, line: line)
        XCTAssertEqual(host.p14RequestAdmissionCount, 1, file: file, line: line)
        XCTAssertEqual(host.p14RequestAdmissionBeforeViewLoadCount, 1, file: file, line: line)
        XCTAssertEqual(host.p14GroupConversationProofCount, 1, file: file, line: line)
        XCTAssertEqual(host.p14ExplicitRequestCount, 1, file: file, line: line)
        XCTAssertEqual(host.p14UnreadRequestCount, 0, file: file, line: line)
        XCTAssertEqual(host.p14SavedRequestCount, 0, file: file, line: line)
        XCTAssertEqual(host.p14LatestRequestCount, 0, file: file, line: line)
        XCTAssertTrue(host.isAccepted(for: .lastChatsSeededMentionExact), file: file, line: line)

        let mention = receipt.p14Mention
        XCTAssertEqual(mention.unreadFrameCount, 0, file: file, line: line)
        XCTAssertEqual(mention.savedFrameCount, 0, file: file, line: line)
        XCTAssertEqual(mention.readEagerMutationCount, 0, file: file, line: line)
        XCTAssertEqual(mention.readScheduledCount, 1, file: file, line: line)
        XCTAssertEqual(mention.readCommittedCount, 1, file: file, line: line)
        XCTAssertEqual(mention.readSuccessfulFlushCount, 1, file: file, line: line)
        XCTAssertEqual(mention.readTerminalSuccessCount, 1, file: file, line: line)
        XCTAssertEqual(mention.readTerminalFailureCount, 0, file: file, line: line)
        XCTAssertTrue(mention.unreadBeforeTap, file: file, line: line)
        XCTAssertTrue(mention.unreadAtAdmission, file: file, line: line)
        XCTAssertTrue(mention.unreadAtInitialCommit, file: file, line: line)
        XCTAssertTrue(mention.readAtTerminal, file: file, line: line)
        XCTAssertEqual(mention.freshRealmMatchCount, 1, file: file, line: line)
        XCTAssertEqual(mention.freshRealmProofFailureCount, 0, file: file, line: line)
        XCTAssertEqual(mention.pendingCandidateCount, 0, file: file, line: line)
        XCTAssertEqual(mention.inFlightFlushCount, 0, file: file, line: line)
        XCTAssertFalse(mention.hasReconciliationWorkItem, file: file, line: line)
        XCTAssertFalse(mention.hasStableLayoutRetryWorkItem, file: file, line: line)
        XCTAssertTrue(mention.isAccepted, file: file, line: line)
    }

    private func assertAcceptedP13HostedReceipt(
        _ receipt: ChatOpenRealPipelineFixtureDiagnostics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(receipt.scenario, .mentionDeletedAdvance, file: file, line: line)
        XCTAssertEqual(receipt.requestSource, .mentionNotification, file: file, line: line)
        XCTAssertTrue(receipt.requestHighlight, file: file, line: line)
        XCTAssertEqual(receipt.requestMarkReadOnVisible, true, file: file, line: line)
        XCTAssertEqual(receipt.resolvedTargetOrdinal, 160, file: file, line: line)
        XCTAssertEqual(receipt.targetMatchCount, 1, file: file, line: line)
        XCTAssertEqual(receipt.latestVisualCommitCount, 0, file: file, line: line)

        let host = receipt.routeHost
        XCTAssertTrue(host.rootInstalled, file: file, line: line)
        XCTAssertEqual(host.routeAttemptCount, 1, file: file, line: line)
        XCTAssertEqual(host.nativePushCount, 1, file: file, line: line)
        XCTAssertTrue(host.destinationOpaqueBeforeFirstRow, file: file, line: line)
        XCTAssertEqual(host.lastChatsExposureCount, 0, file: file, line: line)
        XCTAssertEqual(host.accountMaterializationCount, 1, file: file, line: line)
        XCTAssertEqual(host.hostKind, .notificationsDeletedMention, file: file, line: line)
        XCTAssertTrue(host.p13SourceRowVisibleBeforeTap, file: file, line: line)
        XCTAssertEqual(host.p13SourceRowTapCount, 1, file: file, line: line)
        XCTAssertEqual(host.p13AttemptCount, 1, file: file, line: line)
        XCTAssertEqual(host.p13InvalidationCount, 1, file: file, line: line)
        XCTAssertEqual(host.p13AdvanceCount, 1, file: file, line: line)
        XCTAssertEqual(host.p13UnavailableCount, 0, file: file, line: line)
        XCTAssertEqual(host.p13SelectedNextIdentityCount, 1, file: file, line: line)
        XCTAssertEqual(host.p13UnrelatedGroupPreservedCount, 1, file: file, line: line)
        XCTAssertTrue(host.isAccepted(for: .mentionDeletedAdvance), file: file, line: line)
    }

    private func chatPerformanceIntegrationGateSource() throws -> String {
        try repositorySource(
            "xabber/controllers/chats/chat/ChatPerformanceIntegrationGate.swift"
        )
    }

    private func chatSearchBarSource() throws -> String {
        try repositorySource(
            "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        )
    }

    private func chatViewControllerSource() throws -> String {
        try repositorySource(
            "xabber/controllers/chats/chat/ChatViewController.swift"
        )
    }

    private func chatDatasetSource() throws -> String {
        try repositorySource(
            "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
        )
    }

    private func chatHighPrioritySource() throws -> String {
        try repositorySource(
            "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
        )
    }

    private func messageArchiveManagerSource() throws -> String {
        try repositorySource(
            "xabber/xmpp/messages/message_archive/MessageArchiveManager.swift"
        )
    }

    private func chatPerformanceUITestSource() throws -> String {
        try repositorySource(
            "xabberChatPerformanceUITests/ChatPerformanceUITests.swift"
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceMethod(
        named marker: String,
        in source: String
    ) throws -> String {
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(source[markerRange.lowerBound...]
            .firstIndex(of: "{"))
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[markerRange.lowerBound...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        XCTFail("Unterminated source method: \(marker)")
        return ""
    }
}

@MainActor
private final class ChatReadVisibleWindowHierarchyHostedController:
    ChatViewController {
    override func loadView() {
        let root = UIView(frame: .zero)
        root.backgroundColor = .systemBackground
        view = root
    }

    override func viewDidLoad() {}
    override func shouldChangeFrame() {}
    override func viewWillAppear(_ animated: Bool) {}
    override func viewDidAppear(_ animated: Bool) {}
    override func viewWillDisappear(_ animated: Bool) {}
    override func viewDidDisappear(_ animated: Bool) {}
}

private final class ChatMaterializationBarrierStore: ChatTimelineSessionStore {
    private var messages: [MessageStorageItem]
    var forcesSearchResolutionMiss = false
    var forcedSearchResolutionFailure: ChatAnchorTransactionFailure?
    var searchResolutionBarrier: DispatchSemaphore?
    var onSearchResolutionStarted: (() -> Void)?
    private(set) var searchResolutionInvocationCount = 0
    private(set) var mainThreadSearchResolutionInvocationCount = 0
    private(set) var messageLookupInvocationCount = 0
    private(set) var observation: ChatMaterializationBarrierObservation?
    private(set) var diagnosticsSnapshot =
        ChatTimelineStoreDiagnosticsSnapshot.empty

    init(messages: [MessageStorageItem]) {
        self.messages = ChatTimelineOrdering.chronological(messages)
    }

    func replaceMessages(_ messages: [MessageStorageItem]) {
        self.messages = ChatTimelineOrdering.chronological(messages)
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        Array(messages.suffix(max(0, limit)))
    }

    func older(
        before boundary: ChatTimelineBoundary,
        limit: Int
    ) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: {
            $0.primary == boundary.primary
        }) else {
            return []
        }
        return Array(messages.prefix(index).suffix(max(0, limit)))
    }

    func newer(
        after boundary: ChatTimelineBoundary,
        limit: Int
    ) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: {
            $0.primary == boundary.primary
        }) else {
            return []
        }
        let start = messages.index(after: index)
        return Array(messages.suffix(from: start).prefix(max(0, limit)))
    }

    func around(
        anchor: MessageStorageItem,
        before: Int,
        after: Int
    ) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: {
            $0.primary == anchor.primary
        }) else {
            return []
        }
        let lowerBound = max(0, index - max(0, before))
        let upperBound = min(
            messages.count,
            index + max(0, after) + 1
        )
        return Array(messages[lowerBound..<upperBound])
    }

    func message(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        messageLookupInvocationCount += 1
        return messages.first { message in
            primary.map { message.primary == $0 } == true ||
                archivedId.map { message.archivedId == $0 } == true ||
                messageId.map { message.messageId == $0 } == true
        }
    }

    func searchMessageResolution(
        anchor: ChatMessageAnchorRef
    ) -> ChatTimelineSearchMessageResolution {
        searchResolutionInvocationCount += 1
        if Thread.isMainThread {
            mainThreadSearchResolutionInvocationCount += 1
        }
        onSearchResolutionStarted?()
        _ = searchResolutionBarrier?.wait(timeout: .now() + 2)
        if let forcedSearchResolutionFailure {
            return .failed(forcedSearchResolutionFailure)
        }
        guard !forcesSearchResolutionMiss else {
            return .failed(.targetMissing)
        }
        return message(
            primary: anchor.messagePrimary,
            archivedId: anchor.archivedId,
            messageId: anchor.messageId
        ).map(ChatTimelineSearchMessageResolution.found) ??
            .failed(.targetMissing)
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        let byPrimary = Dictionary(
            uniqueKeysWithValues: messages.map { ($0.primary, $0) }
        )
        return primaryKeys.compactMap { byPrimary[$0] }
    }

    func firstIncoming(
        afterArchiveBoundaryId boundaryArchivedId: String
    ) -> MessageStorageItem? {
        guard let boundary = messages.firstIndex(where: {
            $0.archivedId == boundaryArchivedId
        }) else {
            return nil
        }
        return messages
            .suffix(from: messages.index(after: boundary))
            .first { !$0.outgoing }
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata {
        .empty
    }

    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        let observation = ChatMaterializationBarrierObservation(
            residentPrimaryKeys: baseline.residentPrimaryKeys,
            onChange: onChange
        )
        self.observation = observation
        return observation
    }

    func emit(_ change: ChatTimelineStoreChange) {
        observation?.emit(change)
    }
}

private final class ChatMaterializationBarrierObservation:
    ChatTimelineStoreObservation {
    private let onChange: (ChatTimelineStoreChange) -> Void
    private(set) var residentPrimaryKeys: [String]
    private(set) var isInvalidated = false

    init(
        residentPrimaryKeys: [String],
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) {
        self.residentPrimaryKeys = residentPrimaryKeys
        self.onChange = onChange
    }

    func replaceResidentItems(_ items: [MessageStorageItem]) {
        residentPrimaryKeys = items.map(\.primary)
    }

    func invalidate() {
        isInvalidated = true
    }

    func emit(_ change: ChatTimelineStoreChange) {
        guard !isInvalidated else { return }
        onChange(change)
    }
}

private enum ChatTimelineObserverCatchUpMutation: String {
    case append
    case edit
    case physicalDelete
    case tombstone
}

private final class ChatTimelineObservationRegistrationLedger {
    private let lock = NSLock()
    private var storedRegistrations:
        [ChatTimelineStoreObservationRegistrationIdentity] = []
    private var storedCancellations:
        [ChatTimelineStoreObservationRegistrationIdentity] = []

    var registrations: [ChatTimelineStoreObservationRegistrationIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return storedRegistrations
    }

    var cancellations: [ChatTimelineStoreObservationRegistrationIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return storedCancellations
    }

    func recordRegistration(
        _ identity: ChatTimelineStoreObservationRegistrationIdentity
    ) {
        lock.lock()
        storedRegistrations.append(identity)
        lock.unlock()
    }

    func recordCancellation(
        _ identity: ChatTimelineStoreObservationRegistrationIdentity
    ) {
        lock.lock()
        storedCancellations.append(identity)
        lock.unlock()
    }
}

private enum FixtureStoreError: Error {
    case expectedFailure
}

private struct SparseIndexedGroupMentionHistory {
    struct Cost: Equatable {
        let queryCount: Int
        let fullScanCount: Int
        let countQueryCount: Int
        let offsetQueryCount: Int
        let materializedCandidateCount: Int
    }

    struct Result {
        let resolution: [String: String]
        let cost: Cost
    }

    let logicalRowCount: Int
    let indexedCandidates: [ChatUnreadMentionBulkCandidate]

    func execute(_ plan: ChatUnreadMentionBulkQueryPlan) -> Result {
        precondition(logicalRowCount >= indexedCandidates.count)
        let archivedIds = Set(plan.archivedIds)
        let messageIds = Set(plan.messageIds)
        let matches = indexedCandidates
            .filter { candidate in
                candidate.archivedId.map(archivedIds.contains) == true ||
                    candidate.messageId.map(messageIds.contains) == true
            }
            .sorted { $0.primary < $1.primary }
        let bounded = Array(matches.prefix(plan.candidateLimit))
        return Result(
            resolution: ChatUnreadMentionBulkResolutionPolicy.resolve(
                plan: plan,
                candidates: bounded
            ),
            cost: Cost(
                queryCount: 1,
                fullScanCount: 0,
                countQueryCount: 0,
                offsetQueryCount: 0,
                materializedCandidateCount: bounded.count
            )
        )
    }
}

private final class CountingFixtureStore: ChatPerformanceFixturePersisting {
    let isEphemeral: Bool
    private(set) var persistedRowCount = 0
    private(set) var cleanupCallCount = 0
    private let failingOrdinal: Int?

    init(isEphemeral: Bool, failingOrdinal: Int? = nil) {
        self.isEphemeral = isEphemeral
        self.failingOrdinal = failingOrdinal
    }

    func prepare(totalRowCount: Int) throws {}
    func beginBatch(_ range: Range<Int>) throws {}

    func persist(_ row: ChatPerformanceThinFixtureRow) throws {
        if row.ordinal == failingOrdinal {
            throw FixtureStoreError.expectedFailure
        }
        persistedRowCount += 1
    }

    func endBatch() throws {}

    func cleanup() throws -> Int {
        cleanupCallCount += 1
        let deleted = persistedRowCount
        persistedRowCount = 0
        return deleted
    }
}

private final class RealmFixtureStore: ChatPerformanceFixturePersisting {
    let isEphemeral: Bool
    private let realm: Realm
    private let fixtureOwner = "chat-performance-owner"

    var persistedRowCount: Int {
        realm.objects(MessageStorageItem.self)
            .where { $0.owner == fixtureOwner }
            .count
    }

    init(realm: Realm) {
        self.realm = realm
        self.isEphemeral = realm.configuration.inMemoryIdentifier != nil
    }

    func prepare(totalRowCount: Int) throws {}

    func beginBatch(_ range: Range<Int>) throws {
        realm.beginWrite()
    }

    func persist(_ row: ChatPerformanceThinFixtureRow) throws {
        let message = MessageStorageItem()
        message.primary = "chat-performance-fixture-\(row.ordinal)"
        message.owner = fixtureOwner
        message.opponent = "chat-performance-peer"
        message.conversationType = .regular
        message.archivedId = "fixture-archive-\(row.ordinal)"
        message.messageId = "fixture-message-\(row.ordinal)"
        message.date = Date(timeIntervalSince1970: TimeInterval(row.timestampSeconds))
        message.sentDate = message.date
        message.body = "fixture-variant-\(row.bodyVariant)"
        realm.add(message, update: .modified)
    }

    func endBatch() throws {
        try realm.commitWrite()
    }

    func cleanup() throws -> Int {
        if realm.isInWriteTransaction {
            realm.cancelWrite()
        }
        let rows = realm.objects(MessageStorageItem.self)
            .where { $0.owner == fixtureOwner }
        let deleted = rows.count
        try realm.write {
            realm.delete(rows)
        }
        return deleted
    }
}

private enum TerminalEvidenceMutation: CaseIterable, Equatable {
    case datasourceGeneration
    case datasourceApplyCount
    case firstContentApplyCount
    case visualCommitCount
    case stalePreTerminalRealFrameCount
    case mixedSkeletonAndRealFrameCount
    case offsetMutationCount
    case postCommitOffsetMutationCount
    case correctionCount
    case archiveRequestCount
    case gapRequestCount
    case retryVisible
    case skeletonIdentityStable
    case skeletonGeometryStable
    case skeletonDwellMilliseconds
    case postInitialInteractionCount
    case pagingAnchorErrorMilliPoints
    case rotationTransitionCount
    case applicationBackgroundCount
    case applicationForegroundCount
    case productionBootstrapLeaseEventCount
    case productionBootstrapTransportCount
    case fixtureRealmQueryCountAfterRouteAdmission
    case activeProductionWorkCount
    case transportThreadSnapshot
    case routeHost
    case p14Mention
}

private func makeTerminalTransportEvidence()
    -> ChatOpenRealPipelineFixtureTransportThreadSnapshot {
    ChatOpenRealPipelineFixtureTransportThreadSnapshot(
        generation: 23,
        pendingOperationCount: 0,
        mamStartCount: 1,
        archiveEnvelopeCount: 2,
        messageIngressCount: 2,
        finalParserCount: 3,
        uiBookkeepingCount: 4,
        uiReceiptCount: 0,
        transportMainThreadViolationCount: 0,
        uiOffMainThreadViolationCount: 0
    )
}

private func makeTerminalRouteHostEvidence()
    -> ChatPerformanceRouteHostDiagnostics {
    ChatPerformanceRouteHostDiagnostics(
        rootInstalled: true,
        lastChatsVisibleBeforeRoute: true,
        routeAttemptCount: 1,
        nativePushCount: 1,
        destinationOpaqueBeforeFirstRow: true,
        lastChatsExposureCount: 0,
        coldPendingBeforeRoot: 0,
        accountMaterializationCount: 1,
        coldConsumeBeforeStableCount: 0,
        coldConsumeAfterStableCount: 0
    )
}

private func makeTerminalEvidenceSnapshot(
    mutation: TerminalEvidenceMutation? = nil
) -> ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot {
    let transport: ChatOpenRealPipelineFixtureTransportThreadSnapshot
    if mutation == .transportThreadSnapshot {
        transport = ChatOpenRealPipelineFixtureTransportThreadSnapshot(
            generation: 123,
            pendingOperationCount: 0,
            mamStartCount: 1,
            archiveEnvelopeCount: 2,
            messageIngressCount: 2,
            finalParserCount: 3,
            uiBookkeepingCount: 4,
            uiReceiptCount: 0,
            transportMainThreadViolationCount: 0,
            uiOffMainThreadViolationCount: 0
        )
    } else {
        transport = makeTerminalTransportEvidence()
    }
    let routeHost: ChatPerformanceRouteHostDiagnostics
    if mutation == .routeHost {
        routeHost = ChatPerformanceRouteHostDiagnostics(
            rootInstalled: true,
            lastChatsVisibleBeforeRoute: true,
            routeAttemptCount: 1,
            nativePushCount: 1,
            destinationOpaqueBeforeFirstRow: true,
            lastChatsExposureCount: 1,
            coldPendingBeforeRoot: 0,
            accountMaterializationCount: 1,
            coldConsumeBeforeStableCount: 0,
            coldConsumeAfterStableCount: 0
        )
    } else {
        routeHost = makeTerminalRouteHostEvidence()
    }
    let p14Mention: ChatPerformanceP14MentionDiagnostics =
        mutation == .p14Mention
        ? ChatPerformanceP14MentionDiagnostics(
            unreadFrameCount: 1,
            savedFrameCount: 0,
            readEagerMutationCount: 0,
            readScheduledCount: 1,
            readCommittedCount: 1,
            readSuccessfulFlushCount: 1,
            readTerminalSuccessCount: 1,
            readTerminalFailureCount: 0,
            unreadBeforeTap: true,
            unreadAtAdmission: true,
            unreadAtInitialCommit: true,
            readAtTerminal: true,
            freshRealmMatchCount: 1,
            freshRealmProofFailureCount: 0,
            pendingCandidateCount: 0,
            inFlightFlushCount: 0,
            hasReconciliationWorkItem: false,
            hasStableLayoutRetryWorkItem: false
        )
        : .zero
    return ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot(
        datasourceGeneration: mutation == .datasourceGeneration ? 101 : 1,
        datasourceApplyCount: mutation == .datasourceApplyCount ? 102 : 2,
        firstContentApplyCount: mutation == .firstContentApplyCount ? 103 : 3,
        visualCommitCount: mutation == .visualCommitCount ? 104 : 4,
        stalePreTerminalRealFrameCount:
            mutation == .stalePreTerminalRealFrameCount ? 122 : 22,
        mixedSkeletonAndRealFrameCount:
            mutation == .mixedSkeletonAndRealFrameCount ? 123 : 23,
        offsetMutationCount: mutation == .offsetMutationCount ? 105 : 5,
        postCommitOffsetMutationCount:
            mutation == .postCommitOffsetMutationCount ? 106 : 6,
        correctionCount: mutation == .correctionCount ? 107 : 7,
        archiveRequestCount: mutation == .archiveRequestCount ? 108 : 8,
        gapRequestCount: mutation == .gapRequestCount ? 109 : 9,
        retryVisible: mutation == .retryVisible ? false : true,
        skeletonIdentityStable:
            mutation == .skeletonIdentityStable ? false : true,
        skeletonGeometryStable:
            mutation == .skeletonGeometryStable ? false : true,
        skeletonDwellMilliseconds:
            mutation == .skeletonDwellMilliseconds ? 113 : 13,
        postInitialInteractionCount:
            mutation == .postInitialInteractionCount ? 114 : 14,
        pagingAnchorErrorMilliPoints:
            mutation == .pagingAnchorErrorMilliPoints ? 115 : 15,
        rotationTransitionCount:
            mutation == .rotationTransitionCount ? 116 : 16,
        applicationBackgroundCount:
            mutation == .applicationBackgroundCount ? 117 : 17,
        applicationForegroundCount:
            mutation == .applicationForegroundCount ? 118 : 18,
        productionBootstrapLeaseEventCount:
            mutation == .productionBootstrapLeaseEventCount ? 119 : 19,
        productionBootstrapTransportCount:
            mutation == .productionBootstrapTransportCount ? 120 : 20,
        fixtureRealmQueryCountAfterRouteAdmission:
            mutation == .fixtureRealmQueryCountAfterRouteAdmission ? 121 : 21,
        activeProductionWorkCount:
            mutation == .activeProductionWorkCount ? 1 : 0,
        transportThreadSnapshot: transport,
        routeHost: routeHost,
        p14Mention: p14Mention
    )
}
