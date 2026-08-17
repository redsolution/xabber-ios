import Foundation
import RealmSwift

enum GroupRepositoryMutationResult: Equatable {
    case applied
    case ignoredInactiveMembership
}

enum GroupRepositoryAdmissionResult: Equatable {
    case admitted
    case ignoredTombstone
}

enum GroupRepositoryError: Error, Equatable {
    case invalidOwner
    case invalidGroupJID
    case groupJIDMismatch(expected: String, received: String)
    case missingGroup(String)
    case emptyMemberID
    case duplicateMemberID(String)
    case unknownSelfMemberID(String)
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
            guard self.allowsSnapshotState(context) else {
                result = .ignoredInactiveMembership
                return
            }

            let existingItem = self.realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: context.groupPrimary
            )
            let item = existingItem ?? GroupSnapshotStorageItem()
            if existingItem == nil {
                item.primary = context.groupPrimary
                item.owner = context.owner
                item.groupJID = context.groupJID
            }
            self.replaceSnapshot(item, with: snapshot)
            if existingItem == nil {
                self.realm.add(item, update: .error)
            }
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
            guard self.allowsSnapshotState(context) else {
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
            let previousStateRaw = self.realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: context.groupPrimary
            )?.stateRaw
            let previousState = previousStateRaw.flatMap {
                GroupSelfMembershipState(rawValue: $0)
            }
            self.upsertMembership(
                state,
                memberID: memberID,
                context: context
            )
            if state == .none || (state == .wait && previousState != .wait) {
                self.deleteGroupState(context)
            }
        }
    }

    /// Persists the server-confirmed normal-create result with an eager local
    /// creator owner. Roster subscription state is intentionally untouched:
    /// group authorization derives from this member role.
    func admitCreatedOwner(
        _ snapshot: GroupSnapshot,
        creator: GroupMember,
        owner: String,
        groupJID: String
    ) throws {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try validate(snapshotJID: snapshot.jid, context: context)
        try validateMembers([creator])
        guard creator.role == .owner,
              creator.jid.map(GroupStorageKey.bareJID) == context.owner else {
            throw GroupRepositoryError.unknownSelfMemberID(creator.id)
        }
        let replacement = makeMember(creator, context: context)

        try write {
            self.deleteGroupState(context)
            if let legacySubscription = self.realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: context.groupPrimary
            ) {
                self.realm.delete(legacySubscription)
            }
            self.realm.delete(
                self.realm.objects(GroupInviteStorageItem.self)
                    .filter("groupPrimary == %@", context.groupPrimary)
            )

            let item = GroupSnapshotStorageItem()
            item.primary = context.groupPrimary
            item.owner = context.owner
            item.groupJID = context.groupJID
            self.replaceSnapshot(item, with: snapshot)
            self.realm.add(item, update: .error)
            self.realm.add(replacement, update: .error)
        }
    }

    /// Admits a server-returned group snapshot and its self membership as one
    /// coherent Realm transition. A fresh `wait` admission clears stale
    /// authoritative state, while an already-active `both` membership keeps
    /// members and permissions intact during P2P conflict reconciliation.
    @discardableResult
    func admitSnapshot(
        _ snapshot: GroupSnapshot,
        membership state: GroupSelfMembershipState,
        memberID: String?,
        owner: String,
        groupJID: String,
        members: [GroupMember]? = nil,
        rejectingTombstone: Bool = false
    ) throws -> GroupRepositoryAdmissionResult {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try validate(snapshotJID: snapshot.jid, context: context)
        if let members {
            try validateMembers(members)
            guard let memberID,
                  !memberID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  members.contains(where: { $0.id == memberID }) else {
                throw GroupRepositoryError.unknownSelfMemberID(memberID ?? "")
            }
        }
        let memberReplacements = members?.map { makeMember($0, context: context) }
        var result = GroupRepositoryAdmissionResult.admitted
        try write {
            let previousStateRaw = self.realm.object(
                ofType: GroupSelfMembershipStorageItem.self,
                forPrimaryKey: context.groupPrimary
            )?.stateRaw
            let previousState = previousStateRaw.flatMap {
                GroupSelfMembershipState(rawValue: $0)
            }
            if rejectingTombstone,
               previousState == GroupSelfMembershipState.none {
                result = .ignoredTombstone
                return
            }
            if state == .wait, previousState != .wait {
                self.deleteGroupState(context)
            }
            self.upsertMembership(
                state,
                memberID: memberID,
                context: context
            )
            guard state != .none else {
                self.deleteGroupState(context)
                return
            }
            let existingItem = self.realm.object(
                ofType: GroupSnapshotStorageItem.self,
                forPrimaryKey: context.groupPrimary
            )
            let item = existingItem ?? GroupSnapshotStorageItem()
            if existingItem == nil {
                item.primary = context.groupPrimary
                item.owner = context.owner
                item.groupJID = context.groupJID
            }
            self.replaceSnapshot(item, with: snapshot)
            if existingItem == nil {
                self.realm.add(item, update: .error)
            }
            if let memberReplacements {
                self.realm.delete(
                    self.realm.objects(GroupMemberStorageItem.self)
                        .filter("groupPrimary == %@", context.groupPrimary)
                )
                self.realm.add(memberReplacements, update: .error)
                self.realm.delete(
                    self.realm.objects(GroupInviteStorageItem.self).filter(
                        "groupPrimary == %@ AND directionRaw == %@",
                        context.groupPrimary,
                        GroupInviteDirection.incoming.rawValue
                    )
                )
            }
        }
        return result
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
            guard self.allowsActiveState(context) else {
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
            guard self.allowsActiveState(context) else {
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
        if let previewJID = invite.preview?.jid {
            try validate(snapshotJID: previewJID, context: context)
        }
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
            let existingItem = self.realm.object(
                ofType: GroupInviteStorageItem.self,
                forPrimaryKey: primary
            )
            let item = existingItem ?? GroupInviteStorageItem()
            if existingItem == nil {
                item.primary = primary
                item.groupPrimary = context.groupPrimary
                item.owner = context.owner
                item.groupJID = context.groupJID
            }
            item.directionRaw = invite.direction.rawValue
            item.target = target
            item.reason = invite.reason
            self.replaceInviteAuthor(item, with: invite.inviter)
            self.replaceInvitePreview(
                item,
                with: invite.preview
            )
            if existingItem == nil {
                self.realm.add(item, update: .error)
            }
        }
    }

    func invites(
        owner: String,
        direction: GroupInviteDirection? = nil
    ) throws -> [GroupInviteRecord] {
        let normalizedOwner = GroupStorageKey.bareJID(owner)
        guard !normalizedOwner.isEmpty else {
            throw GroupRepositoryError.invalidOwner
        }
        var items = realm.objects(GroupInviteStorageItem.self)
            .filter("owner == %@", normalizedOwner)
        if let direction {
            items = items.filter("directionRaw == %@", direction.rawValue)
        }
        return items
            .sorted(byKeyPath: "primary", ascending: true)
            .compactMap { self.makeInviteRecord($0) }
    }

    func invite(primary: String) throws -> GroupInviteRecord? {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrimary.isEmpty else {
            return nil
        }
        return realm.object(
            ofType: GroupInviteStorageItem.self,
            forPrimaryKey: trimmedPrimary
        ).flatMap { self.makeInviteRecord($0) }
    }

    func incomingInvite(owner: String, groupJID: String) throws -> GroupInviteRecord? {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        return realm.objects(GroupInviteStorageItem.self)
            .filter(
                "groupPrimary == %@ AND directionRaw == %@",
                context.groupPrimary,
                GroupInviteDirection.incoming.rawValue
            )
            .sorted(byKeyPath: "primary", ascending: true)
            .first
            .flatMap { self.makeInviteRecord($0) }
    }

    func removeInvite(primary: String) throws {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrimary.isEmpty else {
            return
        }
        try write {
            guard let invite = self.realm.object(
                ofType: GroupInviteStorageItem.self,
                forPrimaryKey: trimmedPrimary
            ) else {
                return
            }
            self.realm.delete(invite)
        }
    }

    @discardableResult
    func replaceOutgoingInvites(
        owner: String,
        groupJID: String,
        targets: [String]
    ) throws -> [GroupInviteRecord] {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        var seen = Set<String>()
        let normalizedTargets = try targets.map { rawTarget -> String in
            let target = GroupStorageKey.bareJID(rawTarget)
            guard !target.isEmpty else {
                throw GroupRepositoryError.emptyInviteTarget
            }
            return target
        }.filter { seen.insert($0).inserted }
        let replacements = normalizedTargets.map { target -> GroupInviteStorageItem in
            let item = GroupInviteStorageItem()
            item.primary = GroupStorageKey.invitePrimary(
                owner: context.owner,
                groupJID: context.groupJID,
                direction: .outgoing,
                target: target
            )
            item.groupPrimary = context.groupPrimary
            item.owner = context.owner
            item.groupJID = context.groupJID
            item.directionRaw = GroupInviteDirection.outgoing.rawValue
            item.target = target
            return item
        }

        try write {
            let current = self.realm.objects(GroupInviteStorageItem.self).filter(
                "groupPrimary == %@ AND directionRaw == %@",
                context.groupPrimary,
                GroupInviteDirection.outgoing.rawValue
            )
            self.realm.delete(current)
            self.realm.add(replacements, update: .error)
        }
        return replacements.compactMap { self.makeInviteRecord($0) }
    }

    func removeInvites(
        owner: String,
        groupJID: String,
        direction: GroupInviteDirection? = nil,
        target: String? = nil
    ) throws {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        try write {
            var invitations = self.realm.objects(GroupInviteStorageItem.self)
                .filter("groupPrimary == %@", context.groupPrimary)
            if let direction {
                invitations = invitations.filter(
                    "directionRaw == %@",
                    direction.rawValue
                )
            }
            if let target {
                invitations = invitations.filter("target == %@", target)
            }
            self.realm.delete(invitations)
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
        let terminalContexts = try terminalContexts(startingAt: context)
        try write {
            for terminalContext in terminalContexts {
                let memberID = self.realm.object(
                    ofType: GroupSelfMembershipStorageItem.self,
                    forPrimaryKey: terminalContext.groupPrimary
                )?.memberID
                self.upsertMembership(
                    .none,
                    memberID: memberID,
                    context: terminalContext
                )
                self.deleteGroupState(terminalContext)
                self.realm.delete(
                    self.realm.objects(GroupInviteStorageItem.self)
                        .filter("groupPrimary == %@", terminalContext.groupPrimary)
                )
            }
        }
    }

    /// Resolves descendants before entering the write transaction because
    /// deleting the parent snapshots also removes the P2P relationship index.
    private func terminalContexts(startingAt root: Context) throws -> [Context] {
        var result = [root]
        var seen = Set([root.groupPrimary])
        var index = 0
        while index < result.count {
            let parent = result[index]
            index += 1
            let childJIDs = Array(
                realm.objects(GroupSnapshotStorageItem.self)
                    .filter(
                        "owner == %@ AND parentJID == %@",
                        parent.owner,
                        parent.groupJID
                    )
                    .map(\.groupJID)
            )
            for childJID in childJIDs {
                let child = try makeContext(owner: parent.owner, groupJID: childJID)
                if seen.insert(child.groupPrimary).inserted {
                    result.append(child)
                }
            }
        }
        return result
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
        // A nil value means the latest stanza did not disclose identity. It
        // must not erase a stable Member ID learned earlier in an incognito
        // group, where no real JID exists to reconstruct it later.
        item.memberID = memberID ?? existingItem?.memberID
        if existingItem == nil {
            realm.add(item, update: .error)
        }
    }

    private func allowsSnapshotState(_ context: Context) -> Bool {
        guard let membership = realm.object(
            ofType: GroupSelfMembershipStorageItem.self,
            forPrimaryKey: context.groupPrimary
        ) else {
            return true
        }
        return membership.stateRaw != GroupSelfMembershipState.none.rawValue
    }

    private func allowsActiveState(_ context: Context) -> Bool {
        guard let membership = realm.object(
            ofType: GroupSelfMembershipStorageItem.self,
            forPrimaryKey: context.groupPrimary
        ) else {
            return true
        }
        return membership.stateRaw != GroupSelfMembershipState.none.rawValue
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
        item.pinnedMessageIDsPresent = snapshot.pinnedMessageIDs != nil
        replace(
            item.pinnedMessageIDs,
            with: unique(snapshot.pinnedMessageIDs ?? [])
        )
    }

    private func replaceInviteAuthor(
        _ item: GroupInviteStorageItem,
        with inviter: GroupMember?
    ) {
        item.inviterID = inviter?.id
        item.inviterJID = inviter?.jid.map(GroupStorageKey.bareJID)
        item.inviterRoleRaw = inviter?.role?.rawValue
        item.inviterNickname = inviter?.nickname
        item.inviterBadge = inviter?.badge
        item.inviterLastSeen = inviter?.lastSeen
        item.inviterAllowsPeerToPeer = inviter?.allowsPeerToPeer ?? false
        item.inviterAvatarID = inviter?.avatar?.id
        item.inviterAvatarMediaType = inviter?.avatar?.mediaType
        item.inviterAvatarBytes = inviter?.avatar?.bytes
        item.inviterAvatarWidth = inviter?.avatar?.width
        item.inviterAvatarHeight = inviter?.avatar?.height
        item.inviterAvatarURL = inviter?.avatar?.url
    }

    private func replaceInvitePreview(
        _ item: GroupInviteStorageItem,
        with preview: GroupSnapshot?
    ) {
        item.previewPresent = preview != nil
        item.previewPrivacyRaw = preview?.privacy?.rawValue
        item.previewParentJID = preview?.parentJID.map(GroupStorageKey.bareJID)
        item.previewMemberCount = preview?.memberCount
        item.previewPresentCount = preview?.presentCount
        item.previewLocalpart = preview?.localpart
        item.previewInfoPresent = preview?.info != nil
        item.previewName = preview?.info?.name
        item.previewDescriptionText = preview?.info?.description
        item.previewStatus = preview?.info?.status
        item.previewAvatarID = preview?.info?.avatar?.id
        item.previewAvatarMediaType = preview?.info?.avatar?.mediaType
        item.previewAvatarBytes = preview?.info?.avatar?.bytes
        item.previewAvatarWidth = preview?.info?.avatar?.width
        item.previewAvatarHeight = preview?.info?.avatar?.height
        item.previewAvatarURL = preview?.info?.avatar?.url
        item.previewSettingsPresent = preview?.settings != nil
        item.previewMembershipRaw = preview?.settings?.membership?.rawValue
        item.previewIndexRaw = preview?.settings?.index?.rawValue
        item.previewLifecycleStateRaw = preview?.settings?.state?.rawValue
        item.previewContactsPresent = preview?.settings?.contacts != nil
        item.previewDomainsPresent = preview?.settings?.domains != nil
        replace(
            item.previewContacts,
            with: unique((preview?.settings?.contacts ?? []).map(GroupStorageKey.bareJID))
        )
        replace(
            item.previewDomains,
            with: unique((preview?.settings?.domains ?? []).map(normalizedDomain))
        )
        item.previewPinnedMessageIDsPresent = preview?.pinnedMessageIDs != nil
        replace(
            item.previewPinnedMessageIDs,
            with: unique(preview?.pinnedMessageIDs ?? [])
        )
    }

    private func makeInviteRecord(_ item: GroupInviteStorageItem) -> GroupInviteRecord? {
        guard let direction = GroupInviteDirection(rawValue: item.directionRaw) else {
            return nil
        }
        let inviter: GroupMember? = item.inviterID.map { id in
            GroupMember(
                id: id,
                jid: item.inviterJID,
                role: item.inviterRoleRaw.flatMap(GroupMemberRole.init(rawValue:)),
                nickname: item.inviterNickname,
                badge: item.inviterBadge,
                avatar: makeAvatar(
                    id: item.inviterAvatarID,
                    mediaType: item.inviterAvatarMediaType,
                    bytes: item.inviterAvatarBytes,
                    width: item.inviterAvatarWidth,
                    height: item.inviterAvatarHeight,
                    url: item.inviterAvatarURL
                ),
                lastSeen: item.inviterLastSeen,
                allowsPeerToPeer: item.inviterAllowsPeerToPeer
            )
        }
        let preview: GroupSnapshot?
        if item.previewPresent {
            let avatar = makeAvatar(
                id: item.previewAvatarID,
                mediaType: item.previewAvatarMediaType,
                bytes: item.previewAvatarBytes,
                width: item.previewAvatarWidth,
                height: item.previewAvatarHeight,
                url: item.previewAvatarURL
            )
            preview = GroupSnapshot(
                jid: item.groupJID,
                privacy: item.previewPrivacyRaw.flatMap(GroupPrivacy.init(rawValue:)),
                parentJID: item.previewParentJID,
                memberCount: item.previewMemberCount,
                localpart: item.previewLocalpart,
                info: item.previewInfoPresent
                    ? GroupInfo(
                        name: item.previewName,
                        description: item.previewDescriptionText,
                        avatar: avatar,
                        status: item.previewStatus
                    )
                    : nil,
                settings: item.previewSettingsPresent
                    ? GroupSettings(
                        membership: item.previewMembershipRaw.flatMap(
                            GroupMembership.init(rawValue:)
                        ),
                        contacts: item.previewContactsPresent
                            ? Array(item.previewContacts)
                            : nil,
                        domains: item.previewDomainsPresent
                            ? Array(item.previewDomains)
                            : nil,
                        index: item.previewIndexRaw.flatMap(
                            GroupIndexVisibility.init(rawValue:)
                        ),
                        state: item.previewLifecycleStateRaw.flatMap(
                            GroupLifecycleState.init(rawValue:)
                        )
                    )
                    : nil,
                pinnedMessageIDs: item.previewPinnedMessageIDsPresent
                    ? Array(item.previewPinnedMessageIDs)
                    : nil,
                presentCount: item.previewPresentCount
            )
        } else {
            preview = nil
        }
        return GroupInviteRecord(
            primary: item.primary,
            owner: item.owner,
            groupJID: item.groupJID,
            direction: direction,
            target: item.target,
            reason: item.reason,
            inviter: inviter,
            preview: preview
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
        item.settingsPresent = settings != nil
        item.membershipRaw = settings?.membership?.rawValue
        item.indexRaw = settings?.index?.rawValue
        item.lifecycleStateRaw = settings?.state?.rawValue
        item.contactsPresent = settings?.contacts != nil
        item.domainsPresent = settings?.domains != nil
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
            item.settingsPresent = true
            apply(settingsPatch, to: item)
        }
        switch patch.pinnedMessageIDs {
        case .absent:
            break
        case let .value(value):
            item.pinnedMessageIDsPresent = value != nil
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
            item.contactsPresent = value != nil
            replace(
                item.contacts,
                with: unique((value ?? []).map(GroupStorageKey.bareJID))
            )
        }
        switch patch.domains {
        case .absent:
            break
        case let .value(value):
            item.domainsPresent = value != nil
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

struct GroupRepositoryProjection: Equatable, Sendable {
    let state: GroupViewState
    let selfMemberID: String?
    let capabilities: GroupCapabilities
}

/// Immutable list row exposed to UI and orchestration layers. Realm identity
/// and managed objects never cross the repository boundary.
struct GroupRepositoryListRecord: Equatable, Sendable {
    let primary: String
    let owner: String
    let groupJID: String
    let projection: GroupRepositoryProjection
}

/// One coherent immutable snapshot for group-list consumers.
struct GroupRepositoryListState: Equatable, Sendable {
    let activeGroups: [GroupRepositoryListRecord]
    let incomingInvites: [GroupInviteRecord]

    init(
        activeGroups: [GroupRepositoryListRecord] = [],
        incomingInvites: [GroupInviteRecord] = []
    ) {
        self.activeGroups = activeGroups
        self.incomingInvites = incomingInvites
    }
}

final class GroupRepositoryObservation {
    private var tokens: [NotificationToken] = []
    private let projectionLock = NSLock()
    private var lastProjection: GroupRepositoryProjection?

    func invalidate() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
    }

    fileprivate func retain(_ token: NotificationToken) {
        tokens.append(token)
    }

    fileprivate func publishIfChanged(
        _ projection: GroupRepositoryProjection,
        onChange: (GroupRepositoryProjection) -> Void
    ) {
        projectionLock.lock()
        let shouldPublish = lastProjection != projection
        if shouldPublish {
            lastProjection = projection
        }
        projectionLock.unlock()

        if shouldPublish {
            onChange(projection)
        }
    }

    deinit {
        invalidate()
    }
}

final class GroupRepositoryListObservation {
    private var tokens: [NotificationToken] = []
    private let stateLock = NSLock()
    private var lastState: GroupRepositoryListState?

    func invalidate() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
    }

    fileprivate func retain(_ token: NotificationToken) {
        tokens.append(token)
    }

    fileprivate func publishIfChanged(
        _ state: GroupRepositoryListState,
        onChange: (GroupRepositoryListState) -> Void
    ) {
        stateLock.lock()
        let shouldPublish = lastState != state
        if shouldPublish {
            lastState = state
        }
        stateLock.unlock()

        if shouldPublish {
            onChange(state)
        }
    }

    deinit {
        invalidate()
    }
}

final class GroupRepositoryIncomingInvitesObservation {
    private var token: NotificationToken?
    private let stateLock = NSLock()
    private var lastInvites: [GroupInviteRecord]?

    func invalidate() {
        token?.invalidate()
        token = nil
    }

    fileprivate func retain(_ token: NotificationToken) {
        self.token = token
    }

    fileprivate func publishIfChanged(
        _ invites: [GroupInviteRecord],
        onChange: ([GroupInviteRecord]) -> Void
    ) {
        stateLock.lock()
        let shouldPublish = lastInvites != invites
        if shouldPublish {
            lastInvites = invites
        }
        stateLock.unlock()

        if shouldPublish {
            onChange(invites)
        }
    }

    deinit {
        invalidate()
    }
}

extension GroupRepository {
    func projection(
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryProjection {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        let membershipItem = realm.object(
            ofType: GroupSelfMembershipStorageItem.self,
            forPrimaryKey: context.groupPrimary
        )
        let selfSubscription = subscription(from: membershipItem?.stateRaw)
        let snapshotItem = realm.object(
            ofType: GroupSnapshotStorageItem.self,
            forPrimaryKey: context.groupPrimary
        )
        let snapshot = makeSnapshot(
            snapshotItem,
            fallbackJID: context.groupJID
        )
        let members = realm.objects(GroupMemberStorageItem.self)
            .filter("groupPrimary == %@", context.groupPrimary)
            .sorted(byKeyPath: "memberID", ascending: true)
            .map(makeMember)
        let permissionSets = makePermissionSets(context: context)
        let selfMemberID = CanonicalGroupSelfIdentity.resolve(
            existingMemberID: membershipItem?.memberID,
            ownerJID: context.owner,
            members: Array(members)
        )
        let selfMember = selfMemberID.flatMap { id in
            members.first { $0.id == id }
        }
        let personalPermissions = selfMemberID.flatMap { id in
            permissionSets.first {
                $0.scope == .direct && $0.target == id
            }
        }

        return GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: snapshot,
                members: Array(members),
                permissionSets: permissionSets,
                selfSubscription: selfSubscription,
                isDeleted: snapshotItem == nil
            ),
            selfMemberID: selfMemberID,
            capabilities: GroupCapabilities.derive(
                role: selfMember?.role,
                permissionSet: personalPermissions
            )
        )
    }

    func observeProjection(
        owner: String,
        groupJID: String,
        onChange: @escaping (GroupRepositoryProjection) -> Void
    ) throws -> GroupRepositoryObservation {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        let observation = GroupRepositoryObservation()
        let emit: () -> Void = { [weak observation] in
            guard let observation,
                  let value = try? self.projection(
                    owner: context.owner,
                    groupJID: context.groupJID
                  ) else {
                return
            }
            observation.publishIfChanged(value, onChange: onChange)
        }

        let snapshotResults = realm.objects(GroupSnapshotStorageItem.self)
            .filter("primary == %@", context.groupPrimary)
        let membershipResults = realm.objects(GroupSelfMembershipStorageItem.self)
            .filter("primary == %@", context.groupPrimary)
        let memberResults = realm.objects(GroupMemberStorageItem.self)
            .filter("groupPrimary == %@", context.groupPrimary)
        let permissionSetResults = realm.objects(GroupPermissionSetStorageItem.self)
            .filter("groupPrimary == %@", context.groupPrimary)
        let permissionResults = realm.objects(GroupPermissionStorageItem.self)
            .filter("groupPrimary == %@", context.groupPrimary)

        emit()
        observation.retain(snapshotResults.observe { _ in emit() })
        observation.retain(membershipResults.observe { _ in emit() })
        observation.retain(memberResults.observe { _ in emit() })
        observation.retain(permissionSetResults.observe { _ in emit() })
        observation.retain(permissionResults.observe { _ in emit() })
        return observation
    }

    func activeGroup(
        owner: String,
        groupJID: String
    ) throws -> GroupRepositoryListRecord? {
        let context = try makeContext(owner: owner, groupJID: groupJID)
        guard realm.object(
            ofType: GroupSnapshotStorageItem.self,
            forPrimaryKey: context.groupPrimary
        ) != nil else {
            return nil
        }
        let projection = try projection(owner: context.owner, groupJID: context.groupJID)
        guard projection.state.isActive,
              isParticipating(projection) else { return nil }
        return GroupRepositoryListRecord(
            primary: context.groupPrimary,
            owner: context.owner,
            groupJID: context.groupJID,
            projection: projection
        )
    }

    func activeGroups(owners: [String]? = nil) throws -> [GroupRepositoryListRecord] {
        let normalizedOwners = normalizedListOwners(owners)
        if owners != nil, normalizedOwners?.isEmpty == true {
            return []
        }
        var snapshots = realm.objects(GroupSnapshotStorageItem.self)
        if let normalizedOwners {
            snapshots = snapshots.filter("owner IN %@", normalizedOwners)
        }

        return snapshots
            .compactMap { snapshot in
                let primary = GroupStorageKey.groupPrimary(
                    owner: snapshot.owner,
                    groupJID: snapshot.groupJID
                )
                guard snapshot.primary == primary,
                      let projection = try? self.projection(
                        owner: snapshot.owner,
                        groupJID: snapshot.groupJID
                      ),
                      projection.state.isActive,
                      self.isParticipating(projection) else {
                    return nil
                }
                return GroupRepositoryListRecord(
                    primary: primary,
                    owner: snapshot.owner,
                    groupJID: snapshot.groupJID,
                    projection: projection
                )
            }
            .sorted {
                ($0.owner, $0.groupJID, $0.primary) <
                    ($1.owner, $1.groupJID, $1.primary)
            }
    }

    func incomingInvites(owners: [String]? = nil) -> [GroupInviteRecord] {
        let normalizedOwners = normalizedListOwners(owners)
        if owners != nil, normalizedOwners?.isEmpty == true {
            return []
        }
        var inviteItems = realm.objects(GroupInviteStorageItem.self).filter(
            "directionRaw == %@",
            GroupInviteDirection.incoming.rawValue
        )
        if let normalizedOwners {
            inviteItems = inviteItems.filter("owner IN %@", normalizedOwners)
        }
        return inviteItems
            .compactMap(makeInviteRecord)
            .sorted {
                ($0.owner, $0.groupJID, $0.target, $0.primary) <
                    ($1.owner, $1.groupJID, $1.target, $1.primary)
            }
    }

    func observeIncomingInvites(
        owners: [String]? = nil,
        onChange: @escaping ([GroupInviteRecord]) -> Void
    ) -> GroupRepositoryIncomingInvitesObservation {
        let normalizedOwners = normalizedListOwners(owners)
        let observation = GroupRepositoryIncomingInvitesObservation()
        let emit: () -> Void = { [weak observation] in
            guard let observation else { return }
            observation.publishIfChanged(
                self.incomingInvites(owners: normalizedOwners),
                onChange: onChange
            )
        }
        var inviteResults = realm.objects(GroupInviteStorageItem.self).filter(
            "directionRaw == %@",
            GroupInviteDirection.incoming.rawValue
        )
        if let normalizedOwners {
            inviteResults = inviteResults.filter("owner IN %@", normalizedOwners)
        }

        emit()
        observation.retain(inviteResults.observe { _ in emit() })
        return observation
    }

    func listState(owners: [String]? = nil) throws -> GroupRepositoryListState {
        let normalizedOwners = normalizedListOwners(owners)
        if owners != nil, normalizedOwners?.isEmpty == true {
            return GroupRepositoryListState()
        }
        return GroupRepositoryListState(
            activeGroups: try activeGroups(owners: normalizedOwners),
            incomingInvites: incomingInvites(owners: normalizedOwners)
        )
    }

    func observeList(
        owners: [String]? = nil,
        onChange: @escaping (GroupRepositoryListState) -> Void
    ) throws -> GroupRepositoryListObservation {
        let normalizedOwners = normalizedListOwners(owners)
        let observation = GroupRepositoryListObservation()
        let emit: () -> Void = { [weak observation] in
            guard let observation,
                  let state = try? self.listState(owners: normalizedOwners) else {
                return
            }
            observation.publishIfChanged(state, onChange: onChange)
        }

        var snapshotResults = realm.objects(GroupSnapshotStorageItem.self)
        var membershipResults = realm.objects(GroupSelfMembershipStorageItem.self)
        var memberResults = realm.objects(GroupMemberStorageItem.self)
        var permissionSetResults = realm.objects(GroupPermissionSetStorageItem.self)
        var permissionResults = realm.objects(GroupPermissionStorageItem.self)
        var inviteResults = realm.objects(GroupInviteStorageItem.self).filter(
            "directionRaw == %@",
            GroupInviteDirection.incoming.rawValue
        )
        if let normalizedOwners {
            snapshotResults = snapshotResults.filter("owner IN %@", normalizedOwners)
            membershipResults = membershipResults.filter("owner IN %@", normalizedOwners)
            memberResults = memberResults.filter("owner IN %@", normalizedOwners)
            permissionSetResults = permissionSetResults.filter("owner IN %@", normalizedOwners)
            permissionResults = permissionResults.filter("owner IN %@", normalizedOwners)
            inviteResults = inviteResults.filter("owner IN %@", normalizedOwners)
        }

        emit()
        observation.retain(snapshotResults.observe { _ in emit() })
        observation.retain(membershipResults.observe { _ in emit() })
        observation.retain(memberResults.observe { _ in emit() })
        observation.retain(permissionSetResults.observe { _ in emit() })
        observation.retain(permissionResults.observe { _ in emit() })
        observation.retain(inviteResults.observe { _ in emit() })
        return observation
    }
}

private extension GroupRepository {
    func isParticipating(_ projection: GroupRepositoryProjection) -> Bool {
        guard let selfMemberID = projection.selfMemberID,
              let role = projection.state.member(id: selfMemberID)?.role else {
            return false
        }
        return role != .none
    }

    func normalizedListOwners(_ owners: [String]?) -> [String]? {
        owners.map {
            Array(Set($0.map(GroupStorageKey.bareJID)))
                .filter { !$0.isEmpty }
                .sorted()
        }
    }

    func subscription(from rawValue: String?) -> GroupSelfSubscription {
        switch rawValue.flatMap(GroupSelfMembershipState.init(rawValue:)) {
        case .some(.both):
            return .both
        case .some(.none):
            return .none
        case .some(.wait), nil:
            return .wait
        }
    }

    func makeSnapshot(
        _ item: GroupSnapshotStorageItem?,
        fallbackJID: String
    ) -> GroupSnapshot {
        guard let item else {
            return GroupSnapshot(jid: fallbackJID)
        }
        let avatar = makeAvatar(
            id: item.avatarID,
            mediaType: item.avatarMediaType,
            bytes: item.avatarBytes,
            width: item.avatarWidth,
            height: item.avatarHeight,
            url: item.avatarURL
        )
        let hasInfo = item.name != nil
            || item.descriptionText != nil
            || item.status != nil
            || avatar != nil
        let contacts = item.contactsPresent ? Array(item.contacts) : nil
        let domains = item.domainsPresent ? Array(item.domains) : nil

        return GroupSnapshot(
            jid: item.groupJID,
            privacy: item.privacyRaw.flatMap(GroupPrivacy.init(rawValue:)),
            parentJID: item.parentJID,
            memberCount: item.memberCount,
            localpart: item.localpart,
            info: hasInfo
                ? GroupInfo(
                    name: item.name,
                    description: item.descriptionText,
                    avatar: avatar,
                    status: item.status
                )
                : nil,
            settings: item.settingsPresent
                ? GroupSettings(
                    membership: item.membershipRaw.flatMap(GroupMembership.init(rawValue:)),
                    contacts: contacts,
                    domains: domains,
                    index: item.indexRaw.flatMap(GroupIndexVisibility.init(rawValue:)),
                    state: item.lifecycleStateRaw.flatMap(GroupLifecycleState.init(rawValue:))
                )
                : nil,
            pinnedMessageIDs: item.pinnedMessageIDsPresent
                ? Array(item.pinnedMessageIDs)
                : nil,
            presentCount: item.presentCount
        )
    }

    func makeMember(_ item: GroupMemberStorageItem) -> GroupMember {
        GroupMember(
            id: item.memberID,
            jid: item.jid,
            role: item.roleRaw.flatMap(GroupMemberRole.init(rawValue:)),
            nickname: item.nickname,
            badge: item.badge,
            avatar: makeAvatar(
                id: item.avatarID,
                mediaType: item.avatarMediaType,
                bytes: item.avatarBytes,
                width: item.avatarWidth,
                height: item.avatarHeight,
                url: item.avatarURL
            ),
            lastSeen: item.lastSeen,
            allowsPeerToPeer: item.allowsPeerToPeer
        )
    }

    func makeAvatar(
        id: String?,
        mediaType: String?,
        bytes: Int?,
        width: Int?,
        height: Int?,
        url: String?
    ) -> GroupAvatar? {
        guard id != nil
                || mediaType != nil
                || bytes != nil
                || width != nil
                || height != nil
                || url != nil else {
            return nil
        }
        return GroupAvatar(
            id: id,
            mediaType: mediaType,
            bytes: bytes,
            width: width,
            height: height,
            url: url
        )
    }

    private func makePermissionSets(context: Context) -> [GroupPermissionSet] {
        realm.objects(GroupPermissionSetStorageItem.self)
            .filter("groupPrimary == %@", context.groupPrimary)
            .sorted(byKeyPath: "primary", ascending: true)
            .compactMap { header in
                guard let scope = permissionScope(from: header.scopeRaw) else {
                    return nil
                }
                let permissions = realm.objects(GroupPermissionStorageItem.self)
                    .filter("setPrimary == %@", header.primary)
                    .sorted(byKeyPath: "name", ascending: true)
                    .map { item in
                        GroupPermission(
                            name: item.name,
                            level: item.level,
                            status: item.status,
                            seconds: self.unsigned(item.seconds),
                            expires: self.unsigned(item.expires),
                            tag: item.tag,
                            fixed: item.fixed,
                            display: item.display
                        )
                    }
                return GroupPermissionSet(
                    scope: scope,
                    target: header.targetMemberID,
                    label: header.label,
                    actor: header.actorMemberID,
                    stamp: header.stamp,
                    permissions: Array(permissions)
                )
            }
    }

    func permissionScope(from rawValue: String) -> GroupPermissionScope? {
        switch GroupPermissionStorageScope(rawValue: rawValue) {
        case .some(.personal):
            return .direct
        case .some(.defaults):
            return .defaults
        case .some(.newbies):
            return .newbies
        case nil:
            return nil
        }
    }

    func unsigned(_ value: Int64?) -> UInt64? {
        guard let value, value >= 0 else {
            return nil
        }
        return UInt64(value)
    }
}
