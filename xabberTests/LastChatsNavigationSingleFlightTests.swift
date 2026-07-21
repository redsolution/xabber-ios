//
//  LastChatsNavigationSingleFlightTests.swift
//  xabberTests
//

import UIKit
import XCTest
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

private final class NavigationPreparationDestinationProbe {
    private let cancellation: (() -> Void)?

    init(cancellation: (() -> Void)? = nil) {
        self.cancellation = cancellation
    }

    func cancelPreparation() {
        cancellation?()
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
