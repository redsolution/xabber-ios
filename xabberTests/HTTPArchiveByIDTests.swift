import Foundation
import KissXML
import XCTest
@testable import xabber

final class HTTPArchiveByIDTests: XCTestCase {
    private let owner = "romeo@example.com"
    private var fixtureHosts: [String] = []

    override func tearDown() {
        fixtureHosts.forEach { ArchiveHTTPURLProtocol.remove(host: $0) }
        fixtureHosts.removeAll()
        super.tearDown()
    }

    func testRequestPreservesServerBaseArchiveRouteAndBearer() throws {
        let request = try XCTUnwrap(PushArchiveHTTPClient.makeRequest(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/iq")),
            token: "fixture-token", id: "123", by: owner
        ))
        XCTAssertEqual(request.url?.path, "/iq/archive")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testQueryEncodesLiteralPlusForServerFormDecoder() throws {
        let request = try XCTUnwrap(PushArchiveHTTPClient.makeRequest(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/iq")),
            token: "fixture-token", id: "123+45&?", by: "romeo+device@example.com"
        ))
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertTrue(query.contains("%2B"))
        XCTAssertFalse(query.contains("+"))
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "123+45&?")
    }

    func testActualServerMessageAndFinalIQSequenceProducesMessage() {
        assertMessage(decode(message() + fin()), id: "123")
    }

    func testEmptyFinalIQIsSuccessfulEmptyArchiveResult() {
        guard case .empty = decode(fin()) else { return XCTFail("Expected an empty archive result, not invalid XML") }
    }

    func testHTTP200XMPPErrorIsPreservedWithoutUnauthorized() {
        let xml = """
        <iq from='\(owner)' type='error' id='query-1'>
          <query xmlns='urn:xmpp:mam:2'/>
          <error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>
        </iq>
        """
        guard case .xmppError(let condition) = decode(xml) else { return XCTFail("Expected ordinary XMPP error") }
        XCTAssertEqual(condition, "item-not-found")
    }

    func testSingleRootDocumentWithXMLDeclarationProducesMessage() {
        assertMessage(decode("<?xml version='1.0' encoding='UTF-8'?>" + message()), id: "123")
    }

    func testMismatchedArchiveResultIDIsRejected() {
        assertFailure(decode(message(id: "456") + fin()), .invalidResponse)
    }

    func testMismatchedArchiveOwnerIsRejected() {
        assertFailure(decode(message(from: "other@example.com") + fin()), .invalidResponse)
    }

    func testSequenceFinalIQMustMatchMessageQueryID() {
        assertFailure(decode(message() + fin().replacingOccurrences(of: "id='query-1'", with: "id='different-query'")), .invalidResponse)
    }

    func testMultipleMessagesAndForeignMAMNamespaceAreRejected() {
        assertFailure(decode(message() + message() + fin()), .invalidResponse)
        assertFailure(decode(message().replacingOccurrences(of: "urn:xmpp:mam:2", with: "https://foreign.example/mam") + fin()), .invalidResponse)
    }

    func testDTDAndEntityDeclarationsAreRejected() {
        assertFailure(decode("<!DOCTYPE message [<!ENTITY secret 'value'>]>" + message()), .invalidResponse)
    }

    func testRequestRejectsUnsafeURLAndAmbiguousReservedQueryParameters() throws {
        for value in ["http://example.com/iq", "https://user:password@example.com/iq", "https://example.com/iq#fragment", "https://example.com/iq?id=old"] {
            XCTAssertNil(PushArchiveHTTPClient.makeRequest(baseURL: try XCTUnwrap(URL(string: value)), token: "fixture-token", id: "123", by: nil))
        }
    }

    func testActualHTTPClientAcceptsServerTextHTMLContentTypeAndPreservesLiteralQuery() throws {
        let body = message() + fin()
        let received = expectation(description: "typed HTTP archive result")
        let client = try makeClient { request, stub in
            XCTAssertEqual(request.url?.path, "/iq/archive")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            stub.respond(status: 200, body: Data(body.utf8), headers: ["Content-Type": "text/html; charset=utf-8"])
        }
        client.fetch(id: "123") { outcome in
            self.assertMessage(outcome, id: "123")
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    func testHTTP401IsTypedUnauthorizedAndNeverRetried() throws {
        let received = expectation(description: "authorization rejection")
        received.assertForOverFulfill = true
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient { _, stub in
            XCTAssertEqual(count.increment(), 1)
            stub.respond(status: 401, body: Data("invalid_auth".utf8))
        }
        client.fetch(id: "123") { outcome in
            guard case .unauthorized = outcome else { return XCTFail("Expected unauthorized") }
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 1)
    }

    func testHTTP200XMPPErrorThroughTransportDoesNotRejectJWT() throws {
        let received = expectation(description: "ordinary XMPP error")
        let client = try makeClient { _, stub in
            stub.respond(status: 200, body: Data("<iq from='romeo@example.com' type='error' id='q'><error type='auth'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>".utf8))
        }
        client.fetch(id: "123") { outcome in
            guard case .xmppError(let condition) = outcome else { return XCTFail("Expected operation error, not unauthorized") }
            XCTAssertEqual(condition, "forbidden")
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    func testDeclaredOversizedResponseIsRejectedBeforeBuffering() throws {
        let received = expectation(description: "oversized headers")
        let client = try makeClient(maximumResponseSize: 128) { _, stub in
            stub.respond(status: 200, body: Data(), headers: ["Content-Length": "129"])
        }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .oversizedResponse)
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    func testUnknownLengthBodyIsBoundedWhileReceivingChunks() throws {
        let received = expectation(description: "streaming byte limit")
        received.assertForOverFulfill = true
        let client = try makeClient(maximumResponseSize: 128) { _, stub in
            stub.begin(status: 200)
            stub.send(Data(repeating: 65, count: 80))
            stub.send(Data(repeating: 66, count: 80))
            stub.finish()
        }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .oversizedResponse)
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    func testRedirectResponseIsRejectedWithoutASecondRequest() throws {
        let received = expectation(description: "redirect refusal")
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient { _, stub in
            XCTAssertEqual(count.increment(), 1)
            // A 3xx never becomes an accepted archive body, even if URLProtocol
            // does not emulate URLSession's redirect delegate on this platform.
            stub.respond(status: 302, body: Data(), headers: ["Location": "https://elsewhere.example/archive"])
        }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .redirect)
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 1)
    }

    func testTransientRetryOccursOnceWithinAbsoluteBudget() throws {
        let scheduler = ArchiveHTTPControlledScheduler()
        let retryScheduled = expectation(description: "one transient retry scheduled")
        scheduler.onRetryScheduled = { retryScheduled.fulfill() }
        let received = expectation(description: "bounded retry exhausted")
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient(scheduler: scheduler) { _, stub in
            _ = count.increment()
            stub.respond(status: 408, body: Data())
        }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .http(408))
            received.fulfill()
        }
        wait(for: [retryScheduled], timeout: 2)
        scheduler.perform(delay: 0.2)
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 2)
    }

    func testAbsoluteDeadlineCancelsHeldRequestExactlyOnce() throws {
        let scheduler = ArchiveHTTPControlledScheduler()
        let started = expectation(description: "HTTP request held")
        let received = expectation(description: "absolute deadline")
        received.assertForOverFulfill = true
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient(scheduler: scheduler) { _, _ in started.fulfill() }
        client.fetch(id: "123") { outcome in
            _ = count.increment()
            self.assertFailure(outcome, .timeout)
            received.fulfill()
        }
        wait(for: [started], timeout: 2)
        scheduler.perform(delay: 8)
        wait(for: [received], timeout: 2)
        client.cancel()
        XCTAssertEqual(count.value, 1)
    }

    func testCancellationBeforeFetchAvoidsNetworkAndCompletesOnce() throws {
        let received = expectation(description: "cancelled before request")
        received.assertForOverFulfill = true
        let client = try makeClient { _, _ in XCTFail("Cancelled request must not be sent") }
        client.cancel()
        client.cancel()
        client.fetch(id: "123") { outcome in
            guard case .cancelled = outcome else { return XCTFail("Expected cancellation") }
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    private func makeClient(
        maximumResponseSize: Int = 1024 * 1024,
        scheduler: ArchiveHTTPControlledScheduler? = nil,
        handler: @escaping ArchiveHTTPURLProtocol.Handler
    ) throws -> PushArchiveHTTPClient {
        let host = "\(UUID().uuidString.lowercased()).http-archive-tests.invalid"
        fixtureHosts.append(host)
        ArchiveHTTPURLProtocol.install(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveHTTPURLProtocol.self]
        return try XCTUnwrap(PushArchiveHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "https://\(host)/iq")),
            token: "fixture-token", archiveOwner: owner,
            configuration: configuration,
            maximumResponseSize: maximumResponseSize,
            scheduler: scheduler.map { controlled in { delay, work in controlled.schedule(delay: delay, work: work) } }
                ?? PushArchiveHTTPClient.liveScheduler
        ))
    }

    private func decode(_ xml: String) -> PushArchiveHTTPClient.Outcome {
        PushArchiveHTTPClient.decodeResponse(data: Data(xml.utf8), statusCode: 200, expectedID: "123", archiveOwner: owner)
    }

    private func message(id: String = "123", from: String? = nil) -> String {
        """
        <message from='\(from ?? owner)' to='\(owner)/query-1'>
          <result xmlns='urn:xmpp:mam:2' id='\(id)' queryid='query-1'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2026-10-13T01:00:00Z'/>
              <message xmlns='jabber:client' from='juliet@example.com' to='\(owner)' type='chat'><body>Hello</body></message>
            </forwarded>
          </result>
        </message>
        """
    }

    private func fin() -> String {
        """
        <iq from='\(owner)' to='\(owner)/query-1' type='result' id='query-1'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>
        """
    }

    private func assertMessage(_ outcome: PushArchiveHTTPClient.Outcome, id: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .message(let message) = outcome else { return XCTFail("Expected MAM message", file: file, line: line) }
        XCTAssertEqual(message.element(forName: "result", xmlns: "urn:xmpp:mam:2")?.attributeStringValue(forName: "id"), id, file: file, line: line)
    }

    private func assertFailure(_ outcome: PushArchiveHTTPClient.Outcome, _ expected: PushArchiveHTTPClient.Failure, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let failure) = outcome else { return XCTFail("Expected safe failure", file: file, line: line) }
        XCTAssertEqual(failure, expected, file: file, line: line)
    }
}

private final class ArchiveHTTPLockedCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

private final class ArchiveHTTPControlledScheduler {
    private let lock = NSLock()
    private var scheduled: [(TimeInterval, DispatchWorkItem)] = []
    var onRetryScheduled: (() -> Void)?

    func schedule(delay: TimeInterval, work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        lock.lock()
        scheduled.append((delay, item))
        let onRetry = delay < 1 ? onRetryScheduled : nil
        lock.unlock()
        onRetry?()
        return item
    }

    func perform(delay: TimeInterval) {
        lock.lock()
        let index = scheduled.firstIndex { abs($0.0 - delay) < 0.001 && !$0.1.isCancelled }
        let item = index.map { scheduled.remove(at: $0).1 }
        lock.unlock()
        item?.perform()
    }
}

private final class ArchiveHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest, ArchiveHTTPURLProtocol) -> Void
    private static let registryLock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private let lifecycleLock = NSLock()
    private var stopped = false

    static func install(host: String, handler: @escaping Handler) {
        registryLock.lock(); defer { registryLock.unlock() }
        handlers[host] = handler
    }

    static func remove(host: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        handlers.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".http-archive-tests.invalid") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.registryLock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.registryLock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        handler(request, self)
    }

    override func stopLoading() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        stopped = true
    }

    private var active: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return !stopped
    }

    func begin(status: Int, headers: [String: String] = [:]) {
        guard active, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) {
        guard active else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        guard active else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    func respond(status: Int, body: Data, headers: [String: String] = [:]) {
        begin(status: status, headers: headers)
        send(body)
        finish()
    }
}
