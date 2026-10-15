import Foundation
import XCTest
import XMPPFramework
import CocoaLumberjack
@testable import xabber

final class PushEnableDiagnosticsTests: XCTestCase {
    private let owner = "private-jid-sentinel@example.invalid"
    private var fixtures: [Fixture] = []

    private final class Stream: XMPPStream {
        private(set) var sent: [DDXMLElement] = []
        var autoDidSend = true
        var onSend: ((DDXMLElement) -> Void)?
        override func send(_ element: DDXMLElement) {
            let copy = element.copy() as! DDXMLElement
            sent.append(copy)
            if autoDidSend { onSend?(copy) }
        }
    }

    private final class Events {
        var values: [PushRegistrationDiagnosticEvent] = []
    }

    private final class CapturingLogger: NSObject, DDLogger {
        var logFormatter: DDLogFormatter?
        private let lock = NSLock()
        private var messages: [(message: String, flag: DDLogFlag)] = []

        func log(message logMessage: DDLogMessage) {
            lock.lock()
            messages.append((logMessage.message, logMessage.flag))
            lock.unlock()
        }

        func snapshot() -> [(message: String, flag: DDLogFlag)] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    private final class Memory {
        var record: CredentialsManager.PushSecretData
        init(_ record: CredentialsManager.PushSecretData) { self.record = record }
    }

    private final class Timeouts {
        var actions: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
            actions.append(action)
            return {}
        }
    }

    private struct Fixture {
        let manager: PushNotificationsManager
        let stream: Stream
        let events: Events
        let memory: Memory
        let timeouts: Timeouts
        let node: String
        let directory: URL
    }

    override func tearDown() {
        for fixture in fixtures {
            fixture.manager.clearSession()
            PushNotificationsManager.removeDefaultsForPush(target: fixture.node, jid: owner)
            if fixture.manager.node != fixture.node {
                PushNotificationsManager.removeDefaultsForPush(target: fixture.manager.node, jid: owner)
            }
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        super.tearDown()
    }

    func testSentDiagnosticMatchesActualIQIDAndRequestedModeForBothWireValues() throws {
        for mode in [PushPayloadMode.full, .summary] {
            let f = fixture(mode: mode)
            f.stream.autoDidSend = false

            f.manager.enable(xmppStream: f.stream) { _ in }

            let id = try requestID(f)
            XCTAssertEqual(f.events.values, [.queued(request: id, mode: mode)])
            let iq = XMPPIQ(from: try XCTUnwrap(f.stream.sent.first))
            f.manager.didSend(iq, xmppStream: Stream())
            XCTAssertEqual(f.events.values, [.queued(request: id, mode: mode)])
            f.manager.didSend(iq, xmppStream: f.stream)
            f.manager.didSend(iq, xmppStream: f.stream)
            XCTAssertEqual(f.events.values, [.queued(request: id, mode: mode), .sent(request: id, mode: mode)])
            let enable = try XCTUnwrap(f.stream.sent.first?.element(forName: "enable"))
            XCTAssertEqual(enable.xmlns(), "https://xabber.com/protocol/push")
            XCTAssertEqual(enable.attributeStringValue(forName: "mode"), mode.rawValue)
            XCTAssertEqual(enable.element(forName: "security")?.attributeStringValue(forName: "cipher"), "urn:xmpp:ciphers:aes-256cbc")
            XCTAssertEqual(enable.element(forName: "security")?.element(forName: "encryption-key")?.stringValue,
                           Data(f.memory.record.keyBytes!).base64EncodedString())
            XCTAssertNil(enable.element(forName: "encryption"))
        }
    }

    func testPendingCapabilityEmitsWaitingThenSentForTheSameRequest() throws {
        let f = fixture()
        f.manager.awaitCustomPushSupport()

        f.manager.enable(xmppStream: f.stream) { _ in }

        let id = try pendingRequestID(f)
        XCTAssertTrue(f.stream.sent.isEmpty)
        XCTAssertEqual(f.events.values, [.waiting(request: id)])
        f.manager.setCustomPushSupport(true, xmppStream: f.stream)
        XCTAssertEqual(try requestID(f), id)
        XCTAssertEqual(f.events.values, [.waiting(request: id), .queued(request: id, mode: .summary), .sent(request: id, mode: .summary)])
    }

    func testAccountDelegateRoutesActualDidSendIntoPushDiagnosticsOnce() throws {
        let f = fixture()
        f.stream.autoDidSend = false
        let account = Account(jid: owner, queue: DispatchQueue(label: "PushEnableDiagnostics.delegate.\(UUID())"))
        account.xmppStream = f.stream
        account.push = f.manager
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)
        let iq = XMPPIQ(from: try XCTUnwrap(f.stream.sent.first))
        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary)])

        account.xmppStream(Stream(), didSend: iq)
        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary)])
        account.xmppStream = Stream()
        account.xmppStream(f.stream, didSend: iq)
        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary)])
        account.xmppStream = f.stream
        account.xmppStream(f.stream, didSend: iq)
        account.xmppStream(f.stream, didSend: iq)

        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary), .sent(request: id, mode: .summary)])
    }

    func testLiveAdapterEmitsSafeRegistrationLineAtInfoLevel() {
        let capture = CapturingLogger()
        let previousLevel = dynamicLogLevel
        DDLog.flushLog()
        dynamicLogLevel = .info
        DDLog.add(capture, with: .info)
        defer {
            DDLog.flushLog()
            DDLog.remove(capture)
            dynamicLogLevel = previousLevel
        }
        let event = PushRegistrationDiagnosticEvent.sent(request: UUID(), mode: .summary)

        PushRegistrationDiagnosticLogger.live.record(event)
        DDLog.flushLog()

        let matching = capture.snapshot().filter { $0.message == event.diagnosticLine }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.flag, .info)
    }

    func testEmptySuccessfulResultEmitsEnabledOnceWithoutClaimingHTTPReadiness() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)

        XCTAssertTrue(f.manager.read(withIQ: try response(id: id, type: "result")))
        XCTAssertFalse(f.manager.read(withIQ: try response(id: id, type: "result")))

        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary), .sent(request: id, mode: .summary), .enabled(request: id, httpReady: false)])
        XCTAssertTrue(f.manager.enabled)
    }

    func testSuccessfulDurableHTTPGrantEmitsReadyEnabledDiagnostic() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)
        let form = "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE'><value>https://xabber.com/protocol/push</value></field><field var='url'><value>https://private-service-sentinel.invalid/iq</value></field><field var='jwt'><value>private-jwt-sentinel</value></field></x>"

        XCTAssertTrue(f.manager.read(withIQ: try response(id: id, type: "result", body: form)))

        XCTAssertEqual(f.events.values.last, .enabled(request: id, httpReady: true))
        XCTAssertTrue(f.manager.httpPreviewReady)
    }

    func testCorrelatedQualifiedRFCConditionsAreReportedExactly() throws {
        for raw in ["not-allowed", "bad-request", "item-not-found", "internal-server-error", "feature-not-implemented", "policy-violation"] {
            let f = fixture()
            f.manager.enable(xmppStream: f.stream) { _ in }
            let id = try requestID(f)
            let condition = try XCTUnwrap(PushRegistrationErrorCondition(rawValue: raw))

            let iq = try response(id: id, body: error("<\(raw) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"))
            XCTAssertTrue(f.manager.read(withIQ: iq))
            XCTAssertFalse(f.manager.read(withIQ: iq))

            XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary), .sent(request: id, mode: .summary), .rejected(request: id, condition: condition)])
            XCTAssertFalse(f.manager.enabled)
        }
    }

    func testForeignNamespaceConditionCannotClaimRFCNotAllowed() throws {
        for conditionXML in ["<not-allowed xmlns='urn:private-error-sentinel'/>", "<not-allowed/>"] {
            let f = fixture()
            f.manager.enable(xmppStream: f.stream) { _ in }
            let id = try requestID(f)

            XCTAssertTrue(f.manager.read(withIQ: try response(id: id, body: error(conditionXML))))

            guard let last = f.events.values.last,
                  case .rejected(let reportedID, let condition) = last else {
                return XCTFail("The correlated error must produce a classified rejection")
            }
            XCTAssertEqual(reportedID, id)
            XCTAssertNotEqual(condition.rawValue, "not-allowed")
            XCTAssertTrue(["unknown", "missing"].contains(condition.rawValue))
        }
    }

    func testErrorElementMustUseTheParentStanzaNamespace() throws {
        let condition = "<not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
        for (body, expected) in [
            (error(condition), PushRegistrationErrorCondition.notAllowed),
            ("<error xmlns=''>\(condition)</error>", .unknown),
            ("<error xmlns='urn:private-error-sentinel'>\(condition)</error>", .unknown)
        ] {
            let f = fixture()
            f.manager.enable(xmppStream: f.stream) { _ in }
            let id = try requestID(f)
            XCTAssertTrue(f.manager.read(withIQ: try response(id: id, body: body, stanzaNamespace: "jabber:client")))
            XCTAssertEqual(f.events.values.last, .rejected(request: id, condition: expected))
        }
    }

    func testDeferredCapabilityRejectionReportsItsTerminalBlockReasonOnce() throws {
        let f = fixture()
        f.manager.awaitCustomPushSupport()
        var callbacks: [Bool] = []
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        let id = try pendingRequestID(f)

        f.manager.setCustomPushSupport(false, xmppStream: f.stream)
        f.manager.setCustomPushSupport(false, xmppStream: f.stream)
        f.timeouts.actions[0]()

        XCTAssertEqual(f.events.values, [.waiting(request: id), .blocked(reason: .unsupportedServer)])
        XCTAssertEqual(callbacks, [false])
        XCTAssertTrue(f.stream.sent.isEmpty)
    }

    func testDuplicateConditionsAndDuplicateErrorElementsAreAmbiguous() throws {
        let condition = "<not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
        let oversized = error(condition + String(repeating: "<text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>private-error-text-sentinel</text>", count: 65))
        let foreignSibling = error(condition) + "<error xmlns='urn:private-error-sentinel'>\(condition)</error>"
        for body in [error(condition + condition), error(condition) + error(condition), oversized, foreignSibling] {
            let f = fixture()
            f.manager.enable(xmppStream: f.stream) { _ in }
            let id = try requestID(f)

            XCTAssertTrue(f.manager.read(withIQ: try response(id: id, body: body)))

            XCTAssertEqual(f.events.values.last, .rejected(request: id, condition: try XCTUnwrap(PushRegistrationErrorCondition(rawValue: "ambiguous"))))
        }
    }

    func testMissingAndUnknownConditionsUseClosedFallbackCategories() throws {
        let cases = [
            (error("<text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>private-error-text-sentinel</text>"), "missing"),
            (error("<private-condition-sentinel xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"), "unknown"),
            (error("<missing xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"), "unknown"),
            (error("<unknown xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"), "unknown"),
            (error("<ambiguous xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"), "unknown")
        ]
        for (body, expected) in cases {
            let f = fixture()
            f.manager.enable(xmppStream: f.stream) { _ in }
            let id = try requestID(f)

            XCTAssertTrue(f.manager.read(withIQ: try response(id: id, body: body)))

            XCTAssertEqual(f.events.values.last, .rejected(request: id, condition: try XCTUnwrap(PushRegistrationErrorCondition(rawValue: expected))))
        }
    }

    func testWrongIDForeignOwnerAndSupersededConfigurationCannotEmitResults() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)
        let before = f.events.values
        let body = error("<not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>")

        XCTAssertFalse(f.manager.read(withIQ: try response(id: UUID(), body: body)))
        XCTAssertFalse(f.manager.read(withIQ: try response(id: id, from: "other-owner@example.invalid", body: body)))
        XCTAssertEqual(f.events.values, before)
        f.manager.node = "replacement-private-node-sentinel-\(UUID())"
        XCTAssertFalse(f.manager.read(withIQ: try response(id: id, body: body)))
        XCTAssertEqual(f.events.values, before)
    }

    func testSentTimeoutIsReportedOnceAndLateIQCannotBecomeEnabled() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)

        f.timeouts.actions[0]()
        f.timeouts.actions[0]()
        XCTAssertFalse(f.manager.read(withIQ: try response(id: id, type: "result")))

        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary), .sent(request: id, mode: .summary), .timedOut(request: id, sent: true)])
    }

    func testQueuedWithoutDidSendTimesOutWithoutClaimingActualSend() throws {
        let f = fixture()
        f.stream.autoDidSend = false
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)

        f.timeouts.actions[0]()
        f.manager.didSend(XMPPIQ(from: try XCTUnwrap(f.stream.sent.first)), xmppStream: f.stream)

        XCTAssertEqual(f.events.values, [.queued(request: id, mode: .summary), .timedOut(request: id, sent: false)])
    }

    func testCapabilityTimeoutReportsUnsentRequestOnce() throws {
        let f = fixture()
        f.manager.awaitCustomPushSupport()
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try pendingRequestID(f)

        f.timeouts.actions[0]()
        f.timeouts.actions[0]()

        XCTAssertTrue(f.stream.sent.isEmpty)
        XCTAssertEqual(f.events.values, [.waiting(request: id), .timedOut(request: id, sent: false)])
    }

    func testKeychainFailureEmitsCredentialsBlockWithoutSending() {
        let f = fixture()
        f.manager.credentialReader = { _ in throw CredentialsManager.CredentialsError.pushStorageFailure }

        f.manager.enable(xmppStream: f.stream) { _ in }

        XCTAssertTrue(f.stream.sent.isEmpty)
        XCTAssertEqual(f.events.values, [.blocked(reason: .credentialsUnavailable)])
    }

    func testPreflightGatesEmitOnlyClosedBlockReasons() {
        let missing = fixture()
        missing.manager.node = ""
        missing.manager.enable(xmppStream: missing.stream) { _ in }
        XCTAssertEqual(missing.events.values, [.blocked(reason: .missingConfiguration)])
        XCTAssertTrue(missing.stream.sent.isEmpty)
        let invalid = fixture()
        invalid.stream.myJID = XMPPJID(string: "foreign-owner@example.invalid/ios")
        invalid.manager.enable(xmppStream: invalid.stream) { _ in }
        XCTAssertEqual(invalid.events.values, [.blocked(reason: .invalidAccount)])
        XCTAssertTrue(invalid.stream.sent.isEmpty)
        let unsupported = fixture()
        unsupported.manager.setCustomPushSupport(false, xmppStream: unsupported.stream)
        unsupported.manager.enable(xmppStream: unsupported.stream) { _ in }
        XCTAssertEqual(unsupported.events.values, [.blocked(reason: .unsupportedServer)])
        XCTAssertTrue(unsupported.stream.sent.isEmpty)
    }

    func testDiagnosticLinesCannotContainPrivateInputsOrServerErrorText() throws {
        let f = fixture()
        let saved = f.memory.record
        f.memory.record = CredentialsManager.PushSecretData(
            host: saved.host, secret: saved.secret, jid: saved.jid,
            service: saved.service, jwt: "private-jwt-sentinel"
        )
        f.manager.enable(xmppStream: f.stream) { _ in }
        let id = try requestID(f)
        let body = error("<not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/><text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>private-error-text-sentinel</text>")
        XCTAssertTrue(f.manager.read(withIQ: try response(id: id, body: body)))
        XCTAssertFalse(f.events.values.isEmpty)
        let allEvents = f.events.values + [
            .waiting(request: id), .enabled(request: id, httpReady: true),
            .timedOut(request: id, sent: true), .blocked(reason: .credentialsUnavailable)
        ]
        let sentinels = [owner, f.node, f.manager.service, f.memory.record.secret,
                         Data(f.memory.record.keyBytes!).base64EncodedString(),
                         "private-jwt-sentinel", "private-error-text-sentinel", "private-service-sentinel.invalid"]

        for event in allEvents {
            let line = event.diagnosticLine
            XCTAssertTrue(line.hasPrefix("PUSH_REGISTRATION "))
            XCTAssertLessThan(line.utf8.count, 384)
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("<"))
            for sentinel in sentinels { XCTAssertFalse(line.contains(sentinel)) }
        }
    }

    private func fixture(mode: PushPayloadMode = .summary) -> Fixture {
        let manager = PushNotificationsManager(withOwner: owner)
        let node = "private-node-sentinel-\(UUID())"
        manager.node = node
        manager.service = "private-push-service-sentinel.invalid"
        manager.payloadModeProvider = { mode }
        let stream = Stream()
        stream.myJID = XMPPJID(string: owner, resource: "ios")
        stream.onSend = { [weak manager, weak stream] element in
            guard let manager, let stream else { return }
            manager.didSend(XMPPIQ(from: element), xmppStream: stream)
        }
        let memory = Memory(CredentialsManager.PushSecretData(
            host: "example.invalid", secret: "private-key-sentinel-".padding(toLength: 32, withPad: "x", startingAt: 0),
            jid: owner, service: "https://private-service-sentinel.invalid/iq", jwt: ""
        ))
        manager.credentialReader = { _ in memory.record }
        manager.credentialWriter = { _, record in memory.record = record }
        let timeouts = Timeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        let events = Events()
        manager.diagnostics = PushRegistrationDiagnosticLogger(sink: { events.values.append($0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager.tokenInvalidationStore = PushTokenInvalidationStore(directory: directory)
        let fixture = Fixture(manager: manager, stream: stream, events: events, memory: memory,
                              timeouts: timeouts, node: node, directory: directory)
        fixtures.append(fixture)
        return fixture
    }

    private func requestID(_ fixture: Fixture) throws -> UUID {
        let raw = try XCTUnwrap(fixture.stream.sent.last?.attributeStringValue(forName: "id"))
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    private func pendingRequestID(_ fixture: Fixture) throws -> UUID {
        guard case .pending(let raw) = fixture.manager.enableState else {
            XCTFail("Expected a pending registration")
            throw NSError(domain: "PushEnableDiagnosticsTests", code: 1)
        }
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    private func error(_ contents: String) -> String { "<error type='cancel'>\(contents)</error>" }

    private func response(id: UUID, type: String = "error", from: String? = nil, body: String = "", stanzaNamespace: String? = nil) throws -> XMPPIQ {
        let namespaceAttribute = stanzaNamespace.map { " xmlns='\($0)'" } ?? ""
        let document = try DDXMLDocument(
            xmlString: "<iq\(namespaceAttribute) type='\(type)' id='\(id.uuidString)' from='\(from ?? owner)' to='\(owner)/ios'>\(body)</iq>",
            options: 0
        )
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}
