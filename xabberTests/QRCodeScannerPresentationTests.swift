//
//  QRCodeScannerPresentationTests.swift
//  xabberTests
//
//  Created by Codex on 27.08.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class QRCodeScannerPresentationTests: XCTestCase {
    func testScannerMatchesFullscreenReferenceGeometry() throws {
        let controller = ScannerWithoutCaptureViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let camera = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.camera", in: controller.view)
        )
        let focus = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.focus", in: controller.view)
        )
        let back = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.back", in: controller.view)
        )
        let gallery = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.gallery", in: controller.view)
        )
        let torch = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.torch", in: controller.view)
        )
        let focusFrame = focus.convert(focus.bounds, to: controller.view)
        let galleryFrame = gallery.convert(gallery.bounds, to: controller.view)
        let torchFrame = torch.convert(torch.bounds, to: controller.view)

        XCTAssertEqual(controller.view.accessibilityIdentifier, "qr_scanner.screen")
        XCTAssertEqual(camera.frame, controller.view.bounds)
        XCTAssertEqual(focus.bounds.width, 260, accuracy: 0.5)
        XCTAssertEqual(focus.bounds.height, 260, accuracy: 0.5)
        XCTAssertEqual(focus.center.x, controller.view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(focus.center.y, controller.view.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(back.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(gallery.bounds.size, CGSize(width: 56, height: 56))
        XCTAssertEqual(torch.bounds.size, CGSize(width: 56, height: 56))
        XCTAssertEqual(galleryFrame.midY, torchFrame.midY, accuracy: 0.5)
        XCTAssertGreaterThan(galleryFrame.minY, focusFrame.maxY + 80)
        XCTAssertFalse(controller.prefersStatusBarHidden)
        XCTAssertNil(controller.title)
    }

    func testGalleryDecoderAcceptsQRCodeAndRejectsPlainImage() throws {
        let payload = "xmpp:alice@example.com"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let qrOutput = try XCTUnwrap(filter.outputImage)?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        )
        let qrImage = UIImage(ciImage: try XCTUnwrap(qrOutput))
        let plainImage = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image {
            UIColor.systemRed.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }

        XCTAssertEqual(QRCodeScannerImageDecoder.firstCode(in: qrImage), payload)
        XCTAssertNil(QRCodeScannerImageDecoder.firstCode(in: plainImage))
    }

    func testInvalidGalleryImageUsesReferenceAlertContent() throws {
        let controller = ScannerWithoutCaptureViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.showInvalidGalleryQRCodeAlert()
        controller.view.layoutIfNeeded()

        let alert = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.invalid_alert", in: controller.view)
        )
        let message = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.invalid_alert.message", in: alert) as? UILabel
        )
        let okButton = try XCTUnwrap(
            view(withIdentifier: "qr_scanner.invalid_alert.ok", in: alert) as? UIButton
        )

        XCTAssertEqual(
            message.text,
            "No valid QR code found in the image. Please try again."
        )
        XCTAssertEqual(okButton.currentTitle, "OK")
        XCTAssertEqual(alert.bounds.width, 300, accuracy: 0.5)
        XCTAssertEqual(okButton.bounds.height, 48, accuracy: 0.5)
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

@MainActor
private final class ScannerWithoutCaptureViewController: QRCodeScannerViewController {
    override func configure() {}
}
