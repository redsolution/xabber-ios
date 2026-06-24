import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentSheetPresentationTests: XCTestCase {
    private let phoneBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let phoneSafeArea = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)

    func testCompactFrameUsesIPhoneThreeQuarterBottomOriginGeometry() {
        let frame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        let expandedFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .expanded,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(frame, expandedFrame)
        XCTAssertEqual(frame.height, phoneBounds.height * 0.75, accuracy: 0.001)
        XCTAssertEqual(frame.minY, phoneBounds.maxY - (phoneBounds.height * 0.75), accuracy: 0.001)
        XCTAssertEqual(frame.maxY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.width, phoneBounds.width, accuracy: 0.001)
    }

    func testExpandedFrameCapsIPhoneHeightAtThreeQuarters() {
        let frame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .expanded,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(frame.height, phoneBounds.height * 0.75, accuracy: 0.001)
        XCTAssertEqual(frame.minY, phoneBounds.maxY - (phoneBounds.height * 0.75), accuracy: 0.001)
        XCTAssertEqual(frame.maxY, phoneBounds.maxY, accuracy: 0.001)
    }

    func testLandscapePhoneFrameCapsHeightAtThreeQuarters() {
        let landscapeBounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let landscapeSafeArea = UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 47)

        let frame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: landscapeBounds,
            safeAreaInsets: landscapeSafeArea,
            composerTopY: 330,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(frame.height, landscapeBounds.height * 0.75, accuracy: 0.001)
        XCTAssertEqual(frame.minY, landscapeBounds.maxY - (landscapeBounds.height * 0.75), accuracy: 0.001)
        XCTAssertEqual(frame.maxY, landscapeBounds.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(frame.height, 0)
    }

    func testPadFrameKeepsFullAvailableHeightAndWidth() {
        let iPadBounds = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let iPadSafeArea = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)

        let frame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: iPadBounds,
            safeAreaInsets: iPadSafeArea,
            composerTopY: 1250,
            horizontalSizeClass: .regular,
            userInterfaceIdiom: .pad
        )

        XCTAssertEqual(frame.height, iPadBounds.height - iPadSafeArea.top, accuracy: 0.001)
        XCTAssertEqual(frame.minY, iPadSafeArea.top, accuracy: 0.001)
        XCTAssertEqual(frame.width, iPadBounds.width, accuracy: 0.001)
        XCTAssertEqual(frame.midX, iPadBounds.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, iPadBounds.maxY, accuracy: 0.001)
    }

    func testComposerAnchorChangesRecomputeFrameWithoutChangingState() {
        let initialFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )
        let keyboardFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 460,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(initialFrame.maxY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(keyboardFrame.maxY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(keyboardFrame, initialFrame)
    }

    func testPresentationTransitionFrameStartsBelowContainerBottom() {
        let finalFrame = CGRect(x: 0, y: 211, width: 390, height: 633)

        let startFrame = ChatAttachmentSheetTransitionFramePolicy.presentationStartFrame(
            finalFrame: finalFrame,
            containerBounds: phoneBounds
        )

        XCTAssertEqual(startFrame.minY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(startFrame.maxY, phoneBounds.maxY + finalFrame.height, accuracy: 0.001)
        XCTAssertEqual(startFrame.width, finalFrame.width, accuracy: 0.001)
        XCTAssertEqual(startFrame.height, finalFrame.height, accuracy: 0.001)
    }

    func testDismissalTransitionFrameMovesBelowContainerBottom() {
        let currentFrame = CGRect(x: 0, y: 211, width: 390, height: 633)

        let dismissedFrame = ChatAttachmentSheetTransitionFramePolicy.dismissalEndFrame(
            currentFrame: currentFrame,
            containerBounds: phoneBounds
        )

        XCTAssertEqual(dismissedFrame.minY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(dismissedFrame.maxY, phoneBounds.maxY + currentFrame.height, accuracy: 0.001)
        XCTAssertEqual(dismissedFrame.width, currentFrame.width, accuracy: 0.001)
        XCTAssertEqual(dismissedFrame.height, currentFrame.height, accuracy: 0.001)
    }

    func testTransitionLayoutPolicyDoesNotApplyFinalFrameDuringActiveTransitions() {
        XCTAssertFalse(
            ChatAttachmentSheetTransitionLayoutPolicy.shouldApplyPresentedFrame(
                isPresentationTransitionActive: true,
                isDismissalTransitionActive: false
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetTransitionLayoutPolicy.shouldApplyPresentedFrame(
                isPresentationTransitionActive: false,
                isDismissalTransitionActive: true
            )
        )
        XCTAssertTrue(
            ChatAttachmentSheetTransitionLayoutPolicy.shouldApplyPresentedFrame(
                isPresentationTransitionActive: false,
                isDismissalTransitionActive: false
            )
        )
    }

    func testTransitionLayoutPolicyDoesNotApplyFinalFrameDuringActiveInteractivePan() {
        XCTAssertFalse(
            ChatAttachmentSheetTransitionLayoutPolicy.shouldApplyPresentedFrame(
                isPresentationTransitionActive: false,
                isDismissalTransitionActive: false,
                isInteractivePanActive: true
            )
        )
    }

    func testDimmingPolicyUsesLegacyAttachmentPickerOpacity() {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        ChatAttachmentSheetDimmingPolicy.backgroundColor.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        )

        XCTAssertEqual(red, 0, accuracy: 0.001)
        XCTAssertEqual(green, 0, accuracy: 0.001)
        XCTAssertEqual(blue, 0, accuracy: 0.001)
        XCTAssertEqual(alpha, 0.2, accuracy: 0.001)
        XCTAssertEqual(ChatAttachmentSheetDimmingPolicy.hiddenAlpha, 0, accuracy: 0.001)
        XCTAssertEqual(ChatAttachmentSheetDimmingPolicy.visibleAlpha, 1, accuracy: 0.001)
    }

    func testTransitioningDelegateProvidesSheetAnimators() {
        let transitioningDelegate = ChatAttachmentSheetTransitioningDelegate(anchorProvider: nil)
        let presented = UIViewController()
        let presenting = UIViewController()

        let presentationAnimator = transitioningDelegate.animationController(
            forPresented: presented,
            presenting: presenting,
            source: presenting
        )
        let dismissalAnimator = transitioningDelegate.animationController(forDismissed: presented)

        XCTAssertNotNil(presentationAnimator)
        XCTAssertNotNil(dismissalAnimator)
    }

    func testPanResolutionDismissesCappedSheetAfterDownwardDistanceThreshold() {
        let compactFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )
        let expandedFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .expanded,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(
            ChatAttachmentSheetPanResolutionPolicy.resolution(
                currentState: .expanded,
                translationY: 160,
                velocityY: 0,
                compactFrame: compactFrame,
                expandedFrame: expandedFrame
            ),
            .dismiss
        )
    }

    func testPanResolutionDismissesCappedSheetAfterFastDownwardFlick() {
        let compactFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )
        let expandedFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .expanded,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(
            ChatAttachmentSheetPanResolutionPolicy.resolution(
                currentState: .expanded,
                translationY: 42,
                velocityY: 1200,
                compactFrame: compactFrame,
                expandedFrame: expandedFrame
            ),
            .dismiss
        )
    }

    func testPanResolutionSnapsBackForSmallOrUpwardCappedSheetDrag() {
        let compactFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .compact,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )
        let expandedFrame = ChatAttachmentSheetLayoutPolicy.frame(
            for: .expanded,
            containerBounds: phoneBounds,
            safeAreaInsets: phoneSafeArea,
            composerTopY: 760,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .phone
        )

        XCTAssertEqual(
            ChatAttachmentSheetPanResolutionPolicy.resolution(
                currentState: .expanded,
                translationY: 64,
                velocityY: 250,
                compactFrame: compactFrame,
                expandedFrame: expandedFrame
            ),
            .expanded
        )
        XCTAssertEqual(
            ChatAttachmentSheetPanResolutionPolicy.resolution(
                currentState: .compact,
                translationY: -220,
                velocityY: 0,
                compactFrame: compactFrame,
                expandedFrame: expandedFrame
            ),
            .expanded
        )
    }

    func testInteractiveFrameShrinksWithDownwardFingerTranslationAndKeepsBottomPinned() {
        let expandedFrame = CGRect(x: 0, y: 211, width: 390, height: 633)
        let draggedFrame = ChatAttachmentSheetInteractiveFramePolicy.frame(
            startFrame: expandedFrame,
            translationY: 128,
            expandedFrame: expandedFrame,
            bottomY: phoneBounds.maxY
        )

        XCTAssertEqual(draggedFrame.minY, expandedFrame.minY + 128, accuracy: 0.001)
        XCTAssertEqual(draggedFrame.height, expandedFrame.height - 128, accuracy: 0.001)
        XCTAssertEqual(draggedFrame.maxY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(draggedFrame.width, expandedFrame.width, accuracy: 0.001)
    }

    func testInteractiveFrameDoesNotGrowAboveExpandedFrameOrBelowBottom() {
        let expandedFrame = CGRect(x: 0, y: 211, width: 390, height: 633)

        let upwardFrame = ChatAttachmentSheetInteractiveFramePolicy.frame(
            startFrame: expandedFrame,
            translationY: -80,
            expandedFrame: expandedFrame,
            bottomY: phoneBounds.maxY
        )
        let fullyPulledFrame = ChatAttachmentSheetInteractiveFramePolicy.frame(
            startFrame: expandedFrame,
            translationY: 900,
            expandedFrame: expandedFrame,
            bottomY: phoneBounds.maxY
        )

        XCTAssertEqual(upwardFrame, expandedFrame)
        XCTAssertEqual(fullyPulledFrame.minY, phoneBounds.maxY, accuracy: 0.001)
        XCTAssertEqual(fullyPulledFrame.height, 0, accuracy: 0.001)
        XCTAssertEqual(fullyPulledFrame.maxY, phoneBounds.maxY, accuracy: 0.001)
    }

    func testPanActivationAllowsDownwardGestureOutsideScrollView() {
        XCTAssertTrue(
            ChatAttachmentSheetPanActivationPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: nil
            )
        )
    }

    func testPanActivationRejectsUpwardAndHorizontalGestures() {
        XCTAssertFalse(
            ChatAttachmentSheetPanActivationPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: -420),
                touchedScrollViewContentOffsetY: nil
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetPanActivationPolicy.shouldBegin(
                velocity: CGPoint(x: 420, y: 120),
                touchedScrollViewContentOffsetY: nil
            )
        )
    }

    func testPanActivationAllowsScrollViewGestureOnlyAtTop() {
        XCTAssertTrue(
            ChatAttachmentSheetPanActivationPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetPanActivationPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: 24,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
    }

    func testScrollHandoffPolicyAllowsDownwardGestureAtScrollTop() {
        XCTAssertTrue(
            ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
        XCTAssertTrue(
            ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: -11.6,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
    }

    func testScrollHandoffPolicyRejectsGestureWhenScrollViewCanScrollUp() {
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: 24,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
    }

    func testScrollHandoffPolicyRejectsUpwardAndHorizontalGestures() {
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
                velocity: CGPoint(x: 0, y: -420),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.shouldBegin(
                velocity: CGPoint(x: 420, y: 120),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
    }

    func testScrollHandoffPolicyAllowsSimultaneousRecognitionOnlyForTouchedScrollViewAtTop() {
        XCTAssertTrue(
            ChatAttachmentSheetScrollHandoffPolicy.shouldRecognizeSimultaneously(
                isSheetPanGesture: true,
                isTouchedScrollViewPanGesture: true,
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.shouldRecognizeSimultaneously(
                isSheetPanGesture: false,
                isTouchedScrollViewPanGesture: true,
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.shouldRecognizeSimultaneously(
                isSheetPanGesture: true,
                isTouchedScrollViewPanGesture: false,
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: -12,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.shouldRecognizeSimultaneously(
                isSheetPanGesture: true,
                isTouchedScrollViewPanGesture: true,
                velocity: CGPoint(x: 0, y: 420),
                touchedScrollViewContentOffsetY: 24,
                touchedScrollViewAdjustedContentInsetTop: 12
            )
        )
    }

    func testScrollHandoffPolicyClampsActiveScrollViewToTopOffset() {
        XCTAssertEqual(
            ChatAttachmentSheetScrollHandoffPolicy.clampedContentOffsetYForActiveHandoff(
                currentContentOffsetY: -80,
                adjustedContentInsetTop: 12
            ),
            -12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatAttachmentSheetScrollHandoffPolicy.clampedContentOffsetYForActiveHandoff(
                currentContentOffsetY: 24,
                adjustedContentInsetTop: 12
            ),
            -12,
            accuracy: 0.001
        )
    }

    func testScrollHandoffPolicySuspendsAndRestoresOriginalScrollEnabledState() {
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.scrollEnabledDuringActiveHandoff(
                originalIsScrollEnabled: true
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.scrollEnabledDuringActiveHandoff(
                originalIsScrollEnabled: false
            )
        )
        XCTAssertTrue(
            ChatAttachmentSheetScrollHandoffPolicy.restoredScrollEnabledAfterHandoff(
                originalIsScrollEnabled: true
            )
        )
        XCTAssertFalse(
            ChatAttachmentSheetScrollHandoffPolicy.restoredScrollEnabledAfterHandoff(
                originalIsScrollEnabled: false
            )
        )
    }

    func testPresentationTransitionInstallsPanRecognizer() {
        let presented = UIViewController()
        presented.loadViewIfNeeded()
        let presenting = UIViewController()
        let presentationController = ChatAttachmentSheetPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            anchorProvider: FixedSheetAnchorProvider(composerTopY: 760)
        )

        XCTAssertFalse(presented.view.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } ?? false)

        presentationController.presentationTransitionWillBegin()

        XCTAssertTrue(presented.view.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } ?? false)

        presentationController.dismissalTransitionDidEnd(true)
    }

    func testGalleryScrollPolicyAlwaysAllowsContentScrollInCappedPicker() {
        XCTAssertEqual(
            ChatAttachmentGalleryScrollExpansionPolicy.resolution(
                displayMode: .compact,
                contentOffsetY: 8
            ),
            .allowContentScroll
        )
        XCTAssertEqual(
            ChatAttachmentGalleryScrollExpansionPolicy.resolution(
                displayMode: .full,
                contentOffsetY: 8
            ),
            .allowContentScroll
        )
        XCTAssertEqual(
            ChatAttachmentGalleryScrollExpansionPolicy.resolution(
                displayMode: .full,
                contentOffsetY: -80
            ),
            .allowContentScroll
        )
    }

    func testOutsideTapUsesPresentedControllerDismissal() {
        let presented = DismissRecordingViewController()
        let presenting = UIViewController()
        let presentationController = ChatAttachmentSheetPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            anchorProvider: FixedSheetAnchorProvider(composerTopY: 760)
        )

        presentationController.dismissFromOutsideTap()

        XCTAssertEqual(presented.dismissCount, 1)
    }

    func testSheetViewControllerEmbedsSourcesBelowGrabber() throws {
        let factory = Task5FakeSourceControllerFactory()
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )

        sheet.loadViewIfNeeded()

        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        XCTAssertTrue(sheet.grabberView.isDescendant(of: sheet.view))
        XCTAssertTrue(sheet.sourceContainerView.isDescendant(of: sheet.view))
        XCTAssertEqual(gallery.view.superview, sheet.sourceContainerView)
    }

    func testSheetRootViewRoundsTopCornersOnly() {
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task5FakeSourceControllerFactory()
        )

        sheet.loadViewIfNeeded()

        XCTAssertEqual(sheet.view.layer.cornerRadius, 18, accuracy: 0.001)
        XCTAssertEqual(
            sheet.view.layer.maskedCorners,
            [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        )
        XCTAssertTrue(sheet.view.layer.masksToBounds)
    }

    func testRepeatedOpenDismissReleasesSheetSourcesAndTransitioningDelegate() throws {
        for _ in 0..<2 {
            let factory = Task5FakeSourceControllerFactory()
            let delegate = Task5FakeFlowDelegate()
            let presenter = UIViewController()
            let coordinator = ChatAttachmentFlowCoordinator(
                presentingViewController: presenter,
                context: Self.makeContext(),
                sourceControllerFactory: factory,
                sheetAnchorProvider: FixedSheetAnchorProvider(composerTopY: 760),
                presentationHandler: { _, _, _, completion in
                    completion?()
                }
            )
            coordinator.delegate = delegate

            coordinator.start()

            let sheet = try XCTUnwrap(coordinator.sheetViewController)
            let gallery = try XCTUnwrap(factory.controller(for: .gallery))
            XCTAssertNotNil(coordinator.sheetTransitioningDelegate)

            coordinator.dismiss(animated: false)

            XCTAssertEqual(delegate.dismissCount, 1)
            XCTAssertNil(coordinator.sheetViewController)
            XCTAssertNil(coordinator.sheetTransitioningDelegate)
            XCTAssertNil(sheet.delegate)
            XCTAssertNil(gallery.parent)
            XCTAssertNil(gallery.onSelectionCountChanged)
        }
    }

    private static func makeContext() -> ChatAttachmentFlowContext {
        ChatAttachmentFlowContext(
            owner: "alice@example.com",
            jid: "bob@example.com",
            conversationType: .regular,
            forwardedMessageIds: []
        )
    }
}

private final class FixedSheetAnchorProvider: ChatAttachmentSheetAnchorProviding {
    private let composerTopY: CGFloat?

    init(composerTopY: CGFloat?) {
        self.composerTopY = composerTopY
    }

    func chatAttachmentSheetComposerTopY(in containerView: UIView) -> CGFloat? {
        composerTopY
    }
}

private final class DismissRecordingViewController: UIViewController {
    var dismissCount = 0

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCount += 1
        completion?()
    }
}

private final class Task5FakeFlowDelegate: ChatAttachmentFlowCoordinatorDelegate {
    var dismissCount = 0

    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) {}

    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) {
        dismissCount += 1
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    ) {}

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    ) {}
}

private final class Task5FakeSourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private var controllers: [ChatAttachmentSource: Task5WeakSourceController] = [:]

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        let controller = Task5FakeSourceController(source: source)
        controllers[source] = Task5WeakSourceController(controller)
        return controller
    }

    func controller(for source: ChatAttachmentSource) -> Task5FakeSourceController? {
        controllers[source]?.controller
    }
}

private final class Task5WeakSourceController {
    weak var controller: Task5FakeSourceController?

    init(_ controller: Task5FakeSourceController) {
        self.controller = controller
    }
}

private final class Task5FakeSourceController: UIViewController, ChatAttachmentSourceControlling {
    let source: ChatAttachmentSource
    var onSelectionCountChanged: ((Int) -> Void)?

    var viewController: UIViewController {
        self
    }

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
