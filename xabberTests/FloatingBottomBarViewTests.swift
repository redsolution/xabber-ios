//
//  FloatingBottomBarViewTests.swift
//  xabberTests
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

final class FloatingBottomBarViewTests: XCTestCase {
    func testDefaultEffectUsesNativeGlassWhenAvailable() throws {
        let effect = NativeGlassBarStyle.makeEffect(interactive: true)

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertTrue(glassEffect.isInteractive)
            XCTAssertEqual(glassEffect.tintColor, NativeGlassBarStyle.nativeGlassTintColor)
        } else {
            XCTAssertTrue(effect is UIBlurEffect)
        }
    }

    func testFallbackEffectUsesSystemMaterialBlur() {
        XCTAssertEqual(NativeGlassBarStyle.fallbackBlurStyle, .systemMaterial)
        XCTAssertTrue(NativeGlassBarStyle.makeEffect(prefersNativeGlass: false) is UIBlurEffect)
    }

    func testControlsAreHostedInsideVisualEffectContentView() {
        let view = FloatingBottomBarView(frame: .zero)

        XCTAssertTrue(view.leftButton.superview === view)
        XCTAssertTrue(view.centerEffectView.superview === view)
        XCTAssertTrue(view.centerButton.superview === view.centerEffectView.contentView)
    }

    func testComponentDoesNotApplyCustomShadow() {
        let view = FloatingBottomBarView(frame: .zero)

        XCTAssertEqual(view.layer.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(view.centerEffectView.layer.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertNil(view.centerEffectView.layer.shadowPath)
    }

    func testComponentDoesNotApplyCustomBorder() {
        let view = FloatingBottomBarView(frame: .zero)

        XCTAssertEqual(view.centerEffectView.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertNil(view.centerEffectView.layer.borderColor)
    }

    func testLayoutMetricsMatchLastChatsBottomInsetContract() {
        XCTAssertEqual(FloatingBottomBarView.Metrics.height, NativeGlassBarStyle.minimumHeight)
        XCTAssertEqual(FloatingBottomBarView.Metrics.bottomOffset, NativeGlassBarStyle.bottomOffset)
        XCTAssertEqual(FloatingBottomBarView.Metrics.horizontalInset, NativeGlassBarStyle.horizontalInset)
        XCTAssertEqual(FloatingBottomBarView.Metrics.contentInset, NativeGlassBarStyle.contentInset)
        XCTAssertEqual(FloatingBottomBarView.Metrics.buttonSize, NativeGlassBarStyle.buttonSize)
        XCTAssertEqual(FloatingBottomBarView.Metrics.iconSize, NativeGlassBarStyle.iconSize)
        XCTAssertEqual(FloatingBottomBarView.Metrics.maxWidth, 360)
        XCTAssertEqual(FloatingBottomBarView.Metrics.reservedBottomInset, 60)
    }

    func testFilterButtonUsesDetachedGlassStyle() {
        let view = FloatingBottomBarView(frame: CGRect(x: 0, y: 0, width: 360, height: 44))
        view.layoutIfNeeded()

        XCTAssertEqual(view.leftButton.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(view.leftButton.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(view.leftButton.tintColor, NativeGlassBarStyle.iconTintColor)
        XCTAssertEqual(view.leftButton.contentHorizontalAlignment, .center)
        XCTAssertEqual(view.leftButton.contentVerticalAlignment, .center)
        XCTAssertEqual(view.leftButton.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(view.leftButton.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertEqual(view.leftButton.layer.shadowOpacity, 0, accuracy: 0.001)
    }

    func testCenterButtonUsesRoundedGlassSurface() {
        let view = FloatingBottomBarView(frame: CGRect(x: 0, y: 0, width: 360, height: 44))
        view.setCenterButtonTitle(
            "Action",
            accessibilityIdentifier: "test_center_action",
            accessibilityLabel: "Action"
        )
        view.layoutIfNeeded()

        XCTAssertEqual(view.centerButton.title(for: .normal), "Action")
        XCTAssertEqual(view.centerButton.accessibilityIdentifier, "test_center_action")
        XCTAssertEqual(view.centerEffectView.bounds.height, NativeGlassBarStyle.minimumHeight, accuracy: 0.001)
        XCTAssertEqual(view.centerEffectView.layer.cornerRadius, NativeGlassBarStyle.cornerRadius, accuracy: 0.001)
        XCTAssertEqual(view.centerButton.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(view.centerButton.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertEqual(view.centerButton.layer.shadowOpacity, 0, accuracy: 0.001)
    }
}

@MainActor
final class BottomSearchHostViewTests: XCTestCase {
    func testDefaultStateShowsRoundSearchButtonAndHidesExpandedSurface() {
        let view = BottomSearchHostView(frame: .zero)

        XCTAssertFalse(view.isExpanded)
        XCTAssertFalse(view.collapsedButton.isHidden)
        XCTAssertTrue(view.surfaceView.isHidden)
        XCTAssertEqual(view.collapsedButton.bounds.size, .zero)
        XCTAssertEqual(view.searchTextField.placeholder, "Search".localizeString(id: "search", arguments: []))
    }

    func testExpandedStateShowsSurfaceAndHidesCollapsedButton() {
        let view = BottomSearchHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))

        view.setExpanded(true, animated: false)

        XCTAssertTrue(view.isExpanded)
        XCTAssertTrue(view.collapsedButton.isHidden)
        XCTAssertFalse(view.surfaceView.isHidden)
    }

    func testCollapsedHitTestingOnlyReturnsRoundSearchButton() {
        let view = BottomSearchHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))
        view.layoutIfNeeded()

        let searchButtonPoint = view.convert(
            CGPoint(x: view.collapsedButton.bounds.midX, y: view.collapsedButton.bounds.midY),
            from: view.collapsedButton
        )
        let actionBarPoint = CGPoint(x: BottomSearchHostView.Metrics.horizontalInset, y: view.bounds.midY)

        XCTAssertTrue(view.hitTest(searchButtonPoint, with: nil) === view.collapsedButton)
        XCTAssertNil(view.hitTest(actionBarPoint, with: nil))
    }

    func testExpandedHitTestingRoutesInsideSearchSurfaceOnly() {
        let view = BottomSearchHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))

        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        view.setExpanded(true, animated: false)
        view.layoutIfNeeded()
        view.surfaceView.layoutIfNeeded()
        view.surfaceView.contentView.layoutIfNeeded()

        let surfacePoint = view.convert(
            CGPoint(x: view.surfaceView.bounds.midX, y: view.surfaceView.bounds.midY),
            from: view.surfaceView
        )
        let cancelPoint = view.convert(
            CGPoint(x: view.cancelButton.bounds.midX, y: view.cancelButton.bounds.midY),
            from: view.cancelButton
        )
        let outsideSurfacePoint = CGPoint(x: 1, y: view.bounds.midY)

        let surfaceHitView = view.hitTest(surfacePoint, with: nil)
        XCTAssertTrue(surfaceHitView === view.surfaceView || surfaceHitView?.isDescendant(of: view.surfaceView) == true)
        XCTAssertTrue(view.searchTextField.isDescendant(of: view.surfaceView))
        XCTAssertTrue(view.hitTest(cancelPoint, with: nil) === view.cancelButton)
        XCTAssertNil(view.hitTest(outsideSurfacePoint, with: nil))
    }

    func testExpandedSearchTextFieldUsesTransparentChrome() throws {
        let view = BottomSearchHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))

        view.setExpanded(true, animated: false)

        XCTAssertFalse(view.surfaceView.isHidden)
        XCTAssertEqual(view.searchTextField.backgroundColor, .clear)
        let layerBackgroundColor = try XCTUnwrap(view.searchTextField.layer.backgroundColor)
        XCTAssertTrue(UIColor(cgColor: layerBackgroundColor).isEqual(UIColor.clear))
        XCTAssertEqual(view.searchTextField.borderStyle, .none)
        XCTAssertEqual(view.searchTextField.background?.size, .zero)
        XCTAssertEqual(view.searchTextField.disabledBackground?.size, .zero)
        XCTAssertEqual(view.searchTextField.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertNil(view.searchTextField.layer.borderColor)
        XCTAssertEqual(view.searchTextField.layer.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(view.searchTextField.layer.shadowRadius, 0, accuracy: 0.001)
        XCTAssertEqual(view.searchTextField.layer.shadowOffset, .zero)
        XCTAssertNil(view.searchTextField.layer.shadowColor)
    }

    func testQueryChangesNotifyOwnerAndCancelClearsQuery() {
        let view = BottomSearchHostView(frame: .zero)
        var observedQueries: [String?] = []
        var didCancel = false
        view.onQueryChanged = { observedQueries.append($0) }
        view.onCancel = { didCancel = true }

        view.setExpanded(true, animated: false)
        view.setQuery("romeo", notify: true)
        view.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(observedQueries.compactMap { $0 }, ["romeo", ""])
        XCTAssertTrue(didCancel)
        XCTAssertFalse(view.isExpanded)
        XCTAssertEqual(view.query, "")
    }
}
