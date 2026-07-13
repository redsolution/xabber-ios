//
//  ChatSearchBottomActionBarTests.swift
//  xabberTests
//
//  Created by Codex on 13.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchBottomActionBarTests: XCTestCase {
    func testActionBarUsesFixedFortyPointHeightAndTwoIndependentGlassCapsules() throws {
        let panel = makePanel(width: 358)

        XCTAssertEqual(panel.intrinsicContentSize.height, 40, accuracy: 0.001)
        XCTAssertEqual(panel.bounds.height, 40, accuracy: 0.001)
        XCTAssertIdentical(panel.leadingSurfaceView.superview, panel)
        XCTAssertIdentical(panel.trailingSurfaceView.superview, panel)
        XCTAssertNotIdentical(panel.leadingSurfaceView, panel.trailingSurfaceView)
        XCTAssertEqual(panel.leadingSurfaceView.layer.cornerRadius, 20, accuracy: 0.001)
        XCTAssertEqual(panel.trailingSurfaceView.layer.cornerRadius, 20, accuracy: 0.001)

        if #available(iOS 26.0, *) {
            XCTAssertTrue(try XCTUnwrap(panel.leadingSurfaceView.effect as? UIGlassEffect).isInteractive)
            XCTAssertTrue(try XCTUnwrap(panel.trailingSurfaceView.effect as? UIGlassEffect).isInteractive)
        } else {
            XCTAssertTrue(panel.leadingSurfaceView.effect is UIBlurEffect)
            XCTAssertTrue(panel.trailingSurfaceView.effect is UIBlurEffect)
        }
    }

    func testIPhone16eGeometryStartsAtSafeAreaAndKeepsControlsDisjoint() {
        let frames = ChatSearchBottomActionBarLayout.frames(
            in: CGRect(x: 0, y: 0, width: 390, height: 40),
            safeAreaInsets: .zero
        )

        XCTAssertEqual(frames.leadingCapsule.minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames.leadingCapsule.height, 40, accuracy: 0.001)
        XCTAssertEqual(frames.trailingCapsule.height, 40, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frames.leadingCapsule.width, 40)
        XCTAssertGreaterThanOrEqual(frames.trailingCapsule.width, 40)
        XCTAssertLessThanOrEqual(frames.leadingCapsule.maxX, frames.trailingCapsule.minX)
        XCTAssertEqual(frames.trailingCapsule.maxX, 390, accuracy: 0.001)
    }

    func testRotationAndNarrowSafeAreaNeverOverlapCapsules() {
        for (width, insets) in [
            (390.0, UIEdgeInsets.zero),
            (844.0, UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 59)),
            (320.0, UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        ] {
            let frames = ChatSearchBottomActionBarLayout.frames(
                in: CGRect(x: 0, y: 0, width: width, height: 40),
                safeAreaInsets: insets
            )

            XCTAssertEqual(frames.leadingCapsule.minX, insets.left, accuracy: 0.001)
            XCTAssertEqual(frames.trailingCapsule.maxX, width - insets.right, accuracy: 0.001)
            XCTAssertLessThanOrEqual(frames.leadingCapsule.maxX, frames.trailingCapsule.minX)
            XCTAssertGreaterThanOrEqual(frames.leadingCapsule.width, 40)
            XCTAssertGreaterThanOrEqual(frames.trailingCapsule.width, 40)
        }
    }

    func testCalendarControlRemainsAvailableAcrossSearchPhases() {
        let panel = makePanel()
        let states: [ModernXabberInputView.SearchPanel.RenderState] = [
            .idle,
            .loading,
            .emptyResults,
            .results(current: 0, total: 1, isLoadingContext: false)
        ]

        for state in states {
            panel.applyRenderState(state, surfaceMode: .chat, animated: false)

            XCTAssertFalse(panel.calendarButton.isHidden)
            XCTAssertTrue(panel.calendarButton.isEnabled)
            XCTAssertEqual(panel.calendarButton.accessibilityIdentifier, "chat_search_calendar")
            XCTAssertGreaterThanOrEqual(panel.calendarButton.bounds.width, 40)
            XCTAssertGreaterThanOrEqual(panel.calendarButton.bounds.height, 40)
        }
    }

    func testChatModeShowsCurrentOfTotalAndListModeShowsMessagePlural() {
        let panel = makePanel()

        panel.applyRenderState(
            .results(current: 0, total: 2, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        XCTAssertEqual(panel.counterLabel.text, "1 of 2")
        XCTAssertEqual(panel.viewModeButton.title(for: .normal), "Show as List")

        panel.setSurfaceMode(.list, animated: false)
        XCTAssertEqual(panel.counterLabel.text, "2 messages")
        XCTAssertEqual(panel.viewModeButton.title(for: .normal), "Show as Chat")
    }

    func testCountFormatterHasLocalizableZeroOneAndPluralForms() {
        let formatter = ChatSearchBottomCountFormatter()

        XCTAssertEqual(formatter.messages(total: 0), "No messages")
        XCTAssertEqual(formatter.messages(total: 1), "1 message")
        XCTAssertEqual(formatter.messages(total: 2), "2 messages")
        XCTAssertEqual(formatter.current(1, total: 2), "2 of 2")
    }

    func testViewModeControlRequiresCommittedCurrentResult() {
        let panel = makePanel()

        panel.applyRenderState(.idle, surfaceMode: .chat, animated: false)
        XCTAssertTrue(panel.trailingSurfaceView.isHidden)
        panel.applyRenderState(.loading, surfaceMode: .chat, animated: false)
        XCTAssertTrue(panel.trailingSurfaceView.isHidden)
        panel.applyRenderState(.emptyResults, surfaceMode: .chat, animated: false)
        XCTAssertTrue(panel.trailingSurfaceView.isHidden)
        panel.applyRenderState(
            .results(current: -1, total: 2, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        XCTAssertTrue(panel.trailingSurfaceView.isHidden)
        panel.applyRenderState(
            .results(current: 0, total: 2, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        XCTAssertFalse(panel.trailingSurfaceView.isHidden)
        XCTAssertGreaterThanOrEqual(panel.viewModeButton.bounds.height, 40)
    }

    func testIdleLoadingAndEmptyClearStaleCountWithoutChangingCapsuleWidth() {
        let panel = makePanel()
        panel.applyRenderState(
            .results(current: 11, total: 42, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        let resultsWidth = panel.leadingSurfaceView.bounds.width

        for state in [
            ModernXabberInputView.SearchPanel.RenderState.idle,
            .loading,
            .emptyResults
        ] {
            panel.applyRenderState(state, surfaceMode: .chat, animated: false)
            panel.layoutIfNeeded()

            XCTAssertEqual(panel.counterLabel.text, "No messages")
            XCTAssertFalse(panel.counterLabel.isHidden)
            XCTAssertEqual(panel.leadingSurfaceView.bounds.width, resultsWidth, accuracy: 0.001)
        }
    }

    func testCounterTransitionKeepsLabelHierarchyAndUsesReferenceTiming() throws {
        let panel = makePanel(animationSpec: .production)
        panel.applyRenderState(
            .results(current: 0, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        let labelIdentity = ObjectIdentifier(panel.counterLabel)
        let transitionCount = panel.counterTransitionCount

        panel.applyRenderState(
            .results(current: 1, total: 3, isLoadingContext: false),
            surfaceMode: .chat,
            animated: true
        )

        XCTAssertEqual(ObjectIdentifier(panel.counterLabel), labelIdentity)
        XCTAssertEqual(panel.counterTransitionCount, transitionCount + 1)
        let transition = try XCTUnwrap(panel.lastCounterTransition)
        XCTAssertEqual(transition.mode, .verticalPush)
        XCTAssertEqual(transition.duration, 0.25, accuracy: 0.001)
    }

    func testReducedMotionChangesCounterTransitionToCrossfade() throws {
        let reduced = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )
        let panel = makePanel(animationSpec: reduced)
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

        let transition = try XCTUnwrap(panel.lastCounterTransition)
        XCTAssertEqual(transition.mode, .crossfade)
        XCTAssertEqual(transition.duration, 0.15, accuracy: 0.001)
    }

    func testOnlyCalendarAndViewModeControlsOwnBottomActions() {
        let panel = makePanel()
        var calendarCount = 0
        var modeCount = 0
        panel.onCalendarCallback = { calendarCount += 1 }
        panel.onChangeViewStateCallback = { modeCount += 1 }
        panel.applyRenderState(
            .results(current: 0, total: 2, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )

        panel.calendarButton.sendActions(for: .touchUpInside)
        panel.viewModeButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(calendarCount, 1)
        XCTAssertEqual(modeCount, 1)
        XCTAssertNil(panel.cancelButton.superview)
        XCTAssertNil(panel.descendant(withAccessibilityIdentifier: "chat_search_cancel"))
        XCTAssertNil(panel.descendant(withAccessibilityIdentifier: "chat_search_previous_result"))
        XCTAssertNil(panel.descendant(withAccessibilityIdentifier: "chat_search_next_result"))
    }

    func testStableAccessibilityContract() {
        let panel = makePanel()

        XCTAssertEqual(panel.accessibilityIdentifier, "chat_search_results_panel")
        XCTAssertEqual(panel.counterLabel.accessibilityIdentifier, "chat_search_results_count")
        XCTAssertEqual(panel.viewModeButton.accessibilityIdentifier, "chat_search_view_mode_control")
        XCTAssertEqual(panel.calendarButton.accessibilityIdentifier, "chat_search_calendar")
    }

    private func makePanel(
        width: CGFloat = 358,
        animationSpec: ChatSearchAnimationSpec = .immediate
    ) -> ModernXabberInputView.SearchPanel {
        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 0, y: 0, width: width, height: 40),
            animationSpec: animationSpec
        )
        panel.layoutIfNeeded()
        return panel
    }
}

private extension UIView {
    func descendant(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier {
            return self
        }
        return subviews.lazy.compactMap {
            $0.descendant(withAccessibilityIdentifier: identifier)
        }.first
    }
}
