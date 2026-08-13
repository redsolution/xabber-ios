import XCTest
import XMPPFramework
@testable import xabber

final class GroupCommandCodecTests: XCTestCase {
    func testNormalAndP2PCreateUseOnlyCanonicalGroupsShape() throws {
        let normal = try GroupCommandCodec.encode(
            .create(
                GroupSnapshot(
                    privacy: .incognito,
                    localpart: "stage",
                    info: GroupInfo(name: "Stage", description: "Private stage"),
                    settings: GroupSettings(
                        membership: .privateGroup,
                        index: .none
                    )
                )
            )
        )

        XCTAssertEqual(normal.name, "create")
        XCTAssertEqual(normal.xmlns(), GroupProtocolNamespace.groups)
        let group = try XCTUnwrap(normal.element(forName: "group"))
        XCTAssertEqual(group.attributeStringValue(forName: "privacy"), "incognito")
        XCTAssertEqual(group.element(forName: "settings")?.element(forName: "membership")?.stringValue, "private")
        XCTAssertNil(normal.element(forName: "query"))

        let p2p = try GroupCommandCodec.encode(
            .createP2P(parentJID: "Parent@Example.com/Group", memberID: "member-7")
        )
        let peer = try XCTUnwrap(p2p.element(forName: "peer-to-peer"))
        XCTAssertEqual(peer.attributeStringValue(forName: "parent"), "parent@example.com")
        XCTAssertEqual(peer.attributeStringValue(forName: "with"), "member-7")
        XCTAssertNil(p2p.element(forName: "group"))
    }

    func testGroupLifecycleAndRefreshCommandsUseCurrentServerShapes() throws {
        let details = try GroupCommandCodec.encode(.groupDetails)
        XCTAssertEqual(details.name, "query")
        XCTAssertEqual(details.xmlns(), GroupProtocolNamespace.groups)

        let members = try GroupCommandCodec.encode(.fullMembers)
        XCTAssertEqual(members.name, "members")
        XCTAssertNil(members.attribute(forName: "version"))
        XCTAssertNil(members.attribute(forName: "id"))
        XCTAssertTrue((members.children ?? []).isEmpty)

        let delete = try GroupCommandCodec.encode(.delete(groupJID: "Stage@Example.com/Group"))
        XCTAssertEqual(delete.name, "delete")
        XCTAssertEqual(delete.stringValue, "stage@example.com")

        XCTAssertEqual(try GroupCommandCodec.encode(.invites).name, "invites")
        XCTAssertEqual(try GroupCommandCodec.encode(.blocklist).name, "block")
        XCTAssertEqual(try GroupCommandCodec.encode(.declineInvite).name, "decline")
    }

    func testMemberMutationRequiresStableNonSpecialMemberID() throws {
        let element = try GroupCommandCodec.encode(
            .updateMember(GroupMember(id: "member-7", nickname: "Juliet"))
        )
        let user = try XCTUnwrap(element.element(forName: "user"))
        XCTAssertEqual(user.attributeStringValue(forName: "id"), "member-7")
        XCTAssertNil(element.attribute(forName: "id"))

        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .updateMember(GroupMember(id: "0", nickname: "Juliet"))
            )
        )
        XCTAssertThrowsError(try GroupCommandCodec.encode(.setOwner(memberID: "0")))
    }

    func testInviteBlockKickAndPinAddressCanonicalIdentifiers() throws {
        let invite = try GroupCommandCodec.encode(
            .invite(targetJID: "Juliet@Example.com/Balcony", send: true, reason: "Join")
        )
        XCTAssertEqual(invite.element(forName: "jid")?.stringValue, "juliet@example.com")
        XCTAssertEqual(invite.element(forName: "send")?.stringValue, "true")

        let block = try GroupCommandCodec.encode(
            .block(targets: ["Juliet@Example.com/Balcony", "blocked.example.com"])
        )
        XCTAssertEqual(block.elements(forName: "jid").compactMap(\.stringValue), [
            "juliet@example.com",
            "blocked.example.com"
        ])
        XCTAssertEqual(
            try GroupCommandCodec.encode(.kick(targetJID: "Juliet@Example.com/Balcony"))
                .element(forName: "jid")?.stringValue,
            "juliet@example.com"
        )

        let pin = try GroupCommandCodec.encode(.pin(groupStanzaID: "group-stanza-1"))
        XCTAssertEqual(pin.name, "pinned-message")
        XCTAssertEqual(pin.attributeStringValue(forName: "id"), "group-stanza-1")
        XCTAssertNil(pin.attribute(forName: "status"))

        let unpin = try GroupCommandCodec.encode(.unpin(groupStanzaID: "group-stanza-1"))
        XCTAssertEqual(unpin.attributeStringValue(forName: "status"), "remove")
    }

    func testPermissionGETAndSETEnforceGroupProfileContract() throws {
        let personalGet = try GroupCommandCodec.encode(
            .getPermissions(scope: .direct, targetMemberID: "member-7")
        )
        XCTAssertEqual(personalGet.name, "permissions")
        XCTAssertEqual(personalGet.attributeStringValue(forName: "target"), "member-7")

        XCTAssertEqual(
            try GroupCommandCodec.encode(.getPermissions(scope: .defaults, targetMemberID: nil)).name,
            "defaults"
        )
        XCTAssertEqual(
            try GroupCommandCodec.encode(.getPermissions(scope: .newbies, targetMemberID: nil)).name,
            "newbies"
        )

        let personalSet = GroupPermissionSet(
            scope: .direct,
            target: "member-7",
            permissions: [
                GroupPermission(
                    name: "send-messages",
                    level: "member",
                    status: false,
                    seconds: 60
                )
            ]
        )
        let setElement = try GroupCommandCodec.encode(.setPermissions(personalSet))
        let permission = try XCTUnwrap(setElement.element(forName: "permission"))
        XCTAssertEqual(permission.attributeStringValue(forName: "seconds"), "60")
        XCTAssertNil(permission.attribute(forName: "expires"))

        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .setPermissions(
                    GroupPermissionSet(
                        scope: .direct,
                        target: "member-7",
                        permissions: [GroupPermission(name: "owner", status: true)]
                    )
                )
            )
        )
        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .setPermissions(
                    GroupPermissionSet(
                        scope: .defaults,
                        permissions: [
                            GroupPermission(name: "send-messages", status: true, seconds: 60)
                        ]
                    )
                )
            )
        )
        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .setPermissions(
                    GroupPermissionSet(
                        scope: .newbies,
                        permissions: [
                            GroupPermission(name: "send-messages", status: true, expires: 60)
                        ]
                    )
                )
            )
        )
    }
}
