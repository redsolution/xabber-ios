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
import KissXML

class NetworkManager: NSObject {
    private var url: URL
    private var jwt: String
    private var jid: String
    
    public var delegate: PushPayloadDelegate? = nil
    
    init(service url: String, jid: String, jwt: String) {
        guard let url = URL(string: url) else {
            fatalError()
        }
        self.jid = jid
        self.jwt = jwt
        self.url = url
    }
    
    public final func getMessage(host: String, messageId: String, by: String?) {
        var components = URLComponents(string: "\(url.absoluteString)/archive")!
        components.queryItems = []
        components.queryItems?.append(URLQueryItem(name: "id", value: messageId))
        if let by = by {
            components.queryItems?.append(URLQueryItem(name: "by", value: by))
        }
        
        let formedUrl = components.url!
        var request = URLRequest(url: formedUrl)
        request.httpMethod = "GET"
        request.addValue(host, forHTTPHeaderField: "Xmpp-Domain")
        request.addValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            if let data = data,
               let message = String(data: data, encoding: .utf8),
               let document = try? DDXMLDocument(xmlString: "<root>\(message)</root>", options: 0),
               let element = document.rootElement()?.elements(forName: "message").first {
                self.read(message: element)
            } else {
                if let data = data,
                   let message = String(data: data, encoding: .utf8) {
                    self.delegate?.didDisconnectWithError(message)
                } else {
                    self.delegate?.didDisconnectWithError("\((response as? HTTPURLResponse)?.description ?? "")")
                }
                
            }
        }
        task.resume()
    }
    
    private final func read(message stanza: DDXMLElement) {
        if let message = stanza
            .elements(forName: "result")
            .first?
            .elements(forName: "forwarded")
            .first?
            .elements(forName: "message")
            .first {
            var payload: [String: String] = ["stanza": stanza.compactXMLString()]
            var groupchatReference: DDXMLElement? = nil
            if let authElement = message.elements(forName: "authenticated-key-exchange").first {
                if let verificationElement = authElement.elements(forName: "verification-start").first {
                    let from = message.attribute(forName: "from")?.stringValue?.split(separator: "@").first as? String
                    self.delegate?.didReceiveStartVerification(payload: ["from": from ?? "somebody"])
                    return
                }
            }
            if let groupchatReferences = message.elements(forName: "x").first(where: { $0.xmlns() == "https://xabber.com/protocol/groups" })?.elements(forName: "reference") {
                print("GROUPCHAT", groupchatReferences)
                if let nickname = getGrouchatUserNickname(groupchatReferences) {
                    payload["nickname"] = nickname
                }
                if let groupchatFrom = getGrouchatUserJid(groupchatReferences) {
                    payload["groupchatFrom"] = groupchatFrom
                }
                groupchatReference = groupchatReferences.first
            }
            
            if let invite = message.elements(forName: "invite").first(where: { $0.xmlns() == "https://xabber.com/protocol/groups#invite" }) {
                payload["invite"] = "true"
                if let inviteToJid = invite.attribute(forName: "jid")?.stringValue {
                    payload["invite_to_jid"] = inviteToJid
                }
                if let privacy = message.elements(forName: "x").first(where: { $0.xmlns() == "https://xabber.com/protocol/groups" })?.elements(forName: "privacy").first?.stringValue {
                    switch privacy {
                    case "incognito": payload["invite_kind"] = "incognito"
                    case "public": payload["invite_kind"] = "group"
                    default: payload["invite_kind"] = "group"
                    }
                }
                if (message.elements(forName: "x").first(where: { $0.xmlns() == "https://xabber.com/protocol/groups" })?.elements(forName: "parent-chat").count ?? 0) > 0 {
                    payload["invite_kind"] = "peer-to-peer"
                }
            }
            
            if let from = message.attribute(forName: "from")?.stringValue?.split(separator: "/").first {
                payload["from"] = "\(from)"
            }
            if let body = message.elements(forName: "body").first?.stringValue?.excludeFromBody(message.elements(forName: "reference"), groupchat: groupchatReference) {
                payload["body"] = body
            }
            if let stanzaId = message
                .elements(forName: "stanza-id")
                .filter({ $0.attribute(forName: "by")?.stringValue == self.jid })
                .first?
                .attribute(forName: "id")?
                .stringValue {
                payload["stanzaId"] = stanzaId
            }
            let references = message.elements(forName: "reference")
            var imagesCount: Int = 0
            var filesCount: Int = 0
            var filename: String = ""
            var isVoiceMessage: Bool = false
            for ref in references {
                if ref.xmlns() == "https://xabber.com/protocol/references",
                    let kind = getReferenceType(ref) {
                    switch kind {
                    case "voice":
                        isVoiceMessage = true
                    case "media":
                        if let file = ref.elements(forName: "file-sharing").first?.elements(forName: "file").first,
                            let uri = ref.elements(forName: "file-sharing").first?.elements(forName: "sources").first?.elements(forName: "uri").compactMap({ return $0.stringValue }).first(where: { URL(string: $0) != nil }) {
                            if let mediaType = file.elements(forName: "media-type").first?.stringValue,
                               mediaType == "image" {
                                if !payload.keys.contains("imageUrls") {
                                    payload["imageUrls"] = uri
                                }
                                imagesCount += 1
                            } else {
                                if let name = file.elements(forName: "name").first?.stringValue {
                                    filename = name
                                } else {
                                    filename = URL(string: uri)?.lastPathComponent ?? uri
                                }
                                filesCount += 1
                            }
                        }
                    default: break
                    }
                }
            }
            if (payload["body"]?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty {
                if isVoiceMessage {
                    payload["body"] = "Voice message"
                } else if filesCount > 0 {
                    payload["body"] = (filesCount + imagesCount) == 1 ? "File: \(filename)" : "\(filesCount + imagesCount) files"
                } else if imagesCount > 0 {
                    payload["body"] = imagesCount == 1 ? "Image" : "\(imagesCount) images"
                }
            }
            let out = payload
            Task {
                await delegate?.didUpdateContent(payload: out)
            }
        }
    }
    
    internal func getGrouchatUserNickname(_ references: [DDXMLElement]) -> String? {
        if let user = references.first(where: { ($0.attribute(forName: "type")?.stringValue ?? "none") == "mutable" })?.elements(forName: "user").first {
            return user.elements(forName: "nickname").first?.stringValue
        }
        return nil
    }
    
    internal func getGrouchatUserJid(_ references: [DDXMLElement]) -> String? {
        if let user = references.first(where: { ($0.attribute(forName: "type")?.stringValue ?? "none") == "mutable" })?.elements(forName: "user").first {
            return user.elements(forName: "jid").first?.stringValue
        }
        return nil
    }
    
    func getReferenceType(_ ref: DDXMLElement) -> String? {
        if !ref.elements(forName: "voice-message").isEmpty {
            return "voice"
        } else if !ref.elements(forName: "file-sharing").isEmpty {
            return "media"
        }
        return nil
    }
}

extension String {
    func xmlEscaping(reverse: Bool) -> String {
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
       
    func excludeFromBody(_ references: [DDXMLElement], groupchat: DDXMLElement?) -> String {
        var out: String = self.xmlEscaping(reverse: false)
        var mutableReferences: [DDXMLElement] = references
        if let groupchatRef = groupchat {
            mutableReferences.append(groupchatRef)
        }
        if self.isEmpty { return self }
        for reference in mutableReferences
            .sorted(by: { return (Int($0.attribute(forName: "begin")?.stringValue ?? "0") ?? 0) < (Int($1.attribute(forName: "begin")?.stringValue ?? "0") ?? 0) }) {
            if reference.xmlns() != "https://xabber.com/protocol/references" { continue }
            let offset = self.xmlEscaping(reverse: false).count - out.count
            var begin = (Int(reference.attribute(forName: "begin")?.stringValue ?? "0") ?? 0) - offset
            var end = (Int(reference.attribute(forName: "end")?.stringValue ?? "0") ?? 0) - offset// + 1
            let kind = reference.attribute(forName: "type")?.stringValue ?? "none"
            if end > out.count {
                end = out.count - 1
            }
            if begin < 0 {
                begin = 0
            }
            if begin >= end { continue }
            switch kind {
            case "mutable":
                if let range = Range<String.Index>(NSRange(begin..<end), in: out) {
                    out.removeSubrange(range)
                }
            default:
                break
            }
        }
        return out.xmlEscaping(reverse: true)
    }
}

protocol PushPayloadDelegate {
    func didDisconnectWithError(_ error: String)
    func didUpdateContent(payload: [String: String]) async
    func didReceiveSync(stanza: String)
    func didReceiveStartVerification(payload: [String: String])
}
