import XCTest
import RealmSwift
@testable import xabber

final class CreatedGroupOwnerAdmissionTests: XCTestCase {
    private let owner = "owner@example.com/ios"
    private let groupJID = "new-room@groups.example.com"

    func testCreateFlowCompletesEagerOwnerAdmissionBeforeOpeningChat() throws {
        let source = try applicationSource(
            "xabber/controllers/chats/create_new_entity/new_group/CreateNewGroupViewController+Flow.swift"
        )
        let admission = try XCTUnwrap(
            source.range(of: "CanonicalCreatedGroupOwnerAdmission.admit")
        )
        let presentation = try XCTUnwrap(
            source.range(of: "self.onSuccess(groupJID: groupJID)")
        )

        XCTAssertLessThan(admission.lowerBound, presentation.lowerBound)
        XCTAssertFalse(source.contains("groupchatService.refreshMembers"))
        XCTAssertFalse(source.contains("repository.setSelfMembership"))
    }

    func testSelfIdentityFallsBackFromStaleStoredIDToCurrentOwnerJID() {
        let members = [
            GroupMember(
                id: "owner-member",
                jid: "owner@example.com/Desktop",
                role: .owner
            )
        ]

        XCTAssertEqual(
            CanonicalGroupSelfIdentity.resolve(
                existingMemberID: "stale-member",
                ownerJID: owner,
                members: members
            ),
            "owner-member"
        )
    }

    @MainActor
    func testCreateSuccessPersistsOwnerAndEveryCapabilityWithoutRosterSubscription() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let snapshot = GroupSnapshot(
            jid: "NEW-ROOM@GROUPS.EXAMPLE.COM/Service",
            privacy: .publicGroup,
            info: GroupInfo(name: "New room"),
            settings: GroupSettings(
                membership: .open,
                index: .local,
                state: .active
            )
        )

        let projection = try CanonicalCreatedGroupOwnerAdmission.admit(
            snapshot: snapshot,
            owner: owner,
            repository: repository
        )

        XCTAssertTrue(realm.objects(GroupSelfMembershipStorageItem.self).isEmpty)
        let selfMemberID = try XCTUnwrap(projection.selfMemberID)
        XCTAssertTrue(selfMemberID.hasPrefix("local-created-owner:"))
        XCTAssertEqual(projection.state.members.map(\.id), [selfMemberID])
        XCTAssertEqual(
            projection.state.members.first(where: { $0.id == selfMemberID })?.role,
            .owner
        )
        XCTAssertEqual(
            projection.state.members.first(where: { $0.id == selfMemberID })?.jid,
            "owner@example.com"
        )
        XCTAssertTrue(projection.capabilities.allEnabled)
        XCTAssertTrue(ChatGroupProjectionAdapter.map(projection).isComposerActive)
        let model = GroupchatSettingsCanonicalModel(
            projection: projection,
            outgoingInviteCount: 0,
            blockedCount: 0
        )
        XCTAssertTrue(model.canEditInfo)
        XCTAssertTrue(model.canEditSettings)
        XCTAssertTrue(model.canEditDefaultPermissions)
        XCTAssertTrue(model.canManageAdmins)
        XCTAssertTrue(model.canInvite)
        XCTAssertTrue(model.canBlock)
        XCTAssertTrue(model.canDelete)
    }

    @MainActor
    func testAuthoritativeMembersReplaceProvisionalOwnerIDWithoutRosterSubscription() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        _ = try CanonicalCreatedGroupOwnerAdmission.admit(
            snapshot: GroupSnapshot(
                jid: groupJID,
                settings: GroupSettings(state: .active)
            ),
            owner: owner,
            repository: repository
        )
        let processor = GroupEventProcessor(
            owner: owner,
            repository: { repository }
        )
        let input = GroupReducerInput(
            groupJID: groupJID,
            ingress: .headline,
            events: [
                .replaceMembers([
                    GroupMember(
                        id: "owner-member",
                        jid: "owner@example.com/Desktop",
                        role: .owner
                    )
                ])
            ]
        )

        XCTAssertEqual(try processor.process(.reducer(input)), .handled)

        let projection = try repository.projection(
            owner: owner,
            groupJID: groupJID
        )
        XCTAssertEqual(projection.selfMemberID, "owner-member")
        XCTAssertTrue(realm.objects(GroupSelfMembershipStorageItem.self).isEmpty)
        XCTAssertTrue(projection.capabilities.allEnabled)
        XCTAssertTrue(ChatGroupProjectionAdapter.map(projection).isComposerActive)
    }

    func testRosterSubscriptionDoesNotGateOwnerSendOrManagement() {
        for subscription in [
            GroupSelfSubscription.none,
            .wait,
            .both
        ] {
            let projection = GroupRepositoryProjection(
                state: GroupViewState(
                    snapshot: GroupSnapshot(
                        jid: groupJID,
                        settings: GroupSettings(state: .active)
                    ),
                    members: [
                        GroupMember(
                            id: "self-owner",
                            jid: owner,
                            role: .owner
                        )
                    ],
                    selfSubscription: subscription,
                    isDeleted: false
                ),
                selfMemberID: "self-owner",
                capabilities: GroupCapabilities.derive(
                    role: .owner,
                    permissionSet: nil
                )
            )

            XCTAssertTrue(ChatGroupProjectionAdapter.map(projection).isComposerActive)
            let model = GroupchatSettingsCanonicalModel(
                projection: projection,
                outgoingInviteCount: 0,
                blockedCount: 0
            )
            XCTAssertTrue(model.isActive)
            XCTAssertTrue(model.canEditInfo)
            XCTAssertTrue(model.canEditSettings)
            XCTAssertTrue(model.canEditDefaultPermissions)
            XCTAssertTrue(model.canManageAdmins)
            XCTAssertTrue(model.canInvite)
            XCTAssertTrue(model.canBlock)
            XCTAssertTrue(model.canDelete)
        }
    }

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "CreatedGroupOwnerAdmissionTests-\(UUID().uuidString)"
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

    private func applicationSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

}
