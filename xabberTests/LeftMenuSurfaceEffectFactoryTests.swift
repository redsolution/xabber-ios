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

    func testExpandedTabletSidebarUsesWholeColumnWithoutAnInsetCard() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 1024)
        let frame = LeftMenuFloatingLayout.frame(
            in: bounds, safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
            contentHeight: 540, fillsColumn: true)
        XCTAssertEqual(frame, bounds)
    }

    func testExpandedColumnHasNoSecondGlassEffect() {
        XCTAssertNil(LeftMenuSurfaceEffectFactory.makeEffect(fillsColumn: true))
        XCTAssertNotNil(LeftMenuSurfaceEffectFactory.makeEffect(fillsColumn: false))
    }

    @MainActor
    func testCompactMenuBackdropReplacesAndReleasesCapturedContent() {
        let backdrop = LeftMenuCompactBackdropView()
        let firstScreen = UIView()
        let nextScreen = UIView()
        backdrop.show(firstScreen)
        XCTAssertTrue(firstScreen.superview === backdrop)
        XCTAssertFalse(backdrop.isHidden)
        backdrop.show(nextScreen)
        XCTAssertNil(firstScreen.superview)
        XCTAssertTrue(nextScreen.superview === backdrop)
        XCTAssertEqual(backdrop.subviews.count, 1)
        XCTAssertEqual(nextScreen.alpha, 0.5)
        backdrop.show(nil)
        XCTAssertNil(nextScreen.superview)
        XCTAssertTrue(backdrop.isHidden)
    }

    @MainActor
    func testCompactBlurPreservesWallpaperColorInsteadOfAddingGrayMaterial() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let blurred = try XCTUnwrap(LeftMenuCompactBackdropView.blurredImage(source))
        let cgImage = try XCTUnwrap(blurred.cgImage)
        var pixel: [UInt8] = [0, 0, 0, 0]
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertLessThan(pixel[0], 10)
        XCTAssertGreaterThan(pixel[1], 245)
        XCTAssertLessThan(pixel[2], 10)
        XCTAssertGreaterThan(pixel[3], 245)
    }

    func testPhoneCardLeavesAnExposedStripOfUnderlyingContent() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let frame = LeftMenuFloatingLayout.frame(in: bounds, safeArea: .zero, contentHeight: 540)
        XCTAssertGreaterThan(bounds.maxX - frame.maxX, 40)
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
