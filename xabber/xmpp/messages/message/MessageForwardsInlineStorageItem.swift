//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import RealmSwift
import XMPPFramework
import MaterialComponents.MDCPalettes

/// Forwarder-supplied attribution is separate from transport routing and from
/// authenticated incoming sender evidence. Unknown group privacy stays unknown.
struct ForwardAttribution: Equatable {
    let routingJID: String
    let sourceGroupJID: String?
    let memberID: String?
    let displayableAuthorJID: String?
    let groupName: String?
    let groupPrivacy: ForwardContactCard.Privacy?
    let senderName: String
}

class MessageForwardsInlineStorageItem: Object {
        
    override static func indexedProperties() -> [String] {
        return ["messageId"]
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var messageId: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var opponent: String = ""
    @objc dynamic var jid: String = ""
    
    @objc dynamic var parentId: String = ""
    @objc dynamic var body: String = ""
    
    @objc dynamic var forwardJid: String = ""
    @objc dynamic var forwardNickname: String = ""
    
    @objc dynamic var isOutgoing: Bool = false
    @objc dynamic var originalDate: Date? = nil
    
    @objc dynamic var rosterItem: RosterStorageItem? = nil
    
    var subforwards: List<MessageForwardsInlineStorageItem> = List<MessageForwardsInlineStorageItem>()
    var references: List<MessageReferenceStorageItem> = List<MessageReferenceStorageItem>()

    var attribution: ForwardAttribution {
        let member = references.first(where: {
            $0.kind == .groupchat && nonEmptyAuthorValue($0.metadata?["id"] as? String) != nil
        })?.metadata
        let card = ForwardContactDataCodec.matchingCard(for: forwardJid, references: references.toArray())
        let groupCard = card?.kind == .group ? card : nil
        let sourceGroupJID = member != nil || groupCard != nil ? nonEmptyAuthorValue(forwardJid) : nil
        let displayableAuthorJID: String?
        if sourceGroupJID != nil {
            displayableAuthorJID = nonEmptyAuthorValue(member?["jid"] as? String)
                .flatMap { XMPPJID(string: $0)?.bare }
        } else {
            displayableAuthorJID = nonEmptyAuthorValue(forwardJid)
                .flatMap { XMPPJID(string: $0)?.bare }
        }
        return ForwardAttribution(
            routingJID: forwardJid,
            sourceGroupJID: sourceGroupJID,
            memberID: nonEmptyAuthorValue(member?["id"] as? String),
            displayableAuthorJID: displayableAuthorJID,
            groupName: groupCard?.name ?? sourceGroupJID.flatMap(localDisplayName),
            groupPrivacy: groupCard?.privacy,
            senderName: tryToLoadNickname()
        )
    }
    
    
    func configureInline(
        _ messageContainer: XMPPMessage,
        parentId: String,
        owner: String,
        jid: String,
        opponent: String,
        outgoing: Bool,
        date: Date?,
        forwardJid: String?,
        forwardDepth: Int = 1,
        referenceIndex: Int? = nil,
        contactCard: ForwardContactCard? = nil
    ) {
        self.owner = owner
        self.parentId = parentId
        self.jid = jid
        self.opponent = opponent
        self.messageId = getUniqueMessageId(messageContainer, owner: owner)
        var identity = [parentId, messageId]
        if let referenceIndex { identity.append("forward-\(referenceIndex)") }
        self.primary = identity.prp()
        let parsedReferences = parseReferences(
            messageContainer,
            primary: self.primary,
            jid: jid,
            owner: owner,
            forwardDepth: forwardDepth,
            sourceDate: date
        )
        parsedReferences.forEach { $0.messageId = self.primary }
        self.references.append(objectsIn: parsedReferences)
        if let contactCard {
            let reference = MessageReferenceStorageItem()
            reference.owner = owner
            reference.jid = jid
            reference.messageId = self.primary
            reference.kind = .forwardContactData
            reference.metadata = ForwardContactDataCodec.metadata(for: contactCard)
            self.references.append(reference)
        }
        self.subforwards.append(objectsIn: parseInlineMessages(
            messageContainer,
            parentId: self.primary,
            jid: jid,
            owner: owner,
            depth: forwardDepth
        ))
        let bodyReferences = SCEReceivePolicy.children(of: messageContainer, named: "reference", xmlns: "https://xabber.com/protocol/references")
        if SCEReceivePolicy.hasOMEMO2(messageContainer) {
            self.body = L10n.text("chat_list__preview__encrypted_message", fallback: "Encrypted message")
        } else {
            self.body = SCEReceivePolicy.children(of: messageContainer, named: "body", xmlns: "jabber:client")
                .first?.stringValue?.xmlEscaping(reverse: false)
                .excludeFromBody(bodyReferences, groupchat: nil, forwardDepth: forwardDepth) ?? ""
        }
        self.isOutgoing = outgoing
        self.originalDate = date
        self.forwardJid = forwardJid ?? ""
        if let authorSnapshot = resolvedGroupchatAuthorDisplayName(
            userElement: nil,
            references: references.toArray()
        ) {
            self.forwardNickname = authorSnapshot
        } else if let contactCard, contactCard.kind == .individual {
            self.forwardNickname = contactCard.nickname ?? contactCard.name
        }
    }
    
    public func tryToLoadNickname() -> String {
        if let groupAuthor = resolvedGroupchatAuthorDisplayName(
            userElement: nil,
            references: references.toArray()
        ) {
            return groupAuthor
        }
        if let authorSnapshot = nonEmptyAuthorValue(forwardNickname) {
            return authorSnapshot
        }
        if owner == forwardJid,
           let accountName = nonEmptyAuthorValue(
               AccountManager.shared.find(for: owner)?.username
           ) {
            return accountName
        }
        if let nickname = localDisplayName(forwardJid) { return nickname }
        if let card = ForwardContactDataCodec.matchingCard(for: forwardJid, references: references.toArray()),
           card.kind == .group {
            return card.nickname ?? card.name
        }
        return forwardJid
    }

    private func localDisplayName(_ jid: String) -> String? {
        do {
            let realm = try WRealm.safe()
            if let nickname = nonEmptyAuthorValue(
                realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: RosterStorageItem.genPrimary(
                        jid: jid,
                        owner: owner
                    )
                )?.displayName
            ) {
                return nickname
            }
        } catch {
            DDLogDebug("MessageForwardsInlineStorageItem: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    private func nonEmptyAuthorValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }
    
    public final func createRefBody(_ attrs: [NSAttributedString.Key: Any], searchedText: String? = nil, searchedTextColor: UIColor? = nil) -> NSAttributedString {
        let mentionColor = AccountColorManager.shared
            .palette(for: forwardJid.isNotEmpty ? forwardJid : owner)
            .tint700
        let formattedReferences = Array(references).compactMap { reference -> ChatAttributedBodyReference? in
            guard reference.kind == .markup || reference.kind == .mention else { return nil }
            return ChatAttributedBodyReference(
                storageReference: reference,
                mentionColor: mentionColor
            )
        }
        return ChatAttributedBodyFormatter.format(
            body: body,
            references: formattedReferences,
            attributes: attrs,
            searchedText: searchedText,
            searchedTextColor: searchedTextColor
        )
    }
    
}
