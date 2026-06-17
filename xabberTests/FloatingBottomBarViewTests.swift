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

        XCTAssertTrue(view.leftButton.superview === view.effectView.contentView)
        XCTAssertTrue(view.titleLabel.superview === view.effectView.contentView)
        XCTAssertTrue(view.rightButton.superview === view.effectView.contentView)
    }

    func testComponentDoesNotApplyCustomShadow() {
        let view = FloatingBottomBarView(frame: .zero)

        XCTAssertEqual(view.layer.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(view.effectView.layer.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertNil(view.effectView.layer.shadowPath)
    }

    func testComponentDoesNotApplyCustomBorder() {
        let view = FloatingBottomBarView(frame: .zero)

        XCTAssertEqual(view.effectView.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertNil(view.effectView.layer.borderColor)
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

    func testButtonsUseSharedClearIconStyleWithoutIndividualBackgrounds() {
        let view = FloatingBottomBarView(frame: CGRect(x: 0, y: 0, width: 360, height: 44))
        view.layoutIfNeeded()

        for button in [view.leftButton, view.rightButton] {
            XCTAssertEqual(button.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            XCTAssertEqual(button.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            XCTAssertEqual(button.tintColor, NativeGlassBarStyle.iconTintColor)
            XCTAssertEqual(button.contentHorizontalAlignment, .center)
            XCTAssertEqual(button.contentVerticalAlignment, .center)
            XCTAssertEqual(button.backgroundColor ?? .clear, .clear)
            XCTAssertEqual(button.layer.borderWidth, 0, accuracy: 0.001)
            XCTAssertEqual(button.layer.shadowOpacity, 0, accuracy: 0.001)
            XCTAssertNil(button.configuration)
        }
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
        XCTAssertEqual(view.searchTextField.placeholder, ChatSearchResultsController.placeholderText)
    }

    func testExpandedStateShowsSurfaceAndHidesCollapsedButton() {
        let view = BottomSearchHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))

        view.setExpanded(true, animated: false)

        XCTAssertTrue(view.isExpanded)
        XCTAssertTrue(view.collapsedButton.isHidden)
        XCTAssertFalse(view.surfaceView.isHidden)
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
