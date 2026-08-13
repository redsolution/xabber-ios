import Foundation
import XMPPFramework

enum GroupCommand: Equatable, Sendable {
    case create(GroupSnapshot)
    case createP2P(parentJID: String, memberID: String)
    case groupDetails
    case fullMembers
    case delete(groupJID: String)
    case invites
    case blocklist
    case declineInvite
    case updateMember(GroupMember)
    case setOwner(memberID: String)
    case invite(targetJID: String, send: Bool?, reason: String?)
    case block(targets: [String])
    case kick(targetJID: String)
    case pin(groupStanzaID: String)
    case unpin(groupStanzaID: String)
    case getPermissions(scope: GroupPermissionScope, targetMemberID: String?)
    case setPermissions(GroupPermissionSet)
}

enum GroupCommandCodecError: Error, Equatable {
    case invalidMemberID(String)
    case invalidJID(String)
    case emptyBlockTargets
    case invalidGroupStanzaID(String)
    case missingPermissionTarget
    case forbiddenPermissionTarget(scope: GroupPermissionScope)
    case forbiddenPermission(String)
    case forbiddenTemporalPermission(scope: GroupPermissionScope, name: String)
    case absolutePermissionExpiryUnsupported(name: String)
}

enum GroupCommandCodec {
    static func encode(_ command: GroupCommand) throws -> DDXMLElement {
        switch command {
        case let .create(snapshot):
            let create = groupsElement(named: "create")
            create.addChild(try GroupProtocolCodec.encodeGroupSnapshot(snapshot))
            return create

        case let .createP2P(parentJID, memberID):
            let create = groupsElement(named: "create")
            let peerToPeer = DDXMLElement(name: "peer-to-peer")
            peerToPeer.addAttribute(
                withName: "parent",
                stringValue: try normalizeBareJID(parentJID)
            )
            peerToPeer.addAttribute(
                withName: "with",
                stringValue: try normalizeMemberID(memberID)
            )
            create.addChild(peerToPeer)
            return create

        case .groupDetails:
            return groupsElement(named: "query")

        case .fullMembers:
            return try GroupProtocolCodec.encodeFullMembers([])

        case let .delete(groupJID):
            let element = groupsElement(named: "delete")
            element.stringValue = try normalizeBareJID(groupJID)
            return element

        case .invites:
            return groupsElement(named: "invites")

        case .blocklist:
            return groupsElement(named: "block")

        case .declineInvite:
            return groupsElement(named: "decline")

        case var .updateMember(member):
            member.id = try normalizeMemberID(member.id)
            return try GroupProtocolCodec.encodeFullMembers([member])

        case let .setOwner(memberID):
            let element = groupsElement(named: "owner")
            element.addAttribute(
                withName: "id",
                stringValue: try normalizeMemberID(memberID)
            )
            return element

        case let .invite(targetJID, send, reason):
            return try GroupProtocolCodec.encodeInvite(
                .request(targetJID: targetJID, send: send, reason: reason)
            )

        case let .block(targets):
            guard !targets.isEmpty else {
                throw GroupCommandCodecError.emptyBlockTargets
            }
            let element = groupsElement(named: "block")
            for target in targets {
                element.addChild(
                    DDXMLElement(name: "jid", stringValue: try normalizeJIDOrDomain(target))
                )
            }
            return element

        case let .kick(targetJID):
            let element = groupsElement(named: "kick")
            element.addChild(
                DDXMLElement(name: "jid", stringValue: try normalizeJIDOrDomain(targetJID))
            )
            return element

        case let .pin(groupStanzaID):
            return try pinnedMessage(groupStanzaID: groupStanzaID, status: nil)

        case let .unpin(groupStanzaID):
            return try pinnedMessage(groupStanzaID: groupStanzaID, status: "remove")

        case let .getPermissions(scope, targetMemberID):
            return try encodePermissionGet(scope: scope, targetMemberID: targetMemberID)

        case let .setPermissions(set):
            return try encodePermissionSet(set)
        }
    }

    private static func groupsElement(named name: String) -> DDXMLElement {
        DDXMLElement(name: name, xmlns: GroupProtocolNamespace.groups)
    }

    private static func pinnedMessage(
        groupStanzaID: String,
        status: String?
    ) throws -> DDXMLElement {
        guard let id = nonEmpty(groupStanzaID) else {
            throw GroupCommandCodecError.invalidGroupStanzaID(groupStanzaID)
        }
        let element = groupsElement(named: "pinned-message")
        element.addAttribute(withName: "id", stringValue: id)
        if let status = status {
            element.addAttribute(withName: "status", stringValue: status)
        }
        return element
    }

    private static func encodePermissionGet(
        scope: GroupPermissionScope,
        targetMemberID: String?
    ) throws -> DDXMLElement {
        let element: DDXMLElement
        switch scope {
        case .direct:
            guard let targetMemberID = targetMemberID else {
                throw GroupCommandCodecError.missingPermissionTarget
            }
            element = DDXMLElement(
                name: "permissions",
                xmlns: GroupProtocolNamespace.permissions
            )
            element.addAttribute(
                withName: "target",
                stringValue: try normalizeMemberID(targetMemberID)
            )

        case .defaults, .newbies:
            guard targetMemberID == nil else {
                throw GroupCommandCodecError.forbiddenPermissionTarget(scope: scope)
            }
            element = DDXMLElement(
                name: scope == .defaults ? "defaults" : "newbies",
                xmlns: GroupProtocolNamespace.permissions
            )
        }
        return element
    }

    private static func encodePermissionSet(
        _ set: GroupPermissionSet
    ) throws -> DDXMLElement {
        var normalized = set
        switch set.scope {
        case .direct:
            guard let target = set.target else {
                throw GroupCommandCodecError.missingPermissionTarget
            }
            normalized.target = try normalizeMemberID(target)

        case .defaults, .newbies:
            guard set.target == nil else {
                throw GroupCommandCodecError.forbiddenPermissionTarget(scope: set.scope)
            }
        }

        for permission in set.permissions {
            let name = permission.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.lowercased() == "owner" {
                throw GroupCommandCodecError.forbiddenPermission(name)
            }
            if permission.expires != nil {
                throw GroupCommandCodecError.absolutePermissionExpiryUnsupported(name: name)
            }
            if set.scope == .defaults, permission.seconds != nil {
                throw GroupCommandCodecError.forbiddenTemporalPermission(
                    scope: set.scope,
                    name: name
                )
            }
        }

        return try GroupProtocolCodec.encodePermissionSet(normalized)
    }

    private static func normalizeMemberID(_ raw: String) throws -> String {
        guard let value = nonEmpty(raw), value != "0" else {
            throw GroupCommandCodecError.invalidMemberID(raw)
        }
        return value
    }

    private static func normalizeBareJID(_ raw: String) throws -> String {
        guard let value = nonEmpty(raw),
              let jid = XMPPJID(string: value),
              jid.user != nil,
              !jid.domain.isEmpty,
              !jid.bare.isEmpty else {
            throw GroupCommandCodecError.invalidJID(raw)
        }
        return jid.bare.lowercased()
    }

    private static func normalizeJIDOrDomain(_ raw: String) throws -> String {
        guard let value = nonEmpty(raw), let jid = XMPPJID(string: value) else {
            throw GroupCommandCodecError.invalidJID(raw)
        }
        if jid.user != nil, !jid.domain.isEmpty, !jid.bare.isEmpty {
            return jid.bare.lowercased()
        }
        guard !value.contains("@"),
              !value.contains("/"),
              jid.isServer else {
            throw GroupCommandCodecError.invalidJID(raw)
        }
        return value.lowercased()
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
