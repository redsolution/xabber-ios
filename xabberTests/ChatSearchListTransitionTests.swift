//
//  ChatSearchListTransitionTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchListTransitionTests: XCTestCase {
    func testPresentationPlanMatchesObservedScaleBlurAndStationaryRegions() throws {
        let plan = ChatSearchModeTransitionPlan.make(
            targetMode: .list,
            generation: 17,
            animationSpec: .production,
            animated: true
        )
        let scale = try XCTUnwrap(plan.contentTransition.scale)
        let blur = try XCTUnwrap(plan.contentTransition.blurRadius)

        XCTAssertEqual(plan.targetMode, .list)
        XCTAssertEqual(plan.generation, 17)
        XCTAssertEqual(scale.from, 0.95, accuracy: 0.0001)
        XCTAssertEqual(scale.to, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.timing.duration, 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            scale.timing.curve,
            .spring(.init(dampingRatio: 0.86, initialVelocity: 0.15))
        )
        XCTAssertEqual(blur.from, 30, accuracy: 0.0001)
        XCTAssertEqual(blur.to, 0, accuracy: 0.0001)
        XCTAssertEqual(blur.timing.duration, 0.20, accuracy: 0.0001)
        XCTAssertEqual(plan.maximumDuration, 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            plan.stationaryRegions,
            [.timeline, .topChrome, .bottomControls, .keyboard]
        )
        XCTAssertTrue(plan.animatesListContentOnly)
        XCTAssertFalse(plan.removesListAfterCompletion)
        XCTAssertEqual(plan.blurImplementation, .publicVisualEffect)
    }

    func testDismissalPlanHasNoSeparateAlphaPhaseAndRemovesListAfterCompletion() throws {
        let plan = ChatSearchModeTransitionPlan.make(
            targetMode: .chat,
            generation: 18,
            animationSpec: .production,
            animated: true
        )
        let scale = try XCTUnwrap(plan.contentTransition.scale)
        let blur = try XCTUnwrap(plan.contentTransition.blurRadius)

        XCTAssertEqual(scale.from, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.to, 0.95, accuracy: 0.0001)
        XCTAssertEqual(blur.from, 0, accuracy: 0.0001)
        XCTAssertEqual(blur.to, 30, accuracy: 0.0001)
        XCTAssertEqual(scale.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(blur.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertNil(plan.contentTransition.alpha)
        XCTAssertEqual(plan.maximumDuration, 0.30, accuracy: 0.0001)
        XCTAssertTrue(plan.removesListAfterCompletion)
    }

    func testReduceMotionPlanUsesOnlyShortCrossfade() throws {
        let spec = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let presentation = ChatSearchModeTransitionPlan.make(
            targetMode: .list,
            generation: 1,
            animationSpec: spec,
            animated: true
        )
        let dismissal = ChatSearchModeTransitionPlan.make(
            targetMode: .chat,
            generation: 1,
            animationSpec: spec,
            animated: true
        )

        XCTAssertNil(presentation.contentTransition.scale)
        XCTAssertNil(presentation.contentTransition.blurRadius)
        XCTAssertEqual(try XCTUnwrap(presentation.contentTransition.alpha).from, 0)
        XCTAssertLessThanOrEqual(presentation.maximumDuration, 0.20)
        XCTAssertNil(dismissal.contentTransition.scale)
        XCTAssertNil(dismissal.contentTransition.blurRadius)
        XCTAssertEqual(try XCTUnwrap(dismissal.contentTransition.alpha).to, 0)
        XCTAssertLessThanOrEqual(dismissal.maximumDuration, 0.20)
    }

    func testAnimatedFalsePreservesEndpointsWithImmediateFinalPlan() throws {
        let plan = ChatSearchModeTransitionPlan.make(
            targetMode: .list,
            generation: 2,
            animationSpec: .production,
            animated: false
        )

        XCTAssertFalse(plan.isAnimated)
        XCTAssertEqual(plan.maximumDuration, 0)
        XCTAssertEqual(try XCTUnwrap(plan.contentTransition.scale).from, 0.95)
        XCTAssertEqual(try XCTUnwrap(plan.contentTransition.scale).to, 1)
        XCTAssertEqual(try XCTUnwrap(plan.contentTransition.blurRadius).from, 30)
        XCTAssertEqual(try XCTUnwrap(plan.contentTransition.blurRadius).to, 0)
    }

    func testCoordinatorAppliesFinalHierarchyAndKeepsListUntilDismissalCompletes() {
        let factory = ManualModeAnimatorFactory()
        let coordinator = ChatSearchModeTransitionCoordinator(animatorFactory: factory)
        let host = TransitionHost()
        let recorder = ModeRecorder()

        transition(
            coordinator,
            host: host,
            to: .list,
            generation: 3,
            recorder: recorder
        )

        XCTAssertTrue(coordinator.isTransitioning)
        XCTAssertEqual(coordinator.activeOverlayCount, 1)
        XCTAssertFalse(host.list.isHidden)
        XCTAssertFalse(host.timeline.isHidden)
        XCTAssertFalse(host.timeline.isUserInteractionEnabled)
        XCTAssertEqual(factory.animators.count, 2)

        factory.finishPending()

        XCTAssertFalse(coordinator.isTransitioning)
        XCTAssertEqual(coordinator.settledMode, .list)
        XCTAssertEqual(coordinator.activeOverlayCount, 0)
        XCTAssertFalse(host.list.isHidden)
        XCTAssertEqual(host.list.alpha, 1, accuracy: 0.0001)
        XCTAssertTrue(host.timeline.isHidden)

        transition(
            coordinator,
            host: host,
            to: .chat,
            generation: 3,
            recorder: recorder
        )

        XCTAssertTrue(coordinator.isTransitioning)
        XCTAssertFalse(host.list.isHidden, "Visible list content must remain until out completion")
        XCTAssertFalse(host.timeline.isHidden)
        XCTAssertFalse(host.timeline.isUserInteractionEnabled)

        factory.finishPending()

        XCTAssertEqual(coordinator.settledMode, .chat)
        XCTAssertTrue(host.list.isHidden)
        XCTAssertEqual(host.list.alpha, 1, accuracy: 0.0001)
        XCTAssertFalse(host.timeline.isHidden)
        XCTAssertTrue(host.timeline.isUserInteractionEnabled)
        XCTAssertEqual(recorder.modes, [.list, .chat])
    }

    func testRepeatedRequestsCoalesceAndInterruptionSettlesAtLastRequestedMode() {
        let factory = ManualModeAnimatorFactory()
        let coordinator = ChatSearchModeTransitionCoordinator(animatorFactory: factory)
        let host = TransitionHost()
        let recorder = ModeRecorder()

        transition(
            coordinator,
            host: host,
            to: .list,
            generation: 4,
            recorder: recorder
        )
        let initialAnimatorCount = factory.animators.count
        for _ in 0..<5 {
            transition(
                coordinator,
                host: host,
                to: .list,
                generation: 4,
                recorder: recorder
            )
        }
        XCTAssertEqual(factory.animators.count, initialAnimatorCount)

        transition(
            coordinator,
            host: host,
            to: .chat,
            generation: 4,
            recorder: recorder
        )
        transition(
            coordinator,
            host: host,
            to: .list,
            generation: 4,
            recorder: recorder
        )
        factory.finishAllIncludingStopped()

        XCTAssertEqual(coordinator.requestedMode, .list)
        XCTAssertEqual(coordinator.settledMode, .list)
        XCTAssertEqual(recorder.modes.last, .list)
        XCTAssertFalse(host.list.isHidden)
        XCTAssertTrue(host.timeline.isHidden)
        XCTAssertEqual(coordinator.activeOverlayCount, 0)
    }

    func testStaleGenerationCompletionCannotApplyRequestedMode() {
        let factory = ManualModeAnimatorFactory()
        let coordinator = ChatSearchModeTransitionCoordinator(animatorFactory: factory)
        let host = TransitionHost()
        var currentGeneration = 5
        let recorder = ModeRecorder()

        coordinator.transition(
            to: .list,
            generation: 5,
            animated: true,
            animationSpec: .production,
            containerView: host.container,
            listContentView: host.list,
            timelineView: host.timeline,
            isGenerationCurrent: { $0 == currentGeneration },
            bringChromeToFront: host.bringChromeToFront,
            applyFinalMode: { recorder.modes.append($0) }
        )
        currentGeneration = 6
        factory.finishPending()

        XCTAssertFalse(recorder.modes.contains(.list))
        XCTAssertEqual(coordinator.settledMode, .chat)
        XCTAssertEqual(coordinator.activeOverlayCount, 0)
        XCTAssertTrue(host.list.isHidden)
        XCTAssertFalse(host.timeline.isHidden)
    }

    func testCoordinatorLeavesChromeKeyboardAndConstraintFramesStationary() {
        let factory = ManualModeAnimatorFactory()
        let coordinator = ChatSearchModeTransitionCoordinator(animatorFactory: factory)
        let host = TransitionHost()
        let initialFrames = [host.timeline.frame, host.topChrome.frame, host.bottomControls.frame]
        let initialTransforms = [
            host.timeline.transform,
            host.topChrome.transform,
            host.bottomControls.transform
        ]
        let recorder = ModeRecorder()

        transition(
            coordinator,
            host: host,
            to: .list,
            generation: 6,
            recorder: recorder
        )

        XCTAssertTrue(coordinator.activeBlurView is UIVisualEffectView)
        XCTAssertEqual([host.timeline.frame, host.topChrome.frame, host.bottomControls.frame], initialFrames)
        XCTAssertEqual(
            [host.timeline.transform, host.topChrome.transform, host.bottomControls.transform],
            initialTransforms
        )
        XCTAssertEqual(host.container.constraints.map(\.constant), host.initialConstraintConstants)

        factory.finishPending()

        XCTAssertEqual([host.timeline.frame, host.topChrome.frame, host.bottomControls.frame], initialFrames)
        XCTAssertEqual(host.container.constraints.map(\.constant), host.initialConstraintConstants)
    }

    private func transition(
        _ coordinator: ChatSearchModeTransitionCoordinator,
        host: TransitionHost,
        to mode: ChatSearchModeTransitionPlan.Mode,
        generation: Int,
        recorder: ModeRecorder
    ) {
        coordinator.transition(
            to: mode,
            generation: generation,
            animated: true,
            animationSpec: .production,
            containerView: host.container,
            listContentView: host.list,
            timelineView: host.timeline,
            isGenerationCurrent: { $0 == generation },
            bringChromeToFront: host.bringChromeToFront,
            applyFinalMode: { recorder.modes.append($0) }
        )
    }
}

private final class ModeRecorder {
    var modes: [ChatSearchModeTransitionPlan.Mode] = []
}

@MainActor
private final class TransitionHost {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let container = UIView()
    let timeline = UIView()
    let list = UIView()
    let topChrome = UIView()
    let bottomControls = UIView()
    let initialConstraintConstants: [CGFloat]

    init() {
        initialConstraintConstants = [390, 844]
        container.frame = window.bounds
        timeline.frame = container.bounds
        list.frame = container.bounds
        topChrome.frame = CGRect(x: 0, y: 0, width: 390, height: 60)
        bottomControls.frame = CGRect(x: 0, y: 804, width: 390, height: 40)
        timeline.backgroundColor = .systemBackground
        list.backgroundColor = .secondarySystemBackground
        list.addSubview(UILabel(frame: CGRect(x: 16, y: 100, width: 200, height: 30)))
        topChrome.backgroundColor = .systemBlue
        bottomControls.backgroundColor = .systemGreen
        list.isHidden = true
        container.addSubview(timeline)
        container.addSubview(list)
        container.addSubview(topChrome)
        container.addSubview(bottomControls)

        let width = container.widthAnchor.constraint(equalToConstant: 390)
        let height = container.heightAnchor.constraint(equalToConstant: 844)
        NSLayoutConstraint.activate([width, height])

        window.addSubview(container)
        window.isHidden = false
        container.layoutIfNeeded()
    }

    deinit {
        window.isHidden = true
    }

    lazy var bringChromeToFront: () -> Void = { [unowned self] in
        container.bringSubviewToFront(topChrome)
        container.bringSubviewToFront(bottomControls)
    }
}

@MainActor
private final class ManualModeAnimatorFactory: ChatSearchModeAnimatorFactory {
    private(set) var animators: [ManualModeAnimator] = []

    func makeAnimator(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void
    ) -> ChatSearchModeAnimating {
        let animator = ManualModeAnimator(timing: timing, animations: animations)
        animators.append(animator)
        return animator
    }

    func finishPending() {
        animators.filter { !$0.isFinished && !$0.isStopped }.forEach {
            $0.finishAnimation(at: .end)
        }
    }

    func finishAllIncludingStopped() {
        animators.filter { !$0.isFinished }.forEach {
            $0.finishAnimation(at: .end)
        }
    }
}

@MainActor
private final class ManualModeAnimator: ChatSearchModeAnimating {
    let timing: ChatSearchAnimationSpec.Timing
    private let animations: () -> Void
    private var completions: [(UIViewAnimatingPosition) -> Void] = []
    private(set) var isStopped = false
    private(set) var isFinished = false

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
        isStopped = true
    }

    func finishAnimation(at position: UIViewAnimatingPosition) {
        guard !isFinished else { return }
        isFinished = true
        completions.forEach { $0(position) }
    }
}
