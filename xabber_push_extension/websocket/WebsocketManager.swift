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
import Starscream
import KissXML

public class WebsocketManager {
    
    enum ConnectionState: Equatable {
        case none
        case open
        case connect
        case authenticate(String)
        case resume
        case features
        case bind(String)
        case session(String)
        case authenticated
    }
    
    var socket: WebSocket
    var jid: String
    var host: String
    var username: String
    var resource: String
    var password: String
    var token: String
    var remoteArchiveJid: String?
    
    var stanzaId: String?
    var isMessageRequested: Bool = false
    var queryId: String = ""
    
    var isVcardRequest: Bool = false
    
    var vcardJid: String? = nil
    var isVCardRequested: Bool = false
    
    internal var supportXToken: Bool = false
    
    var state: ConnectionState = .none
    
    var delegate: PushPayloadDelegate? = nil
    var completionHandler: (() -> Void )? = nil
    public var prevPayload: [String: String] = [:]
    
    init(_ jid: String, resource: String, password: String, token: String, stanzaId: String?, websocketUrl: String?, remoteArchiveJid: String?, isVcardRequest: Bool = false, vcardJid: String? = nil) {
        self.jid = jid
        self.host = "\(jid.split(separator: "@").last ?? "")"
        self.username = "\(jid.split(separator: "@").first ?? "")"
        self.resource = [resource, String.randomString(length: 6, includeNumber: true)].joined(separator: "_")
        self.password = password
        self.token = token
        self.stanzaId = stanzaId
        self.remoteArchiveJid = remoteArchiveJid
        self.isVcardRequest = isVcardRequest
        self.vcardJid = vcardJid
//        self.socket = WebSocket(request: URLRequest(url: URL(string: "ws://\(host):\(port)/ws")!))
        var request: URLRequest
        if let websocketUrl = websocketUrl,
            let url = URL(string: websocketUrl) {
            request = URLRequest(url: url)
            print("websocketUrl", url)
        } else {
            request = URLRequest(url: URL(string: "wss://ws.xabber.com:9443/websocket")!)
        }
        request.setValue("xmpp", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        self.socket = WebSocket(request: request,
                                certPinner: FoundationSecurity(allowSelfSigned: true))
        self.socket.delegate = self
    }
    
    func connect() {
        socket.connect()
    }
    
    open func isAuthenticated() -> Bool {
        switch state {
        case .authenticated: return true
        default: return false
        }
    }
    
    func openStream() {
        guard let open = DDXMLElement(name: "open", xmlns: "urn:ietf:params:xml:ns:xmpp-framing") else { fatalError() }
        open.addAttribute(withName: "to", stringValue: host)
        open.addAttribute(withName: "version", stringValue: "1.0")
        send(open)
    }
    
    private func isStreamOpen(received stanza: DDXMLElement) -> String? {
//        if let error = stanza.forName("error") {
//
//        }
        return nil
    }
    
    private func authenticate(received stanza: DDXMLElement) -> String {
        let elementId: String = UUID().uuidString
        guard let mechanisms = stanza
            .forName("mechanisms", xmlns: "urn:ietf:params:xml:ns:xmpp-sasl")?
            .elements(forName: "mechanism")
            .compactMap ({ return $0.stringValue }) else {
                delegate?.didDisconnectWithError("Authenticate mechanisms not found")
                closeSocket()
                return ""
        }
        
        supportXToken = mechanisms.contains("X-TOKEN")
        
        if !mechanisms.contains("PLAIN") && !supportXToken {
            delegate?.didDisconnectWithError("Authenticate mechanisms not found")
            closeSocket()
            return ""
        }

        guard let auth = DDXMLElement(name: "auth", xmlns: "urn:ietf:params:xml:ns:xmpp-sasl") else {
            delegate?.didDisconnectWithError("Authenticate mechanisms not found")
            closeSocket()
            return ""
        }
        
        if supportXToken && !token.isEmpty,
            let mechanismValue = "\0\(self.username)\0\(self.token)"
                .data(using: .utf8)?
                .base64EncodedString() {
            auth.addAttribute(withName: "mechanism", stringValue: "X-TOKEN")
            auth.stringValue = mechanismValue
        } else if let mechanismValue = "\0\(self.username)\0\(self.password)"
            .data(using: .utf8)?
            .base64EncodedString() {
            auth.addAttribute(withName: "mechanism", stringValue: "PLAIN")
            auth.stringValue = mechanismValue
        } else {
            delegate?.didDisconnectWithError("Authenticate mechanism invalid")
            closeSocket()
            return ""
        }
        self.send(auth)
        return elementId
    }
    
    private func isAuthenticated(received stanza: DDXMLElement) -> String? {
        return nil
    }
    
    private func bind(received stanza: DDXMLElement) -> String {
        let elementId: String = UUID().uuidString

        guard let iq = DDXMLElement(name: "iq", xmlns: "jabber:client") else {
           delegate?.didDisconnectWithError("Bind faied")
           closeSocket()
           return ""
        }
        let bind = DDXMLElement(name: "bind")
        bind.setXmlns("urn:ietf:params:xml:ns:xmpp-bind")
        bind.addChild(DDXMLElement(name: "resource", stringValue: self.resource))
        iq.addChild(bind)
        iq.addAttribute(withName: "id", stringValue: elementId)
        iq.addAttribute(withName: "type", stringValue: "set")

        send(iq)

        return elementId
   }
    
    private func isBinded(received stanza: DDXMLElement) -> String? {
        return nil
    }
    
    private func createSession(received stanza: DDXMLElement) -> String {
        let elementId: String = UUID().uuidString
       
        guard let iq = DDXMLElement(name: "iq", xmlns: "jabber:client"),
            let session = DDXMLElement(name: "session", xmlns: "urn:ietf:params:xml:ns:xmpp-session") else {
            delegate?.didDisconnectWithError("Bind faied")
            closeSocket()
            return ""
        }
        
        iq.addChild(session)
        iq.addAttribute(withName: "id", stringValue: elementId)
        iq.addAttribute(withName: "type", stringValue: "set")
        
        send(iq)
        
        return elementId
   }
    
    private func isSessionCreated(received stanza: DDXMLElement, elementId: String) -> String? {
        return nil
    }
    
    func processAuth(received stanza: DDXMLElement?) {
        guard let stanza = stanza else {
            openStream()
            state = .open
            return
        }
        switch state {
        case .none:
            break
        case .open:
            state = .connect
        case .connect:
            if let error = isStreamOpen(received: stanza) {
                closeSocket()
                delegate?.didDisconnectWithError(error)
            } else {
                state = .authenticate(authenticate(received: stanza))
            }
        case .authenticate:
            if let error = isAuthenticated(received: stanza) {
                closeSocket()
                delegate?.didDisconnectWithError(error)
            } else {
                openStream()
                state = .resume
            }
        case .resume:
            if let error = isStreamOpen(received: stanza) {
                closeSocket()
                delegate?.didDisconnectWithError(error)
            } else {
                state = .bind(bind(received: stanza))
            }
        case .features:
            state = .bind(bind(received: stanza))
        case .bind:
            if let error = isBinded(received: stanza) {
                closeSocket()
                delegate?.didDisconnectWithError(error)
            } else {
                state = .session(createSession(received: stanza))
            }
        case .session(let elementId):
            if let error = isSessionCreated(received: stanza, elementId: elementId) {
                closeSocket()
                delegate?.didDisconnectWithError(error)
            } else {
                state = .authenticated
                if self.isVcardRequest {
                    queryId = getVCard()
                } else {
                    queryId = getMessage()
                }
            }
        case .authenticated:
            break
        }
    }
    
    internal func getVCard(jid: String? = nil) -> String {
        let elementId = UUID().uuidString
        if !isAuthenticated() { return elementId }
        guard let vcard = DDXMLElement(name: "vCard", xmlns: "vcard-temp"),
            let iq = DDXMLElement(name: "iq", xmlns: "jabber:client") else {
            return elementId
        }
        
        iq.addAttribute(withName: "type", stringValue: "get")
        iq.addAttribute(withName: "id", stringValue: elementId)
        if let jid = jid {
            iq.addAttribute(withName: "to", stringValue: jid)
        }
        if let vcardJid = vcardJid {
            iq.addAttribute(withName: "to", stringValue: vcardJid)
        }
        iq.addChild(vcard)
        send(iq) {
            self.isVCardRequested = true
        }
        return elementId
    }
    
    internal func getSync() -> String {
        let elementId = UUID().uuidString
        if !isAuthenticated() { return elementId }
        guard let query = DDXMLElement(name: "query", xmlns: "https://xabber.com/protocol/synchronization"),
            let iq = DDXMLElement(name: "iq", xmlns: "jabber:client") else {
            return elementId
        }
        
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            return elementId
        }
        let computedKey: String = ["client_sync", "version", self.jid].joined(separator: "_")
        if let version = userDefaults.string(forKey: computedKey) {
            query.addAttribute(withName: "stamp", stringValue: version)
        }
        
        iq.addAttribute(withName: "type", stringValue: "get")
        iq.addAttribute(withName: "id", stringValue: elementId)
        iq.addChild(query)
        send(iq) {
            self.isVCardRequested = true
        }
        return elementId
    }
    
    internal func getMessage() -> String {
        let elementId = UUID().uuidString
        if !isAuthenticated(), isMessageRequested { return elementId }
        func getField(formVar: String?, formType: String?, value: String) -> DDXMLElement {
            let field = DDXMLElement(name: "field")
            if let formVar = formVar {
                field.addAttribute(withName: "var", stringValue: formVar)
            }
            if let formType = formType {
                field.addAttribute(withName: "type", stringValue: formType)
            }
            field.addChild(DDXMLElement(name: "value", stringValue: value))
            return field
        }
        guard let iq = DDXMLElement(name: "iq", xmlns: "jabber:client"),
            let x = DDXMLElement(name: "x", xmlns: "jabber:x:data"),
            let query = DDXMLElement(name: "query", xmlns: "urn:xmpp:mam:1") else {
            delegate?.didDisconnectWithError("Mailformed stanza")
            closeSocket()
                return elementId
        }
        x.addAttribute(withName: "type", stringValue: "submit")
        x.addChild(getField(formVar: "FORM_TYPE", formType: "hidden", value: "urn:xmpp:mam:1"))
        if let stanzaId = stanzaId {
            x.addChild(getField(formVar: "{urn:xmpp:sid:0}stanza-id", formType: nil, value: stanzaId))
        } else {
            guard let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm") else {
                delegate?.didDisconnectWithError("Mailformed stanza")
                closeSocket()
                return elementId
            }
            set.addChild(DDXMLElement(name: "max", stringValue: "1"))
            set.addChild(DDXMLElement(name: "before"))
            query.addChild(set)
        }

        query.addAttribute(withName: "queryid", stringValue: elementId)
        query.addChild(x)
        iq.addAttribute(withName: "type", stringValue: "set")
        iq.addAttribute(withName: "id", stringValue: elementId)
        if let remoteArchiveJid = remoteArchiveJid {
            iq.addAttribute(withName: "to", stringValue: remoteArchiveJid)
        } else {
            iq.addAttribute(withName: "to", stringValue: self.jid)
        }
        iq.addChild(query)
        send(iq) {
            self.isMessageRequested = true
        }
        return elementId
    }
    
    internal func send(_ stanza: DDXMLElement, callback: (() -> Void)? = nil ) {
        socket.write(string: stanza.compactXMLString()) {
            print(["SEND:", stanza.prettyXMLString()].joined(separator: " "))
        }
    }
    
    internal func route(_ stanza: DDXMLElement) {
        print(["RECV:", stanza.prettyXMLString()].joined(separator: " "))
        if isAuthenticated() {
            if let name = stanza.rootDocument?.rootElement()?.name {
                switch name {
                case "iq":
                    read(iq: stanza)
                case "message":
                    read(message: stanza)
                default:
                    read(stanza: stanza)
                }
            }
        } else {
            processAuth(received: stanza)
        }
    }
    
    internal func read(message: String) -> DDXMLElement? {
        do {
            let document = try DDXMLDocument(xmlString: message.replacingOccurrences(of: "vcard-temp", with: "urn:ietf:params:xml:ns:vcard-4.0"), options: 0)
            if document.rootElement()?.name == "stream:error" {
                if let text = document.rootElement()?.children?.first?.name {
                    delegate?.didDisconnectWithError(text)
                } else {
                    delegate?.didDisconnectWithError("Internal error")
                }
                closeSocket()
            }
            return document.rootElement()
        } catch {
//            DDLogError(["Can`t decode xml string:", message].joined(separator: " "))
            return nil
        }
    }
    
    internal func read(iq stanza: DDXMLElement) {
        print("RAW STANZA====================",stanza.prettyXMLString())
        if let root = stanza.rootDocument?.rootElement(),
           let type = root.attribute(forName: "type")?.stringValue,
           type == "error" {
            self.delegate?.didUpdateContent(payload: [:])
            closeSocket()
        } else if let root = stanza.rootDocument?.rootElement(),
            let type = root.attribute(forName: "type")?.stringValue,
            type == "result" {
            print("LOL KEKE EKEKKEKEK", root.prettyXMLString())
            if let vcard = root.elements(forName: "vCard").first {
                print("VCARD ======================================2")
                var payload: [String : String] = prevPayload
                if let fn = vcard.elements(forName: "FN").first?.stringValue {
                    payload["fn"] = fn
                }
                
                if let family = vcard.elements(forName: "N").first?.elements(forName: "FAMILY").first?.stringValue {
                    payload["family"] = family
                }
                
                if let given = vcard.elements(forName: "N").first?.elements(forName: "GIVEN").first?.stringValue {
                    payload["given"] = given
                }
                
                if let nickname = vcard.elements(forName: "NICKNAME").first?.stringValue {
                    payload["nickname"] = nickname
                }
                
                if let avatarBase64String = vcard.elements(forName: "PHOTO").first?.elements(forName: "BINVAL").first?.stringValue {
                    payload["avatarBase64"] = avatarBase64String
                }
                
                if let from = vcardJid {
                    payload["from"] = from
                }
                self.delegate?.didUpdateContent(payload: payload)
            }
//            closeSocket()
        }
    }
    
    internal func closeSocket() {
        if let close = DDXMLElement(name: "close", xmlns: "urn:ietf:params:xml:ns:xmpp-framing") {
            send(close) {
                self.socket.disconnect(closeCode: 1000)
            }
        } else {
            socket.disconnect(closeCode: 1000)
        }
        state = .none
        isMessageRequested = false
    }
    
    func getReferenceType(_ ref: DDXMLElement) -> String? {
        if !ref.elements(forName: "voice-message").isEmpty {
            return "voice"
        } else if !ref.elements(forName: "file-sharing").isEmpty {
            return "media"
        }
        return nil
    }
    
    internal func read(message stanza: DDXMLElement) {
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
    
    internal func read(stanza: DDXMLElement) {
        
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
