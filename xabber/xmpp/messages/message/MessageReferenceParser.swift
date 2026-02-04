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
import XMPPFramework
import RealmSwift

func parseSystemMessageMetadata(_ message: XMPPMessage) -> [String: Any]? {
//    print(message.prettyXMLString())
    for item in message.elements(forName: "x") {//}.forEach {
//        item in
        switch item.xmlns() {
        case "https://xabber.com/protocol/groups#create":
            return ["type": "create"]
        case "https://xabber.com/protocol/groups#join":
            return ["type": "join"]
        case "https://xabber.com/protocol/groups#left":
            return ["type": "left"]
        case "https://xabber.com/protocol/groups#kick":
            return ["type": "kick",
                    "count": item.elements(forName: "user").count,
                    "users": item
                        .elements(forName: "user")
                        .compactMap { return $0.attributeStringValue(forName: "id")}
                        .joined(separator: ",") ]
        case "https://xabber.com/protocol/groups#update":
            return ["type": "update"]
        case "https://xabber.com/protocol/groups#user-updated":
            return ["type": "user-update"]
        case "https://xabber.com/protocol/groups#system-message":
            return ["type": "user-update"]
        default: break
        }
    }
    return nil
}

func parseInlineMessages(_ message: XMPPMessage, parentId: String, jid: String, owner: String) -> [MessageForwardsInlineStorageItem] {
       
    func delayedDate(delay dateString: String) -> Date? {
        var date: Date? = nil
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        date = dateFormatter.date(from: dateString)
        if date == nil {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            date = dateFormatter.date(from: dateString)
        }
        return date
    }
    
    func parse(_ ref: DDXMLElement) -> [MessageForwardsInlineStorageItem] {
        guard ref.xmlns() == "https://xabber.com/protocol/references",
            ref.attributeStringValue(forName: "type") == "mutable",
            let forwarded = ref.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"),
            let delay = forwarded.element(forName: "delay", xmlns: "urn:xmpp:delay")?.attributeStringValue(forName: "stamp"),
            let messageDate = delayedDate(delay: delay),
            let message = forwarded.element(forName: "message") else {
                return []
        }
        let messageContainer = XMPPMessage(from: message)
        guard let to = messageContainer.to?.bare else { return [] }
        let from = messageContainer.from?.bare
        var outgoing: Bool = owner != to
        if  messageContainer.from?.bare != owner {
            outgoing = false
        }
        var out: [MessageForwardsInlineStorageItem] = []
        let item: MessageForwardsInlineStorageItem = MessageForwardsInlineStorageItem()
        item.configureInline(messageContainer,
                             parentId: parentId,
                             owner: owner,
                             jid: jid,
                             opponent: (outgoing ? messageContainer.to?.bare : messageContainer.from?.bare) ?? jid,
                             outgoing: outgoing,
                             date: messageDate,
                             forwardJid: from)
        
        if let opponent = (outgoing ? messageContainer.to?.bare : messageContainer.from?.bare) {
            do {
                let realm = try WRealm.safe()
                item.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [opponent, owner].prp())
            } catch {
                DDLogDebug("\(#function). \(error.localizedDescription)")
            }
        }
        out.append(item)
        return out
    }
    
    var out: [MessageForwardsInlineStorageItem] = []
    
    for ref in message.elements(forName: "reference") {
        out.append(contentsOf: parse(ref))
    }
    
    return out
}

func getReferenceType(_ ref: DDXMLElement) -> String? {
    if ref.element(forName: "voice-message",
                   xmlns: "https://xabber.com/protocol/voice-messages") != nil {
        return "voice"
    } else if ref.element(forName: "system-message",
                          xmlns: "https://xabber.com/protocol/system-message") != nil {
        return "system-message"
    } else if ref.element(forName: "file-sharing",
                          xmlns: "https://xabber.com/protocol/files") != nil {
        return "media"
    } else if ref.attributeStringValue(forName: "type") == "decoration" {
        if ref.element(forName: "quote", xmlns: "https://xabber.com/protocol/markup") != nil {
            return "quote"
        }
        return "markup"
    } else if ref.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0") != nil {
        return "forward"
    } else if ref.element(forName: "user") != nil {
        return "groupchat"
    }
    return nil
}

func parseReferences(_ message: XMPPMessage, primary: String, jid: String, owner: String, echo: Bool = false) -> [MessageReferenceStorageItem] {
    var out: [MessageReferenceStorageItem] = []
    let escapingBody = (message.body ?? "").xmlEscaping(reverse: false)
    let references = message.elements(forName: "reference")
    
    let messageDate = getDelayedDate(message) ?? Date()
    
    let groupchatRef = message
        .element(forName: "x",xmlns: "https://xabber.com/protocol/groups")?
        .element(forName: "reference",xmlns: "https://xabber.com/protocol/references")
    
    func parse(_ ref: DDXMLElement) -> MessageReferenceStorageItem? {
        guard ref.xmlns() == "https://xabber.com/protocol/references",
            let kind = getReferenceType(ref) else {
                return nil
            }
        let begin_unwr = ref.attributeIntegerValue(forName: "begin", withDefaultValue: 0)
        let end_unwr = ref.attributeIntegerValue(forName: "end", withDefaultValue: 0)// + 1
        let begin = "\(escapingBody.prefix(begin_unwr))".excludeFromBody(references, groupchat: groupchatRef).count
        let end = "\(escapingBody.prefix(end_unwr))".excludeFromBody(references, groupchat: groupchatRef).count
        let reference = MessageReferenceStorageItem()
        
        
        reference.conversationType = conversationTypeByMessage(message)
        reference.jid = jid
        reference.owner = owner
        reference.begin = begin
        reference.end = end
        reference.kind_ = kind
        reference.sentDate = messageDate
        var metadata: [String: Any] = [:]
        switch reference.kind {
            case .voice:
                guard let voice = ref.element(forName: "voice-message",
                                              xmlns: "https://xabber.com/protocol/voice-messages"),
                    let fileSharing = voice.element(forName: "file-sharing",
                                                  xmlns: "https://xabber.com/protocol/files"),
                    let file = fileSharing.element(forName: "file"),
                    let sources = fileSharing.element(forName: "sources"),
                      let uri = sources.elements(forName: "uri").compactMap({ return $0.stringValue }).first(where: { URL(string: $0.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? $0) != nil }) else {
                        return nil
                    }
                if let encryptedElement = file.element(forName: "encrypted", xmlns: "urn:xmpp:esfs:0"),
                   let encryptionKey = encryptedElement.element(forName: "key")?.stringValue,
                   let iv = encryptedElement.element(forName: "iv")?.stringValue {
                    metadata["encryption-key"] = encryptionKey
                    metadata["iv"] = iv
                }
                let mediaType = file.element(forName: "media-type")?.stringValue ?? ""
                metadata["media-type"] = mediaType
                reference.mimeType = "audio"//MimeIcon(mediaType).value.rawValue
                metadata["name"] = file.element(forName: "name")?.stringValue ?? ""
                metadata["duration"] = file.element(forName: "duration")?.stringValueAsNSInteger() ?? 0
                metadata["size"] = file.element(forName: "size")?.stringValueAsNSInteger() ?? 0
                metadata["hash"] = file.element(forName: "hash")?.stringValue ?? ""
                let pcmRaw = file.element(forName: "meters")?.stringValue ?? ""
                if pcmRaw.isNotEmpty {
                    metadata["pcm"] = pcmRaw
                }
                metadata["uri"] = uri
                reference.url = uri
            case .media:
                guard let fileSharing = ref.element(forName: "file-sharing",
                                                    xmlns: "https://xabber.com/protocol/files"),
                    let file = fileSharing.element(forName: "file"),
                    let sources = fileSharing.element(forName: "sources"),
                      let uri = sources.elements(forName: "uri").compactMap({ return $0.stringValue }).first(where: { URL(string: $0.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") != nil }) else {
                        return nil
                    }
                
                var isEncrypted: Bool = false
                
                if let encryptedElement = file.element(forName: "encrypted", xmlns: "urn:xmpp:esfs:0"),
                   let encryptionKey = encryptedElement.element(forName: "key")?.stringValue,
                   let iv = encryptedElement.element(forName: "iv")?.stringValue {
                    metadata["encryption-key"] = encryptionKey
                    metadata["iv"] = iv
                    isEncrypted = true
                }
                
                let mediaType = file.element(forName: "media-type")?.stringValue ?? ""
                metadata["media-type"] = mediaType
                reference.mimeType = MimeIcon(mediaType).value.rawValue
                metadata["name"] = file.element(forName: "name")?.stringValue ?? ""
                metadata["height"] = file.element(forName: "height")?.stringValueAsNSInteger() ?? 0
                metadata["width"] = file.element(forName: "width")?.stringValueAsNSInteger() ?? 0
                metadata["size"] = file.element(forName: "size")?.stringValueAsNSInteger() ?? 0
                metadata["desc"] = file.element(forName: "desc")?.stringValue ?? ""
                metadata["hash"] = file.element(forName: "hash")?.stringValue ?? ""
                metadata["orientation"] = file.element(forName: "orientation")?.stringValue ?? ""
                metadata["video_duration"] = file.element(forName: "video_duration")?.stringValue ?? ""
                metadata["uri"] = uri
                reference.url = uri
                
                let conversationType = reference.conversationType
                let attachment = MessageMediaAttachmentStorageItem()
                attachment.primary = MessageMediaAttachmentStorageItem.genPrimary(jid: jid, owner: owner, url: uri, messagePrimary: primary)
                attachment.url_ = uri
                attachment.jid = jid
                attachment.owner = owner
                attachment.conversationType = conversationType
                attachment.archiveId = getStanzaId(message, owner: owner)
                attachment.metadata = metadata
                switch reference.mimeType {
                    case "image":
                        attachment.kind = .image
                    case "video":
                        attachment.kind = .video
                    case "audio":
                        attachment.kind = .audio
                    default:
                        attachment.kind = .file
                }
                attachment.date = messageDate
                attachment.outgoing = message.from?.bare == owner
                attachment.filename = file.element(forName: "name")?.stringValue ?? ""
                attachment.isDownloaded = false
                attachment.isEncrypted = isEncrypted
                attachment.sizeBytes = file.element(forName: "size")?.stringValueAsNSInteger() ?? 0
                attachment.metadata = metadata
                
                if let thumb = file.element(forName: "thumbnail"), let dataURI = thumb.attributeStringValue(forName: "uri") {
                    if let commaIndex = dataURI.firstIndex(of: ","),
                       dataURI.hasPrefix("data:image/") {
                        let base64String = String(dataURI[dataURI.index(after: commaIndex)...])
                        attachment.verySmallThumb = base64String
                    }
                }
                
                do {
                    let realm = try WRealm.safe()
                    if realm.object(ofType: MessageMediaAttachmentStorageItem.self, forPrimaryKey: attachment.primary) == nil {
                        if realm.isInWriteTransaction {
                            realm.add(attachment, update: .modified)
                        } else {
                            try realm.write {
                                realm.add(attachment, update: .modified)
                            }
                        }
                    }
                } catch {
                    DDLogDebug("MessageReferencePArser: \(#function). \(error.localizedDescription)")
                }
            case .markup:
                var styles: [String] = []
                if ref.element(forName: "bold") != nil { styles.append("bold") }
                if ref.element(forName: "underline") != nil { styles.append("underline") }
                if ref.element(forName: "strike") != nil { styles.append("strike") }
                if ref.element(forName: "italic") != nil { styles.append("italic") }
                if let uri = ref.element(forName: "link")?.stringValue {
                    styles.append("uri")
                    metadata["uri"] = uri
                    reference.url = uri
                }
                if styles.isNotEmpty {
                    metadata["styles"] = styles
                } else {
                    return nil
                }
            case .quote:
                metadata["marker"] = ">".xmlEscaping(reverse: false)
            case .systemMessage:
                if let timer = ref.element(forName: "system-message", xmlns: "https://xabber.com/protocol/system-message")?.element(forName: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeIntegerValue(forName: "timer") {
                    metadata["ephemeral-timer"] = timer
                }
            case .groupchat:
                guard let user = ref.element(forName: "user") else { return nil }
                metadata["id"] = user.attributeStringValue(forName: "id", withDefaultValue: "")
                metadata["jid"] = user.element(forName: "jid")?.stringValue ?? ""
                metadata["nickname"] = user.element(forName: "nickname")?.stringValue ?? ""
                metadata["role"] = user.element(forName: "role")?.stringValue ?? ""
                metadata["badge"] = user.element(forName: "badge")?.stringValue ?? ""
                if let avatarInfo = user.element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")?.element(forName: "info") {
                    metadata["avatar_uri"] = avatarInfo.attributeStringValue(forName: "url", withDefaultValue: "")
                    metadata["avatar_id"] = avatarInfo.attributeStringValue(forName: "id", withDefaultValue: "")
                }
            default: break
        }
        reference.metadata = metadata
//        print("Reference received: ", reference, ref.prettyXMLString ?? "")
        return reference
    }
    
    if let referenceElement = groupchatRef,
        let reference = parse(referenceElement) {
        out = [reference]
    }
    
    out.append(contentsOf: references.compactMap{ return parse($0) })
    return out
}

extension String {
    public func xmlEscaping(reverse: Bool) -> String {
        var out = self
        let symbols: [String: String] = [
            "<": "&lt;",
            ">": "&gt;",
            "\"": "&quot;",
            "\'": "&apos;",
        ]
        out = out.replacingOccurrences(of: reverse ? "&amp;" : "&",
                                       with: reverse ? "&" : "&amp;",
                                       options: [],
                                       range: Range<String.Index>(NSRange(location: 0,
                                                                          length: out.count), in: out))
        symbols.forEach {
            out = out.replacingOccurrences(of: reverse ? $0.value : $0.key,
                                           with: reverse ? $0.key : $0.value,
                                           options: [],
                                           range: Range<String.Index>(NSRange(location: 0,
                                                                              length: out.count), in: out))
        }
        return out
    }
    
    public func excludeFromBody(_ references: [DDXMLElement], groupchat: DDXMLElement?) -> String {
        var out: String = self
        var mutatedReferences: [DDXMLElement] = references
        if let groupchatReference = groupchat {
            mutatedReferences.append(groupchatReference)
        }
        if self.isEmpty { return self }
        for reference in mutatedReferences
            .sorted(by: { $0.attributeIntegerValue(forName: "begin") < $1.attributeIntegerValue(forName: "begin")}) {
            if reference.xmlns() != "https://xabber.com/protocol/references" { continue }
            let ref = MessageReferenceStorageItem()
            ref.kind_ = getReferenceType(reference) ?? "none"
            let offset = self.count - out.count
            var begin = reference.attributeIntegerValue(forName: "begin") - offset
            var end = reference.attributeIntegerValue(forName: "end") - offset// + 1
            if end > out.count {
                end = out.count - 1
            }
            if begin < 0 {
                begin = 0
            }
            if begin >= end { continue }
            ref.begin = begin
            ref.end = end
            switch ref.kind {
            case .media, .voice, .forward, .groupchat:
                if let range = Range<String.Index>(ref.range, in: out) {
                    out.removeSubrange(range)
                }
            case .quote:
                let marker =  ">".xmlEscaping(reverse: false)
                if let range = Range<String.Index>(ref.range, in: out) {
                    out = out.replacingOccurrences(of: marker, with: "", options: [], range: range)
                }
            default:
                break
            }
        }
        return out.xmlEscaping(reverse: true)
    }
}
