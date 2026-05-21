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
