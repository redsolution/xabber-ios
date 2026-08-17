import Foundation

enum GroupEventProcessingResult: Equatable, Sendable {
    case handled
    case message(GroupMessageEvent)
    case invite(GroupInviteMessageEvent)
    case ignored
}

/// Applies the typed stanza boundary to canonical storage in transport order.
/// Message author cards are returned as immutable message snapshots and never
/// enter authoritative member storage.
final class GroupEventProcessor {
    typealias RepositoryProvider = () throws -> GroupRepository
    typealias PresenceReplySender = (String, GroupPresenceReply) throws -> Void

    private let owner: String
    private let repositoryProvider: RepositoryProvider
    private let presenceReplySender: PresenceReplySender
    private let activationHandler: (String) -> Void
    private let deactivationHandler: (String) -> Void

    init(
        owner: String,
        repository: @escaping RepositoryProvider,
        sendPresenceReply: @escaping PresenceReplySender = { _, _ in },
        onActivated: @escaping (String) -> Void = { _ in },
        onDeactivated: @escaping (String) -> Void = { _ in }
    ) {
        self.owner = GroupStorageKey.bareJID(owner)
        self.repositoryProvider = repository
        self.presenceReplySender = sendPresenceReply
        self.activationHandler = onActivated
        self.deactivationHandler = onDeactivated
    }

    @discardableResult
    func process(_ event: GroupStanzaEvent) throws -> GroupEventProcessingResult {
        switch event {
        case .iq:
            return .ignored

        case let .message(message):
            return .message(message)

        case let .invite(invite):
            let repository = try repositoryProvider()
            guard case let .message(_, reason, inviter) = invite.invite else {
                return .ignored
            }
            try repository.storeInvite(
                GroupInviteRecord(
                    groupJID: invite.groupJID,
                    direction: .incoming,
                    target: inviter?.id ?? inviter?.jid ?? invite.groupJID,
                    reason: reason,
                    inviter: inviter,
                    preview: invite.preview
                ),
                owner: owner
            )
            return .invite(invite)

        case let .reducer(input):
            let repository = try repositoryProvider()
            try apply(input.events, groupJID: input.groupJID, repository: repository)
            if let reply = input.requiredReply {
                try presenceReplySender(input.groupJID, reply)
            }
            try apply(
                input.eventsAfterReply,
                groupJID: input.groupJID,
                repository: repository
            )
            return .handled
        }
    }
}

private extension GroupEventProcessor {
    func apply(
        _ events: [GroupDomainEvent],
        groupJID: String,
        repository: GroupRepository
    ) throws {
        for event in events {
            try apply(event, groupJID: groupJID, repository: repository)
        }
    }

    func apply(
        _ event: GroupDomainEvent,
        groupJID: String,
        repository: GroupRepository
    ) throws {
        switch event {
        case let .created(snapshot):
            try repository.applySnapshot(snapshot, owner: owner, groupJID: groupJID)
            activationHandler(GroupStorageKey.bareJID(groupJID))

        case let .snapshot(snapshot):
            try repository.applySnapshot(snapshot, owner: owner, groupJID: groupJID)

        case let .patch(patch):
            try repository.applyPatch(patch, owner: owner, groupJID: groupJID)

        case let .replaceMembers(members):
            let projection = try repository.projection(
                owner: owner,
                groupJID: groupJID
            )
            let resolvedSelfMemberID = CanonicalGroupSelfIdentity.resolve(
                existingMemberID: projection.selfMemberID,
                ownerJID: owner,
                members: members
            )
            let reconciledMembers = CanonicalGroupSelfIdentity.attachingOwnerJID(
                to: members,
                selfMemberID: resolvedSelfMemberID,
                ownerJID: owner
            )
            try repository.replaceMembers(
                reconciledMembers,
                owner: owner,
                groupJID: groupJID
            )

        case .member:
            // Message/system author cards are historical snapshots. The full,
            // unpaged members request is the sole member synchronization path.
            break

        case let .permissions(permissions):
            try repository.replacePermissionSet(
                permissions,
                owner: owner,
                groupJID: groupJID
            )

        case .system:
            // System events are immutable message metadata. Their snapshots do
            // not replace authoritative group/member rows.
            break

        case let .selfSubscription(subscription):
            let memberID = currentMemberID(repository, groupJID: groupJID)
            switch subscription {
            case .wait:
                try repository.setSelfMembership(
                    .wait,
                    memberID: memberID,
                    owner: owner,
                    groupJID: groupJID
                )
            case .both:
                try repository.setSelfMembership(
                    .both,
                    memberID: memberID,
                    owner: owner,
                    groupJID: groupJID
                )
                activationHandler(GroupStorageKey.bareJID(groupJID))
            case .none:
                try repository.recordLeave(owner: owner, groupJID: groupJID)
                deactivationHandler(GroupStorageKey.bareJID(groupJID))
            }

        case .deleted:
            try repository.recordDeletion(owner: owner, groupJID: groupJID)
            deactivationHandler(GroupStorageKey.bareJID(groupJID))
        }
    }

    func currentMemberID(
        _ repository: GroupRepository,
        groupJID: String
    ) -> String? {
        try? repository.projection(owner: owner, groupJID: groupJID).selfMemberID
    }
}
