//
//  LeftMenuSelectionPresentationPolicyTests.swift
//  xabberTests
//
//  Created by Codex on 10.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

final class LeftMenuSelectionPresentationPolicyTests: XCTestCase {
    private func action(
        isSplitCollapsed: Bool = false,
        splitHorizontalSizeClass: UIUserInterfaceSizeClass = .regular,
        windowHorizontalSizeClass: UIUserInterfaceSizeClass = .regular,
        viewHorizontalSizeClass: UIUserInterfaceSizeClass = .regular
    ) -> LeftMenuSelectionPresentationPolicy.PresentationAction {
        LeftMenuSelectionPresentationPolicy.action(
            isSplitCollapsed: isSplitCollapsed,
            splitHorizontalSizeClass: splitHorizontalSizeClass,
            windowHorizontalSizeClass: windowHorizontalSizeClass,
            viewHorizontalSizeClass: viewHorizontalSizeClass
        )
    }

    func testCollapsedSplitUsesCompactReveal() {
        XCTAssertEqual(
            action(isSplitCollapsed: true),
            .compactRevealSupplementary
        )
    }

    func testCompactSplitTraitUsesCompactReveal() {
        XCTAssertEqual(
            action(splitHorizontalSizeClass: .compact),
            .compactRevealSupplementary
        )
    }

    func testCompactWindowTraitUsesCompactReveal() {
        XCTAssertEqual(
            action(windowHorizontalSizeClass: .compact),
            .compactRevealSupplementary
        )
    }

    func testRegularSplitWithCompactSourceViewTraitUsesRegularRevealAndHidePrimary() {
        XCTAssertEqual(
            action(viewHorizontalSizeClass: .compact),
            .regularRevealSupplementaryAndHidePrimary
        )
    }

    func testRegularTraitsUseRegularRevealAndHidePrimary() {
        XCTAssertEqual(
            action(),
            .regularRevealSupplementaryAndHidePrimary
        )
    }

    func testCompactRevealDoesNotHidePrimary() {
        let action = LeftMenuSelectionPresentationPolicy.PresentationAction.compactRevealSupplementary

        XCTAssertFalse(action.hidesPrimary)
    }

    func testRegularRevealHidesPrimary() {
        let action = LeftMenuSelectionPresentationPolicy.PresentationAction.regularRevealSupplementaryAndHidePrimary

        XCTAssertTrue(action.hidesPrimary)
    }
}

final class LeftMenuSplitDestinationPreparerTests: XCTestCase {
    func testTargetBoundsUsesExistingColumnBoundsBeforeFallbacks() {
        let existingColumnBounds = CGRect(x: 0, y: 0, width: 320, height: 640)
        let splitBounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let presenterBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            existingColumnBounds: existingColumnBounds,
            splitBounds: splitBounds,
            presenterBounds: presenterBounds
        )

        XCTAssertEqual(targetBounds, existingColumnBounds)
    }

    func testTargetBoundsFallsBackToSplitBoundsWhenExistingColumnIsZero() {
        let splitBounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let presenterBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            existingColumnBounds: .zero,
            splitBounds: splitBounds,
            presenterBounds: presenterBounds
        )

        XCTAssertEqual(targetBounds, splitBounds)
    }

    func testTargetBoundsFallsBackToPresenterBoundsWhenSplitAndColumnAreZero() {
        let presenterBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            existingColumnBounds: .zero,
            splitBounds: .zero,
            presenterBounds: presenterBounds
        )

        XCTAssertEqual(targetBounds, presenterBounds)
    }

    func testPrepareSetsNonZeroBoundsAndRunsLayoutBeforePresentation() {
        let viewController = LayoutRecordingViewController()
        let targetBounds = CGRect(x: 0, y: 0, width: 320, height: 640)

        LeftMenuSplitDestinationPreparer.prepare(viewController, targetBounds: targetBounds)

        XCTAssertEqual(viewController.view.bounds.size, targetBounds.size)
        XCTAssertGreaterThan(viewController.layoutPassCount, 0)
    }

    func testPrepareNavigationControllerAlsoPreparesRootController() {
        let rootViewController = LayoutRecordingViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        LeftMenuSplitDestinationPreparer.prepare(navigationController, targetBounds: targetBounds)

        XCTAssertEqual(navigationController.view.bounds.size, targetBounds.size)
        XCTAssertTrue(rootViewController.isViewLoaded)
        XCTAssertFalse(rootViewController.view.bounds.isEmpty)
        XCTAssertGreaterThan(rootViewController.layoutPassCount, 0)
    }

    func testPrepareBeginsFirstPresentationQuietModeForSupportedController() {
        let viewController = QuietPresentationViewController()
        let targetBounds = CGRect(x: 0, y: 0, width: 320, height: 640)

        LeftMenuSplitDestinationPreparer.prepare(viewController, targetBounds: targetBounds)

        XCTAssertTrue(viewController.isLeftMenuFirstPresentationQuietModeActive)
    }

    func testPrepareNavigationControllerBeginsFirstPresentationQuietModeForRootController() {
        let rootViewController = QuietPresentationViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

        LeftMenuSplitDestinationPreparer.prepare(navigationController, targetBounds: targetBounds)

        XCTAssertTrue(rootViewController.isLeftMenuFirstPresentationQuietModeActive)
    }
}

final class LeftMenuFirstPresentationPolicyTests: XCTestCase {
    func testQuietModeDisablesRequestedTableAnimations() {
        XCTAssertEqual(
            LeftMenuFirstPresentationPolicy.rowAnimation(
                requested: .automatic,
                isQuietModeActive: true
            ),
            .none
        )
        XCTAssertFalse(
            LeftMenuFirstPresentationPolicy.shouldAnimate(
                requested: true,
                isQuietModeActive: true
            )
        )
    }

    func testNormalModePreservesRequestedTableAnimations() {
        XCTAssertEqual(
            LeftMenuFirstPresentationPolicy.rowAnimation(
                requested: .automatic,
                isQuietModeActive: false
            ),
            .automatic
        )
        XCTAssertTrue(
            LeftMenuFirstPresentationPolicy.shouldAnimate(
                requested: true,
                isQuietModeActive: false
            )
        )
    }

    func testQuietModeEndsAfterFirstAppearanceWindow() {
        let viewController = QuietPresentationViewController()
        let quietModeEnded = expectation(description: "quiet mode ended")

        viewController.beginLeftMenuFirstPresentationQuietMode()
        XCTAssertTrue(viewController.isLeftMenuFirstPresentationQuietModeActive)

        viewController.completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame()

        DispatchQueue.main.async {
            DispatchQueue.main.async {
                XCTAssertFalse(viewController.isLeftMenuFirstPresentationQuietModeActive)
                quietModeEnded.fulfill()
            }
        }

        wait(for: [quietModeEnded], timeout: 1.0)
    }
}

private final class LayoutRecordingViewController: UIViewController {
    private(set) var layoutPassCount = 0

    override func loadView() {
        view = UIView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPassCount += 1
    }
}

private final class QuietPresentationViewController: UIViewController, LeftMenuFirstPresentationQuieting {}
