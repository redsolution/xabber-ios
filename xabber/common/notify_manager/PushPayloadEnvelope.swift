import Foundation
import KissXML
import CryptoSwift

enum PushPayloadAction: String {
    case message, update, subscribe, invite, call, data, none
    case marker = "displayed"
}

struct PushStanzaIdentifier: Equatable {
    let id: String
    let by: String
}

struct PushDisplayedTarget {
    let messageID: String
    let stanzaIDs: [PushStanzaIdentifier]
}

enum PushDecodedEvent {
    case message(PushStanzaIdentifier)
    case fullMessage(DDXMLElement)
    case displayed(PushDisplayedTarget)
    case subscription(String)
    case call(DDXMLElement)
    case callUpdate(DDXMLElement)
    case reconciliation
}

enum PushPayloadXML {
    static let maximumSize = 512 * 1024
    static let namespace = "https://xabber.com/protocol/push"
    static let jingle = "urn:xmpp:jingle-message:0"

    static func allowed(_ xml: String) -> Bool {
        xml.utf8.count <= maximumSize
            && !xml.localizedCaseInsensitiveContains("<!DOCTYPE")
            && !xml.localizedCaseInsensitiveContains("<!ENTITY")
    }

    static func children(_ node: DDXMLElement, _ name: String? = nil) -> [DDXMLElement] {
        (node.children ?? []).compactMap { $0 as? DDXMLElement }.filter {
            name == nil || $0.localName == name
        }
    }

    static func value(_ node: DDXMLElement, _ name: String) -> String? {
        guard let raw = node.attribute(forName: name)?.stringValue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    static func decrypt(encryptedXML: String, key: [UInt8]) -> String? {
        guard key.count == 32, allowed(encryptedXML),
              let document = try? DDXMLDocument(xmlString: encryptedXML, options: 0),
              let root = document.rootElement(), root.localName == "encrypted", root.uri == namespace,
              children(root).isEmpty,
              root.attribute(forName: "iv-length")?.stringValue == "16",
              let encoded = root.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let bytes = Data(base64Encoded: encoded), bytes.count > 16,
              (bytes.count - 16).isMultiple(of: 16),
              let decrypted = try? AES(key: key, blockMode: CBC(iv: Array(bytes.prefix(16))),
                                       padding: .noPadding).decrypt(Array(bytes.dropFirst(16))) else { return nil }
        var end = decrypted.count
        while end > 0, decrypted[end - 1] == 0 { end -= 1 }
        guard end > 0, let xml = String(bytes: decrypted.prefix(end), encoding: .utf8), allowed(xml) else { return nil }
        return xml
    }

    static func element(encryptedXML: String, key: [UInt8]) -> DDXMLElement? {
        guard let xml = decrypt(encryptedXML: encryptedXML, key: key),
              let document = try? DDXMLDocument(xmlString: xml, options: 0),
              let root = document.rootElement(), classify(root) != nil else { return nil }
        return root
    }

    static func classify(_ root: DDXMLElement) -> PushDecodedEvent? {
        switch root.localName {
        case "stanza-id":
            guard root.uri == "urn:xmpp:sid:0", children(root).isEmpty,
                  let id = value(root, "id"), let by = value(root, "by") else { return nil }
            return .message(PushStanzaIdentifier(id: id, by: by))
        case "displayed":
            guard root.uri == "urn:xmpp:chat-markers:0", let id = value(root, "id") else { return nil }
            let nodes = children(root)
            var identifiers: [PushStanzaIdentifier] = []
            for node in nodes {
                guard node.localName == "stanza-id", node.uri == "urn:xmpp:sid:0",
                      let archiveID = value(node, "id"), let by = value(node, "by") else { return nil }
                identifiers.append(PushStanzaIdentifier(id: archiveID, by: by))
            }
            return .displayed(PushDisplayedTarget(messageID: id, stanzaIDs: identifiers))
        case "presence":
            guard [nil, "jabber:client"].contains(root.uri), value(root, "type") == "subscribe",
                  let from = value(root, "from") else { return nil }
            return .subscription(from)
        case "accept", "reject":
            guard root.uri == jingle, value(root, "id") != nil else { return nil }
            return .callUpdate(root)
        case "message":
            guard [nil, "jabber:client"].contains(root.uri) else { return nil }
            let controls = children(root).filter {
                ["propose", "accept", "reject", "retract", "proceed", "finish", "displayed"].contains($0.localName ?? "")
            }
            guard controls.count <= 1 else { return nil }
            if let control = controls.first {
                guard validSender(value(root, "from")) else { return nil }
                if control.localName == "displayed" {
                    guard case .displayed(let marker)? = classify(control) else { return nil }
                    return .displayed(marker)
                }
                guard control.uri == jingle, value(control, "id") != nil else { return nil }
                if control.localName == "propose" { return .call(root) }
                // A complete stanza carries sender/device semantics absent in the
                // bare app-server update contract. Reconcile it over authenticated XMPP.
                return .reconciliation
            }
            // Server can send a full device-revoke headline; CBC grants no destructive authority.
            if value(root, "type") == "headline" { return .reconciliation }
            guard ["normal", "chat", "groupchat"].contains(value(root, "type") ?? "normal"),
                  validSender(value(root, "from")), validFullMessageFields(root) else { return nil }
            return .fullMessage(root)
        default: return nil
        }
    }

    private static func validSender(_ sender: String?) -> Bool {
        guard let sender, !sender.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let bare = String(sender.prefix { $0 != "/" })
        guard !bare.isEmpty, !bare.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else { return false }
        let components = bare.split(separator: "@", omittingEmptySubsequences: false)
        return components.count <= 2 && components.allSatisfy { !$0.isEmpty }
    }

    private static func validFullMessageFields(_ root: DDXMLElement) -> Bool {
        let nodes = children(root)
        // Distinct xml:lang bodies/subjects are legal; duplicate language choices are ambiguous.
        for name in ["body", "subject"] {
            var languages = Set<String>()
            for node in nodes where node.localName == name {
                guard [nil, "jabber:client"].contains(node.uri), children(node).isEmpty else { return false }
                let language = (node.attribute(forName: "xml:lang")?.stringValue ?? "").lowercased()
                guard languages.insert(language).inserted else { return false }
            }
        }
        let threads = nodes.filter { $0.localName == "thread" }
        guard threads.count <= 1,
              threads.allSatisfy({ [nil, "jabber:client"].contains($0.uri) && children($0).isEmpty }) else { return false }
        var archives = Set<String>()
        for node in nodes where node.localName == "stanza-id" {
            guard node.uri == "urn:xmpp:sid:0", children(node).isEmpty,
                  value(node, "id") != nil, let by = value(node, "by"),
                  archives.insert(by).inserted else { return false }
        }
        let origins = nodes.filter { $0.localName == "origin-id" }
        return origins.count <= 1 && origins.allSatisfy {
            $0.uri == "urn:xmpp:sid:0" && children($0).isEmpty && value($0, "id") != nil
        }
    }
}

/// Canonical PubSub notification or the relay's encrypted/form sibling representation.
final class PushPayloadEnvelope {
    typealias StanzaId = PushStanzaIdentifier
    let actionElement: String
    let encrypted: String?
    let outgoing: Bool
    var action: PushPayloadAction { PushPayloadAction(rawValue: actionElement) ?? .none }

    init?(_ body: String) {
        guard PushPayloadXML.allowed(body),
              let document = try? DDXMLDocument(xmlString: "<push-envelope xmlns='\(PushPayloadXML.namespace)'>\(body)</push-envelope>", options: 0),
              let wrapper = document.rootElement() else { return nil }
        let children = PushPayloadXML.children(wrapper)
        let container: DDXMLElement
        if children.count == 1, let notification = children.first,
           notification.localName == "notification", notification.uri == PushPayloadXML.namespace {
            container = notification
        } else { container = wrapper }
        let nodes = PushPayloadXML.children(container)
        let encryptedNodes = nodes.filter { $0.localName == "encrypted" }
        let forms = nodes.filter { $0.localName == "x" }
        guard nodes.count == 2, encryptedNodes.count == 1, forms.count == 1,
              let encryptedNode = encryptedNodes.first, encryptedNode.uri == PushPayloadXML.namespace,
              let form = forms.first, form.uri == "jabber:x:data",
              form.attribute(forName: "type")?.stringValue == "result" else { return nil }
        let fields = PushPayloadXML.children(form, "field")
        func field(_ name: String) -> [String]? {
            let matching = fields.filter { $0.attribute(forName: "var")?.stringValue == name }
            var result: [String] = []
            for entry in matching {
                let values = PushPayloadXML.children(entry, "value")
                guard entry.uri == "jabber:x:data", values.count == 1,
                      let value = values.first, value.uri == "jabber:x:data",
                      PushPayloadXML.children(value).isEmpty, let text = value.stringValue else { return nil }
                result.append(text)
            }
            return result
        }
        guard field("FORM_TYPE") == [PushPayloadXML.namespace + "#info"],
              let types = field("type"), types.count <= 1,
              let outgoingValues = field("outgoing"), outgoingValues.count <= 1 else { return nil }
        let outgoingValue = outgoingValues.first ?? "false"
        guard ["true", "1", "false", "0"].contains(outgoingValue) else { return nil }
        self.outgoing = ["true", "1"].contains(outgoingValue)
        self.actionElement = types.first ?? "message"
        // Relay fragments inherit the notification namespace. Preserve it when
        // serializing the encrypted child independently from its parent.
        guard let encrypted = encryptedNode.copy() as? DDXMLElement else { return nil }
        encrypted.addNamespace(DDXMLNode.namespace(withName: "", stringValue: PushPayloadXML.namespace) as! DDXMLNode)
        self.encrypted = encrypted.xmlString
    }

    func event(key: [UInt8]) -> PushDecodedEvent? {
        guard let root = payloadStanza(key: key) else { return nil }
        return PushPayloadXML.classify(root)
    }

    func payloadStanza(key: [UInt8]) -> DDXMLElement? {
        guard let encrypted else { return nil }
        return PushPayloadXML.element(encryptedXML: encrypted, key: key)
    }

    func decrypt(by key: [UInt8]) -> String? {
        guard let encrypted else { return nil }
        return PushPayloadXML.decrypt(encryptedXML: encrypted, key: key)
    }

    func messageStanzaID(key: [UInt8]) -> StanzaId? {
        guard case .message(let id)? = event(key: key) else { return nil }
        return id
    }

    func subscribtionRequestFrom(key: [UInt8]) -> String? {
        guard case .subscription(let from)? = event(key: key) else { return nil }
        return from
    }

    func markerStanzaIDs(key: [UInt8], owner: String) -> [StanzaId] {
        guard case .displayed(let marker)? = event(key: key) else { return [] }
        return marker.stanzaIDs.filter { $0.by == owner }
    }
}

struct PushDeliveredNotification {
    let identifier: String
    let owner: String
    let jid: String
    let timestamp: TimeInterval
    let stanzaID: String?
    let messageID: String?
}

enum PushDisplayedPolicy {
    static func removalIDs(marker: PushDisplayedTarget, owner: String,
                           notifications: [PushDeliveredNotification]) -> [String] {
        let owned = notifications.filter { $0.owner == owner && !$0.jid.isEmpty && $0.timestamp.isFinite }
        let matches = owned.filter { notification in
            notification.messageID == marker.messageID || marker.stanzaIDs.contains {
                $0.id == notification.stanzaID && ($0.by == owner || $0.by == notification.jid)
            }
        }
        guard Set(matches.map(\.jid)).count == 1, Set(matches.map(\.timestamp)).count == 1,
              let boundary = matches.first?.timestamp, let jid = matches.first?.jid else { return [] }
        return owned.filter { $0.jid == jid && $0.timestamp <= boundary }.map(\.identifier)
    }
}
