import XCTest
import XMPPFramework
@testable import xabber

final class PrivacyProxyDiscoveryTests: XCTestCase {
    private let owner = "alice@example.com"
    private let endpoint = URL(string: "https://proxy.example.net/api/v1/")!

    func testRootDiscoDiscoversHTTPSProxyAndPreservesBasePath() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = makeStream()
        XCTAssertEqual(disco.privacyProxyDiscovery, .unknown)

        let id = try requestRootDisco(disco, on: stream)
        let result = try makeResult(id: id, body: proxyForm(value: " https://proxy.example.net/api/v1 "))

        XCTAssertTrue(disco.read(withIQ: result))
        XCTAssertEqual(disco.privacyProxyDiscovery, .advertised(endpoint))
    }

    func testAuthoritativeRefreshReplacesAndThenRemovesEndpoint() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = makeStream()

        let firstID = try requestRootDisco(disco, on: stream)
        let firstReply = try makeResult(id: firstID, body: proxyForm(value: endpoint.absoluteString))
        XCTAssertTrue(disco.read(withIQ: firstReply))

        let secondID = try requestRootDisco(disco, on: stream)
        let newEndpoint = URL(string: "https://replacement.example.net/")!
        XCTAssertTrue(disco.read(withIQ: try makeResult(id: secondID, body: proxyForm(value: newEndpoint.absoluteString))))
        XCTAssertFalse(disco.read(withIQ: firstReply))
        XCTAssertEqual(disco.privacyProxyDiscovery, .advertised(newEndpoint))

        let thirdID = try requestRootDisco(disco, on: stream)
        XCTAssertTrue(disco.read(withIQ: try makeResult(id: thirdID)))
        XCTAssertEqual(disco.privacyProxyDiscovery, .notAdvertised)
    }

    func testFeatureFlagWrongFormAndUnsafeURLsDoNotDiscoverProxy() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = makeStream()
        let bodies = [
            "<feature var='urn:xabber:http:url:privacyproxy'/>",
            proxyForm(value: endpoint.absoluteString, formType: "urn:xabber:other"),
            proxyForm(value: endpoint.absoluteString, namespace: "urn:xabber:other"),
            proxyForm(value: ""),
            proxyForm(value: "proxy.example.net/path"),
            proxyForm(value: "http://proxy.example.net/"),
            proxyForm(value: "https://alice:secret@proxy.example.net/"),
            proxyForm(value: "https://proxy.example.net/path?key=value"),
            proxyForm(value: "https://proxy.example.net/path#fragment"),
        ]

        for body in bodies {
            let id = try requestRootDisco(disco, on: stream)
            XCTAssertTrue(disco.read(withIQ: try makeResult(id: id, body: body)), body)
            XCTAssertEqual(disco.privacyProxyDiscovery, .notAdvertised, body)
        }
    }

    func testComponentAndNodeCannotConsumePendingRootDiscovery() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = makeStream()
        let id = try requestRootDisco(disco, on: stream)
        let body = proxyForm(value: endpoint.absoluteString)

        XCTAssertFalse(disco.read(withIQ: try makeResult(id: id, from: "component.example.com", body: body)))
        XCTAssertFalse(disco.read(withIQ: try makeResult(id: id, from: "example.com/resource", body: body)))
        XCTAssertFalse(disco.read(withIQ: try makeResult(id: id, node: "component", body: body)))
        XCTAssertEqual(disco.privacyProxyDiscovery, .unknown)
        XCTAssertTrue(disco.read(withIQ: try makeResult(id: id, body: body)))
        XCTAssertEqual(disco.privacyProxyDiscovery, .advertised(endpoint))
    }

    func testBareJIDAndTrackedComponentRepliesCannotAdvertiseProxy() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = makeStream()
        let body = proxyForm(value: endpoint.absoluteString)

        XCTAssertTrue(disco.requestFeatures(stream))
        let bareID = try XCTUnwrap(stream.lastIQ?.elementID)
        XCTAssertTrue(disco.read(withIQ: try makeResult(id: bareID, from: owner, body: body)))

        disco.checkItem(stream, in: "component.example.com", node: nil)
        let componentID = try XCTUnwrap(stream.lastIQ?.elementID)
        XCTAssertTrue(disco.read(withIQ: try makeResult(id: componentID, from: "component.example.com", body: body)))
        XCTAssertEqual(disco.privacyProxyDiscovery, .unknown)
    }

    func testErrorAndDisconnectKeepLastConfirmedAdvertisement() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = makeStream()
        let id = try requestRootDisco(disco, on: stream)
        XCTAssertTrue(disco.read(withIQ: try makeResult(id: id, body: proxyForm(value: endpoint.absoluteString))))

        let errorID = try requestRootDisco(disco, on: stream)
        let error = XMPPIQ(iqType: .error, to: nil, elementID: errorID)
        error.addAttribute(withName: "from", stringValue: "example.com")
        XCTAssertTrue(disco.read(withIQ: error))
        XCTAssertEqual(disco.privacyProxyDiscovery, .advertised(endpoint))

        let interruptedID = try requestRootDisco(disco, on: stream)
        disco.clearSession()
        XCTAssertFalse(disco.read(withIQ: try makeResult(id: interruptedID)))
        XCTAssertEqual(disco.privacyProxyDiscovery, .advertised(endpoint))
    }

    func testAdvertisementIsIsolatedPerAccount() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let otherOwner = "bob@example.com"
        let otherDisco = ServerDiscoManager(withOwner: otherOwner)
        let stream = makeStream()
        let otherStream = makeStream(owner: otherOwner)

        let id = try requestRootDisco(disco, on: stream)
        let otherID = try requestRootDisco(otherDisco, on: otherStream)
        let reply = try makeResult(id: id, body: proxyForm(value: endpoint.absoluteString))
        XCTAssertFalse(otherDisco.read(withIQ: reply))
        XCTAssertTrue(disco.read(withIQ: reply))
        XCTAssertTrue(otherDisco.read(withIQ: try makeResult(id: otherID)))
        XCTAssertEqual(disco.privacyProxyDiscovery, .advertised(endpoint))
        XCTAssertEqual(otherDisco.privacyProxyDiscovery, .notAdvertised)
    }

    private func makeStream(owner: String? = nil) -> PrivacyProxyDiscoCapturingStream {
        let stream = PrivacyProxyDiscoCapturingStream()
        stream.myJID = XMPPJID(string: owner ?? self.owner, resource: "ios")
        return stream
    }

    private func requestRootDisco(_ disco: ServerDiscoManager, on stream: PrivacyProxyDiscoCapturingStream) throws -> String {
        stream.lastIQ = nil
        disco.requestServerFeatures(stream)
        let iq = try XCTUnwrap(stream.lastIQ)
        XCTAssertEqual(iq.to?.full, "example.com")
        return try XCTUnwrap(iq.elementID)
    }

    private func proxyForm(value: String, formType: String = "urn:xabber:http:url", namespace: String = "jabber:x:data") -> String {
        """
        <x xmlns='\(namespace)' type='result'>
          <field var='FORM_TYPE' type='hidden'><value>\(formType)</value></field>
          <field var='urn:xabber:http:url:privacyproxy' type='text-single'><value>\(value)</value></field>
        </x>
        """
    }

    private func makeResult(id: String, from: String = "example.com", node: String? = nil, body: String = "") throws -> XMPPIQ {
        let nodeAttribute = node.map { " node='\($0)'" } ?? ""
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(id)' from='\(from)'>
          <query xmlns='http://jabber.org/protocol/disco#info'\(nodeAttribute)>
            \(body)
          </query>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}

private final class PrivacyProxyDiscoCapturingStream: XMPPStream {
    var lastIQ: XMPPIQ?

    override func send(_ element: DDXMLElement) {
        lastIQ = element as? XMPPIQ
    }
}
