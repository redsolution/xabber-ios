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
//    XMPP-Domain: redsolution.com
//    auth bearer
    private var url: URL
    private var token: String
    private var jid: String
    private var password: String
    
    public var delegate: PushPayloadDelegate? = nil
    
    init(service url: String, jid: String, token: String, password: String) {
        guard let url = URL(string: url) else {
            fatalError()
        }
        self.jid = jid
        self.password = password
        self.token = token
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
        request.addValue(host, forHTTPHeaderField: "XMPP-Domain")
        if token.isNotEmpty {
            request.addValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
        } else if password.isNotEmpty {
            let credentials = "\(jid):\(password)".toBase64()
            request.addValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        } else {
            fatalError()
        }
//        print("request", request, request.httpMethod, request.httpBody, request.allHTTPHeaderFields)
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            if let data = data,
               let message = String(data: data, encoding: .utf8),
               let document = try? DDXMLDocument(xmlString: "<root>\(message)</root>", options: 0),
               let element = document.rootElement()?.elements(forName: "message").first {
                self.read(message: element)
                print(element.prettyXMLString())
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
            delegate?.didUpdateContent(payload: payload)
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
