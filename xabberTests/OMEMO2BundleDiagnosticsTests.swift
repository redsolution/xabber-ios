import Foundation
import XMPPFramework
import XCTest
@testable import xabber

final class OMEMO2BundleDiagnosticsTests: XCTestCase {
    private let jid = "bundle-peer@example.test"
    private let namespace = OMEMO2BundleCodec.namespace

    func testRejectedSenderlessLegacyBundleLogsTheExactOriginalIQ() throws {
        let source = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='bundle-request-7' trace='original-attribute'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(namespace):bundles'>\(bundleItemXML())</items><unknown trace='keep-this-sibling'>original-sibling</unknown></pubsub><diagnostic xmlns='urn:example:debug'>keep-original-payload</diagnostic></iq>")
        let original = source.xmlString
        let item = try XCTUnwrap(source.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item"))
        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item))

        let record = OMEMO2BundleDiagnostics.record(
            stanza: source, jid: jid, error: OMEMO2BundleCodec.Error.invalidBase64,
            includeRawXML: true
        )

        XCTAssertEqual(record.rawXML, original)
        XCTAssertEqual(source.xmlString, original)
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("original-attribute"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("keep-this-sibling"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("time-signature"))
        XCTAssertTrue(record.summary.contains("rejected"))
    }

    func testBundleHeadlineLogsTheExactOriginalMessage() throws {
        let source = try XMPPMessage(xmlString: "<message xmlns='jabber:client' type='headline' from='\(jid)/resource' id='bundle-event-7' original='yes'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='\(namespace):bundles'>\(bundleItemXML())</items><extra original='preserved'>event-sibling</extra></event><body>original body</body></message>")
        let original = source.xmlString

        let record = OMEMO2BundleDiagnostics.record(
            stanza: source, jid: jid, error: OMEMO2BundleCodec.Error.invalidBase64,
            includeRawXML: true
        )

        XCTAssertEqual(record.rawXML, original)
        XCTAssertEqual(source.xmlString, original)
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("original body"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("event-sibling"))
    }

    func testOwnBundlePublicationLogsTheExactOutgoingIQIncludingOptions() throws {
        let source = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='set' id='own-bundle-publication'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='\(namespace):bundles'>\(bundleItemXML(keyLength: 32))</publish><publish-options><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#publish-options</value></field><field var='pubsub#access_model'><value>open</value></field><unknown original='preserved'/></x></publish-options></pubsub></iq>")
        let original = source.xmlString

        let record = OMEMO2BundleDiagnostics.record(stanza: source, jid: jid, includeRawXML: true)

        XCTAssertEqual(record.rawXML, original)
        XCTAssertEqual(source.xmlString, original)
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("publish-options"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("pubsub#access_model"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("time-signature"))
    }

    func testPrefixedQNameAndBase64WhitespaceArePreservedExactly() throws {
        let encoded = publicKey(length: 33)
        let whitespaceKey = " \n\t\(encoded.prefix(12))\r\n\(encoded.dropFirst(12)) "
        let source = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='prefixed-bundle'><p:pubsub xmlns:p='http://jabber.org/protocol/pubsub'><p:items node='\(namespace):bundles'><p:item id='7'><o:bundle xmlns:o='\(namespace)' original='attribute'><o:ik>\(whitespaceKey)</o:ik><o:spk id='9'>\(encoded)</o:spk><o:spks>\(signature())</o:spks><o:prekeys><o:pk id='10'>\(encoded)</o:pk></o:prekeys><o:unknown original='preserved'/></o:bundle></p:item></p:items></p:pubsub></iq>")
        let original = source.xmlString

        let record = OMEMO2BundleDiagnostics.record(
            stanza: source, jid: jid, error: OMEMO2BundleCodec.Error.invalidBase64,
            includeRawXML: true
        )

        XCTAssertEqual(record.rawXML, original)
        XCTAssertEqual(source.xmlString, original)
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("o:bundle"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains("p:pubsub"))
        XCTAssertTrue(try XCTUnwrap(record.rawXML).contains(" \n\t"))
    }

    func testAllThousandPreKeysRemainInTheExactOriginalStanza() throws {
        let source = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='large-bundle'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(namespace):bundles'>\(bundleItemXML(preKeyCount: 1_000))</items></pubsub></iq>")
        let original = source.xmlString
        let inputKeys = try XCTUnwrap(source.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item")?.element(forName: "bundle")?.element(forName: "prekeys"))
        XCTAssertEqual(inputKeys.elements(forName: "pk").count, 1_000)

        let record = OMEMO2BundleDiagnostics.record(
            stanza: source, jid: jid, error: OMEMO2BundleCodec.Error.invalidBase64,
            includeRawXML: true
        )

        XCTAssertEqual(record.rawXML, original)
        XCTAssertEqual(source.xmlString, original)
        XCTAssertFalse(record.summary.contains("truncated"))
        let logged = try DDXMLElement(xmlString: XCTUnwrap(record.rawXML))
        let loggedKeys = try XCTUnwrap(logged.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item")?.element(forName: "bundle")?.element(forName: "prekeys"))
        XCTAssertEqual(loggedKeys.elements(forName: "pk").count, 1_000)
    }

    func testExplicitlyDisabledXMLLoggingReturnsOnlyTheSummary() throws {
        let source = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='disabled-bundle'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(namespace):bundles'>\(bundleItemXML())</items></pubsub></iq>")
        let original = source.xmlString

        let record = OMEMO2BundleDiagnostics.record(
            stanza: source, jid: jid, error: OMEMO2BundleCodec.Error.invalidBase64,
            includeRawXML: false
        )

        XCTAssertNil(record.rawXML)
        XCTAssertFalse(record.summary.isEmpty)
        XCTAssertEqual(source.xmlString, original)
    }

    func testDefaultXMLLoggingIsEnabledOnlyInDebugBuilds() throws {
        let source = try XMPPIQ(xmlString: "<iq xmlns='jabber:client' type='result' id='debug-bundle'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(namespace):bundles'>\(bundleItemXML())</items></pubsub></iq>")
        let original = source.xmlString

        let record = OMEMO2BundleDiagnostics.record(stanza: source, jid: jid)

        #if DEBUG
        XCTAssertTrue(OMEMO2BundleDiagnostics.debugXMLLoggingEnabled)
        XCTAssertEqual(record.rawXML, original)
        #else
        XCTAssertFalse(OMEMO2BundleDiagnostics.debugXMLLoggingEnabled)
        XCTAssertNil(record.rawXML)
        #endif
        XCTAssertEqual(source.xmlString, original)
    }

    private func bundleItemXML(keyLength: Int = 33, preKeyCount: Int = 1) -> String {
        let keys = (0..<preKeyCount).map { index in
            "<pk id='\(index + 10)' original='attribute'>\(publicKey(length: keyLength))</pk>"
        }.joined()
        return "<item id='7' original='attribute'><bundle xmlns='\(namespace)' original='attribute'><ik>\(publicKey(length: keyLength))</ik><spk id='9' original='attribute'>\(publicKey(length: keyLength))</spk><spks>\(signature())</spks><prekeys>\(keys)</prekeys><time-signature xmlns='urn:xabber:signature:0' original='attribute'><certificate>original certificate</certificate></time-signature><unknown original='preserved'>original value</unknown></bundle></item>"
    }

    private func publicKey(length: Int) -> String {
        (Data([5]) + Data(repeating: 42, count: length - 1)).base64EncodedString()
    }

    private func signature() -> String { Data(repeating: 17, count: 64).base64EncodedString() }
}
