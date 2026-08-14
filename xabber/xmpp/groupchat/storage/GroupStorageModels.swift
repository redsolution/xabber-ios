import Foundation
import RealmSwift

enum GroupStorageKey {
    private static let separator = "|"

    static func bareJID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? trimmed
        return bare.lowercased()
    }

    static func groupPrimary(owner: String, groupJID: String) -> String {
        join([bareJID(owner), bareJID(groupJID)])
    }

    static func memberPrimary(
        owner: String,
        groupJID: String,
        memberID: String
    ) -> String {
        join([bareJID(owner), bareJID(groupJID), memberID])
    }

    static func permissionSetPrimary(
        owner: String,
        groupJID: String,
        scope: GroupPermissionStorageScope,
        targetMemberID: String?
    ) -> String {
        join([
            bareJID(owner),
            bareJID(groupJID),
            scope.rawValue,
            targetMemberID ?? ""
        ])
    }

    static func permissionPrimary(setPrimary: String, name: String) -> String {
        join([setPrimary, name])
    }

    static func invitePrimary(
        owner: String,
        groupJID: String,
        direction: GroupInviteDirection,
        target: String
    ) -> String {
        join([bareJID(owner), bareJID(groupJID), direction.rawValue, target])
    }

    private static func join(_ components: [String]) -> String {
        components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: separator)
    }
}

enum GroupSelfMembershipState: String, Equatable, Sendable {
    case wait
    case both
    case none
}

enum GroupPermissionStorageScope: String, Equatable, Sendable {
    case personal
    case defaults
    case newbies
}

enum GroupInviteDirection: String, Equatable, Sendable {
    case incoming
    case outgoing
}

struct GroupInviteRecord: Equatable, Sendable {
    var primary: String
    var owner: String
    var groupJID: String
    var direction: GroupInviteDirection
    var target: String
    var reason: String?
    var inviter: GroupMember?
    var preview: GroupSnapshot?

    init(
        primary: String = "",
        owner: String = "",
        groupJID: String,
        direction: GroupInviteDirection,
        target: String,
        reason: String? = nil,
        inviter: GroupMember? = nil,
        preview: GroupSnapshot? = nil
    ) {
        self.primary = primary
        self.owner = owner
        self.groupJID = groupJID
        self.direction = direction
        self.target = target
        self.reason = reason
        self.inviter = inviter
        self.preview = preview
    }
}

final class GroupSnapshotStorageItem: Object {
    @Persisted(primaryKey: true) var primary = ""
    @Persisted(indexed: true) var owner = ""
    @Persisted(indexed: true) var groupJID = ""

    @Persisted var privacyRaw: String?
    @Persisted var parentJID: String?
    @Persisted var memberCount: Int?
    @Persisted var presentCount: Int?
    @Persisted var localpart: String?

    @Persisted var name: String?
    @Persisted var descriptionText: String?
    @Persisted var status: String?

    @Persisted var avatarID: String?
    @Persisted var avatarMediaType: String?
    @Persisted var avatarBytes: Int?
    @Persisted var avatarWidth: Int?
    @Persisted var avatarHeight: Int?
    @Persisted var avatarURL: String?

    @Persisted var membershipRaw: String?
    @Persisted var indexRaw: String?
    @Persisted var lifecycleStateRaw: String?
    @Persisted var settingsPresent = false
    @Persisted var contactsPresent = false
    @Persisted var domainsPresent = false
    @Persisted var contacts = List<String>()
    @Persisted var domains = List<String>()
    @Persisted var pinnedMessageIDsPresent = false
    @Persisted var pinnedMessageIDs = List<String>()
}

final class GroupSelfMembershipStorageItem: Object {
    @Persisted(primaryKey: true) var primary = ""
    @Persisted(indexed: true) var owner = ""
    @Persisted(indexed: true) var groupJID = ""
    @Persisted var stateRaw = GroupSelfMembershipState.none.rawValue
    @Persisted var memberID: String?
}

final class GroupMemberStorageItem: Object {
    @Persisted(primaryKey: true) var primary = ""
    @Persisted(indexed: true) var groupPrimary = ""
    @Persisted(indexed: true) var owner = ""
    @Persisted(indexed: true) var groupJID = ""
    @Persisted(indexed: true) var memberID = ""

    @Persisted var jid: String?
    @Persisted var roleRaw: String?
    @Persisted var nickname: String?
    @Persisted var badge: String?
    @Persisted var lastSeen: Date?
    @Persisted var allowsPeerToPeer = false

    @Persisted var avatarID: String?
    @Persisted var avatarMediaType: String?
    @Persisted var avatarBytes: Int?
    @Persisted var avatarWidth: Int?
    @Persisted var avatarHeight: Int?
    @Persisted var avatarURL: String?
}

final class GroupPermissionSetStorageItem: Object {
    @Persisted(primaryKey: true) var primary = ""
    @Persisted(indexed: true) var groupPrimary = ""
    @Persisted(indexed: true) var owner = ""
    @Persisted(indexed: true) var groupJID = ""
    @Persisted(indexed: true) var scopeRaw = ""
    @Persisted(indexed: true) var targetMemberID: String?
    @Persisted var label: String?
    @Persisted var actorMemberID: String?
    @Persisted var stamp: Date?
}

final class GroupPermissionStorageItem: Object {
    @Persisted(primaryKey: true) var primary = ""
    @Persisted(indexed: true) var groupPrimary = ""
    @Persisted(indexed: true) var setPrimary = ""
    @Persisted(indexed: true) var owner = ""
    @Persisted(indexed: true) var groupJID = ""
    @Persisted(indexed: true) var scopeRaw = ""
    @Persisted(indexed: true) var targetMemberID: String?
    @Persisted(indexed: true) var name = ""

    @Persisted var level: String?
    @Persisted var status = false
    @Persisted var seconds: Int64?
    @Persisted var expires: Int64?
    @Persisted var tag: String?
    @Persisted var fixed = false
    @Persisted var display: String?
}

final class GroupInviteStorageItem: Object {
    @Persisted(primaryKey: true) var primary = ""
    @Persisted(indexed: true) var groupPrimary = ""
    @Persisted(indexed: true) var owner = ""
    @Persisted(indexed: true) var groupJID = ""
    @Persisted(indexed: true) var directionRaw = ""
    @Persisted(indexed: true) var target = ""
    @Persisted var reason: String?

    // The invite preview is intentionally embedded into the invite row. It is
    // presentation-only and must never be promoted to authoritative group or
    // member storage before membership becomes `both`.
    @Persisted var inviterID: String?
    @Persisted var inviterJID: String?
    @Persisted var inviterRoleRaw: String?
    @Persisted var inviterNickname: String?
    @Persisted var inviterBadge: String?
    @Persisted var inviterLastSeen: Date?
    @Persisted var inviterAllowsPeerToPeer = false
    @Persisted var inviterAvatarID: String?
    @Persisted var inviterAvatarMediaType: String?
    @Persisted var inviterAvatarBytes: Int?
    @Persisted var inviterAvatarWidth: Int?
    @Persisted var inviterAvatarHeight: Int?
    @Persisted var inviterAvatarURL: String?

    @Persisted var previewPresent = false
    @Persisted var previewPrivacyRaw: String?
    @Persisted var previewParentJID: String?
    @Persisted var previewMemberCount: Int?
    @Persisted var previewPresentCount: Int?
    @Persisted var previewLocalpart: String?
    @Persisted var previewInfoPresent = false
    @Persisted var previewName: String?
    @Persisted var previewDescriptionText: String?
    @Persisted var previewStatus: String?
    @Persisted var previewAvatarID: String?
    @Persisted var previewAvatarMediaType: String?
    @Persisted var previewAvatarBytes: Int?
    @Persisted var previewAvatarWidth: Int?
    @Persisted var previewAvatarHeight: Int?
    @Persisted var previewAvatarURL: String?
    @Persisted var previewSettingsPresent = false
    @Persisted var previewMembershipRaw: String?
    @Persisted var previewIndexRaw: String?
    @Persisted var previewLifecycleStateRaw: String?
    @Persisted var previewContactsPresent = false
    @Persisted var previewDomainsPresent = false
    @Persisted var previewContacts = List<String>()
    @Persisted var previewDomains = List<String>()
    @Persisted var previewPinnedMessageIDsPresent = false
    @Persisted var previewPinnedMessageIDs = List<String>()
}
