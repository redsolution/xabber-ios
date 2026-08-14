import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class GroupStreamManagementResumeRecoveryTests: XCTestCase {
    func testFullAuthenticationRecoveryRefreshesPersistedActiveGroupsWithoutSync() throws {
        var activated: [String] = []

        try CanonicalGroupFullAuthenticationRecovery.recover(
            activeGroupJIDs: {
                [
                    "Stage@Groups.Example.com/Group",
                    "stage@groups.example.com",
                    "Second@Groups.Example.com/Group"
                ]
            },
            activate: { activated.append($0) }
        )

        XCTAssertEqual(
            activated,
            ["stage@groups.example.com", "second@groups.example.com"]
        )
    }

    @MainActor
    func testFreshAuthenticationRecoveryAdmitsVerifiedMembershipBeforeConversationProjection() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let owner = "romeo@example.com/ios"
        let group = "Stage@Groups.Example.com/Group"
        var events: [String] = []

        let result = try await CanonicalGroupFreshAuthenticationRecovery.recover(
            owner: owner,
            groupJID: group,
            repository: repository,
            refreshGroup: {
                events.append("group")
                return GroupSnapshot(
                    jid: "stage@groups.example.com/Group",
                    privacy: .incognito,
                    info: GroupInfo(name: "Stage")
                )
            },
            refreshMembers: {
                events.append("members")
                return [
                    GroupMember(id: "member-self", jid: "romeo@example.com", role: .owner),
                    GroupMember(id: "member-peer", jid: nil, role: .member)
                ]
            },
            activateConversationAndHistory: { normalizedGroupJID in
                let projection = try repository.projection(
                    owner: owner,
                    groupJID: normalizedGroupJID
                )
                XCTAssertEqual(projection.state.selfSubscription, .both)
                XCTAssertEqual(projection.selfMemberID, "member-self")
                XCTAssertNil(
                    realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: normalizedGroupJID,
                            owner: GroupStorageKey.bareJID(owner),
                            conversationType: .group
                        )
                    ),
                    "The generic sync path must not create LastChat before verified membership"
                )
                try GroupConversationProjectionStore.activate(
                    owner: owner,
                    groupJID: normalizedGroupJID,
                    in: realm
                )
                events.append("mam")
            },
            refreshPermissions: { memberID in
                events.append("permissions:\(memberID)")
                return GroupPermissionSet(
                    scope: .direct,
                    target: memberID,
                    permissions: [GroupPermission(name: "send-messages", status: true)]
                )
            }
        )

        XCTAssertEqual(result, .admitted(memberID: "member-self"))
        XCTAssertEqual(events, ["group", "members", "mam", "permissions:member-self"])
        let projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertEqual(projection.state.selfSubscription, .both)
        XCTAssertEqual(projection.state.snapshot.info?.name, "Stage")
        XCTAssertEqual(projection.state.members.map(\.id), ["member-peer", "member-self"])
        XCTAssertEqual(projection.state.permissionSets.first?.target, "member-self")
        XCTAssertNotNil(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: "stage@groups.example.com",
                    owner: "romeo@example.com",
                    conversationType: .group
                )
            )
        )
    }

    @MainActor
    func testFreshAuthenticationRecoveryDoesNotResurrectTombstonedMembership() async throws {
        let realm = try makeRealm()
        let repository = GroupRepository(realm: realm)
        let owner = "romeo@example.com"
        let group = "stage@groups.example.com"
        try repository.setSelfMembership(
            .none,
            memberID: "member-self",
            owner: owner,
            groupJID: group
        )
        var didActivate = false
        var didRequestPermissions = false

        let result = try await CanonicalGroupFreshAuthenticationRecovery.recover(
            owner: owner,
            groupJID: group,
            repository: repository,
            refreshGroup: { GroupSnapshot(jid: group, info: GroupInfo(name: "Stale")) },
            refreshMembers: {
                [GroupMember(id: "member-self", jid: owner, role: .member)]
            },
            activateConversationAndHistory: { _ in didActivate = true },
            refreshPermissions: { _ in
                didRequestPermissions = true
                return GroupPermissionSet(
                    scope: .direct,
                    target: "member-self",
                    permissions: []
                )
            }
        )

        XCTAssertEqual(result, .ignoredTombstone)
        XCTAssertFalse(didActivate)
        XCTAssertFalse(didRequestPermissions)
        let projection = try repository.projection(owner: owner, groupJID: group)
        XCTAssertEqual(projection.state.selfSubscription, .none)
        XCTAssertTrue(projection.state.isDeleted)
        XCTAssertNil(projection.state.snapshot.info)
    }

    func testTransportBindingIgnoresDuplicatePrepareForSameStream() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        var firstGenerationElements: [XMPPElement] = []
        var duplicateGenerationElements: [XMPPElement] = []

        XCTAssertTrue(binding.prepare(stream: stream) {
            firstGenerationElements.append($0)
        })
        XCTAssertFalse(binding.prepare(stream: stream) {
            duplicateGenerationElements.append($0)
        })

        try service.sendJoin(groupJID: "stage@groups.example.com")

        XCTAssertEqual(firstGenerationElements.count, 1)
        XCTAssertTrue(duplicateGenerationElements.isEmpty)
    }

    func testTransportBindingDisconnectAllowsSameStreamToInstallFreshGeneration() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        var oldGenerationElements: [XMPPElement] = []
        var resumedGenerationElements: [XMPPElement] = []

        XCTAssertTrue(binding.prepare(stream: stream) {
            oldGenerationElements.append($0)
        })
        XCTAssertEqual(binding.disconnect(), 0)
        XCTAssertTrue(binding.prepare(stream: stream) {
            resumedGenerationElements.append($0)
        })

        try service.sendJoin(groupJID: "stage@groups.example.com")

        XCTAssertTrue(oldGenerationElements.isEmpty)
        XCTAssertEqual(resumedGenerationElements.count, 1)
    }

    func testTransportBindingNewStreamCancelsOldGeneration() async throws {
        let oldRequestSent = expectation(description: "old generation request sent")
        let service = GroupchatService(requestIDProvider: { "members-old" })
        let binding = CanonicalGroupTransportBinding(service: service)
        let oldStream = XMPPStream()
        let newStream = XMPPStream()
        let oldRecorder = ResumeTransportRecorder()
        let newRecorder = ResumeTransportRecorder()

        XCTAssertTrue(binding.prepare(stream: oldStream) { element in
            oldRecorder.append(element)
            oldRequestSent.fulfill()
        })
        let oldRequest = Task {
            try await service.refreshMembers(groupJID: "stage@groups.example.com")
        }
        await fulfillment(of: [oldRequestSent], timeout: 1)

        XCTAssertTrue(binding.prepare(stream: newStream, transport: newRecorder.append))

        do {
            _ = try await oldRequest.value
            XCTFail("Expected the old stream generation to be cancelled")
        } catch let error as GroupRequestError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(service.pendingRequestCount, 0)

        try service.sendJoin(groupJID: "stage@groups.example.com")
        XCTAssertEqual(oldRecorder.elements.count, 1)
        XCTAssertEqual(newRecorder.elements.count, 1)
    }

    func testResumeRecoveryInstallsFreshTransportBeforeActiveMembershipRefresh() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        binding.prepare(stream: stream) { _ in
            XCTFail("Disconnected transport must not be reused")
        }
        XCTAssertEqual(binding.disconnect(), 0)

        var events: [String] = []
        var sentElements: [XMPPElement] = []
        try CanonicalGroupStreamResumeRecovery.recover(
            binding: binding,
            stream: stream,
            transport: { element in
                events.append("send")
                sentElements.append(element)
            },
            invalidateCurrentActivations: {
                events.append("invalidate")
            },
            activeGroupJIDs: {
                [
                    "Stage@Groups.Example.com/Group",
                    "stage@groups.example.com",
                    "Second@Groups.Example.com/Group"
                ]
            },
            activate: { groupJID in
                events.append("activate:\(groupJID)")
                try service.sendChatPresence(groupJID: groupJID, state: .active)
            }
        )

        XCTAssertEqual(
            events,
            [
                "invalidate",
                "activate:stage@groups.example.com",
                "send",
                "activate:second@groups.example.com",
                "send"
            ]
        )
        XCTAssertEqual(sentElements.count, 2)
        XCTAssertEqual(sentElements.map { $0.to?.bare }, [
            "stage@groups.example.com",
            "second@groups.example.com"
        ])
    }

    func testResumeRecoveryLeavesFreshTransportPreparedWhenActiveGroupLookupFails() throws {
        enum LookupError: Error {
            case failed
        }

        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        var sentElements: [XMPPElement] = []

        XCTAssertThrowsError(
            try CanonicalGroupStreamResumeRecovery.recover(
                binding: binding,
                stream: stream,
                transport: { sentElements.append($0) },
                invalidateCurrentActivations: {},
                activeGroupJIDs: { throw LookupError.failed },
                activate: { _ in XCTFail("No group should be activated") }
            )
        ) { error in
            XCTAssertTrue(error is LookupError)
        }

        XCTAssertNoThrow(
            try service.sendJoin(groupJID: "stage@groups.example.com")
        )
        XCTAssertEqual(sentElements.count, 1)
    }

    func testSuccessfulResumeBranchInvokesCanonicalRuntimeRecovery() throws {
        let source = try productionSource(
            "models/account/extensions/AccountConnectBehaviorExtension.swift"
        )
        let resumedBranch = try XCTUnwrap(
            source.range(of: "if didResume {")
        )
        let fullAuthenticationBranch = try XCTUnwrap(
            source.range(of: "} else {", range: resumedBranch.upperBound..<source.endIndex)
        )
        let body = String(source[resumedBranch.lowerBound..<fullAuthenticationBranch.lowerBound])

        XCTAssertTrue(
            body.contains("recoverCanonicalGroupRuntimeAfterStreamManagementResume()")
        )

        let delegate = try productionSource(
            "models/account/delegates/AccountStreamDelegate.swift"
        )
        XCTAssertTrue(delegate.contains("disconnectCanonicalGroupTransport()"))
        XCTAssertFalse(delegate.contains("groupchatService.disconnect()"))

        let account = try productionSource("models/account/Account.swift")
        let resetStart = try XCTUnwrap(account.range(of: "func resetStream()"))
        let resetEnd = try XCTUnwrap(
            account.range(of: "func registerModules()", range: resetStart.upperBound..<account.endIndex)
        )
        let resetBody = String(account[resetStart.lowerBound..<resetEnd.lowerBound])
        XCTAssertTrue(resetBody.contains("disconnectCanonicalGroupTransport()"))
    }

    func testFullAuthenticationBranchInvokesCanonicalRuntimeRecoveryAfterTransportSetup() throws {
        let source = try productionSource(
            "models/account/extensions/AccountConnectBehaviorExtension.swift"
        )
        let fullAuthenticationStart = try XCTUnwrap(source.range(of: "} else {"))
        let completion = try XCTUnwrap(
            source.range(
                of: "self.connectionResilience.streamManagementResumeCompleted",
                range: fullAuthenticationStart.upperBound..<source.endIndex
            )
        )
        let body = String(
            source[fullAuthenticationStart.upperBound..<completion.lowerBound]
        )
        let configure = try XCTUnwrap(body.range(of: "self.configureExtensions()"))
        let recovery = try XCTUnwrap(
            body.range(of: "self.recoverCanonicalGroupRuntimeAfterFullAuthentication()")
        )

        XCTAssertLessThan(configure.lowerBound, recovery.lowerBound)

        let integration = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        let methodStart = try XCTUnwrap(
            integration.range(of: "func recoverCanonicalGroupRuntimeAfterFullAuthentication()")
        )
        let methodEnd = try XCTUnwrap(
            integration.range(
                of: "func recoverCanonicalGroupMembershipFromSynchronization(",
                range: methodStart.upperBound..<integration.endIndex
            )
        )
        let methodBody = String(integration[methodStart.lowerBound..<methodEnd.lowerBound])
        let prepareTransport = try XCTUnwrap(
            methodBody.range(of: "prepareCanonicalGroupTransport()")
        )
        let enumerateGroups = try XCTUnwrap(
            methodBody.range(of: "CanonicalGroupFullAuthenticationRecovery.recover")
        )
        XCTAssertLessThan(prepareTransport.lowerBound, enumerateGroups.lowerBound)
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("xabber", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        return try Realm(configuration: configuration)
    }
}

private final class ResumeTransportRecorder {
    private let lock = NSLock()
    private var storage: [XMPPElement] = []

    var elements: [XMPPElement] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: XMPPElement) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }
}
