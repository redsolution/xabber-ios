import XCTest
import XMPPFramework
@testable import xabber

final class PrivacyProxyClientTests: XCTestCase {
    private let owner = "alice@example.com"
    private let endpoint = URL(string: "https://proxy.example.com/api/")!
    private let source = URL(string: "https://external.example.net/file?a=b+c&other=a%26b#client-only")!
    private let proxiedURL = URL(string: "https://proxy.example.com/api/proxy/files/opaque/")!

    func testCodeRequestAndExchangeUseCorrectJIDsAndBearerStaysOnLookup() async throws {
        let fixture = makeFixture()

        let result = try await fixture.client.resolve(originalURL: source, owner: owner)

        XCTAssertEqual(result, proxiedURL)
        let requests = fixture.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/xmpp_auth/code_request", "/api/xmpp_auth/confirm", "/api/proxy/geturl"
        ])
        XCTAssertEqual(requests.map { $0.httpMethod }, ["POST", "POST", "GET"])
        XCTAssertEqual(try body(requests[0]), ["jid": owner + "/ios", "type": "iq"])
        XCTAssertEqual(try body(requests[1]), ["jid": owner, "code": "code-1"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let lookup = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests[2].url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(lookup.queryItems, [URLQueryItem(name: "url", value: "https://external.example.net/file?a=b+c&other=a%26b")])
        XCTAssertTrue(lookup.percentEncodedQuery?.contains("%2B") == true)
        XCTAssertEqual(fixture.acknowledgementIDs, ["request-1"])
    }

    func testEarlyConfirmationsMustMatchHTTPIDSenderRecipientAndStream() async throws {
        let fixture = makeFixture()
        let otherStream = XMPPStream()
        fixture.beforeConfirmation = { fixture, requestID in
            let fromWrongStream = fixture.makeConfirmation(id: requestID, sender: "proxy-bot@example.com")
            XCTAssertFalse(fixture.client.read(fromWrongStream, from: otherStream, owner: self.owner))

            let wrongRecipient = fixture.makeConfirmation(
                id: requestID, sender: "proxy-bot@example.com", recipient: self.owner + "/other"
            )
            XCTAssertFalse(fixture.client.read(wrongRecipient, from: fixture.stream, owner: self.owner))
            let wrongMethod = fixture.makeConfirmation(
                id: requestID, sender: "proxy-bot@example.com", method: "GET"
            )
            XCTAssertFalse(fixture.client.read(wrongMethod, from: fixture.stream, owner: self.owner))

            for candidate in [
                fixture.makeConfirmation(id: "unrelated", sender: "proxy-bot@example.com"),
                fixture.makeConfirmation(id: requestID, sender: "not-the-proxy@example.com", method: "POST")
            ] {
                XCTAssertTrue(fixture.client.read(candidate, from: fixture.stream, owner: self.owner))
            }
        }

        let result = try await fixture.client.resolve(originalURL: source, owner: owner)

        XCTAssertEqual(result, proxiedURL)
        XCTAssertEqual(fixture.acknowledgementIDs, ["request-1"])
        XCTAssertEqual(try body(fixture.requests[1])["code"], "code-1")
    }

    func testMissingConfirmationTimesOutWithoutExchangingCode() async throws {
        let fixture = makeFixture(deliverConfirmation: false, confirmationTimeout: 0.01)

        do {
            _ = try await fixture.client.resolve(originalURL: source, owner: owner)
            XCTFail("Expected correlation timeout")
        } catch {
            XCTAssertEqual(error as? PrivacyProxyClientError, .confirmationTimedOut)
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertTrue(fixture.acknowledgementIDs.isEmpty)
    }

    func testUnauthorizedLookupRefreshesOnceAndUsesNewToken() async throws {
        let fixture = makeFixture(lookupStatuses: [401, 200, 200])

        let first = try await fixture.client.resolve(originalURL: source, owner: owner)
        let second = try await fixture.client.resolve(originalURL: source, owner: owner)

        XCTAssertEqual(first, proxiedURL)
        XCTAssertEqual(second, proxiedURL)
        XCTAssertEqual(fixture.acknowledgementIDs, ["request-1", "request-2"])
        XCTAssertEqual(
            fixture.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer token-1", "Bearer token-2", "Bearer token-2"]
        )
    }

    func testConcurrentLookupsShareOneAuthorization() async throws {
        let fixture = makeFixture()

        async let first = fixture.client.resolve(originalURL: source, owner: owner)
        async let second = fixture.client.resolve(originalURL: source, owner: owner)
        let results = try await [first, second]

        XCTAssertEqual(results, [proxiedURL, proxiedURL])
        XCTAssertEqual(fixture.acknowledgementIDs, ["request-1"])
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testLookupRejectsOffOriginAndNonFileURLs() async throws {
        for candidate in [
            URL(string: "https://external.example.net/file")!,
            URL(string: "https://proxy.example.com/api/other")!,
            URL(string: "https://proxy.example.com/api/proxy/files/../")!,
            URL(string: "https://proxy.example.com:8443/api/proxy/files/opaque/")!
        ] {
            let fixture = makeFixture(resolvedURL: candidate)
            do {
                _ = try await fixture.client.resolve(originalURL: source, owner: owner)
                XCTFail("Unexpected URL: \(candidate)")
            } catch {
                XCTAssertEqual(error as? PrivacyProxyClientError, .invalidResponse)
            }
        }
    }

    private func makeFixture(
        lookupStatuses: [Int] = [],
        resolvedURL: URL? = nil,
        deliverConfirmation: Bool = true,
        confirmationTimeout: TimeInterval = 1
    ) -> Fixture {
        Fixture(
            owner: owner,
            endpoint: endpoint,
            resolvedURL: resolvedURL ?? proxiedURL,
            lookupStatuses: lookupStatuses,
            deliverConfirmation: deliverConfirmation,
            confirmationTimeout: confirmationTimeout
        )
    }

    private func body(_ request: URLRequest) throws -> [String: String] {
        let data = try XCTUnwrap(request.httpBody)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private final class Fixture {
        let stream = XMPPStream()
        let owner: String
        let endpoint: URL
        let resolvedURL: URL
        let deliverConfirmation: Bool
        private let lock = NSLock()
        private var recordedRequests: [URLRequest] = []
        private var recordedAcknowledgements: [String] = []
        private var lookupStatuses: [Int]
        private var authorizationCount = 0
        var beforeConfirmation: ((Fixture, String) -> Void)?
        private(set) var client: PrivacyProxyClient!

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        var acknowledgementIDs: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedAcknowledgements
        }

        init(
            owner: String,
            endpoint: URL,
            resolvedURL: URL,
            lookupStatuses: [Int],
            deliverConfirmation: Bool,
            confirmationTimeout: TimeInterval
        ) {
            self.owner = owner
            self.endpoint = endpoint
            self.resolvedURL = resolvedURL
            self.lookupStatuses = lookupStatuses
            self.deliverConfirmation = deliverConfirmation
            self.client = PrivacyProxyClient(
                contextForOwner: { [weak self] owner in
                    guard let self, owner == self.owner else { return nil }
                    return PrivacyProxyClient.Context(
                        endpoint: endpoint, stream: self.stream,
                        fullJID: owner + "/ios", authenticationGeneration: 1,
                        isCurrent: { true },
                        acknowledge: { [weak self] iq in
                            self?.recordAcknowledgement(iq)
                            return true
                        }
                    )
                },
                transport: { [weak self] request in
                    guard let self else { throw PrivacyProxyClientError.unavailable }
                    return try self.respond(to: request)
                },
                confirmationTimeout: confirmationTimeout
            )
        }

        func makeConfirmation(
            id: String,
            sender: String,
            recipient: String? = nil,
            code: String = "ignored",
            method: String? = nil
        ) -> XMPPIQ {
            let confirm = DDXMLElement(name: "confirm", xmlns: "http://jabber.org/protocol/http-auth")
            confirm.addAttribute(withName: "id", stringValue: code)
            if let method { confirm.addAttribute(withName: "method", stringValue: method) }
            confirm.addAttribute(
                withName: "url",
                stringValue: endpoint.appendingPathComponent("xmpp_auth/code_request/confirm").absoluteString
            )
            let iq = XMPPIQ(iqType: .get, to: XMPPJID(string: recipient ?? owner + "/ios"), elementID: id, child: confirm)
            iq.addAttribute(withName: "from", stringValue: sender)
            return iq
        }

        private func recordAcknowledgement(_ iq: XMPPIQ) {
            lock.lock()
            defer { lock.unlock() }
            recordedAcknowledgements.append(iq.elementID ?? "")
        }

        private func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            let (status, body) = try responseData(for: url, request: request)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (try JSONEncoder().encode(body), response)
        }

        private func responseData(for url: URL, request: URLRequest) throws -> (Int, [String: String]) {
            lock.lock()
            defer { lock.unlock() }
            recordedRequests.append(request)
            switch url.path {
            case "/api/xmpp_auth/code_request":
                authorizationCount += 1
                let id = "request-\(authorizationCount)"
                beforeConfirmation?(self, id)
                if deliverConfirmation {
                    let iq = makeConfirmation(id: id, sender: "proxy-bot@example.com", code: "code-\(authorizationCount)")
                    XCTAssertTrue(client.read(iq, from: stream, owner: owner))
                }
                return (201, ["request_id": id, "api_jid": "proxy-bot@example.com"])
            case "/api/xmpp_auth/confirm":
                return (201, ["token": "token-\(authorizationCount)", "expires": "2099-01-01T00:00:00.123456+00:00Z"])
            case "/api/proxy/geturl":
                return (lookupStatuses.isEmpty ? 200 : lookupStatuses.removeFirst(), ["url": resolvedURL.absoluteString])
            default:
                XCTFail("Unexpected path: \(url.path)")
                throw PrivacyProxyClientError.invalidResponse
            }
        }
    }
}
