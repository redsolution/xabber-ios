import Foundation

enum CanonicalGroupSelfIdentity {
    private static let createdOwnerPrefix = "local-created-owner:"

    static func provisionalCreatedOwner(ownerJID: String) -> GroupMember {
        let owner = GroupStorageKey.bareJID(ownerJID)
        return GroupMember(
            id: createdOwnerPrefix + owner,
            jid: owner,
            role: .owner,
            nickname: owner
        )
    }

    static func resolve(
        existingMemberID: String?,
        ownerJID: String,
        members: [GroupMember]
    ) -> String? {
        if let existingMemberID,
           !existingMemberID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           members.contains(where: { $0.id == existingMemberID }) {
            return existingMemberID
        }
        let owner = GroupStorageKey.bareJID(ownerJID)
        if let matchedByJID = members.first(where: {
            $0.jid.map(GroupStorageKey.bareJID) == owner
        }) {
            return matchedByJID.id
        }
        if existingMemberID?.hasPrefix(createdOwnerPrefix) == true {
            let owners = members.filter { $0.role == .owner }
            if owners.count == 1 {
                return owners[0].id
            }
        }
        return nil
    }

    static func attachingOwnerJID(
        to members: [GroupMember],
        selfMemberID: String?,
        ownerJID: String
    ) -> [GroupMember] {
        guard let selfMemberID else { return members }
        let owner = GroupStorageKey.bareJID(ownerJID)
        return members.map { member in
            guard member.id == selfMemberID, member.jid == nil else {
                return member
            }
            var result = member
            result.jid = owner
            return result
        }
    }
}

struct GroupCapabilities: Equatable, Sendable {
    let sendMessages: Bool
    let sendMedia: Bool
    let addMembers: Bool
    let pinMessages: Bool
    let changeGroupInfo: Bool
    let changeGroupSettings: Bool
    let changeUserInfo: Bool
    let deleteMessages: Bool
    let changePermissions: Bool
    let changeDefaultPermissions: Bool
    let blockUsers: Bool
    let createAdmins: Bool

    var allEnabled: Bool {
        capabilityValues.allSatisfy { $0 }
    }

    var anyEnabled: Bool {
        capabilityValues.contains(true)
    }

    static func derive(
        role: GroupMemberRole?,
        permissionSet: GroupPermissionSet?
    ) -> GroupCapabilities {
        derive(
            role: role,
            permissions: permissionSet?.permissions ?? []
        )
    }
}

private extension GroupCapabilities {
    enum PermissionName {
        static let sendMessages = "send-messages"
        static let sendMedia = "send-media"
        static let addMembers = "add-members"
        static let pinMessages = "pin-messages"
        static let changeGroupInfo = "change-group-info"
        static let changeGroupSettings = "change-group-settings"
        static let changeUserInfo = "change-user-info"
        static let deleteMessages = "delete-messages"
        static let changePermissions = "change-permissions"
        static let changeDefaultPermissions = "change-default-permissions"
        static let blockUsers = "block-users"
        static let createAdmins = "create-admins"
    }

    static let disabled = GroupCapabilities(
        sendMessages: false,
        sendMedia: false,
        addMembers: false,
        pinMessages: false,
        changeGroupInfo: false,
        changeGroupSettings: false,
        changeUserInfo: false,
        deleteMessages: false,
        changePermissions: false,
        changeDefaultPermissions: false,
        blockUsers: false,
        createAdmins: false
    )

    static let enabled = GroupCapabilities(
        sendMessages: true,
        sendMedia: true,
        addMembers: true,
        pinMessages: true,
        changeGroupInfo: true,
        changeGroupSettings: true,
        changeUserInfo: true,
        deleteMessages: true,
        changePermissions: true,
        changeDefaultPermissions: true,
        blockUsers: true,
        createAdmins: true
    )

    var capabilityValues: [Bool] {
        [
            sendMessages,
            sendMedia,
            addMembers,
            pinMessages,
            changeGroupInfo,
            changeGroupSettings,
            changeUserInfo,
            deleteMessages,
            changePermissions,
            changeDefaultPermissions,
            blockUsers,
            createAdmins
        ]
    }

    static func derive(
        role: GroupMemberRole?,
        permissions: [GroupPermission]
    ) -> GroupCapabilities {
        switch role {
        case .some(.owner):
            // Owner is a role implication, not a synthetic permission record.
            return .enabled

        case .some(.admin):
            return GroupCapabilities(
                sendMessages: true,
                sendMedia: true,
                addMembers: true,
                pinMessages: true,
                changeGroupInfo: true,
                changeGroupSettings: status(
                    PermissionName.changeGroupSettings,
                    level: "admin",
                    in: permissions
                ),
                changeUserInfo: status(
                    PermissionName.changeUserInfo,
                    level: "admin",
                    in: permissions
                ),
                deleteMessages: status(
                    PermissionName.deleteMessages,
                    level: "admin",
                    in: permissions
                ),
                changePermissions: status(
                    PermissionName.changePermissions,
                    level: "admin",
                    in: permissions
                ),
                changeDefaultPermissions: status(
                    PermissionName.changeDefaultPermissions,
                    level: "admin",
                    in: permissions
                ),
                blockUsers: status(
                    PermissionName.blockUsers,
                    level: "admin",
                    in: permissions
                ),
                createAdmins: status(
                    PermissionName.createAdmins,
                    level: "admin",
                    in: permissions
                )
            )

        case .some(.member):
            return GroupCapabilities(
                sendMessages: status(
                    PermissionName.sendMessages,
                    level: "member",
                    in: permissions
                ),
                sendMedia: status(
                    PermissionName.sendMedia,
                    level: "member",
                    in: permissions
                ),
                addMembers: status(
                    PermissionName.addMembers,
                    level: "member",
                    in: permissions
                ),
                pinMessages: status(
                    PermissionName.pinMessages,
                    level: "member",
                    in: permissions
                ),
                changeGroupInfo: status(
                    PermissionName.changeGroupInfo,
                    level: "member",
                    in: permissions
                ),
                changeGroupSettings: false,
                changeUserInfo: false,
                deleteMessages: false,
                changePermissions: false,
                changeDefaultPermissions: false,
                blockUsers: false,
                createAdmins: false
            )

        case .some(.none), nil:
            return .disabled
        }
    }

    static func status(
        _ name: String,
        level: String,
        in permissions: [GroupPermission]
    ) -> Bool {
        permissions.last(where: {
            $0.name == name && ($0.level == nil || $0.level == level)
        })?.status ?? false
    }
}
