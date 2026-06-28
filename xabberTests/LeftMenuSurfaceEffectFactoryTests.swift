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
