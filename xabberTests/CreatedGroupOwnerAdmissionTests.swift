import XCTest
import RealmSwift
@testable import xabber

final class CreatedGroupOwnerAdmissionTests: XCTestCase {
    private let owner = "owner@example.com/ios"
    private let groupJID = "new-room@groups.example.com"

    func testCreateFlowCompletesOwnerAdmissionBeforeOpeningChat() throws {
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
        XCTAssertTrue(source.contains("groupchatService.refreshMembers"))
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
    func testAdmissionPersistsOwnerReadyProjectionBeforePresentation() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let snapshot = GroupSnapshot(
            jid: "NEW-ROOM@GROUPS.EXAMPLE.COM/Service",
            privacy: .publicGroup,
            info: GroupInfo(name: "New room")
        )
        var refreshedGroupJIDs: [String] = []

        let projection = try await CanonicalCreatedGroupOwnerAdmission.admit(
            snapshot: snapshot,
            owner: owner,
            repository: repository,
            refreshMembers: { groupJID in
                refreshedGroupJIDs.append(groupJID)
                return [
                    GroupMember(
                        id: "owner-member",
                        jid: "owner@example.com/Desktop",
                        role: .owner
                    ),
                    GroupMember(
                        id: "member-2",
                        jid: "juliet@example.com",
                        role: .member
                    )
                ]
            }
        )

        XCTAssertEqual(refreshedGroupJIDs, [groupJID])
        XCTAssertEqual(projection.state.selfSubscription, .both)
        XCTAssertEqual(projection.selfMemberID, "owner-member")
        XCTAssertEqual(
            Set(projection.state.members.map(\.id)),
            Set(["owner-member", "member-2"])
        )
        XCTAssertEqual(
            projection.state.members.first(where: { $0.id == "owner-member" })?.role,
            .owner
        )
        XCTAssertTrue(projection.capabilities.allEnabled)
        XCTAssertTrue(ChatGroupProjectionAdapter.map(projection).isComposerActive)
    }

    @MainActor
    func testAdmissionRejectsMemberListWithoutCurrentAccountAndPersistsNothing() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        await XCTAssertThrowsErrorAsync(
            try await CanonicalCreatedGroupOwnerAdmission.admit(
                snapshot: GroupSnapshot(jid: groupJID),
                owner: owner,
                repository: repository,
                refreshMembers: { _ in
                    [
                        GroupMember(
                            id: "another-owner",
                            jid: "juliet@example.com",
                            role: .owner
                        )
                    ]
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? CanonicalCreatedGroupOwnerAdmissionError,
                .missingSelfMemberID
            )
        }

        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupSelfMembershipStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupMemberStorageItem.self).isEmpty)
    }

    @MainActor
    func testAdmissionRejectsNonOwnerCreatorAndPersistsNothing() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        await XCTAssertThrowsErrorAsync(
            try await CanonicalCreatedGroupOwnerAdmission.admit(
                snapshot: GroupSnapshot(jid: groupJID),
                owner: owner,
                repository: repository,
                refreshMembers: { _ in
                    [
                        GroupMember(
                            id: "self-member",
                            jid: "owner@example.com",
                            role: .member
                        )
                    ]
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? CanonicalCreatedGroupOwnerAdmissionError,
                .creatorIsNotOwner
            )
        }

        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupSelfMembershipStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupMemberStorageItem.self).isEmpty)
    }

    func testAuthoritativeMembersEventRepairsActiveProjectionWithMissingSelfID() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(
            .both,
            memberID: nil,
            owner: owner,
            groupJID: groupJID
        )
        try repository.applySnapshot(
            GroupSnapshot(jid: groupJID),
            owner: owner,
            groupJID: groupJID
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
        XCTAssertTrue(projection.capabilities.allEnabled)
        XCTAssertTrue(ChatGroupProjectionAdapter.map(projection).isComposerActive)
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

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
