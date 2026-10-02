import Foundation
import KissXML

public enum OMEMOReceiveProfile: Hashable, Sendable {
    case omemo2
    case legacySignal
}

/// In-process evidence from the decrypt boundary. Never encode in XML/userInfo.
public enum MessageEncryptionProvenance: Hashable, Sendable {
    case plaintext
    case authenticatedSCE(profile: OMEMOReceiveProfile)
    case unverifiedOMEMO
    case failedOMEMO

    public var isAuthenticated: Bool {
        if case .authenticatedSCE = self { return true }
        return false
    }
    public var isEncrypted: Bool { self != .plaintext }
}

/// Pure XML rules shared by the application and the notification extension.
/// This layer has no keys, storage access or authority to grant authentication.
enum SCEReceivePolicy {
    static let omemo = "urn:xmpp:omemo:2"
    static let sce = "urn:xmpp:sce:1"
    static let client = "jabber:client"
    static let mamNamespaces: Set<String> = ["urn:xmpp:mam:0", "urn:xmpp:mam:1", "urn:xmpp:mam:2", "urn:xmpp:mam:3"]
    static let carbonNamespaces: Set<String> = ["urn:xmpp:carbons:0", "urn:xmpp:carbons:1", "urn:xmpp:carbons:2"]

    static func matches(_ element: DDXMLElement, name: String, namespace: String) -> Bool {
        element.localName == name && element.uri == namespace
    }

    static func children(of element: DDXMLElement, named name: String, xmlns namespace: String) -> [DDXMLElement] {
        (element.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
            matches($0, name: name, namespace: namespace)
        }
    }

    static func hasOMEMO2(_ element: DDXMLElement) -> Bool {
        !children(of: element, named: "encrypted", xmlns: omemo).isEmpty
    }

    static func containsOMEMO2(_ element: DDXMLElement) -> Bool {
        hasOMEMO2(element) || (element.children?.compactMap { $0 as? DDXMLElement } ?? []).contains { containsOMEMO2($0) }
    }

    static func isServerProcessed(_ element: DDXMLElement) -> Bool {
        let name = element.localName ?? ""
        switch element.uri {
        case "urn:xmpp:hints":
            return ["store", "no-store", "no-permanent-store", "no-copy"].contains(name)
        case "urn:xmpp:sid:0": return name == "stanza-id"
        case "http://jabber.org/protocol/address": return ["addresses", "address"].contains(name)
        case "urn:xmpp:eme:0": return name == "encryption"
        case "urn:xmpp:delay": return name == "delay"
        case "https://xabber.com/protocol/delivery": return ["time", "received", "retry"].contains(name)
        default: return false
        }
    }

    /// Known semantic names cannot acquire meaning through an unrelated URI.
    /// Unknown extensions remain opaque, preserving custom encrypted protocols.
    static func isClientContentElement(_ element: DDXMLElement) -> Bool {
        let name = element.localName ?? ""
        if name == "omemo-result__system" || isServerProcessed(element) { return false }
        if matches(element, name: "envelope", namespace: sce) { return false }
        // Decrypted peer content cannot impersonate a server mutation event.
        // The authenticated edit marker uses rewrite without the #notify suffix.
        if element.uri == "https://xabber.com/protocol/rewrite#notify" &&
            ["replace", "retract-message", "retract-user", "retract-all"].contains(name) { return false }
        let namespaces: [String: Set<String>] = [
            "body": [client], "subject": [client], "thread": [client],
            "reference": ["https://xabber.com/protocol/references", "urn:xmpp:reference:0"],
            "ephemeral": ["urn:xmpp:ephemeral:0"],
            "markable": ["urn:xmpp:chat-markers:0"],
            "received": ["urn:xmpp:chat-markers:0", "urn:xmpp:receipts"],
            "displayed": ["urn:xmpp:chat-markers:0"], "acknowledged": ["urn:xmpp:chat-markers:0"],
            "request": ["urn:xmpp:receipts"],
            "active": ["http://jabber.org/protocol/chatstates"], "inactive": ["http://jabber.org/protocol/chatstates"],
            "gone": ["http://jabber.org/protocol/chatstates"], "composing": ["http://jabber.org/protocol/chatstates"],
            "paused": ["http://jabber.org/protocol/chatstates"],
            "replaced": ["https://xabber.com/protocol/rewrite"], "replace": ["urn:xmpp:message-correct:0"],
            "retract-message": ["https://xabber.com/protocol/rewrite#notify"],
            "retract-user": ["https://xabber.com/protocol/rewrite#notify"],
            "retract-all": ["https://xabber.com/protocol/rewrite#notify"],
            "time-signature": ["urn:xmpp:x509:0"],
            "propose": ["urn:xmpp:jingle-message:0"], "accept": ["urn:xmpp:jingle-message:0"],
            "reject": ["urn:xmpp:jingle-message:0"], "retract": ["urn:xmpp:jingle-message:0", "urn:xmpp:message-retract:0", "urn:xmpp:message-retract:1"],
            "origin-id": ["urn:xmpp:sid:0"],
            "stanza-id": ["urn:xmpp:sid:0"], "archived": [],
            "time": ["https://xabber.com/protocol/delivery"], "delay": ["urn:xmpp:delay"],
            "addresses": ["http://jabber.org/protocol/address"], "address": ["http://jabber.org/protocol/address"],
            "encryption": ["urn:xmpp:eme:0"],
            "previous-id": ["http://xabber.com/protocol/previous"],
            "deferred": ["https://xabber.com/protocol/schedule"]
        ]
        return namespaces[name].map { $0.contains(element.uri ?? "") } ?? true
    }

    static func filteredContent(_ content: DDXMLElement) -> DDXMLElement {
        let copy = content.copy() as! DDXMLElement
        for child in copy.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
            child.detach()
            if isClientContentElement(child) { copy.addChild(canonicalElementCopy(child)) }
        }
        return copy
    }

    /// Internal consumers historically address tags by their unprefixed name.
    /// Canonicalize prefixes, preserving each expanded QName and all values.
    static func canonicalElementCopy(_ element: DDXMLElement) -> DDXMLElement {
        let name = element.localName ?? element.name ?? ""
        let candidate: DDXMLElement? = DDXMLElement(name: name, xmlns: element.uri ?? "")
        guard let copy = candidate else {
            return element.copy() as! DDXMLElement
        }
        for namespace in element.namespaces ?? [] where namespace.name?.isEmpty == false {
            copy.addNamespace(namespace.copy() as! DDXMLNode)
        }
        for attribute in element.attributes ?? [] { copy.addAttribute(attribute.copy() as! DDXMLNode) }
        for child in element.children ?? [] {
            if let child = child as? DDXMLElement { copy.addChild(canonicalElementCopy(child)) }
            else { copy.addChild(child.copy() as! DDXMLNode) }
        }
        return copy
    }

    /// Preserve routing attributes, ciphertext and explicit server metadata.
    /// Sensitive children are reconstructed solely from authenticated content.
    static func sanitized(_ message: DDXMLElement, content: DDXMLElement? = nil) -> DDXMLElement {
        let copy = message.copy() as! DDXMLElement
        for child in copy.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
            if !matches(child, name: "encrypted", namespace: omemo) && !isServerProcessed(child) {
                child.detach()
            }
        }
        if let content {
            let filtered = filteredContent(content)
            for child in filtered.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
                copy.addChild(child.copy() as! DDXMLElement)
            }
        }
        return copy
    }

    static func droppingUnprotectedSCE(_ element: DDXMLElement) -> DDXMLElement {
        let copy = element.copy() as! DDXMLElement
        func remove(_ parent: DDXMLElement) {
            for child in parent.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
                if child.localName == "omemo-result__system" || matches(child, name: "envelope", namespace: sce) {
                    child.detach()
                } else { remove(child) }
            }
        }
        remove(copy)
        return copy
    }
}
