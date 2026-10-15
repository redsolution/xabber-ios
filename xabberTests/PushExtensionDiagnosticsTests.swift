import Foundation
import XCTest
@testable import xabber

final class PushExtensionDiagnosticsTests: XCTestCase {
    func testOfflineDiagnosticLaunchPreservesRealStorageAndDisablesAccountAutoconnect() {
        let environment = ["XABBER_PUSH_DIAGNOSTICS_OFFLINE": "1"]

        XCTAssertTrue(PushExtensionDiagnostics.isOfflineHostRun(environment: environment))
        XCTAssertFalse(AppLaunchEnvironmentPolicy.shouldAutoconnectAccounts(isPushKit: false, environment: environment))
        XCTAssertNil(AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(environment: environment))
        XCTAssertFalse(PushExtensionDiagnostics.isOfflineHostRun(environment: [:]))
        XCTAssertFalse(PushExtensionDiagnostics.isOfflineHostRun(environment: ["XABBER_PUSH_DIAGNOSTICS_OFFLINE": "0"]))
    }

    func testFullMultilineUnicodePayloadIsAppendedWithoutReplacementOrConsoleTruncation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("extension.log")
        var console: [String] = []
        let logger = PushExtensionDiagnostics(fileURL: url, console: { console.append($0) })
        let xml = "<message><body>" + String(repeating: "Привет 👋 &amp; ", count: 900) + "</body>\n<key>literal-key-sentinel</key></message>"

        logger.record(xml)
        logger.record("event=complete")

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains(xml))
        XCTAssertTrue(saved.hasSuffix("event=complete\n"))
        let payloadParts = console.filter { $0.contains("part=") && !$0.contains("event=complete") }
        let reconstructed = payloadParts.map { part -> String in
            guard let newline = part.firstIndex(of: "\n") else { return "" }
            return String(part[part.index(after: newline)...])
        }
        XCTAssertGreaterThan(payloadParts.count, 1)
        XCTAssertTrue(payloadParts.allSatisfy { $0.utf8.count < 1024 })
        XCTAssertEqual(reconstructed.joined(), xml)
    }

    func testConcurrentRecordsPreserveEveryCompleteEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("extension.log")
        let logger = PushExtensionDiagnostics(fileURL: url, console: { _ in })

        DispatchQueue.concurrentPerform(iterations: 30) { logger.record("entry=\($0)") }

        let saved = try String(contentsOf: url, encoding: .utf8)
        for value in 0..<30 { XCTAssertEqual(saved.components(separatedBy: " entry=\(value)\n").count - 1, 1) }
    }

    func testFileFailureStillEmitsUnmodifiedPayloadToConsole() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        var console: [String] = []
        let logger = PushExtensionDiagnostics(fileURL: directory.appendingPathComponent("extension.log"),
                                              console: { console.append($0) })

        logger.record("<payload>unchanged</payload>")

        XCTAssertTrue(console.contains { $0.contains("event=log_write_failed") })
        XCTAssertTrue(console.contains { $0.hasSuffix("<payload>unchanged</payload>") })
    }
}
