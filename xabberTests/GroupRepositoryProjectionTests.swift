import XCTest
import RealmSwift
@testable import xabber

final class GroupRepositoryProjectionTests: XCTestCase {
    private let owner = "romeo@example.com/ios"
    private let group = "Stage@Example.com/Group"

    func testViewStateIsAnImmutableProjectionOfCanonicalRealmRows() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(
            .both,
            memberID: "self-1",
            owner: owner,
            groupJID: group
        )
        try repository.applySnapshot(
            GroupSnapshot(
                jid: group,
                privacy: .incognito,
                memberCount: 2,
                info: GroupInfo(name: "Stage"),
                settings: GroupSettings(membership: .privateGroup, index: .none),
                pinnedMessageIDs: ["stanza-1", "stanza-2"]
            ),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [
                GroupMember(id: "self-1", role: .owner, nickname: "Romeo"),
                GroupMember(id: "member-2", role: .member, nickname: "Juliet")
            ],
            owner: owner,
            groupJID: group
        )
        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .direct,
                target: "self-1",
                permissions: [
                    GroupPermission(name: "send-messages", level: "member", status: true)
                ]
            ),
            owner: owner,
            groupJID: group
        )

        let projection = try repository.projection(owner: owner, groupJID: group)

        XCTAssertEqual(projection.selfMemberID, "self-1")
        XCTAssertEqual(projection.state.selfSubscription, .both)
        XCTAssertTrue(projection.state.isActive)
        XCTAssertEqual(projection.state.snapshot.jid, "stage@example.com")
        XCTAssertEqual(projection.state.snapshot.privacy, .incognito)
        XCTAssertEqual(projection.state.snapshot.info?.name, "Stage")
        XCTAssertEqual(projection.state.snapshot.settings?.membership, .privateGroup)
        XCTAssertEqual(projection.state.snapshot.pinnedMessageIDs, ["stanza-1", "stanza-2"])
        XCTAssertEqual(projection.state.members.map(\.id), ["member-2", "self-1"])
        XCTAssertEqual(projection.state.permissionSets.count, 1)

        try realm.write {
            realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: GroupStorageKey.groupPrimary(owner: owner, groupJID: group)
            )?.name = "Changed behind the projection"
        }
        XCTAssertEqual(projection.state.snapshot.info?.name, "Stage")
    }

    func testProjectionDerivesCapabilitiesFromSelfMemberAndPersonalPermissions() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.both, memberID: "self-1", owner: owner, groupJID: group)
        try repository.applySnapshot(
            GroupSnapshot(jid: group),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [GroupMember(id: "self-1", role: .member, nickname: "Romeo")],
            owner: owner,
            groupJID: group
        )
        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .direct,
                target: "self-1",
                permissions: [
                    GroupPermission(name: "send-messages", level: "member", status: true),
                    GroupPermission(name: "pin-messages", level: "member", status: false)
                ]
            ),
            owner: owner,
            groupJID: group
        )

        let projection = try repository.projection(owner: owner, groupJID: group)

        XCTAssertTrue(projection.capabilities.sendMessages)
        XCTAssertFalse(projection.capabilities.pinMessages)
        XCTAssertFalse(projection.capabilities.changePermissions)
    }

    func testProjectionPreservesAbsentAndExplicitEmptyContainers() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.both, memberID: "self-1", owner: owner, groupJID: group)

        try repository.applySnapshot(
            GroupSnapshot(jid: group),
            owner: owner,
            groupJID: group
        )

        var projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertNil(projection.state.snapshot.settings)
        XCTAssertNil(projection.state.snapshot.pinnedMessageIDs)

        try repository.applySnapshot(
            GroupSnapshot(
                jid: group,
                settings: GroupSettings(contacts: [], domains: nil),
                pinnedMessageIDs: []
            ),
            owner: owner,
            groupJID: group
        )

        projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertNotNil(projection.state.snapshot.settings)
        XCTAssertEqual(projection.state.snapshot.settings?.contacts, [])
        XCTAssertNil(projection.state.snapshot.settings?.domains)
        XCTAssertEqual(projection.state.snapshot.pinnedMessageIDs, [])

        try repository.applyPatch(
            GroupPatch(
                settings: .value(
                    GroupSettingsPatch(
                        contacts: .value(nil),
                        domains: .value([])
                    )
                ),
                pinnedMessageIDs: .value(nil)
            ),
            owner: owner,
            groupJID: group
        )

        projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertNotNil(projection.state.snapshot.settings)
        XCTAssertNil(projection.state.snapshot.settings?.contacts)
        XCTAssertEqual(projection.state.snapshot.settings?.domains, [])
        XCTAssertNil(projection.state.snapshot.pinnedMessageIDs)

        try repository.applyPatch(
            GroupPatch(settings: .value(nil)),
            owner: owner,
            groupJID: group
        )

        projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertNil(projection.state.snapshot.settings)
    }

    func testObservationEmitsUpdatedImmutableProjection() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.both, memberID: "self-1", owner: owner, groupJID: group)
        try repository.applySnapshot(
            GroupSnapshot(jid: group, info: GroupInfo(name: "Before")),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [GroupMember(id: "self-1", jid: owner, role: .owner)],
            owner: owner,
            groupJID: group
        )
        let updated = expectation(description: "updated projection")
        var observedNames: [String] = []
        let observation = try repository.observeProjection(owner: owner, groupJID: group) { projection in
            observedNames.append(projection.state.snapshot.info?.name ?? "")
            if projection.state.snapshot.info?.name == "After" {
                updated.fulfill()
            }
        }

        try repository.applyPatch(
            GroupPatch(info: .value(GroupInfoPatch(name: .value("After")))),
            owner: owner,
            groupJID: group
        )

        wait(for: [updated], timeout: 1)
        observation.invalidate()
        XCTAssertEqual(observedNames.last, "After")
    }

    func testObservationCoalescesOneTransactionIntoOneFinalProjection() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.both, memberID: "self-1", owner: owner, groupJID: group)
        try repository.applySnapshot(
            GroupSnapshot(jid: group, info: GroupInfo(name: "Before")),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [GroupMember(id: "self-1", role: .owner)],
            owner: owner,
            groupJID: group
        )
        try repository.replacePermissionSet(
            GroupPermissionSet(
                scope: .direct,
                target: "self-1",
                permissions: [GroupPermission(name: "send-messages", status: true)]
            ),
            owner: owner,
            groupJID: group
        )

        let initial = expectation(description: "initial projection")
        let terminal = expectation(description: "terminal projection")
        var projections: [GroupRepositoryProjection] = []
        let observation = try repository.observeProjection(owner: owner, groupJID: group) { projection in
            projections.append(projection)
            if projections.count == 1 {
                initial.fulfill()
            }
            if projection.state.isDeleted {
                terminal.fulfill()
            }
        }

        wait(for: [initial], timeout: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(projections.count, 1)

        try repository.recordLeave(owner: owner, groupJID: group)

        wait(for: [terminal], timeout: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        observation.invalidate()

        XCTAssertEqual(projections.count, 2)
        XCTAssertEqual(projections.first?.state.snapshot.info?.name, "Before")
        XCTAssertEqual(projections.last?.state.snapshot.info?.name, nil)
        XCTAssertEqual(
            projections.last?.state.selfSubscription,
            GroupSelfSubscription.none
        )
        XCTAssertTrue(projections.last?.state.members.isEmpty == true)
        XCTAssertTrue(projections.last?.state.permissionSets.isEmpty == true)
    }

    func testListStateReturnsImmutableActiveGroupsAndIncomingInvitesForSelectedOwners() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(
            .both,
            memberID: "self-1",
            owner: owner,
            groupJID: group
        )
        try repository.applySnapshot(
            GroupSnapshot(jid: group, info: GroupInfo(name: "Before")),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [GroupMember(id: "self-1", jid: owner, role: .owner)],
            owner: owner,
            groupJID: group
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "invite@example.com",
                direction: .incoming,
                target: "member-2"
            ),
            owner: owner
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "outgoing@example.com",
                direction: .outgoing,
                target: "target@example.com"
            ),
            owner: owner
        )
        try repository.setSelfMembership(
            .both,
            memberID: "other-self",
            owner: "other@example.com",
            groupJID: "other-group@example.com"
        )
        try repository.applySnapshot(
            GroupSnapshot(jid: "other-group@example.com", info: GroupInfo(name: "Other")),
            owner: "other@example.com",
            groupJID: "other-group@example.com"
        )
        try repository.replaceMembers(
            [GroupMember(id: "other-self", jid: "other@example.com", role: .owner)],
            owner: "other@example.com",
            groupJID: "other-group@example.com"
        )

        let state = try repository.listState(owners: [owner])

        XCTAssertEqual(state.activeGroups.map(\.groupJID), ["stage@example.com"])
        XCTAssertEqual(state.activeGroups.first?.projection.state.snapshot.info?.name, "Before")
        XCTAssertEqual(state.incomingInvites.map(\.groupJID), ["invite@example.com"])
        XCTAssertTrue(state.incomingInvites.allSatisfy { $0.direction == .incoming })

        try repository.applyPatch(
            GroupPatch(info: .value(GroupInfoPatch(name: .value("After")))),
            owner: owner,
            groupJID: group
        )
        XCTAssertEqual(state.activeGroups.first?.projection.state.snapshot.info?.name, "Before")
    }

    func testListObservationPublishesImmutableStateAfterGroupAndInviteChanges() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let activeGroupObserved = expectation(description: "active group observed")
        let inviteObserved = expectation(description: "incoming invite observed")
        var states: [GroupRepositoryListState] = []
        var didFulfillActiveGroup = false
        var didFulfillInvite = false
        let observation = try repository.observeList(owners: [owner]) { state in
            states.append(state)
            if !didFulfillActiveGroup,
               state.activeGroups.map(\.groupJID) == ["stage@example.com"] {
                didFulfillActiveGroup = true
                activeGroupObserved.fulfill()
            }
            if !didFulfillInvite,
               state.incomingInvites.map(\.groupJID) == ["invite@example.com"] {
                didFulfillInvite = true
                inviteObserved.fulfill()
            }
        }

        try repository.setSelfMembership(
            .both,
            memberID: "self-1",
            owner: owner,
            groupJID: group
        )
        try repository.applySnapshot(
            GroupSnapshot(jid: group, info: GroupInfo(name: "Stage")),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [GroupMember(id: "self-1", jid: owner, role: .owner)],
            owner: owner,
            groupJID: group
        )
        try repository.storeInvite(
            GroupInviteRecord(
                groupJID: "invite@example.com",
                direction: .incoming,
                target: "member-2"
            ),
            owner: owner
        )

        wait(for: [activeGroupObserved, inviteObserved], timeout: 1)
        observation.invalidate()

        XCTAssertEqual(states.first, GroupRepositoryListState())
        XCTAssertEqual(states.last?.activeGroups.first?.projection.state.snapshot.info?.name, "Stage")
        XCTAssertEqual(states.last?.incomingInvites.first?.target, "member-2")
    }

    func testOpaqueListObservationRetainsRepositoryBoundaryUntilInvalidated() throws {
        let realm = try makeRealm()
        let inviteObserved = expectation(description: "invite observed after repository scope ends")
        let observation: GroupRepositoryListObservation
        do {
            let scopedRepository = GroupRepository(realm: realm)
            observation = try scopedRepository.observeList(owners: [owner]) { state in
                if state.incomingInvites.map(\.groupJID) == ["invite@example.com"] {
                    inviteObserved.fulfill()
                }
            }
        }

        try GroupRepository(realm: realm).storeInvite(
            GroupInviteRecord(
                groupJID: "invite@example.com",
                direction: .incoming,
                target: "member-2"
            ),
            owner: owner
        )

        wait(for: [inviteObserved], timeout: 1)
        observation.invalidate()
    }

    func testIncomingInviteObservationPublishesOnlyImmutableSelectedOwnerRecords() throws {
        let realm = try makeRealm()
        let inviteObserved = expectation(description: "selected incoming invite observed")
        var observed: [[GroupInviteRecord]] = []
        let observation: GroupRepositoryIncomingInvitesObservation
        do {
            let scopedRepository = GroupRepository(realm: realm)
            observation = scopedRepository.observeIncomingInvites(owners: [owner]) { invites in
                observed.append(invites)
                if invites.map(\.groupJID) == ["invite@example.com"] {
                    inviteObserved.fulfill()
                }
            }
        }
        let writer = GroupRepository(realm: realm)
        try writer.storeInvite(
            GroupInviteRecord(
                groupJID: "outgoing@example.com",
                direction: .outgoing,
                target: "target@example.com"
            ),
            owner: owner
        )
        try writer.storeInvite(
            GroupInviteRecord(
                groupJID: "other@example.com",
                direction: .incoming,
                target: "other-member"
            ),
            owner: "other-owner@example.com"
        )
        try writer.storeInvite(
            GroupInviteRecord(
                groupJID: "invite@example.com",
                direction: .incoming,
                target: "member-2"
            ),
            owner: owner
        )

        wait(for: [inviteObserved], timeout: 1)
        observation.invalidate()

        XCTAssertEqual(observed.first ?? [], [])
        XCTAssertEqual(observed.last?.map(\.owner), ["romeo@example.com"])
        XCTAssertEqual(observed.last?.map(\.target), ["member-2"])
    }

    func testChatProjectionUsesLastCanonicalPinAndActiveCapabilities() {
        let projection = GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: GroupSnapshot(
                    jid: group,
                    pinnedMessageIDs: ["group-stanza-1", "group-stanza-2"]
                ),
                members: [
                    GroupMember(id: "member-2", nickname: "Juliet"),
                    GroupMember(id: "self-1", nickname: "Romeo")
                ],
                selfSubscription: .both
            ),
            selfMemberID: "self-1",
            capabilities: GroupCapabilities(
                sendMessages: true,
                sendMedia: true,
                addMembers: false,
                pinMessages: true,
                changeGroupInfo: false,
                changeGroupSettings: false,
                changeUserInfo: false,
                deleteMessages: false,
                changePermissions: false,
                changeDefaultPermissions: false,
                blockUsers: false,
                createAdmins: false
            )
        )

        let state = ChatGroupProjectionAdapter.map(projection)

        XCTAssertEqual(state.pinnedMessageIDs, ["group-stanza-1", "group-stanza-2"])
        XCTAssertEqual(state.lastPinnedMessageID, "group-stanza-1")
        XCTAssertEqual(state.selfMemberID, "self-1")
        XCTAssertEqual(state.selfMember?.nickname, "Romeo")
        XCTAssertEqual(state.members.map(\.id), ["member-2", "self-1"])
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.isComposerActive)
        XCTAssertTrue(state.canPinMessages)
        XCTAssertTrue(state.canUnpinLastMessage)
        XCTAssertTrue(
            ChatGroupProjectionAdapter.allowsComposer(
                baseEnabled: true,
                isGroupConversation: true,
                state: state
            )
        )
    }

    func testCanonicalGroupChatPresenceRequiresActiveGroupAndDeduplicatesState() {
        let active = ChatGroupProjectionState(
            pinnedMessageIDs: nil,
            selfMemberID: "self-1",
            members: [GroupMember(id: "self-1", role: .member)],
            capabilities: GroupCapabilities(
                sendMessages: true,
                sendMedia: true,
                addMembers: false,
                pinMessages: false,
                changeGroupInfo: false,
                changeGroupSettings: false,
                changeUserInfo: false,
                deleteMessages: false,
                changePermissions: false,
                changeDefaultPermissions: false,
                blockUsers: false,
                createAdmins: false
            ),
            isActive: true,
            isDeleted: false
        )
        let waiting = ChatGroupProjectionState(
            pinnedMessageIDs: nil,
            selfMemberID: "self-1",
            members: [],
            capabilities: active.capabilities,
            isActive: false,
            isDeleted: false
        )

        XCTAssertTrue(
            ChatCanonicalGroupPresencePolicy.shouldSend(
                .active,
                conversationIsGroup: true,
                projection: active,
                lastSent: nil
            )
        )
        XCTAssertTrue(
            ChatCanonicalGroupPresencePolicy.shouldSend(
                .inactive,
                conversationIsGroup: true,
                projection: active,
                lastSent: .active
            )
        )
        XCTAssertFalse(
            ChatCanonicalGroupPresencePolicy.shouldSend(
                .active,
                conversationIsGroup: true,
                projection: active,
                lastSent: .active
            )
        )
        XCTAssertFalse(
            ChatCanonicalGroupPresencePolicy.shouldSend(
                .active,
                conversationIsGroup: true,
                projection: waiting,
                lastSent: nil
            )
        )
        XCTAssertFalse(
            ChatCanonicalGroupPresencePolicy.shouldSend(
                .active,
                conversationIsGroup: false,
                projection: active,
                lastSent: nil
            )
        )
    }

    func testChatUIKitReadsCanonicalGroupEntitiesOnlyThroughProjection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "xabber/controllers/chats/chat/ChatViewController.swift",
            "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift",
            "xabber/controllers/chats/chat/rx/ChatViewController+LowPrioritySubscribtions.swift"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("realm.objects(GroupMemberStorageItem.self)"), relativePath)
            XCTAssertFalse(source.contains("ofType: GroupMemberStorageItem.self"), relativePath)
            XCTAssertFalse(source.contains("ofType: GroupSelfMembershipStorageItem.self"), relativePath)
        }
    }

    func testChatLifecyclePublishesCanonicalXEP0085StatesThroughTypedService() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("self.sendCanonicalGroupChatPresence(.active)"))
        XCTAssertTrue(source.contains("self.sendCanonicalGroupChatPresence(.inactive)"))
        XCTAssertTrue(source.contains("self.sendCanonicalGroupChatPresence(.gone)"))
        XCTAssertTrue(source.contains("account.groupchatService.sendChatPresence"))
        XCTAssertFalse(source.contains("#present"))
        XCTAssertFalse(source.contains("#not-present"))
    }

    func testChatProjectionKeepsComposerAndPinMutationInactiveForInactiveOrDeletedGroup() {
        let capabilities = GroupCapabilities(
            sendMessages: true,
            sendMedia: true,
            addMembers: true,
            pinMessages: true,
            changeGroupInfo: true,
            changeGroupSettings: true,
            changeUserInfo: true,
            deleteMessages: true,
            changePermissions: true,
            changeDefaultPermissions: true,
            blockUsers: true,
            createAdmins: true
        )
        let inactiveProjection = GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: GroupSnapshot(
                    jid: group,
                    settings: GroupSettings(state: .inactive),
                    pinnedMessageIDs: ["group-stanza-1"]
                )
            ),
            selfMemberID: "self-1",
            capabilities: capabilities
        )
        let deletedProjection = GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: GroupSnapshot(jid: group, pinnedMessageIDs: ["group-stanza-1"]),
                isDeleted: true
            ),
            selfMemberID: "self-1",
            capabilities: capabilities
        )

        for state in [
            ChatGroupProjectionAdapter.map(inactiveProjection),
            ChatGroupProjectionAdapter.map(deletedProjection)
        ] {
            XCTAssertFalse(state.isActive)
            XCTAssertFalse(state.isComposerActive)
            XCTAssertFalse(state.canUnpinLastMessage)
            XCTAssertFalse(
                ChatGroupProjectionAdapter.allowsComposer(
                    baseEnabled: true,
                    isGroupConversation: true,
                    state: state
                )
            )
        }
    }

    func testChatProjectionRequiresSendPermissionAndPreservesAbsentPinList() {
        let projection = GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: GroupSnapshot(jid: group, pinnedMessageIDs: nil),
                selfSubscription: .both
            ),
            selfMemberID: "self-1",
            capabilities: GroupCapabilities(
                sendMessages: false,
                sendMedia: false,
                addMembers: false,
                pinMessages: true,
                changeGroupInfo: false,
                changeGroupSettings: false,
                changeUserInfo: false,
                deleteMessages: false,
                changePermissions: false,
                changeDefaultPermissions: false,
                blockUsers: false,
                createAdmins: false
            )
        )

        let state = ChatGroupProjectionAdapter.map(projection)

        XCTAssertNil(state.pinnedMessageIDs)
        XCTAssertNil(state.lastPinnedMessageID)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.isComposerActive)
        XCTAssertFalse(state.canUnpinLastMessage)
        XCTAssertFalse(
            ChatGroupProjectionAdapter.allowsComposer(
                baseEnabled: true,
                isGroupConversation: true,
                state: state
            )
        )
        XCTAssertTrue(
            ChatGroupProjectionAdapter.allowsComposer(
                baseEnabled: true,
                isGroupConversation: false,
                state: nil
            )
        )
        XCTAssertFalse(
            ChatGroupProjectionAdapter.allowsComposer(
                baseEnabled: false,
                isGroupConversation: false,
                state: nil
            )
        )
    }

    func testMigratedPinnedSubscriptionHasNoLegacyGroupStorageRead() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "internal func observeCanonicalGroupProjection() throws"))
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: "\n    }"))
        let migratedBlock = String(suffix[..<end.upperBound])

        XCTAssertTrue(migratedBlock.contains("ChatGroupProjectionObserver"))
        XCTAssertFalse(migratedBlock.contains("GroupChatStorageItem"))
        XCTAssertFalse(migratedBlock.contains("realm.write"))
    }

    func testChatProjectionObserverPublishesCanonicalPinUpdates() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(
            .both,
            memberID: "self-1",
            owner: owner,
            groupJID: group
        )
        try repository.applySnapshot(
            GroupSnapshot(jid: group, pinnedMessageIDs: ["group-stanza-1"]),
            owner: owner,
            groupJID: group
        )
        try repository.replaceMembers(
            [GroupMember(id: "self-1", role: .owner)],
            owner: owner,
            groupJID: group
        )
        let updated = expectation(description: "canonical pin update")
        var states: [ChatGroupProjectionState] = []
        let observer = ChatGroupProjectionObserver()
        try observer.observe(repository: repository, owner: owner, groupJID: group) { state in
            states.append(state)
            if state.lastPinnedMessageID == "group-stanza-2" {
                updated.fulfill()
            }
        }

        try repository.applyPatch(
            GroupPatch(pinnedMessageIDs: .value(["group-stanza-2", "group-stanza-1"])),
            owner: owner,
            groupJID: group
        )

        wait(for: [updated], timeout: 1)
        observer.invalidate()
        XCTAssertEqual(states.first?.lastPinnedMessageID, "group-stanza-1")
        XCTAssertEqual(states.last?.lastPinnedMessageID, "group-stanza-2")
        XCTAssertEqual(states.last?.pinnedMessageIDs, ["group-stanza-2", "group-stanza-1"])
    }

    func testPinnedMessageSelectionUsesEveryCanonicalIDWithNewestFirst() {
        XCTAssertEqual(
            ChatPinnedMessageSelectionPolicy.displayedMessageIDs(
                ["group-stanza-1", "", "0", "group-stanza-2", "group-stanza-1"]
            ),
            ["group-stanza-1", "group-stanza-2"]
        )
    }

    func testPinCapabilityDoesNotDependOnAnExistingPin() {
        let state = ChatGroupProjectionState(
            pinnedMessageIDs: [],
            selfMemberID: "self-1",
            members: [GroupMember(id: "self-1", role: .admin)],
            capabilities: GroupCapabilities(
                sendMessages: true,
                sendMedia: true,
                addMembers: false,
                pinMessages: true,
                changeGroupInfo: false,
                changeGroupSettings: false,
                changeUserInfo: false,
                deleteMessages: false,
                changePermissions: false,
                changeDefaultPermissions: false,
                blockUsers: false,
                createAdmins: false
            ),
            isActive: true,
            isDeleted: false
        )

        XCTAssertTrue(state.canPinMessages)
        XCTAssertFalse(state.canUnpinLastMessage)
        XCTAssertEqual(
            ChatPinnedMessageActionPolicy.action(
                groupStanzaID: "group-stanza-1",
                pinnedMessageIDs: state.pinnedMessageIDs,
                canPin: state.canPinMessages
            ),
            .pin
        )
    }

    func testPinnedMessageActionUsesCanonicalGroupStanzaIDAndCurrentSnapshot() {
        XCTAssertEqual(
            ChatPinnedMessageActionPolicy.action(
                groupStanzaID: "group-stanza-2",
                pinnedMessageIDs: ["group-stanza-2", "group-stanza-1"],
                canPin: true
            ),
            .unpin
        )
        XCTAssertNil(
            ChatPinnedMessageActionPolicy.action(
                groupStanzaID: "",
                pinnedMessageIDs: [],
                canPin: true
            )
        )
        XCTAssertNil(
            ChatPinnedMessageActionPolicy.action(
                groupStanzaID: "group-stanza-3",
                pinnedMessageIDs: [],
                canPin: false
            )
        )
    }

    func testCellMenuRoutesCanonicalPinActionThroughTypedService() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menu = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/delegate/action/ChatViewController+CellDelegate.swift"
            ),
            encoding: .utf8
        )
        let mutation = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+AdditionalNavbarPanel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(menu.contains("pinnedMessageContextMenuItem(for: item)"))
        XCTAssertTrue(menu.contains("groupStanzaID = item.archivedId"))
        XCTAssertTrue(menu.contains("performPinnedMessageMutation("))
        XCTAssertTrue(mutation.contains("account.groupchatService.pin("))
        XCTAssertTrue(mutation.contains("account.groupchatService.unpin("))
    }

    func testPinnedMessageSelectionFallsBackToCurrentPinBeforeProjectionArrives() {
        XCTAssertEqual(
            ChatPinnedMessageSelectionPolicy.displayedMessageIDs(
                nil,
                fallbackMessageID: "group-stanza-current"
            ),
            ["group-stanza-current"]
        )
    }

    func testChatInputBindsMentionAllToCanonicalSelfRoleOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chat = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )
        let projection = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(chat.contains("mentionAllCandidateProvider"))
        XCTAssertTrue(chat.contains("ComposerMentionCandidate.mentionAll(groupJID: self.jid)"))
        XCTAssertTrue(chat.contains("groupMentionSenderRole = nil"))
        XCTAssertTrue(chat.contains("groupMentionAllCapabilityGranted = false"))
        XCTAssertTrue(projection.contains("groupMentionSenderRole = state.selfMember?.role"))
        XCTAssertFalse(chat.contains("GroupMemberStorageItem"))
    }
}

private extension GroupRepositoryProjectionTests {
    func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
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
