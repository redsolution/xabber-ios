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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//

import UIKit

struct ChatSearchCalendarDismissalPolicy: Equatable {
    let dismissesOnOutsideTap: Bool
    let dismissesInteractively: Bool

    static let explicitCloseOnly = ChatSearchCalendarDismissalPolicy(
        dismissesOnOutsideTap: false,
        dismissesInteractively: false
    )
}

struct ChatSearchCalendarPresentationPlan: Equatable {
    enum TargetState: Equatable {
        case presented
        case dismissed
    }

    let targetState: TargetState
    let generation: Int
    let dimTransition: ChatSearchAnimationSpec.Transition
    let sheetTransition: ChatSearchAnimationSpec.Transition
    let dimTargetAlpha: Double
    let dismissalPolicy: ChatSearchCalendarDismissalPolicy
    let isAnimated: Bool
    let isReducedMotion: Bool
    let maximumDuration: TimeInterval

    var initialSheetOffsetFraction: Double {
        sheetTransition.verticalOffsetFraction?.from ?? 0
    }

    static func make(
        targetState: TargetState,
        generation: Int,
        animationSpec: ChatSearchAnimationSpec,
        animated: Bool
    ) -> ChatSearchCalendarPresentationPlan {
        let dimTransition: ChatSearchAnimationSpec.Transition
        let sheetTransition: ChatSearchAnimationSpec.Transition
        switch targetState {
        case .presented:
            dimTransition = animationSpec.calendar.dimPresentation
            sheetTransition = animationSpec.calendar.sheetPresentation
        case .dismissed:
            dimTransition = animationSpec.calendar.dimDismissal
            sheetTransition = animationSpec.calendar.sheetDismissal
        }
        let durations = [
            dimTransition.alpha?.timing.duration,
            dimTransition.verticalOffsetFraction?.timing.duration,
            sheetTransition.alpha?.timing.duration,
            sheetTransition.verticalOffsetFraction?.timing.duration
        ].compactMap { $0 }
        let sourceMaximumDuration = durations.max() ?? 0
        let maximumDuration = animated ? sourceMaximumDuration : 0
        return ChatSearchCalendarPresentationPlan(
            targetState: targetState,
            generation: generation,
            dimTransition: dimTransition,
            sheetTransition: sheetTransition,
            dimTargetAlpha: 0.5,
            dismissalPolicy: .explicitCloseOnly,
            isAnimated: animated && maximumDuration > 0,
            isReducedMotion: animationSpec.isReducedMotion,
            maximumDuration: maximumDuration
        )
    }
}

@MainActor
final class ChatSearchCalendarViewController: UIViewController {
    private struct VisualState {
        let dimAlpha: CGFloat
        let sheetAlpha: CGFloat
        let sheetTransform: CGAffineTransform
    }

    private final class ActiveTransition {
        let token = UUID()
        let plan: ChatSearchCalendarPresentationPlan
        let isGenerationCurrent: (Int) -> Bool
        let completion: (() -> Void)?
        var animators: [ChatSearchModeAnimating] = []
        var pendingCompletionCount = 0

        init(
            plan: ChatSearchCalendarPresentationPlan,
            isGenerationCurrent: @escaping (Int) -> Bool,
            completion: (() -> Void)?
        ) {
            self.plan = plan
            self.isGenerationCurrent = isGenerationCurrent
            self.completion = completion
        }
    }

    static let dimAccessibilityIdentifier = "chat_search_calendar_dim"

    var onCancel: (() -> Void)?
    var onComplete: ((Date) -> Void)?
    var onAccessibilityFocusRequest: ((UIView) -> Void)?

    let dimView = UIView()
    let calendarView: ChatSearchCalendarView
    let dismissalPolicy = ChatSearchCalendarDismissalPolicy.explicitCloseOnly

    private(set) var settledState: ChatSearchCalendarPresentationPlan.TargetState = .dismissed
    private(set) var requestedState: ChatSearchCalendarPresentationPlan.TargetState = .dismissed
    private(set) var lastTransitionPlan: ChatSearchCalendarPresentationPlan?
    private(set) weak var lastAccessibilityFocusTarget: UIView?

    var isTransitioning: Bool {
        activeTransition != nil
    }

    var activeOverlayCount: Int {
        viewIfLoaded?.superview == nil ? 0 : 1
    }

    private var model: ChatSearchCalendarModel
    private let animationSpec: ChatSearchAnimationSpec
    private let animatorFactory: ChatSearchModeAnimatorFactory
    private var activeTransition: ActiveTransition?
    private var requestedGeneration: Int?
    private weak var focusReturnView: UIView?

    init(
        model: ChatSearchCalendarModel,
        animationSpec: ChatSearchAnimationSpec,
        animatorFactory: ChatSearchModeAnimatorFactory = UIKitChatSearchModeAnimatorFactory(),
        prefersNativeGlass: Bool = true
    ) {
        self.model = model
        self.animationSpec = animationSpec
        self.animatorFactory = animatorFactory
        calendarView = ChatSearchCalendarView(
            frame: .zero,
            snapshot: model.snapshot,
            animationSpec: animationSpec,
            prefersNativeGlass: prefersNativeGlass
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
        wireCalendarCallbacks()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settleForApplicationLifecycleInterruption),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settleForApplicationLifecycleInterruption),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .clear
        rootView.accessibilityViewIsModal = true
        rootView.accessibilityElementsHidden = true
        rootView.accessibilityElements = [calendarView]

        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.isAccessibilityElement = false
        dimView.accessibilityElementsHidden = true
        dimView.accessibilityIdentifier = Self.dimAccessibilityIdentifier
        rootView.addSubview(dimView)
        rootView.addSubview(calendarView)
        view = rootView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dimView.frame = view.bounds
        let snapshot = model.snapshot
        let frames = ChatSearchCalendarLayout.frames(
            in: CGRect(
                x: 0,
                y: 0,
                width: view.bounds.width,
                height: view.bounds.height
            ),
            rowCount: snapshot.rowCount,
            isMonthYearPickerPresented: snapshot.isMonthYearPickerPresented,
            safeAreaInsets: view.safeAreaInsets,
            layoutDirection: UIView.userInterfaceLayoutDirection(
                for: calendarView.semanticContentAttribute
            ),
            contentSizeCategory: calendarView.adaptiveEnvironment.contentSizeCategory
        )
        let sheetHeight = min(view.bounds.height, frames.sheetHeight)
        calendarView.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: view.bounds.width, height: sheetHeight)
        )
        calendarView.center = CGPoint(
            x: view.bounds.midX,
            y: view.bounds.maxY - (sheetHeight / 2)
        )
    }

    func install(in parent: UIViewController, containerView: UIView) {
        assert(Thread.isMainThread, "Chat search calendar containment must run on the main thread")
        guard self.parent == nil else {
            if self.parent === parent, view.superview === containerView {
                containerView.bringSubviewToFront(view)
            }
            return
        }
        parent.definesPresentationContext = true
        parent.addChild(self)
        view.frame = containerView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.addSubview(view)
        didMove(toParent: parent)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func present(
        generation: Int,
        animated: Bool,
        focusReturnView: UIView?,
        isGenerationCurrent: @escaping (Int) -> Bool
    ) {
        assert(Thread.isMainThread, "Chat search calendar presentation must run on the main thread")
        guard parent != nil, view.superview != nil else { return }
        if requestedState == .presented,
           requestedGeneration == generation,
           (activeTransition != nil || settledState == .presented) {
            return
        }

        let interruptedVisualState = interruptActiveTransitionPreservingVisualState()
        requestedState = .presented
        requestedGeneration = generation
        self.focusReturnView = focusReturnView
        startTransition(
            targetState: .presented,
            generation: generation,
            animated: animated,
            isGenerationCurrent: isGenerationCurrent,
            completion: nil,
            initialVisualState: interruptedVisualState
        )
    }

    func dismiss(
        generation: Int,
        animated: Bool,
        isGenerationCurrent: @escaping (Int) -> Bool,
        completion: (() -> Void)?
    ) {
        assert(Thread.isMainThread, "Chat search calendar dismissal must run on the main thread")
        guard parent != nil || viewIfLoaded?.superview != nil else {
            completion?()
            return
        }
        if requestedState == .dismissed,
           requestedGeneration == generation,
           activeTransition != nil {
            return
        }

        let interruptedVisualState = interruptActiveTransitionPreservingVisualState()
        requestedState = .dismissed
        requestedGeneration = generation
        startTransition(
            targetState: .dismissed,
            generation: generation,
            animated: animated,
            isGenerationCurrent: isGenerationCurrent,
            completion: completion,
            initialVisualState: interruptedVisualState
        )
    }

    func settleTransitionForLifecycleInterruption() {
        assert(Thread.isMainThread, "Chat search calendar lifecycle settlement must run on the main thread")
        guard let activeTransition else { return }
        activeTransition.animators.forEach { $0.stopAnimation(true) }
        complete(activeTransition)
    }

    func reset() {
        assert(Thread.isMainThread, "Chat search calendar reset must run on the main thread")
        activeTransition?.animators.forEach { $0.stopAnimation(true) }
        activeTransition = nil
        requestedState = .dismissed
        settledState = .dismissed
        requestedGeneration = nil
        applyFinalVisualState(.dismissed, dimTargetAlpha: 0.5)
        removeFromContainment()
    }

    private func startTransition(
        targetState: ChatSearchCalendarPresentationPlan.TargetState,
        generation: Int,
        animated: Bool,
        isGenerationCurrent: @escaping (Int) -> Bool,
        completion: (() -> Void)?,
        initialVisualState: VisualState?
    ) {
        let plan = ChatSearchCalendarPresentationPlan.make(
            targetState: targetState,
            generation: generation,
            animationSpec: animationSpec,
            animated: animated
        )
        lastTransitionPlan = plan
        view.setNeedsLayout()
        view.layoutIfNeeded()
        configureInteractionState(for: plan.targetState)
        if let initialVisualState {
            applyVisualState(initialVisualState)
        } else {
            applyInitialVisualState(plan)
        }

        guard plan.isAnimated, view.window != nil else {
            let immediate = ActiveTransition(
                plan: plan,
                isGenerationCurrent: isGenerationCurrent,
                completion: completion
            )
            activeTransition = immediate
            complete(immediate)
            return
        }

        let active = ActiveTransition(
            plan: plan,
            isGenerationCurrent: isGenerationCurrent,
            completion: completion
        )
        activeTransition = active
        appendDimAnimator(to: active)
        appendSheetAnimator(to: active)

        guard !active.animators.isEmpty else {
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

    private func appendDimAnimator(to active: ActiveTransition) {
        guard let alpha = active.plan.dimTransition.alpha else { return }
        let animator = animatorFactory.makeAnimator(timing: alpha.timing) { [weak self] in
            guard let self else { return }
            dimView.alpha = CGFloat(alpha.to * active.plan.dimTargetAlpha)
        }
        active.animators.append(animator)
    }

    private func appendSheetAnimator(to active: ActiveTransition) {
        let transition = active.plan.sheetTransition
        guard let timing = transition.verticalOffsetFraction?.timing ?? transition.alpha?.timing else {
            return
        }
        let animator = animatorFactory.makeAnimator(timing: timing) { [weak self] in
            guard let self else { return }
            if let alpha = transition.alpha {
                calendarView.alpha = CGFloat(alpha.to)
            }
            if let offset = transition.verticalOffsetFraction {
                calendarView.transform = sheetTransform(offsetFraction: offset.to)
            }
        }
        active.animators.append(animator)
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
        let isCurrent = active.isGenerationCurrent(active.plan.generation) &&
            requestedState == active.plan.targetState &&
            requestedGeneration == active.plan.generation
        activeTransition = nil

        guard isCurrent else {
            requestedState = .dismissed
            settledState = .dismissed
            requestedGeneration = nil
            applyFinalVisualState(.dismissed, dimTargetAlpha: active.plan.dimTargetAlpha)
            removeFromContainment()
            return
        }

        settledState = active.plan.targetState
        applyFinalVisualState(
            active.plan.targetState,
            dimTargetAlpha: active.plan.dimTargetAlpha
        )
        switch active.plan.targetState {
        case .presented:
            requestAccessibilityFocus(calendarView.preferredAccessibilityFocusView)
        case .dismissed:
            removeFromContainment()
            active.completion?()
            if let focusReturnView {
                requestAccessibilityFocus(focusReturnView)
            }
        }
    }

    private func interruptActiveTransitionPreservingVisualState() -> VisualState? {
        guard let activeTransition else { return nil }
        let visualState = currentVisualState()
        activeTransition.animators.forEach { $0.stopAnimation(true) }
        self.activeTransition = nil
        applyVisualState(visualState)
        return visualState
    }

    private func applyInitialVisualState(_ plan: ChatSearchCalendarPresentationPlan) {
        configureInteractionState(for: plan.targetState)
        if let dimAlpha = plan.dimTransition.alpha {
            dimView.alpha = CGFloat(dimAlpha.from * plan.dimTargetAlpha)
        }
        if let sheetAlpha = plan.sheetTransition.alpha {
            calendarView.alpha = CGFloat(sheetAlpha.from)
        } else {
            calendarView.alpha = 1
        }
        if let sheetOffset = plan.sheetTransition.verticalOffsetFraction {
            calendarView.transform = sheetTransform(offsetFraction: sheetOffset.from)
        } else {
            calendarView.transform = .identity
        }
    }

    private func configureInteractionState(
        for targetState: ChatSearchCalendarPresentationPlan.TargetState
    ) {
        let isPresenting = targetState == .presented
        view.accessibilityElementsHidden = !isPresenting
        calendarView.accessibilityElementsHidden = !isPresenting
        dimView.isUserInteractionEnabled = true
        calendarView.isUserInteractionEnabled = true
    }

    private func currentVisualState() -> VisualState {
        let presentedDimLayer = dimView.layer.presentation()
        let presentedSheetLayer = calendarView.layer.presentation()
        return VisualState(
            dimAlpha: CGFloat(presentedDimLayer?.opacity ?? Float(dimView.alpha)),
            sheetAlpha: CGFloat(presentedSheetLayer?.opacity ?? Float(calendarView.alpha)),
            sheetTransform: presentedSheetLayer?.affineTransform() ?? calendarView.transform
        )
    }

    private func applyVisualState(_ state: VisualState) {
        dimView.alpha = state.dimAlpha
        calendarView.alpha = state.sheetAlpha
        calendarView.transform = state.sheetTransform
    }

    private func applyFinalVisualState(
        _ state: ChatSearchCalendarPresentationPlan.TargetState,
        dimTargetAlpha: Double
    ) {
        switch state {
        case .presented:
            view.accessibilityElementsHidden = false
            calendarView.accessibilityElementsHidden = false
            dimView.alpha = CGFloat(dimTargetAlpha)
            calendarView.alpha = 1
            calendarView.transform = .identity
            dimView.isUserInteractionEnabled = true
            calendarView.isUserInteractionEnabled = true
        case .dismissed:
            view.accessibilityElementsHidden = true
            calendarView.accessibilityElementsHidden = true
            dimView.alpha = 0
            calendarView.alpha = 0
            calendarView.transform = sheetTransform(offsetFraction: 1)
            dimView.isUserInteractionEnabled = false
            calendarView.isUserInteractionEnabled = false
        }
    }

    private func sheetTransform(offsetFraction: Double) -> CGAffineTransform {
        CGAffineTransform(
            translationX: 0,
            y: calendarView.bounds.height * CGFloat(offsetFraction)
        )
    }

    private func requestAccessibilityFocus(_ target: UIView) {
        lastAccessibilityFocusTarget = target
        if let onAccessibilityFocusRequest {
            onAccessibilityFocusRequest(target)
        } else {
            UIAccessibility.post(notification: .screenChanged, argument: target)
        }
    }

    private func removeFromContainment() {
        guard parent != nil || viewIfLoaded?.superview != nil else { return }
        willMove(toParent: nil)
        viewIfLoaded?.removeFromSuperview()
        removeFromParent()
    }

    private func wireCalendarCallbacks() {
        calendarView.onClose = { [weak self] in
            self?.onCancel?()
        }
        calendarView.onPreviousMonth = { [weak self] in
            self?.moveMonth(.previous)
        }
        calendarView.onNextMonth = { [weak self] in
            self?.moveMonth(.next)
        }
        calendarView.onSwipeMonth = { [weak self] direction in
            self?.moveMonth(for: direction)
        }
        calendarView.onSelectDay = { [weak self] id in
            guard let self, model.selectDay(id: id) else { return }
            renderModel(animated: false)
        }
        calendarView.onToggleMonthYearPicker = { [weak self] in
            guard let self else { return }
            model.toggleMonthYearPicker()
            renderModel(animated: false)
        }
        calendarView.onSelectMonthYear = { [weak self] month, year in
            guard let self, model.selectMonthYear(month: month, year: year) else { return }
            renderModel(animated: false)
        }
        calendarView.onDismissMonthYearPicker = { [weak self] in
            guard let self else { return }
            model.dismissMonthYearPicker()
            renderModel(animated: false)
        }
        calendarView.onApplyMonthYearPicker = { [weak self] in
            guard let self else { return }
            let oldMonth = model.snapshot.visibleMonthStart
            guard model.applyMonthYearPickerSelection() else { return }
            let direction: ChatSearchCalendarModel.MonthDirection =
                model.snapshot.visibleMonthStart >= oldMonth ? .next : .previous
            renderModel(animated: true, monthDirection: direction)
        }
        calendarView.onDone = { [weak self] in
            guard let self,
                  model.snapshot.isDoneEnabled else {
                return
            }
            onComplete?(model.selectedDate)
        }
    }

    private func moveMonth(_ direction: ChatSearchCalendarModel.MonthDirection) {
        guard model.navigateMonth(direction) else { return }
        renderModel(animated: true, monthDirection: direction)
    }

    private func moveMonth(for visualDirection: ChatSearchCalendarModel.VisualSwipeDirection) {
        let direction = UIView.userInterfaceLayoutDirection(for: calendarView.semanticContentAttribute)
        let modelDirection: ChatSearchCalendarModel.LayoutDirection = direction == .rightToLeft
            ? .rightToLeft
            : .leftToRight
        guard let transition = model.monthTransition(
            for: visualDirection,
            layoutDirection: modelDirection
        ), model.navigateMonth(transition.monthDirection) else {
            return
        }
        renderModel(animated: true, monthDirection: transition.monthDirection)
    }

    private func renderModel(
        animated: Bool,
        monthDirection: ChatSearchCalendarModel.MonthDirection? = nil
    ) {
        calendarView.render(
            snapshot: model.snapshot,
            animated: animated,
            monthDirection: monthDirection
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    @objc private func settleForApplicationLifecycleInterruption() {
        settleTransitionForLifecycleInterruption()
    }
}
