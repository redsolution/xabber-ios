import XCTest
import XMPPFramework
@testable import xabber

final class GroupProtocolCodecTests: XCTestCase {
    private enum Fixture {
        static let groupSnapshot = """
        <group xmlns='https://xabber.com/protocol/groups'
               jid='Stage@Example.COM/Group'
               privacy='public'
               parent='Parent@Example.COM/Group'
               members='2'>
          <localpart>stage</localpart>
          <info>
            <name>Stage</name>
            <description>Discussion</description>
            <status>Active</status>
          </info>
          <settings>
            <membership>private</membership>
            <contacts><contact>Juliet@Example.COM/Balcony</contact></contacts>
            <domains><domain>Example.COM</domain></domains>
            <index>local</index>
            <state>active</state>
          </settings>
          <pinned>
            <pinned-message id='message-1'/>
            <pinned-message id='message-2' status='pinned'/>
          </pinned>
          <present>1</present>
        </group>
        """

        static let explicitEmptyPatch = """
        <group xmlns='https://xabber.com/protocol/groups'>
          <info><description/></info>
          <settings><contacts/><domains/></settings>
          <pinned/>
        </group>
        """

        static let fullMembers = """
        <members xmlns='https://xabber.com/protocol/groups'>
          <user id='member-1'>
            <jid>Juliet@Example.COM/Balcony</jid>
            <role>owner</role>
            <nickname>Juliet</nickname>
            <badge>admin</badge>
            <allow-p2p/>
          </user>
          <user id='member-2'>
            <role>member</role>
            <nickname>Incognito member</nickname>
          </user>
        </members>
        """

        static let messageAuthor = """
        <x xmlns='https://xabber.com/protocol/groups'>
          <user id='member-1'>
            <jid>Juliet@Example.COM/Balcony</jid>
            <nickname>Juliet</nickname>
            <role>owner</role>
          </user>
        </x>
        """

        static let systemEvent = """
        <x xmlns='https://xabber.com/protocol/groups'>
          <system-message type='join'>
            <user id='member-2'>
              <nickname>Romeo</nickname>
              <role>member</role>
            </user>
          </system-message>
        </x>
        """

        static let directInvite = """
        <invite xmlns='https://xabber.com/protocol/groups' jid='Stage@Example.COM/Group'>
          <reason>Join us</reason>
          <user id='member-1'><nickname>Juliet</nickname></user>
        </invite>
        """

        static let inviteRequest = """
        <invite xmlns='https://xabber.com/protocol/groups'>
          <jid>Romeo@Example.COM/Phone</jid>
          <send>true</send>
          <reason>Join us</reason>
        </invite>
        """

        static let permissions = """
        <permissions xmlns='https://xabber.com/protocol/permissions'
                     target='member-2' label='member' actor='member-1'
                     stamp='2026-08-13T10:00:00Z'>
          <permission name='send-messages' level='member' status='true'
                      display='Send messages'/>
          <permission name='send-media' status='false' seconds='3600'
                      tag='moderation' fixed='true'/>
        </permissions>
        """
    }

    private func element(_ xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return try XCTUnwrap(document.rootElement())
    }

    func testGroupSnapshotUsesGroupRootAndNormalizesBareJIDs() throws {
        let snapshot = try GroupProtocolCodec.decodeGroupSnapshot(element(Fixture.groupSnapshot))

        XCTAssertEqual(snapshot.jid, "stage@example.com")
        XCTAssertEqual(snapshot.parentJID, "parent@example.com")
        XCTAssertEqual(snapshot.privacy, .publicGroup)
        XCTAssertEqual(snapshot.memberCount, 2)
        XCTAssertEqual(snapshot.localpart, "stage")
        XCTAssertEqual(snapshot.info?.name, "Stage")
        XCTAssertEqual(snapshot.info?.description, "Discussion")
        XCTAssertEqual(snapshot.settings?.membership, .privateGroup)
        XCTAssertEqual(snapshot.settings?.contacts, ["juliet@example.com"])
        XCTAssertEqual(snapshot.settings?.domains, ["example.com"])
        XCTAssertEqual(snapshot.settings?.index, .local)
        XCTAssertEqual(snapshot.settings?.state, .active)
        XCTAssertEqual(snapshot.pinnedMessageIDs, ["message-1", "message-2"])
        XCTAssertEqual(snapshot.presentCount, 1)
    }

    func testGroupPatchDistinguishesAbsentFromExplicitEmptyContainers() throws {
        let patch = try GroupProtocolCodec.decodeGroupPatch(element(Fixture.explicitEmptyPatch))

        XCTAssertEqual(patch.jid, .absent)
        XCTAssertEqual(patch.memberCount, .absent)
        XCTAssertEqual(patch.pinnedMessageIDs, .value([]))

        guard case let .value(info?) = patch.info else {
            return XCTFail("Expected an explicit info patch")
        }
        XCTAssertEqual(info.name, .absent)
        XCTAssertEqual(info.description, .value(""))

        guard case let .value(settings?) = patch.settings else {
            return XCTFail("Expected an explicit settings patch")
        }
        XCTAssertEqual(settings.contacts, .value([]))
        XCTAssertEqual(settings.domains, .value([]))
        XCTAssertEqual(settings.membership, .absent)
    }

    func testSnapshotRoundTripPreservesCanonicalShape() throws {
        let original = try GroupProtocolCodec.decodeGroupSnapshot(element(Fixture.groupSnapshot))
        let encoded = try GroupProtocolCodec.encodeGroupSnapshot(original)

        XCTAssertEqual(encoded.name, "group")
        XCTAssertEqual(encoded.xmlns(), GroupProtocolNamespace.groups)
        XCTAssertNil(encoded.element(forName: "x"))
        XCTAssertEqual(try GroupProtocolCodec.decodeGroupSnapshot(encoded), original)
    }

    func testGroupRootRejectsMessageXAndLegacyFragmentNamespaces() throws {
        XCTAssertThrowsError(try GroupProtocolCodec.decodeGroupSnapshot(element(Fixture.messageAuthor)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeGroupSnapshot(element("""
        <group xmlns='https://xabber.com/protocol/groups#info' jid='stage@example.com'/>
        """)))
    }

    func testFullMembersParseStableIDsAndDoNotRequireVisibleJIDs() throws {
        let members = try GroupProtocolCodec.decodeFullMembers(element(Fixture.fullMembers))

        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].id, "member-1")
        XCTAssertEqual(members[0].jid, "juliet@example.com")
        XCTAssertEqual(members[0].role, .owner)
        XCTAssertTrue(members[0].allowsPeerToPeer)
        XCTAssertEqual(members[1].id, "member-2")
        XCTAssertNil(members[1].jid)
    }

    func testFullMembersAcceptNumericResponseVersionAsFullSnapshotMetadata() throws {
        let members = try GroupProtocolCodec.decodeFullMembers(element("""
        <members xmlns='https://xabber.com/protocol/groups' version='1786706642'>
          <user id='j5q0ssu8tt0a7u5p'>
            <role>owner</role>
            <nickname>igor.boldin@redsolution.com</nickname>
            <jid>igor.boldin@redsolution.com</jid>
          </user>
        </members>
        """))

        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].id, "j5q0ssu8tt0a7u5p")
        XCTAssertEqual(members[0].role, .owner)
        XCTAssertEqual(members[0].jid, "igor.boldin@redsolution.com")
    }

    func testFullMembersRejectMalformedVersionRSMAndMissingStableID() throws {
        XCTAssertThrowsError(try GroupProtocolCodec.decodeFullMembers(element("""
        <members xmlns='https://xabber.com/protocol/groups' version='not-a-number'/>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeFullMembers(element("""
        <members xmlns='https://xabber.com/protocol/groups'>
          <set xmlns='http://jabber.org/protocol/rsm'><count>1</count></set>
        </members>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeFullMembers(element("""
        <members xmlns='https://xabber.com/protocol/groups'><user><nickname>No ID</nickname></user></members>
        """)))
    }

    func testMessageAuthorUsesCanonicalXRoot() throws {
        let member = try GroupProtocolCodec.decodeMessageAuthor(element(Fixture.messageAuthor))

        XCTAssertEqual(member.id, "member-1")
        XCTAssertEqual(member.jid, "juliet@example.com")
        let encoded = try GroupProtocolCodec.encodeMessageAuthor(member)
        XCTAssertEqual(encoded.name, "x")
        XCTAssertEqual(encoded.xmlns(), GroupProtocolNamespace.groups)
        XCTAssertNil(encoded.element(forName: "group"))
    }

    func testSystemEventRequiresNestedUserAndCanonicalKnownType() throws {
        let event = try GroupProtocolCodec.decodeSystemEvent(element(Fixture.systemEvent))

        XCTAssertEqual(event.type, .join)
        XCTAssertEqual(event.user?.id, "member-2")
        XCTAssertEqual(try GroupProtocolCodec.decodeSystemEvent(
            GroupProtocolCodec.encodeSystemEvent(event)
        ), event)

        XCTAssertThrowsError(try GroupProtocolCodec.decodeSystemEvent(element("""
        <x xmlns='https://xabber.com/protocol/groups'>
          <user id='member-2'/><system-message type='join'/>
        </x>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeSystemEvent(element("""
        <system-message xmlns='https://xabber.com/protocol/groups' type='join'>
          <user id='member-2'/>
        </system-message>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeSystemEvent(element("""
        <x xmlns='https://xabber.com/protocol/groups'><system-message type='unpinned'/></x>
        """)))
    }

    func testPinAndUnpinNotificationsSharePinnedSystemType() throws {
        let pin = GroupSystemEvent(type: .pinned, user: nil)
        let unpin = GroupSystemEvent(type: .pinned, user: nil)

        XCTAssertEqual(try GroupProtocolCodec.decodeSystemEvent(
            GroupProtocolCodec.encodeSystemEvent(pin)
        ), pin)
        XCTAssertEqual(unpin.type.rawValue, "pinned")
    }

    func testInviteDistinguishesRequestFromMessageAndNormalizesBareJIDs() throws {
        XCTAssertEqual(
            try GroupProtocolCodec.decodeInvite(element(Fixture.directInvite)),
            .message(
                groupJID: "stage@example.com",
                reason: "Join us",
                inviter: GroupMember(id: "member-1", nickname: "Juliet")
            )
        )
        XCTAssertEqual(
            try GroupProtocolCodec.decodeInvite(element(Fixture.inviteRequest)),
            .request(targetJID: "romeo@example.com", send: true, reason: "Join us")
        )
    }

    func testInviteRejectsLegacyFragmentAndAmbiguousFlatShapes() throws {
        XCTAssertThrowsError(try GroupProtocolCodec.decodeInvite(element("""
        <invite xmlns='https://xabber.com/protocol/groups#invite' jid='stage@example.com'/>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeInvite(element("""
        <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
          <jid>romeo@example.com</jid>
        </invite>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeInvite(element("""
        <x xmlns='https://xabber.com/protocol/groups'><invite jid='stage@example.com'/></x>
        """)))
    }

    func testInvitationAndBlockListsDecodeCanonicalTypedAddresses() throws {
        let invites = try GroupProtocolCodec.decodeInvites(element("""
        <invites xmlns='https://xabber.com/protocol/groups'>
          <jid>Juliet@Example.COM/Balcony</jid>
          <jid>Romeo@Example.COM/Phone</jid>
        </invites>
        """))
        XCTAssertEqual(invites, ["juliet@example.com", "romeo@example.com"])

        let blocklist = try GroupProtocolCodec.decodeBlocklist(element("""
        <block xmlns='https://xabber.com/protocol/groups'>
          <jid>Tybalt@Example.COM/Sword</jid>
          <jid>Spam.Example.COM</jid>
        </block>
        """))
        XCTAssertEqual(blocklist, ["tybalt@example.com", "spam.example.com"])

        XCTAssertEqual(
            try GroupProtocolCodec.decodeInvites(element("""
            <invites xmlns='https://xabber.com/protocol/groups'/>
            """)),
            []
        )
        XCTAssertEqual(
            try GroupProtocolCodec.decodeBlocklist(element("""
            <block xmlns='https://xabber.com/protocol/groups'/>
            """)),
            []
        )
    }

    func testInvitationAndBlockListsRejectLegacyOrMixedShapes() throws {
        XCTAssertThrowsError(try GroupProtocolCodec.decodeInvites(element("""
        <invites xmlns='https://xabber.com/protocol/groups#invites'>
          <jid>juliet@example.com</jid>
        </invites>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeInvites(element("""
        <invites xmlns='https://xabber.com/protocol/groups'>
          <user jid='juliet@example.com'/>
        </invites>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodeBlocklist(element("""
        <block xmlns='https://xabber.com/protocol/groups'>
          <item jid='juliet@example.com'/>
        </block>
        """)))
    }

    func testInfoAndSettingsStandalonePayloadsRoundTrip() throws {
        let info = GroupInfo(name: "Stage", description: "Discussion", status: "active")
        XCTAssertEqual(
            try GroupProtocolCodec.decodeInfo(GroupProtocolCodec.encodeInfo(info)),
            info
        )

        let settings = GroupSettings(
            membership: .privateGroup,
            contacts: [],
            domains: ["example.com"],
            index: .local,
            state: .active
        )
        XCTAssertEqual(
            try GroupProtocolCodec.decodeSettings(GroupProtocolCodec.encodeSettings(settings)),
            settings
        )
    }

    func testPermissionsParseCanonicalAttributesAndDurations() throws {
        let set = try GroupProtocolCodec.decodePermissionSet(element(Fixture.permissions))

        XCTAssertEqual(set.scope, .direct)
        XCTAssertEqual(set.target, "member-2")
        XCTAssertEqual(set.label, "member")
        XCTAssertEqual(set.actor, "member-1")
        XCTAssertEqual(set.permissions.count, 2)
        XCTAssertEqual(set.permissions[0].name, "send-messages")
        XCTAssertEqual(set.permissions[0].level, "member")
        XCTAssertTrue(set.permissions[0].status)
        XCTAssertEqual(set.permissions[1].seconds, 3600)
        XCTAssertTrue(set.permissions[1].fixed)
        XCTAssertEqual(try GroupProtocolCodec.decodePermissionSet(
            GroupProtocolCodec.encodePermissionSet(set)
        ), set)
    }

    func testPermissionsPreserveExplicitEmptyDefaultsAndNewbiesSets() throws {
        let defaults = try GroupProtocolCodec.decodePermissionSet(element("""
        <defaults xmlns='https://xabber.com/protocol/permissions'><permissions/></defaults>
        """))
        let newbies = try GroupProtocolCodec.decodePermissionSet(element("""
        <newbies xmlns='https://xabber.com/protocol/permissions'><permissions/></newbies>
        """))

        XCTAssertEqual(defaults, GroupPermissionSet(scope: .defaults, permissions: []))
        XCTAssertEqual(newbies, GroupPermissionSet(scope: .newbies, permissions: []))
    }

    func testPermissionsRejectLegacyNamespaceMissingStatusAndDualDuration() throws {
        XCTAssertThrowsError(try GroupProtocolCodec.decodePermissionSet(element("""
        <permissions xmlns='https://xabber.com/protocol/groups#permissions'/>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodePermissionSet(element("""
        <permissions xmlns='https://xabber.com/protocol/permissions'>
          <permission name='send-media'/>
        </permissions>
        """)))
        XCTAssertThrowsError(try GroupProtocolCodec.decodePermissionSet(element("""
        <permissions xmlns='https://xabber.com/protocol/permissions'>
          <permission name='send-media' status='false' seconds='60' expires='100'/>
        </permissions>
        """)))
    }

}
