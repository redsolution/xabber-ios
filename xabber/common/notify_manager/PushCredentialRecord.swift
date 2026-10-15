import Foundation
import CryptoKit
import CoreFoundation

enum PushCredentialKeyEncoding: String, Codable {
    case utf8
    case base64
}

/// Endpoint and token obtained together from one authenticated XMPP discovery domain.
/// Token claims are only scheduling hints; authorization is enforced by the HTTP server.
struct PushHTTPArchiveGrant: Codable, Equatable {
    let endpoint: String
    let token: String
    let scopes: [String]
    let expiresAt: Date
    let discoveryDomain: String

    func isUsable(forAccount account: String, host: String, now: Date) -> Bool {
        let bareAccount = account.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let accountParts = bareAccount.split(separator: "@", omittingEmptySubsequences: false)
        guard accountParts.count == 2, !accountParts[0].isEmpty,
              !discoveryDomain.isEmpty, !host.isEmpty,
              accountParts[1].lowercased() == discoveryDomain.lowercased(),
              host.lowercased() == discoveryDomain.lowercased(),
              !discoveryDomain.contains(where: { $0.isWhitespace || $0.isNewline }),
              discoveryDomain.rangeOfCharacter(from: .controlCharacters) == nil,
              scopes.contains("urn:xmpp:mam:2"), expiresAt > now,
              !token.isEmpty, token.utf8.count <= 256 * 1024,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              token.rangeOfCharacter(from: .controlCharacters) == nil,
              !endpoint.isEmpty,
              !endpoint.contains(where: { $0.isWhitespace || $0.isNewline }),
              endpoint.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URLComponents(string: endpoint),
              url.scheme?.lowercased() == "https", let endpointHost = url.host, !endpointHost.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              !(url.queryItems ?? []).contains(where: { $0.name == "id" || $0.name == "by" }),
              url.url != nil else { return false }
        return true
    }
}

/// One atomic Keychain value. JWT claims below are scheduling hints, never auth proof.
struct PushCredentialRecord: Codable {
    static let currentVersion = 3
    let version: Int
    let host: String
    let secret: String
    let jid: String
    let service: String
    let jwt: String
    let keyEncoding: PushCredentialKeyEncoding
    let grantRevision: String?
    let httpArchive: PushHTTPArchiveGrant?

    init(host: String, secret: String, jid: String, service: String, jwt: String,
         keyEncoding: PushCredentialKeyEncoding = .utf8, grantRevision: String? = nil,
         httpArchive: PushHTTPArchiveGrant? = nil) {
        self.version = Self.currentVersion
        self.host = host
        self.secret = secret
        self.jid = jid
        self.service = service
        self.jwt = jwt
        self.keyEncoding = keyEncoding
        self.grantRevision = grantRevision
        self.httpArchive = httpArchive
    }

    private enum CodingKeys: String, CodingKey {
        case version, host, secret, jid, service, jwt, keyEncoding, grantRevision, httpArchive
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values,
                                                   debugDescription: "Unsupported push credential version")
        }
        host = try values.decode(String.self, forKey: .host)
        secret = try values.decode(String.self, forKey: .secret)
        jid = try values.decode(String.self, forKey: .jid)
        service = try values.decode(String.self, forKey: .service)
        jwt = try values.decode(String.self, forKey: .jwt)
        keyEncoding = version == 1
            ? (try values.decodeIfPresent(PushCredentialKeyEncoding.self, forKey: .keyEncoding) ?? .utf8)
            : (try values.decode(PushCredentialKeyEncoding.self, forKey: .keyEncoding))
        grantRevision = try values.decodeIfPresent(String.self, forKey: .grantRevision)
        // Legacy flat URL/JWT fields do not prove endpoint discovery or a MAM-scoped grant.
        // Keep the encryption key, then require the app to discover and request a fresh token.
        if version >= 3 {
            httpArchive = try values.decodeIfPresent(PushHTTPArchiveGrant.self, forKey: .httpArchive)
        } else {
            httpArchive = nil
        }
    }

    var keyBytes: [UInt8]? {
        let bytes: [UInt8]
        switch keyEncoding {
        case .utf8: bytes = Array(secret.utf8)
        case .base64:
            guard let decoded = Data(base64Encoded: secret) else { return nil }
            bytes = Array(decoded)
        }
        return bytes.count == 32 ? bytes : nil
    }

    var tokenGeneration: String {
        struct GrantContext: Encodable {
            let jid: String
            let host: String
            let service: String
            let jwt: String
            let revision: String?
            let httpArchive: PushHTTPArchiveGrant?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let context = (try? encoder.encode(GrantContext(jid: jid, host: host, service: service, jwt: jwt,
                                                      revision: grantRevision, httpArchive: httpArchive))) ?? Data()
        return SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
    }

    var tokenExpiresAt: Date? {
        guard let grant = httpArchive else { return Self.jwtExpiresAt(jwt) }
        guard let jwtExpiry = Self.jwtExpiresAt(grant.token) else { return grant.expiresAt }
        return min(grant.expiresAt, jwtExpiry)
    }

    private static func jwtExpiresAt(_ jwt: String) -> Date? {
        guard jwt.utf8.count <= 256 * 1024 else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = payload["exp"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue)
    }
}

/// NSE writes a rejection marker for the snapshot it used, never overwrites a newer JWT.
struct PushTokenInvalidationStore {
    let directory: URL

    static var live: PushTokenInvalidationStore? {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CredentialsManager.uniqueAccessGroup()
        ) else { return nil }
        return Self(directory: group.appendingPathComponent("PushHTTPGrantInvalidations", isDirectory: true))
    }

    func contains(node: String, generation: String) throws -> Bool {
        try prepareDirectory()
        let path = markerURL(node: node, generation: generation)
        // Distinguish absence from file protection/permission failures.
        do { _ = try Data(contentsOf: path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    func invalidate(node: String, generation: String, preservingGeneration: String? = nil) throws {
        try prepareDirectory()
        try FileManager.default.createDirectory(at: nodeDirectory(node), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try Data([1]).write(to: markerURL(node: node, generation: generation), options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: markerURL(node: node, generation: generation).path
        )
        try prune(node: node, preservingGeneration: preservingGeneration ?? generation)
    }

    func remove(node: String, generation: String) throws {
        let path = markerURL(node: node, generation: generation)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    func removeAll(node: String) throws {
        let path = nodeDirectory(node)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// Keep the current rejected snapshot even if many late requests reject obsolete grants.
    private func prune(node: String, preservingGeneration: String) throws {
        let files = try FileManager.default.contentsOfDirectory(at: nodeDirectory(node),
            includingPropertiesForKeys: [.contentModificationDateKey])
        guard files.count > 64 else { return }
        let protected = markerURL(node: node, generation: preservingGeneration)
        let candidates = files.filter { $0 != protected }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first < second
        }
        for path in candidates.prefix(files.count - 64) {
            do { try FileManager.default.removeItem(at: path) }
            catch CocoaError.fileNoSuchFile { /* Another process already retired it. */ }
        }
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func nodeDirectory(_ node: String) -> URL {
        directory.appendingPathComponent(digest(node), isDirectory: true)
    }

    private func markerURL(node: String, generation: String) -> URL {
        nodeDirectory(node).appendingPathComponent(digest(generation))
    }
}
