import Foundation

/// Resolves request-local sender image bytes without changing the app-owned
/// snapshot store or its deletion markers.
final class PushNotificationAvatarResolver {
    typealias Identity = PushNotificationAvatarIdentity

    private let cachedData: (Identity) -> Data?
    private let savedURL: (Identity) -> String?
    private let fallbackURLs: (Identity) -> [String]
    private let download: (String) async -> Data?
    private let diagnostics: ((String) -> Void)?

    init(
        cachedData: @escaping (Identity) -> Data?,
        savedURL: @escaping (Identity) -> String?,
        fallbackURLs: @escaping (Identity) -> [String] = { _ in [] },
        download: @escaping (String) async -> Data?,
        diagnostics: ((String) -> Void)? = nil
    ) {
        self.cachedData = cachedData
        self.savedURL = savedURL
        self.fallbackURLs = fallbackURLs
        self.download = download
        self.diagnostics = diagnostics
    }

    static func live(diagnostics: ((String) -> Void)? = nil) -> PushNotificationAvatarResolver {
        let loader = RichNotificationAttachmentLoader(
            limits: .init(
                maximumAttachmentCount: 1,
                maximumImageBytes: 2 * 1024 * 1024,
                maximumTotalBytes: 2 * 1024 * 1024,
                maximumImagePixels: 16_000_000,
                maximumImageDimension: 256,
                requestTimeout: 3,
                totalDeadline: 3
            ),
            diagnostics: diagnostics
        )
        return PushNotificationAvatarResolver(
            cachedData: { PushNotificationAvatarStore.shared.imageData(for: $0) },
            savedURL: { identity in
                guard identity.scope == .contact,
                      !PushNotificationAvatarStore.shared.isOwnerMarkedDeleted(identity.owner) else { return nil }
                return CommonContactsMetadataManager.shared.getItem(
                    owner: identity.owner,
                    jid: identity.entityJid
                ).avatarUrl
            },
            fallbackURLs: { identity in
                guard identity.scope == .contact,
                      !PushNotificationAvatarStore.shared.isOwnerMarkedDeleted(identity.owner) else { return [] }
                return [CommonContactsMetadataManager.shared.getItem(
                    owner: identity.owner,
                    jid: identity.entityJid
                ).avatarOriginalUrl].compactMap { $0 }
            },
            download: { await loader.avatarImageData(from: $0) },
            diagnostics: diagnostics
        )
    }

    func imageData(
        for route: PushNotificationRoutePayload,
        displayName: String,
        fallbackJid: String
    ) async -> Data {
        let identities = route.senderAvatarLookupIdentities
        for identity in identities where !Task.isCancelled {
            let data = cachedData(identity)
            diagnostics?("cache_lookup identity=\(identity) hit=\(data != nil) bytes=\(data?.count ?? 0)")
            if let data {
                diagnostics?("selected source=cache bytes=\(data.count)")
                return data
            }
        }
        for identity in identities where identity.scope == .contact && !Task.isCancelled {
            let sources = remoteSources(for: identity)
            diagnostics?("remote_sources identity=\(identity) urls=\(sources)")
            for url in sources {
                guard !Task.isCancelled else { break }
                diagnostics?("download_begin url=\(url)")
                let data = await download(url)
                guard !Task.isCancelled, remoteSources(for: identity) == sources else {
                    diagnostics?("download_discarded url=\(url) reason=cancelled_or_metadata_changed")
                    return initials(displayName: displayName, jid: fallbackJid)
                }
                if let data, !data.isEmpty {
                    diagnostics?("selected source=remote url=\(url) bytes=\(data.count)")
                    return data
                }
                diagnostics?("download_failed url=\(url)")
            }
        }
        return initials(displayName: displayName, jid: fallbackJid)
    }

    private func remoteSources(for identity: Identity) -> [String] {
        var result: [String] = []
        for candidate in [savedURL(identity)].compactMap({ $0 }) + fallbackURLs(identity) {
            guard let url = PushNotificationMediaURLPolicy.remoteURLString(candidate),
                  !result.contains(url) else { continue }
            result.append(url)
            if result.count == 2 { break }
        }
        return result
    }

    private func initials(displayName: String, jid: String) -> Data {
        diagnostics?("selected source=initials cancelled=\(Task.isCancelled)")
        return PushNotificationInitialsRenderer.imageData(
            displayName: displayName,
            jid: jid
        )
    }
}
