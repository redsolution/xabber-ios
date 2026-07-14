//
//  ChatSearchAdaptiveLayoutTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchAdaptiveLayoutTests: XCTestCase {
    private let maximumAccessibilityEnvironment = ChatSearchAdaptiveEnvironment(
        contentSizeCategory: .accessibilityExtraExtraExtraLarge,
        layoutDirection: .rightToLeft,
        accessibilityContrast: .high,
        differentiateWithoutColor: true,
        reduceTransparency: true,
        reduceMotion: true,
        userInterfaceStyle: .dark
    )

    func testEnvironmentResolvesSharedMotionTransparencyAndSurfacePolicy() {
        let animationSpec = ChatSearchAnimationSpec.production.resolved(
            for: maximumAccessibilityEnvironment.animationPreferences
        )
        let surfaceStyle = ChatSearchAdaptiveAppearance.surfaceStyle(
            for: maximumAccessibilityEnvironment
        )

        XCTAssertTrue(animationSpec.isReducedMotion)
        XCTAssertEqual(animationSpec.backgroundTreatment, .opaqueSystemMaterial)
        XCTAssertFalse(surfaceStyle.usesVisualEffect)
        XCTAssertTrue(surfaceStyle.usesOpaqueBackground)
        XCTAssertGreaterThanOrEqual(surfaceStyle.borderWidth, 1)
    }

    func testTopInputStaysSingleLineScrollableAndMirrorsWithoutLosingHitTargets() {
        let categories: [UIContentSizeCategory] = [
            .large,
            .extraExtraExtraLarge,
            .accessibilityMedium,
            .accessibilityExtraExtraExtraLarge
        ]

        for category in categories {
            let environment = maximumAccessibilityEnvironment.replacing(
                contentSizeCategory: category,
                layoutDirection: .leftToRight
            )
            let view = ChatSearchNavigationView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 60),
                prefersNativeGlass: false
            )
            view.applyAdaptiveEnvironment(environment)
            view.text = String(repeating: "long test query ", count: 40)
            view.layoutIfNeeded()

            XCTAssertEqual(view.textField.maxLines, 1)
            XCTAssertFalse(view.textField.adjustsFontSizeToFitWidth)
            XCTAssertGreaterThan(view.textField.bounds.width, 0)
            XCTAssertGreaterThanOrEqual(view.submitButton.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(view.clearButton.bounds.height, 44)
            XCTAssertGreaterThanOrEqual(view.cancelButton.bounds.width, 44)
            XCTAssertFalse(view.submitButton.frame.intersects(view.textField.frame))
            XCTAssertFalse(view.textField.frame.intersects(view.clearButton.frame))
        }

        let leftToRight = ChatSearchNavigationLayout.frames(
            containerWidth: 320,
            layoutDirection: .leftToRight
        )
        let rightToLeft = ChatSearchNavigationLayout.frames(
            containerWidth: 320,
            layoutDirection: .rightToLeft
        )
        assertMirrored(leftToRight.field, rightToLeft.field, width: 320)
        assertMirrored(leftToRight.cancel, rightToLeft.cancel, width: 320)
    }

    func testBottomCapsulesMirrorAtCompactWidthAndKeepAccessibleControlFrames() {
        let panel = ModernXabberInputView.SearchPanel(
            frame: CGRect(x: 0, y: 0, width: 280, height: 40),
            animationSpec: .production
        )
        panel.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        panel.applyRenderState(
            .results(current: 1, total: 12, isLoadingContext: false),
            surfaceMode: .chat,
            animated: false
        )
        panel.layoutIfNeeded()

        XCTAssertGreaterThan(panel.leadingSurfaceView.frame.minX, panel.trailingSurfaceView.frame.minX)
        XCTAssertFalse(panel.leadingSurfaceView.frame.intersects(panel.trailingSurfaceView.frame))
        XCTAssertGreaterThanOrEqual(panel.calendarButton.chatSearchAccessibilityFrame.width, 44)
        XCTAssertGreaterThanOrEqual(panel.calendarButton.chatSearchAccessibilityFrame.height, 44)
        XCTAssertGreaterThanOrEqual(panel.viewModeButton.chatSearchAccessibilityFrame.height, 44)
        XCTAssertGreaterThanOrEqual(panel.leadingSurfaceView.layer.borderWidth, 1)
        XCTAssertNil(panel.leadingSurfaceView.effect)
        XCTAssertNil(panel.trailingSurfaceView.effect)
    }

    func testFloatingNavigationRetainsOlderNewerMeaningWithExpandedAccessibilityFrames() {
        let view = ChatSearchNavigationButtonsView(
            frame: CGRect(origin: .zero, size: ChatSearchNavigationButtonsLayout.stackSize),
            animationSpec: .production
        )
        view.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        view.render(
            .init(
                isVisible: true,
                isPreviousEnabled: true,
                isNextEnabled: false,
                isBusy: false
            ),
            animated: false
        )
        view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(view.previousButton.chatSearchAccessibilityFrame.width, 44)
        XCTAssertGreaterThanOrEqual(view.previousButton.chatSearchAccessibilityFrame.height, 44)
        XCTAssertGreaterThanOrEqual(view.nextButton.chatSearchAccessibilityFrame.width, 44)
        XCTAssertEqual(view.previousButton.accessibilityValue, "Older message")
        XCTAssertEqual(view.nextButton.accessibilityValue, "No newer results")
        XCTAssertTrue(view.resolvedAnimationSpec.isReducedMotion)
        XCTAssertEqual(view.resolvedAnimationSpec.backgroundTreatment, .opaqueSystemMaterial)
    }

    func testResultRowGrowsAtMaximumTypeAndPreservesPrimaryMetadata() {
        let cell = ChatSearchResultCell(
            style: .default,
            reuseIdentifier: ChatSearchResultCell.reuseIdentifier
        )
        cell.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        let height = cell.sizeThatFits(
            CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        ).height
        cell.frame = CGRect(x: 0, y: 0, width: 320, height: height)
        cell.layoutIfNeeded()

        let frames = ChatSearchResultCellLayoutPolicy.frames(
            in: cell.contentView.bounds,
            dateWidth: 88,
            showsStatus: true,
            layoutDirection: .rightToLeft,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        XCTAssertGreaterThan(height, ChatSearchResultCellLayoutPolicy.standardRowHeight)
        XCTAssertGreaterThan(frames.sender.width, 0)
        XCTAssertGreaterThan(frames.snippet.width, 0)
        XCTAssertGreaterThan(frames.date.width, 0)
        XCTAssertGreaterThan(frames.status.width, 0)
        XCTAssertFalse(frames.sender.intersects(frames.date))
        XCTAssertFalse(frames.sender.intersects(frames.status))
        XCTAssertFalse(frames.sender.intersects(frames.snippet))
        XCTAssertEqual(cell.snippetLabel.numberOfLines, 1)
        XCTAssertEqual(cell.snippetLabel.lineBreakMode, .byTruncatingTail)
    }

    func testCalendarUsesVerticalOverflowAtLandscapeHeightWithoutHorizontalScrollingOrOverlap() {
        let view = makeCalendarView(width: 844, height: 390)
        view.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        view.layoutIfNeeded()

        XCTAssertTrue(view.contentScrollView.isScrollEnabled)
        XCTAssertFalse(view.contentScrollView.alwaysBounceHorizontal)
        XCTAssertEqual(view.contentScrollView.contentSize.width, view.contentScrollView.bounds.width, accuracy: 0.001)
        XCTAssertGreaterThan(view.contentScrollView.contentSize.height, view.contentScrollView.bounds.height)
        XCTAssertLessThanOrEqual(view.titleLabel.frame.maxY, view.monthButton.frame.minY)
        XCTAssertLessThanOrEqual(view.monthButton.frame.maxY, view.weekdayContainerView.frame.minY)
        XCTAssertLessThanOrEqual(view.weekdayContainerView.frame.maxY, view.collectionView.frame.minY)
        XCTAssertLessThanOrEqual(view.collectionView.frame.maxY, view.doneButton.frame.minY)
        XCTAssertLessThanOrEqual(view.doneButton.frame.maxY, view.contentScrollView.contentSize.height)
        for button in [view.closeButton, view.monthButton, view.previousButton, view.nextButton, view.doneButton] {
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
    }

    func testCalendarDayUsesFortyPointCueFortyFourPointHitAreaAndNonColorState() throws {
        let snapshot = makeCalendarModel().snapshot
        let selected = try XCTUnwrap(snapshot.daySlots.first(where: { $0.isSelected }))
        let today = try XCTUnwrap(snapshot.daySlots.first(where: { $0.isToday }))

        let selectedCell = ChatSearchCalendarDayCell(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44)
        )
        selectedCell.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        selectedCell.configure(with: selected)
        selectedCell.layoutIfNeeded()

        XCTAssertEqual(selectedCell.selectionCircleView.bounds.size, CGSize(width: 40, height: 40))
        XCTAssertEqual(selectedCell.chatSearchAccessibilityFrame.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(selectedCell.visualCue, .selectedEmphasized)
        XCTAssertGreaterThanOrEqual(selectedCell.selectionCircleView.layer.borderWidth, 2)

        let todayCell = ChatSearchCalendarDayCell(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44)
        )
        todayCell.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        todayCell.configure(with: today)
        XCTAssertEqual(todayCell.visualCue, selected.isToday ? .selectedEmphasized : .todayRing)
    }

    func testReduceTransparencyRemovesBlurAndReduceMotionKeepsFinalStatePlans() {
        let top = ChatSearchNavigationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60),
            prefersNativeGlass: false
        )
        top.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)
        let calendar = makeCalendarView(width: 390, height: 700)
        calendar.applyAdaptiveEnvironment(maximumAccessibilityEnvironment)

        XCTAssertNil(top.surfaceView.effect)
        XCTAssertNil(calendar.surfaceView.effect)
        XCTAssertFalse(top.adaptiveSurfaceStyle.usesVisualEffect)
        XCTAssertFalse(calendar.adaptiveSurfaceStyle.usesVisualEffect)
        XCTAssertEqual(calendar.resolvedAnimationSpec.monthSwipe.mode, .crossfade)
        XCTAssertTrue(calendar.resolvedAnimationSpec.requiresFinalStateApplication)
    }

    func testSemanticColorsPassProjectContrastPolicyInLightDarkAndHighContrast() {
        let traits = [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: .light),
                UITraitCollection(accessibilityContrast: .high)
            ]),
            UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: .dark),
                UITraitCollection(accessibilityContrast: .high)
            ])
        ]

        for trait in traits {
            XCTAssertTrue(ChatSearchContrastPolicy.passesBodyText(
                foreground: .label,
                background: .systemBackground,
                compatibleWith: trait
            ))
            XCTAssertTrue(ChatSearchContrastPolicy.passesLargeOrControlText(
                foreground: ChatSearchCalendarDayCell.Colors.selectedText,
                background: ChatSearchCalendarDayCell.Colors.selectedFill,
                compatibleWith: trait
            ))
            XCTAssertTrue(ChatSearchContrastPolicy.passesNonTextBoundary(
                foreground: .secondaryLabel,
                background: .systemBackground,
                compatibleWith: trait
            ))
        }
    }

    func testRotationCompactWidthAndRTLLayoutMatrixHasNoZeroOrOverlappingControls() {
        for width in [320.0, 390.0, 844.0] {
            for direction in [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
                let top = ChatSearchNavigationLayout.frames(
                    containerWidth: width,
                    layoutDirection: direction
                )
                let bottom = ChatSearchBottomActionBarLayout.frames(
                    in: CGRect(x: 0, y: 0, width: width, height: 40),
                    safeAreaInsets: width > 400
                        ? UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 59)
                        : .zero,
                    layoutDirection: direction
                )

                XCTAssertTrue(ChatSearchAdaptiveLayoutPolicy.areUsableAndDisjoint([
                    top.field,
                    top.cancel
                ]))
                XCTAssertTrue(ChatSearchAdaptiveLayoutPolicy.areUsableAndDisjoint([
                    bottom.leadingCapsule,
                    bottom.trailingCapsule
                ]))
            }
        }
    }

    private func makeCalendarView(width: CGFloat, height: CGFloat) -> ChatSearchCalendarView {
        ChatSearchCalendarView(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            snapshot: makeCalendarModel().snapshot,
            animationSpec: .production,
            prefersNativeGlass: false
        )
    }

    private func makeCalendarModel() -> ChatSearchCalendarModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return ChatSearchCalendarModel(
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            clock: FixedClock(now: calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 13,
                hour: 10,
                minute: 51
            ))!)
        )
    }

    private func assertMirrored(
        _ leftToRight: CGRect,
        _ rightToLeft: CGRect,
        width: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(leftToRight.minX, width - rightToLeft.maxX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(leftToRight.width, rightToLeft.width, accuracy: 0.001, file: file, line: line)
    }

    private struct FixedClock: ChatSearchCalendarClock {
        let now: Date
    }
}
