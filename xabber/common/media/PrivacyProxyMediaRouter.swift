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
        case imageConsentRequired
    }

    static let shared = PrivacyProxyMediaRouter(
        context: { owner in
            let policy = CommonConfigManager.shared.config.privacyProxyPolicy
            let preference = policy != .never && (SettingManager.shared.getKeyBool(
                for: owner, scope: .security, key: SettingManager.privacyProxyEnabledKey
            ) ?? false)
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
    private let imageConsentLock = NSLock()
    private var approvedImages: [String: [URL]] = [:]

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
        pushRouting?.publish(endpoint: current.endpoint, trustedHosts: current.trustedHosts, owner: owner)
    }

    func canRequestDirectImage(_ url: URL, owner: String) -> Bool {
        guard let jid = XMPPJID(string: owner), jid.user != nil, Self.isHTTPImageURL(url) else { return false }
        let current = context(jid.bare)
        return mayApproveImage(url, jid: jid, context: current)
    }

    func imageRequiresConsent(_ url: URL, owner: String) -> Bool {
        guard let jid = XMPPJID(string: owner), jid.user != nil, Self.isHTTPImageURL(url) else { return false }
        let current = context(jid.bare)
        return (!current.usesProxy || current.endpoint == nil) && mayApproveImage(url, jid: jid, context: current)
    }

    func canResolveImagesThroughProxy(owner: String) -> Bool {
        guard let jid = XMPPJID(string: owner), jid.user != nil else { return false }
        let current = context(jid.bare)
        return current.usesProxy && current.endpoint != nil
    }

    @discardableResult
    func grantDirectImage(_ url: URL, owner: String) -> Bool {
        guard canRequestDirectImage(url, owner: owner), let jid = XMPPJID(string: owner) else { return false }
        imageConsentLock.lock()
        defer { imageConsentLock.unlock() }
        var recent = approvedImages[jid.bare, default: []]
        recent.removeAll { $0 == url }
        recent.append(url)
        approvedImages[jid.bare] = Array(recent.suffix(128))
        return true
    }

    func clearImageConsent(owner: String) {
        imageConsentLock.lock()
        defer { imageConsentLock.unlock() }
        approvedImages.removeValue(forKey: XMPPJID(string: owner)?.bare ?? owner)
    }

    private func hasImageConsent(_ url: URL, owner: String) -> Bool {
        imageConsentLock.lock()
        defer { imageConsentLock.unlock() }
        return approvedImages[owner]?.contains(url) == true
    }

    private func mayApproveImage(_ url: URL, jid: XMPPJID, context: Context) -> Bool {
        context.policy != .always && !isTrustedImage(url, jid: jid, context: context)
            && !hasImageConsent(url, owner: jid.bare)
    }

    private func isTrustedImage(_ url: URL, jid: XMPPJID, context: Context) -> Bool {
        if PrivacyProxyPushRouting.matchesTrustedHost(url, trustedHosts: context.trustedHosts + [jid.domain]) {
            return true
        }
        return context.usesProxy && context.endpoint.map {
            PrivacyProxyClient.isProxiedFileURL(url, endpoint: $0)
        } == true
    }

    private static func isHTTPImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    func resolveImage(_ url: URL, owner: String) async throws -> URL {
        try await resolveImage(url, owner: owner, allowsConsent: true)
    }

    func resolveAutomaticImage(_ url: URL, owner: String) async throws -> URL {
        try await resolveImage(url, owner: owner, allowsConsent: false)
    }

    private func resolveImage(_ url: URL, owner: String, allowsConsent: Bool) async throws -> URL {
        try Task.checkCancellation()
        if url.isFileURL || url.scheme?.lowercased() == "data" { return url }
        guard let jid = XMPPJID(string: owner), jid.user != nil else { throw RoutingError.invalidOwner }
        guard Self.isHTTPImageURL(url) else { throw RoutingError.invalidSource }
        let current = context(jid.bare)
        if isTrustedImage(url, jid: jid, context: current) { return url }
        if current.policy != .always, allowsConsent, hasImageConsent(url, owner: jid.bare) { return url }
        guard current.usesProxy else { throw RoutingError.imageConsentRequired }
        do {
            return try await resolveUsingProxy(url, jid: jid, current: current)
        } catch {
            try Task.checkCancellation()
            if current.policy == .always { throw error }
            throw RoutingError.imageConsentRequired
        }
    }

    func resolve(_ url: URL, owner: String) async throws -> URL {
        try Task.checkCancellation()
        if url.isFileURL || url.scheme?.lowercased() == "data" { return url }
        let jid = XMPPJID(string: owner)
        let owner = jid?.bare ?? owner
        let current = context(owner)
        guard current.usesProxy else { return url }
        guard let jid, jid.user != nil else { throw RoutingError.invalidOwner }
        guard Self.isHTTPImageURL(url) else { throw RoutingError.invalidSource }
        return try await resolveUsingProxy(url, jid: jid, current: current)
    }

    private func resolveUsingProxy(_ url: URL, jid: XMPPJID, current: Context) async throws -> URL {
        let owner = jid.bare
        if current.policy == .payed {
            pushRouting?.publishPremiumExpiration(current.premiumExpires, owner: owner)
        }
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
        for originalURL: URL, resolvedURL: URL, owner: String, force: Bool = false
    ) -> (any ImageDownloadRedirectHandler)? {
        guard force || originalURL != resolvedURL || shared.restrictsRedirects(owner: owner) else { return nil }
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
        return try await download(from: resolved, originalURL: url)
    }

    func downloadAutomaticImage(_ url: URL, owner: String) async throws -> URL {
        let resolved = try await resolveAutomaticImage(url, owner: owner)
        return try await download(from: resolved, originalURL: url)
    }

    func downloadImage(_ url: URL, owner: String) async throws -> URL {
        let resolved = try await resolveImage(url, owner: owner)
        return try await download(from: resolved, originalURL: url)
    }

    private func download(from resolved: URL, originalURL url: URL) async throws -> URL {
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
