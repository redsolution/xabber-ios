import Foundation
import XMPPFramework

struct ChatStickerStarterPack {
    static let all = [
        ChatStickerStarterPack(id: "owls", fallbackName: "Owls"),
        ChatStickerStarterPack(id: "monsters", fallbackName: "Monsters")
    ]

    let id: String
    let manifestURL: URL
    let previewURL: URL?
    private let fallbackName: String

    var name: String { L10n.text("chat__stickers__pack_\(id)", fallback: fallbackName) }

    private init(id: String, fallbackName: String) {
        let base = URL(string: "https://cdn.jsdelivr.net/gh/redsolution/xabber-stickers@adf96ab")!
        let directory = base.appendingPathComponent(id)
        self.id = id
        self.fallbackName = fallbackName
        manifestURL = directory.appendingPathComponent("pack.xml")
        previewURL = directory.appendingPathComponent("cover.webp")
    }
}

struct ChatStickerPack: Codable, Equatable, Sendable {
    let manifestURL: URL
    let name: String
    let version: Int
    let coverURL: URL?
    let stickers: [ChatStickerEntry]

    var displayName: String {
        ChatStickerStarterPack.all.first { $0.manifestURL == manifestURL }?.name ?? name
    }
}

struct ChatStickerEntry: Codable, Equatable, Sendable {
    let packURL: URL
    let id: String
    let name: String
    let description: String
    let imageURL: URL
    let filename: String
    let mediaType: String
    let width: Int
    let height: Int
    let emojis: [String]

    func descriptor(preferredEmoji: String? = nil, thumbnail: Data? = nil) -> ChatStickerDescriptor {
        let emoji = preferredEmoji.flatMap { emojis.contains($0) ? $0 : nil } ?? emojis.first ?? "🖼️"
        return ChatStickerDescriptor(
            name: name, packURL: packURL, imageURL: imageURL, emoji: emoji, mediaType: mediaType,
            filename: filename, width: width, height: height, inlineThumbnail: thumbnail
        )
    }
}

enum ChatStickerSuggestion {
    static func loneEmoji(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, trimmed.utf16.count <= 32,
              trimmed.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0 == "\u{FE0F}" || $0 == "\u{20E3}" }) else { return nil }
        return trimmed
    }

    static func matches(text: String, packs: [ChatStickerPack]) -> [ChatStickerEntry] {
        guard let emoji = loneEmoji(in: text) else { return [] }
        return Array(packs.lazy.flatMap(\.stickers).filter { $0.emojis.contains(emoji) }.prefix(12))
    }
}

enum ChatStickerPackManifest {
    enum Failure: Error { case invalidManifest, invalidOwner, unavailable, capacity }

    static let maximumBytes = 1_048_576

    static func manifestURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2_048,
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    static func parse(_ data: Data, url: URL) throws -> ChatStickerPack {
        guard manifestURL(url.absoluteString) == url, data.count <= maximumBytes,
              let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY"),
              let document = try? DDXMLDocument(xmlString: xml, options: 0),
              let root = document.rootElement(), root.name == "sticker-pack",
              let packName = root.attributeStringValue(forName: "name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !packName.isEmpty, let stickers = root.elements(forName: "stickers").first else {
            throw Failure.invalidManifest
        }
        let stickerElements = stickers.elements(forName: "sticker")
        guard !stickerElements.isEmpty, stickerElements.count <= 512 else { throw Failure.invalidManifest }
        var ids: Set<String> = []
        let entries = try stickerElements.map { element in
            guard let file = element.elements(forName: "file").first,
                  let image = source(for: file, manifest: url) else { throw Failure.invalidManifest }
            let filename = text("name", in: file) ?? image.lastPathComponent
            let id = file.attributeStringValue(forName: "id") ?? filename
            let type = text("media-type", in: file) ?? "image/webp"
            guard !filename.isEmpty, !id.isEmpty, ids.insert(id).inserted,
                  ["image/webp", "image/png", "image/jpeg", "image/gif", "image/apng", "image/avif"].contains(type.lowercased()) else {
                throw Failure.invalidManifest
            }
            let emojis = (element.elements(forName: "emojis").first?.elements(forName: "emoji") ?? [])
                .compactMap { $0.stringValue.flatMap(ChatStickerSuggestion.loneEmoji(in:)) }
            let descriptionElement = "description"
            return ChatStickerEntry(
                packURL: url, id: id, name: element.attributeStringValue(forName: "name") ?? filename,
                description: text(descriptionElement, in: element) ?? "", imageURL: image, filename: filename,
                mediaType: type, width: dimension("width", file), height: dimension("height", file),
                emojis: Array(emojis.prefix(32))
            )
        }
        let cover = root.elements(forName: "cover").first?.elements(forName: "file").first
        let version = max(1, Int(root.attributeStringValue(forName: "version") ?? "") ?? 1)
        return ChatStickerPack(manifestURL: url, name: packName, version: version,
                               coverURL: cover.flatMap { source(for: $0, manifest: url) }, stickers: entries)
    }

    private static func text(_ name: String, in element: DDXMLElement) -> String? {
        guard let value = element.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func dimension(_ name: String, _ file: DDXMLElement) -> Int {
        min(16_384, max(0, text(name, in: file).flatMap(Int.init) ?? 0))
    }

    private static func source(for element: DDXMLElement, manifest: URL) -> URL? {
        if let absolute = text("url", in: element) { return manifestURL(absolute) }
        guard let relative = text("name", in: element), relative.utf8.count <= 1_024,
              var url = URLComponents(url: manifest, resolvingAgainstBaseURL: false) else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#;"))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        var escaped: [String] = []
        for component in components {
            let raw = String(component)
            let decoded = raw.removingPercentEncoding ?? raw
            guard !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.unicodeScalars.contains(where: { $0.value == 0x5C }),
                  decoded.rangeOfCharacter(from: .controlCharacters) == nil,
                  let part = decoded.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            escaped.append(part)
        }
        let pathBeforeFilename = url.percentEncodedPath.lastIndex(of: "/").map { url.percentEncodedPath[...$0] } ?? "/"
        url.percentEncodedPath = pathBeforeFilename + escaped.joined(separator: "/")
        url.query = nil
        return url.url.flatMap { manifestURL($0.absoluteString) }
    }
}

@MainActor
final class ChatStickerCatalogue {
    static let changed = Notification.Name("chat.stickerCatalogue.changed")
    static let recentlyUsedChanged = Notification.Name("chat.stickerCatalogue.recentlyUsedChanged")
    private static let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()) ?? .standard
    private static let recentUsagePrefix = "chat.stickerUsage.v1."
    private static let recentStickerLimit = 24
    static let shared = ChatStickerCatalogue(defaults: defaults, imagePreloader: ChatStickerPackImagePreloader())

    private struct StickerUse: Codable {
        let count: Int
        let sequence: Int
    }

    private let defaults: UserDefaults
    private let imagePreloader: ChatStickerPackImagePreloading?
    private let readManifest: (URL, String) async throws -> Data
    private var requests: [String: UUID] = [:]

    init(
        defaults: UserDefaults,
        imagePreloader: ChatStickerPackImagePreloading? = nil,
        readManifest: @escaping (URL, String) async throws -> Data = {
            url, owner in
            let file = try await PrivacyProxyMediaRouter.shared.download(url, owner: owner)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            return try reader.read(upToCount: ChatStickerPackManifest.maximumBytes + 1) ?? Data()
        }
    ) {
        self.defaults = defaults
        self.imagePreloader = imagePreloader
        self.readManifest = readManifest
    }

    func installed(for owner: String) -> [ChatStickerPack] {
        guard let key = Self.key(for: owner), let data = defaults.data(forKey: key),
              let result = try? JSONDecoder().decode([ChatStickerPack].self, from: data) else { return [] }
        return result
    }

    func recentStickers(for owner: String) -> [ChatStickerEntry] {
        guard Self.key(for: owner) != nil else { return [] }
        let usage = stickerUsage(for: owner)
        guard !usage.isEmpty else { return [] }

        let usedEntries = installed(for: owner).lazy.flatMap(\.stickers)
            .filter { usage[$0.imageURL.absoluteString] != nil }
            .map { ($0.imageURL.absoluteString, $0) }
        let entriesByURL = Dictionary(usedEntries, uniquingKeysWith: { first, _ in first })
        let rankedUsage = usage.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            if lhs.value.sequence != rhs.value.sequence {
                return lhs.value.sequence > rhs.value.sequence
            }
            return lhs.key < rhs.key
        }
        return Array(rankedUsage.lazy.compactMap { entriesByURL[$0.key] }.prefix(Self.recentStickerLimit))
    }

    func recordStickerUse(_ sticker: ChatStickerDescriptor, owner: String) {
        guard installed(for: owner).lazy.flatMap(\.stickers).contains(where: { $0.imageURL == sticker.imageURL }) else {
            return
        }
        var usage = stickerUsage(for: owner)
        let url = sticker.imageURL.absoluteString
        let sequence = usage.values.lazy.map(\.sequence).max() ?? 0
        let count = usage[url]?.count ?? 0
        usage[url] = StickerUse(count: min(count, Int.max - 1) + 1,
                                sequence: min(sequence, Int.max - 1) + 1)
        if saveStickerUsage(usage, owner: owner) {
            NotificationCenter.default.post(name: Self.recentlyUsedChanged, object: owner)
        }
    }

    @discardableResult
    func install(_ url: URL, owner: String, imageProfile: ChatStickerImageProfile? = nil) async throws -> ChatStickerPack {
        guard let key = Self.key(for: owner), ChatStickerPackManifest.manifestURL(url.absoluteString) == url else {
            throw ChatStickerPackManifest.Failure.invalidOwner
        }
        let requestKey = key + "|" + url.absoluteString
        let request = UUID()
        requests[requestKey] = request
        defer { if requests[requestKey] == request { requests.removeValue(forKey: requestKey) } }
        let data = try await readManifest(url, owner)
        try Task.checkCancellation()
        let pack = try await Task.detached(priority: .userInitiated) {
            try ChatStickerPackManifest.parse(data, url: url)
        }.value
        try Task.checkCancellation()
        guard requests[requestKey] == request else { throw CancellationError() }
        var packs = installed(for: owner)
        if let current = packs.firstIndex(where: { $0.manifestURL == url }) {
            if packs[current].version >= pack.version {
                let existing = packs[current]
                if let imageProfile {
                    imagePreloader?.preload(existing, owner: owner, profile: imageProfile)
                }
                return existing
            }
            packs[current] = pack
        } else {
            guard packs.count < 24 else { throw ChatStickerPackManifest.Failure.capacity }
            packs.append(pack)
        }
        try save(packs, key: key, owner: owner)
        if let imageProfile {
            imagePreloader?.preload(pack, owner: owner, profile: imageProfile)
        }
        return pack
    }

    func remove(_ url: URL, owner: String) throws {
        guard let key = Self.key(for: owner) else { throw ChatStickerPackManifest.Failure.invalidOwner }
        requests.removeValue(forKey: key + "|" + url.absoluteString)
        try save(installed(for: owner).filter { $0.manifestURL != url }, key: key, owner: owner)
        imagePreloader?.cancel(manifestURL: url, owner: owner)
    }

    func removeAccount(_ owner: String) {
        guard let key = Self.key(for: owner) else { return }
        requests = requests.filter { !$0.key.hasPrefix(key + "|") }
        imagePreloader?.cancel(owner: owner)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: Self.recentUsagePrefix + owner)
        NotificationCenter.default.post(name: Self.changed, object: owner)
    }

    private func save(_ packs: [ChatStickerPack], key: String, owner: String) throws {
        let data = try JSONEncoder().encode(packs)
        guard data.count <= 3 * ChatStickerPackManifest.maximumBytes else {
            throw ChatStickerPackManifest.Failure.capacity
        }
        defaults.set(data, forKey: key)
        let usage = stickerUsage(for: owner)
        if !usage.isEmpty {
            let installedURLs = Set(packs.lazy.flatMap(\.stickers).map { $0.imageURL.absoluteString })
            let preserved = usage.filter { installedURLs.contains($0.key) }
            if preserved.count != usage.count {
                saveStickerUsage(preserved, owner: owner)
            }
        }
        NotificationCenter.default.post(name: Self.changed, object: owner)
    }

    private func stickerUsage(for owner: String) -> [String: StickerUse] {
        guard let data = defaults.data(forKey: Self.recentUsagePrefix + owner) else { return [:] }
        return (try? JSONDecoder().decode([String: StickerUse].self, from: data)) ?? [:]
    }

    @discardableResult
    private func saveStickerUsage(_ usage: [String: StickerUse], owner: String) -> Bool {
        let key = Self.recentUsagePrefix + owner
        if usage.isEmpty {
            defaults.removeObject(forKey: key)
            return true
        }
        guard let data = try? JSONEncoder().encode(usage) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    private static func key(for owner: String) -> String? {
        guard let jid = XMPPJID(string: owner), jid.user != nil, jid.bare == owner else { return nil }
        return "chat.stickerCatalogue.v1." + owner
    }
}
