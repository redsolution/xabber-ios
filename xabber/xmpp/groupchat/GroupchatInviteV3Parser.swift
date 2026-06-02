import Foundation
import KissXML

struct GroupchatInviteV3Payload: Equatable {
    static let groupsNamespace = "https://xabber.com/protocol/groups"

    let owner: String
    let groupchat: String
    let sender: String
    let invitee: String?
    let messageId: String?
    let originId: String?
    let stanzaId: String?
    let archiveId: String?
    let reason: String?
    let date: Date
    let isAnonymous: Bool
    let isFromGroupchat: Bool
    let isOutgoing: Bool
}

enum GroupchatInviteV3Parser {
    static func isInvite(_ message: DDXMLElement) -> Bool {
        parse(message, owner: "", date: Date(), archiveId: nil) != nil
    }

    static func parse(
        _ message: DDXMLElement,
        owner: String,
        date: Date,
        archiveId: String?
    ) -> GroupchatInviteV3Payload? {
        guard let invite = message.xbFirstChild(named: "invite", xmlns: GroupchatInviteV3Payload.groupsNamespace),
              invite.xmlns() == GroupchatInviteV3Payload.groupsNamespace,
              let groupchat = trimmed(invite.xbAttributeString("jid")),
              !groupchat.isEmpty else {
            return nil
        }

        let from = bareJid(message.xbAttributeString("from") ?? "")
        let to = bareJid(message.xbAttributeString("to") ?? "")
        guard !from.isEmpty || !to.isEmpty else {
            return nil
        }

        let group = message.xbFirstChild(named: "group", xmlns: GroupchatInviteV3Payload.groupsNamespace)
        let privacy = trimmed(group?.xbAttributeString("privacy"))
        let explicitInviter = explicitInviterBareJid(from: invite)
        let effectiveSender = explicitInviter ?? from
        guard !effectiveSender.isEmpty else {
            return nil
        }

        let isOutgoing = owner.isEmpty ? false : from == owner
        let invitee = isOutgoing ? to : nil
        let sender = isOutgoing ? owner : effectiveSender
        let stanzaId = preferredStanzaId(in: message, owner: owner, groupchat: groupchat)

        return GroupchatInviteV3Payload(
            owner: owner,
            groupchat: groupchat,
            sender: sender,
            invitee: invitee,
            messageId: trimmed(message.xbAttributeString("id")),
            originId: trimmed(message.xbFirstChild(named: "origin-id")?.xbAttributeString("id")),
            stanzaId: stanzaId,
            archiveId: trimmed(archiveId),
            reason: trimmed(invite.xbFirstChild(named: "reason")?.stringValue),
            date: date,
            isAnonymous: privacy == "incognito",
            isFromGroupchat: effectiveSender == groupchat || from == groupchat,
            isOutgoing: isOutgoing
        )
    }

    private static func explicitInviterBareJid(from invite: DDXMLElement) -> String? {
        let childNames = ["inviter", "sender", "user"]
        for name in childNames {
            guard let element = invite.xbFirstChild(named: name) else {
                continue
            }
            if let jid = trimmed(element.xbAttributeString("jid")) {
                return bareJid(jid)
            }
            if let jid = trimmed(element.xbFirstChild(named: "jid")?.stringValue) {
                return bareJid(jid)
            }
        }
        if let jid = trimmed(invite.xbAttributeString("inviter")) {
            return bareJid(jid)
        }
        return nil
    }

    private static func preferredStanzaId(in message: DDXMLElement, owner: String, groupchat: String) -> String? {
        let ids = message.elements(forName: "stanza-id") + message.elements(forName: "archived")
        guard !ids.isEmpty else {
            return nil
        }
        if ids.count == 1 {
            return trimmed(ids.first?.xbAttributeString("id"))
        }
        let preferredBy = owner.isEmpty ? groupchat : owner
        return ids
            .first(where: { $0.xbAttributeString("by") == preferredBy })?
            .xbAttributeString("id")
            .flatMap(trimmed)
            ?? ids.first(where: { $0.xbAttributeString("by") == groupchat })?
                .xbAttributeString("id")
                .flatMap(trimmed)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func bareJid(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "/")
            .first ?? ""
    }
}

private extension DDXMLElement {
    func xbFirstChild(named name: String, xmlns namespace: String? = nil) -> DDXMLElement? {
        elements(forName: name).first(where: { element in
            guard let namespace else {
                return true
            }
            return element.xmlns() == namespace
        })
    }

    func xbAttributeString(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }
}
