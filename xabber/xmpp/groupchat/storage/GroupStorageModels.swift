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
    var groupJID: String
    var direction: GroupInviteDirection
    var target: String
    var reason: String?

    init(
        groupJID: String,
        direction: GroupInviteDirection,
        target: String,
        reason: String? = nil
    ) {
        self.groupJID = groupJID
        self.direction = direction
        self.target = target
        self.reason = reason
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
    @Persisted var contacts = List<String>()
    @Persisted var domains = List<String>()
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
}
