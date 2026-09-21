//
//  AppearanceSettings.swift
//  xabber
//
//  Created by Codex on 04.09.2026.
//

import Foundation
import UIKit

struct AppearanceColor: Codable, Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16) else {
            return nil
        }
        if value.count == 6 {
            self.init(
                red: Double((raw >> 16) & 0xFF) / 255,
                green: Double((raw >> 8) & 0xFF) / 255,
                blue: Double(raw & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((raw >> 24) & 0xFF) / 255,
                green: Double((raw >> 16) & 0xFF) / 255,
                blue: Double((raw >> 8) & 0xFF) / 255,
                alpha: Double(raw & 0xFF) / 255
            )
        }
    }

    static let systemBlue = AppearanceColor(red: 0, green: 0.478, blue: 1)
    static let white = AppearanceColor(red: 1, green: 1, blue: 1)
    static let black = AppearanceColor(red: 0, green: 0, blue: 0)

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

enum AppearanceInterfaceStyle: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return L10n.text(
                "appearance__interface_style__system",
                fallback: "System"
            )
        case .light: return L10n.text("appearance__interface_style__light", fallback: "Light")
        case .dark: return L10n.text("appearance__interface_style__dark", fallback: "Dark")
        }
    }
}

enum AppearanceTextSize: String, Codable, CaseIterable {
    case system
    case points14
    case points15
    case points16
    case points17
    case points18
    case points19
    case points20
    case points21

    static let fixedCases: [AppearanceTextSize] = [
        .points14, .points15, .points16, .points17, .points18, .points19, .points20, .points21
    ]

    var points: Int? {
        switch self {
        case .system: return nil
        case .points14: return 14
        case .points15: return 15
        case .points16: return 16
        case .points17: return 17
        case .points18: return 18
        case .points19: return 19
        case .points20: return 20
        case .points21: return 21
        }
    }

    var displayName: String {
        points.map { L10n.format("appearance__text_size__points_format", fallback: "%1$@ pt", arguments: [String(describing: $0)]) } ?? L10n.text("appearance__text_size__system", fallback: "System")
    }
}

enum AppearanceBubbleStyle: String, Codable, CaseIterable {
    case noTail
    case smooth
    case bubble
    case bubbles
    case curvy
    case stripes
    case transparent
    case wedge

    static let freeCases: [AppearanceBubbleStyle] = [.noTail, .smooth, .bubble, .bubbles, .curvy]
    static let premiumCases: [AppearanceBubbleStyle] = [.stripes, .transparent, .wedge]

    var displayName: String {
        switch self {
        case .noTail: return L10n.text("appearance__bubble_style__no_tail", fallback: "No tail")
        case .smooth: return L10n.text("appearance__bubble_style__smooth", fallback: "Smooth")
        case .bubble: return L10n.text("appearance__bubble_style__bubble", fallback: "Bubble")
        case .bubbles: return L10n.text("appearance__bubble_style__bubbles", fallback: "Bubbles")
        case .curvy: return L10n.text("appearance__bubble_style__curvy", fallback: "Curvy")
        case .stripes: return L10n.text("appearance__bubble_style__stripes", fallback: "Stripes")
        case .transparent: return L10n.text("appearance__bubble_style__transparent", fallback: "Transparent")
        case .wedge: return L10n.text("appearance__bubble_style__wedge", fallback: "Wedge")
        }
    }

    /// Stable value mirrored to legacy defaults. It must not change with the
    /// in-app language because older builds use these English tokens as IDs.
    var legacyName: String {
        switch self {
        case .noTail: return "No tail"
        case .smooth: return "Smooth"
        case .bubble: return "Bubble"
        case .bubbles: return "Bubbles"
        case .curvy: return "Curvy"
        case .stripes: return "Stripes"
        case .transparent: return "Transparent"
        case .wedge: return "Wedge"
        }
    }

    init(legacyName: String?) {
        let normalized = legacyName?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self = Self.allCases.first {
            $0.legacyName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
        } ?? .noTail
    }
}

enum AppearanceAvatarMask: String, Codable, CaseIterable {
    case circle
    case rounded
    case square
    case roundedSquare = "rounded_square"
    case star
    case pentagon
    case octagon

    static let freeCases: [AppearanceAvatarMask] = [.circle, .rounded, .square, .roundedSquare]
    static let premiumCases: [AppearanceAvatarMask] = [.star, .pentagon, .octagon]

    var displayName: String {
        switch self {
        case .circle: return L10n.text("appearance__avatar_mask__circle", fallback: "Circle")
        case .rounded: return L10n.text("appearance__avatar_mask__rounded", fallback: "Rounded")
        case .square: return L10n.text("appearance__avatar_mask__square", fallback: "Square")
        case .roundedSquare: return L10n.text("appearance__avatar_mask__rounded_square", fallback: "Rounded Square")
        case .star: return L10n.text("appearance__avatar_mask__star", fallback: "Star")
        case .pentagon: return L10n.text("appearance__avatar_mask__pentagon", fallback: "Pentagon")
        case .octagon: return L10n.text("appearance__avatar_mask__octagon", fallback: "Octagon")
        }
    }
}

enum AppearanceAvatarPosition: String, Codable, CaseIterable {
    case top
    case bottom

    var displayName: String {
        switch self {
        case .top: return L10n.text("appearance__avatar_position__top", fallback: "Top")
        case .bottom: return L10n.text("appearance__avatar_position__bottom", fallback: "Bottom")
        }
    }

    /// Stable value mirrored to legacy defaults. See `AppearanceBubbleStyle.legacyName`.
    var legacyName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
}

struct CloudWallpaperReference: Codable, Equatable, Hashable {
    let owner: String
    let galleryIdentity: String
    let fileID: String
    let url: String
    let thumbnailURL: String?
    let hash: String
    let mimeType: String

    init(
        owner: String,
        galleryIdentity: String,
        fileID: String,
        url: String,
        thumbnailURL: String? = nil,
        hash: String,
        mimeType: String = "image/jpeg"
    ) {
        self.owner = owner
        self.galleryIdentity = galleryIdentity
        self.fileID = fileID
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.hash = hash
        self.mimeType = mimeType
    }
}

enum AppearanceWallpaper: Codable, Equatable, Hashable {
    case none
    case builtIn(name: String)
    case gradient(stops: [AppearanceColor], pattern: String?, intensity: Int)
    case cloud(reference: CloudWallpaperReference, blurred: Bool, motion: Bool)

    var legacyName: String {
        switch self {
        case .none: return "None"
        case .builtIn(let name): return name
        case .gradient: return "None"
        case .cloud: return "None"
        }
    }

    /// User-facing name for a stable built-in wallpaper asset identifier.
    /// Unknown values belong to user/server data and are returned untouched.
    static func displayName(forAssetName name: String) -> String {
        switch name {
        case "None": return L10n.text("appearance__wallpaper__none", fallback: "None")
        case "Honeycomb": return L10n.text("appearance__wallpaper__honeycomb", fallback: "Honeycomb")
        case "Aliens": return L10n.text("appearance__wallpaper__aliens", fallback: "Aliens")
        case "Summer": return L10n.text("appearance__wallpaper__summer", fallback: "Summer")
        case "Cats": return L10n.text("appearance__wallpaper__cats", fallback: "Cats")
        case "Flowers": return L10n.text("appearance__wallpaper__flowers", fallback: "Flowers")
        case "Flowers-daisy": return L10n.text("appearance__wallpaper__daisies", fallback: "Daisies")
        case "Hearts": return L10n.text("appearance__wallpaper__hearts", fallback: "Hearts")
        default: return name
        }
    }
}

struct AppearancePalette: Codable, Equatable, Hashable {
    var backgroundStops: [AppearanceColor]
    var accent: AppearanceColor
    var incomingBubble: AppearanceColor
    var outgoingBubble: AppearanceColor
    var incomingText: AppearanceColor
    var outgoingText: AppearanceColor
    var replyAccent: AppearanceColor
    var serviceFill: AppearanceColor

    init(
        backgroundStops: [AppearanceColor],
        accent: AppearanceColor,
        incomingBubble: AppearanceColor,
        outgoingBubble: AppearanceColor,
        incomingText: AppearanceColor,
        outgoingText: AppearanceColor,
        replyAccent: AppearanceColor,
        serviceFill: AppearanceColor
    ) {
        self.backgroundStops = backgroundStops
        self.accent = accent
        self.incomingBubble = incomingBubble
        self.outgoingBubble = outgoingBubble
        self.incomingText = incomingText
        self.outgoingText = outgoingText
        self.replyAccent = replyAccent
        self.serviceFill = serviceFill
    }
}

struct AppearanceTheme: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var isBuiltIn: Bool
    var lightPalette: AppearancePalette
    var darkPalette: AppearancePalette
    var wallpaper: AppearanceWallpaper

    var displayName: String {
        guard isBuiltIn else { return name }
        return AppearanceThemeCatalog.displayName(forBuiltInID: id) ?? name
    }

    func palette(for style: UIUserInterfaceStyle) -> AppearancePalette {
        style == .dark ? darkPalette : lightPalette
    }
}

enum AppearanceThemeCatalog {
    static let builtInThemes: [AppearanceTheme] = {
        let definitions: [(String, String, String, [String], [String], String)] = [
            ("purple", "Classic", "Flowers", ["#A7D96B", "#68B79B"], ["#172634", "#214967"], "#1687F8"),
            ("darkRed", "Ember", "Honeycomb", ["#8D2939", "#E43A58"], ["#271419", "#5E202D"], "#D94B54"),
            ("lightRed", "Rose", "Hearts", ["#FF9A9E", "#FAD0C4"], ["#3B1D2C", "#713446"], "#F25472"),
            ("yellowOrange", "Sunset", "Summer", ["#FFD36E", "#FF8C42"], ["#3B2915", "#71401F"], "#F28A18"),
            ("yellowBlue", "Lagoon", "Aliens", ["#F9ED69", "#43C6DB"], ["#23303D", "#315E71"], "#2F80ED"),
            ("lightGreen", "Mint", "Cats", ["#DCE35B", "#45B649"], ["#152C22", "#28623C"], "#35B85A"),
            ("greenBlue", "Ocean", "Honeycomb", ["#52C234", "#061700"], ["#0D2824", "#175B55"], "#19A7A0"),
            ("lightBlue", "Sky", "Flowers-daisy", ["#89F7FE", "#66A6FF"], ["#142238", "#28547D"], "#3D8BFF")
        ]
        return definitions.map { raw, name, wallpaper, lightStops, darkStops, accentHex in
            let accent = AppearanceColor(hex: accentHex) ?? .systemBlue
            let light = lightStops.compactMap(AppearanceColor.init(hex:))
            let dark = darkStops.compactMap(AppearanceColor.init(hex:))
            return AppearanceTheme(
                id: "builtin.\(raw)",
                name: name,
                isBuiltIn: true,
                lightPalette: AppearancePalette(
                    backgroundStops: light,
                    accent: accent,
                    incomingBubble: .white,
                    outgoingBubble: AppearanceColor(red: 0.82, green: 1, blue: 0.70),
                    incomingText: .black,
                    outgoingText: .black,
                    replyAccent: accent,
                    serviceFill: accent
                ),
                darkPalette: AppearancePalette(
                    backgroundStops: dark,
                    accent: accent,
                    incomingBubble: AppearanceColor(red: 0.12, green: 0.16, blue: 0.21),
                    outgoingBubble: AppearanceColor(red: 0.13, green: 0.33, blue: 0.42),
                    incomingText: .white,
                    outgoingText: .white,
                    replyAccent: accent,
                    serviceFill: AppearanceColor(red: accent.red, green: accent.green, blue: accent.blue, alpha: 0.78)
                ),
                wallpaper: .builtIn(name: wallpaper)
            )
        }
    }()

    /// User-facing name for a stable built-in theme identifier. Custom theme
    /// names remain user data and are never passed through localization.
    static func displayName(forBuiltInID id: String) -> String? {
        switch id {
        case "builtin.purple": return L10n.text("appearance__theme__classic", fallback: "Classic")
        case "builtin.darkRed": return L10n.text("appearance__theme__ember", fallback: "Ember")
        case "builtin.lightRed": return L10n.text("appearance__theme__rose", fallback: "Rose")
        case "builtin.yellowOrange": return L10n.text("appearance__theme__sunset", fallback: "Sunset")
        case "builtin.yellowBlue": return L10n.text("appearance__theme__lagoon", fallback: "Lagoon")
        case "builtin.lightGreen": return L10n.text("appearance__theme__mint", fallback: "Mint")
        case "builtin.greenBlue": return L10n.text("appearance__theme__ocean", fallback: "Ocean")
        case "builtin.lightBlue": return L10n.text("appearance__theme__sky", fallback: "Sky")
        default: return nil
        }
    }

    static func theme(id: String, customThemes: [AppearanceTheme]) -> AppearanceTheme {
        (builtInThemes + customThemes).first(where: { $0.id == id }) ?? builtInThemes[0]
    }
}

struct AppearanceProfile: Codable, Equatable {
    var themeID: String
    var wallpaper: AppearanceWallpaper
    var interfaceStyle: AppearanceInterfaceStyle
    var textSize: AppearanceTextSize
    var bubbleStyle: AppearanceBubbleStyle
    var bubbleRadius: Int
    var avatarMask: AppearanceAvatarMask
    var avatarPosition: AppearanceAvatarPosition
    var accentOverride: AppearanceColor?

    static func `default`(accent: AppearanceColor) -> AppearanceProfile {
        let theme = AppearanceThemeCatalog.builtInThemes[0]
        return AppearanceProfile(
            themeID: theme.id,
            wallpaper: theme.wallpaper,
            interfaceStyle: .system,
            textSize: .system,
            bubbleStyle: .noTail,
            bubbleRadius: 16,
            avatarMask: .rounded,
            avatarPosition: .bottom,
            accentOverride: accent
        )
    }

    mutating func apply(theme: AppearanceTheme, preserveWallpaper: Bool = false) {
        let currentWallpaper = wallpaper
        themeID = theme.id
        wallpaper = theme.wallpaper
        accentOverride = nil
        if preserveWallpaper {
            wallpaper = currentWallpaper
        }
    }

    mutating func sanitize() {
        bubbleRadius = min(max(bubbleRadius, 0), 16)
        if case .gradient(let stops, let pattern, let intensity) = wallpaper {
            wallpaper = .gradient(
                stops: Array(stops.prefix(4)),
                pattern: pattern,
                intensity: min(max(intensity, 0), 100)
            )
        }
    }
}

struct AppearanceSettingsDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var profile: AppearanceProfile
    var customThemes: [AppearanceTheme]

    init(
        version: Int = AppearanceSettingsDocument.currentVersion,
        profile: AppearanceProfile,
        customThemes: [AppearanceTheme] = []
    ) {
        self.version = version
        self.profile = profile
        self.customThemes = customThemes
    }
}

struct AppearanceChangeSet: OptionSet, Equatable {
    let rawValue: Int

    static let paint = AppearanceChangeSet(rawValue: 1 << 0)
    static let layout = AppearanceChangeSet(rawValue: 1 << 1)
    static let interfaceStyle = AppearanceChangeSet(rawValue: 1 << 2)

    static func between(_ old: AppearanceProfile, _ new: AppearanceProfile) -> AppearanceChangeSet {
        var result: AppearanceChangeSet = []
        if old.themeID != new.themeID ||
            old.wallpaper != new.wallpaper ||
            old.accentOverride != new.accentOverride {
            result.insert(.paint)
        }
        if old.textSize != new.textSize ||
            old.bubbleStyle != new.bubbleStyle ||
            old.bubbleRadius != new.bubbleRadius ||
            old.avatarMask != new.avatarMask ||
            old.avatarPosition != new.avatarPosition {
            result.insert(.layout)
        }
        if old.interfaceStyle != new.interfaceStyle {
            result.formUnion([.paint, .interfaceStyle])
        }
        return result
    }

    static func between(
        _ old: AppearanceSettingsDocument,
        _ new: AppearanceSettingsDocument
    ) -> AppearanceChangeSet {
        var result = between(old.profile, new.profile)
        let oldTheme = AppearanceThemeCatalog.theme(
            id: old.profile.themeID,
            customThemes: old.customThemes
        )
        let newTheme = AppearanceThemeCatalog.theme(
            id: new.profile.themeID,
            customThemes: new.customThemes
        )
        if oldTheme != newTheme {
            result.insert(.paint)
        }
        return result
    }
}

struct AppearanceDraft: Equatable {
    private(set) var original: AppearanceProfile
    var profile: AppearanceProfile

    init(profile: AppearanceProfile) {
        original = profile
        self.profile = profile
    }

    var isDirty: Bool { profile != original }
    var changeSet: AppearanceChangeSet { .between(original, profile) }

    mutating func reset() {
        profile = original
    }

    mutating func accept() {
        original = profile
    }
}

enum AppearanceStoreError: Error, Equatable {
    case emptyThemeName
    case duplicateThemeName
    case themeNotFound
    case builtInThemeImmutable
    case encodingFailed
}

protocol AppearanceSettingsStoring: AnyObject {
    func load() -> AppearanceSettingsDocument
    @discardableResult func commit(_ document: AppearanceSettingsDocument) throws -> AppearanceChangeSet
    @discardableResult func createCustomTheme(named: String, basedOn theme: AppearanceTheme) throws -> AppearanceTheme
}

final class AppearanceSettingsStore: AppearanceSettingsStoring {
    static let storageKey = "appearance.settings.document.v1"

    private let defaults: UserDefaults
    private let defaultAccent: AppearanceColor
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults, defaultAccentHex: String) {
        self.defaults = defaults
        defaultAccent = AppearanceColor(hex: defaultAccentHex) ?? .systemBlue
    }

    convenience init?() {
        guard let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            return nil
        }
        self.init(
            defaults: defaults,
            defaultAccentHex: CommonConfigManager.shared.config.application_color
        )
    }

    func load() -> AppearanceSettingsDocument {
        if let data = defaults.data(forKey: Self.storageKey),
           var decoded = try? decoder.decode(AppearanceSettingsDocument.self, from: data),
           decoded.version <= AppearanceSettingsDocument.currentVersion {
            decoded.profile.sanitize()
            decoded.customThemes = Self.validCustomThemes(decoded.customThemes)
            return decoded
        }
        let migrated = migrateLegacyProfile()
        if let data = try? encoder.encode(migrated) {
            defaults.set(data, forKey: Self.storageKey)
        }
        return migrated
    }

    @discardableResult
    func commit(_ document: AppearanceSettingsDocument) throws -> AppearanceChangeSet {
        let old = load()
        var sanitized = document
        sanitized.version = AppearanceSettingsDocument.currentVersion
        sanitized.profile.sanitize()
        sanitized.customThemes = try validatedCustomThemes(sanitized.customThemes)
        guard let data = try? encoder.encode(sanitized) else {
            throw AppearanceStoreError.encodingFailed
        }
        defaults.set(data, forKey: Self.storageKey)
        mirrorLegacy(profile: sanitized.profile)
        return .between(old, sanitized)
    }

    @discardableResult
    func createCustomTheme(named name: String, basedOn theme: AppearanceTheme) throws -> AppearanceTheme {
        let clean = try validatedName(name, excludingID: nil)
        var copy = theme
        copy.id = "custom.\(UUID().uuidString.lowercased())"
        copy.name = clean
        copy.isBuiltIn = false
        var document = load()
        document.customThemes.append(copy)
        _ = try commit(document)
        return copy
    }

    @discardableResult
    func updateCustomTheme(_ theme: AppearanceTheme) throws -> AppearanceTheme {
        guard !theme.isBuiltIn else { throw AppearanceStoreError.builtInThemeImmutable }
        var document = load()
        guard let index = document.customThemes.firstIndex(where: { $0.id == theme.id }) else {
            throw AppearanceStoreError.themeNotFound
        }
        var replacement = theme
        replacement.name = try validatedName(theme.name, excludingID: theme.id)
        replacement.isBuiltIn = false
        document.customThemes[index] = replacement
        _ = try commit(document)
        return replacement
    }

    @discardableResult
    func renameCustomTheme(id: String, to name: String) throws -> AppearanceTheme {
        var document = load()
        guard let index = document.customThemes.firstIndex(where: { $0.id == id }) else {
            if AppearanceThemeCatalog.builtInThemes.contains(where: { $0.id == id }) {
                throw AppearanceStoreError.builtInThemeImmutable
            }
            throw AppearanceStoreError.themeNotFound
        }
        document.customThemes[index].name = try validatedName(name, excludingID: id)
        _ = try commit(document)
        return document.customThemes[index]
    }

    func deleteCustomTheme(id: String) throws {
        var document = load()
        guard let index = document.customThemes.firstIndex(where: { $0.id == id }) else {
            if AppearanceThemeCatalog.builtInThemes.contains(where: { $0.id == id }) {
                throw AppearanceStoreError.builtInThemeImmutable
            }
            throw AppearanceStoreError.themeNotFound
        }
        document.customThemes.remove(at: index)
        if document.profile.themeID == id {
            document.profile.apply(theme: AppearanceThemeCatalog.builtInThemes[0])
        }
        _ = try commit(document)
    }

    private func migrateLegacyProfile() -> AppearanceSettingsDocument {
        var profile = AppearanceProfile.default(accent: defaultAccent)
        let legacyGradient = defaults.string(forKey: "chat_chooseBackgroundColor") ?? "purple"
        let themeID = "builtin.\(legacyGradient)"
        if AppearanceThemeCatalog.builtInThemes.contains(where: { $0.id == themeID }) {
            profile.themeID = themeID
        }
        let background = defaults.string(forKey: "chat_chooseBackground") ?? profile.wallpaper.legacyName
        profile.wallpaper = background == "None" ? .none : .builtIn(name: background)
        profile.bubbleStyle = AppearanceBubbleStyle(legacyName: defaults.string(forKey: "message_corner_style"))
        profile.bubbleRadius = Int(defaults.string(forKey: "message_corner_radius") ?? "16") ?? 16
        profile.avatarPosition = AppearanceAvatarPosition(
            rawValue: (defaults.string(forKey: "avatar_chat_vertical_position") ?? "Bottom").lowercased()
        ) ?? .bottom
        let mask = defaults.string(forKey: "avatar_masks_current_avatar_mask_") ?? "rounded"
        profile.avatarMask = AppearanceAvatarMask(rawValue: mask) ?? .rounded
        profile.sanitize()
        return AppearanceSettingsDocument(profile: profile)
    }

    private func mirrorLegacy(profile: AppearanceProfile) {
        defaults.set(profile.themeID.replacingOccurrences(of: "builtin.", with: ""), forKey: "chat_chooseBackgroundColor")
        defaults.set(profile.wallpaper.legacyName, forKey: "chat_chooseBackground")
        defaults.set(profile.bubbleStyle.legacyName, forKey: "message_corner_style")
        defaults.set(String(profile.bubbleRadius), forKey: "message_corner_radius")
        defaults.set(profile.avatarPosition.legacyName, forKey: "avatar_chat_vertical_position")
        defaults.set(profile.avatarMask.rawValue, forKey: "avatar_masks_current_avatar_mask_")
    }

    private func validatedName(_ name: String, excludingID: String?) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AppearanceStoreError.emptyThemeName }
        let normalized = Self.normalizedName(clean)
        let all = AppearanceThemeCatalog.builtInThemes + load().customThemes
        if all.contains(where: { $0.id != excludingID && Self.normalizedName($0.name) == normalized }) {
            throw AppearanceStoreError.duplicateThemeName
        }
        return clean
    }

    private func validatedCustomThemes(_ themes: [AppearanceTheme]) throws -> [AppearanceTheme] {
        var names = Set<String>()
        var result: [AppearanceTheme] = []
        for var theme in themes where !theme.isBuiltIn {
            let clean = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw AppearanceStoreError.emptyThemeName }
            let normalized = Self.normalizedName(clean)
            guard names.insert(normalized).inserted,
                  !AppearanceThemeCatalog.builtInThemes.contains(where: { Self.normalizedName($0.name) == normalized }) else {
                throw AppearanceStoreError.duplicateThemeName
            }
            theme.name = clean
            result.append(theme)
        }
        return result
    }

    private static func validCustomThemes(_ themes: [AppearanceTheme]) -> [AppearanceTheme] {
        var names = Set(AppearanceThemeCatalog.builtInThemes.map { normalizedName($0.name) })
        return themes.compactMap { theme in
            guard !theme.isBuiltIn else { return nil }
            var theme = theme
            theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedName(theme.name)
            guard !normalized.isEmpty, names.insert(normalized).inserted else { return nil }
            return theme
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AppearancePremiumPolicy {
    let isEntitled: Bool
    let subscriptionsEnabled: Bool

    var visibleBubbleStyles: [AppearanceBubbleStyle] {
        subscriptionsEnabled ? AppearanceBubbleStyle.allCases : AppearanceBubbleStyle.freeCases
    }

    var visibleAvatarMasks: [AppearanceAvatarMask] {
        subscriptionsEnabled ? AppearanceAvatarMask.allCases : AppearanceAvatarMask.freeCases
    }

    func canSelect(_ candidate: AppearanceBubbleStyle, currentlyApplied: AppearanceBubbleStyle) -> Bool {
        visibleBubbleStyles.contains(candidate)
    }

    func requiresPurchaseToCommit(
        _ candidate: AppearanceBubbleStyle,
        currentlyApplied: AppearanceBubbleStyle
    ) -> Bool {
        subscriptionsEnabled
            && !isEntitled
            && AppearanceBubbleStyle.premiumCases.contains(candidate)
            && candidate != currentlyApplied
    }

    func canSelect(_ candidate: AppearanceAvatarMask, currentlyApplied: AppearanceAvatarMask) -> Bool {
        visibleAvatarMasks.contains(candidate)
    }

    func requiresPurchaseToCommit(
        _ candidate: AppearanceAvatarMask,
        currentlyApplied: AppearanceAvatarMask
    ) -> Bool {
        subscriptionsEnabled
            && !isEntitled
            && AppearanceAvatarMask.premiumCases.contains(candidate)
            && candidate != currentlyApplied
    }
}

protocol AppearanceEntitlementProviding {
    var hasActiveAppearanceEntitlement: Bool { get }
    var areSubscriptionsEnabled: Bool { get }
}

struct AppearanceCloudOwnerCandidate: Equatable {
    let owner: String
    let galleryIdentity: String
    let isEnabled: Bool
    let isPremium: Bool
    let isReady: Bool
}

enum AppearanceCloudOwnerSelector {
    static func select(from candidates: [AppearanceCloudOwnerCandidate]) -> AppearanceCloudOwnerCandidate? {
        let ready = candidates.filter { $0.isEnabled && $0.isReady }
        return ready.first(where: { $0.isPremium }) ?? ready.first
    }
}

struct AppearanceCloudWallpaperUploadRequest: Equatable {
    let owner: String
    let galleryIdentity: String
    let data: Data
    let filename: String
    let mimeType: String
    let metadata: [String: String]
}

protocol AppearanceCloudWallpaperClient {
    func upload(
        request: AppearanceCloudWallpaperUploadRequest,
        completion: @escaping (Result<CloudWallpaperReference, Error>) -> Void
    )
}

struct ResolvedAppearanceSnapshot: Equatable {
    let profile: AppearanceProfile
    let theme: AppearanceTheme
    let palette: AppearancePalette
    let accent: AppearanceColor

    var layoutSignature: String {
        [
            profile.textSize.rawValue,
            profile.bubbleStyle.rawValue,
            String(profile.bubbleRadius),
            profile.avatarMask.rawValue,
            profile.avatarPosition.rawValue
        ].joined(separator: "|")
    }
}

enum AppearanceResolver {
    static func resolve(
        document: AppearanceSettingsDocument,
        traitStyle: UIUserInterfaceStyle
    ) -> ResolvedAppearanceSnapshot {
        let theme = AppearanceThemeCatalog.theme(
            id: document.profile.themeID,
            customThemes: document.customThemes
        )
        let style: UIUserInterfaceStyle
        switch document.profile.interfaceStyle {
        case .system:
            style = traitStyle == .dark ? .dark : .light
        case .light:
            style = .light
        case .dark:
            style = .dark
        }
        let palette = messageSemanticPalette(theme.palette(for: style))
        return ResolvedAppearanceSnapshot(
            profile: document.profile,
            theme: theme,
            palette: palette,
            accent: document.profile.accentOverride ?? palette.accent
        )
    }

    /// Legacy palettes describe the coloured bubble as outgoing.  Appearance
    /// now presents that theme colour for the other participant and keeps the
    /// user's messages consistently white, including old custom palettes.
    private static func messageSemanticPalette(_ palette: AppearancePalette) -> AppearancePalette {
        var resolved = palette
        resolved.incomingBubble = palette.outgoingBubble
        resolved.incomingText = palette.outgoingText
        resolved.outgoingBubble = .white
        resolved.outgoingText = .black
        return resolved
    }
}

extension Notification.Name {
    static let appearanceDidChange = Notification.Name("AppearanceDidChange")
}

@MainActor
final class AppearanceCoordinator {
    static let shared = AppearanceCoordinator()

    private let store: AppearanceSettingsStoring
    private(set) var document: AppearanceSettingsDocument

    init(store: AppearanceSettingsStoring? = nil) {
        let resolvedStore = store ?? AppearanceSettingsStore() ?? AppearanceSettingsStore(
            defaults: .standard,
            defaultAccentHex: "#007AFF"
        )
        self.store = resolvedStore
        document = resolvedStore.load()
    }

    func snapshot(for traits: UITraitCollection) -> ResolvedAppearanceSnapshot {
        AppearanceResolver.resolve(document: document, traitStyle: traits.userInterfaceStyle)
    }

    @discardableResult
    func commit(_ updated: AppearanceSettingsDocument) throws -> AppearanceChangeSet {
        let previousProfile = document.profile
        let changes = try store.commit(updated)
        document = store.load()
        applyToAllWindows()
        publish(changes, previousProfile: previousProfile)
        return changes
    }

    func reloadAndApply() {
        let previousDocument = document
        document = store.load()
        applyToAllWindows()
        publish(.between(previousDocument, document), previousProfile: previousDocument.profile)
    }

    @discardableResult
    func createCustomTheme(named: String, basedOn theme: AppearanceTheme) throws -> AppearanceTheme {
        let created = try store.createCustomTheme(named: named, basedOn: theme)
        reloadAndApply()
        return created
    }

    func apply(to window: UIWindow) {
        let snapshot = snapshot(for: window.traitCollection)
        window.overrideUserInterfaceStyle = document.profile.interfaceStyle.userInterfaceStyle
        window.tintColor = snapshot.accent.uiColor
    }

    func applyToAllWindows() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard !UIAccessibility.isReduceMotionEnabled else {
            windows.forEach(apply(to:))
            return
        }
        windows.forEach { window in
            UIView.transition(
                with: window,
                duration: 0.32,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent],
                animations: { self.apply(to: window) }
            )
        }
    }

    private func publish(_ changes: AppearanceChangeSet, previousProfile: AppearanceProfile) {
        NotificationCenter.default.post(
            name: .appearanceDidChange,
            object: self,
            userInfo: ["changes": changes.rawValue]
        )
        if changes.contains(.paint) {
            NotificationCenter.default.post(name: .chatBackgroundChanged, object: self)
        }
        // Chat message attributed strings and bubble layers cache resolved palette
        // values as well as geometry. Re-map them for paint commits so an open
        // conversation updates immediately instead of waiting for cell reuse.
        if changes.contains(.paint) || changes.contains(.layout) {
            NotificationCenter.default.post(name: .chatInterfaceChanged, object: self)
        }
        if previousProfile.avatarMask != document.profile.avatarMask {
            AccountMasksManager.shared.update(mask: document.profile.avatarMask.rawValue)
            NotificationCenter.default.post(name: .newMaskSelected, object: self)
        }
    }
}

enum AppearanceTypography {
    static var currentSize: AppearanceTextSize {
        AppearanceSettingsStore()?.load().profile.textSize ?? .system
    }

    static func currentFont(
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        font(
            textStyle: textStyle,
            appearanceSize: currentSize,
            weight: weight,
            compatibleWith: traits
        )
    }

    static func font(
        textStyle: UIFont.TextStyle,
        appearanceSize: AppearanceTextSize,
        weight: UIFont.Weight = .regular,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        guard let points = appearanceSize.points else {
            let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle, compatibleWith: traits)
            return UIFont(descriptor: descriptor, size: 0).withWeight(weight)
        }
        let relativeOffset: CGFloat
        switch textStyle {
        case .largeTitle: relativeOffset = 17
        case .title1: relativeOffset = 11
        case .title2: relativeOffset = 5
        case .title3: relativeOffset = 3
        case .headline, .body: relativeOffset = 0
        case .callout: relativeOffset = -1
        case .subheadline: relativeOffset = -2
        case .footnote: relativeOffset = -4
        case .caption1: relativeOffset = -5
        case .caption2: relativeOffset = -6
        default: relativeOffset = 0
        }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: UIFont.systemFont(ofSize: max(9, CGFloat(points) + relativeOffset), weight: weight),
            compatibleWith: traits
        )
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let attributes: [UIFontDescriptor.AttributeName: Any] = [
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ]
        return UIFont(descriptor: fontDescriptor.addingAttributes(attributes), size: pointSize)
    }
}
