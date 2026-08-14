import Foundation
import XMPPFramework

enum GroupProtocolCodecError: Error, Equatable {
    case unexpectedRoot(expected: String, actual: String?)
    case invalidNamespace(expected: String, actual: String?)
    case missingAttribute(element: String, attribute: String)
    case invalidAttribute(element: String, attribute: String, value: String)
    case missingElement(parent: String, child: String)
    case duplicateElement(parent: String, child: String)
    case unexpectedElement(parent: String, child: String, namespace: String?)
    case invalidText(element: String, value: String)
    case invalidJID(String)
    case ambiguousShape(String)
}

enum GroupProtocolCodec {
    static func decodeGroupSnapshot(_ element: DDXMLElement) throws -> GroupSnapshot {
        try requireRoot(element, name: "group", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["localpart", "info", "settings", "pinned", "present"],
            namespace: GroupProtocolNamespace.groups
        )

        return GroupSnapshot(
            jid: try optionalBareJIDAttribute(element, "jid"),
            privacy: try optionalEnumAttribute(element, "privacy", as: GroupPrivacy.self),
            parentJID: try optionalBareJIDAttribute(element, "parent"),
            memberCount: try optionalNonNegativeIntAttribute(element, "members"),
            localpart: try optionalUniqueChild(element, "localpart").map(text),
            info: try optionalUniqueChild(element, "info").map(decodeInfo),
            settings: try optionalUniqueChild(element, "settings").map(decodeSettings),
            pinnedMessageIDs: try optionalUniqueChild(element, "pinned").map(decodePinned),
            presentCount: try optionalUniqueChild(element, "present").map(nonNegativeIntText)
        )
    }

    static func encodeGroupSnapshot(_ snapshot: GroupSnapshot) throws -> DDXMLElement {
        let group = DDXMLElement(name: "group", xmlns: GroupProtocolNamespace.groups)
        if let jid = snapshot.jid {
            group.addAttribute(withName: "jid", stringValue: try normalizeBareJID(jid))
        }
        addAttribute("privacy", snapshot.privacy?.rawValue, to: group)
        if let parentJID = snapshot.parentJID {
            group.addAttribute(withName: "parent", stringValue: try normalizeBareJID(parentJID))
        }
        if let memberCount = snapshot.memberCount {
            guard memberCount >= 0 else {
                throw GroupProtocolCodecError.invalidAttribute(
                    element: "group", attribute: "members", value: String(memberCount)
                )
            }
            group.addAttribute(withName: "members", stringValue: String(memberCount))
        }
        addTextChild("localpart", snapshot.localpart, to: group)
        if let info = snapshot.info {
            group.addChild(try encodeInfo(info))
        }
        if let settings = snapshot.settings {
            group.addChild(try encodeSettings(settings))
        }
        if let pinnedMessageIDs = snapshot.pinnedMessageIDs {
            group.addChild(try encodePinned(pinnedMessageIDs))
        }
        if let presentCount = snapshot.presentCount {
            guard presentCount >= 0 else {
                throw GroupProtocolCodecError.invalidText(element: "present", value: String(presentCount))
            }
            group.addChild(DDXMLElement(name: "present", stringValue: String(presentCount)))
        }
        return group
    }

    static func decodeGroupPatch(_ element: DDXMLElement) throws -> GroupPatch {
        try requireRoot(element, name: "group", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["localpart", "info", "settings", "pinned", "present"],
            namespace: GroupProtocolNamespace.groups
        )

        return GroupPatch(
            jid: try patchAttribute(element, "jid", transform: normalizeBareJID),
            privacy: try patchEnumAttribute(element, "privacy", as: GroupPrivacy.self),
            parentJID: try patchAttribute(element, "parent", transform: normalizeBareJID),
            memberCount: try patchNonNegativeIntAttribute(element, "members"),
            localpart: try patchChild(element, "localpart", transform: text),
            info: try patchChild(element, "info") { try decodeInfoPatch($0) },
            settings: try patchChild(element, "settings") { try decodeSettingsPatch($0) },
            pinnedMessageIDs: try patchChild(element, "pinned", transform: decodePinned),
            presentCount: try patchChild(element, "present", transform: nonNegativeIntText)
        )
    }

    static func decodeFullMembers(_ element: DDXMLElement) throws -> [GroupMember] {
        try requireRoot(element, name: "members", namespace: GroupProtocolNamespace.groups)
        if let version = attribute(element, "version") {
            throw GroupProtocolCodecError.invalidAttribute(
                element: "members", attribute: "version", value: version
            )
        }
        if let id = attribute(element, "id") {
            throw GroupProtocolCodecError.invalidAttribute(element: "members", attribute: "id", value: id)
        }

        return try childElements(element).map { child in
            guard child.name == "user",
                  effectiveNamespace(of: child) == GroupProtocolNamespace.groups else {
                throw GroupProtocolCodecError.unexpectedElement(
                    parent: "members", child: child.name ?? "", namespace: effectiveNamespace(of: child)
                )
            }
            return try decodeMember(child)
        }
    }

    static func encodeFullMembers(_ members: [GroupMember]) throws -> DDXMLElement {
        let container = DDXMLElement(name: "members", xmlns: GroupProtocolNamespace.groups)
        for member in members {
            container.addChild(try encodeMember(member))
        }
        return container
    }

    static func encodeMemberUpdate(_ update: GroupMemberUpdate) throws -> DDXMLElement {
        guard let memberID = nonEmpty(update.memberID), memberID != "0" else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: "members",
                attribute: "id",
                value: update.memberID
            )
        }
        let members = DDXMLElement(name: "members", xmlns: GroupProtocolNamespace.groups)
        members.addAttribute(withName: "id", stringValue: memberID)
        let user = DDXMLElement(name: "user")
        user.addAttribute(withName: "id", stringValue: memberID)
        addTextChild("nickname", update.nickname, to: user)
        addTextChild("badge", update.badge, to: user)
        if let avatar = update.avatar {
            user.addChild(try encodeAvatar(avatar))
        }
        members.addChild(user)
        return members
    }

    static func decodeInvites(_ element: DDXMLElement) throws -> [String] {
        try decodeAddressList(element, rootName: "invites", allowsDomains: false)
    }

    static func decodeBlocklist(_ element: DDXMLElement) throws -> [String] {
        try decodeAddressList(element, rootName: "block", allowsDomains: true)
    }

    static func decodeMessageAuthor(_ element: DDXMLElement) throws -> GroupMember {
        try requireRoot(element, name: "x", namespace: GroupProtocolNamespace.groups)
        let children = childElements(element)
        guard children.count == 1, let user = children.first, user.name == "user" else {
            throw GroupProtocolCodecError.ambiguousShape("message x must contain exactly one direct user")
        }
        guard effectiveNamespace(of: user) == GroupProtocolNamespace.groups else {
            throw GroupProtocolCodecError.invalidNamespace(
                expected: GroupProtocolNamespace.groups, actual: effectiveNamespace(of: user)
            )
        }
        return try decodeMember(user)
    }

    static func encodeMessageAuthor(_ member: GroupMember) throws -> DDXMLElement {
        let x = DDXMLElement(name: "x", xmlns: GroupProtocolNamespace.groups)
        x.addChild(try encodeMember(member))
        return x
    }

    static func decodeSystemEvent(_ element: DDXMLElement) throws -> GroupSystemEvent {
        try requireRoot(element, name: "x", namespace: GroupProtocolNamespace.groups)
        let children = childElements(element)
        guard children.count == 1,
              let system = children.first,
              system.name == "system-message",
              effectiveNamespace(of: system) == GroupProtocolNamespace.groups else {
            throw GroupProtocolCodecError.ambiguousShape(
                "message x must contain exactly one nested system-message"
            )
        }
        guard let rawType = nonEmpty(attribute(system, "type")),
              let type = GroupSystemEventType(rawValue: rawType) else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: "system-message",
                attribute: "type",
                value: attribute(system, "type") ?? ""
            )
        }
        let nested = childElements(system)
        guard nested.count <= 1 else {
            throw GroupProtocolCodecError.ambiguousShape("system-message contains multiple actors")
        }
        let member: GroupMember?
        if let user = nested.first {
            guard user.name == "user",
                  effectiveNamespace(of: user) == GroupProtocolNamespace.groups else {
                throw GroupProtocolCodecError.unexpectedElement(
                    parent: "system-message", child: user.name ?? "", namespace: effectiveNamespace(of: user)
                )
            }
            member = try decodeMember(user)
        } else {
            member = nil
        }
        return GroupSystemEvent(type: type, user: member)
    }

    static func encodeSystemEvent(_ event: GroupSystemEvent) throws -> DDXMLElement {
        let x = DDXMLElement(name: "x", xmlns: GroupProtocolNamespace.groups)
        let system = DDXMLElement(name: "system-message")
        system.addAttribute(withName: "type", stringValue: event.type.rawValue)
        if let user = event.user {
            system.addChild(try encodeMember(user))
        }
        x.addChild(system)
        return x
    }

    static func decodeInvite(_ element: DDXMLElement) throws -> GroupInvite {
        try requireRoot(element, name: "invite", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["jid", "send", "reason", "user"],
            namespace: GroupProtocolNamespace.groups
        )

        let groupAttribute = nonEmpty(attribute(element, "jid"))
        let targetElement = try optionalUniqueChild(element, "jid")
        let sendElement = try optionalUniqueChild(element, "send")
        let reason = try optionalUniqueChild(element, "reason").map(text)
        let userElement = try optionalUniqueChild(element, "user")

        switch (groupAttribute, targetElement) {
        case let (groupJID?, nil):
            guard sendElement == nil else {
                throw GroupProtocolCodecError.ambiguousShape("invite message cannot contain send")
            }
            return .message(
                groupJID: try normalizeBareJID(groupJID),
                reason: reason,
                inviter: try userElement.map(decodeMember)
            )
        case let (nil, target?):
            guard userElement == nil else {
                throw GroupProtocolCodecError.ambiguousShape("invite request cannot contain user")
            }
            let send = try sendElement.map { try boolText($0, name: "send") }
            return .request(
                targetJID: try normalizeBareJID(text(target)),
                send: send,
                reason: reason
            )
        default:
            throw GroupProtocolCodecError.ambiguousShape(
                "invite must be either a jid attribute message or a jid child request"
            )
        }
    }

    static func encodeInvite(_ invite: GroupInvite) throws -> DDXMLElement {
        let element = DDXMLElement(name: "invite", xmlns: GroupProtocolNamespace.groups)
        switch invite {
        case let .request(targetJID, send, reason):
            element.addChild(DDXMLElement(name: "jid", stringValue: try normalizeBareJID(targetJID)))
            if let send = send {
                element.addChild(DDXMLElement(name: "send", stringValue: send ? "true" : "false"))
            }
            addTextChild("reason", reason, to: element)
        case let .message(groupJID, reason, inviter):
            element.addAttribute(withName: "jid", stringValue: try normalizeBareJID(groupJID))
            addTextChild("reason", reason, to: element)
            if let inviter = inviter {
                element.addChild(try encodeMember(inviter))
            }
        }
        return element
    }

    static func decodePermissionSet(_ element: DDXMLElement) throws -> GroupPermissionSet {
        try requireNamespace(element, GroupProtocolNamespace.permissions)

        let scope: GroupPermissionScope
        let permissionsElement: DDXMLElement
        switch element.name {
        case "permissions":
            scope = .direct
            permissionsElement = element
        case "defaults":
            scope = .defaults
            permissionsElement = try requiredSinglePermissionsChild(element)
        case "newbies":
            scope = .newbies
            permissionsElement = try requiredSinglePermissionsChild(element)
        default:
            throw GroupProtocolCodecError.unexpectedRoot(expected: "permissions/defaults/newbies", actual: element.name)
        }

        let permissions = try childElements(permissionsElement).map(decodePermission)
        return GroupPermissionSet(
            scope: scope,
            target: nonEmpty(attribute(permissionsElement, "target")),
            label: nonEmpty(attribute(permissionsElement, "label")),
            actor: nonEmpty(attribute(permissionsElement, "actor")),
            stamp: try optionalDateAttribute(permissionsElement, "stamp"),
            permissions: permissions
        )
    }

    static func encodePermissionSet(_ set: GroupPermissionSet) throws -> DDXMLElement {
        let permissions = set.scope == .direct
            ? DDXMLElement(name: "permissions", xmlns: GroupProtocolNamespace.permissions)
            : DDXMLElement(name: "permissions")
        addAttribute("target", set.target, to: permissions)
        addAttribute("label", set.label, to: permissions)
        addAttribute("actor", set.actor, to: permissions)
        if let stamp = set.stamp {
            permissions.addAttribute(withName: "stamp", stringValue: timestampString(stamp))
        }
        for permission in set.permissions {
            permissions.addChild(try encodePermission(permission))
        }

        switch set.scope {
        case .direct:
            return permissions
        case .defaults, .newbies:
            let name = set.scope == .defaults ? "defaults" : "newbies"
            let wrapper = DDXMLElement(name: name, xmlns: GroupProtocolNamespace.permissions)
            wrapper.addChild(permissions)
            return wrapper
        }
    }

    static func decodeInfo(_ element: DDXMLElement) throws -> GroupInfo {
        try requireElement(element, name: "info", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["name", "description", "avatar", "status"],
            namespace: GroupProtocolNamespace.groups
        )
        return GroupInfo(
            name: try optionalUniqueChild(element, "name").map(text),
            description: try optionalUniqueChild(element, "description").map(text),
            avatar: try optionalUniqueChild(element, "avatar").map(decodeAvatar),
            status: try optionalUniqueChild(element, "status").map(text)
        )
    }

    static func encodeInfo(_ info: GroupInfo) throws -> DDXMLElement {
        let element = DDXMLElement(name: "info", xmlns: GroupProtocolNamespace.groups)
        addTextChild("name", info.name, to: element)
        addTextChild("description", info.description, to: element)
        if let avatar = info.avatar {
            element.addChild(try encodeAvatar(avatar))
        }
        addTextChild("status", info.status, to: element)
        return element
    }

    private static func decodeInfoPatch(_ element: DDXMLElement) throws -> GroupInfoPatch {
        try requireElement(element, name: "info", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["name", "description", "avatar", "status"],
            namespace: GroupProtocolNamespace.groups
        )
        return GroupInfoPatch(
            name: try patchChild(element, "name", transform: text),
            description: try patchChild(element, "description", transform: text),
            avatar: try patchChild(element, "avatar", transform: decodeAvatar),
            status: try patchChild(element, "status", transform: text)
        )
    }

    static func decodeSettings(_ element: DDXMLElement) throws -> GroupSettings {
        try requireElement(element, name: "settings", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["membership", "contacts", "domains", "index", "state"],
            namespace: GroupProtocolNamespace.groups
        )
        return GroupSettings(
            membership: try optionalUniqueChild(element, "membership").map {
                try enumText($0, as: GroupMembership.self)
            },
            contacts: try optionalUniqueChild(element, "contacts").map(decodeContacts),
            domains: try optionalUniqueChild(element, "domains").map(decodeDomains),
            index: try optionalUniqueChild(element, "index").map {
                try enumText($0, as: GroupIndexVisibility.self)
            },
            state: try optionalUniqueChild(element, "state").map {
                try enumText($0, as: GroupLifecycleState.self)
            }
        )
    }

    static func encodeSettings(_ settings: GroupSettings) throws -> DDXMLElement {
        let element = DDXMLElement(name: "settings", xmlns: GroupProtocolNamespace.groups)
        addTextChild("membership", settings.membership?.rawValue, to: element)
        if let contacts = settings.contacts {
            let container = DDXMLElement(name: "contacts")
            for contact in contacts {
                container.addChild(DDXMLElement(name: "contact", stringValue: try normalizeBareJID(contact)))
            }
            element.addChild(container)
        }
        if let domains = settings.domains {
            let container = DDXMLElement(name: "domains")
            for domain in domains {
                container.addChild(DDXMLElement(name: "domain", stringValue: try normalizeDomain(domain)))
            }
            element.addChild(container)
        }
        addTextChild("index", settings.index?.rawValue, to: element)
        addTextChild("state", settings.state?.rawValue, to: element)
        return element
    }

    private static func decodeSettingsPatch(_ element: DDXMLElement) throws -> GroupSettingsPatch {
        try requireElement(element, name: "settings", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["membership", "contacts", "domains", "index", "state"],
            namespace: GroupProtocolNamespace.groups
        )
        return GroupSettingsPatch(
            membership: try patchChild(element, "membership") {
                try enumText($0, as: GroupMembership.self)
            },
            contacts: try patchChild(element, "contacts", transform: decodeContacts),
            domains: try patchChild(element, "domains", transform: decodeDomains),
            index: try patchChild(element, "index") {
                try enumText($0, as: GroupIndexVisibility.self)
            },
            state: try patchChild(element, "state") {
                try enumText($0, as: GroupLifecycleState.self)
            }
        )
    }

    private static func decodeContacts(_ element: DDXMLElement) throws -> [String] {
        try requireElement(element, name: "contacts", namespace: GroupProtocolNamespace.groups)
        return try childElements(element).map { child in
            try requireElement(child, name: "contact", namespace: GroupProtocolNamespace.groups)
            return try normalizeBareJID(text(child))
        }
    }

    private static func decodeDomains(_ element: DDXMLElement) throws -> [String] {
        try requireElement(element, name: "domains", namespace: GroupProtocolNamespace.groups)
        return try childElements(element).map { child in
            try requireElement(child, name: "domain", namespace: GroupProtocolNamespace.groups)
            return try normalizeDomain(text(child))
        }
    }

    private static func decodePinned(_ element: DDXMLElement) throws -> [String] {
        try requireElement(element, name: "pinned", namespace: GroupProtocolNamespace.groups)
        return try childElements(element).map { child in
            try requireElement(child, name: "pinned-message", namespace: GroupProtocolNamespace.groups)
            guard let id = nonEmpty(attribute(child, "id")) else {
                throw GroupProtocolCodecError.missingAttribute(element: "pinned-message", attribute: "id")
            }
            if let status = nonEmpty(attribute(child, "status")), status != "pinned" {
                throw GroupProtocolCodecError.invalidAttribute(
                    element: "pinned-message", attribute: "status", value: status
                )
            }
            return id
        }
    }

    private static func encodePinned(_ ids: [String]) throws -> DDXMLElement {
        let pinned = DDXMLElement(name: "pinned")
        for id in ids {
            guard let value = nonEmpty(id) else {
                throw GroupProtocolCodecError.invalidAttribute(
                    element: "pinned-message", attribute: "id", value: id
                )
            }
            let message = DDXMLElement(name: "pinned-message")
            message.addAttribute(withName: "id", stringValue: value)
            pinned.addChild(message)
        }
        return pinned
    }

    static func decodeMember(_ element: DDXMLElement) throws -> GroupMember {
        try requireElement(element, name: "user", namespace: GroupProtocolNamespace.groups)
        try requireOnlyChildren(
            element,
            names: ["jid", "role", "nickname", "badge", "avatar", "last", "allow-p2p"],
            namespace: GroupProtocolNamespace.groups
        )
        guard let id = nonEmpty(attribute(element, "id")) else {
            throw GroupProtocolCodecError.missingAttribute(element: "user", attribute: "id")
        }
        return GroupMember(
            id: id,
            jid: try optionalUniqueChild(element, "jid").map { try normalizeBareJID(text($0)) },
            role: try optionalUniqueChild(element, "role").map {
                try enumText($0, as: GroupMemberRole.self)
            },
            nickname: try optionalUniqueChild(element, "nickname").map(text),
            badge: try optionalUniqueChild(element, "badge").map(text),
            avatar: try optionalUniqueChild(element, "avatar").map(decodeAvatar),
            lastSeen: try optionalUniqueChild(element, "last").map { try timestamp(text($0), element: "last") },
            allowsPeerToPeer: try optionalUniqueChild(element, "allow-p2p") != nil
        )
    }

    private static func encodeMember(_ member: GroupMember) throws -> DDXMLElement {
        guard let id = nonEmpty(member.id) else {
            throw GroupProtocolCodecError.invalidAttribute(element: "user", attribute: "id", value: member.id)
        }
        let element = DDXMLElement(name: "user")
        element.addAttribute(withName: "id", stringValue: id)
        if let jid = member.jid {
            element.addChild(DDXMLElement(name: "jid", stringValue: try normalizeBareJID(jid)))
        }
        addTextChild("role", member.role?.rawValue, to: element)
        addTextChild("nickname", member.nickname, to: element)
        addTextChild("badge", member.badge, to: element)
        if let avatar = member.avatar {
            element.addChild(try encodeAvatar(avatar))
        }
        if let lastSeen = member.lastSeen {
            element.addChild(DDXMLElement(name: "last", stringValue: timestampString(lastSeen)))
        }
        if member.allowsPeerToPeer {
            element.addChild(DDXMLElement(name: "allow-p2p"))
        }
        return element
    }

    private static func decodeAvatar(_ element: DDXMLElement) throws -> GroupAvatar {
        try requireElement(element, name: "avatar", namespace: GroupProtocolNamespace.groups)
        let children = childElements(element)
        var result = GroupAvatar()
        for child in children {
            switch (child.name, effectiveNamespace(of: child)) {
            case ("info", GroupProtocolNamespace.avatarMetadata):
                if result.id != nil || result.mediaType != nil || result.bytes != nil || result.url != nil {
                    throw GroupProtocolCodecError.duplicateElement(parent: "avatar", child: "info")
                }
                guard let id = nonEmpty(attribute(child, "id")) else {
                    throw GroupProtocolCodecError.missingAttribute(element: "info", attribute: "id")
                }
                guard let mediaType = nonEmpty(attribute(child, "type")) else {
                    throw GroupProtocolCodecError.missingAttribute(element: "info", attribute: "type")
                }
                guard let bytes = try optionalNonNegativeIntAttribute(child, "bytes") else {
                    throw GroupProtocolCodecError.missingAttribute(element: "info", attribute: "bytes")
                }
                result.id = id
                result.mediaType = mediaType
                result.bytes = bytes
                result.width = try optionalNonNegativeIntAttribute(child, "width")
                result.height = try optionalNonNegativeIntAttribute(child, "height")
                result.url = nonEmpty(attribute(child, "url"))
            default:
                throw GroupProtocolCodecError.unexpectedElement(
                    parent: "avatar", child: child.name ?? "", namespace: effectiveNamespace(of: child)
                )
            }
        }
        return result
    }

    private static func encodeAvatar(_ avatar: GroupAvatar) throws -> DDXMLElement {
        let element = DDXMLElement(name: "avatar")
        guard let id = nonEmpty(avatar.id) else {
            throw GroupProtocolCodecError.missingAttribute(element: "info", attribute: "id")
        }
        guard let mediaType = nonEmpty(avatar.mediaType) else {
            throw GroupProtocolCodecError.missingAttribute(element: "info", attribute: "type")
        }
        guard let bytes = avatar.bytes else {
            throw GroupProtocolCodecError.missingAttribute(element: "info", attribute: "bytes")
        }
        let info = DDXMLElement(name: "info", xmlns: GroupProtocolNamespace.avatarMetadata)
        addAttribute("id", id, to: info)
        addAttribute("type", mediaType, to: info)
        try addNonNegativeAttribute("bytes", bytes, to: info)
        try addNonNegativeAttribute("width", avatar.width, to: info)
        try addNonNegativeAttribute("height", avatar.height, to: info)
        addAttribute("url", avatar.url, to: info)
        element.addChild(info)
        return element
    }

    private static func decodePermission(_ element: DDXMLElement) throws -> GroupPermission {
        try requireElement(element, name: "permission", namespace: GroupProtocolNamespace.permissions)
        guard childElements(element).isEmpty else {
            throw GroupProtocolCodecError.unexpectedElement(
                parent: "permission",
                child: childElements(element).first?.name ?? "",
                namespace: childElements(element).first.flatMap(effectiveNamespace)
            )
        }
        guard let name = nonEmpty(attribute(element, "name")) else {
            throw GroupProtocolCodecError.missingAttribute(element: "permission", attribute: "name")
        }
        guard let rawStatus = nonEmpty(attribute(element, "status")) else {
            throw GroupProtocolCodecError.missingAttribute(element: "permission", attribute: "status")
        }
        let status = try bool(rawStatus, element: "permission", attribute: "status")
        let seconds = try optionalUInt64Attribute(element, "seconds")
        let expires = try optionalUInt64Attribute(element, "expires")
        guard seconds == nil || expires == nil else {
            throw GroupProtocolCodecError.ambiguousShape(
                "permission cannot contain both seconds and expires"
            )
        }
        return GroupPermission(
            name: name,
            level: nonEmpty(attribute(element, "level")),
            status: status,
            seconds: seconds,
            expires: expires,
            tag: nonEmpty(attribute(element, "tag")),
            fixed: try attribute(element, "fixed").map {
                try bool($0, element: "permission", attribute: "fixed")
            } ?? false,
            display: nonEmpty(attribute(element, "display"))
        )
    }

    private static func encodePermission(_ permission: GroupPermission) throws -> DDXMLElement {
        guard let name = nonEmpty(permission.name) else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: "permission", attribute: "name", value: permission.name
            )
        }
        guard permission.seconds == nil || permission.expires == nil else {
            throw GroupProtocolCodecError.ambiguousShape(
                "permission cannot contain both seconds and expires"
            )
        }
        let element = DDXMLElement(name: "permission")
        element.addAttribute(withName: "name", stringValue: name)
        addAttribute("level", permission.level, to: element)
        element.addAttribute(withName: "status", stringValue: permission.status ? "true" : "false")
        if let seconds = permission.seconds {
            element.addAttribute(withName: "seconds", stringValue: String(seconds))
        }
        if let expires = permission.expires {
            element.addAttribute(withName: "expires", stringValue: String(expires))
        }
        addAttribute("tag", permission.tag, to: element)
        if permission.fixed {
            element.addAttribute(withName: "fixed", stringValue: "true")
        }
        addAttribute("display", permission.display, to: element)
        return element
    }

    private static func requiredSinglePermissionsChild(_ wrapper: DDXMLElement) throws -> DDXMLElement {
        let children = childElements(wrapper)
        guard children.count == 1, let child = children.first, child.name == "permissions" else {
            if children.isEmpty {
                throw GroupProtocolCodecError.missingElement(parent: wrapper.name ?? "", child: "permissions")
            }
            throw GroupProtocolCodecError.ambiguousShape(
                "\(wrapper.name ?? "permission wrapper") must contain exactly one permissions element"
            )
        }
        try requireNamespace(child, GroupProtocolNamespace.permissions)
        return child
    }

    private static func decodeAddressList(
        _ element: DDXMLElement,
        rootName: String,
        allowsDomains: Bool
    ) throws -> [String] {
        try requireRoot(
            element,
            name: rootName,
            namespace: GroupProtocolNamespace.groups
        )
        return try childElements(element).map { child in
            try requireElement(
                child,
                name: "jid",
                namespace: GroupProtocolNamespace.groups
            )
            guard childElements(child).isEmpty else {
                throw GroupProtocolCodecError.unexpectedElement(
                    parent: "jid",
                    child: childElements(child).first?.name ?? "",
                    namespace: childElements(child).first.flatMap(effectiveNamespace)
                )
            }
            let raw = text(child)
            if allowsDomains, !raw.contains("@") {
                return try normalizeDomain(raw)
            }
            return try normalizeBareJID(raw)
        }
    }

    private static func requireRoot(
        _ element: DDXMLElement,
        name: String,
        namespace: String
    ) throws {
        guard element.name == name else {
            throw GroupProtocolCodecError.unexpectedRoot(expected: name, actual: element.name)
        }
        try requireNamespace(element, namespace)
    }

    private static func requireElement(
        _ element: DDXMLElement,
        name: String,
        namespace: String
    ) throws {
        guard element.name == name else {
            throw GroupProtocolCodecError.unexpectedElement(
                parent: element.parent?.name ?? "",
                child: element.name ?? "",
                namespace: effectiveNamespace(of: element)
            )
        }
        try requireNamespace(element, namespace)
    }

    private static func requireNamespace(_ element: DDXMLElement, _ namespace: String) throws {
        let actual = effectiveNamespace(of: element)
        guard actual == namespace else {
            throw GroupProtocolCodecError.invalidNamespace(expected: namespace, actual: actual)
        }
    }

    /// KissXML leaves `xmlns()` nil on programmatically-created children even
    /// though their serialized XML inherits the nearest default namespace.
    private static func effectiveNamespace(of element: DDXMLElement) -> String? {
        var current: DDXMLElement? = element
        while let candidate = current {
            if let namespace = candidate.xmlns() {
                return namespace
            }
            current = candidate.parent as? DDXMLElement
        }
        return nil
    }

    private static func requireOnlyChildren(
        _ element: DDXMLElement,
        names: Set<String>,
        namespace: String
    ) throws {
        var counts: [String: Int] = [:]
        for child in childElements(element) {
            guard let name = child.name,
                  names.contains(name),
                  effectiveNamespace(of: child) == namespace else {
                throw GroupProtocolCodecError.unexpectedElement(
                    parent: element.name ?? "",
                    child: child.name ?? "",
                    namespace: effectiveNamespace(of: child)
                )
            }
            counts[name, default: 0] += 1
            if counts[name, default: 0] > 1 {
                throw GroupProtocolCodecError.duplicateElement(parent: element.name ?? "", child: name)
            }
        }
    }

    private static func childElements(_ element: DDXMLElement) -> [DDXMLElement] {
        element.children?.compactMap { $0 as? DDXMLElement } ?? []
    }

    private static func optionalUniqueChild(
        _ element: DDXMLElement,
        _ name: String
    ) throws -> DDXMLElement? {
        let matches = childElements(element).filter {
            $0.name == name && effectiveNamespace(of: $0) == GroupProtocolNamespace.groups
        }
        guard matches.count <= 1 else {
            throw GroupProtocolCodecError.duplicateElement(parent: element.name ?? "", child: name)
        }
        return matches.first
    }

    private static func patchChild<T: Equatable & Sendable>(
        _ element: DDXMLElement,
        _ name: String,
        transform: (DDXMLElement) throws -> T
    ) throws -> GroupPatchValue<T?> {
        guard let child = try optionalUniqueChild(element, name) else {
            return .absent
        }
        return .value(try transform(child))
    }

    private static func patchAttribute<T: Equatable & Sendable>(
        _ element: DDXMLElement,
        _ name: String,
        transform: (String) throws -> T
    ) throws -> GroupPatchValue<T?> {
        guard let raw = attribute(element, name) else { return .absent }
        return .value(try transform(raw))
    }

    private static func patchEnumAttribute<T: RawRepresentable & Equatable & Sendable>(
        _ element: DDXMLElement,
        _ name: String,
        as type: T.Type
    ) throws -> GroupPatchValue<T?> where T.RawValue == String {
        try patchAttribute(element, name) { raw in
            guard let result = T(rawValue: raw) else {
                throw GroupProtocolCodecError.invalidAttribute(
                    element: element.name ?? "", attribute: name, value: raw
                )
            }
            return result
        }
    }

    private static func patchNonNegativeIntAttribute(
        _ element: DDXMLElement,
        _ name: String
    ) throws -> GroupPatchValue<Int?> {
        try patchAttribute(element, name) { raw in
            guard let value = Int(raw), value >= 0 else {
                throw GroupProtocolCodecError.invalidAttribute(
                    element: element.name ?? "", attribute: name, value: raw
                )
            }
            return value
        }
    }

    private static func optionalEnumAttribute<T: RawRepresentable>(
        _ element: DDXMLElement,
        _ name: String,
        as type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard let raw = attribute(element, name) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: element.name ?? "", attribute: name, value: raw
            )
        }
        return value
    }

    private static func optionalBareJIDAttribute(
        _ element: DDXMLElement,
        _ name: String
    ) throws -> String? {
        guard let raw = attribute(element, name) else { return nil }
        return try normalizeBareJID(raw)
    }

    private static func optionalNonNegativeIntAttribute(
        _ element: DDXMLElement,
        _ name: String
    ) throws -> Int? {
        guard let raw = attribute(element, name) else { return nil }
        guard let value = Int(raw), value >= 0 else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: element.name ?? "", attribute: name, value: raw
            )
        }
        return value
    }

    private static func optionalUInt64Attribute(
        _ element: DDXMLElement,
        _ name: String
    ) throws -> UInt64? {
        guard let raw = attribute(element, name) else { return nil }
        guard let value = UInt64(raw) else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: element.name ?? "", attribute: name, value: raw
            )
        }
        return value
    }

    private static func optionalDateAttribute(
        _ element: DDXMLElement,
        _ name: String
    ) throws -> Date? {
        guard let raw = attribute(element, name) else { return nil }
        return try timestamp(raw, element: element.name ?? "")
    }

    private static func enumText<T: RawRepresentable>(
        _ element: DDXMLElement,
        as type: T.Type
    ) throws -> T where T.RawValue == String {
        let raw = text(element)
        guard let value = T(rawValue: raw) else {
            throw GroupProtocolCodecError.invalidText(element: element.name ?? "", value: raw)
        }
        return value
    }

    private static func nonNegativeIntText(_ element: DDXMLElement) throws -> Int {
        let raw = text(element)
        guard let result = Int(raw), result >= 0 else {
            throw GroupProtocolCodecError.invalidText(element: element.name ?? "", value: raw)
        }
        return result
    }

    private static func boolText(_ element: DDXMLElement, name: String) throws -> Bool {
        try bool(text(element), element: name, attribute: "text")
    }

    private static func bool(_ raw: String, element: String, attribute: String) throws -> Bool {
        switch raw {
        case "true", "1": return true
        case "false", "0": return false
        default:
            throw GroupProtocolCodecError.invalidAttribute(
                element: element, attribute: attribute, value: raw
            )
        }
    }

    private static func timestamp(_ raw: String, element: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw GroupProtocolCodecError.invalidText(element: element, value: raw)
        }
        return date
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func normalizeBareJID(_ raw: String) throws -> String {
        guard let value = nonEmpty(raw),
              let jid = XMPPJID(string: value),
              jid.user != nil,
              !jid.domain.isEmpty,
              !jid.bare.isEmpty else {
            throw GroupProtocolCodecError.invalidJID(raw)
        }
        return jid.bare.lowercased()
    }

    private static func normalizeDomain(_ raw: String) throws -> String {
        guard let value = nonEmpty(raw)?.lowercased(),
              !value.contains("@"),
              !value.contains("/"),
              XMPPJID(string: value)?.isServer == true else {
            throw GroupProtocolCodecError.invalidJID(raw)
        }
        return value
    }

    private static func text(_ element: DDXMLElement) -> String {
        element.stringValue ?? ""
    }

    private static func attribute(_ element: DDXMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func addAttribute(_ name: String, _ value: String?, to element: DDXMLElement) {
        if let value = value {
            element.addAttribute(withName: name, stringValue: value)
        }
    }

    private static func addTextChild(_ name: String, _ value: String?, to element: DDXMLElement) {
        if let value = value {
            element.addChild(DDXMLElement(name: name, stringValue: value))
        }
    }

    private static func addNonNegativeAttribute(
        _ name: String,
        _ value: Int?,
        to element: DDXMLElement
    ) throws {
        guard let value = value else { return }
        guard value >= 0 else {
            throw GroupProtocolCodecError.invalidAttribute(
                element: element.name ?? "", attribute: name, value: String(value)
            )
        }
        element.addAttribute(withName: name, stringValue: String(value))
    }
}
