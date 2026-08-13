import Foundation
import RealmSwift

enum GroupRepositoryMutationResult: Equatable {
    case applied
    case ignoredInactiveMembership
}

enum GroupRepositoryError: Error, Equatable {
    case invalidOwner
    case invalidGroupJID
    case groupJIDMismatch(expected: String, received: String)
    case missingGroup(String)
    case emptyMemberID
    case duplicateMemberID(String)
    case missingPersonalPermissionTarget
    case unexpectedPermissionTarget
    case duplicatePermissionName(String)
    case permissionIntegerOverflow(String)
    case emptyInviteTarget
    case externalWriteTransaction
}

final class GroupRepository {
    private struct Context {
        let owner: String
        let groupJID: String
        let groupPrimary: String
    }

    private let realm: Realm

    init(realm: Realm) {
        self.realm = realm
    }

    @discardableResult
    func applySnapshot(
        _ snapshot: GroupSnapshot,
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryMutationResult {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try validate(snapshotJID: snapshot.jid, context: context)
        var result = GroupRepositoryMutationResult.applied

        try write {
            guard self.allowsGroupState(context) else {
                result = .ignoredInactiveMembership
                return
            }

            let item = self.realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: context.groupPrimary
            ) ?? GroupSnapshotStorageItem()
            item.primary = context.groupPrimary
            item.owner = context.owner
            item.groupJID = context.groupJID
            self.replaceSnapshot(item, with: snapshot)
            self.realm.add(item, update: .modified)
        }
        return result
    }

    @discardableResult
    func applyPatch(
        _ patch: GroupPatch,
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryMutationResult {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        if case let .value(jid) = patch.jid {
            try validate(snapshotJID: jid, context: context)
        }
        var result = GroupRepositoryMutationResult.applied

        try write {
            guard self.allowsGroupState(context) else {
                result = .ignoredInactiveMembership
                return
            }
            guard let item = self.realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: context.groupPrimary
            ) else {
                throw GroupRepositoryError.missingGroup(context.groupJID)
            }

            self.apply(patch, to: item)
        }
        return result
    }

    func setSelfMembership(
        _ state: GroupSelfMembershipState,
        memberID: String?,
        owner: String,
        groupJID: String
    ) throws {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try write {
            self.upsertMembership(
                state,
                memberID: memberID,
                context: context
            )
            if state != .both {
                self.deleteGroupState(context)
            }
        }
    }

    func recordLeave(owner: String, groupJID: String) throws {
        try recordTerminalMembership(owner: owner, groupJID: groupJID)
    }

    func recordDeletion(owner: String, groupJID: String) throws {
        try recordTerminalMembership(owner: owner, groupJID: groupJID)
    }

    @discardableResult
    func replaceMembers(
        _ members: [GroupMember],
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryMutationResult {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try validateMembers(members)
        let replacements = members.map {
            makeMember($0, context: context)
        }
        var result = GroupRepositoryMutationResult.applied

        try write {
            guard self.allowsGroupState(context) else {
                result = .ignoredInactiveMembership
                return
            }
            guard self.realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: context.groupPrimary
            ) != nil else {
                throw GroupRepositoryError.missingGroup(context.groupJID)
            }

            let current = self.realm.objects(GroupMemberStorageItem.self)
                .filter("groupPrimary == %@", context.groupPrimary)
            self.realm.delete(current)
            self.realm.add(replacements, update: .error)
        }
        return result
    }

    @discardableResult
    func replacePermissionSet(
        _ permissionSet: GroupPermissionSet,
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryMutationResult {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        let scopeAndTarget = try storageScope(for: permissionSet)
        let scope = scopeAndTarget.scope
        let targetMemberID = scopeAndTarget.targetMemberID
        try validatePermissions(permissionSet.permissions)
        let setPrimary = GroupStorageKey.permissionSetPrimary(
            owner: context.owner,
            groupJID: context.groupJID,
            scope: scope,
            targetMemberID: targetMemberID
        )
        let replacements = try permissionSet.permissions.map {
            try makePermission(
                $0,
                setPrimary: setPrimary,
                scope: scope,
                targetMemberID: targetMemberID,
                context: context
            )
        }
        var result = GroupRepositoryMutationResult.applied

        try write {
            guard self.allowsGroupState(context) else {
                result = .ignoredInactiveMembership
                return
            }
            guard self.realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: context.groupPrimary
            ) != nil else {
                throw GroupRepositoryError.missingGroup(context.groupJID)
            }

            let existingHeader = self.realm.object(
                ofType: GroupPermissionSetStorageItem.self,
                forPrimaryKey: setPrimary
            )
            let header = existingHeader ?? GroupPermissionSetStorageItem()
            if existingHeader == nil {
                header.primary = setPrimary
            }
            header.groupPrimary = context.groupPrimary
            header.owner = context.owner
            header.groupJID = context.groupJID
            header.scopeRaw = scope.rawValue
            header.targetMemberID = targetMemberID
            header.label = permissionSet.label
            header.actorMemberID = permissionSet.actor
            header.stamp = permissionSet.stamp

            let current = self.realm.objects(GroupPermissionStorageItem.self)
                .filter("setPrimary == %@", setPrimary)
            self.realm.delete(current)
            if existingHeader == nil {
                self.realm.add(header, update: .error)
            }
            self.realm.add(replacements, update: .error)
        }
        return result
    }

    func storeInvite(_ invite: GroupInviteRecord, owner: String) throws {
        let context = try makeContext(owner: owner, groupJID: invite.groupJID)
        let target = invite.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw GroupRepositoryError.emptyInviteTarget
        }
        let primary = GroupStorageKey.invitePrimary(
            owner: context.owner,
            groupJID: context.groupJID,
            direction: invite.direction,
            target: target
        )

        try write {
            let item = self.realm.object(
                ofType: GroupInviteStorageItem.self,
                forPrimaryKey: primary
            ) ?? GroupInviteStorageItem()
            item.primary = primary
            item.groupPrimary = context.groupPrimary
            item.owner = context.owner
            item.groupJID = context.groupJID
            item.directionRaw = invite.direction.rawValue
            item.target = target
            item.reason = invite.reason
            self.realm.add(item, update: .modified)
        }
    }

    private func makeContext(owner: String, groupJID: String) throws -> Context {
        let normalizedOwner = GroupStorageKey.bareJID(owner)
        guard !normalizedOwner.isEmpty else {
            throw GroupRepositoryError.invalidOwner
        }
        let normalizedGroup = GroupStorageKey.bareJID(groupJID)
        guard !normalizedGroup.isEmpty else {
            throw GroupRepositoryError.invalidGroupJID
        }
        return Context(
            owner: normalizedOwner,
            groupJID: normalizedGroup,
            groupPrimary: GroupStorageKey.groupPrimary(
                owner: normalizedOwner,
                groupJID: normalizedGroup
            )
        )
    }

    private func validate(snapshotJID: String?, context: Context) throws {
        guard let snapshotJID else {
            return
        }
        let normalizedSnapshotJID = GroupStorageKey.bareJID(snapshotJID)
        guard normalizedSnapshotJID == context.groupJID else {
            throw GroupRepositoryError.groupJIDMismatch(
                expected: context.groupJID,
                received: normalizedSnapshotJID
            )
        }
    }

    private func recordTerminalMembership(owner: String, groupJID: String) throws {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try write {
            let memberID = self.realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: context.groupPrimary
            )?.memberID
            self.upsertMembership(
                .none,
                memberID: memberID,
                context: context
            )
            self.deleteGroupState(context)
        }
    }

    private func upsertMembership(
        _ state: GroupSelfMembershipState,
        memberID: String?,
        context: Context
    ) {
        let existingItem = realm.object(
            ofType: GroupSelfMembershipStorageItem.self,
            forPrimaryKey: context.groupPrimary
        )
        let item = existingItem ?? GroupSelfMembershipStorageItem()
        if existingItem == nil {
            item.primary = context.groupPrimary
        }
        item.owner = context.owner
        item.groupJID = context.groupJID
        item.stateRaw = state.rawValue
        item.memberID = memberID
        if existingItem == nil {
            realm.add(item, update: .error)
        }
    }

    private func allowsGroupState(_ context: Context) -> Bool {
        guard let membership = realm.object(
            ofType: GroupSelfMembershipStorageItem.self,
            forPrimaryKey: context.groupPrimary
        ) else {
            return true
        }
        return membership.stateRaw == GroupSelfMembershipState.both.rawValue
    }

    private func deleteGroupState(_ context: Context) {
        if let snapshot = realm.object(
            ofType: GroupSnapshotStorageItem.self,
            forPrimaryKey: context.groupPrimary
        ) {
            realm.delete(snapshot)
        }
        realm.delete(
            realm.objects(GroupMemberStorageItem.self)
                .filter("groupPrimary == %@", context.groupPrimary)
        )
        realm.delete(
            realm.objects(GroupPermissionStorageItem.self)
                .filter("groupPrimary == %@", context.groupPrimary)
        )
        realm.delete(
            realm.objects(GroupPermissionSetStorageItem.self)
                .filter("groupPrimary == %@", context.groupPrimary)
        )
    }

    private func replaceSnapshot(
        _ item: GroupSnapshotStorageItem,
        with snapshot: GroupSnapshot
    ) {
        item.privacyRaw = snapshot.privacy?.rawValue
        item.parentJID = snapshot.parentJID.map(GroupStorageKey.bareJID)
        item.memberCount = snapshot.memberCount
        item.presentCount = snapshot.presentCount
        item.localpart = snapshot.localpart
        replaceInfo(item, with: snapshot.info)
        replaceSettings(item, with: snapshot.settings)
        replace(
            item.pinnedMessageIDs,
            with: unique(snapshot.pinnedMessageIDs ?? [])
        )
    }

    private func replaceInfo(
        _ item: GroupSnapshotStorageItem,
        with info: GroupInfo?
    ) {
        item.name = info?.name
        item.descriptionText = info?.description
        item.status = info?.status
        replaceAvatar(on: item, with: info?.avatar)
    }

    private func replaceSettings(
        _ item: GroupSnapshotStorageItem,
        with settings: GroupSettings?
    ) {
        item.membershipRaw = settings?.membership?.rawValue
        item.indexRaw = settings?.index?.rawValue
        item.lifecycleStateRaw = settings?.state?.rawValue
        replace(
            item.contacts,
            with: unique((settings?.contacts ?? []).map(GroupStorageKey.bareJID))
        )
        replace(
            item.domains,
            with: unique((settings?.domains ?? []).map(normalizedDomain))
        )
    }

    private func replaceAvatar(
        on item: GroupSnapshotStorageItem,
        with avatar: GroupAvatar?
    ) {
        item.avatarID = avatar?.id
        item.avatarMediaType = avatar?.mediaType
        item.avatarBytes = avatar?.bytes
        item.avatarWidth = avatar?.width
        item.avatarHeight = avatar?.height
        item.avatarURL = avatar?.url
    }

    private func apply(_ patch: GroupPatch, to item: GroupSnapshotStorageItem) {
        switch patch.privacy {
        case .absent:
            break
        case let .value(value):
            item.privacyRaw = value?.rawValue
        }
        switch patch.parentJID {
        case .absent:
            break
        case let .value(value):
            item.parentJID = value.map(GroupStorageKey.bareJID)
        }
        switch patch.memberCount {
        case .absent:
            break
        case let .value(value):
            item.memberCount = value
        }
        switch patch.presentCount {
        case .absent:
            break
        case let .value(value):
            item.presentCount = value
        }
        switch patch.localpart {
        case .absent:
            break
        case let .value(value):
            item.localpart = value
        }
        switch patch.info {
        case .absent:
            break
        case .value(nil):
            replaceInfo(item, with: nil)
        case let .value(infoPatch?):
            apply(infoPatch, to: item)
        }
        switch patch.settings {
        case .absent:
            break
        case .value(nil):
            replaceSettings(item, with: nil)
        case let .value(settingsPatch?):
            apply(settingsPatch, to: item)
        }
        switch patch.pinnedMessageIDs {
        case .absent:
            break
        case let .value(value):
            replace(item.pinnedMessageIDs, with: unique(value ?? []))
        }
    }

    private func apply(
        _ patch: GroupInfoPatch,
        to item: GroupSnapshotStorageItem
    ) {
        switch patch.name {
        case .absent:
            break
        case let .value(value):
            item.name = value
        }
        switch patch.description {
        case .absent:
            break
        case let .value(value):
            item.descriptionText = value
        }
        switch patch.status {
        case .absent:
            break
        case let .value(value):
            item.status = value
        }
        switch patch.avatar {
        case .absent:
            break
        case let .value(value):
            replaceAvatar(on: item, with: value)
        }
    }

    private func apply(
        _ patch: GroupSettingsPatch,
        to item: GroupSnapshotStorageItem
    ) {
        switch patch.membership {
        case .absent:
            break
        case let .value(value):
            item.membershipRaw = value?.rawValue
        }
        switch patch.index {
        case .absent:
            break
        case let .value(value):
            item.indexRaw = value?.rawValue
        }
        switch patch.state {
        case .absent:
            break
        case let .value(value):
            item.lifecycleStateRaw = value?.rawValue
        }
        switch patch.contacts {
        case .absent:
            break
        case let .value(value):
            replace(
                item.contacts,
                with: unique((value ?? []).map(GroupStorageKey.bareJID))
            )
        }
        switch patch.domains {
        case .absent:
            break
        case let .value(value):
            replace(
                item.domains,
                with: unique((value ?? []).map(normalizedDomain))
            )
        }
    }

    private func validateMembers(_ members: [GroupMember]) throws {
        var memberIDs = Set<String>()
        for member in members {
            guard !member.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GroupRepositoryError.emptyMemberID
            }
            guard memberIDs.insert(member.id).inserted else {
                throw GroupRepositoryError.duplicateMemberID(member.id)
            }
        }
    }

    private func makeMember(
        _ member: GroupMember,
        context: Context
    ) -> GroupMemberStorageItem {
        let item = GroupMemberStorageItem()
        item.primary = GroupStorageKey.memberPrimary(
            owner: context.owner,
            groupJID: context.groupJID,
            memberID: member.id
        )
        item.groupPrimary = context.groupPrimary
        item.owner = context.owner
        item.groupJID = context.groupJID
        item.memberID = member.id
        item.jid = member.jid.map(GroupStorageKey.bareJID)
        item.roleRaw = member.role?.rawValue
        item.nickname = member.nickname
        item.badge = member.badge
        item.lastSeen = member.lastSeen
        item.allowsPeerToPeer = member.allowsPeerToPeer
        item.avatarID = member.avatar?.id
        item.avatarMediaType = member.avatar?.mediaType
        item.avatarBytes = member.avatar?.bytes
        item.avatarWidth = member.avatar?.width
        item.avatarHeight = member.avatar?.height
        item.avatarURL = member.avatar?.url
        return item
    }

    private func storageScope(
        for permissionSet: GroupPermissionSet
    ) throws -> (scope: GroupPermissionStorageScope, targetMemberID: String?) {
        switch permissionSet.scope {
        case .direct:
            guard let target = permissionSet.target?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !target.isEmpty else {
                throw GroupRepositoryError.missingPersonalPermissionTarget
            }
            return (.personal, target)
        case .defaults:
            guard permissionSet.target == nil else {
                throw GroupRepositoryError.unexpectedPermissionTarget
            }
            return (.defaults, nil)
        case .newbies:
            guard permissionSet.target == nil else {
                throw GroupRepositoryError.unexpectedPermissionTarget
            }
            return (.newbies, nil)
        }
    }

    private func validatePermissions(_ permissions: [GroupPermission]) throws {
        var names = Set<String>()
        for permission in permissions {
            guard names.insert(permission.name).inserted else {
                throw GroupRepositoryError.duplicatePermissionName(permission.name)
            }
        }
    }

    private func makePermission(
        _ permission: GroupPermission,
        setPrimary: String,
        scope: GroupPermissionStorageScope,
        targetMemberID: String?,
        context: Context
    ) throws -> GroupPermissionStorageItem {
        let item = GroupPermissionStorageItem()
        item.primary = GroupStorageKey.permissionPrimary(
            setPrimary: setPrimary,
            name: permission.name
        )
        item.groupPrimary = context.groupPrimary
        item.setPrimary = setPrimary
        item.owner = context.owner
        item.groupJID = context.groupJID
        item.scopeRaw = scope.rawValue
        item.targetMemberID = targetMemberID
        item.name = permission.name
        item.level = permission.level
        item.status = permission.status
        item.seconds = try persistedInteger(permission.seconds, field: "seconds")
        item.expires = try persistedInteger(permission.expires, field: "expires")
        item.tag = permission.tag
        item.fixed = permission.fixed
        item.display = permission.display
        return item
    }

    private func persistedInteger(
        _ value: UInt64?,
        field: String
    ) throws -> Int64? {
        guard let value else {
            return nil
        }
        guard let persisted = Int64(exactly: value) else {
            throw GroupRepositoryError.permissionIntegerOverflow(field)
        }
        return persisted
    }

    private func replace(_ list: List<String>, with values: [String]) {
        list.removeAll()
        list.append(objectsIn: values)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func normalizedDomain(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func write(_ mutation: () throws -> Void) throws {
        guard !realm.isInWriteTransaction else {
            throw GroupRepositoryError.externalWriteTransaction
        }
        try realm.write {
            try mutation()
        }
    }
}
