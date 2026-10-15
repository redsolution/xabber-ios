//
//  LeftMenuSurfaceEffectFactoryTests.swift
//  xabberTests
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

final class LeftMenuSurfaceEffectFactoryTests: XCTestCase {
    func testFloatingPanelFitsPhoneAndTabletColumns() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852),
                     CGSize(width: 375, height: 1024), CGSize(width: 1024, height: 768)] {
            let safeArea = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
            let frame = LeftMenuFloatingLayout.frame(in: CGRect(origin: .zero, size: size),
                                                    safeArea: safeArea, contentHeight: 540)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertLessThanOrEqual(frame.width, 350)
            XCTAssertGreaterThanOrEqual(frame.minY, safeArea.top)
            XCTAssertLessThanOrEqual(frame.maxY, size.height - safeArea.bottom)
            XCTAssertLessThanOrEqual(frame.maxX, size.width - 16)
        }
    }

    func testShortWindowConstrainsPanelInsteadOfClippingSettings() {
        let frame = LeftMenuFloatingLayout.frame(in: CGRect(x: 0, y: 0, width: 700, height: 320),
                                                safeArea: .zero, contentHeight: 700)
        XCTAssertEqual(frame.height, 288)
        XCTAssertEqual(frame.minX, 16)
    }

    func testDefaultEffectUsesNativeGlassWhenAvailable() throws {
        let effect = LeftMenuSurfaceEffectFactory.makeEffect()

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertFalse(glassEffect.isInteractive)
            XCTAssertEqual(glassEffect.tintColor, XabberGlassStyle.nativeGlassTintColor)
        } else {
            XCTAssertTrue(effect is UIBlurEffect)
        }
    }

    func testFallbackEffectUsesExistingThinMaterialBlur() {
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .leftMenuSurface), .systemThinMaterial)
        XCTAssertTrue(LeftMenuSurfaceEffectFactory.makeEffect(prefersNativeGlass: false) is UIBlurEffect)
    }

    func testNativeGlassSurfaceBackgroundIsClearWhenAvailable() {
        if #available(iOS 26.0, *) {
            XCTAssertEqual(LeftMenuSurfaceEffectFactory.surfaceBackgroundColor(prefersNativeGlass: true), .clear)
        }
    }

    func testFallbackSurfaceBackgroundPreservesExistingOverlay() {
        XCTAssertEqual(
            LeftMenuSurfaceEffectFactory.surfaceBackgroundColor(prefersNativeGlass: false),
            XabberGlassStyle.leftMenuFallbackSurfaceBackgroundColor
        )
    }
}
