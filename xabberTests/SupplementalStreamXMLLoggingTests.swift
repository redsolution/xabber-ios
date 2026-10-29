import Foundation
import XCTest
import XMPPFramework
import CocoaLumberjack
import Darwin
@testable import xabber

final class SupplementalStreamXMLLoggingTests: XCTestCase {
    private let owner = "stream-log-owner@example.invalid"

    private final class CapturingLogger: NSObject, DDLogger {
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

    private final class OneShotManager: XMPPActionManager {
        override func endBackgroundUpdateTask() {}
    }

    private final class OneShotStream: XMPPStream {
        var onSend: ((DDXMLElement) -> Void)?
        override func send(_ element: DDXMLElement) { onSend?(element) }
        override func disconnectAfterSending() {}
    }

    func testUIActionFinalIQLogsOnceAcrossWillReceiveAndDidReceive() throws {
        try assertUIActionFinalLogging(willReceive: true, didReceive: true)
    }

    func testUIActionFinalIQStillLogsWhenDidReceiveIsBypassed() throws {
        try assertUIActionFinalLogging(willReceive: true, didReceive: false)
    }

    func testUIActionFinalIQStillLogsWhenOnlyDidReceiveIsCalled() throws {
        try assertUIActionFinalLogging(willReceive: false, didReceive: true)
    }

    func testOneShotQueueLogsEachStandardStanzaOnceAndRetainsCustomXML() throws {
        let manager = OneShotManager()
        let stream = OneShotStream()
        stream.myJID = XMPPJID(string: owner)
        manager.stream = stream
        manager.jid = owner
        let iq = try XMPPIQ(xmlString: "<iq type='get' id='one-shot-iq'><trace>one-shot-iq-payload</trace></iq>")
        let message = try XMPPMessage(xmlString: "<message to='\(owner)' id='one-shot-message'><body>one-shot-message-payload</body></message>")
        let presence = try XMPPPresence(xmlString: "<presence id='one-shot-presence'><status>one-shot-presence-payload</status></presence>")
        let custom = try DDXMLElement(xmlString: "<custom xmlns='urn:example:diagnostic'>one-shot-custom-payload</custom>")
        let prefixedCustom = try DDXMLElement(xmlString: "<custom:iq xmlns:custom='urn:example:diagnostic'>one-shot-prefixed-custom-payload</custom:iq>")
        manager.stanzaQueue = [iq, message, presence, custom, prefixedCustom]
        stream.onSend = { element in
            if let iq = element as? XMPPIQ { manager.xmppStream(stream, didSend: iq) }
            else if let message = element as? XMPPMessage { manager.xmppStream(stream, didSend: message) }
            else if let presence = element as? XMPPPresence { manager.xmppStream(stream, didSend: presence) }
        }

        let captured = try capture { manager.xmppStreamDidAuthenticate(stream) }

        for (element, marker) in [(iq as DDXMLElement, "one-shot-iq-payload"),
                                  (message, "one-shot-message-payload"),
                                  (presence, "one-shot-presence-payload"),
                                  (custom, "one-shot-custom-payload"),
                                  (prefixedCustom, "one-shot-prefixed-custom-payload")] {
            assertOneOriginalXML(element, marker: marker, in: captured)
        }
    }

    func testOneShotFailedIQRetainsCompleteXMLAndError() throws {
        let manager = OneShotManager()
        let iq = try XMPPIQ(xmlString: "<iq type='set' id='failed-iq'><secret>failed-iq-payload</secret></iq>")
        let error = NSError(domain: "stream-log-test", code: 17)

        let captured = try capture {
            manager.xmppStream(manager.stream, didFailToSend: iq, error: error)
        }

        assertOneOriginalXML(iq, marker: "failed-iq-payload", in: captured)
        XCTAssertTrue(captured.messages.contains { $0.contains("errorDomain=stream-log-test") && $0.contains("errorCode=17") })
    }

    func testVoIPCallbacksLogEachPayloadOnceWithoutSupplementalStdoutXML() throws {
        let call = VoIPCall(owner: owner, fullJid: "peer@example.invalid/device",
                            callId: "logging-call", callUUID: UUID(), outgoing: true)
        let sentIQ = try XMPPIQ(xmlString: "<iq type='result' id='voip-sent-iq'><trace>voip-sent-iq-payload</trace></iq>")
        let sentMessage = try XMPPMessage(xmlString: "<message id='voip-sent-message'><body>voip-sent-message-payload</body></message>")
        let receivedIQ = try XMPPIQ(xmlString: "<iq type='get' id='voip-received-iq'><query xmlns='jabber:iq:version'><trace>voip-received-iq-payload</trace></query></iq>")
        let receivedMessage = try XMPPMessage(xmlString: "<message id='voip-received-message'><body>voip-received-message-payload</body></message>")

        let captured = try capture {
            call.xmppStream(call.stream, didSend: sentIQ)
            call.xmppStream(call.stream, didSend: sentMessage)
            XCTAssertFalse(call.xmppStream(call.stream, didReceive: receivedIQ))
            call.xmppStream(call.stream, didReceive: receivedMessage)
        }

        for (element, marker) in [(sentIQ as DDXMLElement, "voip-sent-iq-payload"),
                                  (sentMessage, "voip-sent-message-payload"),
                                  (receivedIQ, "voip-received-iq-payload"),
                                  (receivedMessage, "voip-received-message-payload")] {
            assertOneOriginalXML(element, marker: marker, in: captured)
        }
    }

    private func assertUIActionFinalLogging(willReceive: Bool, didReceive: Bool) throws {
        let manager = XMPPUIActionManager()
        let stream = XMPPStream()
        stream.myJID = XMPPJID(string: owner)
        manager.stream = stream
        manager.currentJid = owner
        manager.mam = nil
        let queryID = "MAM next history: logging-\(UUID().uuidString)"
        var completionCount = 0
        let token = MessageArchiveEndPageDispatcher.register(owner: owner, queryId: queryID, delivery: .synchronous) { _ in
            completionCount += 1
        }
        defer { MessageArchiveEndPageDispatcher.unregister(token) }
        let iq = try XMPPIQ(xmlString: "<iq type='result' id='\(queryID)'><fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'><set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin><trace>ui-action-final-payload</trace></iq>")

        let captured = try capture {
            if willReceive { XCTAssertNotNil(manager.xmppStream(stream, willReceive: iq)) }
            if didReceive { XCTAssertTrue(manager.xmppStream(stream, didReceive: iq)) }
        }

        XCTAssertEqual(completionCount, 1)
        assertOneOriginalXML(iq, marker: "ui-action-final-payload", in: captured)
    }

    private func assertOneOriginalXML(_ element: DDXMLElement, marker: String,
                                      in captured: (messages: [String], standardOutput: String),
                                      file: StaticString = #filePath, line: UInt = #line) {
        let matching = captured.messages.filter { $0.contains(marker) }
        XCTAssertEqual(matching.count, 1, "Supplemental diagnostics must not print another XML copy", file: file, line: line)
        XCTAssertTrue(matching.first?.hasSuffix("\n" + (element.prettyXMLString ?? element.xmlString)) == true, file: file, line: line)
        XCTAssertFalse(captured.standardOutput.contains(marker), file: file, line: line)
    }

    private func capture(_ operation: () throws -> Void) throws -> (messages: [String], standardOutput: String) {
        let logger = CapturingLogger()
        let previousLevel = dynamicLogLevel
        DDLog.flushLog()
        dynamicLogLevel = .all
        DDLog.add(logger, with: .all)
        defer {
            DDLog.flushLog()
            DDLog.remove(logger)
            dynamicLogLevel = previousLevel
        }
        fflush(stdout)
        let originalDescriptor = dup(STDOUT_FILENO)
        guard originalDescriptor >= 0 else { throw NSError(domain: "stdout-capture", code: 1) }
        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(originalDescriptor)
            throw NSError(domain: "stdout-capture", code: 2)
        }
        var operationError: Error?
        do { try operation() } catch { operationError = error }
        DDLog.flushLog()
        fflush(stdout)
        _ = dup2(originalDescriptor, STDOUT_FILENO)
        close(originalDescriptor)
        pipe.fileHandleForWriting.closeFile()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        if let operationError { throw operationError }
        return (logger.snapshot(), String(decoding: output, as: UTF8.self))
    }
}
