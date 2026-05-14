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
        let effect = BottomBarGlassEffectFactory.makeEffect()

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertTrue(glassEffect.isInteractive)
        } else {
            XCTAssertTrue(effect is UIBlurEffect)
        }
    }

    func testFallbackEffectUsesSystemMaterialBlur() {
        XCTAssertEqual(BottomBarGlassEffectFactory.fallbackBlurStyle, .systemMaterial)
        XCTAssertTrue(BottomBarGlassEffectFactory.makeEffect(prefersNativeGlass: false) is UIBlurEffect)
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
    }

    func testLayoutMetricsMatchLastChatsBottomInsetContract() {
        XCTAssertEqual(FloatingBottomBarView.Metrics.height, 44)
        XCTAssertEqual(FloatingBottomBarView.Metrics.bottomOffset, 4)
        XCTAssertEqual(FloatingBottomBarView.Metrics.horizontalInset, 16)
        XCTAssertEqual(FloatingBottomBarView.Metrics.contentInset, 10)
        XCTAssertEqual(FloatingBottomBarView.Metrics.buttonSize, 44)
        XCTAssertEqual(FloatingBottomBarView.Metrics.iconSize, 20)
        XCTAssertEqual(FloatingBottomBarView.Metrics.maxWidth, 360)
        XCTAssertEqual(FloatingBottomBarView.Metrics.reservedBottomInset, 60)
    }
}
