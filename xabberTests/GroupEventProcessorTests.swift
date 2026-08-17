import XCTest
import RealmSwift
@testable import xabber

final class GroupEventProcessorTests: XCTestCase {
    private let owner = "romeo@example.com/ios"
    private let group = "stage@example.com"

    func testJoinReplyIsSentWhileWaitingAndActivationHappensAfterReply() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(
            .wait,
            memberID: nil,
            owner: owner,
            groupJID: group
        )
        var stateObservedDuringReply: GroupSelfSubscription?
        var activations: [String] = []
        let processor = GroupEventProcessor(
            owner: owner,
            repository: { repository },
            sendPresenceReply: { routedGroup, reply in
                XCTAssertEqual(routedGroup, self.group)
                XCTAssertEqual(reply, .subscribed)
                stateObservedDuringReply = try repository
                    .projection(owner: self.owner, groupJID: self.group)
                    .state.selfSubscription
            },
            onActivated: { activations.append($0) }
        )
        let input = GroupReducerInput(
            groupJID: group,
            ingress: .presence,
            events: [
                .snapshot(
                    GroupSnapshot(
                        jid: group,
                        info: GroupInfo(name: "Stage")
                    )
                )
            ],
            requiredReply: .subscribed,
            eventsAfterReply: [.selfSubscription(.both)]
        )

        XCTAssertEqual(try processor.process(.reducer(input)), .handled)

        XCTAssertEqual(stateObservedDuringReply, .wait)
        let projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertEqual(projection.state.selfSubscription, .both)
        XCTAssertEqual(projection.state.snapshot.info?.name, "Stage")
        XCTAssertEqual(activations, [group])
    }

    func testFailedRequiredReplyLeavesMembershipWaiting() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.wait, memberID: nil, owner: owner, groupJID: group)
        let processor = GroupEventProcessor(
            owner: owner,
            repository: { repository },
            sendPresenceReply: { _, _ in throw ProbeError.sendFailed }
        )
        let input = GroupReducerInput(
            groupJID: group,
            ingress: .presence,
            events: [.snapshot(GroupSnapshot(jid: group))],
            requiredReply: .subscribed,
            eventsAfterReply: [.selfSubscription(.both)]
        )

        XCTAssertThrowsError(try processor.process(.reducer(input))) { error in
            XCTAssertEqual(error as? ProbeError, .sendFailed)
        }
        XCTAssertEqual(
            try repository.projection(owner: owner, groupJID: group).state.selfSubscription,
            .wait
        )
    }

    func testIncomingInviteStaysSeparateAndDoesNotCreateGroupState() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let processor = GroupEventProcessor(owner: owner, repository: { repository })
        let invite = GroupInviteMessageEvent(
            groupJID: group,
            source: .live,
            messageID: "invite-1",
            invite: .message(
                groupJID: group,
                reason: "Join us",
                inviter: GroupMember(id: "member-7", nickname: "Juliet")
            ),
            preview: GroupSnapshot(jid: group, info: GroupInfo(name: "Stage"))
        )

        XCTAssertEqual(try processor.process(.invite(invite)), .invite(invite))
        XCTAssertEqual(realm.objects(GroupInviteStorageItem.self).count, 1)
        let storedInvite = try XCTUnwrap(
            repository.incomingInvite(owner: owner, groupJID: group)
        )
        XCTAssertEqual(storedInvite.inviter?.id, "member-7")
        XCTAssertEqual(storedInvite.inviter?.nickname, "Juliet")
        XCTAssertEqual(storedInvite.preview?.info?.name, "Stage")
        XCTAssertTrue(realm.objects(GroupSnapshotStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(GroupSelfMembershipStorageItem.self).isEmpty)
    }

    func testMessageAuthorSnapshotNeverMutatesAuthoritativeMembers() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.both, memberID: "self", owner: owner, groupJID: group)
        try repository.applySnapshot(GroupSnapshot(jid: group), owner: owner, groupJID: group)
        try repository.replaceMembers(
            [GroupMember(id: "member-7", nickname: "Authoritative")],
            owner: owner,
            groupJID: group
        )
        let processor = GroupEventProcessor(owner: owner, repository: { repository })
        let message = GroupMessageEvent(
            groupJID: group,
            source: .live,
            stanzaType: .chat,
            messageID: "message-1",
            originID: "origin-1",
            stanzaID: "stanza-1",
            stanzaIDBy: group,
            body: "Hello",
            author: GroupMember(id: "member-7", nickname: "Historical snapshot"),
            systemEvent: nil
        )

        XCTAssertEqual(try processor.process(.message(message)), .message(message))
        XCTAssertEqual(
            try repository.projection(owner: owner, groupJID: group)
                .state.member(id: "member-7")?.nickname,
            "Authoritative"
        )
    }

    func testCanonicalMessageRoutingDispositionSeparatesPersistenceFromConsumption() {
        XCTAssertNotEqual(
            Account.CanonicalGroupMessageRouting.validatedMessage,
            .consumed
        )
        XCTAssertNotEqual(
            Account.CanonicalGroupMessageRouting.validatedMessage,
            .notGroup
        )
    }

    func testTrailingCanonicalMessageRequiresActiveSelfMemberNotRosterSubscription() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)

        XCTAssertFalse(
            CanonicalGroupMessageAdmission.allowsPersistence(
                owner: owner,
                groupJID: group,
                repository: repository
            )
        )

        try repository.setSelfMembership(
            .none,
            memberID: "self",
            owner: owner,
            groupJID: group
        )
        XCTAssertFalse(
            CanonicalGroupMessageAdmission.allowsPersistence(
                owner: owner,
                groupJID: group,
                repository: repository
            ),
            "A queued live/MAM system or chat stanza must not resurrect a tombstoned group"
        )

        let activeRealm = try makeRealm()
        let activeRepository = GroupRepository(realm: activeRealm)
        try activeRepository.setSelfMembership(
            .both,
            memberID: "self",
            owner: owner,
            groupJID: group
        )
        try activeRepository.applySnapshot(
            GroupSnapshot(jid: group),
            owner: owner,
            groupJID: group
        )
        XCTAssertFalse(
            CanonicalGroupMessageAdmission.allowsPersistence(
                owner: owner,
                groupJID: group,
                repository: activeRepository
            ),
            "A roster subscription and cached self ID do not prove group membership"
        )
        try activeRepository.replaceMembers(
            [GroupMember(id: "self", jid: owner, role: .member)],
            owner: owner,
            groupJID: group
        )
        XCTAssertTrue(
            CanonicalGroupMessageAdmission.allowsPersistence(
                owner: owner,
                groupJID: group,
                repository: activeRepository
            )
        )
    }

    func testActivationIntegrationUsesCanonicalGroupMAMEntryPoint() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/models/account/delegates/AccountGroupchatIntegration.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(integration.contains("requestCanonicalGroupHistory"))
        XCTAssertFalse(integration.contains("conversation-type"))
    }

    func testTerminalMembershipDeletesStateAndNotifiesConversationCleanup() throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        try repository.setSelfMembership(.both, memberID: "self", owner: owner, groupJID: group)
        try repository.applySnapshot(
            GroupSnapshot(jid: group, info: GroupInfo(name: "Stage")),
            owner: owner,
            groupJID: group
        )
        var deactivated: [String] = []
        let processor = GroupEventProcessor(
            owner: owner,
            repository: { repository },
            onDeactivated: { deactivated.append($0) }
        )
        let input = GroupReducerInput(
            groupJID: group,
            ingress: .presence,
            events: [.selfSubscription(.none)]
        )

        XCTAssertEqual(try processor.process(.reducer(input)), .handled)

        let projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertEqual(projection.state.selfSubscription, .none)
        XCTAssertTrue(projection.state.isDeleted)
        XCTAssertNil(projection.state.snapshot.info)
        XCTAssertEqual(deactivated, [group])
    }

    func testActivationSyncGateDeduplicatesAndIgnoresStaleTicketCompletion() {
        let gate = GroupActivationSyncGate()
        let first = gate.begin(groupJID: "Stage@Example.com/Group")

        XCTAssertNotNil(first)
        XCTAssertNil(gate.begin(groupJID: "stage@example.com"))

        gate.invalidate(groupJID: group)
        if let first { XCTAssertFalse(gate.isCurrent(first)) }
        let replacement = gate.begin(groupJID: group)
        XCTAssertNotNil(replacement)
        if let first { gate.end(first) }
        XCTAssertNil(gate.begin(groupJID: group))
        if let replacement { XCTAssertTrue(gate.isCurrent(replacement)) }
        if let replacement { gate.end(replacement) }
        XCTAssertNotNil(gate.begin(groupJID: group))
    }

    func testConversationProjectionStartsOnlyGroupChatAndCleanupIsConversationScoped() throws {
        let realm = try makeApplicationRealm()
        let ownerBare = GroupStorageKey.bareJID(owner)
        try GroupConversationProjectionStore.activate(
            owner: owner,
            groupJID: "Stage@Example.com/Group",
            in: realm
        )
        let groupChat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: group,
                    owner: ownerBare,
                    conversationType: .group
                )
            )
        )
        XCTAssertEqual(groupChat.conversationType, .group)

        let regularChat = LastChatsStorageItem()
        regularChat.primary = LastChatsStorageItem.genPrimary(
            jid: group,
            owner: ownerBare,
            conversationType: .regular
        )
        regularChat.owner = ownerBare
        regularChat.jid = group
        regularChat.conversationType = .regular
        let groupMessage = MessageStorageItem()
        groupMessage.primary = "group-message"
        groupMessage.owner = ownerBare
        groupMessage.opponent = group
        groupMessage.conversationType = .group
        let regularMessage = MessageStorageItem()
        regularMessage.primary = "regular-message"
        regularMessage.owner = ownerBare
        regularMessage.opponent = group
        regularMessage.conversationType = .regular
        try realm.write {
            realm.add(regularChat)
            realm.add(groupMessage)
            realm.add(regularMessage)
        }
        let groupChatPrimary = groupChat.primary
        let regularChatPrimary = regularChat.primary

        try GroupConversationProjectionStore.deactivate(
            owner: owner,
            groupJID: "Stage@Example.com/Group",
            in: realm
        )

        XCTAssertNil(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "group-message"))
        XCTAssertNotNil(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "regular-message"))
        XCTAssertNil(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: groupChatPrimary))
        XCTAssertNotNil(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: regularChatPrimary))
    }

    private func makeRealm() throws -> Realm {
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

    private func makeApplicationRealm() throws -> Realm {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        return try Realm(configuration: configuration)
    }
}

private enum ProbeError: Error, Equatable {
    case sendFailed
}
