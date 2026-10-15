import Foundation
import XCTest
import XMPPFramework
@testable import xabber

final class PushPayloadModeRegistrationTests: XCTestCase {
    private let preferenceKey = "notification_push_payload_mode"
    private let owner = "push-mode@example.invalid"
    private var savedPreference: Any?
    private var preferences: UserDefaults { UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup())! }
    private var fixtures: [Fixture] = []

    private final class Stream: XMPPStream {
        private(set) var sent: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { sent.append(element.copy() as! DDXMLElement) }
        var enables: [DDXMLElement] {
            sent.filter { $0.element(forName: "enable")?.xmlns() == "https://xabber.com/protocol/push" }
        }
    }

    private final class Memory {
        var record: CredentialsManager.PushSecretData
        var writes = 0
        init(record: CredentialsManager.PushSecretData) { self.record = record }
    }

    private final class Timeouts {
        private(set) var actions: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
            actions.append(action)
            return {}
        }
    }

    private struct Fixture {
        let manager: PushNotificationsManager
        let stream: Stream
        let memory: Memory
        let timeouts: Timeouts
        let directory: URL
    }

    override func setUp() {
        super.setUp()
        savedPreference = preferences.object(forKey: preferenceKey)
        preferences.removeObject(forKey: preferenceKey)
    }

    override func tearDown() {
        for fixture in fixtures {
            fixture.manager.clearSession()
            PushNotificationsManager.removeDefaultsForPush(target: fixture.manager.node, jid: owner)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        if let savedPreference { preferences.set(savedPreference, forKey: preferenceKey) }
        else { preferences.removeObject(forKey: preferenceKey) }
        savedPreference = nil
        super.tearDown()
    }

    func testMissingPreferenceSendsExplicitSummaryWithXEPEncryption() throws {
        let f = fixture()

        f.manager.enable(xmppStream: f.stream) { _ in }

        let enable = try enableElement(f, index: 0)
        let encryption = try XCTUnwrap(enable.element(forName: "encryption", xmlns: "https://xabber.com/protocol/push"))
        XCTAssertEqual(enable.attributeStringValue(forName: "mode"), "summary")
        XCTAssertEqual(encryption.attributeStringValue(forName: "algorithm"), "urn:xmpp:ciphers:aes-256-cbc")
        XCTAssertEqual(encryption.element(forName: "key", xmlns: "https://xabber.com/protocol/push")?.stringValue,
                       Data(f.memory.record.keyBytes!).base64EncodedString())
        XCTAssertNil(enable.element(forName: "security"))
    }

    func testFullPreferenceSendsExactFullWireValue() throws {
        preferences.set("full", forKey: preferenceKey)
        let f = fixture()

        f.manager.enable(xmppStream: f.stream) { _ in }

        let enable = try enableElement(f, index: 0)
        XCTAssertEqual(enable.attributeStringValue(forName: "mode"), "full")
        XCTAssertEqual(enable.element(forName: "encryption", xmlns: "https://xabber.com/protocol/push")?
            .attributeStringValue(forName: "algorithm"), "urn:xmpp:ciphers:aes-256-cbc")
        XCTAssertEqual(enable.element(forName: "encryption", xmlns: "https://xabber.com/protocol/push")?
            .element(forName: "key", xmlns: "https://xabber.com/protocol/push")?.stringValue,
                       Data(f.memory.record.keyBytes!).base64EncodedString())
        XCTAssertNil(enable.element(forName: "security"))
    }

    func testUnknownSavedPreferenceFallsBackToSummary() throws {
        preferences.set("partial", forKey: preferenceKey)
        let f = fixture()

        f.manager.enable(xmppStream: f.stream) { _ in }

        XCTAssertEqual(try enableElement(f, index: 0).attributeStringValue(forName: "mode"), "summary")
    }

    func testUnsentRequestUsesLatestPreferenceWhenOwnerCapabilityArrives() throws {
        let f = fixture()
        f.manager.awaitCustomPushSupport()
        f.manager.enable(xmppStream: f.stream) { _ in }
        preferences.set("full", forKey: preferenceKey)
        XCTAssertTrue(f.stream.enables.isEmpty)

        f.manager.setCustomPushSupport(true, xmppStream: f.stream)

        XCTAssertEqual(f.stream.enables.count, 1)
        XCTAssertEqual(try enableElement(f, index: 0).attributeStringValue(forName: "mode"), "full")
    }

    func testSentSummaryAcknowledgementStartsLatestFullModeWithoutAcceptingInlineGrant() throws {
        let f = fixture()
        var callbacks: [Bool] = []
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        let originalKey = f.memory.record.keyBytes
        let originalGrant = f.memory.record.httpArchive
        preferences.set("full", forKey: preferenceKey)
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        XCTAssertEqual(f.stream.enables.count, 1)

        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0, jwt: "first-rotated-grant")))

        XCTAssertEqual(f.memory.record.jwt, "saved-opaque-grant")
        XCTAssertEqual(f.memory.record.httpArchive, originalGrant)
        XCTAssertEqual(f.stream.enables.count, 2)
        XCTAssertEqual(try enableElement(f, index: 1).attributeStringValue(forName: "mode"), "full")
        for index in [0, 1] {
            let encodedKey = try XCTUnwrap(try enableElement(f, index: index)
                .element(forName: "encryption", xmlns: "https://xabber.com/protocol/push")?
                .element(forName: "key", xmlns: "https://xabber.com/protocol/push")?.stringValue)
            XCTAssertEqual(Data(base64Encoded: encodedKey), originalKey.map { Data($0) })
        }
        XCTAssertEqual(f.memory.record.keyBytes, originalKey)
        XCTAssertFalse(f.manager.read(withIQ: try response(f, index: 0, jwt: "duplicate-old-grant")))
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 1, jwt: "latest-grant")))
        XCTAssertEqual(f.memory.record.jwt, "saved-opaque-grant")
        XCTAssertEqual(f.memory.record.httpArchive, originalGrant)
        XCTAssertEqual(callbacks, [true, true])
        XCTAssertTrue(f.manager.enabled)
        XCTAssertTrue(f.manager.isPayloadModeCurrent)
    }

    func testSeveralChangesWhileSentCoalesceToOneLatestModeRequest() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        for mode in ["full", "summary", "full"] {
            preferences.set(mode, forKey: preferenceKey)
            f.manager.enable(xmppStream: f.stream) { _ in }
        }
        XCTAssertEqual(f.stream.enables.count, 1)

        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0)))

        XCTAssertEqual(f.stream.enables.count, 2)
        XCTAssertEqual(try enableElement(f, index: 1).attributeStringValue(forName: "mode"), "full")
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 1)))
        XCTAssertEqual(f.stream.enables.count, 2)
    }

    func testUnchangedAcknowledgedModeDoesNotSendAgainOrRewriteCredentials() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0)))
        let writes = f.memory.writes

        f.manager.enable(xmppStream: f.stream) { XCTAssertTrue($0) }

        XCTAssertEqual(f.stream.enables.count, 1)
        XCTAssertEqual(f.memory.writes, writes)
    }

    func testFailedModeChangePreservesAcknowledgedRegistrationAndGrantUntilExplicitRetry() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0)))
        let savedRecord = f.memory.record
        XCTAssertTrue(f.manager.isPayloadModeCurrent)
        preferences.set("full", forKey: preferenceKey)
        XCTAssertFalse(f.manager.isPayloadModeCurrent)
        var callbacks: [Bool] = []
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }

        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 1, type: "error")))

        XCTAssertEqual(callbacks, [false])
        XCTAssertTrue(f.manager.enabled)
        XCTAssertFalse(f.manager.isPayloadModeCurrent)
        XCTAssertTrue(f.manager.httpPreviewReady)
        XCTAssertEqual(f.memory.record.keyBytes, savedRecord.keyBytes)
        XCTAssertEqual(f.memory.record.tokenGeneration, savedRecord.tokenGeneration)
        XCTAssertEqual(f.stream.enables.count, 2, "A failed mode attempt must not loop automatically")
        f.manager.enable(xmppStream: f.stream) { _ in }
        XCTAssertEqual(f.stream.enables.count, 3)
        XCTAssertEqual(try enableElement(f, index: 2).attributeStringValue(forName: "mode"), "full")
    }

    func testModeTimeoutCompletesOnceAndWaitsForExplicitRetry() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0)))
        preferences.set("full", forKey: preferenceKey)
        var callbacks: [Bool] = []
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        let timeout = try XCTUnwrap(f.timeouts.actions.last)

        timeout()
        timeout()

        XCTAssertEqual(callbacks, [false])
        XCTAssertTrue(f.manager.enabled)
        XCTAssertFalse(f.manager.isPayloadModeCurrent)
        XCTAssertTrue(f.manager.httpPreviewReady)
        XCTAssertEqual(f.stream.enables.count, 2)
        XCTAssertFalse(f.manager.read(withIQ: try response(f, index: 1, jwt: "late-grant")))
        f.manager.enable(xmppStream: f.stream) { _ in }
        XCTAssertEqual(f.stream.enables.count, 3)
    }

    func testSupersededModeTimeoutStartsOnlyOneLatestRequestAndCarriesCallbacks() throws {
        let f = fixture()
        var callbacks: [Bool] = []
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        preferences.set("full", forKey: preferenceKey)
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }

        f.timeouts.actions[0]()
        f.timeouts.actions[0]()

        XCTAssertEqual(f.stream.enables.count, 2)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(try enableElement(f, index: 1).attributeStringValue(forName: "mode"), "full")
        XCTAssertFalse(f.manager.read(withIQ: try response(f, index: 0, jwt: "late-superseded-grant")))
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 1, jwt: "latest-grant")))
        XCTAssertEqual(callbacks, [true, true])
        XCTAssertTrue(f.manager.isPayloadModeCurrent)
    }

    func testReturningToInflightModeAvoidsRedundantSuccessor() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        for mode in ["full", "summary"] {
            preferences.set(mode, forKey: preferenceKey)
            f.manager.enable(xmppStream: f.stream) { _ in }
        }

        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0)))

        XCTAssertEqual(f.stream.enables.count, 1)
        XCTAssertTrue(f.manager.isPayloadModeCurrent)
    }

    func testReturningToPreviouslyAcknowledgedModeAfterSentTimeoutStillReRegistersLatestMode() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { _ in }
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 0)))
        let savedRecord = f.memory.record
        var callbacks: [Bool] = []
        preferences.set("full", forKey: preferenceKey)
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        preferences.set("summary", forKey: preferenceKey)
        f.manager.enable(xmppStream: f.stream) { callbacks.append($0) }
        XCTAssertEqual(f.stream.enables.count, 2)

        let timeout = try XCTUnwrap(f.timeouts.actions.last)
        timeout()

        XCTAssertTrue(f.manager.enabled)
        XCTAssertTrue(f.manager.httpPreviewReady)
        XCTAssertEqual(f.memory.record.keyBytes, savedRecord.keyBytes)
        XCTAssertEqual(f.memory.record.tokenGeneration, savedRecord.tokenGeneration)
        XCTAssertFalse(f.manager.isPayloadModeCurrent, "A sent timeout cannot prove the server retained its older acknowledged mode")
        XCTAssertEqual(f.stream.enables.count, 3)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(try enableElement(f, index: 2).attributeStringValue(forName: "mode"), "summary")
        timeout()
        XCTAssertEqual(f.stream.enables.count, 3)
        XCTAssertTrue(f.manager.read(withIQ: try response(f, index: 2)))
        XCTAssertEqual(callbacks, [true, true])
        XCTAssertTrue(f.manager.isPayloadModeCurrent)
    }

    private func fixture() -> Fixture {
        let manager = PushNotificationsManager(withOwner: owner)
        manager.node = "mode-node-\(UUID())"
        manager.service = "push.example.invalid"
        let stream = Stream()
        stream.myJID = XMPPJID(string: owner, resource: "ios")
        let memory = Memory(record: CredentialsManager.PushSecretData(
            host: "example.invalid", secret: String(repeating: "k", count: 32), jid: owner,
            service: "https://example.invalid/iq", jwt: "saved-opaque-grant",
            httpArchive: PushHTTPArchiveGrant(endpoint: "https://example.invalid/custom/archive/id",
                token: "header.payload.signature", scopes: ["urn:xmpp:mam:2"],
                expiresAt: Date().addingTimeInterval(3600), discoveryDomain: "example.invalid")
        ))
        manager.credentialReader = { _ in memory.record }
        manager.credentialWriter = { _, record in memory.record = record; memory.writes += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager.tokenInvalidationStore = PushTokenInvalidationStore(directory: directory)
        let timeouts = Timeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        let fixture = Fixture(manager: manager, stream: stream, memory: memory, timeouts: timeouts, directory: directory)
        fixtures.append(fixture)
        return fixture
    }

    private func enableElement(_ fixture: Fixture, index: Int) throws -> DDXMLElement {
        guard fixture.stream.enables.indices.contains(index) else {
            XCTFail("Expected push enable at index \(index), got \(fixture.stream.enables.count)")
            throw NSError(domain: "PushPayloadModeRegistrationTests", code: 1)
        }
        return try XCTUnwrap(fixture.stream.enables[index].element(forName: "enable"))
    }

    private func response(_ fixture: Fixture, index: Int, type: String = "result", jwt: String? = nil) throws -> XMPPIQ {
        _ = try enableElement(fixture, index: index)
        let id = try XCTUnwrap(fixture.stream.enables[index].attributeStringValue(forName: "id"))
        let body = jwt.map { token in
            "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE'><value>https://xabber.com/protocol/push</value></field><field var='url'><value>https://example.invalid/iq</value></field><field var='jwt'><value>\(token)</value></field></x>"
        } ?? ""
        let document = try DDXMLDocument(xmlString: "<iq type='\(type)' id='\(id)' from='\(owner)' to='\(owner)/ios'>\(body)</iq>", options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}
