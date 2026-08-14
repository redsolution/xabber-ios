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
            .updateMember(
                GroupMemberUpdate(
                    memberID: "member-7",
                    nickname: "Juliet",
                    badge: "moderator"
                )
            )
        )
        let user = try XCTUnwrap(element.element(forName: "user"))
        XCTAssertEqual(element.attributeStringValue(forName: "id"), "member-7")
        XCTAssertEqual(user.attributeStringValue(forName: "id"), "member-7")
        XCTAssertEqual(user.element(forName: "nickname")?.stringValue, "Juliet")
        XCTAssertEqual(user.element(forName: "badge")?.stringValue, "moderator")
        XCTAssertNil(user.element(forName: "role"))
        XCTAssertNil(user.element(forName: "jid"))

        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .updateMember(GroupMemberUpdate(memberID: "0", nickname: "Juliet"))
            )
        )
        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .updateMember(GroupMemberUpdate(memberID: "member-7"))
            )
        )
        XCTAssertThrowsError(try GroupCommandCodec.encode(.setOwner(memberID: "0")))
    }

    func testInfoAndSettingsMutationsEncodeCanonicalPartialRoots() throws {
        let info = try GroupCommandCodec.encode(
            .updateInfo(GroupInfo(name: "New stage", description: ""))
        )
        XCTAssertEqual(info.name, "info")
        XCTAssertEqual(info.xmlns(), GroupProtocolNamespace.groups)
        XCTAssertEqual(info.element(forName: "name")?.stringValue, "New stage")
        XCTAssertEqual(info.element(forName: "description")?.stringValue, "")
        XCTAssertNil(info.element(forName: "settings"))

        let settings = try GroupCommandCodec.encode(
            .updateSettings(
                GroupSettings(
                    membership: .privateGroup,
                    contacts: [],
                    domains: ["Example.COM"]
                )
            )
        )
        XCTAssertEqual(settings.name, "settings")
        XCTAssertEqual(settings.xmlns(), GroupProtocolNamespace.groups)
        XCTAssertEqual(settings.element(forName: "membership")?.stringValue, "private")
        XCTAssertNotNil(settings.element(forName: "contacts"))
        XCTAssertTrue(settings.element(forName: "contacts")?.elements(forName: "contact").isEmpty == true)
        XCTAssertEqual(
            settings.element(forName: "domains")?.element(forName: "domain")?.stringValue,
            "example.com"
        )
    }

    func testRevokeUnblockAndURLAvatarUseCurrentServerShapes() throws {
        let revoke = try GroupCommandCodec.encode(
            .revokeInvite(targetJID: "Juliet@Example.com/Balcony")
        )
        XCTAssertEqual(revoke.name, "revoke")
        XCTAssertEqual(revoke.element(forName: "jid")?.stringValue, "juliet@example.com")

        let unblock = try GroupCommandCodec.encode(
            .unblock(target: "Blocked.Example.com")
        )
        XCTAssertEqual(unblock.name, "unblock")
        XCTAssertEqual(unblock.element(forName: "jid")?.stringValue, "blocked.example.com")

        let avatar = GroupAvatar(
            id: "sha256",
            mediaType: "image/png",
            bytes: 42,
            width: 64,
            height: 64,
            url: "https://media.example.com/avatar.png"
        )
        let info = try GroupCommandCodec.encode(
            .updateInfo(GroupInfo(avatar: avatar))
        )
        let metadata = try XCTUnwrap(
            info.element(forName: "avatar")?.element(
                forName: "info",
                xmlns: GroupProtocolNamespace.avatarMetadata
            )
        )
        XCTAssertEqual(metadata.attributeStringValue(forName: "url"), avatar.url)

        XCTAssertThrowsError(
            try GroupCommandCodec.encode(
                .updateInfo(
                    GroupInfo(
                        avatar: GroupAvatar(
                            id: "sha256",
                            mediaType: "image/png",
                            bytes: 42
                        )
                    )
                )
            )
        )
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
        XCTAssertEqual(pin.attributeStringValue(forName: "status"), "pinned")

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
