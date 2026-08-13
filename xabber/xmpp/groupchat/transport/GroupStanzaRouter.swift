import Foundation
import XMPPFramework

enum GroupStanzaRouterError: Error, Equatable {
    case ambiguousEnvelope(String)
    case missingEnvelopeElement(parent: String, child: String)
    case invalidGroupJID(String?)
}

enum GroupMessageSource: Equatable, Sendable {
    case live
    case mam(queryID: String?, resultID: String?)
    case carbonSent
    case carbonReceived
    case senderReceipt
}

enum GroupMessageStanzaType: String, Equatable, Sendable {
    case chat
    case headline
}

struct GroupMessageEvent: Equatable, Sendable {
    let groupJID: String
    let source: GroupMessageSource
    let stanzaType: GroupMessageStanzaType
    let messageID: String?
    let originID: String?
    let stanzaID: String?
    let stanzaIDBy: String?
    let body: String?
    let author: GroupMember?
    let systemEvent: GroupSystemEvent?
}

struct GroupInviteMessageEvent: Equatable, Sendable {
    let groupJID: String
    let source: GroupMessageSource
    let messageID: String?
    let invite: GroupInvite
    let preview: GroupSnapshot?
}

enum GroupIQPayload: Equatable, Sendable {
    case empty
    case snapshot(GroupSnapshot)
    case members([GroupMember])
    case permissions(GroupPermissionSet)
    case invite(GroupInvite)
}

struct GroupIQStanzaError: Equatable, Sendable {
    let type: String?
    let condition: String?
    let text: String?
    let payload: GroupIQPayload?
}

enum GroupIQOutcome: Equatable, Sendable {
    case result(GroupIQPayload)
    case error(GroupIQStanzaError)
}

struct GroupIQCorrelationEvent: Equatable, Sendable {
    let requestID: String
    let outcome: GroupIQOutcome
}

enum GroupReducerIngress: Equatable, Sendable {
    case presence
    case headline
    case message
}

struct GroupReducerInput: Equatable, Sendable {
    let groupJID: String
    let ingress: GroupReducerIngress
    let events: [GroupDomainEvent]
}

enum GroupStanzaEvent: Equatable, Sendable {
    case iq(GroupIQCorrelationEvent)
    case reducer(GroupReducerInput)
    case message(GroupMessageEvent)
    case invite(GroupInviteMessageEvent)

    /// The only bridge from routed stanzas into `GroupDomainReducer`.
    /// Requests and invite previews intentionally have no reducer input.
    var reducerInput: GroupReducerInput? {
        switch self {
        case let .reducer(input):
            return input

        case let .message(message):
            if let systemEvent = message.systemEvent {
                return GroupReducerInput(
                    groupJID: message.groupJID,
                    ingress: .message,
                    events: [.system(systemEvent)]
                )
            }
            if let author = message.author {
                return GroupReducerInput(
                    groupJID: message.groupJID,
                    ingress: .message,
                    events: [.member(author)]
                )
            }
            return nil

        case .iq, .invite:
            return nil
        }
    }
}

enum GroupStanzaRouter {
    private enum Namespace {
        static let forwarded = "urn:xmpp:forward:0"
        static let mam = "urn:xmpp:mam:2"
        static let carbons = "urn:xmpp:carbons:2"
        static let stanzaID = "urn:xmpp:sid:0"
        static let stanzaErrors = "urn:ietf:params:xml:ns:xmpp-stanzas"
    }

    static func route(
        _ iq: XMPPIQ,
        correlating requestIDs: Set<String>
    ) throws -> GroupStanzaEvent? {
        guard !containsLegacyGroupNamespace(iq),
              let requestID = nonEmpty(iq.elementID),
              requestIDs.contains(requestID) else {
            return nil
        }

        let payloads = try canonicalIQPayloads(in: iq)
        guard payloads.count <= 1 else {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "IQ contains multiple canonical group payloads"
            )
        }
        let payload = payloads.first

        switch iq.attributeStringValue(forName: "type") {
        case "result":
            return .iq(
                GroupIQCorrelationEvent(
                    requestID: requestID,
                    outcome: .result(payload ?? .empty)
                )
            )

        case "error":
            let errorElement = directChildren(of: iq).first {
                $0.name == "error"
            }
            let errorChildren = errorElement.map(directChildren) ?? []
            let textElement = errorChildren.first {
                $0.name == "text" && effectiveNamespace(of: $0) == Namespace.stanzaErrors
            }
            let condition = errorChildren.first {
                $0.name != "text" && effectiveNamespace(of: $0) == Namespace.stanzaErrors
            }?.name
            return .iq(
                GroupIQCorrelationEvent(
                    requestID: requestID,
                    outcome: .error(
                        GroupIQStanzaError(
                            type: nonEmpty(errorElement?.attributeStringValue(forName: "type")),
                            condition: nonEmpty(condition),
                            text: textElement?.stringValue,
                            payload: payload
                        )
                    )
                )
            )

        default:
            return nil
        }
    }

    static func route(_ presence: XMPPPresence) throws -> GroupStanzaEvent? {
        guard !containsLegacyGroupNamespace(presence) else {
            return nil
        }
        let groups = directChildren(of: presence).filter {
            $0.name == "group" && effectiveNamespace(of: $0) == GroupProtocolNamespace.groups
        }
        guard groups.count <= 1 else {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "presence contains multiple canonical group payloads"
            )
        }
        guard let groupElement = groups.first else {
            return nil
        }
        let groupJID = try requiredBareJID(presence.from?.bare)
        let rawType = nonEmpty(presence.attributeStringValue(forName: "type"))

        let subscription: GroupSelfSubscription?
        let isSnapshot: Bool
        switch rawType {
        case "subscribe":
            subscription = .wait
            isSnapshot = true
        case "subscribed":
            subscription = .both
            isSnapshot = true
        case "unsubscribe", "unsubscribed":
            subscription = GroupSelfSubscription.none
            isSnapshot = false
        case nil, "unavailable":
            subscription = nil
            isSnapshot = false
        default:
            return nil
        }

        var events: [GroupDomainEvent] = []
        if let subscription {
            events.append(.selfSubscription(subscription))
        }
        if isSnapshot {
            events.append(
                .snapshot(try GroupProtocolCodec.decodeGroupSnapshot(groupElement))
            )
        } else {
            events.append(
                .patch(try GroupProtocolCodec.decodeGroupPatch(groupElement))
            )
        }

        return .reducer(
            GroupReducerInput(
                groupJID: groupJID,
                ingress: .presence,
                events: events
            )
        )
    }

    static func route(_ message: XMPPMessage) throws -> GroupStanzaEvent? {
        guard !containsLegacyGroupNamespace(message),
              message.attributeStringValue(forName: "type") != "groupchat" else {
            return nil
        }

        if let receipt = try senderReceipt(in: message) {
            return try routeMessageContent(
                receipt.message,
                source: .senderReceipt,
                groupJIDOverride: receipt.groupJID,
                allowUnmarkedMessage: true
            )
        }

        let unwrapped = try unwrapStandardEnvelope(message)
        guard !containsLegacyGroupNamespace(unwrapped.message),
              unwrapped.message.attributeStringValue(forName: "type") != "groupchat" else {
            return nil
        }
        return try routeMessageContent(
            unwrapped.message,
            source: unwrapped.source,
            groupJIDOverride: nil,
            allowUnmarkedMessage: false
        )
    }
}

private extension GroupStanzaRouter {
    struct UnwrappedMessage {
        let message: XMPPMessage
        let source: GroupMessageSource
    }

    struct SenderReceipt {
        let message: XMPPMessage
        let groupJID: String
    }

    static func senderReceipt(in outer: XMPPMessage) throws -> SenderReceipt? {
        guard outer.attributeStringValue(forName: "type") == "headline" else {
            return nil
        }
        let wrappers = directChildren(of: outer).filter {
            $0.name == "x" && effectiveNamespace(of: $0) == GroupProtocolNamespace.groups
        }
        guard wrappers.count <= 1 else {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "headline contains multiple canonical x wrappers"
            )
        }
        guard let wrapper = wrappers.first else {
            return nil
        }
        let forwarded = directChildren(of: wrapper).filter {
            $0.name == "forwarded" && effectiveNamespace(of: $0) == Namespace.forwarded
        }
        guard !forwarded.isEmpty else {
            return nil
        }
        guard forwarded.count == 1, directChildren(of: wrapper).count == 1 else {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "sender receipt x must contain exactly one forwarded envelope"
            )
        }
        let message = try requiredForwardedMessage(in: forwarded[0])
        return SenderReceipt(
            message: message,
            groupJID: try requiredBareJID(outer.from?.bare)
        )
    }

    static func unwrapStandardEnvelope(
        _ outer: XMPPMessage
    ) throws -> UnwrappedMessage {
        let mamResults = directChildren(of: outer).filter {
            $0.name == "result" && effectiveNamespace(of: $0) == Namespace.mam
        }
        guard mamResults.count <= 1 else {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "message contains multiple MAM results"
            )
        }
        if let result = mamResults.first {
            let forwarded = directChildren(of: result).filter {
                $0.name == "forwarded" && effectiveNamespace(of: $0) == Namespace.forwarded
            }
            guard forwarded.count == 1 else {
                throw GroupStanzaRouterError.missingEnvelopeElement(
                    parent: "result",
                    child: "forwarded"
                )
            }
            return UnwrappedMessage(
                message: try requiredForwardedMessage(in: forwarded[0]),
                source: .mam(
                    queryID: nonEmpty(result.attributeStringValue(forName: "queryid")),
                    resultID: nonEmpty(result.attributeStringValue(forName: "id"))
                )
            )
        }

        let carbonWrappers = directChildren(of: outer).filter {
            ($0.name == "sent" || $0.name == "received")
                && effectiveNamespace(of: $0) == Namespace.carbons
        }
        guard carbonWrappers.count <= 1 else {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "message contains multiple carbon wrappers"
            )
        }
        if let carbon = carbonWrappers.first {
            guard normalizedBareJID(outer.from?.bare) == normalizedBareJID(outer.to?.bare) else {
                throw GroupStanzaRouterError.ambiguousEnvelope(
                    "carbon wrapper must be addressed between the same bare JID"
                )
            }
            let forwarded = directChildren(of: carbon).filter {
                $0.name == "forwarded" && effectiveNamespace(of: $0) == Namespace.forwarded
            }
            guard forwarded.count == 1 else {
                throw GroupStanzaRouterError.missingEnvelopeElement(
                    parent: carbon.name ?? "carbon",
                    child: "forwarded"
                )
            }
            return UnwrappedMessage(
                message: try requiredForwardedMessage(in: forwarded[0]),
                source: carbon.name == "sent" ? .carbonSent : .carbonReceived
            )
        }

        return UnwrappedMessage(message: outer, source: .live)
    }

    static func requiredForwardedMessage(
        in forwarded: DDXMLElement
    ) throws -> XMPPMessage {
        let messages = directChildren(of: forwarded).filter { $0.name == "message" }
        guard messages.count == 1 else {
            throw GroupStanzaRouterError.missingEnvelopeElement(
                parent: "forwarded",
                child: "message"
            )
        }
        return XMPPMessage(from: messages[0])
    }

    static func routeMessageContent(
        _ message: XMPPMessage,
        source: GroupMessageSource,
        groupJIDOverride: String?,
        allowUnmarkedMessage: Bool
    ) throws -> GroupStanzaEvent? {
        guard let stanzaType = GroupMessageStanzaType(
            rawValue: message.attributeStringValue(forName: "type") ?? ""
        ) else {
            return nil
        }

        let invites = canonicalChildren(named: "invite", in: message)
        let groups = canonicalChildren(named: "group", in: message)
        let groupX = canonicalChildren(named: "x", in: message)
        let permissionElements = directChildren(of: message).filter {
            ["permissions", "defaults", "newbies"].contains($0.name ?? "")
                && effectiveNamespace(of: $0) == GroupProtocolNamespace.permissions
        }
        let membersElements = canonicalChildren(named: "members", in: message)

        for count in [invites.count, groups.count, groupX.count, permissionElements.count, membersElements.count]
        where count > 1 {
            throw GroupStanzaRouterError.ambiguousEnvelope(
                "message contains duplicate canonical group payloads"
            )
        }

        if let inviteElement = invites.first {
            let invite = try GroupProtocolCodec.decodeInvite(inviteElement)
            guard case let .message(groupJID, _, _) = invite else {
                return nil
            }
            let preview = try groups.first.map(GroupProtocolCodec.decodeGroupSnapshot)
            return .invite(
                GroupInviteMessageEvent(
                    groupJID: groupJID,
                    source: source,
                    messageID: nonEmpty(message.elementID),
                    invite: invite,
                    preview: preview
                )
            )
        }

        if let group = groups.first {
            guard stanzaType == .headline else {
                return nil
            }
            return .reducer(
                GroupReducerInput(
                    groupJID: try resolvedGroupJID(
                        for: message,
                        source: source,
                        override: groupJIDOverride
                    ),
                    ingress: .headline,
                    events: [.patch(try GroupProtocolCodec.decodeGroupPatch(group))]
                )
            )
        }

        if let members = membersElements.first {
            guard stanzaType == .headline else {
                return nil
            }
            return .reducer(
                GroupReducerInput(
                    groupJID: try resolvedGroupJID(
                        for: message,
                        source: source,
                        override: groupJIDOverride
                    ),
                    ingress: .headline,
                    events: [.replaceMembers(try GroupProtocolCodec.decodeFullMembers(members))]
                )
            )
        }

        if let permissions = permissionElements.first {
            guard stanzaType == .headline else {
                return nil
            }
            return .reducer(
                GroupReducerInput(
                    groupJID: try resolvedGroupJID(
                        for: message,
                        source: source,
                        override: groupJIDOverride
                    ),
                    ingress: .headline,
                    events: [.permissions(try GroupProtocolCodec.decodePermissionSet(permissions))]
                )
            )
        }

        var author: GroupMember?
        var systemEvent: GroupSystemEvent?
        if let x = groupX.first {
            let children = directChildren(of: x)
            if children.count == 1, children.first?.name == "system-message" {
                systemEvent = try GroupProtocolCodec.decodeSystemEvent(x)
            } else {
                author = try GroupProtocolCodec.decodeMessageAuthor(x)
            }
        } else if !allowUnmarkedMessage {
            return nil
        }

        let groupJID = try resolvedGroupJID(
            for: message,
            source: source,
            override: groupJIDOverride
        )
        let stanzaIDElement = directChildren(of: message)
            .filter {
                $0.name == "stanza-id" && effectiveNamespace(of: $0) == Namespace.stanzaID
            }
            .first(where: {
                normalizedBareJID($0.attributeStringValue(forName: "by")) == groupJID
            })
            ?? directChildren(of: message).first {
                $0.name == "stanza-id" && effectiveNamespace(of: $0) == Namespace.stanzaID
            }
        let originID = directChildren(of: message).first {
            $0.name == "origin-id" && effectiveNamespace(of: $0) == Namespace.stanzaID
        }?.attributeStringValue(forName: "id")

        let rawBody = message.element(forName: "body")?.stringValue
        return .message(
            GroupMessageEvent(
                groupJID: groupJID,
                source: source,
                stanzaType: stanzaType,
                messageID: nonEmpty(message.elementID),
                originID: nonEmpty(originID),
                stanzaID: nonEmpty(stanzaIDElement?.attributeStringValue(forName: "id")),
                stanzaIDBy: normalizedBareJID(
                    stanzaIDElement?.attributeStringValue(forName: "by")
                ),
                body: strippedNicknameFallback(rawBody, nickname: author?.nickname),
                author: author,
                systemEvent: systemEvent
            )
        )
    }

    static func canonicalIQPayloads(in iq: XMPPIQ) throws -> [GroupIQPayload] {
        try directChildren(of: iq).compactMap { element in
            switch (element.name, effectiveNamespace(of: element)) {
            case ("group", GroupProtocolNamespace.groups):
                return .snapshot(try GroupProtocolCodec.decodeGroupSnapshot(element))
            case ("members", GroupProtocolNamespace.groups):
                return .members(try GroupProtocolCodec.decodeFullMembers(element))
            case ("invite", GroupProtocolNamespace.groups):
                return .invite(try GroupProtocolCodec.decodeInvite(element))
            case ("permissions", GroupProtocolNamespace.permissions),
                 ("defaults", GroupProtocolNamespace.permissions),
                 ("newbies", GroupProtocolNamespace.permissions):
                return .permissions(try GroupProtocolCodec.decodePermissionSet(element))
            default:
                return nil
            }
        }
    }

    static func resolvedGroupJID(
        for message: XMPPMessage,
        source: GroupMessageSource,
        override: String?
    ) throws -> String {
        if let override {
            return try requiredBareJID(override)
        }
        switch source {
        case .carbonSent:
            return try requiredBareJID(message.to?.bare)
        case .live, .mam, .carbonReceived, .senderReceipt:
            return try requiredBareJID(message.from?.bare)
        }
    }

    static func strippedNicknameFallback(
        _ body: String?,
        nickname: String?
    ) -> String? {
        guard let body, let nickname else {
            return body
        }
        let prefix = nickname + ":\n"
        guard body.hasPrefix(prefix) else {
            return body
        }
        return String(body.dropFirst(prefix.count))
    }

    static func canonicalChildren(
        named name: String,
        in element: DDXMLElement
    ) -> [DDXMLElement] {
        directChildren(of: element).filter {
            $0.name == name && effectiveNamespace(of: $0) == GroupProtocolNamespace.groups
        }
    }

    static func directChildren(of element: DDXMLElement) -> [DDXMLElement] {
        element.children?.compactMap { $0 as? DDXMLElement } ?? []
    }

    static func effectiveNamespace(of element: DDXMLElement) -> String? {
        var current: DDXMLElement? = element
        while let candidate = current {
            if let namespace = candidate.xmlns() {
                return namespace
            }
            current = candidate.parent as? DDXMLElement
        }
        return nil
    }

    static func containsLegacyGroupNamespace(_ element: DDXMLElement) -> Bool {
        if let namespace = effectiveNamespace(of: element),
           isLegacyGroupNamespace(namespace) {
            return true
        }
        return directChildren(of: element).contains { containsLegacyGroupNamespace($0) }
    }

    static func isLegacyGroupNamespace(_ namespace: String) -> Bool {
        namespace == "http://xabber.com/protocol/groupchat"
            || namespace == "https://xabber.com/protocol/groupchat"
            || namespace.hasPrefix("https://xabber.com/protocol/groups#")
            || namespace.hasPrefix("http://xabber.com/protocol/groups")
    }

    static func requiredBareJID(_ raw: String?) throws -> String {
        guard let normalized = normalizedBareJID(raw) else {
            throw GroupStanzaRouterError.invalidGroupJID(raw)
        }
        return normalized
    }

    static func normalizedBareJID(_ raw: String?) -> String? {
        guard let raw = nonEmpty(raw),
              let jid = XMPPJID(string: raw),
              jid.user != nil,
              !jid.domain.isEmpty,
              !jid.bare.isEmpty else {
            return nil
        }
        return jid.bare.lowercased()
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}
