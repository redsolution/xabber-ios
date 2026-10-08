import Foundation
import XMPPFramework

/// A snapshot asserted by the forwarding user, never evidence of identity or
/// group membership. It is scoped to the message carrying its data reference.
struct ForwardContactCard: Equatable {
    enum Kind: String {
        case individual
        case group
    }

    enum Privacy: String {
        case `public`
        case incognito
    }

    let jid: String
    let name: String
    let nickname: String?
    let kind: Kind
    let privacy: Privacy?
    let avatarURI: String?
}

enum ForwardContactDataCodec {
    static let referencesXMLNS = "https://xabber.com/protocol/references"
    static let vcardXMLNS = "urn:ietf:params:xml:ns:vcard-4.0"

    static func decode(_ reference: DDXMLElement) -> ForwardContactCard? {
        guard matches(reference, name: "reference", namespace: referencesXMLNS),
              reference.attributeStringValue(forName: "type") == "data",
              reference.attribute(forName: "begin") == nil,
              reference.attribute(forName: "end") == nil else {
            return nil
        }
        let payloads = elementChildren(reference)
        guard payloads.count == 1,
              let vcard = payloads.first,
              matches(vcard, name: "vcard", namespace: vcardXMLNS),
              let name = value(of: "fn", childName: "text", in: vcard),
              let impp = value(of: "impp", childName: "uri", in: vcard),
              let jid = jid(fromXMPPURI: impp) else {
            return nil
        }

        // Multiple values for properties used by this profile are ambiguous.
        // Unknown xCard properties remain outside this presentation snapshot.
        for property in ["nickname", "kind", "x-groups-privacy", "photo"] {
            guard children(vcard, named: property).count <= 1 else { return nil }
        }
        let rawKind = value(of: "kind", childName: "text", in: vcard)
        if !children(vcard, named: "kind").isEmpty, rawKind == nil { return nil }
        let kind: ForwardContactCard.Kind
        let legacyPrivacy: ForwardContactCard.Privacy?
        switch rawKind {
        case nil, "individual":
            kind = .individual
            legacyPrivacy = nil
        case "group", "groupchat":
            kind = .group
            legacyPrivacy = nil
        case "incognito":
            kind = .group
            legacyPrivacy = .incognito
        default:
            return nil
        }
        // No inference from an author's real JID, group title, or absent data.
        let rawPrivacy = value(of: "x-groups-privacy", childName: "text", in: vcard)
        let privacy: ForwardContactCard.Privacy?
        if kind == .group {
            privacy = children(vcard, named: "x-groups-privacy").isEmpty
                ? legacyPrivacy
                : rawPrivacy.flatMap(ForwardContactCard.Privacy.init(rawValue:))
        } else {
            privacy = nil
        }
        return ForwardContactCard(
            jid: jid,
            name: name,
            nickname: value(of: "nickname", childName: "text", in: vcard),
            kind: kind,
            privacy: privacy,
            avatarURI: hostedAvatarURI(value(of: "photo", childName: "uri", in: vcard))
        )
    }

    static func encode(_ card: ForwardContactCard) -> DDXMLElement {
        let reference = DDXMLElement(name: "reference", xmlns: referencesXMLNS)
        reference.addAttribute(withName: "type", stringValue: "data")
        let vcard = DDXMLElement(name: "vcard", xmlns: vcardXMLNS)
        vcard.addChild(property("fn", childName: "text", value: card.name))
        if let nickname = nonempty(card.nickname) {
            vcard.addChild(property("nickname", childName: "text", value: nickname))
        }
        vcard.addChild(property("kind", childName: "text", value: card.kind.rawValue))
        vcard.addChild(property("impp", childName: "uri", value: "xmpp:\(card.jid)"))
        if card.kind == .group, let privacy = card.privacy {
            vcard.addChild(property("x-groups-privacy", childName: "text", value: privacy.rawValue))
        }
        if let avatarURI = hostedAvatarURI(card.avatarURI) {
            vcard.addChild(property("photo", childName: "uri", value: avatarURI))
        }
        reference.addChild(vcard)
        return reference
    }

    static func cards(in message: XMPPMessage) -> [ForwardContactCard] {
        unambiguousCards(elementChildren(message).compactMap(decode))
    }

    static func metadata(for card: ForwardContactCard) -> [String: Any] {
        var result: [String: Any] = [
            "jid": card.jid,
            "name": card.name,
            "kind": card.kind.rawValue
        ]
        if let nickname = card.nickname { result["nickname"] = nickname }
        if card.kind == .group, let privacy = card.privacy { result["privacy"] = privacy.rawValue }
        if let avatarURI = hostedAvatarURI(card.avatarURI) { result["avatar_uri"] = avatarURI }
        return result
    }

    static func card(from metadata: [String: Any]?) -> ForwardContactCard? {
        guard let rawJID = metadata?["jid"] as? String,
              let jid = canonicalBareJID(rawJID),
              let name = nonempty(metadata?["name"] as? String),
              let rawKind = metadata?["kind"] as? String,
              let kind = ForwardContactCard.Kind(rawValue: rawKind) else {
            return nil
        }
        let privacy = kind == .group
            ? (metadata?["privacy"] as? String).flatMap(ForwardContactCard.Privacy.init(rawValue:))
            : nil
        return ForwardContactCard(
            jid: jid, name: name, nickname: nonempty(metadata?["nickname"] as? String),
            kind: kind, privacy: privacy,
            avatarURI: hostedAvatarURI(metadata?["avatar_uri"] as? String)
        )
    }

    static func card(from reference: MessageReferenceStorageItem) -> ForwardContactCard? {
        guard reference.kind == .forwardContactData else { return nil }
        return card(from: reference.metadata)
    }

    static func matchingCard(
        for from: String,
        references: [MessageReferenceStorageItem]
    ) -> ForwardContactCard? {
        matchingCard(for: from, cards: references.compactMap { card(from: $0) })
    }

    static func matchingCard(
        for from: String,
        cards: [ForwardContactCard]
    ) -> ForwardContactCard? {
        guard let jid = XMPPJID(string: from)?.bare else { return nil }
        return unambiguousCards(cards)
            .first { $0.jid == jid }
    }

    /// Conflicting assertions never become authoritative by arrival order.
    /// A conflicted address falls back to independent/local identity resolution.
    private static func unambiguousCards(_ cards: [ForwardContactCard]) -> [ForwardContactCard] {
        var orderedJIDs: [String] = []
        var unique: [String: ForwardContactCard] = [:]
        var conflicts = Set<String>()
        for card in cards {
            if let existing = unique[card.jid] {
                if existing != card { conflicts.insert(card.jid) }
            } else {
                orderedJIDs.append(card.jid)
                unique[card.jid] = card
            }
        }
        return orderedJIDs.compactMap { conflicts.contains($0) ? nil : unique[$0] }
    }

    private static func jid(fromXMPPURI uri: String) -> String? {
        guard uri.prefix(5).lowercased() == "xmpp:",
              let address = String(uri.dropFirst(5)).removingPercentEncoding,
              !address.contains("?"), !address.contains("#") else {
            return nil
        }
        return canonicalBareJID(address)
    }

    private static func canonicalBareJID(_ address: String) -> String? {
        guard !address.isEmpty,
              !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !address.contains("/"),
              !address.contains("?"), !address.contains("#"),
              let jid = XMPPJID(string: address),
              jid.resource == nil,
              !jid.bare.isEmpty else {
            return nil
        }
        return jid.bare
    }

    private static func hostedAvatarURI(_ rawValue: String?) -> String? {
        guard let value = nonempty(rawValue),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.url != nil else {
            return nil
        }
        return value
    }

    private static func property(_ name: String, childName: String, value: String) -> DDXMLElement {
        let property = DDXMLElement(name: name, xmlns: vcardXMLNS)
        let child = DDXMLElement(name: childName, xmlns: vcardXMLNS)
        child.stringValue = value
        property.addChild(child)
        return property
    }

    private static func value(of property: String, childName: String, in vcard: DDXMLElement) -> String? {
        let properties = children(vcard, named: property)
        guard properties.count == 1,
              let node = properties.first else { return nil }
        let values = elementChildren(node)
        guard values.count == 1,
              let value = values.first,
              matches(value, name: childName, namespace: vcardXMLNS) else {
            return nil
        }
        return nonempty(value.stringValue)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func children(_ node: DDXMLElement, named name: String) -> [DDXMLElement] {
        elementChildren(node).filter { matches($0, name: name, namespace: vcardXMLNS) }
    }

    private static func elementChildren(_ node: DDXMLElement) -> [DDXMLElement] {
        (node.children ?? []).compactMap { $0 as? DDXMLElement }
    }

    private static func matches(_ node: DDXMLElement, name: String, namespace: String) -> Bool {
        node.localName == name && node.uri == namespace
    }
}
