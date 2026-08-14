import XCTest
import XMPPFramework
@testable import xabber

final class GroupStanzaRouterTests: XCTestCase {
    private let owner = "romeo@example.com"
    private let group = "stage@example.com"

    func testCorrelatedIQResultDecodesCanonicalSnapshotPayload() throws {
        let stanza = try iq("""
        <iq type='result' id='group-info-1'>
          <group xmlns='https://xabber.com/protocol/groups'
                 jid='Stage@Example.COM/Group' privacy='public'>
            <info><name>Stage</name></info>
          </group>
        </iq>
        """)

        let event = try GroupStanzaRouter.route(
            stanza,
            correlating: ["group-info-1"]
        )

        guard case let .iq(correlation)? = event,
              case let .result(.snapshot(snapshot)) = correlation.outcome else {
            return XCTFail("Expected a correlated canonical snapshot result")
        }
        XCTAssertEqual(correlation.requestID, "group-info-1")
        XCTAssertEqual(snapshot.jid, group)
        XCTAssertEqual(snapshot.info?.name, "Stage")
    }

    func testIQErrorPreservesConditionTextAndCanonicalCollisionPayload() throws {
        let stanza = try iq("""
        <iq type='error' id='p2p-1'>
          <group xmlns='https://xabber.com/protocol/groups' jid='existing@example.com'/>
          <error type='cancel'>
            <conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
            <text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Already exists</text>
          </error>
        </iq>
        """)

        let event = try GroupStanzaRouter.route(
            stanza,
            correlating: ["p2p-1"]
        )

        guard case let .iq(correlation)? = event,
              case let .error(error) = correlation.outcome else {
            return XCTFail("Expected a correlated IQ error")
        }
        XCTAssertEqual(error.condition, "conflict")
        XCTAssertEqual(error.text, "Already exists")
        XCTAssertEqual(error.type, "cancel")
        guard case let .snapshot(snapshot)? = error.payload else {
            return XCTFail("Expected the existing-group collision payload")
        }
        XCTAssertEqual(snapshot.jid, "existing@example.com")
    }

    func testCorrelatedIQDecodesInfoSettingsInvitesAndBlocklistPayloads() throws {
        let fixtures: [(String, String, GroupIQPayload)] = [
            (
                "info-1",
                "<info xmlns='https://xabber.com/protocol/groups'><name>Stage</name></info>",
                .info(GroupInfo(name: "Stage"))
            ),
            (
                "settings-1",
                "<settings xmlns='https://xabber.com/protocol/groups'><membership>private</membership></settings>",
                .settings(GroupSettings(membership: .privateGroup))
            ),
            (
                "invites-1",
                "<invites xmlns='https://xabber.com/protocol/groups'><jid>Juliet@Example.COM/Phone</jid></invites>",
                .invites(["juliet@example.com"])
            ),
            (
                "block-1",
                "<block xmlns='https://xabber.com/protocol/groups'><jid>Spam.Example.COM</jid></block>",
                .blocklist(["spam.example.com"])
            ),
            (
                "member-1",
                "<user xmlns='https://xabber.com/protocol/groups' id='member-7'><nickname>Juliet</nickname></user>",
                .member(GroupMember(id: "member-7", nickname: "Juliet"))
            )
        ]

        for (id, payloadXML, expectedPayload) in fixtures {
            let stanza = try iq("<iq type='result' id='\(id)'>\(payloadXML)</iq>")
            guard case let .iq(correlation)? = try GroupStanzaRouter.route(
                stanza,
                correlating: [id]
            ), case let .result(payload) = correlation.outcome else {
                return XCTFail("Expected correlated payload for \(id)")
            }
            XCTAssertEqual(payload, expectedPayload)
        }
    }

    func testUncorrelatedIQIsIgnored() throws {
        let canonical = try iq("""
        <iq type='result' id='other'>
          <group xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </iq>
        """)

        XCTAssertNil(try GroupStanzaRouter.route(canonical, correlating: ["expected"]))
    }

    func testCorrelatedForeignGroupIQIsRejectedByStrictCodec() throws {
        let legacy = try iq("""
        <iq type='result' id='legacy'>
          <group xmlns='http://xabber.com/protocol/groupchat' jid='stage@example.com'/>
        </iq>
        """)

        XCTAssertThrowsError(try GroupStanzaRouter.route(legacy, correlating: ["legacy"])) { error in
            guard case GroupProtocolCodecError.invalidNamespace = error else {
                return XCTFail("Expected strict namespace rejection, got \(error)")
            }
        }
    }

    func testSubscribedPresencePreservesWaitUntilReciprocalHandshake() throws {
        let stanza = try presence("""
        <presence type='subscribed' from='Stage@Example.COM/Group' to='romeo@example.com/ios'>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public' members='2'>
            <info><name>Stage</name></info>
          </group>
        </presence>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .reducer(input)? = event else {
            return XCTFail("Expected a reducer input")
        }
        XCTAssertEqual(input.groupJID, group)
        XCTAssertEqual(input.events.count, 1)
        guard case let .snapshot(snapshot) = input.events[0] else {
            return XCTFail("Expected an authoritative subscription snapshot")
        }
        XCTAssertEqual(snapshot.info?.name, "Stage")
        XCTAssertNil(input.requiredReply)
        XCTAssertEqual(input.eventsAfterReply, [])
        let state = input.events.reduce(
            GroupViewState(selfSubscription: .wait),
            GroupDomainReducer.reduce
        )
        XCTAssertEqual(state.selfSubscription, .wait)
    }

    func testIncomingSubscribeIsHandshakeAndDoesNotDowngradeActiveMembership() throws {
        let stanza = try presence("""
        <presence type='subscribe' from='stage@example.com/Group' to='romeo@example.com/ios'>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public' members='2'>
            <info><name>Stage</name></info>
          </group>
        </presence>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .reducer(input)? = event else {
            return XCTFail("Expected a reducer input")
        }
        XCTAssertEqual(input.events.count, 1)
        guard case let .snapshot(snapshot) = input.events[0] else {
            return XCTFail("Expected handshake snapshot without a subscription transition")
        }
        XCTAssertEqual(snapshot.info?.name, "Stage")
        XCTAssertFalse(input.events.contains(.selfSubscription(.wait)))
        XCTAssertEqual(input.requiredReply, .subscribed)
        XCTAssertEqual(input.eventsAfterReply, [.selfSubscription(.both)])

        let active = input.eventsAfterReply.reduce(
            GroupViewState(selfSubscription: .both),
            GroupDomainReducer.reduce
        )
        XCTAssertEqual(active.selfSubscription, .both)
    }

    func testJoinHandshakeActivatesOnlyAfterRequiredReplyIsSent() throws {
        let subscribed = try presence("""
        <presence type='subscribed' from='stage@example.com/Group'>
          <group xmlns='https://xabber.com/protocol/groups' members='2'/>
        </presence>
        """)
        let subscribe = try presence("""
        <presence type='subscribe' from='stage@example.com/Group'>
          <group xmlns='https://xabber.com/protocol/groups' members='2'/>
        </presence>
        """)

        guard case let .reducer(first)? = try GroupStanzaRouter.route(subscribed),
              case let .reducer(second)? = try GroupStanzaRouter.route(subscribe) else {
            return XCTFail("Expected both handshake legs")
        }
        let waiting = first.events.reduce(
            GroupViewState(selfSubscription: .wait),
            GroupDomainReducer.reduce
        )
        let beforeReply = second.events.reduce(waiting, GroupDomainReducer.reduce)
        XCTAssertEqual(beforeReply.selfSubscription, .wait)
        XCTAssertEqual(second.requiredReply, .subscribed)

        let afterReply = second.eventsAfterReply.reduce(
            beforeReply,
            GroupDomainReducer.reduce
        )
        XCTAssertEqual(afterReply.selfSubscription, .both)
    }

    func testAvailablePresenceProducesPartialPatchWithoutClearingAbsentFields() throws {
        let stanza = try presence("""
        <presence from='stage@example.com/Group' to='romeo@example.com/ios'>
          <group xmlns='https://xabber.com/protocol/groups' members='3'>
            <present>2</present>
          </group>
        </presence>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .reducer(input)? = event,
              case let .patch(patch) = input.events.first else {
            return XCTFail("Expected a partial presence patch")
        }
        XCTAssertEqual(patch.memberCount, .value(3))
        XCTAssertEqual(patch.presentCount, .value(2))
        XCTAssertEqual(patch.info, .absent)
        XCTAssertEqual(patch.settings, .absent)
    }

    func testUnsubscribedPresenceProducesNoneBeforeTrailingPatch() throws {
        let stanza = try presence("""
        <presence type='unsubscribed' from='stage@example.com/Group'>
          <group xmlns='https://xabber.com/protocol/groups' members='0'/>
        </presence>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .reducer(input)? = event else {
            return XCTFail("Expected a reducer input")
        }
        XCTAssertEqual(input.events.first, .selfSubscription(.none))
        guard case .patch = input.events.last else {
            return XCTFail("Expected the trailing patch to remain ordered after tombstone")
        }
    }

    func testKnownGroupBareTerminalPresenceCompletesLeaveWithoutGroupPayload() throws {
        let fixtures: [(type: String, expectedReply: GroupPresenceReply?)] = [
            ("unsubscribed", nil),
            ("unsubscribe", .unsubscribed),
            ("unavailable", nil)
        ]

        for fixture in fixtures {
            let stanza = try presence("""
            <presence type='\(fixture.type)' from='Stage@Example.COM/Group'/>
            """)

            guard case let .reducer(input)? = try GroupStanzaRouter.route(
                stanza,
                knownGroupJIDs: [group]
            ) else {
                return XCTFail("Expected known-group \(fixture.type) to complete leave")
            }
            XCTAssertEqual(input.groupJID, group)
            XCTAssertEqual(input.events, [.selfSubscription(.none)])
            XCTAssertEqual(input.requiredReply, fixture.expectedReply)
            XCTAssertEqual(input.eventsAfterReply, [])
        }
    }

    func testBareTerminalPresenceIsIgnoredWithoutKnownGroupAdmission() throws {
        for type in ["unsubscribed", "unsubscribe", "unavailable"] {
            let stanza = try presence("""
            <presence type='\(type)' from='contact@example.com/mobile'/>
            """)
            XCTAssertNil(
                try GroupStanzaRouter.route(stanza, knownGroupJIDs: [group]),
                "A bare roster \(type) must not be classified as Xabber Groups"
            )
        }
    }

    func testKnownGroupBareTerminalAdmissionDoesNotAcceptLegacyPayload() throws {
        let stanza = try presence("""
        <presence type='unsubscribed' from='stage@example.com/Group'>
          <group xmlns='https://xabber.com/protocol/groups#presence'/>
        </presence>
        """)

        XCTAssertNil(try GroupStanzaRouter.route(stanza, knownGroupJIDs: [group]))
    }

    func testLiveChatUsesCanonicalAuthorAndStripsExactNicknameFallbackWithoutTrim() throws {
        let stanza = try message("""
        <message type='chat' from='stage@example.com/Group' to='romeo@example.com' id='message-1'>
          <origin-id xmlns='urn:xmpp:sid:0' id='origin-1'/>
          <stanza-id xmlns='urn:xmpp:sid:0' by='stage@example.com' id='1770000000000001'/>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><nickname>Juliet</nickname><role>member</role></user>
          </x>
          <body>Juliet:
        &#32;&#32;keep both spaces and tail&#32;
        </body>
        </message>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .message(messageEvent)? = event else {
            return XCTFail("Expected a canonical live group message")
        }
        XCTAssertEqual(messageEvent.source, .live)
        XCTAssertEqual(messageEvent.stanzaType, .chat)
        XCTAssertEqual(messageEvent.groupJID, group)
        XCTAssertEqual(messageEvent.author?.id, "member-7")
        XCTAssertNil(messageEvent.author?.jid)
        XCTAssertEqual(messageEvent.originID, "origin-1")
        XCTAssertEqual(messageEvent.stanzaID, "1770000000000001")
        XCTAssertEqual(messageEvent.body, "  keep both spaces and tail \n")
        XCTAssertNil(
            event?.reducerInput,
            "An immutable message author snapshot must not mutate authoritative members"
        )
    }

    func testNicknameFallbackIsNotTrimmedOrStrippedOnNonExactPrefix() throws {
        let stanza = try message("""
        <message type='chat' from='stage@example.com/Group'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><nickname>Juliet</nickname></user>
          </x>
          <body> Juliet:
        body </body>
        </message>
        """)

        guard case let .message(messageEvent)? = try GroupStanzaRouter.route(stanza) else {
            return XCTFail("Expected a live group message")
        }
        XCTAssertEqual(messageEvent.body, " Juliet:\nbody ")
    }

    func testHeadlineSystemMessageRoutesAsMessageAndExposesReducerInput() throws {
        let stanza = try message("""
        <message type='headline' from='stage@example.com/Group' id='system-1'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='join'>
              <user id='member-8'><nickname>Mercutio</nickname></user>
            </system-message>
          </x>
          <body>joined</body>
        </message>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .message(messageEvent)? = event else {
            return XCTFail("Expected a headline system message")
        }
        XCTAssertEqual(messageEvent.stanzaType, .headline)
        XCTAssertEqual(messageEvent.systemEvent?.type, .join)
        XCTAssertEqual(event?.reducerInput?.events, [.system(GroupSystemEvent(
            type: .join,
            user: GroupMember(id: "member-8", nickname: "Mercutio")
        ))])
    }

    func testChatSystemMessageWithBodyRoutesThroughCanonicalSystemParser() throws {
        let stanza = try message("""
        <message type='chat' from='stage@example.com/Group' id='system-chat-1'>
          <origin-id xmlns='urn:xmpp:sid:0' id='system-chat-1'/>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='leave'>
              <user id='member-8'><nickname>Mercutio</nickname></user>
            </system-message>
          </x>
          <body>Mercutio left the group.</body>
        </message>
        """)

        let event = try GroupStanzaRouter.route(stanza)
        guard case let .message(messageEvent)? = event else {
            return XCTFail("Expected a canonical chat system message")
        }
        XCTAssertEqual(messageEvent.stanzaType, .chat)
        XCTAssertEqual(messageEvent.body, "Mercutio left the group.")
        XCTAssertNil(messageEvent.author)
        XCTAssertEqual(
            messageEvent.systemEvent,
            GroupSystemEvent(
                type: .leave,
                user: GroupMember(id: "member-8", nickname: "Mercutio")
            )
        )
        XCTAssertEqual(event?.reducerInput?.events, [.system(GroupSystemEvent(
            type: .leave,
            user: GroupMember(id: "member-8", nickname: "Mercutio")
        ))])
    }

    func testCreateSystemEventIsRejectedLiveAndAcceptedOnlyFromMAM() throws {
        let live = try message("""
        <message type='chat' from='stage@example.com/Group' id='create-live'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='create'/>
          </x>
          <body>Romeo created the group chat.</body>
        </message>
        """)
        let archived = try message("""
        <message type='chat' from='romeo@example.com' to='romeo@example.com/ios'>
          <result xmlns='urn:xmpp:mam:2' queryid='group-mam-create' id='mam-create-1'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='stage@example.com/Group' id='create-archived'>
                <x xmlns='https://xabber.com/protocol/groups'>
                  <system-message type='create'/>
                </x>
                <body>Romeo created the group chat.</body>
              </message>
            </forwarded>
          </result>
        </message>
        """)

        XCTAssertNil(try GroupStanzaRouter.route(live))

        guard case let .message(event)? = try GroupStanzaRouter.route(archived) else {
            return XCTFail("Expected an archived create system event")
        }
        XCTAssertEqual(
            event.source,
            .mam(queryID: "group-mam-create", resultID: "mam-create-1")
        )
        XCTAssertEqual(event.systemEvent?.type, .create)
    }

    func testHeadlineGroupUpdateUsesPatchCodecAndRoutesToReducer() throws {
        let stanza = try message("""
        <message type='headline' from='stage@example.com/Group'>
          <group xmlns='https://xabber.com/protocol/groups' members='4'>
            <pinned/>
          </group>
        </message>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .reducer(input)? = event,
              case let .patch(patch) = input.events.first else {
            return XCTFail("Expected a headline patch")
        }
        XCTAssertEqual(patch.memberCount, .value(4))
        XCTAssertEqual(patch.pinnedMessageIDs, .value([]))
    }

    func testCanonicalSenderReceiptUsesInnerIdentifiersWhenOuterHasNoOriginID() throws {
        let stanza = try message("""
        <message type='headline' from='stage@example.com/Group' to='romeo@example.com/ios'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='romeo@example.com/ios' to='stage@example.com' id='origin-2'>
                <origin-id xmlns='urn:xmpp:sid:0' id='origin-2'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='stage@example.com' id='1770000000000002'/>
                <body>sent body</body>
              </message>
            </forwarded>
          </x>
        </message>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .message(receipt)? = event else {
            return XCTFail("Expected a typed sender receipt")
        }
        XCTAssertEqual(receipt.source, .senderReceipt)
        XCTAssertEqual(receipt.groupJID, group)
        XCTAssertEqual(receipt.messageID, "origin-2")
        XCTAssertEqual(receipt.originID, "origin-2")
        XCTAssertEqual(receipt.stanzaID, "1770000000000002")
        XCTAssertNil(receipt.author)
    }

    func testMAMEnvelopeRoutesInnerCanonicalGroupMessage() throws {
        let stanza = try message("""
        <message type='chat' from='romeo@example.com' to='romeo@example.com/ios'>
          <result xmlns='urn:xmpp:mam:2' queryid='group-mam-1' id='mam-result-1'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='stage@example.com/Group' id='origin-3'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='stage@example.com' id='1770000000000003'/>
                <x xmlns='https://xabber.com/protocol/groups'>
                  <user id='member-9'><nickname>Benvolio</nickname></user>
                </x>
                <body>Benvolio:
        archive body</body>
              </message>
            </forwarded>
          </result>
        </message>
        """)

        guard case let .message(archived)? = try GroupStanzaRouter.route(stanza) else {
            return XCTFail("Expected a MAM group message")
        }
        XCTAssertEqual(
            archived.source,
            .mam(queryID: "group-mam-1", resultID: "mam-result-1")
        )
        XCTAssertEqual(archived.body, "archive body")
        XCTAssertEqual(archived.author?.id, "member-9")
    }

    func testCanonicalSentAndReceivedCarbonsRouteWithDirection() throws {
        let sent = try carbon(wrapper: "sent", innerFrom: "romeo@example.com/ios", innerTo: group)
        let received = try carbon(wrapper: "received", innerFrom: "\(group)/Group", innerTo: owner)

        guard case let .message(sentEvent)? = try GroupStanzaRouter.route(sent),
              case let .message(receivedEvent)? = try GroupStanzaRouter.route(received) else {
            return XCTFail("Expected both canonical carbon directions")
        }
        XCTAssertEqual(sentEvent.source, .carbonSent)
        XCTAssertEqual(sentEvent.groupJID, group)
        XCTAssertEqual(receivedEvent.source, .carbonReceived)
        XCTAssertEqual(receivedEvent.groupJID, group)
    }

    func testCanonicalInvitePreviewRoutesWithoutReducerInput() throws {
        let stanza = try message("""
        <message type='chat' from='stage@example.com/Group' to='romeo@example.com'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
            <reason>Join us</reason>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'>
            <info><name>Stage</name></info>
          </group>
        </message>
        """)

        let event = try GroupStanzaRouter.route(stanza)

        guard case let .invite(invite)? = event else {
            return XCTFail("Expected a canonical invite preview")
        }
        XCTAssertEqual(invite.invite, .message(groupJID: group, reason: "Join us", inviter: nil))
        XCTAssertEqual(invite.preview?.info?.name, "Stage")
        XCTAssertNil(event?.reducerInput)
    }

    func testGroupchatTypeAndLegacyNamespacesAreRejectedEvenWithOtherwiseValidPayload() throws {
        let groupchat = try message("""
        <message type='groupchat' from='stage@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'><user id='member-1'/></x>
          <body>legacy type</body>
        </message>
        """)
        let legacyNamespace = try message("""
        <message type='chat' from='stage@example.com'>
          <x xmlns='http://xabber.com/protocol/groupchat'><user id='member-1'/></x>
          <body>legacy namespace</body>
        </message>
        """)
        let fragmentNamespace = try message("""
        <message type='headline' from='stage@example.com'>
          <x xmlns='https://xabber.com/protocol/groups#system-message' type='join'/>
        </message>
        """)

        XCTAssertNil(try GroupStanzaRouter.route(groupchat))
        XCTAssertNil(try GroupStanzaRouter.route(legacyNamespace))
        XCTAssertNil(try GroupStanzaRouter.route(fragmentNamespace))
    }

    func testCanonicalMessageWrapperRejectsForeignAuthorNamespace() throws {
        let stanza = try message("""
        <message type='chat' from='stage@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user xmlns='urn:example:foreign' id='member-1'/>
          </x>
          <body>foreign author</body>
        </message>
        """)

        XCTAssertThrowsError(try GroupStanzaRouter.route(stanza)) { error in
            guard case GroupProtocolCodecError.invalidNamespace = error else {
                return XCTFail("Expected strict namespace rejection, got \(error)")
            }
        }
    }

    func testCanonicalPresenceRejectsForeignNestedGroupShape() throws {
        let stanza = try presence("""
        <presence from='stage@example.com/Group'>
          <group xmlns='https://xabber.com/protocol/groups'>
            <info xmlns='urn:example:foreign'><name>Forged</name></info>
          </group>
        </presence>
        """)

        XCTAssertThrowsError(try GroupStanzaRouter.route(stanza)) { error in
            guard case GroupProtocolCodecError.unexpectedElement = error else {
                return XCTFail("Expected strict shape rejection, got \(error)")
            }
        }
    }
}

private extension GroupStanzaRouterTests {
    func element(_ xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return try XCTUnwrap(document.rootElement())
    }

    func message(_ xml: String) throws -> XMPPMessage {
        XMPPMessage(from: try element(xml))
    }

    func presence(_ xml: String) throws -> XMPPPresence {
        XMPPPresence(from: try element(xml))
    }

    func iq(_ xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try element(xml))
    }

    func carbon(
        wrapper: String,
        innerFrom: String,
        innerTo: String
    ) throws -> XMPPMessage {
        try message("""
        <message type='chat' from='romeo@example.com/ios' to='romeo@example.com/ios'>
          <\(wrapper) xmlns='urn:xmpp:carbons:2'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='\(innerFrom)' to='\(innerTo)' id='carbon-message'>
                <x xmlns='https://xabber.com/protocol/groups'>
                  <user id='member-carbon'><nickname>Carbon</nickname></user>
                </x>
                <body>Carbon:
        body</body>
              </message>
            </forwarded>
          </\(wrapper)>
        </message>
        """)
    }
}
