import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class GroupCreationContractTests: XCTestCase {

    func testMembershipExposesOnlyCanonicalWireValues() {
        XCTAssertEqual(
            Set([GroupMembership.open, .privateGroup].map(\.rawValue)),
            Set(["open", "private"])
        )
        XCTAssertEqual(GroupMembership.privateGroup.rawValue, "private")
        XCTAssertNil(GroupMembership(rawValue: "member-only"))
        XCTAssertNil(GroupMembership(rawValue: "none"))
    }

    func testCreationIsUnavailableWithoutDiscoveredGroupService() {
        XCTAssertEqual(GroupCreationServiceAvailability(discoveredJID: nil), .unavailable)
        XCTAssertEqual(GroupCreationServiceAvailability(discoveredJID: ""), .unavailable)
        XCTAssertNil(GroupCreationServiceAvailability(discoveredJID: nil).serviceJID)
    }

    func testCreationUsesNormalizedDiscoveredServiceJID() {
        let availability = GroupCreationServiceAvailability(
            discoveredJID: "groups.example.com/Discovery"
        )

        XCTAssertEqual(availability, .available(serviceJID: "groups.example.com"))
        XCTAssertEqual(availability.serviceJID, "groups.example.com")
    }

    func testGroupServiceDiscoRequiresCanonicalGroupsFeature() throws {
        let canonical = try DDXMLElement(xmlString: """
            <query xmlns='http://jabber.org/protocol/disco#info'>
              <feature var='https://xabber.com/protocol/groups'/>
            </query>
            """)
        let legacy = try DDXMLElement(xmlString: """
            <query xmlns='http://jabber.org/protocol/disco#info'>
              <feature var='https://xabber.com/protocol/groups#create'/>
            </query>
            """)

        XCTAssertTrue(ServerDiscoManager.supportsGroupService(canonical))
        XCTAssertFalse(ServerDiscoManager.supportsGroupService(legacy))
    }

    func testGroupServiceSelectionFollowsRootItemOrderNotResponseOrder() {
        let ranks = ServerDiscoManager.orderedGroupServiceRanks([
            "Groups.Local.Example/Discovery",
            "groups.remote.example",
            "groups.local.example"
        ])

        XCTAssertEqual(ranks["groups.local.example"], 0)
        XCTAssertEqual(ranks["groups.remote.example"], 1)
        XCTAssertTrue(
            ServerDiscoManager.shouldSelectGroupService(
                candidateRank: 1,
                currentRank: nil
            )
        )
        XCTAssertTrue(
            ServerDiscoManager.shouldSelectGroupService(
                candidateRank: 0,
                currentRank: 1
            )
        )
        XCTAssertFalse(
            ServerDiscoManager.shouldSelectGroupService(
                candidateRank: 1,
                currentRank: 0
            )
        )
    }

    func testCreateFlowUsesTypedServiceAndServerReturnedGroupJID() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let flowURL = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/create_new_entity/new_group/CreateNewGroupViewController+Flow.swift"
        )
        let source = try String(contentsOf: flowURL, encoding: .utf8)

        XCTAssertTrue(source.contains("groupchatService.create"))
        XCTAssertTrue(source.contains("snapshot.jid"))
        XCTAssertFalse(source.contains("groupchats.create"))
        XCTAssertFalse(source.contains("joined(separator: \"@\")"))
    }

    @MainActor
    func testSuccessfulP2PCreatePersistsReturnedSnapshotWithoutSecondJoin() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let returned = GroupSnapshot(
            jid: "private@groups.example.com",
            privacy: .incognito,
            parentJID: "parent@groups.example.com",
            info: GroupInfo(name: "Private room")
        )
        var joinedExistingJIDs: [String] = []

        let result = try await CanonicalGroupP2PFlow.createOrJoin(
            owner: "owner@example.com/ios",
            parentJID: "parent@groups.example.com",
            repository: repository,
            create: { returned },
            joinExisting: { joinedExistingJIDs.append($0) }
        )

        let projection = try repository.projection(
            owner: "owner@example.com",
            groupJID: "private@groups.example.com"
        )
        XCTAssertEqual(result, returned)
        XCTAssertEqual(projection.state.snapshot, returned)
        XCTAssertEqual(projection.state.selfSubscription, .wait)
        XCTAssertTrue(joinedExistingJIDs.isEmpty)
    }

    @MainActor
    func testP2PConflictPersistsExistingSnapshotThenStartsOrdinaryJoin() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let existing = GroupSnapshot(
            jid: "existing@groups.example.com",
            privacy: .incognito
        )
        var joinedExistingJIDs: [String] = []

        let result = try await CanonicalGroupP2PFlow.createOrJoin(
            owner: "owner@example.com/ios",
            parentJID: "parent@groups.example.com/Group",
            repository: repository,
            create: {
                throw GroupchatServiceError.iq(
                    GroupIQStanzaError(
                        type: "cancel",
                        condition: "conflict",
                        text: "Already exists",
                        payload: .snapshot(existing)
                    )
                )
            },
            joinExisting: { joinedExistingJIDs.append($0) }
        )

        let projection = try repository.projection(
            owner: "owner@example.com",
            groupJID: "existing@groups.example.com"
        )
        XCTAssertEqual(result.jid, "existing@groups.example.com")
        XCTAssertEqual(result.privacy, .incognito)
        XCTAssertEqual(result.parentJID, "parent@groups.example.com")
        XCTAssertEqual(projection.state.snapshot, result)
        XCTAssertEqual(projection.state.selfSubscription, .wait)
        XCTAssertEqual(joinedExistingJIDs, ["existing@groups.example.com"])
    }

    @MainActor
    func testP2PConflictDoesNotDowngradeAnAlreadyActiveRoom() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let groupJID = "existing@groups.example.com"
        try repository.setSelfMembership(
            .both,
            memberID: "incognito-self",
            owner: "owner@example.com/ios",
            groupJID: groupJID
        )
        try repository.applySnapshot(
            GroupSnapshot(
                jid: groupJID,
                privacy: .incognito,
                parentJID: "parent@groups.example.com",
                info: GroupInfo(name: "Local room")
            ),
            owner: "owner@example.com/ios",
            groupJID: groupJID
        )
        try repository.replaceMembers(
            [GroupMember(id: "incognito-self", jid: nil, role: .member)],
            owner: "owner@example.com/ios",
            groupJID: groupJID
        )
        let response = GroupSnapshot(
            jid: groupJID
        )
        var joinedExistingJIDs: [String] = []

        _ = try await CanonicalGroupP2PFlow.createOrJoin(
            owner: "owner@example.com/ios",
            parentJID: "parent@groups.example.com",
            repository: repository,
            create: {
                throw GroupchatServiceError.iq(
                    GroupIQStanzaError(
                        type: "cancel",
                        condition: "conflict",
                        text: nil,
                        payload: .snapshot(response)
                    )
                )
            },
            joinExisting: { joinedExistingJIDs.append($0) }
        )

        let projection = try repository.projection(
            owner: "owner@example.com",
            groupJID: groupJID
        )
        XCTAssertEqual(projection.state.selfSubscription, .both)
        XCTAssertEqual(projection.selfMemberID, "incognito-self")
        XCTAssertEqual(projection.state.snapshot.info?.name, "Local room")
        XCTAssertEqual(
            projection.state.snapshot.parentJID,
            "parent@groups.example.com"
        )
        XCTAssertEqual(projection.state.members.map(\.id), ["incognito-self"])
        XCTAssertEqual(joinedExistingJIDs, [groupJID])
    }

    func testParentDeactivationIncludesCascadedP2PConversationTargets() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let owner = "owner@example.com/ios"
        let parent = "parent@groups.example.com"
        let child = "private@groups.example.com"
        let unrelated = "unrelated@groups.example.com"
        for (groupJID, parentJID) in [
            (parent, nil),
            (child, parent),
            (unrelated, nil)
        ] as [(String, String?)] {
            try repository.setSelfMembership(
                .both,
                memberID: "self-\(groupJID)",
                owner: owner,
                groupJID: groupJID
            )
            try repository.applySnapshot(
                GroupSnapshot(jid: groupJID, parentJID: parentJID),
                owner: owner,
                groupJID: groupJID
            )
        }
        try repository.recordLeave(owner: owner, groupJID: parent)

        XCTAssertEqual(
            Set(
                GroupConversationProjectionStore.deactivationTargets(
                    owner: owner,
                    groupJID: parent,
                    in: realm
                )
            ),
            Set([parent, child])
        )
    }

    func testIncognitoSelfIdentityUsesStoredMemberIDWithoutJIDReconstruction() {
        let members = [
            GroupMember(id: "incognito-self", jid: nil, role: .member),
            GroupMember(id: "jid-match", jid: "owner@example.com", role: .member)
        ]

        XCTAssertEqual(
            CanonicalGroupSelfIdentity.resolve(
                existingMemberID: "incognito-self",
                ownerJID: "owner@example.com/ios",
                members: members
            ),
            "incognito-self"
        )
        XCTAssertNil(members[0].jid)
    }

    @MainActor
    func testPeerToPeerExitUsesDeleteMode() {
        XCTAssertEqual(
            CanonicalGroupMembershipLifecycle.exitMode(
                snapshot: GroupSnapshot(
                    jid: "private@groups.example.com",
                    parentJID: "parent@groups.example.com"
                ),
                selfMemberID: nil,
                members: []
            ),
            .deletePeerToPeer
        )
    }

    func testPeerToPeerAndLastOwnerHaveDistinctDeletePresentation() throws {
        XCTAssertTrue(CanonicalGroupMembershipLifecycle.ExitMode.deletePeerToPeer.deletesGroup)
        XCTAssertTrue(CanonicalGroupMembershipLifecycle.ExitMode.deleteLastOwner.deletesGroup)
        XCTAssertFalse(CanonicalGroupMembershipLifecycle.ExitMode.leave.deletesGroup)

        let contacts = try source(
            "xabber/controllers/chats/contact_list/ContactsViewController+UITableViewAction.swift"
        )
        let info = try source(
            "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController.swift"
        )
        XCTAssertTrue(contacts.contains("case .deletePeerToPeer:"))
        XCTAssertTrue(contacts.contains("id: \"groupchat_delete_p2p_confirm\""))
        XCTAssertTrue(contacts.contains("case .deleteLastOwner:"))
        XCTAssertTrue(contacts.contains("id: \"groupchat_delete_last_owner_confirm\""))
        XCTAssertTrue(info.contains("id: \"exit\""))

        for locale in ["en", "ru"] {
            let strings = try source("xabber/translations/\(locale).lproj/Localizable.strings")
            XCTAssertTrue(strings.contains("\"groupchat_delete_p2p_confirm\""), locale)
            XCTAssertTrue(strings.contains("\"groupchat_delete_last_owner_confirm\""), locale)
        }
    }

    func testBothP2PEntryPointsUseSharedConflictReconciliationBeforeOpening() throws {
        let contactInfo = try source(
            "xabber/controllers/chats/info_screens/groupchat_contact_info/GroupchatContactInfoViewController+InfoScreenHeaderButtonDelegate.swift"
        )
        let members = try source(
            "xabber/controllers/chats/groupchats/info/GroupchatMembersListViewController.swift"
        )

        for caller in [contactInfo, members] {
            XCTAssertTrue(caller.contains("CanonicalGroupP2PFlow.createOrJoin"))
            XCTAssertTrue(caller.contains("showDetail"))
        }
    }

    func testCanonicalGroupLifecycleUIUsesTypedServiceAndRepositoryProjection() throws {
        let join = try source(
            "xabber/controllers/chats/groupchats/join/GroupchatJoinViewController.swift"
        )
        let chatInvites = try source(
            "xabber/controllers/chats/chat/extension/ChatViewController+Invitations.swift"
        )
        let contactActions = try source(
            "xabber/controllers/chats/contact_list/ContactsViewController+UITableViewAction.swift"
        )
        let contactInvites = try source(
            "xabber/controllers/chats/contact_list/ContactsViewController+UITableViewDataSource.swift"
        )
        let info = try source(
            "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController+InfoScreenHeaderButtonDelegate.swift"
        )
        let lifecycle = try source(
            "xabber/models/account/delegates/AccountGroupchatIntegration.swift"
        )

        XCTAssertTrue(join.contains("CanonicalGroupMembershipLifecycle.join"))
        XCTAssertTrue(join.contains("groupchatService.declineInvite"))
        XCTAssertTrue(join.contains("removeCanonicalGroupInvite"))
        XCTAssertTrue(lifecycle.contains("expected: .both"))
        XCTAssertTrue(lifecycle.contains("expected: .none"))
        XCTAssertTrue(lifecycle.contains("observeProjection"))
        XCTAssertTrue(lifecycle.contains(".setSelfMembership("))
        XCTAssertTrue(lifecycle.contains(".wait,"))
        XCTAssertTrue(lifecycle.contains("recordDeletion("))

        XCTAssertTrue(chatInvites.contains("CanonicalGroupMembershipLifecycle.join"))
        XCTAssertTrue(chatInvites.contains("groupchatService.declineInvite"))
        XCTAssertTrue(chatInvites.contains("removeCanonicalGroupInvite"))

        XCTAssertTrue(contactActions.contains("CanonicalGroupMembershipLifecycle.leave"))
        XCTAssertTrue(contactActions.contains("groupchatService.declineInvite"))
        XCTAssertTrue(contactInvites.contains("CanonicalGroupMembershipLifecycle.join"))
        XCTAssertTrue(contactInvites.contains("groupchatService.declineInvite"))

        XCTAssertTrue(info.contains("CanonicalGroupMembershipLifecycle.leave"))
        XCTAssertTrue(info.contains("CanonicalGroupMembershipLifecycle.delete"))
        XCTAssertTrue(info.contains("GroupRepository(realm:"))

        [join, chatInvites, contactActions, contactInvites, info].forEach {
            XCTAssertFalse($0.contains("groupchats.join"))
            XCTAssertFalse($0.contains("groupchats.decline"))
            XCTAssertFalse($0.contains("groupchats.leave"))
            XCTAssertFalse($0.contains("groupchats.delete"))
            XCTAssertFalse($0.contains("groupchats.afterLeave"))
        }
    }

    func testDeniedJoinTerminatesImmediatelyInsteadOfWaitingForTimeout() {
        XCTAssertEqual(
            CanonicalGroupMembershipLifecycle.terminalError(
                observed: .none,
                expected: .both
            ),
            .rejected
        )
        XCTAssertNil(
            CanonicalGroupMembershipLifecycle.terminalError(
                observed: .wait,
                expected: .both
            )
        )
        XCTAssertNil(
            CanonicalGroupMembershipLifecycle.terminalError(
                observed: .none,
                expected: .none
            )
        )
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

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "GroupCreationContractTests-\(UUID().uuidString)"
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
}
