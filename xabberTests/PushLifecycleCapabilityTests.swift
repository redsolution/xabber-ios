import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

final class PushLifecycleCapabilityTests: XCTestCase {
    private var originalRealm: Realm.Configuration!
    private var realmKeeper: Realm?
    private var accounts: [Account] = []

    private final class Stream: XMPPStream {
        var authenticated = true
        private(set) var sent: [DDXMLElement] = []
        override var isAuthenticated: Bool { authenticated }
        override func send(_ element: DDXMLElement) { sent.append(element.copy() as! DDXMLElement) }
        var enables: [DDXMLElement] {
            sent.filter { $0.element(forName: "enable")?.xmlns() == "https://xabber.com/protocol/push" }
        }
        func discoID(to target: String) -> String? {
            sent.last { $0.attributeStringValue(forName: "to") == target && $0.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info" }?
                .attributeStringValue(forName: "id")
        }
    }

    private final class Memory {
        var record: CredentialsManager.PushSecretData!
    }

    private struct Fixture {
        let account: Account
        let stream: Stream
        let memory: Memory
    }

    override func setUp() {
        super.setUp()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "PushLifecycle-\(UUID())")
        realmKeeper = try? WRealm.safe()
    }

    override func tearDown() {
        for account in accounts {
            account.disco.clearSession()
            account.push.clearSession()
            AccountManager.shared.users.removeAll { $0 === account }
            PushNotificationsManager.removeDefaultsForPush(target: account.push.node, jid: account.jid)
        }
        accounts.removeAll()
        realmKeeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testTrackedOwnerDiscoUnblocksPendingPushBeforeRootResponse() throws {
        let f = fixture()
        f.account.push.awaitCustomPushSupport()
        f.account.configureExtensions()
        f.account.disco.configure(f.stream)
        XCTAssertTrue(f.stream.enables.isEmpty)

        XCTAssertTrue(f.account.disco.read(withIQ: try disco(f, from: f.account.jid, features: ["https://xabber.com/protocol/push"])))

        XCTAssertEqual(f.stream.enables.count, 1)
        XCTAssertEqual(f.stream.enables.first?.element(forName: "enable")?
            .element(forName: "encryption", xmlns: "https://xabber.com/protocol/push")?
            .element(forName: "key", xmlns: "https://xabber.com/protocol/push")?.stringValue,
                       Data(f.memory.record.keyBytes!).base64EncodedString())
    }

    func testRootDiscoCannotSubstituteForOwnerPushSupport() throws {
        let f = fixture()
        f.account.push.awaitCustomPushSupport()
        f.account.configureExtensions()
        f.account.disco.configure(f.stream)

        XCTAssertTrue(f.account.disco.read(withIQ: try disco(f, from: "example.invalid", features: ["https://xabber.com/protocol/push"])))

        XCTAssertTrue(f.stream.enables.isEmpty)
        XCTAssertFalse(f.account.push.isAvailable("example.invalid"))
    }

    func testStandardOnlyOwnerResultRejectsCustomRegistrationWithoutLosingKey() throws {
        let f = fixture()
        f.account.push.awaitCustomPushSupport()
        var callbacks: [Bool] = []
        f.account.push.enable(xmppStream: f.stream) { callbacks.append($0) }
        f.account.disco.configure(f.stream)
        let originalKey = f.memory.record.keyBytes

        XCTAssertTrue(f.account.disco.read(withIQ: try disco(f, from: f.account.jid, features: ["urn:xmpp:push:0"])))

        XCTAssertEqual(callbacks, [false])
        XCTAssertTrue(f.stream.enables.isEmpty)
        XCTAssertEqual(f.memory.record.keyBytes, originalKey)
    }

    func testWrongSenderCannotConsumeTrackedOwnerCapabilityQuery() throws {
        let f = fixture()
        f.account.push.awaitCustomPushSupport()
        f.account.configureExtensions()
        f.account.disco.configure(f.stream)
        let id = try XCTUnwrap(f.stream.discoID(to: f.account.jid))

        XCTAssertFalse(f.account.disco.read(withIQ: try iq("<iq type='result' id='\(id)' from='attacker@example.invalid'><query xmlns='http://jabber.org/protocol/disco#info'><feature var='https://xabber.com/protocol/push'/></query></iq>")))
        XCTAssertTrue(f.stream.enables.isEmpty)
        XCTAssertTrue(f.account.disco.read(withIQ: try disco(f, from: f.account.jid, features: ["https://xabber.com/protocol/push"])))
        XCTAssertEqual(f.stream.enables.count, 1)
    }

    func testModuleResetCancelsPendingRegistrationAndRejectsLateCapabilityResult() throws {
        let f = fixture()
        f.account.push.awaitCustomPushSupport()
        var callbacks: [Bool] = []
        f.account.push.enable(xmppStream: f.stream) { callbacks.append($0) }
        f.account.disco.configure(f.stream)
        let id = try XCTUnwrap(f.stream.discoID(to: f.account.jid))

        f.account.resetModules()

        XCTAssertEqual(callbacks, [false])
        XCTAssertEqual(f.account.push.enableState, .disabled)
        XCTAssertFalse(f.account.disco.read(withIQ: try iq("<iq type='result' id='\(id)' from='\(f.account.jid)'><query xmlns='http://jabber.org/protocol/disco#info'><feature var='https://xabber.com/protocol/push'/></query></iq>")))
        XCTAssertTrue(f.stream.enables.isEmpty)
    }

    func testForegroundRefreshesMissingHTTPGrantWithoutDisablingAcknowledgedPush() throws {
        let f = fixture()
        f.account.configureExtensions()
        let firstID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='result' id='\(firstID)' from='\(f.account.jid)'/>")))
        XCTAssertTrue(f.account.pushStatusMessage.value)
        XCTAssertFalse(f.account.push.httpPreviewReady)
        try rejectPendingHTTPDiscovery(f)
        let originalKey = f.memory.record.keyBytes

        ApplicationStateManager().sceneDidBecomeActive()
        f.account.queue.sync {}

        XCTAssertEqual(f.stream.enables.count, 2)
        let refreshID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        XCTAssertNotEqual(refreshID, firstID)
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='error' id='\(refreshID)' from='\(f.account.jid)'><error type='wait'><internal-server-error xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")))
        XCTAssertTrue(f.account.push.enabled)
        XCTAssertTrue(f.account.pushStatusMessage.value)
        XCTAssertEqual(f.memory.record.keyBytes, originalKey)
    }

    func testForegroundRestoresDisabledRegistrationWithSavedReadyHTTPGrant() throws {
        let f = fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        f.account.push.tokenInvalidationStore = PushTokenInvalidationStore(directory: directory)
        let saved = f.memory.record!
        f.memory.record = CredentialsManager.PushSecretData(
            host: saved.host, secret: saved.secret, jid: saved.jid,
            service: saved.service, jwt: "fixture-opaque-jwt", keyEncoding: saved.keyEncoding,
            httpArchive: PushHTTPArchiveGrant(endpoint: "https://example.invalid/iq/archive/id",
                token: "header.payload.signature", scopes: ["urn:xmpp:mam:2"],
                expiresAt: Date().addingTimeInterval(3600), discoveryDomain: "example.invalid")
        )
        let originalKey = f.memory.record.keyBytes
        f.account.push.awaitCustomPushSupport()
        XCTAssertTrue(f.account.push.httpPreviewReady)
        XCTAssertFalse(f.account.push.enabled)

        ApplicationStateManager().sceneDidBecomeActive()
        f.account.queue.sync {}

        _ = try XCTUnwrap(f.stream.discoID(to: f.account.jid), "Disabled registration must retry owner discovery even with a usable HTTP grant")
        XCTAssertTrue(f.stream.enables.isEmpty)
        XCTAssertTrue(f.account.disco.read(withIQ: try disco(f, from: f.account.jid, features: ["https://xabber.com/protocol/push"])))
        XCTAssertEqual(f.stream.enables.count, 1)
        XCTAssertEqual(f.memory.record.keyBytes, originalKey)
        XCTAssertTrue(f.account.push.httpPreviewReady)
        let enableID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='result' id='\(enableID)' from='\(f.account.jid)'/>")))
        XCTAssertTrue(f.account.push.enabled)
        XCTAssertTrue(f.account.pushStatusMessage.value)
    }

    func testForegroundDoesNotSendRefreshOnUnauthenticatedStream() {
        let f = fixture()
        f.stream.authenticated = false

        ApplicationStateManager().sceneDidBecomeActive()
        f.account.queue.sync {}

        XCTAssertTrue(f.stream.enables.isEmpty)
    }

    func testForegroundDoesNotSendAfterSASLWhileBindingIsIncomplete() {
        let f = fixture()
        f.account.connectionGate.markDisconnected()
        f.account.connectionGate.adoptFrameworkActivePhase(.authenticating)
        f.account.connectionGate.markBinding()
        XCTAssertEqual(f.account.connectionGate.snapshot().phase, .binding)

        ApplicationStateManager().sceneDidBecomeActive()
        f.account.queue.sync {}

        XCTAssertTrue(f.stream.enables.isEmpty)
    }

    func testResumeRestoresRegistrationAndRefreshesUsingTheSameKey() throws {
        let f = fixture()
        f.account.configureExtensions()
        let firstID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='result' id='\(firstID)' from='\(f.account.jid)'/>")))
        let originalKey = f.memory.record.keyBytes
        f.account.push.clearSession()

        f.account.restorePushRegistrationAfterResume()

        XCTAssertEqual(f.stream.enables.count, 2)
        XCTAssertEqual(f.memory.record.keyBytes, originalKey)
        let resumedID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        XCTAssertNotEqual(resumedID, firstID)
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='result' id='\(resumedID)' from='\(f.account.jid)'/>")))
        XCTAssertTrue(f.account.push.enabled)
        XCTAssertTrue(f.account.pushStatusMessage.value)
    }

    func testRepeatedForegroundActivationsPreservePendingRegistrationSingleFlight() throws {
        let f = fixture()
        f.account.push.awaitCustomPushSupport()
        f.account.configureExtensions()
        f.account.disco.configure(f.stream)
        let pending = f.account.push.enableState

        ApplicationStateManager().sceneDidBecomeActive()
        ApplicationStateManager().sceneDidBecomeActive()
        f.account.queue.sync {}

        XCTAssertEqual(f.account.push.enableState, pending)
        XCTAssertTrue(f.stream.enables.isEmpty)
        XCTAssertTrue(f.account.disco.read(withIQ: try disco(f, from: f.account.jid, features: ["https://xabber.com/protocol/push"])))
        XCTAssertEqual(f.stream.enables.count, 1)
    }

    func testSameConfigurationJoiningFailedGrantRefreshKeepsPushStatusEnabled() throws {
        let f = fixture()
        f.account.configureExtensions()
        let initialID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='result' id='\(initialID)' from='\(f.account.jid)'/>")))
        try rejectPendingHTTPDiscovery(f)
        f.account.refreshPushHTTPGrantIfNeeded()
        let refreshID = try XCTUnwrap(f.stream.enables.last?.attributeStringValue(forName: "id"))
        f.account.push.configure(node: f.account.push.node, service: f.account.push.service)
        f.account.queue.sync {}
        XCTAssertTrue(f.account.push.read(withIQ: try iq("<iq type='error' id='\(refreshID)' from='\(f.account.jid)'/>")))
        XCTAssertTrue(f.account.push.enabled)
        XCTAssertTrue(f.account.pushStatusMessage.value)
    }

    private func rejectPendingHTTPDiscovery(_ fixture: Fixture) throws {
        let request = try XCTUnwrap(fixture.stream.sent.last(where: {
            $0.element(forName: "endpoints", xmlns: "https://xabber.com/protocol/http-iq") != nil
        }))
        let id = try XCTUnwrap(request.attributeStringValue(forName: "id"))
        let domain = try XCTUnwrap(fixture.stream.myJID?.domain)
        let recipient = try XCTUnwrap(fixture.stream.myJID?.full)
        XCTAssertEqual(request.attributeStringValue(forName: "to"), domain)
        XCTAssertFalse(fixture.account.push.needsHTTPArchive, "An active HTTP IQ chain must suppress foreground retries")

        XCTAssertTrue(fixture.account.push.read(withIQ: try iq("""
        <iq type='error' id='\(id)' from='\(domain)' to='\(recipient)'>
          <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>
        </iq>
        """)))

        XCTAssertTrue(fixture.account.push.needsHTTPArchive, "The completed failure must permit a later foreground retry")
        XCTAssertTrue(fixture.account.push.enabled)
    }

    private func fixture() -> Fixture {
        let owner = "push-lifecycle-\(UUID().uuidString.lowercased())@example.invalid"
        let account = Account(jid: owner, queue: DispatchQueue(label: "PushLifecycle.\(UUID())"))
        let stream = Stream()
        stream.myJID = XMPPJID(string: owner, resource: "ios")
        account.xmppStream = stream
        account.connectionGate.adoptFrameworkActivePhase(.authenticating)
        account.connectionGate.markOnline()
        XCTAssertEqual(account.connectionGate.snapshot().phase, .online)
        account.isRegularPushRequestSended = true
        account.isVoIPPushRequestSended = true
        let memory = Memory()
        memory.record = CredentialsManager.PushSecretData(host: "example.invalid", secret: String(repeating: "k", count: 32), jid: owner, service: "https://example.invalid/iq", jwt: "")
        account.push.node = "lifecycle-node-\(UUID())"
        account.push.service = "push.example.invalid"
        account.push.tokenInvalidationStore = nil
        account.push.registrationTimeoutScheduler = { _, _ in {} }
        account.push.credentialReader = { _ in memory.record }
        account.push.credentialWriter = { _, record in memory.record = record }
        AccountManager.shared.users.append(account)
        accounts.append(account)
        return Fixture(account: account, stream: stream, memory: memory)
    }

    private func disco(_ fixture: Fixture, from: String, features: [String]) throws -> XMPPIQ {
        let id = try XCTUnwrap(fixture.stream.discoID(to: from))
        let payload = features.map { "<feature var='\($0)'/>" }.joined()
        return try iq("<iq type='result' id='\(id)' from='\(from)'><query xmlns='http://jabber.org/protocol/disco#info'>\(payload)</query></iq>")
    }

    private func iq(_ xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}
