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

    
    
    
    func configureInline(_ messageContainer: XMPPMessage, parentId: String, owner: String, jid: String, opponent: String, outgoing: Bool, date: Date, forwardJid: String?) {
        self.messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        self.primary = [parentId, messageId].prp()
        self.references.append(objectsIn: parseReferences(messageContainer, primary: self.primary, jid: jid, owner: owner))
        self.subforwards.append(objectsIn: parseInlineMessages(messageContainer, parentId: self.primary, jid: jid, owner: owner))
        let groupchatRef = messageContainer
            .element(forName: "x",xmlns: "https://xabber.com/protocol/groups")?
            .element(forName: "reference",xmlns: "https://xabber.com/protocol/references")
        self.body = messageContainer
            .body?
            .xmlEscaping(reverse: false)
            .excludeFromBody(messageContainer.elements(forName: "reference"), groupchat: groupchatRef) ?? ""
        self.jid = jid
        self.owner = owner
        self.opponent = opponent
        self.isOutgoing = outgoing
        self.originalDate = date
        self.forwardJid = forwardJid ?? ""
    }
    
    public func tryToLoadNickname() -> String {
        do {
            let realm = try WRealm.safe()
            if self.owner == self.forwardJid {
                return AccountManager.shared.find(for: self.owner)?.username ?? forwardJid
            }
            if let nickname = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.forwardJid, owner: self.owner))?.displayName {
                return nickname
            }
        } catch {
            DDLogDebug("MessageForwardsInlineStorageItem: \(#function). \(error.localizedDescription)")
        }
        return self.forwardJid
    }
    
    public final func createRefBody(_ attrs: [NSAttributedString.Key: Any], searchedText: String? = nil, searchedTextColor: UIColor? = nil) -> NSAttributedString {
        let string = NSMutableAttributedString(string: body.trimmingCharacters(in: .newlines))
        string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5
        paragraph.allowsDefaultTighteningForTruncation = true
        for reference in references {
            if reference.end <= reference.begin { continue }
            if reference.end > body.count { continue }
            switch reference.kind {
            case .markup:
                if let styles = reference.metadata?["styles"] as? [String] {
                    for style in styles {
                        if style == "bold" {
                            string.addAttribute(NSAttributedString.Key.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).bold(), range: reference.range)
                        }
                        if style == "italic" {
                            if styles.contains("bold") {
                                string.addAttribute(NSAttributedString.Key.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).boldItalic(), range: reference.range)
                            } else {
                                string.addAttribute(NSAttributedString.Key.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).italic(), range: reference.range)
                            }
                        }
                        if style == "underline" {
                            string.addAttribute(NSAttributedString.Key.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: reference.range)
                        }
                        if style == "strike" {
                            string.addAttribute(NSAttributedString.Key.strikethroughStyle, value: 1, range: reference.range)
//                            string.addAttribute(NSAttributedString.Key.strikethroughColor, value: MDCPalette.grey.tint900.cgColor, range: reference.range)
                        }
                        if style == "uri" {
                            if let url = reference.metadata?["uri"] as? String {
                                string.addAttribute(NSAttributedString.Key.link, value: url, range: reference.range)
                            }
                        }
                    }
                }
            default: break
            }
        }
        if let searchedText = searchedText {
            let range = (string.string as NSString).range(of: searchedText, options: [.caseInsensitive, .diacriticInsensitive])
            string.addAttribute(.backgroundColor, value: searchedTextColor ?? MDCPalette.blue.tint200, range: range)
        }
        string.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        if string.string.starts(with: "\n") {
            string.deleteCharacters(in: NSRange(0..<"\n".count))
        }
        return string
    }
    
}
