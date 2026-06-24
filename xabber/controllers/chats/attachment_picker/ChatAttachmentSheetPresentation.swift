import UIKit

protocol ChatAttachmentSheetAnchorProviding: AnyObject {
    func chatAttachmentSheetComposerTopY(in containerView: UIView) -> CGFloat?
}

enum ChatAttachmentSheetPresentationState: Equatable {
    case compact
    case expanded
}

protocol ChatAttachmentSheetPresentationStateObserving: AnyObject {
    func chatAttachmentSheetPresentationStateDidChange(_ state: ChatAttachmentSheetPresentationState)
}

protocol ChatAttachmentSheetPresentationRequesting: AnyObject {
    var onSheetPresentationStateRequested: ((ChatAttachmentSheetPresentationState) -> Void)? { get set }
    var onDismissRequested: (() -> Void)? { get set }
}

enum ChatAttachmentSheetPanResolution: Equatable {
    case compact
    case expanded
    case dismiss
}

enum ChatAttachmentSheetDimmingPolicy {
    static let backgroundColor = UIColor.black.withAlphaComponent(0.2)
    static let hiddenAlpha: CGFloat = 0
    static let visibleAlpha: CGFloat = 1
}

enum ChatAttachmentSheetTransitionFramePolicy {
    static func presentationStartFrame(finalFrame: CGRect, containerBounds: CGRect) -> CGRect {
        var startFrame = finalFrame
        startFrame.origin.y = containerBounds.maxY
        return startFrame
    }

    static func dismissalEndFrame(currentFrame: CGRect, containerBounds: CGRect) -> CGRect {
        var dismissedFrame = currentFrame
        dismissedFrame.origin.y = containerBounds.maxY
        return dismissedFrame
    }
}

enum ChatAttachmentSheetTransitionLayoutPolicy {
    static func shouldApplyPresentedFrame(
        isPresentationTransitionActive: Bool,
        isDismissalTransitionActive: Bool,
        isInteractivePanActive: Bool = false
    ) -> Bool {
        !isPresentationTransitionActive && !isDismissalTransitionActive && !isInteractivePanActive
    }
}

enum ChatAttachmentSheetScrollHandoffPolicy {
    private static let verticalDominanceRatio: CGFloat = 1.2
    private static let topTolerance: CGFloat = 0.5

    static func shouldBegin(
        velocity: CGPoint,
        touchedScrollViewContentOffsetY: CGFloat?,
        touchedScrollViewAdjustedContentInsetTop: CGFloat = 0
    ) -> Bool {
        guard isDownwardVertical(velocity: velocity) else {
            return false
        }

        guard let touchedScrollViewContentOffsetY else {
            return true
        }

        return isAtTop(
            contentOffsetY: touchedScrollViewContentOffsetY,
            adjustedContentInsetTop: touchedScrollViewAdjustedContentInsetTop
        )
    }

    static func shouldRecognizeSimultaneously(
        isSheetPanGesture: Bool,
        isTouchedScrollViewPanGesture: Bool,
        velocity: CGPoint,
        touchedScrollViewContentOffsetY: CGFloat,
        touchedScrollViewAdjustedContentInsetTop: CGFloat
    ) -> Bool {
        guard isSheetPanGesture,
              isTouchedScrollViewPanGesture else {
            return false
        }

        return shouldBegin(
            velocity: velocity,
            touchedScrollViewContentOffsetY: touchedScrollViewContentOffsetY,
            touchedScrollViewAdjustedContentInsetTop: touchedScrollViewAdjustedContentInsetTop
        )
    }

    static func clampedContentOffsetYForActiveHandoff(
        currentContentOffsetY: CGFloat,
        adjustedContentInsetTop: CGFloat
    ) -> CGFloat {
        _ = currentContentOffsetY
        return topContentOffsetY(adjustedContentInsetTop: adjustedContentInsetTop)
    }

    static func scrollEnabledDuringActiveHandoff(originalIsScrollEnabled: Bool) -> Bool {
        _ = originalIsScrollEnabled
        return false
    }

    static func restoredScrollEnabledAfterHandoff(originalIsScrollEnabled: Bool) -> Bool {
        originalIsScrollEnabled
    }

    static func isAtTop(contentOffsetY: CGFloat, adjustedContentInsetTop: CGFloat) -> Bool {
        contentOffsetY <= topContentOffsetY(adjustedContentInsetTop: adjustedContentInsetTop) + topTolerance
    }

    private static func isDownwardVertical(velocity: CGPoint) -> Bool {
        guard velocity.y > 0 else {
            return false
        }

        return abs(velocity.y) >= max(1, abs(velocity.x)) * verticalDominanceRatio
    }

    private static func topContentOffsetY(adjustedContentInsetTop: CGFloat) -> CGFloat {
        -adjustedContentInsetTop
    }
}

enum ChatAttachmentSheetPanActivationPolicy {
    static func shouldBegin(
        velocity: CGPoint,
        touchedScrollViewContentOffsetY: CGFloat?,
        touchedScrollViewAdjustedContentInsetTop: CGFloat = 0
    ) -> Bool {
        ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
            velocity: velocity,
            touchedScrollViewContentOffsetY: touchedScrollViewContentOffsetY,
            touchedScrollViewAdjustedContentInsetTop: touchedScrollViewAdjustedContentInsetTop
        )
    }
}

enum ChatAttachmentSheetLayoutPolicy {
    static func frame(
        for state: ChatAttachmentSheetPresentationState,
        containerBounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        composerTopY: CGFloat?,
        horizontalSizeClass: UIUserInterfaceSizeClass,
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) -> CGRect {
        guard containerBounds.width > 0, containerBounds.height > 0 else {
            return .zero
        }

        let safeTop = containerBounds.minY + max(0, safeAreaInsets.top)
        let safeLeft = containerBounds.minX + max(0, safeAreaInsets.left)
        let safeRight = containerBounds.maxX - max(0, safeAreaInsets.right)
        let bottomY = containerBounds.maxY
        let availableHeight = max(0, bottomY - safeTop)
        let cappedHeight: CGFloat
        if userInterfaceIdiom == .phone {
            cappedHeight = min(availableHeight, containerBounds.height * 0.75)
        } else {
            cappedHeight = availableHeight
        }
        _ = composerTopY
        _ = state

        let availableWidth = max(0, safeRight - safeLeft)
        let width = availableWidth
        let x = safeLeft + ((availableWidth - width) / 2)
        let y = bottomY - cappedHeight
        _ = horizontalSizeClass

        return CGRect(x: x, y: y, width: width, height: cappedHeight)
    }
}

enum ChatAttachmentSheetInteractiveFramePolicy {
    static func frame(
        startFrame: CGRect,
        translationY: CGFloat,
        expandedFrame: CGRect,
        bottomY: CGFloat
    ) -> CGRect {
        let downwardTranslation = max(0, translationY)
        let proposedY = startFrame.minY + downwardTranslation
        let y = min(max(expandedFrame.minY, proposedY), bottomY)
        return CGRect(
            x: expandedFrame.minX,
            y: y,
            width: expandedFrame.width,
            height: max(0, bottomY - y)
        )
    }
}

enum ChatAttachmentSheetPanResolutionPolicy {
    static func resolution(
        currentState: ChatAttachmentSheetPresentationState,
        translationY: CGFloat,
        velocityY: CGFloat,
        compactFrame: CGRect,
        expandedFrame: CGRect
    ) -> ChatAttachmentSheetPanResolution {
        _ = currentState
        let sheetHeight = max(compactFrame.height, expandedFrame.height)
        let distanceThreshold = min(max(sheetHeight * 0.18, 96), 180)
        let fastDismissVelocity: CGFloat = 1100

        if translationY > 0, velocityY >= fastDismissVelocity {
            return .dismiss
        }

        if translationY >= distanceThreshold {
            return .dismiss
        }

        return .expanded
    }
}

final class ChatAttachmentSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    private weak var anchorProvider: ChatAttachmentSheetAnchorProviding?
    private(set) weak var presentationController: ChatAttachmentSheetPresentationController?

    init(anchorProvider: ChatAttachmentSheetAnchorProviding?) {
        self.anchorProvider = anchorProvider
        super.init()
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        let presentationController = ChatAttachmentSheetPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            anchorProvider: anchorProvider
        )
        self.presentationController = presentationController
        return presentationController
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        ChatAttachmentSheetAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        ChatAttachmentSheetAnimator(isPresenting: false)
    }
}

final class ChatAttachmentSheetPresentationController: UIPresentationController, UIGestureRecognizerDelegate {
    private weak var anchorProvider: ChatAttachmentSheetAnchorProviding?
    private let outsideTapView = UIControl()
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private weak var activeHandoffScrollView: UIScrollView?
    private var activeHandoffScrollViewWasScrollEnabled: Bool?
    private var panStartFrame: CGRect = .zero
    private var isObservingKeyboard = false
    private var isPresentationTransitionActive = false
    private var isDismissalTransitionActive = false
    private var isInteractivePanActive = false

    private(set) var state: ChatAttachmentSheetPresentationState = .expanded

    init(
        presentedViewController: UIViewController,
        presenting presentingViewController: UIViewController?,
        anchorProvider: ChatAttachmentSheetAnchorProviding?
    ) {
        self.anchorProvider = anchorProvider
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else {
            return .zero
        }

        return ChatAttachmentSheetLayoutPolicy.frame(
            for: state,
            containerBounds: containerView.bounds,
            safeAreaInsets: containerView.safeAreaInsets,
            composerTopY: anchorProvider?.chatAttachmentSheetComposerTopY(in: containerView),
            horizontalSizeClass: containerView.traitCollection.horizontalSizeClass,
            userInterfaceIdiom: containerView.traitCollection.userInterfaceIdiom
        )
    }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        isPresentationTransitionActive = true
        installOutsideTapView()
        installPanGestureIfNeeded()
        startObservingKeyboardIfNeeded()
        animateDimming(to: ChatAttachmentSheetDimmingPolicy.visibleAlpha)
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        isPresentationTransitionActive = false

        if completed {
            outsideTapView.alpha = ChatAttachmentSheetDimmingPolicy.visibleAlpha
            presentedView?.frame = frameOfPresentedViewInContainerView
        } else {
            cleanupPresentationState()
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        outsideTapView.frame = containerView?.bounds ?? .zero
        guard ChatAttachmentSheetTransitionLayoutPolicy.shouldApplyPresentedFrame(
            isPresentationTransitionActive: isPresentationTransitionActive,
            isDismissalTransitionActive: isDismissalTransitionActive,
            isInteractivePanActive: isInteractivePanActive
        ) else {
            return
        }

        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        isDismissalTransitionActive = true
        animateDimming(to: ChatAttachmentSheetDimmingPolicy.hiddenAlpha)
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        isDismissalTransitionActive = false

        if completed {
            cleanupPresentationState()
        } else {
            outsideTapView.alpha = ChatAttachmentSheetDimmingPolicy.visibleAlpha
            presentedView?.frame = frameOfPresentedViewInContainerView
        }
    }

    private func cleanupPresentationState() {
        outsideTapView.removeFromSuperview()
        if let panGestureRecognizer {
            presentedViewController.view.removeGestureRecognizer(panGestureRecognizer)
        }
        restoreActiveHandoffScrollViewIfNeeded()
        isInteractivePanActive = false
        self.panGestureRecognizer = nil
        stopObservingKeyboard()
    }

    private func animateDimming(to alpha: CGFloat) {
        guard outsideTapView.superview != nil else {
            return
        }

        let updates = {
            self.outsideTapView.alpha = alpha
        }

        if let transitionCoordinator = presentedViewController.transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: { _ in
                updates()
            }, completion: nil)
        } else {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: updates,
                completion: nil
            )
        }
    }

    func setState(
        _ state: ChatAttachmentSheetPresentationState,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        let resolvedState: ChatAttachmentSheetPresentationState = .expanded
        self.state = resolvedState
        (presentedViewController as? ChatAttachmentSheetPresentationStateObserving)?
            .chatAttachmentSheetPresentationStateDidChange(resolvedState)

        guard let presentedView else {
            completion?()
            return
        }

        let updates = {
            presentedView.frame = self.frameOfPresentedViewInContainerView
        }

        if animated {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: updates,
                completion: { _ in
                    completion?()
                }
            )
        } else {
            updates()
            completion?()
        }
    }

    @objc
    func dismissFromOutsideTap() {
        presentedViewController.view.endEditing(true)
        presentedViewController.dismiss(animated: true, completion: nil)
    }

    private func installOutsideTapView() {
        guard outsideTapView.superview == nil,
              let containerView else {
            return
        }

        outsideTapView.backgroundColor = ChatAttachmentSheetDimmingPolicy.backgroundColor
        outsideTapView.alpha = ChatAttachmentSheetDimmingPolicy.hiddenAlpha
        outsideTapView.addTarget(self, action: #selector(dismissFromOutsideTap), for: .touchUpInside)
        outsideTapView.frame = containerView.bounds
        containerView.insertSubview(outsideTapView, at: 0)
    }

    private func installPanGestureIfNeeded() {
        guard panGestureRecognizer == nil else {
            return
        }

        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        presentedViewController.view.addGestureRecognizer(recognizer)
        panGestureRecognizer = recognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer,
              let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let touchedScrollView = scrollViewContainingInitialTouch(for: panGestureRecognizer)
        let shouldBegin = ChatAttachmentSheetPanActivationPolicy.shouldBegin(
            velocity: panGestureRecognizer.velocity(in: presentedViewController.view),
            touchedScrollViewContentOffsetY: touchedScrollView?.contentOffset.y,
            touchedScrollViewAdjustedContentInsetTop: touchedScrollView?.adjustedContentInset.top ?? 0
        )
        if shouldBegin, let touchedScrollView {
            beginActiveHandoff(with: touchedScrollView)
        } else {
            restoreActiveHandoffScrollViewIfNeeded()
        }
        return shouldBegin
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let sheetPanGestureRecognizer: UIPanGestureRecognizer?
        let pairedGestureRecognizer: UIGestureRecognizer

        if gestureRecognizer === panGestureRecognizer {
            sheetPanGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer
            pairedGestureRecognizer = otherGestureRecognizer
        } else if otherGestureRecognizer === panGestureRecognizer {
            sheetPanGestureRecognizer = otherGestureRecognizer as? UIPanGestureRecognizer
            pairedGestureRecognizer = gestureRecognizer
        } else {
            return false
        }

        guard let sheetPanGestureRecognizer,
              let touchedScrollView = scrollViewContainingInitialTouch(for: sheetPanGestureRecognizer) else {
            return false
        }

        let shouldRecognize = ChatAttachmentSheetScrollHandoffPolicy.shouldRecognizeSimultaneously(
            isSheetPanGesture: true,
            isTouchedScrollViewPanGesture: pairedGestureRecognizer === touchedScrollView.panGestureRecognizer,
            velocity: sheetPanGestureRecognizer.velocity(in: presentedViewController.view),
            touchedScrollViewContentOffsetY: touchedScrollView.contentOffset.y,
            touchedScrollViewAdjustedContentInsetTop: touchedScrollView.adjustedContentInset.top
        )
        if shouldRecognize {
            beginActiveHandoff(with: touchedScrollView)
        }
        return shouldRecognize
    }

    private func scrollViewContainingInitialTouch(for gestureRecognizer: UIGestureRecognizer) -> UIScrollView? {
        let location = gestureRecognizer.location(in: presentedViewController.view)
        var currentView = presentedViewController.view.hitTest(location, with: nil)

        while let view = currentView {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }

            currentView = view.superview
        }

        return nil
    }

    private func startObservingKeyboardIfNeeded() {
        guard !isObservingKeyboard else {
            return
        }

        isObservingKeyboard = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func stopObservingKeyboard() {
        guard isObservingKeyboard else {
            return
        }

        NotificationCenter.default.removeObserver(self)
        isObservingKeyboard = false
    }

    @objc
    private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let containerView,
              let presentedView else {
            return
        }

        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curveValue = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
        let options = curveValue
            .map { UIView.AnimationOptions(rawValue: $0 << 16).union(.beginFromCurrentState) }
            ?? [.beginFromCurrentState, .curveEaseInOut]

        let updates = {
            presentedView.frame = self.frameOfPresentedViewInContainerView
            containerView.layoutIfNeeded()
        }

        if duration > 0 {
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: options,
                animations: updates,
                completion: nil
            )
        } else {
            updates()
        }
    }

    @objc
    private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let presentedView else {
            return
        }

        let compactFrame = frame(for: .compact)
        let expandedFrame = frame(for: .expanded)

        switch recognizer.state {
        case .began:
            panStartFrame = presentedView.frame
            isInteractivePanActive = true
            if activeHandoffScrollView == nil {
                updateActiveHandoffScrollView(for: recognizer)
            }
            clampActiveHandoffScrollViewIfNeeded()
        case .changed:
            clampActiveHandoffScrollViewIfNeeded()
            let translationY = recognizer.translation(in: containerView).y
            presentedView.frame = interactiveFrame(
                startFrame: panStartFrame,
                translationY: translationY,
                compactFrame: compactFrame,
                expandedFrame: expandedFrame
            )
        case .ended:
            let translationY = recognizer.translation(in: containerView).y
            let velocityY = recognizer.velocity(in: containerView).y
            let resolution = ChatAttachmentSheetPanResolutionPolicy.resolution(
                currentState: state,
                translationY: translationY,
                velocityY: velocityY,
                compactFrame: compactFrame,
                expandedFrame: expandedFrame
            )
            restoreActiveHandoffScrollViewIfNeeded()
            resolvePan(resolution)
        case .cancelled, .failed:
            restoreActiveHandoffScrollViewIfNeeded()
            resolvePan(.expanded)
        default:
            break
        }
    }

    private func updateActiveHandoffScrollView(for recognizer: UIPanGestureRecognizer) {
        guard let touchedScrollView = scrollViewContainingInitialTouch(for: recognizer),
              ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
                velocity: recognizer.velocity(in: presentedViewController.view),
                touchedScrollViewContentOffsetY: touchedScrollView.contentOffset.y,
                touchedScrollViewAdjustedContentInsetTop: touchedScrollView.adjustedContentInset.top
              ) else {
            activeHandoffScrollView = nil
            return
        }

        beginActiveHandoff(with: touchedScrollView)
    }

    private func clampActiveHandoffScrollViewIfNeeded() {
        guard let activeHandoffScrollView else {
            return
        }

        let clampedOffsetY = ChatAttachmentSheetScrollHandoffPolicy.clampedContentOffsetYForActiveHandoff(
            currentContentOffsetY: activeHandoffScrollView.contentOffset.y,
            adjustedContentInsetTop: activeHandoffScrollView.adjustedContentInset.top
        )
        guard abs(activeHandoffScrollView.contentOffset.y - clampedOffsetY) > 0.001 else {
            return
        }

        var clampedOffset = activeHandoffScrollView.contentOffset
        clampedOffset.y = clampedOffsetY
        activeHandoffScrollView.setContentOffset(clampedOffset, animated: false)
    }

    private func beginActiveHandoff(with scrollView: UIScrollView) {
        if activeHandoffScrollView !== scrollView {
            restoreActiveHandoffScrollViewIfNeeded()
            activeHandoffScrollView = scrollView
            activeHandoffScrollViewWasScrollEnabled = scrollView.isScrollEnabled
        }

        scrollView.isScrollEnabled = ChatAttachmentSheetScrollHandoffPolicy.scrollEnabledDuringActiveHandoff(
            originalIsScrollEnabled: activeHandoffScrollViewWasScrollEnabled ?? scrollView.isScrollEnabled
        )
        clampActiveHandoffScrollViewIfNeeded()
    }

    private func restoreActiveHandoffScrollViewIfNeeded() {
        guard let activeHandoffScrollView,
              let activeHandoffScrollViewWasScrollEnabled else {
            self.activeHandoffScrollView = nil
            self.activeHandoffScrollViewWasScrollEnabled = nil
            return
        }

        activeHandoffScrollView.isScrollEnabled = ChatAttachmentSheetScrollHandoffPolicy
            .restoredScrollEnabledAfterHandoff(
                originalIsScrollEnabled: activeHandoffScrollViewWasScrollEnabled
            )
        self.activeHandoffScrollView = nil
        self.activeHandoffScrollViewWasScrollEnabled = nil
    }

    private func frame(for state: ChatAttachmentSheetPresentationState) -> CGRect {
        guard let containerView else {
            return .zero
        }

        return ChatAttachmentSheetLayoutPolicy.frame(
            for: state,
            containerBounds: containerView.bounds,
            safeAreaInsets: containerView.safeAreaInsets,
            composerTopY: anchorProvider?.chatAttachmentSheetComposerTopY(in: containerView),
            horizontalSizeClass: containerView.traitCollection.horizontalSizeClass,
            userInterfaceIdiom: containerView.traitCollection.userInterfaceIdiom
        )
    }

    private func interactiveFrame(
        startFrame: CGRect,
        translationY: CGFloat,
        compactFrame: CGRect,
        expandedFrame: CGRect
    ) -> CGRect {
        ChatAttachmentSheetInteractiveFramePolicy.frame(
            startFrame: startFrame,
            translationY: translationY,
            expandedFrame: expandedFrame,
            bottomY: compactFrame.maxY
        )
    }

    private func resolvePan(_ resolution: ChatAttachmentSheetPanResolution) {
        switch resolution {
        case .compact:
            setState(.expanded, animated: true) { [weak self] in
                self?.isInteractivePanActive = false
            }
        case .expanded:
            setState(.expanded, animated: true) { [weak self] in
                self?.isInteractivePanActive = false
            }
        case .dismiss:
            animateDismissFromPan()
        }
    }

    private func animateDismissFromPan() {
        guard let containerView,
              let presentedView else {
            isInteractivePanActive = false
            dismissFromOutsideTap()
            return
        }

        presentedViewController.view.endEditing(true)
        let dismissedFrame = ChatAttachmentSheetTransitionFramePolicy.dismissalEndFrame(
            currentFrame: presentedView.frame,
            containerBounds: containerView.bounds
        )
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                presentedView.frame = dismissedFrame
                self.outsideTapView.alpha = ChatAttachmentSheetDimmingPolicy.hiddenAlpha
            },
            completion: { [weak self] _ in
                guard let self else {
                    return
                }
                self.isInteractivePanActive = false
                self.presentedViewController.dismiss(animated: false, completion: nil)
            }
        )
    }
}

private final class ChatAttachmentSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.28 : 0.22
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresentation(using: transitionContext)
        } else {
            animateDismissal(using: transitionContext)
        }
    }

    private func animatePresentation(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toView = transitionContext.view(forKey: .to),
              let toViewController = transitionContext.viewController(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }

        let finalFrame = transitionContext.finalFrame(for: toViewController)
        let startFrame = ChatAttachmentSheetTransitionFramePolicy.presentationStartFrame(
            finalFrame: finalFrame,
            containerBounds: transitionContext.containerView.bounds
        )

        toView.frame = startFrame
        transitionContext.containerView.addSubview(toView)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: {
                toView.frame = finalFrame
            },
            completion: { completed in
                transitionContext.completeTransition(completed && !transitionContext.transitionWasCancelled)
            }
        )
    }

    private func animateDismissal(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromView = transitionContext.view(forKey: .from) else {
            transitionContext.completeTransition(false)
            return
        }

        let finalFrame = ChatAttachmentSheetTransitionFramePolicy.dismissalEndFrame(
            currentFrame: fromView.frame,
            containerBounds: transitionContext.containerView.bounds
        )

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                fromView.frame = finalFrame
            },
            completion: { completed in
                transitionContext.completeTransition(completed && !transitionContext.transitionWasCancelled)
            }
        )
    }
}
