import Foundation
import XCTest
import XMPPFramework
import CryptoSwift
@testable import xabber

final class PushPipelineIntegrationTests: XCTestCase {
    private final class Stream: XMPPStream {
        var sent: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { sent.append(element) }
    }

    func testAcknowledgedRegistrationSharedBinaryKeyHTTPAndExactMessageRoute() throws {
        let owner = "romeo@example.invalid"
        let node = "pipeline-\(UUID().uuidString)"
        let manager = PushNotificationsManager(withOwner: owner)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager.tokenInvalidationStore = PushTokenInvalidationStore(directory: directory)
        defer {
            manager.clearSession()
            PushNotificationsManager.removeDefaultsForPush(target: node, jid: owner)
            try? FileManager.default.removeItem(at: directory)
        }
        manager.node = node
        manager.service = "push.example.invalid"
        manager.payloadModeProvider = { .summary }
        let stream = Stream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")
        manager.awaitCustomPushSupport()
        manager.setCustomPushSupport(true, xmppStream: stream)
        manager.enable(xmppStream: stream) { XCTAssertTrue($0) }
        func requestID(_ child: String, namespace: String) throws -> String {
            try XCTUnwrap(stream.sent.last(where: {
                $0.element(forName: child, xmlns: namespace) != nil
            })?.attributeStringValue(forName: "id"))
        }
        func result(_ id: String, body: String) throws -> XMPPIQ {
            let document = try DDXMLDocument(xmlString: "<iq type='result' id='\(id)' from='example.invalid' to='\(owner)/ios'>\(body)</iq>", options: 0)
            return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
        }
        XCTAssertTrue(manager.read(withIQ: try result(requestID("enable", namespace: manager.getPrimaryNamespace()), body: "")))
        XCTAssertTrue(manager.enabled)
        XCTAssertFalse(manager.httpPreviewReady)
        let httpNamespace = "https://xabber.com/protocol/http-iq"
        XCTAssertTrue(manager.read(withIQ: try result(requestID("endpoints", namespace: httpNamespace), body: """
        <endpoints xmlns='\(httpNamespace)'><protocol var='urn:xmpp:mam:2'><endpoint name='by-id' url='https://archive.pipeline.invalid/custom/archive/by-id?deployment=ios'/></protocol></endpoints>
        """)))
        XCTAssertTrue(manager.read(withIQ: try result(requestID("token", namespace: httpNamespace), body: """
        <token xmlns='\(httpNamespace)'><scope>urn:xmpp:mam:2</scope><ttl>3600</ttl><expires>2100-01-01T00:00:00Z</expires><value>\(PipelineArchiveProtocol.token)</value></token>
        """)))
        XCTAssertTrue(manager.httpPreviewReady)
        let record = try CredentialsManager.staticGetPushCredentials(for: node)
        let key = try XCTUnwrap(record.keyBytes)
        XCTAssertEqual(key.count, 32)
        XCTAssertTrue(manager.enabled)

        let summary = "<stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.invalid' id='123'/>"
        let iv = Array(repeating: UInt8(9), count: 16)
        var plaintext = Array(summary.utf8)
        plaintext += Array(repeating: 0, count: 16 - plaintext.count % 16)
        let ciphertext = try AES(key: key, blockMode: CBC(iv: iv), padding: .noPadding).encrypt(plaintext)
        let envelope = try XCTUnwrap(PushPayloadEnvelope("""
        <encrypted xmlns='https://xabber.com/protocol/push' iv-length='16'>\(Data(iv + ciphertext).base64EncodedString())</encrypted>
        <x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE'><value>https://xabber.com/protocol/push#info</value></field><field var='type'><value>invite</value></field></x>
        """))
        guard case .message(let identifier)? = envelope.event(key: key) else {
            return XCTFail("The decrypted summary owns HTTP dispatch")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PipelineArchiveProtocol.self]
        let grant = try XCTUnwrap(record.httpArchive)
        let client = try XCTUnwrap(PushArchiveHTTPClient(endpointURL: try XCTUnwrap(URL(string: grant.endpoint)),
            token: grant.token, archiveOwner: record.jid, configuration: configuration))
        let delivered = expectation(description: "Validated archive preview")
        client.fetch(id: identifier.id, by: identifier.by) { outcome in
            guard case .message(let message) = outcome,
                  let preview = PushNotificationArchiveParser.parseHTTPArchivedMessage(message, owner: record.jid) else {
                delivered.fulfill()
                return XCTFail("Expected real transport plus shared preview parser")
            }
            XCTAssertEqual(preview.route.kind, .message)
            XCTAssertEqual(preview.route.owner, record.jid)
            XCTAssertEqual(preview.route.routeJid, "juliet@example.invalid")
            XCTAssertEqual(preview.route.stanzaId, "123")
            XCTAssertEqual(preview.route.messageId, "message-123")
            XCTAssertEqual(preview.body, "Archive preview")
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 3)
    }
}

private final class PipelineArchiveProtocol: URLProtocol {
    static let token: String = {
        let payload = Data("{\"iss\":\"example.invalid\",\"sub\":\"romeo@example.invalid/device-42\",\"scope\":[\"urn:xmpp:mam:2\"],\"exp\":4102444800}".utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2lnbmF0dXJl"
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "archive.pipeline.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(url.path, "/custom/archive/by-id")
        XCTAssertEqual(query?.first(where: { $0.name == "deployment" })?.value, "ios")
        XCTAssertEqual(query?.first(where: { $0.name == "by" })?.value, "romeo@example.invalid")
        XCTAssertEqual(query?.first(where: { $0.name == "id" })?.value, "123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token)")
        let xml = """
        <message from='romeo@example.invalid'><result xmlns='urn:xmpp:mam:2' id='123' queryid='q'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' type='chat' from='juliet@example.invalid/mobile' to='romeo@example.invalid' id='message-123'><body>Archive preview</body><stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.invalid' id='123'/></message></forwarded></result></message>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/xml; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
