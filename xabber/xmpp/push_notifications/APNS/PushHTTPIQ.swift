import Foundation
import XMPPFramework

/// XEP-HTTPIQ discovery/authorization codec. HTTP operation details belong to the MAM profile.
enum PushHTTPIQ {
    static let namespace = "https://xabber.com/protocol/http-iq"
    static let mamScope = "urn:xmpp:mam:2"
    static let requestedTTL = 3600

    static func endpointsRequest(id: String, jid: XMPPJID) -> XMPPIQ {
        request(id: id, jid: jid, child: DDXMLElement(name: "endpoints", xmlns: namespace))
    }

    static func tokenRequest(id: String, jid: XMPPJID) -> XMPPIQ {
        let token = DDXMLElement(name: "token", xmlns: namespace)
        let scope = DDXMLElement(name: "scope", xmlns: namespace)
        scope.stringValue = mamScope
        token.addChild(scope)
        let ttl = DDXMLElement(name: "ttl", xmlns: namespace)
        ttl.stringValue = String(requestedTTL)
        token.addChild(ttl)
        return request(id: id, jid: jid, child: token)
    }

    private static func request(id: String, jid: XMPPJID, child: DDXMLElement) -> XMPPIQ {
        let iq = XMPPIQ(iqType: .get, to: XMPPJID(string: jid.domain), elementID: id, child: child)
        iq.addAttribute(withName: "from", stringValue: jid.full)
        return iq
    }

    static func archiveEndpoint(in iq: XMPPIQ) -> String? {
        guard let container = singleChild(iq, name: "endpoints"),
              let branches = children(container) else { return nil }
        let mam = branches.filter { $0.localName == "protocol" && $0.uri == namespace
            && $0.attributeStringValue(forName: "var") == mamScope }
        guard mam.count == 1, let branch = mam.first, let endpoints = children(branch) else { return nil }
        // Unknown branches and endpoint names are deliberately ignored.
        let matching = endpoints.filter { $0.localName == "endpoint" && $0.uri == namespace
            && $0.attributeStringValue(forName: "name") == "by-id" }
        guard matching.count == 1, let endpoint = matching.first,
              children(endpoint)?.isEmpty == true,
              let url = endpoint.attributeStringValue(forName: "url"), validEndpoint(url) else { return nil }
        return url
    }

    static func archiveGrant(in iq: XMPPIQ, endpoint: String, owner: String,
                             domain: String, now: Date) -> PushHTTPArchiveGrant? {
        guard let token = singleChild(iq, name: "token"), let nodes = children(token) else { return nil }
        let scopes = nodes.filter { $0.localName == "scope" }
        guard !scopes.isEmpty else { return nil }
        var grantedScopes: [String] = []
        for scope in scopes {
            guard scope.uri == namespace, let value = text(scope) else { return nil }
            grantedScopes.append(value)
        }
        guard grantedScopes.contains(mamScope),
              let value = singleText(nodes, name: "value"), value.utf8.count <= 256 * 1024,
              validToken(value), let expires = singleText(nodes, name: "expires"),
              let expiry = parseDate(expires), expiry > now else { return nil }
        let ttls = nodes.filter { $0.localName == "ttl" }
        if !ttls.isEmpty {
            guard ttls.count == 1, let ttl = ttls.first, ttl.uri == namespace,
                  let raw = text(ttl), raw.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let seconds = Int(raw), seconds > 0 else { return nil }
        }
        let grant = PushHTTPArchiveGrant(endpoint: endpoint, token: value, scopes: grantedScopes,
                                        expiresAt: expiry, discoveryDomain: domain)
        return grant.isUsable(forAccount: owner, host: domain, now: now) ? grant : nil
    }

    private static func singleChild(_ element: DDXMLElement, name: String) -> DDXMLElement? {
        guard let nodes = children(element) else { return nil }
        let matching = nodes.filter { $0.localName == name }
        guard matching.count == 1, let child = matching.first, child.uri == namespace else { return nil }
        return child
    }

    private static func singleText(_ nodes: [DDXMLElement], name: String) -> String? {
        let matching = nodes.filter { $0.localName == name }
        guard matching.count == 1, let node = matching.first, node.uri == namespace else { return nil }
        return text(node)
    }

    private static func text(_ element: DDXMLElement) -> String? {
        guard children(element)?.isEmpty == true, let value = element.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func children(_ element: DDXMLElement) -> [DDXMLElement]? {
        let nodes = element.children ?? []
        guard nodes.count <= 512 else { return nil }
        return nodes.compactMap { $0 as? DDXMLElement }
    }

    private static func validEndpoint(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.fragment == nil, url.url != nil else { return false }
        return !(url.queryItems ?? []).contains { ["id", "by"].contains($0.name) }
    }

    private static func validToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
