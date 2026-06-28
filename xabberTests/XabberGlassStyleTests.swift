//
//  XabberGlassStyleTests.swift
//  xabberTests
//
//  Created by Codex on 25.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

final class XabberGlassStyleTests: XCTestCase {
    func testBarEffectUsesUntintedStandardNativeGlassWhenAvailable() throws {
        let effect = XabberGlassStyle.makeEffect(role: .bar, interactive: true)

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertTrue(glassEffect.isInteractive)
            XCTAssertNil(glassEffect.tintColor)
        } else {
            XCTAssertTrue(effect is UIBlurEffect)
        }
    }

    func testDefaultNativeGlassTintMatchesUntintedSystemNavbarButtons() {
        XCTAssertNil(XabberGlassStyle.nativeGlassTintColor)
    }

    func testRoleFallbackBlurStylesAreCentralized() {
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .bar), .systemMaterial)
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .audioPlayer), .systemMaterial)
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .leftMenuSurface), .systemThinMaterial)
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .splitCellNormal), .systemThinMaterial)
        XCTAssertEqual(XabberGlassStyle.fallbackBlurStyle(for: .splitCellHighlighted), .systemMaterial)

        XCTAssertTrue(XabberGlassStyle.makeEffect(role: .leftMenuSurface, prefersNativeGlass: false) is UIBlurEffect)
        XCTAssertTrue(XabberGlassStyle.makeEffect(role: .splitCellNormal, prefersNativeGlass: false) is UIBlurEffect)
        XCTAssertTrue(XabberGlassStyle.makeEffect(role: .splitCellHighlighted, prefersNativeGlass: false) is UIBlurEffect)
    }

    func testApplySurfaceClearsCustomChromeAndAppliesFixedCorners() {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.backgroundColor = .red
        view.contentView.backgroundColor = .blue
        view.isOpaque = true
        view.layer.borderWidth = 2
        view.layer.borderColor = UIColor.green.cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.5
        view.layer.shadowRadius = 12
        view.layer.shadowOffset = CGSize(width: 1, height: 2)
        view.layer.shadowPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10)).cgPath

        XabberGlassStyle.applySurface(
            to: view,
            role: .bar,
            cornerStyle: .fixed(18),
            interactive: false
        )

        XCTAssertEqual(view.backgroundColor, .clear)
        XCTAssertEqual(view.contentView.backgroundColor, .clear)
        XCTAssertFalse(view.isOpaque)
        XCTAssertTrue(view.clipsToBounds)
        XCTAssertEqual(view.layer.cornerRadius, 18, accuracy: 0.001)
        XCTAssertEqual(view.layer.cornerCurve, .continuous)
        XCTAssertEqual(view.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertNil(view.layer.borderColor)
        XCTAssertNil(view.layer.shadowColor)
        XCTAssertEqual(view.layer.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(view.layer.shadowRadius, 0, accuracy: 0.001)
        XCTAssertEqual(view.layer.shadowOffset, .zero)
        XCTAssertNil(view.layer.shadowPath)
    }

    func testDetachedIconButtonUsesStandardGlassConfigurationOrFallbackEffectView() throws {
        let button = UIButton(type: .system)

        XabberGlassStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: .label,
            image: nil
        )

        XCTAssertEqual(button.tintColor, .label)
        XCTAssertEqual(button.contentHorizontalAlignment, .center)
        XCTAssertEqual(button.contentVerticalAlignment, .center)
        XCTAssertEqual(button.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(button.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertEqual(button.layer.shadowOpacity, 0, accuracy: 0.001)

        if #available(iOS 26.0, *) {
            let configuration = try XCTUnwrap(button.configuration)
            XCTAssertEqual(configuration.baseForegroundColor, .label)
            XCTAssertEqual(configuration.contentInsets, NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            let configurationDescription = String(describing: configuration)
            XCTAssertTrue(configurationDescription.contains("baseStyle=glass"))
            XCTAssertFalse(configurationDescription.contains("baseStyle=clearGlass"))
            XCTAssertTrue(button.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
        } else {
            let effectView = try? XCTUnwrap(button.subviews.compactMap { $0 as? UIVisualEffectView }.first)
            XCTAssertNotNil(effectView)
        }
    }
}
