import Foundation
import XCTest
import XMPPFramework
@testable import xabber

final class PushHTTPIQProvisioningTests: XCTestCase {
    private let owner = "http-iq-push@example.invalid"
    private let domain = "example.invalid"
    private let httpNamespace = "https://xabber.com/protocol/http-iq"
    private let mamNamespace = "urn:xmpp:mam:2"
    private let endpoint = "https://archive.example.invalid/custom/by-id?deployment=ios"
    private var fixtures: [Fixture] = []

    private final class Stream: XMPPStream {
        private(set) var sent: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { sent.append(element.copy() as! DDXMLElement) }

        func requests(_ child: String, namespace: String) -> [DDXMLElement] {
            sent.filter { $0.element(forName: child, xmlns: namespace) != nil }
        }
    }

    private final class Timeout {
        let fire: () -> Void
        var cancelled = false
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }

    private final class Fixture {
        let manager: PushNotificationsManager
        let stream: Stream
        let directory: URL
        var record: CredentialsManager.PushSecretData
        var writes = 0
        var failWrites = false
        var mode = PushPayloadMode.summary
        var callbacks: [Bool] = []
        var timeouts: [Timeout] = []

        init(owner: String) {
            manager = PushNotificationsManager(withOwner: owner)
            stream = Stream()
            stream.myJID = XMPPJID(string: owner, resource: "ios-http-iq")
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            record = CredentialsManager.PushSecretData(
                host: "example.invalid", secret: String(repeating: "k", count: 32), jid: owner,
                service: "https://legacy.example.invalid/iq", jwt: "legacy-push-grant"
            )
            manager.node = "http-iq-node-\(UUID())"
            manager.service = "push.example.invalid"
            manager.tokenInvalidationStore = PushTokenInvalidationStore(directory: directory)
            manager.payloadModeProvider = { [weak self] in self?.mode ?? .summary }
            manager.credentialReader = { [weak self] _ in
                guard let self else { throw CredentialsManager.CredentialsError.itemNotFound }
                return self.record
            }
            manager.credentialWriter = { [weak self] _, record in
                guard let self, !self.failWrites else {
                    throw CredentialsManager.CredentialsError.pushStorageFailure
                }
                self.writes += 1
                self.record = record
            }
            manager.registrationTimeoutScheduler = { [weak self] _, fire in
                let timeout = Timeout(fire)
                self?.timeouts.append(timeout)
                return { timeout.cancelled = true }
            }
        }
    }

    override func tearDown() {
        for f in fixtures {
            f.manager.clearSession()
            PushNotificationsManager.removeDefaultsForPush(target: f.manager.node, jid: owner)
            try? FileManager.default.removeItem(at: f.directory)
        }
        fixtures.removeAll()
        super.tearDown()
    }

    func testSummaryEnableAcknowledgementStartsUnaddressedDiscoveryBeforeAnyTokenOrHTTPReadiness() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { f.callbacks.append($0) }
        XCTAssertTrue(requests(f, "endpoints").isEmpty)
        XCTAssertTrue(requests(f, "token").isEmpty)
        XCTAssertFalse(f.manager.httpPreviewReady, "A legacy push URL/JWT is not an HTTP IQ grant")

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f), body: "")))

        XCTAssertEqual(f.callbacks, [true], "Push enable completes independently of HTTP provisioning")
        XCTAssertTrue(f.manager.enabled)
        XCTAssertFalse(f.manager.httpPreviewReady)
        let discovery = try request(f, "endpoints")
        XCTAssertEqual(discovery.attributeStringValue(forName: "type"), "get")
        XCTAssertNil(discovery.attributeStringValue(forName: "from"))
        XCTAssertNil(discovery.attributeStringValue(forName: "to"))
        XCTAssertEqual(discovery.element(forName: "endpoints", xmlns: httpNamespace)?.childCount, 0)
        XCTAssertTrue(requests(f, "token").isEmpty)
    }

    func testDiscoveryIssuesUnaddressedMAMTokenRequestAndPublishesGrantAtomicallyForExtension() throws {
        let f = fixture()
        let originalKey = f.record.keyBytes
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        XCTAssertEqual(f.writes, 0, "An endpoint alone must not publish a usable partial grant")
        let tokenRequest = try request(f, "token")
        XCTAssertEqual(tokenRequest.attributeStringValue(forName: "type"), "get")
        XCTAssertNil(tokenRequest.attributeStringValue(forName: "from"))
        XCTAssertNil(tokenRequest.attributeStringValue(forName: "to"))
        let token = try XCTUnwrap(tokenRequest.element(forName: "token", xmlns: httpNamespace))
        XCTAssertEqual(token.elements(forName: "scope").map { $0.stringValue ?? "" }, [mamNamespace])
        XCTAssertEqual(token.element(forName: "ttl", xmlns: httpNamespace)?.stringValue, "2592000")
        XCTAssertFalse(f.manager.httpPreviewReady)
        let expires = Date().addingTimeInterval(3600)
        let jwt = bearer(expires: expires)

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: tokenRequest, body: tokenResult(value: jwt, expires: expires))))

        let grant = try XCTUnwrap(f.record.httpArchive)
        XCTAssertEqual(grant.endpoint, endpoint)
        XCTAssertEqual(grant.token, jwt)
        XCTAssertEqual(grant.scopes, [mamNamespace])
        XCTAssertEqual(grant.expiresAt.timeIntervalSince1970, expires.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(grant.discoveryDomain, domain)
        XCTAssertEqual(f.record.keyBytes, originalKey)
        XCTAssertEqual(f.writes, 1)
        XCTAssertTrue(f.manager.httpPreviewReady)
        XCTAssertTrue(f.manager.enabled)
        XCTAssertEqual(f.callbacks, [true])
    }

    func testUnaddressedHTTPProvisioningCorrelatesResponsesRegardlessOfFrom() throws {
        for sender in [owner, domain, nil, "another@example.invalid", "another.example.invalid",
                       "\(domain)/server-resource", "\(owner)/ios-http-iq"] {
            let f = fixture()
            try acknowledgeSummary(f)
            let discovery = try request(f, "endpoints")
            let discoveryID = try XCTUnwrap(discovery.attributeStringValue(forName: "id"))

            XCTAssertTrue(f.manager.read(withIQ: try reply(id: discoveryID, from: sender,
                includeSender: sender != nil, body: endpoints())))
            let token = try request(f, "token")
            let tokenID = try XCTUnwrap(token.attributeStringValue(forName: "id"))
            XCTAssertTrue(f.manager.read(withIQ: try reply(id: tokenID, from: sender,
                includeSender: sender != nil, body: tokenResult())))

            XCTAssertEqual(f.writes, 1)
            XCTAssertEqual(f.record.httpArchive?.discoveryDomain, domain)
            XCTAssertTrue(f.manager.httpPreviewReady)
            XCTAssertTrue(f.manager.enabled)
        }
    }

    func testFullModeNeverDiscoversOrIssuesHTTPTokenAfterSuccessfulEnable() throws {
        let f = fixture()
        f.mode = .full
        f.manager.enable(xmppStream: f.stream) { f.callbacks.append($0) }

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f), body: "")))

        XCTAssertTrue(f.manager.enabled)
        XCTAssertEqual(f.callbacks, [true])
        XCTAssertTrue(requests(f, "endpoints").isEmpty)
        XCTAssertTrue(requests(f, "token").isEmpty)
        XCTAssertNil(f.record.httpArchive)
    }

    func testLegacyPushResultFormCannotReplaceExplicitDiscoveryAndToken() throws {
        let f = fixture()
        f.manager.enable(xmppStream: f.stream) { f.callbacks.append($0) }
        let legacyForm = "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE'><value>https://xabber.com/protocol/push</value></field><field var='url'><value>https://wrong.example.invalid/iq</value></field><field var='jwt'><value>unrequested-token</value></field></x>"

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f), body: legacyForm)))

        XCTAssertTrue(f.manager.enabled)
        XCTAssertNil(f.record.httpArchive)
        XCTAssertFalse(f.manager.httpPreviewReady)
        XCTAssertEqual(requests(f, "endpoints").count, 1)
        XCTAssertTrue(requests(f, "token").isEmpty)
        XCTAssertEqual(f.record.jwt, "legacy-push-grant")
    }

    func testUnknownProtocolsAndEndpointNamesAreIgnoredWhileMAMByIDIsSelected() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let body = """
        <endpoints xmlns='\(httpNamespace)'>
          <protocol var='vcard-temp'><endpoint name='by-id' url='https://wrong.example.invalid/vcard'/></protocol>
          <protocol var='\(mamNamespace)'>
            <endpoint name='query' url='https://wrong.example.invalid/query'/>
            <endpoint name='by-id' url='\(endpoint)'/>
          </protocol>
        </endpoints>
        """
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: body)))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: tokenResult())))

        XCTAssertEqual(f.record.httpArchive?.endpoint, endpoint)
    }

    func testMissingMAMByIDEndpointDoesNotIssueTokenOrDisablePush() throws {
        for body in [
            "<endpoints xmlns='\(httpNamespace)'/>",
            "<endpoints xmlns='\(httpNamespace)'><protocol var='vcard-temp'><endpoint name='by-id' url='\(endpoint)'/></protocol></endpoints>",
            "<endpoints xmlns='\(httpNamespace)'><protocol var='\(mamNamespace)'><endpoint name='query' url='\(endpoint)'/></protocol></endpoints>"
        ] {
            let f = fixture()
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: body)))
            XCTAssertTrue(requests(f, "token").isEmpty)
            XCTAssertNil(f.record.httpArchive)
            XCTAssertTrue(f.manager.enabled)
            XCTAssertEqual(f.callbacks, [true])
        }
    }

    func testInvalidOrAmbiguousEndpointCannotReceiveBearerToken() throws {
        let invalidEndpoints = [
            "http://archive.example.invalid/id", "/iq/archive/id",
            "https://user:password@archive.example.invalid/id", "https://archive.example.invalid/id#fragment"
        ]
        var bodies = invalidEndpoints.map { endpoints(url: $0) }
        bodies.append("<endpoints xmlns='\(httpNamespace)'><protocol var='\(mamNamespace)'><endpoint name='by-id' url='\(endpoint)'/><endpoint name='by-id' url='https://other.example.invalid/id'/></protocol></endpoints>")
        bodies.append(endpoints().replacingOccurrences(of: httpNamespace, with: "urn:foreign:http-iq"))
        bodies.append("<endpoints xmlns='\(httpNamespace)'><protocol xmlns='urn:foreign:http-iq' var='\(mamNamespace)'><endpoint name='by-id' url='\(endpoint)'/></protocol></endpoints>")
        for body in bodies {
            let f = fixture()
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: body)))
            XCTAssertTrue(requests(f, "token").isEmpty)
            XCTAssertFalse(f.manager.httpPreviewReady)
            XCTAssertTrue(f.manager.enabled)
        }
    }

    func testDiscoveryErrorDoesNotIssueTokenAndExplicitRefreshCanRetry() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: discovery, type: "error", body: stanzaError())))
        XCTAssertFalse(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        XCTAssertTrue(requests(f, "token").isEmpty)
        XCTAssertTrue(f.manager.enabled)
        f.manager.refresh(xmppStream: f.stream) { f.callbacks.append($0) }
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f, index: 1), body: "")))

        XCTAssertEqual(requests(f, "endpoints").count, 2)
        XCTAssertEqual(f.callbacks, [true, true])
    }

    func testReadinessChecksDoNotRequestRetryWhileDiscoveryOrTokenIsPending() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")
        for _ in 0..<3 {
            XCTAssertFalse(f.manager.needsHTTPArchive)
        }
        XCTAssertEqual(requests(f, "endpoints").count, 1)
        XCTAssertTrue(requests(f, "token").isEmpty)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        let token = try request(f, "token")
        for _ in 0..<3 {
            XCTAssertFalse(f.manager.needsHTTPArchive)
        }
        XCTAssertEqual(requests(f, "token").count, 1)

        let timeout = try XCTUnwrap(f.timeouts.last)
        timeout.fire()

        XCTAssertTrue(f.manager.needsHTTPArchive)
        XCTAssertTrue(f.manager.enabled)
        XCTAssertFalse(f.manager.read(withIQ: try reply(to: token, body: tokenResult())))
    }

    func testDiscoveryTimeoutIgnoresLateReplyAndNeverDisablesPush() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")
        let timeout = try XCTUnwrap(f.timeouts.last)

        timeout.fire()
        timeout.fire()

        XCTAssertTrue(f.manager.enabled)
        XCTAssertFalse(f.manager.httpPreviewReady)
        XCTAssertFalse(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        XCTAssertTrue(requests(f, "token").isEmpty)
        XCTAssertEqual(f.callbacks, [true])
    }

    func testTokenErrorAndTimeoutKeepPushEnabledWithoutPublishingGrant() throws {
        for shouldTimeout in [false, true] {
            let f = fixture()
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
            let token = try request(f, "token")
            if shouldTimeout {
                let timeout = try XCTUnwrap(f.timeouts.last)
                timeout.fire()
                timeout.fire()
            } else {
                XCTAssertTrue(f.manager.read(withIQ: try reply(to: token, type: "error", body: stanzaError())))
            }
            XCTAssertFalse(f.manager.read(withIQ: try reply(to: token, body: tokenResult())))
            XCTAssertNil(f.record.httpArchive)
            XCTAssertTrue(f.manager.enabled)
            XCTAssertEqual(f.callbacks, [true])
        }
    }

    func testTokenResultRequiresMAMScopeValueAndFutureAbsoluteExpiration() throws {
        let valid = tokenResult()
        let malformed = [
            valid.replacingOccurrences(of: mamNamespace, with: "vcard-temp"),
            valid.replacingOccurrences(of: "<scope>\(mamNamespace)</scope>", with: ""),
            valid.replacingOccurrences(of: "<scope>\(mamNamespace)</scope>", with: "<scope><nested>\(mamNamespace)</nested></scope>"),
            valid.replacingOccurrences(of: "</token>", with: "<value>duplicate-token</value></token>"),
            tokenResult(value: ""), tokenResult(expires: Date(timeIntervalSince1970: 1)),
            valid.replacingOccurrences(of: "<ttl>3600</ttl>", with: "<ttl>0</ttl>"),
            valid.replacingOccurrences(of: "<ttl>3600</ttl>", with: "<ttl>invalid</ttl>"),
            valid.replacingOccurrences(of: httpNamespace, with: "urn:foreign:http-iq"),
            "<token xmlns='\(httpNamespace)'><scope>\(mamNamespace)</scope><value>header.payload.signature</value></token>"
        ]
        for body in malformed {
            let f = fixture()
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: body)))
            XCTAssertNil(f.record.httpArchive)
            XCTAssertFalse(f.manager.httpPreviewReady)
            XCTAssertTrue(f.manager.enabled)
        }
    }

    func testExpiredJWTSchedulingHintCannotPublishGrantDespiteFutureXMPPExpiration() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
        let expiredBearer = bearer(expires: Date(timeIntervalSince1970: 1))
        let body = tokenResult(value: expiredBearer, expires: Date().addingTimeInterval(3600))

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: body)))

        XCTAssertEqual(f.writes, 0)
        XCTAssertNil(f.record.httpArchive)
        XCTAssertFalse(f.manager.httpPreviewReady)
        XCTAssertTrue(f.manager.enabled)
        XCTAssertEqual(f.callbacks, [true])
    }

    func testOptionalTTLMayBeAbsentAndServerMayClampIt() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let expires = now.addingTimeInterval(1800)
        for body in [
            tokenResult(expires: expires).replacingOccurrences(of: "<ttl>3600</ttl>", with: ""),
            tokenResult(expires: expires).replacingOccurrences(of: "<ttl>3600</ttl>", with: "<ttl>1800</ttl>")
        ] {
            let f = fixture()
            f.manager.httpArchiveNow = { now }
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: body)))
            XCTAssertEqual(try XCTUnwrap(f.record.httpArchive).expiresAt, expires)
            XCTAssertEqual(f.record.tokenExpiresAt, expires)
            XCTAssertEqual(f.writes, 1)
            XCTAssertTrue(f.manager.httpPreviewReady)
        }
    }

    func testWrongIDRecipientAndIQTypeCannotConsumeCurrentHTTPQuery() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")
        let id = try XCTUnwrap(discovery.attributeStringValue(forName: "id"))
        for iq in [
            try reply(id: "wrong-id", body: endpoints()),
            try reply(id: id, to: "another@example.invalid/ios-http-iq", body: endpoints()),
            try reply(id: id, to: "\(owner)/other-resource", body: endpoints()),
            try reply(id: id, type: "get", body: endpoints())
        ] {
            XCTAssertFalse(f.manager.read(withIQ: iq))
            XCTAssertTrue(requests(f, "token").isEmpty)
        }
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        XCTAssertEqual(requests(f, "token").count, 1)
    }

    func testCorrelatedTokenResponsePublishesGrantRegardlessOfFrom() throws {
        for sender in [owner, domain, nil, "another@example.invalid", "another.example.invalid",
                       "\(domain)/server-resource", "\(owner)/ios-http-iq"] {
            let f = fixture()
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
            let token = try request(f, "token")
            let id = try XCTUnwrap(token.attributeStringValue(forName: "id"))

            XCTAssertTrue(f.manager.read(withIQ: try reply(id: id, from: sender,
                includeSender: sender != nil, body: tokenResult())))
            XCTAssertEqual(f.writes, 1)
            XCTAssertNotNil(f.record.httpArchive)
            XCTAssertTrue(f.manager.httpPreviewReady)
            XCTAssertTrue(f.manager.enabled)
        }
    }

    func testDuplicateDiscoveryAndTokenRepliesCannotRepublishOrIssueTwice() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        let token = try request(f, "token")
        XCTAssertFalse(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: token, body: tokenResult())))
        let generation = f.record.tokenGeneration

        XCTAssertFalse(f.manager.read(withIQ: try reply(to: token, body: tokenResult())))

        XCTAssertEqual(requests(f, "token").count, 1)
        XCTAssertEqual(f.writes, 1)
        XCTAssertEqual(f.record.tokenGeneration, generation)
    }

    func testDisconnectConfigurationAndModeChangesInvalidateInflightHTTPResponses() throws {
        for cancel in [0, 1, 2] {
            let f = fixture()
            try acknowledgeSummary(f)
            XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
            let token = try request(f, "token")
            if cancel == 0 { f.manager.clearSession() }
            if cancel == 1 { f.manager.service = "replacement-push.example.invalid" }
            if cancel == 2 {
                f.mode = .full
                f.manager.enable(xmppStream: f.stream) { _ in }
            }

            XCTAssertFalse(f.manager.read(withIQ: try reply(to: token, body: tokenResult())))
            XCTAssertNil(f.record.httpArchive)
            XCTAssertEqual(f.writes, 0)
        }
    }

    func testChangedStreamResourceCannotAcceptHTTPResult() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        let discovery = try request(f, "endpoints")
        f.stream.myJID = XMPPJID(string: owner, resource: "replacement-session")

        XCTAssertFalse(f.manager.read(withIQ: try reply(to: discovery, body: endpoints())))

        XCTAssertNil(f.record.httpArchive)
        XCTAssertTrue(requests(f, "token").isEmpty)
    }

    func testAccountDelegateIgnoresHTTPReplyFromReplacedPrimaryStream() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
        let result = try reply(to: request(f, "token"), body: tokenResult())
        let account = Account(jid: owner, queue: DispatchQueue(label: "PushHTTPIQ.stale-stream.\(UUID())"))
        account.push = f.manager
        let replacement = Stream()
        replacement.myJID = f.stream.myJID
        account.xmppStream = replacement

        _ = account.xmppStream(f.stream, didReceive: result)

        XCTAssertEqual(f.writes, 0)
        XCTAssertNil(f.record.httpArchive)
        account.xmppStream = f.stream
        _ = account.xmppStream(f.stream, didReceive: result)
        XCTAssertEqual(f.writes, 1)
        XCTAssertTrue(f.manager.httpPreviewReady)
    }

    func testDurableWriteFailureKeepsPushEnabledAndExplicitRefreshCanRecover() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
        f.failWrites = true

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: tokenResult())))

        XCTAssertNil(f.record.httpArchive)
        XCTAssertFalse(f.manager.httpPreviewReady)
        XCTAssertTrue(f.manager.enabled)
        XCTAssertEqual(f.callbacks, [true])
        f.failWrites = false
        f.manager.refresh(xmppStream: f.stream) { f.callbacks.append($0) }
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f, index: 1), body: "")))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints", index: 1), body: endpoints())))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token", index: 1), body: tokenResult())))
        XCTAssertTrue(f.manager.httpPreviewReady)
        XCTAssertEqual(f.writes, 1)
        XCTAssertEqual(f.callbacks, [true, true])
    }

    func testTokenRefreshKeepsEncryptionKeyAndInvalidationCannotAffectNewGeneration() throws {
        let f = fixture()
        try completeProvisioning(f)
        let originalKey = f.record.keyBytes
        let oldGeneration = f.record.tokenGeneration
        let markers = try XCTUnwrap(f.manager.tokenInvalidationStore)
        try markers.invalidate(node: f.manager.node, generation: oldGeneration)
        XCTAssertFalse(f.manager.httpPreviewReady)
        f.manager.refresh(xmppStream: f.stream) { _ in }
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f, index: 1), body: "")))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints", index: 1), body: endpoints())))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token", index: 1), body: tokenResult())))

        XCTAssertEqual(f.record.keyBytes, originalKey)
        XCTAssertNotEqual(f.record.tokenGeneration, oldGeneration)
        XCTAssertTrue(try markers.contains(node: f.manager.node, generation: oldGeneration))
        XCTAssertTrue(f.manager.httpPreviewReady)
    }

    func testReadinessExpiresByServerAbsoluteExpirationWithoutDisablingPush() throws {
        let f = fixture()
        var now = Date(timeIntervalSince1970: 1_900_000_000)
        f.manager.httpArchiveNow = { now }
        try acknowledgeSummary(f)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: tokenResult(expires: now.addingTimeInterval(3600)))))
        XCTAssertTrue(f.manager.httpPreviewReady)

        now = now.addingTimeInterval(3600)

        XCTAssertFalse(f.manager.httpPreviewReady)
        XCTAssertTrue(f.manager.needsHTTPArchive)
        XCTAssertTrue(f.manager.enabled)
    }

    func testFailedRefreshPublicationKeepsPreviousValidModernGrant() throws {
        let f = fixture()
        try completeProvisioning(f)
        let previous = f.record.httpArchive
        let generation = f.record.tokenGeneration
        f.failWrites = true
        f.manager.refresh(xmppStream: f.stream) { f.callbacks.append($0) }
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f, index: 1), body: "")))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints", index: 1), body: endpoints())))

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token", index: 1),
            body: tokenResult(expires: Date().addingTimeInterval(7200)))))

        XCTAssertEqual(f.record.httpArchive, previous)
        XCTAssertEqual(f.record.tokenGeneration, generation)
        XCTAssertTrue(f.manager.httpPreviewReady, "The protocol does not revoke a previous token when issuing another")
        XCTAssertTrue(f.manager.enabled)
        XCTAssertEqual(f.callbacks, [true, true])
    }

    func testCredentialKeyChangeBeforeTokenResponseCannotPublishOverReplacementKey() throws {
        let f = fixture()
        try acknowledgeSummary(f)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
        f.record = CredentialsManager.PushSecretData(host: domain, secret: String(repeating: "z", count: 32),
                                                   jid: owner, service: "", jwt: "")

        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: tokenResult())))

        XCTAssertEqual(f.record.secret, String(repeating: "z", count: 32))
        XCTAssertNil(f.record.httpArchive)
        XCTAssertEqual(f.writes, 0)
    }

    private func fixture() -> Fixture {
        let f = Fixture(owner: owner)
        fixtures.append(f)
        return f
    }

    private func acknowledgeSummary(_ f: Fixture) throws {
        f.manager.enable(xmppStream: f.stream) { f.callbacks.append($0) }
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: pushRequest(f), body: "")))
    }

    private func completeProvisioning(_ f: Fixture) throws {
        try acknowledgeSummary(f)
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "endpoints"), body: endpoints())))
        XCTAssertTrue(f.manager.read(withIQ: try reply(to: request(f, "token"), body: tokenResult())))
    }

    private func pushRequest(_ f: Fixture, index: Int = 0) throws -> DDXMLElement {
        try XCTUnwrap(f.stream.requests("enable", namespace: "https://xabber.com/protocol/push").dropFirst(index).first)
    }

    private func requests(_ f: Fixture, _ child: String) -> [DDXMLElement] {
        f.stream.requests(child, namespace: httpNamespace)
    }

    private func request(_ f: Fixture, _ child: String, index: Int = 0) throws -> DDXMLElement {
        try XCTUnwrap(requests(f, child).dropFirst(index).first)
    }

    private func reply(to request: DDXMLElement, type: String = "result", body: String) throws -> XMPPIQ {
        try reply(id: XCTUnwrap(request.attributeStringValue(forName: "id")), type: type, body: body)
    }

    private func reply(id: String, type: String = "result", from: String? = nil, to: String? = nil,
                       includeSender: Bool = true, body: String) throws -> XMPPIQ {
        let sender = includeSender ? " from='\(from ?? domain)'" : ""
        let document = try DDXMLDocument(
            xmlString: "<iq type='\(type)'\(sender) to='\(to ?? "\(owner)/ios-http-iq")' id='\(id)'>\(body)</iq>", options: 0
        )
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func endpoints(url: String? = nil) -> String {
        "<endpoints xmlns='\(httpNamespace)'><protocol var='\(mamNamespace)'><endpoint name='by-id' url='\(url ?? endpoint)'/></protocol></endpoints>"
    }

    private func tokenResult(value: String? = nil, expires: Date = Date().addingTimeInterval(3600)) -> String {
        let stamp = ISO8601DateFormatter().string(from: expires)
        return "<token xmlns='\(httpNamespace)'><scope>\(mamNamespace)</scope><ttl>3600</ttl><expires>\(stamp)</expires><value>\(value ?? bearer(expires: expires))</value></token>"
    }

    private func bearer(expires: Date) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        let payload = "{\"iss\":\"\(domain)\",\"sub\":\"\(owner)/device-42\",\"scope\":[\"\(mamNamespace)\"],\"exp\":\(Int(expires.timeIntervalSince1970))}"
        return "\(header).\(base64URL(Data(payload.utf8))).c2lnbmF0dXJl"
    }

    private func stanzaError() -> String {
        "<error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>"
    }
}
