//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchNavigationButtonsTests: XCTestCase {
    func testLayoutUsesFortyPointButtonsAndTwelvePointVerticalGap() {
        XCTAssertEqual(ChatSearchNavigationButtonsLayout.buttonSize, 40)
        XCTAssertEqual(ChatSearchNavigationButtonsLayout.verticalGap, 12)
        XCTAssertEqual(
            ChatSearchNavigationButtonsLayout.stackSize,
            CGSize(width: 40, height: 92)
        )

        let frames = ChatSearchNavigationButtonsLayout.buttonFrames(
            in: CGRect(origin: .zero, size: ChatSearchNavigationButtonsLayout.stackSize)
        )

        XCTAssertEqual(frames.previous, CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertEqual(frames.next, CGRect(x: 0, y: 52, width: 40, height: 40))
    }

    func testLayoutUsesTrailingSafeAreaAndBottomObstructionAnchor() {
        let frame = ChatSearchNavigationButtonsLayout.stackFrame(
            in: CGRect(x: 0, y: 0, width: 390, height: 844),
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 6),
            bottomObstructionMinY: 760
        )

        XCTAssertEqual(frame, CGRect(x: 328, y: 656, width: 40, height: 92))
        XCTAssertEqual(frame.maxX, 390 - 6 - 16)
        XCTAssertEqual(frame.maxY, 760 - 12)
    }

    func testViewOwnsTwoDetachedButtonsWithStableAccessibilityIdentifiers() {
        let view = makeView()
        view.frame = CGRect(origin: .zero, size: ChatSearchNavigationButtonsLayout.stackSize)
        view.layoutIfNeeded()

        XCTAssertTrue(view.previousButton.superview === view)
        XCTAssertTrue(view.nextButton.superview === view)
        XCTAssertEqual(view.previousButton.frame, CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertEqual(view.nextButton.frame, CGRect(x: 0, y: 52, width: 40, height: 40))
        XCTAssertEqual(view.previousButton.accessibilityIdentifier, "chat_search_previous_result")
        XCTAssertEqual(view.nextButton.accessibilityIdentifier, "chat_search_next_result")
        XCTAssertEqual(view.previousButton.accessibilityLabel, "Previous result")
        XCTAssertEqual(view.nextButton.accessibilityLabel, "Next result")
        XCTAssertNil(view.descendant(withAccessibilityIdentifier: "chat_search_calendar"))
    }

    func testCallbacksRespectEnabledBoundaryState() {
        let view = makeView()
        var previousCount = 0
        var nextCount = 0
        view.onPrevious = { previousCount += 1 }
        view.onNext = { nextCount += 1 }
        view.render(
            .init(
                isVisible: true,
                isPreviousEnabled: false,
                isNextEnabled: true,
                isBusy: false
            ),
            animated: false
        )

        view.previousButton.sendActions(for: .touchUpInside)
        view.nextButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(previousCount, 0)
        XCTAssertEqual(nextCount, 1)
    }

    func testVisibilityRequiresChatSurfaceAndCommittedResult() {
        var state = makePresentation(resultCount: 3, committedIndex: 1)
        XCTAssertTrue(
            ChatSearchNavigationButtonsRenderPolicy.state(
                presentation: state,
                navigationBusy: false,
                canRequestOlderPage: false
            ).isVisible
        )

        state.reduce(.openList)
        XCTAssertFalse(
            ChatSearchNavigationButtonsRenderPolicy.state(
                presentation: state,
                navigationBusy: false,
                canRequestOlderPage: false
            ).isVisible
        )

        state.reduce(.openCalendar)
        XCTAssertFalse(
            ChatSearchNavigationButtonsRenderPolicy.state(
                presentation: state,
                navigationBusy: false,
                canRequestOlderPage: false
            ).isVisible
        )

        var searching = ChatSearchPresentationState.inactive
        searching.reduce(.activate)
        searching.reduce(.queryChanged("test"))
        searching.reduce(.debounceElapsed(generation: searching.generation))
        XCTAssertFalse(
            ChatSearchNavigationButtonsRenderPolicy.state(
                presentation: searching,
                navigationBusy: false,
                canRequestOlderPage: false
            ).isVisible
        )
    }

    func testNewestFirstBoundaryMappingDoesNotWrap() {
        let newest = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: makePresentation(resultCount: 3, committedIndex: 0),
            navigationBusy: false,
            canRequestOlderPage: false
        )
        XCTAssertTrue(newest.isPreviousEnabled)
        XCTAssertFalse(newest.isNextEnabled)

        let middle = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: makePresentation(resultCount: 3, committedIndex: 1),
            navigationBusy: false,
            canRequestOlderPage: false
        )
        XCTAssertTrue(middle.isPreviousEnabled)
        XCTAssertTrue(middle.isNextEnabled)

        let oldest = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: makePresentation(resultCount: 3, committedIndex: 2),
            navigationBusy: false,
            canRequestOlderPage: false
        )
        XCTAssertFalse(oldest.isPreviousEnabled)
        XCTAssertTrue(oldest.isNextEnabled)
    }

    func testSingleResultIsVisibleButTerminalButtonsAreDisabled() {
        let terminal = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: makePresentation(resultCount: 1, committedIndex: 0),
            navigationBusy: false,
            canRequestOlderPage: false
        )
        XCTAssertTrue(terminal.isVisible)
        XCTAssertFalse(terminal.isPreviousEnabled)
        XCTAssertFalse(terminal.isNextEnabled)

        let cursorAvailable = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: makePresentation(resultCount: 1, committedIndex: 0),
            navigationBusy: false,
            canRequestOlderPage: true
        )
        XCTAssertTrue(cursorAvailable.isPreviousEnabled)
        XCTAssertFalse(cursorAvailable.isNextEnabled)
    }

    func testAppendingOlderResultPreservesCommittedSelectionAndEnablesPrevious() {
        var presentation = makePresentation(resultCount: 2, committedIndex: 1)

        presentation.reduce(
            .resultsAppended(
                count: 3,
                generation: presentation.generation
            )
        )

        XCTAssertEqual(presentation.resultCount, 3)
        XCTAssertEqual(presentation.committedResultIndex, 1)
        let render = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: presentation,
            navigationBusy: false,
            canRequestOlderPage: false
        )
        XCTAssertTrue(render.isPreviousEnabled)
        XCTAssertTrue(render.isNextEnabled)
    }

    func testBusyStateDisablesBothButtonsWithoutChangingCommittedBoundary() {
        let state = ChatSearchNavigationButtonsRenderPolicy.state(
            presentation: makePresentation(resultCount: 4, committedIndex: 1),
            navigationBusy: true,
            canRequestOlderPage: true
        )

        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.isPreviousEnabled)
        XCTAssertFalse(state.isNextEnabled)
    }

    func testOlderPageGateIssuesOneRequestAndTargetsFirstNewOlderResult() throws {
        var gate = ChatSearchOlderPageNavigationGate(generation: 7)
        XCTAssertTrue(gate.offer(cursor: "older-250", generation: 7, loadedResultCount: 250))
        XCTAssertTrue(gate.canRequest)

        let request = try XCTUnwrap(gate.requestNavigation(generation: 7))
        XCTAssertEqual(request.cursor, "older-250")
        XCTAssertEqual(request.loadedResultCount, 250)
        XCTAssertNil(gate.requestNavigation(generation: 7))
        XCTAssertFalse(gate.canRequest)
        XCTAssertEqual(gate.consumePendingNavigationTarget(resultCount: 250, generation: 7), nil)
        XCTAssertEqual(gate.consumePendingNavigationTarget(resultCount: 251, generation: 7), 250)
        XCTAssertNil(gate.consumePendingNavigationTarget(resultCount: 252, generation: 7))
    }

    func testOlderPageGateRejectsRepeatedNoProgressTerminalAndStaleGeneration() {
        var gate = ChatSearchOlderPageNavigationGate(generation: 2)
        XCTAssertFalse(gate.offer(cursor: "stale", generation: 1, loadedResultCount: 4))
        XCTAssertTrue(gate.offer(cursor: "cursor", generation: 2, loadedResultCount: 4))
        XCTAssertNotNil(gate.requestNavigation(generation: 2))
        XCTAssertFalse(gate.offer(cursor: "next", generation: 2, loadedResultCount: 4))
        XCTAssertEqual(gate.phase, .terminal)
        XCTAssertFalse(gate.canRequest)

        gate.reset(generation: 3)
        XCTAssertTrue(gate.offer(cursor: "cursor", generation: 3, loadedResultCount: 4))
        XCTAssertFalse(gate.offer(cursor: "cursor", generation: 3, loadedResultCount: 5))
        XCTAssertEqual(gate.phase, .terminal)
    }

    func testQueryReplacementClearsPendingOlderPageIntent() {
        var gate = ChatSearchOlderPageNavigationGate(generation: 4)
        XCTAssertTrue(gate.offer(cursor: "cursor", generation: 4, loadedResultCount: 8))
        XCTAssertNotNil(gate.requestNavigation(generation: 4))
        XCTAssertTrue(gate.hasPendingNavigation)

        gate.reset(generation: 5)

        XCTAssertEqual(gate.generation, 5)
        XCTAssertEqual(gate.phase, .unavailable)
        XCTAssertFalse(gate.hasPendingNavigation)
        XCTAssertNil(gate.consumePendingNavigationTarget(resultCount: 20, generation: 4))
    }

    func testVisibilityAnimationUsesSharedSpecAndNeverLeavesHiddenViewHittable() {
        let view = makeView()
        view.render(
            .init(
                isVisible: true,
                isPreviousEnabled: true,
                isNextEnabled: false,
                isBusy: false
            ),
            animated: true
        )

        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertEqual(view.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(view.transform, .identity)
        XCTAssertEqual(view.lastVisibilityTransition, ChatSearchAnimationSpec.immediate.floatingButtons)

        view.render(.hidden, animated: true)

        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertEqual(view.alpha, 0, accuracy: 0.001)
        XCTAssertFalse(view.point(inside: CGPoint(x: 20, y: 20), with: nil))
    }

    func testReduceMotionUsesAlphaOnlyFloatingTransition() {
        let reduced = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let view = ChatSearchNavigationButtonsView(
            frame: .zero,
            animationSpec: reduced
        )

        view.render(
            .init(
                isVisible: true,
                isPreviousEnabled: true,
                isNextEnabled: true,
                isBusy: false
            ),
            animated: true
        )

        XCTAssertNil(view.lastVisibilityTransition?.scale)
        XCTAssertEqual(view.lastVisibilityTransition?.alpha?.timing.duration, 0.15)
        XCTAssertEqual(view.transform, .identity)
    }

    func testControllerInstallsStackAboveKeyboardOwnedBottomBar() throws {
        let controller = ChatViewController()
        controller.owner = "owner@example.com"
        controller.jid = "contact@example.com"
        controller.conversationType = .regular
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.searchNavigationButtonsView.superview === controller.view)
        XCTAssertEqual(controller.searchNavigationButtonsTrailingConstraint?.constant, -16)
        XCTAssertEqual(controller.searchNavigationButtonsBottomConstraint?.constant, -12)
        XCTAssertTrue(
            controller.searchNavigationButtonsBottomConstraint?.secondItem as? UIView === controller.xabberInputView
        )
        XCTAssertNil(
            controller.xabberInputView.searchPanel.descendant(
                withAccessibilityIdentifier: "chat_search_previous_result"
            )
        )
        XCTAssertNil(
            controller.xabberInputView.searchPanel.descendant(
                withAccessibilityIdentifier: "chat_search_next_result"
            )
        )
    }

    private func makeView() -> ChatSearchNavigationButtonsView {
        ChatSearchNavigationButtonsView(frame: .zero, animationSpec: .immediate)
    }

    private func makePresentation(
        resultCount: Int,
        committedIndex: Int
    ) -> ChatSearchPresentationState {
        var state = ChatSearchPresentationState.inactive
        state.reduce(.activate)
        state.reduce(.queryChanged("test"))
        state.reduce(
            .resultsReceived(
                count: resultCount,
                generation: state.generation
            )
        )
        state.reduce(
            .resultCommitted(
                index: committedIndex,
                generation: state.generation
            )
        )
        return state
    }
}

private extension UIView {
    func descendant(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.descendant(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
