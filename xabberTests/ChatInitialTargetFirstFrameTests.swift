import XCTest
import RealmSwift
@testable import xabber

final class ChatInitialTargetFirstFrameTests: XCTestCase {
    private let owner = "romeo@example.org"
    private let jid = "juliet@example.org"
    private let conversationType =
        ClientSynchronizationManager.ConversationType.regular

    func testMappedTargetProducesCenteredAtomicAnchor() {
        let request = makeRequest(archivedID: "200")

        let plan = ChatInitialTargetFirstFramePolicy.plan(
            request: request,
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            resolvedTargetPrimary: "target-primary",
            viewportHeight: 800,
            targetHeight: 120
        )

        XCTAssertEqual(
            plan,
            .aligned(
                ChatViewportAnchor(
                    primary: "target-primary",
                    viewportRelativeMinY: 340
                )
            )
        )
        XCTAssertFalse(plan.shouldKeepSkeleton)
        XCTAssertTrue(plan.canCompletePreparation)
        XCTAssertTrue(plan.canPublishDatasource)
    }

    func testMissingMappedTargetKeepsSkeletonAndPreparationPending() {
        let plan = ChatInitialTargetFirstFramePolicy.plan(
            request: makeRequest(archivedID: "200"),
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            resolvedTargetPrimary: nil,
            viewportHeight: 800,
            targetHeight: nil
        )

        XCTAssertEqual(plan, .waitingForTarget)
        XCTAssertTrue(plan.shouldKeepSkeleton)
        XCTAssertFalse(plan.canCompletePreparation)
        XCTAssertFalse(plan.canPublishDatasource)
        XCTAssertNil(plan.restoreAnchor)
    }

    func testMissingPreparedLayoutKeepsSkeletonInsteadOfUsingZeroHeight() {
        let plan = ChatInitialTargetFirstFramePolicy.plan(
            request: makeRequest(archivedID: "200"),
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            resolvedTargetPrimary: "target-primary",
            viewportHeight: 800,
            targetHeight: nil
        )

        XCTAssertEqual(plan, .waitingForTarget)
    }

    func testForeignConversationDoesNotOwnInitialFrame() {
        let plan = ChatInitialTargetFirstFramePolicy.plan(
            request: makeRequest(archivedID: "200"),
            owner: "mercutio@example.org",
            jid: jid,
            conversationType: conversationType,
            resolvedTargetPrimary: "target-primary",
            viewportHeight: 800,
            targetHeight: 120
        )

        XCTAssertEqual(plan, .inactive)
        XCTAssertFalse(plan.shouldKeepSkeleton)
        XCTAssertFalse(plan.canCompletePreparation)
        XCTAssertTrue(plan.canPublishDatasource)
    }

    func testPreparationCompletionIsOneShot() {
        var completionCount = 0
        let context = ChatInitialTargetFirstFrameContext(
            request: makeRequest(archivedID: "200")
        ) {
            completionCount += 1
        }

        XCTAssertTrue(context.finishPreparationIfNeeded())
        XCTAssertFalse(context.finishPreparationIfNeeded())
        XCTAssertEqual(completionCount, 1)
    }

    func testTimeoutDropsCompletionButRetainsTargetOwnership() {
        let request = makeRequest(archivedID: "200")
        var completionCount = 0
        let context = ChatInitialTargetFirstFrameContext(request: request) {
            completionCount += 1
        }

        context.releasePreparationCompletion()

        XCTAssertEqual(context.request, request)
        XCTAssertFalse(context.isAwaitingPreparationCompletion)
        XCTAssertFalse(context.finishPreparationIfNeeded())
        XCTAssertEqual(completionCount, 0)
    }

    @MainActor
    func testTimeoutReinstallsTheActualSkeletonDatasource() {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.pendingOpenMessageRequest = makeRequest(archivedID: "200")
        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            completion: {}
        )
        controller.datasource[0].isFakeMessage = false
        controller.showSkeletonObserver.accept(false)

        controller.stackedNavigationPresentationPreparationDidTimeOut()

        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertFalse(controller.canLoadDatasource)
        XCTAssertEqual(
            controller.datasource.map(\.primary),
            ChatSkeletonTemplate.descriptors.map(\.primary)
        )
        XCTAssertTrue(
            controller.datasource.allSatisfy(\.isFakeMessage),
            "A timeout must restore fake rows, not only flip the skeleton relay"
        )
    }

    @MainActor
    func testTimeoutPreservesCurrentGenerationAlignedFrame() {
        let controller = makePreparingController(archivedID: "200")
        let request = try! XCTUnwrap(controller.pendingOpenMessageRequest)
        controller.datasource[0].isFakeMessage = false
        controller.showSkeletonObserver.accept(false)
        controller.canLoadDatasource = true
        controller.initialTargetFirstFrameContext?.markAlignedFrameCommitted(
            request: request,
            positionedPrimary: "target-primary",
            applyGeneration: controller.archiveWindowApplyGeneration,
            datasourceGeneration: controller.scrollResidentMetadataGeneration
        )

        controller.stackedNavigationPresentationPreparationDidTimeOut()

        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.canLoadDatasource)
        XCTAssertTrue(controller.datasource.contains { !$0.isFakeMessage })
    }

    @MainActor
    func testTimeoutRejectsAlignedFrameFromStaleApplyGeneration() {
        let controller = makePreparingController(archivedID: "200")
        let request = try! XCTUnwrap(controller.pendingOpenMessageRequest)
        controller.datasource[0].isFakeMessage = false
        controller.showSkeletonObserver.accept(false)
        controller.canLoadDatasource = true
        controller.initialTargetFirstFrameContext?.markAlignedFrameCommitted(
            request: request,
            positionedPrimary: "target-primary",
            applyGeneration: controller.archiveWindowApplyGeneration,
            datasourceGeneration: controller.scrollResidentMetadataGeneration
        )
        controller.archiveWindowApplyGeneration &+= 1

        controller.stackedNavigationPresentationPreparationDidTimeOut()

        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertFalse(controller.canLoadDatasource)
        XCTAssertEqual(
            controller.datasource.map(\.primary),
            ChatSkeletonTemplate.descriptors.map(\.primary)
        )
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
    }

    func testRetargetPreservesPreparationCompletion() {
        let first = makeRequest(archivedID: "200")
        let second = makeRequest(archivedID: "300")
        var completionCount = 0
        let context = ChatInitialTargetFirstFrameContext(request: first) {
            completionCount += 1
        }
        context.markAlignedFrameCommitted(
            request: first,
            positionedPrimary: "target-primary",
            applyGeneration: 7,
            datasourceGeneration: 11
        )
        context.retarget(to: second)

        XCTAssertEqual(context.request, second)
        XCTAssertTrue(context.isAwaitingPreparationCompletion)
        XCTAssertFalse(
            context.hasCommittedAlignedFrame(
                for: second,
                applyGeneration: 7,
                datasourceGeneration: 11
            ),
            "A superseding target must invalidate the old target's commit token"
        )
        XCTAssertTrue(context.finishPreparationIfNeeded())
        XCTAssertEqual(completionCount, 1)
    }

    func testAlignedFrameCommitRejectsCompetingDatasourceGeneration() {
        let request = makeRequest(archivedID: "200")
        let context = ChatInitialTargetFirstFrameContext(request: request) {}
        context.markAlignedFrameCommitted(
            request: request,
            positionedPrimary: "target-primary",
            applyGeneration: 7,
            datasourceGeneration: 11
        )

        XCTAssertTrue(
            context.hasCommittedAlignedFrame(
                for: request,
                applyGeneration: 7,
                datasourceGeneration: 11
            )
        )
        XCTAssertFalse(
            context.hasCommittedAlignedFrame(
                for: request,
                applyGeneration: 7,
                datasourceGeneration: 12
            ),
            "A competing datasource publication must invalidate first-frame proof"
        )
    }

    func testAlignedFrameInvalidationRetainsRequestAndCompletion() {
        let request = makeRequest(archivedID: "200")
        var completionCount = 0
        let context = ChatInitialTargetFirstFrameContext(request: request) {
            completionCount += 1
        }
        context.markAlignedFrameCommitted(
            request: request,
            positionedPrimary: "target-primary",
            applyGeneration: 7,
            datasourceGeneration: 11
        )

        context.invalidateAlignedFrameCommit()

        XCTAssertEqual(context.request, request)
        XCTAssertTrue(context.isAwaitingPreparationCompletion)
        XCTAssertFalse(
            context.hasCommittedAlignedFrame(
                for: request,
                applyGeneration: 7,
                datasourceGeneration: 11
            )
        )
        XCTAssertTrue(context.finishPreparationIfNeeded())
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testAdmissionRetargetsInitialFrameBeforeLoadedShortcut() {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        let first = makeRequest(archivedID: "200")
        let second = makeRequest(archivedID: "300")
        controller.initialTargetFirstFrameContext =
            ChatInitialTargetFirstFrameContext(request: first) {}
        controller.pendingOpenMessageRequest = first

        XCTAssertTrue(
            controller.protectInitialTargetFirstFrameIfNeeded(for: second)
        )
        XCTAssertEqual(
            controller.initialTargetFirstFrameContext?.request,
            second
        )
        XCTAssertTrue(
            controller.initialTargetFirstFrameContext?
                .isAwaitingPreparationCompletion ?? false
        )
    }

    @MainActor
    func testTerminalCleanupDropsOnlyTheMatchingInitialFrameContext() {
        let controller = ChatViewController()
        let first = makeRequest(archivedID: "200")
        let second = makeRequest(archivedID: "300")
        controller.initialTargetFirstFrameContext =
            ChatInitialTargetFirstFrameContext(request: second) {}

        XCTAssertFalse(
            controller.clearInitialTargetFirstFrameProtectionIfMatching(first)
        )
        XCTAssertEqual(
            controller.initialTargetFirstFrameContext?.request,
            second
        )
        XCTAssertTrue(
            controller.clearInitialTargetFirstFrameProtectionIfMatching(second)
        )
        XCTAssertNil(controller.initialTargetFirstFrameContext)
    }

    @MainActor
    func testAlignedFirstFrameCommitTerminatesPendingRequestWithoutLoadedPositionReplay() throws {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded()
        controller.cancelStackedNavigationPresentationPreparation()
        controller.isStackedNavigationPresentationPreparationCancelled = false
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.datasource = [makeDatasource()]
        controller.datasourceSnapshot = ChatDatasourceCoordinator.makeSnapshot(
            items: controller.datasource
        )
        controller.showSkeletonObserver.accept(false)
        controller.loadDatasourceObserver.accept(true)
        controller.messagesCollectionView.reloadData()
        controller.view.layoutIfNeeded()

        let request = makeRequest(archivedID: "200")
        var preparationCompletionCount = 0
        controller.pendingOpenMessageRequest = request
        controller.initialTargetFirstFrameContext =
            ChatInitialTargetFirstFrameContext(request: request) {
                preparationCompletionCount += 1
            }
        controller.isPreparingStackedNavigationPresentation = true
        controller.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion = true
        controller.initialTargetFirstFrameContext?.markAlignedFrameCommitted(
            request: request,
            positionedPrimary: "target-primary",
            applyGeneration: controller.archiveWindowApplyGeneration,
            datasourceGeneration: controller.scrollResidentMetadataGeneration
        )

        let freshness = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 1,
            queryID: "initial-target-single-position"
        )
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
        let segment = try XCTUnwrap(
            ArchiveCoverageSegment(
                oldest: cursor,
                newest: cursor,
                reachesArchiveStart: true,
                reachesLiveEdge: true,
                fingerprint: freshness.fingerprint,
                isVerified: true
            )
        )
        controller.archiveWindowState = .verified(
            ArchiveWindowSnapshot(
                messagePrimaryIDs: ["target-primary"],
                target: .archiveID(cursor),
                verifiedSegment: segment,
                coverageGeneration: 1,
                freshnessToken: freshness
            )
        )
        controller.archiveWindowCommittedCoverageGeneration = 1

        var events: [String] = []
        controller.activeAnchorExecutionHooks = ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: false,
            onPositioningStarted: { events.append("started") },
            onFailed: { events.append("failed") },
            onPositioned: { events.append("positioned") }
        )
        var loadedPositioningCount = 0
        controller.loadedAnchorPositioningDriverForTests = { completion in
            loadedPositioningCount += 1
            completion(true)
        }
        var scheduledReadRequest: ChatOpenMessageRequest?
        controller.mentionReadOnVisibleSchedulingObserverForTests = {
            scheduledReadRequest = $0
        }
        var drainEvents: [ChatTimelinePresentationDrainLane] = []
        var drainProtectionStates: [Bool] = []
        controller.timelinePresentationLaneDrainObserverForTests = {
            drainEvents.append($0)
            drainProtectionStates.append(
                controller.initialTargetFirstFrameContext != nil
            )
        }
        let offsetBeforeCompletion =
            controller.messagesCollectionView.contentOffset.y

        controller.completeInitialTargetFirstFrameIfNeeded(
            request: request,
            applyGeneration: controller.archiveWindowApplyGeneration
        )

        XCTAssertEqual(preparationCompletionCount, 1)
        XCTAssertEqual(events, ["started", "positioned"])
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.activeAnchorExecutionState)
        XCTAssertEqual(
            controller.anchorTransactionGate.snapshot.lastTerminalOutcome,
            .positioned
        )
        XCTAssertEqual(controller.retainedMessageAnchor?.primary, "target-primary")
        XCTAssertEqual(scheduledReadRequest, request)
        XCTAssertEqual(loadedPositioningCount, 0)
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            offsetBeforeCompletion,
            accuracy: 0.001,
            "Semantic terminal completion must not reposition the committed frame"
        )
        XCTAssertEqual(
            drainEvents,
            [.store, .sensitiveReveal, .liveEdge],
            "The first drain remains protected by first-frame ownership"
        )
        XCTAssertEqual(drainProtectionStates, [true, true, true])

        controller.completeNavigationTransitionDeferral(cancelled: false)

        XCTAssertEqual(
            drainEvents,
            [
                .store, .sensitiveReveal, .liveEdge,
                .store, .sensitiveReveal, .liveEdge
            ],
            "Presentation lanes must drain again after first-frame protection releases"
        )
        XCTAssertEqual(
            drainProtectionStates,
            [true, true, true, false, false, false]
        )

        controller.performPendingOpenMessageRequestIfNeeded()

        XCTAssertEqual(
            loadedPositioningCount,
            0,
            "Navigation-transition release must not replay loaded positioning"
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            offsetBeforeCompletion,
            accuracy: 0.001
        )
    }

    @MainActor
    func testAlignedSearchFirstFramePreservesPersistentTargetSelection() {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded()
        controller.cancelStackedNavigationPresentationPreparation()
        controller.isStackedNavigationPresentationPreparationCancelled = false
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.datasource = [makeDatasource()]
        controller.datasourceSnapshot = ChatDatasourceCoordinator.makeSnapshot(
            items: controller.datasource
        )
        controller.showSkeletonObserver.accept(false)
        controller.loadDatasourceObserver.accept(true)
        controller.messagesCollectionView.reloadData()
        controller.view.layoutIfNeeded()

        let request = makeRequest(
            archivedID: "200",
            highlight: true,
            source: .search
        )
        controller.pendingOpenMessageRequest = request
        controller.initialTargetFirstFrameContext =
            ChatInitialTargetFirstFrameContext(request: request) {}
        controller.isPreparingStackedNavigationPresentation = true
        controller.initialTargetFirstFrameContext?.markAlignedFrameCommitted(
            request: request,
            positionedPrimary: "target-primary",
            applyGeneration: controller.archiveWindowApplyGeneration,
            datasourceGeneration: controller.scrollResidentMetadataGeneration
        )
        let targetCell = MessageContentCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 80)
        )
        controller.transientMessageHighlightCellProviderForTests = { _ in
            targetCell
        }

        controller.completeInitialTargetFirstFrameIfNeeded(
            request: request,
            applyGeneration: controller.archiveWindowApplyGeneration
        )

        XCTAssertTrue(targetCell.isSelected())
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertEqual(
            controller.anchorTransactionGate.snapshot.lastTerminalOutcome,
            .positioned
        )
    }

    @MainActor
    func testAlignedFirstFrameDoesNotConsumeSupersedingPendingRequest() {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        let committedRequest = makeRequest(archivedID: "200")
        let supersedingRequest = makeRequest(archivedID: "300")
        let context = ChatInitialTargetFirstFrameContext(
            request: committedRequest,
            completion: {}
        )
        context.markAlignedFrameCommitted(
            request: committedRequest,
            positionedPrimary: "target-primary",
            applyGeneration: controller.archiveWindowApplyGeneration,
            datasourceGeneration: controller.scrollResidentMetadataGeneration
        )
        controller.initialTargetFirstFrameContext = context
        controller.pendingOpenMessageRequest = supersedingRequest

        controller.completeInitialTargetFirstFrameIfNeeded(
            request: committedRequest,
            applyGeneration: controller.archiveWindowApplyGeneration
        )

        XCTAssertEqual(controller.pendingOpenMessageRequest, supersedingRequest)
        XCTAssertTrue(controller.initialTargetFirstFrameContext === context)
        XCTAssertNil(
            controller.anchorTransactionGate.snapshot.lastTerminalOutcome
        )
    }

    func testVerifiedArchiveApplyWiresTargetPlanIntoAtomicTransaction() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
                ),
            encoding: .utf8
        )
        let method = try XCTUnwrap(
            source.range(
                of: "private func applyArchiveEngineVerifiedSnapshot("
            )
        )
        let tail = source[method.lowerBound...]
        let nextMethod = try XCTUnwrap(
            tail.range(of: "private func captureArchiveEngineBoundaryAnchor(")
        )
        let body = String(tail[..<nextMethod.lowerBound])

        for marker in [
            "ChatInitialTargetFirstFramePolicy.plan(",
            "anchorRestorePhase: effectiveRestoreAnchor == nil",
            "restoreAnchor: effectiveRestoreAnchor",
            "guard targetFirstFramePlan.canPublishDatasource else",
            "initialTargetFirstFrameContext?.retarget(to:",
            "completeInitialTargetFirstFrameIfNeeded("
        ] {
            XCTAssertTrue(
                body.contains(marker),
                "Verified archive apply is missing initial-target first-frame marker: \(marker)"
            )
        }
        let publicationGuard = try XCTUnwrap(
            body.range(of: "guard targetFirstFramePlan.canPublishDatasource else")
        )
        let apply = try XCTUnwrap(
            body.range(of: "self.applyChatDatasource(")
        )
        XCTAssertLessThan(
            publicationGuard.lowerBound,
            apply.lowerBound,
            "Unaligned real rows must be rejected before the atomic datasource transaction begins"
        )
    }

    func testQueueAdmissionRoutesProtectedTargetThroughArchiveBeforeLocalShortcut() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
                ),
            encoding: .utf8
        )
        let method = try XCTUnwrap(
            source.range(of: "internal func queueOpenMessageRequest(")
        )
        let tail = source[method.lowerBound...]
        let nextMethod = try XCTUnwrap(
            tail.range(of: "private func isArchiveTargetHandoffReady(")
        )
        let body = String(tail[..<nextMethod.lowerBound])
        let protection = try XCTUnwrap(
            body.range(of: "protectInitialTargetFirstFrameIfNeeded(for: request)")
        )
        let loadedShortcut = try XCTUnwrap(
            body.range(of: "performLoadedOpenMessageRequestIfPossible")
        )
        let protectedArchiveRoute = try XCTUnwrap(
            body.range(of: "if protectsInitialTargetFirstFrame")
        )
        let localShortcut = try XCTUnwrap(
            body.range(of: "startProofScopedLocalOpenMessageRequestIfPossible")
        )

        XCTAssertLessThan(protection.lowerBound, loadedShortcut.lowerBound)
        XCTAssertLessThan(protectedArchiveRoute.lowerBound, localShortcut.lowerBound)
        XCTAssertTrue(
            body[protectedArchiveRoute.lowerBound...]
                .contains(
                    "submitProtectedInitialTargetFirstFrameToArchive(request)"
                )
        )

        let archiveSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            archiveSource.contains(
                "internal func submitProtectedInitialTargetFirstFrameToArchive("
            )
        )
        XCTAssertTrue(
            archiveSource.contains("return submitArchiveEngineTarget(request)")
        )
    }

    func testPendingResumePreservesProtectedArchiveRouteBeforeLocalShortcut() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
            ),
            encoding: .utf8
        )
        let method = try XCTUnwrap(
            source.range(
                of: "private func resumePendingOpenMessageRequestThroughCurrentRoute()"
            )
        )
        let tail = source[method.lowerBound...]
        let nextMethod = try XCTUnwrap(
            tail.range(of: "private func handleSuppressedOpenMessageRequest(")
        )
        let body = String(tail[..<nextMethod.lowerBound])
        let protection = try XCTUnwrap(
            body.range(of: "isProtectingInitialTargetFirstFrame(request)")
        )
        let protectedArchiveRoute = try XCTUnwrap(
            body.range(
                of: "submitProtectedInitialTargetFirstFrameToArchive(request)"
            )
        )
        let localShortcut = try XCTUnwrap(
            body.range(of: "startProofScopedLocalOpenMessageRequestIfPossible")
        )

        XCTAssertLessThan(protection.lowerBound, localShortcut.lowerBound)
        XCTAssertLessThan(protectedArchiveRoute.lowerBound, localShortcut.lowerBound)
    }

    func testAnchorTerminalCleanupDropsOnlyItsOwnedInitialFrameContext() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
            ),
            encoding: .utf8
        )
        for methodName in [
            "private func failActiveAnchorExecution(",
            "private func cancelActiveAnchorExecution("
        ] {
            let method = try XCTUnwrap(source.range(of: methodName))
            let body = String(source[method.lowerBound...].prefix(2_500))
            XCTAssertTrue(
                body.contains(
                    "clearInitialTargetFirstFrameProtectionIfMatching("
                ),
                "\(methodName) must terminate protection owned by the same request"
            )
        }
    }

    func testStorePresentationWaitsForInitialTargetPreparationCommit() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )
        let method = try XCTUnwrap(
            source.range(of: "private func timelineStoreSnapshotPresentationAction(")
        )
        let body = String(source[method.lowerBound...].prefix(2_500))

        XCTAssertTrue(
            body.contains(
                "initialTargetFirstFrameContext?.isAwaitingPreparationCompletion"
            ),
            "Store applies must remain deferred until the aligned first frame releases navigation"
        )
    }

    func testAdmittedStoreApplyInvalidatesAlignedFrameBeforeDatasourceCommit() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )
        let method = try XCTUnwrap(
            source.range(of: "private func applyMappedTimelineStoreSnapshot(")
        )
        let body = String(source[method.lowerBound...].prefix(12_000))
        let admission = try XCTUnwrap(
            body.range(of: "timelineStoreRemoteApplyExclusionGate.beginStoreApply")
        )
        let invalidation = try XCTUnwrap(
            body.range(
                of: "initialTargetFirstFrameContext?.invalidateAlignedFrameCommit()"
            )
        )
        let apply = try XCTUnwrap(body.range(of: "applyChatDatasource("))

        XCTAssertLessThan(admission.lowerBound, invalidation.lowerBound)
        XCTAssertLessThan(invalidation.lowerBound, apply.lowerBound)
    }

    @MainActor
    func testPendingTargetHoldsStackedPreparationUntilTargetCommitOrTimeout() {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        let request = makeRequest(archivedID: "200")
        controller.pendingOpenMessageRequest = request

        var completionCount = 0
        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(controller.isPreparingStackedNavigationPresentation)
        XCTAssertEqual(
            controller.initialTargetFirstFrameContext?.request,
            request
        )

        controller.stackedNavigationPresentationPreparationDidTimeOut()

        XCTAssertEqual(completionCount, 0)
        XCTAssertFalse(controller.isPreparingStackedNavigationPresentation)
        XCTAssertEqual(
            controller.initialTargetFirstFrameContext?.request,
            request,
            "Timeout may release navigation, but the skeleton must retain target ownership until a correct frame commits"
        )
        XCTAssertFalse(
            controller.initialTargetFirstFrameContext?
                .isAwaitingPreparationCompletion ?? true
        )
    }

    @MainActor
    func testLateVerifiedOMEMOPageAfterNavigationTimeoutReplacesSkeletonAndFinishesExactLocalTarget() async throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "LateVerifiedOMEMOTarget-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let item = MessageStorageItem()
        item.primary = "late-verified-target"
        item.messageId = "2e9a7778-0bd7-4a81-b0bc-9dd63ef0e6ae"
        item.owner = owner
        item.opponent = jid
        item.conversationType = .omemo
        item.archivedId = "200"
        item.mamArchiveId = "200"
        item.date = Date(timeIntervalSince1970: 1_700_000_000)
        item.sentDate = item.date
        item.body = "Verified delayed OMEMO page"
        item.legacyBody = item.body
        try realm.write { realm.add(item) }

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .omemo
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let request = ChatOpenMessageRequest(chatJid: jid, owner: owner, conversationType: .omemo,
            anchor: .init(messagePrimary: item.primary, archivedId: nil, archiveCursor: nil,
                          messageId: item.messageId, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)
        controller.pendingOpenMessageRequest = request
        var oldNavigationCompletionCount = 0
        controller.initialTargetFirstFrameContext = .init(request: request) { oldNavigationCompletionCount += 1 }
        controller.isPreparingStackedNavigationPresentation = true
        controller.isStackedNavigationPresentationPreparationCancelled = false
        controller.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion = true
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: owner, jid: jid, conversationType: .omemo),
            pageSize: ArchivePageSizing.history,
            conversationKey: .init(owner: owner, jid: jid, conversationType: .omemo),
            observesStoreImmediately: false)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = ArchiveWindowIntent(
            conversation: .init(owner: owner, jid: jid, conversationType: .omemo), locator: .latest,
            contextBefore: ArchivePageSizing.initial, contextAfter: 0, priority: .visibleIntegrity)
        controller.archiveWindowState = .skeleton(reason: .opening, target: .latest)
        controller.setSkeletonVisible(true)
        _ = controller.commitArchiveEngineOpeningSkeletonSynchronously()
        defer { controller.stopArchiveEnginePresentationSubscription() }

        controller.stackedNavigationPresentationPreparationDidTimeOut()
        controller.completeNavigationTransitionDeferral(cancelled: false)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertNotNil(controller.initialTargetFirstFrameContext)
        var duplicateLoadedPositionCount = 0
        controller.loadedAnchorPositioningDriverForTests = { completion in
            duplicateLoadedPositionCount += 1
            completion(true)
        }
        let published = expectation(description: "late verified target reaches UIKit after timeout")
        published.assertForOverFulfill = false
        controller.datasourceDidSetForTests = { rows in
            if rows.contains(where: { $0.primary == item.primary && !$0.isFakeMessage }) { published.fulfill() }
        }
        let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "late-verified-omemo")
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
        let segment = try XCTUnwrap(ArchiveCoverageSegment(oldest: cursor, newest: cursor,
            reachesArchiveStart: true, reachesLiveEdge: true, fingerprint: freshness.fingerprint, isVerified: true))
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.receiveArchiveWindowState(.verified(ArchiveWindowSnapshot(
            messagePrimaryIDs: [item.primary], target: .latest, verifiedSegment: segment,
            coverageGeneration: 1, freshnessToken: freshness)))
        await fulfillment(of: [published], timeout: 3)
        // The atomic UIKit receipt follows datasource publication on the same main lane.
        for _ in 0..<200 where controller.pendingOpenMessageRequest != nil || controller.initialTargetFirstFrameContext != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.canLoadDatasource)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.initialTargetFirstFrameContext, "The winning frame receipt must release completed target ownership")
        XCTAssertEqual(duplicateLoadedPositionCount, 0, "The atomic archive frame already positioned the target; its receipt must be the sole terminal owner")
        XCTAssertEqual(oldNavigationCompletionCount, 0, "The expired navigation completion must not be revived")
        XCTAssertEqual(controller.timelineSession?.snapshot.items.map(\.primary), [item.primary])
        XCTAssertEqual(controller.messagesCollectionView.numberOfSections, controller.datasource.count)
    }

    @MainActor
    func testPendingLoadedNavigationWaitsOnlyForMatchingCurrentAlignedFirstFrameReceipt() throws {
        for state in ["matching", "stale-apply", "stale-datasource", "not-aligned", "invalidated", "newer-request"] {
            let request = makeRequest(archivedID: "200", source: .directOpenAtMessage)
            let controller = ChatViewController()
            controller.owner = owner
            controller.jid = jid
            controller.conversationType = conversationType
            controller.ownerSender = Sender(id: owner, displayName: owner)
            controller.opponentSender = Sender(id: jid, displayName: jid)
            controller.loadViewIfNeeded()
            controller.stopArchiveEnginePresentationSubscription()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            controller.datasource = [makeDatasource()]
            controller.datasourceSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: controller.datasource)
            controller.showSkeletonObserver.accept(false)
            controller.loadDatasourceObserver.accept(true)
            controller.messagesCollectionView.reloadData()
            controller.view.layoutIfNeeded()
            let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "pending-frame-receipt")
            let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
            let segment = try XCTUnwrap(ArchiveCoverageSegment(oldest: cursor, newest: cursor,
                reachesArchiveStart: true, reachesLiveEdge: true, fingerprint: freshness.fingerprint, isVerified: true))
            controller.archiveWindowState = .verified(.init(messagePrimaryIDs: ["target-primary"], target: .archiveID(cursor),
                verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness))
            controller.archiveWindowCommittedCoverageGeneration = 1
            controller.pendingOpenMessageRequest = request
            let contextRequest = state == "newer-request" ? makeRequest(archivedID: "200", source: .savedVisiblePosition) : request
            let context = ChatInitialTargetFirstFrameContext(request: contextRequest) {}
            context.releasePreparationCompletion()
            controller.initialTargetFirstFrameContext = context
            if state != "not-aligned" {
                context.markAlignedFrameCommitted(request: contextRequest, positionedPrimary: "target-primary",
                    applyGeneration: controller.archiveWindowApplyGeneration,
                    datasourceGeneration: controller.scrollResidentMetadataGeneration)
            }
            if state == "stale-apply" { controller.archiveWindowApplyGeneration &+= 1 }
            if state == "stale-datasource" { controller.scrollResidentMetadataGeneration &+= 1 }
            if state == "invalidated" { context.invalidateAlignedFrameCommit() }
            var loadedPositions = 0
            controller.loadedAnchorPositioningDriverForTests = { completion in loadedPositions += 1; completion(true) }

            controller.performPendingOpenMessageRequestIfNeeded()

            XCTAssertEqual(loadedPositions, state == "matching" ? 0 : 1, state)
            XCTAssertEqual(controller.pendingOpenMessageRequest != nil, state == "matching", state)
            controller.stopArchiveEnginePresentationSubscription()
        }
    }

    @MainActor
    func testSequentialLatestReopenKeepsPendingLiveTargetUntilFreshVerifiedPageWins() async throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "SequentialLatestReopen-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        func row(_ suffix: String, cursor: String) -> MessageStorageItem {
            let item = MessageStorageItem()
            item.primary = "sequential-\(suffix)"
            item.messageId = "message-\(suffix)"
            item.owner = owner
            item.opponent = jid
            item.conversationType = .omemo
            item.archivedId = cursor
            item.mamArchiveId = cursor
            item.date = Date(timeIntervalSince1970: 1_700_000_000 + (suffix == "A" ? 0 : 1))
            item.sentDate = item.date
            item.body = "Verified sequential \(suffix)"
            item.legacyBody = item.body
            return item
        }
        func request(_ item: MessageStorageItem) -> ChatOpenMessageRequest {
            .init(chatJid: jid, owner: owner, conversationType: .omemo,
                anchor: .init(messagePrimary: item.primary, archivedId: nil, archiveCursor: nil,
                    messageId: item.messageId, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
                highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)
        }
        func page(_ primaries: [String], newest: String, generation: UInt64) throws -> ArchiveWindowSnapshot {
            let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "sequential-\(generation)")
            let ledger = try primaries.map { primary in
                let message = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
                return try XCTUnwrap(ArchiveCursor(rawValue: message.mamArchiveId))
            }
            let segment = try XCTUnwrap(ArchiveCoverageSegment(
                oldest: try XCTUnwrap(ArchiveCursor(rawValue: "200")),
                newest: try XCTUnwrap(ArchiveCursor(rawValue: newest)),
                reachesArchiveStart: true, reachesLiveEdge: true,
                fingerprint: freshness.fingerprint, isVerified: true,
                orderedArchiveIDs: ledger))
            return .init(messagePrimaryIDs: primaries, target: .latest, verifiedSegment: segment,
                coverageGeneration: generation, freshnessToken: freshness)
        }
        let a = row("A", cursor: "200")
        try realm.write { realm.add(a) }
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .omemo
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: owner, jid: jid, conversationType: .omemo),
            pageSize: ArchivePageSizing.history,
            conversationKey: .init(owner: owner, jid: jid, conversationType: .omemo),
            observesStoreImmediately: false)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = .init(conversation: .init(owner: owner, jid: jid, conversationType: .omemo),
            locator: .latest, contextBefore: ArchivePageSizing.initial, contextAfter: 0, priority: .visibleIntegrity)
        defer { controller.stopArchiveEnginePresentationSubscription() }
        var loadedPositions = 0
        controller.loadedAnchorPositioningDriverForTests = { completion in loadedPositions += 1; completion(true) }
        let requestA = request(a)
        var completedA = 0
        controller.pendingOpenMessageRequest = requestA
        controller.initialTargetFirstFrameContext = .init(request: requestA) { completedA += 1 }
        controller.isPreparingStackedNavigationPresentation = true
        controller.isStackedNavigationPresentationPreparationCancelled = false
        controller.archiveWindowState = .skeleton(reason: .opening, target: .latest)
        controller.setSkeletonVisible(true)
        _ = controller.commitArchiveEngineOpeningSkeletonSynchronously()
        let oldPage = try page([a.primary], newest: "200", generation: 1)
        controller.receiveArchiveWindowState(.verified(oldPage))
        for _ in 0..<400 where controller.pendingOpenMessageRequest != nil || controller.initialTargetFirstFrameContext != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(completedA, 1)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.initialTargetFirstFrameContext)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.timelineSession?.snapshot.items.map(\.primary), [a.primary])
        let oldApplyGeneration = controller.archiveWindowApplyGeneration

        // B is a real durable live row; its raw stanza ID is not MAM proof.
        let b = row("B", cursor: "300")
        b.mamArchiveId = ""
        try realm.write { realm.add(b) }
        let requestB = request(b)
        controller.queueOpenMessageRequest(requestB)
        var completedB = 0
        controller.initialTargetFirstFrameContext = .init(request: requestB) { completedB += 1 }
        controller.isPreparingStackedNavigationPresentation = true
        controller.receiveArchiveWindowState(.skeleton(reason: .loadingTarget, target: .latest))
        var publishedWrongTarget = false
        var freshBSubmitted = false
        var publishedRealRowBeforeFreshProof = false
        controller.datasourceDidSetForTests = { [weak controller] rows in
            guard let controller else { return }
            if !freshBSubmitted && rows.contains(where: { !$0.isFakeMessage }) {
                publishedRealRowBeforeFreshProof = true
            }
            if controller.pendingOpenMessageRequest == requestB && rows.contains(where: { !$0.isFakeMessage && $0.primary != b.primary }) && !rows.contains(where: { $0.primary == b.primary }) {
                publishedWrongTarget = true
            }
        }
        controller.receiveArchiveWindowState(.verified(oldPage))
        for _ in 0..<400 where controller.archiveWindowAtomicApplyRetryCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(controller.archiveWindowAtomicApplyRetryCount, 0, "The actual stale page must reach the target-publication guard")
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(controller.pendingOpenMessageRequest, requestB)
        XCTAssertEqual(controller.initialTargetFirstFrameContext?.request, requestB)
        XCTAssertEqual(completedB, 0)
        XCTAssertFalse(publishedWrongTarget)
        XCTAssertFalse(publishedRealRowBeforeFreshProof, "Neither A nor raw durable B may be published before fresh proof")
        controller.completeInitialTargetFirstFrameIfNeeded(request: requestA, applyGeneration: oldApplyGeneration)
        XCTAssertEqual(controller.pendingOpenMessageRequest, requestB, "A's old receipt cannot finish B")

        // Only the subsequent real MAM materialization establishes B's cursor.
        try realm.write { b.mamArchiveId = "300" }
        let freshPage = try page([a.primary, b.primary], newest: "300", generation: 2)
        freshBSubmitted = true
        controller.receiveArchiveWindowState(.verified(freshPage))
        for _ in 0..<400 where controller.pendingOpenMessageRequest != nil || controller.initialTargetFirstFrameContext != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.canLoadDatasource)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.initialTargetFirstFrameContext)
        XCTAssertEqual(completedA, 1)
        XCTAssertEqual(completedB, 1)
        XCTAssertEqual(controller.retainedMessageAnchor?.primary, b.primary)
        XCTAssertEqual(controller.archiveWindowCommittedCoverageGeneration, 2)
        XCTAssertEqual(controller.timelineSession?.verifiedScope?.coverageGeneration, 2)
        XCTAssertEqual(controller.timelineSession?.snapshot.items.map(\.primary), [a.primary, b.primary])
        XCTAssertEqual(loadedPositions, 0, "Only the winning atomic frame may position either target")
        XCTAssertFalse(publishedWrongTarget)
        XCTAssertFalse(publishedRealRowBeforeFreshProof, "Neither A nor raw durable B may be published before fresh proof")
    }

    @MainActor
    func testReusedVerifiedChatQueuesPrimaryOnlyCurrentLiveTailThroughOwnedLatest() async throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ReusedPrimaryLiveTail-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let accountOwner = "live-target-\(UUID().uuidString.lowercased())@example.org"
        let previousUsers = AccountManager.shared.users
        let account = Account(jid: accountOwner, queue: DispatchQueue(label: "ReusedPrimaryLiveTail-account"))
        AccountManager.shared.users = previousUsers + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }
        let key = ArchiveConversationKey(owner: accountOwner, jid: jid, conversationType: .omemo)
        func row(_ id: String, mamID: String) -> MessageStorageItem {
            let item = MessageStorageItem()
            item.messageId = id
            item.primary = MessageStorageItem.genPrimary(messageId: id, owner: accountOwner)
            item.owner = accountOwner
            item.opponent = jid
            item.conversationType = .omemo
            item.archivedId = mamID.isEmpty ? "opaque-live-reference" : mamID
            item.mamArchiveId = mamID
            item.date = Date(timeIntervalSince1970: 1_700_000_000 + (mamID.isEmpty ? 1 : 0))
            item.sentDate = item.date
            item.body = "Authenticated live \(id)"
            item.legacyBody = item.body
            item.state = .deliver
            item.systemMetadata = ["omemo_authenticated_sender_v1": ["owner": accountOwner,
                "jid": jid, "deviceID": 42, "fingerprint": String(repeating: "a", count: 64), "trusted": true]]
            return item
        }
        let a = row("reuse-A", mamID: "200")
        try realm.write { realm.add(a) }
        let controller = ChatViewController()
        controller.owner = accountOwner
        controller.jid = jid
        controller.conversationType = .omemo
        controller.ownerSender = Sender(id: accountOwner, displayName: accountOwner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: accountOwner, jid: jid, conversationType: .omemo),
            pageSize: ArchivePageSizing.history, conversationKey: .init(owner: accountOwner, jid: jid, conversationType: .omemo), observesStoreImmediately: false)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = .init(conversation: key, locator: .latest,
            contextBefore: ArchivePageSizing.initial, contextAfter: 0, priority: .visibleIntegrity)
        let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "old-reused-latest")
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
        let segment = try XCTUnwrap(ArchiveCoverageSegment(oldest: cursor, newest: cursor,
            reachesArchiveStart: true, reachesLiveEdge: true, fingerprint: freshness.fingerprint, isVerified: true))
        controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: [a.primary], target: .latest,
            verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness)))
        for _ in 0..<400 where controller.timelineSession?.verifiedScope == nil || controller.showSkeletonObserver.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(controller.timelineSession?.snapshot.items.map(\.primary), [a.primary])
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertNil(controller.initialTargetFirstFrameContext)
        let oldIntent = try XCTUnwrap(controller.archiveWindowIntent)
        let oldApplyGeneration = controller.archiveWindowApplyGeneration
        let demandID = UUID()
        await account.archiveEngine.attachPresentationDemand(for: key, demandID: demandID)
        controller.archiveEnginePresentationDemandID = demandID
        controller.archiveEnginePresentationDemandConversation = key
        controller.archiveEnginePresentationDemandEngine = account.archiveEngine
        defer { controller.stopArchiveEnginePresentationSubscription() }

        let b = row("reuse-B", mamID: "")
        b.outgoing = true // W carbon on T belongs to the same account as the sender.
        b.systemMetadata = ["omemo_authenticated_sender_v1": ["owner": accountOwner,
            "jid": accountOwner, "deviceID": 1761201430,
            "fingerprint": "868390cb 370b3b6c e0e40203 807fff0e f0ecbd23 2a4e3a56 ceec64d8 ff6c133d", "trusted": true]]
        try realm.write {
            realm.add(b)
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: accountOwner, conversationType: .omemo)
            chat.owner = accountOwner
            chat.jid = jid
            chat.conversationType = .omemo
            chat.lastMessage = b
            chat.lastMessageId = b.messageId
            realm.add(chat)
        }
        let request = ChatOpenMessageRequest(chatJid: jid, owner: accountOwner, conversationType: .omemo,
            anchor: .init(messagePrimary: b.primary, archivedId: nil, archiveCursor: nil,
                messageId: b.messageId, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)

        let chat = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: accountOwner, conversationType: .omemo)))
        let authenticatedMetadata = b.systemMetadata
        for invalid in ["non-current-tail-without-reference", "hidden", "deleted", "tombstone", "expired",
                        "foreign-owner", "foreign-peer", "foreign-type", "wrong-message-id", "missing-auth", "malformed-fingerprint", "malformed-grouping", "foreign-auth-sender", "missing-reference", "mismatched-tail-id-without-reference"] {
            try realm.write {
                switch invalid {
                case "non-current-tail-without-reference":
                    chat.lastMessage = a
                    b.archivedId = ""
                case "hidden": b.isLocallyHiddenByReport = true
                case "deleted": b.isDeleted = true
                case "tombstone": b.deleteState = .autoDeleted
                case "expired": b.autoDeleteExpiresAt = 1
                case "foreign-owner": b.owner = "other@example.org"
                case "foreign-peer": b.opponent = "other@example.org"
                case "foreign-type": b.conversationType = .regular
                case "wrong-message-id": b.messageId = "different-message"
                case "missing-auth": b.systemMetadata = nil
                case "malformed-fingerprint":
                    var auth = authenticatedMetadata?["omemo_authenticated_sender_v1"] as? [String: Any] ?? [:]
                    auth["fingerprint"] = "868390cb not-a-native-fingerprint"
                    b.systemMetadata = ["omemo_authenticated_sender_v1": auth]
                case "malformed-grouping":
                    var auth = authenticatedMetadata?["omemo_authenticated_sender_v1"] as? [String: Any] ?? [:]
                    auth["fingerprint"] = String(repeating: "a ", count: 32)
                    b.systemMetadata = ["omemo_authenticated_sender_v1": auth]
                case "foreign-auth-sender":
                    var auth = authenticatedMetadata?["omemo_authenticated_sender_v1"] as? [String: Any] ?? [:]
                    auth["jid"] = jid
                    b.systemMetadata = ["omemo_authenticated_sender_v1": auth]
                case "mismatched-tail-id-without-reference":
                    chat.lastMessageId = "newer-live-C"
                    b.archivedId = ""
                default: b.archivedId = ""
                }
            }
            controller.queueOpenMessageRequest(request)
            XCTAssertNil(controller.pendingOpenMessageRequest, invalid)
            XCTAssertNil(controller.initialTargetFirstFrameContext, invalid)
            XCTAssertEqual(controller.archiveWindowIntent?.id, oldIntent.id, "No latest handoff for \(invalid)")
            try realm.write {
                chat.lastMessage = b
                chat.lastMessageId = "reuse-B"
                b.isLocallyHiddenByReport = false
                b.isDeleted = false
                b.deleteState = .visible
                b.autoDeleteExpiresAt = -1
                b.owner = accountOwner
                b.opponent = jid
                b.conversationType = .omemo
                b.messageId = "reuse-B"
                b.systemMetadata = authenticatedMetadata
                b.archivedId = "opaque-live-reference"
            }
        }

        // The real reused-controller entry point must create the handoff itself.
        // Do not install a B context, skeleton, cursor or verified page in this test.
        let previousTransactionCount = controller.anchorTransactionGate.snapshot.transactionBeginCount
        controller.queueOpenMessageRequest(request)

        XCTAssertEqual(controller.pendingOpenMessageRequest, request, "A live primary-only target must survive normal expanded-chat reuse")
        XCTAssertNotEqual(controller.archiveWindowIntent?.id, oldIntent.id, "A new owned latest request must revalidate the outgrown cache")
        XCTAssertEqual(controller.archiveWindowIntent?.locator, .latest)
        XCTAssertEqual(controller.archiveWindowTargetOpenRequest, request)
        XCTAssertTrue(controller.showSkeletonObserver.value, "Old verified A cannot be presented as successful B navigation")
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertNotNil(controller.anchorTransactionGate.snapshot.activeToken)
        XCTAssertGreaterThan(controller.anchorTransactionGate.snapshot.transactionBeginCount, previousTransactionCount)
        XCTAssertEqual(b.mamArchiveId, "", "A raw stanza reference must never be promoted to an archive cursor")
        XCTAssertEqual(controller.initialTargetFirstFrameContext?.request, request,
            "Normal queue(B), not the fixture, must create exact first-frame ownership")
        let requestA = ChatOpenMessageRequest(chatJid: jid, owner: accountOwner, conversationType: .omemo,
            anchor: .init(messagePrimary: a.primary, archivedId: nil, archiveCursor: nil,
                messageId: a.messageId, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)
        controller.completeInitialTargetFirstFrameIfNeeded(request: requestA, applyGeneration: oldApplyGeneration)
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)
        XCTAssertEqual(controller.initialTargetFirstFrameContext?.request, request)
        controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: [a.primary], target: .latest,
            verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness)))
        for _ in 0..<400 where controller.archiveWindowAtomicApplyRetryCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(controller.archiveWindowAtomicApplyRetryCount, 0)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage), "Old A cannot stand in for B")
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)

        // Only a subsequent owned MAM materialization can grant B a cursor.
        try realm.write { b.mamArchiveId = "300" }
        let freshToken = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "fresh-reused-latest")
        let freshSegment = try XCTUnwrap(ArchiveCoverageSegment(oldest: cursor,
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "300")), reachesArchiveStart: true,
            reachesLiveEdge: true, fingerprint: freshToken.fingerprint, isVerified: true,
            orderedArchiveIDs: try [a, b].map { try XCTUnwrap(ArchiveCursor(rawValue: $0.mamArchiveId)) }))
        controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: [a.primary, b.primary], target: .latest,
            verifiedSegment: freshSegment, coverageGeneration: 2, freshnessToken: freshToken)))
        for _ in 0..<400 where controller.pendingOpenMessageRequest != nil || controller.initialTargetFirstFrameContext != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.initialTargetFirstFrameContext)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.retainedMessageAnchor?.primary, b.primary)
        XCTAssertEqual(controller.timelineSession?.verifiedScope?.coverageGeneration, 2)
        XCTAssertEqual(controller.anchorTransactionGate.snapshot.lastTerminalOutcome, .positioned)
    }

    @MainActor
    func testReusedLiveImageRouteSurvivesMAMCursorCommitBeforeWindowPresentation() async throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ReusedMaterializedMedia-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let accountOwner = "materialized-media-\(UUID().uuidString.lowercased())@example.org"
        let previousUsers = AccountManager.shared.users
        let account = Account(jid: accountOwner, queue: DispatchQueue(label: "ReusedMaterializedMedia-account"))
        AccountManager.shared.users = previousUsers + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }
        let key = ArchiveConversationKey(owner: accountOwner, jid: jid, conversationType: .omemo)
        func row(_ id: String, mamID: String, image: Bool) -> MessageStorageItem {
            let item = MessageStorageItem()
            item.messageId = id
            item.primary = MessageStorageItem.genPrimary(messageId: id, owner: accountOwner)
            item.owner = accountOwner; item.opponent = jid; item.conversationType = .omemo
            item.archivedId = mamID.isEmpty ? "opaque-live-reference" : mamID
            item.mamArchiveId = mamID
            item.date = Date(timeIntervalSince1970: 1_700_000_000 + (mamID.isEmpty ? 1 : 0))
            item.sentDate = item.date
            item.body = image ? "QA3 image \(id)" : "Prior text \(id)"
            item.legacyBody = item.body
            item.state = .deliver
            item.outgoing = true
            item.systemMetadata = ["omemo_authenticated_sender_v1": ["owner": accountOwner,
                "jid": accountOwner, "deviceID": 101,
                "fingerprint": String(repeating: "a", count: 64), "trusted": true]]
            if image {
                let reference = MessageReferenceStorageItem()
                reference.primary = id + "-image-reference"
                reference.owner = accountOwner; reference.jid = jid; reference.conversationType = .omemo
                reference.messageId = id; reference.kind = .media; reference.mimeType = "image"
                // No remote URL: exercise the normal mapped image geometry and
                // placeholder without issuing thumbnail or attachment requests.
                reference.metadata = ["width": 64, "height": 64, "name": "QA3-image.png",
                    "media-type": "image/png", "size": 14205]
                item.references.append(reference)
            }
            return item
        }
        let history = (0..<12).map { row("history-\($0)", mamID: String(100 + $0), image: false) }
        let a = row("media-A", mamID: "200", image: true)
        let oldRows = history + [a]
        try realm.write { realm.add(oldRows) }
        let controller = ChatViewController()
        controller.owner = accountOwner; controller.jid = jid; controller.conversationType = .omemo
        controller.ownerSender = Sender(id: accountOwner, displayName: accountOwner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 765.5, height: 820)
        controller.view.layoutIfNeeded()
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: accountOwner, jid: jid, conversationType: .omemo),
            pageSize: ArchivePageSizing.history,
            conversationKey: .init(owner: accountOwner, jid: jid, conversationType: .omemo),
            observesStoreImmediately: false)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = .init(conversation: key, locator: .latest,
            contextBefore: ArchivePageSizing.initial, contextAfter: 0, priority: .visibleIntegrity)
        let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "old-media-window")
        let oldest = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let segment = try XCTUnwrap(ArchiveCoverageSegment(oldest: oldest,
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "200")), reachesArchiveStart: true,
            reachesLiveEdge: true, fingerprint: freshness.fingerprint, isVerified: true,
            orderedArchiveIDs: try oldRows.map { try XCTUnwrap(ArchiveCursor(rawValue: $0.mamArchiveId)) }))
        controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: oldRows.map(\.primary), target: .latest,
            verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness)))
        for _ in 0..<400 where controller.timelineSession?.verifiedScope == nil || controller.showSkeletonObserver.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(controller.timelineSession?.snapshot.items.map(\.primary), oldRows.map(\.primary))
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertGreaterThan(controller.messagesCollectionView.contentSize.height, 820)
        let oldIntentID = try XCTUnwrap(controller.archiveWindowIntent?.id)
        let demandID = UUID()
        await account.archiveEngine.attachPresentationDemand(for: key, demandID: demandID)
        controller.archiveEnginePresentationDemandID = demandID
        controller.archiveEnginePresentationDemandConversation = key
        controller.archiveEnginePresentationDemandEngine = account.archiveEngine
        defer { controller.stopArchiveEnginePresentationSubscription() }

        let b = row("media-B", mamID: "", image: true)
        try realm.write {
            realm.add(b)
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: accountOwner, conversationType: .omemo)
            chat.owner = accountOwner; chat.jid = jid; chat.conversationType = .omemo
            chat.lastMessage = b; chat.lastMessageId = b.messageId
            realm.add(chat)
        }
        let request = ChatOpenMessageRequest(chatJid: jid, owner: accountOwner, conversationType: .omemo,
            anchor: .init(messagePrimary: b.primary, archivedId: nil, archiveCursor: nil,
                messageId: b.messageId, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)

        // Owned MAM persistence can win this race before its new window reaches
        // UIKit. The exact route still has only its original primary/message ID.
        try realm.write { b.mamArchiveId = "300" }
        let transactionCount = controller.anchorTransactionGate.snapshot.transactionBeginCount
        controller.queueOpenMessageRequest(request)

        XCTAssertEqual(controller.pendingOpenMessageRequest, request,
            "A committed owned cursor must not turn an exact live-media route into targetMissing")
        XCTAssertNotEqual(controller.archiveWindowIntent?.id, oldIntentID)
        XCTAssertGreaterThan(controller.anchorTransactionGate.snapshot.transactionBeginCount, transactionCount)
        XCTAssertEqual(b.archivedId, "opaque-live-reference", "Raw stanza reference is not the MAM cursor")
        XCTAssertTrue(controller.showSkeletonObserver.value, "Old A is not proof that B has been positioned")
        let freshTarget = controller.archiveWindowIntent?.locator ?? .latest

        let freshToken = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "fresh-media-window")
        let freshSegment = try XCTUnwrap(ArchiveCoverageSegment(oldest: oldest,
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "300")), reachesArchiveStart: true,
            reachesLiveEdge: true, fingerprint: freshToken.fingerprint, isVerified: true,
            orderedArchiveIDs: try (oldRows + [b]).map { try XCTUnwrap(ArchiveCursor(rawValue: $0.mamArchiveId)) }))
        controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: (oldRows + [b]).map(\.primary),
            target: freshTarget, verifiedSegment: freshSegment, coverageGeneration: 2, freshnessToken: freshToken)))
        for _ in 0..<400 {
            if controller.datasource.contains(where: { $0.primary == b.primary && !$0.isFakeMessage }),
               controller.pendingOpenMessageRequest == nil, !controller.isChatDatasourceStructuralTransactionActive { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.anchorTransactionGate.snapshot.lastTerminalOutcome, .positioned)
        XCTAssertEqual(controller.retainedMessageAnchor?.primary, b.primary)

        // A later normal datasource apply and inset/layout settlement must not
        // replace the successful exact anchor with the prior window position.
        let flow = try XCTUnwrap(controller.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)
        controller.applyChatDatasource(controller.datasource, mode: .fullReload(keepOffset: true), animated: false,
            preparedLayouts: flow.cache.reuseSnapshot(), suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        XCTAssertEqual(controller.anchorTransactionGate.snapshot.lastTerminalOutcome, .positioned)
        XCTAssertEqual(controller.retainedMessageAnchor?.primary, b.primary)

        let section = try XCTUnwrap(controller.datasourceSnapshot.primaryIndex[b.primary])
        let path = IndexPath(item: 0, section: section)
        let attributes = try XCTUnwrap(controller.messagesCollectionView.layoutAttributesForItem(at: path))
        let collection = controller.messagesCollectionView
        let expected = ChatAnchorContentOffsetPolicy.centeredOffsetY(targetMidY: attributes.frame.midY,
            viewportHeight: collection.bounds.height, contentHeight: collection.contentSize.height,
            adjustedContentInsets: collection.adjustedContentInset)
        XCTAssertEqual(collection.contentOffset.y, expected, accuracy: 1)
        let cell = try XCTUnwrap(collection.cellForItem(at: path) as? TextMessageCell)
        XCTAssertGreaterThan(cell.imagesView.frame.height, 400)
        let caption = cell.messageLabel.convert(cell.messageLabel.bounds, to: collection)
        let image = cell.imagesView.convert(cell.imagesView.bounds, to: collection)
        XCTAssertTrue(collection.bounds.contains(CGPoint(x: caption.midX, y: caption.midY)))
        XCTAssertTrue(collection.bounds.contains(CGPoint(x: image.midX, y: image.midY)))
    }

    @MainActor
    func testPrimaryOnlyAuthenticatedLiveAnchorResolvesOnlyOpaqueReferenceWithoutGrantingAuthority() throws {
        for reference in ["opaque-live-reference", "999", " opaque-live-reference "] {
            try withPrimaryOnlyLiveAnchorFixture(mutate: { $0.archivedId = reference }) { controller, row, request in
                let resolved = controller.resolvedArchiveAnchor(for: request)
                XCTAssertEqual(resolved.archivedId, reference)
                XCTAssertEqual(resolved.messagePrimary, request.anchor.messagePrimary)
                XCTAssertEqual(resolved.messageId, request.anchor.messageId)
                XCTAssertNil(resolved.archiveCursor, "Even a numeric raw reference is not an owned MAM cursor")
                XCTAssertNil(resolved.sourceDate)
                XCTAssertNil(request.anchor.archivedId, "The original pending request identity must remain unchanged")
                XCTAssertEqual(row.mamArchiveId, "")
                XCTAssertNil(controller.archiveWindowState)
                XCTAssertNil(controller.timelineSession?.verifiedScope)
                XCTAssertFalse(row.isRead)
            }
        }
    }

    @MainActor
    func testPrimaryOnlyLiveReferenceRejectsUnqualifiedOrUnauthenticatedCanonicalRows() throws {
        for invalid in ["owner", "peer", "type", "primary", "messageID", "deleted", "hidden", "tombstone",
                        "expired", "error", "empty-reference", "whitespace-reference", "missing-auth", "auth-owner", "auth-jid",
                        "auth-device", "auth-trusted", "fingerprint", "fingerprint-grouping"] {
            try withPrimaryOnlyLiveAnchorFixture(mutate: { row in
                var auth = row.systemMetadata?["omemo_authenticated_sender_v1"] as? [String: Any] ?? [:]
                switch invalid {
                case "owner": row.owner = "foreign@example.org"
                case "peer": row.opponent = "foreign@example.org"
                case "type": row.conversationType = .regular
                case "primary": row.primary = "noncanonical-live-primary"
                case "messageID": row.messageId = "other-live-message"
                case "deleted": row.isDeleted = true
                case "hidden": row.isLocallyHiddenByReport = true
                case "tombstone": row.deleteState = .autoDeleted
                case "expired": row.autoDeleteExpiresAt = 1
                case "error": row.state = .error
                case "empty-reference": row.archivedId = ""
                case "whitespace-reference": row.archivedId = " \t\n "
                case "missing-auth": row.systemMetadata = nil
                case "auth-owner": auth["owner"] = "foreign@example.org"
                case "auth-jid": auth["jid"] = "foreign@example.org"
                case "auth-device": auth["deviceID"] = 0
                case "auth-trusted": auth.removeValue(forKey: "trusted")
                case "fingerprint": auth["fingerprint"] = String(repeating: "z", count: 64)
                case "fingerprint-grouping": auth["fingerprint"] = String(repeating: "aa ", count: 32)
                default: XCTFail("Unhandled live reference mutation: \(invalid)")
                }
                if invalid.hasPrefix("auth-") || invalid.hasPrefix("fingerprint") {
                    row.systemMetadata = ["omemo_authenticated_sender_v1": auth]
                }
            }) { controller, _, request in
                XCTAssertEqual(controller.resolvedArchiveAnchor(for: request), request.anchor, invalid)
            }
        }
    }

    @MainActor
    func testPrimaryOnlyLiveReferencePreservesExplicitLocatorAndSourcePrecedence() throws {
        try withPrimaryOnlyLiveAnchorFixture { controller, _, original in
            func request(cursor: ArchiveCursor? = nil, reference: String? = nil, date: Date? = nil,
                         source: ChatOpenMessageRequestSource = .directOpenAtMessage,
                         resolution: ChatOpenMessageTargetResolution = .anchor) -> ChatOpenMessageRequest {
                .init(chatJid: original.chatJid, owner: original.owner, conversationType: original.conversationType,
                    anchor: .init(messagePrimary: original.anchor.messagePrimary, archivedId: reference,
                        archiveCursor: cursor, messageId: original.anchor.messageId, authorId: nil,
                        bodyFingerprint: nil, sourceDate: date), highlight: false, markReadOnVisible: false,
                    source: source, targetResolution: resolution)
            }
            for explicit in [request(cursor: ArchiveCursor(rawValue: "500")), request(reference: "explicit-reference"),
                             request(date: Date(timeIntervalSince1970: 123)), request(source: .search),
                             request(resolution: .firstIncomingAfterBoundary("900"))] {
                XCTAssertEqual(controller.resolvedArchiveAnchor(for: explicit), explicit.anchor)
            }
        }
    }

    @MainActor
    func testReusedStaleVerified80QueuesNonTailLiveReferenceUntilOwnedMAMPositionsExactTarget() async throws {
        for olderThanWindow in [false, true] {
            try await withStaleVerifiedLiveReferenceFixture(targetOlderThanWindow: olderThanWindow) {
                controller, realm, history, b, c, request in
                let oldIntent = try XCTUnwrap(controller.archiveWindowIntent)
                controller.queueOpenMessageRequest(request)

                XCTAssertEqual(controller.pendingOpenMessageRequest, request,
                    "Exact B must survive normal queue even though C is the live tail")
                let resolutionID = try XCTUnwrap(controller.archiveReferenceResolutionID,
                    "A non-tail target outside cached80 must use normal opaque-reference resolution")
                let resolvingIntent = try XCTUnwrap(controller.archiveWindowIntent)
                XCTAssertNotEqual(resolvingIntent.id, oldIntent.id)
                XCTAssertEqual(controller.archiveWindowTargetOpenRequest, request)
                XCTAssertEqual(controller.initialTargetFirstFrameContext?.request, request,
                    "Normal primary-only reference handoff must protect B before the first real frame")
                XCTAssertNil(controller.timelineSession?.verifiedScope)
                XCTAssertTrue(controller.showSkeletonObserver.value)
                XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
                XCTAssertEqual(b.mamArchiveId, "")
                XCTAssertFalse(b.isRead)

                let cursor = try XCTUnwrap(ArchiveCursor(rawValue: olderThanWindow ? "150" : "300"))
                let ownedIntent = try XCTUnwrap(controller.completeArchiveReferenceResolution(cursor, request: request,
                    resolutionID: resolutionID, expectedIntentID: resolvingIntent.id))
                XCTAssertEqual(ownedIntent.locator, .archiveID(cursor))
                XCTAssertEqual(controller.pendingOpenMessageRequest, request)
                XCTAssertTrue(controller.showSkeletonObserver.value, "Resolution alone must not publish cached A or live C")
                XCTAssertFalse(b.isRead)

                try realm.write { b.mamArchiveId = cursor.rawValue; c.mamArchiveId = "400" }
                let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "fresh-nontail-B")
                let orderedRows = olderThanWindow ? [b] + history + [c] : history + [b, c]
                let segment = try XCTUnwrap(ArchiveCoverageSegment(
                    oldest: try XCTUnwrap(ArchiveCursor(rawValue: olderThanWindow ? "150" : "200")),
                    newest: try XCTUnwrap(ArchiveCursor(rawValue: "400")), reachesArchiveStart: true,
                    reachesLiveEdge: true, fingerprint: freshness.fingerprint, isVerified: true,
                    orderedArchiveIDs: try orderedRows.map { try XCTUnwrap(ArchiveCursor(rawValue: $0.mamArchiveId)) }))
                let primaries = orderedRows.map(\.primary)
                controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: primaries,
                    target: .archiveID(cursor), verifiedSegment: segment, coverageGeneration: 2,
                    freshnessToken: freshness)))
                for _ in 0..<400 where controller.pendingOpenMessageRequest != nil {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                XCTAssertNil(controller.pendingOpenMessageRequest)
                XCTAssertNil(controller.initialTargetFirstFrameContext)
                XCTAssertFalse(controller.showSkeletonObserver.value)
                XCTAssertEqual(controller.retainedMessageAnchor?.primary, b.primary)
                XCTAssertEqual(controller.timelineSession?.verifiedScope?.coverageGeneration, 2)
                XCTAssertEqual(controller.anchorTransactionGate.snapshot.lastTerminalOutcome, .positioned)
                XCTAssertFalse(b.isRead, "This exact route did not request markReadOnVisible")
            }
        }
    }

    @MainActor
    func testQueuedLiveReferenceConsumesOwnedMAMCursorCommittedBeforeResolutionTaskStarts() async throws {
        try await withStaleVerifiedLiveReferenceFixture { controller, realm, _, b, _, request in
            controller.queueOpenMessageRequest(request)
            XCTAssertEqual(controller.pendingOpenMessageRequest, request)
            XCTAssertNotNil(controller.archiveReferenceResolutionID)

            // No await between normal queue and this persistence commit: the
            // MainActor resolution task has not started yet.
            try realm.write { b.mamArchiveId = "300" }
            for _ in 0..<200 where controller.archiveWindowIntent?.locator != .archiveID(ArchiveCursor(rawValue: "300")!) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(controller.archiveWindowIntent?.locator, .archiveID(ArchiveCursor(rawValue: "300")!))
            XCTAssertNil(controller.archiveReferenceResolutionID,
                "An owned MAM cursor winning this race must not strand the opaque-reference operation")
            XCTAssertEqual(controller.pendingOpenMessageRequest, request)
            XCTAssertTrue(controller.showSkeletonObserver.value, "Cursor identity still needs owned window materialization")
            XCTAssertNil(controller.timelineSession?.verifiedScope)
            XCTAssertFalse(b.isRead)
        }
    }

    @MainActor
    func testUnreadFirstFrameUsesVerifiedIncomingWhenLongOutgoingPrefixTrimsBoundary() async throws {
        for isInitialOpen in [true, false] {
            let previous = Realm.Configuration.defaultConfiguration
            Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "UnreadTrimmedBoundary-\(UUID())")
            defer { Realm.Configuration.defaultConfiguration = previous }
            let realm = try WRealm.safe()
            let rows: [MessageStorageItem] = (0..<120).map { index in
                let row = MessageStorageItem()
                row.owner = owner; row.opponent = jid; row.conversationType = .regular
                row.messageId = "trimmed-\(index)"
                row.primary = MessageStorageItem.genPrimary(messageId: row.messageId, owner: owner)
                row.archivedId = "stanza-\(index)"
                row.mamArchiveId = "opaque-cursor-\(120 - index)"
                row.historyPositionOrdinal = Int64(index + 1)
                row.date = Date(timeIntervalSince1970: Double(1_700_000_120 - index))
                row.sentDate = row.date
                row.outgoing = index != 0 && index != 101 && index != 119
                row.body = "Verified unread context \(index)"; row.legacyBody = row.body
                row.state = .deliver
                return row
            }
            try realm.write { realm.add(rows) }
            let controller = ChatViewController()
            controller.owner = owner; controller.jid = jid; controller.conversationType = .regular
            controller.ownerSender = Sender(id: owner, displayName: owner)
            controller.opponentSender = Sender(id: jid, displayName: jid)
            controller.loadViewIfNeeded()
            controller.stopArchiveEnginePresentationSubscription()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            controller.view.layoutIfNeeded()
            controller.timelineSession = ChatTimelineSession(
                store: RealmChatTimelineSessionStore(owner: owner, jid: jid, conversationType: .regular),
                pageSize: ArchivePageSizing.history,
                conversationKey: .init(owner: owner, jid: jid, conversationType: .regular),
                observesStoreImmediately: false)
            let boundary = try XCTUnwrap(ArchiveCursor(rawValue: rows[0].mamArchiveId))
            let request = controller.makeScrollDownUnreadBoundaryRequest(boundaryId: rows[0].archivedId)
            controller.pendingOpenMessageRequest = request
            var completionCount = 0
            if isInitialOpen {
                controller.initialTargetFirstFrameContext = .init(request: request) { completionCount += 1 }
                controller.isPreparingStackedNavigationPresentation = true
            }
            let locator = ArchiveWindowLocator.firstUnread(after: boundary)
            controller.archiveWindowStateTask = Task {}
            controller.archiveWindowIntent = .init(
                conversation: .init(owner: owner, jid: jid, conversationType: .regular),
                locator: locator, contextBefore: ArchivePageSizing.anchorBefore,
                contextAfter: ArchivePageSizing.anchorAfter, priority: .target)
            controller.archiveWindowTargetOpenRequest = request
            controller.archiveWindowState = .skeleton(reason: .loadingTarget, target: locator)
            controller.setSkeletonVisible(true)
            _ = controller.commitArchiveEngineOpeningSkeletonSynchronously()
            defer { controller.stopArchiveEnginePresentationSubscription() }
            var duplicateLoadedPositionCount = 0
            controller.loadedAnchorPositioningDriverForTests = { completion in
                duplicateLoadedPositionCount += 1
                completion(true)
            }
            let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "trimmed-unread")
            let segment = try XCTUnwrap(ArchiveCoverageSegment(
                orderedArchiveIDs: rows.compactMap { ArchiveCursor(rawValue: $0.mamArchiveId) },
                reachesArchiveStart: true, reachesLiveEdge: true,
                fingerprint: freshness.fingerprint, isVerified: true))
            let centeredRows = Array(rows[61...119])
            XCTAssertFalse(centeredRows.contains { $0.primary == rows[0].primary })

            controller.receiveArchiveWindowState(.verified(.init(
                messagePrimaryIDs: centeredRows.map(\.primary), target: locator,
                verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness)))
            for _ in 0..<400 where controller.pendingOpenMessageRequest != nil || controller.initialTargetFirstFrameContext != nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            controller.messagesCollectionView.layoutIfNeeded()

            XCTAssertNil(controller.pendingOpenMessageRequest, "initial=\(isInitialOpen)")
            XCTAssertNil(controller.initialTargetFirstFrameContext)
            XCTAssertFalse(controller.showSkeletonObserver.value)
            XCTAssertEqual(controller.retainedMessageAnchor?.primary, rows[101].primary,
                "The first incoming row follows 100 outgoing rows in verified ledger order, independent of dates and cursor text")
            XCTAssertEqual(controller.timelineSession?.snapshot.items.map(\.primary), centeredRows.map(\.primary))
            XCTAssertEqual(completionCount, isInitialOpen ? 1 : 0)
            XCTAssertEqual(duplicateLoadedPositionCount, 0,
                "The winning atomic receipt must complete the original unread request without a second loaded-message scroll")
            if let section = controller.datasourceSnapshot.primaryIndex[rows[101].primary],
               let attributes = controller.messagesCollectionView.layoutAttributesForItem(at: .init(item: 0, section: section)) {
                let collection = controller.messagesCollectionView
                let expected = ChatAnchorContentOffsetPolicy.centeredOffsetY(targetMidY: attributes.frame.midY,
                    viewportHeight: collection.bounds.height, contentHeight: collection.contentSize.height,
                    adjustedContentInsets: collection.adjustedContentInset)
                XCTAssertEqual(collection.contentOffset.y, expected, accuracy: 1)
            } else {
                XCTFail("Winning first unread target must have actual committed layout")
            }
        }
    }

    @MainActor
    private func withPrimaryOnlyLiveAnchorFixture(
        mutate: (MessageStorageItem) -> Void = { _ in },
        body: (ChatViewController, MessageStorageItem, ChatOpenMessageRequest) throws -> Void
    ) throws {
        try withPrimaryOnlyMAMAnchorFixture(mutate: { row in
            row.mamArchiveId = ""
            row.systemMetadata = ["omemo_authenticated_sender_v1": ["owner": row.owner, "jid": row.opponent,
                "deviceID": 42, "fingerprint": String(repeating: "a", count: 64), "trusted": true]]
            mutate(row)
        }, body: body)
    }

    @MainActor
    private func withStaleVerifiedLiveReferenceFixture(
        targetOlderThanWindow: Bool = false,
        body: (ChatViewController, Realm, [MessageStorageItem], MessageStorageItem,
               MessageStorageItem, ChatOpenMessageRequest) async throws -> Void
    ) async throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "NonTailLiveReference-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let accountOwner = "nontail-\(UUID().uuidString.lowercased())@example.org"
        let previousUsers = AccountManager.shared.users
        let account = Account(jid: accountOwner, queue: DispatchQueue(label: "NonTailLiveReference-account"))
        AccountManager.shared.users = previousUsers + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }
        func row(_ id: String, mamID: String, date: TimeInterval) -> MessageStorageItem {
            let item = MessageStorageItem()
            item.messageId = id; item.primary = MessageStorageItem.genPrimary(messageId: id, owner: accountOwner)
            item.owner = accountOwner; item.opponent = jid; item.conversationType = .omemo
            item.archivedId = "opaque-reference-\(id)"; item.mamArchiveId = mamID
            item.date = Date(timeIntervalSince1970: date); item.sentDate = item.date
            item.body = "Authenticated \(id)"; item.legacyBody = item.body; item.state = .deliver
            item.systemMetadata = ["omemo_authenticated_sender_v1": ["owner": accountOwner, "jid": jid,
                "deviceID": 42, "fingerprint": String(repeating: "a", count: 64), "trusted": true]]
            return item
        }
        let history = (0..<80).map { row("history-\($0)", mamID: "\(200 + $0)", date: 1_700_000_100 + Double($0)) }
        let b = row("non-tail-B", mamID: "", date: targetOlderThanWindow ? 1_700_000_000 : 1_700_000_300)
        let c = row("newer-tail-C", mamID: "", date: 1_700_000_400)
        try realm.write {
            realm.add(history); realm.add(b); realm.add(c)
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: accountOwner, conversationType: .omemo)
            chat.owner = accountOwner; chat.jid = jid; chat.conversationType = .omemo
            chat.lastMessage = c; chat.lastMessageId = c.messageId
            realm.add(chat)
        }
        let controller = ChatViewController()
        controller.owner = accountOwner; controller.jid = jid; controller.conversationType = .omemo
        controller.ownerSender = Sender(id: accountOwner, displayName: accountOwner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        controller.loadViewIfNeeded(); controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); controller.view.layoutIfNeeded()
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: accountOwner, jid: jid, conversationType: .omemo),
            pageSize: ArchivePageSizing.history,
            conversationKey: .init(owner: accountOwner, jid: jid, conversationType: .omemo), observesStoreImmediately: false)
        let key = ArchiveConversationKey(owner: accountOwner, jid: jid, conversationType: .omemo)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = .init(conversation: key, locator: .latest,
            contextBefore: ArchivePageSizing.initial, contextAfter: 0, priority: .visibleIntegrity)
        let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "stale-verified80")
        let segment = try XCTUnwrap(ArchiveCoverageSegment(oldest: try XCTUnwrap(ArchiveCursor(rawValue: "200")),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "279")), reachesArchiveStart: false,
            reachesLiveEdge: true, fingerprint: freshness.fingerprint, isVerified: true,
            orderedArchiveIDs: try history.map { try XCTUnwrap(ArchiveCursor(rawValue: $0.mamArchiveId)) }))
        controller.receiveArchiveWindowState(.verified(.init(messagePrimaryIDs: history.map(\.primary), target: .latest,
            verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness)))
        for _ in 0..<400 where controller.timelineSession?.verifiedScope == nil || controller.showSkeletonObserver.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(controller.timelineSession?.snapshot.items.count, 80)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        let demandID = UUID()
        await account.archiveEngine.attachPresentationDemand(for: key, demandID: demandID)
        controller.archiveEnginePresentationDemandID = demandID
        controller.archiveEnginePresentationDemandConversation = key
        controller.archiveEnginePresentationDemandEngine = account.archiveEngine
        defer { controller.stopArchiveEnginePresentationSubscription() }
        let request = ChatOpenMessageRequest(chatJid: jid, owner: accountOwner, conversationType: .omemo,
            anchor: .init(messagePrimary: b.primary, archivedId: nil, archiveCursor: nil, messageId: b.messageId,
                authorId: nil, bodyFingerprint: nil, sourceDate: nil), highlight: false,
            markReadOnVisible: false, source: .directOpenAtMessage)
        try await body(controller, realm, history, b, c, request)
    }

    @MainActor
    func testPrimaryOnlyExactAnchorUsesOwnedMAMCursorWithoutGrantingArchiveOrReadAuthority() throws {
        try withPrimaryOnlyMAMAnchorFixture { controller, row, request in
            let resolved = controller.resolvedArchiveAnchor(for: request)
            XCTAssertEqual(resolved.archiveCursor, ArchiveCursor(rawValue: "300"))
            XCTAssertEqual(resolved.messagePrimary, request.anchor.messagePrimary)
            XCTAssertEqual(resolved.messageId, request.anchor.messageId)
            XCTAssertNil(resolved.archivedId)
            XCTAssertNil(resolved.sourceDate)
            XCTAssertNil(controller.archiveWindowState)
            XCTAssertNil(controller.timelineSession?.verifiedScope)
            XCTAssertFalse(row.isRead)
        }
    }

    @MainActor
    func testPrimaryOnlyExactAnchorKeepsOwnedArchivedErrorContentNavigable() throws {
        try withPrimaryOnlyMAMAnchorFixture(mutate: {
            $0.state = .error
            $0.messageError = "Stored decrypt failure"
            $0.systemMetadata = nil
        }) { controller, _, request in
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: request).archiveCursor,
                           ArchiveCursor(rawValue: "300"))
        }
    }

    @MainActor
    func testPrimaryOnlyExactAnchorRejectsUnqualifiedHiddenExpiredAndMissingMAMRows() throws {
        for mutation in ["owner", "peer", "type", "primary", "messageID", "deleted", "hidden",
                         "tombstone", "expired", "empty-MAM"] {
            try withPrimaryOnlyMAMAnchorFixture(mutate: { row in
                switch mutation {
                case "owner": row.owner = "other@example.org"
                case "peer": row.opponent = "other@example.org"
                case "type": row.conversationType = .regular
                case "primary": row.primary = "other-primary"
                case "messageID": row.messageId = "other-message"
                case "deleted": row.isDeleted = true
                case "hidden": row.isLocallyHiddenByReport = true
                case "tombstone": row.deleteState = .autoDeleted
                case "expired": row.autoDeleteExpiresAt = 1
                case "empty-MAM":
                    row.mamArchiveId = ""
                    row.archivedId = "999"
                default: XCTFail("Unhandled exact anchor mutation: \(mutation)")
                }
            }) { controller, _, request in
                XCTAssertNil(controller.resolvedArchiveAnchor(for: request).archiveCursor, mutation)
            }
        }
    }

    @MainActor
    func testPrimaryOnlyExactAnchorAcceptsOpaquePersistedMAMCursor() throws {
        try withPrimaryOnlyMAMAnchorFixture(mutate: { $0.mamArchiveId = "opaque-MAM-record" }) {
            controller, _, request in
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: request).archiveCursor,
                           ArchiveCursor(rawValue: "opaque-MAM-record"))
        }
    }

    @MainActor
    func testPrimaryOnlyLiveReferenceUsesOpaqueMAMCursorWhenPersistenceWins() throws {
        try withPrimaryOnlyLiveAnchorFixture(mutate: { $0.mamArchiveId = "opaque-materialized-MAM" }) {
            controller, _, request in
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: request).archiveCursor,
                           ArchiveCursor(rawValue: "opaque-materialized-MAM"))
        }
    }

    @MainActor
    func testPrimaryOnlyExactAnchorRejectsMatchingRowWithNoncanonicalPrimary() throws {
        try withPrimaryOnlyMAMAnchorFixture(mutate: { $0.primary = "noncanonical-alias-primary" }) {
            controller, row, original in
            let request = ChatOpenMessageRequest(chatJid: original.chatJid, owner: original.owner,
                conversationType: original.conversationType,
                anchor: .init(messagePrimary: row.primary, archivedId: nil, archiveCursor: nil,
                    messageId: row.messageId, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
                highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)

            XCTAssertNil(controller.resolvedArchiveAnchor(for: request).archiveCursor,
                "A row found by the requested alias must still match the canonical owner/message identity")
        }
    }

    @MainActor
    func testExactMAMResolutionPreservesExplicitCursorDateReferenceAndFirstUnreadPrecedence() throws {
        try withPrimaryOnlyMAMAnchorFixture { controller, _, original in
            func request(cursor: ArchiveCursor? = nil, reference: String? = nil, date: Date? = nil,
                         source: ChatOpenMessageRequestSource = .directOpenAtMessage,
                         resolution: ChatOpenMessageTargetResolution = .anchor) -> ChatOpenMessageRequest {
                .init(chatJid: original.chatJid, owner: original.owner, conversationType: original.conversationType,
                    anchor: .init(messagePrimary: original.anchor.messagePrimary, archivedId: reference,
                        archiveCursor: cursor, messageId: original.anchor.messageId, authorId: nil,
                        bodyFingerprint: nil, sourceDate: date), highlight: false, markReadOnVisible: false,
                    source: source, targetResolution: resolution)
            }
            let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "500"))
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: request(cursor: cursor)).archiveCursor, cursor)
            let dated = request(date: Date(timeIntervalSince1970: 123))
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: dated), dated.anchor)
            let reference = request(reference: "999")
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: reference), reference.anchor)
            let search = request(source: .search)
            XCTAssertEqual(controller.resolvedArchiveAnchor(for: search), search.anchor)
            XCTAssertEqual(controller.resolvedArchiveAnchor(for:
                request(cursor: cursor, resolution: .firstIncomingAfterBoundary("900"))).archiveCursor, cursor)
        }
    }

    @MainActor
    private func withPrimaryOnlyMAMAnchorFixture(
        mutate: (MessageStorageItem) -> Void = { _ in },
        body: (ChatViewController, MessageStorageItem, ChatOpenMessageRequest) throws -> Void
    ) throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ExactPersistedMAM-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let owner = "exact-mam-\(UUID().uuidString.lowercased())@example.org"
        let messageID = "exact-mam-message"
        let primary = MessageStorageItem.genPrimary(messageId: messageID, owner: owner)
        let row = MessageStorageItem()
        row.primary = primary; row.messageId = messageID
        row.owner = owner; row.opponent = jid; row.conversationType = .omemo
        row.archivedId = "opaque-stanza-reference"; row.mamArchiveId = "300"
        row.date = Date(timeIntervalSince1970: 100); row.sentDate = row.date
        row.body = "QA3 archived message"; row.legacyBody = row.body
        row.state = .deliver; row.isRead = false
        mutate(row)
        let realm = try WRealm.safe()
        try realm.write { realm.add(row) }
        let controller = ChatViewController()
        controller.owner = owner; controller.jid = jid; controller.conversationType = .omemo
        let request = ChatOpenMessageRequest(chatJid: jid, owner: owner, conversationType: .omemo,
            anchor: .init(messagePrimary: primary, archivedId: nil, archiveCursor: nil, messageId: messageID,
                authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .directOpenAtMessage)
        try body(controller, row, request)
    }

    private func makeRequest(
        archivedID: String,
        highlight: Bool = false,
        source: ChatOpenMessageRequestSource = .savedVisiblePosition
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedID,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            highlight: highlight,
            markReadOnVisible: false,
            source: source
        )
    }

    private func makeDatasource() -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: "target-primary",
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: jid),
            messageId: "target-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "Target")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: true,
            canEditMessage: false,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .deliver,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "200",
            queryIds: nil,
            isRead: false,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil
        )
    }

    @MainActor
    private func makePreparingController(
        archivedID: String
    ) -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.pendingOpenMessageRequest = makeRequest(
            archivedID: archivedID
        )
        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            completion: {}
        )
        return controller
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
