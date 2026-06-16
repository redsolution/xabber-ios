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

final class LeftMenuSplitPresentationAnimationPolicyTests: XCTestCase {
    func testDestinationPreparationDisablesAnimations() {
        XCTAssertTrue(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: .destinationPreparation)
        )
    }

    func testColumnInstallationDisablesAnimations() {
        XCTAssertTrue(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: .columnInstallation)
        )
    }

    func testCompactRevealUsesNativeAnimations() {
        let phase = LeftMenuSplitPresentationAnimationPolicy.revealPhase(
            for: .compactRevealSupplementary
        )

        XCTAssertFalse(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: phase)
        )
    }

    func testRegularRevealAndHidePrimaryUsesNativeAnimations() {
        let phase = LeftMenuSplitPresentationAnimationPolicy.revealPhase(
            for: .regularRevealSupplementaryAndHidePrimary
        )

        XCTAssertFalse(
            LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: phase)
        )
    }
}

final class LeftMenuSplitDestinationPreparerTests: XCTestCase {
    private final class TraitWindow: UIWindow {
        private let horizontalSizeClass: UIUserInterfaceSizeClass

        init(horizontalSizeClass: UIUserInterfaceSizeClass) {
            self.horizontalSizeClass = horizontalSizeClass
            super.init(frame: UIScreen.main.bounds)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var traitCollection: UITraitCollection {
            UITraitCollection(traitsFrom: [
                super.traitCollection,
                UITraitCollection(horizontalSizeClass: horizontalSizeClass)
            ])
        }
    }

    private final class RecordingNavigationController: UINavigationController {
        private(set) var loadViewCallCount = 0
        private(set) var layoutSubviewsCallCount = 0

        override func loadView() {
            loadViewCallCount += 1
            super.loadView()
        }

        override func viewDidLayoutSubviews() {
            layoutSubviewsCallCount += 1
            super.viewDidLayoutSubviews()
        }

        func resetRecording() {
            loadViewCallCount = 0
            layoutSubviewsCallCount = 0
        }
    }

    private var retainedTraitWindows: [UIWindow] = []

    override func tearDown() {
        retainedTraitWindows.forEach { $0.isHidden = true }
        retainedTraitWindows.removeAll()
        super.tearDown()
    }

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

    func testPrepareDefersDetachedLayoutForSearchHostNavigationController() {
        searchHostNavigationControllers().forEach { navigationController in
            guard let navigationController = navigationController as? RecordingNavigationController else {
                XCTFail("Expected recording navigation controller")
                return
            }
            guard let rootViewController = navigationController.topViewController else {
                XCTFail("Expected search host root controller")
                return
            }
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)
            let initialNavigationBounds = navigationController.viewIfLoaded?.bounds
            let initialRootLoaded = rootViewController.isViewLoaded
            navigationController.resetRecording()

            LeftMenuSplitDestinationPreparer.prepare(navigationController, targetBounds: targetBounds)

            XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: navigationController))
            XCTAssertEqual(navigationController.loadViewCallCount, 0)
            XCTAssertEqual(navigationController.layoutSubviewsCallCount, 0)
            XCTAssertEqual(navigationController.viewIfLoaded?.bounds, initialNavigationBounds)
            XCTAssertEqual(rootViewController.isViewLoaded, initialRootLoaded)
            XCTAssertNotNil(rootViewController.navigationItem.searchController)
        }
    }

    func testPrepareDefersDetachedLayoutForDirectSearchHostController() {
        directSearchHostControllers().forEach { name, viewController in
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            XCTAssertTrue(
                SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: viewController),
                name
            )
            XCTAssertFalse(viewController.isViewLoaded, name)
            XCTAssertNil(viewController.navigationItem.searchController, name)

            LeftMenuSplitDestinationPreparer.prepare(viewController, targetBounds: targetBounds)

            XCTAssertFalse(viewController.isViewLoaded, name)
            XCTAssertNil(viewController.navigationItem.searchController, name)
        }
    }

    func testPrepareAttachedLoadsSearchHostNavigationControllerAfterSplitInstallation() {
        searchHostNavigationControllers().forEach { navigationController in
            guard let rootViewController = navigationController.topViewController else {
                XCTFail("Expected search host root controller")
                return
            }
            let splitViewController = UISplitViewController(style: .tripleColumn)
            splitViewController.setViewController(navigationController, for: .supplementary)
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            LeftMenuSplitDestinationPreparer.prepareAttached(navigationController, targetBounds: targetBounds)

            XCTAssertTrue(navigationController.isViewLoaded)
            XCTAssertTrue(rootViewController.isViewLoaded)
            XCTAssertEqual(navigationController.view.bounds.size, targetBounds.size)
            XCTAssertFalse(rootViewController.view.bounds.isEmpty)
            XCTAssertNotNil(rootViewController.navigationItem.searchController)
        }
    }

    func testPrepareAttachedIfDeferredLoadsSearchHostNavigationControllerAfterSplitInstallation() {
        searchHostNavigationControllers().forEach { navigationController in
            guard let rootViewController = navigationController.topViewController else {
                XCTFail("Expected search host root controller")
                return
            }
            let splitViewController = UISplitViewController(style: .tripleColumn)
            splitViewController.setViewController(navigationController, for: .supplementary)
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            LeftMenuSplitDestinationPreparer.prepareAttachedIfDeferred(
                navigationController,
                targetBounds: targetBounds
            )

            XCTAssertTrue(navigationController.isViewLoaded)
            XCTAssertTrue(rootViewController.isViewLoaded)
            XCTAssertEqual(navigationController.view.bounds.size, targetBounds.size)
            XCTAssertFalse(rootViewController.view.bounds.isEmpty)
            XCTAssertNotNil(rootViewController.navigationItem.searchController)
        }
    }

    func testPrepareAttachedIfDeferredLoadsDirectSearchHostAfterSplitInstallation() {
        directSearchHostControllers().forEach { name, viewController in
            let splitViewController = UISplitViewController(style: .tripleColumn)
            let parent = embedInTraitContainer(splitViewController, horizontalSizeClass: .regular)
            parent.loadViewIfNeeded()
            splitViewController.setViewController(viewController, for: .secondary)
            let targetBounds = CGRect(x: 0, y: 0, width: 414, height: 896)

            let didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
                viewController,
                in: splitViewController
            )
            LeftMenuSplitDestinationPreparer.prepareAttachedIfDeferred(
                viewController,
                targetBounds: targetBounds
            )

            XCTAssertFalse(didRebind, name)
            XCTAssertTrue(viewController.isViewLoaded, name)
            XCTAssertEqual(viewController.view.bounds.size, targetBounds.size, name)
            XCTAssertTrue(
                viewController.navigationItem.searchController === searchController(for: viewController),
                name
            )
        }
    }

    func testPrepareAttachedIfDeferredSkipsNonSearchController() {
        let viewController = LayoutRecordingViewController()
        let targetBounds = CGRect(x: 0, y: 0, width: 320, height: 640)

        LeftMenuSplitDestinationPreparer.prepareAttachedIfDeferred(
            viewController,
            targetBounds: targetBounds
        )

        XCTAssertFalse(viewController.isViewLoaded)
        XCTAssertEqual(viewController.layoutPassCount, 0)
    }

    func testPrepareSearchHostForRevealDoesNotRebindAlreadyAttachedSearchControllerAfterSplitInstallation() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let viewController = LastChatsViewController()
        viewController.configureSearchBar()
        let searchController = viewController.searchController
        let navigationController = RecordingNavigationController(rootViewController: viewController)
        let splitViewController = UISplitViewController(style: .tripleColumn)
        let parent = embedInTraitContainer(splitViewController, horizontalSizeClass: .regular)
        parent.loadViewIfNeeded()
        splitViewController.setViewController(navigationController, for: .supplementary)

        let didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
            navigationController,
            in: splitViewController,
            forceSearchRebind: true
        )

        XCTAssertFalse(didRebind)
        XCTAssertTrue(viewController.navigationItem.searchController === searchController)
        assertNativeDefaultSearchNavigationChrome(navigationController)
    }

    func testPrepareSearchHostForRevealDoesNotForceRebindByDefault() {
        let viewController = LastChatsViewController()
        viewController.configureSearchBar()
        let searchController = viewController.searchController
        let navigationController = RecordingNavigationController(rootViewController: viewController)

        let didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
            navigationController
        )

        XCTAssertFalse(didRebind)
        XCTAssertTrue(viewController.navigationItem.searchController === searchController)
    }

    func testPrepareSearchHostForRevealSkipsActiveSearchControllerRebind() {
        let viewController = LastChatsViewController()
        let navigationController = RecordingNavigationController(rootViewController: viewController)
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        parent.loadViewIfNeeded()
        viewController.configureSearchBar()
        activateInPlaceSearch(viewController.searchController)

        let didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
            navigationController,
            forceSearchRebind: true
        )

        XCTAssertFalse(didRebind)
        XCTAssertTrue(viewController.navigationItem.searchController === viewController.searchController)
    }

    func testPrepareSearchHostForRevealDoesNotRebindDirectAlreadyAttachedSearchHostController() {
        let viewController = LastChatsViewController()
        viewController.configureSearchBar()
        let searchController = viewController.searchController

        let didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
            viewController,
            forceSearchRebind: true
        )

        XCTAssertFalse(didRebind)
        XCTAssertTrue(viewController.navigationItem.searchController === searchController)
    }

    func testPrepareSearchHostForRevealKeepsNonSearchNavigationStackOnTransparentSplitPath() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: EmptyChatViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
        parent.loadViewIfNeeded()

        let didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
            navigationController
        )

        XCTAssertFalse(didRebind)
        XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        XCTAssertEqual(navigationController.view.backgroundColor, .clear)
        XCTAssertFalse(navigationController.view.isOpaque)
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

    func testSearchSectionRootsRequireNativeDefaultNavigationContainers() {
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: LastChatsViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: ContactsViewController()))
        XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: LastCallsViewController()))
    }

    func testSearchSectionNavigationContainersRequireDeferredAttachedLayout() {
        searchHostNavigationControllers().forEach { navigationController in
            XCTAssertTrue(SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: navigationController))
        }

        XCTAssertFalse(
            SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(
                for: UINavigationController(rootViewController: UIViewController())
            )
        )
    }

    func testSearchSectionRootsRequireDeferredAttachedLayout() {
        directSearchHostControllers().forEach { name, viewController in
            XCTAssertTrue(
                SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: viewController),
                name
            )
        }

        XCTAssertFalse(
            SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: UIViewController())
        )
        XCTAssertFalse(
            SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: EmptyChatViewController())
        )
    }

    func testSearchSectionNavigationContainersDoNotMutateAppearanceWhenSplitTraitsAreUnresolved() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        [
            UINavigationController(rootViewController: LastChatsViewController()),
            UINavigationController(rootViewController: ContactsViewController()),
            UINavigationController(rootViewController: LastCallsViewController())
        ].forEach { navigationController in
            installStaleTransparentNavigationAppearance(on: navigationController)
            let standardAppearance = navigationController.navigationBar.standardAppearance
            let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
            let compactAppearance = navigationController.navigationBar.compactAppearance
            let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance

            SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

            XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
            XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
            XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
            XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        }
    }

    func testCompactSplitNavigationContainersKeepNavbarAppearanceUntouched() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: UIViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        installStaleTransparentNavigationAppearance(on: navigationController)
        let standardAppearance = navigationController.navigationBar.standardAppearance
        let scrollEdgeAppearance = navigationController.navigationBar.scrollEdgeAppearance
        let compactAppearance = navigationController.navigationBar.compactAppearance
        let compactScrollEdgeAppearance = navigationController.navigationBar.compactScrollEdgeAppearance

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        assertCompactNavigationContainerBackground(navigationController)
        XCTAssertTrue(navigationController.navigationBar.standardAppearance === standardAppearance)
        XCTAssertTrue(navigationController.navigationBar.scrollEdgeAppearance === scrollEdgeAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactAppearance === compactAppearance)
        XCTAssertTrue(navigationController.navigationBar.compactScrollEdgeAppearance === compactScrollEdgeAppearance)
    }

    private func installStaleTransparentNavigationAppearance(on navigationController: UINavigationController) {
        let staleAppearance = UINavigationBarAppearance()
        staleAppearance.configureWithTransparentBackground()
        staleAppearance.shadowColor = .magenta
        navigationController.navigationBar.isTranslucent = true
        navigationController.navigationBar.standardAppearance = staleAppearance
        navigationController.navigationBar.scrollEdgeAppearance = staleAppearance
        navigationController.navigationBar.compactAppearance = staleAppearance
        navigationController.navigationBar.compactScrollEdgeAppearance = staleAppearance
        navigationController.topViewController?.navigationItem.standardAppearance = staleAppearance
        navigationController.topViewController?.navigationItem.scrollEdgeAppearance = staleAppearance
        navigationController.topViewController?.navigationItem.compactAppearance = staleAppearance
        if #available(iOS 15.0, *) {
            navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance = staleAppearance
        }
    }

    private func assertCompactNavigationContainerBackground(
        _ navigationController: UINavigationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(navigationController.view.backgroundColor, .systemBackground, file: file, line: line)
        XCTAssertTrue(navigationController.view.isOpaque, file: file, line: line)
    }

    func testCompactSplitNavigationContainersDoNotApplyTransparentSplitAppearance() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: UIViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .compact)
        navigationController.navigationBar.isTranslucent = false

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        XCTAssertFalse(navigationController.navigationBar.isTranslucent)
        XCTAssertEqual(navigationController.view.backgroundColor, .systemBackground)
        XCTAssertTrue(navigationController.view.isOpaque)
    }

    func testRegularSplitNonSearchNavigationContainersCanApplyTransparentSplitAppearance() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: UIViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

        XCTAssertTrue(navigationController.navigationBar.isTranslucent)
        XCTAssertNotNil(navigationController.navigationBar.standardAppearance)
        XCTAssertNotNil(navigationController.navigationBar.scrollEdgeAppearance)
        XCTAssertNotNil(navigationController.navigationBar.compactAppearance)
    }

    func testRegularSplitSearchNavigationContainersUseNativeDefaultSearchChrome() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        [
            UINavigationController(rootViewController: LastChatsViewController()),
            UINavigationController(rootViewController: ContactsViewController()),
            UINavigationController(rootViewController: LastCallsViewController())
        ].forEach { navigationController in
            let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)
            installStaleTransparentNavigationAppearance(on: navigationController)

            parent.loadViewIfNeeded()
            SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

            assertNativeDefaultSearchNavigationChrome(navigationController)
            XCTAssertEqual(navigationController.view.backgroundColor, .clear)
            XCTAssertFalse(navigationController.view.isOpaque)
        }
    }

    func testBackgroundRootContainerKeepsSearchHostNavigationChromeNativeDefaultInRegularSplit() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: LastChatsViewController())
        installStaleTransparentNavigationAppearance(on: navigationController)
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.setViewController(navigationController, for: .supplementary)
        let container = BackgroundRootContainerViewController(contentViewController: splitViewController)
        let parent = embedInTraitContainer(container, horizontalSizeClass: .regular)

        parent.loadViewIfNeeded()
        container.view.setNeedsLayout()
        container.view.layoutIfNeeded()
        parent.view.layoutIfNeeded()

        assertNativeDefaultSearchNavigationChrome(navigationController)
        XCTAssertEqual(navigationController.view.backgroundColor, .clear)
        XCTAssertFalse(navigationController.view.isOpaque)
    }

    func testRegularSplitNonSearchNavigationContainersKeepTransparentSharedBackdropAppearance() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let navigationController = UINavigationController(rootViewController: EmptyChatViewController())
        let parent = embedInTraitContainer(navigationController, horizontalSizeClass: .regular)

        parent.loadViewIfNeeded()
        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)

            XCTAssertTrue(navigationController.navigationBar.isTranslucent)
            XCTAssertEqual(navigationController.view.backgroundColor, .clear)
            XCTAssertFalse(navigationController.view.isOpaque)
    }

    func testNonSearchSectionRootsCanUseExistingNavigationContainerChrome() {
        XCTAssertFalse(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: UIViewController()))
        XCTAssertFalse(SearchSectionNavigationContainerPolicy.requiresNativeDefaultNavigationContainer(for: EmptyChatViewController()))
    }

    @discardableResult
    private func embedInTraitContainer(
        _ child: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> UIViewController {
        let parent = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        parent.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: horizontalSizeClass),
            forChild: child
        )
        attachToTraitWindow(parent, horizontalSizeClass: horizontalSizeClass)
        return parent
    }

    private func assertNativeDefaultSearchNavigationChrome(
        _ navigationController: UINavigationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let defaultNavigationBar = UINavigationBar()
        XCTAssertEqual(
            navigationController.navigationBar.isTranslucent,
            defaultNavigationBar.isTranslucent,
            file: file,
            line: line
        )
        assertNativeDefaultAppearance(
            navigationController.navigationBar.standardAppearance,
            matches: defaultNavigationBar.standardAppearance,
            file: file,
            line: line
        )
        assertNativeDefaultAppearance(
            navigationController.navigationBar.scrollEdgeAppearance,
            matches: defaultNavigationBar.scrollEdgeAppearance,
            file: file,
            line: line
        )
        assertNativeDefaultAppearance(
            navigationController.navigationBar.compactAppearance,
            matches: defaultNavigationBar.compactAppearance,
            file: file,
            line: line
        )
        assertNativeDefaultAppearance(
            navigationController.navigationBar.compactScrollEdgeAppearance,
            matches: defaultNavigationBar.compactScrollEdgeAppearance,
            file: file,
            line: line
        )
        XCTAssertNil(navigationController.topViewController?.navigationItem.standardAppearance, file: file, line: line)
        XCTAssertNil(navigationController.topViewController?.navigationItem.scrollEdgeAppearance, file: file, line: line)
        XCTAssertNil(navigationController.topViewController?.navigationItem.compactAppearance, file: file, line: line)
        if #available(iOS 15.0, *) {
            XCTAssertNil(
                navigationController.topViewController?.navigationItem.compactScrollEdgeAppearance,
                file: file,
                line: line
            )
        }
    }

    private func assertNativeDefaultAppearance(
        _ actual: UINavigationBarAppearance?,
        matches expected: UINavigationBarAppearance?,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case let (actual?, expected?):
            assertNativeDefaultAppearance(actual, matches: expected, file: file, line: line)
        case (nil, nil):
            break
        default:
            XCTFail("Expected native default optional navigation bar appearance", file: file, line: line)
        }
    }

    private func assertNativeDefaultAppearance(
        _ actual: UINavigationBarAppearance,
        matches expected: UINavigationBarAppearance,
        file: StaticString,
        line: UInt
    ) {
        assertColor(actual.backgroundColor, matches: expected.backgroundColor, file: file, line: line)
        assertColor(actual.shadowColor, matches: expected.shadowColor, file: file, line: line)
        XCTAssertEqual(actual.backgroundImage == nil, expected.backgroundImage == nil, file: file, line: line)
        XCTAssertEqual(actual.shadowImage == nil, expected.shadowImage == nil, file: file, line: line)
        XCTAssertEqual(actual.backgroundEffect == nil, expected.backgroundEffect == nil, file: file, line: line)
        XCTAssertFalse(actual.shadowColor?.isEqual(UIColor.magenta) ?? false, file: file, line: line)
    }

    private func assertColor(
        _ actual: UIColor?,
        matches expected: UIColor?,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case let (actual?, expected?):
            XCTAssertTrue(actual.isEqual(expected), file: file, line: line)
        case (nil, nil):
            break
        default:
            XCTFail("Expected matching native default color", file: file, line: line)
        }
    }

    private func searchHostNavigationControllers() -> [UINavigationController] {
        let lastChats = LastChatsViewController()
        lastChats.configureSearchBar()

        let contacts = ContactsViewController()
        contacts.configureSearchBar()

        let calls = LastCallsViewController()
        calls.configureSearchBar()

        return [
            RecordingNavigationController(rootViewController: lastChats),
            RecordingNavigationController(rootViewController: contacts),
            RecordingNavigationController(rootViewController: calls)
        ]
    }

    private func directSearchHostControllers() -> [(String, UIViewController)] {
        [
            ("Last Chats", LastChatsViewController()),
            ("Contacts", ContactsViewController()),
            ("Calls", LastCallsViewController())
        ]
    }

    private func searchController(for viewController: UIViewController) -> UISearchController? {
        switch viewController {
        case let viewController as LastChatsViewController:
            return viewController.searchController
        case let viewController as ContactsViewController:
            return viewController.searchController
        case let viewController as LastCallsViewController:
            return viewController.searchController
        default:
            return nil
        }
    }

    private func activateInPlaceSearch(_ searchController: UISearchController) {
        searchController.searchBar.text = "romeo"
        searchController.isActive = true
    }

    private func attachToTraitWindow(
        _ viewController: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) {
        let window = TraitWindow(horizontalSizeClass: horizontalSizeClass)
        retainedTraitWindows.append(window)
        window.rootViewController = viewController
        window.frame = UIScreen.main.bounds
        window.isHidden = false
        window.layoutIfNeeded()
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
