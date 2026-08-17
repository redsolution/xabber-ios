import XCTest
@testable import xabber

final class GroupDomainReducerTests: XCTestCase {
    func testPartialPatchChangesOnlyExplicitValuesAndLeavesInputImmutable() {
        let original = GroupViewState(
            snapshot: makeSnapshot(
                name: "Original",
                description: "Description",
                pinned: ["message-1"],
                contacts: ["romeo@example.com"],
                domains: ["example.com"]
            ),
            selfSubscription: .both
        )
        let patch = GroupPatch(
            info: .value(
                GroupInfoPatch(name: .value("Renamed"))
            )
        )

        let updated = GroupDomainReducer.reduce(original, event: .patch(patch))

        XCTAssertEqual(updated.snapshot.info?.name, "Renamed")
        XCTAssertEqual(updated.snapshot.info?.description, "Description")
        XCTAssertEqual(updated.snapshot.pinnedMessageIDs, ["message-1"])
        XCTAssertEqual(updated.snapshot.settings?.contacts, ["romeo@example.com"])
        XCTAssertEqual(updated.snapshot.settings?.domains, ["example.com"])
        XCTAssertEqual(original.snapshot.info?.name, "Original")
    }

    func testExplicitEmptyCollectionsClearPinnedContactsAndDomains() {
        let original = GroupViewState(
            snapshot: makeSnapshot(
                pinned: ["message-1", "message-2"],
                contacts: ["romeo@example.com"],
                domains: ["example.com"]
            ),
            selfSubscription: .both
        )
        let patch = GroupPatch(
            settings: .value(
                GroupSettingsPatch(
                    contacts: .value([]),
                    domains: .value([])
                )
            ),
            pinnedMessageIDs: .value([])
        )

        let updated = GroupDomainReducer.reduce(original, event: .patch(patch))

        XCTAssertEqual(updated.snapshot.pinnedMessageIDs, [])
        XCTAssertEqual(updated.snapshot.settings?.contacts, [])
        XCTAssertEqual(updated.snapshot.settings?.domains, [])
    }

    func testExplicitNilClearsOptionalPatchValueWhileAbsentSiblingsSurvive() {
        let original = GroupViewState(
            snapshot: makeSnapshot(
                name: "Name",
                description: "Description"
            ),
            selfSubscription: .both
        )
        let patch = GroupPatch(
            info: .value(
                GroupInfoPatch(description: .value(nil))
            )
        )

        let updated = GroupDomainReducer.reduce(original, event: .patch(patch))

        XCTAssertEqual(updated.snapshot.info?.name, "Name")
        XCTAssertNil(updated.snapshot.info?.description)
    }

    func testFullMembersAtomicallyReplacePreviousMembersByStableID() {
        let original = GroupViewState(
            members: [
                makeMember(id: "old", jid: "old@example.com"),
                makeMember(id: "stable", jid: "before@example.com")
            ],
            selfSubscription: .both
        )

        let updated = GroupDomainReducer.reduce(
            original,
            event: .replaceMembers([
                makeMember(id: "stable", jid: "after@example.com", nickname: "After"),
                makeMember(id: "new", jid: nil),
                makeMember(id: "stable", jid: "last@example.com", nickname: "Last")
            ])
        )

        XCTAssertEqual(updated.members.map(\.id), ["stable", "new"])
        XCTAssertEqual(updated.member(id: "stable")?.jid, "last@example.com")
        XCTAssertEqual(updated.member(id: "stable")?.nickname, "Last")
        XCTAssertNil(updated.member(id: "new")?.jid)
        XCTAssertNil(updated.member(id: "old"))
    }

    func testMemberAndSystemEventsUpdateActiveStateWithoutSynthesizingJID() {
        let active = GroupViewState(selfSubscription: .both)
        let anonymous = makeMember(id: "anonymous", jid: nil)

        let afterMember = GroupDomainReducer.reduce(
            active,
            event: .member(anonymous)
        )
        let afterJoin = GroupDomainReducer.reduce(
            afterMember,
            event: .system(GroupSystemEvent(type: .join, user: makeMember(id: "joined", jid: nil)))
        )
        let afterLeave = GroupDomainReducer.reduce(
            afterJoin,
            event: .system(GroupSystemEvent(type: .leave, user: anonymous))
        )

        XCTAssertNil(afterMember.member(id: "anonymous")?.jid)
        XCTAssertNil(afterJoin.member(id: "joined")?.jid)
        XCTAssertNil(afterLeave.member(id: "anonymous"))
        XCTAssertNotNil(afterLeave.member(id: "joined"))
    }

    func testRosterSubscriptionDoesNotDetermineGroupLifecycle() {
        let active = GroupViewState(
            snapshot: makeSnapshot(name: "Active"),
            selfSubscription: .wait
        )
        let withBothRosterSubscription = GroupDomainReducer.reduce(
            active,
            event: .selfSubscription(.both)
        )
        let withNoRosterSubscription = GroupDomainReducer.reduce(
            withBothRosterSubscription,
            event: .selfSubscription(.none)
        )
        let inactive = GroupDomainReducer.reduce(
            GroupViewState(
                snapshot: GroupSnapshot(
                    jid: "group@example.com",
                    settings: GroupSettings(state: .inactive)
                )
            ),
            event: .selfSubscription(.both)
        )

        XCTAssertTrue(active.isActive)
        XCTAssertTrue(withBothRosterSubscription.isActive)
        XCTAssertTrue(withNoRosterSubscription.isActive)
        XCTAssertFalse(withNoRosterSubscription.isTombstoned)
        XCTAssertFalse(inactive.isActive)
    }

    func testDeleteAndNoneTombstonesAggregateAndTrailingEventsCannotResurrect() {
        let active = GroupViewState(
            snapshot: makeSnapshot(name: "Before"),
            members: [makeMember(id: "member", jid: "member@example.com")],
            selfSubscription: .both
        )
        let deleted = GroupDomainReducer.reduce(active, event: .deleted)
        let tombstoned = GroupDomainReducer.reduce(
            deleted,
            event: .selfSubscription(.none)
        )

        let afterPatch = GroupDomainReducer.reduce(
            tombstoned,
            event: .patch(GroupPatch(info: .value(GroupInfoPatch(name: .value("Late")))))
        )
        let afterMembers = GroupDomainReducer.reduce(
            afterPatch,
            event: .replaceMembers([makeMember(id: "late", jid: "late@example.com")])
        )
        let afterSystem = GroupDomainReducer.reduce(
            afterMembers,
            event: .system(
                GroupSystemEvent(
                    type: .join,
                    user: makeMember(id: "system-late", jid: "late@example.com")
                )
            )
        )

        XCTAssertTrue(afterSystem.isDeleted)
        XCTAssertEqual(afterSystem.selfSubscription, .none)
        XCTAssertTrue(afterSystem.isTombstoned)
        XCTAssertFalse(afterSystem.isActive)
        XCTAssertEqual(afterSystem.snapshot.info?.name, "Before")
        XCTAssertEqual(afterSystem.members.map(\.id), ["member"])
        XCTAssertNil(afterSystem.lastSystemEvent)
    }

    func testExplicitCreatedEventCanAdmitAfterTombstoneAndResetsStaleAggregateState() {
        let stale = GroupViewState(
            snapshot: makeSnapshot(name: "Stale"),
            members: [makeMember(id: "stale", jid: "stale@example.com")],
            selfSubscription: .none,
            isDeleted: true,
            lastSystemEvent: GroupSystemEvent(type: .leave)
        )

        let recreated = GroupDomainReducer.reduce(
            stale,
            event: .created(makeSnapshot(name: "Created"))
        )

        XCTAssertTrue(recreated.isActive)
        XCTAssertFalse(recreated.isDeleted)
        XCTAssertFalse(recreated.isTombstoned)
        XCTAssertEqual(recreated.selfSubscription, .wait)
        XCTAssertEqual(recreated.snapshot.info?.name, "Created")
        XCTAssertTrue(recreated.members.isEmpty)
        XCTAssertTrue(recreated.permissionSets.isEmpty)
        XCTAssertNil(recreated.lastSystemEvent)
    }

    func testRosterBothCannotAdmitAfterGroupDeletion() {
        let tombstoned = GroupViewState(
            selfSubscription: .none,
            isDeleted: true
        )

        let activated = GroupDomainReducer.reduce(
            tombstoned,
            event: .selfSubscription(.both)
        )

        XCTAssertFalse(activated.isActive)
        XCTAssertTrue(activated.isDeleted)
        XCTAssertTrue(activated.isTombstoned)
        XCTAssertEqual(activated.selfSubscription, .both)
    }

    func testOwnerCapabilitiesAreAllEnabledWithoutOwnerPseudoPermission() {
        let capabilities = GroupCapabilities.derive(
            role: .owner,
            permissionSet: makePermissionSet([])
        )

        XCTAssertTrue(capabilities.allEnabled)
    }

    func testAdminGetsAllMemberCapabilitiesAndUsesAdminPermissionStatuses() {
        let capabilities = GroupCapabilities.derive(
            role: .admin,
            permissionSet: makePermissionSet([
                makePermission(name: "send-messages", level: "member", status: false),
                makePermission(name: "pin-messages", level: "member", status: false),
                makePermission(name: "block-users", level: "admin", status: true),
                makePermission(name: "create-admins", level: "admin", status: false)
            ])
        )

        XCTAssertTrue(capabilities.sendMessages)
        XCTAssertTrue(capabilities.sendMedia)
        XCTAssertTrue(capabilities.addMembers)
        XCTAssertTrue(capabilities.pinMessages)
        XCTAssertTrue(capabilities.changeGroupInfo)
        XCTAssertTrue(capabilities.blockUsers)
        XCTAssertFalse(capabilities.createAdmins)
    }

    func testMemberCapabilitiesUseExactCanonicalPermissionStatuses() {
        let capabilities = GroupCapabilities.derive(
            role: .member,
            permissionSet: makePermissionSet([
                makePermission(name: "send-messages", level: "member", status: true),
                makePermission(name: "send-media", level: "member", status: false),
                makePermission(name: "pin-messages", level: "member", status: true),
                makePermission(name: "send_message", level: "member", status: true),
                makePermission(name: "block-users", level: "admin", status: false)
            ])
        )

        XCTAssertTrue(capabilities.sendMessages)
        XCTAssertFalse(capabilities.sendMedia)
        XCTAssertTrue(capabilities.pinMessages)
        XCTAssertFalse(capabilities.addMembers)
        XCTAssertFalse(capabilities.changeGroupInfo)
        XCTAssertFalse(capabilities.blockUsers)
    }

    func testNoneRoleCannotGainCapabilitiesFromPermissionStatuses() {
        let capabilities = GroupCapabilities.derive(
            role: .none,
            permissionSet: makePermissionSet([
                makePermission(name: "send-messages", level: "member", status: true),
                makePermission(name: "block-users", level: "admin", status: true)
            ])
        )

        XCTAssertFalse(capabilities.anyEnabled)
    }
}

private extension GroupDomainReducerTests {
    func makeSnapshot(
        name: String = "Group",
        description: String = "Description",
        pinned: [String] = [],
        contacts: [String] = [],
        domains: [String] = []
    ) -> GroupSnapshot {
        GroupSnapshot(
            jid: "group@example.com",
            privacy: .publicGroup,
            parentJID: nil,
            memberCount: 2,
            localpart: "group",
            info: GroupInfo(
                name: name,
                description: description,
                avatar: nil,
                status: "active"
            ),
            settings: GroupSettings(
                membership: .privateGroup,
                contacts: contacts,
                domains: domains,
                index: .local,
                state: .active
            ),
            pinnedMessageIDs: pinned,
            presentCount: 1
        )
    }

    func makeMember(
        id: String,
        jid: String?,
        nickname: String? = nil
    ) -> GroupMember {
        GroupMember(
            id: id,
            jid: jid,
            role: .member,
            nickname: nickname,
            badge: nil,
            avatar: nil,
            lastSeen: nil,
            allowsPeerToPeer: false
        )
    }

    func makePermission(
        name: String,
        level: String?,
        status: Bool
    ) -> GroupPermission {
        GroupPermission(
            name: name,
            level: level,
            status: status,
            seconds: nil,
            expires: nil,
            tag: nil,
            fixed: false,
            display: nil
        )
    }

    func makePermissionSet(_ permissions: [GroupPermission]) -> GroupPermissionSet {
        GroupPermissionSet(
            scope: .direct,
            target: nil,
            label: nil,
            actor: nil,
            stamp: nil,
            permissions: permissions
        )
    }
}
