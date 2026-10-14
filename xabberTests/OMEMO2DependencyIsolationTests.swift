import Foundation
import MachO
import XCTest
@testable import xabber

/// Verify the actual hosted application products, rather than the dependency
/// declarations: removed frameworks must not survive in an installed bundle.
final class OMEMO2DependencyIsolationTests: XCTestCase {
    private let retiredFrameworkNames = ["SignalProtocolC", "SignalProtocolObjC", "Curve25519Kit"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "This suite requires isolated hosted XCTest storage and disabled account autoconnect"
        )
    }

    func testInstalledApplicationAndNotificationExtensionContainOnlyTheNativeOMEMOCryptoProduct() throws {
        let app = Bundle.main
        XCTAssertEqual(app.bundleURL.pathExtension, "app", "Run this integration test in the application host")
        let appFrameworks = try frameworkInventory(in: app)
        let plugIns = try XCTUnwrap(app.builtInPlugInsURL)
        let extensionURL = plugIns.appendingPathComponent("xabber-push-extension.appex", isDirectory: true)
        let notificationExtension = try XCTUnwrap(Bundle(url: extensionURL), "The app must embed the notification extension")
        let extensionFrameworks = try frameworkInventory(in: notificationExtension)

        for (product, frameworks) in [("application", appFrameworks), ("notification extension", extensionFrameworks)] {
            let retired = frameworks.filter { containsRetiredFramework($0.lastPathComponent) }
            XCTAssertTrue(retired.isEmpty,
                          "The installed \(product) still contains retired crypto frameworks: \(retired.map(\.lastPathComponent))")
        }
        let nativeProduct = try XCTUnwrap(appFrameworks.first {
            $0.lastPathComponent.hasPrefix("XabberCryptoSwift") && $0.pathExtension == "framework"
        }, "The application must embed its linked XabberCryptoSwift package product")
        let nativeBundle = try XCTUnwrap(Bundle(url: nativeProduct))
        let nativeExecutable = try XCTUnwrap(nativeBundle.executableURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nativeExecutable.path),
                      "The embedded XabberCryptoSwift framework must contain its executable")
    }

    func testRunningApplicationLoadsNativeCryptoWithoutAnyRetiredSignalFramework() {
        let loadedImages = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return String(cString: name)
        }

        let retiredImages = loadedImages.filter(containsRetiredFramework)
        XCTAssertTrue(retiredImages.isEmpty, "The running application loaded retired crypto images: \(retiredImages)")
        XCTAssertTrue(loadedImages.contains { $0.contains("/XabberCryptoSwift") },
                      "The running application must load its linked XabberCryptoSwift package product")
    }

    private func frameworkInventory(in bundle: Bundle) throws -> [URL] {
        guard let directory = bundle.privateFrameworksURL,
              FileManager.default.fileExists(atPath: directory.path) else {
            // The notification extension may share the containing app's
            // frameworks through its runpath and have no private frameworks.
            return []
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func containsRetiredFramework(_ path: String) -> Bool {
        retiredFrameworkNames.contains { path.contains($0) }
    }
}
