import XCTest
import CocoaLumberjack
@testable import xabber

final class XMPPWireLoggingOwnershipTests: XCTestCase {
    func testDebugSinkAdmitsTheNativeFrameworkSendAndReceiveFlags() {
        let level = AppLoggingPolicy.osLogLevel(isRelease: false).rawValue
        // XMPPLogging.h uses its own SEND/RECV_POST bits, above DDLogFlag.debug.
        XCTAssertNotEqual(level & UInt(1 << 5), 0)
        XCTAssertNotEqual(level & UInt(1 << 7), 0)
    }

    func testAppConnectionDiagnosticsDoNotDuplicateFrameworkWireXML() {
        let line = ConnectionDiagnosticsLogger.line(
            event: "stanza_receive_iq", stream: .primary,
            jid: "owner@example.invalid", details: ["type": "result"],
            rawXML: "<iq type='result'><body>framework-wire-fixture</body></iq>",
            includeRawXML: true)

        XCTAssertTrue(line.contains("stanza_receive_iq"))
        XCTAssertFalse(line.contains("<iq"))
        XCTAssertFalse(line.contains("framework-wire-fixture"),
                       "XMPPFramework owns wire logging; the app must not serialize another copy")
    }

    func testRawXMLDoesNotForceSuppressedRoutineDiagnostic() {
        XCTAssertFalse(ConnectionDiagnosticsLogger.shouldLog(
            event: "primary_stream_iq_response_correlated", details: [:],
            rawXML: "<iq type='result'/>", error: nil))
    }

    func testAppLoggerDoesNotInstallAnXMLModifierAroundFrameworkMessages() {
        let name = DDOSLogger.sharedInstance.logFormatter.map {
            String(describing: type(of: $0))
        } ?? "none"
        XCTAssertFalse(name.contains("XMPPPrivatePayloadLogFormatter"),
                       "Leave the framework's simple logger unwrapped")
    }
}
