//
//  LastChatsNavigationSingleFlightTests.swift
//  xabberTests
//

import UIKit
import XCTest
import RealmSwift
@testable import xabber

final class LastChatsNavigationSingleFlightTests: XCTestCase {
    private let romeo = LastChatsNavigationSingleFlightCoordinator.Target(
        owner: "juliet@example.com",
        jid: "romeo@example.com",
        conversationType: .regular
    )
    private let mercutio = LastChatsNavigationSingleFlightCoordinator.Target(
        owner: "juliet@example.com",
        jid: "mercutio@example.com",
        conversationType: .regular
    )
    private let tybalt = LastChatsNavigationSingleFlightCoordinator.Target(
        owner: "juliet@example.com",
        jid: "tybalt@example.com",
        conversationType: .regular
    )

    func testLastChatsDatasourceApplyPolicyUsesDetachedSnapshotBeforeWindowAttachment() {
        XCTAssertEqual(
            LastChatsDatasourceApplyPolicy.resolve(
                isTableAttachedToWindow: false
            ),
            .detachedSnapshot
        )
        XCTAssertEqual(
            LastChatsDatasourceApplyPolicy.resolve(
                isTableAttachedToWindow: true
            ),
            .incrementalDiff
        )
    }

    func testDefaultPreparationGuardRunsAfterFirstFrameFallbackDeadline() {
        XCTAssertGreaterThan(
            LastChatsNavigationSingleFlightCoordinator.defaultPreparationTimeout,
            StackedNavigationPresentationTimingPolicy
                .asynchronousPreparationFallbackDelay,
            "the outer navigation guard must not cancel the 450-ms destination fallback before it commits skeleton"
        )
        XCTAssertLessThanOrEqual(
            LastChatsNavigationSingleFlightCoordinator.defaultPreparationTimeout,
            1,
            "the outer guard remains a short emergency bound"
        )
    }

    func testIdleRequestStartsPreparationForTargetAndToken() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let token = UUID()

        let decision = coordinator.request(target: romeo, token: token)

        XCTAssertEqual(decision, .started(token))
        XCTAssertEqual(
            coordinator.state,
            .init(token: token, target: romeo, phase: .preparing)
        )
    }

    func testRepeatedRequestForPreparingTargetCoalescesOntoOriginalToken() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let originalToken = UUID()
        let repeatedToken = UUID()
        _ = coordinator.request(target: romeo, token: originalToken)

        let decision = coordinator.request(target: romeo, token: repeatedToken)

        XCTAssertEqual(decision, .coalesced(originalToken))
        XCTAssertEqual(coordinator.state?.token, originalToken)
        XCTAssertEqual(coordinator.state?.phase, .preparing)
    }

    func testTenRapidRequestsForSameTargetPerformOneNavigationPush() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let rootViewController = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: rootViewController
        )

        for _ in 0..<10 {
            guard case .started(let token) = coordinator.request(target: romeo) else {
                continue
            }
            let destination = UIViewController()
            let didPresent = performGuardedStackedNavigationPresentation(
                commitPresentation: {
                    coordinator.markPushing(token: token, target: self.romeo)
                },
                presentation: {
                    navigationController.pushViewController(destination, animated: false)
                }
            )
            XCTAssertTrue(didPresent)
            XCTAssertTrue(coordinator.markPresented(token: token, target: romeo))
        }

        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.viewControllers.first === rootViewController)
        XCTAssertEqual(coordinator.state?.target, romeo)
        XCTAssertEqual(coordinator.state?.phase, .presented)
    }

    @MainActor
    func testCoalescedRequestsAfterBackStillPushWhenFirstFramePreparationStalls() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let previousToken = UUID()
        _ = coordinator.request(target: romeo, token: previousToken)
        XCTAssertTrue(coordinator.markPushing(token: previousToken, target: romeo))
        XCTAssertTrue(coordinator.markPresented(token: previousToken, target: romeo))
        coordinator.reset()

        var activeToken: UUID?
        var coalescedCount = 0
        for _ in 0..<10 {
            switch coordinator.request(target: romeo) {
            case .started(let token):
                activeToken = token
            case .coalesced:
                coalescedCount += 1
            case .ignored:
                XCTFail("Requests must remain coalescible before the push starts")
            }
        }

        let token = try! XCTUnwrap(activeToken)
        let rootViewController = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: rootViewController
        )
        navigationController.loadViewIfNeeded()
        let destination = StalledStackedNavigationPreparationViewController()
        let presentation = expectation(description: "stalled preparation falls back to one push")
        var presentationCount = 0

        let handle = showStacked(
            destination,
            in: rootViewController,
            commitPresentation: {
                coordinator.markPushing(token: token, target: self.romeo)
            },
            completion: { didPresent in
                guard didPresent else {
                    XCTFail("The current coalesced target must not be abandoned")
                    return
                }
                presentationCount += 1
                XCTAssertTrue(coordinator.markPresented(token: token, target: self.romeo))
                presentation.fulfill()
            }
        )

        wait(for: [presentation], timeout: 2)

        XCTAssertEqual(coalescedCount, 9)
        XCTAssertEqual(destination.preparationCount, 1)
        XCTAssertEqual(destination.preparationTimeoutCount, 1)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.topViewController === destination)
        XCTAssertEqual(coordinator.state?.phase, .presented)
        handle.cancel()
    }

    func testDifferentTargetSupersedesOnlyPendingPreparation() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let staleToken = UUID()
        let currentToken = UUID()
        _ = coordinator.request(target: romeo, token: staleToken)

        let decision = coordinator.request(target: mercutio, token: currentToken)

        XCTAssertEqual(decision, .started(currentToken))
        XCTAssertEqual(
            coordinator.state,
            .init(token: currentToken, target: mercutio, phase: .preparing)
        )
        XCTAssertFalse(coordinator.markPushing(token: staleToken, target: romeo))
        XCTAssertFalse(coordinator.cancel(token: staleToken))
        XCTAssertEqual(coordinator.state?.token, currentToken)
    }

    func testStaleFirstCompletionAfterDifferentTargetSupersessionIsInert() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let staleToken = UUID()
        let currentToken = UUID()
        _ = coordinator.request(target: romeo, token: staleToken)
        _ = coordinator.request(target: mercutio, token: currentToken)

        let staleCompletionMayPush = coordinator.markPushing(
            token: staleToken,
            target: romeo
        )

        XCTAssertFalse(staleCompletionMayPush)
        XCTAssertEqual(
            coordinator.state,
            .init(token: currentToken, target: mercutio, phase: .preparing)
        )
    }

    func testRequestsAreIgnoredAfterPushStarts() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let activeToken = UUID()
        _ = coordinator.request(target: romeo, token: activeToken)
        XCTAssertTrue(coordinator.markPushing(token: activeToken, target: romeo))

        let sameTargetDecision = coordinator.request(target: romeo, token: UUID())
        let differentTargetDecision = coordinator.request(target: mercutio, token: UUID())

        XCTAssertEqual(sameTargetDecision, .ignored(activeToken))
        XCTAssertEqual(differentTargetDecision, .ignored(activeToken))
        XCTAssertEqual(coordinator.state?.phase, .pushing)
    }

    func testRequestsRemainIgnoredWhileDestinationIsPresented() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let activeToken = UUID()
        _ = coordinator.request(target: romeo, token: activeToken)
        XCTAssertTrue(coordinator.markPushing(token: activeToken, target: romeo))
        XCTAssertTrue(coordinator.markPresented(token: activeToken, target: romeo))

        let decision = coordinator.request(target: mercutio, token: UUID())

        XCTAssertEqual(decision, .ignored(activeToken))
        XCTAssertEqual(coordinator.state?.phase, .presented)
    }

    func testMatchingCancellationResetsStateAndAllowsRetry() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let cancelledToken = UUID()
        let retryToken = UUID()
        _ = coordinator.request(target: romeo, token: cancelledToken)

        XCTAssertTrue(coordinator.cancel(token: cancelledToken))
        let retryDecision = coordinator.request(target: romeo, token: retryToken)

        XCTAssertEqual(retryDecision, .started(retryToken))
        XCTAssertEqual(coordinator.state?.token, retryToken)
    }

    func testGuardRejectionCancelsTransactionAndEndsOutgoingDeferral() {
        let controller = LastChatsViewController()
        let token = UUID()
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 60
        )

        let didCancel = controller.cancelChatNavigationPreparation(
            token: token,
            reason: .presentationGuardRejected
        )

        XCTAssertTrue(didCancel)
        XCTAssertNil(controller.chatNavigationSingleFlight.state)
        XCTAssertFalse(controller.isNavigationTransitionActive)
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertFalse(controller.hasPendingChatNavigationPreparationTimeout)
        XCTAssertEqual(
            controller.chatNavigationSingleFlight.request(target: romeo).phase,
            .started
        )
    }

    func testMatchingPreparationTimeoutCancelsTransactionAndEndsOutgoingDeferral() {
        let controller = LastChatsViewController()
        let token = UUID()
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 60
        )

        let didTimeout = controller.handleChatNavigationPreparationTimeout(token: token)

        XCTAssertTrue(didTimeout)
        XCTAssertNil(controller.chatNavigationSingleFlight.state)
        XCTAssertFalse(controller.isNavigationTransitionActive)
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertFalse(controller.hasPendingChatNavigationPreparationTimeout)
    }

    func testPreparationTimeoutCancelsDestinationHandleAndSuppressesStaleCompletion() {
        let controller = LastChatsViewController()
        let token = UUID()
        var cancellationCount = 0
        var completionCount = 0
        let handle = StackedNavigationPresentationPreparationHandle(
            cancellation: { cancellationCount += 1 },
            completion: { completionCount += 1 }
        )
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 60
        )
        XCTAssertTrue(
            controller.registerOutgoingChatOpenNavigationPreparation(
                handle,
                token: token
            )
        )

        XCTAssertTrue(controller.handleChatNavigationPreparationTimeout(token: token))
        handle.finish()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(completionCount, 0)
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationPreparation)
    }

    func testCancellationRetainsDestinationUntilItsCancellationCallbackRuns() throws {
        var cancellationCount = 0
        weak var weakDestination: NavigationPreparationDestinationProbe?

        try autoreleasepool {
            var destination: NavigationPreparationDestinationProbe? =
                NavigationPreparationDestinationProbe {
                    cancellationCount += 1
                }
            weakDestination = destination
            let handle = makeNavigationPreparationHandle(
                retaining: try XCTUnwrap(destination)
            )

            destination = nil
            handle.cancel()
        }

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNil(weakDestination)
    }

    func testFirstAppearancePreservesProgrammaticOpenPreparation() {
        let controller = LastChatsViewController()
        let token = UUID()
        var cancellationCount = 0
        let handle = StackedNavigationPresentationPreparationHandle(
            cancellation: { cancellationCount += 1 },
            completion: {}
        )
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 60
        )
        XCTAssertTrue(
            controller.registerOutgoingChatOpenNavigationPreparation(
                handle,
                token: token
            )
        )

        controller.reconcileChatNavigationTransactionOnDidAppear()

        XCTAssertEqual(
            controller.chatNavigationSingleFlight.state,
            .init(token: token, target: romeo, phase: .preparing)
        )
        XCTAssertTrue(controller.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertTrue(controller.hasActiveOutgoingChatOpenNavigationPreparation)
        XCTAssertTrue(controller.hasPendingChatNavigationPreparationTimeout)
        XCTAssertEqual(cancellationCount, 0)

        controller.resetChatNavigationTransaction(cancelled: true)
    }

    func testReturnAppearanceCancelsOldPreparationAndLateCompletionCannotAffectFreshRequest() {
        let controller = LastChatsViewController()
        let staleToken = UUID()
        let currentToken = UUID()
        var staleCancellationCount = 0
        var staleCompletionCount = 0
        let staleHandle = StackedNavigationPresentationPreparationHandle(
            cancellation: { staleCancellationCount += 1 },
            completion: { staleCompletionCount += 1 }
        )
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: staleToken)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: staleToken,
            preparationTimeout: 60
        )
        XCTAssertTrue(
            controller.registerOutgoingChatOpenNavigationPreparation(
                staleHandle,
                token: staleToken
            )
        )

        controller.markChatNavigationPresenterWillDisappear()
        controller.reconcileChatNavigationTransactionOnDidAppear()
        XCTAssertNil(controller.chatNavigationSingleFlight.state)

        _ = controller.chatNavigationSingleFlight.request(target: mercutio, token: currentToken)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: currentToken,
            preparationTimeout: 60
        )
        staleHandle.finish()

        XCTAssertEqual(staleCancellationCount, 1)
        XCTAssertEqual(staleCompletionCount, 0)
        XCTAssertEqual(
            controller.chatNavigationSingleFlight.state,
            .init(token: currentToken, target: mercutio, phase: .preparing)
        )
        XCTAssertTrue(controller.hasActiveOutgoingChatOpenNavigationDeferral)

        controller.resetChatNavigationTransaction(cancelled: true)
    }

    @MainActor
    func testForegroundNavigationHostDoesNotConstructRootWhenSceneAdmissionFails() {
        let expectedError = NSError(
            domain: "LastChatsNavigationSingleFlightTests.SceneAdmission",
            code: 1
        )
        var rootFactoryInvocationCount = 0

        XCTAssertThrowsError(
            try makeForegroundNavigationHost(
                windowSceneProvider: { throw expectedError },
                rootFactory: {
                    rootFactoryInvocationCount += 1
                    return UIViewController()
                }
            )
        ) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, expectedError.domain)
            XCTAssertEqual(error.code, expectedError.code)
        }
        XCTAssertEqual(rootFactoryInvocationCount, 0)
    }

    @MainActor
    func testBackDuringPushReleasesSingleFlightOnlyAfterTransitionCancellationCompletes() throws {
        try withInterfaceType(.tabs) {
            let (host, controller) = try makeForegroundNavigationHost(rootFactory: {
                NavigationAppearanceProbeLastChatsViewController()
            })
            let destination = ControlledExpandedSplitChatViewController()
            let effects = LastChatsChatOpenIntentSideEffectProbe()
            let transition = InteractivePushCancellationDriver()
            var destinationFactoryCount = 0
            var retryCount = 0
            var transitionCompletionDelivered = false
            var appearanceSnapshot: NavigationReturnAppearanceSnapshot?

            defer {
                host.navigationController.delegate = nil
                controller.didAppearAfterSuper = nil
                controller.resetChatNavigationTransaction(cancelled: true)
                releaseForegroundNavigationHost(host)
            }

            controller.unsubscribe()
            controller.compactChatDestinationFactory = {
                destinationFactoryCount += 1
                return destination
            }
            controller.chatOpenIntentDeliveryHandler = effects.deliver
            controller.pendingMessageNotificationAsyncScheduler = { $0() }
            controller.pendingMessageNotificationRouteRetryHandler = {
                retryCount += 1
                return false
            }
            controller.didAppearAfterSuper = {
                appearanceSnapshot = NavigationReturnAppearanceSnapshot(
                    transitionCompletionDelivered: transitionCompletionDelivered,
                    state: controller.chatNavigationSingleFlight.state,
                    retainedDestination: controller
                        .retainedCompactChatNavigationDestination?.controller,
                    retryCount: retryCount
                )
            }
            host.navigationController.delegate = transition
            transition.arm()
            let request = makeExactNotificationRequest(
                target: romeo,
                archivedId: "back-during-push",
                source: .search
            )

            XCTAssertTrue(controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: request,
                navigationSource: .standard
            ))
            XCTAssertEqual(destinationFactoryCount, 1)
            XCTAssertEqual(destination.preparationCount, 1)
            XCTAssertEqual(effects.deliveryCount(for: request), 1)
            let originalToken = try XCTUnwrap(
                controller.chatNavigationSingleFlight.state?.token
            )

            destination.releaseNextPreparation()

            let coordinator = try XCTUnwrap(
                host.navigationController.transitionCoordinator,
                "the production push must expose a real UIKit transition coordinator"
            )
            XCTAssertTrue(coordinator.isInteractive)
            XCTAssertTrue(coordinator.animate(
                alongsideTransition: nil,
                completion: { _ in
                    transitionCompletionDelivered = true
                }
            ))
            XCTAssertEqual(
                controller.chatNavigationSingleFlight.state,
                .init(token: originalToken, target: romeo, phase: .pushing)
            )
            XCTAssertTrue(
                controller.retainedCompactChatNavigationDestination?.controller
                    === destination
            )
            let datasourceIdentityBeforeCancellation =
                controller.datasource.map(\.diffId)
            let datasourceSectionsBeforeCancellation =
                controller.datasourceSections.map {
                    NavigationReturnDatasourceSectionIdentity(
                        kind: $0.kind,
                        rows: $0.rows.map(\.diffId)
                    )
                }

            transition.update(0.35)
            transition.cancel()

            XCTAssertTrue(waitUntil(timeout: 2) {
                appearanceSnapshot != nil
            })
            let duringReturn = try XCTUnwrap(appearanceSnapshot)
            XCTAssertFalse(
                duringReturn.transitionCompletionDelivered,
                "viewDidAppear must not impersonate UIKit's terminal transition callback"
            )
            XCTAssertEqual(
                duringReturn.state,
                .init(token: originalToken, target: romeo, phase: .pushing),
                "the exact navigation owner must survive structural rollback and return appearance"
            )
            XCTAssertTrue(duringReturn.retainedDestination === destination)
            XCTAssertEqual(
                duringReturn.retryCount,
                0,
                "the pending route cannot retry while the cancelled push still owns UIKit"
            )

            XCTAssertTrue(waitUntil(timeout: 2) {
                transition.completedOutcomes == [false] &&
                    transitionCompletionDelivered &&
                    host.navigationController.transitionCoordinator == nil &&
                    host.navigationController.topViewController === controller &&
                    controller.chatNavigationSingleFlight.state == nil
            })
            XCTAssertEqual(retryCount, 1)
            XCTAssertNil(controller.retainedCompactChatNavigationDestination)
            XCTAssertEqual(destinationFactoryCount, 1)
            XCTAssertEqual(effects.deliveryCount(for: request), 1)
            XCTAssertEqual(
                controller.datasource.map(\.diffId),
                datasourceIdentityBeforeCancellation
            )
            XCTAssertEqual(
                controller.datasourceSections.map {
                    NavigationReturnDatasourceSectionIdentity(
                        kind: $0.kind,
                        rows: $0.rows.map(\.diffId)
                    )
                },
                datasourceSectionsBeforeCancellation
            )
            XCTAssertEqual(host.navigationController.viewControllers.count, 1)

            let retryToken = UUID()
            XCTAssertEqual(
                controller.chatNavigationSingleFlight.request(
                    target: romeo,
                    token: retryToken
                ),
                .started(retryToken)
            )
            XCTAssertFalse(
                controller.completeChatNavigationReturnTransition(
                    token: originalToken,
                    cancelled: true
                )
            )
            XCTAssertFalse(
                controller.completeChatNavigationReturnTransition(
                    token: originalToken,
                    cancelled: true
                )
            )
            XCTAssertEqual(
                controller.chatNavigationSingleFlight.state,
                .init(token: retryToken, target: romeo, phase: .preparing)
            )
            XCTAssertEqual(retryCount, 1)
            XCTAssertEqual(destinationFactoryCount, 1)
            XCTAssertEqual(effects.deliveryCount(for: request), 1)
        }
    }

    func testRetargetCancelsStaleDestinationHandleWithoutCancellingCurrentPreparation() {
        let controller = LastChatsViewController()
        let staleToken = UUID()
        let currentToken = UUID()
        var staleCancellationCount = 0
        var staleCompletionCount = 0
        let staleHandle = StackedNavigationPresentationPreparationHandle(
            cancellation: { staleCancellationCount += 1 },
            completion: { staleCompletionCount += 1 }
        )
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: staleToken)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: staleToken,
            preparationTimeout: 60
        )
        XCTAssertTrue(
            controller.registerOutgoingChatOpenNavigationPreparation(
                staleHandle,
                token: staleToken
            )
        )

        _ = controller.chatNavigationSingleFlight.request(target: mercutio, token: currentToken)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: currentToken,
            preparationTimeout: 60
        )
        staleHandle.finish()

        XCTAssertEqual(staleCancellationCount, 1)
        XCTAssertEqual(staleCompletionCount, 0)
        XCTAssertEqual(
            controller.chatNavigationSingleFlight.state,
            .init(token: currentToken, target: mercutio, phase: .preparing)
        )
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationPreparation)

        controller.resetChatNavigationTransaction(cancelled: true)
    }

    func testScheduledPreparationTimeoutIsBoundedAndUnlocksNavigation() {
        let controller = LastChatsViewController()
        let token = UUID()
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 0.01
        )
        let timeout = expectation(description: "navigation preparation timeout")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertNil(controller.chatNavigationSingleFlight.state)
            XCTAssertFalse(controller.isNavigationTransitionActive)
            XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationDeferral)
            timeout.fulfill()
        }

        wait(for: [timeout], timeout: 1)
    }

    func testStaleTimeoutAndCompletionCannotCancelSupersedingPreparation() {
        let controller = LastChatsViewController()
        let staleToken = UUID()
        let currentToken = UUID()
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: staleToken)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: staleToken,
            preparationTimeout: 60
        )
        _ = controller.chatNavigationSingleFlight.request(target: mercutio, token: currentToken)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: currentToken,
            preparationTimeout: 60
        )

        XCTAssertFalse(controller.handleChatNavigationPreparationTimeout(token: staleToken))
        XCTAssertFalse(
            controller.commitChatNavigationPush(
                token: staleToken,
                target: romeo
            )
        )
        XCTAssertFalse(
            controller.cancelChatNavigationPreparation(
                token: staleToken,
                reason: .presentationGuardRejected
            )
        )

        XCTAssertEqual(
            controller.chatNavigationSingleFlight.state,
            .init(token: currentToken, target: mercutio, phase: .preparing)
        )
        XCTAssertTrue(controller.isNavigationTransitionActive)
        XCTAssertTrue(controller.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertTrue(controller.hasPendingChatNavigationPreparationTimeout)

        controller.resetChatNavigationTransaction(cancelled: true)
    }

    func testPushStartCancelsPreparationTimeoutButKeepsDeferralUntilReturn() {
        let controller = LastChatsViewController()
        let token = UUID()
        var didRunDeferredWork = false
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 60
        )
        XCTAssertTrue(
            controller.deferUntilNavigationTransitionCompletesIfNeeded {
                didRunDeferredWork = true
            }
        )
        let didBeginPush = controller.commitChatNavigationPush(
            token: token,
            target: romeo
        )

        XCTAssertTrue(didBeginPush)
        XCTAssertTrue(controller.isNavigationTransitionActive)
        XCTAssertTrue(controller.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertFalse(controller.hasPendingChatNavigationPreparationTimeout)

        controller.resetChatNavigationTransaction(cancelled: false)

        XCTAssertTrue(didRunDeferredWork)
        XCTAssertNil(controller.chatNavigationSingleFlight.state)
        XCTAssertFalse(controller.isNavigationTransitionActive)
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationDeferral)
    }

    func testResetCancelsPreparationAndDropsDeferredWork() {
        let controller = LastChatsViewController()
        let token = UUID()
        var didRunDeferredWork = false
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        controller.beginOutgoingChatOpenNavigationDeferral(
            token: token,
            preparationTimeout: 60
        )
        XCTAssertTrue(
            controller.deferUntilNavigationTransitionCompletesIfNeeded {
                didRunDeferredWork = true
            }
        )

        controller.resetChatNavigationTransaction(cancelled: true)

        XCTAssertFalse(didRunDeferredWork)
        XCTAssertNil(controller.chatNavigationSingleFlight.state)
        XCTAssertFalse(controller.isNavigationTransitionActive)
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationDeferral)
        XCTAssertFalse(controller.hasPendingChatNavigationPreparationTimeout)
    }

    func testResetClearsPresentedStateForBackNavigation() {
        var coordinator = LastChatsNavigationSingleFlightCoordinator()
        let activeToken = UUID()
        _ = coordinator.request(target: romeo, token: activeToken)
        XCTAssertTrue(coordinator.markPushing(token: activeToken, target: romeo))
        XCTAssertTrue(coordinator.markPresented(token: activeToken, target: romeo))

        coordinator.reset()

        XCTAssertNil(coordinator.state)
        XCTAssertEqual(
            coordinator.request(target: romeo, token: UUID()).phase,
            .started
        )
    }

    func testRejectedPresentationCommitDoesNotRunUIKitMutation() {
        var events: [String] = []

        let didPresent = performGuardedStackedNavigationPresentation(
            commitPresentation: {
                events.append("commit")
                return false
            },
            presentation: {
                events.append("present")
            }
        )

        XCTAssertFalse(didPresent)
        XCTAssertEqual(events, ["commit"])
    }

    func testRejectedPresentationCancellationReleasesCompletedPreparationDestination() {
        let controller = LastChatsViewController()
        let token = UUID()
        weak var weakDestination: NavigationPreparationDestinationProbe?

        autoreleasepool {
            var destination: NavigationPreparationDestinationProbe? =
                NavigationPreparationDestinationProbe()
            weakDestination = destination
            let retainedDestination = destination
            let handle = StackedNavigationPresentationPreparationHandle(
                completion: {
                    _ = retainedDestination
                    let didPresent = performGuardedStackedNavigationPresentation(
                        commitPresentation: { false },
                        presentation: {
                            XCTFail("Rejected presentation must not mutate UIKit")
                        }
                    )
                    XCTAssertFalse(didPresent)
                    XCTAssertTrue(
                        controller.cancelChatNavigationPreparation(
                            token: token,
                            reason: .presentationGuardRejected
                        )
                    )
                }
            )
            _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
            controller.beginOutgoingChatOpenNavigationDeferral(
                token: token,
                preparationTimeout: 60
            )
            XCTAssertTrue(
                controller.registerOutgoingChatOpenNavigationPreparation(
                    handle,
                    token: token
                )
            )

            handle.finish()
            destination = nil
        }

        XCTAssertNil(weakDestination)
        XCTAssertNil(controller.chatNavigationSingleFlight.state)
        XCTAssertFalse(controller.hasActiveOutgoingChatOpenNavigationPreparation)
    }

    func testAcceptedPresentationCommitRunsBeforeUIKitMutation() {
        var events: [String] = []

        let didPresent = performGuardedStackedNavigationPresentation(
            commitPresentation: {
                events.append("commit")
                return true
            },
            presentation: {
                events.append("present")
            }
        )

        XCTAssertTrue(didPresent)
        XCTAssertEqual(events, ["commit", "present"])
    }

    func testPresentationGuardRejectsNavigationControllerCapturedFromStalePresenter() {
        let expectedNavigationController = UINavigationController()
        let currentNavigationController = UINavigationController()

        XCTAssertFalse(
            LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                expectedNavigationController: expectedNavigationController,
                currentNavigationController: currentNavigationController,
                isPresenterTopViewController: true,
                isPresenterVisibleInWindow: true,
                isPresenterInSelectedTabHierarchy: true,
                isForegroundActiveScene: true,
                isCurrentNavigationPushRoute: true,
                presenterHasPresentedViewController: false,
                navigationControllerHasPresentedViewController: false
            )
        )
        XCTAssertTrue(
            LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                expectedNavigationController: expectedNavigationController,
                currentNavigationController: expectedNavigationController,
                isPresenterTopViewController: true,
                isPresenterVisibleInWindow: true,
                isPresenterInSelectedTabHierarchy: true,
                isForegroundActiveScene: true,
                isCurrentNavigationPushRoute: true,
                presenterHasPresentedViewController: false,
                navigationControllerHasPresentedViewController: false
            )
        )
    }

    func testPresentationGuardRejectsPresenterInHiddenTab() {
        let navigationController = UINavigationController()

        XCTAssertFalse(
            LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                expectedNavigationController: navigationController,
                currentNavigationController: navigationController,
                isPresenterTopViewController: true,
                isPresenterVisibleInWindow: true,
                isPresenterInSelectedTabHierarchy: false,
                isForegroundActiveScene: true,
                isCurrentNavigationPushRoute: true,
                presenterHasPresentedViewController: false,
                navigationControllerHasPresentedViewController: false
            )
        )
    }

    func testPresentationGuardRejectsPresenterDetachedFromWindow() {
        let navigationController = UINavigationController()

        XCTAssertFalse(
            LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                expectedNavigationController: navigationController,
                currentNavigationController: navigationController,
                isPresenterTopViewController: true,
                isPresenterVisibleInWindow: false,
                isPresenterInSelectedTabHierarchy: true,
                isForegroundActiveScene: true,
                isCurrentNavigationPushRoute: true,
                presenterHasPresentedViewController: false,
                navigationControllerHasPresentedViewController: false
            )
        )
    }

    func testPresentationGuardRejectsPresenterOutsideActiveForegroundScene() {
        let navigationController = UINavigationController()

        XCTAssertFalse(
            LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                expectedNavigationController: navigationController,
                currentNavigationController: navigationController,
                isPresenterTopViewController: true,
                isPresenterVisibleInWindow: true,
                isPresenterInSelectedTabHierarchy: true,
                isForegroundActiveScene: false,
                isCurrentNavigationPushRoute: true,
                presenterHasPresentedViewController: false,
                navigationControllerHasPresentedViewController: false
            )
        )
    }

    func testPresentationGuardRejectsPresenterWhoseRouteExpandedToSplitDetail() {
        let navigationController = UINavigationController()

        XCTAssertFalse(
            LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                expectedNavigationController: navigationController,
                currentNavigationController: navigationController,
                isPresenterTopViewController: true,
                isPresenterVisibleInWindow: true,
                isPresenterInSelectedTabHierarchy: true,
                isForegroundActiveScene: true,
                isCurrentNavigationPushRoute: false,
                presenterHasPresentedViewController: false,
                navigationControllerHasPresentedViewController: false
            )
        )
    }

    func testMissingPresentationCommitPreservesExistingUnconditionalBehavior() {
        var didRunPresentation = false

        let didPresent = performGuardedStackedNavigationPresentation(
            commitPresentation: nil,
            presentation: {
                didRunPresentation = true
            }
        )

        XCTAssertTrue(didPresent)
        XCTAssertTrue(didRunPresentation)
    }

    @MainActor
    func testPresentedSameConversationAcceptsExactNotificationIntentWithoutSecondPush() throws {
        try withInterfaceType(.tabs) {
            let controller = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.loadViewIfNeeded()
            let alreadyPresentedChat = makeChat(for: romeo)
            let previouslyOwnedRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-before-tap"
            )
            let tappedRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-from-tap"
            )
            alreadyPresentedChat.pendingOpenMessageRequest = previouslyOwnedRequest
            navigationController.setViewControllers(
                [controller, alreadyPresentedChat],
                animated: false
            )
            let token = UUID()
            _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
            XCTAssertTrue(controller.chatNavigationSingleFlight.markPushing(token: token, target: romeo))
            XCTAssertTrue(controller.chatNavigationSingleFlight.markPresented(token: token, target: romeo))
            var acceptingDestination: ChatViewController?

            let acknowledged = controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: tappedRequest
            ) { chat in
                acceptingDestination = chat
            }

            XCTAssertFalse(
                acknowledged,
                "the matching destination accepts the exact intent immediately, but a notification route remains pending until that new exact request owns a stable frame"
            )
            XCTAssertTrue(
                acceptingDestination === alreadyPresentedChat,
                "the visible matching chat must explicitly accept the complete notification intent"
            )
            XCTAssertEqual(
                ownedOpenMessageRequest(in: alreadyPresentedChat),
                tappedRequest,
                "coalescing presentation must not preserve the stale exact anchor"
            )
            XCTAssertEqual(navigationController.viewControllers.count, 2)
            XCTAssertTrue(navigationController.topViewController === alreadyPresentedChat)
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testInitialPushNotificationDefersUntilStableVisibleDestinationCanAcknowledge() throws {
        try withInterfaceType(.tabs) {
            let (host, controller) = try makeForegroundNavigationHost(rootFactory: {
                LastChatsViewController()
            })
            defer { releaseForegroundNavigationHost(host) }
            let navigationController = host.navigationController
            let request = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-initial-deferred"
            )
            var preparedDestination: ChatViewController?
            let retried = expectation(
                description: "presented exact notification route is retried on its stable destination"
            )
            var retryCount = 0
            var retryAccepted = false
            var retryDestination: ChatViewController?
            var scheduled: [() -> Void] = []
            controller.pendingMessageNotificationAsyncScheduler = {
                scheduled.append($0)
            }
            controller.pendingMessageNotificationRouteRetryHandler = {
                retryCount += 1
                retryAccepted = controller.stackNewChat(
                    owner: self.romeo.owner,
                    jid: self.romeo.jid,
                    conversationType: self.romeo.conversationType,
                    openMessageRequest: request
                ) { chat in
                    retryDestination = chat
                }
                retried.fulfill()
                return retryAccepted
            }

            XCTAssertTrue(controller.isAppeared)
            XCTAssertTrue(controller.viewIfLoaded?.window === host.window)

            let accepted = controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: request
            ) { chat in
                preparedDestination = chat
            }

            XCTAssertFalse(accepted)
            let destination = try XCTUnwrap(preparedDestination)
            XCTAssertEqual(ownedOpenMessageRequest(in: destination), request)
            switch try XCTUnwrap(controller.chatNavigationSingleFlight.state?.phase) {
            case .preparing:
                XCTAssertTrue(
                    controller.retainedCompactChatNavigationDestination?.controller === destination
                )
                XCTAssertEqual(navigationController.viewControllers.count, 1)
            case .presented:
                XCTAssertNil(controller.retainedCompactChatNavigationDestination)
                XCTAssertEqual(navigationController.viewControllers.count, 2)
                XCTAssertTrue(navigationController.topViewController === destination)
            case .pushing:
                XCTAssertTrue(
                    controller.retainedCompactChatNavigationDestination?.controller === destination
                )
                XCTAssertEqual(navigationController.viewControllers.count, 2)
                XCTAssertTrue(navigationController.topViewController === destination)
            }

            XCTAssertTrue(waitUntil {
                controller.chatNavigationSingleFlight.state?.phase == .presented &&
                    navigationController.topViewController === destination &&
                    scheduled.count == 1
            })
            simulateCommittedStableChatOpenPresentation(on: destination)
            scheduled.removeFirst()()
            wait(for: [retried], timeout: 1)
            XCTAssertEqual(retryCount, 1)
            XCTAssertTrue(retryAccepted)
            XCTAssertTrue(retryDestination === destination)
            XCTAssertEqual(ownedOpenMessageRequest(in: destination), request)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.phase, .presented)
            XCTAssertNil(controller.retainedCompactChatNavigationDestination)
            XCTAssertEqual(navigationController.viewControllers.count, 2)
            XCTAssertTrue(navigationController.topViewController === destination)
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testInitialSearchIntentKeepsImmediateAcceptedResult() throws {
        try withInterfaceType(.tabs) {
            let (host, controller) = try makeForegroundNavigationHost(rootFactory: {
                LastChatsViewController()
            })
            defer { releaseForegroundNavigationHost(host) }
            let navigationController = host.navigationController
            let request = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-search-immediate",
                source: .search
            )
            var preparedDestination: ChatViewController?

            let accepted = controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: request
            ) { chat in
                preparedDestination = chat
            }

            XCTAssertTrue(accepted)
            let destination = try XCTUnwrap(preparedDestination)
            XCTAssertEqual(ownedOpenMessageRequest(in: destination), request)
            switch try XCTUnwrap(controller.chatNavigationSingleFlight.state?.phase) {
            case .preparing:
                XCTAssertTrue(
                    controller.retainedCompactChatNavigationDestination?.controller === destination
                )
                XCTAssertEqual(navigationController.viewControllers.count, 1)
            case .presented:
                XCTAssertNil(controller.retainedCompactChatNavigationDestination)
                XCTAssertEqual(navigationController.viewControllers.count, 2)
                XCTAssertTrue(navigationController.topViewController === destination)
            case .pushing:
                XCTAssertTrue(
                    controller.retainedCompactChatNavigationDestination?.controller === destination
                )
                XCTAssertEqual(navigationController.viewControllers.count, 2)
                XCTAssertTrue(navigationController.topViewController === destination)
            }
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testPreparingSameConversationNewerExactTargetRetargetsOneDestination() throws {
        try withInterfaceType(.tabs) {
            let controller = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.loadViewIfNeeded()
            let firstRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-preparing-old"
            )
            let newerRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-preparing-new"
            )
            let retainedPreparingDestination = makeChat(for: romeo)
            retainedPreparingDestination.pendingOpenMessageRequest = firstRequest
            let originalToken = UUID()
            _ = controller.chatNavigationSingleFlight.request(
                target: romeo,
                token: originalToken
            )
            controller.retainCompactChatNavigationDestination(
                retainedPreparingDestination,
                token: originalToken,
                target: romeo
            )
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.phase, .preparing)
            var retargetedDestination: ChatViewController?

            let accepted = controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: newerRequest
            ) { chat in
                retargetedDestination = chat
            }

            XCTAssertFalse(
                accepted,
                "the push route stays in NotifyManager until this preparation is visibly presented"
            )
            XCTAssertTrue(
                retargetedDestination === retainedPreparingDestination,
                "a newer stable target must retarget the retained preparation, not create or lose a destination"
            )
            XCTAssertEqual(
                ownedOpenMessageRequest(in: retainedPreparingDestination),
                newerRequest
            )
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.token, originalToken)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.target, romeo)
            XCTAssertEqual(
                navigationController.viewControllers.count,
                1,
                "retargeting one preparation must never produce a second chat push"
            )
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testPreparingIdenticalExactNotificationIntentRemainsIdempotent() throws {
        try withInterfaceType(.tabs) {
            let controller = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.loadViewIfNeeded()
            let request = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-identical"
            )
            let retainedPreparingDestination = makeChat(for: romeo)
            retainedPreparingDestination.pendingOpenMessageRequest = request
            let originalToken = UUID()
            _ = controller.chatNavigationSingleFlight.request(
                target: romeo,
                token: originalToken
            )
            controller.retainCompactChatNavigationDestination(
                retainedPreparingDestination,
                token: originalToken,
                target: romeo
            )
            let accepted = controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: request
            )

            XCTAssertFalse(
                accepted,
                "an identical provisional destination does not consume the typed push route"
            )
            XCTAssertEqual(
                ownedOpenMessageRequest(in: retainedPreparingDestination),
                request
            )
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.token, originalToken)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.target, romeo)
            XCTAssertEqual(
                navigationController.viewControllers.count,
                1,
                "an identical exact intent must remain owned by the single existing transaction"
            )
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testPushingSameConversationAcceptsExactIntentOnRetainedDestination() throws {
        try withInterfaceType(.tabs) {
            let controller = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.loadViewIfNeeded()
            let retainedDestination = makeChat(for: romeo)
            let oldRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-pushing-old"
            )
            let newerRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-pushing-new"
            )
            retainedDestination.pendingOpenMessageRequest = oldRequest
            let token = UUID()
            _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
            controller.retainCompactChatNavigationDestination(
                retainedDestination,
                token: token,
                target: romeo
            )
            XCTAssertTrue(controller.chatNavigationSingleFlight.markPushing(token: token, target: romeo))
            var acceptingDestination: ChatViewController?

            let accepted = controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: newerRequest
            ) { chat in
                acceptingDestination = chat
            }

            XCTAssertFalse(
                accepted,
                "phase pushing cannot acknowledge a push before transition completion"
            )
            XCTAssertTrue(acceptingDestination === retainedDestination)
            XCTAssertEqual(ownedOpenMessageRequest(in: retainedDestination), newerRequest)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.phase, .pushing)
            XCTAssertEqual(navigationController.viewControllers.count, 1)
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testPushingDifferentConversationReturnsFalseForTypedPendingRetry() throws {
        try withInterfaceType(.tabs) {
            let controller = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.loadViewIfNeeded()
            let retainedDestination = makeChat(for: romeo)
            let retainedRequest = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-pushing-owned"
            )
            retainedDestination.pendingOpenMessageRequest = retainedRequest
            let token = UUID()
            _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
            controller.retainCompactChatNavigationDestination(
                retainedDestination,
                token: token,
                target: romeo
            )
            XCTAssertTrue(controller.chatNavigationSingleFlight.markPushing(token: token, target: romeo))
            var acceptingDestination: ChatViewController?

            let accepted = controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: makeExactNotificationRequest(
                    target: mercutio,
                    archivedId: "archive-pushing-different"
                )
            ) { chat in
                acceptingDestination = chat
            }

            XCTAssertFalse(accepted)
            XCTAssertNil(acceptingDestination)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.token, token)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.target, romeo)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.phase, .pushing)
            XCTAssertEqual(retainedDestination.owner, romeo.owner)
            XCTAssertEqual(retainedDestination.jid, romeo.jid)
            XCTAssertEqual(ownedOpenMessageRequest(in: retainedDestination), retainedRequest)
            XCTAssertEqual(navigationController.viewControllers.count, 1)
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testSuccessfulPresentationSchedulesOneTypedPendingNotificationRetry() {
        let controller = LastChatsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        let destination = makeChat(for: romeo)
        navigationController.setViewControllers([controller, destination], animated: false)
        let request = makeExactNotificationRequest(
            target: romeo,
            archivedId: "archive-retry-visible"
        )
        _ = destination.acceptChatOpenPerformanceTrace(
            purpose: .notificationRoute,
            semanticTargetFingerprint:
                destination.chatOpenPerformanceSemanticTargetFingerprint(
                    for: request
                )
        )
        destination.pendingOpenMessageRequest = request
        simulateCommittedStableChatOpenPresentation(on: destination)
        let token = UUID()
        _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
        XCTAssertTrue(controller.chatNavigationSingleFlight.markPushing(token: token, target: romeo))
        controller.retainCompactChatNavigationDestination(
            destination,
            token: token,
            target: romeo
        )
        let retried = expectation(description: "typed notification pending route retried")
        var retryCount = 0
        var retryAccepted = false
        controller.pendingMessageNotificationRouteRetryHandler = {
            retryCount += 1
            retryAccepted = controller.stackNewChat(
                owner: self.romeo.owner,
                jid: self.romeo.jid,
                conversationType: self.romeo.conversationType,
                openMessageRequest: request
            )
            retried.fulfill()
            return retryAccepted
        }

        XCTAssertTrue(
            controller.completeChatNavigationPresentation(
                token: token,
                target: romeo,
                destination: destination
            )
        )

        wait(for: [retried], timeout: 1)
        XCTAssertEqual(retryCount, 1)
        XCTAssertTrue(retryAccepted)
        XCTAssertEqual(ownedOpenMessageRequest(in: destination), request)
        XCTAssertEqual(controller.chatNavigationSingleFlight.state?.phase, .presented)
        XCTAssertNil(controller.retainedCompactChatNavigationDestination)
        controller.resetChatNavigationTransaction(cancelled: true)
    }

    @MainActor
    func testCancellationAndTimeoutClearRetainedCompactDestinations() {
        let cancelledController = LastChatsViewController()
        let cancelledToken = UUID()
        let cancelledDestination = makeChat(for: romeo)
        _ = cancelledController.chatNavigationSingleFlight.request(
            target: romeo,
            token: cancelledToken
        )
        cancelledController.beginOutgoingChatOpenNavigationDeferral(
            token: cancelledToken,
            preparationTimeout: 60
        )
        cancelledController.retainCompactChatNavigationDestination(
            cancelledDestination,
            token: cancelledToken,
            target: romeo
        )

        XCTAssertTrue(
            cancelledController.cancelChatNavigationPreparation(
                token: cancelledToken,
                reason: .presentationGuardRejected
            )
        )
        XCTAssertNil(cancelledController.retainedCompactChatNavigationDestination)
        XCTAssertFalse(
            LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                request: makeExactNotificationRequest(
                    target: romeo,
                    archivedId: "archive-cancelled"
                ),
                isStableVisibleDestination: false,
                hasStableTargetAcknowledgement: false
            )
        )

        let timedOutController = LastChatsViewController()
        let timedOutToken = UUID()
        let timedOutDestination = makeChat(for: romeo)
        _ = timedOutController.chatNavigationSingleFlight.request(
            target: romeo,
            token: timedOutToken
        )
        timedOutController.beginOutgoingChatOpenNavigationDeferral(
            token: timedOutToken,
            preparationTimeout: 60
        )
        timedOutController.retainCompactChatNavigationDestination(
            timedOutDestination,
            token: timedOutToken,
            target: romeo
        )

        XCTAssertTrue(timedOutController.handleChatNavigationPreparationTimeout(token: timedOutToken))
        XCTAssertNil(timedOutController.retainedCompactChatNavigationDestination)
    }

    @MainActor
    func testPresentedDifferentConversationBuildsSeparateDestinationButDefersPushAcknowledgement() throws {
        try withInterfaceType(.tabs) {
            let (host, controller) = try makeForegroundNavigationHost(rootFactory: {
                LastChatsViewController()
            })
            defer { releaseForegroundNavigationHost(host) }
            let navigationController = host.navigationController
            let presentedChat = makeChat(for: romeo)
            navigationController.setViewControllers([controller, presentedChat], animated: false)
            presentedChat.loadViewIfNeeded()
            navigationController.view.layoutIfNeeded()
            presentedChat.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            XCTAssertTrue(presentedChat.viewIfLoaded?.window === host.window)
            let activeToken = UUID()
            _ = controller.chatNavigationSingleFlight.request(target: romeo, token: activeToken)
            XCTAssertTrue(
                controller.chatNavigationSingleFlight.markPushing(
                    token: activeToken,
                    target: romeo
                )
            )
            XCTAssertTrue(
                controller.chatNavigationSingleFlight.markPresented(
                    token: activeToken,
                    target: romeo
                )
            )
            let differentRequest = makeExactNotificationRequest(
                target: mercutio,
                archivedId: "archive-different-chat"
            )
            var acceptingDestination: ChatViewController?

            let accepted = controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: differentRequest
            ) { chat in
                acceptingDestination = chat
            }

            XCTAssertFalse(
                accepted,
                "the exact push stays pending until the separate destination is stably visible"
            )
            let destination = try XCTUnwrap(
                acceptingDestination,
                "a different notification target cannot be reported handled while the old chat remains the only destination"
            )
            XCTAssertFalse(destination === presentedChat)
            XCTAssertEqual(destination.owner, mercutio.owner)
            XCTAssertEqual(destination.jid, mercutio.jid)
            XCTAssertEqual(destination.conversationType, mercutio.conversationType)
            XCTAssertEqual(ownedOpenMessageRequest(in: destination), differentRequest)
            XCTAssertEqual(presentedChat.owner, romeo.owner)
            XCTAssertEqual(presentedChat.jid, romeo.jid)
            XCTAssertEqual(presentedChat.conversationType, romeo.conversationType)
            XCTAssertEqual(controller.chatNavigationSingleFlight.state?.target, mercutio)
            XCTAssertLessThanOrEqual(navigationController.viewControllers.count, 3)
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testExpandedSplitPolicyRetainsMatchingCurrentChatExactIntentCompatibility() throws {
        let route = StackedNavigationRoutePolicy.route(
            for: StackedNavigationRouteContext(
                interfaceType: .split,
                isPhone: false,
                hasSplitViewController: true,
                isSplitCollapsed: false,
                splitHorizontalSizeClass: .regular,
                windowHorizontalSizeClass: .regular,
                presenterHorizontalSizeClass: .regular
            )
        )
        XCTAssertEqual(route, .splitDetailReplacement)

        let controller = LastChatsViewController()
        let listNavigationController = UINavigationController(rootViewController: controller)
        let matchingCurrentChat = makeChat(for: romeo)
        let detailNavigationController = UINavigationController(
            rootViewController: matchingCurrentChat
        )
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.setViewController(UIViewController(), for: .primary)
        splitViewController.setViewController(listNavigationController, for: .supplementary)
        splitViewController.setViewController(detailNavigationController, for: .secondary)
        controller.currentChatVC = matchingCurrentChat
        let exactRequest = makeExactNotificationRequest(
            target: romeo,
            archivedId: "archive-split-exact"
        )
        let retainedDestination = try XCTUnwrap(
            InfoCardChatSearchRouting.matchingCurrentChat(
                in: splitViewController,
                route: InfoCardChatSearchRouting.route(
                    owner: romeo.owner,
                    jid: romeo.jid,
                    conversationType: romeo.conversationType
                )
            )
        )

        retainedDestination.queueOpenMessageRequest(exactRequest)

        XCTAssertTrue(retainedDestination === matchingCurrentChat)
        XCTAssertTrue(controller.currentChatVC === matchingCurrentChat)
        XCTAssertTrue(detailNavigationController.topViewController === matchingCurrentChat)
        XCTAssertEqual(detailNavigationController.viewControllers.count, 1)
        XCTAssertEqual(ownedOpenMessageRequest(in: matchingCurrentChat), exactRequest)
        XCTAssertNil(controller.chatNavigationSingleFlight.state)
    }

    @MainActor
    func testExpandedSplitStableMatchingDetailAcknowledgesExactPushWithoutReplacement() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        host.controller.chatOpenIntentDeliveryHandler = { intent, destination in
            effects.deliver(intent: intent, destination: destination)
            simulateCommittedStableChatOpenPresentation(on: destination)
        }
        let request = makeExactNotificationRequest(
            target: romeo,
            archivedId: "archive-split-stable"
        )

        let accepted = host.controller.stackNewChat(
            owner: romeo.owner,
            jid: romeo.jid,
            conversationType: romeo.conversationType,
            openMessageRequest: request
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(host.detailNavigationController.topViewController === host.currentChat)
        XCTAssertEqual(ownedOpenMessageRequest(in: host.currentChat), request)
        XCTAssertTrue(probe.attempts.isEmpty)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
    }

    @MainActor
    func testExpandedSplitActiveLeftMenuRouteBypassesResetAndPropagatesStableAcknowledgement() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        host.controller.chatOpenIntentDeliveryHandler = { intent, destination in
            effects.deliver(intent: intent, destination: destination)
            simulateCommittedStableChatOpenPresentation(on: destination)
        }
        let request = makeExactNotificationRequest(
            target: romeo,
            archivedId: "archive-split-left-menu"
        )
        let resetSentinel = LastChatsViewController.SelectedChatIdentity(
            jid: tybalt.jid,
            owner: tybalt.owner,
            conversationType: tybalt.conversationType
        )
        host.controller.selectedChatIdentity = resetSentinel

        let accepted = host.leftMenu.openChatlistWithChat(
            owner: romeo.owner,
            jid: romeo.jid,
            conversationType: romeo.conversationType,
            openMessageRequest: request,
            configure: nil
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(host.controller.selectedChatIdentity, resetSentinel)
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(host.detailNavigationController.topViewController === host.currentChat)
        XCTAssertEqual(ownedOpenMessageRequest(in: host.currentChat), request)
        XCTAssertTrue(probe.attempts.isEmpty)
    }

    @MainActor
    func testExpandedSplitInitialExactPushAcknowledgesOnlyAfterStableRetryOnSameController() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-new"
        )
        let retried = expectation(description: "stable split detail retries the typed push route")
        var retryAccepted = false
        var retryDestination: ChatViewController?
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            retryAccepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request
            ) { retryDestination = $0 }
            retried.fulfill()
            return retryAccepted
        }

        let initiallyAccepted = host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request
        )

        XCTAssertFalse(initiallyAccepted)
        XCTAssertEqual(probe.attempts.count, 1)
        let preparedDestination = try XCTUnwrap(probe.attempts.first?.destination)
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(host.detailNavigationController.topViewController === host.currentChat)
        XCTAssertEqual(ownedOpenMessageRequest(in: preparedDestination), request)
        XCTAssertTrue(
            probe.commitAttempt(
                at: 0,
                in: host.splitViewController
            )
        )
        simulateCommittedStableChatOpenPresentation(
            on: preparedDestination
        )

        wait(for: [retried], timeout: 1)
        XCTAssertTrue(retryAccepted)
        XCTAssertTrue(retryDestination === preparedDestination)
        XCTAssertTrue(host.controller.currentChatVC === preparedDestination)
        XCTAssertEqual(probe.installCount, 1)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
    }

    @MainActor
    func testExpandedSplitSameTargetRetargetsRetainedDestinationWithoutSecondInstall() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        let firstRequest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-first"
        )
        let newestRequest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-newest"
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: firstRequest
        ))
        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: newestRequest
        ))

        let retainedDestination = try XCTUnwrap(probe.attempts.first?.destination)
        XCTAssertEqual(probe.attempts.count, 1)
        XCTAssertEqual(ownedOpenMessageRequest(in: retainedDestination), newestRequest)
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(host.detailNavigationController.topViewController === host.currentChat)
        host.controller.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: true
        )
    }

    @MainActor
    func testExpandedSplitDifferentTargetCancelsStalePreparationAndLateCommitIsInert() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        let firstRequest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-stale"
        )
        let newestRequest = makeExactNotificationRequest(
            target: tybalt,
            archivedId: "archive-split-current"
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: firstRequest
        ))
        XCTAssertFalse(host.controller.stackNewChat(
            owner: tybalt.owner,
            jid: tybalt.jid,
            conversationType: tybalt.conversationType,
            openMessageRequest: newestRequest
        ))

        XCTAssertEqual(probe.attempts.count, 2)
        XCTAssertEqual(probe.cancellationCount, 1)
        XCTAssertFalse(probe.commitAttempt(at: 0, in: host.splitViewController))
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(host.detailNavigationController.topViewController === host.currentChat)
        XCTAssertEqual(host.currentChat.owner, romeo.owner)
        XCTAssertEqual(host.currentChat.jid, romeo.jid)
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.target,
            tybalt
        )
        host.controller.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: true
        )
    }

    @MainActor
    func testExpandedSplitCollapseRejectionRetainsPreparedPushAndPreviousDetailUntilWakeup() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        var route: StackedNavigationRoute = .splitDetailReplacement
        var attempts: [Bool] = []
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        host.controller.chatNavigationRouteResolver = { _ in route }
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            attempts.append(destinationWasAlreadyPrepared)
        }
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-collapse"
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request
        ))
        route = .currentNavigationPush
        let listNavigationController = try XCTUnwrap(
            host.controller.navigationController
        )
        host.splitViewController.setViewController(nil, for: .supplementary)
        host.window.rootViewController = listNavigationController
        host.window.makeKeyAndVisible()
        listNavigationController.view.layoutIfNeeded()
        controlledDestination.releaseNextPreparation()

        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })
        XCTAssertEqual(attempts, [false])
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(
            host.detailNavigationController.topViewController === host.currentChat
        )
        XCTAssertNotNil(host.controller.expandedSplitChatNavigationTransaction)
        XCTAssertTrue(listNavigationController.topViewController === host.controller)
    }

    @MainActor
    func testExpandedSplitSearchAcknowledgesWhileOnePreparedDestinationIsRetained() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-search",
            source: .search
        )

        XCTAssertTrue(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request
        ))
        XCTAssertEqual(probe.attempts.count, 1)
        XCTAssertNotNil(host.controller.expandedSplitChatNavigationTransaction)
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        host.controller.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: true
        )
    }

    @MainActor
    func testExpandedSplitDifferentPushWaitsWhilePresentedDetailIsStillTransitioning() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let probe = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = probe.present
        let firstRequest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-presenting"
        )
        let newerRequest = makeExactNotificationRequest(
            target: tybalt,
            archivedId: "archive-split-waits"
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: firstRequest
        ))
        XCTAssertTrue(probe.installAttempt(at: 0, in: host.splitViewController))
        let presentedDestination = try XCTUnwrap(probe.attempts.first?.destination)

        XCTAssertFalse(host.controller.stackNewChat(
            owner: tybalt.owner,
            jid: tybalt.jid,
            conversationType: tybalt.conversationType,
            openMessageRequest: newerRequest
        ))
        XCTAssertEqual(probe.attempts.count, 1)
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController
                === presentedDestination
        )
        XCTAssertEqual(presentedDestination.owner, mercutio.owner)
        XCTAssertEqual(presentedDestination.jid, mercutio.jid)
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )
        probe.completeAttempt(at: 0, didPresent: true)
    }

    @MainActor
    func testSameTargetNotificationPromotesStandardPreparationWithoutSecondControllerOrDelivery() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let presentation = ExpandedSplitChatPresentationProbe()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var configuredDestinations: Set<ObjectIdentifier> = []
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = presentation.present
        host.controller.expandedSplitPreparedChatPresentationHandler = presentation.present
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        let standardRequest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "standard-preparation",
            source: .search
        )
        let notificationRequest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "promoted-notification"
        )

        XCTAssertTrue(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: standardRequest,
            navigationSource: .standard,
            configure: { destination in
                if let destination {
                    configuredDestinations.insert(ObjectIdentifier(destination))
                }
            }
        ))
        let destination = try XCTUnwrap(presentation.attempts.first?.destination)

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: notificationRequest,
            navigationSource: .notification,
            configure: { destination in
                if let destination {
                    configuredDestinations.insert(ObjectIdentifier(destination))
                }
            }
        ))
        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: notificationRequest,
            navigationSource: .notification
        ))

        XCTAssertEqual(
            configuredDestinations,
            Set([ObjectIdentifier(destination)])
        )
        XCTAssertEqual(presentation.attempts.count, 1)
        XCTAssertEqual(effects.deliveryCount(for: standardRequest), 1)
        XCTAssertEqual(effects.deliveryCount(for: notificationRequest), 1)
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.navigationSource,
            .notification
        )
        XCTAssertEqual(
            host.controller.chatOpenIntentOwnership?.intent,
            .message(notificationRequest)
        )
        XCTAssertEqual(
            host.controller.chatOpenIntentOwnership?.navigationSource,
            .notification
        )
    }

    @MainActor
    func testExpandedSplitTransactionModelSemanticallyTypechecksImmutablePromotion() throws {
        let controller = LastChatsViewController()
        let destination = makeChat(for: mercutio)
        let token = UUID()
        let account = NSObject()
        controller.installExpandedSplitChatNavigationTransaction(
            token: token,
            target: mercutio,
            destination: destination,
            previousVisibleDetail: nil,
            previousSecondarySnapshot: .init(
                container: nil,
                topViewController: nil
            ),
            accountEpoch: .init(
                accountIdentifier: ObjectIdentifier(account),
                isPresent: true,
                isEnabled: true
            ),
            navigationSource: .standard,
            activationContext: nil
        )

        controller.promoteExpandedSplitChatNavigationSourceToNotification(
            token: token
        )

        let promoted = try XCTUnwrap(
            controller.expandedSplitChatNavigationTransaction
        )
        XCTAssertEqual(promoted.navigationSource, .notification)
        XCTAssertEqual(promoted.token, token)
        XCTAssertTrue(promoted.destination === destination)
        XCTAssertEqual(
            promoted.accountEpoch.accountIdentifier,
            Optional(ObjectIdentifier(account))
        )
    }

    @MainActor
    func testInitiallyMissingOrDisabledAccountCannotCommitUntilAValidEnabledIdentityEpochExists() throws {
        let disabledAccount = NSObject()
        let materializedAccount = NSObject()
        let cases: [(String, LastChatsChatNavigationAccountEpoch, LastChatsChatNavigationAccountEpoch)] = [
            (
                "missing",
                .init(
                    accountIdentifier: nil,
                    isPresent: false,
                    isEnabled: false
                ),
                .init(
                    accountIdentifier: ObjectIdentifier(materializedAccount),
                    isPresent: true,
                    isEnabled: true
                )
            ),
            (
                "disabled",
                .init(
                    accountIdentifier: ObjectIdentifier(disabledAccount),
                    isPresent: true,
                    isEnabled: false
                ),
                .init(
                    accountIdentifier: ObjectIdentifier(disabledAccount),
                    isPresent: true,
                    isEnabled: true
                )
            )
        ]

        for (name, invalidEpoch, validEpoch) in cases {
            let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
            let presentation = ExpandedSplitChatPresentationProbe()
            let effects = LastChatsChatOpenIntentSideEffectProbe()
            var epoch = invalidEpoch
            host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
            host.controller.chatNavigationAccountEpochResolver = { _ in epoch }
            host.controller.expandedSplitChatPresentationHandler = presentation.present
            host.controller.expandedSplitPreparedChatPresentationHandler = presentation.present
            host.controller.chatOpenIntentDeliveryHandler = effects.deliver
            let request = makeExactNotificationRequest(
                target: mercutio,
                archivedId: "account-\(name)"
            )

            XCTAssertFalse(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ), name)
            let destination = try XCTUnwrap(
                host.controller.expandedSplitChatNavigationTransaction?.destination,
                name
            )
            XCTAssertFalse(
                presentation.commitAttempt(at: 0, in: host.splitViewController),
                name
            )
            XCTAssertEqual(
                host.controller.expandedSplitChatNavigationTransaction?.phase,
                .waitingForEligibility,
                name
            )
            XCTAssertTrue(host.controller.currentChatVC === host.currentChat, name)
            XCTAssertEqual(effects.deliveryCount(for: request), 1, name)

            XCTAssertFalse(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ), name)
            XCTAssertEqual(presentation.attempts.count, 1, name)

            epoch = validEpoch
            XCTAssertFalse(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ), name)
            XCTAssertEqual(presentation.attempts.count, 2, name)
            XCTAssertTrue(
                presentation.attempts[1].destination === destination,
                name
            )
            XCTAssertTrue(
                presentation.commitAttempt(at: 1, in: host.splitViewController),
                name
            )
            XCTAssertEqual(effects.deliveryCount(for: request), 1, name)
            simulateCommittedStableChatOpenPresentation(
                on: destination,
                file: #filePath,
                line: #line
            )
            XCTAssertTrue(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ), name)
            releaseForegroundExpandedSplitHost(host)
        }
    }

    @MainActor
    func testInactiveSupplementaryActivationStillRequiresForegroundKeyWindowAndActualModalTransitionGuards() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let supplementaryNavigation = try XCTUnwrap(
            host.controller.navigationController
        )
        let windowScene = try XCTUnwrap(host.window.windowScene)
        let foregroundKeyWindow = UIWindow(windowScene: windowScene)
        foregroundKeyWindow.frame = windowScene.coordinateSpace.bounds
        foregroundKeyWindow.rootViewController = UIViewController()
        foregroundKeyWindow.makeKeyAndVisible()
        defer {
            foregroundKeyWindow.isHidden = true
            foregroundKeyWindow.rootViewController = nil
        }
        let inactiveTop = UIViewController()
        supplementaryNavigation.pushViewController(inactiveTop, animated: false)
        let coveringModal = UIViewController()
        inactiveTop.present(coveringModal, animated: false)
        let oldSecondary = host.splitViewController.viewController(for: .secondary)
        var attempts: [Bool] = []
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            attempts.append(destinationWasAlreadyPrepared)
        }
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "inactive-real-guards"
        )

        XCTAssertFalse(host.leftMenu.openChatlistWithChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification,
            configure: nil
        ))
        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })
        XCTAssertEqual(attempts, [false])
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary) === oldSecondary
        )
        XCTAssertTrue(supplementaryNavigation.topViewController === inactiveTop)

        coveringModal.dismiss(animated: false)
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            host.leftMenu.openChatlistWithChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification,
                configure: nil
            )
        }
        host.controller.retryPendingMessageNotificationRouteOnLifecycleStability()

        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility && attempts.count == 2
        })
        XCTAssertEqual(attempts, [false, true])
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary) === oldSecondary
        )
        XCTAssertTrue(supplementaryNavigation.topViewController === inactiveTop)

        host.window.makeKeyAndVisible()
        host.controller.retryPendingMessageNotificationRouteOnLifecycleStability()

        XCTAssertTrue(waitUntil {
            let secondary = host.splitViewController.viewController(for: .secondary)
            let chat = (secondary as? UINavigationController)?.topViewController
                as? ChatViewController
            return chat?.jid == self.mercutio.jid &&
                supplementaryNavigation.topViewController === host.controller
        })
        XCTAssertEqual(attempts, [false, true, true])
    }

    @MainActor
    func testPersistentGuardRejectionCoalescesOnePendingIntentAndPerformsZeroRecursivePreparation() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let coveringModal = UIViewController()
        host.detailNavigationController.present(coveringModal, animated: false)
        defer { coveringModal.dismiss(animated: false) }
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var attempts: [Bool] = []
        var retryDispatchCount = 0
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            attempts.append(destinationWasAlreadyPrepared)
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            retryDispatchCount += 1
            return false
        }
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "persistent-modal"
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })
        let destination = try XCTUnwrap(
            host.controller.expandedSplitChatNavigationTransaction?.destination
        )

        for _ in 0..<3 {
            XCTAssertFalse(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(attempts, [false])
        XCTAssertEqual(retryDispatchCount, 0)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertTrue(
            host.controller.expandedSplitChatNavigationTransaction?.destination
                === destination
        )
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
    }

    @MainActor
    func testProductionShowStackedOwnsExpandedSplitPresentationAndNativeCompletion() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        var attempts: [Bool] = []
        var stableAcknowledgementCount = 0
        var scheduled: [() -> Void] = []
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "production-show-stacked"
        )
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            attempts.append(destinationWasAlreadyPrepared)
        }
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))

        XCTAssertTrue(waitUntil(timeout: 2) {
            let secondary = host.splitViewController.viewController(for: .secondary)
            let chat = (secondary as? UINavigationController)?.topViewController
                as? ChatViewController
            return chat?.jid == self.mercutio.jid && scheduled.count == 1
        })
        let installedSecondary = try XCTUnwrap(
            host.splitViewController.viewController(for: .secondary)
                as? UINavigationController
        )
        let destination = try XCTUnwrap(
            installedSecondary.topViewController as? ChatViewController
        )
        simulateCommittedStableChatOpenPresentation(on: destination)
        scheduled.removeFirst()()
        XCTAssertTrue(waitUntil { stableAcknowledgementCount == 1 })
        XCTAssertEqual(attempts, [false])
        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertTrue(host.controller.currentChatVC === destination)
        XCTAssertEqual(ownedOpenMessageRequest(in: destination), request)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
    }

    @MainActor
    func testPhoneHostPassesOneInjectedSplitRouteThroughLeftMenuAndProductionShowStacked() throws {
        XCTAssertEqual(
            UIDevice.current.userInterfaceIdiom,
            .phone,
            "the fixed C302 integration host is intentionally a phone"
        )
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let previousSecondary = host.splitViewController.viewController(
            for: .secondary
        )
        var presentationAttempts: [Bool] = []
        var stableAcknowledgementCount = 0
        var scheduled: [() -> Void] = []
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "phone-production-split-route"
        )
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            presentationAttempts.append(destinationWasAlreadyPrepared)
        }
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.leftMenu.openChatlistWithChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification,
                configure: nil
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertEqual(
            stackedNavigationRoute(for: host.controller),
            .currentNavigationPush,
            "the device policy remains compact on phone; only the transaction decision is injected"
        )
        XCTAssertEqual(
            host.controller.chatNavigationRouteResolver(host.controller),
            .splitDetailReplacement
        )
        XCTAssertEqual(
            host.leftMenu.chatNavigationRouteResolver(
                host.splitViewController
            ),
            .splitDetailReplacement
        )
        XCTAssertFalse(host.leftMenu.openChatlistWithChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification,
            configure: nil
        ))

        XCTAssertTrue(waitUntil(timeout: 2) {
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            let destination = (secondary as? UINavigationController)?
                .topViewController as? ChatViewController
            return secondary !== previousSecondary &&
                destination?.jid == self.mercutio.jid && scheduled.count == 1
        })
        let destination = try XCTUnwrap(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController
                as? ChatViewController
        )
        simulateCommittedStableChatOpenPresentation(on: destination)
        scheduled.removeFirst()()
        XCTAssertTrue(waitUntil { stableAcknowledgementCount == 1 })
        XCTAssertEqual(presentationAttempts, [false])
        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertTrue(
            host.controller.navigationController?.topViewController
                === host.controller,
            "production split presentation must not compact-push the chat"
        )
    }

    @MainActor
    func testCancelledProductionSplitMutationRestoresPreviousSecondaryAndRetriesExactRouteOnce() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let previousSecondary = try XCTUnwrap(
            host.splitViewController.viewController(for: .secondary)
        )
        let previousSecondaryTop = try XCTUnwrap(
            (previousSecondary as? UINavigationController)?.topViewController
        )
        let controlledDestination =
            ControlledExpandedSplitChatViewController(
                controlsNativeTransitionCompletion: true
            )
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var scheduled: [() -> Void] = []
        var stableAcknowledgementCount = 0
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "cancelled-native-secondary"
        )
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationTransitionRegistrar = {
            _, _ in false
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        controlledDestination.releaseNextPreparation()

        XCTAssertTrue(waitUntil {
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            return (secondary as? UINavigationController)?
                .topViewController === controlledDestination &&
                controlledDestination.nativeTransitionCompletions.count == 1
        })
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .presenting
        )
        XCTAssertEqual(
            host.controller.chatOpenIntentOwnership?.intent,
            .message(request)
        )
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(
            host.controller.playerViewToolbar.delegate === host.currentChat
        )

        controlledDestination.completeNativeTransition(
            at: 0,
            didComplete: false
        )
        controlledDestination.completeNativeTransition(
            at: 0,
            didComplete: false
        )

        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === previousSecondary
        )
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController
                === previousSecondaryTop
        )
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(
            host.controller.playerViewToolbar.delegate === host.currentChat
        )
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .waitingForEligibility
        )
        XCTAssertTrue(
            host.controller.expandedSplitChatNavigationTransaction?.destination
                === controlledDestination
        )
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(
            host.controller.chatOpenIntentOwnership?.intent,
            .message(request)
        )
        XCTAssertEqual(stableAcknowledgementCount, 0)
        XCTAssertEqual(scheduled.count, 1)

        scheduled.removeFirst()()
        XCTAssertTrue(waitUntil {
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            return (secondary as? UINavigationController)?
                .topViewController === controlledDestination &&
                controlledDestination.nativeTransitionCompletions.count == 2
        })
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(
            host.controller.chatOpenIntentOwnership?.intent,
            .message(request)
        )
        controlledDestination.completeNativeTransition(
            at: 1,
            didComplete: true
        )
        XCTAssertEqual(scheduled.count, 1)
        simulateCommittedStableChatOpenPresentation(
            on: controlledDestination
        )
        scheduled.removeFirst()()

        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
        XCTAssertTrue(host.controller.currentChatVC === controlledDestination)
        XCTAssertTrue(
            host.controller.playerViewToolbar.delegate
                === controlledDestination
        )
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        effects.assertEveryAnchorSideEffectExecutedOnce()
    }

    @MainActor
    func testCancelledProductionSplitMutationDoesNotOverwriteNewerSecondaryOwner() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let controlledDestination =
            ControlledExpandedSplitChatViewController(
                controlsNativeTransitionCompletion: true
            )
        let newerSecondary = UINavigationController(
            rootViewController: UIViewController()
        )
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var scheduled: [() -> Void] = []
        var retryDispatchCount = 0
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "cancelled-newer-secondary-owner"
        )
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            retryDispatchCount += 1
            return false
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        controlledDestination.releaseNextPreparation()
        XCTAssertTrue(waitUntil {
            controlledDestination.nativeTransitionCompletions.count == 1
        })
        host.splitViewController.setViewController(
            newerSecondary,
            for: .secondary
        )

        controlledDestination.completeNativeTransition(
            at: 0,
            didComplete: false
        )
        controlledDestination.completeNativeTransition(
            at: 0,
            didComplete: false
        )
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === newerSecondary
        )
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(retryDispatchCount, 0)
        if !scheduled.isEmpty {
            scheduled.removeFirst()()
        }
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === newerSecondary
        )
        XCTAssertEqual(retryDispatchCount, 1)
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
    }

    @MainActor
    func testExpandedSplitStableRetryDoesNotRedeliverProvisionalExactIntentSideEffects() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let presentation = ExpandedSplitChatPresentationProbe()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = presentation.present
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-split-delivery-once"
        )
        let retried = expectation(description: "split exact route reaches stable ACK")
        var retryAccepted = false
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            retryAccepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            retried.fulfill()
            return retryAccepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        let destination = try XCTUnwrap(presentation.attempts.first?.destination)
        effects.simulateExecutionCompletion(on: destination)
        XCTAssertTrue(presentation.commitAttempt(at: 0, in: host.splitViewController))

        wait(for: [retried], timeout: 1)
        XCTAssertTrue(retryAccepted)
        effects.assertEveryAnchorSideEffectExecutedOnce()
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertTrue(host.controller.currentChatVC === destination)
    }

    @MainActor
    func testCompactStableRetryDoesNotRedeliverProvisionalExactIntentSideEffects() throws {
        try withInterfaceType(.tabs) {
            let controller = LastChatsViewController()
            let navigationController = UINavigationController(rootViewController: controller)
            let destination = makeChat(for: romeo)
            navigationController.setViewControllers([controller, destination], animated: false)
            let effects = LastChatsChatOpenIntentSideEffectProbe()
            controller.chatOpenIntentDeliveryHandler = effects.deliver
            let request = makeExactNotificationRequest(
                target: romeo,
                archivedId: "archive-compact-delivery-once"
            )
            _ = controller.acceptChatOpenIntent(
                on: destination,
                target: romeo,
                openMessageRequest: request,
                configure: nil
            )
            effects.simulateExecutionCompletion(on: destination)
            let token = UUID()
            _ = controller.chatNavigationSingleFlight.request(target: romeo, token: token)
            XCTAssertTrue(controller.chatNavigationSingleFlight.markPushing(token: token, target: romeo))
            XCTAssertTrue(controller.chatNavigationSingleFlight.markPresented(token: token, target: romeo))

            XCTAssertTrue(controller.stackNewChat(
                owner: romeo.owner,
                jid: romeo.jid,
                conversationType: romeo.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ))
            effects.assertEveryAnchorSideEffectExecutedOnce()
            XCTAssertEqual(effects.deliveryCount(for: request), 1)
            controller.resetChatNavigationTransaction(cancelled: true)
        }
    }

    @MainActor
    func testExpandedSplitNewerExactIdReplacesProvisionalOwnershipAndExecutesNewestOnce() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let presentation = ExpandedSplitChatPresentationProbe()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = presentation.present
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        let first = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-provisional-old"
        )
        let newest = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "archive-provisional-newest"
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: first,
            navigationSource: .notification
        ))
        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: newest,
            navigationSource: .notification
        ))

        XCTAssertEqual(effects.deliveryCount(for: first), 1)
        XCTAssertEqual(effects.deliveryCount(for: newest), 1)
        XCTAssertEqual(
            host.controller.chatOpenIntentOwnership?.intent,
            .message(newest)
        )
        XCTAssertEqual(presentation.attempts.count, 1)
    }

    @MainActor
    func testExpandedSplitNilExplicitIntentResolvesUnreadSavedLatestOnceBeforePreparation() throws {
        let cases: [(String, LastChatsResolvedChatOpenIntent)] = [
            (
                "unread",
                .message(makeImplicitOpenRequest(target: mercutio, source: .initialUnreadBoundary))
            ),
            (
                "saved",
                .message(makeImplicitOpenRequest(target: mercutio, source: .savedVisiblePosition))
            ),
            ("latest", .latest)
        ]

        for (name, expectedIntent) in cases {
            let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
            let presentation = ExpandedSplitChatPresentationProbe()
            let effects = LastChatsChatOpenIntentSideEffectProbe()
            var resolutionCount = 0
            host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
            host.controller.expandedSplitChatPresentationHandler = presentation.present
            host.controller.chatOpenIntentDeliveryHandler = effects.deliver
            host.controller.chatOpenMessageRequestResolverOverride = { target, explicit in
                XCTAssertEqual(target, self.mercutio, name)
                XCTAssertNil(explicit, name)
                resolutionCount += 1
                if case .message(let request) = expectedIntent {
                    return request
                }
                return nil
            }

            XCTAssertTrue(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: nil,
                navigationSource: .standard
            ), name)
            XCTAssertEqual(resolutionCount, 1, name)
            XCTAssertEqual(host.controller.chatOpenIntentOwnership?.intent, expectedIntent, name)
            XCTAssertEqual(effects.deliveredIntents, [expectedIntent], name)
            XCTAssertEqual(presentation.attempts.count, 1, name)
            releaseForegroundExpandedSplitHost(host)
        }
    }

    @MainActor
    func testMessageNotificationWithoutStableAnchorDefersUntilStableSplitPresentation() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let presentation = ExpandedSplitChatPresentationProbe()
        var route: StackedNavigationRoute = .splitDetailReplacement
        host.controller.chatNavigationRouteResolver = { _ in route }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: nil,
            navigationSource: .notification
        ))
        XCTAssertEqual(presentation.attempts.count, 1)
        route = .currentNavigationPush
        XCTAssertFalse(presentation.commitAttempt(at: 0, in: host.splitViewController))
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .waitingForEligibility
        )
    }

    @MainActor
    func testMessageNotificationDefersUntilCompactPresentationAndTargetFrameAreStable() {
        let request: ChatOpenMessageRequest? = nil

        XCTAssertFalse(
            LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: .notification,
                request: request,
                isStableVisibleDestination: false,
                hasStableTargetAcknowledgement: false
            )
        )
        XCTAssertFalse(
            LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: .notification,
                request: request,
                isStableVisibleDestination: true,
                hasStableTargetAcknowledgement: false
            )
        )
        XCTAssertTrue(
            LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: .notification,
                request: request,
                isStableVisibleDestination: true,
                hasStableTargetAcknowledgement: true
            )
        )
        XCTAssertTrue(
            LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: .standard,
                request: request,
                isStableVisibleDestination: false,
                hasStableTargetAcknowledgement: false
            )
        )
    }

    func testMessageNotificationWithoutStableAnchorDefersUntilStableChatPresentation() {
        XCTAssertFalse(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .notification,
            request: nil,
            isStableVisibleDestination: false,
            hasStableTargetAcknowledgement: false
        ))
        XCTAssertFalse(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .notification,
            request: nil,
            isStableVisibleDestination: true,
            hasStableTargetAcknowledgement: false
        ))
        XCTAssertTrue(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .notification,
            request: nil,
            isStableVisibleDestination: true,
            hasStableTargetAcknowledgement: true
        ))
        XCTAssertTrue(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .standard,
            request: nil,
            isStableVisibleDestination: false,
            hasStableTargetAcknowledgement: false
        ))
    }

    @MainActor
    func testExpandedSplitInactiveChatListDoesNotInstallEmptyDetailBeforePreparedCommit() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let oldDetailContainer = try XCTUnwrap(
            host.splitViewController.viewController(for: .secondary)
        )
        let unrelatedSupplementary = UINavigationController(
            rootViewController: UIViewController()
        )
        host.splitViewController.setViewController(
            unrelatedSupplementary,
            for: .supplementary
        )
        let presentation = ExpandedSplitChatPresentationProbe()
        host.leftMenu.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertTrue(host.leftMenu.openChatlistWithChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: nil,
            navigationSource: .standard,
            configure: nil
        ))

        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === oldDetailContainer
        )
        XCTAssertFalse(
            (host.splitViewController.viewController(for: .secondary)
                as? UINavigationController)?.topViewController
                is EmptyChatViewController
        )
        XCTAssertTrue(presentation.commitAttempt(
            at: 0,
            in: host.splitViewController
        ))
        XCTAssertTrue(
            (host.splitViewController.viewController(for: .supplementary)
                as? UINavigationController)?.topViewController
                === host.controller
        )
    }

    @MainActor
    func testExpandedSplitBuriedChatListIsActivatedAtomicallyInsteadOfTreatedAsVisible() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let listNavigationController = try XCTUnwrap(host.controller.navigationController)
        let overlay = UIViewController()
        listNavigationController.setViewControllers(
            [host.controller, overlay],
            animated: false
        )
        let oldDetailContainer = host.splitViewController.viewController(for: .secondary)
        let presentation = ExpandedSplitChatPresentationProbe()
        host.leftMenu.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertFalse(host.leftMenu.openChatlistWithChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: makeExactNotificationRequest(
                target: mercutio,
                archivedId: "buried-list-route"
            ),
            navigationSource: .notification,
            configure: nil
        ))
        XCTAssertTrue(listNavigationController.topViewController === overlay)
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === oldDetailContainer
        )

        XCTAssertTrue(presentation.commitAttempt(
            at: 0,
            in: host.splitViewController
        ))
        XCTAssertTrue(listNavigationController.topViewController === host.controller)
    }

    @MainActor
    func testExpandedSplitMatchingDetailBehindSecondaryNavigationModalDoesNotAcknowledgeExactPush() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        let coveringModal = UIViewController()
        host.detailNavigationController.present(coveringModal, animated: false)
        defer { coveringModal.dismiss(animated: false) }
        XCTAssertTrue(
            host.detailNavigationController.presentedViewController
                === coveringModal
        )

        XCTAssertFalse(host.controller.stackNewChat(
            owner: romeo.owner,
            jid: romeo.jid,
            conversationType: romeo.conversationType,
            openMessageRequest: makeExactNotificationRequest(
                target: romeo,
                archivedId: "detail-modal"
            ),
            navigationSource: .notification
        ))
    }

    @MainActor
    func testExpandedSplitPreparationDoesNotCommitDuringSecondaryNavigationTransitionOrModal() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let transitionDelegate = SlowModalTransitioningDelegate(
            duration: 1.25
        )
        let coveringModal = UIViewController()
        coveringModal.modalPresentationStyle = .custom
        coveringModal.transitioningDelegate = transitionDelegate
        host.detailNavigationController.present(coveringModal, animated: true)
        let oldSecondary = host.splitViewController.viewController(for: .secondary)
        var attempts: [Bool] = []
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            attempts.append(destinationWasAlreadyPrepared)
        }

        XCTAssertNotNil(
            host.detailNavigationController.transitionCoordinator
                ?? coveringModal.transitionCoordinator,
            "the rejection must be owned by a real UIKit transition"
        )
        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: makeExactNotificationRequest(
                target: mercutio,
                archivedId: "secondary-native-transition"
            ),
            navigationSource: .notification
        ))
        XCTAssertTrue(waitUntil(timeout: 1) {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })
        XCTAssertEqual(attempts, [false])
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary) === oldSecondary
        )
        XCTAssertTrue(host.controller.currentChatVC === host.currentChat)
        XCTAssertTrue(waitUntil(timeout: 2) {
            host.detailNavigationController.transitionCoordinator == nil &&
                coveringModal.transitionCoordinator == nil
        })
        coveringModal.dismiss(animated: false)
    }

    @MainActor
    func testExpandedSplitNonChatSecondaryReplacementMakesPreparedCommitStaleAndInert() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let firstNonChat = UIViewController()
        let firstContainer = UINavigationController(rootViewController: firstNonChat)
        host.splitViewController.setViewController(firstContainer, for: .secondary)
        host.controller.currentChatVC = nil
        let presentation = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertTrue(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            navigationSource: .standard
        ))
        let replacement = UINavigationController(
            rootViewController: UIViewController()
        )
        host.splitViewController.setViewController(replacement, for: .secondary)

        XCTAssertFalse(presentation.commitAttempt(
            at: 0,
            in: host.splitViewController
        ))
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === replacement
        )
        XCTAssertNil(host.controller.currentChatVC)
    }

    @MainActor
    func testExpandedSplitAccountDisabledBeforePreparedCommitMakesItStale() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let account = NSObject()
        var epoch = LastChatsChatNavigationAccountEpoch(
            accountIdentifier: ObjectIdentifier(account),
            isEnabled: true
        )
        let presentation = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.chatNavigationAccountEpochResolver = { _ in epoch }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertTrue(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            navigationSource: .standard
        ))
        epoch = LastChatsChatNavigationAccountEpoch(
            accountIdentifier: ObjectIdentifier(account),
            isEnabled: false
        )
        XCTAssertFalse(presentation.commitAttempt(at: 0, in: host.splitViewController))
    }

    @MainActor
    func testExpandedSplitSameJIDAccountObjectReplacementMakesPreparedCommitStale() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let firstAccount = NSObject()
        let replacementAccount = NSObject()
        var epoch = LastChatsChatNavigationAccountEpoch(
            accountIdentifier: ObjectIdentifier(firstAccount),
            isEnabled: true
        )
        let presentation = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.chatNavigationAccountEpochResolver = { _ in epoch }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertTrue(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            navigationSource: .standard
        ))
        epoch = LastChatsChatNavigationAccountEpoch(
            accountIdentifier: ObjectIdentifier(replacementAccount),
            isEnabled: true
        )
        XCTAssertFalse(presentation.commitAttempt(at: 0, in: host.splitViewController))
    }

    @MainActor
    func testExpandedSplitReenabledAndRecreatedAccountEpochsRequireFreshValidWakeup() throws {
        for recreatesAccount in [false, true] {
            let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
            let firstAccount = NSObject()
            let nextAccount = recreatesAccount ? NSObject() : firstAccount
            var epoch = LastChatsChatNavigationAccountEpoch(
                accountIdentifier: ObjectIdentifier(firstAccount),
                isPresent: true,
                isEnabled: true
            )
            let presentation = ExpandedSplitChatPresentationProbe()
            let effects = LastChatsChatOpenIntentSideEffectProbe()
            host.controller.chatNavigationRouteResolver = { _ in
                .splitDetailReplacement
            }
            host.controller.chatNavigationAccountEpochResolver = { _ in epoch }
            host.controller.expandedSplitChatPresentationHandler =
                presentation.present
            host.controller.expandedSplitPreparedChatPresentationHandler =
                presentation.present
            host.controller.chatOpenIntentDeliveryHandler = effects.deliver
            let request = makeExactNotificationRequest(
                target: mercutio,
                archivedId: recreatesAccount
                    ? "account-recreated"
                    : "account-reenabled"
            )

            XCTAssertFalse(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ))
            epoch = LastChatsChatNavigationAccountEpoch(
                accountIdentifier: recreatesAccount
                    ? ObjectIdentifier(nextAccount)
                    : ObjectIdentifier(firstAccount),
                isPresent: true,
                isEnabled: recreatesAccount
            )
            XCTAssertFalse(
                presentation.commitAttempt(at: 0, in: host.splitViewController)
            )
            XCTAssertEqual(
                host.controller.expandedSplitChatNavigationTransaction?.phase,
                .waitingForEligibility
            )
            XCTAssertFalse(host.controller.stackNewChat(
                owner: mercutio.owner,
                jid: mercutio.jid,
                conversationType: mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            ))
            XCTAssertEqual(
                presentation.attempts.count,
                recreatesAccount ? 2 : 1
            )

            if !recreatesAccount {
                epoch = LastChatsChatNavigationAccountEpoch(
                    accountIdentifier: ObjectIdentifier(firstAccount),
                    isPresent: true,
                    isEnabled: true
                )
                XCTAssertFalse(host.controller.stackNewChat(
                    owner: mercutio.owner,
                    jid: mercutio.jid,
                    conversationType: mercutio.conversationType,
                    openMessageRequest: request,
                    navigationSource: .notification
                ))
            }
            XCTAssertEqual(presentation.attempts.count, 2)
            XCTAssertTrue(
                presentation.commitAttempt(at: 1, in: host.splitViewController)
            )
            XCTAssertEqual(effects.deliveryCount(for: request), 1)
            releaseForegroundExpandedSplitHost(host)
        }
    }

    @MainActor
    func testMissingAccountMaterializationWakeDuringExpandedSplitPreparationCommitsOnce() throws {
        let materializedAccount = NSObject()
        try assertValidAccountWakeDuringExpandedSplitPreparation(
            initialEpoch: .init(
                accountIdentifier: nil,
                isPresent: false,
                isEnabled: false
            ),
            wakeEpoch: .init(
                accountIdentifier: ObjectIdentifier(materializedAccount),
                isPresent: true,
                isEnabled: true
            ),
            requestIdentifier: "preparing-missing-materialized"
        )
    }

    @MainActor
    func testDisabledAccountEnableWakeDuringExpandedSplitPreparationCommitsOnce() throws {
        let account = NSObject()
        try assertValidAccountWakeDuringExpandedSplitPreparation(
            initialEpoch: .init(
                accountIdentifier: ObjectIdentifier(account),
                isPresent: true,
                isEnabled: false
            ),
            wakeEpoch: .init(
                accountIdentifier: ObjectIdentifier(account),
                isPresent: true,
                isEnabled: true
            ),
            requestIdentifier: "preparing-disabled-enabled"
        )
    }

    @MainActor
    func testRecreatedAccountWakeDuringExpandedSplitPreparationCommitsOnce() throws {
        let capturedAccount = NSObject()
        let recreatedAccount = NSObject()
        try assertValidAccountWakeDuringExpandedSplitPreparation(
            initialEpoch: .init(
                accountIdentifier: ObjectIdentifier(capturedAccount),
                isPresent: true,
                isEnabled: true
            ),
            wakeEpoch: .init(
                accountIdentifier: ObjectIdentifier(recreatedAccount),
                isPresent: true,
                isEnabled: true
            ),
            requestIdentifier: "preparing-account-recreated"
        )
    }

    @MainActor
    func testUnobservedAccountReplacementAfterPreparationWakeCannotCommitOrAcknowledge() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let capturedAccount = NSObject()
        let observedAccount = NSObject()
        let unobservedReplacement = NSObject()
        var epoch = LastChatsChatNavigationAccountEpoch(
            accountIdentifier: ObjectIdentifier(capturedAccount),
            isPresent: true,
            isEnabled: true
        )
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var scheduled: [() -> Void] = []
        var stableAcknowledgementCount = 0
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "unobserved-account-after-wake"
        )
        host.controller.chatNavigationAccountEpochResolver = { _ in epoch }
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        epoch = .init(
            accountIdentifier: ObjectIdentifier(observedAccount),
            isPresent: true,
            isEnabled: true
        )
        host.controller.retryPendingMessageNotificationRouteOnLifecycleStability()
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.accountEpoch,
            epoch
        )

        epoch = .init(
            accountIdentifier: ObjectIdentifier(unobservedReplacement),
            isPresent: true,
            isEnabled: true
        )
        controlledDestination.releaseNextPreparation()

        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === host.detailNavigationController
        )
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(stableAcknowledgementCount, 0)
        XCTAssertTrue(scheduled.isEmpty)
    }

    @MainActor
    func testInactiveUnsubscribedActivationTransactionObservesActualAccountMaterializationDuringPreparation() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousConnectingUsers = AccountManager.shared.connectingUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let owner = "registry-materialization-\(UUID().uuidString)@example.com"
        let target = LastChatsNavigationSingleFlightCoordinator.Target(
            owner: owner,
            jid: "retained-chat@example.com",
            conversationType: .regular
        )
        Realm.Configuration.defaultConfiguration = .init(
            inMemoryIdentifier: "RegistryMaterialization-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        defer {
            AccountManager.shared.users.removeAll()
            AccountManager.shared.users = previousUsers
            AccountManager.shared.activeUsers.accept(previousActiveUsers)
            AccountManager.shared.connectingUsers.accept(
                previousConnectingUsers
            )
            AccountManager.shared.authenticatedUsers.accept(
                previousAuthenticatedUsers
            )
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let realm = try WRealm.safe()
        try realm.write {
            let storedAccount = AccountStorageItem()
            storedAccount.jid = owner
            storedAccount.username = "registry-test"
            storedAccount.enabled = true
            realm.add(storedAccount, update: .modified)
        }
        XCTAssertNil(AccountManager.shared.find(for: owner))

        let host = try makeForegroundInactiveExpandedSplitActivationHost(
            currentTarget: romeo,
            installDefaultAccountEpochResolver: false
        )
        defer { releaseForegroundExpandedSplitHost(host) }
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var scheduled: [() -> Void] = []
        var stableAcknowledgementCount = 0
        let request = makeExactNotificationRequest(
            target: target,
            archivedId: "registry-materialization"
        )
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationTransitionRegistrar = {
            _, _ in false
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.leftMenu.openChatlistWithChat(
                owner: target.owner,
                jid: target.jid,
                conversationType: target.conversationType,
                openMessageRequest: request,
                navigationSource: .notification,
                configure: nil
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.leftMenu.openChatlistWithChat(
            owner: target.owner,
            jid: target.jid,
            conversationType: target.conversationType,
            openMessageRequest: request,
            navigationSource: .notification,
            configure: nil
        ))
        XCTAssertNil(
            host.controller.viewIfLoaded?.window,
            "the cached Last Chats controller must still be inactive and unsubscribed"
        )
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(scheduled.count, 0)

        AccountManager.shared.add(withJid: owner, autoConnect: false)
        XCTAssertNotNil(AccountManager.shared.find(for: owner))
        XCTAssertEqual(
            try WRealm.safe()
                .object(
                    ofType: AccountStorageItem.self,
                    forPrimaryKey: owner
                )?.enabled,
            true,
            "materialization must not require another Realm-row mutation"
        )
        AccountManager.shared.users = AccountManager.shared.users
        XCTAssertTrue(waitUntil {
            scheduled.count == 1
        }, "the real append signal plus a duplicate registry mutation coalesce")
        let materializationWake = try XCTUnwrap(scheduled.first)
        scheduled.removeFirst()
        materializationWake()
        XCTAssertTrue(
            host.controller.expandedSplitChatNavigationTransaction?
                .accountEpoch.isValidForChatNavigation == true
        )
        controlledDestination.releaseNextPreparation()
        XCTAssertTrue(waitUntil {
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            return (secondary as? UINavigationController)?
                .topViewController === controlledDestination &&
                host.controller.expandedSplitChatNavigationTransaction?.phase ==
                    .presented &&
                !scheduled.isEmpty
        })
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .presented
        )
        let scheduledAfterPresentation = scheduled.count
        AccountManager.shared.users = AccountManager.shared.users
        XCTAssertEqual(
            scheduled.count,
            scheduledAfterPresentation,
            "the registry observer must stop as soon as presentation succeeds"
        )
        simulateCommittedStableChatOpenPresentation(
            on: controlledDestination
        )
        let stablePresentationWake = try XCTUnwrap(scheduled.first)
        scheduled.removeFirst()
        stablePresentationWake()

        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
    }

    @MainActor
    func testInactiveActivationTransactionDoesNotAdoptDisabledAccountRegistryWake() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousConnectingUsers = AccountManager.shared.connectingUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let owner = "registry-disabled-\(UUID().uuidString)@example.com"
        let target = LastChatsNavigationSingleFlightCoordinator.Target(
            owner: owner,
            jid: "retained-disabled-chat@example.com",
            conversationType: .regular
        )
        Realm.Configuration.defaultConfiguration = .init(
            inMemoryIdentifier: "RegistryDisabled-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        defer {
            AccountManager.shared.users.removeAll()
            AccountManager.shared.users = previousUsers
            AccountManager.shared.activeUsers.accept(previousActiveUsers)
            AccountManager.shared.connectingUsers.accept(
                previousConnectingUsers
            )
            AccountManager.shared.authenticatedUsers.accept(
                previousAuthenticatedUsers
            )
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        let realm = try WRealm.safe()
        try realm.write {
            let storedAccount = AccountStorageItem()
            storedAccount.jid = owner
            storedAccount.username = "registry-disabled-test"
            storedAccount.enabled = false
            realm.add(storedAccount, update: .modified)
        }

        let host = try makeForegroundInactiveExpandedSplitActivationHost(
            currentTarget: romeo,
            installDefaultAccountEpochResolver: false
        )
        defer { releaseForegroundExpandedSplitHost(host) }
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var scheduled: [() -> Void] = []
        var stableAcknowledgementCount = 0
        let request = makeExactNotificationRequest(
            target: target,
            archivedId: "registry-disabled-materialization"
        )
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationTransitionRegistrar = {
            _, _ in false
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.leftMenu.openChatlistWithChat(
                owner: target.owner,
                jid: target.jid,
                conversationType: target.conversationType,
                openMessageRequest: request,
                navigationSource: .notification,
                configure: nil
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.leftMenu.openChatlistWithChat(
            owner: target.owner,
            jid: target.jid,
            conversationType: target.conversationType,
            openMessageRequest: request,
            navigationSource: .notification,
            configure: nil
        ))
        XCTAssertNil(host.controller.viewIfLoaded?.window)
        AccountManager.shared.add(withJid: owner, autoConnect: false)
        AccountManager.shared.users = AccountManager.shared.users
        XCTAssertTrue(waitUntil {
            scheduled.count == 1
        })
        scheduled.removeFirst()()
        XCTAssertFalse(
            host.controller.expandedSplitChatNavigationTransaction?
                .accountEpoch.isValidForChatNavigation == true
        )

        controlledDestination.releaseNextPreparation()

        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })
        XCTAssertTrue(
            host.splitViewController.viewController(for: .secondary)
                === host.detailNavigationController
        )
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertEqual(stableAcknowledgementCount, 0)
        XCTAssertTrue(scheduled.isEmpty)
    }

    @MainActor
    func testExpandedSplitAccountRegistryObserverStopsAfterResetAndDeinit() {
        let accountIdentity = NSObject()
        let epoch = LastChatsChatNavigationAccountEpoch(
            accountIdentifier: ObjectIdentifier(accountIdentity),
            isPresent: true,
            isEnabled: true
        )
        var resetSchedulerInvocationCount = 0
        let resetController = LastChatsViewController()
        let resetDestination = makeChat(for: mercutio)
        resetController.pendingMessageNotificationAsyncScheduler = { _ in
            resetSchedulerInvocationCount += 1
        }
        resetController.installExpandedSplitChatNavigationTransaction(
            token: UUID(),
            target: mercutio,
            destination: resetDestination,
            previousVisibleDetail: nil,
            previousSecondarySnapshot: .init(
                container: nil,
                topViewController: nil
            ),
            accountEpoch: epoch,
            navigationSource: .notification,
            activationContext: nil
        )
        resetController.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: false
        )
        AccountManager.shared.users = AccountManager.shared.users
        XCTAssertEqual(resetSchedulerInvocationCount, 0)

        var deinitSchedulerInvocationCount = 0
        weak var weakController: LastChatsViewController?
        autoreleasepool {
            var controller: LastChatsViewController? = LastChatsViewController()
            weakController = controller
            controller?.pendingMessageNotificationAsyncScheduler = { _ in
                deinitSchedulerInvocationCount += 1
            }
            controller?.installExpandedSplitChatNavigationTransaction(
                token: UUID(),
                target: mercutio,
                destination: makeChat(for: mercutio),
                previousVisibleDetail: nil,
                previousSecondarySnapshot: .init(
                    container: nil,
                    topViewController: nil
                ),
                accountEpoch: epoch,
                navigationSource: .notification,
                activationContext: nil
            )
            controller = nil
        }
        XCTAssertNil(weakController)
        AccountManager.shared.users = AccountManager.shared.users
        XCTAssertEqual(deinitSchedulerInvocationCount, 0)
    }

    @MainActor
    func testExpandedSplitDifferentOwnerEpochDoesNotInvalidatePreparedCommit() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let mercutioAccount = NSObject()
        let tybaltAccount = NSObject()
        let differentOwner = "benvolio@example.com"
        var epochs: [String: LastChatsChatNavigationAccountEpoch] = [
            mercutio.owner: .init(
                accountIdentifier: ObjectIdentifier(mercutioAccount),
                isEnabled: true
            ),
            differentOwner: .init(
                accountIdentifier: ObjectIdentifier(tybaltAccount),
                isEnabled: true
            )
        ]
        let presentation = ExpandedSplitChatPresentationProbe()
        host.controller.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        host.controller.chatNavigationAccountEpochResolver = {
            epochs[$0.owner] ?? .init(accountIdentifier: nil, isEnabled: false)
        }
        host.controller.expandedSplitChatPresentationHandler = presentation.present

        XCTAssertTrue(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            navigationSource: .standard
        ))
        epochs[differentOwner] = .init(accountIdentifier: nil, isEnabled: false)
        XCTAssertTrue(presentation.commitAttempt(at: 0, in: host.splitViewController))
    }

    @MainActor
    func testRevealTransitionGuardRejectionRetriesOnceOnCompletionAndAcknowledgesWhenStable() {
        let controller = LastChatsViewController()
        let transitionOwner = UIViewController()
        var transitionCompletion: ((Bool) -> Void)?
        var scheduled: [() -> Void] = []
        var retryCount = 0
        controller.pendingMessageNotificationTransitionRegistrar = { _, completion in
            transitionCompletion = completion
            return true
        }
        controller.pendingMessageNotificationAsyncScheduler = { scheduled.append($0) }
        controller.pendingMessageNotificationRouteRetryHandler = {
            retryCount += 1
            return true
        }

        controller.schedulePendingMessageNotificationRouteRetry(after: transitionOwner)
        controller.schedulePendingMessageNotificationRouteRetry(after: transitionOwner)
        XCTAssertEqual(retryCount, 0)
        transitionCompletion?(false)
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(retryCount, 1)
        XCTAssertFalse(controller.isPendingMessageNotificationRetryScheduled)
    }

    @MainActor
    func testCancelledTransitionPreservesAndRearmsPendingNotificationRetry() {
        let controller = LastChatsViewController()
        let transitionOwner = UIViewController()
        var completion: ((Bool) -> Void)?
        var scheduled: [() -> Void] = []
        var retryCount = 0
        var transitionIsActive = true
        controller.pendingMessageNotificationTransitionRegistrar = { _, callback in
            guard transitionIsActive else {
                return false
            }
            completion = callback
            return true
        }
        controller.pendingMessageNotificationAsyncScheduler = { scheduled.append($0) }
        controller.pendingMessageNotificationRouteRetryHandler = {
            retryCount += 1
            return retryCount == 2
        }

        controller.schedulePendingMessageNotificationRouteRetry(after: transitionOwner)
        completion?(true)
        scheduled.removeFirst()()
        XCTAssertEqual(retryCount, 1)
        transitionIsActive = false
        controller.retryPendingMessageNotificationRouteOnLifecycleStability()
        scheduled.removeFirst()()
        XCTAssertEqual(retryCount, 2)
    }

    @MainActor
    func testRetryObservingAnotherActiveTransitionReregistersExactlyOnce() {
        let controller = LastChatsViewController()
        let transitionOwner = UIViewController()
        var completions: [(Bool) -> Void] = []
        var scheduled: [() -> Void] = []
        var retryCount = 0
        controller.pendingMessageNotificationTransitionRegistrar = { _, completion in
            completions.append(completion)
            return true
        }
        controller.pendingMessageNotificationAsyncScheduler = { scheduled.append($0) }
        controller.pendingMessageNotificationRouteRetryHandler = {
            retryCount += 1
            if retryCount == 1 {
                controller.schedulePendingMessageNotificationRouteRetry(
                    after: transitionOwner
                )
                return false
            }
            return true
        }

        controller.schedulePendingMessageNotificationRouteRetry(after: transitionOwner)
        XCTAssertEqual(completions.count, 1)
        completions[0](false)
        scheduled.removeFirst()()
        XCTAssertEqual(completions.count, 2)
        completions[1](false)
        scheduled.removeFirst()()
        XCTAssertEqual(retryCount, 2)
        XCTAssertEqual(completions.count, 2)
    }

    @MainActor
    func testExpandedSplitNotificationReregistersFromTransitionAToBWithoutPreparingOrDeliveringTwice() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        let transitionA = UIViewController()
        let transitionB = UIViewController()
        var activeTransitionOwner: UIViewController? = transitionA
        var transitionCompletions:
            [ObjectIdentifier: [(Bool) -> Void]] = [:]
        var transitionRegistrationCounts: [ObjectIdentifier: Int] = [:]
        var scheduled: [() -> Void] = []
        var presentationAttempts: [Bool] = []
        var retryDispatchCount = 0
        var stableAcknowledgementCount = 0
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "transition-a-to-b"
        )
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.expandedSplitTransitionOwnerOverride = { _ in
            activeTransitionOwner
        }
        host.controller.expandedSplitPresentationAttemptObserver = {
            _, destinationWasAlreadyPrepared in
            presentationAttempts.append(destinationWasAlreadyPrepared)
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationTransitionRegistrar = {
            owner,
            completion in
            guard owner === transitionA || owner === transitionB else {
                return false
            }
            let identifier = ObjectIdentifier(owner)
            transitionRegistrationCounts[identifier, default: 0] += 1
            transitionCompletions[identifier, default: []].append(completion)
            return true
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            retryDispatchCount += 1
            let accepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        controlledDestination.releaseNextPreparation()
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .waitingForEligibility
        )
        XCTAssertEqual(
            transitionRegistrationCounts[ObjectIdentifier(transitionA)],
            1
        )
        XCTAssertEqual(presentationAttempts, [false])
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)

        activeTransitionOwner = transitionB
        let transitionACompletion = try XCTUnwrap(
            transitionCompletions[ObjectIdentifier(transitionA)]?.first
        )
        transitionACompletion(false)
        transitionACompletion(false)
        XCTAssertEqual(scheduled.count, 2)
        scheduled.removeFirst()()

        XCTAssertEqual(
            transitionRegistrationCounts[ObjectIdentifier(transitionB)],
            1,
            "A completion must register once on the current B epoch even though the Boolean fingerprint is unchanged"
        )
        XCTAssertEqual(presentationAttempts, [false])
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        XCTAssertEqual(
            transitionRegistrationCounts[ObjectIdentifier(transitionB)],
            1
        )
        scheduled.removeFirst()()

        activeTransitionOwner = nil
        let transitionBCompletion = try XCTUnwrap(
            transitionCompletions[ObjectIdentifier(transitionB)]?.first
        )
        transitionBCompletion(false)
        transitionBCompletion(false)
        XCTAssertEqual(scheduled.count, 2)
        scheduled.removeFirst()()
        scheduled.removeFirst()()

        XCTAssertTrue(waitUntil {
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            return (secondary as? UINavigationController)?
                .topViewController === controlledDestination &&
                !scheduled.isEmpty
        })
        XCTAssertEqual(presentationAttempts, [false, true])
        XCTAssertEqual(controlledDestination.preparationCount, 1)
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        simulateCommittedStableChatOpenPresentation(
            on: controlledDestination
        )
        scheduled.removeFirst()()

        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertGreaterThanOrEqual(retryDispatchCount, 3)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
        XCTAssertEqual(
            transitionRegistrationCounts[ObjectIdentifier(transitionB)],
            1
        )
        effects.assertEveryAnchorSideEffectExecutedOnce()
    }

    @MainActor
    func testEveryNotificationTransitionRegistrationCallSiteFallsBackToOneCoalescedAsyncWakeup() throws {
        let controller = LastChatsViewController()
        let transitionOwner = UIViewController()
        var registrationAttemptCount = 0
        var scheduled: [() -> Void] = []
        var retryDispatchCount = 0
        controller.pendingMessageNotificationTransitionRegistrar = {
            _, _ in
            registrationAttemptCount += 1
            return false
        }
        controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        controller.pendingMessageNotificationRouteRetryHandler = {
            retryDispatchCount += 1
            return false
        }

        for _ in 0..<5 {
            controller.schedulePendingMessageNotificationRouteRetryOrEnqueue(
                after: transitionOwner
            )
        }

        XCTAssertEqual(registrationAttemptCount, 1)
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(retryDispatchCount, 1)
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertFalse(controller.isPendingMessageNotificationRetryScheduled)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delegateSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDelegate.swift"
            ),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController.swift"
            ),
            encoding: .utf8
        )
        let rawRegistrarName =
            "schedulePendingMessageNotificationRouteRetry("
        let fallbackHelperName =
            "schedulePendingMessageNotificationRouteRetryOrEnqueue("
        XCTAssertEqual(
            delegateSource.components(separatedBy: rawRegistrarName).count - 1,
            0,
            "every delegate call-site family must preserve a registrar-false fallback"
        )
        XCTAssertEqual(
            controllerSource.components(separatedBy: rawRegistrarName).count - 1,
            2,
            "the raw registrar remains only at its definition and inside the fallback helper"
        )
        XCTAssertEqual(
            delegateSource.components(separatedBy: fallbackHelperName).count - 1,
            6,
            "five existing deferral families plus the consecutive-transition branch use the helper"
        )
        XCTAssertEqual(
            controllerSource.components(separatedBy: fallbackHelperName).count - 1,
            3,
            "both presentation completions plus the helper definition are covered"
        )
    }

    func testAccountManagerSnapshotStorageSignalsAfterUnlockedVisibleMutationsOnly() {
        var observedSnapshots: [[Int]] = []
        var storage: AccountManagerSnapshotStorage<Int>!
        storage = AccountManagerSnapshotStorage(didMutate: {
            observedSnapshots.append(storage.snapshot())
        })

        storage.append(1)
        storage.replace(with: [1, 2])
        XCTAssertEqual(storage.removeFirst(where: { $0 == 1 }), 1)
        XCTAssertNil(storage.removeFirst(where: { $0 == 99 }))

        XCTAssertEqual(observedSnapshots, [[1], [1, 2], [2]])
    }

    func testAccountManagerRegistryMutationSignalIsPayloadlessAndDeliveredOnMain() {
        let center = NotificationCenter()
        let delivered = expectation(
            description: "privacy-safe account registry mutation"
        )
        let observer = center.addObserver(
            forName: AccountManagerRegistryMutationSignal.notification,
            object: nil,
            queue: nil
        ) { notification in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(notification.object)
            XCTAssertNil(notification.userInfo)
            delivered.fulfill()
        }
        defer { center.removeObserver(observer) }

        DispatchQueue.global(qos: .userInitiated).async {
            AccountManagerRegistryMutationSignal.publish(center: center)
        }

        wait(for: [delivered], timeout: 1)
    }

    @MainActor
    func testExpandedSplitCollapseDuringPreparationRetriesThroughCurrentCompactRouteOnce() throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        var route: StackedNavigationRoute = .splitDetailReplacement
        var retryCount = 0
        var stableAcknowledgementCount = 0
        var scheduled: [() -> Void] = []
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: "collapse-recovery"
        )
        host.controller.chatNavigationRouteResolver = { _ in route }
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            retryCount += 1
            let accepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ))
        let preparedDestination = try XCTUnwrap(
            host.controller.expandedSplitChatNavigationTransaction?.destination
        )
        route = .currentNavigationPush
        let listNavigationController = try XCTUnwrap(
            host.controller.navigationController
        )
        host.splitViewController.setViewController(nil, for: .supplementary)
        host.window.rootViewController = listNavigationController
        host.window.makeKeyAndVisible()
        listNavigationController.view.layoutIfNeeded()
        controlledDestination.releaseNextPreparation()
        XCTAssertTrue(waitUntil {
            host.controller.expandedSplitChatNavigationTransaction?.phase ==
                .waitingForEligibility
        })

        host.controller.retryPendingMessageNotificationRouteOnLifecycleStability()
        XCTAssertEqual(scheduled.count, 1)
        let collapseRecoveryWake = try XCTUnwrap(scheduled.first)
        scheduled.removeFirst()
        collapseRecoveryWake()
        XCTAssertTrue(waitUntil(timeout: 2) {
            listNavigationController.topViewController === preparedDestination &&
                host.controller.chatNavigationSingleFlight.state?.phase ==
                    .presented &&
                !scheduled.isEmpty
        })
        simulateCommittedStableChatOpenPresentation(
            on: preparedDestination
        )
        let stablePresentationWake = try XCTUnwrap(scheduled.first)
        scheduled.removeFirst()
        stablePresentationWake()
        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertGreaterThanOrEqual(retryCount, 1)
        XCTAssertEqual(stableAcknowledgementCount, 1)
        XCTAssertTrue(
            listNavigationController.topViewController === preparedDestination
        )
        XCTAssertEqual(effects.deliveryCount(for: request), 1)
        XCTAssertNil(host.controller.expandedSplitChatNavigationTransaction)
    }

    @MainActor
    func testDetachedSplitRootAndLastChatsDeallocateAfterNavigationCancellation() {
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer { NotifyManager.shared.leftMenuDelegate = previousDelegate }
        weak var weakLeftMenu: LeftMenuViewController?
        weak var weakLastChats: LastChatsViewController?

        autoreleasepool {
            var leftMenu: LeftMenuViewController? = LeftMenuViewController()
            var lastChats: LastChatsViewController? = LastChatsViewController()
            leftMenu?.chatsVc = lastChats
            lastChats?.leftMenuSelectRootCategoryDelegate = leftMenu
            NotifyManager.shared.leftMenuDelegate = leftMenu
            if let lastChats {
                let destination = makeChat(for: mercutio)
                let token = UUID()
                lastChats.installExpandedSplitChatNavigationTransaction(
                    token: token,
                    target: mercutio,
                    destination: destination,
                    previousVisibleDetail: nil,
                    previousSecondarySnapshot: .init(
                        container: nil,
                        topViewController: nil
                    ),
                    accountEpoch: .init(
                        accountIdentifier: nil,
                        isPresent: false,
                        isEnabled: false
                    ),
                    navigationSource: .notification,
                    activationContext: nil
                )
                _ = lastChats.registerExpandedSplitChatNavigationPreparation(
                    StackedNavigationPresentationPreparationHandle(
                        cancellation: {},
                        completion: {}
                    ),
                    token: token
                )
            }
            lastChats?.resetChatNavigationTransaction(cancelled: true)
            lastChats?.resetExpandedSplitChatNavigationTransaction(
                restorePreviousDetail: false
            )
            weakLeftMenu = leftMenu
            weakLastChats = lastChats
            leftMenu = nil
            lastChats = nil
        }

        XCTAssertNil(weakLeftMenu)
        XCTAssertNil(weakLastChats)
    }

    private func makeExactNotificationRequest(
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        archivedId: String,
        source: ChatOpenMessageRequestSource = .pushNotification
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: target.jid,
            owner: target.owner,
            conversationType: target.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: "message-\(archivedId)",
                authorId: "sender@example.com",
                bodyFingerprint: "body-\(archivedId)",
                sourceDate: Date(timeIntervalSince1970: 1_711_283_200)
            ),
            highlight: true,
            markReadOnVisible: true,
            source: source
        )
    }

    private func makeImplicitOpenRequest(
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        source: ChatOpenMessageRequestSource
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: target.jid,
            owner: target.owner,
            conversationType: target.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: source == .savedVisiblePosition ? "saved-primary" : nil,
                archivedId: source == .savedVisiblePosition
                    ? "saved-archive"
                    : "unread-boundary",
                messageId: source == .savedVisiblePosition ? "saved-message" : nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: Date(timeIntervalSince1970: 1_711_283_200)
            ),
            highlight: false,
            markReadOnVisible: false,
            source: source,
            targetResolution: source == .initialUnreadBoundary
                ? .firstIncomingAfterBoundary("unread-boundary")
                : .anchor
        )
    }

    @MainActor
    private func makeChat(
        for target: LastChatsNavigationSingleFlightCoordinator.Target
    ) -> ChatViewController {
        let chat = ChatViewController()
        chat.owner = target.owner
        chat.jid = target.jid
        chat.conversationType = target.conversationType
        return chat
    }

    @MainActor
    private func assertValidAccountWakeDuringExpandedSplitPreparation(
        initialEpoch: LastChatsChatNavigationAccountEpoch,
        wakeEpoch: LastChatsChatNavigationAccountEpoch,
        requestIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = try makeForegroundExpandedSplitHost(currentTarget: romeo)
        defer { releaseForegroundExpandedSplitHost(host) }
        var epoch = initialEpoch
        let controlledDestination =
            ControlledExpandedSplitChatViewController()
        let effects = LastChatsChatOpenIntentSideEffectProbe()
        var scheduled: [() -> Void] = []
        var stableAcknowledgementCount = 0
        let request = makeExactNotificationRequest(
            target: mercutio,
            archivedId: requestIdentifier
        )
        host.controller.chatNavigationAccountEpochResolver = { _ in epoch }
        host.controller.expandedSplitChatDestinationFactory = {
            controlledDestination
        }
        host.controller.chatOpenIntentDeliveryHandler = effects.deliver
        host.controller.pendingMessageNotificationAsyncScheduler = {
            scheduled.append($0)
        }
        host.controller.pendingMessageNotificationTransitionRegistrar = {
            _, _ in false
        }
        host.controller.pendingMessageNotificationRouteRetryHandler = {
            let accepted = host.controller.stackNewChat(
                owner: self.mercutio.owner,
                jid: self.mercutio.jid,
                conversationType: self.mercutio.conversationType,
                openMessageRequest: request,
                navigationSource: .notification
            )
            if accepted {
                stableAcknowledgementCount += 1
            }
            return accepted
        }

        XCTAssertFalse(host.controller.stackNewChat(
            owner: mercutio.owner,
            jid: mercutio.jid,
            conversationType: mercutio.conversationType,
            openMessageRequest: request,
            navigationSource: .notification
        ), file: file, line: line)
        let retainedDestination = try XCTUnwrap(
            host.controller.expandedSplitChatNavigationTransaction?.destination,
            file: file,
            line: line
        )
        XCTAssertTrue(
            retainedDestination === controlledDestination,
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .preparing,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controlledDestination.preparationCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            effects.deliveryCount(for: request),
            1,
            file: file,
            line: line
        )

        epoch = wakeEpoch
        host.controller.retryPendingMessageNotificationRouteOnLifecycleStability()
        host.controller.retryPendingMessageNotificationRouteOnLifecycleStability()
        XCTAssertEqual(scheduled.count, 1, file: file, line: line)
        let accountWake = try XCTUnwrap(
            scheduled.first,
            file: file,
            line: line
        )
        scheduled.removeFirst()
        accountWake()

        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.accountEpoch,
            wakeEpoch,
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.controller.expandedSplitChatNavigationTransaction?.phase,
            .preparing,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controlledDestination.preparationCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            effects.deliveryCount(for: request),
            1,
            file: file,
            line: line
        )

        controlledDestination.releaseNextPreparation()
        XCTAssertTrue(waitUntil {
            let secondary = host.splitViewController.viewController(
                for: .secondary
            )
            return (secondary as? UINavigationController)?
                .topViewController === retainedDestination &&
                host.controller.expandedSplitChatNavigationTransaction?.phase ==
                    .presented &&
                !scheduled.isEmpty
        }, file: file, line: line)
        simulateCommittedStableChatOpenPresentation(
            on: retainedDestination,
            file: file,
            line: line
        )
        let stablePresentationWake = try XCTUnwrap(
            scheduled.first,
            file: file,
            line: line
        )
        scheduled.removeFirst()
        stablePresentationWake()

        XCTAssertEqual(stableAcknowledgementCount, 1, file: file, line: line)
        XCTAssertNil(
            host.controller.expandedSplitChatNavigationTransaction,
            file: file,
            line: line
        )
        XCTAssertTrue(
            host.controller.currentChatVC === retainedDestination,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controlledDestination.preparationCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            effects.deliveryCount(for: request),
            1,
            file: file,
            line: line
        )
        effects.assertEveryAnchorSideEffectExecutedOnce(
            file: file,
            line: line
        )
    }

    private func ownedOpenMessageRequest(
        in chat: ChatViewController
    ) -> ChatOpenMessageRequest? {
        chat.pendingOpenMessageRequest ?? chat.activeAnchorExecutionState?.request
    }

    private struct ForegroundNavigationHost {
        let window: UIWindow
        let navigationController: UINavigationController
        let previousKeyWindow: UIWindow?
    }

    private struct ForegroundExpandedSplitHost {
        let window: UIWindow
        let splitViewController: UISplitViewController
        let leftMenu: LeftMenuViewController
        let controller: LastChatsViewController
        let detailNavigationController: UINavigationController
        let currentChat: ChatViewController
        let previousKeyWindow: UIWindow?
    }

    @MainActor
    private func makeForegroundInactiveExpandedSplitActivationHost(
        currentTarget: LastChatsNavigationSingleFlightCoordinator.Target,
        installDefaultAccountEpochResolver: Bool = true
    ) throws -> ForegroundExpandedSplitHost {
        let windowScene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let controller = LastChatsViewController()
        let placeholderSupplementary = UINavigationController(
            rootViewController: UIViewController()
        )
        let currentChat = makeChat(for: currentTarget)
        let detailNavigationController = UINavigationController(
            rootViewController: currentChat
        )
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.preferredSplitBehavior = .tile
        splitViewController.preferredDisplayMode = .twoBesideSecondary
        let leftMenu = LeftMenuViewController()
        let accountIdentity = NSObject()
        leftMenu.chatsVc = controller
        leftMenu.chatNavigationRouteResolver = { _ in
            .splitDetailReplacement
        }
        controller.chatNavigationRouteResolver = { _ in
            .splitDetailReplacement
        }
        if installDefaultAccountEpochResolver {
            controller.chatNavigationAccountEpochResolver = { _ in
                LastChatsChatNavigationAccountEpoch(
                    accountIdentifier: ObjectIdentifier(accountIdentity),
                    isPresent: true,
                    isEnabled: true
                )
            }
        }
        splitViewController.setViewController(leftMenu, for: .primary)
        splitViewController.setViewController(
            placeholderSupplementary,
            for: .supplementary
        )
        splitViewController.setViewController(
            detailNavigationController,
            for: .secondary
        )
        controller.currentChatVC = currentChat
        controller.playerViewToolbar.delegate = currentChat
        let splitHost = ExpandedSplitFixtureViewController(
            splitViewController: splitViewController
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = splitHost
        window.makeKeyAndVisible()
        splitHost.loadViewIfNeeded()
        splitViewController.loadViewIfNeeded()
        currentChat.loadViewIfNeeded()
        UIView.performWithoutAnimation {
            splitViewController.show(.supplementary)
            splitHost.view.layoutIfNeeded()
            splitViewController.view.layoutIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertFalse(
            splitViewController.isCollapsed,
            "the expanded fixture must keep distinct supplementary and detail columns"
        )
        XCTAssertTrue(
            waitUntil {
                splitViewController.transitionCoordinator == nil &&
                    splitViewController
                        .viewController(for: .supplementary)?
                        .transitionCoordinator == nil &&
                    splitViewController
                        .viewController(for: .secondary)?
                        .transitionCoordinator == nil
            },
            "the expanded fixture must settle its initial UIKit transition epoch"
        )
        XCTAssertTrue(
            currentChat.viewIfLoaded?.window === window,
            "the existing detail must be attached in the expanded fixture"
        )
        XCTAssertFalse(
            controller.isViewLoaded,
            "the cached Last Chats activation target must begin unsubscribed"
        )
        controller.cancelPendingMessageNotificationRouteRetry()
        return ForegroundExpandedSplitHost(
            window: window,
            splitViewController: splitViewController,
            leftMenu: leftMenu,
            controller: controller,
            detailNavigationController: detailNavigationController,
            currentChat: currentChat,
            previousKeyWindow: previousKeyWindow
        )
    }

    @MainActor
    private func makeForegroundExpandedSplitHost(
        currentTarget: LastChatsNavigationSingleFlightCoordinator.Target,
        installDefaultAccountEpochResolver: Bool = true
    ) throws -> ForegroundExpandedSplitHost {
        let windowScene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let controller = LastChatsViewController()
        let listNavigationController = UINavigationController(rootViewController: controller)
        let currentChat = makeChat(for: currentTarget)
        let detailNavigationController = UINavigationController(rootViewController: currentChat)
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.preferredSplitBehavior = .tile
        splitViewController.preferredDisplayMode = .twoBesideSecondary
        let leftMenu = LeftMenuViewController()
        let accountIdentity = NSObject()
        leftMenu.chatsVc = controller
        leftMenu.chatNavigationRouteResolver = { _ in
            .splitDetailReplacement
        }
        controller.chatNavigationRouteResolver = { _ in
            .splitDetailReplacement
        }
        if installDefaultAccountEpochResolver {
            controller.chatNavigationAccountEpochResolver = { _ in
                LastChatsChatNavigationAccountEpoch(
                    accountIdentifier: ObjectIdentifier(accountIdentity),
                    isPresent: true,
                    isEnabled: true
                )
            }
        }
        splitViewController.setViewController(leftMenu, for: .primary)
        splitViewController.setViewController(listNavigationController, for: .supplementary)
        splitViewController.setViewController(detailNavigationController, for: .secondary)
        controller.currentChatVC = currentChat
        controller.playerViewToolbar.delegate = currentChat
        let splitHost = ExpandedSplitFixtureViewController(
            splitViewController: splitViewController
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = splitHost
        window.makeKeyAndVisible()
        splitHost.loadViewIfNeeded()
        splitViewController.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        currentChat.loadViewIfNeeded()
        UIView.performWithoutAnimation {
            splitViewController.show(.supplementary)
            splitHost.view.layoutIfNeeded()
            splitViewController.view.layoutIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertFalse(
            splitViewController.isCollapsed,
            "the expanded fixture must keep distinct supplementary and detail columns"
        )
        XCTAssertTrue(
            waitUntil {
                splitViewController.transitionCoordinator == nil &&
                    splitViewController
                        .viewController(for: .supplementary)?
                        .transitionCoordinator == nil &&
                    splitViewController
                        .viewController(for: .secondary)?
                        .transitionCoordinator == nil
            },
            "the expanded fixture must settle its initial UIKit transition epoch"
        )
        XCTAssertTrue(
            controller.viewIfLoaded?.window === window,
            "Last Chats must be attached as the expanded supplementary column"
        )
        XCTAssertTrue(
            currentChat.viewIfLoaded?.window === window,
            "the current chat must be attached as the expanded detail column"
        )
        // `viewDidAppear` legitimately asks the app route owner for a retry.
        // Tests install their own scheduler only after this helper returns, so
        // do not leak that fixture-setup wake into the scenario under test.
        controller.cancelPendingMessageNotificationRouteRetry()
        return ForegroundExpandedSplitHost(
            window: window,
            splitViewController: splitViewController,
            leftMenu: leftMenu,
            controller: controller,
            detailNavigationController: detailNavigationController,
            currentChat: currentChat,
            previousKeyWindow: previousKeyWindow
        )
    }

    @MainActor
    private func releaseForegroundExpandedSplitHost(_ host: ForegroundExpandedSplitHost) {
        host.controller.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: false
        )
        host.window.isHidden = true
        host.window.rootViewController = nil
        host.previousKeyWindow?.makeKey()
    }

    @MainActor
    private func makeForegroundNavigationHost<Root: UIViewController>(
        rootFactory: () -> Root
    ) throws -> (host: ForegroundNavigationHost, root: Root) {
        try makeForegroundNavigationHost(
            windowSceneProvider: { try requireHostedForegroundWindowScene() },
            rootFactory: rootFactory
        )
    }

    @MainActor
    private func makeForegroundNavigationHost<Root: UIViewController>(
        windowSceneProvider: () throws -> UIWindowScene,
        rootFactory: () -> Root
    ) throws -> (host: ForegroundNavigationHost, root: Root) {
        let windowScene = try windowSceneProvider()
        let root = rootFactory()
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let navigationController = UINavigationController(rootViewController: root)
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = navigationController
        navigationController.loadViewIfNeeded()
        navigationController.view.frame = window.bounds
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        navigationController.view.layoutIfNeeded()
        root.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return (
            host: ForegroundNavigationHost(
                window: window,
                navigationController: navigationController,
                previousKeyWindow: previousKeyWindow
            ),
            root: root
        )
    }

    @MainActor
    private func releaseForegroundNavigationHost(_ host: ForegroundNavigationHost) {
        if let transitionCoordinator = host.navigationController.transitionCoordinator {
            let transitionCompleted = expectation(
                description: "foreground navigation transition completes before host teardown"
            )
            let registered = transitionCoordinator.animate(
                alongsideTransition: nil,
                completion: { _ in
                    transitionCompleted.fulfill()
                }
            )
            XCTAssertTrue(
                registered,
                "an active navigation transition must accept a deterministic completion observer"
            )
            if !registered {
                transitionCompleted.fulfill()
            }
            wait(for: [transitionCompleted], timeout: 1)
        }
        XCTAssertNil(
            host.navigationController.transitionCoordinator,
            "the navigation transition must finish before its window is detached"
        )
        host.window.isHidden = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        host.window.rootViewController = nil
        host.previousKeyWindow?.makeKey()
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
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

    private func withInterfaceType<T>(
        _ interfaceType: CommonConfigManager.InterfaceType,
        perform body: () throws -> T
    ) rethrows -> T {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = interfaceType.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }
        return try body()
    }

}

private extension LastChatsNavigationSingleFlightCoordinator.RequestDecision {
    enum Phase {
        case started
        case coalesced
        case ignored
    }

    var phase: Phase {
        switch self {
        case .started:
            return .started
        case .coalesced:
            return .coalesced
        case .ignored:
            return .ignored
        }
    }
}

/// A phone-hosted UIWindow cannot be resized beyond its UIWindowScene geometry.
/// Containing the split lets the fixture model the production iPad hierarchy:
/// a regular-width, wide split whose supplementary and secondary columns are
/// attached to the same real foreground/key window.
private final class ExpandedSplitFixtureViewController: UIViewController {
    private static let splitLayoutFrame = CGRect(
        origin: .zero,
        size: CGSize(width: 1_200, height: 900)
    )

    private let hostedSplitViewController: UISplitViewController

    init(splitViewController: UISplitViewController) {
        hostedSplitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView(frame: Self.splitLayoutFrame)
        rootView.clipsToBounds = false
        view = rootView

        addChild(hostedSplitViewController)
        setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: .regular),
            forChild: hostedSplitViewController
        )
        hostedSplitViewController.loadViewIfNeeded()
        rootView.addSubview(hostedSplitViewController.view)
        hostedSplitViewController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hostedSplitViewController.view.frame = Self.splitLayoutFrame
        hostedSplitViewController.view.layoutIfNeeded()
    }
}

private struct NavigationReturnAppearanceSnapshot {
    let transitionCompletionDelivered: Bool
    let state: LastChatsNavigationSingleFlightCoordinator.State?
    let retainedDestination: ChatViewController?
    let retryCount: Int
}

private struct NavigationReturnDatasourceSectionIdentity: Equatable {
    let kind: LastChatsViewController.DatasourceSectionKind
    let rows: [String]
}

private final class NavigationAppearanceProbeLastChatsViewController:
    LastChatsViewController {
    var didAppearAfterSuper: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppearAfterSuper?()
    }
}

private final class InteractivePushCancellationDriver:
    NSObject,
    UINavigationControllerDelegate,
    UIViewControllerAnimatedTransitioning {
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

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard operation == .push, interactionController != nil else {
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

    func animateTransition(
        using transitionContext: UIViewControllerContextTransitioning
    ) {
        guard let fromController = transitionContext.viewController(forKey: .from),
              let toController = transitionContext.viewController(forKey: .to),
              let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            completedOutcomes.append(false)
            interactionController = nil
            return
        }

        let container = transitionContext.containerView
        let fromFrame = transitionContext.initialFrame(for: fromController)
        let toFrame = transitionContext.finalFrame(for: toController)
        toView.frame = toFrame.offsetBy(dx: container.bounds.width, dy: 0)
        container.addSubview(toView)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: [.curveLinear, .allowUserInteraction],
            animations: {
                fromView.frame = fromFrame.offsetBy(
                    dx: -0.3 * container.bounds.width,
                    dy: 0
                )
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

private final class NavigationPreparationDestinationProbe {
    private let cancellation: (() -> Void)?

    init(cancellation: (() -> Void)? = nil) {
        self.cancellation = cancellation
    }

    func cancelPreparation() {
        cancellation?()
    }
}

private final class ExpandedSplitChatPresentationProbe {
    struct Attempt {
        let destination: ChatViewController
        let commitPresentation: () -> Bool
        let completion: (Bool) -> Void
    }

    private(set) var attempts: [Attempt] = []
    private(set) var cancellationCount = 0
    private(set) var installCount = 0

    func present(
        destination: ChatViewController,
        presenter: UIViewController,
        commitPresentation: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) -> StackedNavigationPresentationPreparationHandle {
        attempts.append(Attempt(
            destination: destination,
            commitPresentation: commitPresentation,
            completion: completion
        ))
        return StackedNavigationPresentationPreparationHandle(
            cancellation: { [weak self] in
                self?.cancellationCount += 1
            },
            completion: {}
        )
    }

    @MainActor
    func installAttempt(
        at index: Int,
        in splitViewController: UISplitViewController
    ) -> Bool {
        let attempt = attempts[index]
        let didCommit = attempt.commitPresentation()
        if didCommit {
            let navigationController = UINavigationController(
                rootViewController: attempt.destination
            )
            UIView.performWithoutAnimation {
                splitViewController.setViewController(
                    navigationController,
                    for: .secondary
                )
                splitViewController.show(.secondary)
                splitViewController.view.layoutIfNeeded()
            }
            attempt.destination.loadViewIfNeeded()
            attempt.destination.view.layoutIfNeeded()
            installCount += 1
        }
        return didCommit
    }

    func completeAttempt(at index: Int, didPresent: Bool) {
        attempts[index].completion(didPresent)
    }

    @MainActor
    func commitAttempt(
        at index: Int,
        in splitViewController: UISplitViewController
    ) -> Bool {
        let didCommit = installAttempt(
            at: index,
            in: splitViewController
        )
        completeAttempt(at: index, didPresent: didCommit)
        return didCommit
    }
}

private final class SlowModalTransitioningDelegate: NSObject,
    UIViewControllerTransitioningDelegate {
    private let animator: SlowModalPresentationAnimator

    init(duration: TimeInterval) {
        animator = SlowModalPresentationAnimator(duration: duration)
        super.init()
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        animator
    }
}

private final class SlowModalPresentationAnimator: NSObject,
    UIViewControllerAnimatedTransitioning {
    private let duration: TimeInterval

    init(duration: TimeInterval) {
        self.duration = duration
        super.init()
    }

    func transitionDuration(
        using transitionContext: UIViewControllerContextTransitioning?
    ) -> TimeInterval {
        duration
    }

    func animateTransition(
        using transitionContext: UIViewControllerContextTransitioning
    ) {
        guard let destinationView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        destinationView.alpha = 0
        transitionContext.containerView.addSubview(destinationView)
        UIView.animate(
            withDuration: duration,
            animations: {
                destinationView.alpha = 1
            },
            completion: { _ in
                transitionContext.completeTransition(
                    !transitionContext.transitionWasCancelled
                )
            }
        )
    }
}

private final class LastChatsChatOpenIntentSideEffectProbe {
    private(set) var deliveredIntents: [LastChatsResolvedChatOpenIntent] = []
    private(set) var anchorPositioningCount = 0
    private(set) var highlightCount = 0
    private(set) var contextMAMDispatchCount = 0
    private(set) var datasourceApplyCount = 0
    private(set) var mentionReadVisibleSchedulingCount = 0

    func deliver(
        intent: LastChatsResolvedChatOpenIntent,
        destination: ChatViewController
    ) {
        deliveredIntents.append(intent)
        switch intent {
        case .message(let request):
            destination.pendingOpenMessageRequest = request
            anchorPositioningCount += 1
            highlightCount += 1
            contextMAMDispatchCount += 1
            datasourceApplyCount += 1
            mentionReadVisibleSchedulingCount += 1
        case .latest:
            destination.pendingForceLatestOpen = true
        }
    }

    func simulateExecutionCompletion(on destination: ChatViewController) {
        destination.pendingOpenMessageRequest = nil
        destination.activeAnchorExecutionState = nil
        simulateCommittedStableChatOpenPresentation(on: destination)
    }

    func deliveryCount(for request: ChatOpenMessageRequest) -> Int {
        deliveredIntents.lazy.filter { $0 == .message(request) }.count
    }

    func assertEveryAnchorSideEffectExecutedOnce(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(anchorPositioningCount, 1, file: file, line: line)
        XCTAssertEqual(highlightCount, 1, file: file, line: line)
        XCTAssertEqual(contextMAMDispatchCount, 1, file: file, line: line)
        XCTAssertEqual(datasourceApplyCount, 1, file: file, line: line)
        XCTAssertEqual(mentionReadVisibleSchedulingCount, 1, file: file, line: line)
    }
}

/// Navigation fixtures replace the real archive/presentation pipeline. The
/// hard cut no longer lets route acceptance or UIKit installation imply that
/// content is ready, so a test expecting semantic notification ACK must emit
/// the same terminal-receipt-plus-stable-frame proof that production emits.
private func simulateCommittedStableChatOpenPresentation(
    on destination: ChatViewController,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let context = destination.chatOpenPerformanceTraceContext,
          let semanticTarget =
            destination.chatOpenPerformanceTraceTargetFingerprint else {
        XCTFail(
            "the accepted exact intent must own a trace generation",
            file: file,
            line: line
        )
        return
    }
    if !destination.chatOpenPerformanceTraceLifecycle
        .hasCommittedTerminalPresentationReceipt(context: context) {
        XCTAssertTrue(
            destination.chatOpenPerformanceTraceLifecycle
                .recordPresentationReceipt(
                    .content,
                    context: context,
                    schedulesStableFrame: true
                ),
            file: file,
            line: line
        )
    }
    if !destination.chatOpenPerformanceTraceLifecycle
        .hasEmittedStableFrame(context: context) {
        XCTAssertTrue(
            destination.consumeChatOpenStableFrame(
                context: context,
                semanticTarget: semanticTarget,
                eligibility: .eligible
            ),
            file: file,
            line: line
        )
    }
}

private final class ControlledExpandedSplitChatViewController:
    ChatViewController,
    StackedNavigationPresentationPreparationControlling,
    StackedNavigationNativeTransitionCompletionRegistering {

    private let controlsNativeTransitionCompletion: Bool
    private var preparationHandles:
        [StackedNavigationPresentationPreparationHandle] = []
    private(set) var preparationCount = 0
    private(set) var preparationCancellationCount = 0
    private(set) var nativeTransitionCompletions: [(Bool) -> Void] = []

    init(controlsNativeTransitionCompletion: Bool = false) {
        self.controlsNativeTransitionCompletion =
            controlsNativeTransitionCompletion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func makeStackedNavigationPresentationPreparation(
        targetBounds: CGRect?,
        completion: @escaping () -> Void
    ) -> StackedNavigationPresentationPreparationHandle {
        preparationCount += 1
        loadViewIfNeeded()
        if let targetBounds,
           targetBounds.width > 0,
           targetBounds.height > 0 {
            view.frame = CGRect(origin: .zero, size: targetBounds.size)
        }
        let handle = StackedNavigationPresentationPreparationHandle(
            cancellation: { [weak self] in
                self?.preparationCancellationCount += 1
            },
            completion: completion
        )
        preparationHandles.append(handle)
        return handle
    }

    func releaseNextPreparation() {
        guard !preparationHandles.isEmpty else {
            XCTFail("expected one controlled expanded-split preparation")
            return
        }
        preparationHandles.removeFirst().finish()
    }

    func registerStackedNavigationNativeTransitionCompletion(
        transitionOwner: UIViewController?,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard controlsNativeTransitionCompletion else {
            return false
        }
        nativeTransitionCompletions.append { didComplete in
            transitionOwner?.viewIfLoaded?.layoutIfNeeded()
            completion(didComplete)
        }
        return true
    }

    func completeNativeTransition(
        at index: Int,
        didComplete: Bool
    ) {
        guard nativeTransitionCompletions.indices.contains(index) else {
            XCTFail("missing controlled native transition completion")
            return
        }
        nativeTransitionCompletions[index](didComplete)
    }
}

private final class StalledStackedNavigationPreparationViewController:
    UIViewController,
    AsyncStackedNavigationPresentationPreparing {

    private(set) var preparationCount = 0
    private(set) var preparationTimeoutCount = 0

    func prepareForStackedNavigationPresentation(
        targetBounds: CGRect?,
        completion: @escaping () -> Void
    ) {
        preparationCount += 1
        // Models first-frame work temporarily stuck behind teardown/persistence.
        // The missing callback must not strand the valid navigation transaction.
    }

    func stackedNavigationPresentationPreparationDidTimeOut() {
        preparationTimeoutCount += 1
    }
}

private func makeNavigationPreparationHandle(
    retaining destination: NavigationPreparationDestinationProbe
) -> StackedNavigationPresentationPreparationHandle {
    StackedNavigationPresentationPreparationHandle(
        cancellation: { [weak destination] in
            destination?.cancelPreparation()
        },
        completion: {
            _ = destination
        }
    )
}
