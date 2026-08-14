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

    func testFreshPresentationAllowsTypedMaterializationDespiteReusedReadinessProof() {
        XCTAssertTrue(
            ChatInitialMaterializationProbeAdmissionPolicy.allows(
                isFreshPresentationLifecycle: true,
                hasCurrentReadinessProof: true
            ),
            "a session proof from the previous controller must not replace this controller's typed first-frame preparation"
        )
        XCTAssertTrue(
            ChatInitialMaterializationProbeAdmissionPolicy.allows(
                isFreshPresentationLifecycle: false,
                hasCurrentReadinessProof: false
            )
        )
        XCTAssertFalse(
            ChatInitialMaterializationProbeAdmissionPolicy.allows(
                isFreshPresentationLifecycle: false,
                hasCurrentReadinessProof: true
            ),
            "an in-flight presentation must not duplicate its bounded preparation"
        )
    }

    func testFreshPresentationQuiescesTransferredObservationUntilInitialCommit() {
        XCTAssertTrue(
            ChatInitialSessionObservationTransferPolicy.shouldQuiesce(
                isFreshPresentationLifecycle: true,
                hasCommittedInitialContent: false
            )
        )
        XCTAssertFalse(
            ChatInitialSessionObservationTransferPolicy.shouldQuiesce(
                isFreshPresentationLifecycle: false,
                hasCommittedInitialContent: false
            )
        )
        XCTAssertFalse(
            ChatInitialSessionObservationTransferPolicy.shouldQuiesce(
                isFreshPresentationLifecycle: true,
                hasCommittedInitialContent: true
            ),
            "a committed controller must retain its active observation"
        )
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

    func testRemoteActionAcknowledgementLatchesUntilProductionArchiveAdmission() throws {
        let source = try chatPerformanceFixtureSource()
        let acknowledgement = try sourceMethod(
            named: "private func acknowledgeOpenScenarioSkeleton(",
            in: source
        )
        XCTAssertTrue(acknowledgement.contains(
            "openScenarioRemoteActionLatch.acknowledge(plan: plan)"
        ))
        XCTAssertFalse(acknowledgement.contains(
            "injectOpenScenarioRemotePage(plan: plan)"
        ))

        let admission = try sourceMethod(
            named: "private func applyOpenScenarioArchiveTransportStart(",
            in: source
        )
        XCTAssertTrue(admission.contains(
            "openScenarioRemoteActionLatch.admit(queryID: queryId)"
        ))
        XCTAssertTrue(admission.contains(
            "performOpenScenarioAcknowledgedRemoteActionIfReady()"
        ))

        let dispatch = try sourceMethod(
            named: "private func performOpenScenarioAcknowledgedRemoteActionIfReady(",
            in: source
        )
        XCTAssertTrue(dispatch.contains(
            "openScenarioArchiveTransportSession != nil"
        ))
        XCTAssertTrue(dispatch.contains(
            "openScenarioArchiveTransportGeneration != nil"
        ))
        XCTAssertTrue(dispatch.contains("openScenarioQueryId.flatMap"))
        XCTAssertTrue(dispatch.contains(
            "openScenarioArchiveDescriptor(for: queryId) == nil ? nil : queryId"
        ))
        XCTAssertTrue(dispatch.contains(
            "openScenarioRemoteActionLatch.takeIfReady("
        ))
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

    func testE10AndE11FixturePathsCannotFallThroughSuccessfulPageDelivery() throws {
        let source = try chatPerformanceFixtureSource()
        let acknowledgement = try sourceMethod(
            named: "private func acknowledgeOpenScenarioSkeleton(",
            in: source
        )
        XCTAssertTrue(acknowledgement.contains(
            "openScenarioRemoteActionLatch.acknowledge(plan: plan)"
        ))
        XCTAssertTrue(acknowledgement.contains(
            "performOpenScenarioAcknowledgedRemoteActionIfReady()"
        ))

        let acknowledgedDispatch = try sourceMethod(
            named: "private func performOpenScenarioAcknowledgedRemoteActionIfReady(",
            in: source
        )
        XCTAssertTrue(acknowledgedDispatch.contains(".holdActiveDwellThenCancel"))
        XCTAssertTrue(acknowledgedDispatch.contains(".injectTypedTerminalFailure"))
        XCTAssertTrue(acknowledgedDispatch.contains("beginOpenScenarioActiveDwell"))
        XCTAssertTrue(acknowledgedDispatch.contains("injectOpenScenarioTypedFailure"))
        XCTAssertTrue(acknowledgedDispatch.contains(
            "openScenarioArchiveDescriptor(for: queryId) == nil ? nil : queryId"
        ))

        let dwell = try sourceMethod(
            named: "private func finishOpenScenarioActiveDwellIfReady(",
            in: source
        )
        XCTAssertTrue(dwell.contains("minimumActiveDwellNanoseconds"))
        XCTAssertTrue(dwell.contains("discardConfirmedAttempt"))
        XCTAssertTrue(dwell.contains("resetInitialBootstrapTracking"))
        XCTAssertFalse(dwell.contains("deliverOpenScenarioArchivePage"))
        XCTAssertTrue(try chatHighPrioritySource().contains(
            "performanceFixtureArchiveTransportCancellationHandler"
        ))

        let failure = try sourceMethod(
            named: "private func injectOpenScenarioTypedFailure(",
            in: source
        )
        XCTAssertTrue(failure.contains("makeOpenScenarioArchiveFailureIQ"))
        XCTAssertTrue(failure.contains("archiveManager.read"))
        XCTAssertFalse(failure.contains("deliverOpenScenarioArchivePage"))
    }

    func testTrustedEmptyFixtureUsesAuthoritativeCompleteZeroResultFinal() throws {
        let source = try chatPerformanceFixtureSource()
        let injection = try sourceMethod(
            named: "private func injectOpenScenarioRemotePage(",
            in: source
        )
        XCTAssertTrue(injection.contains("plan.successfulArchiveFinalIsComplete"))
        XCTAssertTrue(injection.contains(
            "plan.successfulArchiveServerResultCount"
        ))
        XCTAssertTrue(injection.contains(
            "serverResultCount: serverResultCount"
        ))
        XCTAssertFalse(injection.contains(
            "serverResultCount: ordinalValues.count"
        ))
        XCTAssertFalse(injection.contains(
            "plan.scenario == .bootstrapEmptyToContent"
        ))
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
        XCTAssertFalse(commit.contains(
            "cancelPendingWidthTransitionLayoutRemap()"
        ))
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

    func testE04TailCardinalityProvesNewestEdgeWithoutClaimingOlderArchiveEnd() throws {
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .bootstrapStaleLocalToContent
        )
        let deliveredCount = try XCTUnwrap(
            plan.remoteInjectionOrdinalRange
        ).count
        let disposition = MessageArchiveManager.archivePageFinalDisposition(
            deliveredResultCount: deliveredCount,
            serverResultCount: plan.successfulArchiveServerResultCount,
            complete: plan.successfulArchiveFinalIsComplete,
            requestedPageCursor: nil,
            responseLastCursor: "archive-319"
        )

        XCTAssertEqual(disposition.deliveredResultCount, 80)
        XCTAssertEqual(disposition.serverResultCount, 320)
        XCTAssertFalse(disposition.queryExhausted)
        XCTAssertTrue(
            MessageArchiveManager.bootstrapPageReachesNewestLiveEdge(
                coverageUpdateKind: .bootstrapNewest,
                queryExhausted: disposition.queryExhausted
            ),
            "A newest bootstrap page proves the live edge without exhausting older history"
        )

        let manager = try messageArchiveManagerSource()
        let pageEndState = try sourceMethod(
            named: "private func makePageEndState(",
            in: manager
        )
        XCTAssertTrue(pageEndState.contains(
            "archiveEnded:\n                queryExhausted &&"
        ))
        let coverageCommit = try sourceMethod(
            named: "private func applyConversationArchivePageResult(",
            in: manager
        )
        XCTAssertTrue(coverageCommit.contains("if state.archiveEnded"))
        XCTAssertTrue(coverageCommit.contains(
            "archiveState.olderArchiveEndReached = true"
        ))
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

    @MainActor
    func testP13DeletedMentionFixtureClearsTappedNotificationAndRoutesOnlyToNextExactMention()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p13-route-\(UUID().uuidString)"
        )
        defer {
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .mentionDeletedAdvance
        )
        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: plan.scenario
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
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
        let notificationsNavigationController = try XCTUnwrap(
            tabController.viewControllers?[2] as? UINavigationController
        )
        let notificationsHost = try XCTUnwrap(
            notificationsNavigationController.viewControllers.first as?
                ChatPerformanceMentionNotificationsRouteHostViewController
        )
        defer {
            chatsNavigationController.delegate = nil
            destination.performOpenScenarioTerminalResourceTeardown()
            window.isHidden = true
            window.rootViewController = nil
        }

        XCTAssertTrue(
            (notificationsHost.leftMenuDelegate as AnyObject?) ===
                (coordinator as AnyObject),
            "P13 must retain the weak scene coordinator installed by makeTabRoot"
        )
        XCTAssertEqual(tabController.selectedIndex, 2)
        XCTAssertNil(destination.pendingOpenMessageRequest)
        XCTAssertNil(lastChatsHost.chatNavigationSingleFlight.state)
        XCTAssertFalse(destination.isViewLoaded)
        XCTAssertNotNil(AccountManager.shared.find(for: destination.owner))
        XCTAssertFalse(
            destination
                .isP13DeletedMentionTapBoundaryPreparedForTesting,
            "Hidden-root account startup must reconcile the still-valid mention before deletion"
        )

        let realm = try WRealm.safe()
        let groupMessages = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            destination.owner,
            destination.jid,
            ClientSynchronizationManager.ConversationType.group.rawValue
        )
        XCTAssertEqual(groupMessages.count, 320)
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: destination.openScenarioPrimary(
                plan.p13DeletedMentionOrdinal
            )
        )).isDeleted)
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: destination.openScenarioPrimary(
                plan.p13NextValidMentionOrdinal
            )
        )).isDeleted)
        let staleNotification = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey:
                destination.p13DeletedMentionNotificationPrimaryForTesting
        ))
        let nextNotification = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey:
                destination.p13NextMentionNotificationPrimaryForTesting
        ))
        let unrelatedNotification = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey:
                destination.p13UnrelatedMentionNotificationPrimaryForTesting
        ))
        XCTAssertEqual(staleNotification.mentionLinkStatus, .resolved)
        XCTAssertFalse(staleNotification.isRead)
        XCTAssertTrue(staleNotification.shouldShow)
        XCTAssertEqual(nextNotification.mentionLinkStatus, .resolved)
        XCTAssertFalse(nextNotification.isRead)
        XCTAssertTrue(nextNotification.shouldShow)
        XCTAssertEqual(unrelatedNotification.mentionLinkStatus, .resolved)
        XCTAssertFalse(unrelatedNotification.isRead)
        XCTAssertTrue(unrelatedNotification.shouldShow)

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            notificationsHost.performanceP13SourceRowVisibleForTesting
        })
        realm.refresh()
        XCTAssertTrue(
            destination
                .isP13DeletedMentionTapBoundaryPreparedForTesting,
            "The visible production row must arm the deleted target before inherited didSelect"
        )
        XCTAssertTrue(try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: destination.openScenarioPrimary(
                plan.p13DeletedMentionOrdinal
            )
        )).isDeleted)
        XCTAssertEqual(staleNotification.mentionLinkStatus, .resolved)
        XCTAssertFalse(staleNotification.isRead)
        XCTAssertTrue(staleNotification.shouldShow)
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: destination.openScenarioPrimary(
                plan.p13NextValidMentionOrdinal
            )
        )).isDeleted)
        XCTAssertTrue(
            notificationsHost.performanceP13DatasourceWasProductionAppliedForTesting
        )
        let preTapRoute =
            lastChatsHost.performanceRouteHostDiagnosticsSnapshot
        XCTAssertEqual(preTapRoute.routeAttemptCount, 0)
        XCTAssertEqual(preTapRoute.nativePushCount, 0)
        XCTAssertTrue(notificationsHost.performP13SourceRowTapForTesting())
        XCTAssertTrue(waitUntil(timeout: 14) {
            let route =
                lastChatsHost.performanceRouteHostDiagnosticsSnapshot
            return route.routeAttemptCount == 1 &&
                route.nativePushCount == 1 &&
                destination.openScenarioStableReceipt?.isStable == true
        })

        let receipt = try XCTUnwrap(destination.openScenarioStableReceipt)
        XCTAssertNil(
            destination.pendingOpenMessageRequest,
            "P13 route evidence must survive consumption of transient pending state"
        )
        XCTAssertEqual(receipt.scenario, .mentionDeletedAdvance)
        XCTAssertEqual(receipt.requestSource, .mentionNotification)
        XCTAssertTrue(receipt.requestHighlight)
        XCTAssertEqual(receipt.requestMarkReadOnVisible, true)
        XCTAssertEqual(receipt.resolvedTargetOrdinal, 160)
        XCTAssertEqual(receipt.targetMatchCount, 1)
        XCTAssertEqual(receipt.latestVisualCommitCount, 0)
        XCTAssertEqual(receipt.initialSkeletonRowCount, 0)
        XCTAssertEqual(receipt.currentSkeletonRowCount, 0)
        XCTAssertEqual(receipt.previousOrBlankRealFrameCount, 0)
        XCTAssertEqual(receipt.correctionCount, 0)
        XCTAssertEqual(receipt.postCommitOffsetMutationCount, 0)
        XCTAssertEqual(plan.artifactTraceContract, .initialLocalContent)
        XCTAssertTrue(receipt.routeHost.isAccepted(for: .mentionDeletedAdvance))
        XCTAssertEqual(receipt.routeHost.hostKind, .notificationsDeletedMention)
        XCTAssertTrue(receipt.routeHost.p13SourceRowVisibleBeforeTap)
        XCTAssertEqual(receipt.routeHost.p13SourceRowTapCount, 1)
        XCTAssertEqual(receipt.routeHost.p13AttemptCount, 1)
        XCTAssertEqual(receipt.routeHost.p13InvalidationCount, 1)
        XCTAssertEqual(receipt.routeHost.p13AdvanceCount, 1)
        XCTAssertEqual(receipt.routeHost.p13UnavailableCount, 0)
        XCTAssertEqual(receipt.routeHost.p13SelectedNextIdentityCount, 1)
        XCTAssertEqual(receipt.routeHost.p13UnrelatedGroupPreservedCount, 1)
        XCTAssertEqual(receipt.routeHost.routeAttemptCount, 1)
        XCTAssertEqual(receipt.routeHost.nativePushCount, 1)
        XCTAssertEqual(tabController.selectedIndex, 0)

        XCTAssertEqual(staleNotification.mentionLinkStatus, .missing)
        XCTAssertTrue(staleNotification.isRead)
        XCTAssertFalse(staleNotification.shouldShow)
        XCTAssertEqual(unrelatedNotification.mentionLinkStatus, .resolved)
        XCTAssertFalse(unrelatedNotification.isRead)
        XCTAssertTrue(unrelatedNotification.shouldShow)

        destination.performOpenScenarioTerminalResourceTeardown()
        XCTAssertNil(
            destination.performanceOpenMessageRequestAdmissionObserver,
            "P13 host admission observation must not survive fixture teardown"
        )
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
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
    func testP13LateMatchingAttemptRevokesPublishedStableReceiptAndLiveAccessibility()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p13-late-attempt-\(UUID().uuidString)"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
        let lateAttempt = NotificationsMentionOpenAttemptDiagnostics(
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
        var publications: [ChatOpenRealPipelineFixtureDiagnostics] = []
        destination.openScenarioDidStabilize = {
            publications.append($0)
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            notificationsHost.performanceP13SourceRowVisibleForTesting
        })
        XCTAssertTrue(notificationsHost.performP13SourceRowTapForTesting())
        XCTAssertTrue(waitUntil(timeout: 14) {
            destination.openScenarioStableReceipt?.isStable == true
        })
        let acceptedReceipt = try XCTUnwrap(
            destination.openScenarioStableReceipt
        )
        XCTAssertTrue(
            acceptedReceipt.routeHost.isAccepted(
                for: .mentionDeletedAdvance
            )
        )
        XCTAssertEqual(acceptedReceipt.routeHost.p13AttemptCount, 1)
        XCTAssertEqual(acceptedReceipt.routeHost.routeAttemptCount, 1)
        XCTAssertEqual(publications.count, 1)
        XCTAssertTrue(
            destination.isOpenScenarioPublishedEvidenceAcceptedForTesting
        )

        let liveObserver = try XCTUnwrap(
            notificationsHost.mentionOpenAttemptObserverForTests
        )
        liveObserver(lateAttempt)

        XCTAssertTrue(waitUntil(timeout: 2) {
            destination.openScenarioStableReceipt?.isStable == false &&
                destination.openScenarioStableReceipt?
                    .routeHost.p13AttemptCount == 2
        })
        let revokedReceipt = try XCTUnwrap(
            destination.openScenarioStableReceipt
        )
        XCTAssertEqual(revokedReceipt.phase, .failed)
        XCTAssertFalse(revokedReceipt.isStable)
        XCTAssertEqual(revokedReceipt.routeHost.p13AttemptCount, 2)
        XCTAssertEqual(
            revokedReceipt.routeHost.routeAttemptCount,
            1,
            "A late duplicate source callback must not fabricate a second native route admission"
        )
        XCTAssertFalse(
            revokedReceipt.routeHost.isAccepted(
                for: .mentionDeletedAdvance
            )
        )
        XCTAssertEqual(publications.count, 2)
        XCTAssertFalse(
            destination.isOpenScenarioPublishedEvidenceAcceptedForTesting
        )
        let liveSummary = try XCTUnwrap(
            destination.openScenarioStableAccessibilitySummaryForTesting
        )
        XCTAssertTrue(liveSummary.contains("stable=false"))
        XCTAssertTrue(liveSummary.contains("phase=failed"))
        XCTAssertTrue(liveSummary.contains("hostP13Attempts=2"))
        XCTAssertFalse(liveSummary.contains("stable=true"))
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
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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

    func testP14RouteHostSourceRequiresRealRowTapAndReadVisibleCompletion()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatPerformanceRouteHost.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".lastChatsSeededMentionExact"))
        XCTAssertTrue(source.contains("performanceChatRowSelectionObserver"))
        XCTAssertTrue(source.contains("performP14SourceRowTapForTesting"))
        XCTAssertTrue(source.contains("p14SourceRowVisibleBeforeTap"))
        XCTAssertTrue(source.contains("[weak self, weak destination] item in"))
        XCTAssertTrue(source.contains("self.p14SourceRowVisibleBeforeTap,"))
        XCTAssertTrue(source.contains(
            "tableView.cellForRow(at: indexPath)?.accessibilityIdentifier ="
        ))
        let lastChatsDatasource = try repositorySource(
            "xabber/controllers/chats/last_chats_list/" +
                "LastChatsViewController+UITableViewDatasource.swift"
        )
        XCTAssertTrue(lastChatsDatasource.contains(
            "cell.accessibilityIdentifier =\n" +
                "            performanceChatRowAccessibilityIdentifierProvider?(item)"
        ))
        XCTAssertTrue(source.contains("p14PendingRequestCountBeforeTap"))
        XCTAssertTrue(source.contains("p14RequestAdmissionCountBeforeTap"))
        XCTAssertTrue(source.contains("p14RequestAdmissionBeforeViewLoadCount"))
        XCTAssertTrue(source.contains(
            "performanceP14SourceReadinessBlockerForTesting"
        ))
        XCTAssertNil(source.range(
            of: #"destination\.pendingOpenMessageRequest\s*=(?!=)"#,
            options: .regularExpression
        ))
        let materialization = try sourceMethod(
            named: "private func materializeFixtureAccountIfNeeded()",
            in: source
        )
        let addOffset = try XCTUnwrap(materialization.range(
            of: "AccountManager.shared.add("
        )?.lowerBound)
        let connectedOffset = try XCTUnwrap(materialization.range(
            of: "AccountManager.shared.markAsConnected(jid: destination.owner)"
        )?.lowerBound)
        XCTAssertLessThan(addOffset, connectedOffset)
        let tapMethod = try sourceMethod(
            named: "internal func performP14SourceRowTapForTesting()",
            in: source
        )
        XCTAssertTrue(tapMethod.contains(
            "tableView(tableView, didSelectRowAt: indexPath)"
        ))
        XCTAssertFalse(tapMethod.contains("stackNewChat"))
        XCTAssertFalse(tapMethod.contains("queueOpenMessageRequest"))
        XCTAssertFalse(tapMethod.contains("pendingOpenMessageRequest ="))

        let delegateSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDelegate.swift"
            ),
            encoding: .utf8
        )
        let selection = try sourceMethod(
            named: "func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)",
            in: delegateSource
        )
        let observerOffset = try XCTUnwrap(selection.range(
            of: "performanceChatRowSelectionObserver?"
        )?.lowerBound)
        let routeOffset = try XCTUnwrap(selection.range(
            of: "self.stackNewChat("
        )?.lowerBound)
        XCTAssertLessThan(observerOffset, routeOffset)

        let fixtureSource = try repositorySource(
            "xabber/controllers/chats/chat/" +
                "ChatPerformanceFixtureViewController.swift"
        )
        let p14Receipt = try sourceMethod(
            named: "private func issueP14ProductionPresentationReceiptIfReady()",
            in: fixtureSource
        )
        let controllerSource = try repositorySource(
            "xabber/controllers/chats/chat/ChatViewController.swift"
        )
        let productionAppearance = try sourceMethod(
            named: "override func viewDidAppear(_ animated: Bool)",
            in: controllerSource
        )
        let receiptRecord = "recordReadVisiblePresentationReceiptHandoff()"
        let retryEnqueue = "enqueuePendingReadStateRetry("
        XCTAssertTrue(p14Receipt.contains(receiptRecord))
        XCTAssertTrue(p14Receipt.contains(retryEnqueue))
        XCTAssertTrue(productionAppearance.contains(receiptRecord))
        XCTAssertTrue(productionAppearance.contains(retryEnqueue))
        XCTAssertFalse(p14Receipt.contains(
            "visibleUnreadMentionReconciliationWorkItem == nil"
        ))
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
        let finishAppearanceOffset = try XCTUnwrap(appearance.range(
            of: "finishInitialHistoryAppearanceIfPossible()"
        )?.lowerBound)
        let latestStabilizationOffset = try XCTUnwrap(appearance.range(
            of: "completeInitialLatestOpenStabilizationIfPossible()"
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
        XCTAssertLessThan(transitionFallbackOffset, finishAppearanceOffset)
        XCTAssertLessThan(finishAppearanceOffset, latestStabilizationOffset)
        XCTAssertLessThan(latestStabilizationOffset, pendingRequestOffset)
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

    @MainActor
    func testUnreadBoundaryLocalFixtureSeedsOutgoingRowsBeforeFirstIncomingAndSelectsServerProvenance() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ChatPerformanceLabTests-unread-local-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .unreadBoundaryLocal
        ))
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: controller.conversationType
            )
        ))
        let boundary = try XCTUnwrap(chat.syncUnreadAfterId)
        let boundaryValue = try XCTUnwrap(Int64(boundary))
        XCTAssertGreaterThan(chat.syncUnreadCount, 0)
        XCTAssertGreaterThan(chat.unread, 0)
        XCTAssertGreaterThan(boundaryValue, 0)

        let messagesAfterBoundary = realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                controller.owner,
                controller.jid,
                controller.conversationType.rawValue
            )
            .sorted(byKeyPath: "date", ascending: true)
            .filter { (Int64($0.archivedId) ?? .min) > boundaryValue }
        XCTAssertGreaterThanOrEqual(messagesAfterBoundary.count, 3)
        XCTAssertTrue(messagesAfterBoundary[0].outgoing)
        XCTAssertTrue(messagesAfterBoundary[1].outgoing)
        let firstIncoming = try XCTUnwrap(messagesAfterBoundary.first(where: { !$0.outgoing }))
        XCTAssertEqual(firstIncoming.primary, messagesAfterBoundary[2].primary)
        let persistedUnreadIncomingCount = messagesAfterBoundary.filter {
            !$0.outgoing && !$0.isRead
        }.count
        XCTAssertEqual(chat.syncUnreadCount, persistedUnreadIncomingCount)
        XCTAssertEqual(chat.unread, persistedUnreadIncomingCount)
        let productionStore = RealmChatTimelineSessionStore(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let productionWindow = try XCTUnwrap(
            productionStore.firstIncomingWindow(
                afterArchiveBoundaryId: boundary,
                before: 40,
                after: 39
            )
        )
        XCTAssertEqual(
            productionWindow.target.primary,
            firstIncoming.primary
        )
        XCTAssertTrue(productionWindow.items.contains { $0.primary == firstIncoming.primary })
        XCTAssertLessThanOrEqual(productionWindow.items.count, 80)
        _ = productionStore.unreadMetadata(limit: 80)
        let productionDiagnostics = productionStore.diagnosticsSnapshot
        XCTAssertEqual(productionDiagnostics.queryCount, 2)
        XCTAssertEqual(
            Set(productionDiagnostics.operationCandidateCounts.keys),
            Set(["firstIncomingWindow", "unread"])
        )
        XCTAssertEqual(productionDiagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(productionDiagnostics.maxCandidateCount, 80)
        let boundaryMessage = try XCTUnwrap(
            realm.objects(MessageStorageItem.self)
                .filter("archivedId == %@", boundary)
                .first
        )
        XCTAssertEqual(
            try XCTUnwrap(ChatInitialPositionPolicy.archiveDate(from: boundary))
                .timeIntervalSince1970,
            boundaryMessage.date.timeIntervalSince1970,
            accuracy: 0.001
        )

        let request = try XCTUnwrap(controller.pendingOpenMessageRequest)
        XCTAssertEqual(request.source, .initialUnreadBoundary)
        XCTAssertFalse(request.highlight)
        XCTAssertFalse(request.markReadOnVisible)
        guard case .firstIncomingAfterBoundary(let selectedBoundary) = request.targetResolution else {
            return XCTFail("Unread fixture must select first-incoming-after-boundary")
        }
        XCTAssertEqual(selectedBoundary, boundary)
    }

    func testGroupInitialFrameBulkResolvesManyUnreadMentionsWithinTwoRouteTotalOperations() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ChatPerformanceLabTests-group-many-mentions-\(UUID().uuidString)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "group-route-owner@example.test"
        let jid = "group-route@example.test"
        let conversationKey = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .group
        )
        let realm = try WRealm.safe()
        let messageCount = 160
        let archiveId: (Int) -> String = { String(1_800_000_000_000_000 + $0) }
        try realm.write {
            for index in 0..<messageCount {
                let message = MessageStorageItem()
                message.primary = "group-route-primary-\(index)"
                message.owner = owner
                message.opponent = jid
                message.conversationType = .group
                message.archivedId = archiveId(index)
                message.messageId = "group-route-message-\(index)"
                message.date = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index))
                message.sentDate = message.date
                message.body = "group-route-body-\(index)"
                message.outgoing = false
                message.refreshHistoryPositionComponents()
                realm.add(message, update: .modified)
            }

            func addAmbiguousCandidate(
                primary: String,
                archivedId: String,
                messageId: String,
                dateOffset: Int
            ) {
                let message = MessageStorageItem()
                message.primary = primary
                message.owner = owner
                message.opponent = jid
                message.conversationType = .group
                message.archivedId = archivedId
                message.messageId = messageId
                message.date = Date(
                    timeIntervalSince1970: TimeInterval(1_800_000_500 + dateOffset)
                )
                message.sentDate = message.date
                message.body = primary
                message.outgoing = false
                message.refreshHistoryPositionComponents()
                realm.add(message, update: .modified)
            }
            addAmbiguousCandidate(
                primary: "group-route-ambiguous-archived-b",
                archivedId: archiveId(500),
                messageId: "group-route-ambiguous-archived-message-b",
                dateOffset: 0
            )
            addAmbiguousCandidate(
                primary: "group-route-ambiguous-archived-a",
                archivedId: archiveId(500),
                messageId: "group-route-ambiguous-archived-message-a",
                dateOffset: 1
            )
            addAmbiguousCandidate(
                primary: "group-route-ambiguous-message-b",
                archivedId: archiveId(501),
                messageId: "group-route-ambiguous-message-id",
                dateOffset: 2
            )
            addAmbiguousCandidate(
                primary: "group-route-ambiguous-message-a",
                archivedId: archiveId(502),
                messageId: "group-route-ambiguous-message-id",
                dateOffset: 3
            )

            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .group
            )
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = .group
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.syncSnapshotLastArchiveId = archiveId(messageCount - 1)
            chat.unread = 49
            realm.add(chat, update: .modified)

            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .group,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = archiveId(messageCount - 1)
            archiveState.newerLiveEdgeReached = true
            archiveState.mergeLoadedRange(
                first: archiveId(0),
                last: archiveId(messageCount - 1),
                updateKind: .bootstrapNewest
            )

            func addMention(
                uniqueId: String,
                archivedId: String?,
                messageId: String?,
                authorId: String = "other-member",
                targetMemberId: String = "current-member",
                linkStatus: NotificationStorageItem.MentionLinkStatus = .resolved,
                dateOffset: Int
            ) {
                let notification = NotificationStorageItem()
                notification.primary = NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: jid,
                    uniqueId: uniqueId
                )
                notification.owner = owner
                notification.jid = jid
                notification.uniqueId = uniqueId
                notification.messageId = uniqueId
                notification.category = .mention
                notification.isRead = false
                notification.shouldShow = true
                notification.associatedJid = jid
                notification.sourceConversationType = .group
                notification.sourceChatJid = jid
                notification.sourceArchivedId = archivedId
                notification.sourceMessageId = messageId
                notification.sourceSenderId = authorId
                notification.mentionTargetUserId = targetMemberId
                notification.mentionLinkStatus = linkStatus
                notification.date = Date(
                    timeIntervalSince1970: TimeInterval(1_800_001_000 + dateOffset)
                )
                notification.sourceMessageDate = notification.date
                realm.add(notification, update: .modified)
            }

            for index in 0..<40 {
                addMention(
                    uniqueId: "valid-\(index)",
                    archivedId: index.isMultiple(of: 2) ? archiveId(index) : nil,
                    messageId: "group-route-message-\(index)",
                    dateOffset: index
                )
            }
            for index in 0..<5 {
                addMention(
                    uniqueId: "duplicate-\(index)",
                    archivedId: archiveId(0),
                    messageId: "group-route-message-0",
                    dateOffset: 40 + index
                )
            }
            addMention(
                uniqueId: "archived-precedence",
                archivedId: archiveId(1),
                messageId: "group-route-message-2",
                dateOffset: 45
            )
            addMention(
                uniqueId: "missing",
                archivedId: archiveId(9_999),
                messageId: "missing-message",
                dateOffset: 46
            )
            addMention(
                uniqueId: "invalidated",
                archivedId: archiveId(3),
                messageId: "group-route-message-3",
                linkStatus: .invalidated,
                dateOffset: 47
            )
            addMention(
                uniqueId: "self-authored",
                archivedId: archiveId(4),
                messageId: "group-route-message-4",
                authorId: "current-member",
                targetMemberId: "current-member",
                dateOffset: 48
            )
            addMention(
                uniqueId: "ambiguous-archived-id",
                archivedId: archiveId(500),
                messageId: nil,
                dateOffset: 49
            )
            addMention(
                uniqueId: "ambiguous-message-id",
                archivedId: nil,
                messageId: "group-route-ambiguous-message-id",
                dateOffset: 50
            )
        }

        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .group
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: 250,
            conversationKey: conversationKey,
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "group-route-archive-state",
                persistedCursorId: archiveId(0),
                fullArchiveLoaded: true,
                newestCursorId: archiveId(messageCount - 1),
                newerLiveEdgeReached: true
            )
        )
        let prepared = expectation(description: "group first frame prepared off main")
        var preparationResult: ChatTimelineInitialFramePreparationResult?
        XCTAssertEqual(
            session.prepareInitialFrame(
                target: .latest,
                limit: 80,
                expectedGeneration: session.snapshot.generation
            ) {
                preparationResult = $0
                prepared.fulfill()
            },
            .started
        )
        wait(for: [prepared], timeout: 2)
        guard case .prepared(let frame) = preparationResult else {
            return XCTFail("Expected a finalized group initial frame")
        }

        let mentions = frame.unreadMetadata.mentions
        XCTAssertEqual(frame.snapshot.items.count, 80)
        XCTAssertEqual(mentions.count, 44)
        XCTAssertEqual(mentions.filter { $0.messagePrimary != nil }.count, 43)
        XCTAssertEqual(
            mentions.first(where: { $0.archivedId == archiveId(1) })?.messagePrimary,
            "group-route-primary-1",
            "archived id must retain precedence over a conflicting message id"
        )
        XCTAssertNil(
            mentions.first(where: { $0.archivedId == archiveId(9_999) })?.messagePrimary
        )
        XCTAssertEqual(
            mentions.first(where: { $0.archivedId == archiveId(500) })?.messagePrimary,
            "group-route-ambiguous-archived-a",
            "duplicate archived identifiers must choose the stable lowest primary"
        )
        XCTAssertEqual(
            mentions.first(where: {
                $0.messageId == "group-route-ambiguous-message-id"
            })?.messagePrimary,
            "group-route-ambiguous-message-a",
            "duplicate message identifiers must choose the stable lowest primary"
        )
        XCTAssertFalse(mentions.contains { $0.authorId == "current-member" })

        let diagnostics = store.diagnosticsSnapshot
        XCTAssertEqual(diagnostics.queryCount, 2)
        XCTAssertEqual(diagnostics.mainThreadQueryCount, 0)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 80)
        XCTAssertEqual(
            Set(diagnostics.operationCandidateCounts.keys),
            Set(["latestWindow", "unread"])
        )
        XCTAssertNil(diagnostics.operationCandidateCounts["message"])
        XCTAssertEqual(frame.metrics.storeQueryCount, 2)
        XCTAssertEqual(frame.metrics.mainThreadStoreQueryCount, 0)
        XCTAssertEqual(
            frame.unreadMetadata.initialFrameReadinessProof?
                .materializedLocalMessageCount,
            80
        )
    }

    func testRealmCompoundPostBootstrapLeaseFreezesOnlyPreviouslyCommittedPageObjects() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-post-bootstrap-freeze-\(UUID().uuidString)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "post-bootstrap-freeze-owner@example.test"
        let jid = "post-bootstrap-freeze-peer@example.test"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let archiveId: (Int) -> String = {
            String(1_900_000_000_000_000 + $0)
        }
        let realm = try WRealm.safe()

        // Model the real ordering: MAM page persistence commits first. The
        // compound op2 below opens its own Realm and only freezes these already
        // committed objects while its consistency write lease is active.
        try realm.write {
            for index in 120...200 {
                let message = MessageStorageItem()
                message.primary = "post-bootstrap-primary-\(index)"
                message.owner = owner
                message.opponent = jid
                message.conversationType = conversationType
                message.archivedId = archiveId(index)
                message.messageId = "post-bootstrap-message-\(index)"
                message.date = Date(timeIntervalSince1970: TimeInterval(index))
                message.sentDate = message.date
                message.outgoing = index.isMultiple(of: 2)
                message.isRead = true
                message.state = .read
                realm.add(message, update: .modified)
            }

            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = conversationType
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.syncSnapshotLastArchiveId = archiveId(200)
            chat.lastMessageId = "post-bootstrap-message-200"
            chat.messageDate = Date(timeIntervalSince1970: 200)
            realm.add(chat, update: .modified)

            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = archiveId(200)
            archiveState.newerLiveEdgeReached = true
            archiveState.mergeLoadedRange(
                first: archiveId(120),
                last: archiveId(200),
                updateKind: .disjointWindow
            )
            archiveState.updatedAt = Date()
        }
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self).filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                owner,
                jid,
                conversationType.rawValue
            ).count,
            81
        )

        let conversationKey = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            conversationKey: conversationKey,
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
            ),
            observesStoreImmediately: false
        )
        let target = ChatTimelineInitialFrameTarget.message(ChatTimelineAnchor(
            primary: "post-bootstrap-primary-160",
            archivedId: archiveId(160),
            messageId: "post-bootstrap-message-160",
            date: Date(timeIntervalSince1970: 160)
        ))
        let committed = expectation(
            description: "compound Realm lease materializes and commits"
        )
        var result: ChatTimelinePostBootstrapMappedCommitResult<[String]>?
        XCTAssertEqual(
            session.prepareMapAndCommitPostBootstrapInitialFrame(
                target: target,
                // The controller's resident datasource page is 250, but an
                // initial exact rematerialization must clamp at the 80-row
                // first-frame contract inside the session API itself.
                limit: ChatHistoryPagingConfiguration.pageSize,
                expectedGeneration: session.snapshot.generation,
                map: { frame in
                    ChatFirstFrameMappedValue(
                        value: frame.snapshot.items.map(\.primary),
                        mappedOnMainThread: Thread.isMainThread
                    )
                },
                shouldCommit: { _, mapped in
                    !mapped.mappedOnMainThread
                },
                completion: {
                    result = $0
                    committed.fulfill()
                }
            ),
            .started
        )
        wait(for: [committed], timeout: 2)

        guard case .committed(let frame, let snapshot, let mapped) = result else {
            return XCTFail(
                "previously committed Realm objects must survive freeze inside op2"
            )
        }
        XCTAssertEqual(frame.alignment, .anchor(
            primary: "post-bootstrap-primary-160",
            archivedId: archiveId(160)
        ))
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(mapped.value, frame.snapshot.items.map(\.primary))
        XCTAssertTrue(mapped.value.contains("post-bootstrap-primary-160"))
        XCTAssertLessThanOrEqual(
            mapped.value.count,
            ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertTrue(
            frame.unreadMetadata.initialFrameReadinessProof?
                .hasDurableArchiveReadiness == true
        )
        XCTAssertEqual(store.diagnosticsSnapshot.queryCount, 1)
        XCTAssertEqual(
            store.diagnosticsSnapshot.operationCounts,
            ["postBootstrapWindowAndMetadata": 1]
        )
        XCTAssertEqual(store.diagnosticsSnapshot.mainThreadQueryCount, 0)
        XCTAssertEqual(store.diagnosticsSnapshot.fullScanCount, 0)
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
    func testSavedPositionLocalFixtureSelectsOnlyMatchingLiveEdgeSavedProvenance() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ChatPerformanceLabTests-saved-local-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .savedPositionLocal
        ))
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: controller.conversationType
            )
        ))
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(
            chat.lastVisiblePositionSavedAtLastMessageId,
            chat.lastMessageId
        )
        XCTAssertEqual(
            chat.lastVisiblePositionSavedAtSnapshotLastArchiveId,
            chat.syncSnapshotLastArchiveId
        )
        XCTAssertNotNil(chat.lastVisibleMessageArchivedId)

        let request = try XCTUnwrap(controller.pendingOpenMessageRequest)
        XCTAssertEqual(request.source, .savedVisiblePosition)
        XCTAssertEqual(request.anchor.messagePrimary, chat.lastVisibleMessagePrimary)
        XCTAssertEqual(request.anchor.archivedId, chat.lastVisibleMessageArchivedId)
        XCTAssertEqual(request.anchor.messageId, chat.lastVisibleMessageId)
        XCTAssertFalse(request.highlight)
        XCTAssertFalse(request.markReadOnVisible)
        guard case .anchor = request.targetResolution else {
            return XCTFail("Saved fixture must retain the saved-position anchor resolution")
        }

        let productionStore = RealmChatTimelineSessionStore(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let productionWindow = try XCTUnwrap(productionStore.messageWindow(
            primary: request.anchor.messagePrimary,
            archivedId: request.anchor.archivedId,
            messageId: request.anchor.messageId,
            before: 40,
            after: 39
        ))
        XCTAssertEqual(
            productionWindow.target.primary,
            request.anchor.messagePrimary
        )
        XCTAssertTrue(productionWindow.items.contains {
            $0.primary == productionWindow.target.primary
        })
        XCTAssertLessThanOrEqual(productionWindow.items.count, 80)
        _ = productionStore.unreadMetadata(limit: 80)
        let productionDiagnostics = productionStore.diagnosticsSnapshot
        XCTAssertEqual(productionDiagnostics.queryCount, 2)
        XCTAssertEqual(
            Set(productionDiagnostics.operationCandidateCounts.keys),
            Set(["messageWindow", "unread"])
        )
        XCTAssertEqual(productionDiagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(
            productionDiagnostics.maxCandidateCount,
            80
        )
    }

    @MainActor
    func testInitialAdmissionHelpersDoNotTouchHistoryProviderBeforeTypedBackgroundPreparation() throws {
        for scenario in [
            ChatOpenRealPipelineFixtureScenario.unreadBoundaryLocal,
            .savedPositionLocal
        ] {
            let previousConfiguration = Realm.Configuration.defaultConfiguration
            Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "ChatPerformanceLabTests-admission-zero-\(scenario.rawValue)-\(UUID().uuidString)"
            )
            let controller = ChatPerformanceFixtureViewController(descriptor: .init(
                scale: .small,
                openScenario: scenario
            ))
            defer {
                controller.performTerminalChatResourceTeardownForTesting()
                ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
                Realm.Configuration.defaultConfiguration = previousConfiguration
            }

            controller.configureDataset()
            let request = try XCTUnwrap(controller.pendingOpenMessageRequest)
            let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
                request: request,
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType
            )
            for _ in 0..<3 {
                XCTAssertTrue(controller.hasLocalAnchorForBootstrap(request))
                _ = controller.currentBootstrapLoadingState()
                _ = controller.currentBootstrapRequiresArchiveConfirmation()
                if scenario == .savedPositionLocal {
                    _ = controller.savedPositionFirstFrameDecision(for: request)
                    controller.initialLocalFirstFramePhase = .preparing(descriptor)
                    XCTAssertTrue(
                        controller.shouldDeferInitialBootstrapArchiveForSavedPositionProbe(
                            .savedPosition(
                                messagePrimary: request.anchor.messagePrimary,
                                archivedId: request.anchor.archivedId,
                                messageId: request.anchor.messageId,
                                sourceDate: request.anchor.sourceDate
                            )
                        )
                    )
                }
            }

            let diagnostics = try XCTUnwrap(
                controller.timelineSession?.routeStoreDiagnosticsSnapshot
            )
            XCTAssertEqual(diagnostics.queryCount, 0)
            XCTAssertEqual(diagnostics.mainThreadQueryCount, 0)
            XCTAssertEqual(diagnostics.fullScanCount, 0)
            XCTAssertTrue(diagnostics.operationCandidateCounts.isEmpty)

            let directControl: MessageStorageItem?
            switch scenario {
            case .unreadBoundaryLocal:
                guard case .firstIncomingAfterBoundary(let boundary) =
                    request.targetResolution else {
                    return XCTFail("Unread fixture must retain its boundary target")
                }
                directControl = controller.timelineSession?.firstIncoming(
                    afterArchiveBoundaryId: boundary
                )
            case .savedPositionLocal:
                directControl = controller.timelineSession?.resolvedMessage(
                    primary: request.anchor.messagePrimary,
                    archivedId: request.anchor.archivedId,
                    messageId: request.anchor.messageId
                )
            default:
                directControl = nil
            }
            XCTAssertNotNil(directControl)
            let controlDiagnostics = try XCTUnwrap(
                controller.timelineSession?.routeStoreDiagnosticsSnapshot
            )
            XCTAssertEqual(controlDiagnostics.queryCount, 1)
            XCTAssertEqual(controlDiagnostics.mainThreadQueryCount, 1)
            XCTAssertEqual(controlDiagnostics.fullScanCount, 0)
            controller.initialLocalFirstFramePhase = .idle
        }
    }

    func testInitialFrameControllerGuardsContainNoDirectHistoryPresenceFallback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let datasetSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
            ),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatTimelineSession.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(
            datasetSource.contains(
                "ConversationArchiveDurableReadinessPolicy.localMessageCount"
            ),
            "request-to-commit controller guards must consume the finalized proof instead of querying MessageStorageItem"
        )

        let countStart = try XCTUnwrap(datasetSource.range(
            of: "internal func localHistoryMessageCountForBootstrap()"
        ))
        let countEnd = try XCTUnwrap(datasetSource.range(
            of: "internal func currentInitialFrameReadinessProof()",
            range: countStart.upperBound..<datasetSource.endIndex
        ))
        let countFunction = String(datasetSource[
            countStart.lowerBound..<countEnd.lowerBound
        ])
        ["WRealm.safe", ".latest(", ".message(", ".around(", ".firstIncoming("].forEach {
            XCTAssertFalse(
                countFunction.contains($0),
                "synchronous history-presence guard contains forbidden fallback: \($0)"
            )
        }

        let mapping = try XCTUnwrap(datasetSource.range(
            of: "ChatFirstFrameDisplayMappingExecutor.map("
        ))
        let finalization = try XCTUnwrap(datasetSource.range(
            of: "session.finalizeAndCommitPreparedInitialFrame(",
            range: mapping.upperBound..<datasetSource.endIndex
        ))
        XCTAssertLessThan(mapping.lowerBound, finalization.lowerBound)
        XCTAssertFalse(
            datasetSource[finalization.lowerBound...].contains(
                "session.commitPreparedInitialFrame("
            ),
            "controller commit must stay inside the op2 consistency lease"
        )
        XCTAssertTrue(
            datasetSource.contains(
                "admission.authorizesCommit"
            ),
            "compound op2 authorization must use the lock-protected query/target admission"
        )
        XCTAssertTrue(
            datasetSource.contains(
                "revokePostBootstrapInitialFrameAdmissionIfSuperseded("
            )
        )
        XCTAssertTrue(
            datasetSource.contains(
                "bootstrapQueryId: self.initialBootstrapQueryId"
            )
        )
        XCTAssertTrue(
            datasetSource.contains(
                "targetFingerprint: self.initialBootstrapTargetFingerprint"
            )
        )

        func sourceSlice(
            _ source: String,
            from startToken: String,
            until endToken: String
        ) throws -> String {
            let start = try XCTUnwrap(source.range(of: startToken))
            let end = try XCTUnwrap(source.range(
                of: endToken,
                range: start.upperBound..<source.endIndex
            ))
            return String(source[start.lowerBound..<end.lowerBound])
        }

        let configureDataset = try sourceSlice(
            controllerSource,
            from: "final func configureDataset()",
            until: "final func configureBackground()"
        )
        let reloadAdmission = try sourceSlice(
            datasetSource,
            from: "internal func reloadInitialWindowAfterBootstrapIfNeeded(",
            until: "internal func prepareInitialLocalFirstFrame("
        )
        let prepareAdmission = try sourceSlice(
            datasetSource,
            from: "internal func prepareInitialLocalFirstFrame(",
            until: "private func handlePreparedInitialLocalFirstFrame("
        )
        let initialLoad = try sourceSlice(
            datasetSource,
            from: "internal final func loadInitialDatasource(",
            until: "private func armedRemoteSnapshot("
        )
        [configureDataset, reloadAdmission, prepareAdmission, initialLoad].forEach {
            XCTAssertFalse($0.contains("WRealm.safe"))
            XCTAssertFalse(
                $0.contains("loadChatArchiveStateSnapshot"),
                "configure/admission must not read Realm outside op1/op2"
            )
        }

        let lease = try XCTUnwrap(sessionSource.range(
            of: "self.store.withInitialFrameMetadataConsistencyLease("
        ))
        let atomicAuthorization = try XCTUnwrap(sessionSource.range(
            of: "atomicResult = self.atomicInitialFrameCommitResult(",
            range: lease.upperBound..<sessionSource.endIndex
        ))
        let atomicCommit = try XCTUnwrap(sessionSource.range(
            of: "commitPreparedInitialFrame(frame)",
            range: lease.upperBound..<sessionSource.endIndex
        ))
        XCTAssertLessThan(lease.lowerBound, atomicAuthorization.lowerBound)
        XCTAssertLessThan(atomicAuthorization.lowerBound, atomicCommit.lowerBound)
        XCTAssertFalse(
            sessionSource.contains("DispatchQueue.main.sync"),
            "the op2 Realm write lease must never wait on main"
        )
        XCTAssertTrue(sessionSource.contains("realm.beginWrite()"))
        XCTAssertTrue(sessionSource.contains("realm.cancelWrite()"))
        let storedFinalizationState = try sourceSlice(
            sessionSource,
            from: "private enum FinalizationState {",
            until: "fileprivate enum FinalizationEnqueueDisposition {"
        )
        XCTAssertTrue(
            storedFinalizationState.contains(
                "case resolved(FinalizationTerminalPayload)"
            )
        )
        XCTAssertFalse(
            storedFinalizationState.contains(
                "case resolved(ChatTimelineInitialFrameFinalizationCommitResult)"
            ),
            "a frame must never retain a terminal result that strongly owns the same frame"
        )
        XCTAssertTrue(sessionSource.contains("func replayResult("))
        XCTAssertTrue(
            sessionSource.contains(
                "self.store.withPostBootstrapInitialFrameConsistencyLease("
            )
        )
        let resumedMissingTarget = try sourceSlice(
            datasetSource,
            from: "if resumesPersistedMissingTarget {",
            until: "let disposition = session.prepareInitialFrame("
        )
        XCTAssertTrue(
            resumedMissingTarget.contains(
                "session.prepareMapAndCommitPostBootstrapInitialFrame("
            )
        )
        XCTAssertFalse(
            resumedMissingTarget.contains(
                "session.finalizeAndCommitPreparedInitialFrame("
            ),
            "post-MAM target window, metadata and commit must remain one op2 lease"
        )
        XCTAssertTrue(
            resumedMissingTarget.contains(
                "activePostBootstrapInitialFrameAdmission = admission"
            )
        )
        XCTAssertTrue(
            resumedMissingTarget.contains(
                "self.isCurrentPostBootstrapInitialFrameAdmission("
            )
        )

        let singleFrameTests = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabberTests/ChatSingleFrameLocalOpenTests.swift"
            ),
            encoding: .utf8
        )
        [
            "testCommittedDeferredInitialFrameDeallocatesAfterAllExternalOwnersRelease",
            "testRejectedDeferredInitialFrameDeallocatesAfterAllExternalOwnersRelease",
            "testResolvedDuplicateWaiterStillReceivesSameTerminalWithoutRetainingFrame"
        ].forEach {
            XCTAssertTrue(singleFrameTests.contains("func \($0)()"))
        }
    }

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

    @MainActor
    func testLatestWithUnrelatedOlderGapFixtureKeepsGapOutsideLiveTailAndSelectsNoAnchor() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ChatPerformanceLabTests-unrelated-gap-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .latestWithUnrelatedOlderGap
        ))
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let realm = try WRealm.safe()
        let archiveState = try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: controller.conversationType
            )
        ))
        XCTAssertEqual(archiveState.loadedRanges.count, 2)
        XCTAssertEqual(archiveState.knownGaps.count, 1)
        let liveTailRange = try XCTUnwrap(archiveState.loadedRanges.last)
        let olderGap = try XCTUnwrap(archiveState.knownGaps.first)
        XCTAssertEqual(
            olderGap.newerRangeOldestArchiveId,
            liveTailRange.oldestArchiveId
        )
        XCTAssertLessThan(
            try XCTUnwrap(Int64(olderGap.olderRangeNewestArchiveId)),
            try XCTUnwrap(Int64(liveTailRange.oldestArchiveId))
        )
        let liveTailCount = realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                controller.owner,
                controller.jid,
                controller.conversationType.rawValue
            )
            .filter { item in
                guard let itemValue = Int64(item.archivedId),
                      let tailValue = Int64(liveTailRange.oldestArchiveId) else {
                    return false
                }
                return itemValue >= tailValue
            }
            .count
        XCTAssertEqual(liveTailCount, 80)
        let productionStore = RealmChatTimelineSessionStore(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let productionLiveTail = productionStore.initialLatestWindow(limit: 80)
        XCTAssertEqual(productionLiveTail.count, 80)
        XCTAssertEqual(
            productionLiveTail.first?.archivedId,
            liveTailRange.oldestArchiveId
        )
        XCTAssertEqual(
            productionLiveTail.last?.archivedId,
            liveTailRange.newestArchiveId
        )
        _ = productionStore.unreadMetadata(limit: 80)
        let productionDiagnostics = productionStore.diagnosticsSnapshot
        XCTAssertEqual(productionDiagnostics.queryCount, 2)
        XCTAssertEqual(
            Set(productionDiagnostics.operationCandidateCounts.keys),
            Set(["latestWindow", "unread"])
        )
        XCTAssertEqual(productionDiagnostics.fullScanCount, 0)
        XCTAssertLessThanOrEqual(productionDiagnostics.maxCandidateCount, 80)
        XCTAssertTrue(archiveState.newerLiveEdgeReached)
        XCTAssertNil(controller.pendingOpenMessageRequest)
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

    @MainActor
    func testStableReceiptRejectsLateOffsetApplyAndRemoteWorkAfterFirstQuietPair() throws {
        var gate = ChatOpenRealPipelineFixtureTerminalStabilityGate(
            quietWindow: 0.5
        )
        let firstTerminalSample = ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot(
            datasourceGeneration: 4,
            datasourceApplyCount: 1,
            firstContentApplyCount: 1,
            visualCommitCount: 1,
            offsetMutationCount: 0,
            postCommitOffsetMutationCount: 0,
            correctionCount: 0,
            archiveRequestCount: 0,
            gapRequestCount: 0,
            productionBootstrapLeaseEventCount: 0,
            productionBootstrapTransportCount: 0,
            fixtureRealmQueryCountAfterRouteAdmission: 0,
            activeProductionWorkCount: 0
        )

        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: firstTerminalSample,
            hasExpectedTerminal: true,
            now: 10
        ))
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: firstTerminalSample,
            hasExpectedTerminal: true,
            now: 10.12
        ), "The old two-sample 120 ms quiet pair must remain provisional")

        let lateApplyAndRemoteWork = ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot(
            datasourceGeneration: 5,
            datasourceApplyCount: 2,
            firstContentApplyCount: 1,
            visualCommitCount: 1,
            offsetMutationCount: 1,
            postCommitOffsetMutationCount: 1,
            correctionCount: 0,
            archiveRequestCount: 1,
            gapRequestCount: 1,
            productionBootstrapLeaseEventCount: 1,
            productionBootstrapTransportCount: 1,
            fixtureRealmQueryCountAfterRouteAdmission: 0,
            activeProductionWorkCount: 1
        )
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: lateApplyAndRemoteWork,
            hasExpectedTerminal: true,
            now: 10.13
        ))

        let lateWorkSettled = ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot(
            datasourceGeneration: 5,
            datasourceApplyCount: 2,
            firstContentApplyCount: 1,
            visualCommitCount: 1,
            offsetMutationCount: 1,
            postCommitOffsetMutationCount: 1,
            correctionCount: 0,
            archiveRequestCount: 1,
            gapRequestCount: 1,
            productionBootstrapLeaseEventCount: 1,
            productionBootstrapTransportCount: 1,
            fixtureRealmQueryCountAfterRouteAdmission: 0,
            activeProductionWorkCount: 0
        )
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: lateWorkSettled,
            hasExpectedTerminal: true,
            now: 10.25
        ))
        XCTAssertNil(gate.stableReceiptIfReady(
            evidence: lateWorkSettled,
            hasExpectedTerminal: true,
            now: 10.74
        ))
        let receipt = try XCTUnwrap(gate.stableReceiptIfReady(
            evidence: lateWorkSettled,
            hasExpectedTerminal: true,
            now: 10.76
        ))
        XCTAssertGreaterThanOrEqual(receipt.quietMilliseconds, 500)
        XCTAssertGreaterThanOrEqual(receipt.provisionalResetCount, 1)
        XCTAssertEqual(receipt.evidence, lateWorkSettled)

        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-late-terminal-work-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .unreadBoundaryLocal
        ))
        let window = UIWindow(frame: UIScreen.main.bounds)
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        defer {
            controller.openScenarioDidStabilize = nil
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            coordinator.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let injected = expectation(description: "late production work injected")
        let published = expectation(description: "receipt published after late work")
        var injectionTime: CFTimeInterval?
        var publicationTime: CFTimeInterval?
        controller.openScenarioDidStabilize = { _ in
            publicationTime = CACurrentMediaTime()
            published.fulfill()
        }
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()

        let commitPollDeadline = Date().addingTimeInterval(5)
        var pollForCommittedFrame: (() -> Void)?
        pollForCommittedFrame = { [weak controller] in
            guard let controller else { return }
            guard controller.openScenarioCommittedInitialFrameDiagnostics != nil else {
                if Date() < commitPollDeadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        pollForCommittedFrame?()
                    }
                }
                return
            }
            // The rejected implementation published after a second equal
            // sample at 120 ms. Inject after that pair so a frozen receipt
            // would miss all three real production mutations below.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                let currentOffset = controller.messagesCollectionView.contentOffset
                controller.messagesCollectionView.setContentOffset(
                    CGPoint(x: currentOffset.x, y: currentOffset.y + 8),
                    animated: false
                )
                controller.applyChatDatasource(
                    controller.datasource,
                    mode: .fullReload(keepOffset: true),
                    animated: false,
                    invalidateLayout: false,
                    suppressDefaultBottomScroll: true
                )

                let acquisition = coordinator.acquire(
                    key: controller.initialBootstrapRequestKey,
                    proposedQueryId: "late-terminal-production-work",
                    timeout: 30
                ) { _, _, _ in }
                guard case .start(let lease) = acquisition else {
                    XCTFail("Late work must acquire the real coordinator lease")
                    injected.fulfill()
                    return
                }
                coordinator.resolveStart(
                    key: controller.initialBootstrapRequestKey,
                    queryId: lease.queryId,
                    result: .bootstrapStarted(queryId: lease.queryId),
                    messages: nil,
                    cancelTransport: {}
                )
                XCTAssertTrue(coordinator.complete(
                    key: controller.initialBootstrapRequestKey,
                    queryId: lease.queryId
                ))
                injectionTime = CACurrentMediaTime()
                injected.fulfill()
            }
        }
        pollForCommittedFrame?()

        wait(for: [injected, published], timeout: 12)
        pollForCommittedFrame = nil
        let integratedReceipt = try XCTUnwrap(controller.openScenarioStableReceipt)
        XCTAssertGreaterThanOrEqual(integratedReceipt.datasourceApplyCount, 2)
        XCTAssertGreaterThanOrEqual(
            integratedReceipt.postCommitOffsetMutationCount,
            1
        )
        XCTAssertEqual(integratedReceipt.productionBootstrapLeaseStartCount, 1)
        XCTAssertEqual(integratedReceipt.productionBootstrapTransportStartCount, 1)
        XCTAssertEqual(integratedReceipt.productionBootstrapActiveLeaseCount, 0)
        XCTAssertGreaterThanOrEqual(
            integratedReceipt.terminalQuietMilliseconds,
            500
        )
        let unwrappedPublicationTime = try XCTUnwrap(publicationTime)
        let unwrappedInjectionTime = try XCTUnwrap(injectionTime)
        XCTAssertGreaterThanOrEqual(
            unwrappedPublicationTime - unwrappedInjectionTime,
            0.5
        )
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
    func testLocalRouteReceiptObservesProductionBootstrapLeaseAndTransportInsteadOfPlanCounters() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-production-bootstrap-proof-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .unreadBoundaryLocal
        ))
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
            coordinator.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        XCTAssertEqual(
            controller.captureOpenScenarioProductionBootstrapDiagnostics(),
            .zero
        )
        let acquisition = coordinator.acquire(
            key: controller.initialBootstrapRequestKey,
            proposedQueryId: "production-bootstrap-proof",
            timeout: 30
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("The production coordinator must issue the first lease")
        }

        var diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.leaseStartCount, 1)
        XCTAssertEqual(diagnostics.leaseJoinCount, 0)
        XCTAssertEqual(diagnostics.activeLeaseCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 0)

        coordinator.resolveStart(
            key: controller.initialBootstrapRequestKey,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )
        diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.activeLeaseCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 1)

        XCTAssertTrue(coordinator.complete(
            key: controller.initialBootstrapRequestKey,
            queryId: lease.queryId
        ))
        diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.activeLeaseCount, 0)
        XCTAssertEqual(diagnostics.completedLeaseCount, 1)
        XCTAssertEqual(diagnostics.failedLeaseCount, 0)
        XCTAssertEqual(diagnostics.cancelledLeaseCount, 0)

        let failedAcquisition = coordinator.acquire(
            key: controller.initialBootstrapRequestKey,
            proposedQueryId: "production-bootstrap-proof-failed",
            timeout: 30
        ) { _, _, _ in }
        guard case .start(let failedLease) = failedAcquisition else {
            return XCTFail("Failure proof must own a fresh production lease")
        }
        coordinator.resolveStart(
            key: controller.initialBootstrapRequestKey,
            queryId: failedLease.queryId,
            result: .bootstrapStarted(queryId: failedLease.queryId),
            messages: nil,
            cancelTransport: {}
        )
        XCTAssertTrue(coordinator.recordFailure(
            key: controller.initialBootstrapRequestKey,
            event: MessageArchiveRequestFailureEvent(
                owner: controller.owner,
                queryId: failedLease.queryId,
                streamKind: .unknown,
                reason: .timeout,
                errorDescription: nil,
                pendingQueryCount: 1
            ),
            publishEvent: false
        ))
        diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.activeLeaseCount, 0)
        XCTAssertEqual(diagnostics.failedLeaseCount, 1)
        coordinator.clearTerminal(key: controller.initialBootstrapRequestKey)

        let cancelledAcquisition = coordinator.acquire(
            key: controller.initialBootstrapRequestKey,
            proposedQueryId: "production-bootstrap-proof-cancelled",
            timeout: 30
        ) { _, _, _ in }
        guard case .start = cancelledAcquisition else {
            return XCTFail("Cancellation proof must own a fresh production lease")
        }
        coordinator.discardConfirmedAttempt(
            key: controller.initialBootstrapRequestKey
        )
        diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.activeLeaseCount, 0)
        XCTAssertEqual(diagnostics.cancelledLeaseCount, 1)

        let joinedStart = coordinator.acquire(
            key: controller.initialBootstrapRequestKey,
            proposedQueryId: "production-bootstrap-proof-joined-start",
            timeout: 30
        ) { _, _, _ in }
        guard case .start(let joinedLease) = joinedStart else {
            return XCTFail("Join proof must own its first production lease")
        }
        let joined = coordinator.acquire(
            key: controller.initialBootstrapRequestKey,
            proposedQueryId: "production-bootstrap-proof-joined-observer",
            timeout: 30
        ) { _, _, _ in }
        guard case .joined(let observedLease) = joined else {
            return XCTFail("Second acquisition must join the production lease")
        }
        XCTAssertEqual(observedLease.queryId, joinedLease.queryId)
        diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.leaseJoinCount, 1)
        XCTAssertEqual(diagnostics.activeLeaseCount, 1)
        XCTAssertTrue(coordinator.complete(
            key: controller.initialBootstrapRequestKey,
            queryId: joinedLease.queryId
        ))
        diagnostics = controller.captureOpenScenarioProductionBootstrapDiagnostics()
        XCTAssertEqual(diagnostics.activeLeaseCount, 0)
        XCTAssertEqual(diagnostics.completedLeaseCount, 2)
        XCTAssertEqual(diagnostics.failedLeaseCount, 1)
        XCTAssertEqual(diagnostics.cancelledLeaseCount, 1)
        XCTAssertEqual(diagnostics.transportStartCount, 2)
    }

    @MainActor
    func testLocalRouteReceiptCarriesBoundedStoreMapAndLayoutMetricsFromProductionCommit() throws {
        for scenario in [
            ChatOpenRealPipelineFixtureScenario.preloadedLatest,
            .notificationExactLocal,
            .searchExactLocal,
            .unreadBoundaryLocal,
            .savedPositionLocal,
            .latestWithUnrelatedOlderGap
        ] {
            try withStableLocalOpenScenario(scenario) { controller, receipt in
                XCTAssertEqual(receipt.storeQueryCount, 2)
                XCTAssertEqual(receipt.mainThreadStoreQueryCount, 0)
                XCTAssertEqual(receipt.fullScanCount, 0)
                XCTAssertLessThanOrEqual(receipt.maxCandidateCount, 80)
                XCTAssertFalse(receipt.preparedOnMainThread)
                XCTAssertFalse(receipt.mappedOnMainThread)
                XCTAssertEqual(receipt.realDatasourceApplyCount, 1)
                XCTAssertEqual(receipt.atomicLayoutCommitCount, 1)
                XCTAssertEqual(receipt.committedRouteCount, 1)
                XCTAssertEqual(receipt.postCommitOffsetMutationCount, 0)
                XCTAssertEqual(receipt.correctionCount, 0)
                XCTAssertGreaterThanOrEqual(receipt.terminalQuietMilliseconds, 500)
                XCTAssertEqual(receipt.activeProductionWorkCount, 0)
            }
        }
    }

    @MainActor
    func testInitialFrameObserverInstallationPerformsZeroMainThreadRealmQueriesThroughStableReceipt() throws {
        for scenario in ChatOpenRealPipelineFixtureScenario.allCases {
            try withStableLocalOpenScenario(scenario) { _, receipt in
                XCTAssertEqual(receipt.observerActivationCount, 1)
                XCTAssertGreaterThanOrEqual(receipt.observerRealmQueryCount, 1)
                XCTAssertLessThanOrEqual(receipt.observerRealmQueryCount, 2)
                XCTAssertEqual(receipt.mainThreadObserverRealmQueryCount, 0)
                XCTAssertEqual(
                    receipt.observerInitialCallbackCount,
                    receipt.observerRealmQueryCount
                )
                XCTAssertEqual(receipt.mainThreadObserverInitialCallbackCount, 0)
                XCTAssertLessThanOrEqual(
                    receipt.observerMaxInitialCandidateCount,
                    80
                )
                XCTAssertEqual(receipt.observerMetadataQueryCount, 0)
                XCTAssertEqual(receipt.mainThreadObserverMetadataQueryCount, 0)
                XCTAssertEqual(receipt.observerMetadataFullScanCount, 0)
                XCTAssertEqual(receipt.observerMaxMetadataCandidateCount, 0)
                XCTAssertEqual(receipt.observerCatchUpMutationCount, 0)
                XCTAssertEqual(receipt.observerPendingWorkCount, 0)
                XCTAssertEqual(receipt.firstContentApplyCount, 1)
                XCTAssertEqual(receipt.realDatasourceApplyCount, 1)
                XCTAssertEqual(receipt.previousOrBlankRealFrameCount, 0)
                XCTAssertEqual(receipt.activeProductionWorkCount, 0)
            }
        }
    }

    @MainActor
    func testObserverInitialCatchUpAppliesMessageArrivingBetweenCommitAndRegistrationExactlyOnce() throws {
        try assertObserverInitialCatchUp(
            mutation: .append,
            expectedFinalPrimaries: [
                "observer-primary-0",
                "observer-primary-1",
                "observer-primary-2",
                "observer-primary-3"
            ],
            expectedInsertedPrimaries: ["observer-primary-3"]
        )
    }

    @MainActor
    func testObserverInitialCatchUpNeverReappliesCommittedFirstFrameOrPublishesOldDatasource() throws {
        try assertObserverInitialCatchUp(
            mutation: .edit,
            expectedFinalPrimaries: [
                "observer-primary-0",
                "observer-primary-1",
                "observer-primary-2"
            ],
            expectedUpdatedPrimaries: ["observer-primary-2"]
        )
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
    func testObserverInitialCatchUpDetectsSameIdentityEditDeleteAndTombstoneExactlyOnce() throws {
        try assertObserverInitialCatchUp(
            mutation: .edit,
            expectedFinalPrimaries: [
                "observer-primary-0",
                "observer-primary-1",
                "observer-primary-2"
            ],
            expectedUpdatedPrimaries: ["observer-primary-2"]
        )
        try assertObserverInitialCatchUp(
            mutation: .physicalDelete,
            expectedFinalPrimaries: [
                "observer-primary-0",
                "observer-primary-1"
            ],
            expectedDeletedPrimaries: ["observer-primary-2"]
        )
        try assertObserverInitialCatchUp(
            mutation: .tombstone,
            expectedFinalPrimaries: [
                "observer-primary-0",
                "observer-primary-1"
            ],
            expectedDeletedPrimaries: ["observer-primary-2"]
        )
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
    func testCommittedRouteProvenanceComesFromAcceptedProductionViewportRequest() throws {
        for scenario in [
            ChatOpenRealPipelineFixtureScenario.unreadBoundaryLocal,
            .notificationExactLocal,
            .searchExactLocal,
            .savedPositionLocal,
            .latestWithUnrelatedOlderGap
        ] {
            try withStableLocalOpenScenario(scenario) { controller, receipt in
                let committed = try XCTUnwrap(
                    controller.openScenarioCommittedInitialFrameDiagnostics
                )
                let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
                XCTAssertEqual(committed.requestSource, plan.expectedRequestSource)
                XCTAssertEqual(
                    committed.requestHighlight,
                    plan.expectedRequestHighlight ?? false
                )
                XCTAssertEqual(
                    committed.requestMarkReadOnVisible,
                    plan.expectedRequestMarkReadOnVisible
                )
                XCTAssertEqual(committed.targetKind, plan.targetKind)
                XCTAssertEqual(receipt.requestSource, committed.requestSource)
                XCTAssertEqual(receipt.requestHighlight, committed.requestHighlight)
                XCTAssertEqual(
                    receipt.requestMarkReadOnVisible,
                    committed.requestMarkReadOnVisible
                )
                XCTAssertEqual(receipt.committedTargetKind, committed.targetKind)
                XCTAssertEqual(receipt.committedRouteCount, 1)
                XCTAssertNil(
                    controller.pendingOpenMessageRequest,
                    "Receipt provenance must survive consumption of the input request"
                )
            }
        }
    }

    @MainActor
    func testNewSessionRequestToTerminalReceiptsCoverEveryLocalOpeningTarget() throws {
        for scenario in localRequestToTerminalCoverageScenarios {
            try withStableLocalOpenScenario(scenario) { controller, receipt in
                let isRemoteAnchor = scenario == .knownGapMissingTarget
                let expectedRouteQueries = isRemoteAnchor ? 3 : 2
                XCTAssertFalse(receipt.usesReusedTimelineSession)
                XCTAssertEqual(receipt.storeQueryBaselineCount, 0)
                XCTAssertEqual(
                    receipt.initialFrameStoreQueryCount,
                    2
                )
                XCTAssertEqual(receipt.storeQueryCount, expectedRouteQueries)
                XCTAssertEqual(
                    receipt.storeLifetimeQueryCount,
                    expectedRouteQueries
                )
                assertRequestToTerminalRouteReceipt(
                    receipt,
                    scenario: scenario
                )
                let routeDiagnostics = try XCTUnwrap(
                    controller.captureOpenScenarioRouteStoreDiagnosticsForTesting()
                )
                XCTAssertEqual(routeDiagnostics.queryCount, expectedRouteQueries)
                XCTAssertEqual(
                    routeDiagnostics.operationCounts.values.reduce(0, +),
                    expectedRouteQueries
                )
                if scenario == .knownGapMissingTarget {
                    XCTAssertEqual(receipt.blockingInitialStoreQueryCount, 1)
                    XCTAssertEqual(receipt.postInitialStoreQueryCount, 0)
                    XCTAssertEqual(
                        receipt.initialFrameStoreQueryCount +
                            receipt.blockingInitialStoreQueryCount +
                            receipt.postInitialStoreQueryCount,
                        receipt.storeQueryCount
                    )
                    XCTAssertEqual(
                        receipt.initialFrameStoreOperationSummary
                            .accessibilityValue,
                        "message-window:1,post-bootstrap:1"
                    )
                    XCTAssertEqual(
                        receipt.initialFrameStoreOperationSummary.totalCount,
                        receipt.initialFrameStoreQueryCount
                    )
                    XCTAssertEqual(
                        receipt.terminalRouteStoreOperationSummary,
                        ChatOpenRealPipelineFixtureStoreOperationSummary(
                            operationCounts: routeDiagnostics.operationCounts
                        )
                    )
                    XCTAssertEqual(
                        routeDiagnostics.operationCounts,
                        [
                            "messageWindow": 1,
                            "postBootstrapWindowAndMetadata": 2
                        ]
                    )
                    XCTAssertEqual(
                        receipt.blockingInitialStoreOperationSummary
                            .accessibilityValue,
                        "post-bootstrap:1"
                    )
                    XCTAssertEqual(
                        receipt.postInitialStoreOperationSummary
                            .accessibilityValue,
                        "none"
                    )
                    XCTAssertEqual(
                        Set(routeDiagnostics.operationCandidateCounts.keys),
                        Set([
                            "messageWindow",
                            "postBootstrapWindowAndMetadata"
                        ])
                    )
                }
            }
        }
    }

    @MainActor
    func testReusedSessionRequestToTerminalReceiptsCoverEveryLocalOpeningTarget() throws {
        for scenario in localRequestToTerminalCoverageScenarios {
            try withStableLocalOpenScenario(
                scenario,
                usingReusedSession: true
            ) { controller, receipt in
                let isRemoteAnchor = scenario == .knownGapMissingTarget
                let expectedRouteQueries = isRemoteAnchor ? 3 : 2
                XCTAssertTrue(receipt.usesReusedTimelineSession)
                XCTAssertTrue(
                    controller.timelineSession?
                        .hasActiveStoreObservationForTests == true,
                    "the transferred observation must be reactivated after the sole initial frame commits"
                )
                XCTAssertEqual(
                    receipt.storeQueryBaselineCount,
                    2,
                    "the reused session must carry one completed two-operation warm route"
                )
                XCTAssertEqual(receipt.storeQueryCount, expectedRouteQueries)
                XCTAssertEqual(
                    receipt.initialFrameStoreQueryCount,
                    2
                )
                XCTAssertEqual(
                    receipt.storeLifetimeQueryCount,
                    receipt.storeQueryBaselineCount + expectedRouteQueries,
                    "route delta must include every request-to-terminal operation without resetting lifetime diagnostics"
                )
                assertRequestToTerminalRouteReceipt(
                    receipt,
                    scenario: scenario
                )
                let routeDiagnostics = try XCTUnwrap(
                    controller.captureOpenScenarioRouteStoreDiagnosticsForTesting()
                )
                XCTAssertEqual(routeDiagnostics.queryCount, expectedRouteQueries)
                XCTAssertEqual(
                    routeDiagnostics.operationCounts.values.reduce(0, +),
                    expectedRouteQueries,
                    "lifetime operation keys must not hide extra work in the reused route"
                )
                if scenario == .knownGapMissingTarget {
                    XCTAssertEqual(receipt.blockingInitialStoreQueryCount, 1)
                    XCTAssertEqual(receipt.postInitialStoreQueryCount, 0)
                    XCTAssertEqual(
                        receipt.initialFrameStoreQueryCount +
                            receipt.blockingInitialStoreQueryCount +
                            receipt.postInitialStoreQueryCount,
                        receipt.storeQueryCount
                    )
                    XCTAssertEqual(
                        receipt.initialFrameStoreOperationSummary
                            .accessibilityValue,
                        "message-window:1,post-bootstrap:1"
                    )
                    XCTAssertEqual(
                        receipt.initialFrameStoreOperationSummary.totalCount,
                        receipt.initialFrameStoreQueryCount
                    )
                    XCTAssertEqual(
                        receipt.terminalRouteStoreOperationSummary,
                        ChatOpenRealPipelineFixtureStoreOperationSummary(
                            operationCounts: routeDiagnostics.operationCounts
                        )
                    )
                    XCTAssertEqual(
                        routeDiagnostics.operationCounts,
                        [
                            "messageWindow": 1,
                            "postBootstrapWindowAndMetadata": 2
                        ]
                    )
                    XCTAssertEqual(
                        receipt.blockingInitialStoreOperationSummary
                            .accessibilityValue,
                        "post-bootstrap:1"
                    )
                    XCTAssertEqual(
                        receipt.postInitialStoreOperationSummary
                            .accessibilityValue,
                        "none"
                    )
                    XCTAssertEqual(
                        Set(routeDiagnostics.operationCandidateCounts.keys),
                        Set([
                            "messageWindow",
                            "postBootstrapWindowAndMetadata"
                        ])
                    )
                }
            }
        }
    }

    @MainActor
    func testReplacingBootstrapQueryDuringPostBootstrapOp2RejectsOldFrameBeforeSessionCommit() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-op2-query-replacement-\(UUID().uuidString)"
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .knownGapMissingTarget
        ))
        let window = UIWindow(frame: UIScreen.main.bounds)
        let mappingReached = expectation(
            description: "old query reached compound op2 mapping barrier"
        )
        let releaseOldMapping = DispatchSemaphore(value: 0)
        controller.initialFirstFrameMappingBarrierForTests = {
            mappingReached.fulfill()
            _ = releaseOldMapping.wait(timeout: .now() + 2)
        }
        defer {
            releaseOldMapping.signal()
            controller.initialFirstFrameMappingBarrierForTests = nil
            controller.openScenarioDidStabilize = nil
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        window.rootViewController = UINavigationController(
            rootViewController: controller
        )
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        wait(for: [mappingReached], timeout: 4)

        let session = try XCTUnwrap(controller.timelineSession)
        let oldToken = try XCTUnwrap(controller.initialLocalFirstFrameMappingToken)
        let generationBeforeReplacement = session.snapshot.generation
        XCTAssertEqual(generationBeforeReplacement, 0)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        controller.beginInitialBootstrapTracking(
            queryId: "replacement-query-during-op2",
            timeout: nil
        )

        XCTAssertTrue(
            oldToken.isCancelled,
            "true query replacement must revoke the exact in-flight op2 mapping token"
        )
        XCTAssertNil(controller.activePostBootstrapInitialFrameAdmission)
        XCTAssertEqual(
            session.snapshot.generation,
            generationBeforeReplacement,
            "the superseded query must not commit a hidden session generation"
        )

        controller.initialFirstFrameMappingBarrierForTests = nil
        releaseOldMapping.signal()
        var replacementFinished = false
        XCTAssertTrue(controller.reloadInitialWindowAfterBootstrapIfNeeded(
            force: true,
            hasTrustedPersistedBootstrapPage: true
        ) {
            replacementFinished = true
        })
        XCTAssertTrue(waitUntil {
            replacementFinished &&
                session.snapshot.generation == generationBeforeReplacement + 1 &&
                controller.initialFirstContentApplyCount == 1 &&
                !controller.showSkeletonObserver.value
        })

        XCTAssertEqual(session.snapshot.generation, generationBeforeReplacement + 1)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 1)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            1
        )
        XCTAssertEqual(
            controller.openScenarioCommittedInitialFrameDiagnostics?.requestSource,
            .directOpenAtMessage
        )
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertFalse(controller.datasource.contains(where: \.isFakeMessage))
    }

    func testAnchorContextTopUpUsesInitialAndSubsequentPhasePageSizes() {
        let coverage = ChatAnchorContextCoverage(
            olderLocalCount: 40,
            newerLocalCount: 39,
            olderBoundary: .knownGap,
            newerBoundary: .knownGap
        )
        XCTAssertEqual(ChatInitialFirstFrameHistoryConfiguration.pageSize, 80)
        XCTAssertEqual(ChatHistoryPagingConfiguration.pageSize, 250)

        let initialFirstFrameTopUp = ChatAnchorContextPrefetchPolicy.plan(
            coverage: coverage,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            archivedId: "fixture-anchor",
            targetWindowIncludesAnchor: true
        )
        XCTAssertNil(initialFirstFrameTopUp.olderPageSize)
        XCTAssertNil(initialFirstFrameTopUp.newerPageSize)
        XCTAssertFalse(initialFirstFrameTopUp.requiresRemoteFetch)

        let subsequentBackgroundTopUp = ChatAnchorContextPrefetchPolicy.plan(
            coverage: coverage,
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            archivedId: "fixture-anchor"
        )
        XCTAssertEqual(subsequentBackgroundTopUp.olderPageSize, 85)
        XCTAssertEqual(subsequentBackgroundTopUp.newerPageSize, 86)
        XCTAssertEqual(
            (subsequentBackgroundTopUp.olderPageSize ?? 0) +
                (subsequentBackgroundTopUp.newerPageSize ?? 0),
            171
        )
        XCTAssertTrue(subsequentBackgroundTopUp.requiresRemoteFetch)

        let completeTargetWindow = ChatAnchorContextPrefetchPolicy.plan(
            coverage: ChatAnchorContextCoverage(
                olderLocalCount: 40,
                newerLocalCount: 40,
                olderBoundary: .knownGap,
                newerBoundary: .knownGap
            ),
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            archivedId: "fixture-anchor",
            targetWindowIncludesAnchor: true
        )
        XCTAssertNil(completeTargetWindow.olderPageSize)
        XCTAssertNil(completeTargetWindow.newerPageSize)
        XCTAssertFalse(completeTargetWindow.requiresRemoteFetch)
    }

    func testFixtureRemoteHistoryRoutingInterceptsOnlyAnInstalledSyntheticTransport() {
        let action = ChatPerformanceFixtureRemoteHistoryAction(
            kind: .anchorContextPrefetch,
            source: .pushNotification,
            newerPageSize: 86,
            olderPageSize: 85
        )
        XCTAssertTrue(action.requiresRemoteFetch)
        XCTAssertEqual(action.requestedMessageCount, 171)
        XCTAssertTrue(
            ChatPerformanceFixtureRemoteHistoryRoutingPolicy.shouldDispatchProductionTransport(
                requiresRemoteFetch: action.requiresRemoteFetch,
                fixtureDisposition: nil
            ),
            "Production controllers without a fixture transport must keep normal archive paging"
        )
        XCTAssertTrue(
            ChatPerformanceFixtureRemoteHistoryRoutingPolicy.shouldDispatchProductionTransport(
                requiresRemoteFetch: action.requiresRemoteFetch,
                fixtureDisposition: .useProductionTransport
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureRemoteHistoryRoutingPolicy.shouldDispatchProductionTransport(
                requiresRemoteFetch: action.requiresRemoteFetch,
                fixtureDisposition: .consumedByFixtureTransport
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureRemoteHistoryRoutingPolicy.shouldDispatchProductionTransport(
                requiresRemoteFetch: false,
                fixtureDisposition: nil
            ),
            "An already-satisfied context must not dispatch any transport"
        )
    }

    @MainActor
    func testRealPipelineFixtureRetainsSeededRealmAcrossSceneInitializationBoundary() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let inMemoryIdentifier =
            "ChatPerformanceLabTests-scene-boundary-\(UUID().uuidString)"
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: inMemoryIdentifier
        )
        var controller: ChatPerformanceFixtureViewController?
        defer {
            controller = nil
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        autoreleasepool {
            controller = ChatPerformanceFixtureViewController(descriptor: .init(
                scale: .small,
                openScenario: .preloadedLatest
            ))
        }

        let retainedController = try XCTUnwrap(controller)
        let storageDiagnostics = try retainedController.captureOpenScenarioStorageDiagnostics()
        XCTAssertTrue(storageDiagnostics.hasRetainedRealmLease)
        XCTAssertTrue(storageDiagnostics.isEphemeral)
        XCTAssertEqual(storageDiagnostics.messageCount, 320)
        XCTAssertTrue(storageDiagnostics.hasChatRecord)
        XCTAssertTrue(storageDiagnostics.hasArchiveState)
        XCTAssertTrue(storageDiagnostics.hasDurableReadiness)

        let realm = try WRealm.safe()
        XCTAssertEqual(realm.configuration.inMemoryIdentifier, inMemoryIdentifier)
        XCTAssertEqual(
            realm.objects(MessageStorageItem.self).filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                retainedController.owner,
                retainedController.jid,
                retainedController.conversationType.rawValue
            ).count,
            320,
            "The fixture must own an in-memory Realm lease until Scene loads its first frame"
        )

        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: retainedController.jid,
                owner: retainedController.owner,
                conversationType: retainedController.conversationType
            )
        ))
        let archiveState = try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: retainedController.jid,
                owner: retainedController.owner,
                conversationType: retainedController.conversationType
            )
        ))
        XCTAssertTrue(chat.isSynced)
        XCTAssertTrue(chat.isInitialArchiveLoaded)
        XCTAssertTrue(
            ConversationArchiveDurableReadinessPolicy.isReady(
                chat: chat,
                archiveState: archiveState,
                conversationType: retainedController.conversationType,
                localMessageCount: 320
            ),
            "Scene first-frame preparation must observe the durable seeded coverage"
        )
    }

    @MainActor
    func testRemoteSkeletonAcknowledgementBeforeQueryAdmissionDispatchesExactlyOnce() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-early-ack-\(UUID().uuidString)"
        )
        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(
                    token: "00000000-0000-4000-8000-000000000099"
                )
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .bootstrapEmptyToContent,
            externalSkeletonAcknowledgementNotificationName:
                acknowledgementName
        ))
        controller.defersOpenScenarioInitialBootstrapRequestForTesting = true
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            controller.openScenarioDidStabilize = nil
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        window.rootViewController = UINavigationController(
            rootViewController: controller
        )
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()

        XCTAssertTrue(
            waitUntil(timeout: 8) {
                controller
                    .isOpenScenarioExternalSkeletonAcknowledgementArmedForTesting
            },
            "The committed skeleton must arm ACK before query admission"
        )
        XCTAssertEqual(
            controller
                .openScenarioInitialBootstrapRequestInvocationCountForTesting,
            0
        )
        XCTAssertTrue(controller.acknowledgeOpenScenarioSkeletonForTesting())
        XCTAssertFalse(controller.acknowledgeOpenScenarioSkeletonForTesting())
        XCTAssertTrue(
            controller.isOpenScenarioRemoteActionAcknowledgementPendingForTesting
        )
        XCTAssertEqual(
            controller.openScenarioRemoteActionDispatchCountForTesting,
            0
        )

        XCTAssertTrue(
            controller.resumeDeferredOpenScenarioInitialBootstrapRequestForTesting()
        )
        XCTAssertFalse(
            controller.resumeDeferredOpenScenarioInitialBootstrapRequestForTesting()
        )
        XCTAssertTrue(
            waitUntil(timeout: 14) {
                controller.openScenarioStableReceipt != nil
            },
            "The admitted production query must consume the early ACK"
        )
        let receipt = try XCTUnwrap(controller.openScenarioStableReceipt)
        XCTAssertTrue(receipt.isStable)
        XCTAssertEqual(receipt.phase, .content)
        XCTAssertEqual(receipt.visualCommitCount, 1)
        XCTAssertEqual(receipt.firstContentApplyCount, 1)
        XCTAssertEqual(receipt.productionBootstrapLeaseStartCount, 1)
        XCTAssertEqual(receipt.productionBootstrapTransportStartCount, 1)
        XCTAssertEqual(
            controller
                .openScenarioInitialBootstrapRequestInvocationCountForTesting,
            1
        )
        XCTAssertEqual(
            controller.openScenarioRemoteActionDispatchCountForTesting,
            1
        )
        XCTAssertFalse(
            controller.isOpenScenarioRemoteActionAcknowledgementPendingForTesting
        )
        XCTAssertFalse(controller.acknowledgeOpenScenarioSkeletonForTesting())
        XCTAssertEqual(
            controller.openScenarioRemoteActionDispatchCountForTesting,
            1
        )
    }

    @MainActor
    func testE04UnsyncedStaleLocalRowsNeverPublishBeforeTrustedPersistence() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-e04-stale-local-\(UUID().uuidString)"
        )
        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(
                    token: "00000000-0000-4000-8000-000000000104"
                )
        )
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .bootstrapStaleLocalToContent,
            externalSkeletonAcknowledgementNotificationName:
                acknowledgementName
        ))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        XCTAssertTrue(window.windowScene === scene)
        defer {
            controller.openScenarioDidStabilize = nil
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
            previousKeyWindow?.makeKey()
        }

        window.rootViewController = UINavigationController(
            rootViewController: controller
        )
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()

        XCTAssertTrue(
            waitUntil(timeout: 8) {
                controller
                    .isOpenScenarioExternalSkeletonAcknowledgementArmedForTesting
            },
            "E04 must retain its committed skeleton until explicit persistence admission"
        )

        let realm = try WRealm.safe()
        let staleRows = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            controller.owner,
            controller.jid,
            controller.conversationType.rawValue
        )
        XCTAssertEqual(staleRows.count, 320)
        let staleReadState: [[Int]] = Array(
            staleRows.map { [$0.isRead ? 1 : 0, $0.state.rawValue] }
        )
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: controller.jid,
                owner: controller.owner,
                conversationType: controller.conversationType
            )
        ))
        let unreadState = [chat.unread, chat.syncUnreadCount, chat.runtimeUnreadCount]
        XCTAssertFalse(chat.isSynced)
        XCTAssertFalse(chat.isInitialArchiveLoaded)

        var firstHeldSkeletonSample: ChatOpenRealPipelineFixtureDiagnostics?
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                guard let sample = controller
                    .captureOpenScenarioDiagnosticsForTesting(),
                      sample.heldSkeletonDisplayTickCount > 0 else {
                    return false
                }
                firstHeldSkeletonSample = sample
                return true
            },
            "E04 did not expose its held skeleton on a compositor-facing tick"
        )
        var heldSkeletonSamples = [try XCTUnwrap(firstHeldSkeletonSample)]
        for _ in 0..<2 {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.18)
            )
            heldSkeletonSamples.append(try XCTUnwrap(
                controller.captureOpenScenarioDiagnosticsForTesting()
            ))
        }
        let skeletonGeneration = try XCTUnwrap(
            heldSkeletonSamples.first?.initialSkeletonDatasourceGeneration
        )
        for sample in heldSkeletonSamples {
            XCTAssertEqual(sample.phase, .skeleton)
            XCTAssertEqual(sample.initialSkeletonRowCount, 30)
            XCTAssertEqual(sample.currentSkeletonRowCount, 30)
            XCTAssertEqual(sample.realRowCount, 0)
            XCTAssertEqual(sample.datasourceApplyCount, 1)
            XCTAssertEqual(sample.firstContentApplyCount, 0)
            XCTAssertEqual(sample.visualCommitCount, 0)
            XCTAssertEqual(sample.previousOrBlankRealFrameCount, 0)
            XCTAssertEqual(sample.stalePreTerminalRealFrameCount, 0)
            XCTAssertEqual(sample.mixedSkeletonAndRealFrameCount, 0)
            XCTAssertEqual(sample.latestVisualCommitCount, 0)
            XCTAssertGreaterThan(sample.heldSkeletonDisplayTickCount, 0)
            XCTAssertEqual(sample.postCommitOffsetMutationCount, 0)
            XCTAssertEqual(sample.correctionCount, 0)
            XCTAssertFalse(sample.retryVisible)
            XCTAssertTrue(sample.skeletonIdentityStable)
            XCTAssertTrue(sample.skeletonGeometryStable)
            XCTAssertEqual(
                sample.initialSkeletonDatasourceGeneration,
                Optional(skeletonGeneration)
            )
            XCTAssertEqual(
                sample.datasourceGeneration,
                skeletonGeneration,
                "Model-only mapping work must not impersonate a visible skeleton generation change"
            )
            XCTAssertEqual(sample.storage.messageCount, 320)
            XCTAssertFalse(sample.storage.hasDurableReadiness)
            XCTAssertEqual(sample.productionBootstrapLeaseStartCount, 1)
            XCTAssertEqual(sample.productionBootstrapLeaseJoinCount, 0)
            XCTAssertEqual(sample.productionBootstrapActiveLeaseCount, 1)
            XCTAssertEqual(sample.productionBootstrapTransportStartCount, 1)
            XCTAssertEqual(sample.transportThreadSnapshot.mamStartCount, 1)
            XCTAssertEqual(sample.transportThreadSnapshot.archiveEnvelopeCount, 0)
            XCTAssertEqual(sample.transportThreadSnapshot.messageIngressCount, 0)
        }

        XCTAssertEqual(
            Array(staleRows.map { [$0.isRead ? 1 : 0, $0.state.rawValue] }),
            staleReadState,
            "Opening at a blocking skeleton must not emit displayed/read effects"
        )
        XCTAssertEqual(
            [chat.unread, chat.syncUnreadCount, chat.runtimeUnreadCount],
            unreadState,
            "Opening at a blocking skeleton must not mutate unread state"
        )

        XCTAssertTrue(controller.acknowledgeOpenScenarioSkeletonForTesting())
        XCTAssertFalse(controller.acknowledgeOpenScenarioSkeletonForTesting())
        XCTAssertTrue(
            waitUntil(timeout: 14) {
                controller.openScenarioStableReceipt != nil
            },
            "E04 trusted persistence did not publish its atomic latest frame"
        )

        let receipt = try XCTUnwrap(controller.openScenarioStableReceipt)
        XCTAssertTrue(receipt.isStable)
        XCTAssertEqual(receipt.phase, .content)
        XCTAssertEqual(receipt.targetKind, .latest)
        XCTAssertEqual(receipt.initialSkeletonRowCount, 30)
        XCTAssertEqual(receipt.currentSkeletonRowCount, 0)
        XCTAssertEqual(receipt.realRowCount, 80)
        XCTAssertEqual(receipt.datasourceApplyCount, 2)
        XCTAssertEqual(receipt.firstContentApplyCount, 1)
        XCTAssertEqual(receipt.visualCommitCount, 1)
        XCTAssertEqual(receipt.realDatasourceApplyCount, 1)
        XCTAssertEqual(receipt.atomicLayoutCommitCount, 1)
        XCTAssertEqual(receipt.previousOrBlankRealFrameCount, 0)
        XCTAssertEqual(receipt.stalePreTerminalRealFrameCount, 0)
        XCTAssertEqual(receipt.mixedSkeletonAndRealFrameCount, 0)
        XCTAssertEqual(receipt.latestVisualCommitCount, 1)
        XCTAssertGreaterThan(receipt.heldSkeletonDisplayTickCount, 0)
        XCTAssertEqual(receipt.postCommitOffsetMutationCount, 0)
        XCTAssertEqual(receipt.correctionCount, 0)
        XCTAssertLessThanOrEqual(receipt.bottomDistanceMilliPoints ?? .max, 500)
        XCTAssertEqual(receipt.productionBootstrapLeaseStartCount, 1)
        XCTAssertEqual(receipt.productionBootstrapLeaseJoinCount, 0)
        XCTAssertEqual(receipt.productionBootstrapCompletedLeaseCount, 1)
        XCTAssertEqual(receipt.productionBootstrapTransportStartCount, 1)
        XCTAssertEqual(receipt.bootstrapRequestCount, 1)
        XCTAssertEqual(receipt.bootstrapFinalCount, 1)
        XCTAssertEqual(receipt.bootstrapDeliveredMessageCount, 80)
        XCTAssertEqual(receipt.bootstrapPersistedMessageCount, 80)
        XCTAssertTrue(receipt.finalNewerLiveEdgeReached)
        XCTAssertFalse(receipt.finalOlderArchiveEndReached)
        XCTAssertFalse(receipt.finalFullArchiveLoaded)
        XCTAssertEqual(receipt.storeQueryBaselineCount, 0)
        XCTAssertEqual(receipt.storeQueryCount, 4)
        XCTAssertEqual(receipt.storeLifetimeQueryCount, 4)
        XCTAssertEqual(receipt.mainThreadStoreQueryCount, 0)
        XCTAssertEqual(receipt.fullScanCount, 0)
        XCTAssertLessThanOrEqual(receipt.maxCandidateCount, 80)
        XCTAssertEqual(receipt.observerActivationCount, 1)
        XCTAssertGreaterThanOrEqual(receipt.observerRealmQueryCount, 1)
        XCTAssertLessThanOrEqual(receipt.observerRealmQueryCount, 2)
        XCTAssertEqual(receipt.mainThreadObserverRealmQueryCount, 0)
        XCTAssertEqual(
            receipt.observerInitialCallbackCount,
            receipt.observerRealmQueryCount
        )
        XCTAssertEqual(receipt.mainThreadObserverInitialCallbackCount, 0)
        XCTAssertLessThanOrEqual(receipt.observerMaxInitialCandidateCount, 80)
        XCTAssertEqual(receipt.observerMetadataQueryCount, 0)
        XCTAssertEqual(receipt.mainThreadObserverMetadataQueryCount, 0)
        XCTAssertEqual(receipt.observerMetadataFullScanCount, 0)
        XCTAssertEqual(receipt.observerCatchUpMutationCount, 0)
        XCTAssertEqual(receipt.observerPendingWorkCount, 0)
        let routeDiagnostics = try XCTUnwrap(
            controller.captureOpenScenarioRouteStoreDiagnosticsForTesting()
        )
        XCTAssertEqual(routeDiagnostics.queryCount, 4)
        XCTAssertEqual(
            routeDiagnostics.operationCounts,
            ["latestWindow": 2, "unread": 2]
        )
        XCTAssertEqual(receipt.archiveRequestCount, 1)
        XCTAssertEqual(receipt.transportThreadSnapshot.mamStartCount, 1)
        XCTAssertEqual(receipt.transportThreadSnapshot.archiveEnvelopeCount, 80)
        XCTAssertEqual(receipt.transportThreadSnapshot.messageIngressCount, 80)
        XCTAssertGreaterThanOrEqual(
            receipt.transportThreadSnapshot.finalParserCount,
            2
        )
        XCTAssertEqual(receipt.activeProductionWorkCount, 0)

        let finalArchiveState = try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey:
                RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: controller.jid,
                    owner: controller.owner,
                    conversationType: controller.conversationType
                )
        ))
        XCTAssertTrue(finalArchiveState.newerLiveEdgeReached)
        XCTAssertFalse(finalArchiveState.olderArchiveEndReached)
        XCTAssertFalse(chat.fullArchiveLoaded)
        XCTAssertTrue(chat.isInitialArchiveLoaded)
        XCTAssertTrue(chat.isSynced)
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
        XCTAssertTrue(source.contains(
            "fixtureRealmQueryCountAfterRouteAdmission: " +
                "openScenarioFixtureRealmQueryCountAfterRouteAdmission"
        ))
        XCTAssertTrue(try chatPerformanceIntegrationGateSource().contains(
            "fixtureRealmQueriesAfterAdmission="
        ))
    }

    func testRemoteFixtureDoesNotPreAcquireBootstrapCoordinatorOrCallTrustedPageTestHook() throws {
        let source = try chatPerformanceFixtureSource()
        XCTAssertFalse(source.contains("installOpenScenarioCoordinatorIfNeeded"))
        XCTAssertFalse(source.contains("recordCommittedPageForTesting"))
        XCTAssertFalse(try sourceMethod(
            named: "private func injectOpenScenarioRemotePage(",
            in: source
        ).contains("realm.write"))
    }

    func testConfirmedEmptyUsesDurableLocalReadinessWithZeroLeaseTransportAndRequest() throws {
        let plan = ChatOpenRealPipelineFixturePlan(scenario: .confirmedEmpty)
        XCTAssertTrue(plan.expectsConfirmedEmpty)
        XCTAssertFalse(plan.requiresRemoteInjection)
        let source = try chatPerformanceFixtureSource()
        XCTAssertTrue(try sourceMethod(
            named: "private func prepareOpenScenarioRealm(",
            in: source
        ).contains("case .confirmedEmpty:"))
        XCTAssertFalse(try sourceMethod(
            named: "private func configureOpenScenario(",
            in: source
        ).contains("acquireOrJoin"))
    }

    func testFixtureEntersInitialBootstrapCoordinatorOnlyForBlockingRemotePlans() throws {
        let source = try chatPerformanceFixtureSource()
        let configuration = try sourceMethod(
            named: "private func configureOpenScenario(",
            in: source
        )
        let admission = try sourceMethod(
            named: "private func startOpenScenarioInitialBootstrapRequestIfNeeded(",
            in: source
        )

        XCTAssertTrue(configuration.contains("if plan.requiresRemoteInjection"))
        XCTAssertTrue(configuration.contains(
            "startOpenScenarioInitialBootstrapRequestIfNeeded("
        ))
        XCTAssertFalse(configuration.contains("self.requestInitialBootstrapArchive()"))
        XCTAssertTrue(admission.contains("guard plan.requiresRemoteInjection"))
        XCTAssertTrue(admission.contains("requestInitialBootstrapArchive()"))

        let localOrPostInteractionOnly =
            ChatOpenRealPipelineFixtureScenario.allCases.filter {
                !ChatOpenRealPipelineFixturePlan(
                    scenario: $0
                ).requiresRemoteInjection
            }
        XCTAssertFalse(localOrPostInteractionOnly.isEmpty)
        for scenario in localOrPostInteractionOnly {
            XCTAssertFalse(
                ChatOpenRealPipelineFixturePlan(
                    scenario: scenario
                ).requiresRemoteInjection,
                scenario.rawValue
            )
        }
    }

    func testRemoteFixtureResultTraversesMAMIngressSealPersistenceAndCoordinatorCommit() throws {
        let source = try chatPerformanceFixtureSource()
        let delivery = try sourceMethod(
            named: "private func deliverOpenScenarioArchivePage(",
            in: source
        )
        XCTAssertTrue(delivery.contains("recordDeferredArchiveResultDelivery"))
        XCTAssertTrue(delivery.contains("receiveArchived"))
        XCTAssertTrue(delivery.contains("archiveManager.read"))
        XCTAssertFalse(delivery.contains("realm.write"))
        XCTAssertFalse(delivery.contains("recordCommittedPageForTesting"))
    }

    func testRemoteFixtureFinalBeforeLastIngressWaitsAndCommitsExactlyOnce() throws {
        let delivery = try sourceMethod(
            named: "private func deliverOpenScenarioArchivePage(",
            in: chatPerformanceFixtureSource()
        )
        let final = try XCTUnwrap(delivery.range(
            of: "session.archiveManager.read"
        ))
        let lastIngress = try XCTUnwrap(delivery.range(
            of: "session.messageManager.receiveArchived(lastMessage)"
        ))
        XCTAssertLessThan(final.lowerBound, lastIngress.lowerBound)
    }

    func testInteractiveGapFixtureBindsItsExactMAMIngressExpectationBeforeSend()
        throws {
        let dataset = try repositorySource(
            "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
        )
        let requestArm = try sourceMethod(
            named: "private func armRemoteInteractiveHistoryRequest(",
            in: dataset
        )
        let enqueue = try sourceMethod(
            named: "private func enqueueInteractiveRemoteArchiveRequest(",
            in: dataset
        )
        let productionArchiveManager = try XCTUnwrap(enqueue.range(
            of: "archiveManager: account.mam"
        ))
        let productionWireSend = try XCTUnwrap(enqueue.range(
            of: "return send(stream, account.mam)"
        ))
        let fixtureRegistration = try XCTUnwrap(enqueue.range(
            of: "self.registerRemoteHistoryPersistenceSource("
        ))
        let archiveManager = try XCTUnwrap(enqueue.range(
            of: "archiveManager: mam"
        ))
        let wireSend = try XCTUnwrap(enqueue.range(
            of: "return send(stream, mam)"
        ))

        XCTAssertLessThan(
            productionArchiveManager.lowerBound,
            productionWireSend.lowerBound
        )
        XCTAssertLessThan(fixtureRegistration.lowerBound, archiveManager.lowerBound)
        XCTAssertLessThan(archiveManager.lowerBound, wireSend.lowerBound)
        XCTAssertFalse(requestArm.contains(
            "ChatRemoteHistoryCompletionCoordinator.flushQueryMessages("
        ))
        XCTAssertTrue(requestArm.contains(
            "ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync("
        ))
    }

    func testKnownGapBackgroundContextDescriptorsRemainGapEvidence() throws {
        let transportStart = try sourceMethod(
            named: "private func applyOpenScenarioArchiveTransportStart(",
            in: chatPerformanceFixtureSource()
        )
        let backgroundStart = try XCTUnwrap(transportStart.range(
            of: "case .backgroundContext:"
        ))
        let backgroundEnd = try XCTUnwrap(transportStart.range(
            of: "case .unreadBoundary",
            range: backgroundStart.upperBound..<transportStart.endIndex
        ))
        let backgroundContext = transportStart[
            backgroundStart.lowerBound..<backgroundEnd.lowerBound
        ]

        XCTAssertTrue(backgroundContext.contains("if plan.hasKnownGapTopology"))
        XCTAssertTrue(backgroundContext.contains("openScenarioGapRequestCount &+= 1"))
        XCTAssertTrue(backgroundContext.contains(
            "openScenarioObservedProductionGapQueryIds.insert(queryId)"
        ))
    }

    func testInteractiveGapRefetchLimitUsesOnlyQueryLocalVisibleRows() {
        XCTAssertEqual(
            ChatInteractiveRemoteHistoryRefetchLimitPolicy.limit(
                coverageUpdateKind: .gapRepairOlder(
                    cursorArchiveId: "newer-gap-boundary"
                ),
                visibleRowsForConversation: 80
            ),
            80
        )
        XCTAssertEqual(
            ChatInteractiveRemoteHistoryRefetchLimitPolicy.limit(
                coverageUpdateKind: .gapRepairNewer(
                    cursorArchiveId: "older-gap-boundary"
                ),
                visibleRowsForConversation: 80
            ),
            80
        )
        XCTAssertEqual(
            ChatInteractiveRemoteHistoryRefetchLimitPolicy.limit(
                coverageUpdateKind: .gapRepairOlder(
                    cursorArchiveId: "empty-gap-boundary"
                ),
                visibleRowsForConversation: 0
            ),
            0,
            "An empty gap result must not stitch a disjoint local range"
        )
        XCTAssertNil(
            ChatInteractiveRemoteHistoryRefetchLimitPolicy.limit(
                coverageUpdateKind: .pageOlder(
                    cursorArchiveId: "ordinary-page-boundary"
                ),
                visibleRowsForConversation: 80
            ),
            "Ordinary paging retains the session's existing refetch policy"
        )
    }

    func testRemoteFixtureDuplicateFinalCannotDuplicatePersistenceOrPresentation() throws {
        let delivery = try sourceMethod(
            named: "private func deliverOpenScenarioArchivePage(",
            in: chatPerformanceFixtureSource()
        )
        XCTAssertTrue(delivery.contains("deliverDuplicateFinalForIdempotencyProof"))
        let terminal = try sourceMethod(
            named: "private func observeOpenScenarioTerminal(",
            in: chatPerformanceFixtureSource()
        )
        XCTAssertTrue(terminal.contains("initialFirstContentApplyCount == 1"))
        XCTAssertTrue(terminal.contains("openScenarioProductionVisualCommitCount == 1"))
    }

    func testDetachedGapFixtureUsesActualPageRequestDescriptorAndPersistenceTransaction() throws {
        let archiveAction = try sourceMethod(
            named: "private func performArchiveAction(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(archiveAction.contains(
            "performanceFixtureArchiveTransportProvider"
        ))
        XCTAssertTrue(archiveAction.contains(
            "detachedPersistenceTransaction.registerPersistenceSource"
        ))
        XCTAssertTrue(archiveAction.contains("action(session.stream"))
        XCTAssertTrue(archiveAction.contains(
            "performanceFixtureArchiveTransportDidStartHandler"
        ))
    }

    func testFixtureArchiveDescriptorIsDerivedFromCanonicalMAMPlan() throws {
        let exactPlan = MessageArchiveManager.regularExactAnchorRequestPlan(
            jid: "descriptor-peer@invalid",
            archivedId: "anchor-42"
        )
        let exact = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: exactPlan,
                leasePurpose: .anchorTransaction,
                requestSource: .search,
                semanticRouteClass: .exactTarget
            )
        )
        XCTAssertEqual(exact.requestKind, .exactAnchor)
        XCTAssertEqual(exact.archivePurpose, .jump)
        XCTAssertEqual(exact.leasePurpose, .anchorTransaction)
        XCTAssertEqual(exact.cursorKind, .aroundTarget)
        XCTAssertEqual(exact.targetArchiveID, "anchor-42")
        XCTAssertEqual(exact.maximumResultCount, 1)
        XCTAssertEqual(exact.requestSource, .search)
        XCTAssertEqual(exact.semanticRouteClass, .exactTarget)

        let olderPlan = MessageArchiveManager.regularOlderRequestPlan(
            jid: "descriptor-peer@invalid",
            oldestLoadedArchiveId: "anchor-42",
            pageSize: 40
        )
        let older = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: olderPlan,
                leasePurpose: .anchorTransaction,
                requestSource: .search,
                semanticRouteClass: .anchorContext
            )
        )
        XCTAssertEqual(older.requestKind, .older)
        XCTAssertEqual(older.archivePurpose, .pageOlder)
        XCTAssertEqual(older.direction, .older)
        XCTAssertEqual(older.cursorKind, .before)
        XCTAssertEqual(older.cursorArchiveID, "anchor-42")
        XCTAssertEqual(older.maximumResultCount, 40)

        let latestPlan = MessageArchiveManager.regularBootstrapRequestPlan(
            jid: "descriptor-peer@invalid",
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            target: .latest
        )
        let latest = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: latestPlan,
                leasePurpose: .initialBootstrap,
                requestSource: nil,
                semanticRouteClass: .latest
            )
        )
        XCTAssertEqual(latest.requestKind, .bootstrap)
        XCTAssertEqual(latest.archivePurpose, .bootstrap)
        XCTAssertEqual(latest.cursorKind, .latest)
        XCTAssertEqual(latest.maximumResultCount, 80)
    }

    func testInteractiveGapDescriptorRejectsSwappedDirectionCursorAndCursorKind() throws {
        let olderCursor = "newer-range-oldest"
        let newerCursor = "older-range-newest"
        let older = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: MessageArchiveManager.regularGapRepairRequestPlan(
                    jid: "descriptor-peer@invalid",
                    gap: RegularChatArchiveGap(
                        olderRangeNewestArchiveId: newerCursor,
                        newerRangeOldestArchiveId: olderCursor
                    ),
                    direction: .older,
                    pageSize: ChatHistoryPagingConfiguration.pageSize
                ),
                leasePurpose: .interactivePaging,
                requestSource: nil,
                semanticRouteClass: .knownGapRepair
            )
        )
        XCTAssertTrue(
            ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy.accepts(
                descriptor: older,
                expectedDirection: .older,
                expectedCursorArchiveID: olderCursor,
                expectedPageSize: ChatHistoryPagingConfiguration.pageSize
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy.accepts(
                descriptor: older,
                expectedDirection: .newer,
                expectedCursorArchiveID: newerCursor,
                expectedPageSize: ChatHistoryPagingConfiguration.pageSize
            )
        )

        let wrongCursor = ChatPerformanceFixtureArchiveRequestDescriptor(
            requestKind: older.requestKind,
            archivePurpose: older.archivePurpose,
            leasePurpose: older.leasePurpose,
            direction: older.direction,
            cursorKind: older.cursorKind,
            cursorArchiveID: newerCursor,
            targetArchiveID: older.targetArchiveID,
            maximumResultCount: older.maximumResultCount,
            requestSource: older.requestSource,
            semanticRouteClass: older.semanticRouteClass
        )
        let wrongCursorKind = ChatPerformanceFixtureArchiveRequestDescriptor(
            requestKind: older.requestKind,
            archivePurpose: older.archivePurpose,
            leasePurpose: older.leasePurpose,
            direction: older.direction,
            cursorKind: .after,
            cursorArchiveID: older.cursorArchiveID,
            targetArchiveID: older.targetArchiveID,
            maximumResultCount: older.maximumResultCount,
            requestSource: older.requestSource,
            semanticRouteClass: older.semanticRouteClass
        )
        [wrongCursor, wrongCursorKind].forEach {
            XCTAssertFalse(
                ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy
                    .accepts(
                        descriptor: $0,
                        expectedDirection: .older,
                        expectedCursorArchiveID: olderCursor,
                        expectedPageSize:
                            ChatHistoryPagingConfiguration.pageSize
                    )
            )
        }
    }

    func testInteractiveGapDescriptorRejectsMissingOrEmptyExpectedCursor() throws {
        let exactCursor = "newer-range-oldest"
        let descriptor = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: MessageArchiveManager.regularGapRepairRequestPlan(
                    jid: "descriptor-peer@invalid",
                    gap: RegularChatArchiveGap(
                        olderRangeNewestArchiveId: "older-range-newest",
                        newerRangeOldestArchiveId: exactCursor
                    ),
                    direction: .older,
                    pageSize: ChatHistoryPagingConfiguration.pageSize
                ),
                leasePurpose: .interactivePaging,
                requestSource: nil,
                semanticRouteClass: .knownGapRepair
            )
        )

        XCTAssertFalse(
            ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy
                .accepts(
                    descriptor: descriptor,
                    expectedDirection: .older,
                    expectedCursorArchiveID: nil,
                    expectedPageSize:
                        ChatHistoryPagingConfiguration.pageSize
                )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy
                .accepts(
                    descriptor: descriptor,
                    expectedDirection: .older,
                    expectedCursorArchiveID: "",
                    expectedPageSize:
                        ChatHistoryPagingConfiguration.pageSize
                )
        )
        XCTAssertTrue(
            ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy
                .accepts(
                    descriptor: descriptor,
                    expectedDirection: .older,
                    expectedCursorArchiveID: exactCursor,
                    expectedPageSize:
                        ChatHistoryPagingConfiguration.pageSize
                )
        )
    }

    func testFixtureArchivePayloadAdmissionFailsClosedForDescriptorMismatch() throws {
        let exact = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: MessageArchiveManager.regularExactAnchorRequestPlan(
                    jid: "descriptor-peer@invalid",
                    archivedId: "anchor-42"
                ),
                leasePurpose: .anchorTransaction,
                requestSource: .pushNotification,
                semanticRouteClass: .exactTarget
            )
        )
        XCTAssertTrue(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: exact,
                deliveredArchiveIDs: ["anchor-42"],
                firstArchiveID: "anchor-42",
                lastArchiveID: "anchor-42",
                expectedSource: .pushNotification,
                expectedSemanticRouteClass: .exactTarget
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: exact,
                deliveredArchiveIDs: ["wrong-anchor"],
                firstArchiveID: "wrong-anchor",
                lastArchiveID: "wrong-anchor",
                expectedSource: .pushNotification,
                expectedSemanticRouteClass: .exactTarget
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: exact,
                deliveredArchiveIDs: ["anchor-42", "extra"],
                firstArchiveID: "anchor-42",
                lastArchiveID: "extra",
                expectedSource: .pushNotification,
                expectedSemanticRouteClass: .exactTarget
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: exact,
                deliveredArchiveIDs: ["anchor-42"],
                firstArchiveID: "anchor-42",
                lastArchiveID: "anchor-42",
                expectedSource: .search,
                expectedSemanticRouteClass: .exactTarget
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: exact,
                deliveredArchiveIDs: ["anchor-42"],
                firstArchiveID: "anchor-42",
                lastArchiveID: "anchor-42",
                expectedSource: .pushNotification,
                expectedSemanticRouteClass: .latest
            )
        )
    }

    func testTargetWindowContextRejectsWrongCursorDirectionLimitAndAdjacency() throws {
        let targetArchiveID = "anchor-160"
        let older = try XCTUnwrap(
            ChatPerformanceFixtureArchiveRequestDescriptor.make(
                plan: MessageArchiveManager.regularOlderRequestPlan(
                    jid: "descriptor-peer@invalid",
                    oldestLoadedArchiveId: targetArchiveID,
                    pageSize: 40
                ),
                leasePurpose: .anchorTransaction,
                requestSource: .pushNotification,
                semanticRouteClass: .anchorContext
            )
        )
        XCTAssertTrue(
            ChatPerformanceFixtureTargetWindowDescriptorAdmissionPolicy.accepts(
                descriptor: older,
                targetArchiveID: targetArchiveID,
                targetOrdinal: 160,
                totalMessageCount: 320
            )
        )
        let wrongCursor = ChatPerformanceFixtureArchiveRequestDescriptor(
            requestKind: older.requestKind,
            archivePurpose: older.archivePurpose,
            leasePurpose: older.leasePurpose,
            direction: older.direction,
            cursorKind: older.cursorKind,
            cursorArchiveID: "anchor-159",
            targetArchiveID: older.targetArchiveID,
            maximumResultCount: older.maximumResultCount,
            requestSource: older.requestSource,
            semanticRouteClass: older.semanticRouteClass
        )
        let wrongDirection = ChatPerformanceFixtureArchiveRequestDescriptor(
            requestKind: older.requestKind,
            archivePurpose: older.archivePurpose,
            leasePurpose: older.leasePurpose,
            direction: .newer,
            cursorKind: older.cursorKind,
            cursorArchiveID: older.cursorArchiveID,
            targetArchiveID: older.targetArchiveID,
            maximumResultCount: older.maximumResultCount,
            requestSource: older.requestSource,
            semanticRouteClass: older.semanticRouteClass
        )
        let wrongMaximum = ChatPerformanceFixtureArchiveRequestDescriptor(
            requestKind: older.requestKind,
            archivePurpose: older.archivePurpose,
            leasePurpose: older.leasePurpose,
            direction: older.direction,
            cursorKind: older.cursorKind,
            cursorArchiveID: older.cursorArchiveID,
            targetArchiveID: older.targetArchiveID,
            maximumResultCount: 39,
            requestSource: older.requestSource,
            semanticRouteClass: older.semanticRouteClass
        )
        [wrongCursor, wrongDirection, wrongMaximum].forEach {
            XCTAssertFalse(
                ChatPerformanceFixtureTargetWindowDescriptorAdmissionPolicy.accepts(
                    descriptor: $0,
                    targetArchiveID: targetArchiveID,
                    targetOrdinal: 160,
                    totalMessageCount: 320
                )
            )
        }

        let expectedIDs = (120..<160).map { "anchor-\($0)" }
        XCTAssertTrue(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: older,
                deliveredArchiveIDs: expectedIDs,
                firstArchiveID: expectedIDs.first,
                lastArchiveID: expectedIDs.last,
                expectedSource: .pushNotification,
                expectedSemanticRouteClass: .anchorContext,
                expectedDeliveredArchiveIDs: expectedIDs
            )
        )
        XCTAssertFalse(
            ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
                descriptor: older,
                deliveredArchiveIDs: Array(expectedIDs.dropFirst()) + ["anchor-160"],
                firstArchiveID: "anchor-121",
                lastArchiveID: "anchor-160",
                expectedSource: .pushNotification,
                expectedSemanticRouteClass: .anchorContext,
                expectedDeliveredArchiveIDs: expectedIDs
            )
        )

        XCTAssertEqual(
            ChatPerformanceFixtureTargetWindowDescriptorAdmissionPolicy
                .contextShape(
                    targetOrdinal: 4,
                    totalMessageCount: 320
                ),
            ChatPerformanceFixtureTargetWindowContextShape(
                olderCount: 4,
                newerCount: 75
            )
        )
    }

    func testRemoteExactOpenOwnsOneBoundedTargetWindowBeforeFirstContent() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchModePolicy.mode(
                for: .pushNotification,
                hasLocalMatch: true,
                isSynced: false,
                hasCommittedInitialContent: false
            ),
            .blocking
        )
        let completeWindow = ChatAnchorContextPrefetchPolicy.plan(
            coverage: ChatAnchorContextCoverage(
                olderLocalCount: 40,
                newerLocalCount: 39,
                olderBoundary: .knownGap,
                newerBoundary: .knownGap
            ),
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            archivedId: "anchor-42",
            targetWindowIncludesAnchor: true
        )
        XCTAssertFalse(completeWindow.requiresRemoteFetch)

        let targetOnly = ChatAnchorContextPrefetchPolicy.plan(
            coverage: ChatAnchorContextCoverage(
                olderLocalCount: 0,
                newerLocalCount: 0,
                olderBoundary: .knownGap,
                newerBoundary: .knownGap
            ),
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            archivedId: "anchor-42",
            targetWindowIncludesAnchor: true
        )
        XCTAssertEqual(targetOnly.olderPageSize, 40)
        XCTAssertEqual(targetOnly.newerPageSize, 39)
        XCTAssertEqual(
            (targetOnly.olderPageSize ?? 0) +
                (targetOnly.newerPageSize ?? 0) + 1,
            ChatInitialFirstFrameHistoryConfiguration.pageSize
        )

        let olderTerminal = ChatAnchorContextPrefetchPolicy.plan(
            coverage: ChatAnchorContextCoverage(
                olderLocalCount: 4,
                newerLocalCount: 0,
                olderBoundary: .complete,
                newerBoundary: .knownGap
            ),
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            archivedId: "anchor-42",
            targetWindowIncludesAnchor: true
        )
        XCTAssertNil(olderTerminal.olderPageSize)
        XCTAssertEqual(olderTerminal.newerPageSize, 75)
    }

    func testTargetWindowWaitsForObserverGenerationAndMaterializedSides() {
        XCTAssertFalse(
            ChatAnchorContextMaterializationPolicy.isReady(
                snapshotGeneration: 7,
                baselineGeneration: 7,
                targetIsMaterialized: true,
                olderLocalCount: 40,
                newerLocalCount: 39,
                requiredOlderLocalCount: 40,
                requiredNewerLocalCount: 39,
                olderBoundary: .knownGap,
                newerBoundary: .knownGap,
                persistedMessageCount: 79
            )
        )
        XCTAssertFalse(
            ChatAnchorContextMaterializationPolicy.isReady(
                snapshotGeneration: 8,
                baselineGeneration: 7,
                targetIsMaterialized: true,
                olderLocalCount: 40,
                newerLocalCount: 0,
                requiredOlderLocalCount: 40,
                requiredNewerLocalCount: 39,
                olderBoundary: .knownGap,
                newerBoundary: .knownGap,
                persistedMessageCount: 79
            )
        )
        XCTAssertTrue(
            ChatAnchorContextMaterializationPolicy.isReady(
                snapshotGeneration: 8,
                baselineGeneration: 7,
                targetIsMaterialized: true,
                olderLocalCount: 40,
                newerLocalCount: 39,
                requiredOlderLocalCount: 40,
                requiredNewerLocalCount: 39,
                olderBoundary: .knownGap,
                newerBoundary: .knownGap,
                persistedMessageCount: 79
            )
        )
        XCTAssertTrue(
            ChatAnchorContextMaterializationPolicy.isReady(
                snapshotGeneration: 8,
                baselineGeneration: 7,
                targetIsMaterialized: true,
                olderLocalCount: 4,
                newerLocalCount: 75,
                requiredOlderLocalCount: 40,
                requiredNewerLocalCount: 75,
                olderBoundary: .complete,
                newerBoundary: .knownGap,
                persistedMessageCount: 75
            )
        )
    }

    func testContextPersistenceTerminalCannotSynchronouslyPositionTargetOnlyFrame() throws {
        let handler = try sourceMethod(
            named: "private func handleAnchorContextPrefetchEndPageIfNeeded(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(handler.contains("hasMaterializedExpectedContext"))
        XCTAssertTrue(handler.contains("state.persistedMessageCount"))
        XCTAssertFalse(handler.contains("delay: 0.08"))
        let waitRange = try XCTUnwrap(handler.range(of: "case .waitForObserverSync:"))
        let completeRange = try XCTUnwrap(handler.range(of: "case .complete:"))
        let waitingSource = String(handler[waitRange.lowerBound..<completeRange.lowerBound])
        XCTAssertFalse(waitingSource.contains("resumeAnchorExecutionIfNeeded"))
        let completionSource = String(handler[completeRange.lowerBound...])
        XCTAssertTrue(completionSource.contains("resumeAnchorExecutionIfNeeded"))

        let prepare = try sourceMethod(
            named: "private func prepareContextPrefetchIfNeeded(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(prepare.contains("contextPrefetchSnapshotGenerationAtStart"))
        XCTAssertTrue(prepare.contains("hasMaterializedExpectedContext"))
        XCTAssertTrue(prepare.contains("return true"))

        let transition = try sourceMethod(
            named: "private func beginBootstrapAnchorContentTransitionIfNeeded(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(transition.contains("setSkeletonVisible(false)"))
    }

    func testRemoteExactObserverBarrierIgnoresServerCardinalityAndRequiresNewerSnapshot() {
        XCTAssertTrue(
            ChatAnchorRemoteObserverBarrierPolicy.shouldWaitForNewerSnapshot(
                persistedMessageCount: 1,
                baselineGeneration: 7,
                observedGeneration: 7
            )
        )
        XCTAssertFalse(
            ChatAnchorRemoteObserverBarrierPolicy.shouldWaitForNewerSnapshot(
                persistedMessageCount: 1,
                baselineGeneration: 7,
                observedGeneration: 8
            )
        )
        XCTAssertFalse(
            ChatAnchorRemoteObserverBarrierPolicy.shouldWaitForNewerSnapshot(
                persistedMessageCount: 0,
                baselineGeneration: 7,
                observedGeneration: 7
            )
        )
        XCTAssertFalse(
            ChatAnchorRemoteObserverBarrierPolicy.shouldWaitForNewerSnapshot(
                persistedMessageCount: 1,
                baselineGeneration: nil,
                observedGeneration: 7
            )
        )
    }

    func testRemoteExactTerminalUsesNoCardinalityOrDelayedRetry() throws {
        let handler = try sourceMethod(
            named: "private func handleAnchorRemoteFetchEndPageIfNeeded(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(handler.contains("remoteFetchSnapshotGenerationAtStart"))
        XCTAssertTrue(handler.contains("ChatAnchorRemoteObserverBarrierPolicy"))
        XCTAssertFalse(handler.contains("remoteResultCount"))
        XCTAssertFalse(handler.contains("scheduleAnchorObserverResumeIfNeeded"))
        XCTAssertFalse(handler.contains("asyncAfter"))
        XCTAssertFalse(handler.contains("0.08"))
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
    func testRemoteExactPersistenceWaitsForNewerMaterializedObserverAndIgnoresDuplicate() throws {
        let owner = "materialization-owner@example.test"
        let jid = "materialization-peer@example.test"
        let conversationType =
            ClientSynchronizationManager.ConversationType.regular
        let messages = (120..<200).map { ordinal -> MessageStorageItem in
            let message = MessageStorageItem()
            message.primary = "materialization-primary-\(ordinal)"
            message.owner = owner
            message.opponent = jid
            message.conversationType = conversationType
            message.archivedId = String(2_100_000_000_000_000 + ordinal)
            message.messageId = "materialization-message-\(ordinal)"
            message.date = Date(
                timeIntervalSince1970: TimeInterval(12_000 + ordinal)
            )
            message.sentDate = message.date
            message.body = "materialized context row \(ordinal)"
            message.outgoing = false
            message.isRead = true
            message.state = .read
            return message
        }
        let target = messages[40]
        let store = ChatMaterializationBarrierStore(messages: [])
        let conversationKey = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: conversationKey,
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
            ),
            observesStoreImmediately: false
        )
        let baseline = session.openLatest(
            limit: ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertEqual(baseline.generation, 1)
        XCTAssertTrue(baseline.items.isEmpty)

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        controller.cancelDatasetMappingJobs()
        controller.timelineSession?.deactivateStoreObservation()
        controller.timelineSession = session
        controller.cancelPendingArchiveObserverRefresh(
            reason: "materializationTestInstall"
        )
        controller.observerRefreshGenerationCoalescer =
            ChatObserverRefreshGenerationCoalescer()
        controller.datasource = []
        controller.datasourceSnapshot = .empty
        controller.initialLocalFirstFramePhase = .idle
        controller.initialFirstContentApplyCount = 0
        controller.hasCommittedRealContentInCurrentLifecycle = false
        controller.hasCommittedTimelinePresentationInCurrentLifecycle = false
        controller.showSkeletonObserver.accept(true)
        controller.messagesCollectionView.reloadData()
        controller.messagesCollectionView.layoutIfNeeded()
        controller.scrollFrameOperationCounter.setEnabled(true)
        controller.scrollFrameOperationCounter.reset()
        defer {
            controller.datasourceDidSetForTests = nil
            session.deactivateStoreObservation()
            controller.performTerminalChatResourceTeardownForTesting()
        }

        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: target.primary,
                archivedId: target.archivedId,
                messageId: target.messageId,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: target.date
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .pushNotification
        )
        let queryId = "remote-exact-cardinality-terminal"
        var state = ChatAnchorExecutionState(
            request: request,
            usesBootstrapLoading: true
        )
        state.lastAttemptedRemotePlan = .exactArchivedId(target.archivedId)
        state.remoteQueryId = queryId
        state.remoteFetchSnapshotGenerationAtStart = baseline.generation
        state.isRemoteFetchInFlight = true
        controller.pendingOpenMessageRequest = request
        controller.activeAnchorExecutionState = state
        _ = controller.anchorTransactionGate.begin(
            token: state.transactionToken,
            requestIdentity: "materialization-barrier"
        )
        XCTAssertTrue(controller.anchorTransactionGate.acquire(
            .query(queryId),
            token: state.transactionToken
        ))
        controller.anchorTransactionTokenByQueryId[queryId] =
            state.transactionToken

        var realDatasourcePublications = 0
        var maximumRealRowCount = 0
        var positioningStartedCount = 0
        var positionedCount = 0
        var materializedStoreChangeSnapshot: ChatTimelineSessionSnapshot?
        controller.datasourceDidSetForTests = { datasource in
            let realCount = datasource.lazy.filter { !$0.isFakeMessage }.count
            guard realCount > 0 else { return }
            realDatasourcePublications += 1
            maximumRealRowCount = max(maximumRealRowCount, realCount)
        }
        let positioned = expectation(
            description: "newer materialized observer snapshot positions once"
        )
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onPositioningStarted: { positioningStartedCount += 1 },
            onFailed: {
                XCTFail("materialized target window must not fail")
                positioned.fulfill()
            },
            onPositioned: {
                positionedCount += 1
                positioned.fulfill()
            }
        )
        session.onSnapshot = { [weak controller, weak session] snapshot in
            let route = {
                guard snapshot.cause == .storeChange,
                      let controller,
                      let session,
                      controller.timelineSession === session else {
                    return
                }
                materializedStoreChangeSnapshot = snapshot
                controller.handleTimelineSessionRefresh(
                    observedGeneration: snapshot.generation
                )
            }
            if Thread.isMainThread {
                route()
            } else {
                DispatchQueue.main.async(execute: route)
            }
        }
        session.activateStoreObservation()

        XCTAssertTrue(
            controller.performanceTestConsumeAnchorRemotePersistenceTerminal(
                queryId: queryId,
                serverResultCardinality: 1_000_000,
                persistedMessageCount: 1
            )
        )
        XCTAssertTrue(controller.isExecutingOpenMessageRequest)
        XCTAssertTrue(controller.isMessageAnchorNavigationInFlight)
        controller.handleTimelineSessionRefresh(
            observedGeneration: baseline.generation
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(session.snapshot.generation, baseline.generation)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            0
        )
        XCTAssertEqual(realDatasourcePublications, 0)
        XCTAssertEqual(positioningStartedCount, 0)
        XCTAssertEqual(positionedCount, 0)
        XCTAssertTrue(
            controller.activeAnchorExecutionState?.isWaitingForObserverSync == true
        )
        XCTAssertNil(controller.activeAnchorExecutionState?.remoteQueryId)
        XCTAssertEqual(
            controller.activeAnchorExecutionState?.lastAttemptedRemotePlan,
            .exactArchivedId(target.archivedId)
        )
        XCTAssertTrue(controller.isExecutingOpenMessageRequest)
        XCTAssertTrue(controller.isMessageAnchorNavigationInFlight)

        store.replaceMessages(messages)
        let contextMutations = messages
            .map {
                ChatIncrementalMessageMutation<MessageStorageItem>.upsert(
                    identity: ChatIncrementalMessageIdentity(message: $0),
                    revision: 1,
                    payload: $0
                )
            }
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: contextMutations,
                enqueuedMutationCount: contextMutations.count
            ),
            refreshUnread: false
        ))
        wait(for: [positioned], timeout: 2)

        XCTAssertGreaterThan(session.snapshot.generation, baseline.generation)
        XCTAssertEqual(positioningStartedCount, 1)
        XCTAssertEqual(positionedCount, 1)
        XCTAssertEqual(realDatasourcePublications, 1)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            1
        )
        XCTAssertLessThanOrEqual(maximumRealRowCount, 80)
        XCTAssertEqual(
            controller.datasource.lazy.filter { !$0.isFakeMessage }.count,
            80
        )
        XCTAssertTrue(controller.datasource.contains {
            $0.primary == target.primary
        })
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertFalse(controller.isExecutingOpenMessageRequest)
        XCTAssertFalse(controller.isMessageAnchorNavigationInFlight)

        let materializedObserverSnapshot = try XCTUnwrap(
            materializedStoreChangeSnapshot
        )
        XCTAssertEqual(materializedObserverSnapshot.cause, .storeChange)
        XCTAssertEqual(
            materializedObserverSnapshot.generation,
            baseline.generation + 1
        )
        let postObserverCommandSnapshot = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: target.primary,
                archivedId: target.archivedId,
                messageId: target.messageId,
                date: target.date
            )
        )
        XCTAssertGreaterThan(
            postObserverCommandSnapshot.generation,
            materializedObserverSnapshot.generation
        )
        session.onSnapshot?(materializedObserverSnapshot)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(positioningStartedCount, 1)
        XCTAssertEqual(positionedCount, 1)
        XCTAssertEqual(realDatasourcePublications, 1)
        XCTAssertEqual(
            controller.scrollFrameOperationCounter.snapshot()[.datasourceApplies],
            1
        )

    }

    @MainActor
    func testCommittedSearchDateWindowUpdatedExistingMaterializesOffResidentTargetWithoutObserverAndReleasesNavigation() {
        let owner = "off-resident-search-owner@example.test"
        let jid = "off-resident-search-peer@example.test"
        let conversationType =
            ClientSynchronizationManager.ConversationType.regular
        let messages = (0..<121).map { ordinal -> MessageStorageItem in
            let message = MessageStorageItem()
            message.primary = "off-resident-search-primary-\(ordinal)"
            message.owner = owner
            message.opponent = jid
            message.conversationType = conversationType
            message.archivedId = String(2_200_000_000_000_000 + ordinal)
            message.messageId = "off-resident-search-message-\(ordinal)"
            message.date = Date(
                timeIntervalSince1970: TimeInterval(24_000 + ordinal)
            )
            message.sentDate = message.date
            message.body = "off-resident search row \(ordinal)"
            message.outgoing = false
            message.isRead = true
            message.state = .read
            return message
        }
        let target = messages[40]
        let store = ChatMaterializationBarrierStore(messages: messages)
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ),
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
            ),
            observesStoreImmediately: false
        )
        let baseline = session.openLatest(
            limit: ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertEqual(baseline.items.count, 80)
        XCTAssertNil(baseline.item(primary: target.primary))

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        controller.cancelDatasetMappingJobs()
        controller.timelineSession?.deactivateStoreObservation()
        controller.timelineSession = session
        controller.cancelPendingArchiveObserverRefresh(
            reason: "offResidentSearchTestInstall"
        )
        controller.observerRefreshGenerationCoalescer =
            ChatObserverRefreshGenerationCoalescer()
        controller.datasource = []
        controller.datasourceSnapshot = .empty
        controller.initialLocalFirstFramePhase = .idle
        controller.showSkeletonObserver.accept(false)
        controller.messagesCollectionView.reloadData()
        controller.messagesCollectionView.layoutIfNeeded()
        defer {
            store.searchResolutionBarrier?.signal()
            store.searchResolutionBarrier = nil
            store.onSearchResolutionStarted = nil
            session.deactivateStoreObservation()
            controller.performTerminalChatResourceTeardownForTesting()
        }

        let baselineMapped = expectation(
            description: "latest resident chat content is already committed"
        )
        controller.mapAndApplyTimelineCurrent(
            mode: .fullReload(),
            animated: false,
            invalidateLayout: false,
            completion: { baselineMapped.fulfill() }
        )
        wait(for: [baselineMapped], timeout: 2)
        controller.initialFirstContentApplyCount = 1
        controller.hasCommittedRealContentInCurrentLifecycle = true
        controller.hasCommittedTimelinePresentationInCurrentLifecycle = true
        XCTAssertEqual(
            controller.datasource.lazy.filter { !$0.isFakeMessage }.count,
            80
        )
        XCTAssertFalse(controller.datasource.contains {
            $0.primary == target.primary
        })
        XCTAssertNil(store.observation)

        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: target.archivedId,
                messageId: target.messageId,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: target.date
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
        let queryId = "off-resident-search-date-window"
        var state = ChatAnchorExecutionState(request: request)
        state.lastAttemptedRemotePlan = .dateWindow(
            start: target.date.addingTimeInterval(-1),
            end: target.date.addingTimeInterval(1),
            max: controller.datasourcePageSize
        )
        state.remoteQueryId = queryId
        state.remoteFetchSnapshotGenerationAtStart = baseline.generation
        state.isRemoteFetchInFlight = true
        controller.pendingOpenMessageRequest = request
        controller.activeAnchorExecutionState = state
        _ = controller.anchorTransactionGate.begin(
            token: state.transactionToken,
            requestIdentity: "off-resident-search-date-window"
        )
        XCTAssertTrue(controller.anchorTransactionGate.acquire(
            .query(queryId),
            token: state.transactionToken
        ))
        XCTAssertTrue(controller.anchorTransactionGate.acquire(
            .loader,
            token: state.transactionToken
        ))
        XCTAssertTrue(controller.anchorTransactionGate.acquire(
            .scrollLock,
            token: state.transactionToken
        ))
        controller.anchorTransactionTokenByQueryId[queryId] =
            state.transactionToken
        let terminalWatchdog = DispatchWorkItem {}
        controller.anchorTransactionTimeoutWorkItems[queryId] =
            terminalWatchdog
        controller.searchAnchorNavigationWasScrollEnabled = true
        controller.messagesCollectionView.isScrollEnabled = false
        controller.setLoadingIndicatorVisible(true)
        controller.setDatasourceLoadingEnabled(false)
        controller.syncAnchorExecutionFlags()

        let materializationStarted = expectation(
            description: "bounded off-resident materialization starts"
        )
        let materializationBarrier = DispatchSemaphore(value: 0)
        store.searchResolutionBarrier = materializationBarrier
        store.onSearchResolutionStarted = {
            materializationStarted.fulfill()
        }
        var positioningStartedCount = 0
        var positionedCount = 0
        let positioned = expectation(
            description: "off-resident target is positioned without observer"
        )
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onPositioningStarted: { positioningStartedCount += 1 },
            onFailed: {
                XCTFail("Persisted off-resident search target must materialize")
                positioned.fulfill()
            },
            onPositioned: {
                positionedCount += 1
                positioned.fulfill()
            }
        )

        XCTAssertTrue(
            controller.performanceTestConsumeAnchorRemotePersistenceTerminal(
                queryId: queryId,
                serverResultCardinality: 1_000_000,
                persistedMessageCount: 1
            )
        )
        wait(for: [materializationStarted], timeout: 2)
        XCTAssertTrue(
            controller.activeAnchorExecutionState?
                .isPersistenceMaterializationInFlight == true
        )
        XCTAssertEqual(
            controller.anchorTransactionTokenByQueryId[queryId],
            state.transactionToken
        )
        XCTAssertNotNil(controller.anchorTransactionTimeoutWorkItems[queryId])
        XCTAssertFalse(terminalWatchdog.isCancelled)

        controller.performPendingOpenMessageRequestIfNeeded(
            trigger: .observerRefresh
        )
        XCTAssertEqual(store.searchResolutionInvocationCount, 1)
        XCTAssertTrue(
            controller.activeAnchorExecutionState?
                .isPersistenceMaterializationInFlight == true
        )
        XCTAssertEqual(
            controller.activeAnchorExecutionState?.remoteQueryId,
            queryId
        )

        materializationBarrier.signal()
        wait(for: [positioned], timeout: 3)

        XCTAssertNil(store.observation)
        XCTAssertEqual(store.searchResolutionInvocationCount, 1)
        XCTAssertEqual(store.mainThreadSearchResolutionInvocationCount, 0)
        XCTAssertGreaterThan(session.snapshot.generation, baseline.generation)
        XCTAssertEqual(session.snapshot.cause, .command)
        XCTAssertLessThanOrEqual(session.snapshot.items.count, 80)
        XCTAssertEqual(positioningStartedCount, 1)
        XCTAssertEqual(positionedCount, 1)
        XCTAssertTrue(controller.datasource.contains {
            $0.primary == target.primary
        })
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertFalse(controller.isExecutingOpenMessageRequest)
        XCTAssertFalse(controller.isMessageAnchorNavigationInFlight)
        XCTAssertFalse(controller.showLoadingIndicator.value)
        XCTAssertTrue(controller.messagesCollectionView.isScrollEnabled)
        XCTAssertNil(controller.searchAnchorNavigationWasScrollEnabled)
        XCTAssertNil(controller.anchorTransactionTokenByQueryId[queryId])
        XCTAssertNil(controller.anchorTransactionTimeoutWorkItems[queryId])
        XCTAssertTrue(terminalWatchdog.isCancelled)
        XCTAssertNil(controller.anchorTransactionGate.snapshot.activeToken)
        XCTAssertTrue(controller.anchorTransactionGate.snapshot.queryIds.isEmpty)
        XCTAssertFalse(controller.anchorTransactionGate.snapshot.ownsLoader)
        XCTAssertFalse(controller.anchorTransactionGate.snapshot.ownsScrollLock)
        XCTAssertEqual(
            controller.anchorTransactionGate.snapshot.lastTerminalOutcome,
            .positioned
        )
    }

    func testCommittedResidentExactSearchPrimaryResolvesBeforeTemporarilyStaleStore() {
        let owner = "resident-search-owner@example.test"
        let jid = "resident-search-peer@example.test"
        let target = MessageStorageItem()
        target.primary = "resident-search-primary"
        target.owner = owner
        target.opponent = jid
        target.conversationType = .regular
        target.archivedId = "2200000000000042"
        target.messageId = "resident-search-message"
        target.date = Date(timeIntervalSince1970: 22_042)
        target.sentDate = target.date
        target.body = "resident exact search target"
        target.isRead = true
        target.state = .read

        let store = ChatMaterializationBarrierStore(messages: [target])
        store.forcesSearchResolutionMiss = true
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            observesStoreImmediately: false
        )
        let committed = session.openAround(anchor: ChatTimelineAnchor(
            primary: target.primary,
            archivedId: target.archivedId,
            messageId: target.messageId,
            date: target.date
        ))
        XCTAssertEqual(committed.item(primary: target.primary)?.primary, target.primary)

        let exactPrimary = session.resolvedSearchMessageResolution(anchor:
            ChatMessageAnchorRef(
                messagePrimary: target.primary,
                archivedId: target.archivedId,
                messageId: target.messageId,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: target.date
            )
        )
        XCTAssertEqual(exactPrimary.message?.primary, target.primary)
        XCTAssertEqual(store.searchResolutionInvocationCount, 0)

        let archiveOnly = session.resolvedSearchMessageResolution(anchor:
            ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: target.archivedId,
                messageId: target.messageId,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: target.date
            )
        )
        XCTAssertNil(
            archiveOnly.message,
            "Only globally unique resident primary may bypass a stale store; archive/message ambiguity remains store-owned"
        )
        XCTAssertEqual(store.searchResolutionInvocationCount, 1)
    }

    func testArchiveOnlySearchProofCommitsOffMainAndDrivesPhaseBWithoutSecondResolution() {
        let owner = "archive-only-proof-owner@example.test"
        let jid = "archive-only-proof-peer@example.test"
        let target = MessageStorageItem()
        target.primary = "archive-only-proof-primary"
        target.owner = owner
        target.opponent = jid
        target.conversationType = .regular
        target.archivedId = "2200000000000160"
        target.messageId = "archive-only-proof-message"
        target.date = Date(timeIntervalSince1970: 22_160)
        target.sentDate = target.date
        target.body = "archive-only exact search target"
        target.isRead = true
        target.state = .read

        let store = ChatMaterializationBarrierStore(messages: [target])
        let conversationKey = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: conversationKey,
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            observesStoreImmediately: false
        )
        let archiveOnlyAnchor = ChatMessageAnchorRef(
            messagePrimary: nil,
            archivedId: target.archivedId,
            messageId: nil,
            authorId: nil,
            bodyFingerprint: nil,
            sourceDate: target.date
        )
        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: .regular,
            anchor: archiveOnlyAnchor,
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
        let semanticTarget = ChatTimelineInitialFrameTarget.message(
            ChatTimelineAnchor(
                primary: nil,
                archivedId: target.archivedId,
                messageId: nil,
                date: target.date
            )
        )

        let phaseACommitted = expectation(
            description: "archive-only proof committed off main"
        )
        var phaseAResult:
            ChatTimelinePostBootstrapMappedCommitResult<Bool>?
        XCTAssertEqual(
            session.prepareMapAndCommitPostBootstrapInitialFrame(
                target: semanticTarget,
                searchAnchor: archiveOnlyAnchor,
                limit: ChatInitialFirstFrameHistoryConfiguration.pageSize,
                expectedGeneration: session.snapshot.generation,
                map: { frame in
                    ChatFirstFrameMappedValue(
                        value: frame.snapshot.items.contains {
                            $0.primary == target.primary
                        },
                        mappedOnMainThread: Thread.isMainThread
                    )
                },
                shouldCommit: { _, mapped in
                    mapped.value && !mapped.mappedOnMainThread
                },
                completion: {
                    phaseAResult = $0
                    phaseACommitted.fulfill()
                }
            ),
            .started
        )
        wait(for: [phaseACommitted], timeout: 2)
        guard case .committed(
            let phaseAFrame,
            let phaseASnapshot,
            _
        ) = phaseAResult else {
            return XCTFail("Expected typed archive-only Phase-A commit")
        }
        XCTAssertEqual(
            phaseAFrame.searchResolutionProof,
            .found(primary: target.primary)
        )
        XCTAssertEqual(
            phaseAFrame.alignment,
            .anchor(primary: target.primary, archivedId: target.archivedId)
        )
        XCTAssertEqual(
            phaseASnapshot.item(primary: target.primary)?.primary,
            target.primary
        )
        XCTAssertEqual(store.searchResolutionInvocationCount, 1)
        XCTAssertEqual(store.mainThreadSearchResolutionInvocationCount, 0)

        var executionState = ChatAnchorExecutionState(request: request)
        executionState.persistenceMaterializedWindowGeneration =
            phaseASnapshot.generation
        executionState.persistenceSearchResolutionProof =
            phaseAFrame.searchResolutionProof
        let unrelated = MessageStorageItem()
        unrelated.primary = "archive-only-unrelated-live-primary"
        unrelated.owner = owner
        unrelated.opponent = jid
        unrelated.conversationType = .regular
        unrelated.archivedId = "2200000000000999"
        unrelated.messageId = "archive-only-unrelated-live-message"
        unrelated.date = Date(timeIntervalSince1970: 22_999)
        unrelated.sentDate = unrelated.date
        unrelated.isRead = true
        unrelated.state = .read
        let observationAdvancedSnapshot = session.appendLiveMessage(unrelated)
        XCTAssertGreaterThan(
            observationAdvancedSnapshot.generation,
            phaseASnapshot.generation,
            "An unrelated legal session advance must not invalidate the immutable exact-primary proof"
        )
        let phaseBAdmission = ChatPersistenceMaterializedSearchTargetPolicy
            .phaseBAdmission(
                request: request,
                executionState: executionState,
                snapshot: observationAdvancedSnapshot
            )
        guard case .admitted(let provedPrimary) = phaseBAdmission else {
            return XCTFail("Phase B must admit the generation-bound primary")
        }
        XCTAssertEqual(provedPrimary, target.primary)

        let phaseBCommitted = expectation(
            description: "proved primary Phase-B commit"
        )
        var phaseBResult:
            ChatTimelinePostBootstrapMappedCommitResult<Bool>?
        XCTAssertEqual(
            session.prepareMapAndCommitPostBootstrapInitialFrame(
                target: .message(ChatTimelineAnchor(
                    primary: provedPrimary,
                    archivedId: nil,
                    messageId: nil,
                    date: target.date
                )),
                searchAnchor: nil,
                limit: ChatInitialFirstFrameHistoryConfiguration.pageSize,
                expectedGeneration: observationAdvancedSnapshot.generation,
                map: { frame in
                    ChatFirstFrameMappedValue(
                        value: frame.snapshot.items.contains {
                            $0.primary == provedPrimary
                        },
                        mappedOnMainThread: Thread.isMainThread
                    )
                },
                shouldCommit: { _, mapped in
                    mapped.value && !mapped.mappedOnMainThread
                },
                completion: {
                    phaseBResult = $0
                    phaseBCommitted.fulfill()
                }
            ),
            .started
        )
        wait(for: [phaseBCommitted], timeout: 2)
        guard case .committed(
            let phaseBFrame,
            let phaseBSnapshot,
            _
        ) = phaseBResult else {
            return XCTFail("Expected primary-only Phase-B commit")
        }
        guard case .message(let phaseBTarget) = phaseBFrame.target else {
            return XCTFail("Phase B must materialize a message target")
        }
        XCTAssertEqual(phaseBTarget.primary, target.primary)
        XCTAssertNil(phaseBTarget.archivedId)
        XCTAssertNil(phaseBTarget.messageId)
        XCTAssertEqual(phaseBFrame.searchResolutionProof, .notRequested)
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy.resolvedMessage(
                request: request,
                executionState: executionState,
                snapshot: phaseBSnapshot
            )?.primary,
            target.primary
        )
        XCTAssertEqual(
            store.searchResolutionInvocationCount,
            1,
            "Phase B and its committed-snapshot lookup must reuse Phase-A proof"
        )
        XCTAssertEqual(store.mainThreadSearchResolutionInvocationCount, 0)

        let staleRequest = ChatOpenMessageRequest(
            chatJid: "different-peer@example.test",
            owner: owner,
            conversationType: .regular,
            anchor: archiveOnlyAnchor,
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy.phaseBAdmission(
                request: staleRequest,
                executionState: executionState,
                snapshot: phaseBSnapshot
            ),
            .failed(.targetMissing),
            "A proof is request-bound and cannot authorize a superseding search"
        )

        let missingSession = ChatTimelineSession(
            store: ChatMaterializationBarrierStore(messages: []),
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: conversationKey,
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            observesStoreImmediately: false
        )
        let missingSnapshot = missingSession.appendLiveMessage(unrelated)
        XCTAssertGreaterThanOrEqual(
            missingSnapshot.generation,
            phaseASnapshot.generation
        )
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy.phaseBAdmission(
                request: request,
                executionState: executionState,
                snapshot: missingSnapshot
            ),
            .failed(.targetMissing),
            "A monotonic generation alone cannot admit a vanished proved primary"
        )
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy
                .boundResolutionFailure(
                    request: request,
                    executionState: executionState,
                    snapshot: missingSnapshot
                ),
            .targetMissing
        )

        let deletedTarget = MessageStorageItem()
        deletedTarget.primary = target.primary
        deletedTarget.owner = owner
        deletedTarget.opponent = jid
        deletedTarget.conversationType = .regular
        deletedTarget.archivedId = target.archivedId
        deletedTarget.messageId = target.messageId
        deletedTarget.date = target.date
        deletedTarget.sentDate = target.sentDate
        deletedTarget.isDeleted = true
        let deletedSnapshot = ChatTimelineSessionSnapshot(
            generation: phaseBSnapshot.generation,
            cause: .storeChange,
            items: [deletedTarget],
            state: phaseBSnapshot.state,
            loadingState: phaseBSnapshot.loadingState,
            loadDecision: phaseBSnapshot.loadDecision,
            anchorRestore: phaseBSnapshot.anchorRestore,
            localOlderCandidateCount:
                phaseBSnapshot.localOlderCandidateCount,
            pageSize: phaseBSnapshot.pageSize,
            shortLocalRemainderRemoteFirst:
                phaseBSnapshot.shortLocalRemainderRemoteFirst,
            residentIndex: ChatTimelineResidentIndex(items: [deletedTarget]),
            readBoundary: phaseBSnapshot.readBoundary,
            unreadMetadata: phaseBSnapshot.unreadMetadata,
            residentHardLimit: phaseBSnapshot.residentHardLimit,
            residentChangeSet: nil
        )
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy.phaseBAdmission(
                request: request,
                executionState: executionState,
                snapshot: deletedSnapshot
            ),
            .failed(.targetDeleted),
            "A tombstoned proved primary must fail closed"
        )
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy
                .boundResolutionFailure(
                    request: request,
                    executionState: executionState,
                    snapshot: deletedSnapshot
                ),
            .targetDeleted
        )
    }

    func testArchiveOnlySearchAmbiguityFailsClosedBeforeWindowMapOrCommit() {
        let owner = "archive-only-ambiguous-owner@example.test"
        let jid = "archive-only-ambiguous-peer@example.test"
        let target = MessageStorageItem()
        target.primary = "archive-only-ambiguous-primary"
        target.owner = owner
        target.opponent = jid
        target.conversationType = .regular
        target.archivedId = "2200000000000260"
        target.messageId = "archive-only-ambiguous-message"
        target.date = Date(timeIntervalSince1970: 22_260)
        target.sentDate = target.date
        target.isRead = true
        target.state = .read

        let store = ChatMaterializationBarrierStore(messages: [target])
        store.forcedSearchResolutionFailure = .ambiguous(candidateCount: 2)
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            observesStoreImmediately: false
        )
        let archiveOnlyAnchor = ChatMessageAnchorRef(
            messagePrimary: nil,
            archivedId: target.archivedId,
            messageId: nil,
            authorId: nil,
            bodyFingerprint: nil,
            sourceDate: target.date
        )
        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: .regular,
            anchor: archiveOnlyAnchor,
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
        let completed = expectation(
            description: "archive-only ambiguity returns typed failure"
        )
        var mapInvocationCount = 0
        var result: ChatTimelinePostBootstrapMappedCommitResult<Bool>?
        XCTAssertEqual(
            session.prepareMapAndCommitPostBootstrapInitialFrame(
                target: .message(ChatTimelineAnchor(
                    primary: nil,
                    archivedId: target.archivedId,
                    messageId: nil,
                    date: target.date
                )),
                searchAnchor: archiveOnlyAnchor,
                limit: ChatInitialFirstFrameHistoryConfiguration.pageSize,
                expectedGeneration: session.snapshot.generation,
                map: { _ in
                    mapInvocationCount += 1
                    return ChatFirstFrameMappedValue(
                        value: true,
                        mappedOnMainThread: Thread.isMainThread
                    )
                },
                shouldCommit: { _, _ in true },
                completion: {
                    result = $0
                    completed.fulfill()
                }
            ),
            .started
        )
        wait(for: [completed], timeout: 2)
        guard case .blocked(
            .searchResolutionFailed(.ambiguous(candidateCount: let count))
        ) = result else {
            return XCTFail("Ambiguity must remain a typed terminal failure")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(session.snapshot.generation, 0)
        XCTAssertEqual(mapInvocationCount, 0)
        XCTAssertEqual(store.messageLookupInvocationCount, 0)
        XCTAssertEqual(store.searchResolutionInvocationCount, 1)
        XCTAssertEqual(store.mainThreadSearchResolutionInvocationCount, 0)

        var failedState = ChatAnchorExecutionState(request: request)
        failedState.persistenceMaterializedWindowGeneration = 0
        failedState.persistenceSearchResolutionProof =
            .failed(.ambiguous(candidateCount: 2))
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy.phaseBAdmission(
                request: request,
                executionState: failedState,
                snapshot: session.snapshot
            ),
            .failed(.ambiguous(candidateCount: 2))
        )
        XCTAssertNil(
            ChatPersistenceMaterializedSearchTargetPolicy.resolvedMessage(
                request: request,
                executionState: failedState,
                snapshot: session.snapshot
            ),
            "Typed ambiguity must not be reinterpreted as a looser fallback"
        )
        XCTAssertEqual(
            ChatPersistenceMaterializedSearchTargetPolicy
                .boundResolutionFailure(
                    request: request,
                    executionState: failedState,
                    snapshot: session.snapshot
                ),
            .ambiguous(candidateCount: 2)
        )
    }

    @MainActor
    func testBoundArchiveOnlyProofMissingOnObserverResumeFailsWithoutFallbackOrStoreLookup() {
        let owner = "bound-proof-resume-owner@example.test"
        let jid = "bound-proof-resume-peer@example.test"
        let archivedId = "2200000000000360"
        let provedPrimary = "bound-proof-resume-missing-primary"
        let unrelated = MessageStorageItem()
        unrelated.primary = "bound-proof-resume-unrelated-primary"
        unrelated.owner = owner
        unrelated.opponent = jid
        unrelated.conversationType = .regular
        unrelated.archivedId = "2200000000000998"
        unrelated.messageId = "bound-proof-resume-unrelated-message"
        unrelated.date = Date(timeIntervalSince1970: 23_998)
        unrelated.sentDate = unrelated.date
        unrelated.isRead = true
        unrelated.state = .read

        let store = ChatMaterializationBarrierStore(messages: [unrelated])
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatInitialFirstFrameHistoryConfiguration.pageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            observesStoreImmediately: false
        )
        let resident = session.openLatest(
            limit: ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertNil(resident.item(primary: provedPrimary))

        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: Date(timeIntervalSince1970: 23_360)
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
        var executionState = ChatAnchorExecutionState(request: request)
        executionState.lastAttemptedRemotePlan = .exactArchivedId(archivedId)
        executionState.persistenceMaterializedWindowGeneration =
            resident.generation
        executionState.persistenceSearchResolutionProof =
            .found(primary: provedPrimary)

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.timelineSession = session
        controller.datasource = []
        controller.datasourceSnapshot = .empty
        controller.pendingOpenMessageRequest = request
        controller.activeAnchorExecutionState = executionState
        _ = controller.anchorTransactionGate.begin(
            token: executionState.transactionToken,
            requestIdentity: "bound-proof-observer-resume"
        )
        var failureCallbackCount = 0
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onFailed: { failureCallbackCount += 1 },
            onPositioned: {
                XCTFail("A vanished proved primary cannot position")
            }
        )

        controller.performPendingOpenMessageRequestIfNeeded(
            trigger: .observerRefresh
        )

        XCTAssertEqual(failureCallbackCount, 1)
        XCTAssertEqual(
            controller.anchorTransactionGate.snapshot.lastTerminalOutcome,
            .failed(.targetMissing)
        )
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertTrue(
            controller.anchorTransactionGate.snapshot.queryIds.isEmpty,
            "Bound-proof failure must not admit exact→date-window fallback"
        )
        XCTAssertTrue(controller.anchorTransactionTokenByQueryId.isEmpty)
        XCTAssertEqual(controller.remoteHistoryQueryCoordinator.activeQueryCount, 0)
        XCTAssertEqual(
            store.searchResolutionInvocationCount,
            0,
            "Typed terminal failure must not re-query the semantic store"
        )
    }

    func testRemoteExactBootstrapCannotEmitLatestFirstDescriptor() throws {
        let highPriority = try sourceMethod(
            named: "internal func requestInitialBootstrapArchive(",
            in: chatHighPrioritySource()
        )
        XCTAssertTrue(highPriority.contains(
            "shouldDeferInitialBootstrapArchiveForAnchorTransaction"
        ))
        XCTAssertTrue(highPriority.contains(
            "performPendingOpenMessageRequestIfNeeded"
        ))

        let currentTarget = try sourceMethod(
            named: "internal var currentInitialBootstrapTargetFingerprint:",
            in: chatHighPrioritySource()
        )
        XCTAssertTrue(currentTarget.contains("case .anchor:"))
        XCTAssertTrue(currentTarget.contains("target = .savedPosition("))
        XCTAssertFalse(currentTarget.contains("case .anchor:\n                target = .latest"))

        let blockingContext = try sourceMethod(
            named: "private func prepareContextPrefetchIfNeeded(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(blockingContext.contains("initialFirstFramePageSize"))
        XCTAssertTrue(blockingContext.contains("targetWindowIncludesAnchor: true"))

        let backgroundContext = try sourceMethod(
            named: "private func startBackgroundContextPrefetchIfNeeded(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(backgroundContext.contains("datasourcePageSize"))
        XCTAssertTrue(backgroundContext.contains("targetWindowIncludesAnchor: false"))
    }

    func testFixtureArchiveTransportUsesOneSerialOffMainExecutorAndMainBookkeeping() throws {
        let controller = try chatViewControllerSource()
        XCTAssertTrue(controller.contains(
            "performanceFixtureArchiveTransportExecutor: ((@escaping () -> Void) -> Void)?"
        ))

        let bootstrap = try sourceMethod(
            named: "internal func requestInitialBootstrapArchive(",
            in: chatHighPrioritySource()
        )
        XCTAssertTrue(bootstrap.contains("performanceFixtureArchiveTransportExecutor"))
        XCTAssertTrue(bootstrap.contains("performanceFixtureTransportExecutor {"))
        XCTAssertTrue(bootstrap.contains("startRequest("))
        XCTAssertTrue(bootstrap.contains("DispatchQueue.main.async"))
        XCTAssertTrue(bootstrap.contains(
            "performanceFixtureArchiveTransportDidStartHandler"
        ))

        let detached = try sourceMethod(
            named: "private func performArchiveAction(",
            in: chatSearchBarSource()
        )
        XCTAssertTrue(detached.contains("performanceFixtureArchiveTransportExecutor"))
        XCTAssertTrue(detached.contains("performanceFixtureTransportExecutor {"))
        XCTAssertTrue(detached.contains("action(session.stream"))
        XCTAssertTrue(detached.contains("DispatchQueue.main.async"))

        let fixture = try chatPerformanceFixtureSource()
        XCTAssertTrue(fixture.contains(
            "DispatchQueue(label: \"com.xabber.chat-performance.fixture-archive-transport\""
        ))
        XCTAssertTrue(fixture.contains(
            "performanceFixtureArchiveTransportExecutor = {"
        ))
    }

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

    func testRemoteFixtureBuildsAndDeliversMAMOnlyOnSerialTransportQueue() throws {
        let fixture = try chatPerformanceFixtureSource()
        let injection = try sourceMethod(
            named: "private func injectOpenScenarioRemotePage(",
            in: fixture
        )
        XCTAssertTrue(injection.contains("enqueueOpenScenarioArchiveTransport"))
        XCTAssertFalse(injection.contains("makeOpenScenarioArchivedMessage("))
        XCTAssertFalse(injection.contains("receiveArchived("))
        XCTAssertFalse(injection.contains("archiveManager.read("))

        let delivery = try sourceMethod(
            named: "private func deliverOpenScenarioArchivePage(",
            in: fixture
        )
        XCTAssertTrue(delivery.contains("record(.archiveEnvelope"))
        XCTAssertTrue(delivery.contains("record(.messageIngress"))
        XCTAssertTrue(delivery.contains("record(.finalParser"))
        XCTAssertFalse(delivery.contains("DispatchQueue.main"))

        let terminal = try sourceMethod(
            named: "private func completeOpenScenarioArchiveTransport(",
            in: fixture
        )
        XCTAssertTrue(terminal.contains("DispatchQueue.main.async"))
        XCTAssertTrue(terminal.contains("isCurrent(generation:"))
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

    func testE04DisplayTickAndTerminalAdmissionFailClosedOnSkeletonChurn() throws {
        let fixture = try chatPerformanceFixtureSource()
        let displayTick = try sourceMethod(
            named: "@objc private func sampleOpenScenarioVisibleOffset(",
            in: fixture
        )
        XCTAssertTrue(displayTick.contains(
            "recordOpenScenarioPreTerminalVisualState()"
        ))
        XCTAssertTrue(displayTick.contains(
            "openScenarioHeldSkeletonDisplayTickCount &+= 1"
        ))
        XCTAssertTrue(displayTick.contains(
            "completeOpenScenarioAcknowledgementAfterHeldTickIfReady()"
        ))

        let preTerminalSample = try sourceMethod(
            named: "private func recordOpenScenarioPreTerminalVisualState()",
            in: fixture
        )
        XCTAssertTrue(preTerminalSample.contains(
            "descriptor.openScenario == .bootstrapStaleLocalToContent"
        ))
        XCTAssertTrue(preTerminalSample.contains(
            "openScenarioProductionVisualCommitCount == 0"
        ))
        XCTAssertTrue(preTerminalSample.contains(
            "compareOpenScenarioSkeletonWithBaseline()"
        ))

        let terminalEvaluation = try sourceMethod(
            named: "private func captureOpenScenarioTerminalEvaluation(",
            in: fixture
        )
        XCTAssertTrue(terminalEvaluation.contains(
            "let hasExpectedHeldSkeletonStability ="
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "plan.scenario != .bootstrapStaleLocalToContent ||"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "openScenarioSkeletonIdentityStable &&"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "openScenarioSkeletonGeometryStable"
        ))
        XCTAssertGreaterThanOrEqual(
            terminalEvaluation.components(
                separatedBy: "hasExpectedHeldSkeletonStability"
            ).count - 1,
            2,
            "The E04 stability gate must be declared and consumed by admission"
        )
        XCTAssertTrue(terminalEvaluation.contains(
            "openScenarioHeldSkeletonDisplayTickCount > 0"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "let hasExpectedBootstrapPersistenceProof ="
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "committedDiagnostics?.bootstrapDeliveredMessageCount == 80"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "committedDiagnostics?.bootstrapPersistedMessageCount == 80"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "committedDiagnostics?.finalNewerLiveEdgeReached == true"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "committedDiagnostics?.finalOlderArchiveEndReached == false"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "let hasExpectedE04StoreBounds ="
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "openScenarioRouteStoreDiagnosticsBaseline.queryCount == 0"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "lifetimeRouteDiagnostics?.queryCount == 4"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.queryCount == 4"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.operationCounts ==\n                [\"latestWindow\": 2, \"unread\": 2]"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.mainThreadQueryCount == 0"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.observation.activationCount == 1"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "(terminalRouteDiagnostics?.observation.realmQueryCount ?? 0) >= 1"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "(terminalRouteDiagnostics?.observation.realmQueryCount ?? Int.max) <= 2"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.observation.initialCallbackCount ==\n                terminalRouteDiagnostics?.observation.realmQueryCount"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.observation.catchUpMutationCount == 0"
        ))
        XCTAssertTrue(terminalEvaluation.contains(
            "terminalRouteDiagnostics?.observation.pendingWorkCount == 0"
        ))

        let acknowledgement = try sourceMethod(
            named: "private func acknowledgeOpenScenarioSkeleton()",
            in: fixture
        )
        XCTAssertTrue(acknowledgement.contains(
            "openScenarioE04AcknowledgementAwaitingDisplayTick = true"
        ))
        let dispatch = try sourceMethod(
            named: "private func performOpenScenarioAcknowledgedRemoteActionIfReady()",
            in: fixture
        )
        XCTAssertTrue(dispatch.contains(
            "!openScenarioE04AcknowledgementAwaitingDisplayTick"
        ))
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

    func testOpenVideoSelectorsForwardOnlyClosedContainerBoundArtifacts() throws {
        let source = try chatPerformanceUITestSource()
        let forwarding = try sourceMethod(
            named: "static func forwardedValues(",
            in: source
        )
        XCTAssertTrue(forwarding.contains("signpostPath == nil"))
        XCTAssertTrue(forwarding.contains("markerEventPath == nil"))
        XCTAssertTrue(forwarding.contains("dataContainerPath == nil"))
        XCTAssertTrue(forwarding.contains("isAbsolutePath"))
        XCTAssertTrue(forwarding.contains("parent.path.hasPrefix(containerPrefix)"))
        XCTAssertTrue(forwarding.contains("dataContainerKey: dataContainerPath"))
        XCTAssertFalse(forwarding.contains("isWritableFile"))
        XCTAssertFalse(forwarding.contains("fileExists"))
        XCTAssertFalse(forwarding.contains("resolvingSymlinksInPath"))

        let launch = try sourceMethod(
            named: "private func launch(openScenario: String)",
            in: source
        )
        XCTAssertTrue(launch.contains(
            "ChatPerformanceArtifactEnvironmentForwarding.forwardedValues("
        ))
        XCTAssertTrue(launch.contains("app.launchEnvironment = launchEnvironment"))
    }

    func testCommittedBootstrapEmptyProofOverridesBlockingLiveStateWithoutWeakeningUnprovenZeroPage() {
        XCTAssertEqual(
            ChatInitialBootstrapCommittedPresentationPolicy.loadingState(
                liveLoadingState: .blockingArchive,
                didConfirmEmpty: true
            ),
            .empty
        )
        XCTAssertEqual(
            ChatInitialBootstrapCommittedPresentationPolicy.loadingState(
                liveLoadingState: .blockingArchive,
                didConfirmEmpty: false
            ),
            .blockingArchive
        )
    }

    func testExplicitFixturePagingMayCrossAnOffscreenBoundaryWithoutWeakeningOrdinaryValidation() {
        let context = ChatHistoryPagingBoundaryContext(
            firstRealSection: 0,
            lastRealSection: 79,
            visibleRealSections: [39, 40, 41]
        )
        XCTAssertFalse(
            ChatPendingBoundaryPagingValidationPolicy.shouldProceed(
                visibilityRequirement: .visibleBoundary,
                direction: .older,
                boundaryContext: context
            )
        )
        XCTAssertFalse(
            ChatPendingBoundaryPagingValidationPolicy.shouldProceed(
                visibilityRequirement: .visibleBoundary,
                direction: .newer,
                boundaryContext: context
            )
        )
        XCTAssertTrue(
            ChatPendingBoundaryPagingValidationPolicy.shouldProceed(
                visibilityRequirement: .explicitFixtureAction,
                direction: .older,
                boundaryContext: context
            )
        )
        XCTAssertTrue(
            ChatPendingBoundaryPagingValidationPolicy.shouldProceed(
                visibilityRequirement: .explicitFixtureAction,
                direction: .newer,
                boundaryContext: context
            )
        )
    }

    @MainActor
    func testGapFixturesAdmitExplicitPostInitialActionFromTheirCommittedViewport()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-gap-admission-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
            previousKeyWindow?.makeKey()
        }

        for scenario in [
            ChatOpenRealPipelineFixtureScenario.olderCrossingGap,
            .newerCrossingGap
        ] {
            let controller = ChatPerformanceFixtureViewController(
                descriptor: .init(scale: .small, openScenario: scenario)
            )
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            XCTAssertTrue(window.windowScene === scene)
            window.rootViewController = UINavigationController(
                rootViewController: controller
            )
            window.makeKeyAndVisible()
            defer {
                controller.openScenarioDidStabilize = nil
                controller.performOpenScenarioTerminalResourceTeardown()
                window.isHidden = true
                window.rootViewController = nil
                ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            }
            controller.loadViewIfNeeded()
            XCTAssertTrue(waitUntil(timeout: 8) {
                controller.isOpenScenarioPostInitialInteractionReadyForTesting
            })
            XCTAssertTrue(
                controller.performOpenScenarioPostInitialActionForTesting(),
                "production paging admission rejected \(scenario)"
            )
            XCTAssertTrue(waitUntil(timeout: 14) {
                controller.openScenarioStableReceipt?.isStable == true
            })
            let receipt = try XCTUnwrap(controller.openScenarioStableReceipt)
            XCTAssertEqual(receipt.postInitialInteractionCount, 1)
            let expectedRequestCount =
                scenario == .newerCrossingGap ? 3 : 1
            XCTAssertEqual(receipt.archiveRequestCount, expectedRequestCount)
            XCTAssertEqual(receipt.gapRequestCount, expectedRequestCount)
            XCTAssertEqual(
                receipt.transportThreadSnapshot.mamStartCount,
                scenario == .newerCrossingGap ? 2 : 1
            )
            XCTAssertGreaterThanOrEqual(
                receipt.transportThreadSnapshot.finalParserCount,
                expectedRequestCount * 2
            )
            XCTAssertEqual(receipt.realRowCount, 160)
            XCTAssertLessThanOrEqual(
                receipt.pagingAnchorErrorMilliPoints ?? .max,
                1_000
            )
            XCTAssertEqual(receipt.postCommitOffsetMutationCount, 0)
            XCTAssertEqual(receipt.activeProductionWorkCount, 0)
        }
    }

    @MainActor
    func testHostedNativeRouteFixturesSequentiallyReachStablePresentationInForegroundScene()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-native-route-sequence-\(UUID().uuidString)"
        )
        defer {
            NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        for scenario in [
            ChatOpenRealPipelineFixtureScenario.lastChatsAnimatedPush,
            .coldPushExact,
            .mentionDeletedAdvance,
            .lastChatsSeededMentionExact
        ] {
            let descriptor = ChatPerformanceUITestLaunchDescriptor(
                scale: .small,
                openScenario: scenario
            )
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            var destinationForCleanup:
                ChatPerformanceFixtureViewController?
            var navigationControllerForCleanup:
                UINavigationController?
            defer {
                navigationControllerForCleanup?.delegate = nil
                destinationForCleanup?
                    .performOpenScenarioTerminalResourceTeardown()
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
                ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            }
            let coordinator = AppRootCoordinator(
                window: window,
                appDelegate: nil
            )
            coordinator.startChatPerformanceProductionRouteFixture(
                descriptor: descriptor
            )
            let tabController = try XCTUnwrap(
                window.rootViewController as? XabberTabBarViewController
            )
            let navigationController = try XCTUnwrap(
                tabController.viewControllers?.first as?
                    UINavigationController
            )
            let host = try XCTUnwrap(
                navigationController.viewControllers.first as?
                    ChatPerformanceLastChatsRouteHostViewController
            )
            let destination = try XCTUnwrap(
                host.compactChatDestinationFactory()
                    as? ChatPerformanceFixtureViewController
            )
            let p13SourceHost = scenario == .mentionDeletedAdvance
                ? try XCTUnwrap(
                    (tabController.viewControllers?[2] as?
                        UINavigationController)?.viewControllers.first as?
                        ChatPerformanceMentionNotificationsRouteHostViewController
                )
                : nil
            destinationForCleanup = destination
            navigationControllerForCleanup = navigationController

            window.makeKeyAndVisible()
            if scenario == .mentionDeletedAdvance {
                XCTAssertTrue(waitUntil(timeout: 8) {
                    p13SourceHost?
                        .performanceP13SourceRowVisibleForTesting == true
                })
                XCTAssertTrue(
                    p13SourceHost?.performP13SourceRowTapForTesting() == true
                )
            }
            if scenario == .lastChatsSeededMentionExact {
                XCTAssertTrue(waitUntil(timeout: 8) {
                    host.performanceRouteHostDiagnosticsSnapshot
                        .p14SourceRowVisibleBeforeTap
                }, "P14 source readiness blocker: \(host.performanceP14SourceReadinessBlockerForTesting?.rawValue ?? "none")")
                XCTAssertTrue(host.performP14SourceRowTapForTesting())
            }
            XCTAssertTrue(waitUntil(timeout: 14) {
                destination.openScenarioStableReceipt?.isStable == true
            }, "stable receipt was not published for \(scenario)")
            let receipt = try XCTUnwrap(destination.openScenarioStableReceipt)
            XCTAssertTrue(receipt.routeHost.isAccepted(for: scenario))
            XCTAssertEqual(receipt.activeProductionWorkCount, 0)
            if scenario == .mentionDeletedAdvance {
                assertAcceptedP13HostedReceipt(receipt)
            }
            if scenario == .lastChatsSeededMentionExact {
                assertAcceptedP14HostedReceipt(receipt)
                destination.performOpenScenarioTerminalResourceTeardown()
                XCTAssertTrue(
                    destination.isP14ObserverTeardownCompleteForTesting
                )
                destinationForCleanup = nil
            }
        }
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
    func testP14DidShowBeforeInitialCommitWaitsForFreshUnreadProofBeforeReadVisibleReceipt()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-didshow-before-proof-\(UUID().uuidString)"
        )

        let mappingReached = expectation(
            description: "P14 initial mapping held before native didShow"
        )
        mappingReached.assertForOverFulfill = false
        let releaseInitialMapping = DispatchSemaphore(value: 0)
        let mappingBarrierLock = NSLock()
        var shouldHoldInitialMapping = true
        let initialProofCaptured = expectation(
            description: "P14 initial fresh-unread proof captured"
        )
        initialProofCaptured.assertForOverFulfill = false
        var heldInitialProofWork: (() -> Void)?
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var destinationForCleanup:
            ChatPerformanceFixtureViewController?
        var navigationControllerForCleanup:
            UINavigationController?

        defer {
            releaseInitialMapping.signal()
            if let heldInitialProofWork {
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: heldInitialProofWork
                )
            }
            navigationControllerForCleanup?.delegate = nil
            destinationForCleanup?
                .performOpenScenarioTerminalResourceTeardown()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        )
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as?
                UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        destinationForCleanup = destination
        navigationControllerForCleanup = navigationController

        destination.initialFirstFrameMappingBarrierForTests = {
            mappingBarrierLock.lock()
            let shouldHold = shouldHoldInitialMapping
            shouldHoldInitialMapping = false
            mappingBarrierLock.unlock()
            guard shouldHold else { return }
            mappingReached.fulfill()
            _ = releaseInitialMapping.wait(timeout: .now() + 4)
        }
        destination.p14InitialCommitFreshRealmProofExecutorForTests = { work in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(heldInitialProofWork)
            heldInitialProofWork = work
            initialProofCaptured.fulfill()
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            host.performanceRouteHostDiagnosticsSnapshot
                .p14SourceRowVisibleBeforeTap
        })
        XCTAssertTrue(host.performP14SourceRowTapForTesting())
        wait(for: [mappingReached], timeout: 4)
        XCTAssertTrue(
            waitUntil(timeout: 4) {
                destination.p14NativeDidShowCompletedForTesting
            },
            "native didShow must complete while the initial mapping is held"
        )
        XCTAssertEqual(destination.p14ProductionVisualCommitCountForTesting, 0)
        XCTAssertFalse(
            destination.readVisiblePresentationCoordinator
                .hasPresentationReceipt
        )

        destination.initialFirstFrameMappingBarrierForTests = nil
        releaseInitialMapping.signal()
        wait(for: [initialProofCaptured], timeout: 4)
        XCTAssertTrue(waitUntil(timeout: 4) {
            destination.p14ProductionVisualCommitCountForTesting == 1 &&
                destination.p14MentionDiagnosticsForTesting
                    .readScheduledCount == 1
        })

        let beforeDelayedReconciliation =
            destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(beforeDelayedReconciliation.pendingCandidateCount, 1)
        XCTAssertTrue(beforeDelayedReconciliation.hasReconciliationWorkItem)

        // Pump the existing XCTest wait loop beyond production's 0.25-second
        // delayed reconciliation boundary while the fresh Realm proof remains
        // held. Monotonic elapsed time plus work-item consumption proves the
        // real attempt fired and stayed receipt-gated.
        let holdStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(waitUntil(timeout: 1) {
            ProcessInfo.processInfo.systemUptime >= holdStartedAt + 0.35
        })
        let heldElapsed = ProcessInfo.processInfo.systemUptime - holdStartedAt
        XCTAssertGreaterThanOrEqual(heldElapsed, 0.35)

        let beforeProof = destination.p14MentionDiagnosticsForTesting
        XCTAssertFalse(beforeProof.hasReconciliationWorkItem)
        XCTAssertFalse(destination.p14InitialCommitUnreadProofCompletedForTesting)
        XCTAssertFalse(destination.p14DidIssuePresentationReceiptForTesting)
        XCTAssertFalse(
            destination.readVisiblePresentationCoordinator
                .hasPresentationReceipt
        )
        XCTAssertEqual(beforeProof.readScheduledCount, 1)
        XCTAssertEqual(beforeProof.pendingCandidateCount, 1)
        XCTAssertEqual(beforeProof.readCommittedCount, 0)
        XCTAssertEqual(beforeProof.readSuccessfulFlushCount, 0)
        XCTAssertEqual(beforeProof.inFlightFlushCount, 0)
        XCTAssertEqual(beforeProof.readTerminalSuccessCount, 0)
        XCTAssertEqual(beforeProof.readTerminalFailureCount, 0)
        XCTAssertFalse(beforeProof.unreadAtInitialCommit)
        XCTAssertFalse(beforeProof.readAtTerminal)

        let unreadRealm = try WRealm.safe()
        let unreadNotification = try XCTUnwrap(unreadRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: destination.p14MentionNotificationPrimaryForTesting
        ))
        XCTAssertFalse(
            unreadNotification.isRead,
            "P14 notification must remain unread until successful initial proof"
        )

        let proofWork = try XCTUnwrap(heldInitialProofWork)
        heldInitialProofWork = nil
        DispatchQueue.global(qos: .userInitiated).async(execute: proofWork)

        XCTAssertTrue(
            waitUntil(timeout: 6) {
                let diagnostics = destination.p14MentionDiagnosticsForTesting
                return destination
                    .p14InitialCommitUnreadProofCompletedForTesting &&
                    destination.p14DidIssuePresentationReceiptForTesting &&
                    destination.readVisiblePresentationCoordinator
                        .hasPresentationReceipt &&
                    diagnostics.readScheduledCount == 1 &&
                    diagnostics.readCommittedCount == 1 &&
                    diagnostics.readSuccessfulFlushCount == 1 &&
                    diagnostics.readTerminalSuccessCount == 1 &&
                    diagnostics.readTerminalFailureCount == 0 &&
                    diagnostics.readAtTerminal
            },
            "successful proof must admit exactly one read-visible flush; " +
                "receiptReadiness=\(String(describing: destination.p14ReceiptReadinessDiagnosticsForTesting))"
        )
        let afterProof = destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(afterProof.readScheduledCount, 1)
        XCTAssertEqual(afterProof.pendingCandidateCount, 0)
        XCTAssertEqual(afterProof.inFlightFlushCount, 0)
        XCTAssertEqual(afterProof.readCommittedCount, 1)
        XCTAssertEqual(afterProof.readSuccessfulFlushCount, 1)
        XCTAssertEqual(afterProof.readTerminalSuccessCount, 1)
        XCTAssertEqual(afterProof.readTerminalFailureCount, 0)
        XCTAssertTrue(afterProof.unreadAtInitialCommit)
        XCTAssertTrue(afterProof.readAtTerminal)
        XCTAssertEqual(afterProof.freshRealmMatchCount, 1)
        XCTAssertEqual(afterProof.freshRealmProofFailureCount, 0)

        let readRealm = try WRealm.safe()
        let readNotification = try XCTUnwrap(readRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: destination.p14MentionNotificationPrimaryForTesting
        ))
        XCTAssertTrue(readNotification.isRead)

        destination.p14InitialCommitFreshRealmProofExecutorForTests = nil
        destination.performOpenScenarioTerminalResourceTeardown()
        XCTAssertTrue(destination.isP14ObserverTeardownCompleteForTesting)
        destinationForCleanup = nil
    }

    @MainActor
    func testP14ReadReceiptStableRowStoreChangePreservesCommittedAnchoredFrameWithoutSecondDatasourceApply()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-read-stable-row-\(UUID().uuidString)"
        )

        let initialProofCaptured = expectation(
            description: "P14 initial fresh-unread proof held after first frame"
        )
        initialProofCaptured.assertForOverFulfill = true
        var heldInitialProofWork: (() -> Void)?
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var destinationForCleanup:
            ChatPerformanceFixtureViewController?
        var navigationControllerForCleanup:
            UINavigationController?
        var observedSession: ChatTimelineSession?
        var productionSnapshotHandler:
            ChatTimelineSession.SnapshotHandler?

        defer {
            if let observedSession {
                observedSession.onSnapshot = productionSnapshotHandler
            }
            if let heldInitialProofWork {
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: heldInitialProofWork
                )
            }
            navigationControllerForCleanup?.delegate = nil
            destinationForCleanup?
                .performOpenScenarioTerminalResourceTeardown()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        XCTAssertEqual(plan.expectedDatasourceApplyCount, 1)
        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: plan.scenario
        )
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as?
                UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        destinationForCleanup = destination
        navigationControllerForCleanup = navigationController
        destination.p14InitialCommitFreshRealmProofExecutorForTests = { work in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(heldInitialProofWork)
            heldInitialProofWork = work
            initialProofCaptured.fulfill()
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            host.performanceRouteHostDiagnosticsSnapshot
                .p14SourceRowVisibleBeforeTap
        })
        XCTAssertTrue(host.performP14SourceRowTapForTesting())
        wait(for: [initialProofCaptured], timeout: 8)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                destination.p14NativeDidShowCompletedForTesting &&
                    destination.p14ProductionVisualCommitCountForTesting == 1 &&
                    destination.p14MentionDiagnosticsForTesting
                        .readScheduledCount == 1
            },
            "P14 must commit and realize one anchored frame before read proof"
        )

        let targetPrimary = destination.openScenarioPrimary(
            plan.p14ExplicitMentionOrdinal
        )
        let notificationPrimary =
            destination.p14MentionNotificationPrimaryForTesting
        let session = try XCTUnwrap(destination.timelineSession)
        observedSession = session
        XCTAssertTrue(session.hasActiveStoreObservationForTests)
        XCTAssertTrue(waitUntilObserverIdle(session))

        let beforeSessionSnapshot = session.snapshot
        let beforeTarget = try XCTUnwrap(
            beforeSessionSnapshot.item(primary: targetPrimary)
        )
        XCTAssertFalse(beforeTarget.outgoing)
        XCTAssertFalse(beforeTarget.isRead)
        XCTAssertEqual(beforeTarget.state, .deliver)
        let beforeRichRevisionByPrimary = Dictionary(
            uniqueKeysWithValues: beforeSessionSnapshot.items.map {
                (
                    $0.primary,
                    ChatMessageRichStorageRevision.capture(
                        $0,
                        revealedSensitiveMediaPrimaries: []
                    )
                )
            }
        )
        let beforeGeometry =
            destination.p14TargetGeometrySnapshotForTesting()
        let beforeMappingGeneration = destination.datasetMappingGeneration
        XCTAssertEqual(
            destination.scrollFrameOperationCounter
                .snapshot()[.datasourceApplies],
            1
        )
        let beforeDatasourceTarget = try XCTUnwrap(
            destination.datasource.first { $0.primary == targetPrimary }
        )
        XCTAssertFalse(beforeDatasourceTarget.outgoing)
        XCTAssertFalse(beforeDatasourceTarget.isRead)
        XCTAssertEqual(beforeDatasourceTarget.state, .deliver)
        let unreadRealm = try WRealm.safe()
        XCTAssertFalse(try XCTUnwrap(unreadRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: targetPrimary
        )).isRead)
        XCTAssertFalse(try XCTUnwrap(unreadRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: notificationPrimary
        )).isRead)

        let stableReadStoreChange = expectation(
            description: "Realm observer publishes the stable incoming read transition"
        )
        stableReadStoreChange.assertForOverFulfill = true
        let observedSnapshotLock = NSLock()
        var observedReadSnapshot: ChatTimelineSessionSnapshot?
        var heldProductionReadSnapshots: [ChatTimelineSessionSnapshot] = []
        var isHoldingProductionReadSnapshots = true
        let routeProductionSnapshot = session.onSnapshot
        productionSnapshotHandler = routeProductionSnapshot
        session.onSnapshot = { snapshot in
            var shouldFulfill = false
            var shouldRouteToProduction = true
            if snapshot.cause == .storeChange,
               snapshot.residentChangeSet?.updatedStablePrimaries
                .contains(targetPrimary) == true {
                observedSnapshotLock.lock()
                if isHoldingProductionReadSnapshots {
                    heldProductionReadSnapshots.append(snapshot)
                    shouldRouteToProduction = false
                }
                if observedReadSnapshot == nil {
                    observedReadSnapshot = snapshot
                    shouldFulfill = true
                }
                observedSnapshotLock.unlock()
            }
            if shouldRouteToProduction {
                routeProductionSnapshot?(snapshot)
            }
            if shouldFulfill {
                stableReadStoreChange.fulfill()
            }
        }

        let proofWork = try XCTUnwrap(heldInitialProofWork)
        heldInitialProofWork = nil
        DispatchQueue.global(qos: .userInitiated).async(execute: proofWork)

        XCTAssertTrue(
            waitUntil(timeout: 6) {
                let diagnostics = destination.p14MentionDiagnosticsForTesting
                return destination.p14DidIssuePresentationReceiptForTesting &&
                    destination.readVisiblePresentationCoordinator
                        .hasPresentationReceipt &&
                    diagnostics.readScheduledCount == 1 &&
                    diagnostics.readCommittedCount == 1 &&
                    diagnostics.readSuccessfulFlushCount == 1 &&
                    diagnostics.readTerminalSuccessCount == 1 &&
                    diagnostics.readTerminalFailureCount == 0 &&
                    diagnostics.readAtTerminal
            },
            "read receipt must complete before presentation assimilation is judged"
        )
        wait(for: [stableReadStoreChange], timeout: 6)
        XCTAssertTrue(waitUntilObserverIdle(session))

        observedSnapshotLock.lock()
        let readSnapshot = observedReadSnapshot
        observedSnapshotLock.unlock()
        let observed = try XCTUnwrap(readSnapshot)
        let changeSet = try XCTUnwrap(observed.residentChangeSet)
        XCTAssertEqual(observed.cause, .storeChange)
        XCTAssertGreaterThan(
            observed.generation,
            beforeSessionSnapshot.generation
        )
        XCTAssertEqual(
            observed.items.map(\.primary),
            beforeSessionSnapshot.items.map(\.primary),
            "read-state assimilation is stable-row-only"
        )
        XCTAssertTrue(changeSet.insertedPrimaries.isEmpty)
        XCTAssertTrue(changeSet.deletedPrimaries.isEmpty)
        XCTAssertTrue(changeSet.trimmedPrimaries.isEmpty)
        XCTAssertTrue(changeSet.nonResidentIncomingPrimaries.isEmpty)
        XCTAssertTrue(changeSet.updatedStablePrimaries.contains(targetPrimary))
        XCTAssertFalse(changeSet.updatedStablePrimaries.isEmpty)
        var logicalReadTransitionPrimaries: [String] = []
        for primary in changeSet.updatedStablePrimaries {
            let before = try XCTUnwrap(
                beforeSessionSnapshot.item(primary: primary)
            )
            let after = try XCTUnwrap(observed.item(primary: primary))
            XCTAssertEqual(
                ChatMessageRichStorageRevision.capture(
                    after,
                    revealedSensitiveMediaPrimaries: []
                ),
                beforeRichRevisionByPrimary[primary],
                "the stable transition may change read chrome only"
            )
            let beforeChrome =
                ChatMessageChromeStorageRevision.capture(before)
            let afterChrome =
                ChatMessageChromeStorageRevision.capture(after)
            guard beforeChrome != afterChrome else {
                continue
            }
            logicalReadTransitionPrimaries.append(primary)
            XCTAssertFalse(before.outgoing)
            XCTAssertFalse(after.outgoing)
            XCTAssertFalse(before.isRead)
            XCTAssertEqual(before.state, .deliver)
            XCTAssertTrue(after.isRead)
            XCTAssertEqual(after.state, .read)
        }
        XCTAssertTrue(logicalReadTransitionPrimaries.contains(targetPrimary))
        XCTAssertFalse(logicalReadTransitionPrimaries.isEmpty)

        let readRealm = try WRealm.safe()
        let readMessage = try XCTUnwrap(readRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: targetPrimary
        ))
        XCTAssertTrue(readMessage.isRead)
        XCTAssertEqual(readMessage.state, .read)
        XCTAssertTrue(try XCTUnwrap(readRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: notificationPrimary
        )).isRead)

        let explicitReadUIWorkDrained = expectation(
            description: "explicit read-owned unread UI work drained"
        )
        DispatchQueue.main.async {
            explicitReadUIWorkDrained.fulfill()
        }
        wait(for: [explicitReadUIWorkDrained], timeout: 4)

        observedSnapshotLock.lock()
        isHoldingProductionReadSnapshots = false
        let productionReadSnapshots = heldProductionReadSnapshots
        heldProductionReadSnapshots.removeAll()
        observedSnapshotLock.unlock()
        XCTAssertEqual(
            productionReadSnapshots.count,
            1,
            "the exact stable read frame must be the only held observer-current publication"
        )
        XCTAssertFalse(
            destination.datasource.first(where: {
                $0.primary == targetPrimary
            })?.isRead == true,
            "the datasource must remain pre-read until the held observer frame is routed"
        )

        var observerOwnedUnreadRebuildCount = 0
        var observerOwnedFallbackRealmQueryCount = 0
        var observerOwnedNavigatorRefreshCount = 0
        var observerOwnedNavigatorFrameWriteCount = 0
        var observerOwnedScrollDownFrameWriteCount = 0
        var modelOnlyDecisionDiagnostics: [
            (ChatObserverModelOnlyAssimilationDecision,
             ChatObserverModelOnlyAssimilationRejectionReason?)
        ] = []
        destination.unreadMentionRebuildObserverForTests = {
            XCTAssertTrue(Thread.isMainThread)
            observerOwnedUnreadRebuildCount &+= 1
        }
        destination.unreadMentionFallbackRealmQueryObserverForTests = {
            XCTAssertTrue(Thread.isMainThread)
            observerOwnedFallbackRealmQueryCount &+= 1
        }
        destination.unreadMentionNavigatorRefreshObserverForTests = {
            XCTAssertTrue(Thread.isMainThread)
            observerOwnedNavigatorRefreshCount &+= 1
        }
        destination.unreadMentionNavigatorFrameWriteObserverForTests = {
            XCTAssertTrue(Thread.isMainThread)
            observerOwnedNavigatorFrameWriteCount &+= 1
        }
        destination.scrollDownButtonFrameWriteObserverForTests = {
            XCTAssertTrue(Thread.isMainThread)
            observerOwnedScrollDownFrameWriteCount &+= 1
        }
        destination.observerModelOnlyAssimilationDecisionObserverForTests = {
            decision,
            rejectionReason in
            XCTAssertTrue(Thread.isMainThread)
            modelOnlyDecisionDiagnostics.append((decision, rejectionReason))
        }

        productionReadSnapshots.forEach { routeProductionSnapshot?($0) }
        XCTAssertTrue(
            waitUntil(timeout: 6) {
                destination.datasource.first(where: {
                    $0.primary == targetPrimary
                }).map {
                    $0.isRead && $0.state == .read
                } == true
            },
            "stable observer refresh must install current read state in the datasource"
        )

        destination.unreadMentionRebuildObserverForTests = nil
        destination.unreadMentionFallbackRealmQueryObserverForTests = nil
        destination.unreadMentionNavigatorRefreshObserverForTests = nil
        destination.unreadMentionNavigatorFrameWriteObserverForTests = nil
        destination.scrollDownButtonFrameWriteObserverForTests = nil
        destination.observerModelOnlyAssimilationDecisionObserverForTests = nil
        XCTAssertEqual(
            modelOnlyDecisionDiagnostics.count,
            1,
            "the held stable-read frame must produce exactly one model-only decision"
        )
        let modelOnlyDiagnostic = try XCTUnwrap(
            modelOnlyDecisionDiagnostics.first
        )
        XCTAssertEqual(
            modelOnlyDiagnostic.0,
            .incomingReadOnly(
                changedPrimaries: Set(logicalReadTransitionPrimaries)
            ),
            "the stable read frame must assimilate only its real incoming rows"
        )
        XCTAssertNil(
            modelOnlyDiagnostic.1,
            "causal model-only rejection: \(modelOnlyDiagnostic.1?.rawValue ?? "none")"
        )
        XCTAssertEqual(
            observerOwnedUnreadRebuildCount,
            0,
            "observer-current model-only assimilation must not rebuild unread mentions"
        )
        XCTAssertEqual(
            observerOwnedFallbackRealmQueryCount,
            0,
            "observer-current model-only assimilation must not query Realm for unread fallback"
        )
        XCTAssertEqual(
            observerOwnedNavigatorRefreshCount,
            0,
            "observer-current model-only assimilation must not refresh navigator state"
        )
        XCTAssertEqual(
            observerOwnedNavigatorFrameWriteCount,
            0,
            "observer-current model-only assimilation must not rewrite the navigator frame"
        )
        XCTAssertEqual(
            observerOwnedScrollDownFrameWriteCount,
            0,
            "observer-current model-only assimilation must not rewrite the scroll-down frame"
        )

        let finalDiagnostics = destination.p14MentionDiagnosticsForTesting
        XCTAssertTrue(finalDiagnostics.isAccepted)
        destination.scheduleVisibleUnreadMentionReconciliation(
            notificationPrimaries: [notificationPrimary],
            positionedMessagePrimary: targetPrimary
        )
        XCTAssertEqual(
            destination.readVisiblePresentationCoordinator
                .pendingCandidateCount,
            0,
            "a consumed receipt must reject repeated production reconciliation"
        )
        XCTAssertFalse(
            destination.readVisiblePresentationCoordinator
                .pendingMessagePrimaries.contains(targetPrimary),
            "the read target must not regain viewport-read eligibility"
        )

        let afterGeometry =
            destination.p14TargetGeometrySnapshotForTesting()
        let afterMappingGeneration = destination.datasetMappingGeneration
        XCTAssertEqual(afterGeometry.contentOffset, beforeGeometry.contentOffset)
        XCTAssertEqual(
            afterGeometry.targetLayoutFrame,
            beforeGeometry.targetLayoutFrame
        )
        XCTAssertEqual(
            afterGeometry.targetCellFrame,
            beforeGeometry.targetCellFrame
        )
        XCTAssertEqual(
            destination.scrollFrameOperationCounter
                .snapshot()[.datasourceApplies],
            1,
            "stable incoming read-only store change must not enter " +
                "applyChatDatasource; mappingDelta=\(afterMappingGeneration - beforeMappingGeneration)"
        )

        destination.p14InitialCommitFreshRealmProofExecutorForTests = nil
        destination.performOpenScenarioTerminalResourceTeardown()
        XCTAssertTrue(destination.isP14ObserverTeardownCompleteForTesting)
        destinationForCleanup = nil
    }

    @MainActor
    func testP14FastStackedInitialCommitRealizesTargetBeforeDidShowWithoutGeometryCorrection()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-pre-didshow-geometry-\(UUID().uuidString)"
        )

        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var destinationForCleanup:
            ChatPerformanceFixtureViewController?
        var navigationControllerForCleanup:
            UINavigationController?
        var heldProofRelease: (() -> Void)?

        defer {
            if let heldProofRelease {
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: heldProofRelease
                )
            }
            navigationControllerForCleanup?.delegate = nil
            destinationForCleanup?
                .performOpenScenarioTerminalResourceTeardown()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        )
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as?
                UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        destinationForCleanup = destination
        navigationControllerForCleanup = navigationController

        destination.p14InitialCommitFreshRealmProofExecutorForTests = {
            release in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(heldProofRelease)
            heldProofRelease = release
        }
        var initialCommitGeometry:
            ChatPerformanceP14TargetGeometrySnapshot?
        var nativeDidShowAtInitialCommit: Bool?
        destination.p14InitialFrameCommitRecordedForTests = {
            [weak destination] _ in
            guard let destination,
                  initialCommitGeometry == nil else {
                return
            }
            nativeDidShowAtInitialCommit =
                destination.p14NativeDidShowCompletedForTesting
            initialCommitGeometry =
                destination.p14TargetGeometrySnapshotForTesting()
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            host.performanceRouteHostDiagnosticsSnapshot
                .p14SourceRowVisibleBeforeTap
        })
        XCTAssertTrue(host.performP14SourceRowTapForTesting())
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                initialCommitGeometry != nil
            },
            "the real fast stacked P14 A commit must be observed"
        )

        let initial = try XCTUnwrap(initialCommitGeometry)
        XCTAssertEqual(
            nativeDidShowAtInitialCommit,
            false,
            "A must commit while the destination is still off-screen"
        )
        XCTAssertEqual(
            initial.collectionFrame,
            initial.viewBounds,
            "the off-screen collection must settle against final host bounds; \(initial)"
        )
        XCTAssertGreaterThanOrEqual(initial.collectionFrame.minX, 0)
        XCTAssertGreaterThanOrEqual(initial.collectionFrame.minY, 0)
        XCTAssertTrue(initial.targetPresentInDatasource)
        XCTAssertTrue(initial.targetInVisibleIndexPaths)
        XCTAssertTrue(initial.targetCellExists)
        XCTAssertEqual(
            initial.layoutMeaningfullyVisible,
            true,
            "the target layout must intersect the adjusted read viewport at A; \(initial)"
        )
        XCTAssertEqual(
            initial.cellMeaningfullyVisible,
            true,
            "the realized target cell must be meaningful at A; \(initial)"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(initial.originalViewportRelativeMinY),
            0,
            "centering must not be calculated from a stale zero-height viewport"
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(initial.liveLayoutAnchorError),
            1
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(initial.liveCellAnchorError),
            1
        )

        XCTAssertTrue(
            waitUntil(timeout: 4) {
                destination.p14NativeDidShowCompletedForTesting
            },
            "native didShow must follow the already-valid A commit"
        )
        let didShow = destination.p14TargetGeometrySnapshotForTesting()
        XCTAssertEqual(didShow.collectionFrame, initial.collectionFrame)
        XCTAssertEqual(didShow.contentOffset, initial.contentOffset)
        XCTAssertEqual(didShow.targetLayoutFrame, initial.targetLayoutFrame)
        XCTAssertEqual(didShow.targetCellFrame, initial.targetCellFrame)
        XCTAssertEqual(didShow.layoutMeaningfullyVisible, true)
        XCTAssertEqual(didShow.cellMeaningfullyVisible, true)

        let viewportDiagnostics = try XCTUnwrap(
            destination.p14ViewportDiagnosticsForTesting
        )
        XCTAssertEqual(viewportDiagnostics.finalAlignmentCorrectionCount, 0)
        XCTAssertEqual(viewportDiagnostics.nextRunLoopCorrectionCount, 0)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(viewportDiagnostics.anchorError),
            1
        )
    }

    @MainActor
    func testP14HeldProofRejectsSameDescriptorOldGenerationAndFreshReplacementPublishesOnce()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-effect-token-supersession-\(UUID().uuidString)"
        )

        let proofCaptured = expectation(
            description: "A, B and C each capture an immutable proof release"
        )
        proofCaptured.expectedFulfillmentCount = 3
        proofCaptured.assertForOverFulfill = true
        let proofLock = NSLock()
        var heldProofReleases: [() -> Void] = []
        let queriedBResultCaptured = expectation(
            description: "B Realm result held before main assignment"
        )
        queriedBResultCaptured.assertForOverFulfill = true
        let resultLock = NSLock()
        var heldQueriedBResultRelease: (() -> Void)?
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var destinationForCleanup:
            ChatPerformanceFixtureViewController?
        var navigationControllerForCleanup:
            UINavigationController?

        defer {
            proofLock.lock()
            let unreleasedProofs = heldProofReleases
            heldProofReleases.removeAll()
            proofLock.unlock()
            unreleasedProofs.forEach { release in
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: release
                )
            }
            resultLock.lock()
            let unreleasedResult = heldQueriedBResultRelease
            heldQueriedBResultRelease = nil
            resultLock.unlock()
            if let unreleasedResult {
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: unreleasedResult
                )
            }
            navigationControllerForCleanup?.delegate = nil
            destinationForCleanup?
                .performOpenScenarioTerminalResourceTeardown()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        )
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as?
                UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        destinationForCleanup = destination
        navigationControllerForCleanup = navigationController

        destination.p14InitialCommitFreshRealmProofExecutorForTests = {
            release in
            XCTAssertTrue(Thread.isMainThread)
            proofLock.lock()
            heldProofReleases.append(release)
            proofLock.unlock()
            proofCaptured.fulfill()
        }
        destination.p14FreshRealmProofResultDeliveryExecutorForTests = {
            release in
            resultLock.lock()
            XCTAssertNil(heldQueriedBResultRelease)
            heldQueriedBResultRelease = release
            resultLock.unlock()
            queriedBResultCaptured.fulfill()
        }
        var stablePublicationCount = 0
        destination.openScenarioDidStabilize = { _ in
            stablePublicationCount &+= 1
        }
        var initialCommitGeometry:
            ChatPerformanceP14TargetGeometrySnapshot?
        destination.p14InitialFrameCommitRecordedForTests = {
            [weak destination] _ in
            guard initialCommitGeometry == nil else { return }
            initialCommitGeometry = destination?
                .p14TargetGeometrySnapshotForTesting()
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            host.performanceRouteHostDiagnosticsSnapshot
                .p14SourceRowVisibleBeforeTap
        })
        XCTAssertTrue(host.performP14SourceRowTapForTesting())
        XCTAssertTrue(waitUntil(timeout: 8) {
            proofLock.lock()
            defer { proofLock.unlock() }
            return heldProofReleases.count == 1
        })

        let tokenA = try XCTUnwrap(
            destination.p14InitialFrameCommitEffectTokenForTesting
        )
        XCTAssertTrue(destination.isLatestInitialFrameEffectToken(tokenA))
        XCTAssertEqual(
            destination.p14ProductionVisualCommitCountForTesting,
            1
        )
        let capturedInitialCommitGeometry = try XCTUnwrap(
            initialCommitGeometry
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            destination.p14NativeDidShowCompletedForTesting
        })
        let didShowGeometry =
            destination.p14TargetGeometrySnapshotForTesting()

        let tokenB = ChatInitialFrameEffectToken(
            presentationGeneration: tokenA.presentationGeneration &+ 1,
            sessionIdentifier: tokenA.sessionIdentifier,
            descriptor: tokenA.descriptor,
            anchorTransactionToken: tokenA.anchorTransactionToken
        )
        XCTAssertEqual(tokenB.descriptor, tokenA.descriptor)
        destination.readVisiblePresentationCoordinator.revoke(
            initialFrameEffectToken: tokenA
        )
        destination.initialLocalFirstFramePresentationGeneration =
            tokenB.presentationGeneration
        destination.initialLocalFirstFrameLatestEffectToken = tokenB
        XCTAssertFalse(destination.isLatestInitialFrameEffectToken(tokenA))
        XCTAssertTrue(destination.isLatestInitialFrameEffectToken(tokenB))
        destination.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenB
        )
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        destination.scheduleVisibleUnreadMentionReconciliation(
            notificationPrimaries: [
                destination.p14MentionNotificationPrimaryForTesting
            ],
            positionedMessagePrimary: destination.openScenarioPrimary(
                plan.p14ExplicitMentionOrdinal
            ),
            initialFrameEffectToken: tokenB
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            proofLock.lock()
            defer { proofLock.unlock() }
            return heldProofReleases.count == 2
        })

        proofLock.lock()
        let releaseA = heldProofReleases[0]
        let releaseB = heldProofReleases[1]
        proofLock.unlock()
        let staleARealm = try WRealm.safe()
        let staleAMention = try XCTUnwrap(staleARealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: destination
                .p14MentionNotificationPrimaryForTesting
        ))
        try staleARealm.write { staleAMention.isRead = true }
        let staleAAdmissionDrained = expectation(
            description: "stale A admission closure drained on main"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseA()
            DispatchQueue.main.async {
                staleAAdmissionDrained.fulfill()
            }
        }
        wait(for: [staleAAdmissionDrained], timeout: 4)
        XCTAssertEqual(
            destination.p14FreshRealmProofInFlightCountForTesting,
            1
        )
        XCTAssertFalse(
            destination.p14InitialCommitUnreadProofCompletedForTesting
        )
        XCTAssertFalse(destination.p14DidIssuePresentationReceiptForTesting)
        XCTAssertNil(destination.openScenarioStableReceipt)
        XCTAssertEqual(stablePublicationCount, 0)
        XCTAssertTrue(
            destination.openScenarioStableAccessibilitySummaryForTesting?
                .contains("stable=false receipt=0") == true
        )
        let afterStaleA = destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(afterStaleA.readCommittedCount, 0)
        XCTAssertEqual(afterStaleA.readSuccessfulFlushCount, 0)
        XCTAssertEqual(afterStaleA.readTerminalSuccessCount, 0)
        XCTAssertEqual(afterStaleA.freshRealmProofFailureCount, 0)
        resultLock.lock()
        XCTAssertNil(
            heldQueriedBResultRelease,
            "A's release must never dereference or execute held B work"
        )
        resultLock.unlock()

        try staleARealm.write { staleAMention.isRead = false }

        DispatchQueue.global(qos: .userInitiated).async(execute: releaseB)
        wait(for: [queriedBResultCaptured], timeout: 4)

        let tokenC = ChatInitialFrameEffectToken(
            presentationGeneration: tokenB.presentationGeneration &+ 1,
            sessionIdentifier: tokenB.sessionIdentifier,
            descriptor: tokenB.descriptor,
            anchorTransactionToken: tokenB.anchorTransactionToken
        )
        XCTAssertEqual(tokenC.descriptor, tokenA.descriptor)
        destination.readVisiblePresentationCoordinator.revoke(
            initialFrameEffectToken: tokenB
        )
        destination.initialLocalFirstFramePresentationGeneration =
            tokenC.presentationGeneration
        destination.initialLocalFirstFrameLatestEffectToken = tokenC
        destination.p14FreshRealmProofResultDeliveryExecutorForTests = nil
        destination.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenC
        )
        destination.scheduleVisibleUnreadMentionReconciliation(
            notificationPrimaries: [
                destination.p14MentionNotificationPrimaryForTesting
            ],
            positionedMessagePrimary: destination.openScenarioPrimary(
                plan.p14ExplicitMentionOrdinal
            ),
            initialFrameEffectToken: tokenC
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            proofLock.lock()
            defer { proofLock.unlock() }
            return heldProofReleases.count == 3
        })
        wait(for: [proofCaptured], timeout: 4)
        proofLock.lock()
        let releaseC = heldProofReleases[2]
        proofLock.unlock()

        resultLock.lock()
        let queriedBResultRelease = heldQueriedBResultRelease
        heldQueriedBResultRelease = nil
        resultLock.unlock()
        let releaseQueriedB = try XCTUnwrap(queriedBResultRelease)
        let staleBResultDeliveryDrained = expectation(
            description: "stale queried B result delivery drained on main"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseQueriedB()
            DispatchQueue.main.async {
                staleBResultDeliveryDrained.fulfill()
            }
        }
        wait(for: [staleBResultDeliveryDrained], timeout: 4)
        XCTAssertEqual(
            destination.p14FreshRealmProofInFlightCountForTesting,
            1
        )
        XCTAssertFalse(
            destination.p14InitialCommitUnreadProofCompletedForTesting
        )
        XCTAssertFalse(destination.p14DidIssuePresentationReceiptForTesting)
        XCTAssertNil(destination.openScenarioStableReceipt)
        XCTAssertEqual(stablePublicationCount, 0)
        let afterStaleB = destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(afterStaleB.readCommittedCount, 0)
        XCTAssertEqual(afterStaleB.readSuccessfulFlushCount, 0)
        XCTAssertEqual(afterStaleB.readTerminalSuccessCount, 0)
        XCTAssertEqual(afterStaleB.freshRealmProofFailureCount, 0)

        DispatchQueue.global(qos: .userInitiated).async(execute: releaseC)
        let didReachTerminal = waitUntil(timeout: 10) {
                destination.openScenarioStableReceipt?.isStable == true &&
                    destination.p14DidIssuePresentationReceiptForTesting &&
                    destination.p14MentionDiagnosticsForTesting
                        .readAtTerminal
            }
        let finalGeometry = didReachTerminal
            ? nil
            : destination.p14TargetGeometrySnapshotForTesting()
        XCTAssertTrue(
            didReachTerminal,
            "only C's fresh proof may publish P14 terminal evidence; " +
                "receiptReadiness=\(String(describing: destination.p14ReceiptReadinessDiagnosticsForTesting)); " +
                "geometry[A]=\(capturedInitialCommitGeometry); " +
                "geometry[didShow]=\(didShowGeometry); " +
                "geometry[final]=\(String(describing: finalGeometry))"
        )
        let receipt = try XCTUnwrap(destination.openScenarioStableReceipt)
        XCTAssertEqual(stablePublicationCount, 1)
        XCTAssertEqual(
            destination.openScenarioStableAccessibilitySummaryForTesting,
            receipt.accessibilitySummary
        )
        XCTAssertEqual(
            destination.p14InitialCommitUnreadProofEffectTokenForTesting,
            tokenC
        )
        XCTAssertEqual(
            destination.p14PresentationReceiptEffectTokenForTesting,
            tokenC
        )
        let final = destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(final.readScheduledCount, 1)
        XCTAssertEqual(final.readCommittedCount, 1)
        XCTAssertEqual(final.readSuccessfulFlushCount, 1)
        XCTAssertEqual(final.readTerminalSuccessCount, 1)
        XCTAssertEqual(final.readTerminalFailureCount, 0)
        XCTAssertEqual(final.freshRealmProofFailureCount, 0)
        XCTAssertEqual(destination.p14FreshRealmProofInFlightCountForTesting, 0)

        // All three companion observer boundaries carry the flush owner. An
        // arbitrarily late A callback cannot be relabeled as C evidence.
        destination.visibleMentionReadScheduledEffectTokenForTests?(1, tokenA)
        destination
            .visibleMentionReadAfterFirstPersistentMutationEffectTokenForTests?(
                tokenA
            )
        destination.visibleMentionReadTerminalEffectTokenForTests?(true, tokenA)
        let staleObserverCallbacksDrained = expectation(
            description: "stale A observer callbacks drained on main"
        )
        DispatchQueue.main.async {
            staleObserverCallbacksDrained.fulfill()
        }
        wait(for: [staleObserverCallbacksDrained], timeout: 4)
        let afterLateA = destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(afterLateA.readScheduledCount, 1)
        XCTAssertEqual(afterLateA.readCommittedCount, 1)
        XCTAssertEqual(afterLateA.readTerminalSuccessCount, 1)
        XCTAssertEqual(destination.p14FreshRealmProofInFlightCountForTesting, 0)
        XCTAssertEqual(stablePublicationCount, 1)
    }

    /// Causal integration coverage for the installed Dataset diagnostics
    /// handler. The forced trusted reload is intentionally not treated as a
    /// canonical one-apply terminal run; the normal hosted P14 test above
    /// remains the acceptance proof for exactly-one stable publication.
    @MainActor
    func testP14InstalledHandlerReplacesStoredCommitWithRealDatasetRecommit()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration =
            makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "ChatPerformanceLabTests-p14-real-recommit-\(UUID().uuidString)"
            )

        let diagnosticsCaptured = expectation(
            description: "two real Dataset commit diagnostics"
        )
        diagnosticsCaptured.expectedFulfillmentCount = 2
        diagnosticsCaptured.assertForOverFulfill = true
        let proofCaptured = expectation(
            description: "A and B immutable proof releases"
        )
        proofCaptured.expectedFulfillmentCount = 2
        proofCaptured.assertForOverFulfill = true
        let proofLock = NSLock()
        var heldProofReleases: [() -> Void] = []
        var commitDiagnostics:
            [ChatPerformanceInitialFrameCommitDiagnostics] = []
        var didRequestReplacement = false
        var replacementRequestWasAccepted = false
        let queryLock = NSLock()
        var proofQueryCount = 0
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var destinationForCleanup:
            ChatPerformanceFixtureViewController?
        var navigationControllerForCleanup:
            UINavigationController?

        defer {
            proofLock.lock()
            let unreleasedProofs = heldProofReleases
            heldProofReleases.removeAll()
            proofLock.unlock()
            unreleasedProofs.forEach { release in
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: release
                )
            }
            navigationControllerForCleanup?.delegate = nil
            destinationForCleanup?
                .performOpenScenarioTerminalResourceTeardown()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        )
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as?
                UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        destinationForCleanup = destination
        navigationControllerForCleanup = navigationController

        destination.p14InitialCommitFreshRealmProofExecutorForTests = {
            release in
            XCTAssertTrue(Thread.isMainThread)
            proofLock.lock()
            heldProofReleases.append(release)
            proofLock.unlock()
            proofCaptured.fulfill()
        }
        destination.p14FreshRealmProofQueryObserverForTests = {
            queryLock.lock()
            proofQueryCount &+= 1
            queryLock.unlock()
        }
        destination.p14InitialFrameCommitRecordedForTests = {
            diagnostics in
            XCTAssertTrue(Thread.isMainThread)
            commitDiagnostics.append(diagnostics)
            diagnosticsCaptured.fulfill()
            guard !didRequestReplacement else { return }
            didRequestReplacement = true
            replacementRequestWasAccepted = destination
                .reloadInitialWindowAfterBootstrapIfNeeded(
                    force: true,
                    hasTrustedPersistedBootstrapPage: true
                )
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            host.performanceRouteHostDiagnosticsSnapshot
                .p14SourceRowVisibleBeforeTap
        })
        XCTAssertTrue(host.performP14SourceRowTapForTesting())
        wait(
            for: [diagnosticsCaptured, proofCaptured],
            timeout: 10
        )
        XCTAssertTrue(replacementRequestWasAccepted)

        proofLock.lock()
        let capturedProofReleases = heldProofReleases
        proofLock.unlock()
        XCTAssertEqual(capturedProofReleases.count, 2)
        XCTAssertEqual(commitDiagnostics.count, 2)
        let diagnosticsA = try XCTUnwrap(commitDiagnostics.first)
        let diagnosticsB = try XCTUnwrap(commitDiagnostics.dropFirst().first)
        let tokenA = diagnosticsA.initialFrameEffectToken
        let tokenB = diagnosticsB.initialFrameEffectToken
        XCTAssertEqual(tokenA.descriptor, tokenB.descriptor)
        XCTAssertNotEqual(tokenA, tokenB)
        XCTAssertGreaterThan(
            tokenB.presentationGeneration,
            tokenA.presentationGeneration
        )
        XCTAssertEqual(
            diagnosticsB.realDatasourceApplyCount,
            diagnosticsA.realDatasourceApplyCount + 1,
            "the second token must come from another real Dataset apply"
        )
        XCTAssertFalse(destination.isLatestInitialFrameEffectToken(tokenA))
        XCTAssertTrue(destination.isLatestInitialFrameEffectToken(tokenB))
        XCTAssertEqual(
            destination.p14InitialFrameCommitEffectTokenForTesting,
            tokenB
        )
        XCTAssertEqual(
            destination.openScenarioCommittedInitialFrameDiagnostics,
            diagnosticsB
        )
        XCTAssertEqual(
            destination.p14ViewportDiagnosticsForTesting,
            diagnosticsB.viewportDiagnostics
        )
        XCTAssertEqual(destination.p14ProductionVisualCommitCountForTesting, 1)
        XCTAssertEqual(destination.p14TargetMatchCountForTesting, 1)
        XCTAssertEqual(destination.p14LatestVisualCommitCountForTesting, 0)
        XCTAssertEqual(
            destination.p14FreshRealmProofInFlightCountForTesting,
            1,
            "B must stabilize ownership without releasing held A"
        )
        if case .message(let anchor) =
            diagnosticsB.viewportDiagnostics.anchorStrategy {
            let plan = ChatOpenRealPipelineFixturePlan(
                scenario: .lastChatsSeededMentionExact
            )
            XCTAssertEqual(
                anchor.primary,
                destination.openScenarioPrimary(
                    plan.p14ExplicitMentionOrdinal
                )
            )
        } else {
            XCTFail("the replacement must retain the exact mention anchor")
        }
        XCTAssertLessThanOrEqual(
            abs(diagnosticsB.viewportDiagnostics.anchorError ?? .infinity),
            1
        )
        XCTAssertEqual(
            diagnosticsB.viewportDiagnostics.nextRunLoopCorrectionCount,
            0
        )

        let releaseA = try XCTUnwrap(capturedProofReleases.first)
        let releaseB = try XCTUnwrap(
            capturedProofReleases.dropFirst().first
        )
        DispatchQueue.global(qos: .userInitiated).async(execute: releaseB)
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                let p14 = destination.p14MentionDiagnosticsForTesting
                return destination
                    .p14InitialCommitUnreadProofEffectTokenForTesting == tokenB &&
                    destination.p14PresentationReceiptEffectTokenForTesting ==
                        tokenB &&
                    p14.readCommittedCount == 1 &&
                    p14.readSuccessfulFlushCount == 1 &&
                    p14.readTerminalSuccessCount == 1 &&
                    p14.readAtTerminal &&
                    destination.p14FreshRealmProofInFlightCountForTesting == 0
            },
            "B must own receipt and terminal read evidence; " +
                "receiptReadiness=\(String(describing: destination.p14ReceiptReadinessDiagnosticsForTesting))"
        )
        let beforeLateA = destination.p14MentionDiagnosticsForTesting
        let storedDiagnosticsBeforeLateA =
            destination.openScenarioCommittedInitialFrameDiagnostics
        queryLock.lock()
        let queryCountBeforeLateA = proofQueryCount
        queryLock.unlock()
        let lateAAdmissionDrained = expectation(
            description: "late A admission closure drained on main"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseA()
            DispatchQueue.main.async {
                lateAAdmissionDrained.fulfill()
            }
        }
        wait(for: [lateAAdmissionDrained], timeout: 4)
        XCTAssertEqual(
            destination.p14MentionDiagnosticsForTesting,
            beforeLateA
        )
        XCTAssertEqual(
            destination.p14InitialCommitUnreadProofEffectTokenForTesting,
            tokenB
        )
        XCTAssertEqual(
            destination.p14PresentationReceiptEffectTokenForTesting,
            tokenB
        )
        XCTAssertEqual(
            destination.openScenarioCommittedInitialFrameDiagnostics,
            storedDiagnosticsBeforeLateA
        )
        queryLock.lock()
        let queryCountAfterLateA = proofQueryCount
        queryLock.unlock()
        XCTAssertEqual(queryCountAfterLateA, queryCountBeforeLateA)
    }

    @MainActor
    func testP14CurrentHeldUnreadProofFailurePublishesExactlyOnceWithoutReadReceipt()
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
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-current-proof-failure-\(UUID().uuidString)"
        )
        let proofCaptured = expectation(
            description: "current P14 unread proof held"
        )
        var heldProofRelease: (() -> Void)?
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var destinationForCleanup:
            ChatPerformanceFixtureViewController?
        var navigationControllerForCleanup:
            UINavigationController?
        defer {
            if let heldProofRelease {
                DispatchQueue.global(qos: .userInitiated).async(
                    execute: heldProofRelease
                )
            }
            navigationControllerForCleanup?.delegate = nil
            destinationForCleanup?
                .performOpenScenarioTerminalResourceTeardown()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        )
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as?
                UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        destinationForCleanup = destination
        navigationControllerForCleanup = navigationController
        destination.p14InitialCommitFreshRealmProofExecutorForTests = {
            XCTAssertNil(heldProofRelease)
            heldProofRelease = $0
            proofCaptured.fulfill()
        }
        var publicationCount = 0
        destination.openScenarioDidStabilize = { _ in
            publicationCount &+= 1
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 8) {
            host.performanceRouteHostDiagnosticsSnapshot
                .p14SourceRowVisibleBeforeTap
        })
        XCTAssertTrue(host.performP14SourceRowTapForTesting())
        wait(for: [proofCaptured], timeout: 8)
        let realm = try WRealm.safe()
        let mention = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: destination
                .p14MentionNotificationPrimaryForTesting
        ))
        try realm.write { mention.isRead = true }

        let release = try XCTUnwrap(heldProofRelease)
        heldProofRelease = nil
        DispatchQueue.global(qos: .userInitiated).async(execute: release)
        XCTAssertTrue(waitUntil(timeout: 6) {
            destination.openScenarioStableReceipt?.phase == .failed
        })
        let receipt = try XCTUnwrap(destination.openScenarioStableReceipt)
        XCTAssertFalse(receipt.isStable)
        XCTAssertEqual(receipt.phase, .failed)
        XCTAssertEqual(receipt.p14Mention.freshRealmProofFailureCount, 1)
        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(
            destination.openScenarioStableAccessibilitySummaryForTesting,
            receipt.accessibilitySummary
        )
        XCTAssertFalse(
            destination.p14InitialCommitUnreadProofCompletedForTesting
        )
        XCTAssertFalse(destination.p14DidIssuePresentationReceiptForTesting)
        XCTAssertFalse(
            destination.readVisiblePresentationCoordinator
                .hasPresentationReceipt
        )
        let diagnostics = destination.p14MentionDiagnosticsForTesting
        XCTAssertEqual(diagnostics.freshRealmProofFailureCount, 1)
        XCTAssertEqual(diagnostics.readCommittedCount, 0)
        XCTAssertEqual(diagnostics.readSuccessfulFlushCount, 0)
        XCTAssertEqual(diagnostics.readTerminalSuccessCount, 0)
        XCTAssertEqual(destination.p14FreshRealmProofInFlightCountForTesting, 0)
        let terminalCallbacksDrained = expectation(
            description: "current failure callbacks drained on main"
        )
        DispatchQueue.main.async {
            terminalCallbacksDrained.fulfill()
        }
        wait(for: [terminalCallbacksDrained], timeout: 4)
        XCTAssertEqual(publicationCount, 1)
    }

    @MainActor
    func testP14SupersededQueuedProofDoesNotQueryRealmAfterWorkerAdmission()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-worker-query-boundary-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        ))
        defer { controller.performOpenScenarioTerminalResourceTeardown() }
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let request = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group,
                in: try WRealm.safe()
            )
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group
        )
        func token(_ generation: UInt64) -> ChatInitialFrameEffectToken {
            ChatInitialFrameEffectToken(
                presentationGeneration: generation,
                sessionIdentifier: ObjectIdentifier(session),
                descriptor: descriptor,
                anchorTransactionToken: ChatAnchorTransactionToken(
                    rawValue: "p14-worker-query-\(generation)"
                )
            )
        }
        let tokenA = token(401)
        let tokenB = token(402)
        controller.initialLocalFirstFramePresentationGeneration =
            tokenA.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenA
        controller.initialLocalFirstFramePhase = .committed(descriptor)

        let releaseLock = NSLock()
        var proofReleases: [() -> Void] = []
        controller.p14InitialCommitFreshRealmProofExecutorForTests = {
            releaseLock.lock()
            proofReleases.append($0)
            releaseLock.unlock()
        }
        let workerReached = expectation(
            description: "A worker admitted but held immediately before query"
        )
        let workerLock = NSLock()
        var releaseAWorker: (() -> Void)?
        controller.p14FreshRealmProofWorkerBeforeQueryExecutorForTests = {
            workerLock.lock()
            releaseAWorker = $0
            workerLock.unlock()
            workerReached.fulfill()
        }
        let queryLock = NSLock()
        var queryCount = 0
        controller.p14FreshRealmProofQueryObserverForTests = {
            queryLock.lock()
            queryCount &+= 1
            queryLock.unlock()
        }

        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenA
        )
        releaseLock.lock()
        let capturedReleaseA = proofReleases.first
        releaseLock.unlock()
        let releaseA = try XCTUnwrap(capturedReleaseA)
        DispatchQueue.global(qos: .userInitiated).async(execute: releaseA)
        wait(for: [workerReached], timeout: 4)

        controller.initialLocalFirstFramePresentationGeneration =
            tokenB.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenB
        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenB
        )
        XCTAssertEqual(
            controller.p14FreshRealmProofInFlightCountForTesting,
            1,
            "B adoption must eagerly revoke A's admitted lease"
        )
        releaseLock.lock()
        XCTAssertEqual(proofReleases.count, 2)
        releaseLock.unlock()

        workerLock.lock()
        let capturedReleaseAWorker = releaseAWorker
        releaseAWorker = nil
        workerLock.unlock()
        let releaseWorker = try XCTUnwrap(capturedReleaseAWorker)
        let staleWorkerReturned = expectation(
            description: "stale A worker query-boundary closure returned"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseWorker()
            staleWorkerReturned.fulfill()
        }
        wait(for: [staleWorkerReturned], timeout: 4)
        queryLock.lock()
        let observedQueryCount = queryCount
        queryLock.unlock()
        XCTAssertEqual(observedQueryCount, 0)
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting
                .freshRealmProofFailureCount,
            0
        )
        XCTAssertFalse(
            controller.p14InitialCommitUnreadProofCompletedForTesting
        )
    }

    @MainActor
    func testP14QueriedFailingProofSupersededBeforeMainDeliveryIsCompleteNoOp()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-stale-query-result-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        ))
        defer { controller.performOpenScenarioTerminalResourceTeardown() }
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let request = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group,
                in: try WRealm.safe()
            )
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group
        )
        func token(_ generation: UInt64) -> ChatInitialFrameEffectToken {
            ChatInitialFrameEffectToken(
                presentationGeneration: generation,
                sessionIdentifier: ObjectIdentifier(session),
                descriptor: descriptor,
                anchorTransactionToken: ChatAnchorTransactionToken(
                    rawValue: "p14-stale-query-result-\(generation)"
                )
            )
        }
        let tokenA = token(406)
        let tokenB = token(407)
        controller.initialLocalFirstFramePresentationGeneration =
            tokenA.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenA
        controller.initialLocalFirstFramePhase = .committed(descriptor)

        let proofLock = NSLock()
        var proofReleases: [() -> Void] = []
        controller.p14InitialCommitFreshRealmProofExecutorForTests = {
            proofLock.lock()
            proofReleases.append($0)
            proofLock.unlock()
        }
        let staleResultCaptured = expectation(
            description: "queried failing A result held before main delivery"
        )
        let resultLock = NSLock()
        var staleResultRelease: (() -> Void)?
        controller.p14FreshRealmProofResultDeliveryExecutorForTests = {
            resultLock.lock()
            staleResultRelease = $0
            resultLock.unlock()
            staleResultCaptured.fulfill()
        }
        var publicationCount = 0
        controller.openScenarioDidStabilize = { _ in
            publicationCount &+= 1
        }

        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenA
        )
        let realm = try WRealm.safe()
        let mention = try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: controller.p14MentionNotificationPrimaryForTesting
        ))
        try realm.write { mention.isRead = true }
        proofLock.lock()
        let capturedReleaseA = proofReleases.first
        proofLock.unlock()
        let releaseA = try XCTUnwrap(capturedReleaseA)
        DispatchQueue.global(qos: .userInitiated).async(execute: releaseA)
        wait(for: [staleResultCaptured], timeout: 4)

        controller.p14FreshRealmProofResultDeliveryExecutorForTests = nil
        controller.initialLocalFirstFramePresentationGeneration =
            tokenB.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenB
        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenB
        )
        proofLock.lock()
        let capturedProofReleases = proofReleases
        proofLock.unlock()
        XCTAssertEqual(capturedProofReleases.count, 2)
        XCTAssertEqual(controller.p14FreshRealmProofInFlightCountForTesting, 1)

        let accessibilityBeforeStaleDelivery =
            controller.openScenarioStableAccessibilitySummaryForTesting
        resultLock.lock()
        let capturedStaleResultRelease = staleResultRelease
        staleResultRelease = nil
        resultLock.unlock()
        let releaseStaleResult = try XCTUnwrap(capturedStaleResultRelease)
        let staleResultDeliveryDrained = expectation(
            description: "stale failing result delivery drained on main"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseStaleResult()
            DispatchQueue.main.async {
                staleResultDeliveryDrained.fulfill()
            }
        }
        wait(for: [staleResultDeliveryDrained], timeout: 4)
        let afterStaleDelivery = controller.p14MentionDiagnosticsForTesting
        XCTAssertEqual(afterStaleDelivery.freshRealmProofFailureCount, 0)
        XCTAssertEqual(afterStaleDelivery.freshRealmMatchCount, 0)
        XCTAssertEqual(afterStaleDelivery.readEagerMutationCount, 0)
        XCTAssertEqual(afterStaleDelivery.readCommittedCount, 0)
        XCTAssertEqual(afterStaleDelivery.readSuccessfulFlushCount, 0)
        XCTAssertEqual(afterStaleDelivery.readTerminalSuccessCount, 0)
        XCTAssertFalse(
            controller.p14InitialCommitUnreadProofCompletedForTesting
        )
        XCTAssertFalse(controller.p14DidIssuePresentationReceiptForTesting)
        XCTAssertNil(
            controller.p14InitialCommitUnreadProofEffectTokenForTesting
        )
        XCTAssertNil(controller.p14PresentationReceiptEffectTokenForTesting)
        XCTAssertEqual(
            controller.p14InitialFrameCommitEffectTokenForTesting,
            tokenB
        )
        XCTAssertNil(controller.openScenarioStableReceipt)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(
            controller.openScenarioStableAccessibilitySummaryForTesting,
            accessibilityBeforeStaleDelivery
        )

        try realm.write { mention.isRead = false }
        let releaseB = try XCTUnwrap(
            capturedProofReleases.dropFirst().first
        )
        DispatchQueue.global(qos: .userInitiated).async(execute: releaseB)
        XCTAssertTrue(waitUntil(timeout: 4) {
            controller.p14InitialCommitUnreadProofCompletedForTesting &&
                controller
                    .p14InitialCommitUnreadProofEffectTokenForTesting == tokenB
        })
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting
                .freshRealmProofFailureCount,
            0
        )
        XCTAssertEqual(controller.p14FreshRealmProofInFlightCountForTesting, 0)
    }

    @MainActor
    func testP14ReplacementUsesAttemptScopedSuccessfulFlushBaseline()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-flush-baseline-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        ))
        defer { controller.performOpenScenarioTerminalResourceTeardown() }
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let request = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group,
                in: try WRealm.safe()
            )
        )
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group
        )
        func token(_ generation: UInt64) -> ChatInitialFrameEffectToken {
            ChatInitialFrameEffectToken(
                presentationGeneration: generation,
                sessionIdentifier: ObjectIdentifier(session),
                descriptor: descriptor,
                anchorTransactionToken: ChatAnchorTransactionToken(
                    rawValue: "p14-flush-baseline-\(generation)"
                )
            )
        }
        let tokenA = token(411)
        let tokenB = token(412)
        var proofReleases: [() -> Void] = []
        controller.p14InitialCommitFreshRealmProofExecutorForTests = {
            proofReleases.append($0)
        }
        let coordinator = controller.readVisiblePresentationCoordinator
        let snapshot = ChatReadVisiblePresentationSnapshot(
            isApplicationActive: true,
            isWindowAttached: true,
            isWindowSceneForegroundActive: true,
            isKeyWindow: true,
            isTopNavigationDestination: true,
            isVisibleSplitSecondary: false,
            hasCoveringPresentation: false,
            isTransitionActive: false
        )

        controller.initialLocalFirstFramePresentationGeneration =
            tokenA.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenA
        controller.initialLocalFirstFramePhase = .committed(descriptor)
        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenA
        )
        coordinator.recordPresentationReceipt()
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-flush-baseline-a-notification",
            messagePrimary: "p14-flush-baseline-a-message",
            initialFrameEffectToken: tokenA
        )])
        let flushA = try XCTUnwrap(coordinator.takeFlush(
            snapshot: snapshot,
            visibleMessagePrimaries: ["p14-flush-baseline-a-message"]
        ))
        XCTAssertTrue(coordinator.complete(flush: flushA, succeeded: true))
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting
                .readSuccessfulFlushCount,
            1
        )

        controller.initialLocalFirstFramePresentationGeneration =
            tokenB.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenB
        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenB
        )
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting
                .readSuccessfulFlushCount,
            0,
            "B begins with an attempt-local zero even after A completed"
        )
        coordinator.recordPresentationReceipt()
        coordinator.enqueue([ChatPendingMentionReadCandidate(
            notificationPrimary: "p14-flush-baseline-b-notification",
            messagePrimary: "p14-flush-baseline-b-message",
            initialFrameEffectToken: tokenB
        )])
        let flushB = try XCTUnwrap(coordinator.takeFlush(
            snapshot: snapshot,
            visibleMessagePrimaries: ["p14-flush-baseline-b-message"]
        ))
        XCTAssertTrue(coordinator.complete(flush: flushB, succeeded: true))
        XCTAssertEqual(coordinator.successfulFlushCount, 2)
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting
                .readSuccessfulFlushCount,
            1
        )
        XCTAssertEqual(proofReleases.count, 2)
    }

    @MainActor
    func testP14HeldProofReleasedAfterTerminalTeardownIsCompleteNoOp()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-p14-proof-teardown-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .lastChatsSeededMentionExact
        ))
        let proofLock = NSLock()
        var heldProofReleases: [() -> Void] = []
        controller.p14InitialCommitFreshRealmProofExecutorForTests = {
            proofLock.lock()
            heldProofReleases.append($0)
            proofLock.unlock()
        }
        let queriedBResultCaptured = expectation(
            description: "B queried result held before terminal teardown"
        )
        let resultLock = NSLock()
        var heldQueriedBResultRelease: (() -> Void)?
        controller.p14FreshRealmProofResultDeliveryExecutorForTests = {
            resultLock.lock()
            heldQueriedBResultRelease = $0
            resultLock.unlock()
            queriedBResultCaptured.fulfill()
        }
        let queryLock = NSLock()
        var proofQueryCount = 0
        controller.p14FreshRealmProofQueryObserverForTests = {
            queryLock.lock()
            proofQueryCount &+= 1
            queryLock.unlock()
        }

        let request = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: .group,
                in: try WRealm.safe()
            )
        )
        controller.configureDataset()
        let session = try XCTUnwrap(controller.timelineSession)
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: .group
        )
        func token(_ generation: UInt64) -> ChatInitialFrameEffectToken {
            ChatInitialFrameEffectToken(
                presentationGeneration: generation,
                sessionIdentifier: ObjectIdentifier(session),
                descriptor: descriptor,
                anchorTransactionToken: ChatAnchorTransactionToken(
                    rawValue: "p14-proof-teardown-\(generation)"
                )
            )
        }
        let tokenA = token(421)
        let tokenB = token(422)
        controller.initialLocalFirstFramePresentationGeneration =
            tokenA.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenA
        controller.initialLocalFirstFramePhase = .committed(descriptor)
        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenA
        )
        controller.initialLocalFirstFramePresentationGeneration =
            tokenB.presentationGeneration
        controller.initialLocalFirstFrameLatestEffectToken = tokenB
        controller.scheduleP14ReplacementInitialCommitProofForTesting(
            effectToken: tokenB
        )
        proofLock.lock()
        let capturedProofReleases = heldProofReleases
        proofLock.unlock()
        XCTAssertEqual(capturedProofReleases.count, 2)
        XCTAssertEqual(controller.p14FreshRealmProofInFlightCountForTesting, 1)
        let releaseA = try XCTUnwrap(capturedProofReleases.first)
        let releaseB = try XCTUnwrap(
            capturedProofReleases.dropFirst().first
        )
        DispatchQueue.global(qos: .userInitiated).async(execute: releaseB)
        wait(for: [queriedBResultCaptured], timeout: 4)
        XCTAssertEqual(controller.p14FreshRealmProofInFlightCountForTesting, 1)
        queryLock.lock()
        let queryCountBeforeTeardown = proofQueryCount
        queryLock.unlock()
        XCTAssertEqual(queryCountBeforeTeardown, 1)
        resultLock.lock()
        let capturedQueriedBResultRelease = heldQueriedBResultRelease
        heldQueriedBResultRelease = nil
        resultLock.unlock()
        let releaseQueriedBResult = try XCTUnwrap(
            capturedQueriedBResultRelease
        )

        controller.performOpenScenarioTerminalResourceTeardown()
        XCTAssertTrue(controller.isP14ObserverTeardownCompleteForTesting)
        let lateTeardownClosuresDrained = expectation(
            description: "late A admission and B result drained on main"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseA()
            releaseQueriedBResult()
            DispatchQueue.main.async {
                lateTeardownClosuresDrained.fulfill()
            }
        }
        wait(for: [lateTeardownClosuresDrained], timeout: 4)
        XCTAssertEqual(controller.p14FreshRealmProofInFlightCountForTesting, 0)
        XCTAssertFalse(
            controller.p14InitialCommitUnreadProofCompletedForTesting
        )
        XCTAssertFalse(controller.p14DidIssuePresentationReceiptForTesting)
        XCTAssertNil(controller.openScenarioStableReceipt)
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting.readCommittedCount,
            0
        )
        XCTAssertEqual(
            controller.p14MentionDiagnosticsForTesting
                .freshRealmProofFailureCount,
            0
        )
        XCTAssertNil(
            controller.openScenarioStableAccessibilitySummaryForTesting
        )
        queryLock.lock()
        let queryCountAfterLateReleases = proofQueryCount
        queryLock.unlock()
        XCTAssertEqual(queryCountAfterLateReleases, 1)
    }

    @MainActor
    func testRealPipelineFixtureRunsEveryScenarioThroughOneStableInitialPresentation()
        throws {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousInterfaceType =
            CommonConfigManager.shared.config.interface_type
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let previousConnectingUsers =
            AccountManager.shared.connectingUsers.value
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        defer {
            NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
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
            previousKeyWindow?.makeKey()
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        }

        let foregroundScene = try requireHostedForegroundWindowScene()
        for scenario in ChatOpenRealPipelineFixtureScenario.allCases {
            let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
            let descriptor = ChatPerformanceUITestLaunchDescriptor(
                scale: .small,
                openScenario: scenario
            )
            let window = UIWindow(windowScene: foregroundScene)
            window.frame = foregroundScene.coordinateSpace.bounds
            XCTAssertTrue(window.windowScene === foregroundScene)
            var controllerForCleanup:
                ChatPerformanceFixtureViewController?
            var navigationControllerForCleanup:
                UINavigationController?
            defer {
                controllerForCleanup?.openScenarioDidStabilize = nil
                controllerForCleanup?
                    .performTerminalChatResourceTeardownForTesting()
                navigationControllerForCleanup?.delegate = nil
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
                ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            }
            let controller: ChatPerformanceFixtureViewController
            let navigationController: UINavigationController
            var routeCoordinator: AppRootCoordinator?
            var routeHost:
                ChatPerformanceLastChatsRouteHostViewController?
            var p13SourceHost:
                ChatPerformanceMentionNotificationsRouteHostViewController?
            if ChatPerformanceFixtureRootPolicy.mode(for: scenario) ==
                .lastChatsNativeRoute {
                let coordinator = AppRootCoordinator(
                    window: window,
                    appDelegate: nil
                )
                routeCoordinator = coordinator
                coordinator.startChatPerformanceProductionRouteFixture(
                    descriptor: descriptor
                )
                guard let tabController = window.rootViewController as?
                        XabberTabBarViewController,
                      let routeNavigationController =
                        tabController.viewControllers?.first as?
                            UINavigationController,
                      let host = routeNavigationController.viewControllers.first
                        as? ChatPerformanceLastChatsRouteHostViewController,
                      let destination = host.compactChatDestinationFactory()
                        as? ChatPerformanceFixtureViewController else {
                    XCTFail("Unable to install production route fixture for \(scenario)")
                    window.isHidden = true
                    continue
                }
                navigationController = routeNavigationController
                controller = destination
                routeHost = host
                if scenario == .mentionDeletedAdvance {
                    p13SourceHost =
                        (tabController.viewControllers?[2] as?
                            UINavigationController)?
                            .viewControllers.first as?
                            ChatPerformanceMentionNotificationsRouteHostViewController
                }
            } else {
                controller = ChatPerformanceFixtureViewController(
                    descriptor: descriptor
                )
                navigationController = UINavigationController(
                    rootViewController: controller
                )
                window.rootViewController = navigationController
            }
            controllerForCleanup = controller
            navigationControllerForCleanup = navigationController
            var publicationCount = 0
            controller.openScenarioDidStabilize = { _ in
                publicationCount += 1
            }

            window.makeKeyAndVisible()
            if ChatPerformanceFixtureRootPolicy.mode(for: scenario) ==
                .directChatFixture {
                controller.loadViewIfNeeded()
            }
            if scenario == .lastChatsSeededMentionExact {
                XCTAssertTrue(waitUntil(timeout: 8) {
                    routeHost?.performanceRouteHostDiagnosticsSnapshot
                        .p14SourceRowVisibleBeforeTap == true
                })
                XCTAssertTrue(
                    routeHost?.performP14SourceRowTapForTesting() == true
                )
            }
            if scenario == .mentionDeletedAdvance {
                XCTAssertTrue(waitUntil(timeout: 8) {
                    p13SourceHost?
                        .performanceP13SourceRowVisibleForTesting == true
                })
                XCTAssertTrue(
                    p13SourceHost?.performP13SourceRowTapForTesting() == true
                )
            }
            if scenario == .searchExactRemote {
                XCTAssertEqual(
                    controller.pendingOpenMessageRequest?.source,
                    .search
                )
                XCTAssertNil(
                    controller.pendingOpenMessageRequest?
                        .anchor.messagePrimary
                )
                XCTAssertNil(
                    controller.pendingOpenMessageRequest?
                        .anchor.messageId
                )
                XCTAssertNotNil(
                    controller.pendingOpenMessageRequest?
                        .anchor.archivedId,
                    "X03 must exercise a genuinely archive-only exact search"
                )
            }
            if plan.requiresPostInitialInteraction &&
                scenario != .lastChatsAnimatedPush {
                XCTAssertTrue(
                    waitUntil(timeout: 8) {
                        controller
                            .isOpenScenarioPostInitialInteractionReadyForTesting
                    },
                    "post-initial action never became ready for \(scenario)"
                )
                switch scenario {
                case .olderCrossingGap, .newerCrossingGap:
                    XCTAssertTrue(
                        controller
                            .performOpenScenarioPostInitialActionForTesting(),
                        "production paging admission rejected \(scenario)"
                    )
                case .rotationRealPipeline:
                    controller.completeOpenScenarioRotationTransitionForTesting()
                    controller.completeOpenScenarioRotationTransitionForTesting()
                case .committedContentBackgroundForeground:
                    controller.performOpenScenarioBackgroundForegroundForTesting()
                default:
                    XCTFail("Missing hosted post-initial driver for \(scenario)")
                }
            }
            XCTAssertTrue(
                waitUntil(timeout: 14) {
                    controller.openScenarioStableReceipt != nil
                },
                "stable receipt was not published for \(scenario)"
            )
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.35)
            )

            let receipt = try? XCTUnwrap(controller.openScenarioStableReceipt)
            XCTAssertEqual(publicationCount, 1)
            XCTAssertEqual(receipt?.stableReceiptGeneration, 1)
            XCTAssertEqual(receipt?.scenario, scenario)
            XCTAssertEqual(receipt?.phase, plan.stableTerminalPhase)
            XCTAssertEqual(receipt?.targetKind, plan.targetKind)
            XCTAssertEqual(
                receipt?.initialSkeletonRowCount,
                plan.expectedInitialSkeletonRowCount
            )
            XCTAssertEqual(
                receipt?.currentSkeletonRowCount,
                plan.expectedFinalSkeletonRowCount
            )
            XCTAssertEqual(receipt?.realRowCount, plan.expectedFinalRealRowCount)
            XCTAssertEqual(
                receipt?.firstContentApplyCount,
                plan.expectsSkeletonTerminal ? 0 : 1
            )
            XCTAssertEqual(
                receipt?.visualCommitCount,
                plan.expectsSkeletonTerminal ? 0 : 1
            )
            XCTAssertEqual(receipt?.previousOrBlankRealFrameCount, 0)
            XCTAssertEqual(receipt?.correctionCount, 0)
            XCTAssertEqual(receipt?.postCommitOffsetMutationCount, 0)
            XCTAssertLessThanOrEqual(receipt?.offsetMutationCount ?? .max, 1)
            XCTAssertTrue(receipt?.isStable == true)
            XCTAssertTrue(receipt?.storage.hasRetainedRealmLease == true)
            XCTAssertTrue(receipt?.storage.isEphemeral == true)
            XCTAssertEqual(
                receipt?.storage.messageCount,
                plan.initialLocalMessageCount
            )
            XCTAssertTrue(receipt?.storage.hasChatRecord == true)
            XCTAssertTrue(receipt?.storage.hasArchiveState == true)
            if ChatPerformanceFixtureRootPolicy.mode(for: scenario) ==
                .lastChatsNativeRoute {
                XCTAssertNotNil(routeCoordinator)
                XCTAssertTrue(receipt?.routeHost.isAccepted(for: scenario) == true)
            }
            if scenario == .lastChatsSeededMentionExact,
               let receipt {
                assertAcceptedP14HostedReceipt(receipt)
            }
            if scenario == .mentionDeletedAdvance,
               let receipt {
                assertAcceptedP13HostedReceipt(receipt)
            }
            XCTAssertEqual(
                receipt?.fixtureRealmQueryCountAfterRouteAdmission,
                0
            )
            XCTAssertEqual(
                receipt?.storage.hasDurableReadiness,
                !plan.startsWithoutDurableReadiness
            )
            XCTAssertEqual(
                receipt?.requestSource,
                plan.expectedRequestSource
            )
            XCTAssertEqual(
                receipt?.requestHighlight,
                plan.expectedRequestHighlight ?? false
            )
            XCTAssertEqual(
                receipt?.postInitialInteractionCount,
                plan.requiresPostInitialInteraction ? 1 : 0
            )
            XCTAssertEqual(
                controller
                    .openScenarioInitialBootstrapRequestInvocationCountForTesting,
                plan.requiresRemoteInjection ? 1 : 0,
                "Only a blocking remote-open plan may enter the bootstrap coordinator"
            )
            if !plan.requiresRemoteInjection {
                XCTAssertEqual(
                    receipt?.productionBootstrapLeaseStartCount,
                    0,
                    "Local/durable route unexpectedly started a bootstrap lease for \(scenario)"
                )
                XCTAssertEqual(
                    receipt?.productionBootstrapLeaseJoinCount,
                    0,
                    "Local/durable route unexpectedly joined a bootstrap lease for \(scenario)"
                )
                XCTAssertEqual(
                    receipt?.productionBootstrapTransportStartCount,
                    0,
                    "Local/durable route unexpectedly started bootstrap transport for \(scenario)"
                )
            }

            if [.unreadBoundaryLocal, .savedPositionLocal].contains(scenario) {
                XCTAssertEqual(receipt?.resolvedTargetOrdinal, 160)
                XCTAssertEqual(receipt?.targetMatchCount, 1)
                XCTAssertEqual(receipt?.latestVisualCommitCount, 0)
                XCTAssertEqual(receipt?.archiveLeaseCount, 0)
                XCTAssertEqual(receipt?.archiveRequestCount, 0)
                XCTAssertEqual(receipt?.gapRequestCount, 0)
                XCTAssertEqual(
                    receipt?.archiveCursorKind,
                    ChatOpenRealPipelineFixtureArchiveCursorKind.none
                )
            } else if scenario == .confirmedEmpty {
                XCTAssertEqual(receipt?.archiveLeaseCount, 0)
                XCTAssertEqual(receipt?.archiveRequestCount, 0)
                XCTAssertEqual(receipt?.gapRequestCount, 0)
                XCTAssertEqual(receipt?.productionBootstrapLeaseStartCount, 0)
                XCTAssertEqual(receipt?.productionBootstrapLeaseJoinCount, 0)
                XCTAssertEqual(receipt?.productionBootstrapTransportStartCount, 0)
            } else if scenario == .latestWithUnrelatedOlderGap {
                XCTAssertNil(receipt?.resolvedTargetOrdinal)
                XCTAssertEqual(receipt?.targetMatchCount, 0)
                XCTAssertEqual(receipt?.latestVisualCommitCount, 1)
                XCTAssertEqual(receipt?.archiveLeaseCount, 0)
                XCTAssertEqual(receipt?.archiveRequestCount, 0)
                XCTAssertEqual(receipt?.gapRequestCount, 0)
                XCTAssertEqual(
                    receipt?.archiveCursorKind,
                    ChatOpenRealPipelineFixtureArchiveCursorKind.none
                )
            }

            let consumedRemoteActions = controller.openScenarioConsumedRemoteHistoryActions
            let expectsAnchorContextPrefetch = [
                ChatOpenRealPipelineFixtureScenario.notificationExactRemote,
                .notificationKnownGapTarget,
                .searchExactRemote,
                .knownGapMissingTarget,
                .coldPushExact,
                .newerCrossingGap
            ].contains(scenario)
            if expectsAnchorContextPrefetch {
                XCTAssertEqual(consumedRemoteActions.count, 1)
                XCTAssertEqual(consumedRemoteActions.first?.kind, .anchorContextPrefetch)
                XCTAssertEqual(
                    consumedRemoteActions.first?.source,
                    plan.expectedRequestSource
                )
                XCTAssertTrue(consumedRemoteActions.first?.requiresRemoteFetch == true)
                XCTAssertEqual(consumedRemoteActions.first?.olderPageSize, 85)
                XCTAssertEqual(consumedRemoteActions.first?.newerPageSize, 86)
                XCTAssertEqual(consumedRemoteActions.first?.requestedMessageCount, 171)
                XCTAssertEqual(
                    receipt?.transportThreadSnapshot.archiveEnvelopeCount,
                    80
                )
                XCTAssertEqual(
                    receipt?.transportThreadSnapshot.messageIngressCount,
                    80
                )
                if scenario == .newerCrossingGap {
                    XCTAssertEqual(receipt?.archiveRequestCount, 3)
                    XCTAssertEqual(receipt?.gapRequestCount, 3)
                    XCTAssertEqual(
                        receipt?.transportThreadSnapshot.mamStartCount,
                        2
                    )
                    XCTAssertGreaterThanOrEqual(
                        receipt?.transportThreadSnapshot.finalParserCount ?? 0,
                        6
                    )
                }
            } else {
                XCTAssertTrue(consumedRemoteActions.isEmpty)
            }
            if [
                ChatOpenRealPipelineFixtureScenario.notificationExactRemote,
                .notificationKnownGapTarget,
                .searchExactRemote,
                .knownGapMissingTarget,
                .coldPushExact
            ].contains(scenario) {
                let expectedInitialGapRequests =
                    plan.hasKnownGapTopology ? 2 : 0
                let expectedTerminalGapRequests =
                    plan.hasKnownGapTopology ? 4 : 0
                XCTAssertEqual(receipt?.initialFrameArchiveRequestCount, 3)
                XCTAssertEqual(
                    receipt?.initialFrameGapRequestCount,
                    expectedInitialGapRequests
                )
                XCTAssertEqual(receipt?.archiveRequestCount, 5)
                XCTAssertEqual(
                    receipt?.gapRequestCount,
                    expectedTerminalGapRequests
                )
                XCTAssertEqual(receipt?.postInitialArchiveRequestCount, 2)
                XCTAssertEqual(
                    receipt?.postInitialGapRequestCount,
                    expectedTerminalGapRequests - expectedInitialGapRequests
                )
                XCTAssertEqual(receipt?.initialFrameStoreQueryCount, 2)
                XCTAssertEqual(
                    receipt?.initialFrameStoreOperationSummary
                        .accessibilityValue,
                    "message-window:1,post-bootstrap:1"
                )
                XCTAssertEqual(
                    receipt?.initialFrameStoreOperationSummary.totalCount,
                    receipt?.initialFrameStoreQueryCount
                )
                XCTAssertEqual(receipt?.blockingInitialStoreQueryCount, 1)
                XCTAssertEqual(
                    receipt?.blockingInitialStoreOperationSummary
                        .accessibilityValue,
                    "post-bootstrap:1"
                )
                XCTAssertEqual(receipt?.storeQueryCount, 3)
                XCTAssertEqual(receipt?.storeLifetimeQueryCount, 3)
                XCTAssertEqual(receipt?.postInitialStoreQueryCount, 0)
                XCTAssertEqual(
                    (receipt?.initialFrameStoreQueryCount ?? -1) +
                        (receipt?.blockingInitialStoreQueryCount ?? -1) +
                        (receipt?.postInitialStoreQueryCount ?? -1),
                    receipt?.storeQueryCount
                )
                XCTAssertEqual(
                    receipt?.postInitialStoreOperationSummary
                        .accessibilityValue,
                    "none"
                )
                XCTAssertEqual(
                    receipt?.terminalRouteStoreOperationSummary.totalCount,
                    receipt?.storeQueryCount
                )
                XCTAssertEqual(
                    receipt?.terminalRouteStoreOperationSummary
                        .accessibilityValue,
                    "message-window:1,post-bootstrap:2"
                )
                XCTAssertEqual(
                    receipt?.terminalRouteStoreOperationSummary
                        .unknownOperationCount,
                    0
                )
                XCTAssertEqual(receipt?.mainThreadStoreQueryCount, 0)
                XCTAssertEqual(
                    receipt?.transportThreadSnapshot.mamStartCount,
                    3
                )
                XCTAssertGreaterThanOrEqual(
                    receipt?.transportThreadSnapshot.finalParserCount ?? 0,
                    10
                )
            }
            if scenario == .searchExactRemote {
                XCTAssertEqual(receipt?.resolvedTargetOrdinal, 160)
                XCTAssertEqual(receipt?.targetMatchCount, 1)
                XCTAssertEqual(receipt?.visualCommitCount, 1)
                XCTAssertEqual(receipt?.activeProductionWorkCount, 0)
            }
        }
    }

    @MainActor
    private func withStableLocalOpenScenario(
        _ scenario: ChatOpenRealPipelineFixtureScenario,
        usingReusedSession: Bool = false,
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
        if usingReusedSession {
            controller.installOpenScenarioReusedTimelineSessionForTesting(
                try makePrewarmedOpenScenarioSession(controller: controller)
            )
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            controller.openScenarioDidStabilize = nil
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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

    private var localRequestToTerminalCoverageScenarios:
        [ChatOpenRealPipelineFixtureScenario] {
        [
            .preloadedLatest,
            .unreadBoundaryLocal,
            .notificationExactLocal,
            .searchExactLocal,
            .savedPositionLocal,
            .knownGapMissingTarget
        ]
    }

    private func assertRequestToTerminalRouteReceipt(
        _ receipt: ChatOpenRealPipelineFixtureDiagnostics,
        scenario: ChatOpenRealPipelineFixtureScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
        XCTAssertEqual(receipt.scenario, scenario, file: file, line: line)
        XCTAssertEqual(receipt.phase, .content, file: file, line: line)
        XCTAssertEqual(receipt.targetKind, plan.targetKind, file: file, line: line)
        XCTAssertEqual(
            receipt.committedTargetKind,
            plan.targetKind,
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.requestSource,
            plan.expectedRequestSource,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.mainThreadStoreQueryCount, 0, file: file, line: line)
        XCTAssertEqual(
            receipt.mainThreadObserverRealmQueryCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.mainThreadObserverInitialCallbackCount,
            0,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            receipt.observerMaxInitialCandidateCount,
            80,
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.mainThreadObserverMetadataQueryCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.observerMetadataFullScanCount,
            0,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            receipt.observerMaxMetadataCandidateCount,
            80,
            file: file,
            line: line
        )
        XCTAssertEqual(
            receipt.observerCatchUpMutationCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.observerPendingWorkCount, 0, file: file, line: line)
        XCTAssertEqual(receipt.fullScanCount, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(receipt.maxCandidateCount, 80, file: file, line: line)
        XCTAssertEqual(receipt.committedRouteCount, 1, file: file, line: line)
        XCTAssertEqual(receipt.visualCommitCount, 1, file: file, line: line)
        XCTAssertEqual(
            receipt.previousOrBlankRealFrameCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.postCommitOffsetMutationCount, 0, file: file, line: line)
        XCTAssertEqual(receipt.correctionCount, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            receipt.terminalQuietMilliseconds,
            500,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.activeProductionWorkCount, 0, file: file, line: line)
        XCTAssertEqual(
            receipt.fixtureRealmQueryCountAfterRouteAdmission,
            0,
            file: file,
            line: line
        )
    }

    @MainActor
    private func makePrewarmedOpenScenarioSession(
        controller: ChatPerformanceFixtureViewController
    ) throws -> ChatTimelineSession {
        let conversationKey = ChatTimelineConversationKey(
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        let session = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(
                owner: controller.owner,
                jid: controller.jid,
                conversationType: controller.conversationType
            ),
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            conversationKey: conversationKey,
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: controller.jid,
                    owner: controller.owner,
                    conversationType: controller.conversationType
                )
            ),
            observesStoreImmediately: false
        )
        let prepared = expectation(description: "reused session warm route prepared")
        var preparationResult: ChatTimelineInitialFramePreparationResult?
        XCTAssertEqual(
            session.prepareInitialFrame(
                target: .latest,
                limit: ChatInitialFirstFrameHistoryConfiguration.pageSize,
                expectedGeneration: session.snapshot.generation
            ) {
                preparationResult = $0
                prepared.fulfill()
            },
            .started
        )
        wait(for: [prepared], timeout: 2)
        guard case .prepared(let frame) = preparationResult else {
            throw NSError(
                domain: "ChatPerformanceLabTests.reusedSession",
                code: 1
            )
        }
        XCTAssertNotNil(session.commitPreparedInitialFrame(frame))
        XCTAssertEqual(session.snapshot.generation, 1)
        XCTAssertEqual(session.routeStoreDiagnosticsSnapshot.queryCount, 2)
        XCTAssertEqual(
            session.routeStoreDiagnosticsSnapshot.mainThreadQueryCount,
            0
        )
        XCTAssertEqual(session.routeStoreDiagnosticsSnapshot.fullScanCount, 0)
        XCTAssertLessThanOrEqual(
            session.routeStoreDiagnosticsSnapshot.maxCandidateCount,
            80
        )
        session.activateStoreObservation()
        XCTAssertTrue(
            waitUntilObserverIdle(session),
            "the reused control must enter its route with an already active observer"
        )
        return session
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
    private func assertObserverInitialCatchUp(
        mutation: ChatTimelineObserverCatchUpMutation,
        expectedFinalPrimaries: [String],
        expectedInsertedPrimaries: [String] = [],
        expectedUpdatedPrimaries: [String] = [],
        expectedDeletedPrimaries: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "ChatPerformanceLabTests-observer-catch-up-\(mutation.rawValue)-\(UUID().uuidString)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let owner = "observer-catch-up-owner@example.test"
        let jid = "observer-catch-up-peer@example.test"
        let conversationType = ClientSynchronizationManager.ConversationType.regular
        let realm = try WRealm.safe()
        try seedObserverConversation(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )

        let registrationReached = expectation(
            description: "LastChats registration is held after frame commit"
        )
        registrationReached.assertForOverFulfill = true
        let registrationRelease = DispatchSemaphore(value: 0)
        var didReleaseRegistration = false
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            observationTestHooks: ChatTimelineStoreObservationTestHooks(
                beforeRealmQuery: { identity in
                    guard identity == .init(kind: .lastChats, generation: 1) else {
                        return
                    }
                    registrationReached.fulfill()
                    _ = registrationRelease.wait(timeout: .now() + 5)
                },
                didRegister: nil,
                didCancel: nil
            )
        )
        let conversationKey = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            conversationKey: conversationKey,
            archiveState: .unresolved(
                primaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
            ),
            observesStoreImmediately: false
        )
        defer {
            if !didReleaseRegistration {
                registrationRelease.signal()
            }
            session.deactivateStoreObservation()
        }

        let prepared = expectation(description: "authoritative first frame prepared")
        var preparationResult: ChatTimelineInitialFramePreparationResult?
        XCTAssertEqual(
            session.prepareInitialFrame(
                target: .latest,
                limit: 80,
                expectedGeneration: session.snapshot.generation
            ) {
                preparationResult = $0
                prepared.fulfill()
            },
            .started,
            file: file,
            line: line
        )
        wait(for: [prepared], timeout: 2)
        guard case .prepared(let frame) = preparationResult else {
            return XCTFail(
                "Expected an authoritative prepared first frame",
                file: file,
                line: line
            )
        }
        let committed = try XCTUnwrap(
            session.commitPreparedInitialFrame(frame),
            file: file,
            line: line
        )
        XCTAssertEqual(committed.generation, 1, file: file, line: line)
        XCTAssertEqual(
            committed.items.map(\.primary),
            [
                "observer-primary-0",
                "observer-primary-1",
                "observer-primary-2"
            ],
            file: file,
            line: line
        )
        XCTAssertNotNil(
            committed.unreadMetadata.initialFrameReadinessProof,
            file: file,
            line: line
        )
        XCTAssertEqual(store.diagnosticsSnapshot.queryCount, 2, file: file, line: line)

        var publishedSnapshots: [ChatTimelineSessionSnapshot] = []
        session.onSnapshot = { publishedSnapshots.append($0) }
        session.activateStoreObservation()
        wait(for: [registrationReached], timeout: 2)

        try mutateObserverConversation(
            mutation,
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        registrationRelease.signal()
        didReleaseRegistration = true

        XCTAssertTrue(
            waitUntilObserverIdle(session, timeout: 3),
            "Observer catch-up must reach a stable terminal state",
            file: file,
            line: line
        )
        XCTAssertEqual(publishedSnapshots.count, 1, file: file, line: line)
        let caughtUp = try XCTUnwrap(publishedSnapshots.first, file: file, line: line)
        XCTAssertEqual(caughtUp.cause, .storeChange, file: file, line: line)
        XCTAssertEqual(caughtUp.generation, 2, file: file, line: line)
        XCTAssertEqual(
            caughtUp.items.map(\.primary),
            expectedFinalPrimaries,
            file: file,
            line: line
        )
        if mutation == .edit {
            XCTAssertEqual(
                caughtUp.item(primary: "observer-primary-2")?.body,
                "observer body edited between commit and registration",
                file: file,
                line: line
            )
        }
        let changeSet = try XCTUnwrap(
            caughtUp.residentChangeSet,
            file: file,
            line: line
        )
        XCTAssertEqual(
            changeSet.insertedPrimaries.sorted(),
            expectedInsertedPrimaries.sorted(),
            file: file,
            line: line
        )
        XCTAssertEqual(
            changeSet.updatedStablePrimaries.sorted(),
            expectedUpdatedPrimaries.sorted(),
            file: file,
            line: line
        )
        XCTAssertEqual(
            changeSet.deletedPrimaries.sorted(),
            expectedDeletedPrimaries.sorted(),
            file: file,
            line: line
        )

        let diagnostics = store.diagnosticsSnapshot
        XCTAssertEqual(
            diagnostics.queryCount,
            2,
            "observer metadata must not contaminate initial-frame query totals",
            file: file,
            line: line
        )
        XCTAssertEqual(diagnostics.mainThreadQueryCount, 0, file: file, line: line)
        XCTAssertEqual(diagnostics.observation.activationCount, 1, file: file, line: line)
        XCTAssertEqual(diagnostics.observation.realmQueryCount, 2, file: file, line: line)
        XCTAssertEqual(
            diagnostics.observation.mainThreadRealmQueryCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.initialCallbackCount,
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.mainThreadInitialCallbackCount,
            0,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            diagnostics.observation.maxInitialCandidateCount,
            80,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.metadataQueryCount,
            mutation == .append ? 1 : 0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.mainThreadMetadataQueryCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.metadataFullScanCount,
            0,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            diagnostics.observation.maxMetadataCandidateCount,
            80,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.catchUpMutationCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.observation.pendingWorkCount,
            0,
            file: file,
            line: line
        )
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
    private func mutateObserverConversation(
        _ mutation: ChatTimelineObserverCatchUpMutation,
        realm: Realm,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) throws {
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        ))
        let latest = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "observer-primary-2"
        ))
        try realm.write {
            switch mutation {
            case .append:
                let appended = makeObserverMessage(
                    ordinal: 3,
                    owner: owner,
                    jid: jid,
                    conversationType: conversationType
                )
                realm.add(appended, update: .modified)
                chat.lastMessage = appended
                chat.lastMessageId = appended.messageId
                chat.messageDate = appended.date
                chat.syncSnapshotLastArchiveId = appended.archivedId
            case .edit:
                latest.body = "observer body edited between commit and registration"
                latest.editDate = Date(timeIntervalSince1970: 9_002)
                latest.state = .deliver
            case .physicalDelete:
                let previous = realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: "observer-primary-1"
                )
                chat.lastMessage = previous
                chat.lastMessageId = previous?.messageId ?? ""
                chat.messageDate = previous?.date ?? Date(timeIntervalSince1970: 0)
                realm.delete(latest)
            case .tombstone:
                latest.markDeleted()
            }
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

    func initialFrameMetadata(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64
    ) -> ChatTimelineUnreadMetadata {
        ChatTimelineUnreadMetadata(
            unreadCount: 0,
            mentions: [],
            candidateCount: 0,
            initialFrameReadinessProof:
                ChatTimelineInitialFrameReadinessProof(
                    conversationKey: conversationKey,
                    baseGeneration: baseGeneration,
                    materializedLocalMessageCount:
                        max(0, materializedLocalMessageCount),
                    isSynced: true,
                    isInitialArchiveLoaded: true,
                    hasDurableArchiveReadiness: true,
                    archiveState: .unresolved(
                        primaryKey: LastChatsStorageItem.genPrimary(
                            jid: conversationKey.jid,
                            owner: conversationKey.owner,
                            conversationType:
                                conversationKey.conversationType
                        )
                    ),
                    chatFullArchiveLoaded: false,
                    loadedRanges: [],
                    knownGaps: [],
                    archiveBoundaryFingerprint: nil,
                    hasKnownRemoteArchiveBoundary: false,
                    latestMessageFingerprint: nil
                )
        )
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
