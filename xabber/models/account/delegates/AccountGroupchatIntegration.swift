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

/// Rebinds canonical Groups to an authenticated stream-management generation
/// and restarts authoritative refresh for memberships that remained active
/// across the socket interruption.
enum CanonicalGroupStreamResumeRecovery {
    static func recover(
        binding: CanonicalGroupTransportBinding,
        stream: XMPPStream,
        transport: @escaping GroupchatTransport,
        invalidateCurrentActivations: () -> Void,
        activeGroupJIDs: () throws -> [String],
        activate: (String) throws -> Void
    ) throws {
        // Invalidate reducer-side work before replacing the transport. Any IQ
        // issued by the old generation is then completed as disconnected by
        // GroupchatService.prepare and cannot commit through an old ticket.
        invalidateCurrentActivations()
        binding.prepare(stream: stream, transport: transport)

        var seen = Set<String>()
        for rawGroupJID in try activeGroupJIDs() {
            let groupJID = GroupStorageKey.bareJID(rawGroupJID)
            guard !groupJID.isEmpty, seen.insert(groupJID).inserted else {
                continue
            }
            try activate(groupJID)
        }
    }
}

enum CanonicalGroupFullAuthenticationRecovery {
    static func recover(
        activeGroupJIDs: () throws -> [String],
        activate: (String) throws -> Void
    ) throws {
        var seen = Set<String>()
        for rawGroupJID in try activeGroupJIDs() {
            let groupJID = GroupStorageKey.bareJID(rawGroupJID)
            guard !groupJID.isEmpty, seen.insert(groupJID).inserted else {
                continue
            }
            try activate(groupJID)
        }
    }
}

enum CanonicalCreatedGroupOwnerAdmissionError: Error, Equatable {
    case missingSelfMemberID
    case creatorIsNotOwner
}

/// Completes the server-side create contract before UIKit presents the room.
/// A successful normal create already admits the creator as owner, so this is
/// identity hydration and one atomic local admission, not a join handshake.
@MainActor
enum CanonicalCreatedGroupOwnerAdmission {
    static func admit(
        snapshot: GroupSnapshot,
        owner: String,
        repository: GroupRepository,
        refreshMembers: (String) async throws -> [GroupMember]
    ) async throws -> GroupRepositoryProjection {
        guard let rawGroupJID = snapshot.jid else {
            throw GroupRepositoryError.invalidGroupJID
        }
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        guard !groupJID.isEmpty else {
            throw GroupRepositoryError.invalidGroupJID
        }

        let members = try await refreshMembers(groupJID)
        let existingSelfMemberID = try? repository.projection(
            owner: owner,
            groupJID: groupJID
        ).selfMemberID
        guard let selfMemberID = CanonicalGroupSelfIdentity.resolve(
            existingMemberID: existingSelfMemberID,
            ownerJID: owner,
            members: members
        ) else {
            throw CanonicalCreatedGroupOwnerAdmissionError.missingSelfMemberID
        }
        guard members.first(where: { $0.id == selfMemberID })?.role == .owner else {
            throw CanonicalCreatedGroupOwnerAdmissionError.creatorIsNotOwner
        }

        try repository.admitSnapshot(
            snapshot,
            membership: .both,
            memberID: selfMemberID,
            owner: owner,
            groupJID: groupJID,
            members: members
        )
        return try repository.projection(owner: owner, groupJID: groupJID)
    }
}

enum CanonicalGroupFreshAuthenticationRecoveryResult: Equatable {
    case admitted(memberID: String)
    case ignoredTombstone
}

enum CanonicalGroupFreshAuthenticationRecoveryError: Error, Equatable {
    case missingSelfMemberID
}

/// Converts a XEP-SYNC group candidate into canonical membership only after
/// current-server IQ authorization proves that the account is still a member.
/// The repository commit is atomic, so LastChat/MAM can never precede `.both`.
@MainActor
enum CanonicalGroupFreshAuthenticationRecovery {
    static func recover(
        owner: String,
        groupJID rawGroupJID: String,
        repository: GroupRepository,
        refreshGroup: () async throws -> GroupSnapshot,
        refreshMembers: () async throws -> [GroupMember],
        activateConversationAndHistory: (String) throws -> Void,
        refreshPermissions: (String) async throws -> GroupPermissionSet
    ) async throws -> CanonicalGroupFreshAuthenticationRecoveryResult {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        let snapshot = try await refreshGroup()
        let members = try await refreshMembers()
        let existingSelfMemberID = try? repository.projection(
            owner: owner,
            groupJID: groupJID
        ).selfMemberID
        guard let selfMemberID = CanonicalGroupSelfIdentity.resolve(
            existingMemberID: existingSelfMemberID,
            ownerJID: owner,
            members: members
        ) else {
            throw CanonicalGroupFreshAuthenticationRecoveryError.missingSelfMemberID
        }
        let admission = try repository.admitSnapshot(
            snapshot,
            membership: .both,
            memberID: selfMemberID,
            owner: owner,
            groupJID: groupJID,
            members: members,
            rejectingTombstone: true
        )
        guard admission == .admitted else {
            return .ignoredTombstone
        }

        try activateConversationAndHistory(groupJID)
        let permissions = try await refreshPermissions(selfMemberID)
        try repository.replacePermissionSet(
            permissions,
            owner: owner,
            groupJID: groupJID
        )
        return .admitted(memberID: selfMemberID)
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
        ) else {
            return false
        }
        return projection.state.selfSubscription == .both &&
            !projection.state.isDeleted
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

final class GroupActivationSyncGate {
    struct Ticket: Equatable {
        fileprivate let groupJID: String
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var active: [String: UInt64] = [:]

    func begin(groupJID rawGroupJID: String) -> Ticket? {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        lock.lock()
        defer { lock.unlock() }
        guard active[groupJID] == nil else { return nil }
        nextGeneration &+= 1
        active[groupJID] = nextGeneration
        return Ticket(groupJID: groupJID, generation: nextGeneration)
    }

    func end(_ ticket: Ticket) {
        lock.lock()
        if active[ticket.groupJID] == ticket.generation {
            active.removeValue(forKey: ticket.groupJID)
        }
        lock.unlock()
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active[ticket.groupJID] == ticket.generation
    }

    func invalidate(groupJID rawGroupJID: String) {
        lock.lock()
        active.removeValue(forKey: GroupStorageKey.bareJID(rawGroupJID))
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        active.removeAll()
        lock.unlock()
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
        guard realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) == nil else {
            return
        }
        let item = LastChatsStorageItem()
        item.primary = primary
        item.owner = owner
        item.jid = groupJID
        item.conversationType = .group
        item.messageDate = Date()
        try realm.write {
            realm.add(item, update: .error)
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

    /// XEP-0198 resume skips the ordinary extension setup path. The stream
    /// transport was intentionally cleared on disconnect, so it must be
    /// rebound here before active groups request MAM, snapshots, members, and
    /// direct permissions again.
    func recoverCanonicalGroupRuntimeAfterStreamManagementResume() {
        do {
            let stream = xmppStream
            try CanonicalGroupStreamResumeRecovery.recover(
                binding: canonicalGroupTransportBinding,
                stream: stream,
                transport: canonicalGroupTransport(for: stream),
                invalidateCurrentActivations: {
                    self.groupActivationSyncGate.invalidateAll()
                },
                activeGroupJIDs: {
                    try GroupRepository(realm: WRealm.safe())
                        .activeGroups(owners: [self.jid])
                        .map(\.groupJID)
                },
                activate: { groupJID in
                    self.groupMembershipDidActivate(groupJID)
                }
            )
        } catch {
            // The service transport is already prepared even when Realm lookup
            // fails, so live membership signals can still recover the state.
            DDLogError("Group resume recovery failed for \(jid): \(error)")
        }
    }

    /// Full SASL authentication prepares a fresh transport generation. Restore
    /// persisted `.both` groups immediately even when XEP-SYNC is unavailable;
    /// a clean Realm is populated later from verified synchronization candidates.
    func recoverCanonicalGroupRuntimeAfterFullAuthentication() {
        prepareCanonicalGroupTransport()
        do {
            try CanonicalGroupFullAuthenticationRecovery.recover(
                activeGroupJIDs: {
                    try GroupRepository(realm: WRealm.safe())
                        .activeGroups(owners: [self.jid])
                        .map(\.groupJID)
                },
                activate: { groupJID in
                    self.groupMembershipDidActivate(groupJID)
                }
            )
        } catch {
            DDLogError("Group full-auth recovery failed for \(jid): \(error)")
        }
    }

    /// A full authentication on a clean Realm has no canonical memberships to
    /// resume. XEP-SYNC provides candidates; group+members IQ authorization is
    /// the proof used to admit them without creating generic chat projections.
    func recoverCanonicalGroupMembershipFromSynchronization(
        _ rawGroupJID: String
    ) {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        guard let syncTicket = groupActivationSyncGate.begin(groupJID: groupJID) else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.groupActivationSyncGate.end(syncTicket) }
            do {
                let repository = GroupRepository(realm: try WRealm.safe())
                _ = try await CanonicalGroupFreshAuthenticationRecovery.recover(
                    owner: self.jid,
                    groupJID: groupJID,
                    repository: repository,
                    refreshGroup: {
                        try await self.groupchatService.refreshGroup(groupJID: groupJID)
                    },
                    refreshMembers: {
                        try await self.groupchatService.refreshMembers(groupJID: groupJID)
                    },
                    activateConversationAndHistory: { verifiedGroupJID in
                        guard self.groupActivationSyncGate.isCurrent(syncTicket) else {
                            throw CancellationError()
                        }
                        let realm = try WRealm.safe()
                        try GroupConversationProjectionStore.activate(
                            owner: self.jid,
                            groupJID: verifiedGroupJID,
                            in: realm
                        )
                        if let groupAddress = XMPPJID(string: verifiedGroupJID) {
                            self.mam.requestCanonicalGroupHistory(
                                self.xmppStream,
                                groupJID: groupAddress
                            )
                        }
                    },
                    refreshPermissions: { selfMemberID in
                        guard self.groupActivationSyncGate.isCurrent(syncTicket) else {
                            throw CancellationError()
                        }
                        return try await self.groupchatService.getPermissions(
                            groupJID: groupJID,
                            scope: .direct,
                            targetMemberID: selfMemberID
                        )
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                DDLogError("Fresh-auth group recovery failed for \(groupJID): \(error)")
            }
        }
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
        guard let syncTicket = groupActivationSyncGate.begin(groupJID: groupJID) else {
            return
        }
        do {
            try GroupConversationProjectionStore.activate(
                owner: jid,
                groupJID: groupJID,
                in: WRealm.safe()
            )
        } catch {
            groupActivationSyncGate.end(syncTicket)
            DDLogError("Group conversation activation failed for \(groupJID): \(error)")
            return
        }
        if let groupAddress = XMPPJID(string: groupJID) {
            mam.requestCanonicalGroupHistory(
                xmppStream,
                groupJID: groupAddress
            )
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.groupActivationSyncGate.end(syncTicket) }
            do {
                let snapshot = try await self.groupchatService.refreshGroup(
                    groupJID: groupJID
                )
                guard self.groupActivationSyncGate.isCurrent(syncTicket) else {
                    return
                }
                try GroupRepository(realm: WRealm.safe()).applySnapshot(
                    snapshot,
                    owner: self.jid,
                    groupJID: groupJID
                )

                let members = try await self.groupchatService.refreshMembers(
                    groupJID: groupJID
                )
                guard self.groupActivationSyncGate.isCurrent(syncTicket) else {
                    return
                }
                let repository = GroupRepository(realm: try WRealm.safe())
                let existingSelfMemberID = try? repository.projection(
                    owner: self.jid,
                    groupJID: groupJID
                ).selfMemberID
                try repository.replaceMembers(
                    members,
                    owner: self.jid,
                    groupJID: groupJID
                )
                let selfMemberID = CanonicalGroupSelfIdentity.resolve(
                    existingMemberID: existingSelfMemberID,
                    ownerJID: self.jid,
                    members: members
                )
                try repository.setSelfMembership(
                    .both,
                    memberID: selfMemberID,
                    owner: self.jid,
                    groupJID: groupJID
                )

                if let selfMemberID {
                    let permissions = try await self.groupchatService.getPermissions(
                        groupJID: groupJID,
                        scope: .direct,
                        targetMemberID: selfMemberID
                    )
                    guard self.groupActivationSyncGate.isCurrent(syncTicket) else {
                        return
                    }
                    try GroupRepository(realm: WRealm.safe()).replacePermissionSet(
                        permissions,
                        owner: self.jid,
                        groupJID: groupJID
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                DDLogError("Group activation sync failed for \(groupJID): \(error)")
            }
        }
    }

    func groupMembershipDidDeactivate(_ rawGroupJID: String) {
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)
        groupActivationSyncGate.invalidate(groupJID: groupJID)
        do {
            let realm = try WRealm.safe()
            let targets = GroupConversationProjectionStore.deactivationTargets(
                owner: jid,
                groupJID: groupJID,
                in: realm
            )
            var firstCleanupError: Error?
            for target in targets {
                groupActivationSyncGate.invalidate(groupJID: target)
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
