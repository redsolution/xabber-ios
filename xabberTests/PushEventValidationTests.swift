import XCTest
import CryptoSwift
import KissXML
@testable import xabber

final class PushEventValidationTests: XCTestCase {
    private let key = String(repeating: "k", count: 32)

    func testServerCompactMessageCanBeDecrypted() throws {
        let body = try envelope(plaintext: "<stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.invalid' id='123'/>")
        let result = EncryptedPushDate(body).payloadStanza(key: key)
        XCTAssertEqual(result?.name, "stanza-id")
        XCTAssertEqual(result?.attributeStringValue(forName: "id"), "123")
    }

    func testRelaySiblingPayloadWithoutEncryptedNamespaceDecryptsSummary() throws {
        let plaintext = "<stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='relay-archive-1'/>"
        let body = try envelope(plaintext: plaintext, namespace: nil)

        let parsed = try XCTUnwrap(PushPayloadEnvelope(body))

        XCTAssertEqual(parsed.decrypt(by: Array(key.utf8)), plaintext)
        XCTAssertEqual(parsed.messageStanzaID(key: Array(key.utf8)),
                       PushStanzaIdentifier(id: "relay-archive-1", by: "owner@example.invalid"))
    }

    func testRelaySiblingPayloadWithoutEncryptedNamespaceDecryptsFullMessage() throws {
        let body = try envelope(plaintext: "<message xmlns='jabber:client' from='peer@example.invalid/device' type='chat' id='relay-message-1'><body>Relay full preview</body></message>", namespace: nil)

        let parsed = try XCTUnwrap(PushPayloadEnvelope(body))
        guard case .fullMessage(let message)? = parsed.event(key: Array(key.utf8)) else {
            return XCTFail("Relay siblings must preserve full-message dispatch after decryption")
        }

        XCTAssertEqual(message.attribute(forName: "id")?.stringValue, "relay-message-1")
        XCTAssertEqual(message.attribute(forName: "from")?.stringValue, "peer@example.invalid/device")
        XCTAssertEqual(message.element(forName: "body")?.stringValue, "Relay full preview")
    }

    func testCanonicalNotificationInheritedEncryptedNamespaceDecryptsSummary() throws {
        let plaintext = "<stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='canonical-archive-1'/>"
        let siblings = try envelope(plaintext: plaintext, namespace: nil)
        let body = "<notification xmlns='https://xabber.com/protocol/push'>\(siblings)</notification>"

        let parsed = try XCTUnwrap(PushPayloadEnvelope(body))

        XCTAssertEqual(parsed.decrypt(by: Array(key.utf8)), plaintext)
        XCTAssertEqual(parsed.messageStanzaID(key: Array(key.utf8)),
                       PushStanzaIdentifier(id: "canonical-archive-1", by: "owner@example.invalid"))
    }

    func testRelayExplicitlyEmptyEncryptedNamespaceIsRejected() throws {
        let body = try envelope(plaintext: "<stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='rejected-archive-1'/>", namespace: "")

        XCTAssertNil(PushPayloadEnvelope(body))
    }

    func testRelayExplicitlyForeignEncryptedNamespaceIsRejected() throws {
        let body = try envelope(plaintext: "<stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='rejected-archive-1'/>", namespace: "https://foreign.invalid")

        XCTAssertNil(PushPayloadEnvelope(body))
    }

    func testMissingTypeUsesDefaultMessageHint() throws {
        let body = try envelope(plaintext: "<stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.invalid' id='123'/>", type: nil)
        XCTAssertEqual(EncryptedPushDate(body).payloadStanza(key: key)?.name, "stanza-id")
    }

    func testForeignEncryptedNamespaceCannotProduceAStanza() throws {
        let body = try envelope(plaintext: "<presence from='peer@example.invalid' type='subscribe'/>", namespace: "https://foreign.invalid")
        XCTAssertNil(EncryptedPushDate(body).payloadStanza(key: key))
    }

    func testForeignFormTypeCannotProduceAStanza() throws {
        let body = try envelope(plaintext: "<presence from='peer@example.invalid' type='subscribe'/>", formType: "https://foreign.invalid/info")
        XCTAssertNil(EncryptedPushDate(body).payloadStanza(key: key))
    }

    func testDuplicateEncryptedElementsAreRejected() throws {
        let body = try envelope(plaintext: "<presence from='peer@example.invalid' type='subscribe'/>")
        let encrypted = try XCTUnwrap(EncryptedPushDate(body).encrypted)
        XCTAssertNil(EncryptedPushDate(encrypted + body).payloadStanza(key: key))
    }

    func testDuplicateMetadataFormsAreRejected() throws {
        let body = try envelope(plaintext: "<presence from='peer@example.invalid' type='subscribe'/>")
        XCTAssertNil(EncryptedPushDate(body + form(type: "subscribe")).payloadStanza(key: key))
    }

    func testInternalDTDInDecryptedPayloadIsRejected() throws {
        let body = try envelope(plaintext: "<!DOCTYPE presence [<!ENTITY name 'fixture'>]><presence from='&name;' type='subscribe'/>")
        XCTAssertNil(EncryptedPushDate(body).payloadStanza(key: key))
    }

    func testMalformedCiphertextDoesNotGetPaddedIntoAValidBlock() {
        let bytes = Data(Array(repeating: UInt8(0), count: 17)).base64EncodedString()
        let body = "<encrypted xmlns='https://xabber.com/protocol/push' iv-length='16'>\(bytes)</encrypted>" + form(type: "message")
        XCTAssertNil(EncryptedPushDate(body).payloadStanza(key: key))
    }

    func testUnknownDecryptedRootCannotProduceAStanza() throws {
        let body = try envelope(plaintext: "<unexpected id='123'/>")
        XCTAssertNil(EncryptedPushDate(body).payloadStanza(key: key))
    }

    func testDisplayedWithoutOptionalArchiveIDIsValidated() throws {
        let body = try envelope(plaintext: "<displayed xmlns='urn:xmpp:chat-markers:0' id='message-123'/>", type: "message")
        let parsed = try XCTUnwrap(PushPayloadEnvelope(body))
        guard case .displayed(let marker)? = parsed.event(key: Array(key.utf8)) else {
            return XCTFail("Validated plaintext must own event dispatch, independently of metadata")
        }
        XCTAssertEqual(marker.messageID, "message-123")
        XCTAssertTrue(marker.stanzaIDs.isEmpty)
    }

    func testRawBinaryKeyAndOutgoingMetadataArePreserved() throws {
        var body = try envelope(plaintext: "<stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.invalid' id='123'/>")
        body = body.replacingOccurrences(of: "</x>", with: "<field var='outgoing'><value>true</value></field></x>")
        XCTAssertTrue(try XCTUnwrap(PushPayloadEnvelope(body)).outgoing)
    }

    func testServerFullCallMayContainBodyWhileProposalOwnsDispatch() throws {
        let body = try envelope(plaintext: "<message from='peer@example.invalid/device' type='chat'><body>legacy server full call</body><propose xmlns='urn:xmpp:jingle-message:0' id='call-123'/></message>")
        guard case .call? = PushPayloadEnvelope(body)?.event(key: Array(key.utf8)) else {
            return XCTFail("Server full-call payload must remain supported")
        }
    }

    func testBareJingleUpdateIsRecognizedAsData() throws {
        let body = try envelope(plaintext: "<reject xmlns='urn:xmpp:jingle-message:0' id='call-123'/>", type: "data")
        guard case .callUpdate? = PushPayloadEnvelope(body)?.event(key: Array(key.utf8)) else {
            return XCTFail("Actual server data payload is a Jingle update")
        }
    }

    func testDisplayedRemovalIsOwnerScopedAndUsesMessageIDWithoutStanzaID() {
        let marker = PushDisplayedTarget(messageID: "message-123", stanzaIDs: [])
        let records = [
            PushDeliveredNotification(identifier: "own-old", owner: "me", jid: "peer", timestamp: 1, stanzaID: nil, messageID: "old"),
            PushDeliveredNotification(identifier: "own-target", owner: "me", jid: "peer", timestamp: 2, stanzaID: nil, messageID: "message-123"),
            PushDeliveredNotification(identifier: "own-new", owner: "me", jid: "peer", timestamp: 3, stanzaID: nil, messageID: "new"),
            PushDeliveredNotification(identifier: "foreign", owner: "other", jid: "peer", timestamp: 2, stanzaID: nil, messageID: "message-123")
        ]
        XCTAssertEqual(Set(PushDisplayedPolicy.removalIDs(marker: marker, owner: "me", notifications: records)), ["own-old", "own-target"])
    }

    func testAmbiguousDisplayedMessageIDNeverDeletesAnotherConversation() {
        let marker = PushDisplayedTarget(messageID: "same", stanzaIDs: [])
        let records = [
            PushDeliveredNotification(identifier: "one", owner: "me", jid: "peer1", timestamp: 1, stanzaID: nil, messageID: "same"),
            PushDeliveredNotification(identifier: "two", owner: "me", jid: "peer2", timestamp: 1, stanzaID: nil, messageID: "same")
        ]
        XCTAssertTrue(PushDisplayedPolicy.removalIDs(marker: marker, owner: "me", notifications: records).isEmpty)
    }

    func testAmbiguousDisplayedTimestampCannotDeleteNewerNotifications() {
        let marker = PushDisplayedTarget(messageID: "same", stanzaIDs: [])
        let records = [
            PushDeliveredNotification(identifier: "one", owner: "me", jid: "peer", timestamp: 1, stanzaID: nil, messageID: "same"),
            PushDeliveredNotification(identifier: "two", owner: "me", jid: "peer", timestamp: 3, stanzaID: nil, messageID: "same")
        ]
        XCTAssertTrue(PushDisplayedPolicy.removalIDs(marker: marker, owner: "me", notifications: records).isEmpty)
    }

    func testNonUTF8AESKeyDecryptsServerPayload() throws {
        let rawKey = Array(UInt8(128)...UInt8(159))
        let plaintext = "<stanza-id xmlns='urn:xmpp:sid:0' by='me' id='123'/>"
        let iv = Array(repeating: UInt8(7), count: 16)
        var bytes = Array(plaintext.utf8)
        bytes += Array(repeating: 0, count: 16 - bytes.count % 16)
        let encrypted = try AES(key: rawKey, blockMode: CBC(iv: iv), padding: .noPadding).encrypt(bytes)
        let body = "<encrypted xmlns='https://xabber.com/protocol/push' iv-length='16'>\(Data(iv + encrypted).base64EncodedString())</encrypted>" + form(type: "message")
        XCTAssertEqual(EncryptedPushDate(body).payloadStanza(key: rawKey)?.attribute(forName: "id")?.stringValue, "123")
    }

    private func envelope(plaintext: String, type: String? = "message",
                          namespace: String? = "https://xabber.com/protocol/push",
                          formType: String = "https://xabber.com/protocol/push#info") throws -> String {
        let iv = Array(repeating: UInt8(7), count: 16)
        var bytes = Array(plaintext.utf8)
        bytes += Array(repeating: 0, count: 16 - bytes.count % 16)
        let encrypted = try AES(key: Array(key.utf8), blockMode: CBC(iv: iv), padding: .noPadding).encrypt(bytes)
        let payload = Data(iv + encrypted).base64EncodedString()
        let namespaceAttribute = namespace.map { " xmlns='\($0)'" } ?? ""
        return "<encrypted\(namespaceAttribute) iv-length='16'>\(payload)</encrypted>" + form(type: type, formType: formType)
    }

    private func form(type: String?, formType: String = "https://xabber.com/protocol/push#info") -> String {
        let field = type.map { "<field var='type'><value>\($0)</value></field>" } ?? ""
        return "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE' type='hidden'><value>\(formType)</value></field>\(field)</x>"
    }
}
