//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import UIKit

private final class ChatSearchExpandedHitButton: UIButton {
    override var accessibilityFrame: CGRect {
        get {
            guard window != nil, let superview else {
                return super.accessibilityFrame
            }
            return superview.convert(
                ChatSearchAdaptiveLayoutPolicy.accessibilityHitFrame(for: frame),
                to: nil
            )
        }
        set {
            super.accessibilityFrame = newValue
        }
    }
}

struct ChatSearchNavigationButtonsLayout {
    struct Frames: Equatable {
        let previous: CGRect
        let next: CGRect
    }

    static let buttonSize: CGFloat = 40
    static let verticalGap: CGFloat = 12
    static let trailingInset: CGFloat = 16
    static let bottomInset: CGFloat = 12
    static let stackSize = CGSize(
        width: buttonSize,
        height: buttonSize * 2 + verticalGap
    )

    static func buttonFrames(in bounds: CGRect) -> Frames {
        let x = bounds.minX + max(0, (bounds.width - buttonSize) / 2)
        return Frames(
            previous: CGRect(x: x, y: bounds.minY, width: buttonSize, height: buttonSize),
            next: CGRect(
                x: x,
                y: bounds.minY + buttonSize + verticalGap,
                width: buttonSize,
                height: buttonSize
            )
        )
    }

    static func stackFrame(
        in bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        bottomObstructionMinY: CGFloat
    ) -> CGRect {
        CGRect(
            x: bounds.maxX - max(0, safeAreaInsets.right) - trailingInset - stackSize.width,
            y: bottomObstructionMinY - bottomInset - stackSize.height,
            width: stackSize.width,
            height: stackSize.height
        )
    }
}

struct ChatSearchNavigationButtonsRenderPolicy {
    static func state(
        presentation: ChatSearchPresentationState,
        navigationBusy: Bool,
        canRequestOlderPage: Bool
    ) -> ChatSearchNavigationButtonsView.RenderState {
        guard presentation.isActive,
              presentation.surfaceMode == .chat,
              presentation.resultPhase == .results,
              presentation.resultCount > 0,
              let current = presentation.committedResultIndex,
              (0..<presentation.resultCount).contains(current) else {
            return .hidden
        }

        let canNavigateOlder = current + 1 < presentation.resultCount ||
            (current == presentation.resultCount - 1 && canRequestOlderPage)
        let canNavigateNewer = current > 0
        return .init(
            isVisible: true,
            isPreviousEnabled: !navigationBusy && canNavigateOlder,
            isNextEnabled: !navigationBusy && canNavigateNewer,
            isBusy: navigationBusy
        )
    }
}

struct ChatSearchOlderPageNavigationGate {
    enum Phase: Equatable {
        case unavailable
        case available
        case requesting
        case terminal
    }

    struct Request: Equatable {
        let cursor: String
        let loadedResultCount: Int
    }

    private(set) var generation: UInt64
    private(set) var phase: Phase = .unavailable
    private var cursor: String?
    private var offeredCursors: Set<String> = []
    private var loadedResultCount = 0
    private var pendingNavigationTarget: Int?

    init(generation: UInt64) {
        self.generation = generation
    }

    var canRequest: Bool {
        phase == .available && cursor != nil
    }

    var hasPendingNavigation: Bool {
        pendingNavigationTarget != nil
    }

    @discardableResult
    mutating func offer(
        cursor rawCursor: String,
        generation eventGeneration: UInt64,
        loadedResultCount eventLoadedResultCount: Int
    ) -> Bool {
        let normalizedCursor = rawCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventGeneration == generation,
              normalizedCursor.isNotEmpty,
              phase != .terminal else {
            return false
        }
        guard !offeredCursors.contains(normalizedCursor) else {
            phase = .terminal
            cursor = nil
            pendingNavigationTarget = nil
            return false
        }
        if phase == .requesting,
           eventLoadedResultCount <= loadedResultCount {
            phase = .terminal
            cursor = nil
            pendingNavigationTarget = nil
            return false
        }

        offeredCursors.insert(normalizedCursor)
        cursor = normalizedCursor
        loadedResultCount = max(0, eventLoadedResultCount)
        phase = .available
        return true
    }

    mutating func requestNavigation(generation eventGeneration: UInt64) -> Request? {
        guard eventGeneration == generation,
              canRequest,
              let cursor else {
            return nil
        }
        phase = .requesting
        pendingNavigationTarget = loadedResultCount
        return Request(cursor: cursor, loadedResultCount: loadedResultCount)
    }

    mutating func consumePendingNavigationTarget(
        resultCount: Int,
        generation eventGeneration: UInt64
    ) -> Int? {
        guard eventGeneration == generation,
              let target = pendingNavigationTarget,
              resultCount > target else {
            return nil
        }
        pendingNavigationTarget = nil
        return target
    }

    mutating func markTerminal(generation eventGeneration: UInt64) {
        guard eventGeneration == generation else {
            return
        }
        phase = .terminal
        cursor = nil
        pendingNavigationTarget = nil
    }

    mutating func reset(generation newGeneration: UInt64) {
        generation = newGeneration
        phase = .unavailable
        cursor = nil
        offeredCursors.removeAll()
        loadedResultCount = 0
        pendingNavigationTarget = nil
    }
}

final class ChatSearchNavigationButtonsView: UIView {
    struct RenderState: Equatable {
        let isVisible: Bool
        let isPreviousEnabled: Bool
        let isNextEnabled: Bool
        let isBusy: Bool

        static let hidden = RenderState(
            isVisible: false,
            isPreviousEnabled: false,
            isNextEnabled: false,
            isBusy: false
        )
    }

    let previousButton: UIButton = ChatSearchExpandedHitButton(type: .system)
    let nextButton: UIButton = ChatSearchExpandedHitButton(type: .system)

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private var baseAnimationSpec: ChatSearchAnimationSpec
    private var animationSpec: ChatSearchAnimationSpec
    private let localization: ChatSearchLocalization
    private(set) var adaptiveEnvironment = ChatSearchAdaptiveEnvironment.standard
    var resolvedAnimationSpec: ChatSearchAnimationSpec { animationSpec }
    private(set) var renderState: RenderState = .hidden
    private(set) var lastVisibilityTransition: ChatSearchAnimationSpec.Transition?

    override init(frame: CGRect) {
        localization = .production()
        animationSpec = ChatSearchAnimationSpec.production.resolved(
            for: .init(
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                reduceTransparency: UIAccessibility.isReduceTransparencyEnabled
            )
        )
        baseAnimationSpec = animationSpec
        super.init(frame: frame)
        setup()
    }

    init(
        frame: CGRect,
        animationSpec: ChatSearchAnimationSpec,
        localization: ChatSearchLocalization = .production()
    ) {
        self.animationSpec = animationSpec
        self.baseAnimationSpec = animationSpec
        self.localization = localization
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        localization = .production()
        animationSpec = ChatSearchAnimationSpec.production.resolved(
            for: .init(
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                reduceTransparency: UIAccessibility.isReduceTransparencyEnabled
            )
        )
        baseAnimationSpec = animationSpec
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: CGSize {
        ChatSearchNavigationButtonsLayout.stackSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = ChatSearchNavigationButtonsLayout.buttonFrames(in: bounds)
        previousButton.frame = frames.previous
        nextButton.frame = frames.next
        [previousButton, nextButton].forEach {
            $0.updateChatSearchAccessibilityFrame()
            if adaptiveEnvironment.reduceTransparency {
                $0.layer.cornerRadius = ChatSearchNavigationButtonsLayout.buttonSize / 2
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        [previousButton, nextButton].forEach {
            $0.updateChatSearchAccessibilityFrame()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.accessibilityContrast != traitCollection.accessibilityContrast ||
                previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle ||
                previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
            return
        }
        applyAdaptiveEnvironment(.current(for: self))
    }

    func applyAdaptiveEnvironment(_ environment: ChatSearchAdaptiveEnvironment) {
        adaptiveEnvironment = environment
        semanticContentAttribute = environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        animationSpec = baseAnimationSpec.resolved(
            for: environment.animationPreferences
        )
        ChatSearchAdaptiveAppearance.applyDetachedButton(
            previousButton,
            environment: environment
        )
        ChatSearchAdaptiveAppearance.applyDetachedButton(
            nextButton,
            environment: environment
        )
        setNeedsLayout()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else {
            return false
        }
        return previousButton.frame.contains(point) || nextButton.frame.contains(point)
    }

    func render(_ state: RenderState, animated: Bool) {
        let wasVisible = renderState.isVisible
        renderState = state
        previousButton.isEnabled = state.isVisible && state.isPreviousEnabled
        nextButton.isEnabled = state.isVisible && state.isNextEnabled
        updateAccessibilityState()

        guard state.isVisible != wasVisible else {
            if !state.isVisible {
                applyHiddenState()
            }
            return
        }

        let transition = animationSpec.floatingButtons
        lastVisibilityTransition = transition
        if state.isVisible {
            isHidden = false
            isUserInteractionEnabled = true
            applyInitialState(for: transition)
            animate(transition: transition, animated: animated) { [weak self] in
                self?.alpha = 1
                self?.transform = .identity
            }
        } else {
            isUserInteractionEnabled = false
            animate(transition: transition, animated: animated, animations: { [weak self] in
                self?.alpha = CGFloat(transition.alpha?.from ?? 0)
                if let scale = transition.scale?.from {
                    self?.transform = CGAffineTransform(scaleX: scale, y: scale)
                }
            }, completion: { [weak self] in
                self?.applyHiddenState()
            })
        }
    }

    func cleanupAnimations(finalState state: RenderState) {
        layer.removeAllAnimations()
        previousButton.layer.removeAllAnimations()
        nextButton.layer.removeAllAnimations()
        renderState = state
        previousButton.isEnabled = state.isVisible && state.isPreviousEnabled
        nextButton.isEnabled = state.isVisible && state.isNextEnabled
        updateAccessibilityState()
        if state.isVisible {
            isHidden = false
            isUserInteractionEnabled = true
            alpha = 1
            transform = .identity
        } else {
            applyHiddenState()
        }
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        accessibilityIdentifier = "chat_search_navigation_buttons"
        isAccessibilityElement = false
        accessibilityElements = [previousButton, nextButton]

        configure(
            previousButton,
            imageName: "chevron.up",
            identifier: ChatSearchAccessibilityIdentifier.previousResult,
            label: localization.text(.previousResult)
        )
        configure(
            nextButton,
            imageName: "chevron.down",
            identifier: ChatSearchAccessibilityIdentifier.nextResult,
            label: localization.text(.nextResult)
        )
        addSubview(previousButton)
        addSubview(nextButton)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        applyAdaptiveEnvironment(.current(for: self))
        applyHiddenState()
    }

    private func configure(
        _ button: UIButton,
        imageName: String,
        identifier: String,
        label: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = true
        button.setImage(imageLiteral(imageName, dimension: 18), for: .normal)
        button.tintColor = NativeGlassBarStyle.iconTintColor
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor
        )
        button.translatesAutoresizingMaskIntoConstraints = true
    }

    private func applyInitialState(for transition: ChatSearchAnimationSpec.Transition) {
        alpha = CGFloat(transition.alpha?.from ?? 1)
        if let scale = transition.scale?.from {
            transform = CGAffineTransform(scaleX: scale, y: scale)
        } else {
            transform = .identity
        }
    }

    private func applyHiddenState() {
        layer.removeAllAnimations()
        isHidden = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        alpha = 0
        transform = .identity
    }

    private func updateAccessibilityState() {
        accessibilityElementsHidden = !renderState.isVisible
        guard renderState.isVisible else {
            previousButton.accessibilityValue = nil
            nextButton.accessibilityValue = nil
            return
        }
        if renderState.isBusy {
            let loading = localization.text(.loading)
            previousButton.accessibilityValue = loading
            nextButton.accessibilityValue = loading
            return
        }
        previousButton.accessibilityValue = renderState.isPreviousEnabled
            ? localization.text(.olderMessage)
            : localization.text(.noOlderResults)
        nextButton.accessibilityValue = renderState.isNextEnabled
            ? localization.text(.newerMessage)
            : localization.text(.noNewerResults)
    }

    private func animate(
        transition: ChatSearchAnimationSpec.Transition,
        animated: Bool,
        animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        let duration = transition.alpha?.timing.duration ??
            transition.scale?.timing.duration ?? 0
        guard animated, duration > 0, window != nil else {
            animations()
            completion?()
            return
        }

        let timing = transition.alpha?.timing ?? transition.scale?.timing
        switch timing?.curve {
        case .spring(let spring):
            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: spring.dampingRatio,
                initialSpringVelocity: spring.initialVelocity,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: { _ in completion?() }
            )
        case .easeInOut:
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: { _ in completion?() }
            )
        case .linear:
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: { _ in completion?() }
            )
        case .easeOut, .none:
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: { _ in completion?() }
            )
        }
    }

    @objc
    private func previousTapped() {
        guard previousButton.isEnabled else { return }
        onPrevious?()
    }

    @objc
    private func nextTapped() {
        guard nextButton.isEnabled else { return }
        onNext?()
    }
}
