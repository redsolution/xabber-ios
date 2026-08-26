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

    
    
    
    func configureInline(
        _ messageContainer: XMPPMessage,
        parentId: String,
        owner: String,
        jid: String,
        opponent: String,
        outgoing: Bool,
        date: Date?,
        forwardJid: String?,
        forwardDepth: Int = 1
    ) {
        self.owner = owner
        self.jid = jid
        self.opponent = opponent
        self.messageId = getUniqueMessageId(messageContainer, owner: owner)
        self.primary = [parentId, messageId].prp()
        let parsedReferences = parseReferences(
            messageContainer,
            primary: self.primary,
            jid: jid,
            owner: owner
        )
        self.references.append(objectsIn: forwardDepth >= inlineForwardMaximumDepth
            ? parsedReferences.filter { $0.kind != .forward }
            : parsedReferences
        )
        self.subforwards.append(objectsIn: parseInlineMessages(
            messageContainer,
            parentId: self.primary,
            jid: jid,
            owner: owner,
            depth: forwardDepth
        ))
        let bodyReferences = messageContainer.elements(forName: "reference")
        let removableBodyReferences = forwardDepth >= inlineForwardMaximumDepth
            ? bodyReferences.filter { getReferenceType($0) != "forward" }
            : bodyReferences
        self.body = messageContainer
            .body?
            .xmlEscaping(reverse: false)
            .excludeFromBody(removableBodyReferences, groupchat: nil) ?? ""
        self.isOutgoing = outgoing
        self.originalDate = date
        self.forwardJid = forwardJid ?? ""
        if let authorSnapshot = resolvedGroupchatAuthorDisplayName(
            userElement: nil,
            references: references.toArray()
        ) {
            self.forwardNickname = authorSnapshot
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
        do {
            let realm = try WRealm.safe()
            if let nickname = nonEmptyAuthorValue(
                realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: RosterStorageItem.genPrimary(
                        jid: forwardJid,
                        owner: owner
                    )
                )?.displayName
            ) {
                return nickname
            }
        } catch {
            DDLogDebug("MessageForwardsInlineStorageItem: \(#function). \(error.localizedDescription)")
        }
        return forwardJid
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
