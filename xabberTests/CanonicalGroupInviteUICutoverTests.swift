import XCTest
import RealmSwift
@testable import xabber

final class CanonicalGroupInviteUICutoverTests: XCTestCase {
    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "CanonicalGroupInviteUICutoverTests-\(UUID().uuidString)"
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

    func testIncomingInviteProjectionCarriesEmbeddedPreviewWithoutCreatingGroupState() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "Stage@Example.COM/Group",
                direction: .incoming,
                target: "member-inviter",
                reason: "Join us",
                preview: GroupSnapshot(
                    jid: "Stage@Example.COM/Group",
                    privacy: .incognito,
                    memberCount: 7,
                    info: GroupInfo(
                        name: "Stage",
                        description: "Discussion",
                        avatar: GroupAvatar(url: "https://cdn.example/stage.png")
                    )
                )
            ),
            owner: "Romeo@Example.COM/Phone"
        )

        let invites = try repository.invites(
            owner: "romeo@example.com",
            direction: .incoming
        )

        XCTAssertEqual(invites.count, 1)
        XCTAssertEqual(invites[0].groupJID, "stage@example.com")
        XCTAssertEqual(invites[0].target, "member-inviter")
        XCTAssertEqual(invites[0].reason, "Join us")
        XCTAssertEqual(invites[0].preview?.jid, "stage@example.com")
        XCTAssertEqual(invites[0].preview?.privacy, .incognito)
        XCTAssertEqual(invites[0].preview?.memberCount, 7)
        XCTAssertEqual(invites[0].preview?.info?.name, "Stage")
        XCTAssertEqual(
            invites[0].preview?.info?.avatar?.url,
            "https://cdn.example/stage.png"
        )
        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupSelfMembershipStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupMemberStorageItem.self).isEmpty)
    }

    func testInviteProjectionCanResolveCanonicalPrimaryAndRemoveOnlySelectedInvite() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let owner = "romeo@example.com"

        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "one@example.com",
                direction: .incoming,
                target: "member-one"
            ),
            owner: owner
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "two@example.com",
                direction: .incoming,
                target: "member-two"
            ),
            owner: owner
        )

        let selected = try XCTUnwrap(
            try repository.invite(
                primary: GroupStorageKey.invitePrimary(
                    owner: owner,
                    groupJID: "one@example.com",
                    direction: .incoming,
                    target: "member-one"
                )
            )
        )
        XCTAssertEqual(selected.groupJID, "one@example.com")

        try repository.removeInvite(primary: selected.primary)

        XCTAssertEqual(
            try repository.invites(owner: owner, direction: .incoming).map(\.groupJID),
            ["two@example.com"]
        )
    }

    func testOutgoingInviteRefreshAtomicallyReplacesOnlyOutgoingTargets() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let owner = "Romeo@Example.COM/Phone"
        let group = "Stage@Example.COM/Group"
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: group,
                direction: .incoming,
                target: "member-inviter"
            ),
            owner: owner
        )
        _ = try repository.replaceOutgoingInvites(
            owner: owner,
            groupJID: group,
            targets: ["Old@Example.COM/Desktop"]
        )

        let replacement = try repository.replaceOutgoingInvites(
            owner: owner,
            groupJID: group,
            targets: [
                "Juliet@Example.COM/Balcony",
                "juliet@example.com/Phone",
                "Mercutio@Example.COM"
            ]
        )

        XCTAssertEqual(
            replacement.map(\.target),
            ["juliet@example.com", "mercutio@example.com"]
        )
        XCTAssertEqual(
            try repository.invites(owner: owner, direction: .incoming).count,
            1
        )
        XCTAssertEqual(
            try repository.invites(owner: owner, direction: .outgoing).map(\.target),
            ["juliet@example.com", "mercutio@example.com"]
        )
    }

    func testInvitePresentationFilesHaveNoLegacyInviteReadPath() throws {
        let paths = [
            "xabber/controllers/chats/contact_list/ContactsViewController.swift",
            "xabber/controllers/chats/contact_list/ContactsCategoryViewController.swift",
            "xabber/controllers/chats/last_chats_list/LastChatsViewController.swift",
            "xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDatasource.swift",
            "xabber/controllers/split/LeftMenuViewController.swift",
            "xabber/controllers/chats/contact_list/ContactsViewController+UITableViewDataSource.swift",
            "xabber/controllers/chats/contact_list/ContactsViewController+UITableViewAction.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+Invitations.swift",
            "xabber/controllers/chats/groupchats/join/GroupchatJoinViewController.swift"
        ]

        for path in paths {
            let source = try source(path)
            XCTAssertFalse(source.contains("GroupchatInvitesStorageItem"), path)
            XCTAssertFalse(source.contains("GroupchatInviteV3Parser"), path)
            XCTAssertFalse(source.contains("GroupchatInvitePersistenceService"), path)
            XCTAssertTrue(
                source.contains("GroupRepository")
                    || source.contains("CanonicalGroupInviteUIQuery"),
                path
            )
        }
    }

    func testInviteUIQueryReturnsOnlyIncomingRecordsForSelectedOwners() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "one@example.com",
                direction: .incoming,
                target: "inviter-one"
            ),
            owner: "Romeo@Example.COM/Phone"
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "outgoing@example.com",
                direction: .outgoing,
                target: "target@example.com"
            ),
            owner: "romeo@example.com"
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "two@example.com",
                direction: .incoming,
                target: "inviter-two"
            ),
            owner: "Juliet@Example.COM/Balcony"
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "hidden@example.com",
                direction: .incoming,
                target: "inviter-three"
            ),
            owner: "mercutio@example.com"
        )

        let records = try CanonicalGroupInviteUIQuery.incoming(
            in: realm,
            owners: ["juliet@example.com/Phone", "ROMEO@example.com/Desktop"]
        )

        XCTAssertEqual(records.map(\.owner), ["juliet@example.com", "romeo@example.com"])
        XCTAssertEqual(records.map(\.groupJID), ["two@example.com", "one@example.com"])
        XCTAssertTrue(records.allSatisfy { $0.direction == .incoming })
    }

    func testInvitePresentationUsesOnlyEmbeddedPreviewAndInviterSnapshot() {
        let record = GroupInviteRecord(
            primary: "invite-primary",
            owner: "romeo@example.com",
            groupJID: "stage@example.com",
            direction: .incoming,
            target: "member-17",
            reason: "Join the stage",
            inviter: GroupMember(
                id: "member-17",
                nickname: "Masked host",
                avatar: GroupAvatar(url: "https://cdn.example/host.png")
            ),
            preview: GroupSnapshot(
                jid: "stage@example.com",
                privacy: .incognito,
                memberCount: 7,
                localpart: "stage",
                info: GroupInfo(
                    name: "The Stage",
                    description: "Private discussion",
                    avatar: GroupAvatar(url: "https://cdn.example/stage.png")
                )
            )
        )

        let presentation = CanonicalGroupInvitePresentation(record)

        XCTAssertEqual(presentation.primary, "invite-primary")
        XCTAssertEqual(presentation.title, "The Stage")
        XCTAssertEqual(presentation.subtitle, "Join the stage")
        XCTAssertEqual(presentation.avatarURL, "https://cdn.example/stage.png")
        XCTAssertEqual(presentation.inviterName, "Masked host")
        XCTAssertNil(presentation.inviterJID)
        XCTAssertEqual(presentation.memberCount, 7)
        XCTAssertEqual(presentation.privacy, .incognito)
    }

    func testGroupListProjectionIncludesOnlyActiveCanonicalMemberships() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        try repository.setSelfMembership(
            .both,
            memberID: "self-active",
            owner: "Romeo@Example.COM/Phone",
            groupJID: "Stage@Example.COM/Group"
        )
        try repository.applySnapshot(
            GroupSnapshot(
                jid: "stage@example.com",
                privacy: .incognito,
                memberCount: 2,
                info: GroupInfo(
                    name: "The Stage",
                    description: "Discussion",
                    avatar: GroupAvatar(url: "https://cdn.example/stage.png")
                )
            ),
            owner: "romeo@example.com",
            groupJID: "stage@example.com"
        )
        try repository.replaceMembers(
            [
                GroupMember(id: "self-active", role: .owner, nickname: "Romeo"),
                GroupMember(id: "masked-member", role: .member, nickname: "Masked")
            ],
            owner: "romeo@example.com",
            groupJID: "stage@example.com"
        )

        try repository.setSelfMembership(
            .wait,
            memberID: nil,
            owner: "romeo@example.com",
            groupJID: "waiting@example.com"
        )
        try repository.applySnapshot(
            GroupSnapshot(jid: "waiting@example.com", info: GroupInfo(name: "Waiting")),
            owner: "romeo@example.com",
            groupJID: "waiting@example.com"
        )

        let groups = CanonicalGroupListUIQuery.active(
            in: realm,
            owners: ["ROMEO@example.com/Desktop"]
        )

        XCTAssertEqual(groups.map(\.groupJID), ["stage@example.com"])
        XCTAssertEqual(groups.first?.title, "The Stage")
        XCTAssertEqual(groups.first?.privacy, .incognito)
        XCTAssertEqual(groups.first?.avatarURL, "https://cdn.example/stage.png")
        XCTAssertEqual(groups.first?.members.map(\.memberID), ["masked-member", "self-active"])
        XCTAssertNil(groups.first?.members.first?.jid)
    }

    func testContactsGroupSourcesHaveNoLegacyGroupOrMemberReadPath() throws {
        let paths = [
            "xabber/controllers/chats/contact_list/ContactsViewController.swift",
            "xabber/controllers/chats/contact_list/ContactsCategoryViewController.swift"
        ]

        for path in paths {
            let source = try source(path)
            XCTAssertFalse(source.contains("GroupChatStorageItem"), path)
            XCTAssertFalse(source.contains("GroupchatUserStorageItem"), path)
            XCTAssertFalse(source.contains("GroupSnapshotStorageItem"), path)
            XCTAssertFalse(source.contains("GroupSelfMembershipStorageItem"), path)
            XCTAssertFalse(source.contains("GroupMemberStorageItem"), path)
            XCTAssertFalse(source.contains("GroupInviteStorageItem"), path)
            XCTAssertTrue(source.contains("GroupRepository"), path)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
