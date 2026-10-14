import XCTest
import XMPPFramework
import XabberCryptoSwift
@testable import xabber

final class OMEMO2NativePayloadBoundaryTests: XCTestCase {
    private let sender = "sender@example.test"
    private let recipient = "recipient@example.test"

    func testMaximumUTF8PayloadRoundTripsThroughNativeCipherAndSCEValidation() throws {
        let prefix = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>"
        let suffix = "</body></content><rpad>p</rpad><from jid='\(sender)'/><to jid='\(recipient)'/></envelope>"
        let limit = OMEMOPayloadCipher.maximumPlaintextByteCount
        let bodyBytes = limit - prefix.utf8.count - suffix.utf8.count
        let body = String(repeating: "🌐", count: bodyBytes / 4) + String(repeating: "a", count: bodyBytes % 4)
        let xml = prefix + body + suffix
        XCTAssertEqual(xml.utf8.count, limit)

        let sealed = try Omemo2PayloadCodec.seal(xml)
        let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(sealed.ciphertext,
            keyAndMAC: sealed.keyAndMAC, expectedFrom: sender, expectedTo: recipient, requireTo: true))

        XCTAssertEqual(sealed.ciphertext.count, OMEMOPayloadCipher.maximumCiphertextByteCount)
        XCTAssertEqual(sealed.keyAndMAC.count, 48)
        XCTAssertEqual(opened.content.element(forName: "body", xmlns: "jabber:client")?.stringValue, body)
    }

    func testPlaintextOneByteOverNativeLimitProducesNoCiphertext() {
        let xml = String(repeating: "a", count: OMEMOPayloadCipher.maximumPlaintextByteCount + 1)

        XCTAssertThrowsError(try Omemo2PayloadCodec.seal(xml)) { error in
            XCTAssertEqual(error as? OMEMOPayloadError, .limitExceeded)
        }
    }

    func testOversizedAlignedCiphertextIsRejectedBeforeAuthenticationOrXMLParsing() {
        let ciphertext = Data(repeating: 0, count: OMEMOPayloadCipher.maximumCiphertextByteCount + 16)

        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(ciphertext,
            keyAndMAC: Data(repeating: 0, count: 48), expectedFrom: sender, expectedTo: recipient)) { error in
            XCTAssertEqual(error as? OMEMOPayloadError, .limitExceeded)
        }
    }

    func testAuthenticatedNonUTF8PayloadCannotBecomeApplicationContent() throws {
        let sealed = try OMEMOPayloadCipher().seal(Data([0xff, 0xfe, 0x80, 0xc0]))

        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(sealed.ciphertext,
            keyAndMAC: sealed.keyMaterial.serializedData(), expectedFrom: sender, expectedTo: recipient)) { error in
            guard case OmemoManagerError.invalidDecryptedPayload = error else {
                return XCTFail("Expected authenticated non-UTF8 data to fail content validation, got \(error)")
            }
        }
    }

    func testAuthenticatedEmptyOpaquePayloadIsNotAnAbsentControlOrValidSCEContent() throws {
        let sealed = try OMEMOPayloadCipher().seal(Data())
        XCTAssertEqual(sealed.ciphertext.count, 16)

        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(sealed.ciphertext,
            keyAndMAC: sealed.keyMaterial.serializedData(), expectedFrom: sender, expectedTo: recipient))
        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(nil,
            keyAndMAC: sealed.keyMaterial.serializedData(), expectedFrom: sender, expectedTo: recipient))
        XCTAssertNil(try Omemo2PayloadCodec.openVerified(nil, keyAndMAC: Data(repeating: 0, count: 32),
            expectedFrom: sender, expectedTo: recipient))
    }

    func testPayloadPresenceAndMaterialLengthCannotSelectAControlFallback() throws {
        let sealed = try Omemo2PayloadCodec.seal("<envelope xmlns='urn:xmpp:sce:1'><content/><rpad/></envelope>")
        for length in [0, 1, 31, 32, 33, 47, 49, 64] {
            XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(sealed.ciphertext,
                keyAndMAC: Data(repeating: 0, count: length), expectedFrom: sender, expectedTo: recipient), "length=\(length)")
        }
        for bytes in [Data(), Data(repeating: 0, count: 1), Data(repeating: 0, count: 15), Data(repeating: 0, count: 17)] {
            XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(bytes,
                keyAndMAC: sealed.keyAndMAC, expectedFrom: sender, expectedTo: recipient), "bytes=\(bytes.count)")
        }
    }
}
