import Foundation

enum GroupProtocolNamespace {
    static let groups = "https://xabber.com/protocol/groups"
    static let permissions = "https://xabber.com/protocol/permissions"
    static let avatarMetadata = "urn:xmpp:avatar:metadata"
}

enum GroupPrivacy: String, Equatable, Sendable {
    case publicGroup = "public"
    case incognito
}

enum GroupMembership: String, Equatable, Sendable {
    case open
    case privateGroup = "private"
}

enum GroupIndexVisibility: String, Equatable, Sendable {
    case none
    case local
    case global
}

enum GroupLifecycleState: String, Equatable, Sendable {
    case active
    case inactive
}

enum GroupMemberRole: String, Equatable, Sendable {
    case owner
    case admin
    case member
    case none
}

enum GroupPatchValue<Value>: Equatable, Sendable where Value: Equatable & Sendable {
    case absent
    case value(Value)
}

struct GroupAvatar: Equatable, Sendable {
    var id: String?
    var mediaType: String?
    var bytes: Int?
    var width: Int?
    var height: Int?
    var url: String?

    init(
        id: String? = nil,
        mediaType: String? = nil,
        bytes: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.bytes = bytes
        self.width = width
        self.height = height
        self.url = url
    }
}

struct GroupInfo: Equatable, Sendable {
    var name: String?
    var description: String?
    var avatar: GroupAvatar?
    var status: String?

    init(
        name: String? = nil,
        description: String? = nil,
        avatar: GroupAvatar? = nil,
        status: String? = nil
    ) {
        self.name = name
        self.description = description
        self.avatar = avatar
        self.status = status
    }
}

struct GroupSettings: Equatable, Sendable {
    var membership: GroupMembership?
    var contacts: [String]?
    var domains: [String]?
    var index: GroupIndexVisibility?
    var state: GroupLifecycleState?

    init(
        membership: GroupMembership? = nil,
        contacts: [String]? = nil,
        domains: [String]? = nil,
        index: GroupIndexVisibility? = nil,
        state: GroupLifecycleState? = nil
    ) {
        self.membership = membership
        self.contacts = contacts
        self.domains = domains
        self.index = index
        self.state = state
    }
}

struct GroupSnapshot: Equatable, Sendable {
    var jid: String?
    var privacy: GroupPrivacy?
    var parentJID: String?
    var memberCount: Int?
    var localpart: String?
    var info: GroupInfo?
    var settings: GroupSettings?
    var pinnedMessageIDs: [String]?
    var presentCount: Int?

    init(
        jid: String? = nil,
        privacy: GroupPrivacy? = nil,
        parentJID: String? = nil,
        memberCount: Int? = nil,
        localpart: String? = nil,
        info: GroupInfo? = nil,
        settings: GroupSettings? = nil,
        pinnedMessageIDs: [String]? = nil,
        presentCount: Int? = nil
    ) {
        self.jid = jid
        self.privacy = privacy
        self.parentJID = parentJID
        self.memberCount = memberCount
        self.localpart = localpart
        self.info = info
        self.settings = settings
        self.pinnedMessageIDs = pinnedMessageIDs
        self.presentCount = presentCount
    }
}

struct GroupInfoPatch: Equatable, Sendable {
    var name: GroupPatchValue<String?>
    var description: GroupPatchValue<String?>
    var avatar: GroupPatchValue<GroupAvatar?>
    var status: GroupPatchValue<String?>

    init(
        name: GroupPatchValue<String?> = .absent,
        description: GroupPatchValue<String?> = .absent,
        avatar: GroupPatchValue<GroupAvatar?> = .absent,
        status: GroupPatchValue<String?> = .absent
    ) {
        self.name = name
        self.description = description
        self.avatar = avatar
        self.status = status
    }
}

struct GroupSettingsPatch: Equatable, Sendable {
    var membership: GroupPatchValue<GroupMembership?>
    var contacts: GroupPatchValue<[String]?>
    var domains: GroupPatchValue<[String]?>
    var index: GroupPatchValue<GroupIndexVisibility?>
    var state: GroupPatchValue<GroupLifecycleState?>

    init(
        membership: GroupPatchValue<GroupMembership?> = .absent,
        contacts: GroupPatchValue<[String]?> = .absent,
        domains: GroupPatchValue<[String]?> = .absent,
        index: GroupPatchValue<GroupIndexVisibility?> = .absent,
        state: GroupPatchValue<GroupLifecycleState?> = .absent
    ) {
        self.membership = membership
        self.contacts = contacts
        self.domains = domains
        self.index = index
        self.state = state
    }
}

struct GroupPatch: Equatable, Sendable {
    var jid: GroupPatchValue<String?>
    var privacy: GroupPatchValue<GroupPrivacy?>
    var parentJID: GroupPatchValue<String?>
    var memberCount: GroupPatchValue<Int?>
    var localpart: GroupPatchValue<String?>
    var info: GroupPatchValue<GroupInfoPatch?>
    var settings: GroupPatchValue<GroupSettingsPatch?>
    var pinnedMessageIDs: GroupPatchValue<[String]?>
    var presentCount: GroupPatchValue<Int?>

    init(
        jid: GroupPatchValue<String?> = .absent,
        privacy: GroupPatchValue<GroupPrivacy?> = .absent,
        parentJID: GroupPatchValue<String?> = .absent,
        memberCount: GroupPatchValue<Int?> = .absent,
        localpart: GroupPatchValue<String?> = .absent,
        info: GroupPatchValue<GroupInfoPatch?> = .absent,
        settings: GroupPatchValue<GroupSettingsPatch?> = .absent,
        pinnedMessageIDs: GroupPatchValue<[String]?> = .absent,
        presentCount: GroupPatchValue<Int?> = .absent
    ) {
        self.jid = jid
        self.privacy = privacy
        self.parentJID = parentJID
        self.memberCount = memberCount
        self.localpart = localpart
        self.info = info
        self.settings = settings
        self.pinnedMessageIDs = pinnedMessageIDs
        self.presentCount = presentCount
    }
}

struct GroupMember: Equatable, Sendable {
    var id: String
    var jid: String?
    var role: GroupMemberRole?
    var nickname: String?
    var badge: String?
    var avatar: GroupAvatar?
    var lastSeen: Date?
    var allowsPeerToPeer: Bool

    init(
        id: String,
        jid: String? = nil,
        role: GroupMemberRole? = nil,
        nickname: String? = nil,
        badge: String? = nil,
        avatar: GroupAvatar? = nil,
        lastSeen: Date? = nil,
        allowsPeerToPeer: Bool = false
    ) {
        self.id = id
        self.jid = jid
        self.role = role
        self.nickname = nickname
        self.badge = badge
        self.avatar = avatar
        self.lastSeen = lastSeen
        self.allowsPeerToPeer = allowsPeerToPeer
    }
}

/// A partial, stable-ID-addressed member mutation.
///
/// The current server accepts only mutable member-card fields here. Identity,
/// role, last-seen and P2P flags are authoritative response data and therefore
/// cannot accidentally be serialized by this command model.
struct GroupMemberUpdate: Equatable, Sendable {
    var memberID: String
    var nickname: String?
    var badge: String?
    var avatar: GroupAvatar?

    init(
        memberID: String,
        nickname: String? = nil,
        badge: String? = nil,
        avatar: GroupAvatar? = nil
    ) {
        self.memberID = memberID
        self.nickname = nickname
        self.badge = badge
        self.avatar = avatar
    }
}

enum GroupInvite: Equatable, Sendable {
    case request(targetJID: String, send: Bool?, reason: String?)
    case message(groupJID: String, reason: String?, inviter: GroupMember?)
}

struct GroupPermission: Equatable, Sendable {
    var name: String
    var level: String?
    var status: Bool
    var seconds: UInt64?
    var expires: UInt64?
    var tag: String?
    var fixed: Bool
    var display: String?

    init(
        name: String,
        level: String? = nil,
        status: Bool,
        seconds: UInt64? = nil,
        expires: UInt64? = nil,
        tag: String? = nil,
        fixed: Bool = false,
        display: String? = nil
    ) {
        self.name = name
        self.level = level
        self.status = status
        self.seconds = seconds
        self.expires = expires
        self.tag = tag
        self.fixed = fixed
        self.display = display
    }
}

enum GroupPermissionScope: Equatable, Sendable {
    case direct
    case defaults
    case newbies
}

struct GroupPermissionSet: Equatable, Sendable {
    var scope: GroupPermissionScope
    var target: String?
    var label: String?
    var actor: String?
    var stamp: Date?
    var permissions: [GroupPermission]

    init(
        scope: GroupPermissionScope,
        target: String? = nil,
        label: String? = nil,
        actor: String? = nil,
        stamp: Date? = nil,
        permissions: [GroupPermission]
    ) {
        self.scope = scope
        self.target = target
        self.label = label
        self.actor = actor
        self.stamp = stamp
        self.permissions = permissions
    }
}

enum GroupSystemEventType: String, Equatable, Sendable {
    case create
    case join
    case leave
    case update
    case pinned
}

struct GroupSystemEvent: Equatable, Sendable {
    var type: GroupSystemEventType
    var user: GroupMember?

    init(type: GroupSystemEventType, user: GroupMember? = nil) {
        self.type = type
        self.user = user
    }
}
