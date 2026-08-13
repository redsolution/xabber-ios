import XCTest
import RealmSwift
@testable import xabber

final class GroupRepositoryTests: XCTestCase {
    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "GroupRepositoryTests-\(UUID().uuidString)"
        )
        configuration.objectTypes = [
            GroupSnapshotStorageItem.self,
            GroupSelfMembershipStorageItem.self,
            GroupMemberStorageItem.self,
            GroupPermissionSetStorageItem.self,
            GroupPermissionStorageItem.self,
            GroupInviteStorageItem.self
        ]
        return try Realm(configuration: configuration)
    }

    private func snapshot(
        jid: String = "Stage@Example.COM/Group"
    ) -> GroupSnapshot {
        GroupSnapshot(
            jid: jid,
            privacy: .incognito,
            parentJID: "Parent@Example.COM/Group",
            memberCount: 2,
            localpart: "stage",
            info: GroupInfo(
                name: "Stage",
                description: "Discussion",
                avatar: GroupAvatar(
                    id: "avatar-1",
                    mediaType: "image/png",
                    bytes: 512,
                    width: 128,
                    height: 128,
                    url: "https://cdn.example/avatar.png"
                ),
                status: "Active"
            ),
            settings: GroupSettings(
                membership: .privateGroup,
                contacts: ["Juliet@Example.COM/Balcony"],
                domains: ["Example.COM"],
                index: .local,
                state: .active
            ),
            pinnedMessageIDs: ["message-1", "message-2"],
            presentCount: 1
        )
    }

    @discardableResult
    private func seedGroup(
        repository: GroupRepository,
        owner: String = "Owner@Example.COM/Phone",
        groupJID: String = "Stage@Example.COM/Group"
    ) throws -> GroupRepositoryMutationResult {
        try repository.applySnapshot(
            snapshot(jid: groupJID),
            owner: owner,
            groupJID: groupJID
        )
    }

    func testSnapshotUsesOwnerAndBareGroupKeyAndStoresCanonicalRawFields() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        XCTAssertEqual(try seedGroup(repository: repository), .applied)
        XCTAssertEqual(
            try seedGroup(
                repository: repository,
                owner: "Other@Example.COM/Desktop"
            ),
            .applied
        )

        let primary = GroupStorageKey.groupPrimary(
            owner: "Owner@Example.COM/Phone",
            groupJID: "Stage@Example.COM/Group"
        )
        let item = try XCTUnwrap(
            realm.object(ofType: GroupSnapshotStorageItem.self, forPrimaryKey: primary)
        )

        XCTAssertEqual(realm.objects(GroupSnapshotStorageItem.self).count, 2)
        XCTAssertEqual(item.owner, "owner@example.com")
        XCTAssertEqual(item.groupJID, "stage@example.com")
        XCTAssertEqual(item.privacyRaw, GroupPrivacy.incognito.rawValue)
        XCTAssertEqual(item.membershipRaw, GroupMembership.privateGroup.rawValue)
        XCTAssertEqual(item.indexRaw, GroupIndexVisibility.local.rawValue)
        XCTAssertEqual(item.lifecycleStateRaw, GroupLifecycleState.active.rawValue)
        XCTAssertEqual(item.parentJID, "parent@example.com")
        XCTAssertEqual(item.memberCount, 2)
        XCTAssertEqual(item.presentCount, 1)
        XCTAssertEqual(Array(item.pinnedMessageIDs), ["message-1", "message-2"])
        XCTAssertEqual(Array(item.contacts), ["juliet@example.com"])
        XCTAssertEqual(Array(item.domains), ["example.com"])
        XCTAssertEqual(item.name, "Stage")
        XCTAssertEqual(item.avatarID, "avatar-1")
    }

    func testSelfMembershipPersistsWaitBothAndNoneWithStableMemberID() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let primary = GroupStorageKey.groupPrimary(
            owner: "Owner@Example.COM/Phone",
            groupJID: "Stage@Example.COM/Group"
        )

        try repository.setSelfMembership(
            .wait,
            memberID: "member-self",
            owner: "Owner@Example.COM/Phone",
            groupJID: "Stage@Example.COM/Group"
        )
        var membership = try XCTUnwrap(
            realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: primary
            )
        )
        XCTAssertEqual(membership.stateRaw, GroupSelfMembershipState.wait.rawValue)
        XCTAssertEqual(membership.memberID, "member-self")

        try repository.setSelfMembership(
            .both,
            memberID: "member-self",
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        membership = try XCTUnwrap(
            realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: primary
            )
        )
        XCTAssertEqual(membership.stateRaw, GroupSelfMembershipState.both.rawValue)

        try repository.setSelfMembership(
            .none,
            memberID: "member-self",
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        membership = try XCTUnwrap(
            realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: primary
            )
        )
        XCTAssertEqual(membership.stateRaw, GroupSelfMembershipState.none.rawValue)
        XCTAssertEqual(membership.memberID, "member-self")
    }

    func testFullMemberReplacementUsesStableMemberIDAndRemovesPreviousRows() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try seedGroup(repository: repository)

        XCTAssertEqual(
            try repository.replaceMembers(
                [
                    GroupMember(
                        id: "member-1",
                        jid: "Juliet@Example.COM/Balcony",
                        role: .owner,
                        nickname: "Juliet",
                        badge: "admin",
                        avatar: GroupAvatar(
                            id: "member-avatar",
                            mediaType: "image/png",
                            bytes: 128,
                            url: "https://cdn.example/member-avatar.png"
                        ),
                        allowsPeerToPeer: true
                    ),
                    GroupMember(
                        id: "member-2",
                        role: .member,
                        nickname: "Incognito member"
                    )
                ],
                owner: "Owner@Example.COM/Phone",
                groupJID: "Stage@Example.COM/Group"
            ),
            .applied
        )
        XCTAssertEqual(realm.objects(GroupMemberStorageItem.self).count, 2)

        XCTAssertEqual(
            try repository.replaceMembers(
                [
                    GroupMember(
                        id: "member-3",
                        role: .admin,
                        nickname: "Replacement"
                    )
                ],
                owner: "owner@example.com",
                groupJID: "stage@example.com"
            ),
            .applied
        )

        let rows = realm.objects(GroupMemberStorageItem.self)
        XCTAssertEqual(rows.count, 1)
        let member = try XCTUnwrap(rows.first)
        XCTAssertEqual(member.memberID, "member-3")
        XCTAssertEqual(member.roleRaw, GroupMemberRole.admin.rawValue)
        XCTAssertNil(member.jid)
        XCTAssertEqual(
            member.primary,
            GroupStorageKey.memberPrimary(
                owner: "owner@example.com",
                groupJID: "stage@example.com",
                memberID: "member-3"
            )
        )
    }

    func testInvalidFullMemberReplacementLeavesPreviousRowsUntouched() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try seedGroup(repository: repository)
        try repository.replaceMembers(
            [GroupMember(id: "member-old", nickname: "Original")],
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        XCTAssertThrowsError(
            try repository.replaceMembers(
                [
                    GroupMember(id: "duplicate", nickname: "One"),
                    GroupMember(id: "duplicate", nickname: "Two")
                ],
                owner: "owner@example.com",
                groupJID: "stage@example.com"
            )
        ) { error in
            XCTAssertEqual(
                error as? GroupRepositoryError,
                .duplicateMemberID("duplicate")
            )
        }

        let rows = realm.objects(GroupMemberStorageItem.self)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.memberID, "member-old")
        XCTAssertEqual(rows.first?.nickname, "Original")
    }

    func testPartialPatchPreservesAbsentValuesAndClearsExplicitEmptyContainers() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try seedGroup(repository: repository)

        let result = try repository.applyPatch(
            GroupPatch(
                info: .value(
                    GroupInfoPatch(
                        description: .value("")
                    )
                ),
                settings: .value(
                    GroupSettingsPatch(
                        contacts: .value([])
                    )
                ),
                pinnedMessageIDs: .value([])
            ),
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        XCTAssertEqual(result, .applied)
        let item = try XCTUnwrap(realm.objects(GroupSnapshotStorageItem.self).first)
        XCTAssertEqual(item.name, "Stage")
        XCTAssertEqual(item.descriptionText, "")
        XCTAssertEqual(item.privacyRaw, GroupPrivacy.incognito.rawValue)
        XCTAssertEqual(item.membershipRaw, GroupMembership.privateGroup.rawValue)
        XCTAssertTrue(item.contacts.isEmpty)
        XCTAssertEqual(Array(item.domains), ["example.com"])
        XCTAssertTrue(item.pinnedMessageIDs.isEmpty)
    }

    func testLeaveTombstoneDeletesGroupStateAndRejectsLateStateUntilBoth() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(
            .both,
            memberID: "member-self",
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        try seedGroup(repository: repository)
        try repository.replaceMembers(
            [GroupMember(id: "member-1")],
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .defaults,
                permissions: [GroupPermission(name: "send-messages", status: true)]
            ),
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        try repository.recordLeave(
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupMemberStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupPermissionSetStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupPermissionStorageItem.self).isEmpty)
        let membership = try XCTUnwrap(
            realm.objects(GroupSelfMembershipStorageItem.self).first
        )
        XCTAssertEqual(membership.stateRaw, GroupSelfMembershipState.none.rawValue)
        XCTAssertEqual(membership.memberID, "member-self")

        XCTAssertEqual(
            try seedGroup(repository: repository),
            .ignoredInactiveMembership
        )
        XCTAssertEqual(
            try repository.replaceMembers(
                [GroupMember(id: "late-member")],
                owner: "owner@example.com",
                groupJID: "stage@example.com"
            ),
            .ignoredInactiveMembership
        )
        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupMemberStorageItem.self).isEmpty)

        try repository.setSelfMembership(
            .both,
            memberID: "member-self",
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        XCTAssertEqual(try seedGroup(repository: repository), .applied)
        XCTAssertEqual(realm.objects(GroupSnapshotStorageItem.self).count, 1)
    }

    func testDeletionCreatesTheSameNoResurrectionTombstone() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try seedGroup(repository: repository)

        try repository.recordDeletion(
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        XCTAssertEqual(
            try seedGroup(repository: repository),
            .ignoredInactiveMembership
        )
        XCTAssertEqual(
            realm.objects(GroupSelfMembershipStorageItem.self).first?.stateRaw,
            GroupSelfMembershipState.none.rawValue
        )
        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
    }

    func testPermissionSetsAreNormalizedForPersonalDefaultsAndNewbies() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try seedGroup(repository: repository)

        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .direct,
                target: "member-1",
                label: "member",
                actor: "member-owner",
                stamp: Date(timeIntervalSince1970: 1_700_000_000),
                permissions: [
                    GroupPermission(
                        name: "send-media",
                        level: "member",
                        status: false,
                        seconds: 3_600,
                        tag: "moderation",
                        fixed: true,
                        display: "Send media"
                    )
                ]
            ),
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .defaults,
                permissions: [
                    GroupPermission(name: "send-messages", status: true)
                ]
            ),
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )
        try repository.replacePermissionSet(
            GroupPermissionSet(scope: .newbies, permissions: []),
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        let sets = realm.objects(GroupPermissionSetStorageItem.self)
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(
            Set(sets.map(\.scopeRaw)),
            Set([
                GroupPermissionStorageScope.personal.rawValue,
                GroupPermissionStorageScope.defaults.rawValue,
                GroupPermissionStorageScope.newbies.rawValue
            ])
        )
        let personal = try XCTUnwrap(
            sets.first(where: {
                $0.scopeRaw == GroupPermissionStorageScope.personal.rawValue
            })
        )
        XCTAssertEqual(personal.targetMemberID, "member-1")
        XCTAssertEqual(personal.label, "member")
        XCTAssertEqual(personal.actorMemberID, "member-owner")

        let permissions = realm.objects(GroupPermissionStorageItem.self)
        XCTAssertEqual(permissions.count, 2)
        let personalPermission = try XCTUnwrap(
            permissions.first(where: { $0.name == "send-media" })
        )
        XCTAssertFalse(personalPermission.status)
        XCTAssertEqual(personalPermission.seconds, 3_600)
        XCTAssertTrue(personalPermission.fixed)

        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .direct,
                target: "member-1",
                permissions: []
            ),
            owner: "owner@example.com",
            groupJID: "stage@example.com"
        )

        XCTAssertEqual(
            realm.objects(GroupPermissionSetStorageItem.self).count,
            3,
            "An explicit empty set remains authoritative"
        )
        XCTAssertNil(
            realm.objects(GroupPermissionStorageItem.self)
                .first(where: { $0.name == "send-media" })
        )
        XCTAssertNotNil(
            realm.objects(GroupPermissionStorageItem.self)
                .first(where: { $0.name == "send-messages" })
        )
    }

    func testInviteUsesUnifiedDirectionAndTargetWithoutCreatingGroup() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "Stage@Example.COM/Group",
                direction: .incoming,
                target: "member-inviter",
                reason: "Join us"
            ),
            owner: "Owner@Example.COM/Phone"
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "Stage@Example.COM/Group",
                direction: .outgoing,
                target: "romeo@example.com",
                reason: nil
            ),
            owner: "Owner@Example.COM/Phone"
        )

        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertEqual(realm.objects(GroupInviteStorageItem.self).count, 2)
        let incoming = try XCTUnwrap(
            realm.objects(GroupInviteStorageItem.self).first(where: {
                $0.directionRaw == GroupInviteDirection.incoming.rawValue
            })
        )
        XCTAssertEqual(incoming.owner, "owner@example.com")
        XCTAssertEqual(incoming.groupJID, "stage@example.com")
        XCTAssertEqual(incoming.target, "member-inviter")
        XCTAssertEqual(incoming.reason, "Join us")
    }
}
