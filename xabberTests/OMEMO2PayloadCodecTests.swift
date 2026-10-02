import CryptoKit
import XCTest
import XMPPFramework
@testable import xabber

final class OMEMO2PayloadCodecTests: XCTestCase {
    private let xml = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>hello</body></content><rpad>pad</rpad><from jid='alice@example.com'/><to jid='bob@example.com'/></envelope>"

    // Independent fixture: Python RFC5869 HMAC/HKDF + OpenSSL AES-CBC.
    func testPayloadMatchesIndependentHKDFCBCMAC16Fixture() throws {
        let expected = Data(base64Encoded: "6dSO/ouvpV4xQv+FlKj3IJr7pGv2i1KYlfKFPgf3Bx+EId8KrZdSvpJ1K0lK52P5CVZ59FL+4WUsmYvmWo+JUSA3QtSZUUy4BzkllY48EO5NE99RFfz4DaQS34n46DEFH6TYnPf5nPBg0dUOdLccJDXEHTCGp5LIK9wYPw3Tyok35Q8ow72yDneFeAnF9YRIzUXV8h0x5/d2Ro2XI/d7Df5XKbSb6GRPWWtHud6YO8l0MZ/Dy3i/kbD9KIFmIQUe")!
        let sealed = try Omemo2PayloadCodec.seal(xml, randomBytes: { _ in Data(0..<32) })
        XCTAssertEqual(sealed.ciphertext, expected)
        XCTAssertEqual(sealed.keyAndMAC.suffix(16), Data(base64Encoded: "n1fcJGJGP2ZQ7nLsVLjNHA==")!)
    }

    func testPayloadRoundTripHasExactlyKey32AndMAC16() throws {
        let sealed = try Omemo2PayloadCodec.seal(xml, randomBytes: { Data(repeating: 1, count: $0) })
        XCTAssertEqual(sealed.keyAndMAC.count, 48)
        XCTAssertEqual(sealed.keyAndMAC.prefix(32), Data(repeating: 1, count: 32))
        XCTAssertTrue(sealed.ciphertext.count.isMultiple(of: 16))
        let opened = try XCTUnwrap(try Omemo2PayloadCodec.open(sealed.ciphertext, keyAndMAC: sealed.keyAndMAC,
                                                            expectedFrom: "alice@example.com", expectedTo: "bob@example.com"))
        XCTAssertEqual(opened.element(forName: "content")?.element(forName: "body")?.stringValue, "hello")
    }

    func testRandomnessFailureAndWrongRandomLengthDoNotProduceCiphertext() throws {
        XCTAssertThrowsError(try Omemo2PayloadCodec.seal(xml, randomBytes: { _ in throw OmemoManagerError.encryptionFailed }))
        XCTAssertThrowsError(try Omemo2PayloadCodec.seal(xml, randomBytes: { _ in Data(repeating: 1, count: 31) }))
    }

    func testCorruptedPayloadOrMACIsRejected() throws {
        let sealed = try Omemo2PayloadCodec.seal(xml)
        var payload = sealed.ciphertext; payload[0] ^= 1
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(payload, keyAndMAC: sealed.keyAndMAC, expectedFrom: nil, expectedTo: nil))
        var keyAndMAC = sealed.keyAndMAC; keyAndMAC[47] ^= 1
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(sealed.ciphertext, keyAndMAC: keyAndMAC, expectedFrom: nil, expectedTo: nil))
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(sealed.ciphertext, keyAndMAC: sealed.keyAndMAC + Data([0]), expectedFrom: nil, expectedTo: nil))
    }

    func testOnlyAbsentPayloadAndZero32RepresentControl() throws {
        XCTAssertNil(try Omemo2PayloadCodec.open(nil, keyAndMAC: Data(repeating: 0, count: 32), expectedFrom: nil, expectedTo: nil))
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(Data(), keyAndMAC: Data(repeating: 0, count: 32), expectedFrom: nil, expectedTo: nil))
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(nil, keyAndMAC: Data(repeating: 1, count: 32), expectedFrom: nil, expectedTo: nil))
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(nil, keyAndMAC: Data(repeating: 0, count: 48), expectedFrom: nil, expectedTo: nil))
    }

    func testSCEBindingAndStructureAreVerifiedAfterMAC() throws {
        let sealed = try Omemo2PayloadCodec.seal(xml)
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(sealed.ciphertext, keyAndMAC: sealed.keyAndMAC, expectedFrom: "mallory@example.com", expectedTo: "bob@example.com"))
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(sealed.ciphertext, keyAndMAC: sealed.keyAndMAC, expectedFrom: "alice@example.com", expectedTo: "mallory@example.com"))
        for malformed in ["<envelope xmlns='wrong'><content/><rpad/></envelope>", "<envelope xmlns='urn:xmpp:sce:1'><content/></envelope>", "<envelope xmlns='urn:xmpp:sce:1'><content/><content/><rpad/></envelope>", "<broken"] {
            let packet = try Omemo2PayloadCodec.seal(malformed)
            XCTAssertThrowsError(try Omemo2PayloadCodec.open(packet.ciphertext, keyAndMAC: packet.keyAndMAC, expectedFrom: nil, expectedTo: nil))
        }
    }

    func testOptionalAffixesAndHistoricTimeRemainInteroperable() throws {
        let minimal = "<envelope xmlns='urn:xmpp:sce:1'><content/><rpad/><time stamp='2004-01-25T06:05:00Z'/></envelope>"
        let packet = try Omemo2PayloadCodec.seal(minimal)
        XCTAssertNotNil(try Omemo2PayloadCodec.open(packet.ciphertext, keyAndMAC: packet.keyAndMAC, expectedFrom: "alice@example.com", expectedTo: "bob@example.com"))
        let malformed = try Omemo2PayloadCodec.seal(minimal.replacingOccurrences(of: "2004-01-25T06:05:00Z", with: "not-a-date"))
        XCTAssertThrowsError(try Omemo2PayloadCodec.open(malformed.ciphertext, keyAndMAC: malformed.keyAndMAC, expectedFrom: nil, expectedTo: nil))
    }

    func testPrefixedSCEElementsHaveTheSameNamespaceMeaning() throws {
        let prefixed = "<s:envelope xmlns:s='urn:xmpp:sce:1'><s:content><body xmlns='jabber:client'>prefixed</body></s:content><s:rpad/><s:from jid='alice@example.com'/><s:to jid='bob@example.com'/></s:envelope>"
        let packet = try Omemo2PayloadCodec.seal(prefixed)

        let opened = try XCTUnwrap(Omemo2PayloadCodec.open(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                                  expectedFrom: "alice@example.com", expectedTo: "bob@example.com"))

        XCTAssertEqual(opened.localName, "envelope")
        XCTAssertEqual(opened.uri, "urn:xmpp:sce:1")
        let content = try XCTUnwrap((opened.children ?? []).compactMap { $0 as? DDXMLElement }.first { $0.localName == "content" })
        XCTAssertEqual(content.element(forName: "body", xmlns: "jabber:client")?.stringValue, "prefixed")
    }

    func testGroupChatSCEWithoutProtectedRecipientIsRejected() throws {
        let missingTo = "<envelope xmlns='urn:xmpp:sce:1'><content/><rpad/><from jid='alice@example.com'/></envelope>"
        let packet = try Omemo2PayloadCodec.seal(missingTo)

        XCTAssertThrowsError(try Omemo2PayloadCodec.open(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                             expectedFrom: "alice@example.com", expectedTo: "room@conference.example.com", requireTo: true))
    }

    func testGroupChatSCEWithMatchingProtectedRecipientIsAccepted() throws {
        let group = xml.replacingOccurrences(of: "bob@example.com", with: "room@conference.example.com")
        let packet = try Omemo2PayloadCodec.seal(group)

        XCTAssertNotNil(try Omemo2PayloadCodec.open(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                        expectedFrom: "alice@example.com", expectedTo: "room@conference.example.com", requireTo: true))
    }

    func testForbiddenServerElementsAreRemovedFromDecryptedContent() throws {
        let message = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>hello</body><store xmlns='urn:xmpp:hints'/><stanza-id xmlns='urn:xmpp:sid:0' id='forged'/><addresses xmlns='http://jabber.org/protocol/address'/></content><rpad/></envelope>"
        let packet = try Omemo2PayloadCodec.seal(message)
        let opened = try XCTUnwrap(try Omemo2PayloadCodec.open(packet.ciphertext, keyAndMAC: packet.keyAndMAC, expectedFrom: nil, expectedTo: nil))
        XCTAssertEqual(opened.element(forName: "content")?.children?.count, 1)
    }

    func testBase64AllowsOnlyXMLWhitespaceAroundValidEncoding() throws {
        XCTAssertEqual(try Omemo2PayloadCodec.decodeBase64(" AQ\nID\t "), Data([1, 2, 3]))
        for malformed in ["AQID!", "AA==garbage", "", "😀"] {
            XCTAssertThrowsError(try Omemo2PayloadCodec.decodeBase64(malformed))
        }
    }
}
