import CocoaLumberjack
import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

@MainActor
final class PEPDiagnosticLoggingTests: XCTestCase {
    private let owner = "pep-log-owner@example.invalid"

    private final class Capture: NSObject, DDLogger {
        var logFormatter: DDLogFormatter?
        private let lock = NSLock()
        private var messages: [String] = []

        func log(message: DDLogMessage) {
            lock.lock()
            messages.append(message.message)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    func testRoutineActivityAndIQCorrelationDoNotFloodTheLiveLog() throws {
        try capture { sink in
            for event in ["resilience_activity_observed", "resilience_outbound_stanza_observed",
                          "primary_stream_iq_response_correlated", "stream_management_ack_requested",
                          "stream_management_ack_received", "stream_management_raw_ack_received",
                          "stream_management_ack_sent", "primary_stream_bootstrap_sync_stanza_observed",
                          "primary_stream_non_health_stanza_observed"] {
                ConnectionDiagnosticsLogger.log(event: event, stream: .primary, jid: owner)
            }
            DDLog.flushLog()
            XCTAssertTrue(sink.snapshot().filter { $0.contains(owner) }.isEmpty)
        }
    }

    func testHealthySnapshotsAndDiagnosticOnlyTimeoutsAreQuiet() throws {
        try capture { sink in
            for _ in 0..<10 {
                ConnectionDiagnosticsLogger.log(
                    event: "connection_health_snapshot", stream: .primary, jid: owner,
                    details: ["isSuspectedStale": false, "pendingOutgoingCount": 0]
                )
                ConnectionDiagnosticsLogger.log(
                    event: "resilience_primary_stream_ack_timeout", stream: .primary, jid: owner,
                    details: ["action": "diagnosticOnly"]
                )
            }
            DDLog.flushLog()
            XCTAssertTrue(sink.snapshot().filter { $0.contains(owner) }.isEmpty)
        }
    }

    func testFailuresStaleStateAndLifecycleRemainVisible() throws {
        try capture { sink in
            for event in ["tls_secure", "tcp_disconnected", "resilience_ping_timeout",
                          "stream_management_ack_timeout", "new_diagnostic_event"] {
                ConnectionDiagnosticsLogger.log(event: event, stream: .primary, jid: owner)
            }
            ConnectionDiagnosticsLogger.log(
                event: "connection_health_snapshot", stream: .primary, jid: owner,
                details: ["isSuspectedStale": true]
            )
            ConnectionDiagnosticsLogger.log(
                event: "resilience_activity_observed", stream: .primary, jid: owner,
                error: NSError(domain: "PEPLoggingFixture", code: 1)
            )
            DDLog.flushLog()
            XCTAssertEqual(sink.snapshot().filter { $0.contains(owner) }.count, 7)
        }
    }

    func testEveryStreamKeepsCompleteOriginalXMLIncludingRepeatedWireFrames() throws {
        let xml = "<message id='same-id'><body>" + String(repeating: "original &amp; text\n", count: 2_000)
            + "</body><key>full-key-sentinel</key><unknown original='preserve'/></message>"
        let streams: [ConnectionDiagnosticsStreamKind] = [
            .primary, .background, .uiAction, .register, .changePassword, .accountDelete, .oneShot, .voip
        ]
        try capture { sink in
            for stream in streams {
                for _ in 0..<2 {
                    ConnectionDiagnosticsLogger.log(
                        event: "stanza_receive_message", stream: stream, jid: owner, rawXML: xml
                    )
                }
            }
            DDLog.flushLog()
            let messages = sink.snapshot().filter { $0.contains(owner) }
            XCTAssertEqual(messages.count, streams.count * 2)
            XCTAssertTrue(messages.allSatisfy { $0.hasSuffix("\n" + xml) })
        }
    }

    func testXMLAlwaysSurvivesEvenForAnOtherwiseQuietEvent() throws {
        let xml = "<a xmlns='urn:xmpp:sm:3' h='123' original='keep'/>"
        try capture { sink in
            ConnectionDiagnosticsLogger.log(
                event: "stream_management_ack_received", stream: .primary, jid: owner, rawXML: xml
            )
            DDLog.flushLog()
            XCTAssertEqual(sink.snapshot().filter { $0.hasSuffix("\n" + xml) }.count, 1)
        }
    }

    func testBundlePEPObserverDoesNotPrintTheStreamXMLAgain() throws {
        let message = try XMPPMessage(xmlString: "<message type='headline' from='\(owner)' id='bundle-wire-sentinel'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:bundles'><item id='7'><bundle xmlns='urn:xmpp:omemo:2'><unknown>original-bundle-sentinel</unknown></bundle></item></items></event></message>")
        let xml = message.prettyXMLString ?? message.xmlString
        let manager = OmemoManager(withOwner: owner)
        try capture { sink in
            ConnectionDiagnosticsLogger.log(
                event: "stanza_receive_message", stream: .primary, jid: owner, rawXML: xml
            )
            XCTAssertTrue(manager.onContactDeviceReceiveHeadline(message))
            DDLog.flushLog()
            XCTAssertEqual(sink.snapshot().filter { $0.contains("original-bundle-sentinel") }.count, 1)
            XCTAssertFalse(sink.snapshot().contains { $0.hasPrefix("OMEMO_BUNDLE") })
        }
    }

    func testStreamManagementWireFramesRetainFullXMLAfterQuietingAckMetadata() throws {
        let previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: UUID().uuidString)
        defer { Realm.Configuration.defaultConfiguration = previousRealm }
        let account = Account(jid: owner, queue: DispatchQueue(label: "PEPLogging.SM"))
        let stream = XMPPStream()
        account.xmppStream = stream
        let request = try DDXMLElement(xmlString: "<r xmlns='urn:xmpp:sm:3' trace='sm-request-sentinel'/>")
        let ack = try DDXMLElement(xmlString: "<a xmlns='urn:xmpp:sm:3' h='123' trace='sm-ack-sentinel'/>")
        try capture { sink in
            account.xmppStream(stream, didSendCustomElement: request)
            account.xmppStream(stream, didSendCustomElement: ack)
            account.xmppStream(stream, didReceiveCustomElement: request)
            account.xmppStream(stream, didReceiveCustomElement: ack)
            DDLog.flushLog()
            let frames = sink.snapshot().filter { $0.contains("sm-request-sentinel") || $0.contains("sm-ack-sentinel") }
            XCTAssertEqual(frames.count, 4)
            for frame in frames {
                XCTAssertTrue(frame.hasSuffix("\n" + (request.prettyXMLString ?? request.xmlString))
                    || frame.hasSuffix("\n" + (ack.prettyXMLString ?? ack.xmlString)))
            }
        }
        account.queue.sync {}
    }

    private func capture(_ action: (Capture) throws -> Void) throws {
        let sink = Capture()
        let previous = dynamicLogLevel
        DDLog.flushLog()
        dynamicLogLevel = .all
        DDLog.add(sink, with: .all)
        defer {
            DDLog.flushLog()
            DDLog.remove(sink)
            dynamicLogLevel = previous
        }
        try action(sink)
    }
}
