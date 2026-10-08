import Foundation
import XMPPFramework

/// Display metadata supplied with a forward; it does not establish identity or trust.
struct ForwardCardGroupSnapshot: Equatable {
    let jid: String
    let name: String
    let avatarURL: URL?
    let privacy: ForwardContactCard.Privacy?

    init(jid: String, name: String, avatarURL: URL? = nil,
         privacy: ForwardContactCard.Privacy? = nil) {
        self.jid = jid
        self.name = name
        self.avatarURL = avatarURL
        self.privacy = privacy
    }
}

struct ForwardCardSnapshot: Equatable {
    enum Kind { case individual, group }

    let kind: Kind
    let owner: String
    let name: String
    let jid: String?
    let avatarURL: URL?
    let badge: String?
    let privacy: ForwardContactCard.Privacy?
    let sourceGroup: ForwardCardGroupSnapshot?

    init(kind: Kind, owner: String, name: String, jid: String? = nil,
         avatarURL: URL? = nil, badge: String? = nil,
         privacy: ForwardContactCard.Privacy? = nil,
         sourceGroup: ForwardCardGroupSnapshot? = nil) {
        self.kind = kind
        self.owner = owner
        self.name = name
        self.jid = jid
        self.avatarURL = Self.hostedAvatarURL(avatarURL?.absoluteString)
        self.badge = Self.nonEmpty(badge)
        self.privacy = privacy
        self.sourceGroup = sourceGroup
    }

    var sourceGroupCard: ForwardCardSnapshot? {
        sourceGroup.map {
            ForwardCardSnapshot(kind: .group, owner: owner, name: $0.name,
                                jid: $0.jid, avatarURL: $0.avatarURL, privacy: $0.privacy)
        }
    }

    static func capture(_ forward: MessageForwardsInlineStorageItem) -> ForwardCardSnapshot {
        let attribution = forward.attribution
        let card = ForwardContactDataCodec.matchingCard(
            for: forward.forwardJid, references: forward.references.toArray()
        )
        let member = forward.references.first {
            $0.kind == .groupchat && nonEmpty($0.metadata?["id"] as? String) != nil
        }?.metadata
        let groupJID = attribution.sourceGroupJID.flatMap(bareJID)
        if let groupJID, let member {
            let groupCard = card?.kind == .group ? card : nil
            let group = ForwardCardGroupSnapshot(
                jid: groupJID, name: groupCard?.name ?? attribution.groupName ?? groupJID,
                avatarURL: hostedAvatarURL(groupCard?.avatarURI), privacy: attribution.groupPrivacy
            )
            return ForwardCardSnapshot(
                kind: .individual, owner: forward.owner, name: attribution.senderName,
                jid: (member["jid"] as? String).flatMap(bareJID),
                avatarURL: hostedAvatarURL(member["avatar_uri"] as? String),
                badge: member["badge"] as? String, sourceGroup: group
            )
        }
        if card?.kind == .group {
            return ForwardCardSnapshot(
                kind: .group, owner: forward.owner,
                name: card?.name ?? attribution.senderName,
                jid: bareJID(forward.forwardJid), avatarURL: hostedAvatarURL(card?.avatarURI),
                privacy: card?.privacy
            )
        }
        return ForwardCardSnapshot(
            kind: .individual, owner: forward.owner,
            name: card?.nickname ?? card?.name ?? attribution.senderName,
            jid: bareJID(forward.forwardJid), avatarURL: hostedAvatarURL(card?.avatarURI)
        )
    }

    static func hostedAvatarURL(_ raw: String?) -> URL? {
        guard let raw = nonEmpty(raw), let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func bareJID(_ raw: String) -> String? {
        nonEmpty(raw).flatMap { XMPPJID(string: $0)?.bare }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum ForwardCardGroupAccess { case unknown, loading, open, restricted, unavailable }
enum ForwardCardAction: String { case openChat, addContact, openGroup, joinGroup, requestToJoin }

struct ForwardCardPrimaryAction: Equatable {
    let kind: ForwardCardAction
    let isEnabled: Bool

    init(kind: ForwardCardAction, isEnabled: Bool = true) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

enum ForwardCardActionPolicy {
    static func primaryAction(for card: ForwardCardSnapshot, hasContact: Bool,
                              hasChat: Bool, hasGroup: Bool,
                              groupAccess: ForwardCardGroupAccess = .unknown) -> ForwardCardPrimaryAction? {
        guard !card.owner.isEmpty else { return nil }
        switch card.kind {
        case .individual:
            if card.jid?.isEmpty == false {
                return .init(kind: hasContact || hasChat ? .openChat : .addContact)
            }
            return hasGroup && card.sourceGroup != nil ? .init(kind: .openGroup) : nil
        case .group:
            guard card.jid?.isEmpty == false else { return nil }
            if hasGroup { return .init(kind: .openGroup) }
            switch groupAccess {
            case .open: return .init(kind: .joinGroup)
            case .restricted: return .init(kind: .requestToJoin, isEnabled: false)
            case .unknown, .loading, .unavailable: return nil
            }
        }
    }
}
