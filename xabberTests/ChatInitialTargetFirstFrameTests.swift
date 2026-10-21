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
            let segment = try XCTUnwrap(ArchiveCoverageSegment(
                oldest: try XCTUnwrap(ArchiveCursor(rawValue: "200")),
                newest: try XCTUnwrap(ArchiveCursor(rawValue: newest)),
                reachesArchiveStart: true, reachesLiveEdge: true,
                fingerprint: freshness.fingerprint, isVerified: true))
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
        for invalid in ["non-current-tail", "hidden", "deleted", "tombstone", "expired",
                        "foreign-owner", "foreign-peer", "foreign-type", "wrong-message-id", "missing-auth", "malformed-fingerprint", "malformed-grouping", "foreign-auth-sender", "missing-reference", "mismatched-tail-id"] {
            try realm.write {
                switch invalid {
                case "non-current-tail": chat.lastMessage = a
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
                case "mismatched-tail-id": chat.lastMessageId = "newer-live-C"
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
            reachesLiveEdge: true, fingerprint: freshToken.fingerprint, isVerified: true))
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
