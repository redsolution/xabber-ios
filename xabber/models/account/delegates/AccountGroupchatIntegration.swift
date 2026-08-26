import Foundation
import CocoaLumberjack
import RealmSwift
import XMPPFramework

enum CanonicalGroupLifecycleError: Error, Equatable {
    case timeout
    case rejected
}

/// Owns the identity relationship between the typed Groups service and the
/// concrete primary XMPP stream. Repeated extension setup for one live stream
/// is a no-op, while disconnect or a different stream starts a new service
/// transport generation.
final class CanonicalGroupTransportBinding {
    private let lock = NSLock()
    private let service: GroupchatService
    private weak var boundStream: XMPPStream?
    private var isPrepared = false

    init(service: GroupchatService) {
        self.service = service
    }

    @discardableResult
    func prepare(
        stream: XMPPStream,
        transport: @escaping GroupchatTransport
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isPrepared || boundStream !== stream else {
            return false
        }
        service.prepare(transport)
        boundStream = stream
        isPrepared = true
        return true
    }

    @discardableResult
    func disconnect() -> Int {
        lock.lock()
        defer { lock.unlock() }
        boundStream = nil
        isPrepared = false
        return service.disconnect()
    }
}

/// Rebinds canonical Groups to an authenticated stream-management generation.
/// Persisted rooms are intentionally not enumerated here: authoritative
/// admission is performed only for a group the user actually opens.
enum CanonicalGroupStreamResumeRecovery {
    static func recover(
        binding: CanonicalGroupTransportBinding,
        stream: XMPPStream,
        transport: @escaping GroupchatTransport
    ) {
        binding.prepare(stream: stream, transport: transport)
    }
}

/// Materializes the create contract before UIKit presents the room. Successful
/// normal creation guarantees that the creator is owner; authoritative members
/// later replace this provisional local identity without gating presentation.
@MainActor
enum CanonicalCreatedGroupOwnerAdmission {
    static func admit(
        snapshot: GroupSnapshot,
        owner: String,
        repository: GroupRepository
    ) throws -> GroupRepositoryProjection {
        guard let rawGroupJID = snapshot.jid else {
            throw GroupRepositoryError.invalidGroupJID
        }
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        guard !groupJID.isEmpty else {
            throw GroupRepositoryError.invalidGroupJID
        }

        let creator = CanonicalGroupSelfIdentity.provisionalCreatedOwner(
            ownerJID: owner
        )
        try repository.admitCreatedOwner(
            snapshot,
            creator: creator,
            owner: owner,
            groupJID: groupJID
        )
        return try repository.projection(owner: owner, groupJID: groupJID)
    }
}

enum CanonicalGroupMessageAdmission {
    static func allowsPersistence(
        owner: String,
        groupJID: String,
        repository: GroupRepository
    ) -> Bool {
        guard let projection = try? repository.projection(
            owner: owner,
            groupJID: groupJID
        ), projection.state.isActive,
           let selfMemberID = projection.selfMemberID,
           let role = projection.state.member(id: selfMemberID)?.role else {
            return false
        }
        return role != .none
    }
}

enum ArchiveConversationAdmissionResult: Equatable, Sendable {
    case notRequired
    case admitted
}

enum ArchiveConversationAdmissionError: Error, Equatable, Sendable {
    case disconnected
    case staleConnection
    case ownerMismatch
    case invalidGroupJID
    case missingSelfMemberID
    case inactiveSelfMembership
    case tombstoned
}

/// ArchiveEngine preflight seam. Admission may materialize authorization
/// required to persist a requested archive window, but it never sends MAM.
protocol ArchiveConversationAdmissionProviding: Sendable {
    func connectionDidBecomeReady(generation: UInt64) async
    func connectionDidDisconnect() async
    func admit(
        _ conversation: ArchiveConversationKey,
        connectionGeneration: UInt64
    ) async throws -> ArchiveConversationAdmissionResult
}

/// The minimal canonical Groups surface needed before MAM. Permissions are
/// deliberately absent: capability hydration is lazy and cannot delay history.
protocol CanonicalGroupOpenAdmissionServicing: Sendable {
    func hasDurableAdmission(owner: String, groupJID: String) -> Bool
    func existingSelfMemberID(owner: String, groupJID: String) -> String?
    func refreshGroup(groupJID: String) async throws -> GroupSnapshot
    func refreshMembers(groupJID: String) async throws -> [GroupMember]
    func commitAdmission(
        snapshot: GroupSnapshot,
        members: [GroupMember],
        selfMemberID: String,
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryAdmissionResult
}

/// One account-scoped owner of group-open authorization. The actor joins
/// identical opens, rejects late stream generations, and commits membership,
/// snapshot, and members only after both authoritative IQs have completed.
actor CanonicalGroupOpenAdmissionCoordinator:
    ArchiveConversationAdmissionProviding {
    private struct RequestKey: Hashable {
        let groupJID: String
        let connectionGeneration: UInt64
    }

    private let owner: String
    private let service: CanonicalGroupOpenAdmissionServicing
    private var currentConnectionGeneration: UInt64?
    private var activeAdmissions: [
        RequestKey: Task<ArchiveConversationAdmissionResult, Error>
    ] = [:]

    init(
        owner: String,
        service: CanonicalGroupOpenAdmissionServicing
    ) {
        self.owner = GroupStorageKey.bareJID(owner)
        self.service = service
    }

    func connectionDidBecomeReady(generation: UInt64) {
        guard currentConnectionGeneration != generation else {
            return
        }
        activeAdmissions.values.forEach { $0.cancel() }
        activeAdmissions.removeAll()
        currentConnectionGeneration = generation
    }

    func connectionDidDisconnect() {
        currentConnectionGeneration = nil
        activeAdmissions.values.forEach { $0.cancel() }
        activeAdmissions.removeAll()
    }

    func admit(
        _ conversation: ArchiveConversationKey,
        connectionGeneration: UInt64
    ) async throws -> ArchiveConversationAdmissionResult {
        guard conversation.conversationType == .group else {
            return .notRequired
        }
        guard GroupStorageKey.bareJID(conversation.owner) == owner else {
            throw ArchiveConversationAdmissionError.ownerMismatch
        }
        try ensureCurrent(connectionGeneration)

        let groupJID = GroupStorageKey.bareJID(conversation.jid)
        guard groupJID.isNotEmpty else {
            throw ArchiveConversationAdmissionError.invalidGroupJID
        }
        if service.hasDurableAdmission(owner: owner, groupJID: groupJID) {
            return .admitted
        }

        let key = RequestKey(
            groupJID: groupJID,
            connectionGeneration: connectionGeneration
        )
        let admission: Task<ArchiveConversationAdmissionResult, Error>
        if let active = activeAdmissions[key] {
            admission = active
        } else {
            admission = Task { [weak self] in
                guard let self else {
                    throw ArchiveConversationAdmissionError.disconnected
                }
                return try await self.performAdmission(
                    groupJID: groupJID,
                    connectionGeneration: connectionGeneration
                )
            }
            activeAdmissions[key] = admission
        }

        do {
            let result = try await admission.value
            activeAdmissions.removeValue(forKey: key)
            return result
        } catch {
            activeAdmissions.removeValue(forKey: key)
            if currentConnectionGeneration == nil {
                throw ArchiveConversationAdmissionError.disconnected
            }
            if currentConnectionGeneration != connectionGeneration {
                throw ArchiveConversationAdmissionError.staleConnection
            }
            throw error
        }
    }

    private func performAdmission(
        groupJID: String,
        connectionGeneration: UInt64
    ) async throws -> ArchiveConversationAdmissionResult {
        try ensureCurrent(connectionGeneration)
        let snapshot = try await service.refreshGroup(groupJID: groupJID)
        try Task.checkCancellation()
        try ensureCurrent(connectionGeneration)

        let members = try await service.refreshMembers(groupJID: groupJID)
        try Task.checkCancellation()
        try ensureCurrent(connectionGeneration)

        let existingSelfMemberID = service.existingSelfMemberID(
            owner: owner,
            groupJID: groupJID
        )
        guard let selfMemberID = CanonicalGroupSelfIdentity.resolve(
            existingMemberID: existingSelfMemberID,
            ownerJID: owner,
            members: members
        ) else {
            throw ArchiveConversationAdmissionError.missingSelfMemberID
        }
        guard let selfRole = members.first(where: { $0.id == selfMemberID })?.role,
              selfRole != GroupMemberRole.none else {
            throw ArchiveConversationAdmissionError.inactiveSelfMembership
        }
        let reconciledMembers = CanonicalGroupSelfIdentity.attachingOwnerJID(
            to: members,
            selfMemberID: selfMemberID,
            ownerJID: owner
        )

        try ensureCurrent(connectionGeneration)
        let result = try service.commitAdmission(
            snapshot: snapshot,
            members: reconciledMembers,
            selfMemberID: selfMemberID,
            owner: owner,
            groupJID: groupJID
        )
        guard result == .admitted else {
            throw ArchiveConversationAdmissionError.tombstoned
        }
        return .admitted
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        guard let currentConnectionGeneration else {
            throw ArchiveConversationAdmissionError.disconnected
        }
        guard currentConnectionGeneration == generation else {
            throw ArchiveConversationAdmissionError.staleConnection
        }
    }
}

/// Realm/GroupchatService adapter used by Account when constructing its
/// account-scoped admission coordinator. It performs no permissions request.
final class LiveCanonicalGroupOpenAdmissionService:
    CanonicalGroupOpenAdmissionServicing,
    @unchecked Sendable {
    private let groupchatService: GroupchatService

    init(groupchatService: GroupchatService) {
        self.groupchatService = groupchatService
    }

    func hasDurableAdmission(owner: String, groupJID: String) -> Bool {
        guard let realm = try? WRealm.safe() else {
            return false
        }
        return CanonicalGroupMessageAdmission.allowsPersistence(
            owner: owner,
            groupJID: groupJID,
            repository: GroupRepository(realm: realm)
        )
    }

    func existingSelfMemberID(owner: String, groupJID: String) -> String? {
        guard let realm = try? WRealm.safe() else {
            return nil
        }
        return try? GroupRepository(realm: realm)
            .projection(owner: owner, groupJID: groupJID)
            .selfMemberID
    }

    func refreshGroup(groupJID: String) async throws -> GroupSnapshot {
        try await groupchatService.refreshGroup(groupJID: groupJID)
    }

    func refreshMembers(groupJID: String) async throws -> [GroupMember] {
        try await groupchatService.refreshMembers(groupJID: groupJID)
    }

    func commitAdmission(
        snapshot: GroupSnapshot,
        members: [GroupMember],
        selfMemberID: String,
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryAdmissionResult {
        let realm = try WRealm.safe()
        return try GroupRepository(realm: realm).admitSnapshot(
            snapshot,
            membership: .both,
            memberID: selfMemberID,
            owner: owner,
            groupJID: groupJID,
            members: members,
            rejectingTombstone: true,
            additionalMutation: { transactionRealm in
                try GroupConversationProjectionStore.activate(
                    owner: owner,
                    groupJID: groupJID,
                    in: transactionRealm
                )
            }
        )
    }
}

/// Reconciles both P2P creation outcomes into canonical local state.
/// A successful create already sends subscribe in `GroupchatService`; a
/// conflict carries the existing room snapshot and needs the ordinary join
/// only after that snapshot has been admitted to storage.
@MainActor
enum CanonicalGroupP2PFlow {
    private struct CreationOutcome {
        let snapshot: GroupSnapshot
        let requiresJoin: Bool
    }

    static func createOrJoin(
        owner: String,
        parentJID: String,
        repository: GroupRepository,
        create: () async throws -> GroupSnapshot,
        joinExisting: (String) throws -> Void
    ) async throws -> GroupSnapshot {
        let outcome = try await resolveCreation(create: create)
        return try reconcile(
            outcome,
            owner: owner,
            parentJID: parentJID,
            repository: repository,
            joinExisting: joinExisting
        )
    }

    /// Keep typed IQ outcome resolution separate from state reconciliation.
    @inline(never)
    private static func resolveCreation(
        create: () async throws -> GroupSnapshot
    ) async throws -> CreationOutcome {
        do {
            return CreationOutcome(
                snapshot: try await create(),
                requiresJoin: false
            )
        } catch let GroupchatServiceError.iq(error)
            where error.condition == "conflict" {
            guard case let .snapshot(existingSnapshot)? = error.payload else {
                throw GroupchatServiceError.iq(error)
            }
            return CreationOutcome(
                snapshot: existingSnapshot,
                requiresJoin: true
            )
        }
    }

    @inline(never)
    private static func reconcile(
        _ outcome: CreationOutcome,
        owner: String,
        parentJID: String,
        repository: GroupRepository,
        joinExisting: (String) throws -> Void
    ) throws -> GroupSnapshot {
        let snapshot = outcome.snapshot
        guard let rawGroupJID = snapshot.jid else {
            throw GroupchatServiceError.missingCreatedGroupJID
        }
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        guard !groupJID.isEmpty else {
            throw GroupchatServiceError.missingCreatedGroupJID
        }
        let existingProjection = try? repository.projection(
            owner: owner,
            groupJID: groupJID
        )
        let canonicalParentJID = GroupStorageKey.bareJID(parentJID)
        var canonicalSnapshot: GroupSnapshot
        if outcome.requiresJoin,
           let existing = existingProjection?.state.snapshot {
            canonicalSnapshot = mergeConflictSnapshot(
                snapshot,
                into: existing,
                parentJID: canonicalParentJID
            )
        } else {
            canonicalSnapshot = snapshot
            canonicalSnapshot.parentJID = snapshot.parentJID
                .map(GroupStorageKey.bareJID) ?? canonicalParentJID
        }
        canonicalSnapshot.jid = groupJID
        let membershipState: GroupSelfMembershipState =
            existingProjection?.state.selfSubscription == .both ? .both : .wait
        try repository.admitSnapshot(
            canonicalSnapshot,
            membership: membershipState,
            memberID: existingProjection?.selfMemberID,
            owner: owner,
            groupJID: groupJID
        )
        if outcome.requiresJoin {
            try joinExisting(groupJID)
        }
        return canonicalSnapshot
    }

    private static func mergeConflictSnapshot(
        _ response: GroupSnapshot,
        into existing: GroupSnapshot,
        parentJID: String
    ) -> GroupSnapshot {
        GroupSnapshot(
            jid: response.jid ?? existing.jid,
            privacy: response.privacy ?? existing.privacy,
            parentJID: response.parentJID
                .map(GroupStorageKey.bareJID) ?? existing.parentJID ?? parentJID,
            memberCount: response.memberCount ?? existing.memberCount,
            localpart: response.localpart ?? existing.localpart,
            info: response.info ?? existing.info,
            settings: response.settings ?? existing.settings,
            pinnedMessageIDs: response.pinnedMessageIDs ?? existing.pinnedMessageIDs,
            presentCount: response.presentCount ?? existing.presentCount
        )
    }
}

private final class CanonicalGroupLifecycleCompletion {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    if let result = self.result {
                        self.lock.unlock()
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                        self.lock.unlock()
                    }
                }
            },
            onCancel: {
                self.finish(.failure(CancellationError()))
            }
        )
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Account/UI lifecycle boundary for canonical Xabber Groups.
///
/// Presence commands are send-only, so join and leave complete only after the
/// repository observes the matching server-authoritative subscription state.
@MainActor
enum CanonicalGroupMembershipLifecycle {
    enum ExitMode: Equatable {
        case leave
        case deletePeerToPeer
        case deleteLastOwner

        var deletesGroup: Bool {
            switch self {
            case .leave:
                return false
            case .deletePeerToPeer, .deleteLastOwner:
                return true
            }
        }
    }

    static func join(account: Account, groupJID: String) async throws {
        let normalizedJID = GroupStorageKey.bareJID(groupJID)
        let repository = GroupRepository(realm: try WRealm.safe())
        let memberID = try? repository.projection(
            owner: account.jid,
            groupJID: normalizedJID
        ).selfMemberID
        try repository.setSelfMembership(
            .wait,
            memberID: memberID,
            owner: account.jid,
            groupJID: normalizedJID
        )
        try await perform(
            owner: account.jid,
            groupJID: normalizedJID,
            expected: .both
        ) {
            try account.groupchatService.sendJoin(groupJID: normalizedJID)
        }
    }

    static func leave(account: Account, groupJID: String) async throws {
        let normalizedJID = GroupStorageKey.bareJID(groupJID)
        try await perform(
            owner: account.jid,
            groupJID: normalizedJID,
            expected: .none
        ) {
            try account.groupchatService.sendLeave(groupJID: normalizedJID)
        }
    }

    static func delete(account: Account, groupJID: String) async throws {
        let normalizedJID = GroupStorageKey.bareJID(groupJID)
        try await account.groupchatService.delete(groupJID: normalizedJID)
        try GroupRepository(realm: WRealm.safe()).recordDeletion(
            owner: account.jid,
            groupJID: normalizedJID
        )
        account.groupMembershipDidDeactivate(normalizedJID)
    }

    static func exitMode(owner: String, groupJID: String) throws -> ExitMode {
        let projection = try GroupRepository(realm: WRealm.safe()).projection(
            owner: owner,
            groupJID: groupJID
        )
        return exitMode(
            snapshot: projection.state.snapshot,
            selfMemberID: projection.selfMemberID,
            members: projection.state.members
        )
    }

    static func exitMode(
        snapshot: GroupSnapshot,
        selfMemberID: String?,
        members: [GroupMember]
    ) -> ExitMode {
        // A P2P group has no independent leave lifecycle: either participant
        // leaving deletes the P2P room.
        if snapshot.parentJID != nil {
            return .deletePeerToPeer
        }
        guard let selfMemberID,
              members.first(where: { $0.id == selfMemberID })?.role == .owner else {
            return .leave
        }
        let ownerCount = members.filter { $0.role == .owner }.count
        return ownerCount == 1 ? .deleteLastOwner : .leave
    }

    static func localizedErrorMessage(_ error: Error) -> String {
        if let serviceError = error as? GroupchatServiceError,
           case let .iq(iqError) = serviceError {
            switch iqError.condition {
            case "conflict":
                return "Conflict".localizeString(
                    id: "message_manager_error_conflict",
                    arguments: []
                )
            case "not-allowed":
                return "Not allowed".localizeString(
                    id: "message_manager_error_unallowed",
                    arguments: []
                )
            default:
                break
            }
        }
        switch error {
        case CanonicalGroupLifecycleError.rejected:
            return "Not allowed".localizeString(
                id: "message_manager_error_unallowed",
                arguments: []
            )
        case CanonicalGroupLifecycleError.timeout, GroupRequestError.timeout:
            return "Request timeout".localizeString(
                id: "message_manager_errpr_request_timeout",
                arguments: []
            )
        case GroupRequestError.disconnected, GroupchatServiceError.notPrepared:
            return "Network unreachable".localizeString(
                id: "message_manager_error_unreachable_network",
                arguments: []
            )
        default:
            return "Internal error".localizeString(
                id: "message_manager_error_internal",
                arguments: []
            )
        }
    }

    nonisolated static func terminalError(
        observed: GroupSelfSubscription,
        expected: GroupSelfSubscription
    ) -> CanonicalGroupLifecycleError? {
        guard expected == .both, observed == .none else {
            return nil
        }
        return .rejected
    }

    private static func perform(
        owner: String,
        groupJID: String,
        expected: GroupSelfSubscription,
        operation: @escaping () async throws -> Void
    ) async throws {
        let completion = CanonicalGroupLifecycleCompletion()
        let repository = GroupRepository(realm: try WRealm.safe())
        let observation = try repository.observeProjection(
            owner: owner,
            groupJID: groupJID
        ) { projection in
            let observed = projection.state.selfSubscription
            if observed == expected {
                completion.finish(.success(()))
                return
            }
            if let error = terminalError(
                observed: observed,
                expected: expected
            ) {
                completion.finish(.failure(error))
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            completion.finish(.failure(CanonicalGroupLifecycleError.timeout))
        }
        defer {
            timeoutTask.cancel()
            observation.invalidate()
            withExtendedLifetime(repository) {}
        }

        do {
            try await operation()
        } catch {
            completion.finish(.failure(error))
        }
        try await completion.wait()
    }
}

/// Active canonical groups own their owner/JID conversation namespace.
/// Account-side archived copies may omit the Groups extension and look like
/// regular messages, but they must never create a second contact conversation.
enum CanonicalGroupRegularShadowPolicy {
    static func shouldSuppress(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        activeGroupPrimaries: Set<String>
    ) -> Bool {
        guard conversationType == .regular else {
            return false
        }
        return activeGroupPrimaries.contains(
            GroupStorageKey.groupPrimary(owner: owner, groupJID: jid)
        )
    }

    static func activeGroupPrimaries(
        in realm: Realm,
        owners: [String]
    ) -> Set<String> {
        let normalizedOwners = Array(Set(owners.map(GroupStorageKey.bareJID)))
            .filter { !$0.isEmpty }
        guard !normalizedOwners.isEmpty else {
            return []
        }
        let memberships = Dictionary(
            uniqueKeysWithValues: realm
                .objects(GroupSelfMembershipStorageItem.self)
                .filter("owner IN %@", normalizedOwners)
                .map { ($0.primary, $0.memberID) }
        )
        let membersByGroup = Dictionary(
            grouping: realm
                .objects(GroupMemberStorageItem.self)
                .filter("owner IN %@", normalizedOwners),
            by: \.groupPrimary
        )

        return Set(
            realm.objects(GroupSnapshotStorageItem.self)
                .filter("owner IN %@", normalizedOwners)
                .compactMap { snapshot -> String? in
                    guard snapshot.lifecycleStateRaw != GroupLifecycleState.inactive.rawValue else {
                        return nil
                    }
                    let storedMembers = membersByGroup[snapshot.primary] ?? []
                    let members = storedMembers.map {
                        GroupMember(
                            id: $0.memberID,
                            jid: $0.jid,
                            role: $0.roleRaw.flatMap(GroupMemberRole.init(rawValue:))
                        )
                    }
                    guard let selfMemberID = CanonicalGroupSelfIdentity.resolve(
                        existingMemberID: memberships[snapshot.primary] ?? nil,
                        ownerJID: snapshot.owner,
                        members: members
                    ),
                    let selfRole = members.first(where: { $0.id == selfMemberID })?.role,
                    selfRole != .none else {
                        return nil
                    }
                    return snapshot.primary
                }
        )
    }
}

enum GroupConversationProjectionStore {
    static func deactivationTargets(
        owner: String,
        groupJID: String,
        in realm: Realm
    ) -> [String] {
        let owner = GroupStorageKey.bareJID(owner)
        let groupJID = GroupStorageKey.bareJID(groupJID)
        var seen = Set<String>()
        var result: [String] = []
        func append(_ candidate: String) {
            let normalized = GroupStorageKey.bareJID(candidate)
            if !normalized.isEmpty, seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        append(groupJID)
        realm.objects(GroupSelfMembershipStorageItem.self)
            .filter(
                "owner == %@ AND stateRaw == %@",
                owner,
                GroupSelfMembershipState.none.rawValue
            )
            .forEach { append($0.groupJID) }
        return result
    }

    static func activate(owner: String, groupJID: String, in realm: Realm) throws {
        let owner = GroupStorageKey.bareJID(owner)
        let groupJID = GroupStorageKey.bareJID(groupJID)
        let primary = LastChatsStorageItem.genPrimary(
            jid: groupJID,
            owner: owner,
            conversationType: .group
        )
        let mutation = {
            guard realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: primary
            ) == nil else {
                return
            }
            let item = LastChatsStorageItem()
            item.primary = primary
            item.owner = owner
            item.jid = groupJID
            item.conversationType = .group
            item.messageDate = Date()
            realm.add(item, update: .error)
        }
        if realm.isInWriteTransaction {
            mutation()
        } else {
            try realm.write(mutation)
        }
    }

    static func deactivate(owner: String, groupJID: String, in realm: Realm) throws {
        let owner = GroupStorageKey.bareJID(owner)
        let groupJID = GroupStorageKey.bareJID(groupJID)
        let type = ClientSynchronizationManager.ConversationType.group.rawValue
        try realm.write {
            realm.delete(
                realm.objects(LastChatsStorageItem.self).filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
            realm.delete(
                realm.objects(MessageMediaAttachmentStorageItem.self).filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
            realm.delete(
                realm.objects(MessageReferenceStorageItem.self).filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
            realm.delete(
                realm.objects(XMPPMessageScheduleStorageItem.self).filter(
                    "owner == %@ AND conversation == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
            realm.delete(
                realm.objects(RegularChatArchiveSyncStateStorageItem.self).filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
            realm.delete(
                realm.objects(ChatLocalHistoryIndexStorageItem.self).filter(
                    "owner == %@ AND jid == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
            realm.delete(
                realm.objects(MessageStorageItem.self).filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                    owner,
                    groupJID,
                    type
                )
            )
        }
    }
}

extension Account {
    enum CanonicalGroupMessageRouting: Equatable {
        case notGroup
        case validatedMessage
        case consumed
    }

    @discardableResult
    func routeCanonicalGroupPresence(_ presence: XMPPPresence) -> Bool {
        do {
            var knownGroupJIDs = Set<String>()
            let isBareTerminalPresence = presence.element(
                forName: "group",
                xmlns: GroupProtocolNamespace.groups
            ) == nil && ["unsubscribe", "unsubscribed", "unavailable"].contains(
                presence.attributeStringValue(forName: "type") ?? ""
            )
            if isBareTerminalPresence,
               let fromJID = presence.from,
               fromJID.user != nil,
               let realm = try? WRealm.safe() {
                let from = fromJID.bare
                let groupJID = GroupStorageKey.bareJID(from)
                if let _ = try? GroupRepository(realm: realm).activeGroup(
                    owner: jid,
                    groupJID: groupJID
                ) {
                    knownGroupJIDs.insert(groupJID)
                }
            }
            guard let event = try GroupStanzaRouter.route(
                presence,
                knownGroupJIDs: knownGroupJIDs
            ) else {
                return false
            }
            _ = try groupEventProcessor.process(event)
            return true
        } catch {
            DDLogError("Group presence rejected: \(error)")
            return true
        }
    }

    func routeCanonicalGroupMessage(
        _ message: XMPPMessage
    ) -> CanonicalGroupMessageRouting {
        do {
            guard let event = try GroupStanzaRouter.route(message) else {
                return .notGroup
            }
            switch try groupEventProcessor.process(event) {
            case .handled, .invite:
                return .consumed
            case let .message(groupMessage):
                let repository = GroupRepository(realm: try WRealm.safe())
                guard CanonicalGroupMessageAdmission.allowsPersistence(
                    owner: jid,
                    groupJID: groupMessage.groupJID,
                    repository: repository
                ) else {
                    // Delayed live/MAM/system messages cannot recreate a group
                    // after leave/delete, and unknown sync candidates cannot
                    // bypass verified membership admission.
                    return .consumed
                }
                // Canonical group messages still pass through the ordinary
                // message/MAM/receipt persistence paths after typed validation.
                return .validatedMessage
            case .ignored:
                return .consumed
            }
        } catch {
            DDLogError("Group message rejected: \(error)")
            return .consumed
        }
    }

    func prepareCanonicalGroupTransport() {
        let stream = xmppStream
        canonicalGroupTransportBinding.prepare(
            stream: stream,
            transport: canonicalGroupTransport(for: stream)
        )
    }

    func disconnectCanonicalGroupTransport() {
        canonicalGroupTransportBinding.disconnect()
    }

    /// XEP-0198 resume skips the ordinary extension setup path. Rebind the
    /// transport generation without enumerating or hydrating persisted rooms.
    func recoverCanonicalGroupRuntimeAfterStreamManagementResume() {
        let stream = xmppStream
        CanonicalGroupStreamResumeRecovery.recover(
            binding: canonicalGroupTransportBinding,
            stream: stream,
            transport: canonicalGroupTransport(for: stream)
        )
    }

    /// Full SASL authentication prepares only the typed transport. A room is
    /// refreshed when the user opens it, never as account-startup fanout.
    func recoverCanonicalGroupRuntimeAfterFullAuthentication() {
        prepareCanonicalGroupTransport()
    }

    func reconcileCanonicalGroupDeletionFromSynchronization(
        _ rawGroupJID: String
    ) {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        do {
            try GroupRepository(realm: WRealm.safe()).recordDeletion(
                owner: jid,
                groupJID: groupJID
            )
            groupMembershipDidDeactivate(groupJID)
        } catch {
            DDLogError("Group synchronization deletion failed for \(groupJID): \(error)")
        }
    }

    private func canonicalGroupTransport(
        for preparedStream: XMPPStream
    ) -> GroupchatTransport {
        return { [weak self, weak preparedStream] element in
            guard let self,
                  let preparedStream,
                  preparedStream === self.xmppStream else {
                return
            }
            preparedStream.send(element)
        }
    }

    func groupMembershipDidActivate(_ rawGroupJID: String) {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        // Membership events only update local projection. Authoritative group
        // details and members are admitted immediately before the first MAM
        // window; permissions stay lazy behind their explicit UI actions.
        do {
            try GroupConversationProjectionStore.activate(
                owner: jid,
                groupJID: groupJID,
                in: WRealm.safe()
            )
        } catch {
            DDLogError("Group conversation activation failed for \(groupJID): \(error)")
        }
    }

    func groupMembershipDidDeactivate(_ rawGroupJID: String) {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        do {
            let realm = try WRealm.safe()
            let targets = GroupConversationProjectionStore.deactivationTargets(
                owner: jid,
                groupJID: groupJID,
                in: realm
            )
            var firstCleanupError: Error?
            for target in targets {
                do {
                    try GroupConversationProjectionStore.deactivate(
                        owner: jid,
                        groupJID: target,
                        in: realm
                    )
                } catch {
                    if firstCleanupError == nil {
                        firstCleanupError = error
                    }
                }
            }
            if let firstCleanupError {
                throw firstCleanupError
            }
        } catch {
            DDLogError("Group conversation cleanup failed for \(groupJID): \(error)")
        }
    }

    func removeCanonicalGroupInvite(_ rawGroupJID: String) {
        do {
            try GroupRepository(realm: WRealm.safe()).removeInvites(
                owner: jid,
                groupJID: rawGroupJID,
                direction: .incoming
            )
        } catch {
            DDLogError("Group invite cleanup failed for \(rawGroupJID): \(error)")
        }
    }
}
