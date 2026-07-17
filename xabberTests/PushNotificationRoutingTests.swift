import XCTest
@testable import xabber

final class PushNotificationRoutingTests: XCTestCase {
    private let owner = "romeo@example.com"

    func testRegularTextMessageParsesRouteAndBody() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <body>Hello Romeo</body>
              <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='msg-1'/>
            </message>
            """
        )

        XCTAssertEqual(preview.route.kind, .message)
        XCTAssertEqual(preview.route.owner, owner)
        XCTAssertEqual(preview.route.routeJid, "juliet@example.com")
        XCTAssertEqual(preview.route.stanzaId, "msg-1")
        XCTAssertEqual(preview.body, "Hello Romeo")
    }

    func testImageAttachmentParsesMediaAndImageFallback() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <body>photo</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='5'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file>
                    <media-type>image/jpeg</media-type>
                    <name>balcony.jpg</name>
                    <size>3072</size>
                  </file>
                  <sources>
                    <uri>https://example.com/balcony.jpg</uri>
                  </sources>
                </file-sharing>
              </reference>
            </message>
            """
        )

        XCTAssertEqual(preview.body, "Image")
        XCTAssertEqual(preview.mediaItems.first?.kind, .image)
        XCTAssertEqual(preview.mediaItems.first?.url, "https://example.com/balcony.jpg")
    }

    func testGenericFileParsesFilenameAndFormattedSize() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <body>file</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='4'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file>
                    <media-type>application/pdf</media-type>
                    <name>report.pdf</name>
                    <size>3072</size>
                  </file>
                  <sources>
                    <uri>https://example.com/report.pdf</uri>
                  </sources>
                </file-sharing>
              </reference>
            </message>
            """
        )

        XCTAssertEqual(preview.body, "file: report.pdf, 3kB")
        XCTAssertEqual(preview.mediaItems.first?.kind, .file)
        XCTAssertEqual(preview.mediaItems.first?.filename, "report.pdf")
    }

    func testVoiceMessageParsesDurationFallback() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <body>voice</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='5'>
                <voice-message xmlns='https://xabber.com/protocol/voice-messages'>
                  <file-sharing xmlns='https://xabber.com/protocol/files'>
                    <file>
                      <media-type>audio/ogg</media-type>
                      <name>voice.ogg</name>
                      <duration>10</duration>
                      <size>2048</size>
                    </file>
                    <sources>
                      <uri>https://example.com/voice.ogg</uri>
                    </sources>
                  </file-sharing>
                </voice-message>
              </reference>
            </message>
            """
        )

        XCTAssertEqual(preview.body, "Voice message, 0:10s")
        XCTAssertEqual(preview.mediaItems.first?.kind, .voice)
        XCTAssertEqual(preview.mediaItems.first?.duration, 10)
    }

    func testGroupChatMessageUsesGroupRouteAndSenderNickname() throws {
        let preview = try parseArchivedMessage(
            """
            <message type='groupchat' from='stage@conference.example.com/member-a' to='romeo@example.com'>
              <body>Hello group</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user xmlns='https://xabber.com/protocol/groups' id='member-a'>
                  <nickname>Mercutio</nickname>
                </user>
              </x>
              <stanza-id xmlns='urn:xmpp:sid:0' by='stage@conference.example.com' id='group-1'/>
            </message>
            """
        )

        XCTAssertEqual(preview.route.kind, .message)
        XCTAssertEqual(preview.route.routeJid, "stage@conference.example.com")
        XCTAssertEqual(preview.route.groupchat, "stage@conference.example.com")
        XCTAssertEqual(preview.route.conversationType, "group")
        XCTAssertEqual(preview.route.senderNickname, "Mercutio")
        XCTAssertEqual(preview.route.stanzaId, "group-1")
    }

    func testSubscriptionRequestRouteEncodesContactChatDestination() throws {
        let route = PushNotificationRoutePayload.subscriptionRequest(
            owner: owner,
            contactJid: "benvolio@example.com",
            nickname: "Benvolio"
        )
        let decoded = try XCTUnwrap(PushNotificationRoutePayload(userInfo: route.userInfo()))

        XCTAssertEqual(decoded.kind, .subscriptionRequest)
        XCTAssertEqual(decoded.owner, owner)
        XCTAssertEqual(decoded.routeJid, "benvolio@example.com")
        XCTAssertEqual(decoded.senderNickname, "Benvolio")
    }

    func testGroupInviteParsesCanonicalGroupchatKey() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.com'/>
              <group xmlns='https://xabber.com/protocol/groups' privacy='incognito'/>
            </message>
            """
        )
        let userInfo = preview.route.userInfo()

        XCTAssertEqual(preview.route.kind, .groupInvite)
        XCTAssertEqual(preview.route.routeJid, "stage@conference.example.com")
        XCTAssertEqual(preview.route.groupchat, "stage@conference.example.com")
        XCTAssertEqual(preview.route.inviterJid, "juliet@example.com")
        XCTAssertEqual(userInfo["groupchat"] as? String, "stage@conference.example.com")
        XCTAssertEqual(userInfo["route_jid"] as? String, "stage@conference.example.com")
    }

    func testLegacyGroupInvitePayloadsAreNotParsedAsInviteRoutes() throws {
        XCTAssertNotEqual(parseOptionalArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups#invite' jid='stage@conference.example.com'/>
            </message>
            """
        )?.route.kind, .groupInvite)
        XCTAssertNotEqual(parseOptionalArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <x xmlns='https://xabber.com/protocol/groups'>
                <jid>stage@conference.example.com</jid>
                <privacy>incognito</privacy>
              </x>
            </message>
            """
        )?.route.kind, .groupInvite)
    }

    func testXenWrappedVerificationRequestValidatesOFromAndParsesSid() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='push.example.com' to='romeo@example.com'>
              <addresses xmlns='http://jabber.org/protocol/address'>
                <address type='ofrom' jid='juliet@example.com'/>
              </addresses>
              <notification xmlns='urn:xabber:xen:0'>
                <forwarded xmlns='urn:xmpp:forward:0'>
                  <message from='juliet@example.com/device-1' to='romeo@example.com'>
                    <trust xmlns='urn:xmpp:trust:0' sid='trust-1'>
                      <request device-id='42'/>
                    </trust>
                  </message>
                </forwarded>
              </notification>
            </message>
            """
        )

        XCTAssertEqual(preview.route.kind, .verificationRequest)
        XCTAssertEqual(preview.route.owner, owner)
        XCTAssertEqual(preview.route.sid, "trust-1")
        XCTAssertEqual(preview.route.senderJid, "juliet@example.com")
    }

    func testRoutePayloadDecodesLegacyJidWhenRouteJidIsMissing() throws {
        let decoded = try XCTUnwrap(PushNotificationRoutePayload(userInfo: [
            "route_kind": "message",
            "owner": owner,
            "jid": "juliet@example.com",
            "stanzaId": "legacy-1"
        ]))

        XCTAssertEqual(decoded.kind, .message)
        XCTAssertEqual(decoded.routeJid, "juliet@example.com")
        XCTAssertEqual(decoded.stanzaId, "legacy-1")
    }

    func testLocalMessageNotificationBuildsExactMessageAnchorRequest() throws {
        let timestamp = Date(timeIntervalSince1970: 1_711_283_200).timeIntervalSinceReferenceDate
        let producedRoute = LocalMessageNotificationRouteFactory.make(
            owner: owner,
            routeJid: "juliet@example.com",
            conversationType: "regular",
            stanzaId: "1711283200000000",
            senderJid: "juliet@example.com",
            senderNickname: nil
        )
        let decodedRoute = try XCTUnwrap(
            PushNotificationRoutePayload(userInfo: producedRoute.userInfo(timestamp: timestamp))
        )

        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: decodedRoute,
                fallbackConversationType: .regular
            )
        )

        XCTAssertEqual(request.source, .pushNotification)
        XCTAssertEqual(request.anchor.archivedId, "1711283200000000")
        XCTAssertNil(request.anchor.messageId)
        XCTAssertEqual(request.anchor.authorId, "juliet@example.com")
        XCTAssertEqual(request.anchor.sourceDate, Date(timeIntervalSince1970: 1_711_283_200))
        XCTAssertTrue(request.highlight)
        XCTAssertTrue(request.markReadOnVisible)
    }

    func testForegroundNotificationTapStillOpensTheExactMessageRoute() {
        let plan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: true,
            atStart: false
        )

        XCTAssertTrue(plan.opensChat)
        XCTAssertFalse(plan.clearsUnread)
        XCTAssertNil(plan.legacyFallbackAction)
    }

    func testBackgroundLocalOrPushNotificationTapUsesTheSameChatRoute() {
        let foregroundPlan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: false,
            atStart: false
        )
        let coldStartPlan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: false,
            atStart: true
        )

        XCTAssertTrue(foregroundPlan.opensChat)
        XCTAssertTrue(foregroundPlan.clearsUnread)
        XCTAssertEqual(foregroundPlan.legacyFallbackAction, "foregroundChat")
        XCTAssertTrue(coldStartPlan.opensChat)
        XCTAssertTrue(coldStartPlan.clearsUnread)
        XCTAssertEqual(coldStartPlan.legacyFallbackAction, "initialChat")
    }

    func testRichPushNotificationBuildsTheSameExactMessageAnchorRequest() throws {
        let preview = try parseArchivedMessage(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com' id='push-message-id'>
              <body>Hello Romeo</body>
              <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='1711283200000000'/>
            </message>
            """
        )
        let decodedRoute = try XCTUnwrap(
            PushNotificationRoutePayload(
                userInfo: preview.route.userInfo(
                    timestamp: Date(timeIntervalSince1970: 1_711_283_200).timeIntervalSinceReferenceDate
                )
            )
        )

        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: decodedRoute,
                fallbackConversationType: .regular
            )
        )

        XCTAssertEqual(request.chatJid, "juliet@example.com")
        XCTAssertEqual(request.anchor.archivedId, "1711283200000000")
        XCTAssertEqual(request.anchor.messageId, "push-message-id")
        XCTAssertEqual(request.source, .pushNotification)
    }

    private func parseArchivedMessage(_ messageXML: String) throws -> PushNotificationPreview {
        try XCTUnwrap(parseOptionalArchivedMessage(messageXML))
    }

    private func parseOptionalArchivedMessage(_ messageXML: String) -> PushNotificationPreview? {
        let archiveXML = """
        <message>
          <result>
            <forwarded xmlns='urn:xmpp:forward:0'>
              \(messageXML)
            </forwarded>
          </result>
        </message>
        """
        return PushNotificationArchiveParser.parseArchivedMessage(xmlString: archiveXML, owner: owner)
    }
}
