import XCTest
@testable import xabber

final class ChatArchiveEnginePresentationTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testReplacementTargetRejectsLateStateFromPreviousDescriptor() throws {
        let latest = ChatArchiveWindowPresentationPolicy.latestTargetIntent(
            conversation: conversation
        )
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let replacement = ArchiveWindowIntent(
            conversation: conversation,
            locator: .archiveID(cursor),
            contextBefore: 30,
            contextAfter: 30,
            priority: .target
        )
        let lateLatest = ArchiveWindowState.skeleton(
            reason: .unverifiedCoverage,
            target: latest.locator
        )
        let currentTarget = ArchiveWindowState.skeleton(
            reason: .loadingTarget,
            target: replacement.locator
        )

        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldAccept(
                state: lateLatest,
                for: replacement
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldAccept(
                state: currentTarget,
                for: replacement
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldAccept(
                state: currentTarget,
                for: nil
            )
        )
    }

    @MainActor
    func testBoundaryLoadingIndicatorAnimatesAboveTimelineContent() {
        let controller = ChatViewController()
        let rootView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.view = rootView
        rootView.addSubview(controller.messageLoadingActivityIndicator)
        let timelineContent = UIView(frame: rootView.bounds)
        rootView.addSubview(timelineContent)
        controller.messageLoadingActivityIndicator.stopAnimating()
        controller.messageLoadingActivityIndicator.isHidden = true

        controller.setArchiveLoading(true)

        XCTAssertFalse(controller.messageLoadingActivityIndicator.isHidden)
        XCTAssertTrue(controller.messageLoadingActivityIndicator.isAnimating)
        XCTAssertTrue(rootView.subviews.last === controller.messageLoadingActivityIndicator)

        controller.setArchiveLoading(false)

        XCTAssertTrue(controller.messageLoadingActivityIndicator.isHidden)
        XCTAssertFalse(controller.messageLoadingActivityIndicator.isAnimating)
    }

    @MainActor
    func testBoundaryLoadingIndicatorCoversIntentThroughUIKitApplyCompletion() throws {
        let controller = ChatViewController()
        let rootView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.view = rootView
        rootView.addSubview(controller.messageLoadingActivityIndicator)
        controller.messageLoadingActivityIndicator.stopAnimating()
        controller.messageLoadingActivityIndicator.isHidden = true
        controller.showSkeletonObserver.accept(false)
        let target = ArchiveWindowLocator.older(
            before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        )

        controller.beginArchiveBoundaryLoadingIndicator(for: target)

        XCTAssertFalse(
            controller.messageLoadingActivityIndicator.isHidden,
            "Paging intent must show feedback synchronously, before the engine activity stream arrives"
        )
        XCTAssertTrue(controller.messageLoadingActivityIndicator.isAnimating)

        controller.archiveWindowActivity = .idle
        controller.archiveWindowPendingSnapshot = try makeSnapshot(
            generation: 8,
            target: target
        )
        controller.refreshArchiveBoundaryLoadingIndicator()

        XCTAssertFalse(
            controller.messageLoadingActivityIndicator.isHidden,
            "An engine receipt cannot hide feedback while the verified page is still awaiting UIKit apply"
        )

        controller.archiveWindowPendingSnapshot = nil
        controller.completeArchiveBoundaryLoadingIndicator(for: target)

        XCTAssertTrue(controller.messageLoadingActivityIndicator.isHidden)
        XCTAssertFalse(controller.messageLoadingActivityIndicator.isAnimating)
    }

    func testBoundarySpinnerFollowsEngineActivityWithoutCoveringFullSkeleton() {
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: .idle,
                isShowingFullSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: .idle,
                pendingRequestTarget: .older(
                    before: ArchiveCursor(rawValue: "10")!
                ),
                isShowingFullSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: .idle,
                pendingPresentationTarget: .older(
                    before: ArchiveCursor(rawValue: "10")!
                ),
                isShowingFullSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: ArchiveWindowActivity(activeBoundaryRequestCount: 1),
                isShowingFullSkeleton: false
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryLoadingIndicator(
                activity: ArchiveWindowActivity(activeBoundaryRequestCount: 1),
                isShowingFullSkeleton: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldReplaceCommittedContentWithSkeleton(
                for: .older(before: ArchiveCursor(rawValue: "10")!)
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldReplaceCommittedContentWithSkeleton(
                for: .archiveID(ArchiveCursor(rawValue: "10")!)
            )
        )
    }

    func testAuthoritativeEmptyCommitsSessionOnlyFromAtomicUIKitAuthorization() throws {
        let source = try archiveEngineSource()
        let start = try XCTUnwrap(
            source.range(of: "private func applyArchiveEngineAuthoritativeEmpty")
        )
        let tail = source[start.lowerBound...]
        let end = tail.range(of: "private func recordArchiveSkeletonTerminalIfNeeded")?
            .lowerBound ?? tail.endIndex
        let method = String(tail[..<end])
        let authorization = try XCTUnwrap(
            method.range(of: "transactionCommitAuthorization:")
        )
        let install = try XCTUnwrap(
            method.range(of: "installArchiveEngineAuthoritativeEmpty(")
        )

        XCTAssertGreaterThan(
            install.lowerBound,
            authorization.lowerBound,
            "The session must not become empty before the winning UIKit transaction is authorized"
        )
    }

    func testAuthoritativeEmptyUsesInitialPresentationTransactionOnlyForInitialTargets() throws {
        let source = try archiveEngineSource()
        let start = try XCTUnwrap(
            source.range(of: "private func applyArchiveEngineAuthoritativeEmpty")
        )
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(
            tail.range(
                of: "private func performArchiveEngineInitialPresentationTransactionIfNeeded"
            )
        ).lowerBound
        let method = String(tail[..<end])

        XCTAssertTrue(
            method.contains("case .authoritativeEmpty(") &&
                method.contains("let target") &&
                method.contains("let freshnessToken")
        )
        XCTAssertTrue(
            method.contains(
                "performArchiveEngineInitialPresentationTransactionIfNeeded(\n                    for: target,\n                    receipt: .empty"
            )
        )
        XCTAssertFalse(
            method.contains("performChatOpenPerformancePresentationTransaction("),
            "Boundary empty receipts must pass through the target-aware helper instead of rearming initial presentation directly"
        )

        let helper = String(source[end...])
        let boundaryGuard = try XCTUnwrap(
            helper.range(of: "ChatArchiveWindowPresentationPolicy.boundaryDirection")
        )
        let directUpdate = try XCTUnwrap(helper.range(of: "updates()"))
        let beginPresenting = try XCTUnwrap(helper.range(of: "beginPresenting("))
        XCTAssertLessThan(boundaryGuard.lowerBound, directUpdate.lowerBound)
        XCTAssertLessThan(directUpdate.lowerBound, beginPresenting.lowerBound)
    }

    func testVerifiedStoreObservationStartsOnlyAfterWinningUIKitCompletion() throws {
        let source = try archiveEngineSource()
        let start = try XCTUnwrap(
            source.range(of: "private func applyArchiveEngineVerifiedSnapshot")
        )
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(
            tail.range(of: "private func captureArchiveEngineBoundaryAnchor")
        ).lowerBound
        let method = String(tail[..<end])
        let completionStart = try XCTUnwrap(
            method.range(of: "completion: { [weak self, weak session] in")
        )
        let beforeCompletion = String(method[..<completionStart.lowerBound])
        let completion = String(method[completionStart.lowerBound...])
        let winningGuard = try XCTUnwrap(
            completion.range(of: "guard self.timelineSession === session")
        )
        let datasourceReady = try XCTUnwrap(
            completion.range(of: "self.setDatasourceLoadingEnabled(true)")
        )
        let activation = try XCTUnwrap(
            completion.range(of: "session.activateStoreObservation()")
        )

        XCTAssertFalse(beforeCompletion.contains("activateStoreObservation"))
        XCTAssertEqual(
            method.components(separatedBy: "session.activateStoreObservation()").count - 1,
            1
        )
        XCTAssertGreaterThan(activation.lowerBound, winningGuard.lowerBound)
        XCTAssertGreaterThan(
            activation.lowerBound,
            datasourceReady.lowerBound,
            "Realm observation may start only after the verified UIKit apply has won and presentation state is committed"
        )
    }

    func testAuthoritativeEmptyObservationUsesTrustedBaselineAfterWinningUIKitCompletion() throws {
        let source = try archiveEngineSource()
        let start = try XCTUnwrap(
            source.range(of: "private func applyArchiveEngineAuthoritativeEmpty")
        )
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(
            tail.range(
                of: "private func performArchiveEngineInitialPresentationTransactionIfNeeded"
            )
        ).lowerBound
        let method = String(tail[..<end])
        let completionStart = try XCTUnwrap(
            method.range(of: "completion: { [weak self] in")
        )
        let beforeCompletion = String(method[..<completionStart.lowerBound])
        let completion = String(method[completionStart.lowerBound...])
        let winningGuard = try XCTUnwrap(
            completion.range(of: "guard let self,")
        )
        let datasourceReady = try XCTUnwrap(
            completion.range(of: "self.setDatasourceLoadingEnabled(true)")
        )
        let activation = try XCTUnwrap(
            completion.range(of: "session.activateStoreObservation(")
        )

        XCTAssertFalse(beforeCompletion.contains("activateStoreObservation"))
        XCTAssertEqual(
            method.components(separatedBy: "session.activateStoreObservation").count - 1,
            1
        )
        XCTAssertTrue(completion.contains("authoritativeEmptyBaseline: true"))
        XCTAssertGreaterThan(activation.lowerBound, winningGuard.lowerBound)
        XCTAssertGreaterThan(
            activation.lowerBound,
            datasourceReady.lowerBound,
            "An empty Realm baseline is authoritative only after the empty UIKit apply wins"
        )
    }

    func testDeferredObservationUsesCommittedVerifiedRuntimeBaseline() throws {
        let item = message(primary: "p10", archiveID: "10")
        let store = ChatArchiveBoundaryDecisionStore(items: [item])
        let session = makeTimelineSession(store: store)

        XCTAssertTrue(store.observedBaselines.isEmpty)
        XCTAssertNotNil(
            session.installArchiveEngineVerifiedWindow(
                try makeSnapshot(generation: 11)
            )
        )
        XCTAssertTrue(
            store.observedBaselines.isEmpty,
            "Committing proof must not expose Realm observation before UIKit wins"
        )

        session.activateStoreObservation()

        XCTAssertEqual(store.observedBaselines.count, 1)
        let baseline = try XCTUnwrap(store.observedBaselines.first)
        XCTAssertFalse(baseline.isAuthoritative)
        XCTAssertEqual(baseline.residentPrimaryKeys, ["p10"])
    }

    func testDeferredObservationUsesAuthoritativeEmptyRuntimeBaseline() throws {
        let store = ChatArchiveBoundaryDecisionStore(items: [])
        let session = makeTimelineSession(store: store)

        _ = session.installArchiveEngineAuthoritativeEmpty()
        XCTAssertTrue(store.observedBaselines.isEmpty)

        session.activateStoreObservation(authoritativeEmptyBaseline: true)

        XCTAssertEqual(store.observedBaselines.count, 1)
        let baseline = try XCTUnwrap(store.observedBaselines.first)
        XCTAssertTrue(baseline.isAuthoritative)
        XCTAssertTrue(baseline.residentPrimaryKeys.isEmpty)
    }

    func testStoreObservationBindingUsesCurrentStoreChangesAndTargetedOffMainApply()
        throws {
        let source = try chatViewControllerSource()
        let binding = try sourceMethod(
            named: "private func replaceTimelineStoreSnapshotBinding(",
            in: source
        )
        XCTAssertTrue(binding.contains("previousSession?.onSnapshot = nil"))
        XCTAssertTrue(binding.contains(
            "session.onSnapshot = { [weak self, weak session] snapshot in"
        ))
        XCTAssertTrue(binding.contains("snapshot.cause == .storeChange"))
        XCTAssertTrue(binding.contains("DispatchQueue.main.async"))

        let drain = try sourceMethod(
            named: "func drainPendingTimelineStoreSnapshot()",
            in: source
        )
        XCTAssertTrue(drain.contains("self.timelineSession === session"))
        XCTAssertTrue(drain.contains("datasetMappingQueue.async"))
        XCTAssertTrue(drain.contains("self.mapDataset("))
        XCTAssertTrue(drain.contains("DispatchQueue.main.async"))

        let policyBridge = try sourceMethod(
            named: "private func timelineStoreSnapshotPresentationAction(",
            in: source
        )
        XCTAssertTrue(policyBridge.contains(
            "ChatTimelineStoreSnapshotPresentationPolicy.action("
        ))
        XCTAssertTrue(policyBridge.contains(
            "archiveWindowPendingLiveEdgeAdmission != nil"
        ))
        XCTAssertTrue(policyBridge.contains(
            "archiveWindowLiveEdgeApplyGeneration != nil"
        ))

        let apply = try sourceMethod(
            named: "private func applyMappedTimelineStoreSnapshot(",
            in: source
        )
        XCTAssertTrue(apply.contains(
            "session.snapshot.generation == snapshot.generation"
        ))
        XCTAssertTrue(apply.contains("mode: .targetedDiff"))
        XCTAssertTrue(apply.contains("animated: false"))
        XCTAssertTrue(apply.contains("presentationOwner: .archiveEngine"))
        XCTAssertTrue(apply.contains(
            "presentationCommitMode: .atomicInitialFrame"
        ))
        XCTAssertTrue(apply.contains("transactionCommitAuthorization:"))
        XCTAssertTrue(apply.contains("introducesLocalOutgoing"))
        XCTAssertTrue(apply.contains(
            "snapshot.provisionalLocalOutgoingPrimaryIDs"
        ))
        XCTAssertTrue(apply.contains(
            "forceBottomAlignmentTarget: introducesLocalOutgoing"
        ))
        XCTAssertTrue(apply.contains(
            "session.reprepareLocalOutgoingPresentation("
        ))

        let implementation = binding + drain + apply
        XCTAssertFalse(implementation.contains("handleTimelineSessionRefresh"))
        XCTAssertFalse(implementation.contains("initialLocalFirstFramePhase"))
        XCTAssertFalse(implementation.contains("pendingArchiveObserverRefresh"))
    }

    func testStoreSnapshotCoordinatorRejectsWrongBindingAndCoalescesLatestGeneration() {
        var coordinator = ChatTimelineStoreSnapshotApplyCoordinator()
        let binding = coordinator.replaceBinding()
        let command = timelineSnapshot(generation: 1, cause: .command)
        let first = timelineSnapshot(generation: 2, cause: .storeChange)
        let latest = timelineSnapshot(generation: 3, cause: .storeChange)

        XCTAssertEqual(
            coordinator.receive(command, bindingGeneration: binding),
            .ignored
        )
        XCTAssertEqual(
            coordinator.receive(first, bindingGeneration: binding),
            .queued
        )
        XCTAssertEqual(
            coordinator.beginPending(bindingGeneration: binding)?.generation,
            first.generation
        )
        XCTAssertEqual(
            coordinator.receive(latest, bindingGeneration: binding),
            .supersededActive
        )
        XCTAssertTrue(coordinator.complete(
            generation: first.generation,
            bindingGeneration: binding,
            applied: false
        ))
        XCTAssertEqual(
            coordinator.beginPending(bindingGeneration: binding)?.generation,
            latest.generation
        )

        let replacementBinding = coordinator.replaceBinding()
        XCTAssertNotEqual(binding, replacementBinding)
        XCTAssertEqual(
            coordinator.receive(latest, bindingGeneration: binding),
            .ignored
        )
        XCTAssertNil(coordinator.beginPending(
            bindingGeneration: replacementBinding
        ))
    }

    func testLocalOutgoingRemainsApplicableWhenStoreUpdateSupersedesItBeforeUIKitApply() {
        let presented = Set(["p10"])
        let local = timelineSnapshot(
            generation: 2,
            cause: .localOutgoingAdmission,
            primaries: ["p10", "p11"],
            provisionalPrimaries: ["p11"]
        )
        let supersedingStoreChange = timelineSnapshot(
            generation: 3,
            cause: .storeChange,
            primaries: ["p10", "p11"],
            provisionalPrimaries: ["p11"]
        )

        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: local,
                currentSessionGeneration: local.generation,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .apply
        )
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: supersedingStoreChange,
                currentSessionGeneration: supersedingStoreChange.generation,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .apply,
            "A typed provisional row must survive an upload/error observer update before its first UIKit apply"
        )
    }

    func testLocalOutgoingEventIsRetainedUntilVerifiedLiveTailAuthorityExists()
        throws {
        let source = try archiveEngineSource()
        let receive = try sourceMethod(
            named: "func receiveLocalOutgoingAdmission(",
            in: source
        )
        let drain = try sourceMethod(
            named: "func drainPendingLocalOutgoingAdmissions()",
            in: source
        )

        XCTAssertTrue(receive.contains(
            "archivePendingLocalOutgoingAdmissions[admission.primaryID]"
        ))
        XCTAssertTrue(receive.contains("drainPendingLocalOutgoingAdmissions()"))
        XCTAssertTrue(drain.contains(
            "session.snapshot.authoritativeEmptyLiveTailAuthority != nil"
        ))
        XCTAssertTrue(drain.contains("session.admitLocalOutgoing(admission)"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "drainPendingLocalOutgoingAdmissions()")
                .count - 1,
            3,
            "The queue must drain on receipt and after verified/empty UIKit authority commits"
        )
    }

    @MainActor
    func testControllerAutomaticallyReplaysPreProofOutgoingAfterEmptyProof()
        async throws {
        let outgoing = message(primary: "local-p1", archiveID: "")
        outgoing.messageId = "local-message-1"
        outgoing.outgoing = true
        outgoing.state = .sending
        let store = ChatArchiveBoundaryDecisionStore(items: [outgoing])
        let session = makeTimelineSession(store: store)
        let controller = ChatViewController()
        controller.owner = conversation.owner
        controller.jid = conversation.jid
        controller.conversationType = conversation.conversationType
        controller.timelineSession = session
        controller.archiveLocalOutgoingAdmissionTask = Task {}
        defer {
            controller.archiveLocalOutgoingAdmissionTask?.cancel()
            controller.archiveLocalOutgoingAdmissionTask = nil
        }
        let admission = ChatTimelineLocalOutgoingAdmission(
            conversation: conversation,
            primaryID: outgoing.primary
        )
        let published = expectation(description: "pre-proof outgoing replayed")
        session.onSnapshot = { snapshot in
            if snapshot.cause == .localOutgoingAdmission,
               snapshot.item(primary: outgoing.primary) != nil {
                published.fulfill()
            }
        }

        controller.receiveLocalOutgoingAdmission(admission)
        XCTAssertNotNil(
            controller.archivePendingLocalOutgoingAdmissions[outgoing.primary]
        )
        XCTAssertNil(session.snapshot.item(primary: outgoing.primary))

        _ = session.installArchiveEngineAuthoritativeEmpty(
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: "empty-proof"
            )
        )
        controller.drainPendingLocalOutgoingAdmissions()

        await fulfillment(of: [published], timeout: 1)
        XCTAssertNotNil(session.snapshot.item(primary: outgoing.primary))
        // Admission publishes from its dedicated queue and schedules the
        // controller-owned bookkeeping cleanup on MainActor immediately
        // afterwards. Wait for that second hop instead of racing it.
        for _ in 0..<20
        where controller.archivePendingLocalOutgoingAdmissions[
            outgoing.primary
        ] != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(
            controller.archivePendingLocalOutgoingAdmissions[outgoing.primary]
        )
    }

    func testStoreSnapshotPresentationRejectsStaleAndUnseenRowsAndDefersBlockedUI() {
        let snapshot = timelineSnapshot(
            generation: 4,
            cause: .storeChange,
            primaries: ["p10"]
        )
        let presented = Set(["p10"])

        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: snapshot,
                currentSessionGeneration: 4,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .apply
        )
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: snapshot,
                currentSessionGeneration: 5,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .reject
        )
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: timelineSnapshot(
                    generation: 4,
                    cause: .storeChange,
                    primaries: ["p11"]
                ),
                currentSessionGeneration: 4,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .reject
        )
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: snapshot,
                currentSessionGeneration: 4,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: true,
                hasPendingArchiveApply: false
            ),
            .deferUntilPresentationSettles
        )
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: snapshot,
                currentSessionGeneration: 4,
                presentedPrimaryIDs: presented,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: true
            ),
            .deferUntilPresentationSettles
        )
    }

    func testStoreSnapshotBindingLifecycleRequiresRebindAfterInvalidation() {
        var coordinator = ChatTimelineStoreSnapshotApplyCoordinator()

        XCTAssertFalse(coordinator.isBindingActive)
        let firstBinding = coordinator.replaceBinding()
        XCTAssertTrue(coordinator.isBindingActive)

        coordinator.invalidateBinding()
        XCTAssertFalse(coordinator.isBindingActive)

        let rebound = coordinator.replaceBinding()
        XCTAssertTrue(coordinator.isBindingActive)
        XCTAssertGreaterThan(rebound, firstBinding)
    }

    func testSameSessionReappearanceReinstallsStoreSnapshotBinding() throws {
        let source = try chatViewControllerSource()
        let ensure = try sourceMethod(
            named: "internal func ensureTimelineStoreSnapshotBindingForCurrentAppearance()",
            in: source
        )
        let willAppear = try sourceMethod(
            named: "override func viewWillAppear(",
            in: source
        )
        let invalidate = try sourceMethod(
            named: "private func invalidateTimelineStoreSnapshotBinding()",
            in: source
        )

        XCTAssertTrue(ensure.contains("!timelineStoreSnapshotApplyCoordinator.isBindingActive"))
        XCTAssertTrue(ensure.contains("replaceTimelineStoreSnapshotBinding("))
        XCTAssertTrue(willAppear.contains(
            "ensureTimelineStoreSnapshotBindingForCurrentAppearance()"
        ))
        XCTAssertTrue(invalidate.contains(
            "timelineStoreSnapshotApplyCoordinator.invalidateBinding()"
        ))
    }

    @MainActor
    func testSameSessionReappearanceReceivesStoreChangeAfterRuntimeRebind()
        async throws {
        let item = message(primary: "p10", archiveID: "10")
        let store = ChatArchiveBoundaryDecisionStore(items: [item])
        let session = makeTimelineSession(store: store)
        let controller = ChatViewController()
        controller.owner = conversation.owner
        controller.jid = conversation.jid
        controller.conversationType = conversation.conversationType
        controller.timelineSession = session
        XCTAssertNotNil(session.installArchiveEngineVerifiedWindow(
            try makeSnapshot(generation: 1)
        ))
        session.activateStoreObservation()

        controller.invalidateTimelineStoreSnapshotBindingForTests()
        XCTAssertNil(session.onSnapshot)

        let received = expectation(description: "rebound store snapshot")
        var receivedGeneration: UInt64?
        controller.timelineStoreSnapshotReceiveObserverForTests = {
            snapshot,
            disposition in
            guard disposition != .ignored else { return }
            XCTAssertTrue(Thread.isMainThread)
            receivedGeneration = snapshot.generation
            received.fulfill()
        }
        controller.ensureTimelineStoreSnapshotBindingForCurrentAppearance()
        XCTAssertNotNil(session.onSnapshot)

        store.emit(.residentChanged)

        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(receivedGeneration, session.snapshot.generation)
        XCTAssertEqual(session.snapshot.cause, .storeChange)
    }

    func testStorePresentationEpochRejectsDatasourceLayoutAndMappingContextDrift() {
        let captured = storePresentationEpoch(
            datasourceGeneration: 10,
            layoutGeneration: 3,
            width: 320,
            searchText: nil
        )

        XCTAssertTrue(ChatTimelineStorePresentationEpochPolicy.isCurrent(
            captured,
            current: captured
        ))
        XCTAssertFalse(ChatTimelineStorePresentationEpochPolicy.isCurrent(
            captured,
            current: storePresentationEpoch(
                datasourceGeneration: 11,
                layoutGeneration: 3,
                width: 320,
                searchText: nil
            )
        ))
        XCTAssertFalse(ChatTimelineStorePresentationEpochPolicy.isCurrent(
            captured,
            current: storePresentationEpoch(
                datasourceGeneration: 10,
                layoutGeneration: 4,
                width: 390,
                searchText: nil
            )
        ))
        XCTAssertFalse(ChatTimelineStorePresentationEpochPolicy.isCurrent(
            captured,
            current: storePresentationEpoch(
                datasourceGeneration: 10,
                layoutGeneration: 3,
                width: 320,
                searchText: "archive"
            )
        ))
    }

    func testStoreMappingCarriesPresentationEpochAndRemapsStaleResult() throws {
        let source = try chatViewControllerSource()
        let drain = try sourceMethod(
            named: "func drainPendingTimelineStoreSnapshot()",
            in: source
        )
        let apply = try sourceMethod(
            named: "private func applyMappedTimelineStoreSnapshot(",
            in: source
        )

        XCTAssertTrue(drain.contains("let presentationEpoch ="))
        XCTAssertTrue(drain.contains("presentationEpoch: presentationEpoch"))
        XCTAssertTrue(apply.contains(
            "ChatTimelineStorePresentationEpochPolicy.isCurrent("
        ))
        XCTAssertTrue(apply.contains(
            "timelineStoreSnapshotApplyCoordinator.deferActive("
        ))
        XCTAssertTrue(apply.contains("drainPendingTimelineStoreSnapshot()"))
        XCTAssertTrue(apply.contains(
            "anchorRestorePhase: restoreAnchor == nil ? .none : .applyTransaction"
        ))
        XCTAssertTrue(apply.contains("restoreAnchor: restoreAnchor"))
    }

    func testStalePresentationEpochRequeuesNewestCoordinatorSnapshot() {
        var coordinator = ChatTimelineStoreSnapshotApplyCoordinator()
        let binding = coordinator.replaceBinding()
        let mapped = timelineSnapshot(generation: 8, cause: .storeChange)
        let newest = timelineSnapshot(generation: 9, cause: .storeChange)
        XCTAssertEqual(
            coordinator.receive(mapped, bindingGeneration: binding),
            .queued
        )
        XCTAssertEqual(
            coordinator.beginPending(bindingGeneration: binding)?.generation,
            mapped.generation
        )
        XCTAssertEqual(
            coordinator.receive(newest, bindingGeneration: binding),
            .supersededActive
        )

        let captured = storePresentationEpoch(
            datasourceGeneration: 10,
            layoutGeneration: 3,
            width: 320,
            searchText: nil
        )
        let current = storePresentationEpoch(
            datasourceGeneration: 11,
            layoutGeneration: 3,
            width: 320,
            searchText: nil
        )
        XCTAssertFalse(ChatTimelineStorePresentationEpochPolicy.isCurrent(
            captured,
            current: current
        ))
        coordinator.deferActive(mapped, bindingGeneration: binding)

        XCTAssertEqual(
            coordinator.beginPending(bindingGeneration: binding)?.generation,
            newest.generation
        )
    }

    func testRemoteApplyExclusionDefersLatestAndDrainsExactlyOnce() {
        var gate = ChatTimelineStoreRemoteApplyExclusionGate()
        let token = ChatTimelineStoreUIKitApplyToken(
            bindingGeneration: 2,
            snapshotGeneration: 8
        )

        XCTAssertTrue(gate.beginStoreApply(token: token))
        XCTAssertEqual(gate.admitRemote(applyGeneration: 20), .deferred)
        XCTAssertEqual(gate.admitRemote(applyGeneration: 21), .coalesced)
        var drainedGenerations: [UInt64] = []
        if let generation = gate.finishStoreApply(token: token) {
            drainedGenerations.append(generation)
        }
        if let generation = gate.finishStoreApply(token: token) {
            drainedGenerations.append(generation)
        }
        XCTAssertEqual(drainedGenerations, [21])
        XCTAssertEqual(gate.admitRemote(applyGeneration: 22), .start)
    }

    func testVerifiedRemoteApplyUsesStoreExclusionBeforeMapping() throws {
        let source = try archiveEngineSource()
        let apply = try sourceMethod(
            named: "private func applyArchiveEngineVerifiedSnapshot(",
            in: source
        )
        let exclusion = try XCTUnwrap(
            apply.range(
                of: "deferArchiveEnginePresentationIfTimelineStoreApplyActive("
            )
        )
        let mapping = try XCTUnwrap(apply.range(of: "let mappingJob ="))

        XCTAssertLessThan(exclusion.lowerBound, mapping.lowerBound)
        XCTAssertTrue(apply.contains("applyGeneration: applyGeneration"))
    }

    @MainActor
    func testInteractiveBoundaryDecisionUsesCommittedVerifiedSessionScope() throws {
        let controller = ChatViewController()
        let snapshot = try makeSnapshot(
            generation: 7,
            reachesArchiveStart: false,
            reachesLiveEdge: true
        )
        controller.archiveWindowState = .verified(snapshot)
        controller.archiveWindowCommittedCoverageGeneration = 7
        controller.archiveWindowPendingSnapshot = nil
        controller.showSkeletonObserver.accept(false)
        try installTimelineSession(on: controller, snapshot: snapshot)
        let olderBoundary = ChatHistoryPagingBoundaryContext(
            firstRealSection: 4,
            lastRealSection: 40,
            visibleRealSections: [4, 5, 6]
        )

        XCTAssertEqual(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: 20,
                boundaryContext: olderBoundary
            ),
            .older
        )
        XCTAssertNil(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: false,
                gestureTranslationY: 20,
                boundaryContext: olderBoundary
            ),
            "Programmatic collection movement must not submit an archive page"
        )

        controller.archiveWindowCommittedCoverageGeneration = 6
        XCTAssertNil(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: 20,
                boundaryContext: olderBoundary
            ),
            "An uncommitted coverage generation must not page beyond the visible proof"
        )
    }

    @MainActor
    func testInteractiveAndPrefetchAuthorizeAuthoritativeEmptyLiveScope() throws {
        let controller = ChatViewController()
        controller.owner = conversation.owner
        controller.jid = conversation.jid
        controller.conversationType = conversation.conversationType
        let items = (1...601).map {
            message(primary: "p\($0)", archiveID: String($0))
        }
        let store = ChatArchiveBoundaryDecisionStore(items: items)
        let session = makeTimelineSession(store: store)
        controller.timelineSession = session
        _ = session.installArchiveEngineAuthoritativeEmpty()
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 1,
            queryID: "empty-live"
        )
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: "1")),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "601")),
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: freshnessToken.fingerprint,
            isVerified: true
        ))
        let admission = ArchiveLiveEdgeAdmission(
            conversation: conversation,
            primaryID: "p601",
            latestWindow: ArchiveWindowSnapshot(
                messagePrimaryIDs: items.map(\.primary),
                target: .latest,
                verifiedSegment: segment,
                coverageGeneration: 1,
                freshnessToken: freshnessToken
            ),
            presentationIntent: ArchiveIntentDescriptor(
                conversation: conversation,
                locator: .latest,
                contextBefore: ArchivePageSizing.initial,
                contextAfter: 0
            )
        )
        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(admission)
        )
        _ = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        controller.archiveWindowState = .authoritativeEmpty(
            target: .latest,
            freshnessToken: freshnessToken
        )
        controller.archiveWindowCommittedCoverageGeneration = 1
        controller.archiveWindowPendingSnapshot = nil
        controller.showSkeletonObserver.accept(false)

        XCTAssertEqual(
            controller.committedTimelineScope()?.coverageGeneration,
            1
        )
        XCTAssertTrue(controller.canRequestTimelineBoundary(direction: .older))
        XCTAssertEqual(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: 20,
                boundaryContext: ChatHistoryPagingBoundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 599,
                    visibleRealSections: [0, 1, 2]
                )
            ),
            .older
        )

        controller.archiveWindowCommittedCoverageGeneration = 0
        XCTAssertNil(controller.committedTimelineScope())
        XCTAssertFalse(controller.canRequestTimelineBoundary(direction: .older))
    }

    func testCommittedTimelineScopeAuthorizationBindsStateProofAndConversation() throws {
        let actorSnapshot = try makeSnapshot(generation: 7)
        let scope = try XCTUnwrap(ChatTimelineVerifiedScope(
            conversationKey: ChatTimelineConversationKey(
                owner: conversation.owner,
                jid: conversation.jid,
                conversationType: conversation.conversationType
            ),
            segment: actorSnapshot.verifiedSegment,
            coverageGeneration: 8,
            freshnessToken: actorSnapshot.freshnessToken
        ))
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
                state: .verified(actorSnapshot),
                committedCoverageGeneration: 8,
                sessionScope: scope,
                requiredScope: scope,
                conversationKey: scope.conversationKey,
                isShowingSkeleton: false,
                hasPendingPresentation: false
            ),
            "An older actor snapshot from the same session must not revoke a newer live proof"
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
                state: .authoritativeEmpty(
                    target: .latest,
                    freshnessToken: actorSnapshot.freshnessToken
                ),
                committedCoverageGeneration: 8,
                sessionScope: scope,
                requiredScope: scope,
                conversationKey: scope.conversationKey,
                isShowingSkeleton: false,
                hasPendingPresentation: false
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
                state: .authoritativeEmpty(
                    target: .latest,
                    freshnessToken: actorSnapshot.freshnessToken
                ),
                committedCoverageGeneration: 0,
                sessionScope: nil,
                requiredScope: nil,
                conversationKey: scope.conversationKey,
                isShowingSkeleton: false,
                hasPendingPresentation: false
            ),
            "The authoritative-empty baseline is not a paging or local-target proof"
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
                state: .verified(actorSnapshot),
                committedCoverageGeneration: 8,
                sessionScope: scope,
                requiredScope: scope,
                conversationKey: ChatTimelineConversationKey(
                    owner: conversation.owner,
                    jid: "other@example.org",
                    conversationType: conversation.conversationType
                ),
                isShowingSkeleton: false,
                hasPendingPresentation: false
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
                state: .verified(actorSnapshot),
                committedCoverageGeneration: 8,
                sessionScope: scope,
                requiredScope: scope,
                conversationKey: scope.conversationKey,
                isShowingSkeleton: false,
                hasPendingPresentation: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.authorizesCommittedTimelineScope(
                state: .authoritativeEmpty(
                    target: .latest,
                    freshnessToken: .sessionMAM(
                        connectionGeneration: 2,
                        queryID: "stale-session"
                    )
                ),
                committedCoverageGeneration: 8,
                sessionScope: scope,
                requiredScope: scope,
                conversationKey: scope.conversationKey,
                isShowingSkeleton: false,
                hasPendingPresentation: false
            ),
            "A reconnect token cannot authorize the previous session scope"
        )
    }

    @MainActor
    func testCommittedLocalPresentationTokenExcludesStoreAndRejectsStaleApply() throws {
        let controller = ChatViewController()
        let snapshot = try makeSnapshot(generation: 7)
        controller.archiveWindowState = .verified(snapshot)
        controller.archiveWindowCommittedCoverageGeneration = 7
        controller.showSkeletonObserver.accept(false)
        try installTimelineSession(on: controller, snapshot: snapshot)
        let session = try XCTUnwrap(controller.timelineSession)
        let scope = try XCTUnwrap(session.verifiedScope)
        controller.archiveWindowApplyGeneration = 11
        let token = ChatCommittedTimelineLocalPresentationToken(
            id: UUID(),
            purpose: .sensitiveReveal,
            scope: scope,
            sessionGeneration: session.snapshot.generation,
            applyGeneration: 11
        )

        XCTAssertTrue(controller.beginCommittedTimelineLocalPresentation(token))
        XCTAssertNil(controller.committedTimelineScope())
        XCTAssertEqual(
            controller.committedTimelineScope(
                matching: scope,
                allowingLocalPresentationID: token.id
            ),
            scope
        )

        controller.archiveWindowApplyGeneration = 12
        XCTAssertNil(controller.committedTimelineScope(
            matching: scope,
            allowingLocalPresentationID: token.id
        ))
        controller.invalidateCommittedTimelineLocalPresentation()
        XCTAssertNil(controller.committedTimelineLocalPresentationToken)
    }

    @MainActor
    func testQueuedLiveProofDoesNotRevokeActiveRevealOrLocalTargetOwner() throws {
        let controller = ChatViewController()
        let snapshot = try makeSnapshot(generation: 7)
        controller.archiveWindowState = .verified(snapshot)
        controller.archiveWindowCommittedCoverageGeneration = 7
        controller.showSkeletonObserver.accept(false)
        try installTimelineSession(on: controller, snapshot: snapshot)
        let session = try XCTUnwrap(controller.timelineSession)
        let scope = try XCTUnwrap(session.verifiedScope)
        let queuedLiveAdmission = ArchiveLiveEdgeAdmission(
            conversation: conversation,
            primaryID: "p10",
            latestWindow: snapshot,
            presentationIntent: ArchiveIntentDescriptor(
                conversation: conversation,
                locator: .latest,
                contextBefore: ArchivePageSizing.initial,
                contextAfter: 0
            )
        )

        for (offset, purpose) in [
            ChatCommittedTimelineLocalPresentationPurpose.sensitiveReveal,
            .localTarget,
        ].enumerated() {
            let applyGeneration = UInt64(13 + offset)
            controller.archiveWindowApplyGeneration = applyGeneration
            let token = ChatCommittedTimelineLocalPresentationToken(
                id: UUID(),
                purpose: purpose,
                scope: scope,
                sessionGeneration: session.snapshot.generation,
                applyGeneration: applyGeneration
            )
            XCTAssertTrue(
                controller.beginCommittedTimelineLocalPresentation(token)
            )
            controller.archiveWindowPendingLiveEdgeAdmission =
                queuedLiveAdmission
            XCTAssertNil(
                controller.committedTimelineScope(
                    matching: scope,
                    allowingLocalPresentationID: token.id
                ),
                "Queued live proof requires explicit owner-lane admission"
            )
            XCTAssertEqual(
                controller.committedTimelineScope(
                    matching: scope,
                    allowingLocalPresentationID: token.id,
                    allowsPendingLiveEdgeAdmission: true
                ),
                scope,
                "Queued proof-only live admission cannot revoke \(purpose)"
            )
            controller.archiveWindowPendingLiveEdgeAdmission = nil
            controller.invalidateCommittedTimelineLocalPresentation()
        }
    }

    func testLiveEdgeReprepareRetriesOnceOnlyWhileSameAdmissionRemainsCurrent() {
        XCTAssertTrue(ChatArchiveLiveEdgeRepreparePolicy.shouldReprepare(
            remainsCurrent: true,
            completedRetryCount: 0
        ))
        XCTAssertFalse(ChatArchiveLiveEdgeRepreparePolicy.shouldReprepare(
            remainsCurrent: true,
            completedRetryCount: 1
        ))
        XCTAssertFalse(ChatArchiveLiveEdgeRepreparePolicy.shouldReprepare(
            remainsCurrent: false,
            completedRetryCount: 0
        ))
    }

    func testSensitiveRevealFailureRetriesOnceOnlyWhileScopeRemainsCurrent() {
        XCTAssertTrue(
            ChatCommittedTimelineSensitiveRevealRetryPolicy.shouldRetry(
                remainsInCommittedScope: true,
                hasNewRevealRequest: false,
                didFail: true,
                retryCount: 0
            )
        )
        XCTAssertFalse(
            ChatCommittedTimelineSensitiveRevealRetryPolicy.shouldRetry(
                remainsInCommittedScope: true,
                hasNewRevealRequest: false,
                didFail: true,
                retryCount: 1
            )
        )
        XCTAssertTrue(
            ChatCommittedTimelineSensitiveRevealRetryPolicy.shouldRetry(
                remainsInCommittedScope: true,
                hasNewRevealRequest: true,
                didFail: false,
                retryCount: 1
            )
        )
        XCTAssertFalse(
            ChatCommittedTimelineSensitiveRevealRetryPolicy.shouldRetry(
                remainsInCommittedScope: false,
                hasNewRevealRequest: true,
                didFail: true,
                retryCount: 0
            )
        )
    }

    func testAuthoritativeEmptyPendingTargetRetriesOnlyWhenTargetIsDisjoint() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "42"))

        XCTAssertEqual(
            ChatAuthoritativeEmptyPendingTargetPolicy.action(
                emptyTarget: .latest,
                requestedTarget: .archiveID(cursor)
            ),
            .submitArchiveTarget
        )
        XCTAssertEqual(
            ChatAuthoritativeEmptyPendingTargetPolicy.action(
                emptyTarget: .archiveID(cursor),
                requestedTarget: .archiveID(cursor)
            ),
            .failTargetMissing
        )
        XCTAssertEqual(
            ChatAuthoritativeEmptyPendingTargetPolicy.action(
                emptyTarget: .latest,
                requestedTarget: nil
            ),
            .failTargetMissing
        )
    }

    @MainActor
    func testCancelledAuthoritativeEmptyMappingKeepsSkeletonWithoutRetryAffordance() {
        let controller = ChatViewController()
        controller.loadViewIfNeeded()
        controller.showSkeletonObserver.accept(true)
        let stateTask = Task<Void, Never> {}
        controller.archiveWindowStateTask = stateTask
        defer {
            stateTask.cancel()
            controller.archiveWindowStateTask = nil
        }
        controller.archiveWindowApplyGeneration = 9
        controller.archiveWindowAuthoritativeEmptyApplyGeneration = 9
        controller.archiveWindowAuthoritativeEmptyMappingGeneration = 44
        controller.archiveWindowState = .authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: "cancelled-empty"
            )
        )

        controller.finishCancelledArchiveEngineAuthoritativeEmptyApply(
            applyGeneration: 9,
            mappingGeneration: 44
        )

        XCTAssertNil(controller.archiveWindowAuthoritativeEmptyApplyGeneration)
        XCTAssertNil(controller.archiveWindowAuthoritativeEmptyMappingGeneration)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(
            controller.archiveWindowState,
            .authoritativeEmpty(
                target: .latest,
                freshnessToken: .sessionMAM(
                    connectionGeneration: 1,
                    queryID: "cancelled-empty"
                )
            )
        )
    }

    @MainActor
    func testInteractiveShortWindowChoosesOpenBoundaryFromGestureDirection() throws {
        let controller = ChatViewController()
        let snapshot = try makeSnapshot(
            generation: 8,
            reachesArchiveStart: false,
            reachesLiveEdge: false
        )
        controller.archiveWindowState = .verified(snapshot)
        controller.archiveWindowCommittedCoverageGeneration = 8
        controller.archiveWindowPendingSnapshot = nil
        controller.showSkeletonObserver.accept(false)
        try installTimelineSession(on: controller, snapshot: snapshot)
        let entireWindow = ChatHistoryPagingBoundaryContext(
            firstRealSection: 0,
            lastRealSection: 6,
            visibleRealSections: Array(0...6)
        )

        XCTAssertEqual(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: 18,
                boundaryContext: entireWindow
            ),
            .older
        )
        XCTAssertEqual(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: -18,
                boundaryContext: entireWindow
            ),
            .newer
        )
        XCTAssertNil(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: 0,
                boundaryContext: entireWindow
            )
        )
    }

    @MainActor
    func testBoundaryDecisionWaitsForPendingAtomicApplyInsteadOfCrossingUnknownWindow() throws {
        let controller = ChatViewController()
        let current = try makeSnapshot(
            generation: 9,
            reachesArchiveStart: false,
            reachesLiveEdge: true
        )
        controller.archiveWindowState = .verified(current)
        controller.archiveWindowCommittedCoverageGeneration = 9
        controller.archiveWindowPendingSnapshot = try makeSnapshot(
            generation: 10,
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "10"))),
            reachesArchiveStart: false,
            reachesLiveEdge: true
        )
        controller.showSkeletonObserver.accept(false)

        XCTAssertNil(
            controller.interactiveBoundaryPagingDirection(
                isUserScrolling: true,
                gestureTranslationY: 18,
                boundaryContext: ChatHistoryPagingBoundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 30,
                    visibleRealSections: [0, 1, 2]
                )
            ),
            "Paging must resume only after the previous verified page is atomically presented"
        )
    }

    func testUserLatestJumpBuildsAnEngineTargetInsteadOfRematerializingLocalArchive() {
        let intent = ChatArchiveWindowPresentationPolicy.latestTargetIntent(
            conversation: conversation
        )

        XCTAssertEqual(intent.conversation, conversation)
        XCTAssertEqual(intent.locator, .latest)
        XCTAssertEqual(intent.contextBefore, ArchivePageSizing.initial)
        XCTAssertEqual(intent.contextAfter, 0)
        XCTAssertEqual(intent.priority, .target)
    }

    @MainActor
    func testStackedPreparationSynchronouslyCommitsThirtyEngineNativeSkeletonRowsBeforeCompletion() {
        let controller = ChatViewController()
        controller.owner = conversation.owner
        controller.jid = conversation.jid
        controller.conversationType = conversation.conversationType
        controller.loadViewIfNeeded()

        var publishedDatasourceCounts: [Int] = []
        var didPublishCompleteSkeleton = false
        controller.datasourceDidSetForTests = { items in
            publishedDatasourceCounts.append(items.count)
            didPublishCompleteSkeleton =
                items.count == 30 &&
                items.allSatisfy { item in
                    guard item.isFakeMessage else { return false }
                    if case .skeleton = item.kind { return true }
                    return false
                }
        }

        var completionCallCount = 0
        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCallCount += 1
            XCTAssertTrue(
                didPublishCompleteSkeleton,
                "Stacked navigation completion must follow the logical 30-row skeleton publication"
            )
            XCTAssertEqual(controller.datasource.count, 30)
            XCTAssertEqual(controller.datasourceSnapshot.items.count, 30)
            XCTAssertEqual(controller.messagesCollectionView.numberOfSections, 30)
        }

        XCTAssertEqual(
            completionCallCount,
            1,
            "The engine-native skeleton commit must finish synchronously before compact navigation pushes"
        )
        XCTAssertEqual(ChatSkeletonTemplate.descriptors.count, 30)
        XCTAssertFalse(
            publishedDatasourceCounts.contains(0),
            "Opening may not publish an empty datasource between navigation intent and skeleton"
        )
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertEqual(
            controller.datasource.map(\.primary),
            ChatSkeletonTemplate.descriptors.map(\.primary),
            "The committed opening skeleton must use the stable engine-native row identities"
        )
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertFalse(controller.shouldShowInitialMessage.value)
        for item in controller.datasource {
            XCTAssertTrue(item.isFakeMessage)
            guard case .skeleton = item.kind else {
                XCTFail("Opening skeleton datasource contains a non-skeleton row")
                continue
            }
        }
    }

    func testOpeningAndReplacementTargetsCommitSkeletonBeforeArchiveSubmit() throws {
        let source = try archiveEngineSource()
        for marker in [
            "internal func startArchiveEnginePresentationIfNeeded()",
            "internal func submitArchiveEngineLatestTarget()",
            "internal func submitArchiveEngineTarget(",
        ] {
            let method = try sourceMethod(named: marker, in: source)
            let skeletonCommit = try XCTUnwrap(
                method.range(
                    of: "commitArchiveEngineOpeningSkeletonSynchronously()"
                )
            )
            let gateAcquire = try XCTUnwrap(
                method.range(of: "beginArchiveInteractiveCriticalSection()")
            )
            let archiveSubmit = try XCTUnwrap(method.range(of: "submit(intent)"))
            XCTAssertLessThan(
                gateAcquire.lowerBound,
                skeletonCommit.lowerBound,
                "\(marker) must synchronously own the interactive lane before skeleton mapping/apply"
            )
            XCTAssertLessThan(
                skeletonCommit.lowerBound,
                archiveSubmit.lowerBound,
                marker
            )
        }
    }

    func testSkeletonRemainsFullUntilMatchingUIKitGenerationCommits() throws {
        let snapshot = try makeSnapshot(generation: 7)
        let state = ArchiveWindowState.verified(snapshot)

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: state,
                committedCoverageGeneration: nil
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: state,
                committedCoverageGeneration: 6
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: state,
                committedCoverageGeneration: 7
            )
        )
    }

    func testOfflineAndRetryStateNeverRevealPreviouslyCommittedCache() throws {
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: .skeleton(reason: .offline, target: .latest),
                committedCoverageGeneration: 99
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
                for: .retryableFailure(
                    ArchiveRetryableFailure(
                        message: "timeout",
                        retryCount: 7,
                        canRetry: true
                    ),
                    target: .latest
                ),
                committedCoverageGeneration: 99
            )
        )
    }

    func testVerifiedTimelineFactoryRejectsMissingOrOutOfCoverageRows() throws {
        let segment = try makeSegment(oldest: "10", newest: "30")
        let key = ChatTimelineConversationKey(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )
        let p10 = message(primary: "p10", archiveID: "10")
        let p20 = message(primary: "p20", archiveID: "20")
        let p40 = message(primary: "p40", archiveID: "40")

        XCTAssertNil(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [p10],
                expectedPrimaryIDs: ["p10", "p20"],
                segment: segment,
                conversationKey: key
            )
        )
        XCTAssertNil(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [p10, p40],
                expectedPrimaryIDs: ["p10", "p40"],
                segment: segment,
                conversationKey: key
            )
        )
    }

    func testVerifiedTimelineFactoryOrdersRowsAndRepresentsBothUnknownEdges() throws {
        let segment = try makeSegment(
            oldest: "10",
            newest: "30",
            reachesArchiveStart: false,
            reachesLiveEdge: false
        )
        let key = ChatTimelineConversationKey(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )
        let snapshot = try XCTUnwrap(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [
                    message(primary: "p30", archiveID: "30"),
                    message(primary: "p10", archiveID: "10"),
                    message(primary: "p20", archiveID: "20"),
                ],
                expectedPrimaryIDs: ["p10", "p20", "p30"],
                segment: segment,
                conversationKey: key
            )
        )

        XCTAssertEqual(snapshot.items.map(\.primary), ["p10", "p20", "p30"])
        XCTAssertEqual(snapshot.state.residentPrimaryKeys, ["p10", "p20", "p30"])
        XCTAssertEqual(
            snapshot.state.segments,
            [
                .unknownOlder,
                .loadedRange(oldestArchiveId: "10", newestArchiveId: "30"),
                .unknownNewer,
            ]
        )
        XCTAssertFalse(snapshot.state.isResidentAtLiveTail)
    }

    func testVerifiedTimelineFactoryRepresentsConsumedOnlyArchiveWindowWithoutRows() throws {
        let segment = try makeSegment(
            oldest: "10",
            newest: "20",
            reachesArchiveStart: true,
            reachesLiveEdge: true
        )
        let key = ChatTimelineConversationKey(
            owner: conversation.owner,
            jid: conversation.jid,
            conversationType: conversation.conversationType
        )

        let snapshot = try XCTUnwrap(
            ChatArchiveVerifiedTimelineStateFactory.make(
                items: [],
                expectedPrimaryIDs: [],
                segment: segment,
                conversationKey: key
            )
        )

        XCTAssertEqual(snapshot.items, [])
        XCTAssertEqual(snapshot.state.residentPrimaryKeys, [])
        XCTAssertEqual(
            snapshot.state.segments,
            [
                .loadedRange(oldestArchiveId: "10", newestArchiveId: "20"),
                .liveTail,
            ]
        )
        XCTAssertTrue(snapshot.state.isResidentAtLiveTail)
    }

    func testConsumedOnlyLatestWindowDoesNotRequireANonexistentBottomMessage() throws {
        XCTAssertNil(
            ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                for: .latest,
                itemCount: 0
            )
        )
        XCTAssertEqual(
            ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                for: .latest,
                itemCount: 1
            ),
            .newestRealMessage
        )
        XCTAssertNil(
            ChatArchiveWindowPresentationPolicy.forceBottomAlignmentTarget(
                for: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))),
                itemCount: 1
            )
        )
    }

    func testVerifiedPrefetchCanKeepAlreadyCommittedWindowVisibleDuringAtomicApply() throws {
        let current = try makeSnapshot(generation: 7)
        let incoming = try makeSnapshot(
            generation: 8,
            target: .older(before: XCTUnwrap(ArchiveCursor(rawValue: "10")))
        )

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldPreserveCommittedContent(
                currentState: .verified(current),
                committedCoverageGeneration: 7,
                incoming: incoming
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldPreserveCommittedContent(
                currentState: .skeleton(reason: .boundaryGap, target: incoming.target),
                committedCoverageGeneration: nil,
                incoming: incoming
            )
        )
    }

    func testRepeatedPresentationStartForSameSemanticIntentPreservesCommittedProof() {
        let current = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let duplicate = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )

        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: true,
                currentIntent: current,
                incomingIntent: duplicate
            )
        )
    }

    func testPresentationStartResetsOnlyForFirstLifecycleAdmission() throws {
        let current = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let target = ArchiveWindowIntent(
            conversation: conversation,
            locator: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: false,
                currentIntent: nil,
                incomingIntent: current
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldResetForStart(
                isPresentationActive: true,
                currentIntent: current,
                incomingIntent: target
            )
        )
    }

    func testDuplicateVerifiedEmissionIsCoalescedWhilePendingAndAfterCommit() throws {
        let snapshot = try makeSnapshot(generation: 7)
        let state = ArchiveWindowState.verified(snapshot)

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: state,
                committedCoverageGeneration: nil,
                pendingSnapshot: snapshot,
                incoming: snapshot
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: state,
                committedCoverageGeneration: 7,
                pendingSnapshot: nil,
                incoming: snapshot
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCoalesceVerifiedState(
                currentState: state,
                committedCoverageGeneration: nil,
                pendingSnapshot: nil,
                incoming: snapshot
            )
        )
    }

    func testMissingVerifiedPrimaryFailsClosedBeforePresentation() throws {
        let segment = try makeSegment(oldest: "10", newest: "11")

        XCTAssertNil(ChatArchiveVerifiedTimelineStateFactory.make(
            items: [message(primary: "p10", archiveID: "10")],
            expectedPrimaryIDs: ["p10", "missing-p11"],
            segment: segment,
            conversationKey: ChatTimelineConversationKey(
                owner: conversation.owner,
                jid: conversation.jid,
                conversationType: conversation.conversationType
            )
        ))
    }

    func testInvalidMaterializationPreservesCurrentPresentationAndRetriesSilently() throws {
        let source = try archiveEngineSource()
        let method = try sourceMethod(
            named: "private func finishArchiveEngineVerifiedMaterializationFailure(",
            in: source
        )

        XCTAssertFalse(method.contains("presentArchiveBoundaryRetry("))
        XCTAssertFalse(method.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(method.contains("retryArchiveEngineWindow()"))
        XCTAssertTrue(method.contains("retryArchiveEngineVerifiedMaterialization("))
        XCTAssertTrue(method.contains("setSkeletonVisible(false)"))
        XCTAssertTrue(method.contains("setSkeletonVisible(true)"))
    }

    func testBenignLocalBoundaryDriftNeverEscalatesToEdgeRetry() {
        let benignFailures: [ChatTimelineLocalBoundaryFailure] = [
            .sessionGenerationChanged,
            .mappingCancelled,
            .atomicApplySuperseded,
            .transientAtomicApplyFailure,
        ]

        for failure in benignFailures {
            XCTAssertEqual(
                ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
                    for: failure,
                    isVisible: true,
                    retainsVerifiedProof: true,
                    completedRetryCount: 0
                ),
                .retryLocal,
                "\(failure) must remain an internal proof-scoped recovery"
            )
            XCTAssertEqual(
                ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
                    for: failure,
                    isVisible: false,
                    retainsVerifiedProof: true,
                    completedRetryCount: 0
                ),
                .dropSilent
            )
            XCTAssertEqual(
                ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
                    for: failure,
                    isVisible: true,
                    retainsVerifiedProof: true,
                    completedRetryCount:
                        ChatTimelineLocalBoundaryRecoveryPolicy.maximumRetryCount
                ),
                .dropSilent,
                "Persistent Realm/UIKit churn must terminate while preserving already verified content"
            )
        }
        XCTAssertEqual(
            ChatTimelineLocalBoundaryRecoveryPolicy.retryDelay(forAttempt: 1),
            0.05,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ChatTimelineLocalBoundaryRecoveryPolicy.retryDelay(forAttempt: 99),
            0.5,
            accuracy: 0.000_1,
            "Repeated local drift must use capped backoff"
        )
    }

    func testProofConnectionOrTargetReplacementStillFailsClosed() {
        XCTAssertEqual(
            ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
                for: .invalidProof,
                isVisible: true,
                retainsVerifiedProof: true,
                completedRetryCount: 0
            ),
            .failClosed
        )
        XCTAssertEqual(
            ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
                for: .connectionOrTargetReplaced,
                isVisible: false,
                retainsVerifiedProof: true,
                completedRetryCount: 0
            ),
            .failClosed
        )
        XCTAssertEqual(
            ChatTimelineLocalBoundaryRecoveryPolicy.disposition(
                for: .sessionGenerationChanged,
                isVisible: true,
                retainsVerifiedProof: false,
                completedRetryCount: 0
            ),
            .failClosed
        )
    }

    func testBenignLocalBoundaryRecoveryCannotReenterPagingGatewayOrExposeRetry() throws {
        let source = try archiveEngineSource()
        let retry = try sourceMethod(
            named: "private func retryTimelineBoundaryLocally(",
            in: source
        )
        let recoveryRouter = try sourceMethod(
            named: "private func handleTimelineBoundaryLocalFailure(",
            in: source
        )
        let drop = try sourceMethod(
            named: "private func dropSilentTimelineBoundaryRequest(",
            in: source
        )

        for method in [retry, recoveryRouter, drop] {
            XCTAssertFalse(method.contains("submitArchiveEngineLatestTarget"))
            XCTAssertFalse(method.contains("submitArchiveEngineBoundaryExpansion"))
            XCTAssertFalse(method.contains("setSkeletonVisible(true)"))
            XCTAssertFalse(method.contains("archiveEngineRetryView.present"))
            XCTAssertFalse(method.contains("presentArchiveBoundaryRetry("))
        }
        XCTAssertFalse(
            retry.contains("requestTimelineBoundary("),
            "A proof-scoped local retry must not re-enter the gateway that can submit a second MAM"
        )
        XCTAssertFalse(
            retry.contains("preserveTimelineBoundaryContentWithRetry("),
            "Benign UIKit/Realm drift must not fall through to a user-facing edge retry"
        )
        XCTAssertTrue(retry.contains("localRecoveryAttempt"))
        XCTAssertTrue(retry.contains("let retryDelay"))
        XCTAssertTrue(
            recoveryRouter.contains(
                "completedRetryCount: request.localRecoveryAttempt"
            ),
            "Every failed local attempt must consume the bounded recovery budget"
        )
        XCTAssertTrue(
            retry.contains("asyncAfter"),
            "Repeated Realm/UIKit drift must use capped local backoff instead of spinning on main"
        )
        XCTAssertFalse(
            recoveryRouter.contains(".preserveContentWithEdgeRetry"),
            "The local failure router must keep verified generation, mapping and atomic-apply drift internal"
        )
        XCTAssertTrue(drop.contains("setSkeletonVisible(false)"))
    }

    func testLocalBoundaryInvalidationCallSitesUseTypedRecoveryRouter() throws {
        let source = try archiveEngineSource()
        let receive = try sourceMethod(
            named: "private func receiveTimelineBoundaryPreparation(",
            in: source
        )
        XCTAssertTrue(receive.contains("failure: .sessionGenerationChanged"))
        XCTAssertTrue(receive.contains("failure: .mappingCancelled"))
        XCTAssertTrue(receive.contains("classifyTimelineBoundaryInvalidProof("))
        XCTAssertFalse(receive.contains("failTimelineBoundaryClosed("))

        let classify = try sourceMethod(
            named: "private func classifyTimelineBoundaryInvalidProof(",
            in: source
        )
        XCTAssertTrue(classify.contains("session.verifiedScope == request.scope"))
        XCTAssertTrue(classify.contains("? .sessionGenerationChanged"))

        let apply = try sourceMethod(
            named: "private func applyPreparedTimelineBoundary(",
            in: source
        )
        XCTAssertTrue(apply.contains("validationFailure = .mappingCancelled"))
        XCTAssertTrue(apply.contains("validationFailure = .sessionGenerationChanged"))
        XCTAssertTrue(apply.contains("handleTimelineBoundaryLocalFailure("))
        XCTAssertFalse(apply.contains("failTimelineBoundaryClosed("))

        let atomic = try sourceMethod(
            named: "private func handlePreparedTimelineBoundaryApplyResult(",
            in: source
        )
        XCTAssertTrue(atomic.contains("localFailure = .atomicApplySuperseded"))
        XCTAssertTrue(atomic.contains("handleTimelineBoundaryLocalFailure("))
        XCTAssertFalse(atomic.contains("failTimelineBoundaryClosed("))
    }

    func testStaleBoundaryProofFailsClosedWithoutSubmittingMAM() throws {
        let source = try archiveEngineSource()
        let failClosed = try sourceMethod(
            named: "private func failTimelineBoundaryClosed(",
            in: source
        )
        XCTAssertTrue(
            failClosed.contains("hasNewerTimelineBoundaryPresentationOwner(request)")
        )
        XCTAssertTrue(failClosed.contains("invalidateArchiveEngineVerifiedScope()"))
        XCTAssertTrue(failClosed.contains("setSkeletonVisible(true)"))
        XCTAssertTrue(failClosed.contains("setDatasourceLoadingEnabled(false)"))
        XCTAssertFalse(failClosed.contains("submitArchiveEngineLatestTarget()"))
        XCTAssertFalse(failClosed.contains("submitArchiveEngineBoundaryExpansion"))
        XCTAssertFalse(failClosed.contains("archiveEngine.submit"))
        XCTAssertFalse(failClosed.contains("requestTimelineBoundary("))
    }

    func testSkeletonStateCommitFailureAndOfflineReleaseInteractiveGate() throws {
        let source = try archiveEngineSource()
        let handler = try sourceMethod(
            named: "private func receiveArchiveWindowState(",
            in: source
        )

        XCTAssertTrue(handler.contains("let didCommitSkeleton"))
        XCTAssertTrue(handler.contains("if !didCommitSkeleton || reason == .offline"))
        XCTAssertTrue(handler.contains("let didCommitFailureSkeleton"))
        XCTAssertTrue(handler.contains("if !didCommitFailureSkeleton"))
        XCTAssertTrue(handler.contains("endArchiveInteractiveCriticalSection()"))
    }

    func testHistoryFailurePathsNeverPresentRetryAffordances() throws {
        let source = try archiveEngineSource()
        let methods = [
            try sourceMethod(
                named: "private func handleTimelineBoundaryLocalFailure(",
                in: source
            ),
            try sourceMethod(
                named: "private func receiveArchiveBoundaryTerminal(",
                in: source
            ),
            try sourceMethod(
                named: "private func finishArchiveEngineVerifiedMaterializationFailure(",
                in: source
            ),
            try sourceMethod(
                named: "private func receiveArchiveWindowState(",
                in: source
            ),
            try sourceMethod(
                named: "private func applyArchiveEngineAuthoritativeEmpty(",
                in: source
            ),
            try sourceMethod(
                named: "internal func finishCancelledArchiveEngineAuthoritativeEmptyApply(",
                in: source
            ),
        ]

        for method in methods {
            XCTAssertFalse(method.contains("presentArchiveBoundaryRetry("))
            XCTAssertFalse(method.contains("archiveBoundaryRetryView.present"))
            XCTAssertFalse(method.contains("archiveEngineRetryView.present"))
        }
    }

    func testActivityIdleCannotSynthesizeBoundaryFailureOrFinishRequest() throws {
        let source = try archiveEngineSource()
        let method = try sourceMethod(
            named: "private func receiveArchiveWindowActivity(",
            in: source
        )

        XCTAssertFalse(method.contains("timelineBoundaryRequest = nil"))
        XCTAssertFalse(method.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(method.contains("presentArchiveBoundaryRetry("))
        XCTAssertFalse(method.contains("endArchiveInteractiveCriticalSection()"))
    }

    func testBoundaryTerminalIsRequestKeyedAndSuccessWaitsForWinningUIKitApply() throws {
        let source = try archiveEngineSource()
        let receive = try sourceMethod(
            named: "private func receiveArchiveBoundaryTerminal(",
            in: source
        )
        let completion = try sourceMethod(
            named: "private func completeSucceededRemoteTimelineBoundaryIfReady(",
            in: source
        )

        XCTAssertTrue(receive.contains("outcome.requestID"))
        XCTAssertTrue(receive.contains("request.remoteIntentID"))
        XCTAssertTrue(receive.contains("case .succeeded"))
        XCTAssertTrue(receive.contains("case .failed(let failure)"))
        XCTAssertTrue(receive.contains("case .cancelled"))
        let failedStart = try XCTUnwrap(
            receive.range(of: "case .failed(let failure):")
        ).lowerBound
        let cancelledStart = try XCTUnwrap(
            receive.range(
                of: "case .cancelled:",
                range: failedStart..<receive.endIndex
            )
        ).lowerBound
        let failed = String(receive[failedStart..<cancelledStart])
        let actionSwitch = try XCTUnwrap(
            failed.range(of: "switch failure.recoveryAction")
        )
        let beforeActionSwitch = String(failed[..<actionSwitch.lowerBound])
        let retryStart = try XCTUnwrap(
            failed.range(of: "case .retry:")
        ).lowerBound
        let recoverStart = try XCTUnwrap(
            failed.range(of: "case .recoverAccount:")
        ).lowerBound
        let retryBranch = String(failed[retryStart..<recoverStart])

        XCTAssertFalse(beforeActionSwitch.contains("timelineBoundaryRequest = nil"))
        XCTAssertTrue(retryBranch.contains("scheduleArchiveHistoryAutomaticRetry("))
        XCTAssertTrue(retryBranch.contains("failure.retryCount"))
        XCTAssertFalse(retryBranch.contains("requestTimelineBoundary("))
        XCTAssertFalse(retryBranch.contains("retryArchiveEngineWindow()"))
        XCTAssertFalse(failed.contains("presentArchiveBoundaryRetry("))
        XCTAssertFalse(failed.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(failed.contains("setSkeletonVisible(true)"))
        XCTAssertFalse(failed.contains("archiveWindowCommittedCoverageGeneration = nil"))
        XCTAssertFalse(failed.contains("datasource ="))
        XCTAssertTrue(failed.contains("CredentialsExpiredPresenter"))
        XCTAssertTrue(completion.contains("request.didWinUIKitApply"))
        XCTAssertTrue(completion.contains("case .succeeded = request.remoteTerminal"))
        XCTAssertTrue(completion.contains("timelineBoundaryRequest = nil"))
    }

    func testRetryableWindowFailureSchedulesBackoffWhileKeepingSkeleton() throws {
        let source = try archiveEngineSource()
        let receive = try sourceMethod(
            named: "private func receiveArchiveWindowState(",
            in: source
        )
        let retryStart = try XCTUnwrap(
            receive.range(of: "case .retryableFailure(let failure, _):")
        ).lowerBound
        let verifiedStart = try XCTUnwrap(
            receive.range(
                of: "case .verified(let snapshot):",
                range: retryStart..<receive.endIndex
            )
        ).lowerBound
        let retryableFailure = String(receive[retryStart..<verifiedStart])

        XCTAssertTrue(retryableFailure.contains("setSkeletonVisible(true)"))
        XCTAssertTrue(retryableFailure.contains("switch failure.recoveryAction"))
        XCTAssertTrue(retryableFailure.contains("scheduleArchiveHistoryAutomaticRetry("))
        XCTAssertTrue(retryableFailure.contains("failure.retryCount"))
        XCTAssertTrue(retryableFailure.contains("CredentialsExpiredPresenter"))
        XCTAssertFalse(retryableFailure.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(retryableFailure.contains("presentArchiveBoundaryRetry("))
    }

    func testAutomaticHistoryRetryUsesBackoffAndActorRetryWithoutPagingGateway() throws {
        let source = try archiveEngineSource()
        let scheduler = try sourceMethod(
            named: "private func scheduleArchiveHistoryAutomaticRetry(",
            in: source
        )

        XCTAssertTrue(scheduler.contains("failureRetryCount"))
        XCTAssertTrue(
            scheduler.contains("asyncAfter") || scheduler.contains("Task.sleep"),
            "Automatic history retry must be delayed by backoff rather than spinning synchronously"
        )
        XCTAssertTrue(scheduler.contains("archiveEngine.retry(conversation:"))
        XCTAssertFalse(scheduler.contains("requestTimelineBoundary("))
        XCTAssertFalse(scheduler.contains("retryArchiveEngineWindow()"))
        XCTAssertFalse(scheduler.contains("presentArchiveBoundaryRetry("))
        XCTAssertFalse(scheduler.contains("archiveEngineRetryView.present"))
    }

    func testAutomaticHistoryRetryBackoffAccumulatesAcrossActorCyclesAndCapsAtThirtySeconds() {
        XCTAssertEqual(
            ChatArchiveHistoryAutomaticRetryPolicy.delay(
                actorFailureCount: 1,
                presentationAttempt: 1
            ),
            0.5
        )
        XCTAssertEqual(
            ChatArchiveHistoryAutomaticRetryPolicy.delay(
                actorFailureCount: 1,
                presentationAttempt: 4
            ),
            4.0
        )
        XCTAssertEqual(
            ChatArchiveHistoryAutomaticRetryPolicy.delay(
                actorFailureCount: 1,
                presentationAttempt: 7
            ),
            30.0
        )
        XCTAssertEqual(
            ChatArchiveHistoryAutomaticRetryPolicy.delay(
                actorFailureCount: 8,
                presentationAttempt: 1
            ),
            4.0,
            "The actor's bounded transient retry cycle contributes its own backoff"
        )
        XCTAssertEqual(
            ChatArchiveHistoryAutomaticRetryPolicy.delay(
                actorFailureCount: 8,
                presentationAttempt: 4
            ),
            30.0
        )
    }

    func testAutomaticHistoryRetryKeepsCumulativeAttemptUntilSemanticRequestTerminates() throws {
        let source = try archiveEngineSource()
        let scheduler = try sourceMethod(
            named: "private func scheduleArchiveHistoryAutomaticRetry(",
            in: source
        )
        let cancellation = try sourceMethod(
            named: "internal func cancelArchiveHistoryAutomaticRetry(",
            in: source
        )
        let receiver = try sourceMethod(
            named: "private func receiveArchiveWindowState(",
            in: source
        )

        XCTAssertTrue(
            scheduler.contains(
                "cancelArchiveHistoryAutomaticRetry(resetAttempt: false)"
            )
        )
        XCTAssertTrue(
            scheduler.contains("archiveHistoryAutomaticRetryAttempt += 1")
        )
        XCTAssertTrue(
            scheduler.contains("ChatArchiveHistoryAutomaticRetryPolicy.delay(")
        )
        XCTAssertTrue(cancellation.contains("resetAttempt: Bool = true"))
        XCTAssertTrue(
            cancellation.contains("archiveHistoryAutomaticRetryAttempt = 0")
        )
        XCTAssertTrue(
            receiver.contains(
                "case .retryableFailure, .skeleton(reason: .loadingTarget, target: _):"
            ),
            "The actor emits a loading-target skeleton at the start of every automatic cycle; it must not reset cumulative backoff"
        )
    }

    func testPrefetchRequiresMatchingCommittedProof() throws {
        let snapshot = try makeSnapshot(generation: 7)

        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: nil,
                isShowingSkeleton: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: 6,
                isShowingSkeleton: false
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.canPrefetch(
                snapshot: snapshot,
                committedCoverageGeneration: 7,
                isShowingSkeleton: false
            )
        )
    }

    func testPendingOpenRequestWaitsForVerifiedPresentationCommit() throws {
        let snapshot = try makeSnapshot(generation: 7)
        let state = ArchiveWindowState.verified(snapshot)

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
                isPresentationActive: true,
                state: state,
                committedCoverageGeneration: nil,
                pendingSnapshot: snapshot,
                isShowingSkeleton: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
                isPresentationActive: true,
                state: state,
                committedCoverageGeneration: 7,
                pendingSnapshot: nil,
                isShowingSkeleton: false
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
                isPresentationActive: false,
                state: nil,
                committedCoverageGeneration: nil,
                pendingSnapshot: nil,
                isShowingSkeleton: false
            )
        )
    }

    func testOnlyBoundaryExpansionPreservesTheExistingViewportAnchor() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "10"))

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .older(before: cursor)
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .newer(after: cursor)
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .latest
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .archiveID(cursor)
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldCapturePagingAnchor(
                for: .timestamp(Date())
            )
        )
    }

    func testOlderBoundaryApplyNeverDropsOffsetWhenLiveAnchorIsTemporarilyUnavailable() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        let retainedAnchor = ChatHistoryPageAnchor(
            primary: "visible-message",
            viewportRelativeMinY: 37
        )

        XCTAssertEqual(
            ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                for: .older(before: cursor),
                live: nil,
                retained: retainedAnchor
            ),
            retainedAnchor
        )

        let retainedPlan = ChatArchiveWindowPresentationPolicy.boundaryApplyPlan(
            for: .older(before: cursor),
            hasCapturedAnchor: true
        )
        XCTAssertFalse(retainedPlan.keepOffset)
        XCTAssertEqual(retainedPlan.restorePhase, .applyTransaction)

        let offsetFallbackPlan = ChatArchiveWindowPresentationPolicy.boundaryApplyPlan(
            for: .older(before: cursor),
            hasCapturedAnchor: false
        )
        XCTAssertTrue(offsetFallbackPlan.keepOffset)
        XCTAssertEqual(offsetFallbackPlan.restorePhase, .none)
    }

    func testCurrentBoundaryAnchorSupersedesAnchorCapturedAtRequestStart() throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        let retainedAnchor = ChatHistoryPageAnchor(
            primary: "request-start-message",
            viewportRelativeMinY: 20
        )
        let liveAnchor = ChatHistoryPageAnchor(
            primary: "current-visible-message",
            viewportRelativeMinY: 44
        )

        XCTAssertEqual(
            ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                for: .older(before: cursor),
                live: liveAnchor,
                retained: retainedAnchor
            ),
            liveAnchor
        )
        XCTAssertNil(
            ChatArchiveWindowPresentationPolicy.resolveBoundaryAnchor(
                for: .latest,
                live: liveAnchor,
                retained: retainedAnchor
            )
        )
    }

    func testMissingBoundaryAnchorFallsBackToSkeletonInsteadOfJumpingTheViewport() throws {
        let locator = ArchiveWindowLocator.older(
            before: try XCTUnwrap(ArchiveCursor(rawValue: "10"))
        )

        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: locator,
                hasUsableAnchor: false,
                hasCommittedContent: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: locator,
                hasUsableAnchor: true,
                hasCommittedContent: true
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldShowBoundaryRecoverySkeleton(
                for: .latest,
                hasUsableAnchor: false,
                hasCommittedContent: true
            )
        )
    }

    func testBoundaryPresentationRetriesTransientAtomicFailuresOnlyTwice() {
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .alignmentUnresolved(target: "anchor", error: 2),
                completedRetryCount: 0
            )
        )
        XCTAssertTrue(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .targetMissing(primary: "anchor"),
                completedRetryCount: 1
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .alignmentUnresolved(target: "anchor", error: 2),
                completedRetryCount: 2
            )
        )
        XCTAssertFalse(
            ChatArchiveWindowPresentationPolicy.shouldRetryAtomicApply(
                failure: .superseded,
                completedRetryCount: 0
            )
        )
    }

    func testPrependViewportFallbackAdmitsOnlyAnExactOldSuffix() {
        XCTAssertTrue(
            ChatPrependViewportFallbackPolicy.isEligible(
                previousPrimaryIDs: ["m67", "m68", "m69"],
                nextPrimaryIDs: ["m1", "m2", "m67", "m68", "m69"],
                anchorPrimary: "m68"
            )
        )
        XCTAssertFalse(
            ChatPrependViewportFallbackPolicy.isEligible(
                previousPrimaryIDs: ["m67", "m68", "m69"],
                nextPrimaryIDs: ["m1", "m67", "inserted", "m68", "m69"],
                anchorPrimary: "m68"
            )
        )
        XCTAssertFalse(
            ChatPrependViewportFallbackPolicy.isEligible(
                previousPrimaryIDs: ["m67", "m68", "m69"],
                nextPrimaryIDs: ["m1", "m2", "m67", "m68", "m69"],
                anchorPrimary: "missing"
            )
        )
    }

    func testPrependViewportFallbackUsesContentHeightDeltaAndClamps() {
        XCTAssertEqual(
            ChatPrependViewportFallbackPolicy.targetContentOffsetY(
                previousContentOffsetY: 120,
                previousContentHeight: 700,
                nextContentHeight: 1_100,
                minimumContentOffsetY: -20,
                maximumContentOffsetY: 900
            ),
            520,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatPrependViewportFallbackPolicy.targetContentOffsetY(
                previousContentOffsetY: 800,
                previousContentHeight: 700,
                nextContentHeight: 1_100,
                minimumContentOffsetY: -20,
                maximumContentOffsetY: 900
            ),
            900,
            accuracy: 0.001
        )
    }

    private func makeSnapshot(
        generation: UInt64,
        target: ArchiveWindowLocator = .latest,
        reachesArchiveStart: Bool = true,
        reachesLiveEdge: Bool = true
    ) throws -> ArchiveWindowSnapshot {
        ArchiveWindowSnapshot(
            messagePrimaryIDs: ["p10"],
            target: target,
            verifiedSegment: try makeSegment(
                oldest: "10",
                newest: "10",
                reachesArchiveStart: reachesArchiveStart,
                reachesLiveEdge: reachesLiveEdge
            ),
            coverageGeneration: generation,
            freshnessToken: .sessionMAM(
                connectionGeneration: 1,
                queryID: "presentation-\(generation)"
            )
        )
    }

    private func makeSegment(
        oldest: String,
        newest: String,
        reachesArchiveStart: Bool = true,
        reachesLiveEdge: Bool = true
    ) throws -> ArchiveCoverageSegment {
        try XCTUnwrap(
            ArchiveCoverageSegment(
                oldest: XCTUnwrap(ArchiveCursor(rawValue: oldest)),
                newest: XCTUnwrap(ArchiveCursor(rawValue: newest)),
                reachesArchiveStart: reachesArchiveStart,
                reachesLiveEdge: reachesLiveEdge,
                fingerprint: "session:1",
                isVerified: true
            )
        )
    }

    private func message(primary: String, archiveID: String) -> MessageStorageItem {
        let value = MessageStorageItem()
        value.primary = primary
        value.owner = conversation.owner
        value.opponent = conversation.jid
        value.conversationType = conversation.conversationType
        value.archivedId = archiveID
        value.date = Date(timeIntervalSince1970: TimeInterval(archiveID) ?? 0)
        return value
    }

    private func archiveEngineSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
            ),
            encoding: .utf8
        )
    }

    private func chatViewControllerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )
    }

    private func sourceMethod(
        named marker: String,
        in source: String
    ) throws -> String {
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(
            source[markerRange.lowerBound...].firstIndex(of: "{")
        )
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

    private func timelineSnapshot(
        generation: UInt64,
        cause: ChatTimelineSessionSnapshotCause,
        primaries: [String] = [],
        provisionalPrimaries: Set<String> = []
    ) -> ChatTimelineSessionSnapshot {
        let items = primaries.enumerated().map { offset, primary in
            let item = message(primary: primary, archiveID: String(offset + 1))
            if provisionalPrimaries.contains(primary) {
                item.archivedId = ""
                item.outgoing = true
            }
            return item
        }
        return ChatTimelineSessionSnapshot(
            generation: generation,
            cause: cause,
            items: items,
            state: .empty(
                owner: conversation.owner,
                jid: conversation.jid,
                conversationType: conversation.conversationType
            ),
            anchorRestore: nil,
            pageSize: ArchivePageSizing.history,
            residentIndex: ChatTimelineResidentIndex(items: items),
            readBoundary: nil,
            unreadMetadata: .empty,
            residentHardLimit: 600,
            residentChangeSet: nil,
            provisionalLocalOutgoingPrimaryIDs: provisionalPrimaries
        )
    }

    private func storePresentationEpoch(
        datasourceGeneration: UInt64,
        layoutGeneration: Int,
        width: CGFloat,
        searchText: String?
    ) -> ChatTimelineStorePresentationEpoch {
        ChatTimelineStorePresentationEpoch(
            datasourceGeneration: datasourceGeneration,
            layoutGeneration: layoutGeneration,
            layoutContext: ChatMessageLayoutContext(
                width: width,
                contentSizeCategory: UIContentSizeCategory.large.rawValue,
                localeIdentifier: "en_US",
                interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
                messageStyle: "noTail",
                cornerRadius: "16",
                avatarMode: "bottom"
            ),
            displayContext: ChatDisplayModelCacheContext(
                searchText: searchText,
                localeIdentifier: "en_US",
                contentSizeCategory: UIContentSizeCategory.large.rawValue,
                bodyFontName: "System",
                bodyFontPointSize: 17,
                interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue
            ),
            inSearchMode: searchText != nil,
            revealedSensitiveMediaPrimaries: [],
            canPinMessages: false
        )
    }

    private func makeTimelineSession(
        store: ChatTimelineSessionStore
    ) -> ChatTimelineSession {
        ChatTimelineSession(
            store: store,
            pageSize: ArchivePageSizing.history,
            conversationKey: ChatTimelineConversationKey(
                owner: conversation.owner,
                jid: conversation.jid,
                conversationType: conversation.conversationType
            ),
            observesStoreImmediately: false
        )
    }

    @MainActor
    private func installTimelineSession(
        on controller: ChatViewController,
        snapshot: ArchiveWindowSnapshot
    ) throws {
        controller.owner = conversation.owner
        controller.jid = conversation.jid
        controller.conversationType = conversation.conversationType
        let item = message(primary: "p10", archiveID: "10")
        let store = ChatArchiveBoundaryDecisionStore(items: [item])
        let session = ChatTimelineSession(
            store: store,
            pageSize: ArchivePageSizing.history,
            conversationKey: ChatTimelineConversationKey(
                owner: conversation.owner,
                jid: conversation.jid,
                conversationType: conversation.conversationType
            ),
            observesStoreImmediately: false
        )
        controller.timelineSession = session
        XCTAssertNotNil(session.installArchiveEngineVerifiedWindow(snapshot))
    }
}

private final class ChatArchiveBoundaryDecisionStore: ChatTimelineSessionStore {
    private let storedItems: [MessageStorageItem]
    private(set) var observedBaselines: [ChatTimelineStoreObservationBaseline] = []
    private var onChange: ((ChatTimelineStoreChange) -> Void)?

    init(items: [MessageStorageItem]) {
        storedItems = ChatTimelineOrdering.deduplicatedChronological(items)
    }

    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot { .empty }

    func latest(limit: Int) -> [MessageStorageItem] {
        Array(storedItems.suffix(max(0, limit)))
    }

    func older(
        before boundary: ChatTimelineBoundary,
        limit: Int
    ) -> [MessageStorageItem] {
        Array(storedItems.filter {
            ChatTimelinePositionKey(message: $0) <
                ChatTimelinePositionKey(boundary: boundary)
        }.suffix(max(0, limit)))
    }

    func newer(
        after boundary: ChatTimelineBoundary,
        limit: Int
    ) -> [MessageStorageItem] {
        Array(storedItems.filter {
            ChatTimelinePositionKey(message: $0) >
                ChatTimelinePositionKey(boundary: boundary)
        }.prefix(max(0, limit)))
    }

    func around(
        anchor: MessageStorageItem,
        before: Int,
        after: Int
    ) -> [MessageStorageItem] {
        guard let index = storedItems.firstIndex(where: {
            $0.primary == anchor.primary
        }) else { return [] }
        let lower = max(0, index - max(0, before))
        let upper = min(storedItems.count, index + max(0, after) + 1)
        return Array(storedItems[lower..<upper])
    }

    func message(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        storedItems.first {
            (primary?.isNotEmpty == true && $0.primary == primary) ||
                (archivedId?.isNotEmpty == true && $0.archivedId == archivedId) ||
                (messageId?.isNotEmpty == true && $0.messageId == messageId)
        }
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        let keys = Set(primaryKeys)
        return storedItems.filter { keys.contains($0.primary) }
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata { .empty }

    func firstIncoming(
        afterArchiveBoundaryId boundaryArchivedId: String
    ) -> MessageStorageItem? {
        nil
    }

    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        observedBaselines.append(baseline)
        self.onChange = onChange
        return ChatArchiveBoundaryDecisionObservation()
    }

    func emit(_ change: ChatTimelineStoreChange) {
        onChange?(change)
    }
}

private final class ChatArchiveBoundaryDecisionObservation:
    ChatTimelineStoreObservation {
    func replaceResidentItems(_ items: [MessageStorageItem]) {}
    func invalidate() {}
}
