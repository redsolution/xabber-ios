//
//  ChatSearchCalendarPresentationTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchCalendarPresentationTests: XCTestCase {
    func testPresentationRequestDispatchesOpenCalendarWithChatAndListOriginWithoutMutatingSearchData() throws {
        var chat = makeResultsState()
        let chatRequest = try XCTUnwrap(chat.calendarPresentationRequest)

        XCTAssertEqual(chatRequest.event, .openCalendar)
        XCTAssertEqual(chatRequest.origin, .chat)
        assertSearchDataUnchanged(whenApplying: chatRequest, to: &chat)
        XCTAssertEqual(chat.surfaceMode, .calendar)
        XCTAssertEqual(chat.calendarOrigin, .chat)

        var list = makeResultsState()
        list.reduce(.openList)
        let listRequest = try XCTUnwrap(list.calendarPresentationRequest)

        XCTAssertEqual(listRequest.event, .openCalendar)
        XCTAssertEqual(listRequest.origin, .list)
        assertSearchDataUnchanged(whenApplying: listRequest, to: &list)
        XCTAssertEqual(list.surfaceMode, .calendar)
        XCTAssertEqual(list.calendarOrigin, .list)
    }

    func testPresentationRequestIsIdempotentAndPreparesKeyboardBeforeFinalLayout() throws {
        var state = makeResultsState()
        let request = try XCTUnwrap(state.calendarPresentationRequest)
        var operations: [String] = []

        request.prepareForPresentation(
            resignKeyboard: { operations.append("keyboard") },
            layoutBottomGuide: { operations.append("layout") }
        )
        state.reduce(request.event)

        XCTAssertEqual(operations, ["keyboard", "layout"])
        XCTAssertNil(state.calendarPresentationRequest)
        XCTAssertFalse(request.restoresKeyboardAutomaticallyOnCancel)
        XCTAssertTrue(request.permitsUserRequestedInputFocusAfterCancel)
    }

    func testPresentationPlanMatchesDimSheetAndExplicitDismissalPolicy() throws {
        let plan = ChatSearchCalendarPresentationPlan.make(
            targetState: .presented,
            generation: 17,
            animationSpec: .production,
            animated: true
        )
        let dim = try XCTUnwrap(plan.dimTransition.alpha)
        let sheet = try XCTUnwrap(plan.sheetTransition.verticalOffsetFraction)

        XCTAssertEqual(plan.targetState, .presented)
        XCTAssertEqual(plan.generation, 17)
        XCTAssertEqual(plan.dimTargetAlpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(dim.from, 0, accuracy: 0.0001)
        XCTAssertEqual(dim.to, 1, accuracy: 0.0001)
        XCTAssertEqual(dim.timing.duration, 0.40, accuracy: 0.0001)
        XCTAssertEqual(sheet.from, 1, accuracy: 0.0001)
        XCTAssertEqual(sheet.to, 0, accuracy: 0.0001)
        XCTAssertEqual(
            sheet.timing.curve,
            .spring(.init(dampingRatio: 0.86, initialVelocity: 0.15))
        )
        XCTAssertEqual(plan.maximumDuration, 0.40, accuracy: 0.0001)
        XCTAssertFalse(plan.dismissalPolicy.dismissesOnOutsideTap)
        XCTAssertFalse(plan.dismissalPolicy.dismissesInteractively)
    }

    func testDismissalAndReduceMotionPlansUseReferenceOutAndShortFade() throws {
        let dismissal = ChatSearchCalendarPresentationPlan.make(
            targetState: .dismissed,
            generation: 18,
            animationSpec: .production,
            animated: true
        )
        XCTAssertEqual(
            try XCTUnwrap(dismissal.dimTransition.alpha).timing.duration,
            0.30,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(dismissal.sheetTransition.verticalOffsetFraction).to,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(dismissal.maximumDuration, 0.30, accuracy: 0.0001)

        let reducedSpec = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let reduced = ChatSearchCalendarPresentationPlan.make(
            targetState: .presented,
            generation: 19,
            animationSpec: reducedSpec,
            animated: true
        )
        XCTAssertTrue(reduced.isReducedMotion)
        XCTAssertNil(reduced.sheetTransition.verticalOffsetFraction)
        XCTAssertEqual(try XCTUnwrap(reduced.sheetTransition.alpha).from, 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(reduced.maximumDuration, 0.15)
    }

    func testDismissalContinuesDownwardFromInterruptedPresentationWithoutUpwardReset() {
        let factory = ManualCalendarAnimatorFactory(runsAnimationsOnStart: false)
        let controller = makeController(animatorFactory: factory)
        let host = CalendarPresentationHost()
        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 28,
            animated: true,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 28 }
        )

        let sheetHeight = controller.calendarView.bounds.height
        let interruptedOffset = sheetHeight * 0.4
        controller.calendarView.transform = CGAffineTransform(
            translationX: 0,
            y: interruptedOffset
        )
        controller.dimView.alpha = 0.2

        controller.dismiss(
            generation: 28,
            animated: true,
            isGenerationCurrent: { $0 == 28 },
            completion: nil
        )

        XCTAssertEqual(
            controller.calendarView.transform.ty,
            interruptedOffset,
            accuracy: 0.001,
            "Dismiss must begin at the currently visible Y instead of resetting upward"
        )
        XCTAssertEqual(controller.dimView.alpha, 0.2, accuracy: 0.001)

        factory.runPendingAnimations()

        XCTAssertEqual(controller.calendarView.transform.ty, sheetHeight, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            controller.calendarView.transform.ty,
            interruptedOffset
        )
        XCTAssertEqual(controller.dimView.alpha, 0, accuracy: 0.001)
        factory.finishPending()
    }

    func testLayoutDuringDismissalPreservesSheetAnchorAndDownwardTravel() {
        let controller = makeController(animatorFactory: ManualCalendarAnimatorFactory())
        let host = CalendarPresentationHost()
        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 30,
            animated: false,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 30 }
        )

        let settledCenter = controller.calendarView.center
        let settledMinY = controller.calendarView.frame.minY
        let downwardOffset = controller.calendarView.bounds.height * 0.4
        controller.calendarView.transform = CGAffineTransform(
            translationX: 0,
            y: downwardOffset
        )
        let visibleMinYBeforeLayout = controller.calendarView.frame.minY

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.calendarView.center.x, settledCenter.x, accuracy: 0.001)
        XCTAssertEqual(
            controller.calendarView.center.y,
            settledCenter.y,
            accuracy: 0.001,
            "Layout must not move the bottom sheet's base center while dismissal transform is active"
        )
        XCTAssertEqual(
            visibleMinYBeforeLayout,
            settledMinY + downwardOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.calendarView.frame.minY,
            visibleMinYBeforeLayout,
            accuracy: 0.001,
            "Layout must preserve the sheet's current downward displacement"
        )
    }

    func testReducedMotionDismissalPreservesInterruptedAlphaWithoutFlashOrSlide() {
        let factory = ManualCalendarAnimatorFactory(runsAnimationsOnStart: false)
        let reducedSpec = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let controller = makeController(
            animatorFactory: factory,
            animationSpec: reducedSpec
        )
        let host = CalendarPresentationHost()
        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 29,
            animated: true,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 29 }
        )

        controller.calendarView.alpha = 0.4
        controller.calendarView.transform = .identity
        controller.dimView.alpha = 0.2

        controller.dismiss(
            generation: 29,
            animated: true,
            isGenerationCurrent: { $0 == 29 },
            completion: nil
        )

        XCTAssertEqual(controller.calendarView.alpha, 0.4, accuracy: 0.001)
        XCTAssertEqual(controller.dimView.alpha, 0.2, accuracy: 0.001)
        XCTAssertEqual(controller.calendarView.transform, .identity)

        factory.runPendingAnimations()

        XCTAssertEqual(controller.calendarView.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(controller.dimView.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(controller.calendarView.transform, .identity)
        factory.finishPending()
    }

    func testControllerPresentsOneOverCurrentContextChildAndMovesAccessibilityFocus() throws {
        let factory = ManualCalendarAnimatorFactory()
        let controller = makeController(animatorFactory: factory)
        let host = CalendarPresentationHost()
        let returnFocus = UIButton(type: .system)
        host.parent.view.addSubview(returnFocus)
        var currentGeneration = 20

        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: currentGeneration,
            animated: true,
            focusReturnView: returnFocus,
            isGenerationCurrent: { $0 == currentGeneration }
        )

        XCTAssertEqual(controller.modalPresentationStyle, .overCurrentContext)
        XCTAssertTrue(controller.parent === host.parent)
        XCTAssertIdentical(host.parent.view.subviews.last, controller.view)
        XCTAssertEqual(controller.activeOverlayCount, 1)
        XCTAssertTrue(controller.isTransitioning)
        XCTAssertEqual(controller.lastTransitionPlan?.initialSheetOffsetFraction, 1)
        XCTAssertEqual(factory.animators.count, 2)

        factory.finishPending()

        XCTAssertEqual(controller.settledState, .presented)
        XCTAssertEqual(controller.dimView.alpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(controller.calendarView.transform, .identity)
        XCTAssertIdentical(
            controller.lastAccessibilityFocusTarget,
            controller.calendarView.preferredAccessibilityFocusView
        )

        currentGeneration = 21
    }

    func testRepeatedPresentationCoalescesAndOutsideInputCannotDismiss() {
        let factory = ManualCalendarAnimatorFactory()
        let controller = makeController(animatorFactory: factory)
        let host = CalendarPresentationHost()

        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 21,
            animated: true,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 21 }
        )
        let animatorCount = factory.animators.count
        controller.present(
            generation: 21,
            animated: true,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 21 }
        )

        XCTAssertEqual(factory.animators.count, animatorCount)
        XCTAssertEqual(host.parent.children.filter { $0 === controller }.count, 1)
        XCTAssertFalse(controller.dismissalPolicy.dismissesOnOutsideTap)
        XCTAssertFalse(controller.dismissalPolicy.dismissesInteractively)
        XCTAssertTrue(controller.dimView.gestureRecognizers?.isEmpty ?? true)
        XCTAssertTrue(controller.view.gestureRecognizers?.isEmpty ?? true)
    }

    func testCloseDismissesAfterOutCompletionRestoresOriginAndDoesNotRestoreKeyboard() throws {
        let factory = ManualCalendarAnimatorFactory()
        let controller = makeController(animatorFactory: factory)
        let host = CalendarPresentationHost()
        let returnFocus = UIButton(type: .system)
        host.parent.view.addSubview(returnFocus)
        var state = makeResultsState()
        let request = try XCTUnwrap(state.calendarPresentationRequest)
        state.reduce(request.event)

        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: state.generation,
            animated: true,
            focusReturnView: returnFocus,
            isGenerationCurrent: { $0 == state.generation }
        )
        factory.finishPending()
        controller.onCancel = {
            controller.dismiss(
                generation: state.generation,
                animated: true,
                isGenerationCurrent: { $0 == state.generation }
            ) {
                state.reduce(.cancelCalendar)
            }
        }

        controller.calendarView.closeButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(controller.isTransitioning)
        XCTAssertEqual(controller.lastTransitionPlan?.targetState, .dismissed)
        XCTAssertEqual(
            try XCTUnwrap(controller.lastTransitionPlan).maximumDuration,
            0.30,
            accuracy: 0.0001
        )
        XCTAssertEqual(state.surfaceMode, .calendar, "Origin changes only after out completion")

        factory.finishPending()

        XCTAssertEqual(state.surfaceMode, .chat)
        XCTAssertNil(controller.parent)
        XCTAssertNil(controller.view.superview)
        XCTAssertEqual(controller.activeOverlayCount, 0)
        XCTAssertIdentical(controller.lastAccessibilityFocusTarget, returnFocus)
        XCTAssertFalse(request.restoresKeyboardAutomaticallyOnCancel)
    }

    func testRotationAndSafeAreaLayoutPreserveSelectedMonthAndDay() throws {
        let controller = makeController(animatorFactory: ManualCalendarAnimatorFactory())
        let host = CalendarPresentationHost()
        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 22,
            animated: false,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 22 }
        )
        let selected = try XCTUnwrap(
            controller.calendarView.renderedSnapshot?.daySlots.first { $0.isSelected }.map(\.id)
        )
        let monthStart = controller.calendarView.renderedSnapshot?.visibleMonthStart

        host.window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        host.parent.view.frame = host.window.bounds
        controller.view.frame = host.parent.view.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.calendarView.renderedSnapshot?.visibleMonthStart, monthStart)
        XCTAssertEqual(
            controller.calendarView.renderedSnapshot?.daySlots.first { $0.isSelected }?.id,
            selected
        )
        XCTAssertEqual(controller.calendarView.frame.maxY, controller.view.bounds.maxY, accuracy: 0.001)
    }

    func testNavigatingFromSixWeekToFiveWeekMonthKeepsSheetFrameStable() throws {
        let controller = makeController(
            animatorFactory: ManualCalendarAnimatorFactory(),
            now: makeDate(2026, 8, 15)
        )
        let host = CalendarPresentationHost()
        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 27,
            animated: false,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 27 }
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.calendarView.renderedSnapshot?.rowCount, 6)
        let augustFrame = controller.calendarView.frame
        let augustDoneFrame = controller.calendarView.doneButton.frame

        controller.calendarView.nextButton.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.calendarView.renderedSnapshot?.rowCount, 5)
        XCTAssertEqual(controller.calendarView.frame, augustFrame)
        XCTAssertEqual(controller.calendarView.frame.minY, augustFrame.minY, accuracy: 0.001)
        XCTAssertEqual(controller.calendarView.frame.maxY, augustFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(controller.calendarView.doneButton.frame, augustDoneFrame)
    }

    func testLifecycleInterruptionSettlesPresentedAndDismissedWithoutOrphanOverlay() {
        let factory = ManualCalendarAnimatorFactory()
        let controller = makeController(animatorFactory: factory)
        let host = CalendarPresentationHost()

        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 23,
            animated: true,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 23 }
        )
        controller.settleTransitionForLifecycleInterruption()

        XCTAssertFalse(controller.isTransitioning)
        XCTAssertEqual(controller.settledState, .presented)
        XCTAssertEqual(controller.activeOverlayCount, 1)
        XCTAssertEqual(controller.dimView.alpha, 0.5, accuracy: 0.0001)

        controller.dismiss(
            generation: 23,
            animated: true,
            isGenerationCurrent: { $0 == 23 },
            completion: nil
        )
        controller.settleTransitionForLifecycleInterruption()

        XCTAssertFalse(controller.isTransitioning)
        XCTAssertEqual(controller.settledState, .dismissed)
        XCTAssertEqual(controller.activeOverlayCount, 0)
        XCTAssertNil(controller.parent)
    }

    func testStaleGenerationCompletionRemovesOverlayWithoutApplyingPresentedState() {
        let factory = ManualCalendarAnimatorFactory()
        let controller = makeController(animatorFactory: factory)
        let host = CalendarPresentationHost()
        var generation = 24

        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: generation,
            animated: true,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == generation }
        )
        generation = 25
        factory.finishPending()

        XCTAssertEqual(controller.settledState, .dismissed)
        XCTAssertEqual(controller.activeOverlayCount, 0)
        XCTAssertNil(controller.parent)
    }

    func testCalendarInteractionUpdatesOwnedModelAndDoneOnlyEmitsSelectedDate() throws {
        let controller = makeController(animatorFactory: ManualCalendarAnimatorFactory())
        let host = CalendarPresentationHost()
        controller.install(in: host.parent, containerView: host.parent.view)
        controller.present(
            generation: 26,
            animated: false,
            focusReturnView: nil,
            isGenerationCurrent: { $0 == 26 }
        )
        let candidate = try XCTUnwrap(
            controller.calendarView.renderedSnapshot?.daySlots.first {
                $0.isInteractive && !$0.isSelected
            }
        )
        var completedDate: Date?
        controller.onComplete = { completedDate = $0 }

        controller.calendarView.onSelectDay?(candidate.id)
        controller.calendarView.doneButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.calendarView.renderedSnapshot?.selectedDate, candidate.date)
        XCTAssertEqual(completedDate, candidate.date)
        XCTAssertNotNil(controller.parent, "Task 19 owns date resolution and final dismissal")
    }

    private func assertSearchDataUnchanged(
        whenApplying request: ChatSearchCalendarPresentationRequest,
        to state: inout ChatSearchPresentationState
    ) {
        let query = state.query
        let resultCount = state.resultCount
        let selectedIndex = state.committedResultIndex
        let generation = state.generation
        let phase = state.resultPhase

        state.reduce(request.event)

        XCTAssertEqual(state.query, query)
        XCTAssertEqual(state.resultCount, resultCount)
        XCTAssertEqual(state.committedResultIndex, selectedIndex)
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.resultPhase, phase)
        XCTAssertTrue(state.visibility.top)
        XCTAssertTrue(state.visibility.bottom)
        XCTAssertFalse(state.visibility.arrows)
    }

    private func makeResultsState() -> ChatSearchPresentationState {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        state.reduce(.resultsReceived(count: 3, generation: state.generation))
        state.reduce(.resultCommitted(index: 1, generation: state.generation))
        return state
    }

    private func makeController(
        animatorFactory: ChatSearchModeAnimatorFactory,
        now: Date? = nil,
        animationSpec: ChatSearchAnimationSpec = .production
    ) -> ChatSearchCalendarViewController {
        ChatSearchCalendarViewController(
            model: ChatSearchCalendarModel(
                calendar: makeCalendar(),
                locale: Locale(identifier: "en_US_POSIX"),
                clock: CalendarPresentationClock(now: now ?? makeDate(2026, 7, 13))
            ),
            animationSpec: animationSpec,
            animatorFactory: animatorFactory,
            prefersNativeGlass: false
        )
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        makeCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

private struct CalendarPresentationClock: ChatSearchCalendarClock {
    let now: Date
}

@MainActor
private final class CalendarPresentationHost {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let parent = UIViewController()

    init() {
        window.rootViewController = parent
        window.isHidden = false
        parent.loadViewIfNeeded()
        parent.view.frame = window.bounds
        parent.view.layoutIfNeeded()
    }

    deinit {
        window.isHidden = true
    }
}

@MainActor
private final class ManualCalendarAnimatorFactory: ChatSearchModeAnimatorFactory {
    private(set) var animators: [ManualCalendarAnimator] = []
    private let runsAnimationsOnStart: Bool

    init(runsAnimationsOnStart: Bool = true) {
        self.runsAnimationsOnStart = runsAnimationsOnStart
    }

    func makeAnimator(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void
    ) -> ChatSearchModeAnimating {
        let animator = ManualCalendarAnimator(
            timing: timing,
            animations: animations,
            runsAnimationsOnStart: runsAnimationsOnStart
        )
        animators.append(animator)
        return animator
    }

    func runPendingAnimations() {
        animators.filter { !$0.isFinished && !$0.isStopped }.forEach {
            $0.runAnimationsIfNeeded()
        }
    }

    func finishPending() {
        animators.filter { !$0.isFinished && !$0.isStopped }.forEach {
            $0.finishAnimation(at: .end)
        }
    }
}

@MainActor
private final class ManualCalendarAnimator: ChatSearchModeAnimating {
    let timing: ChatSearchAnimationSpec.Timing
    private let animations: () -> Void
    private var completions: [(UIViewAnimatingPosition) -> Void] = []
    private let runsAnimationsOnStart: Bool
    private var hasStarted = false
    private var hasRunAnimations = false
    private(set) var isStopped = false
    private(set) var isFinished = false

    init(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void,
        runsAnimationsOnStart: Bool
    ) {
        self.timing = timing
        self.animations = animations
        self.runsAnimationsOnStart = runsAnimationsOnStart
    }

    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {
        completions.append(completion)
    }

    func startAnimation() {
        hasStarted = true
        if runsAnimationsOnStart {
            runAnimationsIfNeeded()
        }
    }

    func runAnimationsIfNeeded() {
        guard hasStarted, !hasRunAnimations, !isStopped else { return }
        hasRunAnimations = true
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
