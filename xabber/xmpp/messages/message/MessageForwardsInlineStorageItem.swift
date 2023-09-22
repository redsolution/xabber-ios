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
    
    struct Model {
        let messageId: String
        let parentId: String
        let owner: String
        let jid: String
        let kind_: String
        let body: String
        let forwardJid: String
        let forwardNickname: String
        let isOutgoing: Bool
        let originalDate: Date?
        let subforwards: [Model]
        let references: [MessageReferenceStorageItem.Model]
        
        var kind: Kind {
            get {
                return Kind(rawValue: kind_) ?? .text
            }
        }
        
        var displayedBody: String {
            get {
                switch kind {
                case .text, .quote:
                    return body
                case .files:
                    let count = references.filter{ $0.kind != .groupchat }.count
                    if count == 1 {
                        if let sizeInBytes = references.filter({ $0.kind != .groupchat }).first?.sizeInBytes {
                            return "File, \(sizeInBytes)".localizeString(id: "chat_message_file_count", arguments: ["\(sizeInBytes)"])
                        }
                        return "File".localizeString(id: "chat_message_file", arguments: [])
                    } else {
                        return "\(count) attached files".localizeString(id: "chat_message_attached_files", arguments: ["\(count)"])
                    }
                case .images:
                    let count = references.filter{ $0.kind != .groupchat }.count
                    if count == 1 {
                        if let sizeInBytes = references.filter({ $0.kind != .groupchat }).first?.sizeInBytes {
                            return "Image, \(sizeInBytes)".localizeString(id: "chat_message_image_count", arguments: ["\(sizeInBytes)"])
                        }
                        return "Image".localizeString(id: "chat_message_image", arguments: [])
                    } else {
                        return "\(count) attached images".localizeString(id: "chat_message_attached_images", arguments: ["\(count)"])
                    }
                case .videos:
                    let count = references.filter{ $0.kind != .groupchat }.count
                    if count == 1 {
                        if let sizeInBytes = references.filter({ $0.kind != .groupchat }).first?.sizeInBytesRaw {
                            return "Video, \(sizeInBytes)".localizeString(id: "chat_message_video_count", arguments: ["\(sizeInBytes)"])
                        }
                        return "Video".localizeString(id: "chat_message_video", arguments: [])
                    } else {
                        return "\(count) attached videos".localizeString(id: "chat_messages_attached_videos", arguments: ["\(count)"])
                    }
                case .voice:
                    if let duration = references.first(where: { $0.kind == .voice })?.metadata?["duration"] as? Double,
                        let durationInterval = TimeInterval(exactly: duration) {
                        return "Voice message, \(durationInterval.minuteFormatedString)".localizeString(id: "chat_message_voice_duration", arguments: ["\(durationInterval.minuteFormatedString)"])
                    }
                    return "Voice message".localizeString(id: "chat_message_voice", arguments: [])
                }
            }
        }
        
        var attributedGroupAuthor: NSAttributedString {
            get {
                let author: String
                if let nickname = self.groupchatAuthorNickname {
                    author = nickname
                } else if self.isOutgoing {
                    author = AccountManager.shared.find(for: owner)?.username ?? self.owner
                } else if self.forwardNickname.isNotEmpty {
                    author = self.forwardNickname
                } else {
                    author = self.forwardJid
                }
                return ContactChatMetadataManager
                    .shared
                    .get(author,
                         for: self.owner,
                         badge: self.groupchatAuthorBadge ?? "",
                         role: self.groupchatMetadata?["role"] as? String ?? "member")
                    .getAttributedNickname([.font: UIFont.systemFont(ofSize: 14, weight: .medium)])
            }
        }
        
        var attributedAuthor: NSAttributedString {
            get {
                let author: String
                if let nickname = self.groupchatAuthorNickname {
                    author = nickname
                } else if self.isOutgoing {
                    author = AccountManager.shared.find(for: owner)?.username ?? self.owner
                } else if self.forwardNickname.isNotEmpty {
                    author = self.forwardNickname
                } else {
                    author = self.forwardJid
                }
                return ContactChatMetadataManager
                    .shared
                    .get(author,
                         for: self.owner,
                         badge: self.groupchatAuthorBadge ?? "",
                         role: self.groupchatMetadata?["role"] as? String ?? "member")
                    .getAttributedNickname([.font: UIFont.systemFont(ofSize: 14, weight: .medium)])
            }
        }
        
        var forwardedBody: NSAttributedString {
            get {
                let formattedBody: NSMutableAttributedString
                formattedBody = NSMutableAttributedString(string: subforwards.count <= 1 ? "Forwarded message"
                                                            .localizeString(id: "chat_message_forwarded_message", arguments: []) :
                                "\(subforwards.count) forwarded messages"
                                                            .localizeString(id: "chat_message_some_forwarded_messages", arguments:  ["\(subforwards.count)"]))
                let range = NSRange(location: 0, length: formattedBody.mutableString.length)
                formattedBody.addAttribute(.foregroundColor, value: MDCPalette.blue.tint700, range: range)
                formattedBody.addAttribute(.font, value: UIFont.systemFont(ofSize: 16.0), range: range)
                formattedBody.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                return formattedBody
            }
        }
        
        var attributedBody: NSAttributedString {
            get {
                return applyReferences([.font : UIFont.systemFont(ofSize: 16.0)])
            }
        }
        
        var attributedQuotes: [MessageStorageItem.QuoteBodyItem] {
            get {
                return quoteBody([.font : UIFont.systemFont(ofSize: 16.0)])
            }
        }
        
        
        internal func quoteBody(_ attrs: [NSAttributedString.Key: Any]) -> [MessageStorageItem.QuoteBodyItem] {
            let quoteRanges: [NSRange] = self.references
                .filter{ $0.kind == .quote }
                .compactMap { return $0.range }
                .sorted(by: { $0.lowerBound < $1.lowerBound })
            
            if quoteRanges.isEmpty {
                return []
            }
            
            let refBody = applyReferences(attrs)
            var ranges = quoteRanges
            if let first = quoteRanges.first?.lowerBound,
                first > 1 {
                ranges.append(NSRange(0..<first-1))
            }
            if let last = quoteRanges.last?.upperBound,
                last+1 < refBody.string.count {
                ranges.append(NSRange(last+1..<refBody.string.count))
            }
            
            if quoteRanges.count > 1 {
                quoteRanges.enumerated().forEach { (offset, element) in
                    if offset >= quoteRanges.count - 1 { return }
                    if quoteRanges[offset + 1].lowerBound != element.upperBound + 1,
                        element.upperBound+1 < quoteRanges[offset + 1].lowerBound-1 {
                        ranges.append(NSRange((element.upperBound+1)..<quoteRanges[offset + 1].lowerBound-1))
                    }
                }
            }
            ranges = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
            return ranges.compactMap { (range) -> MessageStorageItem.QuoteBodyItem? in
                let bodyCopy = NSMutableAttributedString(attributedString: refBody)
                if range.lowerBound != 0 {
                    bodyCopy.deleteCharacters(in: NSRange(0..<range.lowerBound))
                }
                if (range.upperBound+1) != bodyCopy.string.count {
                    bodyCopy.deleteCharacters(in: NSRange((range.length)..<(bodyCopy.string.count)))
                }
                return MessageStorageItem.QuoteBodyItem(body: bodyCopy, isQuote: quoteRanges.contains(range))
            }
        }
        
        internal func applyReferences(_ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
            let string = NSMutableAttributedString(string: body)
            string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.allowsDefaultTighteningForTruncation = true
            for reference in references {
                if reference.end <= reference.begin { continue }
                if reference.end > body.count { continue }
                switch reference.kind {
                case .markup:
                    if let styles = reference.metadata?["styles"] as? [String] {
                        for style in styles {
                            if style == "bold" {
                                string.addAttribute(NSAttributedString.Key.font, value: UIFont.preferredFont(forTextStyle: .body).bold(), range: reference.range)
                            }
                            if style == "italic" {
                                if styles.contains("bold") {
                                    string.addAttribute(NSAttributedString.Key.font, value: UIFont.preferredFont(forTextStyle: .body).boldItalic(), range: reference.range)
                                } else {
                                    string.addAttribute(NSAttributedString.Key.font, value: UIFont.preferredFont(forTextStyle: .body).italic(), range: reference.range)
                                }
                            }
                            if style == "underline" {
                                string.addAttribute(NSAttributedString.Key.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: reference.range)
                            }
                            if style == "strike" {
                                string.addAttribute(NSAttributedString.Key.strikethroughStyle, value: 1, range: reference.range)
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
            string.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
            return string
        }
        
        var groupchatMetadata: [String: Any]? {
            get {
                return references.first(where: { $0.kind == .groupchat })?.metadata
            }
        }
        
        var groupchatAuthorJid: String? {
            get {
                return groupchatMetadata?["jid"] as? String
            }
        }
        
        var groupchatAuthorNickname: String? {
            get {
                return groupchatMetadata?["nickname"] as? String ?? groupchatMetadata?["jid"] as? String
            }
        }
        
         var groupchatAuthorBadge: String? {
            get {
                return groupchatMetadata?["badge"] as? String ?? (groupchatMetadata?["role"] as? String)?.capitalized
            }
        }
        
        var groupchatUserAvatarPath: String? {
            get {
                if let avatarId = groupchatMetadata?["id"] as? String {
                    return [avatarId, jid].prp()
                }
                return nil
            }
        }
    }
    
    enum Kind: String {
        case text = "text"
        case images = "images"
        case videos = "videos"
        case files = "files"
        case voice = "voice"
        case quote = "quote"
    }
    
    override static func indexedProperties() -> [String] {
        return ["messageId"]
    }
    
    override static func ignoredProperties() -> [String] {
        return [
            "canCheckRealmAccessedLinks",
            "model",
        ]
    }
    
    var model: Model?
    
    public final func loadModel() -> Model? {
        self.model = Model(
            messageId: self.messageId,
            parentId: self.parentId,
            owner: self.owner,
            jid: self.jid,
            kind_: self.kind_,
            body: self.body,
            forwardJid: self.forwardJid,
            forwardNickname: self.forwardNickname,
            isOutgoing: self.isOutgoing,
            originalDate: self.originalDate,
            subforwards: self.subforwards.compactMap { $0.loadModel() },
            references: self.references.toArray().compactMap { $0.loadModel() }
        )
        return self.model
    }
    
    @objc dynamic var messageId: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    
    @objc dynamic var kind_: String = Kind.text.rawValue
    @objc dynamic var parentId: String = ""
    @objc dynamic var body: String = ""
    
    @objc dynamic var forwardJid: String = ""
    @objc dynamic var forwardNickname: String = ""
    
    @objc dynamic var isOutgoing: Bool = false
    @objc dynamic var originalDate: Date? = nil
    
    @objc dynamic var rosterItem: RosterStorageItem? = nil
    
    var subforwards: List<MessageForwardsInlineStorageItem> = List<MessageForwardsInlineStorageItem>()
    var references: List<MessageReferenceStorageItem> = List<MessageReferenceStorageItem>()
    
    var canCheckRealmAccessedLinks: Bool = true
    
    var kind: Kind {
        get {
            return Kind(rawValue: kind_) ?? .text
        } set {
            kind_ = newValue.rawValue
        }
    }
    
    
    func configureInline(_ messageContainer: XMPPMessage, parentId: String, owner: String, jid: String, outgoing: Bool, date: Date, forwardJid: String?) {
        self.references.append(objectsIn: parseReferences(messageContainer, jid: jid, owner: owner))
        self.subforwards.append(objectsIn: parseInlineMessages(messageContainer, parentId: parentId, jid: jid, owner: owner, canAccessRealm: self.canCheckRealmAccessedLinks))
        self.subforwards.forEach { $0.canCheckRealmAccessedLinks = self.canCheckRealmAccessedLinks }
        let groupchatRef = messageContainer
            .element(forName: "x",xmlns: "https://xabber.com/protocol/groups")?
            .element(forName: "reference",xmlns: "https://xabber.com/protocol/references")
        self.body = messageContainer
            .body?
            .xmlEscaping(reverse: false)
            .excludeFromBody(messageContainer.elements(forName: "reference"), groupchat: groupchatRef) ?? ""
        self.jid = jid
        self.owner = owner
        self.isOutgoing = outgoing
        self.originalDate = date
        self.messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        self.forwardJid = forwardJid ?? ""
        updateDisplayMode()
    }
    
    func updateDisplayMode() {
        if references.contains(where: { $0.kind == .voice }) {
            self.kind = .voice
        } else if references.filter({ $0.kind == .media }).count > 0 && references.filter({ $0.mimeType == MimeIconTypes.image.rawValue }).count == references.filter({ $0.kind == .media }).count {
            self.kind = .images
        } else if references.contains(where: { $0.kind == .media && $0.mimeType == "video" }) {
            self.kind = .videos
        } else if references.contains(where: { $0.kind == .media }) {
            self.kind = .files
        } else if references.contains(where: { $0.kind == .quote }) {
            self.kind = .quote
        } else {
            self.kind = .text
        }
    }
    
}
