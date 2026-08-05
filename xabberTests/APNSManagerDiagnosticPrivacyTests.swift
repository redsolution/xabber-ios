import Foundation
import XCTest
import CocoaLumberjack
#if canImport(Darwin)
import Darwin
#endif
@testable import xabber

final class APNSManagerDiagnosticPrivacyTests: XCTestCase {
    private enum StandardOutputCaptureError: Error {
        case couldNotDuplicateDescriptor
        case couldNotRedirectDescriptor
    }

    private final class CapturingDDLogger: NSObject, DDLogger {
        var logFormatter: DDLogFormatter?

        private let lock = NSLock()
        private var storage: [String] = []

        func log(message logMessage: DDLogMessage) {
            lock.lock()
            storage.append(logMessage.message)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct SyntheticSensitiveFixture {
        let payload: [AnyHashable: Any]
        let nodeData: APNSManager.NodeData
        let encodedBody: String
        let sentinels: [String]
    }

    func testAppSideDiagnosticsContainNoRawPayloadOrIdentitySinkPatterns() throws {
        let source = try appSideManagerSource()
        let forbiddenSinkFragments = [
            "print(\"\\(api)\\(url)\")",
            "\\(pushData)",
            "print(target)",
            "dict.value(forKey: \"body\")",
            "\\(targetType)",
            "\\(base64EncodedString)",
            "\\(json.action)",
            "print(\"REGJID json\", json)",
            "print(registrationInfo)",
            "print(result)",
            "print(jid)",
            "print(service)",
            "print(\"REGISTR INFO\", node, service)",
            "print(stanzaIds)"
        ]

        let matches = activeDiagnosticLines(in: source).filter { line in
            forbiddenSinkFragments.contains(where: line.contains)
        }

        XCTAssertTrue(
            matches.isEmpty,
            "APNSManager app-side diagnostics contain \(matches.count) raw payload or identity sink patterns"
        )
    }

    func testSyntheticForbiddenFieldsCannotReachAppSideDiagnosticSinks() throws {
        let fixture = try syntheticSensitiveFixture()
        let rawRepresentations = [
            String(describing: fixture.payload),
            String(describing: fixture.nodeData),
            fixture.encodedBody
        ]

        for sentinel in fixture.sentinels {
            XCTAssertTrue(
                rawRepresentations.contains(where: { $0.contains(sentinel) }),
                "The synthetic fixture must prove every forbidden field is observable through raw interpolation"
            )
        }

        let matches = activeDiagnosticLines(in: try appSideManagerSource())

        XCTAssertTrue(
            matches.isEmpty,
            "APNSManager must route diagnostics through an injected typed seam instead of \(matches.count) direct stdout/logger sink calls"
        )
    }

    func testTypedEventsRenderOnlyAllowlistedCategoriesBooleansAndBoundedCounts() {
        let rawAction = sentinel(label: "raw-action")
        let rawTarget = sentinel(label: "raw-target")
        let rawResult = sentinel(label: "raw-result")
        let rawPath = "private/\(sentinel(label: "raw-path"))?token=hidden"
        let events: [APNSDiagnosticEvent] = [
            .endpointResolved(
                hasScheme: true,
                hasHost: true,
                pathCategory: APNSDiagnosticPathCategory.classify(rawPath)
            ),
            .received(
                targetType: APNSDiagnosticTargetCategory.classify(rawTarget),
                hasTarget: true,
                hasBody: true
            ),
            .decoded(
                action: APNSDiagnosticActionCategory.classify(rawAction)
            ),
            .registration(
                result: APNSDiagnosticRegistrationResultCategory.classify(rawResult),
                hasJID: true,
                hasNode: true,
                hasService: true
            ),
            .displayed(stanzaIDCount: Int.max),
            .displayed(stanzaIDCount: -1)
        ]

        let lines = events.map(\.diagnosticLine)

        XCTAssertEqual(
            lines,
            [
                "APNS_DIAGNOSTIC event=endpoint_resolved hasScheme=true hasHost=true pathCategory=unknown",
                "APNS_DIAGNOSTIC event=received targetType=unknown hasTarget=true hasBody=true",
                "APNS_DIAGNOSTIC event=decoded action=unknown",
                "APNS_DIAGNOSTIC event=registration result=failure hasJID=true hasNode=true hasService=true",
                "APNS_DIAGNOSTIC event=displayed stanzaIDCount=10000",
                "APNS_DIAGNOSTIC event=displayed stanzaIDCount=0"
            ]
        )
        let output = lines.joined(separator: "\n")
        [rawAction, rawTarget, rawResult, rawPath].forEach { forbiddenValue in
            XCTAssertFalse(
                output.contains(forbiddenValue),
                "Typed APNS diagnostic rendering must not retain a raw classifier input"
            )
        }
    }

    func testInjectedSinkReceivesTypedEventsWithoutStringPayloadSlots() {
        var capturedEvents: [APNSDiagnosticEvent] = []
        let logger = APNSDiagnosticLogger { event in
            capturedEvents.append(event)
        }
        let expectedEvents: [APNSDiagnosticEvent] = [
            .received(targetType: .node, hasTarget: true, hasBody: true),
            .decoded(action: .data),
            .registration(
                result: .missing,
                hasJID: false,
                hasNode: false,
                hasService: false
            ),
            .displayed(stanzaIDCount: 2)
        ]

        expectedEvents.forEach { event in
            logger.record(event)
        }

        XCTAssertEqual(capturedEvents, expectedEvents)
        XCTAssertEqual(
            capturedEvents.map(\.diagnosticLine),
            [
                "APNS_DIAGNOSTIC event=received targetType=node hasTarget=true hasBody=true",
                "APNS_DIAGNOSTIC event=decoded action=data",
                "APNS_DIAGNOSTIC event=registration result=missing hasJID=false hasNode=false hasService=false",
                "APNS_DIAGNOSTIC event=displayed stanzaIDCount=2"
            ]
        )
    }

    func testUnknownActionReceiveWritesOnlySanitizedCocoaDiagnosticsAndNoStdout() throws {
        let fixture = try syntheticSensitiveFixture()
        let manager = APNSManager(diagnostics: .live)
        var receiveResult: APNSManager.ReceiveResult?
        var completionCount = 0

        let capture = try captureCocoaDiagnosticsAndStandardOutput {
            receiveResult = try manager.receive(
                fixture.payload,
                completionHandler: {
                    completionCount += 1
                }
            )
        }

        XCTAssertEqual(receiveResult, .ignored)
        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(
            capture.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        XCTAssertEqual(
            capture.cocoaMessages.filter { $0.hasPrefix("APNS_DIAGNOSTIC ") },
            [
                "APNS_DIAGNOSTIC event=received targetType=node hasTarget=true hasBody=true",
                "APNS_DIAGNOSTIC event=decoded action=unknown"
            ]
        )

        let capturedOutput = ([capture.standardOutput] + capture.cocoaMessages)
            .joined(separator: "\n")
        let forbiddenValues = fixture.sentinels + [
            fixture.encodedBody,
            String(describing: fixture.payload),
            String(describing: fixture.nodeData)
        ]
        forbiddenValues.forEach { forbiddenValue in
            XCTAssertFalse(
                capturedOutput.contains(forbiddenValue),
                "APNS receive diagnostics must not expose a synthetic raw or composite value"
            )
        }
    }

    func testAPIURLDiagnosticUsesPresenceAndFixedPathCategoryOnly() {
        let rawQuery = sentinel(label: "url-query")
        var capturedEvents: [APNSDiagnosticEvent] = []
        let logger = APNSDiagnosticLogger { event in
            capturedEvents.append(event)
        }

        let resolvedURL = APNSManager.apiUrl(
            for: "jid/endpoints/?token=\(rawQuery)",
            diagnostics: logger
        )

        XCTAssertEqual(capturedEvents.count, 1)
        guard let endpointEvent = capturedEvents.first else {
            XCTFail("Expected one endpoint-resolution diagnostic")
            return
        }
        guard case .endpointResolved(
            _,
            _,
            let pathCategory
        ) = endpointEvent else {
            XCTFail("Expected one endpoint-resolution diagnostic")
            return
        }
        XCTAssertEqual(pathCategory, .jidEndpoints)
        XCTAssertFalse(capturedEvents[0].diagnosticLine.contains(rawQuery))
        if !resolvedURL.isEmpty {
            XCTAssertFalse(capturedEvents[0].diagnosticLine.contains(resolvedURL))
        }
    }

    private func syntheticSensitiveFixture() throws -> SyntheticSensitiveFixture {
        let action = sentinel(label: "action")
        let target = sentinel(label: "target")
        let jid = "\(sentinel(label: "owner"))@example.invalid/ios"
        let node = sentinel(label: "node")
        let service = "https://\(sentinel(label: "service")).example.invalid/private/path?token=hidden"
        let result = sentinel(label: "result")
        let encrypted = sentinel(label: "encrypted")
        let outer = sentinel(label: "outer")
        let nodeData = APNSManager.NodeData(
            action: action,
            node: node,
            jid: jid,
            result: result,
            service: service,
            encrypted: encrypted
        )
        let data = try JSONEncoder().encode(nodeData)
        let encodedBody = data.base64EncodedString()
        let payload: [AnyHashable: Any] = [
            "target_type": "node",
            "target": target,
            "body": encodedBody,
            "unexpected": outer
        ]

        return SyntheticSensitiveFixture(
            payload: payload,
            nodeData: nodeData,
            encodedBody: encodedBody,
            sentinels: [
                action,
                target,
                jid,
                node,
                service,
                result,
                encrypted,
                outer
            ]
        )
    }

    private func appSideManagerSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("xabber")
            .appendingPathComponent("xmpp")
            .appendingPathComponent("push_notifications")
            .appendingPathComponent("APNS")
            .appendingPathComponent("APNSManager.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func captureCocoaDiagnosticsAndStandardOutput(
        _ operation: () throws -> Void
    ) throws -> (standardOutput: String, cocoaMessages: [String]) {
        let cocoaLogger = CapturingDDLogger()
        let previousDynamicLogLevel = dynamicLogLevel
        dynamicLogLevel = .all
        DDLog.add(cocoaLogger, with: .all)
        DDLog.flushLog()
        defer {
            DDLog.remove(cocoaLogger)
            dynamicLogLevel = previousDynamicLogLevel
        }

        let standardOutput = try captureStandardOutput(operation)
        DDLog.flushLog()
        return (standardOutput, cocoaLogger.snapshot())
    }

    private func captureStandardOutput(
        _ operation: () throws -> Void
    ) throws -> String {
        Darwin.fflush(Darwin.stdout)
        let originalDescriptor = Darwin.dup(STDOUT_FILENO)
        guard originalDescriptor >= 0 else {
            throw StandardOutputCaptureError.couldNotDuplicateDescriptor
        }

        let pipe = Pipe()
        guard Darwin.dup2(
            pipe.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        ) >= 0 else {
            Darwin.close(originalDescriptor)
            throw StandardOutputCaptureError.couldNotRedirectDescriptor
        }

        var operationError: Error?
        do {
            try operation()
        } catch {
            operationError = error
        }

        Darwin.fflush(Darwin.stdout)
        _ = Darwin.dup2(originalDescriptor, STDOUT_FILENO)
        Darwin.close(originalDescriptor)
        pipe.fileHandleForWriting.closeFile()

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        if let operationError {
            throw operationError
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func activeDiagnosticLines(in source: String) -> [String] {
        source.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else {
                return false
            }
            return trimmed.contains("print(")
                || trimmed.contains("DDLog")
                || trimmed.contains("NSLog")
                || trimmed.contains("os_log")
                || trimmed.contains("Logger(")
        }
    }

    private func sentinel(label: String) -> String {
        "synthetic-\(label)-\(UUID().uuidString)-\(UUID().uuidString)"
    }
}
