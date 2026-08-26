import XCTest
@testable import xabber

final class CanonicalGroupOpenAdmissionCoordinatorTests: XCTestCase {
    private let owner = "romeo@example.com"
    private let group = "stage@groups.example.com"

    func testNonGroupConversationNeedsNoCanonicalAdmission() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 7)

        let result = try await coordinator.admit(
            ArchiveConversationKey(
                owner: owner,
                jid: "juliet@example.com",
                conversationType: .regular
            ),
            connectionGeneration: 7
        )

        XCTAssertEqual(result, .notRequired)
        XCTAssertEqual(service.refreshGroupCount, 0)
        XCTAssertEqual(service.refreshMembersCount, 0)
        XCTAssertEqual(service.commitCount, 0)
    }

    func testDurableAdmissionFastPathSendsNoGroupIQ() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.isDurablyAdmitted = true
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 11)

        let result = try await coordinator.admit(
            groupConversation(),
            connectionGeneration: 11
        )

        XCTAssertEqual(result, .admitted)
        XCTAssertEqual(service.refreshGroupCount, 0)
        XCTAssertEqual(service.refreshMembersCount, 0)
        XCTAssertEqual(service.commitCount, 0)
    }

    func testConcurrentSameGroupAdmissionJoinsOneGroupAndMembersRefresh() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.refreshDelayNanoseconds = 30_000_000
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 19)

        async let first = coordinator.admit(
            groupConversation(jid: "Stage@Groups.Example.com/Group"),
            connectionGeneration: 19
        )
        async let second = coordinator.admit(
            groupConversation(jid: "stage@groups.example.com"),
            connectionGeneration: 19
        )

        let results = try await [first, second]

        XCTAssertEqual(results, [.admitted, .admitted])
        XCTAssertEqual(service.refreshGroupCount, 1)
        XCTAssertEqual(service.refreshMembersCount, 1)
        XCTAssertEqual(service.commitCount, 1)
        XCTAssertEqual(service.committedMemberID, "member-self")
    }

    func testAdmissionFetchesOnlyGroupAndMembersThenCommitsResolvedSelf() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.snapshot = GroupSnapshot(
            jid: group,
            info: GroupInfo(name: "Stage")
        )
        service.members = [
            GroupMember(id: "member-self", jid: owner, role: .owner),
            GroupMember(id: "member-peer", jid: nil, role: .member)
        ]
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 23)

        let result = try await coordinator.admit(
            groupConversation(),
            connectionGeneration: 23
        )

        XCTAssertEqual(result, .admitted)
        XCTAssertEqual(service.events, ["group", "members", "commit"])
        XCTAssertEqual(service.committedMemberID, "member-self")
        XCTAssertEqual(
            service.committedMembers.first(where: { $0.id == "member-self" })?.jid,
            owner
        )
    }

    func testMissingSelfMemberFailsClosedWithoutCommit() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.members = [
            GroupMember(id: "member-peer", jid: "juliet@example.com", role: .member)
        ]
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 29)

        do {
            _ = try await coordinator.admit(
                groupConversation(),
                connectionGeneration: 29
            )
            XCTFail("Missing self membership must reject archive admission")
        } catch let error as ArchiveConversationAdmissionError {
            XCTAssertEqual(error, .missingSelfMemberID)
        }

        XCTAssertEqual(service.commitCount, 0)
    }

    func testInactiveSelfMemberFailsClosedWithoutCommit() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.members = [
            GroupMember(id: "member-self", jid: owner, role: .none)
        ]
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 30)

        do {
            _ = try await coordinator.admit(
                groupConversation(),
                connectionGeneration: 30
            )
            XCTFail("An inactive self member must reject archive admission")
        } catch let error as ArchiveConversationAdmissionError {
            XCTAssertEqual(error, .inactiveSelfMembership)
        }

        XCTAssertEqual(service.commitCount, 0)
    }

    func testSelfMemberWithoutRoleFailsClosedWithoutCommit() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.members = [
            GroupMember(id: "member-self", jid: owner, role: nil)
        ]
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 30)

        do {
            _ = try await coordinator.admit(
                groupConversation(),
                connectionGeneration: 30
            )
            XCTFail("Self membership without an authoritative role must reject archive admission")
        } catch let error as ArchiveConversationAdmissionError {
            XCTAssertEqual(error, .inactiveSelfMembership)
        }

        XCTAssertEqual(service.commitCount, 0)
    }

    func testTombstoneFailsClosed() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.commitResult = .ignoredTombstone
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 31)

        do {
            _ = try await coordinator.admit(
                groupConversation(),
                connectionGeneration: 31
            )
            XCTFail("A tombstoned group must not be admitted to MAM")
        } catch let error as ArchiveConversationAdmissionError {
            XCTAssertEqual(error, .tombstoned)
        }
    }

    func testDisconnectWhileRefreshingPreventsCommitAndLateCompletion() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        service.refreshDelayNanoseconds = 100_000_000
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 37)

        let task = Task {
            try await coordinator.admit(
                groupConversation(),
                connectionGeneration: 37
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await coordinator.connectionDidDisconnect()

        do {
            _ = try await task.value
            XCTFail("A disconnected generation must fail closed")
        } catch let error as ArchiveConversationAdmissionError {
            XCTAssertTrue([.disconnected, .staleConnection].contains(error))
        } catch is CancellationError {
            // Cancellation is also a terminal, fail-closed generation result.
        }

        XCTAssertEqual(service.commitCount, 0)
    }

    func testWrongConnectionGenerationFailsBeforeNetwork() async throws {
        let service = CanonicalGroupOpenAdmissionServiceSpy(owner: owner)
        let coordinator = CanonicalGroupOpenAdmissionCoordinator(
            owner: owner,
            service: service
        )
        await coordinator.connectionDidBecomeReady(generation: 41)

        do {
            _ = try await coordinator.admit(
                groupConversation(),
                connectionGeneration: 40
            )
            XCTFail("An old connection generation must not send group IQ")
        } catch let error as ArchiveConversationAdmissionError {
            XCTAssertEqual(error, .staleConnection)
        }

        XCTAssertEqual(service.refreshGroupCount, 0)
        XCTAssertEqual(service.refreshMembersCount, 0)
    }

    private func groupConversation(
        jid: String? = nil
    ) -> ArchiveConversationKey {
        ArchiveConversationKey(
            owner: owner,
            jid: jid ?? group,
            conversationType: .group
        )
    }
}

private final class CanonicalGroupOpenAdmissionServiceSpy:
    CanonicalGroupOpenAdmissionServicing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let owner: String
    var isDurablyAdmitted = false
    var snapshot: GroupSnapshot
    var members: [GroupMember]
    var commitResult = GroupRepositoryAdmissionResult.admitted
    var refreshDelayNanoseconds: UInt64 = 0

    private var _refreshGroupCount = 0
    private var _refreshMembersCount = 0
    private var _commitCount = 0
    private var _events: [String] = []
    private var _committedMemberID: String?
    private var _committedMembers: [GroupMember] = []

    init(owner: String) {
        self.owner = owner
        self.snapshot = GroupSnapshot(jid: "stage@groups.example.com")
        self.members = [
            GroupMember(id: "member-self", jid: owner, role: .member)
        ]
    }

    var refreshGroupCount: Int { locked { _refreshGroupCount } }
    var refreshMembersCount: Int { locked { _refreshMembersCount } }
    var commitCount: Int { locked { _commitCount } }
    var events: [String] { locked { _events } }
    var committedMemberID: String? { locked { _committedMemberID } }
    var committedMembers: [GroupMember] { locked { _committedMembers } }

    func hasDurableAdmission(owner _: String, groupJID _: String) -> Bool {
        isDurablyAdmitted
    }

    func existingSelfMemberID(owner _: String, groupJID _: String) -> String? {
        nil
    }

    func refreshGroup(groupJID _: String) async throws -> GroupSnapshot {
        locked {
            _refreshGroupCount += 1
            _events.append("group")
        }
        if refreshDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        return snapshot
    }

    func refreshMembers(groupJID _: String) async throws -> [GroupMember] {
        locked {
            _refreshMembersCount += 1
            _events.append("members")
        }
        if refreshDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        return members
    }

    func commitAdmission(
        snapshot _: GroupSnapshot,
        members: [GroupMember],
        selfMemberID: String,
        owner _: String,
        groupJID _: String
    ) throws -> GroupRepositoryAdmissionResult {
        locked {
            _commitCount += 1
            _events.append("commit")
            _committedMemberID = selfMemberID
            _committedMembers = members
        }
        return commitResult
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
