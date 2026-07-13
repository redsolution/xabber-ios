//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//

import UIKit

struct ChatSearchModeTransitionPlan: Equatable {
    enum Mode: Equatable {
        case chat
        case list
    }

    enum StationaryRegion: Hashable {
        case timeline
        case topChrome
        case bottomControls
        case keyboard
    }

    enum BlurImplementation: Equatable {
        case none
        case publicVisualEffect
    }

    let targetMode: Mode
    let generation: Int
    let contentTransition: ChatSearchAnimationSpec.Transition
    let stationaryRegions: Set<StationaryRegion>
    let animatesListContentOnly: Bool
    let removesListAfterCompletion: Bool
    let blurImplementation: BlurImplementation
    let isAnimated: Bool
    let maximumDuration: TimeInterval

    static func make(
        targetMode: Mode,
        generation: Int,
        animationSpec: ChatSearchAnimationSpec,
        animated: Bool
    ) -> ChatSearchModeTransitionPlan {
        let sourceTransition: ChatSearchAnimationSpec.Transition
        switch targetMode {
        case .chat:
            sourceTransition = animationSpec.list.dismissal
        case .list:
            sourceTransition = animationSpec.list.presentation
        }
        let transition = animated
            ? sourceTransition
            : sourceTransition.replacingDurationsForModeTransition(with: 0)
        let maximumDuration = transition.modeTransitionDurations.max() ?? 0
        return ChatSearchModeTransitionPlan(
            targetMode: targetMode,
            generation: generation,
            contentTransition: transition,
            stationaryRegions: [.timeline, .topChrome, .bottomControls, .keyboard],
            animatesListContentOnly: true,
            removesListAfterCompletion: targetMode == .chat,
            blurImplementation: transition.blurRadius == nil ? .none : .publicVisualEffect,
            isAnimated: animated && maximumDuration > 0,
            maximumDuration: maximumDuration
        )
    }
}

private extension ChatSearchAnimationSpec.ScalarTransition {
    func replacingDurationForModeTransition(
        with duration: TimeInterval
    ) -> ChatSearchAnimationSpec.ScalarTransition {
        ChatSearchAnimationSpec.ScalarTransition(
            from: from,
            to: to,
            timing: ChatSearchAnimationSpec.Timing(
                duration: duration,
                curve: timing.curve
            )
        )
    }
}

private extension ChatSearchAnimationSpec.Transition {
    var modeTransitionDurations: [TimeInterval] {
        [
            scale?.timing.duration,
            alpha?.timing.duration,
            blurRadius?.timing.duration
        ].compactMap { $0 }
    }

    func replacingDurationsForModeTransition(
        with duration: TimeInterval
    ) -> ChatSearchAnimationSpec.Transition {
        ChatSearchAnimationSpec.Transition(
            scale: scale?.replacingDurationForModeTransition(with: duration),
            alpha: alpha?.replacingDurationForModeTransition(with: duration),
            blurRadius: blurRadius?.replacingDurationForModeTransition(with: duration),
            verticalOffsetFraction: verticalOffsetFraction,
            completionPolicy: completionPolicy
        )
    }
}

protocol ChatSearchModeAnimating: AnyObject {
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void)
    func startAnimation()
    func stopAnimation(_ withoutFinishing: Bool)
    func finishAnimation(at finalPosition: UIViewAnimatingPosition)
}

protocol ChatSearchModeAnimatorFactory: AnyObject {
    func makeAnimator(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void
    ) -> ChatSearchModeAnimating
}

extension UIViewPropertyAnimator: ChatSearchModeAnimating {}

final class UIKitChatSearchModeAnimatorFactory: ChatSearchModeAnimatorFactory {
    func makeAnimator(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void
    ) -> ChatSearchModeAnimating {
        let timingParameters: UITimingCurveProvider
        switch timing.curve {
        case .spring(let spring):
            timingParameters = UISpringTimingParameters(
                dampingRatio: CGFloat(spring.dampingRatio),
                initialVelocity: CGVector(
                    dx: spring.initialVelocity,
                    dy: spring.initialVelocity
                )
            )
        case .easeOut:
            timingParameters = UICubicTimingParameters(animationCurve: .easeOut)
        case .easeInOut:
            timingParameters = UICubicTimingParameters(animationCurve: .easeInOut)
        case .linear:
            timingParameters = UICubicTimingParameters(animationCurve: .linear)
        }
        let animator = UIViewPropertyAnimator(
            duration: timing.duration,
            timingParameters: timingParameters
        )
        animator.addAnimations(animations)
        return animator
    }
}

struct ChatSearchChromeTransitionPlan: Equatable {
    enum FinalState: Equatable {
        case visible
        case hidden
    }

    let finalState: FinalState
    let generation: Int
    let transition: ChatSearchAnimationSpec.Transition
    let isAnimated: Bool
    let maximumDuration: TimeInterval

    static func make(
        finalState: FinalState,
        generation: Int,
        animationSpec: ChatSearchAnimationSpec,
        animated: Bool
    ) -> ChatSearchChromeTransitionPlan {
        let source = finalState == .visible
            ? animationSpec.chromeControls
            : animationSpec.chromeControls.reversed()
        let transition = animated
            ? source
            : source.replacingDurationsForModeTransition(with: 0)
        let maximumDuration = transition.modeTransitionDurations.max() ?? 0
        return ChatSearchChromeTransitionPlan(
            finalState: finalState,
            generation: generation,
            transition: transition,
            isAnimated: animated && maximumDuration > 0,
            maximumDuration: maximumDuration
        )
    }
}

enum ChatSearchMotionMutationPolicy {
    static func shouldAnimate(
        requestedAnimated: Bool,
        isNavigationTransitionActive: Bool,
        isPreparingFirstFrame: Bool,
        isInteractiveKeyboardUpdate: Bool
    ) -> Bool {
        requestedAnimated &&
            !isNavigationTransitionActive &&
            !isPreparingFirstFrame &&
            !isInteractiveKeyboardUpdate
    }
}

final class ChatSearchChromeTransitionCoordinator {
    private final class ActiveTransition {
        let token = UUID()
        let plan: ChatSearchChromeTransitionPlan
        let contentHosts: [UIView]
        let animator: ChatSearchModeAnimating
        let isGenerationCurrent: (Int) -> Bool
        let completion: (ChatSearchChromeTransitionPlan.FinalState) -> Void

        init(
            plan: ChatSearchChromeTransitionPlan,
            contentHosts: [UIView],
            animator: ChatSearchModeAnimating,
            isGenerationCurrent: @escaping (Int) -> Bool,
            completion: @escaping (ChatSearchChromeTransitionPlan.FinalState) -> Void
        ) {
            self.plan = plan
            self.contentHosts = contentHosts
            self.animator = animator
            self.isGenerationCurrent = isGenerationCurrent
            self.completion = completion
        }
    }

    private let animatorFactory: ChatSearchModeAnimatorFactory
    private var activeTransition: ActiveTransition?

    private(set) var settledState: ChatSearchChromeTransitionPlan.FinalState = .hidden
    private(set) var requestedState: ChatSearchChromeTransitionPlan.FinalState = .hidden

    var isTransitioning: Bool {
        activeTransition != nil
    }

    init(
        animatorFactory: ChatSearchModeAnimatorFactory = UIKitChatSearchModeAnimatorFactory()
    ) {
        self.animatorFactory = animatorFactory
    }

    func transition(
        to finalState: ChatSearchChromeTransitionPlan.FinalState,
        generation: Int,
        animated: Bool,
        animationSpec: ChatSearchAnimationSpec,
        contentHosts: [UIView],
        isGenerationCurrent: @escaping (Int) -> Bool,
        completion: @escaping (ChatSearchChromeTransitionPlan.FinalState) -> Void
    ) {
        assert(Thread.isMainThread, "Chat search chrome motion must run on the main thread")
        requestedState = finalState
        if let activeTransition,
           activeTransition.plan.finalState == finalState,
           activeTransition.plan.generation == generation {
            return
        }

        if activeTransition == nil,
           settledState == finalState {
            cleanupViews(contentHosts)
            if isGenerationCurrent(generation) {
                completion(finalState)
            }
            return
        }

        interruptActiveTransition()
        let hosts = contentHosts.filter { !$0.isHidden }
        let plan = ChatSearchChromeTransitionPlan.make(
            finalState: finalState,
            generation: generation,
            animationSpec: animationSpec,
            animated: animated
        )
        guard !hosts.isEmpty,
              plan.isAnimated,
              hosts.allSatisfy({ $0.window != nil }),
              let timing = plan.transition.scale?.timing ?? plan.transition.alpha?.timing else {
            cleanupViews(hosts)
            settledState = finalState
            if isGenerationCurrent(generation) {
                completion(finalState)
            }
            return
        }

        apply(
            transition: plan.transition,
            endpoint: .initial,
            to: hosts
        )
        let animator = animatorFactory.makeAnimator(timing: timing) {
            Self.apply(
                transition: plan.transition,
                endpoint: .final,
                to: hosts
            )
        }
        let active = ActiveTransition(
            plan: plan,
            contentHosts: hosts,
            animator: animator,
            isGenerationCurrent: isGenerationCurrent,
            completion: completion
        )
        activeTransition = active
        animator.addCompletion { [weak self] _ in
            self?.animationCompleted(token: active.token)
        }
        animator.startAnimation()
    }

    func cleanupAnimations(finalState: ChatSearchChromeTransitionPlan.FinalState) {
        assert(Thread.isMainThread, "Chat search chrome cleanup must run on the main thread")
        if let activeTransition {
            activeTransition.animator.stopAnimation(true)
            cleanupViews(activeTransition.contentHosts)
            self.activeTransition = nil
        }
        settledState = finalState
        requestedState = finalState
    }

    private func animationCompleted(token: UUID) {
        guard let activeTransition,
              activeTransition.token == token else {
            return
        }
        let shouldComplete = activeTransition.isGenerationCurrent(
            activeTransition.plan.generation
        ) && requestedState == activeTransition.plan.finalState
        cleanupViews(activeTransition.contentHosts)
        self.activeTransition = nil
        guard shouldComplete else { return }
        settledState = activeTransition.plan.finalState
        activeTransition.completion(activeTransition.plan.finalState)
    }

    private func interruptActiveTransition() {
        guard let activeTransition else { return }
        activeTransition.animator.stopAnimation(true)
        cleanupViews(activeTransition.contentHosts)
        self.activeTransition = nil
    }

    private func cleanupViews(_ views: [UIView]) {
        views.forEach {
            $0.layer.removeAllAnimations()
            $0.alpha = 1
            $0.transform = .identity
        }
    }

    private enum Endpoint {
        case initial
        case final
    }

    private func apply(
        transition: ChatSearchAnimationSpec.Transition,
        endpoint: Endpoint,
        to views: [UIView]
    ) {
        Self.apply(transition: transition, endpoint: endpoint, to: views)
    }

    private static func apply(
        transition: ChatSearchAnimationSpec.Transition,
        endpoint: Endpoint,
        to views: [UIView]
    ) {
        let alpha: Double?
        let scale: Double?
        switch endpoint {
        case .initial:
            alpha = transition.alpha?.from
            scale = transition.scale?.from
        case .final:
            alpha = transition.alpha?.to
            scale = transition.scale?.to
        }
        views.forEach {
            if let alpha {
                $0.alpha = CGFloat(alpha)
            }
            if let scale {
                $0.transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
            } else {
                $0.transform = .identity
            }
        }
    }
}

protocol ChatSearchNavigationFeedbackGenerating: AnyObject {
    func prepare()
    func selectionChanged()
}

final class UIKitChatSearchNavigationFeedbackGenerator:
    ChatSearchNavigationFeedbackGenerating {
    private let generator = UISelectionFeedbackGenerator()

    func prepare() {
        generator.prepare()
    }

    func selectionChanged() {
        generator.selectionChanged()
    }
}

final class ChatSearchNavigationFeedbackCoordinator {
    private struct PendingFeedback {
        let expectedIndex: Int
        let generation: Int
    }

    private let generator: ChatSearchNavigationFeedbackGenerating
    private var pending: PendingFeedback?

    init(
        generator: ChatSearchNavigationFeedbackGenerating =
            UIKitChatSearchNavigationFeedbackGenerator()
    ) {
        self.generator = generator
    }

    func prepare(expectedIndex: Int, generation: Int) {
        pending = PendingFeedback(expectedIndex: expectedIndex, generation: generation)
        generator.prepare()
    }

    @discardableResult
    func commitPositioned(index: Int, generation: Int) -> Bool {
        guard let pending,
              pending.expectedIndex == index,
              pending.generation == generation else {
            return false
        }
        self.pending = nil
        generator.selectionChanged()
        return true
    }

    func cancel(generation: Int? = nil) {
        pending = nil
    }
}

final class ChatSearchModeTransitionCoordinator {
    private final class ActiveTransition {
        let token = UUID()
        let plan: ChatSearchModeTransitionPlan
        let listContentView: UIView
        let timelineView: UIView
        let snapshotView: UIView
        let blurView: UIVisualEffectView?
        let isGenerationCurrent: (Int) -> Bool
        let applyFinalMode: (ChatSearchModeTransitionPlan.Mode) -> Void
        var animators: [ChatSearchModeAnimating] = []
        var pendingCompletionCount = 0

        init(
            plan: ChatSearchModeTransitionPlan,
            listContentView: UIView,
            timelineView: UIView,
            snapshotView: UIView,
            blurView: UIVisualEffectView?,
            isGenerationCurrent: @escaping (Int) -> Bool,
            applyFinalMode: @escaping (ChatSearchModeTransitionPlan.Mode) -> Void
        ) {
            self.plan = plan
            self.listContentView = listContentView
            self.timelineView = timelineView
            self.snapshotView = snapshotView
            self.blurView = blurView
            self.isGenerationCurrent = isGenerationCurrent
            self.applyFinalMode = applyFinalMode
        }
    }

    private let animatorFactory: ChatSearchModeAnimatorFactory
    private var activeTransition: ActiveTransition?

    private(set) var settledMode: ChatSearchModeTransitionPlan.Mode = .chat
    private(set) var requestedMode: ChatSearchModeTransitionPlan.Mode = .chat

    var isTransitioning: Bool {
        activeTransition != nil
    }

    var activeOverlayCount: Int {
        activeTransition?.snapshotView.superview == nil ? 0 : 1
    }

    var activeBlurView: UIView? {
        activeTransition?.blurView
    }

    init(
        animatorFactory: ChatSearchModeAnimatorFactory = UIKitChatSearchModeAnimatorFactory()
    ) {
        self.animatorFactory = animatorFactory
    }

    func transition(
        to mode: ChatSearchModeTransitionPlan.Mode,
        generation: Int,
        animated: Bool,
        animationSpec: ChatSearchAnimationSpec,
        containerView: UIView,
        listContentView: UIView,
        timelineView: UIView,
        isGenerationCurrent: @escaping (Int) -> Bool,
        bringChromeToFront: @escaping () -> Void,
        applyFinalMode: @escaping (ChatSearchModeTransitionPlan.Mode) -> Void
    ) {
        assert(Thread.isMainThread, "Chat search mode transitions must run on the main thread")
        requestedMode = mode

        if let activeTransition,
           activeTransition.plan.targetMode == mode,
           activeTransition.plan.generation == generation {
            return
        }

        interruptActiveTransition(forIncomingGeneration: generation)

        let plan = ChatSearchModeTransitionPlan.make(
            targetMode: mode,
            generation: generation,
            animationSpec: animationSpec,
            animated: animated
        )
        guard settledMode != mode,
              plan.isAnimated,
              containerView.window != nil,
              listContentView.window != nil,
              !listContentView.bounds.isEmpty else {
            applyImmediateFinalMode(
                mode,
                listContentView: listContentView,
                timelineView: timelineView,
                applyFinalMode: applyFinalMode
            )
            bringChromeToFront()
            return
        }

        startTransition(
            plan,
            containerView: containerView,
            listContentView: listContentView,
            timelineView: timelineView,
            isGenerationCurrent: isGenerationCurrent,
            bringChromeToFront: bringChromeToFront,
            applyFinalMode: applyFinalMode
        )
    }

    func reset(to mode: ChatSearchModeTransitionPlan.Mode = .chat) {
        assert(Thread.isMainThread, "Chat search mode transitions must reset on the main thread")
        cleanupAnimations(finalState: mode)
    }

    func cleanupAnimations(finalState mode: ChatSearchModeTransitionPlan.Mode) {
        assert(Thread.isMainThread, "Chat search mode cleanup must run on the main thread")
        if let activeTransition {
            activeTransition.animators.forEach { $0.stopAnimation(true) }
            cleanup(activeTransition)
            applyVisualFinalMode(
                mode,
                listContentView: activeTransition.listContentView,
                timelineView: activeTransition.timelineView
            )
            activeTransition.applyFinalMode(mode)
            self.activeTransition = nil
        }
        settledMode = mode
        requestedMode = mode
    }

    private func startTransition(
        _ plan: ChatSearchModeTransitionPlan,
        containerView: UIView,
        listContentView: UIView,
        timelineView: UIView,
        isGenerationCurrent: @escaping (Int) -> Bool,
        bringChromeToFront: @escaping () -> Void,
        applyFinalMode: @escaping (ChatSearchModeTransitionPlan.Mode) -> Void
    ) {
        listContentView.transform = .identity
        listContentView.alpha = 1
        listContentView.isHidden = false
        listContentView.isUserInteractionEnabled = false
        timelineView.transform = .identity
        timelineView.alpha = 1
        timelineView.isHidden = false
        timelineView.isUserInteractionEnabled = false
        containerView.layoutIfNeeded()
        listContentView.layoutIfNeeded()

        guard let snapshotView = listContentView.snapshotView(afterScreenUpdates: true) else {
            applyImmediateFinalMode(
                plan.targetMode,
                listContentView: listContentView,
                timelineView: timelineView,
                applyFinalMode: applyFinalMode
            )
            bringChromeToFront()
            return
        }

        snapshotView.accessibilityIdentifier = "chat_search_mode_transition_snapshot"
        snapshotView.isAccessibilityElement = false
        snapshotView.isUserInteractionEnabled = false
        snapshotView.clipsToBounds = true
        snapshotView.frame = listContentView.convert(listContentView.bounds, to: containerView)
        if timelineView.superview === containerView {
            containerView.insertSubview(snapshotView, aboveSubview: timelineView)
        } else {
            containerView.addSubview(snapshotView)
        }
        listContentView.alpha = 0

        let transition = plan.contentTransition
        if let scale = transition.scale {
            snapshotView.transform = CGAffineTransform(
                scaleX: CGFloat(scale.from),
                y: CGFloat(scale.from)
            )
        }
        snapshotView.alpha = CGFloat(transition.alpha?.from ?? 1)

        let blurView: UIVisualEffectView?
        if let blur = transition.blurRadius {
            let view = UIVisualEffectView(effect: blurEffect(equivalentRadius: blur.from))
            view.frame = snapshotView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "chat_search_mode_transition_blur"
            snapshotView.addSubview(view)
            blurView = view
        } else {
            blurView = nil
        }

        let active = ActiveTransition(
            plan: plan,
            listContentView: listContentView,
            timelineView: timelineView,
            snapshotView: snapshotView,
            blurView: blurView,
            isGenerationCurrent: isGenerationCurrent,
            applyFinalMode: applyFinalMode
        )
        activeTransition = active
        bringChromeToFront()

        if let primaryTiming = transition.scale?.timing ?? transition.alpha?.timing {
            let animator = animatorFactory.makeAnimator(timing: primaryTiming) {
                if let scale = transition.scale {
                    snapshotView.transform = CGAffineTransform(
                        scaleX: CGFloat(scale.to),
                        y: CGFloat(scale.to)
                    )
                }
                if let alpha = transition.alpha {
                    snapshotView.alpha = CGFloat(alpha.to)
                }
            }
            active.animators.append(animator)
        }
        if let blur = transition.blurRadius, let blurView {
            let animator = animatorFactory.makeAnimator(timing: blur.timing) {
                blurView.effect = self.blurEffect(equivalentRadius: blur.to)
            }
            active.animators.append(animator)
        }

        guard active.animators.isNotEmpty else {
            complete(active)
            return
        }
        active.pendingCompletionCount = active.animators.count
        active.animators.forEach { animator in
            animator.addCompletion { [weak self] _ in
                self?.animationCompleted(token: active.token)
            }
            animator.startAnimation()
        }
    }

    private func animationCompleted(token: UUID) {
        guard let activeTransition,
              activeTransition.token == token else {
            return
        }
        activeTransition.pendingCompletionCount -= 1
        guard activeTransition.pendingCompletionCount == 0 else { return }
        complete(activeTransition)
    }

    private func complete(_ active: ActiveTransition) {
        guard activeTransition?.token == active.token else { return }
        let mayApplyRequestedMode = active.isGenerationCurrent(active.plan.generation) &&
            requestedMode == active.plan.targetMode
        cleanup(active)
        activeTransition = nil
        if mayApplyRequestedMode {
            settledMode = active.plan.targetMode
            applyVisualFinalMode(
                active.plan.targetMode,
                listContentView: active.listContentView,
                timelineView: active.timelineView
            )
            active.applyFinalMode(active.plan.targetMode)
        } else {
            applyVisualFinalMode(
                settledMode,
                listContentView: active.listContentView,
                timelineView: active.timelineView
            )
            active.applyFinalMode(settledMode)
        }
    }

    private func interruptActiveTransition(forIncomingGeneration generation: Int) {
        guard let activeTransition else { return }
        activeTransition.animators.forEach { $0.stopAnimation(true) }
        let canSettleAtInterruptedTarget = activeTransition.plan.generation == generation &&
            activeTransition.isGenerationCurrent(activeTransition.plan.generation)
        cleanup(activeTransition)
        self.activeTransition = nil
        if canSettleAtInterruptedTarget {
            settledMode = activeTransition.plan.targetMode
            applyVisualFinalMode(
                settledMode,
                listContentView: activeTransition.listContentView,
                timelineView: activeTransition.timelineView
            )
            activeTransition.applyFinalMode(settledMode)
        } else {
            applyVisualFinalMode(
                settledMode,
                listContentView: activeTransition.listContentView,
                timelineView: activeTransition.timelineView
            )
        }
    }

    private func applyImmediateFinalMode(
        _ mode: ChatSearchModeTransitionPlan.Mode,
        listContentView: UIView,
        timelineView: UIView,
        applyFinalMode: (ChatSearchModeTransitionPlan.Mode) -> Void
    ) {
        settledMode = mode
        requestedMode = mode
        applyVisualFinalMode(
            mode,
            listContentView: listContentView,
            timelineView: timelineView
        )
        applyFinalMode(mode)
    }

    private func applyVisualFinalMode(
        _ mode: ChatSearchModeTransitionPlan.Mode,
        listContentView: UIView,
        timelineView: UIView
    ) {
        listContentView.transform = .identity
        listContentView.alpha = 1
        timelineView.transform = .identity
        timelineView.alpha = 1
        switch mode {
        case .chat:
            listContentView.isHidden = true
            listContentView.isUserInteractionEnabled = false
            timelineView.isHidden = false
            timelineView.isUserInteractionEnabled = true
        case .list:
            listContentView.isHidden = false
            listContentView.isUserInteractionEnabled = true
            timelineView.isHidden = true
            timelineView.isUserInteractionEnabled = false
        }
    }

    private func cleanup(_ active: ActiveTransition) {
        active.snapshotView.removeFromSuperview()
        active.listContentView.transform = .identity
        active.listContentView.alpha = 1
        active.timelineView.transform = .identity
        active.timelineView.alpha = 1
    }

    private func blurEffect(equivalentRadius: Double) -> UIVisualEffect? {
        guard equivalentRadius > 0 else { return nil }
        return UIBlurEffect(style: .systemMaterial)
    }
}
