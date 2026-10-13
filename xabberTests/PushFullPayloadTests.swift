import Foundation
import XCTest
import CryptoSwift
import KissXML
@testable import xabber

final class PushFullPayloadTests: XCTestCase {
    private let key = Array(UInt8(128)...UInt8(159))
    private let owner = "owner@example.invalid"

    func testQualifiedFullMessageDecryptsWithoutCompactArchiveLookup() throws {
        let message = try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' to='owner@example.invalid' type='chat' id='message-1'>
          <body>Full push preview</body>
          <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='archive-1'/>
        </message>
        """)

        XCTAssertEqual(message?.localName, "message")
        XCTAssertEqual(message?.element(forName: "body")?.stringValue, "Full push preview")
        guard let message, case .fullMessage? = PushPayloadXML.classify(message) else {
            return XCTFail("Ordinary full stanza must have its own event, without an HTTP lookup")
        }
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parseArchivedMessage(message, owner: owner))
        XCTAssertEqual(preview.body, "Full push preview")
        XCTAssertEqual(preview.route.messageId, "message-1")
        XCTAssertEqual(preview.route.stanzaId, "archive-1")
    }

    func testServerMessageFragmentWithoutExplicitNamespaceRemainsSupported() throws {
        let message = try decode("<message from='peer@example.invalid/device' type='chat' id='message-1'><body>Server fragment</body></message>")

        XCTAssertEqual(message?.localName, "message")
        XCTAssertEqual(message?.element(forName: "body")?.stringValue, "Server fragment")
    }

    func testFullMessageWorksThroughCanonicalNotificationWrapper() throws {
        let body = try envelope("<message xmlns='jabber:client' from='peer@example.invalid'><body>Full wrapper</body></message>")
        let wrapped = "<notification xmlns='https://xabber.com/protocol/push'>\(body)</notification>"
        let message = try XCTUnwrap(EncryptedPushDate(wrapped).payloadStanza(key: key))

        guard case .fullMessage? = PushPayloadXML.classify(message) else { return XCTFail("Canonical wrapper must preserve full dispatch") }
    }

    func testFullMessageWorksThroughBase64JSONRelay() throws {
        let body = try envelope("<message xmlns='jabber:client' from='peer@example.invalid'><body>Full relay</body></message>")
        let encrypted = try XCTUnwrap(EncryptedPushDate(body).encrypted)
        let json = try JSONSerialization.data(withJSONObject: ["action": "unknown-info-hint", "encrypted": encrypted])
        let message = try XCTUnwrap(EncryptedPushDate(json.base64EncodedString()).payloadStanza(key: key))

        guard case .fullMessage? = PushPayloadXML.classify(message) else { return XCTFail("JSON relay must preserve full dispatch independent of hint") }
    }

    func testFullReceivedCarbonUsesInnerPeerAndExactMessageRoute() throws {
        let message = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' from='owner@example.invalid/device' type='chat'>
          <received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>
            <message xmlns='jabber:client' from='peer@example.invalid/device' to='owner@example.invalid' type='chat' id='carbon-message-1'>
              <body>Full received carbon</body><stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='carbon-archive-1'/>
            </message>
          </forwarded></received>
        </message>
        """))
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parseArchivedMessage(message, owner: owner))

        XCTAssertEqual(preview.body, "Full received carbon")
        XCTAssertEqual(preview.route.routeJid, "peer@example.invalid")
        XCTAssertEqual(preview.route.messageId, "carbon-message-1")
        XCTAssertEqual(preview.route.stanzaId, "carbon-archive-1")
    }

    func testFullMessageWithDefaultTypeAndMismatchedMetadataIsRecognized() throws {
        let message = try decode("<message xmlns='jabber:client' from='peer@example.invalid/device'><body>Default normal</body></message>", hint: "displayed")

        XCTAssertEqual(message?.localName, "message")
    }

    func testFullOMEMOMessageKeepsNeutralPreviewInsteadOfUntrustedFallbackBody() throws {
        let message = try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' to='owner@example.invalid' type='chat' id='message-1'>
          <body>Untrusted encryption fallback</body>
          <encrypted xmlns='urn:xmpp:omemo:2'><header sid='123'/><payload>opaque</payload></encrypted>
        </message>
        """)

        let preview = try XCTUnwrap(message.flatMap { PushNotificationArchiveParser.parseArchivedMessage($0, owner: owner) })
        XCTAssertNotEqual(preview.body, "Untrusted encryption fallback")
        XCTAssertEqual(preview.route.kind, .message)
    }

    func testFullImagePreservesMediaAndExactMessageRoute() throws {
        let message = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' to='owner@example.invalid' type='chat' id='image-1'>
          <body>Image caption</body>
          <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='archive-image-1'/>
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>
            <file-sharing xmlns='https://xabber.com/protocol/files'>
              <file><media-type>image/jpeg</media-type><name>picture.jpg</name></file>
              <sources><uri>https://cdn.example.invalid/picture.jpg</uri></sources>
            </file-sharing>
          </reference>
        </message>
        """))
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parseArchivedMessage(message, owner: owner))

        XCTAssertEqual(preview.body, "Image caption")
        XCTAssertEqual(preview.mediaItems.first?.kind, .image)
        XCTAssertEqual(preview.imageURLs, ["https://cdn.example.invalid/picture.jpg"])
        XCTAssertEqual(preview.route.messageId, "image-1")
        XCTAssertEqual(preview.route.stanzaId, "archive-image-1")
    }

    func testFullInvitePreservesTypedRouteAndIncognitoIdentity() throws {
        let message = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' type='chat' from='stage@conference.example.invalid' to='owner@example.invalid' id='invite-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.invalid'>
            <user id='member-peer'><nickname>Peer</nickname></user>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='incognito'><info><name>Secret Stage</name></info></group>
        </message>
        """))
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parseArchivedMessage(message, owner: owner))

        XCTAssertEqual(preview.route.kind, .groupInvite)
        XCTAssertEqual(preview.route.groupchat, "stage@conference.example.invalid")
        XCTAssertEqual(preview.route.senderUserId, "member-peer")
        XCTAssertNil(preview.route.inviterJid)
    }

    func testForeignFullMessageNamespaceIsRejected() throws {
        XCTAssertNil(try decode("<message xmlns='https://foreign.invalid' from='peer@example.invalid'><body>Rejected</body></message>"))
    }

    func testForeignCoreBodyCannotBecomeFullMessagePreview() throws {
        XCTAssertNil(try decode("<message xmlns='jabber:client' from='peer@example.invalid'><body xmlns='https://foreign.invalid'>Rejected</body></message>"))
    }

    func testDuplicateDefaultBodiesAreRejected() throws {
        XCTAssertNil(try decode("<message xmlns='jabber:client' from='peer@example.invalid'><body>One</body><body>Two</body></message>"))
    }

    func testDuplicateArchiveIDsForSameOwnerAreRejected() throws {
        XCTAssertNil(try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid'><body>Rejected</body>
          <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='one'/>
          <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='two'/>
        </message>
        """))
    }

    func testDifferentArchiveOwnersRemainValidInFullMessage() throws {
        XCTAssertNotNil(try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid'><body>Two archives</body>
          <stanza-id xmlns='urn:xmpp:sid:0' by='peer@example.invalid' id='one'/>
          <stanza-id xmlns='urn:xmpp:sid:0' by='owner@example.invalid' id='two'/>
        </message>
        """))
    }

    func testMissingSenderCannotBecomeVisibleFullMessage() throws {
        XCTAssertNil(try decode("<message xmlns='jabber:client' type='chat'><body>Rejected</body></message>"))
    }

    func testErrorMessageCannotBecomeVisibleFullPush() throws {
        XCTAssertNil(try decode("<message xmlns='jabber:client' from='peer@example.invalid' type='error'><body>Rejected</body></message>"))
    }

    func testCallProposalHasPriorityOverFullMessageBody() throws {
        let root = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' type='chat'>
          <body>Call body is not a message preview</body><propose xmlns='urn:xmpp:jingle-message:0' id='call-1'/>
        </message>
        """))
        guard case .call? = PushPayloadXML.classify(root) else { return XCTFail("Call proposal must own dispatch") }
    }

    func testHeadlineReconciliationHasPriorityOverFullMessageBody() throws {
        let root = try XCTUnwrap(decode("<message xmlns='jabber:client' from='example.invalid' type='headline'><body>Control headline</body></message>"))

        guard case .reconciliation? = PushPayloadXML.classify(root) else { return XCTFail("Headline must keep reconciliation dispatch") }
    }

    func testWrappedDisplayedHasPriorityOverFullMessage() throws {
        let root = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' from='owner@example.invalid/device' type='chat'>
          <displayed xmlns='urn:xmpp:chat-markers:0' id='message-1'/>
        </message>
        """))

        guard case .displayed(let marker)? = PushPayloadXML.classify(root) else { return XCTFail("Full marker must retain displayed dispatch") }
        XCTAssertEqual(marker.messageID, "message-1")
    }

    func testCompetingCallAndDisplayedCannotBecomeAVisibleMessage() throws {
        XCTAssertNil(try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' type='chat'><body>Rejected</body>
          <propose xmlns='urn:xmpp:jingle-message:0' id='call-1'/><displayed xmlns='urn:xmpp:chat-markers:0' id='message-1'/>
        </message>
        """))
    }

    func testWrappedAcceptAndRejectNeverBecomeVisibleFullMessageBody() throws {
        for name in ["accept", "reject"] {
            let root = try XCTUnwrap(decode("""
            <message xmlns='jabber:client' from='owner@example.invalid/device' type='chat'>
              <body>Control body</body><\(name) xmlns='urn:xmpp:jingle-message:0' id='call-1'/>
            </message>
            """))
            guard case .reconciliation? = PushPayloadXML.classify(root) else {
                return XCTFail("Wrapped JMI \(name) must reconcile without assuming local relay ownership")
            }
        }
    }

    func testForeignControlNamespaceCannotFallThroughToFullMessage() throws {
        for name in ["propose", "accept", "reject", "displayed"] {
            XCTAssertNil(try decode("""
            <message xmlns='jabber:client' from='peer@example.invalid/device' type='chat'>
              <body>Rejected</body><\(name) xmlns='https://foreign.invalid' id='control-1'/>
            </message>
            """), name)
        }
    }

    func testCompetingJMIUpdatesCannotBecomeVisibleFullMessage() throws {
        XCTAssertNil(try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' type='chat'><body>Rejected</body>
          <accept xmlns='urn:xmpp:jingle-message:0' id='call-1'/><reject xmlns='urn:xmpp:jingle-message:0' id='call-1'/>
        </message>
        """))
    }

    func testOtherWrappedJMIControlsRemainNonVisibleReconciliation() throws {
        for name in ["retract", "proceed", "finish"] {
            let root = try XCTUnwrap(decode("""
            <message xmlns='jabber:client' from='peer@example.invalid/device' type='chat'>
              <body>Control body</body><\(name) xmlns='urn:xmpp:jingle-message:0' id='call-1'/>
            </message>
            """))
            guard case .reconciliation? = PushPayloadXML.classify(root) else {
                return XCTFail("Wrapped JMI \(name) must retain non-visible dispatch")
            }
        }
    }

    func testInvalidBareSenderCannotBecomeFullMessage() throws {
        for sender in ["@example.invalid", "peer@", "/device", "peer @example.invalid"] {
            XCTAssertNil(try decode("<message xmlns='jabber:client' from='\(sender)'><body>Rejected</body></message>"), sender)
        }
    }

    func testDuplicateCallProposalCannotFallThroughToFullMessage() throws {
        XCTAssertNil(try decode("""
        <message xmlns='jabber:client' from='peer@example.invalid/device' type='chat'><body>Rejected</body>
          <propose xmlns='urn:xmpp:jingle-message:0' id='one'/><propose xmlns='urn:xmpp:jingle-message:0' id='two'/>
        </message>
        """))
    }

    func testFullMessageDTDIsRejectedBeforeParsing() throws {
        XCTAssertNil(try decode("<!DOCTYPE message [<!ENTITY secret 'fixture'>]><message xmlns='jabber:client' from='peer@example.invalid'><body>&secret;</body></message>"))
    }

    func testFullHeadlineCanonicalInviteProducesTypedPreview() throws {
        let message = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' type='headline' from='stage@conference.example.invalid' to='owner@example.invalid'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.invalid'>
            <user id='member-peer'><nickname>Peer</nickname></user>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='incognito'><info><name>Secret Stage</name></info></group>
        </message>
        """))
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parsePushHeadline(message, owner: owner))

        XCTAssertEqual(preview.route.kind, .groupInvite)
        XCTAssertEqual(preview.route.groupchat, "stage@conference.example.invalid")
        XCTAssertEqual(preview.route.senderUserId, "member-peer")
        XCTAssertNil(preview.route.inviterJid)
    }

    func testFullHeadlineTrustRequestProducesTypedPreview() throws {
        let message = try XCTUnwrap(decode("""
        <message xmlns='jabber:client' type='headline' from='peer@example.invalid/device' to='owner@example.invalid'>
          <trust xmlns='urn:xmpp:trust:0' sid='session-1'><request/></trust>
        </message>
        """))
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parsePushHeadline(message, owner: owner))

        XCTAssertEqual(preview.route.kind, .verificationRequest)
        XCTAssertEqual(preview.route.senderJid, "peer@example.invalid")
        XCTAssertEqual(preview.route.sid, "session-1")
    }

    func testUnknownHeadlineBodyAndDeviceRevokeRemainNonVisible() throws {
        for child in [
            "<body>Control body</body>",
            "<revoke xmlns='https://xabber.com/protocol/devices'><device id='device-1'/></revoke>",
            "<revoke xmlns='https://xabber.com/protocol/devices'><device id='device-1'/></revoke><trust xmlns='urn:xmpp:trust:0'><request/></trust>"
        ] {
            let message = try headlineElement(child)
            XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(message, owner: owner))
        }
    }

    func testMalformedAndForeignHeadlineInvitesRemainNonVisible() throws {
        for child in [
            "<invite xmlns='https://foreign.invalid' jid='stage@conference.example.invalid'/>",
            "<invite xmlns='https://xabber.com/protocol/groups' jid='invalid-jid'/>",
            "<invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.invalid'/><invite xmlns='https://xabber.com/protocol/groups' jid='other@conference.example.invalid'/>"
        ] {
            XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(try headlineElement(child), owner: owner))
        }
    }

    func testHeadlineSenderMayHaveAnOpaqueResourceWithSpaces() throws {
        let message = try headlineElement("<trust xmlns='urn:xmpp:trust:0' sid='session-1'><request/></trust>",
                                          sender: "peer@example.invalid/My Phone")
        let preview = try XCTUnwrap(PushNotificationArchiveParser.parsePushHeadline(message, owner: owner))
        XCTAssertEqual(preview.route.kind, .verificationRequest)
        XCTAssertEqual(preview.route.senderJid, "peer@example.invalid")
    }

    func testForeignHeadlineRootAndInvalidSenderRemainNonVisible() throws {
        let trust = "<trust xmlns='urn:xmpp:trust:0' sid='session-1'><request/></trust>"
        let foreign = try headlineElement(trust, namespace: "https://foreign.invalid")
        XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(foreign, owner: owner))
        for sender in ["", "peer@", "peer @example.invalid", "/device"] {
            XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(try headlineElement(trust, sender: sender), owner: owner))
        }
    }

    func testOMEMOHeadlineCannotExposeAnOuterTrustOrInviteHint() throws {
        let children = "<trust xmlns='urn:xmpp:trust:0'><request/></trust><encrypted xmlns='urn:xmpp:omemo:2'><header sid='123'/><payload>opaque</payload></encrypted>"

        XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(try headlineElement(children), owner: owner))
    }

    func testAmbiguousOrForeignHeadlineTrustRequestRemainsNonVisible() throws {
        for children in [
            "<trust xmlns='https://foreign.invalid'><request/></trust>",
            "<trust xmlns='urn:xmpp:trust:0'><request xmlns='https://foreign.invalid'/></trust>",
            "<trust xmlns='urn:xmpp:trust:0'><request/><request/></trust>",
            "<trust xmlns='urn:xmpp:trust:0'><request/><accept/></trust>",
            "<trust xmlns='urn:xmpp:trust:0'><request><nested/></request></trust>",
            "<trust xmlns='urn:xmpp:trust:0'><request/></trust><trust xmlns='urn:xmpp:trust:0'><request/></trust>"
        ] {
            XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(try headlineElement(children), owner: owner))
        }
    }

    func testCompetingHeadlineInviteAndTrustRequestRemainNonVisible() throws {
        let children = "<invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.invalid'/><trust xmlns='urn:xmpp:trust:0'><request/></trust>"

        XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(try headlineElement(children), owner: owner))
    }

    func testJMIControlsCannotAcquireVisibleHeadlineThroughTypedHint() throws {
        for name in ["propose", "accept", "reject"] {
            let children = "<\(name) xmlns='urn:xmpp:jingle-message:0' id='call-1'/><trust xmlns='urn:xmpp:trust:0'><request/></trust>"
            XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(try headlineElement(children), owner: owner))
        }
    }

    func testHeadlineParserDoesNotReclassifyAnOrdinaryChatMessage() throws {
        let message = try headlineElement("<trust xmlns='urn:xmpp:trust:0'><request/></trust>")
        message.attribute(forName: "type")?.stringValue = "chat"

        XCTAssertNil(PushNotificationArchiveParser.parsePushHeadline(message, owner: owner))
    }

    private func headlineElement(_ children: String, namespace: String = "jabber:client",
                                 sender: String = "peer@example.invalid/device") throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: "<message xmlns='\(namespace)' type='headline' from='\(sender)'>\(children)</message>", options: 0)
        return try XCTUnwrap(document.rootElement())
    }

    private func decode(_ plaintext: String, hint: String = "message") throws -> DDXMLElement? {
        EncryptedPushDate(try envelope(plaintext, hint: hint)).payloadStanza(key: key)
    }

    private func envelope(_ plaintext: String, hint: String = "message") throws -> String {
        let iv = Array(repeating: UInt8(7), count: 16)
        var bytes = Array(plaintext.utf8)
        bytes += Array(repeating: 0, count: 16 - bytes.count % 16)
        let encrypted = try AES(key: key, blockMode: CBC(iv: iv), padding: .noPadding).encrypt(bytes)
        let data = Data(iv + encrypted).base64EncodedString()
        let body = "<encrypted xmlns='https://xabber.com/protocol/push' iv-length='16'>\(data)</encrypted>"
            + "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE'><value>https://xabber.com/protocol/push#info</value></field><field var='type'><value>\(hint)</value></field></x>"
        return body
    }
}
