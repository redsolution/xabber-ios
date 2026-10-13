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
        defer { CredentialsManager.shared.removePushCredentials(for: node) }
        let manager = PushNotificationsManager(withOwner: owner)
        manager.configure(node: node, service: "push.example.invalid")
        let stream = Stream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")
        manager.awaitCustomPushSupport()
        manager.setCustomPushSupport(true, xmppStream: stream)
        manager.enable(xmppStream: stream) { XCTAssertTrue($0) }
        let requestID = try XCTUnwrap(stream.sent.last?.attributeStringValue(forName: "id"))
        // This is the server's actual optional grant form on successful push enable.
        let response = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(requestID)' from='\(owner)'>
          <x xmlns='jabber:x:data' type='result'>
            <field var='FORM_TYPE' type='hidden'><value>https://xabber.com/protocol/push</value></field>
            <field var='url'><value>https://archive.pipeline.invalid/iq</value></field>
            <field var='jwt'><value>fixture-jwt</value></field>
          </x>
        </iq>
        """, options: 0)
        XCTAssertTrue(manager.read(withIQ: XMPPIQ(from: try XCTUnwrap(response.rootElement()))))
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
        let client = try XCTUnwrap(PushArchiveHTTPClient(baseURL: try XCTUnwrap(URL(string: record.service)),
            token: record.jwt, archiveOwner: record.jid, configuration: configuration))
        let delivered = expectation(description: "Validated archive preview")
        client.fetch(id: identifier.id) { outcome in
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
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "archive.pipeline.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(url.path, "/iq/archive")
        XCTAssertEqual(query?.first(where: { $0.name == "id" })?.value, "123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-jwt")
        let xml = """
        <message from='romeo@example.invalid'><result xmlns='urn:xmpp:mam:2' id='123' queryid='q'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' type='chat' from='juliet@example.invalid/mobile' to='romeo@example.invalid' id='message-123'><body>Archive preview</body></message></forwarded></result></message>
        <iq from='romeo@example.invalid' type='result' id='q'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
