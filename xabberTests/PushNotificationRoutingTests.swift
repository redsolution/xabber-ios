import UIKit
import XCTest
import RealmSwift
import UserNotifications
@testable import xabber

final class PushNotificationRoutingTests: XCTestCase {
    private let owner = "romeo@example.com"

    private final class LeftMenuAcknowledgementSpy: LeftMenuSelectRootScreenDelegate {
        var acknowledgement = false
        private(set) var receivedOwner: String?
        private(set) var receivedJid: String?
        private(set) var receivedConversationType: ClientSynchronizationManager.ConversationType?
        private(set) var receivedRequest: ChatOpenMessageRequest?
        private(set) var receivedNavigationSource: ChatOpenNavigationSource?
        private(set) var openCount = 0

        func selectRootScreenAndCategory(screen key: String, category: String?) -> Bool {
            true
        }

        func openChatlistWithChat(
            owner: String,
            jid: String,
            conversationType: ClientSynchronizationManager.ConversationType,
            openMessageRequest: ChatOpenMessageRequest?,
            navigationSource: ChatOpenNavigationSource,
            configure: ((ChatViewController?) -> Void)?
        ) -> Bool {
            receivedOwner = owner
            receivedJid = jid
            receivedConversationType = conversationType
            receivedRequest = openMessageRequest
            receivedNavigationSource = navigationSource
            openCount += 1
            return acknowledgement
        }
    }

    func testRegularTextMessageParsesRouteAndBody() throws {
        let preview = try parseArchivedMessage(
            """
            <message type='chat' from='juliet@example.com/mobile' to='romeo@example.com'>
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
            <message type='chat' from='stage@conference.example.com/member-a' to='romeo@example.com'>
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

    func testPushGroupAuthorRejectsDuplicateAmbiguousAndNestedCanonicalShapes() throws {
        let malformed = [
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Ambiguous wrapper</body>
              <x xmlns='https://xabber.com/protocol/groups'><user id='member-a'/></x>
              <x xmlns='https://xabber.com/protocol/groups'><user id='member-b'/></x>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Ambiguous users</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user id='member-a'/><user id='member-b'/>
              </x>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Ambiguous sibling</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user id='member-a'/>
                <reference xmlns='https://xabber.com/protocol/references' type='mutable'/>
              </x>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Nested author</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <wrapper><user id='member-a'/></wrapper>
              </x>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Malformed author</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user id='member-a'><nickname>First</nickname><nickname>Second</nickname></user>
              </x>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Legacy attribute author</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user id='member-a' jid='member-a@example.com'/>
              </x>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <body>Decorated wrapper</body>
              <x xmlns='https://xabber.com/protocol/groups' legacy='true'>
                <user id='member-a'/>
              </x>
            </message>
            """
        ]

        for xml in malformed {
            let preview = try XCTUnwrap(parseOptionalArchivedMessage(xml), xml)
            XCTAssertEqual(preview.route.conversationType, "regular", xml)
            XCTAssertNil(preview.route.groupchat, xml)
            XCTAssertNil(preview.route.senderUserId, xml)
            XCTAssertNil(preview.route.senderNickname, xml)
        }
    }

    func testLocalPreviewDoesNotTreatLegacyGroupchatConversationAliasAsGroup() {
        let legacy = LocalMessageNotificationPreviewFactory.make(
            originalStanzaXML: nil,
            owner: owner,
            routeJid: "stage@conference.example.com",
            conversationType: "groupchat",
            archivedId: "archive-legacy",
            messageId: "message-legacy",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            fallbackBody: "Legacy",
            senderJid: nil,
            senderNickname: nil,
            senderUserId: nil
        )
        let canonical = LocalMessageNotificationPreviewFactory.make(
            originalStanzaXML: nil,
            owner: owner,
            routeJid: "stage@conference.example.com",
            conversationType: "group",
            archivedId: "archive-current",
            messageId: "message-current",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            fallbackBody: "Canonical",
            senderJid: nil,
            senderNickname: nil,
            senderUserId: "member-a"
        )

        XCTAssertEqual(legacy.route.conversationType, "regular")
        XCTAssertNil(legacy.route.groupchat)
        XCTAssertEqual(canonical.route.conversationType, "group")
        XCTAssertEqual(canonical.route.groupchat, "stage@conference.example.com")
        XCTAssertEqual(canonical.route.senderUserId, "member-a")
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
            <message type='chat' from='juliet@example.com/mobile' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='Stage@Conference.Example.COM/Group'/>
              <group xmlns='https://xabber.com/protocol/groups' privacy='incognito'/>
            </message>
            """
        )
        let userInfo = preview.route.userInfo()

        XCTAssertEqual(preview.route.kind, .groupInvite)
        XCTAssertEqual(preview.route.routeJid, "stage@conference.example.com")
        XCTAssertEqual(preview.route.groupchat, "stage@conference.example.com")
        XCTAssertNil(preview.route.inviterJid)
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

    func testMalformedCanonicalGroupInvitesAreRejectedByPushBoundary() throws {
        let malformed = [
            """
            <message type='groupchat' from='stage@conference.example.com' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.com'/>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.com'>
                <sender jid='juliet@example.com'/>
              </invite>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.com'/>
              <group xmlns='https://xabber.com/protocol/groups' privacy='private'/>
            </message>
            """,
            """
            <message type='chat' from='stage@conference.example.com' to='romeo@example.com'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='not-a-group-jid'/>
            </message>
            """
        ]

        for xml in malformed {
            XCTAssertNotEqual(
                parseOptionalArchivedMessage(xml)?.route.kind,
                .groupInvite,
                xml
            )
        }
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
        XCTAssertNil(request.anchor.authorId)
        XCTAssertEqual(request.anchor.sourceDate, Date(timeIntervalSince1970: 1_711_283_200))
        XCTAssertTrue(request.highlight)
        XCTAssertTrue(request.markReadOnVisible)
    }

    func testMessageRouteWithoutTimestampNeverFabricatesTapTimeDateFallback() throws {
        let stableIdRoute = PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: "juliet@example.com",
            timestamp: nil,
            stanzaId: "archive-without-date"
        )
        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: stableIdRoute,
                fallbackConversationType: .regular
            )
        )
        XCTAssertNil(request.anchor.sourceDate)

        let noStableIdRoute = PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: "juliet@example.com",
            timestamp: nil
        )
        XCTAssertNil(PushNotificationMessageOpenRequestFactory.make(
            route: noStableIdRoute,
            fallbackConversationType: .regular
        ))

        let sentAt = Date(timeIntervalSince1970: 1_711_283_200)
        let datedRoute = PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: "juliet@example.com",
            timestamp: sentAt.timeIntervalSinceReferenceDate,
            messageId: "message-with-date"
        )
        XCTAssertEqual(
            PushNotificationMessageOpenRequestFactory.make(
                route: datedRoute,
                fallbackConversationType: .regular
            )?.anchor.sourceDate,
            sentAt
        )
    }

    func testLegacyMessageWithoutStableIdentityProducesTypedFallbackAndNeverExactSuccess() throws {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        AppRootCoordinator.active = nil
        let spy = LeftMenuAcknowledgementSpy()
        spy.acknowledgement = true
        NotifyManager.shared.leftMenuDelegate = spy
        let legacyUserInfo: [AnyHashable: Any] = [
            PushNotificationUserInfoKey.owner: owner,
            PushNotificationUserInfoKey.legacyJid: "juliet@example.com",
            PushNotificationUserInfoKey.conversationType: "regular"
        ]

        let decodedRoute = try XCTUnwrap(PushNotificationRoutePayload(userInfo: legacyUserInfo))
        XCTAssertEqual(decodedRoute.kind, .message)
        XCTAssertEqual(decodedRoute.owner, owner)
        XCTAssertEqual(decodedRoute.routeJid, "juliet@example.com")
        XCTAssertEqual(decodedRoute.conversationType, "regular")
        XCTAssertNil(decodedRoute.stanzaId)
        XCTAssertNil(decodedRoute.messageId)
        XCTAssertNil(decodedRoute.timestamp)
        XCTAssertNil(
            PushNotificationMessageOpenRequestFactory.make(
                route: decodedRoute,
                fallbackConversationType: .regular
            ),
            "An ID-less/date-less legacy payload must never fabricate an exact request"
        )

        var completionCount = 0
        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRoute(
            userInfo: legacyUserInfo,
            atStart: false,
            handler: { completionCount += 1 }
        ))

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(spy.openCount, 1)
        XCTAssertEqual(spy.receivedOwner, owner)
        XCTAssertEqual(spy.receivedJid, "juliet@example.com")
        XCTAssertEqual(spy.receivedConversationType, .regular)
        XCTAssertNil(spy.receivedRequest)
        XCTAssertEqual(spy.receivedNavigationSource, .notification)

        let effectPlan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: false,
            atStart: false
        )
        XCTAssertTrue(effectPlan.immediateEffects.isEmpty)
        XCTAssertFalse(effectPlan.sendsDisplayedImmediately)
        XCTAssertFalse(effectPlan.clearsUnread)
    }

    func testSemanticConversationTypeAliasesBuildTheMatchingExactMessageRequest() throws {
        let groupRequest = try makeExactMessageRequest(
            conversationType: "group",
            fallbackConversationType: .regular
        )
        let regularRequest = try makeExactMessageRequest(
            conversationType: "regular",
            fallbackConversationType: .group
        )

        XCTAssertEqual(groupRequest.conversationType, .group)
        XCTAssertEqual(regularRequest.conversationType, .regular)
    }

    func testNamespaceConversationTypeRemainsCompatibleWithExactMessageRequest() throws {
        let groupRequest = try makeExactMessageRequest(
            conversationType: ClientSynchronizationManager.ConversationType.group.rawValue,
            fallbackConversationType: .regular
        )
        let encryptedRequest = try makeExactMessageRequest(
            conversationType: ClientSynchronizationManager.ConversationType.omemo.rawValue,
            fallbackConversationType: .regular
        )

        XCTAssertEqual(groupRequest.conversationType, .group)
        XCTAssertEqual(encryptedRequest.conversationType, .omemo)
    }

    func testForegroundNotificationTapStillOpensTheExactMessageRoute() {
        let plan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: true,
            atStart: false
        )

        XCTAssertTrue(plan.opensChat)
        XCTAssertTrue(plan.immediateEffects.isEmpty)
        XCTAssertFalse(plan.sendsDisplayedImmediately)
        XCTAssertFalse(plan.clearsUnread)
        XCTAssertNil(plan.legacyFallbackAction)
    }

    func testBackgroundAndColdStartNotificationTapsRemainNavigationOnlyUntilTargetIsVisible() {
        let backgroundPlan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: false,
            atStart: false
        )
        let coldStartPlan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: false,
            atStart: true
        )

        XCTAssertTrue(backgroundPlan.opensChat)
        XCTAssertTrue(backgroundPlan.immediateEffects.isEmpty)
        XCTAssertFalse(backgroundPlan.sendsDisplayedImmediately)
        XCTAssertFalse(backgroundPlan.clearsUnread)
        XCTAssertNil(backgroundPlan.legacyFallbackAction)
        XCTAssertTrue(coldStartPlan.opensChat)
        XCTAssertTrue(coldStartPlan.immediateEffects.isEmpty)
        XCTAssertFalse(coldStartPlan.sendsDisplayedImmediately)
        XCTAssertFalse(coldStartPlan.clearsUnread)
        XCTAssertNil(coldStartPlan.legacyFallbackAction)
    }

    func testMissingNavigationDelegateDefersTheCompleteExactMessageRoute() throws {
        let exactRoute = try makeExactPendingChatRoute()
        var pendingState = MessageNotificationChatRoutePendingState()
        var attemptedRoute: MessageNotificationChatRoute?

        let opened = pendingState.openOrDefer(exactRoute) { route in
            attemptedRoute = route
            return false
        }

        XCTAssertFalse(opened)
        XCTAssertEqual(attemptedRoute, exactRoute)
        let deferredRoute = try XCTUnwrap(pendingState.pendingRoute)
        XCTAssertEqual(deferredRoute.owner, owner)
        XCTAssertEqual(deferredRoute.jid, "stage@conference.example.com")
        XCTAssertEqual(deferredRoute.conversationType, .group)
        let request = try XCTUnwrap(deferredRoute.openMessageRequest)
        XCTAssertEqual(request.owner, owner)
        XCTAssertEqual(request.chatJid, "stage@conference.example.com")
        XCTAssertEqual(request.conversationType, .group)
        XCTAssertEqual(request.anchor.archivedId, "1711283200000000")
        XCTAssertEqual(request.anchor.authorId, "member-a@example.com")
        XCTAssertEqual(request.anchor.sourceDate, Date(timeIntervalSince1970: 1_711_283_200))
        XCTAssertEqual(request.source, .pushNotification)
        XCTAssertTrue(request.highlight)
        XCTAssertTrue(request.markReadOnVisible)
    }

    func testDuplicateDeferredTapsCoalesceAndSuccessfulRetryConsumesTheRouteOnce() throws {
        let exactRoute = try makeExactPendingChatRoute()
        let duplicateRouteWithDifferentFallbackDate = try makeExactPendingChatRoute(
            sentAt: Date(timeIntervalSince1970: 1_711_283_230)
        )
        var pendingState = MessageNotificationChatRoutePendingState()
        var unavailableAttempts = 0

        XCTAssertFalse(pendingState.openOrDefer(exactRoute) { _ in
            unavailableAttempts += 1
            return false
        })
        XCTAssertFalse(pendingState.openOrDefer(duplicateRouteWithDifferentFallbackDate) { _ in
            unavailableAttempts += 1
            return false
        })

        XCTAssertEqual(unavailableAttempts, 1)
        XCTAssertEqual(pendingState.pendingRoute, exactRoute)
        var replayedRoutes: [MessageNotificationChatRoute] = []
        XCTAssertTrue(pendingState.retry { route in
            replayedRoutes.append(route)
            return true
        })
        XCTAssertNil(pendingState.pendingRoute)
        XCTAssertFalse(pendingState.retry { _ in
            XCTFail("A consumed notification route must not replay twice")
            return true
        })
        XCTAssertEqual(replayedRoutes, [exactRoute])
    }

    func testDifferentExactTargetSupersedesPendingGenerationWithoutReplayingTheStaleRoute() throws {
        let firstRoute = try makeExactPendingChatRoute(archivedId: "1711283200000000")
        let newerRoute = try makeExactPendingChatRoute(archivedId: "1711283200000001")
        var pendingState = MessageNotificationChatRoutePendingState()
        var attemptedRoutes: [MessageNotificationChatRoute] = []

        XCTAssertFalse(pendingState.openOrDefer(firstRoute) { route in
            attemptedRoutes.append(route)
            return false
        })
        XCTAssertFalse(pendingState.openOrDefer(newerRoute) { route in
            attemptedRoutes.append(route)
            return false
        })

        XCTAssertEqual(attemptedRoutes, [firstRoute, newerRoute])
        XCTAssertEqual(pendingState.pendingRoute, newerRoute)
        var replayedRoutes: [MessageNotificationChatRoute] = []
        XCTAssertTrue(pendingState.retry { route in
            replayedRoutes.append(route)
            return true
        })
        XCTAssertEqual(replayedRoutes, [newerRoute])
        XCTAssertNil(pendingState.pendingRoute)
    }

    func testFailedRetryKeepsExactRouteAndTapEffectsReadNeutral() throws {
        let exactRoute = try makeExactPendingChatRoute()
        var pendingState = MessageNotificationChatRoutePendingState()
        _ = pendingState.openOrDefer(exactRoute) { _ in false }
        let plan = MessageNotificationTapRoutingPolicy.plan(
            applicationIsActive: false,
            atStart: true
        )

        XCTAssertFalse(pendingState.retry { _ in false })

        XCTAssertEqual(pendingState.pendingRoute, exactRoute)
        XCTAssertTrue(plan.immediateEffects.isEmpty)
        XCTAssertFalse(plan.sendsDisplayedImmediately)
        XCTAssertFalse(plan.clearsUnread)
    }

    func testSuccessfulInitialNavigationLeavesNoDeferredFallback() throws {
        let exactRoute = try makeExactPendingChatRoute()
        var pendingState = MessageNotificationChatRoutePendingState()
        var openedRoute: MessageNotificationChatRoute?

        XCTAssertTrue(pendingState.openOrDefer(exactRoute) { route in
            openedRoute = route
            return true
        })

        XCTAssertEqual(openedRoute, exactRoute)
        XCTAssertNil(pendingState.pendingRoute)
    }

    func testExpandedSplitDelegateFalsePropagatesThroughAppRootWithoutConsumingExactRoute() throws {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.split.rawValue
        let spy = LeftMenuAcknowledgementSpy()
        NotifyManager.shared.leftMenuDelegate = spy
        let coordinator = AppRootCoordinator(window: UIWindow(), appDelegate: nil)
        let route = try makeExactPendingChatRoute()

        let accepted = coordinator.route(.chatMessage(
            owner: route.owner,
            jid: route.jid,
            conversationType: route.conversationType,
            openMessageRequest: route.openMessageRequest,
            configure: nil
        ))

        XCTAssertFalse(accepted)
        XCTAssertEqual(spy.receivedRequest, route.openMessageRequest)
        XCTAssertEqual(spy.receivedNavigationSource, .notification)
    }

    func testNotifyFallbackPropagatesExpandedSplitDelegateFalseWithFullExactRequest() throws {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        AppRootCoordinator.active = nil
        let spy = LeftMenuAcknowledgementSpy()
        NotifyManager.shared.leftMenuDelegate = spy
        let route = try makeExactPendingChatRoute()

        let accepted = NotifyManager.shared.openChatForNotification(
            owner: route.owner,
            jid: route.jid,
            conversationType: route.conversationType,
            openMessageRequest: route.openMessageRequest,
            configure: nil
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(spy.receivedRequest, route.openMessageRequest)
        XCTAssertEqual(spy.receivedNavigationSource, .notification)
    }

    func testMessageNotificationWithoutStableAnchorPreservesNotificationProvenance() {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        AppRootCoordinator.active = nil
        let spy = LeftMenuAcknowledgementSpy()
        NotifyManager.shared.leftMenuDelegate = spy

        XCTAssertFalse(NotifyManager.shared.openChatForNotification(
            owner: owner,
            jid: "juliet@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            configure: nil
        ))
        XCTAssertNil(spy.receivedRequest)
        XCTAssertEqual(spy.receivedNavigationSource, .notification)
    }

    func testMessageNotificationWithoutStableAnchorDoesNotGetConsumedByRootFallback() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.split.rawValue
        NotifyManager.shared.leftMenuDelegate = nil
        let coordinator = AppRootCoordinator(window: UIWindow(), appDelegate: nil)

        XCTAssertFalse(coordinator.routeNotificationChat(
            owner: owner,
            jid: "juliet@example.com",
            conversationType: .regular,
            openMessageRequest: nil,
            configure: nil
        ))
    }

    func testExpandedSplitRootStartupWithoutDelegateDefersExactPushRoute() throws {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.split.rawValue
        NotifyManager.shared.leftMenuDelegate = nil
        let coordinator = AppRootCoordinator(window: UIWindow(), appDelegate: nil)
        let route = try makeExactPendingChatRoute()

        XCTAssertFalse(coordinator.route(.chatMessage(
            owner: route.owner,
            jid: route.jid,
            conversationType: route.conversationType,
            openMessageRequest: route.openMessageRequest,
            configure: nil
        )))
    }

    func testPresentedModalDefersExactPushBeforeCallingExpandedSplitDelegate() throws {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.split.rawValue
        let spy = LeftMenuAcknowledgementSpy()
        spy.acknowledgement = true
        NotifyManager.shared.leftMenuDelegate = spy
        let coordinator = AppRootCoordinator(window: UIWindow(), appDelegate: nil)
        coordinator.currentPresentedVc = UIViewController()
        let route = try makeExactPendingChatRoute()

        XCTAssertFalse(coordinator.route(.chatMessage(
            owner: route.owner,
            jid: route.jid,
            conversationType: route.conversationType,
            openMessageRequest: route.openMessageRequest,
            configure: nil
        )))
        XCTAssertNil(spy.receivedRequest)
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

    func testSentCarbonUsesInnerMessageForCanonicalExactOpenRequest() throws {
        let sentAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2018-04-18T12:00:00Z")
        )
        let preview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: """
                <message from='romeo@example.com/laptop' to='romeo@example.com/ios' type='chat'>
                  <sent xmlns='urn:xmpp:carbons:2'>
                    <forwarded xmlns='urn:xmpp:forward:0'>
                      <delay xmlns='urn:xmpp:delay' stamp='2018-04-18T12:00:00Z'/>
                      <message from='romeo@example.com/laptop' to='juliet@example.com/mobile' type='chat' id='own-carbon-1'>
                        <body>Sent while the phone was sleeping</body>
                        <stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.com' id='own-archive-1'/>
                      </message>
                    </forwarded>
                  </sent>
                </message>
                """,
                owner: owner
            )
        )
        let decodedRoute = try XCTUnwrap(
            PushNotificationRoutePayload(
                userInfo: preview.route.userInfo(
                    timestamp: sentAt.addingTimeInterval(3_600).timeIntervalSinceReferenceDate
                )
            )
        )
        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: decodedRoute,
                fallbackConversationType: .regular
            )
        )

        XCTAssertEqual(decodedRoute.routeJid, "juliet@example.com")
        XCTAssertEqual(decodedRoute.senderJid, owner)
        XCTAssertEqual(decodedRoute.messageId, "own-carbon-1")
        XCTAssertEqual(decodedRoute.stanzaId, "own-archive-1")
        XCTAssertEqual(decodedRoute.timestamp, sentAt.timeIntervalSinceReferenceDate)
        XCTAssertEqual(request.chatJid, "juliet@example.com")
        XCTAssertEqual(request.owner, owner)
        XCTAssertEqual(request.conversationType, .regular)
        XCTAssertEqual(request.anchor.archivedId, "own-archive-1")
        XCTAssertEqual(request.anchor.messageId, "own-carbon-1")
        XCTAssertNil(request.anchor.authorId)
        XCTAssertEqual(request.anchor.sourceDate, sentAt)
        XCTAssertEqual(request.source, .pushNotification)
        XCTAssertTrue(request.highlight)
        XCTAssertTrue(request.markReadOnVisible)
    }

    func testReceivedCarbonUsesInnerIncomingMessageAndForwardedDelay() throws {
        let receivedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2018-04-18T12:05:00Z")
        )
        let preview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: """
                <message from='romeo@example.com/laptop' to='romeo@example.com/ios' type='chat'>
                  <received xmlns='urn:xmpp:carbons:2'>
                    <forwarded xmlns='urn:xmpp:forward:0'>
                      <delay xmlns='urn:xmpp:delay' stamp='2018-04-18T12:05:00Z'/>
                      <message from='juliet@example.com/mobile' to='romeo@example.com/laptop' type='chat' id='received-carbon-1'>
                        <body>Received on another resource</body>
                        <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='received-archive-1'/>
                      </message>
                    </forwarded>
                  </received>
                </message>
                """,
                owner: owner
            )
        )

        XCTAssertEqual(preview.route.routeJid, "juliet@example.com")
        XCTAssertEqual(preview.route.senderJid, "juliet@example.com")
        XCTAssertEqual(preview.route.messageId, "received-carbon-1")
        XCTAssertEqual(preview.route.stanzaId, "received-archive-1")
        XCTAssertEqual(preview.route.timestamp, receivedAt.timeIntervalSinceReferenceDate)
        XCTAssertEqual(preview.body, "Received on another resource")
    }

    func testMalformedCarbonWrapperIsRejectedInsteadOfRoutingToOwner() {
        let malformedCarbon = """
        <message from='romeo@example.com/laptop' to='romeo@example.com/ios' type='chat'>
          <sent xmlns='urn:xmpp:carbons:2'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2018-04-18T12:00:00Z'/>
            </forwarded>
          </sent>
        </message>
        """

        XCTAssertNil(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: malformedCarbon,
                owner: owner
            )
        )
    }

    @MainActor
    func testDuplicateTapProducesOneNavigationAnchorAndReadVisibleEffect() throws {
        let conversation = ProductionPushConversationSeed(
            owner: "duplicate-owner-\(UUID().uuidString)@example.com",
            jid: "duplicate-peer@example.com",
            conversationType: .regular,
            primaryPrefix: "p16",
            archiveBase: 1_731_000_000_000_000,
            messageCount: 12,
            targetIndex: 7,
            targetIsUnread: true
        )
        let harness = try ProductionPushRouteHarness(
            conversations: [conversation]
        )
        defer { harness.tearDown() }
        let mutationAudit = try ProductionPushRealmMutationAudit(
            conversation: conversation
        )
        defer { mutationAudit.invalidate() }
        XCTAssertTrue(productionPushWaitUntil(timeout: 2) {
            mutationAudit.isReady
        })
        let destination = ProductionHeldChatViewController()
        harness.track(destination)
        let routeAccount = try XCTUnwrap(
            AccountManager.shared.find(for: conversation.owner)
        )
        let durableEventLock = NSLock()
        var durableReadEvents: [String] = []
        let appendDurableReadEvent: (String) -> Void = { event in
            durableEventLock.lock()
            durableReadEvents.append(event)
            durableEventLock.unlock()
        }
        let durableReadEventsSnapshot: () -> [String] = {
            durableEventLock.lock()
            defer { durableEventLock.unlock() }
            return durableReadEvents
        }
        routeAccount.messages.readMessageDurableMutationObserverForTests = {
            event in
            guard event.owner == conversation.owner,
                  event.primary == conversation.targetPrimary else {
                return
            }
            switch event.phase {
            case .attempted:
                appendDurableReadEvent("realm.attempted")
            case .committed:
                appendDurableReadEvent("realm.committed")
            }
        }
        destination.readBoundaryPrecommitBarrierForTests = { target in
            guard target.primary == conversation.targetPrimary else {
                return
            }
            appendDurableReadEvent("viewport.precommit")
        }
        defer {
            routeAccount.messages.readMessageDurableMutationObserverForTests = nil
            destination.readBoundaryPrecommitBarrierForTests = nil
        }
        var destinationFactoryCount = 0
        harness.lastChats.compactChatDestinationFactory = {
            destinationFactoryCount += 1
            return destination
        }
        let notificationRequest = conversation.notificationRequest(
            identifier: "p16-duplicate-tap"
        )
        var readStates = [try conversation.readState()]

        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRequest(
            notificationRequest,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            atStart: false,
            handler: nil
        ))
        readStates.append(try conversation.readState())
        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRequest(
            notificationRequest,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            atStart: false,
            handler: nil
        ))
        readStates.append(try conversation.readState())

        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            destination.hasPreparedProductionFirstFrame
        })
        let exactRequest = try XCTUnwrap(
            destination.productionOwnedOpenMessageRequest
        )
        XCTAssertEqual(exactRequest, conversation.expectedOpenRequest)
        XCTAssertEqual(destinationFactoryCount, 1)
        XCTAssertEqual(harness.navigationController.viewControllers.count, 1)
        XCTAssertEqual(
            destination.anchorTransactionGate.snapshot.transactionBeginCount,
            1,
            "two identical taps must own one semantic anchor transaction"
        )
        XCTAssertTrue(
            durableReadEventsSnapshot().allSatisfy {
                $0 == "viewport.precommit"
            },
            "pre-presentation geometry may reject a viewport attempt, but it must not attempt or commit a Realm read"
        )
        XCTAssertFalse(readStates.last?.targetIsRead == true)
        XCTAssertEqual(readStates.last?.chatUnread, 1)

        destination.releaseProductionFirstFrame()
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            harness.navigationController.topViewController === destination &&
                destination.anchorTransactionGate.snapshot
                    .lastTerminalOutcome == .positioned &&
                destination.pendingOpenMessageRequest == nil &&
                destination.activeAnchorExecutionState == nil
        })
        readStates.append(try conversation.readState())
        XCTAssertFalse(readStates.last?.targetIsRead == true)
        XCTAssertEqual(readStates.last?.chatUnread, 1)

        let traceContext = try XCTUnwrap(
            destination.chatOpenPerformanceTraceContext
        )
        let semanticTarget = try XCTUnwrap(
            destination.chatOpenPerformanceTraceTargetFingerprint
        )
        XCTAssertTrue(productionPushWaitUntil(timeout: 2) {
            destination.hasStableChatOpenAcknowledgement(
                for: conversation.expectedOpenRequest
            ) &&
                NotifyManager.shared
                    .performancePendingMessageNotificationChatRoute == nil
        })
        XCTAssertFalse(
            destination.consumeChatOpenStableFrame(
                context: traceContext,
                semanticTarget: semanticTarget,
                eligibility: .eligible
            ),
            "the production display link must already own the one stable-frame consume"
        )
        readStates.append(try conversation.readState())
        XCTAssertTrue(
            readStates.last?.targetIsRead == true,
            "the production viewport must mark the exact target only after the stable visible frame"
        )
        XCTAssertEqual(mutationAudit.targetModificationCount, 1)

        XCTAssertTrue(
            destination.readVisiblePresentationCoordinator
                .hasPresentationReceipt
        )
        let actualPresentation = destination.readVisiblePresentationSnapshot()
        XCTAssertTrue(actualPresentation.isApplicationActive)
        XCTAssertTrue(actualPresentation.isWindowAttached)
        XCTAssertTrue(actualPresentation.isWindowSceneForegroundActive)
        XCTAssertTrue(actualPresentation.isKeyWindow)
        XCTAssertTrue(actualPresentation.isTopNavigationDestination)
        XCTAssertFalse(actualPresentation.hasCoveringPresentation)
        XCTAssertFalse(actualPresentation.isTransitionActive)
        XCTAssertTrue(
            destination.messagesCollectionView.collectionViewLayout
                is MessagesCollectionViewFlowLayout,
            "P16 must retain the production message layout"
        )
        destination.messagesCollectionView.layoutIfNeeded()
        let targetSection = try XCTUnwrap(
            destination.datasourceSnapshot.primaryIndex[
                conversation.targetPrimary
            ]
        )
        let targetIndexPath = IndexPath(item: 0, section: targetSection)
        XCTAssertEqual(
            destination.meaningfullyVisibleRealMessagePrimariesForRead(
                indexPaths: [targetIndexPath]
            ),
            [conversation.targetPrimary],
            "the production layout must make the exact target meaningfully visible"
        )
        XCTAssertFalse(destination.advanceReadBoundaryFromVisibleMessages(
            indexPaths: [targetIndexPath]
        ))
        readStates.append(try conversation.readState())
        XCTAssertTrue(readStates.last?.targetIsRead == true)
        XCTAssertFalse(destination.flushPendingVisibleReadTarget())
        readStates.append(try conversation.readState())
        XCTAssertTrue(readStates.last?.targetIsRead == true)
        XCTAssertEqual(
            readStates.last?.chatUnread,
            1,
            "reading an exact target before the synchronization snapshot edge must not falsely clear the server unread boundary"
        )
        XCTAssertEqual(readStates.last?.syncUnread, 1)
        let targetModificationsAfterRead =
            mutationAudit.targetModificationCount
        let chatModificationsAfterRead = mutationAudit.chatModificationCount

        XCTAssertFalse(destination.consumeChatOpenStableFrame(
            context: traceContext,
            semanticTarget: semanticTarget,
            eligibility: .eligible
        ))
        readStates.append(try conversation.readState())
        XCTAssertFalse(destination.advanceReadBoundaryFromVisibleMessages(
            indexPaths: [targetIndexPath]
        ))
        XCTAssertFalse(destination.flushPendingVisibleReadTarget())
        readStates.append(try conversation.readState())
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.05)
        )
        XCTAssertEqual(
            mutationAudit.targetModificationCount,
            targetModificationsAfterRead
        )
        XCTAssertEqual(
            mutationAudit.chatModificationCount,
            chatModificationsAfterRead
        )
        XCTAssertEqual(
            mutationAudit.targetModificationCount,
            1,
            "the Realm observer must corroborate the one durable unread-to-read transition"
        )
        let durableEvents = durableReadEventsSnapshot()
        XCTAssertEqual(
            durableEvents.filter { $0 == "realm.attempted" }.count,
            1
        )
        XCTAssertEqual(
            durableEvents.filter { $0 == "realm.committed" }.count,
            1
        )
        XCTAssertEqual(
            Array(durableEvents.suffix(2)),
            ["realm.attempted", "realm.committed"],
            "one or more revocable viewport admissions must precede exactly one durable Realm transition"
        )
        XCTAssertTrue(
            durableEvents.dropLast(2).allSatisfy {
                $0 == "viewport.precommit"
            }
        )
        XCTAssertEqual(
            mutationAudit.events.filter { $0 == .targetModified }.count,
            1
        )

        let unreadToReadTransitions = zip(readStates, readStates.dropFirst())
            .filter { !$0.targetIsRead && $1.targetIsRead }
        XCTAssertEqual(
            unreadToReadTransitions.count,
            1,
            "every producer attempt is snapshotted; only the visible viewport owner may mutate Realm"
        )
        XCTAssertEqual(destinationFactoryCount, 1)
        XCTAssertEqual(harness.navigationController.viewControllers.count, 2)
        XCTAssertEqual(
            destination.anchorTransactionGate.snapshot.transactionBeginCount,
            1
        )
    }

    private func parseArchivedMessage(_ messageXML: String) throws -> PushNotificationPreview {
        try XCTUnwrap(parseOptionalArchivedMessage(messageXML))
    }

    private func makeExactPendingChatRoute(
        archivedId: String = "1711283200000000",
        sentAt: Date = Date(timeIntervalSince1970: 1_711_283_200)
    ) throws -> MessageNotificationChatRoute {
        let timestamp = sentAt.timeIntervalSinceReferenceDate
        let payload = LocalMessageNotificationRouteFactory.make(
            owner: owner,
            routeJid: "stage@conference.example.com",
            conversationType: "group",
            stanzaId: archivedId,
            senderJid: "member-a@example.com",
            senderNickname: "Mercutio"
        )
        let decodedRoute = try XCTUnwrap(
            PushNotificationRoutePayload(userInfo: payload.userInfo(timestamp: timestamp))
        )
        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: decodedRoute,
                fallbackConversationType: .regular
            )
        )
        return MessageNotificationChatRoute(
            owner: owner,
            jid: "stage@conference.example.com",
            conversationType: .group,
            openMessageRequest: request
        )
    }

    private func makeExactMessageRequest(
        conversationType: String,
        fallbackConversationType: ClientSynchronizationManager.ConversationType
    ) throws -> ChatOpenMessageRequest {
        let route = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: "stage@conference.example.com",
            conversationType: conversationType,
            stanzaId: "1711283200000000",
            messageId: nil,
            stanza: nil,
            senderJid: "member-a@example.com",
            senderNickname: "Mercutio",
            groupchat: "stage@conference.example.com"
        )
        return try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: route,
                fallbackConversationType: fallbackConversationType
            )
        )
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

final class PushNotificationSceneRoutingTests: XCTestCase {
    @MainActor
    func testRequestIngressRejectsUnsupportedCategoryAndMalformedPayloadWithoutDiagnostic() {
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
        defer {
            NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
        }
        var completionCount = 0
        let unsupportedContent = UNMutableNotificationContent()
        unsupportedContent.categoryIdentifier = "p03-unsupported-category"
        unsupportedContent.userInfo = ["owner": "owner@example.com"]
        let unsupportedRequest = UNNotificationRequest(
            identifier: "p03-invalid-category",
            content: unsupportedContent,
            trigger: nil
        )
        XCTAssertFalse(NotifyManager.shared.onTouchNotificationRequest(
            unsupportedRequest,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            atStart: false,
            handler: { completionCount += 1 }
        ))
        XCTAssertNil(
            NotifyManager.shared.notificationRequestRoutingIngressForTests
        )

        let malformedContent = UNMutableNotificationContent()
        malformedContent.categoryIdentifier =
            NotifyManager.notificationPushMessageCategory
        malformedContent.userInfo = [:]
        let malformedRequest = UNNotificationRequest(
            identifier: "p03-malformed-payload",
            content: malformedContent,
            trigger: nil
        )
        XCTAssertFalse(NotifyManager.shared.onTouchNotificationRequest(
            malformedRequest,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            atStart: false,
            handler: { completionCount += 1 }
        ))
        XCTAssertNil(
            NotifyManager.shared.notificationRequestRoutingIngressForTests
        )
        XCTAssertEqual(completionCount, 2)
    }

    @MainActor
    func testSuspendedTapPreservesOwnerConversationTypeAndExactTargetUntilVisible() throws {
        let conversation = ProductionPushConversationSeed(
            owner: "suspended-owner-\(UUID().uuidString)@example.com",
            jid: "suspended-room@conference.example.com",
            conversationType: .group,
            primaryPrefix: "p03",
            archiveBase: 1_732_000_000_000_000,
            messageCount: 10,
            targetIndex: 6,
            targetIsUnread: true,
            authorId: "suspended-member@example.com"
        )
        let harness = try ProductionPushRouteHarness(
            conversations: [conversation]
        )
        defer { harness.tearDown() }
        let destination = ProductionHeldChatViewController()
        destination.readVisiblePresentationSnapshotProvider = {
            .blockedForProductionPushTest
        }
        harness.track(destination)
        harness.lastChats.compactChatDestinationFactory = { destination }
        let beforeTap = try conversation.readState()
        let notificationRequest = conversation.notificationRequest(
            identifier: "p03-suspended-default-action"
        )
        var completionCount = 0

        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRequest(
            notificationRequest,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            atStart: false,
            handler: { completionCount += 1 }
        ))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(
            NotifyManager.shared.notificationRequestRoutingIngressForTests,
            NotificationRequestRoutingIngressSnapshot(
                requestIdentifier: notificationRequest.identifier,
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                atStart: false
            ),
            "ordinary AppDelegate response remains a suspended/default tap"
        )
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            destination.hasPreparedProductionFirstFrame
        })
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(
            NotifyManager.shared.notificationRequestRoutingIngressForTests,
            NotificationRequestRoutingIngressSnapshot(
                requestIdentifier: notificationRequest.identifier,
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                atStart: false
            ),
            "no second ingress may rescue the suspended tap before navigation"
        )

        let pendingRoute = try XCTUnwrap(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute
        )
        XCTAssertEqual(pendingRoute.owner, conversation.owner)
        XCTAssertEqual(pendingRoute.jid, conversation.jid)
        XCTAssertEqual(
            pendingRoute.conversationType,
            conversation.conversationType
        )
        XCTAssertEqual(
            pendingRoute.openMessageRequest,
            conversation.expectedOpenRequest
        )
        XCTAssertEqual(
            destination.productionOwnedOpenMessageRequest,
            conversation.expectedOpenRequest
        )
        XCTAssertTrue(AppRootCoordinator.active === harness.coordinator)
        let rootOwnership = try XCTUnwrap(
            harness.lastChats.chatOpenIntentOwnership
        )
        XCTAssertEqual(rootOwnership.target.owner, conversation.owner)
        XCTAssertEqual(rootOwnership.target.jid, conversation.jid)
        XCTAssertEqual(
            rootOwnership.target.conversationType,
            conversation.conversationType
        )
        XCTAssertEqual(
            rootOwnership.destinationIdentifier,
            ObjectIdentifier(destination)
        )
        XCTAssertEqual(
            rootOwnership.intent,
            .message(conversation.expectedOpenRequest)
        )
        XCTAssertEqual(rootOwnership.navigationSource, .notification)
        XCTAssertEqual(harness.navigationController.viewControllers.count, 1)
        XCTAssertEqual(try conversation.readState(), beforeTap)
        XCTAssertFalse(destination.hasStableChatOpenAcknowledgement(
            for: conversation.expectedOpenRequest
        ))

        destination.releaseProductionFirstFrame()
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            harness.navigationController.topViewController === destination &&
                destination.anchorTransactionGate.snapshot
                    .lastTerminalOutcome == .positioned &&
                destination.pendingOpenMessageRequest == nil &&
                destination.activeAnchorExecutionState == nil
        })
        XCTAssertEqual(try conversation.readState(), beforeTap)
        XCTAssertEqual(
            destination.productionOwnedOpenMessageRequest,
            conversation.expectedOpenRequest
        )

        let traceContext = try XCTUnwrap(
            destination.chatOpenPerformanceTraceContext
        )
        let semanticTarget = try XCTUnwrap(
            destination.chatOpenPerformanceTraceTargetFingerprint
        )
        XCTAssertEqual(
            semanticTarget,
            .message(conversation.expectedOpenRequest)
        )
        XCTAssertTrue(productionPushWaitUntil(timeout: 2) {
            destination.hasStableChatOpenAcknowledgement(
                for: conversation.expectedOpenRequest
            ) &&
                NotifyManager.shared
                    .performancePendingMessageNotificationChatRoute == nil
        })
        XCTAssertFalse(
            destination.consumeChatOpenStableFrame(
                context: traceContext,
                semanticTarget: semanticTarget,
                eligibility: .eligible
            ),
            "the production display link must already own the one stable-frame consume"
        )
        XCTAssertTrue(destination.hasStableChatOpenAcknowledgement(
            for: conversation.expectedOpenRequest
        ))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(
            NotifyManager.shared.notificationRequestRoutingIngressForTests,
            NotificationRequestRoutingIngressSnapshot(
                requestIdentifier: notificationRequest.identifier,
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                atStart: false
            )
        )
        XCTAssertEqual(try conversation.readState(), beforeTap)
        XCTAssertFalse(destination.consumeChatOpenStableFrame(
            context: traceContext,
            semanticTarget: semanticTarget,
            eligibility: .eligible
        ))
        XCTAssertEqual(try conversation.readState(), beforeTap)
    }

    @MainActor
    func testSceneLaunchIngressRoutesOneValidCanonicalRequestThroughTheRealCoordinator() throws {
        let conversation = ProductionPushConversationSeed(
            owner: "scene-launch-owner-\(UUID().uuidString)@example.com",
            jid: "scene-launch-room@conference.example.com",
            conversationType: .group,
            primaryPrefix: "p03-scene-launch",
            archiveBase: 1_732_100_000_000_000,
            messageCount: 9,
            targetIndex: 5,
            targetIsUnread: true,
            authorId: "scene-launch-member@example.com"
        )
        let harness = try ProductionPushRouteHarness(
            conversations: [conversation]
        )
        defer { harness.tearDown() }
        let destination = ProductionHeldChatViewController()
        destination.readVisiblePresentationSnapshotProvider = {
            .blockedForProductionPushTest
        }
        harness.track(destination)
        harness.lastChats.compactChatDestinationFactory = { destination }
        let request = conversation.notificationRequest(
            identifier: "p03-scene-launch-default-action"
        )

        XCTAssertTrue(harness.coordinator.routeSceneNotificationRequest(
            request,
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ))
        XCTAssertEqual(
            NotifyManager.shared.notificationRequestRoutingIngressForTests,
            NotificationRequestRoutingIngressSnapshot(
                requestIdentifier: request.identifier,
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                atStart: true
            )
        )
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            destination.hasPreparedProductionFirstFrame
        })
        let pendingRoute = try XCTUnwrap(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute
        )
        XCTAssertEqual(pendingRoute.owner, conversation.owner)
        XCTAssertEqual(pendingRoute.jid, conversation.jid)
        XCTAssertEqual(
            pendingRoute.conversationType,
            conversation.conversationType
        )
        XCTAssertEqual(
            pendingRoute.openMessageRequest,
            conversation.expectedOpenRequest
        )
        XCTAssertEqual(
            destination.productionOwnedOpenMessageRequest,
            conversation.expectedOpenRequest
        )
        let ownership = try XCTUnwrap(
            harness.lastChats.chatOpenIntentOwnership
        )
        XCTAssertEqual(ownership.target.owner, conversation.owner)
        XCTAssertEqual(ownership.target.jid, conversation.jid)
        XCTAssertEqual(
            ownership.target.conversationType,
            conversation.conversationType
        )
        XCTAssertEqual(
            ownership.intent,
            .message(conversation.expectedOpenRequest)
        )
        XCTAssertEqual(ownership.navigationSource, .notification)

        destination.releaseProductionFirstFrame()
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            harness.navigationController.topViewController === destination &&
                destination.anchorTransactionGate.snapshot
                    .lastTerminalOutcome == .positioned &&
                destination.pendingOpenMessageRequest == nil &&
                destination.activeAnchorExecutionState == nil
        })
        let traceContext = try XCTUnwrap(
            destination.chatOpenPerformanceTraceContext
        )
        let semanticTarget = try XCTUnwrap(
            destination.chatOpenPerformanceTraceTargetFingerprint
        )
        XCTAssertEqual(
            semanticTarget,
            .message(conversation.expectedOpenRequest)
        )
        XCTAssertTrue(productionPushWaitUntil(timeout: 2) {
            destination.hasStableChatOpenAcknowledgement(
                for: conversation.expectedOpenRequest
            ) &&
                NotifyManager.shared
                    .performancePendingMessageNotificationChatRoute == nil
        })
        XCTAssertFalse(
            destination.consumeChatOpenStableFrame(
                context: traceContext,
                semanticTarget: semanticTarget,
                eligibility: .eligible
            ),
            "the production display link must already own the one stable-frame consume"
        )

        let appRootSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "xabber/application/AppRootCoordinator.swift"
            )
        let appRootSource = try String(
            contentsOf: appRootSourceURL,
            encoding: .utf8
        )
        let startBegin = try XCTUnwrap(
            appRootSource.range(
                of: "func start(connectionOptions: UIScene.ConnectionOptions"
            )
        )
        let startEnd = try XCTUnwrap(
            appRootSource.range(
                of: "func rebuildRoot(userInfo:",
                range: startBegin.upperBound..<appRootSource.endIndex
            )
        )
        let startSource = String(
            appRootSource[startBegin.lowerBound..<startEnd.lowerBound]
        )
        XCTAssertTrue(startSource.contains(
            "_ = routeSceneNotificationRequest("
        ))
        XCTAssertTrue(startSource.contains(
            "launchNotificationResponse.notification.request"
        ))
        XCTAssertTrue(startSource.contains(
            "actionIdentifier: launchNotificationResponse.actionIdentifier"
        ))
    }
}

final class CrossAccountPushRoutingTests: XCTestCase {
    @MainActor
    func testPushForOtherOwnerSwitchesAccountAndPublishesZeroOldConversationRows() throws {
        let ownerA = "visible-a-\(UUID().uuidString)@example.com"
        let ownerB = "push-b-\(UUID().uuidString)@example.com"
        let conversationA = ProductionPushConversationSeed(
            owner: ownerA,
            jid: "visible-a-peer@example.com",
            conversationType: .regular,
            primaryPrefix: "p17-a",
            archiveBase: 1_733_000_000_000_000,
            messageCount: 9,
            targetIndex: 8,
            targetIsUnread: false
        )
        let conversationB = ProductionPushConversationSeed(
            owner: ownerB,
            jid: "push-b-peer@example.com",
            conversationType: .regular,
            primaryPrefix: "p17-b",
            archiveBase: 1_734_000_000_000_000,
            messageCount: 11,
            targetIndex: 5,
            targetIsUnread: true
        )
        let harness = try ProductionPushRouteHarness(
            conversations: [conversationA, conversationB]
        )
        defer { harness.tearDown() }

        let visibleA = ChatViewController()
        visibleA.owner = conversationA.owner
        visibleA.jid = conversationA.jid
        visibleA.conversationType = conversationA.conversationType
        visibleA.readVisiblePresentationSnapshotProvider = {
            .blockedForProductionPushTest
        }
        harness.track(visibleA)
        harness.navigationController.setViewControllers(
            [harness.lastChats, visibleA],
            animated: false
        )
        visibleA.loadViewIfNeeded()
        harness.navigationController.view.layoutIfNeeded()
        visibleA.view.layoutIfNeeded()
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            visibleA.datasource.contains {
                $0.primary == conversationA.targetPrimary
            }
        })
        let visibleATarget = LastChatsNavigationSingleFlightCoordinator.Target(
            owner: conversationA.owner,
            jid: conversationA.jid,
            conversationType: conversationA.conversationType
        )
        let visibleAToken = UUID()
        _ = harness.lastChats.chatNavigationSingleFlight.request(
            target: visibleATarget,
            token: visibleAToken
        )
        XCTAssertTrue(harness.lastChats.chatNavigationSingleFlight.markPushing(
            token: visibleAToken,
            target: visibleATarget
        ))
        XCTAssertTrue(harness.lastChats.chatNavigationSingleFlight.markPresented(
            token: visibleAToken,
            target: visibleATarget
        ))

        let recorder = ProductionChatPublicationRecorder()
        let collectionView = ProductionRecordingMessagesCollectionView(
            recorder: recorder
        )
        let destinationB = ProductionHeldChatViewController(
            recordingCollectionView: collectionView
        )
        destinationB.readVisiblePresentationSnapshotProvider = {
            .blockedForProductionPushTest
        }
        collectionView.observe(destinationB)
        recorder.beginRecording()
        harness.track(destinationB)
        var destinationFactoryCount = 0
        harness.lastChats.compactChatDestinationFactory = {
            destinationFactoryCount += 1
            return destinationB
        }
        let notificationRequest = conversationB.notificationRequest(
            identifier: "p17-owner-b-default-action"
        )

        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRequest(
            notificationRequest,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            atStart: false,
            handler: nil
        ))
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            destinationB.hasPreparedProductionFirstFrame
        })
        let targetB = LastChatsNavigationSingleFlightCoordinator.Target(
            owner: conversationB.owner,
            jid: conversationB.jid,
            conversationType: conversationB.conversationType
        )
        let accountB = try XCTUnwrap(
            AccountManager.shared.find(for: conversationB.owner)
        )
        let resolvedBEpoch = harness.lastChats
            .chatNavigationAccountEpochResolver(targetB)
        XCTAssertTrue(resolvedBEpoch.isValidForChatNavigation)
        XCTAssertEqual(
            resolvedBEpoch.accountIdentifier,
            ObjectIdentifier(accountB)
        )
        let retainedEpoch = try XCTUnwrap(
            harness.lastChats.retainedCompactChatNavigationDestination?
                .accountEpoch
        )
        XCTAssertTrue(retainedEpoch.isExactValidMatch(for: resolvedBEpoch))
        let retainedBDestination = try XCTUnwrap(
            harness.lastChats.retainedCompactChatNavigationDestination
        )
        XCTAssertEqual(retainedBDestination.target, targetB)
        XCTAssertTrue(retainedBDestination.controller === destinationB)
        XCTAssertEqual(
            retainedBDestination.accountEpoch?.accountIdentifier,
            ObjectIdentifier(accountB)
        )
        let ownerBIntent = try XCTUnwrap(
            harness.lastChats.chatOpenIntentOwnership
        )
        XCTAssertEqual(ownerBIntent.target, targetB)
        XCTAssertEqual(
            ownerBIntent.destinationIdentifier,
            ObjectIdentifier(destinationB)
        )
        XCTAssertEqual(
            ownerBIntent.intent,
            .message(conversationB.expectedOpenRequest)
        )
        XCTAssertEqual(ownerBIntent.navigationSource, .notification)
        XCTAssertEqual(
            harness.lastChats.selectedChatIdentity,
            LastChatsViewController.SelectedChatIdentity(
                jid: conversationB.jid,
                owner: conversationB.owner,
                conversationType: conversationB.conversationType
            )
        )
        XCTAssertEqual(destinationFactoryCount, 1)
        XCTAssertEqual(
            destinationB.productionOwnedOpenMessageRequest,
            conversationB.expectedOpenRequest
        )
        XCTAssertEqual(destinationB.owner, conversationB.owner)
        XCTAssertEqual(destinationB.jid, conversationB.jid)
        XCTAssertEqual(
            destinationB.conversationType,
            conversationB.conversationType
        )

        destinationB.releaseProductionFirstFrame()
        XCTAssertTrue(productionPushWaitUntil(timeout: 5) {
            harness.navigationController.topViewController === destinationB &&
                destinationB.anchorTransactionGate.snapshot
                    .lastTerminalOutcome == .positioned &&
                destinationB.pendingOpenMessageRequest == nil &&
                destinationB.activeAnchorExecutionState == nil
        })
        let traceContext = try XCTUnwrap(
            destinationB.chatOpenPerformanceTraceContext
        )
        let semanticTarget = try XCTUnwrap(
            destinationB.chatOpenPerformanceTraceTargetFingerprint
        )
        XCTAssertTrue(productionPushWaitUntil(timeout: 2) {
            destinationB.hasStableChatOpenAcknowledgement(
                for: conversationB.expectedOpenRequest
            ) &&
                NotifyManager.shared
                    .performancePendingMessageNotificationChatRoute == nil
        })
        XCTAssertFalse(
            destinationB.consumeChatOpenStableFrame(
                context: traceContext,
                semanticTarget: semanticTarget,
                eligibility: .eligible
            ),
            "the production display link must already own the one stable-frame consume"
        )

        XCTAssertTrue(destinationB.timelineSession?.isConfigured(
            for: ChatTimelineConversationKey(
                owner: conversationB.owner,
                jid: conversationB.jid,
                conversationType: conversationB.conversationType
            )
        ) == true)
        XCTAssertEqual(destinationFactoryCount, 1)
        XCTAssertEqual(harness.navigationController.viewControllers.count, 3)
        XCTAssertFalse(recorder.frames.isEmpty)
        XCTAssertTrue(recorder.frames.contains { $0.boundary == .datasource })
        XCTAssertTrue(recorder.frames.contains { $0.boundary == .reload })
        XCTAssertTrue(recorder.frames.contains { $0.boundary == .layout })
        XCTAssertFalse(
            recorder.frames.contains { $0.boundary == .offset },
            "the bounded local frame already fits the viewport and must not create an unnecessary visible offset mutation"
        )
        XCTAssertTrue(recorder.frames.contains {
            $0.primaries.contains(conversationB.targetPrimary)
        })
        let forbiddenAPrimaries = Set(conversationA.messagePrimaries)
        recorder.frames.forEach { frame in
            XCTAssertEqual(frame.controllerOwner, conversationB.owner)
            XCTAssertEqual(frame.controllerJid, conversationB.jid)
            XCTAssertEqual(
                frame.conversationType,
                conversationB.conversationType
            )
            XCTAssertTrue(
                forbiddenAPrimaries.isDisjoint(with: frame.primaries),
                "\(frame.boundary) published an owner-A row during the owner-B route"
            )
            XCTAssertTrue(frame.rowOwners.allSatisfy {
                $0 == conversationB.owner
            })
            XCTAssertTrue(frame.rowJids.allSatisfy {
                $0 == conversationB.jid
            })
        }
    }
}

private struct ProductionPushConversationSeed {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let primaryPrefix: String
    let archiveBase: Int64
    let messageCount: Int
    let targetIndex: Int
    let targetIsUnread: Bool
    let authorId: String

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        primaryPrefix: String,
        archiveBase: Int64,
        messageCount: Int,
        targetIndex: Int,
        targetIsUnread: Bool,
        authorId: String? = nil
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.primaryPrefix = "\(primaryPrefix)-\(UUID().uuidString)"
        self.archiveBase = archiveBase
        self.messageCount = messageCount
        self.targetIndex = targetIndex
        self.targetIsUnread = targetIsUnread
        self.authorId = authorId ?? jid
    }

    var messagePrimaries: [String] {
        (0..<messageCount).map { "\(primaryPrefix)-primary-\($0)" }
    }

    var targetPrimary: String { messagePrimaries[targetIndex] }
    var targetArchivedId: String {
        String(archiveBase + Int64(targetIndex))
    }
    var targetMessageId: String {
        "\(primaryPrefix)-message-\(targetIndex)"
    }
    var targetDate: Date {
        Date(
            timeIntervalSince1970:
                TimeInterval(archiveBase + Int64(targetIndex)) / 1_000_000
        )
    }
    var notificationSourceDate: Date {
        Date(
            timeIntervalSinceReferenceDate:
                targetDate.timeIntervalSinceReferenceDate
        )
    }

    var expectedOpenRequest: ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: targetArchivedId,
                messageId: targetMessageId,
                authorId: conversationType == .group ? authorId : nil,
                bodyFingerprint: nil,
                sourceDate: notificationSourceDate
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .pushNotification
        )
    }

    func notificationRequest(identifier: String) -> UNNotificationRequest {
        let payload = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: jid,
            conversationType: conversationType == .group
                ? "group"
                : conversationType == .regular
                    ? "regular"
                    : conversationType.rawValue,
            stanzaId: targetArchivedId,
            messageId: targetMessageId,
            stanza: nil,
            senderJid: authorId,
            senderNickname: nil,
            groupchat: conversationType == .group ? jid : nil,
            timestamp: targetDate.timeIntervalSinceReferenceDate
        )
        let content = UNMutableNotificationContent()
        content.categoryIdentifier =
            NotifyManager.notificationPushMessageCategory
        content.userInfo = payload.userInfo(timestamp: payload.timestamp)
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
    }

    func persist(in realm: Realm) throws {
        precondition(messageCount > 0)
        precondition((0..<messageCount).contains(targetIndex))
        var messages: [MessageStorageItem] = []
        messages.reserveCapacity(messageCount)
        for index in 0..<messageCount {
            let message = MessageStorageItem()
            message.primary = messagePrimaries[index]
            message.owner = owner
            message.opponent = jid
            message.conversationType = conversationType
            message.archivedId = String(archiveBase + Int64(index))
            message.messageId = "\(primaryPrefix)-message-\(index)"
            message.body = "Production push row \(index)"
            message.legacyBody = message.body
            message.date = Date(
                timeIntervalSince1970:
                    TimeInterval(archiveBase + Int64(index)) / 1_000_000
            )
            message.sentDate = message.date
            message.outgoing = false
            message.displayAs = .text
            let isUnreadTarget = targetIsUnread && index == targetIndex
            message.isRead = !isUnreadTarget
            message.state = isUnreadTarget ? .deliver : .read
            message.readDate = isUnreadTarget
                ? -1
                : message.date.timeIntervalSince1970 + 1
            messages.append(message)
            realm.add(message, update: .modified)
        }

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = conversationType
        chat.messageDate = messages.last?.date ?? targetDate
        chat.lastMessage = messages.last
        chat.lastMessageId = messages.last?.messageId ?? ""
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.fullArchiveLoaded = true
        chat.isAllHistoryLoaded = true
        chat.syncUnreadCount = targetIsUnread ? 1 : 0
        chat.runtimeUnreadCount = 0
        chat.unread = targetIsUnread ? 1 : 0
        chat.syncUnreadAfterId = targetIsUnread && targetIndex > 0
            ? messages[targetIndex - 1].archivedId
            : messages.last?.archivedId
        chat.lastReadId = chat.syncUnreadAfterId
        chat.syncSnapshotLastArchiveId = messages.last?.archivedId
        chat.lastLoadedMessageHistoryId = messages.first?.archivedId
        realm.add(chat, update: .modified)

        let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            in: realm
        )
        if let first = messages.first?.archivedId,
           let last = messages.last?.archivedId {
            archiveState.mergeLoadedRange(
                first: first,
                last: last,
                updateKind: .bootstrapNewest
            )
        }
        archiveState.olderArchiveEndReached = true
        archiveState.newerLiveEdgeReached = true
        archiveState.lastSnapshotArchiveId = messages.last?.archivedId
        archiveState.lastSnapshotMessageId = messages.last?.messageId
        archiveState.lastSnapshotSenderId = authorId
        archiveState.lastSnapshotDate = messages.last?.date
    }

    func readState() throws -> ProductionPushRealmReadState {
        let realm = try WRealm.safe()
        let message = try XCTUnwrap(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: targetPrimary
            )
        )
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
            )
        )
        return ProductionPushRealmReadState(
            targetIsRead: message.isRead,
            targetStateRawValue: message.state_,
            targetReadDate: message.readDate,
            chatUnread: chat.unread,
            syncUnread: chat.syncUnreadCount,
            runtimeUnread: chat.runtimeUnreadCount,
            lastReadId: chat.lastReadId,
            displayedId: chat.displayedId
        )
    }
}

private struct ProductionPushRealmReadState: Equatable {
    let targetIsRead: Bool
    let targetStateRawValue: Int
    let targetReadDate: Double
    let chatUnread: Int
    let syncUnread: Int
    let runtimeUnread: Int
    let lastReadId: String?
    let displayedId: String?
}

private final class ProductionPushRealmMutationAudit {
    enum Event: Equatable {
        case targetModified
        case chatModified
    }

    private let realm: Realm
    private var targetToken: NotificationToken?
    private var chatToken: NotificationToken?
    private var targetInitialDelivered = false
    private var chatInitialDelivered = false
    private(set) var targetModificationCount = 0
    private(set) var chatModificationCount = 0
    private(set) var events: [Event] = []

    var isReady: Bool {
        targetInitialDelivered && chatInitialDelivered
    }

    init(conversation: ProductionPushConversationSeed) throws {
        realm = try WRealm.safe()
        targetToken = realm.objects(MessageStorageItem.self)
            .filter("primary == %@", conversation.targetPrimary)
            .observe { [weak self] change in
                guard let self else { return }
                switch change {
                case .initial:
                    self.targetInitialDelivered = true
                case .update(_, _, _, let modifications):
                    guard !modifications.isEmpty else { return }
                    self.targetModificationCount += 1
                    self.events.append(.targetModified)
                case .error(let error):
                    XCTFail(
                        "target Realm mutation observation failed: \(error)"
                    )
                }
            }
        let chatPrimary = LastChatsStorageItem.genPrimary(
            jid: conversation.jid,
            owner: conversation.owner,
            conversationType: conversation.conversationType
        )
        chatToken = realm.objects(LastChatsStorageItem.self)
            .filter("primary == %@", chatPrimary)
            .observe { [weak self] change in
                guard let self else { return }
                switch change {
                case .initial:
                    self.chatInitialDelivered = true
                case .update(_, _, _, let modifications):
                    guard !modifications.isEmpty else { return }
                    self.chatModificationCount += 1
                    self.events.append(.chatModified)
                case .error(let error):
                    XCTFail(
                        "chat Realm mutation observation failed: \(error)"
                    )
                }
            }
    }

    func invalidate() {
        targetToken?.invalidate()
        chatToken?.invalidate()
        targetToken = nil
        chatToken = nil
    }
}

@MainActor
private final class ProductionPushRouteHarness {
    let coordinator: AppRootCoordinator
    let window: UIWindow
    let navigationController: UINavigationController
    let lastChats: LastChatsViewController

    private let previousRealmConfiguration: Realm.Configuration
    private let previousActiveCoordinator: AppRootCoordinator?
    private let previousInterfaceType: String
    private let previousLeftMenuDelegate: LeftMenuSelectRootScreenDelegate?
    private let previousUsers: [Account]
    private let previousActiveUsers: Set<String>
    private let previousAuthenticatedUsers: Set<String>
    private let previousConnectingUsers: Set<String>
    private weak var previousKeyWindow: UIWindow?
    private var trackedChats: [ChatViewController] = []
    private var didTearDown = false

    init(conversations: [ProductionPushConversationSeed]) throws {
        let savedRealmConfiguration = Realm.Configuration.defaultConfiguration
        let savedActiveCoordinator = AppRootCoordinator.active
        let savedInterfaceType =
            CommonConfigManager.shared.config.interface_type
        let savedLeftMenuDelegate = NotifyManager.shared.leftMenuDelegate
        let savedUsers = AccountManager.shared.users
        let savedActiveUsers = AccountManager.shared.activeUsers.value
        let savedAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let savedConnectingUsers =
            AccountManager.shared.connectingUsers.value
        previousRealmConfiguration = savedRealmConfiguration
        previousActiveCoordinator = savedActiveCoordinator
        previousInterfaceType = savedInterfaceType
        previousLeftMenuDelegate = savedLeftMenuDelegate
        previousUsers = savedUsers
        previousActiveUsers = savedActiveUsers
        previousAuthenticatedUsers = savedAuthenticatedUsers
        previousConnectingUsers = savedConnectingUsers

        let windowScene = try requireHostedForegroundWindowScene()
        previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        var didCompleteInitialization = false
        defer {
            if !didCompleteInitialization {
                NotifyManager.shared
                    .resetPendingMessageNotificationChatRouteForTesting()
                NotifyManager.shared.leftMenuDelegate = savedLeftMenuDelegate
                AccountManager.shared.users.removeAll()
                AccountManager.shared.users = savedUsers
                AccountManager.shared.activeUsers.accept(savedActiveUsers)
                AccountManager.shared.authenticatedUsers.accept(
                    savedAuthenticatedUsers
                )
                AccountManager.shared.connectingUsers.accept(
                    savedConnectingUsers
                )
                CommonConfigManager.shared.config.interface_type =
                    savedInterfaceType
                AppRootCoordinator.active = savedActiveCoordinator
                ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
                MessageArchiveEndPageDispatcher.resetForTests()
                MessageArchiveRequestFailureDispatcher.resetForTests()
                Realm.Configuration.defaultConfiguration =
                    savedRealmConfiguration
            }
        }

        Realm.Configuration.defaultConfiguration =
            makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "ProductionPushRouteHarness-\(UUID().uuidString)"
            )
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.tabs.rawValue

        let realm = try WRealm.safe()
        try realm.write {
            for owner in Set(conversations.map(\.owner)) {
                let account = AccountStorageItem()
                account.jid = owner
                account.username = owner
                account.enabled = true
                account.savePassword = false
                realm.add(account, update: .modified)
            }
            try conversations.forEach { try $0.persist(in: realm) }
        }
        for owner in Set(conversations.map(\.owner)) {
            AccountManager.shared.add(withJid: owner, autoConnect: false)
        }

        window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        coordinator.rebuildRoot(userInfo: nil)
        let tabController = try XCTUnwrap(
            coordinator.tabController as? XabberTabBarViewController
        )
        navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as? UINavigationController
        )
        lastChats = try XCTUnwrap(
            navigationController.viewControllers.first
                as? LastChatsViewController
        )
        window.makeKeyAndVisible()
        tabController.selectedIndex = 0
        tabController.loadViewIfNeeded()
        navigationController.loadViewIfNeeded()
        lastChats.loadViewIfNeeded()
        window.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()
        lastChats.view.layoutIfNeeded()
        _ = productionPushWaitUntil(timeout: 2) {
            self.lastChats.isAppeared && self.window.isKeyWindow
        }
        didCompleteInitialization = true
    }

    func track(_ chat: ChatViewController) {
        trackedChats.append(chat)
    }

    func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        trackedChats.forEach {
            $0.datasourceDidSetForTests = nil
            $0.performTerminalChatResourceTeardownForTesting()
        }
        lastChats.resetChatNavigationTransaction(cancelled: true)
        lastChats.unsubscribe()
        window.isHidden = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        window.rootViewController = nil
        coordinator.sceneDidDisconnect()
        previousKeyWindow?.makeKey()
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
        NotifyManager.shared.leftMenuDelegate = previousLeftMenuDelegate
        AccountManager.shared.users.removeAll()
        AccountManager.shared.users = previousUsers
        AccountManager.shared.activeUsers.accept(previousActiveUsers)
        AccountManager.shared.authenticatedUsers.accept(
            previousAuthenticatedUsers
        )
        AccountManager.shared.connectingUsers.accept(previousConnectingUsers)
        CommonConfigManager.shared.config.interface_type =
            previousInterfaceType
        AppRootCoordinator.active = previousActiveCoordinator
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
    }
}

@MainActor
private final class ProductionHeldChatViewController:
    ChatViewController,
    StackedNavigationPresentationPreparationControlling {
    private var heldPreparationHandle:
        StackedNavigationPresentationPreparationHandle?
    private(set) var hasPreparedProductionFirstFrame = false

    init(
        recordingCollectionView:
            ProductionRecordingMessagesCollectionView? = nil
    ) {
        super.init(nibName: nil, bundle: nil)
        if let recordingCollectionView {
            messagesCollectionView = recordingCollectionView
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func makeStackedNavigationPresentationPreparation(
        targetBounds: CGRect?,
        completion: @escaping () -> Void
    ) -> StackedNavigationPresentationPreparationHandle {
        let handle = StackedNavigationPresentationPreparationHandle(
            cancellation: { [weak self] in
                self?.cancelStackedNavigationPresentationPreparation()
            },
            completion: completion
        )
        heldPreparationHandle = handle
        super.prepareForStackedNavigationPresentation(
            targetBounds: targetBounds
        ) { [weak self] in
            self?.hasPreparedProductionFirstFrame = true
        }
        return handle
    }

    func releaseProductionFirstFrame() {
        guard hasPreparedProductionFirstFrame,
              let handle = heldPreparationHandle else {
            XCTFail("the real chat first frame must be ready before release")
            return
        }
        heldPreparationHandle = nil
        handle.finish()
    }

    var productionOwnedOpenMessageRequest: ChatOpenMessageRequest? {
        if let pendingOpenMessageRequest {
            return pendingOpenMessageRequest
        }
        if let request = activeAnchorExecutionState?.request {
            return request
        }
        guard case .message(let request)? =
                chatOpenPerformanceTraceTargetFingerprint else {
            return nil
        }
        return request
    }
}

private enum ProductionChatPublicationBoundary: String, Equatable {
    case datasource
    case reload
    case layout
    case offset
}

private struct ProductionChatPublicationFrame: Equatable {
    let boundary: ProductionChatPublicationBoundary
    let controllerOwner: String
    let controllerJid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let primaries: Set<String>
    let rowOwners: [String]
    let rowJids: [String]
}

@MainActor
private final class ProductionChatPublicationRecorder {
    private(set) var frames: [ProductionChatPublicationFrame] = []
    private var isRecording = false

    func beginRecording() {
        frames.removeAll(keepingCapacity: true)
        isRecording = true
    }

    func append(
        boundary: ProductionChatPublicationBoundary,
        controller: ChatViewController
    ) {
        guard isRecording else { return }
        let rows = controller.datasource
        frames.append(ProductionChatPublicationFrame(
            boundary: boundary,
            controllerOwner: controller.owner,
            controllerJid: controller.jid,
            conversationType: controller.conversationType,
            primaries: Set(rows.map(\.primary)),
            rowOwners: rows.map(\.owner),
            rowJids: rows.map(\.jid)
        ))
    }
}

@MainActor
private final class ProductionRecordingMessagesCollectionView:
    MessagesCollectionView {
    private let recorder: ProductionChatPublicationRecorder
    private weak var observedController: ChatViewController?

    init(recorder: ProductionChatPublicationRecorder) {
        self.recorder = recorder
        super.init(frame: .zero, collectionViewLayout: MessagesCollectionViewFlowLayout())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func observe(_ controller: ChatViewController) {
        observedController = controller
        controller.datasourceDidSetForTests = { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.recorder.append(
                boundary: .datasource,
                controller: controller
            )
        }
    }

    override func reloadData() {
        super.reloadData()
        record(.reload)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        record(.layout)
    }

    override func setContentOffset(
        _ contentOffset: CGPoint,
        animated: Bool
    ) {
        super.setContentOffset(contentOffset, animated: animated)
        record(.offset)
    }

    private func record(_ boundary: ProductionChatPublicationBoundary) {
        guard let observedController else { return }
        recorder.append(boundary: boundary, controller: observedController)
    }
}

private extension ChatReadVisiblePresentationSnapshot {
    static let blockedForProductionPushTest =
        ChatReadVisiblePresentationSnapshot(
            isApplicationActive: true,
            isWindowAttached: false,
            isWindowSceneForegroundActive: true,
            isKeyWindow: true,
            isTopNavigationDestination: false,
            isVisibleSplitSecondary: false,
            hasCoveringPresentation: false,
            isTransitionActive: false
        )

}

@MainActor
private func productionPushWaitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.01)
        )
    }
    return condition()
}
