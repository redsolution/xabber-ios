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

    func testRequestUsesExactDiscoveredByIDEndpointAndBearer() throws {
        let request = try XCTUnwrap(PushArchiveHTTPClient.makeRequest(
            endpointURL: try XCTUnwrap(URL(string: "https://example.com/custom/archive/id?tenant=ios")),
            token: "fixture-token", id: "123", by: owner
        ))
        XCTAssertEqual(request.url?.path, "/custom/archive/id")
        XCTAssertEqual(request.url?.query, "tenant=ios&id=123&by=romeo%40example.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/xml")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testQueryEncodesLiteralPlusForServerFormDecoder() throws {
        let request = try XCTUnwrap(PushArchiveHTTPClient.makeRequest(
            endpointURL: try XCTUnwrap(URL(string: "https://example.com/custom/archive/id?tenant=ios")),
            token: "fixture-token", id: "123+45&?", by: "romeo+device@example.com"
        ))
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertTrue(query.contains("%2B"))
        XCTAssertFalse(query.contains("+"))
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value, "123+45&?")
    }

    func testSingleMAMResultDocumentProducesMessage() {
        assertMessage(decode(message()), id: "123")
    }

    func testLegacySequenceWithoutFinalQueryIDAndArchiveBoundsIsRejected() {
        assertFailure(decode(message() + fin()), .invalidResponse)
    }

    func testServerMAMMessageAndCorrelatedFinalIQProduceMessage() {
        assertMessage(decode(serverMessage() + serverFinalIQ()), id: "123")
    }

    func testServerMAMSequenceRejectsMismatchedArchiveResultID() {
        let xml = serverMessage().replacingOccurrences(of: "id='123'", with: "id='456'") + serverFinalIQ()
        assertFailure(decode(xml), .invalidResponse)
    }

    func testServerMAMSequenceRejectsMismatchedMessageOwner() {
        let message = serverMessage().replacingOccurrences(of: "from='\(owner)'", with: "from='other@example.com'")
        assertFailure(decode(message + serverFinalIQ()), .invalidResponse)
    }

    func testServerMAMSequenceRejectsMismatchedFinalOwnerOrSender() {
        for sender in ["other@example.com", "\(owner)/other-resource"] {
            let final = serverFinalIQ().replacingOccurrences(of: "from='\(owner)'", with: "from='\(sender)'")
            assertFailure(decode(serverMessage() + final), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsMismatchedFinalRecipient() {
        let final = serverFinalIQ().replacingOccurrences(of: "to='\(owner)/query-1'", with: "to='\(owner)/other-resource'")
        assertFailure(decode(serverMessage() + final), .invalidResponse)
    }

    func testServerMAMSequenceRejectsMissingOrMismatchedResultQueryID() {
        for replacement in ["", "queryid='other-query'"] {
            let message = serverMessage().replacingOccurrences(of: "queryid='query-1'", with: replacement)
            assertFailure(decode(message + serverFinalIQ()), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsMissingOrMismatchedFinalIQID() {
        for replacement in ["", "id='other-query'"] {
            let final = serverFinalIQ().replacingOccurrences(of: " id='query-1'", with: " \(replacement)")
            assertFailure(decode(serverMessage() + final), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsMissingOrMismatchedFinalQueryID() {
        for replacement in ["", "queryid='other-query'"] {
            let final = serverFinalIQ().replacingOccurrences(of: "queryid='query-1'", with: replacement)
            assertFailure(decode(serverMessage() + final), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsForeignFinalNamespaces() {
        let final = serverFinalIQ()
        let variants = [
            final.replacingOccurrences(of: "xmlns='jabber:client'", with: "xmlns='urn:foreign'"),
            final.replacingOccurrences(of: "xmlns='urn:xmpp:mam:2'", with: "xmlns='urn:foreign'"),
            final.replacingOccurrences(of: "xmlns='http://jabber.org/protocol/rsm'", with: "xmlns='urn:foreign'")
        ]
        for variant in variants {
            assertFailure(decode(serverMessage() + variant), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsFinalIQThatIsNotACompleteResult() {
        let final = serverFinalIQ()
        let variants = [
            final.replacingOccurrences(of: "type='result'", with: "type='error'"),
            final.replacingOccurrences(of: "type='result'", with: "type='get'"),
            final.replacingOccurrences(of: "complete='true'", with: "complete='false'"),
            final.replacingOccurrences(of: "complete='true'", with: "")
        ]
        for variant in variants {
            assertFailure(decode(serverMessage() + variant), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsMismatchedArchiveBounds() {
        let final = serverFinalIQ()
        for variant in [
            final.replacingOccurrences(of: "<first>123</first>", with: "<first>456</first>"),
            final.replacingOccurrences(of: "<last>123</last>", with: "<last>456</last>")
        ] {
            assertFailure(decode(serverMessage() + variant), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsSecondMessageOrAdditionalRoot() {
        assertFailure(decode(serverMessage() + serverMessage() + serverFinalIQ()), .invalidResponse)
        assertFailure(decode(serverMessage() + serverFinalIQ() + "<unexpected/>"), .invalidResponse)
        assertFailure(decode(serverFinalIQ() + serverMessage()), .invalidResponse)
    }

    func testServerMAMSequenceRejectsTextOutsideStanzas() {
        let message = serverMessage()
        let final = serverFinalIQ()
        for xml in ["text" + message + final, message + "text" + final, message + final + "text"] {
            assertFailure(decode(xml), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsDTDAndEntityDeclarations() {
        let xml = "<!DOCTYPE message [<!ENTITY secret 'value'>]>" + serverMessage() + serverFinalIQ()
        assertFailure(decode(xml), .invalidResponse)
    }

    func testServerMAMSequenceAllowsWhitespaceAroundStanzas() {
        assertMessage(decode(" \n" + serverMessage() + "\n\t" + serverFinalIQ() + "\n"), id: "123")
    }

    func testServerMAMSequenceRejectsCommentsInstructionsAndMetadataText() {
        for separator in ["<!-- ignored -->", "<?probe value?>"] {
            assertFailure(decode(serverMessage() + separator + serverFinalIQ()), .invalidResponse)
        }
        for final in [
            serverFinalIQ().replacingOccurrences(of: "<set xmlns=", with: "junk<set xmlns="),
            serverFinalIQ().replacingOccurrences(of: "<first>", with: "<!-- ignored --><first>"),
            serverFinalIQ().replacingOccurrences(of: "<first>123", with: "<first><?probe value?>123")
        ] {
            assertFailure(decode(serverMessage() + final), .invalidResponse)
        }
    }

    func testServerMAMSequenceRejectsDuplicateRSMAndExtraIQChildren() {
        let extraSet = "<set xmlns='http://jabber.org/protocol/rsm'><first>123</first><last>123</last></set>"
        for final in [
            serverFinalIQ().replacingOccurrences(of: "</fin>", with: extraSet + "</fin>"),
            serverFinalIQ().replacingOccurrences(of: "</iq>", with: "<unexpected/></iq>")
        ] {
            assertFailure(decode(serverMessage() + final), .invalidResponse)
        }
    }

    func testFinalIQWithoutMAMMessageIsNotAByIDResponse() {
        assertFailure(decode(fin()), .invalidResponse)
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
        assertFailure(decode(message(id: "456")), .invalidResponse)
    }

    func testMismatchedArchiveOwnerIsRejected() {
        assertFailure(decode(message(from: "other@example.com")), .invalidResponse)
    }

    func testUnknownWrapperAndTrailingSecondRootAreRejected() {
        assertFailure(decode("<archive-envelope>" + message() + "</archive-envelope>"), .invalidResponse)
        assertFailure(decode(message() + "<unexpected/>"), .invalidResponse)
        assertFailure(decode("text" + message()), .invalidResponse)
    }

    func testForeignStanzaAndForwardedNamespacesAreRejected() {
        assertFailure(decode(message().replacingOccurrences(of: "<message from=", with: "<message xmlns='urn:foreign' from=")), .invalidResponse)
        assertFailure(decode(message().replacingOccurrences(of: "urn:xmpp:forward:0", with: "urn:foreign")), .invalidResponse)
    }

    func testMalformedOrMissingForwardedMessageIsRejected() {
        let missing = "<message from='\(owner)'><result xmlns='urn:xmpp:mam:2' id='123'/></message>"
        assertFailure(decode(missing), .invalidResponse)
        assertFailure(decode(message().replacingOccurrences(of: "id='123'", with: "id=''")), .invalidResponse)
    }

    func testMultipleMessagesAndForeignMAMNamespaceAreRejected() {
        assertFailure(decode(message() + message() + fin()), .invalidResponse)
        assertFailure(decode(message().replacingOccurrences(of: "urn:xmpp:mam:2", with: "https://foreign.example/mam")), .invalidResponse)
    }

    func testDTDAndEntityDeclarationsAreRejected() {
        assertFailure(decode("<!DOCTYPE message [<!ENTITY secret 'value'>]>" + message()), .invalidResponse)
    }

    func testRequestRejectsUnsafeURLAndAmbiguousReservedQueryParameters() throws {
        for value in ["http://example.com/iq", "https://user:password@example.com/iq", "https://example.com/iq#fragment", "https://example.com/iq?id=old", "https://example.com/iq?by=old", "https://example.com/iq?%69d=old", "//example.com/iq", "/iq/archive/id"] {
            XCTAssertNil(PushArchiveHTTPClient.makeRequest(endpointURL: try XCTUnwrap(URL(string: value)), token: "fixture-token", id: "123", by: nil))
        }
    }

    func testHTTPClientAcceptsApplicationXMLAndUsesDiscoveredEndpoint() throws {
        let body = message()
        let received = expectation(description: "typed HTTP archive result")
        let client = try makeClient { request, stub in
            XCTAssertEqual(request.url?.path, "/custom/archive/id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            stub.respond(status: 200, body: Data(body.utf8), headers: ["Content-Type": "application/xml; charset=utf-8"])
        }
        client.fetch(id: "123") { outcome in
            self.assertMessage(outcome, id: "123")
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    func testDiagnosticsPreserveRequestHeadersAndCompleteUnmodifiedResponseBody() throws {
        let body = "\n" + message().replacingOccurrences(of: "Hello", with: "Hello &amp; привет") + "\n"
        let received = expectation(description: "diagnosed archive result")
        let finished = expectation(description: "diagnostics finish")
        let diagnostics = ArchiveHTTPDiagnostics()
        let client = try makeClient(diagnostic: { event in
            diagnostics.append(event)
            if event.contains("event=finish outcome=message") { finished.fulfill() }
        }) { request, stub in
            diagnostics.append("fixture-url=\(request.url!.absoluteString)")
            let data = Data(body.utf8)
            stub.begin(status: 200, headers: ["X-Archive-Test": "exact-header-value"])
            stub.send(data.prefix(31))
            stub.send(data.dropFirst(31))
            stub.finish()
        }
        client.fetch(id: "123", by: owner) { outcome in
            self.assertMessage(outcome, id: "123")
            XCTAssertTrue(diagnostics.events.contains { $0.contains("event=finish outcome=message") },
                          "An NSE may exit immediately after completion; transport logs must already be delivered")
            received.fulfill()
        }
        wait(for: [received, finished], timeout: 2)

        let events = diagnostics.events
        let request = try XCTUnwrap(events.first { $0.contains("event=request ") })
        let fixtureURL = try XCTUnwrap(events.first { $0.hasPrefix("fixture-url=") })
            .replacingOccurrences(of: "fixture-url=", with: "")
        XCTAssertTrue(request.contains("method=GET url=\(fixtureURL)"))
        XCTAssertTrue(request.contains("Authorization: Bearer fixture-token"))
        XCTAssertTrue(request.contains("Accept: application/xml"))
        XCTAssertTrue(request.contains("Cache-Control: no-store"))
        XCTAssertTrue(request.contains("bodyBytes=0"))
        let response = try XCTUnwrap(events.first { $0.contains("event=response ") })
        XCTAssertTrue(response.contains("status=200"))
        XCTAssertTrue(response.lowercased().contains("x-archive-test: exact-header-value"))
        let completeBody = try XCTUnwrap(events.first { $0.contains("event=response_body ") })
        XCTAssertEqual(completeBody.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), body)
        XCTAssertTrue(completeBody.contains("encoding=utf8 bytes=\(body.utf8.count)"))
        XCTAssertTrue(events.contains { $0.contains("event=parser outcome=message") })
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex { $0.contains("event=request ") }),
                          try XCTUnwrap(events.firstIndex { $0.contains("event=response ") }))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex { $0.contains("event=response_body ") }),
                          try XCTUnwrap(events.firstIndex { $0.contains("event=parser ") }))
    }

    func testDiagnosticsPreserveNonUTF8BytesAndReportParserFailure() throws {
        let data = Data([0xFF, 0xFE, 0x00, 0x81])
        let received = expectation(description: "binary response rejected")
        let finished = expectation(description: "binary diagnostics finish")
        let diagnostics = ArchiveHTTPDiagnostics()
        let client = try makeClient(diagnostic: { event in
            diagnostics.append(event)
            if event.contains("event=finish outcome=failure.invalidResponse") { finished.fulfill() }
        }) { _, stub in
            stub.respond(status: 200, body: data)
        }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .invalidResponse)
            received.fulfill()
        }
        wait(for: [received, finished], timeout: 2)
        let body = try XCTUnwrap(diagnostics.events.first { $0.contains("event=response_body ") })
        XCTAssertTrue(body.contains("encoding=base64 bytes=4"))
        XCTAssertEqual(body.components(separatedBy: "\n").last, data.base64EncodedString())
        XCTAssertTrue(diagnostics.events.contains { $0.contains("event=parser outcome=failure.invalidResponse") })
    }

    func testDiagnosticsRecordRetryAndReentrantCancellationWithoutDeadlock() throws {
        let scheduler = ArchiveHTTPControlledScheduler()
        let retryScheduled = expectation(description: "diagnosed retry")
        scheduler.onRetryScheduled = { retryScheduled.fulfill() }
        let received = expectation(description: "reentrant cancel result")
        let cancelled = expectation(description: "cancel diagnostics finish")
        let diagnostics = ArchiveHTTPDiagnostics()
        weak var cancellableClient: PushArchiveHTTPClient?
        let client = try makeClient(scheduler: scheduler, diagnostic: { event in
            diagnostics.append(event)
            if event.contains("event=retry ") { cancellableClient?.cancel() }
            if event.contains("event=finish outcome=cancelled") { cancelled.fulfill() }
        }) { _, stub in
            stub.fail(URLError(.networkConnectionLost))
        }
        cancellableClient = client
        client.fetch(id: "123") { outcome in
            guard case .cancelled = outcome else { return XCTFail("Expected cancellation from diagnostic callback") }
            received.fulfill()
        }
        wait(for: [retryScheduled, received, cancelled], timeout: 2)
        XCTAssertTrue(diagnostics.events.contains { $0.contains("event=transport_error ") })
        XCTAssertTrue(diagnostics.events.contains { $0.contains("event=cancel_requested") })
    }

    func testDiagnosticsRecordAbsoluteDeadline() throws {
        let scheduler = ArchiveHTTPControlledScheduler()
        let started = expectation(description: "diagnosed held request")
        let received = expectation(description: "diagnosed timeout result")
        let finished = expectation(description: "timeout diagnostics finish")
        let diagnostics = ArchiveHTTPDiagnostics()
        let client = try makeClient(scheduler: scheduler, diagnostic: { event in
            diagnostics.append(event)
            if event.contains("event=finish outcome=failure.timeout") { finished.fulfill() }
        }) { _, _ in started.fulfill() }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .timeout)
            received.fulfill()
        }
        wait(for: [started], timeout: 2)
        scheduler.perform(delay: 8)
        wait(for: [received, finished], timeout: 2)
        XCTAssertTrue(diagnostics.events.contains { $0.contains("event=deadline ") })
    }

    func testQueryEncodesEveryReservedCharacterAndUnicodeWithoutChangingEndpoint() throws {
        let id = "id +&?=/#%Ж"
        let by = "room+tag@example.com/ресурс"
        let request = try XCTUnwrap(PushArchiveHTTPClient.makeRequest(
            endpointURL: try XCTUnwrap(URL(string: "https://example.com/exact%2Froute?id-context=retained%2Bvalue")),
            token: "fixture-token", id: id, by: by
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/exact%2Froute")
        XCTAssertEqual(components.queryItems?.map(\.name), ["id-context", "id", "by"])
        XCTAssertEqual(components.queryItems?.map(\.value), ["retained+value", id, by])
        XCTAssertEqual(components.percentEncodedQuery, "id-context=retained%2Bvalue&id=id%20%2B%26%3F%3D%2F%23%25%D0%96&by=room%2Btag%40example.com%2F%D1%80%D0%B5%D1%81%D1%83%D1%80%D1%81")
    }

    func testOmittedByUsesTokenOwnerAndDoesNotAddAQueryParameter() throws {
        let request = try XCTUnwrap(PushArchiveHTTPClient.makeRequest(
            endpointURL: try XCTUnwrap(URL(string: "https://example.com/iq/archive/id")),
            token: "fixture-token", id: "123", by: nil
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/iq/archive/id?id=123")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testInvalidOrMissingXMLContentTypeIsRejectedWithoutRetry() throws {
        for contentType in ["text/html", "application/json", ""] {
            let received = expectation(description: "invalid MIME \(contentType)")
            let count = ArchiveHTTPLockedCounter()
            let client = try makeClient { _, stub in
                _ = count.increment()
                stub.respond(status: 200, body: Data(self.message().utf8), headers: ["Content-Type": contentType])
            }
            client.fetch(id: "123") { outcome in
                self.assertFailure(outcome, .invalidResponse)
                received.fulfill()
            }
            wait(for: [received], timeout: 2)
            XCTAssertEqual(count.value, 1)
        }
    }

    func testErrorDocumentMustUseRequestedArchiveOwnerAndConsistentStanzaNamespace() {
        let error = "<iq from='\(owner)' type='error' id='q'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
        assertFailure(decode(error.replacingOccurrences(of: owner, with: "other@example.com")), .invalidResponse)
        assertFailure(decode(error.replacingOccurrences(of: "<error type=", with: "<error xmlns='jabber:client' type=")), .invalidResponse)
        guard case .xmppError(let condition) = decode(error.replacingOccurrences(of: "<iq from=", with: "<iq xmlns='jabber:client' from=")) else {
            return XCTFail("Expected namespace-consistent XMPP error document")
        }
        XCTAssertEqual(condition, "item-not-found")
    }

    func testHTTPClientRejectsLegacySequenceWithoutCorrelatedFinalMetadata() throws {
        let received = expectation(description: "uncorrelated legacy final IQ rejection")
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient { _, stub in
            _ = count.increment()
            stub.respond(status: 200, body: Data((self.message() + self.fin()).utf8))
        }
        client.fetch(id: "123") { outcome in
            self.assertFailure(outcome, .invalidResponse)
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 1)
    }

    func testHTTPClientAcceptsCorrelatedServerMAMSequenceAcrossChunks() throws {
        let body = Data((serverMessage() + serverFinalIQ()).utf8)
        let received = expectation(description: "chunked server MAM sequence")
        received.assertForOverFulfill = true
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient { _, stub in
            XCTAssertEqual(count.increment(), 1)
            stub.begin(status: 200, headers: ["Content-Length": String(body.count)])
            // Split XML tags and stanza boundaries to verify transport buffering.
            for offset in stride(from: 0, to: body.count, by: 7) {
                stub.send(body.subdata(in: offset..<min(offset + 7, body.count)))
            }
            stub.finish()
        }
        client.fetch(id: "123") { outcome in
            self.assertMessage(outcome, id: "123")
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 1)
    }

    func testHTTPClientAcceptsServerTextXMLMAMSequence() throws {
        let body = Data((serverMessage() + serverFinalIQ()).utf8)
        let received = expectation(description: "deployed server text/xml MAM response")
        received.assertForOverFulfill = true
        let client = try makeClient { _, stub in
            stub.respond(status: 200, body: body, headers: ["Content-Type": "text/xml; charset=utf-8"])
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

    func testTransientNetworkFailureRetriesSameEndpointAndCanSucceed() throws {
        let scheduler = ArchiveHTTPControlledScheduler()
        let retryScheduled = expectation(description: "network retry scheduled")
        scheduler.onRetryScheduled = { retryScheduled.fulfill() }
        let received = expectation(description: "retry success")
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient(scheduler: scheduler) { request, stub in
            XCTAssertEqual(request.url?.path, "/custom/archive/id")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["id", "by"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            if count.increment() == 1 { stub.fail(URLError(.networkConnectionLost)) }
            else { stub.respond(status: 200, body: Data(self.message().utf8)) }
        }
        client.fetch(id: "123", by: owner) { outcome in
            self.assertMessage(outcome, id: "123")
            received.fulfill()
        }
        wait(for: [retryScheduled], timeout: 2)
        scheduler.perform(delay: 0.2)
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 2)
    }

    func testExplicitArchiveOwnerIsUsedToValidateResponse() throws {
        let received = expectation(description: "selected archive owner")
        let archive = "room@example.com"
        let client = try makeClient { request, stub in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "by" })?.value, archive)
            stub.respond(status: 200, body: Data(self.message(from: archive).utf8))
        }
        client.fetch(id: "123", by: archive) { outcome in
            self.assertMessage(outcome, id: "123")
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
    }

    func testCancellationDuringRequestCompletesOnceAndDoesNotRetry() throws {
        let started = expectation(description: "held request")
        let received = expectation(description: "in-flight cancellation")
        received.assertForOverFulfill = true
        let count = ArchiveHTTPLockedCounter()
        let client = try makeClient { _, _ in
            _ = count.increment()
            started.fulfill()
        }
        client.fetch(id: "123") { outcome in
            guard case .cancelled = outcome else { return XCTFail("Expected cancellation") }
            received.fulfill()
        }
        wait(for: [started], timeout: 2)
        client.cancel()
        client.cancel()
        wait(for: [received], timeout: 2)
        XCTAssertEqual(count.value, 1)
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
        diagnostic: ((String) -> Void)? = nil,
        handler: @escaping ArchiveHTTPURLProtocol.Handler
    ) throws -> PushArchiveHTTPClient {
        let host = "\(UUID().uuidString.lowercased()).http-archive-tests.invalid"
        fixtureHosts.append(host)
        ArchiveHTTPURLProtocol.install(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveHTTPURLProtocol.self]
        return try XCTUnwrap(PushArchiveHTTPClient(
            endpointURL: try XCTUnwrap(URL(string: "https://\(host)/custom/archive/id")),
            token: "fixture-token", archiveOwner: owner,
            configuration: configuration,
            maximumResponseSize: maximumResponseSize,
            scheduler: scheduler.map { controlled in { delay, work in controlled.schedule(delay: delay, work: work) } }
                ?? PushArchiveHTTPClient.liveScheduler,
            diagnostic: diagnostic
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

    /// Sanitized shape observed from the deployed by-id endpoint on the iPad.
    private func serverMessage() -> String {
        message().replacingOccurrences(of: "<message from=", with: "<message xmlns='jabber:client' from=")
    }

    private func serverFinalIQ() -> String {
        """
        <iq xmlns='jabber:client' from='\(owner)' to='\(owner)/query-1' type='result' id='query-1'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='query-1'>
            <set xmlns='http://jabber.org/protocol/rsm'><first>123</first><last>123</last></set>
          </fin>
        </iq>
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

private final class ArchiveHTTPDiagnostics {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
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
        let fields = ["Content-Type": "application/xml"].merging(headers) { _, supplied in supplied }
        guard active, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else { return }
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

    func fail(_ error: Error) {
        guard active else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    func respond(status: Int, body: Data, headers: [String: String] = [:]) {
        begin(status: status, headers: headers)
        send(body)
        finish()
    }
}
