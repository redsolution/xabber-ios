import XCTest

final class ChatArchiveLegacyPagingHardCutTests: XCTestCase {
    func testScrollDragAndPrefetchUseOneTimelineBoundaryGateway() throws {
        let datasourceSource = try productionSource(
            "controllers/chats/chat/datasource/ChatViewController+PrefetchDatasource.swift"
        )
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let controllerSource = try productionSource(
            "controllers/chats/chat/ChatViewController.swift"
        )

        XCTAssertTrue(
            datasourceSource.contains("requestTimelineBoundary("),
            "Every boundary producer must enter the single timeline/session gateway"
        )
        XCTAssertFalse(
            datasourceSource.contains("submitArchiveEnginePage("),
            "PrefetchDatasource must not bypass local virtual-timeline paging and submit MAM directly"
        )
        XCTAssertTrue(archiveSource.contains("prepareVerifiedLocalBoundary("))
        XCTAssertTrue(archiveSource.contains("inspectPreparedVerifiedLocalBoundary(prepared)"))
        XCTAssertTrue(archiveSource.contains("commitPreparedVerifiedLocalBoundary("))
        XCTAssertTrue(archiveSource.contains("private func submitArchiveEngineBoundaryExpansion("))
        XCTAssertTrue(archiveSource.contains("scope.oldest"))
        XCTAssertTrue(archiveSource.contains("scope.newest"))
        XCTAssertFalse(archiveSource.contains("internal func submitArchiveEnginePage("))
        XCTAssertTrue(archiveSource.contains("request.phase == .waitingRemote"))
        for forbidden in [
            "ChatArchiveEngineRetryView",
            "ChatArchiveBoundaryRetryView",
            "archiveEngineRetryView",
            "archiveBoundaryRetryView",
            "presentArchiveBoundaryRetry(",
            "dismissArchiveBoundaryRetry()",
        ] {
            XCTAssertFalse(archiveSource.contains(forbidden), forbidden)
            XCTAssertFalse(controllerSource.contains(forbidden), forbidden)
        }
        XCTAssertTrue(archiveSource.contains("boundaryTerminals("))
        XCTAssertTrue(archiveSource.contains("receiveArchiveBoundaryTerminal("))
        XCTAssertTrue(archiveSource.contains("scheduleArchiveHistoryAutomaticRetry("))
        XCTAssertTrue(archiveSource.contains("archiveEngine.retry(conversation:"))
        XCTAssertTrue(archiveSource.contains("prepareArchiveEngineVerifiedWindow(snapshot)"))
        XCTAssertTrue(archiveSource.contains("inspectPreparedArchiveEngineVerifiedWindow("))
        XCTAssertTrue(archiveSource.contains("commitPreparedArchiveEngineVerifiedWindow("))
        XCTAssertTrue(archiveSource.contains("finishArchiveEngineVerifiedMaterializationFailure("))
        XCTAssertFalse(
            archiveSource.contains("session.installArchiveEngineVerifiedWindow(snapshot)")
        )
        XCTAssertFalse(datasourceSource.contains("handleBoundaryPagingCandidate"))
        XCTAssertFalse(datasourceSource.contains("applyPendingBoundaryPagingAfterScrollRest"))
        XCTAssertFalse(datasourceSource.contains("ChatHistoryPagingPolicy"))
    }

    func testPagingNeverInfersFailureFromActivityIdleOrUsesCenteredRetry() throws {
        let source = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let activity = try sourceMethod(
            named: "private func receiveArchiveWindowActivity(",
            in: source
        )
        let terminal = try sourceMethod(
            named: "private func receiveArchiveBoundaryTerminal(",
            in: source
        )

        XCTAssertFalse(activity.contains("timelineBoundaryRequest"))
        XCTAssertFalse(activity.contains("Retry"))
        XCTAssertFalse(activity.contains("endArchiveInteractiveCriticalSection"))
        XCTAssertTrue(terminal.contains("outcome.requestID"))
        XCTAssertTrue(terminal.contains("scheduleArchiveHistoryAutomaticRetry("))
        XCTAssertFalse(terminal.contains("presentArchiveBoundaryRetry("))
        XCTAssertFalse(terminal.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(terminal.contains("setSkeletonVisible(true)"))
        XCTAssertFalse(terminal.contains("invalidateArchiveEngineVerifiedScope()"))
    }

    func testVerifiedSearchTargetHasLocalProofScopedPreparationBeforeRemoteHandoff() throws {
        let sessionSource = try productionSource(
            "controllers/chats/chat/ChatTimelineSession.swift"
        )
        let engineSource = try productionSource(
            "controllers/chats/chat/ChatVirtualTimelineEngine.swift"
        )

        XCTAssertTrue(sessionSource.contains("func prepareVerifiedLocalTarget("))
        XCTAssertTrue(sessionSource.contains("func inspectPreparedVerifiedLocalTarget("))
        XCTAssertTrue(sessionSource.contains("func commitPreparedVerifiedLocalTarget("))
        XCTAssertTrue(engineSource.contains("func openAround("))
        XCTAssertTrue(engineSource.contains(".needsArchiveTarget(archiveCursor)"))
        XCTAssertTrue(sessionSource.contains("func invalidateVerifiedScope()"))
    }

    func testTimelineConsumersUseUnifiedCommittedScopeAuthorization() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let prefetchSource = try productionSource(
            "controllers/chats/chat/datasource/ChatViewController+PrefetchDatasource.swift"
        )
        let searchSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        )
        let controllerSource = try productionSource(
            "controllers/chats/chat/ChatViewController.swift"
        )
        let archiveMethods = [
            "internal func canRequestTimelineBoundary(",
            "internal func requestTimelineBoundary(",
            "internal func prefetchTimelineBoundaryIfNeeded(",
            "private func applyPreparedTimelineBoundary("
        ]
        for marker in archiveMethods {
            let method = try sourceMethod(named: marker, in: archiveSource)
            XCTAssertTrue(method.contains("committedTimelineScope("), marker)
            XCTAssertFalse(method.contains("case .verified"), marker)
        }
        let interactive = try sourceMethod(
            named: "internal func interactiveBoundaryPagingDirection(",
            in: prefetchSource
        )
        XCTAssertTrue(interactive.contains("committedTimelineScope("))
        XCTAssertFalse(interactive.contains("case .verified"))

        let localTarget = try sourceMethod(
            named: "private func isCurrentProofScopedLocalTargetPresentation(",
            in: searchSource
        )
        XCTAssertTrue(localTarget.contains("committedTimelineScope("))
        XCTAssertFalse(localTarget.contains("case .verified"))
        XCTAssertTrue(controllerSource.contains(
            "committedTimelineLocalPresentationToken != nil"
        ))
    }

    func testFirstSensitiveLiveRevealRemapsCurrentSessionWithoutActorSnapshotOrMAM() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let cellSource = try productionSource(
            "controllers/chats/chat/delegate/action/ChatViewController+CellDelegate.swift"
        )
        let reveal = try sourceMethod(
            named: "internal func revealSensitiveMediaAndRemapCommittedTimeline(",
            in: archiveSource
        )
        let remap = try sourceMethod(
            named: "internal func drainPendingCommittedTimelineSensitiveRevealRemap(",
            in: archiveSource
        )

        XCTAssertTrue(cellSource.contains(
            "revealSensitiveMediaAndRemapCommittedTimeline("
        ))
        XCTAssertFalse(cellSource.contains(
            "refreshArchiveEngineVerifiedPresentation()"
        ))
        XCTAssertTrue(reveal.contains("revealedSensitiveMediaPrimaries.insert"))
        XCTAssertTrue(reveal.contains(
            "drainPendingCommittedTimelineSensitiveRevealRemap()"
        ))
        XCTAssertTrue(remap.contains("let base = session.snapshot"))
        XCTAssertTrue(remap.contains("dataset: base.items"))
        XCTAssertTrue(remap.contains("mode: .targetedDiff"))
        XCTAssertTrue(remap.contains("presentationCommitMode: .atomicInitialFrame"))
        XCTAssertTrue(remap.contains("transactionCommitAuthorization:"))
        XCTAssertTrue(remap.contains("ChatTimelineStorePresentationEpochPolicy"))
        XCTAssertTrue(remap.contains(
            "ChatCommittedTimelineSensitiveRevealRetryPolicy"
        ))
        XCTAssertTrue(remap.contains(".shouldRetry("))
        XCTAssertFalse(remap.contains("ArchiveWindowSnapshot("))
        XCTAssertFalse(remap.contains("applyArchiveEngineVerifiedSnapshot("))
        XCTAssertFalse(remap.contains("archiveEngine.submit"))

        let transaction = try XCTUnwrap(
            remap.range(of: "transactionCompletion: { [weak self, weak session] result in")
        )
        let completion = try XCTUnwrap(
            remap.range(
                of: "completion: { [weak self, weak session] in",
                range: transaction.upperBound..<remap.endIndex
            )
        )
        let transactionBody = String(
            remap[transaction.lowerBound..<completion.lowerBound]
        )
        let committedBody = String(remap[completion.lowerBound...])
        XCTAssertTrue(transactionBody.contains(
            "guard case .failed = result else { return }"
        ))
        XCTAssertTrue(committedBody.contains(
            "finishCommittedTimelineLocalPresentation("
        ))
        XCTAssertTrue(committedBody.contains(
            "committedTimelineSensitiveRevealRemapRetryCount = 0"
        ))
        XCTAssertGreaterThanOrEqual(
            remap.components(
                separatedBy: "allowsPendingLiveEdgeAdmission: true"
            ).count - 1,
            4
        )
    }

    func testLocalBoundarySuccessReleasesTokenBeforeDeferredPresentationDrains() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let apply = try sourceMethod(
            named: "private func applyPreparedTimelineBoundary(",
            in: archiveSource
        )
        let completion = try XCTUnwrap(
            apply.range(of: "completion: { [weak self, weak session] in")
        )
        let success = String(apply[completion.lowerBound...])
        let clear = try XCTUnwrap(
            success.range(of: "self.timelineBoundaryRequest = nil")
        )
        let finish = try XCTUnwrap(
            success.range(
                of: "self.finishCommittedTimelineLocalPresentation(\n                    id: current.id"
            )
        )
        let pendingTarget = try XCTUnwrap(
            success.range(of: "self.performPendingOpenMessageRequestIfNeeded()")
        )
        let drains = try XCTUnwrap(
            success.range(
                of: "self.drainTimelinePresentationLanesAfterAnchorTerminal()"
            )
        )

        XCTAssertLessThan(clear.lowerBound, finish.lowerBound)
        XCTAssertLessThan(finish.lowerBound, pendingTarget.lowerBound)
        XCTAssertLessThan(pendingTarget.lowerBound, drains.lowerBound)
    }

    func testVerifiedMaterializationPreserveFailureWakesTargetBeforeAuxiliaryDrains() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let failure = try sourceMethod(
            named: "private func finishArchiveEngineVerifiedMaterializationFailure(",
            in: archiveSource
        )
        let preserve = try XCTUnwrap(
            failure.range(of: "case .preserveContent:")
        )
        let wake = try XCTUnwrap(
            failure.range(of: "performPendingOpenMessageRequestIfNeeded()")
        )
        let drains = try XCTUnwrap(
            failure.range(
                of: "drainTimelinePresentationLanesAfterAnchorTerminal()"
            )
        )
        let fullSkeleton = try XCTUnwrap(
            failure.range(of: "case .fullSkeleton:")
        )

        XCTAssertLessThan(preserve.lowerBound, wake.lowerBound)
        XCTAssertLessThan(wake.lowerBound, drains.lowerBound)
        XCTAssertLessThan(
            drains.lowerBound,
            fullSkeleton.lowerBound,
            "A full-skeleton failure must keep the target deferred for fresh proof"
        )
    }

    func testRemoteBoundaryFailureKeepsRequestAndSchedulesAutomaticRetry() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let terminal = try sourceMethod(
            named: "private func receiveArchiveBoundaryTerminal(",
            in: archiveSource
        )
        XCTAssertTrue(terminal.contains("case .failed(let failure)"))
        let retryStart = try XCTUnwrap(
            terminal.range(of: "case .retry:")
        ).lowerBound
        let recoverStart = try XCTUnwrap(
            terminal.range(
                of: "case .recoverAccount:",
                range: retryStart..<terminal.endIndex
            )
        ).lowerBound
        let retryBranch = String(terminal[retryStart..<recoverStart])

        XCTAssertTrue(retryBranch.contains("scheduleArchiveHistoryAutomaticRetry("))
        XCTAssertTrue(retryBranch.contains("failure.retryCount"))
        XCTAssertFalse(retryBranch.contains("timelineBoundaryRequest = nil"))
        XCTAssertFalse(retryBranch.contains("performPendingOpenMessageRequestIfNeeded()"))
        XCTAssertFalse(retryBranch.contains("requestTimelineBoundary("))
        XCTAssertFalse(terminal.contains("presentArchiveBoundaryRetry("))
        XCTAssertFalse(terminal.contains("archiveEngineRetryView.present"))
    }

    func testArchiveSuccessAuthorizesPendingTargetBeforeWakeAndAuxiliaryDrains() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        for (marker, wakeToken) in [
            (
                "private func applyArchiveEngineVerifiedSnapshot(",
                "performPendingOpenMessageRequestIfNeeded()"
            ),
            (
                "private func applyArchiveEngineAuthoritativeEmpty(",
                "resolvePendingOpenMessageRequestAfterAuthoritativeEmpty("
            )
        ] {
            let method = try sourceMethod(named: marker, in: archiveSource)
            let receipt = try XCTUnwrap(
                method.range(of: "recordArchiveSkeletonTerminalIfNeeded()")
            )
            let terminal = String(method[receipt.lowerBound...])
            let skeletonOff = try XCTUnwrap(
                terminal.range(of: "setSkeletonVisible(false)")
            )
            let datasourceEnabled = try XCTUnwrap(
                terminal.range(of: "setDatasourceLoadingEnabled(true)")
            )
            let wake = try XCTUnwrap(
                terminal.range(of: wakeToken)
            )
            let drains = try XCTUnwrap(
                terminal.range(
                    of: "drainTimelinePresentationLanesAfterAnchorTerminal()"
                )
            )

            XCTAssertLessThan(skeletonOff.lowerBound, wake.lowerBound, marker)
            XCTAssertLessThan(datasourceEnabled.lowerBound, wake.lowerBound, marker)
            XCTAssertLessThan(wake.lowerBound, drains.lowerBound, marker)
        }

        let liveTerminal = try sourceMethod(
            named: "private func finishCommittedArchiveLiveEdgeAdmission(",
            in: archiveSource
        )
        let authoritativeEmpty = try XCTUnwrap(
            liveTerminal.range(of: "case .authoritativeEmpty = state")
        )
        let skeletonOff = try XCTUnwrap(
            liveTerminal.range(of: "setSkeletonVisible(false)")
        )
        let wake = try XCTUnwrap(
            liveTerminal.range(of: "performPendingOpenMessageRequestIfNeeded()")
        )
        let drains = try XCTUnwrap(
            liveTerminal.range(
                of: "drainTimelinePresentationLanesAfterAnchorTerminal()"
            )
        )
        XCTAssertLessThan(authoritativeEmpty.lowerBound, skeletonOff.lowerBound)
        XCTAssertLessThan(skeletonOff.lowerBound, wake.lowerBound)
        XCTAssertLessThan(wake.lowerBound, drains.lowerBound)
    }

    func testAuthoritativeEmptyApplyOwnsForeignLaneUntilExactTerminal() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let controllerSource = try productionSource(
            "controllers/chats/chat/ChatViewController.swift"
        )
        let searchSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        )

        let receive = try sourceMethod(
            named: "private func receiveArchiveWindowState(",
            in: archiveSource
        )
        let compactReceive = receive
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let markerSet = try XCTUnwrap(
            compactReceive.range(
                of: "archiveWindowAuthoritativeEmptyApplyGeneration = applyGeneration"
            )
        )
        let emptyApplyCall = try XCTUnwrap(
            compactReceive.range(of: "applyArchiveEngineAuthoritativeEmpty(")
        )
        XCTAssertLessThan(markerSet.lowerBound, emptyApplyCall.lowerBound)

        let foreign = try sourceMethod(
            named: "internal func shouldDeferLoadedAnchorForForeignTimelinePresentation(",
            in: controllerSource
        )
        XCTAssertTrue(foreign.contains(
            "archiveWindowAuthoritativeEmptyApplyGeneration != nil"
        ))

        let emptyApply = try sourceMethod(
            named: "private func applyArchiveEngineAuthoritativeEmpty(",
            in: archiveSource
        )
        let compactEmptyApply = emptyApply
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        XCTAssertGreaterThanOrEqual(
            compactEmptyApply.components(
                separatedBy: "archiveWindowAuthoritativeEmptyApplyGeneration == applyGeneration"
            ).count - 1,
            3
        )
        XCTAssertTrue(emptyApply.contains(
            "anchorTransactionGate.snapshot.positioningStarted"
        ))
        XCTAssertTrue(emptyApply.contains(
            "deferArchiveEnginePresentationIfAnchorPositioningActive("
        ))
        XCTAssertOrdered(
            "archiveWindowAuthoritativeEmptyApplyGeneration = nil",
            before: "resolvePendingOpenMessageRequestAfterAuthoritativeEmpty(",
            in: emptyApply
        )

        XCTAssertTrue(emptyApply.contains(
            "finishCancelledArchiveEngineAuthoritativeEmptyApply("
        ))
        let cancel = try sourceMethod(
            named: "internal func finishCancelledArchiveEngineAuthoritativeEmptyApply(",
            in: archiveSource
        )
        XCTAssertTrue(cancel.contains(
            "archiveWindowAuthoritativeEmptyApplyGeneration = nil"
        ))
        XCTAssertTrue(cancel.contains(
            "archiveWindowAuthoritativeEmptyMappingGeneration = nil"
        ))
        XCTAssertTrue(cancel.contains(
            "scheduleArchiveEngineAuthoritativeEmptyMaterializationRetry("
        ))
        XCTAssertFalse(cancel.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(cancel.contains("presentArchiveBoundaryRetry("))

        let terminalRoute = try sourceMethod(
            named: "internal func resolvePendingOpenMessageRequestAfterAuthoritativeEmpty(",
            in: searchSource
        )
        XCTAssertEqual(
            terminalRoute.components(
                separatedBy: "submitArchiveEngineTarget(request)"
            ).count - 1,
            1
        )
        XCTAssertTrue(terminalRoute.contains("failActiveAnchorExecution("))
        XCTAssertFalse(terminalRoute.contains(
            "performPendingOpenMessageRequestIfNeeded()"
        ))
    }

    func testLoadedAnchorViewportLaneDefersEveryDatasourceProducerAndWakesInOrder() throws {
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let searchSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        )
        let controllerSource = try productionSource(
            "controllers/chats/chat/ChatViewController.swift"
        )

        let queue = try sourceMethod(
            named: "internal func queueOpenMessageRequest(",
            in: searchSource
        )
        let foreignGuard = try XCTUnwrap(
            queue.range(
                of: "shouldDeferLoadedAnchorForForeignTimelinePresentation("
            )
        )
        let loadedRoute = try XCTUnwrap(
            queue.range(of: "performLoadedOpenMessageRequestIfPossible(")
        )
        XCTAssertLessThan(foreignGuard.lowerBound, loadedRoute.lowerBound)
        XCTAssertTrue(queue.contains("pendingOpenMessageRequest = request"))

        let pending = try sourceMethod(
            named: "internal func performPendingOpenMessageRequestIfNeeded()",
            in: searchSource
        )
        let pendingGuard = try XCTUnwrap(
            pending.range(
                of: "shouldDeferLoadedAnchorForForeignTimelinePresentation("
            )
        )
        let pendingLoadedRoute = try XCTUnwrap(
            pending.range(of: "performLoadedOpenMessageRequestIfPossible(")
        )
        XCTAssertLessThan(pendingGuard.lowerBound, pendingLoadedRoute.lowerBound)
        XCTAssertTrue(pending.contains("allowingLocalPresentationID:"))

        for marker in [
            "internal func requestTimelineBoundary(",
            "private func drainPendingArchiveLiveEdgeAdmission()",
            "internal func drainPendingCommittedTimelineSensitiveRevealRemap()",
        ] {
            let method = try sourceMethod(named: marker, in: archiveSource)
            XCTAssertTrue(
                method.contains("anchorTransactionGate.snapshot.positioningStarted"),
                marker
            )
        }
        for marker in [
            "private func applyArchiveEngineVerifiedSnapshot(",
            "private func applyArchiveEngineAuthoritativeEmpty("
        ] {
            let method = try sourceMethod(named: marker, in: archiveSource)
            XCTAssertTrue(
                method.contains(
                    "deferArchiveEnginePresentationIfAnchorPositioningActive("
                ),
                marker
            )
        }
        let storeDrain = try sourceMethod(
            named: "internal func drainPendingTimelineStoreSnapshot()",
            in: controllerSource
        )
        XCTAssertTrue(storeDrain.contains(
            "anchorTransactionGate.snapshot.positioningStarted"
        ))
        let storeTerminal = try sourceMethod(
            named: "private func finishTimelineStoreSnapshotApply(",
            in: controllerSource
        )
        let coordinatorTerminal = try XCTUnwrap(
            storeTerminal.range(
                of: "timelineStoreSnapshotApplyCoordinator.complete("
            )
        )
        let pendingWake = try XCTUnwrap(
            storeTerminal.range(
                of: "performPendingOpenMessageRequestIfNeeded()"
            )
        )
        XCTAssertLessThan(
            coordinatorTerminal.lowerBound,
            pendingWake.lowerBound,
            "Even a store mapping rejected before UIKit-token acquisition must wake a deferred loaded anchor"
        )
        let datasetSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+Dataset.swift"
        )
        let structuralTerminal = try sourceMethod(
            named: "internal func finishChatDatasourceStructuralTransaction()",
            in: datasetSource
        )
        let structuralWake = try XCTUnwrap(
            structuralTerminal.range(
                of: "performPendingOpenMessageRequestIfNeeded()"
            )
        )
        let structuralDrains = try XCTUnwrap(
            structuralTerminal.range(
                of: "drainTimelinePresentationLanesAfterAnchorTerminal()"
            )
        )
        XCTAssertLessThan(
            structuralWake.lowerBound,
            structuralDrains.lowerBound
        )

        let finishLocal = try sourceMethod(
            named: "internal func finishCommittedTimelineLocalPresentation(",
            in: archiveSource
        )
        XCTAssertFalse(
            finishLocal.contains("performPendingOpenMessageRequestIfNeeded()"),
            "Token release must not re-enter a still-owned proof-local request"
        )
        XCTAssertFalse(
            finishLocal.contains(
                "drainTimelinePresentationLanesAfterAnchorTerminal()"
            ),
            "The terminal owner must choose wake-before-drain ordering explicitly"
        )

        for marker in [
            "private func finishActiveAnchorExecution(",
            "private func clearAnchorExecutionPresentationState("
        ] {
            let terminal = try sourceMethod(named: marker, in: searchSource)
            XCTAssertTrue(
                terminal.contains(
                    "drainTimelinePresentationLanesAfterAnchorTerminal()"
                ),
                marker
            )
        }
    }

    func testCollectionPrefetchUsesArchiveEngineForHistoryAndHasNoLegacyPageWarmup() throws {
        let datasourceSource = try productionSource(
            "controllers/chats/chat/datasource/ChatViewController+PrefetchDatasource.swift"
        )
        let contentPrefetchSource = try productionSource(
            "controllers/chats/chat/ChatCollectionPrefetcher.swift"
        )

        XCTAssertTrue(
            datasourceSource.contains("prefetchTimelineBoundaryIfNeeded(indexPaths: indexPaths)"),
            "Near-edge history prefetch must enter the unified timeline boundary gateway"
        )
        XCTAssertFalse(contentPrefetchSource.contains("ChatCollectionPrefetchPageWarmup"))
        XCTAssertFalse(contentPrefetchSource.contains("ChatCollectionPageWarmup"))
        XCTAssertFalse(contentPrefetchSource.contains(".pageWarmup"))
    }

    func testControllerContainsNoLegacyArchivePagingRuntime() throws {
        let sources = try productionSwiftSources(
            under: "controllers/chats/chat"
        )
        let forbiddenTokens = [
            "ChatInteractiveHistoryPagingPlan",
            "ChatBoundaryPagingExecutionAction",
            "ChatPreparedLocalHistoryPage",
            "ChatBoundaryPagingVisibilityRequirement",
            "ChatLocalHistoryPagingIntent",
            "ChatInteractiveHistoryPagingPreparation",
            "ChatPendingBoundaryPagingValidationPolicy",
            "ChatInteractiveRemoteArchive",
            "ChatRemoteHistory",
            "handleBoundaryPagingCandidate",
            "applyPendingBoundaryPagingAfterScrollRest",
            "startLocalHistoryPagingPreparation",
            "completeLocalHistoryPagingPreparation",
            "performInteractiveHistoryPaging(",
            "pendingLocalHistoryPaging",
            "pendingPreparedLocalHistoryPage",
            "pendingDeferredRemoteHistory",
            "interactiveRemoteArchiveRequestDispatcher",
            "remoteHistoryQueryCoordinator",
            "remoteHistoryEndPageDispatcherTokens",
            "remoteHistoryFailureDispatcherTokens",
            "remoteHistoryFinishingQueryId",
            "ChatTimelineRemoteLoad",
            "ChatHistoryPagingLoadDecision",
            "ChatShortLocalOlderRemainderPolicy",
            "ChatBoundedTimelineWindowState",
            "activeRemoteLoad",
            "activePlaceholder",
            "loadDecision",
            "localOlderCandidateCount",
            "shortLocalRemainderRemoteFirst",
            "ChatTimelineLoadingState",
            "func appendLiveMessage(",
            "knownGap(RegularChatArchiveGap",
            "loadingPlaceholder(",
            "applyRuntimePlaceholder(",
            "ChatCollectionPrefetchPageWarmup",
            "ChatCollectionPageWarmup",
            ".pageWarmup"
        ]

        let violations = forbiddenTokens.flatMap { token in
            sources.compactMap { source in
                source.contents.contains(token)
                    ? "\(source.relativePath): \(token)"
                    : nil
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "Legacy archive paging runtime must be deleted, not guarded:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testDatasetHasNoLateLoadDatasourceBridgeIntoArchiveEngine() throws {
        let source = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+Dataset.swift"
        )

        XCTAssertFalse(source.contains("preparation: ChatInteractiveHistoryPagingPreparation"))
        XCTAssertFalse(source.contains("submitArchiveEnginePage(direction: preparation.direction)"))
    }

    func testControllerContainsNoLegacyBootstrapOrDirectMAMAnchorRuntime() throws {
        let sources = try productionSwiftSources(
            under: "controllers/chats/chat"
        )
        let forbiddenTokens = [
            "ChatInitialBootstrapRequestCoordinator",
            "ChatInitialBootstrapRequestKey",
            "ChatLegacyArchivePresentationProof",
            "requestInitialBootstrapArchive(",
            "resumeInitialBootstrapArchiveRequest",
            "consumeInitialBootstrapCommittedPage",
            "initialBootstrapQueryId",
            "initialBootstrapLeaseKey",
            "ChatAnchorRemoteFetchPlan",
            "ChatDetachedRemoteHistoryPersistenceTransaction",
            "startRemoteAnchorFetch(",
            "contextPrefetchQueryIds",
            "extension ChatViewController: TemporaryMessageReceiverProtocol"
        ]

        let violations = forbiddenTokens.flatMap { token in
            sources.compactMap { source in
                source.contents.contains(token)
                    ? "\(source.relativePath): \(token)"
                    : nil
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "Legacy bootstrap/anchor MAM runtime must be absent:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testArchiveEngineOwnershipIsNotRuntimeSwitchable() throws {
        let sources = try productionSwiftSources(
            under: "controllers/chats/chat"
        )
        let violations = sources.compactMap { source in
            source.contents.contains("archiveEnginePresentationActive")
                ? source.relativePath
                : nil
        }

        XCTAssertEqual(
            violations,
            [],
            "The archive engine is the sole timeline owner and must not have a legacy fallback switch"
        )
    }

    func testProductionContainsNoDeletedArchiveOrchestrationTypes() throws {
        let sources = try productionSwiftSources(under: "")
        let forbiddenTokens = [
            "ChatInitialBootstrapRequestCoordinator",
            "ChatInitialBootstrapRequestKey",
            "ChatInitialBootstrapFollowUpTargetPolicy",
            "ChatInitialBootstrapCompletionPolicy",
            "ChatInitialBootstrapFailureRecoveryPolicy",
            "ChatInteractiveRemoteArchive",
            "ChatRemoteHistoryQueryCoordinator",
            "ChatRemoteHistoryCompletionCoordinator",
            "ChatScrollBoundaryAvailabilityCache",
            "ChatArchiveEndVerificationPolicy",
            "ConversationArchiveDurableReadinessPolicy",
            "RegularIdleBackfill",
            "RegularArchiveSnapshotRepair",
            "archiveEnginePresentationActive",
            "applyBootstrapLoadingState",
            "applyBootstrapViewState",
            "prepareInitialLocalFirstFrame",
            "reloadInitialWindowAfterBootstrapIfNeeded",
            "currentInitialFrameReadinessProof",
            "finalizeAndCommitPreparedInitialFrame",
            "ChatTimelineInitialFrame",
            "ChatInitialFrameEffectToken",
            "TemporaryMessageReceiverProtocol"
        ]

        let violations = forbiddenTokens.flatMap { token in
            sources.compactMap { source in
                source.contents.contains(token)
                    ? "\(source.relativePath): \(token)"
                    : nil
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "Deleted archive orchestration must not survive outside the chat controller:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testAccountConnectContainsNoDeadInitialMAMShell() throws {
        let accountSource = try productionSource("models/account/Account.swift")
        let connectSource = try productionSource(
            "models/account/extensions/AccountConnectBehaviorExtension.swift"
        )
        let forbiddenTokens = [
            "requestInitialMAM(",
            "isInitialMAMRequestSend",
            "isRequestedAway",
            "pushLastMAMId",
        ]

        let violations = forbiddenTokens.flatMap { token in
            [
                "models/account/Account.swift": accountSource,
                "models/account/extensions/AccountConnectBehaviorExtension.swift": connectSource,
            ].compactMap { path, source in
                source.contains(token) ? "\(path): \(token)" : nil
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "The post-auth no-op initial-MAM route must be physically deleted:\n\(violations.joined(separator: "\n"))"
        )
    }

    private struct SourceFile {
        let relativePath: String
        let contents: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("xabber", isDirectory: true)
                .appendingPathComponent(relativePath),
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

    private func XCTAssertOrdered(
        _ first: String,
        before second: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            return XCTFail(
                "Missing ordered tokens: \(first), \(second)",
                file: file,
                line: line
            )
        }
        XCTAssertLessThan(
            firstRange.lowerBound,
            secondRange.lowerBound,
            file: file,
            line: line
        )
    }

    private func productionSwiftSources(under relativePath: String) throws -> [SourceFile] {
        let root = repositoryRoot
            .appendingPathComponent("xabber", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Unable to enumerate production source at \(root.path)")
            return []
        }

        var sources: [SourceFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else {
                continue
            }
            let contents = try String(contentsOf: url, encoding: .utf8)
            sources.append(SourceFile(
                relativePath: url.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                ),
                contents: contents
            ))
        }
        return sources.sorted { $0.relativePath < $1.relativePath }
    }
}
