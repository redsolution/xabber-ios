import Foundation

enum GroupSelfSubscription: String, Equatable, Sendable {
    case wait
    case both
    case none
}

struct GroupViewState: Equatable, Sendable {
    let snapshot: GroupSnapshot
    let members: [GroupMember]
    let permissionSets: [GroupPermissionSet]
    let selfSubscription: GroupSelfSubscription
    let isDeleted: Bool
    let lastSystemEvent: GroupSystemEvent?

    init(
        snapshot: GroupSnapshot = GroupSnapshot(),
        members: [GroupMember] = [],
        permissionSets: [GroupPermissionSet] = [],
        selfSubscription: GroupSelfSubscription = .wait,
        isDeleted: Bool = false,
        lastSystemEvent: GroupSystemEvent? = nil
    ) {
        self.snapshot = snapshot
        self.members = members
        self.permissionSets = permissionSets
        self.selfSubscription = selfSubscription
        self.isDeleted = isDeleted
        self.lastSystemEvent = lastSystemEvent
    }

    var isActive: Bool {
        selfSubscription == .both && !isDeleted
    }

    var isTombstoned: Bool {
        selfSubscription == .none || isDeleted
    }

    func member(id: String) -> GroupMember? {
        members.first { $0.id == id }
    }
}

enum GroupDomainEvent: Equatable, Sendable {
    /// A server-authoritative creation. Unlike an ordinary snapshot, this may
    /// intentionally admit a JID which was previously tombstoned.
    case created(GroupSnapshot)
    case snapshot(GroupSnapshot)
    case patch(GroupPatch)
    case replaceMembers([GroupMember])
    case member(GroupMember)
    case permissions(GroupPermissionSet)
    case system(GroupSystemEvent)
    case selfSubscription(GroupSelfSubscription)
    case deleted
}

enum GroupDomainReducer {
    static func reduce(
        _ state: GroupViewState,
        event: GroupDomainEvent
    ) -> GroupViewState {
        switch event {
        case let .created(snapshot):
            return GroupViewState(
                snapshot: snapshot,
                selfSubscription: .both
            )

        case let .selfSubscription(subscription):
            return applying(subscription, to: state)

        case .deleted:
            return replacing(state, isDeleted: true)

        default:
            break
        }

        // Delete and self-membership-none are aggregate tombstones. Only an
        // explicit creation or authoritative `both` transition above may
        // admit the group again; delayed transport events are inert.
        guard !state.isTombstoned else {
            return state
        }

        switch event {
        case .created, .selfSubscription, .deleted:
            return state

        case let .snapshot(snapshot):
            return replacing(state, snapshot: snapshot)

        case let .patch(patch):
            return replacing(
                state,
                snapshot: applying(patch, to: state.snapshot)
            )

        case let .replaceMembers(members):
            guard state.isActive else {
                return state
            }
            return replacing(
                state,
                members: normalizedMembers(members)
            )

        case let .member(member):
            guard state.isActive, member.role != .some(.none) else {
                return state
            }
            return replacing(
                state,
                members: upserting(member, into: state.members)
            )

        case let .permissions(permissionSet):
            guard state.isActive else {
                return state
            }
            return replacing(
                state,
                permissionSets: upserting(
                    permissionSet,
                    into: state.permissionSets
                )
            )

        case let .system(systemEvent):
            guard state.isActive else {
                return state
            }
            return applying(systemEvent, to: state)
        }
    }
}

private extension GroupDomainReducer {
    static func applying(
        _ subscription: GroupSelfSubscription,
        to state: GroupViewState
    ) -> GroupViewState {
        switch subscription {
        case .both:
            // `both` is an authoritative admission transition and is one of
            // the two events allowed to clear aggregate tombstones.
            return replacing(
                state,
                selfSubscription: .both,
                isDeleted: false
            )

        case .none:
            return replacing(
                state,
                selfSubscription: GroupSelfSubscription.none
            )

        case .wait:
            guard !state.isTombstoned else {
                return state
            }
            return replacing(state, selfSubscription: .wait)
        }
    }

    static func applying(
        _ patch: GroupPatch,
        to snapshot: GroupSnapshot
    ) -> GroupSnapshot {
        GroupSnapshot(
            jid: patched(snapshot.jid, with: patch.jid),
            privacy: patched(snapshot.privacy, with: patch.privacy),
            parentJID: patched(snapshot.parentJID, with: patch.parentJID),
            memberCount: patched(snapshot.memberCount, with: patch.memberCount),
            localpart: patched(snapshot.localpart, with: patch.localpart),
            info: patchedInfo(snapshot.info, with: patch.info),
            settings: patchedSettings(snapshot.settings, with: patch.settings),
            pinnedMessageIDs: patched(
                snapshot.pinnedMessageIDs,
                with: patch.pinnedMessageIDs
            ),
            presentCount: patched(
                snapshot.presentCount,
                with: patch.presentCount
            )
        )
    }

    static func patchedInfo(
        _ current: GroupInfo?,
        with patch: GroupPatchValue<GroupInfoPatch?>
    ) -> GroupInfo? {
        switch patch {
        case .absent:
            return current
        case .value(nil):
            return nil
        case let .value(.some(patch)):
            return GroupInfo(
                name: patched(current?.name, with: patch.name),
                description: patched(
                    current?.description,
                    with: patch.description
                ),
                avatar: patched(current?.avatar, with: patch.avatar),
                status: patched(current?.status, with: patch.status)
            )
        }
    }

    static func patchedSettings(
        _ current: GroupSettings?,
        with patch: GroupPatchValue<GroupSettingsPatch?>
    ) -> GroupSettings? {
        switch patch {
        case .absent:
            return current
        case .value(nil):
            return nil
        case let .value(.some(patch)):
            return GroupSettings(
                membership: patched(
                    current?.membership,
                    with: patch.membership
                ),
                contacts: patched(current?.contacts, with: patch.contacts),
                domains: patched(current?.domains, with: patch.domains),
                index: patched(current?.index, with: patch.index),
                state: patched(current?.state, with: patch.state)
            )
        }
    }

    static func patched<Value: Equatable & Sendable>(
        _ current: Value,
        with patch: GroupPatchValue<Value>
    ) -> Value {
        switch patch {
        case .absent:
            return current
        case let .value(value):
            return value
        }
    }

    static func applying(
        _ systemEvent: GroupSystemEvent,
        to state: GroupViewState
    ) -> GroupViewState {
        var members = state.members

        switch systemEvent.type {
        case .join:
            if let member = systemEvent.user, member.role != .some(.none) {
                members = upserting(member, into: members)
            }

        case .leave:
            if let memberID = systemEvent.user?.id {
                members.removeAll { $0.id == memberID }
            }

        case .create, .update, .pinned:
            break
        }

        return replacing(
            state,
            members: members,
            lastSystemEvent: .value(systemEvent)
        )
    }

    static func normalizedMembers(_ members: [GroupMember]) -> [GroupMember] {
        var orderedIDs: [String] = []
        var memberByID: [String: GroupMember] = [:]

        for member in members where member.role != .some(.none) {
            if memberByID[member.id] == nil {
                orderedIDs.append(member.id)
            }
            memberByID[member.id] = member
        }

        return orderedIDs.compactMap { memberByID[$0] }
    }

    static func upserting(
        _ member: GroupMember,
        into members: [GroupMember]
    ) -> [GroupMember] {
        var updated = members
        if let index = updated.firstIndex(where: { $0.id == member.id }) {
            updated[index] = member
        } else {
            updated.append(member)
        }
        return updated
    }

    static func upserting(
        _ permissionSet: GroupPermissionSet,
        into permissionSets: [GroupPermissionSet]
    ) -> [GroupPermissionSet] {
        var updated = permissionSets
        if let index = updated.firstIndex(where: {
            $0.scope == permissionSet.scope && $0.target == permissionSet.target
        }) {
            updated[index] = permissionSet
        } else {
            updated.append(permissionSet)
        }
        return updated
    }

    static func replacing(
        _ state: GroupViewState,
        snapshot: GroupSnapshot? = nil,
        members: [GroupMember]? = nil,
        permissionSets: [GroupPermissionSet]? = nil,
        selfSubscription: GroupSelfSubscription? = nil,
        isDeleted: Bool? = nil,
        lastSystemEvent: GroupPatchValue<GroupSystemEvent?> = .absent
    ) -> GroupViewState {
        GroupViewState(
            snapshot: snapshot ?? state.snapshot,
            members: members ?? state.members,
            permissionSets: permissionSets ?? state.permissionSets,
            selfSubscription: selfSubscription ?? state.selfSubscription,
            isDeleted: isDeleted ?? state.isDeleted,
            lastSystemEvent: patched(
                state.lastSystemEvent,
                with: lastSystemEvent
            )
        )
    }
}
