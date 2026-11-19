import CryptoKit
import Foundation

/// The notification extension can reuse short-lived byte URLs resolved by the app.
struct PrivacyProxyPushRouting {
    static let preferenceName = "privacy_proxy_enabled"
    private struct Mapping: Codable {
        let url: URL
        let expires: Date
    }

    private struct Snapshot: Codable {
        let endpoint: URL?
        let trustedHosts: [String]
        var premiumExpires: Date?
        var mappings: [String: Mapping] = [:]
    }

    private static let lock = NSLock()
    private let defaults: UserDefaults?

    static var live: Self {
        Self(defaults: UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()))
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func publish(endpoint: URL?, trustedHosts: [String], owner: String) {
        guard !owner.isEmpty else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = read(owner: owner)
        if let previous, previous.endpoint == endpoint,
           previous.trustedHosts == trustedHosts {
            return
        }
        let premiumExpires = previous?.premiumExpires
        write(Snapshot(endpoint: endpoint, trustedHosts: trustedHosts, premiumExpires: premiumExpires), owner: owner)
    }

    func publishPremiumExpiration(_ expiration: Date?, owner: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var snapshot = read(owner: owner) ?? Snapshot(endpoint: nil, trustedHosts: [])
        guard snapshot.premiumExpires != expiration else { return }
        snapshot.premiumExpires = expiration
        write(snapshot, owner: owner)
    }

    func remember(source: URL, resolved: URL, endpoint: URL, owner: String, now: Date = Date()) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var snapshot = read(owner: owner), snapshot.endpoint == endpoint else { return }
        snapshot.mappings = snapshot.mappings.filter { $0.value.expires > now }
        let key = Self.digest(source.absoluteString)
        if snapshot.mappings[key] == nil, snapshot.mappings.count >= 48,
           let oldest = snapshot.mappings.min(by: { $0.value.expires < $1.value.expires }) {
            snapshot.mappings.removeValue(forKey: oldest.key)
        }
        snapshot.mappings[key] = Mapping(url: resolved, expires: now.addingTimeInterval(600))
        write(snapshot, owner: owner)
    }

    func clear(owner: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        defaults?.removeObject(forKey: Self.snapshotKey(owner))
    }

    func needsProxy(owner: String, policy: CommonConfigManager.PrivacyProxyPolicy) -> Bool {
        switch policy {
        case .never: return false
        case .always: return true
        case .manual, .payed:
            guard let defaults else { return true }
            return defaults.bool(forKey: Self.preferenceKey(owner))
        }
    }

    func route(
        _ url: URL, owner: String, requiresPremium: Bool = false,
        allowTrustedDirect: Bool = true, now: Date = Date()
    ) -> URL? {
        route(url, owner: owner, allowsMapping: true, requiresPremium: requiresPremium,
              allowTrustedDirect: allowTrustedDirect, now: now)
    }

    func routeImage(
        _ url: URL, owner: String, policy: CommonConfigManager.PrivacyProxyPolicy, now: Date = Date()
    ) -> URL? {
        route(
            url, owner: owner, allowsMapping: needsProxy(owner: owner, policy: policy),
            requiresPremium: policy == .payed, now: now
        )
    }

    private func route(
        _ url: URL, owner: String, allowsMapping: Bool, requiresPremium: Bool,
        allowTrustedDirect: Bool = true, now: Date
    ) -> URL? {
        let snapshot = read(owner: owner)
        let domain = owner.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init)
        let trustedHosts = (snapshot?.trustedHosts ?? []) + [domain].compactMap { $0 }
        if allowTrustedDirect, Self.matchesTrustedHost(url, trustedHosts: trustedHosts) {
            return url
        }
        guard allowsMapping,
              !requiresPremium || snapshot?.premiumExpires.map({ $0 > now }) == true,
              let mapping = snapshot?.mappings[Self.digest(url.absoluteString)],
              mapping.expires > now else { return nil }
        return mapping.url
    }

    static func matchesTrustedHost(_ url: URL, trustedHosts: [String]) -> Bool {
        guard let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return trustedHosts.contains { domain in
            let domain = domain.lowercased()
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }

    static func preferenceKey(_ owner: String) -> String {
        "security_\(preferenceName)_\(owner)"
    }

    static func allowsRedirect(from source: URL, to target: URL) -> Bool {
        guard let host = source.host?.lowercased(), target.host?.lowercased() == host,
              target.scheme?.lowercased() == "https", target.user == nil, target.password == nil else {
            return false
        }
        let targetPort = target.port ?? 443
        switch source.scheme?.lowercased() {
        case "https": return (source.port ?? 443) == targetPort
        case "http": return (source.port == nil || source.port == 80) && targetPort == 443
        default: return false
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshotKey(_ owner: String) -> String {
        "privacy_proxy_routing_v1_" + digest(owner)
    }

    private func read(owner: String) -> Snapshot? {
        guard let data = defaults?.data(forKey: Self.snapshotKey(owner)) else { return nil }
        return try? PropertyListDecoder().decode(Snapshot.self, from: data)
    }

    private func write(_ snapshot: Snapshot, owner: String) {
        guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: Self.snapshotKey(owner))
    }
}
