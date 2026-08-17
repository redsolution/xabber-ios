import Foundation
import XMPPFramework

typealias GroupchatTransport = (XMPPElement) -> Void

enum GroupchatServicePayloadKind: String, Equatable, Sendable {
    case empty
    case snapshot
    case info
    case settings
    case members
    case member
    case invites
    case blocklist
    case permissions
    case invite
}

enum GroupchatServiceError: Error, Equatable {
    case notPrepared
    case invalidJID(String)
    case invalidRequestID(String)
    case missingCreatedGroupJID
    case invalidDemotionPermissions
    case invalidPermissionResetBaseline
    case unexpectedPayload(
        expected: GroupchatServicePayloadKind,
        actual: GroupchatServicePayloadKind
    )
    case iq(GroupIQStanzaError)
    case responseDecoding(GroupchatServiceResponseDecodingError)
}

enum GroupchatServiceResponseDecodingError: Error, Equatable {
    case rejectedCorrelatedResponse
    case router(GroupStanzaRouterError)
    case codec(GroupProtocolCodecError)
    case unexpected
}

enum GroupChatPresenceState: String, Equatable, Sendable {
    case active
    case gone
    case inactive
}

enum GroupModerationStage: String, Equatable, Sendable {
    case block
    case demote
    case kick
    case refreshBlocklist
    case refreshMembers
}

struct GroupModerationPartialFailure: Error {
    let failedStage: GroupModerationStage
    let completedStages: [GroupModerationStage]
    let underlying: Error
    let blocklist: [String]?
    let members: [GroupMember]?
    let refreshFailures: [GroupModerationStage]
}

struct GroupBlockMemberResult: Equatable, Sendable {
    let demoted: Bool
    let blocklist: [String]
    let members: [GroupMember]
}

/// The one delivery decision for outgoing group invitations.
/// Public groups let the inviting client address the user directly, while an
/// incognito group delegates delivery to the server to avoid exposing the
/// inviter's real JID.
enum GroupInviteDeliveryMode: Equatable, Sendable {
    case clientDirect
    case serverMediated

    init(privacy: GroupPrivacy) {
        switch privacy {
        case .publicGroup:
            self = .clientDirect
        case .incognito:
            self = .serverMediated
        }
    }

    var serverShouldSend: Bool {
        self == .serverMediated
    }
}

/// Builds the complete direct-permission mutation required before removing an
/// administrator. Response-only metadata is never echoed back to the server.
enum CanonicalAdminDemotionMutation {
    static func make(
        baseline: GroupPermissionSet,
        targetMemberID: String,
        now: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) -> GroupPermissionSet {
        let permissions = baseline.permissions.compactMap { permission -> GroupPermission? in
            guard permission.name.lowercased() != GroupMemberRole.owner.rawValue else {
                return nil
            }
            let seconds: UInt64?
            if let expires = permission.expires {
                seconds = expires > now ? expires - now : nil
            } else {
                seconds = permission.seconds
            }
            return GroupPermission(
                name: permission.name,
                level: permission.level,
                status: permission.level?.lowercased() == GroupMemberRole.admin.rawValue
                    ? false
                    : permission.status,
                seconds: seconds,
                expires: nil,
                tag: nil,
                fixed: false,
                display: nil
            )
        }
        return GroupPermissionSet(
            scope: .direct,
            target: targetMemberID,
            permissions: permissions
        )
    }
}

/// Builds cache-safe permission resets for the current server.
///
/// The server's permission delete path does not reliably invalidate its role/fast
/// permission caches. Resets therefore use ordinary canonical SET payloads:
/// defaults and personal permissions send every known baseline value, while
/// newbies send an explicit empty replacement set.
enum GroupPermissionResetMutationBuilder {
    static let defaultBaseline = GroupPermissionSet(
        scope: .defaults,
        permissions: [
            baselinePermission(name: "send-messages", level: .member, status: true),
            baselinePermission(name: "send-media", level: .member, status: true),
            baselinePermission(name: "add-members", level: .member, status: true),
            baselinePermission(name: "pin-messages", level: .member, status: false),
            baselinePermission(name: "change-group-info", level: .member, status: false)
        ]
    )

    static let adminBaseline = GroupPermissionSet(
        scope: .direct,
        permissions: [
            baselinePermission(name: "change-group-settings", level: .admin, status: false),
            baselinePermission(name: "change-user-info", level: .admin, status: false),
            baselinePermission(name: "delete-messages", level: .admin, status: false),
            baselinePermission(name: "change-permissions", level: .admin, status: false),
            baselinePermission(name: "change-default-permissions", level: .admin, status: false),
            baselinePermission(name: "block-users", level: .admin, status: false),
            baselinePermission(name: "create-admins", level: .admin, status: false)
        ]
    )

    static func defaults() -> GroupPermissionSet {
        GroupPermissionSet(
            scope: .defaults,
            permissions: sanitizedBaseline(defaultBaseline.permissions)
        )
    }

    static func personal(
        targetMemberID: String,
        baseline: GroupPermissionSet
    ) -> GroupPermissionSet {
        GroupPermissionSet(
            scope: .direct,
            target: targetMemberID,
            permissions: sanitizedBaseline(baseline.permissions)
        )
    }

    static func newbies() -> GroupPermissionSet {
        GroupPermissionSet(scope: .newbies, permissions: [])
    }

    private static func baselinePermission(
        name: String,
        level: GroupMemberRole,
        status: Bool
    ) -> GroupPermission {
        GroupPermission(name: name, level: level.rawValue, status: status)
    }

    private static func sanitizedBaseline(
        _ permissions: [GroupPermission]
    ) -> [GroupPermission] {
        permissions.compactMap { permission in
            let name = permission.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.lowercased() != GroupMemberRole.owner.rawValue else {
                return nil
            }
            return GroupPermission(
                name: name,
                level: permission.level,
                status: permission.status,
                seconds: nil,
                expires: nil,
                tag: nil,
                fixed: false,
                display: nil
            )
        }
    }
}

/// Typed command boundary for the current Xabber Groups protocol.
///
/// The service intentionally owns no storage or UI state. It serializes commands,
/// correlates their IQ responses, and returns immutable protocol values. Incoming
/// non-IQ group events continue through `GroupStanzaRouter` to the domain reducer.
final class GroupchatService {
    private enum CoordinatedResponse {
        case payload(GroupIQPayload)
        case iqError(GroupIQStanzaError)
        case responseDecoding(GroupchatServiceResponseDecodingError)
    }

    private struct PreparedTransport {
        let generation: UInt64
        let send: GroupchatTransport
    }

    private let coordinator: GroupRequestCoordinator<CoordinatedResponse>
    private let requestIDProvider: () -> String
    private let stateQueue = DispatchQueue(
        label: "com.xabber.groupchat-service.state"
    )
    private var transport: GroupchatTransport?
    private var transportGeneration: UInt64 = 0

    init(
        defaultTimeout: TimeInterval = 15,
        timeoutScheduler: GroupRequestTimeoutScheduling = DispatchGroupRequestTimeoutScheduler(),
        requestIDProvider: @escaping () -> String = { UUID().uuidString }
    ) {
        coordinator = GroupRequestCoordinator(
            defaultTimeout: defaultTimeout,
            scheduler: timeoutScheduler
        )
        self.requestIDProvider = requestIDProvider
    }

    var pendingRequestCount: Int {
        coordinator.pendingRequestCount
    }

    /// Installs the transport for the current stream generation.
    /// Preparing a replacement transport invalidates requests issued on the old one.
    func prepare(_ transport: @escaping GroupchatTransport) {
        let previousGeneration = stateQueue.sync { () -> UInt64? in
            let previousGeneration = self.transport.map { _ in
                self.transportGeneration
            }
            transportGeneration &+= 1
            self.transport = transport
            return previousGeneration
        }
        if let previousGeneration {
            coordinator.cancelPendingRequestsForDisconnect(
                transportGeneration: previousGeneration
            )
        }
    }

    /// Removes the stream transport and completes every pending request once.
    @discardableResult
    func disconnect() -> Int {
        let previousGeneration = stateQueue.sync { () -> UInt64? in
            let previousGeneration = transport.map { _ in
                transportGeneration
            }
            transportGeneration &+= 1
            transport = nil
            return previousGeneration
        }
        guard let previousGeneration else {
            return 0
        }
        return coordinator.cancelPendingRequestsForDisconnect(
            transportGeneration: previousGeneration
        )
    }

    /// Routes a correlated IQ result/error into its waiting async command.
    /// Unknown, duplicate, and late responses are ignored.
    @discardableResult
    func receive(_ iq: XMPPIQ) throws -> Bool {
        guard let requestID = nonEmpty(iq.elementID),
              coordinator.isPending(id: requestID) else {
            return false
        }

        let routedEvent: GroupStanzaEvent?
        do {
            routedEvent = try GroupStanzaRouter.route(
                iq,
                correlating: [requestID]
            )
        } catch let error as GroupStanzaRouterError {
            return completeResponseDecoding(
                .router(error),
                requestID: requestID
            )
        } catch let error as GroupProtocolCodecError {
            return completeResponseDecoding(
                .codec(error),
                requestID: requestID
            )
        } catch {
            return completeResponseDecoding(
                .unexpected,
                requestID: requestID
            )
        }
        guard case let .iq(event)? = routedEvent else {
            return completeResponseDecoding(
                .rejectedCorrelatedResponse,
                requestID: requestID
            )
        }

        let response: CoordinatedResponse
        switch event.outcome {
        case let .result(payload):
            response = .payload(payload)
        case let .error(error):
            response = .iqError(error)
        }
        return coordinator.receive(
            id: event.requestID,
            response: .result(response)
        ) == .completed
    }

    // MARK: - Creation and lifecycle

    func create(
        serviceJID: String,
        snapshot: GroupSnapshot
    ) async throws -> GroupSnapshot {
        let payload = try await request(
            command: .create(snapshot),
            iqType: .set,
            destination: try serviceDestination(serviceJID)
        )
        return try snapshotPayload(payload)
    }

    func createP2P(
        parentJID: String,
        memberID: String
    ) async throws -> GroupSnapshot {
        let parent = try groupDestination(parentJID)
        let payload = try await request(
            command: .createP2P(parentJID: parentJID, memberID: memberID),
            iqType: .set,
            destination: parent.domainJID
        )
        let snapshot = try snapshotPayload(payload)
        guard let groupJID = snapshot.jid else {
            throw GroupchatServiceError.missingCreatedGroupJID
        }
        // P2P creation places both members in `wait`; unlike normal create,
        // the creator must start the ordinary subscription handshake.
        try sendJoin(groupJID: groupJID)
        return snapshot
    }

    func delete(groupJID: String) async throws {
        let group = try groupDestination(groupJID)
        let payload = try await request(
            command: .delete(groupJID: groupJID),
            iqType: .set,
            destination: group.domainJID
        )
        try requireEmpty(payload)
    }

    // MARK: - Authoritative refresh

    func refreshGroup(groupJID: String) async throws -> GroupSnapshot {
        let payload = try await request(
            command: .groupDetails,
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        return try snapshotPayload(payload)
    }

    func refreshMembers(groupJID: String) async throws -> [GroupMember] {
        let payload = try await request(
            command: .fullMembers,
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        guard case let .members(members) = payload else {
            throw unexpectedPayload(expected: .members, actual: payload)
        }
        return members
    }

    func refreshInfo(groupJID: String) async throws -> GroupInfo {
        let payload = try await request(
            command: .updateInfo(GroupInfo()),
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        guard case let .info(info) = payload else {
            throw unexpectedPayload(expected: .info, actual: payload)
        }
        return info
    }

    func refreshSettings(groupJID: String) async throws -> GroupSettings {
        let payload = try await request(
            command: .updateSettings(GroupSettings()),
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        guard case let .settings(settings) = payload else {
            throw unexpectedPayload(expected: .settings, actual: payload)
        }
        return settings
    }

    func refreshInvites(groupJID: String) async throws -> [String] {
        let payload = try await request(
            command: .invites,
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        guard case let .invites(invites) = payload else {
            throw unexpectedPayload(expected: .invites, actual: payload)
        }
        return invites
    }

    func refreshBlocklist(groupJID: String) async throws -> [String] {
        let payload = try await request(
            command: .blocklist,
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        guard case let .blocklist(blocklist) = payload else {
            throw unexpectedPayload(expected: .blocklist, actual: payload)
        }
        return blocklist
    }

    func getPermissions(
        groupJID: String,
        scope: GroupPermissionScope,
        targetMemberID: String? = nil
    ) async throws -> GroupPermissionSet {
        let payload = try await request(
            command: .getPermissions(
                scope: scope,
                targetMemberID: targetMemberID
            ),
            iqType: .get,
            destination: try groupDestination(groupJID)
        )
        guard case let .permissions(permissions) = payload else {
            throw unexpectedPayload(expected: .permissions, actual: payload)
        }
        return permissions
    }

    /// Applies a permission patch/replacement and then reads the authoritative state.
    /// The GET is intentionally not sent until the SET IQ result succeeds.
    func setPermissions(
        groupJID: String,
        permissions: GroupPermissionSet
    ) async throws -> GroupPermissionSet {
        let payload = try await request(
            command: .setPermissions(permissions),
            iqType: .set,
            destination: try groupDestination(groupJID)
        )
        try requireEmpty(payload)
        return try await getPermissions(
            groupJID: groupJID,
            scope: permissions.scope,
            targetMemberID: permissions.target
        )
    }

    /// Restores every current-server default permission to its built-in value.
    /// This deliberately uses SET rather than the server's defective delete path.
    func resetDefaultPermissions(groupJID: String) async throws -> GroupPermissionSet {
        try await setPermissions(
            groupJID: groupJID,
            permissions: GroupPermissionResetMutationBuilder.defaults()
        )
    }

    /// Restores one complete personal permission level to the supplied authoritative
    /// baseline. The caller supplies either the current group defaults (member level)
    /// or `adminBaseline` (admin level), avoiding a mixed-level server mutation.
    func resetPersonalPermissions(
        groupJID: String,
        targetMemberID: String,
        baseline: GroupPermissionSet
    ) async throws -> GroupPermissionSet {
        let mutation = GroupPermissionResetMutationBuilder.personal(
            targetMemberID: targetMemberID,
            baseline: baseline
        )
        guard !mutation.permissions.isEmpty else {
            throw GroupchatServiceError.invalidPermissionResetBaseline
        }
        return try await setPermissions(
            groupJID: groupJID,
            permissions: mutation
        )
    }

    /// Clears newbies permissions through the server's replacement semantics.
    /// `<newbies><permissions/></newbies>` is intentional and is not a delete request.
    func resetNewbiesPermissions(groupJID: String) async throws -> GroupPermissionSet {
        try await setPermissions(
            groupJID: groupJID,
            permissions: GroupPermissionResetMutationBuilder.newbies()
        )
    }

    // MARK: - Mutations

    func updateInfo(
        groupJID: String,
        info: GroupInfo
    ) async throws -> GroupInfo {
        let payload = try await request(
            command: .updateInfo(info),
            iqType: .set,
            destination: try groupDestination(groupJID)
        )
        guard case .info = payload else {
            throw unexpectedPayload(expected: .info, actual: payload)
        }
        return try await refreshInfo(groupJID: groupJID)
    }

    func updateSettings(
        groupJID: String,
        settings: GroupSettings
    ) async throws -> GroupSettings {
        let payload = try await request(
            command: .updateSettings(settings),
            iqType: .set,
            destination: try groupDestination(groupJID)
        )
        guard case .settings = payload else {
            throw unexpectedPayload(expected: .settings, actual: payload)
        }
        return try await refreshSettings(groupJID: groupJID)
    }

    func updateGroupAvatar(
        groupJID: String,
        metadata: GroupAvatar
    ) async throws -> GroupInfo {
        try await updateInfo(
            groupJID: groupJID,
            info: GroupInfo(avatar: metadata)
        )
    }

    func updateMember(
        groupJID: String,
        update: GroupMemberUpdate
    ) async throws -> [GroupMember] {
        let payload = try await request(
            command: .updateMember(update),
            iqType: .set,
            destination: try groupDestination(groupJID)
        )
        switch payload {
        case .empty, .member:
            break
        default:
            throw unexpectedPayload(expected: .empty, actual: payload)
        }
        return try await refreshMembers(groupJID: groupJID)
    }

    func updateMemberAvatar(
        groupJID: String,
        memberID: String,
        metadata: GroupAvatar
    ) async throws -> [GroupMember] {
        try await updateMember(
            groupJID: groupJID,
            update: GroupMemberUpdate(
                memberID: memberID,
                avatar: metadata
            )
        )
    }

    func setOwner(
        groupJID: String,
        memberID: String
    ) async throws -> [GroupMember] {
        try await emptyMutation(.setOwner(memberID: memberID), groupJID: groupJID)
        return try await refreshMembers(groupJID: groupJID)
    }

    func pin(
        groupJID: String,
        groupStanzaID: String
    ) async throws -> GroupSnapshot {
        try await emptyMutation(
            .pin(groupStanzaID: groupStanzaID),
            groupJID: groupJID
        )
        return try await refreshGroup(groupJID: groupJID)
    }

    func unpin(
        groupJID: String,
        groupStanzaID: String
    ) async throws -> GroupSnapshot {
        try await emptyMutation(
            .unpin(groupStanzaID: groupStanzaID),
            groupJID: groupJID
        )
        return try await refreshGroup(groupJID: groupJID)
    }

    func invite(
        groupJID: String,
        targetJID: String,
        privacy: GroupPrivacy,
        reason: String? = nil
    ) async throws -> [String] {
        let delivery = GroupInviteDeliveryMode(privacy: privacy)
        try await emptyMutation(
            .invite(
                targetJID: targetJID,
                send: delivery.serverShouldSend,
                reason: reason
            ),
            groupJID: groupJID
        )
        if delivery == .clientDirect {
            try sendDirectInviteMessage(
                groupJID: groupJID,
                targetJID: targetJID,
                reason: reason
            )
        }
        return try await refreshInvites(groupJID: groupJID)
    }

    func declineInvite(groupJID: String) async throws {
        try await emptyMutation(.declineInvite, groupJID: groupJID)
    }

    func revokeInvite(
        groupJID: String,
        targetJID: String
    ) async throws -> [String] {
        try await emptyMutation(
            .revokeInvite(targetJID: targetJID),
            groupJID: groupJID
        )
        return try await refreshInvites(groupJID: groupJID)
    }

    func block(groupJID: String, targets: [String]) async throws -> [String] {
        try await emptyMutation(.block(targets: targets), groupJID: groupJID)
        return try await refreshBlocklist(groupJID: groupJID)
    }

    func unblock(
        groupJID: String,
        target: String
    ) async throws -> [String] {
        try await emptyMutation(.unblock(target: target), groupJID: groupJID)
        return try await refreshBlocklist(groupJID: groupJID)
    }

    /// Removes a typed member and enforces the server's admin lifecycle:
    /// administrators are first demoted using their complete direct baseline,
    /// then kicked by real JID. The returned list is always an authoritative
    /// full-members refresh; no local state is mutated optimistically.
    func kickMember(
        groupJID: String,
        member: GroupMember
    ) async throws -> [GroupMember] {
        let targetJID = member.jid ?? ""
        _ = try groupDestination(groupJID)
        _ = try GroupCommandCodec.encode(.kick(targetJID: targetJID))

        var completed: [GroupModerationStage] = []
        if member.role == .admin {
            let baseline = try await getPermissions(
                groupJID: groupJID,
                scope: .direct,
                targetMemberID: member.id
            )
            let demotion = CanonicalAdminDemotionMutation.make(
                baseline: baseline,
                targetMemberID: member.id
            )
            try validateDemotionPermissions(
                demotion,
                expectedMemberID: member.id
            )
            do {
                _ = try await setPermissions(
                    groupJID: groupJID,
                    permissions: demotion
                )
                completed.append(.demote)
            } catch {
                throw await moderationFailure(
                    failedStage: .demote,
                    completedStages: completed,
                    underlying: error,
                    groupJID: groupJID,
                    includeBlocklist: false
                )
            }
        }

        do {
            try await emptyMutation(
                .kick(targetJID: targetJID),
                groupJID: groupJID
            )
            completed.append(.kick)
        } catch {
            throw await moderationFailure(
                failedStage: .kick,
                completedStages: completed,
                underlying: error,
                groupJID: groupJID,
                includeBlocklist: false
            )
        }

        do {
            return try await refreshMembers(groupJID: groupJID)
        } catch {
            throw GroupModerationPartialFailure(
                failedStage: .refreshMembers,
                completedStages: completed,
                underlying: error,
                blocklist: nil,
                members: nil,
                refreshFailures: [.refreshMembers]
            )
        }
    }

    /// Runs the current-server moderation sequence without hiding partial state.
    /// `demotionPermissions`, when present, must be the caller's complete known
    /// direct baseline for the admin Member ID; the service never emits `<delete/>`.
    func blockMember(
        groupJID: String,
        targetJID: String,
        demotionPermissions: GroupPermissionSet? = nil
    ) async throws -> GroupBlockMemberResult {
        // Validate every command before the first state-changing stanza so a
        // local serialization error cannot leave only the block leg applied.
        _ = try groupDestination(groupJID)
        _ = try GroupCommandCodec.encode(.block(targets: [targetJID]))
        _ = try GroupCommandCodec.encode(.kick(targetJID: targetJID))
        if let demotionPermissions {
            try validateDemotionPermissions(demotionPermissions)
            _ = try GroupCommandCodec.encode(.setPermissions(demotionPermissions))
        }
        var completed: [GroupModerationStage] = []
        do {
            try await emptyMutation(.block(targets: [targetJID]), groupJID: groupJID)
            completed.append(.block)
        } catch {
            throw await moderationFailure(
                failedStage: .block,
                completedStages: completed,
                underlying: error,
                groupJID: groupJID
            )
        }

        if let demotionPermissions {
            do {
                _ = try await setPermissions(
                    groupJID: groupJID,
                    permissions: demotionPermissions
                )
                completed.append(.demote)
            } catch {
                throw await moderationFailure(
                    failedStage: .demote,
                    completedStages: completed,
                    underlying: error,
                    groupJID: groupJID
                )
            }
        }

        do {
            try await emptyMutation(
                .kick(targetJID: targetJID),
                groupJID: groupJID
            )
            completed.append(.kick)
        } catch {
            throw await moderationFailure(
                failedStage: .kick,
                completedStages: completed,
                underlying: error,
                groupJID: groupJID
            )
        }

        var blocklist: [String]?
        var members: [GroupMember]?
        var refreshFailures: [GroupModerationStage] = []
        var firstRefreshError: Error?
        do {
            blocklist = try await refreshBlocklist(groupJID: groupJID)
        } catch {
            refreshFailures.append(.refreshBlocklist)
            firstRefreshError = error
        }
        do {
            members = try await refreshMembers(groupJID: groupJID)
        } catch {
            refreshFailures.append(.refreshMembers)
            if firstRefreshError == nil {
                firstRefreshError = error
            }
        }
        if let firstRefreshError, let failedStage = refreshFailures.first {
            throw GroupModerationPartialFailure(
                failedStage: failedStage,
                completedStages: completed,
                underlying: firstRefreshError,
                blocklist: blocklist,
                members: members,
                refreshFailures: refreshFailures
            )
        }
        guard let blocklist, let members else {
            preconditionFailure("successful moderation refresh must contain both payloads")
        }
        return GroupBlockMemberResult(
            demoted: demotionPermissions != nil,
            blocklist: blocklist,
            members: members
        )
    }

    // MARK: - Send-only presence

    /// Starts the canonical membership handshake. Completion means only that
    /// the subscribe presence was sent; activation is driven by routed server
    /// presence and the reciprocal subscribed leg.
    func join(groupJID: String) async throws {
        try sendJoin(groupJID: groupJID)
    }

    /// Starts canonical leave. The authoritative `none` transition is driven
    /// by routed server presence, not by an optimistic local mutation.
    func leave(groupJID: String) async throws {
        try sendLeave(groupJID: groupJID)
    }

    func sendJoin(groupJID: String) throws {
        try send(
            XMPPPresence(
                type: .subscribe,
                to: try groupDestination(groupJID)
            )
        )
    }

    /// Completes the reciprocal subscription leg sent by the group service.
    func sendJoinApproval(groupJID: String) throws {
        try sendPresenceReply(groupJID: groupJID, reply: .subscribed)
    }

    func sendPresenceReply(
        groupJID: String,
        reply: GroupPresenceReply
    ) throws {
        let type: XMPPPresence.PresenceType
        switch reply {
        case .subscribed:
            type = .subscribed
        case .unsubscribed:
            type = .unsubscribed
        }
        try send(XMPPPresence(type: type, to: try groupDestination(groupJID)))
    }

    func sendLeave(groupJID: String) throws {
        try send(
            XMPPPresence(
                type: .unsubscribe,
                to: try groupDestination(groupJID)
            )
        )
    }

    func sendChatPresence(
        groupJID: String,
        state: GroupChatPresenceState
    ) throws {
        let stateElement = DDXMLElement(
            name: state.rawValue,
            xmlns: "http://jabber.org/protocol/chatstates"
        )
        try send(
            XMPPMessage(
                messageType: .chat,
                to: try groupDestination(groupJID),
                child: stateElement
            )
        )
    }
}

private final class GroupchatTaskCancellationState {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private extension GroupchatService {
    func sendDirectInviteMessage(
        groupJID: String,
        targetJID: String,
        reason: String?
    ) throws {
        let invite = try GroupProtocolCodec.encodeInvite(
            .message(groupJID: groupJID, reason: reason, inviter: nil)
        )
        let canonicalGroupJID = try groupDestination(groupJID).bare
        let messageID = UUID().uuidString
        let message = XMPPMessage(
            messageType: .chat,
            to: try groupDestination(targetJID),
            elementID: messageID,
            child: invite
        )
        message.addBody(
            "To join group add %@ to your contacts list".localizeString(
                id: "groupchat_legacy_invitation_body",
                arguments: [canonicalGroupJID]
            )
        )
        message.addOriginId(messageID)
        try send(message)
    }

    func moderationFailure(
        failedStage: GroupModerationStage,
        completedStages: [GroupModerationStage],
        underlying: Error,
        groupJID: String,
        includeBlocklist: Bool = true
    ) async -> GroupModerationPartialFailure {
        var blocklist: [String]?
        var members: [GroupMember]?
        var refreshFailures: [GroupModerationStage] = []
        if includeBlocklist {
            do {
                blocklist = try await refreshBlocklist(groupJID: groupJID)
            } catch {
                refreshFailures.append(.refreshBlocklist)
            }
        }
        do {
            members = try await refreshMembers(groupJID: groupJID)
        } catch {
            refreshFailures.append(.refreshMembers)
        }
        return GroupModerationPartialFailure(
            failedStage: failedStage,
            completedStages: completedStages,
            underlying: underlying,
            blocklist: blocklist,
            members: members,
            refreshFailures: refreshFailures
        )
    }

    func validateDemotionPermissions(
        _ permissions: GroupPermissionSet,
        expectedMemberID: String? = nil
    ) throws {
        let adminPermissions = permissions.permissions.filter {
            $0.level?.lowercased() == GroupMemberRole.admin.rawValue
        }
        guard permissions.scope == .direct,
              let target = nonEmpty(permissions.target),
              expectedMemberID.map({ $0 == target }) ?? true,
              !adminPermissions.isEmpty,
              adminPermissions.allSatisfy({ !$0.status }) else {
            throw GroupchatServiceError.invalidDemotionPermissions
        }
    }

    func emptyMutation(
        _ command: GroupCommand,
        groupJID: String
    ) async throws {
        let payload = try await request(
            command: command,
            iqType: .set,
            destination: try groupDestination(groupJID)
        )
        try requireEmpty(payload)
    }

    func request(
        command: GroupCommand,
        iqType: XMPPIQ.IQType,
        destination: XMPPJID
    ) async throws -> GroupIQPayload {
        let child = try GroupCommandCodec.encode(command)
        let preparedTransport = try currentTransport()
        let requestID = try nextRequestID()
        let iq = XMPPIQ(
            iqType: iqType,
            to: destination,
            elementID: requestID,
            child: child
        )
        let cancellationState = GroupchatTaskCancellationState()

        let response: CoordinatedResponse
        do {
            response = try await withTaskCancellationHandler(
                operation: {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<CoordinatedResponse, Error>) in
                        coordinator.registerAndSend(
                            id: requestID,
                            transportGeneration: preparedTransport.generation,
                            send: {
                                guard !cancellationState.isCancelled else {
                                    self.coordinator.cancel(
                                        id: requestID,
                                        reason: .cancelled
                                    )
                                    return
                                }
                                guard self.send(iq, on: preparedTransport) else {
                                    self.coordinator.cancel(
                                        id: requestID,
                                        reason: .disconnected
                                    )
                                    return
                                }
                            },
                            completion: { result in
                                continuation.resume(with: result)
                            }
                        )
                    }
                },
                onCancel: {
                    cancellationState.cancel()
                    self.coordinator.cancel(
                        id: requestID,
                        reason: .cancelled
                    )
                }
            )
        } catch GroupRequestError.cancelled {
            throw CancellationError()
        }

        switch response {
        case let .payload(payload):
            return payload
        case let .iqError(error):
            throw GroupchatServiceError.iq(error)
        case let .responseDecoding(error):
            throw GroupchatServiceError.responseDecoding(error)
        }
    }

    private func currentTransport() throws -> PreparedTransport {
        try stateQueue.sync {
            guard let transport else {
                throw GroupchatServiceError.notPrepared
            }
            return PreparedTransport(
                generation: transportGeneration,
                send: transport
            )
        }
    }

    func nextRequestID() throws -> String {
        let requestID = stateQueue.sync(execute: requestIDProvider)
        guard let requestID = nonEmpty(requestID) else {
            throw GroupchatServiceError.invalidRequestID(requestID)
        }
        return requestID
    }

    func send(_ element: XMPPElement) throws {
        let preparedTransport = try currentTransport()
        guard send(element, on: preparedTransport) else {
            throw GroupchatServiceError.notPrepared
        }
    }

    private func send(
        _ element: XMPPElement,
        on preparedTransport: PreparedTransport
    ) -> Bool {
        let isCurrentGeneration = stateQueue.sync {
            transport != nil
                && transportGeneration == preparedTransport.generation
        }
        guard isCurrentGeneration else {
            return false
        }
        preparedTransport.send(element)
        return true
    }

    func completeResponseDecoding(
        _ error: GroupchatServiceResponseDecodingError,
        requestID: String
    ) -> Bool {
        coordinator.receive(
            id: requestID,
            response: .result(.responseDecoding(error))
        ) == .completed
    }

    func snapshotPayload(_ payload: GroupIQPayload) throws -> GroupSnapshot {
        guard case let .snapshot(snapshot) = payload else {
            throw unexpectedPayload(expected: .snapshot, actual: payload)
        }
        return snapshot
    }

    func requireEmpty(_ payload: GroupIQPayload) throws {
        guard case .empty = payload else {
            throw unexpectedPayload(expected: .empty, actual: payload)
        }
    }

    func unexpectedPayload(
        expected: GroupchatServicePayloadKind,
        actual payload: GroupIQPayload
    ) -> GroupchatServiceError {
        .unexpectedPayload(expected: expected, actual: payloadKind(payload))
    }

    func payloadKind(_ payload: GroupIQPayload) -> GroupchatServicePayloadKind {
        switch payload {
        case .empty:
            return .empty
        case .snapshot:
            return .snapshot
        case .info:
            return .info
        case .settings:
            return .settings
        case .members:
            return .members
        case .member:
            return .member
        case .invites:
            return .invites
        case .blocklist:
            return .blocklist
        case .permissions:
            return .permissions
        case .invite:
            return .invite
        }
    }

    func serviceDestination(_ raw: String) throws -> XMPPJID {
        try normalizedBareJID(raw, requiresUser: false)
    }

    func groupDestination(_ raw: String) throws -> XMPPJID {
        try normalizedBareJID(raw, requiresUser: true)
    }

    func normalizedBareJID(
        _ raw: String,
        requiresUser: Bool
    ) throws -> XMPPJID {
        guard let value = nonEmpty(raw),
              let parsed = XMPPJID(string: value),
              !parsed.domain.isEmpty,
              (!requiresUser || parsed.user != nil),
              let normalized = XMPPJID(string: parsed.bare.lowercased()) else {
            throw GroupchatServiceError.invalidJID(raw)
        }
        return normalized
    }

    func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
