//
//  SettingsAccountQRCodeTests.swift
//  xabberTests
//
//  Created by Codex on 27.08.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class SettingsAccountQRCodeTests: XCTestCase {
    func testDefaultModeKeepsTheLegacyQRCodePresentation() {
        let controller = QRCodeViewController()
        controller.username = "Alice"
        controller.jid = "alice@example.com"
        controller.stringValue = "xmpp:alice@example.com"
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.presentationMode, .legacy)
        XCTAssertNil(controller.view.accessibilityIdentifier)
        XCTAssertNotNil(controller.imageView.image)
        XCTAssertTrue(controller.avatarImageView.isDescendant(of: controller.logoInsideQR))
    }

    func testPayloadUsesCanonicalXMPPURI() {
        XCTAssertEqual(
            SettingsAccountQRCodePayload.string(for: "Alice@Example.com/mobile"),
            "xmpp:Alice@Example.com"
        )
    }

    func testThemeCatalogStartsWithCurrentChatThemeAndUsesExistingOptions() {
        let themes = SettingsAccountQRCodeThemeCatalog.themes(
            currentGradient: .greenBlue,
            currentBackgroundName: "Cats"
        )

        XCTAssertEqual(themes.first?.gradient, .greenBlue)
        XCTAssertEqual(themes.first?.backgroundName, "Cats")
        XCTAssertEqual(
            Set(themes.map { $0.gradient.rawValue }),
            Set(ChatViewController.BackgroundColor.allCases.map(\.rawValue))
        )
        XCTAssertTrue(
            themes.allSatisfy {
                SettingsAccountQRCodeThemeCatalog.chatBackgroundNames.contains($0.backgroundName)
            }
        )
        XCTAssertEqual(
            Set(themes.map { "\($0.gradient.rawValue)|\($0.backgroundName)" }).count,
            themes.count
        )
    }

    func testSettingsModeExposesAvatarAppLogoShareAndScanControls() throws {
        let controller = QRCodeViewController()
        controller.presentationMode = .settingsAccountCard
        controller.username = "Alice"
        controller.jid = "alice@example.com"
        controller.stringValue = SettingsAccountQRCodePayload.string(for: controller.jid)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.view.accessibilityIdentifier, "settings.account_qr.screen")
        XCTAssertNotNil(
            try XCTUnwrap(view(withIdentifier: "settings.account_qr.avatar", in: controller.view))
                as? UIImageView
        )
        let appLogo = try XCTUnwrap(
            view(withIdentifier: "settings.account_qr.app_logo", in: controller.view) as? UIImageView
        )
        XCTAssertNotNil(appLogo.image)
        XCTAssertNotNil(view(withIdentifier: "settings.account_qr.themes", in: controller.view))
        XCTAssertNotNil(view(withIdentifier: "settings.account_qr.share", in: controller.view))
        XCTAssertNotNil(view(withIdentifier: "settings.account_qr.scan", in: controller.view))
    }

    func testScanActionReusesExistingAddContactScanner() {
        XCTAssertTrue(SettingsAccountQRCodeRoute.makeScanner() is QRCodeScannerViewController)
    }

    func testScanButtonPushesTheExistingAddContactScanner() throws {
        let controller = QRCodeViewController()
        controller.presentationMode = .settingsAccountCard
        controller.jid = "alice@example.com"
        controller.stringValue = SettingsAccountQRCodePayload.string(for: controller.jid)
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()

        let scanButton = try XCTUnwrap(
            view(withIdentifier: "settings.account_qr.scan", in: controller.view) as? UIButton
        )
        scanButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(navigationController.topViewController is QRCodeScannerViewController)
    }

    func testShareExportContainsOnlyTheRenderedImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }

        let items = SettingsAccountQRCodeExportPolicy.activityItems(for: image)

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first is UIImage)
    }

    func testRenderedShareImageKeepsTheXMPPPayloadScannable() throws {
        let controller = QRCodeViewController()
        controller.presentationMode = .settingsAccountCard
        controller.username = "Alice"
        controller.jid = "alice@example.com"
        controller.stringValue = SettingsAccountQRCodePayload.string(for: controller.jid)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let image = try XCTUnwrap(controller.makeSettingsAccountShareImage())
        let detector = try XCTUnwrap(
            CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
        )
        let ciImage = try XCTUnwrap(CIImage(image: image))
        let features = detector.features(in: ciImage)
        let messages = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }

        XCTAssertEqual(image.size, CGSize(width: 390, height: 844))
        XCTAssertTrue(messages.contains("xmpp:alice@example.com"))
    }

    func testDarkRenderedShareImageKeepsTheXMPPPayloadScannable() throws {
        let controller = QRCodeViewController()
        controller.presentationMode = .settingsAccountCard
        controller.jid = "alice@example.com"
        controller.stringValue = SettingsAccountQRCodePayload.string(for: controller.jid)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()

        let appearanceButton = try XCTUnwrap(
            view(withIdentifier: "settings.account_qr.appearance", in: controller.view) as? UIButton
        )
        appearanceButton.sendActions(for: .touchUpInside)

        let image = try XCTUnwrap(controller.makeSettingsAccountShareImage())
        let ciImage = try XCTUnwrap(CIImage(image: image))
        let detector = try XCTUnwrap(
            CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
        )
        let messages = detector.features(in: ciImage)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }

        XCTAssertTrue(messages.contains("xmpp:alice@example.com"))
    }

    private func view(withIdentifier identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = view(withIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}
