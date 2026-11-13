import Foundation
import Kingfisher
import XMPPFramework

final class PrivacyProxyMediaRouter {
    struct Context {
        let policy: CommonConfigManager.PrivacyProxyPolicy
        let localEnabled: Bool
        let premium: Bool
        let endpoint: URL?
        let trustedHosts: [String]
        var premiumExpires: Date? = nil

        var usesProxy: Bool {
            policy.usesProxy(localProxyEnabled: localEnabled, hasActivePremium: premium)
        }
    }

    enum RoutingError: Error {
        case invalidOwner
        case invalidSource
        case unavailable
        case configurationChanged
        case invalidDownloadResponse
    }

    static let shared = PrivacyProxyMediaRouter(
        context: { owner in
            let policy = CommonConfigManager.shared.config.privacyProxyPolicy
            guard policy != .never else {
                return Context(policy: policy, localEnabled: false, premium: false, endpoint: nil, trustedHosts: [])
            }
            let preference = SettingManager.shared.getKeyBool(
                for: owner, scope: .security, key: SettingManager.privacyProxyEnabledKey
            ) ?? false
            let premiumExpires = policy == .payed && preference
                ? SubscribtionsManager.shared.getExpiresDate(for: owner)
                : nil
            let endpoint: URL?
            if case .advertised(let url) = AccountManager.shared.find(for: owner)?.disco.privacyProxyDiscovery {
                endpoint = url
            } else {
                endpoint = nil
            }
            let gallery = AccountGalleryConfiguration(owner: owner)
            return Context(
                policy: policy,
                localEnabled: preference,
                premium: premiumExpires.map { $0 > Date() } ?? false,
                endpoint: endpoint,
                trustedHosts: [gallery.basicGalleryURL?.host, gallery.premiumGalleryURL?.host].compactMap { $0 },
                premiumExpires: premiumExpires
            )
        },
        resolveExternal: { try await PrivacyProxyClient.shared.resolve(originalURL: $0, owner: $1) },
        pushRouting: .live
    )

    private let context: (String) -> Context
    private let resolveExternal: (URL, String) async throws -> URL
    private let pushRouting: PrivacyProxyPushRouting?

    init(
        context: @escaping (String) -> Context,
        resolveExternal: @escaping (URL, String) async throws -> URL,
        pushRouting: PrivacyProxyPushRouting? = nil
    ) {
        self.context = context
        self.resolveExternal = resolveExternal
        self.pushRouting = pushRouting
    }

    func restrictsRedirects(owner: String) -> Bool {
        context(XMPPJID(string: owner)?.bare ?? owner).usesProxy
    }

    func publishPushRouting(owner: String) {
        let current = context(owner)
        guard current.policy != .never else { return }
        pushRouting?.publish(endpoint: current.endpoint, trustedHosts: current.trustedHosts, owner: owner)
    }

    func resolve(_ url: URL, owner: String) async throws -> URL {
        try Task.checkCancellation()
        if url.isFileURL || url.scheme?.lowercased() == "data" { return url }
        let jid = XMPPJID(string: owner)
        let owner = jid?.bare ?? owner
        let current = context(owner)
        if current.policy == .payed {
            pushRouting?.publishPremiumExpiration(current.premiumExpires, owner: owner)
        }
        guard current.usesProxy else { return url }
        guard let jid, jid.user != nil else { throw RoutingError.invalidOwner }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { throw RoutingError.invalidSource }

        pushRouting?.publish(endpoint: current.endpoint, trustedHosts: current.trustedHosts, owner: owner)
        let trustedHosts = current.trustedHosts + [jid.domain]
        if PrivacyProxyPushRouting.matchesTrustedHost(url, trustedHosts: trustedHosts) {
            return url
        }
        guard let endpoint = current.endpoint else { throw RoutingError.unavailable }
        if PrivacyProxyClient.isProxiedFileURL(url, endpoint: endpoint) { return url }
        if let cached = pushRouting?.route(url, owner: owner, requiresPremium: current.policy == .payed) { return cached }

        let resolved = try await resolveExternal(url, owner)
        try Task.checkCancellation()
        let refreshed = context(owner)
        guard refreshed.usesProxy, refreshed.endpoint == endpoint else { throw RoutingError.configurationChanged }
        guard PrivacyProxyClient.isProxiedFileURL(resolved, endpoint: endpoint) else {
            throw RoutingError.invalidDownloadResponse
        }
        pushRouting?.remember(source: url, resolved: resolved, endpoint: endpoint, owner: owner)
        return resolved
    }

    private static let downloadSession = URLSession(configuration: protectedSessionConfiguration())

    static let protectedImageDownloader: ImageDownloader = {
        let downloader = ImageDownloader(name: "xabber.privacy-proxy")
        downloader.sessionConfiguration = protectedSessionConfiguration()
        return downloader
    }()

    private static func protectedSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func allowsRedirect(from source: URL, to target: URL) -> Bool {
        PrivacyProxyPushRouting.allowsRedirect(from: source, to: target)
    }

    static func redirectHandler(
        for originalURL: URL, resolvedURL: URL, owner: String
    ) -> (any ImageDownloadRedirectHandler)? {
        guard originalURL != resolvedURL || shared.restrictsRedirects(owner: owner) else { return nil }
        return AnyRedirectHandler { _, _, request, completion in
            completion(request.url.map { allowsRedirect(from: resolvedURL, to: $0) } == true ? request : nil)
        }
    }

    static func redirectDelegate(
        for originalURL: URL, resolvedURL: URL, owner: String
    ) -> URLSessionTaskDelegate? {
        guard originalURL != resolvedURL || shared.restrictsRedirects(owner: owner) else { return nil }
        return RedirectDelegate(source: resolvedURL)
    }

    func download(_ url: URL, owner: String) async throws -> URL {
        let resolved = try await resolve(url, owner: owner)
        let (temporary, response) = try await Self.downloadSession.download(
            for: URLRequest(url: resolved), delegate: RedirectDelegate(source: resolved)
        )
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw RoutingError.invalidDownloadResponse
        }

        let root = fileManager.temporaryDirectory.appendingPathComponent("xabber-proxied-media", isDirectory: true)
        let expiration = Date().addingTimeInterval(-24 * 60 * 60)
        for directory in (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        )) ?? [] {
            if let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < expiration {
                try? fileManager.removeItem(at: directory)
            }
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalName = url.lastPathComponent
        let filename = (originalName.isEmpty || originalName == "." || originalName == "..")
            ? "attachment" : originalName.replacingOccurrences(of: "/", with: "_")
        let destination = directory.appendingPathComponent(filename)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        private let source: URL

        init(source: URL) {
            self.source = source
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url.map { allowsRedirect(from: source, to: $0) } == true ? request : nil)
        }
    }
}
