//
//  ChatSearchModeTransitionTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchModeTransitionTests: XCTestCase {
    func testSharedSpecDefinesSynchronizedChromeAndArrowTiming() throws {
        let spec = ChatSearchAnimationSpec.production
        let chromeScale = try XCTUnwrap(spec.chromeControls.scale)
        let chromeAlpha = try XCTUnwrap(spec.chromeControls.alpha)
        let arrowScale = try XCTUnwrap(spec.floatingButtons.scale)

        XCTAssertEqual(chromeScale.from, 0.01, accuracy: 0.0001)
        XCTAssertEqual(chromeScale.to, 1, accuracy: 0.0001)
        XCTAssertEqual(chromeAlpha.from, 0, accuracy: 0.0001)
        XCTAssertEqual(chromeAlpha.to, 1, accuracy: 0.0001)
        XCTAssertEqual(chromeScale.timing, chromeAlpha.timing)
        XCTAssertEqual(chromeScale.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(arrowScale.from, 0.2, accuracy: 0.0001)
        XCTAssertEqual(arrowScale.timing.duration, 0.30, accuracy: 0.0001)
    }

    func testChromePlanReversesInsertionEndpointsForRemoval() throws {
        let insertion = ChatSearchChromeTransitionPlan.make(
            finalState: .visible,
            generation: 7,
            animationSpec: .production,
            animated: true
        )
        let removal = ChatSearchChromeTransitionPlan.make(
            finalState: .hidden,
            generation: 7,
            animationSpec: .production,
            animated: true
        )

        XCTAssertEqual(try XCTUnwrap(insertion.transition.scale).from, 0.01)
        XCTAssertEqual(try XCTUnwrap(insertion.transition.scale).to, 1)
        XCTAssertEqual(try XCTUnwrap(removal.transition.scale).from, 1)
        XCTAssertEqual(try XCTUnwrap(removal.transition.scale).to, 0.01)
        XCTAssertEqual(try XCTUnwrap(removal.transition.alpha).from, 1)
        XCTAssertEqual(try XCTUnwrap(removal.transition.alpha).to, 0)
        XCTAssertEqual(insertion.maximumDuration, removal.maximumDuration, accuracy: 0.0001)
    }

    func testListCalendarAndMonthPlansRemainUnchanged() {
        let spec = ChatSearchAnimationSpec.production

        XCTAssertEqual(spec.list.presentation.scale?.timing.duration, 0.40)
        XCTAssertEqual(spec.list.presentation.blurRadius?.timing.duration, 0.20)
        XCTAssertEqual(spec.list.dismissal.scale?.timing.duration, 0.30)
        XCTAssertEqual(spec.calendar.sheetPresentation.verticalOffsetFraction?.timing.duration, 0.40)
        XCTAssertEqual(spec.calendar.sheetDismissal.verticalOffsetFraction?.timing.duration, 0.30)
        XCTAssertEqual(spec.monthSwipe.timing.duration, 0.30)
    }

    func testBottomCapsuleSpecUsesSpringGeometryAndReduceMotionAlphaOnly() {
        let production = ChatSearchAnimationSpec.production.bottomCapsule
        XCTAssertEqual(production.geometry.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(production.textAlpha.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(production.geometry.curve, production.textAlpha.curve)
        guard case .spring = production.geometry.curve else {
            return XCTFail("Normal capsule geometry must use an interruptible spring")
        }

        let reduced = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        ).bottomCapsule
        XCTAssertEqual(reduced.geometry.duration, 0, accuracy: 0.0001)
        XCTAssertEqual(reduced.textAlpha.duration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(reduced.textAlpha.curve, .easeOut)
    }

    func testProductionPanelKeepsUnresolvedMotionBaseAndRestoresSpringAfterReduceMotion() {
        let launchedReduced = ModernXabberInputView.SearchPanel.productionAnimationSpecs(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        XCTAssertEqual(launchedReduced.base, .production)
        XCTAssertTrue(launchedReduced.active.isReducedMotion)
        XCTAssertFalse(
            launchedReduced.base.resolved(
                for: .init(reduceMotion: false, reduceTransparency: false)
            ).isReducedMotion
        )

        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 0, y: 0, width: 358, height: 40),
            animationSpec: .production
        )
        panel.applyAdaptiveEnvironment(.standard.replacing(reduceMotion: true))
        XCTAssertTrue(panel.animationSpec.isReducedMotion)
        panel.applyAdaptiveEnvironment(.standard.replacing(reduceMotion: false))
        XCTAssertFalse(panel.animationSpec.isReducedMotion)
        XCTAssertEqual(panel.animationSpec.bottomCapsule.geometry.duration, 0.30, accuracy: 0.001)
    }

    func testReduceMotionUsesOnlyShortChromeFade() throws {
        let reduced = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let plan = ChatSearchChromeTransitionPlan.make(
            finalState: .visible,
            generation: 1,
            animationSpec: reduced,
            animated: true
        )

        XCTAssertNil(plan.transition.scale)
        XCTAssertEqual(try XCTUnwrap(plan.transition.alpha).timing.duration, 0.15)
        XCTAssertLessThanOrEqual(plan.maximumDuration, 0.20)
    }

    func testMotionMutationPolicyPreventsNestedNavigationFirstFrameAndInteractiveKeyboardAnimation() {
        XCTAssertTrue(
            ChatSearchMotionMutationPolicy.shouldAnimate(
                requestedAnimated: true,
                isNavigationTransitionActive: false,
                isPreparingFirstFrame: false,
                isInteractiveKeyboardUpdate: false
            )
        )
        XCTAssertFalse(
            ChatSearchMotionMutationPolicy.shouldAnimate(
                requestedAnimated: true,
                isNavigationTransitionActive: true,
                isPreparingFirstFrame: false,
                isInteractiveKeyboardUpdate: false
            )
        )
        XCTAssertFalse(
            ChatSearchMotionMutationPolicy.shouldAnimate(
                requestedAnimated: true,
                isNavigationTransitionActive: false,
                isPreparingFirstFrame: true,
                isInteractiveKeyboardUpdate: false
            )
        )
        XCTAssertFalse(
            ChatSearchMotionMutationPolicy.shouldAnimate(
                requestedAnimated: true,
                isNavigationTransitionActive: false,
                isPreparingFirstFrame: false,
                isInteractiveKeyboardUpdate: true
            )
        )
    }

    func testChromeCoordinatorAnimatesContentHostsWithoutChangingOwnedFrames() {
        let factory = ManualSearchMotionAnimatorFactory()
        let coordinator = ChatSearchChromeTransitionCoordinator(animatorFactory: factory)
        let host = MotionHost()
        let initialFrames = host.contentHosts.map(\.frame)
        var completions: [ChatSearchChromeTransitionPlan.FinalState] = []

        coordinator.transition(
            to: .visible,
            generation: 3,
            animated: true,
            animationSpec: .production,
            contentHosts: host.contentHosts,
            isGenerationCurrent: { $0 == 3 },
            completion: { completions.append($0) }
        )

        XCTAssertTrue(coordinator.isTransitioning)
        XCTAssertEqual(host.contentHosts.map(\.frame), initialFrames)
        XCTAssertTrue(host.contentHosts.allSatisfy { $0.transform == .identity && $0.alpha == 1 })

        factory.finishPending()

        XCTAssertFalse(coordinator.isTransitioning)
        XCTAssertEqual(coordinator.settledState, .visible)
        XCTAssertEqual(completions, [.visible])
        XCTAssertEqual(host.contentHosts.map(\.frame), initialFrames)
    }

    func testRapidReverseAndStaleCompletionSettleAtLatestReducerState() {
        let factory = ManualSearchMotionAnimatorFactory()
        let coordinator = ChatSearchChromeTransitionCoordinator(animatorFactory: factory)
        let host = MotionHost()
        var generation = 5
        var completions: [ChatSearchChromeTransitionPlan.FinalState] = []

        coordinator.transition(
            to: .visible,
            generation: 5,
            animated: true,
            animationSpec: .production,
            contentHosts: host.contentHosts,
            isGenerationCurrent: { $0 == generation },
            completion: { completions.append($0) }
        )
        generation = 6
        coordinator.transition(
            to: .hidden,
            generation: 6,
            animated: true,
            animationSpec: .production,
            contentHosts: host.contentHosts,
            isGenerationCurrent: { $0 == generation },
            completion: { completions.append($0) }
        )
        factory.finishAllIncludingStopped()

        XCTAssertEqual(coordinator.settledState, .hidden)
        XCTAssertEqual(completions, [.hidden])
        XCTAssertFalse(coordinator.isTransitioning)
        XCTAssertTrue(host.contentHosts.allSatisfy { $0.transform == .identity && $0.alpha == 1 })
    }

    func testCleanupAnimationsAppliesExplicitLifecycleFinalState() {
        let factory = ManualSearchMotionAnimatorFactory()
        let coordinator = ChatSearchChromeTransitionCoordinator(animatorFactory: factory)
        let host = MotionHost()

        coordinator.transition(
            to: .visible,
            generation: 9,
            animated: true,
            animationSpec: .production,
            contentHosts: host.contentHosts,
            isGenerationCurrent: { _ in true },
            completion: { _ in XCTFail("Interrupted transition must not complete") }
        )
        coordinator.cleanupAnimations(finalState: .hidden)

        XCTAssertEqual(coordinator.settledState, .hidden)
        XCTAssertFalse(coordinator.isTransitioning)
        XCTAssertTrue(factory.animators.allSatisfy(\.wasStopped))
        XCTAssertTrue(host.contentHosts.allSatisfy { $0.layer.animationKeys()?.isEmpty != false })
    }

    func testCoordinatorDoesNotRetainItselfThroughAnimatorCompletion() {
        let factory = ManualSearchMotionAnimatorFactory()
        let host = MotionHost()
        weak var weakCoordinator: ChatSearchChromeTransitionCoordinator?

        autoreleasepool {
            var coordinator: ChatSearchChromeTransitionCoordinator? = .init(animatorFactory: factory)
            weakCoordinator = coordinator
            coordinator?.transition(
                to: .visible,
                generation: 1,
                animated: true,
                animationSpec: .production,
                contentHosts: host.contentHosts,
                isGenerationCurrent: { _ in true },
                completion: { _ in }
            )
            coordinator = nil
        }

        XCTAssertNil(weakCoordinator)
        factory.finishAllIncludingStopped()
    }

    func testCounterUpdatesDoNotCreateIndependentMotionChannel() {
        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 0, y: 0, width: 358, height: 40),
            animationSpec: .production,
            localization: ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main)
        )
        panel.applyRenderState(
            .results(current: 0, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        panel.applyRenderState(
            .results(current: 1, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )

        XCTAssertEqual(panel.counterLabel.text, "2 of 3")
        XCTAssertNil(panel.counterLabel.layer.animationKeys())

        panel.applyRenderState(
            .results(current: 0, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )
        XCTAssertEqual(panel.counterLabel.text, "1 of 3")
        XCTAssertNil(panel.counterLabel.layer.animationKeys())
    }

    func testBottomCapsuleTransitionInterruptsRapidReversalAndDoesNotRestartForCountChanges() {
        let factory = ManualSearchMotionAnimatorFactory()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 16, y: 790, width: 358, height: 40),
            animationSpec: .production,
            localization: ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main),
            capsuleAnimatorFactory: factory
        )
        window.rootViewController = root
        root.view.addSubview(panel)
        window.makeKeyAndVisible()
        panel.layoutIfNeeded()

        panel.applyRenderState(
            .results(current: -1, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )
        XCTAssertEqual(factory.animators.count, 1)
        XCTAssertEqual(factory.animators[0].timing, ChatSearchAnimationSpec.production.bottomCapsule.geometry)
        XCTAssertTrue(panel.isCapsuleTransitioning)

        panel.applyRenderState(
            .results(current: 0, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )
        XCTAssertEqual(factory.animators.count, 1)
        XCTAssertEqual(panel.counterLabel.text, "1 of 3")

        panel.applyRenderState(.emptyResults, surfaceMode: .chat, animated: true)
        XCTAssertEqual(factory.animators.count, 2)
        XCTAssertTrue(factory.animators[0].wasStopped)
        panel.applyRenderState(
            .results(current: -1, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )
        XCTAssertEqual(factory.animators.count, 3)
        XCTAssertTrue(factory.animators[1].wasStopped)

        factory.finishAllIncludingStopped()

        XCTAssertFalse(panel.isCapsuleTransitioning)
        XCTAssertEqual(panel.capsuleTransitionCount, 3)
        XCTAssertEqual(panel.leadingSurfaceView.bounds.width, 144, accuracy: 0.001)
        XCTAssertEqual(panel.counterLabel.text, "3 messages")
        XCTAssertEqual(panel.counterLabel.alpha, 1, accuracy: 0.001)
        XCTAssertNil(panel.counterLabel.layer.animationKeys())
        window.isHidden = true
    }

    func testReduceMotionAppliesCapsuleGeometryImmediatelyAndAnimatesOnlyShortAlpha() {
        let reduced = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let factory = ManualSearchMotionAnimatorFactory()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 16, y: 790, width: 358, height: 40),
            animationSpec: reduced,
            localization: ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main),
            capsuleAnimatorFactory: factory
        )
        window.rootViewController = root
        root.view.addSubview(panel)
        window.makeKeyAndVisible()
        panel.layoutIfNeeded()
        XCTAssertEqual(panel.leadingSurfaceView.bounds.width, 40, accuracy: 0.001)

        panel.applyRenderState(
            .results(current: -1, total: 2, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )

        XCTAssertEqual(panel.leadingSurfaceView.bounds.width, 144, accuracy: 0.001)
        XCTAssertEqual(factory.animators.count, 1)
        XCTAssertEqual(factory.animators[0].timing, reduced.bottomCapsule.textAlpha)
        XCTAssertTrue(panel.isCapsuleTransitioning)
        factory.finishPending()
        XCTAssertFalse(panel.isCapsuleTransitioning)
        XCTAssertEqual(panel.counterLabel.alpha, 1, accuracy: 0.001)
        window.isHidden = true
    }

    func testNavigationFeedbackIsPreparedBeforeWorkAndEmittedOnlyAfterMatchingSuccess() {
        let generator = RecordingSearchNavigationFeedbackGenerator()
        let coordinator = ChatSearchNavigationFeedbackCoordinator(generator: generator)

        coordinator.prepare(expectedIndex: 2, generation: 11)
        XCTAssertEqual(generator.prepareCount, 1)
        XCTAssertEqual(generator.selectionCount, 0)
        XCTAssertFalse(coordinator.commitPositioned(index: 1, generation: 11))
        XCTAssertEqual(generator.selectionCount, 0)
        XCTAssertTrue(coordinator.commitPositioned(index: 2, generation: 11))
        XCTAssertEqual(generator.selectionCount, 1)
        XCTAssertFalse(coordinator.commitPositioned(index: 2, generation: 11))
        XCTAssertEqual(generator.selectionCount, 1)
    }

    func testNavigationFeedbackCancelFailureAndStaleGenerationNeverEmitSelection() {
        let generator = RecordingSearchNavigationFeedbackGenerator()
        let coordinator = ChatSearchNavigationFeedbackCoordinator(generator: generator)

        coordinator.prepare(expectedIndex: 3, generation: 20)
        coordinator.cancel()
        XCTAssertFalse(coordinator.commitPositioned(index: 3, generation: 20))

        coordinator.prepare(expectedIndex: 4, generation: 21)
        XCTAssertFalse(coordinator.commitPositioned(index: 4, generation: 22))
        coordinator.cancel(generation: 22)

        XCTAssertEqual(generator.prepareCount, 2)
        XCTAssertEqual(generator.selectionCount, 0)
    }
}

@MainActor
private final class MotionHost {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    let topField = UIView(frame: CGRect(x: 16, y: 6, width: 306, height: 44))
    let topClose = UIView(frame: CGRect(x: 330, y: 6, width: 44, height: 44))
    let bottomLeading = UIView(frame: CGRect(x: 16, y: 790, width: 144, height: 40))
    let bottomTrailing = UIView(frame: CGRect(x: 250, y: 790, width: 124, height: 40))

    var contentHosts: [UIView] {
        [topField, topClose, bottomLeading, bottomTrailing]
    }

    init() {
        window.rootViewController = root
        contentHosts.forEach(root.view.addSubview)
        window.makeKeyAndVisible()
    }
}

private final class ManualSearchMotionAnimatorFactory: ChatSearchModeAnimatorFactory {
    private(set) var animators: [ManualSearchMotionAnimator] = []

    func makeAnimator(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void
    ) -> ChatSearchModeAnimating {
        let animator = ManualSearchMotionAnimator(timing: timing, animations: animations)
        animators.append(animator)
        return animator
    }

    func finishPending() {
        animators.filter { !$0.wasStopped && !$0.didFinish }.forEach { $0.finish() }
    }

    func finishAllIncludingStopped() {
        animators.filter { !$0.didFinish }.forEach { $0.finish() }
    }
}

private final class ManualSearchMotionAnimator: ChatSearchModeAnimating {
    let timing: ChatSearchAnimationSpec.Timing
    private let animations: () -> Void
    private var completions: [(UIViewAnimatingPosition) -> Void] = []
    private(set) var wasStopped = false
    private(set) var didFinish = false

    init(timing: ChatSearchAnimationSpec.Timing, animations: @escaping () -> Void) {
        self.timing = timing
        self.animations = animations
    }

    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {
        completions.append(completion)
    }

    func startAnimation() {
        animations()
    }

    func stopAnimation(_ withoutFinishing: Bool) {
        wasStopped = true
    }

    func finishAnimation(at finalPosition: UIViewAnimatingPosition) {
        finish(position: finalPosition)
    }

    func finish() {
        finish(position: .end)
    }

    private func finish(position: UIViewAnimatingPosition) {
        guard !didFinish else { return }
        didFinish = true
        completions.forEach { $0(position) }
    }
}

private final class RecordingSearchNavigationFeedbackGenerator:
    ChatSearchNavigationFeedbackGenerating {
    private(set) var prepareCount = 0
    private(set) var selectionCount = 0

    func prepare() {
        prepareCount += 1
    }

    func selectionChanged() {
        selectionCount += 1
    }
}
