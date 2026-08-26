import XCTest
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

    private func makeRequest(archivedID: String) -> ChatOpenMessageRequest {
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
            highlight: false,
            markReadOnVisible: false,
            source: .savedVisiblePosition
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
