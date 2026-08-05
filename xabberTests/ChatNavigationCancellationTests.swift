//
//  ChatNavigationCancellationTests.swift
//  xabberTests
//
//  Created by Codex on 01.08.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

/// Exact V12 acceptance at UIKit's real interactive transition boundary.
///
/// Unlike the smaller navigation-state tests, these cases do not invoke the
/// chat's transition-completion helpers directly. A percent-driven interactive
/// UINavigationController pop supplies the real transition coordinator and
/// UIKit lifecycle callbacks used in production.
@MainActor
final class ChatNavigationCancellationTests: ChatLocalTargetProductionTestCase {
    private var retainedWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var previousInterfaceType: String?

    override func setUp() {
        super.setUp()
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.tabs.rawValue
    }

    override func tearDown() {
        retainedWindow?.isHidden = true
        retainedWindow?.rootViewController = nil
        retainedWindow = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        if let previousInterfaceType {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }
        previousInterfaceType = nil
        super.tearDown()
    }

    func testScheduledDisappearanceReappearanceRemainsRollbackAfterInteractionEnds() {
        XCTAssertTrue(
            ChatNavigationTransitionMutationPolicy.isCancelledReappearance(
                didRunDisappearanceCleanup: false,
                didScheduleDisappearanceCleanup: true,
                didCancelDisappearanceTransition: false,
                hasRegisteredChatObservers: true
            ),
            "scheduled cleanup is the ownership receipt while UIKit is between interaction end and transition completion"
        )
        XCTAssertFalse(
            ChatNavigationTransitionMutationPolicy.isCancelledReappearance(
                didRunDisappearanceCleanup: true,
                didScheduleDisappearanceCleanup: false,
                didCancelDisappearanceTransition: false,
                hasRegisteredChatObservers: false
            ),
            "a controller returning after terminal cleanup must perform its ordinary appearance lifecycle"
        )
    }

    func testCancelledEdgePopPreservesDatasourceGenerationAndSemanticOffset() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let stack = try makeCommittedNavigationStack(suffix: "v12-cancel")
        let chat = stack.chat
        let collectionView = stack.collectionView
        defer {
            clearEvidenceHooks(chat)
            chat.performTerminalChatResourceTeardownForTesting()
        }

        let anchorPrimary = try positionMiddleRow(in: chat)
        XCTAssertTrue(waitForCausalMainQueueDrain())
        stack.navigationController.view.layoutIfNeeded()
        chat.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        XCTAssertTrue(waitUntil {
            chat.chatLifecycleResourceSnapshot.scheduledScrollRequests == 0
        })
        let mappingToken = chat.beginDatasetMappingJobForTesting()
        let recordingSessionID = UUID()
        chat.activeAudioRecordingSessionID = recordingSessionID
        let timer = Timer(timeInterval: 60, repeats: true) { _ in }
        chat.omemoDeviceListTimer = timer
        chat.scrollFrameOperationCounter.setEnabled(true)
        chat.scrollFrameOperationCounter.reset()
        collectionView.resetRecordedEvents()
        let committed = try captureCommittedState(
            chat,
            semanticAnchorPrimary: anchorPrimary
        )

        let transition = InteractivePopTransitionDriver()
        stack.navigationController.delegate = transition
        transition.arm()
        let popped = stack.navigationController.popViewController(animated: true)

        XCTAssertTrue(popped === chat)
        let coordinator = try XCTUnwrap(
            stack.navigationController.transitionCoordinator ?? chat.transitionCoordinator,
            "the cancellation must run through an actual UIKit transition coordinator"
        )
        XCTAssertTrue(coordinator.isInteractive)
        XCTAssertTrue(
            waitUntil {
                chat.didScheduleNavigationDisappearanceCleanup &&
                    chat.isNavigationTransitionActive
            },
            "UIKit must deliver the real viewWillDisappear boundary before cancellation"
        )
        var interactionChangeWasCancelled: Bool?
        coordinator.notifyWhenInteractionChanges { context in
            interactionChangeWasCancelled = context.isCancelled
        }

        transition.update(0.35)
        transition.cancel()

        XCTAssertTrue(waitUntil(timeout: 2) {
            transition.completedOutcomes == [false] &&
                interactionChangeWasCancelled == true &&
                stack.navigationController.topViewController === chat &&
                chat.viewIfLoaded?.window != nil &&
                !chat.didScheduleNavigationDisappearanceCleanup &&
                !chat.isNavigationTransitionActive &&
                stack.navigationController.transitionCoordinator == nil &&
                chat.transitionCoordinator == nil
        })
        stack.navigationController.view.layoutIfNeeded()
        chat.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        XCTAssertTrue(waitForCausalMainQueueDrain())
        stack.navigationController.view.layoutIfNeeded()
        chat.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        XCTAssertTrue(waitUntil(timeout: 2) {
            let resources = chat.chatLifecycleResourceSnapshot
            return resources.scheduledScrollRequests ==
                    committed.lifecycleResources.scheduledScrollRequests &&
                resources.animations == committed.lifecycleResources.animations
        })

        XCTAssertTrue(stack.navigationController.topViewController === chat)
        XCTAssertTrue(stack.navigationController.visibleViewController === chat)
        XCTAssertTrue(stack.navigationController.navigationBar.topItem === chat.navigationItem)
        XCTAssertFalse(chat.didRunNavigationDisappearanceCleanup)
        XCTAssertFalse(chat.didScheduleNavigationDisappearanceCleanup)
        XCTAssertFalse(mappingToken.isCancelled)
        XCTAssertTrue(chat.activeAudioRecordingSessionID == recordingSessionID)
        XCTAssertTrue(chat.omemoDeviceListTimer === timer)
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(
            try captureCommittedState(chat, semanticAnchorPrimary: anchorPrimary),
            committed,
            "a cancelled edge pop must be transactionally neutral for the committed chat frame"
        )
        XCTAssertTrue(
            collectionView.recordedEvents.filter { $0 == .reload || $0 == .offset }.isEmpty,
            "UIKit cancellation must not reload the datasource or rewrite the scroll offset"
        )
        let operations = chat.scrollFrameOperationCounter.snapshot()
        XCTAssertEqual(operations[.datasourceApplies], 0)
        XCTAssertEqual(operations[.reloads], 0)
        XCTAssertEqual(operations[.offsetMutations], 0)
        XCTAssertEqual(operations[.layoutFlushes], 0)

        // A cancellation must leave the navigation controller usable. Prove
        // that the immediately following ordinary UIKit pop completes.
        stack.navigationController.delegate = nil
        XCTAssertTrue(stack.navigationController.popViewController(animated: true) === chat)
        XCTAssertTrue(waitUntil(timeout: 2) {
            stack.navigationController.topViewController === stack.lastChats
        })
#else
        throw XCTSkip("Production first-frame diagnostics are available in DEBUG/lab builds")
#endif
    }

    func testSuccessfulInteractivePopStillRunsTerminalTeardownExactlyOnce() throws {
#if DEBUG || CHAT_PERFORMANCE_LAB
        let stack = try makeCommittedNavigationStack(suffix: "v12-finish")
        let chat = stack.chat
        defer {
            clearEvidenceHooks(chat)
            chat.performTerminalChatResourceTeardownForTesting()
        }

        let mappingToken = chat.beginDatasetMappingJobForTesting()
        let recordingSessionID = UUID()
        chat.activeAudioRecordingSessionID = recordingSessionID
        let timer = Timer(timeInterval: 60, repeats: true) { _ in }
        chat.omemoDeviceListTimer = timer
        let datasourceGeneration = chat.datasetMappingGeneration
        let skeletonGeneration = chat.bootstrapSkeletonMappingGeneration

        let transition = InteractivePopTransitionDriver()
        stack.navigationController.delegate = transition
        transition.arm()
        let popped = stack.navigationController.popViewController(animated: true)

        XCTAssertTrue(popped === chat)
        let coordinator = try XCTUnwrap(
            stack.navigationController.transitionCoordinator ?? chat.transitionCoordinator
        )
        XCTAssertTrue(coordinator.isInteractive)
        transition.update(0.8)
        transition.finish()

        XCTAssertTrue(waitUntil(timeout: 2) {
            transition.completedOutcomes == [true] &&
                stack.navigationController.topViewController === stack.lastChats
        })
        XCTAssertTrue(chat.didRunNavigationDisappearanceCleanup)
        XCTAssertFalse(chat.didScheduleNavigationDisappearanceCleanup)
        XCTAssertTrue(mappingToken.isCancelled)
        XCTAssertNil(chat.activeAudioRecordingSessionID)
        XCTAssertNil(chat.omemoDeviceListTimer)
        XCTAssertFalse(timer.isValid)
        XCTAssertEqual(chat.datasetMappingGeneration, datasourceGeneration + 1)
        XCTAssertEqual(chat.bootstrapSkeletonMappingGeneration, skeletonGeneration + 1)
        XCTAssertTrue(chat.chatLifecycleResourceSnapshot.isIdle)

        let terminalDatasourceGeneration = chat.datasetMappingGeneration
        let terminalSkeletonGeneration = chat.bootstrapSkeletonMappingGeneration
        chat.runNavigationDisappearanceCleanupIfNeeded()

        XCTAssertEqual(chat.datasetMappingGeneration, terminalDatasourceGeneration)
        XCTAssertEqual(chat.bootstrapSkeletonMappingGeneration, terminalSkeletonGeneration)
        XCTAssertTrue(chat.chatLifecycleResourceSnapshot.isIdle)
#else
        throw XCTSkip("Production first-frame diagnostics are available in DEBUG/lab builds")
#endif
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    private func makeCommittedNavigationStack(
        suffix: String
    ) throws -> CommittedNavigationStack {
        let windowScene = try requireHostedForegroundWindowScene()
        let targetBounds = windowScene.coordinateSpace.bounds
        previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let hosted = try makeHostedController(
            suffix: suffix,
            messageRanges: [0..<80],
            coverageRanges: [0..<80],
            targetBounds: targetBounds
        )
        let evidence = installEvidence(on: hosted.controller)
        hosted.controller.scrollFrameOperationCounter.setEnabled(true)
        hosted.controller.scrollFrameOperationCounter.reset()
        hosted.collectionView.resetRecordedEvents()
        prepareInitialFrame(hosted, evidence: evidence)
        XCTAssertEqual(evidence.publications.count, 1)
        XCTAssertEqual(hosted.controller.initialFirstContentApplyCount, 1)
        XCTAssertFalse(hosted.controller.showSkeletonObserver.value)
        XCTAssertEqual(
            hosted.controller.datasource.filter {
                ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .message
            }.count,
            80
        )
        XCTAssertFalse(
            hosted.controller.datasource.contains {
                ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
            }
        )

        hosted.controller.willMove(toParent: nil)
        hosted.controller.view.removeFromSuperview()
        hosted.controller.removeFromParent()

        let lastChats = LastChatsViewController()
        let navigationController = UINavigationController(rootViewController: lastChats)
        let window = UIWindow(windowScene: windowScene)
        window.frame = targetBounds
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        retainedWindow = window
        navigationController.loadViewIfNeeded()
        navigationController.view.frame = window.bounds
        lastChats.loadViewIfNeeded()
        lastChats.configureBars(updateNavigationItems: true)
        navigationController.view.layoutIfNeeded()

        navigationController.pushViewController(hosted.controller, animated: true)
        XCTAssertTrue(waitUntil(timeout: 2) {
            navigationController.topViewController === hosted.controller &&
                navigationController.transitionCoordinator == nil
        })
        navigationController.view.layoutIfNeeded()
        hosted.controller.view.layoutIfNeeded()
        hosted.collectionView.layoutIfNeeded()
        XCTAssertTrue(waitForCausalMainQueueDrain())
        XCTAssertTrue(navigationController.topViewController === hosted.controller)
        XCTAssertTrue(hosted.controller.view.window === window)

        return CommittedNavigationStack(
            lastChats: lastChats,
            chat: hosted.controller,
            collectionView: hosted.collectionView,
            navigationController: navigationController
        )
    }

    private func positionMiddleRow(in chat: ChatViewController) throws -> String {
        let section = chat.datasource.count / 2
        let primary = chat.datasource[section].primary
        chat.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: section),
            at: .centeredVertically,
            animated: false
        )
        chat.messagesCollectionView.layoutIfNeeded()
        return primary
    }

    private func captureCommittedState(
        _ chat: ChatViewController,
        semanticAnchorPrimary: String
    ) throws -> CommittedChatState {
        let section = try XCTUnwrap(chat.datasourceSnapshot.primaryIndex[semanticAnchorPrimary])
        let attributes = try XCTUnwrap(
            chat.messagesCollectionView.layoutAttributesForItem(
                at: IndexPath(item: 0, section: section)
            )
        )
        let sessionSnapshot = try XCTUnwrap(chat.timelineSession?.snapshot)
        return CommittedChatState(
            rows: chat.datasource.map(RowIdentity.init),
            snapshotRows: chat.datasourceSnapshot.items.map(RowIdentity.init),
            snapshotPrimaryIndex: chat.datasourceSnapshot.primaryIndex,
            snapshotArchivedIDIndex: chat.datasourceSnapshot.archivedIdIndex,
            snapshotHasDuplicateKeys: chat.datasourceSnapshot.hasDuplicateKeys,
            residentWindow: chat.residentDatasetWindow,
            virtualTimelineState: chat.virtualTimelineState,
            timelineGeneration: sessionSnapshot.generation,
            timelineCause: sessionSnapshot.cause,
            timelineRows: sessionSnapshot.items.map {
                TimelineRowIdentity(
                    primary: $0.primary,
                    messageID: $0.messageId,
                    archivedID: $0.archivedId
                )
            },
            timelineState: sessionSnapshot.state,
            timelineLoadingState: sessionSnapshot.loadingState,
            datasourceGeneration: chat.datasetMappingGeneration,
            skeletonGeneration: chat.bootstrapSkeletonMappingGeneration,
            layoutGeneration: chat.layoutPreparationGeneration,
            contentSize: chat.messagesCollectionView.contentSize,
            contentOffset: chat.messagesCollectionView.contentOffset,
            contentInset: chat.messagesCollectionView.contentInset,
            semanticAnchorViewportY:
                attributes.frame.minY - chat.messagesCollectionView.contentOffset.y,
            initialFramePhase: chat.initialLocalFirstFramePhase,
            bootstrapLoadingState: chat.appliedBootstrapLoadingState,
            firstContentApplyCount: chat.initialFirstContentApplyCount,
            isSkeletonVisible: chat.showSkeletonObserver.value,
            isDatasourceLoadingEnabled: chat.loadDatasourceObserver.value,
            pendingOpenRequest: chat.pendingOpenMessageRequest,
            pendingForceLatestOpen: chat.pendingForceLatestOpen,
            lifecycleResources: chat.chatLifecycleResourceSnapshot,
            timerIdentity: chat.omemoDeviceListTimer.map(ObjectIdentifier.init),
            timerIsValid: chat.omemoDeviceListTimer?.isValid,
            activeAudioRecordingSessionID: chat.activeAudioRecordingSessionID
        )
    }
#endif
}

#if DEBUG || CHAT_PERFORMANCE_LAB
private struct CommittedNavigationStack {
    let lastChats: LastChatsViewController
    let chat: ChatViewController
    let collectionView: ChatLayoutLifecycleRecordingCollectionView
    let navigationController: UINavigationController
}

private struct RowIdentity: Equatable {
    let primary: String
    let messageID: String
    let archivedID: String?
    let isFake: Bool

    init(_ row: ChatViewController.Datasource) {
        primary = row.primary
        messageID = row.messageId
        archivedID = row.archivedId
        isFake = row.isFakeMessage
    }
}

private struct TimelineRowIdentity: Equatable {
    let primary: String
    let messageID: String
    let archivedID: String?
}

private struct CommittedChatState: Equatable {
    let rows: [RowIdentity]
    let snapshotRows: [RowIdentity]
    let snapshotPrimaryIndex: [String: Int]
    let snapshotArchivedIDIndex: [String: Int]
    let snapshotHasDuplicateKeys: Bool
    let residentWindow: ChatDatasetWindow
    let virtualTimelineState: ChatVirtualTimelineState
    let timelineGeneration: UInt64
    let timelineCause: ChatTimelineSessionSnapshotCause
    let timelineRows: [TimelineRowIdentity]
    let timelineState: ChatVirtualTimelineState
    let timelineLoadingState: ChatTimelineLoadingState
    let datasourceGeneration: Int
    let skeletonGeneration: Int
    let layoutGeneration: Int
    let contentSize: CGSize
    let contentOffset: CGPoint
    let contentInset: UIEdgeInsets
    let semanticAnchorViewportY: CGFloat
    let initialFramePhase: ChatLocalFirstFramePhase
    let bootstrapLoadingState: ChatBootstrapLoadingState?
    let firstContentApplyCount: Int
    let isSkeletonVisible: Bool
    let isDatasourceLoadingEnabled: Bool
    let pendingOpenRequest: ChatOpenMessageRequest?
    let pendingForceLatestOpen: Bool
    let lifecycleResources: ChatLifecycleResourceSnapshot
    let timerIdentity: ObjectIdentifier?
    let timerIsValid: Bool?
    let activeAudioRecordingSessionID: UUID?
}
#endif

#if DEBUG || CHAT_PERFORMANCE_LAB
@MainActor
private final class InteractivePopTransitionDriver:
    NSObject,
    UINavigationControllerDelegate,
    UIViewControllerAnimatedTransitioning
{
    private var interactionController: UIPercentDrivenInteractiveTransition?
    private(set) var completedOutcomes: [Bool] = []

    func arm() {
        let interactionController = UIPercentDrivenInteractiveTransition()
        interactionController.completionCurve = .linear
        interactionController.completionSpeed = 2
        interactionController.wantsInteractiveStart = true
        self.interactionController = interactionController
    }

    func update(_ progress: CGFloat) {
        interactionController?.update(progress)
    }

    func cancel() {
        interactionController?.cancel()
    }

    func finish() {
        interactionController?.finish()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard operation == .pop, interactionController != nil else {
            return nil
        }
        return self
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        guard animationController === self else {
            return nil
        }
        return interactionController
    }

    func transitionDuration(
        using transitionContext: UIViewControllerContextTransitioning?
    ) -> TimeInterval {
        0.2
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            completedOutcomes.append(false)
            interactionController = nil
            return
        }

        let container = transitionContext.containerView
        let fromFrame = transitionContext.initialFrame(
            for: transitionContext.viewController(forKey: .from)!
        )
        let toFrame = transitionContext.finalFrame(
            for: transitionContext.viewController(forKey: .to)!
        )
        toView.frame = toFrame.offsetBy(dx: -0.3 * container.bounds.width, dy: 0)
        container.insertSubview(toView, belowSubview: fromView)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: [.curveLinear, .allowUserInteraction],
            animations: {
                fromView.frame = fromFrame.offsetBy(dx: container.bounds.width, dy: 0)
                toView.frame = toFrame
            },
            completion: { [weak self] _ in
                let completed = !transitionContext.transitionWasCancelled
                transitionContext.completeTransition(completed)
                fromView.frame = fromFrame
                toView.frame = toFrame
                self?.completedOutcomes.append(completed)
                self?.interactionController = nil
            }
        )
    }
}
#endif
